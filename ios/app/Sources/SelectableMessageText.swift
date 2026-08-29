import SwiftUI

struct MessageTextActions {
    let canEdit: Bool
    let reply: () -> Void
    let edit: () -> Void
    let copy: () -> Void
    let more: () -> Void
}

#if targetEnvironment(macCatalyst)
import UIKit

private final class WrappingTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(bounds.width - textContainerInset.left - textContainerInset.right, 0)
        guard width > 0, textContainer.size.width != width else { return }
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    }
}

struct SelectableMessageText: UIViewRepresentable {
    enum Style {
        case body
        case quote
    }

    let text: AttributedString
    var style: Style = .body
    var actions: MessageTextActions?

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var actions: MessageTextActions?

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let actions else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                var children: [UIMenuElement] = [
                    UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
                        actions.reply()
                    },
                ]
                if actions.canEdit {
                    children.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
                        actions.edit()
                    })
                }
                children.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    actions.copy()
                })
                children.append(UIAction(title: "Reactions and More…", image: UIImage(systemName: "face.smiling")) { _ in
                    actions.more()
                })
                return UIMenu(children: children)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.actions = actions
        return coordinator
    }

    func makeUIView(context: Context) -> UITextView {
        let view = WrappingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.textContainer.widthTracksTextView = false
        view.textContainer.heightTracksTextView = false
        view.adjustsFontForContentSizeCategory = true
        view.tintColor = .tintColor
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        if actions != nil {
            view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let value = resolvedText
        if !view.attributedText.isEqual(to: value) {
            view.attributedText = value
        }
        context.coordinator.actions = actions
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth > 0 else { return nil }
        let unwrapped = uiView.sizeThatFits(CGSize(width: 10_000, height: 10_000))
        let width = min(ceil(unwrapped.width), proposedWidth)
        let wrapped = uiView.sizeThatFits(CGSize(width: width, height: 10_000))
        return CGSize(width: width, height: ceil(wrapped.height))
    }
    private var resolvedText: NSAttributedString {
        let value = NSMutableAttributedString(attributedString: NSAttributedString(text))
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let font: UIFont
        let color: UIColor
        switch style {
        case .body:
            font = bodyFont
            color = .label
        case .quote:
            font = .italicSystemFont(ofSize: bodyFont.pointSize)
            color = .secondaryLabel
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        value.addAttributes(
            [.font: font, .foregroundColor: color, .paragraphStyle: paragraph],
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }
}

#endif
