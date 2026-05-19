import Foundation
import SkyBridgeAppleTransport
import SkyBridgeRealtimeMedia

@available(macOS 14.0, iOS 17.0, *)
extension CrossNetworkConnectionManager {
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
        if status == 401 && (
            body.contains("media_admission_token_superseded")
                || body.contains("media_admission_token_expired")
        ) {
            return true
        }
        return status == 429 && body.contains("media_admission_token_lease_limit")
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
        guard case SignalServerClient.ClientError.serverRejected(let status, let body) = error else {
            return "relayUnavailable"
        }
        if body.contains("media_admission_token_superseded") { return "superseded" }
        if body.contains("media_admission_token_expired") { return "expired" }
        if body.contains("media_admission_token_lease_limit") { return "leaseLimit" }
        if status == 404 || body.contains("Cannot POST /api/media/admission/refresh") { return "serverRefreshUnsupported" }
        if status == 503 { return "relayUnavailable" }
        return "leaseRejected"
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
