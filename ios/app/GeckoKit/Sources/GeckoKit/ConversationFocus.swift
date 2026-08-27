enum ConversationFocusAction: Equatable {
    case blur(Int32)
    case focus(Int32)
}

struct ConversationFocusState {
    private(set) var focusedConversation: Int32?

    mutating func transition(to conversation: Int32?) -> [ConversationFocusAction] {
        guard focusedConversation != conversation else { return [] }
        let previous = focusedConversation
        focusedConversation = conversation

        var actions: [ConversationFocusAction] = []
        if let previous {
            actions.append(.blur(previous))
        }
        if let conversation {
            actions.append(.focus(conversation))
        }
        return actions
    }

    mutating func conversationDisappeared(_ conversation: Int32) -> [ConversationFocusAction] {
        guard focusedConversation == conversation else { return [] }
        focusedConversation = nil
        return [.blur(conversation)]
    }
}
