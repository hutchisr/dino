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

        let download = app.buttons["Download fixture.png"]
        XCTAssertTrue(download.waitForExistence(timeout: 2), "Delayed attachment never became accessible")
        let compactHeight = download.frame.height
        let preview = app.buttons["Open image"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "The attachment never became an image preview")
        let frame = preview.frame
        XCTAssertGreaterThan(frame.height, compactHeight, "The image preview did not expand")
        XCTAssertGreaterThan(frame.width, 100, "Expected the image preview, not a descendant icon")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(frame), "The expanded image preview is not fully visible")
        assertNewestMessage(preview, remainsAbove: app.textViews.firstMatch)
    }

    func testTypingKeepsNewestMessageAboveComposer() {
        app.launchEnvironment["DINO_UI_TEST_COMPOSER"] = "1"
        app.launch()
        let newest = app.staticTexts["Newest fixture message"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        let editor = app.textViews.firstMatch
        focusComposer(editor, above: newest)
        let baselineGap = editor.frame.minY - newest.frame.maxY
        // Soft wrapping plus explicit breaks exercise both height transitions,
        // including entering and leaving the six-line internal scrolling mode.
        let draft = String(repeating: "A line of draft text. ", count: 6) + "\n\n\n"
        for character in draft {
            editor.typeText(String(character))
            assertNewestMessage(newest, remainsAbove: editor, gap: baselineGap)
        }
        let expandedHeight = editor.frame.height
        let enteredText = editor.value as? String ?? ""
        for _ in enteredText {
            editor.typeText(XCUIKeyboardKey.delete.rawValue)
            assertNewestMessage(newest, remainsAbove: editor, gap: baselineGap)
        }
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertLessThan(editor.frame.height, expandedHeight, "Deletion never shrank the composer")
    }

    func testShrinkingDraftDoesNotLeaveOlderMessages() throws {
        app.launchEnvironment["DINO_UI_TEST_COMPOSER"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Newest fixture message"].waitForExistence(timeout: 5))
        let editor = app.textViews.firstMatch
        focusComposer(editor, above: app.staticTexts["Newest fixture message"])
        let line = "A line of draft text.\n"
        editor.typeText(String(repeating: line, count: 8))

        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 200, dy: 180)).press(
            forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: 200, dy: 340)))
        let scrollDown = app.buttons["Scroll to latest messages"]
        XCTAssertTrue(scrollDown.waitForExistence(timeout: 3))
        editor.tap()
        let marker = try XCTUnwrap(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Message "))
                .allElementsBoundByIndex.first {
                    $0.frame.minY >= 130 && $0.frame.minY < editor.frame.minY - 30
                })
        let y = marker.frame.minY
        for _ in 0..<(line.count * 5) {
            editor.typeText(XCUIKeyboardKey.delete.rawValue)
            XCTAssertEqual(marker.frame.minY, y, accuracy: 2, "Shrinking a draft moved the history being read")
            XCTAssertTrue(scrollDown.exists, "Shrinking a draft unexpectedly resumed bottom following")
        }
    }

    private func focusComposer(_ editor: XCUIElement, above newest: XCUIElement) {
        editor.tap()
#if !targetEnvironment(macCatalyst)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "The keyboard never appeared")
        XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 2)
#endif
        // Establish a stable post-keyboard baseline before entering any text.
        let frame = newest.frame
        let editorFrame = editor.frame
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(newest.frame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(editor.frame.minY, editorFrame.minY, accuracy: 1)
        assertNewestMessage(newest, remainsAbove: editor)
    }

    private func assertNewestMessage(
        _ newest: XCUIElement,
        remainsAbove editor: XCUIElement,
        gap expectedGap: CGFloat? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gap = editor.frame.minY - newest.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, 0, "Newest message is covered by the composer", file: file, line: line)
        XCTAssertLessThan(gap, 44, "Resizing the draft scrolled away from the newest message", file: file, line: line)
        if let expectedGap {
            XCTAssertEqual(gap, expectedGap, accuracy: 2, "A keystroke displaced the message relative to the composer",
                           file: file, line: line)
        }
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
