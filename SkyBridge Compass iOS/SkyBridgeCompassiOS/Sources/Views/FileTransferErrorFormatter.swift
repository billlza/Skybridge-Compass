import Foundation
import enum SkyBridgeProtocolCore.ClassicTransferApprovalError

/// Presentation only: preserve typed protocol failures and keep unknown error details intact.
enum FileTransferErrorFormatter {
    static func localizedMessage(
        for error: Error,
        localize: (String) -> String = { RuntimeLocalization.string($0) }
    ) -> String {
        guard let approvalError = error as? ClassicTransferApprovalError else {
            return error.localizedDescription
        }
        let key: String
        switch approvalError {
        case .refused(.denied):
            key = "fileTransfer.error.approvalDenied"
        case .refused(.unavailable):
            key = "fileTransfer.error.receiverUnavailable"
        case .capabilityEvidenceUnavailable:
            key = "fileTransfer.error.capabilitiesNotReady"
        case .invalidSessionBinding:
            key = "fileTransfer.error.sessionNotReady"
        case .unsupportedProtocol:
            key = "fileTransfer.error.approvalProtocolUnsupported"
        case .invalidResponse:
            key = "fileTransfer.error.approvalResponseInvalid"
        case .requestMismatch:
            key = "fileTransfer.error.approvalRequestMismatch"
        case .authenticationFailed:
            key = "fileTransfer.error.approvalAuthenticationFailed"
        }
        return localize(key)
    }
}
