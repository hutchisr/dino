import XCTest
@testable import GeckoKit

final class PrivacyFormattingTests: XCTestCase {
    func testRedactsLongIdentifier() {
        XCTAssertEqual(redactedIdentifier("abcdef1234567890"), "abcdef...7890")
    }

    func testShortIdentifierDoesNotLeakPartialValue() {
        XCTAssertEqual(redactedIdentifier("abcd"), "<redacted:4>")
    }

    func testEmptyIdentifierHasStablePlaceholder() {
        XCTAssertEqual(redactedIdentifier(""), "<empty>")
    }

    func testCustomVisibleWidths() {
        XCTAssertEqual(redactedIdentifier("abcdefghijkl", visiblePrefix: 2, visibleSuffix: 3), "ab...jkl")
    }
}
