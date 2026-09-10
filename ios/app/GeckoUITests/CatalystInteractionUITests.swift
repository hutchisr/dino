#if targetEnvironment(macCatalyst)
import XCTest
import UIKit

/// Desktop-only contracts, exercised through the real Catalyst windows and
/// responder chain. The existing fixture bypasses core startup and live accounts.
final class CatalystInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DINO_UI_TEST_FIXTURE"] = "chat-visibility"
        app.launchEnvironment["DINO_UI_TEST_COMPOSER"] = "1"
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    private var composer: XCUIElement {
        app.descendants(matching: .any)["chat.composer"]
    }

    private var editor: XCUIElement { composer.textViews.firstMatch }
    private var field: XCUIElement {
        composer.descendants(matching: .any)["chat.composer.field"]
    }

    private var chatWindow: XCUIElement {
        app.children(matching: .window).containing(.any, identifier: "chat.composer").firstMatch
    }

    private func resizeChatWindow(by delta: CGVector) {
        let before = chatWindow.frame
        let corner = chatWindow.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -4, dy: -4))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(delta))
        XCTAssertEqual(chatWindow.frame.width, before.width + delta.dx, accuracy: 8)
        XCTAssertEqual(chatWindow.frame.height, before.height + delta.dy, accuracy: 8)
    }

    private func launchChat() {
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Newest fixture message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testComposerGlassFieldRoutesPaddingClicksToEditor() {
        launchChat()
        let original = String(repeating: "0123456789", count: 6)
        let attach = app.buttons["Attach"]
        XCTAssertTrue(attach.isHittable)
        XCTAssertTrue(field.exists)

        let initialTop = CGPoint(x: field.frame.midX, y: field.frame.minY + 3)
        let initialBottom = CGPoint(x: field.frame.midX, y: field.frame.maxY - 3)
        XCTAssertTrue(editor.frame.contains(initialTop), "The native editor does not fill the glass field's top edge")
        XCTAssertTrue(editor.frame.contains(initialBottom), "The native editor does not fill the glass field's bottom edge")

        editor.click()
        editor.typeText(original)
        let send = app.buttons["Send"]
        XCTAssertTrue(send.isHittable)
        let clickPoint = CGPoint(x: field.frame.midX, y: field.frame.minY + 3)
        XCTAssertTrue(editor.frame.contains(clickPoint), "The native editor does not fill the expanded glass field")
        chatWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: clickPoint.x - chatWindow.frame.minX, dy: clickPoint.y - chatWindow.frame.minY))
            .click()
        app.typeText("|")

        let edited = editor.value as? String
        XCTAssertEqual(edited?.count, original.count + 1)
        XCTAssertFalse(edited?.hasSuffix("|") == true, "The glass field did not route the middle click to the editor")
    }
    func testRepeatedWindowResizingKeepsChatResponsive() {
        app.launchArguments += [
            "-macWindowContentWidth", "1100",
            "-macWindowContentHeight", "760",
        ]
        launchChat()
        let newest = app.staticTexts["Newest fixture message"]
        editor.click()
        editor.typeText("Draft during resize")

        for _ in 0..<6 {
            resizeChatWindow(by: CGVector(dx: -160, dy: -100))
            XCTAssertTrue(newest.isHittable)
            resizeChatWindow(by: CGVector(dx: 160, dy: 100))
            XCTAssertTrue(newest.isHittable)
        }

        editor.click()
        editor.typeText(" remains editable")
        XCTAssertEqual(editor.value as? String, "Draft during resize remains editable")
    }

    func testClosingMainWindowKeepsDraftAndReopensSameChat() {
        launchChat()
        editor.click()
        editor.typeText("Draft survives window close")
        let frame = chatWindow.frame

        chatWindow.buttons["_XCUI:CloseWindow"].click()
        XCTAssertTrue(chatWindow.waitForNonExistence(timeout: 5), "Close did not hide the chat window")
        XCTAssertNotEqual(app.state, .notRunning, "Closing the chat quit the persistent desktop app")
        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")

        // XCTest runs a separate temporary app bundle; its newly launched Dock
        // item follows any installed Gecko. A real Dock click sends the reopen
        // event, unlike XCUIApplication.activate() on a windowless Catalyst app.
        let icons = dock.descendants(matching: .dockItem).matching(identifier: "Gecko")
        XCTAssertGreaterThan(icons.count, 0)
        icons.element(boundBy: icons.count - 1).click()
        XCTAssertTrue(chatWindow.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Draft survives window close")
        XCTAssertTrue(app.staticTexts["Newest fixture message"].isHittable)
        XCTAssertEqual(chatWindow.frame.width, frame.width, accuracy: 2)
        XCTAssertEqual(chatWindow.frame.height, frame.height, accuracy: 2)
        XCTAssertEqual(app.children(matching: .window).containing(.any, identifier: "chat.composer").count, 1)
        editor.click()
        editor.typeText(" and reopen")
        XCTAssertEqual(editor.value as? String, "Draft survives window close and reopen")
    }

    func testHidingAndActivatingAppPreservesDraftAndKeyboardInput() {
        launchChat()
        editor.click()
        editor.typeText("Draft survives Hide")
        app.typeKey("h", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertEqual(editor.value as? String, "Draft survives Hide")
        editor.click()
        editor.typeText(" and activation")
        XCTAssertEqual(editor.value as? String, "Draft survives Hide and activation")
        XCTAssertTrue(app.staticTexts["Newest fixture message"].isHittable)
    }

    func testReturnSubmitsDraftWhileShiftReturnInsertsNewline() {
        launchChat()
        // No click: a newly opened Catalyst chat must accept keyboard input.
        app.typeText("First line")
        XCTAssertEqual(editor.value as? String, "First line")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .shift)
        app.typeText("Second line")
        XCTAssertEqual(editor.value as? String, "First line\nSecond line")
        XCTAssertTrue(app.buttons["Send"].isHittable)

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "", "Return inserted a newline instead of submitting")
        XCTAssertTrue(app.buttons["Send"].waitForNonExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "", "Return must not insert a blank draft")
        app.typeText("Next draft")
        XCTAssertEqual(editor.value as? String, "Next draft", "Submitting lost composer keyboard focus")
    }

    func testNewMessageShortcutSearchAndCancelReturnToDraft() {
        launchChat()
        editor.click()
        editor.typeText("Keep this draft")
        app.typeKey("n", modifierFlags: .command)
        let search = app.textFields["Search contacts"]
        XCTAssertTrue(search.waitForExistence(timeout: 3), "Command-N did not open Contacts")
        search.click()
        search.typeText("missing@example.invalid")
        XCTAssertTrue(search.buttons["Clear text"].isHittable)
        search.buttons["Clear text"].click()
        XCTAssertEqual(search.value as? String, "")

        app.buttons["Add Contact"].click()
        let alert = app.sheets["Add contact"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Cancel"].click()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(search.isHittable, "Cancelling Add Contact dismissed Contacts too")
        app.buttons["Close"].click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "Keep this draft")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 3), "Contacts could not be reopened")
        app.buttons["Close"].click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3))
    }

    func testSettingsShortcutAndEscapePreserveChatDraft() {
        launchChat()
        editor.click()
        editor.typeText("Draft behind settings")
        XCTAssertEqual(editor.value as? String, "Draft behind settings", "The draft was not entered before opening Settings")
        app.typeKey(",", modifierFlags: .command)
        let accountPhoto = app.buttons["Change account photo"]
        XCTAssertTrue(accountPhoto.waitForExistence(timeout: 3), "Command-comma did not open Settings")
        XCTAssertTrue(app.staticTexts["fixture@example.invalid"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(accountPhoto.waitForNonExistence(timeout: 3), "Escape did not dismiss Settings")
        XCTAssertEqual(editor.value as? String, "Draft behind settings")
        editor.click()
        editor.typeText(" remains editable")
        XCTAssertEqual(editor.value as? String, "Draft behind settings remains editable")
    }

    func testTextContextMenuCopiesMessageAndCancelsReplyWithoutLosingDraft() {
        let previousClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboard }
        UIPasteboard.general.string = "Unrelated clipboard content"
        launchChat()
        editor.click()
        editor.typeText("Reply draft")
        let message = app.staticTexts["Newest fixture message"]
        message.rightClick()
        let menu = chatWindow.menus.firstMatch
        XCTAssertTrue(menu.menuItems["Copy"].waitForExistence(timeout: 3))
        XCTAssertFalse(menu.menuItems["Edit"].exists, "An incoming message must not offer editing")
        menu.menuItems["Copy"].click()
        let copied = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in UIPasteboard.general.string == "Newest fixture message" },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 3), .completed)

        message.rightClick()
        XCTAssertTrue(menu.menuItems["Reply"].waitForExistence(timeout: 3))
        menu.menuItems["Reply"].click()
        let cancel = app.buttons["Cancel reply"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.staticTexts["Newest fixture message"].exists, "Reply banner quoted the wrong message")
        XCTAssertEqual(editor.value as? String, "Reply draft")
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "Reply draft", "Cancelling a reply discarded the draft")
    }

    func testCustomReactionPickerSearchToggleAndCancelPreserveDraft() {
        launchChat()
        editor.click()
        editor.typeText("Draft behind reactions")
        let message = app.staticTexts["Newest fixture message"]
        let search = app.textFields["Search emoji"]
        let close = app.buttons["Close"]
        let hedgehog = app.buttons["hedgehog"].firstMatch
        let grinningFace = app.buttons["grinning face"].firstMatch
        let reaction = app.buttons["🦔 1"]

        func openPicker() {
            message.rightClick()
            let more = chatWindow.menus.firstMatch.menuItems["Reactions and More…"]
            XCTAssertTrue(more.waitForExistence(timeout: 3))
            more.click()
            XCTAssertTrue(search.waitForExistence(timeout: 3))
            XCTAssertTrue(close.exists)
        }

        openPicker()
        for name in [
            "thumbs up", "red heart", "face with tears of joy", "face with open mouth",
            "crying face", "fire", "party popper", "lizard",
        ] {
            XCTAssertTrue(app.buttons[name].firstMatch.isHittable, "Missing quick reaction: \(name)")
        }
        XCTAssertTrue(app.buttons["Reply"].isHittable)
        XCTAssertTrue(app.buttons["Copy"].isHittable)
        XCTAssertFalse(app.buttons["Edit"].exists, "An incoming message must not offer editing")
        XCTAssertTrue(grinningFace.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Custom reaction picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        search.click()
        search.typeText("hedgehog")
        XCTAssertTrue(hedgehog.waitForExistence(timeout: 3))
        XCTAssertTrue(grinningFace.waitForNonExistence(timeout: 3), "Search retained unrelated emoji")
        hedgehog.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3), "Selecting a reaction did not dismiss the picker")
        XCTAssertTrue(reaction.waitForExistence(timeout: 3), "The selected grid emoji was not added to the message")
        XCTAssertEqual(editor.value as? String, "Draft behind reactions")

        openPicker()
        XCTAssertFalse(app.buttons["Clear search"].exists, "Reopening retained the previous search")
        search.click()
        search.typeText("hedgehog")
        XCTAssertTrue(hedgehog.waitForExistence(timeout: 3))
        hedgehog.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3))
        XCTAssertTrue(reaction.waitForNonExistence(timeout: 3), "Selecting the same emoji did not remove the reaction")
        XCTAssertEqual(editor.value as? String, "Draft behind reactions")

        openPicker()
        search.click()
        search.typeText("hedgehog")
        XCTAssertTrue(hedgehog.waitForExistence(timeout: 3))
        let clear = app.buttons["Clear search"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.click()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 3))
        XCTAssertTrue(grinningFace.waitForExistence(timeout: 3), "Clearing search did not restore the emoji catalog")
        close.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3))
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        XCTAssertFalse(reaction.exists, "Cancelling the picker added a reaction")
        XCTAssertEqual(editor.value as? String, "Draft behind reactions", "Cancelling discarded the draft")
        editor.click()
        editor.typeText(" remains editable")
        XCTAssertEqual(editor.value as? String, "Draft behind reactions remains editable")
    }

    func testEscapeClosesMediaWindowWithoutClosingChat() {
        app.launchEnvironment.removeValue(forKey: "DINO_UI_TEST_COMPOSER")
        app.launch()
        let image = app.buttons["Open image"]
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        editor.click()
        editor.typeText("Draft behind preview")
        // Count native scene windows, not the nested UIKit accessibility windows.
        let previews = app.children(matching: .window).containing(.any, identifier: "media.preview")
        for _ in 0..<3 {
            image.click()
            XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(previews.count, 1, "Opening media accumulated preview windows")
            XCTAssertTrue(chatWindow.exists)
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(previews.firstMatch.waitForNonExistence(timeout: 5), "Escape did not dismiss the media window")
            XCTAssertTrue(chatWindow.isHittable, "Closing media also closed the main chat")
            XCTAssertEqual(editor.value as? String, "Draft behind preview")
        }
        editor.click()
        editor.typeText(" remains editable")
        XCTAssertEqual(editor.value as? String, "Draft behind preview remains editable")
    }

    func testEscapeClosesFocusedVideoPreview() {
        app.launchEnvironment["DINO_UI_TEST_IMAGE_DATA"] = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMUbW9vdgAAAGxtdmhkAAAAAAAAAAAA
        AAAAAAAD6AAAACgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
        AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAj90cmFrAAAAXHRraGQAAAADAAAA
        AAAAAAAAAAABAAAAAAAAACgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA
        AAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAAoAAAAAAABAAAA
        AAG3bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAyAAAAAgBVxAAAAAAALWhkbHIAAAAAAAAAAHZp
        ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABYm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA
        ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAASJzdGJsAAAAvnN0c2QAAAAAAAAA
        AQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFExhdmM2
        My4xLjEwMSBsaWJ4MjY0AAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2V7ARAAA
        AwAEAAADAMg8SJZYAQAGaOvjyyLA/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAino
        AAAAAAAAABhzdHRzAAAAAAAAAAEAAAABAAACAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEA
        AAAUc3RzegAAAAAAAALFAAAAAQAAABRzdGNvAAAAAAAAAAEAAANEAAAAYXVkdGEAAABZbWV0YQAA
        AAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRh
        dGEAAAABAAAAAExhdmY2My4xLjEwMQAAAAhmcmVlAAACzW1kYXQAAAKuBgX//6rcRem95tlIt5Ys
        2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNv
        ZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5o
        dG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4
        MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVf
        cmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIx
        LDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRf
        dGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBi
        bHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIg
        Yl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9
        MiBrZXlpbnQ9MjUwIGtleWludF9taW49MjUgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJj
        X2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0w
        IHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAPZYiEACv//vZz
        fAprbbGB
        """
        app.launchEnvironment["DINO_UI_TEST_IMAGE_EXTENSION"] = "mp4"
        app.launch()

        let video = app.buttons["Play gecko-image-fixture.mp4"]
        XCTAssertTrue(video.waitForExistence(timeout: 8))
        video.click()

        let previews = app.children(matching: .window).containing(.any, identifier: "media.preview")
        XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            previews.firstMatch.waitForNonExistence(timeout: 5),
            "Escape did not dismiss the focused video preview")
        XCTAssertTrue(chatWindow.isHittable, "Closing video preview also closed the main chat")
    }
}
#endif
