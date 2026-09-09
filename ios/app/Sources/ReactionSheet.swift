import SwiftUI
import UIKit

/// Long-press action sheet for a message: quick reactions, the full emoji
/// grid, and message actions (reply/edit/copy).
struct ReactionSheet: View {
    let msg: ChatMessage
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onEdit: (() -> Void)?
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var detent: PresentationDetent = .fraction(0.45)
    @FocusState private var searchFocused: Bool

    private struct EmojiItem: Identifiable, Equatable {
        let emoji: String
        let name: String
        var id: String { emoji }
    }

    private static let quickEmojis: [EmojiItem] = [
        EmojiItem(emoji: "👍", name: "thumbs up"),
        EmojiItem(emoji: "❤️", name: "red heart"),
        EmojiItem(emoji: "😂", name: "face with tears of joy"),
        EmojiItem(emoji: "😮", name: "face with open mouth"),
        EmojiItem(emoji: "😢", name: "crying face"),
        EmojiItem(emoji: "🔥", name: "fire"),
        EmojiItem(emoji: "🎉", name: "party popper"),
        EmojiItem(emoji: "🦎", name: "lizard"),
    ]

    /// Lightweight Unicode scalar catalog. This intentionally favors the
    /// common default-presentation emoji over the much larger RGI sequence set.
    private static let allEmojis: [EmojiItem] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F,  // smileys
            0x1F900...0x1F9FF,  // supplemental symbols
            0x1FA70...0x1FAFF,  // extended-A
            0x1F300...0x1F5FF,  // misc symbols and pictographs
            0x1F680...0x1F6FF,  // transport
            0x2600...0x26FF,    // misc symbols
            0x2700...0x27BF,    // dingbats
        ]
        var items: [EmojiItem] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value),
                      scalar.properties.isEmojiPresentation else { continue }
                items.append(
                    EmojiItem(
                        emoji: String(scalar),
                        name: (scalar.properties.name ?? "").lowercased()
                    )
                )
            }
        }
        return items
    }()

    private var filteredEmojis: [EmojiItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Self.allEmojis }
        return Self.allEmojis.filter { $0.name.contains(query) }
    }

    var body: some View {
        let items = filteredEmojis

        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(Self.quickEmojis) { item in
                        Button {
                            onReact(item.emoji)
                            dismiss()
                        } label: {
                            Text(item.emoji).font(.system(size: 28))
                        }
                        .accessibilityLabel(item.name)
#if targetEnvironment(macCatalyst)
                        .buttonStyle(.plain)
#endif
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 24) {
                    Button {
                        onReply()
                        dismiss()
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    if let onEdit {
                        Button {
                            onEdit()
                            dismiss()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    if !msg.isFile {
                        Button {
                            onCopy()
                            dismiss()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
                .font(.callout)

                Divider()

                searchBar

#if targetEnvironment(macCatalyst)
                if items.isEmpty {
                    ScrollView {
                        ContentUnavailableView.search(text: search)
                            .padding(.top, 24)
                    }
                    .background(Color(uiColor: .systemBackground))
                    .scrollDismissesKeyboard(.immediately)
                } else {
                    CatalystEmojiGrid(items: items) { emoji in
                        onReact(emoji)
                        dismiss()
                    }
                }
#else
                ScrollView {
                    if items.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .padding(.top, 24)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 6) {
                            ForEach(items) { item in
                                Button {
                                    onReact(item.emoji)
                                    dismiss()
                                } label: {
                                    Text(item.emoji).font(.system(size: 30))
                                }
                                .accessibilityLabel(item.name)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                // Dismiss the keyboard when the user starts scrolling the grid.
                .scrollDismissesKeyboard(.immediately)
#endif
            }
#if !targetEnvironment(macCatalyst)
            .padding(.top, 25)
#endif
#if targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .padding(4)
                    }
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
                .sharedBackgroundVisibility(.hidden)
            }
#endif
        }
        .presentationDetents([.fraction(0.45), .large], selection: $detent)
#if targetEnvironment(macCatalyst)
        .presentationDragIndicator(.hidden)
#else
        .presentationDragIndicator(.visible)
#endif
        // Expand to full height when searching so the keyboard doesn't cover
        // the results.
        .onChange(of: searchFocused) { _, focused in
            if focused { detent = .large }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search emoji", text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6), in: Capsule())
        .padding(.horizontal, 12)
    }

#if targetEnvironment(macCatalyst)
    private struct CatalystEmojiGrid: UIViewRepresentable {
        let items: [EmojiItem]
        let onSelect: (String) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeUIView(context: Context) -> UICollectionView {
            let view = UICollectionView(frame: .zero, collectionViewLayout: GridLayout())
            // An opaque native surface also receives wheel events in the gaps
            // between cells and below short search results.
            view.backgroundColor = .systemBackground
            view.isOpaque = true
            view.keyboardDismissMode = .onDrag
            view.contentInsetAdjustmentBehavior = .never
            view.alwaysBounceVertical = true
            view.allowsSelection = false
            view.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseIdentifier)
            view.dataSource = context.coordinator
            return view
        }

        func updateUIView(_ uiView: UICollectionView, context: Context) {
            let itemsChanged = context.coordinator.parent.items != items
            // Visible buttons always call the latest SwiftUI action, even when
            // the catalog did not change and their cells are not reconfigured.
            context.coordinator.parent = self
            guard itemsChanged else { return }
            uiView.reloadData()
            uiView.setContentOffset(.zero, animated: false)
        }

        final class Coordinator: NSObject, UICollectionViewDataSource {
            var parent: CatalystEmojiGrid

            init(_ parent: CatalystEmojiGrid) {
                self.parent = parent
            }

            func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
                parent.items.count
            }

            func collectionView(
                _ collectionView: UICollectionView,
                cellForItemAt indexPath: IndexPath
            ) -> UICollectionViewCell {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: EmojiCell.reuseIdentifier,
                    for: indexPath
                ) as! EmojiCell
                cell.configure(parent.items[indexPath.item]) { [weak self] emoji in
                    self?.parent.onSelect(emoji)
                }
                return cell
            }
        }

        final class EmojiCell: UICollectionViewCell {
            static let reuseIdentifier = "ReactionEmoji"
            private let button = UIButton(type: .custom)
            private var emoji = ""
            private var onSelect: ((String) -> Void)?

            override init(frame: CGRect) {
                super.init(frame: frame)
                button.titleLabel?.font = .systemFont(ofSize: 30)
                button.frame = contentView.bounds
                button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                button.addTarget(self, action: #selector(selectEmoji), for: .touchUpInside)
                contentView.addSubview(button)
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func configure(_ item: EmojiItem, onSelect: @escaping (String) -> Void) {
                emoji = item.emoji
                self.onSelect = onSelect
                button.setTitle(item.emoji, for: .normal)
                button.accessibilityLabel = item.name
            }

            @objc private func selectEmoji() {
                onSelect?(emoji)
            }
        }

        final class GridLayout: UICollectionViewFlowLayout {
            override init() {
                super.init()
                minimumInteritemSpacing = 6
                minimumLineSpacing = 6
                sectionInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
                estimatedItemSize = .zero
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func prepare() {
                if let collectionView {
                    let width = max(0, collectionView.bounds.width - sectionInset.left - sectionInset.right)
                    let columns = max(1, floor((width + minimumInteritemSpacing) / (40 + minimumInteritemSpacing)))
                    let cellWidth = (width - (columns - 1) * minimumInteritemSpacing) / columns
                    let scale = collectionView.traitCollection.displayScale
                    let size = CGSize(width: floor(cellWidth * scale) / scale, height: 36)
                    if itemSize != size {
                        itemSize = size
                    }
                }
                super.prepare()
            }

            override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
                newBounds.width != collectionView?.bounds.width
            }
        }
    }
#endif
}
