import SwiftUI
import UIKit
import PhotosUI

@main
struct DinoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { model.boot() }
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
        .navigationTitle("Dino")
        .onChange(of: model.lastError) { error in
            if error != nil { submitting = false }
        }
    }
}

struct ConversationListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showContacts = false
    @State private var showJoinMuc = false
    @State private var mucJid = ""
    @State private var mucNick = ""

    var body: some View {
        List {
            if let account = model.accounts.first {
                Section {
                    HStack {
                        Circle()
                            .fill(account.state == "CONNECTED" ? .green : .orange)
                            .frame(width: 10, height: 10)
                        Text(account.id).font(.caption)
                        Spacer()
                        Text(account.state.lowercased()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
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
            Button {
                model.requestState()
                showContacts = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            Menu {
                Button {
                    showJoinMuc = true
                } label: {
                    Label("Join channel", systemImage: "person.2")
                }
                Button(role: .destructive) {
                    model.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $showContacts) {
            ContactsView(isPresented: $showContacts)
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
    }
}

struct AvatarView: View {
    @EnvironmentObject var model: AppModel
    let jid: String
    let name: String
    let isGroup: Bool
    var size: CGFloat = 44

    private var initial: String {
        String((name.isEmpty ? jid : name).prefix(1)).uppercased()
    }

    private var fallbackColor: Color {
        let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .red]
        return palette[abs(jid.hashValue) % palette.count]
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
            AvatarView(jid: conv.jid, name: conv.name, isGroup: conv.isGroupchat)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conv.name)
                        .fontWeight(conv.unread > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if conv.encryption == "OMEMO" {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
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
                            AvatarView(jid: contact.id, name: contact.displayName, isGroup: false, size: 36)
                                .overlay(alignment: .bottomTrailing) {
                                    Circle()
                                        .fill(contact.online ? .green : Color(.systemGray4))
                                        .frame(width: 10, height: 10)
                                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                                }
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
                }
                .onDelete { offsets in
                    for i in offsets { model.removeContact(jid: filtered[i].id) }
                }
            }
            .searchable(text: $search, prompt: "Search contacts")
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
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
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showOccupants = false
    @State private var editing: ChatMessage?
    @State private var viewerItem: ImageViewerItem?

    private var conversation: XmppConversation? {
        model.conversations.first { $0.id == conversationId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.messages[conversationId] ?? []) { msg in
                            MessageBubble(conversationId: conversationId, msg: msg, onEdit: { m in
                                editing = m
                                draft = m.body
                            }, onImageTap: { path in
                                viewerItem = ImageViewerItem(id: path)
                            })
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.messages[conversationId]?.count ?? 0) { _ in
                    if let last = model.messages[conversationId]?.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if model.chatStates[conversationId] == "composing" {
                HStack {
                    Text("typing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 2)
                    Spacer()
                }
            }
            Divider()
            if editing != nil {
                HStack {
                    Image(systemName: "pencil").font(.caption)
                    Text("Editing message").font(.caption)
                    Spacer()
                    Button {
                        editing = nil
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            HStack {
                Menu {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Photo", systemImage: "photo")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("File", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus.circle").font(.title3)
                }
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { value in
                        if editing == nil {
                            model.setTyping(conversationId, !value.isEmpty)
                        }
                    }
                Button {
                    if let editing {
                        model.correctMessage(conversationId, item: editing.id, body: draft)
                        self.editing = nil
                    } else {
                        model.send(conversationId, draft)
                    }
                    draft = ""
                } label: {
                    Image(systemName: editing != nil ? "checkmark.circle.fill" : "paperplane.fill")
                }
                .disabled(draft.isEmpty)
            }
            .padding(10)
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let name = (item.itemIdentifier ?? UUID().uuidString).replacingOccurrences(of: "/", with: "_")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(name).jpg")
                try? data.write(to: url)
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
        .navigationTitle(conversation?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if conversation?.isGroupchat == true {
                Button {
                    model.requestOccupants(conversationId)
                    showOccupants = true
                } label: {
                    Image(systemName: "person.2")
                }
            }
            Button {
                let omemoOn = conversation?.encryption == "OMEMO"
                model.setEncryption(conversationId, omemo: !omemoOn)
            } label: {
                Image(systemName: conversation?.encryption == "OMEMO" ? "lock.fill" : "lock.open")
                    .foregroundStyle(conversation?.encryption == "OMEMO" ? .green : .secondary)
            }
        }
        .sheet(isPresented: $showOccupants) {
            OccupantsView(conversationId: conversationId, isPresented: $showOccupants)
                .environmentObject(model)
        }
        .fullScreenCover(item: $viewerItem) { item in
            ImageViewer(path: item.path)
        }
        .onChange(of: model.viewerRequest) { path in
            if let path {
                viewerItem = ImageViewerItem(id: path)
                model.viewerRequest = nil
            }
        }
        .onAppear {
            model.openConversation(conversationId)
            model.focusConversation(conversationId)
        }
        .onDisappear {
            model.blurConversation(conversationId)
        }
    }
}

struct MessageBubble: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    let msg: ChatMessage
    var onEdit: ((ChatMessage) -> Void)? = nil
    var onImageTap: ((String) -> Void)? = nil

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "😢"]

    var body: some View {
        HStack {
            if msg.direction == "out" { Spacer(minLength: 40) }
            VStack(alignment: msg.direction == "out" ? .trailing : .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    if msg.isFile {
                        FileContent(conversationId: conversationId, msg: msg, onImageTap: onImageTap)
                    } else {
                        Text(msg.body)
                    }
                    HStack(spacing: 4) {
                        if msg.encryption == "OMEMO" {
                            Image(systemName: "lock.fill").font(.system(size: 8))
                        }
                        Text(msg.time, style: .time).font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(msg.direction == "out" ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contextMenu {
                    ForEach(Self.quickEmojis, id: \.self) { emoji in
                        Button {
                            let mine = msg.reactions.first { $0.emoji == emoji }?.me ?? false
                            model.setReaction(conversationId, item: msg.id, emoji: emoji, add: !mine)
                        } label: {
                            Text(emoji)
                        }
                    }
                    if msg.editable, let onEdit {
                        Divider()
                        Button {
                            onEdit(msg)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
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
    }
}

struct OccupantsView: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                let list = model.occupants[conversationId] ?? []
                if list.isEmpty {
                    Text("No participants visible.").foregroundStyle(.secondary)
                }
                ForEach(list, id: \.nick) { occupant in
                    HStack {
                        AvatarView(jid: occupant.nick, name: occupant.nick, isGroup: false, size: 32)
                        Text(occupant.nick)
                        if occupant.isSelf {
                            Text("you").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Participants (\((model.occupants[conversationId] ?? []).count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Close") { isPresented = false }
            }
        }
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
        } else {
            HStack(spacing: 8) {
                switch msg.fileState {
                case "in_progress":
                    ProgressView().controlSize(.small)
                case "failed":
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                case "complete":
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
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
            .onTapGesture {
                if msg.fileState == "not_started" || msg.fileState == "failed" {
                    model.downloadFile(conversationId, item: msg.id)
                }
            }
        }
    }
}
