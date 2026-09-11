import SwiftUI
import UIKit

struct ComposerPastedImage {
    let data: Data
    let fileExtension: String
}

struct PasteAwareComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let maxLines: Int
    let minimumHeight: CGFloat
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let verticalAlignmentOffset: CGFloat
    let canPasteImages: Bool
    let onImagePaste: (ComposerPastedImage) -> Void
#if targetEnvironment(macCatalyst)
    let autofocusID: Int32
    let onSubmit: () -> Void
#endif

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
        view.textContainerInset = textContainerInset
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
#if targetEnvironment(macCatalyst)
        view.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.handleSubmit()
        }
        view.requestAutofocus(for: autofocusID)
#endif
        return view
    }

    func updateUIView(_ uiView: PasteAwareTextView, context: Context) {
        context.coordinator.parent = self
        uiView.canPasteImages = canPasteImages
        let inset = textContainerInset
        if uiView.textContainerInset != inset {
            uiView.textContainerInset = inset
            uiView.invalidateIntrinsicContentSize()
        }
        if uiView.text != text {
            uiView.text = text
            uiView.invalidateIntrinsicContentSize()
        }
        updateScrolling(uiView)
#if targetEnvironment(macCatalyst)
        uiView.requestAutofocus(for: autofocusID)
#endif
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

    private var textContainerInset: UIEdgeInsets {
        UIEdgeInsets(
            top: verticalInset + verticalAlignmentOffset,
            left: horizontalInset,
            bottom: max(0, verticalInset - verticalAlignmentOffset),
            right: horizontalInset
        )
    }

    private func minTextHeight(_ uiView: UITextView) -> CGFloat {
        let lineHeight = (uiView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let contentHeight = ceil(lineHeight + uiView.textContainerInset.top + uiView.textContainerInset.bottom)
        return max(minimumHeight, contentHeight)
    }

    private func maxTextHeight(_ uiView: UITextView) -> CGFloat {
        let lineHeight = (uiView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let contentHeight = ceil(
            lineHeight * CGFloat(max(maxLines, 1))
                + uiView.textContainerInset.top
                + uiView.textContainerInset.bottom
        )
        return max(minimumHeight, contentHeight)
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
#if targetEnvironment(macCatalyst)
        func handleSubmit() {
            parent.onSubmit()
        }
#endif
    }
}

final class PasteAwareTextView: UITextView {
    var canPasteImages = true
    var onImagePaste: ((ComposerPastedImage) -> Void)?
#if targetEnvironment(macCatalyst)
    var onSubmit: (() -> Void)?
    private var autofocusID: Int32?
    private var scheduledAutofocusID: Int32?
    private var completedAutofocusID: Int32?
    private var autofocusAttempts = 0

    /// Re-arm autofocus when SwiftUI reuses this native view for another chat.
    /// A temporarily rejected responder request gets two bounded retries.
    func requestAutofocus(for id: Int32) {
        if autofocusID != id {
            autofocusID = id
            completedAutofocusID = nil
            autofocusAttempts = 0
        }
        scheduleAutofocus()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, completedAutofocusID != autofocusID {
            autofocusAttempts = 0
        }
        scheduleAutofocus()
    }

    private func scheduleAutofocus() {
        guard window != nil,
              autofocusAttempts < 3,
              let autofocusID,
              completedAutofocusID != autofocusID,
              scheduledAutofocusID != autofocusID else { return }
        scheduledAutofocusID = autofocusID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.scheduledAutofocusID == autofocusID {
                self.scheduledAutofocusID = nil
            }
            guard self.window != nil, self.autofocusID == autofocusID else { return }
            self.autofocusAttempts += 1
            let focused = self.becomeFirstResponder()
            if focused {
                self.completedAutofocusID = autofocusID
            } else if self.autofocusAttempts < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard self?.autofocusID == autofocusID else { return }
                    self?.scheduleAutofocus()
                }
            }
            geckoDebugLog(
                "gecko-composer: Catalyst autofocus=%d attempt=%d",
                focused ? 1 : 0,
                self.autofocusAttempts)
        }
    }

    private lazy var submitKeyCommand: UIKeyCommand = {
        let command = UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(submitFromKeyboard(_:))
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }()

    private lazy var newlineKeyCommand: UIKeyCommand = {
        let command = UIKeyCommand(
            input: "\r",
            modifierFlags: .shift,
            action: #selector(insertNewlineFromKeyboard(_:))
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }()

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [newlineKeyCommand, submitKeyCommand]
    }

    @objc private func submitFromKeyboard(_: UIKeyCommand) {
        onSubmit?()
    }

    @objc private func insertNewlineFromKeyboard(_: UIKeyCommand) {
        insertText("\n")
    }
#endif

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
