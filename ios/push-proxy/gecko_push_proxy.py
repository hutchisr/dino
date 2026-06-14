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
"""
import asyncio
import json
import logging
import os
import re
import signal
import sys
import time

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
        self.key = open(key_path).read()
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
            reason = ""
            try:
                reason = resp.json().get("reason", "")
            except Exception:
                pass
            if reason != "BadDeviceToken":
                log.warning("APNs %s (%s) for %s…: %s", status, env, device_token[:8], resp.text)
                return status
            # wrong environment — fall through and try the other one
        log.warning("APNs BadDeviceToken on all environments for %s…", device_token[:8])
        return status


class PushBot(slixmpp.ClientXMPP):
    def __init__(self, jid: str, password: str, apns: Apns):
        super().__init__(jid, password)
        self.apns = apns
        # device token -> {"muted": set of bare jids,
        #                  "mention": {bare jid: nick}}
        self.filters: dict[str, dict] = {}
        self.add_event_handler("session_start", self.on_start)
        self.add_event_handler("message", self.on_message)
        self.register_plugin("xep_0030")
        self.register_plugin("xep_0060")
        self.register_plugin("xep_0198")
        # XEP-0357 sends the push publish as an iq-set to the app server
        self.register_handler(CoroutineCallback(
            "xep0357-publish",
            StanzaPath("iq@type=set/pubsub/publish"),
            self.on_publish_iq))

    async def on_start(self, _event):
        self.send_presence()
        log.info("connected as %s", self.boundjid.full)

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
        try:
            for field in iq.xml.iter("{jabber:x:data}field"):
                var = field.get("var")
                value = field.find("{jabber:x:data}value")
                text = value.text if value is not None else None
                if var == "message-count" and text:
                    count = int(text)
                elif var == "last-message-sender" and text:
                    sender = text
                elif var == "last-message-body" and text:
                    last_body = text
        except Exception:
            pass
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
        if not last_body:
            log.info("bodiless publish for %s… (chat state / receipt / twin) — dropping", node[:8])
            return

        rules = self.filters.get(node.lower())
        if rules and sender:
            bare = sender.split("/")[0].lower()
            if bare in rules["muted"]:
                log.info("muted conversation %s — dropping push", bare)
                return
            if bare in rules["mention"]:
                nick = rules["mention"][bare]
                # Suppress only when we can see the body and the nick isn't in
                # it. If the server sent no body we can't tell, so deliver rather
                # than risk swallowing a real mention.
                if last_body and nick.lower() not in last_body.lower():
                    log.info("mention-only %s without mention — dropping push", bare)
                    return

        body = "New message" if not count or count <= 1 else f"{count} new messages"
        payload = {
            "aps": {
                "alert": {"title": "Gecko", "body": body},
                "sound": "default",
                "mutable-content": 1,
                "thread-id": "gecko-messages",
            }
        }
        status = await self.apns.push(node.lower(), payload)
        log.info("push -> %s… (%s)", node[:8], status)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        jid = os.environ["XMPP_JID"]
        password = os.environ["XMPP_PASSWORD"]
        apns = Apns(os.environ["APNS_KEY_PATH"], os.environ["APNS_KEY_ID"], os.environ["APNS_TEAM_ID"])
    except KeyError as e:
        sys.exit(f"missing required environment variable: {e}")

    bot = PushBot(jid, password, apns)
    bot.connect()
    loop = asyncio.get_event_loop()
    # exit promptly on SIGTERM so k8s Recreate rollouts don't hang
    loop.add_signal_handler(signal.SIGTERM, loop.stop)
    try:
        loop.run_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
