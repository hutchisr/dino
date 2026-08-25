import SwiftUI
import UIKit

/// The SwiftUI chat list, built on the modern scroll APIs: stable-ID viewport
/// restoration for prepends, scroll geometry for boundary detection, and a
/// small UIKit hook for reliable mid-deceleration bottom scrolling.
///
/// The list is laid out upright — oldest at the top, newest at the bottom. It
/// opens pinned to the newest message by positioning the final row explicitly
/// and follows new messages only while already pinned to the bottom.
struct SwiftUIMessageList: View {
    let messages: [ChatMessage]           // chronological: oldest first
    let messageRevision: Int
    let messageUpdateWasSynced: Bool
    let historyPageRevision: Int
    let historyPageRenderedRowsAdded: Bool
    let canLoadOlderHistory: Bool
    let conversationId: Int32
    let isGroupchat: Bool
    let avatarPaths: [String: String]
    let avatarRevision: Int
    let visualTopInset: CGFloat
    let visualBottomInset: CGFloat
    let visualScrollIndicatorTopInset: CGFloat
    let visualScrollIndicatorBottomInset: CGFloat
    let model: AppModel
    @Binding var isAtBottom: Bool
    /// Bumped by the caller to request a programmatic scroll to the newest
    /// message — the scroll-down button, and after sending.
    let scrollToBottomToken: Int
    let onEdit: (ChatMessage) -> Void
    let onReply: (ChatMessage) -> Void
    let onImageTap: (String) -> Void
    let onVideoTap: (String) -> Void
    let onLoadOlder: () -> Void
    let onActions: (ChatMessage) -> Void

    /// Tracks whether the initial "open pinned to the newest message" scroll has
    /// happened. The first populated layout jumps to the bottom instantly; later
    /// live arrivals animate only while already pinned, while sync updates snap.
    @State private var didInitialScroll = false
    /// Keep the initial default scroll position invisible until both geometry
    /// and row visibility confirm that the newest message is at the bottom.
    @State private var initialViewportReady = false

    /// Older-history paging stays disabled until scroll visibility confirms the
    /// initial jump has put the newest row at the measured bottom. Otherwise the
    /// oldest row's first appearance at the ScrollView's default top position
    /// immediately requests page two.
    @State private var canLoadOlder = false
    @State private var historyLoadTrigger = HistoryLoadTrigger()
    @State private var trackedHistoryViewportID: Int32?
    @State private var visibleNewestID: Int32?

    /// The newest row we've already pinned after a layout pass. If content
    /// grows for a different newest message, let that growth animate instead of
    /// using the image-settling snap correction.
    @State private var lastSettledNewestID: Int32?
    @State private var animateBottomGrowthForNewestID: Int32?

    /// Intent to stay glued to the newest message. Starts true (we open at the
    /// bottom) and is re-asserted as content settles; only the user scrolling
    /// away from the bottom clears it, and scrolling back (or the scroll-down
    /// button / sending) re-arms it. Kept separate from `isAtBottom` because the
    /// live geometry transiently reads "not at bottom" while image rows grow.
    @State private var stickToBottom = true

    /// True while the user is physically driving the scroll (drag/inertia), so
    /// content-growth re-pins don't fight their finger and only their own
    /// scrolling changes `stickToBottom`.
    @State private var userInteracting = false

    /// Latest measured remaining downward travel (points to the bottom). Parked
    /// in a reference holder so updating it on every scroll frame doesn't
    /// invalidate the view; read when scrolling to the bottom to scale the
    /// animation duration to the distance (a roughly constant glide speed,
    /// instead of a fixed time that whips past from far up).
    @State private var metrics = ScrollMetrics()

