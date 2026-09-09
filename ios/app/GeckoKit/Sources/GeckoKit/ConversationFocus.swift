enum DirectChatRouteAction: Equatable {
    case navigate(Int32)
    case startConversation(String)
}

struct DirectChatRouteState {
    private(set) var pendingJid: String?
    private var receivedConversationSnapshot = false
    private var startedJid: String?

    mutating func request(
        jid: String,
        matchingConversation: Int32?
    ) -> [DirectChatRouteAction] {
        if pendingJid != jid {
            startedJid = nil
        }
        pendingJid = jid
        return resolve(matchingConversation: matchingConversation)
    }

    mutating func conversationsUpdated(
        matchingConversation: Int32?
    ) -> [DirectChatRouteAction] {
        receivedConversationSnapshot = true
        return resolve(matchingConversation: matchingConversation)
    }

    private mutating func resolve(
        matchingConversation: Int32?
    ) -> [DirectChatRouteAction] {
        guard receivedConversationSnapshot, let jid = pendingJid else { return [] }
        if let conversation = matchingConversation {
            pendingJid = nil
            startedJid = nil
            return [.navigate(conversation)]
        }
        guard startedJid != jid else { return [] }
        startedJid = jid
        return [.startConversation(jid)]
    }
}

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
