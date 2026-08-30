#if canImport(UIKit)
import UIKit
import XCTest
@testable import GeckoKit

final class AnimatedImageTests: XCTestCase {
    private static let animatedGIF = """
    R0lGODlhAgACAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQICgAAACwAAAAA
    AgACAAAIBgABCAQQEAAh+QQIGQAAACwAAAAAAgACAIEAAP8AAAAAAAAAAAAIBgABCAQQEAA7
    """

    private static let animatedWebP = """
    UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAA
    AAEAAAEAAGQAAAJWUDhMDwAAAC8BQAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAAPoA
    AABWUDhMDwAAAC8BQAAABxDR//4HIqL/AQA=
    """

    private static let staticGIF = """
    R0lGODdhAgACAIEAAAD/AAAAAAAAAAAAACwAAAAAAgACAAAIBgABCAQQEAA7
    """

    private func writeFixture(_ encoded: String, fileExtension: String) throws -> URL {
        let data = try XCTUnwrap(Data(
            base64Encoded: encoded,
            options: .ignoreUnknownCharacters
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: url)
        return url
    }

    func testDecodesAnimatedGIFFramesAndDuration() async throws {
        let url = try writeFixture(Self.animatedGIF, fileExtension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = await ThumbnailLoader.loadViewerImageAsync(path: url.path, maxPixel: 64)
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(ThumbnailLoader.animatedFormat(path: url.path), "GIF")

        XCTAssertEqual(image.images?.count, 2)
        XCTAssertEqual(image.duration, 0.35, accuracy: 0.01)
    }

    func testDecodesAnimatedWebPFramesAndDuration() async throws {
        let url = try writeFixture(Self.animatedWebP, fileExtension: "webp")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = await ThumbnailLoader.loadViewerImageAsync(path: url.path, maxPixel: 64)
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(ThumbnailLoader.animatedFormat(path: url.path), "WEBP")

        XCTAssertEqual(image.images?.count, 2)
        XCTAssertEqual(image.duration, 0.35, accuracy: 0.01)
    }

    func testInlineDecoderRetainsAnimatedGIFFramesAndDuration() async throws {
        let url = try writeFixture(Self.animatedGIF, fileExtension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = await ThumbnailLoader.loadInlineAnimatedImageAsync(path: url.path, maxPixel: 64)
        let image = try XCTUnwrap(decoded)

        XCTAssertEqual(image.images?.count, 2)
        XCTAssertEqual(image.duration, 0.35, accuracy: 0.01)
    }

    func testInlineDecoderRetainsAnimatedWebPFramesAndDuration() async throws {
        let url = try writeFixture(Self.animatedWebP, fileExtension: "webp")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = await ThumbnailLoader.loadInlineAnimatedImageAsync(path: url.path, maxPixel: 64)
        let image = try XCTUnwrap(decoded)

        XCTAssertEqual(image.images?.count, 2)
        XCTAssertEqual(image.duration, 0.35, accuracy: 0.01)
    }

    func testInlineDecoderRejectsSingleFrameImage() async throws {
        let url = try writeFixture(Self.staticGIF, fileExtension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = await ThumbnailLoader.loadInlineAnimatedImageAsync(path: url.path, maxPixel: 64)

        XCTAssertNil(decoded)
    }

    func testSingleFrameImageUsesStaticFallback() async throws {
        let url = try writeFixture(Self.staticGIF, fileExtension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = await ThumbnailLoader.loadViewerImageAsync(path: url.path, maxPixel: 64)
        let image = try XCTUnwrap(decoded)
        XCTAssertNil(ThumbnailLoader.animatedFormat(path: url.path))

        XCTAssertNil(image.images)
        XCTAssertEqual(image.size, CGSize(width: 2, height: 2))
    }
}
#endif
