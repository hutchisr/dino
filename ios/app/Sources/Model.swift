import Foundation
import UIKit
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
    var encryptionAvailable: Bool = false
    var kind: String = "chat"
    var unread: Int = 0
    var preview: String = ""
    var previewDirection: String = ""
    var time: Date = Date(timeIntervalSince1970: 0)
    var notify: String = "default"
    var notifyEffective: String = "on"

    var isGroupchat: Bool { kind == "groupchat" }
}

/// A pending request to create a group chat the user tried to join but that
/// doesn't exist yet.
struct PendingMucCreate: Identifiable {
    let id = UUID()
    let jid: String
    let nick: String?
}

/// A participant in a group chat.
struct Occupant: Identifiable {
    var id: String { jid }
    let nick: String
    let jid: String        // full room jid (room@conf/nick), used for the avatar
    let realJid: String?   // bare real jid, known only in non-anonymous rooms
    let isSelf: Bool
    var affiliation: String = "none"  // owner | admin | member | outcast | none
    var role: String = "none"         // moderator | participant | visitor | none

    var isOwner: Bool { affiliation == "owner" }
    var isAdmin: Bool { affiliation == "admin" }
    var isModerator: Bool { role == "moderator" }
    var hasVoice: Bool { role == "moderator" || role == "participant" }
    /// A visitor has had voice revoked (or never granted) in a moderated room —
    /// i.e. they can't send messages.
    var isMuted: Bool { role == "visitor" }

    /// A short badge label for the row, or nil when there's nothing notable.
    /// Staff always have voice, so "Muted" only ever applies to members/guests.
    var badge: String? {
        switch affiliation {
        case "owner": return "Owner"
        case "admin": return "Admin"
        default:
            if isModerator { return "Mod" }
            if isMuted { return "Muted" }
            return nil
        }
    }
}

/// Room-wide settings/state for a group chat, fetched on demand.
struct RoomInfo {
    var subject: String = ""
    var isPrivate: Bool = false
    var isModerated: Bool = false
    var myAffiliation: String = "none"
    var myRole: String = "none"

    var iAmOwner: Bool { myAffiliation == "owner" }
    var canEditSubject: Bool {
        // Moderators (and owners/admins, who hold the role) can set the subject;
        // many open rooms also let participants. Show it for anyone with voice.
        myRole == "moderator" || myAffiliation == "owner" || myAffiliation == "admin"
    }
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

struct Reaction: Equatable {
    let emoji: String
    let count: Int
    let me: Bool
}

struct QuoteRef: Equatable {
    let item: Int32
    let from: String
    let body: String
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int32    // content item id
    let content: String  // "text" or "file"
    let direction: String
    let from: String
    var fromDisplay: String = ""
    let body: String
    let time: Date
    let encryption: String
    var fileName: String = ""
    var mime: String = ""
    var size: Int = 0
    var fileState: String = ""
    var path: String = ""
    var editable: Bool = false
    var reactions: [Reaction] = []
    var marked: String = "none"
    var quote: QuoteRef? = nil

    var isFile: Bool { content == "file" }
    var isImage: Bool {
        if mime.hasPrefix("image/") { return true }
        // iOS has no shared-mime-info database, so GIO often reports
        // application/octet-stream; fall back to the file extension.
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(ext)
    }
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
    @Published var occupants: [Int32: [Occupant]] = [:]
    @Published var roomInfo: [Int32: RoomInfo] = [:]
    @Published var selfShow = "online"     // online | away | dnd | xa
    @Published var selfStatus = ""
    @Published var blockedContacts: [String] = []
    @Published var blockingSupported = false
    @Published var sendTyping = true
    @Published var sendMarker = true
    @Published var viewerRequest: String?   // used by UI automation to open the image viewer
    @Published var accountAlias: String = ""
    @Published var omemoDeviceId: Int = 0
    @Published var omemoFingerprint: String = ""
    @Published var passwordChanged = false
    /// Set when a join targeted a room that doesn't exist yet; the UI asks the
    /// user to confirm creating it.
    @Published var pendingMucCreate: PendingMucCreate?

