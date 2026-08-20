import Foundation
import CryptoKit
import OSLog
import struct SkyBridgeProtocolCore.CrossNetworkFileTransferOperationReservationLedger
import class SkyBridgeProtocolCore.InboundFileTransferIOActor
import enum SkyBridgeProtocolCore.CrossNetworkFileTransferOp
import struct SkyBridgeProtocolCore.CrossNetworkFileTransferMessage
import enum SkyBridgeProtocolCore.P2PEvidenceReference
import enum SkyBridgeProtocolCore.CrossNetworkFileTransferWireDecoder
import enum SkyBridgeProtocolCore.DeviceTextMessagePolicy
import enum SkyBridgeProtocolCore.WebRTCFramedPayloadPolicy
import struct SkyBridgeProtocolCore.RemoteDesktopStreamConfigurationAcknowledgement
import SkyBridgeRealtimeMedia
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

@available(iOS 17.0, *)
enum CurrentPathJoinBootstrapError: LocalizedError, Sendable, Equatable {
    case missingIdentity
    case invalidIdentity
    case authorityMismatch
    case missingKEM
    case timedOut
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "strict-PQC WebRTC join is missing its protocol identity"
        case .invalidIdentity:
            return "WebRTC join protocol identity encoding or fingerprint is invalid"
        case .authorityMismatch:
            return "WebRTC join protocol identity does not match the admitted session authority"
        case .missingKEM:
            return "strict-PQC WebRTC join has no valid KEM public key"
        case .timedOut:
            return "timed out waiting for the remote WebRTC join authority"
        case .rollbackFailed:
            return "stale WebRTC join authority could not be rolled back safely"
        }
    }
}

@available(iOS 17.0, *)
private final class CurrentPathJoinBootstrapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func succeed() {
        finish(.success(()))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    func wait(timeoutSeconds: TimeInterval) async throws {
        precondition(timeoutSeconds.isFinite && timeoutSeconds > 0)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }
            self?.fail(CurrentPathJoinBootstrapError.timedOut)
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: { [weak self] in
            self?.fail(CancellationError())
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        precondition(self.continuation == nil, "join bootstrap gate supports one waiter")
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@available(iOS 17.0, *)
enum CrossNetworkCancelledTaskTeardownJoiner {
    enum QuarantineReason: Sendable, Equatable {
        case deadlineExceeded
        case joinCancelled
    }

    enum Outcome: Sendable, Equatable {
        case completed
        case quarantined(QuarantineReason)
    }

    /// Waits only for the bounded cancellation grace period. The manager has
    /// already detached the task or the authority it is cancelling from live
    /// session state before calling this; a task that does not quiesce remains
    /// quarantined behind the session-incarnation guards instead of retaining
    /// teardown authority forever.
    nonisolated static func joinCancelledTask(
        _ task: Task<Void, Never>,
        timeoutSeconds: TimeInterval
    ) async -> Outcome {
        precondition(
            timeoutSeconds.isFinite && timeoutSeconds >= 0,
            "Cancelled-task teardown timeout must be finite and non-negative"
        )
        let callbackOutcome: WebRTCSession.BoundedCallbackOutcome<Void> =
            await WebRTCSession.awaitBoundedStatsCallback(
                timeoutSeconds: timeoutSeconds
            ) { completion in
                Task {
                    await task.value
                    completion(())
                }
            }
        switch callbackOutcome {
        case .completed:
            return .completed
        case .timedOut:
            return .quarantined(.deadlineExceeded)
        case .cancelled:
            return .quarantined(.joinCancelled)
        }
    }
}

@available(iOS 17.0, *)
@MainActor
enum CrossNetworkTerminalNotificationDispatcher {
    /// Enqueues delivery without awaiting it. NotificationManager retains the
    /// transport/session dedupe authority; `didFinish` makes the delivery
    /// attempt observable without delaying lifecycle-gate release.
    @discardableResult
    static func enqueue(
        delivery: @escaping @MainActor @Sendable () async -> Void,
        didFinish: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await delivery()
            didFinish()
        }
    }
}

@available(iOS 17.0, *)
enum CrossNetworkTemporaryRegistrationRollback {
    static func removeOwnedValue<Key: Hashable, Value: Equatable>(
        from values: inout [Key: Value],
        key: Key,
        ownedValue: Value
    ) {
        guard values[key] == ownedValue else { return }
        values.removeValue(forKey: key)
    }
}

@available(iOS 17.0, *)
enum CrossNetworkExactOwnerDictionary {
    @discardableResult
    static func removeValue<Key: Hashable, Value, Owner: Equatable>(
        from values: inout [Key: Value],
        key: Key,
        expectedOwner: Owner,
        owner: (Value) -> Owner
    ) -> Value? {
        guard let current = values[key], owner(current) == expectedOwner else {
            return nil
        }
        return values.removeValue(forKey: key)
    }
}

@available(iOS 17.0, *)
@MainActor
enum CrossNetworkSignalingEnvelopeDrain {
    /// Drains only while the exact lifecycle owner remains current. Authority
    /// is checked both before and after every awaited envelope handler so an A
    /// drain cannot continue under a same-session-ID B incarnation.
    @discardableResult
    static func run<Envelope: Sendable, Owner: Equatable & Sendable>(
        _ envelopes: [Envelope],
        expectedOwner: Owner,
        expectedSessionID: String,
        envelopeSessionID: @MainActor (Envelope) -> String,
        currentOwner: @MainActor () -> Owner?,
        handle: @MainActor (Envelope, Owner) async -> Void
    ) async -> Int {
        var handledCount = 0
        for envelope in envelopes {
            guard envelopeSessionID(envelope) == expectedSessionID,
                  currentOwner() == expectedOwner else {
                return handledCount
            }
            await handle(envelope, expectedOwner)
            handledCount += 1
            guard currentOwner() == expectedOwner else {
                return handledCount
            }
        }
        return handledCount
    }
}

@available(iOS 17.0, *)
enum CrossNetworkConnectLinkGenerationError: LocalizedError, Equatable {
    case sessionStateCollision

    var errorDescription: String? {
        switch self {
        case .sessionStateCollision:
            return "信令服务返回的会话标识与现有本地会话状态冲突"
        }
    }
}

@available(iOS 17.0, *)
enum CurrentPathAuthorityCommitError: LocalizedError, Equatable {
    case missingAuthenticatedRemoteAuthority
    case missingStableExpectedDeviceIdentifier
    case unsupportedAuthenticatedAlgorithm(String)
    case invalidAuthenticatedFingerprint
    case missingAuthenticatedPublicKey
    case invalidAuthenticatedPublicKey
    case authenticatedPublicKeyFingerprintMismatch
    case durableCommitFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAuthenticatedRemoteAuthority:
            return "握手完成但没有认证的对端 authority"
        case .missingStableExpectedDeviceIdentifier:
            return "current-path authority 缺少稳定设备标识"
        case .unsupportedAuthenticatedAlgorithm(let algorithm):
            return "握手返回了不支持的协议签名算法：\(algorithm)"
        case .invalidAuthenticatedFingerprint:
            return "握手返回了无效的协议身份公钥指纹"
        case .missingAuthenticatedPublicKey:
            return "握手没有返回已认证的协议身份公钥字节"
        case .invalidAuthenticatedPublicKey:
            return "握手返回的协议身份公钥编码或长度无效"
        case .authenticatedPublicKeyFingerprintMismatch:
            return "握手返回的协议身份公钥与认证指纹不匹配"
        case .durableCommitFailed(let reason):
            return "认证 authority 无法持久化：\(reason)"
        }
    }
}

@available(iOS 17.0, *)
struct CurrentPathAuthenticatedAuthorityBinding: Sendable, Equatable {
    let stableDeviceId: String
    let deviceName: String
    let protocolSigningAlgorithm: String
    let protocolPublicKeyFingerprint: String
    let protocolPublicKeyBytes: Data
}

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

    enum InboundFileTransferFailureOrigin: Sendable, Equatable {
        case controlReceiveLoop
        case worker
    }

    func failInboundFileTransferControlChannel(
        _ message: String,
        owner: WebRTCFileTransferOperationOwner,
        origin: InboundFileTransferFailureOrigin
    ) async {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else { return }
        await terminateRemoteDesktopSession(
            sessionId: owner.sessionID,
            expectedSessionObjectIdentifier: owner.sessionObjectIdentifier,
            disconnectKind: .explicit,
            notificationKind: .interrupted,
            reason: "inbound_file_transfer_control_channel_failed",
            terminalFailureMessage: message,
            clearSnapshot: true,
            originatingReceiveLoop: origin == .controlReceiveLoop ? .control : nil
        )
    }

    @Published public private(set) var lastScreenData: ScreenData?
    @Published public private(set) var lastRekeyEvent: String?
    @Published public private(set) var remoteDeviceName: String?
    @Published public private(set) var remoteDeviceId: String?
#if canImport(WebRTC)
    @Published public private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published public private(set) var remoteVideoTrackIsAdmitted = false
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
    private var remoteVideoAdmissionOwner: RemoteDesktopSessionOwner?
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
    nonisolated private static let maxPendingPreSessionSignalingEnvelopes = 32
    nonisolated private static let protocolIdentityLogRedaction = "<redacted>"
    nonisolated private static let receiveLoopTeardownJoinTimeoutSeconds: TimeInterval = 2
    nonisolated private static let handshakeDriverTeardownJoinTimeoutSeconds: TimeInterval = 2
    nonisolated private static let signalingTeardownJoinTimeoutSeconds: TimeInterval = 2
    nonisolated private static let pairingIdentityNetworkSubmitTimeoutSeconds: TimeInterval = 8

    nonisolated private static func diagnosticErrorSummary(_ error: Error) -> String {
        let diagnosticError = error as NSError
        return "error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
    }

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
        expectedSessionObjectIdentifier: ObjectIdentifier,
        disconnectKind: SessionDisconnectKind,
        notificationKind: RemoteDesktopTerminalNotificationKind,
        reason: String,
        terminalFailureMessage: String? = nil,
        terminalFailureStateMessage: String? = nil,
        clearSnapshot: Bool = false,
        originatingReceiveLoop: ReceiveLoopTaskKind? = nil
    ) async {
        guard let expectedIncarnation = sessionIncarnation(
            sessionId: sessionId,
            sessionObjectIdentifier: expectedSessionObjectIdentifier
        ) else {
            return
        }
        await disconnectInternal(
            clearSnapshot: clearSnapshot,
            preservingConnectionCodeAttemptToken: nil,
            originatingReceiveLoop: originatingReceiveLoop,
            terminalFailureMessage: terminalFailureMessage,
            terminalFailureStateMessage: terminalFailureStateMessage,
            expectedIncarnation: expectedIncarnation,
            terminalNotification: DisconnectTerminalNotification(
                sessionId: sessionId,
                disconnectKind: disconnectKind,
                notificationKind: notificationKind,
                reason: reason
            )
        )
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
            "🎧 PQC media relay endpoint invalidated: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) reason=\(reason) failureCount=\(failureCount) backoffMs=\(Int((backoff * 1000).rounded()))"
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
            "🎧 PQC media relay endpoint cache cleared: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) reason=\(reason)"
        )
    }

    func requestRealtimeMediaRelayEndpointForActiveSession() async throws
        -> RealtimeMediaRelayEndpointPair? {
        guard let owner = currentRemoteDesktopSessionOwner() else { return nil }
        return try await requestRealtimeMediaRelayEndpoint(for: owner)
    }

    func requestRealtimeMediaRelayEndpoint(
        for owner: RemoteDesktopSessionOwner
    ) async throws -> RealtimeMediaRelayEndpointPair? {
        guard isCurrentRemoteDesktopSessionOwner(owner) else {
            throw CancellationError()
        }
        let sessionId = owner.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else {
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
                "ℹ️ media admission lease retry suppressed: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) reason=\(backoffReason)"
            )
            return nil
        }
        if let existingOwner = mediaAdmissionLeaseInFlightOwnerBySessionId[sessionId],
           existingOwner != owner {
            mediaAdmissionLeaseInFlightOwnerBySessionId.removeValue(forKey: sessionId)
        }
        guard mediaAdmissionLeaseInFlightOwnerBySessionId[sessionId] == nil else {
            recordMediaRelayLeaseFailure(sessionId: sessionId, token: nil, reason: "inFlight")
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
                if let cachedEndpoint = mediaAdmissionRelayEndpointBySessionId[sessionId],
                   Self.isUsableMediaRelayEndpoint(cachedEndpoint) {
                    return RealtimeMediaRelayEndpointPair(
                        localEndpoint: cachedEndpoint,
                        localRole: mediaAdmissionRelayRoleBySessionId[sessionId] ?? "unknown"
                    )
                }
                if mediaAdmissionLeaseInFlightOwnerBySessionId[sessionId] == nil {
                    break
                }
            }
            return nil
        }
        mediaAdmissionLeaseInFlightOwnerBySessionId[sessionId] = owner
        defer {
            if mediaAdmissionLeaseInFlightOwnerBySessionId[sessionId] == owner {
                mediaAdmissionLeaseInFlightOwnerBySessionId.removeValue(forKey: sessionId)
            }
        }

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
                token = try await refreshMediaAdmissionToken(
                    sessionId: sessionId,
                    staleToken: nil,
                    owner: owner
                )
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
                let reason = Self.mediaAdmissionRefreshFailureReason(for: error)
                if reason == "sessionTokenSuperseded" || reason == "sessionTokenExpired" {
                    do {
                        token = try await refreshWebRTCSessionAdmissionTokens(
                            sessionId: sessionId,
                            reason: reason,
                            owner: owner
                        )
                        guard isCurrentRemoteDesktopSessionOwner(owner) else {
                            throw CancellationError()
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard isCurrentRemoteDesktopSessionOwner(owner) else {
                            throw CancellationError()
                        }
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
                "ℹ️ media admission lease retry suppressed: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) reason=\(backoffReason)"
            )
            return nil
        }
        let lease: SignalServerClientCompat.MediaRelayLease
        do {
            let requestedLease = try await signalServer.requestMediaRelayLease(
                mediaAdmissionToken: token
            )
            guard isCurrentRemoteDesktopSessionOwner(owner) else {
                throw CancellationError()
            }
            lease = requestedLease
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrentRemoteDesktopSessionOwner(owner) else {
                throw CancellationError()
            }
            guard Self.isMediaAdmissionTokenRefreshable(error) else {
                let reason = Self.mediaRelayLeaseFailureReason(for: error)
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: reason, backoff: 5)
                return nil
            }
            let refreshedToken: String
            do {
                guard let refreshed = try await refreshMediaAdmissionToken(
                    sessionId: sessionId,
                    staleToken: token,
                    owner: owner
                ) else {
                    recordMediaRelayLeaseFailure(sessionId: sessionId, token: token, reason: "refreshFailed", backoff: 5)
                    return nil
                }
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
                refreshedToken = refreshed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
                let reason = Self.mediaAdmissionRefreshFailureReason(for: error)
                if reason == "sessionTokenSuperseded" || reason == "sessionTokenExpired" {
                    do {
                        guard let refreshed = try await refreshWebRTCSessionAdmissionTokens(
                            sessionId: sessionId,
                            reason: reason,
                            owner: owner
                        ) else {
                            recordMediaRelayLeaseFailure(
                                sessionId: sessionId,
                                token: token,
                                reason: "sessionReauthFailed",
                                backoff: 30
                            )
                            return nil
                        }
                        guard isCurrentRemoteDesktopSessionOwner(owner) else {
                            throw CancellationError()
                        }
                        refreshedToken = refreshed
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard isCurrentRemoteDesktopSessionOwner(owner) else {
                            throw CancellationError()
                        }
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
                "🎧 media admission token refreshed; retrying relay lease: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
            )
            do {
                let refreshedLease = try await signalServer.requestMediaRelayLease(
                    mediaAdmissionToken: refreshedToken
                )
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
                lease = refreshedLease
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
                let baseReason = Self.mediaRelayLeaseFailureReason(for: error)
                let reason = Self.mediaRelayLeaseFailureReasonAfterRefresh(for: error)
                if baseReason == "superseded" {
                    SkyBridgeLogger.shared.info(
                        "🎧 media admission refreshed token rejected by relay lease: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) reason=refreshLeaseSuperseded localRetryGeneration=\(Self.tokenGenerationPrefix(refreshedToken) ?? "-") \(Self.mediaTokenDiagnosticSummary(for: error) ?? "")"
                    )
                }
                recordMediaRelayLeaseFailure(sessionId: sessionId, token: refreshedToken, reason: reason, backoff: 5)
                return nil
            }
        }
        let leaseSessionId = lease.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard leaseSessionId == sessionId,
              isCurrentRemoteDesktopSessionOwner(owner) else {
            throw CancellationError()
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
            "🎧 PQC media relay lease ready: session_ref=\(SkyBridgeDiagnosticReference.stableReference(lease.sessionID)) role=\(lease.role) relay_ref=\(SkyBridgeDiagnosticReference.stableReference("\(lease.endpoint.host):\(lease.endpoint.port)")) token=\(lease.endpoint.relayToken == nil ? "missing" : "present") event=leaseReady"
        )
        return RealtimeMediaRelayEndpointPair(
            localEndpoint: lease.endpoint,
            localRole: lease.role
        )
    }

    private func refreshMediaAdmissionToken(
        sessionId: String,
        staleToken: String?,
        owner: RemoteDesktopSessionOwner
    ) async throws -> String? {
        guard isCurrentRemoteDesktopSessionOwner(owner), owner.sessionId == sessionId else {
            throw CancellationError()
        }
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
        guard isCurrentRemoteDesktopSessionOwner(owner) else {
            throw CancellationError()
        }
        let normalized = Self.normalizedNonEmptyToken(refreshed.token)
        if let normalized {
            webrtcMediaAdmissionTokenBySessionId[sessionId] = normalized
            SkyBridgeLogger.shared.info(
                "🎧 media admission token refresh accepted: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) role=\(roleName) localStaleGeneration=\(staleGeneration) localRefreshedGeneration=\(Self.tokenGenerationPrefix(normalized) ?? "-") serverGeneration=\(refreshed.mediaTokenGeneration ?? "-") serverBuild=\(refreshed.serverBuildFingerprint ?? "-")"
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
        reason: String,
        owner: RemoteDesktopSessionOwner
    ) async throws -> String? {
        guard isCurrentRemoteDesktopSessionOwner(owner), owner.sessionId == sessionId else {
            throw CancellationError()
        }
        guard let role = currentRole else {
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "missingRole"]
            )
        }
        let roleName = role == .offerer ? "initiator" : "responder"
        if let existingOwner = mediaAdmissionSessionRefreshInFlightOwnerBySessionId[sessionId],
           existingOwner != owner {
            mediaAdmissionSessionRefreshInFlightOwnerBySessionId.removeValue(forKey: sessionId)
        }
        guard mediaAdmissionSessionRefreshInFlightOwnerBySessionId[sessionId] == nil else {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                guard isCurrentRemoteDesktopSessionOwner(owner) else {
                    throw CancellationError()
                }
                if let token = Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId]) {
                    return token
                }
                if mediaAdmissionSessionRefreshInFlightOwnerBySessionId[sessionId] == nil {
                    break
                }
            }
            return Self.normalizedNonEmptyToken(webrtcMediaAdmissionTokenBySessionId[sessionId])
        }

        mediaAdmissionSessionRefreshInFlightOwnerBySessionId[sessionId] = owner
        defer {
            if mediaAdmissionSessionRefreshInFlightOwnerBySessionId[sessionId] == owner {
                mediaAdmissionSessionRefreshInFlightOwnerBySessionId.removeValue(forKey: sessionId)
            }
        }

        guard let authority = currentPathLocalAuthorityBySessionId[sessionId] else {
            throw SkyBridgeError.notInitialized
        }
        let admission = try await requestAdmissionLease(for: authority)
        guard isCurrentRemoteDesktopSessionOwner(owner) else {
            throw CancellationError()
        }
        let lease = try await signalServer.refreshWebRTCSession(
            admissionToken: admission.token,
            sessionId: sessionId,
            role: roleName
        )
        guard isCurrentRemoteDesktopSessionOwner(owner) else {
            throw CancellationError()
        }
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
            "🎧 WebRTC session tokens refreshed for media lease: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) role=\(roleName) reason=\(reason) serverBuild=\(lease.serverBuildFingerprint ?? "-") sessionTokenGeneration=\(lease.sessionTokenGeneration ?? "-") mediaTokenGeneration=\(lease.mediaTokenGeneration ?? "-")"
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
            "🎧 PQC media relay lease unavailable: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) reason=\(reason)\(backoffLabel)"
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
            "🎧 WebRTC session authority lost: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) event=sessionAuthorityLost reason=\(reason) localSessionGeneration=\(sessionGeneration) localMediaGeneration=\(mediaGeneration) action=fullRejoinRequired"
        )
        if currentSessionId == sessionId,
           let activeSession = session {
            let expectedSessionObjectIdentifier = ObjectIdentifier(activeSession)
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentSession(
                        sessionId: sessionId,
                        sessionObjectIdentifier: expectedSessionObjectIdentifier
                      ) else { return }
                await self.terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    expectedSessionObjectIdentifier: expectedSessionObjectIdentifier,
                    disconnectKind: .transient,
                    notificationKind: .interrupted,
                    reason: "session_authority_lost:\(reason)",
                    terminalFailureMessage: "WebRTC session authority lost; full rejoin required",
                    terminalFailureStateMessage: "sessionAuthorityLost"
                )
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
    private var signalingRecoveryTaskTokensBySessionId: [String: UUID] = [:]
    private var signalingGenerationBySessionId: [String: Int] = [:]
    private var activeSignalingHandleBySessionId: [String: WebSocketSignalingClient.SignalingHandleID] = [:]
    private var signalingHealth: SignalingHealth = .healthy
    private let lifecycleGate = CrossNetworkWebRTCLifecycleGate()
    private struct SessionSetupAttempt: Equatable, Sendable {
        let token: UUID
        let sessionId: String
        let lifecycleEpoch: UInt64
    }
    private struct SessionIncarnation: Equatable, Sendable {
        let sessionId: String
        let sessionObjectIdentifier: ObjectIdentifier
        let lifecycleEpoch: UInt64
    }
    struct RemoteDesktopSessionOwner: Equatable {
        fileprivate let sessionId: String
        fileprivate let sessionObjectIdentifier: ObjectIdentifier
        fileprivate let lifecycleEpoch: UInt64
    }
    struct WebRTCFileTransferOperationOwner {
        let remoteDesktopSessionOwner: RemoteDesktopSessionOwner
        let sessionID: String
        let session: WebRTCSession
        let sessionObjectIdentifier: ObjectIdentifier
        let fileTransferLifecycleToken: UUID
        let keys: SessionKeys

        init(
            sessionID: String,
            session: WebRTCSession,
            lifecycleEpoch: UInt64,
            fileTransferLifecycleToken: UUID,
            keys: SessionKeys
        ) {
            let sessionObjectIdentifier = ObjectIdentifier(session)
            self.remoteDesktopSessionOwner = RemoteDesktopSessionOwner(
                sessionId: sessionID,
                sessionObjectIdentifier: sessionObjectIdentifier,
                lifecycleEpoch: lifecycleEpoch
            )
            self.sessionID = sessionID
            self.session = session
            self.sessionObjectIdentifier = sessionObjectIdentifier
            self.fileTransferLifecycleToken = fileTransferLifecycleToken
            self.keys = keys
        }
    }
    private enum SessionLifecycleWitness: Equatable, Sendable {
        case setup(SessionSetupAttempt)
        case incarnation(SessionIncarnation)

        var sessionId: String {
            switch self {
            case .setup(let attempt):
                return attempt.sessionId
            case .incarnation(let incarnation):
                return incarnation.sessionId
            }
        }
    }
    private struct PendingPreSessionSignalingEnvelope: Sendable {
        let envelope: WebRTCSignalingEnvelope
        let lifecycleWitness: SessionLifecycleWitness
        let sourceSignaling: WebSocketSignalingClient
    }
    private enum PreSessionOperationKind: Equatable {
        case scannedConnect
        case connectionCodeConnect
        case connectionCodeGeneration
        case connectLinkGeneration
    }
    private struct PreSessionOperation: Equatable {
        let token: UUID
        let kind: PreSessionOperationKind
        let lifecycleEpoch: UInt64
    }
    private struct SessionBootstrapOperation: Equatable {
        let token: UUID
        let sessionId: String
    }
    private struct DisconnectTerminalFailure {
        let lastError: String
        let stateMessage: String
    }
    private struct DisconnectTerminalNotification {
        let sessionId: String
        let disconnectKind: SessionDisconnectKind
        let notificationKind: RemoteDesktopTerminalNotificationKind
        let reason: String
    }
    private struct DeferredTerminalNotification: Sendable {
        let sessionId: String
        let deviceName: String?
        let notificationKind: RemoteDesktopTerminalNotificationKind
        let reason: String
    }
    private struct TerminalNotificationContext: Sendable {
        let sessionId: String
        let deviceName: String?
    }
    private struct ConnectLinkRegistrationReceipt {
        let ownerToken: UUID
        let sessionId: String
        let sessionToken: String
        let turnAdmissionToken: String
        let mediaAdmissionToken: String?
        let signalingOrigin: String
        let signalingWebSocketPath: String
        let authorityDeviceId: String
        let authorityFingerprint: String
    }
    private var pendingDisconnectFailure: DisconnectTerminalFailure?
    private var pendingDisconnectClearSnapshot = false
    private var hasPendingDisconnectRequest = false
    private var pendingDisconnectPreservingConnectionCodeAttemptToken: UUID?
    private var pendingDisconnectPreservingSessionBootstrapToken: UUID?
    private var sessionLifecycleEpoch: UInt64 = 0
    private var activePreSessionOperation: PreSessionOperation?
    private var activeSessionSetupAttempt: SessionSetupAttempt?
    private var activeSessionIncarnation: SessionIncarnation?
    var session: WebRTCSession?
    private var currentSessionId: String?
#if canImport(WebRTC)
    private var remoteVideoHeartbeatRenderer: RemoteVideoTrackHeartbeatRenderer?
    private var pendingRemoteVideoTrackBeforeAdmission: RTCVideoTrack?
