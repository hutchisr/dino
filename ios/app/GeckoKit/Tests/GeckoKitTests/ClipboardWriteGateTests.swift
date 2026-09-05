import XCTest
@testable import GeckoKit

final class ClipboardWriteGateTests: XCTestCase {
    func testNewerCopyInvalidatesPendingSVGWrite() {
        var gate = ClipboardWriteGate()
        let svgCopy = gate.begin(changeCount: 10)
        let textCopy = gate.begin(changeCount: 10)

        XCTAssertFalse(gate.permits(svgCopy, changeCount: 10))
        XCTAssertTrue(gate.permits(textCopy, changeCount: 10))
    }

    func testExternalPasteboardChangeInvalidatesPendingSVGWrite() {
        var gate = ClipboardWriteGate()
        let svgCopy = gate.begin(changeCount: 10)

        XCTAssertFalse(gate.permits(svgCopy, changeCount: 11))
    }

    func testCurrentCopyCanWriteWhenPasteboardIsUnchanged() {
        var gate = ClipboardWriteGate()
        let svgCopy = gate.begin(changeCount: 10)

        XCTAssertTrue(gate.permits(svgCopy, changeCount: 10))
    }
}
