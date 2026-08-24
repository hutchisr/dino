struct LocalNotificationPolicyInput {
    var appIsActive: Bool
    var isNew: Bool
    var isSynced: Bool
    var direction: String
    var notifyEffective: String
    var isGroupchat: Bool
    var mentioned: Bool
}

func shouldPostLocalNotification(_ input: LocalNotificationPolicyInput) -> Bool {
    guard !input.appIsActive, input.isNew, !input.isSynced, input.direction == "in" else {
        return false
    }
    switch input.notifyEffective {
    case "off":
        return false
    case "highlight":
        return !input.isGroupchat || input.mentioned
    default:
        return true
    }
}
