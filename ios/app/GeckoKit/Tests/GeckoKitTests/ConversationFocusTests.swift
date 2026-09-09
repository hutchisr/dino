import XCTest
@testable import GeckoKit

final class ConversationFocusTests: XCTestCase {
    func testFocusesAndBlursConversation() {
        var state = ConversationFocusState()

        XCTAssertEqual(state.transition(to: 7), [.focus(7)])
        XCTAssertEqual(state.focusedConversation, 7)
        XCTAssertEqual(state.transition(to: nil), [.blur(7)])
        XCTAssertNil(state.focusedConversation)
    }

    func testSwitchBlursOldConversationBeforeFocusingNewOne() {
        var state = ConversationFocusState()
        _ = state.transition(to: 7)

        XCTAssertEqual(state.transition(to: 9), [.blur(7), .focus(9)])
        XCTAssertEqual(state.focusedConversation, 9)
    }

    func testLateDisappearanceDoesNotBlurNewConversation() {
        var state = ConversationFocusState()
        _ = state.transition(to: 7)
        _ = state.transition(to: 9)

        XCTAssertEqual(state.conversationDisappeared(7), [])
        XCTAssertEqual(state.focusedConversation, 9)
    }

    func testRepeatedFocusIsNoOp() {
        var state = ConversationFocusState()
        _ = state.transition(to: 7)

        XCTAssertEqual(state.transition(to: 7), [])
    }

    func testDirectRouteWaitsForInitialConversationSnapshot() {
        var state = DirectChatRouteState()

        XCTAssertEqual(
            state.request(jid: "friend@example.com", matchingConversation: nil),
            [])
        XCTAssertEqual(
            state.conversationsUpdated(matchingConversation: 42),
            [.navigate(42)])
        XCTAssertNil(state.pendingJid)
    }

    func testDirectRouteStartsMissingConversationOnlyOnce() {
        var state = DirectChatRouteState()

        XCTAssertEqual(
            state.request(jid: "friend@example.com", matchingConversation: nil),
            [])
        XCTAssertEqual(
            state.conversationsUpdated(matchingConversation: nil),
            [.startConversation("friend@example.com")])
        XCTAssertEqual(
            state.conversationsUpdated(matchingConversation: nil),
            [])
        XCTAssertEqual(
            state.conversationsUpdated(matchingConversation: 42),
            [.navigate(42)])
    }

    func testDirectRouteUsesLatestAuthoritativeSnapshotImmediately() {
        var state = DirectChatRouteState()
        _ = state.conversationsUpdated(matchingConversation: nil)

        XCTAssertEqual(
            state.request(jid: "friend@example.com", matchingConversation: 42),
            [.navigate(42)])
    }
}
