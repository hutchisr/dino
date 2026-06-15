import XCTest
@testable import GeckoKit

final class ChatScrollIsAtBottomTests: XCTestCase {
    // Real numbers pulled from the Simulator logs while debugging this:
    // resting at the bottom the visible content bottom sits ~50pt above the
    // content bottom (the trailing padding), well inside the 80pt threshold.
    func testRestingAtBottomCountsAsAtBottom() {
        XCTAssertTrue(ChatScroll.isAtBottom(contentHeight: 7373, visibleMaxY: 7322))
    }

    // Overshoot during image-load layout flux: visibleMaxY briefly exceeds
    // contentHeight (negative gap). Still at the bottom.
    func testOvershootCountsAsAtBottom() {
        XCTAssertTrue(ChatScroll.isAtBottom(contentHeight: 7236, visibleMaxY: 7322))
    }

    func testScrolledUpIntoHistoryIsNotAtBottom() {
        // A screenful up — clearly not at the bottom.
        XCTAssertFalse(ChatScroll.isAtBottom(contentHeight: 7373, visibleMaxY: 6700))
    }

    func testThresholdBoundaryIsInclusive() {
        // Exactly `threshold` away counts; one past does not.
        XCTAssertTrue(ChatScroll.isAtBottom(contentHeight: 1000, visibleMaxY: 920))   // gap 80
        XCTAssertFalse(ChatScroll.isAtBottom(contentHeight: 1000, visibleMaxY: 919))  // gap 81
    }

    func testCustomThresholdIsHonored() {
        // gap 50 — at bottom under the default 80, not under a tight 40.
        XCTAssertTrue(ChatScroll.isAtBottom(contentHeight: 1000, visibleMaxY: 950))
        XCTAssertFalse(ChatScroll.isAtBottom(contentHeight: 1000, visibleMaxY: 950, threshold: 40))
    }

    // Guards the formula itself: the broken version used
    // contentOffset.y + containerSize.height, which trails visibleRect.maxY by
    // the inset region (~218pt here). That value would read "not at bottom"
    // while visibly pinned — so a regression to it must fail a test.
    func testBrokenOffsetFormulaWouldNotPass() {
        let contentHeight: CGFloat = 7373
        let visibleMaxY: CGFloat = 7322           // correct: at bottom
        let offsetPlusContainer: CGFloat = 7104   // broken: undershoots by ~218
        XCTAssertTrue(ChatScroll.isAtBottom(contentHeight: contentHeight, visibleMaxY: visibleMaxY))
        XCTAssertFalse(ChatScroll.isAtBottom(contentHeight: contentHeight, visibleMaxY: offsetPlusContainer))
    }
}

final class ChatScrollFollowTests: XCTestCase {
    func testFollowsWhenAtBottom() {
        XCTAssertTrue(ChatScroll.shouldFollow(isAtBottom: true, settling: false))
    }

    func testFollowsWhileSettlingEvenIfNotAtBottom() {
        // The growth itself can push the bottom off-screen (isAtBottom false)
        // right when we need to follow; `settling` keeps us following.
        XCTAssertTrue(ChatScroll.shouldFollow(isAtBottom: false, settling: true))
    }

    func testDoesNotFollowWhenScrolledUpAndNotSettling() {
        XCTAssertFalse(ChatScroll.shouldFollow(isAtBottom: false, settling: false))
    }
}

final class ChatScrollRepinTests: XCTestCase {
    func testContinuesWhileFollowingAndNotYetLanded() {
        XCTAssertTrue(ChatScroll.shouldContinueRepin(attemptsLeft: 15, settling: true, isAtBottom: false))
    }

    func testStopsOnceLanded() {
        XCTAssertFalse(ChatScroll.shouldContinueRepin(attemptsLeft: 15, settling: true, isAtBottom: true))
    }

    func testStopsWhenUserTakesOver() {
        // User scrolled (settling cleared) — don't fight them back to the bottom.
        XCTAssertFalse(ChatScroll.shouldContinueRepin(attemptsLeft: 15, settling: false, isAtBottom: false))
    }

    func testStopsWhenAttemptsExhausted() {
        XCTAssertFalse(ChatScroll.shouldContinueRepin(attemptsLeft: 0, settling: true, isAtBottom: false))
    }
}
