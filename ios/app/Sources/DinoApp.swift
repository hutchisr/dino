import SwiftUI

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
    @State private var showNew = false
    @State private var newJid = ""

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
            Section("Conversations") {
                ForEach(model.conversations) { conv in
                    NavigationLink(value: conv.id) {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(conv.name)
                                if conv.encryption == "OMEMO" {
                                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
                                }
                            }
                            Text(conv.jid).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Dino")
        .navigationDestination(for: Int32.self) { id in
            ChatView(conversationId: id)
        }
        .toolbar {
            Button {
                showNew = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            Menu {
                Button(role: .destructive) {
                    model.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .alert("New conversation", isPresented: $showNew) {
            TextField("JID", text: $newJid)
                .textInputAutocapitalization(.never)
            Button("Start") {
                model.startConversation(jid: newJid)
                newJid = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    @State private var draft = ""

    private var conversation: XmppConversation? {
        model.conversations.first { $0.id == conversationId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.messages[conversationId] ?? []) { msg in
                            MessageBubble(msg: msg)
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
            Divider()
            HStack {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    model.send(conversationId, draft)
                    draft = ""
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(draft.isEmpty)
            }
            .padding(10)
        }
        .navigationTitle(conversation?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                let omemoOn = conversation?.encryption == "OMEMO"
                model.setEncryption(conversationId, omemo: !omemoOn)
            } label: {
                Image(systemName: conversation?.encryption == "OMEMO" ? "lock.fill" : "lock.open")
                    .foregroundStyle(conversation?.encryption == "OMEMO" ? .green : .secondary)
            }
        }
        .onAppear { model.openConversation(conversationId) }
    }
}

struct MessageBubble: View {
    let msg: ChatMessage

    var body: some View {
        HStack {
            if msg.direction == "out" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.body)
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
            if msg.direction != "out" { Spacer(minLength: 40) }
        }
    }
}
