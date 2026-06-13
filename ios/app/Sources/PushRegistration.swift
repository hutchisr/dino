import Foundation
import UIKit
import UserNotifications

/// APNs registration: ask for notification permission, register with APNs,
/// and enable XEP-0357 push on the XMPP server with the device token as the
/// node (the proxy decodes the node back into a token, so no registration
/// round-trip is needed).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var onToken: ((String) -> Void)?

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
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("gecko-push: APNs token %@", hex)
        AppDelegate.onToken?(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("gecko-push: APNs registration failed: %@", error.localizedDescription)
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
            NSLog("gecko-push: notification permission granted=%d", granted ? 1 : 0)
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
        DinoCore.shared.enablePush(proxyJid: proxyJid, node: token)
    }

    /// Clears delivered banners and the badge — the app is open, so the
    /// messages are (about to be) seen in the conversation list.
    static func clearDelivered() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }
}
