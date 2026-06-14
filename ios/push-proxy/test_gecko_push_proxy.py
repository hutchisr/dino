"""Unit tests for the Gecko push proxy's pure logic.

Covers the two pieces most likely to regress and hardest to eyeball:
  * Apns.push()        — the sandbox/production fallback + per-token caching.
  * PushBot.handle_publish() — per-conversation mute / mention-only filtering,
                         burst de-duplication, and the summary -> banner text.
  * PushBot.on_message()     — parsing the client's filter payload.

No network, no XMPP, no APNs: the async APNs HTTP call and the slixmpp stanzas
are faked, and the bot methods are exercised as unbound functions against a
duck-typed `self`, so nothing here connects to anything.

Run (uses the proxy's venv, which already has the deps):
    ./venv/bin/python -m unittest test_gecko_push_proxy -v
"""
import json
import logging
import unittest
from types import SimpleNamespace
from xml.etree import ElementTree as ET

import gecko_push_proxy as proxy
from gecko_push_proxy import Apns, PushBot

# The proxy logs (incl. an expected exception traceback for the malformed-input
# test) — keep test output clean; behaviour is asserted, not the logs.
logging.disable(logging.CRITICAL)


# --- helpers --------------------------------------------------------------

def make_apns(valid_env, *, bad_reason="BadDeviceToken", fail_status=400):
    """An Apns whose _post returns 200 only for `valid_env`, otherwise
    `fail_status` carrying `bad_reason`. Bypasses __init__ (no key file / JWT).
    Records the order of environments tried on `_calls`."""
    apns = Apns.__new__(Apns)
    apns.token_env = {}
    apns._calls = []

    async def fake_post(env, device_token, payload):
        apns._calls.append(env)
        if env == valid_env:
            return SimpleNamespace(status_code=200, json=lambda: {}, text="ok")
        return SimpleNamespace(status_code=fail_status,
                               json=lambda: {"reason": bad_reason}, text=bad_reason)

    apns._post = fake_post
    return apns


class FakeApns:
    """Captures pushes instead of sending them."""

    def __init__(self):
        self.pushes = []

    async def push(self, token, payload):
        self.pushes.append((token, payload))
        return 200


def make_bot(filters=None):
    """Duck-typed stand-in for a PushBot — just the attributes the methods use."""
    return SimpleNamespace(filters=filters or {}, last_push={}, apns=FakeApns())


HEX_TOKEN = "ab" * 32  # 64 hex chars, matches TOKEN_RE


def make_iq(count=None, sender=None, body=None):
    """Minimal stand-in for the XEP-0357 publish iq: only `.xml` is read, and
    only for its jabber:x:data summary fields."""
    x = ET.Element("{jabber:x:data}x")

    def add(var, value):
        field = ET.SubElement(x, "{jabber:x:data}field", {"var": var})
        ET.SubElement(field, "{jabber:x:data}value").text = value

    if count is not None:
        add("message-count", str(count))
    if sender is not None:
        add("last-message-sender", sender)
    if body is not None:
        add("last-message-body", body)
    return SimpleNamespace(xml=x)


class FakeMsg:
    """Minimal stand-in for a slixmpp message for on_message()."""

    def __init__(self, filters_json=None, body=""):
        self.xml = ET.Element("{jabber:client}message")
        if filters_json is not None:
            ET.SubElement(self.xml, "{urn:gecko:push:filters}filters").text = filters_json
        self._body = body

    def __getitem__(self, key):
        if key == "body":
            return self._body
        raise KeyError(key)


# --- Apns.push() fallback -------------------------------------------------

