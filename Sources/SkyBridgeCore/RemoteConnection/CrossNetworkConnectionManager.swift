import Foundation
import Network
import CryptoKit
import Combine
import OSLog
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore
import CoreGraphics
import ImageIO
import ApplicationServices
import UniformTypeIdentifiers
import VideoToolbox
#if os(iOS)
import UIKit
#endif

@available(macOS 14.0, iOS 17.0, *)
@MainActor
private final class WebRTCHandshakeLoopState {
    var driver: HandshakeDriver?
    var sessionKeys: SessionKeys?
    var previousSessionKeysBeforeRekey: SessionKeys?
}

@available(macOS 14.0, iOS 17.0, *)
private struct WebRTCEncodedScreenFrame: Sendable, Equatable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
    let format: String
    let isSyncFrame: Bool
}

private enum RemoteMessageTypeWire: String, Codable {
    case screenData
    case mouseEvent
    case keyboardEvent
    case clipboard
    case streamConfiguration
    case damageReport
    case cursorUpdate
    case overlayUpdate
}

private struct RemoteMessageWire: Codable {
    let type: RemoteMessageTypeWire
    let payload: Data
}

private enum MouseEventTypeWire: String, Codable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case scrollUp
    case scrollDown
}

private struct MouseEventWire: Codable {
    let type: MouseEventTypeWire
    let x: Double
    let y: Double
    let timestamp: TimeInterval
}

private enum KeyboardEventTypeWire: String, Codable {
    case keyDown
    case keyUp
}

private struct KeyboardEventWire: Codable {
    let type: KeyboardEventTypeWire
    let keyCode: Int
    let timestamp: TimeInterval
}

private struct ScreenDataWire: Codable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
    let format: String?
    let isSyncFrame: Bool?
}

@available(macOS 14.0, iOS 17.0, *)
private final class LatestWebRTCEncodedFrameStore: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.skybridge.connection.webrtc.direct-frame-store",
        qos: .userInteractive
    )
    private var latestFrame: WebRTCEncodedScreenFrame?

    func store(_ frame: WebRTCEncodedScreenFrame) {
        queue.sync {
            latestFrame = frame
        }
    }

    func takeLatest() -> WebRTCEncodedScreenFrame? {
        queue.sync {
            defer { latestFrame = nil }
            return latestFrame
        }
    }

    func clear() {
        queue.sync {
            latestFrame = nil
        }
    }
}

/// 跨网络连接管理器 - 2025年创新架构
///
/// 三层连接方案：
/// 1. 动态二维码 + NFC 近场连接
/// 2. Apple ID / iCloud 设备链（零配置）
/// 3. 智能连接码 + P2P 穿透（通用方案）
@MainActor
public final class CrossNetworkConnectionManager: ObservableObject {

    public enum ConnectionCodeLeaseMode: String, CaseIterable, Sendable {
        case shortLived
        case dayStable

