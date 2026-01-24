import Foundation
import OSLog

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
    
    public enum WebRTCError: Error, LocalizedError {
        case webRTCNotAvailable
        case peerConnectionCreationFailed
        case dataChannelNotReady
        case sdpFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .webRTCNotAvailable: return "WebRTC 模块不可用（请确认已添加 WebRTC 依赖）"
            case .peerConnectionCreationFailed: return "创建 RTCPeerConnection 失败"
            case .dataChannelNotReady: return "DataChannel 未就绪"
            case .sdpFailed(let msg): return "SDP 处理失败：\(msg)"
            }
        }
    }
    
    private let logger = Logger(subsystem: "com.skybridge.webrtc", category: "WebRTCSession")
    
    public let sessionId: String
    public let localDeviceId: String
    public let role: Role
    public let ice: ICEConfig
    
    public var onLocalOffer: (@Sendable (String) -> Void)?
    public var onLocalAnswer: (@Sendable (String) -> Void)?
    public var onLocalICECandidate: (@Sendable (WebRTCSignalingEnvelope.Payload) -> Void)?
    public var onData: (@Sendable (Data) -> Void)?
    public var onReady: (@Sendable () -> Void)?
    
#if canImport(WebRTC)
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
#endif
    
    public init(sessionId: String, localDeviceId: String, role: Role, ice: ICEConfig) {
        self.sessionId = sessionId
        self.localDeviceId = localDeviceId
        self.role = role
        self.ice = ice
        super.init()
    }
    
    public func start() throws {
#if canImport(WebRTC)
        // WebRTC factory is not Sendable; keep it as a local instance (avoid global/shared state under Swift 6 checks).
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        
        // ICE servers: STUN + TURN
        let stun = RTCIceServer(urlStrings: [ice.stunURL])
        let turn = RTCIceServer(urlStrings: [ice.turnURL], username: ice.turnUsername, credential: ice.turnPassword)
        config.iceServers = [stun, turn]
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
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
    
    public func setRemoteOffer(_ sdp: String) {
#if canImport(WebRTC)
        guard let pc = peerConnection else { return }
        let desc = RTCSessionDescription(type: .offer, sdp: sdp)
        pc.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("❌ setRemoteOffer failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            Task { @MainActor in
                self.createAnswer()
            }
        }
#endif
    }
    
    public func setRemoteAnswer(_ sdp: String) {
#if canImport(WebRTC)
        guard let pc = peerConnection else { return }
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        pc.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("❌ setRemoteAnswer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
#endif
    }
    
    public func addRemoteICECandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
#if canImport(WebRTC)
        guard let pc = peerConnection else { return }
        let cand = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex ?? 0, sdpMid: sdpMid)
        pc.add(cand) { _ in }
#endif
    }
    
    public func send(_ data: Data) throws {
#if canImport(WebRTC)
        guard let dc = dataChannel else { throw WebRTCError.dataChannelNotReady }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        _ = dc.sendData(buffer)
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
        onReady?()
    }
}

extension WebRTCSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger.info("DataChannel state: \(String(describing: dataChannel.readyState), privacy: .public)")
        if dataChannel.readyState == .open {
            onReady?()
        }
    }
    
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onData?(buffer.data)
    }
}
#endif


