import Foundation
import SkyBridgeRealtimeMedia

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    private struct MediaAdmissionLeaseRejection: Decodable {
        let code: String?
        let error: String?
        let reason: String?
        let rejectReason: String?
        let mediaTokenRequestGeneration: String?
        let mediaTokenGeneration: String?
        let mediaTokenExpectedGeneration: String?
        let mediaTokenExpectedPresent: Bool?
        let mediaTokenSessionPresent: Bool?
        let mediaTokenState: String?
        let mediaTokenRevokedReason: String?
        let serverBuildFingerprint: String?
    }

    nonisolated static func isMediaAdmissionTokenRefreshable(_ error: Error) -> Bool {
        guard case SignalServerClientCompat.ClientError.serverRejected(let status, let body) = error else {
            return false
        }
        guard !mediaLeaseBodyIndicatesSessionAuthorityLost(body) else {
            return false
        }
        let errorCode = mediaAdmissionLeaseErrorCode(from: body)
        if status == 401,
           errorCode == "media_admission_token_superseded"
            || errorCode == "media_admission_token_expired" {
            return true
        }
        return status == 429 && errorCode == "media_admission_token_lease_limit"
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
        switch mediaAdmissionLeaseErrorCode(from: body) {
        case "media_admission_token_superseded":
            return "superseded"
        case "media_admission_token_expired":
            return "expired"
        case "media_admission_token_lease_limit":
            return "leaseLimit"
        default:
            break
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
              let rejection = mediaAdmissionLeaseRejection(from: body) else {
            return nil
        }
        let request = rejection.mediaTokenRequestGeneration
            ?? rejection.mediaTokenGeneration
            ?? "-"
        let expected = rejection.mediaTokenExpectedGeneration ?? "-"
        let expectedPresent = rejection.mediaTokenExpectedPresent.map { $0 ? "true" : "false" } ?? "-"
        let sessionPresent = rejection.mediaTokenSessionPresent.map { $0 ? "true" : "false" } ?? "-"
        let state = rejection.mediaTokenState ?? "-"
        let revokedReason = rejection.mediaTokenRevokedReason ?? "-"
        let build = rejection.serverBuildFingerprint ?? "-"
        let rejectReason = rejection.rejectReason ?? "-"
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
        guard let rejection = mediaAdmissionLeaseRejection(from: body) else {
            return !looksLikeJSONObject(body)
                && (body.contains("session_inactive") || body.contains("missing_session"))
        }
        if rejection.mediaTokenSessionPresent == false {
            return true
        }
        if ["session_inactive", "missing_session"].contains(mediaAdmissionLeaseErrorCode(from: rejection)) {
            return true
        }
        if let rejectReason = rejection.rejectReason,
           ["missingRecord", "revoked", "activeExpired", "iceKilled", "remote_kill", "session_killed"].contains(rejectReason) {
            return true
        }
        if rejection.mediaTokenState?.caseInsensitiveCompare("revoked") == .orderedSame {
            return rejection.mediaTokenExpectedPresent != true || rejection.mediaTokenSessionPresent == false
        }
        return false
    }

    nonisolated private static func mediaAdmissionLeaseErrorCode(from body: String) -> String? {
        if let rejection = mediaAdmissionLeaseRejection(from: body) {
            return mediaAdmissionLeaseErrorCode(from: rejection)
        }
        guard !looksLikeJSONObject(body) else {
            return nil
        }
        if body.contains("media_admission_token_superseded") {
            return "media_admission_token_superseded"
        }
        if body.contains("media_admission_token_expired") {
            return "media_admission_token_expired"
        }
        if body.contains("media_admission_token_lease_limit") {
            return "media_admission_token_lease_limit"
        }
        if body.contains("session_inactive") {
            return "session_inactive"
        }
        if body.contains("missing_session") {
            return "missing_session"
        }
        return nil
    }

    nonisolated private static func mediaAdmissionLeaseErrorCode(
        from rejection: MediaAdmissionLeaseRejection
    ) -> String? {
        rejection.error ?? rejection.code ?? rejection.reason
    }

    nonisolated private static func mediaAdmissionLeaseRejection(from body: String) -> MediaAdmissionLeaseRejection? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeJSONObject(trimmed),
              let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(MediaAdmissionLeaseRejection.self, from: data)
    }

    nonisolated private static func looksLikeJSONObject(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
    }
}
