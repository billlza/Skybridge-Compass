import Foundation
import OSLog
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

@available(macOS 14.0, *)
@MainActor
struct WebRTCRealtimeAudioSenderCoordinator {
    struct StartedSender {
        let sender: RemoteRealtimeMediaAudioSender
        let endpoint: SkyBridgeMediaEndpoint
    }

    struct Dependencies {
        var reusableAdmissionLease: @MainActor (_ sessionID: String) -> SignalServerClient.MediaAdmissionLease?
        var sessionToken: @MainActor (_ sessionID: String) -> String?
        var sessionRoleName: @MainActor (_ sessionID: String) -> String?
        var storeAdmissionLease: @MainActor (_ lease: SignalServerClient.MediaAdmissionLease?, _ sessionID: String) -> Void
        var requestMediaRelayLease: @MainActor (_ token: String) async throws -> SignalServerClient.MediaRelayLease
        var refreshMediaAdmissionLease: @MainActor (
            _ sessionID: String,
            _ sessionToken: String,
            _ roleName: String
        ) async throws -> SignalServerClient.MediaAdmissionLease
        var appendSessionDiagnostic: @MainActor (_ line: String, _ sessionID: String) -> Void
    }

    private let logger: Logger
    private let dependencies: Dependencies

    init(logger: Logger, dependencies: Dependencies) {
        self.logger = logger
        self.dependencies = dependencies
    }

