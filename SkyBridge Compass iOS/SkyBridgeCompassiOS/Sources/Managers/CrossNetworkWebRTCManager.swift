import Foundation
import CryptoKit
import OSLog
import SkyBridgeRealtimeMedia
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

// MARK: - iOS-local server config

/// iOS 跨网连接管理器（WebRTC DataChannel + ICE + WebSocket signaling）
///
/// 目标：让 iPhone 在 P2P/Bonjour 不可用时，仍可通过扫码（skybridge://connect/…）完成跨网连接。
@available(iOS 17.0, *)
@MainActor
public final class CrossNetworkWebRTCManager: ObservableObject {

    @Published public private(set) var state: State = .idle
    @Published public private(set) var readiness: Readiness = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastScreenData: ScreenData?
    @Published public private(set) var lastRekeyEvent: String?
    @Published public private(set) var remoteDeviceName: String?
    @Published public private(set) var remoteDeviceId: String?
#if canImport(WebRTC)
    @Published public private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published public private(set) var remoteVideoTrackReadyForPromotion = false
    @Published public private(set) var remoteVideoTrackHasRenderedFrame = false
    @Published public private(set) var remoteVideoTrackHasReceiverFrameEvidence = false
    @Published public private(set) var nativeRenderEvidenceSource: String?
    @Published public private(set) var nativeRenderUISurface: String?
    @Published public private(set) var nativePromotionState = "idle"
    @Published public private(set) var nativeVideoProbeActive = false
    @Published public private(set) var remoteVideoTrackFrameSize: CGSize = .zero
    @Published public private(set) var remoteVideoTrackRenderEpoch: UInt64 = 0
    @Published public private(set) var remoteAudioTrackHasReceivedFirstPacket = false
    private var remoteVideoTrackHasReceivedFirstPacket = false
    private var remoteVideoTrackConfirmationTask: Task<Void, Never>?
    private var nativeVideoProbeTask: Task<Void, Never>?
    private var nativeVideoProbeCooldownUntil = Date.distantPast
    private var remoteVideoTrackVisibleRenderTraceEpoch: UInt64?
    private var lastNativeReceiverFrameStatusAt = Date.distantPast
    private var remoteVideoTrackDetectedAt: Date?
    private var lastFallbackOnlyNativeVideoDiagnosticAt = Date.distantPast
    private var lastScreenDataAt: Date?
#endif
    public var nativeAudioReceiveEnabled = false
    public var smokeMediaHeartbeatDiagnosticsProvider: (@MainActor () async -> AppMessage.WebRTCMediaHeartbeatDiagnostics?)?
    @Published public private(set) var localConnectionCode: String?
    @Published public private(set) var localConnectionCodeExpiresAt: Date?
    @Published public var connectionCodeLeaseMode: ConnectionCodeLeaseMode = .shortLived {
        didSet {
            UserDefaults.standard.set(connectionCodeLeaseMode.rawValue, forKey: Self.connectionCodeLeaseModeDefaultsKey)
        }
    }
    @Published public private(set) var currentConnectLink: String?
    @Published public private(set) var activeSessionSnapshot: ActiveSessionSnapshot?
    @Published public private(set) var idleConnectionPrompt: IdleConnectionPrompt?
    nonisolated static let webRTCStartupJoinHeartbeatAttempts = 60

    public var activeRemoteDesktopSessionId: String? {
        if let sessionId = activeSessionSnapshot?.sessionId {
            return sessionId
        }
        switch state {
        case .connecting(let sessionId), .connected(let sessionId):
            return sessionId
        case .idle, .failed:
            return nil
        }
    }

    public func notifyRemoteDesktopInterruptedForActiveSession(reason: String) async {
        guard let sessionId = activeRemoteDesktopSessionId ?? currentSessionId else { return }
        await notifyRemoteDesktopTerminalSessionIfNeeded(
            sessionId: sessionId,
            kind: .interrupted,
            reason: reason
        )
    }

    private func beginRemoteDesktopNotificationTracking(sessionId: String) {
        NotificationManager.beginRemoteDesktopSession(
            sessionId: sessionId,
            transport: "webrtc"
        )
    }

    private func notifyRemoteDesktopTerminalSessionIfNeeded(
        sessionId: String,
        kind: RemoteDesktopTerminalNotificationKind,
        reason: String
    ) async {
        guard hasUserVisibleRemoteDesktopSession(sessionId: sessionId) else { return }
        await NotificationManager.sendRemoteDesktopTerminalNotificationIfNeeded(
            sessionId: sessionId,
            deviceName: remoteDesktopNotificationDeviceName(sessionId: sessionId),
            transport: "webrtc",
            kind: kind,
            reason: reason
        )
    }

    private func terminateRemoteDesktopSession(
        sessionId: String,
        disconnectKind: SessionDisconnectKind,
        notificationKind: RemoteDesktopTerminalNotificationKind,
        reason: String,
        clearSnapshot: Bool = false
    ) async {
        await notifyRemoteDesktopTerminalSessionIfNeeded(
            sessionId: sessionId,
            kind: notificationKind,
            reason: reason
        )
        applyActiveSessionDisconnect(sessionId: sessionId, kind: disconnectKind)
        await disconnect(clearSnapshot: clearSnapshot)
    }

    private func hasUserVisibleRemoteDesktopSession(sessionId: String) -> Bool {
        if case .connected(let activeSessionId) = state, activeSessionId == sessionId {
            return true
        }
        switch readiness {
        case .transportReady(let activeSessionId),
             .handshakeComplete(let activeSessionId, _):
            if activeSessionId == sessionId {
                return true
            }
        case .idle:
            break
        }
        if let snapshot = activeSessionSnapshot, snapshot.sessionId == sessionId {
            switch snapshot.phase {
            case .connecting:
                break
            case .transportReady, .handshakeComplete, .reconnecting, .disconnecting:
                return true
            }
        }
        if sessionKeys != nil, currentSessionId == sessionId {
            return true
        }
        if remoteAppActivityAtBySessionId[sessionId] != nil {
            return true
        }
        return false
    }

    private func remoteDesktopNotificationDeviceName(sessionId: String) -> String? {
        let candidates = [
            activeSessionSnapshot?.sessionId == sessionId ? activeSessionSnapshot?.deviceName : nil,
            remoteDeviceName,
            activeSessionSnapshot?.sessionId == sessionId ? activeSessionSnapshot?.deviceId : nil,
            remoteDeviceId
        ]
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  trimmed != "Remote Device",
                  trimmed != "Unknown Device",
                  trimmed != "-",
                  trimmed.lowercased() != "missing" else {
                continue
            }
            return trimmed
        }
        return nil
    }

    func realtimeMediaKeySnapshot() -> RemoteRealtimeMediaKeySnapshot? {
        guard let keys = sessionKeys,
              let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        return RemoteRealtimeMediaKeySnapshot(
            sessionId: sessionId,
            sendKey: keys.sendKey,
            receiveKey: keys.receiveKey,
            localRole: keys.role,
            transcriptHash: keys.transcriptHash,
            mediaAdmissionToken: webrtcMediaAdmissionTokenBySessionId[sessionId]
        )
    }

    func mediaRelayLeaseDiagnosticForActiveSession() -> String? {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return "missingSession"
        }
        return mediaAdmissionLeaseFailureReasonBySessionId[sessionId]
    }

    func markRealtimeMediaRelayEndpointUnusableForActiveSession(reason: String) {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return
        }
        let countKey = "\(sessionId)|\(reason)"
        let failureCount = (mediaAdmissionEndpointUnusableCountsBySessionReason[countKey] ?? 0) + 1
        mediaAdmissionEndpointUnusableCountsBySessionReason[countKey] = failureCount
        let backoff = min(30.0, Double(1 << min(failureCount - 1, 3)) * 5.0)
        let token = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId])
        recordMediaRelayLeaseFailure(
            sessionId: sessionId,
            token: token,
            reason: reason,
            backoff: backoff
        )
        SkyBridgeLogger.shared.warning(
            "🎧 PQC media relay endpoint invalidated: session=\(sessionId) reason=\(reason) failureCount=\(failureCount) backoffMs=\(Int((backoff * 1000).rounded()))"
        )
    }

    func clearCachedRealtimeMediaRelayEndpointForActiveSession(reason: String) {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return
        }
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId.removeValue(forKey: sessionId)
        SkyBridgeLogger.shared.info(
            "🎧 PQC media relay endpoint cache cleared: session=\(sessionId) reason=\(reason)"
        )
    }

    func requestRealtimeMediaRelayEndpointForActiveSession() async throws -> RealtimeMediaRelayEndpointPair? {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        if let cachedEndpoint = mediaAdmissionRelayEndpointBySessionId[sessionId] {
            if Self.isUsableMediaRelayEndpoint(cachedEndpoint) {
                return RealtimeMediaRelayEndpointPair(
                    localEndpoint: cachedEndpoint,
                    localRole: mediaAdmissionRelayRoleBySessionId[sessionId] ?? "unknown"
                )
            }
            mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
            mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        }
        let initialToken = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId])
        if let backoffReason = activeMediaAdmissionLeaseBackoffReason(sessionId: sessionId, token: initialToken) {
            SkyBridgeLogger.shared.debug(
                "ℹ️ media admission lease retry suppressed: session=\(sessionId) reason=\(backoffReason)"
            )
            return nil
        }
        guard !mediaAdmissionLeaseInFlightSessionIds.contains(sessionId) else {
            recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "inFlight")
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if let cachedEndpoint = mediaAdmissionRelayEndpointBySessionId[sessionId],
                   Self.isUsableMediaRelayEndpoint(cachedEndpoint) {
                    return RealtimeMediaRelayEndpointPair(
                        localEndpoint: cachedEndpoint,
                        localRole: mediaAdmissionRelayRoleBySessionId[sessionId] ?? "unknown"
                    )
                }
                if !mediaAdmissionLeaseInFlightSessionIds.contains(sessionId) {
                    break
                }
            }
            return nil
        }
        mediaAdmissionLeaseInFlightSessionIds.insert(sessionId)
        defer { mediaAdmissionLeaseInFlightSessionIds.remove(sessionId) }

        var token = initialToken
        if token == nil {
            guard Self.normalizedNonEmptyToken(webrtcSignalingAuthTokenBySessionId[sessionId]) != nil else {
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "missingSessionToken")
                return nil
            }
            guard currentRole != nil else {
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "missingRole")
                return nil
            }
            do {
                token = try await refreshMediaAdmissionToken(sessionId: sessionId, staleToken: nil)
            } catch {
                let reason = Self.mediaAdmissionRefreshFailureReason(for: error)
                if reason == "sessionTokenSuperseded" || reason == "sessionTokenExpired" {
                    do {
                        token = try await refreshWebRTCSessionAdmissionTokens(
                            sessionId: sessionId,
                            reason: reason
                        )
                    } catch {
                        let sessionReason = Self.sessionRefreshFailureReason(for: error)
                        recordMediaRelayLeaseFailure(
                            sessionId: sessionId,
                            token: nil,
                            reason: sessionReason,
                            backoff: 30
                        )
                        return nil
                    }
                } else {
                    recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: reason, backoff: 5)
                    return nil
                }
            }
        }
        guard let token else {
            recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "missingToken")
            return nil
        }
        if let backoffReason = activeMediaAdmissionLeaseBackoffReason(sessionId: sessionId, token: token) {
            SkyBridgeLogger.shared.debug(
                "ℹ️ media admission lease retry suppressed: session=\(sessionId) reason=\(backoffReason)"
            )
            return nil
        }
        let lease: SignalServerClientCompat.MediaRelayLease
        do {
            lease = try await signalServer.requestMediaRelayLease(mediaAdmissionToken: token)
        } catch {
            guard Self.isMediaAdmissionTokenRefreshable(error) else {
                let reason = Self.mediaRelayLeaseFailureReason(for: error)
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: reason, backoff: 5)
                return nil
            }
            let refreshedToken: String
            do {
                guard let refreshed = try await refreshMediaAdmissionToken(
                    sessionId: sessionId,
                    staleToken: token
                ) else {
                    recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: "refreshFailed", backoff: 5)
                    return nil
                }
                refreshedToken = refreshed
            } catch {
                let reason = Self.mediaAdmissionRefreshFailureReason(for: error)
                if reason == "sessionTokenSuperseded" || reason == "sessionTokenExpired" {
                    do {
                        guard let refreshed = try await refreshWebRTCSessionAdmissionTokens(
                            sessionId: sessionId,
                            reason: reason
                        ) else {
                            recordMediaRelayLeaseFailure(
                                sessionId: sessionId,
                                token: token,
                                reason: "sessionReauthFailed",
                                backoff: 30
                            )
                            return nil
                        }
                        refreshedToken = refreshed
                    } catch {
                        let sessionReason = Self.sessionRefreshFailureReason(for: error)
                        recordMediaRelayLeaseFailure(
                            sessionId: sessionId,
                            token: token,
                            reason: sessionReason,
                            backoff: 30
                        )
                        return nil
                    }
                } else {
                    recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: reason, backoff: 5)
                    return nil
                }
            }
            SkyBridgeLogger.shared.info(
                "🎧 media admission token refreshed; retrying relay lease: session=\(sessionId)"
            )
            do {
                lease = try await signalServer.requestMediaRelayLease(mediaAdmissionToken: refreshedToken)
            } catch {
                let baseReason = Self.mediaRelayLeaseFailureReason(for: error)
                let reason = Self.mediaRelayLeaseFailureReasonAfterRefresh(for: error)
                if baseReason == "superseded" {
                    SkyBridgeLogger.shared.info(
                        "🎧 media admission refreshed token rejected by relay lease: session=\(sessionId) reason=refreshLeaseSuperseded localRetryGeneration=\(Self.tokenGenerationPrefix(refreshedToken) ?? "-") \(Self.mediaTokenDiagnosticSummary(for: error) ?? "")"
                    )
                }
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: refreshedToken, reason: reason, backoff: 5)
                return nil
            }
        }
        mediaAdmissionRelayEndpointBySessionId[sessionId] = lease.endpoint
        mediaAdmissionRelayRoleBySessionId[sessionId] = lease.role
        mediaAdmissionLeaseBackoffBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionEndpointUnusableCountsBySessionReason = mediaAdmissionEndpointUnusableCountsBySessionReason.filter {
            !$0.key.hasPrefix("\(sessionId)|")
        }
        mediaAdmissionAuthorityLostSessionIds.remove(sessionId)
        SkyBridgeLogger.shared.info(
            "🎧 PQC media relay lease ready: session=\(lease.sessionID) role=\(lease.role) relay=\(lease.endpoint.host):\(lease.endpoint.port) token=\(lease.endpoint.relayToken == nil ? "missing" : "present") event=leaseReady"
        )
        return RealtimeMediaRelayEndpointPair(
            localEndpoint: lease.endpoint,
            localRole: lease.role
        )
    }

    private func refreshMediaAdmissionToken(
        sessionId: String,
        staleToken: String?
    ) async throws -> String? {
        guard let sessionToken = Self.normalizedNonEmptyToken(webrtcSignalingAuthTokenBySessionId[sessionId]),
              let role = currentRole else {
            return nil
        }
        let roleName = role == .offerer ? "initiator" : "responder"
        if staleToken != nil {
            webrtcMediaAdmissionTokenBySessionId.removeValue(forKey: sessionId)
        }
        let staleGeneration = Self.tokenGenerationPrefix(staleToken) ?? "missing"
        let sessionGeneration = Self.tokenGenerationPrefix(sessionToken) ?? "missing"
        let idempotencyKey = "media-refresh-\(sessionId)-\(roleName)-\(sessionGeneration)-\(staleGeneration)"
        let refreshed = try await signalServer.refreshMediaAdmissionLease(
            sessionId: sessionId,
            sessionToken: sessionToken,
            role: roleName,
            idempotencyKey: idempotencyKey
        )
        let normalized = Self.normalizedNonEmptyToken(refreshed.token)
        if let normalized {
            webrtcMediaAdmissionTokenBySessionId[sessionId] = normalized
            SkyBridgeLogger.shared.info(
                "🎧 media admission token refresh accepted: session=\(sessionId) role=\(roleName) localStaleGeneration=\(staleGeneration) localRefreshedGeneration=\(Self.tokenGenerationPrefix(normalized) ?? "-") serverGeneration=\(refreshed.mediaTokenGeneration ?? "-") serverBuild=\(refreshed.serverBuildFingerprint ?? "-")"
            )
        } else {
            if let staleToken {
                webrtcMediaAdmissionTokenBySessionId[sessionId] = staleToken
            } else {
                webrtcMediaAdmissionTokenBySessionId.removeValue(forKey: sessionId)
            }
        }
        return normalized
    }

    private func refreshWebRTCSessionAdmissionTokens(
        sessionId: String,
        reason: String
    ) async throws -> String? {
        guard let role = currentRole else {
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "missingRole"]
            )
        }
        let roleName = role == .offerer ? "initiator" : "responder"
        guard !mediaAdmissionSessionRefreshInFlightSessionIds.contains(sessionId) else {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if let token = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId]) {
                    return token
                }
                if !mediaAdmissionSessionRefreshInFlightSessionIds.contains(sessionId) {
                    break
                }
            }
            return Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId])
        }

        mediaAdmissionSessionRefreshInFlightSessionIds.insert(sessionId)
        defer { mediaAdmissionSessionRefreshInFlightSessionIds.remove(sessionId) }

        let binding = try await currentPathLocalBinding()
        let admission = try await requestAdmissionLease(for: binding)
        let lease = try await signalServer.refreshWebRTCSession(
            admissionToken: admission.token,
            sessionId: sessionId,
            role: roleName
        )
        let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
            origin: lease.signalingServerOrigin,
            wsPath: lease.wsPath
        )
        webrtcSignalingAuthTokenBySessionId[sessionId] = lease.sessionToken
        webrtcTurnAdmissionTokenBySessionId[sessionId] = lease.turnAdmissionToken
        if let mediaToken = Self.normalizedNonEmptyToken(lease.mediaAdmissionToken) {
            webrtcMediaAdmissionTokenBySessionId[sessionId] = mediaToken
        } else {
            webrtcMediaAdmissionTokenBySessionId.removeValue(forKey: sessionId)
        }
        setCurrentPathSignalingEndpoint(sessionId: sessionId, endpoint: signalingEndpoint)
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseBackoffBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId.removeValue(forKey: sessionId)
        SkyBridgeLogger.shared.info(
            "🎧 WebRTC session tokens refreshed for media lease: session=\(sessionId) role=\(roleName) reason=\(reason) serverBuild=\(lease.serverBuildFingerprint ?? "-") sessionTokenGeneration=\(lease.sessionTokenGeneration ?? "-") mediaTokenGeneration=\(lease.mediaTokenGeneration ?? "-")"
        )
        return Self.normalizedNonEmptyToken(lease.mediaAdmissionToken)
    }

    private func recordMediaRelayLeaseFailure(
        sessionId: String,
        token: String?,
        reason: String,
        backoff: TimeInterval? = nil
    ) {
        mediaAdmissionLeaseFailureReasonBySessionId[sessionId] = reason
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        if let backoff {
            mediaAdmissionLeaseBackoffBySessionId[sessionId] = (token, Date().addingTimeInterval(backoff), reason)
        }
        let backoffLabel = backoff.map { " backoffMs=\(Int(($0 * 1000).rounded()))" } ?? ""
        SkyBridgeLogger.shared.info(
            "🎧 PQC media relay lease unavailable: session=\(sessionId) reason=\(reason)\(backoffLabel)"
        )
        if Self.isSessionAuthorityLostReason(reason) {
            recordSessionAuthorityLost(sessionId: sessionId, reason: reason)
        }
    }

    private func recordSessionAuthorityLost(sessionId: String, reason: String) {
        guard mediaAdmissionAuthorityLostSessionIds.insert(sessionId).inserted else { return }
        mediaAdmissionLeaseBackoffBySessionId[sessionId] = (nil, Date().addingTimeInterval(30), "sessionAuthorityLost")
        mediaAdmissionRelayEndpointBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionRelayRoleBySessionId.removeValue(forKey: sessionId)
        mediaAdmissionLeaseFailureReasonBySessionId[sessionId] = "sessionAuthorityLost"
        let sessionGeneration = Self.tokenGenerationPrefix(webrtcSignalingAuthTokenBySessionId[sessionId]) ?? "-"
        let mediaGeneration = Self.tokenGenerationPrefix(webrtcMediaAdmissionTokenBySessionId[sessionId]) ?? "-"
        SkyBridgeLogger.shared.warning(
            "🎧 WebRTC session authority lost: session=\(sessionId) event=sessionAuthorityLost reason=\(reason) localSessionGeneration=\(sessionGeneration) localMediaGeneration=\(mediaGeneration) action=fullRejoinRequired"
        )
        if currentSessionId == sessionId {
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentSessionId == sessionId else { return }
                await self.terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    disconnectKind: .transient,
                    notificationKind: .interrupted,
                    reason: "session_authority_lost:\(reason)"
                )
                self.lastError = "WebRTC session authority lost; full rejoin required"
                self.state = .failed("sessionAuthorityLost")
                self.readiness = .idle
            }
        }
    }

    private func activeMediaAdmissionLeaseBackoffReason(
        sessionId: String,
        token: String?,
        now: Date = Date()
    ) -> String? {
        guard let backoff = mediaAdmissionLeaseBackoffBySessionId[sessionId] else {
            return nil
        }
        guard backoff.until > now else {
            mediaAdmissionLeaseBackoffBySessionId.removeValue(forKey: sessionId)
            return nil
        }
        guard backoff.token == nil || backoff.token == token else {
            return nil
        }
        mediaAdmissionLeaseFailureReasonBySessionId[sessionId] = backoff.reason
        return backoff.reason
    }

    private static let connectionCodeLeaseModeDefaultsKey = "cross_network_connection_code_lease_mode"
    private static let idleConnectionReminderDelay: TimeInterval = 180

    private var signaling: WebSocketSignalingClient?
    private var signalingShardKey: String?
    private let signalServer = SignalServerClientCompat()
    private let signalingRetryController = SignalingRetryController()
    private var signalingRecoveryTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var signalingGenerationBySessionId: [String: Int] = [:]
    private var activeSignalingHandleBySessionId: [String: WebSocketSignalingClient.SignalingHandleID] = [:]
    private var signalingHealth: SignalingHealth = .healthy
    var session: WebRTCSession?
    private var currentSessionId: String?
#if canImport(WebRTC)
    private var remoteVideoHeartbeatRenderer: RemoteVideoTrackHeartbeatRenderer?
