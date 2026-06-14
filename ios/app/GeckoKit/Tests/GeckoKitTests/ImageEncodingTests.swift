#if canImport(UIKit)
import XCTest
import UIKit
@testable import GeckoKit

/// UIKit-dependent, so this suite only compiles/runs under the iOS Simulator
/// (`xcodebuild test -destination 'platform=iOS Simulator,...'`), not host
/// `swift test`.
final class ImageEncodingTests: XCTestCase {
    /// A small solid-colour image written to a temp file in the given format.
    private func writeImage(ext: String, jpeg: Bool) throws -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = try XCTUnwrap(jpeg ? image.jpegData(compressionQuality: 0.9) : image.pngData())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url.path
    }

    func testReencodesJpegToPng() throws {
        let out = try XCTUnwrap(avatarPNG(from: try writeImage(ext: "jpg", jpeg: true)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        XCTAssertEqual(URL(fileURLWithPath: out).pathExtension, "png")
        // The output must really be PNG (the whole point — gdk-pixbuf only
        // decodes PNG): check the 8-byte PNG signature.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    func testPngInputStillProducesPng() throws {
        let out = try XCTUnwrap(avatarPNG(from: try writeImage(ext: "png", jpeg: false)))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testWritesToANewDistinctFile() throws {
        let source = try writeImage(ext: "jpg", jpeg: true)
        let out = try XCTUnwrap(avatarPNG(from: source))
        XCTAssertNotEqual(out, source)
    }

    func testNonImageFileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("not an image".utf8).write(to: url)
        XCTAssertNil(avatarPNG(from: url.path))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(avatarPNG(from: "/no/such/path/avatar.png"))
    }
}
#endif
