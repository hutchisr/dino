struct MucRemoval {
    let conversationID: Int32
    let room: String
    let reason: String

    func apply<Conversation>(
        to conversations: inout [Conversation],
        navigation: inout [Int32],
        id: (Conversation) -> Int32,
        name: (Conversation) -> String
    ) -> String {
        let displayName = conversations.first(where: { id($0) == conversationID }).map(name)
        let roomName = (displayName?.isEmpty == false ? displayName : nil)
            ?? (room.isEmpty ? "the group chat" : room)

        conversations.removeAll { id($0) == conversationID }
        navigation.removeAll { $0 == conversationID }

        switch reason {
        case "banned":
            return "You were banned from \(roomName)."
        case "kicked":
            return "You were kicked from \(roomName)."
        case "affiliation_changed":
            return "You were removed from \(roomName) because your room affiliation changed."
        case "members_only":
            return "You were removed because \(roomName) is now members-only."
        case "shutdown":
            return "\(roomName) was shut down."
        default:
            return "You were removed from \(roomName)."
        }
    }
}
