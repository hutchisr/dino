import Foundation
import SwiftUI

struct XmppAccount: Identifiable {
    let id: String   // bare jid
    var state: String
}

struct XmppConversation: Identifiable {
    let id: Int32
    let account: String
    let jid: String
    var name: String
    var encryption: String
    var kind: String = "chat"
    var unread: Int = 0
    var preview: String = ""
    var previewDirection: String = ""
    var time: Date = Date(timeIntervalSince1970: 0)

    var isGroupchat: Bool { kind == "groupchat" }
}

struct RosterContact: Identifiable {
    let id: String   // bare jid
    let account: String
    var name: String
    var subscription: String
    var show: String

    var displayName: String { name.isEmpty ? id : name }
    var online: Bool { show != "offline" }
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int32    // content item id
    let direction: String
    let from: String
    let body: String
    let time: Date
    let encryption: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var ready = false
    @Published var accounts: [XmppAccount] = []
    @Published var conversations: [XmppConversation] = []
    @Published var messages: [Int32: [ChatMessage]] = [:]
    @Published var lastError: String?
    @Published var navigation: [Int32] = []
    @Published var roster: [RosterContact] = []
    @Published var subscriptionRequests: [String] = []
    @Published var avatars: [String: String] = [:]      // bare jid -> file path
    @Published var chatStates: [Int32: String] = [:]    // conversation id -> XEP-0085 state

    private var pendingChatJid: String?
    private var requestedAvatars = Set<String>()

    private var booted = false

    var hasAccount: Bool { !accounts.isEmpty }
    var connected: Bool { accounts.contains { $0.state == "CONNECTED" } }

    func boot() {
        if booted { return }
        booted = true
        DinoCore.shared.onEvent = { [weak self] e in self?.handle(e) }
        DinoCore.shared.start()
    }

    func addAccount(jid: String, password: String) {
        DinoCore.shared.addAccount(jid: jid, password: password)
    }

    func startConversation(jid: String) {
        DinoCore.shared.startConversation(jid: jid)
    }

    func signOut() {
        DinoCore.shared.signOut()
    }

    func requestState() {
        DinoCore.shared.requestState()
    }

    func focusConversation(_ id: Int32) {
        DinoCore.shared.focusConversation(id)
    }

    func blurConversation(_ id: Int32) {
        DinoCore.shared.blurConversation(id)
    }

    func setTyping(_ id: Int32, _ typing: Bool) {
        DinoCore.shared.setTyping(id, typing)
    }

    func ensureAvatar(for jid: String) {
        if avatars[jid] == nil && !requestedAvatars.contains(jid) {
            requestedAvatars.insert(jid)
            DinoCore.shared.requestAvatar(jid: jid)
        }
    }

    /// Start (or open) a chat with a contact and navigate into it once the
    /// conversation id arrives with the next conversations push.
    func openChat(with jid: String) {
        if let existing = conversations.first(where: { $0.jid == jid }) {
            navigation = [existing.id]
        } else {
            pendingChatJid = jid
            startConversation(jid: jid)
        }
    }

    func addContact(jid: String, alias: String?) {
        DinoCore.shared.addContact(jid: jid, alias: alias)
    }

    func removeContact(jid: String) {
        DinoCore.shared.removeContact(jid: jid)
    }

    func respondSubscription(jid: String, approve: Bool) {
        DinoCore.shared.respondSubscription(jid: jid, approve: approve)
        subscriptionRequests.removeAll { $0 == jid }
    }

    func openConversation(_ id: Int32) {
        DinoCore.shared.requestMessages(conversation: id)
    }

    func send(_ id: Int32, _ body: String) {
        DinoCore.shared.sendText(conversation: id, body: body)
    }

    func setEncryption(_ id: Int32, omemo: Bool) {
        DinoCore.shared.setEncryption(conversation: id, omemo: omemo)
    }

