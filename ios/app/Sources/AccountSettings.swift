import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var alias = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showPhotoPicker = false
    @State private var aliasSaved = false

    private var jid: String { model.accounts.first?.id ?? "" }

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
                                AvatarView(jid: jid, name: model.accountAlias.isEmpty ? jid : model.accountAlias, isGroup: false, size: 88)
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
                    Button(role: .destructive) {
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
                Button("Done") { isPresented = false }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { url in
                    model.setAvatar(path: url.path)
                }
            }
            .onAppear {
                model.requestAccountDetails()
                alias = model.accountAlias
            }
            .onChange(of: model.accountAlias) { value in
                alias = value
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
}