#endif
    private var localProtocolIdentitySnapshot: ProtocolIdentitySnapshot?
    private var currentPathLocalAuthorityBySessionId: [String: CurrentPathLocalAuthority] = [:]
    private var currentPathExpectedRemoteAuthorityBySessionId: [String: CurrentPathRemoteAuthorityCompat] = [:]
    private var authenticatedHandshakePeerBindingBySessionId: [String: AuthenticatedHandshakePeerBinding] = [:]
    private var currentPathJoinBootstrapGatesBySessionId: [String: CurrentPathJoinBootstrapGate] = [:]
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
    private enum ReceiveLoopTaskKind: Sendable {
        case control
        case screen
    }
    private var currentRole: WebRTCSession.Role?
    private var handshakeStartedSessionIds: Set<String> = []
    private var inboundInitialHandshakeResponderSessionIds: Set<String> = []
    private var inboundClassicAuthorityBootstrapSessionIds: Set<String> = []
    private var strictPQCClassicBootstrapOnlySessionIds: Set<String> = []
    private var strictPQCClassicBootstrapTimeoutTasksBySessionId: [String: Task<Void, Never>] = [:]
    private var rekeyInProgressSessionIds: Set<String> = []
    private var rekeyCompletedSessionIds: Set<String> = []
    private var productEvidenceOwnersBySessionId: [
        String: ProductEvidenceSessionOwner
    ] = [:]
    private var productEvidenceMediaTasksBySessionId: [
        String: Task<Void, Never>
    ] = [:]
    private var activeOutboundRekeyOperationToken: UUID?
    private var inboundRekeyResponderSessionIds: Set<String> = []
    private var strictPQCRequestedBySessionId: [String: Bool] = [:]
    private enum PairingIdentitySendOutcome: Sendable, Equatable {
        case contentProcessedCurrent
        case contentProcessedButSuperseded
    }
    private var lastPairingIdentityExchangeSentAtByPeerId: [
        String: PairingIdentityReplyObservation
    ] = [:]
    private var pairingMaterialAdmission: PairingMaterialAdmissionOwner?
    private var pairingMaterialAdmissionDeadline: PairingMaterialAdmissionDeadline?
    private var connectionCodeBootstrapTask: Task<Void, Never>?
    private var activeSessionBootstrapOperation: SessionBootstrapOperation?
    private var connectionCodeExpiryTask: Task<Void, Never>?
    private var resolvedSessionIdByConnectionCode: [String: String] = [:]
    private struct ConnectionCodeConnectOwner {
        let code: String
        let token: UUID
        let task: Task<Void, Never>
    }
    private var connectionCodeConnectOwner: ConnectionCodeConnectOwner?
    private var connectionCodeLifecycleEpoch: UInt64 = 0
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
    private var temporaryConnectLinkRegistrationOwnerBySessionId: [String: UUID] = [:]
    private var mediaAdmissionLeaseBackoffBySessionId: [String: (token: String?, until: Date, reason: String)] = [:]
    private var mediaAdmissionLeaseInFlightOwnerBySessionId: [String: RemoteDesktopSessionOwner] = [:]
    private var mediaAdmissionSessionRefreshInFlightOwnerBySessionId: [String: RemoteDesktopSessionOwner] = [:]
    private var mediaAdmissionLeaseFailureReasonBySessionId: [String: String] = [:]
    private var mediaAdmissionAuthorityLostSessionIds = Set<String>()
    private var mediaAdmissionRelayEndpointBySessionId: [String: SkyBridgeMediaEndpoint] = [:]
    private var mediaAdmissionRelayRoleBySessionId: [String: String] = [:]
    private var mediaAdmissionEndpointUnusableCountsBySessionReason: [String: Int] = [:]
    private var latestLocalOfferBySessionId: [String: String] = [:]
    private var latestLocalAnswerBySessionId: [String: String] = [:]
    private var localICECandidatesBySessionId: [String: [WebRTCSignalingEnvelope.Payload]] = [:]
    private var pendingPreSessionSignalingEnvelopesBySessionId: [
        String: [PendingPreSessionSignalingEnvelope]
    ] = [:]
    private var joinHeartbeatTask: Task<Void, Never>?
    private var offerResendTask: Task<Void, Never>?
    private var remoteDesktopHeartbeatTask: Task<Void, Never>?
    private var remotePeerPingTask: Task<Void, Never>?
    private var remotePeerLivenessWatchdogTask: Task<Void, Never>?
    private var remoteAppActivityAtBySessionId: [String: Date] = [:]
    private var suppressSignalingRecovery = false
    private var nextRemotePeerPingID: UInt64 = 1
    private var inFlightScannedConnectLink: String?

    // Typed waiter keys prevent delimiter injection from widening transfer-scoped
    // cancellation/error routing. The token still prevents stale timeout tasks
    // from removing a later waiter with the same exact key.
    typealias InboundFileTransferApprovalProvider = @MainActor (InboundFileTransferApprovalRequest) async -> InboundFileTransferApprovalDecision
    var inboundFileTransferApprovalProvider: InboundFileTransferApprovalProvider = { request in
        await InboundFileTransferApprovalService.shared.decide(for: request)
    }
    var fileTransferWaiters: [FileTransferWaiterKey: FileTransferWaiter] = [:]
    var webRTCSecureEnvelopeSendCounterBySessionId: [String: UInt64] = [:]
    var webRTCSecureEnvelopeReplayWindowBySessionId: [String: WebRTCAppSecureReplayWindow] = [:]
    var webRTCSecureEnvelopeKeyFingerprintBySessionId: [String: String] = [:]

    private var sessionSnapshotMetadataBySessionId: [String: SessionSnapshotMetadata] = [:]

    var inboundFileTransfers: [String: InboundFileTransferState] = [:]
    struct InboundFileTransferChunkOperationOwner: Sendable, Equatable {
        let token: UUID
        let stateToken: UUID
        let lifecycleToken: UUID
        let sessionID: String
    }
    var inboundFileTransferChunkOperationsInFlight: [
        String: InboundFileTransferChunkOperationOwner
    ] = [:]
    var queuedInboundFileTransferOperationsByTransferID: [String: [QueuedInboundFileTransferOperation]] = [:]
    var inboundFileTransferOperationReservationLedger =
        CrossNetworkFileTransferOperationReservationLedger()
    struct InboundFileTransferOperationWorker: Sendable {
        struct Owner: Sendable, Equatable {
            let token: UUID
            let lifecycleToken: UUID
        }
        let owner: Owner
        let task: Task<Void, Never>
    }
    var inboundFileTransferOperationWorkers: [String: InboundFileTransferOperationWorker] = [:]
    var acceptsQueuedInboundFileTransferOperations = true
    let inboundFileTransferIO = InboundFileTransferIOActor.shared
    var inboundFileTransferPendingAdmissions: [String: InboundFileTransferPendingAdmission] = [:]
    var inboundFileTransferLifecycleToken = UUID()
    var inboundFileTransferCompleteTimers: [String: Task<Void, Never>] = [:]
    var inboundFileTransferIdleTimers: [String: Task<Void, Never>] = [:]
    var inboundFileTransferTerminalReceipts = InboundFileTransferTerminalReceiptCache()

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
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
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
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    continue
                }
                guard self.sessionKeys != nil else {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    continue
                }
                if self.rekeyInProgressSessionIds.contains(sessionId) {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
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
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC ping send failed: \(Self.diagnosticErrorSummary(error))"
                    )
                    break
                }

                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func startRemotePeerLivenessWatchdog(sessionId: String, session: WebRTCSession) {
        let timeoutSeconds: TimeInterval = 12.0
        let sessionObjectIdentifier = ObjectIdentifier(session)
        if !isPairingMaterialAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), (pairingMaterialAdmissionDeadline?.sessionId != sessionId
            || pairingMaterialAdmissionDeadline?.sessionObjectIdentifier != sessionObjectIdentifier) {
            pairingMaterialAdmissionDeadline = PairingMaterialAdmissionDeadline(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier,
                expiresAt: Date().addingTimeInterval(timeoutSeconds)
            )
        }
        remotePeerLivenessWatchdogTask?.cancel()
        remotePeerLivenessWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.currentSessionId == sessionId,
                      self.session === session else { break }
                if !self.isPairingMaterialAdmitted(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) {
                    if PairingMaterialAdmissionPolicy.isAdmissionDeadlineExpired(
                        self.pairingMaterialAdmissionDeadline,
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier,
                        now: Date()
                    ) {
                        let message = "WebRTC 配对材料准入超时"
                        self.lastError = message
                        await self.terminateRemoteDesktopSession(
                            sessionId: sessionId,
                            expectedSessionObjectIdentifier: sessionObjectIdentifier,
                            disconnectKind: .explicit,
                            notificationKind: .interrupted,
                            reason: "pairing_material_admission_timeout",
                            terminalFailureMessage: message,
                            clearSnapshot: false
                        )
                        break
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    continue
                }

                // Pairing-material admission has its own short deadline above.
                // Once admitted, a strict-PQC Classic bootstrap is governed by
                // `strictPQCClassicBootstrapTimeoutTasksBySessionId`, whose
                // bounded grace period also accounts for an active rekey. The
                // normal app-activity watchdog must not terminate a legitimate
                // handshake simply because handshake frames do not count as app
                // traffic.
                if self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    continue
                }
                // An admitted session must still retain the exact authenticated
                // key material for this incarnation before normal liveness can
                // use its app-activity timestamp.
                guard self.sessionKeys?.sessionId == sessionId else {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        return
                    }
                    continue
                }

                let lastActivityAt = self.remoteAppActivityAtBySessionId[sessionId] ?? .distantPast
                if Date().timeIntervalSince(lastActivityAt) > timeoutSeconds {
                    let msg = "远端连接已失活"
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC remote peer timeout: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                    )
                    self.lastError = msg
                    await self.terminateRemoteDesktopSession(
                        sessionId: sessionId,
                        expectedSessionObjectIdentifier: ObjectIdentifier(session),
                        disconnectKind: .transient,
                        notificationKind: .interrupted,
                        reason: "remote_peer_timeout",
                        terminalFailureMessage: msg,
                        clearSnapshot: false
                    )
                    break
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
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
                do {
                    try await Task.sleep(for: .seconds(
                        CrossNetworkWebRTCHandshakeLimits.strictPQCClassicBootstrapTimeoutSeconds
                    ))
                } catch {
                    return
                }
                guard let self,
                      let session,
                      self.isCurrentSession(
                        sessionId: sessionId,
                        sessionObjectIdentifier: ObjectIdentifier(session)
                      ),
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
                        "⏳ WebRTC strictPQC classic bootstrap timeout extended while rekey/liveness is active: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), elapsed=\(Int(elapsed))s, active=\(hasFreshActivity), rekey=\(isRekeyActivelyProgressing)"
                    )
                    continue
                }

                self.strictPQCClassicBootstrapTimeoutTasksBySessionId.removeValue(forKey: sessionId)
                await self.failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: ObjectIdentifier(session),
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

    private func localProtocolIdentityPublicKeysForPairing(
        sessionId: String
    ) async throws
        -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        guard let activeIdentity = currentPathLocalAuthorityBySessionId[sessionId]?.identity else {
            throw SkyBridgeError.notInitialized
        }
        var keys = [
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: activeIdentity.algorithm.rawValue,
                publicKey: activeIdentity.publicKey
            )
        ]
        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .ed25519]
        where algorithm != activeIdentity.algorithm {
            do {
                let compatibilityIdentity = try await SkyBridgeiOSCore.shared
                    .committedProtocolIdentitySnapshot(
                        for: algorithm,
                        protection: .softwareKeychain
                    )
                keys.append(.init(
                    protocolSigningAlgorithm: compatibilityIdentity.algorithm.rawValue,
                    publicKey: compatibilityIdentity.publicKey
                ))
            } catch {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ WebRTC pairingIdentityExchange skipped protocol identity key alg=\(algorithm.rawValue): \(Self.diagnosticErrorSummary(error))"
                )
            }
        }
        let normalized = AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(keys) ?? []
        guard normalized.contains(where: {
            $0.normalizedAlgorithm == activeIdentity.algorithm
                && $0.publicKey == activeIdentity.publicKey
        }) else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Active protocol identity is missing from the WebRTC pairing advertisement"
            )
        }
        return normalized
    }

    /// Returns only exact raw-key identities that were authenticated and persisted before this
    /// handshake. This lets an already trusted ML-DSA-65 identity authorize a compatibility
    /// handshake during migration to ML-DSA-87 without treating a fresh signaling advertisement
    /// as an authenticated downgrade authority.
    private func durableCurrentPathProtocolFingerprints(
        for candidateDeviceIds: [String]
    ) -> Set<String> {
        let algorithms: [ProtocolSigningAlgorithm] = [.ed25519, .mlDSA65, .mlDSA87]
        var fingerprints = Set<String>()
        var seenDeviceIds = Set<String>()

        for rawDeviceId in candidateDeviceIds {
            let deviceId = rawDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deviceId.isEmpty, seenDeviceIds.insert(deviceId).inserted else { continue }

            for algorithm in algorithms {
                guard let binding = TrustedDeviceStore.shared.currentPathProtocolIdentityKeyBinding(
                    for: deviceId,
                    algorithm: algorithm
                ) else {
                    continue
                }
                guard binding.algorithm == algorithm.rawValue,
                      let publicKey = binding.publicKeyBytes,
                      (try? CurrentPathSecurityCompat.validateKeyEncoding(
                        bytes: publicKey,
                        algorithm: algorithm
                      )) != nil else {
                    continue
                }
                let fingerprint = binding.fingerprint
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let computedFingerprint = CurrentPathSecurityCompat.computeFingerprint(
                    algorithm: algorithm,
                    publicKeyBytes: publicKey
                ).lowercased()
                if !fingerprint.isEmpty, fingerprint == computedFingerprint {
                    fingerprints.insert(fingerprint)
                }
            }
        }
        return fingerprints
    }

    private func handshakeTrustedProtocolFingerprints(
        for sessionId: String,
        candidateDeviceIds: [String]
    ) -> Set<String> {
        var fingerprints = Set<String>()
        fingerprints.formUnion(
            durableCurrentPathProtocolFingerprints(for: candidateDeviceIds)
        )
        return fingerprints
    }

    private func localRouteAuthorityProtocolFingerprint(
        sessionId: String
    ) throws -> String {
        guard let fingerprint = currentPathLocalAuthorityBySessionId[sessionId]?
            .identity.authoritativeFingerprint,
              CrossNetworkWebRTCLocalAppMessageFactory
                .isCanonicalLowerHexFingerprint(fingerprint) else {
            throw SkyBridgeError.notInitialized
        }
        return fingerprint
    }

    private func sendLocalAuthenticatedRouteBindings(
        keys: SessionKeys,
        sessionId: String,
        session: WebRTCSession,
        stage: String
    ) async {
        guard currentSessionId == sessionId else { return }
        guard isApplicationTrafficAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: ObjectIdentifier(session)
        ) else {
            appendSmokeTrace(
                "authenticated-route-binding-send-skipped session=\(sessionId) stage=\(stage) reason=pairing_material_not_admitted"
            )
            return
        }
        guard !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId),
              !rekeyInProgressSessionIds.contains(sessionId) else {
            appendSmokeTrace("authenticated-route-binding-send-skipped session=\(sessionId) stage=\(stage) reason=session_not_business_ready")
            return
        }
        if strictPQCRequestedBySessionId[sessionId] == true,
           !keys.negotiatedSuite.isPQCGroup {
            appendSmokeTrace("authenticated-route-binding-send-skipped session=\(sessionId) stage=\(stage) reason=strict_pqc_rekey_pending")
            return
        }

        do {
            guard let remoteAuthority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] else {
                appendSmokeTrace("authenticated-route-binding-send-skipped session=\(sessionId) stage=\(stage) reason=missing_remote_authority")
                return
            }
            try await FileTransferRuntime.shared.ensureHealthy()
            let localFingerprint = try localRouteAuthorityProtocolFingerprint(
                sessionId: sessionId
            )
            let messages = try CrossNetworkWebRTCLocalAppMessageFactory.authenticatedFileTransferRouteBindingMessages(
                keys: keys,
                localDeviceId: try requiredLocalProtocolIdentity().deviceId,
                remoteAuthority: remoteAuthority,
                localRouteAuthorityProtocolPublicKeyFingerprint: localFingerprint
            )
            guard !messages.isEmpty else {
                appendSmokeTrace("authenticated-route-binding-send-skipped session=\(sessionId) stage=\(stage) reason=no_registered_product_routes")
                return
            }

            for message in messages {
                try await sendAppMessageOverWebRTC(
                    message,
                    sessionId: sessionId,
                    session: session,
                    label: "tx/webrtc-authenticated-route-binding"
                )
            }
            appendSmokeTrace("authenticated-route-binding-send session=\(sessionId) stage=\(stage) routes=\(messages.count)")
            SkyBridgeLogger.shared.info(
                "🔐 WebRTC authenticatedRouteBinding sent: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), stage=\(stage), routes=\(messages.count)"
            )
        } catch {
            appendSmokeTrace(
                "authenticated-route-binding-send-failed session=\(sessionId) stage=\(stage) error=\(CrossNetworkWebRTCTraceDescription.smokeTraceToken(error.localizedDescription))"
            )
            SkyBridgeLogger.shared.warning(
                "⚠️ WebRTC authenticatedRouteBinding send failed: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), stage=\(stage), \(Self.diagnosticErrorSummary(error))"
            )
        }
    }

    private func currentPathTrustedProtocolFingerprints(for sessionId: String) -> Set<String> {
        var fingerprints = Set<String>()
        if let expected = currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !expected.isEmpty {
            fingerprints.insert(expected)
        }
        return fingerprints
    }

    private func trustedCurrentPathKEMPublicKeys(
        for candidates: [String],
        sessionId: String
    ) async -> [CryptoSuite: Data] {
        let pinnedFingerprints = currentPathTrustedProtocolFingerprints(for: sessionId)
        guard !pinnedFingerprints.isEmpty else { return [:] }
        let signedRefresh = await KEMTrustStore.shared.signedRefreshKEMPublicKeys(
            forAny: candidates,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
        let joinBootstrap = await KEMTrustStore.shared.authorityBoundBootstrapKEMPublicKeys(
            forAny: candidates,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
        return joinBootstrap.merging(signedRefresh) { _, signed in signed }
    }

    private func currentPathLocalProtocolSigningAlgorithm(
        configuration: ProtocolIdentityConfigurationRecord
    ) -> ProtocolSigningAlgorithm {
        let compatibilityModeEnabled = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
        return CrossNetworkWebRTCPQCHandshakePolicy.shouldRequestStrictPQC(
            compatibilityModeEnabled: compatibilityModeEnabled
        ) ? configuration.algorithm : .ed25519
    }

    /// Returns the signed-QR ML-DSA-87 key for this session after checking its
    /// encoding and fingerprint again at the handshake boundary. Authorities
    /// without raw key bytes (for example connection codes) cannot authorize a
    /// first-use ML-DSA-87 handshake.
    private func sessionAuthenticatedMLDSA87PublicKey(for sessionId: String) throws -> Data? {
        guard let authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId],
              authority.protocolSigningAlgorithm == .mlDSA87,
              let publicKeyBytes = authority.protocolPublicKeyBytes else {
            return nil
        }
        do {
            try CurrentPathSecurityCompat.validateKeyEncoding(
                bytes: publicKeyBytes,
                algorithm: .mlDSA87
            )
        } catch {
            throw HandshakeError.failed(
                .identityMismatch(
                    expected: "valid signed-QR ML-DSA-87 authority",
                    actual: "invalid current-path ML-DSA-87 public key encoding"
                )
            )
        }
        let expectedFingerprint = authority.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let actualFingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: publicKeyBytes
        )
        guard expectedFingerprint == actualFingerprint else {
            throw HandshakeError.failed(
                .identityMismatch(
                    expected: "signed-QR ML-DSA-87 authority fingerprint",
                    actual: "current-path ML-DSA-87 public key fingerprint mismatch"
                )
            )
        }
        return publicKeyBytes
    }

    private struct CurrentPathLocalAuthority: Sendable {
        let identity: CommittedIOSProtocolIdentitySnapshot
        let binding: ProtocolIdentityBindingCompat
    }

    private func currentPathLocalAuthority() async throws -> CurrentPathLocalAuthority {
        _ = try await IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()
        let configuration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        let algorithm = currentPathLocalProtocolSigningAlgorithm(
            configuration: configuration
        )
        let protection = SkyBridgeiOSCore.protocolSigningKeyProtection(
            for: algorithm,
            requestedPQCAlgorithm: configuration.algorithm,
            requestedPQCProtection: configuration.keyProtection
        )
        let identity = try await SkyBridgeiOSCore.shared
            .committedProtocolIdentitySnapshot(
                for: algorithm,
                protection: protection
            )
        guard try ProtocolSigningIdentityPolicy.requiredConfiguration() == configuration else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Protocol identity configuration changed while the current-path binding was resolving"
            )
        }
        localProtocolIdentitySnapshot = identity.snapshot
        let binding = try ProtocolIdentityBindingCompat(
            deviceId: identity.deviceId,
            protocolSigningAlgorithm: identity.algorithm,
            protocolPublicKeyBytes: identity.publicKey
        )
        return CurrentPathLocalAuthority(identity: identity, binding: binding)
    }

    private func requiredLocalProtocolIdentity() throws -> ProtocolIdentitySnapshot {
        guard let localProtocolIdentitySnapshot else {
            throw SkyBridgeError.notInitialized
        }
        return localProtocolIdentitySnapshot
    }

    private func signCurrentPathPayload(
        _ payload: Data,
        authority: CurrentPathLocalAuthority
    ) async throws -> Data {
        let signatureProvider = ProtocolSignatureProviderSelector.select(
            for: authority.identity.algorithm
        )
        return try await signatureProvider.sign(
            payload,
            key: authority.identity.keyHandle
        )
    }

    private func sessionRequestedPQCAlgorithm(
        sessionId: String
    ) throws -> ProtocolSigningAlgorithm {
        guard let algorithm = currentPathLocalAuthorityBySessionId[sessionId]?
            .identity.algorithm,
              algorithm != .ed25519 else {
            throw SkyBridgeError.handshakeFailed(
                reason: "The admitted WebRTC session has no frozen PQC signing authority"
            )
        }
        return algorithm
    }

    private func sessionProtocolSigningKeyProtection(
        for algorithm: ProtocolSigningAlgorithm,
        sessionId: String
    ) throws -> ProtocolSigningKeyProtection {
        guard let localIdentity = currentPathLocalAuthorityBySessionId[sessionId]?
            .identity else {
            throw SkyBridgeError.notInitialized
        }
        return SkyBridgeiOSCore.protocolSigningKeyProtection(
            for: algorithm,
            requestedPQCAlgorithm: localIdentity.algorithm,
            requestedPQCProtection: localIdentity.protection
        )
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
                    "⚠️ 允许受限 current-path authority 重绑定: source=\(String(describing: rebindSource)) deviceId=\(Self.protocolIdentityLogRedaction) fingerprint=\(Self.protocolIdentityLogRedaction) conflict=\(String(describing: conflict))"
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

    private func persistCurrentPathTrust(
        sessionId: String,
        authenticatedRemoteAuthority: AuthenticatedRemoteAuthority?
    ) throws {
        guard let expectedAuthority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] else {
            return
        }
        guard let authenticatedRemoteAuthority else {
            throw CurrentPathAuthorityCommitError.missingAuthenticatedRemoteAuthority
        }
        let binding = try Self.authenticatedAuthorityBinding(
            expectedRemoteAuthority: expectedAuthority,
            authenticatedRemoteAuthority: authenticatedRemoteAuthority
        )
        guard let bindingAlgorithm = ProtocolSigningAlgorithm(
            rawValue: binding.protocolSigningAlgorithm
        ) else {
            throw CurrentPathAuthorityCommitError.unsupportedAuthenticatedAlgorithm(
                binding.protocolSigningAlgorithm
            )
        }
        do {
            try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
                deviceId: binding.stableDeviceId,
                name: binding.deviceName,
                protocolSigningAlgorithm: binding.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
                protocolPublicKeyBytes: binding.protocolPublicKeyBytes
            )
            currentPathExpectedRemoteAuthorityBySessionId[sessionId] =
                CurrentPathRemoteAuthorityCompat(
                    deviceId: binding.stableDeviceId,
                    protocolSigningAlgorithm: bindingAlgorithm,
                    protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint,
                    protocolPublicKeyBytes: binding.protocolPublicKeyBytes,
                    deviceName: binding.deviceName
                )
        } catch {
            throw CurrentPathAuthorityCommitError.durableCommitFailed(error.localizedDescription)
        }
    }

    nonisolated static func authenticatedAuthorityBinding(
        expectedRemoteAuthority: CurrentPathRemoteAuthorityCompat,
        authenticatedRemoteAuthority: AuthenticatedRemoteAuthority
    ) throws -> CurrentPathAuthenticatedAuthorityBinding {
        guard let stableDeviceId = PeerIdentityAliasResolver.persistentDeviceId(
            from: expectedRemoteAuthority.deviceId
        ) else {
            throw CurrentPathAuthorityCommitError.missingStableExpectedDeviceIdentifier
        }
        let algorithm = authenticatedRemoteAuthority.protocolSigningAlgorithm
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let protocolSigningAlgorithm = ProtocolSigningAlgorithm(rawValue: algorithm) else {
            throw CurrentPathAuthorityCommitError.unsupportedAuthenticatedAlgorithm(algorithm)
        }
        let fingerprint = authenticatedRemoteAuthority.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard fingerprint.count == 64, fingerprint.allSatisfy(\.isHexDigit) else {
            throw CurrentPathAuthorityCommitError.invalidAuthenticatedFingerprint
        }
        guard let publicKeyBytes = authenticatedRemoteAuthority.protocolPublicKeyBytes else {
            throw CurrentPathAuthorityCommitError.missingAuthenticatedPublicKey
        }
        do {
            try CurrentPathSecurityCompat.validateKeyEncoding(
                bytes: publicKeyBytes,
                algorithm: protocolSigningAlgorithm
            )
        } catch {
            throw CurrentPathAuthorityCommitError.invalidAuthenticatedPublicKey
        }
        guard CurrentPathSecurityCompat.computeFingerprint(
            algorithm: protocolSigningAlgorithm,
            publicKeyBytes: publicKeyBytes
        ) == fingerprint else {
            throw CurrentPathAuthorityCommitError.authenticatedPublicKeyFingerprintMismatch
        }
        let expectedName = expectedRemoteAuthority.deviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName: String
        if let expectedName, !expectedName.isEmpty {
            deviceName = expectedName
        } else {
            deviceName = stableDeviceId
        }
        return CurrentPathAuthenticatedAuthorityBinding(
            stableDeviceId: stableDeviceId,
            deviceName: deviceName,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: publicKeyBytes
        )
    }

    private func failCurrentPathAuthorityCommit(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        stage: String,
        error: Error,
        originatingReceiveLoop: ReceiveLoopTaskKind? = nil
    ) async {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else { return }
        let message = "WebRTC \(stage)认证 authority 提交失败：\(error.localizedDescription)"
        SkyBridgeLogger.shared.error(
            "⛔️ WebRTC authority durable commit 失败: session=\(Self.protocolIdentityLogRedaction), stage=\(stage)"
        )
        lastError = message
        await terminateRemoteDesktopSession(
            sessionId: sessionId,
            expectedSessionObjectIdentifier: sessionObjectIdentifier,
            disconnectKind: .explicit,
            notificationKind: .interrupted,
            reason: "authority_commit_failed:\(stage)",
            terminalFailureMessage: message,
            originatingReceiveLoop: originatingReceiveLoop
        )
    }

    func authenticatedInboundFileTransferSenderAuthority() -> (deviceId: String, deviceName: String)? {
        guard let sessionId = currentSessionId,
              sessionKeys?.sessionId == sessionId,
              let authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] else {
            return nil
        }
        let deviceId = authority.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty else { return nil }
        let deviceName = (authority.deviceName ?? remoteDeviceName ?? deviceId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (deviceId, deviceName.isEmpty ? deviceId : deviceName)
    }

    private func requestAdmissionLease(
        for authority: CurrentPathLocalAuthority
    ) async throws -> SignalServerClientCompat.AdmissionLease {
        let challenge = try await signalServer.requestAdmissionChallenge(
            binding: authority.binding
        )
        let signature = try await signCurrentPathPayload(
            challenge.signaturePayload(),
            authority: authority
        )
        return try await signalServer.completeAdmission(
            challenge: challenge,
            binding: authority.binding,
            signature: signature
        )
    }

    private func waitForLifecycleAvailability(operation: String) async -> Bool {
        do {
            try await lifecycleGate.waitForTeardownCompletion()
            return true
        } catch is CancellationError {
            return false
        } catch let error as CrossNetworkWebRTCLifecycleGate.WaitError {
            let message: String
            switch error {
            case .waiterCapacityExceeded(let limit):
                message = "WebRTC lifecycle request capacity exceeded (limit=\(limit))"
            }
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) operation=\(operation)"
            )
            lastError = message
            state = .failed(message)
            readiness = .idle
            return false
        } catch {
            let message = "WebRTC lifecycle gate returned an unexpected error"
            SkyBridgeLogger.shared.error(
                "⛔️ \(message) operation=\(operation)"
            )
            lastError = message
            state = .failed(message)
            readiness = .idle
            return false
        }
    }

    @discardableResult
    private func advanceSessionLifecycleEpoch() -> UInt64 {
        let increment = sessionLifecycleEpoch.addingReportingOverflow(1)
        precondition(!increment.overflow, "WebRTC session lifecycle epoch exhausted")
        sessionLifecycleEpoch = increment.partialValue
        return sessionLifecycleEpoch
    }

    private func beginSessionSetupAttempt(sessionId: String) -> SessionSetupAttempt {
        revokeRemoteDesktopNativeVideoAdmission()
        let attempt = SessionSetupAttempt(
            token: UUID(),
            sessionId: sessionId,
            lifecycleEpoch: advanceSessionLifecycleEpoch()
        )
        activeSessionSetupAttempt = attempt
        activeSessionIncarnation = nil
        pairingMaterialAdmission = nil
        pairingMaterialAdmissionDeadline = nil
#if canImport(WebRTC)
        pendingRemoteVideoTrackBeforeAdmission = nil
#endif
        return attempt
    }

    private func requireActiveSessionSetupAttempt(_ expected: SessionSetupAttempt) throws {
        guard activeSessionSetupAttempt == expected,
              sessionLifecycleEpoch == expected.lifecycleEpoch else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func requireSessionLifecycleEpoch(_ expected: UInt64) throws {
        guard sessionLifecycleEpoch == expected,
              !lifecycleGate.isTeardownInProgress else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func beginPreSessionOperation(
        kind: PreSessionOperationKind
    ) -> PreSessionOperation {
        if activePreSessionOperation?.kind == .connectionCodeConnect,
           let connectionCodeConnectOwner {
            connectionCodeLifecycleEpoch &+= 1
            connectionCodeConnectOwner.task.cancel()
            self.connectionCodeConnectOwner = nil
            resolvedSessionIdByConnectionCode.removeAll()
        }
        let operation = PreSessionOperation(
            token: UUID(),
            kind: kind,
            lifecycleEpoch: sessionLifecycleEpoch
        )
        activePreSessionOperation = operation
        return operation
    }

    private func requireActivePreSessionOperation(
        _ expected: PreSessionOperation
    ) throws {
        guard activePreSessionOperation == expected else {
            throw CancellationError()
        }
        try requireSessionLifecycleEpoch(expected.lifecycleEpoch)
    }

    private func isActivePreSessionOperation(
        _ expected: PreSessionOperation,
        allowingLifecycleAdvance: Bool = false
    ) -> Bool {
        guard activePreSessionOperation == expected else { return false }
        return allowingLifecycleAdvance || sessionLifecycleEpoch == expected.lifecycleEpoch
    }

    private func finishPreSessionOperation(_ expected: PreSessionOperation) {
        if activePreSessionOperation == expected {
            activePreSessionOperation = nil
        }
    }

    private func beginSessionBootstrapOperation(
        sessionId: String
    ) -> SessionBootstrapOperation {
        connectionCodeBootstrapTask?.cancel()
        connectionCodeBootstrapTask = nil
        let operation = SessionBootstrapOperation(
            token: UUID(),
            sessionId: sessionId
        )
        activeSessionBootstrapOperation = operation
        return operation
    }

    private func isActiveSessionBootstrapOperation(
        _ expected: SessionBootstrapOperation
    ) -> Bool {
        activeSessionBootstrapOperation == expected && !Task.isCancelled
    }

    private func finishSessionBootstrapOperation(
        _ expected: SessionBootstrapOperation
    ) {
        if activeSessionBootstrapOperation == expected {
            activeSessionBootstrapOperation = nil
            connectionCodeBootstrapTask = nil
        }
    }

    private func invalidateSessionBootstrapOperation() {
        activeSessionBootstrapOperation = nil
        connectionCodeBootstrapTask?.cancel()
        connectionCodeBootstrapTask = nil
    }

    private func installSessionIncarnation(
        sessionId: String,
        session: WebRTCSession,
        setupAttempt: SessionSetupAttempt
    ) throws {
        try requireActiveSessionSetupAttempt(setupAttempt)
        revokeRemoteDesktopNativeVideoAdmission()
        pairingMaterialAdmission = nil
        pairingMaterialAdmissionDeadline = nil
#if canImport(WebRTC)
        pendingRemoteVideoTrackBeforeAdmission = nil
#endif
        activeSessionIncarnation = SessionIncarnation(
            sessionId: sessionId,
            sessionObjectIdentifier: ObjectIdentifier(session),
            lifecycleEpoch: setupAttempt.lifecycleEpoch
        )
    }

    private func sessionIncarnation(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> SessionIncarnation? {
        guard let incarnation = activeSessionIncarnation,
              incarnation.sessionId == sessionId,
              incarnation.sessionObjectIdentifier == sessionObjectIdentifier,
              incarnation.lifecycleEpoch == sessionLifecycleEpoch else {
            return nil
        }
        return incarnation
    }

    private func isCurrentSessionIncarnation(_ expected: SessionIncarnation) -> Bool {
        activeSessionIncarnation == expected
            && expected.lifecycleEpoch == sessionLifecycleEpoch
            && currentSessionId == expected.sessionId
            && session.map(ObjectIdentifier.init) == expected.sessionObjectIdentifier
    }

    func currentRemoteDesktopSessionOwner() -> RemoteDesktopSessionOwner? {
        guard let incarnation = activeSessionIncarnation,
              isCurrentSessionIncarnation(incarnation),
              activeSessionSnapshot?.sessionId == incarnation.sessionId else {
            return nil
        }
        return RemoteDesktopSessionOwner(
            sessionId: incarnation.sessionId,
            sessionObjectIdentifier: incarnation.sessionObjectIdentifier,
            lifecycleEpoch: incarnation.lifecycleEpoch
        )
    }

    func isCurrentRemoteDesktopSessionOwner(_ owner: RemoteDesktopSessionOwner) -> Bool {
        isCurrentSessionIncarnation(
            SessionIncarnation(
                sessionId: owner.sessionId,
                sessionObjectIdentifier: owner.sessionObjectIdentifier,
                lifecycleEpoch: owner.lifecycleEpoch
            )
        )
    }

    func isCurrentRemoteDesktopSessionOwner(
        _ owner: RemoteDesktopSessionOwner,
        expectedSessionID: String
    ) -> Bool {
        owner.sessionId == expectedSessionID
            && isCurrentRemoteDesktopSessionOwner(owner)
    }

    @discardableResult
    func setRemoteDesktopNativeAudioAdmission(
        _ admitted: Bool,
        owner: RemoteDesktopSessionOwner
    ) -> Bool {
        guard isCurrentRemoteDesktopSessionOwner(owner),
              let session,
              ObjectIdentifier(session) == owner.sessionObjectIdentifier,
              currentSessionId == owner.sessionId else {
            return false
        }
        session.setRemoteAudioAdmissionEnabled(admitted)
        return isCurrentRemoteDesktopSessionOwner(owner)
    }

    @discardableResult
    func setRemoteDesktopNativeVideoAdmission(
        _ admitted: Bool,
        owner: RemoteDesktopSessionOwner
    ) -> Bool {
        guard isCurrentRemoteDesktopSessionOwner(owner),
              let session,
              ObjectIdentifier(session) == owner.sessionObjectIdentifier,
              currentSessionId == owner.sessionId else {
            return false
        }
        if admitted {
            remoteVideoAdmissionOwner = owner
        } else {
            revokeRemoteDesktopNativeVideoAdmission()
        }
        session.setRemoteVideoAdmissionEnabled(admitted)
#if canImport(WebRTC)
        remoteVideoTrackIsAdmitted = admitted
        remoteVideoTrack?.isEnabled = admitted
#endif
        return isCurrentRemoteDesktopSessionOwner(owner)
    }

#if canImport(WebRTC)
    func canRenderAdmittedRemoteVideoTrack(
        trackID: String,
        renderEpoch: UInt64
    ) -> Bool {
        guard let remoteVideoAdmissionOwner,
              isCurrentRemoteDesktopSessionOwner(remoteVideoAdmissionOwner) else {
            return false
        }
        return CrossNetworkWebRTCNativeVideoPolicy.allowsTrackRender(
            isAdmitted: remoteVideoTrackIsAdmitted,
            currentTrackID: remoteVideoTrack?.trackId,
            renderedTrackID: trackID,
            currentRenderEpoch: remoteVideoTrackRenderEpoch,
            renderedEpoch: renderEpoch
        )
    }
#endif

    private func revokeRemoteDesktopNativeVideoAdmission() {
        remoteVideoAdmissionOwner = nil
#if canImport(WebRTC)
        remoteVideoTrackIsAdmitted = false
        remoteVideoTrack?.isEnabled = false
        remoteVideoTrackRenderEpoch &+= 1
        remoteVideoTrackReadyForPromotion = false
        remoteVideoTrackHasRenderedFrame = false
        remoteVideoTrackHasReceiverFrameEvidence = false
        remoteVideoTrackHasReceivedFirstPacket = false
        nativeRenderEvidenceSource = nil
        nativeRenderUISurface = nil
        nativePromotionState = remoteVideoTrack == nil ? "idle" : "admission-pending"
        nativeVideoProbeTask?.cancel()
        nativeVideoProbeTask = nil
        nativeVideoProbeActive = false
        remoteVideoTrackConfirmationTask?.cancel()
        remoteVideoTrackConfirmationTask = nil
#endif
    }

    static func isSameWebRTCFileTransferSecureSession(
        _ lhs: SessionKeys,
        _ rhs: SessionKeys
    ) -> Bool {
        lhs.sessionId == rhs.sessionId
            && lhs.negotiatedSuite.rawValue == rhs.negotiatedSuite.rawValue
            && lhs.role.rawValue == rhs.role.rawValue
            && lhs.transcriptHash == rhs.transcriptHash
            && lhs.sendKey == rhs.sendKey
            && lhs.receiveKey == rhs.receiveKey
    }

    private func publishWebRTCProductEvidenceIfCurrent(
        sessionId: String,
        session: WebRTCSession,
        keys: SessionKeys,
        driver: HandshakeDriver,
        attemptSnapshot: ProductConnectivityHandshakeAttemptSnapshot
    ) async {
        let sessionObjectIdentifier = ObjectIdentifier(session)
        guard keys.negotiatedSuite == .xwing,
              isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
              ),
              handshakeDriver === driver,
              let currentKeys = sessionKeys,
              Self.isSameWebRTCFileTransferSecureSession(currentKeys, keys),
              let sessionReference = P2PEvidenceReference.sessionIncarnation(
                sessionID: keys.sessionId,
                transcriptHash: keys.transcriptHash
              ) else {
            return
        }
        let selectedPath = await session.currentICETransportPath()
        guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
              ),
              handshakeDriver === driver,
              let postPathKeys = sessionKeys,
              Self.isSameWebRTCFileTransferSecureSession(postPathKeys, keys) else {
            return
        }
        let selectedTransport: ProductEvidenceSelectedTransport
        switch selectedPath {
        case .direct:
            selectedTransport = .direct
        case .relay:
            selectedTransport = .relay
        case .unknown:
            return
        }

        let committedIdentity = try? await SkyBridgeiOSCore.shared
            .committedActiveProtocolIdentitySnapshot()
        guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
              ),
              handshakeDriver === driver,
              let postIdentityKeys = sessionKeys,
              Self.isSameWebRTCFileTransferSecureSession(postIdentityKeys, keys),
              let localAuthority = currentPathLocalAuthorityBySessionId[sessionId],
              let committedIdentity,
              committedIdentity.algorithm
                == attemptSnapshot.localProtocolSigningAlgorithm,
              committedIdentity.protection
                == attemptSnapshot.localProtocolSigningKeyProtection,
              committedIdentity.publicKey
                == attemptSnapshot.localProtocolPublicKey,
              localAuthority.identity.algorithm == committedIdentity.algorithm,
              localAuthority.identity.protection == committedIdentity.protection,
              localAuthority.identity.publicKey == committedIdentity.publicKey,
              let identityDescriptor = committedIdentity.productEvidenceDescriptor else {
            return
        }

        if let existing = productEvidenceOwnersBySessionId[sessionId] {
            guard existing.sessionReference != sessionReference else { return }
            productEvidenceMediaTasksBySessionId.removeValue(
                forKey: sessionId
            )?.cancel()
            productEvidenceOwnersBySessionId.removeValue(forKey: sessionId)
            _ = ProductReleaseEvidenceRecorder.shared.endSession(
                owner: existing,
                reason: .sessionReplaced
            )
        }
        guard let owner = ProductReleaseEvidenceRecorder.shared.beginSession(
            transport: .webrtc,
            sessionReference: sessionReference,
            selectedTransport: selectedTransport
        ), ProductReleaseEvidenceRecorder.shared
            .recordWebRTCPQCRekeyAuthenticated(owner: owner, suite: .xwing) else {
            return
        }
        productEvidenceOwnersBySessionId[sessionId] = owner
        _ = ProductReleaseEvidenceRecorder.shared
            .recordProductionIdentityHandshakeBound(
                descriptor: identityDescriptor,
                sessionOwner: owner
            )
        beginWebRTCProductEvidenceMediaSampling(
            sessionId: sessionId,
            session: session,
            keys: keys,
            owner: owner
        )
    }

    private func beginWebRTCProductEvidenceMediaSampling(
        sessionId: String,
        session: WebRTCSession,
        keys: SessionKeys,
        owner: ProductEvidenceSessionOwner
    ) {
        productEvidenceMediaTasksBySessionId.removeValue(
            forKey: sessionId
        )?.cancel()
        productEvidenceMediaTasksBySessionId[sessionId] = Task {
            [weak self, weak session] in
            guard let self, let session else { return }
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(115)
            var firstSampleAt: ContinuousClock.Instant?
            var sequence = 1
            while !Task.isCancelled, clock.now < deadline, sequence <= 2 {
                guard self.isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: ObjectIdentifier(session)
                ), let currentKeys = self.sessionKeys,
                   Self.isSameWebRTCFileTransferSecureSession(
                    currentKeys,
                    keys
                   ), self.productEvidenceOwnersBySessionId[sessionId] == owner else {
                    return
                }
                let stats = await session.incomingMediaRTCStats()
                guard !Task.isCancelled else { return }
                let now = clock.now
                let baseline = firstSampleAt ?? now
                let duration = baseline.duration(to: now).components
                let elapsedMilliseconds = UInt64(max(0, duration.seconds))
                    * 1_000
                    + UInt64(max(0, duration.attoseconds)
                        / 1_000_000_000_000_000)
                if let sample = ProductEvidenceMediaSample(
                    role: .receiver,
                    sequence: sequence,
                    elapsedMilliseconds: elapsedMilliseconds,
                    videoFrames: stats.videoFrames,
                    videoBytes: stats.videoBytes,
                    audioUnits: stats.audioPackets,
                    audioBytes: stats.audioBytes
                ), ProductReleaseEvidenceRecorder.shared.recordWebRTCMediaSample(
                    owner: owner,
                    sample: sample
                ) {
                    if firstSampleAt == nil { firstSampleAt = now }
                    sequence += 1
                    if sequence == 2 {
                        do {
                            try await Task.sleep(for: .seconds(31))
                        } catch {
                            return
                        }
                        continue
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    func currentWebRTCFileTransferOperationOwner()
        -> WebRTCFileTransferOperationOwner? {
        guard let session, let keys = sessionKeys else {
            return nil
        }
        return currentWebRTCFileTransferOperationOwner(
            sessionID: keys.sessionId,
            session: session,
            keys: keys
        )
    }

    func currentWebRTCFileTransferOperationOwner(
        sessionID: String,
        session: WebRTCSession,
        keys: SessionKeys
    ) -> WebRTCFileTransferOperationOwner? {
        guard let incarnation = activeSessionIncarnation,
              isCurrentSessionIncarnation(incarnation),
              incarnation.sessionId == sessionID,
              self.session === session,
              ObjectIdentifier(session) == incarnation.sessionObjectIdentifier,
              let currentKeys = sessionKeys,
              Self.isSameWebRTCFileTransferSecureSession(currentKeys, keys) else {
            return nil
        }
        return WebRTCFileTransferOperationOwner(
            sessionID: incarnation.sessionId,
            session: session,
            lifecycleEpoch: incarnation.lifecycleEpoch,
            fileTransferLifecycleToken: inboundFileTransferLifecycleToken,
            keys: currentKeys
        )
    }

    func isCurrentWebRTCFileTransferOperationOwner(
        _ owner: WebRTCFileTransferOperationOwner
    ) -> Bool {
        guard isCurrentRemoteDesktopSessionOwner(owner.remoteDesktopSessionOwner),
              session === owner.session,
              ObjectIdentifier(owner.session) == owner.sessionObjectIdentifier,
              inboundFileTransferLifecycleToken == owner.fileTransferLifecycleToken,
              let currentKeys = sessionKeys else {
            return false
        }
        return Self.isSameWebRTCFileTransferSecureSession(currentKeys, owner.keys)
    }

    func requireCurrentWebRTCFileTransferOperationOwner(
        _ owner: WebRTCFileTransferOperationOwner
    ) throws {
        guard isCurrentWebRTCFileTransferOperationOwner(owner) else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    static func isSameWebRTCFileTransferOperationOwner(
        _ lhs: WebRTCFileTransferOperationOwner,
        _ rhs: WebRTCFileTransferOperationOwner
    ) -> Bool {
        lhs.remoteDesktopSessionOwner == rhs.remoteDesktopSessionOwner
            && lhs.sessionID == rhs.sessionID
            && lhs.session === rhs.session
            && lhs.sessionObjectIdentifier == rhs.sessionObjectIdentifier
            && lhs.fileTransferLifecycleToken == rhs.fileTransferLifecycleToken
            && isSameWebRTCFileTransferSecureSession(lhs.keys, rhs.keys)
    }

    func notifyRemoteDesktopInterruptedIfCurrent(
        _ owner: RemoteDesktopSessionOwner,
        reason: String
    ) async -> Bool {
        guard isCurrentRemoteDesktopSessionOwner(owner) else { return false }
        await notifyRemoteDesktopTerminalSessionIfNeeded(
            sessionId: owner.sessionId,
            kind: .interrupted,
            reason: reason
        )
        return isCurrentRemoteDesktopSessionOwner(owner)
    }

    func disconnectRemoteDesktopSessionIfCurrent(
        _ owner: RemoteDesktopSessionOwner,
        clearSnapshot: Bool
    ) async {
        let incarnation = SessionIncarnation(
            sessionId: owner.sessionId,
            sessionObjectIdentifier: owner.sessionObjectIdentifier,
            lifecycleEpoch: owner.lifecycleEpoch
        )
        guard isCurrentSessionIncarnation(incarnation) else { return }
        await disconnectInternal(
            clearSnapshot: clearSnapshot,
            preservingConnectionCodeAttemptToken: nil,
            expectedIncarnation: incarnation
        )
    }

    private func isPairingMaterialAdmitted(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            return false
        }
        return PairingMaterialAdmissionPolicy.isCurrentAdmission(
            pairingMaterialAdmission,
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        )
    }

    private func isApplicationTrafficAdmitted(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard isPairingMaterialAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), let keys = sessionKeys,
           keys.sessionId == sessionId,
           !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId),
           !rekeyInProgressSessionIds.contains(sessionId) else {
            return false
        }
        return strictPQCRequestedBySessionId[sessionId] != true
            || keys.negotiatedSuite.isPQCGroup
    }

    @discardableResult
    private func installPairingMaterialAdmissionIfCurrent(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        acceptedMaterialDigest: Data
    ) -> Bool {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), sessionKeys?.sessionId == sessionId else {
            return false
        }
        pairingMaterialAdmission = PairingMaterialAdmissionOwner(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier,
            acceptedMaterialDigest: acceptedMaterialDigest
        )
        pairingMaterialAdmissionDeadline = nil
        return true
    }

    @discardableResult
    private func publishApplicationReadyIfCurrent(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        keys: SessionKeys,
        session: WebRTCSession
    ) -> Bool {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), ObjectIdentifier(session) == sessionObjectIdentifier,
           sessionKeys?.sessionId == sessionId,
           keys.sessionId == sessionId,
           isApplicationTrafficAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
           ) else {
            return false
        }

        let wasAlreadyPublished: Bool
        if case .handshakeComplete(let activeSessionId, let activeSuite) = readiness {
            wasAlreadyPublished = activeSessionId == sessionId
                && activeSuite == keys.negotiatedSuite.rawValue
        } else {
            wasAlreadyPublished = false
        }

        state = .connected(sessionId: sessionId)
        readiness = .handshakeComplete(
            sessionId: sessionId,
            negotiatedSuite: keys.negotiatedSuite.rawValue
        )
        noteRemoteAppActivity(sessionId: sessionId)
        startRemotePeerPingLoop(sessionId: sessionId, session: session)
        startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)
        updatePreparedSessionSnapshot(
            sessionId: sessionId,
            phase: .handshakeComplete,
            deviceId: remoteDeviceId,
            deviceName: remoteDeviceName,
            negotiatedSuite: keys.negotiatedSuite.rawValue
        )