class TestApnsFallback(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        # Pin the "try first" env so tests don't depend on the runner's
        # APNS_SANDBOX environment variable.
        self._saved_first = proxy.APNS_FIRST
        proxy.APNS_FIRST = "sandbox"

    def tearDown(self):
        proxy.APNS_FIRST = self._saved_first

    async def test_sandbox_token_succeeds_on_first_try(self):
        apns = make_apns("sandbox")
        self.assertEqual(await apns.push("tok", {}), 200)
        self.assertEqual(apns._calls, ["sandbox"])
        self.assertEqual(apns.token_env["tok"], "sandbox")

    async def test_production_token_falls_back_from_sandbox(self):
        apns = make_apns("production")
        self.assertEqual(await apns.push("tok", {}), 200)
        self.assertEqual(apns._calls, ["sandbox", "production"])
        self.assertEqual(apns.token_env["tok"], "production")

    async def test_learned_env_is_tried_first_next_time(self):
        apns = make_apns("production")
        await apns.push("tok", {})           # learns production via fallback
        apns._calls.clear()
        await apns.push("tok", {})           # should skip the sandbox attempt
        self.assertEqual(apns._calls, ["production"])

    async def test_real_error_does_not_fall_back(self):
        # 410 Unregistered is a genuine failure, not a wrong-environment signal.
        apns = make_apns(None, bad_reason="Unregistered", fail_status=410)
        self.assertEqual(await apns.push("tok", {}), 410)
        self.assertEqual(apns._calls, ["sandbox"])     # no second attempt
        self.assertNotIn("tok", apns.token_env)        # nothing cached

    async def test_bad_on_both_envs_returns_last_status(self):
        apns = make_apns(None)               # BadDeviceToken everywhere
        self.assertEqual(await apns.push("tok", {}), 400)
        self.assertEqual(apns._calls, ["sandbox", "production"])
        self.assertNotIn("tok", apns.token_env)


# --- PushBot.handle_publish() filtering / dedup / summary -----------------

class TestHandlePublish(unittest.IsolatedAsyncioTestCase):
    async def test_non_token_node_is_ignored(self):
        bot = make_bot()
        await PushBot.handle_publish(bot, "not-a-token", make_iq(count=1))
        self.assertEqual(bot.apns.pushes, [])

    async def test_single_message_banner(self):
        bot = make_bot()
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1, sender="x@y/r", body="hi"))
        self.assertEqual(len(bot.apns.pushes), 1)
        token, payload = bot.apns.pushes[0]
        self.assertEqual(token, HEX_TOKEN)
        self.assertEqual(payload["aps"]["alert"]["body"], "New message")

    async def test_no_count_still_pushes_generic_banner(self):
        bot = make_bot()
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(sender="x@y/r"))
        self.assertEqual(bot.apns.pushes[0][1]["aps"]["alert"]["body"], "New message")

    async def test_multiple_messages_banner(self):
        bot = make_bot()
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=3))
        self.assertEqual(bot.apns.pushes[0][1]["aps"]["alert"]["body"], "3 new messages")

    async def test_muted_conversation_is_dropped(self):
        bot = make_bot({HEX_TOKEN: {"muted": {"alice@example.com"}, "mention": {}}})
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1, sender="alice@example.com/phone"))
        self.assertEqual(bot.apns.pushes, [])

    async def test_unmuted_conversation_is_sent(self):
        bot = make_bot({HEX_TOKEN: {"muted": {"alice@example.com"}, "mention": {}}})
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1, sender="bob@example.com/x"))
        self.assertEqual(len(bot.apns.pushes), 1)

    async def test_mention_only_without_mention_is_dropped(self):
        bot = make_bot({HEX_TOKEN: {"muted": set(), "mention": {"room@muc": "rachel"}}})
        await PushBot.handle_publish(
            bot, HEX_TOKEN, make_iq(count=1, sender="room@muc/someone", body="hello everyone"))
        self.assertEqual(bot.apns.pushes, [])

    async def test_mention_only_with_mention_is_sent(self):
        bot = make_bot({HEX_TOKEN: {"muted": set(), "mention": {"room@muc": "rachel"}}})
        await PushBot.handle_publish(
            bot, HEX_TOKEN, make_iq(count=1, sender="room@muc/someone", body="hey Rachel!"))
        self.assertEqual(len(bot.apns.pushes), 1)

    async def test_mention_only_without_body_is_delivered(self):
        # The server didn't include a body, so we can't check for the mention —
        # deliver rather than risk dropping a real one.
        bot = make_bot({HEX_TOKEN: {"muted": set(), "mention": {"room@muc": "rachel"}}})
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1, sender="room@muc/someone"))
        self.assertEqual(len(bot.apns.pushes), 1)

    async def test_identical_near_simultaneous_repeat_is_collapsed(self):
        # A ghost session re-fires the same notification ~ms later; collapse it.
        bot = make_bot()
        iq = make_iq(count=1, body="New Message!")
        await PushBot.handle_publish(bot, HEX_TOKEN, iq)
        await PushBot.handle_publish(bot, HEX_TOKEN, iq)   # identical summary, same instant
        self.assertEqual(len(bot.apns.pushes), 1)

    async def test_distinct_bodies_are_both_delivered(self):
        bot = make_bot()
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1, body="first"))
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1, body="second"))
        self.assertEqual(len(bot.apns.pushes), 2)

    async def test_mismatched_body_twin_is_not_collapsed_here(self):
        # The body-less + body-ful seconds-apart re-push is the NSE's job to
        # prevent at the source; the proxy can't tell it from a new message, so
        # it forwards both rather than guess.
        bot = make_bot()
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1))
        await PushBot.handle_publish(bot, HEX_TOKEN, make_iq(count=1, body="New Message!"))
        self.assertEqual(len(bot.apns.pushes), 2)


# --- PushBot.on_message() filter parsing ----------------------------------

class TestOnMessage(unittest.TestCase):
    def test_parses_and_normalizes_filters(self):
        bot = SimpleNamespace(filters={})
        token = "AABB" + "c" * 60
        PushBot.on_message(bot, FakeMsg(filters_json=json.dumps({
            "token": token,
            "muted": ["Alice@Example.com"],
            "mention_only": [{"jid": "Room@MUC", "nick": "Rachel"}],
        })))
        key = token.lower()
        self.assertIn(key, bot.filters)
        # jids are case-folded (bare jids are case-insensitive); nick is kept.
        self.assertEqual(bot.filters[key]["muted"], {"alice@example.com"})
        self.assertEqual(bot.filters[key]["mention"], {"room@muc": "Rachel"})

    def test_message_without_filters_is_ignored(self):
        bot = SimpleNamespace(filters={})
        PushBot.on_message(bot, FakeMsg(body="just a normal message"))
        self.assertEqual(bot.filters, {})

    def test_malformed_filter_payload_does_not_raise(self):
        bot = SimpleNamespace(filters={})
        PushBot.on_message(bot, FakeMsg(filters_json="{ not valid json"))
        self.assertEqual(bot.filters, {})


if __name__ == "__main__":
    unittest.main()
