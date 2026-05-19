import Foundation
import OSLog
import SkyBridgeProtocolCore

@MainActor
extension CrossNetworkConnectionManager {
    func writeConnectionCodeSnapshot(
        code: String,
        sessionID: String,
        expiresAt: Date?,
        leaseMode: ConnectionCodeLeaseMode,
        binding: ProtocolIdentityBinding
    ) {
        CrossNetworkConnectionCodeSnapshotStore.write(
            code: code,
            sessionID: sessionID,
            expiresAt: expiresAt,
            leaseModeRawValue: leaseMode.rawValue,
            binding: binding
        )
    }

    nonisolated static func removeConnectionCodeSnapshot() {
        CrossNetworkConnectionCodeSnapshotStore.remove()
    }

    func logQRCodeStage(_ operation: String, stage: String, sessionID: String? = nil) {
        CrossNetworkQRCodeLog.stage(operation: operation, stage: stage, sessionID: sessionID)
    }
}

private enum CrossNetworkQRCodeLog {
    private static let logger = Logger(subsystem: "com.skybridge.connection", category: "CrossNetwork")

    static func stage(operation: String, stage: String, sessionID: String?) {
        let sessionHint = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
        logger.info("📷 QR stage: operation=\(operation, privacy: .public) stage=\(stage, privacy: .public) session=\(sessionHint, privacy: .public)")
    }
}
