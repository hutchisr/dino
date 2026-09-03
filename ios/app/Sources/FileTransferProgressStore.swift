import Combine
import Foundation

struct FileTransferProgressKey: Hashable {
    let conversation: Int32
    let item: Int32
}

@MainActor
final class FileTransferProgressState: ObservableObject {
    @Published private(set) var value: FileTransferProgress

    init(_ value: FileTransferProgress) {
        self.value = value
    }

    func update(_ value: FileTransferProgress) {
        guard self.value != value else { return }
        self.value = value
    }
}

@MainActor
final class FileTransferProgressStore {
    private var states: [FileTransferProgressKey: FileTransferProgressState] = [:]

    func state(for key: FileTransferProgressKey) -> FileTransferProgressState? {
        states[key]
    }

    func begin(_ key: FileTransferProgressKey, totalBytes: Int64?) {
        let value = FileTransferProgress(transferredBytes: 0, totalBytes: totalBytes)
        if let state = states[key] {
            state.update(value)
        } else {
            states[key] = FileTransferProgressState(value)
        }
    }

    func update(_ key: FileTransferProgressKey, transferredBytes: Int64, totalBytes: Int64?) {
        let value = FileTransferProgress(
            transferredBytes: transferredBytes,
            totalBytes: totalBytes
        )
        if let state = states[key] {
            state.update(value)
        } else {
            states[key] = FileTransferProgressState(value)
        }
    }

    func remove(_ key: FileTransferProgressKey) {
        states[key] = nil
    }

    func removeAll(in conversation: Int32) {
        states = states.filter { $0.key.conversation != conversation }
    }

    func removeAll() {
        states.removeAll()
    }
}
