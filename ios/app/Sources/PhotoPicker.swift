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
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider else { return }
            guard let typeIdentifier = preferredTypeIdentifier(for: provider) else { return }
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [parent] url, _ in
                guard let url else { return }
                guard AttachmentStaging.canStageFile(
                    byteCount: AttachmentStaging.byteCount(at: url)
                ) else {
                    DispatchQueue.main.async { parent.onTooLarge() }
                    return
                }
                // the provider's URL is only valid inside this callback
                let dest = AttachmentStaging.temporaryCopyURL(for: url)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
                DispatchQueue.main.async {
                    parent.onPicked(dest)
                }
            }
        }

        private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
            let identifiers = provider.registeredTypeIdentifiers
            if parent.allowsVideos, let movie = identifiers.first(where: { identifier in
                UTType(identifier)?.conforms(to: .movie) ?? false
            }) {
                return movie
            }
            return identifiers.first(where: { identifier in
                UTType(identifier)?.conforms(to: .image) ?? false
            })
        }
    }
}
