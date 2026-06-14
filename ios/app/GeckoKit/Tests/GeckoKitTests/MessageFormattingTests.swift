import XCTest
@testable import GeckoKit

/// Pull out the (text, url) of every linked run, in order.
private func links(in attr: AttributedString) -> [(text: String, url: URL)] {
    var found: [(String, URL)] = []
    for run in attr.runs {
        if let url = run.link {
            found.append((String(attr[run.range].characters), url))
        }
    }
    return found
}

final class MessageRunsTests: XCTestCase {
    func testPlainTextIsOneNormalRun() {
        let runs = messageRuns("hello\nworld")
        XCTAssertEqual(runs.count, 1)
        XCTAssertFalse(runs[0].isQuote)
        XCTAssertEqual(runs[0].text, "hello\nworld")
    }

    func testEmptyStringIsOneEmptyNormalRun() {
        let runs = messageRuns("")
        XCTAssertEqual(runs.count, 1)
        XCTAssertFalse(runs[0].isQuote)
        XCTAssertEqual(runs[0].text, "")
    }

    func testConsecutiveQuoteLinesShareOneRun() {
        let runs = messageRuns("> a\n> b\n> c")
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].isQuote)
        XCTAssertEqual(runs[0].text, "a\nb\nc")
    }

    func testQuoteMarkerStripsAtMostOneSpace() {
        XCTAssertEqual(messageRuns(">x")[0].text, "x")        // no space
        XCTAssertEqual(messageRuns("> x")[0].text, "x")       // one space
        XCTAssertEqual(messageRuns(">  x")[0].text, " x")     // only one removed
    }

    func testNestedQuoteStripsOneLevelOnly() {
        let runs = messageRuns(">> deep")
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(runs[0].isQuote)
        XCTAssertEqual(runs[0].text, "> deep")
    }

    func testMixedLinesGroupIntoAlternatingRuns() {
        let runs = messageRuns("reply\n> quoted\n> more\ndone")
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[0].isQuote, false)
        XCTAssertEqual(runs[0].text, "reply")
        XCTAssertEqual(runs[1].isQuote, true)
        XCTAssertEqual(runs[1].text, "quoted\nmore")
        XCTAssertEqual(runs[2].isQuote, false)
        XCTAssertEqual(runs[2].text, "done")
    }

    func testQuoteThenNormalThenQuoteKeepsThreeRuns() {
        let runs = messageRuns("> q1\nmid\n> q2")
        XCTAssertEqual(runs.map(\.isQuote), [true, false, true])
        XCTAssertEqual(runs.map(\.text), ["q1", "mid", "q2"])
    }
}

final class LinkifiedBodyTests: XCTestCase {
    func testPlainTextHasNoLinksAndKeepsContent() {
        let attr = linkifiedBody("just some text")
        XCTAssertTrue(links(in: attr).isEmpty)
        XCTAssertEqual(String(attr.characters), "just some text")
    }

    func testEmptyStringHasNoLinks() {
        let attr = linkifiedBody("")
        XCTAssertTrue(links(in: attr).isEmpty)
        XCTAssertEqual(String(attr.characters), "")
    }

    func testHttpsUrlIsLinked() {
        let attr = linkifiedBody("see https://example.com now")
        let found = links(in: attr)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "https://example.com")
        XCTAssertEqual(found.first?.url.absoluteString, "https://example.com")
    }

    func testSurroundingTextIsNotLinked() {
        // The whole string should still be present; only the URL run carries a link.
        let attr = linkifiedBody("see https://example.com now")
        XCTAssertEqual(String(attr.characters), "see https://example.com now")
    }

    func testMultipleUrlsAreEachLinked() {
        let attr = linkifiedBody("a http://a.example b http://b.example")
        let urls = links(in: attr).map(\.url.absoluteString)
        XCTAssertEqual(urls, ["http://a.example", "http://b.example"])
    }

    func testEmailIsLinkedAsMailto() {
        let attr = linkifiedBody("write to rachel@example.com please")
        let found = links(in: attr)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.url.scheme, "mailto")
    }
}
