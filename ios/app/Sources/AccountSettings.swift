import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var alias = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showPhotoPicker = false
    @State private var aliasSaved = false
    @State private var presenceShow = "online"
    @State private var presenceStatus = ""
    @State private var presenceDirty = false
    @State private var closingForSignOut = false

    @AppStorage("experimentalSwiftUIMessageList") private var useSwiftUIMessageList = true

    private let presenceOptions = [("online", "Online"), ("away", "Away"), ("dnd", "Do Not Disturb")]
    private var jid: String { model.accounts.first?.id ?? "" }
    private var presenceShowBinding: Binding<String> {
        Binding(
            get: { presenceShow },
            set: { value in
                presenceShow = value
                presenceDirty = true
            })
    }
    private var presenceStatusBinding: Binding<String> {
        Binding(
            get: { presenceStatus },
            set: { value in
                presenceStatus = value
                presenceDirty = true
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Button {
                                showPhotoPicker = true
                            } label: {
                                AvatarView(
                                    jid: jid,
                                    name: model.accountAlias.isEmpty ? jid : model.accountAlias,
                                    isGroup: false,
                                    size: 88,
                                    avatarPath: model.avatars[jid],
                                    requestAvatar: jid.isEmpty ? nil : { model.ensureAvatar(for: jid) })
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "camera.fill")
                                            .font(.caption)
                                            .padding(6)
                                            .background(Circle().fill(Color.accentColor))
                                            .foregroundStyle(.white)
                                    }
                            }
                            .buttonStyle(.plain)
                            Text(jid).font(.caption).foregroundStyle(.secondary)
                            if let state = model.accounts.first?.state {
                                Text(state.lowercased())
                                    .font(.caption2)
                                    .foregroundStyle(state == "CONNECTED" ? .green : .orange)
                            }
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)

                Section("Status") {
                    Picker("Availability", selection: presenceShowBinding) {
                        ForEach(presenceOptions, id: \.0) { value, label in
                            HStack {
                                Circle().fill(presenceColor(value)).frame(width: 8, height: 8)
                                Text(label)
                            }
                            .tag(value)
                        }
                    }
                    TextField("Status message (optional)", text: presenceStatusBinding)
                        .onSubmit { savePresenceIfNeeded() }
                    Button("Save status") { savePresenceIfNeeded() }
                        .disabled(!presenceDirty)
                }

                Section("Display name") {
                    HStack {
                        TextField("Name shown for this account", text: $alias)
                        if aliasSaved {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                    .onSubmit { saveAlias() }
                    Button("Save name") { saveAlias() }
                        .disabled(alias == model.accountAlias)
                }

                Section("Change password") {
                    SecureField("New password", text: $newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                    Button("Change password") {
                        model.changePassword(newPassword)
                        newPassword = ""
                        confirmPassword = ""
                    }
                    .disabled(newPassword.isEmpty || newPassword != confirmPassword)
                }

                if !model.omemoFingerprint.isEmpty {
                    Section("OMEMO") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This device's fingerprint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.omemoFingerprint)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        Text("Device id: \(String(model.omemoDeviceId))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Typing notifications", isOn: Binding(
                        get: { model.sendTyping },
                        set: { model.setSendTyping($0) }))
                    Toggle("Read receipts", isOn: Binding(
                        get: { model.sendMarker },
                        set: { model.setSendMarker($0) }))
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("When off, others won't see when you're typing or that you've read their messages.")
                }

                Section {
                    NavigationLink {
                        BlockedContactsView().environmentObject(model)
                    } label: {
                        LabeledContent("Blocked contacts",
                                       value: model.blockedContacts.isEmpty ? "" : "\(model.blockedContacts.count)")
                    }
                }

                Section {
                    Toggle("SwiftUI message list", isOn: $useSwiftUIMessageList)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Experimental: render chats with the pure-SwiftUI list instead of "
                         + "the UIKit one. Reopen a chat after changing this.")
                }

                Section {
                    Button(role: .destructive) {
                        closingForSignOut = true
                        presenceDirty = false
                        isPresented = false
                        model.signOut()
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") {
                    savePresenceIfNeeded()
                    isPresented = false
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker(
                    allowsVideos: false,
                    onPicked: { url in model.setAvatar(path: url.path) },
                    onTooLarge: {
                        model.lastError = AttachmentStaging.tooLargeMessage(noun: "image")
                    })
            }
            .onAppear {
                model.requestAccountDetails()
                model.requestSelfPresence()
                model.requestBlocklist()
                model.requestPrivacy()
                alias = model.accountAlias
                syncPresenceFromModel()
            }
            .onChange(of: model.accountAlias) { _, value in
                alias = value
            }
            .onChange(of: model.selfShow) { _, _ in if !presenceDirty { syncPresenceFromModel() } }
            .onChange(of: model.selfStatus) { _, _ in if !presenceDirty { syncPresenceFromModel() } }
            .onDisappear {
                if !closingForSignOut { savePresenceIfNeeded() }
            }
            .alert("Password changed", isPresented: $model.passwordChanged) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your account password was updated on the server.")
            }
        }
    }

    private func saveAlias() {
        model.setAlias(alias)
        aliasSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { aliasSaved = false }
    }

    private func syncPresenceFromModel() {
        presenceShow = model.selfShow
        presenceStatus = model.selfStatus
        presenceDirty = false
    }

    private func savePresenceIfNeeded() {
        guard presenceDirty else { return }
        model.setPresence(show: presenceShow, status: presenceStatus)
        presenceDirty = false
    }
}
