import Foundation

/// Pure decision logic for the chat's "keep pinned to the bottom" behavior,
/// pulled out of the SwiftUI view so the subtle bits that have already regressed
/// once — the at-bottom geometry test and its threshold, and the follow / re-pin
/// conditions — are locked down by `swift test`. GeckoApp calls these, so the
/// tests exercise exactly what ships.
///
/// Background (why these shapes): the runtime bugs themselves (a `scrollTo` to a
/// zero-height anchor that no-ops, a retry loop that out-runs layout) aren't
/// unit-testable, but the math that decides *whether* we're at the bottom and
/// *whether* to follow is — and that's what was wrong.
enum ChatScroll {
    /// How close (pt) the visible content bottom must be to the content bottom to
    /// count as "at the bottom". Sized to clear the message list's trailing
    /// padding: a 1px anchor below that padding is never itself visible, which is
    /// why detection is geometry-based rather than anchor-visibility-based.
    static let atBottomThreshold: CGFloat = 80

    /// Whether the scroll view is at (or within `threshold` of) the bottom.
    ///
    /// `visibleMaxY` MUST be the bottom edge of the visible content in content
    /// coordinates (`ScrollGeometry.visibleRect.maxY`). Deriving it from
    /// `contentOffset.y + containerSize.height` instead undershoots by the bottom
    /// inset region (~the composer) and reads "not at bottom" while the last row
    /// is visibly pinned — the original bug. A negative gap (overshoot during
    /// image-load layout flux) still counts as at the bottom.
    static func isAtBottom(contentHeight: CGFloat,
                           visibleMaxY: CGFloat,
                           threshold: CGFloat = atBottomThreshold) -> Bool {
        contentHeight - visibleMaxY <= threshold
    }

    /// Whether newly-arrived or newly-grown content should pull the view to the
    /// bottom: only when we're already following it — at the bottom, or mid-settle
    /// on a fresh open / right after a send (`settling`). Never yanks a user who
    /// has scrolled up into history.
    static func shouldFollow(isAtBottom: Bool, settling: Bool) -> Bool {
        isAtBottom || settling
    }

    /// Whether the frame-spaced re-pin loop should take another step: tries left,
    /// still following (`settling`), and not yet landed at the bottom. Stops the
    /// loop the moment any of those fails so it can't fight the user or spin.
    static func shouldContinueRepin(attemptsLeft: Int,
                                    settling: Bool,
                                    isAtBottom: Bool) -> Bool {
        attemptsLeft > 0 && settling && !isAtBottom
    }
}
