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

        // NSE fetch DISABLED again: connecting from the extension re-triggers
        // server pushes on xmpp.is (each connect leaves the pending message
        // unacked, so the server re-pushes, waking the extension — a flood).
        // No-presence didn't break it; the trigger is at the
        // stream-management/delivery layer, not presence. Pass the generic
        // push through until a fetch that doesn't disturb server state exists.
        contentHandler(content)
    }

    /// Temporary verification breadcrumb (simulator banners show the static
    /// payload, not our replacement) — removed once validated on device.
    static func debug(_ s: String) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.me.anemoneya.gecko")?
            .appendingPathComponent("nse-last.txt") else { return }
        try? (s + "\n").data(using: .utf8)?.write(to: url)
    }

    /// Temporary append-only trace of every bridge line, for diagnosing the
    /// connect/sync sequence on the simulator.
    static func debugAppend(_ s: String) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.me.anemoneya.gecko")?
            .appendingPathComponent("nse-trace.txt") else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); try? h.close()
        } else {
            try? (s + "\n").data(using: .utf8)?.write(to: url)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Deliver whatever we have if we run out of time.
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
