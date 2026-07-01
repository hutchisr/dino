import SwiftUI
import UIKit

struct ComposerPastedImage {
    let data: Data
    let fileExtension: String
}

struct PasteAwareComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let maxLines: Int
    let canPasteImages: Bool
    let onImagePaste: (ComposerPastedImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PasteAwareTextView {
        let view = PasteAwareTextView()
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = .systemBlue
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .default
        view.spellCheckingType = .default
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onImagePaste = { [weak coordinator = context.coordinator] image in
            coordinator?.handleImagePaste(image)
        }
        return view
    }

    func updateUIView(_ uiView: PasteAwareTextView, context: Context) {
        context.coordinator.parent = self
        uiView.canPasteImages = canPasteImages
        if uiView.text != text {
            uiView.text = text
            uiView.invalidateIntrinsicContentSize()
        }
        updateScrolling(uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteAwareTextView, context: Context) -> CGSize? {
        guard let width = proposal.width ?? nonZeroWidth(uiView.bounds.width) else { return nil }
        let measuredHeight = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: width,
            height: min(max(measuredHeight, minTextHeight(uiView)), maxTextHeight(uiView))
        )
    }

    private func updateScrolling(_ uiView: UITextView) {
        guard let width = nonZeroWidth(uiView.bounds.width) else { return }
        let measuredHeight = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        uiView.isScrollEnabled = measuredHeight > maxTextHeight(uiView) + 1
    }

    private func nonZeroWidth(_ width: CGFloat) -> CGFloat? {
        width > 0 ? width : nil
    }

    private func minTextHeight(_ uiView: UITextView) -> CGFloat {
        ceil((uiView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight)
    }

    private func maxTextHeight(_ uiView: UITextView) -> CGFloat {
        minTextHeight(uiView) * CGFloat(max(maxLines, 1))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteAwareComposerTextView

        init(_ parent: PasteAwareComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.updateScrolling(textView)
            textView.invalidateIntrinsicContentSize()
        }

        func handleImagePaste(_ image: ComposerPastedImage) {
            parent.onImagePaste(image)
        }
    }
}

final class PasteAwareTextView: UITextView {
    var canPasteImages = true
    var onImagePaste: ((ComposerPastedImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), canPasteImages, PasteboardImageReader.hasImage() {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if canPasteImages, let image = PasteboardImageReader.readImage() {
            onImagePaste?(image)
            return
        }
        super.paste(sender)
    }
}

private enum PasteboardImageReader {
    private static let supportedTypes: [(identifier: String, fileExtension: String)] = [
        ("public.png", "png"),
        ("public.jpeg", "jpg"),
        ("public.heic", "heic"),
        ("public.heif", "heif"),
        ("com.compuserve.gif", "gif"),
        ("public.tiff", "tiff"),
        ("org.webmproject.webp", "webp"),
    ]

    static func hasImage(in pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.hasImages
            || supportedTypes.contains { pasteboard.contains(pasteboardTypes: [$0.identifier]) }
    }

    static func readImage(from pasteboard: UIPasteboard = .general) -> ComposerPastedImage? {
        for type in supportedTypes {
            guard let data = pasteboard.data(forPasteboardType: type.identifier), !data.isEmpty else {
                continue
            }
            return ComposerPastedImage(data: data, fileExtension: type.fileExtension)
        }
        guard let data = pasteboard.image?.pngData(), !data.isEmpty else { return nil }
        return ComposerPastedImage(data: data, fileExtension: "png")
    }
}
