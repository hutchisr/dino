# Gecko push proxy

Translates XEP-0357 push publishes into APNs notifications. Runs as a plain
XMPP bot account — no server component or HTTP endpoint needed.

How it fits together:

1. Gecko registers with APNs and gets a device token.
2. Gecko sends `<enable xmlns='urn:xmpp:push:0' jid='BOT_JID' node='TOKEN'/>`
   to the user's server (which must support XEP-0357; xmpp.is does).
3. When the user has no active session and a message arrives, the server
   sends a pubsub publish to the bot. The publish's node is the device
   token, so the proxy is completely stateless.
4. The proxy posts a (generic, content-free) alert to APNs; iOS shows the
   notification and the app reconnects + syncs when opened.

## Running

```sh
python3 -m venv venv && venv/bin/pip install -r requirements.txt
XMPP_JID=geckopush@example.org \
XMPP_PASSWORD=... \
APNS_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8 \
APNS_KEY_ID=XXXXXXXXXX \
APNS_TEAM_ID=998J34UYP5 \
APNS_TOPIC=me.anemoneya.gecko \
APNS_SANDBOX=1 \
venv/bin/python gecko_push_proxy.py
```

`APNS_SANDBOX=1` for development-signed builds (sideloaded with a dev
certificate, or the iOS Simulator); `0` for App Store / TestFlight builds.

## Docker / Kubernetes

```sh
docker build -t gecko-push-proxy .
docker run -d --restart unless-stopped \
  -v /path/to/AuthKey_XXXXXXXXXX.p8:/secrets/apns.p8:ro \
  -e XMPP_JID='geckopush@example.org/proxy' -e XMPP_PASSWORD=... \
  -e APNS_KEY_PATH=/secrets/apns.p8 -e APNS_KEY_ID=... -e APNS_TEAM_ID=... \
  gecko-push-proxy
```

For Kubernetes see `k8s.yaml` (Deployment with a single replica — the bot
binds a fixed XMPP resource, so never scale it up — plus the secret recipe
in its header comment).

The client picks the proxy's JID from the `DINO_PUSH_PROXY_JID` environment
variable (Simulator runs) or the default in `PushRegistration.swift`.

Notes:

- Notifications are content-free ("New message") since XEP-0357 summaries
  carry no message bodies and OMEMO couldn't be decrypted here anyway.
  Real previews require a Notification Service Extension in the app that
  briefly connects and decrypts — future work.
- The `mutable-content` flag is already set on pushes so an NSE can be
  added without proxy changes.
