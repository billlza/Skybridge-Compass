import Foundation

@available(iOS 17.0, *)
enum CurrentPathSignalingCredentialTransportCompat {
    case headers
    case queryToken
}

@available(iOS 17.0, *)
enum CurrentPathSignalingWebSocketPolicyCompat {
    static let sessionIDHeader = "X-SkyBridge-Session-Id"
    static let sessionTokenHeader = "X-SkyBridge-Session"
    static let clientVersionHeader = "X-SkyBridge-Client-Version"
    static let protocolVersionHeader = "X-SkyBridge-Protocol-Version"

    static let maxWebSocketPathLength = 256
    static let maxSessionIDLength = 512
    static let maxSessionTokenLength = 4096
    static let maxVersionLength = 64

    static func validatedWebSocketPath(_ rawPath: String?) -> String? {
        let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.first == "/",
              trimmed != "/",
              trimmed.count <= maxWebSocketPathLength,
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains("\\"),
              !trimmed.contains("//"),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && scalar.value >= 0x21
                      && scalar.value != 0x7F
                      && !CharacterSet.whitespacesAndNewlines.contains(scalar)
              }),
              pathSegmentsAreSafe(trimmed),
              percentEscapesAreSafe(trimmed) else {
            return nil
        }
        return trimmed
    }

    static func webSocketURL(
        signalingServerOrigin: String?,
        wsPath: String?,
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String,
        credentialTransport: CurrentPathSignalingCredentialTransportCompat
    ) -> URL? {
        guard let rawOrigin = signalingServerOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOrigin.isEmpty,
              let canonicalOrigin = try? CurrentPathSecurityCompat.canonicalOrigin(rawOrigin),
              var components = URLComponents(string: canonicalOrigin),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let path = validatedWebSocketPath(wsPath) else {
            return nil
        }

        let normalizedSessionID = normalizedSessionID(sessionID)
        let sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientVersion = clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolVersion = protocolVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCredentialValue(normalizedSessionID, maxLength: maxSessionIDLength),
              isValidCredentialValue(sessionToken, maxLength: maxSessionTokenLength),
              isValidCredentialValue(clientVersion, maxLength: maxVersionLength),
              isValidCredentialValue(protocolVersion, maxLength: maxVersionLength) else {
            return nil
        }

        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = path
        components.fragment = nil
        var queryItems = [
            URLQueryItem(name: "shard", value: normalizedSessionID),
            URLQueryItem(name: "cv", value: clientVersion),
            URLQueryItem(name: "pv", value: protocolVersion)
        ]
        if credentialTransport == .queryToken {
            queryItems.append(URLQueryItem(name: "st", value: sessionToken))
        }
        components.queryItems = queryItems
        return components.url
    }

    static func webSocketHeaders(
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String,
        credentialTransport: CurrentPathSignalingCredentialTransportCompat
    ) -> [String: String]? {
        let normalizedSessionID = normalizedSessionID(sessionID)
        let sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientVersion = clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolVersion = protocolVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCredentialValue(normalizedSessionID, maxLength: maxSessionIDLength),
              isValidCredentialValue(sessionToken, maxLength: maxSessionTokenLength),
              isValidCredentialValue(clientVersion, maxLength: maxVersionLength),
              isValidCredentialValue(protocolVersion, maxLength: maxVersionLength) else {
            return nil
        }

        var headers = [
            clientVersionHeader: clientVersion,
            protocolVersionHeader: protocolVersion
        ]
        if credentialTransport == .headers {
            headers[sessionIDHeader] = normalizedSessionID
            headers[sessionTokenHeader] = sessionToken
        }
        return headers
    }

    private static func normalizedSessionID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isValidCredentialValue(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maxLength else { return false }
        return !value.unicodeScalars.contains { scalar in
            scalar.value < 0x20
                || scalar.value == 0x7F
                || scalar == ","
        }
    }

    private static func pathSegmentsAreSafe(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "" else { return false }
        return segments.dropFirst().allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
        }
    }

    private static func percentEscapesAreSafe(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            guard scalars[index] == "%" else {
                index = scalars.index(after: index)
                continue
            }
            let firstHexIndex = scalars.index(after: index)
            let secondHexIndex = scalars.index(firstHexIndex, offsetBy: 1, limitedBy: scalars.endIndex)
            guard firstHexIndex < scalars.endIndex,
                  let secondHexIndex,
                  secondHexIndex < scalars.endIndex,
                  let highNibble = scalars[firstHexIndex].hexNibble,
                  let lowNibble = scalars[secondHexIndex].hexNibble else {
                return false
            }
            let byte = (highNibble << 4) | lowNibble
            if byte < 0x20
                || byte == 0x7F
                || byte == 0x2E
                || byte == 0x2F
                || byte == 0x5C
                || byte == 0x3F
                || byte == 0x23 {
                return false
            }
            index = scalars.index(after: secondHexIndex)
        }
        return true
    }
}

private extension Unicode.Scalar {
    var hexNibble: UInt8? {
        switch value {
        case 0x30...0x39:
            return UInt8(value - 0x30)
        case 0x41...0x46:
            return UInt8(value - 0x41 + 10)
        case 0x61...0x66:
            return UInt8(value - 0x61 + 10)
        default:
            return nil
        }
    }
}

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    static func resolvedSignalingWebSocketURLString(
        signalingOrigin: String?,
        signalingWebSocketPath: String?
    ) -> String? {
        guard let url = CurrentPathSignalingWebSocketPolicyCompat.webSocketURL(
            signalingServerOrigin: signalingOrigin,
            wsPath: signalingWebSocketPath,
            sessionID: "compat-session",
            sessionToken: "compat-token",
            clientVersion: "0",
            protocolVersion: "1",
            credentialTransport: .headers
        ),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = nil
        return components.url?.absoluteString
    }

    static func normalizedSignalingWebSocketPath(_ rawPath: String?) -> String? {
        CurrentPathSignalingWebSocketPolicyCompat.validatedWebSocketPath(rawPath)
    }

    func validateCurrentPathWebSocketPath(_ rawPath: String?) throws -> String {
        guard let rawPath,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "missing current-path signaling websocket path"]
            )
        }
        guard let normalized = Self.normalizedSignalingWebSocketPath(rawPath) else {
            throw NSError(
                domain: "CrossNetworkWebRTCManager",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "invalid current-path signaling websocket path"]
            )
        }
        return normalized
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

    nonisolated static func publicSignalingFailureClass(
        _ failureClass: SignalingFailureKind
    ) -> String {
        switch failureClass {
        case .authBindRejected:
            return "auth_bind_rejected"
        case .invalidShardOrSessionMismatch:
            return "invalid_shard_or_session_mismatch"
        case .tokenExpired:
            return "token_expired"
        case .transientNetwork:
            return "transient_network"
        case .transientServer:
            return "transient_server"
        case .protocolViolation:
            return "protocol_violation"
        }
    }

    nonisolated static func publicSignalingFailureCode(
        _ failureClass: SignalingFailureKind
    ) -> String {
        switch failureClass {
        case .authBindRejected:
            return "signaling_auth_rejected"
        case .invalidShardOrSessionMismatch:
            return "signaling_session_scope_mismatch"
        case .tokenExpired:
            return "signaling_token_expired"
        case .transientNetwork:
            return "signaling_network_unavailable"
        case .transientServer:
            return "signaling_server_error"
        case .protocolViolation:
            return "signaling_protocol_violation"
        }
    }

    nonisolated static func publicSignalingSessionLabel(_ sessionId: String?) -> String {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return "-"
        }
        return SkyBridgeDiagnosticReference.stableReference(sessionId)
    }
}
