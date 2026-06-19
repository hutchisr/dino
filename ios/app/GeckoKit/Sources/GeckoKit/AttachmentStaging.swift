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

    static func temporaryCopyURL(
        for source: URL,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        id: UUID = UUID()
    ) -> URL {
        let name = source.lastPathComponent.isEmpty ? "File" : source.lastPathComponent
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
