import SwiftUI

/// The account's blocked contacts (XEP-0191), with unblock.
struct BlockedContactsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if !model.blockingSupported {
                Text("Your server doesn't support blocking.")
                    .foregroundStyle(.secondary)
            } else if model.blockedContacts.isEmpty {
                Text("No blocked contacts.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.blockedContacts, id: \.self) { jid in
                    HStack(spacing: 10) {
                        AvatarView(jid: jid, name: jid, isGroup: false, size: 32)
                        Text(jid).lineLimit(1)
                        Spacer()
                        Button("Unblock") { model.unblockContact(jid) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.requestBlocklist() }
    }
}
