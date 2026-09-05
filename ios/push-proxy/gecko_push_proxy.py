#!/usr/bin/env python3
"""Gecko push proxy: XEP-0357 app server -> APNs.

Logs into XMPP as a plain bot account. The user's server sends it a pubsub
publish whenever a push-enabled account has pending messages; the publish's
node IS the APNs device token (hex), so no registration state is needed.

Configuration (environment):
  XMPP_JID        bot account jid           (required)
  XMPP_PASSWORD   bot account password      (required)
  APNS_KEY_PATH   path to AuthKey_*.p8      (required)
  APNS_KEY_ID     APNs auth key id          (required)
  APNS_TEAM_ID    Apple developer team id   (required)
  APNS_TOPIC      app bundle id             (default me.anemoneya.gecko)
  APNS_SANDBOX    which APNs env to try first: "1" sandbox (dev builds),
                  "0" production (ad-hoc/TestFlight). Both are tried — this is
                  only the preference; tokens for the other env fall back
                  automatically. (default 1)
  XMPP_PING_INTERVAL seconds between server pings; 0 disables active pings
                  (default 60)
  XMPP_PING_TIMEOUT  seconds to wait before forcing an XMPP reconnect
                  (default 15)
  XMPP_RECONNECT_INITIAL first reconnect delay in seconds (default 1)
  XMPP_RECONNECT_MAX     maximum reconnect delay in seconds (default 60)
"""
import asyncio
import json
import logging
import os
import re
import signal
import sys
import time
from contextlib import suppress

import httpx
import jwt
import slixmpp
from slixmpp.xmlstream.handler import CoroutineCallback
from slixmpp.xmlstream.matcher import StanzaPath

log = logging.getLogger("gecko-push")

APNS_TOPIC = os.environ.get("APNS_TOPIC", "me.anemoneya.gecko")
APNS_HOSTS = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}
# A token only works against one environment: development-signed builds
# (Xcode/dev) use sandbox; ad-hoc / TestFlight / App Store builds use
# production. We don't know which a given token is, so we try one and fall back
# to the other on BadDeviceToken. APNS_SANDBOX just sets which to try first.
APNS_FIRST = "sandbox" if os.environ.get("APNS_SANDBOX", "1") == "1" else "production"
TOKEN_RE = re.compile(r"^[0-9a-fA-F]{32,200}$")



class Apns:
    """Minimal APNs HTTP/2 client with JWT (token-based) auth."""

    def __init__(self, key_path: str, key_id: str, team_id: str):
        with open(key_path, encoding="utf-8") as key_file:
            self.key = key_file.read()
        self.key_id = key_id
        self.team_id = team_id
        self._jwt = None
        self._jwt_at = 0.0
        self.http = httpx.AsyncClient(http2=True, timeout=10)
        # device token -> environment ("sandbox"/"production") last seen working,
        # so we hit the right one first next time (in-memory; relearned on restart)
        self.token_env: dict[str, str] = {}

    def _auth(self) -> str:
        # APNs accepts tokens for up to an hour; refresh at 45 minutes
        if self._jwt is None or time.time() - self._jwt_at > 45 * 60:
            self._jwt = jwt.encode(
                {"iss": self.team_id, "iat": int(time.time())},
                self.key, algorithm="ES256", headers={"kid": self.key_id})
            self._jwt_at = time.time()
        return self._jwt

    async def _post(self, env: str, device_token: str, payload: dict):
        return await self.http.post(
            f"{APNS_HOSTS[env]}/3/device/{device_token}",
            headers={
                "authorization": f"bearer {self._auth()}",
                "apns-topic": APNS_TOPIC,
                "apns-push-type": "alert",
                "apns-priority": "10",
            },
            json=payload)

    async def push(self, device_token: str, payload: dict) -> int:
        # Try the env this token is known to use (else the configured default)
        # first, then the other only if APNs says the token is for the wrong
        # environment (400 BadDeviceToken). Cache whichever worked.
        first = self.token_env.get(device_token, APNS_FIRST)
        order = [first] + [e for e in APNS_HOSTS if e != first]
        status = None
        for env in order:
            resp = await self._post(env, device_token, payload)
            status = resp.status_code
            if status == 200:
                self.token_env[device_token] = env
                return 200
            try:
                response_payload = resp.json()
            except json.JSONDecodeError:
                log.debug("APNs returned a non-JSON error response", exc_info=True)
                response_payload = {}
            reason = response_payload.get("reason", "") if isinstance(response_payload, dict) else ""
            if reason != "BadDeviceToken":
                log.warning("APNs %s (%s) for %s…: %s", status, env, device_token[:8], resp.text)
                return status
            # wrong environment — fall through and try the other one
        log.warning("APNs BadDeviceToken on all environments for %s…", device_token[:8])
        return status

    async def close(self):
        await self.http.aclose()


