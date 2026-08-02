import Foundation
import OSLog
import SkyBridgeProtocolCore
import SkyBridgeWebRTCRuntime

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

@available(iOS 17.0, *)
public final class WebRTCSession: NSObject, @unchecked Sendable {
    public enum Role: Sendable { case offerer, answerer }

    public struct ICEConfig: Sendable {
        public var stunURL: String
        public var turnURLs: [String]
        public var turnUsername: String
        public var turnPassword: String

        public var turnURL: String {
            get { turnURLs.first ?? "" }
            set { turnURLs = [newValue] }
        }

        public init(stunURL: String, turnURLs: [String], turnUsername: String, turnPassword: String) {
            self.stunURL = stunURL
            self.turnURLs = turnURLs
            self.turnUsername = turnUsername
            self.turnPassword = turnPassword
        }
        
        public init(stunURL: String, turnURL: String, turnUsername: String, turnPassword: String) {
            self.stunURL = stunURL
            self.turnURLs = turnURL.isEmpty ? [] : [turnURL]
            self.turnUsername = turnUsername
            self.turnPassword = turnPassword
        }
    }
    
    public enum WebRTCError: Error, LocalizedError, Sendable {
        case webRTCNotAvailable
        case sslInitializationFailed
        case peerConnectionCreationFailed
        case dataChannelNotReady
        case dataChannelNotOpen
        case dataChannelSendFailed
        case sdpFailed(String)
        case invalidChunkSize(Int)
        case invalidFramedPayloadSize(Int)
        case framedPayloadTooLarge(Int)
        case alreadyClosed
        case alreadyStarted
        case remoteICECandidateOverflow(Int)
        case invalidICEConfiguration(String)
        
        public var errorDescription: String? {
            switch self {
            case .webRTCNotAvailable: return "WebRTC 模块不可用（请确认已添加 WebRTC 依赖）"
            case .sslInitializationFailed: return "WebRTC 进程级 SSL 初始化失败"
            case .peerConnectionCreationFailed: return "创建 RTCPeerConnection 失败"
            case .dataChannelNotReady: return "DataChannel 未就绪"
            case .dataChannelNotOpen: return "DataChannel 未打开"
            case .dataChannelSendFailed: return "DataChannel 发送失败"
            case .sdpFailed(let message): return "SDP 处理失败：\(message)"
            case .invalidChunkSize(let value): return "分块大小无效：\(value)。必须大于 0"
            case .invalidFramedPayloadSize(let size):
                return "分帧负载大小无效：\(size) 字节。必须大于 0"
            case .framedPayloadTooLarge(let size):
                return "分帧负载过大：\(size) 字节，超过 \(WebRTCFramedPayloadPolicy.maximumPayloadByteCount) 字节上限"
            case .alreadyClosed: return "WebRTCSession 已关闭"
            case .alreadyStarted: return "WebRTCSession 已启动"
            case .remoteICECandidateOverflow(let limit): return "远端 ICE 候选队列超过上限：\(limit)"
            case .invalidICEConfiguration(let message): return "ICE 配置无效：\(message)"
            }
        }
    }

