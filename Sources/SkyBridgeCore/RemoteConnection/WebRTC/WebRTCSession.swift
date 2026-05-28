import Foundation
import OSLog
import SkyBridgeProtocolCore
import CoreVideo

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

/// WebRTC 会话：负责 PeerConnection + DataChannel + ICE 收发
///
/// 注意：
/// - 这是“跨网连接”的传输层，只解决可达性（ICE/TURN）。
/// - 上层可以在 DataChannel 上跑现有的握手/加密/业务协议。
public final class WebRTCSession: NSObject, @unchecked Sendable {
    public enum Role: Sendable {
        case offerer
        case answerer
    }

    public enum ICETransportPath: String, Sendable {
        case unknown
        case direct
        case relay
    }

    public struct NativeScreenVideoSendSnapshot: Sendable, Equatable {
        public let trackReady: Bool
        public let trackEnabled: Bool
        public let sourceReady: Bool
        public let capturerReady: Bool
        public let transceiverReady: Bool
        public let senderReady: Bool
        public let transceiverDirection: String?
        public let negotiatedTransceiverDirection: String?
        public let lastFrameWidth: Int
        public let lastFrameHeight: Int
        public let lastSubmittedFrameWidth: Int
        public let lastSubmittedFrameHeight: Int
        public let lastRawFramePixelFormat: UInt32?
        public let lastFramePixelFormat: UInt32?
        public let lastSubmittedFramePixelFormat: UInt32?
        public let lastSubmittedFrameBytesPerRow: Int
        public let lastSubmittedFrameHasIOSurface: Bool
        public let lastFrameWasNormalized: Bool
        public let lastRawFrameTimestampNs: Int64?
        public let lastFrameTimestampNs: Int64?
        public let lastRawFrameTimestampDeltaNs: Int64?
        public let lastFrameTimestampDeltaNs: Int64?
        public let lastFrameTimestampWasAdjusted: Bool
        public let targetWidth: Int
        public let targetHeight: Int
        public let targetFPS: Int
        public let normalizedFrames: UInt64
        public let submittedFrames: UInt64
    }

    public struct NativeScreenVideoRTCStats: Sendable, Equatable {
        public let outboundStatsPresent: Bool
        public let framesEncoded: UInt64
        public let framesSent: UInt64
        public let packetsSent: UInt64
        public let bytesSent: UInt64
        public let nackCount: UInt64
        public let pliCount: UInt64
        public let firCount: UInt64
        public let codec: String?
        public let encoderImplementation: String?
        public let qualityLimitationReason: String?
        public let frameWidth: UInt64
        public let frameHeight: UInt64
        public let framesPerSecond: UInt64
        public let keyFramesEncoded: UInt64
        public let totalEncodeTime: Double?
        public let targetBitrate: UInt64
        public let availableOutgoingBitrate: UInt64
        public let currentRoundTripTime: Double?
        public let remotePacketsLost: Int64
        public let remoteJitter: Double?
        public let remoteRoundTripTime: Double?

        public var rtpFlowing: Bool {
            outboundStatsPresent && packetsSent > 0 && bytesSent > 0
        }

        public var bandwidthEstimatePresent: Bool {
            targetBitrate > 0 || availableOutgoingBitrate > 0
        }

        public var isQualityLimited: Bool {
            guard let reason = qualityLimitationReason?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty else {
                return false
            }
            return reason.lowercased() != "none"
        }

        public static let empty = NativeScreenVideoRTCStats(
            outboundStatsPresent: false,
            framesEncoded: 0,
            framesSent: 0,
            packetsSent: 0,
            bytesSent: 0,
            nackCount: 0,
            pliCount: 0,
            firCount: 0,
            codec: nil,
            encoderImplementation: nil,
            qualityLimitationReason: nil,
            frameWidth: 0,
            frameHeight: 0,
            framesPerSecond: 0,
            keyFramesEncoded: 0,
            totalEncodeTime: nil,
            targetBitrate: 0,
            availableOutgoingBitrate: 0,
            currentRoundTripTime: nil,
            remotePacketsLost: 0,
            remoteJitter: nil,
            remoteRoundTripTime: nil
        )
    }

    public struct ScreenChunkedPayloadBudget: Sendable, Equatable {
        public let chunkCount: Int
        public let framedBytes: Int
        public let bufferedAmountBytes: UInt64
        public let maxBufferedAmountBytes: UInt64
    }

    public static func recommendedNativeScreenVideoBitrateBps(
        width: Int,
        height: Int,
        fps: Int
    ) -> Int {
        WebRTCNativeScreenVideoValuePolicy.recommendedBitrateBps(
            width: width,
            height: height,
            fps: fps
        )
    }

    public static func minimumExtremeNativeScreenVideoBitrateBps(
        width: Int,
        height: Int,
        fps: Int
    ) -> UInt64 {
        WebRTCNativeScreenVideoValuePolicy.minimumExtremeBitrateBps(
            width: width,
            height: height,
            fps: fps
        )
    }

    public typealias ICEConfig = SkyBridgeICEConfiguration
    
    public enum WebRTCError: Error, LocalizedError, Sendable {
        case webRTCNotAvailable
        case peerConnectionCreationFailed
        case dataChannelNotReady
        case dataChannelNotOpen
        case dataChannelSendFailed
        case sdpFailed(String)
        case invalidChunkSize(Int)
        case framedPayloadTooLarge(Int)
        case screenFrameBudgetExceeded(framedBytes: Int, bufferedAmount: UInt64, maxBufferedAmountBytes: UInt64)
        case alreadyClosed
        
        public var errorDescription: String? {
            switch self {
            case .webRTCNotAvailable: return "WebRTC 模块不可用（请确认已添加 WebRTC 依赖）"
            case .peerConnectionCreationFailed: return "创建 RTCPeerConnection 失败"
            case .dataChannelNotReady: return "DataChannel 未就绪"
            case .dataChannelNotOpen: return "DataChannel 未打开"
            case .dataChannelSendFailed: return "DataChannel 发送失败"
            case .sdpFailed(let msg): return "SDP 处理失败：\(msg)"
            case .invalidChunkSize(let value): return "分块大小无效：\(value)。必须大于 0"
            case .framedPayloadTooLarge(let size): return "分帧负载过大：\(size) 字节，超过 4 GiB 上限"
            case .screenFrameBudgetExceeded(let framedBytes, let bufferedAmount, let maxBufferedAmountBytes):
                return "SBC2 屏幕帧超过发送预算：framedBytes=\(framedBytes) buffered=\(bufferedAmount) budget=\(maxBufferedAmountBytes)"
            case .alreadyClosed: return "WebRTCSession 已关闭"
            }
        }
    }

    private let logger = Logger(subsystem: "com.skybridge.webrtc", category: "WebRTCSession")
    private static let publicFallbackSTUNURL = "stun:stun.l.google.com:19302"
    private static let controlChannelLabel = "skybridge"
    private static let screenChannelLabel = "skybridge-screen"
    private static let maxPendingInboundControlBuffers = 64
    private static let maxPendingInboundControlBytes = 512 * 1024
    private static let maxPendingInboundScreenBuffers = 256
    private static let maxPendingInboundScreenBytes = 4 * 1024 * 1024
    private let stateQueue = DispatchQueue(label: "com.skybridge.webrtc.session.state.\(UUID().uuidString)")
    private let callbackQueue = DispatchQueue(label: "com.skybridge.webrtc.session.callback.\(UUID().uuidString)", qos: .userInitiated)
    private let stateQueueKey = DispatchSpecificKey<String>()
    private let stateQueueID = UUID().uuidString
    
    public let sessionId: String
    public let localDeviceId: String
    public let role: Role
    public let ice: ICEConfig
    
    private var _onLocalOffer: (@Sendable (String) -> Void)?
    public var onLocalOffer: (@Sendable (String) -> Void)? {
        get { withState { _onLocalOffer } }
        set { withState { _onLocalOffer = newValue } }
    }
    private var _onLocalAnswer: (@Sendable (String) -> Void)?
    public var onLocalAnswer: (@Sendable (String) -> Void)? {
        get { withState { _onLocalAnswer } }
        set { withState { _onLocalAnswer = newValue } }
    }
    private var _onLocalICECandidate: (@Sendable (WebRTCSignalingEnvelope.Payload) -> Void)?
    public var onLocalICECandidate: (@Sendable (WebRTCSignalingEnvelope.Payload) -> Void)? {
        get { withState { _onLocalICECandidate } }
        set { withState { _onLocalICECandidate = newValue } }
    }
    private var _onData: (@Sendable (Data) -> Void)?
    public var onData: (@Sendable (Data) -> Void)? {
        get { withState { _onData } }
        set {
            withState { _onData = newValue }
            flushPendingInboundDataIfNeeded()
        }
    }
    private var _onScreenData: (@Sendable (Data) -> Void)?
    public var onScreenData: (@Sendable (Data) -> Void)? {
        get { withState { _onScreenData } }
        set {
            withState { _onScreenData = newValue }
            flushPendingInboundScreenDataIfNeeded()
        }
    }
    private var _onReady: (@Sendable () -> Void)?
    public var onReady: (@Sendable () -> Void)? {
        get { withState { _onReady } }
        set { withState { _onReady = newValue } }
    }
    private var _onDisconnected: (@Sendable (String) -> Void)?
    public var onDisconnected: (@Sendable (String) -> Void)? {
        get { withState { _onDisconnected } }
        set { withState { _onDisconnected = newValue } }
    }
    private var _onTrace: (@Sendable (String) -> Void)?
    public var onTrace: (@Sendable (String) -> Void)? {
        get { withState { _onTrace } }
        set { withState { _onTrace = newValue } }
    }
    
#if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var screenDataChannel: RTCDataChannel?
    private var localVideoSource: RTCVideoSource?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoTransceiver: RTCRtpTransceiver?
    private var localVideoCapturer: RTCVideoCapturer?
    private let nativeScreenVideoFrameNormalizer = WebRTCNativeScreenVideoFrameNormalizer()
    private var localAudioSource: RTCAudioSource?
    private var localAudioTrack: RTCAudioTrack?
    private var localAudioTransceiver: RTCRtpTransceiver?
    private var didLogOutgoingNativeVideoFrame = false
    private var didLogMissingOutgoingNativeVideoPipeline = false
    private var outgoingNativeVideoFrameCount: UInt64 = 0
    private var outgoingNativeVideoNormalizedFrameCount: UInt64 = 0
    private var lastOutgoingNativeVideoFrameWidth = 0
    private var lastOutgoingNativeVideoFrameHeight = 0
    private var lastOutgoingNativeVideoSubmittedFrameWidth = 0
    private var lastOutgoingNativeVideoSubmittedFrameHeight = 0
    private var lastOutgoingNativeVideoRawPixelFormat: UInt32?
    private var lastOutgoingNativeVideoSubmittedPixelFormat: UInt32?
    private var lastOutgoingNativeVideoSubmittedBytesPerRow = 0
    private var lastOutgoingNativeVideoSubmittedHasIOSurface = false
    private var lastOutgoingNativeVideoFrameWasNormalized = false
    private var lastOutgoingNativeVideoRawTimestampNs: Int64?
    private var lastOutgoingNativeVideoTimestampNs: Int64?
    private var lastOutgoingNativeVideoRawTimestampDeltaNs: Int64?
    private var lastOutgoingNativeVideoTimestampDeltaNs: Int64?
    private var lastOutgoingNativeVideoTimestampWasAdjusted = false
    private var lastOutgoingNativeVideoTargetWidth = 1280
    private var lastOutgoingNativeVideoTargetHeight = 720
    private var lastOutgoingNativeVideoTargetFPS = 60
    private var lastOutgoingNativeVideoDisallowQualityDegradation = false
    private var lastOutgoingNativeVideoFrameLogAt: Date = .distantPast
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
    private var seenRemoteICECandidateKeys: Set<String> = []
#endif
    
