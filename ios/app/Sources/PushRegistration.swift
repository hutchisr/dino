import Foundation
import UIKit
import UserNotifications

/// APNs registration: ask for notification permission, register with APNs,
/// and enable XEP-0357 push on the XMPP server with the device token as the
/// node (the proxy decodes the node back into a token, so no registration
/// round-trip is needed).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var onToken: ((String) -> Void)?
#if targetEnvironment(macCatalyst)
    private var persistenceActivity: NSObjectProtocol?
#endif

    /// Set by the UI once the model is available; routes a tapped
    /// notification's conversation to `openChat`. A tap that arrives before
    /// the handler is set (cold launch) is held in `pendingOpenJid`.
    private static var openHandler: ((String) -> Void)?
    private static var pendingOpenJid: String?

    static func setOpenHandler(_ handler: @escaping (String) -> Void) {
        openHandler = handler
        if let jid = pendingOpenJid {
            pendingOpenJid = nil
            DispatchQueue.main.async { handler(jid) }
        }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must be set before launch finishes to receive notification responses.
        UNUserNotificationCenter.current().delegate = self
#if targetEnvironment(macCatalyst)
        MacLocalNotifications.start()
        persistenceActivity = ProcessInfo.processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "Keep the XMPP connection available for notifications"
        )
#endif
        return true
    }

#if targetEnvironment(macCatalyst)
    func applicationDidBecomeActive(_ application: UIApplication) {
        CatalystWindowLifecycle.reopenIfNeeded()
    }
#endif

    // --- Background clean-disconnect coordination ---
    // On entering the background we cleanly disconnect (flush XEP-0198 acks +
    // close) so iOS doesn't suspend us with an unacked message that the server
    // would re-push on a loop. A short grace delay avoids churning the
    // connection on a quick background→foreground toggle (e.g. a glance at
    // Control Center): if we return to the foreground first, the disconnect is
    // cancelled and the live connection is kept.
    private var pendingDisconnect: DispatchWorkItem?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private let backgroundGrace: TimeInterval = 3

    func scheduleBackgroundDisconnect() {
        pendingDisconnect?.cancel()
        beginBgTaskIfNeeded()
        let work = DispatchWorkItem { [weak self] in
            GeckoCore.shared.appBackgrounded()
            self?.pendingDisconnect = nil
            // Let the flush-ack + stream close finish before releasing the
            // background assertion that keeps the process alive to do it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.endBgTask() }
        }
        pendingDisconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backgroundGrace, execute: work)
    }

    func cancelBackgroundDisconnect() {
        pendingDisconnect?.cancel()
        pendingDisconnect = nil
        endBgTask()
    }

    private func beginBgTaskIfNeeded() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "gecko-clean-disconnect") { [weak self] in
            self?.endBgTask()
        }
    }

    private func endBgTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        geckoDebugLog("gecko-push: APNs token %@", redactedIdentifier(hex))
        AppDelegate.onToken?(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        geckoDebugLog("gecko-push: APNs registration failed: %@", error.localizedDescription)
    }

    /// User tapped a notification — open the conversation it belongs to (the
    /// extension stamped the jid into userInfo).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let jid = response.notification.request.content.userInfo["conversationJid"] as? String, !jid.isEmpty {
            if let handler = AppDelegate.openHandler {
                DispatchQueue.main.async { handler(jid) }
            } else {
                AppDelegate.pendingOpenJid = jid
            }
        }
        completionHandler()
    }
}

#if targetEnvironment(macCatalyst)
@MainActor
enum MacLocalNotifications {
    private static var appIsActive = true

    static func setAppIsActive(_ active: Bool) {
        appIsActive = active
    }

    static func start() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    private static var applicationIsActive: Bool {
        guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = applicationClass
                .perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? NSObject,
              let active = application.value(forKey: "active") as? Bool
        else {
            return appIsActive
        }
        return active
    }

    static func post(
        message: ChatMessage,
        conversation: XmppConversation,
        isNew: Bool,
        isSynced: Bool
    ) {
        let input = LocalNotificationPolicyInput(
            appIsActive: applicationIsActive,
            isNew: isNew,
            isSynced: isSynced,
            direction: message.direction,
            notifyEffective: conversation.notifyEffective,
            isGroupchat: conversation.isGroupchat,
            mentioned: message.mentioned
        )
        guard shouldPostLocalNotification(input) else { return }

        let body: String
        if message.isFile {
            body = message.fileName.isEmpty ? "Sent an attachment" : "Sent \(message.fileName)"
        } else {
            body = message.body
        }
        guard !body.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = conversation.name
        if conversation.isGroupchat {
            content.subtitle = message.fromDisplay.isEmpty ? message.from : message.fromDisplay
        }
        content.body = body
        content.sound = .default
        content.threadIdentifier = conversation.jid
        content.userInfo = ["conversationJid": conversation.jid]

        let request = UNNotificationRequest(
            identifier: "mac-local-\(conversation.id)-\(message.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                geckoDebugLog(
                    "gecko-notify: local notification failed: %@",
                    error.localizedDescription
                )
            }
        }
    }
}
#endif

enum PushRegistration {
    /// The XMPP account acting as the push proxy (see ios/push-proxy).
    static var proxyJid: String {
        // full jid with fixed resource: iq-sets to a bare account jid are
        // answered by the server itself and never reach the proxy client
        ProcessInfo.processInfo.environment["DINO_PUSH_PROXY_JID"] ?? "geckopush@xmpp.is/proxy"
    }

    static private(set) var deviceToken: String?

    static func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            geckoDebugLog("gecko-push: notification permission granted=%d", granted ? 1 : 0)
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        AppDelegate.onToken = { token in
            deviceToken = token
            enableOnServer()
        }
    }

    /// Idempotent; called when the token arrives and on every reconnect.
    static func enableOnServer() {
        guard let token = deviceToken else { return }
        GeckoCore.shared.enablePush(proxyJid: proxyJid, node: token)
    }

    /// Clears delivered banners and the badge — the app is open, so the
    /// messages are (about to be) seen in the conversation list.
    static func clearDelivered() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }
}
