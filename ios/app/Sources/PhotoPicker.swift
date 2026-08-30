import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// PHPickerViewController wrapper. The SwiftUI PhotosPicker control does not
/// reliably present when used as a Menu item on device, so the picker is
/// shown from a sheet instead.
struct PhotoPicker: UIViewControllerRepresentable {
    let allowsVideos: Bool
    let onPicked: (URL) -> Void
    let onTooLarge: () -> Void
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

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider else { return }
            guard let typeIdentifier = MediaFileKind.preferredPickerTypeIdentifier(
                in: provider.registeredTypeIdentifiers,
                allowsVideos: parent.allowsVideos
            ) else { return }
            let preferredFilenameExtension = UTType(typeIdentifier)?.preferredFilenameExtension
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [parent] url, _ in
                guard let url else { return }
                guard AttachmentStaging.canStageFile(
                    byteCount: AttachmentStaging.byteCount(at: url)
                ) else {
                    DispatchQueue.main.async { parent.onTooLarge() }
                    return
                }
                // the provider's URL is only valid inside this callback
                guard let dest = AttachmentStaging.stageCopy(
                    of: url,
                    preferredFilenameExtension: preferredFilenameExtension
                ) else { return }
                DispatchQueue.main.async {
                    parent.onPicked(dest)
                }
            }
        }

    }
}