    private var isClosed = false
    private var sslHeld = false
    private var didNotifyDisconnected = false
    private var didNotifyReady = false
    private var hasRemoteDescription = false
    private var isSettingRemoteDescription = false
    private var lastEmittedLocalSDP: String?
    private var lifecycleToken: UInt64 = 0
    private let inboundDataLock = NSLock()
    private let inboundScreenDataLock = NSLock()
    private let outboundFrameLock = NSLock()
    private let outboundScreenFrameLock = NSLock()
    private let outboundFrameGate = WebRTCOutboundFrameGate()
    private let outboundScreenFrameGate = WebRTCOutboundFrameGate()
    private var nextScreenChunkedFrameId: UInt64 = 1
    private var pendingInboundDataBuffers: [Data] = []
    private var pendingInboundDataBytes: Int = 0
    private var pendingInboundScreenDataBuffers: [Data] = []
    private var pendingInboundScreenDataBytes: Int = 0
    // Native screen video is the primary cross-network path on macOS.
    // Other platforms stay on the framed DataChannel path unless explicitly enabled.
    private let prefersNativeOutgoingScreenTrack: Bool = {
        if let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_ENABLE_WEBRTC_NATIVE_SCREEN_TRACK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw == "1"
        }
#if os(macOS)
        return true
#else
        return false
#endif
    }()
    private let prefersNativeOutgoingAudioTrack: Bool = {
        WebRTCSession.nativeOutgoingAudioTrackPreference(
            environment: ProcessInfo.processInfo.environment
        )
    }()
    
    public init(sessionId: String, localDeviceId: String, role: Role, ice: ICEConfig) {
        self.sessionId = sessionId
        self.localDeviceId = localDeviceId
        self.role = role
        self.ice = ice
        super.init()
        stateQueue.setSpecific(key: stateQueueKey, value: stateQueueID)
    }

    private var isOnStateQueue: Bool {
        DispatchQueue.getSpecific(key: stateQueueKey) == stateQueueID
    }

    private func withState<T>(_ operation: () throws -> T) rethrows -> T {
        switch Self.stateAccessPlan(isOnStateQueue: isOnStateQueue) {
        case .executeInline:
            return try operation()
        case .syncOnStateQueue:
            return try stateQueue.sync(execute: operation)
        }
    }

    private func scheduleState(_ operation: @escaping () -> Void) {
        stateQueue.async(execute: DispatchWorkItem(block: operation))
    }

    private func dispatchCallback(_ operation: @escaping () -> Void) {
        switch Self.callbackDispatchPlan(isOnStateQueue: isOnStateQueue) {
        case .asyncOffStateQueue:
            callbackQueue.async(execute: DispatchWorkItem(block: operation))
        case .executeInline:
            operation()
        }
    }

    public nonisolated static let screenChunkedWireFormat = "sbc2-chunked-v1"
    public nonisolated static let screenChunkHeaderByteCount = 36

    public nonisolated static func screenChunkedPayloadBudget(
        payloadByteCount: Int,
        maxChunkBytes: Int,
        bufferedAmountBytes: UInt64,
        maxBufferedAmountBytes: UInt64
    ) throws -> ScreenChunkedPayloadBudget {
        guard maxChunkBytes > screenChunkHeaderByteCount else {
            throw WebRTCError.invalidChunkSize(maxChunkBytes)
        }
        _ = try validateFramedPayloadParameters(
            payloadByteCount: payloadByteCount,
            maxChunkBytes: maxChunkBytes
        )
        let maxPayloadBytes = maxChunkBytes - screenChunkHeaderByteCount
        let chunkCount = max(1, (payloadByteCount + maxPayloadBytes - 1) / maxPayloadBytes)
        let framedBytes = payloadByteCount + chunkCount * screenChunkHeaderByteCount
        return ScreenChunkedPayloadBudget(
            chunkCount: chunkCount,
            framedBytes: framedBytes,
            bufferedAmountBytes: bufferedAmountBytes,
            maxBufferedAmountBytes: maxBufferedAmountBytes
        )
    }

    public nonisolated static func validateScreenChunkedWholeFrameBudget(
        payloadByteCount: Int,
        maxChunkBytes: Int,
        bufferedAmountBytes: UInt64,
        maxBufferedAmountBytes: UInt64
    ) throws -> ScreenChunkedPayloadBudget {
        let budget = try screenChunkedPayloadBudget(
            payloadByteCount: payloadByteCount,
            maxChunkBytes: maxChunkBytes,
            bufferedAmountBytes: bufferedAmountBytes,
            maxBufferedAmountBytes: maxBufferedAmountBytes
        )
        guard UInt64(budget.framedBytes) <= maxBufferedAmountBytes,
              bufferedAmountBytes <= maxBufferedAmountBytes - UInt64(budget.framedBytes) else {
            throw WebRTCError.screenFrameBudgetExceeded(
                framedBytes: budget.framedBytes,
                bufferedAmount: bufferedAmountBytes,
                maxBufferedAmountBytes: maxBufferedAmountBytes
            )
        }
        return budget
    }

    public nonisolated static func encodeScreenChunkEnvelope(
        frameId: UInt64,
        chunkIndex: Int,
        chunkCount: Int,
        totalBytes: Int,
        chunkOffset: Int,
        payload: Data
    ) throws -> Data {
        guard chunkIndex >= 0,
              chunkCount > 0,
              chunkIndex < chunkCount,
              totalBytes >= 0,
              chunkOffset >= 0,
              payload.count >= 0,
              chunkOffset + payload.count <= totalBytes,
              chunkCount <= Int(UInt32.max),
              chunkIndex <= Int(UInt32.max),
              totalBytes <= Int(UInt32.max),
              chunkOffset <= Int(UInt32.max),
              payload.count <= Int(UInt32.max) else {
            throw WebRTCError.framedPayloadTooLarge(totalBytes)
        }

        var data = Data()
        appendBigEndian(UInt32(0x5342_4332), to: &data) // SBC2
        data.append(1) // version
        var flags: UInt8 = 0
        if chunkIndex == 0 { flags |= 0x01 }
        if chunkIndex == chunkCount - 1 { flags |= 0x02 }
        data.append(flags)
        appendBigEndian(UInt16(screenChunkHeaderByteCount), to: &data)
        appendBigEndian(frameId, to: &data)
        appendBigEndian(UInt32(chunkIndex), to: &data)
        appendBigEndian(UInt32(chunkCount), to: &data)
        appendBigEndian(UInt32(totalBytes), to: &data)
        appendBigEndian(UInt32(chunkOffset), to: &data)
        appendBigEndian(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    private nonisolated static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    /// 关闭 WebRTC 会话并释放所有资源（PeerConnection / DataChannel / SSL）。
    ///
    /// 符合 IEEE TDSC 安全生命周期管理要求：
    /// - 主动关闭 DataChannel 防止数据残留
    /// - 关闭 PeerConnection 终止 ICE / DTLS-SRTP 会话
    /// - 调用 RTCCleanupSSL() 释放 OpenSSL 上下文
    public func close() {
        withState {
            guard !isClosed else { return }
            isClosed = true
            didNotifyDisconnected = true
            didNotifyReady = false
            hasRemoteDescription = false
            isSettingRemoteDescription = false
            lastEmittedLocalSDP = nil
            lifecycleToken &+= 1
            onDisconnected = nil
#if canImport(WebRTC)
            pendingRemoteICECandidates.removeAll(keepingCapacity: false)
            seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
            dataChannel?.close()
            dataChannel = nil
            screenDataChannel?.close()
            screenDataChannel = nil
            localVideoTrack = nil
            localVideoSource = nil
            localVideoTransceiver = nil
            localVideoCapturer = nil
            localAudioTrack = nil
            localAudioSource = nil
            localAudioTransceiver = nil
            didLogOutgoingNativeVideoFrame = false
            didLogMissingOutgoingNativeVideoPipeline = false
            outgoingNativeVideoFrameCount = 0
            outgoingNativeVideoNormalizedFrameCount = 0
            lastOutgoingNativeVideoFrameWidth = 0
            lastOutgoingNativeVideoFrameHeight = 0
            lastOutgoingNativeVideoSubmittedFrameWidth = 0
            lastOutgoingNativeVideoSubmittedFrameHeight = 0
            lastOutgoingNativeVideoRawPixelFormat = nil
            lastOutgoingNativeVideoSubmittedPixelFormat = nil
            lastOutgoingNativeVideoSubmittedBytesPerRow = 0
            lastOutgoingNativeVideoSubmittedHasIOSurface = false
            lastOutgoingNativeVideoFrameWasNormalized = false
            lastOutgoingNativeVideoRawTimestampNs = nil
            lastOutgoingNativeVideoTimestampNs = nil
            lastOutgoingNativeVideoRawTimestampDeltaNs = nil
            lastOutgoingNativeVideoTimestampDeltaNs = nil
            lastOutgoingNativeVideoTimestampWasAdjusted = false
            lastOutgoingNativeVideoTargetWidth = 1280
            lastOutgoingNativeVideoTargetHeight = 720
            lastOutgoingNativeVideoTargetFPS = 60
            lastOutgoingNativeVideoDisallowQualityDegradation = false
            lastOutgoingNativeVideoFrameLogAt = .distantPast
            peerConnection?.close()
            peerConnection = nil
            if sslHeld {
                sslHeld = false
                WebRTCSSL.release()
            }
#endif
            onLocalOffer = nil
            onLocalAnswer = nil
            onLocalICECandidate = nil
            inboundDataLock.lock()
            pendingInboundDataBuffers.removeAll(keepingCapacity: false)
            pendingInboundDataBytes = 0
            inboundDataLock.unlock()
            inboundScreenDataLock.lock()
            pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
            pendingInboundScreenDataBytes = 0
            inboundScreenDataLock.unlock()
            onData = nil
            onScreenData = nil
            onReady = nil
            onTrace = nil
            logger.info("⏹️ WebRTCSession closed sessionId=\(self.sessionId, privacy: .public)")
        }
    }
    
    deinit {
        close()
    }

    private static func normalizedICEURL(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("stun:") || value.hasPrefix("turn:") || value.hasPrefix("turns:") {
            return value
        }
        return nil
    }

    private static func normalizedCredential(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var shouldForceRelayOnlyForSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil &&
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FORCE_RELAY_ICE"] == "1"
    }

#if canImport(WebRTC)
    private func buildIceServers() -> [RTCIceServer] {
        var servers: [RTCIceServer] = []

        if let stunURL = Self.normalizedICEURL(ice.stunURL), stunURL.hasPrefix("stun:") {
            servers.append(RTCIceServer(urlStrings: [stunURL]))
        } else {
            logger.warning("⚠️ Invalid STUN URL. sessionId=\(self.sessionId, privacy: .public)")
        }

        let turnURLs = ice.turnURLs.compactMap(Self.normalizedICEURL)
        let validTurnURLs = Array(Set(turnURLs)).sorted { lhs, rhs in
            let lhsLower = lhs.lowercased()
            let rhsLower = rhs.lowercased()
            if lhsLower.hasPrefix("turns:") == rhsLower.hasPrefix("turns:") {
                return lhs < rhs
            }
            return lhsLower.hasPrefix("turns:")
        }
        let turnUsername = Self.normalizedCredential(ice.turnUsername)
        let turnPassword = Self.normalizedCredential(ice.turnPassword)

        if !validTurnURLs.isEmpty {
            if !turnUsername.isEmpty, !turnPassword.isEmpty {
                servers.append(RTCIceServer(urlStrings: validTurnURLs, username: turnUsername, credential: turnPassword))
            } else {
                logger.warning("⚠️ TURN credentials missing, degraded to STUN-only. sessionId=\(self.sessionId, privacy: .public)")
            }
        } else if !ice.turnURLs.isEmpty {
            logger.warning("⚠️ Invalid TURN URLs. sessionId=\(self.sessionId, privacy: .public)")
        }

        if servers.isEmpty {
            servers.append(RTCIceServer(urlStrings: [Self.publicFallbackSTUNURL]))
            logger.warning("⚠️ No valid ICE servers, fallback to public STUN. sessionId=\(self.sessionId, privacy: .public)")
        }

        return servers
    }
#endif
    
    public func start() throws {
        try withState {
            guard !isClosed else { throw WebRTCError.alreadyClosed }
            didNotifyDisconnected = false
            didNotifyReady = false
            hasRemoteDescription = false
            lastEmittedLocalSDP = nil
            lifecycleToken &+= 1
#if canImport(WebRTC)
            pendingRemoteICECandidates.removeAll(keepingCapacity: false)
            seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
            WebRTCSSL.retain()
            sslHeld = true
            let factory = WebRTCPeerConnectionFactoryProvider.factory(
                useCustomAudioDevice: prefersNativeOutgoingAudioTrack
            )
            
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.continualGatheringPolicy = .gatherContinually
            if Self.shouldForceRelayOnlyForSmoke {
                config.iceTransportPolicy = .relay
            }
            config.iceServers = buildIceServers()
            
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
            )
            
            guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
                logger.error("❌ RTCPeerConnection creation failed: sessionId=\(self.sessionId, privacy: .public) iceServerCount=\(config.iceServers.count, privacy: .public)")
                sslHeld = false
                WebRTCSSL.release()
                throw WebRTCError.peerConnectionCreationFailed
            }
            self.peerConnection = pc
            if prefersNativeOutgoingScreenTrack {
                configureOutgoingScreenVideoIfNeeded(factory: factory, peerConnection: pc)
            }
            if prefersNativeOutgoingAudioTrack {
                configureOutgoingSystemAudioIfNeeded(factory: factory, peerConnection: pc)
            }
            
            if role == .offerer {
                let dcConfig = RTCDataChannelConfiguration()
                dcConfig.isOrdered = true
                dcConfig.isNegotiated = false
                let dc = pc.dataChannel(forLabel: Self.controlChannelLabel, configuration: dcConfig)
                dc?.delegate = self
                self.dataChannel = dc
            }
            
            logger.info("✅ WebRTCSession started role=\(String(describing: self.role), privacy: .public) sessionId=\(self.sessionId, privacy: .public)")
            
            if role == .offerer {
                createOffer()
            }
#else
            throw WebRTCError.webRTCNotAvailable
#endif
        }
    }

    @discardableResult
    public func requestLocalOfferEmission(reason: String) -> Bool {
#if canImport(WebRTC)
        withState {
            guard role == .offerer, !isClosed else { return false }

            if let localDescription = peerConnection?.localDescription {
                let sdp = localDescription.sdp
                guard !sdp.isEmpty else { return false }
                lastEmittedLocalSDP = sdp
                logger.info(
                    "🔁 re-emitting local offer. sessionId=\(self.sessionId, privacy: .public) reason=\(reason, privacy: .public)"
                )
                logLocalSDPSummary(kind: "offer-reemit", sdp: sdp)
                let handler = onLocalOffer
                dispatchCallback {
                    handler?(sdp)
                }
                return true
            }

            guard peerConnection != nil else { return false }
            logger.warning(
                "⚠️ local offer requested before localDescription was cached; regenerating offer. sessionId=\(self.sessionId, privacy: .public) reason=\(reason, privacy: .public)"
            )
            createOffer()
            return true
        }
#else
        false
#endif
    }

    private func notifyDisconnectedIfNeeded(reason: String) {
        let handler: (@Sendable (String) -> Void)? = withState {
            guard !didNotifyDisconnected else { return nil }
            didNotifyDisconnected = true
            return onDisconnected
        }
        guard let handler else { return }
        dispatchCallback {
            handler(reason)
        }
    }

    private func notifyReadyIfNeeded() {
        let handler: (@Sendable () -> Void)? = withState {
            guard !didNotifyReady else { return nil }
            didNotifyReady = true
            return onReady
        }
        guard let handler else { return }
        dispatchCallback {
            handler()
        }
    }

    private func flushPendingInboundDataIfNeeded() {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundDataLock.lock()
        handler = onData
        switch Self.pendingInboundFlushPlan(
            hasHandlerInstalled: handler != nil,
            pendingCount: pendingInboundDataBuffers.count
        ) {
        case .dispatchBuffered:
            buffered = pendingInboundDataBuffers
            pendingInboundDataBuffers.removeAll(keepingCapacity: false)
            pendingInboundDataBytes = 0
        case .keepBuffered:
            break
        }
        inboundDataLock.unlock()

        guard let handler else { return }
        dispatchCallback {
            buffered.forEach(handler)
        }
    }

    private func flushPendingInboundScreenDataIfNeeded() {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundScreenDataLock.lock()
        handler = onScreenData
        switch Self.pendingInboundFlushPlan(
            hasHandlerInstalled: handler != nil,
            pendingCount: pendingInboundScreenDataBuffers.count
        ) {
        case .dispatchBuffered:
            buffered = pendingInboundScreenDataBuffers
            pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
            pendingInboundScreenDataBytes = 0
        case .keepBuffered:
            break
        }
        inboundScreenDataLock.unlock()

        guard let handler else { return }
        dispatchCallback {
            buffered.forEach(handler)
        }
    }

    private func deliverInboundData(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        var overflowReason: String?
        inboundDataLock.lock()
        let activeHandler = onData
        switch Self.pendingInboundDeliveryPlan(
            hasHandlerInstalled: activeHandler != nil,
            pendingCount: pendingInboundDataBuffers.count
        ) {
        case .dispatch:
            handler = activeHandler
            if !pendingInboundDataBuffers.isEmpty {
                buffered = pendingInboundDataBuffers
                pendingInboundDataBuffers.removeAll(keepingCapacity: false)
                pendingInboundDataBytes = 0
            }
        case .bufferIncoming:
            switch Self.pendingInboundBufferLimitPlan(
                pendingCount: pendingInboundDataBuffers.count,
                pendingBytes: pendingInboundDataBytes,
                incomingBytes: data.count,
                maxCount: Self.maxPendingInboundControlBuffers,
                maxBytes: Self.maxPendingInboundControlBytes
            ) {
            case .append(_, let nextPendingBytes):
                pendingInboundDataBuffers.append(data)
                pendingInboundDataBytes = nextPendingBytes
            case .overflow:
                pendingInboundDataBuffers.removeAll(keepingCapacity: false)
                pendingInboundDataBytes = 0
                overflowReason = "pending_inbound_control_overflow"
            }
            handler = nil
        }
        inboundDataLock.unlock()

        if let overflowReason {
            logger.error(
                "❌ WebRTC control inbound buffer overflow. sessionId=\(self.sessionId, privacy: .public) limitBytes=\(Self.maxPendingInboundControlBytes, privacy: .public)"
            )
            notifyDisconnectedIfNeeded(reason: overflowReason)
            close()
            return
        }

        guard let handler else { return }
        dispatchCallback {
            buffered.forEach(handler)
            handler(data)
        }
    }

    private func deliverInboundScreenData(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        var overflowReason: String?
        inboundScreenDataLock.lock()
        let activeHandler = onScreenData
        switch Self.pendingInboundDeliveryPlan(
            hasHandlerInstalled: activeHandler != nil,
            pendingCount: pendingInboundScreenDataBuffers.count
        ) {
        case .dispatch:
            handler = activeHandler
            if !pendingInboundScreenDataBuffers.isEmpty {
                buffered = pendingInboundScreenDataBuffers
                pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
                pendingInboundScreenDataBytes = 0
            }
        case .bufferIncoming:
            switch Self.pendingInboundBufferLimitPlan(
                pendingCount: pendingInboundScreenDataBuffers.count,
                pendingBytes: pendingInboundScreenDataBytes,
                incomingBytes: data.count,
                maxCount: Self.maxPendingInboundScreenBuffers,
                maxBytes: Self.maxPendingInboundScreenBytes
            ) {
            case .append(_, let nextPendingBytes):
                pendingInboundScreenDataBuffers.append(data)
                pendingInboundScreenDataBytes = nextPendingBytes
            case .overflow:
                pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
                pendingInboundScreenDataBytes = 0
                overflowReason = "pending_inbound_screen_overflow"
            }
            handler = nil
        }
        inboundScreenDataLock.unlock()

        if let overflowReason {
            logger.error(
                "❌ WebRTC screen inbound buffer overflow. sessionId=\(self.sessionId, privacy: .public) limitBytes=\(Self.maxPendingInboundScreenBytes, privacy: .public)"
            )
            notifyDisconnectedIfNeeded(reason: overflowReason)
            close()
            return
        }

        guard let handler else { return }
        dispatchCallback {
            buffered.forEach(handler)
            handler(data)
        }
    }

    private func isScreenChannel(_ dataChannel: RTCDataChannel) -> Bool {
#if canImport(WebRTC)
        dataChannel.label == Self.screenChannelLabel
#else
        false
#endif
    }

    private func isControlChannel(_ dataChannel: RTCDataChannel) -> Bool {
#if canImport(WebRTC)
        dataChannel.label == Self.controlChannelLabel || dataChannel.label.isEmpty
#else
        false
#endif
    }
    
    public func setRemoteOffer(_ sdp: String) {
#if canImport(WebRTC)
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            let normalizedOffer = Self.normalizedRemoteSDP(sdp)
            if self.hasRemoteDescription || self.isSettingRemoteDescription {
                self.absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp)
                self.logger.debug("ℹ️ ignore duplicate remote offer. sessionId=\(self.sessionId, privacy: .public)")
                return
            }
            guard let pc = self.peerConnection else { return }
            if pc.remoteDescription != nil {
                self.hasRemoteDescription = true
                self.absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp)
                self.flushPendingRemoteICECandidates()
                self.logger.debug("ℹ️ remote offer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
                return
            }
            let desc = RTCSessionDescription(type: .offer, sdp: normalizedOffer.sdp)
            self.isSettingRemoteDescription = true
            let expectedLifecycleToken = self.lifecycleToken
            pc.setRemoteDescription(desc) { [weak self, weak pc] error in
                guard let self else { return }
                self.scheduleState {
                    guard let pc,
                          self.peerConnection === pc,
                          !self.isClosed,
                          self.lifecycleToken == expectedLifecycleToken else { return }
                    self.isSettingRemoteDescription = false
                    if let error {
                        self.logger.error("❌ setRemoteOffer failed: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    self.hasRemoteDescription = true
                    self.logRemoteSDPSummary(kind: "offer", sdp: normalizedOffer.sdp)
                    self.flushPendingRemoteICECandidates()
                    self.createAnswer()
                }
            }
        }
#endif
    }
    
    public func setRemoteAnswer(_ sdp: String) {
#if canImport(WebRTC)
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            guard let pc = self.peerConnection else { return }
            let normalizedAnswer = Self.normalizedRemoteSDP(sdp)
            if self.hasRemoteDescription || self.isSettingRemoteDescription || pc.remoteDescription != nil {
                self.hasRemoteDescription = true
                self.absorbRemoteICECandidatesFromSDP(normalizedAnswer.sdp)
                self.flushPendingRemoteICECandidates()
                self.logger.debug("ℹ️ ignore duplicate remote answer. sessionId=\(self.sessionId, privacy: .public)")
                return
            }
            let desc = RTCSessionDescription(type: .answer, sdp: normalizedAnswer.sdp)
            self.isSettingRemoteDescription = true
            let expectedLifecycleToken = self.lifecycleToken
            pc.setRemoteDescription(desc) { [weak self, weak pc] error in
                guard let self else { return }
                self.scheduleState {
                    guard let pc,
                          self.peerConnection === pc,
                          !self.isClosed,
                          self.lifecycleToken == expectedLifecycleToken else { return }
                    self.isSettingRemoteDescription = false
                    if let error {
                        if pc.signalingState == .stable || pc.remoteDescription != nil {
                            self.hasRemoteDescription = true
                            self.flushPendingRemoteICECandidates()
                            self.logger.debug("ℹ️ remote answer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
                            return
                        }
                        self.logger.error("❌ setRemoteAnswer failed: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    self.hasRemoteDescription = true
                    self.logRemoteSDPSummary(kind: "answer", sdp: normalizedAnswer.sdp)
                    self.flushPendingRemoteICECandidates()
                }
            }
        }
#endif
    }
    
    public func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
#if canImport(WebRTC)
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            let cand = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex ?? 0, sdpMid: sdpMid)
            switch Self.pendingRemoteICEPlan(
                isDuplicate: !self.trackRemoteICECandidateIfNeeded(cand),
                hasRemoteDescription: self.hasRemoteDescription,
                pendingCount: self.pendingRemoteICECandidates.count
            ) {
            case .ignoreDuplicate:
                return
            case .queueCandidate(let nextPendingCount):
                self.pendingRemoteICECandidates.append(cand)
                self.logger.debug("⏳ queue remote ICE candidate until remote description is set. sessionId=\(self.sessionId, privacy: .public) pending=\(nextPendingCount, privacy: .public)")
            case .applyImmediately:
                self.addRemoteICECandidateInternal(cand)
            }
        }
