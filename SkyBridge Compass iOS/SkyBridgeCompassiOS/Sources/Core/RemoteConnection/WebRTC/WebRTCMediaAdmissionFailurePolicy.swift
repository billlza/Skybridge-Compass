import Foundation
import SkyBridgeRealtimeMedia

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    static func isMediaAdmissionTokenRefreshable(_ error: Error) -> Bool {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            return false
        }
        guard !mediaLeaseBodyIndicatesSessionAuthorityLost(body) else {
            return false
        }
        if status == 401 && (
            body.contains("media_admission_token_superseded")
                || body.contains("media_admission_token_expired")
        ) {
            return true
        }
        return status == 429 && body.contains("media_admission_token_lease_limit")
    }

    static func isUsableMediaRelayEndpoint(_ endpoint: SkyBridgeMediaEndpoint, now: Date = Date()) -> Bool {
        guard let expiresAt = endpoint.expiresAt else { return true }
        return expiresAt - now.timeIntervalSince1970 > 10
    }

    nonisolated static func mediaRelayLeaseFailureReason(for error: Error) -> String {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            return "leaseRejected"
        }
        if mediaLeaseBodyIndicatesSessionAuthorityLost(body) {
            return "sessionAuthorityLost"
        }
        if body.contains("media_admission_token_superseded") {
            return "superseded"
        }
        if body.contains("media_admission_token_expired") {
            return "expired"
        }
        if body.contains("media_admission_token_lease_limit") {
            return "leaseLimit"
        }
        if body.contains("missing_session") || body.contains("session_inactive") {
            return "sessionAuthorityLost"
        }
        if status == 503 || body.contains("relay") {
            return "relayUnavailable"
        }
        return "leaseRejected"
    }

    nonisolated static func mediaRelayLeaseFailureReasonAfterRefresh(for error: Error) -> String {
        let reason = mediaRelayLeaseFailureReason(for: error)
        return reason == "superseded" ? "serverStateMismatch" : reason
    }

    nonisolated static func mediaTokenDiagnosticSummary(for error: Error) -> String? {
        guard case SignalServerClientCompat.ClientError.serverRejected(_, let body) = error,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let request = object["mediaTokenRequestGeneration"] as? String
            ?? object["mediaTokenGeneration"] as? String
            ?? "-"
        let expected = object["mediaTokenExpectedGeneration"] as? String ?? "-"
        let expectedPresent: String = {
            if let bool = object["mediaTokenExpectedPresent"] as? Bool {
                return bool ? "true" : "false"
            }
            return "-"
        }()
        let sessionPresent: String = {
            if let bool = object["mediaTokenSessionPresent"] as? Bool {
                return bool ? "true" : "false"
            }
            return "-"
        }()
        let state = object["mediaTokenState"] as? String ?? "-"
        let revokedReason = object["mediaTokenRevokedReason"] as? String ?? "-"
        let build = object["serverBuildFingerprint"] as? String ?? "-"
        let rejectReason = object["rejectReason"] as? String ?? "-"
        return "requestGeneration=\(request) expectedGeneration=\(expected) expectedPresent=\(expectedPresent) sessionPresent=\(sessionPresent) tokenState=\(state) tokenRevokedReason=\(revokedReason) rejectReason=\(rejectReason) serverBuild=\(build)"
    }

    nonisolated static func mediaAdmissionRefreshFailureReason(for error: Error) -> String {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            return "refreshFailed"
        }
        if status == 404 || body.contains("Cannot POST /api/media/admission/refresh") {
            return "serverRefreshUnsupported"
        }
        if body.contains("session_token_superseded") {
            return "sessionTokenSuperseded"
        }
        if body.contains("session_token_expired") {
            return "sessionTokenExpired"
        }
        if body.contains("missing_session_token") {
            return "missingSessionToken"
        }
        if body.contains("missing_session") || body.contains("session_inactive") {
            return "sessionAuthorityLost"
        }
        if status == 503 {
            return "relayUnavailable"
        }
        return "refreshFailed"
    }

    nonisolated static func sessionRefreshFailureReason(for error: Error) -> String {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            let description = (error as NSError).localizedDescription
            if description == "missingRole" {
                return "missingRole"
            }
            return "sessionReauthFailed"
        }
        if status == 404 || body.contains("Cannot POST /api/webrtc/session/refresh") {
            return "serverUnsupported"
        }
        if body.contains("missing_session") || body.contains("session_inactive") {
            return "sessionAuthorityLost"
        }
        if body.contains("session_scope_mismatch") || body.contains("scope") || status == 403 {
            return "scopeMismatch"
        }
        if status == 503 {
            return "serverUnavailable"
        }
        return "sessionReauthFailed"
    }

    nonisolated static func isSessionAuthorityLostReason(_ reason: String) -> Bool {
        reason == "sessionAuthorityLost"
    }

    nonisolated static func mediaLeaseBodyIndicatesSessionAuthorityLost(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.contains("session_inactive") || body.contains("missing_session")
        }
        if let present = object["mediaTokenSessionPresent"] as? Bool, present == false {
            return true
        }
        if let error = object["error"] as? String,
           error == "session_inactive" || error == "missing_session" {
            return true
        }
        if let rejectReason = object["rejectReason"] as? String,
           ["missingRecord", "revoked", "activeExpired", "iceKilled", "remote_kill", "session_killed"].contains(rejectReason) {
            return true
        }
        if let state = object["mediaTokenState"] as? String,
           state.caseInsensitiveCompare("revoked") == .orderedSame {
            let expectedPresent = object["mediaTokenExpectedPresent"] as? Bool
            let sessionPresent = object["mediaTokenSessionPresent"] as? Bool
            return expectedPresent != true || sessionPresent == false
        }
        return false
    }
}