#endif
    private let localDeviceId: String = {
        ProtocolDeviceIdentity.stableDeviceId()
    }()
    private var currentPathExpectedRemoteAuthorityBySessionId: [String: CurrentPathRemoteAuthorityCompat] = [:]
    private var currentPathAdditionalProtocolFingerprintsBySessionId: [String: Set<String>] = [:]
    private var currentPathSignalingOriginBySessionId: [String: String] = [:]
    private var currentPathSignalingWebSocketPathBySessionId: [String: String] = [:]
    private var pendingVerifiedQRAuthoritiesByDeviceId: [String: PendingVerifiedQRAuthorityCompat] = [:]
    private var handshakeDriver: HandshakeDriver?
    private var handshakePeerId: String?
    var sessionKeys: SessionKeys?
    private var inboundQueue: InboundChunkQueue?
    private var screenInboundQueue: InboundChunkQueue?
    private var receiveTask: Task<Void, Never>?
    private var screenReceiveTask: Task<Void, Never>?
    private var currentRole: WebRTCSession.Role?
    private var handshakeStartedSessionIds: Set<String> = []
    private var inboundInitialHandshakeResponderSessionIds: Set<String> = []
    private var inboundClassicAuthorityBootstrapSessionIds: Set<String> = []
    private var strictPQCClassicBootstrapOnlySessionIds: Set<String> = []
    private var strictPQCClassicBootstrapTimeoutTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var rekeyInProgressSessionIds: Set<String> = []
    private var rekeyCompletedSessionIds: Set<String> = []
    private var inboundRekeyResponderSessionIds: Set<String> = []
    private var strictPQCRequestedBySessionId: [String: Bool] = [:]
    private var lastPairingIdentityExchangeSentAtByPeerId: [String: Date] = [:]
    private var connectionCodeBootstrapTask: Task<Void, Never>?
    private var connectionCodeExpiryTask: Task<Void, Never>?
    private var idleConnectionReminderTask: Task<Void, Never>?
    private var activeConnectionCodeLeaseMode: ConnectionCodeLeaseMode?
    private var localConnectionSessionId: String?
    private var activeConnectionCodeAuthorityDeviceId: String?
    private var activeConnectionCodeAuthorityFingerprint: String?
    private var authorityBoundWebRTCBootstrapSessionIds = Set<String>()
    private var activeSessionReconnectTimeoutTask: Task<Void, Never>?
    private var webrtcSignalingAuthTokenBySessionId: [String: String] = [:]
    private var webrtcTurnAdmissionTokenBySessionId: [String: String] = [:]
    private var webrtcMediaAdmissionTokenBySessionId: [String: String] = [:]
    private var mediaAdmissionLeaseBackoffBySessionId: [String: (token: String?, until: Date, reason: String)] = [:]
    private var mediaAdmissionLeaseInFlightSessionIds = Set<String>()
    private var mediaAdmissionSessionRefreshInFlightSessionIds = Set<String>()
    private var mediaAdmissionLeaseFailureReasonBySessionId: [String: String] = [:]
    private var mediaAdmissionAuthorityLostSessionIds = Set<String>()
    private var mediaAdmissionRelayEndpointBySessionId: [String: SkyBridgeMediaEndpoint] = [:]
    private var mediaAdmissionRelayRoleBySessionId: [String: String] = [:]
    private var mediaAdmissionEndpointUnusableCountsBySessionReason: [String: Int] = [:]
    private var latestLocalOfferBySessionId: [String: String] = [:]
    private var latestLocalAnswerBySessionId: [String: String] = [:]
    private var localICECandidatesBySessionId: [String: [WebRTCSignalingEnvelope.Payload]] = [:]
    private var joinHeartbeatTask: Task<Void, Never>?
    private var offerResendTask: Task<Void, Never>?
    private var remoteDesktopHeartbeatTask: Task<Void, Never>?
    private var remotePeerPingTask: Task<Void, Never>?
    private var remotePeerLivenessWatchdogTask: Task<Void, Never>?
    private var remoteAppActivityAtBySessionId: [String: Date] = [:]
    private var suppressSignalingRecovery = false
    private var nextRemotePeerPingID: UInt64 = 1
    private var inFlightScannedConnectLink: String?

    // File transfer waiters (transferId|op|chunkIndex -> waiter)
    // token 用于防止残留的超时任务误杀同 key 的后续 waiter（见 waitForFileTransferAck）。
    var fileTransferWaiters: [String: FileTransferWaiter] = [:]
    var webRTCSecureEnvelopeSendCounterBySessionId: [String: UInt64] = [:]
    var webRTCSecureEnvelopeReplayWindowBySessionId: [String: WebRTCAppSecureReplayWindow] = [:]
    var webRTCSecureEnvelopeKeyFingerprintBySessionId: [String: String] = [:]

    private var sessionSnapshotMetadataBySessionId: [String: SessionSnapshotMetadata] = [:]

    var inboundFileTransfers: [String: InboundFileTransferState] = [:]
    var inboundFileTransferCompleteTimers: [String: Task<Void, Never>] = [:]

    public static let instance = CrossNetworkWebRTCManager()
    private init() {
        if let rawMode = UserDefaults.standard.string(forKey: Self.connectionCodeLeaseModeDefaultsKey),
           let mode = ConnectionCodeLeaseMode(rawValue: rawMode) {
            connectionCodeLeaseMode = mode
        }
    }

    public var isTransportReady: Bool {
        switch readiness {
        case .transportReady, .handshakeComplete:
            return true
        case .idle:
            return false
        }
    }

    public var isHandshakeComplete: Bool {
        if case .handshakeComplete = readiness { return true }
        return false
    }

    @discardableResult
    private func prepareSessionSnapshotMetadata(
        sessionId: String,
        source: ActiveSessionSnapshotSource,
        deviceId: String?,
        deviceName: String?
    ) -> SessionSnapshotMetadata {
        let metadata = SessionSnapshotMetadata(
            snapshotToken: UUID(),
            source: source,
            deviceId: deviceId,
            deviceName: deviceName
        )
        sessionSnapshotMetadataBySessionId[sessionId] = metadata
        return metadata
    }

    @discardableResult
    private func activatePreparedSessionSnapshot(
        sessionId: String,
        phase: ActiveSessionSnapshotPhase,
        negotiatedSuite: String? = nil
    ) -> UUID? {
        guard let metadata = sessionSnapshotMetadataBySessionId[sessionId] else { return nil }
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionSnapshot = ActiveSessionSnapshotContract.activate(
            sessionId: sessionId,
            source: metadata.source,
            phase: phase,
            deviceId: metadata.deviceId,
            deviceName: metadata.deviceName,
            negotiatedSuite: negotiatedSuite,
            snapshotToken: metadata.snapshotToken
        )
        return metadata.snapshotToken
    }

    private func updatePreparedSessionSnapshot(
        sessionId: String,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String? = nil,
        deviceName: String? = nil,
        negotiatedSuite: String? = nil,
        snapshotToken: UUID? = nil
    ) {
        let token = snapshotToken ?? sessionSnapshotMetadataBySessionId[sessionId]?.snapshotToken
        guard let token else { return }
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionSnapshot = ActiveSessionSnapshotContract.update(
            current: activeSessionSnapshot,
            sessionId: sessionId,
            snapshotToken: token,
            phase: phase,
            deviceId: deviceId,
            deviceName: deviceName,
            negotiatedSuite: negotiatedSuite
        )
    }

    private func applyActiveSessionDisconnect(
        sessionId: String,
        kind: SessionDisconnectKind,
        snapshotToken: UUID? = nil
    ) {
        let token = snapshotToken ?? sessionSnapshotMetadataBySessionId[sessionId]?.snapshotToken
        guard let token else { return }

        let nextSnapshot = ActiveSessionSnapshotContract.disconnect(
            current: activeSessionSnapshot,
            sessionId: sessionId,
            snapshotToken: token,
            kind: kind
        )
        activeSessionSnapshot = nextSnapshot

        switch kind {
        case .transient:
            if let nextSnapshot {
                scheduleActiveSessionReconnectTimeout(for: nextSnapshot)
            }
        case .explicit, .remoteLeave:
            activeSessionReconnectTimeoutTask?.cancel()
            sessionSnapshotMetadataBySessionId.removeValue(forKey: sessionId)
        }
    }

    private func scheduleActiveSessionReconnectTimeout(for snapshot: ActiveSessionSnapshot) {
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionReconnectTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(5))
            guard let current = self.activeSessionSnapshot,
                  current.snapshotToken == snapshot.snapshotToken,
                  current.phase == .reconnecting else {
                return
            }
            self.activeSessionSnapshot = nil
            self.sessionSnapshotMetadataBySessionId.removeValue(forKey: snapshot.sessionId)
        }
    }

    private func noteRemoteAppActivity(sessionId: String) {
        remoteAppActivityAtBySessionId[sessionId] = Date()
    }

    private func startRemotePeerPingLoop(sessionId: String, session: WebRTCSession) {
        remotePeerPingTask?.cancel()
        remotePeerPingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.currentSessionId == sessionId,
                      self.session === session else { break }
                guard case .connected(let activeSessionId) = self.state, activeSessionId == sessionId else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                guard self.sessionKeys != nil else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if self.rekeyInProgressSessionIds.contains(sessionId) {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                let pingId = self.nextRemotePeerPingID
                self.nextRemotePeerPingID &+= 1

                do {
                    try await self.sendAppMessageOverWebRTC(
                        .ping(.init(id: pingId)),
                        sessionId: sessionId,
                        session: session,
                        label: "tx/webrtc-ping"
                    )
                } catch {
                    SkyBridgeLogger.shared.debug("ℹ️ WebRTC ping send failed: \(error.localizedDescription)")
                    break
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startRemotePeerLivenessWatchdog(sessionId: String, session: WebRTCSession) {
        remotePeerLivenessWatchdogTask?.cancel()
        remotePeerLivenessWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let timeoutSeconds: TimeInterval = 12.0
            while !Task.isCancelled {
                guard self.currentSessionId == sessionId,
                      self.session === session else { break }
                if self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                guard case .connected(let activeSessionId) = self.state, activeSessionId == sessionId else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }

                let lastActivityAt = self.remoteAppActivityAtBySessionId[sessionId] ?? .distantPast
                if Date().timeIntervalSince(lastActivityAt) > timeoutSeconds {
                    let msg = "远端连接已失活"
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC remote peer timeout: session=\(sessionId) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                    )
                    self.lastError = msg
                    await self.notifyRemoteDesktopTerminalSessionIfNeeded(
                        sessionId: sessionId,
                        kind: .interrupted,
                        reason: "remote_peer_timeout"
                    )
                    self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .transient)
                    await self.disconnect(clearSnapshot: false)
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.readiness = .idle
                    break
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func markStrictPQCClassicBootstrapOnly(
        sessionId: String,
        session: WebRTCSession
    ) {
        strictPQCClassicBootstrapOnlySessionIds.insert(sessionId)
        startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)

        strictPQCClassicBootstrapTimeoutTasksBySessionId[sessionId]?.cancel()
        strictPQCClassicBootstrapTimeoutTasksBySessionId[sessionId] = Task { @MainActor [weak self, weak session] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(
                    CrossNetworkWebRTCHandshakeLimits.strictPQCClassicBootstrapTimeoutSeconds
                ))
                guard let self,
                      let session,
                      self.currentSessionId == sessionId,
                      self.session === session,
                      self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionId),
                      self.sessionKeys?.negotiatedSuite.isPQCGroup != true else {
                    self?.strictPQCClassicBootstrapTimeoutTasksBySessionId.removeValue(forKey: sessionId)
                    return
                }

                let now = Date()
                let elapsed = now.timeIntervalSince(startedAt)
                let lastActivityAt = self.remoteAppActivityAtBySessionId[sessionId] ?? startedAt
                let hasFreshActivity = now.timeIntervalSince(lastActivityAt)
                    <= CrossNetworkWebRTCHandshakeLimits.strictPQCClassicBootstrapTimeoutSeconds
                let isRekeyActivelyProgressing = self.rekeyInProgressSessionIds.contains(sessionId)
                if elapsed < CrossNetworkWebRTCHandshakeLimits.strictPQCClassicBootstrapMaxGraceSeconds,
                   (hasFreshActivity || isRekeyActivelyProgressing) {
                    SkyBridgeLogger.shared.warning(
                        "⏳ WebRTC strictPQC classic bootstrap timeout extended while rekey/liveness is active: session=\(sessionId), elapsed=\(Int(elapsed))s, active=\(hasFreshActivity), rekey=\(isRekeyActivelyProgressing)"
                    )
                    continue
                }

                self.strictPQCClassicBootstrapTimeoutTasksBySessionId.removeValue(forKey: sessionId)
                await self.failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: "strictPQC WebRTC rekey timed out after classic bootstrap"
                )
                return
            }
        }
    }

    private func clearStrictPQCClassicBootstrapOnly(sessionId: String) {
        strictPQCClassicBootstrapOnlySessionIds.remove(sessionId)
        strictPQCClassicBootstrapTimeoutTasksBySessionId.removeValue(forKey: sessionId)?.cancel()
    }

    private func localProtocolIdentityPublicKeysForPairing() async -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        var keys: [AppMessage.ProtocolIdentityPublicKeyInfo] = []
        for algorithm in [ProtocolSigningAlgorithm.ed25519, .mlDSA65] {
            do {
                let publicKey = try await SkyBridgeiOSCore.shared.getProtocolSigningPublicKey(for: algorithm)
                keys.append(.init(protocolSigningAlgorithm: algorithm.rawValue, publicKey: publicKey))
            } catch {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ WebRTC pairingIdentityExchange skipped protocol identity key alg=\(algorithm.rawValue): \(error.localizedDescription)"
                )
            }
        }
        return AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(keys) ?? []
    }

    private func protocolIdentityFingerprints(
        from payload: AppMessage.PairingIdentityExchangePayload
    ) -> Set<String> {
        Set((AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(payload.protocolIdentityPublicKeys) ?? [])
            .compactMap { $0.authoritativeFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    private func recordCurrentPathProtocolFingerprints(
        from payload: AppMessage.PairingIdentityExchangePayload,
        sessionId: String,
        peerDeviceId: String
    ) {
        let fingerprints = protocolIdentityFingerprints(from: payload)
        guard !fingerprints.isEmpty else { return }
        currentPathAdditionalProtocolFingerprintsBySessionId[sessionId, default: []].formUnion(fingerprints)
        appendSmokeTrace(
            "protocol-identity-pins session=\(sessionId) peer=\(peerDeviceId) declared=\(payload.deviceId) count=\(fingerprints.count)"
        )
        SkyBridgeLogger.shared.info(
            "🔐 WebRTC current-path protocol identity pins updated: session=\(sessionId), peer=\(peerDeviceId), declared=\(payload.deviceId), count=\(fingerprints.count)"
        )
    }

    private func additionalProtocolFingerprints(for sessionId: String) -> Set<String> {
        currentPathAdditionalProtocolFingerprintsBySessionId[sessionId] ?? []
    }

    private func currentPathLocalProtocolSigningAlgorithm() -> ProtocolSigningAlgorithm {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        return CrossNetworkWebRTCPQCHandshakePolicy.shouldRequestStrictPQC(
            compatibilityModeEnabled: compatibilityModeEnabled
        ) ? .mlDSA65 : .ed25519
    }

    private func currentPathLocalBinding() async throws -> ProtocolIdentityBindingCompat {
        let algorithm = currentPathLocalProtocolSigningAlgorithm()
        let publicKey = try await SkyBridgeiOSCore.shared.getProtocolSigningPublicKey(for: algorithm)
        return try ProtocolIdentityBindingCompat(
            deviceId: localDeviceId,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyBytes: publicKey
        )
    }

    private func signCurrentPathPayload(
        _ payload: Data,
        algorithm: ProtocolSigningAlgorithm
    ) async throws -> Data {
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let signingHandle = try await SkyBridgeiOSCore.shared.getProtocolSigningKeyHandle(for: algorithm)
        return try await signatureProvider.sign(payload, key: signingHandle)
    }

    private func noteVerifiedQRCodeAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String
    ) {
        pendingVerifiedQRAuthoritiesByDeviceId[deviceId] = PendingVerifiedQRAuthorityCompat(
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint.lowercased(),
            verifiedAt: Date()
        )
    }

    private func hasRecentVerifiedQRCodeAuthority(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        maxAge: TimeInterval = 10 * 60
    ) -> Bool {
        guard let pending = pendingVerifiedQRAuthoritiesByDeviceId[deviceId] else { return false }
        guard pending.protocolPublicKeyFingerprint == protocolPublicKeyFingerprint.lowercased() else { return false }
        return Date().timeIntervalSince(pending.verifiedAt) <= maxAge
    }

    private func activeConnectionCodeMatchesCurrentAuthority(_ binding: ProtocolIdentityBindingCompat) -> Bool {
        guard let activeConnectionCodeAuthorityDeviceId,
              let activeConnectionCodeAuthorityFingerprint else {
            return false
        }
        return activeConnectionCodeAuthorityDeviceId == binding.deviceId
            && activeConnectionCodeAuthorityFingerprint == binding.protocolPublicKeyFingerprint
    }

    private func enforceCurrentPathTrustBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        rebindSource: CurrentPathRebindSource = .none
    ) throws {
        if let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
            let shouldAllowRebind: Bool
            switch rebindSource {
            case .none:
                shouldAllowRebind = false
            case .verifiedQRCode:
                shouldAllowRebind = Self.shouldAllowVerifiedQRCodeRebind(
                    for: conflict,
                    deviceId: deviceId,
                    protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
                )
            case .verifiedConnectionCode:
                shouldAllowRebind = Self.shouldAllowAuthenticatedConnectionCodeRebind(for: conflict)
            }

            if shouldAllowRebind {
                SkyBridgeLogger.shared.warning(
                    "⚠️ 允许受限 current-path authority 重绑定: source=\(String(describing: rebindSource)) deviceId=\(deviceId) fingerprint=\(protocolPublicKeyFingerprint) conflict=\(String(describing: conflict))"
                )
                return
            }
            let prefix = rebindSource == .verifiedConnectionCode ? "连接码" : "二维码"
            switch conflict {
            case .identityConflict:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 21, userInfo: [NSLocalizedDescriptionKey: "\(prefix) authoritative key 与现有 deviceId 绑定冲突"])
            case .deviceIdMigrationRequired:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 22, userInfo: [NSLocalizedDescriptionKey: "\(prefix) deviceId 与已 pinned authoritative key 不匹配"])
            case .quarantinedIdentity:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 23, userInfo: [NSLocalizedDescriptionKey: "\(prefix)身份处于隔离/待重新验证状态"])
            case .revokedIdentity:
                throw NSError(domain: "CrossNetworkWebRTCManager", code: 24, userInfo: [NSLocalizedDescriptionKey: "\(prefix)身份已撤销"])
            }
        }
    }

    private func persistCurrentPathTrust(sessionId: String) {
        guard let authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] else { return }
        TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: authority.deviceId,
            name: authority.deviceName ?? authority.deviceId,
            protocolSigningAlgorithm: authority.protocolSigningAlgorithm.rawValue,
            protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
        )
    }

    private func requestAdmissionLease(for binding: ProtocolIdentityBindingCompat) async throws -> SignalServerClientCompat.AdmissionLease {
        let challenge = try await signalServer.requestAdmissionChallenge(binding: binding)
        let signature = try await signCurrentPathPayload(
            challenge.signaturePayload(),
            algorithm: binding.protocolSigningAlgorithm
        )
        return try await signalServer.completeAdmission(challenge: challenge, binding: binding, signature: signature)
    }

    public func connect(fromScannedString string: String) async {
        disarmIdleConnectionReminder(clearPrompt: true)
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            lastError = ConnectLinkError.invalidFormat.localizedDescription
            state = .failed(lastError ?? "二维码格式无效")
            readiness = .idle
            return
        }
        if inFlightScannedConnectLink == normalized {
            SkyBridgeLogger.shared.info("ℹ️ 忽略重复扫码连接请求（同一二维码仍在处理中）")
            return
        }
        inFlightScannedConnectLink = normalized
        defer {
            if inFlightScannedConnectLink == normalized {
                inFlightScannedConnectLink = nil
            }
        }
        do {
            SkyBridgeLogger.shared.info("🌐 QR connect phase=start")
            let payload = try await parseSkybridgeConnectLink(normalized)
            SkyBridgeLogger.shared.info("🌐 QR connect phase=payload_parsed session=\(payload.sessionID) device=\(payload.deviceID)")
            try await connect(from: payload)
            SkyBridgeLogger.shared.info("🌐 QR connect phase=connect_dispatched session=\(payload.sessionID)")
        } catch {
            let msg = error.localizedDescription
            SkyBridgeLogger.shared.error("❌ QR connect phase=failed err=\(msg)")
            lastError = msg
            state = .failed(msg)
            readiness = .idle
        }
    }

    @discardableResult
    public func importVerifiedConnectLinkTrust(
        fromScannedString string: String
    ) async throws -> VerifiedConnectLinkTrustImport {
        _ = string
        throw Self.p2pKEMQRCodeBootstrapDisabledError()
    }

#if DEBUG
    internal func testOnlyVerifyConnectLinkWithoutRedeem(
        fromScannedString string: String
    ) async throws -> VerifiedConnectLinkTrustImport {
        let verified = try await verifyAndPersistSkybridgeConnectLink(string)
        return VerifiedConnectLinkTrustImport(
            deviceID: verified.qr.deviceID,
            deviceName: verified.qr.deviceName,
            capabilities: verified.qr.normalizedCapabilities,
            protocolPublicKeyFingerprint: verified.qr.protocolPublicKeyFingerprint,
            kemSuiteWireIDs: verified.qr.normalizedKEMPublicKeys.map(\.suiteWireId)
        )
    }
