import SwiftUI
import SkyBridgeCore

public struct FileTransferRow: View {
    let transfer: FileTransferTask

    public init(transfer: FileTransferTask) {
        self.transfer = transfer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(transfer.fileName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(transfer.progress.formatted(.percent.precision(.fractionLength(1))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: transfer.progress)
                .tint(.purple)
            Text("\(LocalizationManager.shared.localizedString("dashboard.transfer.speed")): \(transfer.throughputMbps, specifier: "%.2f") Mbps · \(LocalizationManager.shared.localizedString("dashboard.transfer.remaining")): \(transfer.remainingTimeDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

