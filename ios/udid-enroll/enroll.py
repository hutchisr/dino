#!/usr/bin/env python3
"""Self-hosted iOS device UDID enrollment, via Apple's Over-the-Air Profile
Service protocol — no third party involved.

Flow:
  1. The tester opens the site in Safari and taps "Install profile".
  2. /profile returns a `Profile Service` .mobileconfig. On install, iOS
     gathers the requested device attributes (UDID, model, iOS version, ...),
     CMS-signs them with Apple's device certificate, and POSTs them to /collect.
  3. /collect logs the attributes (read them with `kubectl logs`) and shows a
     confirmation. The temporary profile removes itself afterwards.

The POSTed body is a PKCS#7/CMS signed blob whose payload is the attributes
plist verbatim, so we slice the inner <?xml ... </plist> out rather than doing
full CMS parsing. (The UDID is logged regardless of what we return, so capture
never depends on the device's handling of the response.)
"""
import plistlib

from flask import Flask, request, Response
from waitress import serve

app = Flask(__name__)

# Stable id for the one-shot enrollment profile (any fixed UUID is fine).
PROFILE_UUID = "7E6B0C2A-1D34-4F90-9A1E-9C0F1E2D3A4B"

PAGE_STYLE = (
    "body{font-family:-apple-system,system-ui,sans-serif;max-width:34rem;"
    "margin:3rem auto;padding:0 1.3rem;line-height:1.55;color:#1c1c1e}"
    "a.btn{display:inline-block;background:#16a34a;color:#fff;padding:.85rem 1.5rem;"
    "border-radius:13px;text-decoration:none;font-weight:600;margin:1rem 0}"
    ".muted{color:#8e8e93;font-size:.9rem}code{background:#f2f2f7;padding:.1rem .35rem;border-radius:5px}"
)


@app.get("/")
def index():
    return (
        f"<!doctype html><html><head><meta charset=utf-8>"
        f"<meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<title>Gecko device registration</title><style>{PAGE_STYLE}</style></head><body>"
        "<h2>Register this device for Gecko</h2>"
        "<p>Tap below and install the profile when prompted. It sends this "
        "device's identifier (UDID) so it can be added to the Gecko test build, "
        "then removes itself — nothing stays installed.</p>"
        "<p><a class=btn href='/profile'>Install registration profile</a></p>"
        "<p class=muted>Open this page in <b>Safari</b> on the iPhone you want to register. "
        "After installing, you'll see an “Unsigned” note — that's expected; tap Install.</p>"
        "</body></html>"
    )


@app.get("/profile")
def profile():
    host = request.host  # whatever host the ingress routed (e.g. enroll.anemoneya.me)
    payload = {
        "PayloadContent": {
            "URL": f"https://{host}/collect",
            "DeviceAttributes": ["UDID", "PRODUCT", "VERSION", "SERIAL", "DEVICE_NAME"],
        },
        "PayloadOrganization": "Gecko",
        "PayloadDisplayName": "Gecko Device Registration",
        "PayloadDescription": "Sends this device's UDID to register it for the "
                              "Gecko test build, then removes itself.",
        "PayloadVersion": 1,
        "PayloadUUID": PROFILE_UUID,
        "PayloadIdentifier": "me.anemoneya.gecko.enroll",
        "PayloadType": "Profile Service",
    }
    return Response(plistlib.dumps(payload),
                    mimetype="application/x-apple-aspen-config")


@app.post("/collect")
def collect():
    body = request.get_data()
    info = {}
    start, end = body.find(b"<?xml"), body.find(b"</plist>")
    if start != -1 and end != -1:
        try:
            info = plistlib.loads(body[start:end + 8])
        except Exception as exc:  # noqa: BLE001
            print(f"collect: plist parse error: {exc!r}", flush=True)
    udid = info.get("UDID", "?")
    print(
        f"ENROLL udid={udid} product={info.get('PRODUCT')} "
        f"version={info.get('VERSION')} serial={info.get('SERIAL')} "
        f"name={info.get('DEVICE_NAME')}",
        flush=True,
    )
    return Response(
        f"<!doctype html><html><head><meta charset=utf-8>"
        f"<meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<title>Registered</title><style>{PAGE_STYLE}body{{text-align:center}}</style></head><body>"
        "<h2>✅ Registered</h2>"
        "<p>Thanks — your device is registered. You can close this page; the "
        "profile removes itself automatically.</p>"
        f"<p class=muted>UDID: <code>{udid}</code></p>"
        "</body></html>",
        mimetype="text/html",
    )


if __name__ == "__main__":
    serve(app, host="0.0.0.0", port=8080)