#if canImport(WebRTC)
        if let pendingRemoteVideoTrackBeforeAdmission {
            self.pendingRemoteVideoTrackBeforeAdmission = nil
            installRemoteVideoTrack(pendingRemoteVideoTrackBeforeAdmission)
        }
#endif
        if shouldAutoStartRemoteDesktopHeartbeat() {
            startRemoteDesktopHeartbeat()
        }
        return !wasAlreadyPublished
    }

    nonisolated static func isPairingAdmissionBootstrapMessage(
        _ message: AppMessage
    ) -> Bool {
        switch message {
        case .pairingIdentityExchange, .heartbeat, .peerDisconnecting, .ping, .pong:
            return true
        default:
            return false
        }
    }

    private func currentSessionLifecycleWitness(
        sessionId: String
    ) -> SessionLifecycleWitness? {
        if let incarnation = activeSessionIncarnation,
           incarnation.sessionId == sessionId,
           isCurrentSessionIncarnation(incarnation) {
            return .incarnation(incarnation)
        }
        if let attempt = activeSessionSetupAttempt,
           attempt.sessionId == sessionId,
           attempt.lifecycleEpoch == sessionLifecycleEpoch {
            return .setup(attempt)
        }
        return nil
    }

    private func isCurrentSessionLifecycleWitness(
        _ expected: SessionLifecycleWitness
    ) -> Bool {
        switch expected {
        case .setup(let attempt):
            return activeSessionSetupAttempt == attempt
                && sessionLifecycleEpoch == attempt.lifecycleEpoch
        case .incarnation(let incarnation):
            return isCurrentSessionIncarnation(incarnation)
        }
    }

    private func requireCurrentSessionLifecycleWitness(
        _ expected: SessionLifecycleWitness
    ) throws {
        guard isCurrentSessionLifecycleWitness(expected) else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    public func connect(fromScannedString string: String) async {
        guard await waitForLifecycleAvailability(operation: "scan-connect") else { return }
        guard !Task.isCancelled else { return }
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
        let operation = beginPreSessionOperation(kind: .scannedConnect)
        inFlightScannedConnectLink = normalized
        defer {
            if inFlightScannedConnectLink == normalized {
                inFlightScannedConnectLink = nil
            }
            finishPreSessionOperation(operation)
        }
        do {
            try requireActivePreSessionOperation(operation)
            SkyBridgeLogger.shared.info("🌐 QR connect phase=start")
            // 与 macOS 扫描器对齐：先尝试服务端背书邀请(version>=8，无 PQC 公钥)，失败/版本不符再回退到经典 QR 解码。
            if let invite = decodeServerBackedConnectLinkIfPresent(normalized) {
                SkyBridgeLogger.shared.info(
                    "🌐 QR connect phase=server_backed_invite session_ref=\(SkyBridgeDiagnosticReference.stableReference(invite.sessionID)) device_ref=\(SkyBridgeDiagnosticReference.stableReference(invite.deviceID))"
                )
                try await redeemServerBackedQRCodeInvite(
                    invite,
                    expectedOperation: operation
                )
                try requireActivePreSessionOperation(operation)
                invalidateSessionBootstrapOperation()
                try await connect(
                    sessionId: invite.sessionID,
                    remoteName: invite.deviceName,
                    remotePeerDeviceId: invite.deviceID,
                    source: .qr,
                    role: .answerer
                )
                SkyBridgeLogger.shared.info(
                    "🌐 QR connect phase=connect_dispatched session_ref=\(SkyBridgeDiagnosticReference.stableReference(invite.sessionID))"
                )
                return
            }
            let payload = try await parseSkybridgeConnectLink(
                normalized,
                expectedOperation: operation
            )
            try requireActivePreSessionOperation(operation)
            SkyBridgeLogger.shared.info(
                "🌐 QR connect phase=payload_parsed session_ref=\(SkyBridgeDiagnosticReference.stableReference(payload.sessionID)) device_ref=\(SkyBridgeDiagnosticReference.stableReference(payload.deviceID))"
            )
            invalidateSessionBootstrapOperation()
            try await connect(from: payload)
            SkyBridgeLogger.shared.info(
                "🌐 QR connect phase=connect_dispatched session_ref=\(SkyBridgeDiagnosticReference.stableReference(payload.sessionID))"
            )
        } catch is CancellationError {
            return
        } catch {
            let msg = error.localizedDescription
            let diagnosticError = error as NSError
            SkyBridgeLogger.shared.error(
                "❌ QR connect phase=failed error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
            )
            guard isActivePreSessionOperation(operation, allowingLifecycleAdvance: true) else {
                return
            }
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

#if DEBUG || SKYBRIDGE_TESTING
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

    private func installTemporaryConnectLinkRegistration(
        lease: SignalServerClientCompat.SessionLease,
        signalingEndpoint: (origin: String, wsPath: String),
        localAuthority: CurrentPathLocalAuthority,
        ownerToken: UUID
    ) throws -> ConnectLinkRegistrationReceipt {
        let sessionId = lease.sessionID
        guard temporaryConnectLinkRegistrationOwnerBySessionId[sessionId] == nil,
              webrtcSignalingAuthTokenBySessionId[sessionId] == nil,
              webrtcTurnAdmissionTokenBySessionId[sessionId] == nil,
              webrtcMediaAdmissionTokenBySessionId[sessionId] == nil,
              currentPathSignalingOriginBySessionId[sessionId] == nil,
              currentPathSignalingWebSocketPathBySessionId[sessionId] == nil,
              currentPathLocalAuthorityBySessionId[sessionId] == nil else {
            throw CrossNetworkConnectLinkGenerationError.sessionStateCollision
        }

        temporaryConnectLinkRegistrationOwnerBySessionId[sessionId] = ownerToken
        webrtcSignalingAuthTokenBySessionId[sessionId] = lease.sessionToken
        webrtcTurnAdmissionTokenBySessionId[sessionId] = lease.turnAdmissionToken
        if let mediaAdmissionToken = lease.mediaAdmissionToken {
            webrtcMediaAdmissionTokenBySessionId[sessionId] = mediaAdmissionToken
        }
        setCurrentPathSignalingEndpoint(sessionId: sessionId, endpoint: signalingEndpoint)
        currentPathLocalAuthorityBySessionId[sessionId] = localAuthority

        return ConnectLinkRegistrationReceipt(
            ownerToken: ownerToken,
            sessionId: sessionId,
            sessionToken: lease.sessionToken,
            turnAdmissionToken: lease.turnAdmissionToken,
            mediaAdmissionToken: lease.mediaAdmissionToken,
            signalingOrigin: signalingEndpoint.origin,
            signalingWebSocketPath: signalingEndpoint.wsPath,
            authorityDeviceId: localAuthority.binding.deviceId,
            authorityFingerprint: localAuthority.binding.protocolPublicKeyFingerprint
        )
    }

    private func requireTemporaryConnectLinkRegistration(
        _ receipt: ConnectLinkRegistrationReceipt
    ) throws {
        guard temporaryConnectLinkRegistrationOwnerBySessionId[receipt.sessionId]
                == receipt.ownerToken else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func commitTemporaryConnectLinkRegistration(
        _ receipt: ConnectLinkRegistrationReceipt
    ) throws {
        try requireTemporaryConnectLinkRegistration(receipt)
        temporaryConnectLinkRegistrationOwnerBySessionId.removeValue(
            forKey: receipt.sessionId
        )
    }

    private func rollbackTemporaryConnectLinkRegistration(
        _ receipt: ConnectLinkRegistrationReceipt
    ) {
        let sessionId = receipt.sessionId
        guard temporaryConnectLinkRegistrationOwnerBySessionId[sessionId]
                == receipt.ownerToken else {
            return
        }
        temporaryConnectLinkRegistrationOwnerBySessionId.removeValue(forKey: sessionId)
        CrossNetworkTemporaryRegistrationRollback.removeOwnedValue(
            from: &webrtcSignalingAuthTokenBySessionId,
            key: sessionId,
            ownedValue: receipt.sessionToken
        )
        CrossNetworkTemporaryRegistrationRollback.removeOwnedValue(
            from: &webrtcTurnAdmissionTokenBySessionId,
            key: sessionId,
            ownedValue: receipt.turnAdmissionToken
        )
        if let mediaAdmissionToken = receipt.mediaAdmissionToken {
            CrossNetworkTemporaryRegistrationRollback.removeOwnedValue(
                from: &webrtcMediaAdmissionTokenBySessionId,
                key: sessionId,
                ownedValue: mediaAdmissionToken
            )
        }
        if currentPathSignalingOriginBySessionId[sessionId] == receipt.signalingOrigin,
           currentPathSignalingWebSocketPathBySessionId[sessionId]
                == receipt.signalingWebSocketPath {
            currentPathSignalingOriginBySessionId.removeValue(forKey: sessionId)
            currentPathSignalingWebSocketPathBySessionId.removeValue(forKey: sessionId)
        }
        if let authority = currentPathLocalAuthorityBySessionId[sessionId],
           authority.binding.deviceId == receipt.authorityDeviceId,
           authority.binding.protocolPublicKeyFingerprint == receipt.authorityFingerprint {
            currentPathLocalAuthorityBySessionId.removeValue(forKey: sessionId)
        }
    }

    /// 通过智能连接码连接（与 macOS 侧共享同一字母表与长度语义）
    public func connect(withCode rawCode: String) async {
        guard await waitForLifecycleAvailability(operation: "code-connect") else { return }
        guard !Task.isCancelled else { return }
        let lifecycleEpoch = connectionCodeLifecycleEpoch
        let sessionEpoch = sessionLifecycleEpoch
        let code: String
        do {
            code = try normalizeConnectionCode(rawCode)
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            state = .failed(msg)
            readiness = .idle
            return
        }

        if let sessionId = resolvedSessionIdByConnectionCode[code],
           currentSessionId == sessionId {
            switch state {
            case .connecting(let activeSessionId) where activeSessionId == sessionId:
                return
            case .connected(let activeSessionId) where activeSessionId == sessionId:
                return
            default:
                break
            }
        }
        while let existingOwner = connectionCodeConnectOwner {
            await existingOwner.task.value
            guard connectionCodeLifecycleEpoch == lifecycleEpoch,
                  sessionLifecycleEpoch == sessionEpoch,
                  !Task.isCancelled else { return }
            if connectionCodeConnectOwner?.token == existingOwner.token {
                connectionCodeConnectOwner = nil
            }
            if existingOwner.code == code { return }
        }

        guard connectionCodeLifecycleEpoch == lifecycleEpoch,
              sessionLifecycleEpoch == sessionEpoch,
              !Task.isCancelled else { return }
        let operation = beginPreSessionOperation(kind: .connectionCodeConnect)
        defer { finishPreSessionOperation(operation) }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performConnectWithCode(
                code,
                attemptToken: token,
                expectedConnectionCodeLifecycleEpoch: lifecycleEpoch,
                expectedSessionLifecycleEpoch: sessionEpoch,
                expectedOperation: operation
            )
        }
        connectionCodeConnectOwner = ConnectionCodeConnectOwner(
            code: code,
            token: token,
            task: task
        )
        await task.value
        if connectionCodeConnectOwner?.token == token {
            connectionCodeConnectOwner = nil
        }
    }

    private func performConnectWithCode(
        _ code: String,
        attemptToken: UUID,
        expectedConnectionCodeLifecycleEpoch: UInt64,
        expectedSessionLifecycleEpoch: UInt64,
        expectedOperation: PreSessionOperation
    ) async {
        disarmIdleConnectionReminder(clearPrompt: true)
        var sessionIdForRollback: String?
        do {
            try requireActivePreSessionOperation(expectedOperation)
            SkyBridgeLogger.shared.info("🌐 code connect phase=start code=<redacted>")
            let localAuthority = try await currentPathLocalAuthority()
            try requireActivePreSessionOperation(expectedOperation)
            guard sessionLifecycleEpoch == expectedSessionLifecycleEpoch else {
                throw CancellationError()
            }
            guard connectionCodeLifecycleEpoch == expectedConnectionCodeLifecycleEpoch else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            SkyBridgeLogger.shared.info("🌐 code connect phase=local_binding_ready device=present")
            let admission = try await requestAdmissionLease(for: localAuthority)
            try requireActivePreSessionOperation(expectedOperation)
            guard sessionLifecycleEpoch == expectedSessionLifecycleEpoch else {
                throw CancellationError()
            }
            guard connectionCodeLifecycleEpoch == expectedConnectionCodeLifecycleEpoch else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            SkyBridgeLogger.shared.info("🌐 code connect phase=admission_ready")
            let lookup = try await signalServer.lookupConnectionCode(admissionToken: admission.token, code: code)
            try requireActivePreSessionOperation(expectedOperation)
            guard sessionLifecycleEpoch == expectedSessionLifecycleEpoch else {
                throw CancellationError()
            }
            guard connectionCodeLifecycleEpoch == expectedConnectionCodeLifecycleEpoch else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            sessionIdForRollback = lookup.sessionID
            currentPathLocalAuthorityBySessionId[lookup.sessionID] = localAuthority
            resolvedSessionIdByConnectionCode[code] = lookup.sessionID
            SkyBridgeLogger.shared.info("🌐 code connect phase=lookup_ready session=assigned initiator=present")
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
                role: .answerer,
                connectionCodeAttemptToken: attemptToken
            )
            SkyBridgeLogger.shared.info("🌐 code connect phase=connect_dispatched session=assigned")
        } catch is CancellationError {
            resolvedSessionIdByConnectionCode.removeValue(forKey: code)
            return
        } catch {
            guard connectionCodeLifecycleEpoch == expectedConnectionCodeLifecycleEpoch,
                  isActivePreSessionOperation(expectedOperation),
                  !Task.isCancelled else { return }
            let msg = error.localizedDescription
            resolvedSessionIdByConnectionCode.removeValue(forKey: code)
            if let sessionIdForRollback,
               currentSessionId == sessionIdForRollback {
                await rollbackFailedSessionSetup(
                    sessionId: sessionIdForRollback,
                    error: error,
                    preservingConnectionCodeAttemptToken: attemptToken
                )
            }
            SkyBridgeLogger.shared.error(
                "❌ code connect phase=failed \(Self.diagnosticErrorSummary(error))"
            )
            lastError = msg
            state = .failed(msg)
            readiness = .idle
        }
    }

    /// 生成本机连接码并等待对端（例如 macOS）输入连接。
    /// - Returns: 服务端签发的短期连接码；失败时返回 `nil` 且更新 `state/.failed`。
    @discardableResult
    public func generateConnectionCode() async -> String? {
        guard await waitForLifecycleAvailability(operation: "connection-code") else { return nil }
        guard !Task.isCancelled else { return nil }
        disarmIdleConnectionReminder(clearPrompt: true)
        let requestedLeaseMode = connectionCodeLeaseMode
        var requestOperation = beginPreSessionOperation(kind: .connectionCodeGeneration)
        defer { finishPreSessionOperation(requestOperation) }

        do {
            var localAuthority = try await currentPathLocalAuthority()
            try requireActivePreSessionOperation(requestOperation)
            var localBinding = localAuthority.binding
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
            if localConnectionCode != nil,
               activeConnectionCodeLeaseMode == requestedLeaseMode,
               currentRole == .offerer,
               (!Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt) || !canReuseCurrentAuthority) {
                let reason = canReuseCurrentAuthority ? "connection_code_lease_not_reusable" : "connection_code_authority_changed"
                SkyBridgeLogger.shared.info("ℹ️ 本地连接码不可复用，重新向信令服务注册: reason=\(reason) code=<redacted>")
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
                invalidateSessionBootstrapOperation()
            }
            if localConnectionCode != nil,
               currentRole == .offerer,
               activeConnectionCodeLeaseMode != requestedLeaseMode {
                await disconnect()
                guard await waitForLifecycleAvailability(operation: "connection-code-regenerate") else {
                    return nil
                }
                try Task.checkCancellation()
                requestOperation = beginPreSessionOperation(kind: .connectionCodeGeneration)
                localAuthority = try await currentPathLocalAuthority()
                try requireActivePreSessionOperation(requestOperation)
                localBinding = localAuthority.binding
            }
            let admission = try await requestAdmissionLease(for: localAuthority)
            try requireActivePreSessionOperation(requestOperation)
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
            try requireActivePreSessionOperation(requestOperation)
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
            currentPathLocalAuthorityBySessionId[lease.sessionID] = localAuthority
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

            let bootstrapOperation = beginSessionBootstrapOperation(
                sessionId: lease.sessionID
            )
            connectionCodeBootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishSessionBootstrapOperation(bootstrapOperation) }
                guard self.isActiveSessionBootstrapOperation(bootstrapOperation),
                      self.localConnectionCode == lease.code,
                      self.localConnectionSessionId == lease.sessionID,
                      self.currentRole == .offerer else { return }
                do {
                    try await self.connect(
                        sessionId: lease.sessionID,
                        remoteName: nil,
                        remotePeerDeviceId: nil,
                        source: .code,
                        role: .offerer,
                        sessionBootstrapOperationToken: bootstrapOperation.token
                    )
                    guard self.isActiveSessionBootstrapOperation(bootstrapOperation),
                          self.currentSessionId == lease.sessionID,
                          self.currentRole == .offerer else { return }
                    self.localConnectionCode = lease.code
                    self.localConnectionSessionId = lease.sessionID
                } catch is CancellationError {
                    // Cancellation is expected during regenerate/disconnect.
                } catch {
                    guard self.isActiveSessionBootstrapOperation(bootstrapOperation) else {
                        return
                    }
                    let msg = error.localizedDescription
                    self.lastError = msg
                    self.state = .failed(msg)
                    self.readiness = .idle
                }
            }

            return lease.code
        } catch is CancellationError {
            return nil
        } catch {
            guard isActivePreSessionOperation(requestOperation) else { return nil }
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
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.localConnectionCode == code,
                  self.localConnectionSessionId == sessionID,
                  !Self.isReusableConnectionCodeLease(expiresAt: self.localConnectionCodeExpiresAt) else {
                return
            }
            SkyBridgeLogger.shared.info("ℹ️ 本地连接码租约到期，已清理旧码: reason=connection_code_lease_expired code=<redacted>")
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
        guard await waitForLifecycleAvailability(operation: "connect-link") else { return nil }
        guard !Task.isCancelled else { return nil }
        disarmIdleConnectionReminder(clearPrompt: true)
        let requestOperation = beginPreSessionOperation(kind: .connectLinkGeneration)
        defer { finishPreSessionOperation(requestOperation) }
        var registrationReceipt: ConnectLinkRegistrationReceipt?
        defer {
            if let registrationReceipt {
                rollbackTemporaryConnectLinkRegistration(registrationReceipt)
            }
        }
        do {
            let localAuthority = try await currentPathLocalAuthority()
            try requireActivePreSessionOperation(requestOperation)
            let localBinding = localAuthority.binding
            let admission = try await requestAdmissionLease(for: localAuthority)
            try requireActivePreSessionOperation(requestOperation)
            #if canImport(UIKit)
            let localDeviceName = AppleMobileDeviceIdentity.currentSnapshot().deviceName
            #else
            let localDeviceName = Host.current().localizedName ?? "Apple Device"
            #endif
            let lease = try await signalServer.registerSession(
                admissionToken: admission.token,
                validDuration: validDuration
            )
            try requireActivePreSessionOperation(requestOperation)
            let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
                origin: lease.signalingServerOrigin,
                wsPath: lease.wsPath
            )
            let kemPublicKeys = KEMPublicKeyInfo.normalizedValidKeys(
                try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
            )
            try requireActivePreSessionOperation(requestOperation)
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
                authority: localAuthority
            )
            try requireActivePreSessionOperation(requestOperation)
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

            let ownedRegistrationReceipt = try installTemporaryConnectLinkRegistration(
                lease: lease,
                signalingEndpoint: signalingEndpoint,
                localAuthority: localAuthority,
                ownerToken: requestOperation.token
            )
            registrationReceipt = ownedRegistrationReceipt
            try requireActivePreSessionOperation(requestOperation)
            try commitTemporaryConnectLinkRegistration(ownedRegistrationReceipt)
            registrationReceipt = nil

            currentConnectLink = link
            currentRole = .offerer
            localConnectionSessionId = lease.sessionID
            authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)
            state = .connecting(sessionId: lease.sessionID)
            readiness = .idle
            lastError = nil

            let bootstrapOperation = beginSessionBootstrapOperation(
                sessionId: lease.sessionID
            )
            connectionCodeBootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishSessionBootstrapOperation(bootstrapOperation) }
                guard self.isActiveSessionBootstrapOperation(bootstrapOperation),
                      self.currentConnectLink == link,
                      self.localConnectionSessionId == lease.sessionID,
                      self.currentRole == .offerer else { return }
                do {
                    try await self.connect(
                        sessionId: lease.sessionID,
                        remoteName: nil,
                        remotePeerDeviceId: nil,
                        source: .code,
                        role: .offerer,
                        sessionBootstrapOperationToken: bootstrapOperation.token
                    )
                } catch is CancellationError {
                } catch {
                    guard self.isActiveSessionBootstrapOperation(bootstrapOperation) else {
                        return
                    }
                    self.lastError = error.localizedDescription
                    self.state = .failed(error.localizedDescription)
                    self.readiness = .idle
                }
            }

            return link
        } catch is CancellationError {
            return nil
        } catch {
            guard isActivePreSessionOperation(requestOperation) else { return nil }
            lastError = error.localizedDescription
            state = .failed(error.localizedDescription)
            readiness = .idle
            return nil
        }
    }

    private func terminalNotificationContext(
        sessionId: String?
    ) -> TerminalNotificationContext? {
        guard let sessionId,
              hasUserVisibleRemoteDesktopSession(sessionId: sessionId) else {
            return nil
        }
        return TerminalNotificationContext(
            sessionId: sessionId,
            deviceName: remoteDesktopNotificationDeviceName(sessionId: sessionId)
        )
    }

    private func enqueueTerminalNotification(
        _ notification: DeferredTerminalNotification
    ) {
        let sessionReference = SkyBridgeDiagnosticReference.stableReference(
            notification.sessionId
        )
        SkyBridgeLogger.shared.info(
            "ℹ️ WebRTC terminal notification scheduled session_ref=\(sessionReference) kind=\(notification.notificationKind.rawValue)"
        )
        CrossNetworkTerminalNotificationDispatcher.enqueue {
            await NotificationManager.sendRemoteDesktopTerminalNotificationIfNeeded(
                sessionId: notification.sessionId,
                deviceName: notification.deviceName,
                transport: "webrtc",
                kind: notification.notificationKind,
                reason: notification.reason
            )
        } didFinish: {
            SkyBridgeLogger.shared.info(
                "ℹ️ WebRTC terminal notification attempt finished session_ref=\(sessionReference) kind=\(notification.notificationKind.rawValue)"
            )
        }
    }

    private func joinDetachedReceiveLoopTasks(
        controlTask: Task<Void, Never>?,
        screenTask: Task<Void, Never>?,
        originatingReceiveLoop: ReceiveLoopTaskKind?
    ) async {
        var detachedTasks: [(kind: ReceiveLoopTaskKind, task: Task<Void, Never>)] = []
        if originatingReceiveLoop != .control, let controlTask {
            detachedTasks.append((.control, controlTask))
        }
        if originatingReceiveLoop != .screen, let screenTask {
            detachedTasks.append((.screen, screenTask))
        }

        let outcomes = await withTaskGroup(
            of: (ReceiveLoopTaskKind, CrossNetworkCancelledTaskTeardownJoiner.Outcome).self,
            returning: [(ReceiveLoopTaskKind, CrossNetworkCancelledTaskTeardownJoiner.Outcome)].self
        ) { group in
            for detachedTask in detachedTasks {
                group.addTask {
                    let outcome = await CrossNetworkCancelledTaskTeardownJoiner.joinCancelledTask(
                        detachedTask.task,
                        timeoutSeconds: Self.receiveLoopTeardownJoinTimeoutSeconds
                    )
                    return (detachedTask.kind, outcome)
                }
            }
            var joined: [(ReceiveLoopTaskKind, CrossNetworkCancelledTaskTeardownJoiner.Outcome)] = []
            for await outcome in group {
                joined.append(outcome)
            }
            return joined
        }

        for (kind, outcome) in outcomes {
            guard case .quarantined(let reason) = outcome else { continue }
            let loopName = kind == .control ? "control" : "screen"
            let reasonName = reason == .deadlineExceeded
                ? "deadline_exceeded"
                : "join_cancelled"
            let message = "WebRTC \(loopName) receive loop did not quiesce during bounded teardown (reason=\(reasonName))"
            if pendingDisconnectFailure == nil {
                pendingDisconnectFailure = DisconnectTerminalFailure(
                    lastError: message,
                    stateMessage: message
                )
            }
            appendSmokeTrace(
                "receive-loop-quarantined loop=\(loopName) reason=\(reasonName)"
            )
            SkyBridgeLogger.shared.error("⛔️ \(message)")
        }
    }

    private func joinDetachedHandshakeDriverCancellationTask(
        _ cancellationTask: Task<Void, Never>?
    ) async {
        guard let cancellationTask else { return }
        let outcome = await CrossNetworkCancelledTaskTeardownJoiner.joinCancelledTask(
            cancellationTask,
            timeoutSeconds: Self.handshakeDriverTeardownJoinTimeoutSeconds
        )
        guard case .quarantined(let reason) = outcome else { return }
        let reasonName = reason == .deadlineExceeded
            ? "deadline_exceeded"
            : "join_cancelled"
        let message = "WebRTC handshake driver did not quiesce during bounded teardown "
            + "(reason=\(reasonName))"
        if pendingDisconnectFailure == nil {
            pendingDisconnectFailure = DisconnectTerminalFailure(
                lastError: message,
                stateMessage: message
            )
        }
        appendSmokeTrace(
            "handshake-driver-quarantined reason=\(reasonName)"
        )
        SkyBridgeLogger.shared.error("⛔️ \(message)")
    }

    private func joinDetachedSignalingCloseTask(
        _ closeTask: Task<Void, Never>?
    ) async {
        guard let closeTask else { return }
        let outcome = await CrossNetworkCancelledTaskTeardownJoiner.joinCancelledTask(
            closeTask,
            timeoutSeconds: Self.signalingTeardownJoinTimeoutSeconds
        )
        guard case .quarantined(let reason) = outcome else { return }
        let reasonName = reason == .deadlineExceeded
            ? "deadline_exceeded"
            : "join_cancelled"
        let message = "WebRTC signaling transport did not close during bounded teardown "
            + "(reason=\(reasonName))"
        if pendingDisconnectFailure == nil {
            pendingDisconnectFailure = DisconnectTerminalFailure(
                lastError: message,
                stateMessage: message
            )
        }
        appendSmokeTrace(
            "signaling-close-quarantined reason=\(reasonName)"
        )
        SkyBridgeLogger.shared.error("⛔️ \(message)")
    }

    public func disconnect(clearSnapshot: Bool = true) async {
        connectionCodeLifecycleEpoch &+= 1
        await disconnectInternal(
            clearSnapshot: clearSnapshot,
            preservingConnectionCodeAttemptToken: nil
        )
    }

    private func disconnectInternal(
        clearSnapshot: Bool,
        preservingConnectionCodeAttemptToken: UUID?,
        preservingSessionBootstrapToken: UUID? = nil,
        originatingReceiveLoop: ReceiveLoopTaskKind? = nil,
        terminalFailureMessage: String? = nil,
        terminalFailureStateMessage: String? = nil,
        expectedIncarnation: SessionIncarnation? = nil,
        expectedSetupAttempt: SessionSetupAttempt? = nil,
        terminalNotification: DisconnectTerminalNotification? = nil
    ) async {
        if let expectedIncarnation,
           !isCurrentSessionIncarnation(expectedIncarnation) {
            return
        }
        if let expectedSetupAttempt,
           activeSessionSetupAttempt != expectedSetupAttempt {
            return
        }
        pendingDisconnectClearSnapshot = pendingDisconnectClearSnapshot || clearSnapshot
        if !hasPendingDisconnectRequest {
            pendingDisconnectPreservingConnectionCodeAttemptToken = preservingConnectionCodeAttemptToken
            pendingDisconnectPreservingSessionBootstrapToken = preservingSessionBootstrapToken
            hasPendingDisconnectRequest = true
        } else {
            if pendingDisconnectPreservingConnectionCodeAttemptToken != preservingConnectionCodeAttemptToken {
                pendingDisconnectPreservingConnectionCodeAttemptToken = nil
            }
            if pendingDisconnectPreservingSessionBootstrapToken != preservingSessionBootstrapToken {
                pendingDisconnectPreservingSessionBootstrapToken = nil
            }
        }
        if let terminalFailureMessage,
           pendingDisconnectFailure == nil {
            pendingDisconnectFailure = DisconnectTerminalFailure(
                lastError: terminalFailureMessage,
                stateMessage: terminalFailureStateMessage ?? terminalFailureMessage
            )
        }
        guard let teardownLease = lifecycleGate.beginTeardown() else {
            if originatingReceiveLoop == nil {
                do {
                    try await lifecycleGate.waitForTeardownCompletion()
                } catch is CancellationError {
                    return
                } catch let error as CrossNetworkWebRTCLifecycleGate.WaitError {
                    let message: String
                    switch error {
                    case .waiterCapacityExceeded(let limit):
                        message = "WebRTC disconnect waiter capacity exceeded (limit=\(limit))"
                    }
                    if pendingDisconnectFailure == nil {
                        pendingDisconnectFailure = DisconnectTerminalFailure(
                            lastError: message,
                            stateMessage: message
                        )
                    }
                    SkyBridgeLogger.shared.error("⛔️ \(message)")
                } catch {
                    let message = "WebRTC disconnect lifecycle wait failed unexpectedly"
                    if pendingDisconnectFailure == nil {
                        pendingDisconnectFailure = DisconnectTerminalFailure(
                            lastError: message,
                            stateMessage: message
                        )
                    }
                    SkyBridgeLogger.shared.error("⛔️ \(message)")
                }
            }
            return
        }
        var deferredTerminalNotification: DeferredTerminalNotification?
        defer {
            if let deferredTerminalNotification {
                enqueueTerminalNotification(deferredTerminalNotification)
            }
            lifecycleGate.finishTeardown(teardownLease)
        }

        let disconnectedSessionId = currentSessionId
        if let disconnectedSessionId {
            let hadTerminalFailure = pendingDisconnectFailure != nil
            productEvidenceMediaTasksBySessionId.removeValue(
                forKey: disconnectedSessionId
            )?.cancel()
            if let evidenceOwner = productEvidenceOwnersBySessionId
                .removeValue(forKey: disconnectedSessionId) {
                let evidenceReason: ProductEvidenceDisconnectReason =
                    terminalNotification?.disconnectKind == .remoteLeave
                        ? .peer
                        : hadTerminalFailure == false
                            ? .user
                            : .protocolFailure
                _ = ProductReleaseEvidenceRecorder.shared.endSession(
                    owner: evidenceOwner,
                    reason: evidenceReason
                )
            }
        }
        let notificationContext = terminalNotificationContext(
            sessionId: terminalNotification?.sessionId ?? disconnectedSessionId
        )
        advanceSessionLifecycleEpoch()
        activePreSessionOperation = nil
        activeSessionSetupAttempt = nil
        activeSessionIncarnation = nil
        pairingMaterialAdmission = nil
        pairingMaterialAdmissionDeadline = nil
        currentSessionId = nil
        connectionCodeLifecycleEpoch &+= 1

        disarmIdleConnectionReminder(clearPrompt: true)
        suppressSignalingRecovery = true
        defer { suppressSignalingRecovery = false }
        for (_, task) in signalingRecoveryTasksBySessionId {
            task.cancel()
        }
        signalingRecoveryTasksBySessionId.removeAll()
        signalingRecoveryTaskTokensBySessionId.removeAll()
        let closingSignaling = signaling
        signaling = nil
        let signalingCloseTask: Task<Void, Never>?
        if let closingSignaling {
            signalingCloseTask = Task {
                await closingSignaling.close()
            }
        } else {
            signalingCloseTask = nil
        }
        signalingShardKey = nil
        signalingHealth = .healthy
        signalingGenerationBySessionId.removeAll()
        activeSignalingHandleBySessionId.removeAll()

        // Detach every receive/session authority and synchronously request
        // cancellation before the first suspension point. Old callbacks can no
        // longer observe a live manager incarnation while signaling closes.
        let controlReceiveTask = receiveTask
        receiveTask = nil
        let detachedScreenReceiveTask = screenReceiveTask
        screenReceiveTask = nil
        let controlInboundQueue = inboundQueue
        inboundQueue = nil
        let detachedScreenInboundQueue = screenInboundQueue
        screenInboundQueue = nil
        let closingSession = session
        session = nil
        let closingHandshakeDriver = handshakeDriver
        handshakeDriver = nil
        let handshakeDriverCancellationTask: Task<Void, Never>?
        if let closingHandshakeDriver {
            handshakeDriverCancellationTask = Task {
                await closingHandshakeDriver.cancel()
            }
        } else {
            handshakeDriverCancellationTask = nil
        }
        controlReceiveTask?.cancel()
        detachedScreenReceiveTask?.cancel()
        closingSession?.close()
        invalidateInboundFileTransferOperationsForTeardown()

        await joinDetachedHandshakeDriverCancellationTask(
            handshakeDriverCancellationTask
        )
        await joinDetachedSignalingCloseTask(signalingCloseTask)
        if let controlInboundQueue {
            await controlInboundQueue.finish()
        }
        if let detachedScreenInboundQueue {
            await detachedScreenInboundQueue.finish()
        }
        await joinDetachedReceiveLoopTasks(
            controlTask: controlReceiveTask,
            screenTask: detachedScreenReceiveTask,
            originatingReceiveLoop: originatingReceiveLoop
        )
        failAllFileTransferWaiters(FileTransferWaitError.transportClosed)
        let fileTransferCleanupReport = await cleanupInboundFileTransfers()
        if fileTransferCleanupReport.hasFailures {
            let message = "WebRTC inbound file-transfer teardown failed "
                + "(worker_deadline_exceeded=\(fileTransferCleanupReport.workerDeadlineExceededCount), "
                + "worker_join_cancelled=\(fileTransferCleanupReport.workerJoinCancelledCount), "
                + "partial_file_discard_failed=\(fileTransferCleanupReport.partialFileDiscardFailureCount))"
            if pendingDisconnectFailure == nil {
                pendingDisconnectFailure = DisconnectTerminalFailure(
                    lastError: message,
                    stateMessage: message
                )
            }
            appendSmokeTrace(
                "inbound-file-transfer-teardown-failed deadline=\(fileTransferCleanupReport.workerDeadlineExceededCount) cancelled=\(fileTransferCleanupReport.workerJoinCancelledCount) discard=\(fileTransferCleanupReport.partialFileDiscardFailureCount)"
            )
            SkyBridgeLogger.shared.error("⛔️ \(message)")
        }
        if let terminalNotification {
            applyActiveSessionDisconnect(
                sessionId: terminalNotification.sessionId,
                kind: terminalNotification.disconnectKind
            )
            if let notificationContext,
               notificationContext.sessionId == terminalNotification.sessionId {
                deferredTerminalNotification = DeferredTerminalNotification(
                    sessionId: notificationContext.sessionId,
                    deviceName: notificationContext.deviceName,
                    notificationKind: terminalNotification.notificationKind,
                    reason: terminalNotification.reason
                )
            }
        }
        if let disconnectedSessionId {
            clearWebRTCSecureEnvelopeState(for: disconnectedSessionId)
        }
        lastScreenData = nil
#if canImport(WebRTC)
        pendingRemoteVideoTrackBeforeAdmission = nil
        revokeRemoteDesktopNativeVideoAdmission()
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
        pendingPreSessionSignalingEnvelopesBySessionId.removeAll()
        webrtcSignalingAuthTokenBySessionId.removeAll()
        webrtcTurnAdmissionTokenBySessionId.removeAll()
        webrtcMediaAdmissionTokenBySessionId.removeAll()
        temporaryConnectLinkRegistrationOwnerBySessionId.removeAll()
        mediaAdmissionLeaseBackoffBySessionId.removeAll()
        mediaAdmissionLeaseInFlightOwnerBySessionId.removeAll()
        mediaAdmissionSessionRefreshInFlightOwnerBySessionId.removeAll()
        mediaAdmissionLeaseFailureReasonBySessionId.removeAll()
        mediaAdmissionAuthorityLostSessionIds.removeAll()
        mediaAdmissionRelayEndpointBySessionId.removeAll()
        mediaAdmissionRelayRoleBySessionId.removeAll()
        mediaAdmissionEndpointUnusableCountsBySessionReason.removeAll()
        currentPathExpectedRemoteAuthorityBySessionId.removeAll()
        authenticatedHandshakePeerBindingBySessionId.removeAll()
        currentPathJoinBootstrapGatesBySessionId.values.forEach {
            $0.fail(CancellationError())
        }
        currentPathJoinBootstrapGatesBySessionId.removeAll()
        currentPathLocalAuthorityBySessionId.removeAll()
        localProtocolIdentitySnapshot = nil
        currentPathSignalingOriginBySessionId.removeAll()
        currentPathSignalingWebSocketPathBySessionId.removeAll()
        remoteAppActivityAtBySessionId.removeAll()
        handshakeStartedSessionIds.removeAll()
        inboundInitialHandshakeResponderSessionIds.removeAll()
        inboundClassicAuthorityBootstrapSessionIds.removeAll()
        strictPQCClassicBootstrapOnlySessionIds.removeAll()
        rekeyInProgressSessionIds.removeAll()
        rekeyCompletedSessionIds.removeAll()
        activeOutboundRekeyOperationToken = nil
        inboundRekeyResponderSessionIds.removeAll()
        strictPQCRequestedBySessionId.removeAll()
        lastPairingIdentityExchangeSentAtByPeerId.removeAll()
        if pendingDisconnectClearSnapshot,
           terminalNotification == nil,
           let notificationContext {
            deferredTerminalNotification = DeferredTerminalNotification(
                sessionId: notificationContext.sessionId,
                deviceName: notificationContext.deviceName,
                notificationKind: .normal,
                reason: "explicit_disconnect"
            )
        }
        if pendingDisconnectClearSnapshot {
            activeSessionReconnectTimeoutTask?.cancel()
            activeSessionReconnectTimeoutTask = nil
            activeSessionSnapshot = nil
            sessionSnapshotMetadataBySessionId.removeAll()
        }
        if pendingDisconnectPreservingConnectionCodeAttemptToken == nil
            || connectionCodeConnectOwner?.token != pendingDisconnectPreservingConnectionCodeAttemptToken {
            connectionCodeConnectOwner?.task.cancel()
            connectionCodeConnectOwner = nil
            resolvedSessionIdByConnectionCode.removeAll()
        }
        if pendingDisconnectPreservingSessionBootstrapToken == nil
            || activeSessionBootstrapOperation?.token != pendingDisconnectPreservingSessionBootstrapToken {
            invalidateSessionBootstrapOperation()
        }
        if let terminalFailure = pendingDisconnectFailure {
            lastError = terminalFailure.lastError
            state = .failed(terminalFailure.stateMessage)
        } else {
            state = .idle
        }
        pendingDisconnectFailure = nil
        pendingDisconnectClearSnapshot = false
        hasPendingDisconnectRequest = false
        pendingDisconnectPreservingConnectionCodeAttemptToken = nil
        pendingDisconnectPreservingSessionBootstrapToken = nil
        readiness = .idle
    }

    private func rollbackFailedSessionSetup(
        sessionId: String,
        expectedSession: WebRTCSession? = nil,
        expectedSetupAttempt: SessionSetupAttempt? = nil,
        error: Error,
        preservingConnectionCodeAttemptToken: UUID? = nil,
        preservingSessionBootstrapToken: UUID? = nil
    ) async {
        if let expectedSetupAttempt {
            guard activeSessionSetupAttempt == expectedSetupAttempt,
                  currentSessionId == nil || currentSessionId == sessionId else {
                return
            }
        } else {
            guard currentSessionId == sessionId else { return }
        }
        if let expectedSession, session !== expectedSession {
            return
        }
        let message = error.localizedDescription
        appendSmokeTrace(
            "session-setup-rollback session=\(sessionId) error=\(CrossNetworkWebRTCTraceDescription.smokeTraceToken(message))"
        )
        await disconnectInternal(
            clearSnapshot: true,
            preservingConnectionCodeAttemptToken: preservingConnectionCodeAttemptToken,
            preservingSessionBootstrapToken: preservingSessionBootstrapToken,
            terminalFailureMessage: error is CancellationError ? nil : message,
            expectedSetupAttempt: expectedSetupAttempt
        )
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
                "🔁 WebRTC 原生视频轨实例已更换，重新绑定 renderer: track_ref=\(SkyBridgeDiagnosticReference.stableReference(incomingTrackId))"
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

        let isAdmitted = remoteVideoAdmissionOwner.map {
            isCurrentRemoteDesktopSessionOwner($0)
        } == true
        remoteVideoTrackIsAdmitted = isAdmitted
        track.isEnabled = isAdmitted
        SkyBridgeDiagnosticTrace.appendStatus(
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
                "⚠️ WebRTC 原生视频轨 3 秒内无真实渲染帧: session_ref=\(SkyBridgeDiagnosticReference.stableReference(self.currentSessionId)) probable=\(probable) firstPacket=\(self.remoteVideoTrackHasReceivedFirstPacket) fallbackEvidence=\(trigger)"
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
            "🎬 native-render-probe-start session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) track_ref=\(SkyBridgeDiagnosticReference.stableReference(trackId)) epoch=\(epoch) trigger=\(trigger) receiverEvidence=\(remoteVideoTrackHasReceiverFrameEvidence) evidenceSize=\(evidenceSizeLabel) action=raise-rtc-mtl-video-view"
        )
        SkyBridgeDiagnosticTrace.appendStatus(
            "native-render-probe-start session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) track_ref=\(SkyBridgeDiagnosticReference.stableReference(trackId)) epoch=\(epoch) trigger=\(trigger)"
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
                "⚠️ native-render-probe-timeout session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) track_ref=\(SkyBridgeDiagnosticReference.stableReference(trackId)) epoch=\(epoch) trigger=\(trigger) receiverEvidence=\(self.remoteVideoTrackHasReceiverFrameEvidence) evidenceSize=\(sizeLabel) fallback=source-jpeg"
            )
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-render-probe-timeout session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) track_ref=\(SkyBridgeDiagnosticReference.stableReference(trackId)) epoch=\(epoch) trigger=\(trigger)"
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
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=probe-inactive track_ref=\(SkyBridgeDiagnosticReference.stableReference(trackId)) epoch=\(renderEpoch.map(String.init) ?? "-")"
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
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=track-mismatch observed_track_ref=\(SkyBridgeDiagnosticReference.stableReference(observedTrackId)) expected_track_ref=\(SkyBridgeDiagnosticReference.stableReference(expectedTrackId))"
                )
                return
            }
            guard let renderEpoch,
                  renderEpoch == remoteVideoTrackRenderEpoch else {
                SkyBridgeLogger.shared.debug(
                    "ℹ️ ignore stale native render evidence: source=\(source) reason=epoch-mismatch observed_track_ref=\(SkyBridgeDiagnosticReference.stableReference(observedTrackId)) expected_track_ref=\(SkyBridgeDiagnosticReference.stableReference(expectedTrackId)) observedEpoch=\(renderEpoch.map(String.init) ?? "-") expectedEpoch=\(remoteVideoTrackRenderEpoch)"
                )
                return
            }
        }
        guard RemoteDesktopManager.instance.canAdmitCrossNetworkNativeVideoFrame() else {
            SkyBridgeDiagnosticTrace.appendStatus(
                "native-frame-drop session_ref=- dropReason=stream-configuration-ack-pending"
            )
            return
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
                SkyBridgeDiagnosticTrace.appendStatus(
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
        SkyBridgeDiagnosticTrace.appendStatus(
            "native-render-frame session=\(currentSessionId ?? "-") size=\(Int(visibleSize.width))x\(Int(visibleSize.height)) visibleSize=\(Int(visibleSize.width))x\(Int(visibleSize.height)) codedSize=\(Int(codedSize.width))x\(Int(codedSize.height)) source=\(source) nativeRenderEvidenceSource=\(source) nativePromotionState=\(nativePromotionState) uiSurface=\(uiSurface)"
        )
    }

    @MainActor
    private func normalizedNativeVideoVisibleFrameSize(
        forCodedSize codedSize: CGSize
    ) -> (visibleSize: CGSize, usedEvenPadding: Bool) {
        let normalization = CrossNetworkWebRTCNativeVideoPolicy.normalizedVisibleFrameSize(
            forCodedSize: codedSize,
            expectedVisibleSize: expectedNativeVideoVisibleFrameSize()
        )
        return (normalization.visibleSize, normalization.usedEvenPadding)
    }

    @MainActor
    private func expectedNativeVideoVisibleFrameSize() -> CGSize? {
        if let expected = RemoteDesktopManager.instance.expectedCrossNetworkNativeVideoVisibleFrameSize() {
            return expected
        }
#if DEBUG || SKYBRIDGE_TESTING
        return CrossNetworkWebRTCNativeVideoPolicy.requestedSmokeNativeVideoVisibleFrameSize()
#else
        return nil
#endif
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
            "ℹ️ fallback screen data confirms only degraded screen path; native promotion still waits for real RTP/render evidence session_ref=\(SkyBridgeDiagnosticReference.stableReference(currentSessionId))"
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
                        "⚠️ 发送闲置连接提醒失败: \(Self.diagnosticErrorSummary(error))"
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
        guard let shardKey = shardKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shardKey.isEmpty else {
            throw SignalingRetryControllerError.invalidWebSocketURL(
                "missing current-path signaling endpoint"
            )
        }
        guard let token = webrtcSignalingAuthTokenBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw SignalingRetryControllerError.invalidWebSocketURL("missing current-path signaling token")
        }
        guard let wsURL = CurrentPathSignalingWebSocketPolicyCompat.webSocketURL(
            signalingServerOrigin: currentPathSignalingOriginBySessionId[shardKey],
            wsPath: currentPathSignalingWebSocketPathBySessionId[shardKey],
            sessionID: shardKey,
            sessionToken: token,
            clientVersion: resolvedCurrentPathClientVersion(),
            protocolVersion: resolvedCurrentPathProtocolVersion(),
            credentialTransport: .headers
        ) else {
            throw SignalingRetryControllerError.invalidWebSocketURL(
                "missing current-path signaling endpoint"
            )
        }
        return wsURL
    }

    private func signalingHeaders(shardKey: String) throws -> [String: String] {
        guard let token = webrtcSignalingAuthTokenBySessionId[shardKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw SignalingRetryControllerError.invalidWebSocketURL("missing current-path signaling token")
        }
        guard let headers = CurrentPathSignalingWebSocketPolicyCompat.webSocketHeaders(
            sessionID: shardKey,
            sessionToken: token,
            clientVersion: resolvedCurrentPathClientVersion(),
            protocolVersion: resolvedCurrentPathProtocolVersion(),
            credentialTransport: .headers
        ) else {
            throw SignalingRetryControllerError.invalidWebSocketURL("invalid current-path signaling headers")
        }
        return headers
    }

    private func resolvedCurrentPathClientVersion() -> String {
        if let envVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envVersion.isEmpty {
            return envVersion
        }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "0.0.0"
    }

    private func resolvedCurrentPathProtocolVersion() -> String {
        let rawProtocolVersion = ProcessInfo.processInfo.environment["SKYBRIDGE_PROTOCOL_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        return rawProtocolVersion.isEmpty ? "1" : rawProtocolVersion
    }

    nonisolated static func currentPathSignalingWebSocketHeaders(
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String
    ) -> [String: String]? {
        CurrentPathSignalingWebSocketPolicyCompat.webSocketHeaders(
            sessionID: sessionID,
            sessionToken: sessionToken,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion,
            credentialTransport: .headers
        )
    }

    private func ensureSignalingConnected(
        shardKey: String? = nil,
        setupAttempt: SessionSetupAttempt? = nil
    ) async throws {
        let effectiveShardKey = (shardKey ?? currentSessionId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedShardKey = (effectiveShardKey?.isEmpty == false) ? effectiveShardKey : nil

        if let signaling, signalingShardKey != normalizedShardKey {
            let previousShardKey = signalingShardKey
            appendSmokeTrace("signaling reset shard=\(signalingShardKey ?? "-")->\(normalizedShardKey ?? "-")")
            await signaling.close()
            if let setupAttempt {
                try requireActiveSessionSetupAttempt(setupAttempt)
            }
            guard self.signaling === signaling else {
                throw CancellationError()
            }
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
            if let setupAttempt {
                try requireActiveSessionSetupAttempt(setupAttempt)
            }
            guard self.signaling === signaling else {
                throw CancellationError()
            }
            return
        }

        guard let sessionId = normalizedShardKey else {
            throw WebSocketSignalingClient.SignalingError.notConnected
        }

        let wsURL = try signalingURL(shardKey: sessionId)
        let headers = try signalingHeaders(shardKey: sessionId)
        let newSignaling = WebSocketSignalingClient(
            url: wsURL,
            sessionId: sessionId,
            generation: 0,
            additionalHeaders: headers
        )
        signaling = newSignaling
        signalingShardKey = sessionId
        signalingHealth = .healthy

#if DEBUG || SKYBRIDGE_TESTING
        await newSignaling.setOnTrace { [weak self] (line: String) in
            Task { @MainActor in
                guard let self, self.signaling === newSignaling else { return }
                self.appendSmokeTrace("ws \(line)")
            }
        }
        if let setupAttempt {
            try requireActiveSessionSetupAttempt(setupAttempt)
        }
        guard signaling === newSignaling else { throw CancellationError() }
#endif
        await newSignaling.setOnEnvelope { [weak self, weak newSignaling] (env: WebRTCSignalingEnvelope) in
            guard let newSignaling else { return }
            await self?.handleEnvelopeIfCurrent(env, signaling: newSignaling)
        }
        if let setupAttempt {
            try requireActiveSessionSetupAttempt(setupAttempt)
        }
        guard signaling === newSignaling else { throw CancellationError() }
        await newSignaling.setOnServerFrame { [weak self, weak newSignaling] (frame: WebSocketSignalingClient.SignalingServerFrame) in
            Task { @MainActor in
                guard let self, let newSignaling,
                      self.signaling === newSignaling else { return }
                await self.handleServerFrame(frame, sourceSignaling: newSignaling)
            }
        }
        if let setupAttempt {
            try requireActiveSessionSetupAttempt(setupAttempt)
        }
        guard signaling === newSignaling else { throw CancellationError() }
        await newSignaling.setOnLifecycleEvent { [weak self, weak newSignaling] (event: WebSocketSignalingClient.SignalingLifecycleEvent) in
            Task { @MainActor in
                guard let self, let newSignaling,
                      self.signaling === newSignaling else { return }
                await self.handleSignalingLifecycleEvent(
                    event,
                    sessionId: sessionId,
                    sourceSignaling: newSignaling
                )
            }
        }
        if let setupAttempt {
            try requireActiveSessionSetupAttempt(setupAttempt)
        }
        guard signaling === newSignaling else { throw CancellationError() }
        appendSmokeTrace("signaling connect shard=\(sessionId) url=\(WebSocketSignalingClient.redactedURLString(wsURL))")
        try await newSignaling.connectOrThrow()
        if let setupAttempt {
            try requireActiveSessionSetupAttempt(setupAttempt)
        }
        guard signaling === newSignaling else { throw CancellationError() }
    }

    private func signalingGeneration(for sessionId: String) -> Int {
        signalingGenerationBySessionId[sessionId] ?? 0
    }

    private func handleSignalingLifecycleEvent(
        _ event: WebSocketSignalingClient.SignalingLifecycleEvent,
        sessionId: String,
        sourceSignaling: WebSocketSignalingClient
    ) async {
        guard signaling === sourceSignaling,
              signalingShardKey == sessionId,
              event.handleId.sessionId == sessionId else { return }

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
                "♻️ signaling health recovered: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) phase=bound summary=\(remoteDesktopRecoveryDebugSummary())"
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
                SkyBridgeLogger.shared.error(
                    "❌ signaling health fatal: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) phase=failed preTransport=true summary=\(remoteDesktopRecoveryDebugSummary())"
                )
                guard let lifecycleWitness = currentSessionLifecycleWitness(
                    sessionId: sessionId
                ) else { return }
                await failConnectingSessionIfNeeded(
                    sessionId: sessionId,
                    expectedLifecycleWitness: lifecycleWitness,
                    expectedSignaling: sourceSignaling,
                    messageType: .join,
                    reason: "Signaling error: \(String(describing: failureKind))",
                    trigger: "lifecycle_failed_fatal"
                )
            } else {
                signalingHealth = .degradedRecoverable
                let recoveryScheduled = scheduleSignalingRecovery(
                    for: sessionId,
                    tokenExpired: failureKind == .tokenExpired
                )
                SkyBridgeLogger.shared.warning(
                    "⚠️ signaling health degraded: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) phase=failed recoveryScheduled=\(recoveryScheduled) summary=\(remoteDesktopRecoveryDebugSummary())"
                )
            }
        default:
            break
        }
    }

    private enum RequiredSetupEnvelopeOutcome: Equatable {
        case sent
        case supersededByHandshakeCompletion
    }

    private func authenticatedEnvelope(_ envelope: WebRTCSignalingEnvelope) -> WebRTCSignalingEnvelope? {
        if envelope.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return envelope
        }
        guard let token = webrtcSignalingAuthTokenBySessionId[envelope.sessionId],
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    private func requireCurrentSignalingClient(
        _ expectedSignaling: WebSocketSignalingClient,
        shardKey: String,
        expectedLifecycleWitness: SessionLifecycleWitness
    ) throws {
        guard expectedLifecycleWitness.sessionId == shardKey else {
            throw CancellationError()
        }
        try requireCurrentSessionLifecycleWitness(expectedLifecycleWitness)
        guard signaling === expectedSignaling,
              signalingShardKey == shardKey else {
            throw CancellationError()
        }
    }

    private func currentSignalingClient(
        shardKey: String,
        expectedLifecycleWitness: SessionLifecycleWitness
    ) throws -> WebSocketSignalingClient {
        guard expectedLifecycleWitness.sessionId == shardKey else {
            throw CancellationError()
        }
        try requireCurrentSessionLifecycleWitness(expectedLifecycleWitness)
        guard let signaling, signalingShardKey == shardKey else {
            throw WebSocketSignalingClient.SignalingError.notConnected
        }
        return signaling
    }

    private func shouldDeferCurrentSignalingSend(
        sessionId: String,
        messageType: WebRTCSignalingEnvelope.MessageType
    ) -> Bool {
        Self.shouldDeferSignalingSendRecovery(
            isHandshakeComplete: isHandshakeComplete(for: sessionId),
            suppressRecovery: suppressSignalingRecovery,
            messageType: messageType
        )
    }

    private func sendEnvelope(
        _ envelope: WebRTCSignalingEnvelope,
        expectedLifecycleWitness: SessionLifecycleWitness,
        retries: Int = 2
    ) async {
        guard envelope.sessionId == expectedLifecycleWitness.sessionId,
              isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else {
            return
        }
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

        guard let authorizedEnvelope = authenticatedEnvelope(directedEnvelope) else {
            guard isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else { return }
            let expectedSignaling = signalingShardKey == directedEnvelope.sessionId
                ? signaling
                : nil
            await failConnectingSessionIfNeeded(
                sessionId: directedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness,
                expectedSignaling: expectedSignaling,
                messageType: directedEnvelope.type,
                reason: "Missing signaling authorization",
                trigger: "send_missing_authorization_\(directedEnvelope.type.rawValue)"
            )
            return
        }
        appendSmokeTrace("tx \(describeEnvelope(authorizedEnvelope)) retries=\(retries)")
        if shouldDeferCurrentSignalingSend(
            sessionId: authorizedEnvelope.sessionId,
            messageType: authorizedEnvelope.type
        ) {
            guard let expectedSignaling = try? currentSignalingClient(
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            ) else {
                guard isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else { return }
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=missing_client"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session_ref=\(SkyBridgeDiagnosticReference.stableReference(authorizedEnvelope.sessionId)) type=\(authorizedEnvelope.type.rawValue) phase=missing_client"
                )
                return
            }

            let lifecyclePhase = await expectedSignaling.currentLifecyclePhase()
            do {
                try requireCurrentSignalingClient(
                    expectedSignaling,
                    shardKey: authorizedEnvelope.sessionId,
                    expectedLifecycleWitness: expectedLifecycleWitness
                )
            } catch {
                return
            }
            guard lifecyclePhase == .bound else {
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=\(lifecyclePhase.rawValue)"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session_ref=\(SkyBridgeDiagnosticReference.stableReference(authorizedEnvelope.sessionId)) type=\(authorizedEnvelope.type.rawValue) phase=\(lifecyclePhase.rawValue)"
                )
                return
            }

            do {
                do {
                    try await expectedSignaling.send(authorizedEnvelope)
                } catch {
                    try requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                    throw error
                }
                try requireCurrentSignalingClient(
                    expectedSignaling,
                    shardKey: authorizedEnvelope.sessionId,
                    expectedLifecycleWitness: expectedLifecycleWitness
                )
                appendSmokeTrace("tx-ok \(describeEnvelope(authorizedEnvelope))")
                return
            } catch {
                guard isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                      signaling === expectedSignaling,
                      signalingShardKey == authorizedEnvelope.sessionId else {
                    return
                }
                signalingHealth = .degradedRecoverable
                appendSmokeTrace(
                    "tx-suppressed-detached \(describeEnvelope(authorizedEnvelope)) phase=\(lifecyclePhase.rawValue) error=\(error.localizedDescription)"
                )
                SkyBridgeLogger.shared.debug(
                    "ℹ️ suppress detached post-transport signaling send: session_ref=\(SkyBridgeDiagnosticReference.stableReference(authorizedEnvelope.sessionId)) type=\(authorizedEnvelope.type.rawValue) phase=\(lifecyclePhase.rawValue) \(Self.diagnosticErrorSummary(error))"
                )
                return
            }
        }
        let expectedSignaling: WebSocketSignalingClient
        do {
            expectedSignaling = try currentSignalingClient(
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )
        } catch {
            guard isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else { return }
            await failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness,
                expectedSignaling: nil,
                messageType: authorizedEnvelope.type,
                reason: "信令发送失败: signaling client unavailable",
                trigger: "send_missing_client_\(authorizedEnvelope.type.rawValue)"
            )
            return
        }
        do {
            let retryOutcome = try await signalingRetryController.sendWithRetry(
                retries: retries,
                validateCurrentAttempt: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                },
                shouldSupersedeCurrentAttempt: { [weak self] in
                    self?.shouldDeferCurrentSignalingSend(
                        sessionId: authorizedEnvelope.sessionId,
                        messageType: authorizedEnvelope.type
                    ) ?? false
                },
                reconnectIfNeeded: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                    if self.shouldDeferCurrentSignalingSend(
                        sessionId: authorizedEnvelope.sessionId,
                        messageType: authorizedEnvelope.type
                    ) {
                        throw CancellationError()
                    }
                    do {
                        try await expectedSignaling.connectOrThrow()
                    } catch {
                        try self.requireCurrentSignalingClient(
                            expectedSignaling,
                            shardKey: authorizedEnvelope.sessionId,
                            expectedLifecycleWitness: expectedLifecycleWitness
                        )
                        throw error
                    }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                },
                send: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                    if self.shouldDeferCurrentSignalingSend(
                        sessionId: authorizedEnvelope.sessionId,
                        messageType: authorizedEnvelope.type
                    ) {
                        throw CancellationError()
                    }
                    do {
                        try await expectedSignaling.send(authorizedEnvelope)
                    } catch {
                        try self.requireCurrentSignalingClient(
                            expectedSignaling,
                            shardKey: authorizedEnvelope.sessionId,
                            expectedLifecycleWitness: expectedLifecycleWitness
                        )
                        throw error
                    }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                }
            )
            if retryOutcome == .superseded {
                appendSmokeTrace(
                    "tx-superseded \(describeEnvelope(authorizedEnvelope)) reason=handshake-complete"
                )
                return
            }
            try requireCurrentSignalingClient(
                expectedSignaling,
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )
            appendSmokeTrace("tx-ok \(describeEnvelope(authorizedEnvelope))")
        } catch SignalingRetryControllerError.invalidWebSocketURL {
            guard (try? requireCurrentSignalingClient(
                expectedSignaling,
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )) != nil else { return }
            if shouldDeferCurrentSignalingSend(
                sessionId: authorizedEnvelope.sessionId,
                messageType: authorizedEnvelope.type
            ) { return }
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=invalid_websocket_url")
            await failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness,
                expectedSignaling: expectedSignaling,
                messageType: authorizedEnvelope.type,
                reason: "信令服务 URL 无效",
                trigger: "send_invalid_url_\(authorizedEnvelope.type.rawValue)"
            )
        } catch SignalingRetryControllerError.attemptTimedOut {
            guard (try? requireCurrentSignalingClient(
                expectedSignaling,
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )) != nil else { return }
            if shouldDeferCurrentSignalingSend(
                sessionId: authorizedEnvelope.sessionId,
                messageType: authorizedEnvelope.type
            ) { return }
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=attempt_timed_out")
            await failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness,
                expectedSignaling: expectedSignaling,
                messageType: authorizedEnvelope.type,
                reason: "信令发送失败: 请求超时",
                trigger: "send_timeout_\(authorizedEnvelope.type.rawValue)"
            )
        } catch is CancellationError {
            if !Task.isCancelled,
               isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
               shouldDeferCurrentSignalingSend(
                    sessionId: authorizedEnvelope.sessionId,
                    messageType: authorizedEnvelope.type
               ) {
                appendSmokeTrace("tx-superseded \(describeEnvelope(authorizedEnvelope)) reason=handshake-complete")
                return
            }
            appendSmokeTrace("tx-cancel \(describeEnvelope(authorizedEnvelope))")
            return
        } catch {
            guard (try? requireCurrentSignalingClient(
                expectedSignaling,
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )) != nil else { return }
            if shouldDeferCurrentSignalingSend(
                sessionId: authorizedEnvelope.sessionId,
                messageType: authorizedEnvelope.type
            ) { return }
            appendSmokeTrace("tx-fail \(describeEnvelope(authorizedEnvelope)) error=\(error.localizedDescription)")
            await failConnectingSessionIfNeeded(
                sessionId: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness,
                expectedSignaling: expectedSignaling,
                messageType: authorizedEnvelope.type,
                reason: "信令发送失败: \(error.localizedDescription)",
                trigger: "send_error_\(authorizedEnvelope.type.rawValue)"
            )
        }
    }

    private func sendRequiredSetupEnvelope(
        _ envelope: WebRTCSignalingEnvelope,
        expectedLifecycleWitness: SessionLifecycleWitness,
        retries: Int
    ) async throws -> RequiredSetupEnvelopeOutcome {
        guard envelope.sessionId == expectedLifecycleWitness.sessionId else {
            throw CancellationError()
        }
        try requireCurrentSessionLifecycleWitness(expectedLifecycleWitness)
        guard let authorizedEnvelope = authenticatedEnvelope(envelope) else {
            throw WebSocketSignalingClient.SignalingError.sendRequiresBound
        }
        if shouldDeferCurrentSignalingSend(
            sessionId: authorizedEnvelope.sessionId,
            messageType: authorizedEnvelope.type
        ) {
            return .supersededByHandshakeCompletion
        }
        let expectedSignaling = try currentSignalingClient(
            shardKey: authorizedEnvelope.sessionId,
            expectedLifecycleWitness: expectedLifecycleWitness
        )
        do {
            let retryOutcome = try await signalingRetryController.sendWithRetry(
                retries: retries,
                validateCurrentAttempt: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                },
                shouldSupersedeCurrentAttempt: { [weak self] in
                    self?.shouldDeferCurrentSignalingSend(
                        sessionId: authorizedEnvelope.sessionId,
                        messageType: authorizedEnvelope.type
                    ) ?? false
                },
                reconnectIfNeeded: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                    if self.shouldDeferCurrentSignalingSend(
                        sessionId: authorizedEnvelope.sessionId,
                        messageType: authorizedEnvelope.type
                    ) {
                        throw CancellationError()
                    }
                    do {
                        try await expectedSignaling.connectOrThrow()
                    } catch {
                        try self.requireCurrentSignalingClient(
                            expectedSignaling,
                            shardKey: authorizedEnvelope.sessionId,
                            expectedLifecycleWitness: expectedLifecycleWitness
                        )
                        throw error
                    }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                },
                send: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                    if self.shouldDeferCurrentSignalingSend(
                        sessionId: authorizedEnvelope.sessionId,
                        messageType: authorizedEnvelope.type
                    ) {
                        throw CancellationError()
                    }
                    do {
                        try await expectedSignaling.send(authorizedEnvelope)
                    } catch {
                        try self.requireCurrentSignalingClient(
                            expectedSignaling,
                            shardKey: authorizedEnvelope.sessionId,
                            expectedLifecycleWitness: expectedLifecycleWitness
                        )
                        throw error
                    }
                    try self.requireCurrentSignalingClient(
                        expectedSignaling,
                        shardKey: authorizedEnvelope.sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness
                    )
                }
            )
            if retryOutcome == .superseded {
                appendSmokeTrace(
                    "tx-required-superseded \(describeEnvelope(authorizedEnvelope)) reason=handshake-complete"
                )
                return .supersededByHandshakeCompletion
            }
            try requireCurrentSignalingClient(
                expectedSignaling,
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )
            appendSmokeTrace("tx-required-ok \(describeEnvelope(authorizedEnvelope))")
            return .sent
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            try requireCurrentSessionLifecycleWitness(expectedLifecycleWitness)
            if shouldDeferCurrentSignalingSend(
                sessionId: authorizedEnvelope.sessionId,
                messageType: authorizedEnvelope.type
            ) {
                appendSmokeTrace("tx-required-superseded \(describeEnvelope(authorizedEnvelope)) reason=handshake-complete")
                return .supersededByHandshakeCompletion
            }
            try requireCurrentSignalingClient(
                expectedSignaling,
                shardKey: authorizedEnvelope.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )
            throw error
        }
    }

    private func failConnectingSessionIfNeeded(
        sessionId: String,
        expectedLifecycleWitness: SessionLifecycleWitness,
        expectedSignaling: WebSocketSignalingClient?,
        messageType: WebRTCSignalingEnvelope.MessageType,
        reason: String,
        trigger: String
    ) async {
        guard expectedLifecycleWitness.sessionId == sessionId,
              isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
              currentSessionId == sessionId else { return }

        if let expectedSignaling {
            guard (try? requireCurrentSignalingClient(
                expectedSignaling,
                shardKey: sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness
            )) != nil else { return }
        } else {
            guard signaling == nil,
                  signalingShardKey == nil || signalingShardKey == sessionId else { return }
        }

        if shouldDeferCurrentSignalingSend(
            sessionId: sessionId,
            messageType: messageType
        ) {
            noteDetachedSignalingAfterTransportEstablished(
                sessionId: sessionId,
                source: trigger,
                failure: reason
            )
            return
        }

        let message = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        SkyBridgeLogger.shared.error(
            "❌ cross-network connect failed before transportReady: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) trigger=\(trigger) failure_ref=\(SkyBridgeDiagnosticReference.stableReference(message))"
        )
        switch expectedLifecycleWitness {
        case .incarnation(let incarnation):
            guard isCurrentSessionIncarnation(incarnation) else { return }
            await disconnectInternal(
                clearSnapshot: true,
                preservingConnectionCodeAttemptToken: nil,
                terminalFailureMessage: message,
                expectedIncarnation: incarnation
            )
        case .setup(let setupAttempt):
            guard activeSessionSetupAttempt == setupAttempt else { return }
            await disconnectInternal(
                clearSnapshot: true,
                preservingConnectionCodeAttemptToken: nil,
                terminalFailureMessage: message,
                expectedSetupAttempt: setupAttempt
            )
        }
    }

    private func handleServerFrame(
        _ frame: WebSocketSignalingClient.SignalingServerFrame,
        sourceSignaling: WebSocketSignalingClient
    ) async {
        guard signaling === sourceSignaling,
              let sourceShard = signalingShardKey else { return }
        let sessionLabel = Self.publicSignalingSessionLabel(frame.sessionId)
        guard frame.isError else {
            appendSmokeTrace(
                "server-frame type=\(frame.type) session=\(sessionLabel) error_present=0 what_present=\(frame.what == nil ? 0 : 1)"
            )
            return
        }

        let rawReason = frame.error ?? "unknown_signaling_error"
        let traceFailureClass = Self.classifySignalingFailureReason(rawReason)
        let traceFailureCode = Self.publicSignalingFailureCode(traceFailureClass)
        let tracePublicFailureClass = Self.publicSignalingFailureClass(traceFailureClass)
        appendSmokeTrace(
            "server-frame type=\(frame.type) session=\(sessionLabel) failure_code=\(traceFailureCode) failure_class=\(tracePublicFailureClass) what_present=\(frame.what == nil ? 0 : 1)"
        )
        let declaredSessionId = frame.sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let failureClass = traceFailureClass
        let failureCode = traceFailureCode
        let publicFailureClass = tracePublicFailureClass

        if let declaredSessionId,
           !declaredSessionId.isEmpty,
           declaredSessionId != sourceShard {
            SkyBridgeLogger.shared.warning(
                "ℹ️ reject signaling server error for a shard different from its exact source client: failure_code=\(failureCode) failure_class=\(publicFailureClass)"
            )
            return
        }
        let sessionId = declaredSessionId.flatMap { $0.isEmpty ? nil : $0 }
            ?? sourceShard

        guard signaling === sourceSignaling,
              signalingShardKey == sessionId,
              currentSessionId == sessionId,
              let lifecycleWitness = currentSessionLifecycleWitness(sessionId: sessionId) else { return }
        if suppressSignalingRecovery { return }

        if Self.shouldUseOnDemandSignalingAfterTransportFailure(
            isHandshakeComplete: isHandshakeComplete(for: sessionId),
            suppressRecovery: suppressSignalingRecovery
        ) {
            noteDetachedSignalingAfterTransportEstablished(
                sessionId: sessionId,
                source: "server_frame",
                failure: failureCode,
                fatal: Self.isFatalPostTransportFailure(failureClass)
            )
            return
        }

        SkyBridgeLogger.shared.error("❌ signaling server rejected frame: session_ref=\(sessionLabel) failure_code=\(failureCode) failure_class=\(publicFailureClass)")
        if Self.isFatalPreTransportFailure(failureClass) {
            await failConnectingSessionIfNeeded(
                sessionId: sessionId,
                expectedLifecycleWitness: lifecycleWitness,
                expectedSignaling: sourceSignaling,
                messageType: .join,
                reason: "Signaling error: \(failureCode)",
                trigger: "server_frame_\(failureCode)"
            )
            return
        }

        signalingHealth = .degradedRecoverable
        scheduleSignalingRecovery(for: sessionId, tokenExpired: failureClass == .tokenExpired)
        lastError = "Signaling error: \(failureCode)"
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
            "ℹ️ signaling detached after transport establishment: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) source=\(source) fatal=\(fatal ? 1 : 0)\(failureSuffix) summary=\(remoteDesktopRecoveryDebugSummary())"
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
        let taskToken = UUID()
        signalingRecoveryTaskTokensBySessionId[sessionId] = taskToken
        signalingRecoveryTasksBySessionId[sessionId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishSignalingRecoveryTask(sessionId: sessionId, token: taskToken) }
            let maxAttempts = tokenExpired ? 1 : 3
            for attempt in 0..<maxAttempts where !Task.isCancelled {
                if attempt > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
                    } catch {
                        return
                    }
                }
                guard self.signalingRecoveryTaskTokensBySessionId[sessionId] == taskToken else { return }
                do {
                    try await self.ensureSignalingConnected(shardKey: sessionId)
                    try Task.checkCancellation()
                    guard self.signalingRecoveryTaskTokensBySessionId[sessionId] == taskToken else { return }
                    if self.signalingShardKey == sessionId {
                        self.signalingHealth = .healthy
                        SkyBridgeLogger.shared.info(
                            "♻️ signaling recovery succeeded: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) attempt=\(attempt + 1) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                        )
                    }
                    return
                } catch is CancellationError {
                    if self.signalingRecoveryTaskTokensBySessionId[sessionId] == taskToken {
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ signaling recovery cancelled: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) attempt=\(attempt + 1)"
                        )
                    }
                    return
                } catch {
                    guard self.signalingRecoveryTaskTokensBySessionId[sessionId] == taskToken else { return }
                    SkyBridgeLogger.shared.error(
                        "⚠️ signaling recovery failed: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) attempt=\(attempt + 1) \(Self.diagnosticErrorSummary(error)) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                    )
                }
            }
            guard self.signalingRecoveryTaskTokensBySessionId[sessionId] == taskToken else { return }
            if tokenExpired, self.isHandshakeComplete(for: sessionId) {
                self.signalingHealth = .degradedFatal
                SkyBridgeLogger.shared.error(
                    "❌ signaling recovery exhausted after token expiry: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) summary=\(self.remoteDesktopRecoveryDebugSummary())"
                )
            }
        }
        return true
    }

    private func finishSignalingRecoveryTask(sessionId: String, token: UUID) {
        guard signalingRecoveryTaskTokensBySessionId[sessionId] == token else { return }
        signalingRecoveryTasksBySessionId.removeValue(forKey: sessionId)
        signalingRecoveryTaskTokensBySessionId.removeValue(forKey: sessionId)
    }

    private func stopJoinHeartbeat() {
        joinHeartbeatTask?.cancel()
        joinHeartbeatTask = nil
    }

    /// Builds the strict-PQC `.join` bootstrap payload carrying this device's protocol identity
    /// + KEM public keys, wire-identical to what the macOS offerer ingests in
    /// `ingestWebRTCJoinBootstrapPayload`. Without this the Mac offerer waits for the joiner's
    /// KEM, never receives it (payload was nil), and the PQC handshake fails (`handshake_failed`).
    ///
    /// The identity/KEM material is required for this authenticated current-path
    /// session. A missing authority fails setup instead of silently sending an
    /// unbound join. The self-asserted fingerprint is recomputed on the peer, and the bound
    /// KEM remains authenticated end-to-end by the strict-PQC MessageB transcript signature against
    /// the pinned fingerprint, so populating these fields adds no trust.
    private func makeWebRTCJoinBootstrapPayload(
        sessionId: String
    ) async throws -> WebRTCSignalingEnvelope.Payload {
        guard let localAuthority = currentPathLocalAuthorityBySessionId[sessionId] else {
            throw SkyBridgeError.notInitialized
        }
        let localBinding = localAuthority.binding
        let kemPublicKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        )
        guard !kemPublicKeys.isEmpty else {
            throw SkyBridgeError.invalidKeyData(
                reason: "WebRTC join bootstrap has no valid PQC KEM public keys"
            )
        }
        return WebRTCSignalingEnvelope.Payload(
            protocolSigningAlgorithm: localBinding.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: localBinding.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: localBinding.protocolPublicKeyBytes,
            kemPublicKeys: kemPublicKeys.map {
                WebRTCSignalingEnvelope.Payload.BootstrapKEMPublicKey(
                    suiteWireId: $0.suiteWireId,
                    publicKey: $0.publicKey
                )
            },
            platform: "iOS",
            osVersion: {
                let version = ProcessInfo.processInfo.operatingSystemVersion
                return "iOS \(version.majorVersion).\(version.minorVersion)"
            }()
        )
    }

    nonisolated static func validatedWebRTCJoinBootstrap(
        _ payload: WebRTCSignalingEnvelope.Payload?,
        from remoteDeviceId: String,
        expectedAuthority: CurrentPathRemoteAuthorityCompat?,
        requiresStrictPQC: Bool
    ) throws -> (
        authority: CurrentPathRemoteAuthorityCompat,
        kemPublicKeys: [KEMPublicKeyInfo]
    )? {
        guard let payload else {
            if requiresStrictPQC { throw CurrentPathJoinBootstrapError.missingIdentity }
            return nil
        }
        let hasAnyIdentityField = payload.protocolSigningAlgorithm != nil
            || payload.protocolPublicKeyFingerprint != nil
            || payload.protocolPublicKeyBytes != nil
        guard hasAnyIdentityField else {
            if requiresStrictPQC { throw CurrentPathJoinBootstrapError.missingIdentity }
            return nil
        }
        guard let algorithm = payload.protocolSigningAlgorithm,
              let publicKey = payload.protocolPublicKeyBytes,
              let claimedFingerprint = payload.protocolPublicKeyFingerprint,
              let normalizedRemoteDeviceId = try? CurrentPathSecurityCompat
                .normalizeDeviceId(remoteDeviceId) else {
            throw CurrentPathJoinBootstrapError.invalidIdentity
        }
        let normalizedFingerprint = claimedFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard claimedFingerprint == normalizedFingerprint,
              normalizedFingerprint.count == 64,
              normalizedFingerprint.allSatisfy(\.isHexDigit) else {
            throw CurrentPathJoinBootstrapError.invalidIdentity
        }
        do {
            try CurrentPathSecurityCompat.validateKeyEncoding(
                bytes: publicKey,
                algorithm: algorithm
            )
        } catch {
            throw CurrentPathJoinBootstrapError.invalidIdentity
        }
        guard CurrentPathSecurityCompat.computeFingerprint(
            algorithm: algorithm,
            publicKeyBytes: publicKey
        ) == normalizedFingerprint else {
            throw CurrentPathJoinBootstrapError.invalidIdentity
        }

        let authority: CurrentPathRemoteAuthorityCompat
        if let expectedAuthority {
            guard let expectedDeviceId = try? CurrentPathSecurityCompat
                .normalizeDeviceId(expectedAuthority.deviceId),
                  normalizedRemoteDeviceId == expectedDeviceId,
                  algorithm == expectedAuthority.protocolSigningAlgorithm,
                  normalizedFingerprint == expectedAuthority.protocolPublicKeyFingerprint
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  expectedAuthority.protocolPublicKeyBytes.map({ $0 == publicKey }) ?? true else {
                throw CurrentPathJoinBootstrapError.authorityMismatch
            }
            authority = CurrentPathRemoteAuthorityCompat(
                deviceId: expectedDeviceId,
                protocolSigningAlgorithm: algorithm,
                protocolPublicKeyFingerprint: normalizedFingerprint,
                protocolPublicKeyBytes: publicKey,
                deviceName: expectedAuthority.deviceName
            )
        } else {
            authority = CurrentPathRemoteAuthorityCompat(
                deviceId: normalizedRemoteDeviceId,
                protocolSigningAlgorithm: algorithm,
                protocolPublicKeyFingerprint: normalizedFingerprint,
                protocolPublicKeyBytes: publicKey,
                deviceName: nil
            )
        }

        let kemPublicKeys = KEMPublicKeyInfo.normalizedValidKeys(
            (payload.kemPublicKeys ?? []).map {
                KEMPublicKeyInfo(
                    suiteWireId: $0.suiteWireId,
                    publicKey: $0.publicKey
                )
            },
            platform: payload.platform,
            osVersion: payload.osVersion
        )
        guard !kemPublicKeys.isEmpty else {
            throw CurrentPathJoinBootstrapError.missingKEM
        }
        return (authority, kemPublicKeys)
    }

    private func ingestWebRTCJoinBootstrapPayload(
        _ payload: WebRTCSignalingEnvelope.Payload?,
        from remoteDeviceId: String,
        sessionId: String,
        expectedLifecycleWitness: SessionLifecycleWitness
    ) async throws {
        guard expectedLifecycleWitness.sessionId == sessionId else {
            throw CancellationError()
        }
        try requireCurrentSessionLifecycleWitness(expectedLifecycleWitness)
        let requiresStrictPQC = currentPathLocalAuthorityBySessionId[sessionId]?
            .identity.algorithm != .ed25519
        guard let validated = try Self.validatedWebRTCJoinBootstrap(
            payload,
            from: remoteDeviceId,
            expectedAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
            requiresStrictPQC: requiresStrictPQC
        ) else {
            return
        }
        try requireCurrentSessionLifecycleWitness(expectedLifecycleWitness)
        let mutationReceipt = try await KEMTrustStore.shared.upsertAuthorityBoundBootstrap(
            deviceIds: [remoteDeviceId, validated.authority.deviceId],
            kemPublicKeys: validated.kemPublicKeys,
            verifiedProtocolFingerprint: validated.authority.protocolPublicKeyFingerprint
        )
        do {
            try requireCurrentSessionLifecycleWitness(expectedLifecycleWitness)
        } catch {
            do {
                try await KEMTrustStore.shared.rollbackAuthorityBoundMutation(
                    mutationReceipt
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "⛔️ stale WebRTC join bootstrap rollback failed: session=\(Self.protocolIdentityLogRedaction)"
                )
                throw CurrentPathJoinBootstrapError.rollbackFailed
            }
            throw error
        }
        currentPathExpectedRemoteAuthorityBySessionId[sessionId] = validated.authority
        currentPathJoinBootstrapGatesBySessionId[sessionId]?.succeed()
        appendSmokeTrace(
            "join-bootstrap-accepted session=\(sessionId) kemKeys=\(validated.kemPublicKeys.count) authorityBound=1"
        )
    }

    private func awaitRemoteWebRTCJoinBootstrapIfNeeded(sessionId: String) async throws {
        if let authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] {
            let trustedKEM = await trustedCurrentPathKEMPublicKeys(
                for: [authority.deviceId],
                sessionId: sessionId
            )
            if !trustedKEM.isEmpty { return }
        }
        let gate = currentPathJoinBootstrapGatesBySessionId[sessionId]
            ?? CurrentPathJoinBootstrapGate()
        currentPathJoinBootstrapGatesBySessionId[sessionId] = gate
        defer {
            if currentPathJoinBootstrapGatesBySessionId[sessionId] === gate {
                currentPathJoinBootstrapGatesBySessionId.removeValue(forKey: sessionId)
            }
        }
        try await gate.wait(timeoutSeconds: 10)
        guard let authority = currentPathExpectedRemoteAuthorityBySessionId[sessionId] else {
            throw CurrentPathJoinBootstrapError.invalidIdentity
        }
        let trustedKEM = await trustedCurrentPathKEMPublicKeys(
            for: [authority.deviceId],
            sessionId: sessionId
        )
        guard !trustedKEM.isEmpty else {
            throw CurrentPathJoinBootstrapError.missingKEM
        }
    }

    private func startJoinHeartbeat(
        sessionId: String,
        localId: String,
        expectedLifecycleWitness: SessionLifecycleWitness,
        signaling expectedSignaling: WebSocketSignalingClient,
        attempts: Int = CrossNetworkWebRTCManager.webRTCStartupJoinHeartbeatAttempts
    ) {
        stopJoinHeartbeat()
        joinHeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            SkyBridgeLogger.shared.info(
                "🌐 join heartbeat start: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) attempts=\(attempts)"
            )
            var remaining = max(0, attempts)
            while remaining > 0,
                  !Task.isCancelled,
                  self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                  self.signaling === expectedSignaling,
                  self.signalingShardKey == sessionId {
                if self.isTransportEstablished(for: sessionId) {
                    break
                }
                // Re-deliver the strict-PQC identity + KEM bootstrap on every heartbeat so a dropped
                // first join still hands the Mac offerer the KEM it needs to build HandshakeMessageA.
                let heartbeatJoinPayload: WebRTCSignalingEnvelope.Payload
                do {
                    heartbeatJoinPayload = try await self.makeWebRTCJoinBootstrapPayload(
                        sessionId: sessionId
                    )
                } catch {
                    SkyBridgeLogger.shared.error(
                        "⛔️ WebRTC join heartbeat stopped: local authority unavailable: \(Self.diagnosticErrorSummary(error))"
                    )
                    guard self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                          self.signaling === expectedSignaling,
                          self.signalingShardKey == sessionId else { return }
                    await self.failConnectingSessionIfNeeded(
                        sessionId: sessionId,
                        expectedLifecycleWitness: expectedLifecycleWitness,
                        expectedSignaling: expectedSignaling,
                        messageType: .join,
                        reason: "WebRTC join bootstrap material unavailable",
                        trigger: "join_heartbeat_material_unavailable"
                    )
                    return
                }
                guard self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                      self.signaling === expectedSignaling,
                      self.signalingShardKey == sessionId else { return }
                await self.sendEnvelope(
                    WebRTCSignalingEnvelope(sessionId: sessionId, from: localId, type: .join, payload: heartbeatJoinPayload),
                    expectedLifecycleWitness: expectedLifecycleWitness,
                    retries: 2
                )
                guard self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                      self.signaling === expectedSignaling,
                      self.signalingShardKey == sessionId else { return }
                remaining -= 1
                if remaining == 0 { break }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                  self.signaling === expectedSignaling,
                  self.signalingShardKey == sessionId else { return }

            if self.isTransportEstablished(for: sessionId) {
                SkyBridgeLogger.shared.info(
                    "🌐 join heartbeat stop after transport established: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
                )
                return
            }

            let message = "等待远端 offer / answer 超时"
            SkyBridgeLogger.shared.error(
                "❌ join heartbeat exhausted before transportReady: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
            )
            await self.failConnectingSessionIfNeeded(
                sessionId: sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness,
                expectedSignaling: expectedSignaling,
                messageType: .join,
                reason: message,
                trigger: "join_heartbeat_exhausted"
            )
        }
    }

    private func stopOfferResendLoop() {
        offerResendTask?.cancel()
        offerResendTask = nil
    }

    private func resendCachedOfferIfNeeded(
        sessionId: String,
        localId: String,
        reason: String,
        expectedLifecycleWitness: SessionLifecycleWitness
    ) async {
        guard expectedLifecycleWitness.sessionId == sessionId,
              isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else { return }
        guard let sdp = latestLocalOfferBySessionId[sessionId] else { return }
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionId: sessionId, sdp: sdp)
        await sendEnvelope(
            WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .offer,
                payload: WebRTCSignalingEnvelope.Payload(sdp: enrichedSDP)
            ),
            expectedLifecycleWitness: expectedLifecycleWitness,
            retries: 2
        )
        if reason != "periodic",
           isCurrentSessionLifecycleWitness(expectedLifecycleWitness) {
            lastError = nil
        }
    }

    private func startOfferResendLoop(
        sessionId: String,
        localId: String,
        expectedLifecycleWitness: SessionLifecycleWitness,
        signaling expectedSignaling: WebSocketSignalingClient,
        attempts: Int = 40
    ) {
        stopOfferResendLoop()
        offerResendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = max(0, attempts)
            while remaining > 0,
                  !Task.isCancelled,
                  self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                  self.signaling === expectedSignaling,
                  self.signalingShardKey == sessionId {
                if case .connected = self.state { break }
                await self.resendCachedOfferIfNeeded(
                    sessionId: sessionId,
                    localId: localId,
                    reason: "periodic",
                    expectedLifecycleWitness: expectedLifecycleWitness
                )
                guard self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                      self.signaling === expectedSignaling,
                      self.signalingShardKey == sessionId else { return }
                await self.resendCachedLocalICECandidatesIfNeeded(
                    sessionId: sessionId,
                    localId: localId,
                    expectedLifecycleWitness: expectedLifecycleWitness
                )
                guard self.isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
                      self.signaling === expectedSignaling,
                      self.signalingShardKey == sessionId else { return }
                remaining -= 1
                if remaining == 0 { break }
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                } catch {
                    return
                }
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

    private func resendCachedAnswerIfNeeded(
        sessionId: String,
        localId: String,
        expectedLifecycleWitness: SessionLifecycleWitness
    ) async {
        guard expectedLifecycleWitness.sessionId == sessionId,
              isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else { return }
        guard let sdp = latestLocalAnswerBySessionId[sessionId] else { return }
        let enrichedSDP = sdpWithCachedLocalICECandidates(sessionId: sessionId, sdp: sdp)
        let env = WebRTCSignalingEnvelope(
            sessionId: sessionId,
            from: localId,
            type: .answer,
            payload: WebRTCSignalingEnvelope.Payload(sdp: enrichedSDP)
        )
        await sendEnvelope(
            env,
            expectedLifecycleWitness: expectedLifecycleWitness,
            retries: 2
        )
    }

    private func sdpWithCachedLocalICECandidates(sessionId: String, sdp: String) -> String {
        guard let candidates = localICECandidatesBySessionId[sessionId], !candidates.isEmpty else {
            return sdp
        }
        return WebRTCSDPCandidateInjector.injectLocalICECandidates(candidates, into: sdp)
    }

    private func resendCachedLocalICECandidatesIfNeeded(
        sessionId: String,
        localId: String,
        expectedLifecycleWitness: SessionLifecycleWitness
    ) async {
        guard expectedLifecycleWitness.sessionId == sessionId,
              isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else { return }
        guard let candidates = localICECandidatesBySessionId[sessionId], !candidates.isEmpty else { return }
        for payload in candidates {
            let env = WebRTCSignalingEnvelope(
                sessionId: sessionId,
                from: localId,
                type: .iceCandidate,
                payload: payload
            )
            await sendEnvelope(
                env,
                expectedLifecycleWitness: expectedLifecycleWitness,
                retries: 2
            )
            guard isCurrentSessionLifecycleWitness(expectedLifecycleWitness) else { return }
        }
    }

    /// 发送远程桌面消息（鼠标/键盘/屏幕）到 macOS（通过已建立的 WebRTC DataChannel + 会话密钥）
    public func sendRemoteDesktopMessage(_ message: RemoteMessage) async throws {
        guard let session,
              let sessionId = currentSessionId,
              let keys = sessionKeys,
              keys.sessionId == sessionId else {
            throw RemoteDesktopError.disconnected
        }
        guard isApplicationTrafficAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: ObjectIdentifier(session)
        ) else {
            throw ApplicationTrafficAdmissionError.pairingMaterialNotAdmitted
        }
        let data = try JSONEncoder().encode(message)
        let encrypted = try encrypt(plaintext: data, with: keys, packetType: .remoteControl)
        let padded = try TrafficPadding.wrapIfEnabled(encrypted, label: "tx/webrtc-remote")
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

                guard let localIdentitySnapshot = self.localProtocolIdentitySnapshot else {
                    self.appendSmokeTrace(
                        "heartbeat-stopped session=\(sessionId) reason=missing_local_identity"
                    )
                    SkyBridgeLogger.shared.error(
                        "⛔️ WebRTC heartbeat stopped: local protocol identity is unavailable"
                    )
                    break
                }
                let fileTransferReady = FileTransferRuntime.shared.isReady
                let heartbeat = AppMessage.heartbeat(.init(
                    sentAt: Date(),
                    deviceId: localIdentitySnapshot.deviceId,
                    deviceName: localName,
                    modelName: localModel,
                    platform: "iOS",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    chip: nil,
                    accountDisplayName: identity.accountDisplayName,
                    nebulaId: identity.nebulaId,
                    remoteVideoFormats: RemoteDesktopManager.supportedRemoteVideoFormats(),
                    capabilities: fileTransferReady ? ["file_transfer"] : [],
                    fileTransferPort: fileTransferReady ? FileTransferConstants.defaultPort : nil,
                    remoteControlPort: nil,
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
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC heartbeat send failed: \(Self.diagnosticErrorSummary(error))"
                    )
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
#if DEBUG || SKYBRIDGE_TESTING
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] == "ios-client" {
            return true
        }
#endif
        // Identity/capability heartbeat is symmetric. Role-specific media
        // diagnostics remain optional fields inside the authenticated payload.
        return currentRole != nil
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
        _ string: String,
        expectedLifecycleEpoch: UInt64? = nil,
        expectedOperation: PreSessionOperation? = nil
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
        SkyBridgeLogger.shared.info(
            "🌐 QR parse phase=decoded session_ref=\(SkyBridgeDiagnosticReference.stableReference(qr.sessionID)) device_ref=\(SkyBridgeDiagnosticReference.stableReference(qr.deviceID))"
        )
        let canonicalOrigin = try validateCurrentPathOrigin(qr.signalingServerOrigin)
        let verifyResult = try await CrossNetworkQRCodeVerificationPolicy.verify(qr)
        if let expectedOperation {
            try requireActivePreSessionOperation(expectedOperation)
        } else if let expectedLifecycleEpoch {
            try requireSessionLifecycleEpoch(expectedLifecycleEpoch)
        }
        guard verifyResult.ok else {
            let reason = verifyResult.reason ?? "二维码校验失败"
            SkyBridgeLogger.shared.error(
                "❌ iOS QR 校验失败: reason_ref=\(SkyBridgeDiagnosticReference.stableReference(reason))"
            )
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 25,
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }
        SkyBridgeLogger.shared.info(
            "🌐 QR parse phase=verified session_ref=\(SkyBridgeDiagnosticReference.stableReference(qr.sessionID))"
        )
        guard !Self.isP2PKEMBootstrapCapability(qr.normalizedCapabilities) else {
            SkyBridgeLogger.shared.error(
                "❌ QR parse phase=rejected_p2p_kem_bootstrap_removed session_ref=\(SkyBridgeDiagnosticReference.stableReference(qr.sessionID))"
            )
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
        SkyBridgeLogger.shared.info("🌐 QR parse phase=trust_binding_ok session=verified")
        return (qr, canonicalOrigin)
    }

    private func parseSkybridgeConnectLink(
        _ string: String,
        expectedOperation: PreSessionOperation
    ) async throws -> DynamicQRCodeData {
        try requireActivePreSessionOperation(expectedOperation)
        let verified = try await verifyAndPersistSkybridgeConnectLink(
            string,
            expectedOperation: expectedOperation
        )
        try requireActivePreSessionOperation(expectedOperation)
        let qr = verified.qr
        let canonicalOrigin = verified.canonicalOrigin

        if reuseCachedRedeemedSessionArtifactsIfPossible(for: qr, canonicalOrigin: canonicalOrigin) {
            SkyBridgeLogger.shared.info(
                "♻️ 复用已兑换的 QR signaling artifacts: session=<redacted> device=<redacted>"
            )
            SkyBridgeLogger.shared.debug("ℹ️ iOS QR 仅完成内容完整性校验；设备来源认证仍依赖后续握手/pinning")
            return qr
        }
        let localAuthority = try await currentPathLocalAuthority()
        try requireActivePreSessionOperation(expectedOperation)
        let localBinding = localAuthority.binding
        SkyBridgeLogger.shared.info("🌐 QR parse phase=local_binding_ready device=present")
        let admission = try await requestAdmissionLease(for: localAuthority)
        try requireActivePreSessionOperation(expectedOperation)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=admission_ready")
        let redeemed = try await signalServer.redeemSession(
            admissionToken: admission.token,
            sessionId: qr.sessionID,
            qrBootstrapToken: qr.qrBootstrapToken,
            idempotencyKey: "qr-redeem-\(qr.sessionID)-\(localBinding.deviceId)"
        )
        try requireActivePreSessionOperation(expectedOperation)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=redeem_ready session=assigned initiator=present")
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
        currentPathLocalAuthorityBySessionId[qr.sessionID] = localAuthority
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

    /// 尝试把 `skybridge://connect/...` 解码为服务端背书邀请(version>=8)。
    /// 非该形态(经典 QR / 短码 / 版本<8 / 解码失败)时返回 nil，调用方回退到既有路径。
    private func decodeServerBackedConnectLinkIfPresent(_ string: String) -> ServerBackedDynamicQRCodeInvite? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = Self.extractConnectPayloadString(from: trimmed),
              let jsonData = Self.decodeConnectPayload(payload),
              let invite = try? Self.decodeServerBackedQRCodeInvite(from: jsonData),
              invite.version >= 8 else {
            return nil
        }
        return invite
    }

    /// 兑换服务端背书邀请，复用 `connect(withCode:)` 同款 redeem/admission plumbing。
    /// 邀请不携带 PQC 公钥材料；来源认证仍依赖后续握手/pinning。镜像 macOS `scanServerBackedQRCodeInvite`。
    private func redeemServerBackedQRCodeInvite(
        _ invite: ServerBackedDynamicQRCodeInvite,
        expectedOperation: PreSessionOperation
    ) async throws {
        try requireActivePreSessionOperation(expectedOperation)
        guard invite.expiresAt > Date() else { throw ConnectLinkError.expired }
        let canonicalOrigin = try validateCurrentPathOrigin(invite.signalingServerOrigin)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=server_backed_decoded session=verified device=present")

        let rebindSource: CurrentPathRebindSource =
            hasRecentVerifiedQRCodeAuthority(
                deviceId: invite.deviceID,
                protocolPublicKeyFingerprint: invite.protocolPublicKeyFingerprint
            )
            ? .verifiedQRCode
            : .verifiedConnectionCode
        try enforceCurrentPathTrustBinding(
            deviceId: invite.deviceID,
            protocolPublicKeyFingerprint: invite.protocolPublicKeyFingerprint,
            rebindSource: rebindSource
        )

        let localAuthority = try await currentPathLocalAuthority()
        try requireActivePreSessionOperation(expectedOperation)
        let localBinding = localAuthority.binding
        SkyBridgeLogger.shared.info("🌐 QR parse phase=local_binding_ready device=present")
        let admission = try await requestAdmissionLease(for: localAuthority)
        try requireActivePreSessionOperation(expectedOperation)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=admission_ready")
        let redeemed = try await signalServer.redeemSession(
            admissionToken: admission.token,
            sessionId: invite.sessionID,
            qrBootstrapToken: invite.qrBootstrapToken,
            idempotencyKey: "qr-redeem-\(invite.sessionID)-\(localBinding.deviceId)"
        )
        try requireActivePreSessionOperation(expectedOperation)
        SkyBridgeLogger.shared.info("🌐 QR parse phase=redeem_ready session=assigned initiator=present")
        guard redeemed.initiatorDeviceId == invite.deviceID,
              redeemed.initiatorProtocolSigningAlgorithm == invite.protocolSigningAlgorithm,
              redeemed.initiatorProtocolPublicKeyFingerprint == invite.protocolPublicKeyFingerprint else {
            throw ConnectLinkError.invalidSignature
        }
        let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(
            origin: redeemed.signalingServerOrigin,
            wsPath: redeemed.wsPath
        )
        _ = canonicalOrigin
        webrtcSignalingAuthTokenBySessionId[invite.sessionID] = redeemed.sessionToken
        webrtcTurnAdmissionTokenBySessionId[invite.sessionID] = redeemed.turnAdmissionToken
        if let mediaAdmissionToken = redeemed.mediaAdmissionToken {
            webrtcMediaAdmissionTokenBySessionId[invite.sessionID] = mediaAdmissionToken
        }
        setCurrentPathSignalingEndpoint(sessionId: invite.sessionID, endpoint: signalingEndpoint)
        currentPathLocalAuthorityBySessionId[invite.sessionID] = localAuthority
        currentPathExpectedRemoteAuthorityBySessionId[invite.sessionID] = CurrentPathRemoteAuthorityCompat(
            deviceId: invite.deviceID,
            protocolSigningAlgorithm: invite.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: invite.protocolPublicKeyFingerprint,
            protocolPublicKeyBytes: nil,
            deviceName: invite.deviceName
        )
        SkyBridgeLogger.shared.debug("ℹ️ iOS 服务端背书 QR 仅完成 redeem；设备来源认证仍依赖后续握手/pinning")
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
            "🔑 已验证二维码包含 PQC KEM，但不会导入 KEM trust；P2P KEM 恢复必须走 PIB-1 SAS + SKR-1 signed LAN refresh: device_ref=\(SkyBridgeDiagnosticReference.stableReference(qrData.deviceID)) keys=\(kemKeys.count)"
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
        role: WebRTCSession.Role,
        connectionCodeAttemptToken: UUID? = nil,
        sessionBootstrapOperationToken: UUID? = nil
    ) async throws {
        if let sessionBootstrapOperationToken {
            guard activeSessionBootstrapOperation?.token == sessionBootstrapOperationToken else {
                throw CancellationError()
            }
        }
        try await lifecycleGate.waitForTeardownCompletion()
        try Task.checkCancellation()
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
        let preservedLocalAuthority = currentPathLocalAuthorityBySessionId[sessionId]

        if signaling != nil || session != nil || currentSessionId != nil {
            await disconnectInternal(
                clearSnapshot: true,
                preservingConnectionCodeAttemptToken: connectionCodeAttemptToken,
                preservingSessionBootstrapToken: sessionBootstrapOperationToken
            )
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
            if let preservedLocalAuthority {
                currentPathLocalAuthorityBySessionId[sessionId] = preservedLocalAuthority
            }
        }

        try await lifecycleGate.waitForTeardownCompletion()
        try Task.checkCancellation()
        let setupAttempt = beginSessionSetupAttempt(sessionId: sessionId)
        defer {
            if activeSessionSetupAttempt == setupAttempt {
                activeSessionSetupAttempt = nil
            }
        }

        var setupSessionObjectIdentifier: ObjectIdentifier?
        do {
        guard let localAuthority = currentPathLocalAuthorityBySessionId[sessionId] else {
            throw SkyBridgeError.notInitialized
        }
        let currentConfiguration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        let expectedAlgorithm = currentPathLocalProtocolSigningAlgorithm(
            configuration: currentConfiguration
        )
        let expectedProtection = SkyBridgeiOSCore.protocolSigningKeyProtection(
            for: expectedAlgorithm,
            requestedPQCAlgorithm: currentConfiguration.algorithm,
            requestedPQCProtection: currentConfiguration.keyProtection
        )
        guard localAuthority.identity.algorithm == expectedAlgorithm,
              localAuthority.identity.protection == expectedProtection else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Protocol identity configuration changed after the session admission lease was issued"
            )
        }
        let localAlgorithm = localAuthority.identity.algorithm
        try await SkyBridgeiOSCore.shared.initialize(
            policy: localAlgorithm == .ed25519 ? .classicOnly : .requirePQC
        )
        try requireActiveSessionSetupAttempt(setupAttempt)
        let localIdentity = localAuthority.identity
        localProtocolIdentitySnapshot = localIdentity.snapshot

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
            try await ensureSignalingConnected(
                shardKey: sessionId,
                setupAttempt: setupAttempt
            )
            try requireActiveSessionSetupAttempt(setupAttempt)
            SkyBridgeLogger.shared.info(
                "🌐 cross-network phase=signaling_bound session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
            )
        } catch {
            await rollbackFailedSessionSetup(
                sessionId: sessionId,
                expectedSetupAttempt: setupAttempt,
                error: error,
                preservingConnectionCodeAttemptToken: connectionCodeAttemptToken,
                preservingSessionBootstrapToken: sessionBootstrapOperationToken
            )
            throw error
        }
        guard let signaling = self.signaling else {
            let error = WebSocketSignalingClient.SignalingError.notConnected
            await rollbackFailedSessionSetup(
                sessionId: sessionId,
                expectedSetupAttempt: setupAttempt,
                error: error,
                preservingConnectionCodeAttemptToken: connectionCodeAttemptToken,
                preservingSessionBootstrapToken: sessionBootstrapOperationToken
            )
            throw error
        }

        // 2) WebRTC session (offerer / answerer)
        let localId = try requiredLocalProtocolIdentity().deviceId

        // SECURITY: Never hardcode TURN credentials in the client app.
        // A failed short-lived credential lease is a connection failure; it is
        // never disguised as a successful STUN-only session.
        let ice: WebRTCSession.ICEConfig
        do {
            ice = try await CrossNetworkServerConfig.dynamicICEConfig(
                turnAdmissionToken: webrtcTurnAdmissionTokenBySessionId[sessionId]
            )
            try requireActiveSessionSetupAttempt(setupAttempt)
        } catch {
            await rollbackFailedSessionSetup(
                sessionId: sessionId,
                expectedSetupAttempt: setupAttempt,
                error: error,
                preservingConnectionCodeAttemptToken: connectionCodeAttemptToken,
                preservingSessionBootstrapToken: sessionBootstrapOperationToken
            )
            throw error
        }
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
        setupSessionObjectIdentifier = ObjectIdentifier(s)
        self.session = s
        try installSessionIncarnation(
            sessionId: sessionId,
            session: s,
            setupAttempt: setupAttempt
        )
        guard let installedSessionIncarnation = sessionIncarnation(
            sessionId: sessionId,
            sessionObjectIdentifier: ObjectIdentifier(s)
        ) else {
            throw CancellationError()
        }
        let sessionLifecycleWitness = SessionLifecycleWitness.incarnation(
            installedSessionIncarnation
        )
        // 仅 smoke 模式安装 trace 回调：生产环境保持 onTrace == nil，
        // 使 session 内全部 trace 调用点（含每条入站消息）退化为空指针判断，避免高频字符串插值开销。
