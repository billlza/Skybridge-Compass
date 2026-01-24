import Foundation

/// WebRTC 信令消息（Offer/Answer/ICE Candidate）
///
/// 说明：
/// - 这是一套“应用层信令协议”，通过 WebSocket 传输。
/// - 服务端只需做 sessionId 维度的转发/广播（或基于 `to` 的定向转发）。
public struct WebRTCSignalingEnvelope: Codable, Sendable, Equatable {
    public enum MessageType: String, Codable, Sendable {
        case join
        case offer
        case answer
        case iceCandidate
        case leave
    }
    
    public let sessionId: String
    public let from: String
    public let to: String?
    public let type: MessageType
    public let payload: Payload?
    public let sentAt: Double
    
    public init(
        sessionId: String,
        from: String,
        to: String? = nil,
        type: MessageType,
        payload: Payload? = nil,
        sentAt: Double = Date().timeIntervalSince1970
    ) {
        self.sessionId = sessionId
        self.from = from
        self.to = to
        self.type = type
        self.payload = payload
        self.sentAt = sentAt
    }
    
    public struct Payload: Codable, Sendable, Equatable {
        public var sdp: String?
        
        public var candidate: String?
        public var sdpMid: String?
        public var sdpMLineIndex: Int32?
        
        public init(
            sdp: String? = nil,
            candidate: String? = nil,
            sdpMid: String? = nil,
            sdpMLineIndex: Int32? = nil
        ) {
            self.sdp = sdp
            self.candidate = candidate
            self.sdpMid = sdpMid
            self.sdpMLineIndex = sdpMLineIndex
        }
    }
}