#endif

    private static func p2pKEMQRCodeBootstrapDisabledError() -> NSError {
        NSError(
            domain: "CrossNetworkWebRTCManager",
            code: 8412,
            userInfo: [
                NSLocalizedDescriptionKey: "P2P KEM 二维码引导已移除。请使用设备确认码完成 PIB-1 身份绑定，然后通过 SKR-1 signed LAN KEM refresh 恢复。"
            ]
        )
    }

    private func validatedCurrentPathSignalingEndpoint(
        origin: String,
        wsPath: String?
    ) throws -> (origin: String, wsPath: String) {
        let canonicalOrigin = try validateCurrentPathOrigin(origin)
        let normalizedPath = try validateCurrentPathWebSocketPath(wsPath)
        return (canonicalOrigin, normalizedPath)
    }

    private func setCurrentPathSignalingEndpoint(
        sessionId: String,
        endpoint: (origin: String, wsPath: String)
    ) {
        currentPathSignalingOriginBySessionId[sessionId] = endpoint.origin
        currentPathSignalingWebSocketPathBySessionId[sessionId] = endpoint.wsPath
    }

    /// 通过智能连接码连接（与 macOS 侧共享同一字母表与长度语义）
    /// - Note: 当前实现直接把 code 当作 WebRTC sessionId（同 signaling room）。
    public func connect(withCode rawCode: String) async {
        disarmIdleConnectionReminder(clearPrompt: true)
        do {
            let code = try normalizeConnectionCode(rawCode)
            SkyBridgeLogger.shared.info("🌐 code connect phase=start code=<redacted>")
            let localBinding = try await currentPathLocalBinding()
            SkyBridgeLogger.shared.info("🌐 code connect phase=local_binding_ready device=\(localBinding.deviceId)")
            let admission = try await requestAdmissionLease(for: localBinding)
            SkyBridgeLogger.shared.info("🌐 code connect phase=admission_ready")
            let lookup = try await signalServer.lookupConnectionCode(admissionToken: admission.token, code: code)
            SkyBridgeLogger.shared.info("🌐 code connect phase=lookup_ready session=\(lookup.sessionID) initiator=\(lookup.initiatorDeviceId)")
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: lookup.signalingServerOrigin,
                wsPath: lookup.wsPath
            )
            let codeRebindSource: CurrentPathRebindSource =
                hasRecentVerifiedQRCodeAuthority(
                    deviceId: lookup.initiatorDeviceId,
                    protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint
                )
                ? .verifiedQRCode
                : .verifiedConnectionCode
            try enforceCurrentPathTrustBinding(
                deviceId: lookup.initiatorDeviceId,
                protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
                rebindSource: codeRebindSource
            )
            webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lookup.sessionID] = lookup.turnAdmissionToken
            if let mediaAdmissionToken = lookup.mediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[lookup.sessionID] = mediaAdmissionToken
            }
            setCurrentPathSignalingEndpoint(sessionId: lookup.sessionID, endpoint: signalingEndpoint)
            currentPathExpectedRemoteAuthorityBySessionId[lookup.sessionID] = CurrentPathRemoteAuthorityCompat(
                deviceId: lookup.initiatorDeviceId,
                protocolSigningAlgorithm: lookup.initiatorProtocolSigningAlgorithm,
                protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
                protocolPublicKeyBytes: nil,
                deviceName: lookup.initiatorDeviceName
            )
            try await connect(
                sessionId: lookup.sessionID,
                remoteName: lookup.initiatorDeviceName,
                remotePeerDeviceId: lookup.initiatorDeviceId,
                source: .code,
                role: .answerer
            )
            SkyBridgeLogger.shared.info("🌐 code connect phase=connect_dispatched session=\(lookup.sessionID)")
        } catch {
            let msg = error.localizedDescription
            SkyBridgeLogger.shared.error("❌ code connect phase=failed err=\(msg)")
            lastError = msg
            state = .failed(msg)
            readiness = .idle
        }
    }

    /// 生成本机连接码并等待对端（例如 macOS）输入连接。
    /// - Returns: 服务端签发的短期连接码；失败时返回 `nil` 且更新 `state/.failed`。
    @discardableResult
    public func generateConnectionCode() async -> String? {
        disarmIdleConnectionReminder(clearPrompt: true)
        let requestedLeaseMode = connectionCodeLeaseMode

        do {
            let localBinding = try await currentPathLocalBinding()
            let canReuseCurrentAuthority = activeConnectionCodeMatchesCurrentAuthority(localBinding)
            if let existing = localConnectionCode,
               activeConnectionCodeLeaseMode == requestedLeaseMode,
               currentRole == .offerer,
               case .connecting(let sid) = state, sid == (localConnectionSessionId ?? existing),
               Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt),
               canReuseCurrentAuthority {
                return existing
            }
            if let existing = localConnectionCode,
               activeConnectionCodeLeaseMode == requestedLeaseMode,
               currentRole == .offerer,
               case .connected(let sid) = state, sid == (localConnectionSessionId ?? existing),
               Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt),
               canReuseCurrentAuthority {
                return existing
            }
            if let existing = localConnectionCode,
               activeConnectionCodeLeaseMode == requestedLeaseMode,
               currentRole == .offerer,
               (!Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt) || !canReuseCurrentAuthority) {
                let reason = canReuseCurrentAuthority ? "connection_code_lease_not_reusable" : "connection_code_authority_changed"
                SkyBridgeLogger.shared.info("ℹ️ 本地连接码不可复用，重新向信令服务注册: reason=\(reason) code=\(existing)")
                let staleSessionId = localConnectionSessionId
                localConnectionCode = nil
                localConnectionCodeExpiresAt = nil
                localConnectionSessionId = nil
                activeConnectionCodeLeaseMode = nil
                activeConnectionCodeAuthorityDeviceId = nil
                activeConnectionCodeAuthorityFingerprint = nil
                if let staleSessionId {
                    authorityBoundWebRTCBootstrapSessionIds.remove(staleSessionId)
                }
                connectionCodeExpiryTask?.cancel()
                connectionCodeExpiryTask = nil
                connectionCodeBootstrapTask?.cancel()
                connectionCodeBootstrapTask = nil
            }
            if localConnectionCode != nil,
               currentRole == .offerer,
               activeConnectionCodeLeaseMode != requestedLeaseMode {
                await disconnect()
            }
            let admission = try await requestAdmissionLease(for: localBinding)
            #if canImport(UIKit)
            let localDeviceName = AppleMobileDeviceIdentity.currentSnapshot().deviceName
            #else
            let localDeviceName = Host.current().localizedName ?? "Apple Device"
            #endif
            let lease = try await signalServer.registerConnectionCode(
                admissionToken: admission.token,
                deviceName: localDeviceName,
                validDuration: requestedLeaseMode.validDuration
            )
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: lease.signalingServerOrigin,
                wsPath: lease.wsPath
            )
            webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lease.sessionID] = lease.turnAdmissionToken
            if let mediaAdmissionToken = lease.mediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[lease.sessionID] = mediaAdmissionToken
            }
            setCurrentPathSignalingEndpoint(sessionId: lease.sessionID, endpoint: signalingEndpoint)
            localConnectionCode = lease.code
            localConnectionCodeExpiresAt = Date().addingTimeInterval(lease.expiresIn)
            activeConnectionCodeLeaseMode = requestedLeaseMode
            localConnectionSessionId = lease.sessionID
            activeConnectionCodeAuthorityDeviceId = localBinding.deviceId
            activeConnectionCodeAuthorityFingerprint = localBinding.protocolPublicKeyFingerprint
            authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)
            currentRole = .offerer
            state = .connecting(sessionId: lease.sessionID)
            readiness = .idle
            lastError = nil
            if let expiresAt = localConnectionCodeExpiresAt {
                scheduleConnectionCodeLeaseInvalidation(
                    code: lease.code,
                    sessionID: lease.sessionID,
                    expiresAt: expiresAt
                )
            }

            connectionCodeBootstrapTask?.cancel()
            connectionCodeBootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.localConnectionCode == lease.code,
                      self.localConnectionSessionId == lease.sessionID,
                      self.currentRole == .offerer else { return }
                do {
                    try await self.connect(
                        sessionId: lease.sessionID,
                        remoteName: nil,
                        remotePeerDeviceId: nil,
                        source: .code,
                        role: .offerer
                    )
                    self.localConnectionCode = lease.code
                    self.localConnectionSessionId = lease.sessionID
                } catch is CancellationError {
                    // Cancellation is expected during regenerate/disconnect.
                } catch {
                    guard self.localConnectionCode == lease.code else { return }
                    let msg = error.localizedDescription
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.readiness = .idle
                }
                if self.connectionCodeBootstrapTask?.isCancelled == false {
                    self.connectionCodeBootstrapTask = nil
                }
            }

            return lease.code
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            state = .failed(msg)
            readiness = .idle
            return nil
        }
    }

    private func scheduleConnectionCodeLeaseInvalidation(
        code: String,
        sessionID: String,
        expiresAt: Date
    ) {
        connectionCodeExpiryTask?.cancel()
        let delay = max(
            0,
            expiresAt
                .addingTimeInterval(-Self.connectionCodeMinimumReusableTime)
                .timeIntervalSinceNow
        )
        connectionCodeExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.localConnectionCode == code,
                  self.localConnectionSessionId == sessionID,
                  !Self.isReusableConnectionCodeLease(expiresAt: self.localConnectionCodeExpiresAt) else {
                return
            }
            SkyBridgeLogger.shared.info("ℹ️ 本地连接码租约到期，已清理旧码: reason=connection_code_lease_expired code=\(code)")
            self.connectionCodeExpiryTask = nil
            self.localConnectionCode = nil
            self.localConnectionCodeExpiresAt = nil
            self.activeConnectionCodeLeaseMode = nil
            self.activeConnectionCodeAuthorityDeviceId = nil
            self.activeConnectionCodeAuthorityFingerprint = nil
            self.authorityBoundWebRTCBootstrapSessionIds.remove(sessionID)
        }
    }

    @discardableResult
    public func generateConnectLink(validDuration: TimeInterval = 300) async -> String? {
        disarmIdleConnectionReminder(clearPrompt: true)
        do {
            let localBinding = try await currentPathLocalBinding()
            let admission = try await requestAdmissionLease(for: localBinding)
            #if canImport(UIKit)
            let localDeviceName = AppleMobileDeviceIdentity.currentSnapshot().deviceName
            #else
            let localDeviceName = Host.current().localizedName ?? "Apple Device"
            #endif
            let lease = try await signalServer.registerSession(
                admissionToken: admission.token,
                validDuration: validDuration
            )
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: lease.signalingServerOrigin,
                wsPath: lease.wsPath
            )
            webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
            webrtcTurnAdmissionTokenBySessionId[lease.sessionID] = lease.turnAdmissionToken
            if let mediaAdmissionToken = lease.mediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[lease.sessionID] = mediaAdmissionToken
            }
            setCurrentPathSignalingEndpoint(sessionId: lease.sessionID, endpoint: signalingEndpoint)
            let kemPublicKeys = KEMPublicKeyInfo.normalizedValidKeys(
                try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
            )
            guard !kemPublicKeys.isEmpty else {
                throw NSError(
                    domain: "CrossNetworkWebRTCManager",
                    code: 8405,
                    userInfo: [NSLocalizedDescriptionKey: "本机没有可用于二维码 OOB 引导的 PQC KEM 公钥"]
                )
            }

            let qrData = DynamicQRCodeData(
                version: 7,
                sessionID: lease.sessionID,
                qrBootstrapToken: lease.qrBootstrapToken,
                signalingServerOrigin: lease.signalingServerOrigin,
                deviceID: localBinding.deviceId,
                deviceName: localDeviceName,
                deviceType: P2PDeviceType.iOS.rawValue,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                capabilities: ["cross-network", "p2p"],
                protocolSigningAlgorithm: localBinding.protocolSigningAlgorithm,
                protocolPublicKeyBytes: localBinding.protocolPublicKeyBytes,
                protocolPublicKeyFingerprint: localBinding.protocolPublicKeyFingerprint,
                kemPublicKeys: kemPublicKeys,
                signature: nil,
                signatureTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                expiresAt: Date().addingTimeInterval(validDuration)
            )
            let signature = try await signCurrentPathPayload(
                qrData.canonicalSignaturePayload,
                algorithm: localBinding.protocolSigningAlgorithm
            )
            let signed = DynamicQRCodeData(
                version: qrData.version,
                sessionID: qrData.sessionID,
                qrBootstrapToken: qrData.qrBootstrapToken,
                signalingServerOrigin: qrData.canonicalSignalingServerOrigin,
                deviceID: qrData.deviceID,
                deviceName: qrData.deviceName,
                deviceType: qrData.deviceType,
                osVersion: qrData.osVersion,
                capabilities: qrData.normalizedCapabilities,
                protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
                protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
                protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
                kemPublicKeys: qrData.kemPublicKeys,
                signature: signature,
                signatureTimestampMs: qrData.signatureTimestampMs,
                expiresAt: qrData.expiresAt
            )
            let jsonData = try JSONEncoder().encode(signed)
            let payload = jsonData.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let link = "skybridge://connect/\(payload)"

            currentConnectLink = link
            currentRole = .offerer
            localConnectionSessionId = lease.sessionID
            authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)
            state = .connecting(sessionId: lease.sessionID)
            readiness = .idle
            lastError = nil

            connectionCodeBootstrapTask?.cancel()
            connectionCodeBootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.connect(
                        sessionId: lease.sessionID,
                        remoteName: nil,
                        remotePeerDeviceId: nil,
                        source: .code,
                        role: .offerer
                    )
                } catch is CancellationError {
                } catch {
                    self.lastError = error.localizedDescription
                    self.state = .failed(error.localizedDescription)
                    self.readiness = .idle
                }
            }

            return link
        } catch {
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
            readiness = .idle
            return nil
        }
    }

    public func disconnect(clearSnapshot: Bool = true) async {
        disarmIdleConnectionReminder(clearPrompt: true)
        if clearSnapshot, let sessionId = activeRemoteDesktopSessionId ?? currentSessionId {
            await notifyRemoteDesktopTerminalSessionIfNeeded(
                sessionId: sessionId,
                kind: .normal,
                reason: "explicit_disconnect"
            )
        }
        suppressSignalingRecovery = true
        defer { suppressSignalingRecovery = false }
        for (_, task) in signalingRecoveryTasksBySessionId {
            task.cancel()
        }
        signalingRecoveryTasksBySessionId.removeAll()
        if let signaling {
            await signaling.close()
        }
        signaling = nil
        signalingShardKey = nil
        signalingHealth = .healthy
        signalingGenerationBySessionId.removeAll()
        activeSignalingHandleBySessionId.removeAll()
        session?.close()
        session = nil
        if let currentSessionId {
            clearWebRTCSecureEnvelopeState(for: currentSessionId)
        }
        currentSessionId = nil
        lastScreenData = nil
#if canImport(WebRTC)
        installRemoteVideoTrack(nil)
        remoteVideoTrackReadyForPromotion = false
        remoteVideoTrackHasRenderedFrame = false
        remoteVideoTrackHasReceiverFrameEvidence = false
        nativeRenderEvidenceSource = nil
        nativeRenderUISurface = nil
        nativePromotionState = "idle"
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeTask = nil
        nativeVideoProbeActive = false
        nativeVideoProbeCooldownUntil = .distantPast
        remoteVideoTrackVisibleRenderTraceEpoch = nil
        lastNativeReceiverFrameStatusAt = .distantPast
        remoteVideoTrackFrameSize = .zero
        remoteAudioTrackHasReceivedFirstPacket = false
        remoteVideoTrackHasReceivedFirstPacket = false
        remoteVideoTrackDetectedAt = nil
        lastScreenDataAt = nil
#endif
        handshakeDriver = nil
        handshakePeerId = nil
        sessionKeys = nil
        remoteDeviceName = nil
        remoteDeviceId = nil
        localConnectionCode = nil
        localConnectionCodeExpiresAt = nil
        activeConnectionCodeLeaseMode = nil
        activeConnectionCodeAuthorityDeviceId = nil
        activeConnectionCodeAuthorityFingerprint = nil
        authorityBoundWebRTCBootstrapSessionIds.removeAll()
        currentConnectLink = nil
        localConnectionSessionId = nil
        currentRole = nil
        connectionCodeBootstrapTask?.cancel()
        connectionCodeBootstrapTask = nil
        connectionCodeExpiryTask?.cancel()
        connectionCodeExpiryTask = nil
        strictPQCClassicBootstrapTimeoutTasksBySessionId.values.forEach { $0.cancel() }
        strictPQCClassicBootstrapTimeoutTasksBySessionId.removeAll()
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
        offerResendTask?.cancel()
        offerResendTask = nil
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = nil
        remotePeerPingTask?.cancel()
        remotePeerPingTask = nil
        remotePeerLivenessWatchdogTask?.cancel()
        remotePeerLivenessWatchdogTask = nil
        latestLocalOfferBySessionId.removeAll()
        latestLocalAnswerBySessionId.removeAll()
        localICECandidatesBySessionId.removeAll()
        webrtcSignalingAuthTokenBySessionId.removeAll()
        webrtcTurnAdmissionTokenBySessionId.removeAll()
        webrtcMediaAdmissionTokenBySessionId.removeAll()
        mediaAdmissionLeaseBackoffBySessionId.removeAll()
        mediaAdmissionLeaseInFlightSessionIds.removeAll()
        mediaAdmissionLeaseFailureReasonBySessionId.removeAll()
        mediaAdmissionAuthorityLostSessionIds.removeAll()
        mediaAdmissionRelayEndpointBySessionId.removeAll()
        mediaAdmissionRelayRoleBySessionId.removeAll()
        mediaAdmissionEndpointUnusableCountsBySessionReason.removeAll()
        currentPathExpectedRemoteAuthorityBySessionId.removeAll()
        currentPathAdditionalProtocolFingerprintsBySessionId.removeAll()
        currentPathSignalingOriginBySessionId.removeAll()
        currentPathSignalingWebSocketPathBySessionId.removeAll()
        remoteAppActivityAtBySessionId.removeAll()
        handshakeStartedSessionIds.removeAll()
        inboundInitialHandshakeResponderSessionIds.removeAll()
        inboundClassicAuthorityBootstrapSessionIds.removeAll()
        strictPQCClassicBootstrapOnlySessionIds.removeAll()
        rekeyInProgressSessionIds.removeAll()
        rekeyCompletedSessionIds.removeAll()
        inboundRekeyResponderSessionIds.removeAll()
        strictPQCRequestedBySessionId.removeAll()
        lastPairingIdentityExchangeSentAtByPeerId.removeAll()
        failAllFileTransferWaiters(FileTransferWaitError.cancelled)
        cleanupInboundFileTransfers()
        if let inboundQueue {
            await inboundQueue.finish()
        }
        inboundQueue = nil
        if let screenInboundQueue {
            await screenInboundQueue.finish()
        }
        screenInboundQueue = nil
        receiveTask?.cancel()
        receiveTask = nil
        screenReceiveTask?.cancel()
        screenReceiveTask = nil
        if clearSnapshot {
            activeSessionReconnectTimeoutTask?.cancel()
            activeSessionReconnectTimeoutTask = nil
            activeSessionSnapshot = nil
            sessionSnapshotMetadataBySessionId.removeAll()
        }
        state = .idle
        readiness = .idle
    }

#if canImport(WebRTC)
    private func installRemoteVideoTrack(_ track: RTCVideoTrack?) {
        let currentTrackId = WebRTCSession.normalizedRemoteVideoTrackId(remoteVideoTrack?.trackId)
        let incomingTrackId = WebRTCSession.normalizedRemoteVideoTrackId(track?.trackId)
        let tracksShareNativeBacking = CrossNetworkWebRTCNativeVideoPolicy.remoteVideoTracksShareNativeBacking(
            remoteVideoTrack,
            track
        )
        guard !tracksShareNativeBacking else {
            scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: "track-unchanged")
            return
        }
        let isTrackRebind =
            !currentTrackId.isEmpty
            && currentTrackId == incomingTrackId
            && track != nil
        if !incomingTrackId.isEmpty, isTrackRebind {
            SkyBridgeLogger.shared.info(
                "🔁 WebRTC 原生视频轨实例已更换，重新绑定 renderer: trackId=\(incomingTrackId)"
            )
        }
        let preservedFrameSize = remoteVideoTrackFrameSize
        let preservedFirstPacket = remoteVideoTrackHasReceivedFirstPacket
        let preservedReceiverFrameEvidence = remoteVideoTrackHasReceiverFrameEvidence

        if let currentTrack = remoteVideoTrack,
           let heartbeatRenderer = remoteVideoHeartbeatRenderer {
            currentTrack.remove(heartbeatRenderer)
        }

        remoteVideoTrackConfirmationTask?.cancel()
        remoteVideoTrackConfirmationTask = nil
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeTask = nil
        nativeVideoProbeActive = false
        nativeVideoProbeCooldownUntil = .distantPast
        remoteVideoTrackRenderEpoch &+= 1
        remoteVideoTrackVisibleRenderTraceEpoch = nil
        lastNativeReceiverFrameStatusAt = .distantPast
        remoteVideoTrack = track
        let shouldPreservePacketEvidence = track != nil && isTrackRebind && preservedFirstPacket
        remoteVideoTrackReadyForPromotion = false
        remoteVideoTrackHasRenderedFrame = false
        remoteVideoTrackHasReceiverFrameEvidence = shouldPreservePacketEvidence ? preservedReceiverFrameEvidence : false
        nativeRenderEvidenceSource = nil
        nativeRenderUISurface = nil
        nativePromotionState = shouldPreservePacketEvidence ? "track-rebound" : "track-installed"
        remoteVideoTrackFrameSize = shouldPreservePacketEvidence ? preservedFrameSize : .zero
        remoteVideoTrackHasReceivedFirstPacket = shouldPreservePacketEvidence ? preservedFirstPacket : false
        remoteVideoTrackDetectedAt = track == nil
            ? nil
            : (isTrackRebind ? remoteVideoTrackDetectedAt ?? Date() : Date())
        remoteVideoHeartbeatRenderer = nil

        guard let track else {
            remoteVideoTrackReadyForPromotion = false
            remoteVideoTrackHasReceiverFrameEvidence = false
            nativeRenderEvidenceSource = nil
            nativeRenderUISurface = nil
            nativePromotionState = "idle"
            remoteVideoTrackHasReceivedFirstPacket = false
            nativeVideoProbeActive = false
            return
        }

        track.isEnabled = true
        SkyBridgeSmokeTraceWriter.appendStatus(
            "native-video-track-install trackId=\(track.trackId) enabled=\(track.isEnabled ? 1 : 0) epoch=\(remoteVideoTrackRenderEpoch)"
        )

        let heartbeatRenderer = RemoteVideoTrackHeartbeatRenderer()
        heartbeatRenderer.trackId = track.trackId
        heartbeatRenderer.sessionId = currentSessionId ?? "-"
        heartbeatRenderer.onSize = { [weak self] size in
            Task { @MainActor [weak self] in
                self?.noteRemoteVideoTrackResolutionAvailable(size, source: "heartbeat-set-size")
            }
        }
        heartbeatRenderer.onFrame = { [weak self] size in
            Task { @MainActor [weak self] in
                self?.noteRemoteVideoTrackRenderedFrame(size, source: "heartbeat-renderer")
            }
        }
        remoteVideoHeartbeatRenderer = heartbeatRenderer
        track.add(heartbeatRenderer)
        scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: "track-installed")
        RemoteDesktopManager.instance.handleCrossNetworkNativeVideoWarmupEvidence(
            reason: "native-track-installed"
        )
        if remoteVideoTrackHasReceiverFrameEvidence {
            scheduleNativeRenderProbeIfNeeded(trigger: "track-installed")
        }
    }

    @MainActor
    func currentRemoteVideoTrackRenderToken(trackId: String?) -> UInt64 {
        let observedTrackId = trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expectedTrackId = remoteVideoTrack?.trackId.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTrackId.isEmpty,
           observedTrackId != expectedTrackId {
            return remoteVideoTrackRenderEpoch
        }
        return remoteVideoTrackRenderEpoch
    }

    @MainActor
    private func scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: String) {
        guard currentSessionId != nil, remoteVideoTrack != nil else { return }
        guard !remoteVideoTrackHasRenderedFrame else { return }
        let sessionIdAtStart = currentSessionId
        remoteVideoTrackConfirmationTask?.cancel()
        remoteVideoTrackConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard self.currentSessionId != nil, self.remoteVideoTrack != nil else { return }
            guard !self.remoteVideoTrackHasRenderedFrame else { return }
            guard self.bestAvailableRemoteVideoEvidenceSize() != nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(2_650))
            } catch {
                return
            }
            guard self.currentSessionId == sessionIdAtStart,
                  self.remoteVideoTrack != nil,
                  !self.remoteVideoTrackHasRenderedFrame else { return }
            let probable = self.remoteVideoTrackHasReceivedFirstPacket
                ? "renderer-bound-no-native-frame"
                : "receiver-stats-zero-or-track-muted"
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC 原生视频轨 3 秒内无真实渲染帧: session=\(self.currentSessionId ?? "-") probable=\(probable) firstPacket=\(self.remoteVideoTrackHasReceivedFirstPacket) fallbackEvidence=\(trigger)"
            )
        }
    }

    @MainActor
    private func scheduleNativeRenderProbeIfNeeded(
        trigger: String,
        allowsPacketOnlyEvidence: Bool = false
    ) {
        guard let sessionId = currentSessionId,
              let track = remoteVideoTrack else { return }
        guard remoteVideoTrackHasReceiverFrameEvidence || allowsPacketOnlyEvidence else { return }
        guard !remoteVideoTrackHasRenderedFrame else { return }
        guard !nativeVideoProbeActive else { return }
        let now = Date()
        guard now >= nativeVideoProbeCooldownUntil else { return }

        let trackId = track.trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        let epoch = remoteVideoTrackRenderEpoch
        let evidenceSize = bestAvailableRemoteVideoEvidenceSize()
        let evidenceSizeLabel = evidenceSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeActive = true
        nativePromotionState = remoteVideoTrackHasReceiverFrameEvidence
            ? "native-render-probe-active"
            : "native-render-probe-packet-active"
        SkyBridgeLogger.shared.info(
            "🎬 native-render-probe-start session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger) receiverEvidence=\(remoteVideoTrackHasReceiverFrameEvidence) evidenceSize=\(evidenceSizeLabel) action=raise-rtc-mtl-video-view"
        )
        SkyBridgeSmokeTraceWriter.appendStatus(
            "native-render-probe-start session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger)"
        )
        nativeVideoProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(2_500))
            } catch {
                return
            }
            guard self.currentSessionId == sessionId,
                  self.remoteVideoTrack != nil,
                  self.remoteVideoTrackRenderEpoch == epoch,
                  !self.remoteVideoTrackHasRenderedFrame else {
                return
            }
            self.nativeVideoProbeActive = false
            self.nativeVideoProbeTask = nil
            self.nativeVideoProbeCooldownUntil = Date().addingTimeInterval(2.0)
            self.nativePromotionState = "native-render-probe-timeout"
            let size = self.bestAvailableRemoteVideoEvidenceSize()
            let sizeLabel = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
            SkyBridgeLogger.shared.warning(
                "⚠️ native-render-probe-timeout session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger) receiverEvidence=\(self.remoteVideoTrackHasReceiverFrameEvidence) evidenceSize=\(sizeLabel) fallback=source-jpeg"
            )
            SkyBridgeSmokeTraceWriter.appendStatus(
                "native-render-probe-timeout session=\(sessionId) trackId=\(trackId.isEmpty ? "-" : trackId) epoch=\(epoch) trigger=\(trigger)"
            )
            self.scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: "native-render-probe-timeout")
        }
    }

    @MainActor
    func noteRemoteVideoTrackRenderedFrame(_ size: CGSize, source: String) {
        noteRemoteVideoTrackRenderedFrame(
            size,
            source: source,
            uiSurface: "unknown",
            trackId: nil,
            renderEpoch: nil
        )
    }

    @MainActor
    func noteRemoteVideoTrackRenderedFrame(_ size: CGSize, source: String, trackId: String?) {
        noteRemoteVideoTrackRenderedFrame(
            size,
            source: source,
            uiSurface: "unknown",
            trackId: trackId,
            renderEpoch: nil
        )
    }

    @MainActor
    func noteRemoteVideoTrackRenderedFrame(
        _ size: CGSize,
        source: String,
        uiSurface: String,
        trackId: String?,
        renderEpoch: UInt64?
    ) {
        guard size.width > 0, size.height > 0 else { return }
        guard currentSessionId != nil else { return }
        let codedSize = size
        let normalizedFrameSize = normalizedNativeVideoVisibleFrameSize(forCodedSize: codedSize)
        let visibleSize = normalizedFrameSize.visibleSize
        if CrossNetworkWebRTCNativeVideoPolicy.isActualNativeRenderEvidence(source: source) {
            let hasInboundRenderContext =
                remoteVideoTrackHasRenderedFrame
                || nativeVideoProbeActive
                || remoteVideoTrackHasReceiverFrameEvidence
                || remoteVideoTrackHasReceivedFirstPacket
            guard hasInboundRenderContext else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=probe-inactive trackId=\(trackId ?? "-") epoch=\(renderEpoch.map(String.init) ?? "-")"
                )
                return
            }
            guard let expectedTrackId = remoteVideoTrack?.trackId.trimmingCharacters(in: .whitespacesAndNewlines),
                  !expectedTrackId.isEmpty else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=no-current-track"
                )
                return
            }
            let observedTrackId = trackId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard observedTrackId == expectedTrackId else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=track-mismatch observedTrack=\(observedTrackId ?? "-") expectedTrack=\(expectedTrackId)"
                )
                return
            }
            guard let renderEpoch,
                  renderEpoch == remoteVideoTrackRenderEpoch else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=epoch-mismatch observedTrack=\(observedTrackId ?? "-") expectedTrack=\(expectedTrackId) observedEpoch=\(renderEpoch.map(String.init) ?? "-") expectedEpoch=\(remoteVideoTrackRenderEpoch)"
                )
                return
            }
        }
        noteCurrentSessionActivity()
        remoteVideoTrackFrameSize = visibleSize
        remoteVideoTrackHasReceivedFirstPacket = true
        if source == "receiver-stats" || source == "heartbeat-renderer" {
            let isReceiverStatsEvidence = source == "receiver-stats"
            nativePromotionState = isReceiverStatsEvidence
                ? "receiver-frame-evidence"
                : "track-renderer-frame-evidence"
            let visibleSource = normalizedFrameSize.usedEvenPadding
                ? "inferred-even-padding-from-stream-config"
                : "coded-frame"
            let now = Date()
            let shouldAppendReceiverStatus = !remoteVideoTrackHasReceiverFrameEvidence
                || now.timeIntervalSince(lastNativeReceiverFrameStatusAt) >= 5
            if shouldAppendReceiverStatus {
                lastNativeReceiverFrameStatusAt = now
                SkyBridgeSmokeTraceWriter.appendStatus(
                    "native-receiver-frame session=\(currentSessionId ?? "-") size=\(Int(visibleSize.width))x\(Int(visibleSize.height)) visibleSize=\(Int(visibleSize.width))x\(Int(visibleSize.height)) codedSize=\(Int(codedSize.width))x\(Int(codedSize.height)) evenPadding=\(normalizedFrameSize.usedEvenPadding ? 1 : 0) visibleSource=\(visibleSource) source=\(source)"
                )
            }
            if !remoteVideoTrackHasReceiverFrameEvidence {
                remoteVideoTrackHasReceiverFrameEvidence = true
                let warmupReason = isReceiverStatsEvidence
                    ? "native-receiver-frame-evidence"
                    : "native-heartbeat-frame-evidence"
                RemoteDesktopManager.instance.handleCrossNetworkNativeVideoWarmupEvidence(
                    reason: warmupReason
                )
            }
            scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: source)
            scheduleNativeRenderProbeIfNeeded(trigger: source)
        }
        guard CrossNetworkWebRTCNativeVideoPolicy.isActualNativeRenderEvidence(source: source) else { return }
        nativeRenderEvidenceSource = source
        nativeRenderUISurface = uiSurface
        nativePromotionState = "visible-render-evidence"
        finishNativeRenderProbeAfterVisibleFrame()
        appendNativeRenderFrameTraceIfNeeded(
            visibleSize: visibleSize,
            codedSize: codedSize,
            source: source,
            uiSurface: uiSurface
        )
        markRemoteVideoTrackReadyForPromotion(size: visibleSize, source: source)
        remoteVideoTrackConfirmationTask?.cancel()
        remoteVideoTrackConfirmationTask = nil
        RemoteDesktopManager.instance.noteCrossNetworkNativeVideoFrame(visibleSize)
        if !remoteVideoTrackHasRenderedFrame {
            remoteVideoTrackHasRenderedFrame = true
            nativePromotionState = "native-ready-advertised"
            SkyBridgeLogger.shared.info(
                "🎬 WebRTC 原生视频轨已收到首帧: visible=\(Int(visibleSize.width))x\(Int(visibleSize.height)) coded=\(Int(codedSize.width))x\(Int(codedSize.height)) source=\(source) nativeRenderEvidenceSource=\(source) nativePromotionState=\(nativePromotionState)"
            )
            RemoteDesktopManager.instance.handleCrossNetworkNativeVideoTrackRenderedFirstFrame()
        }
    }

    @MainActor
    private func finishNativeRenderProbeAfterVisibleFrame() {
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeTask = nil
        nativeVideoProbeActive = false
        nativeVideoProbeCooldownUntil = .distantPast
    }

    @MainActor
    private func appendNativeRenderFrameTraceIfNeeded(
        visibleSize: CGSize,
        codedSize: CGSize,
        source: String,
        uiSurface: String
    ) {
        guard remoteVideoTrackVisibleRenderTraceEpoch != remoteVideoTrackRenderEpoch else { return }
        remoteVideoTrackVisibleRenderTraceEpoch = remoteVideoTrackRenderEpoch
        SkyBridgeSmokeTraceWriter.appendStatus(
            "native-render-frame session=\(currentSessionId ?? "-") size=\(Int(visibleSize.width))x\(Int(visibleSize.height)) visibleSize=\(Int(visibleSize.width))x\(Int(visibleSize.height)) codedSize=\(Int(codedSize.width))x\(Int(codedSize.height)) source=\(source) nativeRenderEvidenceSource=\(source) nativePromotionState=\(nativePromotionState) uiSurface=\(uiSurface)"
        )
    }

    @MainActor
    private func normalizedNativeVideoVisibleFrameSize(
        forCodedSize codedSize: CGSize
    ) -> (visibleSize: CGSize, usedEvenPadding: Bool) {
        guard let expectedVisibleSize = expectedNativeVideoVisibleFrameSize() else {
            return (codedSize, false)
        }
        let expectedWidth = Int(expectedVisibleSize.width)
        let expectedHeight = Int(expectedVisibleSize.height)
        guard expectedWidth > 0, expectedHeight > 0 else {
            return (codedSize, false)
        }
        let codedWidth = Int(codedSize.width)
        let codedHeight = Int(codedSize.height)
        let expectedCodedWidth = CrossNetworkWebRTCNativeVideoPolicy.evenNativeVideoBackingDimension(expectedWidth)
        let expectedCodedHeight = CrossNetworkWebRTCNativeVideoPolicy.evenNativeVideoBackingDimension(expectedHeight)
        if codedWidth == expectedCodedWidth, codedHeight == expectedCodedHeight {
            return (expectedVisibleSize, expectedCodedWidth != expectedWidth || expectedCodedHeight != expectedHeight)
        }
        if codedWidth == expectedWidth, codedHeight == expectedHeight {
            return (expectedVisibleSize, false)
        }
        return (codedSize, false)
    }

    @MainActor
    private func expectedNativeVideoVisibleFrameSize() -> CGSize? {
        if let expected = RemoteDesktopManager.instance.expectedCrossNetworkNativeVideoVisibleFrameSize() {
            return expected
        }
        return CrossNetworkWebRTCNativeVideoPolicy.requestedSmokeNativeVideoVisibleFrameSize()
    }

    @MainActor
    func noteRemoteVideoTrackReceivedFirstPacket(source: String) {
        guard currentSessionId != nil else { return }
        noteCurrentSessionActivity()
        remoteVideoTrackHasReceivedFirstPacket = true
        if remoteVideoTrackHasRenderedFrame { return }
        SkyBridgeLogger.shared.debug("ℹ️ WebRTC 原生视频轨已收到首个 RTP 包，等待分辨率证据后确认首帧 source=\(source)")
        scheduleNativeRenderProbeIfNeeded(trigger: source, allowsPacketOnlyEvidence: true)
    }

    @MainActor
    func noteRemoteAudioTrackReceivedFirstPacket(source: String) {
        guard currentSessionId != nil else { return }
        noteCurrentSessionActivity()
        remoteAudioTrackHasReceivedFirstPacket = true
        SkyBridgeLogger.shared.info("🎧 WebRTC 原生音频轨已收到首个 RTP 包 source=\(source)")
        RemoteDesktopManager.instance.handleCrossNetworkNativeAudioTrackReceivedFirstPacket()
    }

    @MainActor
    func noteRemoteVideoTrackResolutionAvailable(_ size: CGSize, source: String) {
        guard size.width > 0, size.height > 0 else { return }
        remoteVideoTrackFrameSize = normalizedNativeVideoVisibleFrameSize(forCodedSize: size).visibleSize
        if remoteVideoTrackHasRenderedFrame {
            return
        }
        if remoteVideoTrack != nil, CrossNetworkWebRTCNativeVideoPolicy.isActualNativeRenderEvidence(source: source) {
            scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: source)
        } else if remoteVideoTrackHasReceiverFrameEvidence {
            scheduleNativeRenderProbeIfNeeded(trigger: source)
        }
    }

    @MainActor
    private func bestAvailableRemoteVideoEvidenceSize() -> CGSize? {
        if remoteVideoTrackFrameSize.width > 0, remoteVideoTrackFrameSize.height > 0 {
            return remoteVideoTrackFrameSize
        }
        if let lastScreenData,
           lastScreenData.width > 0,
           lastScreenData.height > 0 {
            return CGSize(width: lastScreenData.width, height: lastScreenData.height)
        }
        let managerResolution = RemoteDesktopManager.instance.resolution
        if managerResolution.width > 0, managerResolution.height > 0 {
            return managerResolution
        }
        return nil
    }

    @MainActor
    private func maybeConfirmRemoteVideoTrackFromFallbackEvidence(
        now: Date = Date(),
        minimumTrackAge: TimeInterval = 0.5,
        maximumFallbackSilence: TimeInterval = 0.4
    ) {
        guard currentSessionId != nil else { return }
        guard remoteVideoTrack != nil else { return }
        guard !remoteVideoTrackHasRenderedFrame else { return }
        guard let remoteVideoTrackDetectedAt else { return }
        guard now.timeIntervalSince(remoteVideoTrackDetectedAt) >= minimumTrackAge else { return }
        guard let lastScreenDataAt else { return }
        guard now.timeIntervalSince(lastScreenDataAt) <= maximumFallbackSilence else { return }
        guard bestAvailableRemoteVideoEvidenceSize() != nil else { return }
        guard now.timeIntervalSince(lastFallbackOnlyNativeVideoDiagnosticAt) >= 2.0 else { return }
        lastFallbackOnlyNativeVideoDiagnosticAt = now
        SkyBridgeLogger.shared.debug(
            "ℹ️ fallback screen data confirms only degraded screen path; native promotion still waits for real RTP/render evidence session=\(currentSessionId ?? "-")"
        )
    }

    @MainActor
    private func markRemoteVideoTrackReadyForPromotion(size: CGSize, source: String) {
        guard size.width > 0, size.height > 0 else { return }
        remoteVideoTrackFrameSize = size
        if !remoteVideoTrackReadyForPromotion {
            remoteVideoTrackReadyForPromotion = true
            nativePromotionState = "promotion-ready"
            SkyBridgeLogger.shared.info(
                "🎬 WebRTC 原生视频轨已由真实渲染证据触发 promotion 条件: \(Int(size.width))x\(Int(size.height)) source=\(source)"
            )
            RemoteDesktopManager.instance.handleCrossNetworkNativeVideoTrackPromotionReady()
        }
    }