#endif
    }
    
    public func ensureScreenDataChannel() throws {
        guard !withState({ isClosed }) else { throw WebRTCError.alreadyClosed }
#if canImport(WebRTC)
        try withState {
            guard let pc = peerConnection else { throw WebRTCError.peerConnectionCreationFailed }
            if let screenDataChannel {
                screenDataChannel.delegate = self
                return
            }
            let configuration = RTCDataChannelConfiguration()
            configuration.isOrdered = true
            configuration.isNegotiated = false
            configuration.`protocol` = "screen-frame-v1"
            let channel = pc.dataChannel(forLabel: Self.screenChannelLabel, configuration: configuration)
            guard let channel else {
                throw WebRTCError.dataChannelNotReady
            }
            channel.delegate = self
            screenDataChannel = channel
        }
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    public func send(_ data: Data) throws {
        try send(data, preferScreenChannel: false, fallbackToControlChannel: false)
    }

    public func sendScreen(_ data: Data) throws {
        try send(data, preferScreenChannel: true, fallbackToControlChannel: false)
    }

    private func send(
        _ data: Data,
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool
    ) throws {
        guard !withState({ isClosed }) else { throw WebRTCError.alreadyClosed }
#if canImport(WebRTC)
        let channel = try resolvedDataChannel(
            preferScreenChannel: preferScreenChannel,
            fallbackToControlChannel: fallbackToControlChannel
        )
        try send(data, over: channel)
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    public func sendFramedPayload(_ payload: Data, maxChunkBytes: Int = 8 * 1024) throws {
        try sendFramedPayload(
            payload,
            maxChunkBytes: maxChunkBytes,
            preferScreenChannel: false,
            fallbackToControlChannel: false,
            lock: outboundFrameLock
        )
    }

    public func sendScreenFramedPayload(_ payload: Data, maxChunkBytes: Int = 8 * 1024) throws {
        try sendFramedPayload(
            payload,
            maxChunkBytes: maxChunkBytes,
            preferScreenChannel: true,
            fallbackToControlChannel: false,
            lock: outboundScreenFrameLock
        )
    }

    private func sendFramedPayload(
        _ payload: Data,
        maxChunkBytes: Int,
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool,
        lock: NSLock
    ) throws {
        let payloadLength = try Self.validateFramedPayloadParameters(
            payloadByteCount: payload.count,
            maxChunkBytes: maxChunkBytes
        )

        lock.lock()
        defer { lock.unlock() }

        var framed = Data()
        var length = payloadLength.bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(payload)
        let channel = try resolvedDataChannel(
            preferScreenChannel: preferScreenChannel,
            fallbackToControlChannel: fallbackToControlChannel
        )

        var offset = 0
        while offset < framed.count {
            let end = min(offset + maxChunkBytes, framed.count)
            let chunk = Data(framed[offset..<end])
            try send(chunk, over: channel)
            offset = end
        }
    }

    public func sendFramedPayloadAsync(
        _ payload: Data,
        maxChunkBytes: Int = 8 * 1024,
        maxBufferedAmountBytes: UInt64 = 16 * 1024,
        pollInterval: Duration = .milliseconds(10),
        drainTimeout: Duration = .seconds(5)
    ) async throws {
        try await sendFramedPayloadAsync(
            payload,
            maxChunkBytes: maxChunkBytes,
            maxBufferedAmountBytes: maxBufferedAmountBytes,
            pollInterval: pollInterval,
            drainTimeout: drainTimeout,
            preferScreenChannel: false,
            fallbackToControlChannel: false,
            gate: outboundFrameGate
        )
    }

    public func sendScreenFramedPayloadAsync(
        _ payload: Data,
        maxChunkBytes: Int = 8 * 1024,
        maxBufferedAmountBytes: UInt64 = 16 * 1024,
        pollInterval: Duration = .milliseconds(10),
        drainTimeout: Duration = .seconds(5)
    ) async throws {
        try await sendFramedPayloadAsync(
            payload,
            maxChunkBytes: maxChunkBytes,
            maxBufferedAmountBytes: maxBufferedAmountBytes,
            pollInterval: pollInterval,
            drainTimeout: drainTimeout,
            preferScreenChannel: true,
            fallbackToControlChannel: false,
            gate: outboundScreenFrameGate
        )
    }

    public func sendScreenChunkedPayloadAsync(
        _ payload: Data,
        maxChunkBytes: Int = 16 * 1024,
        maxBufferedAmountBytes: UInt64 = 16 * 1024,
        pollInterval: Duration = .milliseconds(10),
        drainTimeout: Duration = .seconds(5)
    ) async throws -> UInt64 {
        return try await outboundScreenFrameGate.run {
            let channel = try resolvedDataChannel(
                preferScreenChannel: true,
                fallbackToControlChannel: false
            )
            let frameBudget = try Self.validateScreenChunkedWholeFrameBudget(
                payloadByteCount: payload.count,
                maxChunkBytes: maxChunkBytes,
                bufferedAmountBytes: dataChannelBufferedAmountBytes(for: channel),
                maxBufferedAmountBytes: maxBufferedAmountBytes
            )
            let frameId = withState {
                let id = nextScreenChunkedFrameId
                nextScreenChunkedFrameId &+= 1
                if nextScreenChunkedFrameId == 0 {
                    nextScreenChunkedFrameId = 1
                }
                return id
            }
            let maxPayloadBytes = maxChunkBytes - Self.screenChunkHeaderByteCount
            let chunkCount = frameBudget.chunkCount

            var offset = 0
            for chunkIndex in 0..<chunkCount {
                let end = min(offset + maxPayloadBytes, payload.count)
                let fragment = Data(payload[offset..<end])
                let chunk = try Self.encodeScreenChunkEnvelope(
                    frameId: frameId,
                    chunkIndex: chunkIndex,
                    chunkCount: chunkCount,
                    totalBytes: payload.count,
                    chunkOffset: offset,
                    payload: fragment
                )
                try send(chunk, over: channel)
                offset = end
            }

            return frameId
        }
    }

    private func sendFramedPayloadAsync(
        _ payload: Data,
        maxChunkBytes: Int,
        maxBufferedAmountBytes: UInt64,
        pollInterval: Duration,
        drainTimeout: Duration,
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool,
        gate: WebRTCOutboundFrameGate
    ) async throws {
        let payloadLength = try Self.validateFramedPayloadParameters(
            payloadByteCount: payload.count,
            maxChunkBytes: maxChunkBytes
        )

        try await gate.run {
            var framed = Data()
            var length = payloadLength.bigEndian
            framed.append(Data(bytes: &length, count: 4))
            framed.append(payload)
            let channel = try resolvedDataChannel(
                preferScreenChannel: preferScreenChannel,
                fallbackToControlChannel: fallbackToControlChannel
            )

            var offset = 0
            while offset < framed.count {
                try await waitForBufferedAmountBelow(
                    maxBufferedAmountBytes,
                    pollInterval: pollInterval,
                    timeout: drainTimeout,
                    channel: channel
                )
                let end = min(offset + maxChunkBytes, framed.count)
                let chunk = Data(framed[offset..<end])
                try send(chunk, over: channel)
                offset = end
            }

            try await waitForBufferedAmountBelow(
                maxBufferedAmountBytes,
                pollInterval: pollInterval,
                timeout: drainTimeout,
                channel: channel
            )
        }
    }

    public func dataChannelBufferedAmountBytes() -> UInt64 {
        dataChannelBufferedAmountBytes(preferScreenChannel: false, fallbackToControlChannel: false)
    }

    public func screenDataChannelBufferedAmountBytes() -> UInt64 {
        dataChannelBufferedAmountBytes(preferScreenChannel: true, fallbackToControlChannel: true)
    }

    public var supportsNativeScreenVideoTrack: Bool {
#if canImport(WebRTC)
        withState {
            prefersNativeOutgoingScreenTrack
                && localVideoTrack != nil
                && localVideoSource != nil
                && localVideoCapturer != nil
        }
#else
        false
#endif
    }

    public var supportsNativeSystemAudioTrack: Bool {
#if canImport(WebRTC)
        withState {
            prefersNativeOutgoingAudioTrack
                && localAudioTrack != nil
                && localAudioSource != nil
                && localAudioTransceiver != nil
        }
#else
        false
#endif
    }

    public func prepareOutgoingScreenVideo(
        width: Int,
        height: Int,
        fps: Int,
        disallowQualityDegradation: Bool = false
    ) {
#if canImport(WebRTC)
        guard let localVideoSource = withState({ self.localVideoSource }) else { return }
        guard ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_DIAGNOSTIC_SKIP_ADAPT_OUTPUT_FORMAT"] != "1" else {
            withState {
                lastOutgoingNativeVideoTargetWidth = max(1, width)
                lastOutgoingNativeVideoTargetHeight = max(1, height)
                lastOutgoingNativeVideoTargetFPS = max(1, fps)
                lastOutgoingNativeVideoDisallowQualityDegradation = disallowQualityDegradation
            }
            return
        }
        let clampedFPS = max(1, fps)
        let targetWidth = max(1, width)
        let targetHeight = max(1, height)
        let adaptedWidth = WebRTCNativeScreenVideoValuePolicy.evenBackingDimension(targetWidth)
        let adaptedHeight = WebRTCNativeScreenVideoValuePolicy.evenBackingDimension(targetHeight)
        var shouldUpdateNativeVideoFormat = false
        withState {
            shouldUpdateNativeVideoFormat =
                lastOutgoingNativeVideoTargetWidth != targetWidth
                || lastOutgoingNativeVideoTargetHeight != targetHeight
                || lastOutgoingNativeVideoTargetFPS != clampedFPS
                || lastOutgoingNativeVideoDisallowQualityDegradation != disallowQualityDegradation
            if shouldUpdateNativeVideoFormat {
                lastOutgoingNativeVideoTargetWidth = targetWidth
                lastOutgoingNativeVideoTargetHeight = targetHeight
                lastOutgoingNativeVideoTargetFPS = clampedFPS
                lastOutgoingNativeVideoDisallowQualityDegradation = disallowQualityDegradation
                if let sender = localVideoTransceiver?.sender {
                    configureOutgoingScreenSenderParametersIfNeeded(sender)
                }
            }
        }
        guard shouldUpdateNativeVideoFormat else { return }
        localVideoSource.adaptOutputFormat(
            toWidth: Int32(adaptedWidth),
            height: Int32(adaptedHeight),
            fps: Int32(clampedFPS)
        )
#endif
    }

    public func pushVideoFrame(pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
        pushVideoFrame(
            pixelBuffer: pixelBuffer,
            rawTimeStampNs: timeStampNs,
            timeStampNs: timeStampNs
        )
    }

    public func pushVideoFrame(
        pixelBuffer: CVPixelBuffer,
        rawTimeStampNs: Int64,
        timeStampNs: Int64
    ) {
#if canImport(WebRTC)
        let pipeline = withState {
            (
                localVideoSource,
                localVideoCapturer,
                localVideoTrack != nil,
                localVideoSource != nil,
                localVideoCapturer != nil
            )
        }
        guard let localVideoSource = pipeline.0,
              let localVideoCapturer = pipeline.1 else {
            let shouldLogMissing = withState {
                if didLogMissingOutgoingNativeVideoPipeline {
                    return false
                }
                didLogMissingOutgoingNativeVideoPipeline = true
                return true
            }
            if shouldLogMissing {
                logger.warning(
                    """
                    ⚠️ native WebRTC screen frame dropped: outgoing pipeline not ready. \
                    sessionId=\(self.sessionId, privacy: .public) \
                    trackReady=\(pipeline.2, privacy: .public) \
                    sourceReady=\(pipeline.3, privacy: .public) \
                    capturerReady=\(pipeline.4, privacy: .public)
                    """
                )
            }
            return
        }
        withState {
            didLogMissingOutgoingNativeVideoPipeline = false
        }
        let normalizedFrame: WebRTCNativeScreenVideoFrameNormalizer.NormalizedFrame
        do {
            normalizedFrame = try nativeScreenVideoFrameNormalizer.normalize(
                pixelBuffer,
                rawTimestampNs: rawTimeStampNs
            )
        } catch {
            logger.error(
                "❌ native WebRTC screen frame dropped: pixel format normalization failed. sessionId=\(self.sessionId, privacy: .public) rawPixelFormat=\(CVPixelBufferGetPixelFormatType(pixelBuffer), privacy: .public) size=\(CVPixelBufferGetWidth(pixelBuffer), privacy: .public)x\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
        autoreleasepool {
            let submittedTimestamp = monotonicOutgoingNativeVideoTimestamp(
                rawTimestampNs: rawTimeStampNs,
                preferredTimestampNs: timeStampNs
            )
            let submittedPixelBuffer = normalizedFrame.pixelBuffer
            let buffer: RTCCVPixelBuffer
            if normalizedFrame.requiresVisibleCrop,
               ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_USE_VISIBLE_CROP_METADATA"] == "1" {
                buffer = RTCCVPixelBuffer(
                    pixelBuffer: submittedPixelBuffer,
                    adaptedWidth: Int32(normalizedFrame.visibleWidth),
                    adaptedHeight: Int32(normalizedFrame.visibleHeight),
                    cropWidth: Int32(normalizedFrame.visibleWidth),
                    cropHeight: Int32(normalizedFrame.visibleHeight),
                    cropX: 0,
                    cropY: 0
                )
            } else {
                buffer = RTCCVPixelBuffer(pixelBuffer: submittedPixelBuffer)
            }
            let frame = RTCVideoFrame(
                buffer: buffer,
                rotation: ._0,
                timeStampNs: submittedTimestamp.timestampNs
            )
            let shouldLogFirstFrame = withState {
                lastOutgoingNativeVideoFrameWidth = normalizedFrame.visibleWidth
                lastOutgoingNativeVideoFrameHeight = normalizedFrame.visibleHeight
                lastOutgoingNativeVideoSubmittedFrameWidth = CVPixelBufferGetWidth(submittedPixelBuffer)
                lastOutgoingNativeVideoSubmittedFrameHeight = CVPixelBufferGetHeight(submittedPixelBuffer)
                lastOutgoingNativeVideoRawPixelFormat = normalizedFrame.rawPixelFormat
                lastOutgoingNativeVideoSubmittedPixelFormat = normalizedFrame.submittedPixelFormat
                lastOutgoingNativeVideoSubmittedBytesPerRow = Self.pixelBufferPrimaryBytesPerRow(submittedPixelBuffer)
                lastOutgoingNativeVideoSubmittedHasIOSurface = CVPixelBufferGetIOSurface(submittedPixelBuffer) != nil
                lastOutgoingNativeVideoFrameWasNormalized = normalizedFrame.wasNormalized
                if didLogOutgoingNativeVideoFrame {
                    return false
                }
                didLogOutgoingNativeVideoFrame = true
                return true
            }
            if shouldLogFirstFrame {
                logger.info(
                    "🎥 submitting first native WebRTC screen frame. sessionId=\(self.sessionId, privacy: .public) size=\(normalizedFrame.visibleWidth, privacy: .public)x\(normalizedFrame.visibleHeight, privacy: .public) codedSize=\(CVPixelBufferGetWidth(submittedPixelBuffer), privacy: .public)x\(CVPixelBufferGetHeight(submittedPixelBuffer), privacy: .public) crop=\(normalizedFrame.requiresVisibleCrop, privacy: .public) rawPixelFormat=\(normalizedFrame.rawPixelFormat, privacy: .public) submittedPixelFormat=\(normalizedFrame.submittedPixelFormat, privacy: .public) bytesPerRow=\(Self.pixelBufferPrimaryBytesPerRow(submittedPixelBuffer), privacy: .public) iosurface=\(CVPixelBufferGetIOSurface(submittedPixelBuffer) != nil, privacy: .public) normalized=\(normalizedFrame.wasNormalized, privacy: .public) rawTimestampNs=\(submittedTimestamp.rawTimestampNs, privacy: .public) timestampNs=\(submittedTimestamp.timestampNs, privacy: .public) timestampAdjusted=\(submittedTimestamp.wasAdjusted, privacy: .public)"
                )
            }
            localVideoSource.capturer(localVideoCapturer, didCapture: frame)
        }
        let progress = withState { () -> (shouldLog: Bool, count: UInt64) in
            outgoingNativeVideoFrameCount &+= 1
            if normalizedFrame.wasNormalized {
                outgoingNativeVideoNormalizedFrameCount &+= 1
            }
            let now = Date()
            guard now.timeIntervalSince(lastOutgoingNativeVideoFrameLogAt) >= 2.0 else {
                return (false, outgoingNativeVideoFrameCount)
            }
            lastOutgoingNativeVideoFrameLogAt = now
            return (true, outgoingNativeVideoFrameCount)
        }
        if progress.shouldLog {
            let snapshot = nativeScreenVideoSendSnapshot()
            logger.info(
                "📈 native WebRTC screen frames submitted: sessionId=\(self.sessionId, privacy: .public) count=\(progress.count, privacy: .public) normalized=\(snapshot.normalizedFrames, privacy: .public) trackEnabled=\(snapshot.trackEnabled, privacy: .public) sourceReady=\(snapshot.sourceReady, privacy: .public) capturerReady=\(snapshot.capturerReady, privacy: .public) transceiverReady=\(snapshot.transceiverReady, privacy: .public) direction=\(snapshot.transceiverDirection ?? "-", privacy: .public) currentDirection=\(snapshot.negotiatedTransceiverDirection ?? "-", privacy: .public) targetVisible=\(snapshot.targetWidth, privacy: .public)x\(snapshot.targetHeight, privacy: .public)@\(snapshot.targetFPS, privacy: .public) lastFrame=\(snapshot.lastFrameWidth, privacy: .public)x\(snapshot.lastFrameHeight, privacy: .public) visibleFrame=\(snapshot.lastFrameWidth, privacy: .public)x\(snapshot.lastFrameHeight, privacy: .public) codedFrame=\(snapshot.lastSubmittedFrameWidth, privacy: .public)x\(snapshot.lastSubmittedFrameHeight, privacy: .public) rawPixelFormat=\(snapshot.lastRawFramePixelFormat.map(String.init) ?? "-", privacy: .public) submittedPixelFormat=\(snapshot.lastSubmittedFramePixelFormat.map(String.init) ?? "-", privacy: .public) pixelFormat=\(snapshot.lastFramePixelFormat.map(String.init) ?? "-", privacy: .public) bytesPerRow=\(snapshot.lastSubmittedFrameBytesPerRow, privacy: .public) iosurface=\(snapshot.lastSubmittedFrameHasIOSurface, privacy: .public) frameNormalized=\(snapshot.lastFrameWasNormalized, privacy: .public) rawTimestampNs=\(snapshot.lastRawFrameTimestampNs.map(String.init) ?? "-", privacy: .public) rawDeltaNs=\(snapshot.lastRawFrameTimestampDeltaNs.map(String.init) ?? "-", privacy: .public) timestampNs=\(snapshot.lastFrameTimestampNs.map(String.init) ?? "-", privacy: .public) timestampDeltaNs=\(snapshot.lastFrameTimestampDeltaNs.map(String.init) ?? "-", privacy: .public) timestampAdjusted=\(snapshot.lastFrameTimestampWasAdjusted, privacy: .public)"
            )
        }
#endif
    }

    public func pushDiagnosticSyntheticNativeVideoFrame(
        width: Int,
        height: Int,
        fps: Int,
        frameIndex: UInt64
    ) throws {
#if canImport(WebRTC)
        let alignedWidth = max(2, width - (width % 2))
        let alignedHeight = max(2, height - (height % 2))
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: alignedWidth,
            kCVPixelBufferHeightKey as String: alignedHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            alignedWidth,
            alignedHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw NSError(
                domain: "com.skybridge.webrtc.synthetic-native-video",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed with status \(status)"]
            )
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw NSError(
                domain: "com.skybridge.webrtc.synthetic-native-video",
                code: Int(lockStatus),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferLockBaseAddress failed with status \(lockStatus)"]
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let lumaValue = Int32(32 + Int(frameIndex % 160))
        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 {
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
                memset(
                    yBase,
                    lumaValue,
                    CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                        * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                )
            }
            if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
                memset(
                    uvBase,
                    128,
                    CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                        * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
                )
            }
        } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(
                base,
                lumaValue,
                CVPixelBufferGetBytesPerRow(pixelBuffer) * alignedHeight
            )
        }

        prepareOutgoingScreenVideo(
            width: alignedWidth,
            height: alignedHeight,
            fps: fps,
            disallowQualityDegradation: true
        )
        let timestampNs = Int64((ProcessInfo.processInfo.systemUptime * 1_000_000_000.0).rounded())
        pushVideoFrame(pixelBuffer: pixelBuffer, timeStampNs: timestampNs)
#else
        _ = width
        _ = height
        _ = fps
        _ = frameIndex
#endif
    }

    private static func pixelBufferPrimaryBytesPerRow(_ pixelBuffer: CVPixelBuffer) -> Int {
        if CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) > 0 {
            return CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        }
        return CVPixelBufferGetBytesPerRow(pixelBuffer)
    }

    private struct OutgoingNativeVideoTimestamp: Sendable {
        let rawTimestampNs: Int64
        let timestampNs: Int64
        let wasAdjusted: Bool
    }

    private func monotonicOutgoingNativeVideoTimestamp(
        rawTimestampNs: Int64,
        preferredTimestampNs: Int64
    ) -> OutgoingNativeVideoTimestamp {
        withState {
            let sanitizedRaw = max(0, rawTimestampNs)
            let sanitizedPreferred = max(0, preferredTimestampNs)
            let frameDurationNs = Int64(
                max(
                    1,
                    1_000_000_000 / max(1, lastOutgoingNativeVideoTargetFPS)
                )
            )
            let previous = lastOutgoingNativeVideoTimestampNs ?? -frameDurationNs
            let previousRaw = lastOutgoingNativeVideoRawTimestampNs
            let minimumNext = previous + frameDurationNs
            let submitted = max(sanitizedPreferred, minimumNext)
            lastOutgoingNativeVideoRawTimestampNs = sanitizedRaw
            lastOutgoingNativeVideoTimestampNs = submitted
            lastOutgoingNativeVideoRawTimestampDeltaNs = previousRaw.map { sanitizedRaw - $0 }
            lastOutgoingNativeVideoTimestampDeltaNs = submitted - previous
            lastOutgoingNativeVideoTimestampWasAdjusted = submitted != sanitizedRaw
            return OutgoingNativeVideoTimestamp(
                rawTimestampNs: sanitizedRaw,
                timestampNs: submitted,
                wasAdjusted: submitted != sanitizedRaw
            )
        }
    }

    public func nativeScreenVideoSendSnapshot() -> NativeScreenVideoSendSnapshot {
#if canImport(WebRTC)
        withState {
            let negotiatedDirection: String? = {
                guard let localVideoTransceiver else { return nil }
                var direction = RTCRtpTransceiverDirection.inactive
                guard localVideoTransceiver.currentDirection(&direction) else { return nil }
                return Self.transceiverDirectionLabel(direction)
            }()
            return NativeScreenVideoSendSnapshot(
                trackReady: localVideoTrack != nil,
                trackEnabled: localVideoTrack?.isEnabled == true,
                sourceReady: localVideoSource != nil,
                capturerReady: localVideoCapturer != nil,
                transceiverReady: localVideoTransceiver != nil,
                senderReady: localVideoTransceiver?.sender.track != nil,
                transceiverDirection: localVideoTransceiver.map { Self.transceiverDirectionLabel($0.direction) },
                negotiatedTransceiverDirection: negotiatedDirection,
                lastFrameWidth: lastOutgoingNativeVideoFrameWidth,
                lastFrameHeight: lastOutgoingNativeVideoFrameHeight,
                lastSubmittedFrameWidth: lastOutgoingNativeVideoSubmittedFrameWidth,
                lastSubmittedFrameHeight: lastOutgoingNativeVideoSubmittedFrameHeight,
                lastRawFramePixelFormat: lastOutgoingNativeVideoRawPixelFormat,
                lastFramePixelFormat: lastOutgoingNativeVideoSubmittedPixelFormat,
                lastSubmittedFramePixelFormat: lastOutgoingNativeVideoSubmittedPixelFormat,
                lastSubmittedFrameBytesPerRow: lastOutgoingNativeVideoSubmittedBytesPerRow,
                lastSubmittedFrameHasIOSurface: lastOutgoingNativeVideoSubmittedHasIOSurface,
                lastFrameWasNormalized: lastOutgoingNativeVideoFrameWasNormalized,
                lastRawFrameTimestampNs: lastOutgoingNativeVideoRawTimestampNs,
                lastFrameTimestampNs: lastOutgoingNativeVideoTimestampNs,
                lastRawFrameTimestampDeltaNs: lastOutgoingNativeVideoRawTimestampDeltaNs,
                lastFrameTimestampDeltaNs: lastOutgoingNativeVideoTimestampDeltaNs,
                lastFrameTimestampWasAdjusted: lastOutgoingNativeVideoTimestampWasAdjusted,
                targetWidth: lastOutgoingNativeVideoTargetWidth,
                targetHeight: lastOutgoingNativeVideoTargetHeight,
                targetFPS: lastOutgoingNativeVideoTargetFPS,
                normalizedFrames: outgoingNativeVideoNormalizedFrameCount,
                submittedFrames: outgoingNativeVideoFrameCount
            )
        }
#else
        NativeScreenVideoSendSnapshot(
            trackReady: false,
            trackEnabled: false,
            sourceReady: false,
            capturerReady: false,
            transceiverReady: false,
            senderReady: false,
            transceiverDirection: nil,
            negotiatedTransceiverDirection: nil,
            lastFrameWidth: 0,
            lastFrameHeight: 0,
            lastSubmittedFrameWidth: 0,
            lastSubmittedFrameHeight: 0,
            lastRawFramePixelFormat: nil,
            lastFramePixelFormat: nil,
            lastSubmittedFramePixelFormat: nil,
            lastSubmittedFrameBytesPerRow: 0,
            lastSubmittedFrameHasIOSurface: false,
            lastFrameWasNormalized: false,
            lastRawFrameTimestampNs: nil,
            lastFrameTimestampNs: nil,
            lastRawFrameTimestampDeltaNs: nil,
            lastFrameTimestampDeltaNs: nil,
            lastFrameTimestampWasAdjusted: false,
            targetWidth: 0,
            targetHeight: 0,
            targetFPS: 0,
            normalizedFrames: 0,
            submittedFrames: 0
        )
#endif
    }

    @discardableResult
    public func refreshOutgoingScreenVideoSender(reason: String) -> Bool {
#if canImport(WebRTC)
        withState {
            guard prefersNativeOutgoingScreenTrack,
                  !isClosed else {
                return false
            }
            guard let localVideoTransceiver,
                  let localVideoTrack,
                  localVideoSource != nil,
                  localVideoCapturer != nil else {
                logger.warning("⚠️ native WebRTC screen refresh skipped: pipeline missing. sessionId=\(self.sessionId, privacy: .public) reason=\(reason, privacy: .public)")
                return false
            }
            localVideoTrack.isEnabled = true
            if localVideoTransceiver.direction != .sendOnly {
                setTransceiverDirection(.sendOnly, on: localVideoTransceiver)
            }
            configureOutgoingScreenSenderParametersIfNeeded(localVideoTransceiver.sender)
            logger.warning("🔧 native WebRTC screen sender refreshed without renegotiation. sessionId=\(self.sessionId, privacy: .public) reason=\(reason, privacy: .public)")
            return true
        }
#else
        false
#endif
    }

    public func outgoingNativeScreenVideoRTCStats() async -> NativeScreenVideoRTCStats {
#if canImport(WebRTC)
        guard let peerConnection = withState({ self.peerConnection }) else {
            return .empty
        }
        return await withCheckedContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false

                func resume(
                    _ stats: NativeScreenVideoRTCStats,
                    continuation: CheckedContinuation<NativeScreenVideoRTCStats, Never>
                ) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: stats)
                }
            }

            let state = ResumeState()
            peerConnection.statistics { report in
                state.resume(Self.nativeScreenVideoRTCStats(from: report), continuation: continuation)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                state.resume(
                    .empty,
                    continuation: continuation
                )
            }
        }
