import SwiftUI
import UIKit

/// Small capsule badge (Owner / Admin / Mod / Muted) shown next to a participant.
struct MemberBadge: View {
    let text: String
    let color: Color
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .foregroundStyle(Color(uiColor: .label))
        .overlay {
            Capsule().stroke(color, lineWidth: 1)
        }
    }
}

extension Occupant {
    /// The badge's capsule colour. Only meaningful when `badge` is non-nil.
    var badgeColor: Color {
        if isOwner { return .orange }
        if isAdmin { return .blue }
        if isModerator { return .gray }
        return .secondary  // muted
    }

    /// An icon to pair with the badge, for states that aren't a rank.
    var badgeIcon: String? { isMuted && !isModerator ? "mic.slash.fill" : nil }
}

/// Detail + moderation actions for one online or offline MUC member. Actions are gated by
/// the viewer's own affiliation/role; the server is the final authority, so
/// gating here only hides clearly-disallowed actions.
struct MemberDetailView: View {
    @EnvironmentObject var model: AppModel
    let conversationId: Int32
    let member: Member
    let me: Occupant?
    let onMessage: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmKick = false
    @State private var confirmBan = false

    enum Member {
        case online(Occupant)
        case offline(OfflineMember)

        var occupant: Occupant? {
            if case .online(let occupant) = self { return occupant }
            return nil
        }

        var name: String {
            switch self {
            case .online(let occupant): return occupant.nick
            case .offline(let member): return member.name
            }
        }

        var jid: String {
            switch self {
            case .online(let occupant): return occupant.jid
            case .offline(let member): return member.jid
            }
        }

        var realJid: String? {
            switch self {
            case .online(let occupant): return occupant.realJid
            case .offline(let member): return member.jid
            }
        }

        var affiliation: String {
            switch self {
            case .online(let occupant): return occupant.affiliation
            case .offline(let member): return member.affiliation
            }
        }

        var badge: String? {
            switch self {
            case .online(let occupant): return occupant.badge
            case .offline(let member): return member.badge
            }
        }
    }

    private var iAmOwner: Bool { me?.isOwner ?? false }
    private var iAmAdmin: Bool { me?.isAdmin ?? false }

    private func rank(_ affiliation: String) -> Int {
        switch affiliation {
        case "owner": return 3
        case "admin": return 2
        case "member": return 1
        default: return 0
        }
    }

    /// The single moderation gate: owners can manage anyone, admins only
    /// members/none (not other admins or owners), and never yourself. Anyone
    /// who passes it is an owner or admin, so they already hold both the
    /// affiliation and moderation rights the individual actions need.
    private var canManageTarget: Bool {
        guard member.occupant?.isSelf != true else { return false }
        if iAmOwner { return true }
        if iAmAdmin { return rank(member.affiliation) < 2 }
        return false
    }

    /// Voice is meaningful only for plain members/visitors, not staff or mods.
    private var canManageVoice: Bool {
        guard let occupant = member.occupant else { return false }
        return canManageTarget && !occupant.isModerator
            && !occupant.isOwner && !occupant.isAdmin
    }

    var body: some View {
        List {
            Section { header }

            if member.occupant?.isSelf != true {
                Section {
                    Button(action: onMessage) {
                        Label("Message", systemImage: "message")
                    }
                }
            }

            if let occupant = member.occupant, canManageVoice {
                Section("Voice") {
                    if occupant.hasVoice {
                        Button { run { model.mucSetRole(conversationId, nick: occupant.nick, role: "visitor") } } label: {
                            Label("Revoke voice", systemImage: "mic.slash.fill")
                        }
                    } else {
                        Button { run { model.mucSetRole(conversationId, nick: occupant.nick, role: "participant") } } label: {
                            Label("Grant voice", systemImage: "mic.fill")
                        }
                    }
                }
            }

            if canManageTarget {
                Section("Role") {
                    if iAmOwner && member.affiliation != "owner" {
                        Button { run { setAffiliation("owner") } } label: { Label("Make owner", systemImage: "crown.fill") }
                    }
                    if iAmOwner && member.affiliation != "admin" {
                        Button { run { setAffiliation("admin") } } label: { Label("Make admin", systemImage: "star.fill") }
                    }
                    if member.affiliation != "member" {
                        Button { run { setAffiliation("member") } } label: { Label("Make member", systemImage: "person.fill.checkmark") }
                    }
                    if member.affiliation != "none" {
                        Button { run { setAffiliation("none") } } label: { Label("Remove affiliation", systemImage: "person.fill.xmark") }
                    }
                }
            }

            if canManageTarget {
                Section {
                    if member.occupant != nil {
                        Button(role: .destructive) { confirmKick = true } label: {
                            Label("Kick from room", systemImage: "door.left.hand.open")
                        }
                    }
                    Button(role: .destructive) { confirmBan = true } label: {
                        Label("Ban from room", systemImage: "nosign")
                    }
                }
            }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Kick \(member.name)?", isPresented: $confirmKick, titleVisibility: .visible) {
            if let occupant = member.occupant {
                Button("Kick", role: .destructive) { run { model.mucKick(conversationId, nick: occupant.nick) } }
            }
        }
        .confirmationDialog("Ban \(member.name)?", isPresented: $confirmBan, titleVisibility: .visible) {
            Button("Ban", role: .destructive) { run { setAffiliation("outcast") } }
        } message: {
            Text("They'll be removed and blocked from rejoining.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(jid: member.jid, name: member.name, isGroup: false, size: 52,
                       avatarPath: model.avatars[member.jid],
                       requestAvatar: { model.ensureAvatar(for: member.jid) })
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name).font(.headline)
                if let real = member.realJid {
                    Text(real).font(.caption).foregroundStyle(.secondary)
                }
                if member.occupant == nil {
                    Text("Offline").font(.caption).foregroundStyle(.secondary)
                }
                if let badge = member.badge {
                    MemberBadge(text: badge,
                                color: member.occupant?.badgeColor ?? (member.affiliation == "owner" ? .orange : .blue),
                                systemImage: member.occupant?.badgeIcon)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func setAffiliation(_ affiliation: String) {
        model.mucSetAffiliation(conversationId, jid: member.jid, affiliation: affiliation)
    }

    /// Perform an action then pop back to the (auto-refreshing) participant list.
    private func run(_ action: () -> Void) {
        action()
        dismiss()
    }
}
