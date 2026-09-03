import Foundation

public struct FileTransferProgress: Equatable, Sendable {
    public let transferredBytes: Int64
    public let totalBytes: Int64?

    public init(transferredBytes: Int64, totalBytes: Int64?) {
        self.transferredBytes = max(0, transferredBytes)
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    public var percentage: Int? {
        fractionCompleted.map { Int($0 * 100) }
    }

    public var statusText: String {
        percentage.map { "\($0)%" } ?? "Downloading…"
    }

    public var accessibilityValue: String {
        guard let totalBytes, totalBytes > 0, let percentage else {
            if transferredBytes == 0 { return "Downloading" }
            return "Downloading, \(Self.byteLabel(transferredBytes)) received"
        }
        let displayedTransferredBytes = min(transferredBytes, totalBytes)
        return "\(percentage) percent, \(Self.byteLabel(displayedTransferredBytes)) of \(Self.byteLabel(totalBytes))"
    }

    private static func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public struct FileTransferProgressEvent: Equatable, Sendable {
    public let conversationID: Int32
    public let itemID: Int32
    public let progress: FileTransferProgress

    public init?(dictionary: [String: Any]) {
        guard dictionary["type"] as? String == "file_progress",
              let conversationNumber = dictionary["conversation"] as? NSNumber,
              let conversationID = Int32(exactly: conversationNumber.int64Value),
              let itemNumber = dictionary["item"] as? NSNumber,
              let itemID = Int32(exactly: itemNumber.int64Value),
              let transferredNumber = dictionary["transferred_bytes"] as? NSNumber
        else {
            return nil
        }

        let totalBytes = (dictionary["total_bytes"] as? NSNumber)?.int64Value
        self.conversationID = conversationID
        self.itemID = itemID
        self.progress = FileTransferProgress(
            transferredBytes: transferredNumber.int64Value,
            totalBytes: totalBytes
        )
    }
}