    private let logger = Logger(subsystem: "com.skybridge.compass.ios", category: "WebRTCSession")
    private static let controlChannelLabel = "skybridge"
    private static let screenChannelLabel = "skybridge-screen"
    private static let maxPendingInboundControlBuffers = 64
    private static let maxPendingInboundControlBytes = 512 * 1024
    private static let maxPendingInboundScreenBuffers = 256
    private static let maxPendingInboundScreenBytes = 4 * 1024 * 1024
    private static let maxPendingRemoteICECandidates = 256
    private static let maxTrackedRemoteICECandidates = 512
    private static let remoteVideoStatsCallbackTimeoutSeconds: TimeInterval = 1
    private static let extremeNativeScreenVideoSDPWidth = 2_056
    private static let extremeNativeScreenVideoSDPHeight = 1_329
    private static let extremeNativeScreenVideoSDPFPS = 60
    private static let extremeNativeScreenVideoH264LevelHex = "33"
    private static var extremeNativeScreenVideoH264MaxFS: Int {
        nativeScreenVideoH264MacroblockFrameSize(
            width: extremeNativeScreenVideoSDPWidth,
            height: extremeNativeScreenVideoSDPHeight
        )
    }
    private static var extremeNativeScreenVideoH264MaxMBPS: Int {
        extremeNativeScreenVideoH264MaxFS * extremeNativeScreenVideoSDPFPS
    }
    private let stateQueue = DispatchQueue(label: "com.skybridge.compass.ios.webrtc.session.state.\(UUID().uuidString)")
    private let callbackQueue = DispatchQueue(label: "com.skybridge.compass.ios.webrtc.session.callback.\(UUID().uuidString)", qos: .userInitiated)
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
#if canImport(WebRTC)
    private var _onRemoteVideoTrack: ((RTCVideoTrack?) -> Void)?
    public var onRemoteVideoTrack: ((RTCVideoTrack?) -> Void)? {
        get { withState { _onRemoteVideoTrack } }
        set { withState { _onRemoteVideoTrack = newValue } }
    }
#endif
    private var _onRemoteVideoFrameEvidence: (@Sendable (CGSize, String) -> Void)?
    public var onRemoteVideoFrameEvidence: (@Sendable (CGSize, String) -> Void)? {
        get { withState { _onRemoteVideoFrameEvidence } }
        set { withState { _onRemoteVideoFrameEvidence = newValue } }
    }
    private var _onRemoteVideoFirstPacket: (@Sendable () -> Void)?
    public var onRemoteVideoFirstPacket: (@Sendable () -> Void)? {
        get { withState { _onRemoteVideoFirstPacket } }
        set { withState { _onRemoteVideoFirstPacket = newValue } }
    }
    private var _onRemoteAudioFirstPacket: (@Sendable () -> Void)?
    public var onRemoteAudioFirstPacket: (@Sendable () -> Void)? {
        get { withState { _onRemoteAudioFirstPacket } }
        set { withState { _onRemoteAudioFirstPacket = newValue } }
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
    private var remoteVideoTrack: RTCVideoTrack?
    private var remoteVideoReceiver: RTCRtpReceiver?
    private var videoTransceiver: RTCRtpTransceiver?
    private var audioTransceiver: RTCRtpTransceiver?
    private var remoteVideoTrackInspectionTask: Task<Void, Never>?
    private var remoteVideoFrameEvidenceTask: Task<Void, Never>?
    private var didEmitRemoteVideoFrameEvidence = false
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
    private var seenRemoteICECandidateKeys: Set<String> = []
#endif
    
	    private var isClosed = false
	    private var hasStarted = false
	    private var didNotifyDisconnected = false
    private var didNotifyReady = false
    private var hasRemoteDescription = false
    private var isSettingRemoteDescription = false
    private var acceptedRemoteDescriptionValidation: ValidatedRemoteSessionDescription?
    private var lastEmittedLocalSDP: String?
    private var lifecycleToken: UInt64 = 0
    private var lastRemoteVideoStatsTimeoutLogAt: Date = .distantPast
    private let nativeAudioReceiveEnabled: Bool
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
    
    public init(
        sessionId: String,
        localDeviceId: String,
        role: Role,
        ice: ICEConfig,
        nativeAudioReceiveEnabled: Bool = true
    ) {
        self.sessionId = sessionId
        self.localDeviceId = localDeviceId
        self.role = role
        self.ice = ice
        self.nativeAudioReceiveEnabled = nativeAudioReceiveEnabled
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

    /// Non-terminal callbacks are admitted only while the lifecycle generation
    /// that queued them is still active. This closes the window where a callback
    /// already queued on `callbackQueue` could mutate a newly disconnected UI
    /// after `close()` advanced the generation and cleared its handlers.
    private func dispatchActiveLifecycleCallback(_ operation: @escaping () -> Void) {
        let expectedLifecycleToken = withState { lifecycleToken }
        dispatchCallback { [weak self] in
            guard let self else { return }
            let remainsActive = self.withState {
                Self.lifecycleGuardAllowsCallback(
                    peerConnectionMatches: true,
                    isClosed: self.isClosed,
                    currentLifecycleToken: self.lifecycleToken,
                    expectedLifecycleToken: expectedLifecycleToken
                )
            }
            guard remainsActive else { return }
            operation()
        }
    }

    public nonisolated static let screenChunkedWireFormat = "sbc2-chunked-v1"
    public nonisolated static let screenChunkHeaderByteCount = 36

    public nonisolated static func encodeScreenChunkEnvelope(
        frameId: UInt64,
        chunkIndex: Int,
        chunkCount: Int,
        totalBytes: Int,
        chunkOffset: Int,
        payload: Data
    ) throws -> Data {
        let (chunkEnd, chunkEndOverflow) = chunkOffset.addingReportingOverflow(
            payload.count
        )
        guard chunkIndex >= 0,
              chunkCount > 0,
              chunkIndex < chunkCount,
              totalBytes >= 0,
              chunkOffset >= 0,
              !chunkEndOverflow,
              chunkEnd <= totalBytes,
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

    /// 关闭 WebRTC 会话并释放会话级资源（PeerConnection / DataChannel）。
    ///
    /// 符合 IEEE TDSC 安全生命周期管理要求：
    /// - 主动关闭 DataChannel 防止数据残留
    /// - 关闭 PeerConnection 终止 ICE / DTLS-SRTP 会话
    /// - WebRTC SSL 由共享 factory provider 持有至进程退出，session close 不得清理
    public func close() {
        withState {
            guard !isClosed else { return }
            onTrace?("close session=\(sessionId)")
            isClosed = true
	        hasStarted = false
	        didNotifyDisconnected = true
		        didNotifyReady = false
		        hasRemoteDescription = false
		        isSettingRemoteDescription = false
            acceptedRemoteDescriptionValidation = nil
            lastEmittedLocalSDP = nil
            lifecycleToken &+= 1
	        onDisconnected = nil
#if canImport(WebRTC)
            pendingRemoteICECandidates.removeAll(keepingCapacity: false)
            seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
            dataChannel?.delegate = nil
            dataChannel?.close()
            dataChannel = nil
            screenDataChannel?.delegate = nil
            screenDataChannel?.close()
            screenDataChannel = nil
            remoteVideoTrack = nil
            remoteVideoReceiver?.delegate = nil
            remoteVideoReceiver = nil
            videoTransceiver = nil
            audioTransceiver?.receiver.delegate = nil
            audioTransceiver = nil
            remoteVideoTrackInspectionTask?.cancel()
            remoteVideoTrackInspectionTask = nil
            remoteVideoFrameEvidenceTask?.cancel()
            remoteVideoFrameEvidenceTask = nil
            didEmitRemoteVideoFrameEvidence = false
            peerConnection?.delegate = nil
            peerConnection?.close()
            peerConnection = nil
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
#if canImport(WebRTC)
            onRemoteVideoTrack = nil
#endif
            onRemoteVideoFrameEvidence = nil
            onRemoteVideoFirstPacket = nil
            onRemoteAudioFirstPacket = nil
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

#if canImport(WebRTC)
#if DEBUG || SKYBRIDGE_TESTING
    private static var shouldForceRelayOnlyForSmoke: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil &&
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_FORCE_RELAY_ICE"] == "1"
    }
#endif

    private func buildIceServers() throws -> [RTCIceServer] {
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
                logger.error("❌ TURN credentials missing; refusing STUN-only downgrade. sessionId=\(self.sessionId, privacy: .public)")
                throw WebRTCError.invalidICEConfiguration("TURN credentials missing")
            }
        } else if !ice.turnURLs.isEmpty {
            logger.error("❌ Invalid TURN URLs. sessionId=\(self.sessionId, privacy: .public)")
            throw WebRTCError.invalidICEConfiguration("invalid TURN URLs")
        }

        if servers.isEmpty {
            logger.error("❌ No valid ICE servers; refusing public STUN fallback. sessionId=\(self.sessionId, privacy: .public)")
            throw WebRTCError.invalidICEConfiguration("no valid ICE servers")
        }

        return servers
    }
#endif
    
    public func start() throws {
        try withState { try startOnStateQueue() }
    }

    /// Starts WebRTC work on the dedicated session queue. UI coordinators call
    /// this async boundary so peer-connection factory/configuration work never
    /// blocks MainActor.
    public func startAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                do {
                    try startOnStateQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startOnStateQueue() throws {
        guard isOnStateQueue else {
            preconditionFailure("startOnStateQueue must run on the WebRTC state queue")
        }
        guard !isClosed else { throw WebRTCError.alreadyClosed }
        guard !hasStarted else { throw WebRTCError.alreadyStarted }
        hasStarted = true

        do {
            didNotifyDisconnected = false
            didNotifyReady = false
            hasRemoteDescription = false
            isSettingRemoteDescription = false
            acceptedRemoteDescriptionValidation = nil
            lastEmittedLocalSDP = nil
            lifecycleToken &+= 1
#if canImport(WebRTC)
            pendingRemoteICECandidates.removeAll(keepingCapacity: false)
            seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
            let factory: RTCPeerConnectionFactory
            do {
                factory = try WebRTCPeerConnectionFactoryProvider.factory(
                    useCustomAudioDevice: false
                )
            } catch WebRTCRuntimeLifecycleError.sslInitializationFailed {
                throw WebRTCError.sslInitializationFailed
            }
            
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.continualGatheringPolicy = .gatherContinually
#if DEBUG || SKYBRIDGE_TESTING
            if Self.shouldForceRelayOnlyForSmoke {
                config.iceTransportPolicy = .relay
            }
#endif
            config.iceServers = try buildIceServers()
            
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
            guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
                logger.error("❌ RTCPeerConnection creation failed: sessionId=\(self.sessionId, privacy: .public) iceServerCount=\(config.iceServers.count, privacy: .public)")
                throw WebRTCError.peerConnectionCreationFailed
            }
            self.peerConnection = pc
            configureIncomingScreenVideoIfNeeded(peerConnection: pc)
            if nativeAudioReceiveEnabled {
                configureIncomingSystemAudioIfNeeded(factory: factory, peerConnection: pc)
            }
            
            if role == .offerer {
                let dcConfig = RTCDataChannelConfiguration()
                dcConfig.isOrdered = true
                dcConfig.isNegotiated = false
                guard let dc = pc.dataChannel(forLabel: Self.controlChannelLabel, configuration: dcConfig) else {
                    throw WebRTCError.peerConnectionCreationFailed
                }
                dc.delegate = self
                self.dataChannel = dc
                onTrace?("start-offerer session=\(sessionId) iceServers=\(config.iceServers.count)")
                createOffer()
            } else {
                onTrace?("start-answerer session=\(sessionId) iceServers=\(config.iceServers.count)")
            }
            
            logger.info("✅ WebRTCSession started role=\(String(describing: self.role), privacy: .public) sessionId=\(self.sessionId, privacy: .public)")
#else
            throw WebRTCError.webRTCNotAvailable
#endif
        } catch {
            rollbackFailedStart()
            throw error
        }
    }

    private func rollbackFailedStart() {
        hasStarted = false
        hasRemoteDescription = false
        isSettingRemoteDescription = false
        acceptedRemoteDescriptionValidation = nil
        lastEmittedLocalSDP = nil
#if canImport(WebRTC)
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        screenDataChannel?.delegate = nil
        screenDataChannel?.close()
        screenDataChannel = nil
        peerConnection?.close()
        peerConnection = nil
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
        dispatchActiveLifecycleCallback {
            handler()
        }
    }

    private func flushPendingInboundDataIfNeeded() {
        let handler = onData
        var buffered: [Data] = []
        inboundDataLock.lock()
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
        dispatchActiveLifecycleCallback {
            buffered.forEach(handler)
        }
    }

    private func flushPendingInboundScreenDataIfNeeded() {
        let handler = onScreenData
        var buffered: [Data] = []
        inboundScreenDataLock.lock()
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
        dispatchActiveLifecycleCallback {
            buffered.forEach(handler)
        }
    }

    private func deliverInboundData(_ data: Data) {
        let activeHandler = onData
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        var overflowReason: String?
        inboundDataLock.lock()
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
        dispatchActiveLifecycleCallback {
            buffered.forEach(handler)
            handler(data)
        }
    }

    private func deliverInboundScreenData(_ data: Data) {
        let activeHandler = onScreenData
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        var overflowReason: String?
        inboundScreenDataLock.lock()
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
        dispatchActiveLifecycleCallback {
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
            self.onTrace?("set-remote-offer session=\(self.sessionId) bytes=\(sdp.utf8.count)")
            let remoteDescriptionValidation: ValidatedRemoteSessionDescription
            do {
                remoteDescriptionValidation = try Self.validateRemoteSessionDescription(
                    sdp,
                    expectedKind: "remote offer"
                )
            } catch {
                self.logger.error("❌ rejected invalid remote offer. sessionId=\(self.sessionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.onTrace?("set-remote-offer rejected session=\(self.sessionId) reason=invalid_remote_sdp")
                self.notifyDisconnectedIfNeeded(reason: "invalid_remote_offer")
                self.close()
                return
            }
            let normalizedOffer = Self.normalizedRemoteSDP(sdp)
            if self.hasRemoteDescription || self.isSettingRemoteDescription {
                self.absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp, traceLabel: "duplicate-offer")
                self.logger.debug("ℹ️ ignore duplicate remote offer. sessionId=\(self.sessionId, privacy: .public)")
                self.onTrace?("set-remote-offer ignored duplicate session=\(self.sessionId)")
                return
            }
            guard let pc = self.peerConnection else { return }
            if pc.remoteDescription != nil {
                guard self.acceptAppliedRemoteDescriptionFromPeerConnection(
                    pc,
                    expectedKind: "applied remote offer"
                ) else { return }
                self.absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp, traceLabel: "existing-offer")
                self.flushPendingRemoteICECandidates()
                self.logger.debug("ℹ️ remote offer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
                self.onTrace?("set-remote-offer ignored existing session=\(self.sessionId)")
                return
            }
            if normalizedOffer.droppedSessionLevelCandidateLines > 0 || normalizedOffer.deduplicatedCandidateLines > 0 {
                self.onTrace?(
                    "normalize-remote-offer session=\(self.sessionId) droppedSessionCandidates=\(normalizedOffer.droppedSessionLevelCandidateLines) dedupedCandidates=\(normalizedOffer.deduplicatedCandidateLines)"
                )
            }
            let desc = RTCSessionDescription(type: .offer, sdp: normalizedOffer.sdp)
            self.isSettingRemoteDescription = true
            let expectedLifecycleToken = self.lifecycleToken
            pc.setRemoteDescription(desc) { [weak self, weak pc] error in
                guard let self else { return }
                self.scheduleState { [weak self, weak pc] in
                    guard let self,
                          let pc,
                          self.peerConnection === pc,
                          !self.isClosed,
                          self.lifecycleToken == expectedLifecycleToken else { return }
                    self.isSettingRemoteDescription = false
                    if let error {
                        self.logger.error("❌ setRemoteOffer failed: \(error.localizedDescription, privacy: .public)")
                        self.onTrace?("set-remote-offer failed session=\(self.sessionId) reason=set_remote_offer_failed")
                        self.notifyDisconnectedIfNeeded(reason: "set_remote_offer_failed")
                        self.close()
                        return
                    }
                    self.hasRemoteDescription = true
                    self.acceptedRemoteDescriptionValidation = remoteDescriptionValidation
                    self.flushPendingRemoteICECandidates()
                    self.inspectRemoteVideoTrackIfAvailable(peerConnection: pc)
                    self.scheduleRemoteVideoTrackInspection(peerConnection: pc, reason: "set-remote-offer")
                    self.onTrace?("set-remote-offer applied session=\(self.sessionId)")
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
            self.onTrace?("set-remote-answer session=\(self.sessionId) bytes=\(sdp.utf8.count)")
            guard let pc = self.peerConnection else { return }
            let remoteDescriptionValidation: ValidatedRemoteSessionDescription
            do {
                remoteDescriptionValidation = try Self.validateRemoteSessionDescription(
                    sdp,
                    expectedKind: "remote answer"
                )
            } catch {
                self.logger.error("❌ rejected invalid remote answer. sessionId=\(self.sessionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.onTrace?("set-remote-answer rejected session=\(self.sessionId) reason=invalid_remote_sdp")
                self.notifyDisconnectedIfNeeded(reason: "invalid_remote_answer")
                self.close()
                return
            }
            let normalizedAnswer = Self.normalizedRemoteSDP(sdp)
            if self.hasRemoteDescription || self.isSettingRemoteDescription {
                self.absorbRemoteICECandidatesFromSDP(normalizedAnswer.sdp, traceLabel: "duplicate-answer")
                self.flushPendingRemoteICECandidates()
                self.logger.debug("ℹ️ ignore duplicate remote answer. sessionId=\(self.sessionId, privacy: .public)")
                self.onTrace?("set-remote-answer ignored duplicate session=\(self.sessionId)")
                return
            }
            if pc.remoteDescription != nil {
                guard self.acceptAppliedRemoteDescriptionFromPeerConnection(
                    pc,
                    expectedKind: "applied remote answer"
                ) else { return }
                self.absorbRemoteICECandidatesFromSDP(normalizedAnswer.sdp, traceLabel: "existing-answer")
                self.flushPendingRemoteICECandidates()
                self.logger.debug("ℹ️ remote answer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
                self.onTrace?("set-remote-answer ignored existing session=\(self.sessionId)")
                return
            }
            if normalizedAnswer.droppedSessionLevelCandidateLines > 0 || normalizedAnswer.deduplicatedCandidateLines > 0 {
                self.onTrace?(
                    "normalize-remote-answer session=\(self.sessionId) droppedSessionCandidates=\(normalizedAnswer.droppedSessionLevelCandidateLines) dedupedCandidates=\(normalizedAnswer.deduplicatedCandidateLines)"
                )
            }
            let desc = RTCSessionDescription(type: .answer, sdp: normalizedAnswer.sdp)
            self.isSettingRemoteDescription = true
            let expectedLifecycleToken = self.lifecycleToken
            pc.setRemoteDescription(desc) { [weak self, weak pc] error in
                guard let self else { return }
                self.scheduleState { [weak self, weak pc] in
                    guard let self,
                          let pc,
                          self.peerConnection === pc,
                          !self.isClosed,
                          self.lifecycleToken == expectedLifecycleToken else { return }
                    self.isSettingRemoteDescription = false
                    if let error {
                        if pc.signalingState == .stable || pc.remoteDescription != nil {
                            guard self.acceptAppliedRemoteDescriptionFromPeerConnection(
                                pc,
                                expectedKind: "applied remote answer"
                            ) else { return }
                            self.flushPendingRemoteICECandidates()
                            self.inspectRemoteVideoTrackIfAvailable(peerConnection: pc)
                            self.scheduleRemoteVideoTrackInspection(peerConnection: pc, reason: "set-remote-answer-stable")
                            self.logger.debug("ℹ️ remote answer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
                            self.onTrace?("set-remote-answer ignored stable session=\(self.sessionId)")
                            return
                        }
                        self.logger.error("❌ setRemoteAnswer failed: \(error.localizedDescription, privacy: .public)")
                        self.onTrace?("set-remote-answer failed session=\(self.sessionId) reason=set_remote_answer_failed")
                        self.notifyDisconnectedIfNeeded(reason: "set_remote_answer_failed")
                        self.close()
                        return
                    }
                    self.hasRemoteDescription = true
                    self.acceptedRemoteDescriptionValidation = remoteDescriptionValidation
                    self.flushPendingRemoteICECandidates()
                    self.inspectRemoteVideoTrackIfAvailable(peerConnection: pc)
                    self.scheduleRemoteVideoTrackInspection(peerConnection: pc, reason: "set-remote-answer")
                    self.onTrace?("set-remote-answer applied session=\(self.sessionId)")
                }
            }
        }
#endif
    }
    
    public func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
#if canImport(WebRTC)
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            let validated: ValidatedRemoteICECandidate
            do {
                validated = try Self.validatedRemoteICECandidate(
                    candidate: candidate,
                    sdpMid: sdpMid,
                    sdpMLineIndex: sdpMLineIndex
                )
                try self.ensureRemoteICECandidateIsBoundToAcceptedRemoteDescription(validated)
            } catch {
                self.rejectInvalidRemoteICECandidate(error, source: "trickle")
                return
            }
            let cand = RTCIceCandidate(
                sdp: validated.candidate,
                sdpMLineIndex: validated.sdpMLineIndex,
                sdpMid: validated.sdpMid
            )
            switch Self.pendingRemoteICEPlan(
                isDuplicate: !self.trackRemoteICECandidateIfNeeded(cand),
                hasRemoteDescription: self.hasRemoteDescription,
                pendingCount: self.pendingRemoteICECandidates.count,
                maxPendingCount: Self.maxPendingRemoteICECandidates
            ) {
            case .ignoreDuplicate:
                return
            case .queueCandidate(let nextPendingCount):
                self.pendingRemoteICECandidates.append(cand)
                self.logger.debug("⏳ queue remote ICE candidate until remote description is set. sessionId=\(self.sessionId, privacy: .public) pending=\(nextPendingCount, privacy: .public)")
                self.onTrace?("queue-remote-ice session=\(self.sessionId) pending=\(self.pendingRemoteICECandidates.count)")
            case .applyImmediately:
                self.onTrace?("apply-remote-ice session=\(self.sessionId)")
                self.addRemoteICECandidateInternal(cand)
            case .overflow:
                self.rejectInvalidRemoteICECandidate(
                    WebRTCError.remoteICECandidateOverflow(Self.maxPendingRemoteICECandidates),
                    source: "trickle-overflow"
                )
            }
        }
#endif
    }

#if canImport(WebRTC)
    private func trackRemoteICECandidateIfNeeded(_ candidate: RTCIceCandidate) -> Bool {
        let normalizedSDP: String
        if candidate.sdp.hasPrefix("a=") {
            normalizedSDP = String(candidate.sdp.dropFirst(2))
        } else {
            normalizedSDP = candidate.sdp
        }
        let mid = candidate.sdpMid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = "\(candidate.sdpMLineIndex)|\(mid)|\(normalizedSDP)"
        if !seenRemoteICECandidateKeys.contains(key),
           seenRemoteICECandidateKeys.count >= Self.maxTrackedRemoteICECandidates {
            rejectInvalidRemoteICECandidate(
                WebRTCError.remoteICECandidateOverflow(Self.maxTrackedRemoteICECandidates),
                source: "tracked-candidate-overflow"
            )
            return false
        }
        return seenRemoteICECandidateKeys.insert(key).inserted
    }

    private func ensureRemoteICECandidateIsBoundToAcceptedRemoteDescription(
        _ candidate: ValidatedRemoteICECandidate
    ) throws {
        guard hasRemoteDescription else { return }
        guard let acceptedRemoteDescriptionValidation else {
            throw WebRTCError.sdpFailed("accepted remote SDP validation state is missing")
        }
        try acceptedRemoteDescriptionValidation.validate(candidate: candidate)
    }

    private func ensureRemoteICECandidateIsBoundToAcceptedRemoteDescription(
        _ candidate: RTCIceCandidate
    ) throws {
        let validated = try Self.validatedRemoteICECandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex
        )
        try ensureRemoteICECandidateIsBoundToAcceptedRemoteDescription(validated)
    }

    private func rejectInvalidRemoteICECandidate(_ error: Error, source: String) {
        logger.error("❌ rejected invalid remote ICE candidate. sessionId=\(self.sessionId, privacy: .public) source=\(source, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        onTrace?("remote-ice rejected session=\(sessionId) source=\(source) reason=invalid_remote_ice")
        notifyDisconnectedIfNeeded(reason: "invalid_remote_ice")
        close()
    }

    private func addRemoteICECandidateInternal(_ candidate: RTCIceCandidate) {
        guard let pc = peerConnection else { return }
        let expectedLifecycleToken = lifecycleToken
        pc.add(candidate) { [weak self, weak pc] error in
            guard let self, let error else { return }
            self.scheduleState { [weak self, weak pc] in
                guard let self,
                      let pc,
                      Self.lifecycleGuardAllowsCallback(
                          peerConnectionMatches: self.peerConnection === pc,
                          isClosed: self.isClosed,
                          currentLifecycleToken: self.lifecycleToken,
                          expectedLifecycleToken: expectedLifecycleToken
                      ) else { return }
                self.logger.error("❌ addIceCandidate failed: \(error.localizedDescription, privacy: .public)")
                self.onTrace?("remote-ice failed session=\(self.sessionId) reason=add_ice_candidate_failed")
                self.notifyDisconnectedIfNeeded(reason: "add_ice_candidate_failed")
                self.close()
            }
        }
    }

    private func acceptAppliedRemoteDescriptionFromPeerConnection(
        _ peerConnection: RTCPeerConnection,
        expectedKind: String
    ) -> Bool {
        guard let appliedSDP = peerConnection.remoteDescription?.sdp else {
            logger.error("❌ remoteDescription missing while accepting applied SDP. sessionId=\(self.sessionId, privacy: .public) kind=\(expectedKind, privacy: .public)")
            onTrace?("remote-description rejected session=\(sessionId) source=peerConnection reason=missing_applied_remote_sdp")
            notifyDisconnectedIfNeeded(reason: "missing_applied_remote_sdp")
            close()
            return false
        }
        do {
            acceptedRemoteDescriptionValidation = try Self.validateRemoteSessionDescription(
                appliedSDP,
                expectedKind: expectedKind
            )
            hasRemoteDescription = true
            return true
        } catch {
            logger.error("❌ applied remoteDescription failed validation. sessionId=\(self.sessionId, privacy: .public) kind=\(expectedKind, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            onTrace?("remote-description rejected session=\(sessionId) source=peerConnection reason=invalid_applied_remote_sdp")
            notifyDisconnectedIfNeeded(reason: "invalid_applied_remote_sdp")
            close()
            return false
        }
    }

    private func flushPendingRemoteICECandidates() {
        guard hasRemoteDescription else { return }
        guard !pendingRemoteICECandidates.isEmpty else { return }

        let pending = pendingRemoteICECandidates
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        logger.info("🔄 applying queued remote ICE candidates. sessionId=\(self.sessionId, privacy: .public) count=\(pending.count, privacy: .public)")
        for candidate in pending {
            do {
                try ensureRemoteICECandidateIsBoundToAcceptedRemoteDescription(candidate)
            } catch {
                rejectInvalidRemoteICECandidate(error, source: "queued")
                return
            }
            addRemoteICECandidateInternal(candidate)
        }
    }

    private func absorbRemoteICECandidatesFromSDP(_ sdp: String, traceLabel: String) {
        let extracted = Self.extractRemoteICECandidates(from: sdp)
        guard !extracted.isEmpty else { return }

        var absorbed = 0
        for candidate in extracted where trackRemoteICECandidateIfNeeded(candidate) {
            absorbed += 1
            if hasRemoteDescription {
                do {
                    try ensureRemoteICECandidateIsBoundToAcceptedRemoteDescription(candidate)
                } catch {
                    rejectInvalidRemoteICECandidate(error, source: "sdp")
                    return
                }
                addRemoteICECandidateInternal(candidate)
            } else {
                guard pendingRemoteICECandidates.count < Self.maxPendingRemoteICECandidates else {
                    rejectInvalidRemoteICECandidate(
                        WebRTCError.remoteICECandidateOverflow(Self.maxPendingRemoteICECandidates),
                        source: "sdp-overflow"
                    )
                    return
                }
                pendingRemoteICECandidates.append(candidate)
            }
        }

        guard absorbed > 0 else { return }
        logger.info("🔄 absorbed ICE candidates from duplicate SDP. sessionId=\(self.sessionId, privacy: .public) count=\(absorbed, privacy: .public)")
        onTrace?("absorb-remote-ice session=\(sessionId) source=\(traceLabel) count=\(absorbed)")
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

    private func configureIncomingScreenVideoIfNeeded(peerConnection: RTCPeerConnection) {
        guard videoTransceiver == nil else { return }
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        transceiverInit.streamIds = ["screen-\(sessionId)"]
        videoTransceiver = peerConnection.addTransceiver(of: .video, init: transceiverInit)
    }

    private func configureIncomingSystemAudioIfNeeded(
        factory: RTCPeerConnectionFactory,
        peerConnection: RTCPeerConnection
    ) {
        guard nativeAudioReceiveEnabled else { return }
        guard audioTransceiver == nil else { return }
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        transceiverInit.streamIds = ["system-audio-\(sessionId)"]
        audioTransceiver = peerConnection.addTransceiver(of: .audio, init: transceiverInit)
        if let audioTransceiver {
            preferOpusCodecIfPossible(factory: factory, transceiver: audioTransceiver)
            audioTransceiver.receiver.delegate = self
        }
    }

    private func preferOpusCodecIfPossible(
        factory: RTCPeerConnectionFactory,
        transceiver: RTCRtpTransceiver
    ) {
        let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
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

    private static func remoteVideoTracksShareNativeBacking(_ lhs: RTCVideoTrack?, _ rhs: RTCVideoTrack?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            // RTCRtpReceiver.track may vend a fresh wrapper on each read; WebRTC requires isEqual for backing identity.
            return lhs === rhs || lhs.isEqual(rhs)
        default:
            return false
        }
    }

    private func captureRemoteVideoTrack(_ track: RTCVideoTrack?, receiver: RTCRtpReceiver? = nil) {
        if let receiver {
            if remoteVideoReceiver?.isEqual(receiver) == false {
                remoteVideoReceiver?.delegate = nil
            }
            remoteVideoReceiver = receiver
            remoteVideoReceiver?.delegate = self
        }
        let tracksShareNativeBacking = Self.remoteVideoTracksShareNativeBacking(remoteVideoTrack, track)
        guard !tracksShareNativeBacking else {
            if track != nil,
               remoteVideoFrameEvidenceTask == nil,
               !didEmitRemoteVideoFrameEvidence {
                startRemoteVideoFrameEvidenceObservation()
            }
            return
        }
        let previousTrackId = Self.normalizedRemoteVideoTrackId(remoteVideoTrack?.trackId)
        let incomingTrackId = Self.normalizedRemoteVideoTrackId(track?.trackId)
        let isTrackRebind =
            !previousTrackId.isEmpty
            && previousTrackId == incomingTrackId
            && track != nil
        if !incomingTrackId.isEmpty, isTrackRebind {
            logger.info(
                "🔁 rebind remote native video track after receiver replaced backing instance. sessionId=\(self.sessionId, privacy: .public) trackId=\(incomingTrackId, privacy: .public)"
            )
            onTrace?("remote-video-track rebind session=\(sessionId) trackId=\(incomingTrackId)")
        }
        remoteVideoFrameEvidenceTask?.cancel()
        remoteVideoFrameEvidenceTask = nil
        didEmitRemoteVideoFrameEvidence = isTrackRebind ? didEmitRemoteVideoFrameEvidence : false
        remoteVideoTrack = track
        if let track {
            track.isEnabled = true
            logger.info("🎬 detected remote native video track. sessionId=\(self.sessionId, privacy: .public)")
            onTrace?("remote-video-track-enabled session=\(sessionId) trackId=\(track.trackId) enabled=\(track.isEnabled ? 1 : 0)")
            remoteVideoTrackInspectionTask?.cancel()
            remoteVideoTrackInspectionTask = nil
            startRemoteVideoFrameEvidenceObservation()
        } else {
            didEmitRemoteVideoFrameEvidence = false
            remoteVideoReceiver = nil
        }
        onTrace?("remote-video-track session=\(sessionId) ready=\(track != nil ? 1 : 0)")
        let handler = onRemoteVideoTrack
        dispatchActiveLifecycleCallback {
            handler?(track)
        }
    }

    private func startRemoteVideoFrameEvidenceObservation() {
        guard !didEmitRemoteVideoFrameEvidence else { return }
        remoteVideoFrameEvidenceTask?.cancel()
        let expectedLifecycleToken = lifecycleToken
        remoteVideoFrameEvidenceTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            var lastProbeLogAt = Date.distantPast
            var lastFrameEvidenceTraceAt = Date.distantPast
            var didEmitPacketEvidence = false
            while !Task.isCancelled {
                if attempt > 0 {
                    let delay: Duration = attempt < 8 ? .milliseconds(250) : .seconds(1)
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }
                attempt += 1
                guard !Task.isCancelled else { return }
                let shouldContinue = self.withState {
                    !self.isClosed
                        && self.lifecycleToken == expectedLifecycleToken
                        && self.peerConnection != nil
                        && self.remoteVideoTrack != nil
                }
                guard shouldContinue else { return }
                let receivers = self.withState { () -> [RTCRtpReceiver] in
                    guard !self.isClosed,
                          self.lifecycleToken == expectedLifecycleToken else { return [] }
                    return self.resolveRemoteVideoReceivers()
                }

                var candidates: [RemoteInboundVideoStatsCandidate] = []
                for receiver in receivers {
                    let receiverTrackId = self.normalizedTrackId(for: receiver)
                    let receiverSamples = await self.remoteInboundVideoStatsSamples(for: receiver)
                    guard !Task.isCancelled else { return }
                    if let snapshot = Self.remoteInboundVideoStatsSnapshot(from: receiverSamples) {
                        candidates.append(
                            RemoteInboundVideoStatsCandidate(
                                source: "receiver-specific",
                                receiver: receiver,
                                receiverTrackId: receiverTrackId,
                                snapshot: snapshot
                            )
                        )
                    }
                }
                if candidates.isEmpty || !candidates.contains(where: { $0.snapshot.hasFrameEvidence }) {
                    let peerSamples = await self.allPeerConnectionVideoStatsSamples()
                    guard !Task.isCancelled else { return }
                    if let peerSnapshot = Self.remoteInboundVideoStatsSnapshot(from: peerSamples) {
                        candidates.append(
                            RemoteInboundVideoStatsCandidate(
                                source: "peer-fallback",
                                receiver: nil,
                                receiverTrackId: "-",
                                snapshot: peerSnapshot
                            )
                        )
                    }
                }

                guard let candidate = candidates.max(
                    by: { lhs, rhs in Self.snapshotPriority(lhs.snapshot) < Self.snapshotPriority(rhs.snapshot) }
                ) else {
                    continue
                }
                let snapshot = candidate.snapshot
                if let receiver = candidate.receiver {
                    let didRefreshTrack = self.withState {
                        self.refreshRemoteVideoTrackFromReceiverIfNeeded(
                            receiver,
                            expectedLifecycleToken: expectedLifecycleToken,
                            reason: "active-receiver-stats"
                        )
                    }
                    if didRefreshTrack {
                        return
                    }
                }

                let now = Date()
                if now.timeIntervalSince(lastProbeLogAt) >= 1.0 {
                    lastProbeLogAt = now
                    self.logger.debug(
                        "📈 remote native video receiver stats probe. sessionId=\(self.sessionId, privacy: .public) \(candidate.summary, privacy: .public)"
                    )
                    self.onTrace?(
                        "remote-video-stats session=\(self.sessionId) \(candidate.summary)"
                    )
                }

                if snapshot.hasPacketEvidence, !didEmitPacketEvidence {
                    didEmitPacketEvidence = true
                    let handler = self.onRemoteVideoFirstPacket
                    self.dispatchActiveLifecycleCallback {
                        handler?()
                    }
                }

                guard snapshot.hasFrameEvidence, let size = snapshot.size else {
                    continue
                }
                let shouldNotifyFirstFrame = self.withState {
                    guard !self.isClosed,
                          self.lifecycleToken == expectedLifecycleToken else { return false }
                    if self.didEmitRemoteVideoFrameEvidence {
                        return false
                    }
                    self.didEmitRemoteVideoFrameEvidence = true
                    return true
                }
                guard shouldNotifyFirstFrame || now.timeIntervalSince(lastFrameEvidenceTraceAt) >= 10 else {
                    continue
                }
                lastFrameEvidenceTraceAt = now
                if shouldNotifyFirstFrame {
                    self.logger.info(
                        "🎬 remote native video receiver stats confirmed first frame. sessionId=\(self.sessionId, privacy: .public) \(candidate.summary, privacy: .public)"
                    )
                }
                self.onTrace?(
                    "remote-video-frame-evidence session=\(self.sessionId) \(candidate.summary)"
                )
                let handler = self.onRemoteVideoFrameEvidence
                self.dispatchActiveLifecycleCallback {
                    handler?(size, "receiver-stats")
                }
            }
        }
    }

    private func normalizedTrackId(for receiver: RTCRtpReceiver) -> String {
        Self.normalizedRemoteVideoTrackId((receiver.track as? RTCVideoTrack)?.trackId)
    }

    private func refreshRemoteVideoTrackFromReceiverIfNeeded(
        _ receiver: RTCRtpReceiver,
        expectedLifecycleToken: UInt64,
        reason: String
    ) -> Bool {
        guard !isClosed,
              lifecycleToken == expectedLifecycleToken,
              let receiverTrack = receiver.track as? RTCVideoTrack else {
            return false
        }
        let refreshAction = Self.receiverStatsProbeRemoteVideoTrackRefreshAction(
            currentTrackId: remoteVideoTrack?.trackId,
            receiverTrackId: receiverTrack.trackId,
            hasCurrentRemoteVideoTrack: remoteVideoTrack != nil
        )
        guard refreshAction == .rebind else {
            return false
        }

        let currentTrackId = Self.normalizedRemoteVideoTrackId(remoteVideoTrack?.trackId)
        let nextTrackId = Self.normalizedRemoteVideoTrackId(receiverTrack.trackId)
        let previousTrackId = currentTrackId.isEmpty ? "-" : currentTrackId
        logger.info(
            "🔁 remote native video track refreshed from receiver stats probe. sessionId=\(self.sessionId, privacy: .public) previousTrackId=\(previousTrackId, privacy: .public) trackId=\(nextTrackId.isEmpty ? "-" : nextTrackId, privacy: .public) reason=\(reason, privacy: .public)"
        )
        onTrace?(
            "remote-video-track-sync session=\(sessionId) previousTrackId=\(previousTrackId) trackId=\(nextTrackId.isEmpty ? "-" : nextTrackId) reason=\(reason)"
        )
        captureRemoteVideoTrack(receiverTrack, receiver: receiver)
        return true
    }

    private func remoteInboundVideoStatsSamples(
        for receiver: RTCRtpReceiver
    ) async -> [RemoteInboundVideoStatsSample] {
        guard let peerConnection = withState({ self.peerConnection }) else {
            return []
        }
        let outcome = await Self.awaitBoundedStatsCallback(
            timeoutSeconds: Self.remoteVideoStatsCallbackTimeoutSeconds
        ) { completion in
            peerConnection.statistics(for: receiver) { report in
                let samples = report.statistics.values.map { statistic in
                    RemoteInboundVideoStatsSample(type: statistic.type, values: statistic.values)
                }
                completion(samples)
            }
        }
        return resolvedRemoteInboundVideoStatsSamples(outcome, source: "receiver-specific")
    }

    private func allPeerConnectionVideoStatsSamples() async -> [RemoteInboundVideoStatsSample] {
        guard let peerConnection = withState({ self.peerConnection }) else {
            return []
        }
        let outcome = await Self.awaitBoundedStatsCallback(
            timeoutSeconds: Self.remoteVideoStatsCallbackTimeoutSeconds
        ) { completion in
            peerConnection.statistics { report in
                let samples = report.statistics.values.map { statistic in
                    RemoteInboundVideoStatsSample(type: statistic.type, values: statistic.values)
                }
                completion(samples)
            }
        }
        return resolvedRemoteInboundVideoStatsSamples(outcome, source: "peer-wide")
    }

    private func resolvedRemoteInboundVideoStatsSamples(
        _ outcome: BoundedCallbackOutcome<[RemoteInboundVideoStatsSample]>,
        source: String
    ) -> [RemoteInboundVideoStatsSample] {
        switch outcome {
        case .completed(let samples):
            return samples
        case .cancelled:
            return []
        case .timedOut:
            let shouldReport = withState {
                guard !isClosed else { return false }
                let now = Date()
                guard now.timeIntervalSince(lastRemoteVideoStatsTimeoutLogAt) >= 10 else {
                    return false
                }
                lastRemoteVideoStatsTimeoutLogAt = now
                return true
            }
            guard shouldReport else { return [] }
            logger.error(
                "WebRTC receiver statistics callback timed out. sessionId=\(self.sessionId, privacy: .public) source=\(source, privacy: .public)"
            )
            onTrace?("remote-video-stats-timeout session=\(sessionId) source=\(source)")
            return []
        }
    }

    private func resolveRemoteVideoReceiver() -> RTCRtpReceiver? {
        if let remoteVideoReceiver {
            remoteVideoReceiver.delegate = self
            return remoteVideoReceiver
        }
        if let receiver = videoTransceiver?.receiver {
            remoteVideoReceiver = receiver
            remoteVideoReceiver?.delegate = self
            return receiver
        }
        guard let peerConnection else { return nil }
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            remoteVideoReceiver = transceiver.receiver
            remoteVideoReceiver?.delegate = self
            return transceiver.receiver
        }
        for receiver in peerConnection.receivers where receiver.track is RTCVideoTrack {
            remoteVideoReceiver = receiver
            remoteVideoReceiver?.delegate = self
            return receiver
        }
        return nil
    }

    private func resolveRemoteVideoReceivers() -> [RTCRtpReceiver] {
        var receivers: [RTCRtpReceiver] = []
        func appendIfNeeded(_ receiver: RTCRtpReceiver?) {
            guard let receiver else { return }
            guard receiver.track is RTCVideoTrack else { return }
            if !receivers.contains(where: { $0 === receiver || $0.isEqual(receiver) }) {
                receiver.delegate = self
                receivers.append(receiver)
            }
        }

        appendIfNeeded(remoteVideoReceiver)
        appendIfNeeded(videoTransceiver?.receiver)
        if let peerConnection {
            for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
                appendIfNeeded(transceiver.receiver)
            }
            for receiver in peerConnection.receivers {
                appendIfNeeded(receiver)
            }
        }

        if remoteVideoReceiver == nil {
            remoteVideoReceiver = receivers.first
        }
        return receivers
    }

    private func inspectRemoteVideoTrackIfAvailable(peerConnection: RTCPeerConnection) {
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video {
            if let track = transceiver.receiver.track as? RTCVideoTrack {
                captureRemoteVideoTrack(track, receiver: transceiver.receiver)
                return
            }
        }
    }

    private func scheduleRemoteVideoTrackInspection(
        peerConnection: RTCPeerConnection,
        reason: String
    ) {
        guard remoteVideoTrack == nil else { return }
        remoteVideoTrackInspectionTask?.cancel()
        let expectedLifecycleToken = lifecycleToken
        remoteVideoTrackInspectionTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...15 {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let didFindTrack: Bool? = self.withState {
                    guard !self.isClosed,
                          self.lifecycleToken == expectedLifecycleToken,
                          self.peerConnection === peerConnection else { return nil }
                    self.inspectRemoteVideoTrackIfAvailable(peerConnection: peerConnection)
                    return self.remoteVideoTrack != nil
                }
                guard let didFindTrack else { return }
                if didFindTrack {
                    self.onTrace?("remote-video-track inspection-success session=\(self.sessionId) reason=\(reason) attempt=\(attempt)")
                    return
                }
            }
            let shouldReportTimeout = self.withState {
                !self.isClosed
                    && self.lifecycleToken == expectedLifecycleToken
                    && self.peerConnection === peerConnection
                    && self.remoteVideoTrack == nil
            }
            guard shouldReportTimeout else { return }
            self.logger.debug("ℹ️ remote native video track still unavailable after inspection. sessionId=\(self.sessionId, privacy: .public) reason=\(reason, privacy: .public)")
            self.onTrace?("remote-video-track inspection-timeout session=\(self.sessionId) reason=\(reason)")
        }
    }
#endif
    
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
            guard let channel else { throw WebRTCError.dataChannelNotReady }
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
        guard maxChunkBytes > Self.screenChunkHeaderByteCount else {
            throw WebRTCError.invalidChunkSize(maxChunkBytes)
        }
        _ = try Self.validateFramedPayloadParameters(
            payloadByteCount: payload.count,
            maxChunkBytes: maxChunkBytes
        )

        let frameId = withState {
            let id = nextScreenChunkedFrameId
            nextScreenChunkedFrameId &+= 1
            if nextScreenChunkedFrameId == 0 {
                nextScreenChunkedFrameId = 1
            }
            return id
        }

        try await outboundScreenFrameGate.run {
            let channel = try resolvedDataChannel(
                preferScreenChannel: true,
                fallbackToControlChannel: false
            )
            let maxPayloadBytes = maxChunkBytes - Self.screenChunkHeaderByteCount
            let chunkCount = max(1, (payload.count + maxPayloadBytes - 1) / maxPayloadBytes)

            var offset = 0
            for chunkIndex in 0..<chunkCount {
                try await waitForBufferedAmountBelow(
                    maxBufferedAmountBytes,
                    pollInterval: pollInterval,
                    timeout: drainTimeout,
                    channel: channel
                )
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

            try await waitForBufferedAmountBelow(
                maxBufferedAmountBytes,
                pollInterval: pollInterval,
                timeout: drainTimeout,
                channel: channel
            )
        }
        return frameId
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
            var didQueueFragment = false
            do {
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
                    didQueueFragment = true
                    offset = end
                }

                try await waitForBufferedAmountBelow(
                    maxBufferedAmountBytes,
                    pollInterval: pollInterval,
                    timeout: drainTimeout,
                    channel: channel
                )
            } catch {
                // A partially queued length-prefixed frame makes the byte stream
                // ambiguous. Close the session before releasing the frame gate so
                // no later message can be appended to a desynchronized channel.
                if didQueueFragment {
                    close()
                }
                throw error
            }
        }
    }

    public func dataChannelBufferedAmountBytes() -> UInt64 {
        dataChannelBufferedAmountBytes(preferScreenChannel: false, fallbackToControlChannel: false)
    }

    public func screenDataChannelBufferedAmountBytes() -> UInt64 {
        dataChannelBufferedAmountBytes(preferScreenChannel: true, fallbackToControlChannel: true)
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
        guard channel.sendData(buffer) else {
            // 仅失败路径打 trace：成功路径每分片读取 onTrace（stateQueue 同步跳变）
            // 与 bufferedAmount（libwebrtc 代理调用）会在屏幕流高码率下形成可观开销。
            onTrace?(
                "data-channel-tx-failed session=\(sessionId) label=\(channel.label) bytes=\(data.count) binary=1 buffered=\(channel.bufferedAmount)"
            )
            throw WebRTCError.dataChannelSendFailed
        }
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    static func validateFramedPayloadParameters(
        payloadByteCount: Int,
        maxChunkBytes: Int
    ) throws -> UInt32 {
        guard maxChunkBytes > 0,
              maxChunkBytes <= WebRTCFramedPayloadPolicy.maximumPayloadByteCount else {
            throw WebRTCError.invalidChunkSize(maxChunkBytes)
        }
        guard payloadByteCount > 0 else {
            throw WebRTCError.invalidFramedPayloadSize(payloadByteCount)
        }
        guard WebRTCFramedPayloadPolicy.isValidPayloadByteCount(payloadByteCount) else {
            throw WebRTCError.framedPayloadTooLarge(payloadByteCount)
        }
        return UInt32(payloadByteCount)
    }

    private func localSDPWithNativeScreenH264ConstraintsIfNeeded(
        _ sdp: String,
        kind: String
    ) -> String {
        guard Self.nativeScreenVideoH264SDPConstraintsEnabled() else { return sdp }
        let constrained = Self.sdpWithNativeScreenH264LevelSupport(
            sdp,
            requiredLevelHex: Self.extremeNativeScreenVideoH264LevelHex,
            maxFS: Self.extremeNativeScreenVideoH264MaxFS,
            maxMBPS: Self.extremeNativeScreenVideoH264MaxMBPS
        )
        guard constrained != sdp else { return sdp }
        onTrace?(
            """
            local-sdp-h264-extreme-constraints session=\(sessionId) \
            kind=\(kind) \
            level=\(Self.extremeNativeScreenVideoH264LevelHex) \
            maxFS=\(Self.extremeNativeScreenVideoH264MaxFS) \
            maxMBPS=\(Self.extremeNativeScreenVideoH264MaxMBPS)
            """
        )
        return constrained
    }

    private static func nativeScreenVideoH264SDPConstraintsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["SKYBRIDGE_WEBRTC_EXTREME_MEDIA"] == "1"
            || environment["SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK"] == "1"
    }

    private static func nativeScreenVideoH264MacroblockFrameSize(width: Int, height: Int) -> Int {
        let clampedWidth = max(1, width)
        let clampedHeight = max(1, height)
        let macroblockWidth = (clampedWidth + 15) / 16
        let macroblockHeight = (clampedHeight + 15) / 16
        return macroblockWidth * macroblockHeight
    }

#if canImport(WebRTC)
    private func createOffer() {
        guard let pc = peerConnection else { return }
        onTrace?("create-offer session=\(sessionId)")
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": nativeAudioReceiveEnabled ? "true" : "false",
                "OfferToReceiveVideo": videoTransceiver == nil ? "false" : "true",
            ],
            optionalConstraints: nil
        )
        let expectedLifecycleToken = lifecycleToken
        pc.offer(for: constraints) { [weak self, weak pc] sdp, error in
            guard let self else { return }
            self.scheduleState { [weak self, weak pc] in
                guard let self else { return }
                guard let pc,
                      Self.lifecycleGuardAllowsCallback(
                        peerConnectionMatches: self.peerConnection === pc,
                        isClosed: self.isClosed,
                        currentLifecycleToken: self.lifecycleToken,
                        expectedLifecycleToken: expectedLifecycleToken
                      ) else { return }
                if let error {
                    self.logger.error("❌ offer failed: \(error.localizedDescription, privacy: .public)")
                    self.onTrace?("create-offer failed session=\(self.sessionId) reason=create_offer_failed")
                    self.notifyDisconnectedIfNeeded(reason: "create_offer_failed")
                    self.close()
                    return
                }
                guard let sdp else {
                    self.logger.error("❌ offer completed without SDP")
                    self.notifyDisconnectedIfNeeded(reason: "create_offer_missing_sdp")
                    self.close()
                    return
                }
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
                    self.scheduleState { [weak self, weak pc] in
                        guard let self else { return }
                        guard let pc,
                              Self.lifecycleGuardAllowsCallback(
                                peerConnectionMatches: self.peerConnection === pc,
                                isClosed: self.isClosed,
                                currentLifecycleToken: self.lifecycleToken,
                                expectedLifecycleToken: expectedLifecycleToken
                              ) else { return }
                        if let err {
                            self.logger.error("❌ setLocalDescription(offer) failed: \(err.localizedDescription, privacy: .public)")
                            self.onTrace?("set-local-offer failed session=\(self.sessionId) reason=set_local_offer_failed")
                            self.notifyDisconnectedIfNeeded(reason: "set_local_offer_failed")
                            self.close()
                            return
                        }
                        self.logLocalSDPSummary(kind: "offer", sdp: sdpString)
                        self.lastEmittedLocalSDP = sdpString
                        self.onTrace?("local-offer-ready session=\(self.sessionId) bytes=\(sdpString.utf8.count)")
                        let handler = self.onLocalOffer
                        self.dispatchActiveLifecycleCallback {
                            handler?(sdpString)
                        }
                    }
                }
            }
        }
    }
    
    private func createAnswer() {
        guard let pc = peerConnection else { return }
        onTrace?("create-answer session=\(sessionId)")
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": nativeAudioReceiveEnabled ? "true" : "false",
                "OfferToReceiveVideo": videoTransceiver == nil ? "false" : "true",
            ],
            optionalConstraints: nil
        )
        let expectedLifecycleToken = lifecycleToken
        pc.answer(for: constraints) { [weak self, weak pc] sdp, error in
            guard let self else { return }
            self.scheduleState { [weak self, weak pc] in
                guard let self else { return }
                guard let pc,
                      Self.lifecycleGuardAllowsCallback(
                        peerConnectionMatches: self.peerConnection === pc,
                        isClosed: self.isClosed,
                        currentLifecycleToken: self.lifecycleToken,
                        expectedLifecycleToken: expectedLifecycleToken
                      ) else { return }
                if let error {
                    self.logger.error("❌ answer failed: \(error.localizedDescription, privacy: .public)")
                    self.onTrace?("create-answer failed session=\(self.sessionId) reason=create_answer_failed")
                    self.notifyDisconnectedIfNeeded(reason: "create_answer_failed")
                    self.close()
                    return
                }
                guard let sdp else {
                    self.logger.error("❌ answer completed without SDP")
                    self.notifyDisconnectedIfNeeded(reason: "create_answer_missing_sdp")
                    self.close()
                    return
                }
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
                    self.scheduleState { [weak self, weak pc] in
                        guard let self else { return }
                        guard let pc,
                              Self.lifecycleGuardAllowsCallback(
                                peerConnectionMatches: self.peerConnection === pc,
                                isClosed: self.isClosed,
                                currentLifecycleToken: self.lifecycleToken,
                                expectedLifecycleToken: expectedLifecycleToken
                              ) else { return }
                        if let err {
                            self.logger.error("❌ setLocalDescription(answer) failed: \(err.localizedDescription, privacy: .public)")
                            self.onTrace?("set-local-answer failed session=\(self.sessionId) reason=set_local_answer_failed")
                            self.notifyDisconnectedIfNeeded(reason: "set_local_answer_failed")
                            self.close()
                            return
                        }
                        self.logLocalSDPSummary(kind: "answer", sdp: sdpString)
                        self.lastEmittedLocalSDP = sdpString
                        self.onTrace?("local-answer-ready session=\(self.sessionId) bytes=\(sdpString.utf8.count)")
                        let handler = self.onLocalAnswer
                        self.dispatchActiveLifecycleCallback {
                            handler?(sdpString)
                        }
                    }
                }
            }
        }
    }

    private func emitCompletedLocalDescriptionIfNeeded() {
#if canImport(WebRTC)
        guard let localDescription = peerConnection?.localDescription else { return }
        let sdp = localDescription.sdp
        guard !sdp.isEmpty, sdp != lastEmittedLocalSDP else { return }
        lastEmittedLocalSDP = sdp
        logger.info("🔁 emitting gathered local description. sessionId=\(self.sessionId, privacy: .public) role=\(String(describing: self.role), privacy: .public)")
        logLocalSDPSummary(kind: role == .offerer ? "offer-gathered" : "answer-gathered", sdp: sdp)
        onTrace?("emit-complete-local-description session=\(sessionId) role=\(String(describing: role)) bytes=\(sdp.utf8.count)")
        switch role {
        case .offerer:
            let handler = onLocalOffer
            dispatchActiveLifecycleCallback {
                handler?(sdp)
            }
        case .answerer:
            let handler = onLocalAnswer
            dispatchActiveLifecycleCallback {
                handler?(sdp)
            }
        }
#endif
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
            nativeVideoTransceiver=\(self.videoTransceiver != nil, privacy: .public) \
            nativeAudioTransceiver=\(self.audioTransceiver != nil, privacy: .public)
            """
        )
        onTrace?("local-sdp-summary session=\(sessionId) kind=\(kind) video=\(videoSummary.description)")
    }

#endif
}

#if canImport(WebRTC)
@available(iOS 17.0, *)
extension WebRTCSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            self.logger.info("ICE connection state: \(String(describing: newState), privacy: .public)")
            self.onTrace?("ice-connection-state session=\(self.sessionId) state=\(String(describing: newState))")
            if newState == .connected || newState == .completed {
                self.inspectRemoteVideoTrackIfAvailable(peerConnection: peerConnection)
                self.scheduleRemoteVideoTrackInspection(peerConnection: peerConnection, reason: "ice-connected")
            }
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
            self.onTrace?("ice-gathering-state session=\(self.sessionId) state=\(String(describing: newState))")
            if newState == .complete {
                self.emitCompletedLocalDescriptionIfNeeded()
            }
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            self.onTrace?("did-generate-local-ice session=\(self.sessionId)")
            let handler = self.onLocalICECandidate
            let payload = WebRTCSignalingEnvelope.Payload(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
            self.dispatchActiveLifecycleCallback {
                handler?(payload)
            }
        }
    }
    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didStartReceivingOn transceiver: RTCRtpTransceiver
    ) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            switch transceiver.mediaType {
            case .video:
                self.captureRemoteVideoTrack(transceiver.receiver.track as? RTCVideoTrack, receiver: transceiver.receiver)
            case .audio:
                guard self.nativeAudioReceiveEnabled else { break }
                transceiver.receiver.delegate = self
            default:
                break
            }
        }
    }
    public func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams mediaStreams: [RTCMediaStream]
    ) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            if let videoTrack = rtpReceiver.track as? RTCVideoTrack {
                self.captureRemoteVideoTrack(videoTrack, receiver: rtpReceiver)
            } else if rtpReceiver.track?.kind == kRTCMediaStreamTrackKindAudio {
                guard self.nativeAudioReceiveEnabled else { return }
                rtpReceiver.delegate = self
            }
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        scheduleState { [weak self] in
            guard let self, self.peerConnection === peerConnection, !self.isClosed else { return }
            if self.isScreenChannel(dataChannel) {
                self.screenDataChannel = dataChannel
            } else if self.isControlChannel(dataChannel) {
                self.dataChannel = dataChannel
            } else {
                // 未知 label 通道不得收编为控制通道（会覆盖真实控制通道引用）。
                // 与 didReceiveMessage 的 fail-closed 语义保持一致：仅挂 delegate 观察，
                // 一旦该通道实际传输数据即按 unknown_data_channel_label 断开。
                self.onTrace?("did-open-data-channel-unknown session=\(self.sessionId) label=\(dataChannel.label)")
            }
            dataChannel.delegate = self
            self.inspectRemoteVideoTrackIfAvailable(peerConnection: peerConnection)
            self.scheduleRemoteVideoTrackInspection(peerConnection: peerConnection, reason: "data-channel-open")
            self.onTrace?("did-open-data-channel session=\(self.sessionId) label=\(dataChannel.label)")
            if self.isControlChannel(dataChannel) {
                self.notifyReadyIfNeeded()
            }
        }
    }
}

@available(iOS 17.0, *)
extension WebRTCSession: RTCRtpReceiverDelegate {
    public func rtpReceiver(
        _ rtpReceiver: RTCRtpReceiver,
        didReceiveFirstPacketFor mediaType: RTCRtpMediaType
    ) {
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            switch mediaType {
            case .video:
                self.logger.info("📡 remote native video receiver got first RTP packet. sessionId=\(self.sessionId, privacy: .public)")
                self.onTrace?("remote-video-first-packet session=\(self.sessionId)")
                let handler = self.onRemoteVideoFirstPacket
                self.dispatchActiveLifecycleCallback {
                    handler?()
                }
            case .audio:
                guard self.nativeAudioReceiveEnabled else { break }
                self.logger.info("📡 remote native audio receiver got first RTP packet. sessionId=\(self.sessionId, privacy: .public)")
                self.onTrace?("remote-audio-first-packet session=\(self.sessionId)")
                let handler = self.onRemoteAudioFirstPacket
                self.dispatchActiveLifecycleCallback {
                    handler?()
                }
            default:
                break
            }
        }
    }
}

@available(iOS 17.0, *)
extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            self.logger.info("DataChannel state: \(String(describing: dataChannel.readyState), privacy: .public) label=\(dataChannel.label, privacy: .public)")
            self.onTrace?("data-channel-state session=\(self.sessionId) label=\(dataChannel.label) state=\(String(describing: dataChannel.readyState))")
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
        // 注意：此回调运行在 libwebrtc 委托线程上，禁止在 scheduleState 之外访问
        // withState 保护的状态（包括 onTrace getter），否则与 stateQueue 上的
        // 阻塞式 WebRTC 代理调用（close/setRemoteDescription 等）构成跨线程等待环。
        scheduleState { [weak self] in
            guard let self, !self.isClosed else { return }
            if self.isScreenChannel(dataChannel) {
                self.onTrace?(
                    "data-channel-rx session=\(self.sessionId) label=\(dataChannel.label) kind=screen bytes=\(buffer.data.count) binary=\(buffer.isBinary ? 1 : 0)"
                )
                self.deliverInboundScreenData(buffer.data)
            } else if self.isControlChannel(dataChannel) {
                self.onTrace?(
                    "data-channel-rx session=\(self.sessionId) label=\(dataChannel.label) kind=control bytes=\(buffer.data.count) binary=\(buffer.isBinary ? 1 : 0)"
                )
                self.deliverInboundData(buffer.data)
            } else {
                self.onTrace?(
                    "data-channel-rx-failed session=\(self.sessionId) label=\(dataChannel.label) reason=unknown_label bytes=\(buffer.data.count)"
                )
                self.notifyDisconnectedIfNeeded(reason: "unknown_data_channel_label")
                self.close()
            }
        }
    }
}
#endif