    private var pendingChatJid: String?
    private var requestedAvatars = Set<String>()
    private var messageRevisions: [Int32: Int] = [:]
    private var avatarRevision = 0

    private var booted = false

    var hasAccount: Bool { !accounts.isEmpty }
    var connected: Bool { accounts.contains { $0.state == "CONNECTED" } }
    var avatarRevisionToken: Int { avatarRevision }

    func messageRevision(for conversation: Int32) -> Int {
        messageRevisions[conversation] ?? 0
    }

    private func replaceNavigation(with path: [Int32]) {
        guard navigation != path else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigation != path else { return }
            self.navigation = path
        }
    }

    private func pushNavigation(_ id: Int32) {
        guard navigation.last != id else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigation.last != id else { return }
            self.navigation.append(id)
        }
    }

    func boot() {
        if booted { return }
        booted = true
        GeckoCore.shared.onEvent = { [weak self] e in self?.handle(e) }
        DispatchQueue.global(qos: .userInitiated).async {
            GeckoCore.shared.start()
        }
    }

    func addAccount(jid: String, password: String) {
        GeckoCore.shared.addAccount(jid: jid, password: password)
    }

    func startConversation(jid: String) {
        GeckoCore.shared.startConversation(jid: jid)
    }

    func signOut() {
        GeckoCore.shared.signOut()
    }

    func setAvatar(path: String) {
        let source = path
        Task {
            let pngPath = await Task.detached(priority: .userInitiated) {
                avatarPNG(from: source)
            }.value
            GeckoCore.shared.setAvatar(path: pngPath ?? source)
            // re-request our own avatar once published
            if let jid = accounts.first?.id {
                requestedAvatars.remove(jid)
                setAvatarPath(nil, for: jid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    GeckoCore.shared.requestAvatar(jid: jid)
                }
            }
        }
    }

    func setAlias(_ alias: String) {
        GeckoCore.shared.setAlias(alias)
    }

    func changePassword(_ pw: String) {
        GeckoCore.shared.changePassword(pw)
    }

    func requestAccountDetails() {
        GeckoCore.shared.requestAccountDetails()
    }

    func requestState() {
        GeckoCore.shared.requestState()
    }

    func focusConversation(_ id: Int32) {
        GeckoCore.shared.focusConversation(id)
    }

    func blurConversation(_ id: Int32) {
        GeckoCore.shared.blurConversation(id)
    }

    func setTyping(_ id: Int32, _ typing: Bool) {
        GeckoCore.shared.setTyping(id, typing)
    }

    func sendFile(_ id: Int32, path: String) {
        GeckoCore.shared.sendFile(id, path: path)
    }

    func downloadFile(_ id: Int32, item: Int32) {
        GeckoCore.shared.downloadFile(id, item: item)
    }

    func joinMuc(jid: String, nick: String?) {
        GeckoCore.shared.joinMuc(jid: jid, nick: nick)
    }

    func createMuc(jid: String, nick: String?) {
        GeckoCore.shared.createMuc(jid: jid, nick: nick)
    }

    func closeConversation(_ id: Int32) {
        GeckoCore.shared.closeConversation(id)
        if navigation.contains(id) { replaceNavigation(with: []) }
    }

    func startOccupantDM(_ id: Int32, nick: String) {
        GeckoCore.shared.startOccupantDM(id, nick: nick)
    }

    func mucKick(_ id: Int32, nick: String) {
        GeckoCore.shared.mucKick(id, nick: nick)
        refreshOccupantsSoon(id)
    }

    func mucSetAffiliation(_ id: Int32, nick: String, affiliation: String) {
        GeckoCore.shared.mucSetAffiliation(id, nick: nick, affiliation: affiliation)
        refreshOccupantsSoon(id)
    }

    func mucSetRole(_ id: Int32, nick: String, role: String) {
        GeckoCore.shared.mucSetRole(id, nick: nick, role: role)
        refreshOccupantsSoon(id)
    }

    /// Re-fetch the occupant list shortly after a moderation action so the UI
    /// reflects the server's broadcast presence change.
    private func refreshOccupantsSoon(_ id: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.requestOccupants(id)
        }
    }

    func requestRoomInfo(_ id: Int32) { GeckoCore.shared.requestRoomInfo(id) }
    func setRoomSubject(_ id: Int32, _ subject: String) { GeckoCore.shared.mucSetSubject(id, subject: subject) }
    func inviteToRoom(_ id: Int32, jid: String) { GeckoCore.shared.mucInvite(id, jid: jid) }
    func setRoomName(_ id: Int32, _ name: String) { GeckoCore.shared.mucSetName(id, name: name) }
    func setRoomPrivate(_ id: Int32, _ priv: Bool) {
        roomInfo[id]?.isPrivate = priv   // optimistic; bridge re-emits room_info to confirm
        GeckoCore.shared.mucSetPrivate(id, priv)
    }
    func setRoomModerated(_ id: Int32, _ moderated: Bool) {
        roomInfo[id]?.isModerated = moderated
        GeckoCore.shared.mucSetModerated(id, moderated)
    }
    func setRoomAvatar(_ id: Int32, path: String) {
        let source = path
        Task {
            let pngPath = await Task.detached(priority: .userInitiated) {
                avatarPNG(from: source)
            }.value
            GeckoCore.shared.mucSetAvatar(id, path: pngPath ?? source)
        }
    }

    func requestOccupants(_ id: Int32) {
        GeckoCore.shared.requestOccupants(id)
    }

    func setReaction(_ id: Int32, item: Int32, emoji: String, add: Bool) {
        GeckoCore.shared.setReaction(id, item: item, emoji: emoji, add: add)
    }

    func correctMessage(_ id: Int32, item: Int32, body: String) {
        GeckoCore.shared.correctMessage(id, item: item, body: body)
    }

    func ensureAvatar(for jid: String) {
        if avatars[jid] == nil && !requestedAvatars.contains(jid) {
            requestedAvatars.insert(jid)
            GeckoCore.shared.requestAvatar(jid: jid)
        }
    }

    /// Start (or open) a chat with a contact and navigate into it once the
    /// conversation id arrives with the next conversations push.
    /// XMPP "show" for a 1:1 contact from the roster (nil if not a known contact).
    func presence(for jid: String) -> String? {
        roster.first { $0.id == jid }?.show
    }

    func setPresence(show: String, status: String) {
        selfShow = show
        selfStatus = status
        GeckoCore.shared.setPresence(show: show, status: status)
    }

    func requestSelfPresence() { GeckoCore.shared.requestSelfPresence() }

    func requestBlocklist() { GeckoCore.shared.requestBlocklist() }
    func blockContact(_ jid: String) {
        if !blockedContacts.contains(jid) { blockedContacts = (blockedContacts + [jid]).sorted() }
        GeckoCore.shared.blockContact(jid)
    }
    func unblockContact(_ jid: String) {
        blockedContacts.removeAll { $0 == jid }   // optimistic
        GeckoCore.shared.unblockContact(jid)
    }
    func isBlocked(_ jid: String) -> Bool { blockedContacts.contains(jid) }

    func requestPrivacy() { GeckoCore.shared.requestPrivacy() }
    func setSendTyping(_ on: Bool) { sendTyping = on; GeckoCore.shared.setSendTyping(on) }
    func setSendMarker(_ on: Bool) { sendMarker = on; GeckoCore.shared.setSendMarker(on) }

    func openChat(with jid: String) {
        if let existing = conversations.first(where: { $0.jid == jid }) {
            replaceNavigation(with: [existing.id])
        } else {
            pendingChatJid = jid
            startConversation(jid: jid)
        }
    }

    func addContact(jid: String, alias: String?) {
        GeckoCore.shared.addContact(jid: jid, alias: alias)
    }

    func removeContact(jid: String) {
        GeckoCore.shared.removeContact(jid: jid)
    }

    func respondSubscription(jid: String, approve: Bool) {
        GeckoCore.shared.respondSubscription(jid: jid, approve: approve)
        subscriptionRequests.removeAll { $0 == jid }
    }

    func openConversation(_ id: Int32) {
        GeckoCore.shared.requestMessages(conversation: id)
    }

    func send(_ id: Int32, _ body: String, replyTo: Int32 = 0) {
        GeckoCore.shared.sendText(conversation: id, body: body, replyTo: replyTo)
    }

    func setEncryption(_ id: Int32, omemo: Bool) {
        GeckoCore.shared.setEncryption(conversation: id, omemo: omemo)
    }

    func setNotify(_ id: Int32, _ setting: String) {
        GeckoCore.shared.setNotify(id, setting)
    }

    private func handle(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "ready":
            ready = true
            GeckoCore.shared.requestState()
            runAutomation()
        case "accounts":
            if let list = e["list"] as? [[String: Any]] {
                accounts = list.compactMap { a in
                    guard let jid = a["jid"] as? String else { return nil }
                    return XmppAccount(id: jid, state: a["state"] as? String ?? "?")
                }
            }
        case "account_added":
            GeckoCore.shared.requestState()
        case "account_details":
            accountAlias = e["alias"] as? String ?? ""
            omemoDeviceId = e["omemo_device_id"] as? Int ?? 0
            omemoFingerprint = e["omemo_fingerprint"] as? String ?? ""
        case "password_changed":
            passwordChanged = true
        case "signed_out":
            accounts = []
            conversations = []
            messages = [:]
            messageRevisions = [:]
            replaceNavigation(with: [])
            roster = []
            subscriptionRequests = []
            GeckoCore.shared.requestState()
        case "connection":
            if let jid = e["account"] as? String, let state = e["state"] as? String {
                if let i = accounts.firstIndex(where: { $0.id == jid }) {
                    accounts[i].state = state
                } else {
                    accounts.append(XmppAccount(id: jid, state: state))
                }
                if state == "CONNECTED" {
                    PushRegistration.start()
                    PushRegistration.enableOnServer()
                    runConnectedAutomation()
                    // The libdino auto-rejoin runs on a worker thread where it's
                    // unreliable; drive it from here once the rejoins should
                    // have had a chance to settle (and again, in case the first
                    // pass was still mid-join).
                    for delay in [3.0, 7.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            GeckoCore.shared.rejoinActiveRooms()
                        }
                    }
                }
            }
        case "connection_error":
            // Transient and auto-recovering (e.g. a brief stream drop or a
            // resource handover with the notification extension) — the live
            // connection state is already shown in the account row, so don't
            // interrupt with a modal alert.
            geckoDebugLog("Gecko: connection error (%@)", e["source"] as? String ?? "?")
        case "conversations":
            if let list = e["list"] as? [[String: Any]] {
                conversations = list.compactMap { c in
                    guard let id = c["id"] as? Int, let jid = c["jid"] as? String else { return nil }
                    return XmppConversation(
                        id: Int32(id), account: c["account"] as? String ?? "",
                        jid: jid, name: c["name"] as? String ?? jid,
                        encryption: c["encryption"] as? String ?? "NONE",
                        encryptionAvailable: c["encryption_available"] as? Bool ?? false,
                        kind: c["kind"] as? String ?? "chat",
                        unread: c["unread"] as? Int ?? 0,
                        preview: c["preview"] as? String ?? "",
                        previewDirection: c["preview_direction"] as? String ?? "",
                        time: Date(timeIntervalSince1970: TimeInterval(c["time"] as? Int ?? 0)),
                        notify: c["notify"] as? String ?? "default",
                        notifyEffective: c["notify_effective"] as? String ?? "on")
                }.sorted { $0.time > $1.time }
                if let pending = pendingChatJid,
                   let conv = conversations.first(where: { $0.jid == pending }) {
                    pendingChatJid = nil
                    replaceNavigation(with: [conv.id])
                }
            }
        case "confirm_create_muc":
            if let jid = e["jid"] as? String {
                let nick = e["nick"] as? String
                pendingMucCreate = PendingMucCreate(jid: jid, nick: (nick?.isEmpty ?? true) ? nil : nick)
            }
        case "push_state":
            geckoDebugLog("gecko-push: server push enabled=%@", String(describing: e["enabled"]))
        case "chat_state":
            if let cid = e["conversation"] as? Int, let state = e["state"] as? String {
                chatStates[Int32(cid)] = state
            }
        case "occupants":
            if let cid = e["conversation"] as? Int, let list = e["list"] as? [[String: Any]] {
                occupants[Int32(cid)] = list.compactMap { o in
                    guard let nick = o["nick"] as? String else { return nil }
                    let real = o["real_jid"] as? String
                    return Occupant(
                        nick: nick,
                        jid: o["jid"] as? String ?? nick,
                        realJid: (real?.isEmpty ?? true) ? nil : real,
                        isSelf: o["self"] as? Bool ?? false,
                        affiliation: o["affiliation"] as? String ?? "none",
                        role: o["role"] as? String ?? "none")
                }.sorted { $0.nick.lowercased() < $1.nick.lowercased() }
            }
        case "diag":
            geckoDebugLog("Gecko-diag: %@", e["message"] as? String ?? "?")
        case "self_presence":
            selfShow = e["show"] as? String ?? "online"
            selfStatus = e["status"] as? String ?? ""
        case "blocklist":
            blockingSupported = e["supported"] as? Bool ?? false
            blockedContacts = (e["list"] as? [String] ?? []).sorted()
        case "privacy":
            sendTyping = e["send_typing"] as? Bool ?? true
            sendMarker = e["send_marker"] as? Bool ?? true
        case "room_info":
            if let cid = e["conversation"] as? Int {
                roomInfo[Int32(cid)] = RoomInfo(
                    subject: e["subject"] as? String ?? "",
                    isPrivate: e["is_private"] as? Bool ?? false,
                    isModerated: e["is_moderated"] as? Bool ?? false,
                    myAffiliation: e["my_affiliation"] as? String ?? "none",
                    myRole: e["my_role"] as? String ?? "none")
            }
        case "open_conversation":
            if let id = e["id"] as? Int {
                // Push so the new chat slides in over the current one (and Back
                // returns to where you were, e.g. the group chat).
                pushNavigation(Int32(id))
            }
        case "avatar":
            if let jid = e["jid"] as? String, let path = e["path"] as? String {
                setAvatarPath(path, for: jid)
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
                replaceMessages(
                    items.compactMap(Self.decodeMessage).sorted { $0.time < $1.time },
                    for: Int32(cid))
            }
        case "message", "item":
            if let m = Self.decodeMessage(e), let cid = e["conversation"] as? Int {
                var list = messages[Int32(cid)] ?? []
                if let i = list.firstIndex(where: { $0.id == m.id }) {
                    list[i] = m
                } else {
                    list.append(m)
                    list.sort { $0.time < $1.time }
                }
                replaceMessages(list, for: Int32(cid))
            }
        case "error", "fatal":
            lastError = e["message"] as? String
        default:
            break
        }
    }

    private func replaceMessages(_ list: [ChatMessage], for cid: Int32) {
        guard messages[cid] != list else { return }
        messageRevisions[cid, default: 0] &+= 1
        messages[cid] = list
    }

    private func setAvatarPath(_ path: String?, for jid: String) {
        guard avatars[jid] != path else { return }
        avatarRevision &+= 1
        avatars[jid] = path
    }

    private static func decodeMessage(_ d: [String: Any]) -> ChatMessage? {
        guard let id = d["item"] as? Int else { return nil }
        let content = d["content"] as? String ?? "text"
        if content != "text" && content != "file" { return nil }
        if content == "text" && d["body"] == nil { return nil }
        return ChatMessage(
            id: Int32(id),
            content: content,
            direction: d["direction"] as? String ?? "in",
            from: d["from"] as? String ?? "",
            fromDisplay: d["from_display"] as? String ?? "",
            body: d["body"] as? String ?? "",
            time: Date(timeIntervalSince1970: TimeInterval(d["time"] as? Int ?? 0)),
            encryption: d["encryption"] as? String ?? "NONE",
            fileName: d["file_name"] as? String ?? "",
            mime: d["mime"] as? String ?? "",
            size: d["size"] as? Int ?? 0,
            fileState: d["file_state"] as? String ?? "",
            path: d["path"] as? String ?? "",
            editable: d["editable"] as? Bool ?? false,
            reactions: (d["reactions"] as? [[String: Any]] ?? []).compactMap { r in
                guard let emoji = r["emoji"] as? String else { return nil }
                return Reaction(emoji: emoji, count: r["count"] as? Int ?? 1, me: r["me"] as? Bool ?? false)
            },
            marked: d["marked"] as? String ?? "none",
            quote: (d["quote"] as? [String: Any]).flatMap { q in
                guard let item = q["item"] as? Int else { return nil }
                return QuoteRef(item: Int32(item), from: q["from"] as? String ?? "", body: q["body"] as? String ?? "")
            })
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
        if let jid = env["DINO_AUTOOPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let conv = self.conversations.first(where: { $0.jid == jid }) else { return }
                self.replaceNavigation(with: [conv.id])
            }
        }
        if let jid = env["DINO_AUTOJOINMUC"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.joinMuc(jid: jid, nick: nil)
            }
        }
        if let jid = env["DINO_AUTOCLOSE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, let conv = self.conversations.first(where: { $0.jid == jid }) else { return }
                self.closeConversation(conv.id)
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
            self.replaceNavigation(with: [conv.id])
            if env["DINO_AUTOOMEMO"] != nil {
                self.setEncryption(conv.id, omemo: true)
            }
            if let text = env["DINO_AUTOSEND"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.send(conv.id, text)
                }
            }
            if let text = env["DINO_AUTOREPLY"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    guard let last = self.messages[conv.id]?.last else { return }
                    self.send(conv.id, text, replyTo: last.id)
                }
            }
            if let emoji = env["DINO_AUTOREACT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    guard let last = self.messages[conv.id]?.last else { return }
                    self.setReaction(conv.id, item: last.id, emoji: emoji, add: true)
                }
            }
            if let text = env["DINO_AUTOCORRECT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    guard let last = self.messages[conv.id]?.last(where: { $0.editable }) else { return }
                    self.correctMessage(conv.id, item: last.id, body: text)
                }
            }
            if env["DINO_AUTOVIEWIMAGE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if let img = self.messages[conv.id]?.last(where: { $0.isImage && $0.fileState == "complete" && !$0.path.isEmpty }) {
                        self.viewerRequest = img.path
                    }
                }
            }
            if env["DINO_AUTOSENDFILE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160))
                    let image = renderer.image { ctx in
                        UIColor.systemTeal.setFill()
                        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
                        ("Dino iOS file test" as NSString).draw(
                            at: CGPoint(x: 20, y: 70),
                            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white])
                    }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dino-ios-test.png")
                    try? image.pngData()?.write(to: url)
                    self.sendFile(conv.id, path: url.path)
                }
            }
        }
    }
}

// avatarPNG(from:) lives in GeckoKit/Sources/GeckoKit/ImageEncoding.swift —
// compiled into this app module by build-app.sh and tested on the iOS Simulator.
