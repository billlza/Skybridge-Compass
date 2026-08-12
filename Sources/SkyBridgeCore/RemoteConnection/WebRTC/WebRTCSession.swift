import Foundation
import OSLog
import SkyBridgeProtocolCore
import CoreVideo

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
/// Global SSL lifecycle guard for WebRTC.
///
/// `RTCInitializeSSL()` / `RTCCleanupSSL()` manage process-wide OpenSSL state. Calling cleanup per-session can
/// break other live sessions. We therefore retain/release with reference counting and only cleanup when the
/// last session is closed.
private enum WebRTCSSL {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refCount: Int = 0

    static func retain() {
        lock.lock()
        defer { lock.unlock() }
        if refCount == 0 {
            RTCInitializeSSL()
        }
        refCount += 1
    }

    static func release() {
        lock.lock()
        defer { lock.unlock() }
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            RTCCleanupSSL()
        }
    }
}
#endif

#if canImport(WebRTC)
/// Shared RTCPeerConnectionFactory provider.
///
/// A long-lived factory avoids repeated native stack bring-up/tear-down and prevents
/// edge-case creation failures when short-lived local factories race with session lifecycle.
private enum WebRTCPeerConnectionFactoryProvider {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sharedFactory: RTCPeerConnectionFactory?

    static func factory() -> RTCPeerConnectionFactory {
        lock.lock()
        defer { lock.unlock() }
        if let sharedFactory {
            return sharedFactory
        }
        let factory = RTCPeerConnectionFactory()
        sharedFactory = factory
        return factory
    }
}
#endif

#if canImport(WebRTC)
private actor WebRTCOutboundFrameGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
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

    public typealias ICEConfig = SkyBridgeICEConfiguration
    
    public enum WebRTCError: Error, LocalizedError, Sendable {
        case webRTCNotAvailable
        case peerConnectionCreationFailed
        case dataChannelNotReady
        case dataChannelNotOpen
        case dataChannelSendFailed
        case sdpFailed(String)
        case alreadyClosed
        
        public var errorDescription: String? {
            switch self {
            case .webRTCNotAvailable: return "WebRTC 模块不可用（请确认已添加 WebRTC 依赖）"
            case .peerConnectionCreationFailed: return "创建 RTCPeerConnection 失败"
            case .dataChannelNotReady: return "DataChannel 未就绪"
            case .dataChannelNotOpen: return "DataChannel 未打开"
            case .dataChannelSendFailed: return "DataChannel 发送失败"
            case .sdpFailed(let msg): return "SDP 处理失败：\(msg)"
            case .alreadyClosed: return "WebRTCSession 已关闭"
            }
        }
    }
    
    private let logger = Logger(subsystem: "com.skybridge.webrtc", category: "WebRTCSession")
    private static let publicFallbackSTUNURL = "stun:stun.l.google.com:19302"
    private static let controlChannelLabel = "skybridge"
    private static let screenChannelLabel = "skybridge-screen"
    
    public let sessionId: String
    public let localDeviceId: String
    public let role: Role
    public let ice: ICEConfig
    
    public var onLocalOffer: (@Sendable (String) -> Void)?
    public var onLocalAnswer: (@Sendable (String) -> Void)?
    public var onLocalICECandidate: (@Sendable (WebRTCSignalingEnvelope.Payload) -> Void)?
    public var onData: (@Sendable (Data) -> Void)? {
        didSet {
            flushPendingInboundDataIfNeeded()
        }
    }
    public var onScreenData: (@Sendable (Data) -> Void)? {
        didSet {
            flushPendingInboundScreenDataIfNeeded()
        }
    }
    public var onReady: (@Sendable () -> Void)?
    public var onDisconnected: (@Sendable (String) -> Void)?
    
