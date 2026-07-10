import SwiftUI

/// A **pure-SwiftUI** alternative to `InvertedMessageList` (the UIKit
/// `UITableView`-backed list), built on the modern iOS 18+ scroll APIs:
/// `ScrollViewReader` for programmatic scrolling, `.onScrollGeometryChange` for
/// "am I at the bottom?", and `.contentMargins` for the floating-chrome insets.
///
/// This is an experiment, kept side-by-side with `InvertedMessageList` so the
/// two can be compared on device (toggle in Account settings). Unlike the
/// inverted table, this list is laid out **upright** — oldest at the top, newest
/// at the bottom. It opens pinned to the newest message by scrolling the last
/// row into view (we can't use `.defaultScrollAnchor(.bottom)`: on a ScrollView
/// that starts empty and is populated asynchronously it leaves the list stuck
/// blank), and follows new messages only while already pinned to the bottom.
///
/// It deliberately exposes the **same initializer as `InvertedMessageList`** so
/// `ChatView` can swap one for the other with no other changes.
struct SwiftUIMessageList: View {
    let messages: [ChatMessage]           // chronological: oldest first
    let messageRevision: Int
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
    /// arrivals animate (and only while already pinned).
    @State private var didInitialScroll = false

    /// Older-history paging stays disabled until scroll visibility confirms the
    /// initial jump has put the newest row at the measured bottom. Otherwise the
    /// oldest row's first appearance at the ScrollView's default top position
    /// immediately requests page two.
    @State private var canLoadOlder = false
    @State private var visibleOldestID: Int32?
    @State private var visibleNewestID: Int32?
    /// Prevent repeated visibility/layout callbacks from requesting the same
    /// page boundary more than once.
    @State private var requestedOldestID: Int32?

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

    /// Briefly flipped true to cancel any in-flight momentum/slide before a
    /// programmatic scroll-to-bottom, so the glide starts from rest instead of
    /// fighting a decelerating scroll. Toggling `.scrollDisabled` halts the
    /// active scroll immediately; we drop it again on the next run loop.
    @State private var haltScroll = false

    /// Latest measured remaining downward travel (points to the bottom). Parked
    /// in a reference holder so updating it on every scroll frame doesn't
    /// invalidate the view; read when scrolling to the bottom to scale the
    /// animation duration to the distance (a roughly constant glide speed,
    /// instead of a fixed time that whips past from far up).
    @State private var metrics = ScrollMetrics()

    /// Mutable scroll metrics kept OUT of `@State`-tracked value storage so
    /// per-frame writes don't re-render the list.
    private final class ScrollMetrics {
        var distanceFromBottom: CGFloat = 0
        var isAtBottom = false
    }

