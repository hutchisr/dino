import QuartzCore
import UIKit

final class ScrollToBottomAnimator: NSObject {
    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var startOffset = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    var isAnimating: Bool {
        displayLink != nil
    }

    @MainActor
    func scrollToBottom(_ scrollView: UIScrollView, animated: Bool) -> Bool {
        scrollView.layoutIfNeeded()
        guard scrollView.bounds.height > 0 else { return false }

        cancel()
        let presentationOffset = scrollView.contentOffset
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        scrollView.setContentOffset(presentationOffset, animated: false)

        let startOffset = scrollView.contentOffset
        let targetY = bottomOffset(for: scrollView)
        let duration = bottomScrollAnimationDuration(
            distance: Double(abs(targetY - startOffset.y)))

        guard animated,
              !UIAccessibility.isReduceMotionEnabled,
              duration > 0 else {
            scrollView.setContentOffset(
                CGPoint(x: startOffset.x, y: targetY),
                animated: false)
            return true
        }

        // The pan recognizer reset above ends native deceleration before the
        // display link starts from the current presentation offset.
        self.scrollView = scrollView
        self.startOffset = startOffset
        self.startTime = CACurrentMediaTime()
        self.duration = duration

        let displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 120,
            preferred: 120)
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
        return true
    }

    @MainActor
    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        scrollView = nil
    }

    @MainActor
    @objc private func step() {
        guard let scrollView else {
            cancel()
            return
        }

        let progress = min(1, max(0, (CACurrentMediaTime() - startTime) / duration))
        let eased = progress * progress * (3 - 2 * progress)
        let targetY = bottomOffset(for: scrollView)
        let y = startOffset.y + (targetY - startOffset.y) * eased
        scrollView.setContentOffset(
            CGPoint(x: startOffset.x, y: y),
            animated: false)

        if progress >= 1 {
            scrollView.setContentOffset(
                CGPoint(x: startOffset.x, y: targetY),
                animated: false)
            cancel()
        }
    }

    @MainActor
    private func bottomOffset(for scrollView: UIScrollView) -> CGFloat {
        let insets = scrollView.adjustedContentInset
        return CGFloat(uiScrollViewBottomContentOffset(
            contentHeight: Double(scrollView.contentSize.height),
            viewportHeight: Double(scrollView.bounds.height),
            topInset: Double(insets.top),
            bottomInset: Double(insets.bottom)))
    }
}