#if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var screenDataChannel: RTCDataChannel?
    private var localVideoSource: RTCVideoSource?
    private var localVideoTrack: RTCVideoTrack?
    private var localVideoTransceiver: RTCRtpTransceiver?
    private var localVideoCapturer: RTCVideoCapturer?
    private var didLogOutgoingNativeVideoFrame = false
    private var didLogMissingOutgoingNativeVideoPipeline = false
    private var outgoingNativeVideoFrameCount: UInt64 = 0
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
    private let inboundDataLock = NSLock()
    private let inboundScreenDataLock = NSLock()
    private let outboundFrameLock = NSLock()
    private let outboundScreenFrameLock = NSLock()
    private let outboundFrameGate = WebRTCOutboundFrameGate()
    private let outboundScreenFrameGate = WebRTCOutboundFrameGate()
    private var pendingInboundDataBuffers: [Data] = []
    private var pendingInboundScreenDataBuffers: [Data] = []
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
    
    public init(sessionId: String, localDeviceId: String, role: Role, ice: ICEConfig) {
        self.sessionId = sessionId
        self.localDeviceId = localDeviceId
        self.role = role
        self.ice = ice
        super.init()
    }
    
    /// 关闭 WebRTC 会话并释放所有资源（PeerConnection / DataChannel / SSL）。
    ///
    /// 符合 IEEE TDSC 安全生命周期管理要求：
    /// - 主动关闭 DataChannel 防止数据残留
    /// - 关闭 PeerConnection 终止 ICE / DTLS-SRTP 会话
    /// - 调用 RTCCleanupSSL() 释放 OpenSSL 上下文
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        didNotifyDisconnected = true
        didNotifyReady = false
        hasRemoteDescription = false
        isSettingRemoteDescription = false
        lastEmittedLocalSDP = nil
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
        didLogOutgoingNativeVideoFrame = false
        didLogMissingOutgoingNativeVideoPipeline = false
        outgoingNativeVideoFrameCount = 0
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
        inboundDataLock.unlock()
        inboundScreenDataLock.lock()
        pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
        inboundScreenDataLock.unlock()
        onData = nil
        onScreenData = nil
        onReady = nil
        logger.info("⏹️ WebRTCSession closed sessionId=\(self.sessionId, privacy: .public)")
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
        guard !isClosed else { throw WebRTCError.alreadyClosed }
        didNotifyDisconnected = false
        didNotifyReady = false
        hasRemoteDescription = false
        lastEmittedLocalSDP = nil