#endif

    public func dismissIdleConnectionPrompt() {
        idleConnectionPrompt = nil
    }

    func remoteDesktopRecoveryDebugSummary() -> String {
        let stateLabel: String = {
            switch state {
            case .idle:
                return "idle"
            case .connecting(let sessionId):
                return "connecting:\(sessionId)"
            case .connected(let sessionId):
                return "connected:\(sessionId)"
            case .failed(let message):
                return "failed:\(message)"
            }
        }()
        let readinessLabel: String = {
            switch readiness {
            case .idle:
                return "idle"
            case .transportReady(let sessionId):
                return "transport_ready:\(sessionId)"
            case .handshakeComplete(let sessionId, let suite):
                return "handshake_complete:\(sessionId):\(suite)"
            }
        }()
        let signalingLabel: String = {
            switch signalingHealth {
            case .healthy:
                return "healthy"
            case .degradedRecoverable:
                return "degraded_recoverable"
            case .degradedFatal:
                return "degraded_fatal"
            }
        }()
        return "session=\(currentSessionId ?? "-") state=\(stateLabel) readiness=\(readinessLabel) signaling=\(signalingLabel) suppressRecovery=\(suppressSignalingRecovery)"
    }

    private func noteCurrentSessionActivity() {
        guard let currentSessionId else { return }
        noteRemoteAppActivity(sessionId: currentSessionId)
    }

    public func disarmIdleConnectionReminder(clearPrompt: Bool = true) {
        idleConnectionReminderTask?.cancel()
        idleConnectionReminderTask = nil
        if clearPrompt {
            idleConnectionPrompt = nil
        }
    }

    public func armIdleConnectionReminderIfNeeded(after delay: TimeInterval = 180) {
        disarmIdleConnectionReminder(clearPrompt: true)

        guard let sessionId = currentSessionId else { return }
        guard isTransportReady || isHandshakeComplete || activeSessionSnapshot != nil else { return }

        let trimmedDeviceName = remoteDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deviceName = trimmedDeviceName.isEmpty
            ? RuntimeLocalization.string("idleConnection.notification.defaultDevice")
            : trimmedDeviceName

        idleConnectionReminderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard self.currentSessionId == sessionId else { return }
            guard self.isTransportReady || self.isHandshakeComplete || self.activeSessionSnapshot != nil else { return }

            if UIApplication.shared.applicationState == .active {
                self.idleConnectionPrompt = IdleConnectionPrompt(
                    sessionId: sessionId,
                    deviceName: deviceName
                )
            } else {
                let content = UNMutableNotificationContent()
                content.title = RuntimeLocalization.string("idleConnection.notification.title")
                content.body = String(
                    format: RuntimeLocalization.string("idleConnection.notification.body"),
                    deviceName
                )
                content.sound = .default
                content.categoryIdentifier = "IDLE_CONNECTION"
                content.userInfo = [
                    "kind": "IDLE_CONNECTION",
                    "sessionId": sessionId,
                    "deviceName": deviceName
                ]
                let request = UNNotificationRequest(
                    identifier: "idle-connection-\(sessionId)",
                    content: content,
                    trigger: nil
                )
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    SkyBridgeLogger.shared.warning(
                        "⚠️ 发送闲置连接提醒失败: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func shouldScheduleSignalingRecovery(for sessionId: String) -> Bool {
        Self.shouldScheduleSignalingRecovery(
            isTransportEstablished: isTransportEstablished(for: sessionId),
            isSessionConnecting: isSessionConnecting(for: sessionId),
            suppressRecovery: suppressSignalingRecovery
        )
    }

    private func isSessionConnecting(for sessionId: String) -> Bool {
        guard currentSessionId == sessionId else { return false }
        if case .connecting(let activeSessionId) = state {
            return activeSessionId == sessionId
        }
        return false
    }

    private func signalingURL(shardKey: String? = nil) throws -> URL {
        guard let baseWebSocketURLString = Self.resolvedSignalingWebSocketURLString(
            signalingOrigin: shardKey.flatMap { currentPathSignalingOriginBySessionId[$0] },
            signalingWebSocketPath: shardKey.flatMap { currentPathSignalingWebSocketPathBySessionId[$0] }
        ) else {
            throw SignalingRetryControllerError.invalidWebSocketURL(
                "missing current-path signaling endpoint"
            )
        }
        guard let wsURL = SignalingRetryController.validatedWebSocketURL(
            baseWebSocketURLString
        ) else {
            throw SignalingRetryControllerError.invalidWebSocketURL(
                baseWebSocketURLString
            )
        }
        guard let shardKey = shardKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shardKey.isEmpty else {
            return wsURL
        }
        guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return wsURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "shard" }
        queryItems.removeAll { $0.name == "st" }
        queryItems.removeAll { $0.name == "cv" }
        queryItems.removeAll { $0.name == "pv" }
        queryItems.append(URLQueryItem(name: "shard", value: shardKey))
        if let token = webrtcSignalingAuthTokenBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            queryItems.append(URLQueryItem(name: "st", value: token))
        }
        if let envVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envVersion.isEmpty {
            queryItems.append(URLQueryItem(name: "cv", value: envVersion))
        } else if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                queryItems.append(URLQueryItem(name: "cv", value: trimmed))
            }
        }
        let protocolVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        queryItems.append(URLQueryItem(name: "pv", value: protocolVersion.isEmpty ? "1" : protocolVersion))
        components.queryItems = queryItems
        return components.url ?? wsURL
    }

    private func ensureSignalingConnected(shardKey: String? = nil) async throws {
        let effectiveShardKey = (shardKey ?? currentSessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedShardKey = (effectiveShardKey?.isEmpty == false) ? effectiveShardKey : nil

        if let signaling, signalingShardKey != normalizedShardKey {
            let previousShardKey = signalingShardKey
            appendSmokeTrace("signaling reset shard=\(signalingShardKey ?? "-")->\(normalizedShardKey ?? "-")")
            await signaling.close()
            self.signaling = nil
            signalingShardKey = nil
            signalingHealth = .healthy
            if let previousShardKey {
                signalingGenerationBySessionId.removeValue(forKey: previousShardKey)
                activeSignalingHandleBySessionId.removeValue(forKey: previousShardKey)
            }
        }

        if let signaling {
            try await signaling.connectOrThrow()
            return
        }

        guard let sessionId = normalizedShardKey else {
            throw WebSocketSignalingClient.SignalingError.notConnected
        }

        let wsURL = try signalingURL(shardKey: sessionId)
        let newSignaling = WebSocketSignalingClient(url: wsURL, sessionId: sessionId, generation: 0)
        signaling = newSignaling
        signalingShardKey = sessionId
        signalingHealth = .healthy

        await newSignaling.setOnTrace { [weak self] (line: String) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.appendSmokeTrace("ws \(line)")
            }
        }
        await newSignaling.setOnEnvelope { [weak self] (env: WebRTCSignalingEnvelope) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.handleEnvelope(env)
            }
        }
        await newSignaling.setOnServerFrame { [weak self] (frame: WebSocketSignalingClient.SignalingServerFrame) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.handleServerFrame(frame)
            }
        }
        await newSignaling.setOnLifecycleEvent { [weak self] (event: WebSocketSignalingClient.SignalingLifecycleEvent) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.handleSignalingLifecycleEvent(event, sessionId: sessionId)
            }
        }
        appendSmokeTrace("signaling connect shard=\(sessionId) url=\(WebSocketSignalingClient.redactedURLString(wsURL))")
        try await newSignaling.connectOrThrow()
    }

    private func signalingGeneration(for sessionId: String) -> Int {
        signalingGenerationBySessionId[sessionId] ?? 0
    }

    private func handleSignalingLifecycleEvent(
        _ event: WebSocketSignalingClient.SignalingLifecycleEvent,
        sessionId: String
    ) {
        guard event.handleId.sessionId == sessionId else { return }

        if event.phase == .connecting || event.phase == .reconnecting {
            guard event.handleId.generation >= signalingGeneration(for: sessionId) else { return }
            signalingGenerationBySessionId[sessionId] = event.handleId.generation
            activeSignalingHandleBySessionId[sessionId] = event.handleId
        }

        guard event.handleId.generation == signalingGeneration(for: sessionId) else { return }
        guard activeSignalingHandleBySessionId[sessionId] == event.handleId else { return }

        let failureKind = event.failureClass ?? .transientServer

        switch event.phase {
        case .bound:
            signalingHealth = .healthy
            SkyBridgeLogger.shared.info(
                "♻️ signaling health recovered: session=\(sessionId) phase=bound summary=\(remoteDesktopRecoveryDebugSummary())"
            )
        case .closed:
            if Self.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: isHandshakeComplete(for: sessionId),
                suppressRecovery: suppressSignalingRecovery
            ) {
                noteDetachedSignalingAfterTransportEstablished(
                    sessionId: sessionId,
                    source: "lifecycle_closed",
                    failure: "transient_network"
                )
            }
        case .failed:
            if suppressSignalingRecovery {
                break
            }
            if Self.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: isHandshakeComplete(for: sessionId),
                suppressRecovery: suppressSignalingRecovery
            ) {
                noteDetachedSignalingAfterTransportEstablished(
                    sessionId: sessionId,
                    source: "lifecycle_failed",
                    failure: String(describing: failureKind),
                    fatal: Self.isFatalPostTransportFailure(failureKind)
                )
            } else if Self.isFatalPreTransportFailure(failureKind) {
                signalingHealth = .degradedFatal
                SkyBridgeLogger.shared.error(
                    "❌ signaling health fatal: session=\(sessionId) phase=failed preTransport=true summary=\(remoteDesktopRecoveryDebugSummary())"
                )
            } else {
                signalingHealth = .degradedRecoverable
                let recoveryScheduled = scheduleSignalingRecovery(
                    for: sessionId,
                    tokenExpired: failureKind == .tokenExpired
                )
                SkyBridgeLogger.shared.warning(
                    "⚠️ signaling health degraded: session=\(sessionId) phase=failed recoveryScheduled=\(recoveryScheduled) summary=\(remoteDesktopRecoveryDebugSummary())"
                )
            }
        default:
            break
        }
    }

    private func authenticatedEnvelope(_ envelope: WebRTCSignalingEnvelope) -> WebRTCSignalingEnvelope? {
        if envelope.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return envelope
        }
        guard let token = webrtcSignalingAuthTokenBySessionId[envelope.sessionId],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "缺少 signaling auth token"
            state = .failed("Missing signaling authorization")
            readiness = .idle
            return nil
        }
        return WebRTCSignalingEnvelope(
            sessionId: envelope.sessionId,
            from: envelope.from,
            to: envelope.to,
            type: envelope.type,
            payload: envelope.payload,
            authToken: token,
            sentAt: envelope.sentAt
        )
    }

    private func sendEnvelope(_ envelope: WebRTCSignalingEnvelope, retries: Int = 2) async {
        let directedEnvelope: WebRTCSignalingEnvelope = {
            guard envelope.to == nil,
                  let remoteId = remoteDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !remoteId.isEmpty,
                  remoteId != envelope.from else {
                return envelope
            }
            return WebRTCSignalingEnvelope(
                sessionId: envelope.sessionId,
                from: envelope.from,
                to: remoteId,
                type: envelope.type,
                payload: envelope.payload,
                authToken: envelope.authToken,
                sentAt: envelope.sentAt
            )
        }()

        guard let authorizedEnvelope = authenticatedEnvelope(directedEnvelope) else { return }
        let handshakeComplete = isHandshakeComplete(for: authorizedEnvelope.sessionId)
        let shouldDeferRecovery = Self.shouldDeferSignalingSendRecovery(
            isHandshakeComplete: handshakeComplete,
            suppressRecovery: suppressSignalingRecovery,
            messageType: authorizedEnvelope.type
        )
        appendSmokeTrace("tx \(describeEnvelope(authorizedEnvelope)) retries=\(retries)")
        if shouldDeferRecovery {
            guard let signaling else {
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=missing_client"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) phase=missing_client"
                )
                return
            }

            let lifecyclePhase = await signaling.currentLifecyclePhase()
            guard lifecyclePhase == .bound else {
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=\(lifecyclePhase.rawValue)"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) phase=\(lifecyclePhase.rawValue)"
                )
                return
            }

            do {
                try await signaling.send(authorizedEnvelope)
                appendSmokeTrace("tx-ok \(describeEnvelope(authorizedEnvelope))")
                return
            } catch {
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=\(lifecyclePhase.rawValue) error=\(error.localizedDescription)"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) phase=\(lifecyclePhase.rawValue) error=\(error.localizedDescription)"
                )
                return
            }
        }
        do {
            try await signalingRetryController.sendWithRetry(
                retries: retries,
                reconnectIfNeeded: { [weak self] in
                    try? await self?.signaling?.connectOrThrow()
                },
                send: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.ensureSignalingConnected(shardKey: authorizedEnvelope.sessionId)
                    guard let signaling = self.signaling else {
                        throw WebSocketSignalingClient.SignalingError.notConnected
                    }
                    try await signaling.send(authorizedEnvelope)
                }
            )
            appendSmokeTrace("tx-ok \(describeEnvelope(authorizedEnvelope))")
        } catch SignalingRetryControllerError.invalidWebSocketURL {
            lastError = "信令服务 URL 无效"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=invalid_websocket_url")
            failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                reason: lastError ?? "信令服务 URL 无效",
                trigger: "send_invalid_url_\(authorizedEnvelope.type.rawValue)"
            )
        } catch SignalingRetryControllerError.attemptTimedOut {
            lastError = "信令发送失败: 请求超时"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=attempt_timed_out")
            failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                reason: lastError ?? "信令发送失败: 请求超时",
                trigger: "send_timeout_\(authorizedEnvelope.type.rawValue)"
            )
        } catch is CancellationError {
            appendSmokeTrace("tx-cancel \(describeEnvelope(authorizedEnvelope))")
            return
        } catch {
            lastError = "信令发送失败: \(error.localizedDescription)"
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=\(error.localizedDescription)")
            failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                reason: lastError ?? "信令发送失败",
                trigger: "send_error_\(authorizedEnvelope.type.rawValue)"
            )
        }
    }

    private func failConnectingSessionIfNeeded(
        sessionId: String,
        reason: String,
        trigger: String
    ) {
        guard currentSessionId == sessionId else { return }
        guard isSessionConnecting(for: sessionId) else { return }

        let message = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        SkyBridgeLogger.shared.error(
            "❌ cross-network connect failed before transportReady: session=\(sessionId) trigger=\(trigger) err=\(message)"
        )
        applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
        state = .failed(message)
        readiness = .idle
    }

    private func handleServerFrame(_ frame: WebSocketSignalingClient.SignalingServerFrame) {
        appendSmokeTrace(
            "server-frame type=\(frame.type) session=\(frame.sessionId ?? "-") error=\(frame.error ?? "-") what=\(frame.what ?? "-")"
        )
        guard frame.isError else { return }
        let sessionId = frame.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = frame.error ?? "unknown_signaling_error"
        let failureClass = Self.classifySignalingFailureReason(reason)

        if sessionId == nil,
           reason == "server_error",
           isTransportEstablished {
            SkyBridgeLogger.shared.warning("ℹ️ ignore unscoped signaling server_error after transport establishment")
            return
        }

        guard let sessionId else {
            SkyBridgeLogger.shared.error("❌ signaling server rejected frame: session=- error=\(reason)")
            lastError = "Signaling error: \(reason)"
            state = .failed(lastError ?? "Signaling error")
            readiness = .idle
            return
        }

        guard currentSessionId == sessionId else { return }
        if suppressSignalingRecovery { return }

        if Self.shouldUseOnDemandSignalingAfterTransportFailure(
            isHandshakeComplete: isHandshakeComplete(for: sessionId),
            suppressRecovery: suppressSignalingRecovery
        ) {
            noteDetachedSignalingAfterTransportEstablished(
                sessionId: sessionId,
                source: "server_frame",
                failure: reason,
                fatal: Self.isFatalPostTransportFailure(failureClass)
            )
            return
        }

        SkyBridgeLogger.shared.error("❌ signaling server rejected frame: session=\(sessionId) error=\(reason)")
        if Self.isFatalPreTransportFailure(failureClass) {
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .transient)
            lastError = "Signaling error: \(reason)"
            state = .failed(lastError ?? "Signaling error")
            readiness = .idle
            return
        }

        signalingHealth = .degradedRecoverable
        scheduleSignalingRecovery(for: sessionId, tokenExpired: failureClass == .tokenExpired)
        lastError = "Signaling error: \(reason)"
    }

    private var isTransportEstablished: Bool {
        switch readiness {
        case .transportReady:
            return true
        case .handshakeComplete:
            return true
        default:
            return false
        }
    }

    private func isTransportEstablished(for sessionId: String) -> Bool {
        switch readiness {
        case .transportReady(let activeSessionId):
            return activeSessionId == sessionId
        case .handshakeComplete(let activeSessionId, _):
            return activeSessionId == sessionId
        default:
            return false
        }
    }

    private func isHandshakeComplete(for sessionId: String) -> Bool {
        if case .handshakeComplete(let activeSessionId, _) = readiness {
            return activeSessionId == sessionId
        }
        return false
    }

    private func noteDetachedSignalingAfterTransportEstablished(
        sessionId: String,
        source: String,
        failure: String? = nil,
        fatal: Bool = false
    ) {
        let previousHealth = signalingHealth
        signalingHealth = fatal ? .degradedFatal : .degradedRecoverable

        let failureSuffix: String
        if let failure,
           !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failureSuffix = " failure=\(failure)"
        } else {
            failureSuffix = ""
        }

        let rendered =
            "ℹ️ signaling detached after transport establishment: session=\(sessionId) source=\(source) fatal=\(fatal ? 1 : 0)\(failureSuffix) summary=\(remoteDesktopRecoveryDebugSummary())"
        if previousHealth == .healthy {
            SkyBridgeLogger.shared.info(rendered)
        } else {
            SkyBridgeLogger.shared.debug(rendered)
        }
    }

    @discardableResult
    private func scheduleSignalingRecovery(for sessionId: String, tokenExpired: Bool = false) -> Bool {
        guard shouldScheduleSignalingRecovery(for: sessionId) else { return false }
        if let existingTask = signalingRecoveryTasksBySessionId[sessionId],
           !existingTask.isCancelled {
            return false
        }
        signalingRecoveryTasksBySessionId[sessionId] = Task { @MainActor [weak self] in
            guard let self else { return }
            let maxAttempts = tokenExpired ? 1 : 3
            for attempt in 0..<maxAttempts where !Task.isCancelled {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                }
                do {
                    try await self.ensureSignalingConnected(shardKey: sessionId)
                    if self.signalingShardKey == sessionId {
                        self.signalingHealth = .healthy
                        SkyBridgeLogger.shared.info(
                            "♻️ signaling recovery succeeded: session=\(sessionId) attempt=\(attempt + 1) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                        )
                    }
                    self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
                    return
                } catch is CancellationError {
                    self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ signaling recovery cancelled: session=\(sessionId) attempt=\(attempt + 1)"
                    )
                    return
                } catch {
                    SkyBridgeLogger.shared.error(
                        "⚠️ signaling recovery failed: session=\(sessionId) attempt=\(attempt + 1) err=\(error.localizedDescription) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                    )
                }
            }
            if tokenExpired, self.isHandshakeComplete(for: sessionId) {
                self.signalingHealth = .degradedFatal
                SkyBridgeLogger.shared.error(
                    "❌ signaling recovery exhausted after token expiry: session=\(sessionId) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                )
            }
            self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
        }
        return true
    }

    private func stopJoinHeartbeat() {
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
    }

    private func startJoinHeartbeat(
        sessionId: String,
        localId: String,
        signaling expectedSignaling: WebSocketSignalingClient,
        attempts: Int = CrossNetworkWebRTCManager.webRTCStartupJoinHeartbeatAttempts
    ) {
        stopJoinHeartbeat()
        joinHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            SkyBridgeLogger.shared.info("🌐 join heartbeat start: session=\(sessionId) attempts=\(attempts)")
            var remaining = max(0, attempts)
            while remaining > 0,
                  !Task.isCancelled,
                  self.currentSessionId == sessionId,
                  self.signaling === expectedSignaling {
                if self.isTransportEstablished(for: sessionId) {
                    break
                }
                await self.sendEnvelope(
                    WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: nil),
                    retries: 2
                )
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }

            guard !Task.isCancelled,
                  self.currentSessionId == sessionId,
                  self.signaling === expectedSignaling else { return }

            if self.isTransportEstablished(for: sessionId) {
                SkyBridgeLogger.shared.info("🌐 join heartbeat stop after transport established: session=\(sessionId)")
                return
            }

            let message = "等待远端 offer / answer 超时"
            self.lastError = message
            SkyBridgeLogger.shared.error("❌ join heartbeat exhausted before transportReady: session=\(sessionId)")
            self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            self.state = .failed(message)
            self.readiness = .idle
        }
    }

    private func stopOfferResendLoop() {
        offerResendTask?.cancel()
        offerResendTask = nil
    }

    private func resendCachedOfferIfNeeded(sessionId: String, localId: String, reason: String) async {
        guard let sdp = latestLocalOfferBySessionId[sessionId] else { return }
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionId: sessionId, sdp: sdp)
        await sendEnvelope(
            WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .offer,
                payload: WebRTCSignalingEnvelope.Payload(sdp: enrichedSDP)
            ),
            retries: 2
        )
        if reason != "periodic" {
            lastError = nil
        }
    }

    private func startOfferResendLoop(
        sessionId: String,
        localId: String,
        signaling expectedSignaling: WebSocketSignalingClient,
        attempts: Int = 40
    ) {
        stopOfferResendLoop()
        offerResendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0,
                  !Task.isCancelled,
                  self.currentSessionId == sessionId,
                  self.signaling === expectedSignaling {
                if case .connected = self.state { break }
                await self.resendCachedOfferIfNeeded(sessionId: sessionId, localId: localId, reason: "periodic")
                await self.resendCachedLocalICECandidatesIfNeeded(sessionId: sessionId, localId: localId)
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func cacheLocalICECandidate(_ payload: WebRTCSignalingEnvelope.Payload, for sessionId: String) {
        guard let candidate = payload.candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return
        }

        var cached = localICECandidatesBySessionId[sessionId] ?? []
        if let existingIndex = cached.firstIndex(where: {
            $0.candidate == candidate &&
            $0.sdpMid == payload.sdpMid &&
            $0.sdpMLineIndex == payload.sdpMLineIndex
        }) {
            cached[existingIndex] = payload
        } else {
            cached.append(payload)
            let maxCachedCandidates = 32
            if cached.count > maxCachedCandidates {
                cached.removeFirst(cached.count - maxCachedCandidates)
            }
        }
        localICECandidatesBySessionId[sessionId] = cached
    }

    private func resendCachedAnswerIfNeeded(sessionId: String, localId: String) async {
        guard let sdp = latestLocalAnswerBySessionId[sessionId] else { return }
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionId: sessionId, sdp: sdp)
        let env = WebRTCSignalingEnvelope(
            sessionId: sessionId,
            from: localId,
            type: .answer,
            payload: WebRTCSignalingEnvelope.Payload(sdp: enrichedSDP)
        )
        await sendEnvelope(env, retries: 2)
    }

    private func sdpWithCachedLocalICECandidates(sessionId: String, sdp: String) -> String {
        guard let candidates = localICECandidatesBySessionId[sessionId], !candidates.isEmpty else {
            return sdp
        }
        return WebRTCSDPCandidateInjector.injectLocalICECandidates(candidates, into: sdp)
    }

    private func resendCachedLocalICECandidatesIfNeeded(sessionId: String, localId: String) async {
        guard let candidates = localICECandidatesBySessionId[sessionId], !candidates.isEmpty else { return }
        for payload in candidates {
            let env = WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .iceCandidate,
                payload: payload
            )
            await sendEnvelope(env, retries: 2)
        }
    }

    /// 发送远程桌面消息（鼠标/键盘/屏幕）到 macOS（通过已建立的 WebRTC DataChannel + 会话密钥）
    public func sendRemoteDesktopMessage(_ message: RemoteMessage) async throws {
        guard let session, let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let data = try JSONEncoder().encode(message)
        let encrypted = try encrypt(plaintext: data, with: keys, packetType: .remoteControl)
        let padded = TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-remote")
        try await sendFramed(padded, over: session)
    }

    public func startRemoteDesktopHeartbeat() {
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendSmokeTrace("heartbeat-loop start session=\(self.currentSessionId ?? "-")")
            while !Task.isCancelled {
                guard let session = self.session,
                      let sessionId = self.currentSessionId,
                      case .connected(let activeSessionId) = self.state,
                      activeSessionId == sessionId
                else { break }

                if self.rekeyInProgressSessionIds.contains(sessionId) {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        break
                    }
                    continue
                }

                #if canImport(UIKit)
                let localIdentity = AppleMobileDeviceIdentity.currentSnapshot()
                let localName = localIdentity.deviceName
                let localModel = localIdentity.modelName
                #else
                let localName: String? = nil
                let localModel: String? = nil
                #endif
                let mediaDiagnostics = await self.smokeMediaHeartbeatDiagnosticsProvider?()
                let identity = AuthenticationManager.instance.remoteControlSecurityIdentityMetadata

                let heartbeat = AppMessage.heartbeat(.init(
                    sentAt: Date(),
                    deviceId: self.localDeviceId,
                    deviceName: localName,
                    modelName: localModel,
                    platform: "iOS",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    chip: nil,
                    accountDisplayName: identity.accountDisplayName,
                    nebulaId: identity.nebulaId,
                    remoteVideoFormats: RemoteDesktopManager.supportedRemoteVideoFormats(),
                    webrtcMedia: mediaDiagnostics
                ))

                do {
                    self.appendSmokeTrace("heartbeat-send session=\(sessionId)")
                    try await self.sendAppMessageOverWebRTC(
                        heartbeat,
                        sessionId: sessionId,
                        session: session,
                        label: "tx/webrtc-heartbeat"
                    )
                    self.appendSmokeTrace("heartbeat-send-ok session=\(sessionId)")
                } catch {
                    self.appendSmokeTrace("heartbeat-send-failed session=\(sessionId) error=\(error.localizedDescription)")
                    SkyBridgeLogger.shared.debug("ℹ️ WebRTC heartbeat send failed: \(error.localizedDescription)")
                    break
                }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
        }
    }

    private func shouldAutoStartRemoteDesktopHeartbeat() -> Bool {
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-client" {
            return true
        }
        return currentRole == .answerer
    }

    public func stopRemoteDesktopHeartbeat() {
        remoteDesktopHeartbeatTask?.cancel()
        remoteDesktopHeartbeatTask = nil
    }

    private func reuseCachedRedeemedSessionArtifactsIfPossible(
        for qr: DynamicQRCodeData,
        canonicalOrigin: String
    ) -> Bool {
        let signalingToken = Self.normalizedNonEmptyToken(webrtcSignalingAuthTokenBySessionId[qr.sessionID])
        let turnAdmissionToken = Self.normalizedNonEmptyToken(webrtcTurnAdmissionTokenBySessionId[qr.sessionID])
        let mediaAdmissionToken = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[qr.sessionID])
        let cachedOrigin = currentPathSignalingOriginBySessionId[qr.sessionID]
            .flatMap { try? validateCurrentPathOrigin($0) }
        let cachedWebSocketPath = currentPathSignalingWebSocketPathBySessionId[qr.sessionID]
            .flatMap { try? validateCurrentPathWebSocketPath($0) }
        let cachedAuthority = currentPathExpectedRemoteAuthorityBySessionId[qr.sessionID]

        guard mediaAdmissionToken != nil,
              cachedWebSocketPath != nil,
              Self.shouldReuseRedeemedQRSessionArtifacts(
            canonicalQRSignalingOrigin: canonicalOrigin,
            qrDeviceId: qr.deviceID,
            qrProtocolSigningAlgorithm: qr.protocolSigningAlgorithm,
            qrProtocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            qrProtocolPublicKeyBytes: qr.protocolPublicKeyBytes,
            signalingToken: signalingToken,
            turnAdmissionToken: turnAdmissionToken,
            cachedSignalingOrigin: cachedOrigin,
            cachedAuthority: cachedAuthority
        ) else {
            return false
        }

        let effectivePublicKeyBytes: Data? = {
            if !qr.protocolPublicKeyBytes.isEmpty {
                return qr.protocolPublicKeyBytes
            }
            return cachedAuthority?.protocolPublicKeyBytes
        }()
        webrtcSignalingAuthTokenBySessionId[qr.sessionID] = signalingToken
        webrtcTurnAdmissionTokenBySessionId[qr.sessionID] = turnAdmissionToken
        webrtcMediaAdmissionTokenBySessionId[qr.sessionID] = mediaAdmissionToken
        currentPathSignalingOriginBySessionId[qr.sessionID] = canonicalOrigin
        currentPathSignalingWebSocketPathBySessionId[qr.sessionID] = cachedWebSocketPath
        currentPathExpectedRemoteAuthorityBySessionId[qr.sessionID] = CurrentPathRemoteAuthorityCompat(
            deviceId: qr.deviceID,
            protocolSigningAlgorithm: qr.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: effectivePublicKeyBytes,
            deviceName: qr.deviceName
        )
        return true
    }

    private func verifyAndPersistSkybridgeConnectLink(
        _ string: String
    ) async throws -> (qr: DynamicQRCodeData, canonicalOrigin: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = Self.extractConnectPayloadString(from: trimmed) else {
            throw ConnectLinkError.invalidFormat
        }

        guard let jsonData = Self.decodeConnectPayload(payload) else {
            throw ConnectLinkError.invalidBase64
        }
        let qr = try Self.decodeDynamicQRCodePayload(from: jsonData)
        guard qr.expiresAt > Date() else { throw ConnectLinkError.expired }
        SkyBridgeLogger.shared.info("🌐 QR parse phase=decoded session=\(qr.sessionID) device=\(qr.deviceID)")
        let canonicalOrigin = try validateCurrentPathOrigin(qr.signalingServerOrigin)
        let verifyResult = try await CrossNetworkQRCodeVerificationPolicy.verify(qr)
        guard verifyResult.ok else {
            let reason = verifyResult.reason ?? "二维码校验失败"
            SkyBridgeLogger.shared.error("❌ iOS QR 校验失败: \(reason)")
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 25,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
        SkyBridgeLogger.shared.info("🌐 QR parse phase=verified session=\(qr.sessionID)")
        guard !Self.isP2PKEMBootstrapCapability(qr.normalizedCapabilities) else {
            SkyBridgeLogger.shared.error("❌ QR parse phase=rejected_p2p_kem_bootstrap_removed session=\(qr.sessionID)")
            throw Self.p2pKEMQRCodeBootstrapDisabledError()
        }
        noteVerifiedQRCodeAuthority(
            deviceId: qr.deviceID,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint
        )
        try enforceCurrentPathTrustBinding(
            deviceId: qr.deviceID,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            rebindSource: .verifiedQRCode
        )
        logVerifiedQRCodeKEMIgnored(qr)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=trust_binding_ok session=\(qr.sessionID)")
        return (qr, canonicalOrigin)
    }

    private func parseSkybridgeConnectLink(_ string: String) async throws -> DynamicQRCodeData {
        let verified = try await verifyAndPersistSkybridgeConnectLink(string)
        let qr = verified.qr
        let canonicalOrigin = verified.canonicalOrigin

        if reuseCachedRedeemedSessionArtifactsIfPossible(for: qr, canonicalOrigin: canonicalOrigin) {
            SkyBridgeLogger.shared.info(
                "♻️ 复用已兑换的 QR signaling artifacts: session=\(qr.sessionID) device=\(qr.deviceID)"
            )
            SkyBridgeLogger.shared.debug("ℹ️ iOS QR 仅完成内容完整性校验；设备来源认证仍依赖后续握手/pinning")
            return qr
        }
        let localBinding = try await currentPathLocalBinding()
        SkyBridgeLogger.shared.info("🌐 QR parse phase=local_binding_ready device=\(localBinding.deviceId)")
        let admission = try await requestAdmissionLease(for: localBinding)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=admission_ready")
        let redeemed = try await signalServer.redeemSession(
            admissionToken: admission.token,
            sessionId: qr.sessionID,
            qrBootstrapToken: qr.qrBootstrapToken,
            idempotencyKey: "qr-redeem-\(qr.sessionID)-\(localBinding.deviceId)"
        )
        SkyBridgeLogger.shared.info("🌐 QR parse phase=redeem_ready session=\(redeemed.sessionID) initiator=\(redeemed.initiatorDeviceId)")
        guard redeemed.initiatorDeviceId == qr.deviceID,
              redeemed.initiatorProtocolSigningAlgorithm == qr.protocolSigningAlgorithm,
              redeemed.initiatorProtocolPublicKeyFingerprint == qr.protocolPublicKeyFingerprint else {
            throw ConnectLinkError.invalidSignature
        }
        let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
            origin: redeemed.signalingServerOrigin,
            wsPath: redeemed.wsPath
        )
        webrtcSignalingAuthTokenBySessionId[qr.sessionID] = redeemed.sessionToken
        webrtcTurnAdmissionTokenBySessionId[qr.sessionID] = redeemed.turnAdmissionToken
        if let mediaAdmissionToken = redeemed.mediaAdmissionToken {
            webrtcMediaAdmissionTokenBySessionId[qr.sessionID] = mediaAdmissionToken
        }
        setCurrentPathSignalingEndpoint(sessionId: qr.sessionID, endpoint: signalingEndpoint)
        currentPathExpectedRemoteAuthorityBySessionId[qr.sessionID] = CurrentPathRemoteAuthorityCompat(
            deviceId: qr.deviceID,
            protocolSigningAlgorithm: qr.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: qr.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: qr.protocolPublicKeyBytes,
            deviceName: qr.deviceName
        )
        SkyBridgeLogger.shared.debug("ℹ️ iOS QR 仅完成内容完整性校验；设备来源认证仍依赖后续握手/pinning")
        return qr
    }

    nonisolated private static func normalizedNonEmptyToken(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func tokenGenerationPrefix(_ token: String?) -> String? {
        guard let token = normalizedNonEmptyToken(token) else { return nil }
        return SHA256.hash(data: Data(token.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func logVerifiedQRCodeKEMIgnored(_ qrData: DynamicQRCodeData) {
        let kemKeys = qrData.normalizedKEMPublicKeys
        guard !kemKeys.isEmpty else { return }

        SkyBridgeLogger.shared.info(
            "🔑 已验证二维码包含 PQC KEM，但不会导入 KEM trust；P2P KEM 恢复必须走 PIB-1 SAS + SKR-1 signed LAN refresh: device=\(qrData.deviceID) keys=\(kemKeys.count)"
        )
    }

    private func connect(from qr: DynamicQRCodeData) async throws {
        try await connect(
            sessionId: qr.sessionID,
            remoteName: qr.deviceName,
            remotePeerDeviceId: qr.deviceID,
            source: .qr,
            role: .answerer
        )
    }

    private func connect(
        sessionId: String,
        remoteName: String?,
        remotePeerDeviceId: String?,
        source: ActiveSessionSnapshotSource,
        role: WebRTCSession.Role
    ) async throws {
        if currentSessionId == sessionId {
            switch state {
            case .connecting(let activeSessionId) where activeSessionId == sessionId:
                return
            case .connected(let activeSessionId) where activeSessionId == sessionId:
                return
            default:
                break
            }
        }

        let preservedSignalingToken = webrtcSignalingAuthTokenBySessionId[sessionId]
        let preservedTurnAdmissionToken = webrtcTurnAdmissionTokenBySessionId[sessionId]
        let preservedMediaAdmissionToken = webrtcMediaAdmissionTokenBySessionId[sessionId]
        let preservedSignalingOrigin = currentPathSignalingOriginBySessionId[sessionId]
        let preservedSignalingWebSocketPath = currentPathSignalingWebSocketPathBySessionId[sessionId]
        let preservedRemoteAuthority = currentPathExpectedRemoteAuthorityBySessionId[sessionId]
        let preservedAdditionalFingerprints = currentPathAdditionalProtocolFingerprintsBySessionId[sessionId]

        if signaling != nil || session != nil || currentSessionId != nil {
            await disconnect()
            if let preservedSignalingToken {
                webrtcSignalingAuthTokenBySessionId[sessionId] = preservedSignalingToken
            }
            if let preservedTurnAdmissionToken {
                webrtcTurnAdmissionTokenBySessionId[sessionId] = preservedTurnAdmissionToken
            }
            if let preservedMediaAdmissionToken {
                webrtcMediaAdmissionTokenBySessionId[sessionId] = preservedMediaAdmissionToken
            }
            if let preservedSignalingOrigin {
                currentPathSignalingOriginBySessionId[sessionId] = preservedSignalingOrigin
            }
            if let preservedSignalingWebSocketPath {
                currentPathSignalingWebSocketPathBySessionId[sessionId] = preservedSignalingWebSocketPath
            }
            if let preservedRemoteAuthority {
                currentPathExpectedRemoteAuthorityBySessionId[sessionId] = preservedRemoteAuthority
            }
            if let preservedAdditionalFingerprints {
                currentPathAdditionalProtocolFingerprintsBySessionId[sessionId] = preservedAdditionalFingerprints
            }
        }

        currentSessionId = sessionId
        beginRemoteDesktopNotificationTracking(sessionId: sessionId)
        state = .connecting(sessionId: sessionId)
        readiness = .idle
        lastError = nil
#if canImport(WebRTC)
        installRemoteVideoTrack(nil)
#endif
        handshakePeerId = remotePeerDeviceId ?? "webrtc-\(sessionId)"
        remoteDeviceName = remoteName
        remoteDeviceId = remotePeerDeviceId
        currentRole = role
        appendSmokeTrace(
            "connect session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer") source=\(String(describing: source)) remoteId=\(remotePeerDeviceId ?? "-") remoteName=\(remoteName ?? "-")"
        )
        prepareSessionSnapshotMetadata(
            sessionId: sessionId,
            source: source,
            deviceId: remotePeerDeviceId,
            deviceName: remoteName
        )
        activatePreparedSessionSnapshot(sessionId: sessionId, phase: .connecting)
        if role != .offerer {
            localConnectionCode = nil
            localConnectionSessionId = nil
            activeConnectionCodeAuthorityDeviceId = nil
            activeConnectionCodeAuthorityFingerprint = nil
            authorityBoundWebRTCBootstrapSessionIds.remove(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
        }

        // 1) WebSocket signaling
        do {
            try await ensureSignalingConnected(shardKey: sessionId)
            SkyBridgeLogger.shared.info("🌐 cross-network phase=signaling_bound session=\(sessionId)")
        } catch {
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            state = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }
        guard let signaling = self.signaling else {
            let error = WebSocketSignalingClient.SignalingError.notConnected
            applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
            state = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }

        // 2) WebRTC session (offerer / answerer)
        let localId = localDeviceId

        // SECURITY: Never hardcode TURN credentials in the client app.
        // Use short-lived TURN REST credentials fetched from backend (with safe fallback).
        let ice = await CrossNetworkServerConfig.dynamicICEConfig(
            turnAdmissionToken: webrtcTurnAdmissionTokenBySessionId[sessionId]
        )
        appendSmokeTrace(
            "ice session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer") stun=\(ice.stunURL.isEmpty ? 0 : 1) turnUrls=\(ice.turnURLs.count) turnCreds=\((ice.turnUsername.isEmpty || ice.turnPassword.isEmpty) ? 0 : 1)"
        )

        let nativeAudioReceiveEnabled = self.nativeAudioReceiveEnabled
        let s = WebRTCSession(
            sessionId: sessionId,
            localDeviceId: localId,
            role: role,
            ice: ice,
            nativeAudioReceiveEnabled: nativeAudioReceiveEnabled
        )
        self.session = s
        // 仅 smoke 模式安装 trace 回调：生产环境保持 onTrace == nil，
        // 使 session 内全部 trace 调用点（含每条入站消息）退化为空指针判断，避免高频字符串插值开销。
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            s.onTrace = { [weak self] line in
                self?.appendSmokeTrace("webrtc \(line)")
            }
        }
#if canImport(WebRTC)
        s.onRemoteVideoTrack = { [weak self] track in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.currentSessionId == sessionId,
                      self.session === s else { return }
                self.installRemoteVideoTrack(track)
            }
        }
        s.onRemoteVideoFrameEvidence = { [weak self] size, source in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.currentSessionId == sessionId,
                      self.session === s else { return }
                self.noteRemoteVideoTrackRenderedFrame(size, source: source)
            }
        }
        s.onRemoteVideoFirstPacket = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.currentSessionId == sessionId,
                      self.session === s else { return }
                self.noteRemoteVideoTrackReceivedFirstPacket(source: "receiver-first-packet")
            }
        }
        if nativeAudioReceiveEnabled {
            s.onRemoteAudioFirstPacket = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.currentSessionId == sessionId,
                          self.session === s else { return }
                    self.noteRemoteAudioTrackReceivedFirstPacket(source: "receiver-first-packet")
                }
            }
        }
