import Foundation
import OSLog
import SkyBridgeProtocolCore

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
    func run<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        try await operation()
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
    public var onReady: (@Sendable () -> Void)?
    public var onDisconnected: (@Sendable (String) -> Void)?
    
#if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var pendingRemoteICECandidates: [RTCIceCandidate] = []
#endif
    
    private var isClosed = false
    private var sslHeld = false
    private var didNotifyDisconnected = false
    private var didNotifyReady = false
    private var hasRemoteDescription = false
    private var isSettingRemoteDescription = false
    private let inboundDataLock = NSLock()
    private let outboundFrameLock = NSLock()
    private let outboundFrameGate = WebRTCOutboundFrameGate()
    private var pendingInboundDataBuffers: [Data] = []
    
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
        onDisconnected = nil
#if canImport(WebRTC)
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
        dataChannel?.close()
        dataChannel = nil
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
        onData = nil
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
#if canImport(WebRTC)
        pendingRemoteICECandidates.removeAll(keepingCapacity: false)
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
        
        if role == .offerer {
            let dcConfig = RTCDataChannelConfiguration()
            dcConfig.isOrdered = true
            dcConfig.isNegotiated = false
            let dc = pc.dataChannel(forLabel: "skybridge", configuration: dcConfig)
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
    
    public func setRemoteOffer(_ sdp: String) {
#if canImport(WebRTC)
        if hasRemoteDescription || isSettingRemoteDescription {
            logger.debug("ℹ️ ignore duplicate remote offer. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        guard let pc = peerConnection else { return }
        if pc.remoteDescription != nil {
            hasRemoteDescription = true
            flushPendingRemoteICECandidates()
            logger.debug("ℹ️ remote offer already applied; ignore. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
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
        if hasRemoteDescription || isSettingRemoteDescription || pc.remoteDescription != nil {
            hasRemoteDescription = true
            flushPendingRemoteICECandidates()
            logger.debug("ℹ️ ignore duplicate remote answer. sessionId=\(self.sessionId, privacy: .public)")
            return
        }
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
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
        guard hasRemoteDescription else {
            pendingRemoteICECandidates.append(cand)
            logger.debug("⏳ queue remote ICE candidate until remote description is set. sessionId=\(self.sessionId, privacy: .public) pending=\(self.pendingRemoteICECandidates.count, privacy: .public)")
            return
        }
        addRemoteICECandidateInternal(cand)
#endif
    }
    
    public func send(_ data: Data) throws {
        guard !isClosed else { throw WebRTCError.alreadyClosed }
#if canImport(WebRTC)
        guard let dc = dataChannel else { throw WebRTCError.dataChannelNotReady }
        guard dc.readyState == .open else { throw WebRTCError.dataChannelNotOpen }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else { throw WebRTCError.dataChannelSendFailed }
#else
        throw WebRTCError.webRTCNotAvailable
#endif
    }

    public func sendFramedPayload(_ payload: Data, maxChunkBytes: Int = 8 * 1024) throws {
        precondition(maxChunkBytes > 0, "maxChunkBytes must be greater than zero")

        outboundFrameLock.lock()
        defer { outboundFrameLock.unlock() }

        var framed = Data()
        var length = UInt32(payload.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(payload)

        var offset = 0
        while offset < framed.count {
            let end = min(offset + maxChunkBytes, framed.count)
            let chunk = Data(framed[offset..<end])
            try send(chunk)
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
        precondition(maxChunkBytes > 0, "maxChunkBytes must be greater than zero")

        try await outboundFrameGate.run {
            var framed = Data()
            var length = UInt32(payload.count).bigEndian
            framed.append(Data(bytes: &length, count: 4))
            framed.append(payload)

            var offset = 0
            while offset < framed.count {
                try await waitForBufferedAmountBelow(
                    maxBufferedAmountBytes,
                    pollInterval: pollInterval,
                    timeout: drainTimeout
                )
                let end = min(offset + maxChunkBytes, framed.count)
                let chunk = Data(framed[offset..<end])
                try send(chunk)
                offset = end
            }

            try await waitForBufferedAmountBelow(
                maxBufferedAmountBytes,
                pollInterval: pollInterval,
                timeout: drainTimeout
            )
        }
    }

    public func dataChannelBufferedAmountBytes() -> UInt64 {
#if canImport(WebRTC)
        return dataChannel?.bufferedAmount ?? 0
#else
        return 0
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
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while dataChannelBufferedAmountBytes() > threshold {
            if clock.now >= deadline {
                throw WebRTCError.dataChannelSendFailed
            }
            try await Task.sleep(for: pollInterval)
        }
    }
    
#if canImport(WebRTC)
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

    private func createOffer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)
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
                self.onLocalOffer?(sdpString)
            }
        }
    }
    
    private func createAnswer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"], optionalConstraints: nil)
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
                self.onLocalAnswer?(sdpString)
            }
        }
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
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalICECandidate?(.init(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        logger.info("✅ DataChannel opened by remote")
        self.dataChannel = dataChannel
        dataChannel.delegate = self
        notifyReadyIfNeeded()
    }
}

extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger.info("DataChannel state: \(String(describing: dataChannel.readyState), privacy: .public)")
        if dataChannel.readyState == .open {
            notifyReadyIfNeeded()
        } else if dataChannel.readyState == .closed {
            notifyDisconnectedIfNeeded(reason: "data_channel_closed")
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        deliverInboundData(buffer.data)
    }
}
#endif