    /// Slack (points) for the at-bottom test so the button doesn't flicker at
    /// rest under rubber-banding / sub-pixel offsets. Matches the spirit of the
    /// inverted table's 8pt threshold but a touch looser for SwiftUI's geometry.
    private static let bottomThreshold: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.msg.id)
                            .onScrollVisibilityChange(threshold: 0.01) { visible in
                                updateBoundaryVisibility(for: row.msg.id, visible: visible)
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: newestMessageID)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollDisabled(haltScroll)
            // The chat chrome (top bar, composer) floats over the list, so inset
            // the content (and the scroll indicators independently) to clear it.
            .contentMargins(.top, max(0, visualTopInset), for: .scrollContent)
            .contentMargins(.bottom, max(0, visualBottomInset), for: .scrollContent)
            .contentMargins(.top, max(0, visualScrollIndicatorTopInset), for: .scrollIndicators)
            .contentMargins(.bottom, max(0, visualScrollIndicatorBottomInset), for: .scrollIndicators)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                // Distance the content can still travel downward; ~0 means
                // pinned to the newest message. Empirically, at the resting
                // bottom SwiftUI gives
                //   contentSize == contentOffset.y + containerSize + insets.top
                // (the bottom inset is slack the content never scrolls into), so
                // the bottom-most offset is contentSize − containerSize − top.
                let bottomOffsetY = geo.contentSize.height
                    - geo.containerSize.height - geo.contentInsets.top
                return max(0, bottomOffsetY - geo.contentOffset.y)
            } action: { _, distanceFromBottom in
                metrics.distanceFromBottom = distanceFromBottom
                let atBottom = distanceFromBottom <= Self.bottomThreshold
                metrics.isAtBottom = atBottom
                // While we intend to stay glued and the user isn't dragging,
                // treat a gap opened purely by content growth as still-at-bottom,
                // so the scroll-down button doesn't flash while images load —
                // we're about to snap back to the newest message.
                let effectiveAtBottom = atBottom || (stickToBottom && !userInteracting)
                if isAtBottom != effectiveAtBottom { isAtBottom = effectiveAtBottom }
                // Only the user's own scrolling releases or re-arms the glue.
                if userInteracting { stickToBottom = atBottom }
                enableOlderLoadingIfReady()
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
            // blank (FB-worthy SwiftUI bug). Instead we bring the last row into
            // view imperatively via the reader.
            .onAppear { scrollToNewest(proxy, animated: false, initial: true) }
            .onChange(of: newestMessageID) { _, newest in
                guard let newest else { return }
                if !didInitialScroll {
                    scrollToNewest(proxy, animated: false, initial: true)
                } else if stickToBottom {
                    animateBottomGrowthForNewestID = newest
                    scrollToNewest(proxy, animated: true, initial: false)
                }
            }
            .onChange(of: scrollToBottomToken) { _, _ in
                stickToBottom = true
                // Cancel any in-flight momentum/slide first (toggling
                // `.scrollDisabled` halts a decelerating scroll immediately), then
                // glide from rest on the next run loop so the two don't fight.
                haltScroll = true
                DispatchQueue.main.async {
                    haltScroll = false
                    scrollToNewest(proxy, animated: true, initial: false)
                }
            }
            // The user's own dragging/flinging is the only thing that releases
            // the stick-to-bottom intent; track when they're driving the scroll
            // so content-growth re-pins never fight a finger.
            .onScrollPhaseChange { _, phase, _ in
                userInteracting = phase == .tracking
                    || phase == .interacting
                    || phase == .decelerating
            }
        }
    }

    /// Bring the newest row into view, if there is one. `initial` marks the
    /// first open-at-bottom jump and flips `didInitialScroll`.
    private func scrollToNewest(_ proxy: ScrollViewProxy, animated: Bool, initial: Bool) {
        guard let last = rows.last?.id else { return }
        if initial {
            didInitialScroll = true
            stickToBottom = true
            lastSettledNewestID = last
            animateBottomGrowthForNewestID = nil
            enableOlderLoadingIfReady()
        }
        // Defer a tick so the LazyVStack has materialised the row before we ask
        // the reader to bring it into view.
        DispatchQueue.main.async {
            if animated {
                // Scale the duration with the distance to the bottom so a scroll
                // from far up doesn't whip past in a fixed-time blur — keep a
                // roughly constant glide speed, clamped so short hops stay snappy
                // and very long ones don't drag.
                let distance = metrics.distanceFromBottom
                let duration = min(0.7, max(0.25, distance / 5000))
                withAnimation(.easeInOut(duration: duration)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(last, anchor: .bottom)
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
            if id == oldestMessageID {
                visibleOldestID = id
                requestOlderIfNeeded()
            }
            if id == newestMessageID {
                visibleNewestID = id
                enableOlderLoadingIfReady()
            }
        } else {
            if visibleOldestID == id { visibleOldestID = nil }
            if visibleNewestID == id { visibleNewestID = nil }
        }
    }

    private func enableOlderLoadingIfReady() {
        guard !canLoadOlder,
              didInitialScroll,
              metrics.isAtBottom,
              visibleNewestID == newestMessageID else { return }
        canLoadOlder = true
        requestOlderIfNeeded()
    }

    private func requestOlderIfNeeded() {
        guard canLoadOlder,
              let oldest = oldestMessageID,
              visibleOldestID == oldest,
              requestedOldestID != oldest else { return }
        requestedOldestID = oldest
        onLoadOlder()
    }

    private var newestMessageID: Int32? {
        messages.last?.id
    }

    private var oldestMessageID: Int32? {
        messages.first?.id
    }

    private var shouldAnimateBottomGrowth: Bool {
        guard let newest = newestMessageID else { return false }
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
}
