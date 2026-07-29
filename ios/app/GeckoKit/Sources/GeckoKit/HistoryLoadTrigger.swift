/// Geometry-driven gate for loading older chat history. The initial page waits
/// for a real scroll so opening a conversation cannot page by itself. After a
/// prepend it waits for the preserved viewport's geometry before rearming, so
/// layout changes cannot cascade through pages on their own.
struct HistoryLoadTrigger {
    enum Zone: Equatable {
        case near
        case middle
        case away
    }

    enum State: Equatable {
        case disabled
        case awaitingUserScroll
        case armed
        case loading
        case awaitingViewportSettle
    }

    static let loadDistance = 240.0
    static let rearmDistance = 360.0

    private(set) var state = State.disabled
    private(set) var triggerDistance = loadDistance
    static func zone(distanceFromTop rawDistance: Double) -> Zone {
        guard rawDistance.isFinite else { return .middle }
        let distance = max(0, rawDistance)
        if distance <= loadDistance { return .near }
        if distance >= rearmDistance { return .away }
        return .middle
    }

    /// Unit anchor that keeps a visible row at the same vertical offset when
    /// SwiftUI repositions that stable ID after rows are prepended. The same
    /// alignment math also works for a row taller than the viewport.
    static func viewportAnchorY(
        rowMinY: Double,
        rowHeight: Double,
        viewportMinY: Double,
        viewportHeight: Double
    ) -> Double? {
        let travel = viewportHeight - rowHeight
        guard rowMinY.isFinite, rowHeight.isFinite,
              viewportMinY.isFinite, viewportHeight.isFinite,
              rowHeight >= 0, abs(travel) > 0.001 else { return nil }
        let anchor = (rowMinY - viewportMinY) / travel
        guard (0...1).contains(anchor) else { return nil }
        return anchor
    }

    /// Whether SwiftUI's automatic content-offset adjustment moved the viewport
    /// by approximately the height of the prepended rows. A little slack allows
    /// the user's active scroll velocity to advance between geometry samples.
    static func automaticAdjustmentPreservedViewport(
        previousDistanceFromTop: Double,
        previousContentHeight: Double,
        currentDistanceFromTop: Double,
        currentContentHeight: Double
    ) -> Bool {
        guard previousDistanceFromTop.isFinite,
              previousContentHeight.isFinite,
              currentDistanceFromTop.isFinite,
              currentContentHeight.isFinite else { return false }
        let addedHeight = currentContentHeight - previousContentHeight
        guard addedHeight > 1 else { return false }
        let expectedDistance = max(0, previousDistanceFromTop) + addedHeight
        let tolerance = max(24, min(120, addedHeight * 0.1))
        return abs(max(0, currentDistanceFromTop) - expectedDistance) <= tolerance
    }

    /// During an active flick, ordinary displacement can put the first
    /// post-prepend sample outside the tight at-rest tolerance above. Only call
    /// the adjustment failed when a substantial prepend moved by nowhere near
    /// its added height (or implausibly overshot it).
    static func automaticAdjustmentGrosslyFailed(
        previousDistanceFromTop: Double,
        previousContentHeight: Double,
        currentDistanceFromTop: Double,
        currentContentHeight: Double
    ) -> Bool {
        guard previousDistanceFromTop.isFinite,
              previousContentHeight.isFinite,
              currentDistanceFromTop.isFinite,
              currentContentHeight.isFinite else { return true }
        let addedHeight = currentContentHeight - previousContentHeight
        guard addedHeight >= 32 else { return false }
        let expectedDistance = max(0, previousDistanceFromTop) + addedHeight
        let motionAllowance = max(48, min(200, addedHeight * 0.2))
        return abs(max(0, currentDistanceFromTop) - expectedDistance) > motionAllowance
    }

    mutating func setCanLoadOlder(_ allowed: Bool) {
        guard allowed else {
            reset()
            return
        }
        guard state == .disabled else { return }
        state = .awaitingUserScroll
    }

