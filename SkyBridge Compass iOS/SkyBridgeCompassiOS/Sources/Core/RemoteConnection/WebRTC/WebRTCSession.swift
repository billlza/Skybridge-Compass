import Foundation
import OSLog

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)
/// Global SSL lifecycle guard for WebRTC.
///
/// `RTCInitializeSSL()` / `RTCCleanupSSL()` manage process-wide OpenSSL state. Calling cleanup per-session can
/// break other live sessions. We therefore retain/release with reference counting and only cleanup when the
/// last session is closed.
@available(iOS 17.0, *)
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
@available(iOS 17.0, *)
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

@available(iOS 17.0, *)
public final class WebRTCSession: NSObject, @unchecked Sendable {
    public enum Role: Sendable { case offerer, answerer }
    
    public struct ICEConfig: Sendable {
        public var stunURL: String
        public var turnURL: String
        public var turnUsername: String
        public var turnPassword: String
        
        public init(stunURL: String, turnURL: String, turnUsername: String, turnPassword: String) {
            self.stunURL = stunURL
            self.turnURL = turnURL
            self.turnUsername = turnUsername
            self.turnPassword = turnPassword
        }
    }
    
    public enum WebRTCError: Error, LocalizedError, Sendable {
        case webRTCNotAvailable
        case peerConnectionCreationFailed
        case dataChannelNotReady
        case dataChannelNotOpen
        case dataChannelSendFailed
        case alreadyClosed
        
        public var errorDescription: String? {
            switch self {
            case .webRTCNotAvailable: return "WebRTC 模块不可用（请确认已添加 WebRTC 依赖）"
            case .peerConnectionCreationFailed: return "创建 RTCPeerConnection 失败"
            case .dataChannelNotReady: return "DataChannel 未就绪"
            case .dataChannelNotOpen: return "DataChannel 未打开"
            case .dataChannelSendFailed: return "DataChannel 发送失败"
            case .alreadyClosed: return "WebRTCSession 已关闭"
            }
        }
    }
    
    private let logger = Logger(subsystem: "com.skybridge.compass.ios", category: "WebRTCSession")
    private static let publicFallbackSTUNURL = "stun:stun.l.google.com:19302"
    
    public let sessionId: String
    public let localDeviceId: String
    public let role: Role
    public let ice: ICEConfig
    
    public var onLocalOffer: (@Sendable (String) -> Void)?
    public var onLocalAnswer: (@Sendable (String) -> Void)?
    public var onLocalICECandidate: (@Sendable (WebRTCSignalingEnvelope.Payload) -> Void)?
    public var onData: (@Sendable (Data) -> Void)?
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

#if canImport(WebRTC)
    private func buildIceServers() -> [RTCIceServer] {
        var servers: [RTCIceServer] = []

        if let stunURL = Self.normalizedICEURL(ice.stunURL), stunURL.hasPrefix("stun:") {
            servers.append(RTCIceServer(urlStrings: [stunURL]))
        } else {
            logger.warning("⚠️ Invalid STUN URL. sessionId=\(self.sessionId, privacy: .public)")
        }

        let turnURL = Self.normalizedICEURL(ice.turnURL)
        let turnUsername = Self.normalizedCredential(ice.turnUsername)
        let turnPassword = Self.normalizedCredential(ice.turnPassword)

        if let turnURL, (turnURL.hasPrefix("turn:") || turnURL.hasPrefix("turns:")) {
            if !turnUsername.isEmpty, !turnPassword.isEmpty {
                servers.append(RTCIceServer(urlStrings: [turnURL], username: turnUsername, credential: turnPassword))
            } else {
                logger.warning("⚠️ TURN credentials missing, degraded to STUN-only. sessionId=\(self.sessionId, privacy: .public)")
            }
        } else if !ice.turnURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.warning("⚠️ Invalid TURN URL. sessionId=\(self.sessionId, privacy: .public)")
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
        config.continualGatheringPolicy = .gatherContinually
        config.iceServers = buildIceServers()
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
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
            createOffer()
        }
        
        logger.info("✅ WebRTCSession started role=\(String(describing: self.role), privacy: .public) sessionId=\(self.sessionId, privacy: .public)")
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
	            self.createAnswer()
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
#endif
    
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
    
#if canImport(WebRTC)
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
        self.dataChannel = dataChannel
        dataChannel.delegate = self
        notifyReadyIfNeeded()
    }
}

@available(iOS 17.0, *)
extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            notifyReadyIfNeeded()
        } else if dataChannel.readyState == .closed {
            notifyDisconnectedIfNeeded(reason: "data_channel_closed")
        }
    }
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onData?(buffer.data)
    }
}
#endif