class PushBot(slixmpp.ClientXMPP):
    def __init__(self, jid: str, password: str, apns: Apns, *,
                 filters: dict[str, dict] | None = None,
                 ping_interval: float = 60.0,
                 ping_timeout: float = 15.0):
        super().__init__(jid, password)
        self.apns = apns
        # device token -> {"muted": set of bare jids,
        #                  "mention": {bare jid: nick}}
        self.filters: dict[str, dict] = filters if filters is not None else {}
        self.ping_interval = ping_interval
        self.ping_timeout = ping_timeout
        self._ping_task: asyncio.Task | None = None
        self.add_event_handler("session_start", self.on_start)
        self.add_event_handler("disconnected", self.on_disconnected)
        self.add_event_handler("message", self.on_message)
        self.register_plugin("xep_0030")
        self.register_plugin("xep_0060")
        self.register_plugin("xep_0198")
        self.register_plugin("xep_0199")
        # XEP-0357 sends the push publish as an iq-set to the app server
        self.register_handler(CoroutineCallback(
            "xep0357-publish",
            StanzaPath("iq@type=set/pubsub/publish"),
            self.on_publish_iq))

    async def on_start(self, _event):
        self.send_presence()
        self.start_ping_monitor()
        log.info("connected as %s", self.boundjid.full)

    def on_disconnected(self, reason):
        self.stop_ping_monitor()
        if reason == "shutdown":
            log.info("XMPP disconnected for shutdown")
            return
        if reason:
            log.warning("XMPP disconnected: %s", reason)
        else:
            log.warning("XMPP disconnected")

    def start_ping_monitor(self):
        self.stop_ping_monitor()
        if self.ping_interval <= 0 or self.ping_timeout <= 0:
            return
        self._ping_task = asyncio.create_task(self.ping_monitor())

    def stop_ping_monitor(self):
        if self._ping_task is not None:
            self._ping_task.cancel()
            self._ping_task = None

    async def ping_monitor(self):
        try:
            while True:
                await asyncio.sleep(self.ping_interval)
                try:
                    await self.plugin["xep_0199"].ping(self.boundjid.host, timeout=self.ping_timeout)
                except asyncio.CancelledError:
                    raise
                except Exception:
                    log.warning("XMPP ping failed; forcing reconnect", exc_info=True)
                    self.disconnect(
                        wait=0,
                        reason=f"Ping timeout after {self.ping_timeout:g}s",
                        ignore_send_queue=True)
                    return
        except asyncio.CancelledError:
            pass

    def on_message(self, msg):
        """Clients send their notification filters in a custom element
        (bodyless message with no-store hints)."""
        payload = None
        el = msg.xml.find("{urn:gecko:push:filters}filters")
        if el is not None and el.text:
            payload = el.text
        elif msg["body"] and '"gecko-push-filters"' in msg["body"]:
            payload = msg["body"]  # legacy clients
        if not payload:
            return
        try:
            data = json.loads(payload)
            token = data["token"].lower()
            self.filters[token] = {
                "muted": {j.lower() for j in data.get("muted", [])},
                "mention": {e["jid"].lower(): e.get("nick", "") for e in data.get("mention_only", [])},
            }
            log.info("filters for %s…: %d muted, %d mention-only",
                     token[:8], len(self.filters[token]["muted"]), len(self.filters[token]["mention"]))
        except Exception:
            log.exception("bad filter message")

    async def on_publish_iq(self, iq):
        try:
            node = iq["pubsub"]["publish"]["node"]
            log.info("publish for node %s… from %s", (node or "")[:8], iq["from"])
            iq.reply().send()
            await self.handle_publish(node, iq)
        except Exception:
            log.exception("failed to handle publish")

    async def handle_publish(self, node: str, iq):
        if not TOKEN_RE.match(node or ""):
            log.warning("publish with non-token node %r ignored", (node or "")[:24])
            return
        # XEP-0357 summary form: message count, and (server-dependent)
        # last-message-sender / last-message-body
        count = None
        sender = None
        last_body = None
        for field in iq.xml.iter("{jabber:x:data}field"):
            var = field.get("var")
            value = field.find("{jabber:x:data}value")
            text = value.text if value is not None else None
            if var == "message-count" and text:
                try:
                    count = int(text)
                except ValueError:
                    log.warning("invalid message-count in push summary: %r", text)
            elif var == "last-message-sender" and text:
                sender = text
            elif var == "last-message-body" and text:
                last_body = text
        log.info("summary: count=%s sender=%s body=%s",
                 count, sender, "yes" if last_body else "no")

        # Bodiless publishes are not messages worth waking the user for: chat
        # states (XEP-0085 typing), delivery receipts (XEP-0184), and read
        # markers (XEP-0333) never carry a body, and neither does the body-less
        # twin the server emits alongside every real message. Real messages
        # always summarise *with* a body — plaintext, or the OMEMO fallback
        # ("[This message is OMEMO encrypted]") that every mainstream client
        # includes. So drop anything bodiless; the body-ful twin of a genuine
        # message still gets through, giving exactly one push per message.
        #
        # ACCEPTED TRADEOFF: a real message *could* summarise bodiless — if a
        # peer's client omits the OMEMO fallback <body>, or sends the encrypted
        # payload as a stanza separate from any body-bearing copy. We'd drop its
        # push and miss that notification. That's deliberate for now: the
        # alternative (pushing on every bodiless publish) floods the user with
        # "New message" spam for every keystroke and receipt. Once the filtering
        # entitlement lands, the NSE can fetch + classify on-device and decide
        # precisely, and this blunt drop can be relaxed. Until then, fewer-but-
        # real pushes beats accurate-but-spammy. See [[gecko-push-duplication]].
        if not last_body:
            log.info("bodiless publish for %s… (chat state / receipt / twin) — dropping", node[:8])
            return

        badge = max(count or 1, 1)
        show_alert = True
        rules = self.filters.get(node.lower())
        if rules and sender:
            bare = sender.split("/")[0].lower()
            if bare in rules["muted"]:
                log.info("muted conversation %s — sending badge-only push", bare)
                show_alert = False
            if bare in rules["mention"]:
                nick = rules["mention"][bare]
                # Suppress only when we can see the body and the nick isn't in
                # it. If the server sent no body we can't tell, so deliver rather
                # than risk swallowing a real mention.
                if last_body and nick.lower() not in last_body.lower():
                    log.info("mention-only %s without mention — sending badge-only push", bare)
                    show_alert = False

        if show_alert:
            body = "New message" if badge <= 1 else f"{badge} new messages"
            aps = {
                "alert": {"title": "Gecko", "body": body},
                "badge": badge,
                "sound": "default",
                "mutable-content": 1,
                "thread-id": "gecko-messages",
            }
        else:
            aps = {"badge": badge}
        payload = {"aps": aps}
        status = await self.apns.push(node.lower(), payload)
        log.info("push -> %s… (%s)", node[:8], status)


