import XCTest
import UIKit

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
        let composer = app.descendants(matching: .any)["chat.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3), "The composer never appeared")
        focusComposer(editor, above: newest)
        let baselineGap = composer.frame.minY - newest.frame.maxY
        // Seven short lines exercise each height transition and the six-line
        // scrolling cap without spending the test typing a paragraph.
        for line in 1...7 {
            editor.typeText(String(line))
            if line < 7 {
                insertLineBreak(in: editor)
            }
            assertNewestMessage(newest, remainsAbove: composer, gap: baselineGap)
        }
        let expandedHeight = composer.frame.height
        let enteredText = editor.value as? String ?? ""
        for _ in enteredText {
            editor.typeText(XCUIKeyboardKey.delete.rawValue)
            assertNewestMessage(newest, remainsAbove: composer, gap: baselineGap)
        }
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertLessThan(composer.frame.height, expandedHeight, "Deletion never shrank the composer")
    }

    func testShrinkingDraftDoesNotLeaveOlderMessages() throws {
        app.launchEnvironment["DINO_UI_TEST_COMPOSER"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Newest fixture message"].waitForExistence(timeout: 5))
        let editor = app.textViews.firstMatch
        focusComposer(editor, above: app.staticTexts["Newest fixture message"])
        for line in 1...8 {
            editor.typeText("x")
            if line < 8 {
                insertLineBreak(in: editor)
            }
        }

        let messageList = app.descendants(matching: .any)["chat.messageList"]
        XCTAssertTrue(messageList.waitForExistence(timeout: 3), "The message list never appeared")
#if targetEnvironment(macCatalyst)
        messageList.scroll(byDeltaX: 0, deltaY: 500)
#else
        let appFrame = app.frame
        let listFrame = messageList.frame
        XCTAssertFalse(listFrame.isEmpty, "The message list has no scrollable viewport")
        let appOrigin = app.coordinate(withNormalizedOffset: .zero)
        let x = listFrame.midX - appFrame.minX
        let dragStart = appOrigin.withOffset(
            CGVector(dx: x, dy: listFrame.minY + listFrame.height * 0.2 - appFrame.minY))
        let dragEnd = appOrigin.withOffset(
            CGVector(dx: x, dy: listFrame.minY + listFrame.height * 0.4 - appFrame.minY))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
#endif
        let scrollDown = app.buttons["Scroll to latest messages"]
        XCTAssertTrue(scrollDown.waitForExistence(timeout: 3))
        editor.tap()
        let marker = try XCTUnwrap(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Message "))
                .allElementsBoundByIndex.first {
                    $0.frame.minY >= 130 && $0.frame.minY < editor.frame.minY - 30
                })
        let y = marker.frame.minY
        for _ in 0..<10 {
            editor.typeText(XCUIKeyboardKey.delete.rawValue)
            XCTAssertEqual(marker.frame.minY, y, accuracy: 2, "Shrinking a draft moved the history being read")
            XCTAssertTrue(scrollDown.exists, "Shrinking a draft unexpectedly resumed bottom following")
        }
    }

    func testOutgoingAttachmentShowsUploadProgress() {
        app.launchEnvironment["DINO_UI_TEST_UPLOAD_PROGRESS"] = "1"
        app.launch()

        let progress = app.descendants(matching: .any)["Uploading upload-fixture.bin"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "The upload progress row never appeared")
        XCTAssertTrue(
            (progress.value as? String)?.hasPrefix("50 percent,") == true,
            "The upload progress row did not expose its determinate progress")
    }

    func testOutgoingImageShowsThumbnailWhileUploading() throws {
        app.launchEnvironment["DINO_UI_TEST_UPLOAD_IMAGE"] = "1"
        app.launch()

        let progress = app.descendants(matching: .any)["Uploading upload-fixture.png"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "The image upload progress row never appeared")
        XCTAssertTrue(
            (progress.value as? String)?.hasPrefix("50 percent,") == true,
            "The image upload did not remain visibly in progress")

        let preview = app.buttons["Open image"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "The image thumbnail was hidden during upload")
        XCTAssertGreaterThan(preview.frame.width, 100, "Expected an image thumbnail, not only file progress")
        XCTAssertGreaterThan(preview.frame.height, 100, "Expected an image thumbnail, not only file progress")
        XCTAssertTrue(progress.exists, "The upload progress row disappeared before the thumbnail was checked")

        let rgb = try screenshotCenterRGB(in: preview.screenshot())
        XCTAssertGreaterThan(rgb.green - rgb.red, 60, "The reserved preview frame still showed its placeholder: \(rgb)")
        XCTAssertGreaterThan(rgb.blue - rgb.red, 80, "The decoded fixture was not visibly teal: \(rgb)")
        XCTAssertLessThan(abs(rgb.green - rgb.blue), 60, "The decoded fixture was not visibly teal: \(rgb)")
    }

    func testViewingConversationClearsUnreadBadge() {
        app.launchEnvironment["DINO_UI_TEST_UNREAD_CLEAR"] = "1"
        app.launch()

        let unread = app.staticTexts["conversation.unread.9001"]
        XCTAssertTrue(unread.waitForExistence(timeout: 3), "The unread badge never appeared")
        app.staticTexts["Visibility Regression"].tap()

#if !targetEnvironment(macCatalyst)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3), "The conversation never opened")
        back.tap()
#endif

        let cleared = NSPredicate(format: "exists == false")
        expectation(for: cleared, evaluatedWith: unread)
        waitForExpectations(timeout: 3)
    }

    private func screenshotCenterRGB(
        in screenshot: XCUIScreenshot
    ) throws -> (red: Int, green: Int, blue: Int) {
        let provider = try XCTUnwrap(
            CGDataProvider(data: screenshot.pngRepresentation as CFData)
        )
        let cgImage = try XCTUnwrap(
            CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
        let x = cgImage.width / 2
        let y = cgImage.height / 2
        let pixel = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &rgba,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

#if !targetEnvironment(macCatalyst)
    func testAccountAvatarUsesUnpaddedArtworkSize() throws {
        app.launchEnvironment["DINO_UI_TEST_FIXTURE"] = "account-avatar"
        app.launch()

        let avatar = app.buttons["Account"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 3), "The account avatar never appeared")
        XCTAssertEqual(avatar.frame.width, 34, accuracy: 1)
        XCTAssertEqual(avatar.frame.height, 34, accuracy: 1)

        let screenshot = app.screenshot()
        let haloDelta = try maximumHorizontalPixelDelta(
            in: screenshot,
            first: CGPoint(x: avatar.frame.minX - 3, y: avatar.frame.midY),
            second: CGPoint(x: avatar.frame.minX - 12, y: avatar.frame.midY))
        XCTAssertLessThanOrEqual(
            haloDelta,
            5,
            "The toolbar added a visible glass margin outside the avatar artwork")
    }

    private func maximumHorizontalPixelDelta(
        in screenshot: XCUIScreenshot,
        first: CGPoint,
        second: CGPoint
    ) throws -> Int {
        let image = screenshot.image
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cgImage.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        XCTAssertGreaterThanOrEqual(bytesPerPixel, 3)

        let scaleX = CGFloat(cgImage.width) / image.size.width
        let scaleY = CGFloat(cgImage.height) / image.size.height
        let firstX = min(cgImage.width - 1, max(0, Int((first.x * scaleX).rounded())))
        let secondX = min(cgImage.width - 1, max(0, Int((second.x * scaleX).rounded())))
        let topY = min(cgImage.height - 1, max(0, Int((first.y * scaleY).rounded())))
        let rows = [topY, cgImage.height - 1 - topY]

        return rows.map { y in
            let firstOffset = y * cgImage.bytesPerRow + firstX * bytesPerPixel
            let secondOffset = y * cgImage.bytesPerRow + secondX * bytesPerPixel
            return (0..<bytesPerPixel).map {
                abs(Int(bytes[firstOffset + $0]) - Int(bytes[secondOffset + $0]))
            }.max() ?? 0
        }.max() ?? 0
    }
#endif
    private func insertLineBreak(in editor: XCUIElement) {
#if targetEnvironment(macCatalyst)
        editor.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .shift)
#else
        editor.typeText("\n")
#endif
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
        remainsAbove boundary: XCUIElement,
        gap expectedGap: CGFloat? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gap = boundary.frame.minY - newest.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, 0, "Newest message is covered by the composer", file: file, line: line)
        XCTAssertLessThan(gap, 44, "Resizing the draft scrolled away from the newest message", file: file, line: line)
        if let expectedGap {
            let accuracy: CGFloat = 2
            XCTAssertEqual(gap, expectedGap, accuracy: accuracy,
                           "A keystroke displaced the message relative to the composer",
                           file: file, line: line)
        }
    }

