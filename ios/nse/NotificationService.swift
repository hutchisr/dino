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

        // Connect, MAM-sync, and OMEMO-decrypt the message(s) that triggered
        // this push. Budget under the ~30s NSE limit so our callback wins the
        // race against serviceExtensionTimeWillExpire.
        NSEFetcher.fetch(timeoutMs: 24_000) { messages in
            guard let latest = messages.last else {
                // Couldn't fetch in time — leave the generic alert as-is.
                Self.debug("fetch empty — delivering generic")
                contentHandler(content)
                return
            }

            if latest.isMuted {
                // Phase 3 will drop this entirely (needs the filtering
                // entitlement); until then, deliver the original generic alert
                // rather than an enriched one for a muted conversation.
                Self.debug("muted [\(latest.notify)] \(latest.conversationName)")
                contentHandler(request.content)
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
            Self.debug("enriched (\(messages.count)) title=\(content.title) body=\(content.body)")
            contentHandler(content)
        }
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
