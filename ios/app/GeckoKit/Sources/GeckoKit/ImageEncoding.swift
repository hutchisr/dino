import Foundation

#if canImport(UIKit)
import UIKit

/// gdk-pixbuf on iOS ships only the built-in PNG loader, so re-encode any picked
/// image (JPEG/HEIC/…) to a PNG temp file before handing its path to the bridge
/// for avatar publishing. Returns nil if the image can't be read or written.
///
/// UIKit-only, so it's excluded from the host `swift test` build; the iOS
/// Simulator test run (`xcodebuild test`) exercises it.
func avatarPNG(from path: String) -> String? {
    guard let image = UIImage(contentsOfFile: path), let data = image.pngData() else { return nil }
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    do {
        try data.write(to: dest)
        return dest.path
    } catch {
        return nil
    }
}
#endif
