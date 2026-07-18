/// Pagination state for raw content-item pages. This deliberately never reads
/// rendered messages: unsupported items and out-of-window updates must not move
/// or replace the database cursor.
struct HistoryPagination {
    private(set) var nextBeforeItemID: Int32?
    private(set) var pendingBeforeItemID: Int32?
    private(set) var reachedBeginning = false

    var canLoadOlder: Bool {
        nextBeforeItemID != nil && !reachedBeginning
    }

    mutating func replaceWithLatestPage(oldestItemID: Int32?, complete: Bool) {
        nextBeforeItemID = oldestItemID
        pendingBeforeItemID = nil
        reachedBeginning = complete || oldestItemID == nil
    }

    mutating func refreshLatestPage(oldestItemID: Int32?, complete: Bool) {
        if complete {
            nextBeforeItemID = oldestItemID
            pendingBeforeItemID = nil
            reachedBeginning = true
        } else if nextBeforeItemID == nil, !reachedBeginning {
            nextBeforeItemID = oldestItemID
            reachedBeginning = oldestItemID == nil
        }
    }

    mutating func beginOlderRequest() -> Int32? {
        guard pendingBeforeItemID == nil, !reachedBeginning,
              let nextBeforeItemID else { return nil }
        pendingBeforeItemID = nextBeforeItemID
        return nextBeforeItemID
    }

    @discardableResult
    mutating func receiveOlderPage(
        requestedBeforeItemID: Int32,
        oldestItemID: Int32?,
        complete: Bool
    ) -> Bool {
        guard pendingBeforeItemID == requestedBeforeItemID else { return false }
        pendingBeforeItemID = nil
        if let oldestItemID {
            nextBeforeItemID = oldestItemID
        }
        reachedBeginning = complete || oldestItemID == nil || oldestItemID == requestedBeforeItemID
        return true
    }
}
