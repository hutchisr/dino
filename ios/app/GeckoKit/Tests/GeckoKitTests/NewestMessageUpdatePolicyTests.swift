import XCTest
@testable import GeckoKit

final class NewestMessageUpdatePolicyTests: XCTestCase {
    func testInitialPopulationSnapsToNewest() {
        XCTAssertEqual(
            newestMessageUpdatePolicy(
                initialScrollCompleted: false,
                updateWasSynced: true,
                isFollowingBottom: true),
            NewestMessageUpdatePolicy(followsNewest: true, animates: false))
    }

    func testLiveArrivalAnimatesWhileFollowingBottom() {
        XCTAssertEqual(
            newestMessageUpdatePolicy(
                initialScrollCompleted: true,
                updateWasSynced: false,
                isFollowingBottom: true),
            NewestMessageUpdatePolicy(followsNewest: true, animates: true))
    }

    func testSyncedArrivalSnapsWhileFollowingBottom() {
        XCTAssertEqual(
            newestMessageUpdatePolicy(
                initialScrollCompleted: true,
                updateWasSynced: true,
                isFollowingBottom: true),
            NewestMessageUpdatePolicy(followsNewest: true, animates: false))
    }

    func testArrivalDoesNotFollowAfterUserScrollsAway() {
        for synced in [false, true] {
            XCTAssertEqual(
                newestMessageUpdatePolicy(
                    initialScrollCompleted: true,
                    updateWasSynced: synced,
                    isFollowingBottom: false),
                NewestMessageUpdatePolicy(followsNewest: false, animates: false))
        }
    }
}
