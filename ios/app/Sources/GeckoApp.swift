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
                    NavigationLink(value: conv.id) {
                        ConversationRow(conv: conv)
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
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let account = model.accounts.first {
                    Button {
                        showAccountSettings = true
                    } label: {
                        AvatarView(jid: account.id, name: model.accountAlias, isGroup: false, size: 34)
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

struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    let jid: String
    let name: String
    let isGroup: Bool
    var size: CGFloat = 44
    /// XMPP "show" for a status dot, or nil to draw no dot (groups, occupants…).
    var presence: String?

    private var initial: String {
        String((name.isEmpty ? jid : name).prefix(1)).uppercased()
    }

    private var fallbackColor: Color {
        jidColor(jid)
    }

    var body: some View {
        Group {
            if let path = model.avatars[jid],
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
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
        .onAppear { model.ensureAvatar(for: jid) }
    }
}

struct ConversationRow: View {
    @EnvironmentObject var model: AppModel
    let conv: XmppConversation

    private var timeLabel: String {
        if conv.time.timeIntervalSince1970 == 0 { return "" }
        let cal = Calendar.current
        let fmt = DateFormatter()
        if cal.isDateInToday(conv.time) {
            fmt.timeStyle = .short
            fmt.dateStyle = .none
        } else {
            fmt.dateStyle = .short
            fmt.timeStyle = .none
        }
        return fmt.string(from: conv.time)
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(jid: conv.jid, name: conv.name, isGroup: conv.isGroupchat,
                       presence: conv.isGroupchat ? nil : model.presence(for: conv.jid))
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
                                       presence: contact.show)
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

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    @Namespace private var composerGlass
    @State private var draft = ""
    @State private var showSend = false
    /// Shared height for the composer's buttons and text field so they align.
    private let composerControlHeight: CGFloat = 44
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showOccupants = false
    @State private var occupantDMNick: String?
    @State private var showEncryptionHelp = false
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var actionMsg: ChatMessage?
    @State private var showFullTitle = false
    @State private var isAtBottom = true
    /// Drives scroll-to-bottom via the native edge API: scrolling to the
    /// `.bottom` content edge is clamped to the real scrollable range, so it
    /// reaches the last message without overshooting into empty space (unlike
    /// hand-computed setContentOffset against a transiently mis-estimated
    /// LazyVStack contentSize).
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var viewerItem: ImageViewerItem?

    /// Scroll to the newest message. `animated` drives the on-screen scroll-down
    /// button (a smooth glide); the implicit scrolls on new content snap.
    private func scrollToBottom(animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt.string(from: date)
    }

    private var conversation: XmppConversation? {
        model.conversations.first { $0.id == conversationId }
    }

    private var chatMessages: [ChatMessage] {
        model.messages[conversationId] ?? []
    }

    private var isGroupChat: Bool {
        conversation?.isGroupchat == true
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
            inputBar
        }
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
            HStack(spacing: 12) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Photo", systemImage: "photo")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("File", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(width: composerControlHeight, height: composerControlHeight)
                        .glassEffect(.regular.interactive(), in: Circle())
                        // Make the whole circle tappable, not just the glyph.
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach")

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .frame(minHeight: composerControlHeight)
                    .glassEffect(.regular, in: Capsule())
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
                            showSend = !value.isEmpty
                        }
                    }

                if showSend {
                    // Blue send button that fluidly splits out of the text
                    // field's glass (and merges back when the draft clears),
                    // via the shared GlassEffectContainer + matched id.
                    Button {
                        if let editing {
                            model.correctMessage(conversationId, item: editing.id, body: draft)
                            self.editing = nil
                        } else {
                            model.send(conversationId, draft, replyTo: replyingTo?.id ?? 0)
                            replyingTo = nil
                        }
                        draft = ""
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
            .padding(.vertical, 8)
        }
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
                editing = m
                draft = m.body
            } : nil)
    }

    private var messageStack: some View {
        LazyVStack(spacing: 6) {
            // Key by the stable message id (not the array index) so inserts and
            // deletes keep each row's identity, animations, and state.
            ForEach(chatMessages.enumerated(), id: \.element.id) { index, _ in
                messageRow(index: index)
            }
            // Bottom anchor: its on-screen visibility is the source of truth for
            // `isAtBottom` (robust against the floating composer's safeAreaInset,
            // unlike offset math).
            Color.clear.frame(height: 1)
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    isAtBottom = visible
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var scrollContent: some View {
        ScrollView {
            messageStack
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .coordinateSpace(name: "chatScroll")
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                scrollDownButton()
            }
        }
        .onChange(of: model.messages[conversationId]?.count ?? 0) {
            // A new message landed — snap to it (defaultScrollAnchor handles the
            // initial appear).
            DispatchQueue.main.async { scrollToBottom(animated: false) }
        }
        .onChange(of: chatMessages.reduce(0) { $0 + $1.reactions.count }) {
            // A reaction chip appearing grows its message row; keep the latest
            // in view if we're already pinned to the bottom (don't yank the user
            // away if they've scrolled up into history).
            if isAtBottom { DispatchQueue.main.async { scrollToBottom(animated: false) } }
        }
        .onAppear {
            // LazyVStack row heights are estimated until laid out; on a very long
            // chat .defaultScrollAnchor(.bottom) resolves against that
            // over-estimate and lands past the real end (empty space below),
            // only clamping on a user scroll. Re-assert the bottom once layout
            // settles: the first pass realizes the bottom rows (accurate
            // heights), the second lands correctly. No-op for short chats.
            for delay in [0.05, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    scrollToBottom(animated: false)
                }
            }
        }
    }

    private func scrollDownButton() -> some View {
        Button {
            // Smooth glide back to the newest message.
            scrollToBottom(animated: true)
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Scroll to latest messages")
        .padding(.trailing, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func messageRow(index: Int) -> some View {
        let msgs = chatMessages
        let msg = msgs[index]
        let isGroup = isGroupChat
        let newDay = index == 0 || !Calendar.current.isDate(msg.time, inSameDayAs: msgs[index - 1].time)
        if newDay {
            Text(Self.dayLabel(msg.time))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .padding(.vertical, 6)
        }
        MessageBubble(conversationId: conversationId, msg: msg,
                      inGroupchat: isGroup,
                      showSender: isGroup && msg.direction == "in" &&
                          (newDay || index == 0 || msgs[index - 1].from != msg.from),
                      onEdit: { m in
            replyingTo = nil
            editing = m
            draft = m.body
        }, onReply: { m in
            editing = nil
            replyingTo = m
        }, onImageTap: { path in
            viewerItem = ImageViewerItem(id: path)
        }, onActions: { m in
            actionMsg = m
        })
        .id(msg.id)
    }

    private var titleButton: some View {
        let name: String = conversation?.name ?? "Chat"
        // Plain left-aligned title (no glass bubble). It lives in the .principal
        // slot, which spans the whole region between the back chevron and the
        // trailing buttons; maxWidth: .infinity + leading alignment makes it
        // hug the back button on the left and use all the space up to the
        // trailing buttons, truncating only there.
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
        .popover(isPresented: $showFullTitle, arrowEdge: .top) {
            titlePopover
        }
    }

    private var titlePopover: some View {
        let name: String = conversation?.name ?? "Chat"
        let jid: String = conversation?.jid ?? ""
        return HStack(spacing: 12) {
            AvatarView(jid: jid, name: name, isGroup: isGroupChat, size: 44)
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

    private var bellMenu: some View {
        Menu {
            notifyOption("All messages", "on")
            if isGroupChat {
                notifyOption("Only when mentioned", "highlight")
            }
            notifyOption("Off", "off")
        } label: {
            Label("Notifications", systemImage: bellIcon)
        }
    }

    private var occupantsButton: some View {
        Button {
            model.requestOccupants(conversationId)
            showOccupants = true
        } label: {
            // Label (not a bare Image) so the overflow menu shows a text title
            // beside the icon; the bar still renders icon-only inline.
            Label("Participants", systemImage: "person.2")
        }
    }

    private var lockButton: some View {
        let omemoOn: Bool = conversation?.encryption == "OMEMO"
        // OMEMO needs a private (members-only, non-anonymous) room; the bridge
        // reports whether it's possible so we can disable the toggle otherwise.
        let available: Bool = conversation?.encryptionAvailable ?? false
        // When unavailable, stay tappable and explain why (and offer a fix for
        // owners) instead of being an inert disabled button.
        return Button {
            if available {
                model.setEncryption(conversationId, omemo: !omemoOn)
            } else {
                showEncryptionHelp = true
            }
        } label: {
            Label(available ? (omemoOn ? "Encryption on" : "Encryption off") : "Encryption unavailable",
                  systemImage: available ? (omemoOn ? "lock.fill" : "lock.open") : "lock.slash")
                .foregroundStyle(omemoOn && available ? Color.green : Color.secondary)
        }
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
        scrollContent
        .safeAreaInset(edge: .bottom) {
            composerArea
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { url in
                model.sendFile(conversationId, path: url.path)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    model.sendFile(conversationId, path: dest.path)
                }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        // Blank: the left-aligned title lives in the leading toolbar item; a
        // navigationTitle here would render a second, centred copy.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                titleButton
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                bellMenu
                if isGroupChat {
                    occupantsButton
                }
                lockButton
            }
        }
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
            model.openConversation(conversationId)
            model.focusConversation(conversationId)
            // So the encryption-help dialog knows whether you're the owner.
            if isGroupChat { model.requestRoomInfo(conversationId) }
        }
        .onDisappear {
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
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    let msg: ChatMessage
    var inGroupchat: Bool = false
    var showSender: Bool = false
    var onEdit: ((ChatMessage) -> Void)? = nil
    var onReply: ((ChatMessage) -> Void)? = nil
    var onImageTap: ((String) -> Void)? = nil
    var onActions: ((ChatMessage) -> Void)? = nil

    @State private var dragOffset: CGFloat = 0

    @ViewBuilder
    private var markIcon: some View {
        switch msg.marked {
        case "sending", "unsent":
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
                    AvatarView(jid: msg.from, name: msg.fromDisplay, isGroup: false, size: 30)
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
                        FileContent(conversationId: conversationId, msg: msg, onImageTap: onImageTap)
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
                                model.setReaction(conversationId, item: msg.id, emoji: r.emoji, add: !r.me)
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

struct FileContent: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    let msg: ChatMessage
    var onImageTap: ((String) -> Void)? = nil

    private var sizeLabel: String {
        msg.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(msg.size), countStyle: .file) : ""
    }

    var body: some View {
        if msg.fileState == "complete", msg.isImage, !msg.path.isEmpty,
           let image = UIImage(contentsOfFile: msg.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                        model.downloadFile(conversationId, item: msg.id)
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
