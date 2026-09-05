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

    private func writeSVG(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).svg")
        try source.write(to: url, atomically: true, encoding: .utf8)
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

    func testReportsSVGViewportDimensions() throws {
        let url = try writeSVG("""
            <svg xmlns="http://www.w3.org/2000/svg"
                 width="320" height="180" viewBox="0 0 640 360"></svg>
            """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ThumbnailLoader.pixelSize(path: url.path), CGSize(width: 320, height: 180))
    }

    func testReportsPrefixedSVGRootDimensions() throws {
        let url = try writeSVG("""
            <?xml version="1.0"?>
            <svg:svg xmlns:svg="http://www.w3.org/2000/svg"
                     width="400" height="250"></svg:svg>
            """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ThumbnailLoader.pixelSize(path: url.path), CGSize(width: 400, height: 250))
    }

    func testFallsBackToSVGViewBoxDimensions() throws {
        let url = try writeSVG("""
            <?xml version="1.0"?>
            <svg xmlns="http://www.w3.org/2000/svg"
                 width="100%" height="100%" viewBox="-10 -20 640 360"></svg>
            """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ThumbnailLoader.pixelSize(path: url.path), CGSize(width: 640, height: 360))
    }

    func testTinySVGDimensionsProduceFiniteReservedSize() throws {
        let box = CGSize(width: 220, height: 280)
        for source in [
            #"<svg xmlns="http://www.w3.org/2000/svg" width="1e-320" height="1e-320"></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1e-320 1e-320"></svg>"#,
        ] {
            let url = try writeSVG(source)
            defer { try? FileManager.default.removeItem(at: url) }
            let size = try XCTUnwrap(ThumbnailLoader.pixelSize(path: url.path))
            let fitted = ThumbnailLoader.fit(size, in: box)
            XCTAssertEqual(fitted, box)
            XCTAssertTrue(fitted.width.isFinite)
            XCTAssertTrue(fitted.height.isFinite)
        }
    }

    func testRejectsSVGEntityDeclarationsBeforeMetadataParsing() throws {
        for declaration in [
            "<!DOCTYPE svg>",
            "<!eNtItY payload \"expanded\">",
        ] {
            let url = try writeSVG("""
                \(declaration)
                <svg xmlns="http://www.w3.org/2000/svg"
                     width="320" height="180"></svg>
                """)
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertNil(ThumbnailLoader.pixelSize(path: url.path))
        }
    }

    func testDetectsExtensionlessSVGForMIMEClassifiedAttachments() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try """
            <svg xmlns="http://www.w3.org/2000/svg"
                 width="300" height="200"></svg>
            """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ThumbnailLoader.isSVG(path: url.path))
        XCTAssertEqual(ThumbnailLoader.pixelSize(path: url.path), CGSize(width: 300, height: 200))
    }

    func testExtensionlessGarbageIsNotDetectedAsSVG() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ThumbnailLoader.isSVG(path: url.path))
        XCTAssertNil(ThumbnailLoader.pixelSize(path: url.path))
    }

    func testValidatedSVGRootOverridesMislabeledExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        try """
            <svg xmlns="http://www.w3.org/2000/svg"
                 width="320" height="180"></svg>
            """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ThumbnailLoader.isSVG(path: url.path))
        XCTAssertEqual(ThumbnailLoader.pixelSize(path: url.path), CGSize(width: 320, height: 180))
    }

    func testSVGExtensionRemainsAuthoritativeForMalformedContent() throws {
        let url = try writeSVG("not actually XML")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ThumbnailLoader.isSVG(path: url.path))
        XCTAssertNil(ThumbnailLoader.pixelSize(path: url.path))
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
