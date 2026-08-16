struct NewestMessageUpdatePolicy: Equatable {
    let followsNewest: Bool
    let animates: Bool
}

/// Chooses how the list responds when its newest stable message ID changes.
/// Archive synchronization stays pinned without animating each replayed item.
func newestMessageUpdatePolicy(
    initialScrollCompleted: Bool,
    updateWasSynced: Bool,
    isFollowingBottom: Bool
) -> NewestMessageUpdatePolicy {
    guard initialScrollCompleted else {
        return NewestMessageUpdatePolicy(followsNewest: true, animates: false)
    }
    guard isFollowingBottom else {
        return NewestMessageUpdatePolicy(followsNewest: false, animates: false)
    }
    return NewestMessageUpdatePolicy(followsNewest: true, animates: !updateWasSynced)
}