#if targetEnvironment(macCatalyst)
    func testCompletedImageContextMenuCopiesAndSavesImage() throws {
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeckoSaveUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: exportDirectory) }
        app.launchEnvironment["DINO_UI_TEST_EXPORT_DIRECTORY"] = exportDirectory.path
        UIPasteboard.general.items = []
        app.launch()

        let preview = app.buttons["Open image"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "The image preview never appeared")
        preview.rightClick()

        let copy = app.windows.firstMatch.menus.firstMatch.menuItems["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 2), "Completed image context menu has no Copy action")
        copy.click()
        let imageCopied = NSPredicate { _, _ in
            UIPasteboard.general.hasImages
        }
        let copied = XCTNSPredicateExpectation(predicate: imageCopied, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [copied], timeout: 5),
            .completed,
            "Copy did not place the rendered image on the pasteboard")

        preview.rightClick()
        let save = app.windows.firstMatch.menus.firstMatch.menuItems["Save As…"]
        XCTAssertTrue(save.waitForExistence(timeout: 2), "Completed image context menu has no Save As action")
        save.click()
        let savePanel = app.sheets["save-panel"]
        let saveButton = savePanel.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3), "Save As did not open the system save dialog")
        let filename = savePanel.textFields.firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 2), "Save dialog has no filename field")
        XCTAssertEqual(filename.value as? String, "fixture")
        saveButton.click()
        XCTAssertTrue(savePanel.waitForNonExistence(timeout: 3), "Save dialog did not dismiss")

        let savedURL = exportDirectory.appendingPathComponent("fixture.png")
        let saved = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: savedURL.path)
        }
        let exported = XCTNSPredicateExpectation(predicate: saved, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [exported], timeout: 3),
            .completed,
            "Save As did not export fixture.png")
        let image = try XCTUnwrap(UIImage(contentsOfFile: savedURL.path))
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertGreaterThan(pixels.width, 0)
        XCTAssertEqual(pixels.width * 3, pixels.height * 4)
    }

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
