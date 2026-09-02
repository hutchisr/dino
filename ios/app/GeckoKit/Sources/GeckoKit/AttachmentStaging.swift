import Foundation

enum AttachmentStagingError: LocalizedError, Equatable {
    case tooLarge
    case copyFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            return AttachmentStaging.tooLargeMessage(noun: "file")
        case .copyFailed:
            return "Could not copy this file for sending."
        case .writeFailed:
            return "Could not prepare this image for sending."
        }
    }
}


enum AttachmentStaging {
    static let maxByteCount: Int64 = 512 * 1024 * 1024

    static func stageCopyCancellable(
        of source: URL,
        preferredFilenameExtension: String? = nil,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        maxByteCount: Int64 = Self.maxByteCount,
        copyChunkByteCount: Int = 1024 * 1024,
        isCancelled: () -> Bool
    ) throws -> URL {
        try checkCancellation(isCancelled)
        guard canStageFile(
            byteCount: byteCount(at: source),
            maxByteCount: maxByteCount
        ) else {
            throw AttachmentStagingError.tooLarge
        }

        let destination = temporaryCopyURL(
            for: source,
            preferredFilenameExtension: preferredFilenameExtension,
            in: temporaryDirectory)
        do {
            try copy(
                source,
                to: destination,
                chunkByteCount: max(1, copyChunkByteCount),
                isCancelled: isCancelled)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func stagePastedImageCancellable(
        _ data: Data,
        fileExtension: String,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        maxByteCount: Int64 = Self.maxByteCount,
        isCancelled: () -> Bool
    ) throws -> URL {
        try checkCancellation(isCancelled)
        guard canStageFile(
            byteCount: Int64(data.count),
            maxByteCount: maxByteCount
        ) else {
            throw AttachmentStagingError.tooLarge
        }

        let destination = temporaryPastedImageURL(
            fileExtension: fileExtension,
            in: temporaryDirectory)
        do {
            try data.write(to: destination, options: .atomic)
            try checkCancellation(isCancelled)
            return destination
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw AttachmentStagingError.writeFailed
        }
    }

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
        preferredFilenameExtension: String? = nil,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        id: UUID = UUID()
    ) -> URL {
        let sourceName = source.lastPathComponent.isEmpty ? "File" : source.lastPathComponent
        let fileExtension = normalizedFileExtension(preferredFilenameExtension)
        let name: String
        if fileExtension.isEmpty {
            name = sourceName
        } else {
            let stem = (sourceName as NSString).deletingPathExtension
            name = "\(stem.isEmpty ? "File" : stem).\(fileExtension)"
        }
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
    static func stageCopy(
        of source: URL,
        preferredFilenameExtension: String? = nil
    ) -> URL? {
        let dest = temporaryCopyURL(
            for: source,
            preferredFilenameExtension: preferredFilenameExtension)
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
        let trimmedExtension = normalizedFileExtension(fileExtension)
        let name = trimmedExtension.isEmpty ? "Pasted Image" : "Pasted Image.\(trimmedExtension)"
        return temporaryDirectory.appendingPathComponent("\(id.uuidString)-\(name)")
    }

    private static func normalizedFileExtension(_ fileExtension: String?) -> String {
        (fileExtension ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
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

    private static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }

    private static func copy(
        _ source: URL,
        to destination: URL,
        chunkByteCount: Int,
        isCancelled: () -> Bool
    ) throws {
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil
        ) else {
            throw AttachmentStagingError.copyFailed
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }

            while true {
                try checkCancellation(isCancelled)
                guard let chunk = try input.read(upToCount: chunkByteCount),
                      !chunk.isEmpty else {
                    break
                }
                try output.write(contentsOf: chunk)
            }
            try checkCancellation(isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AttachmentStagingError.copyFailed
        }
    }
}
