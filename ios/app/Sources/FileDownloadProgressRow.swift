import SwiftUI

struct FileDownloadProgressRow: View {
    @ObservedObject var state: FileTransferProgressState
    let fileName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.title3)
            VStack(alignment: .leading) {
                Text(fileName)
                    .lineLimit(1)
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

                    Text(state.value.statusText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 76, alignment: .trailing)
                }
                .frame(minHeight: 16)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading \(fileName)")
        .accessibilityValue(state.value.accessibilityValue)
    }
}
