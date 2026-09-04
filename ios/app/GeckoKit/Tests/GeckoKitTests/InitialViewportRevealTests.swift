import XCTest
@testable import GeckoKit

final class InitialViewportRevealTests: XCTestCase {
    func testViewportRevealsWhenInitialScrollCompletes() {
        var reveal = InitialViewportReveal()

        XCTAssertFalse(reveal.isReady)
        reveal.initialScrollCompleted()
        XCTAssertTrue(reveal.isReady)
    }

    func testCompletionIsIdempotent() {
        var reveal = InitialViewportReveal()

        reveal.initialScrollCompleted()
        reveal.initialScrollCompleted()
        XCTAssertTrue(reveal.isReady)
    }
}