        public var validDuration: TimeInterval {
            switch self {
            case .shortLived:
                return 10 * 60
            case .dayStable:
                return 24 * 60 * 60
            }
        }
    }

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
    private var deviceFingerprint: String
    private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)
    public static let legacyConnectionCodeLength = 6
    public static let preferredConnectionCodeLength = 8
    public static let maximumConnectionCodeLength = 16
    private static let connectionCodeLeaseModeDefaultsKey = "cross_network_connection_code_lease_mode.macos"
    private var activeSessionReconnectTimeoutTask: Task<Void, Never>?
    private var activeConnectionCodeLeaseMode: ConnectionCodeLeaseMode?

    private struct SessionSnapshotMetadata: Sendable {
        let snapshotToken: UUID
        let source: ActiveSessionSnapshotSource
        let deviceId: String?
        let deviceName: String?
    }

    // MARK: - WebRTC (ICE / DataChannel)

    private var signalingClient: WebSocketSignalingClient?
    private var signalingShardKey: String?
    private var signalingGenerationBySessionId: [String: Int] = [:]
    private var activeSignalingHandle: WebSocketSignalingClient.SignalingHandleID?
    private var signalingRecoveryTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcSignalingAuthTokenBySessionId: [String: String] = [:]
    private var webrtcTurnAdmissionLeaseBySessionId: [String: SignalServerClient.TurnAdmissionLease] = [:]
    private var webrtcSessionsBySessionId: [String: WebRTCSession] = [:]
    private var pendingWebRTCOfferSessionIds: Set<String> = []
    private var webrtcRemoteIdBySessionId: [String: String] = [:]
    private var currentPathExpectedRemoteAuthorityBySessionId: [String: CurrentPathRemoteAuthority] = [:]
    private var currentPathSignalingOriginBySessionId: [String: String] = [:]
    private var webrtcLatestOfferBySessionId: [String: String] = [:]
    private var webrtcLatestAnswerBySessionId: [String: String] = [:]
    private var webrtcLocalICECandidatesBySessionId: [String: [WebRTCSignalingEnvelope.Payload]] = [:]
    private var sessionSnapshotMetadataBySessionId: [String: SessionSnapshotMetadata] = [:]
    private var webrtcJoinHeartbeatTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcOfferResendTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcControlTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcInboundQueuesBySessionId: [String: InboundChunkQueue] = [:]
    private var webrtcScreenStreamingTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcInteractionStreamingTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcRemoteLivenessWatchdogTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var webrtcRekeyInProgressSessionIds: Set<String> = []
    private var webrtcRemoteDesktopHeartbeatAtBySessionId: [String: Date] = [:]
    private var webrtcRemoteVideoFormatsBySessionId: [String: Set<String>] = [:]
    private var webrtcRemoteStreamConfigurationBySessionId: [String: RemoteDesktopStreamConfiguration] = [:]
    private var webrtcPendingStreamRefreshSessionIds: Set<String> = []
    private var webrtcBootstrapReplyFingerprintBySessionId: [String: String] = [:]
    private var webrtcSessionKeysBySessionId: [String: SessionKeys] = [:]
    private var activeWebRTCClipboardSessionId: String?
    private var activeWebRTCClipboardToken: UUID?

    // File transfer waiters (sessionID|transferId|op|chunkIndex -> continuation)
    private var webrtcFileTransferWaiters: [String: CheckedContinuation<CrossNetworkFileTransferMessage, Error>] = [:]

 // MARK: - 连接状态

 /// 跨网络连接状态 - 符合 Swift 6.2.3 的 Sendable 要求和严格并发控制
 /// 注意：这是CrossNetworkConnectionManager专用的连接状态，与全局ConnectionStatus不同
 /// 论文口径：`connected` 必须与 `readiness == .handshakeComplete` 对齐。
    public enum CrossNetworkConnectionStatus: Sendable {
        case idle
        case generating
        case waiting(code: String)
        case connecting
        case connected
        case failed(String) // 使用String而不是Error，以符合Sendable要求
    }

    public enum CrossNetworkReadiness: Sendable, Equatable {
        case idle
        case transportReady(sessionId: String)
        case handshakeComplete(sessionId: String, negotiatedSuite: String)
    }

    private enum SignalingOperationRejection: LocalizedError {
        case degradedFatal(String)

        var errorDescription: String? {
            switch self {
            case .degradedFatal(let sessionId):
                return "当前 signaling 处于 degraded-fatal，已封禁新的 signaling 操作: \(sessionId)"
            }
        }
    }

 // 为了向后兼容，保留类型别名（但建议使用 CrossNetworkConnectionStatus）
    @available(*, deprecated, renamed: "CrossNetworkConnectionStatus", message: "使用 CrossNetworkConnectionStatus 以避免与全局 ConnectionStatus 冲突")
    public typealias ConnectionStatus = CrossNetworkConnectionStatus

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
        self.deviceFingerprint = Self.generateDeviceFingerprint()
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
        signalingGenerationBySessionId[sessionID] ?? 0
    }

    private func nextSignalingGeneration(for sessionID: String) -> Int {
        let next = signalingGeneration(for: sessionID) + 1
        signalingGenerationBySessionId[sessionID] = next
        return next
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

    private func resetSignalingState(to phase: WebSocketSignalingClient.SignalingLifecyclePhase = .idle) {
        signalingLifecyclePhase = phase
        signalingHealth = .healthy
        activeSignalingHandle = nil
    }

    private func shouldAllowSignalingOperation(for sessionID: String) throws {
        guard !(signalingHealth == .degradedFatal && signalingShardKey == sessionID) else {
            throw SignalingOperationRejection.degradedFatal(sessionID)
        }
    }

    private func classifySignalingFailure(
        from frame: WebSocketSignalingClient.SignalingServerFrame
    ) -> WebSocketSignalingClient.SignalingFailureClass {
        let reason = frame.error ?? frame.what ?? "unknown_signaling_error"
        if reason.localizedCaseInsensitiveContains("token") && reason.localizedCaseInsensitiveContains("expired") {
            return .tokenExpired
        }
        if reason.localizedCaseInsensitiveContains("auth") ||
            reason.localizedCaseInsensitiveContains("unauthorized") ||
            reason.localizedCaseInsensitiveContains("forbidden") ||
            reason.localizedCaseInsensitiveContains("bind_rejected") {
            return .authBindRejected
        }
        if reason.localizedCaseInsensitiveContains("invalid shard") ||
            reason.localizedCaseInsensitiveContains("invalid session") ||
            reason.localizedCaseInsensitiveContains("session mismatch") ||
            reason.localizedCaseInsensitiveContains("unknown shard") {
            return .invalidShardOrSessionMismatch
        }
        if reason.localizedCaseInsensitiveContains("protocol") ||
            reason.localizedCaseInsensitiveContains("malformed") {
            return .protocolViolation
        }
        return .transientServer
    }

    private func isFatalPreTransportFailure(_ failureClass: WebSocketSignalingClient.SignalingFailureClass) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }

    private func isFatalPostTransportFailure(_ failureClass: WebSocketSignalingClient.SignalingFailureClass) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }

    private func scheduleSignalingRecovery(for sessionID: String, tokenExpired: Bool = false) {
        signalingRecoveryTasksBySessionId[sessionID]?.cancel()
        signalingRecoveryTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let maxAttempts = tokenExpired ? 1 : 3
            for attempt in 0..<maxAttempts where !Task.isCancelled {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                }
                do {
                    try await self.ensureSignalingConnected(shardKey: sessionID)
                    if self.signalingShardKey == sessionID {
                        self.signalingHealth = .healthy
                    }
                    self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionID)
                    return
                } catch is CancellationError {
                    self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionID)
                    self.logger.debug(
                        "ℹ️ signaling recovery cancelled: session=\(sessionID, privacy: .public) attempt=\(attempt + 1, privacy: .public)"
                    )
                    return
                } catch {
                    self.logger.error(
                        "⚠️ signaling recovery failed: session=\(sessionID, privacy: .public) attempt=\(attempt + 1, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            if tokenExpired, self.isTransportEstablished(for: sessionID) {
                self.signalingHealth = .degradedFatal
            }
            self.signalingRecoveryTasksBySessionId.removeValue(forKey: sessionID)
        }
    }

    func handleSignalingLifecycleEvent(_ event: WebSocketSignalingClient.SignalingLifecycleEvent) {
        guard event.handleId.sessionId == signalingShardKey else { return }

        if event.phase == .connecting || event.phase == .reconnecting {
            guard event.handleId.generation >= signalingGeneration(for: event.handleId.sessionId) else { return }
            signalingGenerationBySessionId[event.handleId.sessionId] = event.handleId.generation
            activeSignalingHandle = event.handleId
        }

        guard event.handleId.generation == signalingGeneration(for: event.handleId.sessionId) else { return }

        guard activeSignalingHandle == event.handleId else { return }

        signalingLifecyclePhase = event.phase

        switch event.phase {
        case .bound:
            signalingHealth = .healthy
        case .closed:
            if isTransportEstablished(for: event.handleId.sessionId) {
                signalingHealth = .degradedRecoverable
                scheduleSignalingRecovery(for: event.handleId.sessionId)
            }
        case .failed:
            let failureClass = event.failureClass ?? .transientServer
            let sessionID = event.handleId.sessionId
            if isTransportEstablished(for: sessionID) {
                if failureClass == .tokenExpired {
                    signalingHealth = .degradedRecoverable
                    scheduleSignalingRecovery(for: sessionID, tokenExpired: true)
                } else if isFatalPostTransportFailure(failureClass) {
                    signalingHealth = .degradedFatal
                } else {
                    signalingHealth = .degradedRecoverable
                    scheduleSignalingRecovery(for: sessionID)
                }
            }
        default:
            break
        }
    }

    func testingSeedSignalingState(
        sessionID: String,
        generation: Int,
        handle: WebSocketSignalingClient.SignalingHandleID? = nil,
        health: SignalingSessionHealth = .healthy,
        phase: WebSocketSignalingClient.SignalingLifecyclePhase = .idle
    ) {
        signalingShardKey = sessionID
        signalingGenerationBySessionId[sessionID] = generation
        activeSignalingHandle = handle
        signalingHealth = health
        signalingLifecyclePhase = phase
    }

    func testingSetReadiness(_ readiness: CrossNetworkReadiness) {
        self.readiness = readiness
    }

    func testingCurrentSignalingHandle() -> WebSocketSignalingClient.SignalingHandleID? {
        activeSignalingHandle
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

    private func preferredCaptureSize(for resolution: ResolutionSetting) -> CGSize {
        if let dim = resolution.dimensions {
            return CGSize(width: dim.width, height: dim.height)
        }

        let settings = RemoteDesktopSettingsManager.shared.settings.displaySettings
        return adaptiveCaptureSize(
            for: .unknown,
            preferredCodec: settings.preferredCodec,
            lowLatencyMode: settings.lowLatencyMode,
            enableHardwareAcceleration: settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization
        )
    }

    private func adaptiveCaptureSize(
        for transportPath: WebRTCSession.ICETransportPath,
        preferredCodec: PreferredVideoCodec,
        lowLatencyMode: Bool,
        enableHardwareAcceleration: Bool,
        enableAppleSiliconOptimization: Bool
    ) -> CGSize {
        let fallback = CGSize(width: 1600, height: 900)
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else {
            return fallback
        }

        let nativeWidth = CGFloat(mode.width)
        let nativeHeight = CGFloat(mode.height)
        guard nativeWidth > 0, nativeHeight > 0 else {
            return fallback
        }

        let longEdge = max(nativeWidth, nativeHeight)
        let prefersHEVC = preferredCodec == .hevc
        let canPushHighRes = prefersHEVC && enableHardwareAcceleration
            && enableAppleSiliconOptimization && Self.isAppleSiliconRuntime

        let targetLongEdge: CGFloat
        switch transportPath {
        case .direct:
            if longEdge <= 1920 {
                return CGSize(width: nativeWidth, height: nativeHeight)
            } else if longEdge <= 2560 {
                targetLongEdge = lowLatencyMode ? 1920 : longEdge
            } else if longEdge <= 3840 {
                targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 2560 : 1920)
            } else {
                targetLongEdge = lowLatencyMode ? 1920 : (canPushHighRes ? 3200 : 2560)
            }
        case .unknown:
            targetLongEdge = lowLatencyMode ? 1280 : 1600
        case .relay:
            targetLongEdge = lowLatencyMode ? 960 : 1280
        }

        let scale = min(1.0, targetLongEdge / longEdge)
        return CGSize(
            width: max(960, floor(nativeWidth * scale)),
            height: max(540, floor(nativeHeight * scale))
        )
    }

    private func webrtcVideoRequest(from settings: DisplaySettings) -> WebRTCRemoteDesktopVideoRequest {
        WebRTCRemoteDesktopVideoRequest(
            preferredSize: preferredCaptureSize(for: settings.resolution),
            preferredCodec: settings.preferredCodec,
            requestedFrameRate: settings.targetFrameRate,
            keyFrameInterval: settings.keyFrameInterval,
            lowLatencyMode: settings.lowLatencyMode,
            enableHardwareAcceleration: settings.enableHardwareAcceleration,
            enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization
        )
    }

    private func webrtcVideoRequest(
        for sessionID: String,
        from settings: DisplaySettings,
        transportPath: WebRTCSession.ICETransportPath
    ) -> WebRTCRemoteDesktopVideoRequest {
        guard let config = webrtcRemoteStreamConfigurationBySessionId[sessionID] else {
            return WebRTCRemoteDesktopVideoRequest(
                preferredSize: adaptiveCaptureSize(
                    for: transportPath,
                    preferredCodec: settings.preferredCodec,
                    lowLatencyMode: settings.lowLatencyMode,
                    enableHardwareAcceleration: settings.enableHardwareAcceleration,
                    enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization
                ),
                preferredCodec: settings.preferredCodec,
                requestedFrameRate: settings.targetFrameRate,
                keyFrameInterval: settings.keyFrameInterval,
                lowLatencyMode: settings.lowLatencyMode,
                enableHardwareAcceleration: settings.enableHardwareAcceleration,
                enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization
            )
        }

        let preferredCodec: PreferredVideoCodec = {
            switch config.preferredCodec?.lowercased() {
            case "h264":
                return .h264
            case "hevc":
                return .hevc
            default:
                return settings.preferredCodec
            }
        }()

        let adaptiveResolutionEnabled = config.adaptiveResolutionEnabled
            ?? (config.width == nil || config.height == nil)
        let preferredSize: CGSize = {
            if !adaptiveResolutionEnabled,
               let width = config.width,
               let height = config.height,
               width > 0,
               height > 0 {
                return CGSize(width: width, height: height)
            }
            if adaptiveResolutionEnabled {
                return adaptiveCaptureSize(
                    for: transportPath,
                    preferredCodec: preferredCodec,
                    lowLatencyMode: config.lowLatencyMode,
                    enableHardwareAcceleration: config.enableHardwareAcceleration,
                    enableAppleSiliconOptimization: config.enableAppleSiliconOptimization
                )
            }
            return preferredCaptureSize(for: settings.resolution)
        }()

        return WebRTCRemoteDesktopVideoRequest(
            preferredSize: preferredSize,
            preferredCodec: preferredCodec,
            requestedFrameRate: max(12, min(config.targetFrameRate, 120)),
            keyFrameInterval: max(10, min(config.keyFrameInterval, 240)),
            lowLatencyMode: config.lowLatencyMode,
            enableHardwareAcceleration: config.enableHardwareAcceleration,
            enableAppleSiliconOptimization: config.enableAppleSiliconOptimization
        )
    }

    private func effectiveWebRTCRemoteVideoFormats(for sessionID: String) -> Set<String> {
        if let config = webrtcRemoteStreamConfigurationBySessionId[sessionID],
           config.preferredCodec?.lowercased() == "jpeg" {
            return ["jpeg"]
        }

        var formats = webrtcRemoteVideoFormatsBySessionId[sessionID] ?? []
        if let config = webrtcRemoteStreamConfigurationBySessionId[sessionID] {
            formats.formUnion(config.supportedVideoFormats.map { $0.lowercased() })
            if let preferred = config.preferredCodec?.lowercased(),
               preferred == "h264" || preferred == "hevc" || preferred == "jpeg" {
                formats.insert(preferred)
            }
        }
        return formats
    }

    private static func supportedRemoteVideoFormats() -> [String] {
        var formats = ["jpeg", "h264"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            formats.insert("hevc", at: 0)
        }
        var seen: Set<String> = []
        return formats.filter { seen.insert($0).inserted }
    }

    private func consumePendingWebRTCStreamRefresh(for sessionID: String) -> Bool {
        webrtcPendingStreamRefreshSessionIds.remove(sessionID) != nil
    }

    private func configureWebRTCClipboardSyncIfNeeded(
        for sessionID: String,
        session: WebRTCSession
    ) {
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

    private func sendWebRTCClipboardPayload(
        data: Data,
        mimeType: String,
        sessionID: String,
        session: WebRTCSession
    ) async {
        do {
            guard let keys = webrtcSessionKeysBySessionId[sessionID] else { return }
            let clipboardPayload = RemoteClipboardPayload(mimeType: mimeType, data: data)
            let remoteMessage = RemoteMessageWire(
                type: .clipboard,
                payload: try JSONEncoder().encode(clipboardPayload)
            )
            let plaintext = try JSONEncoder().encode(remoteMessage)
            let ciphertext = try encryptAppPayload(plaintext, with: keys)
            let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: "tx/webrtc-clipboard")
            try await sendFramed(padded, over: session)
        } catch {
            logger.error("❌ WebRTC 会话剪贴板发送失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func remoteFrameFormatName(frameType: RemoteFrameType, payload: Data) -> String {
        switch frameType {
        case .hevc:
            return "hevc"
        case .h264:
            return "h264"
        case .bgra:
            if payload.count >= 2, payload[0] == 0xFF, payload[1] == 0xD8 {
                return "jpeg"
            }
            return "bgra"
        }
    }

    nonisolated private static var isAppleSiliconRuntime: Bool {
        #if arch(arm64) || arch(arm64e)
        true
        #else
        false
        #endif
    }

    nonisolated private static func smokeStatusURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw)
    }

    private func appendSmokeStatus(_ line: String) {
        guard let statusURL = Self.smokeStatusURL() else { return }
        let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let data = rendered.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: statusURL.path),
           let handle = try? FileHandle(forWritingTo: statusURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: statusURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: statusURL.path
            )
        }
    }

    private func sanitizeStatus(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func stopJoinHeartbeat(for sessionID: String) {
        webrtcJoinHeartbeatTasksBySessionId[sessionID]?.cancel()
        webrtcJoinHeartbeatTasksBySessionId.removeValue(forKey: sessionID)
    }

    private func startJoinHeartbeat(for sessionID: String, attempts: Int = 30) {
        stopJoinHeartbeat(for: sessionID)
        webrtcJoinHeartbeatTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0, !Task.isCancelled, self.webrtcSessionsBySessionId[sessionID] != nil {
                let localDeviceId = self.webrtcSessionsBySessionId[sessionID]?.localDeviceId ?? self.deviceFingerprint
                await self.sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .join, payload: nil), retries: 2)
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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

        stopJoinHeartbeat(for: sessionID)
        stopOfferResendLoop(for: sessionID)
        pendingWebRTCOfferSessionIds.remove(sessionID)
        webrtcLatestOfferBySessionId.removeValue(forKey: sessionID)
        webrtcLatestAnswerBySessionId.removeValue(forKey: sessionID)
        webrtcLocalICECandidatesBySessionId.removeValue(forKey: sessionID)
        webrtcSignalingAuthTokenBySessionId.removeValue(forKey: sessionID)
        webrtcTurnAdmissionLeaseBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteIdBySessionId.removeValue(forKey: sessionID)
        currentPathExpectedRemoteAuthorityBySessionId.removeValue(forKey: sessionID)
        currentPathSignalingOriginBySessionId.removeValue(forKey: sessionID)
        webrtcSessionKeysBySessionId.removeValue(forKey: sessionID)
        webrtcRekeyInProgressSessionIds.remove(sessionID)
        webrtcRemoteDesktopHeartbeatAtBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteVideoFormatsBySessionId.removeValue(forKey: sessionID)
        webrtcRemoteStreamConfigurationBySessionId.removeValue(forKey: sessionID)
        webrtcPendingStreamRefreshSessionIds.remove(sessionID)
        webrtcBootstrapReplyFingerprintBySessionId.removeValue(forKey: sessionID)
        stopWebRTCClipboardSyncIfNeeded(for: sessionID)
        stopWebRTCLivenessWatchdog(for: sessionID)
        markCrossNetworkPresenceDisconnected(sessionID: sessionID)
        signalingRecoveryTasksBySessionId[sessionID]?.cancel()
        signalingRecoveryTasksBySessionId.removeValue(forKey: sessionID)

        if let controlTask = webrtcControlTasksBySessionId.removeValue(forKey: sessionID) {
            controlTask.cancel()
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

    private static func crossNetworkPresencePeerID(sessionID: String) -> String {
        "cross-network:\(sessionID)"
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
        let peerId = Self.crossNetworkPresencePeerID(sessionID: sessionID)

        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: displayName,
            address: nil,
            cryptoKind: cryptoKind,
            suite: negotiatedSuite
        )
        UnifiedOnlineDeviceManager.shared.markDeviceAsConnected(
            peerId: peerId,
            displayName: displayName,
            cryptoKind: cryptoKind,
            suite: negotiatedSuite,
            guardStatus: "跨网已连接"
        )
    }

    private func markCrossNetworkPresenceDisconnected(sessionID: String) {
        ConnectionPresenceService.shared.markDisconnected(
            peerId: Self.crossNetworkPresencePeerID(sessionID: sessionID)
        )
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

                if !hasSessionKeys || rekeyInProgress {
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
                        disconnectKind: .transient
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

    private func resendCachedOfferIfNeeded(for sessionID: String, reason: String) async {
        guard let sdp = webrtcLatestOfferBySessionId[sessionID] else { return }
        let localDeviceId = webrtcSessionsBySessionId[sessionID]?.localDeviceId ?? deviceFingerprint
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionID: sessionID, sdp: sdp)
        logger.info("🔁 重发本地 offer: session=\(sessionID, privacy: .public) reason=\(reason, privacy: .public)")
        await sendSignal(
            .init(sessionId: sessionID, from: localDeviceId, type: .offer, payload: .init(sdp: enrichedSDP)),
            retries: 2
        )
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
        return Self.injectLocalICECandidates(candidates, into: sdp)
    }

    private static func injectLocalICECandidates(
        _ candidates: [WebRTCSignalingEnvelope.Payload],
        into sdp: String
    ) -> String {
        let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
        let normalizedLines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var prefix: [String] = []
        var sections: [[String]] = []
        var currentSection: [String]? = nil

        for line in normalizedLines {
            if line.hasPrefix("m=") {
                if let currentSection {
                    sections.append(currentSection)
                }
                currentSection = [line]
            } else if currentSection != nil {
                currentSection?.append(line)
            } else {
                prefix.append(line)
            }
        }
        if let currentSection {
            sections.append(currentSection)
        }
        guard !sections.isEmpty else { return sdp }

        for payload in candidates {
            guard let candidateLine = normalizedCandidateSDPLine(from: payload) else { continue }
            let targetIndex = targetMediaSectionIndex(for: payload, sections: sections) ?? 0
            guard sections.indices.contains(targetIndex) else { continue }
            insertSDPLine(candidateLine, into: &sections[targetIndex])
        }

        var flattened = prefix
        for section in sections {
            flattened.append(contentsOf: section)
        }

        var rendered = flattened.joined(separator: newline)
        if sdp.hasSuffix("\r\n") || sdp.hasSuffix("\n") {
            rendered.append(newline)
        }
        return rendered
    }

    private static func normalizedCandidateSDPLine(from payload: WebRTCSignalingEnvelope.Payload) -> String? {
        guard let raw = payload.candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("a=") {
            return raw
        }
        if raw.hasPrefix("candidate:") {
            return "a=\(raw)"
        }
        return raw
    }

    private static func targetMediaSectionIndex(
        for payload: WebRTCSignalingEnvelope.Payload,
        sections: [[String]]
    ) -> Int? {
        if let index = payload.sdpMLineIndex, index >= 0, Int(index) < sections.count {
            return Int(index)
        }
        if let mid = payload.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mid.isEmpty,
           let match = sections.firstIndex(where: { section in
               section.contains(where: { $0 == "a=mid:\(mid)" })
           }) {
            return match
        }
        return sections.isEmpty ? nil : max(0, sections.count - 1)
    }

    private static func insertSDPLine(_ line: String, into section: inout [String]) {
        guard !section.contains(line) else { return }
        if let insertionIndex = section.firstIndex(of: "a=end-of-candidates") {
            section.insert(line, at: insertionIndex)
        } else {
            section.append(line)
        }
    }

    private func resendCachedLocalICECandidatesIfNeeded(for sessionID: String, reason: String) async {
        guard let candidates = webrtcLocalICECandidatesBySessionId[sessionID], !candidates.isEmpty else { return }
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
                if case .connected = self.connectionStatus { break }
                await self.resendCachedOfferIfNeeded(for: sessionID, reason: "periodic")
                await self.resendCachedLocalICECandidatesIfNeeded(for: sessionID, reason: "periodic")
                remaining -= 1
                if remaining == 0 { break }
                try? await Task.sleep(for: .milliseconds(1500))
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
        // 1) 关闭所有 WebRTC 会话
        for (_, session) in webrtcSessionsBySessionId {
            session.close()
        }
        webrtcSessionsBySessionId.removeAll()

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
        webrtcRemoteIdBySessionId.removeAll()
        currentPathExpectedRemoteAuthorityBySessionId.removeAll()
        currentPathSignalingOriginBySessionId.removeAll()
        webrtcLatestOfferBySessionId.removeAll()
        pendingWebRTCOfferSessionIds.removeAll()

        for (_, task) in webrtcJoinHeartbeatTasksBySessionId {
            task.cancel()
        }
        webrtcJoinHeartbeatTasksBySessionId.removeAll()

        for (_, task) in webrtcOfferResendTasksBySessionId {
            task.cancel()
        }
        webrtcOfferResendTasksBySessionId.removeAll()

        // 6) 关闭 WebSocket 信令
        if let sc = signalingClient {
            await sc.close()
        }
        signalingClient = nil
        signalingShardKey = nil
        for (_, task) in signalingRecoveryTasksBySessionId {
            task.cancel()
        }
        signalingRecoveryTasksBySessionId.removeAll()
        signalingGenerationBySessionId.removeAll()
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

    private func logQRCodeStage(_ operation: String, stage: String, sessionID: String? = nil) {
        let sessionHint = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
        logger.info("📷 QR stage: operation=\(operation, privacy: .public) stage=\(stage, privacy: .public) session=\(sessionHint, privacy: .public)")
    }

    private func currentPathLocalBinding() async throws -> ProtocolIdentityBinding {
        let algorithm: ProtocolSigningAlgorithm = .ed25519
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

    private func validateCurrentPathOrigin(_ rawOrigin: String) throws -> String {
        let configuredOrigin = try CurrentPathOriginPolicy.canonicalOrigin(SkyBridgeServerConfig.signalingServerURL)
        let claimedOrigin = try CurrentPathOriginPolicy.canonicalOrigin(rawOrigin)
        guard configuredOrigin == claimedOrigin else {
            throw CrossNetworkConnectionError.invalidQRCode
        }
        return claimedOrigin
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

    private static func deriveTenantIdentifier(accessToken: String?) -> String {
        let explicit = ProcessInfo.processInfo.environment["SKYBRIDGE_TENANT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty {
            return explicit
        }
        guard let accessToken, !accessToken.isEmpty else {
            return ""
        }
        guard let payload = accessToken.split(separator: ".").dropFirst().first else {
            return ""
        }
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let appMetadata = object["app_metadata"] as? [String: Any]
        let userMetadata = object["user_metadata"] as? [String: Any]
        let candidates: [Any?] = [
            appMetadata?["tenant_id"],
            appMetadata?["tenantId"],
            appMetadata?["org_id"],
            appMetadata?["workspace_id"],
            userMetadata?["tenant_id"],
            userMetadata?["tenantId"],
            userMetadata?["org_id"],
            userMetadata?["workspace_id"],
            object["tenant_id"],
            object["tenantId"],
            object["sub"]
        ]
        for candidate in candidates {
            let value = String(describing: candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "nil" {
                return value
            }
        }
        return ""
    }

 // MARK: - 1️⃣ 动态二维码连接

 /// 生成动态加密二维码
 /// 包含：设备指纹 + 临时密钥 + ICE 候选信息 + 过期时间
    public func generateDynamicQRCode(validDuration: TimeInterval = 300) async throws -> Data {
        logger.info("生成动态二维码，有效期: \(validDuration)秒")
        connectionStatus = .generating
        readiness = .idle
        qrCodeData = nil
        let watchdog = startQRCodeWatchdog(
            operation: "generate",
            timeoutSeconds: 15,
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
            webrtcSignalingAuthTokenBySessionId[sessionLease.sessionID] = sessionLease.sessionToken
            webrtcTurnAdmissionLeaseBySessionId[sessionLease.sessionID] = sessionLease.turnAdmissionLease
            currentPathSignalingOriginBySessionId[sessionLease.sessionID] = sessionLease.signalingServerOrigin
            logQRCodeStage("generate", stage: "\(currentStage)_finished", sessionID: sessionID)

            let expiresAt = Date().addingTimeInterval(validDuration)
            let signatureTimestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            let qrData = DynamicQRCodeData(
                version: 6,
                sessionID: sessionID,
                qrBootstrapToken: sessionLease.qrBootstrapToken,
                signalingServerOrigin: sessionLease.signalingServerOrigin,
                deviceID: localBinding.deviceId,
                deviceName: Host.current().localizedName ?? "Mac",
                deviceType: P2PDeviceType.macOS.rawValue,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                capabilities: ["cross-network", "p2p"],
                protocolSigningAlgorithm: localBinding.protocolSigningAlgorithm,
                protocolPublicKeyBytes: localBinding.protocolPublicKeyBytes,
                protocolPublicKeyFingerprint: localBinding.protocolPublicKeyFingerprint,
                signature: nil,
                signatureTimestampMs: signatureTimestampMs,
                expiresAt: expiresAt
            )

            currentStage = "sign_qr"
            logQRCodeStage("generate", stage: "\(currentStage)_started", sessionID: sessionID)
            let canonicalPayload = Self.buildCanonicalQRCodePayload(for: qrData)
            let signatureProvider = ProtocolSignatureProviderSelector.select(for: localBinding.protocolSigningAlgorithm)
            let signingHandle = try await DeviceIdentityKeyManager.shared.getProtocolSigningKeyHandle(for: localBinding.protocolSigningAlgorithm)
            let signature = try await signatureProvider.sign(canonicalPayload, key: signingHandle)
            logQRCodeStage("generate", stage: "\(currentStage)_finished", sessionID: sessionID)
            let compactPayload = CompactDynamicQRCodeData(from: qrData.withSignature(signature))

            currentStage = "assign_payload"
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(compactPayload)
            let base64String = Self.base64URLEncodedString(from: jsonData)
            let qrString = "skybridge://connect/\(base64String)"

            self.qrCodeData = qrString.data(using: .utf8)
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
            timeoutSeconds: 20,
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
            switch verifyResult.source {
            case .trustedDevice:
                logger.info("✅ 二维码来源已命中本地 trust store: \(qrData.deviceID, privacy: .public)")
            case .selfAsserted:
                logger.notice("ℹ️ 二维码仅完成完整性校验，未命中外部信任锚；后续身份认证仍依赖握手/pinning")
            }

            currentStage = "redeem_session"
            logQRCodeStage("scan", stage: "\(currentStage)_started", sessionID: qrData.sessionID)
            let localBinding = try await currentPathLocalBinding()
            let admissionLease = try await requestAdmissionLease(for: localBinding)
            let redeemed = try await signalServer.redeemSession(
                admissionToken: admissionLease.token,
                sessionID: qrData.sessionID,
                qrBootstrapToken: qrData.qrBootstrapToken
            )
            _ = try validateCurrentPathOrigin(redeemed.signalingServerOrigin)
            guard redeemed.initiatorDeviceId == qrData.deviceID,
                  redeemed.initiatorProtocolSigningAlgorithm == qrData.protocolSigningAlgorithm,
                  redeemed.initiatorProtocolPublicKeyFingerprint == qrData.protocolPublicKeyFingerprint else {
                throw CrossNetworkConnectionError.invalidSignature
            }
            webrtcSignalingAuthTokenBySessionId[qrData.sessionID] = redeemed.sessionToken
            webrtcTurnAdmissionLeaseBySessionId[qrData.sessionID] = redeemed.turnAdmissionLease
            currentPathSignalingOriginBySessionId[qrData.sessionID] = redeemed.signalingServerOrigin
            currentPathExpectedRemoteAuthorityBySessionId[qrData.sessionID] = CurrentPathRemoteAuthority(
                deviceId: qrData.deviceID,
                protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
                protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
                deviceName: qrData.deviceName
            )
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
        let currentDeviceId = Self.generateDeviceFingerprint()
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
        if let existing = connectionCode,
           activeConnectionCodeLeaseMode == requestedLeaseMode,
           case .waiting(let activeCode) = connectionStatus,
           activeCode == existing {
            return existing
        }
        if connectionCode != nil,
           activeConnectionCodeLeaseMode != requestedLeaseMode {
            await disconnect()
        }
        connectionStatus = .generating
        readiness = .idle

        let localBinding = try await currentPathLocalBinding()
        let admissionLease = try await requestAdmissionLease(for: localBinding)
        let lease = try await signalServer.registerConnectionCode(
            admissionToken: admissionLease.token,
            deviceName: Host.current().localizedName ?? "Mac",
            validDuration: requestedLeaseMode.validDuration
        )
        let code = lease.code
        webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken
        webrtcTurnAdmissionLeaseBySessionId[lease.sessionID] = lease.turnAdmissionLease
        currentPathSignalingOriginBySessionId[lease.sessionID] = lease.signalingServerOrigin

        // 2) 当前主路径由服务端发放短期 code + initiator token，code 同时作为 WebRTC sessionId。
        self.connectionCode = code
        self.connectionCodeExpiresAt = Date().addingTimeInterval(lease.expiresIn)
        self.activeConnectionCodeLeaseMode = requestedLeaseMode
        self.connectionStatus = .waiting(code: code)
        self.readiness = .idle

        // 3) 启动 WebRTC offerer（等待对端输入同一 code 后 join，同会话完成 SDP/ICE，DataChannel ready）
        startWebRTCOfferSession(sessionID: lease.sessionID)

        logger.info("✅ 连接码生成成功: \(code)")
        return code
    }

    /// 通过连接码连接
    public func connectWithCode(_ code: String) async throws -> RemoteConnection {
        guard let normalized = Self.normalizeConnectionCode(code) else {
            throw CrossNetworkConnectionError.invalidDevice
        }
        logger.info("使用连接码连接: \(normalized)")

        if let existing = currentConnection, existing.id == normalized {
            logger.info("复用已有连接码会话: \(normalized, privacy: .public)")
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

        let localBinding = try await currentPathLocalBinding()
        let admissionLease = try await requestAdmissionLease(for: localBinding)
        let lookup = try await signalServer.lookupConnectionCode(
            admissionToken: admissionLease.token,
            code: normalized
        )
        _ = try validateCurrentPathOrigin(lookup.signalingServerOrigin)
        webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken
        webrtcTurnAdmissionLeaseBySessionId[lookup.sessionID] = lookup.turnAdmissionLease
        currentPathSignalingOriginBySessionId[lookup.sessionID] = lookup.signalingServerOrigin
        currentPathExpectedRemoteAuthorityBySessionId[lookup.sessionID] = CurrentPathRemoteAuthority(
            deviceId: lookup.initiatorDeviceId,
            protocolSigningAlgorithm: lookup.initiatorProtocolSigningAlgorithm,
            protocolPublicKeyFingerprint: lookup.initiatorProtocolPublicKeyFingerprint,
            protocolPublicKeyBytes: nil,
            deviceName: lookup.initiatorDeviceName
        )
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
        let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .answerer, ice: ice)

        session.onLocalAnswer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                self.webrtcLatestAnswerBySessionId[sessionID] = sdp
                await self.sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .answer, payload: .init(sdp: sdp)))
            }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                self.cacheLocalICECandidate(payload, for: sessionID)
                await self.sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .iceCandidate, payload: payload))
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
                self.stopJoinHeartbeat(for: sessionID)
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

        webrtcSessionsBySessionId[sessionID] = session

        do {
            try session.start()
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
        await sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .join, payload: nil), retries: 2)
        startJoinHeartbeat(for: sessionID)
        let connection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
        logger.info("✅ 通过连接码开始连接（等待对端 offer）")
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
        try await waitForConnection(connection)

        return RemoteConnection(
            id: qrData.sessionID,
            deviceName: qrData.deviceName,
            transport: .nw(connection)
        )
    }

    // MARK: - WebRTC Connection

    private func signalingWebSocketURL(shardKey: String? = nil) -> URL? {
        guard let baseURL = URL(string: SkyBridgeServerConfig.signalingWebSocketURL) else { return nil }
        guard let shardKey = shardKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shardKey.isEmpty else {
            return baseURL
        }
        guard let sessionToken = webrtcSignalingAuthTokenBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionToken.isEmpty else {
            return nil
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "shard" }
        queryItems.removeAll { $0.name == "st" }
        queryItems.removeAll { $0.name == "cv" }
        queryItems.removeAll { $0.name == "pv" }
        queryItems.append(URLQueryItem(name: "shard", value: shardKey.uppercased()))
        queryItems.append(URLQueryItem(name: "st", value: sessionToken))
        let clientVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        queryItems.append(URLQueryItem(
            name: "cv",
            value: (clientVersion?.isEmpty == false)
                ? clientVersion
                : (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
        ))
        queryItems.append(URLQueryItem(
            name: "pv",
            value: ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"] ?? "1"
        ))
        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    private func ensureSignalingConnected(shardKey: String? = nil) async throws {
        let effectiveShardKey = shardKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedShardKey = (effectiveShardKey?.isEmpty == false) ? effectiveShardKey : nil

        if let client = signalingClient, signalingShardKey != normalizedShardKey {
            await client.close()
            signalingClient = nil
            signalingShardKey = nil
            activeSignalingHandle = nil
            resetSignalingState()
        }

        if let client = signalingClient {
            try await client.connectOrThrow()
            return
        }
        guard let sessionID = normalizedShardKey,
              let url = signalingWebSocketURL(shardKey: normalizedShardKey) else {
            throw WebSocketSignalingClient.SignalingError.notConnected
        }
        let generation = nextSignalingGeneration(for: sessionID)
        let client = WebSocketSignalingClient(url: url, sessionId: sessionID, generation: generation)
        self.signalingClient = client
        signalingShardKey = normalizedShardKey
        signalingHealth = .healthy
        signalingLifecyclePhase = .idle
        activeSignalingHandle = nil
        await client.setOnEnvelope { [weak self] env in
            Task { @MainActor in
                self?.handleSignalingEnvelope(env)
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

        let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .offerer, ice: ice)
        session.onLocalOffer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                self.webrtcLatestOfferBySessionId[sessionID] = sdp
                await self.sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .offer, payload: .init(sdp: sdp)), retries: 2)
            }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                self.cacheLocalICECandidate(payload, for: sessionID)
                await self.sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .iceCandidate, payload: payload))
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
                self.stopJoinHeartbeat(for: sessionID)
                self.stopOfferResendLoop(for: sessionID)
                self.currentConnection = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .webrtc(session))
                self.connectionStatus = .connecting
                self.readiness = .transportReady(sessionId: sessionID)
                self.startWebRTCLivenessWatchdogIfNeeded(for: sessionID)
                self.activatePreparedSessionSnapshot(sessionID: sessionID, phase: .transportReady)

                // 启动“握手/控制通道”消费者：把 DataChannel 当作一条 length-framed byte stream，复用现有 HandshakeDriver / AppMessage 逻辑。
                self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
            }
        }

        webrtcSessionsBySessionId[sessionID] = session

        do {
            try session.start()
            await sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .join, payload: nil), retries: 2)
            startJoinHeartbeat(for: sessionID)
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

    private func establishWebRTCConnection(with qrData: DynamicQRCodeData) async throws -> RemoteConnection {
        guard webrtcSignalingAuthTokenBySessionId[qrData.sessionID]?.isEmpty == false else {
            throw CrossNetworkConnectionError.missingSignalingToken
        }
        try await ensureSignalingConnected(shardKey: qrData.sessionID)

        let sessionID = qrData.sessionID
        let snapshotMetadata = prepareSessionSnapshotMetadata(
            sessionID: sessionID,
            source: .qr,
            deviceId: qrData.deviceID,
            deviceName: qrData.deviceName
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
        let session = WebRTCSession(sessionId: sessionID, localDeviceId: localDeviceId, role: .answerer, ice: ice)

        session.onLocalAnswer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                self.webrtcLatestAnswerBySessionId[sessionID] = sdp
                await self.sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .answer, payload: .init(sdp: sdp)))
            }
        }
        session.onLocalICECandidate = { [weak self] payload in
            guard let self else { return }
            Task { @MainActor in
                self.cacheLocalICECandidate(payload, for: sessionID)
                await self.sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .iceCandidate, payload: payload))
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
                self.stopJoinHeartbeat(for: sessionID)
                self.currentConnection = RemoteConnection(id: sessionID, deviceName: qrData.deviceName, transport: .webrtc(session))
                self.connectionStatus = .connecting
                self.readiness = .transportReady(sessionId: sessionID)
                self.startWebRTCLivenessWatchdogIfNeeded(for: sessionID)
                self.updatePreparedSessionSnapshot(
                    sessionID: sessionID,
                    phase: .transportReady,
                    deviceId: qrData.deviceID,
                    deviceName: qrData.deviceName,
                    snapshotToken: snapshotMetadata.snapshotToken
                )
                self.startWebRTCInboundHandshakeAndControlLoop(sessionID: sessionID, session: session, endpointDescription: "webrtc:\(sessionID)")
            }
        }

        webrtcSessionsBySessionId[sessionID] = session

        do {
            try session.start()
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
        await sendSignal(.init(sessionId: sessionID, from: localDeviceId, type: .join, payload: nil), retries: 2)
        startJoinHeartbeat(for: sessionID)

        return RemoteConnection(id: sessionID, deviceName: qrData.deviceName, transport: .webrtc(session))
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
            connectionStatus = .failed("Missing signaling authorization")
            readiness = .idle
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
                        signalingHealth = isTransportEstablished(for: authorizedEnvelope.sessionId) ? .degradedRecoverable : .healthy
                    }
                }
                if attemptsLeft == 0 {
                    logger.error("❌ signaling send failed: type=\(authorizedEnvelope.type.rawValue, privacy: .public) session=\(authorizedEnvelope.sessionId, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                    appendSmokeStatus(
                        "signal-send-failed session=\(authorizedEnvelope.sessionId) type=\(authorizedEnvelope.type.rawValue) error=\(error.localizedDescription)"
                    )
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
        let failureClass = classifySignalingFailure(from: frame)
        logger.error("❌ signaling server rejected frame: session=\(sessionID ?? "-", privacy: .public) error=\(reason, privacy: .public)")
        appendSmokeStatus("signal-server-error session=\(sessionID ?? "-") error=\(reason)")

        guard let sessionID else {
            if reason == "server_error",
               webrtcSessionsBySessionId.keys.contains(where: isTransportEstablished(for:)) {
                logger.warning("ℹ️ ignore unscoped signaling server_error after transport establishment")
                return
            }
            connectionStatus = .failed("Signaling error: \(reason)")
            readiness = .idle
            return
        }

        if isTransportEstablished(for: sessionID) {
            if failureClass == .tokenExpired {
                signalingHealth = .degradedRecoverable
                scheduleSignalingRecovery(for: sessionID, tokenExpired: true)
            } else if isFatalPostTransportFailure(failureClass) {
                signalingHealth = .degradedFatal
            } else {
                signalingHealth = .degradedRecoverable
                scheduleSignalingRecovery(for: sessionID)
            }
            return
        }

        if isFatalPreTransportFailure(failureClass) {
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

    private func handleSignalingEnvelope(_ env: WebRTCSignalingEnvelope) {
        guard let session = webrtcSessionsBySessionId[env.sessionId] else {
            logger.debug("ℹ️ drop signaling envelope without local session: type=\(env.type.rawValue, privacy: .public) session=\(env.sessionId, privacy: .public)")
            return
        }
        guard env.from != session.localDeviceId else { return }

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
                await self?.resendCachedOfferIfNeeded(for: env.sessionId, reason: "remote-join")
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

    // MARK: - WebRTC File Transfer (macOS → iOS)

    private enum WebRTCFileTransferWaitError: LocalizedError {
        case timeout
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "跨网文件传输等待超时"
            case .cancelled:
                return "跨网文件传输已取消"
            case .failed(let msg):
                return "跨网文件传输失败: \(msg)"
            }
        }
    }

    private func fileTransferWaiterKey(sessionID: String, transferId: String, op: CrossNetworkFileTransferOp, chunkIndex: Int?) -> String {
        let idx = chunkIndex ?? -1
        return "\(sessionID)|\(transferId)|\(op.rawValue)|\(idx)"
    }

    private func resumeFileTransferWaiter(sessionID: String, message: CrossNetworkFileTransferMessage) {
        let key = fileTransferWaiterKey(sessionID: sessionID, transferId: message.transferId, op: message.op, chunkIndex: message.chunkIndex)
        if let waiter = webrtcFileTransferWaiters.removeValue(forKey: key) {
            waiter.resume(returning: message)
            return
        }

        // Also allow awaiting without chunkIndex.
        let keyNoIdx = fileTransferWaiterKey(sessionID: sessionID, transferId: message.transferId, op: message.op, chunkIndex: nil)
        if let waiter = webrtcFileTransferWaiters.removeValue(forKey: keyNoIdx) {
            waiter.resume(returning: message)
            return
        }
    }

    private func failFileTransferWaiters(sessionID: String, transferId: String, message: String) {
        let prefix = "\(sessionID)|\(transferId)|"
        let keys = webrtcFileTransferWaiters.keys.filter { $0.hasPrefix(prefix) }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.resume(throwing: WebRTCFileTransferWaitError.failed(message))
            }
        }
    }

    private func failAllFileTransferWaitersForSession(sessionID: String, message: String) {
        let prefix = "\(sessionID)|"
        let keys = webrtcFileTransferWaiters.keys.filter { $0.hasPrefix(prefix) }
        for k in keys {
            if let w = webrtcFileTransferWaiters.removeValue(forKey: k) {
                w.resume(throwing: WebRTCFileTransferWaitError.failed(message))
            }
        }
    }

    private func waitForFileTransferMessage(
        sessionID: String,
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int? = nil,
        timeoutSeconds: TimeInterval = 20
    ) async throws -> CrossNetworkFileTransferMessage {
        let key = fileTransferWaiterKey(sessionID: sessionID, transferId: transferId, op: op, chunkIndex: chunkIndex)
        if webrtcFileTransferWaiters[key] != nil {
            throw WebRTCFileTransferWaitError.cancelled
        }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CrossNetworkFileTransferMessage, Error>) in
            webrtcFileTransferWaiters[key] = c

            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                if let pending = self.webrtcFileTransferWaiters.removeValue(forKey: key) {
                    pending.resume(throwing: WebRTCFileTransferWaitError.timeout)
                }
            }
        }
    }

    private func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.sendKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined ?? Data()
    }

    private func sendFramed(_ payload: Data, over session: WebRTCSession) async throws {
        try await session.sendFramedPayloadAsync(payload)
    }

    private func sendFileTransferMessage(sessionID: String, session: WebRTCSession, keys: SessionKeys, message: CrossNetworkFileTransferMessage) async throws {
        let plain = try JSONEncoder().encode(message)
        let enc = try encryptAppPayload(plain, with: keys)
        let padded = TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-file")
        try await sendFramed(padded, over: session)
    }

    /// Send a local file to the currently connected iOS peer over WebRTC DataChannel (zero-config cross-network).
    public func sendFileToConnectedPeer(_ url: URL) async throws {
        guard case .connected = connectionStatus,
              let conn = currentConnection,
              case .webrtc(let session) = conn.transport
        else {
            throw WebRTCFileTransferWaitError.failed("未建立跨网连接")
        }

        let sessionID = conn.id
        guard let keys = webrtcSessionKeysBySessionId[sessionID] else {
            throw WebRTCFileTransferWaitError.failed("握手未完成（会话密钥不可用）")
        }

        // Validate file
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attrs[.type] as? FileAttributeType, type == .typeDirectory {
            throw WebRTCFileTransferWaitError.failed("暂不支持直接发送文件夹")
        }
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw WebRTCFileTransferWaitError.failed("文件大小无效")
        }

        let transferId = UUID().uuidString
        let remoteId = webrtcRemoteIdBySessionId[sessionID] ?? "webrtc-peer"
        let remoteName = conn.deviceName

        FileTransferManager.shared.beginExternalOutboundTransfer(
            transferId: transferId,
            fileURL: url,
            fileSize: fileSize,
            toDeviceId: remoteId,
            toDeviceName: remoteName
        )

        do {
            // DataChannel payload should stay conservative to avoid SCTP message-size rejection on mixed endpoints.
            let chunkSize = 16 * 1024
            let totalChunks = Int(ceil(Double(fileSize) / Double(chunkSize)))

            let snap = await SelfIdentityProvider.shared.snapshot()
            let meta = CrossNetworkFileTransferMessage(
                op: .metadata,
                transferId: transferId,
                senderDeviceId: snap.deviceId.isEmpty ? deviceFingerprint : snap.deviceId,
                senderDeviceName: Host.current().localizedName,
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                chunkSize: chunkSize,
                totalChunks: totalChunks,
                mimeType: nil
            )
            try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: meta)

            _ = try await waitForFileTransferMessage(sessionID: sessionID, transferId: transferId, op: .metadataAck, timeoutSeconds: 15)

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var sentBytes: Int64 = 0
            var chunkIndex = 0
            var fileHasher = SHA256()

            while sentBytes < fileSize {
                let remaining = Int(fileSize - sentBytes)
                let readLen = min(chunkSize, max(0, remaining))
                if readLen <= 0 { break }

                try handle.seek(toOffset: UInt64(sentBytes))
                let data = handle.readData(ofLength: readLen)
                if data.isEmpty { break }

                fileHasher.update(data: data)
                let msg = CrossNetworkFileTransferMessage(
                    op: .chunk,
                    transferId: transferId,
                    chunkIndex: chunkIndex,
                    chunkData: data,
                    chunkSha256: CrossNetworkCrypto.sha256(data),
                    rawSize: data.count
                )
                try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: msg)

                let ack: CrossNetworkFileTransferMessage = try await {
                    () async throws -> CrossNetworkFileTransferMessage in
                    var lastError: Error?
                    for _ in 0..<3 {
                        do {
                            return try await waitForFileTransferMessage(
                                sessionID: sessionID,
                                transferId: transferId,
                                op: .chunkAck,
                                chunkIndex: chunkIndex,
                                timeoutSeconds: 30
                            )
                        } catch {
                            lastError = error
                            // Best-effort resend: safe because receiver writes at fixed offset.
                            do {
                                try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: msg)
                            } catch {
                                lastError = error
                                break
                            }
                        }
                    }
                    throw lastError ?? WebRTCFileTransferWaitError.timeout
                }()

                if ack.op == .error {
                    throw WebRTCFileTransferWaitError.failed(ack.message ?? "remote error")
                }

                let progressed = ack.receivedBytes ?? (sentBytes + Int64(data.count))
                sentBytes = min(fileSize, max(sentBytes + Int64(data.count), progressed))
                chunkIndex += 1

                FileTransferManager.shared.updateExternalOutboundProgress(
                    transferId: transferId,
                    transferredBytes: sentBytes
                )
            }

            let fileSha = Data(fileHasher.finalize())
            let done = CrossNetworkFileTransferMessage(
                op: .complete,
                transferId: transferId,
                receivedBytes: fileSize,
                fileSha256: fileSha
            )
            try await sendFileTransferMessage(sessionID: sessionID, session: session, keys: keys, message: done)
            _ = try await waitForFileTransferMessage(sessionID: sessionID, transferId: transferId, op: .completeAck, timeoutSeconds: 30)

            FileTransferManager.shared.completeExternalOutboundTransfer(transferId: transferId)
        } catch {
            FileTransferManager.shared.failExternalOutboundTransfer(transferId: transferId, errorMessage: error.localizedDescription)
            throw error
        }
    }

    // MARK: - WebRTC -> Handshake/Control Channel

    private actor InboundChunkQueue {
        private var pending: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private var finished = false

        enum QueueError: Error {
            case finished
            case invalidReadLimit
        }

        func push(_ data: Data) {
            guard !finished else { return }
            if let w = waiters.first {
                waiters.removeFirst()
                w.resume(returning: data)
                return
            }
            pending.append(data)
        }

        func finish() {
            finished = true
            let ws = waiters
            waiters.removeAll()
            ws.forEach { $0.resume(throwing: QueueError.finished) }
        }

        func next() async throws -> Data {
            if let first = pending.first {
                pending.removeFirst()
                return first
            }
            if finished { throw QueueError.finished }
            return try await withCheckedThrowingContinuation { c in
                waiters.append(c)
            }
        }

        func next(max: Int) async throws -> Data {
            guard max > 0 else {
                throw QueueError.invalidReadLimit
            }
            let chunk = try await next()
            if chunk.count <= max {
                return chunk
            }
            let head = Data(chunk.prefix(max))
            let tail = Data(chunk.dropFirst(max))
            pending.insert(tail, at: 0)
            return head
        }
    }

    private func stopWebRTCScreenStreaming(sessionID: String) {
        if let task = webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            task.cancel()
        }
        if let task = webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID) {
            task.cancel()
        }
    }

    private func startWebRTCInboundHandshakeAndControlLoop(sessionID: String, session: WebRTCSession, endpointDescription: String) {
        if webrtcControlTasksBySessionId[sessionID] != nil { return }

        let queue = InboundChunkQueue()
        webrtcInboundQueuesBySessionId[sessionID] = queue
        session.onData = { data in
            Task { await queue.push(data) }
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
            fallbackPeerIDs: [peerDeviceId, endpointDescription]
        )

        let handshakeState = WebRTCHandshakeLoopState()

        func isLikelyHandshakeControlPacket(_ data: Data) -> Bool {
            if data.count == 38, (try? HandshakeFinished.decode(from: data)) != nil { return true }
            if (try? HandshakeMessageA.decode(from: data)) != nil { return true }
            if (try? HandshakeMessageB.decode(from: data)) != nil { return true }
            return false
        }

        func encryptAppPayload(_ plaintext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.sendKey)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            return sealed.combined ?? Data()
        }

        func decryptAppPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
            let key = SymmetricKey(data: keys.receiveKey)
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        }

        func decodeCompatibilityAppMessage(_ plaintext: Data) -> AppMessage? {
            let decoder = JSONDecoder()
            if let direct = try? decoder.decode(AppMessage.self, from: plaintext) {
                return direct
            }

            struct PlainEnvelope: Decodable {
                let clipboard: AppMessage.ClipboardPayload?
                let pairingIdentityExchange: AppMessage.PairingIdentityExchangePayload?
                let heartbeat: AppMessage.HeartbeatPayload?
                let ping: AppMessage.PingPayload?
                let pong: AppMessage.PongPayload?
            }

            guard let fallback = try? decoder.decode(PlainEnvelope.self, from: plaintext) else {
                return nil
            }
            if let payload = fallback.clipboard {
                return .clipboard(payload)
            }
            if let payload = fallback.pairingIdentityExchange {
                return .pairingIdentityExchange(payload)
            }
            if let payload = fallback.heartbeat {
                return .heartbeat(payload)
            }
            if let payload = fallback.ping {
                return .ping(payload)
            }
            if let payload = fallback.pong {
                return .pong(payload)
            }
            return nil
        }

        func orderedUniqueCandidateIds(_ rawValues: [String]) -> [String] {
            var seen = Set<String>()
            var ordered: [String] = []
            for raw in rawValues {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if seen.insert(trimmed).inserted {
                    ordered.append(trimmed)
                }
            }
            return ordered
        }

        func pairingExchangeFingerprint(_ payload: AppMessage.PairingIdentityExchangePayload) -> String {
            var hasher = SHA256()
            hasher.update(data: Data(payload.deviceId.utf8))
            for key in payload.kemPublicKeys.sorted(by: { $0.suiteWireId < $1.suiteWireId }) {
                hasher.update(data: Data("\(key.suiteWireId)".utf8))
                hasher.update(data: key.publicKey)
            }
            for format in (payload.remoteVideoFormats ?? []).map({ $0.lowercased() }).sorted() {
                hasher.update(data: Data(format.utf8))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func maybeStartOutboundPQCRekeyIfNeeded(
            from pairingPayload: AppMessage.PairingIdentityExchangePayload,
            trigger: String
        ) async {
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                print("🧪 mac maybeStartPQCRekey trigger=\(trigger) deviceId=\(pairingPayload.deviceId) keys=\(pairingPayload.kemPublicKeys.count)")
            }
            guard let establishedKeys = handshakeState.sessionKeys else { return }
            guard !establishedKeys.negotiatedSuite.isPQCGroup else { return }
            guard handshakeState.driver == nil else { return }
            guard !self.webrtcRekeyInProgressSessionIds.contains(sessionID) else { return }
            guard let shouldInitiate = Self.shouldInitiatePQCRekey(
                localDeviceId: session.localDeviceId,
                remoteDeviceId: pairingPayload.deviceId
            ) else {
                self.lastRekeyEvent = "waiting peer=\(pairingPayload.deviceId) election"
                logger.info(
                    "⏳ WebRTC rekey waiting for stable initiator election: session=\(sessionID, privacy: .public) trigger=\(trigger, privacy: .public) peer=\(pairingPayload.deviceId, privacy: .public)"
                )
                return
            }
            guard shouldInitiate else {
                self.lastRekeyEvent = "await inbound peer=\(pairingPayload.deviceId)"
                logger.info(
                    "ℹ️ WebRTC rekey elected peer as initiator; waiting inbound rekey: session=\(sessionID, privacy: .public) trigger=\(trigger, privacy: .public) peer=\(pairingPayload.deviceId, privacy: .public)"
                )
                return
            }

            let capability = CryptoProviderFactory.detectCapability()
            guard capability.hasApplePQC || capability.hasLiboqs else {
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac skip PQC rekey: no local PQC provider")
                }
                logger.info(
                    "ℹ️ WebRTC skip PQC rekey: local PQC provider unavailable. session=\(sessionID, privacy: .public) trigger=\(trigger, privacy: .public)"
                )
                return
            }

            let prefersLiboqsForPeer =
                (pairingPayload.platform ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("android") == .orderedSame

            func sharedPQCSuites(
                localPQCSuites: [CryptoSuite],
                with peerKEMPublicKeys: [UInt16: Data]
            ) -> [CryptoSuite] {
                var seenWireIds = Set<UInt16>()
                var shared: [CryptoSuite] = []

                for suite in localPQCSuites {
                    let canonicalWireId = suite.canonicalKEMSuite.wireId
                    guard peerKEMPublicKeys[canonicalWireId] != nil else { continue }
                    guard seenWireIds.insert(suite.wireId).inserted else { continue }
                    shared.append(suite)
                }

                return shared
            }

            let candidateIds = orderedUniqueCandidateIds([
                pairingPayload.deviceId,
                peerDeviceId,
                endpointDescription
            ])
            guard !candidateIds.isEmpty else { return }

            var peerKEMByCandidateId: [String: [UInt16: Data]] = [:]
            for candidateId in candidateIds {
                peerKEMByCandidateId[candidateId] = await PeerKEMBootstrapStore.shared
                    .mergedKEMPublicKeys(forCandidates: [candidateId])
            }

            let peerHasXWing = peerKEMByCandidateId.values.contains { $0[CryptoSuite.xwingMLDSA.wireId] != nil }

            let providerCandidates: [(provider: any CryptoProvider, label: String)] = {
                var candidates: [(provider: any CryptoProvider, label: String)] = []
                if capability.hasApplePQC, peerHasXWing {
                    candidates.append((CryptoProviderFactory.make(policy: .requirePQC), "native-xwing"))
                }
                if prefersLiboqsForPeer, capability.hasLiboqs {
                    candidates.append((OQSPQCCryptoProvider(), "liboqs"))
                }
                if capability.hasApplePQC && !peerHasXWing {
                    candidates.append((CryptoProviderFactory.make(policy: .requirePQC), "native-pqc"))
                }
                if !prefersLiboqsForPeer, capability.hasLiboqs {
                    candidates.append((OQSPQCCryptoProvider(), "liboqs-fallback"))
                }

                var seen = Set<String>()
                return candidates.filter { candidate in
                    let key = "\(candidate.label)|\(String(describing: type(of: candidate.provider)))"
                    return seen.insert(key).inserted
                }
            }()

            var selectedPeerId: String?
            var selectedProvider: (any CryptoProvider)?
            var selectedProviderLabel = ""
            var selectedCryptoPolicy: CryptoPolicy = .default
            var offeredSuites: [CryptoSuite] = []

            providerLoop: for candidate in providerCandidates {
                let candidateLocalSuites = DeviceIdentityKeyManager
                    .pairingIdentityAdvertisedPQCSuites(using: candidate.provider)
                    .filter(\.isPQCGroup)
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
                    let sharedSuites = sharedPQCSuites(
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
                let mergedPeerKEMPublicKeys = await PeerKEMBootstrapStore.shared
                    .mergedKEMPublicKeys(forCandidates: candidateIds)
                let missingCanonicalSuites = Array(Set(
                    providerCandidates
                        .flatMap { DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(using: $0.provider).filter(\.isPQCGroup) }
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
                    "⏳ WebRTC rekey waiting for peer KEM keys: session=\(sessionID, privacy: .public) trigger=\(trigger, privacy: .public) candidates=\(candidateIds.joined(separator: ","), privacy: .public) missing=\(missingSummary, privacy: .public)"
                )
                return
            }

            do {
                let identityProvider = DeviceIdentityHandshakeProvider(sigAAlgorithm: .mlDSA65)

                let outboundDriver = try HandshakeDriver(
                    transport: transport,
                    cryptoProvider: cryptoProvider,
                    protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: .mlDSA65),
                    identityProvider: identityProvider,
                    sigAAlgorithm: .mlDSA65,
                    offeredSuites: offeredSuites,
                    policy: .strictPQC,
                    cryptoPolicy: selectedCryptoPolicy
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
                    "🔁 WebRTC outbound PQC rekey start: session=\(sessionID, privacy: .public) trigger=\(trigger, privacy: .public) peer=\(selectedPeerId, privacy: .public) offered=\(offeredSummary, privacy: .public)"
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
                        self.logger.info(
                            "✅ WebRTC outbound PQC rekey completed: session=\(sessionID, privacy: .public) peer=\(selectedPeerId, privacy: .public) suite=\(rekeyed.negotiatedSuite.rawValue, privacy: .public)"
                        )
                    } catch {
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            print("🧪 mac PQC rekey task failed err=\(error.localizedDescription)")
                        }
                        guard handshakeState.driver === outboundDriver else { return }

                        if let fallbackKeys = handshakeState.previousSessionKeysBeforeRekey {
                            self.logger.warning(
                                "⚠️ WebRTC outbound PQC rekey failed, preserving established session: session=\(sessionID, privacy: .public) peer=\(selectedPeerId, privacy: .public) err=\(error.localizedDescription, privacy: .public)"
                            )
                            handshakeState.sessionKeys = fallbackKeys
                            handshakeState.previousSessionKeysBeforeRekey = nil
                            handshakeState.driver = nil
                            self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                            self.lastRekeyEvent = "failed reason=\(error.localizedDescription)"
                            self.webrtcSessionKeysBySessionId[sessionID] = fallbackKeys
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
            }
        }

        struct InboundFileTransferState {
            let transferId: String
            let fileName: String
            let fileSize: Int64
            let chunkSize: Int
            let totalChunks: Int
            let senderDeviceId: String
            let senderDeviceName: String?
            let tempURL: URL
            let finalURL: URL
            let handle: FileHandle
            var receivedBytes: Int64
            var completeRequestedAt: Date? = nil
            var expectedFileSha256: Data? = nil
            var expectedMerkleRoot: Data? = nil
            var expectedMerkleSig: Data? = nil
            var expectedMerkleSigAlg: String? = nil
            var chunkHashes: [Int: Data] = [:]
            var receivedChunkSizes: [Int: Int] = [:]
        }
        var inboundFileTransfers: [String: InboundFileTransferState] = [:]
        var inboundFileTransferCompleteTimers: [String: Task<Void, Never>] = [:]
        defer {
            for (_, task) in inboundFileTransferCompleteTimers {
                task.cancel()
            }
            inboundFileTransferCompleteTimers.removeAll()

            if !inboundFileTransfers.isEmpty {
                for st in inboundFileTransfers.values {
                    try? st.handle.close()
                    try? FileManager.default.removeItem(at: st.tempURL)
                    FileTransferManager.shared.failExternalTransfer(
                        transferId: st.transferId,
                        errorMessage: "WebRTC channel closed before transfer completion"
                    )
                }
                inboundFileTransfers.removeAll()
            }
        }

        func sanitizeFileName(_ name: String) -> String {
            let last = (name as NSString).lastPathComponent
            // Avoid empty / reserved names.
            let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "SkyBridgeFile" : trimmed
        }

        func makeUniqueDestinationURL(baseDir: URL, fileName: String) -> URL {
            let safe = sanitizeFileName(fileName)
            let ext = (safe as NSString).pathExtension
            let stem = (safe as NSString).deletingPathExtension

            var candidate = baseDir.appendingPathComponent(safe)
            var idx = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                let altName: String
                if ext.isEmpty {
                    altName = "\(stem) (\(idx))"
                } else {
                    altName = "\(stem) (\(idx)).\(ext)"
                }
                candidate = baseDir.appendingPathComponent(altName)
                idx += 1
            }
            return candidate
        }

        func sha256File(at url: URL) -> Data? {
            guard #available(macOS 10.15, iOS 13.0, *) else { return nil }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                let chunk = handle.readData(ofLength: 256 * 1024)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize())
        }

        let maxInboundChunkSize = 512 * 1024

        func expectedChunkCount(fileSize: Int64, chunkSize: Int) -> Int? {
            guard chunkSize > 0 else { return nil }
            if fileSize == 0 { return 0 }
            let total = (fileSize + Int64(chunkSize) - 1) / Int64(chunkSize)
            guard total >= 0, total <= Int64(Int.max) else { return nil }
            return Int(total)
        }

        func validateInboundMetadata(fileName: String, fileSize: Int64, chunkSize: Int, totalChunks: Int) -> String? {
            guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Invalid metadata (empty fileName)"
            }
            guard fileSize >= 0 else {
                return "Invalid metadata (negative fileSize)"
            }
            guard chunkSize > 0, chunkSize <= maxInboundChunkSize else {
                return "Invalid metadata (chunkSize out of range)"
            }
            guard totalChunks >= 0 else {
                return "Invalid metadata (negative totalChunks)"
            }
            guard let expectedTotalChunks = expectedChunkCount(fileSize: fileSize, chunkSize: chunkSize),
                  expectedTotalChunks == totalChunks else {
                return "Invalid metadata (fileSize/chunkSize/totalChunks mismatch)"
            }
            return nil
        }

        func expectedInboundChunkSize(state: InboundFileTransferState, index: Int) -> Int? {
            guard index >= 0, index < state.totalChunks else { return nil }
            let offset = Int64(index) * Int64(state.chunkSize)
            guard offset >= 0, offset <= state.fileSize else { return nil }
            let remaining = state.fileSize - offset
            guard remaining >= 0 else { return nil }
            return Int(min(Int64(state.chunkSize), remaining))
        }

        func hasRequiredIntegrityProof(_ state: InboundFileTransferState) -> Bool {
            if state.expectedFileSha256 != nil {
                return true
            }
            return state.expectedMerkleRoot != nil
                && state.expectedMerkleSig != nil
                && state.expectedMerkleSigAlg == CrossNetworkMerkleAuth.signatureAlgV1
        }

        func ensureAccessibilityPermission() -> Bool {
            if AXIsProcessTrusted() { return true }
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            return AXIsProcessTrusted()
        }

        func handleMouseEvent(_ event: MouseEventWire) {
            guard ensureAccessibilityPermission() else { return }
            let displayID = CGMainDisplayID()
            let screenH = Double(CGDisplayPixelsHigh(displayID))
            let point = CGPoint(x: event.x, y: screenH - event.y)
            func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
            switch event.type {
            case .mouseMoved:
                post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
            case .leftMouseDown:
                post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
            case .leftMouseUp:
                post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
            case .rightMouseDown:
                post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right))
            case .rightMouseUp:
                post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
            case .scrollUp:
                post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0))
            case .scrollDown:
                post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0))
            }
        }

        func handleKeyboardEvent(_ event: KeyboardEventWire) {
            guard ensureAccessibilityPermission() else { return }
            let keyCode = CGKeyCode(event.keyCode)
            let down = (event.type == .keyDown)
            let cg = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            cg?.post(tap: .cghidEventTap)
        }

        func jpegData(from image: CGImage, quality: CGFloat = 0.55) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return data as Data
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
            return WebRTCRemoteDesktopVideoPolicySelector.select(
                request: self.webrtcVideoRequest(
                    for: sessionID,
                    from: settings,
                    transportPath: transportPath
                ),
                transportPath: transportPath,
                peerFormats: peerFormats,
                thermalState: ProcessInfo.processInfo.thermalState,
                isAppleSilicon: Self.isAppleSiliconRuntime
            )
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
            let ciphertext = try encryptAppPayload(plaintext, with: sessionKeys)
            let padded = TrafficPadding.wrapIfEnabled(ciphertext, label: label)
            try await session.sendFramedPayloadAsync(
                padded,
                maxChunkBytes: 16 * 1024,
                maxBufferedAmountBytes: UInt64(maxBufferedAmountBytes)
            )
        }

        func startInteractionStreamingIfNeeded() {
            guard self.webrtcInteractionStreamingTasksBySessionId[sessionID] == nil else { return }
            self.webrtcInteractionStreamingTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
                guard let self else { return }

#if os(macOS)
                let heartbeatTimeoutSeconds: TimeInterval = 12.0
                let overlaySampleStride = 6
                let sampler = RemoteDesktopInteractionTelemetrySampler()
                var transportPath: WebRTCSession.ICETransportPath = .unknown
                var lastTransportProbeAt = Date.distantPast
                var overlayLoopIndex = 0
                var cursorChannelWasEnabled = false
                var overlayChannelWasEnabled = false

                defer {
                    self.webrtcInteractionStreamingTasksBySessionId.removeValue(forKey: sessionID)
                }

                while !Task.isCancelled {
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
                        transportPath = await session.currentICETransportPath()
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
            startInteractionStreamingIfNeeded()
            guard self.webrtcScreenStreamingTasksBySessionId[sessionID] == nil else { return }
            self.webrtcScreenStreamingTasksBySessionId[sessionID] = Task { @MainActor [weak self] in
                guard let self else { return }
                let heartbeatTimeoutSeconds: TimeInterval = 12.0
                let screenFrameChunkBytes = 16 * 1024
                var bytesSent: Int = 0
                var framesSent: Int = 0
                var logWindowStart = Date()
                var usingSyntheticFrames = false
                var transportPath: WebRTCSession.ICETransportPath = .unknown
                var lastTransportProbeAt = Date.distantPast
                var lastBudget: WebRTCRemoteDesktopStreamBudget?
                var lastVideoPolicy: WebRTCRemoteDesktopVideoPolicy?
                var lastSentFormat = ""
                var lastBackpressureReportAt = Date.distantPast
                let encodedFrameStore = LatestWebRTCEncodedFrameStore()
#if os(macOS)
                var directCaptureStreamer: ScreenCaptureKitStreamer?
                var lastHardwareFrameAt = Date.distantPast
                let damageTracker = CoarseDisplayDamageTracker()
                var pendingDamageReport: RemoteDesktopDamageReport?
#endif

                defer {
#if os(macOS)
                    Task { @MainActor in
                        directCaptureStreamer?.stop()
                    }
#endif
                    encodedFrameStore.clear()
                    self.webrtcScreenStreamingTasksBySessionId.removeValue(forKey: sessionID)
                }

                @MainActor
                func currentBudget(
                    for transportPath: WebRTCSession.ICETransportPath,
                    videoPolicy: WebRTCRemoteDesktopVideoPolicy
                ) -> WebRTCRemoteDesktopStreamBudget {
                    let settings = RemoteDesktopSettingsManager.shared.settings.displaySettings
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
                        thermalState: ProcessInfo.processInfo.thermalState,
                        longEdge: max(1, longEdge),
                        lowLatencyMode: settings.lowLatencyMode,
                        codec: videoPolicy.codec,
                        enableHardwareAcceleration: settings.enableHardwareAcceleration,
                        enableAppleSiliconOptimization: settings.enableAppleSiliconOptimization,
                        isAppleSilicon: Self.isAppleSiliconRuntime
                    )
                }

#if os(macOS)
                @MainActor
                func ensureDirectEncoder(
                    for videoPolicy: WebRTCRemoteDesktopVideoPolicy
                ) async -> Bool {
                    let nativeVideoTrackEnabled = session.supportsNativeScreenVideoTrack
                    guard videoPolicy.usesHardwareEncoder || nativeVideoTrackEnabled else {
                        if let directCaptureStreamer {
                            directCaptureStreamer.stop()
                            self.logger.info(
                                "🛑 WebRTC ScreenCaptureKit 直连硬编停止，回退到 JPEG: session=\(sessionID, privacy: .public)"
                            )
                        }
                        directCaptureStreamer = nil
                        encodedFrameStore.clear()
                        return false
                    }

                    if let current = lastVideoPolicy,
                       current == videoPolicy,
                       directCaptureStreamer != nil {
                        return true
                    }

                    directCaptureStreamer?.stop()
                    directCaptureStreamer = nil
                    encodedFrameStore.clear()

                    let captureStreamer = ScreenCaptureKitStreamer()
                    if nativeVideoTrackEnabled {
                        captureStreamer.onRawFrame = { pixelBuffer, presentationTimeStamp in
                            let width = CVPixelBufferGetWidth(pixelBuffer)
                            let height = CVPixelBufferGetHeight(pixelBuffer)
                            let timeStampNs: Int64
                            if presentationTimeStamp.isValid,
                               presentationTimeStamp.seconds.isFinite {
                                timeStampNs = Int64(
                                    max(
                                        0,
                                        (presentationTimeStamp.seconds * 1_000_000_000.0).rounded()
                                    )
                                )
                            } else {
                                timeStampNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000.0)
                            }
                            session.prepareOutgoingScreenVideo(
                                width: width,
                                height: height,
                                fps: videoPolicy.targetFrameRate
                            )
                            session.pushVideoFrame(
                                pixelBuffer: pixelBuffer,
                                timeStampNs: timeStampNs
                            )
                        }
                    } else {
                        captureStreamer.onEncodedFrame = { data, width, height, frameType, isSyncFrame in
                            encodedFrameStore.store(
                                .init(
                                    width: width,
                                    height: height,
                                    imageData: data,
                                    timestamp: Date().timeIntervalSince1970,
                                    format: Self.remoteFrameFormatName(frameType: frameType, payload: data),
                                    isSyncFrame: isSyncFrame
                                )
                            )
                        }
                    }
                    captureStreamer.onCaptureIssue = { issue in
                        self.logger.warning(
                            "⚠️ WebRTC ScreenCaptureKit 采集提示: session=\(sessionID, privacy: .public) issue=\(issue, privacy: .public)"
                        )
                    }

                    do {
                        try await captureStreamer.start(
                            preferredCodec: videoPolicy.codec,
                            preferredSize: videoPolicy.preferredSize,
                            targetFPS: videoPolicy.targetFrameRate,
                            keyFrameInterval: videoPolicy.keyFrameInterval,
                            captureCursorInVideo: !nativeVideoTrackEnabled,
                            bitstreamFormat: nativeVideoTrackEnabled ? .native : .annexB
                        )
                        directCaptureStreamer = captureStreamer
                        self.logger.info(
                            """
                            🎥 WebRTC ScreenCaptureKit 直连硬编已启动: session=\(sessionID, privacy: .public) \
                            codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data()), privacy: .public) \
                            fps=\(videoPolicy.targetFrameRate, privacy: .public) \
                            size=\(Int(videoPolicy.preferredSize.width), privacy: .public)x\(Int(videoPolicy.preferredSize.height), privacy: .public) \
                            reason=\(videoPolicy.reason, privacy: .public)
                            """
                        )
                        self.appendSmokeStatus(
                            "stream-sck-started session=\(sessionID) codec=\(nativeVideoTrackEnabled ? "webrtc-native-video" : Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data()))"
                        )
                        return true
                    } catch {
                        captureStreamer.stop()
                        directCaptureStreamer = nil
                        encodedFrameStore.clear()
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
                        let newPath = await session.currentICETransportPath()
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
                    let useDedicatedScreenChannel = streamConfig?.screenDataChannelEnabled == true
                    if useDedicatedScreenChannel {
                        try? session.ensureScreenDataChannel()
                    }
                    let selectedVideoPolicy = currentVideoPolicy(for: transportPath)
                    let budget = currentBudget(for: transportPath, videoPolicy: selectedVideoPolicy)
                    let videoPolicy = WebRTCRemoteDesktopVideoPolicy(
                        codec: selectedVideoPolicy.codec,
                        targetFrameRate: min(selectedVideoPolicy.targetFrameRate, budget.frameRate),
                        keyFrameInterval: selectedVideoPolicy.keyFrameInterval,
                        preferredSize: selectedVideoPolicy.preferredSize,
                        usesHardwareEncoder: selectedVideoPolicy.usesHardwareEncoder,
                        reason: selectedVideoPolicy.reason
                    )
                    if videoPolicy != lastVideoPolicy {
                        if lastVideoPolicy?.preferredSize != videoPolicy.preferredSize {
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
                            reason=\(videoPolicy.reason, privacy: .public)
                            """
                        )
                        self.appendSmokeStatus(
                            """
                            stream-policy session=\(sessionID) path=\(transportPath.rawValue) \
                            codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data())) \
                            fps=\(videoPolicy.targetFrameRate) gop=\(videoPolicy.keyFrameInterval) \
                            reason=\(videoPolicy.reason)
                            """
                        )
                    }
                    if budget != lastBudget {
                        self.logger.info(
                            """
                            🎛️ WebRTC 推流预算: session=\(sessionID, privacy: .public) \
                            path=\(transportPath.rawValue, privacy: .public) \
                            fps=\(budget.frameRate, privacy: .public) \
                            buffered=\(Int(budget.maxBufferedAmountBytes), privacy: .public) \
                            reason=\(budget.reason, privacy: .public)
                            """
                        )
                        self.appendSmokeStatus(
                            """
                            stream-budget session=\(sessionID) path=\(transportPath.rawValue) \
                            fps=\(budget.frameRate) buffered=\(Int(budget.maxBufferedAmountBytes)) \
                            reason=\(budget.reason)
                            """
                        )
                        lastBudget = budget
                    }
#if os(macOS)
                    _ = await ensureDirectEncoder(for: videoPolicy)
                    if self.consumePendingWebRTCStreamRefresh(for: sessionID) {
                        directCaptureStreamer?.requestKeyFrameRefresh(reason: "viewer-stream-refresh")
                        self.logger.info(
                            "🪄 WebRTC viewer 请求关键帧刷新: session=\(sessionID, privacy: .public)"
                        )
                    }
                    if session.supportsNativeScreenVideoTrack {
                        if lastSentFormat != "webrtc-native-video" {
                            self.appendSmokeStatus(
                                "stream-format session=\(sessionID) format=webrtc-native-video"
                            )
                            lastSentFormat = "webrtc-native-video"
                        }
                        lastVideoPolicy = videoPolicy
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                        } catch {
                            break
                        }
                        continue
                    }
#endif
                    lastVideoPolicy = videoPolicy
                    do {
                        let frameIntervalNs = max(1_000_000_000 / budget.frameRate, 1_000_000)
                        try await Task.sleep(for: .nanoseconds(frameIntervalNs))
                    } catch {
                        break
                    }
                    let bufferedAmount = useDedicatedScreenChannel
                        ? session.screenDataChannelBufferedAmountBytes()
                        : session.dataChannelBufferedAmountBytes()
                    if bufferedAmount > budget.maxBufferedAmountBytes {
                        self.logger.debug(
                            "⏳ WebRTC 屏幕推流背压：跳过本帧 buffered=\(Int(bufferedAmount), privacy: .public) budget=\(Int(budget.maxBufferedAmountBytes), privacy: .public)"
                        )
                        if Date().timeIntervalSince(lastBackpressureReportAt) >= 1.0 {
                            self.appendSmokeStatus(
                                "stream-backpressure session=\(sessionID) buffered=\(Int(bufferedAmount)) budget=\(Int(budget.maxBufferedAmountBytes))"
                            )
                            lastBackpressureReportAt = Date()
                        }
                        continue
                    }
                    var capturedFrame: ScreenDataWire?
                    if let synthetic = syntheticScreenDataIfEnabled() {
                        if !usingSyntheticFrames {
                            usingSyntheticFrames = true
                            self.logger.info("🧪 WebRTC smoke 使用合成屏幕帧: session=\(sessionID, privacy: .public)")
                        }
                        capturedFrame = synthetic
                    }
#if os(macOS)
                    if capturedFrame == nil {
                        let directEncodedFrame = videoPolicy.usesHardwareEncoder
                            ? encodedFrameStore.takeLatest()
                            : nil
                        if let encodedFrame = directEncodedFrame {
                            lastHardwareFrameAt = Date()
                            capturedFrame = ScreenDataWire(
                                width: encodedFrame.width,
                                height: encodedFrame.height,
                                imageData: encodedFrame.imageData,
                                timestamp: encodedFrame.timestamp,
                                format: encodedFrame.format,
                                isSyncFrame: encodedFrame.isSyncFrame
                            )
                        } else if videoPolicy.usesHardwareEncoder {
                            if Date().timeIntervalSince(lastHardwareFrameAt) > 1.0 {
                                self.appendSmokeStatus(
                                    "stream-hardware-wait session=\(sessionID) codec=\(Self.remoteFrameFormatName(frameType: videoPolicy.codec, payload: Data()))"
                                )
                            }
                            continue
                        }
                    }
#endif
                    if capturedFrame == nil,
                       let img = CGDisplayCreateImage(CGMainDisplayID()),
                       let jpg = jpegData(from: img) {
                        let damageTrackingEnabled = self.webrtcRemoteStreamConfigurationBySessionId[sessionID]?.damageTrackingEnabled ?? true
                        if damageTrackingEnabled {
                            if let report = damageTracker.analyze(image: img) {
                                pendingDamageReport = report
                            } else {
                                continue
                            }
                        }
                        capturedFrame = ScreenDataWire(
                            width: img.width,
                            height: img.height,
                            imageData: jpg,
                            timestamp: Date().timeIntervalSince1970,
                            format: "jpeg",
                            isSyncFrame: true
                        )
                    }
                    guard let sd = capturedFrame else {
                        continue
                    }
                    if let damageReport = pendingDamageReport,
                       let damagePayload = try? JSONEncoder().encode(damageReport),
                       let damageEnvelope = try? JSONEncoder().encode(
                        RemoteMessageWire(type: .damageReport, payload: damagePayload)
                       ) {
                        do {
                            let damageCiphertext = try encryptAppPayload(damageEnvelope, with: keys)
                            let paddedDamage = TrafficPadding.wrapIfEnabled(damageCiphertext, label: "tx/webrtc-damage")
                            try await session.sendFramedPayloadAsync(
                                paddedDamage,
                                maxChunkBytes: screenFrameChunkBytes,
                                maxBufferedAmountBytes: budget.maxBufferedAmountBytes
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
                    if formatLabel != lastSentFormat {
                        self.appendSmokeStatus(
                            "stream-format session=\(sessionID) format=\(formatLabel)"
                        )
                        lastSentFormat = formatLabel
                    }
                    let plain = RemoteDesktopScreenFrameWire.encode(
                        width: sd.width,
                        height: sd.height,
                        imageData: sd.imageData,
                        timestamp: sd.timestamp,
                        format: sd.format,
                        isSyncFrame: sd.isSyncFrame
                    )

                    do {
                        let enc = try encryptAppPayload(plain, with: keys)
                        let padded = TrafficPadding.wrapIfEnabled(enc, label: "tx/webrtc-screen")
                        try await session.sendScreenFramedPayloadAsync(
                            padded,
                            maxChunkBytes: screenFrameChunkBytes,
                            maxBufferedAmountBytes: budget.maxBufferedAmountBytes
                        )
                        bytesSent += padded.count + 4
                        framesSent += 1
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil,
                           framesSent <= 3 {
                            self.appendSmokeStatus(
                                "screen-send session=\(sessionID) bytes=\(padded.count) format=\(formatLabel)"
                            )
                        }
                        let elapsed = Date().timeIntervalSince(logWindowStart)
                        if elapsed >= 5.0 {
                            let upMBps = Double(bytesSent) / elapsed / 1024.0 / 1024.0
                            let fps = Double(framesSent) / elapsed
                            self.logger.info(
                                "📈 WebRTC 屏幕推流吞吐: session=\(sessionID, privacy: .public) up=\(String(format: "%.2f", upMBps), privacy: .public)MB/s fps=\(String(format: "%.1f", fps), privacy: .public)"
                            )
                            self.appendSmokeStatus(
                                """
                                stream-stats session=\(sessionID) fps=\(String(format: "%.1f", fps)) \
                                up_mbps=\(String(format: "%.2f", upMBps * 8.0)) \
                                buffered=\(Int(session.dataChannelBufferedAmountBytes())) \
                                format=\(formatLabel)
                                """
                            )
                            bytesSent = 0
                            framesSent = 0
                            logWindowStart = Date()
                        }
                    } catch {
                        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                            self.appendSmokeStatus(
                                "screen-send-failed session=\(sessionID) error=\(error.localizedDescription)"
                            )
                        }
                        self.logger.error("❌ WebRTC 屏幕推流发送失败: \(error.localizedDescription, privacy: .public)")
                        break
                    }
                }
            }
        }

        logger.info("🤝 WebRTC 控制通道：启动入站握手/消息循环 session=\(sessionID, privacy: .public)")

        let maxInboundFrameBytes = 8_000_000

        do {
            while true {
                let lenData = try await receiveExactly(4)
                let totalLen = lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                guard totalLen > 0 && totalLen < maxInboundFrameBytes else {
                    logger.warning("⚠️ WebRTC frame length out of range: len=\(Int(totalLen), privacy: .public) max=\(maxInboundFrameBytes, privacy: .public)")
                    break
                }
                let payload = try await receiveExactly(Int(totalLen))
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac rx frame totalLen=\(Int(totalLen))")
                }

                let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: "rx/webrtc")
                let frame = HandshakePadding.unwrapIfNeeded(trafficUnwrapped, label: "rx/webrtc")

                if let activeDriver = handshakeState.driver {
                    let driverState = await activeDriver.getCurrentState()
                    if case .waitingFinished(_, _, .initiator) = driverState,
                       (try? HandshakeMessageA.decode(from: frame)) != nil {
                        logger.warning(
                            "♻️ WebRTC responder restarting unfinished handshake from fresh MessageA: session=\(sessionID, privacy: .public) peer=\(peerDeviceId, privacy: .public)"
                        )
                        handshakeState.driver = nil
                        handshakeState.sessionKeys = nil
                        handshakeState.previousSessionKeysBeforeRekey = nil
                        self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                        self.webrtcSessionKeysBySessionId.removeValue(forKey: sessionID)
                        self.lastRekeyEvent = "restart peer=\(peerDeviceId)"
                    }
                }

                if let keys = handshakeState.sessionKeys {
                    do {
                        let plaintext = try decryptAppPayload(frame, with: keys)
                        if let msg = decodeCompatibilityAppMessage(plaintext) {
                            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                switch msg {
                                case .pairingIdentityExchange(let payload):
                                    print("🧪 mac app message=pairingIdentityExchange deviceId=\(payload.deviceId) keys=\(payload.kemPublicKeys.count)")
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
                            switch msg {
                            case .pairingIdentityExchange(let payload):
                                let remoteFormatsSummary = (payload.remoteVideoFormats ?? []).joined(separator: ",")
                                self.appendSmokeStatus(
                                    "app-pairing-recv session=\(sessionID) formats=\(remoteFormatsSummary)"
                                )
                                self.updateCrossNetworkRemoteMetadata(
                                    sessionID: sessionID,
                                    deviceId: payload.deviceId,
                                    deviceName: payload.deviceName
                                )
                                self.webrtcRemoteVideoFormatsBySessionId[sessionID] = Set(
                                    (payload.remoteVideoFormats ?? []).map { $0.lowercased() }
                                )
                                let request = PairingTrustApprovalService.Request(
                                    peerEndpoint: endpointDescription,
                                    declaredDeviceId: payload.deviceId,
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

                                    let peerPlatform = (payload.platform ?? "")
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    let provider: any CryptoProvider = {
                                        if peerPlatform.localizedCaseInsensitiveCompare("ubuntu") == .orderedSame,
                                           SystemCryptoEnvironment.system.checkLiboqsAvailable() {
                                            return OQSPQCCryptoProvider()
                                        }
                                        return CryptoProviderFactory.make(policy: .preferPQC)
                                    }()
                                    let km = DeviceIdentityKeyManager.shared
                                    let kemKeys: [KEMPublicKeyInfo]
                                    do {
                                        kemKeys = try await km.pairingIdentityKEMPublicKeys(using: provider)
                                    } catch {
                                        logger.warning("⚠️ WebRTC bootstrap reply KEM 公钥准备失败: \(error.localizedDescription, privacy: .public)")
                                        self.appendSmokeStatus(
                                            "app-pairing-send-failed session=\(sessionID) stage=prepare_kem error=\(sanitizeStatus(error.localizedDescription))"
                                        )
                                        return
                                    }

                                    let selfIdentity = await SelfIdentityProvider.shared.snapshot()
                                    let localId = selfIdentity.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? await DeviceIdentityKeyManager.shared.getDeviceId()
                                        : selfIdentity.deviceId
                                    let localPlatform: String = {
#if os(macOS)
                                        return "macOS"
#elseif os(iOS)
                                        return "iOS"
#else
                                        return "unknown"
#endif
                                    }()
                                    let localOS = ProcessInfo.processInfo.operatingSystemVersionString
                                    let localName: String? = {
#if os(macOS)
                                        return Host.current().localizedName
#elseif os(iOS)
                                        return UIDevice.current.name
#else
                                        return nil
#endif
                                    }()
                                    let localModel: String? = {
#if os(macOS)
                                        return "Mac"
#elseif os(iOS)
                                        return UIDevice.current.model
#else
                                        return nil
#endif
                                    }()
                                    let replyPayload = AppMessage.PairingIdentityExchangePayload(
                                        deviceId: localId,
                                        kemPublicKeys: kemKeys,
                                        deviceName: localName,
                                        modelName: localModel,
                                        platform: localPlatform,
                                        osVersion: localOS,
                                        chip: nil,
                                        remoteVideoFormats: Self.supportedRemoteVideoFormats()
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
                                self.webrtcRemoteDesktopHeartbeatAtBySessionId[sessionID] = Date()
                                self.updateCrossNetworkRemoteMetadata(
                                    sessionID: sessionID,
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
                        } else if let ft = try? JSONDecoder().decode(CrossNetworkFileTransferMessage.self, from: plaintext), ft.version == 1 {
                            switch ft.op {
                            case .metadata:
                                // Idempotent: allow re-sending metadata for the same transferId (resume).
                                if inboundFileTransfers[ft.transferId] != nil {
                                    let ack = CrossNetworkFileTransferMessage(op: .metadataAck, transferId: ft.transferId)
                                    let outPlain = try JSONEncoder().encode(ack)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-metaAck")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                guard
                                    let fileName = ft.fileName,
                                    let fileSize = ft.fileSize,
                                    let chunkSize = ft.chunkSize,
                                    let totalChunks = ft.totalChunks
                                else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        message: "Invalid metadata (missing fileName/fileSize/chunkSize/totalChunks)"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                if let validationError = validateInboundMetadata(
                                    fileName: fileName,
                                    fileSize: fileSize,
                                    chunkSize: chunkSize,
                                    totalChunks: totalChunks
                                ) {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        message: validationError
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                guard let downloadsDirectory = FileManager.default
                                    .urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        message: "Downloads directory unavailable"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }
                                let baseDir = downloadsDirectory
                                    .appendingPathComponent("SkyBridge", isDirectory: true)
                                try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

                                let finalURL = makeUniqueDestinationURL(baseDir: baseDir, fileName: fileName)
                                let tempURL = baseDir.appendingPathComponent(".skybridge-\(ft.transferId).partial")
                                _ = FileManager.default.createFile(atPath: tempURL.path, contents: nil)

                                let handle = try FileHandle(forWritingTo: tempURL)
                                let senderId = ft.senderDeviceId ?? endpointDescription
                                let senderName = ft.senderDeviceName ?? senderId

                                inboundFileTransfers[ft.transferId] = InboundFileTransferState(
                                    transferId: ft.transferId,
                                    fileName: fileName,
                                    fileSize: fileSize,
                                    chunkSize: chunkSize,
                                    totalChunks: totalChunks,
                                    senderDeviceId: senderId,
                                    senderDeviceName: senderName,
                                    tempURL: tempURL,
                                    finalURL: finalURL,
                                    handle: handle,
                                    receivedBytes: 0
                                )

                                await MainActor.run {
                                    FileTransferManager.shared.beginExternalInboundTransfer(
                                        transferId: ft.transferId,
                                        fileName: fileName,
                                        fileSize: fileSize,
                                        fromDeviceId: senderId,
                                        fromDeviceName: senderName
                                    )
                                }

                                let ack = CrossNetworkFileTransferMessage(op: .metadataAck, transferId: ft.transferId)
                                let outPlain = try JSONEncoder().encode(ack)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-metaAck")
                                try await sendFramed(outPadded)

                            case .chunk:
                                guard
                                    let idx = ft.chunkIndex,
                                    let data = ft.chunkData
                                else { break }
                                guard var st = inboundFileTransfers[ft.transferId] else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        message: "Unknown transferId (no metadata)"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                if let expected = ft.chunkSha256, CrossNetworkCrypto.sha256(data) != expected {
                                    // Backward compatible: only enforce if hash provided.
                                    // Don't ACK corrupted chunk; sender will timeout/retry as appropriate.
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        chunkIndex: idx,
                                        message: "chunk hash mismatch"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                // Track actual chunk hashes for optional Merkle verification.
                                let rawSize = ft.rawSize ?? data.count
                                guard idx >= 0, idx < st.totalChunks else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        chunkIndex: idx,
                                        message: "chunk index out of range"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }
                                guard rawSize >= 0, rawSize == data.count, rawSize <= st.chunkSize else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        chunkIndex: idx,
                                        message: "invalid chunk size"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }
                                guard let expectedChunkSize = expectedInboundChunkSize(state: st, index: idx),
                                      expectedChunkSize == rawSize else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: ft.transferId,
                                        chunkIndex: idx,
                                        message: "chunk length does not match metadata"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                let actualHash = CrossNetworkCrypto.sha256(data)
                                if let existingHash = st.chunkHashes[idx] {
                                    guard existingHash == actualHash, st.receivedChunkSizes[idx] == rawSize else {
                                        let err = CrossNetworkFileTransferMessage(
                                            op: .error,
                                            transferId: ft.transferId,
                                            chunkIndex: idx,
                                            message: "duplicate chunk content mismatch"
                                        )
                                        let outPlain = try JSONEncoder().encode(err)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                        try await sendFramed(outPadded)
                                        break
                                    }
                                } else {
                                    let offset = Int64(idx) * Int64(st.chunkSize)
                                    guard offset >= 0, offset + Int64(rawSize) <= st.fileSize else {
                                        let err = CrossNetworkFileTransferMessage(
                                            op: .error,
                                            transferId: ft.transferId,
                                            chunkIndex: idx,
                                            message: "chunk exceeds declared file size"
                                        )
                                        let outPlain = try JSONEncoder().encode(err)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                        try await sendFramed(outPadded)
                                        break
                                    }
                                    try st.handle.seek(toOffset: UInt64(offset))
                                    try st.handle.write(contentsOf: data)
                                    st.chunkHashes[idx] = actualHash
                                    st.receivedChunkSizes[idx] = rawSize
                                    st.receivedBytes += Int64(rawSize)
                                }
                                // If complete was already requested earlier, finalize once we have enough.
                                if st.completeRequestedAt != nil && st.receivedBytes >= st.fileSize {
                                    // Close + move temp -> final + ACK complete, matching old behavior but delayed.
                                    do { try st.handle.close() } catch {}
                                    do {
                                        if let expectedMerkle = st.expectedMerkleRoot {
                                            let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                                            if leaves.count != st.totalChunks || CrossNetworkMerkle.root(leaves: leaves) != expectedMerkle {
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: st.transferId,
                                                        errorMessage: "merkle root mismatch"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                try? FileManager.default.removeItem(at: st.tempURL)
                                                let err = CrossNetworkFileTransferMessage(
                                                    op: .error,
                                                    transferId: st.transferId,
                                                    message: "merkle root mismatch"
                                                )
                                                let outPlain = try JSONEncoder().encode(err)
                                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                try await sendFramed(outPadded)
                                                break
                                            }

                                            if let sig = st.expectedMerkleSig {
                                                if st.expectedMerkleSigAlg != CrossNetworkMerkleAuth.signatureAlgV1 {
                                                    await MainActor.run {
                                                        FileTransferManager.shared.failExternalTransfer(
                                                            transferId: st.transferId,
                                                            errorMessage: "unknown merkle sig alg"
                                                        )
                                                    }
                                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                    try? FileManager.default.removeItem(at: st.tempURL)
                                                    let err = CrossNetworkFileTransferMessage(
                                                        op: .error,
                                                        transferId: st.transferId,
                                                        message: "unknown merkle sig alg"
                                                    )
                                                    let outPlain = try JSONEncoder().encode(err)
                                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                    try await sendFramed(outPadded)
                                                    break
                                                }
                                                let pre = CrossNetworkMerkleAuth.preimage(
                                                    transferId: st.transferId,
                                                    merkleRoot: expectedMerkle,
                                                    fileSha256: st.expectedFileSha256
                                                )
                                                let expectSig = CrossNetworkMerkleAuth.hmacSha256(key: keys.receiveKey, data: pre)
                                                if sig != expectSig {
                                                    await MainActor.run {
                                                        FileTransferManager.shared.failExternalTransfer(
                                                            transferId: st.transferId,
                                                            errorMessage: "merkle signature mismatch"
                                                        )
                                                    }
                                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                    try? FileManager.default.removeItem(at: st.tempURL)
                                                    let err = CrossNetworkFileTransferMessage(
                                                        op: .error,
                                                        transferId: st.transferId,
                                                        message: "merkle signature mismatch"
                                                    )
                                                    let outPlain = try JSONEncoder().encode(err)
                                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                    try await sendFramed(outPadded)
                                                    break
                                                }
                                            }
                                        }

                                        if let expected = st.expectedFileSha256, let actual = sha256File(at: st.tempURL), actual != expected {
                                            await MainActor.run {
                                                FileTransferManager.shared.failExternalTransfer(
                                                    transferId: st.transferId,
                                                    errorMessage: "file sha256 mismatch"
                                                )
                                            }
                                            inboundFileTransfers.removeValue(forKey: st.transferId)
                                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                            try? FileManager.default.removeItem(at: st.tempURL)

                                            let err = CrossNetworkFileTransferMessage(
                                                op: .error,
                                                transferId: st.transferId,
                                                message: "file sha256 mismatch"
                                            )
                                            let outPlain = try JSONEncoder().encode(err)
                                            let outCipher = try encryptAppPayload(outPlain, with: keys)
                                            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                            try await sendFramed(outPadded)
                                            break
                                        }
                                        if FileManager.default.fileExists(atPath: st.finalURL.path) {
                                            try? FileManager.default.removeItem(at: st.finalURL)
                                        }
                                        try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                                        await MainActor.run {
                                            FileTransferManager.shared.completeExternalInboundTransfer(
                                                transferId: st.transferId,
                                                savedTo: st.finalURL
                                            )
                                        }
                                        inboundFileTransfers.removeValue(forKey: st.transferId)
                                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                        let ack = CrossNetworkFileTransferMessage(op: .completeAck, transferId: st.transferId)
                                        let outPlain = try JSONEncoder().encode(ack)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-completeAck")
                                        try await sendFramed(outPadded)
                                        break
                                    } catch {
                                        await MainActor.run {
                                            FileTransferManager.shared.failExternalTransfer(
                                                transferId: st.transferId,
                                                errorMessage: "Save failed: \(error.localizedDescription)"
                                            )
                                        }
                                        inboundFileTransfers.removeValue(forKey: st.transferId)
                                    }
                                }
                                inboundFileTransfers[ft.transferId] = st

                                await MainActor.run {
                                    FileTransferManager.shared.updateExternalInboundProgress(
                                        transferId: st.transferId,
                                        transferredBytes: st.receivedBytes
                                    )
                                }

                                let ack = CrossNetworkFileTransferMessage(
                                    op: .chunkAck,
                                    transferId: st.transferId,
                                    chunkIndex: idx,
                                    receivedBytes: st.receivedBytes
                                )
                                let outPlain = try JSONEncoder().encode(ack)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-chunkAck")
                                try await sendFramed(outPadded)

                            case .complete:
                                guard var st = inboundFileTransfers[ft.transferId] else { break }

                                // Capture expected full-file hash (optional, backward compatible).
                                if st.expectedFileSha256 == nil { st.expectedFileSha256 = ft.fileSha256 }
                                if st.expectedMerkleRoot == nil { st.expectedMerkleRoot = ft.merkleRoot }
                                if st.expectedMerkleSig == nil { st.expectedMerkleSig = ft.merkleRootSignature }
                                if st.expectedMerkleSigAlg == nil { st.expectedMerkleSigAlg = ft.merkleRootSignatureAlg }

                                guard hasRequiredIntegrityProof(st) else {
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: st.transferId,
                                        message: "missing integrity proof"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                    inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                    inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                    try? st.handle.close()
                                    try? FileManager.default.removeItem(at: st.tempURL)
                                    await MainActor.run {
                                        FileTransferManager.shared.failExternalTransfer(
                                            transferId: st.transferId,
                                            errorMessage: "Missing integrity proof"
                                        )
                                    }
                                    break
                                }

                                if st.receivedBytes < st.fileSize {
                                    // Optional NACK: request missing chunks (backward compatible).
                                    let missing = (0..<st.totalChunks).filter { st.chunkHashes[$0] == nil }
                                    if !missing.isEmpty {
                                        let nack = CrossNetworkFileTransferMessage(
                                            op: .chunkAck,
                                            transferId: st.transferId,
                                            missingChunks: missing.prefix(512).map { Int($0) },
                                            message: "missingChunks"
                                        )
                                        let outPlain = try JSONEncoder().encode(nack)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-missingChunks")
                                        try await sendFramed(outPadded)
                                    }

                                    // Don't fail immediately; mark complete requested and wait for retransmits.
                                    if st.completeRequestedAt == nil { st.completeRequestedAt = Date() }
                                    inboundFileTransfers[st.transferId] = st
                                    if inboundFileTransferCompleteTimers[st.transferId] == nil {
                                        inboundFileTransferCompleteTimers[st.transferId] = Task {
                                            try? await Task.sleep(for: .seconds(10))
                                            if let cur = inboundFileTransfers[st.transferId], cur.receivedBytes < cur.fileSize {
                                                do { try cur.handle.close() } catch {}
                                                try? FileManager.default.removeItem(at: cur.tempURL)
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: cur.transferId,
                                                        errorMessage: "Incomplete file (timeout): \(cur.receivedBytes)/\(cur.fileSize)"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: cur.transferId)
                                                inboundFileTransferCompleteTimers[cur.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: cur.transferId)
                                            }
                                        }
                                    }
                                    break
                                }

                                do { try st.handle.close() } catch {}

                                // Move temp -> final
                                do {
                                    if let expectedMerkle = st.expectedMerkleRoot {
                                        let leaves: [Data] = (0..<st.totalChunks).compactMap { st.chunkHashes[$0] }
                                        if leaves.count != st.totalChunks || CrossNetworkMerkle.root(leaves: leaves) != expectedMerkle {
                                            await MainActor.run {
                                                FileTransferManager.shared.failExternalTransfer(
                                                    transferId: st.transferId,
                                                    errorMessage: "merkle root mismatch"
                                                )
                                            }
                                            inboundFileTransfers.removeValue(forKey: st.transferId)
                                            inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                            inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                            try? FileManager.default.removeItem(at: st.tempURL)
                                            let err = CrossNetworkFileTransferMessage(
                                                op: .error,
                                                transferId: st.transferId,
                                                message: "merkle root mismatch"
                                            )
                                            let outPlain = try JSONEncoder().encode(err)
                                            let outCipher = try encryptAppPayload(outPlain, with: keys)
                                            let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                            try await sendFramed(outPadded)
                                            break
                                        }

                                        if let sig = st.expectedMerkleSig {
                                            if st.expectedMerkleSigAlg != CrossNetworkMerkleAuth.signatureAlgV1 {
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: st.transferId,
                                                        errorMessage: "unknown merkle sig alg"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                try? FileManager.default.removeItem(at: st.tempURL)
                                                let err = CrossNetworkFileTransferMessage(
                                                    op: .error,
                                                    transferId: st.transferId,
                                                    message: "unknown merkle sig alg"
                                                )
                                                let outPlain = try JSONEncoder().encode(err)
                                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                try await sendFramed(outPadded)
                                                break
                                            }
                                            let pre = CrossNetworkMerkleAuth.preimage(
                                                transferId: st.transferId,
                                                merkleRoot: expectedMerkle,
                                                fileSha256: st.expectedFileSha256
                                            )
                                            let expectSig = CrossNetworkMerkleAuth.hmacSha256(key: keys.receiveKey, data: pre)
                                            if sig != expectSig {
                                                await MainActor.run {
                                                    FileTransferManager.shared.failExternalTransfer(
                                                        transferId: st.transferId,
                                                        errorMessage: "merkle signature mismatch"
                                                    )
                                                }
                                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                                try? FileManager.default.removeItem(at: st.tempURL)
                                                let err = CrossNetworkFileTransferMessage(
                                                    op: .error,
                                                    transferId: st.transferId,
                                                    message: "merkle signature mismatch"
                                                )
                                                let outPlain = try JSONEncoder().encode(err)
                                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                                try await sendFramed(outPadded)
                                                break
                                            }
                                        }
                                    }

                                    if let expected = st.expectedFileSha256, let actual = sha256File(at: st.tempURL), actual != expected {
                                        await MainActor.run {
                                            FileTransferManager.shared.failExternalTransfer(
                                                transferId: st.transferId,
                                                errorMessage: "file sha256 mismatch"
                                            )
                                        }
                                        inboundFileTransfers.removeValue(forKey: st.transferId)
                                        inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                        inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)
                                        try? FileManager.default.removeItem(at: st.tempURL)

                                        let err = CrossNetworkFileTransferMessage(
                                            op: .error,
                                            transferId: st.transferId,
                                            message: "file sha256 mismatch"
                                        )
                                        let outPlain = try JSONEncoder().encode(err)
                                        let outCipher = try encryptAppPayload(outPlain, with: keys)
                                        let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                        try await sendFramed(outPadded)
                                        break
                                    }
                                    if FileManager.default.fileExists(atPath: st.finalURL.path) {
                                        try? FileManager.default.removeItem(at: st.finalURL)
                                    }
                                    try FileManager.default.moveItem(at: st.tempURL, to: st.finalURL)
                                } catch {
                                    await MainActor.run {
                                        FileTransferManager.shared.failExternalTransfer(
                                            transferId: st.transferId,
                                            errorMessage: "Save failed: \(error.localizedDescription)"
                                        )
                                    }
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                    let err = CrossNetworkFileTransferMessage(
                                        op: .error,
                                        transferId: st.transferId,
                                        message: "Save failed"
                                    )
                                    let outPlain = try JSONEncoder().encode(err)
                                    let outCipher = try encryptAppPayload(outPlain, with: keys)
                                    let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-error")
                                    try await sendFramed(outPadded)
                                    break
                                }

                                await MainActor.run {
                                    FileTransferManager.shared.completeExternalInboundTransfer(
                                        transferId: st.transferId,
                                        savedTo: st.finalURL
                                    )
                                }
                                inboundFileTransfers.removeValue(forKey: st.transferId)
                                inboundFileTransferCompleteTimers[st.transferId]?.cancel()
                                inboundFileTransferCompleteTimers.removeValue(forKey: st.transferId)

                                let ack = CrossNetworkFileTransferMessage(op: .completeAck, transferId: st.transferId)
                                let outPlain = try JSONEncoder().encode(ack)
                                let outCipher = try encryptAppPayload(outPlain, with: keys)
                                let outPadded = TrafficPadding.wrapIfEnabled(outCipher, label: "tx/webrtc-ft-completeAck")
                                try await sendFramed(outPadded)

                            case .cancel:
                                if let st = inboundFileTransfers[ft.transferId] {
                                    try? st.handle.close()
                                    try? FileManager.default.removeItem(at: st.tempURL)
                                    await MainActor.run {
                                        FileTransferManager.shared.failExternalTransfer(
                                            transferId: st.transferId,
                                            errorMessage: ft.message ?? "Cancelled"
                                        )
                                    }
                                    inboundFileTransfers.removeValue(forKey: st.transferId)
                                }
                            case .error:
                                // Fail any pending macOS->iOS send waiters for this transfer.
                                self.failFileTransferWaiters(
                                    sessionID: sessionID,
                                    transferId: ft.transferId,
                                    message: ft.message ?? "unknown"
                                )
                            case .metadataAck, .chunkAck, .completeAck:
                                // Acks for macOS -> iOS sending.
                                self.resumeFileTransferWaiter(sessionID: sessionID, message: ft)
                            }
                            continue
                        } else if let rm = try? JSONDecoder().decode(RemoteMessageWire.self, from: plaintext) {
                            switch rm.type {
                            case .mouseEvent:
                                if let evt = try? JSONDecoder().decode(MouseEventWire.self, from: rm.payload) {
                                    handleMouseEvent(evt)
                                }
                            case .keyboardEvent:
                                if let evt = try? JSONDecoder().decode(KeyboardEventWire.self, from: rm.payload) {
                                    handleKeyboardEvent(evt)
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
                                    self.webrtcRemoteStreamConfigurationBySessionId[sessionID] = config
                                    self.webrtcRemoteVideoFormatsBySessionId[sessionID] = self.effectiveWebRTCRemoteVideoFormats(for: sessionID)
                                    if config.screenDataChannelEnabled == true {
                                        try? session.ensureScreenDataChannel()
                                    }
                                    self.logger.info(
                                        """
                                        🎛️ WebRTC 收到远控流策略: session=\(sessionID, privacy: .public) \
                                        preset=\(config.qualityPreset ?? "unknown", privacy: .public) \
                                        damage=\(config.damageTrackingEnabled ?? false, privacy: .public) \
                                        cursor=\(config.separateCursorChannelEnabled ?? false, privacy: .public) \
                                        overlay=\(config.interactionOverlayChannelEnabled ?? false, privacy: .public) \
                                        jitter=\(config.jitterBufferFrames ?? 0, privacy: .public) \
                                        recovery=\(config.lossRecoveryMode ?? "unknown", privacy: .public)
                                        """
                                    )
                                    if config.streamRefreshToken != previousConfig?.streamRefreshToken {
                                        self.webrtcPendingStreamRefreshSessionIds.insert(sessionID)
                                    }
                                    self.configureWebRTCClipboardSyncIfNeeded(for: sessionID, session: session)
                                }
                            case .damageReport, .cursorUpdate, .overlayUpdate:
                                break
                            case .screenData:
                                break
                            }
                            continue
                        } else {
                            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                                let previewData = plaintext.prefix(256)
                                let preview = String(data: previewData, encoding: .utf8)
                                    ?? previewData.map { String(format: "%02x", $0) }.joined()
                                print("🧪 mac app plaintext unknown preview=\(preview)")
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

                        let hasPQCGroup = messageA.supportedSuites.contains { $0.isPQCGroup }
                        let hasHybridGroup = messageA.supportedSuites.contains { $0.isHybrid }
                        let peerOnlyOffersHybrid = hasHybridGroup && messageA.supportedSuites.allSatisfy { $0.isHybrid }
                        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
                        let handshakePolicy: HandshakePolicy = {
                            if hasPQCGroup {
                                return HandshakePolicy.recommendedDefault(compatibilityModeEnabled: compatibilityModeEnabled)
                            }
                            // 首次跨网建链（尚未完成 KEM bootstrap）允许 classic 握手落地，避免 strictPQC 直接阻断通道建立。
                            return HandshakePolicy(
                                requirePQC: false,
                                allowClassicFallback: false,
                                minimumTier: .classic
                            )
                        }()
                        let sigAAlgorithm: ProtocolSigningAlgorithm = hasPQCGroup ? .mlDSA65 : .ed25519
                        let capability = CryptoProviderFactory.detectCapability()
                        let remotePrefersLiboqs = messageA.capabilities.providerType == .liboqs
                        let cryptoProvider: any CryptoProvider = {
                            if hasPQCGroup, remotePrefersLiboqs, capability.hasLiboqs {
                                return OQSPQCCryptoProvider()
                            }
                            let selection: CryptoProviderFactory.SelectionPolicy = {
                                if hasPQCGroup { return (handshakePolicy.requirePQC ? .requirePQC : .preferPQC) }
                                return .classicOnly
                            }()
                            return CryptoProviderFactory.make(policy: selection)
                        }()
                        let offeredSuites: [CryptoSuite] = hasPQCGroup
                        ? DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(using: cryptoProvider)
                        : cryptoProvider.supportedSuites.filter { !$0.isPQCGroup }
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

                        handshakeState.driver = try HandshakeDriver(
                            transport: transport,
                            cryptoProvider: cryptoProvider,
                            protocolSignatureProvider: ProtocolSignatureProviderSelector.select(for: sigAAlgorithm),
                            identityProvider: identityProvider,
                            sigAAlgorithm: sigAAlgorithm,
                            offeredSuites: offeredSuites,
                            policy: handshakePolicy,
                            cryptoPolicy: cryptoPolicy,
                            trustProvider: hasPQCGroup ? nil : currentPathTrustProvider
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
                await activeDriver.handleMessage(frame, from: peer)
                let st = await activeDriver.getCurrentState()
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 mac driver state=\(String(describing: st))")
                }
                switch st {
                case .waitingFinished(_, let keys, _):
                    handshakeState.sessionKeys = keys
                    if handshakeState.previousSessionKeysBeforeRekey != nil,
                       !(self.lastRekeyEvent?.contains("raw=") ?? false) {
                        self.lastRekeyEvent = "messageB negotiated=\(keys.negotiatedSuite.rawValue)"
                    }
                case .established(let keys):
                    handshakeState.sessionKeys = keys
                    handshakeState.driver = nil
                    handshakeState.previousSessionKeysBeforeRekey = nil
                    self.webrtcRekeyInProgressSessionIds.remove(sessionID)
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
                    startScreenStreamingIfNeeded(keys: keys)
                case .failed(let reason):
                    if let fallbackKeys = handshakeState.previousSessionKeysBeforeRekey {
                        logger.warning(
                            "⚠️ WebRTC rekey 失败，保留既有会话: session=\(sessionID, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
                        )
                        handshakeState.sessionKeys = fallbackKeys
                        handshakeState.previousSessionKeysBeforeRekey = nil
                        handshakeState.driver = nil
                        self.webrtcRekeyInProgressSessionIds.remove(sessionID)
                        self.lastRekeyEvent = "failed reason=\(String(describing: reason))"
                        self.webrtcSessionKeysBySessionId[sessionID] = fallbackKeys
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
            logger.debug("ℹ️ WebRTC 控制通道结束: \(error.localizedDescription, privacy: .public)")
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

        try await waitForConnection(connection)

        return RemoteConnection(
            id: code,
            deviceName: deviceInfo.deviceName,
            transport: .nw(connection)
        )
    }

    private func negotiateICE(sessionID: String, remotePublicKey: Data) async throws -> ICECandidate {
 // 1. 首先尝试获取本地地址（用于局域网直连）
        let localAddresses = getLocalIPAddresses()

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

 /// 获取本地 IP 地址列表
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ptr = current {
            let interface = ptr.pointee
            current = interface.ifa_next
            guard let addressPtr = interface.ifa_addr,
                  let name = decodeOptionalCString(interface.ifa_name) else { continue }
            let addrFamily = addressPtr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        addressPtr,
                        socklen_t(addressPtr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let address = String(decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !address.isEmpty && !address.hasPrefix("127.") {
                        addresses.append(address)
                    }
                }
            }
        }

        return addresses
    }

    private func waitForConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }

 // MARK: - 监听逻辑

    private func startListeningForConnection(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        logger.info("开始监听连接请求：\(sessionID)")

        let listener = ConnectionListener(sessionID: sessionID, privateKey: privateKey)
        activeListeners.append(listener)

        Task {
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

        Task {
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

        try await waitForConnection(connection)

        return RemoteConnection(
            id: offer.sessionID,
            deviceName: "Remote Device",
            transport: .nw(connection)
        )
    }

 // MARK: - 工具方法

    private static func generateDeviceFingerprint() -> String {
// 生成唯一设备指纹（基于硬件信息）
        let deviceInfo = "\(Host.current().localizedName ?? "")\(ProcessInfo.processInfo.hostName)"
        let hash = SHA256.hash(data: deviceInfo.utf8Data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).uppercased()
    }

    public static func sanitizeConnectionCodeInput(_ raw: String) -> String {
        String(
            raw
                .uppercased()
                .filter { shortCodeAllowedCharacters.contains($0) }
                .prefix(maximumConnectionCodeLength)
        )
    }

    public static func isSupportedConnectionCodeLength(_ count: Int) -> Bool {
        count == legacyConnectionCodeLength || (preferredConnectionCodeLength...maximumConnectionCodeLength).contains(count)
    }

    public static func canSubmitConnectionCode(_ raw: String) -> Bool {
        isSupportedConnectionCodeLength(sanitizeConnectionCodeInput(raw).count)
    }

    nonisolated static func canonicalPQCRekeyElectionDeviceId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.lowercased().hasPrefix("webrtc-") else { return nil }
        return trimmed.lowercased()
    }

    nonisolated static func shouldInitiatePQCRekey(localDeviceId: String?, remoteDeviceId: String?) -> Bool? {
        guard let local = canonicalPQCRekeyElectionDeviceId(localDeviceId),
              let remote = canonicalPQCRekeyElectionDeviceId(remoteDeviceId) else {
            return nil
        }
        guard local != remote else { return nil }
        return local.lexicographicallyPrecedes(remote)
    }

    private static func normalizeConnectionCode(_ raw: String) -> String? {
        let normalized = sanitizeConnectionCodeInput(raw)
        guard isSupportedConnectionCodeLength(normalized.count) else { return nil }
        return normalized
    }

    private static func extractConnectPayload(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "skybridge://connect/"
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }

        guard let url = URL(string: trimmed), url.scheme == "skybridge", url.host == "connect" else {
            return nil
        }
        let pathPayload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathPayload.isEmpty {
            return pathPayload
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryPayload = components.queryItems?.first(where: { $0.name == "data" })?.value,
           !queryPayload.isEmpty {
            return queryPayload
        }
        return nil
    }

    nonisolated fileprivate static func base64URLEncodedString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func decodeBase64Payload(_ raw: String) -> Data? {
        for candidate in strictBase64URLCandidates(from: raw) {
            if let data = Data(base64Encoded: candidate) {
                return data
            }
        }
        return nil
    }

    nonisolated private static func strictBase64URLCandidates(from raw: String) -> [String] {
        let rawCandidates = [raw, raw.removingPercentEncoding]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+/=")
        var normalizedCandidates: [String] = []
        var seen = Set<String>()

        for rawCandidate in rawCandidates {
            let compactScalars = rawCandidate.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            guard !compactScalars.isEmpty else { continue }
            guard compactScalars.allSatisfy({ allowedCharacters.contains($0) }) else { continue }

            let normalized = String(String.UnicodeScalarView(compactScalars))
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = normalized + String(repeating: "=", count: (4 - (normalized.count % 4)) % 4)
            if seen.insert(padded).inserted {
                normalizedCandidates.append(padded)
            }
        }

        return normalizedCandidates
    }

    private static func decodeDynamicQRCodePayload(from jsonData: Data) throws -> DynamicQRCodeData {
        try JSONDecoder().decode(DynamicQRCodeData.self, from: jsonData)
    }

    nonisolated static func buildCanonicalQRCodePayload(for qrData: DynamicQRCodeData) -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(UInt16(max(0, qrData.version)))
        encoder.encode(qrData.sessionID)
        encoder.encode(qrData.qrBootstrapToken)
        encoder.encode(Int64(qrData.expiresAt.timeIntervalSince1970 * 1000))
        encoder.encode(qrData.canonicalSignalingServerOrigin)
        encoder.encode(qrData.deviceID)
        encoder.encode(qrData.deviceName)
        encoder.encode(qrData.deviceType)
        encoder.encode(qrData.osVersion)
        encoder.encode(qrData.normalizedCapabilities) { enc, capability in
            enc.encode(capability)
        }
        encoder.encode(qrData.protocolSigningAlgorithm.rawValue)
        encoder.encode(qrData.protocolPublicKeyBytes)
        encoder.encode(qrData.protocolPublicKeyFingerprint)
        encoder.encode(qrData.signatureTimestampMs)
        return encoder.finalize()
    }

    static func verifyDynamicQRCode(_ qrData: DynamicQRCodeData) async -> (ok: Bool, reason: String?, source: QRCodeTrustSource) {
        guard qrData.version >= 6 else {
            return (false, "二维码协议版本过旧", .selfAsserted)
        }
        guard !qrData.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 sessionID", .selfAsserted)
        }
        guard !qrData.qrBootstrapToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 bootstrap token", .selfAsserted)
        }
        guard (try? ProtocolIdentityBinding.normalizedDeviceId(qrData.deviceID)) != nil else {
            return (false, "二维码 deviceId 格式无效", .selfAsserted)
        }
        guard (try? CurrentPathOriginPolicy.canonicalOrigin(qrData.signalingServerOrigin)) != nil else {
            return (false, "二维码 signaling origin 无效", .selfAsserted)
        }
        guard P2PDeviceType(rawValue: qrData.deviceType) != nil else {
            return (false, "二维码缺少 deviceType", .selfAsserted)
        }
        guard !qrData.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "二维码缺少 osVersion", .selfAsserted)
        }
        guard !qrData.normalizedCapabilities.isEmpty else {
            return (false, "二维码缺少能力列表", .selfAsserted)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let skewMs: Int64 = 120_000
        guard qrData.signatureTimestampMs <= nowMs + skewMs else {
            return (false, "二维码签名时间过于超前", .selfAsserted)
        }
        guard Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) >= nowMs - skewMs else {
            return (false, "二维码已过期", .selfAsserted)
        }
        guard qrData.signatureTimestampMs <= Int64(qrData.expiresAt.timeIntervalSince1970 * 1000) else {
            return (false, "二维码时间戳与过期时间矛盾", .selfAsserted)
        }
        guard let signature = qrData.signature else {
            return (false, "二维码缺少签名", .selfAsserted)
        }
        do {
            try ProtocolIdentityBinding.validateKeyEncoding(
                bytes: qrData.protocolPublicKeyBytes,
                algorithm: qrData.protocolSigningAlgorithm
            )
        } catch {
            return (false, "二维码长期协议公钥编码无效", .selfAsserted)
        }
        let computedFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: qrData.protocolSigningAlgorithm,
            publicKeyBytes: qrData.protocolPublicKeyBytes
        )
        guard computedFingerprint == qrData.protocolPublicKeyFingerprint else {
            return (false, "二维码长期协议公钥指纹不匹配", .selfAsserted)
        }

        do {
            let canonical = Self.buildCanonicalQRCodePayload(for: qrData)
            let provider = ProtocolSignatureProviderSelector.select(for: qrData.protocolSigningAlgorithm)
            guard try await Self.awaitVerifyQRCodeSignature(
                provider: provider,
                canonical: canonical,
                signature: signature,
                publicKey: qrData.protocolPublicKeyBytes
            ) else {
                return (false, "二维码签名验证失败", .selfAsserted)
            }
        } catch {
            return (false, "二维码签名格式无效：\(error.localizedDescription)", .selfAsserted)
        }

        if let conflict = TrustSyncService.shared.evaluateCurrentPathBinding(
            deviceId: qrData.deviceID,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint
        ) {
            switch conflict {
            case .identityConflict:
                return (false, "二维码 authoritative key 与现有 deviceId 绑定冲突", .selfAsserted)
            case .deviceIdMigrationRequired:
                return (false, "二维码 deviceId 与已 pinned authoritative key 不匹配", .selfAsserted)
            case .quarantinedIdentity:
                return (false, "二维码身份处于隔离/待重新验证状态", .selfAsserted)
            case .revokedIdentity:
                return (false, "二维码身份已撤销", .selfAsserted)
            }
        }

        if let trustRecord = TrustSyncService.shared.getCurrentPathTrustRecord(
            fingerprint: qrData.protocolPublicKeyFingerprint
        ),
           trustRecord.currentDeviceId == qrData.deviceID {
            return (true, nil, .trustedDevice)
        }
        return (true, nil, .selfAsserted)
    }

    nonisolated private static func awaitVerifyQRCodeSignature(
        provider: any ProtocolSignatureProvider,
        canonical: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
        try await provider.verify(canonical, signature: signature, publicKey: publicKey)
    }

    private static func deriveSharedSecret(localPrivateKey: Curve25519.KeyAgreement.PrivateKey, remotePublicKey: Data) throws -> SymmetricKey {
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }
}

// MARK: - 数据结构

/// 动态二维码数据结构
struct DynamicQRCodeData: Codable {
    let version: Int
    let sessionID: String
    let qrBootstrapToken: String
    let signalingServerOrigin: String
    let deviceID: String
    let deviceName: String
    let deviceType: String
    let osVersion: String
    let capabilities: [String]
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyBytes: Data
    let protocolPublicKeyFingerprint: String
    let signature: Data?
    let signatureTimestampMs: Int64
    let expiresAt: Date

    init(
        version: Int,
        sessionID: String,
        qrBootstrapToken: String,
        signalingServerOrigin: String,
        deviceID: String,
        deviceName: String,
        deviceType: String,
        osVersion: String,
        capabilities: [String],
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKeyBytes: Data,
        protocolPublicKeyFingerprint: String,
        signature: Data?,
        signatureTimestampMs: Int64,
        expiresAt: Date
    ) {
        self.version = version
        self.sessionID = sessionID
        self.qrBootstrapToken = qrBootstrapToken
        self.signalingServerOrigin = signalingServerOrigin
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.osVersion = osVersion
        self.capabilities = capabilities
        self.protocolSigningAlgorithm = protocolSigningAlgorithm
        self.protocolPublicKeyBytes = protocolPublicKeyBytes
        self.protocolPublicKeyFingerprint = protocolPublicKeyFingerprint.lowercased()
        self.signature = signature
        self.signatureTimestampMs = signatureTimestampMs
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let compact = try CompactDynamicQRCodeData(from: decoder)
        self = try compact.expanded()
    }

    func encode(to encoder: Encoder) throws {
        try CompactDynamicQRCodeData(from: self).encode(to: encoder)
    }

    var normalizedCapabilities: [String] {
        Array(Set(
            capabilities
                .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
        .sorted { lhs, rhs in
            Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
        }
    }

    var canonicalSignalingServerOrigin: String {
        (try? CurrentPathOriginPolicy.canonicalOrigin(signalingServerOrigin)) ?? signalingServerOrigin
    }

    func withSignature(_ signature: Data) -> DynamicQRCodeData {
        DynamicQRCodeData(
            version: version,
            sessionID: sessionID,
            qrBootstrapToken: qrBootstrapToken,
            signalingServerOrigin: canonicalSignalingServerOrigin,
            deviceID: deviceID,
            deviceName: deviceName.precomposedStringWithCanonicalMapping,
            deviceType: deviceType.precomposedStringWithCanonicalMapping,
            osVersion: osVersion.precomposedStringWithCanonicalMapping,
            capabilities: normalizedCapabilities,
            protocolSigningAlgorithm: protocolSigningAlgorithm,
            protocolPublicKeyBytes: protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprint,
            signature: signature,
            signatureTimestampMs: signatureTimestampMs,
            expiresAt: expiresAt
        )
    }
}

struct CompactDynamicQRCodeData: Codable {
    let v: Int
    let s: String
    let q: String
    let r: String
    let d: String
    let n: String
    let y: String
    let o: String
    let c: [String]
    let a: String
    let k: String
    let f: String
    let g: String?
    let t: Int64
    let e: Int64

    init(from qrData: DynamicQRCodeData) {
        self.v = qrData.version
        self.s = qrData.sessionID
        self.q = qrData.qrBootstrapToken
        self.r = qrData.canonicalSignalingServerOrigin
        self.d = qrData.deviceID
        self.n = qrData.deviceName.precomposedStringWithCanonicalMapping
        self.y = qrData.deviceType
        self.o = qrData.osVersion.precomposedStringWithCanonicalMapping
        self.c = qrData.normalizedCapabilities
        self.a = qrData.protocolSigningAlgorithm.rawValue
        self.k = CrossNetworkConnectionManager.base64URLEncodedString(from: qrData.protocolPublicKeyBytes)
        self.f = qrData.protocolPublicKeyFingerprint.lowercased()
        self.g = qrData.signature.map { CrossNetworkConnectionManager.base64URLEncodedString(from: $0) }
        self.t = qrData.signatureTimestampMs
        self.e = Int64(qrData.expiresAt.timeIntervalSince1970 * 1000)
    }

    func expanded() throws -> DynamicQRCodeData {
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: a) else {
            throw CurrentPathSecurityError.invalidBootstrap("unknown protocol signing algorithm")
        }
        guard let keyData = CrossNetworkConnectionManager.decodeBase64Payload(k) else {
            throw CurrentPathSecurityError.invalidBootstrap("invalid protocol public key encoding")
        }
        let signatureData: Data?
        if let g {
            guard let decodedSignature = CrossNetworkConnectionManager.decodeBase64Payload(g) else {
                throw CurrentPathSecurityError.invalidBootstrap("invalid signature encoding")
            }
            signatureData = decodedSignature
        } else {
            signatureData = nil
        }
        return DynamicQRCodeData(
            version: v,
            sessionID: s,
            qrBootstrapToken: q,
            signalingServerOrigin: r,
            deviceID: d,
            deviceName: n,
            deviceType: y,
            osVersion: o,
            capabilities: c,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyBytes: keyData,
            protocolPublicKeyFingerprint: f,
            signature: signatureData,
            signatureTimestampMs: t,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(e) / 1000.0)
        )
    }
}

enum QRCodeTrustSource {
    case selfAsserted
    case trustedDevice
}

private struct CurrentPathRemoteAuthority: Sendable, Equatable {
    let deviceId: String
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyFingerprint: String
    let protocolPublicKeyBytes: Data?
    let deviceName: String?
}

@available(macOS 14.0, iOS 17.0, *)
private struct CurrentPathHandshakeTrustProvider: HandshakeTrustProvider, Sendable {
    let expectedRemoteAuthority: CurrentPathRemoteAuthority?
    let fallbackPeerIDs: [String]

    private func candidateDeviceIds(for requestedDeviceId: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let rawValues: [String?] = [requestedDeviceId, expectedRemoteAuthority?.deviceId] + fallbackPeerIDs.map(Optional.some)
        for raw in rawValues {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }

    func trustedFingerprint(for deviceId: String) async -> String? {
        if let expectedRemoteAuthority,
           deviceId == expectedRemoteAuthority.deviceId || fallbackPeerIDs.contains(deviceId) {
            return expectedRemoteAuthority.protocolPublicKeyFingerprint
        }
        return nil
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let merged = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(
            forCandidates: candidateDeviceIds(for: deviceId)
        )
        return merged.reduce(into: [:]) { partialResult, item in
            partialResult[CryptoSuite(wireId: item.key)] = item.value
        }
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }
}


/// 设备信息（连接码查询结果）- 重命名以避免与FileTransfer中的DeviceInfo冲突
/// 符合 Swift 6.2.3 的 Sendable 要求
struct CrossNetworkDeviceInfo: Sendable {
    let deviceFingerprint: String
    let deviceName: String
    let publicKey: Data
}

/// ICE 候选
struct ICECandidate {
    let host: String
    let port: UInt16
    let type: CandidateType

    enum CandidateType {
        case host, srflx, relay
    }
}

/// 连接 Offer
struct ConnectionOffer: Codable {
    let sessionID: String
    let fromDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

/// 连接 Answer
struct ConnectionAnswer: Codable {
    let sessionID: String
    let toDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

/// 远程连接对象
///
/// 说明：跨网连接未来会统一承载 “握手/控制/文件/视频” 等通道。
/// 当前阶段先落地 WebRTC DataChannel 的可达性与信令闭环。
public struct RemoteConnection: @unchecked Sendable {
    public enum Transport: @unchecked Sendable {
        case webrtc(WebRTCSession)
        case nw(NWConnection)
    }

    public let id: String
    public let deviceName: String
    public let transport: Transport
}

/// 连接监听器 - 通过 NWListener 在本地端口接受入站 P2P 连接。
///
/// 说明：当前跨网连接主路径已迁移至 WebRTC DataChannel（不依赖端口监听），
/// 此监听器仅在局域网/直连回退场景下使用。
actor ConnectionListener {
    private let logger = Logger(subsystem: "com.skybridge.connection", category: "Listener")
    let sessionID: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var listener: NWListener?

    init(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.sessionID = sessionID
        self.privateKey = privateKey
    }

    func start(onConnection: @escaping @Sendable (RemoteConnection) async -> Void) async {
        do {
            let params = NWParameters.quic(alpn: ["skybridge-p2p"])
            let nwListener = try NWListener(using: params)
            self.listener = nwListener

            nwListener.newConnectionHandler = { [sessionID] conn in
                conn.start(queue: .global(qos: .userInitiated))
                let remote = RemoteConnection(id: sessionID, deviceName: "Remote Device", transport: .nw(conn))
                Task { await onConnection(remote) }
            }
            nwListener.start(queue: .global(qos: .userInitiated))
            logger.info("✅ ConnectionListener started for session=\(self.sessionID, privacy: .public)")
        } catch {
            logger.error("❌ ConnectionListener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// 跨网络连接错误
public enum CrossNetworkConnectionError: Error {
    case invalidQRCode
    case qrCodeExpired
    case invalidSignature
    case invalidDevice
    case missingSignalingToken
    case timeout
    case networkError
}
