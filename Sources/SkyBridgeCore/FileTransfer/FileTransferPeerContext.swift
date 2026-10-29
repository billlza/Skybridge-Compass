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
    static let classicResume = BonjourInteropContract.classicResumeCapability

    static func supportsClassicResume(in capabilities: [String]) -> Bool {
        capabilities.contains { capability in
            capability.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == classicResume
        }
    }

    static func normalizedRemoteCapabilities(
        _ advertisedCapabilities: [String]?,
        fileTransferPort: UInt16?,
        remoteControlPort: UInt16?
    ) -> [String] {
        var capabilities = advertisedCapabilities ?? []

        func containsAssignment(for normalizedKey: String) -> Bool {
            capabilities.contains { capability in
                let key = capability.split(separator: "=", maxSplits: 1).first.map(String.init) ?? capability
                let normalized = key
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber }
                return normalized == normalizedKey
            }
        }

        if let fileTransferPort, fileTransferPort > 0,
           !containsAssignment(for: "filetransferport") {
            capabilities.append("fileTransferPort=\(fileTransferPort)")
        }
        if let remoteControlPort, remoteControlPort > 0,
           !containsAssignment(for: "remotecontrolport") {
            capabilities.append("remoteControlPort=\(remoteControlPort)")
        }

        // Remote feature support is authoritative. In particular, never
        // synthesize classic_resume for a peer that did not advertise it.
        return capabilities
    }
}
