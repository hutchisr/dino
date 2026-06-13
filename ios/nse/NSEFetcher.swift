import Foundation

/// Thin wrapper over the libdino bridge's `dino_ios_nse_fetch`. Boots the
/// service stack, connects the account, MAM-syncs, and calls back once with
/// the incoming messages collected within the time budget (or on timeout).
///
/// The bridge invokes our C callback on its own GLib thread; we forward the
/// single `nse_result` line and ignore anything else.
final class NSEFetcher {
    /// Retained for the lifetime of the call and released by the bridge's
    /// destroy-notify, mirroring DinoCore's trampoline ownership.
    private let completion: ([NSEMessage]) -> Void
    private var fired = false

    private init(completion: @escaping ([NSEMessage]) -> Void) {
        self.completion = completion
    }

    static func fetch(timeoutMs: Int32, completion: @escaping ([NSEMessage]) -> Void) {
        // Point libdino's storage at the shared App Group container (the app
        // does the same in DinoCore.start), so the NSE opens the real
        // dino.db / omemo.db instead of an empty default-location database.
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.me.anemoneya.gecko") {
            setenv("XDG_DATA_HOME", container.appendingPathComponent("xdg-data").path, 1)
            setenv("XDG_CONFIG_HOME", container.appendingPathComponent("xdg-config").path, 1)
            setenv("XDG_CACHE_HOME", container.appendingPathComponent("xdg-cache").path, 1)
        }
        dino_ios_init_glib_tls()   // register the iOS trust store for the XMPP TLS connection

        let fetcher = NSEFetcher(completion: completion)
        let ctx = Unmanaged.passRetained(fetcher).toOpaque()
        dino_ios_nse_fetch(timeoutMs, nseTrampoline, ctx, nseRelease)
    }

    fileprivate func deliver(_ json: String) {
        NotificationService.debugAppend("evt " + json)   // temporary tracing
        guard !fired else { return }
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "nse_result" else {
            return
        }
        fired = true
        let raw = obj["messages"] as? [[String: Any]] ?? []
        completion(raw.map(NSEMessage.init(json:)))
    }
}

/// One decrypted incoming message, with the conversation's notify policy so
/// the extension can decide whether to present or suppress it.
struct NSEMessage {
    let conversationName: String
    let sender: String
    let body: String
    let notify: String        // "on" | "off" | "highlight" | "default"
    let isGroupchat: Bool
    let mentioned: Bool

    init(json: [String: Any]) {
        conversationName = json["conversation_name"] as? String ?? ""
        sender = json["from"] as? String ?? ""
        body = json["body"] as? String ?? ""
        notify = json["notify"] as? String ?? "on"
        isGroupchat = json["groupchat"] as? Bool ?? false
        mentioned = json["mentioned"] as? Bool ?? false
    }

    /// Apply the conversation's per-chat notification setting.
    var isMuted: Bool {
        switch notify {
        case "off": return true
        case "highlight": return isGroupchat && !mentioned
        default: return false
        }
    }
}

private func nseTrampoline(json: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    guard let json, let userData else { return }
    Unmanaged<NSEFetcher>.fromOpaque(userData).takeUnretainedValue().deliver(String(cString: json))
}

private func nseRelease(userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    Unmanaged<NSEFetcher>.fromOpaque(userData).release()
}