#if canImport(WebRTC)
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        seenRemoteICECandidateKeys.removeAll(keepingCapacity: false)
        WebRTCSSL.retain()
        sslHeld = true
        let factory = WebRTCPeerConnectionFactoryProvider.factory()
        
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        if Self.shouldForceRelayOnlyForSmoke {
            config.iceTransportPolicy = .relay
            config.continualGatheringPolicy = .gatherOnce
        } else {
            config.continualGatheringPolicy = .gatherContinually
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

    private func notifyDisconnectedIfNeeded(reason: String) {
        guard !didNotifyDisconnected else { return }
        didNotifyDisconnected = true
        onDisconnected?(reason)
    }

    private func notifyReadyIfNeeded() {
        guard !didNotifyReady else { return }
        didNotifyReady = true
        onReady?()
    }

    private func flushPendingInboundDataIfNeeded() {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundDataLock.lock()
        handler = onData
        if handler != nil, !pendingInboundDataBuffers.isEmpty {
            buffered = pendingInboundDataBuffers
            pendingInboundDataBuffers.removeAll(keepingCapacity: false)
        }
        inboundDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
    }

    private func flushPendingInboundScreenDataIfNeeded() {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundScreenDataLock.lock()
        handler = onScreenData
        if handler != nil, !pendingInboundScreenDataBuffers.isEmpty {
            buffered = pendingInboundScreenDataBuffers
            pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
        }
        inboundScreenDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
    }

    private func deliverInboundData(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundDataLock.lock()
        if let activeHandler = onData {
            handler = activeHandler
            if !pendingInboundDataBuffers.isEmpty {
                buffered = pendingInboundDataBuffers
                pendingInboundDataBuffers.removeAll(keepingCapacity: false)
            }
        } else {
            pendingInboundDataBuffers.append(data)
            handler = nil
        }
        inboundDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
        handler(data)
    }

    private func deliverInboundScreenData(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)?
        var buffered: [Data] = []
        inboundScreenDataLock.lock()
        if let activeHandler = onScreenData {
            handler = activeHandler
            if !pendingInboundScreenDataBuffers.isEmpty {
                buffered = pendingInboundScreenDataBuffers
                pendingInboundScreenDataBuffers.removeAll(keepingCapacity: false)
            }
        } else {
            pendingInboundScreenDataBuffers.append(data)
            handler = nil
        }
        inboundScreenDataLock.unlock()

        guard let handler else { return }
        buffered.forEach(handler)
        handler(data)
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
        let normalizedOffer = Self.normalizedRemoteSDP(sdp)
        if hasRemoteDescription || isSettingRemoteDescription {
            absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp)
            logger.debug("ℹ️ ignore duplicate remote offer. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        guard let pc = peerConnection else { return }
        if pc.remoteDescription != nil {
            hasRemoteDescription = true
            absorbRemoteICECandidatesFromSDP(normalizedOffer.sdp)
            flushPendingRemoteICECandidates()
            logger.debug("ℹ️ remote offer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        let desc = RTCSessionDescription(type: .offer, sdp: normalizedOffer.sdp)
        isSettingRemoteDescription = true
        pc.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            self.isSettingRemoteDescription = false
            if let error {
                self.logger.error("❌ setRemoteOffer failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            self.hasRemoteDescription = true
            self.flushPendingRemoteICECandidates()
            Task { @MainActor in
                self.createAnswer()
            }
        }
#endif
    }
    
    public func setRemoteAnswer(_ sdp: String) {
#if canImport(WebRTC)
        guard let pc = peerConnection else { return }
        let normalizedAnswer = Self.normalizedRemoteSDP(sdp)
        if hasRemoteDescription || isSettingRemoteDescription || pc.remoteDescription != nil {
            hasRemoteDescription = true
            absorbRemoteICECandidatesFromSDP(normalizedAnswer.sdp)
            flushPendingRemoteICECandidates()
            logger.debug("ℹ️ ignore duplicate remote answer. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        let desc = RTCSessionDescription(type: .answer, sdp: normalizedAnswer.sdp)
        isSettingRemoteDescription = true
        pc.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            self.isSettingRemoteDescription = false
            if let error {
                // When the peer resends the same answer before our first callback returns,
                // WebRTC may already be stable and reject the duplicate call.
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
            self.flushPendingRemoteICECandidates()
        }
#endif
    }
    
    public func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
#if canImport(WebRTC)
        let cand = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex ?? 0, sdpMid: sdpMid)
        guard trackRemoteICECandidateIfNeeded(cand) else { return }
        guard hasRemoteDescription else {
            pendingRemoteICECandidates.append(cand)
            logger.debug("⏳ queue remote ICE candidate until remote description is set. sessionId=\(self.sessionId, privacy: .public) pending=\(self.pendingRemoteICECandidates.count, privacy: .public)")
            return
        }
        addRemoteICECandidateInternal(cand)
#endif
    }
    
    public func ensureScreenDataChannel() throws {
        guard !isClosed else { throw WebRTCError.alreadyClosed }
#if canImport(WebRTC)
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
        guard !isClosed else { throw WebRTCError.alreadyClosed }
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
        precondition(maxChunkBytes > 0, "maxChunkBytes must be greater than zero")

        lock.lock()
        defer { lock.unlock() }

        var framed = Data()
        var length = UInt32(payload.count).bigEndian
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
        precondition(maxChunkBytes > 0, "maxChunkBytes must be greater than zero")

        try await gate.run {
            try Task.checkCancellation()
            var framed = Data()
            var length = UInt32(payload.count).bigEndian
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
                try Task.checkCancellation()
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
            try Task.checkCancellation()
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
        prefersNativeOutgoingScreenTrack
            && localVideoTrack != nil
            && localVideoSource != nil
            && localVideoCapturer != nil
#else
        false
#endif
    }

    public func prepareOutgoingScreenVideo(width: Int, height: Int, fps: Int) {
#if canImport(WebRTC)
        guard let localVideoSource else { return }
        localVideoSource.adaptOutputFormat(
            toWidth: Int32(max(1, width)),
            height: Int32(max(1, height)),
            fps: Int32(max(1, fps))
        )
#endif
    }

    public func pushVideoFrame(pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
#if canImport(WebRTC)
        guard let localVideoSource,
              let localVideoCapturer else {
            if !didLogMissingOutgoingNativeVideoPipeline {
                didLogMissingOutgoingNativeVideoPipeline = true
                logger.warning(
                    """
                    ⚠️ native WebRTC screen frame dropped: outgoing pipeline not ready. \
                    sessionId=\(self.sessionId, privacy: .public) \
                    trackReady=\(self.localVideoTrack != nil, privacy: .public) \
                    sourceReady=\(self.localVideoSource != nil, privacy: .public) \
                    capturerReady=\(self.localVideoCapturer != nil, privacy: .public)
                    """
                )
            }
            return
        }
        didLogMissingOutgoingNativeVideoPipeline = false
        autoreleasepool {
            let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let frame = RTCVideoFrame(
                buffer: buffer,
                rotation: ._0,
                timeStampNs: timeStampNs
            )
            if !didLogOutgoingNativeVideoFrame {
                didLogOutgoingNativeVideoFrame = true
                logger.info(
                    "🎥 submitting first native WebRTC screen frame. sessionId=\(self.sessionId, privacy: .public) size=\(CVPixelBufferGetWidth(pixelBuffer), privacy: .public)x\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public) pixelFormat=\(CVPixelBufferGetPixelFormatType(pixelBuffer), privacy: .public)"
                )
            }
            localVideoSource.capturer(localVideoCapturer, didCapture: frame)
        }
        outgoingNativeVideoFrameCount &+= 1
        let now = Date()
        if now.timeIntervalSince(lastOutgoingNativeVideoFrameLogAt) >= 2.0 {
            lastOutgoingNativeVideoFrameLogAt = now
            logger.info(
                "📈 native WebRTC screen frames submitted: sessionId=\(self.sessionId, privacy: .public) count=\(self.outgoingNativeVideoFrameCount, privacy: .public)"
            )
        }
#endif
    }

    private func dataChannelBufferedAmountBytes(
        preferScreenChannel: Bool,
        fallbackToControlChannel: Bool
    ) -> UInt64 {
#if canImport(WebRTC)
        if preferScreenChannel,
           let screenDataChannel,
           screenDataChannel.readyState == .open {
            return screenDataChannel.bufferedAmount
        }
        if fallbackToControlChannel || !preferScreenChannel {
            return dataChannel?.bufferedAmount ?? 0
        }
        return screenDataChannel?.bufferedAmount ?? 0
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
        guard let screenDataChannel else { return false }
        return screenDataChannel.readyState == .open
#else
        return false
#endif
    }

    public func currentICETransportPath() async -> ICETransportPath {
#if canImport(WebRTC)
        guard let peerConnection else { return .unknown }
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

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                state.resume(.unknown, continuation: continuation)
            }
        }
#else
        return .unknown
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

    private func configureOutgoingScreenVideoIfNeeded(
        factory: RTCPeerConnectionFactory,
        peerConnection: RTCPeerConnection
    ) {
        guard localVideoTrack == nil else { return }

        let videoSource = factory.videoSource(forScreenCast: true)
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "screen-\(sessionId)")
        let videoCapturer = RTCVideoCapturer(delegate: videoSource)
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["screen-\(sessionId)"]

        guard let transceiver = peerConnection.addTransceiver(with: videoTrack, init: transceiverInit) else {
            logger.warning("⚠️ failed to create native screen video transceiver. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        configureOutgoingScreenSenderParametersIfNeeded(transceiver.sender)

        localVideoSource = videoSource
        localVideoTrack = videoTrack
        localVideoCapturer = videoCapturer
        localVideoTransceiver = transceiver
        videoSource.adaptOutputFormat(toWidth: 1280, height: 720, fps: 60)
        logger.info(
            "🎥 native WebRTC screen track enabled. sessionId=\(self.sessionId, privacy: .public) fps=\(60, privacy: .public)"
        )
    }

    private func configureOutgoingScreenSenderParametersIfNeeded(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        if !parameters.encodings.isEmpty {
            parameters.encodings = parameters.encodings.map { encoding in
                encoding.isActive = true
                encoding.maxFramerate = NSNumber(value: 60)
                return encoding
            }
        }
        sender.parameters = parameters
    }

    static func offerToReceiveVideoConstraintValue(hasNegotiatedVideoTransceiver: Bool) -> String {
        hasNegotiatedVideoTransceiver ? "true" : "false"
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

    private struct NormalizedRemoteSDP {
        let sdp: String
        let droppedSessionLevelCandidateLines: Int
        let deduplicatedCandidateLines: Int
    }

    private static func normalizedRemoteSDP(_ sdp: String) -> NormalizedRemoteSDP {
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
        return NormalizedRemoteSDP(
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
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                self.logger.error("❌ offer failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let sdp else { return }
            let sdpString = sdp.sdp
            guard let pc = self.peerConnection else { return }
            pc.setLocalDescription(sdp) { [weak self] err in
                guard let self else { return }
                if let err {
                    self.logger.error("❌ setLocalDescription(offer) failed: \(err.localizedDescription, privacy: .public)")
                    return
                }
                self.logLocalSDPSummary(kind: "offer", sdp: sdpString)
                self.lastEmittedLocalSDP = sdpString
                self.onLocalOffer?(sdpString)
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
        pc.answer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            if let error {
                self.logger.error("❌ answer failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let sdp else { return }
            let sdpString = sdp.sdp
            guard let pc = self.peerConnection else { return }
            pc.setLocalDescription(sdp) { [weak self] err in
                guard let self else { return }
                if let err {
                    self.logger.error("❌ setLocalDescription(answer) failed: \(err.localizedDescription, privacy: .public)")
                    return
                }
                self.logLocalSDPSummary(kind: "answer", sdp: sdpString)
                self.lastEmittedLocalSDP = sdpString
                self.onLocalAnswer?(sdpString)
            }
        }
    }

    private func logLocalSDPSummary(kind: String, sdp: String) {
        let hasVideoMedia = sdp.contains("\r\nm=video ") || sdp.hasPrefix("m=video ")
        let direction: String = {
            if sdp.contains("\r\na=sendrecv") || sdp.hasPrefix("a=sendrecv") {
                return "sendrecv"
            }
            if sdp.contains("\r\na=sendonly") || sdp.hasPrefix("a=sendonly") {
                return "sendonly"
            }
            if sdp.contains("\r\na=recvonly") || sdp.hasPrefix("a=recvonly") {
                return "recvonly"
            }
            if sdp.contains("\r\na=inactive") || sdp.hasPrefix("a=inactive") {
                return "inactive"
            }
            return "unspecified"
        }()
        logger.info(
            """
            📄 local SDP ready. sessionId=\(self.sessionId, privacy: .public) \
            kind=\(kind, privacy: .public) \
            hasVideo=\(hasVideoMedia, privacy: .public) \
            direction=\(direction, privacy: .public) \
            nativeTrack=\(self.localVideoTrack != nil, privacy: .public) \
            nativeTransceiver=\(self.localVideoTransceiver != nil, privacy: .public)
            """
        )
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
            onLocalOffer?(sdp)
        case .answerer:
            onLocalAnswer?(sdp)
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
#endif
}

#if canImport(WebRTC)
extension WebRTCSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        logger.info("ICE connection state: \(String(describing: newState), privacy: .public)")
        switch newState {
        case .failed:
            notifyDisconnectedIfNeeded(reason: "ice_failed")
        case .closed:
            notifyDisconnectedIfNeeded(reason: "ice_closed")
        default:
            break
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        logger.info("ICE gathering state: \(String(describing: newState), privacy: .public)")
        if newState == .complete {
            emitCompletedLocalDescriptionIfNeeded()
        }
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalICECandidate?(.init(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        logger.info("✅ DataChannel opened by remote label=\(dataChannel.label, privacy: .public)")
        if isScreenChannel(dataChannel) {
            self.screenDataChannel = dataChannel
        } else {
            self.dataChannel = dataChannel
        }
        dataChannel.delegate = self
        if isControlChannel(dataChannel) {
            notifyReadyIfNeeded()
        }
    }
}

extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger.info("DataChannel state: \(String(describing: dataChannel.readyState), privacy: .public) label=\(dataChannel.label, privacy: .public)")
        if dataChannel.readyState == .open, isControlChannel(dataChannel) {
            notifyReadyIfNeeded()
        } else if dataChannel.readyState == .closed, isControlChannel(dataChannel) {
            notifyDisconnectedIfNeeded(reason: "data_channel_closed")
        } else if dataChannel.readyState == .closed, isScreenChannel(dataChannel) {
            if screenDataChannel === dataChannel {
                screenDataChannel = nil
            }
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if isScreenChannel(dataChannel) {
            deliverInboundScreenData(buffer.data)
        } else {
            deliverInboundData(buffer.data)
        }
    }
}
#endif
