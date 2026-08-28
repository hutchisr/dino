import Foundation

enum AttachmentStaging {
    static let maxByteCount: Int64 = 512 * 1024 * 1024

    static func byteCount(at url: URL) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    static func canStageFile(byteCount: Int64?, maxByteCount: Int64 = Self.maxByteCount) -> Bool {
        guard let byteCount else { return true }
        return byteCount >= 0 && byteCount <= maxByteCount
    }

    static func tooLargeMessage(noun: String) -> String {
        let limit = ByteCountFormatter.string(fromByteCount: maxByteCount, countStyle: .file)
        return "This \(noun) is too large to send. The local staging limit is \(limit)."
    }

    static func temporaryCopyURL(
        for source: URL,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        id: UUID = UUID()
    ) -> URL {
        let name = source.lastPathComponent.isEmpty ? "File" : source.lastPathComponent
        return temporaryDirectory.appendingPathComponent("\(id.uuidString)-\(name)")
    }

    /// Copies `source` into the temporary directory and returns the copy, or
    /// nil when the copy fails.
    ///
    /// Why copy at all: the URLs the pickers hand us are borrowed. A
    /// `PHPickerResult` file representation is deleted as soon as its callback
    /// returns, and a `fileImporter` URL is only readable while its
    /// security-scoped access is held. Sending is asynchronous and outlives
    /// both, so staging our own copy is what keeps the bytes alive until the
    /// send completes.
    static func stageCopy(of source: URL) -> URL? {
        let dest = temporaryCopyURL(for: source)
        // A UUID-prefixed name makes a collision practically impossible, but
        // clear the destination anyway so copyItem cannot fail on leftovers.
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: source, to: dest)) != nil else { return nil }
        return dest
    }

    static func temporaryPastedImageURL(
        fileExtension: String,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        id: UUID = UUID()
    ) -> URL {
        let trimmedExtension = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
        let name = trimmedExtension.isEmpty ? "Pasted Image" : "Pasted Image.\(trimmedExtension)"
        return temporaryDirectory.appendingPathComponent("\(id.uuidString)-\(name)")
    }

    static func isInTemporaryDirectory(
        _ url: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let path = url.standardizedFileURL.path
        var tempPath = temporaryDirectory.standardizedFileURL.path
        if !tempPath.hasSuffix("/") { tempPath += "/" }
        return path.hasPrefix(tempPath)
    }
}
