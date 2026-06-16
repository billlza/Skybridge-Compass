import Foundation
import SkyBridgeAppleTransport
import SkyBridgeRealtimeMedia

struct WebRTCMediaAdmissionClassifiedFailure: LocalizedError, Sendable {
    let reason: String
    let underlyingDescription: String

    init(reason: String, underlying: Error) {
        self.reason = reason
        self.underlyingDescription = underlying.localizedDescription
    }

    var errorDescription: String? {
        reason
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension CrossNetworkConnectionManager {
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

    nonisolated static func mediaRelayEndpoint(from lease: SignalServerClient.MediaRelayLease) -> SkyBridgeMediaEndpoint {
        SkyBridgeMediaEndpoint(
            host: lease.endpointHost,
            port: lease.endpointPort,
            relayToken: lease.leaseToken,
            expiresAt: lease.expiresAt
        )
    }

    nonisolated static func isMediaAdmissionLeaseRefreshable(_ error: Error) -> Bool {
        guard case SignalServerClient.ClientError.serverRejected(let status, let body) = error else {
            return false
        }
        guard !mediaLeaseBodyIndicatesSessionAuthorityLost(body) else {
            return false
        }
        let errorCode = mediaAdmissionLeaseErrorCode(from: body)
        if status == 401 {
            return errorCode == "media_admission_token_superseded"
                || errorCode == "media_admission_token_expired"
        }
        return status == 429 && errorCode == "media_admission_token_lease_limit"
    }

    nonisolated static func mediaAdmissionFailureReason(for error: Error) -> String {
        if let transportError = error as? SkyBridgeRealtimeMediaTransportError {
            switch transportError {
            case .udpConnectionReadyTimedOut:
                return "udpConnectionReadyTimedOut"
            case .relayBindTimedOut:
                return "relayBindTimedOut"
            case .relayBindRejected:
                return "relayBindRejected"
            case .relayBindMalformed:
                return "relayBindMalformed"
            }
        }
        if let classifiedFailure = error as? WebRTCMediaAdmissionClassifiedFailure {
            return classifiedFailure.reason
        }
        guard case SignalServerClient.ClientError.serverRejected(let status, let body) = error else {
            return "relayUnavailable"
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
        if status == 404 || body.contains("Cannot POST /api/media/admission/refresh") { return "serverRefreshUnsupported" }
        if status == 503 { return "relayUnavailable" }
        return "leaseRejected"
    }

    nonisolated static func mediaAdmissionFailureReasonAfterRefresh(for error: Error) -> String {
        let reason = mediaAdmissionFailureReason(for: error)
        return reason == "superseded" ? "serverStateMismatch" : reason
    }

    nonisolated static func mediaTokenDiagnosticSummary(for error: Error) -> String? {
        guard case SignalServerClient.ClientError.serverRejected(_, let body) = error,
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

    nonisolated static func strictRealtimeAudioAttachRetryWindowSeconds() -> TimeInterval {
        let rawValue = ProcessInfo.processInfo.environment["SKYBRIDGE_STRICT_AUDIO_ATTACH_RETRY_SECONDS"] ?? "45"
        let parsed = Double(rawValue) ?? 45
        return min(max(parsed, 0), 120)
    }

    nonisolated static func isReusableMediaAdmissionLease(
        expiresAt: Date?,
        now: Date = Date(),
        minimumRemainingTime: TimeInterval = 10
    ) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) > minimumRemainingTime
    }

    nonisolated static func isReusableMediaRelayEndpoint(
        expiresAt: TimeInterval?,
        now: Date = Date(),
        minimumRemainingTime: TimeInterval = 10
    ) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt - now.timeIntervalSince1970 > minimumRemainingTime
    }

    nonisolated static func isSameMediaRelaySocket(
        _ lhs: SkyBridgeMediaEndpoint?,
        _ rhs: SkyBridgeMediaEndpoint
    ) -> Bool {
        guard let lhs else { return false }
        return lhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && lhs.port == rhs.port
    }
}
