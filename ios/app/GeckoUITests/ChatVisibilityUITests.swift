import XCTest

final class ChatVisibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DINO_UI_TEST_FIXTURE"] = "chat-visibility"
    }

    func testDelayedMessagesRevealAndRemainVisibleAfterImageHeightChange() {
        app.launch()

        let newest = app.descendants(matching: .any)
            .matching(identifier: "chat.message.9199")
            .firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 2), "Delayed messages never became accessible")
        XCTAssertLessThan(newest.frame.height, 120, "Fixture image completed before the compact file row was observed")

        let settled = app.descendants(matching: .any)
            .matching(identifier: "chat.fixture.imageSettled")
            .firstMatch
        XCTAssertTrue(settled.waitForExistence(timeout: 5), "The file row never expanded into an image preview")
        let settledFrame = app.descendants(matching: .any)
            .matching(identifier: "chat.message.9199")
            .firstMatch.frame
        let visibleFrame = settledFrame.intersection(app.windows.firstMatch.frame)
        XCTAssertFalse(visibleFrame.isNull, "Newest row fell outside the visible viewport after growing")
        XCTAssertGreaterThan(visibleFrame.height, 1)
    }

#if targetEnvironment(macCatalyst)
    func testRapidMediaActivationCreatesOnlyOnePreviewWindow() {
        app.launchEnvironment["DINO_UI_TEST_RAPID_MEDIA"] = "1"
        app.launch()
        let previews = app.descendants(matching: .any)
            .matching(identifier: "media.preview")
        XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 5), "Media preview did not open")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(previews.count, 1)
    }
#endif
}
