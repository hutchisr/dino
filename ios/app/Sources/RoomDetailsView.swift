import SwiftUI

/// Group-chat details: header, owner settings (name / private / moderated),
/// topic, invite, and separate online-participant and offline-member lists.
struct RoomDetailsView: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    /// Called with a member's JID when "Message" is chosen; the parent
    /// dismisses the sheet and opens the DM.
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var inviteJid = ""
    @State private var editingName = false
    @State private var editingTopic = false
    @State private var nameDraft = ""
    @State private var topicDraft = ""
    @State private var showPhotoPicker = false
    @StateObject private var avatarSelection = AttachmentSelectionPipeline()
    @FocusState private var inviteFocused: Bool

    private var occupants: [Occupant] { model.occupants[conversationId] ?? [] }
    private var offlineMembers: [OfflineMember] { model.offlineMembers[conversationId] ?? [] }
    private var me: Occupant? { occupants.first { $0.isSelf } }
    private var info: RoomInfo { model.roomInfo[conversationId] ?? RoomInfo() }
    private var conversation: XmppConversation? { model.conversations.first { $0.id == conversationId } }

    private var inviteSuggestions: [RosterContact] {
        let query = inviteJid.trimmingCharacters(in: .whitespaces)
        guard inviteFocused, !query.isEmpty else { return [] }
        return Array(model.roster.lazy.filter {
            $0.displayName.localizedStandardContains(query) ||
            $0.id.localizedStandardContains(query)
        }.prefix(5))
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                if !info.subject.isEmpty || info.canEditSubject { topicSection }
                if info.iAmOwner { settingsSection }
                inviteSection
                participantsSection
                if !offlineMembers.isEmpty { offlineMembersSection }
            }
            .navigationTitle("Room details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
#if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .padding(4)
                    }
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
                .sharedBackgroundVisibility(.hidden)
#else
                Button("Close") { dismiss() }
#endif
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
                pipeline: avatarSelection,
                onPicked: { url in model.setRoomAvatar(conversationId, path: url.path) },
                onTooLarge: {
                    model.lastError = AttachmentStaging.tooLargeMessage(noun: "image")
                },
                onError: { model.lastError = $0 })
        }
        .onDisappear {
            avatarSelection.cancel()
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
                    .accessibilityLabel("Change room photo")
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
                    .focused($inviteFocused)
                Button("Invite", action: sendInvite)
                    .disabled(inviteJid.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(inviteSuggestions) { contact in
                Button {
                    inviteJid = contact.id
                    inviteFocused = false
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(jid: contact.id, name: contact.displayName, isGroup: false, size: 32,
                                   presence: contact.show, avatarPath: model.avatars[contact.id],
                                   requestAvatar: { model.ensureAvatar(for: contact.id) })
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.displayName)
                                .foregroundStyle(.primary)
                            if contact.displayName != contact.id {
                                Text(contact.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Invite \(contact.displayName), \(contact.id)")
            }
        }
    }

    private var participantsSection: some View {
        Section("Online (\(occupants.count))") {
            ForEach(occupants) { occupant in
                NavigationLink {
                    MemberDetailView(conversationId: conversationId, member: .online(occupant), me: me,
                                     onMessage: { onSelect(occupant.jid) })
                        .environmentObject(model)
                } label: {
                    occupantRow(occupant)
                }
            }
        }
    }

    private var offlineMembersSection: some View {
        Section("Offline (\(offlineMembers.count))") {
            ForEach(offlineMembers) { member in
                NavigationLink {
                    MemberDetailView(conversationId: conversationId, member: .offline(member), me: me,
                                     onMessage: { onSelect(member.jid) })
                        .environmentObject(model)
                } label: {
                    offlineMemberRow(member)
                }
            }
        }
    }

    private func offlineMemberRow(_ member: OfflineMember) -> some View {
        HStack(spacing: 10) {
            AvatarView(jid: member.jid, name: member.name, isGroup: false, size: 32,
                       avatarPath: model.avatars[member.jid],
                       requestAvatar: { model.ensureAvatar(for: member.jid) })
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name).foregroundStyle(.primary)
                if member.name != member.jid {
                    Text(member.jid).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let badge = member.badge {
                MemberBadge(text: badge, color: member.affiliation == "owner" ? .orange : .blue)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.name), offline")
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
