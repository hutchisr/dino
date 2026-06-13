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
  APNS_SANDBOX    "1" for development-signed builds (default 1)
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
APNS_SANDBOX = os.environ.get("APNS_SANDBOX", "1") == "1"
APNS_HOST = "https://api.sandbox.push.apple.com" if APNS_SANDBOX else "https://api.push.apple.com"
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

    def _auth(self) -> str:
        # APNs accepts tokens for up to an hour; refresh at 45 minutes
        if self._jwt is None or time.time() - self._jwt_at > 45 * 60:
            self._jwt = jwt.encode(
                {"iss": self.team_id, "iat": int(time.time())},
                self.key, algorithm="ES256", headers={"kid": self.key_id})
            self._jwt_at = time.time()
        return self._jwt

    async def push(self, device_token: str, payload: dict) -> int:
        resp = await self.http.post(
            f"{APNS_HOST}/3/device/{device_token}",
            headers={
                "authorization": f"bearer {self._auth()}",
                "apns-topic": APNS_TOPIC,
                "apns-push-type": "alert",
                "apns-priority": "10",
            },
            json=payload)
        if resp.status_code != 200:
            log.warning("APNs %s for %s…: %s", resp.status_code, device_token[:8], resp.text)
        return resp.status_code


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

        rules = self.filters.get(node.lower())
        if rules and sender:
            bare = sender.split("/")[0].lower()
            if bare in rules["muted"]:
                log.info("muted conversation %s — dropping push", bare)
                return
            if bare in rules["mention"]:
                nick = rules["mention"][bare]
                if not last_body or nick.lower() not in last_body.lower():
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
