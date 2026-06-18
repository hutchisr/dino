import SwiftUI
import UIKit
import PhotosUI

@main
struct GeckoApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear {
                    model.boot()
                    AppDelegate.setOpenHandler { jid in model.openChat(with: jid) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Cancel any pending background-disconnect (quick toggle) and
                // keep the live connection rather than churning it.
                appDelegate.cancelBackgroundDisconnect()
                PushRegistration.clearDelivered()
                if model.ready && model.hasAccount {
                    GeckoCore.shared.appForegrounded()
                }
            case .background:
                // Cleanly disconnect (after a short grace delay) so iOS doesn't
                // suspend us with an unacked message that the server would
                // re-push on a loop.
                if model.ready && model.hasAccount {
                    appDelegate.scheduleBackgroundDisconnect()
                }
            default:
                break
            }
        }
    }
}

#if DEBUG
@MainActor
private enum GeckoPreviewFixtures {
    static let account = XmppAccount(id: "rachel@example.org", state: "CONNECTED")

    static let conversations: [XmppConversation] = [
        XmppConversation(
            id: 1,
            account: "rachel@example.org",
            jid: "anemone@xmpp.is",
            name: "Anemone",
            encryption: "OMEMO",
            encryptionAvailable: true,
            kind: "chat",
            unread: 3,
            preview: "Sent a few image-heavy test messages",
            previewDirection: "in",
            time: Date().addingTimeInterval(-180),
            notify: "default",
            notifyEffective: "on"
        ),
        XmppConversation(
            id: 2,
            account: "rachel@example.org",
            jid: "gecko@conference.example.org",
            name: "Gecko Dev",
            encryption: "",
            encryptionAvailable: false,
            kind: "groupchat",
            unread: 0,
            preview: "I will test the new composer layout",
            previewDirection: "out",
            time: Date().addingTimeInterval(-3600),
            notify: "default",
            notifyEffective: "highlight"
        ),
        XmppConversation(
            id: 3,
            account: "rachel@example.org",
            jid: "offline@example.org",
            name: "Offline Contact",
            encryption: "",
            encryptionAvailable: false,
            kind: "chat",
            unread: 0,
            preview: "See you later",
            previewDirection: "in",
            time: Date().addingTimeInterval(-86400),
            notify: "default",
            notifyEffective: "off"
        ),
    ]

    static let messages: [ChatMessage] = [
        ChatMessage(
            id: 100,
            content: "text",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "Can you check how this wraps in the new bubble layout?",
            time: Date().addingTimeInterval(-600),
            encryption: "OMEMO",
            marked: "read"
        ),
        ChatMessage(
            id: 101,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "Yes. This gives us enough text to verify line wrapping, timestamps, and the outgoing bubble.",
            time: Date().addingTimeInterval(-540),
            encryption: "OMEMO",
            editable: true,
            reactions: [
                Reaction(emoji: "👍", count: 2, me: true),
                Reaction(emoji: "✨", count: 1, me: false),
            ],
            marked: "read",
            quote: QuoteRef(item: 100, from: "Anemone", body: "Can you check how this wraps?")
        ),
        ChatMessage(
            id: 102,
            content: "text",
            direction: "out",
            from: "rachel@example.org",
            body: "This one is queued while reconnecting.",
            time: Date().addingTimeInterval(-60),
            encryption: "OMEMO",
            marked: "unsent"
        ),
        ChatMessage(
            id: 103,
            content: "file",
            direction: "in",
            from: "anemone@xmpp.is",
            fromDisplay: "Anemone",
            body: "",
            time: Date().addingTimeInterval(-30),
            encryption: "OMEMO",
            fileName: "photo.jpg",
            mime: "image/jpeg",
            size: 2_400_000,
            fileState: "not_started"
        ),
    ]

    static func model() -> AppModel {
        let model = AppModel()
        model.ready = true
        model.accounts = [account]
        model.accountAlias = "Rachel"
        model.conversations = conversations
        model.messages = [1: messages]
        model.roster = [
            RosterContact(
                id: "anemone@xmpp.is",
                account: "rachel@example.org",
                name: "Anemone",
                subscription: "both",
                show: "online"
            ),
            RosterContact(
                id: "offline@example.org",
                account: "rachel@example.org",
                name: "Offline Contact",
                subscription: "both",
                show: "offline"
            ),
        ]
        model.subscriptionRequests = ["newfriend@example.org"]
        model.chatStates = [1: "composing"]
        return model
    }
}

#Preview("Conversation List") {
    NavigationStack {
        ConversationListView()
            .environmentObject(GeckoPreviewFixtures.model())
    }
}

#Preview("Conversation Rows") {
    List {
        ForEach(GeckoPreviewFixtures.conversations) { conv in
            ConversationRow(
                conv: conv,
                presence: conv.isGroupchat ? nil : (conv.jid == "offline@example.org" ? "offline" : "online"),
                avatarPath: nil,
                requestAvatar: {}
            )
        }
    }
}

#Preview("Chat") {
    NavigationStack {
        ChatView(conversationId: 1, talksToCore: false)
            .environmentObject(GeckoPreviewFixtures.model())
    }
}

