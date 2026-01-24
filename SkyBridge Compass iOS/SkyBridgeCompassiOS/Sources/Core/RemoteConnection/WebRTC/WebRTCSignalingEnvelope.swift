import Foundation

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