#endif

        s.onLocalOffer = { [weak self] (sdp: String) in
            guard let self else { return }
            Task {
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                await MainActor.run {
                    self.latestLocalOfferBySessionId[sessionId] = sdp
                    self.appendSmokeTrace("local-offer session=\(sessionId) \(CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp))")
                }
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .offer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(env, retries: 2)
            }
        }

        s.onLocalAnswer = { [weak self] (sdp: String) in
            guard let self else { return }
            Task {
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                await MainActor.run {
                    self.latestLocalAnswerBySessionId[sessionId] = sdp
                    self.appendSmokeTrace("local-answer session=\(sessionId) \(CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp))")
                }
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .answer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(env, retries: 2)
            }
        }

        s.onLocalICECandidate = { [weak self] (payload: WebRTCSignalingEnvelope.Payload) in
            guard let self else { return }
            Task {
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                let candidateKind = CrossNetworkWebRTCTraceDescription.describeCandidateKind(payload.candidate)
                await MainActor.run {
                    self.cacheLocalICECandidate(payload, for: sessionId)
                    self.appendSmokeTrace("local-ice session=\(sessionId) kind=\(candidateKind) mid=\(payload.sdpMid ?? "-") index=\(payload.sdpMLineIndex ?? -1)")
                }
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .iceCandidate,
                    payload: payload
                )
                await self.sendEnvelope(env, retries: 1)
            }
        }

        // Inbound frames from DataChannel
        let inbound = InboundChunkQueue()
        let screenInbound = InboundChunkQueue()
        let orderedInboundRelay = OrderedInboundChunkRelay()
        let orderedScreenInboundRelay = OrderedInboundChunkRelay()
        self.inboundQueue = inbound
        self.screenInboundQueue = screenInbound
        s.onData = { data in
            orderedInboundRelay.submit { [weak self] in
                guard let self else { return }
                let isCurrentSession = await MainActor.run { self.session === s }
                guard isCurrentSession else { return }
                let rekeyInProgress = await MainActor.run {
                    self.rekeyInProgressSessionIds.contains(sessionId)
                }
                if rekeyInProgress {
                    await MainActor.run {
                        self.lastRekeyEvent = "chunk bytes=\(data.count)"
                        self.appendSmokeTrace("rx chunk bytes=\(data.count)")
                    }
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        print("🧪 WebRTC rekey rx chunk bytes=\(data.count)")
                    }
                }
                await inbound.push(data)
            }
        }
        s.onScreenData = { data in
            orderedScreenInboundRelay.submit { [weak self] in
                guard let self else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }
                await screenInbound.push(data)
            }
        }

        s.onDisconnected = { [weak self] reason in
            Task {
                guard let self else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }
                let msg = "WebRTC 传输已断开: \(reason)"
                await MainActor.run {
                    self.appendSmokeTrace("transport-disconnected session=\(sessionId) reason=\(reason)")
                    self.lastError = msg
                    self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .transient)
                }
                await self.notifyRemoteDesktopTerminalSessionIfNeeded(
                    sessionId: sessionId,
                    kind: .interrupted,
                    reason: "transport_disconnected:\(reason)"
                )
                await self.disconnect(clearSnapshot: false)
                await MainActor.run {
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.readiness = .idle
                }
            }
        }

        s.onReady = { [weak self] in
            Task {
                guard let self else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }

                let bootstrapPlan: (shouldConfigure: Bool, shouldInitiate: Bool) = await MainActor.run {
                    self.appendSmokeTrace("transport-ready session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")
                    self.readiness = .transportReady(sessionId: sessionId)
                    self.updatePreparedSessionSnapshot(
                        sessionId: sessionId,
                        phase: .transportReady,
                        deviceId: self.remoteDeviceId,
                        deviceName: self.remoteDeviceName
                    )
                    SkyBridgeLogger.shared.info("✅ WebRTC transport ready: session=\(sessionId), role=\(String(describing: role))")

                    if !self.handshakeStartedSessionIds.contains(sessionId) {
                        self.handshakeStartedSessionIds.insert(sessionId)
                        return (
                            true,
                            CrossNetworkWebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: role)
                        )
                    }
                    return (false, false)
                }

                if bootstrapPlan.shouldConfigure {
                    let peerDeviceId = await MainActor.run {
                        self.remoteDeviceId ?? self.handshakePeerId ?? "webrtc-\(sessionId)"
                    }
                    await self.startHandshakeOverWebRTC(
                        sessionId: sessionId,
                        peerDeviceId: peerDeviceId,
                        session: s,
                        inbound: inbound,
                        shouldInitiate: bootstrapPlan.shouldInitiate
                    )
                } else {
                    SkyBridgeLogger.shared.debug("ℹ️ skip duplicate WebRTC handshake start: session=\(sessionId)")
                }
            }
        }

        try s.start()
        SkyBridgeLogger.shared.info("🌐 cross-network phase=session_started session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")
        appendSmokeTrace("session-started session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")

        screenReceiveTask?.cancel()
        let screenSessionObjectIdentifier = ObjectIdentifier(s)
        screenReceiveTask = Task {
            defer { orderedScreenInboundRelay.cancel() }
            await self.receiveScreenLoop(
                sessionId: sessionId,
                sessionObjectIdentifier: screenSessionObjectIdentifier,
                inbound: screenInbound
            )
        }

        // 3) Join room + heartbeat to mask websocket timing jitters.
        await sendEnvelope(WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: nil), retries: 2)
        SkyBridgeLogger.shared.info("🌐 cross-network phase=join_sent session=\(sessionId)")
        startJoinHeartbeat(sessionId: sessionId, localId: localId, signaling: signaling)
        if role == .offerer {
            startOfferResendLoop(sessionId: sessionId, localId: localId, signaling: signaling)
        }
    }

    private func handleEnvelope(_ env: WebRTCSignalingEnvelope) {
        guard env.sessionId == currentSessionId else { return }
        // Ignore self-echo
        let localId = localDeviceId
        if env.from == localId { return }
        appendSmokeTrace("rx \(describeEnvelope(env))")

        // If we don't know the remote id yet (e.g., code mode), learn it from signaling.
        if remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true {
            remoteDeviceId = env.from
            handshakePeerId = env.from
            updatePreparedSessionSnapshot(
                sessionId: env.sessionId,
                phase: .connecting,
                deviceId: env.from
            )
        }

        switch env.type {
        case .offer:
            if let sdp = env.payload?.sdp {
                appendSmokeTrace("remote-offer session=\(env.sessionId) \(CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp))")
                session?.setRemoteOffer(sdp)
            }
            let localId = localDeviceId
            Task { @MainActor [weak self] in
                await self?.resendCachedAnswerIfNeeded(sessionId: env.sessionId, localId: localId)
                await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: env.sessionId, localId: localId)
            }
        case .answer:
            stopOfferResendLoop()
            if let sdp = env.payload?.sdp {
                appendSmokeTrace("remote-answer session=\(env.sessionId) \(CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp))")
                session?.setRemoteAnswer(sdp)
            }
            let localId = localDeviceId
            Task { @MainActor [weak self] in
                await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: env.sessionId, localId: localId)
            }
        case .iceCandidate:
            if let p = env.payload, let c = p.candidate {
                appendSmokeTrace(
                    "remote-ice session=\(env.sessionId) kind=\(CrossNetworkWebRTCTraceDescription.describeCandidateKind(p.candidate)) mid=\(p.sdpMid ?? "-") index=\(p.sdpMLineIndex ?? -1)"
                )
                session?.addRemoteICECandidate(candidate: c, sdpMid: p.sdpMid, sdpMLineIndex: p.sdpMLineIndex)
            }
        case .join:
            appendSmokeTrace("remote-join session=\(env.sessionId) from=\(env.from)")
            if currentRole == .offerer, let sid = currentSessionId, sid == env.sessionId {
                let localId = localDeviceId
                Task { @MainActor [weak self] in
                    await self?.resendCachedOfferIfNeeded(sessionId: sid, localId: localId, reason: "remote-join")
                    await self?.resendCachedAnswerIfNeeded(sessionId: sid, localId: localId)
                    await self?.resendCachedLocalICECandidatesIfNeeded(sessionId: sid, localId: localId)
                }
            }
        case .leave:
            stopJoinHeartbeat()
            stopOfferResendLoop()
            appendSmokeTrace("remote-leave session=\(env.sessionId) from=\(env.from)")
            let sessionId = env.sessionId
            Task { @MainActor [weak self] in
                await self?.terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    disconnectKind: .remoteLeave,
                    notificationKind: .normal,
                    reason: "remote_leave"
                )
            }
        }
    }
}