    /// Mutable scroll metrics kept OUT of `@State`-tracked value storage so
    /// per-frame writes don't re-render the list.
    private final class ScrollMetrics {
        var distanceFromTop: CGFloat = 0
        var distanceFromBottom: CGFloat = 0
        var isAtBottom = false
        var isUnderfilled = false
        var contentHeight: CGFloat = 0
        var topVisibleMessageID: Int32?
        var fullyVisibleMessageID: Int32?
        var trackedMessageID: Int32?
        var trackedMessageFrame: CGRect?
        var containerHeight: CGFloat = 0
        var newestMessageID: Int32?
        var awaitingHistoryRestoreGeometry = false
        var expectedHistoryRestoreDistanceFromTop: CGFloat = 0
        var historyRestoreGeneration = 0
        var historyRequest: HistoryRequestContext?
        weak var scrollView: UIScrollView?
        private let bottomScrollAnimator = ScrollToBottomAnimator()

        /// Takes ownership from active deceleration and drives the native
        /// scroll view to its live lower boundary with deterministic timing.
        @MainActor
        func scrollToBottom(animated: Bool) -> Bool {
            guard let scrollView else { return false }
            return bottomScrollAnimator.scrollToBottom(
                scrollView,
                animated: animated)
        }

        @MainActor
        func cancelBottomScrollAnimation() {
            bottomScrollAnimator.cancel()
        }
    }

    /// Includes the content height and model page revision so completion is
    /// acknowledged only by geometry measured from the newly prepended rows.
    /// This prevents a fast local-database response from reusing pre-page
    /// top/bottom metrics and immediately starting another request.
    private struct ScrollSample: Equatable {
        let contentOffsetY: CGFloat
        let distanceFromTop: CGFloat
        let distanceFromBottom: CGFloat
        let contentHeight: CGFloat
        let containerHeight: CGFloat
        let isUnderfilled: Bool
        let historyPageRevision: Int
    }

    private enum HistoryViewportAnchorKind: Equatable {
        case viewport
        case newestBottom
    }

    private struct HistoryViewportAnchor {
        let messageID: Int32
        let unitPoint: UnitPoint
        let contentHeight: CGFloat
        let distanceFromTop: CGFloat
        let kind: HistoryViewportAnchorKind
    }

    private struct HistoryRequestContext {
        let revision: Int
        var preCompletionContentHeight: CGFloat
        var viewportAnchor: HistoryViewportAnchor?
        let refreshViewportAnchor: Bool
    }

    private static let scrollCoordinateSpace = "SwiftUIMessageList.scroll"
    private static let bottomAnchorID = "SwiftUIMessageList.bottom"

