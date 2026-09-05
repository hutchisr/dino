import XCTest
@testable import GeckoKit

final class FileTransferProgressTests: XCTestCase {
    func testNegativeTransferredBytesClampToZero() {
        let progress = FileTransferProgress(transferredBytes: -5, totalBytes: 100)

        XCTAssertEqual(progress.transferredBytes, 0)
        XCTAssertEqual(progress.fractionCompleted, 0)
        XCTAssertEqual(progress.statusText(for: .download), "0%")
    }

    func testUnknownNegativeTotalUsesTransferOperationWording() {
        let progress = FileTransferProgress(transferredBytes: 1_024, totalBytes: -1)

        XCTAssertNil(progress.fractionCompleted)
        XCTAssertNil(progress.percentage)
        XCTAssertEqual(progress.statusText(for: .download), "Downloading…")
        XCTAssertTrue(progress.accessibilityValue(for: .download).hasPrefix("Downloading, "))
        XCTAssertTrue(progress.accessibilityValue(for: .download).hasSuffix(" received"))
        XCTAssertEqual(progress.statusText(for: .upload), "Uploading…")
        XCTAssertTrue(progress.accessibilityValue(for: .upload).hasPrefix("Uploading, "))
        XCTAssertTrue(progress.accessibilityValue(for: .upload).hasSuffix(" sent"))
    }

    func testMissingTotalIsIndeterminate() {
        let progress = FileTransferProgress(transferredBytes: 0, totalBytes: nil)

        XCTAssertNil(progress.fractionCompleted)
        XCTAssertEqual(progress.accessibilityValue(for: .download), "Downloading")
    }

    func testZeroTotalIsIndeterminate() {
        let progress = FileTransferProgress(transferredBytes: 0, totalBytes: 0)

        XCTAssertNil(progress.fractionCompleted)
        XCTAssertEqual(progress.statusText(for: .download), "Downloading…")
    }

    func testTransferredBytesOverTotalClampToComplete() {
        let progress = FileTransferProgress(transferredBytes: 120, totalBytes: 100)

        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(progress.percentage, 100)
        XCTAssertEqual(progress.statusText(for: .download), "100%")
        XCTAssertTrue(progress.accessibilityValue(for: .download).hasPrefix("100 percent, "))
        XCTAssertTrue(progress.accessibilityValue(for: .download).contains(" of "))
    }

    func testLargeInt64ValuesDoNotOverflow() {
        let total = Int64.max - 1
        let progress = FileTransferProgress(transferredBytes: total / 2, totalBytes: total)

        XCTAssertNotNil(progress.fractionCompleted)
        XCTAssertEqual(progress.percentage, 50)
    }

    func testValuesAboveInt32RemainAccurate() {
        let progress = FileTransferProgress(
            transferredBytes: 3_000_000_000,
            totalBytes: 4_000_000_000
        )

        XCTAssertEqual(progress.fractionCompleted, 0.75)
        XCTAssertEqual(progress.percentage, 75)
    }

    func testBridgeEventDecodingPreserves64BitProgress() throws {
        let data = Data(
            #"{"type":"file_progress","conversation":4,"item":13,"transferred_bytes":3000000000,"total_bytes":4000000000}"#
                .utf8
        )
        let dictionary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let event = try XCTUnwrap(FileTransferProgressEvent(dictionary: dictionary))

        XCTAssertEqual(event.conversationID, 4)
        XCTAssertEqual(event.itemID, 13)
        XCTAssertEqual(event.progress.transferredBytes, 3_000_000_000)
        XCTAssertEqual(event.progress.totalBytes, 4_000_000_000)
    }

    func testBridgeEventDecodingPreservesUnknownTotal() throws {
        let data = Data(
            #"{"type":"file_progress","conversation":4,"item":13,"transferred_bytes":1024,"total_bytes":null}"#
                .utf8
        )
        let dictionary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let event = try XCTUnwrap(FileTransferProgressEvent(dictionary: dictionary))

        XCTAssertEqual(event.progress.transferredBytes, 1_024)
        XCTAssertNil(event.progress.totalBytes)
    }

    func testBridgeEventDecodingRejectsOutOfRangeIdentity() {
        let dictionary: [String: Any] = [
            "type": "file_progress",
            "conversation": Int64(Int32.max) + 1,
            "item": 13,
            "transferred_bytes": 1_024,
            "total_bytes": 2_048,
        ]

        XCTAssertNil(FileTransferProgressEvent(dictionary: dictionary))
    }

    func testKnownTotalAccessibilityValueDescribesPercentAndBytes() {
        let progress = FileTransferProgress(transferredBytes: 25, totalBytes: 100)

        XCTAssertEqual(progress.percentage, 25)
        XCTAssertTrue(progress.accessibilityValue(for: .download).hasPrefix("25 percent, "))
        XCTAssertTrue(progress.accessibilityValue(for: .download).contains(" of "))
    }
}
