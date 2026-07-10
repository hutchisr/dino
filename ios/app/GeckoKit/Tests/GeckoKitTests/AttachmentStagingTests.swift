import XCTest
@testable import GeckoKit

final class AttachmentStagingTests: XCTestCase {
    func testAcceptsUnknownSize() {
        XCTAssertTrue(AttachmentStaging.canStageFile(byteCount: nil, maxByteCount: 10))
    }

    func testRejectsFilesAboveLimit() {
        XCTAssertTrue(AttachmentStaging.canStageFile(byteCount: 10, maxByteCount: 10))
        XCTAssertFalse(AttachmentStaging.canStageFile(byteCount: 11, maxByteCount: 10))
    }

    func testRejectsNegativeSize() {
        XCTAssertFalse(AttachmentStaging.canStageFile(byteCount: -1, maxByteCount: 10))
    }

    func testTooLargeMessageUsesRequestedNounAndConfiguredLimit() {
        let message = AttachmentStaging.tooLargeMessage(noun: "video")
        let limit = ByteCountFormatter.string(
            fromByteCount: AttachmentStaging.maxByteCount,
            countStyle: .file)
        XCTAssertTrue(message.hasPrefix("This video is too large to send."))
        XCTAssertTrue(message.hasSuffix("local staging limit is \(limit)."))
    }

    func testTemporaryCopyURLPreservesSourceName() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        let source = URL(fileURLWithPath: "/Users/rachel/Pictures/cat.jpg")
        let staged = AttachmentStaging.temporaryCopyURL(for: source, in: temp, id: id)
        XCTAssertEqual(staged.path, "/tmp/gecko/00000000-0000-0000-0000-000000000123-cat.jpg")
    }

    func testTemporaryPastedImageURLUsesReadableNameAndExtension() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        let staged = AttachmentStaging.temporaryPastedImageURL(
            fileExtension: "PNG",
            in: temp,
            id: id)
        XCTAssertEqual(staged.path, "/tmp/gecko/00000000-0000-0000-0000-000000000123-Pasted Image.png")
    }

    func testTemporaryPastedImageURLHandlesLeadingDot() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        let staged = AttachmentStaging.temporaryPastedImageURL(
            fileExtension: ".jpg",
            in: temp,
            id: id)
        XCTAssertEqual(staged.path, "/tmp/gecko/00000000-0000-0000-0000-000000000123-Pasted Image.jpg")
    }

    func testTemporaryDirectoryCheckDoesNotMatchSiblingPrefix() {
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        XCTAssertTrue(AttachmentStaging.isInTemporaryDirectory(
            URL(fileURLWithPath: "/tmp/gecko/file.jpg"),
            temporaryDirectory: temp
        ))
        XCTAssertFalse(AttachmentStaging.isInTemporaryDirectory(
            URL(fileURLWithPath: "/tmp/gecko-other/file.jpg"),
            temporaryDirectory: temp
        ))
    }

    func testByteCountReadsFileSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(AttachmentStaging.byteCount(at: url), 4)
    }
}
