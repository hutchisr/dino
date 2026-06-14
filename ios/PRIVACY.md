# Gecko Privacy Policy

_Last updated: 14 June 2026_

Gecko is an XMPP (Jabber) chat client for iPhone. This policy explains what data
Gecko handles and how. The short version: Gecko is built to keep your
conversations private. Your data stays on your device and on the XMPP server you
choose, and the developer does not collect, track, sell, or profile you.

## How Gecko works

Gecko connects to an XMPP server of your choice — the account you sign in with.
The developer of Gecko does **not** operate that server and does not host your
account or your messages. Your messages, contacts, and account data live on your
device and on your chosen server, governed by that server operator's own privacy
policy.

## End-to-end encryption

Gecko supports OMEMO end-to-end encryption. When a conversation is encrypted with
OMEMO, message contents can be read only by you and the people you are messaging —
not by your server, not by the developer, and not by Apple. Messages that are not
end-to-end encrypted (for example, in a public group that doesn't support it) are
handled by your XMPP server like any other XMPP message.

## Data stored on your device

Gecko stores your account settings, message history, contacts, and encryption
keys locally on your device, in the app's private storage. This data leaves your
device only to communicate with your chosen XMPP server. Deleting the app removes
this local data.

## Account credentials

Your XMPP username and password are stored on your device and sent only to your
chosen XMPP server to log in. They are never sent to the developer or any third
party.

## Push notifications

To alert you to new messages while the app is closed, Gecko uses a small push
relay together with Apple's Push Notification service (APNs):

- When a message is waiting, your XMPP server notifies the relay (operated by the
  developer) using your app's Apple-issued device token.
- The relay forwards a notification through Apple, which delivers it to your
  device.
- The relay does **not** receive your message contents. Encrypted messages are
  decrypted only on your device, after the notification arrives. The relay
  processes only your device token and the fact that a message is waiting, and
  does not persist this information.
- Apple's handling of push notifications is governed by Apple's privacy policy.

You can turn notifications off in iOS Settings; messaging still works without
them.

## Analytics and tracking

Gecko contains no analytics, no advertising, and no third-party tracking SDKs.
The developer collects no usage data and builds no profile of you.

## Data the developer collects

None, beyond the transient push-relay handling described above. There is no
account with the developer, and no personal data is collected, stored, or sold.

## Third parties

- **Your chosen XMPP server operator** — selected by you; subject to their own
  policy.
- **Apple** — for push notification delivery (APNs).

## Children

Gecko is not directed at children under 13.

## Changes

This policy may be updated from time to time; the "last updated" date above will
change to reflect any revisions.

## Contact

Questions about this policy: `<your-contact-email>`
