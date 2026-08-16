import XCTest
@testable import GeckoKit

final class BottomScrollAnimationTests: XCTestCase {
    func testStationaryAndInvalidDistancesDoNotAnimate() {
        XCTAssertEqual(bottomScrollAnimationDuration(distance: 0), 0)
        XCTAssertEqual(bottomScrollAnimationDuration(distance: -100), 0)
        XCTAssertEqual(bottomScrollAnimationDuration(distance: .infinity), 0)
        XCTAssertEqual(bottomScrollAnimationDuration(distance: .nan), 0)
    }

    func testShortDistanceUsesMinimumDuration() {
        XCTAssertEqual(
            bottomScrollAnimationDuration(distance: 120),
            minimumBottomScrollDuration)
    }

    func testCommonDistanceScalesAtConstantSpeed() {
        XCTAssertEqual(
            bottomScrollAnimationDuration(distance: 900),
            0.5,
            accuracy: 0.000_001)
    }

    func testLongDistanceUsesMaximumDuration() {
        XCTAssertEqual(
            bottomScrollAnimationDuration(distance: 1_260),
            maximumBottomScrollDuration,
            accuracy: 0.000_001)
        XCTAssertEqual(
            bottomScrollAnimationDuration(distance: 10_000),
            maximumBottomScrollDuration)
    }
}