#Preview("Message Bubbles") {
    ScrollView {
        VStack(spacing: 10) {
            ForEach(GeckoPreviewFixtures.messages) { msg in
                MessageBubble(
                    msg: msg,
                    inGroupchat: true,
                    showSender: msg.direction == "in",
                    onEdit: { _ in },
                    onReply: { _ in },
                    onActions: { _ in },
                    onReaction: { _, _ in },
                    onDownloadFile: { _ in }
                )
            }
        }
        .padding()
    }
}
#endif

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack(path: $model.navigation) {
            Group {
                if !model.ready {
                    ProgressView("Starting Dino core…")
                } else if !model.hasAccount {
                    AccountSetupView()
                } else {
                    ConversationListView()
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct AccountSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var jid = ""
    @State private var password = ""
    @State private var submitting = false

    var body: some View {
        Form {
            Section("XMPP Account") {
                TextField("user@example.org", text: $jid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("Password", text: $password)
                Button {
                    submitting = true
                    model.addAccount(jid: jid, password: password)
                } label: {
                    if submitting {
                        HStack {
                            ProgressView()
                            Text("Signing in…").padding(.leading, 8)
                        }
                    } else {
                        Text("Sign in")
                    }
                }
                .disabled(submitting || jid.isEmpty || password.isEmpty)
            }
        }
        .navigationTitle("Log In")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.lastError) { _, error in
            if error != nil { submitting = false }
        }
    }
}

struct ConversationListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showContacts = false
    @State private var showAccountSettings = false
    @State private var showJoinMuc = false
    @State private var mucJid = ""
    @State private var mucNick = ""

    var body: some View {
        List {
            if !model.subscriptionRequests.isEmpty {
                Section("Contact requests") {
                    ForEach(model.subscriptionRequests, id: \.self) { jid in
                        SubscriptionRequestRow(jid: jid)
                    }
                }
            }
            Section("Conversations") {
                ForEach(model.conversations) { conv in
                    let presence = conv.isGroupchat ? nil : model.presence(for: conv.jid)
                    NavigationLink(value: conv.id) {
                        ConversationRow(
                            conv: conv,
                            presence: presence,
                            avatarPath: model.avatars[conv.jid],
                            requestAvatar: { model.ensureAvatar(for: conv.jid) })
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.closeConversation(conv.id)
                        } label: {
                            Label(conv.isGroupchat ? "Leave" : "Close",
                                  systemImage: conv.isGroupchat ? "rectangle.portrait.and.arrow.right" : "xmark")
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Int32.self) { id in
            ChatView(conversationId: id)
                .environmentObject(model)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let account = model.accounts.first {
                    Button {
                        showAccountSettings = true
                    } label: {
                        AvatarView(
                            jid: account.id, name: model.accountAlias, isGroup: false, size: 34,
                            avatarPath: model.avatars[account.id],
                            requestAvatar: { model.ensureAvatar(for: account.id) })
                            .padding(3)
                            .glassEffect(.regular.tint(accountStatusColor(account.state)).interactive(), in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                            // Include the glass ring around the avatar in the
                            // tap target, not just the opaque avatar image.
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.requestState()
                    showContacts = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showJoinMuc = true
                    } label: {
                        Label("Join channel", systemImage: "person.2")
                    }
                    Button {
                        showAccountSettings = true
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showContacts) {
            ContactsView(isPresented: $showContacts)
                .environmentObject(model)
        }
        .sheet(isPresented: $showAccountSettings) {
            AccountSettingsView(isPresented: $showAccountSettings)
                .environmentObject(model)
        }
        .alert("Join channel", isPresented: $showJoinMuc) {
            TextField("room@conference.example.org", text: $mucJid)
                .textInputAutocapitalization(.never)
            TextField("Nickname (optional)", text: $mucNick)
                .textInputAutocapitalization(.never)
            Button("Join") {
                model.joinMuc(jid: mucJid, nick: mucNick.isEmpty ? nil : mucNick)
                mucJid = ""
                mucNick = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Create channel?", isPresented: Binding(
            get: { model.pendingMucCreate != nil },
            set: { if !$0 { model.pendingMucCreate = nil } }
        ), presenting: model.pendingMucCreate) { pending in
            Button("Create") {
                model.createMuc(jid: pending.jid, nick: pending.nick)
                model.pendingMucCreate = nil
            }
            Button("Cancel", role: .cancel) { model.pendingMucCreate = nil }
        } message: { pending in
            Text("\(pending.jid) doesn't exist yet. Create it as a new channel?")
        }
    }
}

/// Ring colour for the account avatar, reflecting the connection state.
func accountStatusColor(_ state: String) -> Color {
    switch state.uppercased() {
    case "CONNECTED": return .green
    case "CONNECTING": return .orange
    default: return .red
    }
}

func jidColor(_ jid: String) -> Color {
    let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .red]
    var hash = 5381
    for b in jid.utf8 { hash = ((hash << 5) &+ hash) &+ Int(b) }
    return palette[abs(hash) % palette.count]
}

/// Maps an XMPP presence "show" to a status-dot colour.
func presenceColor(_ show: String) -> Color {
    switch show {
    case "online", "chat": return .green
    case "away", "xa": return .yellow
    case "dnd": return .red
    default: return Color(.systemGray4)  // offline / unknown
    }
}

struct CachedDiskImage<Placeholder: View>: View {
    let path: String?
    let maxPixel: Int
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var loadedKey = ""

    private var cacheKey: String {
        "\(path ?? "")@\(maxPixel)"
    }

    init(
        path: String?,
        maxPixel: Int,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.path = path
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        if let path, let cached = ThumbnailLoader.cachedThumbnail(path: path, maxPixel: maxPixel) {
            _image = State(initialValue: cached)
            _loadedKey = State(initialValue: "\(path)@\(maxPixel)")
        }
    }

    var body: some View {
        let currentKey = cacheKey
        Group {
            if let image, loadedKey == currentKey {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: currentKey) {
            guard let path, !path.isEmpty else {
                image = nil
                loadedKey = currentKey
                return
            }
            if let cached = ThumbnailLoader.cachedThumbnail(path: path, maxPixel: maxPixel) {
                image = cached
                loadedKey = currentKey
                return
            }
            let p = path, mp = maxPixel
            let decoded = await Task.detached(priority: .userInitiated) {
                ThumbnailLoader.loadThumbnail(path: p, maxPixel: mp)
            }.value
            if !Task.isCancelled {
                image = decoded
                loadedKey = currentKey
            }
        }
    }
}

struct AvatarView: View {
    @Environment(\.displayScale) private var displayScale
    let jid: String
    let name: String
    let isGroup: Bool
    var size: CGFloat = 44
    /// XMPP "show" for a status dot, or nil to draw no dot (groups, occupants…).
    var presence: String?
    var avatarPath: String?
    var requestAvatar: (() -> Void)?

    private var initial: String {
        String((name.isEmpty ? jid : name).prefix(1)).uppercased()
    }

    private var fallbackColor: Color {
        jidColor(jid)
    }

    private var maxPixel: Int {
        max(96, Int((size * displayScale * 2).rounded()))
    }

    var body: some View {
        CachedDiskImage(path: avatarPath, maxPixel: maxPixel, contentMode: .fill) {
            fallback
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if let presence {
                Circle()
                    .fill(presenceColor(presence))
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: max(1.5, size * 0.045)))
            }
        }
        .onAppear { requestAvatar?() }
    }

    private var fallback: some View {
        ZStack {
            fallbackColor.opacity(0.85)
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct ConversationRow: View {
    let conv: XmppConversation
    let presence: String?
    let avatarPath: String?
    let requestAvatar: () -> Void

    private var timeLabel: String {
        GeckoDisplayFormatters.conversationTime(conv.time)
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(jid: conv.jid, name: conv.name, isGroup: conv.isGroupchat,
                       presence: presence, avatarPath: avatarPath, requestAvatar: requestAvatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conv.name)
                        .fontWeight(conv.unread > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if conv.encryption == "OMEMO" {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
                    }
                    if conv.notifyEffective == "off" {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(timeLabel).font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Text((conv.previewDirection == "out" && !conv.preview.isEmpty ? "You: " : "") + conv.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conv.unread > 0 {
                        Text("\(conv.unread)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
            }
        }
    }
}

struct SubscriptionRequestRow: View {
    @EnvironmentObject var model: AppModel
    let jid: String

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(jid)
                Text("wants to add you").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.respondSubscription(jid: jid, approve: true)
            } label: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
            }
            .buttonStyle(.plain)
            Button {
                model.respondSubscription(jid: jid, approve: false)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title2)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ContactsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var showAdd = false
    @State private var newJid = ""
    @State private var newAlias = ""
    @State private var search = ""

    private var filtered: [RosterContact] {
        if search.isEmpty { return model.roster }
        return model.roster.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) ||
            $0.id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.roster.isEmpty {
                    Text("No contacts yet. Add one with the + button.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { contact in
                    Button {
                        isPresented = false
                        model.openChat(with: contact.id)
                    } label: {
                        HStack {
                            AvatarView(jid: contact.id, name: contact.displayName, isGroup: false, size: 36,
                                       presence: contact.show, avatarPath: model.avatars[contact.id],
                                       requestAvatar: { model.ensureAvatar(for: contact.id) })
                            VStack(alignment: .leading) {
                                Text(contact.displayName)
                                HStack(spacing: 4) {
                                    Text(contact.id)
                                    if contact.subscription == "both" {
                                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 8))
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    // No full-swipe: reveal the buttons and require a tap, so a
                    // quick swipe can't accidentally block or remove someone.
                    .swipeActions(allowsFullSwipe: false) {
                        if model.isBlocked(contact.id) {
                            Button { model.unblockContact(contact.id) } label: {
                                Label("Unblock", systemImage: "hand.raised.slash")
                            }
                            .tint(.orange)
                        } else {
                            Button { model.blockContact(contact.id) } label: {
                                Label("Block", systemImage: "nosign")
                            }
                            .tint(.red)
                        }
                        Button(role: .destructive) {
                            model.removeContact(jid: contact.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search contacts")
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.requestBlocklist() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Add contact", isPresented: $showAdd) {
                TextField("user@example.org", text: $newJid)
                    .textInputAutocapitalization(.never)
                TextField("Name (optional)", text: $newAlias)
                Button("Add") {
                    model.addContact(jid: newJid, alias: newAlias.isEmpty ? nil : newAlias)
                    newJid = ""
                    newAlias = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A presence subscription request will be sent.")
            }
        }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PendingFileSend {
    let url: URL
    let name: String
    let isImage: Bool
    let sizeLabel: String

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attrs?[.size] as? NSNumber)?.intValue
        if let byteCount, byteCount > 0 {
            self.sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        } else {
            self.sizeLabel = ""
        }
        self.isImage = ThumbnailLoader.pixelSize(path: url.path) != nil
    }
}

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    var talksToCore: Bool = true
    @Namespace private var composerGlass
    @State private var draft = ""
    @State private var showSend = false
    /// Whether the Photo/File attach options are expanded out of the plus
    /// button. A custom expander (not a system Menu) so the options can morph
    /// out of the button's glass rather than popping over it.
    @State private var showAttach = false
    /// Shared height for the composer's buttons and text field so they align.
    private let composerControlHeight: CGFloat = 44
    private let composerInputVerticalPadding: CGFloat = 8
    /// Extra visible space between the newest message and the floating composer.
    /// Rows already have 3pt bottom padding, so another 3pt matches the 6pt
    /// row-to-row rhythm instead of leaving a visibly larger composer gap.
    private let composerMessageClearance: CGFloat = 3
    private let topToolbarMessageClearance: CGFloat = 8
    private let topToolbarControlHeight: CGFloat = 44
    private let topToolbarVerticalPadding: CGFloat = 6
    private let topToolbarAvatarSize: CGFloat = 34
    private let topMessageFadeHeight: CGFloat = 72
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showOccupants = false
    @State private var occupantDMNick: String?
    @State private var showEncryptionHelp = false
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var actionMsg: ChatMessage?
    @State private var showFullTitle = false
    /// Whether the list is pinned to the newest message. Driven by the inverted
    /// table (InvertedMessageList); gates the scroll-down button.
    @State private var isAtBottom = true
    /// Bumped to ask the message list to glide to the newest message — the
    /// scroll-down button, and after sending.
    @State private var scrollToBottomToken = 0
    @State private var viewerItem: ImageViewerItem?
    @State private var composerHeight: CGFloat = 0
    @State private var keyboardOverlap: CGFloat = 0
    @State private var pendingFileSend: PendingFileSend?

    private var conversation: XmppConversation? {
        model.conversations.first { $0.id == conversationId }
    }

    private var chatMessages: [ChatMessage] {
        model.messages[conversationId] ?? []
    }

    private var isGroupChat: Bool {
        conversation?.isGroupchat == true
    }

    private var hasComposerAccessory: Bool {
        model.chatStates[conversationId] == "composing" || editing != nil || replyingTo != nil
            || pendingFileSend != nil
    }

    private var shouldShowSendButton: Bool {
        !draft.isEmpty
    }

    @ViewBuilder
    private var composerArea: some View {
        // Explicit VStack so the banners stack above the input bar in order;
        // without it the banners (a bare ViewBuilder tuple) laid out wrong and
        // the reply preview ended up under the input.
        VStack(spacing: 0) {
            if model.chatStates[conversationId] == "composing" {
                HStack {
                    Text("typing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            }
            if editing != nil {
                composerBanner(icon: "pencil", cancelLabel: "Cancel edit") {
                    editing = nil
                    draft = ""
                } label: {
                    Text("Editing message").font(.caption)
                }
            }
            if let replyingTo {
                composerBanner(icon: "arrowshape.turn.up.left", cancelLabel: "Cancel reply") {
                    self.replyingTo = nil
                } label: {
                    VStack(alignment: .leading) {
                        Text("Replying to \(replyingTo.fromDisplay.isEmpty ? replyingTo.from : replyingTo.fromDisplay)")
                            .font(.caption.bold())
                        Text(replyingTo.isFile ? replyingTo.fileName : replyingTo.body)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let pendingFileSend {
                pendingFileSendPanel(pendingFileSend)
            }
            inputBar
        }
    }

    private var composerToolbar: some View {
        composerArea
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
                }
            }
    }

    @ViewBuilder
    private func pendingFileSendPanel(_ file: PendingFileSend) -> some View {
        HStack(spacing: 10) {
            if file.isImage {
                CachedDiskImage(path: file.url.path, maxPixel: 360, contentMode: .fill) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, height: 76)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !file.sizeLabel.isEmpty {
                    Text(file.sizeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                cancelPendingFileSend()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel \(file.name)")

            Button {
                confirmPendingFileSend()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(.blue).interactive(), in: Circle())
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send \(file.name)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// A dismissable banner (typing reply/edit context) shown above the input.
    private func composerBanner<Label: View>(
        icon: String,
        cancelLabel: String,
        onCancel: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        HStack {
            Image(systemName: icon).font(.caption)
            label()
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cancelLabel)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var inputBar: some View {
        GlassEffectContainer(spacing: 6) {
            // Bottom-align so the +/send buttons stay pinned to the bottom as the
            // text field grows upward over multiple lines.
            HStack(alignment: .bottom, spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                        showAttach.toggle()
                    }
                } label: {
                    Image(systemName: showAttach ? "xmark" : "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: composerControlHeight, height: composerControlHeight)
                        .glassEffect(.regular.interactive(), in: Circle())
                        // Make the whole circle tappable, not just the glyph.
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showAttach ? "Close attachments" : "Attach")
                .disabled(editing != nil)
                .opacity(editing == nil ? 1 : 0.45)
                // The Photo/File options grow upward out of the plus button —
                // same GlassEffectContainer, so the glass blends as they emerge
                // — instead of a system menu popping over it. Anchored to the
                // button's bottom-leading corner and scaled from there so they
                // visually originate at the plus.
                .overlay(alignment: .bottomLeading) {
                    if showAttach {
                        attachOptions
                            .offset(y: -(composerControlHeight + 8))
                            .transition(.scale(scale: 0.2, anchor: .bottomLeading)
                                .combined(with: .opacity))
                    }
                }

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    // Grow with the text up to a cap, then scroll internally.
                    .lineLimit(1...6)
                    // Vertical inset too (not just horizontal) so multi-line text
                    // stays inside the capsule instead of spilling past its
                    // rounded top/bottom edges.
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .frame(minHeight: composerControlHeight)
                    // RoundedRectangle, not Capsule: a wide multi-line field made
                    // a Capsule rounds its left/right ends into big semicircles
                    // (radius = half the height) that clip the text. Fixed 22pt
                    // corners keep a full-width text area; at one line (44pt tall)
                    // it still reads as a pill.
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .glassEffectID("composerField", in: composerGlass)
                    .onChange(of: draft) { _, value in
                        if editing == nil {
                            model.setTyping(conversationId, !value.isEmpty)
                        }
                        // Drive the send button's presence explicitly so it
                        // morphs in/out (split from / merge into the field) on
                        // BOTH first keystroke and delete-to-empty — relying on
                        // an implicit .animation(value:) didn't animate the
                        // structural removal on delete.
                        // Snappy so the button reaches its tappable position
                        // fast — a slow morph leaves it briefly unresponsive
                        // right after a send (while it animates back in).
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                            showSend = shouldShowSendButton
                        }
                    }

                if showSend {
                    // Blue send button that fluidly splits out of the text
                    // field's glass (and merges back when the draft clears),
                    // via the shared GlassEffectContainer + matched id.
                    Button {
                        sendCurrentDraft()
                    } label: {
                        Image(systemName: editing != nil ? "checkmark" : "paperplane.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: composerControlHeight, height: composerControlHeight)
                            .glassEffect(.regular.tint(.blue).interactive(), in: Circle())
                            .glassEffectID("composerSend", in: composerGlass)
                            // Without this the hit area is just the glyph, not
                            // the full circle — taps off the icon did nothing.
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(editing != nil ? "Save edit" : "Send")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, composerInputVerticalPadding)
        }
    }

    private var attachOptions: some View {
        // .fixedSize so the pills size to their content rather than being
        // squeezed to the plus button's width by the overlay's proposal.
        VStack(alignment: .leading, spacing: 8) {
            attachOption(icon: "photo", title: "Photo") { showPhotoPicker = true }
            attachOption(icon: "doc", title: "File") { showFileImporter = true }
        }
        .fixedSize()
    }

    private func attachOption(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showAttach = false }
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .frame(height: composerControlHeight)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func setPendingFileSend(_ url: URL) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            pendingFileSend = PendingFileSend(url: url)
        }
    }

    private func cancelPendingFileSend() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            pendingFileSend = nil
        }
    }

    private func confirmPendingFileSend() {
        guard let pendingFileSend else { return }
        scrollToBottomToken &+= 1
        model.sendFile(conversationId, path: pendingFileSend.url.path)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            self.pendingFileSend = nil
        }
    }

    private func sendCurrentDraft() {
        scrollToBottomToken &+= 1
        if let editing {
            model.correctMessage(conversationId, item: editing.id, body: draft)
            self.editing = nil
            draft = ""
            showSend = false
            model.setTyping(conversationId, false)
            return
        }

        let body = draft
        if !body.isEmpty {
            model.send(conversationId, body, replyTo: replyingTo?.id ?? 0)
        }
        replyingTo = nil
        draft = ""
        showSend = false
        model.setTyping(conversationId, false)
    }

    private func reactionSheet(for m: ChatMessage) -> some View {
        ReactionSheet(
            msg: m,
            onReact: { emoji in
                let mine = m.reactions.first { $0.emoji == emoji }?.me ?? false
                model.setReaction(conversationId, item: m.id, emoji: emoji, add: !mine)
            },
            onReply: {
                editing = nil
                replyingTo = m
            },
            onEdit: m.editable ? {
                replyingTo = nil
                pendingFileSend = nil
                editing = m
                draft = m.body
            } : nil)
    }

    private func messageList(
        topChromeInset: CGFloat,
        bottomChromeInset: CGFloat,
        scrollButtonBottomPadding: CGFloat
    ) -> some View {
        InvertedMessageList(
            messages: chatMessages,
            conversationId: conversationId,
            isGroupchat: isGroupChat,
            avatarPaths: model.avatars,
            visualTopInset: topChromeInset,
            visualBottomInset: bottomChromeInset,
            model: model,
            isAtBottom: $isAtBottom,
            scrollToBottomToken: scrollToBottomToken,
            onEdit: { m in
                replyingTo = nil
                pendingFileSend = nil
                editing = m
                draft = m.body
            },
            onReply: { m in editing = nil; replyingTo = m },
            onImageTap: { path in viewerItem = ImageViewerItem(id: path) },
            onActions: { m in actionMsg = m }
        )
        .ignoresSafeArea(.container, edges: .vertical)
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                scrollDownButton(bottomPadding: scrollButtonBottomPadding)
            }
        }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
    }

    private func bottomChromeInset(safeAreaBottom: CGFloat) -> CGFloat {
        let toolbarHeight = max(composerHeight, composerControlHeight + composerInputVerticalPadding * 2)
        let transparentTopOverlap = hasComposerAccessory ? 0 : composerInputVerticalPadding
        return safeAreaBottom + toolbarHeight - transparentTopOverlap + composerMessageClearance
    }

    private func chromeSafeAreaBottom(from safeAreaBottom: CGFloat) -> CGFloat {
        max(0, safeAreaBottom - keyboardOverlap)
    }

    private func scrollButtonBottomPadding(bottomChromeInset: CGFloat) -> CGFloat {
        if keyboardOverlap > 0 {
            let toolbarHeight = max(composerHeight, composerControlHeight + composerInputVerticalPadding * 2)
            return toolbarHeight + composerInputVerticalPadding
        }
        return max(0, bottomChromeInset - composerInputVerticalPadding)
    }

    private func updateKeyboardOverlap(from note: Notification) {
        guard
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = scene.windows.first(where: \.isKeyWindow),
            let screenFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            keyboardOverlap = 0
            return
        }

        let frame = window.convert(screenFrame, from: nil)
        let overlap = window.bounds.intersection(frame)
        let coversBottom = !overlap.isNull && overlap.maxY >= window.bounds.maxY - 1
        keyboardOverlap = coversBottom ? overlap.height : 0
    }

    private func topChromeInset(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop + topToolbarControlHeight + topToolbarVerticalPadding * 2 + topToolbarMessageClearance
    }

    private func topFadeHeight(safeAreaTop: CGFloat) -> CGFloat {
        topChromeInset(safeAreaTop: safeAreaTop) + topMessageFadeHeight
    }

    private func topScreenFade(height: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: Color(.systemBackground).opacity(0.94), location: 0),
                .init(color: Color(.systemBackground).opacity(0.82), location: 0.42),
                .init(color: Color(.systemBackground).opacity(0.34), location: 0.72),
                .init(color: Color(.systemBackground).opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
    }

    private func scrollDownButton(bottomPadding: CGFloat) -> some View {
        Button {
            scrollToBottomToken &+= 1   // the inverted table glides to row 0
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .contentShape(.circle)
        .accessibilityLabel("Scroll to latest messages")
        .padding(.trailing, 14)
        .padding(.bottom, bottomPadding)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private func topToolbar(safeAreaTop: CGFloat) -> some View {
        let fadeHeight = topFadeHeight(safeAreaTop: safeAreaTop)
        return ZStack(alignment: .top) {
            topScreenFade(height: fadeHeight)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    topIconButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                        dismiss()
                    }

                    headerAvatarButton

                    titleButton
                        .frame(height: topToolbarControlHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    topBellMenu
                    if isGroupChat {
                        topOccupantsButton
                    }
                    topLockButton
                }
                .padding(.horizontal, 8)
                .padding(.top, safeAreaTop + topToolbarVerticalPadding)
                .popover(isPresented: $showFullTitle, arrowEdge: .top) {
                    titlePopover
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: fadeHeight, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func topIconButton(
        systemImage: String,
        accessibilityLabel: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            topIconLabel(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func topIconLabel(systemImage: String, tint: Color = .primary) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: topToolbarControlHeight, height: topToolbarControlHeight)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }

    private var headerAvatarButton: some View {
        let name: String = conversation?.name ?? "Chat"
        let jid: String = conversation?.jid ?? ""
        return Button {
            showFullTitle = true
        } label: {
            AvatarView(
                jid: jid,
                name: name,
                isGroup: isGroupChat,
                size: topToolbarAvatarSize,
                presence: isGroupChat ? nil : model.presence(for: jid),
                avatarPath: model.avatars[jid],
                requestAvatar: jid.isEmpty ? nil : { model.ensureAvatar(for: jid) })
                .padding((topToolbarControlHeight - topToolbarAvatarSize) / 2)
                .frame(width: topToolbarControlHeight, height: topToolbarControlHeight)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) details")
    }

    private var titleButton: some View {
        let name: String = conversation?.name ?? "Chat"
        // Plain left-aligned title. It uses all the space between the avatar and
        // trailing buttons, truncating only when those controls need the room.
        return Button {
            showFullTitle = true
        } label: {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var titlePopover: some View {
        let name: String = conversation?.name ?? "Chat"
        let jid: String = conversation?.jid ?? ""
        return HStack(spacing: 12) {
            AvatarView(jid: jid, name: name, isGroup: isGroupChat, size: 44,
                       avatarPath: model.avatars[jid],
                       requestAvatar: jid.isEmpty ? nil : { model.ensureAvatar(for: jid) })
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                if !jid.isEmpty, jid != name {
                    Text(jid)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(12)
        .presentationCompactAdaptation(.popover)
    }

    private var topBellMenu: some View {
        Menu {
            notifyOption("All messages", "on")
            if isGroupChat {
                notifyOption("Only when mentioned", "highlight")
            }
            notifyOption("Off", "off")
        } label: {
            topIconLabel(systemImage: bellIcon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notifications")
    }

    private var topOccupantsButton: some View {
        Button {
            model.requestOccupants(conversationId)
            showOccupants = true
        } label: {
            topIconLabel(systemImage: "person.2")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Participants")
    }

    private var topLockButton: some View {
        Button {
            toggleEncryption()
        } label: {
            topIconLabel(systemImage: lockIcon, tint: lockTint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lockAccessibilityLabel)
    }

    private func toggleEncryption() {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        if available {
            model.setEncryption(conversationId, omemo: !omemoOn)
        } else {
            showEncryptionHelp = true
        }
    }

    private var lockIcon: String {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        return available ? (omemoOn ? "lock.fill" : "lock.open") : "lock.slash"
    }

    private var lockTint: Color {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        return omemoOn && available ? .green : .secondary
    }

    private var lockAccessibilityLabel: String {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        let available: Bool = conversation?.encryptionAvailable ?? false
        return available ? (omemoOn ? "Encryption on" : "Encryption off") : "Encryption unavailable"
    }

    @ViewBuilder
    private func notifyOption(_ title: String, _ value: String) -> some View {
        let effective = conversation?.notifyEffective ?? "on"
        Button {
            model.setNotify(conversationId, value)
        } label: {
            if effective == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var bellIcon: String {
        switch conversation?.notifyEffective {
        case "off": return "bell.slash"
        case "highlight": return "bell.badge"
        default: return "bell"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let topInset = topChromeInset(safeAreaTop: geo.safeAreaInsets.top)
            let bottomInset = bottomChromeInset(
                safeAreaBottom: chromeSafeAreaBottom(from: geo.safeAreaInsets.bottom))
            messageList(
                topChromeInset: topInset,
                bottomChromeInset: bottomInset,
                scrollButtonBottomPadding: scrollButtonBottomPadding(bottomChromeInset: bottomInset))
                // Tap anywhere in the chat to dismiss the attach expander (the
                // system Menu used to give this for free). The composer itself is
                // added as a later overlay so the plus/X and options stay tappable.
                .overlay {
                    if showAttach {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    showAttach = false
                                }
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    composerToolbar
                }
                .overlay(alignment: .top) {
                    topToolbar(safeAreaTop: geo.safeAreaInsets.top)
                }
                .onPreferenceChange(ComposerHeightKey.self) { height in
                    if abs(composerHeight - height) > 0.5 {
                        composerHeight = height
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification
        )) { note in
            updateKeyboardOverlap(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { _ in
            keyboardOverlap = 0
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { url in
                setPendingFileSend(url)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    setPendingFileSend(dest)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        // Blank: the custom top overlay renders the title.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showOccupants, onDismiss: {
            // Start the DM only after the sheet has finished sliding away, so
            // the push into the new chat reads as a distinct second step.
            if let nick = occupantDMNick {
                occupantDMNick = nil
                model.startOccupantDM(conversationId, nick: nick)
            }
        }) {
            RoomDetailsView(conversationId: conversationId) { nick in
                occupantDMNick = nick
                showOccupants = false
            }
            .environmentObject(model)
        }
        .fullScreenCover(item: $viewerItem) { item in
            ImageViewer(path: item.path)
        }
        .sheet(item: $actionMsg) { m in
            reactionSheet(for: m)
        }
        .onChange(of: model.viewerRequest) { _, path in
            if let path {
                viewerItem = ImageViewerItem(id: path)
                model.viewerRequest = nil
            }
        }
        .onAppear {
            guard talksToCore else { return }
            model.openConversation(conversationId)
            model.focusConversation(conversationId)
            // So the encryption-help dialog knows whether you're the owner.
            if isGroupChat { model.requestRoomInfo(conversationId) }
        }
        .onDisappear {
            guard talksToCore else { return }
            model.blurConversation(conversationId)
        }
        .confirmationDialog("Encryption unavailable", isPresented: $showEncryptionHelp, titleVisibility: .visible) {
            if model.roomInfo[conversationId]?.iAmOwner == true {
                Button("Make room private") { model.setRoomPrivate(conversationId, true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.roomInfo[conversationId]?.iAmOwner == true {
                Text("End-to-end encryption needs a private room (members-only, with member addresses visible). "
                     + "Make it private to enable encryption, then tap the lock.")
            } else {
                Text("End-to-end encryption needs a private room (members-only, with member addresses visible). "
                     + "Ask a room owner to make it private.")
            }
        }
    }
}

// linkifiedBody(_:) and messageRuns(_:) live in GeckoKit/Sources/GeckoKit/
// MessageFormatting.swift — compiled into this app module by build-app.sh and
// unit-tested via `swift test` in the GeckoKit package.

/// Render a message body: lines starting with `>` become a blockquote (accent
/// bar + muted text), everything else is normal linkified text.
@ViewBuilder
private func messageBody(_ text: String) -> some View {
    if !text.hasPrefix(">") && !text.contains("\n>") {
        Text(linkifiedBody(text)).tint(.accentColor)   // common path: no quotes
    } else {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(messageRuns(text).enumerated()), id: \.offset) { _, run in
                if run.isQuote {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: 3)
                        Text(linkifiedBody(run.text))
                            .italic()
                            .foregroundStyle(.secondary)
                            .tint(.accentColor)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(linkifiedBody(run.text)).tint(.accentColor)
                }
            }
        }
    }
}

struct MessageBubble: View {
    let msg: ChatMessage
    var inGroupchat: Bool = false
    var showSender: Bool = false
    var senderAvatarPath: String?
    var onEdit: ((ChatMessage) -> Void)? = nil
    var onReply: ((ChatMessage) -> Void)? = nil
    var onImageTap: ((String) -> Void)? = nil
    var onActions: ((ChatMessage) -> Void)? = nil
    var onAvatarNeeded: ((String) -> Void)? = nil
    var onReaction: ((String, Bool) -> Void)? = nil
    var onDownloadFile: ((Int32) -> Void)? = nil
    var onImageRendered: (() -> Void)? = nil

    @State private var dragOffset: CGFloat = 0

    @ViewBuilder
    private var markIcon: some View {
        switch msg.marked {
        case "unsent":
            // Queued: the stream was null (disconnected/connecting), so the
            // message is persisted UNSENT and will flush on reconnect. Make
            // that visible rather than letting it look like a normal in-flight
            // message — otherwise the user can't tell it hasn't gone out.
            HStack(spacing: 2) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Pending")
            }
            .font(.system(size: 9))
            .foregroundStyle(.orange)
        case "sending":
            Image(systemName: "clock").font(.system(size: 8))
        case "sent":
            Image(systemName: "checkmark").font(.system(size: 8))
        case "received", "acknowledged":
            Image(systemName: "checkmark").font(.system(size: 8)).foregroundStyle(.secondary)
        case "read":
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 8))
            .foregroundStyle(Color.accentColor)
        case "error", "wontsend":
            Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.direction == "out" { Spacer(minLength: 40) }
            if dragOffset > 8 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(.secondary)
                    .opacity(Double(min(dragOffset / 60, 1)))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            if inGroupchat && msg.direction == "in" {
                if showSender {
                    AvatarView(jid: msg.from, name: msg.fromDisplay, isGroup: false, size: 30,
                               avatarPath: senderAvatarPath,
                               requestAvatar: { onAvatarNeeded?(msg.from) })
                        .padding(.top, showSender ? 16 : 0)
                } else {
                    Color.clear.frame(width: 30, height: 1)
                }
            }
            VStack(alignment: msg.direction == "out" ? .trailing : .leading, spacing: 2) {
                if showSender {
                    Text(msg.fromDisplay.isEmpty ? (msg.from.components(separatedBy: "/").last ?? msg.from) : msg.fromDisplay)
                        .font(.caption.bold())
                        .foregroundStyle(jidColor(msg.from))
                        .padding(.leading, 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let quote = msg.quote {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.accentColor)
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(quote.from)
                                    .font(.caption2.bold())
                                Text(quote.body)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    if msg.isFile {
                        FileContent(msg: msg, onImageTap: onImageTap, onDownloadFile: onDownloadFile,
                                    onImageRendered: onImageRendered)
                    } else {
                        messageBody(msg.body)
                    }
                    HStack(spacing: 4) {
                        if msg.encryption == "OMEMO" {
                            Image(systemName: "lock.fill").font(.system(size: 8))
                        }
                        Text(msg.time, style: .time).font(.system(size: 9))
                        if msg.direction == "out" {
                            markIcon
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(msg.direction == "out" ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onLongPressGesture(minimumDuration: 0.35) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onActions?(msg)
                }
                if !msg.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(msg.reactions, id: \.emoji) { r in
                            Button {
                                onReaction?(r.emoji, !r.me)
                            } label: {
                                Text("\(r.emoji) \(r.count)")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(r.me ? Color.accentColor.opacity(0.3) : Color(.secondarySystemBackground)))
                                    .overlay(
                                        Capsule().stroke(r.me ? Color.accentColor : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if msg.direction != "out" { Spacer(minLength: 40) }
        }
        .offset(x: dragOffset)
        .animation(.spring(duration: 0.25), value: dragOffset == 0)
        .gesture(
            DragGesture(minimumDistance: 25)
                .onChanged { value in
                    // horizontal pull to the right only; vertical stays scroll
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragOffset = max(0, min(value.translation.width, 90))
                }
                .onEnded { _ in
                    if dragOffset > 55 {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onReply?(msg)
                    }
                    dragOffset = 0
                }
        )
    }
}

/// Inline image preview backed by a downsampled, cached thumbnail. Avoids the
/// scroll-killing pattern of decoding a full-resolution image from disk inside
/// `body` on every re-render: the decode happens once, off the main thread, at
/// preview size (ThumbnailLoader), and cache hits render immediately.
struct CachedThumbnail: View {
    let path: String
    /// Longest-side pixel budget: ~the 280pt max preview at 3x retina.
    private let maxPixel = 840
    /// The box the preview is fit into (matches the old maxWidth/maxHeight).
    static let box = CGSize(width: 220, height: 280)
    @State private var image: UIImage?
    /// The row's final on-screen size, reserved BEFORE the image decodes (from a
    /// cheap header read of its real dimensions). Holding the row at its final
    /// height from the first layout means it never grows when the decode lands —
    /// so a chat already pinned to the bottom stays pinned, instead of being left
    /// scrolled to the new image's top with its bottom below the fold.
    private let reserved: CGSize

    init(path: String) {
        self.path = path
        // Seed from cache synchronously so an already-decoded image appears with
        // no placeholder flash while scrolling back over it.
        _image = State(initialValue: ThumbnailLoader.cachedThumbnail(path: path, maxPixel: 840))
        if let px = ThumbnailLoader.pixelSize(path: path) {
            reserved = ThumbnailLoader.fit(px, in: Self.box)
        } else {
            reserved = CGSize(width: 200, height: 150)   // header unreadable: stable fallback
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                // Neutral placeholder until the thumbnail decodes. Same reserved
                // frame as the loaded image, so there's no layout shift.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))
            }
        }
        .frame(width: reserved.width, height: reserved.height)
        .task(id: path) {
            guard image == nil else { return }   // seeded from cache
            let p = path, mp = maxPixel
            let decoded = await Task.detached(priority: .userInitiated) {
                ThumbnailLoader.loadThumbnail(path: p, maxPixel: mp)
            }.value
            if !Task.isCancelled, let decoded { image = decoded }
        }
    }
}

struct FileContent: View {
    let msg: ChatMessage
    var onImageTap: ((String) -> Void)? = nil
    var onDownloadFile: ((Int32) -> Void)? = nil
    var onImageRendered: (() -> Void)? = nil

    private var sizeLabel: String {
        GeckoDisplayFormatters.fileSize(msg.size)
    }

    var body: some View {
        if msg.fileState == "complete", msg.isImage, !msg.path.isEmpty {
            // Downsampled + cached off the main thread (CachedThumbnail), not
            // decoded full-res in body on every scroll frame. The viewer (on tap)
            // still loads the full-resolution file from msg.path.
            // CachedThumbnail reserves its final size up front (from the image
            // header) so the row doesn't grow when the decode lands.
            CachedThumbnail(path: msg.path)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Safety net: should the reserved size ever be wrong (an
                // unreadable header), report a late height change so the chat can
                // still re-pin. With the size reserved this normally fires once.
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size.height, initial: true) { _, _ in
                                onImageRendered?()
                            }
                    }
                }
                .onTapGesture {
                    onImageTap?(msg.path)
                }
        } else if msg.fileState == "complete", !msg.path.isEmpty {
            // No inline preview for this type (video, pdf, …) — hand it to the
            // share sheet so the user can open it in any app that handles it,
            // save it to Files, etc.
            ShareLink(item: URL(fileURLWithPath: msg.path)) { fileRow }
                .buttonStyle(.plain)
        } else {
            fileRow
                .onTapGesture {
                    if msg.fileState == "not_started" || msg.fileState == "failed" {
                        onDownloadFile?(msg.id)
                    }
                }
        }
    }

    private var fileRow: some View {
        HStack(spacing: 8) {
            switch msg.fileState {
            case "in_progress":
                ProgressView().controlSize(.small)
            case "failed":
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            case "complete":
                Image(systemName: msg.isImage ? "photo" : "doc.fill").foregroundStyle(.secondary)
            default:
                Image(systemName: "arrow.down.circle").font(.title3)
            }
            VStack(alignment: .leading) {
                Text(msg.fileName.isEmpty ? "File" : msg.fileName).lineLimit(1)
                HStack(spacing: 4) {
                    if !sizeLabel.isEmpty { Text(sizeLabel) }
                    if msg.fileState == "failed" { Text("failed") }
                    if msg.fileState == "in_progress" { Text(msg.direction == "out" ? "uploading…" : "downloading…") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
