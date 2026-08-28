import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import GeckoKit

final class PixelSizeTests: XCTestCase {
    /// Writes a real JPEG of `width` x `height` pixels, optionally tagged with
    /// an EXIF orientation, and returns its path. Real files (not fixtures)
    /// keep the test honest about what ImageIO actually reports.
    private func writeJPEG(
        width: Int,
        height: Int,
        orientation: UInt32? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil))
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testReportsPixelDimensions() throws {
        let url = try writeJPEG(width: 40, height: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ThumbnailLoader.pixelSize(path: url.path), CGSize(width: 40, height: 20))
    }

    func testRotatedOrientationReportsDisplayDimensions() throws {
        // Orientation 6 is a quarter turn: a 40x20 pixel buffer displays as 20x40.
        let url = try writeJPEG(width: 40, height: 20, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ThumbnailLoader.pixelSize(path: url.path), CGSize(width: 20, height: 40))
    }

    func testGarbageBytesReturnNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ThumbnailLoader.pixelSize(path: url.path))
    }

    func testMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        XCTAssertNil(ThumbnailLoader.pixelSize(path: url.path))
    }
}
