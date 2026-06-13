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

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🔥", "🎉", "🦎"]

    /// Every emoji with default emoji presentation, straight from Unicode
    /// metadata — no curated list to go stale.
    private static let allEmojis: [String] = {
        var out: [String] = []
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
                out.append(String(scalar))
            }
        }
        return out
    }()

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

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.adaptive(minimum: 40)), count: 8), spacing: 6) {
                    ForEach(Self.allEmojis, id: \.self) { emoji in
                        Button {
                            onReact(emoji)
                            dismiss()
                        } label: {
                            Text(emoji).font(.system(size: 30))
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .presentationDetents([.fraction(0.45), .large])
        .presentationDragIndicator(.hidden)
    }
}
