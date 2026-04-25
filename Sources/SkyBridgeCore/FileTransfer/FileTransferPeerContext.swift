import Foundation

struct FileTransferPeerContext: Sendable, Equatable {
    let declaredSenderDeviceId: String?
    let endpointHostOrIP: String?
    let peerLabel: String?
    let transferId: String

    init(
        declaredSenderDeviceId: String?,
        endpointHostOrIP: String?,
        peerLabel: String?,
        transferId: String
    ) {
        self.declaredSenderDeviceId = declaredSenderDeviceId
        self.endpointHostOrIP = endpointHostOrIP
        self.peerLabel = peerLabel
        self.transferId = transferId
    }

    func updating(
        declaredSenderDeviceId: String? = nil,
        transferId: String? = nil
    ) -> Self {
        Self(
            declaredSenderDeviceId: declaredSenderDeviceId ?? self.declaredSenderDeviceId,
            endpointHostOrIP: endpointHostOrIP,
            peerLabel: peerLabel,
            transferId: transferId ?? self.transferId
        )
    }
}

public enum FileTransferReceiptWaitStage: String, Sendable, Equatable {
    case headerTimeout = "receipt_wait_header_timeout"
    case payloadTimeout = "receipt_wait_payload_timeout"
    case authFailed = "receipt_wait_auth_failed"
    case receiverRejected = "receipt_wait_receiver_rejected"
}

enum ClassicTransferCapability {
    static let classicResume = "classic_resume"

    static func supportsClassicResume(in capabilities: [String]) -> Bool {
        capabilities.contains { capability in
            capability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == classicResume
        }
    }
}