#if DEBUG || SKYBRIDGE_TESTING
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            s.onTrace = { [weak self] line in
                self?.appendSmokeTrace("webrtc \(line)")
            }
        }
#endif
#if canImport(WebRTC)
        s.onRemoteVideoTrack = { [weak self, weak s] track in
            DispatchQueue.main.async { [weak self, weak s] in
                guard let self, let s,
                      self.currentSessionId == sessionId,
                      self.session === s else { return }
                guard self.isApplicationTrafficAdmitted(
                    sessionId: sessionId,
                    sessionObjectIdentifier: ObjectIdentifier(s)
                ) else {
                    track?.isEnabled = false
                    self.pendingRemoteVideoTrackBeforeAdmission = track
                    return
                }
                self.installRemoteVideoTrack(track)
            }
        }
        s.onRemoteVideoFrameEvidence = { [weak self, weak s] size, source in
            DispatchQueue.main.async { [weak self, weak s] in
                guard let self, let s,
                      self.currentSessionId == sessionId,
                      self.session === s,
                      self.isApplicationTrafficAdmitted(
                        sessionId: sessionId,
                        sessionObjectIdentifier: ObjectIdentifier(s)
                      ) else { return }
                self.noteRemoteVideoTrackRenderedFrame(size, source: source)
            }
        }
        s.onRemoteVideoFirstPacket = { [weak self, weak s] in
            DispatchQueue.main.async { [weak self, weak s] in
                guard let self, let s,
                      self.currentSessionId == sessionId,
                      self.session === s,
                      self.isApplicationTrafficAdmitted(
                        sessionId: sessionId,
                        sessionObjectIdentifier: ObjectIdentifier(s)
                      ) else { return }
                self.noteRemoteVideoTrackReceivedFirstPacket(source: "receiver-first-packet")
            }
        }
        if nativeAudioReceiveEnabled {
            s.onRemoteAudioFirstPacket = { [weak self, weak s] in
                DispatchQueue.main.async { [weak self, weak s] in
                    guard let self, let s,
                          self.currentSessionId == sessionId,
                          self.session === s,
                          self.isApplicationTrafficAdmitted(
                            sessionId: sessionId,
                            sessionObjectIdentifier: ObjectIdentifier(s)
                          ) else { return }
                    self.noteRemoteAudioTrackReceivedFirstPacket(source: "receiver-first-packet")
                }
            }
        }
