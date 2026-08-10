import Foundation
import OSLog
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

@available(macOS 14.0, *)
struct WebRTCRealtimeAudioSenderCoordinator {
    typealias OperationOwnerValidator = @MainActor @Sendable () throws(CancellationError) -> Void

    struct StartedSender {
        let sender: RemoteRealtimeMediaAudioSender
        let endpoint: SkyBridgeMediaEndpoint
    }

    struct Dependencies {
        var reusableAdmissionLease: @MainActor @Sendable (_ sessionID: String) -> SignalServerClient.MediaAdmissionLease?
        var sessionToken: @MainActor @Sendable (_ sessionID: String) -> String?
        var sessionRoleName: @MainActor @Sendable (_ sessionID: String) -> String?
        var storeAdmissionLease: @MainActor @Sendable (_ lease: SignalServerClient.MediaAdmissionLease?, _ sessionID: String) -> Void
        var requestMediaRelayLease: @Sendable (_ token: String) async throws -> SignalServerClient.MediaRelayLease
        var refreshMediaAdmissionLease: @Sendable (
            _ sessionID: String,
            _ sessionToken: String,
            _ roleName: String
        ) async throws -> SignalServerClient.MediaAdmissionLease
        var appendSessionDiagnostic: @MainActor @Sendable (_ line: String, _ sessionID: String) -> Void
        var startSender: @Sendable (_ sender: RemoteRealtimeMediaAudioSender) async throws -> Void = { sender in
            try await sender.start()
        }
        var closeSender: @Sendable (
            _ sender: RemoteRealtimeMediaAudioSender,
            _ reason: String
        ) async -> Void = { sender, reason in
            await sender.close(reason: reason)
        }
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
        continuityState: RemoteRealtimeMediaAudioSender.ContinuityState? = nil,
        validateOperationOwner: OperationOwnerValidator
    ) async throws(CancellationError) -> StartedSender? {
        try await validateCurrentOperationOwner(validateOperationOwner)
        guard let config else {
            logger.info("🎧 WebRTC PQC media audio sender skipped: session=\(sessionID, privacy: .public) reason=missingStreamConfig")
            try await validateCurrentOperationOwner(validateOperationOwner)
            return nil
        }
        guard config.requestsRealtimeMediaAudio else {
            logger.info(
                "🎧 WebRTC PQC media audio sender skipped: session=\(sessionID, privacy: .public) reason=audioNotRequested audioRedirection=\(config.audioRedirectionEnabled == true, privacy: .public) transport=\(config.audioTransport ?? "nil", privacy: .public)"
            )
            try await validateCurrentOperationOwner(validateOperationOwner)
            return nil
        }
        guard config.allowsLegacyAudioChunkFallback == false else {
            logger.info("🎧 WebRTC PQC media audio sender skipped: session=\(sessionID, privacy: .public) reason=legacyFallbackRequested")
            try await validateCurrentOperationOwner(validateOperationOwner)
            return nil
        }
        guard let viewerAudioEndpoint = config.mediaAudioEndpoint else {
            logger.warning(
                "⚠️ WebRTC PQC media audio sender unavailable: session=\(sessionID, privacy: .public) reason=missingViewerEndpoint mediaSession=\(config.mediaSessionId ?? "-", privacy: .public)"
            )
            try await appendOwnedSessionDiagnostic(
                "audioTxUnavailable session=\(sessionID) reason=missingViewerEndpoint mediaSession=\(config.mediaSessionId ?? "-")",
                sessionID: sessionID,
                validateOperationOwner: validateOperationOwner
            )
            try await validateCurrentOperationOwner(validateOperationOwner)
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
        try await appendOwnedSessionDiagnostic(
            """
            audioTxEndpointReady session=\(sessionID) \
            leaseSource=viewerReceiverSignal endpoint=\(viewerAudioEndpoint.host):\(viewerAudioEndpoint.port) \
            token=\(viewerAudioEndpoint.relayToken == nil ? "missing" : "present") \
            mediaSession=\(config.mediaSessionId ?? keys.sessionId)
            """,
            sessionID: sessionID,
            validateOperationOwner: validateOperationOwner
        )
        var localSender: RemoteRealtimeMediaAudioSender?
        do {
            try await validateCurrentOperationOwner(validateOperationOwner)
            let endpoint = try await requestSenderEndpoint(
                sessionID: sessionID,
                validateOperationOwner: validateOperationOwner
            )
            try await validateCurrentOperationOwner(validateOperationOwner)
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
            localSender = sender
            try await validateCurrentOperationOwner(validateOperationOwner)
            try await dependencies.startSender(sender)
            try await validateCurrentOperationOwner(validateOperationOwner)
            logger.info(
                """
                🎧 WebRTC 音频已接入 PQC UDP relay: session=\(sessionID, privacy: .public) event=audioTxStart \
                relay=\(endpoint.host, privacy: .public):\(endpoint.port, privacy: .public) \
                leaseSource=localRoleLease mode=\(config.requestedMediaAudioMode.rawValue, privacy: .public) \
                continuitySeq=\(continuityState?.nextSequence ?? 0, privacy: .public)
                """
            )
            try await appendOwnedSessionDiagnostic(
                "audioTxStart session=\(sessionID) relay=\(endpoint.host):\(endpoint.port) leaseSource=localRoleLease mode=\(config.requestedMediaAudioMode.rawValue) continuitySeq=\(continuityState.map { String($0.nextSequence) } ?? "-")",
                sessionID: sessionID,
                validateOperationOwner: validateOperationOwner
            )
            try await validateCurrentOperationOwner(validateOperationOwner)
            localSender = nil
            return StartedSender(sender: sender, endpoint: endpoint)
        } catch let cancellation as CancellationError {
            if let localSender {
                await dependencies.closeSender(localSender, "stale-operation-owner")
            }
            throw cancellation
        } catch {
            do {
                try await validateCurrentOperationOwner(validateOperationOwner)
            } catch let cancellation {
                if let localSender {
                    await dependencies.closeSender(localSender, "stale-operation-owner")
                }
                throw cancellation
            }
            if let localSender {
                await dependencies.closeSender(localSender, "sender-start-failed")
                do {
                    try await validateCurrentOperationOwner(validateOperationOwner)
                } catch let cancellation {
                    throw cancellation
                }
            }
            logger.warning(
                "⚠️ WebRTC PQC media relay 不可用，保持视频优先并禁用旧音频回退: session=\(sessionID, privacy: .public) reason=\(CrossNetworkConnectionManager.mediaAdmissionFailureReason(for: error), privacy: .public) err=\(error.localizedDescription, privacy: .public)"
            )
            do {
                try await appendOwnedSessionDiagnostic(
                "audioTxUnavailable session=\(sessionID) reason=\(CrossNetworkConnectionManager.mediaAdmissionFailureReason(for: error)) error=\(error.localizedDescription)",
                    sessionID: sessionID,
                    validateOperationOwner: validateOperationOwner
                )
                try await validateCurrentOperationOwner(validateOperationOwner)
            } catch let cancellation {
                throw cancellation
            }
            return nil
        }
    }

    func requestSenderEndpoint(
        sessionID: String,
        validateOperationOwner: OperationOwnerValidator
    ) async throws -> SkyBridgeMediaEndpoint {
        try await validateCurrentOperationOwner(validateOperationOwner)
        let initialLease: SignalServerClient.MediaAdmissionLease?
        if let reusable = try await ownedMainActorValue(
            validateOperationOwner: validateOperationOwner,
            operation: { dependencies.reusableAdmissionLease(sessionID) }
        ) {
            initialLease = reusable
        } else {
            try await validateCurrentOperationOwner(validateOperationOwner)
            initialLease = try await refreshAdmissionLease(
                sessionID: sessionID,
                validateOperationOwner: validateOperationOwner
            )
            try await validateCurrentOperationOwner(validateOperationOwner)
        }
        guard let initialLease else {
            throw NSError(
                domain: "CrossNetworkConnectionManager",
                code: 51,
                userInfo: [NSLocalizedDescriptionKey: "missing media admission lease"]
            )
        }

        do {
            try await validateCurrentOperationOwner(validateOperationOwner)
            let relayLease = try await dependencies.requestMediaRelayLease(initialLease.token)
            try await validateCurrentOperationOwner(validateOperationOwner)
            let endpoint = CrossNetworkConnectionManager.mediaRelayEndpoint(from: relayLease)
            try await appendOwnedSessionDiagnostic(
                "audioTxEndpointReady session=\(sessionID) leaseSource=localRoleLease role=\(relayLease.role) endpoint=\(endpoint.host):\(endpoint.port) token=\(endpoint.relayToken == nil ? "missing" : "present")",
                sessionID: sessionID,
                validateOperationOwner: validateOperationOwner
            )
            try await validateCurrentOperationOwner(validateOperationOwner)
            return endpoint
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            guard CrossNetworkConnectionManager.isMediaAdmissionLeaseRefreshable(error),
                  let refreshed = try await refreshAdmissionLease(
                    sessionID: sessionID,
                    validateOperationOwner: validateOperationOwner
                  ) else {
                throw error
            }
            do {
                try await validateCurrentOperationOwner(validateOperationOwner)
                let relayLease = try await dependencies.requestMediaRelayLease(refreshed.token)
                try await validateCurrentOperationOwner(validateOperationOwner)
                let endpoint = CrossNetworkConnectionManager.mediaRelayEndpoint(from: relayLease)
                try await appendOwnedSessionDiagnostic(
                    "audioTxEndpointReady session=\(sessionID) leaseSource=localRoleLeaseRefreshed role=\(relayLease.role) endpoint=\(endpoint.host):\(endpoint.port) token=\(endpoint.relayToken == nil ? "missing" : "present")",
                    sessionID: sessionID,
                    validateOperationOwner: validateOperationOwner
                )
                try await validateCurrentOperationOwner(validateOperationOwner)
                return endpoint
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                let baseReason = CrossNetworkConnectionManager.mediaAdmissionFailureReason(for: error)
                let reason = CrossNetworkConnectionManager.mediaAdmissionFailureReasonAfterRefresh(for: error)
                let diagnosticSummary = CrossNetworkConnectionManager.mediaTokenDiagnosticSummary(for: error) ?? ""
                if baseReason == "superseded" {
                    logger.info(
                        "🎧 media admission refreshed token rejected by relay lease: session=\(sessionID, privacy: .public) reason=refreshLeaseSuperseded \(diagnosticSummary, privacy: .public)"
                    )
                }
                try await appendOwnedSessionDiagnostic(
                    "audioTxUnavailable session=\(sessionID) reason=\(reason) \(diagnosticSummary)",
                    sessionID: sessionID,
                    validateOperationOwner: validateOperationOwner
                )
                throw WebRTCMediaAdmissionClassifiedFailure(reason: reason, underlying: error)
            }
        }
    }

    func refreshAdmissionLease(
        sessionID: String,
        validateOperationOwner: OperationOwnerValidator
    ) async throws -> SignalServerClient.MediaAdmissionLease? {
        try await validateCurrentOperationOwner(validateOperationOwner)
        guard let sessionToken = try await ownedMainActorValue(
            validateOperationOwner: validateOperationOwner,
            operation: { dependencies.sessionToken(sessionID) }
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionToken.isEmpty else {
            logger.warning("⚠️ WebRTC PQC media admission refresh skipped: session=\(sessionID, privacy: .public) reason=missingSessionToken")
            try await validateCurrentOperationOwner(validateOperationOwner)
            return nil
        }
        guard let roleName = try await ownedMainActorValue(
            validateOperationOwner: validateOperationOwner,
            operation: { dependencies.sessionRoleName(sessionID) }
        ) else {
            logger.warning("⚠️ WebRTC PQC media admission refresh skipped: session=\(sessionID, privacy: .public) reason=missingRole")
            try await validateCurrentOperationOwner(validateOperationOwner)
            return nil
        }
        try await validateCurrentOperationOwner(validateOperationOwner)
        let lease = try await dependencies.refreshMediaAdmissionLease(sessionID, sessionToken, roleName)
        try await validateCurrentOperationOwner(validateOperationOwner)
        try await commitAdmissionLease(
            lease,
            sessionID: sessionID,
            validateOperationOwner: validateOperationOwner
        )
        try await validateCurrentOperationOwner(validateOperationOwner)
        logger.info(
            "🎧 WebRTC PQC media admission refresh ready: session=\(sessionID, privacy: .public) role=\(roleName, privacy: .public) ttlMs=\(Int((lease.expiresIn * 1000).rounded()), privacy: .public)"
        )
        try await validateCurrentOperationOwner(validateOperationOwner)
        return lease
    }

    private func validateCurrentOperationOwner(
        _ validateOperationOwner: OperationOwnerValidator
    ) async throws(CancellationError) {
        guard !Task.isCancelled else { throw CancellationError() }
        try await validateOperationOwner()
        guard !Task.isCancelled else { throw CancellationError() }
    }

    private func ownedMainActorValue<Value: Sendable>(
        validateOperationOwner: OperationOwnerValidator,
        operation: @MainActor @Sendable () -> Value
    ) async throws(CancellationError) -> Value {
        try await validateCurrentOperationOwner(validateOperationOwner)
        let value = try await Self.performOwnedMainActorOperation(
            validateOperationOwner: validateOperationOwner,
            operation: operation
        )
        try await validateCurrentOperationOwner(validateOperationOwner)
        return value
    }

    @MainActor
    private static func performOwnedMainActorOperation<Value: Sendable>(
        validateOperationOwner: OperationOwnerValidator,
        operation: @MainActor @Sendable () -> Value
    ) throws(CancellationError) -> Value {
        guard !Task.isCancelled else { throw CancellationError() }
        try validateOperationOwner()
        return operation()
    }

    private func appendOwnedSessionDiagnostic(
        _ line: String,
        sessionID: String,
        validateOperationOwner: OperationOwnerValidator
    ) async throws(CancellationError) {
        let appendSessionDiagnostic = dependencies.appendSessionDiagnostic
        _ = try await ownedMainActorValue(
            validateOperationOwner: validateOperationOwner,
            operation: { appendSessionDiagnostic(line, sessionID) }
        )
    }

    private func commitAdmissionLease(
        _ lease: SignalServerClient.MediaAdmissionLease,
        sessionID: String,
        validateOperationOwner: OperationOwnerValidator
    ) async throws(CancellationError) {
        let storeAdmissionLease = dependencies.storeAdmissionLease
        _ = try await ownedMainActorValue(
            validateOperationOwner: validateOperationOwner,
            operation: { storeAdmissionLease(lease, sessionID) }
        )
    }
}
