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

    private struct EmojiItem: Identifiable {
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

                ScrollView {
                    if filteredEmojis.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .padding(.top, 24)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 6) {
                            ForEach(filteredEmojis) { item in
                                Button {
                                    onReact(item.emoji)
                                    dismiss()
                                } label: {
                                    Text(item.emoji).font(.system(size: 30))
                                }
                                .accessibilityLabel(item.name)
#if targetEnvironment(macCatalyst)
                                .buttonStyle(.plain)
#endif
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
#if targetEnvironment(macCatalyst)
                // Wheel events require a rendered native hit-test surface; a
                // contentShape alone does not cover transparent grid gaps.
                .background(Color(uiColor: .systemBackground))
#endif
                // Dismiss the keyboard when the user starts scrolling the grid.
                .scrollDismissesKeyboard(.immediately)
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
}