#endif

        s.onLocalOffer = { [weak self, weak s] (sdp: String) in
            Task { @MainActor [weak self, weak s] in
                guard let self, let s,
                      self.session === s,
                      self.isCurrentSessionLifecycleWitness(sessionLifecycleWitness) else { return }
                self.latestLocalOfferBySessionId[sessionId] = sdp
                self.appendSmokeTrace("local-offer session=\(sessionId) \(CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp))")
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .offer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(
                    env,
                    expectedLifecycleWitness: sessionLifecycleWitness,
                    retries: 2
                )
            }
        }

        s.onLocalAnswer = { [weak self, weak s] (sdp: String) in
            Task { @MainActor [weak self, weak s] in
                guard let self, let s,
                      self.session === s,
                      self.isCurrentSessionLifecycleWitness(sessionLifecycleWitness) else { return }
                self.latestLocalAnswerBySessionId[sessionId] = sdp
                self.appendSmokeTrace("local-answer session=\(sessionId) \(CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp))")
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .answer,
                    payload: WebRTCSignalingEnvelope.Payload(sdp: sdp)
                )
                await self.sendEnvelope(
                    env,
                    expectedLifecycleWitness: sessionLifecycleWitness,
                    retries: 2
                )
            }
        }

        s.onLocalICECandidate = { [weak self, weak s] (payload: WebRTCSignalingEnvelope.Payload) in
            Task { @MainActor [weak self, weak s] in
                guard let self, let s,
                      self.session === s,
                      self.isCurrentSessionLifecycleWitness(sessionLifecycleWitness) else { return }
                let candidateKind = CrossNetworkWebRTCTraceDescription.describeCandidateKind(payload.candidate)
                self.cacheLocalICECandidate(payload, for: sessionId)
                self.appendSmokeTrace("local-ice session=\(sessionId) kind=\(candidateKind) mid=\(payload.sdpMid ?? "-") index=\(payload.sdpMLineIndex ?? -1)")
                let env = WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .iceCandidate,
                    payload: payload
                )
                await self.sendEnvelope(
                    env,
                    expectedLifecycleWitness: sessionLifecycleWitness,
                    retries: 1
                )
            }
        }

        // Inbound frames from DataChannel
        let inbound = InboundChunkQueue()
        let screenInbound = InboundChunkQueue()
        let orderedInboundRelay = OrderedInboundChunkRelay()
        let orderedScreenInboundRelay = OrderedInboundChunkRelay()
        self.inboundQueue = inbound
        self.screenInboundQueue = screenInbound
        s.onData = { [weak self, weak s] data in
            guard self != nil, let s else { return }
            guard WebRTCFramedPayloadPolicy.isValidPayloadByteCount(data.count) else {
                Task { await inbound.failOverflow() }
                return
            }
            let accepted = orderedInboundRelay.submit(byteCount: data.count) { [weak self, weak s] in
                guard let self, let s else { return }
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
#if DEBUG || SKYBRIDGE_TESTING
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        print("🧪 WebRTC rekey rx chunk bytes=\(data.count)")
                    }
#endif
                }
                switch await inbound.push(data) {
                case .accepted, .closed:
                    break
                case .overflow:
                    await MainActor.run {
                        self.appendSmokeTrace(
                            "control-channel inbound chunk rejected bytes=\(data.count) reason=chunk_limit"
                        )
                    }
                }
            }
            if !accepted {
                Task { await inbound.failOverflow() }
            }
        }
        s.onScreenData = { [weak self, weak s] data in
            guard self != nil, let s else { return }
            guard WebRTCFramedPayloadPolicy.isValidPayloadByteCount(data.count) else {
                Task { await screenInbound.failOverflow() }
                return
            }
            let accepted = orderedScreenInboundRelay.submit(byteCount: data.count) { [weak self, weak s] in
                guard let self, let s else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }
                switch await screenInbound.push(data) {
                case .accepted, .closed:
                    break
                case .overflow:
                    await MainActor.run {
                        self.appendSmokeTrace(
                            "screen-channel inbound chunk rejected bytes=\(data.count) reason=chunk_limit"
                        )
                    }
                }
            }
            if !accepted {
                Task { await screenInbound.failOverflow() }
            }
        }

        s.onDisconnected = { [weak self, weak s] reason in
            Task {
                guard let self, let s else { return }
                let isCurrentSession = await MainActor.run {
                    self.currentSessionId == sessionId && self.session === s
                }
                guard isCurrentSession else { return }
                let msg = "WebRTC 传输已断开: \(reason)"
                await MainActor.run {
                    self.appendSmokeTrace("transport-disconnected session=\(sessionId) reason=\(reason)")
                    self.lastError = msg
                }
                await self.terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    expectedSessionObjectIdentifier: ObjectIdentifier(s),
                    disconnectKind: .transient,
                    notificationKind: .interrupted,
                    reason: "transport_disconnected:\(reason)",
                    terminalFailureMessage: msg,
                    clearSnapshot: false
                )
            }
        }

        s.onReady = { [weak self, weak s] in
            Task {
                guard let self, let s else { return }
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
                    SkyBridgeLogger.shared.info(
                        "✅ WebRTC transport ready: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), role=\(String(describing: role))"
                    )

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
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ skip duplicate WebRTC handshake start: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
                    )
                }
            }
        }

        do {
            try await s.startAsync()
            try Task.checkCancellation()
            guard currentSessionId == sessionId, session === s else {
                throw CancellationError()
            }
        } catch {
            await rollbackFailedSessionSetup(
                sessionId: sessionId,
                expectedSession: s,
                expectedSetupAttempt: setupAttempt,
                error: error,
                preservingConnectionCodeAttemptToken: connectionCodeAttemptToken,
                preservingSessionBootstrapToken: sessionBootstrapOperationToken
            )
            throw error
        }
        SkyBridgeLogger.shared.info(
            "🌐 cross-network phase=session_started session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) role=\(role == .offerer ? "offerer" : "answerer")"
        )
        appendSmokeTrace("session-started session=\(sessionId) role=\(role == .offerer ? "offerer" : "answerer")")
        let signalingDrainWitness = sessionLifecycleWitness
        await drainPendingPreSessionSignalingEnvelopes(
            sessionId: sessionId,
            expectedSetupAttempt: setupAttempt,
            expectedLifecycleWitness: signalingDrainWitness
        )
        try requireCurrentSessionLifecycleWitness(signalingDrainWitness)
        try requireActiveSessionSetupAttempt(setupAttempt)
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: ObjectIdentifier(s)
        ) else {
            throw CancellationError()
        }

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

        // 3) Join room + heartbeat to mask websocket timing jitters. Carry this device's protocol
        // identity + strict-PQC KEM public keys so the Mac offerer can ingest the bootstrap and build
        // HandshakeMessageA (previously sent with payload: nil → offerer never got the KEM → handshake_failed).
        let joinPayload = try await makeWebRTCJoinBootstrapPayload(sessionId: sessionId)
        try requireActiveSessionSetupAttempt(setupAttempt)
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: ObjectIdentifier(s)
        ) else {
            throw CancellationError()
        }
        do {
            let joinOutcome = try await sendRequiredSetupEnvelope(
                WebRTCSignalingEnvelope(
                    sessionId: sessionId,
                    from: localId,
                    type: .join,
                    payload: joinPayload
                ),
                expectedLifecycleWitness: sessionLifecycleWitness,
                retries: 2
            )
            try requireCurrentSessionLifecycleWitness(sessionLifecycleWitness)
            if joinOutcome == .sent {
                try requireActiveSessionSetupAttempt(setupAttempt)
                guard isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: ObjectIdentifier(s)
                ) else {
                    throw CancellationError()
                }
            } else {
                appendSmokeTrace(
                    "join-send-superseded session=\(sessionId) reason=handshake-complete"
                )
            }
        } catch {
            let completedHandshakeOwnsSession = isCurrentSessionLifecycleWitness(
                sessionLifecycleWitness
            ) && isHandshakeComplete(for: sessionId)
            if completedHandshakeOwnsSession {
                appendSmokeTrace(
                    "join-send-failure-superseded session=\(sessionId) reason=handshake-complete"
                )
                if error is CancellationError {
                    throw error
                }
            } else {
                await rollbackFailedSessionSetup(
                    sessionId: sessionId,
                    expectedSession: s,
                    expectedSetupAttempt: setupAttempt,
                    error: error,
                    preservingConnectionCodeAttemptToken: connectionCodeAttemptToken,
                    preservingSessionBootstrapToken: sessionBootstrapOperationToken
                )
                throw error
            }
        }
        SkyBridgeLogger.shared.info(
            "🌐 cross-network phase=join_sent session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) bootstrap=\(joinPayload.kemPublicKeys?.count ?? 0)"
        )
        startJoinHeartbeat(
            sessionId: sessionId,
            localId: localId,
            expectedLifecycleWitness: sessionLifecycleWitness,
            signaling: signaling
        )
        if role == .offerer {
            startOfferResendLoop(
                sessionId: sessionId,
                localId: localId,
                expectedLifecycleWitness: sessionLifecycleWitness,
                signaling: signaling
            )
        }
        } catch {
            let ownsSetupAttempt = activeSessionSetupAttempt == setupAttempt
            let exactSetupSessionIsCurrent: Bool
            if let setupSessionObjectIdentifier, let session {
                exactSetupSessionIsCurrent = ObjectIdentifier(session) == setupSessionObjectIdentifier
            } else {
                exactSetupSessionIsCurrent = false
            }
            let completedHandshakeOwnsSession = ownsSetupAttempt
                && currentSessionId == sessionId
                && exactSetupSessionIsCurrent
                && isHandshakeComplete(for: sessionId)
            if completedHandshakeOwnsSession {
                appendSmokeTrace(
                    "late-setup-failure-superseded session=\(sessionId) reason=handshake-complete"
                )
                return
            }
            if ownsSetupAttempt && !completedHandshakeOwnsSession {
                await rollbackFailedSessionSetup(
                    sessionId: sessionId,
                    expectedSetupAttempt: setupAttempt,
                    error: error,
                    preservingConnectionCodeAttemptToken: connectionCodeAttemptToken,
                    preservingSessionBootstrapToken: sessionBootstrapOperationToken
                )
            }
            guard ownsSetupAttempt else {
                throw CancellationError()
            }
            throw error
        }
    }

    private func handleEnvelopeIfCurrent(
        _ env: WebRTCSignalingEnvelope,
        signaling expectedSignaling: WebSocketSignalingClient
    ) async {
        guard signaling === expectedSignaling,
              signalingShardKey == env.sessionId else { return }
        guard let envelopeLifecycleWitness = currentSessionLifecycleWitness(
            sessionId: env.sessionId
        ) else { return }
        await handleEnvelope(
            env,
            expectedLifecycleWitness: envelopeLifecycleWitness,
            expectedSignaling: expectedSignaling
        )
    }

    private func handleEnvelope(
        _ env: WebRTCSignalingEnvelope,
        expectedLifecycleWitness envelopeLifecycleWitness: SessionLifecycleWitness,
        expectedSignaling: WebSocketSignalingClient
    ) async {
        guard env.sessionId == envelopeLifecycleWitness.sessionId,
              isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
              signaling === expectedSignaling,
              signalingShardKey == env.sessionId else {
            return
        }

        guard let localId = localProtocolIdentitySnapshot?.deviceId else {
            let message = "local protocol identity unavailable while handling signaling"
            SkyBridgeLogger.shared.error("⛔️ \(message)")
            await failConnectingSessionIfNeeded(
                sessionId: env.sessionId,
                expectedLifecycleWitness: envelopeLifecycleWitness,
                expectedSignaling: expectedSignaling,
                messageType: env.type,
                reason: message,
                trigger: "signaling_receive_missing_local_identity"
            )
            return
        }
        // Ignore self-echo
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
                guard let session else {
                    await enqueuePreSessionSignalingEnvelope(
                        env,
                        expectedLifecycleWitness: envelopeLifecycleWitness,
                        expectedSignaling: expectedSignaling
                    )
                    return
                }
                session.setRemoteOffer(sdp)
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                      self.signaling === expectedSignaling,
                      self.signalingShardKey == env.sessionId else {
                    return
                }
                await self.resendCachedAnswerIfNeeded(
                    sessionId: env.sessionId,
                    localId: localId,
                    expectedLifecycleWitness: envelopeLifecycleWitness
                )
                guard self.isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                      self.signaling === expectedSignaling,
                      self.signalingShardKey == env.sessionId else { return }
                await self.resendCachedLocalICECandidatesIfNeeded(
                    sessionId: env.sessionId,
                    localId: localId,
                    expectedLifecycleWitness: envelopeLifecycleWitness
                )
            }
        case .answer:
            stopOfferResendLoop()
            if let sdp = env.payload?.sdp {
                appendSmokeTrace("remote-answer session=\(env.sessionId) \(CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp))")
                guard let session else {
                    await enqueuePreSessionSignalingEnvelope(
                        env,
                        expectedLifecycleWitness: envelopeLifecycleWitness,
                        expectedSignaling: expectedSignaling
                    )
                    return
                }
                session.setRemoteAnswer(sdp)
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                      self.signaling === expectedSignaling,
                      self.signalingShardKey == env.sessionId else {
                    return
                }
                await self.resendCachedLocalICECandidatesIfNeeded(
                    sessionId: env.sessionId,
                    localId: localId,
                    expectedLifecycleWitness: envelopeLifecycleWitness
                )
            }
        case .iceCandidate:
            if let p = env.payload, let c = p.candidate {
                appendSmokeTrace(
                    "remote-ice session=\(env.sessionId) kind=\(CrossNetworkWebRTCTraceDescription.describeCandidateKind(p.candidate)) mid=\(p.sdpMid ?? "-") index=\(p.sdpMLineIndex ?? -1)"
                )
                guard let session else {
                    await enqueuePreSessionSignalingEnvelope(
                        env,
                        expectedLifecycleWitness: envelopeLifecycleWitness,
                        expectedSignaling: expectedSignaling
                    )
                    return
                }
                session.addRemoteICECandidate(candidate: c, sdpMid: p.sdpMid, sdpMLineIndex: p.sdpMLineIndex)
            }
        case .join:
            appendSmokeTrace("remote-join session=\(env.sessionId) from=\(env.from)")
            do {
                try requireCurrentSessionLifecycleWitness(envelopeLifecycleWitness)
                try await ingestWebRTCJoinBootstrapPayload(
                    env.payload,
                    from: env.from,
                    sessionId: env.sessionId,
                    expectedLifecycleWitness: envelopeLifecycleWitness
                )
            } catch {
                guard isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                      signaling === expectedSignaling,
                      signalingShardKey == env.sessionId else {
                    return
                }
                currentPathJoinBootstrapGatesBySessionId[env.sessionId]?.fail(error)
                let message = "WebRTC join bootstrap rejected: \(error.localizedDescription)"
                lastError = message
                SkyBridgeLogger.shared.error(
                    "⛔️ WebRTC join bootstrap rejected: session=\(Self.protocolIdentityLogRedaction)"
                )
                switch envelopeLifecycleWitness {
                case .incarnation(let incarnation):
                    await terminateRemoteDesktopSession(
                        sessionId: env.sessionId,
                        expectedSessionObjectIdentifier: incarnation.sessionObjectIdentifier,
                        disconnectKind: .explicit,
                        notificationKind: .interrupted,
                        reason: "join_bootstrap_rejected",
                        terminalFailureMessage: message
                    )
                case .setup(let envelopeSetupAttempt):
                    await disconnectInternal(
                        clearSnapshot: true,
                        preservingConnectionCodeAttemptToken: nil,
                        terminalFailureMessage: message,
                        expectedSetupAttempt: envelopeSetupAttempt
                    )
                }
                return
            }
            guard isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                  signaling === expectedSignaling,
                  signalingShardKey == env.sessionId else { return }
            if currentRole == .offerer, let sid = currentSessionId, sid == env.sessionId {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                          self.signaling === expectedSignaling,
                          self.signalingShardKey == env.sessionId else {
                        return
                    }
                    await self.resendCachedOfferIfNeeded(
                        sessionId: sid,
                        localId: localId,
                        reason: "remote-join",
                        expectedLifecycleWitness: envelopeLifecycleWitness
                    )
                    guard self.isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                          self.signaling === expectedSignaling,
                          self.signalingShardKey == env.sessionId else { return }
                    await self.resendCachedAnswerIfNeeded(
                        sessionId: sid,
                        localId: localId,
                        expectedLifecycleWitness: envelopeLifecycleWitness
                    )
                    guard self.isCurrentSessionLifecycleWitness(envelopeLifecycleWitness),
                          self.signaling === expectedSignaling,
                          self.signalingShardKey == env.sessionId else { return }
                    await self.resendCachedLocalICECandidatesIfNeeded(
                        sessionId: sid,
                        localId: localId,
                        expectedLifecycleWitness: envelopeLifecycleWitness
                    )
                }
            }
        case .leave:
            stopJoinHeartbeat()
            stopOfferResendLoop()
            appendSmokeTrace("remote-leave session=\(env.sessionId) from=\(env.from)")
            let sessionId = env.sessionId
            guard isCurrentSessionLifecycleWitness(envelopeLifecycleWitness) else { return }
            switch envelopeLifecycleWitness {
            case .incarnation(let incarnation):
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    expectedSessionObjectIdentifier: incarnation.sessionObjectIdentifier,
                    disconnectKind: .remoteLeave,
                    notificationKind: .normal,
                    reason: "remote_leave",
                    terminalFailureMessage: nil
                )
            case .setup(let envelopeSetupAttempt):
                await disconnectInternal(
                    clearSnapshot: false,
                    preservingConnectionCodeAttemptToken: nil,
                    expectedSetupAttempt: envelopeSetupAttempt
                )
            }
        }
    }

    private func enqueuePreSessionSignalingEnvelope(
        _ env: WebRTCSignalingEnvelope,
        expectedLifecycleWitness: SessionLifecycleWitness,
        expectedSignaling: WebSocketSignalingClient
    ) async {
        guard isPreSessionSignalingEnvelope(env),
              env.sessionId == expectedLifecycleWitness.sessionId,
              isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
              signaling === expectedSignaling,
              signalingShardKey == env.sessionId else {
            return
        }

        var pending = pendingPreSessionSignalingEnvelopesBySessionId[env.sessionId] ?? []
        guard pending.count < Self.maxPendingPreSessionSignalingEnvelopes else {
            let message = "pre-session signaling queue overflow"
            appendSmokeTrace("pre-session-drop session=\(env.sessionId) type=\(env.type.rawValue) reason=queue-overflow max=\(Self.maxPendingPreSessionSignalingEnvelopes)")
            SkyBridgeLogger.shared.error(
                "⛔️ \(message): session_ref=\(SkyBridgeDiagnosticReference.stableReference(env.sessionId)) type=\(env.type.rawValue)"
            )
            await failConnectingSessionIfNeeded(
                sessionId: env.sessionId,
                expectedLifecycleWitness: expectedLifecycleWitness,
                expectedSignaling: expectedSignaling,
                messageType: env.type,
                reason: message,
                trigger: "pre_session_signaling_queue_overflow"
            )
            return
        }

        pending.append(
            PendingPreSessionSignalingEnvelope(
                envelope: env,
                lifecycleWitness: expectedLifecycleWitness,
                sourceSignaling: expectedSignaling
            )
        )
        pendingPreSessionSignalingEnvelopesBySessionId[env.sessionId] = pending
        appendSmokeTrace("pre-session-queued session=\(env.sessionId) type=\(env.type.rawValue) pending=\(pending.count)")
    }

    private func drainPendingPreSessionSignalingEnvelopes(
        sessionId: String,
        expectedSetupAttempt: SessionSetupAttempt,
        expectedLifecycleWitness: SessionLifecycleWitness
    ) async {
        guard expectedSetupAttempt.sessionId == sessionId,
              activeSessionSetupAttempt == expectedSetupAttempt,
              expectedLifecycleWitness.sessionId == sessionId,
              isCurrentSessionLifecycleWitness(expectedLifecycleWitness),
              let pending = pendingPreSessionSignalingEnvelopesBySessionId.removeValue(
                forKey: sessionId
              ) else {
            return
        }
        let ownedEnvelopes = pending.compactMap { pendingEnvelope in
            let belongsToExpectedLifecycle =
                pendingEnvelope.lifecycleWitness == .setup(expectedSetupAttempt)
                || pendingEnvelope.lifecycleWitness == expectedLifecycleWitness
            let sourceIsCurrent = signaling === pendingEnvelope.sourceSignaling
                && signalingShardKey == sessionId
            return belongsToExpectedLifecycle && sourceIsCurrent
                ? pendingEnvelope
                : nil
        }
        guard !ownedEnvelopes.isEmpty else { return }

        appendSmokeTrace("pre-session-drain session=\(sessionId) count=\(ownedEnvelopes.count)")
        await CrossNetworkSignalingEnvelopeDrain.run(
            ownedEnvelopes,
            expectedOwner: expectedLifecycleWitness,
            expectedSessionID: sessionId,
            envelopeSessionID: { $0.envelope.sessionId },
            currentOwner: { [weak self] in
                self?.currentSessionLifecycleWitness(sessionId: sessionId)
            },
            handle: { [weak self] pendingEnvelope, witness in
                await self?.handleEnvelope(
                    pendingEnvelope.envelope,
                    expectedLifecycleWitness: witness,
                    expectedSignaling: pendingEnvelope.sourceSignaling
                )
            }
        )
    }

    private func isPreSessionSignalingEnvelope(_ env: WebRTCSignalingEnvelope) -> Bool {
        switch env.type {
        case .offer, .answer, .iceCandidate:
            return true
        case .join, .leave:
            return false
        }
    }
}

