let minimumBottomScrollDuration = 0.24
let maximumBottomScrollDuration = 0.70

/// Keeps short trips deliberate and long trips from feeling sluggish while
/// maintaining an approximately constant speed through the common range.
func bottomScrollAnimationDuration(distance rawDistance: Double) -> Double {
    guard rawDistance.isFinite else { return 0 }
    let distance = max(0, rawDistance)
    guard distance > 0 else { return 0 }
    return min(
        maximumBottomScrollDuration,
        max(minimumBottomScrollDuration, distance / 1_800))
}

/// UIKit's lower resting content offset. Unlike SwiftUI scroll geometry,
/// UIScrollView adds its adjusted bottom inset to the scrollable range.
func uiScrollViewBottomContentOffset(
    contentHeight: Double,
    viewportHeight: Double,
    topInset: Double,
    bottomInset: Double
) -> Double {
    max(-topInset, contentHeight - viewportHeight + bottomInset)
}
