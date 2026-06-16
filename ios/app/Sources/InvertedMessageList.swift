import SwiftUI
import UIKit

/// One chat row's display model: the message plus the neighbour-derived flags
/// (day separator, sender header) computed from chronological order.
private struct ChatRowModel: Equatable {
    let msg: ChatMessage
    let showDay: Bool
    let dayLabel: String
    let showSender: Bool
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
            coordinator?.parent.isAtBottom = atBottom
        }
        return controller
    }

    func updateUIViewController(_ controller: ChatListController, context: Context) {
        context.coordinator.parent = self
        controller.model = model
        controller.callbacks = ChatListController.Callbacks(
            conversationId: conversationId, onEdit: onEdit, onReply: onReply,
            onImageTap: onImageTap, onActions: onActions)
        controller.apply(messages: messages, isGroupchat: isGroupchat)
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
        init(_ parent: InvertedMessageList) {
            self.parent = parent
            self.lastScrollToken = parent.scrollToBottomToken
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

    /// Visual bottom = flipped origin. A little slack absorbs the rubber-band
    /// bounce and float imprecision so the button doesn't flicker at rest.
    private static let bottomThreshold: CGFloat = 24

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
        // SwiftUI's .safeAreaInset (the composer) already insets the bottom; the
        // flip would otherwise apply UIKit's safe-area inset to the wrong edge.
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, indexPath, id in
            let cell = table.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            // Flip the cell (not contentView — UIHostingConfiguration owns that).
            cell.transform = CGAffineTransform(scaleX: 1, y: -1)
            cell.backgroundColor = .clear
            cell.clipsToBounds = false
            cell.contentView.clipsToBounds = false
            guard let self, let row = self.rowsByID[id] else { return cell }
            cell.contentConfiguration = UIHostingConfiguration { self.rowView(row) }
                .margins(.all, 0)
            return cell
        }
        dataSource.defaultRowAnimation = .fade
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
                MessageBubble(conversationId: cb.conversationId, msg: row.msg,
                              inGroupchat: isGroupchat, showSender: row.showSender,
                              onEdit: cb.onEdit, onReply: cb.onReply,
                              onImageTap: cb.onImageTap, onActions: cb.onActions)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .environmentObject(model)
        }
    }

    /// Rebuild the row models and apply a diffable snapshot. Inserts/removals
    /// animate; in-place content changes (marked state, file progress) reconfigure
    /// the affected cells. Follows the bottom on a new newest message only if we
    /// were already there.
    func apply(messages: [ChatMessage], isGroupchat: Bool) {
        loadViewIfNeeded()
        self.isGroupchat = isGroupchat

        let cal = Calendar.current
        var chronological: [ChatRowModel] = []
        chronological.reserveCapacity(messages.count)
        for (i, msg) in messages.enumerated() {
            let newDay = i == 0 || !cal.isDate(msg.time, inSameDayAs: messages[i - 1].time)
            let showSender = isGroupchat && msg.direction == "in"
                && (newDay || messages[i - 1].from != msg.from)
            chronological.append(ChatRowModel(msg: msg, showDay: newDay,
                                              dayLabel: Self.dayLabel(msg.time),
                                              showSender: showSender))
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

    /// Scroll to the newest message. In the flipped table that's the content
    /// origin, so a plain `setContentOffset` to zero — which natively cancels any
    /// in-flight deceleration and glides — is all it takes.
    func scrollToBottom(animated: Bool) {
        loadViewIfNeeded()
        guard !orderedIDs.isEmpty else { return }
        // Row 0 = newest. scrollToRow computes the exact target offset (more
        // robust than a raw setContentOffset) and natively cancels momentum.
        // isAtBottom updates itself via scrollViewDidScroll as the glide lands.
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: animated)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let atBottom = scrollView.contentOffset.y <= Self.bottomThreshold
        if atBottom != isAtBottom {
            isAtBottom = atBottom
            onIsAtBottomChanged?(atBottom)
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt.string(from: date)
    }
}
