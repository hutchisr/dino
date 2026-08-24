import XCTest
@testable import GeckoKit

final class LocalNotificationPolicyTests: XCTestCase {
    private var eligible: LocalNotificationPolicyInput {
        LocalNotificationPolicyInput(
            appIsActive: false,
            isNew: true,
            isSynced: false,
            direction: "in",
            notifyEffective: "on",
            isGroupchat: false,
            mentioned: false
        )
    }

    func testPostsEligibleIncomingMessage() {
        XCTAssertTrue(shouldPostLocalNotification(eligible))
    }

    func testSuppressesInactiveDeliveryFailures() {
        var input = eligible
        input.appIsActive = true
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.isNew = false
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.isSynced = true
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.direction = "out"
        XCTAssertFalse(shouldPostLocalNotification(input))
    }

    func testAppliesConversationNotificationSetting() {
        var input = eligible
        input.notifyEffective = "off"
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.notifyEffective = "highlight"
        input.isGroupchat = true
        XCTAssertFalse(shouldPostLocalNotification(input))

        input.mentioned = true
        XCTAssertTrue(shouldPostLocalNotification(input))
    }
}
