import XCTest
@testable import GeckoKit

final class HistoryPaginationTests: XCTestCase {
    func testFreshPaginationCannotLoadWithoutCursor() {
        XCTAssertFalse(HistoryPagination().canLoadOlder)
    }

    func testInitialRequestUsesRawPageCursor() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(oldestItemID: 101, complete: false)

        XCTAssertTrue(paging.canLoadOlder)
        XCTAssertEqual(paging.beginOlderRequest(), 101)
        XCTAssertTrue(paging.canLoadOlder)
    }

    func testDecodedEmptyPageStillAdvancesRawCursor() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 51)
    }

    func testLatestRefreshPreservesDeeperCursor() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)
        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))

        paging.refreshLatestPage(oldestItemID: 121, complete: false)

        XCTAssertEqual(paging.beginOlderRequest(), 51)
    }

    func testCompleteLatestRefreshInvalidatesPendingRequest() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        paging.refreshLatestPage(oldestItemID: 80, complete: true)

        XCTAssertFalse(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))
        XCTAssertNil(paging.beginOlderRequest())
    }

    func testResponseFromBeforeResetIsIgnored() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        paging.replaceWithLatestPage(oldestItemID: 201, complete: false)

        XCTAssertFalse(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 201)
    }

    func testNonAdvancingCursorStopsPagination() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 101,
            complete: false))
        XCTAssertFalse(paging.canLoadOlder)
        XCTAssertNil(paging.beginOlderRequest())
    }
}
