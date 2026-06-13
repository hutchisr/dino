# Self-hosted UDID enrollment

A tiny service that collects an iOS device's UDID via Apple's Over-the-Air
**Profile Service** protocol — no third-party site. Used to register a tester's
device for an ad-hoc Gecko build.

## How it works

1. Tester opens `https://enroll.anemoneya.me` in **Safari** on the iPhone.
2. Taps "Install profile" → `/profile` returns a `Profile Service`
   `.mobileconfig`.
3. On install, iOS gathers the device attributes (UDID, model, iOS version),
   CMS-signs them with Apple's device cert, and POSTs them to `/collect`.
4. `/collect` logs them and shows a confirmation. The temporary profile removes
   itself.

iOS rejects an *unsigned* Profile Service profile as "invalid", so the service
CMS-signs it with the domain's own TLS cert (cert-manager's `gecko-enroll-tls`
secret, mounted at `/tls`). That chains to a trusted root (Let's Encrypt), so it
installs as "Verified" — no extra trust step on the device.

## Deploy

```sh
docker build --platform linux/amd64 -t lax.vultrcr.com/mercury/gecko-udid-enroll:v1 .
docker push lax.vultrcr.com/mercury/gecko-udid-enroll:v1
kubectl apply -f k8s.yaml
```

Then point DNS for `enroll.anemoneya.me` at the nginx ingress (A
`144.202.116.122` + the AAAA, same as the other `*.anemoneya.me` records).
cert-manager issues the Let's Encrypt cert automatically once DNS resolves.

Read collected UDIDs:

```sh
kubectl -n gecko logs deploy/gecko-udid-enroll -f | grep ENROLL
```

## After you have the UDID — getting the build onto the device

1. Register the UDID in the Apple Developer portal (Devices).
2. Create / regenerate **ad-hoc** provisioning profiles that include the new
   device, for both app ids:
   - `me.anemoneya.gecko`
   - `me.anemoneya.gecko.NotificationService`
   (App Groups + push capabilities, as the dev profiles already have.)
3. Build + ad-hoc-sign an IPA (extend `app/deploy-phone.sh`'s signing flow with
   the ad-hoc profiles instead of the development ones).
4. Distribute the IPA over the air (e.g. Diawi) and send the tester the install
   link; they trust the developer cert under Settings → General → VPN & Device
   Management.
