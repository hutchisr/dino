import SwiftUI
import UIKit

/// Long-press action sheet for a message: quick reactions, the full emoji
/// grid, and message actions (reply/edit/copy).
struct ReactionSheet: View {
    let msg: ChatMessage
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onEdit: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var detent: PresentationDetent = .fraction(0.45)
    @FocusState private var searchFocused: Bool

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🔥", "🎉", "🦎"]

    /// Every emoji with default emoji presentation, straight from Unicode
    /// metadata — no curated list to go stale — paired with its lowercased
    /// Unicode name so the grid can be searched (e.g. "fire" → 🔥).
    private static let allEmojis: [(emoji: String, name: String)] = {
        var out: [(String, String)] = []
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F,  // smileys
            0x1F900...0x1F9FF,  // supplemental symbols
            0x1FA70...0x1FAFF,  // extended-A
            0x1F300...0x1F5FF,  // misc symbols & pictographs
            0x1F680...0x1F6FF,  // transport
            0x2600...0x26FF,    // misc symbols
            0x2700...0x27BF,    // dingbats
        ]
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value),
                      scalar.properties.isEmojiPresentation else { continue }
                out.append((String(scalar), (scalar.properties.name ?? "").lowercased()))
            }
        }
        return out
    }()

    private var filteredEmojis: [(emoji: String, name: String)] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Self.allEmojis }
        return Self.allEmojis.filter { $0.name.contains(query) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Capsule().fill(Color(.systemGray4)).frame(width: 36, height: 5).padding(.top, 8)

            HStack(spacing: 10) {
                ForEach(Self.quickEmojis, id: \.self) { emoji in
                    Button {
                        onReact(emoji)
                        dismiss()
                    } label: {
                        Text(emoji).font(.system(size: 28))
                    }
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
                        UIPasteboard.general.string = msg.body
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
                        ForEach(filteredEmojis, id: \.emoji) { item in
                            Button {
                                onReact(item.emoji)
                                dismiss()
                            } label: {
                                Text(item.emoji).font(.system(size: 30))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            // Dismiss the keyboard when the user starts scrolling the grid.
            .scrollDismissesKeyboard(.immediately)
        }
        .presentationDetents([.fraction(0.45), .large], selection: $detent)
        .presentationDragIndicator(.hidden)
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
