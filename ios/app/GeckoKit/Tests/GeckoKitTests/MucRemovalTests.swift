import XCTest
@testable import GeckoKit

final class MucRemovalTests: XCTestCase {
    private struct Conversation: Equatable {
        let id: Int32
        let name: String
    }

    func testRemovalDropsOnlyTargetConversationAndEveryNavigationEntry() {
        var conversations = [
            Conversation(id: 7, name: "Gecko Test Room"),
            Conversation(id: 9, name: "Direct Message"),
        ]
        var navigation: [Int32] = [7, 9, 7]

        let message = MucRemoval(
            conversationID: 7,
            room: "room@example.com",
            reason: "kicked"
        ).apply(
            to: &conversations,
            navigation: &navigation,
            id: { $0.id },
            name: { $0.name }
        )

        XCTAssertEqual(conversations, [Conversation(id: 9, name: "Direct Message")])
        XCTAssertEqual(navigation, [9])
        XCTAssertEqual(message, "You were kicked from Gecko Test Room.")
    }

    func testMissingConversationStillClearsStaleNavigation() {
        let remaining = Conversation(id: 9, name: "Direct Message")
        var conversations = [remaining]
        var navigation: [Int32] = [7, 9]

        let message = apply(
            conversationID: 7,
            room: "room@example.com",
            reason: "removed",
            conversations: &conversations,
            navigation: &navigation
        )

        XCTAssertEqual(conversations, [remaining])
        XCTAssertEqual(navigation, [9])
        XCTAssertEqual(message, "You were removed from room@example.com.")
    }

    func testEmptyDisplayNameFallsBackToRoomJID() {
        var conversations = [Conversation(id: 7, name: "")]
        var navigation: [Int32] = []

        let message = apply(
            conversationID: 7,
            room: "room@example.com",
            reason: "kicked",
            conversations: &conversations,
            navigation: &navigation
        )

        XCTAssertEqual(message, "You were kicked from room@example.com.")
    }

    func testMissingDisplayNameAndRoomUseGenericFallback() {
        var conversations: [Conversation] = []
        var navigation: [Int32] = []

        let message = apply(
            conversationID: 7,
            room: "",
            reason: "removed",
            conversations: &conversations,
            navigation: &navigation
        )

        XCTAssertEqual(message, "You were removed from the group chat.")
    }

    func testReasonSpecificMessages() {
        let expectations = [
            ("banned", "You were banned from Gecko Test Room."),
            ("kicked", "You were kicked from Gecko Test Room."),
            (
                "affiliation_changed",
                "You were removed from Gecko Test Room because your room affiliation changed."
            ),
            ("members_only", "You were removed because Gecko Test Room is now members-only."),
            ("shutdown", "Gecko Test Room was shut down."),
            ("unknown", "You were removed from Gecko Test Room."),
        ]

        for (reason, expected) in expectations {
            var conversations = [Conversation(id: 7, name: "Gecko Test Room")]
            var navigation: [Int32] = []

            let message = apply(
                conversationID: 7,
                room: "room@example.com",
                reason: reason,
                conversations: &conversations,
                navigation: &navigation
            )

            XCTAssertEqual(message, expected, "Unexpected message for reason: \(reason)")
        }
    }

    private func apply(
        conversationID: Int32,
        room: String,
        reason: String,
        conversations: inout [Conversation],
        navigation: inout [Int32]
    ) -> String {
        MucRemoval(
            conversationID: conversationID,
            room: room,
            reason: reason
        ).apply(
            to: &conversations,
            navigation: &navigation,
            id: { $0.id },
            name: { $0.name }
        )
    }
}