// MARK: - WebRTC framed handshake (iOS)

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    func startHandshakeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue,
        shouldInitiate: Bool
    ) async {
        do {
            let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
            let strictPQCRequested = CrossNetworkWebRTCPQCHandshakePolicy.shouldRequestStrictPQC(
                compatibilityModeEnabled: compatibilityModeEnabled
            )
            strictPQCRequestedBySessionId[sessionId] = strictPQCRequested

            let peer = PeerIdentifier(deviceId: peerDeviceId)

            // Keep the control-channel receive loop alive for both the initial handshake
            // and any later rekey/app traffic. The answerer must install this before it
            // can respond to the offerer's first MessageA.
            receiveTask?.cancel()
            receiveTask = Task {
                await self.receiveLoop(
                    sessionId: sessionId,
                    session: session,
                    inbound: inbound,
                    peer: peer,
                    strictPQCRequested: strictPQCRequested
                )
            }

            guard shouldInitiate else {
                SkyBridgeLogger.shared.info(
                    "🤝 WebRTC 等待对端发起初始握手: session=\(sessionId), role=\(String(describing: session.role)), strictPQC=\(strictPQCRequested)"
                )
                return
            }

            let capability = CryptoProviderFactory.detectCapability()
            var peerIdCandidates: [String] = []
            for raw in [
                currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId,
                peerDeviceId,
                remoteDeviceId,
                handshakePeerId
            ] {
                guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
                if !peerIdCandidates.contains(id) {
                    peerIdCandidates.append(id)
                }
            }
            if peerIdCandidates.isEmpty {
                peerIdCandidates = [peerDeviceId]
            }
            if strictPQCRequested,
               currentPathExpectedRemoteAuthorityBySessionId[sessionId] == nil {
                let message = "strictPQC WebRTC initial handshake requires pinned current-path protocol identity"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message): session=\(sessionId), peer=\(peerDeviceId)"
                )
                throw NSError(
                    domain: "CrossNetworkWebRTCManager",
                    code: -1206,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            var trustedPeerKEMKeys: [CryptoSuite: Data] = [:]
            var trustLookupPeerId = peerDeviceId
            for candidate in peerIdCandidates {
                let keys = await KEMTrustStore.shared.kemPublicKeys(for: candidate)
                guard !keys.isEmpty else { continue }
                trustedPeerKEMKeys = keys
                trustLookupPeerId = candidate
                break
            }
            let hasTrustedPeerKEMKey = !trustedPeerKEMKeys.isEmpty
            let useClassicAuthorityBootstrap = !strictPQCRequested
                && CrossNetworkWebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                    sessionId: sessionId,
                    authorityBoundBootstrapSessionIds: authorityBoundWebRTCBootstrapSessionIds,
                    expectedRemoteAuthorityAlgorithm: currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.protocolSigningAlgorithm,
                    localConnectionSessionId: localConnectionSessionId
                )
            let bootstrapDecision = CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: strictPQCRequested,
                hasTrustedPeerKEMKey: hasTrustedPeerKEMKey,
                capability: capability,
                useClassicAuthorityBootstrap: useClassicAuthorityBootstrap,
                peerDeviceId: peerDeviceId
            )
            let bootstrapPlan: CrossNetworkWebRTCPQCHandshakePolicy.InitialHandshakeBootstrapPlan
            switch bootstrapDecision {
            case .proceed(let plan):
                bootstrapPlan = plan
            case .reject(let failure):
                if failure.includeProviderAvailabilityInLog {
                    SkyBridgeLogger.shared.error(
                        "⛔️ \(failure.message) hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
                    )
                } else {
                    SkyBridgeLogger.shared.error("⛔️ \(failure.message)")
                }
                throw NSError(
                    domain: "CrossNetworkWebRTCManager",
                    code: failure.code,
                    userInfo: [NSLocalizedDescriptionKey: failure.message]
                )
            }
            let selection = bootstrapPlan.selection
            SkyBridgeLogger.shared.info(
                "🤝 WebRTC handshake bootstrap: session=\(sessionId), policy=\(selection.rawValue), " +
                "compatMode=\(compatibilityModeEnabled), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs), " +
                "peer=\(peerDeviceId), trustedKEM=\(hasTrustedPeerKEMKey), trustPeer=\(trustLookupPeerId), authorityBootstrap=\(useClassicAuthorityBootstrap)"
            )
            let transport = makeHandshakeTransport(over: session)
            let currentPathTrustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: peerIdCandidates,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )

            func attemptInitialHandshake(
                selection: CryptoProviderFactory.SelectionPolicy,
                bootstrapMode: String
            ) async throws -> SessionKeys {
                try await SkyBridgeiOSCore.shared.initialize(policy: selection)
                let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                    transport: transport,
                    trustProvider: currentPathTrustProvider
                )
                self.handshakeDriver = driver
                SkyBridgeLogger.shared.info(
                    "🤝 WebRTC initiating handshake: session=\(sessionId), peer=\(peerDeviceId), mode=\(bootstrapMode), policy=\(selection.rawValue)"
                )
                return try await driver.initiateHandshake(with: peer)
            }

            let keys: SessionKeys
            do {
                keys = try await attemptInitialHandshake(
                    selection: selection,
                    bootstrapMode: bootstrapPlan.bootstrapMode
                )
            } catch {
                self.handshakeDriver = nil
                if !strictPQCRequested,
                   hasTrustedPeerKEMKey,
                   selection != .classicOnly,
                   CrossNetworkWebRTCPQCHandshakePolicy.shouldRetryClassicBootstrap(after: error) {
                    for candidate in peerIdCandidates {
                        await KEMTrustStore.shared.clear(deviceId: candidate)
                    }
                    self.appendSmokeTrace("bootstrap retry classic peer=\(peerDeviceId)")
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC trusted KEM bootstrap failed; cleared cached peer KEM keys and retrying classic bootstrap. " +
                        "session=\(sessionId), peer=\(peerDeviceId), error=\(CrossNetworkWebRTCPQCHandshakePolicy.describeHandshakeError(error))"
                    )
                    keys = try await attemptInitialHandshake(
                        selection: .classicOnly,
                        bootstrapMode: "classic_retry_after_stale_kem"
                    )
                } else {
                    throw error
                }
            }

            guard self.currentSessionId == sessionId, self.session === session else {
                self.appendSmokeTrace("drop stale handshake-complete session=\(sessionId)")
                return
            }

            self.sessionKeys = keys
            self.handshakeDriver = nil
            if self.currentSessionId == sessionId {
                // Paper-aligned contract:
                // WebRTC DataChannel ready is only transportReady; connected must wait for handshakeComplete.
                self.state = .connected(sessionId: sessionId)
                self.readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                self.noteRemoteAppActivity(sessionId: sessionId)
                self.startRemotePeerPingLoop(sessionId: sessionId, session: session)
                self.startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)
                self.updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .handshakeComplete,
                    deviceId: self.remoteDeviceId,
                    deviceName: self.remoteDeviceName,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                if self.shouldAutoStartRemoteDesktopHeartbeat() {
                    self.startRemoteDesktopHeartbeat()
                }
            }
            self.persistCurrentPathTrust(sessionId: sessionId)
            SkyBridgeLogger.shared.info(
                "✅ WebRTC 握手完成（DataChannel） session=\(sessionId) suite=\(keys.negotiatedSuite.rawValue)"
            )

            do {
                try await sendPairingIdentityExchangeOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    force: true
                )
            } catch {
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC pairingIdentityExchange send failed: session=\(sessionId) peer=\(peerDeviceId) err=\(error.localizedDescription)"
                )
            }

            await maybeStartPQCRekeyOverWebRTC(
                sessionId: sessionId,
                peerDeviceId: peerDeviceId,
                session: session,
                strictPQCRequested: strictPQCRequested,
                trigger: "post_bootstrap"
            )
        } catch {
            let reason: String
            if let hs = error as? HandshakeError {
                switch hs {
                case .alreadyInProgress:
                    reason = "alreadyInProgress"
                case .noSigningCapability:
                    reason = "noSigningCapability"
                case .failed(let failure):
                    reason = String(describing: failure)
                case .emptyOfferedSuites:
                    reason = "emptyOfferedSuites"
                case .homogeneityViolation(let message):
                    reason = "homogeneityViolation(\(message))"
                case .providerAlgorithmMismatch(let provider, let algorithm):
                    reason = "providerAlgorithmMismatch(provider=\(provider), algorithm=\(algorithm))"
                case .signatureAlgorithmMismatch(let algorithm, let keyHandleType):
                    reason = "signatureAlgorithmMismatch(algorithm=\(algorithm), keyHandle=\(keyHandleType))"
                case .contextZeroized:
                    reason = "contextZeroized"
                }
            } else {
                reason = error.localizedDescription
            }
            SkyBridgeLogger.shared.error("❌ WebRTC 握手失败（DataChannel） session=\(sessionId): \(reason)")
            await MainActor.run {
                self.lastError = "WebRTC 握手失败: \(reason)"
                self.applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
                self.state = .failed(self.lastError ?? "WebRTC handshake failed")
                self.readiness = .idle
                self.handshakeDriver = nil
                self.sessionKeys = nil
                self.handshakeStartedSessionIds.remove(sessionId)
                self.inboundInitialHandshakeResponderSessionIds.remove(sessionId)
                self.inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
                self.clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
                self.rekeyInProgressSessionIds.remove(sessionId)
                self.rekeyCompletedSessionIds.remove(sessionId)
                self.strictPQCRequestedBySessionId.removeValue(forKey: sessionId)
            }
        }
    }

    nonisolated private static func webRTCPQCRekeyProvider(for plan: WebRTCPQCRekeyProviderPlan) -> (any CryptoProvider)? {
        switch plan.label {
        case "native-xwing":
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                return AppleXWingCryptoProvider()
            }
            #endif
            return nil
        case "native-pqc":
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                return ApplePQCCryptoProvider()
            }
            #endif
            return nil
        case "liboqs", "liboqs-fallback":
            return OQSPQCCryptoProvider()
        default:
            return nil
        }
    }

    nonisolated private static func isAppleXWingRuntimeAvailableForRekey() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleXWingCryptoProvider.quickRuntimeProbe()
        }
        #endif
        return false
    }

    private func resolvedPQCRekeyElectionRemoteDeviceId(
        sessionId: String,
        peerDeviceId: String
    ) -> String? {
        for raw in [
            currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId,
            remoteDeviceId,
            handshakePeerId,
            peerDeviceId
        ] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.canonicalPQCRekeyElectionDeviceId(trimmed) != nil else { continue }
            return trimmed
        }
        return nil
    }

    private func sendHandshakeFrameOverWebRTC(
        _ data: Data,
        over session: WebRTCSession
    ) async throws {
        let rawHandshake = HandshakePadding.unwrapIfNeeded(data, label: "tx/webrtc")
        let tunedHandshake = HandshakePadding.wrapIfEnabled(
            rawHandshake,
            label: "tx/webrtc",
            maxTotalBytes: CrossNetworkWebRTCHandshakeLimits.maxPaddedPayloadBytes
        )
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            if let messageA = try? HandshakeMessageA.decode(from: rawHandshake) {
                let suites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                appendSmokeTrace("tx messageA suites=\(suites) raw=\(rawHandshake.count)")
                print("🧪 WebRTC rekey tx MessageA raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suites=\(suites)")
            } else if let messageB = try? HandshakeMessageB.decode(from: rawHandshake) {
                let payloadBytes = messageB.encryptedPayload.combinedWithHeader(suite: messageB.selectedSuite).count
                let seBytes = messageB.secureEnclaveSignature?.count ?? 0
                appendSmokeTrace(
                    "tx messageB suite=\(messageB.selectedSuite.rawValue) raw=\(rawHandshake.count) share=\(messageB.responderShare.count) payload=\(payloadBytes) id=\(messageB.identityPublicKey.count) sig=\(messageB.signature.count) se=\(seBytes)"
                )
                print(
                    "🧪 WebRTC rekey tx MessageB raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suite=\(messageB.selectedSuite.rawValue) share=\(messageB.responderShare.count) payload=\(payloadBytes) id=\(messageB.identityPublicKey.count) sig=\(messageB.signature.count) se=\(seBytes)"
                )
            } else if (try? HandshakeFinished.decode(from: rawHandshake)) != nil {
                appendSmokeTrace("tx finished raw=\(rawHandshake.count)")
                print("🧪 WebRTC rekey tx Finished raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
            }
        }
        do {
            try await session.sendFramedPayloadAsync(
                tunedHandshake,
                maxChunkBytes: CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes,
                maxBufferedAmountBytes: CrossNetworkWebRTCHandshakeLimits.maxBufferedAmountBytes
            )
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                appendSmokeTrace("tx handshake-sent raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
            }
        } catch {
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                appendSmokeTrace(
                    "tx handshake-send-failed raw=\(rawHandshake.count) padded=\(tunedHandshake.count) error=\(CrossNetworkWebRTCTraceDescription.smokeTraceToken(error.localizedDescription))"
                )
            }
            throw error
        }
    }

    private func makeHandshakeTransport(
        over session: WebRTCSession
    ) -> CurrentPathWebRTCHandshakeTransportCompat {
        CurrentPathWebRTCHandshakeTransportCompat(
            sendFramed: { [weak self] data in
                guard let self else { return }
                try await self.sendHandshakeFrameOverWebRTC(data, over: session)
            }
        )
    }

    private func ensureInboundPQCRekeyDriverIfNeeded(
        sessionId: String,
        frame: Data,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> HandshakeDriver? {
        guard currentSessionId == sessionId else { return nil }
        if inboundRekeyResponderSessionIds.contains(sessionId) {
            return handshakeDriver
        }
        guard handshakeDriver == nil else { return nil }
        guard sessionKeys != nil else { return nil }
        guard let messageA = try? HandshakeMessageA.decode(from: frame),
              !messageA.supportedSuites.isEmpty else {
            return nil
        }
        appendSmokeTrace("inbound-rekey messageA candidate session=\(sessionId) raw=\(frame.count)")

        let hasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let localCapability = CryptoProviderFactory.detectCapability()
        let localPQCAvailable = localCapability.hasApplePQC || localCapability.hasLiboqs
        guard let selection = CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeySelectionPolicy(
            supportedSuites: messageA.supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable
        ) else {
            let message: String
            if strictPQCRequested && !hasPQCGroup {
                message =
                    "严格 PQC 已启用，但 WebRTC 入站 rekey 对端只提供 Classic suites；当前已拒绝降级。peer=\(peer.deviceId)"
            } else {
                message =
                    "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；当前已拒绝入站 rekey。peer=\(peer.deviceId)"
            }
            lastRekeyEvent = "rejected inbound strict peer=\(peer.deviceId)"
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) hasApplePQC=\(localCapability.hasApplePQC), hasLiboqs=\(localCapability.hasLiboqs)"
            )
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: message
                )
            }
            return nil
        }

        var fallbackPeerIDs: [String] = []
        for raw in [
            peer.deviceId,
            remoteDeviceId,
            handshakePeerId,
            currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId
        ] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !fallbackPeerIDs.contains(trimmed) {
                fallbackPeerIDs.append(trimmed)
            }
        }

        do {
            let provider = hasPQCGroup
                ? CryptoProviderFactory.makeInboundPQCResponderProvider(
                    policy: selection,
                    peerSupportedSuites: messageA.supportedSuites
                )
                : CryptoProviderFactory.make(policy: selection)
            appendSmokeTrace("inbound-rekey provider session=\(sessionId) provider=\(provider.providerName)")
            try await SkyBridgeiOSCore.shared.initialize(policy: selection, providerOverride: provider)
            appendSmokeTrace("inbound-rekey core-ready session=\(sessionId)")
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: fallbackPeerIDs,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: makeHandshakeTransport(over: session),
                peerSupportedSuites: messageA.supportedSuites,
                trustProvider: trustProvider
            )
            handshakeDriver = driver
            appendSmokeTrace("inbound-rekey driver-ready session=\(sessionId)")
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey driver 初始化失败: session=\(sessionId), err=\(error.localizedDescription)"
            )
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: "strictPQC WebRTC inbound rekey driver init failed: \(error.localizedDescription)"
                )
            }
            return nil
        }

        inboundRekeyResponderSessionIds.insert(sessionId)
        rekeyInProgressSessionIds.insert(sessionId)
        lastRekeyEvent = "received peer=\(peer.deviceId)"
        SkyBridgeLogger.shared.info(
            "🔁 收到对端 WebRTC rekey 请求，切换 responder: session=\(sessionId), peer=\(peer.deviceId), suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return handshakeDriver
    }

    private func ensureInboundInitialHandshakeDriverIfNeeded(
        sessionId: String,
        frame: Data,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> HandshakeDriver? {
        guard currentSessionId == sessionId else { return nil }
        if inboundInitialHandshakeResponderSessionIds.contains(sessionId) {
            return handshakeDriver
        }
        guard handshakeDriver == nil else { return nil }
        guard sessionKeys == nil else { return nil }
        guard let messageA = try? HandshakeMessageA.decode(from: frame),
              !messageA.supportedSuites.isEmpty else {
            return nil
        }

        let hasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
        let localCapability = CryptoProviderFactory.detectCapability()
        let localPQCAvailable = localCapability.hasApplePQC || localCapability.hasLiboqs
        let expectedAuthorityAlgorithm = currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.protocolSigningAlgorithm
        let allowsClassicAuthorityBootstrap = CrossNetworkWebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
            supportedSuites: messageA.supportedSuites,
            strictPQCRequested: strictPQCRequested,
            expectedRemoteAuthorityAlgorithm: expectedAuthorityAlgorithm
        )
        guard let selection = CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeSelectionPolicy(
            supportedSuites: messageA.supportedSuites,
            strictPQCRequested: strictPQCRequested,
            localPQCAvailable: localPQCAvailable,
            expectedRemoteAuthorityAlgorithm: expectedAuthorityAlgorithm
        ) else {
            let message: String
            if strictPQCRequested && !hasPQCGroup {
                message =
                    "严格 PQC 已启用，但 WebRTC 对端初始握手只提供 Classic suites；当前已拒绝降级。peer=\(peer.deviceId)"
            } else {
                message =
                    "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；当前已拒绝 WebRTC 入站初始握手。peer=\(peer.deviceId)"
            }
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) hasApplePQC=\(localCapability.hasApplePQC), hasLiboqs=\(localCapability.hasLiboqs)"
            )
            if strictPQCRequested {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: message
                )
            }
            return nil
        }

        var fallbackPeerIDs: [String] = []
        for raw in [
            peer.deviceId,
            remoteDeviceId,
            handshakePeerId,
            currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId
        ] {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !fallbackPeerIDs.contains(trimmed) {
                fallbackPeerIDs.append(trimmed)
            }
        }

        do {
            try await SkyBridgeiOSCore.shared.initialize(policy: selection)
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: fallbackPeerIDs,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: makeHandshakeTransport(over: session),
                peerSupportedSuites: messageA.supportedSuites,
                trustProvider: trustProvider
            )
            handshakeDriver = driver
        } catch {
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC 初始握手驱动初始化失败: session=\(sessionId), err=\(error.localizedDescription)"
            )
            if strictPQCRequested {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    message: "strictPQC WebRTC inbound initial handshake driver init failed: \(error.localizedDescription)"
                )
            }
            return nil
        }

        inboundInitialHandshakeResponderSessionIds.insert(sessionId)
        if allowsClassicAuthorityBootstrap {
            inboundClassicAuthorityBootstrapSessionIds.insert(sessionId)
            SkyBridgeLogger.shared.info(
                "🤝 WebRTC 入站初始握手允许 current-path authority classic bootstrap: session=\(sessionId), peer=\(peer.deviceId)"
            )
        }
        SkyBridgeLogger.shared.info(
            "🤝 收到对端 WebRTC 初始握手请求，切换 responder: session=\(sessionId), peer=\(peer.deviceId), suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return handshakeDriver
    }

    private func failStrictPQCBootstrapSession(
        sessionId: String,
        message: String
    ) async {
        lastError = message
        lastRekeyEvent = "failed strict reason=\(message)"
        handshakeDriver = nil
        sessionKeys = nil
        clearWebRTCSecureEnvelopeState(for: sessionId)
        inboundInitialHandshakeResponderSessionIds.remove(sessionId)
        inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
        inboundRekeyResponderSessionIds.remove(sessionId)
        clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
        rekeyInProgressSessionIds.remove(sessionId)
        rekeyCompletedSessionIds.remove(sessionId)
        strictPQCRequestedBySessionId.removeValue(forKey: sessionId)
        await notifyRemoteDesktopTerminalSessionIfNeeded(
            sessionId: sessionId,
            kind: .interrupted,
            reason: "strict_pqc_bootstrap_failed"
        )
        applyActiveSessionDisconnect(sessionId: sessionId, kind: .explicit)
        await disconnect(clearSnapshot: false)
        lastError = message
        state = .failed(message)
        readiness = .idle
    }

    private func syncInboundPQCRekeyState(
        sessionId: String,
        strictPQCRequested: Bool
    ) async {
        guard inboundRekeyResponderSessionIds.contains(sessionId),
              let driver = handshakeDriver else {
            return
        }

        let currentState = await driver.getCurrentState()
        switch currentState {
        case .established(let keys):
            if strictPQCRequested,
               !CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeyNegotiatedSuiteAllowed(
                    keys.negotiatedSuite,
                    strictPQCRequested: strictPQCRequested
               ) {
                let message =
                    "strictPQC WebRTC 入站 rekey 协商到了 Classic suite=\(keys.negotiatedSuite.rawValue)，当前关闭 classic bootstrap-only 会话。"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session=\(sessionId)"
                )
                await failStrictPQCBootstrapSession(sessionId: sessionId, message: message)
                return
            }
            sessionKeys = keys
            handshakeDriver = nil
            inboundRekeyResponderSessionIds.remove(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            rekeyCompletedSessionIds.insert(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
            lastRekeyEvent = "complete suite=\(keys.negotiatedSuite.rawValue)"

            if currentSessionId == sessionId {
                state = .connected(sessionId: sessionId)
                readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                noteRemoteAppActivity(sessionId: sessionId)
                if let activeSession = self.session {
                    startRemotePeerPingLoop(sessionId: sessionId, session: activeSession)
                }
                if let activeSession = self.session {
                    startRemotePeerLivenessWatchdog(sessionId: sessionId, session: activeSession)
                }
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .handshakeComplete,
                    deviceId: remoteDeviceId,
                    deviceName: remoteDeviceName,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                if shouldAutoStartRemoteDesktopHeartbeat() {
                    startRemoteDesktopHeartbeat()
                }
            }
            persistCurrentPathTrust(sessionId: sessionId)
            SkyBridgeLogger.shared.info(
                "✅ inbound WebRTC rekey 完成: session=\(sessionId), event=pqcRekeyComplete suite=\(keys.negotiatedSuite.rawValue)"
            )

        case .failed(let reason):
            handshakeDriver = nil
            inboundRekeyResponderSessionIds.remove(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            lastRekeyEvent = "failed reason=\(reason)"
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(reason)"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session=\(sessionId), event=pqcRekeyFailed"
                )
                lastError = message
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    disconnectKind: .explicit,
                    notificationKind: .interrupted,
                    reason: "strict_pqc_rekey_failed:\(reason)"
                )
                lastError = message
                state = .failed(message)
                readiness = .idle
                return
            }
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey 失败，保留既有会话: session=\(sessionId), event=pqcRekeyFailed reason=\(reason)"
            )

        default:
            break
        }
    }

    private func syncInboundInitialHandshakeState(
        sessionId: String,
        strictPQCRequested: Bool
    ) async {
        guard inboundInitialHandshakeResponderSessionIds.contains(sessionId),
              let driver = handshakeDriver else {
            return
        }

        let currentState = await driver.getCurrentState()
        switch currentState {
        case .established(let keys):
            let allowsClassicAuthorityBootstrap = inboundClassicAuthorityBootstrapSessionIds.contains(sessionId)
            if strictPQCRequested,
               !CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeNegotiatedSuiteAllowed(
                    keys.negotiatedSuite,
                    strictPQCRequested: strictPQCRequested,
                    allowsClassicAuthorityBootstrap: allowsClassicAuthorityBootstrap
               ) {
                handshakeDriver = nil
                inboundInitialHandshakeResponderSessionIds.remove(sessionId)
                inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
                clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
                let message =
                    "strictPQC WebRTC 初始握手协商到了 Classic suite=\(keys.negotiatedSuite.rawValue)，当前已拒绝建立会话。"
                SkyBridgeLogger.shared.error("⛔️ \(message) session=\(sessionId)")
                lastError = message
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    disconnectKind: .explicit,
                    notificationKind: .interrupted,
                    reason: "initial_handshake_failed:\(keys.negotiatedSuite.rawValue)"
                )
                lastError = message
                state = .failed(message)
                readiness = .idle
                return
            }

            sessionKeys = keys
            handshakeDriver = nil
            inboundInitialHandshakeResponderSessionIds.remove(sessionId)
            inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
            if strictPQCRequested,
               allowsClassicAuthorityBootstrap,
               !keys.negotiatedSuite.isPQCGroup {
                lastRekeyEvent = "bootstrapOnly suite=\(keys.negotiatedSuite.rawValue)"
                if let activeSession = self.session {
                    markStrictPQCClassicBootstrapOnly(sessionId: sessionId, session: activeSession)
                } else {
                    strictPQCClassicBootstrapOnlySessionIds.insert(sessionId)
                }
                SkyBridgeLogger.shared.warning(
                    "⏳ inbound WebRTC strictPQC classic authority bootstrap is bootstrap-only: session=\(sessionId), event=pqcRekeyPending suite=\(keys.negotiatedSuite.rawValue)"
                )
                if currentSessionId == sessionId,
                   let activeSession = self.session {
                    do {
                        try await sendPairingIdentityExchangeOverWebRTC(
                            sessionId: sessionId,
                            peerDeviceId: remoteDeviceId ?? handshakePeerId ?? sessionId,
                            session: activeSession,
                            force: true
                        )
                    } catch {
                        SkyBridgeLogger.shared.warning(
                            "⚠️ inbound WebRTC strictPQC bootstrap pairingIdentityExchange send failed: session=\(sessionId), err=\(error.localizedDescription)"
                        )
                    }
                }
                if currentSessionId == sessionId,
                   let activeSession = self.session {
                    startRemotePeerLivenessWatchdog(sessionId: sessionId, session: activeSession)
                }
                return
            }
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)

            if currentSessionId == sessionId {
                state = .connected(sessionId: sessionId)
                readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                noteRemoteAppActivity(sessionId: sessionId)
                if let activeSession = self.session {
                    startRemotePeerPingLoop(sessionId: sessionId, session: activeSession)
                    startRemotePeerLivenessWatchdog(sessionId: sessionId, session: activeSession)
                }
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .handshakeComplete,
                    deviceId: remoteDeviceId,
                    deviceName: remoteDeviceName,
                    negotiatedSuite: keys.negotiatedSuite.rawValue
                )
                if shouldAutoStartRemoteDesktopHeartbeat() {
                    startRemoteDesktopHeartbeat()
                }
            }
            persistCurrentPathTrust(sessionId: sessionId)
            SkyBridgeLogger.shared.info(
                "✅ inbound WebRTC 初始握手完成: session=\(sessionId), suite=\(keys.negotiatedSuite.rawValue)"
            )

        case .failed(let reason):
            handshakeDriver = nil
            inboundInitialHandshakeResponderSessionIds.remove(sessionId)
            inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
            let message = "WebRTC 握手失败: \(reason)"
            SkyBridgeLogger.shared.error(
                "❌ inbound WebRTC 初始握手失败: session=\(sessionId), reason=\(reason)"
            )
            lastError = message
            await terminateRemoteDesktopSession(
                sessionId: sessionId,
                disconnectKind: .explicit,
                notificationKind: .interrupted,
                reason: "initial_handshake_failed:\(reason)"
            )
            lastError = message
            state = .failed(message)
            readiness = .idle

        default:
            break
        }
    }

    func sendAppMessageOverWebRTC(
        _ message: AppMessage,
        sessionId: String,
        session: WebRTCSession,
        label: String
    ) async throws {
        guard currentSessionId == sessionId else { return }
        guard let keys = sessionKeys else { throw RemoteDesktopError.disconnected }
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encrypt(plaintext: payload, with: keys, packetType: .appControl)
        let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: label)
        try await sendFramed(padded, over: session)
    }

    func sendPairingIdentityExchangeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        force: Bool = false
    ) async throws {
        guard currentSessionId == sessionId else { return }
        if !force,
           let last = lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId],
           Date().timeIntervalSince(last) < 10 {
            return
        }

        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        )
        guard !kemKeys.isEmpty else { return }
        let localDeviceId = self.localDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localDeviceId.isEmpty else {
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC pairingIdentityExchange send skipped: empty localDeviceId session=\(sessionId)"
            )
            return
        }
        let identity = AuthenticationManager.instance.remoteControlSecurityIdentityMetadata
        let localIdentity = AppleMobileDeviceIdentity.currentSnapshot()

        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localDeviceId,
            kemPublicKeys: kemKeys,
            protocolIdentityPublicKeys: await localProtocolIdentityPublicKeysForPairing(),
            deviceName: localIdentity.deviceName,
            modelName: localIdentity.modelName,
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: nil,
            accountDisplayName: identity.accountDisplayName,
            nebulaId: identity.nebulaId,
            remoteVideoFormats: RemoteDesktopManager.supportedRemoteVideoFormats()
        ))
        try await sendAppMessageOverWebRTC(
            message,
            sessionId: sessionId,
            session: session,
            label: "tx/webrtc-bootstrap"
        )
        lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId] = Date()
        SkyBridgeLogger.shared.info(
            "📤 WebRTC pairingIdentityExchange sent: session=\(sessionId), peer=\(peerDeviceId), keys=\(kemKeys.count)"
        )
    }

    func handleInboundAppMessageOverWebRTC(
        _ message: AppMessage,
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async {
        switch message {
        case .pairingIdentityExchange(let payload):
            guard let payload = payload.normalizedBootstrapPayload else {
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC pairingIdentityExchange ignored: empty declaredDeviceId or empty KEM public key session=\(sessionId) peer=\(peerDeviceId)"
                )
                return
            }
            noteRemoteAppActivity(sessionId: sessionId)
            await KEMTrustStore.shared.upsert(deviceId: payload.deviceId, kemPublicKeys: payload.kemPublicKeys)
            await KEMTrustStore.shared.upsert(deviceId: peerDeviceId, kemPublicKeys: payload.kemPublicKeys)
            recordCurrentPathProtocolFingerprints(
                from: payload,
                sessionId: sessionId,
                peerDeviceId: peerDeviceId
            )
            if remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true {
                remoteDeviceId = payload.deviceId
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .transportReady,
                    deviceId: payload.deviceId,
                    deviceName: remoteDeviceName
                )
            }
            if handshakePeerId == nil || handshakePeerId?.hasPrefix("webrtc-") == true {
                handshakePeerId = payload.deviceId
            }
            SkyBridgeLogger.shared.info(
                "🔑 WebRTC bootstrap KEM cache updated: peer=\(peerDeviceId), declared=\(payload.deviceId), keys=\(payload.kemPublicKeys.count)"
            )

            do {
                try await sendPairingIdentityExchangeOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    force: false
                )
            } catch {
                SkyBridgeLogger.shared.debug("ℹ️ pairingIdentityExchange reply failed (ignored): \(error.localizedDescription)")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.maybeStartPQCRekeyOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    strictPQCRequested: strictPQCRequested,
                    trigger: "pairing_exchange"
                )
            }
        case .kemRefreshRequest, .signedKEMRefresh, .kemRefreshFailure,
             .protocolIdentityBindingRequest, .signedProtocolIdentityBinding:
            break
        case .heartbeat(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            if let deviceId = payload.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !deviceId.isEmpty,
               (remoteDeviceId == nil || remoteDeviceId?.hasPrefix("webrtc-") == true) {
                remoteDeviceId = deviceId
            }
            if let deviceName = payload.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !deviceName.isEmpty,
               (remoteDeviceName == nil || remoteDeviceName?.isEmpty == true) {
                remoteDeviceName = deviceName
            }
            updatePreparedSessionSnapshot(
                sessionId: sessionId,
                phase: {
                    if case .handshakeComplete = readiness {
                        return .handshakeComplete
                    }
                    return .transportReady
                }(),
                deviceId: remoteDeviceId,
                deviceName: remoteDeviceName,
                negotiatedSuite: {
                    if case .handshakeComplete(_, let suite) = readiness {
                        return suite
                    }
                    return nil
                }()
            )
        case .peerDisconnecting:
            noteRemoteAppActivity(sessionId: sessionId)
        case .ping(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            do {
                try await sendAppMessageOverWebRTC(
                    .pong(.init(id: payload.id)),
                    sessionId: sessionId,
                    session: session,
                    label: "tx/webrtc-pong"
                )
            } catch {
                // Best-effort reply.
            }
        case .pong:
            noteRemoteAppActivity(sessionId: sessionId)
        case .clipboard:
            noteRemoteAppActivity(sessionId: sessionId)
        }
    }

    func maybeStartPQCRekeyOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool,
        trigger: String
    ) async {
        guard currentSessionId == sessionId else { return }
        guard strictPQCRequested else { return }
        guard let establishedKeys = sessionKeys else { return }
        guard !establishedKeys.negotiatedSuite.isPQCGroup else { return }
        guard !rekeyInProgressSessionIds.contains(sessionId) else { return }
        guard !rekeyCompletedSessionIds.contains(sessionId) else { return }

        func failStrictClassicBootstrap(reason: String, diagnostic: String) async {
            guard strictPQCRequested, sessionKeys?.negotiatedSuite.isPQCGroup != true else { return }
            let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(diagnostic)"
            lastRekeyEvent = "failed strict reason=\(reason)"
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger)"
            )
            lastError = message
            handshakeDriver = nil
            rekeyInProgressSessionIds.remove(sessionId)
            rekeyCompletedSessionIds.remove(sessionId)
            await terminateRemoteDesktopSession(
                sessionId: sessionId,
                disconnectKind: .explicit,
                notificationKind: .interrupted,
                reason: "strict_pqc_rekey_failed:\(reason)"
            )
            lastError = message
            state = .failed(message)
            readiness = .idle
        }
        let hasPeerKEMEvidence = trigger != "post_bootstrap"

        guard let electionRemoteDeviceId = resolvedPQCRekeyElectionRemoteDeviceId(
            sessionId: sessionId,
            peerDeviceId: peerDeviceId
        ) else {
            lastRekeyEvent = "waiting peer=unknown election"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for concrete remote device id: session=\(sessionId), event=pqcRekeyPending trigger=\(trigger)"
            )
            if hasPeerKEMEvidence {
                await failStrictClassicBootstrap(
                    reason: "missing_remote_device_id",
                    diagnostic: "concrete remote device id unavailable"
                )
            }
            return
        }
        guard let shouldInitiate = Self.shouldInitiatePQCRekey(
            localDeviceId: localDeviceId,
            remoteDeviceId: electionRemoteDeviceId
        ) else {
            lastRekeyEvent = "waiting peer=\(electionRemoteDeviceId) election"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for stable initiator election: session=\(sessionId), event=pqcRekeyPending trigger=\(trigger), peer=\(electionRemoteDeviceId)"
            )
            if hasPeerKEMEvidence {
                await failStrictClassicBootstrap(
                    reason: "unstable_rekey_election",
                    diagnostic: "stable initiator election unavailable for peer \(electionRemoteDeviceId)"
                )
            }
            return
        }
        guard shouldInitiate else {
            lastRekeyEvent = "await inbound peer=\(electionRemoteDeviceId)"
            SkyBridgeLogger.shared.info(
                "ℹ️ WebRTC rekey elected peer as initiator; waiting inbound rekey: session=\(sessionId), event=pqcRekeyPending trigger=\(trigger), peer=\(electionRemoteDeviceId)"
            )
            return
        }

        let capability = CryptoProviderFactory.detectCapability()
        let selection: CryptoProviderFactory.SelectionPolicy = .requirePQC
        if !(capability.hasApplePQC || capability.hasLiboqs) {
            SkyBridgeLogger.shared.warning(
                "⚠️ skip WebRTC rekey: strictPQC requested but local PQC provider unavailable. " +
                "session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
            )
            await failStrictClassicBootstrap(
                reason: "local_pqc_provider_unavailable",
                diagnostic: "local device has no available Apple PQC or liboqs provider"
            )
            return
        }

        var candidateIds: [String] = []
        for raw in [
            currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId,
            peerDeviceId,
            remoteDeviceId,
            handshakePeerId
        ] {
            guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
            if !candidateIds.contains(id) {
                candidateIds.append(id)
            }
        }
        if candidateIds.isEmpty {
            await failStrictClassicBootstrap(
                reason: "missing_peer_candidates",
                diagnostic: "no peer id candidate available for trusted KEM lookup"
            )
            return
        }

        let defaultProvider = CryptoProviderFactory.make(policy: selection)
        let candidateSuites = CrossNetworkWebRTCPQCHandshakePolicy.strictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProvider: defaultProvider,
            appleXWingAvailable: Self.isAppleXWingRuntimeAvailableForRekey()
        )
        guard !candidateSuites.isEmpty else {
            await failStrictClassicBootstrap(
                reason: "local_pqc_suites_unavailable",
                diagnostic: "local PQC provider advertised no usable PQC suites"
            )
            return
        }

        var trustedKeysByCandidateId: [String: [CryptoSuite: Data]] = [:]
        for candidateId in candidateIds {
            trustedKeysByCandidateId[candidateId] = await KEMTrustStore.shared.kemPublicKeys(for: candidateId)
        }

        let prefersLiboqsForPeer = false
        let peerHasXWing = trustedKeysByCandidateId.values.contains { keys in
            keys.keys.contains { $0.canonicalKEMSuite == .xwing }
        }
        let providerPlans = CrossNetworkWebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: prefersLiboqsForPeer,
            peerHasXWing: peerHasXWing,
            appleXWingAvailable: Self.isAppleXWingRuntimeAvailableForRekey()
        )

        var selectedPeerId = peerDeviceId
        var trustedPeerKEM: [CryptoSuite: Data] = [:]
        var selectedAvailableSuites: [CryptoSuite] = []
        var selectedProvider: (any CryptoProvider)?
        var selectedProviderLabel = ""

        providerLoop: for plan in providerPlans {
            guard let planProvider = Self.webRTCPQCRekeyProvider(for: plan) else { continue }
            for candidate in candidateIds {
                let keys = trustedKeysByCandidateId[candidate] ?? [:]
                guard !keys.isEmpty else { continue }
                let coverage = CrossNetworkWebRTCPQCHandshakePolicy.resolveTrustedPeerKEMCoverage(
                    requiredSuites: plan.suites,
                    trustedPeerKEM: keys
                )
                if trustedPeerKEM.isEmpty {
                    selectedPeerId = candidate
                    trustedPeerKEM = keys
                    selectedAvailableSuites = coverage.availableSuites
                }
                if !coverage.availableSuites.isEmpty {
                    selectedPeerId = candidate
                    trustedPeerKEM = keys
                    selectedAvailableSuites = coverage.availableSuites
                    selectedProvider = planProvider
                    selectedProviderLabel = plan.label
                    break providerLoop
                }
            }
        }

        let coverage = CrossNetworkWebRTCPQCHandshakePolicy.resolveTrustedPeerKEMCoverage(
            requiredSuites: candidateSuites,
            trustedPeerKEM: trustedPeerKEM
        )
        let missingSuites = coverage.missingSuites
        let offeredSuites = selectedAvailableSuites.isEmpty ? coverage.availableSuites : selectedAvailableSuites
        guard !offeredSuites.isEmpty else {
            let missing = missingSuites.map(\.rawValue).joined(separator: ",")
            lastRekeyEvent = "waiting peer=\(selectedPeerId) missing=\(missing)"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for peer KEM keys: session=\(sessionId), event=pqcRekeyPending peer=\(selectedPeerId), missing=\(missing)"
            )
            if hasPeerKEMEvidence {
                await failStrictClassicBootstrap(
                    reason: "missing_common_peer_kem",
                    diagnostic: missing.isEmpty
                        ? "no common trusted peer PQC KEM key"
                        : "missing common trusted peer PQC KEM key(s): \(missing)"
                )
            }
            return
        }
        guard let selectedProvider else {
            SkyBridgeLogger.shared.warning(
                "⚠️ skip WebRTC rekey: no suite-aware PQC provider selected. session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger)"
            )
            await failStrictClassicBootstrap(
                reason: "suite_aware_provider_unavailable",
                diagnostic: "no suite-aware PQC provider matched the peer KEM material"
            )
            return
        }

        rekeyInProgressSessionIds.insert(sessionId)
        defer {
            rekeyInProgressSessionIds.remove(sessionId)
            handshakeDriver = nil
        }

        do {
            try await SkyBridgeiOSCore.shared.initialize(
                policy: selection,
                providerOverride: selectedProvider
            )
            let transport = makeHandshakeTransport(over: session)
            let peer = PeerIdentifier(deviceId: selectedPeerId)
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: candidateIds,
                additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionId)
            )
            let driver = try SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: transport,
                offeredSuites: offeredSuites,
                trustProvider: trustProvider
            )
            handshakeDriver = driver

            let suiteSummary = offeredSuites.map(\.rawValue).joined(separator: ",")
            lastRekeyEvent = "start peer=\(selectedPeerId) policy=\(selection.rawValue) suites=\(suiteSummary)"
            SkyBridgeLogger.shared.info(
                "🔁 WebRTC rekey start: session=\(sessionId), event=pqcRekeyStarted trigger=\(trigger), peer=\(selectedPeerId), policy=\(selection.rawValue), provider=\(selectedProviderLabel), offeredSuites=\(suiteSummary)"
            )
            let rekeyed = try await driver.initiateHandshake(with: peer)
            sessionKeys = rekeyed
            rekeyCompletedSessionIds.insert(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
            lastRekeyEvent = "complete suite=\(rekeyed.negotiatedSuite.rawValue)"

            if currentSessionId == sessionId {
                state = .connected(sessionId: sessionId)
                readiness = .handshakeComplete(
                    sessionId: sessionId,
                    negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                )
                noteRemoteAppActivity(sessionId: sessionId)
                startRemotePeerPingLoop(sessionId: sessionId, session: session)
                startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .handshakeComplete,
                    deviceId: remoteDeviceId,
                    deviceName: remoteDeviceName,
                    negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                )
                if shouldAutoStartRemoteDesktopHeartbeat() {
                    startRemoteDesktopHeartbeat()
                }
            }
            persistCurrentPathTrust(sessionId: sessionId)

            SkyBridgeLogger.shared.info(
                "✅ WebRTC rekey complete: session=\(sessionId), event=pqcRekeyComplete suite=\(rekeyed.negotiatedSuite.rawValue)"
            )
        } catch {
            lastRekeyEvent = "failed error=\(error.localizedDescription)"
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(error.localizedDescription)"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger)"
                )
                lastError = message
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    disconnectKind: .explicit,
                    notificationKind: .interrupted,
                    reason: "strict_pqc_rekey_failed:\(error.localizedDescription)"
                )
                lastError = message
                state = .failed(message)
                readiness = .idle
                return
            }
            SkyBridgeLogger.shared.error(
                "❌ WebRTC rekey failed: session=\(sessionId), event=pqcRekeyFailed trigger=\(trigger), err=\(error.localizedDescription)"
            )
        }
    }
}

