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

        // Phase 2 will connect over XMPP, fetch the latest message via MAM,
        // OMEMO-decrypt it, map it to a conversation, apply that conversation's
        // notify setting (suppressing when muted, once the filtering
        // entitlement lands), and enrich the alert with sender + preview —
        // all reading from the shared App Group databases via NSEStore.
        // For now the push is delivered unchanged.
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Deliver whatever we have if we run out of time.
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