    func makeSenderIfNeeded(
        sessionID: String,
        keys: SessionKeys,
        config: RemoteDesktopStreamConfiguration?,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy,
        continuityState: RemoteRealtimeMediaAudioSender.ContinuityState? = nil
    ) async -> StartedSender? {
        guard let config else {
            logger.info("🎧 WebRTC PQC media audio sender skipped: session=\(sessionID, privacy: .public) reason=missingStreamConfig")
            return nil
        }
        guard config.requestsRealtimeMediaAudio else {
            logger.info(
                "🎧 WebRTC PQC media audio sender skipped: session=\(sessionID, privacy: .public) reason=audioNotRequested audioRedirection=\(config.audioRedirectionEnabled == true, privacy: .public) transport=\(config.audioTransport ?? "nil", privacy: .public)"
            )
            return nil
        }
        guard config.allowsLegacyAudioChunkFallback == false else {
            logger.info("🎧 WebRTC PQC media audio sender skipped: session=\(sessionID, privacy: .public) reason=legacyFallbackRequested")
            return nil
        }
        guard let viewerAudioEndpoint = config.mediaAudioEndpoint else {
            logger.warning(
                "⚠️ WebRTC PQC media audio sender unavailable: session=\(sessionID, privacy: .public) reason=missingViewerEndpoint mediaSession=\(config.mediaSessionId ?? "-", privacy: .public)"
            )
            dependencies.appendSessionDiagnostic(
                "audioTxUnavailable session=\(sessionID) reason=missingViewerEndpoint mediaSession=\(config.mediaSessionId ?? "-")",
                sessionID
            )
            return nil
        }
        logger.info(
            """
            🎧 WebRTC PQC media audio config received: session=\(sessionID, privacy: .public) \
            mediaSession=\(config.mediaSessionId ?? keys.sessionId, privacy: .public) \
            viewerEndpoint=\(viewerAudioEndpoint.host, privacy: .public):\(viewerAudioEndpoint.port, privacy: .public) \
            viewerRelayToken=\(viewerAudioEndpoint.relayToken == nil ? "missing" : "present", privacy: .public) \
            viewerExpiresAt=\(viewerAudioEndpoint.expiresAt.map { String(format: "%.0f", $0) } ?? "-", privacy: .public) \
            mode=\(config.requestedMediaAudioMode.rawValue, privacy: .public)
            """
        )
        dependencies.appendSessionDiagnostic(
            """
            audioTxEndpointReady session=\(sessionID) \
            leaseSource=viewerReceiverSignal endpoint=\(viewerAudioEndpoint.host):\(viewerAudioEndpoint.port) \
            token=\(viewerAudioEndpoint.relayToken == nil ? "missing" : "present") \
            mediaSession=\(config.mediaSessionId ?? keys.sessionId)
            """,
            sessionID
        )
        do {
            let endpoint = try await requestSenderEndpoint(sessionID: sessionID)
            WebRTCMediaDiagnosticWriter.append(
                WebRTCMediaDiagnosticEvent(
                    sessionId: sessionID,
                    kind: "audioTxEndpointReady",
                    probable: "lease-source-local-role-lease"
                )
            )
            let mediaSessionId = config.mediaSessionId ?? keys.sessionId
            let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
                sendSecret: keys.sendKey,
                receiveSecret: keys.receiveKey,
                sessionId: mediaSessionId,
                transcriptHash: keys.transcriptHash,
                localRole: keys.role == .initiator ? .initiator : .responder
            )
            let transportEventHandler: @Sendable (SkyBridgeRealtimeMediaTransportEvent) -> Void = { event in
                CrossNetworkWebRTCDiagnostics.writeAudioTxTransportEvent(
                    event,
                    sessionID: sessionID,
                    endpoint: endpoint,
                    leaseSource: "localRoleLease",
                    relayBindPolicy: relayBindPolicy
                )
            }
            let sender = try RemoteRealtimeMediaAudioSender(
                sessionId: mediaSessionId,
                diagnosticSessionId: sessionID,
                endpoint: endpoint,
                keys: keyMaterial.send,
                mode: config.requestedMediaAudioMode,
                relayBindPolicy: relayBindPolicy,
                continuityState: continuityState,
                transportEventHandler: transportEventHandler
            )
            try await sender.start()
            logger.info(
                """
                🎧 WebRTC 音频已接入 PQC UDP relay: session=\(sessionID, privacy: .public) event=audioTxStart \
                relay=\(endpoint.host, privacy: .public):\(endpoint.port, privacy: .public) \
                leaseSource=localRoleLease mode=\(config.requestedMediaAudioMode.rawValue, privacy: .public) \
                continuitySeq=\(continuityState?.nextSequence ?? 0, privacy: .public)
                """
            )
            dependencies.appendSessionDiagnostic(
                "audioTxStart session=\(sessionID) relay=\(endpoint.host):\(endpoint.port) leaseSource=localRoleLease mode=\(config.requestedMediaAudioMode.rawValue) continuitySeq=\(continuityState.map { String($0.nextSequence) } ?? "-")",
                sessionID
            )
            return StartedSender(sender: sender, endpoint: endpoint)
        } catch {
            logger.warning(
                "⚠️ WebRTC PQC media relay 不可用，保持视频优先并禁用旧音频回退: session=\(sessionID, privacy: .public) reason=\(CrossNetworkConnectionManager.mediaAdmissionFailureReason(for: error), privacy: .public) err=\(error.localizedDescription, privacy: .public)"
            )
            dependencies.appendSessionDiagnostic(
                "audioTxUnavailable session=\(sessionID) reason=\(CrossNetworkConnectionManager.mediaAdmissionFailureReason(for: error)) error=\(error.localizedDescription)",
                sessionID
            )
            return nil
        }
    }

    func requestSenderEndpoint(sessionID: String) async throws -> SkyBridgeMediaEndpoint {
        let initialLease: SignalServerClient.MediaAdmissionLease?
        if let reusable = dependencies.reusableAdmissionLease(sessionID) {
            initialLease = reusable
        } else {
            initialLease = try await refreshAdmissionLease(sessionID: sessionID)
        }
        guard let initialLease else {
            throw NSError(
                domain: "CrossNetworkConnectionManager",
                code: 51,
                userInfo: [NSLocalizedDescriptionKey: "missing media admission lease"]
            )
        }

        do {
            let relayLease = try await dependencies.requestMediaRelayLease(initialLease.token)
            let endpoint = CrossNetworkConnectionManager.mediaRelayEndpoint(from: relayLease)
            dependencies.appendSessionDiagnostic(
                "audioTxEndpointReady session=\(sessionID) leaseSource=localRoleLease role=\(relayLease.role) endpoint=\(endpoint.host):\(endpoint.port) token=\(endpoint.relayToken == nil ? "missing" : "present")",
                sessionID
            )
            return endpoint
        } catch {
            guard CrossNetworkConnectionManager.isMediaAdmissionLeaseRefreshable(error),
                  let refreshed = try await refreshAdmissionLease(sessionID: sessionID) else {
                throw error
            }
            let relayLease = try await dependencies.requestMediaRelayLease(refreshed.token)
            let endpoint = CrossNetworkConnectionManager.mediaRelayEndpoint(from: relayLease)
            dependencies.appendSessionDiagnostic(
                "audioTxEndpointReady session=\(sessionID) leaseSource=localRoleLeaseRefreshed role=\(relayLease.role) endpoint=\(endpoint.host):\(endpoint.port) token=\(endpoint.relayToken == nil ? "missing" : "present")",
                sessionID
            )
            return endpoint
        }
    }

    func refreshAdmissionLease(sessionID: String) async throws -> SignalServerClient.MediaAdmissionLease? {
        guard let sessionToken = dependencies.sessionToken(sessionID)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionToken.isEmpty else {
            logger.warning("⚠️ WebRTC PQC media admission refresh skipped: session=\(sessionID, privacy: .public) reason=missingSessionToken")
            return nil
        }
        guard let roleName = dependencies.sessionRoleName(sessionID) else {
            logger.warning("⚠️ WebRTC PQC media admission refresh skipped: session=\(sessionID, privacy: .public) reason=missingRole")
            return nil
        }
        let lease = try await dependencies.refreshMediaAdmissionLease(sessionID, sessionToken, roleName)
        dependencies.storeAdmissionLease(lease, sessionID)
        logger.info(
            "🎧 WebRTC PQC media admission refresh ready: session=\(sessionID, privacy: .public) role=\(roleName, privacy: .public) ttlMs=\(Int((lease.expiresIn * 1000).rounded()), privacy: .public)"
        )
        return lease
    }
}