    /// Slack (points) for the at-bottom test so the button doesn't flicker at
    /// rest under rubber-banding / sub-pixel offsets. Matches the spirit of the
    /// inverted table's 8pt threshold but a touch looser for SwiftUI's geometry.
    private static let bottomThreshold: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    messageStack
                        .opacity(initialViewportReady ? 1 : 0)
                        .animation(.easeOut(duration: 0.14), value: initialViewportReady)
                        .allowsHitTesting(initialViewportReady)
                        .accessibilityHidden(!initialViewportReady)
                        .background(alignment: .topLeading) {
                            ScrollViewResolver(metrics: metrics)
                                .frame(width: 0, height: 0)
                                .allowsHitTesting(false)
                        }
                        .animation(
                            messageUpdateWasSynced
                                ? nil
                                : .spring(response: 0.32, dampingFraction: 0.86),
                            value: newestMessageID)
                    Color.clear
                        .frame(height: 0)
                        .id(Self.bottomAnchorID)
                }
            }
            .coordinateSpace(.named(Self.scrollCoordinateSpace))
            .scrollDismissesKeyboard(.interactively)
            // The chat chrome (top bar, composer) floats over the list, so inset
            // the content (and the scroll indicators independently) to clear it.
            .contentMargins(.top, max(0, visualTopInset), for: .scrollContent)
            .contentMargins(.bottom, max(0, visualBottomInset), for: .scrollContent)
            .contentMargins(.top, max(0, visualScrollIndicatorTopInset), for: .scrollIndicators)
            .contentMargins(.bottom, max(0, visualScrollIndicatorBottomInset), for: .scrollIndicators)
            .overlay {
                if !initialViewportReady, newestMessageID != nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .onScrollGeometryChange(for: ScrollSample.self) { geo in
                // Distance the content can still travel downward; ~0 means
                // pinned to the newest message. Empirically, at the resting
                // bottom SwiftUI gives
                //   contentSize == contentOffset.y + containerSize + insets.top
                // (the bottom inset is slack the content never scrolls into), so
                // the bottom-most offset is contentSize − containerSize − top.
                let bottomOffsetY = geo.contentSize.height
                    - geo.containerSize.height - geo.contentInsets.top
                let distanceFromTop = max(0, geo.contentOffset.y + geo.contentInsets.top)
                let distanceFromBottom = max(0, bottomOffsetY - geo.contentOffset.y)
                return ScrollSample(
                    contentOffsetY: geo.contentOffset.y,
                    distanceFromTop: distanceFromTop,
                    distanceFromBottom: distanceFromBottom,
                    contentHeight: geo.contentSize.height,
                    containerHeight: geo.containerSize.height,
                    isUnderfilled: geo.contentSize.height <= geo.containerSize.height + 1,
                    historyPageRevision: historyPageRevision)
            } action: { _, sample in
                let distanceFromBottom = sample.distanceFromBottom
                metrics.distanceFromTop = sample.distanceFromTop
                metrics.distanceFromBottom = distanceFromBottom
                metrics.isUnderfilled = sample.isUnderfilled
                metrics.contentHeight = sample.contentHeight
                metrics.containerHeight = sample.containerHeight
                let atBottom = distanceFromBottom <= Self.bottomThreshold
                metrics.isAtBottom = atBottom
                // While we intend to stay glued and the user isn't dragging,
                // treat a gap opened purely by content growth as still-at-bottom,
                // so the scroll-down button doesn't flash while images load —
                // we're about to snap back to the newest message.
                let effectiveAtBottom = atBottom || (stickToBottom && !userInteracting)
                if isAtBottom != effectiveAtBottom { isAtBottom = effectiveAtBottom }
                // Any confirmed bottom sample re-arms following, including the
                // final geometry that can arrive just after deceleration turns
                // idle. Only user-driven movement away is allowed to release it.
                stickToBottom = updatedBottomFollowIntent(
                    current: stickToBottom,
                    isAtBottom: atBottom,
                    userInteracting: userInteracting)
                refreshHistoryRequestIfNeeded(
                    measuredRevision: sample.historyPageRevision)
                let settledViewport = completePendingHistoryViewportRestoreIfNeeded(
                    sample)
                enableOlderLoadingIfReady()
                let completedPage = processCompletedHistoryPageIfNeeded(
                    sample,
                    proxy: proxy)
                if canLoadOlder {
                    requestOlderIfUnderfilled()
                }
                // Do not treat the layout sample produced by the prepend as
                // another scroll. The restored viewport's first sample also
                // only rearms the gate; later motion from the same drag or
                // momentum can naturally cross the next threshold.
                if !settledViewport, !completedPage, userInteracting,
                   historyLoadTrigger.state == .armed {
                    requestOlderIfNeeded(distanceFromTop: sample.distanceFromTop)
                }
            }
            .onScrollTargetVisibilityChange(idType: Int32.self, threshold: 0.01) { ids in
                metrics.topVisibleMessageID = ids.first
                if metrics.fullyVisibleMessageID == nil,
                   trackedHistoryViewportID != ids.first {
                    trackedHistoryViewportID = ids.first
                }
                refreshHistoryRequestIfNeeded()
            }
            .onScrollTargetVisibilityChange(idType: Int32.self, threshold: 0.99) { ids in
                let first = ids.first
                metrics.fullyVisibleMessageID = first
                let preferred = first ?? metrics.topVisibleMessageID
                if trackedHistoryViewportID != preferred {
                    trackedHistoryViewportID = preferred
                }
                refreshHistoryRequestIfNeeded()
            }
            // Stay pinned to the newest message as the content height settles
            // after open — a LazyVStack with image rows keeps growing as those
            // rows materialise and decode (and on-device the image previews
            // render later still), which would otherwise leave us parked just
            // above the last message. Re-pin on every growth while we intend to
            // stay glued; only a deliberate user scroll releases that intent.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height
            } action: { _, _ in
                if didInitialScroll && stickToBottom && !userInteracting {
                    let animated = shouldAnimateBottomGrowth
                    if animated { animateBottomGrowthForNewestID = nil }
                    scrollToNewest(proxy, animated: animated, initial: false)
                }
            }
            // Open pinned to the newest message. We deliberately do NOT use
            // `.defaultScrollAnchor(.bottom)`: on a ScrollView that starts empty
            // and is then populated asynchronously it leaves the list stuck
            // blank (FB-worthy SwiftUI bug). Instead we scroll to a non-lazy
            // bottom anchor that exists before the final row is materialised.
            .onAppear {
                metrics.newestMessageID = newestMessageID
                scrollToNewest(proxy, animated: false, initial: true)
            }
            .onDisappear {
                metrics.cancelBottomScrollAnimation()
            }
            .onChange(of: newestMessageID) { _, newest in
                metrics.newestMessageID = newest
                guard let newest else { return }
                let policy = newestMessageUpdatePolicy(
                    initialScrollCompleted: didInitialScroll,
                    updateWasSynced: messageUpdateWasSynced,
                    isFollowingBottom: shouldFollowNewestMessage(
                        intent: stickToBottom,
                        measuredAtBottom: metrics.isAtBottom))
                guard policy.followsNewest else { return }
                stickToBottom = true
                animateBottomGrowthForNewestID = policy.animates ? newest : nil
                scrollToNewest(
                    proxy,
                    animated: policy.animates,
                    initial: !didInitialScroll)
            }
            .onChange(of: historyPageRevision) { _, _ in
                // Nonterminal pages are completed by the content-size-aware
                // scroll sample above. A terminal response with no newly rendered
                // rows produces no geometry and can be completed immediately.
                if !historyPageRenderedRowsAdded {
                    processCompletedHistoryPageIfNeeded(
                        nil,
                        proxy: proxy)
                }
            }
            .onChange(of: canLoadOlderHistory) { _, allowed in
                guard canLoadOlder else { return }
                historyLoadTrigger.setCanLoadOlder(allowed)
                if allowed {
                    requestOlderIfUnderfilled()
                }
            }
            .onChange(of: scrollToBottomToken) { _, _ in
                stickToBottom = true
                // Defer one run-loop turn so the UIKit resolver and latest
                // layout target are ready. The display-link animator takes over
                // any active deceleration from its current offset.
                userInteracting = false
                DispatchQueue.main.async {
                    if !metrics.scrollToBottom(animated: true) {
                        scrollToNewest(proxy, animated: true, initial: false)
                    }
                }
            }
            // Track in-flight scrolling so content-growth re-pins never fight
            // the current motion. Catalyst reports fast wheel and programmatic
            // momentum as `.animating`; treating every non-idle phase as active
            // prevents recursive scrollTo calls there. Keep iOS's narrower
            // user-driven phase semantics unchanged.
            .onScrollPhaseChange { previous, phase, context in
#if targetEnvironment(macCatalyst)
                userInteracting = phase != .idle
#else
                userInteracting = phase == .tracking
                    || phase == .interacting
                    || phase == .decelerating
#endif
                if phase == .tracking || phase == .interacting {
                    metrics.cancelBottomScrollAnimation()
                }
                if phase == .tracking || (phase == .interacting && previous == .idle) {
                    historyLoadTrigger.beginUserScroll()
                }
                let beganInteraction = previous == .tracking || previous == .idle
                if phase == .interacting, beganInteraction {
                    let rawDistanceFromTop = context.geometry.contentOffset.y
                        + context.geometry.contentInsets.top
                    if rawDistanceFromTop <= 0 {
                        requestOlderIfNeeded(distanceFromTop: 0)
                    }
                }
            }
        }
    }

    private var messageStack: some View {
        LazyVStack(spacing: 0) {
            messageRows
        }
        .scrollTargetLayout()
    }

    private var messageRows: some View {
        ForEach(rows) { row in
            rowView(row)
                .id(row.msg.id)
                .background {
                    if row.msg.id == trackedHistoryViewportID {
                        Color.clear
                            .onGeometryChange(
                                for: CGRect.self,
                                of: { proxy in
                                    proxy.frame(in: .named(Self.scrollCoordinateSpace))
                                },
                                action: { frame in
                                    metrics.trackedMessageID = row.msg.id
                                    metrics.trackedMessageFrame = frame
                                    refreshHistoryRequestIfNeeded()
                                })
                    }
                }
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    updateBoundaryVisibility(for: row.msg.id, visible: visible)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity))
        }
    }

    /// Bring the newest row into view, if there is one. `initial` marks the
    /// first open-at-bottom jump and flips `didInitialScroll`.
    private func scrollToNewest(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        initial: Bool
    ) {
        guard let last = rows.last?.id else { return }
        if initial {
            didInitialScroll = true
            stickToBottom = true
            lastSettledNewestID = last
            animateBottomGrowthForNewestID = nil
            enableOlderLoadingIfReady()
        }
        // Defer a tick so the non-lazy bottom anchor has joined the hierarchy
        // before the reader brings it into view.
        Task { @MainActor in
            await Task.yield()
            if animated {
                // Scale the duration with the distance to the bottom so a scroll
                // from far up doesn't whip past in a fixed-time blur — keep a
                // roughly constant glide speed, clamped so short hops stay snappy
                // and very long ones don't drag.
                let distance = metrics.distanceFromBottom
                let duration = min(0.7, max(0.25, distance / 5000))
                withAnimation(.easeInOut(duration: duration)) {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            if newestMessageID == last {
                lastSettledNewestID = last
                if animateBottomGrowthForNewestID == last {
                    animateBottomGrowthForNewestID = nil
                }
            }
        }
    }

    private func updateBoundaryVisibility(for id: Int32, visible: Bool) {
        if visible {
            if id == newestMessageID {
                visibleNewestID = id
                if enableOlderLoadingIfReady() {
                    requestOlderIfUnderfilled()
                }
            }
        } else {
            if visibleNewestID == id { visibleNewestID = nil }
        }
    }

    @discardableResult
    private func enableOlderLoadingIfReady() -> Bool {
        guard !canLoadOlder,
              didInitialScroll,
              metrics.isAtBottom,
              visibleNewestID == newestMessageID else { return false }
        if !initialViewportReady {
            initialViewportReady = true
        }
        canLoadOlder = true
        historyLoadTrigger.setCanLoadOlder(canLoadOlderHistory)
        return true
    }

    private func requestOlderIfNeeded(distanceFromTop: CGFloat) {
        guard canLoadOlder else { return }
        if historyLoadTrigger.observe(distanceFromTop: Double(distanceFromTop)) {
            requestOlderPage(
                viewportAnchor: currentHistoryViewportAnchor(),
                refreshViewportAnchor: true)
        }
    }

    @discardableResult
    private func processCompletedHistoryPageIfNeeded(
        _ sample: ScrollSample?,
        proxy: ScrollViewProxy
    ) -> Bool {
        let revision = sample?.historyPageRevision ?? historyPageRevision
        guard let request = metrics.historyRequest,
              revision > request.revision else { return false }
        let viewportAnchor = historyPageRenderedRowsAdded
            ? request.viewportAnchor
            : nil
        if historyPageRenderedRowsAdded {
            guard let sample else { return false }
            if sample.contentHeight <= request.preCompletionContentHeight + 1 {
                // The model revision can arrive one layout pass before the
                // LazyVStack reports the prepended rows. Wait for that actual
                // content-size change before choosing automatic vs fallback
                // viewport preservation.
                return false
            }
        }

        metrics.historyRequest = nil
        historyLoadTrigger.pageCompleted(hasMore: canLoadOlderHistory)

        guard historyPageRenderedRowsAdded, let sample else {
            settleHistoryViewportIfNeeded(distanceFromTop: metrics.distanceFromTop)
            return true
        }
        guard let viewportAnchor else {
            historyLoadTrigger.viewportSettleFailed()
            return true
        }

        switch viewportAnchor.kind {
        case .newestBottom:
            if sample.distanceFromBottom <= Self.bottomThreshold {
                settleHistoryViewportIfNeeded(distanceFromTop: sample.distanceFromTop)
            } else {
                let currentBottomAnchor = HistoryViewportAnchor(
                    messageID: newestMessageID ?? viewportAnchor.messageID,
                    unitPoint: .bottom,
                    contentHeight: viewportAnchor.contentHeight,
                    distanceFromTop: viewportAnchor.distanceFromTop,
                    kind: .newestBottom)
                restoreHistoryViewport(currentBottomAnchor, after: sample, proxy: proxy)
            }
        case .viewport:
            let automaticPreservedViewport =
                HistoryLoadTrigger.automaticAdjustmentPreservedViewport(
                previousDistanceFromTop: Double(viewportAnchor.distanceFromTop),
                previousContentHeight: Double(viewportAnchor.contentHeight),
                currentDistanceFromTop: Double(sample.distanceFromTop),
                currentContentHeight: Double(sample.contentHeight))
            let automaticAdjustmentGrosslyFailed =
                HistoryLoadTrigger.automaticAdjustmentGrosslyFailed(
                    previousDistanceFromTop: Double(viewportAnchor.distanceFromTop),
                    previousContentHeight: Double(viewportAnchor.contentHeight),
                    currentDistanceFromTop: Double(sample.distanceFromTop),
                    currentContentHeight: Double(sample.contentHeight))
            let activeAdjustmentAccepted = userInteracting
                && !automaticAdjustmentGrosslyFailed
            // During a live drag/deceleration, the user's travel between the
            // last pre-merge sample and this layout is legitimate. Trust the
            // transaction's automatic adjustment rather than rewinding the
            // active flick to an older captured position.
            if automaticPreservedViewport || activeAdjustmentAccepted {
                settleHistoryViewportIfNeeded(distanceFromTop: sample.distanceFromTop)
            } else {
                restoreHistoryViewport(viewportAnchor, after: sample, proxy: proxy)
            }
        }
        return true
    }

    private func completePendingHistoryViewportRestoreIfNeeded(
        _ sample: ScrollSample
    ) -> Bool {
        guard metrics.awaitingHistoryRestoreGeometry else { return false }
        let closeToExpected = abs(
            sample.distanceFromTop - metrics.expectedHistoryRestoreDistanceFromTop) <= 24
        guard closeToExpected || sample.isUnderfilled else { return true }
        metrics.awaitingHistoryRestoreGeometry = false
        settleHistoryViewportIfNeeded(distanceFromTop: sample.distanceFromTop)
        return true
    }

    private func restoreHistoryViewport(
        _ viewportAnchor: HistoryViewportAnchor,
        after sample: ScrollSample,
        proxy: ScrollViewProxy
    ) {
        let expectedDistanceFromTop: CGFloat
        switch viewportAnchor.kind {
        case .viewport:
            expectedDistanceFromTop = viewportAnchor.distanceFromTop
                + max(0, sample.contentHeight - viewportAnchor.contentHeight)
        case .newestBottom:
            expectedDistanceFromTop = max(
                0,
                sample.contentHeight - sample.containerHeight)
        }
        let shouldAwaitSettle = historyLoadTrigger.state == .awaitingViewportSettle
        if shouldAwaitSettle {
            metrics.awaitingHistoryRestoreGeometry = true
            metrics.expectedHistoryRestoreDistanceFromTop = expectedDistanceFromTop
            metrics.historyRestoreGeneration &+= 1
        }
        let generation = metrics.historyRestoreGeneration

        Task { @MainActor in
            await Task.yield()
            if shouldAwaitSettle,
               !metrics.awaitingHistoryRestoreGeometry
                || metrics.historyRestoreGeneration != generation {
                // A later automatic-adjustment sample completed the handoff
                // before this fallback ran.
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            transaction.scrollPositionUpdatePreservesVelocity = true
            withTransaction(transaction) {
                proxy.scrollTo(
                    viewportAnchor.kind == .newestBottom
                        ? metrics.newestMessageID ?? viewportAnchor.messageID
                        : viewportAnchor.messageID,
                    anchor: viewportAnchor.unitPoint)
            }
            guard shouldAwaitSettle else { return }

            // `scrollTo` normally emits geometry on the next layout pass. If it
            // does not, fail closed instead of inventing a settled offset that
            // could cascade into another page request.
            try? await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
            guard metrics.awaitingHistoryRestoreGeometry,
                  metrics.historyRestoreGeneration == generation else { return }
            metrics.awaitingHistoryRestoreGeometry = false
            if viewportAnchor.kind == .newestBottom, metrics.isUnderfilled {
                settleHistoryViewportIfNeeded(distanceFromTop: metrics.distanceFromTop)
            } else {
                historyLoadTrigger.viewportSettleFailed()
            }
        }
    }

    private func settleHistoryViewportIfNeeded(distanceFromTop: CGFloat) {
        historyLoadTrigger.viewportSettled(distanceFromTop: Double(distanceFromTop))
        if canLoadOlderHistory {
            requestOlderIfUnderfilled()
        }
    }

    private func requestOlderIfUnderfilled() {
        guard historyLoadTrigger.loadIfUnderfilled(metrics.isUnderfilled) else { return }
        metrics.newestMessageID = messages.last?.id
        let viewportAnchor = messages.last.map { message in
            HistoryViewportAnchor(
                messageID: message.id,
                unitPoint: .bottom,
                contentHeight: metrics.contentHeight,
                distanceFromTop: metrics.distanceFromTop,
                kind: .newestBottom)
        }
        requestOlderPage(
            viewportAnchor: viewportAnchor,
            refreshViewportAnchor: false)
    }

    private func requestOlderPage(
        viewportAnchor: HistoryViewportAnchor?,
        refreshViewportAnchor: Bool
    ) {
        metrics.historyRequest = HistoryRequestContext(
            revision: historyPageRevision,
            preCompletionContentHeight: metrics.contentHeight,
            viewportAnchor: viewportAnchor,
            refreshViewportAnchor: refreshViewportAnchor)
        onLoadOlder()
    }

    private func refreshHistoryRequestIfNeeded(
        measuredRevision: Int? = nil
    ) {
        guard var request = metrics.historyRequest,
              request.revision == (measuredRevision ?? historyPageRevision) else { return }
        request.preCompletionContentHeight = metrics.contentHeight
        if request.refreshViewportAnchor {
            request.viewportAnchor = currentHistoryViewportAnchor()
        }
        metrics.historyRequest = request
    }

    private func currentHistoryViewportAnchor() -> HistoryViewportAnchor? {
        let messageID = metrics.fullyVisibleMessageID ?? metrics.topVisibleMessageID
        if let messageID,
           metrics.trackedMessageID == messageID,
           let frame = metrics.trackedMessageFrame {
            let viewportMinY = max(0, visualTopInset)
            let viewportHeight = max(
                0,
                metrics.containerHeight - viewportMinY - max(0, visualBottomInset))
            if let anchorY = HistoryLoadTrigger.viewportAnchorY(
                rowMinY: Double(frame.minY),
                rowHeight: Double(frame.height),
                viewportMinY: Double(viewportMinY),
                viewportHeight: Double(viewportHeight)) {
                return HistoryViewportAnchor(
                    messageID: messageID,
                    unitPoint: UnitPoint(x: 0.5, y: CGFloat(anchorY)),
                    contentHeight: metrics.contentHeight,
                    distanceFromTop: metrics.distanceFromTop,
                    kind: .viewport)
            }
        }
        return nil
    }

    private var newestMessageID: Int32? {
        messages.last?.id
    }

    private var shouldAnimateBottomGrowth: Bool {
        guard !messageUpdateWasSynced, let newest = newestMessageID else { return false }
        return animateBottomGrowthForNewestID == newest || lastSettledNewestID != newest
    }

    /// Chronological rows (oldest first) with neighbour-derived day-separator and
    /// sender-header flags — the same derivation the inverted table does, minus
    /// the reversal (this list is laid out upright).
    private var rows: [Row] {
        let cal = Calendar.current
        var out: [Row] = []
        out.reserveCapacity(messages.count)
        for (i, msg) in messages.enumerated() {
            let newDay = i == 0 || !cal.isDate(msg.time, inSameDayAs: messages[i - 1].time)
            let showSender = isGroupchat && msg.direction == "in"
                && (newDay || messages[i - 1].from != msg.from)
            let avatarPath = isGroupchat && msg.direction == "in" ? avatarPaths[msg.from] : nil
            out.append(Row(msg: msg, showDay: newDay, dayLabel: Self.dayLabel(msg.time),
                           showSender: showSender, senderAvatarPath: avatarPath))
        }
        return out
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        VStack(spacing: 0) {
            if row.showDay {
                Text(row.dayLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            MessageBubble(msg: row.msg, inGroupchat: isGroupchat, showSender: row.showSender,
                          senderAvatarPath: row.senderAvatarPath,
                          onEdit: onEdit, onReply: onReply,
                          onImageTap: onImageTap, onVideoTap: onVideoTap, onActions: onActions,
                          onAvatarNeeded: { model.ensureAvatar(for: $0) },
                          onReaction: { emoji, add in
                              model.setReaction(conversationId, item: row.msg.id, emoji: emoji, add: add)
                          },
                          onDownloadFile: { item in
                              model.downloadFile(conversationId, item: item)
                          })
        }
        .padding(.horizontal, ChatLayout.horizontalPadding)
        .padding(.vertical, 3)
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return GeckoDisplayFormatters.dayLabel(date)
    }

    /// One chat row's display model (chronological order): the message plus the
    /// neighbour-derived day/sender flags.
    private struct Row: Identifiable, Equatable {
        let msg: ChatMessage
        let showDay: Bool
        let dayLabel: String
        let showSender: Bool
        let senderAvatarPath: String?
        var id: Int32 { msg.id }
    }

    /// Resolves the UIKit scroll view that SwiftUI installs around the lazy
    /// stack. The zero-sized probe lives in the scroll content, so its nearest
    /// UIScrollView ancestor is the chat scroller rather than another view in a
    /// message bubble.
    private struct ScrollViewResolver: UIViewRepresentable {
        let metrics: ScrollMetrics

        func makeUIView(context: Context) -> ScrollViewProbe {
            ScrollViewProbe(metrics: metrics)
        }

        func updateUIView(_ view: ScrollViewProbe, context: Context) {
            view.metrics = metrics
            view.resolve()
        }
    }

    private final class ScrollViewProbe: UIView {
        var metrics: ScrollMetrics

        init(metrics: ScrollMetrics) {
            self.metrics = metrics
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolve()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        func resolve() {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    metrics.scrollView = scrollView
                    return
                }
                view = current.superview
            }
        }
    }
}
