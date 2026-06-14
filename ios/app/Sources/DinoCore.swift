import Foundation

/// Swift wrapper around the libdino iOS bridge (dinoios.h). All bridge calls
/// are fire-and-forget; results and events come back as JSON dictionaries on
/// the main queue via `onEvent`.
final class DinoCore {
    static let shared = DinoCore()
    var onEvent: (([String: Any]) -> Void)?

    private init() {}

    /// App Group shared with the Notification Service Extension. The NSE reads
    /// the same dino.db / omemo.db to decrypt and filter pushes on-device, so
    /// the GLib storage dirs must live in this shared container.
    static let appGroupID = "group.me.anemoneya.gecko"

    func start() {
        // GLib's XDG dirs default to $HOME/.local/... — the container root is
        // not writable on a real device, so point them at the App Group
        // container (shared with the NSE), falling back to Library/Caches.
        let dirs = DinoCore.storageDirs()
        setenv("XDG_DATA_HOME", dirs.data, 1)
        setenv("XDG_CONFIG_HOME", dirs.config, 1)
        setenv("XDG_CACHE_HOME", dirs.cache, 1)
        dino_ios_init_glib_tls()
        dino_ios_start(eventTrampoline, Unmanaged.passRetained(self).toOpaque(), releaseContext)
    }

    /// Resolve the three XDG roots. Prefer the App Group container so the NSE
    /// sees the same databases; fall back to the app's own Library/Caches if
    /// the App Group entitlement isn't present. Data left in the old per-app
    /// location is migrated into the container on first run.
    static func storageDirs() -> (data: String, config: String, cache: String) {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let legacy = (data: library.appendingPathComponent("xdg-data"),
                      config: library.appendingPathComponent("xdg-config"),
                      cache: caches.appendingPathComponent("xdg-cache"))

        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            NSLog("DinoCore: App Group unavailable, using per-app storage")
            return (legacy.data.path, legacy.config.path, legacy.cache.path)
        }
        let shared = (data: container.appendingPathComponent("xdg-data"),
                      config: container.appendingPathComponent("xdg-config"),
                      cache: container.appendingPathComponent("xdg-cache"))
        migrateStorage(legacy.data, to: shared.data, fm: fm)
        migrateStorage(legacy.config, to: shared.config, fm: fm)
        migrateStorage(legacy.cache, to: shared.cache, fm: fm)
        return (shared.data.path, shared.config.path, shared.cache.path)
    }

    /// Move an old XDG root into the shared container, but only when the new
    /// location is empty — never clobber a container the NSE may already use.
    private static func migrateStorage(_ from: URL, to: URL, fm: FileManager) {
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        do {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
            NSLog("DinoCore: migrated %@ -> %@", from.path, to.path)
        } catch {
            NSLog("DinoCore: storage migration failed for %@: %@", from.path, error.localizedDescription)
        }
    }

    func addAccount(jid: String, password: String) { dino_ios_add_account(jid, password) }
    func signOut() { dino_ios_sign_out() }
    func setAvatar(path: String) { dino_ios_set_avatar(path) }
    func setAlias(_ alias: String) { dino_ios_set_alias(alias) }
    func changePassword(_ pw: String) { dino_ios_change_password(pw) }
    func requestAccountDetails() { dino_ios_request_account_details() }
    func appForegrounded() { dino_ios_app_foregrounded() }
    func appBackgrounded() { dino_ios_app_backgrounded() }
    func enablePush(proxyJid: String, node: String) { dino_ios_enable_push(proxyJid, node) }
    func setNotify(_ id: Int32, _ setting: String) { dino_ios_set_notify(id, setting) }
    func requestRoster() { dino_ios_request_roster() }
    func focusConversation(_ id: Int32) { dino_ios_focus_conversation(id) }
    func blurConversation(_ id: Int32) { dino_ios_blur_conversation(id) }
    func setTyping(_ id: Int32, _ typing: Bool) { dino_ios_set_typing(id, typing ? 1 : 0) }
    func requestAvatar(jid: String) { dino_ios_request_avatar(jid) }
    func sendFile(_ id: Int32, path: String) { dino_ios_send_file(id, path) }
    func downloadFile(_ id: Int32, item: Int32) { dino_ios_download_file(id, item) }
    func joinMuc(jid: String, nick: String?) { dino_ios_join_muc(jid, nick) }
    func createMuc(jid: String, nick: String?) { dino_ios_create_muc(jid, nick) }
    func setReaction(_ id: Int32, item: Int32, emoji: String, add: Bool) { dino_ios_set_reaction(id, item, emoji, add ? 1 : 0) }
    func correctMessage(_ id: Int32, item: Int32, body: String) { dino_ios_correct_message(id, item, body) }
    func closeConversation(_ id: Int32) { dino_ios_close_conversation(id) }
    func requestOccupants(_ id: Int32) { dino_ios_request_occupants(id) }
    func addContact(jid: String, alias: String?) { dino_ios_add_contact(jid, alias) }
    func removeContact(jid: String) { dino_ios_remove_contact(jid) }
    func respondSubscription(jid: String, approve: Bool) { dino_ios_respond_subscription(jid, approve ? 1 : 0) }
    func requestState() { dino_ios_request_state() }
    func startConversation(jid: String) { dino_ios_start_conversation(jid) }
    func requestMessages(conversation: Int32, count: Int32 = 50) { dino_ios_request_messages(conversation, count) }
    func sendText(conversation: Int32, body: String, replyTo: Int32 = 0) { dino_ios_send_text(conversation, body, replyTo) }
    func setEncryption(conversation: Int32, omemo: Bool) { dino_ios_set_encryption(conversation, omemo ? 1 : 0) }

    fileprivate func emit(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            NSLog("DinoCore: undecodable event: %@", json)
            return
        }
        DispatchQueue.main.async { self.onEvent?(dict) }
    }
}

private func eventTrampoline(json: UnsafePointer<CChar>?, userData: gpointer?) {
    guard let json, let userData else { return }
    Unmanaged<DinoCore>.fromOpaque(userData).takeUnretainedValue().emit(String(cString: json))
}

private func releaseContext(userData: gpointer?) {
    guard let userData else { return }
    Unmanaged<DinoCore>.fromOpaque(userData).release()
}
