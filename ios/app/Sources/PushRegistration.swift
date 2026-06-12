import Foundation
import UIKit
import UserNotifications

/// APNs registration: ask for notification permission, register with APNs,
/// and enable XEP-0357 push on the XMPP server with the device token as the
/// node (the proxy decodes the node back into a token, so no registration
/// round-trip is needed).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var onToken: ((String) -> Void)?

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
}

enum PushRegistration {
    /// The XMPP account acting as the push proxy (see ios/push-proxy).
    static var proxyJid: String {
        ProcessInfo.processInfo.environment["DINO_PUSH_PROXY_JID"] ?? "geckopush@xmpp.is"
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
}
