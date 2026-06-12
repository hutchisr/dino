import Foundation

/// Swift wrapper around the libdino iOS bridge (dinoios.h). All bridge calls
/// are fire-and-forget; results and events come back as JSON dictionaries on
/// the main queue via `onEvent`.
final class DinoCore {
    static let shared = DinoCore()
    var onEvent: (([String: Any]) -> Void)?

    private init() {}

    func start() {
        if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            setenv("SSL_CERT_FILE", ca, 1)
        }
        dino_ios_init_glib_tls()
        dino_ios_start(eventTrampoline, Unmanaged.passRetained(self).toOpaque(), releaseContext)
    }

    func addAccount(jid: String, password: String) { dino_ios_add_account(jid, password) }
    func requestState() { dino_ios_request_state() }
    func startConversation(jid: String) { dino_ios_start_conversation(jid) }
    func requestMessages(conversation: Int32, count: Int32 = 50) { dino_ios_request_messages(conversation, count) }
    func sendText(conversation: Int32, body: String) { dino_ios_send_text(conversation, body) }
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
