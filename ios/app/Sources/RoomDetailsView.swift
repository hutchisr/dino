import SwiftUI

/// Group-chat details: header, owner settings (name / private / moderated),
/// topic, invite, and the participant list (each row pushes a MemberDetailView).
struct RoomDetailsView: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    /// Called with a participant's nick when "Message" is chosen; the parent
    /// dismisses the sheet and opens the DM.
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var inviteJid = ""
    @State private var editingName = false
    @State private var editingTopic = false
    @State private var nameDraft = ""
    @State private var topicDraft = ""
    @State private var showPhotoPicker = false

    private var occupants: [Occupant] { model.occupants[conversationId] ?? [] }
    private var me: Occupant? { occupants.first { $0.isSelf } }
    private var info: RoomInfo { model.roomInfo[conversationId] ?? RoomInfo() }
    private var conversation: XmppConversation? { model.conversations.first { $0.id == conversationId } }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                if !info.subject.isEmpty || info.canEditSubject { topicSection }
                if info.iAmOwner { settingsSection }
                inviteSection
                participantsSection
            }
            .navigationTitle("Room details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            model.requestRoomInfo(conversationId)
            model.requestOccupants(conversationId)
        }
        .alert("Room name", isPresented: $editingName) {
            TextField("Name", text: $nameDraft)
            Button("Save") { model.setRoomName(conversationId, nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Topic", isPresented: $editingTopic) {
            TextField("Topic", text: $topicDraft)
            Button("Save") { model.setRoomSubject(conversationId, topicDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(
                allowsVideos: false,
                onPicked: { url in model.setRoomAvatar(conversationId, path: url.path) },
                onTooLarge: {
                    model.lastError = AttachmentStaging.tooLargeMessage(noun: "image")
                })
        }
    }

    private var avatar: some View {
        let jid = conversation?.jid ?? ""
        return AvatarView(jid: jid, name: conversation?.name ?? "", isGroup: true, size: 52,
                          avatarPath: model.avatars[jid],
                          requestAvatar: jid.isEmpty ? nil : { model.ensureAvatar(for: jid) })
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                if info.iAmOwner {
                    Button { showPhotoPicker = true } label: {
                        avatar.overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 9))
                                .padding(5)
                                .background(Circle().fill(Color.accentColor))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    avatar
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation?.name ?? "Group chat").font(.headline)
                    if let jid = conversation?.jid {
                        Text(jid).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var topicSection: some View {
        Section("Topic") {
            if info.canEditSubject {
                Button {
                    topicDraft = info.subject
                    editingTopic = true
                } label: {
                    Text(info.subject.isEmpty ? "Set a topic…" : info.subject)
                        .foregroundStyle(info.subject.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(info.subject)
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                nameDraft = conversation?.name ?? ""
                editingName = true
            } label: {
                LabeledContent("Name", value: conversation?.name ?? "")
            }
            Toggle("Private", isOn: Binding(
                get: { info.isPrivate },
                set: { model.setRoomPrivate(conversationId, $0) }))
            Toggle("Moderated", isOn: Binding(
                get: { info.isModerated },
                set: { model.setRoomModerated(conversationId, $0) }))
        } header: {
            Text("Settings")
        } footer: {
            Text("Private rooms are members-only and show real addresses (needed for encryption). "
                 + "Moderated rooms require granted voice to speak.")
        }
    }

    private var inviteSection: some View {
        Section("Invite") {
            HStack {
                TextField("user@example.org", text: $inviteJid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(sendInvite)
                Button("Invite", action: sendInvite)
                    .disabled(inviteJid.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var participantsSection: some View {
        Section("Participants (\(occupants.count))") {
            ForEach(occupants) { occupant in
                NavigationLink {
                    MemberDetailView(conversationId: conversationId, occupant: occupant, me: me,
                                     onMessage: { onSelect(occupant.nick) })
                        .environmentObject(model)
                } label: {
                    occupantRow(occupant)
                }
            }
        }
    }

    private func sendInvite() {
        let jid = inviteJid.trimmingCharacters(in: .whitespaces)
        guard !jid.isEmpty else { return }
        model.inviteToRoom(conversationId, jid: jid)
        inviteJid = ""
    }

    @ViewBuilder
    private func occupantRow(_ occupant: Occupant) -> some View {
        HStack(spacing: 10) {
            AvatarView(jid: occupant.jid, name: occupant.nick, isGroup: false, size: 32,
                       avatarPath: model.avatars[occupant.jid],
                       requestAvatar: { model.ensureAvatar(for: occupant.jid) })
            VStack(alignment: .leading, spacing: 1) {
                Text(occupant.nick).foregroundStyle(.primary)
                if let real = occupant.realJid {
                    Text(real).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if occupant.isSelf {
                Text("you").font(.caption).foregroundStyle(.secondary)
            }
            if let badge = occupant.badge {
                MemberBadge(text: badge, color: occupant.badgeColor, systemImage: occupant.badgeIcon)
            }
        }
        .contentShape(.rect)
    }
}
