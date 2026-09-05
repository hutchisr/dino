import XCTest
import UniformTypeIdentifiers
@testable import GeckoKit

final class MediaFileKindTests: XCTestCase {
    func testMatchesExtensionCaseInsensitively() {
        XCTAssertTrue(MediaFileKind.isImage(fileName: "Holiday.JPEG"))
        XCTAssertTrue(MediaFileKind.isImage(fileName: "Logo.SVG"))
        XCTAssertTrue(MediaFileKind.isVideo(fileName: "Clip.MOV"))
    }

    func testPickerPrefersGIFRepresentationOverGenericImage() {
        let identifiers = [UTType.jpeg.identifier, UTType.gif.identifier]
        XCTAssertEqual(
            MediaFileKind.preferredPickerTypeIdentifier(
                in: identifiers,
                allowsVideos: false
            ),
            UTType.gif.identifier
        )
    }

    func testPickerPrefersWebPRepresentationOverGenericImage() {
        let identifiers = [UTType.jpeg.identifier, UTType.webP.identifier]
        XCTAssertEqual(
            MediaFileKind.preferredPickerTypeIdentifier(
                in: identifiers,
                allowsVideos: false
            ),
            UTType.webP.identifier
        )
    }

    func testPickerRetainsVideoPriorityWhenAllowed() {
        let identifiers = [UTType.jpeg.identifier, UTType.mpeg4Movie.identifier]
        XCTAssertEqual(
            MediaFileKind.preferredPickerTypeIdentifier(
                in: identifiers,
                allowsVideos: true
            ),
            UTType.mpeg4Movie.identifier
        )
    }

    func testPickerFallsBackToImageWhenVideosAreDisabled() {
        let identifiers = [UTType.mpeg4Movie.identifier, UTType.jpeg.identifier]
        XCTAssertEqual(
            MediaFileKind.preferredPickerTypeIdentifier(
                in: identifiers,
                allowsVideos: false
            ),
            UTType.jpeg.identifier
        )
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
