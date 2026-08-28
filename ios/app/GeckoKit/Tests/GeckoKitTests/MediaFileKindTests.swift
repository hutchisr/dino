import XCTest
@testable import GeckoKit

final class MediaFileKindTests: XCTestCase {
    func testMatchesExtensionCaseInsensitively() {
        XCTAssertTrue(MediaFileKind.isImage(fileName: "Holiday.JPEG"))
        XCTAssertTrue(MediaFileKind.isVideo(fileName: "Clip.MOV"))
    }

    func testNameWithoutExtensionIsNeither() {
        XCTAssertFalse(MediaFileKind.isImage(fileName: "screenshot"))
        XCTAssertFalse(MediaFileKind.isVideo(fileName: "screenshot"))
    }

    func testEmptyNameIsNeither() {
        XCTAssertFalse(MediaFileKind.isImage(fileName: ""))
        XCTAssertFalse(MediaFileKind.isVideo(fileName: ""))
    }

    func testDotfileIsNotTreatedAsExtension() {
        XCTAssertFalse(MediaFileKind.isImage(fileName: ".png"))
        XCTAssertFalse(MediaFileKind.isVideo(fileName: ".mov"))
    }

    func testRecognisesImageExtension() {
        XCTAssertTrue(MediaFileKind.isImage(fileName: "cat.heic"))
        XCTAssertFalse(MediaFileKind.isVideo(fileName: "cat.heic"))
    }

    func testRecognisesVideoExtension() {
        XCTAssertTrue(MediaFileKind.isVideo(fileName: "trip.3g2"))
        XCTAssertFalse(MediaFileKind.isImage(fileName: "trip.3g2"))
    }

    func testNonMediaExtensionIsNeither() {
        XCTAssertFalse(MediaFileKind.isImage(fileName: "notes.pdf"))
        XCTAssertFalse(MediaFileKind.isVideo(fileName: "notes.pdf"))
    }
}
