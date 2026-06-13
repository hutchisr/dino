import UserNotifications

/// Notification Service Extension entry point.
///
/// iOS spawns this for every push carrying `mutable-content: 1` (the proxy
/// already sets it). It has ~30s and ~24MB to enrich or — once the filtering
/// entitlement is granted — suppress the notification.
///
/// Phase 1 scope: prove the extension runs and can reach the shared App Group
/// database that the main app writes. Phase 2 will connect over XMPP, fetch the
/// latest message via MAM, OMEMO-decrypt it, and apply per-conversation filters.
@objc(NotificationService)
class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestAttempt = content

        // Receive + decrypt the triggering message on-device (Monal-style):
        // shares the real DB and connects so the message is acked and the
        // server's pending state clears (no re-push). Budget under the ~30s
        // limit so we beat serviceExtensionTimeWillExpire.
        NSEFetcher.fetch(timeoutMs: 24_000) { messages in
            guard let latest = messages.last else {
                contentHandler(content)
                return
            }
            if !latest.conversationJid.isEmpty {
                var info = content.userInfo
                info["conversationJid"] = latest.conversationJid
                content.userInfo = info
            }
            if latest.isMuted {
                // Suppress the banner entirely. With the filtering entitlement
                // an empty UNNotificationContent silences the push; without it
                // (un-granted device) iOS substitutes the original payload, so
                // this degrades to the generic "New message" rather than a
                // wrong banner.
                contentHandler(UNNotificationContent())
                return
            }
            if latest.isGroupchat {
                content.title = latest.conversationName
                content.body = "\(latest.sender): \(latest.body)"
            } else {
                content.title = latest.sender.isEmpty ? latest.conversationName : latest.sender
                content.body = latest.body
            }
            if messages.count > 1 {
                content.subtitle = "\(messages.count) new messages"
            }
            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Deliver whatever we have if we run out of time.
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