@available(iOS 17.0, *)
private extension CrossNetworkWebRTCManager {
    @discardableResult
    private func handleDecodedScreenPlaintext(_ plaintext: Data) -> Bool {
        guard let screenData = Self.decodeScreenDataPayload(plaintext) else { return false }
        publishDecodedScreenData(screenData)
        return true
    }

    private func publishDecodedScreenData(_ screenData: ScreenData) {
        noteCurrentSessionActivity()
        lastScreenData = screenData
#if canImport(WebRTC)
        lastScreenDataAt = Date()
        maybeConfirmRemoteVideoTrackFromFallbackEvidence(now: lastScreenDataAt ?? Date())
#endif
        postScreenFrameNotification(screenData)
    }

    private func postScreenFrameNotification(_ screenData: ScreenData) {
        guard let sessionId = activeRemoteDesktopSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return
        }

        NotificationCenter.default.post(
            name: .crossNetworkScreenDataUpdated,
            object: nil,
            userInfo: [
                CrossNetworkNotificationUserInfoKey.sessionId: sessionId,
                CrossNetworkNotificationUserInfoKey.screenData: screenData
            ]
        )
    }

    @MainActor
    private func sessionKeysIfCurrent(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> SessionKeys? {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return nil
        }
        return sessionKeys
    }

    @MainActor
    private func isCurrentSession(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return false
        }
        return true
    }

    @MainActor
    private func isStrictPQCClassicBootstrapOnlyCurrentSession(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return false
        }
        return strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)
    }

    @MainActor
    @discardableResult
    private func publishHighThroughputRemoteDesktopPayloadIfCurrent(
        _ payload: RemoteDesktopControlPayloadDecodeResult,
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            return false
        }

        guard !isStrictPQCClassicBootstrapOnlyCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            appendSmokeTrace("strict-pqc-bootstrap drop media payload source=control-channel session=\(sessionId)")
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap dropped media payload before PQC rekey: session=\(sessionId) source=control-channel"
            )
            return false
        }

        switch payload {
        case .screen(let screenData):
            publishDecodedScreenData(screenData)
        case .audio(let audioChunk):
            RemoteDesktopManager.instance.handleInboundRemoteAudioChunk(audioChunk)
        }
        return true
    }

    @discardableResult
    private func handleDecodedControlPlaintext(
        _ plaintext: Data,
        packetType: WebRTCAppSecurePacketType,
        sessionId: String,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> Bool {
        if packetType == .appControl,
           let appMessage = try? JSONDecoder().decode(AppMessage.self, from: plaintext) {
            if strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) {
                let messageKind = Self.bootstrapAppMessageKind(appMessage)
                switch appMessage {
                case .pairingIdentityExchange:
                    break
                case .heartbeat, .ping, .pong, .peerDisconnecting:
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC strictPQC classic bootstrap accepted control app message before PQC rekey: session=\(sessionId) type=\(messageKind) lastRekey=\(lastRekeyEvent ?? "-")"
                    )
                default:
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC strictPQC classic bootstrap ignored non-bootstrap app message: session=\(sessionId) type=\(messageKind) lastRekey=\(lastRekeyEvent ?? "-")"
                    )
                    return true
                }
            }
            await handleInboundAppMessageOverWebRTC(
                appMessage,
                sessionId: sessionId,
                peerDeviceId: peer.deviceId,
                session: session,
                strictPQCRequested: strictPQCRequested
            )
            return true
        }

        guard !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) else {
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap ignored business payload before PQC rekey: session=\(sessionId)"
            )
            return true
        }

        if packetType == .fileTransfer,
           let fileTransfer = try? JSONDecoder().decode(CrossNetworkFileTransferMessage.self, from: plaintext),
           fileTransfer.version == 1 {
            await handleInboundFileTransferFromMac(fileTransfer)
            return true
        }

        if packetType == .remoteDesktopAudio {
            if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(plaintext) {
                RemoteDesktopManager.instance.handleInboundRemoteAudioChunk(audioChunk)
                return true
            }
            return false
        }

        if packetType == .remoteDesktop {
            if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(plaintext) {
                RemoteDesktopManager.instance.handleInboundRemoteAudioChunk(audioChunk)
                return true
            }

            if handleDecodedScreenPlaintext(plaintext) { return true }
        }

        guard packetType == .remoteControl else {
            return false
        }

        guard let msg = try? JSONDecoder().decode(RemoteMessage.self, from: plaintext) else {
            return false
        }

        if msg.type == .damageReport,
           let report = try? JSONDecoder().decode(RemoteDesktopDamageReportPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundDamageReport(report)
            return true
        }

        if msg.type == .cursorUpdate,
           let payload = try? JSONDecoder().decode(RemoteDesktopCursorPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundCursorUpdate(payload)
            return true
        }

        if msg.type == .overlayUpdate,
           let payload = try? JSONDecoder().decode(RemoteDesktopOverlayPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundOverlayUpdate(payload)
            return true
        }

        if msg.type == .streamConfigurationAck,
           let payload = try? JSONDecoder().decode(RemoteDesktopStreamConfigurationAckPayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleStreamConfigurationAck(payload)
            return true
        }

        if msg.type == .clipboard,
           let payload = try? JSONDecoder().decode(RemoteClipboardMessagePayload.self, from: msg.payload) {
            RemoteDesktopManager.instance.handleInboundRemoteClipboard(
                data: payload.data,
                mimeType: payload.mimeType,
                fromDeviceId: remoteDeviceId
            )
            return true
        }

        return false
    }

    private static func bootstrapAppMessageKind(_ message: AppMessage) -> String {
        CrossNetworkWebRTCControlChannelCodec.bootstrapAppMessageKind(message)
    }

    nonisolated private func isLikelyCompleteHandshakeControlPacket(_ data: Data) -> Bool {
        CrossNetworkWebRTCControlChannelCodec.isLikelyCompleteHandshakeControlPacket(data)
    }

    nonisolated private func isActiveHandshakeDriverFrame(_ data: Data) -> Bool {
        CrossNetworkWebRTCControlChannelCodec.isActiveHandshakeDriverFrame(data)
    }

    private func hasActiveHandshakeDriver() -> Bool {
        handshakeDriver != nil
    }

    @discardableResult
    private func handlePossibleHandshakeControlFrame(
        _ frame: Data,
        sessionId: String,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> Bool {
        let inboundInitialDriver = await ensureInboundInitialHandshakeDriverIfNeeded(
            sessionId: sessionId,
            frame: frame,
            peer: peer,
            session: session,
            strictPQCRequested: strictPQCRequested
        )
        let inboundRekeyDriver = await ensureInboundPQCRekeyDriverIfNeeded(
            sessionId: sessionId,
            frame: frame,
            peer: peer,
            session: session,
            strictPQCRequested: strictPQCRequested
        )

        if let inboundDriver = inboundInitialDriver ?? inboundRekeyDriver {
            if let messageA = try? HandshakeMessageA.decode(from: frame) {
                let suites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                appendSmokeTrace("rx messageA raw=\(frame.count) suites=\(suites)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx MessageA raw=\(frame.count) suites=\(suites)")
                }
            }
            await inboundDriver.handleMessage(frame, from: peer)
            if inboundInitialHandshakeResponderSessionIds.contains(sessionId) {
                await syncInboundInitialHandshakeState(
                    sessionId: sessionId,
                    strictPQCRequested: strictPQCRequested
                )
            } else {
                await syncInboundPQCRekeyState(
                    sessionId: sessionId,
                    strictPQCRequested: strictPQCRequested
                )
            }
            return true
        }

        if let driver = handshakeDriver {
            guard isActiveHandshakeDriverFrame(frame) else {
                return false
            }
            if let messageB = try? HandshakeMessageB.decode(from: frame) {
                lastRekeyEvent = "messageB suite=\(messageB.selectedSuite.rawValue)"
                appendSmokeTrace("rx messageB raw=\(frame.count) suite=\(messageB.selectedSuite.rawValue)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx MessageB raw=\(frame.count) suite=\(messageB.selectedSuite.rawValue)")
                }
            } else if (try? HandshakeFinished.decode(from: frame)) != nil {
                lastRekeyEvent = "finished"
                appendSmokeTrace("rx finished raw=\(frame.count)")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx Finished raw=\(frame.count)")
                }
            }
            await driver.handleMessage(frame, from: peer)
            await syncInboundPQCRekeyState(
                sessionId: sessionId,
                strictPQCRequested: strictPQCRequested
            )
            return true
        }

        return false
    }

    nonisolated func receiveLoop(
        sessionId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue,
        peer: PeerIdentifier,
        strictPQCRequested: Bool
    ) async {
        let sessionObjectIdentifier = ObjectIdentifier(session)
        let maxInboundFrameBytes = 8_000_000
        do {
            self.appendSmokeTrace("receiveLoop start session=\(sessionId)")
            var parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            var usesDirectControlPayloads = false
            while !Task.isCancelled {
                let chunk = try await inbound.next()

                if parser.canProbeDirectCompatibility,
                   await isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                   ) {
                    if let keys = await sessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ), let openedCandidate = Self.openDirectControlProbePayload(chunk, keys: keys) {
                        let openedPayload: WebRTCAppSecureOpenedPayload
                        do {
                            openedPayload = try await validateWebRTCSecureOpenedPayload(
                                openedCandidate,
                                with: keys,
                                sessionId: sessionId
                            )
                        } catch {
                            self.appendSmokeTrace(
                                "control-channel direct secure payload rejected session=\(sessionId) err=\(error.localizedDescription)"
                            )
                            continue
                        }

                        let plaintext = openedPayload.payload
                        if openedPayload.packetType == .remoteDesktopAudio,
                           let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(plaintext) {
                            let published = await publishHighThroughputRemoteDesktopPayloadIfCurrent(
                                .audio(audioChunk),
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier
                            )
                            if published && !usesDirectControlPayloads {
                                usesDirectControlPayloads = true
                                parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
                                self.appendSmokeTrace(
                                    "control-channel direct-audio-payload compatibility mode session=\(sessionId) bytes=\(chunk.count)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ WebRTC 控制通道检测到直发远桌音频数据模式，已在后台数据面处理: session=\(sessionId)"
                                )
                            }
                            continue
                        }

                        if openedPayload.packetType == .remoteDesktop,
                           let decoded = Self.decodeRemoteDesktopHighThroughputPayload(plaintext) {
                            let published = await publishHighThroughputRemoteDesktopPayloadIfCurrent(
                                decoded,
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier
                            )
                            if published && !usesDirectControlPayloads {
                                usesDirectControlPayloads = true
                                parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
                                self.appendSmokeTrace(
                                    "control-channel direct-payload compatibility mode session=\(sessionId) bytes=\(chunk.count)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ WebRTC 控制通道检测到直发远桌数据模式，已在后台数据面处理: session=\(sessionId)"
                                )
                            }
                            continue
                        }

                        if await handleDecodedControlPlaintext(
                            plaintext,
                            packetType: openedPayload.packetType,
                            sessionId: sessionId,
                            peer: peer,
                            session: session,
                            strictPQCRequested: strictPQCRequested
                        ) {
                            if !usesDirectControlPayloads {
                                usesDirectControlPayloads = true
                                parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
                                self.appendSmokeTrace(
                                    "control-channel direct-payload compatibility mode session=\(sessionId) bytes=\(chunk.count)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ WebRTC 控制通道检测到直发兼容模式，已跳过分帧解析: session=\(sessionId)"
                                )
                            }
                            continue
                        }
                    }

                    let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(chunk, label: "rx/webrtc")
                    let handshakeUnwrapped = HandshakePadding.unwrapIfNeeded(
                        trafficUnwrapped,
                        label: "rx/webrtc-direct"
                    )
                    if isLikelyCompleteHandshakeControlPacket(handshakeUnwrapped),
                       await handlePossibleHandshakeControlFrame(
                        handshakeUnwrapped,
                        sessionId: sessionId,
                        peer: peer,
                        session: session,
                        strictPQCRequested: strictPQCRequested
                       ) {
                        if !usesDirectControlPayloads {
                            usesDirectControlPayloads = true
                            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
                            self.appendSmokeTrace(
                                "control-channel direct-handshake compatibility mode session=\(sessionId) bytes=\(chunk.count)"
                            )
                            SkyBridgeLogger.shared.info(
                                "ℹ️ WebRTC 控制通道检测到直发握手兼容模式，已跳过分帧解析: session=\(sessionId)"
                            )
                        }
                        continue
                    }
                }
                parser.append(chunk)

                while let payload = parser.nextPayload(sessionId: sessionId, logLabel: "WebRTC") {
                    let length = payload.count
                    let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        print("🧪 WebRTC rekey rx frame len=\(length)")
                    }
                    let handshakeFrame = HandshakePadding.unwrapIfNeeded(
                        trafficUnwrapped,
                        label: "rx/webrtc"
                    )
                    let hasActiveDriver = await hasActiveHandshakeDriver()
                    if (isLikelyCompleteHandshakeControlPacket(handshakeFrame) ||
                        (hasActiveDriver && isActiveHandshakeDriverFrame(handshakeFrame))),
                       await handlePossibleHandshakeControlFrame(
                        handshakeFrame,
                        sessionId: sessionId,
                        peer: peer,
                        session: session,
                        strictPQCRequested: strictPQCRequested
                       ) {
                        continue
                    }
                    let hasSessionKeys: Bool
                    if let keys = await sessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ) {
                        hasSessionKeys = true
                        do {
                            let openedPayload = try await decrypt(ciphertext: trafficUnwrapped, with: keys)
                            let plaintext = openedPayload.payload
                            if openedPayload.packetType == .remoteDesktopAudio,
                               let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(plaintext) {
                                _ = await publishHighThroughputRemoteDesktopPayloadIfCurrent(
                                    .audio(audioChunk),
                                    sessionId: sessionId,
                                    sessionObjectIdentifier: sessionObjectIdentifier
                                )
                                continue
                            }

                            if openedPayload.packetType == .remoteDesktop,
                               let decoded = Self.decodeRemoteDesktopHighThroughputPayload(plaintext) {
                                _ = await publishHighThroughputRemoteDesktopPayloadIfCurrent(
                                    decoded,
                                    sessionId: sessionId,
                                    sessionObjectIdentifier: sessionObjectIdentifier
                                )
                                continue
                            }
                            if await handleDecodedControlPlaintext(
                                plaintext,
                                packetType: openedPayload.packetType,
                                sessionId: sessionId,
                                peer: peer,
                                session: session,
                                strictPQCRequested: strictPQCRequested
                            ) {
                                continue
                            }
                        } catch {
                            // Fall through into handshake-control handling.
                        }
                    } else {
                        hasSessionKeys = false
                    }
                    self.appendSmokeTrace("rx frame len=\(length) keys=\(hasSessionKeys)")

                    if isLikelyCompleteHandshakeControlPacket(handshakeFrame) {
                        _ = await handlePossibleHandshakeControlFrame(
                            handshakeFrame,
                            sessionId: sessionId,
                            peer: peer,
                            session: session,
                            strictPQCRequested: strictPQCRequested
                        )
                    } else if strictPQCRequested, hasSessionKeys, length >= 1024 {
                        let sbp1Wrapped = trafficUnwrapped.count >= 4
                            && trafficUnwrapped.prefix(4).elementsEqual([0x53, 0x42, 0x50, 0x31])
                        let firstByte = handshakeFrame.first
                            .map { String(format: "%02x", $0) } ?? "-"
                        let decodeFailure: String
                        do {
                            _ = try HandshakeMessageA.decode(from: handshakeFrame)
                            decodeFailure = "none"
                        } catch {
                            decodeFailure = CrossNetworkWebRTCTraceDescription.smokeTraceToken(error.localizedDescription)
                        }
                        self.appendSmokeTrace(
                            "handshake-control decode-miss session=\(sessionId) frame=\(length) raw=\(handshakeFrame.count) first=\(firstByte) sbp1=\(sbp1Wrapped) messageA=\(decodeFailure)"
                        )
                    }
                }
            }
        } catch {
            self.appendSmokeTrace("receiveLoop ended error=\(error.localizedDescription)")
        }
    }

    nonisolated func receiveScreenLoop(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        inbound: InboundChunkQueue
    ) async {
        let maxInboundFrameBytes = 8_000_000
        do {
            self.appendSmokeTrace("screen-receiveLoop start session=\(sessionId)")
            var wireDecoder = ScreenChannelWireDecoder(maxInboundFrameBytes: maxInboundFrameBytes)
            var announcedWireMode: ScreenChannelWireDecoder.Mode?

            while !Task.isCancelled {
                let chunk = try await inbound.next()
                let now = Date()
                let keys = await screenReceiveSessionKeysIfCurrent(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                )

                if let keys,
                   let pending = wireDecoder.takePendingDirectCandidate(now: now) {
                    if let screenData = await decodeDirectScreenChannelPayloadIfFresh(
                        pending,
                        keys: keys,
                        sessionId: sessionId
                    ) {
                        wireDecoder.markDirectPayloadMode()
                        if announcedWireMode != wireDecoder.mode {
                            announcedWireMode = wireDecoder.mode
                            self.appendSmokeTrace(
                                "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) bytes=\(pending.count) source=pending-direct"
                            )
                            SkyBridgeLogger.shared.info(
                                "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                            )
                        }
                        await publishDecodedScreenDataIfCurrent(
                            screenData,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )
                    } else {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=waiting-keys-drop session=\(sessionId) bytes=\(pending.count)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct candidate 解密失败，已丢弃: mode=waiting-keys-drop session=\(sessionId) bytes=\(pending.count)"
                        )
                    }
                }

                if wireDecoder.isChunkedPayload(chunk) {
                    switch wireDecoder.appendChunkedPayload(chunk, now: now) {
                    case .waiting(let frameId, let chunkIndex, let chunkCount):
                        if chunkIndex == 0 {
                            self.appendSmokeTrace(
                                "screen-channel wire=sbc2-chunked-v1 frameId=\(frameId) chunk=1/\(chunkCount) session=\(sessionId)"
                            )
                        }
                        continue
                    case .dropped(let reason, let frameId):
                        self.appendSmokeTrace(
                            "screen-channel wire=sbc2-chunked-v1 reassemblyDropReason=\(reason) frameId=\(frameId.map(String.init) ?? "-") session=\(sessionId)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel SBC2 分片已丢弃: reason=\(reason) frameId=\(frameId.map(String.init) ?? "-") session=\(sessionId)"
                        )
                        continue
                    case .suppressed:
                        continue
                    case .complete(let frameId, let payload):
                        guard let frameKeys = await screenReceiveSessionKeysIfCurrent(
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        ) else {
                            self.appendSmokeTrace(
                                "screen-channel wire=sbc2-chunked-v1 waiting-keys-drop frameId=\(frameId) session=\(sessionId)"
                            )
                            continue
                        }
                        do {
                            guard let screenData = try await decodeEncryptedScreenChannelPayloadIfFresh(
                                payload,
                                keys: frameKeys,
                                sessionId: sessionId
                            ) else {
                                continue
                            }
                            wireDecoder.markChunkedPayloadMode()
                            if announcedWireMode != wireDecoder.mode {
                                announcedWireMode = wireDecoder.mode
                                self.appendSmokeTrace(
                                    "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) frameId=\(frameId)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                                )
                            }
                            await publishDecodedScreenDataIfCurrent(
                                screenData,
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier
                            )
                        } catch {
                            self.appendSmokeTrace(
                                "screen-channel wire=sbc2-chunked-v1 decryptFailed frameId=\(frameId) session=\(sessionId)"
                            )
                            SkyBridgeLogger.shared.debug(
                                "ℹ️ screen-channel SBC2 payload 解密/解析失败: \(error.localizedDescription)"
                            )
                        }
                        continue
                    }
                }

                if wireDecoder.mode == .directPayload {
                    guard let keys else {
                        _ = wireDecoder.cacheDirectCandidateIfPossible(chunk, now: now)
                        self.appendSmokeTrace(
                            "screen-channel wireMode=directPayload waiting-keys session=\(sessionId) bytes=\(chunk.count)"
                        )
                        continue
                    }

                    if let screenData = await decodeDirectScreenChannelPayloadIfFresh(
                        chunk,
                        keys: keys,
                        sessionId: sessionId
                    ) {
                        await publishDecodedScreenDataIfCurrent(
                            screenData,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )
                    } else {
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct payload 解密/解析失败，已丢弃: session=\(sessionId) bytes=\(chunk.count)"
                        )
                    }
                    continue
                }

                if wireDecoder.canProbeDirectPayload,
                   let keys,
                   let screenData = await decodeDirectScreenChannelPayloadIfFresh(
                       chunk,
                       keys: keys,
                       sessionId: sessionId
                   ) {
                    wireDecoder.markDirectPayloadMode()
                    if announcedWireMode != wireDecoder.mode {
                        announcedWireMode = wireDecoder.mode
                        self.appendSmokeTrace(
                            "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) bytes=\(chunk.count) source=direct-probe"
                        )
                        SkyBridgeLogger.shared.info(
                            "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                        )
                    }
                    await publishDecodedScreenDataIfCurrent(
                        screenData,
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    )
                    continue
                }

                if wireDecoder.shouldKeepOutOfLengthParser(chunk) {
                    if keys == nil,
                       wireDecoder.cacheDirectCandidateIfPossible(chunk, now: now) {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=waiting-keys-cache session=\(sessionId) bytes=\(chunk.count)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct-looking payload 已等待密钥后重试: session=\(sessionId) bytes=\(chunk.count)"
                        )
                    } else {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=direct-candidate-drop session=\(sessionId) bytes=\(chunk.count)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct-looking payload 未通过解密/解析，已丢弃且未进入 length parser: session=\(sessionId) bytes=\(chunk.count)"
                        )
                    }
                    continue
                }

                wireDecoder.appendLengthChunk(chunk)

                while let payload = wireDecoder.nextLengthPayload(sessionId: sessionId, logLabel: "screen-channel") {
                    guard let frameKeys = await screenReceiveSessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ) else {
                        continue
                    }

                    do {
                        guard let screenData = try await decodeEncryptedScreenChannelPayloadIfFresh(
                            payload,
                            keys: frameKeys,
                            sessionId: sessionId
                        ) else {
                            wireDecoder.resetLengthFramedAfterDecodeFailure()
                            announcedWireMode = nil
                            self.appendSmokeTrace(
                                "screen-channel wire=length-framed decodeEmpty reset session=\(sessionId)"
                            )
                            continue
                        }
                        wireDecoder.markLengthFramedMode()
                        if announcedWireMode != wireDecoder.mode {
                            announcedWireMode = wireDecoder.mode
                            self.appendSmokeTrace(
                                "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) payloadBytes=\(payload.count)"
                            )
                            SkyBridgeLogger.shared.info(
                                "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session=\(sessionId)"
                            )
                        }
                        await publishDecodedScreenDataIfCurrent(
                            screenData,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )
                    } catch {
                        switch Self.screenLengthFramedDecodeFailureAction(for: error) {
                        case .dropAuthenticatedReplay(let packetType, let counter, let highestCounter, let reason):
                            self.appendSmokeTrace(
                                """
                                screen-channel wire=length-framed replayDrop session=\(sessionId) packetType=\(packetType.rawValue) \
                                counter=\(counter) highestCounter=\(highestCounter) reason=\(reason.rawValue) action=drop-authenticated-replay
                                """
                            )
                            SkyBridgeLogger.shared.debug(
                                "ℹ️ screen-channel authenticated replay 已丢弃且保留 length parser: packetType=\(packetType.rawValue) counter=\(counter) highestCounter=\(highestCounter) reason=\(reason.rawValue)"
                            )
                        case .resetParser:
                            wireDecoder.resetLengthFramedAfterDecodeFailure()
                            announcedWireMode = nil
                            self.appendSmokeTrace(
                                "screen-channel wire=length-framed decryptFailed reset session=\(sessionId)"
                            )
                            SkyBridgeLogger.shared.debug(
                                "ℹ️ screen-channel payload 解密/解析失败，已重置 length parser: wireMode=lengthFramed \(error.localizedDescription)"
                            )
                        }
                    }
                }
            }
        } catch {
            self.appendSmokeTrace("screen-receiveLoop ended error=\(error.localizedDescription)")
        }
    }

    nonisolated private func decodeDirectScreenChannelPayloadIfFresh(
        _ payload: Data,
        keys: SessionKeys,
        sessionId: String
    ) async -> ScreenData? {
        guard let openedPayload = try? Self.openScreenChannelPayload(payload, keys: keys) else {
            return nil
        }
        guard let freshPayload = try? await validateWebRTCSecureOpenedPayload(
            openedPayload,
            with: keys,
            sessionId: sessionId
        ) else {
            return nil
        }
        return Self.decodeScreenChannelPayload(freshPayload)
    }

    nonisolated private func decodeEncryptedScreenChannelPayloadIfFresh(
        _ payload: Data,
        keys: SessionKeys,
        sessionId: String
    ) async throws -> ScreenData? {
        let openedPayload = try Self.openScreenChannelPayload(payload, keys: keys)
        let freshPayload = try await validateWebRTCSecureOpenedPayload(
            openedPayload,
            with: keys,
            sessionId: sessionId
        )
        return Self.decodeScreenChannelPayload(freshPayload)
    }

    @MainActor
    private func screenReceiveSessionKeysIfCurrent(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> SessionKeys? {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return nil
        }
        return sessionKeys
    }

    @MainActor
    @discardableResult
    private func publishDecodedScreenDataIfCurrent(
        _ screenData: ScreenData,
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard currentSessionId == sessionId,
              let session,
              ObjectIdentifier(session) == sessionObjectIdentifier else {
            return false
        }
        guard !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) else {
            appendSmokeTrace("strict-pqc-bootstrap drop media payload source=screen-channel session=\(sessionId)")
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap dropped media payload before PQC rekey: session=\(sessionId) source=screen-channel"
            )
            return false
        }
        publishDecodedScreenData(screenData)
        return true
    }

    nonisolated func appendSmokeTrace(_ line: String) {
        SkyBridgeSmokeTraceWriter.append(line)
    }

    nonisolated private func describeEnvelope(_ envelope: WebRTCSignalingEnvelope) -> String {
        CrossNetworkWebRTCTraceDescription.describeEnvelope(envelope)
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    func decrypt(
        ciphertext: Data,
        with keys: SessionKeys,
        allowedPacketTypes: Set<WebRTCAppSecurePacketType> = Set(WebRTCAppSecurePacketType.allCases)
    ) throws -> WebRTCAppSecureOpenedPayload {
        try openWebRTCSecurePayload(
            ciphertext,
            with: keys,
            sessionId: currentSessionId ?? keys.sessionId,
            allowedPacketTypes: allowedPacketTypes
        )
    }

    func sealWebRTCSecurePayload(
        _ plaintext: Data,
        with keys: SessionKeys,
        sessionId: String,
        packetType: WebRTCAppSecurePacketType
    ) throws -> Data {
        resetWebRTCSecureEnvelopeStateIfNeeded(sessionId: sessionId, keys: keys)
        let counter = try nextWebRTCSecureEnvelopeCounter(for: sessionId)
        return try CrossNetworkWebRTCControlChannelCodec.encryptAppPayload(
            plaintext,
            with: keys,
            packetType: packetType,
            counter: counter
        )
    }

    func openWebRTCSecurePayload(
        _ ciphertext: Data,
        with keys: SessionKeys,
        sessionId: String,
        allowedPacketTypes: Set<WebRTCAppSecurePacketType> = Set(WebRTCAppSecurePacketType.allCases)
    ) throws -> WebRTCAppSecureOpenedPayload {
        resetWebRTCSecureEnvelopeStateIfNeeded(sessionId: sessionId, keys: keys)
        let opened = try CrossNetworkWebRTCControlChannelCodec.decryptAppPayload(
            ciphertext,
            with: keys,
            allowedPacketTypes: allowedPacketTypes
        )
        return try validateWebRTCSecureOpenedPayload(opened, with: keys, sessionId: sessionId)
    }

    func validateWebRTCSecureOpenedPayload(
        _ opened: WebRTCAppSecureOpenedPayload,
        with keys: SessionKeys,
        sessionId: String
    ) throws -> WebRTCAppSecureOpenedPayload {
        resetWebRTCSecureEnvelopeStateIfNeeded(sessionId: sessionId, keys: keys)
        var replayWindow = webRTCSecureEnvelopeReplayWindowBySessionId[sessionId] ?? WebRTCAppSecureReplayWindow()
        try replayWindow.validateAndRecord(opened)
        webRTCSecureEnvelopeReplayWindowBySessionId[sessionId] = replayWindow
        return opened
    }

    func clearWebRTCSecureEnvelopeState(for sessionId: String) {
        webRTCSecureEnvelopeSendCounterBySessionId.removeValue(forKey: sessionId)
        webRTCSecureEnvelopeReplayWindowBySessionId.removeValue(forKey: sessionId)
        webRTCSecureEnvelopeKeyFingerprintBySessionId.removeValue(forKey: sessionId)
    }

    private func resetWebRTCSecureEnvelopeStateIfNeeded(sessionId: String, keys: SessionKeys) {
        let fingerprint = Self.webRTCSecureEnvelopeKeyFingerprint(for: keys)
        guard webRTCSecureEnvelopeKeyFingerprintBySessionId[sessionId] != fingerprint else { return }
        webRTCSecureEnvelopeSendCounterBySessionId[sessionId] = 0
        webRTCSecureEnvelopeReplayWindowBySessionId[sessionId] = WebRTCAppSecureReplayWindow()
        webRTCSecureEnvelopeKeyFingerprintBySessionId[sessionId] = fingerprint
    }

    private func nextWebRTCSecureEnvelopeCounter(for sessionId: String) throws -> UInt64 {
        let current = webRTCSecureEnvelopeSendCounterBySessionId[sessionId] ?? 0
        guard current < UInt64.max else {
            throw WebRTCAppSecureEnvelopeError.counterExhausted
        }
        let next = current + 1
        webRTCSecureEnvelopeSendCounterBySessionId[sessionId] = next
        return next
    }

    nonisolated private static func webRTCSecureEnvelopeKeyFingerprint(for keys: SessionKeys) -> String {
        var input = Data("SkyBridge-WebRTC-App-State-v1|".utf8)
        input.append(Data(keys.sessionId.utf8))
        input.append(0)
        input.append(Data(keys.role.rawValue.utf8))
        input.append(0)
        input.append(keys.transcriptHash)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}
