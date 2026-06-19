import XCTest
@testable import GeckoKit

final class TypingIndicatorTextTests: XCTestCase {
    func testNoNamesFallsBackToGenericTypingText() {
        XCTAssertEqual(typingIndicatorLabel(names: []), "typing...")
    }

    func testOneNameUsesSingularVerb() {
        XCTAssertEqual(typingIndicatorLabel(names: ["Anemone"]), "Anemone is typing...")
    }

    func testTwoNamesUseBothNames() {
        XCTAssertEqual(typingIndicatorLabel(names: ["Anemone", "Birch"]), "Anemone and Birch are typing...")
    }

    func testThreeNamesUseAllNames() {
        XCTAssertEqual(
            typingIndicatorLabel(names: ["Anemone", "Birch", "Cora"]),
            "Anemone, Birch, and Cora are typing...")
    }

    func testManyNamesUseCompactSummary() {
        XCTAssertEqual(
            typingIndicatorLabel(names: ["Anemone", "Birch", "Cora", "Dahlia"]),
            "Anemone, Birch, and 2 others are typing...")
    }

    func testBlankAndDuplicateNamesAreIgnored() {
        XCTAssertEqual(
            typingIndicatorLabel(names: [" Anemone ", "", "Anemone", "Birch"]),
            "Anemone and Birch are typing...")
    }
}
