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
}
