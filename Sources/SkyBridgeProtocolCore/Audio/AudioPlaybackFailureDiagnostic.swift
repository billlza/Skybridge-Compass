import Foundation

/// Closed local diagnostic codes. Never include credentials, identities or server error bodies.
public enum AudioPlaybackFailureDiagnostic {
    public static func label(for error: Error) -> String {
        if let channel = error as? AudioStreamingChannelError {
            let code: String
            switch channel {
            case .unavailable: code = "unavailable"
            case .staleOwner: code = "stale_owner"
            case .alreadyRegistered: code = "already_registered"
            case .closed: code = "closed"
            case .queueOverflow: code = "queue_overflow"
            case .unsupportedPeer: code = "unsupported_peer"
            case .unexpectedStream: code = "unexpected_stream"
            case .offerRequired: code = "offer_required"
            case .duplicateConsumer: code = "duplicate_consumer"
            case .epochCapacity: code = "epoch_capacity"
            case .sendInProgress: code = "send_in_progress"
            case .timedOut: code = "timed_out"
            case .fileTransferMismatch: code = "file_transfer_mismatch"
            case .peerStopped: code = "peer_stopped"
            }
            return "channel." + code
        }
        if let membership = error as? AudioMembershipError {
            let code: String
            switch membership {
            case .invalidIdentity: code = "invalid_identity"
            case .invalidScope: code = "invalid_scope"
            case .invalidTime: code = "invalid_time"
            case .staleResponse: code = "stale_response"
            case .incompleteList: code = "incomplete_list"
            case .callerNotActive: code = "caller_not_active"
            case .peerNotActive: code = "peer_not_active"
            case .selfPlayback: code = "self_playback"
            case .scopeMismatch: code = "scope_mismatch"
            case .expired: code = "expired"
            case .clockMovedBackwards: code = "clock_moved_backwards"
            }
            return "membership." + code
        }
        if let lease = error as? AudioMembershipLeaseFailure {
            switch lease {
            case .revoked: return "lease.revoked"
            case .accountChanged: return "lease.account_changed"
            case .peerChanged: return "lease.peer_changed"
            case .expired: return "lease.expired"
            case .clockMovedBackwards: return "lease.clock_moved_backwards"
            }
        }
        if let provider = error as? AudioAccountProviderError {
            switch provider {
            case .requestInProgress: return "provider.request_in_progress"
            case .capacity: return "provider.capacity"
            case .contradicted: return "provider.contradicted"
            }
        }
        // Core Bluetooth delegates return NSError. Preserve its bounded system
        // category/code so native connection failures remain diagnosable, without
        // importing a platform framework into the protocol layer or logging
        // userInfo, descriptions, arbitrary domains, or nested server errors.
        let native = error as NSError
        switch native.domain {
        case "CBErrorDomain": return "bluetooth.cb.\(native.code)"
        case "CBATTErrorDomain": return "bluetooth.att.\(native.code)"
        default: break
        }
        return "type." + String(reflecting: type(of: error))
    }
}