    private func handle(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "ready":
            ready = true
            DinoCore.shared.requestState()
            runAutomation()
        case "accounts":
            if let list = e["list"] as? [[String: Any]] {
                accounts = list.compactMap { a in
                    guard let jid = a["jid"] as? String else { return nil }
                    return XmppAccount(id: jid, state: a["state"] as? String ?? "?")
                }
            }
        case "account_added":
            DinoCore.shared.requestState()
        case "signed_out":
            accounts = []
            conversations = []
            messages = [:]
            navigation = []
            roster = []
            subscriptionRequests = []
            DinoCore.shared.requestState()
        case "connection":
            if let jid = e["account"] as? String, let state = e["state"] as? String {
                if let i = accounts.firstIndex(where: { $0.id == jid }) {
                    accounts[i].state = state
                } else {
                    accounts.append(XmppAccount(id: jid, state: state))
                }
                if state == "CONNECTED" { runConnectedAutomation() }
            }
        case "connection_error":
            lastError = "Connection error (\(e["source"] as? String ?? "?"))"
        case "conversations":
            if let list = e["list"] as? [[String: Any]] {
                conversations = list.compactMap { c in
                    guard let id = c["id"] as? Int, let jid = c["jid"] as? String else { return nil }
                    return XmppConversation(
                        id: Int32(id), account: c["account"] as? String ?? "",
                        jid: jid, name: c["name"] as? String ?? jid,
                        encryption: c["encryption"] as? String ?? "NONE",
                        kind: c["kind"] as? String ?? "chat",
                        unread: c["unread"] as? Int ?? 0,
                        preview: c["preview"] as? String ?? "",
                        previewDirection: c["preview_direction"] as? String ?? "",
                        time: Date(timeIntervalSince1970: TimeInterval(c["time"] as? Int ?? 0)))
                }.sorted { $0.time > $1.time }
                if let pending = pendingChatJid,
                   let conv = conversations.first(where: { $0.jid == pending }) {
                    pendingChatJid = nil
                    navigation = [conv.id]
                }
            }
        case "chat_state":
            if let cid = e["conversation"] as? Int, let state = e["state"] as? String {
                chatStates[Int32(cid)] = state
            }
        case "avatar":
            if let jid = e["jid"] as? String, let path = e["path"] as? String {
                avatars[jid] = path
            }
        case "roster":
            if let list = e["list"] as? [[String: Any]] {
                roster = list.compactMap { r in
                    guard let jid = r["jid"] as? String else { return nil }
                    return RosterContact(
                        id: jid, account: r["account"] as? String ?? "",
                        name: r["name"] as? String ?? "",
                        subscription: r["subscription"] as? String ?? "",
                        show: r["show"] as? String ?? "offline")
                }.sorted { ($0.online ? 0 : 1, $0.displayName.lowercased()) < ($1.online ? 0 : 1, $1.displayName.lowercased()) }
            }
        case "subscription_request":
            if let jid = e["jid"] as? String, !subscriptionRequests.contains(jid) {
                subscriptionRequests.append(jid)
            }
        case "history":
            if let cid = e["conversation"] as? Int, let items = e["items"] as? [[String: Any]] {
                messages[Int32(cid)] = items.compactMap(Self.decodeMessage).sorted { $0.time < $1.time }
            }
        case "message", "item":
            if let m = Self.decodeMessage(e), let cid = e["conversation"] as? Int {
                var list = messages[Int32(cid)] ?? []
                if !list.contains(m) {
                    list.append(m)
                    list.sort { $0.time < $1.time }
                    messages[Int32(cid)] = list
                }
            }
        case "error", "fatal":
            lastError = e["message"] as? String
        default:
            break
        }
    }

    private static func decodeMessage(_ d: [String: Any]) -> ChatMessage? {
        guard let id = d["item"] as? Int, let body = d["body"] as? String else { return nil }
        return ChatMessage(
            id: Int32(id),
            direction: d["direction"] as? String ?? "in",
            from: d["from"] as? String ?? "",
            body: body,
            time: Date(timeIntervalSince1970: TimeInterval(d["time"] as? Int ?? 0)),
            encryption: d["encryption"] as? String ?? "NONE")
    }

    // Environment-driven automation used by the build scripts to exercise the
    // stack headlessly in the Simulator.
    private var autoSent = false

    private func runAutomation() {
        let env = ProcessInfo.processInfo.environment
        if let auto = env["DINO_AUTOLOGIN"], let sep = auto.lastIndex(of: ":") {
            addAccount(jid: String(auto[..<sep]), password: String(auto[auto.index(after: sep)...]))
        }
        if env["DINO_AUTOSIGNOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.signOut()
            }
        }
        if let jid = env["DINO_AUTOADDCONTACT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.addContact(jid: jid, alias: nil)
            }
        }
    }

    private func runConnectedAutomation() {
        let env = ProcessInfo.processInfo.environment
        guard !autoSent, let peer = env["DINO_AUTOPEER"] else { return }
        autoSent = true
        startConversation(jid: peer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let conv = self.conversations.first(where: { $0.jid.hasPrefix(peer) }) else { return }
            self.navigation = [conv.id]
            if env["DINO_AUTOOMEMO"] != nil {
                self.setEncryption(conv.id, omemo: true)
            }
            if let text = env["DINO_AUTOSEND"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.send(conv.id, text)
                }
            }
        }
    }
}
