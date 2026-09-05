import Foundation
import UniformTypeIdentifiers

/// Classifies media filenames and selects representations from the photo picker.
///
/// Why the filename and not the MIME type: iOS ships no shared-mime-info
/// database, so GIO's content-type sniffing degrades to
/// `application/octet-stream` for most attachments. When that happens the
/// filename is the only signal left, so callers check the declared MIME type
/// first and fall back here.
enum MediaFileKind {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2",
    ]

    static func preferredPickerTypeIdentifier(
        in registeredTypeIdentifiers: [String],
        allowsVideos: Bool
    ) -> String? {
        if let gif = firstIdentifier(in: registeredTypeIdentifiers, conformingTo: .gif) {
            return gif
        }
        if let webP = firstIdentifier(in: registeredTypeIdentifiers, conformingTo: .webP) {
            return webP
        }
        if allowsVideos,
           let movie = firstIdentifier(
               in: registeredTypeIdentifiers,
               conformingTo: .movie
           ) {
            return movie
        }
        return firstIdentifier(in: registeredTypeIdentifiers, conformingTo: .image)
    }

    static func isImage(fileName: String) -> Bool {
        imageExtensions.contains(pathExtension(of: fileName))
    }

    static func isSVG(fileName: String) -> Bool {
        pathExtension(of: fileName) == "svg"
    }

    static func isVideo(fileName: String) -> Bool {
        videoExtensions.contains(pathExtension(of: fileName))
    }

    /// Empty for a name with no extension, so a bare name or a dotfile like
    /// `.gitignore` matches neither set.
    private static func pathExtension(of fileName: String) -> String {
        (fileName as NSString).pathExtension.lowercased()
    }

    private static func firstIdentifier(
        in identifiers: [String],
        conformingTo type: UTType
    ) -> String? {
        identifiers.first { identifier in
            UTType(identifier)?.conforms(to: type) ?? false
        }
    }
}