// MARK: - WebRTC framed handshake (iOS)

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    private func clearPeerKEMKeysForClassicRetry(
        deviceId: String,
        expectedIncarnation: SessionIncarnation
    ) async throws {
        guard isCurrentSessionIncarnation(expectedIncarnation) else {
            throw CancellationError()
        }
        let mutationReceipt = try await KEMTrustStore.shared.clearWithReceipt(
            deviceId: deviceId
        )
        guard isCurrentSessionIncarnation(expectedIncarnation),
              !Task.isCancelled else {
            do {
                try await KEMTrustStore.shared.rollbackAuthorityBoundMutation(
                    mutationReceipt
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "⛔️ stale WebRTC KEM clear rollback failed: session=\(Self.protocolIdentityLogRedaction)"
                )
                throw error
            }
            throw CancellationError()
        }
    }

    func startHandshakeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        inbound: InboundChunkQueue,
        shouldInitiate: Bool
    ) async {
        let sessionObjectIdentifier = ObjectIdentifier(session)
        guard let handshakeIncarnation = sessionIncarnation(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else { return }
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
                    "🤝 WebRTC 等待对端发起初始握手: session=\(Self.protocolIdentityLogRedaction), role=\(String(describing: session.role)), strictPQC=\(strictPQCRequested)"
                )
                return
            }

            if strictPQCRequested {
                try await awaitRemoteWebRTCJoinBootstrapIfNeeded(sessionId: sessionId)
                guard isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else { return }
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
                    "⛔️ \(message): session=\(Self.protocolIdentityLogRedaction), peer=\(Self.protocolIdentityLogRedaction)"
                )
                throw NSError(
                    domain: "CrossNetworkWebRTCManager",
                    code: -1206,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            var trustedPeerKEMKeys: [CryptoSuite: Data] = [:]
            for candidate in peerIdCandidates {
                let keys: [CryptoSuite: Data]
                if currentPathExpectedRemoteAuthorityBySessionId[sessionId] != nil {
                    keys = await trustedCurrentPathKEMPublicKeys(
                        for: [candidate],
                        sessionId: sessionId
                    )
                } else {
                    keys = await KEMTrustStore.shared.kemPublicKeys(for: candidate)
                }
                guard isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else { return }
                guard !keys.isEmpty else { continue }
                trustedPeerKEMKeys = keys
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
                "🤝 WebRTC handshake bootstrap: session=\(Self.protocolIdentityLogRedaction), policy=\(selection.rawValue), " +
                "compatMode=\(compatibilityModeEnabled), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs), " +
                "peer=\(Self.protocolIdentityLogRedaction), trustedKEM=\(hasTrustedPeerKEMKey), trustPeer=\(Self.protocolIdentityLogRedaction), authorityBootstrap=\(useClassicAuthorityBootstrap)"
            )
            let transport = makeHandshakeTransport(over: session)
            var attemptedInitialHandshakeDriver: HandshakeDriver?

            func attemptInitialHandshake(
                selection: CryptoProviderFactory.SelectionPolicy,
                bootstrapMode: String
            ) async throws -> (
                keys: SessionKeys,
                binding: AuthenticatedHandshakePeerBinding,
                driver: HandshakeDriver
            ) {
                try await SkyBridgeiOSCore.shared.initialize(policy: selection)
                guard self.isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else { throw CancellationError() }
                let stablePeerId = self.currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId
                    ?? peerDeviceId
                let signingAlgorithm: ProtocolSigningAlgorithm
                let exactMLDSA87PublicKey: Data?
                if selection == .classicOnly {
                    signingAlgorithm = .ed25519
                    exactMLDSA87PublicKey = nil
                } else {
                    let sessionMLDSA87PublicKey = try self
                        .sessionAuthenticatedMLDSA87PublicKey(for: sessionId)
                    exactMLDSA87PublicKey = try SkyBridgeiOSCore.shared
                        .resolvedCurrentPathMLDSA87PublicKey(
                            for: stablePeerId,
                            sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey
                        )
                    signingAlgorithm = try SkyBridgeiOSCore.shared.currentPathPQCSignatureAlgorithm(
                        for: stablePeerId,
                        sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey,
                        requestedPQCAlgorithm: try self.sessionRequestedPQCAlgorithm(
                            sessionId: sessionId
                        )
                    )
                }
                let currentPathTrustProvider = CurrentPathHandshakeTrustProviderCompat(
                    expectedRemoteAuthority: self.currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                    fallbackPeerIDs: peerIdCandidates,
                    additionalTrustedFingerprints: self.handshakeTrustedProtocolFingerprints(
                        for: sessionId,
                        candidateDeviceIds: peerIdCandidates
                    ),
                    exactMLDSA87PublicKey: exactMLDSA87PublicKey
                )
                let driver = try await SkyBridgeiOSCore.shared.createHandshakeDriver(
                    transport: transport,
                    trustProvider: currentPathTrustProvider,
                    protocolSigningAlgorithm: signingAlgorithm,
                    protocolSigningKeyProtection: try self.sessionProtocolSigningKeyProtection(
                        for: signingAlgorithm,
                        sessionId: sessionId
                    )
                )
                guard self.isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ), self.handshakeDriver == nil else { throw CancellationError() }
                attemptedInitialHandshakeDriver = driver
                self.handshakeDriver = driver
                SkyBridgeLogger.shared.info(
                    "🤝 WebRTC initiating handshake: session=\(Self.protocolIdentityLogRedaction), peer=\(Self.protocolIdentityLogRedaction), mode=\(bootstrapMode), policy=\(selection.rawValue)"
                )
                let keys = try await driver.initiateHandshake(with: peer)
                guard self.isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ), self.handshakeDriver === driver else { throw CancellationError() }
                guard let binding = await driver.getAuthenticatedHandshakePeerBinding() else {
                    throw CurrentPathAuthorityCommitError.missingAuthenticatedRemoteAuthority
                }
                guard self.isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ), self.handshakeDriver === driver else { throw CancellationError() }
                return (keys, binding, driver)
            }

            let establishedHandshake: (
                keys: SessionKeys,
                binding: AuthenticatedHandshakePeerBinding,
                driver: HandshakeDriver
            )
            do {
                establishedHandshake = try await attemptInitialHandshake(
                    selection: selection,
                    bootstrapMode: bootstrapPlan.bootstrapMode
                )
            } catch {
                guard self.isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else { return }
                if let attemptedInitialHandshakeDriver,
                   self.handshakeDriver === attemptedInitialHandshakeDriver {
                    self.handshakeDriver = nil
                }
                if !strictPQCRequested,
                   hasTrustedPeerKEMKey,
                   selection != .classicOnly,
                   CrossNetworkWebRTCPQCHandshakePolicy.shouldRetryClassicBootstrap(after: error) {
                    for candidate in peerIdCandidates {
                        try await self.clearPeerKEMKeysForClassicRetry(
                            deviceId: candidate,
                            expectedIncarnation: handshakeIncarnation
                        )
                    }
                    self.appendSmokeTrace("bootstrap retry classic peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peerDeviceId))")
                    SkyBridgeLogger.shared.warning(
                        "⚠️ WebRTC trusted KEM bootstrap failed; cleared cached peer KEM keys and retrying classic bootstrap. " +
                        "session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peerDeviceId)), \(Self.diagnosticErrorSummary(error))"
                    )
                    establishedHandshake = try await attemptInitialHandshake(
                        selection: .classicOnly,
                        bootstrapMode: "classic_retry_after_stale_kem"
                    )
                } else {
                    throw error
                }
            }

            guard self.isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), self.handshakeDriver === establishedHandshake.driver else {
                self.appendSmokeTrace("drop stale handshake-complete session=\(sessionId)")
                return
            }

            try self.persistCurrentPathTrust(
                sessionId: sessionId,
                authenticatedRemoteAuthority: establishedHandshake.binding.authority
            )
            self.authenticatedHandshakePeerBindingBySessionId[sessionId] =
                establishedHandshake.binding
            let keys = establishedHandshake.keys
            self.sessionKeys = keys
            self.handshakeDriver = nil
            if self.currentSessionId == sessionId {
                // The cryptographic handshake authenticates the transport, but
                // application readiness remains withheld until the current
                // session incarnation durably commits the remote pairing
                // material and sends its reciprocal identity reply.
                self.noteRemoteAppActivity(sessionId: sessionId)
                self.startRemotePeerPingLoop(sessionId: sessionId, session: session)
                self.startRemotePeerLivenessWatchdog(sessionId: sessionId, session: session)
                self.updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .transportReady,
                    deviceId: self.remoteDeviceId,
                    deviceName: self.remoteDeviceName
                )
            }
            guard self.isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return }
            SkyBridgeLogger.shared.info(
                "✅ WebRTC 握手认证完成，等待配对材料准入: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) suite=\(keys.negotiatedSuite.rawValue)"
            )

            do {
                _ = try await sendPairingIdentityExchangeOverWebRTC(
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId,
                    session: session,
                    force: true
                )
            } catch {
                guard self.isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else { return }
                SkyBridgeLogger.shared.warning(
                    "⚠️ WebRTC pairingIdentityExchange send failed: session=\(Self.protocolIdentityLogRedaction) peer=\(Self.protocolIdentityLogRedaction) \(Self.diagnosticErrorSummary(error))"
                )
            }

            guard self.isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return }

            await maybeStartPQCRekeyOverWebRTC(
                sessionId: sessionId,
                peerDeviceId: peerDeviceId,
                session: session,
                strictPQCRequested: strictPQCRequested,
                trigger: "post_bootstrap"
            )
        } catch {
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return }
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
            SkyBridgeLogger.shared.error(
                "❌ WebRTC 握手失败（DataChannel） session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) \(Self.diagnosticErrorSummary(error))"
            )
            let terminalError = NSError(
                domain: "SkyBridge.WebRTCHandshake",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "WebRTC 握手失败: \(reason)"]
            )
            await rollbackFailedSessionSetup(
                sessionId: sessionId,
                expectedSession: session,
                error: terminalError
            )
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
        let tunedHandshake = try HandshakePadding.wrapIfEnabled(
            rawHandshake,
            label: "tx/webrtc",
            maximumPaddingTargetByteCount: CrossNetworkWebRTCHandshakeLimits.maxPaddedPayloadBytes
        )
