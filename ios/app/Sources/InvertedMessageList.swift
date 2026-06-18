import SwiftUI
import UIKit

/// One chat row's display model: the message plus the neighbour-derived flags
/// (day separator, sender header) computed from chronological order.
private struct ChatRowModel: Equatable {
    let msg: ChatMessage
    let showDay: Bool
    let dayLabel: String
    let showSender: Bool
    let senderAvatarPath: String?
}

/// A table cell that reports **zero safe-area insets**. UIKit otherwise inflates
/// a cell's layout margins by the safe-area inset as the cell nears a screen
/// edge, which the `UIHostingConfiguration` host view picks up and turns into
/// growing space above/below the bubble — making inter-message gaps widen as a
/// row approaches the top or bottom of the screen. The chat manages its own
/// insets (the chrome floats over the table), so the cells never need safe-area
/// awareness; zeroing it here keeps spacing constant at every scroll position.
private final class FlatCell: UITableViewCell {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

/// The chat message list, backed by an **inverted UIKit table view** rather than
/// a SwiftUI `ScrollView`.
///
/// Why UIKit: the SwiftUI `ScrollView` gave us a long tail of scroll bugs — the
/// scroll-to-bottom button snapping or going dead mid-flick, the chat opening a
/// screenful above the newest message, and a freshly-decoded image growing its
/// row and shoving the latest message off the bottom. Every one came from
/// fighting SwiftUI's scroll position imperatively (settling flags, re-pin
/// loops, geometry probes). An inverted `UITableView` — newest row at the visual
/// bottom, `contentOffset.y ≈ 0` — makes "pinned to the bottom" the natural
/// resting state, turns scroll-to-bottom into a native momentum-cancelling
/// `setContentOffset`, and reduces "am I at the bottom?" to `contentOffset.y <=
/// threshold`. Cells host the existing SwiftUI `MessageBubble` via
/// `UIHostingConfiguration`. (Reference: MeshCoreOne's ChatTableView.)
struct InvertedMessageList: UIViewControllerRepresentable {
    let messages: [ChatMessage]           // chronological: oldest first
    let conversationId: Int32
    let isGroupchat: Bool
    let avatarPaths: [String: String]
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
    let onActions: (ChatMessage) -> Void

