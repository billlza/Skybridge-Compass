import Foundation
import Network
import CryptoKit
import Combine
import OSLog
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia
import CoreGraphics
import ImageIO
import ApplicationServices
import UniformTypeIdentifiers
import VideoToolbox
#if canImport(WebRTCAudioDeviceBridge)
import WebRTCAudioDeviceBridge
#endif
#if os(iOS)
import UIKit
#endif

/// 跨网络连接管理器 - 2025年创新架构
///
/// 三层连接方案：
/// 1. 动态二维码 + NFC 近场连接
/// 2. Apple ID / iCloud 设备链（零配置）
/// 3. 智能连接码 + P2P 穿透（通用方案）
@MainActor
public final class CrossNetworkConnectionManager: ObservableObject {
    /// Shared instance so multiple views (connection + file transfer) can operate on the same active WebRTC session.
    public static let shared = CrossNetworkConnectionManager()

 // MARK: - 发布属性

    @Published public var connectionCode: String?
    @Published public private(set) var connectionCodeExpiresAt: Date?
    @Published public var connectionCodeLeaseMode: ConnectionCodeLeaseMode = .shortLived {
        didSet {
            UserDefaults.standard.set(connectionCodeLeaseMode.rawValue, forKey: Self.connectionCodeLeaseModeDefaultsKey)
        }
    }
    @Published public var qrCodeData: Data?
    @Published public var availableCloudDevices: [CloudDevice] = []
    @Published public var connectionStatus: CrossNetworkConnectionStatus = .idle
    @Published public private(set) var readiness: CrossNetworkReadiness = .idle
    @Published public private(set) var lastRekeyEvent: String?
    @Published public var currentConnection: RemoteConnection?
    @Published public private(set) var activeSessionSnapshot: ActiveSessionSnapshot?
    @Published public private(set) var signalingHealth: SignalingSessionHealth = .healthy
    @Published public private(set) var signalingLifecyclePhase: WebSocketSignalingClient.SignalingLifecyclePhase = .idle

 // MARK: - 私有属性

    private let logger = Logger(subsystem: "com.skybridge.connection", category: "CrossNetwork")
    private let signalServer: SignalServerClient
    private let iceServers: [String] = [SkyBridgeServerConfig.stunURL]
        + SkyBridgeServerConfig.turnURLs
        + [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302"
        ]
    private var activeListeners: [ConnectionListener] = []
    var deviceFingerprint: String
    nonisolated static let qrCodeGenerationWatchdogTimeoutSeconds: TimeInterval = 30
    nonisolated static let qrCodeScanBootstrapWatchdogTimeoutSeconds: TimeInterval = 90
    nonisolated static let qrCodeConnectLinkMaximumByteCount = 1_800
    nonisolated static let webRTCStartupJoinHeartbeatAttempts = 60
    nonisolated private static let protocolIdentityLogRedaction = "<redacted>"
    nonisolated private static func streamRefreshTokenLogState(_ token: UInt64?) -> String {
        token == nil ? "missing" : "present"
    }
    private static let connectionCodeLeaseModeDefaultsKey = "cross_network_connection_code_lease_mode.macos"
    private var activeSessionReconnectTimeoutTask: Task<Void, Never>?
    private var activeConnectionCodeLeaseMode: ConnectionCodeLeaseMode?
    private var activeConnectionCodeSessionID: String?
    private var activeConnectionCodeAuthorityDeviceId: String?
    private var activeConnectionCodeAuthorityFingerprint: String?
    private var authorityBoundWebRTCBootstrapSessionIds = Set<String>()
    private var strictPQCClassicBootstrapOnlySessionIds = Set<String>()
    private var connectionCodeExpiryTask: Task<Void, Never>?

    // MARK: - WebRTC (ICE / DataChannel)

    private var signalingClient: WebSocketSignalingClient?
    private var signalingShardKey: String?
    private let signalingLifecycle = CrossNetworkSignalingLifecycleCoordinator()
    private var webrtcSignalingAuthTokenBySessionId: [String: String] = [:]
    private var webrtcTurnAdmissionLeaseBySessionId: [String: SignalServerClient.TurnAdmissionLease] = [:]
    private var webrtcMediaAdmissionLeaseBySessionId: [String: SignalServerClient.MediaAdmissionLease] = [:]
    private var webrtcMediaAdmissionLeaseExpiresAtBySessionId: [String: Date] = [:]
    private var webrtcSessionsBySessionId: [String: WebRTCSession] = [:]
    private var pendingWebRTCOfferSessionIds: Set<String> = []
    var webrtcRemoteIdBySessionId: [String: String] = [:]
    private var currentPathExpectedRemoteAuthorityBySessionId: [String: CurrentPathRemoteAuthority] = [:]
    private var currentPathAdditionalProtocolFingerprintsBySessionId: [String: Set<String>] = [:]
    private var currentPathSignalingOriginBySessionId: [String: String] = [:]
    private var currentPathSignalingWebSocketPathBySessionId: [String: String] = [:]
    private var webrtcLatestOfferBySessionId: [String: String] = [:]
    private var webrtcLatestAnswerBySessionId: [String: String] = [:]
    private var webrtcLocalICECandidatesBySessionId: [String: [WebRTCSignalingEnvelope.Payload]] = [:]
    private var webrtcJoinBootstrapPayloadBySessionId: [String: WebRTCSignalingEnvelope.Payload] = [:]
    private var pendingWebRTCJoinBootstrapBySessionId: [String: (from: String, payload: WebRTCSignalingEnvelope.Payload?)] = [:]
    private var sessionSnapshotMetadataBySessionId: [String: SessionSnapshotMetadata] = [:]
    private var webrtcJoinHeartbeatTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcOfferResendTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcConnectionTimeoutTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcControlTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcInboundQueuesBySessionId: [String: InboundChunkQueue] = [:]
    private var webrtcOutboundHeartbeatTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcScreenStreamingTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcInteractionStreamingTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcInteractionStreamingAllowedSessionIds: Set<String> = []
    private var webrtcRemoteLivenessWatchdogTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcRekeyInProgressSessionIds: Set<String> = []
    private var webrtcRemoteDesktopHeartbeatAtBySessionId: [String: Date] = [:]
    private var webrtcRemoteVideoFormatsBySessionId: [String: Set<String>] = [:]
    private var webrtcRemoteStreamConfigurationBySessionId: [String: RemoteDesktopStreamConfiguration] = [:]
    private var webrtcPendingStreamRefreshSessionIds: Set<String> = []
    private var webrtcAwaitingStreamConfigurationSessionIds: Set<String> = []
    private var webrtcSessionReadyDiagnosticSessionIds: Set<String> = []
    private var webrtcRemoteControlNoticeApprovedSessionIds: Set<String> = []
    private var webrtcRemoteControlNoticePendingSessionIds: Set<String> = []
    private var webrtcRemoteSecurityIdentityBySessionId: [String: RemoteControlSecurityIdentity] = [:]
    private var webrtcBootstrapReplyFingerprintBySessionId: [String: String] = [:]
    var webrtcSessionKeysBySessionId: [String: SessionKeys] = [:]
    var webrtcSecureEnvelopeSendCounterBySessionId: [String: UInt64] = [:]
    var webrtcSecureEnvelopeReplayWindowBySessionId: [String: WebRTCAppSecureReplayWindow] = [:]
    var webrtcSecureEnvelopeKeyFingerprintBySessionId: [String: String] = [:]
    private var activeWebRTCClipboardSessionId: String?
    private var activeWebRTCClipboardToken: UUID?

    // File transfer waiters (sessionID|transferId|op|chunkIndex -> continuation)
    var webrtcFileTransferWaiters: [String: CheckedContinuation<CrossNetworkFileTransferMessage, Error>] = [:]

 // MARK: - 初始化

    public init() {
        self.signalServer = SignalServerClient(
            bearerTokenProvider: {
                if let token = try await AuthenticationService.shared.validAccessToken(),
                   !token.isEmpty {
                    return token
                }
                return await MainActor.run {
                    TenantAccessController.shared.accessToken ?? ""
                }
            },
            tenantIDProvider: {
                await MainActor.run {
                    let accessToken = AuthenticationService.shared.currentAccessToken()
                        ?? TenantAccessController.shared.accessToken
                    let derived = Self.deriveTenantIdentifier(accessToken: accessToken)
                    if !derived.isEmpty {
                        return derived
                    }
                    return TenantAccessController.shared.activeTenant?.id.uuidString ?? ""
                }
            }
        )
        self.deviceFingerprint = CrossNetworkConnectionRuntimeSupport.deviceFingerprint()
        if let rawMode = UserDefaults.standard.string(forKey: Self.connectionCodeLeaseModeDefaultsKey),
           let mode = ConnectionCodeLeaseMode(rawValue: rawMode) {
            self.connectionCodeLeaseMode = mode
        }

        logger.info("跨网络连接管理器初始化完成")
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

    private func signalingGeneration(for sessionID: String) -> Int {
        signalingLifecycle.generation(for: sessionID)
    }

    private func nextSignalingGeneration(for sessionID: String) -> Int {
        signalingLifecycle.nextGeneration(for: sessionID)
    }

    private func isTransportEstablished(for sessionID: String) -> Bool {
        switch readiness {
        case .transportReady(let activeSessionID):
            return activeSessionID == sessionID
        case .handshakeComplete(let activeSessionID, _):
            return activeSessionID == sessionID
        case .idle:
            return false
        }
    }

    private func isHandshakeComplete(for sessionID: String) -> Bool {
        if case .handshakeComplete(let activeSessionID, _) = readiness {
            return activeSessionID == sessionID
        }
        return false
    }

    private func noteDetachedSignalingAfterTransportEstablished(
        for sessionID: String,
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

        if previousHealth == .healthy {
            logger.info(
                "ℹ️ signaling detached after transport establishment: session=\(sessionID, privacy: .public) source=\(source, privacy: .public) fatal=\(fatal ? 1 : 0, privacy: .public)\(failureSuffix)"
            )
        } else {
            logger.debug(
                "ℹ️ signaling detached after transport establishment: session=\(sessionID, privacy: .public) source=\(source, privacy: .public) fatal=\(fatal ? 1 : 0, privacy: .public)\(failureSuffix)"
            )
        }
    }

    private func resetSignalingState(to phase: WebSocketSignalingClient.SignalingLifecyclePhase = .idle) {
        signalingLifecyclePhase = phase
        signalingHealth = .healthy
        signalingLifecycle.resetActiveHandle()
    }

    private func shouldAllowSignalingOperation(for sessionID: String) throws {
        try signalingLifecycle.shouldAllowOperation(
            for: sessionID,
            activeShardKey: signalingShardKey,
            health: signalingHealth
        )
    }

    private func scheduleSignalingRecovery(for sessionID: String, tokenExpired: Bool = false) {
        let networkSettings = RemoteDesktopSettingsManager.shared.settings.networkSettings
        signalingLifecycle.scheduleRecovery(
            for: sessionID,
            tokenExpired: tokenExpired,
            maxAttempts: networkSettings.boundedMaxReconnectAttempts,
            reconnectDelayMilliseconds: { attempt in
                RemoteDesktopSettingsManager.shared.settings.networkSettings
                    .reconnectBackoffDelayMilliseconds(forAttempt: attempt)
            },
            currentShardKey: { [weak self] in self?.signalingShardKey },
            isHandshakeComplete: { [weak self] sessionID in
                self?.isHandshakeComplete(for: sessionID) ?? false
            },
            ensureConnected: { [weak self] sessionID in
                guard let self else { throw WebSocketSignalingClient.SignalingError.notConnected }
                try await self.ensureSignalingConnected(shardKey: sessionID)
            },
            setHealth: { [weak self] health in
                self?.signalingHealth = health
            },
            logCancellation: { [weak self] sessionID, attempt in
                self?.logger.debug(
                    "ℹ️ signaling recovery cancelled: session=\(sessionID, privacy: .public) attempt=\(attempt, privacy: .public)"
                )
            },
            logFailure: { [weak self] sessionID, attempt, error in
                self?.logger.error(
                    "⚠️ signaling recovery failed: session=\(sessionID, privacy: .public) attempt=\(attempt, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                )
            }
        )
    }

    func handleSignalingLifecycleEvent(_ event: WebSocketSignalingClient.SignalingLifecycleEvent) {
        signalingLifecycle.handleLifecycleEvent(
            event,
            activeShardKey: signalingShardKey,
            isHandshakeComplete: { [weak self] sessionID in
                self?.isHandshakeComplete(for: sessionID) ?? false
            },
            setPhase: { [weak self] phase in
                self?.signalingLifecyclePhase = phase
            },
            setHealth: { [weak self] health in
                self?.signalingHealth = health
            },
            noteDetached: { [weak self] sessionID, source, failure, fatal in
                self?.noteDetachedSignalingAfterTransportEstablished(
                    for: sessionID,
                    source: source,
                    failure: failure,
                    fatal: fatal
                )
            }
        )
    }

    func testingSeedSignalingState(
        sessionID: String,
        generation: Int,
        handle: WebSocketSignalingClient.SignalingHandleID? = nil,
        health: SignalingSessionHealth = .healthy,
        phase: WebSocketSignalingClient.SignalingLifecyclePhase = .idle
    ) {
        signalingShardKey = sessionID
        signalingLifecycle.seed(sessionID: sessionID, generation: generation, handle: handle)
        signalingHealth = health
        signalingLifecyclePhase = phase
    }

    func testingSetReadiness(_ readiness: CrossNetworkReadiness) {
        self.readiness = readiness
    }

    func testingCurrentSignalingHandle() -> WebSocketSignalingClient.SignalingHandleID? {
        signalingLifecycle.currentHandle()
    }

    func testingCanPerformSignalingOperation(sessionID: String) -> Bool {
        (try? shouldAllowSignalingOperation(for: sessionID)) != nil
    }

    private static func hasUsableTURNCredentials(_ ice: WebRTCSession.ICEConfig) -> Bool {
        let hasTurnURL = ice.turnURLs.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let username = ice.turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = ice.turnPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasTurnURL && !username.isEmpty && !password.isEmpty
    }

    private func logICEPlan(_ ice: WebRTCSession.ICEConfig, context: String) {
        if Self.hasUsableTURNCredentials(ice) {
            let userHint = String(ice.turnUsername.prefix(8))
            logger.info("📡 \(context, privacy: .public) 使用 TURN+STUN: user=\(userHint, privacy: .public)...")
        } else {
            logger.warning("⚠️ \(context, privacy: .public) 未拿到可用 TURN 凭据，降级为 STUN-only")
        }
    }

    private func webrtcVideoRequest(from settings: DisplaySettings) -> WebRTCRemoteDesktopVideoRequest {
        WebRTCRemoteDesktopVideoRequestFactory.request(
            from: settings,
            isAppleSiliconRuntime: Self.isAppleSiliconRuntime
        )
    }

    private func webrtcVideoRequest(
        for sessionID: String,
        from settings: DisplaySettings,
        transportPath: WebRTCSession.ICETransportPath
    ) -> WebRTCRemoteDesktopVideoRequest {
        WebRTCRemoteDesktopVideoRequestFactory.request(
            from: settings,
            remoteStreamConfiguration: webrtcRemoteStreamConfigurationBySessionId[sessionID],
            transportPath: transportPath,
            isAppleSiliconRuntime: Self.isAppleSiliconRuntime
        )
    }

    private func effectiveWebRTCRemoteVideoFormats(for sessionID: String) -> Set<String> {
        WebRTCRemoteDesktopVideoFormatPolicy.effectiveRemoteVideoFormats(
            advertisedFormats: webrtcRemoteVideoFormatsBySessionId[sessionID] ?? [],
            streamConfiguration: webrtcRemoteStreamConfigurationBySessionId[sessionID]
        )
    }

    private func effectiveWebRTCNativeCaptureVideoFormats(for sessionID: String) -> Set<String> {
        WebRTCRemoteDesktopVideoFormatPolicy.effectiveNativeCaptureVideoFormats(
            localSupportedFormats: Self.supportedRemoteVideoFormats(),
            streamConfiguration: webrtcRemoteStreamConfigurationBySessionId[sessionID]
        )
    }

    private func consumePendingWebRTCStreamRefresh(for sessionID: String) -> Bool {
        webrtcPendingStreamRefreshSessionIds.remove(sessionID) != nil
    }

    private func configureWebRTCClipboardSyncIfNeeded(
        for sessionID: String,
        session: WebRTCSession
    ) {
        guard webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) else {
            stopWebRTCClipboardSyncIfNeeded(for: sessionID)
            appendSmokeStatus(
                "remoteControlClipboardBlocked session=\(sessionID) transport=webrtc reason=awaiting_security_notice"
            )
            return
        }

        let shouldEnable = webrtcRemoteStreamConfigurationBySessionId[sessionID]?.clipboardSyncEnabled ?? false
        let clipboard = ClipboardRedirectionManager.shared

        if shouldEnable {
            if activeWebRTCClipboardSessionId != sessionID {
                if let activeSession = activeWebRTCClipboardSessionId {
                    stopWebRTCClipboardSyncIfNeeded(for: activeSession)
                }
                activeWebRTCClipboardSessionId = sessionID
                activeWebRTCClipboardToken = UUID()
            }

            guard let token = activeWebRTCClipboardToken else { return }
            clipboard.enable(for: token)
            clipboard.onLocalClipboardChanged = { [weak self] data, mimeType in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeWebRTCClipboardSessionId == sessionID else { return }
                    await self.sendWebRTCClipboardPayload(
                        data: data,
                        mimeType: mimeType,
                        sessionID: sessionID,
                        session: session
                    )
                }
            }
        } else {
            stopWebRTCClipboardSyncIfNeeded(for: sessionID)
        }
    }

    private func stopWebRTCClipboardSyncIfNeeded(for sessionID: String) {
        guard activeWebRTCClipboardSessionId == sessionID else { return }
        let clipboard = ClipboardRedirectionManager.shared
        clipboard.onLocalClipboardChanged = nil
        clipboard.disable()
        activeWebRTCClipboardSessionId = nil
        activeWebRTCClipboardToken = nil
    }

    private func noteWebRTCRemoteSecurityIdentity(
        sessionID: String,
        accountDisplayName: String?,
        nebulaId: String?,
        deviceId: String?,
        deviceName: String?
    ) {
        let identity = RemoteControlSecurityIdentity(
            accountDisplayName: accountDisplayName,
            nebulaId: nebulaId,
            deviceId: deviceId,
            deviceName: deviceName
        )
        guard identity.accountDisplayName != nil
            || identity.nebulaId != nil
            || identity.deviceId != nil
            || identity.deviceName != nil else {
            return
        }
        webrtcRemoteSecurityIdentityBySessionId[sessionID] = identity
    }

    private func waitForWebRTCRemoteControlNoticeMetadata(
        sessionID: String,
        session: WebRTCSession,
        timeout: Duration = .seconds(2)
    ) async -> (identity: RemoteControlSecurityIdentity?, remoteIPAddress: String?) {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastRemoteIPAddress = await session.currentSelectedRemoteCandidateAddress()

        while clock.now < deadline {
            let identity = webrtcRemoteSecurityIdentityBySessionId[sessionID]
            lastRemoteIPAddress = await session.currentSelectedRemoteCandidateAddress()
            if Self.noticeMetadataPresent(identity?.accountDisplayName),
               Self.noticeMetadataPresent(identity?.nebulaId),
               Self.noticeMetadataPresent(lastRemoteIPAddress) {
                return (identity, lastRemoteIPAddress)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return (webrtcRemoteSecurityIdentityBySessionId[sessionID], lastRemoteIPAddress)
    }

    private static func noticeMetadataPresent(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !trimmed.isEmpty && trimmed != "missing" && trimmed != "-"
    }

    private func ensureWebRTCRemoteControlSecurityApproved(
        sessionID: String,
        session: WebRTCSession,
        keys: SessionKeys
    ) async -> Bool {
        if webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) {
            RemoteControlSecurityNoticeCenter.shared.updateCryptoSuite(
                webRTCSecurityCryptoSuite(keys),
                sessionId: sessionID,
                transportKind: .webrtc
            )
            return true
        }
        guard webrtcRemoteControlNoticePendingSessionIds.insert(sessionID).inserted else {
            appendSmokeStatus(
                "remoteControlStartBlocked session=\(sessionID) transport=webrtc reason=security_notice_pending"
            )
            return false
        }
        defer {
            webrtcRemoteControlNoticePendingSessionIds.remove(sessionID)
        }

        let noticeCenter = RemoteControlSecurityNoticeCenter.shared
        let localIdentity = noticeCenter.localIdentitySnapshot()
        let noticeMetadata = await waitForWebRTCRemoteControlNoticeMetadata(
            sessionID: sessionID,
            session: session
        )
        let remoteIdentity = noticeMetadata.identity
        let remoteDeviceId = remoteIdentity?.deviceId
            ?? webrtcRemoteIdBySessionId[sessionID]
            ?? sessionID
        let descriptor = RemoteControlSecurityDescriptor(
            sessionId: sessionID,
            transportKind: .webrtc,
            remoteIPAddress: noticeMetadata.remoteIPAddress,
            remoteDeviceId: remoteDeviceId,
            remoteDeviceName: remoteIdentity?.deviceName,
            remoteAccountDisplayName: remoteIdentity?.accountDisplayName,
            remoteNebulaId: remoteIdentity?.nebulaId,
            localAccountDisplayName: localIdentity?.accountDisplayName,
            localNebulaId: localIdentity?.nebulaId,
            cryptoSuite: webRTCSecurityCryptoSuite(keys)
        )
        noticeCenter.setDisconnectHandler(for: descriptor.id) { [weak self] in
            self?.cleanupWebRTCSession(
                sessionID,
                reason: "remote_control_notice_disconnect",
                disconnectKind: .explicit
            )
        }

        let decision = await noticeCenter.requestApproval(descriptor)
        guard decision == .approved, webrtcSessionsBySessionId[sessionID] != nil else {
            webrtcRemoteControlNoticeApprovedSessionIds.remove(sessionID)
            cleanupWebRTCSession(
                sessionID,
                reason: "remote_control_notice_\(decision.rawValue)",
                disconnectKind: .explicit
            )
            return false
        }
        webrtcRemoteControlNoticeApprovedSessionIds.insert(sessionID)
        return true
    }

    private func webRTCSecurityCryptoSuite(_ keys: SessionKeys) -> String {
        guard keys.negotiatedSuite.isKnown else { return "" }
        let rawValue = keys.negotiatedSuite.rawValue
        return keys.negotiatedSuite.isPQCGroup ? "\(rawValue) PQC" : "\(rawValue) secure channel"
    }

    private func sendWebRTCClipboardPayload(
        data: Data,
        mimeType: String,
        sessionID: String,
        session: WebRTCSession
    ) async {
        guard webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) else {
            stopWebRTCClipboardSyncIfNeeded(for: sessionID)
            appendSmokeStatus(
                "remoteControlClipboardSendBlocked session=\(sessionID) transport=webrtc reason=awaiting_security_notice"
            )
            return
        }
        do {
            guard let keys = webrtcSessionKeysBySessionId[sessionID] else { return }
            let clipboardPayload = RemoteClipboardPayload(mimeType: mimeType, data: data)
            let remoteMessage = RemoteMessageWire(
                type: .clipboard,
                payload: try JSONEncoder().encode(clipboardPayload)
            )
            let plaintext = try JSONEncoder().encode(remoteMessage)
            let ciphertext = try sealWebRTCSecurePayload(
                plaintext,
                with: keys,
                sessionID: sessionID,
                packetType: .remoteControl
            )
            let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: "tx/webrtc-clipboard")
            try await sendFramed(padded, over: session)
        } catch {
            logger.error("❌ WebRTC 会话剪贴板发送失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func localProtocolIdentityPublicKeysForPairing() async -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        var keys: [AppMessage.ProtocolIdentityPublicKeyInfo] = []
        for algorithm in [ProtocolSigningAlgorithm.ed25519, .mlDSA65] {
            do {
                let publicKey = try await DeviceIdentityKeyManager.shared.getProtocolSigningPublicKey(for: algorithm)
                keys.append(.init(protocolSigningAlgorithm: algorithm.rawValue, publicKey: publicKey))
            } catch {
                logger.debug(
                    "ℹ️ WebRTC pairingIdentityExchange skipped protocol identity key alg=\(algorithm.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
        sessionID: String,
        peerDeviceId: String
    ) {
        let fingerprints = protocolIdentityFingerprints(from: payload)
        guard !fingerprints.isEmpty else { return }
        currentPathAdditionalProtocolFingerprintsBySessionId[sessionID, default: []].formUnion(fingerprints)
        appendSmokeStatus(
            "protocol-identity-pins session=\(Self.protocolIdentityLogRedaction) peer=\(Self.protocolIdentityLogRedaction) declared=\(Self.protocolIdentityLogRedaction) count=\(fingerprints.count)"
        )
        logger.info(
            "🔐 WebRTC current-path protocol identity pins updated: session=\(Self.protocolIdentityLogRedaction, privacy: .public) peer=\(Self.protocolIdentityLogRedaction, privacy: .public) declared=\(Self.protocolIdentityLogRedaction, privacy: .public) count=\(fingerprints.count, privacy: .public)"
        )
    }

    private func additionalProtocolFingerprints(for sessionID: String) -> Set<String> {
        currentPathAdditionalProtocolFingerprintsBySessionId[sessionID] ?? []
    }

    private func currentPathTrustedProtocolFingerprints(for sessionID: String) -> Set<String> {
        var fingerprints = additionalProtocolFingerprints(for: sessionID)
        if let expected = currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !expected.isEmpty {
            fingerprints.insert(expected)
        }
        return fingerprints
    }

    private func trustedSignedRefreshKEMPublicKeys(
        forCandidates candidates: [String],
        sessionID: String
    ) async -> [UInt16: Data] {
        let pinnedFingerprints = currentPathTrustedProtocolFingerprints(for: sessionID)
        guard !pinnedFingerprints.isEmpty else { return [:] }
        return await PeerKEMBootstrapStore.shared.signedRefreshKEMPublicKeys(
            forCandidates: candidates,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
    }

    private func stopJoinHeartbeat(for sessionID: String) {
        webrtcJoinHeartbeatTasksBySessionId[sessionID]?.cancel()
        webrtcJoinHeartbeatTasksBySessionId.removeValue(forKey: sessionID)
    }

    private typealias CurrentPathSignalingEndpoint = (origin: String, wsPath: String)

    private func validatedCurrentPathSignalingEndpoint(
        origin: String,
        wsPath: String?
    ) throws -> CurrentPathSignalingEndpoint {
        (
            origin: try validateCurrentPathOrigin(origin),
            wsPath: try Self.validatedSignalingWebSocketPath(wsPath)
        )
    }

    private func storeCurrentPathSignalingEndpoint(
        sessionID: String,
        endpoint: CurrentPathSignalingEndpoint
    ) {
        currentPathSignalingOriginBySessionId[sessionID] = endpoint.origin
        currentPathSignalingWebSocketPathBySessionId[sessionID] = endpoint.wsPath
    }

    nonisolated static func validatedSignalingWebSocketPath(_ rawPath: String?) throws -> String {
        let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.first == "/",
              trimmed != "/",
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && !CharacterSet.whitespacesAndNewlines.contains(scalar)
              }) else {
            throw NSError(
                domain: "CrossNetworkConnectionManager",
                code: 654,
                userInfo: [NSLocalizedDescriptionKey: "invalid current-path signaling websocket path"]
            )
        }
        return trimmed
    }

    nonisolated public static func currentPathSignalingWebSocketURL(
        signalingServerOrigin: String,
        wsPath: String?,
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String
    ) -> URL? {
        let origin = signalingServerOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonicalOrigin = try? CurrentPathOriginPolicy.canonicalOrigin(origin) else {
            return nil
        }
        guard !origin.isEmpty, !sessionID.isEmpty, !sessionToken.isEmpty,
              var components = URLComponents(string: canonicalOrigin),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        guard let path = try? validatedSignalingWebSocketPath(wsPath) else {
            return nil
        }
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = path
        components.fragment = nil
        components.queryItems = [
            URLQueryItem(name: "shard", value: sessionID.uppercased()),
            URLQueryItem(name: "cv", value: clientVersion),
            URLQueryItem(name: "pv", value: protocolVersion)
        ]
        return components.url
    }

    nonisolated public static func currentPathSignalingWebSocketHeaders(
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String
    ) -> [String: String]? {
        let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientVersion = clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolVersion = protocolVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidWebSocketCredentialValue(sessionID, maxLength: 512),
              isValidWebSocketCredentialValue(sessionToken, maxLength: 4096),
              isValidWebSocketCredentialValue(clientVersion, maxLength: 64),
              isValidWebSocketCredentialValue(protocolVersion, maxLength: 64) else {
            return nil
        }
        return [
            "X-SkyBridge-Session-Id": sessionID,
            "X-SkyBridge-Session": sessionToken,
            "X-SkyBridge-Client-Version": clientVersion,
            "X-SkyBridge-Protocol-Version": protocolVersion
        ]
    }

    nonisolated private static func isValidWebSocketCredentialValue(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        return !value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    private var remoteDesktopNetworkStatsEnabled: Bool {
        RemoteDesktopSettingsManager.shared.settings.networkSettings.enableNetworkStats
            || ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil
    }

    private func remoteDesktopReconnectBackoffDelayMilliseconds(forAttempt attempt: Int) -> Int {
        RemoteDesktopSettingsManager.shared.settings.networkSettings
            .reconnectBackoffDelayMilliseconds(forAttempt: attempt)
    }

    private func startWebRTCConnectionTimeoutWatchdog(
        for sessionID: String,
        source: String,
        snapshotToken: UUID?
    ) {
        stopWebRTCConnectionTimeoutWatchdog(for: sessionID)
        let timeoutSeconds = RemoteDesktopSettingsManager.shared.settings.networkSettings.boundedConnectionTimeoutSeconds
        webrtcConnectionTimeoutTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil else { return }
            if case .transportReady(let activeSessionID) = self.readiness, activeSessionID == sessionID {
                return
            }
            if case .handshakeComplete(let activeSessionID, _) = self.readiness, activeSessionID == sessionID {
                return
            }
            self.logger.error(
                "⏱️ WebRTC 连接超时: session=\(sessionID, privacy: .public) source=\(source, privacy: .public) timeoutSeconds=\(timeoutSeconds, privacy: .public)"
            )
            self.appendSmokeStatus(
                "webrtc-connection-timeout session=\(sessionID) source=\(source) timeoutSeconds=\(timeoutSeconds)"
            )
            self.cleanupWebRTCSession(
                sessionID,
                reason: "connection_timeout_\(timeoutSeconds)s",
                disconnectKind: .explicit,
                snapshotToken: snapshotToken
            )
            self.connectionStatus = .failed("WebRTC connection timed out after \(timeoutSeconds) seconds")
            self.readiness = .idle
        }
    }

    private func stopWebRTCConnectionTimeoutWatchdog(for sessionID: String) {
        if let task = webrtcConnectionTimeoutTasksBySessionId.removeValue(forKey: sessionID) {
            task.cancel()
        }
    }

    private func stopAllWebRTCConnectionTimeoutWatchdogs() {
        for (_, task) in webrtcConnectionTimeoutTasksBySessionId {
            task.cancel()
        }
        webrtcConnectionTimeoutTasksBySessionId.removeAll()
    }

    private func startJoinHeartbeat(for sessionID: String, attempts: Int = 30) {
        stopJoinHeartbeat(for: sessionID)
        webrtcJoinHeartbeatTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            let totalAttempts = remaining
            while remaining > 0, !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil {
                if case .handshakeComplete(let activeSessionID, _) = self.readiness, activeSessionID == sessionID {
                    break
                }
                // The initial join is sent by the caller. Delay the heartbeat loop so we
                // do not immediately duplicate the bootstrap frame burst on fresh sessions.
                if remaining == attempts {
                    try? await Task.sleep(for: .milliseconds(self.remoteDesktopReconnectBackoffDelayMilliseconds(forAttempt: 1)))
                    guard !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                }
                let localDeviceId = self.webrtcSessionsBySessionId[sessionID]?.localDeviceId ?? self.deviceFingerprint
                await self.sendWebRTCJoinSignal(sessionID: sessionID, localDeviceId: localDeviceId, retries: 2)
                remaining -= 1
                if remaining == 0 { break }
                let attemptIndex = max(0, totalAttempts - remaining)
                try? await Task.sleep(
                    for: .milliseconds(self.remoteDesktopReconnectBackoffDelayMilliseconds(forAttempt: attemptIndex))
                )
            }
        }
    }

    private func strictPQCHandshakeRequested() -> Bool {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        return HandshakePolicy.recommendedDefault(
            compatibilityModeEnabled: compatibilityModeEnabled
        ).requirePQC
    }

    private func webRTCJoinBootstrapPayload(for sessionID: String) async throws -> WebRTCSignalingEnvelope.Payload {
        if let cached = webrtcJoinBootstrapPayloadBySessionId[sessionID] {
            return cached
        }

        let localBinding = try await currentPathLocalBinding()
        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await DeviceIdentityKeyManager.shared.pairingIdentityKEMPublicKeys(using: provider)
        )
        guard !kemKeys.isEmpty else {
            throw NSError(
                domain: "CrossNetworkConnectionManager",
                code: 8450,
                userInfo: [NSLocalizedDescriptionKey: "本机没有可用于 WebRTC strict-PQC join bootstrap 的 KEM 公钥"]
            )
        }

        let payload = WebRTCSignalingEnvelope.Payload(
            protocolSigningAlgorithm: localBinding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: localBinding.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: localBinding.protocolPublicKeyBytes,
            kemPublicKeys: kemKeys.map {
                WebRTCSignalingEnvelope.Payload.BootstrapKEMPublicKey(
                    suiteWireId: $0.suiteWireId,
                    publicKey: $0.publicKey
                )
            }
        )
        webrtcJoinBootstrapPayloadBySessionId[sessionID] = payload
        return payload
    }

    private func sendWebRTCJoinSignal(
        sessionID: String,
        localDeviceId: String,
        retries: Int
    ) async {
        let payload: WebRTCSignalingEnvelope.Payload?
        do {
            payload = try await webRTCJoinBootstrapPayload(for: sessionID)
        } catch {
            logger.error("❌ WebRTC join bootstrap material unavailable: session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            appendWebRTCSessionDiagnostic(
                "join-bootstrap-unavailable session=\(sessionID) error=\(sanitizeStatus(error.localizedDescription))",
                sessionID: sessionID
            )
            if strictPQCHandshakeRequested() {
                connectionStatus = .failed(error.localizedDescription)
                readiness = .idle
                cleanupWebRTCSession(sessionID, reason: "strict_pqc_join_bootstrap_unavailable")
                return
            }
            payload = nil
        }

        await sendSignal(
            .init(sessionId: sessionID, from: localDeviceId, type: .join, payload: payload),
            retries: retries
        )
    }

    private func ingestWebRTCJoinBootstrapPayload(
        _ payload: WebRTCSignalingEnvelope.Payload?,
        from remoteDeviceId: String,
        sessionID: String
    ) async {
        guard let payload else { return }
        let normalizedRemoteId = remoteDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemoteId.isEmpty else { return }

        if let expected = currentPathExpectedRemoteAuthorityBySessionId[sessionID] {
            let incomingAlgorithm = payload.protocolSigningAlgorithm
            let incomingFingerprint = payload.protocolPublicKeyFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let expectedFingerprint = expected.protocolPublicKeyFingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedRemoteId == expected.deviceId,
                  incomingAlgorithm == expected.protocolSigningAlgorithm,
                  incomingFingerprint == expectedFingerprint else {
                logger.error("❌ rejecting mismatched WebRTC join bootstrap: session=\(sessionID, privacy: .public) remote=\(normalizedRemoteId, privacy: .public)")
                appendWebRTCSessionDiagnostic(
                    "join-bootstrap-rejected session=\(sessionID) remote=\(normalizedRemoteId)",
                    sessionID: sessionID
                )
                return
            }

            if let protocolPublicKeyBytes = payload.protocolPublicKeyBytes,
               expected.protocolPublicKeyBytes == nil {
                currentPathExpectedRemoteAuthorityBySessionId[sessionID] = CurrentPathRemoteAuthority(
                    deviceId: expected.deviceId,
                    protocolSigningAlgorithm: expected.protocolSigningAlgorithm,
                    protocolPublicKeyFingerprint: expected.protocolPublicKeyFingerprint,
                    protocolPublicKeyBytes: protocolPublicKeyBytes,
                    deviceName: expected.deviceName
                )
            }
        }

        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            (payload.kemPublicKeys ?? []).map {
                KEMPublicKeyInfo(suiteWireId: $0.suiteWireId, publicKey: $0.publicKey)
            }
        )
        guard !kemKeys.isEmpty else { return }

        await PeerKEMBootstrapStore.shared.upsert(deviceIds: [normalizedRemoteId], kemPublicKeys: kemKeys)
        appendWebRTCSessionDiagnostic(
            "join-bootstrap-accepted session=\(sessionID) remote=\(normalizedRemoteId) kemKeys=\(kemKeys.count)",
            sessionID: sessionID
        )
    }

    private func adoptPendingWebRTCJoinBootstrapIfPresent(
        sessionID: String,
        session: WebRTCSession
    ) async {
        guard let pending = pendingWebRTCJoinBootstrapBySessionId.removeValue(forKey: sessionID) else {
            return
        }
        guard pending.from != session.localDeviceId else { return }

        if webrtcRemoteIdBySessionId[sessionID] == nil {
            webrtcRemoteIdBySessionId[sessionID] = pending.from
            if let snapshot = activeSessionSnapshot, snapshot.sessionId == sessionID {
                updatePreparedSessionSnapshot(
                    sessionID: sessionID,
                    phase: snapshot.phase,
                    deviceId: pending.from
                )
            }
        }
        await ingestWebRTCJoinBootstrapPayload(pending.payload, from: pending.from, sessionID: sessionID)
        appendWebRTCSessionDiagnostic(
            "join-bootstrap-adopted session=\(sessionID) remote=\(pending.from)",
            sessionID: sessionID
        )
    }

    private func stopOfferResendLoop(for sessionID: String) {
        webrtcOfferResendTasksBySessionId[sessionID]?.cancel()
        webrtcOfferResendTasksBySessionId.removeValue(forKey: sessionID)
    }

    private func canReuseWebRTCSession(_ sessionID: String) -> Bool {
        if currentConnection?.id == sessionID {
            return true
        }

        switch readiness {
        case .transportReady(let activeSessionID):
            return activeSessionID == sessionID
        case .handshakeComplete(let activeSessionID, _):
            return activeSessionID == sessionID
        case .idle:
            return false
        }
    }

    private func storeWebRTCMediaAdmissionLease(
        _ lease: SignalServerClient.MediaAdmissionLease?,
        for sessionID: String,
        now: Date = Date()
    ) {
        guard let lease else {
            webrtcMediaAdmissionLeaseBySessionId.removeValue(forKey: sessionID)
            webrtcMediaAdmissionLeaseExpiresAtBySessionId.removeValue(forKey: sessionID)
            return
        }
        webrtcMediaAdmissionLeaseBySessionId[sessionID] = lease
        webrtcMediaAdmissionLeaseExpiresAtBySessionId[sessionID] = now.addingTimeInterval(max(0, lease.expiresIn))
    }

    private func usableWebRTCMediaAdmissionLease(for sessionID: String, now: Date = Date()) -> SignalServerClient.MediaAdmissionLease? {
        guard let lease = webrtcMediaAdmissionLeaseBySessionId[sessionID],
              Self.isReusableMediaAdmissionLease(
                expiresAt: webrtcMediaAdmissionLeaseExpiresAtBySessionId[sessionID],
                now: now
              ) else {
            return nil
        }
        return lease
    }

    private func cacheLocalICECandidate(_ payload: WebRTCSignalingEnvelope.Payload, for sessionID: String) {
        guard let candidate = payload.candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return
        }

        var cached = webrtcLocalICECandidatesBySessionId[sessionID] ?? []
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
        webrtcLocalICECandidatesBySessionId[sessionID] = cached
    }

    private func cleanupWebRTCSession(
        _ sessionID: String,
        reason: String,
        disconnectKind: SessionDisconnectKind = .explicit,
        snapshotToken: UUID? = nil,
        closeSession: Bool = true
    ) {
        logger.info("🧹 清理 WebRTC 会话: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")

        notifyWebRTCTerminalSessionIfNeeded(
            sessionID: sessionID,
            reason: reason,
            disconnectKind: disconnectKind
        )

        RemoteControlSecurityNoticeCenter.shared.endNotice(
            sessionId: sessionID,
            transportKind: .webrtc
        )
        stopJoinHeartbeat(for: sessionID)
        stopOfferResendLoop(for: sessionID)
        stopWebRTCConnectionTimeoutWatchdog(for: sessionID)
        pendingWebRTCOfferSessionIds.remove(sessionID)
        webrtcLatestOfferBySessionId.removeValue(forKey: sessionID)
        webrtcLatestAnswerBySessionId.removeValue(forKey: sessionID)
        webrtcLocalICECandidatesBySessionId.removeValue(forKey: sessionID)
        webrtcJoinBootstrapPayloadBySessionId.removeValue(forKey: sessionID)
        pendingWebRTCJoinBootstrapBySessionId.removeValue(forKey: sessionID)
        webrtcSignalingAuthTokenBySessionId.removeValue(forKey: sessionID)
        webrtcTurnAdmissionLeaseBySessionId.removeValue(forKey: sessionID)
        webrtcMediaAdmissionLeaseBySessionId.removeValue(forKey: sessionID)
        webrtcMediaAdmissionLeaseExpiresAtBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteIdBySessionId.removeValue(forKey: sessionID)
        currentPathExpectedRemoteAuthorityBySessionId.removeValue(forKey: sessionID)
        currentPathAdditionalProtocolFingerprintsBySessionId.removeValue(forKey: sessionID)
        authorityBoundWebRTCBootstrapSessionIds.remove(sessionID)
        strictPQCClassicBootstrapOnlySessionIds.remove(sessionID)
        currentPathSignalingOriginBySessionId.removeValue(forKey: sessionID)
        currentPathSignalingWebSocketPathBySessionId.removeValue(forKey: sessionID)
        webrtcSessionKeysBySessionId.removeValue(forKey: sessionID)
        clearWebRTCSecureEnvelopeState(for: sessionID)
        webrtcRekeyInProgressSessionIds.remove(sessionID)
        webrtcRemoteDesktopHeartbeatAtBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteVideoFormatsBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteStreamConfigurationBySessionId.removeValue(forKey: sessionID)
        webrtcPendingStreamRefreshSessionIds.remove(sessionID)
        webrtcAwaitingStreamConfigurationSessionIds.remove(sessionID)
        webrtcSessionReadyDiagnosticSessionIds.remove(sessionID)
        webrtcInteractionStreamingAllowedSessionIds.remove(sessionID)
        webrtcRemoteControlNoticeApprovedSessionIds.remove(sessionID)
        webrtcRemoteControlNoticePendingSessionIds.remove(sessionID)
        webrtcRemoteSecurityIdentityBySessionId.removeValue(forKey: sessionID)
        webrtcBootstrapReplyFingerprintBySessionId.removeValue(forKey: sessionID)
        stopWebRTCClipboardSyncIfNeeded(for: sessionID)
        stopWebRTCLivenessWatchdog(for: sessionID)
        markCrossNetworkPresenceDisconnected(sessionID: sessionID)
        signalingLifecycle.cancelRecovery(for: sessionID)

        if let controlTask = webrtcControlTasksBySessionId.removeValue(forKey: sessionID) {
            controlTask.cancel()
        }
        if let outboundHeartbeatTask = webrtcOutboundHeartbeatTasksBySessionId.removeValue(forKey: sessionID) {
            outboundHeartbeatTask.cancel()
        }
        if let streamTask = webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            streamTask.cancel()
        }
        if let interactionTask = webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            interactionTask.cancel()
        }
        if let inboundQueue = webrtcInboundQueuesBySessionId.removeValue(forKey: sessionID) {
            Task { await inboundQueue.finish() }
        }
        failAllFileTransferWaitersForSession(sessionID: sessionID, message: "会话已结束")

        if closeSession, let session = webrtcSessionsBySessionId.removeValue(forKey: sessionID) {
            session.close()
        } else {
            webrtcSessionsBySessionId.removeValue(forKey: sessionID)
        }

        if currentConnection?.id == sessionID {
            currentConnection = nil
            readiness = .idle
        }
        applyActiveSessionDisconnect(
            sessionID: sessionID,
            kind: disconnectKind,
            snapshotToken: snapshotToken
        )
        if signalingShardKey == sessionID {
            resetSignalingState()
        }
        Task {
            await TURNCredentialService.shared.clearCache(sessionID: sessionID)
        }
    }

    func sealWebRTCSecurePayload(
        _ plaintext: Data,
        with keys: SessionKeys,
        sessionID: String,
        packetType: WebRTCAppSecurePacketType
    ) throws -> Data {
        resetWebRTCSecureEnvelopeStateIfNeeded(sessionID: sessionID, keys: keys)
        let counter = try nextWebRTCSecureEnvelopeCounter(for: sessionID)
        return try WebRTCControlChannelCodec.encryptAppPayload(
            plaintext,
            with: keys,
            packetType: packetType,
            counter: counter
        )
    }

    func openWebRTCSecurePayload(
        _ ciphertext: Data,
        with keys: SessionKeys,
        sessionID: String,
        allowedPacketTypes: Set<WebRTCAppSecurePacketType> = Set(WebRTCAppSecurePacketType.allCases)
    ) throws -> WebRTCAppSecureOpenedPayload {
        resetWebRTCSecureEnvelopeStateIfNeeded(sessionID: sessionID, keys: keys)
        let opened = try WebRTCControlChannelCodec.decryptAppPayload(
            ciphertext,
            with: keys,
            allowedPacketTypes: allowedPacketTypes
        )
        var replayWindow = webrtcSecureEnvelopeReplayWindowBySessionId[sessionID] ?? WebRTCAppSecureReplayWindow()
        try replayWindow.validateAndRecord(opened)
        webrtcSecureEnvelopeReplayWindowBySessionId[sessionID] = replayWindow
        return opened
    }

    func clearWebRTCSecureEnvelopeState(for sessionID: String) {
        webrtcSecureEnvelopeSendCounterBySessionId.removeValue(forKey: sessionID)
        webrtcSecureEnvelopeReplayWindowBySessionId.removeValue(forKey: sessionID)
        webrtcSecureEnvelopeKeyFingerprintBySessionId.removeValue(forKey: sessionID)
    }

    private func resetWebRTCSecureEnvelopeStateIfNeeded(sessionID: String, keys: SessionKeys) {
        let fingerprint = Self.webRTCSecureEnvelopeKeyFingerprint(for: keys)
        guard webrtcSecureEnvelopeKeyFingerprintBySessionId[sessionID] != fingerprint else { return }
        webrtcSecureEnvelopeSendCounterBySessionId[sessionID] = 0
        webrtcSecureEnvelopeReplayWindowBySessionId[sessionID] = WebRTCAppSecureReplayWindow()
        webrtcSecureEnvelopeKeyFingerprintBySessionId[sessionID] = fingerprint
    }

    private func nextWebRTCSecureEnvelopeCounter(for sessionID: String) throws -> UInt64 {
        let current = webrtcSecureEnvelopeSendCounterBySessionId[sessionID] ?? 0
        guard current < UInt64.max else {
            throw WebRTCAppSecureEnvelopeError.counterExhausted
        }
        let next = current + 1
        webrtcSecureEnvelopeSendCounterBySessionId[sessionID] = next
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

    private func resolvedCrossNetworkDisplayName(
        sessionID: String,
        fallbackDeviceName: String? = nil
    ) -> String {
        if let trimmed = fallbackDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        if let trimmed = sessionSnapshotMetadataBySessionId[sessionID]?.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        if let trimmed = currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        if let trimmed = currentConnection?.deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
           currentConnection?.id == sessionID,
           !trimmed.isEmpty,
           trimmed != "Remote Device" {
            return trimmed
        }
        if let trimmed = currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceId.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return "Remote Device"
    }

    private func remoteDesktopNotificationDeviceName(sessionID: String) -> String? {
        let fallback = activeSessionSnapshot?.sessionId == sessionID
            ? activeSessionSnapshot?.deviceName
            : nil
        let resolved = resolvedCrossNetworkDisplayName(
            sessionID: sessionID,
            fallbackDeviceName: fallback
        )
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Remote Device" else { return nil }
        return trimmed
    }

    private func hasUserVisibleWebRTCRemoteDesktopSession(sessionID: String) -> Bool {
        if currentConnection?.id == sessionID {
            return true
        }
        if let snapshot = activeSessionSnapshot, snapshot.sessionId == sessionID {
            switch snapshot.phase {
            case .connecting:
                break
            case .transportReady, .handshakeComplete, .reconnecting, .disconnecting:
                return true
            }
        }
        if webrtcSessionKeysBySessionId[sessionID] != nil {
            return true
        }
        if webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] != nil {
            return true
        }
        if webrtcScreenStreamingTasksBySessionId[sessionID] != nil {
            return true
        }
        if webrtcInteractionStreamingAllowedSessionIds.contains(sessionID) {
            return true
        }
        if webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) {
            return true
        }
        return false
    }

    private func beginWebRTCTerminalNotificationTracking(sessionID: String) {
        RemoteDesktopSessionNotificationService.shared.beginSession(
            sessionID: sessionID,
            transport: "webrtc"
        )
    }

    private func notifyWebRTCTerminalSessionIfNeeded(
        sessionID: String,
        reason: String,
        disconnectKind: SessionDisconnectKind
    ) {
        guard let kind = RemoteDesktopSessionTerminationPolicy.notificationKind(
            disconnectKind: disconnectKind,
            reason: reason,
            hadUserVisibleSession: hasUserVisibleWebRTCRemoteDesktopSession(sessionID: sessionID)
        ) else {
            return
        }

        RemoteDesktopSessionNotificationService.shared.sendTerminalNotificationIfNeeded(
            sessionID: sessionID,
            deviceName: remoteDesktopNotificationDeviceName(sessionID: sessionID),
            transport: "webrtc",
            kind: kind,
            reason: reason
        )
    }

    private func updateCrossNetworkRemoteMetadata(
        sessionID: String,
        deviceId: String?,
        deviceName: String?
    ) {
        let trimmedDeviceId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let current = currentPathExpectedRemoteAuthorityBySessionId[sessionID] {
            currentPathExpectedRemoteAuthorityBySessionId[sessionID] = CurrentPathRemoteAuthority(
                deviceId: (trimmedDeviceId?.isEmpty == false) ? trimmedDeviceId! : current.deviceId,
                protocolSigningAlgorithm: current.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: current.protocolPublicKeyFingerprint,
                protocolPublicKeyBytes: current.protocolPublicKeyBytes,
                deviceName: (trimmedDeviceName?.isEmpty == false) ? trimmedDeviceName : current.deviceName
            )
        }

        if let metadata = sessionSnapshotMetadataBySessionId[sessionID] {
            sessionSnapshotMetadataBySessionId[sessionID] = SessionSnapshotMetadata(
                snapshotToken: metadata.snapshotToken,
                source: metadata.source,
                deviceId: (trimmedDeviceId?.isEmpty == false) ? trimmedDeviceId : metadata.deviceId,
                deviceName: (trimmedDeviceName?.isEmpty == false) ? trimmedDeviceName : metadata.deviceName
            )
        }

        if currentConnection?.id == sessionID,
           let session = webrtcSessionsBySessionId[sessionID] {
            currentConnection = RemoteConnection(
                id: sessionID,
                deviceName: resolvedCrossNetworkDisplayName(
                    sessionID: sessionID,
                    fallbackDeviceName: trimmedDeviceName
                ),
                transport: .webrtc(session)
            )
        }

        if let snapshot = activeSessionSnapshot, snapshot.sessionId == sessionID {
            updatePreparedSessionSnapshot(
                sessionID: sessionID,
                phase: snapshot.phase,
                deviceId: (trimmedDeviceId?.isEmpty == false) ? trimmedDeviceId : nil,
                deviceName: (trimmedDeviceName?.isEmpty == false) ? trimmedDeviceName : nil
            )
        }
    }

    private func markCrossNetworkPresenceConnected(
        sessionID: String,
        negotiatedSuite: String,
        deviceName: String? = nil
    ) {
        let displayName = resolvedCrossNetworkDisplayName(
            sessionID: sessionID,
            fallbackDeviceName: deviceName
        )
        let cryptoKind = ConnectionCryptoPresentation.modeLabel(
            kind: nil,
            suite: negotiatedSuite
        ) ?? "Current Path"
        let stablePeerId = resolvedStableCrossNetworkPresencePeerID(sessionID: sessionID)
        let peerId = stablePeerId ?? Self.crossNetworkPresencePeerID(sessionID: sessionID)
        let sessionRoutePeerId = Self.crossNetworkPresencePeerID(sessionID: sessionID)

        if peerId != sessionRoutePeerId {
            ConnectionPresenceService.shared.markDisconnected(peerId: sessionRoutePeerId)
        }

        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: displayName,
            address: nil,
            cryptoKind: cryptoKind,
            suite: negotiatedSuite
        )
        if let stablePeerId {
            UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
                peerId: stablePeerId,
                displayName: displayName,
                cryptoKind: cryptoKind,
                suite: negotiatedSuite,
                guardStatus: "跨网已连接"
            )
        } else {
            logger.debug(
                "↪️ cross-network presence skipped UnifiedOnlineDevice recent persistence for session route \(sessionID, privacy: .public)"
            )
        }
    }

    private func markCrossNetworkPresenceDisconnected(sessionID: String) {
        let stablePeerId = resolvedStableCrossNetworkPresencePeerID(sessionID: sessionID)
        let peerId = stablePeerId ?? Self.crossNetworkPresencePeerID(sessionID: sessionID)
        let sessionRoutePeerId = Self.crossNetworkPresencePeerID(sessionID: sessionID)
        let displayName = currentConnection?.deviceName
        ConnectionPresenceService.shared.markDisconnected(
            peerId: sessionRoutePeerId
        )
        ConnectionPresenceService.shared.markDisconnected(
            peerId: peerId
        )
        if let stablePeerId {
            UnifiedOnlineDeviceManager.shared.markDeviceAsDisconnected(
                peerId: stablePeerId,
                displayName: displayName
            )
        }
    }

    private func resolvedStableCrossNetworkPresencePeerID(sessionID: String) -> String? {
        let candidates = [
            sessionSnapshotMetadataBySessionId[sessionID]?.deviceId,
            activeSessionSnapshot?.sessionId == sessionID ? activeSessionSnapshot?.deviceId : nil,
            currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceId
        ]
        for candidate in candidates {
            if let stablePeerId = Self.stableCrossNetworkPresencePeerID(deviceId: candidate) {
                return stablePeerId
            }
        }
        return nil
    }

    private func startWebRTCLivenessWatchdogIfNeeded(for sessionID: String) {
        guard webrtcRemoteLivenessWatchdogTasksBySessionId[sessionID] == nil else { return }
        webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
        webrtcRemoteLivenessWatchdogTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let heartbeatTimeoutSeconds: TimeInterval = 12.0
            let handshakeGraceTimeoutSeconds: TimeInterval = 30.0
            let transportReadyAt = Date()

            defer {
                self.webrtcRemoteLivenessWatchdogTasksBySessionId.removeValue(forKey: sessionID)
            }

            while !Task.isCancelled {
                guard self.webrtcSessionsBySessionId[sessionID] != nil else { break }
                let hasSessionKeys = self.webrtcSessionKeysBySessionId[sessionID] != nil
                let rekeyInProgress = self.webrtcRekeyInProgressSessionIds.contains(sessionID)
                let strictBootstrapOnly = self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionID)

                if !hasSessionKeys || rekeyInProgress || strictBootstrapOnly {
                    if Date().timeIntervalSince(transportReadyAt) <= handshakeGraceTimeoutSeconds {
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }

                    let reason = hasSessionKeys ? "rekey_timeout" : "app_handshake_timeout"
                    let message = hasSessionKeys ? "WebRTC rekey timed out" : "WebRTC app handshake timed out"
                    self.logger.warning(
                        "⚠️ WebRTC 握手宽限期超时: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)"
                    )
                    self.cleanupWebRTCSession(
                        sessionID,
                        reason: reason,
                        disconnectKind: strictBootstrapOnly ? .explicit : .transient
                    )
                    self.connectionStatus = .failed(message)
                    self.readiness = .idle
                    break
                }

                if let lastHeartbeatAt = self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID],
                   Date().timeIntervalSince(lastHeartbeatAt) > heartbeatTimeoutSeconds {
                    let reason = "remote_heartbeat_timeout"
                    self.logger.warning(
                        "⚠️ WebRTC 当前路径远端心跳超时: session=\(sessionID, privacy: .public)"
                    )
                    self.cleanupWebRTCSession(
                        sessionID,
                        reason: reason,
                        disconnectKind: .transient
                    )
                    self.connectionStatus = .failed("WebRTC remote heartbeat timed out")
                    self.readiness = .idle
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopWebRTCLivenessWatchdog(for sessionID: String) {
        if let task = webrtcRemoteLivenessWatchdogTasksBySessionId.removeValue(forKey: sessionID) {
            task.cancel()
        }
    }

    @discardableResult
    private func prepareSessionSnapshotMetadata(
        sessionID: String,
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
        sessionSnapshotMetadataBySessionId[sessionID] = metadata
        return metadata
    }

    @discardableResult
    private func activatePreparedSessionSnapshot(
        sessionID: String,
        phase: ActiveSessionSnapshotPhase,
        negotiatedSuite: String? = nil
    ) -> UUID? {
        guard let metadata = sessionSnapshotMetadataBySessionId[sessionID] else { return nil }
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionSnapshot = ActiveSessionSnapshotContract.activate(
            sessionId: sessionID,
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
        sessionID: String,
        phase: ActiveSessionSnapshotPhase,
        deviceId: String? = nil,
        deviceName: String? = nil,
        negotiatedSuite: String? = nil,
        snapshotToken: UUID? = nil
    ) {
        let token = snapshotToken ?? sessionSnapshotMetadataBySessionId[sessionID]?.snapshotToken
        guard let token else { return }
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionSnapshot = ActiveSessionSnapshotContract.update(
            current: activeSessionSnapshot,
            sessionId: sessionID,
            snapshotToken: token,
            phase: phase,
            deviceId: deviceId,
            deviceName: deviceName,
            negotiatedSuite: negotiatedSuite
        )
    }

    private func applyActiveSessionDisconnect(
        sessionID: String,
        kind: SessionDisconnectKind,
        snapshotToken: UUID? = nil
    ) {
        let token = snapshotToken ?? sessionSnapshotMetadataBySessionId[sessionID]?.snapshotToken
        guard let token else { return }

        let nextSnapshot = ActiveSessionSnapshotContract.disconnect(
            current: activeSessionSnapshot,
            sessionId: sessionID,
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
            sessionSnapshotMetadataBySessionId.removeValue(forKey: sessionID)
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

    @discardableResult
    private func resendCachedOfferIfNeeded(for sessionID: String, reason: String) async -> Bool {
        guard let sdp = webrtcLatestOfferBySessionId[sessionID] else { return false }
        let localDeviceId = webrtcSessionsBySessionId[sessionID]?.localDeviceId ?? deviceFingerprint
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionID: sessionID, sdp: sdp)
        logger.info("🔁 重发本地 offer: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
        await sendSignal(
            .init(sessionId: sessionID, from: localDeviceId, type: .offer, payload: .init(sdp: enrichedSDP)),
            retries: 2
        )
        return true
    }

    private func resendOrRecoverLocalOfferForRemoteJoin(sessionID: String, session: WebRTCSession) async {
        if await resendCachedOfferIfNeeded(for: sessionID, reason: "remote-join") {
            return
        }
        guard shouldRecoverMissingOfferCacheFromRemoteJoin(sessionID: sessionID, session: session) else {
            return
        }

        let requested = session.requestLocalOfferEmission(reason: "remote-join-cache-miss")
        if requested {
            logger.warning(
                "⚠️ remote join found missing local offer cache; requested offer re-emit/regeneration: session=\(sessionID, privacy: .public)"
            )
        } else {
            logger.error(
                "❌ remote join found missing local offer cache, but no local offerer description was available: session=\(sessionID, privacy: .public)"
            )
        }
    }

    private func resendCachedAnswerIfNeeded(for sessionID: String, reason: String) async {
        guard let sdp = webrtcLatestAnswerBySessionId[sessionID] else { return }
        let localDeviceId = webrtcSessionsBySessionId[sessionID]?.localDeviceId ?? deviceFingerprint
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionID: sessionID, sdp: sdp)
        logger.info("🔁 重发本地 answer: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
        await sendSignal(
            .init(sessionId: sessionID, from: localDeviceId, type: .answer, payload: .init(sdp: enrichedSDP)),
            retries: 2
        )
    }

    private func sdpWithCachedLocalICECandidates(sessionID: String, sdp: String) -> String {
        guard let candidates = webrtcLocalICECandidatesBySessionId[sessionID], !candidates.isEmpty else {
            return sdp
        }
        return WebRTCSDPCandidateInjector.injectLocalICECandidates(candidates, into: sdp)
    }

    private func resendCachedLocalICECandidatesIfNeeded(for sessionID: String, reason: String) async {
        guard let candidates = webrtcLocalICECandidatesBySessionId[sessionID], !candidates.isEmpty else { return }
        guard webrtcRemoteIdBySessionId[sessionID] != nil else {
            logger.debug("ℹ️ skip cached ICE resend before remote peer is known: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
            return
        }
        let localDeviceId = webrtcSessionsBySessionId[sessionID]?.localDeviceId ?? deviceFingerprint
        logger.info("🔁 重发本地 ICE candidates: session=\(sessionID, privacy: .public) count=\(candidates.count, privacy: .public) reason=\(reason, privacy: .public)")
        for payload in candidates {
            await sendSignal(
                .init(sessionId: sessionID, from: localDeviceId, type: .iceCandidate, payload: payload),
                retries: 2
            )
        }
    }

    private func startOfferResendLoop(for sessionID: String, attempts: Int = 40) {
        stopOfferResendLoop(for: sessionID)
        webrtcOfferResendTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0, !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil {
                // The original offer/ICE burst is sent by the session callbacks. Wait one
                // interval before the first best-effort resend so startup does not double-send.
                if remaining == attempts {
                    try? await Task.sleep(for: .milliseconds(self.remoteDesktopReconnectBackoffDelayMilliseconds(forAttempt: 1)))
                    guard !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                }
                if case .connected = self.connectionStatus { break }
                await self.resendCachedOfferIfNeeded(for: sessionID, reason: "periodic")
                await self.resendCachedLocalICECandidatesIfNeeded(for: sessionID, reason: "periodic")
                remaining -= 1
                if remaining == 0 { break }
                let attemptIndex = max(0, attempts - remaining)
                try? await Task.sleep(
                    for: .milliseconds(self.remoteDesktopReconnectBackoffDelayMilliseconds(forAttempt: attemptIndex))
                )
            }
        }
    }

    // MARK: - 连接生命周期管理

    /// 断开当前跨网连接，释放所有 WebRTC / Signaling 资源。
    ///
    /// 符合 IEEE TDSC 安全生命周期要求：
    /// - 关闭所有 DataChannel / PeerConnection / SSL 上下文
    /// - 取消控制/屏幕推流任务
    /// - 清空会话密钥（防止密钥残留）
    public func disconnect() async {
        let securityNoticeSessionIDs = Set(webrtcSessionsBySessionId.keys)
            .union(webrtcRemoteControlNoticeApprovedSessionIds)
            .union(webrtcRemoteControlNoticePendingSessionIds)
        for sessionID in securityNoticeSessionIDs {
            RemoteControlSecurityNoticeCenter.shared.endNotice(
                sessionId: sessionID,
                transportKind: .webrtc
            )
        }
        for sessionID in webrtcSessionsBySessionId.keys where hasUserVisibleWebRTCRemoteDesktopSession(sessionID: sessionID) {
            RemoteDesktopSessionNotificationService.shared.sendTerminalNotificationIfNeeded(
                sessionID: sessionID,
                deviceName: remoteDesktopNotificationDeviceName(sessionID: sessionID),
                transport: "webrtc",
                kind: .normal,
                reason: "explicit_disconnect"
            )
        }

        // 1) 关闭所有 WebRTC 会话
        for (_, session) in webrtcSessionsBySessionId {
            session.close()
        }
        webrtcSessionsBySessionId.removeAll()

        let listeners = activeListeners
        activeListeners.removeAll()
        for listener in listeners {
            await listener.stop()
        }

        // 2) 结束入站队列，唤醒控制通道等待
        for (_, queue) in webrtcInboundQueuesBySessionId {
            await queue.finish()
        }
        webrtcInboundQueuesBySessionId.removeAll()

        // 3) 取消控制通道任务
        for (_, task) in webrtcControlTasksBySessionId {
            task.cancel()
        }
        webrtcControlTasksBySessionId.removeAll()

        // 4) 取消屏幕推流任务
        for (_, task) in webrtcScreenStreamingTasksBySessionId {
            task.cancel()
        }
        webrtcScreenStreamingTasksBySessionId.removeAll()

        for (_, task) in webrtcInteractionStreamingTasksBySessionId {
            task.cancel()
        }
        webrtcInteractionStreamingTasksBySessionId.removeAll()

        // 5) 清空会话密钥
        webrtcSessionKeysBySessionId.removeAll()
        webrtcSignalingAuthTokenBySessionId.removeAll()
        webrtcTurnAdmissionLeaseBySessionId.removeAll()
        webrtcMediaAdmissionLeaseBySessionId.removeAll()
        webrtcMediaAdmissionLeaseExpiresAtBySessionId.removeAll()
        webrtcRemoteIdBySessionId.removeAll()
        currentPathExpectedRemoteAuthorityBySessionId.removeAll()
        currentPathAdditionalProtocolFingerprintsBySessionId.removeAll()
        authorityBoundWebRTCBootstrapSessionIds.removeAll()
        strictPQCClassicBootstrapOnlySessionIds.removeAll()
        currentPathSignalingOriginBySessionId.removeAll()
        currentPathSignalingWebSocketPathBySessionId.removeAll()
        webrtcLatestOfferBySessionId.removeAll()
        pendingWebRTCJoinBootstrapBySessionId.removeAll()
        pendingWebRTCOfferSessionIds.removeAll()

        for (_, task) in webrtcJoinHeartbeatTasksBySessionId {
            task.cancel()
        }
        webrtcJoinHeartbeatTasksBySessionId.removeAll()

        for (_, task) in webrtcOfferResendTasksBySessionId {
            task.cancel()
        }
        webrtcOfferResendTasksBySessionId.removeAll()
        stopAllWebRTCConnectionTimeoutWatchdogs()

        // 6) 关闭 WebSocket 信令
        if let sc = signalingClient {
            await sc.close()
        }
        signalingClient = nil
        signalingShardKey = nil
        signalingLifecycle.resetAll()
        resetSignalingState()
        await TURNCredentialService.shared.clearCache()

        // 7) 取消所有文件传输等待
        let waiters = webrtcFileTransferWaiters
        webrtcFileTransferWaiters.removeAll()
        for (_, c) in waiters {
            c.resume(throwing: WebRTCFileTransferWaitError.cancelled)
        }

        // 8) 重置状态
        currentConnection = nil
        connectionCode = nil
        connectionCodeExpiresAt = nil
        activeConnectionCodeLeaseMode = nil
        activeConnectionCodeSessionID = nil
        activeConnectionCodeAuthorityDeviceId = nil
        activeConnectionCodeAuthorityFingerprint = nil
        authorityBoundWebRTCBootstrapSessionIds.removeAll()
        strictPQCClassicBootstrapOnlySessionIds.removeAll()
        Self.removeConnectionCodeSnapshot()
        connectionCodeExpiryTask?.cancel()
        connectionCodeExpiryTask = nil
        qrCodeData = nil
        activeSessionReconnectTimeoutTask?.cancel()
        activeSessionReconnectTimeoutTask = nil
        activeSessionSnapshot = nil
        sessionSnapshotMetadataBySessionId.removeAll()
        connectionStatus = .idle
        readiness = .idle

        logger.info("✅ CrossNetworkConnectionManager disconnected; all resources released")
    }

    private func startQRCodeWatchdog(
        operation: String,
        timeoutSeconds: Double,
        timeoutMessage: String
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.logger.error("⌛️ QR watchdog fired: operation=\(operation, privacy: .public)")
            self.connectionStatus = .failed(timeoutMessage)
            self.readiness = .idle
        }
    }

    private func currentPathLocalProtocolSigningAlgorithm() -> ProtocolSigningAlgorithm {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        let handshakePolicy = HandshakePolicy.recommendedDefault(
            compatibilityModeEnabled: compatibilityModeEnabled
        )
        return handshakePolicy.requirePQC ? .mlDSA65 : .ed25519
    }

    private func currentPathLocalBinding() async throws -> ProtocolIdentityBinding {
        let algorithm = currentPathLocalProtocolSigningAlgorithm()
        await SelfIdentityProvider.shared.loadOrCreate()
        let selfIdentity = await SelfIdentityProvider.shared.snapshot()
        let deviceId = selfIdentity.deviceId.isEmpty
            ? await DeviceIdentityKeyManager.shared.getDeviceId()
            : selfIdentity.deviceId
        let publicKey = try await DeviceIdentityKeyManager.shared.getProtocolSigningPublicKey(for: algorithm)
        return try ProtocolIdentityBinding(
            deviceId: deviceId,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyBytes: publicKey
        )
    }

    private func activeConnectionCodeMatchesCurrentAuthority(_ binding: ProtocolIdentityBinding) -> Bool {
        guard let activeConnectionCodeAuthorityDeviceId,
              let activeConnectionCodeAuthorityFingerprint else {
            return false
        }
        return activeConnectionCodeAuthorityDeviceId == binding.deviceId
            && activeConnectionCodeAuthorityFingerprint == binding.protocolPublicKeyFingerprint
    }

    private func requestAdmissionLease(for binding: ProtocolIdentityBinding) async throws -> SignalServerClient.AdmissionLease {
        let challenge = try await signalServer.requestAdmissionChallenge(binding: binding)
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: binding.protocolSigningAlgorithm)
        let signingHandle = try await DeviceIdentityKeyManager.shared.getProtocolSigningKeyHandle(for: binding.protocolSigningAlgorithm)
        let signature = try await signatureProvider.sign(challenge.signaturePayload(), key: signingHandle)
        return try await signalServer.completeAdmission(
            challenge: challenge,
            binding: binding,
            signature: signature
        )
    }

    nonisolated static func isQRCodeConnectLinkWithinCapacity(_ data: Data) -> Bool {
        data.count <= qrCodeConnectLinkMaximumByteCount
    }

 // MARK: - 1️⃣ 动态二维码连接

 /// 生成动态加密二维码
 /// 包含：设备指纹 + 临时密钥 + ICE 候选信息 + 过期时间
    public func generateDynamicQRCode(validDuration: TimeInterval = 300) async throws -> Data {
        logger.info("生成动态二维码，有效期: \(validDuration)秒")
        connectionStatus = .generating
        readiness = .idle
        let watchdog = startQRCodeWatchdog(
            operation: "generate",
            timeoutSeconds: Self.qrCodeGenerationWatchdogTimeoutSeconds,
            timeoutMessage: "二维码生成超时"
        )
        defer { watchdog.cancel() }

        var currentStage = "entered"
        do {
            logQRCodeStage("generate", stage: currentStage)
            await Task.yield()

            currentStage = "resolve_local_binding"
            logQRCodeStage("generate", stage: currentStage)
            let localBinding = try await currentPathLocalBinding()
            logQRCodeStage("generate", stage: "local_binding_resolved")

            currentStage = "register_session"
            logQRCodeStage("generate", stage: "\(currentStage)_started")
            let admissionLease = try await requestAdmissionLease(for: localBinding)
            let sessionLease = try await signalServer.registerSession(
                admissionToken: admissionLease.token,
                validDuration: validDuration
            )
            let sessionID = sessionLease.sessionID
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: sessionLease.signalingServerOrigin,
                wsPath: sessionLease.wsPath
            )
            webrtcSignalingAuthTokenBySessionId[sessionLease.sessionID] = sessionLease.sessionToken
            webrtcTurnAdmissionLeaseBySessionId[sessionLease.sessionID] = sessionLease.turnAdmissionLease
            storeWebRTCMediaAdmissionLease(sessionLease.mediaAdmissionLease, for: sessionLease.sessionID)
            storeCurrentPathSignalingEndpoint(
                sessionID: sessionLease.sessionID,
                endpoint: signalingEndpoint
            )
            authorityBoundWebRTCBootstrapSessionIds.insert(sessionID)
            logQRCodeStage("generate", stage: "\(currentStage)_finished", sessionID: sessionID)

            let expiresAt = Date().addingTimeInterval(validDuration)
            let localPresentation = LocalDevicePresentation.current()
            let invite = ServerBackedDynamicQRCodeInvite(
                version: 8,
                sessionID: sessionID,
                qrBootstrapToken: sessionLease.qrBootstrapToken,
                signalingServerOrigin: sessionLease.signalingServerOrigin,
                deviceID: localBinding.deviceId,
                deviceName: localPresentation.deviceName ?? localPresentation.modelName ?? "Mac",
                deviceType: P2PDeviceType.macOS.rawValue,
                osVersion: localPresentation.osVersion,
                protocolSigningAlgorithm: localBinding.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: localBinding.protocolPublicKeyFingerprint,
                expiresAt: expiresAt
            )

            currentStage = "assign_payload"
            let connectLink = try Self.encodeQRCodeConnectLink(invite)
            guard Self.isQRCodeConnectLinkWithinCapacity(connectLink) else {
                throw CrossNetworkConnectionError.invalidQRCode
            }
            self.qrCodeData = connectLink
            self.connectionStatus = .waiting(code: sessionID)
            self.readiness = .idle
            logQRCodeStage("generate", stage: "payload_assigned", sessionID: sessionID)

            startWebRTCOfferSession(sessionID: sessionID)

            logger.info("✅ 动态二维码生成成功，会话ID: \(sessionID)")
            guard let qrCodeData else {
                throw CrossNetworkConnectionError.invalidQRCode
            }
            return qrCodeData
        } catch {
            logger.error("❌ generateDynamicQRCode failed: stage=\(currentStage, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }
    }

 /// 扫描并解析动态二维码
    public func scanDynamicQRCode(_ data: Data) async throws -> RemoteConnection {
        logger.info("扫描动态二维码")
        connectionStatus = .connecting
        readiness = .idle
        let watchdog = startQRCodeWatchdog(
            operation: "scan",
            timeoutSeconds: Self.qrCodeScanBootstrapWatchdogTimeoutSeconds,
            timeoutMessage: "二维码连接超时"
        )
        defer { watchdog.cancel() }

        var currentStage = "entered"
        do {
            logQRCodeStage("scan", stage: currentStage)
            guard let qrString = String(data: data, encoding: .utf8),
                  let payload = Self.extractConnectPayload(from: qrString) else {
                throw CrossNetworkConnectionError.invalidQRCode
            }

            currentStage = "payload_decoded"
            logQRCodeStage("scan", stage: currentStage)
            guard let jsonData = Self.decodeBase64Payload(payload) else {
                throw CrossNetworkConnectionError.invalidQRCode
            }

            if let invite = try? Self.decodeServerBackedQRCodeInvite(from: jsonData),
               invite.version >= 8 {
                return try await scanServerBackedQRCodeInvite(invite)
            }

            let qrData = try Self.decodeDynamicQRCodePayload(from: jsonData)
            guard qrData.expiresAt > Date() else {
                throw CrossNetworkConnectionError.qrCodeExpired
            }
            _ = try validateCurrentPathOrigin(qrData.signalingServerOrigin)

            currentStage = "verify_qr"
            logQRCodeStage("scan", stage: "\(currentStage)_started", sessionID: qrData.sessionID)
            let verifyResult = await Self.verifyDynamicQRCode(qrData)
            guard verifyResult.ok else {
                logger.error("二维码校验失败：\(verifyResult.reason ?? "未知原因")")
                throw CrossNetworkConnectionError.invalidSignature
            }
            logQRCodeStage("scan", stage: "qr_signature_verified", sessionID: qrData.sessionID)
            guard !Self.isP2PKEMBootstrapCapability(qrData.normalizedCapabilities) else {
                logger.error("❌ QR scan rejected: P2P KEM QR bootstrap has been removed; use PIB-1 SAS plus SKR-1 signed LAN KEM refresh")
                throw CrossNetworkConnectionError.invalidQRCode
            }
            switch verifyResult.source {
            case .trustedDevice:
                logger.info("✅ 二维码来源已命中本地 trust store: \(qrData.deviceID, privacy: .public)")
            case .selfAsserted:
                logger.notice("ℹ️ 二维码仅完成完整性校验，未命中外部信任锚；后续身份认证仍依赖握手/pinning")
            }
            logVerifiedQRCodeKEMIgnored(qrData)

            currentStage = "redeem_session"
            logQRCodeStage("scan", stage: "\(currentStage)_started", sessionID: qrData.sessionID)
            let localBinding = try await currentPathLocalBinding()
            let admissionLease = try await requestAdmissionLease(for: localBinding)
            let redeemed = try await signalServer.redeemSession(
                admissionToken: admissionLease.token,
                sessionID: qrData.sessionID,
                qrBootstrapToken: qrData.qrBootstrapToken,
                idempotencyKey: "qr-redeem-\(qrData.sessionID)-\(localBinding.deviceId)"
            )
            guard redeemed.initiatorDeviceId == qrData.deviceID,
                  redeemed.initiatorProtocolSigningAlgorithm == qrData.protocolSigningAlgorithm,
                  redeemed.initiatorProtocolPublicKeyFingerprint == qrData.protocolPublicKeyFingerprint else {
                throw CrossNetworkConnectionError.invalidSignature
            }
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: redeemed.signalingServerOrigin,
                wsPath: redeemed.wsPath
            )
            webrtcSignalingAuthTokenBySessionId[qrData.sessionID] = redeemed.sessionToken
            webrtcTurnAdmissionLeaseBySessionId[qrData.sessionID] = redeemed.turnAdmissionLease
            storeWebRTCMediaAdmissionLease(redeemed.mediaAdmissionLease, for: qrData.sessionID)
            storeCurrentPathSignalingEndpoint(
                sessionID: qrData.sessionID,
                endpoint: signalingEndpoint
            )
            currentPathExpectedRemoteAuthorityBySessionId[qrData.sessionID] = CurrentPathRemoteAuthority(
                deviceId: qrData.deviceID,
                protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
                protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
                deviceName: qrData.deviceName
            )
            webrtcRemoteIdBySessionId[qrData.sessionID] = qrData.deviceID
            logQRCodeStage("scan", stage: "\(currentStage)_finished", sessionID: qrData.sessionID)

            currentStage = "start_webrtc_answerer"
            logQRCodeStage("scan", stage: "\(currentStage)_started", sessionID: qrData.sessionID)
            let connection = try await establishWebRTCConnection(with: qrData)
            logQRCodeStage("scan", stage: "webrtc_answerer_started", sessionID: qrData.sessionID)

            if self.currentConnection?.id != connection.id {
                self.currentConnection = connection
            }
            logQRCodeStage("scan", stage: "join_sent", sessionID: qrData.sessionID)

            logger.info("✅ 通过二维码连接成功")
            return connection
        } catch {
            logger.error("❌ scanDynamicQRCode failed: stage=\(currentStage, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }
    }

 // MARK: - 2️⃣ iCloud 设备链连接

 /// 发现同 Apple ID 下的所有设备
    public func discoverCloudDevices() async throws {
        logger.info("🔍 发现 iCloud 设备链")

 // 使用 CloudKitService 获取设备列表
        await CloudKitService.shared.refreshDevices()

 // 获取设备列表（排除当前设备）
        let currentDeviceId = CrossNetworkConnectionRuntimeSupport.deviceFingerprint()
        let allDevices = CloudKitService.shared.devices

 // 过滤掉当前设备和离线设备（1小时内活跃）
        let activeDevices = allDevices.filter { device in
            device.id != currentDeviceId &&
            device.lastSeenAt.timeIntervalSinceNow > -3600
        }

        self.availableCloudDevices = activeDevices
        logger.info("✅ 发现 \(activeDevices.count) 台 iCloud 设备")
    }

 /// 通过 iCloud 设备链连接
    public func connectToCloudDevice(_ device: CloudDevice) async throws -> RemoteConnection {
        logger.info("连接到 iCloud 设备: \(device.name)")
        connectionStatus = .connecting
        readiness = .idle

 // 1. 通过 iCloud KV Store 交换 ICE 候选
        let sessionID = UUID().uuidString
        let snapshotMetadata = prepareSessionSnapshotMetadata(
            sessionID: sessionID,
            source: .icloud,
            deviceId: device.id,
            deviceName: device.name
        )
        activatePreparedSessionSnapshot(sessionID: sessionID, phase: .connecting)
        do {
            let offer = try await createConnectionOffer(sessionID: sessionID)

    // 2. 写入 offer 到 iCloud
            let kvStore = NSUbiquitousKeyValueStore.default
            if let offerData = try? JSONEncoder().encode(offer) {
                kvStore.set(offerData, forKey: "skybridge.offer.\(device.id)")
                kvStore.synchronize()
            }

    // 3. 等待 answer（轮询或推送）
            let answer = try await waitForAnswer(deviceID: device.id, timeout: 30)

    // 4. 建立连接
            let connection = try await finalizeConnection(offer: offer, answer: answer)

            self.currentConnection = connection
            self.connectionStatus = .connected
            self.readiness = .handshakeComplete(
                sessionId: connection.id,
                negotiatedSuite: "quic-transport"
            )
            updatePreparedSessionSnapshot(
                sessionID: connection.id,
                phase: .handshakeComplete,
                deviceId: device.id,
                deviceName: device.name,
                negotiatedSuite: "quic-transport",
                snapshotToken: snapshotMetadata.snapshotToken
            )

            logger.info("✅ 通过 iCloud 连接成功")
            return connection
        } catch {
            cleanupWebRTCSession(
                sessionID,
                reason: "icloud_connect_failed",
                disconnectKind: .explicit,
                snapshotToken: snapshotMetadata.snapshotToken,
                closeSession: false
            )
            throw error
        }
    }

 // MARK: - 3️⃣ 智能连接码

    /// 生成服务器签发的智能连接码（当前默认 8 位）
    public func generateConnectionCode() async throws -> String {
        logger.info("生成智能连接码")
        let requestedLeaseMode = connectionCodeLeaseMode
        let localBinding = try await currentPathLocalBinding()
        let canReuseCurrentAuthority = activeConnectionCodeMatchesCurrentAuthority(localBinding)
        if let existing = connectionCode,
           activeConnectionCodeLeaseMode == requestedLeaseMode,
           case .waiting(let activeCode) = connectionStatus,
           activeCode == existing,
           Self.isReusableConnectionCodeLease(expiresAt: connectionCodeExpiresAt),
           canReuseCurrentAuthority {
            return existing
        }
        if let existing = connectionCode,
           activeConnectionCodeLeaseMode == requestedLeaseMode,
           case .waiting(let activeCode) = connectionStatus,
           activeCode == existing {
            let reason = canReuseCurrentAuthority ? "connection_code_lease_not_reusable" : "connection_code_authority_changed"
            logger.info("ℹ️ 本地连接码不可复用，重新向信令服务注册: reason=\(reason, privacy: .public) code=<redacted>")
            connectionCode = nil
            connectionCodeExpiresAt = nil
            activeConnectionCodeLeaseMode = nil
            activeConnectionCodeSessionID = nil
            activeConnectionCodeAuthorityDeviceId = nil
            activeConnectionCodeAuthorityFingerprint = nil
            Self.removeConnectionCodeSnapshot()
            connectionCodeExpiryTask?.cancel()
            connectionCodeExpiryTask = nil
        }
        if connectionCode != nil,
           activeConnectionCodeLeaseMode != requestedLeaseMode {
            await disconnect()
        }
        connectionStatus = .generating
        readiness = .idle

        do {
            let admissionLease = try await requestAdmissionLease(for: localBinding)
            let localPresentation = LocalDevicePresentation.current()
            let lease = try await signalServer.registerConnectionCode(
                admissionToken: admissionLease.token,
                deviceName: localPresentation.deviceName ?? localPresentation.modelName ?? "Mac",
                validDuration: requestedLeaseMode.validDuration
            )
            let code = lease.code
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: lease.signalingServerOrigin,
                wsPath: lease.wsPath
            )
            webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
            webrtcTurnAdmissionLeaseBySessionId[lease.sessionID] = lease.turnAdmissionLease
            storeWebRTCMediaAdmissionLease(lease.mediaAdmissionLease, for: lease.sessionID)
            storeCurrentPathSignalingEndpoint(
                sessionID: lease.sessionID,
                endpoint: signalingEndpoint
            )

            // 2) 当前主路径由服务端发放短期 code + initiator token，code 同时作为 WebRTC sessionId。
            self.connectionCode = code
            self.connectionCodeExpiresAt = Date().addingTimeInterval(lease.expiresIn)
            self.activeConnectionCodeLeaseMode = requestedLeaseMode
            self.activeConnectionCodeSessionID = lease.sessionID
            self.activeConnectionCodeAuthorityDeviceId = localBinding.deviceId
            self.activeConnectionCodeAuthorityFingerprint = localBinding.protocolPublicKeyFingerprint
            writeConnectionCodeSnapshot(
                code: code,
                sessionID: lease.sessionID,
                expiresAt: self.connectionCodeExpiresAt,
                leaseMode: requestedLeaseMode,
                binding: localBinding
            )
            self.authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)
            self.connectionStatus = .waiting(code: code)
            self.readiness = .idle
            if let expiresAt = self.connectionCodeExpiresAt {
                scheduleConnectionCodeLeaseInvalidation(
                    code: code,
                    sessionID: lease.sessionID,
                    expiresAt: expiresAt
                )
            }

            // 3) 启动 WebRTC offerer（等待对端输入同一 code 后 join，同会话完成 SDP/ICE，DataChannel ready）
            startWebRTCOfferSession(sessionID: lease.sessionID)

            logger.info("✅ 连接码生成成功: code=<redacted>")
            return code
        } catch {
            logger.error("❌ 生成连接码失败: \(error.localizedDescription, privacy: .public)")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }
    }

    /// 通过连接码连接
    public func connectWithCode(_ code: String) async throws -> RemoteConnection {
        guard let normalized = Self.normalizeConnectionCode(code) else {
            let error = CrossNetworkConnectionError.invalidDevice
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }
        logger.info("使用连接码连接: code=<redacted>")

        if let existing = currentConnection, existing.id == normalized {
            logger.info("复用已有连接码会话: code=<redacted>")
            return existing
        }

        let sessionID = normalized
        if let existingSession = webrtcSessionsBySessionId[sessionID], canReuseWebRTCSession(sessionID) {
            logger.info("复用已有会话（避免重复创建）: \(sessionID, privacy: .public)")
            prepareSessionSnapshotMetadata(
                sessionID: sessionID,
                source: .reused,
                deviceId: currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceId,
                deviceName: currentConnection?.deviceName ?? currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceName
            )
            let phase: ActiveSessionSnapshotPhase
            let negotiatedSuite: String?
            switch readiness {
            case .handshakeComplete(let activeSessionID, let suite):
                phase = activeSessionID == sessionID ? .handshakeComplete : .transportReady
                negotiatedSuite = activeSessionID == sessionID ? suite : nil
            case .transportReady(let activeSessionID):
                phase = activeSessionID == sessionID ? .transportReady : .connecting
                negotiatedSuite = nil
            case .idle:
                phase = .transportReady
                negotiatedSuite = nil
            }
            activatePreparedSessionSnapshot(sessionID: sessionID, phase: phase, negotiatedSuite: negotiatedSuite)
            return RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(existingSession))
        }
        if webrtcSessionsBySessionId[sessionID] != nil {
            cleanupWebRTCSession(sessionID, reason: "replace_stale_answerer_session")
        }

        connectionStatus = .connecting
        readiness = .idle

        do {
            let localBinding = try await currentPathLocalBinding()
            let admissionLease = try await requestAdmissionLease(for: localBinding)
            let lookup = try await signalServer.lookupConnectionCode(
                admissionToken: admissionLease.token,
                code: normalized
            )
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: lookup.signalingServerOrigin,
                wsPath: lookup.wsPath
            )
            try enforceCurrentPathTrustBinding(
                deviceId: lookup.initiatorDeviceId,
                protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
                authenticatedConnectionCodeRebindAllowed: true
            )
            webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken
            webrtcTurnAdmissionLeaseBySessionId[lookup.sessionID] = lookup.turnAdmissionLease
            storeWebRTCMediaAdmissionLease(lookup.mediaAdmissionLease, for: lookup.sessionID)
            storeCurrentPathSignalingEndpoint(
                sessionID: lookup.sessionID,
                endpoint: signalingEndpoint
            )
            currentPathExpectedRemoteAuthorityBySessionId[lookup.sessionID] = CurrentPathRemoteAuthority(
                deviceId: lookup.initiatorDeviceId,
                protocolSigningAlgorithm: lookup.initiatorProtocolSigningAlgorithm,
                protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
                protocolPublicKeyBytes: nil,
                deviceName: lookup.initiatorDeviceName
            )
            webrtcRemoteIdBySessionId[lookup.sessionID] = lookup.initiatorDeviceId
            let snapshotMetadata = prepareSessionSnapshotMetadata(
                sessionID: sessionID,
                source: .code,
                deviceId: lookup.initiatorDeviceId,
                deviceName: lookup.initiatorDeviceName
            )
            activatePreparedSessionSnapshot(sessionID: sessionID, phase: .connecting)

            try await ensureSignalingConnected(shardKey: sessionID)

            // 动态获取 TURN 凭据（带缓存和回退）
            let ice = await SkyBridgeServerConfig.dynamicICEConfig(
                sessionID: sessionID,
                turnAdmissionLease: webrtcTurnAdmissionLeaseBySessionId[sessionID]
            )
            logICEPlan(ice, context: "连接码模式")

            let localDeviceId = localBinding.deviceId
            let signalingAuthToken = webrtcSignalingAuthTokenBySessionId[sessionID]
            let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .answerer, ice: ice)
            session.onTrace = { [weak self] line in
                guard let self else { return }
                Task { @MainActor in
                    self.appendWebRTCSessionDiagnostic(line, sessionID: sessionID)
                }
            }

            session.onLocalAnswer = { [weak self] sdp in
                guard let self else { return }
                Task { @MainActor in
                    guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                    self.webrtcLatestAnswerBySessionId[sessionID] = sdp
                    await self.sendSignal(.init(
                        sessionId: sessionID,
                        from: localDeviceId,
                        type: .answer,
                        payload: .init(sdp: sdp),
                        authToken: signalingAuthToken
                    ))
                }
            }
            session.onLocalICECandidate = { [weak self] payload in
                guard let self else { return }
                Task { @MainActor in
                    guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                    self.cacheLocalICECandidate(payload, for: sessionID)
                    guard self.webrtcRemoteIdBySessionId[sessionID] != nil else {
                        self.logger.debug("ℹ️ defer local ICE until remote peer is known: session=\(sessionID, privacy: .public)")
                        return
                    }
                    await self.sendSignal(.init(
                        sessionId: sessionID,
                        from: localDeviceId,
                        type: .iceCandidate,
                        payload: payload,
                        authToken: signalingAuthToken
                    ))
                }
            }
            session.onDisconnected = { [weak self] reason in
                guard let self else { return }
                Task { @MainActor in
                    guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                    self.cleanupWebRTCSession(
                        sessionID,
                        reason: "transport_disconnected:\(reason)",
                        disconnectKind: .transient,
                        snapshotToken: snapshotMetadata.snapshotToken
                    )
                    self.connectionStatus = .failed("WebRTC transport disconnected: \(reason)")
                    self.readiness = .idle
                }
            }
            session.onReady = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.logger.info("✅ WebRTC answerer ready: session=\(sessionID, privacy: .public)")
                    self.stopWebRTCConnectionTimeoutWatchdog(for: sessionID)
                    self.currentConnection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
                    self.connectionStatus = .connecting
                    self.readiness = .transportReady(sessionId: sessionID)
                    self.startWebRTCLivenessWatchdogIfNeeded(for: sessionID)
                    self.updatePreparedSessionSnapshot(
                        sessionID: sessionID,
                        phase: .transportReady,
                        deviceId: lookup.initiatorDeviceId,
                        deviceName: lookup.initiatorDeviceName,
                        snapshotToken: snapshotMetadata.snapshotToken
                    )
                    self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
                }
            }

            beginWebRTCTerminalNotificationTracking(sessionID: sessionID)
            webrtcSessionsBySessionId[sessionID] = session
            await adoptPendingWebRTCJoinBootstrapIfPresent(sessionID: sessionID, session: session)

            do {
                startWebRTCConnectionTimeoutWatchdog(
                    for: sessionID,
                    source: "connection-code-answerer",
                    snapshotToken: snapshotMetadata.snapshotToken
                )
                try await session.startAsync()
            } catch {
                logger.error("❌ connectWithCode(WebRTC) start failed: \(error.localizedDescription, privacy: .public)")
                cleanupWebRTCSession(
                    sessionID,
                    reason: "answerer_start_failed",
                    disconnectKind: .explicit,
                    snapshotToken: snapshotMetadata.snapshotToken
                )
                connectionStatus = .failed(error.localizedDescription)
                readiness = .idle
                throw error
            }

            // 主动加入会话并在短时间内心跳重发，避免 WS 时序抖动导致 offer 丢失。
            await sendWebRTCJoinSignal(sessionID: sessionID, localDeviceId: localDeviceId, retries: 2)
            startJoinHeartbeat(for: sessionID, attempts: Self.webRTCStartupJoinHeartbeatAttempts)
            let connection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
            logger.info("✅ 通过连接码开始连接（等待对端 offer）")
            return connection
        } catch {
            logger.error("❌ 连接码连接失败: \(error.localizedDescription, privacy: .public)")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
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
        connectionCodeExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      self.connectionCode == code,
                      self.activeConnectionCodeSessionID == sessionID,
                      !Self.isReusableConnectionCodeLease(expiresAt: self.connectionCodeExpiresAt) else {
                    return
                }
                self.logger.info("ℹ️ 本地连接码租约到期，已清理旧码: reason=connection_code_lease_expired code=<redacted>")
                self.connectionCode = nil
                self.connectionCodeExpiresAt = nil
                self.activeConnectionCodeLeaseMode = nil
                self.activeConnectionCodeSessionID = nil
                self.activeConnectionCodeAuthorityDeviceId = nil
                self.activeConnectionCodeAuthorityFingerprint = nil
                Self.removeConnectionCodeSnapshot()
                self.authorityBoundWebRTCBootstrapSessionIds.remove(sessionID)
                self.connectionCodeExpiryTask = nil
                if case .waiting(let waitingCode) = self.connectionStatus, waitingCode == code {
                    self.connectionStatus = .idle
                }
            }
        }
    }

    private func scanServerBackedQRCodeInvite(_ invite: ServerBackedDynamicQRCodeInvite) async throws -> RemoteConnection {
        guard invite.expiresAt > Date() else {
            throw CrossNetworkConnectionError.qrCodeExpired
        }
        _ = try validateCurrentPathOrigin(invite.signalingServerOrigin)

        logQRCodeStage("scan", stage: "server_backed_invite_redeem_started", sessionID: invite.sessionID)
        let localBinding = try await currentPathLocalBinding()
        let admissionLease = try await requestAdmissionLease(for: localBinding)
        let redeemed = try await signalServer.redeemSession(
            admissionToken: admissionLease.token,
            sessionID: invite.sessionID,
            qrBootstrapToken: invite.qrBootstrapToken,
            idempotencyKey: "qr-redeem-\(invite.sessionID)-\(localBinding.deviceId)"
        )
        guard redeemed.initiatorDeviceId == invite.deviceID,
              redeemed.initiatorProtocolSigningAlgorithm == invite.protocolSigningAlgorithm,
              redeemed.initiatorProtocolPublicKeyFingerprint == invite.protocolPublicKeyFingerprint else {
            throw CrossNetworkConnectionError.invalidSignature
        }
        let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
            origin: redeemed.signalingServerOrigin,
            wsPath: redeemed.wsPath
        )

        webrtcSignalingAuthTokenBySessionId[invite.sessionID] = redeemed.sessionToken
        webrtcTurnAdmissionLeaseBySessionId[invite.sessionID] = redeemed.turnAdmissionLease
        storeWebRTCMediaAdmissionLease(redeemed.mediaAdmissionLease, for: invite.sessionID)
        storeCurrentPathSignalingEndpoint(
            sessionID: invite.sessionID,
            endpoint: signalingEndpoint
        )
        currentPathExpectedRemoteAuthorityBySessionId[invite.sessionID] = CurrentPathRemoteAuthority(
            deviceId: invite.deviceID,
            protocolSigningAlgorithm: invite.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: invite.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: nil,
            deviceName: invite.deviceName
        )
        webrtcRemoteIdBySessionId[invite.sessionID] = invite.deviceID
        logQRCodeStage("scan", stage: "server_backed_invite_redeemed", sessionID: invite.sessionID)

        let connection = try await establishWebRTCConnection(
            sessionID: invite.sessionID,
            remoteDeviceID: invite.deviceID,
            remoteDeviceName: invite.deviceName
        )
        logger.info("✅ 通过服务端背书二维码连接成功")
        return connection
    }

 // MARK: - 私有方法 - P2P 连接建立

    private func establishP2PConnection(with qrData: DynamicQRCodeData) async throws -> RemoteConnection {
        logger.info("建立 P2P 连接（二维码模式）")

 // 1. 创建 NWConnection（QUIC over UDP for P2P）
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])

 // 2. ICE 候选协商
        let iceCandidate = try await negotiateICE(
            sessionID: qrData.sessionID,
            remotePublicKey: qrData.protocolPublicKeyBytes
        )

 // 3. 建立连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(iceCandidate.host),
            port: NWEndpoint.Port(integerLiteral: iceCandidate.port)
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))

 // 4. 等待连接就绪
        try await CrossNetworkConnectionRuntimeSupport.waitForConnection(connection)

        return RemoteConnection(
            id: qrData.sessionID,
            deviceName: qrData.deviceName,
            transport: .nw(connection)
        )
    }

    // MARK: - WebRTC Connection

    private func establishWebRTCConnection(with qrData: DynamicQRCodeData) async throws -> RemoteConnection {
        try await establishWebRTCConnection(
            sessionID: qrData.sessionID,
            remoteDeviceID: qrData.deviceID,
            remoteDeviceName: qrData.deviceName
        )
    }

    private func signalingWebSocketURL(shardKey: String? = nil) throws -> URL {
        guard let shardKey = shardKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shardKey.isEmpty else {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint("missing current-path session id")
        }
        guard let sessionToken = webrtcSignalingAuthTokenBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionToken.isEmpty else {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint("missing current-path session token")
        }
        let clientVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedClientVersion = (clientVersion?.isEmpty == false)
            ? clientVersion!
            : (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
        let protocolVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"] ?? "1"

        guard let origin = currentPathSignalingOriginBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !origin.isEmpty else {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint("missing current-path signaling origin")
        }
        do {
            _ = try Self.validatedSignalingWebSocketPath(currentPathSignalingWebSocketPathBySessionId[shardKey])
        } catch {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint(error.localizedDescription)
        }
        guard let url = Self.currentPathSignalingWebSocketURL(
            signalingServerOrigin: origin,
            wsPath: currentPathSignalingWebSocketPathBySessionId[shardKey],
            sessionID: shardKey,
            sessionToken: sessionToken,
            clientVersion: resolvedClientVersion,
            protocolVersion: protocolVersion
        ) else {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint("invalid current-path signaling origin")
        }
        return url
    }

    private func signalingWebSocketHeaders(shardKey: String) throws -> [String: String] {
        guard let sessionToken = webrtcSignalingAuthTokenBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionToken.isEmpty else {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint("missing current-path session token")
        }
        let clientVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedClientVersion = (clientVersion?.isEmpty == false)
            ? clientVersion!
            : (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
        let protocolVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"] ?? "1"
        guard let headers = Self.currentPathSignalingWebSocketHeaders(
            sessionID: shardKey,
            sessionToken: sessionToken,
            clientVersion: resolvedClientVersion,
            protocolVersion: protocolVersion
        ) else {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint("invalid current-path signaling headers")
        }
        return headers
    }

    private func ensureSignalingConnected(shardKey: String? = nil) async throws {
        let effectiveShardKey = shardKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedShardKey = (effectiveShardKey?.isEmpty == false) ? effectiveShardKey : nil

        if let client = signalingClient, signalingShardKey != normalizedShardKey {
            await client.close()
            signalingClient = nil
            signalingShardKey = nil
            resetSignalingState()
        }

        if let client = signalingClient {
            try await client.connectOrThrow()
            return
        }
        guard let sessionID = normalizedShardKey else {
            throw WebSocketSignalingClient.SignalingError.invalidSignalingEndpoint("missing current-path session id")
        }
        let url = try signalingWebSocketURL(shardKey: sessionID)
        let headers = try signalingWebSocketHeaders(shardKey: sessionID)
        let generation = nextSignalingGeneration(for: sessionID)
        let client = WebSocketSignalingClient(
            url: url,
            sessionId: sessionID,
            generation: generation,
            additionalHeaders: headers
        )
        self.signalingClient = client
        signalingShardKey = normalizedShardKey
        resetSignalingState()
        await client.setOnEnvelope { [weak self] env in
            Task { @MainActor in
                await self?.handleSignalingEnvelope(env)
            }
        }
        await client.setOnServerFrame { [weak self] frame in
            Task { @MainActor in
                self?.handleSignalingServerFrame(frame)
            }
        }
        await client.setOnLifecycleEvent { [weak self] event in
            Task { @MainActor in
                self?.handleSignalingLifecycleEvent(event)
            }
        }
        try await client.connectOrThrow()
    }

    private func startWebRTCOfferSession(sessionID: String) {
        guard webrtcSignalingAuthTokenBySessionId[sessionID]?.isEmpty == false else {
            logger.error("❌ startWebRTCOfferSession 缺少 signaling token: session=\(sessionID, privacy: .public)")
            connectionStatus = .failed("Missing signaling token")
            readiness = .idle
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await self?.ensureSignalingConnected(shardKey: sessionID)
            } catch {
                self?.connectionStatus = .failed(error.localizedDescription)
                self?.readiness = .idle
            }
        }
        if webrtcSessionsBySessionId[sessionID] != nil, !canReuseWebRTCSession(sessionID) {
            cleanupWebRTCSession(sessionID, reason: "replace_stale_offerer_session")
        }
        guard webrtcSessionsBySessionId[sessionID] == nil else { return }
        guard !pendingWebRTCOfferSessionIds.contains(sessionID) else { return }
        pendingWebRTCOfferSessionIds.insert(sessionID)

        // 异步获取动态 TURN 凭据
        Task { @MainActor in
            await self.startWebRTCOfferSessionWithDynamicCredentials(sessionID: sessionID)
        }
    }

    private func startWebRTCOfferSessionWithDynamicCredentials(sessionID: String) async {
        defer { pendingWebRTCOfferSessionIds.remove(sessionID) }
        guard webrtcSessionsBySessionId[sessionID] == nil else { return }
        let snapshotMetadata = prepareSessionSnapshotMetadata(
            sessionID: sessionID,
            source: .qr,
            deviceId: currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceId,
            deviceName: currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceName
        )
        let localBinding: ProtocolIdentityBinding
        do {
            localBinding = try await currentPathLocalBinding()
        } catch {
            logger.error("❌ failed to resolve local current-path identity: \(error.localizedDescription, privacy: .public)")
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            return
        }
        let localDeviceId = localBinding.deviceId

        // 动态获取 TURN 凭据（带缓存和回退）
        let ice = await SkyBridgeServerConfig.dynamicICEConfig(
            sessionID: sessionID,
            turnAdmissionLease: webrtcTurnAdmissionLeaseBySessionId[sessionID]
        )
        logICEPlan(ice, context: "连接码发起方")
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            let relayOnly = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FORCE_RELAY_ICE"] == "1"
            appendSmokeStatus(
                "webrtc-config session=\(sessionID) role=offerer relayOnly=\(relayOnly) turn=\(ice.hasUsableTURNCredentials) turnUrls=\(ice.turnURLs.count)"
            )
        }

        let signalingAuthToken = webrtcSignalingAuthTokenBySessionId[sessionID]
        let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .offerer, ice: ice)
        session.onTrace = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in
                self.appendWebRTCSessionDiagnostic(line, sessionID: sessionID)
            }
        }
        session.onLocalOffer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                self.webrtcLatestOfferBySessionId[sessionID] = sdp
                await self.sendSignal(.init(
                    sessionId: sessionID,
                    from: localDeviceId,
                    type: .offer,
                    payload: .init(sdp: sdp),
                    authToken: signalingAuthToken
                ), retries: 2)
            }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                self.cacheLocalICECandidate(payload, for: sessionID)
                guard self.webrtcRemoteIdBySessionId[sessionID] != nil else {
                    self.logger.debug("ℹ️ defer local ICE until remote peer is known: session=\(sessionID, privacy: .public)")
                    return
                }
                await self.sendSignal(.init(
                    sessionId: sessionID,
                    from: localDeviceId,
                    type: .iceCandidate,
                    payload: payload,
                    authToken: signalingAuthToken
                ))
            }
        }
        session.onDisconnected = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                self.cleanupWebRTCSession(
                    sessionID,
                    reason: "transport_disconnected:\(reason)",
                    disconnectKind: .transient,
                    snapshotToken: snapshotMetadata.snapshotToken
                )
                self.connectionStatus = .failed("WebRTC transport disconnected: \(reason)")
                self.readiness = .idle
            }
        }
        session.onReady = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("✅ WebRTC offerer ready: session=\(sessionID, privacy: .public)")
                self.stopWebRTCConnectionTimeoutWatchdog(for: sessionID)
                self.currentConnection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
                self.connectionStatus = .connecting
                self.readiness = .transportReady(sessionId: sessionID)
                self.startWebRTCLivenessWatchdogIfNeeded(for: sessionID)
                self.activatePreparedSessionSnapshot(sessionID: sessionID, phase: .transportReady)

                // 启动“握手/控制通道”消费者：把 DataChannel 当作一条 length-framed byte stream，复用现有 HandshakeDriver / AppMessage 逻辑。
                self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
            }
        }

        beginWebRTCTerminalNotificationTracking(sessionID: sessionID)
        webrtcSessionsBySessionId[sessionID] = session
        await adoptPendingWebRTCJoinBootstrapIfPresent(sessionID: sessionID, session: session)

        do {
            startWebRTCConnectionTimeoutWatchdog(
                for: sessionID,
                source: "connection-code-offerer",
                snapshotToken: snapshotMetadata.snapshotToken
            )
            try await session.startAsync()
            await sendWebRTCJoinSignal(sessionID: sessionID, localDeviceId: localDeviceId, retries: 2)
            startJoinHeartbeat(for: sessionID, attempts: Self.webRTCStartupJoinHeartbeatAttempts)
            startOfferResendLoop(for: sessionID)
        } catch {
            logger.error("❌ startWebRTCOfferSession failed: \(error.localizedDescription, privacy: .public)")
            cleanupWebRTCSession(
                sessionID,
                reason: "offerer_start_failed",
                disconnectKind: .explicit,
                snapshotToken: snapshotMetadata.snapshotToken
            )
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
        }
    }

    private func establishWebRTCConnection(
        sessionID: String,
        remoteDeviceID: String,
        remoteDeviceName: String
    ) async throws -> RemoteConnection {
        guard webrtcSignalingAuthTokenBySessionId[sessionID]?.isEmpty == false else {
            throw CrossNetworkConnectionError.missingSignalingToken
        }
        try await ensureSignalingConnected(shardKey: sessionID)

        let snapshotMetadata = prepareSessionSnapshotMetadata(
            sessionID: sessionID,
            source: .qr,
            deviceId: remoteDeviceID,
            deviceName: remoteDeviceName
        )
        activatePreparedSessionSnapshot(sessionID: sessionID, phase: .connecting)
        if webrtcSessionsBySessionId[sessionID] != nil, !canReuseWebRTCSession(sessionID) {
            cleanupWebRTCSession(sessionID, reason: "replace_stale_qr_answerer_session")
        }

        // 动态获取 TURN 凭据（带缓存和回退）
        let ice = await SkyBridgeServerConfig.dynamicICEConfig(
            sessionID: sessionID,
            turnAdmissionLease: webrtcTurnAdmissionLeaseBySessionId[sessionID]
        )
        logICEPlan(ice, context: "二维码应答方")
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            let relayOnly = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FORCE_RELAY_ICE"] == "1"
            appendSmokeStatus(
                "webrtc-config session=\(sessionID) role=answerer relayOnly=\(relayOnly) turn=\(ice.hasUsableTURNCredentials) turnUrls=\(ice.turnURLs.count)"
            )
        }

        let localBinding = try await currentPathLocalBinding()
        let localDeviceId = localBinding.deviceId
        let signalingAuthToken = webrtcSignalingAuthTokenBySessionId[sessionID]
        let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .answerer, ice: ice)
        session.onTrace = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in
                self.appendWebRTCSessionDiagnostic(line, sessionID: sessionID)
            }
        }

        session.onLocalAnswer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                self.webrtcLatestAnswerBySessionId[sessionID] = sdp
                await self.sendSignal(.init(
                    sessionId: sessionID,
                    from: localDeviceId,
                    type: .answer,
                    payload: .init(sdp: sdp),
                    authToken: signalingAuthToken
                ))
            }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                self.cacheLocalICECandidate(payload, for: sessionID)
                guard self.webrtcRemoteIdBySessionId[sessionID] != nil else {
                    self.logger.debug("ℹ️ defer local ICE until remote peer is known: session=\(sessionID, privacy: .public)")
                    return
                }
                await self.sendSignal(.init(
                    sessionId: sessionID,
                    from: localDeviceId,
                    type: .iceCandidate,
                    payload: payload,
                    authToken: signalingAuthToken
                ))
            }
        }
        session.onDisconnected = { [weak self] reason in
            guard let self else { return }
            Task { @MainActor in
                guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                self.cleanupWebRTCSession(
                    sessionID,
                    reason: "transport_disconnected:\(reason)",
                    disconnectKind: .transient,
                    snapshotToken: snapshotMetadata.snapshotToken
                )
                self.connectionStatus = .failed("WebRTC transport disconnected: \(reason)")
                self.readiness = .idle
            }
        }
        session.onReady = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("✅ WebRTC QR answerer ready: session=\(sessionID, privacy: .public)")
                self.stopWebRTCConnectionTimeoutWatchdog(for: sessionID)
                self.currentConnection = RemoteConnection(id: sessionID, deviceName: remoteDeviceName, transport: .webrtc(session))
                self.connectionStatus = .connecting
                self.readiness = .transportReady(sessionId: sessionID)
                self.startWebRTCLivenessWatchdogIfNeeded(for: sessionID)
                self.updatePreparedSessionSnapshot(
                    sessionID: sessionID,
                    phase: .transportReady,
                    deviceId: remoteDeviceID,
                    deviceName: remoteDeviceName,
                    snapshotToken: snapshotMetadata.snapshotToken
                )
                self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
            }
        }

        beginWebRTCTerminalNotificationTracking(sessionID: sessionID)
        webrtcSessionsBySessionId[sessionID] = session
        await adoptPendingWebRTCJoinBootstrapIfPresent(sessionID: sessionID, session: session)

        do {
            startWebRTCConnectionTimeoutWatchdog(
                for: sessionID,
                source: "qr-answerer",
                snapshotToken: snapshotMetadata.snapshotToken
            )
            try await session.startAsync()
        } catch {
            cleanupWebRTCSession(
                sessionID,
                reason: "qr_answerer_start_failed",
                disconnectKind: .explicit,
                snapshotToken: snapshotMetadata.snapshotToken
            )
            connectionStatus = .failed(error.localizedDescription)
            readiness = .idle
            throw error
        }

        // 主动发送 join，帮助服务端/对端建立“同会话订阅”的心智模型（服务端可忽略）
        await sendWebRTCJoinSignal(sessionID: sessionID, localDeviceId: localDeviceId, retries: 2)
        startJoinHeartbeat(for: sessionID, attempts: Self.webRTCStartupJoinHeartbeatAttempts)

        return RemoteConnection(id: sessionID, deviceName: remoteDeviceName, transport: .webrtc(session))
    }

    private func authenticatedEnvelope(_ env: WebRTCSignalingEnvelope) -> WebRTCSignalingEnvelope? {
        let authToken = env.authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? webrtcSignalingAuthTokenBySessionId[env.sessionId]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let authToken, !authToken.isEmpty else {
            logger.error("❌ missing signaling auth token for session=\(env.sessionId, privacy: .public) type=\(env.type.rawValue, privacy: .public)")
            return nil
        }
        return WebRTCSignalingEnvelope(
            sessionId: env.sessionId,
            from: env.from,
            to: env.to,
            type: env.type,
            payload: env.payload,
            authToken: authToken,
            sentAt: env.sentAt
        )
    }

    private func sendSignal(_ env: WebRTCSignalingEnvelope, retries: Int = 2) async {
        let directedEnvelope: WebRTCSignalingEnvelope = {
            guard env.to == nil,
                  let remoteId = webrtcRemoteIdBySessionId[env.sessionId]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !remoteId.isEmpty,
                  remoteId != env.from else {
                return env
            }
            return WebRTCSignalingEnvelope(
                sessionId: env.sessionId,
                from: env.from,
                to: remoteId,
                type: env.type,
                payload: env.payload,
                authToken: env.authToken,
                sentAt: env.sentAt
            )
        }()

        guard let authorizedEnvelope = authenticatedEnvelope(directedEnvelope) else {
            appendSmokeStatus(
                "signal-send-skipped session=\(directedEnvelope.sessionId) type=\(directedEnvelope.type.rawValue) reason=missing_auth activeSession=\(webrtcSessionsBySessionId[directedEnvelope.sessionId] == nil ? 0 : 1)"
            )
            if directedEnvelope.type == .iceCandidate || directedEnvelope.type == .join {
                logger.debug(
                    "ℹ️ suppress unauthenticated best-effort signaling: session=\(directedEnvelope.sessionId, privacy: .public) type=\(directedEnvelope.type.rawValue, privacy: .public)"
                )
                return
            }
            connectionStatus = .failed("Missing signaling authorization")
            readiness = .idle
            return
        }
        let handshakeComplete = isHandshakeComplete(for: authorizedEnvelope.sessionId)
        let shouldDeferRecovery = Self.shouldDeferSignalingSendRecovery(
            isHandshakeComplete: handshakeComplete,
            messageType: authorizedEnvelope.type
        )

        if shouldDeferRecovery {
            guard let signalingClient else {
                signalingHealth = .degradedRecoverable
                logger.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId, privacy: .public) type=\(authorizedEnvelope.type.rawValue, privacy: .public) phase=missing_client"
                )
                return
            }

            let lifecyclePhase = await signalingClient.currentLifecyclePhase()
            guard lifecyclePhase == .bound else {
                signalingHealth = .degradedRecoverable
                logger.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId, privacy: .public) type=\(authorizedEnvelope.type.rawValue, privacy: .public) phase=\(lifecyclePhase.rawValue, privacy: .public)"
                )
                return
            }

            do {
                try await signalingClient.send(authorizedEnvelope)
                signalingHealth = .healthy
                appendSmokeStatus(
                    "signal-send session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue)"
                )
            } catch {
                signalingHealth = .degradedRecoverable
                logger.debug(
                    "ℹ️ suppress detached post-transport signaling send: session=\(authorizedEnvelope.sessionId, privacy: .public) type=\(authorizedEnvelope.type.rawValue, privacy: .public) phase=\(lifecyclePhase.rawValue, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                )
            }
            return
        }
        var attemptsLeft = max(0, retries)
        while true {
            do {
                try shouldAllowSignalingOperation(for: authorizedEnvelope.sessionId)
                if let signalingClient {
                    try await signalingClient.connectOrThrow()
                } else {
                    try await ensureSignalingConnected(shardKey: env.sessionId)
                }
                guard let signalingClient else {
                    throw WebSocketSignalingClient.SignalingError.notConnected
                }
                try await signalingClient.send(authorizedEnvelope)
                signalingHealth = .healthy
                appendSmokeStatus(
                    "signal-send session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue)"
                )
                return
            } catch {
                if error is SignalingOperationRejection {
                    logger.error("❌ signaling operation rejected: session=\(authorizedEnvelope.sessionId, privacy: .public) type=\(authorizedEnvelope.type.rawValue, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                    return
                }
                if let wsError = error as? WebSocketSignalingClient.SignalingError,
                   case .notConnected = wsError {
                    do {
                        if let signalingClient {
                            try await signalingClient.connectOrThrow()
                        } else {
                            try await ensureSignalingConnected(shardKey: authorizedEnvelope.sessionId)
                        }
                    } catch {
                        signalingHealth = handshakeComplete ? .degradedRecoverable : .healthy
                    }
                }
                if attemptsLeft == 0 {
                    logger.error("❌ signaling send failed: type=\(authorizedEnvelope.type.rawValue, privacy: .public) session=\(authorizedEnvelope.sessionId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                    appendSmokeStatus(
                        "signal-send-failed session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) error=\(error.localizedDescription)"
                    )
                    if handshakeComplete {
                        noteDetachedSignalingAfterTransportEstablished(
                            for: authorizedEnvelope.sessionId,
                            source: "signal_send_failed",
                            failure: error.localizedDescription
                        )
                    }
                    return
                }
                attemptsLeft -= 1
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func handleSignalingServerFrame(_ frame: WebSocketSignalingClient.SignalingServerFrame) {
        if frame.type == "bound" {
            signalingHealth = .healthy
            signalingLifecyclePhase = .bound
            return
        }
        guard frame.isError else { return }
        let sessionID = frame.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = frame.error ?? "unknown_signaling_error"
        let failureClass = Self.classifySignalingFailure(from: frame)
        appendSmokeStatus("signal-server-error session=\(sessionID ?? "-") error=\(reason)")

        guard let sessionID else {
            if reason == "server_error",
               webrtcSessionsBySessionId.keys.contains(where: isTransportEstablished(for:)) {
                logger.info("ℹ️ ignore unscoped signaling server_error after transport establishment")
                return
            }
            logger.error("❌ signaling server rejected frame: session=- error=\(reason, privacy: .public)")
            connectionStatus = .failed("Signaling error: \(reason)")
            readiness = .idle
            return
        }

        if Self.shouldUseOnDemandSignalingAfterTransportFailure(
            isHandshakeComplete: isHandshakeComplete(for: sessionID)
        ) {
            noteDetachedSignalingAfterTransportEstablished(
                for: sessionID,
                source: "server_frame",
                failure: reason,
                fatal: Self.isFatalPostTransportFailure(failureClass)
            )
            return
        }

        logger.error("❌ signaling server rejected frame: session=\(sessionID, privacy: .public) error=\(reason, privacy: .public)")
        if Self.isFatalPreTransportFailure(failureClass) {
            if webrtcSessionsBySessionId[sessionID] != nil {
                cleanupWebRTCSession(
                    sessionID,
                    reason: "signaling_server_error:\(reason)",
                    disconnectKind: .explicit
                )
            }
            connectionStatus = .failed("Signaling error: \(reason)")
            readiness = .idle
            return
        }

        signalingHealth = .degradedRecoverable
        scheduleSignalingRecovery(for: sessionID, tokenExpired: failureClass == .tokenExpired)
    }

    private func handleSignalingEnvelope(_ env: WebRTCSignalingEnvelope) async {
        if let existingSession = webrtcSessionsBySessionId[env.sessionId],
           env.from == existingSession.localDeviceId {
            return
        }
        if env.type == .join {
            await ingestWebRTCJoinBootstrapPayload(env.payload, from: env.from, sessionID: env.sessionId)
        }

        guard let session = webrtcSessionsBySessionId[env.sessionId] else {
            if env.type == .join {
                pendingWebRTCJoinBootstrapBySessionId[env.sessionId] = (from: env.from, payload: env.payload)
            }
            if env.type == .join, shouldWakeOffererFromRemoteJoin(sessionID: env.sessionId) {
                logger.warning(
                    "⚠️ remote join arrived before local WebRTC offerer was active; waking offerer: session=\(env.sessionId, privacy: .public)"
                )
                startWebRTCOfferSession(sessionID: env.sessionId)
            } else {
                logger.debug("ℹ️ drop signaling envelope without local session: type=\(env.type.rawValue, privacy: .public) session=\(env.sessionId, privacy: .public)")
            }
            return
        }

        appendSmokeStatus(
            "signal-recv session=\(env.sessionId) type=\(env.type.rawValue)"
        )

        // 记录对端 id（用于未来做定向路由）
        if webrtcRemoteIdBySessionId[env.sessionId] == nil {
            webrtcRemoteIdBySessionId[env.sessionId] = env.from
            if let snapshot = activeSessionSnapshot, snapshot.sessionId == env.sessionId {
                updatePreparedSessionSnapshot(
                    sessionID: env.sessionId,
                    phase: snapshot.phase,
                    deviceId: env.from
                )
            }
        }

        switch env.type {
        case .offer:
            stopJoinHeartbeat(for: env.sessionId)
            if let sdp = env.payload?.sdp {
                session.setRemoteOffer(sdp)
            }
            Task { @MainActor [weak self] in
                await self?.resendCachedAnswerIfNeeded(for: env.sessionId, reason: "remote_offer")
                await self?.resendCachedLocalICECandidatesIfNeeded(for: env.sessionId, reason: "remote_offer")
            }
        case .answer:
            stopJoinHeartbeat(for: env.sessionId)
            stopOfferResendLoop(for: env.sessionId)
            if let sdp = env.payload?.sdp {
                session.setRemoteAnswer(sdp)
            }
            Task { @MainActor [weak self] in
                await self?.resendCachedLocalICECandidatesIfNeeded(for: env.sessionId, reason: "remote_answer")
            }
        case .iceCandidate:
            if let p = env.payload, let c = p.candidate {
                session.addRemoteICECandidate(candidate: c, sdpMid: p.sdpMid, sdpMLineIndex: p.sdpMLineIndex)
            }
        case .join:
            Task { @MainActor [weak self] in
                await self?.resendOrRecoverLocalOfferForRemoteJoin(sessionID: env.sessionId, session: session)
                await self?.resendCachedAnswerIfNeeded(for: env.sessionId, reason: "remote-join")
                await self?.resendCachedLocalICECandidatesIfNeeded(for: env.sessionId, reason: "remote-join")
            }
        case .leave:
            cleanupWebRTCSession(
                env.sessionId,
                reason: "remote_leave",
                disconnectKind: .remoteLeave
            )
            if currentConnection == nil {
                connectionStatus = .idle
                readiness = .idle
            }
        }
    }

    private func shouldWakeOffererFromRemoteJoin(sessionID: String) -> Bool {
        Self.shouldWakeOffererFromRemoteJoin(
            hasLocalSession: webrtcSessionsBySessionId[sessionID] != nil,
            pendingOfferStart: pendingWebRTCOfferSessionIds.contains(sessionID),
            authorityBoundBootstrap: authorityBoundWebRTCBootstrapSessionIds.contains(sessionID),
            hasSignalingToken: webrtcSignalingAuthTokenBySessionId[sessionID]?.isEmpty == false
        )
    }

    private func shouldRecoverMissingOfferCacheFromRemoteJoin(sessionID: String, session: WebRTCSession) -> Bool {
        Self.shouldRecoverMissingOfferCacheFromRemoteJoin(
            hasLocalSession: true,
            isOfferer: session.role == .offerer,
            hasCachedOffer: webrtcLatestOfferBySessionId[sessionID] != nil,
            authorityBoundBootstrap: authorityBoundWebRTCBootstrapSessionIds.contains(sessionID),
            hasSignalingToken: webrtcSignalingAuthTokenBySessionId[sessionID]?.isEmpty == false
        )
    }

    // MARK: - WebRTC -> Handshake/Control Channel

    private func stopWebRTCScreenStreaming(sessionID: String) {
        if let task = webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            task.cancel()
        }
        if let task = webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            task.cancel()
        }
        webrtcSessionsBySessionId[sessionID]?.setOutgoingSystemAudioTrackEnabled(false)
    }

#if os(macOS)
    @available(macOS 14.0, *)
    private func makeWebRTCRealtimeAudioSenderIfNeeded(
        sessionID: String,
        keys: SessionKeys,
        config: RemoteDesktopStreamConfiguration?,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy,
        continuityState: RemoteRealtimeMediaAudioSender.ContinuityState? = nil
    ) async -> (sender: RemoteRealtimeMediaAudioSender, endpoint: SkyBridgeMediaEndpoint)? {
        let started = await makeWebRTCRealtimeAudioSenderCoordinator().makeSenderIfNeeded(
            sessionID: sessionID,
            keys: keys,
            config: config,
            relayBindPolicy: relayBindPolicy,
            continuityState: continuityState
        )
        return started.map { ($0.sender, $0.endpoint) }
    }

    @available(macOS 14.0, *)
    private func requestWebRTCRealtimeAudioSenderEndpoint(sessionID: String) async throws -> SkyBridgeMediaEndpoint {
        try await makeWebRTCRealtimeAudioSenderCoordinator().requestSenderEndpoint(sessionID: sessionID)
    }

    @available(macOS 14.0, *)
    private func refreshWebRTCMediaAdmissionLease(sessionID: String) async throws -> SignalServerClient.MediaAdmissionLease? {
        try await makeWebRTCRealtimeAudioSenderCoordinator().refreshAdmissionLease(sessionID: sessionID)
    }

    @available(macOS 14.0, *)
    private func makeWebRTCRealtimeAudioSenderCoordinator() -> WebRTCRealtimeAudioSenderCoordinator {
        WebRTCRealtimeAudioSenderCoordinator(
            logger: logger,
            dependencies: WebRTCRealtimeAudioSenderCoordinator.Dependencies(
                reusableAdmissionLease: { [self] sessionID in
                    usableWebRTCMediaAdmissionLease(for: sessionID)
                },
                sessionToken: { [self] sessionID in
                    webrtcSignalingAuthTokenBySessionId[sessionID]
                },
                sessionRoleName: { [self] sessionID in
                    guard let role = webrtcSessionsBySessionId[sessionID]?.role else { return nil }
                    return role == .offerer ? "initiator" : "responder"
                },
                storeAdmissionLease: { [self] lease, sessionID in
                    storeWebRTCMediaAdmissionLease(lease, for: sessionID)
                },
                requestMediaRelayLease: { [signalServer] token in
                    try await signalServer.requestMediaRelayLease(mediaAdmissionToken: token)
                },
                refreshMediaAdmissionLease: { [signalServer] sessionID, sessionToken, roleName in
                    try await signalServer.refreshMediaAdmissionLease(
                        sessionId: sessionID,
                        sessionToken: sessionToken,
                        role: roleName
                    )
                },
                appendSessionDiagnostic: { [self] line, sessionID in
                    appendWebRTCSessionDiagnostic(line, sessionID: sessionID)
                }
            )
        )
    }

#endif

    private func startWebRTCInboundHandshakeAndControlLoop(sessionID: String, session: WebRTCSession, endpointDescription: String) {
        if webrtcControlTasksBySessionId[sessionID] != nil { return }

        let queue = InboundChunkQueue()
        let orderedInboundRelay = OrderedInboundChunkRelay()
        webrtcInboundQueuesBySessionId[sessionID] = queue
        session.onData = { data in
            orderedInboundRelay.submit {
                await queue.push(data)
            }
        }

        webrtcControlTasksBySessionId[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.consumeInboundHandshakeOrControlChannelWebRTC(
                sessionID: sessionID,
                session: session,
                endpointDescription: endpointDescription,
                inbound: queue
            )
            await queue.finish()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.webrtcControlTasksBySessionId.removeValue(forKey: sessionID)
                self.webrtcInboundQueuesBySessionId.removeValue(forKey: sessionID)
                self.stopWebRTCScreenStreaming(sessionID: sessionID)
                self.failAllFileTransferWaitersForSession(sessionID: sessionID, message: "WebRTC control channel closed")
                orderedInboundRelay.cancel()
                if self.webrtcSessionsBySessionId[sessionID] != nil {
                    self.cleanupWebRTCSession(
                        sessionID,
                        reason: "control_channel_closed",
                        disconnectKind: .transient
                    )
                    self.connectionStatus = .failed("WebRTC control channel closed")
                    self.readiness = .idle
                }
            }
        }
    }

    private func consumeInboundHandshakeOrControlChannelWebRTC(
        sessionID: String,
        session: WebRTCSession,
        endpointDescription: String,
        inbound: InboundChunkQueue
    ) async {
        let webRTCHandshakeMaxChunkBytes = 1024
        let webRTCHandshakeMaxPaddedPayloadBytes = (8 * 1024) - 4

        struct DirectHandshakeTransport: DiscoveryTransport {
            let sendRaw: @Sendable (Data) async throws -> Void
            func send(to peer: PeerIdentifier, data: Data) async throws { try await sendRaw(data) }
        }

        @Sendable func sendFramed(_ data: Data) async throws {
            try await session.sendFramedPayloadAsync(
                data,
                maxChunkBytes: webRTCHandshakeMaxChunkBytes,
                // Control-plane messages must not starve behind ongoing screen/file traffic.
                maxBufferedAmountBytes: 256 * 1024
            )
        }

        func receiveSome(max: Int) async throws -> Data {
            try await inbound.next(max: max)
        }

        func receiveExactly(_ length: Int) async throws -> Data {
            var buffer = Data()
            buffer.reserveCapacity(length)
            while buffer.count < length {
                let remaining = length - buffer.count
                let chunk = try await receiveSome(max: min(65536, remaining))
                buffer.append(chunk)
            }
            return buffer
        }

        let transport = DirectHandshakeTransport(sendRaw: { data in
            let rawHandshake = HandshakePadding.unwrapIfNeeded(data, label: "tx/webrtc")
            let tunedHandshake = HandshakePadding.wrapIfEnabled(
                rawHandshake,
                label: "tx/webrtc",
                maxTotalBytes: webRTCHandshakeMaxPaddedPayloadBytes
            )
            if let messageB = try? HandshakeMessageB.decode(from: rawHandshake) {
                await MainActor.run {
                    self.lastRekeyEvent = "messageB raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suite=\(messageB.selectedSuite.rawValue)"
                }
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey tx MessageB raw=\(rawHandshake.count) padded=\(tunedHandshake.count) suite=\(messageB.selectedSuite.rawValue)")
                }
            } else if (try? HandshakeFinished.decode(from: rawHandshake)) != nil {
                await MainActor.run {
                    self.lastRekeyEvent = "finished raw=\(rawHandshake.count) padded=\(tunedHandshake.count)"
                }
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey tx Finished raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
                }
            }
            try await sendFramed(tunedHandshake)
        })

        let peerDeviceId = webrtcRemoteIdBySessionId[sessionID] ?? "webrtc-\(sessionID)"
        let peer = PeerIdentifier(deviceId: peerDeviceId)
        let currentPathTrustProvider = CurrentPathHandshakeTrustProvider(
            expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionID],
            fallbackPeerIDs: [peerDeviceId, endpointDescription],
            additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionID)
        )

        let handshakeState = WebRTCHandshakeLoopState()

        func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
            WebRTCControlChannelCodec.isLikelyHandshakeControlPacket(data)
        }

        func isActiveHandshakeDriverFrame(_ data: Data) -> Bool {
            WebRTCControlChannelCodec.isActiveHandshakeDriverFrame(data)
        }

        func encryptAppPayload(
            _ plaintext: Data,
            with keys: SessionKeys,
            packetType: WebRTCAppSecurePacketType = .appControl
        ) throws -> Data {
            try sealWebRTCSecurePayload(
                plaintext,
                with: keys,
                sessionID: sessionID,
                packetType: packetType
            )
        }

        func makeLocalHeartbeatMessage() async -> AppMessage? {
            let localDeviceId = session.localDeviceId
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !localDeviceId.isEmpty else { return nil }
            let localIdentity = RemoteControlSecurityNoticeCenter.shared.localIdentitySnapshot()
            return CrossNetworkWebRTCLocalAppMessageFactory.heartbeatMessage(
                deviceId: localDeviceId,
                remoteVideoFormats: Self.supportedRemoteVideoFormats(),
                accountDisplayName: localIdentity?.accountDisplayName,
                nebulaId: localIdentity?.nebulaId
            )
        }

        func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> WebRTCAppSecureOpenedPayload {
            try openWebRTCSecurePayload(ciphertext, with: keys, sessionID: sessionID)
        }

        func decodeCompatibilityAppMessage(_ plaintext: Data) -> AppMessage? {
            WebRTCControlChannelCodec.decodeCompatibilityAppMessage(plaintext)
        }

        func bootstrapAppMessageKind(_ message: AppMessage) -> String {
            WebRTCControlChannelCodec.bootstrapAppMessageKind(message)
        }

        @MainActor
        func startOutboundHeartbeatIfNeeded() {
            guard self.webrtcOutboundHeartbeatTasksBySessionId[sessionID] == nil else { return }
            self.appendWebRTCSessionDiagnostic(
                "app-heartbeat-send-start session=\(sessionID) interval=2.0",
                sessionID: sessionID
            )
            self.webrtcOutboundHeartbeatTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.webrtcOutboundHeartbeatTasksBySessionId.removeValue(forKey: sessionID)
                }
                while !Task.isCancelled {
                    guard self.webrtcSessionsBySessionId[sessionID] === session else { break }
                    guard case .connected = self.connectionStatus else {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    guard let keys = self.webrtcSessionKeysBySessionId[sessionID] else {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    if self.webrtcRekeyInProgressSessionIds.contains(sessionID) {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }

                    guard let heartbeat = await makeLocalHeartbeatMessage() else {
                        self.appendWebRTCSessionDiagnostic(
                            "app-heartbeat-send-skipped session=\(sessionID) reason=empty_device_id",
                            sessionID: sessionID
                        )
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }

                    do {
                        let plaintext = try JSONEncoder().encode(heartbeat)
                        let ciphertext = try encryptAppPayload(plaintext, with: keys)
                        let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: "tx/webrtc-heartbeat")
                        try await sendFramed(padded)
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            self.appendSmokeStatus("app-heartbeat-send session=\(sessionID)")
                        }
                    } catch {
                        self.logger.debug(
                            "ℹ️ WebRTC outbound heartbeat send failed: session=\(sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                        )
                        self.appendWebRTCSessionDiagnostic(
                            "app-heartbeat-send-failed session=\(sessionID) error=\(sanitizeStatus(error.localizedDescription))",
                            sessionID: sessionID
                        )
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }

                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }

        func orderedUniqueCandidateIds(_ rawValues: [String]) -> [String] {
            WebRTCControlChannelCodec.orderedUniqueCandidateIds(rawValues)
        }

        func pairingExchangeFingerprint(_ payload: AppMessage.PairingIdentityExchangePayload) -> String {
            WebRTCControlChannelCodec.pairingExchangeFingerprint(payload)
        }

        func makeLocalPairingIdentityExchangePayload() async throws -> AppMessage.PairingIdentityExchangePayload {
            let provider = CryptoProviderFactory.make(policy: .preferPQC)
            let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
                try await DeviceIdentityKeyManager.shared.pairingIdentityKEMPublicKeys(using: provider)
            )
            guard !kemKeys.isEmpty else {
                throw NSError(
                    domain: "CrossNetworkConnectionManager",
                    code: 720,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "local device has no usable PQC KEM public keys to advertise"
                    ]
                )
            }

            let localId = session.localDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !localId.isEmpty else {
                throw NSError(
                    domain: "CrossNetworkConnectionManager",
                    code: 721,
                    userInfo: [NSLocalizedDescriptionKey: "local device id is empty"]
                )
            }

            let localIdentity = RemoteControlSecurityNoticeCenter.shared.localIdentitySnapshot()
            return CrossNetworkWebRTCLocalAppMessageFactory.pairingIdentityExchangePayload(
                deviceId: localId,
                kemPublicKeys: kemKeys,
                protocolIdentityPublicKeys: await localProtocolIdentityPublicKeysForPairing(),
                remoteVideoFormats: Self.supportedRemoteVideoFormats(),
                accountDisplayName: localIdentity?.accountDisplayName,
                nebulaId: localIdentity?.nebulaId
            )
        }

        func sendLocalPairingIdentityExchange(
            keys: SessionKeys,
            force: Bool,
            stage: String
        ) async throws {
            let payload = try await makeLocalPairingIdentityExchangePayload()
            let fingerprint = pairingExchangeFingerprint(payload)
            if !force, self.webrtcBootstrapReplyFingerprintBySessionId[sessionID] == fingerprint {
                return
            }

            let reply = AppMessage.pairingIdentityExchange(payload)
            let outPlain = try JSONEncoder().encode(reply)
            let outCipher = try encryptAppPayload(outPlain, with: keys)
            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-bootstrap")
            try await sendFramed(outPadded)
            self.webrtcBootstrapReplyFingerprintBySessionId[sessionID] = fingerprint
            self.appendSmokeStatus(
                "app-pairing-send session=\(sessionID) stage=\(stage) deviceId=\(payload.deviceId) keys=\(payload.kemPublicKeys.count)"
            )
            logger.info(
                "📤 WebRTC pairingIdentityExchange sent: session=\(sessionID, privacy: .public) stage=\(stage, privacy: .public) keys=\(payload.kemPublicKeys.count, privacy: .public)"
            )
        }

        let initialHandshakeTask: Task<Void, Never>? = {
            guard WebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: session.role) else {
                return nil
            }

            return Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.webrtcSessionsBySessionId[sessionID] === session else { return }
                guard handshakeState.driver == nil, handshakeState.sessionKeys == nil else { return }

                do {
                    let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                    let handshakePolicy = HandshakePolicy.recommendedDefault(
                        compatibilityModeEnabled: compatibilityModeEnabled
                    )
                    let strictPQCRequested = handshakePolicy.requirePQC
                    let capability = CryptoProviderFactory.detectCapability()
                    let peerResolutionDeadline = Date().addingTimeInterval(strictPQCRequested ? 6.0 : 0.0)
                    var trustedPeerKEMKeys: [UInt16: Data] = [:]
                    var trustLookupPeerId: String?
                    var resolvedPeerDeviceId: String?
                    var candidateIds: [String] = []

                    while true {
                        let resolution = WebRTCPQCHandshakePolicy.initialWebRTCHandshakePeerResolution(
                            expectedRemoteDeviceId: currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.deviceId,
                            learnedRemoteDeviceId: self.webrtcRemoteIdBySessionId[sessionID],
                            endpointDescription: endpointDescription
                        )
                        resolvedPeerDeviceId = resolution.resolvedPeerDeviceId
                        candidateIds = resolution.candidateIds
                        trustLookupPeerId = resolvedPeerDeviceId ?? candidateIds.first
                        trustedPeerKEMKeys.removeAll(keepingCapacity: true)

                        if let resolvedPeerDeviceId {
                            for candidateId in orderedUniqueCandidateIds([resolvedPeerDeviceId] + candidateIds) {
                                let merged = await self.trustedSignedRefreshKEMPublicKeys(
                                    forCandidates: [candidateId],
                                    sessionID: sessionID
                                )
                                guard !merged.isEmpty else { continue }
                                trustedPeerKEMKeys = merged
                                trustLookupPeerId = candidateId
                                break
                            }
                        }

                        if !WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(
                            strictPQCRequested: strictPQCRequested,
                            resolvedPeerDeviceId: resolvedPeerDeviceId,
                            hasTrustedPeerKEM: !trustedPeerKEMKeys.isEmpty
                        ) {
                            break
                        }

                        guard Date() < peerResolutionDeadline else { break }
                        try? await Task.sleep(for: .milliseconds(150))
                    }

                    guard let trustLookupPeerId else { return }

                    let hasTrustedPeerKEM = !trustedPeerKEMKeys.isEmpty
                    let useClassicAuthorityBootstrap = WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                        sessionID: sessionID,
                        authorityBoundBootstrapSessionIds: authorityBoundWebRTCBootstrapSessionIds,
                        expectedRemoteAuthorityAlgorithm: currentPathExpectedRemoteAuthorityBySessionId[sessionID]?.protocolSigningAlgorithm,
                        activeConnectionCodeSessionID: activeConnectionCodeSessionID,
                        strictPQCRequested: strictPQCRequested
                    )
                    let bootstrapDecision = WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                        strictPQCRequested: strictPQCRequested,
                        hasTrustedPeerKEM: hasTrustedPeerKEM,
                        capability: capability,
                        useClassicAuthorityBootstrap: useClassicAuthorityBootstrap,
                        peerDeviceId: resolvedPeerDeviceId ?? trustLookupPeerId
                    )
                    let bootstrapPlan: WebRTCPQCHandshakePolicy.InitialHandshakeBootstrapPlan
                    switch bootstrapDecision {
                    case .proceed(let plan):
                        bootstrapPlan = plan
                    case .reject(let failure):
                        if failure.includeProviderAvailabilityInLog {
                            logger.error(
                                "⛔️ \(failure.message, privacy: .public) hasApplePQC=\(capability.hasApplePQC, privacy: .public) hasLiboqs=\(capability.hasLiboqs, privacy: .public)"
                            )
                        }
                        throw NSError(
                            domain: "CrossNetworkConnectionManager",
                            code: failure.code,
                            userInfo: [NSLocalizedDescriptionKey: failure.message]
                        )
                    }
                    let selection = bootstrapPlan.selection

                    let cryptoProvider = CryptoProviderFactory.make(policy: selection)
                    let sigAAlgorithm: ProtocolSigningAlgorithm = selection == .classicOnly ? .ed25519 : .mlDSA65
                    let offeredSuites: [CryptoSuite] = selection == .classicOnly
                        ? cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
                        : DeviceIdentityKeyManager
                            .pairingIdentityAdvertisedPQCSuites(using: cryptoProvider)
                            .filter(\.isPQCGroup)

                    let outboundDriver = try HandshakeDriver(
                        transport: transport,
                        cryptoProvider: cryptoProvider,
                        protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                        identityProvider: DeviceIdentityHandshakeProvider(
                            sigAAlgorithm: sigAAlgorithm,
                            includeSecureEnclavePoP: handshakePolicy.requireSecureEnclavePoP
                        ),
                        sigAAlgorithm: sigAAlgorithm,
                        offeredSuites: offeredSuites,
                        policy: handshakePolicy,
                        cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: offeredSuites),
                        trustProvider: selection == .classicOnly ? currentPathTrustProvider : nil
                    )
                    handshakeState.driver = outboundDriver

                    logger.info(
                        "🤝 WebRTC 初始出站握手启动: session=\(sessionID, privacy: .public) peer=\(trustLookupPeerId, privacy: .public) policy=\(selection.rawValue, privacy: .public) mode=\(bootstrapPlan.bootstrapMode, privacy: .public) trustedKEM=\(hasTrustedPeerKEM, privacy: .public) authorityBootstrap=\(bootstrapPlan.usesClassicAuthorityBootstrap, privacy: .public)"
                    )
                    let keys = try await outboundDriver.initiateHandshake(
                        with: PeerIdentifier(deviceId: trustLookupPeerId)
                    )

                    guard handshakeState.driver === outboundDriver,
                    self.webrtcSessionsBySessionId[sessionID] != nil else {
                        return
                    }

                    handshakeState.sessionKeys = keys
                    handshakeState.driver = nil
                    self.webrtcSessionKeysBySessionId[sessionID] = keys
                    let isStrictClassicAuthorityBootstrap =
                        strictPQCRequested && useClassicAuthorityBootstrap && !keys.negotiatedSuite.isPQCGroup
                    if isStrictClassicAuthorityBootstrap {
                        self.lastRekeyEvent = "bootstrapOnly suite=\(keys.negotiatedSuite.rawValue)"
                        self.strictPQCClassicBootstrapOnlySessionIds.insert(sessionID)
                        self.logger.warning(
                            "⏳ WebRTC strictPQC classic authority bootstrap is bootstrap-only: session=\(sessionID, privacy: .public) event=pqcRekeyPending suite=\(keys.negotiatedSuite.rawValue, privacy: .public)"
                        )
                        self.appendSmokeStatus(
                            "strict-pqc-bootstrap-only session=\(sessionID) suite=\(keys.negotiatedSuite.rawValue)"
                        )
                        do {
                            try await sendLocalPairingIdentityExchange(
                                keys: keys,
                                force: true,
                                stage: "strict-bootstrap"
                            )
                        } catch {
                            self.logger.warning(
                                "⚠️ WebRTC strictPQC bootstrap pairingIdentityExchange send failed: session=\(sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                            )
                            self.appendSmokeStatus(
                                "app-pairing-send-failed session=\(sessionID) stage=strict_bootstrap error=\(sanitizeStatus(error.localizedDescription))"
                            )
                        }
                        return
                    }
                    self.strictPQCClassicBootstrapOnlySessionIds.remove(sessionID)
                    self.connectionStatus = .connected
                    self.readiness = .handshakeComplete(
                        sessionId: sessionID,
                        negotiatedSuite: keys.negotiatedSuite.rawValue
                    )
                    self.markCrossNetworkPresenceConnected(
                        sessionID: sessionID,
                        negotiatedSuite: keys.negotiatedSuite.rawValue
                    )
                    self.updatePreparedSessionSnapshot(
                        sessionID: sessionID,
                        phase: .handshakeComplete,
                        negotiatedSuite: keys.negotiatedSuite.rawValue
                    )
                    startOutboundHeartbeatIfNeeded()
                    startScreenStreamingIfNeeded(keys: keys)
                    logger.info(
                        "✅ WebRTC 初始出站握手完成: session=\(sessionID, privacy: .public) suite=\(keys.negotiatedSuite.rawValue, privacy: .public)"
                    )
                } catch {
                    guard self.webrtcSessionsBySessionId[sessionID] != nil else { return }
                    handshakeState.driver = nil
                    self.cleanupWebRTCSession(
                        sessionID,
                        reason: "handshake_failed",
                        disconnectKind: .explicit
                    )
                    self.connectionStatus = .failed("WebRTC handshake failed: \(error.localizedDescription)")
                    self.readiness = .idle
                }
            }
        }()

        func maybeStartOutboundPQCRekeyIfNeeded(
            from pairingPayload: AppMessage.PairingIdentityExchangePayload,
            trigger: String
        ) async {
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                print("🧪 mac maybeStartPQCRekey trigger=\(trigger) deviceId=\(pairingPayload.deviceId) keys=\(pairingPayload.kemPublicKeys.count)")
            }
            guard let establishedKeys = handshakeState.sessionKeys else { return }
            guard !establishedKeys.negotiatedSuite.isPQCGroup else { return }
            let strictPQCRequired = HandshakePolicy.recommendedDefault(
                compatibilityModeEnabled: UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
            ).requirePQC
            func failStrictClassicBootstrap(reason: String, diagnostic: String) {
                guard strictPQCRequired, !establishedKeys.negotiatedSuite.isPQCGroup else { return }
                self.logger.error(
                    "⛔️ WebRTC strictPQC bootstrap could not rekey to PQC; closing classic bootstrap-only session: session=\(sessionID, privacy: .public) event=pqcRekeyFailed trigger=\(trigger, privacy: .public) reason=\(diagnostic, privacy: .public)"
                )
                self.appendWebRTCSessionDiagnostic(
                    "strictPQCRekeyFailed session=\(sessionID) trigger=\(trigger) reason=\(sanitizeStatus(reason))",
                    sessionID: sessionID
                )
                self.lastRekeyEvent = "failed strict reason=\(reason)"
                handshakeState.driver = nil
                handshakeState.previousSessionKeysBeforeRekey = nil
                self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                self.strictPQCClassicBootstrapOnlySessionIds.remove(sessionID)
                self.cleanupWebRTCSession(
                    sessionID,
                    reason: "strict_pqc_rekey_failed_\(reason)",
                    disconnectKind: .explicit
                )
                self.connectionStatus = .failed("Strict PQC rekey failed: \(diagnostic)")
                self.readiness = .idle
            }
            guard handshakeState.driver == nil else { return }
            guard !self.webrtcRekeyInProgressSessionIds.contains(sessionID) else { return }
 // 发起者选举不能直接采用可能为空或为 "webrtc-<session>" 占位的标识：
 // answerer 路径从不校验 session.localDeviceId 是否为空，且对端 id 在解析完成前可能仍是占位串，
 // 二者经 canonicalPQCRekeyElectionDeviceId 规范化后都会变成 nil，使选举判为“不可选举”。
 // 与 iOS 的 resolvedPQCRekeyElectionRemoteDeviceId 行为对齐——从多个稳定来源解析出首个可规范化的标识
 //（本端回退到 init 即就绪、恒定可用的 deviceFingerprint），避免在双方都是 OS27 的严格 PQC 引导期，
 // 把本可恢复的瞬时占位态误判为不可选举而直接拆除已授权的连接。
            let localElectionDeviceId = orderedUniqueCandidateIds([session.localDeviceId, deviceFingerprint])
                .first { WebRTCPQCHandshakePolicy.canonicalPQCRekeyElectionDeviceId($0) != nil }
            let remoteElectionDeviceId = orderedUniqueCandidateIds([pairingPayload.deviceId, peerDeviceId, endpointDescription])
                .first { WebRTCPQCHandshakePolicy.canonicalPQCRekeyElectionDeviceId($0) != nil }
            guard let shouldInitiate = WebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: localElectionDeviceId,
                remoteDeviceId: remoteElectionDeviceId
            ) else {
                self.lastRekeyEvent = "waiting peer=\(pairingPayload.deviceId) election"
                logger.info(
                    "⏳ WebRTC rekey waiting for stable initiator election: session=\(sessionID, privacy: .public) event=pqcRekeyPending trigger=\(trigger, privacy: .public) local=\(localElectionDeviceId ?? "nil", privacy: .public) peer=\(remoteElectionDeviceId ?? "nil", privacy: .public)"
                )
                failStrictClassicBootstrap(
                    reason: "unstable_rekey_election",
                    diagnostic: "stable initiator election unavailable (local=\(localElectionDeviceId ?? "nil") peer=\(remoteElectionDeviceId ?? "nil"))"
                )
                return
            }
            guard shouldInitiate else {
                self.lastRekeyEvent = "await inbound peer=\(pairingPayload.deviceId)"
                logger.info(
                    "ℹ️ WebRTC rekey elected peer as initiator; waiting inbound rekey: session=\(sessionID, privacy: .public) event=pqcRekeyPending trigger=\(trigger, privacy: .public) peer=\(pairingPayload.deviceId, privacy: .public)"
                )
                return
            }

            let capability = CryptoProviderFactory.detectCapability()
            guard capability.hasApplePQC || capability.hasLiboqs else {
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac skip PQC rekey: no local PQC provider")
                }
                logger.info(
                    "⚠️ WebRTC skip PQC rekey: local PQC provider unavailable. session=\(sessionID, privacy: .public) event=pqcRekeyFailed trigger=\(trigger, privacy: .public)"
                )
                failStrictClassicBootstrap(
                    reason: "local_pqc_provider_unavailable",
                    diagnostic: "local device has no available Apple PQC or liboqs provider"
                )
                return
            }

            let prefersLiboqsForPeer =
                (pairingPayload.platform ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("android") == .orderedSame

            let candidateIds = orderedUniqueCandidateIds([
                pairingPayload.deviceId,
                peerDeviceId,
                endpointDescription
            ])
            guard !candidateIds.isEmpty else { return }

            var peerKEMByCandidateId: [String: [UInt16: Data]] = [:]
            for candidateId in candidateIds {
                peerKEMByCandidateId[candidateId] = await self.trustedSignedRefreshKEMPublicKeys(
                    forCandidates: [candidateId],
                    sessionID: sessionID
                )
            }

            let peerHasXWing = peerKEMByCandidateId.values.contains { keys in
                WebRTCPQCHandshakePolicy.peerKEMCanonicalWireIds(keys).contains(CryptoSuite.xwingMLDSA.canonicalKEMSuite.wireId)
            }

            let providerPlans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
                capability: capability,
                prefersLiboqsForPeer: prefersLiboqsForPeer,
                peerHasXWing: peerHasXWing,
                appleXWingAvailable: Self.isAppleXWingRuntimeAvailableForWebRTCRekey()
            )
            let providerCandidates: [(provider: any CryptoProvider, label: String, suites: [CryptoSuite])] =
                Self.webRTCPQCRekeyProviderCandidates(from: providerPlans)

            var selectedPeerId: String?
            var selectedProvider: (any CryptoProvider)?
            var selectedProviderLabel = ""
            var selectedCryptoPolicy: CryptoPolicy = .default
            var offeredSuites: [CryptoSuite] = []

            providerLoop: for candidate in providerCandidates {
                let candidateLocalSuites = candidate.suites.filter(\.isPQCGroup)
                guard !candidateLocalSuites.isEmpty else { continue }

                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    let localSuitesSummary = candidateLocalSuites.map(\.rawValue).joined(separator: ",")
                    print(
                        "🧪 mac PQC candidates=\(candidateIds.joined(separator: ",")) " +
                        "provider=\(candidate.label) localSuites=\(localSuitesSummary)"
                    )
                }

                for candidateId in candidateIds {
                    let peerKEMPublicKeys = peerKEMByCandidateId[candidateId] ?? [:]
                    let sharedSuites = WebRTCPQCHandshakePolicy.webRTCPQCRekeySharedSuites(
                        localPQCSuites: candidateLocalSuites,
                        with: peerKEMPublicKeys
                    )
                    if !sharedSuites.isEmpty {
                        selectedPeerId = candidateId
                        selectedProvider = candidate.provider
                        selectedProviderLabel = candidate.label
                        offeredSuites = sharedSuites
                        selectedCryptoPolicy = sharedSuites.contains(where: { $0.isHybrid })
                            ? CryptoPolicy(
                                minimumSecurityTier: .hybridPreferred,
                                allowExperimentalHybrid: true,
                                advertiseHybrid: true,
                                requireHybridIfAvailable: true
                            )
                            : .default
                        break providerLoop
                    }
                }
            }

            guard let selectedPeerId, let cryptoProvider = selectedProvider else {
                let mergedPeerKEMPublicKeys = await self.trustedSignedRefreshKEMPublicKeys(
                    forCandidates: candidateIds,
                    sessionID: sessionID
                )
                let missingCanonicalSuites = Array(Set(
                    providerCandidates
                        .flatMap { $0.suites.filter(\.isPQCGroup) }
                        .map(\.canonicalKEMSuite)
                        .filter { mergedPeerKEMPublicKeys[$0.wireId] == nil }
                        .map(\.rawValue)
                )).sorted()
                let missingSummary = missingCanonicalSuites.joined(separator: ",")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac skip PQC rekey: missing peer KEM suites=\(missingSummary)")
                }
                self.lastRekeyEvent = "waiting peer=\(pairingPayload.deviceId) missing=\(missingSummary)"
                logger.info(
                    "⏳ WebRTC rekey waiting for peer KEM keys: session=\(sessionID, privacy: .public) event=pqcRekeyPending trigger=\(trigger, privacy: .public) candidates=\(candidateIds.joined(separator: ","), privacy: .public) missing=\(missingSummary, privacy: .public)"
                )
                failStrictClassicBootstrap(
                    reason: "missing_common_peer_kem",
                    diagnostic: missingSummary.isEmpty
                        ? "no common trusted peer PQC KEM key"
                        : "missing common trusted peer PQC KEM key(s): \(missingSummary)"
                )
                return
            }

            do {
                let identityProvider = DeviceIdentityHandshakeProvider(sigAAlgorithm: .mlDSA65)
                let rekeyTrustProvider = CurrentPathHandshakeTrustProvider(
                    expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionID],
                    fallbackPeerIDs: candidateIds,
                    additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionID)
                )

                let outboundDriver = try HandshakeDriver(
                    transport: transport,
                    cryptoProvider: cryptoProvider,
                    protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: .mlDSA65),
                    identityProvider: identityProvider,
                    sigAAlgorithm: .mlDSA65,
                    offeredSuites: offeredSuites,
                    policy: .strictPQC,
                    cryptoPolicy: selectedCryptoPolicy,
                    trustProvider: rekeyTrustProvider
                )

                handshakeState.previousSessionKeysBeforeRekey = establishedKeys
                handshakeState.driver = outboundDriver
                self.webrtcRekeyInProgressSessionIds.insert(sessionID)
                if let streamTask = self.webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) {
                    streamTask.cancel()
                }
                if let interactionTask = self.webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID) {
                    interactionTask.cancel()
                }

                let offeredSummary = offeredSuites.map(\.rawValue).joined(separator: ",")
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print(
                        "🧪 mac start PQC rekey peer=\(selectedPeerId) offered=\(offeredSummary) " +
                        "provider=\(String(describing: type(of: cryptoProvider))) source=\(selectedProviderLabel)"
                    )
                }
                self.lastRekeyEvent = "start peer=\(selectedPeerId) policy=requirePQC"
                logger.info(
                    "🔁 WebRTC outbound PQC rekey start: session=\(sessionID, privacy: .public) event=pqcRekeyStarted trigger=\(trigger, privacy: .public) peer=\(selectedPeerId, privacy: .public) offered=\(offeredSummary, privacy: .public)"
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
	                    do {
	                        let rekeyed = try await outboundDriver.initiateHandshake(
	                            with: PeerIdentifier(deviceId: selectedPeerId)
	                        )
	                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
	                            print("🧪 mac PQC rekey task completed suite=\(rekeyed.negotiatedSuite.rawValue)")
	                        }
	                        let rekeyCompletionEvent = rekeyed.negotiatedSuite.isPQCGroup
	                            ? "pqcRekeyComplete"
	                            : "classicRekeyComplete"
	                        let rekeyCompletionLabel = rekeyed.negotiatedSuite.isPQCGroup
	                            ? "PQC"
	                            : "classic compatibility"
	                        self.logger.info(
	                            "✅ WebRTC outbound \(rekeyCompletionLabel, privacy: .public) rekey completed: session=\(sessionID, privacy: .public) event=\(rekeyCompletionEvent, privacy: .public) peer=\(selectedPeerId, privacy: .public) suite=\(rekeyed.negotiatedSuite.rawValue, privacy: .public)"
	                        )
                        guard handshakeState.driver === outboundDriver else { return }
                        handshakeState.sessionKeys = rekeyed
                        handshakeState.previousSessionKeysBeforeRekey = nil
                        handshakeState.driver = nil
	                        self.webrtcRekeyInProgressSessionIds.remove(sessionID)
	                        self.strictPQCClassicBootstrapOnlySessionIds.remove(sessionID)
	                        self.lastRekeyEvent = "complete suite=\(rekeyed.negotiatedSuite.rawValue)"
                            PairingTrustApprovalService.shared.updateVerificationCode(
                                declaredDeviceId: pairingPayload.deviceId,
                                sessionKeys: rekeyed
                            )
	                        self.webrtcSessionKeysBySessionId[sessionID] = rekeyed
	                        self.connectionStatus = .connected
                        self.readiness = .handshakeComplete(
                            sessionId: sessionID,
                            negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                        )
                        self.markCrossNetworkPresenceConnected(
                            sessionID: sessionID,
                            negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                        )
                        self.updatePreparedSessionSnapshot(
                            sessionID: sessionID,
                            phase: .handshakeComplete,
                            negotiatedSuite: rekeyed.negotiatedSuite.rawValue
                        )
                        startOutboundHeartbeatIfNeeded()
                        startScreenStreamingIfNeeded(keys: rekeyed)
                    } catch {
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            print("🧪 mac PQC rekey task failed err=\(error.localizedDescription)")
                        }
                        guard handshakeState.driver === outboundDriver else { return }

                        if let fallbackKeys = handshakeState.previousSessionKeysBeforeRekey {
                            if strictPQCRequired && !fallbackKeys.negotiatedSuite.isPQCGroup {
                                self.logger.error(
                                    "⛔️ WebRTC outbound PQC rekey failed under strictPQC; closing classic bootstrap-only session: session=\(sessionID, privacy: .public) event=pqcRekeyFailed peer=\(selectedPeerId, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                                )
                                handshakeState.previousSessionKeysBeforeRekey = nil
                                handshakeState.driver = nil
                                self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                                self.lastRekeyEvent = "failed strict reason=\(error.localizedDescription)"
                                self.cleanupWebRTCSession(
                                    sessionID,
                                    reason: "strict_pqc_rekey_failed",
                                    disconnectKind: .explicit
                                )
                                self.connectionStatus = .failed("Strict PQC rekey failed: \(error.localizedDescription)")
                                self.readiness = .idle
                                return
                            }
                            self.logger.warning(
                                "⚠️ WebRTC outbound PQC rekey failed, preserving established session: session=\(sessionID, privacy: .public) event=pqcRekeyFailed establishedClassicPreserved=true peer=\(selectedPeerId, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                            )
                            handshakeState.sessionKeys = fallbackKeys
                            handshakeState.previousSessionKeysBeforeRekey = nil
                            handshakeState.driver = nil
                            self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                            self.lastRekeyEvent = "failed reason=\(error.localizedDescription)"
                            self.webrtcSessionKeysBySessionId[sessionID] = fallbackKeys
                            startOutboundHeartbeatIfNeeded()
                            startScreenStreamingIfNeeded(keys: fallbackKeys)
                        } else {
                            self.cleanupWebRTCSession(
                                sessionID,
                                reason: "handshake_failed",
                                disconnectKind: .explicit
                            )
                            self.connectionStatus = .failed("WebRTC handshake failed: \(error.localizedDescription)")
                            self.readiness = .idle
                        }
                    }
                }
            } catch {
                logger.warning(
                    "⚠️ WebRTC PQC rekey bootstrap setup failed: session=\(sessionID, privacy: .public) trigger=\(trigger, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                )
                failStrictClassicBootstrap(
                    reason: "rekey_driver_setup_failed",
                    diagnostic: error.localizedDescription
                )
            }
        }

        let inboundFileTransferReceiver = WebRTCInboundFileTransferReceiver()
        defer {
            inboundFileTransferReceiver.cleanupOnChannelClosed()
        }

        func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
            ScreenCaptureKitStreamer.jpegData(from: image, quality: quality)
        }

        func degradedFallbackJPEGData(
            from image: CGImage,
            profile: WebRTCDegradedFallbackJPEGProfile
        ) -> (image: CGImage, data: Data, quality: CGFloat)? {
            ScreenCaptureKitStreamer.encodeDegradedFallbackJPEG(
                from: image,
                profile: profile
            )
        }

        func syntheticScreenDataIfEnabled() -> ScreenDataWire? {
            guard ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN"] == "1" else {
                return nil
            }

            let width = 96
            let height = 54
            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }

            let phase = CGFloat(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0))
            ctx.setFillColor(CGColor(red: phase, green: 0.18, blue: 1.0 - phase, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.35))
            ctx.fill(CGRect(x: 8, y: 8, width: width - 16, height: 10))
            ctx.fill(CGRect(x: 8, y: 24, width: width - 28, height: 8))
            ctx.fill(CGRect(x: 8, y: 38, width: width - 40, height: 8))

            guard let image = ctx.makeImage(),
                  let jpg = jpegData(from: image, quality: 0.75) else {
                return nil
            }

            return ScreenDataWire(
                width: width,
                height: height,
                imageData: jpg,
                timestamp: Date().timeIntervalSince1970,
                format: "jpeg",
                isSyncFrame: true
            )
        }

        @MainActor
        func currentVideoPolicy(for transportPath: WebRTCSession.ICETransportPath) -> WebRTCRemoteDesktopVideoPolicy {
            let settings = RemoteDesktopSettingsManager.shared.settings.displaySettings
            let peerFormats = self.effectiveWebRTCRemoteVideoFormats(for: sessionID)
            let nativeVideoTrackEnabled = session.supportsNativeScreenVideoTrack
            let selectedPolicy = WebRTCRemoteDesktopVideoPolicySelector.select(
                request: self.webrtcVideoRequest(
                    for: sessionID,
                    from: settings,
                    transportPath: transportPath
                ),
                transportPath: transportPath,
                peerFormats: peerFormats,
                thermalState: ProcessInfo.processInfo.thermalState,
                isAppleSilicon: Self.isAppleSiliconRuntime,
                nativeVideoTrackEnabled: nativeVideoTrackEnabled
            )
            let streamConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
            let strictSelectedPolicy = Self.policyByEnforcingStrictMediaFrameRateFloor(
                selectedPolicy,
                remoteStreamConfiguration: streamConfig
            )
            let failFastMediaFallbacks = Self.shouldFailFastRemoteMediaFallbacks(
                remoteStreamConfiguration: streamConfig
            )
            let audioRedirectionEnabled = streamConfig?.audioRedirectionEnabled == true
            let shouldUseNativeAudioTrack = Self.shouldUseWebRTCNativeAudio(
                audioRedirectionEnabled: audioRedirectionEnabled,
                remoteNativeAudioTrackEnabled: streamConfig?.nativeAudioTrackEnabled == true,
                localNativeAudioTrackReady: session.supportsNativeSystemAudioTrack
            )
            let shouldUseFallbackAudioChunks = Self.shouldUseWebRTCAudioFallback(
                audioRedirectionEnabled: audioRedirectionEnabled,
                nativeAudioTrackEnabled: shouldUseNativeAudioTrack,
                legacyAudioFallbackEnabled: streamConfig?.allowsLegacyAudioChunkFallback == true
            )
            return shouldUseFallbackAudioChunks && !failFastMediaFallbacks
                ? strictSelectedPolicy.protectingRealtimeAudio()
                : strictSelectedPolicy
        }

        @MainActor
        func currentNativeCaptureVideoPolicy(
            for transportPath: WebRTCSession.ICETransportPath
        ) -> WebRTCRemoteDesktopVideoPolicy {
            let settings = RemoteDesktopSettingsManager.shared.settings.displaySettings
            let peerFormats = self.effectiveWebRTCNativeCaptureVideoFormats(for: sessionID)
            let selectedPolicy = WebRTCRemoteDesktopVideoPolicySelector.select(
                request: self.webrtcVideoRequest(
                    for: sessionID,
                    from: settings,
                    transportPath: transportPath
                ),
                transportPath: transportPath,
                peerFormats: peerFormats,
                thermalState: ProcessInfo.processInfo.thermalState,
                isAppleSilicon: Self.isAppleSiliconRuntime,
                nativeVideoTrackEnabled: true
            )
            let streamConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
            let strictSelectedPolicy = Self.policyByEnforcingStrictMediaFrameRateFloor(
                selectedPolicy,
                remoteStreamConfiguration: streamConfig
            )
            let failFastMediaFallbacks = Self.shouldFailFastRemoteMediaFallbacks(
                remoteStreamConfiguration: streamConfig
            )
            let audioRedirectionEnabled = streamConfig?.audioRedirectionEnabled == true
            let shouldUseNativeAudioTrack = Self.shouldUseWebRTCNativeAudio(
                audioRedirectionEnabled: audioRedirectionEnabled,
                remoteNativeAudioTrackEnabled: streamConfig?.nativeAudioTrackEnabled == true,
                localNativeAudioTrackReady: session.supportsNativeSystemAudioTrack
            )
            let shouldUseFallbackAudioChunks = Self.shouldUseWebRTCAudioFallback(
                audioRedirectionEnabled: audioRedirectionEnabled,
                nativeAudioTrackEnabled: shouldUseNativeAudioTrack,
                legacyAudioFallbackEnabled: streamConfig?.allowsLegacyAudioChunkFallback == true
            )
            return shouldUseFallbackAudioChunks && !failFastMediaFallbacks
                ? strictSelectedPolicy.protectingRealtimeAudio()
                : strictSelectedPolicy
        }

#if os(macOS)
        @MainActor
        func currentInteractionCaptureContext(
            for transportPath: WebRTCSession.ICETransportPath
        ) -> RemoteDesktopInteractionTelemetrySampler.CaptureContext? {
            let displayID = CGMainDisplayID()
            let displayPixelSize: CGSize = {
                guard let mode = CGDisplayCopyDisplayMode(displayID) else {
                    return .zero
                }
                return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            }()

            guard displayPixelSize.width > 0, displayPixelSize.height > 0 else {
                return nil
            }

            let videoPolicy = currentVideoPolicy(for: transportPath)
            let streamSize = videoPolicy.usesHardwareEncoder
                ? videoPolicy.preferredSize
                : displayPixelSize
            return RemoteDesktopInteractionTelemetrySampler.CaptureContext(
                displayID: displayID,
                displayPixelSize: displayPixelSize,
                streamSize: streamSize
            )
        }
#endif

        func sendRealtimeRemoteControlPayload<T: Encodable>(
            _ payload: T,
            type: RemoteMessageTypeWire,
            sessionKeys: SessionKeys,
            maxBufferedAmountBytes: Int,
            label: String
        ) async throws {
            let encodedPayload = try JSONEncoder().encode(payload)
            let message = RemoteMessageWire(type: type, payload: encodedPayload)
            let plaintext = try JSONEncoder().encode(message)
            let ciphertext = try encryptAppPayload(
                plaintext,
                with: sessionKeys,
                packetType: .remoteControl
            )
            let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: label)
            try await session.sendFramedPayloadAsync(
                padded,
                maxChunkBytes: 16 * 1024,
                maxBufferedAmountBytes: UInt64(maxBufferedAmountBytes)
            )
        }

        func startInteractionStreamingIfNeeded() {
            guard self.webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) else {
                self.appendSmokeStatus(
                    "interaction-streaming-blocked session=\(sessionID) reason=awaiting_security_notice"
                )
                return
            }
            guard self.webrtcInteractionStreamingTasksBySessionId[sessionID] == nil else { return }
            self.webrtcInteractionStreamingTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
                guard let self else { return }

#if os(macOS)
                let heartbeatTimeoutSeconds: TimeInterval = 12.0
                let overlaySampleStride = 6
                let sampler = RemoteDesktopInteractionTelemetrySampler()
                var transportPath: WebRTCSession.ICETransportPath = .unknown
                var transportPathState = StableICETransportPathState()
                var lastTransportProbeAt = Date.distantPast
                var overlayLoopIndex = 0
                var cursorChannelWasEnabled = false
                var overlayChannelWasEnabled = false

                defer {
                    self.webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID)
                }

                while !Task.isCancelled {
                    guard self.webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) else {
                        break
                    }
                    guard let lastHeartbeatAt = self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] else {
                        break
                    }
                    if Date().timeIntervalSince(lastHeartbeatAt) > heartbeatTimeoutSeconds {
                        break
                    }
                    if self.webrtcRekeyInProgressSessionIds.contains(sessionID) {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    if Date().timeIntervalSince(lastTransportProbeAt) >= 2.0 {
                        let probedPath = await session.currentICETransportPath()
                        let retainedPreviousPath = transportPathState.recordProbe(probedPath)
                        transportPath = transportPathState.effectivePath
                        if retainedPreviousPath {
                            self.logger.debug(
                                "ℹ️ WebRTC 交互通道保留上次稳定传输路径: session=\(sessionID, privacy: .public) probed=unknown effective=\(transportPath.rawValue, privacy: .public) unknownProbes=\(transportPathState.consecutiveUnknownProbes, privacy: .public)"
                            )
                        }
                        lastTransportProbeAt = Date()
                    }

                    let streamConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
                    let wantsCursorChannel = streamConfig?.separateCursorChannelEnabled ?? false
                    let wantsOverlayChannel = streamConfig?.interactionOverlayChannelEnabled ?? false

                    if !wantsCursorChannel && cursorChannelWasEnabled {
                        sampler.resetCursorState()
                        if let activeKeys = self.webrtcSessionKeysBySessionId[sessionID] {
                            try? await sendRealtimeRemoteControlPayload(
                                RemoteDesktopCursorPayload(
                                    x: 0,
                                    y: 0,
                                    width: 1,
                                    height: 1,
                                    hidden: true
                                ),
                                type: .cursorUpdate,
                                sessionKeys: activeKeys,
                                maxBufferedAmountBytes: 96 * 1024,
                                label: "tx/webrtc-cursor"
                            )
                        }
                    }

                    if !wantsOverlayChannel && overlayChannelWasEnabled {
                        sampler.resetOverlayState()
                        if let activeKeys = self.webrtcSessionKeysBySessionId[sessionID] {
                            try? await sendRealtimeRemoteControlPayload(
                                RemoteDesktopOverlayPayload(),
                                type: .overlayUpdate,
                                sessionKeys: activeKeys,
                                maxBufferedAmountBytes: 96 * 1024,
                                label: "tx/webrtc-overlay"
                            )
                        }
                    }

                    cursorChannelWasEnabled = wantsCursorChannel
                    overlayChannelWasEnabled = wantsOverlayChannel

                    guard wantsCursorChannel || wantsOverlayChannel else {
                        try? await Task.sleep(for: .milliseconds(250))
                        continue
                    }

                    guard self.webrtcInteractionStreamingAllowedSessionIds.contains(sessionID) else {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }

                    guard let activeKeys = self.webrtcSessionKeysBySessionId[sessionID],
                          let captureContext = currentInteractionCaptureContext(for: transportPath) else {
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }

                    let bufferedAmount = session.dataChannelBufferedAmountBytes()
                    if bufferedAmount > 512 * 1024 {
                        try? await Task.sleep(for: .milliseconds(16))
                        continue
                    }

                    if wantsCursorChannel,
                       let cursorPayload = sampler.sampleCursor(context: captureContext) {
                        do {
                            try await sendRealtimeRemoteControlPayload(
                                cursorPayload,
                                type: .cursorUpdate,
                                sessionKeys: activeKeys,
                                maxBufferedAmountBytes: 128 * 1024,
                                label: "tx/webrtc-cursor"
                            )
                        } catch {
                            self.logger.debug(
                                "ℹ️ WebRTC cursorUpdate 发送失败: session=\(sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }

                    overlayLoopIndex = (overlayLoopIndex + 1) % overlaySampleStride
                    if wantsOverlayChannel,
                       overlayLoopIndex == 0,
                       let overlayPayload = sampler.sampleOverlay(context: captureContext) {
                        do {
                            try await sendRealtimeRemoteControlPayload(
                                overlayPayload,
                                type: .overlayUpdate,
                                sessionKeys: activeKeys,
                                maxBufferedAmountBytes: 128 * 1024,
                                label: "tx/webrtc-overlay"
                            )
                        } catch {
                            self.logger.debug(
                                "ℹ️ WebRTC overlayUpdate 发送失败: session=\(sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }

                    try? await Task.sleep(for: .milliseconds(16))
                }
#else
                self.webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID)
#endif
            }
        }

        func startScreenStreamingIfNeeded(keys: SessionKeys) {
            guard RemoteDesktopSettingsManager.shared.settings.networkSettings.enableUDPTransport else {
                self.webrtcAwaitingStreamConfigurationSessionIds.remove(sessionID)
                self.webrtcInteractionStreamingAllowedSessionIds.remove(sessionID)
                self.logger.warning(
                    "⛔️ WebRTC 远程桌面推流被设置阻止: session=\(sessionID, privacy: .public) reason=udp_transport_disabled"
                )
                self.appendSmokeStatus(
                    "stream-deferred session=\(sessionID) reason=udp_transport_disabled_by_settings"
                )
                self.appendWebRTCSessionDiagnostic(
                    "stream-deferred session=\(sessionID) reason=udp_transport_disabled_by_settings",
                    sessionID: sessionID
                )
                return
            }
            guard self.webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID) else {
                guard !self.webrtcRemoteControlNoticePendingSessionIds.contains(sessionID) else {
                    self.appendSmokeStatus(
                        "stream-deferred session=\(sessionID) reason=security_notice_pending"
                    )
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard await self.ensureWebRTCRemoteControlSecurityApproved(
                        sessionID: sessionID,
                        session: session,
                        keys: keys
                    ) else {
                        return
                    }
                    startScreenStreamingIfNeeded(keys: keys)
                }
                self.appendSmokeStatus(
                    "stream-deferred session=\(sessionID) reason=await_security_notice"
                )
                return
            }
            if self.webrtcSessionReadyDiagnosticSessionIds.insert(sessionID).inserted {
                self.appendWebRTCSessionDiagnostic(
                    "sessionReady session=\(sessionID) suite=\(keys.negotiatedSuite.rawValue)",
                    sessionID: sessionID
                )
            }
            if self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.isStopRequest == true {
                self.webrtcAwaitingStreamConfigurationSessionIds.remove(sessionID)
                self.webrtcInteractionStreamingAllowedSessionIds.remove(sessionID)
                self.logger.info(
                    "⏸️ WebRTC 推流保持停止状态: session=\(sessionID, privacy: .public)"
                )
                return
            }
            guard Self.shouldStartWebRTCScreenStreaming(
                remoteStreamConfiguration: self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
            ) else {
                if self.webrtcAwaitingStreamConfigurationSessionIds.insert(sessionID).inserted {
                    self.logger.info(
                        "ℹ️ WebRTC 推流等待 viewer 流配置: session=\(sessionID, privacy: .public)"
                    )
                    self.appendSmokeStatus(
                        "stream-deferred session=\(sessionID) reason=await_stream_configuration"
                    )
                    self.appendWebRTCSessionDiagnostic(
                        "stream-deferred session=\(sessionID) reason=await_stream_configuration",
                        sessionID: sessionID
                    )
                }
                return
            }
            self.webrtcAwaitingStreamConfigurationSessionIds.remove(sessionID)
            guard self.webrtcScreenStreamingTasksBySessionId[sessionID] == nil else { return }
            self.webrtcScreenStreamingTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
                guard let self else { return }
                let heartbeatTimeoutSeconds: TimeInterval = 12.0
                let screenFrameChunkBytes = 16 * 1024
                var screenChannelWaitStartedAt: Date?
                var lastScreenChannelRouteState = ""
                var bytesSent: Int = 0
                var framesSent: Int = 0
                var framesDroppedBackpressure: Int = 0
                var fallbackLoopTicks: Int = 0
                var directEncodedFramesTaken: Int = 0
                var sckLatestFallbackFrames: Int = 0
                var sckLatestAgeMsTotal: Int = 0
                var cgDisplayFallbackFrames: Int = 0
                var cgDisplayCaptureMsTotal: Int = 0
                var jpegEncodeMsTotal: Int = 0
                var lastSendLatencyMs: Int = 0
                var logWindowStart = Date()
                var usingSyntheticFrames = false
                var transportPath: WebRTCSession.ICETransportPath = .unknown
                var transportPathState = StableICETransportPathState()
                var lastTransportProbeAt = Date.distantPast
                var lastBudget: WebRTCRemoteDesktopStreamBudget?
                var lastEncoderVideoPolicy: WebRTCRemoteDesktopVideoPolicy?
                var lastFallbackSendVideoPolicy: WebRTCRemoteDesktopVideoPolicy?
                var lastNativeAudioTrackEnabled: Bool?
                var lastPreferredAudioEncoding: RemoteDesktopAudioChunkPayload.Encoding?
                var lastAudioRedirectionEnabled: Bool?
                var lastFailFastMediaFallbacks: Bool?
                var lastRealtimeAudioEndpointStableKey: WebRTCRealtimeAudioEndpointStableKey?
                var lastSentFormat = ""
                var lastBackpressureReportAt = Date.distantPast
                var lastScreenChannelWaitReportAt = Date.distantPast
                var awaitingRefreshToken: UInt64?
                var awaitingRefreshRequestedAt: Date?
                var predictiveFramesSentAfterRefresh = 0
                var lastAwaitingRefreshReportAt = Date.distantPast
                var lastNativeVideoStatsReportAt = Date.distantPast
                let encodedFrameStore = LatestWebRTCEncodedFrameStore()
                let fallbackFrameSequence = RemoteControlFrameSequenceGenerator()
                var activeFallbackProducer = "initial"
                var fallbackProducerSwitchReason = "initial"
                var lastFallbackSignature = "-"
                var nativeVideoFallbackDrivingMain = false
                var lastNativeVideoRetryDiagnosticAt = Date.distantPast
                var nativeWarmupNonJPEGFallbackDrops = 0
                var lastNativeWarmupNonJPEGFallbackDropReportAt = Date.distantPast
                var strictMediaValidationFailureReason: String?
#if os(macOS)
                var directCaptureStreamer: ScreenCaptureKitStreamer?
                var directAudioFallbackSender: WebRTCAudioFallbackSender?
                var directRealtimeAudioSender: RemoteRealtimeMediaAudioSender?
                var directRealtimeAudioSenderRelayEndpoint: SkyBridgeMediaEndpoint?
                var directRealtimeAudioSenderRelayExpiresAt: TimeInterval?
                var directRealtimeAudioContinuityState: RemoteRealtimeMediaAudioSender.ContinuityState?
                var directRealtimeAudioAttachTask: Task<Void, Never>?
                var directRealtimeAudioAttachGeneration: UInt64 = 0
                var directRealtimeAudioRetryAfter = Date.distantPast
                var directRealtimeAudioStrictFirstAttachFailureAt: Date?
                var directRealtimeAudioRenewalRetryAfter = Date.distantPast
                var directRealtimePCMSubmissionPipe: RemoteRealtimePCM16SubmissionPipe?
                var directSyntheticAudioToneSource: RemoteRealtimeSyntheticPCM16ToneSource?
                var directSyntheticNativeVideoTask: Task<Void, Never>?
                var directNativeFramePacingTask: Task<Void, Never>?
                var directSyntheticNativeVideoSignature = ""
                var directSyntheticNativeVideoStartedAt = Date.distantPast
                var lastHardwareFrameAt = Date.distantPast
                var lastDirectEncoderStartAt = Date.distantPast
                var lastEncodedFallbackMissReportAt = Date.distantPast
                var nativeVideoHealthState: NativeVideoHealthState = .negotiated
                var nativeVideoFailureCooldownUntil = Date.distantPast
                var nativeVideoFailureStrikeCount = 0
                var nativeVideoSenderRefreshAttempted = false
                let damageTracker = CoarseDisplayDamageTracker()
                var pendingDamageReport: RemoteDesktopDamageReport?
#endif

                defer {
#if os(macOS)
                    Task { @MainActor in
                        directCaptureStreamer?.stop()
                        await directAudioFallbackSender?.close()
                        directSyntheticAudioToneSource?.stop()
                        directSyntheticNativeVideoTask?.cancel()
                        directNativeFramePacingTask?.cancel()
                        directSyntheticNativeVideoStartedAt = .distantPast
                        directRealtimeAudioAttachTask?.cancel()
                        directRealtimePCMSubmissionPipe?.close()
                        await directRealtimeAudioSender?.close(reason: "webrtc-session-ended")
                    }
#endif
                    encodedFrameStore.clear()
                    self.webrtcInteractionStreamingAllowedSessionIds.remove(sessionID)
                    self.webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID)
                }

                @MainActor
                func recordStrictMediaValidationFailure(
                    reason: String,
                    probable: String,
                    config: RemoteDesktopStreamConfiguration? = nil
                ) {
                    guard strictMediaValidationFailureReason == nil else { return }
                    let effectiveConfig: RemoteDesktopStreamConfiguration?
                    if let config {
                        effectiveConfig = config
                    } else {
                        effectiveConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
                    }
                    let mode = effectiveConfig?.normalizedPerformanceValidationMode ?? "strict"
                    strictMediaValidationFailureReason = reason
                    self.logger.error(
                        "⛔️ WebRTC strict media validation failed: session=\(sessionID, privacy: .public) mode=\(mode, privacy: .public) reason=\(reason, privacy: .public) probable=\(probable, privacy: .public)"
                    )
                    self.appendSmokeStatus(
                        "strict-media-failed session=\(sessionID) mode=\(mode) reason=\(reason) probable=\(probable)"
                    )
                    self.appendWebRTCSessionDiagnostic(
                        "strict-media-failed session=\(sessionID) mode=\(mode) reason=\(reason) probable=\(probable)",
                        sessionID: sessionID
                    )
                    WebRTCMediaDiagnosticWriter.append(
                        WebRTCMediaDiagnosticEvent(
                            sessionId: sessionID,
                            kind: "strictMediaFailure",
                            probable: probable,
                            validationMode: mode,
                            failureReason: reason
                        )
                    )
                    self.cleanupWebRTCSession(
                        sessionID,
                        reason: "strict_media_validation_failed_\(reason)",
                        disconnectKind: .explicit
                    )
                    self.connectionStatus = .failed("WebRTC strict media validation failed: \(reason)")
                    self.readiness = .idle
                }

                @MainActor
                func currentBudget(
                    for transportPath: WebRTCSession.ICETransportPath,
                    videoPolicy: WebRTCRemoteDesktopVideoPolicy
                ) -> WebRTCRemoteDesktopStreamBudget {
                    let settings = RemoteDesktopSettingsManager.shared.settings.displaySettings
                    let networkSettings = RemoteDesktopSettingsManager.shared.settings.networkSettings
                    let streamConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
                    let strictHighFPS =
                        videoPolicy.targetFrameRate >= 59 &&
                        Self.shouldFailFastRemoteMediaFallbacks(
                            remoteStreamConfiguration: streamConfig
                        )
                    let longEdge: Int = {
                        if videoPolicy.usesHardwareEncoder {
                            return max(
                                Int(videoPolicy.preferredSize.width.rounded()),
                                Int(videoPolicy.preferredSize.height.rounded())
                            )
                        }
                        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
                            return max(mode.width, mode.height)
                        }
                        return max(
                            Int(videoPolicy.preferredSize.width.rounded()),
                            Int(videoPolicy.preferredSize.height.rounded())
                        )
                    }()
                    return WebRTCRemoteDesktopBudgetSelector.select(
                        requestedFrameRate: videoPolicy.targetFrameRate,
                        transportPath: transportPath,
                        thermalState: networkSettings.enableAdaptiveQuality
                            ? ProcessInfo.processInfo.thermalState
                            : .nominal,
                        longEdge: max(1, longEdge),
                        lowLatencyMode: settings.lowLatencyMode || strictHighFPS,
                        codec: videoPolicy.codec,
                        nativeVideoTrackEnabled: session.supportsNativeScreenVideoTrack,
                        enableHardwareAcceleration: settings.enableHardwareAcceleration,
                        enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization,
                        isAppleSilicon: Self.isAppleSiliconRuntime,
                        bandwidthLimitMbps: networkSettings.boundedBandwidthLimitMbps,
                        enableAdaptiveQuality: networkSettings.enableAdaptiveQuality,
                        maxBufferedAmountOverrideBytes: networkSettings.maxBufferedAmountOverrideBytes
                    )
                }

#if os(macOS)
                @MainActor
                func ensureDirectEncoder(
                    for videoPolicy: WebRTCRemoteDesktopVideoPolicy
                ) async -> Bool {
                    let nativeVideoTrackEnabled = session.supportsNativeScreenVideoTrack
                    let streamConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
                    let failFastMediaFallbacks = Self.shouldFailFastRemoteMediaFallbacks(
                        remoteStreamConfiguration: streamConfig
                    )
                    let realtimeAudioRelayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy =
                        failFastMediaFallbacks ? .requireAcknowledgement : .optimisticAfterSend
                    let realtimeAudioRelayRenewalMargin: TimeInterval =
                        failFastMediaFallbacks ? 30 : 10
                    let explicitStreamResolutionRequested =
                        streamConfig?.width != nil
                        && streamConfig?.height != nil
                        && (streamConfig?.adaptiveResolutionEnabled ?? false) == false
                    let preserveExactVisibleCaptureSize =
                        failFastMediaFallbacks
                        && streamConfig?.requiresExtremePerformanceValidation == true
                        && explicitStreamResolutionRequested
                    let nativeVideoTrackReady =
                        streamConfig?.nativeVideoTrackReady == true
                    let fallbackShouldDriveMain = Self.nativeVideoFallbackDecision(
                        supportsNativeVideoTrack: nativeVideoTrackEnabled,
                        nativeVideoTrackReady: nativeVideoTrackReady,
                        nativeVideoHealthState: nativeVideoHealthState,
                        cooldownRemainingSeconds: max(0, nativeVideoFailureCooldownUntil.timeIntervalSince(Date()))
                    ).fallbackShouldDriveMain
                    let nativeAudioTrackEnabled =
                        streamConfig?.nativeAudioTrackEnabled == true
                    let audioRedirectionEnabled =
                        streamConfig?.audioRedirectionEnabled == true
                    let legacyAudioFallbackEnabled =
                        streamConfig?.allowsLegacyAudioChunkFallback == true
                    let preferredAudioEncoding = RemoteDesktopAudioChunkPayload.Encoding(
                        rawValue: streamConfig?.preferredAudioEncoding ?? ""
                    ) ?? .pcmS16LE
                    let localNativeAudioTrackReady = session.supportsNativeSystemAudioTrack
                    let shouldUseNativeAudioTrack = Self.shouldUseWebRTCNativeAudio(
                        audioRedirectionEnabled: audioRedirectionEnabled,
                        remoteNativeAudioTrackEnabled: nativeAudioTrackEnabled,
                        localNativeAudioTrackReady: localNativeAudioTrackReady
                    )
                    let shouldUseFallbackAudioChunks = Self.shouldUseWebRTCAudioFallback(
                        audioRedirectionEnabled: audioRedirectionEnabled,
                        nativeAudioTrackEnabled: shouldUseNativeAudioTrack,
                        legacyAudioFallbackEnabled: legacyAudioFallbackEnabled
                    )
                    let realtimeAudioEndpoint =
                        streamConfig?.mediaAudioEndpoint
                    let realtimeAudioMode =
                        streamConfig?.requestedMediaAudioMode ?? .lowLatency
                    let realtimeAudioMediaSessionId =
                        streamConfig?.mediaSessionId ?? keys.sessionId
                    let realtimeAudioEndpointStableKey = WebRTCRealtimeAudioEndpointStableKey(
                        mediaSessionId: realtimeAudioMediaSessionId,
                        mode: realtimeAudioMode,
                        endpoint: realtimeAudioEndpoint
                    )
                    let shouldUseRealtimeAudio = audioRedirectionEnabled
                        && streamConfig?.requestsRealtimeMediaAudio == true
                        && !shouldUseNativeAudioTrack
                        && !shouldUseFallbackAudioChunks
                    let nativeVideoWarmBackupEnabled =
                        nativeVideoTrackEnabled && fallbackShouldDriveMain && !failFastMediaFallbacks
                    guard videoPolicy.usesHardwareEncoder || nativeVideoTrackEnabled else {
                        if failFastMediaFallbacks {
                            recordStrictMediaValidationFailure(
                                reason: "hardware-video-encoder-unavailable",
                                probable: "video-policy-selected-fallback-codec",
                                config: streamConfig
                            )
                        }
                        if let directCaptureStreamer {
                            directCaptureStreamer.stop()
                            self.logger.info(
                                "🛑 WebRTC ScreenCaptureKit 直连硬编停止，回退到 JPEG: session=\(sessionID, privacy: .public)"
                            )
                        }
                        directCaptureStreamer = nil
                        directNativeFramePacingTask?.cancel()
                        directNativeFramePacingTask = nil
                        encodedFrameStore.clear()
                        lastNativeAudioTrackEnabled = nil
                        lastPreferredAudioEncoding = nil
                        lastAudioRedirectionEnabled = nil
                        lastFailFastMediaFallbacks = nil
                        lastRealtimeAudioEndpointStableKey = nil
                        lastDirectEncoderStartAt = .distantPast
                        session.setOutgoingSystemAudioTrackEnabled(false)
                        await directAudioFallbackSender?.close()
                        directAudioFallbackSender = nil
                        directSyntheticAudioToneSource?.stop()
                        directSyntheticAudioToneSource = nil
                        directRealtimeAudioAttachGeneration &+= 1
                        directRealtimeAudioRetryAfter = .distantPast
                        directRealtimeAudioRenewalRetryAfter = .distantPast
                        directRealtimeAudioAttachTask?.cancel()
                        directRealtimeAudioAttachTask = nil
                        directRealtimePCMSubmissionPipe?.close()
                        directRealtimePCMSubmissionPipe = nil
                        await directRealtimeAudioSender?.close(reason: "direct-encoder-unavailable")
                        directRealtimeAudioSender = nil
                        directRealtimeAudioSenderRelayEndpoint = nil
                        directRealtimeAudioSenderRelayExpiresAt = nil
                        directRealtimeAudioContinuityState = nil
                        return false
                    }

                    let realtimeAudioSenderLeaseReusable = !shouldUseRealtimeAudio
                        || directRealtimeAudioSender == nil
                        || Self.isReusableMediaRelayEndpoint(
                            expiresAt: directRealtimeAudioSenderRelayExpiresAt,
                            minimumRemainingTime: realtimeAudioRelayRenewalMargin
                        )
                    let realtimeAudioEndpointStable =
                        lastRealtimeAudioEndpointStableKey == realtimeAudioEndpointStableKey
                    let preserveRealtimeAudioSender =
                        shouldUseRealtimeAudio
                        && directRealtimeAudioSender != nil
                        && realtimeAudioSenderLeaseReusable
                        && realtimeAudioEndpointStable
                    let diagnosticSyntheticNativeVideoEnabled =
                        ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_DIAGNOSTIC_SYNTHETIC_NATIVE_VIDEO"] == "1"
                    if !diagnosticSyntheticNativeVideoEnabled, directSyntheticNativeVideoTask != nil {
                        directSyntheticNativeVideoTask?.cancel()
                        directSyntheticNativeVideoTask = nil
                        directSyntheticNativeVideoSignature = ""
                        directSyntheticNativeVideoStartedAt = .distantPast
                    }
                    let directVideoPipelineReusable =
                        lastEncoderVideoPolicy == videoPolicy
                        && lastNativeAudioTrackEnabled == nativeAudioTrackEnabled
                        && lastPreferredAudioEncoding == preferredAudioEncoding
                        && lastAudioRedirectionEnabled == audioRedirectionEnabled
                        && lastFailFastMediaFallbacks == failFastMediaFallbacks
                        && (directCaptureStreamer == nil
                            || !(nativeVideoTrackEnabled && failFastMediaFallbacks && videoPolicy.targetFrameRate >= 59)
                            || directNativeFramePacingTask != nil)
                        && (directCaptureStreamer != nil
                            || (diagnosticSyntheticNativeVideoEnabled && directSyntheticNativeVideoTask != nil))
                    if directVideoPipelineReusable {
                        let realtimeAudioSenderNeedsRenewal =
                            shouldUseRealtimeAudio
                            && (!realtimeAudioSenderLeaseReusable || !realtimeAudioEndpointStable)
                        if realtimeAudioSenderNeedsRenewal,
                           directRealtimeAudioSender != nil,
                           !realtimeAudioSenderLeaseReusable,
                           realtimeAudioEndpointStable,
                           Date() < directRealtimeAudioRenewalRetryAfter {
                            scheduleRealtimeAudioAttachIfNeeded()
                            lastRealtimeAudioEndpointStableKey = realtimeAudioEndpointStableKey
                            return true
                        }
                        if realtimeAudioSenderNeedsRenewal,
                           let senderToRenew = directRealtimeAudioSender,
                           directRealtimeAudioAttachTask == nil {
                            if !realtimeAudioSenderLeaseReusable,
                               realtimeAudioEndpointStable {
                                do {
                                    let refreshedEndpoint = try await self.requestWebRTCRealtimeAudioSenderEndpoint(sessionID: sessionID)
                                    if Self.isSameMediaRelaySocket(directRealtimeAudioSenderRelayEndpoint, refreshedEndpoint),
                                       let relayToken = refreshedEndpoint.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !relayToken.isEmpty {
                                        let renewalBindPolicy = realtimeAudioRelayBindPolicy
                                        try await senderToRenew.rebindRelayToken(
                                            relayToken,
                                            relayBindPolicy: renewalBindPolicy
                                        )
                                        directRealtimeAudioSenderRelayEndpoint = refreshedEndpoint
                                        directRealtimeAudioSenderRelayExpiresAt = refreshedEndpoint.expiresAt
                                        directRealtimeAudioRenewalRetryAfter = .distantPast
                                        self.appendWebRTCSessionDiagnostic(
                                            "audioTxSenderRenewed session=\(sessionID) leaseSource=localRoleLease reason=relay-lease-expiring mode=in-place bindPolicy=\(renewalBindPolicy == .requireAcknowledgement ? "require-ack" : "optimistic") endpoint=\(refreshedEndpoint.host):\(refreshedEndpoint.port)",
                                            sessionID: sessionID
                                        )
                                        WebRTCMediaDiagnosticWriter.append(
                                            WebRTCMediaDiagnosticEvent(
                                                sessionId: sessionID,
                                                kind: "audioTxEndpointRenewed",
                                                probable: renewalBindPolicy == .requireAcknowledgement
                                                    ? "relay-lease-renewed-in-place-acknowledged"
                                                    : "relay-lease-renewed-in-place"
                                            )
                                        )
                                        scheduleRealtimeAudioAttachIfNeeded()
                                        lastRealtimeAudioEndpointStableKey = realtimeAudioEndpointStableKey
                                        return true
                                    }
                                } catch {
                                    let relayLeaseRemaining = (directRealtimeAudioSenderRelayExpiresAt ?? 0)
                                        - Date().timeIntervalSince1970
                                    self.appendWebRTCSessionDiagnostic(
                                        "audioTxSenderRenewalFallback session=\(sessionID) leaseSource=localRoleLease reason=relay-lease-expiring stage=in-place remainingMs=\(Int((relayLeaseRemaining * 1000).rounded())) error=\(sanitizeStatus(error.localizedDescription))",
                                        sessionID: sessionID
                                    )
                                    if relayLeaseRemaining > 5 {
                                        directRealtimeAudioRenewalRetryAfter = Date().addingTimeInterval(1.0)
                                        scheduleRealtimeAudioAttachIfNeeded()
                                        lastRealtimeAudioEndpointStableKey = realtimeAudioEndpointStableKey
                                        return true
                                    }
                                }
                            }
                            directRealtimeAudioContinuityState = await senderToRenew.continuityState()
                            let renewalReason = realtimeAudioEndpointStable
                                ? "relay-lease-expiring"
                                : "viewer-endpoint-renewed"
                            self.appendWebRTCSessionDiagnostic(
                                "audioTxSenderRenewing session=\(sessionID) leaseSource=localRoleLease reason=\(renewalReason) nextSeq=\(directRealtimeAudioContinuityState.map { String($0.nextSequence) } ?? "-")",
                                sessionID: sessionID
                            )
                            directSyntheticAudioToneSource?.stop()
                            directSyntheticAudioToneSource = nil
                            directRealtimeAudioAttachGeneration &+= 1
                            directRealtimeAudioRetryAfter = .distantPast
                            directRealtimePCMSubmissionPipe?.detachSender()
                            await senderToRenew.close(reason: "relay-lease-renewal")
                            directRealtimeAudioSender = nil
                            directRealtimeAudioSenderRelayEndpoint = nil
                            directRealtimeAudioSenderRelayExpiresAt = nil
                        }
                        if realtimeAudioSenderNeedsRenewal,
                           directRealtimeAudioSender == nil,
                           directRealtimeAudioAttachTask != nil,
                           !realtimeAudioEndpointStable {
                            directRealtimeAudioAttachGeneration &+= 1
                            directRealtimeAudioAttachTask?.cancel()
                            directRealtimeAudioAttachTask = nil
                            directRealtimeAudioRetryAfter = .distantPast
                        }
                        scheduleRealtimeAudioAttachIfNeeded()
                        lastRealtimeAudioEndpointStableKey = realtimeAudioEndpointStableKey
                        return true
                    }

                    directCaptureStreamer?.stop()
                    directCaptureStreamer = nil
                    directNativeFramePacingTask?.cancel()
                    directNativeFramePacingTask = nil
                    await directAudioFallbackSender?.close()
                    directAudioFallbackSender = nil
                    if !preserveRealtimeAudioSender {
                        if shouldUseRealtimeAudio, let directRealtimeAudioSender {
                            directRealtimeAudioContinuityState = await directRealtimeAudioSender.continuityState()
                            self.appendWebRTCSessionDiagnostic(
                                "audioTxSenderRenewing session=\(sessionID) leaseSource=localRoleLease reason=\(realtimeAudioSenderLeaseReusable ? "stream-restart" : "relay-lease-expiring") nextSeq=\(directRealtimeAudioContinuityState.map { String($0.nextSequence) } ?? "-")",
                                sessionID: sessionID
                            )
                        } else {
                            directRealtimeAudioContinuityState = nil
                        }
                        directSyntheticAudioToneSource?.stop()
                        directSyntheticAudioToneSource = nil
                        directRealtimeAudioAttachGeneration &+= 1
                        directRealtimeAudioRetryAfter = .distantPast
                        directRealtimeAudioRenewalRetryAfter = .distantPast
                        directRealtimeAudioAttachTask?.cancel()
                        directRealtimeAudioAttachTask = nil
                        directRealtimePCMSubmissionPipe?.close()
                        directRealtimePCMSubmissionPipe = nil
                        await directRealtimeAudioSender?.close(reason: realtimeAudioSenderLeaseReusable ? "video-restart" : "relay-lease-expiring")
                        directRealtimeAudioSender = nil
                        directRealtimeAudioSenderRelayEndpoint = nil
                        directRealtimeAudioSenderRelayExpiresAt = nil
                    } else {
                        self.appendWebRTCSessionDiagnostic(
                            "audioTxSenderPreserved session=\(sessionID) leaseSource=localRoleLease reason=video-restart endpoint=\(realtimeAudioEndpoint?.host ?? "-"):\(realtimeAudioEndpoint.map { String($0.port) } ?? "-")",
                            sessionID: sessionID
                        )
                    }
                    encodedFrameStore.clear()
                    lastNativeAudioTrackEnabled = nativeAudioTrackEnabled
                    lastPreferredAudioEncoding = preferredAudioEncoding
                    lastAudioRedirectionEnabled = audioRedirectionEnabled
                    lastFailFastMediaFallbacks = failFastMediaFallbacks
                    lastRealtimeAudioEndpointStableKey = realtimeAudioEndpointStableKey
                    lastDirectEncoderStartAt = .distantPast
                    session.setOutgoingSystemAudioTrackEnabled(shouldUseNativeAudioTrack)
                    func storeEncodedFrame(
                        _ data: Data,
                        width: Int,
                        height: Int,
                        frameType: RemoteFrameType,
                        isSyncFrame: Bool
                    ) {
                        encodedFrameStore.store(
                            .init(
                                width: width,
                                height: height,
                                imageData: data,
                                timestamp: Date().timeIntervalSince1970,
                                format: Self.remoteFrameFormatName(frameType: frameType, payload: data),
                                isSyncFrame: isSyncFrame,
                                sequenceNumber: fallbackFrameSequence.next()
                            )
                        )
                    }

                    let captureStreamer = ScreenCaptureKitStreamer()
                    let captureFPS = videoPolicy.targetFrameRate
                    let audioControlBufferedAmountBytes = 96 * 1024
                    @MainActor
                    func startDiagnosticSyntheticNativeVideoIfRequested() -> Bool {
                        guard diagnosticSyntheticNativeVideoEnabled,
                              nativeVideoTrackEnabled else {
                            return false
                        }
                        if shouldUseNativeAudioTrack || shouldUseFallbackAudioChunks || shouldUseRealtimeAudio {
                            recordStrictMediaValidationFailure(
                                reason: "diagnostic-synthetic-native-video-with-audio-forbidden",
                                probable: "synthetic-native-video-is-video-only",
                                config: streamConfig
                            )
                            return false
                        }
                        let requestedSyntheticSize = ProcessInfo.processInfo
                            .environment["SKYBRIDGE_WEBRTC_DIAGNOSTIC_SYNTHETIC_NATIVE_VIDEO_SIZE"]?
                            .split(separator: "x", maxSplits: 1)
                        let requestedSyntheticWidth = requestedSyntheticSize?.first
                            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        let requestedSyntheticHeight = requestedSyntheticSize?.dropFirst().first
                            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        let targetWidth = max(
                            2,
                            requestedSyntheticWidth ?? Int(videoPolicy.preferredSize.width.rounded(.down))
                        )
                        let targetHeight = max(
                            2,
                            requestedSyntheticHeight ?? Int(videoPolicy.preferredSize.height.rounded(.down))
                        )
                        let evenWidth = targetWidth - (targetWidth % 2)
                        let evenHeight = targetHeight - (targetHeight % 2)
                        let clampedFPS = max(1, captureFPS)
                        let signature = "\(evenWidth)x\(evenHeight)@\(clampedFPS)"
                        if directSyntheticNativeVideoSignature != signature {
                            directSyntheticNativeVideoTask?.cancel()
                            directSyntheticNativeVideoTask = nil
                            directSyntheticNativeVideoSignature = signature
                        }
                        if directSyntheticNativeVideoTask == nil {
                            directCaptureStreamer?.stop()
                            directCaptureStreamer = nil
                            directNativeFramePacingTask?.cancel()
                            directNativeFramePacingTask = nil
                            encodedFrameStore.clear()
                            lastNativeAudioTrackEnabled = nil
                            lastPreferredAudioEncoding = nil
                            lastAudioRedirectionEnabled = nil
                            lastFailFastMediaFallbacks = nil
                            lastRealtimeAudioEndpointStableKey = nil
                            session.setOutgoingSystemAudioTrackEnabled(false)
                            session.prepareOutgoingScreenVideo(
                                width: evenWidth,
                                height: evenHeight,
                                fps: clampedFPS,
                                disallowQualityDegradation: true
                            )
                            directSyntheticNativeVideoTask = Task.detached(priority: .userInitiated) { [sessionID, session] in
                                var frameIndex: UInt64 = 0
                                let sleepNanoseconds = UInt64(
                                    max(1, 1_000_000_000 / clampedFPS)
                                )
                                while !Task.isCancelled {
                                    do {
                                        try session.pushDiagnosticSyntheticNativeVideoFrame(
                                            width: evenWidth,
                                            height: evenHeight,
                                            fps: clampedFPS,
                                            frameIndex: frameIndex
                                        )
                                    } catch {
                                        let renderedError = error.localizedDescription
                                            .replacingOccurrences(of: "\n", with: " ")
                                            .replacingOccurrences(of: "\r", with: " ")
                                        Self.writeWebRTCSessionDiagnostic(
                                            "native-video-diagnostic-synthetic-frame-error session=\(sessionID) error=\(renderedError)",
                                            sessionID: sessionID
                                        )
                                        return
                                    }
                                    frameIndex &+= 1
                                    try? await Task.sleep(nanoseconds: sleepNanoseconds)
                                }
                            }
                            self.appendSmokeStatus(
                                "stream-diagnostic-synthetic-native-video-started session=\(sessionID) size=\(evenWidth)x\(evenHeight) fps=\(clampedFPS)"
                            )
                            self.appendWebRTCSessionDiagnostic(
                                "stream-diagnostic-synthetic-native-video-started session=\(sessionID) size=\(evenWidth)x\(evenHeight) fps=\(clampedFPS)",
                                sessionID: sessionID
                            )
                            directSyntheticNativeVideoStartedAt = Date()
                            lastDirectEncoderStartAt = directSyntheticNativeVideoStartedAt
                        }
                        return true
                    }
                    func scheduleRealtimeAudioAttachIfNeeded() {
                        if shouldUseRealtimeAudio, directRealtimePCMSubmissionPipe == nil {
                            directRealtimePCMSubmissionPipe = RemoteRealtimePCM16SubmissionPipe(
                                replayBufferedOnAttach: false
                            )
                            self.appendWebRTCSessionDiagnostic(
                                "audioTxCapturePipeReady session=\(sessionID) leaseSource=localRoleLease state=pending-attach",
                                sessionID: sessionID
                            )
                        }
                        guard shouldUseRealtimeAudio,
                              directRealtimeAudioSender == nil,
                              directRealtimeAudioAttachTask == nil,
                              Date() >= directRealtimeAudioRetryAfter,
                              let realtimePCMSubmissionPipe = directRealtimePCMSubmissionPipe else {
                            return
                        }
                        let configSnapshot = streamConfig
                        directRealtimeAudioAttachGeneration &+= 1
                        let attachGeneration = directRealtimeAudioAttachGeneration
                        directRealtimeAudioAttachTask = Task(priority: .utility) { @MainActor [weak self] in
                            guard let self else { return }
                            self.appendWebRTCSessionDiagnostic(
                                "audioTxAttachStart session=\(sessionID) leaseSource=localRoleLease state=background",
                                sessionID: sessionID
                            )
                            guard let realtimeSender = await self.makeWebRTCRealtimeAudioSenderIfNeeded(
                                sessionID: sessionID,
                                keys: keys,
                                config: configSnapshot,
                                relayBindPolicy: realtimeAudioRelayBindPolicy,
                                continuityState: directRealtimeAudioContinuityState
                            ) else {
                                let snapshot = realtimePCMSubmissionPipe.snapshot()
                                self.appendWebRTCSessionDiagnostic(
                                    "audioTxAttachFailed session=\(sessionID) leaseSource=localRoleLease pendingBeforeAttach=\(snapshot.pendingBeforeAttach) submittedBeforeAttach=\(snapshot.submittedBeforeAttach) droppedBeforeAttach=\(snapshot.droppedBeforeAttach)",
                                    sessionID: sessionID
                                )
                                if failFastMediaFallbacks {
                                    let now = Date()
                                    let firstFailureAt = directRealtimeAudioStrictFirstAttachFailureAt ?? now
                                    directRealtimeAudioStrictFirstAttachFailureAt = firstFailureAt
                                    let retryWindow = Self.strictRealtimeAudioAttachRetryWindowSeconds()
                                    let elapsed = now.timeIntervalSince(firstFailureAt)
                                    if elapsed < retryWindow {
                                        directRealtimeAudioRetryAfter = now.addingTimeInterval(1.0)
                                        self.appendWebRTCSessionDiagnostic(
                                            "audioTxAttachRetryScheduled session=\(sessionID) leaseSource=localRoleLease reason=main-path-transient elapsedMs=\(Int((elapsed * 1000).rounded())) retryWindowMs=\(Int((retryWindow * 1000).rounded())) retryAfterMs=1000",
                                            sessionID: sessionID
                                        )
                                        if directRealtimeAudioAttachGeneration == attachGeneration {
                                            directRealtimeAudioAttachTask = nil
                                        }
                                        return
                                    }
                                    recordStrictMediaValidationFailure(
                                        reason: "realtime-audio-main-path-unavailable",
                                        probable: "pqc-media-audio-sender-unavailable",
                                        config: configSnapshot
                                    )
                                    if directRealtimeAudioAttachGeneration == attachGeneration {
                                        directRealtimeAudioAttachTask = nil
                                    }
                                    return
                                }
                                if directRealtimeAudioAttachGeneration == attachGeneration {
                                    directRealtimeAudioRetryAfter = Date().addingTimeInterval(1.0)
                                    directRealtimeAudioAttachTask = nil
                                }
                                return
                            }
                            guard !Task.isCancelled,
                                  directRealtimeAudioAttachGeneration == attachGeneration else {
                                await realtimeSender.sender.close(reason: "stale-audio-attach-generation")
                                return
                            }
                            directRealtimeAudioSender = realtimeSender.sender
                            directRealtimeAudioSenderRelayEndpoint = realtimeSender.endpoint
                            directRealtimeAudioSenderRelayExpiresAt = realtimeSender.endpoint.expiresAt
                            directRealtimeAudioContinuityState = nil
                            directRealtimeAudioStrictFirstAttachFailureAt = nil
                            directRealtimeAudioRetryAfter = .distantPast
                            realtimePCMSubmissionPipe.attach(sender: realtimeSender.sender)
                            let snapshot = realtimePCMSubmissionPipe.snapshot()
                            self.appendWebRTCSessionDiagnostic(
                                "audioTxAttachComplete session=\(sessionID) leaseSource=localRoleLease pendingBeforeAttach=\(snapshot.pendingBeforeAttach) submittedBeforeAttach=\(snapshot.submittedBeforeAttach) droppedBeforeAttach=\(snapshot.droppedBeforeAttach)",
                                sessionID: sessionID
                            )
                            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE"] == "1" {
                                if failFastMediaFallbacks {
                                    realtimePCMSubmissionPipe.close()
                                    await realtimeSender.sender.close(reason: "synthetic-audio-forbidden")
                                    directRealtimeAudioSender = nil
                                    directRealtimeAudioSenderRelayEndpoint = nil
                                    directRealtimeAudioSenderRelayExpiresAt = nil
                                    directRealtimeAudioContinuityState = nil
                                    if directRealtimeAudioAttachGeneration == attachGeneration {
                                        directRealtimeAudioAttachTask = nil
                                    }
                                    recordStrictMediaValidationFailure(
                                        reason: "synthetic-audio-forbidden",
                                        probable: "smoke-synthetic-opus-tone-enabled",
                                        config: configSnapshot
                                    )
                                    return
                                }
                                directSyntheticAudioToneSource = RemoteRealtimeSyntheticPCM16ToneSource(
                                    sender: realtimeSender.sender,
                                    mode: realtimeAudioMode
                                )
                                self.appendWebRTCSessionDiagnostic(
                                    "audioSyntheticToneStart session=\(sessionID) mode=\(realtimeAudioMode.rawValue)",
                                    sessionID: sessionID
                                )
                                WebRTCMediaDiagnosticWriter.append(
                                    WebRTCMediaDiagnosticEvent(
                                        sessionId: sessionID,
                                        kind: "audioSyntheticToneStart",
                                        probable: "smoke-tone-injected"
                                    )
                                )
                            }
                            if directRealtimeAudioAttachGeneration == attachGeneration {
                                directRealtimeAudioAttachTask = nil
                            }
                        }
                    }
                    if startDiagnosticSyntheticNativeVideoIfRequested() {
                        return true
                    }
                    if shouldUseFallbackAudioChunks {
                        if failFastMediaFallbacks {
                            recordStrictMediaValidationFailure(
                                reason: "legacy-audio-fallback-forbidden",
                                probable: "audio-fallback-requested-under-strict-media",
                                config: streamConfig
                            )
                            return false
                        }
                        directAudioFallbackSender = WebRTCAudioFallbackSender(
                            sessionID: sessionID,
                            session: session,
                            maxBufferedAmountBytes: UInt64(audioControlBufferedAmountBytes),
                            securePayloadSealer: { [weak self] plaintext in
                                guard let self else { throw CancellationError() }
                                return try await MainActor.run {
                                    try self.sealWebRTCSecurePayload(
                                        plaintext,
                                        with: keys,
                                        sessionID: sessionID,
                                        packetType: .remoteDesktopAudio
                                    )
                                }
                            }
                        )
                    }
                    scheduleRealtimeAudioAttachIfNeeded()
                    if nativeVideoTrackEnabled {
                        let strictNativeFramePacingEnabled = captureFPS >= 30 && failFastMediaFallbacks
                        let nativeFrameIntervalNs = Int64(max(1, 1_000_000_000 / max(1, captureFPS)))
                        let maximumPacedFramesPerRawFrame = 4
                        let nativeFramePacingState = strictNativeFramePacingEnabled
                            ? NativeWebRTCFramePacingState(
                                frameIntervalNs: nativeFrameIntervalNs,
                                maxFramesPerRawFrame: maximumPacedFramesPerRawFrame
                            )
                            : nil
                        func submitNativeFrame(
                            pixelBuffer: CVPixelBuffer,
                            rawTimestampNs: Int64,
                            timestampNs: Int64
                        ) {
                            let width = CVPixelBufferGetWidth(pixelBuffer)
                            let height = CVPixelBufferGetHeight(pixelBuffer)
                            session.prepareOutgoingScreenVideo(
                                width: width,
                                height: height,
                                fps: captureFPS,
                                disallowQualityDegradation: failFastMediaFallbacks
                            )
                            session.pushVideoFrame(
                                pixelBuffer: pixelBuffer,
                                rawTimeStampNs: rawTimestampNs,
                                timeStampNs: timestampNs
                            )
                        }
                        if let nativeFramePacingState {
                            directNativeFramePacingTask?.cancel()
                            directNativeFramePacingTask = Task.detached(priority: .userInitiated) {
                                [sessionID, session, captureFPS, failFastMediaFallbacks, nativeFrameIntervalNs, nativeFramePacingState] in
                                let frameIntervalNanoseconds = UInt64(max(1, nativeFrameIntervalNs))
                                var nextDeadline = DispatchTime.now().uptimeNanoseconds &+ frameIntervalNanoseconds
                                while !Task.isCancelled {
                                    let now = DispatchTime.now().uptimeNanoseconds
                                    if nextDeadline > now {
                                        try? await Task.sleep(nanoseconds: nextDeadline - now)
                                    } else if now - nextDeadline > frameIntervalNanoseconds * 2 {
                                        nextDeadline = now
                                    }
                                    nextDeadline = nextDeadline &+ frameIntervalNanoseconds
                                    guard !Task.isCancelled,
                                          let pacedFrame = nativeFramePacingState.nextTimerFrame() else {
                                        continue
                                    }
                                    let width = CVPixelBufferGetWidth(pacedFrame.pixelBuffer)
                                    let height = CVPixelBufferGetHeight(pacedFrame.pixelBuffer)
                                    session.prepareOutgoingScreenVideo(
                                        width: width,
                                        height: height,
                                        fps: captureFPS,
                                        disallowQualityDegradation: failFastMediaFallbacks
                                    )
                                    session.pushVideoFrame(
                                        pixelBuffer: pacedFrame.pixelBuffer,
                                        rawTimeStampNs: pacedFrame.rawTimestampNs,
                                        timeStampNs: pacedFrame.timestampNs
                                    )
                                    if pacedFrame.shouldLog {
                                        Self.writeWebRTCSessionDiagnostic(
                                            "native-video-last-frame-repeat session=\(sessionID) targetFPS=\(captureFPS) repeatedFrames=\(pacedFrame.timerPacedFrames) lastRawAgeMs=\(pacedFrame.lastRawAgeMs) intervalNs=\(nativeFrameIntervalNs)",
                                            sessionID: sessionID
                                        )
                                    }
                                }
                            }
                        } else {
                            directNativeFramePacingTask?.cancel()
                            directNativeFramePacingTask = nil
                        }
                        captureStreamer.onRawFrame = { pixelBuffer, presentationTimeStamp in
                            let rawTimestampNs: Int64
                            if presentationTimeStamp.isValid,
                               presentationTimeStamp.seconds.isFinite {
                                rawTimestampNs = Int64(
                                    max(
                                        0,
                                        (presentationTimeStamp.seconds * 1_000_000_000.0).rounded()
                                    )
                                )
                            } else {
                                rawTimestampNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000.0)
                            }

                            guard let nativeFramePacingState else {
                                submitNativeFrame(
                                    pixelBuffer: pixelBuffer,
                                    rawTimestampNs: rawTimestampNs,
                                    timestampNs: rawTimestampNs
                                )
                                return
                            }

                            let framePlan = nativeFramePacingState.planForRawFrame(
                                pixelBuffer: pixelBuffer,
                                rawTimestampNs: rawTimestampNs
                            )
                            for timestampNs in framePlan.timestampsNs {
                                submitNativeFrame(
                                    pixelBuffer: pixelBuffer,
                                    rawTimestampNs: rawTimestampNs,
                                    timestampNs: timestampNs
                                )
                            }
                            if framePlan.shouldLogBurst {
                                Self.writeWebRTCSessionDiagnostic(
                                    "native-video-frame-pacing session=\(sessionID) targetFPS=\(captureFPS) rawDeltaNs=\(framePlan.rawDeltaNs) submittedFrames=\(framePlan.submittedFrames) duplicateFrames=\(framePlan.duplicateFrames) intervalNs=\(nativeFrameIntervalNs)",
                                    sessionID: sessionID
                                )
                            }
                        }
                        // Native warmup owns ScreenCaptureKit for raw RTP only.
                        // Fallback main is a separate, bounded JPEG path
                        // so the viewer never sees HEVC/JPEG topology flapping.
                        captureStreamer.onEncodedFrame = nil
                    } else {
                        directNativeFramePacingTask?.cancel()
                        directNativeFramePacingTask = nil
                        captureStreamer.onEncodedFrame = { data, width, height, frameType, isSyncFrame in
                            storeEncodedFrame(
                                data,
                                width: width,
                                height: height,
                                frameType: frameType,
                                isSyncFrame: isSyncFrame
                            )
                        }
                    }
                    if shouldUseNativeAudioTrack {
                        captureStreamer.onCapturedPCM16AudioChunk = { chunk in
                            SBWebRTCSystemAudioDevice.shared().pushRecordedPCM16InterleavedData(
                                chunk.data,
                                sampleRate: chunk.sampleRate,
                                channelCount: chunk.channelCount,
                                frameCount: chunk.frameCount
                            )
                        }
                    } else if shouldUseRealtimeAudio, let realtimePCMSubmissionPipe = directRealtimePCMSubmissionPipe {
                        captureStreamer.onCapturedPCM16AudioChunk = { [realtimePCMSubmissionPipe] chunk in
                            realtimePCMSubmissionPipe.submit(chunk)
                        }
                    } else {
                        captureStreamer.onCapturedPCM16AudioChunk = nil
                    }
                    if shouldUseFallbackAudioChunks {
                        captureStreamer.onCapturedAudioChunk = { [directAudioFallbackSender] chunk in
                            guard let directAudioFallbackSender else { return }
                            let audioWire = RemoteDesktopAudioChunkWire.encode(chunk)
                            Task(priority: .utility) {
                                await directAudioFallbackSender.submit(audioWire)
                            }
                        }
                    } else {
                        captureStreamer.onCapturedAudioChunk = nil
                    }
                    captureStreamer.onCaptureIssue = { issue in
                        self.logger.warning(
                            "⚠️ WebRTC ScreenCaptureKit 采集提示: session=\(sessionID, privacy: .public) issue=\(issue, privacy: .public)"
                        )
                        if failFastMediaFallbacks, issue.hasPrefix("strict-") {
                            Task { @MainActor in
                                recordStrictMediaValidationFailure(
                                    reason: issue,
                                    probable: "screencapturekit-strict-media-issue",
                                    config: streamConfig
                                )
                                self.webrtcScreenStreamingTasksBySessionId[sessionID]?.cancel()
                            }
                        }
                    }
                    captureStreamer.onCaptureTelemetry = { snapshot in
                        guard self.remoteDesktopNetworkStatsEnabled else { return }
                        let captureFPS = String(format: "%.1f", snapshot.captureFPS)
                        let meaningfulFPS = String(format: "%.1f", snapshot.meaningfulFPS)
                        let encodedFPS = String(format: "%.1f", snapshot.encodedFPS)
                        let encodeLatencyP50 = snapshot.encodeLatencyP50Ms.map { String(format: "%.2f", $0) } ?? "n/a"
                        let encodeLatencyP95 = snapshot.encodeLatencyP95Ms.map { String(format: "%.2f", $0) } ?? "n/a"
                        let encodeLatencyMax = snapshot.encodeLatencyMaxMs.map { String(format: "%.2f", $0) } ?? "n/a"
                        Self.writeWebRTCSessionDiagnostic(
                            """
                            sckTxTelemetry session=\(sessionID) targetFPS=\(snapshot.targetFPS) \
                            codec=\(snapshot.codec) size=\(snapshot.width)x\(snapshot.height) \
                            capturesAudio=\(snapshot.capturesAudio) captureFPS=\(captureFPS) \
                            meaningfulFPS=\(meaningfulFPS) encodedFPS=\(encodedFPS) \
                            captured=\(snapshot.capturedSamples) meaningful=\(snapshot.meaningfulSamples) \
                            encoded=\(snapshot.encodedFrames) encodedBytes=\(snapshot.encodedBytes) \
                            encodeLatencyP50Ms=\(encodeLatencyP50) encodeLatencyP95Ms=\(encodeLatencyP95) \
                            encodeLatencyMaxMs=\(encodeLatencyMax) encodeFailures=\(snapshot.encodeFailures)
                            """,
                            sessionID: sessionID
                        )
                        WebRTCMediaDiagnosticWriter.append(
                            WebRTCMediaDiagnosticEvent(
                                sessionId: sessionID,
                                kind: "sckTxTelemetry",
                                probable: snapshot.meaningfulSamples == 0
                                    ? "sck-no-meaningful-frames"
                                    : (snapshot.encodedFrames == 0 ? "vt-no-encoded-output" : "sck-vt-flowing"),
                                codec: snapshot.codec,
                                sckCaptured: UInt64(max(0, snapshot.capturedSamples)),
                                sckMeaningful: UInt64(max(0, snapshot.meaningfulSamples)),
                                sckEncoded: UInt64(max(0, snapshot.encodedFrames)),
                                sckEncodedBytes: UInt64(max(0, snapshot.encodedBytes)),
                                sckCaptureFPS: snapshot.captureFPS,
                                sckMeaningfulFPS: snapshot.meaningfulFPS,
                                sckEncodedFPS: snapshot.encodedFPS,
                                sckTargetFPS: UInt64(max(0, snapshot.targetFPS)),
                                sckWidth: UInt64(max(0, snapshot.width)),
                                sckHeight: UInt64(max(0, snapshot.height)),
                                sckCapturesAudio: snapshot.capturesAudio,
                                sckEncodeLatencyP50Ms: snapshot.encodeLatencyP50Ms,
                                sckEncodeLatencyP95Ms: snapshot.encodeLatencyP95Ms,
                                sckEncodeLatencyMaxMs: snapshot.encodeLatencyMaxMs,
                                sckEncodeFailures: UInt64(max(0, snapshot.encodeFailures))
                            )
                        )
                    }

                    do {
                        try await captureStreamer.start(
                            preferredCodec: videoPolicy.codec,
                            preferredSize: videoPolicy.preferredSize,
                            targetFPS: captureFPS,
                            keyFrameInterval: videoPolicy.keyFrameInterval,
                            captureCursorInVideo: !nativeVideoTrackEnabled,
                            captureSystemAudio: shouldUseNativeAudioTrack
                                || shouldUseFallbackAudioChunks
                                || shouldUseRealtimeAudio,
                            audioEncoding: shouldUseFallbackAudioChunks ? preferredAudioEncoding : .pcmS16LE,
                            degradedFallbackJPEGProfile: nil,
                            failFastOnMediaFallbacks: failFastMediaFallbacks,
                            preserveExactVisibleSize: preserveExactVisibleCaptureSize,
                            lowLatencyMode: (streamConfig?.lowLatencyMode ?? false)
                                || (failFastMediaFallbacks && captureFPS >= 59),
                            videoCompressionLevelPercent: streamConfig?.videoCompressionLevel
                                ?? RemoteDesktopSettingsManager.shared.settings.displaySettings.boundedCompressionLevelPercent,
                            bitstreamFormat: nativeVideoTrackEnabled
                                ? .native
                                : .annexB
                        )
                        directCaptureStreamer = captureStreamer
                        lastDirectEncoderStartAt = Date()
                        let pqcMediaAudioEnabled = shouldUseRealtimeAudio
                        let streamMode: String = {
                            if nativeVideoTrackEnabled {
                                return nativeVideoWarmBackupEnabled
                                    ? "webrtc-native-warmup+sbrf-fallback-main"
                                    : "webrtc-native-main"
                            }
                            return "sbrf-main"
                        }()
                        self.logger.info(
                            """
                            🎥 WebRTC ScreenCaptureKit 直连硬编已启动: session=\(sessionID, privacy: .public) \
                            codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data()), privacy: .public) \
                            fps=\(captureFPS, privacy: .public) \
                            size=\(Int(videoPolicy.preferredSize.width), privacy: .public)x\(Int(videoPolicy.preferredSize.height), privacy: .public) \
                            reason=\(videoPolicy.reason, privacy: .public) \
                            mode=\(streamMode, privacy: .public) \
                            audio=\(audioRedirectionEnabled, privacy: .public) \
                            nativeAudio=\(shouldUseNativeAudioTrack, privacy: .public) \
                            pqcMediaAudio=\(pqcMediaAudioEnabled, privacy: .public) \
                            audioCodec=\(preferredAudioEncoding.rawValue, privacy: .public)
                            """
                        )
                        if let directRealtimeAudioSender {
                            Task(priority: .utility) { [logger = self.logger, sessionID] in
                                try? await Task.sleep(for: .seconds(3))
                                let snapshot = await directRealtimeAudioSender.diagnosticSnapshot()
                                logger.info(
                                    """
                                    📈 WebRTC PQC media audio tx startup: session=\(sessionID, privacy: .public) \
                                    audioTxCaptured=\(snapshot.capturedPackets, privacy: .public) \
                                    audioTxEncoded=\(snapshot.encodedPackets, privacy: .public) \
                                    audioTxSent=\(snapshot.sentPackets, privacy: .public) \
                                    audioDrops=\(snapshot.droppedPackets, privacy: .public) \
                                    probable=\(snapshot.capturedPackets == 0 ? "capture-unavailable-or-silent" : (snapshot.sentPackets == 0 ? "relay-send-not-draining" : "sending"), privacy: .public)
                                    """
                                )
                                Self.writeWebRTCSessionDiagnostic(
                                    "audioTxStartup session=\(sessionID) audioTxCaptured=\(snapshot.capturedPackets) audioTxEncoded=\(snapshot.encodedPackets) audioTxSent=\(snapshot.sentPackets) audioDrops=\(snapshot.droppedPackets)",
                                    sessionID: sessionID
                                )
                                WebRTCMediaDiagnosticWriter.append(
                                    WebRTCMediaDiagnosticEvent(
                                        sessionId: sessionID,
                                        kind: "audioTxStartup",
                                        probable: snapshot.capturedPackets == 0
                                            ? "capture-unavailable-or-silent"
                                            : (snapshot.sentPackets == 0 ? "relay-send-not-draining" : "sending"),
                                        audioTxCaptured: snapshot.capturedPackets,
                                        audioTxEncoded: snapshot.encodedPackets,
                                        audioTxSent: snapshot.sentPackets,
                                        audioDrops: snapshot.droppedPackets
                                    )
                                )
                            }
                        }
                        self.appendSmokeStatus(
                            "stream-sck-started session=\(sessionID) codec=\(nativeVideoTrackEnabled ? "webrtc-native-video" : Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data())) mode=\(streamMode)"
                        )
                        return true
                    } catch {
                        captureStreamer.stop()
                        directCaptureStreamer = nil
                        directNativeFramePacingTask?.cancel()
                        directNativeFramePacingTask = nil
                        directSyntheticAudioToneSource?.stop()
                        directSyntheticAudioToneSource = nil
                        directRealtimeAudioAttachGeneration &+= 1
                        directRealtimeAudioAttachTask?.cancel()
                        directRealtimeAudioAttachTask = nil
                        directRealtimePCMSubmissionPipe?.close()
                        directRealtimePCMSubmissionPipe = nil
                        await directRealtimeAudioSender?.close(reason: "remote-desktop-task-cleanup")
                        directRealtimeAudioSender = nil
                        directRealtimeAudioSenderRelayEndpoint = nil
                        directRealtimeAudioSenderRelayExpiresAt = nil
                        directRealtimeAudioContinuityState = nil
                        encodedFrameStore.clear()
                        lastDirectEncoderStartAt = .distantPast
                        if failFastMediaFallbacks {
                            recordStrictMediaValidationFailure(
                                reason: "sck-video-audio-start-failed",
                                probable: "screencapturekit-main-path-unavailable",
                                config: streamConfig
                            )
                            return false
                        }
                        self.logger.error(
                            "⚠️ WebRTC ScreenCaptureKit 直连硬编启动失败，回退 JPEG: session=\(sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                        )
                        self.appendSmokeStatus(
                            "stream-sck-start-failed session=\(sessionID) codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data())) error=\(error.localizedDescription)"
                        )
                        return false
                    }
                }
#endif

                while !Task.isCancelled {
                    guard let lastHeartbeatAt = self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] else {
                        self.logger.info("⏸️ WebRTC 屏幕推流等待远端心跳: session=\(sessionID, privacy: .public)")
                        break
                    }
                    if Date().timeIntervalSince(lastHeartbeatAt) > heartbeatTimeoutSeconds {
                        self.logger.info("⏹️ WebRTC 屏幕推流因远端心跳超时停止: session=\(sessionID, privacy: .public)")
                        break
                    }
                    if self.webrtcRekeyInProgressSessionIds.contains(sessionID) {
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                        } catch {
                            break
                        }
                        continue
                    }
                    if Date().timeIntervalSince(lastTransportProbeAt) >= 2.0 {
                        let probedPath = await session.currentICETransportPath()
                        let retainedPreviousPath = transportPathState.recordProbe(probedPath)
                        let newPath = transportPathState.effectivePath
                        if retainedPreviousPath {
                            self.logger.debug(
                                "ℹ️ WebRTC 屏幕通道保留上次稳定传输路径: session=\(sessionID, privacy: .public) probed=unknown effective=\(newPath.rawValue, privacy: .public) unknownProbes=\(transportPathState.consecutiveUnknownProbes, privacy: .public)"
                            )
                        }
                        if newPath != transportPath {
                            self.logger.info(
                                "📶 WebRTC 传输路径更新: session=\(sessionID, privacy: .public) path=\(newPath.rawValue, privacy: .public)"
                            )
                            self.appendSmokeStatus(
                                "stream-path session=\(sessionID) path=\(newPath.rawValue)"
                            )
                            transportPath = newPath
                        }
                        lastTransportProbeAt = Date()
                    }
                    let streamConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
                    let failFastMediaFallbacks = Self.shouldFailFastRemoteMediaFallbacks(
                        remoteStreamConfiguration: streamConfig
                    )
                    let requestedDedicatedScreenChannel = streamConfig?.screenDataChannelEnabled == true
                    if requestedDedicatedScreenChannel {
                        try? session.ensureScreenDataChannel()
                    }
                    let screenChannelOpen = requestedDedicatedScreenChannel && session.hasOpenScreenDataChannel()
                    if requestedDedicatedScreenChannel && !screenChannelOpen && screenChannelWaitStartedAt == nil {
                        screenChannelWaitStartedAt = Date()
                    } else if !requestedDedicatedScreenChannel || screenChannelOpen {
                        screenChannelWaitStartedAt = nil
                    }
                    let screenChannelWaitElapsed = screenChannelWaitStartedAt.map { Date().timeIntervalSince($0) }
                    let screenRoute = Self.planWebRTCScreenChannelRoute(
                        screenDataChannelEnabled: requestedDedicatedScreenChannel,
                        screenChannelWireFormat: streamConfig?.screenChannelWireFormat,
                        screenChannelOpen: screenChannelOpen,
                        waitElapsed: screenChannelWaitElapsed
                    )
                    let useDedicatedScreenChannel = screenRoute.useDedicatedScreenChannel
                    let useChunkedScreenWire = screenRoute.useChunkedScreenWire
                    if screenRoute.state != lastScreenChannelRouteState ||
                        Date().timeIntervalSince(lastScreenChannelWaitReportAt) >= 1.0 {
                        self.logger.info(
                            """
                            📡 WebRTC screenChannelState: session=\(sessionID, privacy: .public) \
                            state=\(screenRoute.state, privacy: .public) requested=\(requestedDedicatedScreenChannel, privacy: .public) \
                            open=\(screenChannelOpen, privacy: .public) waitMs=\(Int(((screenChannelWaitElapsed ?? 0) * 1000).rounded()), privacy: .public) \
                            wire=\(useChunkedScreenWire ? WebRTCSession.screenChunkedWireFormat : "length-framed", privacy: .public)
                            """
                        )
                        self.appendSmokeStatus(
                            "screenChannelState session=\(sessionID) state=\(screenRoute.state) requested=\(requestedDedicatedScreenChannel) open=\(screenChannelOpen) waitMs=\(Int(((screenChannelWaitElapsed ?? 0) * 1000).rounded()))"
                        )
                        self.appendWebRTCSessionDiagnostic(
                            "screenChannelState session=\(sessionID) state=\(screenRoute.state) requested=\(requestedDedicatedScreenChannel) open=\(screenChannelOpen) waitMs=\(Int(((screenChannelWaitElapsed ?? 0) * 1000).rounded())) wire=\(useChunkedScreenWire ? WebRTCSession.screenChunkedWireFormat : "length-framed")",
                            sessionID: sessionID
                        )
                        lastScreenChannelRouteState = screenRoute.state
                        lastScreenChannelWaitReportAt = Date()
                    }
                    if failFastMediaFallbacks && screenRoute.state == "failed-control-fallback" {
                        recordStrictMediaValidationFailure(
                            reason: "screen-channel-control-fallback-forbidden",
                            probable: "dedicated-screen-channel-not-open",
                            config: streamConfig
                        )
                        break
                    }
                    let nativeVideoTrackReadyForInteraction =
                        self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.nativeVideoTrackReady == true
                    let hasEstablishedScreenPathForInteraction =
                        framesSent > 0 ||
                        nativeVideoTrackReadyForInteraction ||
                        screenRoute.state == "failed-control-fallback"
                    if screenRoute.allowsInteractionStreaming && hasEstablishedScreenPathForInteraction {
                        if self.webrtcInteractionStreamingAllowedSessionIds.insert(sessionID).inserted {
                            self.appendSmokeStatus(
                                "interaction-stream-enabled session=\(sessionID) reason=screenChannelState:\(screenRoute.state)"
                            )
                        }
                        startInteractionStreamingIfNeeded()
                    } else {
                        self.webrtcInteractionStreamingAllowedSessionIds.remove(sessionID)
                    }
                    let selectedVideoPolicy = currentVideoPolicy(for: transportPath)
                    let nativeVideoTrackReadyForPolicy =
                        self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.nativeVideoTrackReady == true
                    let rawFallbackPolicyShouldDriveMain = Self.nativeVideoFallbackDecision(
                        supportsNativeVideoTrack: session.supportsNativeScreenVideoTrack,
                        nativeVideoTrackReady: nativeVideoTrackReadyForPolicy,
                        nativeVideoHealthState: nativeVideoHealthState,
                        cooldownRemainingSeconds: max(0, nativeVideoFailureCooldownUntil.timeIntervalSince(Date()))
                    ).fallbackShouldDriveMain
                    let fallbackPolicyShouldDriveMain = failFastMediaFallbacks
                        ? false
                        : rawFallbackPolicyShouldDriveMain
                    let nativeCaptureVideoPolicy = session.supportsNativeScreenVideoTrack
                        ? currentNativeCaptureVideoPolicy(for: transportPath)
                        : selectedVideoPolicy
                    let nativeWarmupFallbackSourceSize: CGSize = {
#if os(macOS)
                        if let displayMode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
                            return CGSize(
                                width: displayMode.pixelWidth,
                                height: displayMode.pixelHeight
                            )
                        }
#endif
                        return nativeCaptureVideoPolicy.preferredSize
                    }()
                    let nativeWarmupFallbackJPEGProfile =
                        Self.boundedWebRTCWarmupJPEGProfile(
                            for: nativeWarmupFallbackSourceSize,
                            compressionLevel: RemoteDesktopSettingsManager.shared.settings.networkSettings.boundedCompressionLevel
                        )
                    let fallbackSendVideoPolicy =
                        session.supportsNativeScreenVideoTrack && fallbackPolicyShouldDriveMain
                            ? WebRTCRemoteDesktopVideoPolicySelector.degradedFallbackPolicy(
                                from: selectedVideoPolicy,
                                profile: nativeWarmupFallbackJPEGProfile,
                                reasonSuffix: "native-warmup-bounded-jpeg"
                            )
                            : selectedVideoPolicy
                    let budget = currentBudget(for: transportPath, videoPolicy: fallbackSendVideoPolicy)
                    let nativeCaptureBudget = session.supportsNativeScreenVideoTrack
                        ? currentBudget(for: transportPath, videoPolicy: nativeCaptureVideoPolicy)
                        : budget
                    let strictHighFPSRequested = max(
                        fallbackSendVideoPolicy.targetFrameRate,
                        nativeCaptureVideoPolicy.targetFrameRate
                    ) >= 59
                    if failFastMediaFallbacks,
                       strictHighFPSRequested,
                       transportPath != .unknown,
                       (budget.frameRate < 59 || nativeCaptureBudget.frameRate < 59) {
                        recordStrictMediaValidationFailure(
                            reason: "remote-video-fps-budget-below-target",
                            probable: "transport-or-system-budget-clamped-high-fps",
                            config: streamConfig
                        )
                        break
                    }
                    let screenSendMaxBufferedAmountBytes =
                        session.supportsNativeScreenVideoTrack && fallbackPolicyShouldDriveMain
                            ? max(
                                budget.maxBufferedAmountBytes,
                                UInt64(nativeWarmupFallbackJPEGProfile.maxTransportFrameBytes)
                            )
                            : budget.maxBufferedAmountBytes
                    let videoPolicy = WebRTCRemoteDesktopVideoPolicy(
                        codec: fallbackSendVideoPolicy.codec,
                        targetFrameRate: min(fallbackSendVideoPolicy.targetFrameRate, budget.frameRate),
                        keyFrameInterval: fallbackSendVideoPolicy.keyFrameInterval,
                        preferredSize: fallbackSendVideoPolicy.preferredSize,
                        usesHardwareEncoder: fallbackSendVideoPolicy.usesHardwareEncoder,
                        reason: fallbackSendVideoPolicy.reason
                    )
                    let encoderVideoPolicy = session.supportsNativeScreenVideoTrack
                        ? WebRTCRemoteDesktopVideoPolicy(
                            codec: nativeCaptureVideoPolicy.codec,
                            targetFrameRate: min(nativeCaptureVideoPolicy.targetFrameRate, nativeCaptureBudget.frameRate),
                            keyFrameInterval: nativeCaptureVideoPolicy.keyFrameInterval,
                            preferredSize: nativeCaptureVideoPolicy.preferredSize,
                            usesHardwareEncoder: nativeCaptureVideoPolicy.usesHardwareEncoder,
                            reason: nativeCaptureVideoPolicy.reason
                        )
                        : videoPolicy
                    if encoderVideoPolicy != lastEncoderVideoPolicy ||
                        videoPolicy != lastFallbackSendVideoPolicy {
                        if lastEncoderVideoPolicy?.preferredSize != encoderVideoPolicy.preferredSize {
#if os(macOS)
                            damageTracker.reset()
                            pendingDamageReport = nil
#endif
                        }
                        self.logger.info(
                            """
                            🧭 WebRTC 推流策略: session=\(sessionID, privacy: .public) \
                            path=\(transportPath.rawValue, privacy: .public) \
                            codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data()), privacy: .public) \
                            fps=\(videoPolicy.targetFrameRate, privacy: .public) \
                            gop=\(videoPolicy.keyFrameInterval, privacy: .public) \
                            reason=\(videoPolicy.reason, privacy: .public) \
                            fallbackPreferred=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data()), privacy: .public) \
                            nativeCodec=\(Self.remoteFrameFormatName(frameType: encoderVideoPolicy.codec, payload: Data()), privacy: .public) \
                            nativeCaptureCodec=\(Self.remoteFrameFormatName(frameType: nativeCaptureVideoPolicy.codec, payload: Data()), privacy: .public) \
                            nativeFPS=\(encoderVideoPolicy.targetFrameRate, privacy: .public) \
                            nativeReason=\(encoderVideoPolicy.reason, privacy: .public)
                            """
                        )
                        self.appendSmokeStatus(
                            """
                            stream-policy session=\(sessionID) path=\(transportPath.rawValue) \
                            codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data())) \
                            fps=\(videoPolicy.targetFrameRate) gop=\(videoPolicy.keyFrameInterval) \
                            reason=\(videoPolicy.reason) fallbackPreferred=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data())) \
                            nativeCodec=\(Self.remoteFrameFormatName(frameType: encoderVideoPolicy.codec, payload: Data())) \
                            nativeCaptureCodec=\(Self.remoteFrameFormatName(frameType: nativeCaptureVideoPolicy.codec, payload: Data())) \
                            nativeFPS=\(encoderVideoPolicy.targetFrameRate) nativeReason=\(encoderVideoPolicy.reason)
                            """
                        )
                        lastFallbackSendVideoPolicy = videoPolicy
                    }
                    if budget != lastBudget {
                        self.logger.info(
                            """
                            🎛️ WebRTC 推流预算: session=\(sessionID, privacy: .public) \
                            path=\(transportPath.rawValue, privacy: .public) \
                            fps=\(budget.frameRate, privacy: .public) \
                            buffered=\(Int(budget.maxBufferedAmountBytes), privacy: .public) \
                            screenBuffered=\(Int(screenSendMaxBufferedAmountBytes), privacy: .public) \
                            reason=\(budget.reason, privacy: .public)
                            """
                        )
                        self.appendSmokeStatus(
                            """
                            stream-budget session=\(sessionID) path=\(transportPath.rawValue) \
                            fps=\(budget.frameRate) buffered=\(Int(budget.maxBufferedAmountBytes)) \
                            screenBuffered=\(Int(screenSendMaxBufferedAmountBytes)) \
                            reason=\(budget.reason)
                            """
                        )
                        lastBudget = budget
                    }
#if os(macOS)
                    let directEncoderReady = await ensureDirectEncoder(for: encoderVideoPolicy)
                    if failFastMediaFallbacks && !directEncoderReady {
                        if strictMediaValidationFailureReason == nil {
                            recordStrictMediaValidationFailure(
                                reason: "native-video-main-path-not-ready",
                                probable: "sck-or-native-video-encoder-unavailable",
                                config: streamConfig
                            )
                        }
                        break
                    }
                    if session.supportsNativeScreenVideoTrack,
                       Date().timeIntervalSince(lastNativeVideoStatsReportAt) >= 2.0 {
                        let sendSnapshot = session.nativeScreenVideoSendSnapshot()
                        let rtcStats = await session.outgoingNativeScreenVideoRTCStats()
                        let nativeVideoTrackReadyForStats =
                            self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.nativeVideoTrackReady == true
                        let nextHealthState: NativeVideoHealthState = {
                            if nativeVideoTrackReadyForStats,
                               rtcStats.rtpFlowing {
                                return .rendered
                            }
                            if rtcStats.rtpFlowing {
                                return .rtpFlowing
                            }
                            if Date() < nativeVideoFailureCooldownUntil {
                                return .recovering
                            }
                            let nativeVideoSubmissionStartedAt = max(
                                lastDirectEncoderStartAt,
                                directSyntheticNativeVideoStartedAt
                            )
                            guard nativeVideoSubmissionStartedAt != .distantPast,
                                  sendSnapshot.submittedFrames > 0 else {
                                return .negotiated
                            }
                            let rawFrameAge = Date().timeIntervalSince(nativeVideoSubmissionStartedAt)
                            let noRTPFailureGraceSeconds = Self.nativeVideoNoRTPFailureGraceSeconds(
                                failFastMediaFallbacks: failFastMediaFallbacks,
                                codec: rtcStats.codec,
                                encoder: rtcStats.encoderImplementation,
                                requestedCodec: encoderVideoPolicy.codec
                            )
                            guard rawFrameAge >= noRTPFailureGraceSeconds else {
                                return .rawFramesSubmitted
                            }
                            if !rtcStats.outboundStatsPresent || rtcStats.packetsSent == 0 || rtcStats.bytesSent == 0 {
                                return nativeVideoSenderRefreshAttempted ? .degradedNoRTP : .failedNoRTP
                            }
                            if rtcStats.framesEncoded == 0 || rtcStats.framesSent == 0 {
                                return .senderZero
                            }
                            return .rawFramesSubmitted
                        }()
                        let now = Date()
                        if failFastMediaFallbacks,
                           ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_DIAGNOSTIC_SYNTHETIC_NATIVE_VIDEO"] == "1",
                           rtcStats.rtpFlowing {
                            recordStrictMediaValidationFailure(
                                reason: "diagnostic-synthetic-native-video-enabled",
                                probable: "synthetic-native-video-diagnostic",
                                config: streamConfig
                            )
                        } else if failFastMediaFallbacks, rtcStats.rtpFlowing {
                            let observedBitrate = rtcStats.targetBitrate > 0
                                ? rtcStats.targetBitrate
                                : rtcStats.availableOutgoingBitrate
                            if rtcStats.isQualityLimited {
                                let reason = (rtcStats.qualityLimitationReason ?? "unknown")
                                    .lowercased()
                                    .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                                recordStrictMediaValidationFailure(
                                    reason: "native-video-quality-limited-\(reason.isEmpty ? "unknown" : reason)",
                                    probable: "webrtc-quality-limitation-reported",
                                    config: streamConfig
                                )
                            } else if !rtcStats.bandwidthEstimatePresent {
                                recordStrictMediaValidationFailure(
                                    reason: "native-video-bwe-stats-unavailable",
                                    probable: "webrtc-bandwidth-estimate-missing",
                                    config: streamConfig
                                )
                            } else if let codecFailureReason = Self.strictNativeVideoCodecFailureReason(
                                rtcStats.codec,
                                requestedCodec: encoderVideoPolicy.codec
                            ) {
                                recordStrictMediaValidationFailure(
                                    reason: codecFailureReason,
                                    probable: "webrtc-native-video-codec-not-hardware-path",
                                    config: streamConfig
                                )
                            } else if let encoderFailureReason = Self.strictNativeVideoEncoderFailureReason(rtcStats.encoderImplementation) {
                                recordStrictMediaValidationFailure(
                                    reason: encoderFailureReason,
                                    probable: "webrtc-native-video-encoder-not-hardware-path",
                                    config: streamConfig
                                )
                            } else if sendSnapshot.lastFrameWidth > 0, sendSnapshot.lastFrameHeight > 0 {
                                let minimumTargetBitrate = WebRTCNativeScreenVideoValuePolicy.minimumExtremeBitrateBps(
                                    width: sendSnapshot.lastFrameWidth,
                                    height: sendSnapshot.lastFrameHeight,
                                    fps: encoderVideoPolicy.targetFrameRate
                                )
                                let bitrateFloorTolerance = max(UInt64(64_000), minimumTargetBitrate / 100)
                                if observedBitrate > 0,
                                   observedBitrate + bitrateFloorTolerance < minimumTargetBitrate {
                                    recordStrictMediaValidationFailure(
                                        reason: "native-video-target-bitrate-below-floor",
                                        probable: "webrtc-bwe-or-encoder-rate-limited",
                                        config: streamConfig
                                    )
                                }
                            }
                        }
                        let recoveredFromNativeFailure = (nextHealthState == .rtpFlowing || nextHealthState == .rendered)
                            && nativeVideoHealthState != .rtpFlowing
                            && nativeVideoHealthState != .rendered
                            && nativeVideoFailureStrikeCount > 0
                        if nextHealthState == .rtpFlowing || nextHealthState == .rendered {
                            nativeVideoFailureStrikeCount = 0
                            nativeVideoFailureCooldownUntil = .distantPast
                            if recoveredFromNativeFailure {
                                self.appendSmokeStatus(
                                    "native-video-rtp-flowing session=\(sessionID) state=\(nextHealthState.rawValue) framesSent=\(rtcStats.framesSent) bytesSent=\(rtcStats.bytesSent)"
                                )
                                self.appendWebRTCSessionDiagnostic(
                                    "native-video-rtp-flowing session=\(sessionID) state=\(nextHealthState.rawValue) framesSent=\(rtcStats.framesSent) bytesSent=\(rtcStats.bytesSent)",
                                    sessionID: sessionID
                                )
                                WebRTCMediaDiagnosticWriter.append(
                                    WebRTCMediaDiagnosticEvent(
                                        sessionId: sessionID,
                                        kind: "nativeVideoRecovered",
                                        probable: nil,
                                        fallbackProducer: activeFallbackProducer,
                                        nativeVideoHealth: nextHealthState.rawValue
                                    )
                                )
                            }
                        } else if nextHealthState == .failedNoRTP || nextHealthState == .senderZero || nextHealthState == .degradedNoRTP {
                            nativeVideoFailureStrikeCount += 1
                            if failFastMediaFallbacks {
                                let strictNoRTPReason = Self.strictNativeVideoNoRTPFailureReason(
                                    outboundStatsPresent: rtcStats.outboundStatsPresent,
                                    submittedFrames: sendSnapshot.submittedFrames,
                                    framesEncoded: rtcStats.framesEncoded,
                                    framesSent: rtcStats.framesSent,
                                    packetsSent: rtcStats.packetsSent,
                                    bytesSent: rtcStats.bytesSent
                                )
                                recordStrictMediaValidationFailure(
                                    reason: strictNoRTPReason,
                                    probable: nextHealthState.rawValue,
                                    config: streamConfig
                                )
                            } else {
                                if !nativeVideoSenderRefreshAttempted {
                                    nativeVideoSenderRefreshAttempted = session.refreshOutgoingScreenVideoSender(reason: nextHealthState.rawValue)
                                    if nativeVideoSenderRefreshAttempted {
                                        self.appendWebRTCSessionDiagnostic(
                                            "native-video-sender-refresh session=\(sessionID) action=refresh-sender reason=\(nextHealthState.rawValue)",
                                            sessionID: sessionID
                                        )
                                    }
                                }
                                let cooldownSeconds: TimeInterval = nativeVideoSenderRefreshAttempted || nativeVideoFailureStrikeCount >= 3 ? 10.0 : 1.25
                                nativeVideoFailureCooldownUntil = now.addingTimeInterval(cooldownSeconds)
                                self.appendSmokeStatus(
                                    "native-video-retry session=\(sessionID) action=cooldown state=\(nextHealthState.rawValue) cooldownMs=\(Int(cooldownSeconds * 1000)) strike=\(nativeVideoFailureStrikeCount) fallback=heartbeat"
                                )
                                self.appendWebRTCSessionDiagnostic(
                                    "native-video-retry session=\(sessionID) action=cooldown state=\(nextHealthState.rawValue) cooldownMs=\(Int(cooldownSeconds * 1000)) strike=\(nativeVideoFailureStrikeCount) fallback=heartbeat",
                                    sessionID: sessionID
                                )
                                WebRTCMediaDiagnosticWriter.append(
                                    WebRTCMediaDiagnosticEvent(
                                        sessionId: sessionID,
                                        kind: "nativeVideoRetry",
                                        probable: "native-video-stalled-fast-retry",
                                        fallbackProducer: activeFallbackProducer,
                                        nativeVideoHealth: nextHealthState.rawValue
                                    )
                                )
                            }
                        }
                        if nextHealthState != nativeVideoHealthState {
                            nativeVideoHealthState = nextHealthState
                            self.appendSmokeStatus(
                                "native-video-health session=\(sessionID) state=\(nativeVideoHealthState.rawValue) fallbackMode=\(nativeVideoTrackReadyForStats ? "heartbeat" : "main")"
                            )
                            WebRTCMediaDiagnosticWriter.append(
                                WebRTCMediaDiagnosticEvent(
                                    sessionId: sessionID,
                                    kind: "nativeVideoHealth",
                                    probable: nativeVideoHealthState == .failedNoRTP || nativeVideoHealthState == .senderZero
                                        ? "native-video-stalled-fast-retry"
                                        : nil,
                                    fallbackProducer: activeFallbackProducer,
                                    nativeVideoHealth: nativeVideoHealthState.rawValue
                                )
                            )
                        }
                        let nativeVideoFrameSourceLine =
                            "native-video-frame-source session=\(sessionID) target=\(sendSnapshot.targetWidth)x\(sendSnapshot.targetHeight)@\(sendSnapshot.targetFPS) lastFrame=\(sendSnapshot.lastFrameWidth)x\(sendSnapshot.lastFrameHeight) bytesPerRow=\(sendSnapshot.lastSubmittedFrameBytesPerRow) iosurface=\(sendSnapshot.lastSubmittedFrameHasIOSurface) rawTimestampNs=\(sendSnapshot.lastRawFrameTimestampNs.map(String.init) ?? "-") rawDeltaNs=\(sendSnapshot.lastRawFrameTimestampDeltaNs.map(String.init) ?? "-") timestampNs=\(sendSnapshot.lastFrameTimestampNs.map(String.init) ?? "-") timestampDeltaNs=\(sendSnapshot.lastFrameTimestampDeltaNs.map(String.init) ?? "-") timestampAdjusted=\(sendSnapshot.lastFrameTimestampWasAdjusted)"
                        self.appendSmokeStatus(nativeVideoFrameSourceLine)
                        self.appendWebRTCSessionDiagnostic(
                            nativeVideoFrameSourceLine,
                            sessionID: sessionID
                        )
                        self.logger.info(
                            """
                            📈 native WebRTC screen tx: session=\(sessionID, privacy: .public) \
                            state=\(nativeVideoHealthState.rawValue, privacy: .public) \
                            fallbackMode=\(nativeVideoTrackReadyForStats ? "heartbeat" : "main", privacy: .public) \
                            fallbackProducer=\(activeFallbackProducer, privacy: .public) \
                            fallbackSignature=\(lastFallbackSignature, privacy: .public) \
                            fallbackSwitchReason=\(fallbackProducerSwitchReason, privacy: .public) \
                            submitted=\(sendSnapshot.submittedFrames, privacy: .public) \
                            trackReady=\(sendSnapshot.trackReady, privacy: .public) \
                            trackEnabled=\(sendSnapshot.trackEnabled, privacy: .public) \
                            sourceReady=\(sendSnapshot.sourceReady, privacy: .public) \
                            capturerReady=\(sendSnapshot.capturerReady, privacy: .public) \
                            transceiverReady=\(sendSnapshot.transceiverReady, privacy: .public) \
                            senderReady=\(sendSnapshot.senderReady, privacy: .public) \
                            transceiverDirection=\(sendSnapshot.transceiverDirection ?? "-", privacy: .public) \
                            negotiatedDirection=\(sendSnapshot.negotiatedTransceiverDirection ?? "-", privacy: .public) \
                            lastFrame=\(sendSnapshot.lastFrameWidth, privacy: .public)x\(sendSnapshot.lastFrameHeight, privacy: .public) \
                            visibleFrame=\(sendSnapshot.lastFrameWidth, privacy: .public)x\(sendSnapshot.lastFrameHeight, privacy: .public) \
                            codedFrame=\(sendSnapshot.lastSubmittedFrameWidth, privacy: .public)x\(sendSnapshot.lastSubmittedFrameHeight, privacy: .public) \
                            rawPixelFormat=\(sendSnapshot.lastRawFramePixelFormat.map(String.init) ?? "-", privacy: .public) \
                            submittedPixelFormat=\(sendSnapshot.lastSubmittedFramePixelFormat.map(String.init) ?? "-", privacy: .public) \
                            pixelFormat=\(sendSnapshot.lastFramePixelFormat.map(String.init) ?? "-", privacy: .public) \
                            normalized=\(sendSnapshot.normalizedFrames, privacy: .public) \
                            frameNormalized=\(sendSnapshot.lastFrameWasNormalized, privacy: .public) \
                            rawTimestampNs=\(sendSnapshot.lastRawFrameTimestampNs.map(String.init) ?? "-", privacy: .public) \
                            timestampNs=\(sendSnapshot.lastFrameTimestampNs.map(String.init) ?? "-", privacy: .public) \
                            timestampAdjusted=\(sendSnapshot.lastFrameTimestampWasAdjusted, privacy: .public) \
                            outboundStats=\(rtcStats.outboundStatsPresent, privacy: .public) \
                            framesEncoded=\(rtcStats.framesEncoded, privacy: .public) \
                            framesSent=\(rtcStats.framesSent, privacy: .public) \
                            keyFramesEncoded=\(rtcStats.keyFramesEncoded, privacy: .public) \
                            packetsSent=\(rtcStats.packetsSent, privacy: .public) \
                            bytesSent=\(rtcStats.bytesSent, privacy: .public) \
                            codec=\(rtcStats.codec ?? "-", privacy: .public) \
                            encoder=\(rtcStats.encoderImplementation ?? "-", privacy: .public) \
                            qualityLimit=\(rtcStats.qualityLimitationReason ?? "-", privacy: .public) \
                            encodeSize=\(rtcStats.frameWidth, privacy: .public)x\(rtcStats.frameHeight, privacy: .public) \
                            encodeFPS=\(rtcStats.framesPerSecond, privacy: .public) \
                            totalEncodeTime=\(rtcStats.totalEncodeTime.map { String(format: "%.3f", $0) } ?? "-", privacy: .public) \
                            targetBitrate=\(rtcStats.targetBitrate, privacy: .public) \
                            availableOutgoingBitrate=\(rtcStats.availableOutgoingBitrate, privacy: .public) \
                            currentRTT=\(rtcStats.currentRoundTripTime.map { String(format: "%.3f", $0) } ?? "-", privacy: .public) \
                            remoteRTT=\(rtcStats.remoteRoundTripTime.map { String(format: "%.3f", $0) } ?? "-", privacy: .public) \
                            remotePacketsLost=\(rtcStats.remotePacketsLost, privacy: .public) \
                            remoteJitter=\(rtcStats.remoteJitter.map { String(format: "%.3f", $0) } ?? "-", privacy: .public) \
                            nack=\(rtcStats.nackCount, privacy: .public) \
                            pli=\(rtcStats.pliCount, privacy: .public) \
                            fir=\(rtcStats.firCount, privacy: .public)
                            """
                        )
                        self.appendSmokeStatus(
                            "native-video-tx session=\(sessionID) state=\(nativeVideoHealthState.rawValue) fallbackMode=\(nativeVideoTrackReadyForStats ? "heartbeat" : "main") fallbackProducer=\(activeFallbackProducer) fallbackSignature=\(lastFallbackSignature) submitted=\(sendSnapshot.submittedFrames) normalized=\(sendSnapshot.normalizedFrames) trackEnabled=\(sendSnapshot.trackEnabled) sourceReady=\(sendSnapshot.sourceReady) capturerReady=\(sendSnapshot.capturerReady) senderReady=\(sendSnapshot.senderReady) direction=\(sendSnapshot.transceiverDirection ?? "-") currentDirection=\(sendSnapshot.negotiatedTransceiverDirection ?? "-") lastFrame=\(sendSnapshot.lastFrameWidth)x\(sendSnapshot.lastFrameHeight) visibleFrame=\(sendSnapshot.lastFrameWidth)x\(sendSnapshot.lastFrameHeight) codedFrame=\(sendSnapshot.lastSubmittedFrameWidth)x\(sendSnapshot.lastSubmittedFrameHeight) rawPixelFormat=\(sendSnapshot.lastRawFramePixelFormat.map(String.init) ?? "-") submittedPixelFormat=\(sendSnapshot.lastSubmittedFramePixelFormat.map(String.init) ?? "-") pixelFormat=\(sendSnapshot.lastFramePixelFormat.map(String.init) ?? "-") frameNormalized=\(sendSnapshot.lastFrameWasNormalized) rawTimestampNs=\(sendSnapshot.lastRawFrameTimestampNs.map(String.init) ?? "-") timestampNs=\(sendSnapshot.lastFrameTimestampNs.map(String.init) ?? "-") timestampAdjusted=\(sendSnapshot.lastFrameTimestampWasAdjusted) framesEncoded=\(rtcStats.framesEncoded) framesSent=\(rtcStats.framesSent) keyFramesEncoded=\(rtcStats.keyFramesEncoded) packetsSent=\(rtcStats.packetsSent) bytesSent=\(rtcStats.bytesSent) outboundStats=\(rtcStats.outboundStatsPresent) codec=\(rtcStats.codec ?? "-") encoder=\(rtcStats.encoderImplementation ?? "-") qualityLimit=\(rtcStats.qualityLimitationReason ?? "-") encodeSize=\(rtcStats.frameWidth)x\(rtcStats.frameHeight) encodeFPS=\(rtcStats.framesPerSecond) totalEncodeTime=\(rtcStats.totalEncodeTime.map { String(format: "%.3f", $0) } ?? "-") targetBitrate=\(rtcStats.targetBitrate) availableOutgoingBitrate=\(rtcStats.availableOutgoingBitrate) currentRTT=\(rtcStats.currentRoundTripTime.map { String(format: "%.3f", $0) } ?? "-") remoteRTT=\(rtcStats.remoteRoundTripTime.map { String(format: "%.3f", $0) } ?? "-") remotePacketsLost=\(rtcStats.remotePacketsLost) remoteJitter=\(rtcStats.remoteJitter.map { String(format: "%.3f", $0) } ?? "-") nack=\(rtcStats.nackCount) pli=\(rtcStats.pliCount) fir=\(rtcStats.firCount)"
                        )
                        if self.remoteDesktopNetworkStatsEnabled {
                            self.appendWebRTCSessionDiagnostic(
                                "native-video-tx session=\(sessionID) state=\(nativeVideoHealthState.rawValue) fallbackMode=\(nativeVideoTrackReadyForStats ? "heartbeat" : "main") fallbackProducer=\(activeFallbackProducer) fallbackSignature=\(lastFallbackSignature) submitted=\(sendSnapshot.submittedFrames) normalized=\(sendSnapshot.normalizedFrames) trackEnabled=\(sendSnapshot.trackEnabled) sourceReady=\(sendSnapshot.sourceReady) capturerReady=\(sendSnapshot.capturerReady) senderReady=\(sendSnapshot.senderReady) direction=\(sendSnapshot.transceiverDirection ?? "-") currentDirection=\(sendSnapshot.negotiatedTransceiverDirection ?? "-") lastFrame=\(sendSnapshot.lastFrameWidth)x\(sendSnapshot.lastFrameHeight) visibleFrame=\(sendSnapshot.lastFrameWidth)x\(sendSnapshot.lastFrameHeight) codedFrame=\(sendSnapshot.lastSubmittedFrameWidth)x\(sendSnapshot.lastSubmittedFrameHeight) rawPixelFormat=\(sendSnapshot.lastRawFramePixelFormat.map(String.init) ?? "-") submittedPixelFormat=\(sendSnapshot.lastSubmittedFramePixelFormat.map(String.init) ?? "-") pixelFormat=\(sendSnapshot.lastFramePixelFormat.map(String.init) ?? "-") frameNormalized=\(sendSnapshot.lastFrameWasNormalized) rawTimestampNs=\(sendSnapshot.lastRawFrameTimestampNs.map(String.init) ?? "-") timestampNs=\(sendSnapshot.lastFrameTimestampNs.map(String.init) ?? "-") timestampAdjusted=\(sendSnapshot.lastFrameTimestampWasAdjusted) framesEncoded=\(rtcStats.framesEncoded) framesSent=\(rtcStats.framesSent) keyFramesEncoded=\(rtcStats.keyFramesEncoded) packetsSent=\(rtcStats.packetsSent) bytesSent=\(rtcStats.bytesSent) outboundStats=\(rtcStats.outboundStatsPresent) codec=\(rtcStats.codec ?? "-") encoder=\(rtcStats.encoderImplementation ?? "-") qualityLimit=\(rtcStats.qualityLimitationReason ?? "-") encodeSize=\(rtcStats.frameWidth)x\(rtcStats.frameHeight) encodeFPS=\(rtcStats.framesPerSecond) totalEncodeTime=\(rtcStats.totalEncodeTime.map { String(format: "%.3f", $0) } ?? "-") targetBitrate=\(rtcStats.targetBitrate) availableOutgoingBitrate=\(rtcStats.availableOutgoingBitrate) currentRTT=\(rtcStats.currentRoundTripTime.map { String(format: "%.3f", $0) } ?? "-") remoteRTT=\(rtcStats.remoteRoundTripTime.map { String(format: "%.3f", $0) } ?? "-") remotePacketsLost=\(rtcStats.remotePacketsLost) remoteJitter=\(rtcStats.remoteJitter.map { String(format: "%.3f", $0) } ?? "-") nack=\(rtcStats.nackCount) pli=\(rtcStats.pliCount) fir=\(rtcStats.firCount)",
                                sessionID: sessionID
                            )
                        }
                        if self.remoteDesktopNetworkStatsEnabled, rtcStats.framesPerSecond > 0 {
                            WebRTCMediaDiagnosticWriter.append(
                                WebRTCMediaDiagnosticEvent(
                                    sessionId: sessionID,
                                    kind: "videoStats",
                                    videoFPS: Double(rtcStats.framesPerSecond),
                                    fallbackProducer: activeFallbackProducer,
                                    nativeVideoHealth: nativeVideoHealthState.rawValue,
                                    submitted: sendSnapshot.submittedFrames,
                                    framesEncoded: rtcStats.framesEncoded,
                                    framesSent: rtcStats.framesSent,
                                    keyFramesEncoded: rtcStats.keyFramesEncoded,
                                    packetsSent: rtcStats.packetsSent,
                                    bytesSent: rtcStats.bytesSent,
                                    codec: rtcStats.codec,
                                    encoder: rtcStats.encoderImplementation,
                                    qualityLimit: rtcStats.qualityLimitationReason,
                                    encodeWidth: rtcStats.frameWidth,
                                    encodeHeight: rtcStats.frameHeight,
                                    encodeFPS: rtcStats.framesPerSecond,
                                    totalEncodeTime: rtcStats.totalEncodeTime,
                                    targetBitrate: rtcStats.targetBitrate,
                                    availableOutgoingBitrate: rtcStats.availableOutgoingBitrate,
                                    currentRTT: rtcStats.currentRoundTripTime,
                                    remoteRTT: rtcStats.remoteRoundTripTime,
                                    remotePacketsLost: rtcStats.remotePacketsLost,
                                    remoteJitter: rtcStats.remoteJitter,
                                    nack: rtcStats.nackCount,
                                    pli: rtcStats.pliCount,
                                    fir: rtcStats.firCount,
                                    validationMode: failFastMediaFallbacks ? "strict" : "standard"
                                )
                            )
                        }
                        lastNativeVideoStatsReportAt = Date()
                    }
                    if failFastMediaFallbacks, strictMediaValidationFailureReason != nil {
                        break
                    }
                    let nativeVideoTrackReady =
                        self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.nativeVideoTrackReady == true
                    let nativeVideoFallbackDecision = Self.nativeVideoFallbackDecision(
                        supportsNativeVideoTrack: session.supportsNativeScreenVideoTrack,
                        nativeVideoTrackReady: nativeVideoTrackReady,
                        nativeVideoHealthState: nativeVideoHealthState,
                        cooldownRemainingSeconds: max(0, nativeVideoFailureCooldownUntil.timeIntervalSince(Date()))
                    )
                    let fallbackDecisionShouldDriveMain = failFastMediaFallbacks
                        ? false
                        : nativeVideoFallbackDecision.fallbackShouldDriveMain
                    if fallbackDecisionShouldDriveMain != nativeVideoFallbackDrivingMain {
                        nativeVideoFallbackDrivingMain = fallbackDecisionShouldDriveMain
                        let action = nativeVideoFallbackDrivingMain ? "fallback-main" : "native-main"
                        self.appendSmokeStatus(
                            "native-video-retry session=\(sessionID) action=\(action) state=\(nativeVideoHealthState.rawValue) reason=\(nativeVideoFallbackDecision.retryReason) cooldownMs=\(Int(nativeVideoFallbackDecision.cooldownRemainingSeconds * 1000))"
                        )
                        self.appendWebRTCSessionDiagnostic(
                            "native-video-retry session=\(sessionID) action=\(action) state=\(nativeVideoHealthState.rawValue) reason=\(nativeVideoFallbackDecision.retryReason) cooldownMs=\(Int(nativeVideoFallbackDecision.cooldownRemainingSeconds * 1000))",
                            sessionID: sessionID
                        )
                    } else if nativeVideoFallbackDecision.retryNativeCapture,
                              Date().timeIntervalSince(lastNativeVideoRetryDiagnosticAt) >= 2.0 {
                        lastNativeVideoRetryDiagnosticAt = Date()
                        self.appendWebRTCSessionDiagnostic(
                            "native-video-retry session=\(sessionID) action=probe state=\(nativeVideoHealthState.rawValue) reason=\(nativeVideoFallbackDecision.retryReason) cooldownMs=\(Int(nativeVideoFallbackDecision.cooldownRemainingSeconds * 1000))",
                            sessionID: sessionID
                        )
                    }
                    if screenRoute.shouldWaitForScreenChannel {
                        do {
                            try await Task.sleep(for: .milliseconds(50))
                        } catch {
                            break
                        }
                        continue
                    }
                    if self.consumePendingWebRTCStreamRefresh(for: sessionID) {
                        let refreshToken = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.streamRefreshToken
                        awaitingRefreshToken = refreshToken
                        awaitingRefreshRequestedAt = Date()
                        predictiveFramesSentAfterRefresh = 0
                        lastAwaitingRefreshReportAt = .distantPast
                        directCaptureStreamer?.requestKeyFrameRefresh(reason: "viewer-stream-refresh")
                        self.logger.info(
                            "🪄 WebRTC viewer 请求关键帧刷新: session=\(sessionID, privacy: .public) refreshTokenState=\(Self.streamRefreshTokenLogState(refreshToken), privacy: .public)"
                        )
                    }
                    if session.supportsNativeScreenVideoTrack,
                       !nativeVideoFallbackDrivingMain,
                       nativeVideoTrackReady || nativeVideoHealthState == .rtpFlowing || nativeVideoHealthState == .rendered {
                        if lastSentFormat != "webrtc-native-video" {
                            self.logger.info(
                                "🎬 WebRTC 原生屏幕视频已切换为跨网主链: session=\(sessionID, privacy: .public) nativeReady=\(nativeVideoTrackReady, privacy: .public) nativeHealth=\(nativeVideoHealthState.rawValue, privacy: .public) fallback=frozen-last-good-frame"
                            )
                            self.appendSmokeStatus(
                                "stream-format session=\(sessionID) format=webrtc-native-video nativeReady=\(nativeVideoTrackReady) nativeHealth=\(nativeVideoHealthState.rawValue)"
                            )
                            lastSentFormat = "webrtc-native-video"
                        }
                        lastEncoderVideoPolicy = encoderVideoPolicy
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                        } catch {
                            break
                        }
                        continue
                    } else if !failFastMediaFallbacks,
                              session.supportsNativeScreenVideoTrack,
                              lastSentFormat.hasPrefix("webrtc-native-video") {
                        self.logger.info(
                            "🫧 WebRTC 原生屏幕视频未获 RTP 正证据，SBRF/JPEG 继续作为主链: session=\(sessionID, privacy: .public) state=\(nativeVideoHealthState.rawValue, privacy: .public)"
                        )
                        lastSentFormat = ""
                    }
#endif
                    if failFastMediaFallbacks, session.supportsNativeScreenVideoTrack {
                        if lastSentFormat != "webrtc-native-video-waiting" {
                            self.appendSmokeStatus(
                                "stream-format session=\(sessionID) format=webrtc-native-video-waiting nativeHealth=\(nativeVideoHealthState.rawValue) fallback=forbidden"
                            )
                            self.appendWebRTCSessionDiagnostic(
                                "stream-format session=\(sessionID) format=webrtc-native-video-waiting nativeHealth=\(nativeVideoHealthState.rawValue) fallback=forbidden",
                                sessionID: sessionID
                            )
                            lastSentFormat = "webrtc-native-video-waiting"
                        }
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                        } catch {
                            break
                        }
                        continue
                    }
                    lastEncoderVideoPolicy = encoderVideoPolicy
                    do {
                        let frameIntervalNs = max(1_000_000_000 / budget.frameRate, 1_000_000)
                        try await Task.sleep(for: .nanoseconds(frameIntervalNs))
                    } catch {
                        break
                    }
                    fallbackLoopTicks += 1
                    let bufferedAmount = useDedicatedScreenChannel
                        ? session.screenDataChannelBufferedAmountBytes()
                        : session.dataChannelBufferedAmountBytes()
                    let nativeWarmupNativeReadyForBackpressure =
                        self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.nativeVideoTrackReady == true
                    if Self.shouldThrottleNativeWarmupJPEGFallback(
                        supportsNativeVideoTrack: session.supportsNativeScreenVideoTrack,
                        nativeVideoTrackReady: nativeWarmupNativeReadyForBackpressure,
                        bufferedAmount: bufferedAmount,
                        maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes
                    ) {
                        framesDroppedBackpressure += 1
                        if Date().timeIntervalSince(lastBackpressureReportAt) >= 1.0 {
                            self.logger.warning(
                                "⚠️ WebRTC native warmup JPEG backpressure: skip capture before source read. session=\(sessionID, privacy: .public) screenBuffered=\(Int(bufferedAmount), privacy: .public) threshold=\(Int(Self.nativeWarmupJPEGBackpressureThreshold(maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes)), privacy: .public) budget=\(Int(screenSendMaxBufferedAmountBytes), privacy: .public) chunkDropReason=native-warmup-jpeg-backpressure"
                            )
                            self.appendSmokeStatus(
                                "stream-backpressure session=\(sessionID) screenBuffered=\(Int(bufferedAmount)) budget=\(Int(screenSendMaxBufferedAmountBytes)) chunkDropReason=native-warmup-jpeg-backpressure dropped=\(framesDroppedBackpressure)"
                            )
                            lastBackpressureReportAt = Date()
                        }
                        continue
                    }
                    if bufferedAmount > screenSendMaxBufferedAmountBytes,
                       awaitingRefreshToken == nil {
                        framesDroppedBackpressure += 1
                        self.logger.debug(
                            "⏳ WebRTC 屏幕推流背压：跳过 stale 帧 buffered=\(Int(bufferedAmount), privacy: .public) budget=\(Int(screenSendMaxBufferedAmountBytes), privacy: .public) chunkDropReason=screen-buffered"
                        )
                        if Date().timeIntervalSince(lastBackpressureReportAt) >= 1.0 {
                            self.appendSmokeStatus(
                                "stream-backpressure session=\(sessionID) screenBuffered=\(Int(bufferedAmount)) budget=\(Int(screenSendMaxBufferedAmountBytes)) chunkDropReason=screen-buffered dropped=\(framesDroppedBackpressure)"
                            )
                            lastBackpressureReportAt = Date()
                        }
                        continue
                    }
                    var capturedFrame: ScreenDataWire?
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN"] == "1" {
                        if failFastMediaFallbacks {
                            recordStrictMediaValidationFailure(
                                reason: "synthetic-screen-forbidden",
                                probable: "smoke-synthetic-screen-enabled",
                                config: streamConfig
                            )
                            break
                        }
                        if let synthetic = syntheticScreenDataIfEnabled() {
                            if !usingSyntheticFrames {
                                usingSyntheticFrames = true
                                self.logger.info("🧪 WebRTC smoke 使用合成屏幕帧: session=\(sessionID, privacy: .public)")
                            }
                            capturedFrame = synthetic
                        }
                    }
#if os(macOS)
                    if capturedFrame == nil {
                        let nativeVideoWarmBackupEnabled =
                            session.supportsNativeScreenVideoTrack && nativeVideoFallbackDrivingMain
                        let now = Date()
                        let latestSCKAgeMs = encodedFrameStore.latestAgeMs(now: now)
                        let directEncodedFrame = videoPolicy.usesHardwareEncoder && !nativeVideoWarmBackupEnabled
                            ? encodedFrameStore.takeLatest()
                            : nil
                        if let encodedFrame = directEncodedFrame {
                            directEncodedFramesTaken += 1
                            if activeFallbackProducer != Self.webRTCFallbackDirectEncoderProducer {
                                activeFallbackProducer = Self.webRTCFallbackDirectEncoderProducer
                                fallbackProducerSwitchReason = "direct-encoder-frame-ready"
                                self.logger.info(
                                    "🔄 WebRTC fallback producer switched: session=\(sessionID, privacy: .public) producer=directEncoder reason=\(fallbackProducerSwitchReason, privacy: .public)"
                                )
                                self.appendWebRTCSessionDiagnostic(
                                    "fallbackProducerSwitch session=\(sessionID) producer=directEncoder reason=\(fallbackProducerSwitchReason)",
                                    sessionID: sessionID
                                )
                            }
                            lastHardwareFrameAt = now
                            lastFallbackSignature = "\(encodedFrame.format) \(encodedFrame.width)x\(encodedFrame.height)"
                            capturedFrame = ScreenDataWire(
                                width: encodedFrame.width,
                                height: encodedFrame.height,
                                imageData: encodedFrame.imageData,
                                timestamp: encodedFrame.timestamp,
                                format: encodedFrame.format,
                                isSyncFrame: encodedFrame.isSyncFrame,
                                sequenceNumber: encodedFrame.sequenceNumber
                            )
                        } else if nativeVideoWarmBackupEnabled {
                            if activeFallbackProducer != Self.webRTCFallbackBoundedJPEGWarmupProducer {
                                activeFallbackProducer = Self.webRTCFallbackBoundedJPEGWarmupProducer
                                fallbackProducerSwitchReason = "native-warmup-bounded-jpeg"
                                self.logger.info(
                                    """
                                    🔄 WebRTC fallback producer locked for native warmup: \
                                    session=\(sessionID, privacy: .public) \
                                    producer=boundedJPEGWarmupMain \
                                    reason=\(fallbackProducerSwitchReason, privacy: .public) \
                                    maxLongEdge=\(nativeWarmupFallbackJPEGProfile.maxLongEdge, privacy: .public) \
                                    maxTransportBytes=\(nativeWarmupFallbackJPEGProfile.maxTransportFrameBytes, privacy: .public) \
                                    sckLatestAgeMs=\(latestSCKAgeMs.map(String.init) ?? "-", privacy: .public)
                                    """
                                )
                                self.appendWebRTCSessionDiagnostic(
                                    "fallbackProducerSwitch session=\(sessionID) producer=boundedJPEGWarmupMain reason=\(fallbackProducerSwitchReason) maxLongEdge=\(nativeWarmupFallbackJPEGProfile.maxLongEdge) maxTransportBytes=\(nativeWarmupFallbackJPEGProfile.maxTransportFrameBytes) sckLatestAgeMs=\(latestSCKAgeMs.map(String.init) ?? "-")",
                                    sessionID: sessionID
                                )
                            }
                            if Date().timeIntervalSince(lastEncodedFallbackMissReportAt) >= 2.0 {
                                self.logger.info(
                                    """
                                    ℹ️ WebRTC native warmup uses bounded JPEG fallback until native render evidence: \
                                    session=\(sessionID, privacy: .public) \
                                    state=\(nativeVideoHealthState.rawValue, privacy: .public) \
                                    producer=boundedJPEGWarmupMain \
                                    maxLongEdge=\(nativeWarmupFallbackJPEGProfile.maxLongEdge, privacy: .public) \
                                    maxTransportBytes=\(nativeWarmupFallbackJPEGProfile.maxTransportFrameBytes, privacy: .public) \
                                    sckLatestAgeMs=\(latestSCKAgeMs.map(String.init) ?? "-", privacy: .public)
                                    """
                                )
                                self.appendSmokeStatus(
                                    "stream-native-warmup-fallback-main session=\(sessionID) state=\(nativeVideoHealthState.rawValue) producer=boundedJPEGWarmupMain maxLongEdge=\(nativeWarmupFallbackJPEGProfile.maxLongEdge) maxTransportBytes=\(nativeWarmupFallbackJPEGProfile.maxTransportFrameBytes) sckLatestAgeMs=\(latestSCKAgeMs.map(String.init) ?? "-")"
                                )
                                self.appendWebRTCSessionDiagnostic(
                                    "stream-native-warmup-fallback-main session=\(sessionID) state=\(nativeVideoHealthState.rawValue) producer=\(activeFallbackProducer) sckLatestAgeMs=\(latestSCKAgeMs.map(String.init) ?? "-")",
                                    sessionID: sessionID
                                )
                                lastEncodedFallbackMissReportAt = Date()
                            }
                        } else if videoPolicy.usesHardwareEncoder {
                            let outputBaselineAt: Date = {
                                var baseline = lastHardwareFrameAt
                                if lastDirectEncoderStartAt > baseline {
                                    baseline = lastDirectEncoderStartAt
                                }
                                if let requestedAt = awaitingRefreshRequestedAt,
                                   requestedAt > baseline {
                                    baseline = requestedAt
                                }
                                return baseline
                            }()
                            if Date().timeIntervalSince(outputBaselineAt) > 1.0 {
                                self.appendSmokeStatus(
                                    "stream-hardware-wait session=\(sessionID) codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data()))"
                                )
                                if awaitingRefreshToken != nil,
                                   let requestedAt = awaitingRefreshRequestedAt,
                                   Date().timeIntervalSince(lastAwaitingRefreshReportAt) >= 1.0 {
                                    let waitMs = Int((Date().timeIntervalSince(requestedAt) * 1000).rounded())
                                    self.logger.warning(
                                        "⚠️ WebRTC 刷新请求后编码器仍未产出可发送视频帧: session=\(sessionID, privacy: .public) refreshTokenState=present waitMs=\(waitMs, privacy: .public) probable=encoder-no-output"
                                    )
                                    lastAwaitingRefreshReportAt = Date()
                                }
                            }
                            continue
                        }
                    }
#endif
                    if capturedFrame == nil {
                        if failFastMediaFallbacks {
                            recordStrictMediaValidationFailure(
                                reason: "degraded-screen-fallback-forbidden",
                                probable: "native-video-or-hardware-encoded-frame-unavailable",
                                config: streamConfig
                            )
                            break
                        }
                        let captureStartedAt = Date()
                        let capturedImage = CGDisplayCreateImage(CGMainDisplayID())
                        cgDisplayCaptureMsTotal += Int((Date().timeIntervalSince(captureStartedAt) * 1000).rounded())
                        guard let img = capturedImage else {
                            continue
                        }
                        let nativeVideoFallbackMain =
                            session.supportsNativeScreenVideoTrack && nativeVideoFallbackDrivingMain
                        let damageTrackingEnabled = (self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.damageTrackingEnabled ?? true)
                            && !nativeVideoFallbackMain
                        if damageTrackingEnabled {
                            if let report = damageTracker.analyze(image: img) {
                                pendingDamageReport = report
                            } else {
                                continue
                            }
                        }
                        let outputImage = img
                        let jpegStartedAt = Date()
                        let jpegResult: (image: CGImage, data: Data, quality: CGFloat)?
                        if nativeVideoFallbackMain {
                            jpegResult = degradedFallbackJPEGData(
                                from: outputImage,
                                profile: nativeWarmupFallbackJPEGProfile
                            )
                        } else {
                            jpegResult = jpegData(from: outputImage, quality: 0.55).map {
                                (image: outputImage, data: $0, quality: 0.55)
                            }
                        }
                        guard let jpegResult else { continue }
                        jpegEncodeMsTotal += Int((Date().timeIntervalSince(jpegStartedAt) * 1000).rounded())
                        cgDisplayFallbackFrames += 1
                        if nativeVideoFallbackMain {
                            activeFallbackProducer = Self.webRTCFallbackBoundedJPEGWarmupProducer
                            lastFallbackSignature = "jpeg \(jpegResult.image.width)x\(jpegResult.image.height)"
                        }
                        capturedFrame = ScreenDataWire(
                            width: jpegResult.image.width,
                            height: jpegResult.image.height,
                            imageData: jpegResult.data,
                            timestamp: Date().timeIntervalSince1970,
                            format: "jpeg",
                            isSyncFrame: true,
                            sequenceNumber: fallbackFrameSequence.next()
                        )
                    }
                    guard let sd = capturedFrame else {
                        continue
                    }
                    let nativeWarmupNativeReady =
                        self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.nativeVideoTrackReady == true
                    if Self.shouldDropNativeWarmupNonJPEGFallbackFrame(
                        supportsNativeVideoTrack: session.supportsNativeScreenVideoTrack,
                        nativeVideoTrackReady: nativeWarmupNativeReady,
                        format: sd.format
                    ) {
                        nativeWarmupNonJPEGFallbackDrops += 1
                        let now = Date()
                        if now.timeIntervalSince(lastNativeWarmupNonJPEGFallbackDropReportAt) >= 1.0 {
                            lastNativeWarmupNonJPEGFallbackDropReportAt = now
                            self.logger.warning(
                                """
                                ⚠️ WebRTC native warmup dropped non-JPEG fallback before screen-channel send: \
                                session=\(sessionID, privacy: .public) \
                                format=\(sd.format ?? "unknown", privacy: .public) \
                                size=\(sd.width, privacy: .public)x\(sd.height, privacy: .public) \
                                producer=\(activeFallbackProducer, privacy: .public) \
                                dropReason=native-warmup-non-jpeg-fallback
                                """
                            )
                            self.appendWebRTCSessionDiagnostic(
                                "screenFallbackDrop session=\(sessionID) dropReason=native-warmup-non-jpeg-fallback format=\(sd.format ?? "unknown") size=\(sd.width)x\(sd.height) producer=\(activeFallbackProducer)",
                                sessionID: sessionID
                            )
                            self.appendSmokeStatus(
                                "screen-drop session=\(sessionID) dropReason=native-warmup-non-jpeg-fallback format=\(sd.format ?? "unknown") size=\(sd.width)x\(sd.height)"
                            )
                        }
                        continue
                    }
                    if let damageReport = pendingDamageReport,
                       let damagePayload = try? JSONEncoder().encode(damageReport),
                       let damageEnvelope = try? JSONEncoder().encode(
                        RemoteMessageWire(type: .damageReport, payload: damagePayload)
                       ) {
                        do {
                            let damageCiphertext = try encryptAppPayload(
                                damageEnvelope,
                                with: keys,
                                packetType: .remoteControl
                            )
                            let paddedDamage = TrafficPadding.wrapIfEnabled(damageCiphertext, label: "tx/webrtc-damage")
                            try await session.sendFramedPayloadAsync(
                                paddedDamage,
                                maxChunkBytes: screenFrameChunkBytes,
                                maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes
                            )
                            bytesSent += paddedDamage.count + 4
                            pendingDamageReport = nil
                        } catch {
                            self.logger.debug(
                                "ℹ️ WebRTC damageReport 发送失败: session=\(sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                    let formatLabel = sd.format ?? "unknown"
                    let isIndependentFrame = RemoteDesktopScreenFrameWire.containsSyncFrame(
                        format: sd.format,
                        imageData: sd.imageData,
                        advertisedSyncFrame: sd.isSyncFrame
                    )
                    let screenBufferedBeforeSend = useDedicatedScreenChannel
                        ? session.screenDataChannelBufferedAmountBytes()
                        : session.dataChannelBufferedAmountBytes()
                    let nativeWarmupNativeReadyBeforeSend =
                        self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.nativeVideoTrackReady == true
                    if Self.shouldThrottleNativeWarmupJPEGFallback(
                        supportsNativeVideoTrack: session.supportsNativeScreenVideoTrack,
                        nativeVideoTrackReady: nativeWarmupNativeReadyBeforeSend,
                        bufferedAmount: screenBufferedBeforeSend,
                        maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes
                    ) {
                        framesDroppedBackpressure += 1
                        if Date().timeIntervalSince(lastBackpressureReportAt) >= 1.0 {
                            self.logger.warning(
                                "⚠️ WebRTC native warmup JPEG backpressure: drop encoded warmup frame before send. session=\(sessionID, privacy: .public) screenBuffered=\(Int(screenBufferedBeforeSend), privacy: .public) threshold=\(Int(Self.nativeWarmupJPEGBackpressureThreshold(maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes)), privacy: .public) budget=\(Int(screenSendMaxBufferedAmountBytes), privacy: .public) chunkDropReason=native-warmup-jpeg-backpressure"
                            )
                            self.appendSmokeStatus(
                                "stream-backpressure session=\(sessionID) screenBuffered=\(Int(screenBufferedBeforeSend)) budget=\(Int(screenSendMaxBufferedAmountBytes)) chunkDropReason=native-warmup-jpeg-backpressure dropped=\(framesDroppedBackpressure)"
                            )
                            lastBackpressureReportAt = Date()
                        }
                        continue
                    }
                    if screenBufferedBeforeSend > screenSendMaxBufferedAmountBytes,
                       !isIndependentFrame {
                        framesDroppedBackpressure += 1
                        if Date().timeIntervalSince(lastBackpressureReportAt) >= 1.0 {
                            self.logger.warning(
                                "⚠️ WebRTC 屏幕通道背压丢弃 stale 非关键帧: session=\(sessionID, privacy: .public) screenBuffered=\(Int(screenBufferedBeforeSend), privacy: .public) budget=\(Int(screenSendMaxBufferedAmountBytes), privacy: .public) chunkDropReason=stale-nonkey-backpressure"
                            )
                            self.appendSmokeStatus(
                                "stream-backpressure session=\(sessionID) screenBuffered=\(Int(screenBufferedBeforeSend)) budget=\(Int(screenSendMaxBufferedAmountBytes)) chunkDropReason=stale-nonkey-backpressure dropped=\(framesDroppedBackpressure)"
                            )
                            lastBackpressureReportAt = Date()
                        }
                        continue
                    }
                    if awaitingRefreshToken != nil,
                       let requestedAt = awaitingRefreshRequestedAt {
                        let waitMs = Int((Date().timeIntervalSince(requestedAt) * 1000).rounded())
                        if isIndependentFrame {
                            self.logger.info(
                                "♻️ WebRTC 刷新请求已命中关键帧: session=\(sessionID, privacy: .public) refreshTokenState=present waitMs=\(waitMs, privacy: .public) predictiveBeforeSync=\(predictiveFramesSentAfterRefresh, privacy: .public) format=\(formatLabel, privacy: .public)"
                            )
                            awaitingRefreshToken = nil
                            awaitingRefreshRequestedAt = nil
                            predictiveFramesSentAfterRefresh = 0
                            lastAwaitingRefreshReportAt = .distantPast
                        } else {
                            predictiveFramesSentAfterRefresh += 1
                            if Date().timeIntervalSince(requestedAt) >= 1.0,
                               Date().timeIntervalSince(lastAwaitingRefreshReportAt) >= 1.0 {
                                self.logger.warning(
                                    "⚠️ WebRTC 刷新请求后仍仅发送预测帧: session=\(sessionID, privacy: .public) refreshTokenState=present waitMs=\(waitMs, privacy: .public) predictiveSent=\(predictiveFramesSentAfterRefresh, privacy: .public) probable=missing-keyframe"
                                )
                                lastAwaitingRefreshReportAt = Date()
                            }
                        }
                    }
                    if formatLabel != lastSentFormat {
                        self.appendSmokeStatus(
                            "stream-format session=\(sessionID) format=\(formatLabel) channel=\(useDedicatedScreenChannel ? "screen" : "control")"
                        )
                        lastSentFormat = formatLabel
                    }
                    let plain = RemoteDesktopScreenFrameWire.encode(
                        width: sd.width,
                        height: sd.height,
                        imageData: sd.imageData,
                        timestamp: sd.timestamp,
                        format: sd.format,
                        isSyncFrame: sd.isSyncFrame,
                        sequenceNumber: sd.sequenceNumber
                    )

                    do {
                        let sendStartedAt = Date()
                        let enc = try encryptAppPayload(plain, with: keys, packetType: .remoteDesktop)
                        let padded = TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-screen")
                        let payloadMagic = Self.describeWebRTCScreenPayloadMagic(padded)
                        let wireFormat = useChunkedScreenWire ? WebRTCSession.screenChunkedWireFormat : "length-framed"
                        let chunkCount: Int
                        let framedBytes: Int
                        var sentFrameId: UInt64?
                        if useChunkedScreenWire {
                            let maxPayloadBytes = max(1, screenFrameChunkBytes - WebRTCSession.screenChunkHeaderByteCount)
                            chunkCount = max(1, (padded.count + maxPayloadBytes - 1) / maxPayloadBytes)
                            framedBytes = padded.count + chunkCount * WebRTCSession.screenChunkHeaderByteCount
                            sentFrameId = try await session.sendScreenChunkedPayloadAsync(
                                padded,
                                maxChunkBytes: screenFrameChunkBytes,
                                maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes
                            )
                        } else if useDedicatedScreenChannel {
                            framedBytes = padded.count + 4
                            chunkCount = max(1, (framedBytes + screenFrameChunkBytes - 1) / screenFrameChunkBytes)
                            try await session.sendScreenFramedPayloadAsync(
                                padded,
                                maxChunkBytes: screenFrameChunkBytes,
                                maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes
                            )
                        } else {
                            framedBytes = padded.count + 4
                            chunkCount = max(1, (framedBytes + screenFrameChunkBytes - 1) / screenFrameChunkBytes)
                            try await session.sendFramedPayloadAsync(
                                padded,
                                maxChunkBytes: screenFrameChunkBytes,
                                maxBufferedAmountBytes: screenSendMaxBufferedAmountBytes
                            )
                        }
                        lastSendLatencyMs = Int((Date().timeIntervalSince(sendStartedAt) * 1000).rounded())
                        bytesSent += framedBytes
                        framesSent += 1
                        if framesSent == 1 {
                            logWindowStart = Date()
                        }
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil,
                           framesSent <= 3 {
                            self.appendSmokeStatus(
                                """
                                screen-send session=\(sessionID) wire=\(wireFormat) \
                                screenChannel=\(useDedicatedScreenChannel) screenChannelState=\(screenRoute.state) payloadMagic=\(payloadMagic) \
                                frameId=\(sentFrameId.map(String.init) ?? "-") \
                                framedBytes=\(framedBytes) chunkCount=\(chunkCount) \
                                bytes=\(padded.count) format=\(formatLabel) \
                                sendLatencyMs=\(lastSendLatencyMs) screenBuffered=\(Int(screenBufferedBeforeSend))
                                """
                            )
                        }
                        let elapsed = Date().timeIntervalSince(logWindowStart)
                        if elapsed >= 5.0 {
                            let upMBps = Double(bytesSent) / elapsed / 1024.0 / 1024.0
                            let fps = Double(framesSent) / elapsed
                            let fallbackLoopTickFPS = Double(fallbackLoopTicks) / elapsed
                            let directEncodedFPS = Double(directEncodedFramesTaken) / elapsed
                            let sckLatestFPS = Double(sckLatestFallbackFrames) / elapsed
                            let latestSCKAgeMs = encodedFrameStore.latestAgeMs()
                            let avgSCKLatestAgeMs = sckLatestFallbackFrames > 0
                                ? Double(sckLatestAgeMsTotal) / Double(sckLatestFallbackFrames)
                                : Double(latestSCKAgeMs ?? 0)
                            let cgDisplayFPS = Double(cgDisplayFallbackFrames) / elapsed
                            let avgCGDisplayCaptureMs = cgDisplayFallbackFrames > 0
                                ? Double(cgDisplayCaptureMsTotal) / Double(cgDisplayFallbackFrames)
                                : 0
                            let avgJPEGEncodeMs = cgDisplayFallbackFrames > 0
                                ? Double(jpegEncodeMsTotal) / Double(cgDisplayFallbackFrames)
                                : 0
                            let bufferedAmount = useDedicatedScreenChannel
                                ? session.screenDataChannelBufferedAmountBytes()
                                : session.dataChannelBufferedAmountBytes()
                            self.logger.info(
                                """
                                📈 WebRTC 屏幕推流吞吐: session=\(sessionID, privacy: .public) \
                                up=\(String(format: "%.2f", upMBps), privacy: .public)MB/s \
                                fps=\(String(format: "%.1f", fps), privacy: .public) \
                                wire=\(wireFormat, privacy: .public) screenChannel=\(useDedicatedScreenChannel, privacy: .public) \
                                screenChannelState=\(screenRoute.state, privacy: .public) \
                                frameId=\(sentFrameId.map(String.init) ?? "-", privacy: .public) \
                                fallbackSentFPS=\(String(format: "%.1f", fps), privacy: .public) \
                                fallbackProducer=\(activeFallbackProducer, privacy: .public) \
                                fallbackSignature=\(lastFallbackSignature, privacy: .public) \
                                fallbackLoopTickFPS=\(String(format: "%.1f", fallbackLoopTickFPS), privacy: .public) \
                                directEncodedFPS=\(String(format: "%.1f", directEncodedFPS), privacy: .public) \
                                sckLatestFPS=\(String(format: "%.1f", sckLatestFPS), privacy: .public) \
                                sckLatestAgeMs=\(String(format: "%.1f", avgSCKLatestAgeMs), privacy: .public) \
                                cgdisplayCaptureFPS=\(String(format: "%.1f", cgDisplayFPS), privacy: .public) \
                                cgdisplayCaptureMs=\(String(format: "%.1f", avgCGDisplayCaptureMs), privacy: .public) \
                                jpegEncodeMs=\(String(format: "%.1f", avgJPEGEncodeMs), privacy: .public) \
                                sendSuccessFPS=\(String(format: "%.1f", fps), privacy: .public) \
                                payloadMagic=\(payloadMagic, privacy: .public) screenBuffered=\(Int(bufferedAmount), privacy: .public) \
                                sendLatencyMs=\(lastSendLatencyMs, privacy: .public) dropReason=\(nativeWarmupNonJPEGFallbackDrops > 0 ? "native-warmup-non-jpeg-fallback" : (framesDroppedBackpressure > 0 ? "backpressure" : "none"), privacy: .public) droppedBackpressure=\(framesDroppedBackpressure, privacy: .public) droppedNativeWarmupNonJPEG=\(nativeWarmupNonJPEGFallbackDrops, privacy: .public)
                                """
                            )
                            self.appendSmokeStatus(
                                """
                                stream-stats session=\(sessionID) fps=\(String(format: "%.1f", fps)) \
                                up_mbps=\(String(format: "%.2f", upMBps * 8.0)) \
                                screenBuffered=\(Int(bufferedAmount)) \
                                format=\(formatLabel) wire=\(wireFormat) \
                                screenChannel=\(useDedicatedScreenChannel) screenChannelState=\(screenRoute.state) payloadMagic=\(payloadMagic) \
                                fallbackProducer=\(activeFallbackProducer) fallbackSignature=\(lastFallbackSignature) \
                                fallbackLoopTickFPS=\(String(format: "%.1f", fallbackLoopTickFPS)) \
                                directEncodedFPS=\(String(format: "%.1f", directEncodedFPS)) \
                                sckLatestFPS=\(String(format: "%.1f", sckLatestFPS)) \
                                sckLatestAgeMs=\(String(format: "%.1f", avgSCKLatestAgeMs)) \
                                cgdisplayCaptureFPS=\(String(format: "%.1f", cgDisplayFPS)) \
                                cgdisplayCaptureMs=\(String(format: "%.1f", avgCGDisplayCaptureMs)) \
                                jpegEncodeMs=\(String(format: "%.1f", avgJPEGEncodeMs)) \
                                sendSuccessFPS=\(String(format: "%.1f", fps)) \
                                frameId=\(sentFrameId.map(String.init) ?? "-") \
                                framedBytes=\(framedBytes) chunkCount=\(chunkCount) \
                                sendLatencyMs=\(lastSendLatencyMs) dropReason=\(nativeWarmupNonJPEGFallbackDrops > 0 ? "native-warmup-non-jpeg-fallback" : (framesDroppedBackpressure > 0 ? "backpressure" : "none")) droppedBackpressure=\(framesDroppedBackpressure) droppedNativeWarmupNonJPEG=\(nativeWarmupNonJPEGFallbackDrops)
                                """
                            )
                            if self.remoteDesktopNetworkStatsEnabled {
                                self.appendWebRTCSessionDiagnostic(
                                    """
                                    stream-stats session=\(sessionID) fps=\(String(format: "%.1f", fps)) \
                                    screenBuffered=\(Int(bufferedAmount)) format=\(formatLabel) wire=\(wireFormat) \
                                    screenChannel=\(useDedicatedScreenChannel) screenChannelState=\(screenRoute.state) payloadMagic=\(payloadMagic) \
                                    fallbackProducer=\(activeFallbackProducer) fallbackSignature=\(lastFallbackSignature) \
                                    fallbackLoopTickFPS=\(String(format: "%.1f", fallbackLoopTickFPS)) \
                                    directEncodedFPS=\(String(format: "%.1f", directEncodedFPS)) \
                                    sckLatestFPS=\(String(format: "%.1f", sckLatestFPS)) \
                                    sckLatestAgeMs=\(String(format: "%.1f", avgSCKLatestAgeMs)) \
                                    cgdisplayCaptureFPS=\(String(format: "%.1f", cgDisplayFPS)) \
                                    cgdisplayCaptureMs=\(String(format: "%.1f", avgCGDisplayCaptureMs)) \
                                    jpegEncodeMs=\(String(format: "%.1f", avgJPEGEncodeMs)) \
                                    sendSuccessFPS=\(String(format: "%.1f", fps)) \
                                    sendLatencyMs=\(lastSendLatencyMs) dropReason=\(nativeWarmupNonJPEGFallbackDrops > 0 ? "native-warmup-non-jpeg-fallback" : (framesDroppedBackpressure > 0 ? "backpressure" : "none")) droppedNativeWarmupNonJPEG=\(nativeWarmupNonJPEGFallbackDrops)
                                    """,
                                    sessionID: sessionID
                                )
                                WebRTCMediaDiagnosticWriter.append(
                                    WebRTCMediaDiagnosticEvent(
                                        sessionId: sessionID,
                                        kind: "videoStats",
                                        probable: nativeWarmupNonJPEGFallbackDrops > 0
                                            ? "native-warmup-non-jpeg-fallback"
                                            : (framesDroppedBackpressure > 0 ? "backpressure" : (fps <= 2.0 ? "low-fps" : nil)),
                                        videoFPS: fps,
                                        fallbackProducer: activeFallbackProducer,
                                        nativeVideoHealth: nativeVideoHealthState.rawValue,
                                        screenBuffered: Int(bufferedAmount)
                                    )
                                )
                            }
                            bytesSent = 0
                            framesSent = 0
                            framesDroppedBackpressure = 0
                            nativeWarmupNonJPEGFallbackDrops = 0
                            fallbackLoopTicks = 0
                            directEncodedFramesTaken = 0
                            sckLatestFallbackFrames = 0
                            sckLatestAgeMsTotal = 0
                            cgDisplayFallbackFrames = 0
                            cgDisplayCaptureMsTotal = 0
                            jpegEncodeMsTotal = 0
                            logWindowStart = Date()
                        }
                    } catch WebRTCSession.WebRTCError.screenFrameBudgetExceeded(
                        let framedBytes,
                        let bufferedAmount,
                        let maxBufferedAmountBytes
                    ) {
                        if failFastMediaFallbacks {
                            recordStrictMediaValidationFailure(
                                reason: "screen-frame-whole-budget-exceeded",
                                probable: "datachannel-screen-backpressure",
                                config: streamConfig
                            )
                            break
                        }
                        framesDroppedBackpressure += 1
                        if Date().timeIntervalSince(lastBackpressureReportAt) >= 1.0 {
                            self.logger.warning(
                                "⚠️ WebRTC SBC2 整帧预算不足，丢弃当前屏幕帧: session=\(sessionID, privacy: .public) framedBytes=\(framedBytes, privacy: .public) screenBuffered=\(Int(bufferedAmount), privacy: .public) budget=\(Int(maxBufferedAmountBytes), privacy: .public) chunkDropReason=whole-frame-budget"
                            )
                            self.appendSmokeStatus(
                                "stream-backpressure session=\(sessionID) screenBuffered=\(Int(bufferedAmount)) budget=\(Int(maxBufferedAmountBytes)) framedBytes=\(framedBytes) chunkDropReason=whole-frame-budget dropped=\(framesDroppedBackpressure)"
                            )
                            lastBackpressureReportAt = Date()
                        }
                        continue
                    } catch {
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            self.appendSmokeStatus(
                                "screen-send-failed session=\(sessionID) sendPartialFailure=1 error=\(error.localizedDescription)"
                            )
                        }
                        self.logger.error("❌ WebRTC 屏幕推流发送失败: \(error.localizedDescription, privacy: .public)")
                        break
                    }
                }
#if os(macOS)
                directSyntheticAudioToneSource?.stop()
                directSyntheticAudioToneSource = nil
                await directAudioFallbackSender?.close()
                directAudioFallbackSender = nil
#endif
            }
        }

        defer {
            initialHandshakeTask?.cancel()
        }

        logger.info("🤝 WebRTC 控制通道：启动入站握手/消息循环 session=\(sessionID, privacy: .public)")

        let maxInboundFrameBytes = 8_000_000
        var lastInboundFrameLength = 0
        var lastDecodedFrameLength = 0
        var lastHandshakeDriverState = "none"
        var lastControlLoopEvent = "start"

        do {
            while true {
                let lenData = try await receiveExactly(4)
                let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                lastInboundFrameLength = Int(totalLen)
                guard totalLen > 0 && totalLen <= maxInboundFrameBytes else {
                    logger.warning("⚠️ WebRTC frame length out of range: len=\(Int(totalLen), privacy: .public) max=\(maxInboundFrameBytes, privacy: .public)")
                    break
                }
                let payload = try await receiveExactly(Int(totalLen))
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac rx frame totalLen=\(Int(totalLen))")
                }

                let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
                let frame = HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx/webrtc")
                lastDecodedFrameLength = frame.count

                if let activeDriver = handshakeState.driver {
                    let driverState = await activeDriver.getCurrentState()
                    lastHandshakeDriverState = String(describing: driverState)
                    if case .waitingFinished(_, _, .initiator) = driverState,
                       (try? HandshakeMessageA.decode(from: frame)) != nil {
                        lastControlLoopEvent = "duplicate_message_a_while_waiting_finished"
                        logger.warning(
                            "♻️ WebRTC responder ignored duplicate fresh MessageA while waiting for Finished: session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public) frameBytes=\(frame.count, privacy: .public)"
                        )
                        continue
                    }
                }

                if let keys = handshakeState.sessionKeys,
                   !isLikelyHandshakeControlPacket(frame),
                   !(handshakeState.driver != nil && isActiveHandshakeDriverFrame(frame)) {
                    do {
                        let openedPayload = try decryptAppPayload(frame, with: keys)
                        let plaintext = openedPayload.payload
                        if openedPayload.packetType == .appControl,
                           let msg = decodeCompatibilityAppMessage(plaintext) {
                            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                switch msg {
                                case .pairingIdentityExchange(let payload):
                                    print("🧪 mac app message=pairingIdentityExchange deviceId=\(payload.deviceId) keys=\(payload.kemPublicKeys.count)")
                                case .kemRefreshRequest(let payload):
                                    print("🧪 mac app message=kemRefreshRequest target=\(payload.targetDeviceId)")
                                case .signedKEMRefresh(let payload):
                                    print("🧪 mac app message=signedKEMRefresh deviceId=\(payload.deviceId) keys=\(payload.kemPublicKeys.count)")
                                case .kemRefreshFailure(let payload):
                                    print("🧪 mac app message=kemRefreshFailure reasonCode=\(payload.reasonCode)")
                                case .protocolIdentityBindingRequest(let payload):
                                    print("🧪 mac app message=protocolIdentityBindingRequest target=\(payload.targetDeviceId)")
                                case .signedProtocolIdentityBinding(let payload):
                                    print("🧪 mac app message=signedProtocolIdentityBinding deviceId=\(payload.deviceId)")
                                case .heartbeat:
                                    print("🧪 mac app message=heartbeat")
                                case .clipboard:
                                    print("🧪 mac app message=clipboard")
                                case .peerDisconnecting(let payload):
                                    print("🧪 mac app message=peerDisconnecting deviceId=\(payload.deviceId ?? "nil")")
                                case .ping(let payload):
                                    print("🧪 mac app message=ping id=\(payload.id)")
                                case .pong(let payload):
                                    print("🧪 mac app message=pong id=\(payload.id)")
	                                }
	                            }
                            if self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionID) {
                                let messageKind = bootstrapAppMessageKind(msg)
                                switch WebRTCBootstrapAppMessagePolicy.admission(for: msg) {
                                case .continueBootstrapSecurityFlow:
                                    break
                                case .consumeLivenessLocally:
                                    switch msg {
                                    case .heartbeat(let payload):
                                            self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                                            self.updateCrossNetworkRemoteMetadata(
                                                sessionID: sessionID,
                                                deviceId: payload.deviceId,
                                                deviceName: payload.deviceName
                                            )
                                            self.noteWebRTCRemoteSecurityIdentity(
                                                sessionID: sessionID,
                                                accountDisplayName: payload.accountDisplayName,
                                                nebulaId: payload.nebulaId,
                                                deviceId: payload.deviceId,
                                                deviceName: payload.deviceName
                                            )
                                            logger.debug(
                                                "ℹ️ WebRTC strictPQC classic bootstrap accepted control app message before PQC rekey: session=\(sessionID, privacy: .public) type=\(messageKind, privacy: .public) lastRekey=\(self.lastRekeyEvent ?? "-", privacy: .public)"
                                            )
                                            continue
                                    case .ping(let payload):
                                            self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                                            logger.debug(
                                                "ℹ️ WebRTC strictPQC classic bootstrap accepted control app message before PQC rekey: session=\(sessionID, privacy: .public) type=\(messageKind, privacy: .public) lastRekey=\(self.lastRekeyEvent ?? "-", privacy: .public)"
                                            )
                                            let reply = AppMessage.pong(.init(id: payload.id))
                                            let outPlain = try JSONEncoder().encode(reply)
                                            let outCipher = try encryptAppPayload(outPlain, with: keys)
                                            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-pong")
                                            try await sendFramed(outPadded)
                                            continue
                                    case .pong, .peerDisconnecting:
                                            self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                                            logger.debug(
                                                "ℹ️ WebRTC strictPQC classic bootstrap accepted control app message before PQC rekey: session=\(sessionID, privacy: .public) type=\(messageKind, privacy: .public) lastRekey=\(self.lastRekeyEvent ?? "-", privacy: .public)"
                                            )
                                            continue
                                    default:
                                        continue
                                    }
                                case .dropUntilPQCRekey:
                                    logger.debug(
                                        "ℹ️ WebRTC strictPQC classic bootstrap ignored non-bootstrap app message: session=\(sessionID, privacy: .public) type=\(messageKind, privacy: .public) lastRekey=\(self.lastRekeyEvent ?? "-", privacy: .public)"
                                    )
                                    continue
                                }
                            }
		                            switch msg {
		                            case .pairingIdentityExchange(let rawPayload):
                                guard let payload = rawPayload.normalizedBootstrapPayload else {
                                    logger.warning(
                                        "⚠️ WebRTC pairingIdentityExchange ignored: empty declaredDeviceId or empty KEM public key session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public)"
                                    )
                                    break
                                }
                                let remoteFormatsSummary = (payload.remoteVideoFormats ?? []).joined(separator: ",")
                                self.appendSmokeStatus(
                                    "app-pairing-recv session=\(sessionID) formats=\(remoteFormatsSummary)"
                                )
                                self.updateCrossNetworkRemoteMetadata(
                                    sessionID: sessionID,
                                    deviceId: payload.deviceId,
                                    deviceName: payload.deviceName
                                )
                                self.noteWebRTCRemoteSecurityIdentity(
                                    sessionID: sessionID,
                                    accountDisplayName: payload.accountDisplayName,
                                    nebulaId: payload.nebulaId,
                                    deviceId: payload.deviceId,
                                    deviceName: payload.deviceName
                                )
                                self.webrtcRemoteVideoFormatsBySessionId[sessionID] = Set(
                                    (payload.remoteVideoFormats ?? []).map { $0.lowercased() }
                                )
                                let policyBindingKey = self.currentPathExpectedRemoteAuthorityBySessionId[sessionID].flatMap { authority in
                                    PairingTrustApprovalService.policyBindingKey(
                                        declaredDeviceId: payload.deviceId,
                                        algorithmRawValue: authority.protocolSigningAlgorithm.rawValue,
                                        protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint
                                    )
                                }
                                let request = PairingTrustApprovalService.Request(
                                    peerEndpoint: endpointDescription,
                                    declaredDeviceId: payload.deviceId,
                                    policyBindingKey: policyBindingKey,
                                    displayName: payload.deviceName ?? payload.deviceId,
                                    model: payload.modelName,
                                    platform: payload.platform,
                                    osVersion: payload.osVersion,
                                    kemKeyCount: payload.kemPublicKeys.count
                                )
                                let decision = await PairingTrustApprovalService.shared.decide(for: request)
                                self.appendSmokeStatus(
                                    "app-pairing-decision session=\(sessionID) decision=\(decision.rawValue)"
                                )
                                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                    print("🧪 mac pairing decision=\(decision.rawValue)")
                                }
                                guard decision != PairingTrustApprovalService.Decision.reject else { break }
                                let sendPairingReply = sendFramed
	                                Task { @MainActor [weak self] in
                                    guard let self else { return }

                                    await PeerKEMBootstrapStore.shared.upsert(
                                        deviceIds: orderedUniqueCandidateIds([
                                            payload.deviceId,
                                            peerDeviceId,
                                            endpointDescription
                                        ]),
                                        kemPublicKeys: payload.kemPublicKeys
                                    )
                                    logger.info(
                                        "🔑 WebRTC bootstrap KEM cache updated: declared=\(payload.deviceId, privacy: .public) peer=\(endpointDescription, privacy: .public) keys=\(payload.kemPublicKeys.count, privacy: .public)"
                                    )
                                    self.recordCurrentPathProtocolFingerprints(
                                        from: payload,
                                        sessionID: sessionID,
                                        peerDeviceId: peerDeviceId
                                    )

                                    let provider: any CryptoProvider = CryptoProviderFactory.make(policy: .preferPQC)
                                    let km = DeviceIdentityKeyManager.shared
                                    let kemKeys: [KEMPublicKeyInfo]
                                    do {
                                        kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
                                            try await km.pairingIdentityKEMPublicKeys(using: provider)
                                        )
                                    } catch {
                                        logger.warning("⚠️ WebRTC bootstrap reply KEM 公钥准备失败: \(error.localizedDescription, privacy: .public)")
                                        self.appendSmokeStatus(
                                            "app-pairing-send-failed session=\(sessionID) stage=prepare_kem error=\(sanitizeStatus(error.localizedDescription))"
                                        )
                                        return
                                    }
                                    guard !kemKeys.isEmpty else {
                                        logger.warning("⚠️ WebRTC bootstrap reply skipped: no valid local KEM public keys")
                                        return
                                    }

                                    let localIdRaw = await SelfIdentityProvider.shared.protocolIdentityDeviceId(allowCreate: true)
                                    let localId = localIdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !localId.isEmpty else {
                                        logger.warning("⚠️ WebRTC bootstrap reply skipped: empty local deviceId")
                                        self.appendSmokeStatus(
                                            "app-pairing-send-skipped session=\(sessionID) stage=empty_local_device_id"
                                        )
                                        return
                                    }
                                    let localIdentity = RemoteControlSecurityNoticeCenter.shared.localIdentitySnapshot()
                                    let replyPayload = CrossNetworkWebRTCLocalAppMessageFactory.pairingIdentityExchangePayload(
                                        deviceId: localId,
                                        kemPublicKeys: kemKeys,
                                        protocolIdentityPublicKeys: await self.localProtocolIdentityPublicKeysForPairing(),
                                        remoteVideoFormats: Self.supportedRemoteVideoFormats(),
                                        accountDisplayName: localIdentity?.accountDisplayName,
                                        nebulaId: localIdentity?.nebulaId
                                    )
                                    let replyFingerprint = pairingExchangeFingerprint(replyPayload)
                                    if self.webrtcBootstrapReplyFingerprintBySessionId[sessionID] == replyFingerprint {
                                        await maybeStartOutboundPQCRekeyIfNeeded(
                                            from: payload,
                                            trigger: "pairing_exchange"
                                        )
                                        return
                                    }
                                    let reply = AppMessage.pairingIdentityExchange(replyPayload)
                                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                        print("🧪 mac pairing reply deviceId=\(localId) keys=\(kemKeys.count)")
                                        print("🧪 mac pairing reply provider=\(String(describing: type(of: provider)))")
                                        let digests = kemKeys
                                            .sorted { $0.suiteWireId < $1.suiteWireId }
                                            .map { key in
                                                let digest = SHA256.hash(data: key.publicKey).prefix(8)
                                                    .map { String(format: "%02x", $0) }
                                                    .joined()
                                                return String(format: "0x%04x:%@", key.suiteWireId, digest)
                                            }
                                            .joined(separator: ",")
                                        print("🧪 mac pairing reply KEM digests=\(digests)")
                                    }
                                    self.appendSmokeStatus(
                                        "app-pairing-send session=\(sessionID) deviceId=\(localId) keys=\(kemKeys.count)"
                                    )
                                    do {
                                        let outPlain = try JSONEncoder().encode(reply)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc")
                                        try await sendPairingReply(outPadded)
                                        self.webrtcBootstrapReplyFingerprintBySessionId[sessionID] = replyFingerprint
                                        if let rawDelay = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_DELAY_HOST_PQC_REKEY_SECONDS"],
                                           let delaySeconds = Double(rawDelay.trimmingCharacters(in: .whitespacesAndNewlines)),
                                           delaySeconds > 0 {
                                            self.appendSmokeStatus(
                                                "rekey-delay session=\(sessionID) seconds=\(delaySeconds)"
                                            )
                                            try? await Task.sleep(for: .milliseconds(Int(delaySeconds * 1000)))
                                        }
                                        await maybeStartOutboundPQCRekeyIfNeeded(
                                            from: payload,
                                            trigger: "pairing_exchange"
                                        )
                                    } catch {
                                        self.appendSmokeStatus(
                                            "app-pairing-send-failed session=\(sessionID) stage=send error=\(sanitizeStatus(error.localizedDescription))"
                                        )
                                    }
	                                }
	                            case .heartbeat(let payload):
	                                let remoteFormatsSummary = (payload.remoteVideoFormats ?? []).joined(separator: ",")
	                                self.appendSmokeStatus(
                                    "app-heartbeat-recv session=\(sessionID) formats=\(remoteFormatsSummary)"
                                )
                                self.appendRemoteMediaHeartbeatSmokeStatus(
                                    payload.webrtcMedia,
                                    sessionID: sessionID
                                )
                                self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                                self.updateCrossNetworkRemoteMetadata(
                                    sessionID: sessionID,
                                    deviceId: payload.deviceId,
                                    deviceName: payload.deviceName
                                )
                                self.noteWebRTCRemoteSecurityIdentity(
                                    sessionID: sessionID,
                                    accountDisplayName: payload.accountDisplayName,
                                    nebulaId: payload.nebulaId,
                                    deviceId: payload.deviceId,
                                    deviceName: payload.deviceName
                                )
                                if let formats = payload.remoteVideoFormats {
                                    self.webrtcRemoteVideoFormatsBySessionId[sessionID] = Set(
                                        formats.map { $0.lowercased() }
                                    )
                                }
                                startScreenStreamingIfNeeded(keys: keys)
                            case .ping(let payload):
                                self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                                startScreenStreamingIfNeeded(keys: keys)
                                let reply = AppMessage.pong(.init(id: payload.id))
                                let outPlain = try JSONEncoder().encode(reply)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-pong")
                                try await sendFramed(outPadded)
                            case .pong:
                                self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                            default:
                                break
	                            }
	                            continue
	                        } else if self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionID) {
	                            logger.debug(
	                                "ℹ️ WebRTC strictPQC classic bootstrap ignored business payload before PQC rekey: session=\(sessionID, privacy: .public)"
	                            )
	                            continue
		                        } else if openedPayload.packetType == .fileTransfer,
                                      let ft = try? JSONDecoder().decode(CrossNetworkFileTransferMessage.self, from: plaintext),
                                      ft.version == 1 {
                                guard RemoteDesktopSettingsManager.shared.settings.interactionSettings.enableFileTransfer else {
                                    let response = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        message: "remote_desktop_file_transfer_disabled_by_settings"
                                    )
                                    let outPlain = try JSONEncoder().encode(response)
                                    let outCipher = try encryptAppPayload(
                                        outPlain,
                                        with: keys,
                                        packetType: .fileTransfer
                                    )
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-disabled")
                                    try await sendFramed(outPadded)
                                    self.failFileTransferWaiters(
                                        sessionID: sessionID,
                                        transferId: ft.transferId,
                                        message: "remote_desktop_file_transfer_disabled_by_settings"
                                    )
                                    continue
                                }
	                            try await inboundFileTransferReceiver.handle(
	                                ft,
	                                sessionID: sessionID,
	                                endpointDescription: endpointDescription,
	                                keys: keys,
	                                sendMessage: { response, label in
	                                    let outPlain = try JSONEncoder().encode(response)
	                                    let outCipher = try encryptAppPayload(
                                        outPlain,
                                        with: keys,
                                        packetType: .fileTransfer
                                    )
	                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: label)
	                                    try await sendFramed(outPadded)
	                                },
	                                failSenderWaiters: { transferId, message in
	                                    self.failFileTransferWaiters(
	                                        sessionID: sessionID,
	                                        transferId: transferId,
	                                        message: message
	                                    )
	                                },
	                                resumeSenderWaiter: { message in
	                                    self.resumeFileTransferWaiter(sessionID: sessionID, message: message)
	                                }
	                            )
	                            continue
	                        } else if openedPayload.packetType == .remoteControl,
                                      let rm = try? JSONDecoder().decode(RemoteMessageWire.self, from: plaintext) {
                            guard RemoteControlSecurityAdmissionPolicy.allowsInboundWebRTCPayload(
                                rm.type,
                                isApproved: self.webrtcRemoteControlNoticeApprovedSessionIds.contains(sessionID)
                            ) else {
                                self.logger.warning(
                                    "⛔️ 未经批准的 WebRTC 远控消息被阻断: session=\(sessionID, privacy: .public) type=\(rm.type.rawValue, privacy: .public)"
                                )
                                self.appendSmokeStatus(
                                    "remoteControlPayloadBlocked session=\(sessionID) transport=webrtc type=\(rm.type.rawValue)"
                                )
                                continue
                            }
                            switch rm.type {
                            case .mouseEvent:
                                if let evt = try? JSONDecoder().decode(MouseEventWire.self, from: rm.payload) {
                                    WebRTCRemoteControlInputEventBridge.handleMouseEvent(evt)
                                }
                            case .keyboardEvent:
                                if let evt = try? JSONDecoder().decode(KeyboardEventWire.self, from: rm.payload) {
                                    WebRTCRemoteControlInputEventBridge.handleKeyboardEvent(evt)
                                }
                            case .clipboard:
                                if let payload = try? JSONDecoder().decode(RemoteClipboardPayload.self, from: rm.payload) {
                                    configureWebRTCClipboardSyncIfNeeded(for: sessionID, session: session)
                                    ClipboardRedirectionManager.shared.setRemoteClipboard(
                                        data: payload.data,
                                        mimeType: payload.mimeType
                                    )
                                }
	                            case .streamConfiguration:
	                                if let config = try? JSONDecoder().decode(RemoteDesktopStreamConfiguration.self, from: rm.payload) {
	                                    let previousConfig = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]
	                                    let activeKeysForAck = handshakeState.sessionKeys
	                                        ?? self.webrtcSessionKeysBySessionId[sessionID]
	                                    let plan = Self.planWebRTCStreamConfigurationIngress(
	                                        config,
	                                        previousConfig: previousConfig,
	                                        advertisedFormats: self.webrtcRemoteVideoFormatsBySessionId[sessionID] ?? [],
	                                        hasSessionKeys: activeKeysForAck != nil
                                    )
                                    if plan.audioEndpointPreservedForVideoRefresh {
                                        self.appendWebRTCSessionDiagnostic(
                                            "audioEndpointPreservedForVideoRefresh session=\(sessionID) refreshTokenState=\(Self.streamRefreshTokenLogState(config.streamRefreshToken))",
                                            sessionID: sessionID
                                        )
                                    }
	                                    let effectiveConfig = plan.effectiveConfig
	                                    self.webrtcRemoteStreamConfigurationBySessionId[sessionID] = effectiveConfig
	                                    self.webrtcRemoteVideoFormatsBySessionId[sessionID] = plan.remoteVideoFormats
	                                    if plan.shouldClearPendingStreamRefresh {
	                                        self.webrtcPendingStreamRefreshSessionIds.remove(sessionID)
	                                    }
	                                    if plan.shouldClearAwaitingStreamConfiguration {
	                                        self.webrtcAwaitingStreamConfigurationSessionIds.remove(sessionID)
	                                    }
	                                    if plan.shouldStopScreenStreaming {
	                                        self.stopWebRTCScreenStreaming(sessionID: sessionID)
	                                        self.configureWebRTCClipboardSyncIfNeeded(for: sessionID, session: session)
	                                        self.logger.info(
	                                            "⏹️ WebRTC viewer 请求停止远控推流: session=\(sessionID, privacy: .public) previousTransport=\(previousConfig?.screenFrameTransport ?? "none", privacy: .public)"
	                                        )
	                                        continue
	                                    }
	                                    if plan.shouldEnsureScreenDataChannel {
	                                        try? session.ensureScreenDataChannel()
	                                    }
	                                    self.logger.info(
                                        """
                                        🎛️ WebRTC 收到远控流策略: session=\(sessionID, privacy: .public) \
                                        transport=\(effectiveConfig.screenFrameTransport ?? "legacy", privacy: .public) \
                                        screenWire=\(effectiveConfig.screenChannelWireFormat ?? "length-framed", privacy: .public) \
                                        preset=\(effectiveConfig.qualityPreset ?? "unknown", privacy: .public) \
                                        nativeReady=\(effectiveConfig.nativeVideoTrackReady == true, privacy: .public) \
                                        audioRequested=\(effectiveConfig.requestsRealtimeMediaAudio, privacy: .public) \
                                        audioTransport=\(effectiveConfig.audioTransport ?? "nil", privacy: .public) \
                                        audioEndpoint=\(effectiveConfig.mediaAudioEndpoint == nil ? "missing" : "present", privacy: .public) \
                                        audioRelayToken=\(effectiveConfig.mediaAudioEndpoint?.relayToken == nil ? "missing" : "present", privacy: .public) \
                                        audioMode=\(effectiveConfig.requestedMediaAudioMode.rawValue, privacy: .public) \
                                        damage=\(effectiveConfig.damageTrackingEnabled ?? false, privacy: .public) \
                                        cursor=\(effectiveConfig.separateCursorChannelEnabled ?? false, privacy: .public) \
                                        overlay=\(effectiveConfig.interactionOverlayChannelEnabled ?? false, privacy: .public) \
                                        jitter=\(effectiveConfig.jitterBufferFrames ?? 0, privacy: .public) \
                                        recovery=\(effectiveConfig.lossRecoveryMode ?? "unknown", privacy: .public)
                                        """
                                    )
                                    self.appendWebRTCSessionDiagnostic(
                                        """
                                        streamConfigReceived session=\(sessionID) transport=\(effectiveConfig.screenFrameTransport ?? "legacy") \
                                        screenWire=\(effectiveConfig.screenChannelWireFormat ?? "length-framed") \
                                        nativeReady=\(effectiveConfig.nativeVideoTrackReady == true) \
                                        audioRequested=\(effectiveConfig.requestsRealtimeMediaAudio) \
                                        audioEndpoint=\(effectiveConfig.mediaAudioEndpoint == nil ? "missing" : "present") \
                                        audioRelayToken=\(effectiveConfig.mediaAudioEndpoint?.relayToken == nil ? "missing" : "present") \
                                        refreshTokenState=\(Self.streamRefreshTokenLogState(effectiveConfig.streamRefreshToken))
                                        """,
                                        sessionID: sessionID
                                    )
	                                    if plan.shouldSendAcknowledgement,
	                                       let activeKeys = activeKeysForAck,
	                                       let acknowledgement = plan.acknowledgement {
	                                        let ack = acknowledgement.payload(acceptedAt: Date().timeIntervalSince1970)
	                                        do {
	                                            try await sendRealtimeRemoteControlPayload(
	                                                ack,
                                                type: .streamConfigurationAck,
                                                sessionKeys: activeKeys,
                                                maxBufferedAmountBytes: 96 * 1024,
                                                label: "tx/webrtc-stream-config-ack"
                                            )
                                            self.appendWebRTCSessionDiagnostic(
                                                "streamConfigurationAckSent session=\(sessionID) refreshTokenState=\(Self.streamRefreshTokenLogState(effectiveConfig.streamRefreshToken)) audioEndpoint=\(effectiveConfig.mediaAudioEndpoint == nil ? "missing" : "present")",
                                                sessionID: sessionID
                                            )
                                        } catch {
                                            self.logger.warning(
                                                "⚠️ WebRTC streamConfigurationAck 发送失败: session=\(sessionID, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                                            )
                                            self.appendWebRTCSessionDiagnostic(
                                                "streamConfigurationAckFailed session=\(sessionID) error=\(error.localizedDescription)",
                                                sessionID: sessionID
	                                            )
	                                        }
                                    }
                                    if plan.shouldMarkPendingStreamRefresh {
                                        self.webrtcPendingStreamRefreshSessionIds.insert(sessionID)
                                        if effectiveConfig.streamRefreshToken != nil {
                                            self.logger.info(
                                                "🪄 WebRTC 收到 viewer 关键帧刷新请求: session=\(sessionID, privacy: .public) refreshTokenState=present previousRefreshTokenState=\(Self.streamRefreshTokenLogState(previousConfig?.streamRefreshToken), privacy: .public)"
                                            )
                                        }
                                    }
	                                    if plan.shouldConfigureClipboard {
	                                        self.configureWebRTCClipboardSyncIfNeeded(for: sessionID, session: session)
	                                    }
	                                    if plan.shouldStartScreenStreamingIfNeeded,
	                                       let activeKeys = handshakeState.sessionKeys ?? self.webrtcSessionKeysBySessionId[sessionID] {
	                                        startScreenStreamingIfNeeded(keys: activeKeys)
	                                    }
	                                }
                            case .damageReport, .cursorUpdate, .overlayUpdate:
                                break
                            case .streamConfigurationAck:
                                break
                            case .screenData:
                                break
                            }
                            continue
                        } else {
                            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                let digest = SHA256.hash(data: plaintext)
                                let fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
                                print("🧪 mac app unknown payload length=\(plaintext.count) sha256Prefix=\(fingerprint)")
                            }
                            logger.debug("ℹ️ WebRTC 业务消息解密成功但未匹配已知消息类型")
                            continue
                        }
                    } catch {
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            print("🧪 mac app decrypt/parse failed err=\(error.localizedDescription)")
                        }
                        logger.debug("ℹ️ WebRTC 业务消息解密/解析失败（继续尝试按握手包处理）：\(error.localizedDescription, privacy: .public)")
                    }
                }

                if handshakeState.driver == nil {
                    let decodedMessageA: HandshakeMessageA?
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        do {
                            decodedMessageA = try HandshakeMessageA.decode(from: frame)
                        } catch {
                            print("🧪 mac MessageA decode failed: \(error.localizedDescription)")
                            decodedMessageA = nil
                        }
                    } else {
                        decodedMessageA = try? HandshakeMessageA.decode(from: frame)
                    }
                    if let messageA = decodedMessageA {
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            let suiteSummary = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                            print("🧪 mac rx MessageA bytes=\(frame.count) suites=\(suiteSummary)")
                            let preimageDigest = SHA256.hash(data: messageA.signaturePreimage)
                                .map { String(format: "%02x", $0) }
                                .joined()
                                .prefix(16)
                            let identitySummary = try? IdentityPublicKeys.decodeWithLegacyFallback(from: messageA.identityPublicKey)
                            print(
                                "🧪 mac rx MessageA sigAlg=\(identitySummary?.protocolAlgorithm.rawValue ?? "unknown") " +
                                "pubBytes=\(identitySummary?.protocolPublicKey.count ?? messageA.identityPublicKey.count) " +
                                "sigBytes=\(messageA.signature.count) " +
                                "preimageSha256=\(preimageDigest)"
                            )
                        }
                        if let establishedKeys = handshakeState.sessionKeys {
                            handshakeState.previousSessionKeysBeforeRekey = establishedKeys
                            self.webrtcRekeyInProgressSessionIds.insert(sessionID)
                            if let streamTask = self.webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) {
                                streamTask.cancel()
                            }
                            if let interactionTask = self.webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID) {
                                interactionTask.cancel()
                            }
                            self.lastRekeyEvent = "received peer=\(peerDeviceId)"
                            logger.info(
                                "🔁 WebRTC 收到对端 rekey 请求，暂停旧会话业务流: session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public)"
                            )
                        }

                        let hasHybridGroup = messageA.supportedSuites.contains { $0.isHybrid }
                        let peerOnlyOffersHybrid = hasHybridGroup && messageA.supportedSuites.allSatisfy { $0.isHybrid }
                        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        let handshakePolicy = HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
                        // This pre-selection gate only evaluates the peer offer shape.
                        // Local PQC capability is derived below from the selected provider's offered suites.
                        if let rejection = StrictPQCAdmissionGate.inboundRejection(
                            policy: handshakePolicy,
                            peerSupportedSuites: messageA.supportedSuites,
                            localPQCSuitesAvailable: true
                        ), rejection == .peerOfferedClassicOnly {
                            logger.error(
                                "❌ \(rejection.diagnosticMessage, privacy: .public). session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public)"
                            )
                            self.cleanupWebRTCSession(
                                sessionID,
                                reason: "strict_pqc_peer_offered_classic_only",
                                disconnectKind: .explicit
                            )
                            self.connectionStatus = .failed(rejection.diagnosticMessage)
                            self.readiness = .idle
                            return
                        }
                        guard let responderSelection = Self.selectWebRTCInboundResponder(
                            peerSupportedSuites: messageA.supportedSuites,
                            policy: handshakePolicy
                        ) else {
                            let rejectionMessage = StrictPQCAdmissionRejection.localPQCUnavailable.diagnosticMessage
                            logger.error(
                                "❌ \(rejectionMessage, privacy: .public). session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public)"
                            )
                            self.cleanupWebRTCSession(
                                sessionID,
                                reason: "strict_pqc_inbound_responder_unavailable",
                                disconnectKind: .explicit
                            )
                            self.connectionStatus = .failed(rejectionMessage)
                            self.readiness = .idle
                            return
                        }
                        if responderSelection.fellBackToClassic {
                            SecurityEventEmitter.emitDetached(SecurityEvent(
                                type: .cryptoDowngrade,
                                severity: .warning,
                                message: "WebRTC inbound handshake: peer advertises PQC but local PQC unavailable; falling back to Classic",
                                context: [
                                    "reason": "pqcProviderUnavailable",
                                    "direction": "webrtc_responder_inbound",
                                    "deviceId": peerDeviceId,
                                    "policyRequirePQC": handshakePolicy.requirePQC ? "1" : "0",
                                    "policyAllowClassicFallback": handshakePolicy.allowClassicFallback ? "1" : "0",
                                    "policyMinimumTier": handshakePolicy.minimumTier.rawValue,
                                    "fromStrategy": HandshakeAttemptStrategy.pqcOnly.rawValue,
                                    "toStrategy": HandshakeAttemptStrategy.classicOnly.rawValue,
                                    "strategy": HandshakeAttemptStrategy.classicOnly.rawValue,
                                    "transcriptBinding": "1",
                                    "downgradeResistance": "policy_gate+capability_evidence"
                                ]
                            ))
                            logger.info(
                                "🧩 WebRTC inboundFallback(classic): peer advertises PQC but local PQC unavailable; falling back to classic handshake. session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public)"
                            )
                        }
                        let sigAAlgorithm = responderSelection.sigAAlgorithm
                        let cryptoProvider = responderSelection.cryptoProvider
                        let offeredSuites = responderSelection.offeredSuites
                        let localPQCSuitesAvailable = offeredSuites.contains { $0.isPQCGroup }
                        if let rejection = StrictPQCAdmissionGate.inboundRejection(
                            policy: handshakePolicy,
                            peerSupportedSuites: messageA.supportedSuites,
                            localPQCSuitesAvailable: localPQCSuitesAvailable
                        ) {
                            logger.error(
                                "❌ \(rejection.diagnosticMessage, privacy: .public). session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public)"
                            )
                            self.cleanupWebRTCSession(
                                sessionID,
                                reason: "strict_pqc_inbound_rejection",
                                disconnectKind: .explicit
                            )
                            self.connectionStatus = .failed(rejection.diagnosticMessage)
                            self.readiness = .idle
                            return
                        }
                        let cryptoPolicy: CryptoPolicy = hasHybridGroup
                            ? CryptoPolicy(
                                minimumSecurityTier: peerOnlyOffersHybrid ? .hybridPreferred : .pqcPreferred,
                                allowExperimentalHybrid: true,
                                advertiseHybrid: true,
                                requireHybridIfAvailable: peerOnlyOffersHybrid
                            )
                            : .default

                        let identityProvider = DeviceIdentityHandshakeProvider(
                            sigAAlgorithm: sigAAlgorithm,
                            includeSecureEnclavePoP: handshakePolicy.requireSecureEnclavePoP
                        )
                        let inboundTrustProvider = CurrentPathHandshakeTrustProvider(
                            expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionID],
                            fallbackPeerIDs: orderedUniqueCandidateIds([peerDeviceId, endpointDescription]),
                            additionalTrustedFingerprints: additionalProtocolFingerprints(for: sessionID)
                        )

                        handshakeState.driver = try HandshakeDriver(
                            transport: transport,
                            cryptoProvider: cryptoProvider,
                            protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                            identityProvider: identityProvider,
                            sigAAlgorithm: sigAAlgorithm,
                            offeredSuites: offeredSuites,
                            policy: handshakePolicy,
                            cryptoPolicy: cryptoPolicy,
                            trustProvider: inboundTrustProvider
                        )
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            print("🧪 mac driver init sigA=\(sigAAlgorithm.rawValue) requirePQC=\(handshakePolicy.requirePQC) provider=\(String(describing: type(of: cryptoProvider)))")
                        }
                        if handshakeState.previousSessionKeysBeforeRekey != nil, self.lastRekeyEvent == nil {
                            let suiteSummary = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                            self.lastRekeyEvent = "driver suites=\(suiteSummary)"
                        }
                        logger.info("🤝 WebRTC 入站 HandshakeDriver 初始化完成: sigA=\(sigAAlgorithm.rawValue, privacy: .public) peer=\(peerDeviceId, privacy: .public) policyRequirePQC=\(handshakePolicy.requirePQC, privacy: .public)")
                    } else {
                        continue
                    }
                }

                guard let activeDriver = handshakeState.driver else { continue }
                guard isActiveHandshakeDriverFrame(frame) else {
                    logger.debug(
                        "ℹ️ 跳过非握手控制帧，避免污染握手状态机: session=\(sessionID, privacy: .public) bytes=\(frame.count, privacy: .public)"
                    )
                    continue
                }
                await activeDriver.handleMessage(frame, from: peer)
                let st = await activeDriver.getCurrentState()
                lastHandshakeDriverState = String(describing: st)
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac driver state=\(String(describing: st))")
                }
                switch st {
                case .waitingFinished(_, let keys, _):
                    if handshakeState.previousSessionKeysBeforeRekey != nil,
                       !(self.lastRekeyEvent?.contains("raw=") ?? false) {
                        self.lastRekeyEvent = "messageB negotiated=\(keys.negotiatedSuite.rawValue)"
                    }
                case .established(let keys):
                    let wasInboundRekey = handshakeState.previousSessionKeysBeforeRekey != nil
                    let strictPQCRequired = HandshakePolicy.recommendedDefault(
                        compatibilityModeEnabled: UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                    ).requirePQC
                    if wasInboundRekey, strictPQCRequired, !keys.negotiatedSuite.isPQCGroup {
                        logger.error(
                            "⛔️ WebRTC inbound PQC rekey negotiated Classic under strictPQC; closing session: session=\(sessionID, privacy: .public) suite=\(keys.negotiatedSuite.rawValue, privacy: .public)"
                        )
                        handshakeState.driver = nil
                        handshakeState.previousSessionKeysBeforeRekey = nil
                        self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                        self.strictPQCClassicBootstrapOnlySessionIds.remove(sessionID)
                        self.lastRekeyEvent = "rejected classic suite=\(keys.negotiatedSuite.rawValue)"
                        self.cleanupWebRTCSession(
                            sessionID,
                            reason: "strict_pqc_rekey_negotiated_classic",
                            disconnectKind: .explicit
                        )
                        self.connectionStatus = .failed("Strict PQC rekey negotiated Classic suite: \(keys.negotiatedSuite.rawValue)")
                        self.readiness = .idle
                        return
                    }
                    handshakeState.sessionKeys = keys
                    handshakeState.driver = nil
                    handshakeState.previousSessionKeysBeforeRekey = nil
                    self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                    if keys.negotiatedSuite.isPQCGroup {
                        self.strictPQCClassicBootstrapOnlySessionIds.remove(sessionID)
                    }
                    let isStrictClassicAuthorityBootstrap =
                        self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionID)
                        && !keys.negotiatedSuite.isPQCGroup
                    if isStrictClassicAuthorityBootstrap {
                        self.lastRekeyEvent = "bootstrapOnly suite=\(keys.negotiatedSuite.rawValue)"
                        self.webrtcSessionKeysBySessionId[sessionID] = keys
                        logger.warning(
                            "⏳ WebRTC inbound strictPQC classic authority bootstrap is bootstrap-only: session=\(sessionID, privacy: .public) event=pqcRekeyPending suite=\(keys.negotiatedSuite.rawValue, privacy: .public)"
                        )
                        continue
                    }
                    self.strictPQCClassicBootstrapOnlySessionIds.remove(sessionID)
                    self.lastRekeyEvent = "complete suite=\(keys.negotiatedSuite.rawValue)"
                    self.webrtcSessionKeysBySessionId[sessionID] = keys
                    self.connectionStatus = .connected
                    self.readiness = .handshakeComplete(
                        sessionId: sessionID,
                        negotiatedSuite: keys.negotiatedSuite.rawValue
                    )
                    self.markCrossNetworkPresenceConnected(
                        sessionID: sessionID,
                        negotiatedSuite: keys.negotiatedSuite.rawValue
                    )
                    self.updatePreparedSessionSnapshot(
                        sessionID: sessionID,
                        phase: .handshakeComplete,
                        negotiatedSuite: keys.negotiatedSuite.rawValue
                    )
	                    startOutboundHeartbeatIfNeeded()
	                    startScreenStreamingIfNeeded(keys: keys)
	                    let rekeyCompletionEvent = keys.negotiatedSuite.isPQCGroup
	                        ? "pqcRekeyComplete"
	                        : "classicRekeyComplete"
	                    let rekeyCompletionLabel = keys.negotiatedSuite.isPQCGroup
	                        ? "PQC"
	                        : "classic compatibility"
	                    logger.info(
	                        "✅ WebRTC inbound \(rekeyCompletionLabel, privacy: .public) rekey completed: session=\(sessionID, privacy: .public) event=\(rekeyCompletionEvent, privacy: .public) suite=\(keys.negotiatedSuite.rawValue, privacy: .public)"
	                    )
                case .failed(let reason):
                    if let fallbackKeys = handshakeState.previousSessionKeysBeforeRekey {
                        let strictPQCRequired = HandshakePolicy.recommendedDefault(
                            compatibilityModeEnabled: UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        ).requirePQC
                        if strictPQCRequired && !fallbackKeys.negotiatedSuite.isPQCGroup {
                            logger.error(
                                "⛔️ WebRTC inbound PQC rekey failed under strictPQC; closing classic bootstrap-only session: session=\(sessionID, privacy: .public) event=pqcRekeyFailed reason=\(String(describing: reason), privacy: .public)"
                            )
                            handshakeState.previousSessionKeysBeforeRekey = nil
                            handshakeState.driver = nil
                            self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                            self.lastRekeyEvent = "failed strict reason=\(String(describing: reason))"
                            self.cleanupWebRTCSession(
                                sessionID,
                                reason: "strict_pqc_rekey_failed",
                                disconnectKind: .explicit
                            )
                            self.connectionStatus = .failed("Strict PQC rekey failed: \(reason)")
                            self.readiness = .idle
                            return
                        }
                        logger.warning(
                            "⚠️ WebRTC rekey 失败，保留既有会话: session=\(sessionID, privacy: .public) event=pqcRekeyFailed reason=\(String(describing: reason), privacy: .public)"
                        )
                        handshakeState.sessionKeys = fallbackKeys
                        handshakeState.previousSessionKeysBeforeRekey = nil
                        handshakeState.driver = nil
                        self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                        self.lastRekeyEvent = "failed reason=\(String(describing: reason))"
                        self.webrtcSessionKeysBySessionId[sessionID] = fallbackKeys
                        startOutboundHeartbeatIfNeeded()
                        startScreenStreamingIfNeeded(keys: fallbackKeys)
                        continue
                    }

                    self.cleanupWebRTCSession(
                        sessionID,
                        reason: "handshake_failed",
                        disconnectKind: .explicit
                    )
                    self.connectionStatus = .failed("WebRTC handshake failed: \(reason)")
                    self.readiness = .idle
                    return
                default:
                    break
                }
            }
        } catch {
            logger.warning(
                """
                ⚠️ WebRTC 控制通道结束: session=\(sessionID, privacy: .public) \
                peer=\(peerDeviceId, privacy: .public) error=\(error.localizedDescription, privacy: .public) \
                lastFrameLen=\(lastInboundFrameLength, privacy: .public) decodedFrameLen=\(lastDecodedFrameLength, privacy: .public) \
                driverState=\(lastHandshakeDriverState, privacy: .public) lastEvent=\(lastControlLoopEvent, privacy: .public) \
                lastRekey=\(self.lastRekeyEvent ?? "-", privacy: .public)
                """
            )
        }
    }

    private func establishP2PConnectionWithCode(code: String, deviceInfo: CrossNetworkDeviceInfo) async throws -> RemoteConnection {
        logger.info("建立 P2P 连接（连接码模式）")

 // 类似二维码模式，但使用连接码查询的设备信息
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])

        let iceCandidate = try await negotiateICEWithCode(
            code: code,
            deviceInfo: deviceInfo
        )

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(iceCandidate.host),
            port: NWEndpoint.Port(integerLiteral: iceCandidate.port)
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))

        try await CrossNetworkConnectionRuntimeSupport.waitForConnection(connection)

        return RemoteConnection(
            id: code,
            deviceName: deviceInfo.deviceName,
            transport: .nw(connection)
        )
    }

    private func negotiateICE(sessionID: String, remotePublicKey: Data) async throws -> ICECandidate {
 // 1. 首先尝试获取本地地址（用于局域网直连）
        let localAddresses = CrossNetworkConnectionRuntimeSupport.localIPAddresses()

 // 2. 尝试使用 STUN 获取公网地址
        if let stunResult = await STUNService.shared.getPublicAddress() {
            logger.info("🌐 STUN 返回公网地址: \(stunResult.address):\(stunResult.port)")
            return ICECandidate(
                host: stunResult.address,
                port: stunResult.port,
                type: .srflx // Server Reflexive (STUN 反射地址)
            )
        }

 // 3. 回退到本地地址
        if let firstLocal = localAddresses.first {
            logger.info("📍 使用本地地址: \(firstLocal)")
            return ICECandidate(
                host: firstLocal,
                port: 5000,
                type: .host
            )
        }

        throw CrossNetworkConnectionError.networkError
    }

    private func negotiateICEWithCode(code: String, deviceInfo: CrossNetworkDeviceInfo) async throws -> ICECandidate {
 // 与 negotiateICE 相同的逻辑
        return try await negotiateICE(sessionID: code, remotePublicKey: deviceInfo.publicKey)
    }

 // MARK: - 监听逻辑

    private func startListeningForConnection(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        logger.info("开始监听连接请求：\(sessionID)")

        let listener = ConnectionListener(sessionID: sessionID, privateKey: privateKey)
        activeListeners.append(listener)

        Task { [weak self] in
            await listener.start { [weak self] connection in
                guard let self = self else { return }
                await MainActor.run {
                    self.currentConnection = connection
                    self.connectionStatus = .connected
                    self.readiness = .handshakeComplete(
                        sessionId: connection.id,
                        negotiatedSuite: "quic-transport"
                    )
                    self.updatePreparedSessionSnapshot(
                        sessionID: connection.id,
                        phase: .handshakeComplete,
                        deviceName: connection.deviceName,
                        negotiatedSuite: "quic-transport"
                    )
                }
            }
        }
    }

    private func startListeningForCodeConnection(code: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        logger.info("开始监听连接码请求：\(code)")

        let listener = ConnectionListener(sessionID: code, privateKey: privateKey)
        activeListeners.append(listener)

        Task { [weak self] in
            await listener.start { [weak self] connection in
                guard let self = self else { return }
                await MainActor.run {
                    self.currentConnection = connection
                    self.connectionStatus = .connected
                    self.readiness = .handshakeComplete(
                        sessionId: connection.id,
                        negotiatedSuite: "quic-transport"
                    )
                    self.updatePreparedSessionSnapshot(
                        sessionID: connection.id,
                        phase: .handshakeComplete,
                        deviceName: connection.deviceName,
                        negotiatedSuite: "quic-transport"
                    )
                }
            }
        }
    }

 // MARK: - iCloud 连接辅助

    private func createConnectionOffer(sessionID: String) async throws -> ConnectionOffer {
        return ConnectionOffer(
            sessionID: sessionID,
            fromDevice: deviceFingerprint,
            iceCandidates: [],
            timestamp: Date()
        )
    }

    private func waitForAnswer(deviceID: String, timeout: TimeInterval) async throws -> ConnectionAnswer {
 // 轮询 iCloud KV Store
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let kvStore = NSUbiquitousKeyValueStore.default
            kvStore.synchronize()

            if let answerData = kvStore.data(forKey: "skybridge.answer.\(deviceFingerprint)"),
               let answer = try? JSONDecoder().decode(ConnectionAnswer.self, from: answerData) {
                return answer
            }

            try await Task.sleep(for: .seconds(1))
        }

        throw CrossNetworkConnectionError.timeout
    }

    private func finalizeConnection(offer: ConnectionOffer, answer: ConnectionAnswer) async throws -> RemoteConnection {
        // iCloud KV offer/answer 路径：从 answer 中提取 ICE 候选，选择最优地址建立 QUIC 连接。
        // 若 answer 中无可达候选（跨网场景），应走 WebRTC DataChannel 回退路径。
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])

        guard let firstCandidate = answer.iceCandidates.first,
              let colonIndex = firstCandidate.lastIndex(of: ":"),
              let port = UInt16(firstCandidate[firstCandidate.index(after: colonIndex)...]) else {
            logger.warning("⚠️ iCloud answer 无有效 ICE 候选，回退到 WebRTC 路径")
            throw CrossNetworkConnectionError.networkError
        }
        let host = String(firstCandidate[..<colonIndex])

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))

        try await CrossNetworkConnectionRuntimeSupport.waitForConnection(connection)

        return RemoteConnection(
            id: offer.sessionID,
            deviceName: "Remote Device",
            transport: .nw(connection)
        )
    }

 // MARK: - 工具方法

    private func enforceCurrentPathTrustBinding(
        deviceId: String,
        protocolPublicKeyFingerprint: String,
        authenticatedConnectionCodeRebindAllowed: Bool = false
    ) throws {
        if let conflict = TrustSyncService.shared.evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint
        ) {
            if authenticatedConnectionCodeRebindAllowed,
               Self.shouldAllowAuthenticatedConnectionCodeRebind(for: conflict) {
                logger.warning(
                    "⚠️ allow connection-code current-path authority rebind: deviceId=\(Self.protocolIdentityLogRedaction, privacy: .public) fingerprint=\(Self.protocolIdentityLogRedaction, privacy: .public) conflict=\(String(describing: conflict), privacy: .public)"
                )
                return
            }
            switch conflict {
            case .identityConflict:
                throw NSError(
                    domain: "CrossNetworkConnectionManager",
                    code: 8401,
                    userInfo: [NSLocalizedDescriptionKey: "连接目标 authoritative key 与现有 deviceId 绑定冲突"]
                )
            case .deviceIdMigrationRequired:
                throw NSError(
                    domain: "CrossNetworkConnectionManager",
                    code: 8402,
                    userInfo: [NSLocalizedDescriptionKey: "连接目标 deviceId 与已 pinned authoritative key 不匹配"]
                )
            case .quarantinedIdentity:
                throw NSError(
                    domain: "CrossNetworkConnectionManager",
                    code: 8403,
                    userInfo: [NSLocalizedDescriptionKey: "连接目标身份处于隔离/待重新验证状态"]
                )
            case .revokedIdentity:
                throw NSError(
                    domain: "CrossNetworkConnectionManager",
                    code: 8404,
                    userInfo: [NSLocalizedDescriptionKey: "连接目标身份已撤销"]
                )
            }
        }
    }

    private func logVerifiedQRCodeKEMIgnored(_ qrData: DynamicQRCodeData) {
        let kemKeys = qrData.normalizedKEMPublicKeys
        guard !kemKeys.isEmpty else { return }

        logger.info(
            "🔑 已验证二维码包含 PQC KEM，但不会导入 KEM trust；P2P KEM 恢复必须走 PIB-1 SAS + SKR-1 signed LAN refresh: device=\(qrData.deviceID, privacy: .public) keys=\(kemKeys.count, privacy: .public)"
        )
    }

}