#else
        return .empty
#endif
    }

    public func setOutgoingSystemAudioTrackEnabled(_ enabled: Bool) {
#if canImport(WebRTC)
        withState {
            localAudioTrack?.isEnabled = enabled
        }
#endif
    }

    private func dataChannelBufferedAmountBytes(
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool
    ) -> UInt64 {
#if canImport(WebRTC)
        withState {
            if preferScreenChannel,
               let screenDataChannel,
               screenDataChannel.readyState == .open {
                return screenDataChannel.bufferedAmount
            }
            if fallbackToControlChannel || !preferScreenChannel {
                return dataChannel?.bufferedAmount ?? 0
            }
            return screenDataChannel?.bufferedAmount ?? 0
        }
#else
        return 0
#endif
    }

    private func dataChannelBufferedAmountBytes(for channel: RTCDataChannel) -> UInt64 {
#if canImport(WebRTC)
        channel.bufferedAmount
#else
        0
#endif
    }

    public func hasOpenScreenDataChannel() -> Bool {
#if canImport(WebRTC)
        withState {
            guard let screenDataChannel else { return false }
            return screenDataChannel.readyState == .open
        }
#else
        return false
#endif
    }

    public func currentICETransportPath() async -> ICETransportPath {
#if canImport(WebRTC)
        guard let peerConnection = withState({ self.peerConnection }) else { return .unknown }
        return await withCheckedContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false

                func resume(
                    _ path: ICETransportPath,
                    continuation: CheckedContinuation<ICETransportPath, Never>
                ) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: path)
                }
            }

            let state = ResumeState()

            peerConnection.statistics { report in
                state.resume(Self.detectICETransportPath(from: report), continuation: continuation)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                state.resume(.unknown, continuation: continuation)
            }
        }