    func makeUIViewController(context: Context) -> ChatListController {
        let controller = ChatListController()
        controller.onIsAtBottomChanged = { [weak coordinator = context.coordinator] atBottom in
            DispatchQueue.main.async {
                coordinator?.setIsAtBottom(atBottom)
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: ChatListController, context: Context) {
        context.coordinator.parent = self
        controller.model = model
        controller.callbacks = ChatListController.Callbacks(
            conversationId: conversationId, onEdit: onEdit, onReply: onReply,
            onImageTap: onImageTap, onActions: onActions)
        controller.setVisualInsets(
            top: visualTopInset,
            bottom: visualBottomInset,
            scrollIndicatorTop: visualScrollIndicatorTopInset,
            scrollIndicatorBottom: visualScrollIndicatorBottomInset)
        controller.apply(messages: messages, isGroupchat: isGroupchat, avatarPaths: avatarPaths)
        if context.coordinator.lastScrollToken != scrollToBottomToken {
            context.coordinator.lastScrollToken = scrollToBottomToken
            // Defer past this SwiftUI update: issuing the scroll from inside
            // updateUIViewController gets dropped — it has to run on the next
            // runloop tick.
            DispatchQueue.main.async { controller.scrollToBottom(animated: true) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: InvertedMessageList
        var lastScrollToken: Int
        private var pendingIsAtBottom: Bool?
        private var isAtBottomUpdateScheduled = false

        init(_ parent: InvertedMessageList) {
            self.parent = parent
            self.lastScrollToken = parent.scrollToBottomToken
        }

        func setIsAtBottom(_ atBottom: Bool) {
            pendingIsAtBottom = atBottom
            guard !isAtBottomUpdateScheduled else { return }

            isAtBottomUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let atBottom = self.pendingIsAtBottom else { return }
                self.pendingIsAtBottom = nil
                self.isAtBottomUpdateScheduled = false
                if self.parent.isAtBottom != atBottom {
                    self.parent.isAtBottom = atBottom
                }
            }
        }
    }
}

/// The inverted table controller. Flipped vertically so row 0 (the newest
/// message) sits at the visual bottom; each cell is flipped back to upright.
final class ChatListController: UITableViewController {
    struct Callbacks {
        let conversationId: Int32
        let onEdit: (ChatMessage) -> Void
        let onReply: (ChatMessage) -> Void
        let onImageTap: (String) -> Void
        let onActions: (ChatMessage) -> Void
    }

    var model: AppModel?
    var callbacks: Callbacks?
    var onIsAtBottomChanged: ((Bool) -> Void)?

    private var dataSource: UITableViewDiffableDataSource<Int, Int32>!
    private var rowsByID: [Int32: ChatRowModel] = [:]
    private var orderedIDs: [Int32] = []        // reversed: newest (row 0) first
    private var isGroupchat = false
    private var hasLoaded = false
    private(set) var isAtBottom = true
    private var visualTopInset: CGFloat = 0
    private var visualBottomInset: CGFloat = 0
    private var visualScrollIndicatorTopInset: CGFloat = 0
    private var visualScrollIndicatorBottomInset: CGFloat = 0
    private var pendingBottomCorrection = false
    private var bottomCorrectionWorkItem: DispatchWorkItem?

    /// Deterministic per-row heights, measured once offscreen and cached by
    /// message id. Invalidated when a row's content changes or the table width
    /// changes. Served from both `heightForRowAt` and `estimatedHeightForRowAt`
    /// so `contentSize` stays stable as rows recycle.
    private var heightCache: [Int32: CGFloat] = [:]
    private var heightMeasureWidth: CGFloat = 0
    /// Reused offscreen cell for height measurement. A `FlatCell` so its
    /// (zero) safe-area handling matches the real, in-table cells.
    private lazy var sizingCell: UITableViewCell = FlatCell(style: .default, reuseIdentifier: nil)

    /// Visual bottom = flipped origin. A little slack absorbs the rubber-band
    /// bounce and float imprecision so the button doesn't flicker at rest, but
    /// keep it tight enough that the scroll-down affordance stays visible until
    /// the newest message is actually pinned.
    private static let bottomThreshold: CGFloat = 8

    init() { super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Flip the table so the newest row anchors to the visual bottom.
        tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .interactive
        // Insets are managed manually because the SwiftUI chrome floats over the
        // table. The vertical flip swaps visual top/bottom, so UIKit's
        // automatic safe-area insets would land on the wrong visual edge.
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.register(FlatCell.self, forCellReuseIdentifier: "cell")
        // Row heights are computed deterministically (see `measuredHeight`) and
        // served from `heightForRowAt`, rather than relying on UIKit's
        // self-sizing of `UIHostingConfiguration` cells — that self-sizing is
        // unstable here (the same row measures at different heights on different
        // passes), which made `contentSize` drift and inter-message gaps grow
        // while scrolling back through history.
        tableView.estimatedRowHeight = 80

        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, indexPath, id in
            let cell = table.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            // Flip the cell (not contentView — UIHostingConfiguration owns that).
            cell.transform = CGAffineTransform(scaleX: 1, y: -1)
            cell.backgroundColor = .clear
            cell.clipsToBounds = false
            cell.contentView.clipsToBounds = false
            // `FlatCell` reports zero safe-area insets so the cell's margins (and
            // the visible gap around the bubble) don't grow as the row nears a
            // screen edge. `.margins(.all, 0)` keeps the hosted content flush.
            guard let self, let row = self.rowsByID[id] else { return cell }
            cell.contentConfiguration = UIHostingConfiguration { self.rowView(row) }
                .margins(.all, 0)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
    }

    /// Insets expressed in visual coordinates. Because the table is vertically
    /// flipped, visual bottom maps to UIKit's top inset and visual top maps to
    /// UIKit's bottom inset.
    func setVisualInsets(
        top: CGFloat,
        bottom: CGFloat,
        scrollIndicatorTop: CGFloat,
        scrollIndicatorBottom: CGFloat
    ) {
        loadViewIfNeeded()
        let top = max(0, top.rounded(.up))
        let bottom = max(0, bottom.rounded(.up))
        let scrollIndicatorTop = max(0, scrollIndicatorTop.rounded(.up))
        let scrollIndicatorBottom = max(0, scrollIndicatorBottom.rounded(.up))
        guard top != visualTopInset || bottom != visualBottomInset
            || scrollIndicatorTop != visualScrollIndicatorTopInset
            || scrollIndicatorBottom != visualScrollIndicatorBottomInset
        else { return }

        let wasAtBottom = isAtBottom
        visualTopInset = top
        visualBottomInset = bottom
        visualScrollIndicatorTopInset = scrollIndicatorTop
        visualScrollIndicatorBottomInset = scrollIndicatorBottom
        tableView.contentInset = UIEdgeInsets(top: bottom, left: 0, bottom: top, right: 0)
        tableView.scrollIndicatorInsets = UIEdgeInsets(
            top: scrollIndicatorBottom,
            left: 0,
            bottom: scrollIndicatorTop,
            right: 0)
        if wasAtBottom {
            scrollToBottom(animated: false)
        } else {
            updateBottomState()
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRowModel) -> some View {
        if let model, let cb = callbacks {
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
                              onEdit: cb.onEdit, onReply: cb.onReply,
                              onImageTap: cb.onImageTap, onActions: cb.onActions,
                              onAvatarNeeded: { model.ensureAvatar(for: $0) },
                              onReaction: { emoji, add in
                                  model.setReaction(cb.conversationId, item: row.msg.id, emoji: emoji, add: add)
                              },
                              onDownloadFile: { item in
                                  model.downloadFile(cb.conversationId, item: item)
                              })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        }
    }

    /// Rebuild the row models and apply a diffable snapshot. Inserts/removals
    /// animate; in-place content changes (marked state, file progress) reconfigure
    /// the affected cells. Follows the bottom on a new newest message only if we
    /// were already there.
    func apply(messages: [ChatMessage], isGroupchat: Bool, avatarPaths: [String: String]) {
        loadViewIfNeeded()
        self.isGroupchat = isGroupchat

        let cal = Calendar.current
        var chronological: [ChatRowModel] = []
        chronological.reserveCapacity(messages.count)
        for (i, msg) in messages.enumerated() {
            let newDay = i == 0 || !cal.isDate(msg.time, inSameDayAs: messages[i - 1].time)
            let showSender = isGroupchat && msg.direction == "in"
                && (newDay || messages[i - 1].from != msg.from)
            let avatarPath = isGroupchat && msg.direction == "in" ? avatarPaths[msg.from] : nil
            chronological.append(ChatRowModel(msg: msg, showDay: newDay,
                                              dayLabel: Self.dayLabel(msg.time),
                                              showSender: showSender,
                                              senderAvatarPath: avatarPath))
        }

        let reversed = Array(chronological.reversed())   // row 0 = newest
        let newOrderedIDs = reversed.map { $0.msg.id }
        var newRowsByID: [Int32: ChatRowModel] = [:]
        for row in reversed { newRowsByID[row.msg.id] = row }

        // Items whose visible content changed but identity didn't → reconfigure.
        let changedIDs = newOrderedIDs.filter { id in
            guard let old = rowsByID[id], let new = newRowsByID[id] else { return false }
            return old != new
        }
        let wasAtBottom = isAtBottom
        let newestChanged = newOrderedIDs.first != orderedIDs.first

        // Drop stale heights: changed rows must be re-measured, and rows no
        // longer present should not linger in the cache.
        for id in changedIDs { heightCache[id] = nil }
        let live = Set(newOrderedIDs)
        heightCache = heightCache.filter { live.contains($0.key) }

        rowsByID = newRowsByID
        orderedIDs = newOrderedIDs

        var snapshot = NSDiffableDataSourceSnapshot<Int, Int32>()
        snapshot.appendSections([0])
        snapshot.appendItems(newOrderedIDs, toSection: 0)
        if !changedIDs.isEmpty { snapshot.reconfigureItems(changedIDs) }
        dataSource.apply(snapshot, animatingDifferences: hasLoaded)

        if !hasLoaded {
            hasLoaded = true   // flipped table opens at offset 0 = newest; nothing to do
        } else if newestChanged && wasAtBottom {
            scrollToBottom(animated: false)
        }
    }

    /// Scroll to the newest message. In the flipped table, the visual bottom is
    /// the adjusted top inset's negative offset.
    func scrollToBottom(animated: Bool) {
        loadViewIfNeeded()
        guard !orderedIDs.isEmpty else { return }
        // Row 0 = newest. The visual bottom maps to UIKit's minimum offset:
        // negative adjusted top inset. The inset itself is the floating composer
        // clearance, so targeting 0 stops short.
        tableView.layoutIfNeeded()
        let target = CGPoint(x: 0, y: bottomContentOffsetY)
        bottomCorrectionWorkItem?.cancel()

        if animated {
            pendingBottomCorrection = true
            tableView.setContentOffset(target, animated: true)
            scheduleBottomCorrectionFallback()
        } else {
            pendingBottomCorrection = false
            tableView.setContentOffset(target, animated: false)
            updateBottomState()
        }
    }

    // MARK: - Height estimation

    /// Measure a row's height offscreen with a reused `FlatCell`. The result is
    /// cached and reused; the same value feeds both the real and estimated
    /// height so the table never has to reconcile a wrong guess.
    private func measuredHeight(for id: Int32) -> CGFloat {
        let width = tableView.bounds.width
        guard width > 0, let row = rowsByID[id] else { return 80 }
        if heightMeasureWidth != width {
            heightMeasureWidth = width
            heightCache.removeAll()
        }
        if let cached = heightCache[id] { return cached }
        sizingCell.contentConfiguration = UIHostingConfiguration { self.rowView(row) }
            .margins(.all, 0)
        sizingCell.bounds = CGRect(x: 0, y: 0, width: width, height: 2000)
        sizingCell.contentView.bounds = CGRect(x: 0, y: 0, width: width, height: 2000)
        sizingCell.setNeedsLayout()
        sizingCell.layoutIfNeeded()
        let size = sizingCell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        let h = ceil(size.height)
        heightCache[id] = h
        return h
    }

    override func tableView(_ tableView: UITableView,
                            heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < orderedIDs.count else { return 80 }
        return measuredHeight(for: orderedIDs[indexPath.row])
    }

    override func tableView(_ tableView: UITableView,
                            estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < orderedIDs.count else { return 80 }
        return measuredHeight(for: orderedIDs[indexPath.row])
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateBottomState()
    }

    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingBottomCorrection = false
        bottomCorrectionWorkItem?.cancel()
        bottomCorrectionWorkItem = nil
    }

    override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishBottomCorrection()
    }

    private var bottomContentOffsetY: CGFloat {
        -tableView.adjustedContentInset.top
    }

    private func scheduleBottomCorrectionFallback() {
        let work = DispatchWorkItem { [weak self] in
            self?.finishBottomCorrection()
        }
        bottomCorrectionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func finishBottomCorrection() {
        guard pendingBottomCorrection else { return }
        pendingBottomCorrection = false
        bottomCorrectionWorkItem?.cancel()
        bottomCorrectionWorkItem = nil
        correctBottomOffsetIfNeeded()

        // UIHostingConfiguration cells can report their final height one layout
        // pass after the scroll animation completes. Correct again on the next
        // runloop so the final resting offset is exact.
        DispatchQueue.main.async { [weak self] in
            self?.correctBottomOffsetIfNeeded()
        }
    }

    private func correctBottomOffsetIfNeeded() {
        tableView.layoutIfNeeded()
        let targetY = bottomContentOffsetY
        if abs(tableView.contentOffset.y - targetY) > 0.5 {
            tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        }
        updateBottomState()
    }

    private func updateBottomState() {
        let atBottom = tableView.contentOffset.y <= bottomContentOffsetY + Self.bottomThreshold
        if atBottom != isAtBottom {
            isAtBottom = atBottom
            onIsAtBottomChanged?(atBottom)
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return GeckoDisplayFormatters.dayLabel(date)
    }
}
