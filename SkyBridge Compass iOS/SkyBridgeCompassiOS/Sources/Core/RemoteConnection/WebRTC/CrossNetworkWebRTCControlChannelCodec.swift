import Foundation

@available(iOS 17.0, *)
enum CrossNetworkWebRTCControlChannelCodec {
    nonisolated static func bootstrapAppMessageKind(_ message: AppMessage) -> String {
        switch message {
        case .clipboard:
            return "clipboard"
        case .pairingIdentityExchange:
            return "pairingIdentityExchange"
        case .kemRefreshRequest:
            return "kemRefreshRequest"
        case .signedKEMRefresh:
            return "signedKEMRefresh"
        case .kemRefreshFailure:
            return "kemRefreshFailure"
        case .protocolIdentityBindingRequest:
            return "protocolIdentityBindingRequest"
        case .signedProtocolIdentityBinding:
            return "signedProtocolIdentityBinding"
        case .heartbeat:
            return "heartbeat"
        case .peerDisconnecting:
            return "peerDisconnecting"
        case .ping:
            return "ping"
        case .pong:
            return "pong"
        }
    }

    nonisolated static func isLikelyCompleteHandshakeControlPacket(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx/webrtc")
        if frame.count == 38, (try? HandshakeFinished.decode(from: frame)) != nil { return true }
        guard frame.count >= 5 else { return false }
        guard frame.first == HandshakeConstants.protocolVersion else { return false }
        if (try? HandshakeMessageA.decode(from: frame)) != nil { return true }
        if (try? HandshakeMessageB.decode(from: frame)) != nil { return true }
        return false
    }

    nonisolated static func isActiveHandshakeDriverFrame(_ data: Data) -> Bool {
        let frame = HandshakePadding.unwrapIfNeeded(data, label: "rx/webrtc")
        if isLikelyCompleteHandshakeControlPacket(frame) { return true }
        return false
    }
}