    mutating func beginUserScroll() {
        guard state == .awaitingUserScroll else { return }
        triggerDistance = Self.loadDistance
        state = .armed
    }

    mutating func observe(distanceFromTop rawDistance: Double) -> Bool {
        guard state == .armed, rawDistance.isFinite else { return false }
        let distance = max(0, rawDistance)
        if distance >= Self.rearmDistance {
            triggerDistance = Self.loadDistance
            return false
        }
        guard distance <= triggerDistance else { return false }
        state = .loading
        return true
    }

    /// An underfilled viewport is the one deliberate exception to manual
    /// arming. Its post-layout geometry may keep filling until there is actual
    /// history to scroll through (or the database reports the beginning).
    mutating func loadIfUnderfilled(_ underfilled: Bool) -> Bool {
        guard underfilled,
              state == .awaitingUserScroll || state == .armed else { return false }
        state = .loading
        return true
    }

    mutating func pageCompleted(hasMore: Bool) {
        guard state == .loading else { return }
        guard hasMore else {
            reset()
            return
        }
        state = .awaitingViewportSettle
    }

    /// Rearm after the prepend's automatic adjustment or explicit stable-ID
    /// correction has produced its geometry. Sparse pages use a closer trigger,
    /// so they still require real upward travel without forcing the user to hit
    /// an empty exact top.
    mutating func viewportSettled(distanceFromTop rawDistance: Double) {
        guard state == .awaitingViewportSettle else { return }
        let distance = rawDistance.isFinite ? max(0, rawDistance) : 0
        let requiredTravel = min(64, distance * 0.5)
        triggerDistance = min(Self.loadDistance, max(0, distance - requiredTravel))
        state = .armed
    }

    /// A fallback scroll that never reports confirming geometry must not leave
    /// the gate armed from an invented offset. Require a fresh gesture instead.
    mutating func viewportSettleFailed() {
        guard state == .awaitingViewportSettle else { return }
        triggerDistance = Self.loadDistance
        state = .awaitingUserScroll
    }

    mutating func reset() {
        triggerDistance = Self.loadDistance
        state = .disabled
    }
}

/// Reduces measured geometry into the persistent intent to follow new messages.
/// Layout growth may confirm the bottom, but only user-driven movement may clear
/// an already-established follow intent.
func updatedBottomFollowIntent(
    current: Bool,
    isAtBottom: Bool,
    userInteracting: Bool
) -> Bool {
    if isAtBottom { return true }
    if userInteracting { return false }
    return current
}

/// A measured bottom is authoritative even if the intent missed the final
/// geometry sample after deceleration switched to idle.
func shouldFollowNewestMessage(
    intent: Bool,
    measuredAtBottom: Bool
) -> Bool {
    intent || measuredAtBottom
}

/// SwiftUI's resting lower scroll boundary. The bottom content margin remains
/// slack outside this range, while the top margin shifts the content offset.
func bottomContentOffset(
    contentHeight: Double,
    viewportHeight: Double,
    topInset: Double
) -> Double {
    max(-topInset, contentHeight - viewportHeight - topInset)
}

/// Holds a composer-send scroll request until the asynchronously-created local
/// outgoing item actually appears in the model. A one-shot scroll issued when
/// Send is tapped can only target the previous last row because the bridge
/// creates the pending item on its GLib main context afterward.
struct OutgoingMessageFollowTrigger {
    private(set) var isPending = false
    private var baselineItemID: Int32?

    mutating func begin(latestItemID: Int32?) {
        baselineItemID = latestItemID
        isPending = true
    }

    /// Returns true once for the first outgoing item newer than everything
    /// present when the send began. Incoming traffic, status updates to an
    /// existing item, and prepended history therefore cannot consume it.
    mutating func observe(latestOutgoingItemID: Int32?) -> Bool {
        guard isPending, let latestOutgoingItemID else { return false }
        if let baselineItemID, latestOutgoingItemID <= baselineItemID {
            return false
        }
        isPending = false
        baselineItemID = nil
        return true
    }
}