#if DEBUG || SKYBRIDGE_TESTING
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
#endif
        do {
            try await session.sendFramedPayloadAsync(
                tunedHandshake,
                maxChunkBytes: CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes,
                maxBufferedAmountBytes: CrossNetworkWebRTCHandshakeLimits.maxBufferedAmountBytes
            )
#if DEBUG || SKYBRIDGE_TESTING
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                appendSmokeTrace("tx handshake-sent raw=\(rawHandshake.count) padded=\(tunedHandshake.count)")
            }
#endif
        } catch {
#if DEBUG || SKYBRIDGE_TESTING
            if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                appendSmokeTrace(
                    "tx handshake-send-failed raw=\(rawHandshake.count) padded=\(tunedHandshake.count) error=\(CrossNetworkWebRTCTraceDescription.smokeTraceToken(error.localizedDescription))"
                )
            }
#endif
            throw error
        }
    }

    private func makeHandshakeTransport(
        over session: WebRTCSession
    ) -> CurrentPathWebRTCHandshakeTransportCompat {
        CurrentPathWebRTCHandshakeTransportCompat(
            sendFramed: { [weak self] data in
                guard let self else { throw RemoteDesktopError.disconnected }
                try await self.sendHandshakeFrameOverWebRTC(data, over: session)
            }
        )
    }

    private func ensureInboundPQCRekeyDriverIfNeeded(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        frame: Data,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> HandshakeDriver? {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else { return nil }
        if inboundRekeyResponderSessionIds.contains(sessionId) {
            return handshakeDriver
        }
        guard handshakeDriver == nil else { return nil }
        guard sessionKeys != nil else { return nil }
        guard isPairingMaterialAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else { return nil }
        guard let messageA = try? HandshakeMessageA.decode(from: frame),
              !messageA.supportedSuites.isEmpty else {
            return nil
        }
        // A valid inbound MessageA makes this side the responder. Cancel only
        // the outbound operation token; its defer cannot clear responder state.
        activeOutboundRekeyOperationToken = nil
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
                "⛔️ inbound WebRTC rekey selection rejected peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peer.deviceId)) hasApplePQC=\(localCapability.hasApplePQC), hasLiboqs=\(localCapability.hasLiboqs)"
            )
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    message: message,
                    originatingReceiveLoop: .control
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
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return nil }
            appendSmokeTrace("inbound-rekey core-ready session=\(sessionId)")
            let stablePeerId = currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId
                ?? remoteDeviceId
                ?? handshakePeerId
                ?? peer.deviceId
            let sessionMLDSA87PublicKey = try sessionAuthenticatedMLDSA87PublicKey(
                for: sessionId
            )
            let exactMLDSA87PublicKey = try SkyBridgeiOSCore.shared
                .resolvedCurrentPathMLDSA87PublicKey(
                    for: stablePeerId,
                    sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey
                )
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: fallbackPeerIDs,
                additionalTrustedFingerprints: handshakeTrustedProtocolFingerprints(
                    for: sessionId,
                    candidateDeviceIds: fallbackPeerIDs
                ),
                exactMLDSA87PublicKey: exactMLDSA87PublicKey
            )
            let signingAlgorithm = try SkyBridgeiOSCore.shared
                .validatedIncomingProtocolSigningAlgorithm(
                    messageA: messageA,
                    stableDeviceId: stablePeerId,
                    sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey,
                    requestedPQCAlgorithm: try sessionRequestedPQCAlgorithm(
                        sessionId: sessionId
                    )
                )
            let driver = try await SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: makeHandshakeTransport(over: session),
                peerSupportedSuites: messageA.supportedSuites,
                trustProvider: trustProvider,
                protocolSigningAlgorithm: signingAlgorithm,
                protocolSigningKeyProtection: try sessionProtocolSigningKeyProtection(
                    for: signingAlgorithm,
                    sessionId: sessionId
                )
            )
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver == nil else { return nil }
            handshakeDriver = driver
            appendSmokeTrace("inbound-rekey driver-ready session=\(sessionId)")
        } catch {
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return nil }
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey driver 初始化失败: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), \(Self.diagnosticErrorSummary(error))"
            )
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    message: "strictPQC WebRTC inbound rekey driver init failed: \(error.localizedDescription)",
                    originatingReceiveLoop: .control
                )
            }
            return nil
        }

        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), let installedDriver = handshakeDriver else { return nil }
        inboundRekeyResponderSessionIds.insert(sessionId)
        rekeyInProgressSessionIds.insert(sessionId)
        lastRekeyEvent = "received peer=\(peer.deviceId)"
        SkyBridgeLogger.shared.info(
            "🔁 收到对端 WebRTC rekey 请求，切换 responder: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peer.deviceId)), suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return installedDriver
    }

    private func ensureInboundInitialHandshakeDriverIfNeeded(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        frame: Data,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> HandshakeDriver? {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else { return nil }
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
                "⛔️ inbound WebRTC initial handshake selection rejected peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peer.deviceId)) hasApplePQC=\(localCapability.hasApplePQC), hasLiboqs=\(localCapability.hasLiboqs)"
            )
            if strictPQCRequested {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    message: message,
                    originatingReceiveLoop: .control
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
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return nil }
            let stablePeerId = currentPathExpectedRemoteAuthorityBySessionId[sessionId]?.deviceId
                ?? remoteDeviceId
                ?? handshakePeerId
                ?? peer.deviceId
            let sessionMLDSA87PublicKey = try sessionAuthenticatedMLDSA87PublicKey(
                for: sessionId
            )
            let exactMLDSA87PublicKey = try SkyBridgeiOSCore.shared
                .resolvedCurrentPathMLDSA87PublicKey(
                    for: stablePeerId,
                    sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey
                )
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: fallbackPeerIDs,
                additionalTrustedFingerprints: handshakeTrustedProtocolFingerprints(
                    for: sessionId,
                    candidateDeviceIds: fallbackPeerIDs
                ),
                exactMLDSA87PublicKey: exactMLDSA87PublicKey
            )
            let signingAlgorithm = try SkyBridgeiOSCore.shared
                .validatedIncomingProtocolSigningAlgorithm(
                    messageA: messageA,
                    stableDeviceId: stablePeerId,
                    sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey,
                    requestedPQCAlgorithm: try sessionRequestedPQCAlgorithm(
                        sessionId: sessionId
                    )
                )
            let driver = try await SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: makeHandshakeTransport(over: session),
                peerSupportedSuites: messageA.supportedSuites,
                trustProvider: trustProvider,
                protocolSigningAlgorithm: signingAlgorithm,
                protocolSigningKeyProtection: try sessionProtocolSigningKeyProtection(
                    for: signingAlgorithm,
                    sessionId: sessionId
                )
            )
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver == nil else { return nil }
            handshakeDriver = driver
        } catch {
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return nil }
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC 初始握手驱动初始化失败: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), \(Self.diagnosticErrorSummary(error))"
            )
            if strictPQCRequested {
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    message: "strictPQC WebRTC inbound initial handshake driver init failed: \(error.localizedDescription)",
                    originatingReceiveLoop: .control
                )
            }
            return nil
        }

        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), let installedDriver = handshakeDriver else { return nil }
        inboundInitialHandshakeResponderSessionIds.insert(sessionId)
        if allowsClassicAuthorityBootstrap {
            inboundClassicAuthorityBootstrapSessionIds.insert(sessionId)
            SkyBridgeLogger.shared.info(
                "🤝 WebRTC 入站初始握手允许 current-path authority classic bootstrap: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peer.deviceId))"
            )
        }
        SkyBridgeLogger.shared.info(
            "🤝 收到对端 WebRTC 初始握手请求，切换 responder: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peer.deviceId)), suites=\(messageA.supportedSuites.map(\.rawValue).joined(separator: ","))"
        )
        return installedDriver
    }

    private func failStrictPQCBootstrapSession(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        message: String,
        originatingReceiveLoop: ReceiveLoopTaskKind? = nil
    ) async {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else { return }
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
        await terminateRemoteDesktopSession(
            sessionId: sessionId,
            expectedSessionObjectIdentifier: sessionObjectIdentifier,
            disconnectKind: .explicit,
            notificationKind: .interrupted,
            reason: "strict_pqc_bootstrap_failed",
            terminalFailureMessage: message,
            clearSnapshot: false,
            originatingReceiveLoop: originatingReceiveLoop,
        )
    }

    private func syncInboundPQCRekeyState(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        strictPQCRequested: Bool
    ) async {
        guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
              ),
              inboundRekeyResponderSessionIds.contains(sessionId),
              let driver = handshakeDriver else {
            return
        }

        let currentState = await driver.getCurrentState()
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), handshakeDriver === driver else { return }
        switch currentState {
        case .established(let keys):
            let evidenceAttemptSnapshot = await driver
                .productConnectivityAttemptSnapshot()
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver === driver else { return }
            if strictPQCRequested,
               !CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeyNegotiatedSuiteAllowed(
                    keys.negotiatedSuite,
                    strictPQCRequested: strictPQCRequested
               ) {
                let message =
                    "strictPQC WebRTC 入站 rekey 协商到了 Classic suite=\(keys.negotiatedSuite.rawValue)，当前关闭 classic bootstrap-only 会话。"
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
                )
                await failStrictPQCBootstrapSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    message: message,
                    originatingReceiveLoop: .control
                )
                return
            }
            guard let authenticatedBinding = await driver
                .getAuthenticatedHandshakePeerBinding() else {
                await failCurrentPathAuthorityCommit(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    stage: "inbound-rekey",
                    error: CurrentPathAuthorityCommitError.missingAuthenticatedRemoteAuthority,
                    originatingReceiveLoop: .control
                )
                return
            }
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver === driver else { return }
            do {
                try persistCurrentPathTrust(
                    sessionId: sessionId,
                    authenticatedRemoteAuthority: authenticatedBinding.authority
                )
            } catch {
                await failCurrentPathAuthorityCommit(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    stage: "inbound-rekey",
                    error: error,
                    originatingReceiveLoop: .control
                )
                return
            }
            authenticatedHandshakePeerBindingBySessionId[sessionId] = authenticatedBinding
            sessionKeys = keys
            inboundRekeyResponderSessionIds.remove(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            rekeyCompletedSessionIds.insert(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
            lastRekeyEvent = "complete suite=\(keys.negotiatedSuite.rawValue)"

            if isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), let activeSession = self.session,
               ObjectIdentifier(activeSession) == sessionObjectIdentifier {
                let didPublish = publishApplicationReadyIfCurrent(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    keys: keys,
                    session: activeSession
                )
                if didPublish {
                    await sendLocalAuthenticatedRouteBindings(
                        keys: keys,
                        sessionId: sessionId,
                        session: activeSession,
                        stage: "inbound-rekey"
                    )
                }
            }
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver === driver,
               let activeSession = self.session,
               ObjectIdentifier(activeSession) == sessionObjectIdentifier else { return }
            await publishWebRTCProductEvidenceIfCurrent(
                sessionId: sessionId,
                session: activeSession,
                keys: keys,
                driver: driver,
                attemptSnapshot: evidenceAttemptSnapshot
            )
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver === driver else { return }
            handshakeDriver = nil
            let rekeyCompletionEvent = keys.negotiatedSuite.isPQCGroup
                ? "pqcRekeyComplete"
                : "classicRekeyComplete"
            let rekeyCompletionLabel = keys.negotiatedSuite.isPQCGroup
                ? "PQC"
                : "classic compatibility"
            SkyBridgeLogger.shared.info(
                "✅ inbound WebRTC \(rekeyCompletionLabel) rekey 完成: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=\(rekeyCompletionEvent) suite=\(keys.negotiatedSuite.rawValue)"
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
                    "⛔️ strictPQC WebRTC rekey failed after classic bootstrap: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyFailed \(Self.diagnosticErrorSummary(reason))"
                )
                lastError = message
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    expectedSessionObjectIdentifier: sessionObjectIdentifier,
                    disconnectKind: .explicit,
                    notificationKind: .interrupted,
                    reason: "strict_pqc_rekey_failed:\(reason)",
                    terminalFailureMessage: message,
                    originatingReceiveLoop: .control
                )
                return
            }
            SkyBridgeLogger.shared.warning(
                "⚠️ inbound WebRTC rekey 失败，保留既有会话: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyFailed \(Self.diagnosticErrorSummary(reason))"
            )

        default:
            break
        }
    }

    private func syncInboundInitialHandshakeState(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        strictPQCRequested: Bool
    ) async {
        guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
              ),
              inboundInitialHandshakeResponderSessionIds.contains(sessionId),
              let driver = handshakeDriver else {
            return
        }

        let currentState = await driver.getCurrentState()
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), handshakeDriver === driver else { return }
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
                SkyBridgeLogger.shared.error(
                    "⛔️ \(message) session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
                )
                lastError = message
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    expectedSessionObjectIdentifier: sessionObjectIdentifier,
                    disconnectKind: .explicit,
                    notificationKind: .interrupted,
                    reason: "initial_handshake_failed:\(keys.negotiatedSuite.rawValue)",
                    terminalFailureMessage: message,
                    originatingReceiveLoop: .control
                )
                return
            }

            guard let authenticatedBinding = await driver
                .getAuthenticatedHandshakePeerBinding() else {
                await failCurrentPathAuthorityCommit(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    stage: "inbound-initial",
                    error: CurrentPathAuthorityCommitError.missingAuthenticatedRemoteAuthority,
                    originatingReceiveLoop: .control
                )
                return
            }
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver === driver else { return }
            do {
                try persistCurrentPathTrust(
                    sessionId: sessionId,
                    authenticatedRemoteAuthority: authenticatedBinding.authority
                )
            } catch {
                await failCurrentPathAuthorityCommit(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    stage: "inbound-initial",
                    error: error,
                    originatingReceiveLoop: .control
                )
                return
            }
            authenticatedHandshakePeerBindingBySessionId[sessionId] = authenticatedBinding
            sessionKeys = keys
            handshakeDriver = nil
            inboundInitialHandshakeResponderSessionIds.remove(sessionId)
            inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
            if strictPQCRequested,
               allowsClassicAuthorityBootstrap,
               !keys.negotiatedSuite.isPQCGroup {
                noteRemoteAppActivity(sessionId: sessionId)
                lastRekeyEvent = "bootstrapOnly suite=\(keys.negotiatedSuite.rawValue)"
                if let activeSession = self.session {
                    markStrictPQCClassicBootstrapOnly(sessionId: sessionId, session: activeSession)
                } else {
                    strictPQCClassicBootstrapOnlySessionIds.insert(sessionId)
                }
                SkyBridgeLogger.shared.warning(
                    "⏳ inbound WebRTC strictPQC classic authority bootstrap is bootstrap-only: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyPending suite=\(keys.negotiatedSuite.rawValue)"
                )
                if isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ), let activeSession = self.session,
                   ObjectIdentifier(activeSession) == sessionObjectIdentifier {
                    do {
                        _ = try await sendPairingIdentityExchangeOverWebRTC(
                            sessionId: sessionId,
                            peerDeviceId: remoteDeviceId ?? handshakePeerId ?? sessionId,
                            session: activeSession,
                            force: true
                        )
                    } catch {
                        guard isCurrentSession(
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        ) else { return }
                        SkyBridgeLogger.shared.warning(
                            "⚠️ inbound WebRTC strictPQC bootstrap pairingIdentityExchange send failed: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), \(Self.diagnosticErrorSummary(error))"
                        )
                    }
                }
                if isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ), let activeSession = self.session,
                   ObjectIdentifier(activeSession) == sessionObjectIdentifier {
                    startRemotePeerLivenessWatchdog(sessionId: sessionId, session: activeSession)
                }
                return
            }
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)

            if isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) {
                // Keep the authenticated transport provisional until the
                // authority-bound pairing material is durably committed and
                // reciprocally acknowledged by this exact session instance.
                noteRemoteAppActivity(sessionId: sessionId)
                if let activeSession = self.session {
                    startRemotePeerPingLoop(sessionId: sessionId, session: activeSession)
                    startRemotePeerLivenessWatchdog(sessionId: sessionId, session: activeSession)
                }
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .transportReady,
                    deviceId: remoteDeviceId,
                    deviceName: remoteDeviceName
                )
            }
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return }
            SkyBridgeLogger.shared.info(
                "✅ inbound WebRTC 初始握手认证完成，等待配对材料准入: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), suite=\(keys.negotiatedSuite.rawValue)"
            )

        case .failed(let reason):
            handshakeDriver = nil
            inboundInitialHandshakeResponderSessionIds.remove(sessionId)
            inboundClassicAuthorityBootstrapSessionIds.remove(sessionId)
            let message = "WebRTC 握手失败: \(reason)"
            SkyBridgeLogger.shared.error(
                "❌ inbound WebRTC 初始握手失败: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), \(Self.diagnosticErrorSummary(reason))"
            )
            lastError = message
            await terminateRemoteDesktopSession(
                sessionId: sessionId,
                expectedSessionObjectIdentifier: sessionObjectIdentifier,
                disconnectKind: .explicit,
                notificationKind: .interrupted,
                reason: "initial_handshake_failed:\(reason)",
                terminalFailureMessage: message,
                originatingReceiveLoop: .control
            )

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
        let sessionObjectIdentifier = ObjectIdentifier(session)
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            throw RemoteDesktopError.disconnected
        }
        guard Self.isPairingAdmissionBootstrapMessage(message)
                || isApplicationTrafficAdmitted(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else {
            throw ApplicationTrafficAdmissionError.pairingMaterialNotAdmitted
        }
        guard let keys = sessionKeys,
              keys.sessionId == sessionId else {
            throw RemoteDesktopError.disconnected
        }
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encrypt(plaintext: payload, with: keys, packetType: .appControl)
        let padded = try TrafficPadding.wrapIfEnabled(ciphertext, label: label)
        try await sendFramed(padded, over: session)
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            throw RemoteDesktopError.disconnected
        }
    }

    private func sendPairingIdentityFramedBounded(
        _ data: Data,
        over session: WebRTCSession
    ) async throws {
        let gate = NetworkContentProcessedGate()
        let taskOwner = NetworkContentProcessedTaskOwner()
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard gate.claimSubmission() else {
                    try await gate.wait(
                        timeoutSeconds: Self.pairingIdentityNetworkSubmitTimeoutSeconds,
                        operation: "pairing-identity",
                        transport: "WebRTC",
                        resolvingTaskCancellation: false
                    )
                    return
                }
                let submitTask = Task { @MainActor [weak self, weak session] in
                    guard let self, let session else {
                        gate.finish(.failure(RemoteDesktopError.disconnected))
                        return
                    }
                    do {
                        try await self.sendFramed(data, over: session)
                        gate.finish(.success(()))
                    } catch {
                        gate.finish(.failure(error))
                    }
                }
                taskOwner.install(submitTask)
                try await gate.wait(
                    timeoutSeconds: Self.pairingIdentityNetworkSubmitTimeoutSeconds,
                    operation: "pairing-identity",
                    transport: "WebRTC",
                    resolvingTaskCancellation: false
                )
            } onCancel: { [weak session] in
                guard let submissionClaimed = gate.cancelSubmission(),
                      submissionClaimed,
                      taskOwner.cancel() else { return }
                Task { @MainActor in
                    session?.close()
                }
            }
        } catch {
            if gate.submissionWasClaimed, taskOwner.cancel() {
                session.close()
            }
            throw error
        }
    }

    private func sendPairingIdentityExchangeOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        force: Bool = false,
        acceptedMaterialDigest: Data? = nil,
        beforeNetworkSubmit: () async throws -> Void = {}
    ) async throws -> PairingIdentitySendOutcome {
        let sessionObjectIdentifier = ObjectIdentifier(session)
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            if acceptedMaterialDigest != nil {
                return .contentProcessedButSuperseded
            }
            throw RemoteDesktopError.disconnected
        }
        let now = Date()
        if !force, PairingMaterialAdmissionPolicy.canReusePairingIdentityReply(
            lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId],
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier,
            acceptedMaterialDigest: acceptedMaterialDigest,
            now: now,
            reuseInterval: 10
        ) {
            try await beforeNetworkSubmit()
            return .contentProcessedCurrent
        }

        let kemKeys = KEMPublicKeyInfo.normalizedValidKeys(
            try await P2PKEMIdentityKeyStore.shared.getOrCreateBootstrapPublicKeys()
        )
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            if acceptedMaterialDigest != nil {
                return .contentProcessedButSuperseded
            }
            throw RemoteDesktopError.disconnected
        }
        guard !kemKeys.isEmpty else {
            throw P2PError.pairingIdentityExchangeUnavailable(
                reason: "本机 KEM 公钥为空"
            )
        }
        let localDeviceId = try requiredLocalProtocolIdentity().deviceId
        let localIdentity = AppleMobileDeviceIdentity.currentSnapshot()

        let message = AppMessage.pairingIdentityExchange(.init(
            deviceId: localDeviceId,
            kemPublicKeys: kemKeys,
            protocolIdentityPublicKeys: try await localProtocolIdentityPublicKeysForPairing(
                sessionId: sessionId
            ),
            deviceName: localIdentity.deviceName,
            modelName: localIdentity.modelName,
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: nil,
            remoteVideoFormats: RemoteDesktopManager.supportedRemoteVideoFormats()
        ))
        guard let keys = sessionKeys, keys.sessionId == sessionId else {
            if acceptedMaterialDigest != nil,
               !isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
               ) {
                return .contentProcessedButSuperseded
            }
            throw RemoteDesktopError.disconnected
        }
        let payload = try JSONEncoder().encode(message)
        let ciphertext = try encrypt(
            plaintext: payload,
            with: keys,
            packetType: .appControl
        )
        let padded = try TrafficPadding.wrapIfEnabled(
            ciphertext,
            label: "tx/webrtc-bootstrap"
        )
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), sessionKeys?.sessionId == sessionId else {
            if acceptedMaterialDigest != nil {
                return .contentProcessedButSuperseded
            }
            throw RemoteDesktopError.disconnected
        }
        // Local key/material preparation is complete. Resolve and release the
        // durable acceptance transaction immediately before the bounded
        // network submission; send failure after this point retains after-state.
        try await beforeNetworkSubmit()
        do {
            try await sendPairingIdentityFramedBounded(padded, over: session)
        } catch {
            guard acceptedMaterialDigest != nil,
                  !isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                  ) else {
                throw error
            }
            return .contentProcessedButSuperseded
        }
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ), sessionKeys?.sessionId == sessionId else {
            return .contentProcessedButSuperseded
        }
        lastPairingIdentityExchangeSentAtByPeerId[peerDeviceId] =
            PairingIdentityReplyObservation(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier,
                acceptedMaterialDigest: acceptedMaterialDigest,
                sentAt: now
            )
        SkyBridgeLogger.shared.info(
            "📤 WebRTC pairingIdentityExchange sent: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peerDeviceId)), keys=\(kemKeys.count)"
        )
        return .contentProcessedCurrent
    }

    private func validatedWebRTCPairingIdentityAuthority(
        payload: AppMessage.PairingIdentityExchangePayload,
        sessionId: String,
        peerDeviceId: String
    ) throws -> ValidatedPairingIdentityAuthority {
        guard sessionKeys?.sessionId == sessionId,
            let expectedAuthority = currentPathExpectedRemoteAuthorityBySessionId[sessionId],
            let sessionBinding = authenticatedHandshakePeerBindingBySessionId[sessionId],
            let algorithm = ProtocolSigningAlgorithm(
                rawValue: sessionBinding.authority.protocolSigningAlgorithm
            ),
            let authenticatedPublicKey = sessionBinding.authority.protocolPublicKeyBytes
        else {
            throw PairingIdentityAuthorityValidationError.missingSessionAuthority
        }

        let pibApproval = TrustedDeviceStore.shared.exactActivePIBOperatorApproval(
            forDeclaredDeviceId: payload.deviceId,
            algorithm: algorithm
        )
        let currentPathApproval: CurrentPathOperatorApprovalReceipt? = {
            guard authorityBoundWebRTCBootstrapSessionIds.contains(sessionId),
                expectedAuthority.deviceId == payload.deviceId,
                expectedAuthority.protocolSigningAlgorithm == algorithm,
                expectedAuthority.protocolPublicKeyFingerprint.lowercased()
                    == sessionBinding.authority.protocolPublicKeyFingerprint.lowercased(),
                expectedAuthority.protocolPublicKeyBytes == authenticatedPublicKey
            else {
                return nil
            }
            return CurrentPathOperatorApprovalReceipt(
                declaredDeviceId: expectedAuthority.deviceId,
                protocolSigningAlgorithm: algorithm,
                protocolPublicKeyFingerprint:
                    sessionBinding.authority.protocolPublicKeyFingerprint,
                protocolPublicKey: authenticatedPublicKey
            )
        }()
        return try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: payload,
            sessionBinding: sessionBinding,
            sessionDeviceIds: [expectedAuthority.deviceId, peerDeviceId],
            operatorApproval: pibApproval,
            currentPathApproval: currentPathApproval
        )
    }

    private func authenticatedConversationFingerprint(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) throws -> String {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ),
              sessionKeys?.sessionId == sessionId,
              let expected = currentPathExpectedRemoteAuthorityBySessionId[sessionId],
              let binding = authenticatedHandshakePeerBindingBySessionId[sessionId],
              let algorithm = ProtocolSigningAlgorithm(
                  rawValue: binding.authority.protocolSigningAlgorithm
              ),
              let publicKey = binding.authority.protocolPublicKeyBytes,
              expected.protocolSigningAlgorithm == algorithm,
              expected.protocolPublicKeyBytes == publicKey,
              let fingerprint = try? DeviceTextMessagePolicy
                .normalizedConversationFingerprint(
                    binding.authority.protocolPublicKeyFingerprint
                ),
              fingerprint == expected.protocolPublicKeyFingerprint.lowercased(),
              AppMessage.ProtocolIdentityPublicKeyInfo(
                  protocolSigningAlgorithm: algorithm.rawValue,
                  publicKey: publicKey
              ).authoritativeFingerprint == fingerprint else {
            throw P2PError.authenticatedIdentityMismatch
        }
        return fingerprint
    }

    func handleInboundAppMessageOverWebRTC(
        _ message: AppMessage,
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> Bool {
        let applicationTrafficAdmitted = isApplicationTrafficAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        )
        if !applicationTrafficAdmitted,
           !Self.isPairingAdmissionBootstrapMessage(message) {
            appendSmokeTrace(
                "pairing-admission drop app-control session=\(sessionId) type=\(Self.bootstrapAppMessageKind(message))"
            )
            return true
        }

        switch message {
        case .pairingIdentityExchange(let payload):
            do {
                guard isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else {
                    throw RemoteDesktopError.disconnected
                }
                let validatedAuthority = try validatedWebRTCPairingIdentityAuthority(
                    payload: payload,
                    sessionId: sessionId,
                    peerDeviceId: peerDeviceId
                )
                let acceptedMaterialDigest = try PairingIdentityAcceptedMaterialDigest.compute(
                    payload: payload,
                    authority: validatedAuthority
                )
                let acceptanceHandle = try await PairingAcceptancePersistence.begin(
                    payload: payload,
                    authority: validatedAuthority,
                    canonicalAcceptanceKey: validatedAuthority.declaredDeviceId,
                    acceptedMaterialDigest: acceptedMaterialDigest,
                    trustedDevicePreparation: { _ in nil },
                    pairingPolicyPersistedValue: nil,
                    policyParticipant: P2PConnectionManager.instance
                ) {
                    guard self.isCurrentSession(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ), self.sessionKeys?.sessionId == sessionId else {
                        throw RemoteDesktopError.disconnected
                    }
                }
                var acceptanceFinalized = false
                do {
                    let sendOutcome = try await sendPairingIdentityExchangeOverWebRTC(
                        sessionId: sessionId,
                        peerDeviceId: peerDeviceId,
                        session: session,
                        force: false,
                        acceptedMaterialDigest: acceptedMaterialDigest,
                        beforeNetworkSubmit: {
                            try await PairingAcceptancePersistence
                                .markReplyMayBeVisible(acceptanceHandle) {
                                    // begin already validated the exact current
                                    // incarnation. Later supersession retains the
                                    // accepted durable material.
                                }
                            // This call removes the journal and releases the
                            // global permit in defer before network submission.
                            acceptanceFinalized = true
                            try await PairingAcceptancePersistence
                                .completeAfterReplyMayBeVisible(
                                    acceptanceHandle,
                                    policyParticipant: P2PConnectionManager.instance
                                )
                        }
                    )
                    guard sendOutcome == .contentProcessedCurrent else {
                        if !acceptanceFinalized {
                            try await PairingAcceptancePersistence
                                .markReplyMayBeVisible(acceptanceHandle) {}
                            acceptanceFinalized = true
                            try await PairingAcceptancePersistence
                                .completeAfterReplyMayBeVisible(
                                    acceptanceHandle,
                                    policyParticipant: P2PConnectionManager.instance
                                )
                        }
                        SkyBridgeLogger.shared.info(
                            "✅ WebRTC pairing authority commit retained after the replying session was superseded; stale presentation was suppressed"
                        )
                        return true
                    }
                    guard isCurrentSession(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ), sessionKeys?.sessionId == sessionId else {
                        throw RemoteDesktopError.disconnected
                    }
                    guard installPairingMaterialAdmissionIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier,
                        acceptedMaterialDigest: acceptedMaterialDigest
                    ) else {
                        throw RemoteDesktopError.disconnected
                    }
                } catch {
                    let downstreamError = error
                    let replyWasPossiblyVisible = PairingAcceptancePersistence
                        .replyMayBeVisible(acceptanceHandle)
                    if !acceptanceFinalized {
                        if replyWasPossiblyVisible {
                            acceptanceFinalized = true
                            try await PairingAcceptancePersistence
                                .completeAfterReplyMayBeVisible(
                                    acceptanceHandle,
                                    policyParticipant: P2PConnectionManager.instance
                                )
                        } else {
                            try await PairingAcceptancePersistence
                                .abortBeforeReplyVisibility(
                                    acceptanceHandle,
                                    policyParticipant: P2PConnectionManager.instance
                                )
                        }
                        acceptanceFinalized = true
                    }
                    guard isCurrentSession(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ) else {
                        if replyWasPossiblyVisible || acceptanceFinalized {
                            SkyBridgeLogger.shared.info(
                                "✅ WebRTC pairing acceptance resolved after the replying session was superseded; stale failure was suppressed"
                            )
                        }
                        return true
                    }
                    throw downstreamError
                }

                // Only an authority-validated payload may replace presentation
                // aliases, and it becomes visible only after the reply succeeds.
                remoteDeviceId = validatedAuthority.declaredDeviceId
                handshakePeerId = validatedAuthority.declaredDeviceId
                if let acceptedDeviceName = payload.deviceName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !acceptedDeviceName.isEmpty {
                    remoteDeviceName = acceptedDeviceName
                }
                updatePreparedSessionSnapshot(
                    sessionId: sessionId,
                    phase: .transportReady,
                    deviceId: validatedAuthority.declaredDeviceId,
                    deviceName: remoteDeviceName
                )
                noteRemoteAppActivity(sessionId: sessionId)
                if let keys = sessionKeys, keys.sessionId == sessionId {
                    let didPublish = publishApplicationReadyIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier,
                        keys: keys,
                        session: session
                    )
                    if didPublish {
                        await sendLocalAuthenticatedRouteBindings(
                            keys: keys,
                            sessionId: sessionId,
                            session: session,
                            stage: "pairing-material-admission"
                        )
                    }
                }
                SkyBridgeLogger.shared.info(
                    "🔑 WebRTC authority-bound bootstrap committed: peer_ref=\(SkyBridgeDiagnosticReference.stableReference(peerDeviceId)), declared_ref=\(SkyBridgeDiagnosticReference.stableReference(validatedAuthority.declaredDeviceId)), keys=\(payload.kemPublicKeys.count)"
                )
            } catch {
                guard isCurrentSession(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                ) else {
                    return true
                }
                let diagnosticError = error as NSError
                let message = "WebRTC 配对身份验证失败，请重新连接"
                lastError = message
                SkyBridgeLogger.shared.error(
                    "⛔️ WebRTC pairing identity authority commit/reply failed; closing session: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    expectedSessionObjectIdentifier: sessionObjectIdentifier,
                    disconnectKind: .explicit,
                    notificationKind: .interrupted,
                    reason: "pairing_identity_authority_failed",
                    terminalFailureMessage: message,
                    originatingReceiveLoop: .control
                )
                return true
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
             .protocolIdentityBindingRequest, .signedProtocolIdentityBinding,
             .protocolIdentityBindingConfirm, .signedProtocolIdentityBindingFinalAck:
            break
        case .textMessage(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            do {
                let fingerprint = try authenticatedConversationFingerprint(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                )
                try await DeviceMessagingService.shared.handleIncoming(
                    payload,
                    conversationFingerprint: fingerprint
                )
                if let deliveryAttemptID = payload.deliveryAttemptID {
                    try await sendAppMessageOverWebRTC(
                        .textMessageReceipt(.init(
                            messageID: payload.id,
                            deliveryAttemptID: deliveryAttemptID
                        )),
                        sessionId: sessionId,
                        session: session,
                        label: "tx/webrtc-text-receipt"
                    )
                }
                SkyBridgeLogger.shared.info(
                    "📨 WebRTC textMessage received: session=\(Self.protocolIdentityLogRedaction), peer=\(Self.protocolIdentityLogRedaction), message_ref=\(SkyBridgeDiagnosticReference.stableReference(payload.id.uuidString))"
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "⛔️ WebRTC textMessage not persisted: session=\(Self.protocolIdentityLogRedaction), peer=\(Self.protocolIdentityLogRedaction), message_ref=\(SkyBridgeDiagnosticReference.stableReference(payload.id.uuidString)), reason=\(DeviceMessagingService.logSafeErrorSummary(error))"
                )
            }
        case .textMessageReceipt(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            do {
                let fingerprint = try authenticatedConversationFingerprint(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier
                )
                try await DeviceMessagingService.shared.handleAuthenticatedReceipt(
                    payload,
                    conversationFingerprint: fingerprint
                )
            } catch {
                SkyBridgeLogger.shared.error(
                    "⛔️ WebRTC text receipt binding failed; closing authenticated session"
                )
                await failAuthenticatedWebRTCChannel(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    reason: "authenticated_text_receipt_failed",
                    originatingReceiveLoop: .control
                )
                return false
            }
        case .heartbeat(let payload):
            noteRemoteAppActivity(sessionId: sessionId)
            guard applicationTrafficAdmitted else {
                // Before admission heartbeat is liveness-only. In particular,
                // unauthoritative display names and capability/route metadata
                // must not become observable state.
                return true
            }
            // The heartbeat is session-authenticated but payload.deviceId is not
            // identity authority. The SOA/PIB-validated pairing exchange is the
            // only app-message path allowed to replace the remote device ID.
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
        case .authenticatedRouteBinding:
            noteRemoteAppActivity(sessionId: sessionId)
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
                let diagnosticError = error as NSError
                SkyBridgeLogger.shared.error(
                    "⛔️ WebRTC authenticated pong reply failed; closing session: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
                await failAuthenticatedWebRTCChannel(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    reason: "authenticated_pong_reply_failed",
                    originatingReceiveLoop: .control
                )
                return false
            }
        case .pong:
            noteRemoteAppActivity(sessionId: sessionId)
        case .clipboard:
            noteRemoteAppActivity(sessionId: sessionId)
        }
        return true
    }

    func maybeStartPQCRekeyOverWebRTC(
        sessionId: String,
        peerDeviceId: String,
        session: WebRTCSession,
        strictPQCRequested: Bool,
        trigger: String
    ) async {
        let expectedSessionObjectIdentifier = ObjectIdentifier(session)
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: expectedSessionObjectIdentifier
        ) else { return }
        guard strictPQCRequested else { return }
        guard isPairingMaterialAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: expectedSessionObjectIdentifier
        ) else { return }
        guard let establishedKeys = sessionKeys,
              establishedKeys.sessionId == sessionId else {
            return
        }
        guard !establishedKeys.negotiatedSuite.isPQCGroup else { return }
        guard !rekeyInProgressSessionIds.contains(sessionId) else { return }
        guard !rekeyCompletedSessionIds.contains(sessionId) else { return }
        guard handshakeDriver == nil else { return }

        let rekeyOperationToken = UUID()
        activeOutboundRekeyOperationToken = rekeyOperationToken
        rekeyInProgressSessionIds.insert(sessionId)
        var operationDriver: HandshakeDriver?
        defer {
            if activeOutboundRekeyOperationToken == rekeyOperationToken {
                activeOutboundRekeyOperationToken = nil
                rekeyInProgressSessionIds.remove(sessionId)
                if let operationDriver, handshakeDriver === operationDriver {
                    handshakeDriver = nil
                }
            }
        }

        func isCurrentRekeyOperation() -> Bool {
            isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: expectedSessionObjectIdentifier
            ) && activeOutboundRekeyOperationToken == rekeyOperationToken
        }

        func failStrictClassicBootstrap(reason: String, diagnostic: String) async {
            guard isCurrentRekeyOperation(),
                  strictPQCRequested,
                  sessionKeys?.negotiatedSuite.isPQCGroup != true else { return }
            let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(diagnostic)"
            lastRekeyEvent = "failed strict reason=\(reason)"
            SkyBridgeLogger.shared.error(
                "⛔️ strictPQC WebRTC rekey failed after classic bootstrap: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyFailed trigger=\(trigger) reason=\(reason)"
            )
            lastError = message
            if let operationDriver, handshakeDriver === operationDriver {
                handshakeDriver = nil
            }
            rekeyCompletedSessionIds.remove(sessionId)
            await terminateRemoteDesktopSession(
                sessionId: sessionId,
                expectedSessionObjectIdentifier: expectedSessionObjectIdentifier,
                disconnectKind: .explicit,
                notificationKind: .interrupted,
                reason: "strict_pqc_rekey_failed:\(reason)",
                terminalFailureMessage: message
            )
        }
        let hasPeerKEMEvidence = trigger != "post_bootstrap"
        guard let localDeviceId = localProtocolIdentitySnapshot?.deviceId else {
            await failStrictClassicBootstrap(
                reason: "missing_local_identity",
                diagnostic: "local protocol identity snapshot is unavailable"
            )
            return
        }

        guard let electionRemoteDeviceId = resolvedPQCRekeyElectionRemoteDeviceId(
            sessionId: sessionId,
            peerDeviceId: peerDeviceId
        ) else {
            lastRekeyEvent = "waiting peer=unknown election"
            SkyBridgeLogger.shared.info(
                "⏳ WebRTC rekey waiting for concrete remote device id: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyPending trigger=\(trigger)"
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
                "⏳ WebRTC rekey waiting for stable initiator election: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyPending trigger=\(trigger), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(electionRemoteDeviceId))"
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
                "ℹ️ WebRTC rekey elected peer as initiator; waiting inbound rekey: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyPending trigger=\(trigger), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(electionRemoteDeviceId))"
            )
            return
        }

        let capability = CryptoProviderFactory.detectCapability()
        let selection: CryptoProviderFactory.SelectionPolicy = .requirePQC
        if !(capability.hasApplePQC || capability.hasLiboqs) {
            SkyBridgeLogger.shared.warning(
                "⚠️ skip WebRTC rekey: strictPQC requested but local PQC provider unavailable. " +
                "session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyFailed trigger=\(trigger), hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs)"
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
        if strictPQCRequested,
           currentPathExpectedRemoteAuthorityBySessionId[sessionId] == nil {
            await failStrictClassicBootstrap(
                reason: "missing_current_path_authority",
                diagnostic: "strictPQC WebRTC rekey requires pinned current-path protocol identity"
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
        let requiresSignedCurrentPathKEM = strictPQCRequested
            || currentPathExpectedRemoteAuthorityBySessionId[sessionId] != nil
        for candidateId in candidateIds {
            if requiresSignedCurrentPathKEM {
                trustedKeysByCandidateId[candidateId] = await trustedCurrentPathKEMPublicKeys(
                    for: [candidateId],
                    sessionId: sessionId
                )
            } else {
                trustedKeysByCandidateId[candidateId] = await KEMTrustStore.shared.kemPublicKeys(for: candidateId)
            }
            guard isCurrentRekeyOperation() else { return }
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
                "⏳ WebRTC rekey waiting for peer KEM keys: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyPending peer_ref=\(SkyBridgeDiagnosticReference.stableReference(selectedPeerId)), missing=\(missing)"
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
                "⚠️ skip WebRTC rekey: no suite-aware PQC provider selected. session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyFailed trigger=\(trigger)"
            )
            await failStrictClassicBootstrap(
                reason: "suite_aware_provider_unavailable",
                diagnostic: "no suite-aware PQC provider matched the peer KEM material"
            )
            return
        }

        do {
            try await SkyBridgeiOSCore.shared.initialize(
                policy: selection,
                providerOverride: selectedProvider
            )
            guard isCurrentRekeyOperation() else { return }
            let transport = makeHandshakeTransport(over: session)
            let peer = PeerIdentifier(deviceId: selectedPeerId)
            let sessionMLDSA87PublicKey = try sessionAuthenticatedMLDSA87PublicKey(
                for: sessionId
            )
            let exactMLDSA87PublicKey = try SkyBridgeiOSCore.shared
                .resolvedCurrentPathMLDSA87PublicKey(
                    for: selectedPeerId,
                    sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey
                )
            let trustProvider = CurrentPathHandshakeTrustProviderCompat(
                expectedRemoteAuthority: currentPathExpectedRemoteAuthorityBySessionId[sessionId],
                fallbackPeerIDs: candidateIds,
                additionalTrustedFingerprints: handshakeTrustedProtocolFingerprints(
                    for: sessionId,
                    candidateDeviceIds: candidateIds
                ),
                exactMLDSA87PublicKey: exactMLDSA87PublicKey
            )
            let signingAlgorithm = try SkyBridgeiOSCore.shared
                .currentPathPQCSignatureAlgorithm(
                    for: selectedPeerId,
                    sessionAuthenticatedMLDSA87PublicKey: sessionMLDSA87PublicKey,
                    requestedPQCAlgorithm: try sessionRequestedPQCAlgorithm(
                        sessionId: sessionId
                    )
                )
            let driver = try await SkyBridgeiOSCore.shared.createHandshakeDriver(
                transport: transport,
                offeredSuites: offeredSuites,
                trustProvider: trustProvider,
                protocolSigningAlgorithm: signingAlgorithm,
                protocolSigningKeyProtection: try sessionProtocolSigningKeyProtection(
                    for: signingAlgorithm,
                    sessionId: sessionId
                )
            )
            guard isCurrentRekeyOperation(), handshakeDriver == nil else { return }
            operationDriver = driver
            handshakeDriver = driver

            let suiteSummary = offeredSuites.map(\.rawValue).joined(separator: ",")
            lastRekeyEvent = "start peer=\(selectedPeerId) policy=\(selection.rawValue) suites=\(suiteSummary)"
            SkyBridgeLogger.shared.info(
                "🔁 WebRTC rekey start: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyStarted trigger=\(trigger), peer_ref=\(SkyBridgeDiagnosticReference.stableReference(selectedPeerId)), policy=\(selection.rawValue), provider=\(selectedProviderLabel), offeredSuites=\(suiteSummary)"
            )
            let rekeyed = try await driver.initiateHandshake(with: peer)
            guard isCurrentRekeyOperation(), handshakeDriver === driver else { return }
            let evidenceAttemptSnapshot = await driver
                .productConnectivityAttemptSnapshot()
            guard isCurrentRekeyOperation(), handshakeDriver === driver else { return }
            guard let authenticatedBinding = await driver
                .getAuthenticatedHandshakePeerBinding() else {
                throw CurrentPathAuthorityCommitError.missingAuthenticatedRemoteAuthority
            }
            guard isCurrentRekeyOperation(), handshakeDriver === driver else { return }
            try persistCurrentPathTrust(
                sessionId: sessionId,
                authenticatedRemoteAuthority: authenticatedBinding.authority
            )
            authenticatedHandshakePeerBindingBySessionId[sessionId] = authenticatedBinding
            sessionKeys = rekeyed
            rekeyCompletedSessionIds.insert(sessionId)
            rekeyInProgressSessionIds.remove(sessionId)
            clearStrictPQCClassicBootstrapOnly(sessionId: sessionId)
            lastRekeyEvent = "complete suite=\(rekeyed.negotiatedSuite.rawValue)"

            if isCurrentRekeyOperation() {
                let didPublish = publishApplicationReadyIfCurrent(
                    sessionId: sessionId,
                    sessionObjectIdentifier: expectedSessionObjectIdentifier,
                    keys: rekeyed,
                    session: session
                )
                if didPublish {
                    await sendLocalAuthenticatedRouteBindings(
                        keys: rekeyed,
                        sessionId: sessionId,
                        session: session,
                        stage: "outbound-rekey"
                    )
                }
            }
            guard isCurrentRekeyOperation(), handshakeDriver === driver else { return }

            await publishWebRTCProductEvidenceIfCurrent(
                sessionId: sessionId,
                session: session,
                keys: rekeyed,
                driver: driver,
                attemptSnapshot: evidenceAttemptSnapshot
            )
            guard isCurrentRekeyOperation(), handshakeDriver === driver else { return }

            let rekeyCompletionEvent = rekeyed.negotiatedSuite.isPQCGroup
                ? "pqcRekeyComplete"
                : "classicRekeyComplete"
            let rekeyCompletionLabel = rekeyed.negotiatedSuite.isPQCGroup
                ? "PQC"
                : "classic compatibility"
            SkyBridgeLogger.shared.info(
                "✅ WebRTC \(rekeyCompletionLabel) rekey complete: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=\(rekeyCompletionEvent) suite=\(rekeyed.negotiatedSuite.rawValue)"
            )
        } catch {
            guard isCurrentRekeyOperation() else { return }
            lastRekeyEvent = "failed error=\(error.localizedDescription)"
            if error is CurrentPathAuthorityCommitError {
                await failCurrentPathAuthorityCommit(
                    sessionId: sessionId,
                    sessionObjectIdentifier: expectedSessionObjectIdentifier,
                    stage: "outbound-rekey",
                    error: error
                )
                return
            }
            if strictPQCRequested,
               sessionKeys?.negotiatedSuite.isPQCGroup != true {
                let message = "strictPQC WebRTC rekey failed after classic bootstrap: \(error.localizedDescription)"
                SkyBridgeLogger.shared.error(
                    "⛔️ strictPQC WebRTC rekey failed after classic bootstrap: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyFailed trigger=\(trigger) \(Self.diagnosticErrorSummary(error))"
                )
                lastError = message
                await terminateRemoteDesktopSession(
                    sessionId: sessionId,
                    expectedSessionObjectIdentifier: expectedSessionObjectIdentifier,
                    disconnectKind: .explicit,
                    notificationKind: .interrupted,
                    reason: "strict_pqc_rekey_failed:\(error.localizedDescription)",
                    terminalFailureMessage: message
                )
                return
            }
            SkyBridgeLogger.shared.error(
                "❌ WebRTC rekey failed: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)), event=pqcRekeyFailed trigger=\(trigger), \(Self.diagnosticErrorSummary(error))"
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
        guard sessionIncarnation(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) != nil else {
            return nil
        }
        return sessionKeys
    }

    @MainActor
    private func isCurrentSession(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        sessionIncarnation(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) != nil
    }

    @MainActor
    private func isStrictPQCClassicBootstrapOnlyCurrentSession(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier
    ) -> Bool {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
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

        guard isApplicationTrafficAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            appendSmokeTrace(
                "pairing-admission drop high-throughput session=\(sessionId)"
            )
            return false
        }

        guard !isStrictPQCClassicBootstrapOnlyCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            appendSmokeTrace("strict-pqc-bootstrap drop media payload source=control-channel session=\(sessionId)")
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap dropped media payload before PQC rekey: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) source=control-channel"
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
        keys: SessionKeys,
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> Bool {
        if packetType == .appControl,
           let appMessage = try? AppMessage.decodeWireMessage(from: plaintext) {
            if strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) {
                let messageKind = Self.bootstrapAppMessageKind(appMessage)
                switch appMessage {
                case .pairingIdentityExchange:
                    break
                case .heartbeat, .ping, .pong, .peerDisconnecting:
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC strictPQC classic bootstrap accepted control app message before PQC rekey: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) type=\(messageKind) lastRekey_ref=\(SkyBridgeDiagnosticReference.stableReference(lastRekeyEvent))"
                    )
                default:
                    SkyBridgeLogger.shared.debug(
                        "ℹ️ WebRTC strictPQC classic bootstrap ignored non-bootstrap app message: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) type=\(messageKind) lastRekey_ref=\(SkyBridgeDiagnosticReference.stableReference(lastRekeyEvent))"
                    )
                    return true
                }
            }
            guard await handleInboundAppMessageOverWebRTC(
                appMessage,
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier,
                peerDeviceId: peer.deviceId,
                session: session,
                strictPQCRequested: strictPQCRequested
            ) else {
                return false
            }
            return isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            )
        }

        guard isApplicationTrafficAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            appendSmokeTrace(
                "pairing-admission drop business-packet session=\(sessionId) packet=\(packetType.rawValue)"
            )
            return true
        }

        guard !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) else {
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap ignored business payload before PQC rekey: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
            )
            return true
        }

        if packetType == .fileTransfer {
            do {
                let fileTransfer = try CrossNetworkFileTransferWireDecoder.decode(
                    plaintext
                )
                await dispatchInboundFileTransferFromMac(
                    fileTransfer,
                    sessionID: sessionId,
                    keys: keys,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    encodedPayloadByteCount: plaintext.count
                )
            } catch {
                let diagnosticError = error as NSError
                SkyBridgeLogger.shared.error(
                    "Authenticated WebRTC file-transfer envelope rejected: error_domain=\(diagnosticError.domain) code=\(diagnosticError.code)"
                )
                guard let fileTransferOwner = currentWebRTCFileTransferOperationOwner(
                    sessionID: sessionId,
                    session: session,
                    keys: keys
                ) else {
                    return true
                }
                await failInboundFileTransferControlChannel(
                    "Invalid file-transfer protocol envelope",
                    owner: fileTransferOwner,
                    origin: .controlReceiveLoop
                )
            }
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
           let payload = try? JSONDecoder().decode(
            RemoteDesktopStreamConfigurationAcknowledgement.self,
            from: msg.payload
           ) {
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
        sessionObjectIdentifier: ObjectIdentifier,
        peer: PeerIdentifier,
        session: WebRTCSession,
        strictPQCRequested: Bool
    ) async -> Bool {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else { return false }
        let inboundInitialDriver = await ensureInboundInitialHandshakeDriverIfNeeded(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier,
            frame: frame,
            peer: peer,
            session: session,
            strictPQCRequested: strictPQCRequested
        )
        let inboundRekeyDriver = await ensureInboundPQCRekeyDriverIfNeeded(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier,
            frame: frame,
            peer: peer,
            session: session,
            strictPQCRequested: strictPQCRequested
        )

        if let inboundDriver = inboundInitialDriver ?? inboundRekeyDriver {
            if let messageA = try? HandshakeMessageA.decode(from: frame) {
                let suites = messageA.supportedSuites.map(\.rawValue).joined(separator: ",")
                appendSmokeTrace("rx messageA raw=\(frame.count) suites=\(suites)")
#if DEBUG || SKYBRIDGE_TESTING
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx MessageA raw=\(frame.count) suites=\(suites)")
                }
#endif
            }
            await inboundDriver.handleMessage(frame, from: peer)
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver === inboundDriver else { return true }
            if inboundInitialHandshakeResponderSessionIds.contains(sessionId) {
                await syncInboundInitialHandshakeState(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    strictPQCRequested: strictPQCRequested
                )
            } else {
                await syncInboundPQCRekeyState(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    strictPQCRequested: strictPQCRequested
                )
            }
            return true
        }

        if let driver = handshakeDriver {
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ) else { return false }
            guard isActiveHandshakeDriverFrame(frame) else {
                return false
            }
            if let messageB = try? HandshakeMessageB.decode(from: frame) {
                lastRekeyEvent = "messageB suite=\(messageB.selectedSuite.rawValue)"
                appendSmokeTrace("rx messageB raw=\(frame.count) suite=\(messageB.selectedSuite.rawValue)")
#if DEBUG || SKYBRIDGE_TESTING
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx MessageB raw=\(frame.count) suite=\(messageB.selectedSuite.rawValue)")
                }
#endif
            } else if (try? HandshakeFinished.decode(from: frame)) != nil {
                lastRekeyEvent = "finished"
                appendSmokeTrace("rx finished raw=\(frame.count)")
#if DEBUG || SKYBRIDGE_TESTING
                if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                    print("🧪 WebRTC rekey rx Finished raw=\(frame.count)")
                }
