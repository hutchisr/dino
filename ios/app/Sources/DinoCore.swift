import Foundation

/// Swift wrapper around the libdino iOS bridge (dinoios.h). All bridge calls
/// are fire-and-forget; results and events come back as JSON dictionaries on
/// the main queue via `onEvent`.
final class DinoCore {
    static let shared = DinoCore()
    var onEvent: (([String: Any]) -> Void)?

    private init() {}

    func start() {
        dino_ios_init_glib_tls()
        dino_ios_start(eventTrampoline, Unmanaged.passRetained(self).toOpaque(), releaseContext)
    }

    func addAccount(jid: String, password: String) { dino_ios_add_account(jid, password) }
    func signOut() { dino_ios_sign_out() }
    func requestRoster() { dino_ios_request_roster() }
    func focusConversation(_ id: Int32) { dino_ios_focus_conversation(id) }
    func blurConversation(_ id: Int32) { dino_ios_blur_conversation(id) }
    func setTyping(_ id: Int32, _ typing: Bool) { dino_ios_set_typing(id, typing ? 1 : 0) }
    func requestAvatar(jid: String) { dino_ios_request_avatar(jid) }
    func sendFile(_ id: Int32, path: String) { dino_ios_send_file(id, path) }
    func downloadFile(_ id: Int32, item: Int32) { dino_ios_download_file(id, item) }
    func joinMuc(jid: String, nick: String?) { dino_ios_join_muc(jid, nick) }
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