def env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        sys.exit(f"{name} must be a number, got {raw!r}")


def stop_bot(bot):
    if hasattr(bot, "cancel_connection_attempt"):
        bot.cancel_connection_attempt()
    bot.disconnect(wait=0, reason="shutdown", ignore_send_queue=True)


async def wait_for_disconnect_or_stop(bot, disconnected, stop_event: asyncio.Event) -> bool:
    disconnect_task = asyncio.ensure_future(disconnected)
    stop_task = asyncio.create_task(stop_event.wait())
    done, pending = await asyncio.wait(
        {disconnect_task, stop_task},
        return_when=asyncio.FIRST_COMPLETED)
    for task in pending:
        task.cancel()
    for task in pending:
        with suppress(asyncio.CancelledError):
            await task

    if stop_task in done:
        stop_bot(bot)
        if not disconnect_task.done():
            with suppress(asyncio.TimeoutError):
                await asyncio.wait_for(disconnect_task, timeout=2)
        return True

    if disconnect_task in done:
        disconnect_task.result()
    return stop_event.is_set()


async def sleep_or_stop(delay: float, stop_event: asyncio.Event, sleep=asyncio.sleep):
    if delay <= 0 or stop_event.is_set():
        return
    sleep_task = asyncio.create_task(sleep(delay))
    stop_task = asyncio.create_task(stop_event.wait())
    done, pending = await asyncio.wait(
        {sleep_task, stop_task},
        return_when=asyncio.FIRST_COMPLETED)
    for task in pending:
        task.cancel()
    for task in pending:
        with suppress(asyncio.CancelledError):
            await task
    if sleep_task in done:
        sleep_task.result()


