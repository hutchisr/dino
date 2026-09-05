import SwiftUI

struct FileTransferProgressIndicator: View {
    @ObservedObject var state: FileTransferProgressState
    let operation: FileTransferOperation

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let fraction = state.value.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .frame(width: 96)

            Text(state.value.statusText(for: operation))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 76, alignment: .trailing)
        }
        .frame(minHeight: 16)
    }
}

struct FileTransferProgressRow: View {
    @ObservedObject var state: FileTransferProgressState
    let fileName: String
    let operation: FileTransferOperation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: operation == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.title3)
            VStack(alignment: .leading) {
                Text(fileName)
                    .lineLimit(1)
                FileTransferProgressIndicator(state: state, operation: operation)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(operation == .upload ? "Uploading" : "Downloading") \(fileName)")
        .accessibilityValue(state.value.accessibilityValue(for: operation))
    }
}