#endif
            }
            await driver.handleMessage(frame, from: peer)
            guard isCurrentSession(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier
            ), handshakeDriver === driver else { return true }
            await syncInboundPQCRekeyState(
                sessionId: sessionId,
                sessionObjectIdentifier: sessionObjectIdentifier,
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
        let maxInboundFrameBytes = WebRTCFramedPayloadPolicy.maximumPayloadByteCount
        do {
            self.appendSmokeTrace("receiveLoop start session=\(sessionId)")
            var parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            var usesDirectControlPayloads = false
            while !Task.isCancelled {
                let chunk = try await inbound.next()
                guard WebRTCFramedPayloadPolicy.isValidPayloadByteCount(chunk.count) else {
                    await inbound.failOverflow()
                    await failAuthenticatedWebRTCChannel(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier,
                        reason: "control_inbound_frame_too_large",
                        originatingReceiveLoop: .control
                    )
                    return
                }

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
                                    "ℹ️ WebRTC 控制通道检测到直发远桌音频数据模式，已在后台数据面处理: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
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
                                    "ℹ️ WebRTC 控制通道检测到直发远桌数据模式，已在后台数据面处理: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
                                )
                            }
                            continue
                        }

                        if await handleDecodedControlPlaintext(
                            plaintext,
                            packetType: openedPayload.packetType,
                            keys: keys,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier,
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
                                    "ℹ️ WebRTC 控制通道检测到直发兼容模式，已跳过分帧解析: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
                                )
                            }
                            continue
                        }
                        if !(await isCurrentSession(
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )) {
                            return
                        }
                    }

                    let trafficUnwrapped = try TrafficPadding.unwrapIfNeeded(
                        chunk,
                        label: "rx/webrtc",
                        maximumOutputByteCount: maxInboundFrameBytes
                    )
                    let handshakeUnwrapped = HandshakePadding.unwrapIfNeeded(
                        trafficUnwrapped,
                        label: "rx/webrtc-direct"
                    )
                    if isLikelyCompleteHandshakeControlPacket(handshakeUnwrapped),
                       await handlePossibleHandshakeControlFrame(
                        handshakeUnwrapped,
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier,
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
                                "ℹ️ WebRTC 控制通道检测到直发握手兼容模式，已跳过分帧解析: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
                            )
                        }
                        continue
                    }
                }
                parser.append(chunk)

                while let payload = parser.nextPayload(sessionId: sessionId, logLabel: "WebRTC") {
                    let length = payload.count
                    let trafficUnwrapped = try TrafficPadding.unwrapIfNeeded(
                        payload,
                        label: "rx/webrtc",
                        maximumOutputByteCount: maxInboundFrameBytes
                    )
#if DEBUG || SKYBRIDGE_TESTING
                    if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
                        print("🧪 WebRTC rekey rx frame len=\(length)")
                    }
#endif
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
                        sessionObjectIdentifier: sessionObjectIdentifier,
                        peer: peer,
                        session: session,
                        strictPQCRequested: strictPQCRequested
                       ) {
                        continue
                    }
                    if let keys = await sessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ) {
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
                                keys: keys,
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier,
                                peer: peer,
                                session: session,
                                strictPQCRequested: strictPQCRequested
                            ) {
                                continue
                            }
                            if !(await isCurrentSession(
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier
                            )) {
                                return
                            }
                            await failAuthenticatedWebRTCChannel(
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier,
                                reason: "invalid_authenticated_payload",
                                originatingReceiveLoop: .control
                            )
                            return
                        } catch {
                            await failAuthenticatedWebRTCChannel(
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier,
                                reason: "authenticated_decryption_failed",
                                originatingReceiveLoop: .control
                            )
                            return
                        }
                    }
                    self.appendSmokeTrace("rx frame len=\(length) keys=false")

                    if isLikelyCompleteHandshakeControlPacket(handshakeFrame) {
                        _ = await handlePossibleHandshakeControlFrame(
                            handshakeFrame,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier,
                            peer: peer,
                            session: session,
                            strictPQCRequested: strictPQCRequested
                        )
                    }
                }
                if parser.terminalFailure != nil {
                    await failAuthenticatedWebRTCChannel(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier,
                        reason: "control_inbound_frame_invalid_length",
                        originatingReceiveLoop: .control
                    )
                    return
                }
            }
        } catch {
            self.appendSmokeTrace("receiveLoop ended error=\(error.localizedDescription)")
            if case InboundChunkQueue.QueueError.overflow = error {
                await failAuthenticatedWebRTCChannel(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    reason: "control_inbound_queue_overflow",
                    originatingReceiveLoop: .control
                )
            }
        }
    }

    @MainActor
    private func failAuthenticatedWebRTCChannel(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        reason: String,
        originatingReceiveLoop: ReceiveLoopTaskKind
    ) async {
        guard isCurrentSession(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            return
        }
        let message = "WebRTC authenticated channel failed: \(reason)"
        SkyBridgeLogger.shared.error("❌ \(message)")
        appendSmokeTrace("authenticated-channel-failed session=\(sessionId) reason=\(reason)")
        await terminateRemoteDesktopSession(
            sessionId: sessionId,
            expectedSessionObjectIdentifier: sessionObjectIdentifier,
            disconnectKind: .explicit,
            notificationKind: .interrupted,
            reason: reason,
            terminalFailureMessage: message,
            clearSnapshot: true,
            originatingReceiveLoop: originatingReceiveLoop
        )
    }

    nonisolated func receiveScreenLoop(
        sessionId: String,
        sessionObjectIdentifier: ObjectIdentifier,
        inbound: InboundChunkQueue
    ) async {
        let maxInboundFrameBytes = WebRTCFramedPayloadPolicy.maximumPayloadByteCount
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
                                "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
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
                            "ℹ️ screen-channel direct candidate 解密失败，已丢弃: mode=waiting-keys-drop session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) bytes=\(pending.count)"
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
                            "ℹ️ screen-channel SBC2 分片已丢弃: reason=\(reason) frameId=\(frameId.map(String.init) ?? "-") session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
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
                                "screen-channel wire=sbc2-chunked-v1 missing-current-keys frameId=\(frameId) session=\(sessionId)"
                            )
                            return
                        }
                        do {
                            guard let screenData = try await decodeEncryptedScreenChannelPayloadIfFresh(
                                payload,
                                keys: frameKeys,
                                sessionId: sessionId
                            ) else {
                                await failAuthenticatedWebRTCChannel(
                                    sessionId: sessionId,
                                    sessionObjectIdentifier: sessionObjectIdentifier,
                                    reason: "invalid_authenticated_screen_payload",
                                    originatingReceiveLoop: .screen
                                )
                                return
                            }
                            wireDecoder.markChunkedPayloadMode()
                            if announcedWireMode != wireDecoder.mode {
                                announcedWireMode = wireDecoder.mode
                                self.appendSmokeTrace(
                                    "screen-channel wire-mode=\(wireDecoder.mode.rawValue) session=\(sessionId) frameId=\(frameId)"
                                )
                                SkyBridgeLogger.shared.info(
                                    "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
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
                            await failAuthenticatedWebRTCChannel(
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier,
                                reason: "authenticated_screen_decryption_failed",
                                originatingReceiveLoop: .screen
                            )
                            return
                        }
                        continue
                    }
                }

                if wireDecoder.mode == .directPayload {
                    guard let keys else {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=directPayload missing-current-keys session=\(sessionId) bytes=\(chunk.count)"
                        )
                        return
                    }

                    do {
                        guard let screenData = try await decodeEncryptedScreenChannelPayloadIfFresh(
                            chunk,
                            keys: keys,
                            sessionId: sessionId
                        ) else {
                            await failAuthenticatedWebRTCChannel(
                                sessionId: sessionId,
                                sessionObjectIdentifier: sessionObjectIdentifier,
                                reason: "invalid_authenticated_screen_payload",
                                originatingReceiveLoop: .screen
                            )
                            return
                        }
                        await publishDecodedScreenDataIfCurrent(
                            screenData,
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier
                        )
                    } catch {
                        await failAuthenticatedWebRTCChannel(
                            sessionId: sessionId,
                            sessionObjectIdentifier: sessionObjectIdentifier,
                            reason: "authenticated_screen_decryption_failed",
                            originatingReceiveLoop: .screen
                        )
                        return
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
                            "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
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
                            "ℹ️ screen-channel direct-looking payload 已等待密钥后重试: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) bytes=\(chunk.count)"
                        )
                    } else {
                        self.appendSmokeTrace(
                            "screen-channel wireMode=direct-candidate-drop session=\(sessionId) bytes=\(chunk.count)"
                        )
                        SkyBridgeLogger.shared.debug(
                            "ℹ️ screen-channel direct-looking payload 未通过解密/解析，已丢弃且未进入 length parser: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) bytes=\(chunk.count)"
                        )
                    }
                    continue
                }

                wireDecoder.appendLengthChunk(chunk)

                while let payload = wireDecoder.nextLengthPayload(sessionId: sessionId, logLabel: "screen-channel") {
                    let wasLockedToLengthFraming = wireDecoder.mode == .lengthFramed
                    guard let frameKeys = await screenReceiveSessionKeysIfCurrent(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier
                    ) else {
                        return
                    }

                    do {
                        guard let screenData = try await decodeEncryptedScreenChannelPayloadIfFresh(
                            payload,
                            keys: frameKeys,
                            sessionId: sessionId
                        ) else {
                            if wasLockedToLengthFraming {
                                await failAuthenticatedWebRTCChannel(
                                    sessionId: sessionId,
                                    sessionObjectIdentifier: sessionObjectIdentifier,
                                    reason: "invalid_authenticated_screen_payload",
                                    originatingReceiveLoop: .screen
                                )
                                return
                            }
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
                                "ℹ️ screen-channel wire 模式锁定: mode=\(wireDecoder.mode.rawValue) session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
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
                            if wasLockedToLengthFraming {
                                await failAuthenticatedWebRTCChannel(
                                    sessionId: sessionId,
                                    sessionObjectIdentifier: sessionObjectIdentifier,
                                    reason: "authenticated_screen_decryption_failed",
                                    originatingReceiveLoop: .screen
                                )
                                return
                            }
                            wireDecoder.resetLengthFramedAfterDecodeFailure()
                            announcedWireMode = nil
                            self.appendSmokeTrace(
                                "screen-channel wire=length-framed decryptFailed reset session=\(sessionId)"
                            )
                            SkyBridgeLogger.shared.debug(
                                "ℹ️ screen-channel payload 解密/解析失败，已重置 length parser: wireMode=lengthFramed \(Self.diagnosticErrorSummary(error))"
                            )
                        }
                    }
                }
                if wireDecoder.lengthParserTerminalFailure != nil {
                    await failAuthenticatedWebRTCChannel(
                        sessionId: sessionId,
                        sessionObjectIdentifier: sessionObjectIdentifier,
                        reason: "screen_inbound_frame_invalid_length",
                        originatingReceiveLoop: .screen
                    )
                    return
                }
            }
        } catch {
            self.appendSmokeTrace("screen-receiveLoop ended error=\(error.localizedDescription)")
            if case InboundChunkQueue.QueueError.overflow = error {
                await failAuthenticatedWebRTCChannel(
                    sessionId: sessionId,
                    sessionObjectIdentifier: sessionObjectIdentifier,
                    reason: "screen_inbound_queue_overflow",
                    originatingReceiveLoop: .screen
                )
            }
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
        guard isApplicationTrafficAdmitted(
            sessionId: sessionId,
            sessionObjectIdentifier: sessionObjectIdentifier
        ) else {
            appendSmokeTrace(
                "pairing-admission drop screen-payload session=\(sessionId)"
            )
            return false
        }
        guard !strictPQCClassicBootstrapOnlySessionIds.contains(sessionId) else {
            appendSmokeTrace("strict-pqc-bootstrap drop media payload source=screen-channel session=\(sessionId)")
            SkyBridgeLogger.shared.debug(
                "ℹ️ WebRTC strictPQC classic bootstrap dropped media payload before PQC rekey: session_ref=\(SkyBridgeDiagnosticReference.stableReference(sessionId)) source=screen-channel"
            )
            return false
        }
        publishDecodedScreenData(screenData)
        return true
    }

    @inline(__always)
    nonisolated func appendSmokeTrace(_ line: @autoclosure () -> String) {
#if DEBUG || SKYBRIDGE_TESTING
        SkyBridgeDiagnosticTrace.append(line())
#endif
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
        let applicationTrafficAdmitted: Bool
        if let activeSession = session {
            applicationTrafficAdmitted = isApplicationTrafficAdmitted(
                sessionId: sessionId,
                sessionObjectIdentifier: ObjectIdentifier(activeSession)
            )
        } else {
            applicationTrafficAdmitted = false
        }
        if !applicationTrafficAdmitted {
            guard packetType == .appControl,
                  let appMessage = try? JSONDecoder().decode(
                    AppMessage.self,
                    from: plaintext
                  ),
                  Self.isPairingAdmissionBootstrapMessage(appMessage) else {
                throw ApplicationTrafficAdmissionError.pairingMaterialNotAdmitted
            }
        }
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
