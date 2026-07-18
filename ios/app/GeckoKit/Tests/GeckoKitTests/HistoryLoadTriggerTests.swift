import XCTest
@testable import GeckoKit

final class HistoryLoadTriggerTests: XCTestCase {
    func testInitialTopGeometryIsIgnoredUntilPagingIsEnabled() {
        var trigger = HistoryLoadTrigger()

        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
        trigger.setCanLoadOlder(true)
        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
        trigger.beginUserScroll()

        XCTAssertTrue(trigger.observe(distanceFromTop: 240))
        XCTAssertEqual(trigger.state, .loading)
    }

    func testAwayThenNearRequestsOnePage() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()

        XCTAssertTrue(trigger.observe(distanceFromTop: 200))
        XCTAssertEqual(trigger.state, .loading)
        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
        XCTAssertFalse(trigger.observe(distanceFromTop: 1_000))
    }

    func testCompletionRearmsWithoutAnotherUserScroll() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))

        trigger.pageCompleted(hasMore: true)

        XCTAssertEqual(trigger.state, .awaitingViewportSettle)
        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
        trigger.viewportSettled(distanceFromTop: 1_000)
        XCTAssertEqual(trigger.state, .armed)
        XCTAssertTrue(trigger.observe(distanceFromTop: 240))
    }

    func testGeometryWhileLoadingCannotStartAnotherPage() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))
        XCTAssertFalse(trigger.observe(distanceFromTop: 1_000))
        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
    }

    func testCompletionItselfDoesNotStartAnotherPage() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))

        trigger.pageCompleted(hasMore: true)

        XCTAssertEqual(trigger.state, .awaitingViewportSettle)
        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
    }

    func testUnderfilledViewportContinuesOnePageAtATime() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)

        XCTAssertTrue(trigger.loadIfUnderfilled(true))
        XCTAssertEqual(trigger.state, .loading)
        XCTAssertFalse(trigger.loadIfUnderfilled(true))

        trigger.pageCompleted(hasMore: true)
        XCTAssertEqual(trigger.state, .awaitingViewportSettle)
        trigger.viewportSettled(distanceFromTop: 0)
        XCTAssertTrue(trigger.loadIfUnderfilled(true))

        trigger.pageCompleted(hasMore: false)
        XCTAssertEqual(trigger.state, .disabled)
    }

    func testFilledViewportDoesNotAutoLoadAfterCompletion() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        XCTAssertTrue(trigger.loadIfUnderfilled(true))

        trigger.pageCompleted(hasMore: true)
        trigger.viewportSettled(distanceFromTop: 1_000)

        XCTAssertFalse(trigger.loadIfUnderfilled(false))
        XCTAssertEqual(trigger.state, .armed)
    }

    func testTerminalPageDisablesPagination() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))

        trigger.pageCompleted(hasMore: false)

        XCTAssertEqual(trigger.state, .disabled)
        XCTAssertFalse(trigger.observe(distanceFromTop: 1_000))
        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
    }

    func testResetIgnoresStaleCompletion() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))

        trigger.reset()
        trigger.pageCompleted(hasMore: true)

        XCTAssertEqual(trigger.state, .disabled)
    }

    func testSparsePageRequiresMoreUpwardTravelWithoutAnotherGesture() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))

        trigger.pageCompleted(hasMore: true)
        trigger.viewportSettled(distanceFromTop: 80)

        XCTAssertEqual(trigger.state, .armed)
        XCTAssertEqual(trigger.triggerDistance, 40)
        XCTAssertFalse(trigger.observe(distanceFromTop: 41))
        XCTAssertTrue(trigger.observe(distanceFromTop: 40))
    }

    func testLargePageRearmsAtNormalPrefetchDistance() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))

        trigger.pageCompleted(hasMore: true)
        trigger.viewportSettled(distanceFromTop: 1_000)

        XCTAssertEqual(trigger.triggerDistance, HistoryLoadTrigger.loadDistance)
        XCTAssertFalse(trigger.observe(distanceFromTop: 241))
        XCTAssertTrue(trigger.observe(distanceFromTop: 240))
    }

    func testMovingAwayRestoresNormalThresholdAfterSparsePage() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))
        trigger.pageCompleted(hasMore: true)
        trigger.viewportSettled(distanceFromTop: 80)
        XCTAssertEqual(trigger.triggerDistance, 40)

        XCTAssertFalse(trigger.observe(distanceFromTop: 1_000))

        XCTAssertEqual(trigger.triggerDistance, HistoryLoadTrigger.loadDistance)
        XCTAssertFalse(trigger.observe(distanceFromTop: 241))
        XCTAssertTrue(trigger.observe(distanceFromTop: 240))
    }

    func testFailedViewportSettleRequiresFreshGesture() {
        var trigger = HistoryLoadTrigger()
        trigger.setCanLoadOlder(true)
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))
        trigger.pageCompleted(hasMore: true)

        trigger.viewportSettleFailed()

        XCTAssertEqual(trigger.state, .awaitingUserScroll)
        XCTAssertFalse(trigger.observe(distanceFromTop: 0))
        trigger.beginUserScroll()
        XCTAssertTrue(trigger.observe(distanceFromTop: 0))
    }

    func testDistanceZonesUseHysteresisThresholds() {
        XCTAssertEqual(HistoryLoadTrigger.zone(distanceFromTop: 0), .near)
        XCTAssertEqual(HistoryLoadTrigger.zone(distanceFromTop: 240), .near)
        XCTAssertEqual(HistoryLoadTrigger.zone(distanceFromTop: 241), .middle)
        XCTAssertEqual(HistoryLoadTrigger.zone(distanceFromTop: 359), .middle)
        XCTAssertEqual(HistoryLoadTrigger.zone(distanceFromTop: 360), .away)
        XCTAssertEqual(HistoryLoadTrigger.zone(distanceFromTop: .nan), .middle)
    }

    func testViewportAnchorPreservesFullyVisibleRowOffset() throws {
        let anchor = try XCTUnwrap(HistoryLoadTrigger.viewportAnchorY(
            rowMinY: 220,
            rowHeight: 80,
            viewportMinY: 100,
            viewportHeight: 600))
        XCTAssertEqual(anchor, 120.0 / 520.0, accuracy: 0.000_001)
    }

    func testViewportAnchorRejectsUnrepresentableOffsetAndHandlesOversizedRows() {
        XCTAssertNil(
            HistoryLoadTrigger.viewportAnchorY(
                rowMinY: 50,
                rowHeight: 80,
                viewportMinY: 100,
                viewportHeight: 600))
        XCTAssertEqual(
            HistoryLoadTrigger.viewportAnchorY(
                rowMinY: -100,
                rowHeight: 800,
                viewportMinY: 0,
                viewportHeight: 600),
            0.5)
        XCTAssertNil(
            HistoryLoadTrigger.viewportAnchorY(
                rowMinY: 100,
                rowHeight: 600,
                viewportMinY: 100,
                viewportHeight: 600))
    }

    func testAutomaticAdjustmentRecognizesPreservedViewport() {
        XCTAssertTrue(HistoryLoadTrigger.automaticAdjustmentPreservedViewport(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 1_090,
            currentContentHeight: 3_000))
    }

    func testAutomaticAdjustmentRejectsUnchangedViewportOffset() {
        XCTAssertFalse(HistoryLoadTrigger.automaticAdjustmentPreservedViewport(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 120,
            currentContentHeight: 3_000))
    }

    func testAutomaticAdjustmentRejectsGrossOvershoot() {
        XCTAssertFalse(HistoryLoadTrigger.automaticAdjustmentPreservedViewport(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 1_500,
            currentContentHeight: 3_000))
    }

    func testActiveAdjustmentOnlyRejectsGrossFailure() {
        XCTAssertTrue(HistoryLoadTrigger.automaticAdjustmentGrosslyFailed(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 120,
            currentContentHeight: 3_000))
        XCTAssertFalse(HistoryLoadTrigger.automaticAdjustmentGrosslyFailed(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 950,
            currentContentHeight: 3_000))
        XCTAssertTrue(HistoryLoadTrigger.automaticAdjustmentGrosslyFailed(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 370,
            currentContentHeight: 3_000))
    }

    func testActiveAdjustmentDoesNotCorrectTraversedSparsePage() {
        XCTAssertFalse(HistoryLoadTrigger.automaticAdjustmentGrosslyFailed(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 170,
            currentContentHeight: 2_080))
    }

    func testActiveAdjustmentRejectsUnadjustedSparsePage() {
        XCTAssertTrue(HistoryLoadTrigger.automaticAdjustmentGrosslyFailed(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 120,
            currentContentHeight: 2_080))
    }

    func testAutomaticAdjustmentRejectsInvalidOrUnchangedContentHeight() {
        XCTAssertFalse(HistoryLoadTrigger.automaticAdjustmentPreservedViewport(
            previousDistanceFromTop: 120,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 120,
            currentContentHeight: 2_000))
        XCTAssertFalse(HistoryLoadTrigger.automaticAdjustmentPreservedViewport(
            previousDistanceFromTop: .nan,
            previousContentHeight: 2_000,
            currentDistanceFromTop: 120,
            currentContentHeight: 3_000))
    }

    func testOutgoingFollowWaitsForInsertedItem() {
        var trigger = OutgoingMessageFollowTrigger()
        trigger.begin(latestItemID: 10)

        XCTAssertFalse(trigger.observe(latestOutgoingItemID: nil))
        XCTAssertFalse(trigger.observe(latestOutgoingItemID: 10))
        XCTAssertTrue(trigger.isPending)
    }

    func testOutgoingFollowFiresOnceForNewerOutgoingItem() {
        var trigger = OutgoingMessageFollowTrigger()
        trigger.begin(latestItemID: 10)

        XCTAssertTrue(trigger.observe(latestOutgoingItemID: 11))
        XCTAssertFalse(trigger.isPending)
        XCTAssertFalse(trigger.observe(latestOutgoingItemID: 12))
    }

    func testOutgoingFollowIgnoresPrependedHistory() {
        var trigger = OutgoingMessageFollowTrigger()
        trigger.begin(latestItemID: 10)

        XCTAssertFalse(trigger.observe(latestOutgoingItemID: 7))
        XCTAssertTrue(trigger.isPending)
    }

    func testOutgoingFollowHandlesFirstConversationMessage() {
        var trigger = OutgoingMessageFollowTrigger()
        trigger.begin(latestItemID: nil)

        XCTAssertTrue(trigger.observe(latestOutgoingItemID: 1))
        XCTAssertFalse(trigger.isPending)
    }

    func testLateBottomGeometryRearmsFollowIntentAfterIdle() {
        XCTAssertTrue(updatedBottomFollowIntent(
            current: false,
            isAtBottom: true,
            userInteracting: false))
    }

    func testUserMovementAwayClearsFollowIntent() {
        XCTAssertFalse(updatedBottomFollowIntent(
            current: true,
            isAtBottom: false,
            userInteracting: true))
    }

    func testIdleContentGrowthDoesNotClearFollowIntent() {
        XCTAssertTrue(updatedBottomFollowIntent(
            current: true,
            isAtBottom: false,
            userInteracting: false))
    }

    func testMeasuredBottomFollowsNewestMessageDespiteStaleIntent() {
        XCTAssertTrue(shouldFollowNewestMessage(
            intent: false,
            measuredAtBottom: true))
    }

    func testNewestMessageDoesNotFollowWhenUserIsAway() {
        XCTAssertFalse(shouldFollowNewestMessage(
            intent: false,
            measuredAtBottom: false))
    }

}
