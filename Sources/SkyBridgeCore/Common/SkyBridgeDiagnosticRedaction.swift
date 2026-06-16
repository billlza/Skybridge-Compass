import Foundation
import SkyBridgeProtocolCore

enum SkyBridgeDiagnosticRedaction {
    static let redacted = "<redacted>"

    static func stableIdentifierLabel(_ rawIdentifier: String?) -> String {
        guard rawIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return redacted
        }
        return redacted
    }

    static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "error_domain=\(nsError.domain) code=\(nsError.code)"
    }
}

extension HandshakeFailureReason {
    var diagnosticReasonCode: String {
        switch self {
        case .timeout:
            return "timeout"
        case .peerRejected:
            return "peer_rejected"
        case .cryptoError:
            return "crypto_error"
        case .transportError:
            return "transport_error"
        case .cancelled:
            return "cancelled"
        case .versionMismatch(let local, let remote):
            return "version_mismatch local=\(local) remote=\(remote)"
        case .suiteNegotiationFailed:
            return "suite_negotiation_failed"
        case .signatureVerificationFailed:
            return "signature_verification_failed"
        case .invalidMessageFormat:
            return "invalid_message_format"
        case .identityMismatch:
            return "identity_mismatch"
        case .replayDetected:
            return "replay_detected"
        case .secureEnclavePoPRequired:
            return "secure_enclave_pop_required"
        case .secureEnclaveSignatureInvalid:
            return "secure_enclave_signature_invalid"
        case .keyConfirmationFailed:
            return "key_confirmation_failed"
        case .suiteSignatureMismatch(let selectedSuite, let sigAAlgorithm):
            return "suite_signature_mismatch suite=\(selectedSuite) sigA=\(sigAAlgorithm)"
        case .pqcProviderUnavailable:
            return "pqc_provider_unavailable"
        case .suiteNotSupported:
            return "suite_not_supported"
        case .supersededByConcurrentAttempt:
            return "superseded_by_concurrent_attempt"
        }
    }
}

extension HandshakeState {
    var diagnosticSummary: String {
        switch self {
        case .idle:
            return "idle"
        case .sendingMessageA:
            return "sendingMessageA"
        case .waitingMessageB:
            return "waitingMessageB"
        case .processingMessageB(let epoch):
            return "processingMessageB epoch=\(epoch)"
        case .processingMessageA:
            return "processingMessageA"
        case .sendingMessageB:
            return "sendingMessageB"
        case .waitingFinished(_, let sessionKeys, let expectingFrom):
            return "waitingFinished suite=\(sessionKeys.negotiatedSuite.rawValue) expectingFrom=\(expectingFrom.rawValue)"
        case .established(let sessionKeys):
            return "established suite=\(sessionKeys.negotiatedSuite.rawValue)"
        case .failed(let reason):
            return "failed reason=\(reason.diagnosticReasonCode)"
        }
    }
}
