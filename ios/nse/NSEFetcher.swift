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
        prepareThrowawayStorage()
        dino_ios_init_glib_tls()   // register the iOS trust store for the XMPP TLS connection

        let fetcher = NSEFetcher(completion: completion)
        let ctx = Unmanaged.passRetained(fetcher).toOpaque()
        dino_ios_nse_fetch(timeoutMs, nseTrampoline, ctx, nseRelease)
    }

    /// Point libdino at a private, throwaway copy of the account + OMEMO
    /// databases instead of the app's live store. The extension connects,
    /// MAM-syncs, and decrypts against the copy; it never writes to the shared
    /// dino.db, so messages aren't duplicated when the app later re-syncs them
    /// (the app stays the single source of truth). A same-volume copy is
    /// copy-on-write on APFS, so this is cheap.
    private static func prepareThrowawayStorage() {
        let fm = FileManager.default
        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier: "group.me.anemoneya.gecko") else { return }
        let sharedDino = container.appendingPathComponent("xdg-data/dino")
        let work = container.appendingPathComponent("nse-work")
        let workData = work.appendingPathComponent("xdg-data")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: workData, withIntermediateDirectories: true)
        try? fm.copyItem(at: sharedDino, to: workData.appendingPathComponent("dino"))
        setenv("XDG_DATA_HOME", workData.path, 1)
        setenv("XDG_CONFIG_HOME", work.appendingPathComponent("xdg-config").path, 1)
        setenv("XDG_CACHE_HOME", work.appendingPathComponent("xdg-cache").path, 1)
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
