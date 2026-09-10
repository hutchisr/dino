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

    func testTemporaryCopyURLPreservesSourceName() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        let source = URL(fileURLWithPath: "/Users/rachel/Pictures/cat.jpg")
        let staged = AttachmentStaging.temporaryCopyURL(for: source, in: temp, id: id)
        XCTAssertEqual(staged.lastPathComponent, "cat.jpg")
    }

    func testTemporaryCopyURLUsesNormalizedPreferredExtension() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        let source = URL(fileURLWithPath: "/private/tmp/provider-file.tmp")
        let staged = AttachmentStaging.temporaryCopyURL(
            for: source,
            preferredFilenameExtension: " .GIF ",
            in: temp,
            id: id
        )
        XCTAssertEqual(staged.lastPathComponent, "provider-file.gif")
    }

    func testTemporaryPastedImageURLUsesReadableNameAndExtension() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        let staged = AttachmentStaging.temporaryPastedImageURL(
            fileExtension: "PNG",
            in: temp,
            id: id)
        XCTAssertEqual(staged.lastPathComponent, "Pasted Image.png")
    }

    func testTemporaryPastedImageURLHandlesLeadingDot() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let temp = URL(fileURLWithPath: "/tmp/gecko")
        let staged = AttachmentStaging.temporaryPastedImageURL(
            fileExtension: ".jpg",
            in: temp,
            id: id)
        XCTAssertEqual(staged.lastPathComponent, "Pasted Image.jpg")
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

    func testStageCopyDuplicatesSourceBytes() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-source.jpg")
        let bytes = Data([9, 8, 7, 6, 5])
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try XCTUnwrap(AttachmentStaging.stageCopy(of: source))
        defer { AttachmentStaging.removeTemporaryCopy(at: staged) }

        XCTAssertNotEqual(staged.path, source.path)
        XCTAssertEqual(staged.lastPathComponent, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func testStageCopyUsesGIFExtensionWithoutChangingBytes() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-provider-file")
        let bytes = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 2, 3])
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try XCTUnwrap(
            AttachmentStaging.stageCopy(of: source, preferredFilenameExtension: "gif")
        )
        defer { AttachmentStaging.removeTemporaryCopy(at: staged) }

        XCTAssertTrue(staged.lastPathComponent.hasSuffix("-provider-file.gif"))
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func testStageCopyUsesWebPExtensionWithoutChangingBytes() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-provider-file")
        let bytes = Data([
            0x52, 0x49, 0x46, 0x46, 0x1C, 0, 0, 0,
            0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58,
            0x0A, 0, 0, 0, 0x02, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0x41, 0x4E, 0x49, 0x4D,
        ])
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try XCTUnwrap(
            AttachmentStaging.stageCopy(of: source, preferredFilenameExtension: "webp")
        )
        defer { AttachmentStaging.removeTemporaryCopy(at: staged) }

        XCTAssertTrue(staged.lastPathComponent.hasSuffix("-provider-file.webp"))
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func testStageCopyReturnsNilForMissingSource() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-absent.jpg")
        XCTAssertNil(AttachmentStaging.stageCopy(of: missing))
    }

    func testCancellableCopyPreservesBytesAndPreferredExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("provider-file")
        let bytes = Data((0..<10_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)

        let staged = try AttachmentStaging.stageCopyCancellable(
            of: source,
            preferredFilenameExtension: "png",
            in: staging,
            copyChunkByteCount: 127,
            isCancelled: { false })

        XCTAssertEqual(staged.lastPathComponent, "provider-file.png")
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func testCancelledCopyLeavesNoPartialTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data(repeating: 0xA5, count: 1024).write(to: source)

        XCTAssertThrowsError(try AttachmentStaging.stageCopyCancellable(
            of: source,
            in: staging,
            isCancelled: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testSameNamedCopiesRemainIndependentAndCleanupPreservesSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.pdf")
        try Data([1]).write(to: source)
        let first = try AttachmentStaging.stageCopyCancellable(
            of: source, in: root, isCancelled: { false })
        try Data([2]).write(to: source)
        let second = try AttachmentStaging.stageCopyCancellable(
            of: source, in: root, isCancelled: { false })
        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        XCTAssertEqual(second.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        AttachmentStaging.removeTemporaryCopy(at: first, temporaryDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
        XCTAssertEqual(try Data(contentsOf: source), Data([2]))
    }

    func testCancellationDuringCopyRemovesStagingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data(repeating: 1, count: 32).write(to: source)
        var checks = 0
        XCTAssertThrowsError(try AttachmentStaging.stageCopyCancellable(
            of: source, in: root, copyChunkByteCount: 8,
            isCancelled: { checks += 1; return checks == 3 })
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.bin"])
    }
}
