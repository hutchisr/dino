import XCTest
@testable import GeckoKit

final class UnreadBadgeCountTests: XCTestCase {
    func testTotalsUnreadMessagesAcrossConversations() {
        XCTAssertEqual(unreadBadgeCount([2, 0, 3]), 5)
    }

    func testIgnoresInvalidNegativeCounts() {
        XCTAssertEqual(unreadBadgeCount([-3, 2]), 2)
    }

    func testSaturatesOnOverflow() {
        XCTAssertEqual(unreadBadgeCount([Int.max, 1]), Int.max)
    }
}
