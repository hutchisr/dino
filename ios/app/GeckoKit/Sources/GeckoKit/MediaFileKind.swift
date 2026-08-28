import Foundation

/// Classifies an attachment as image or video from its filename extension.
///
/// Why the filename and not the MIME type: iOS ships no shared-mime-info
/// database, so GIO's content-type sniffing degrades to
/// `application/octet-stream` for most attachments. When that happens the
/// filename is the only signal left, so callers check the declared MIME type
/// first and fall back here.
enum MediaFileKind {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2",
    ]

    static func isImage(fileName: String) -> Bool {
        imageExtensions.contains(pathExtension(of: fileName))
    }

    static func isVideo(fileName: String) -> Bool {
        videoExtensions.contains(pathExtension(of: fileName))
    }

    /// Empty for a name with no extension, so a bare name or a dotfile like
    /// `.gitignore` matches neither set.
    private static func pathExtension(of fileName: String) -> String {
        (fileName as NSString).pathExtension.lowercased()
    }
}
