import XCTest
import CoreGraphics
@testable import GeckoKit

/// `ThumbnailLoader.fit` computes the exact on-screen size a chat image will
/// occupy, so the row can reserve that height before the image decodes (and
/// thus never grow after the chat has pinned to the bottom). These guard the
/// math that replaced the grow-then-re-pin approach.
final class ThumbnailFitTests: XCTestCase {
    private let box = CGSize(width: 220, height: 280)

    func testTallPortraitIsHeightLimited() {
        // 900x1400 into 220x280: height is the binding constraint -> 280 tall.
        let s = ThumbnailLoader.fit(CGSize(width: 900, height: 1400), in: box)
        XCTAssertEqual(s.height, 280)
        XCTAssertEqual(s.width, 180)           // 900 * (280/1400)
        XCTAssertLessThanOrEqual(s.width, box.width)
    }

    func testWideLandscapeIsWidthLimited() {
        // 1600x900 into 220x280: width binds -> 220 wide.
        let s = ThumbnailLoader.fit(CGSize(width: 1600, height: 900), in: box)
        XCTAssertEqual(s.width, 220)
        XCTAssertEqual(s.height, 124)          // round(900 * (220/1600)) = round(123.75)
        XCTAssertLessThanOrEqual(s.height, box.height)
    }

    func testSquareFitsTheNarrowerSide() {
        // Square fits to the smaller box dimension (width 220 < height 280).
        let s = ThumbnailLoader.fit(CGSize(width: 1000, height: 1000), in: box)
        XCTAssertEqual(s.width, 220)
        XCTAssertEqual(s.height, 220)
    }

    func testAspectRatioPreserved() {
        // The reserved box must match the image aspect, or scaledToFit would
        // letterbox and the reserved height wouldn't equal the rendered height.
        let source = CGSize(width: 1200, height: 1600)
        let s = ThumbnailLoader.fit(source, in: box)
        let sourceAR = source.width / source.height
        let fitAR = s.width / s.height
        XCTAssertEqual(sourceAR, fitAR, accuracy: 0.01)
    }

    func testResultNeverExceedsBox() {
        for source in [CGSize(width: 4000, height: 3000),
                       CGSize(width: 100, height: 5000),
                       CGSize(width: 50, height: 40)] {
            let s = ThumbnailLoader.fit(source, in: box)
            XCTAssertLessThanOrEqual(s.width, box.width)
            XCTAssertLessThanOrEqual(s.height, box.height)
        }
    }

    func testSmallImageIsUpscaledToFill() {
        // A tiny source still fills the box (one dimension reaches the edge),
        // matching .scaledToFit on a fixed frame — so no surprise letterboxing.
        let s = ThumbnailLoader.fit(CGSize(width: 40, height: 30), in: box)
        XCTAssertEqual(s.width, 220)           // 40 * (280/30)=373 vs 220 -> width binds
        XCTAssertEqual(s.height, 165)          // round(30 * (220/40))
    }

    func testDegenerateSizeFallsBackToBox() {
        XCTAssertEqual(ThumbnailLoader.fit(CGSize(width: 0, height: 100), in: box), box)
        XCTAssertEqual(ThumbnailLoader.fit(.zero, in: box), box)
    }
}
