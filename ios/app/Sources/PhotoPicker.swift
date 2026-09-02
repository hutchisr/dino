import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Owns the complete attachment-selection lifecycle: provider loading, one
/// serialized background staging lane, cancellation, and generation checks.
/// Keeping this outside the picker coordinator lets an in-flight iCloud load
/// survive sheet dismissal while a newer selection can still retire it.
@MainActor
final class AttachmentSelectionPipeline: ObservableObject {
    @Published private(set) var isStaging = false

    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private let stagingQueue = DispatchQueue(
        label: "im.dino.Gecko.attachment-staging",
        qos: .userInitiated)
    private var generation: UInt64 = 0
    private var token: CancellationToken?
    private var providerProgress: Progress?
    private var onPicked: ((URL) -> Void)?
    private var onTooLarge: (() -> Void)?
    private var onError: ((String) -> Void)?

    func pick(
        _ result: PHPickerResult,
        allowsVideos: Bool,
        onPicked: @escaping (URL) -> Void,
        onTooLarge: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        let operation = begin(
            onPicked: onPicked,
            onTooLarge: onTooLarge,
            onError: onError)
        let provider = result.itemProvider
        guard let typeIdentifier = MediaFileKind.preferredPickerTypeIdentifier(
            in: provider.registeredTypeIdentifiers,
            allowsVideos: allowsVideos
        ) else {
            finish(
                generation: operation.generation,
                result: .failure(PhotoPickerLoadError.unsupportedType))
            return
        }
        let preferredFilenameExtension = UTType(typeIdentifier)?.preferredFilenameExtension
        providerProgress = provider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { [weak self] url, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.finish(
                        generation: operation.generation,
                        result: .failure(PhotoPickerLoadError.provider(error.localizedDescription)))
                }
                return
            }
            guard let url else {
                Task { @MainActor in
                    self.finish(
                        generation: operation.generation,
                        result: .failure(PhotoPickerLoadError.missingURL))
                }
                return
            }

            // The provider owns this URL only until its callback returns. A
            // synchronous hop onto our private serial queue keeps that callback
            // alive for the complete copy without doing any work on MainActor.
            let result: Result<URL, Error> = self.stagingQueue.sync {
                Result {
                    try AttachmentStaging.stageCopyCancellable(
                        of: url,
                        preferredFilenameExtension: preferredFilenameExtension,
                        isCancelled: { operation.token.isCancelled })
                }
            }
            Task { @MainActor in
                self.finish(generation: operation.generation, result: result)
            }
        }
    }

    func stageImportedFile(
        _ url: URL,
        onPicked: @escaping (URL) -> Void,
        onTooLarge: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        let operation = begin(
            onPicked: onPicked,
            onTooLarge: onTooLarge,
            onError: onError)
        // Begin the scope before the importer callback returns, and relinquish
        // it only after the background copy has finished or been cancelled.
        let scoped = url.startAccessingSecurityScopedResource()
        stagingQueue.async { [weak self] in
            let result: Result<URL, Error> = Result {
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                return try AttachmentStaging.stageCopyCancellable(
                    of: url,
                    isCancelled: { operation.token.isCancelled })
            }
            Task { @MainActor in
                self?.finish(generation: operation.generation, result: result)
            }
        }
    }

    func stagePastedImage(
        _ image: ComposerPastedImage,
        onPicked: @escaping (URL) -> Void,
        onTooLarge: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        let operation = begin(
            onPicked: onPicked,
            onTooLarge: onTooLarge,
            onError: onError)
        stagingQueue.async { [weak self] in
            let result = Result {
                try AttachmentStaging.stagePastedImageCancellable(
                    image.data,
                    fileExtension: image.fileExtension,
                    isCancelled: { operation.token.isCancelled })
            }
            Task { @MainActor in
                self?.finish(generation: operation.generation, result: result)
            }
        }
    }

    func cancel() {
        generation &+= 1
        token?.cancel()
        providerProgress?.cancel()
        token = nil
        providerProgress = nil
        onPicked = nil
        onTooLarge = nil
        onError = nil
        isStaging = false
    }

    private func begin(
        onPicked: @escaping (URL) -> Void,
        onTooLarge: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) -> (generation: UInt64, token: CancellationToken) {
        cancel()
        let nextToken = CancellationToken()
        token = nextToken
        self.onPicked = onPicked
        self.onTooLarge = onTooLarge
        self.onError = onError
        isStaging = true
        return (generation, nextToken)
    }

    private func finish(generation: UInt64, result: Result<URL, Error>) {
        guard generation == self.generation else {
            if case .success(let url) = result {
                removeStaleCopy(url)
            }
            return
        }
        providerProgress = nil
        token = nil
        isStaging = false

        switch result {
        case .success(let url):
            onPicked?(url)
        case .failure(let error as CancellationError):
            _ = error
        case .failure(AttachmentStagingError.tooLarge):
            onTooLarge?()
        case .failure(let error):
            onError?(error.localizedDescription)
        }
        onPicked = nil
        onTooLarge = nil
        onError = nil
    }

    private func removeStaleCopy(_ url: URL) {
        stagingQueue.async {
            guard AttachmentStaging.isInTemporaryDirectory(url) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private enum PhotoPickerLoadError: LocalizedError {
        case provider(String)
        case missingURL
        case unsupportedType

        var errorDescription: String? {
            switch self {
            case .provider(let detail):
                return "Could not load this photo or video from your library. \(detail)"
            case .missingURL:
                return "The photo library did not provide a file to send."
            case .unsupportedType:
                return "This photo or video could not be loaded."
            }
        }
    }
}

/// PHPickerViewController wrapper. The SwiftUI PhotosPicker control does not
/// reliably present when used as a Menu item on device, so the picker is
/// shown from a sheet instead.
struct PhotoPicker: UIViewControllerRepresentable {
    let allowsVideos: Bool
    let pipeline: AttachmentSelectionPipeline
    let onPicked: (URL) -> Void
    let onTooLarge: () -> Void
    let onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = allowsVideos ? .any(of: [.images, .videos]) : .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let result = results.first else { return }
            parent.pipeline.pick(
                result,
                allowsVideos: parent.allowsVideos,
                onPicked: parent.onPicked,
                onTooLarge: parent.onTooLarge,
                onError: parent.onError)
        }
    }
}
