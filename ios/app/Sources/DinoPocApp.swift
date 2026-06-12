import SwiftUI

@main
struct DinoPocApp: App {
    @StateObject private var model = PocModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { model.boot() }
        }
    }
}

struct Contact: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class PocModel: ObservableObject {
    @Published var log: [String] = []
    @Published var contacts: [Contact] = []
    @Published var connected = false
    @Published var connecting = false

    private var booted = false

    func boot() {
        if booted { return }
        booted = true
        DinoCore.shared.onLine = { [weak self] line in self?.handle(line) }
        DinoCore.shared.start()
        append("Dino core initialized (GLib \(glibVersion()))")
        if let auto = ProcessInfo.processInfo.environment["DINO_POC_AUTOLOGIN"],
           let sep = auto.lastIndex(of: ":") {
            let jid = String(auto[..<sep])
            let pass = String(auto[auto.index(after: sep)...])
            append("Auto-login as \(jid)")
            login(jid: jid, password: pass)
        }
    }

    func login(jid: String, password: String) {
        connecting = true
        DinoCore.shared.login(jid: jid, password: password)
    }

    func send(to: String, body: String) {
        DinoCore.shared.send(to: to, body: body)
    }

    private func handle(_ line: String) {
        let parts = line.components(separatedBy: "\t")
        switch parts.first {
        case "CONNECTED":
            connected = true
            connecting = false
            append("✅ Logged in as \(parts.count > 1 ? parts[1] : "?")")
        case "CONTACT" where parts.count >= 2:
            let jid = parts[1]
            let name = parts.count > 2 && !parts[2].isEmpty ? parts[2] : jid
            if !contacts.contains(where: { $0.id == jid }) {
                contacts.append(Contact(id: jid, name: name))
            }
        case "MSG" where parts.count >= 3:
            append("💬 \(parts[1]): \(parts[2])")
        case "SENT" where parts.count >= 3:
            append("📤 → \(parts[1]): \(parts[2])")
        case "ERROR":
            connecting = false
            append("⚠️ \(parts.count > 1 ? parts[1] : line)")
        default:
            append(parts.count > 1 ? parts[1] : line)
        }
    }

    private func append(_ s: String) {
        log.append(s)
        if log.count > 500 { log.removeFirst() }
    }

    private func glibVersion() -> String {
        "\(glib_major_version).\(glib_minor_version).\(glib_micro_version)"
    }
}

struct ContentView: View {
    @EnvironmentObject var model: PocModel
    @State private var jid = ""
    @State private var password = ""
    @State private var msgTo = ""
    @State private var msgBody = ""

    var body: some View {
        NavigationStack {
            Form {
                if !model.connected {
                    Section("Account") {
                        TextField("user@example.org", text: $jid)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                        SecureField("Password", text: $password)
                        Button(model.connecting ? "Connecting…" : "Connect") {
                            model.login(jid: jid, password: password)
                        }
                        .disabled(model.connecting || jid.isEmpty)
                    }
                }

                if !model.contacts.isEmpty {
                    Section("Contacts (\(model.contacts.count))") {
                        ForEach(model.contacts) { c in
                            Button {
                                msgTo = c.id
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(c.name)
                                    Text(c.id).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if model.connected {
                    Section("Send message") {
                        TextField("To (JID)", text: $msgTo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Message", text: $msgBody)
                        Button("Send") {
                            model.send(to: msgTo, body: msgBody)
                            msgBody = ""
                        }
                        .disabled(msgTo.isEmpty || msgBody.isEmpty)
                    }
                }

                Section("Log") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Dino iOS PoC")
        }
    }
}
