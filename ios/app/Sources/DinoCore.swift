import Foundation

/// Thin Swift wrapper around the C bridge (dino_poc.h). Lines arrive on the
/// GLib main-loop thread and are forwarded to `onLine` on the main queue.
final class DinoCore {
    static let shared = DinoCore()
    var onLine: ((String) -> Void)?

    private init() {}

    func start() {
        if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            setenv("SSL_CERT_FILE", ca, 1)
        }
        dino_poc_init()
    }

    func login(jid: String, password: String) {
        dino_poc_login(jid, password, lineTrampoline, retainSelf(), releaseBox)
    }

    func send(to: String, body: String) {
        dino_poc_send_message(to, body, lineTrampoline, retainSelf(), releaseBox)
    }

    fileprivate func emit(_ line: String) {
        DispatchQueue.main.async { self.onLine?(line) }
    }

    private func retainSelf() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }
}

private func lineTrampoline(line: UnsafePointer<CChar>?, userData: gpointer?) {
    guard let line, let userData else { return }
    let core = Unmanaged<DinoCore>.fromOpaque(userData).takeUnretainedValue()
    core.emit(String(cString: line))
}

private func releaseBox(userData: gpointer?) {
    guard let userData else { return }
    Unmanaged<DinoCore>.fromOpaque(userData).release()
}
