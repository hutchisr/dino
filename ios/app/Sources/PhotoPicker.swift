import SwiftUI
import PhotosUI

/// PHPickerViewController wrapper. The SwiftUI PhotosPicker control does not
/// reliably present when used as a Menu item on device, so the picker is
/// shown from a sheet instead.
struct PhotoPicker: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
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
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [parent] url, _ in
                guard let url else { return }
                // the provider's URL is only valid inside this callback
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
                DispatchQueue.main.async {
                    parent.onPicked(dest)
                }
            }
        }
    }
}