#else
        return .unknown
#endif
    }

    public func currentSelectedRemoteCandidateAddress() async -> String? {
#if canImport(WebRTC)
        guard let peerConnection = withState({ self.peerConnection }) else { return nil }
        return await withCheckedContinuation { continuation in
            final class ResumeState: @unchecked Sendable {
                private let lock = NSLock()
                private var resumed = false

                func resume(
                    _ address: String?,
                    continuation: CheckedContinuation<String?, Never>
                ) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: address)
                }
            }

            let state = ResumeState()

            peerConnection.statistics { report in
                state.resume(Self.selectedRemoteCandidateAddress(from: report), continuation: continuation)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                state.resume(nil, continuation: continuation)
            }
        }
#else
        return nil
#endif
    }

    private func waitForBufferedAmountBelow(
        _ threshold: UInt64,
        pollInterval: Duration,
        timeout: Duration,
        channel: RTCDataChannel
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while dataChannelBufferedAmountBytes(for: channel) > threshold {
            if clock.now >= deadline {
                throw WebRTCError.dataChannelSendFailed
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func resolvedDataChannel(
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool
    ) throws -> RTCDataChannel {
#if canImport(WebRTC)
        try withState {
            let channel: RTCDataChannel?
            if preferScreenChannel,
               let screenDataChannel,
               screenDataChannel.readyState == .open {
                channel = screenDataChannel
            } else if fallbackToControlChannel || !preferScreenChannel {
                channel = dataChannel
            } else {
                channel = screenDataChannel
            }
            guard let channel else { throw WebRTCError.dataChannelNotReady }
            guard channel.readyState == .open else { throw WebRTCError.dataChannelNotOpen }
            return channel
        }
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    private func send(_ data: Data, over channel: RTCDataChannel) throws {
#if canImport(WebRTC)
        guard channel.readyState == .open else { throw WebRTCError.dataChannelNotOpen }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard channel.sendData(buffer) else { throw WebRTCError.dataChannelSendFailed }
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    static func validateFramedPayloadParameters(
        payloadByteCount: Int,
        maxChunkBytes: Int
    ) throws -> UInt32 {
        guard maxChunkBytes > 0 else {
            throw WebRTCError.invalidChunkSize(maxChunkBytes)
        }
        guard payloadByteCount >= 0, payloadByteCount <= Int(UInt32.max) else {
            throw WebRTCError.framedPayloadTooLarge(payloadByteCount)
        }
        return UInt32(payloadByteCount)
    }

    private func configureOutgoingScreenVideoIfNeeded(
        factory: RTCPeerConnectionFactory,
        peerConnection: RTCPeerConnection
    ) {
        guard localVideoTrack == nil else { return }

        let useGenericVideoSource =
            ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_DIAGNOSTIC_GENERIC_VIDEO_SOURCE"] == "1"
        let videoSource = useGenericVideoSource
            ? factory.videoSource()
            : factory.videoSource(forScreenCast: true)
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "screen-\(sessionId)")
        let videoCapturer = RTCVideoCapturer(delegate: videoSource)
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["screen-\(sessionId)"]

        guard let transceiver = peerConnection.addTransceiver(with: videoTrack, init: transceiverInit) else {
            logger.warning("⚠️ failed to create native screen video transceiver. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        preferNativeScreenVideoCodecIfPossible(factory: factory, transceiver: transceiver)
        configureOutgoingScreenSenderParametersIfNeeded(transceiver.sender)

        localVideoSource = videoSource
        localVideoTrack = videoTrack
        localVideoCapturer = videoCapturer
        localVideoTransceiver = transceiver
        videoTrack.isEnabled = true
        if ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_DIAGNOSTIC_SKIP_ADAPT_OUTPUT_FORMAT"] != "1" {
            videoSource.adaptOutputFormat(toWidth: 1280, height: 720, fps: 60)
        }
        logger.info(
            "🎥 native WebRTC screen track enabled. sessionId=\(self.sessionId, privacy: .public) fps=\(60, privacy: .public) sourceKind=\(useGenericVideoSource ? "generic" : "screencast", privacy: .public)"
        )
    }

    private func preferNativeScreenVideoCodecIfPossible(
        factory: RTCPeerConnectionFactory,
        transceiver: RTCRtpTransceiver
    ) {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        let preferred = WebRTCNativeScreenVideoValuePolicy.codecPreferences(from: capabilities.codecs)
        guard !preferred.isEmpty else { return }
        if let codecError = setCodecPreferences(preferred, on: transceiver) {
            logger.debug("ℹ️ failed to set H264/HEVC-only screen video codec preferences: \(codecError.localizedDescription, privacy: .public)")
        }
    }

    private func configureOutgoingScreenSenderParametersIfNeeded(_ sender: RTCRtpSender) {
        if ProcessInfo.processInfo.environment["SKYBRIDGE_WEBRTC_DIAGNOSTIC_SKIP_VIDEO_SENDER_PARAMETERS"] == "1" {
            logger.warning(
                "⚠️ skipping native screen sender parameters for diagnostic probe. sessionId=\(self.sessionId, privacy: .public)"
            )
            return
        }
        let parameters = sender.parameters
        let targetWidth = max(1, lastOutgoingNativeVideoTargetWidth)
        let targetHeight = max(1, lastOutgoingNativeVideoTargetHeight)
        let targetFPS = max(1, lastOutgoingNativeVideoTargetFPS)
        let targetBitrate = WebRTCNativeScreenVideoValuePolicy.recommendedBitrateBps(
            width: targetWidth,
            height: targetHeight,
            fps: targetFPS
        )
        let strictMinimumBitrate = WebRTCNativeScreenVideoValuePolicy.minimumExtremeBitrateBps(
            width: targetWidth,
            height: targetHeight,
            fps: targetFPS
        )
        let disallowQualityDegradation = lastOutgoingNativeVideoDisallowQualityDegradation
        let encodings = parameters.encodings.isEmpty
            ? [RTCRtpEncodingParameters()]
            : parameters.encodings
        parameters.encodings = encodings.map { encoding in
            encoding.isActive = true
            encoding.maxFramerate = NSNumber(value: targetFPS)
            encoding.maxBitrateBps = NSNumber(value: targetBitrate)
            encoding.bitratePriority = max(encoding.bitratePriority, disallowQualityDegradation ? 2.0 : 1.0)
            if disallowQualityDegradation {
                encoding.minBitrateBps = NSNumber(value: Int(strictMinimumBitrate))
                encoding.scaleResolutionDownBy = NSNumber(value: 1.0)
                encoding.numTemporalLayers = NSNumber(value: 1)
            } else {
                encoding.minBitrateBps = nil
                encoding.scaleResolutionDownBy = nil
            }
            return encoding
        }
        if disallowQualityDegradation {
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.disabled.rawValue)
        } else {
            parameters.degradationPreference = nil
        }
        sender.parameters = parameters
    }

    private func configureOutgoingSystemAudioIfNeeded(
        factory: RTCPeerConnectionFactory,
        peerConnection: RTCPeerConnection
    ) {
        guard localAudioTrack == nil else { return }

        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "system-audio-\(sessionId)")
        audioTrack.isEnabled = false
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["system-audio-\(sessionId)"]

        guard let transceiver = peerConnection.addTransceiver(with: audioTrack, init: transceiverInit) else {
            logger.warning("⚠️ failed to create native system audio transceiver. sessionId=\(self.sessionId, privacy: .public)")
            return
        }

        preferOpusCodecIfPossible(factory: factory, transceiver: transceiver)
        localAudioSource = audioSource
        localAudioTrack = audioTrack
        localAudioTransceiver = transceiver
        logger.info("🎧 native WebRTC system audio track enabled. sessionId=\(self.sessionId, privacy: .public)")
    }

    private func preferOpusCodecIfPossible(
        factory: RTCPeerConnectionFactory,
        transceiver: RTCRtpTransceiver
    ) {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
        let preferred = capabilities.codecs.sorted { lhs, rhs in
            let lhsIsOpus = lhs.name.caseInsensitiveCompare("opus") == .orderedSame
            let rhsIsOpus = rhs.name.caseInsensitiveCompare("opus") == .orderedSame
            if lhsIsOpus != rhsIsOpus {
                return lhsIsOpus && !rhsIsOpus
            }
            let lhsChannels = lhs.numChannels?.intValue ?? 0
            let rhsChannels = rhs.numChannels?.intValue ?? 0
            if lhsChannels != rhsChannels {
                return lhsChannels > rhsChannels
            }
            return lhs.name < rhs.name
        }
        guard !preferred.isEmpty else { return }
        if let codecError = setCodecPreferences(preferred, on: transceiver) {
            logger.debug("ℹ️ failed to set Opus-first audio codec preferences: \(codecError.localizedDescription, privacy: .public)")
        }
    }

    private func setCodecPreferences(
        _ codecs: [RTCRtpCodecCapability],
        on transceiver: RTCRtpTransceiver
    ) -> NSError? {
        let selector = NSSelectorFromString("setCodecPreferences:error:")
        guard transceiver.responds(to: selector) else {
            return nil
        }

        typealias Method = @convention(c) (
            AnyObject,
            Selector,
            NSArray?,
            UnsafeMutablePointer<NSError?>?
        ) -> Bool

        let implementation = transceiver.method(for: selector)
        let function = unsafeBitCast(implementation, to: Method.self)
        var error: NSError?
        let succeeded = function(transceiver, selector, codecs as NSArray, &error)
        guard !succeeded else { return nil }
        return error ?? NSError(
            domain: "com.skybridge.webrtc",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unknown codec preference error"]
        )
    }

    private func setTransceiverDirection(
        _ direction: RTCRtpTransceiverDirection,
        on transceiver: RTCRtpTransceiver
    ) {
        let selector = NSSelectorFromString("setDirection:error:")
        guard transceiver.responds(to: selector) else {
            logger.debug("ℹ️ transceiver does not expose setDirection:error:. sessionId=\(self.sessionId, privacy: .public)")
            return
        }

        typealias Method = @convention(c) (
            AnyObject,
            Selector,
            RTCRtpTransceiverDirection,
            UnsafeMutablePointer<NSError?>?
        ) -> Void

        let implementation = transceiver.method(for: selector)
        let function = unsafeBitCast(implementation, to: Method.self)
        var error: NSError?
        function(transceiver, selector, direction, &error)
        if let error {
            logger.debug("ℹ️ failed to refresh transceiver direction: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func offerToReceiveVideoConstraintValue(hasNegotiatedVideoTransceiver: Bool) -> String {
        hasNegotiatedVideoTransceiver ? "true" : "false"
    }

#if canImport(WebRTC)
    private static func transceiverDirectionLabel(_ direction: RTCRtpTransceiverDirection) -> String {
        switch direction {
        case .sendRecv:
            return "sendrecv"
        case .sendOnly:
            return "sendonly"
        case .recvOnly:
            return "recvonly"
        case .inactive:
            return "inactive"
        case .stopped:
            return "stopped"
        @unknown default:
            return "unknown"
        }
    }

    private func trackRemoteICECandidateIfNeeded(_ candidate: RTCIceCandidate) -> Bool {
        let normalizedSDP: String
        if candidate.sdp.hasPrefix("a=") {
            normalizedSDP = String(candidate.sdp.dropFirst(2))
        } else {
            normalizedSDP = candidate.sdp
        }
        let mid = candidate.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = "\(candidate.sdpMLineIndex)|\(mid)|\(normalizedSDP)"
        return seenRemoteICECandidateKeys.insert(key).inserted
    }

    private func addRemoteICECandidateInternal(_ candidate: RTCIceCandidate) {
        guard let pc = peerConnection else { return }
        pc.add(candidate) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("⚠️ addIceCandidate failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flushPendingRemoteICECandidates() {
        guard hasRemoteDescription else { return }
        guard !pendingRemoteICECandidates.isEmpty else { return }

        let pending = pendingRemoteICECandidates
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        logger.info("🔄 applying queued remote ICE candidates. sessionId=\(self.sessionId, privacy: .public) count=\(pending.count, privacy: .public)")
        for candidate in pending {
            addRemoteICECandidateInternal(candidate)
        }
    }

    private func absorbRemoteICECandidatesFromSDP(_ sdp: String) {
        let extracted = Self.extractRemoteICECandidates(from: sdp)
        guard !extracted.isEmpty else { return }

        var absorbed = 0
        for candidate in extracted where trackRemoteICECandidateIfNeeded(candidate) {
            absorbed += 1
            if hasRemoteDescription {
                addRemoteICECandidateInternal(candidate)
            } else {
                pendingRemoteICECandidates.append(candidate)
            }
        }

        guard absorbed > 0 else { return }
        logger.info("🔄 absorbed ICE candidates from duplicate SDP. sessionId=\(self.sessionId, privacy: .public) count=\(absorbed, privacy: .public)")
    }

    private static func normalizedRemoteSDP(
        _ sdp: String
    ) -> (
        sdp: String,
        droppedSessionLevelCandidateLines: Int,
        deduplicatedCandidateLines: Int
    ) {
        let normalizedNewlines = sdp.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalizedNewlines
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var prefix: [String] = []
        var sections: [[String]] = []
        var currentSection: [String]? = nil
        var droppedSessionLevelCandidateLines = 0
        var deduplicatedCandidateLines = 0

        for line in rawLines {
            if line.hasPrefix("m=") {
                if let currentSection {
                    sections.append(currentSection)
                }
                currentSection = [line]
                continue
            }

            if currentSection != nil {
                currentSection?.append(line)
                continue
            }

            if line.hasPrefix("a=candidate:") || line == "a=end-of-candidates" {
                droppedSessionLevelCandidateLines += 1
                continue
            }
            if !line.isEmpty {
                prefix.append(line)
            }
        }

        if let currentSection {
            sections.append(currentSection)
        }

        var cleanedSections: [[String]] = []
        cleanedSections.reserveCapacity(sections.count)
        for section in sections {
            var seenCandidateLines = Set<String>()
            var cleanedSection: [String] = []
            cleanedSection.reserveCapacity(section.count)

            for line in section {
                guard !line.isEmpty else { continue }
                if line.hasPrefix("a=candidate:") {
                    if !seenCandidateLines.insert(line).inserted {
                        deduplicatedCandidateLines += 1
                        continue
                    }
                }
                if line == "a=end-of-candidates",
                   cleanedSection.last == "a=end-of-candidates" {
                    deduplicatedCandidateLines += 1
                    continue
                }
                cleanedSection.append(line)
            }
            cleanedSections.append(cleanedSection)
        }

        var flattened = prefix
        for section in cleanedSections {
            flattened.append(contentsOf: section)
        }

        let rendered = flattened.joined(separator: "\r\n") + "\r\n"
        return (
            sdp: rendered,
            droppedSessionLevelCandidateLines: droppedSessionLevelCandidateLines,
            deduplicatedCandidateLines: deduplicatedCandidateLines
        )
    }

    private static func extractRemoteICECandidates(from sdp: String) -> [RTCIceCandidate] {
        let normalizedLines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var candidates: [RTCIceCandidate] = []
        var currentMid: String?
        var currentMLineIndex: Int32 = -1

        for line in normalizedLines {
            if line.hasPrefix("m=") {
                currentMLineIndex += 1
                currentMid = nil
                continue
            }
            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst(6))
                continue
            }
            if line.hasPrefix("a=candidate:"), currentMLineIndex >= 0 {
                let candidateSDP = String(line.dropFirst(2))
                candidates.append(
                    RTCIceCandidate(
                        sdp: candidateSDP,
                        sdpMLineIndex: currentMLineIndex,
                        sdpMid: currentMid
                    )
                )
            }
        }

        return candidates
    }

    private func localSDPWithNativeScreenH264ConstraintsIfNeeded(
        _ sdp: String,
        kind: String
    ) -> String {
        guard prefersNativeOutgoingScreenTrack,
              WebRTCNativeScreenVideoValuePolicy.h264SDPConstraintsEnabled() else { return sdp }
        let constrained = Self.sdpWithNativeScreenH264LevelSupport(
            sdp,
            requiredLevelHex: WebRTCNativeScreenVideoValuePolicy.extremeH264LevelHex,
            maxFS: WebRTCNativeScreenVideoValuePolicy.extremeH264MaxFS,
            maxMBPS: WebRTCNativeScreenVideoValuePolicy.extremeH264MaxMBPS
        )
        guard constrained != sdp else { return sdp }
        _onTrace?(
            """
            local-sdp-h264-extreme-constraints session=\(sessionId) \
            kind=\(kind) \
            level=\(WebRTCNativeScreenVideoValuePolicy.extremeH264LevelHex) \
            maxFS=\(WebRTCNativeScreenVideoValuePolicy.extremeH264MaxFS) \
            maxMBPS=\(WebRTCNativeScreenVideoValuePolicy.extremeH264MaxMBPS)
            """
        )
        return constrained
    }

    private func createOffer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                // Keep the negotiated video m-line alive whenever we've attached
                // a native screen-video transceiver; hardcoding false here can
                // suppress the remote track on the viewer side.
                "OfferToReceiveVideo": Self.offerToReceiveVideoConstraintValue(
                    hasNegotiatedVideoTransceiver: localVideoTransceiver != nil
                ),
            ],
            optionalConstraints: nil
        )
        pc.offer(for: constraints) { [weak self, weak pc] sdp, error in
            guard let self else { return }
            let expectedLifecycleToken = self.withState { self.lifecycleToken }
            self.scheduleState {
                guard let pc,
                      Self.lifecycleGuardAllowsCallback(
                        peerConnectionMatches: self.peerConnection === pc,
                        isClosed: self.isClosed,
                        currentLifecycleToken: self.lifecycleToken,
                        expectedLifecycleToken: expectedLifecycleToken
                      ) else { return }
                if let error {
                    self.logger.error("❌ offer failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let sdp else { return }
                let rawSDPString = sdp.sdp
                let sdpString = self.localSDPWithNativeScreenH264ConstraintsIfNeeded(
                    rawSDPString,
                    kind: "offer"
                )
                let localDescription = sdpString == rawSDPString
                    ? sdp
                    : RTCSessionDescription(type: .offer, sdp: sdpString)
                pc.setLocalDescription(localDescription) { [weak self, weak pc] err in
                    guard let self else { return }
                    self.scheduleState {
                        guard let pc,
                              Self.lifecycleGuardAllowsCallback(
                                peerConnectionMatches: self.peerConnection === pc,
                                isClosed: self.isClosed,
                                currentLifecycleToken: self.lifecycleToken,
                                expectedLifecycleToken: expectedLifecycleToken
                              ) else { return }
                        if let err {
                            self.logger.error("❌ setLocalDescription(offer) failed: \(err.localizedDescription, privacy: .public)")
                            return
                        }
                        self.logLocalSDPSummary(kind: "offer", sdp: sdpString)
                        self.lastEmittedLocalSDP = sdpString
                        let handler = self.onLocalOffer
                        self.dispatchCallback {
                            handler?(sdpString)
                        }
                    }
                }
            }
        }
    }
    
    private func createAnswer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": Self.offerToReceiveVideoConstraintValue(
                    hasNegotiatedVideoTransceiver: localVideoTransceiver != nil
                ),
            ],
            optionalConstraints: nil
        )
        pc.answer(for: constraints) { [weak self, weak pc] sdp, error in
            guard let self else { return }
            let expectedLifecycleToken = self.withState { self.lifecycleToken }
            self.scheduleState {
                guard let pc,
                      Self.lifecycleGuardAllowsCallback(
                        peerConnectionMatches: self.peerConnection === pc,
                        isClosed: self.isClosed,
                        currentLifecycleToken: self.lifecycleToken,
                        expectedLifecycleToken: expectedLifecycleToken
                      ) else { return }
                if let error {
                    self.logger.error("❌ answer failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let sdp else { return }
                let rawSDPString = sdp.sdp
                let sdpString = self.localSDPWithNativeScreenH264ConstraintsIfNeeded(
                    rawSDPString,
                    kind: "answer"
                )
                let localDescription = sdpString == rawSDPString
                    ? sdp
                    : RTCSessionDescription(type: .answer, sdp: sdpString)
                pc.setLocalDescription(localDescription) { [weak self, weak pc] err in
                    guard let self else { return }
                    self.scheduleState {
                        guard let pc,
                              Self.lifecycleGuardAllowsCallback(
                                peerConnectionMatches: self.peerConnection === pc,
                                isClosed: self.isClosed,
                                currentLifecycleToken: self.lifecycleToken,
                                expectedLifecycleToken: expectedLifecycleToken
                              ) else { return }
                        if let err {
                            self.logger.error("❌ setLocalDescription(answer) failed: \(err.localizedDescription, privacy: .public)")
                            return
                        }
                        self.logLocalSDPSummary(kind: "answer", sdp: sdpString)
                        self.lastEmittedLocalSDP = sdpString
                        let handler = self.onLocalAnswer
                        self.dispatchCallback {
                            handler?(sdpString)
                        }
                    }
                }
            }
        }
    }

    private func logLocalSDPSummary(kind: String, sdp: String) {
        let videoSummary = Self.videoSDPMediaSummary(from: sdp)
        logger.info(
            """
            📄 local SDP ready. sessionId=\(self.sessionId, privacy: .public) \
            kind=\(kind, privacy: .public) \
            hasVideo=\(videoSummary.hasVideo, privacy: .public) \
            direction=\(videoSummary.direction, privacy: .public) \
            video=\(videoSummary.description, privacy: .public) \
            nativeTrack=\(self.localVideoTrack != nil, privacy: .public) \
            nativeTransceiver=\(self.localVideoTransceiver != nil, privacy: .public)
            """
        )
        onTrace?("local-sdp-summary session=\(sessionId) kind=\(kind) video=\(videoSummary.description)")
    }

    private func logRemoteSDPSummary(kind: String, sdp: String) {
        let videoSummary = Self.videoSDPMediaSummary(from: sdp)
        logger.info(
            "📄 remote SDP applied. sessionId=\(self.sessionId, privacy: .public) kind=\(kind, privacy: .public) video=\(videoSummary.description, privacy: .public)"
        )
        onTrace?("remote-sdp-summary session=\(sessionId) kind=\(kind) video=\(videoSummary.description)")
    }

    private func emitCompletedLocalDescriptionIfNeeded() {
#if canImport(WebRTC)
        guard let localDescription = peerConnection?.localDescription else { return }
        let sdp = localDescription.sdp
        guard !sdp.isEmpty, sdp != lastEmittedLocalSDP else { return }
        lastEmittedLocalSDP = sdp
        logger.info("🔁 emitting gathered local description. sessionId=\(self.sessionId, privacy: .public) role=\(String(describing: self.role), privacy: .public)")
        logLocalSDPSummary(kind: role == .offerer ? "offer-gathered" : "answer-gathered", sdp: sdp)
        switch role {
        case .offerer:
            let handler = onLocalOffer
            dispatchCallback {
                handler?(sdp)
            }
        case .answerer:
            let handler = onLocalAnswer
            dispatchCallback {
                handler?(sdp)
            }
        }
#endif
    }

    private static func detectICETransportPath(from report: RTCStatisticsReport) -> ICETransportPath {
        let statsById = report.statistics

        func stringValue(_ stat: RTCStatistics, key: String) -> String? {
            guard let value = stat.values[key] else { return nil }
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        func boolValue(_ stat: RTCStatistics, key: String) -> Bool {
            guard let value = stat.values[key] else { return false }
            if let number = value as? NSNumber { return number.boolValue }
            if let text = value as? String {
                let lowered = text.lowercased()
                return lowered == "true" || lowered == "1"
            }
            return false
        }

        let selectedPair = statsById.values.first { stat in
            guard stat.type.lowercased() == "candidate-pair" else { return false }
            let state = stringValue(stat, key: "state")?.lowercased()
            let selected = boolValue(stat, key: "selected")
            let nominated = boolValue(stat, key: "nominated")
            return selected || (nominated && state == "succeeded")
        }

        guard let selectedPair else { return .unknown }

        let candidateIDs = [
            stringValue(selectedPair, key: "localCandidateId"),
            stringValue(selectedPair, key: "remoteCandidateId"),
        ]
        .compactMap { $0 }

        for candidateId in candidateIDs {
            guard let candidate = statsById[candidateId] else { continue }
            if stringValue(candidate, key: "candidateType")?.lowercased() == "relay" {
                return .relay
            }
        }

        return .direct
    }

    private static func selectedRemoteCandidateAddress(from report: RTCStatisticsReport) -> String? {
        let statsById = report.statistics

        func stringValue(_ stat: RTCStatistics, key: String) -> String? {
            guard let value = stat.values[key] else { return nil }
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        func boolValue(_ stat: RTCStatistics, key: String) -> Bool {
            guard let value = stat.values[key] else { return false }
            if let number = value as? NSNumber { return number.boolValue }
            if let text = value as? String {
                let lowered = text.lowercased()
                return lowered == "true" || lowered == "1"
            }
            return false
        }

        let selectedPair = statsById.values.first { stat in
            guard stat.type.lowercased() == "candidate-pair" else { return false }
            let state = stringValue(stat, key: "state")?.lowercased()
            let selected = boolValue(stat, key: "selected")
            let nominated = boolValue(stat, key: "nominated")
            return selected || (nominated && state == "succeeded")
        }
        guard let selectedPair,
              let remoteCandidateId = stringValue(selectedPair, key: "remoteCandidateId"),
              let candidate = statsById[remoteCandidateId] else {
            return nil
        }

        for key in ["address", "ip"] {
            if let value = stringValue(candidate, key: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        guard let candidateLine = stringValue(candidate, key: "candidate") else { return nil }
        let fields = candidateLine.split(separator: " ").map(String.init)
        guard fields.count > 4 else { return nil }
        let address = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? nil : address
    }

    private static func nativeScreenVideoRTCStats(from report: RTCStatisticsReport) -> NativeScreenVideoRTCStats {
        let statsById = report.statistics

        func stringValue(_ stat: RTCStatistics, key: String) -> String? {
            guard let value = stat.values[key] else { return nil }
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        func uintValue(_ stat: RTCStatistics, keys: [String]) -> UInt64 {
            for key in keys {
                guard let value = stat.values[key] else { continue }
                if let number = value as? NSNumber {
                    return number.uint64Value
                }
                if let text = value as? String,
                   let parsed = UInt64(text) {
                    return parsed
                }
            }
            return 0
        }

        func intValue(_ stat: RTCStatistics, keys: [String]) -> Int64 {
            for key in keys {
                guard let value = stat.values[key] else { continue }
                if let number = value as? NSNumber {
                    return number.int64Value
                }
                if let text = value as? String,
                   let parsed = Int64(text) {
                    return parsed
                }
            }
            return 0
        }

        func doubleValue(_ stat: RTCStatistics, keys: [String]) -> Double? {
            for key in keys {
                guard let value = stat.values[key] else { continue }
                if let number = value as? NSNumber {
                    return number.doubleValue
                }
                if let text = value as? String,
                   let parsed = Double(text) {
                    return parsed
                }
            }
            return nil
        }

        func boolValue(_ stat: RTCStatistics, key: String) -> Bool {
            guard let value = stat.values[key] else { return false }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            if let text = value as? String {
                let lowered = text.lowercased()
                return lowered == "true" || lowered == "1"
            }
            return false
        }

        let outboundVideoStats = statsById.values.filter { stat in
            guard stat.type.lowercased() == "outbound-rtp" else { return false }
            let kind = stringValue(stat, key: "kind")?.lowercased()
            let mediaType = stringValue(stat, key: "mediaType")?.lowercased()
            return kind == "video" || mediaType == "video"
        }

        let remoteInboundVideoStats = statsById.values.filter { stat in
            guard stat.type.lowercased() == "remote-inbound-rtp" else { return false }
            let kind = stringValue(stat, key: "kind")?.lowercased()
            let mediaType = stringValue(stat, key: "mediaType")?.lowercased()
            return kind == "video" || mediaType == "video"
        }

        let selectedCandidatePair = statsById.values.first { stat in
            guard stat.type.lowercased() == "candidate-pair" else { return false }
            let state = stringValue(stat, key: "state")?.lowercased()
            let selected = boolValue(stat, key: "selected")
            let nominated = boolValue(stat, key: "nominated")
            return selected || (nominated && state == "succeeded")
        }

        guard !outboundVideoStats.isEmpty else {
            return .empty
        }

        var framesEncoded: UInt64 = 0
        var framesSent: UInt64 = 0
        var packetsSent: UInt64 = 0
        var bytesSent: UInt64 = 0
        var nackCount: UInt64 = 0
        var pliCount: UInt64 = 0
        var firCount: UInt64 = 0
        var frameWidth: UInt64 = 0
        var frameHeight: UInt64 = 0
        var framesPerSecond: UInt64 = 0
        var keyFramesEncoded: UInt64 = 0
        var totalEncodeTime: Double?
        var targetBitrate: UInt64 = 0
        var codec: String?
        var encoderImplementation: String?
        var qualityLimitationReason: String?
        for stat in outboundVideoStats {
            framesEncoded &+= uintValue(stat, keys: ["framesEncoded"])
            framesSent &+= uintValue(stat, keys: ["framesSent"])
            packetsSent &+= uintValue(stat, keys: ["packetsSent"])
            bytesSent &+= uintValue(stat, keys: ["bytesSent"])
            nackCount &+= uintValue(stat, keys: ["nackCount"])
            pliCount &+= uintValue(stat, keys: ["pliCount"])
            firCount &+= uintValue(stat, keys: ["firCount"])
            frameWidth = max(frameWidth, uintValue(stat, keys: ["frameWidth"]))
            frameHeight = max(frameHeight, uintValue(stat, keys: ["frameHeight"]))
            framesPerSecond = max(framesPerSecond, uintValue(stat, keys: ["framesPerSecond"]))
            keyFramesEncoded &+= uintValue(stat, keys: ["keyFramesEncoded"])
            targetBitrate = max(targetBitrate, uintValue(stat, keys: ["targetBitrate"]))
            if let value = doubleValue(stat, keys: ["totalEncodeTime"]) {
                totalEncodeTime = (totalEncodeTime ?? 0) + value
            }
            if encoderImplementation == nil {
                encoderImplementation = stringValue(stat, key: "encoderImplementation")
            }
            if qualityLimitationReason == nil {
                qualityLimitationReason = stringValue(stat, key: "qualityLimitationReason")
            }
            if codec == nil,
               let codecId = stringValue(stat, key: "codecId"),
               let codecStat = statsById[codecId] {
                codec = stringValue(codecStat, key: "mimeType")
                    ?? stringValue(codecStat, key: "codec")
            }
        }

        var remotePacketsLost: Int64 = 0
        var remoteJitter: Double?
        var remoteRoundTripTime: Double?
        for stat in remoteInboundVideoStats {
            remotePacketsLost += intValue(stat, keys: ["packetsLost"])
            if let value = doubleValue(stat, keys: ["jitter"]) {
                remoteJitter = max(remoteJitter ?? value, value)
            }
            if let value = doubleValue(stat, keys: ["roundTripTime"]) {
                remoteRoundTripTime = max(remoteRoundTripTime ?? value, value)
            }
        }

        let availableOutgoingBitrate = selectedCandidatePair.map {
            uintValue($0, keys: ["availableOutgoingBitrate"])
        } ?? 0
        let currentRoundTripTime = selectedCandidatePair.flatMap {
            doubleValue($0, keys: ["currentRoundTripTime"])
        }

        return NativeScreenVideoRTCStats(
            outboundStatsPresent: true,
            framesEncoded: framesEncoded,
            framesSent: framesSent,
            packetsSent: packetsSent,
            bytesSent: bytesSent,
            nackCount: nackCount,
            pliCount: pliCount,
            firCount: firCount,
            codec: codec,
            encoderImplementation: encoderImplementation,
            qualityLimitationReason: qualityLimitationReason,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            framesPerSecond: framesPerSecond,
            keyFramesEncoded: keyFramesEncoded,
            totalEncodeTime: totalEncodeTime,
            targetBitrate: targetBitrate,
            availableOutgoingBitrate: availableOutgoingBitrate,
            currentRoundTripTime: currentRoundTripTime,
            remotePacketsLost: remotePacketsLost,
            remoteJitter: remoteJitter,
            remoteRoundTripTime: remoteRoundTripTime
        )
    }
#endif
}

#if canImport(WebRTC)
extension WebRTCSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            self.logger.info("ICE connection state: \(String(describing: newState), privacy: .public)")
            switch newState {
            case .failed:
                self.notifyDisconnectedIfNeeded(reason: "ice_failed")
            case .closed:
                self.notifyDisconnectedIfNeeded(reason: "ice_closed")
            default:
                break
            }
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            self.logger.info("ICE gathering state: \(String(describing: newState), privacy: .public)")
            if newState == .complete {
                self.emitCompletedLocalDescriptionIfNeeded()
            }
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            let handler = self.onLocalICECandidate
            let payload = WebRTCSignalingEnvelope.Payload(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
            self.dispatchCallback {
                handler?(payload)
            }
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            self.logger.info("✅ DataChannel opened by remote label=\(dataChannel.label, privacy: .public)")
            if self.isScreenChannel(dataChannel) {
                self.screenDataChannel = dataChannel
            } else {
                self.dataChannel = dataChannel
            }
            dataChannel.delegate = self
            if self.isControlChannel(dataChannel) {
                self.notifyReadyIfNeeded()
            }
        }
    }
}

extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            self.logger.info("DataChannel state: \(String(describing: dataChannel.readyState), privacy: .public) label=\(dataChannel.label, privacy: .public)")
            if dataChannel.readyState == .open, self.isControlChannel(dataChannel) {
                self.notifyReadyIfNeeded()
            } else if dataChannel.readyState == .closed, self.isControlChannel(dataChannel) {
                self.notifyDisconnectedIfNeeded(reason: "data_channel_closed")
            } else if dataChannel.readyState == .closed, self.isScreenChannel(dataChannel) {
                if self.screenDataChannel === dataChannel {
                    self.screenDataChannel = nil
                }
            }
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            if self.isScreenChannel(dataChannel) {
                self.deliverInboundScreenData(buffer.data)
            } else {
                self.deliverInboundData(buffer.data)
            }
        }
    }
}
#endif
