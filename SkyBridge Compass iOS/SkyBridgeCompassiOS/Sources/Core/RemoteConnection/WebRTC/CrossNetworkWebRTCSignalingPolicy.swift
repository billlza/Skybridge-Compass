import Foundation

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    static func resolvedSignalingWebSocketURLString(
        signalingOrigin: String?,
        fallbackWebSocketURL: String
    ) -> String {
        guard let rawOrigin = signalingOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOrigin.isEmpty,
              let originURL = URL(string: rawOrigin),
              let scheme = originURL.scheme?.lowercased(),
              let host = originURL.host,
              !host.isEmpty else {
            return fallbackWebSocketURL
        }

        let websocketScheme: String
        switch scheme {
        case "https":
            websocketScheme = "wss"
        case "http":
            websocketScheme = "ws"
        default:
            return fallbackWebSocketURL
        }

        var components = URLComponents()
        components.scheme = websocketScheme
        components.host = host
        components.port = originURL.port
        let originPath = originURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if originPath.isEmpty || originPath == "/" {
            components.path = "/ws"
        } else if originPath.hasSuffix("/ws") {
            components.path = originPath
        } else {
            components.path = originPath + "/ws"
        }
        return components.url?.absoluteString ?? fallbackWebSocketURL
    }

    static func shouldScheduleSignalingRecovery(
        isTransportEstablished: Bool,
        isSessionConnecting: Bool,
        suppressRecovery: Bool
    ) -> Bool {
        (isTransportEstablished || isSessionConnecting) && !suppressRecovery
    }

    static func shouldDeferSignalingSendRecovery(
        isHandshakeComplete: Bool,
        suppressRecovery: Bool,
        messageType: WebRTCSignalingEnvelope.MessageType
    ) -> Bool {
        isHandshakeComplete && !suppressRecovery && messageType != .leave
    }

    static func shouldDeferSignalingSendRecovery(
        isTransportEstablished: Bool,
        suppressRecovery: Bool,
        messageType: WebRTCSignalingEnvelope.MessageType
    ) -> Bool {
        shouldDeferSignalingSendRecovery(
            isHandshakeComplete: isTransportEstablished,
            suppressRecovery: suppressRecovery,
            messageType: messageType
        )
    }

    static func shouldUseOnDemandSignalingAfterTransportFailure(
        isHandshakeComplete: Bool,
        suppressRecovery: Bool
    ) -> Bool {
        isHandshakeComplete && !suppressRecovery
    }

    typealias SignalingFailureKind = WebSocketSignalingClient.SignalingFailureClass

    nonisolated static func classifySignalingFailureReason(_ reason: String) -> SignalingFailureKind {
        let reason = reason.lowercased()
        if reason.contains("token") && reason.contains("expired") {
            return .tokenExpired
        }
        if reason.contains("auth")
            || reason.contains("unauthorized")
            || reason.contains("forbidden")
            || reason.contains("bind_rejected") {
            return .authBindRejected
        }
        if reason.contains("invalid shard")
            || reason.contains("invalid session")
            || reason.contains("session mismatch")
            || reason.contains("scope mismatch")
            || reason.contains("unknown shard") {
            return .invalidShardOrSessionMismatch
        }
        if reason.contains("protocol") || reason.contains("malformed") {
            return .protocolViolation
        }
        if reason.contains("socket is not connected")
            || reason.contains("socket未连接")
            || reason.contains("not connected") {
            return .transientNetwork
        }
        return .transientServer
    }

    nonisolated static func isFatalPreTransportFailure(
        _ failureClass: SignalingFailureKind
    ) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }

    nonisolated static func isFatalPostTransportFailure(
        _ failureClass: SignalingFailureKind
    ) -> Bool {
        switch failureClass {
        case .authBindRejected, .invalidShardOrSessionMismatch, .protocolViolation:
            return true
        case .tokenExpired, .transientNetwork, .transientServer:
            return false
        }
    }
}
