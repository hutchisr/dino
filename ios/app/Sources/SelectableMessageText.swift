import SwiftUI

struct MessageTextActions {
    let canEdit: Bool
    let reply: () -> Void
    let edit: () -> Void
    let copy: () -> Void
    let more: () -> Void
}

#if targetEnvironment(macCatalyst)

struct SelectableMessageText: View {
    enum Style: Equatable {
        case body
        case quote
    }

    let text: AttributedString
    var style: Style = .body
    var actions: MessageTextActions?

    var body: some View {
        Text(text)
            .italic(style == .quote)
            .foregroundStyle(style == .quote ? Color.secondary : Color.primary)
            .textSelection(.enabled)
            .contextMenu {
                if let actions {
                    Button {
                        actions.reply()
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    if actions.canEdit {
                        Button {
                            actions.edit()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    Button {
                        actions.copy()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        actions.more()
                    } label: {
                        Label("Reactions and More…", systemImage: "face.smiling")
                    }
                }
            }
    }
}

#endif