async def run_xmpp_forever(jid: str, password: str, apns: Apns, stop_event: asyncio.Event, *,
                           bot_factory=PushBot,
                           sleep=asyncio.sleep,
                           reconnect_initial: float = 1.0,
                           reconnect_max: float = 60.0,
                           ping_interval: float = 60.0,
                           ping_timeout: float = 15.0):
    reconnect_initial = max(0.0, reconnect_initial)
    reconnect_max = max(reconnect_initial, reconnect_max)
    reconnect_delay = reconnect_initial
    filters: dict[str, dict] = {}

    while not stop_event.is_set():
        bot = bot_factory(
            jid,
            password,
            apns,
            filters=filters,
            ping_interval=ping_interval,
            ping_timeout=ping_timeout)
        session_started = asyncio.Event()
        bot.add_event_handler(
            "session_start",
            lambda _event, started=session_started: started.set(),
            disposable=True)
        disconnected = bot.disconnected

        log.info("connecting to XMPP as %s", jid)
        try:
            bot.connect()
            stopped = await wait_for_disconnect_or_stop(bot, disconnected, stop_event)
        except asyncio.CancelledError:
            stop_bot(bot)
            raise
        except Exception:
            log.exception("XMPP client loop failed")
            stopped = stop_event.is_set()
        if stopped:
            break

        if session_started.is_set():
            reconnect_delay = reconnect_initial
        log.warning("reconnecting to XMPP in %.1fs", reconnect_delay)
        await sleep_or_stop(reconnect_delay, stop_event, sleep)
        next_delay = reconnect_delay * 2 if reconnect_delay > 0 else 1.0
        reconnect_delay = min(reconnect_max, max(reconnect_initial, next_delay))


async def async_main():
    try:
        jid = os.environ["XMPP_JID"]
        password = os.environ["XMPP_PASSWORD"]
        apns = Apns(os.environ["APNS_KEY_PATH"], os.environ["APNS_KEY_ID"], os.environ["APNS_TEAM_ID"])
    except KeyError as e:
        sys.exit(f"missing required environment variable: {e}")

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    def request_stop(sig_name):
        log.info("received %s; shutting down", sig_name)
        stop_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, request_stop, sig.name)
        except NotImplementedError:
            pass

    try:
        await run_xmpp_forever(
            jid,
            password,
            apns,
            stop_event,
            reconnect_initial=env_float("XMPP_RECONNECT_INITIAL", 1.0),
            reconnect_max=env_float("XMPP_RECONNECT_MAX", 60.0),
            ping_interval=env_float("XMPP_PING_INTERVAL", 60.0),
            ping_timeout=env_float("XMPP_PING_TIMEOUT", 15.0))
    finally:
        await apns.close()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    asyncio.run(async_main())


if __name__ == "__main__":
    main()
