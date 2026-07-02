import Foundation

public enum CurrentPathSignalingCredentialTransport: Sendable, Equatable {
    case headers
    case queryToken
}

public enum CurrentPathSignalingWebSocketPolicy {
    public static let sessionIDHeader = "X-SkyBridge-Session-Id"
    public static let sessionTokenHeader = "X-SkyBridge-Session"
    public static let clientVersionHeader = "X-SkyBridge-Client-Version"
    public static let protocolVersionHeader = "X-SkyBridge-Protocol-Version"

    public static let maxWebSocketPathLength = 256
    public static let maxSessionIDLength = 512
    public static let maxSessionTokenLength = 4096
    public static let maxVersionLength = 64

    public enum PolicyError: LocalizedError, Sendable, Equatable {
        case invalidWebSocketPath

        public var errorDescription: String? {
            switch self {
            case .invalidWebSocketPath:
                return "invalid current-path signaling websocket path"
            }
        }
    }

    public static func validatedWebSocketPath(_ rawPath: String?) throws -> String {
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
            throw PolicyError.invalidWebSocketPath
        }
        return trimmed
    }

    public static func webSocketURL(
        signalingServerOrigin: String,
        wsPath: String?,
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String,
        credentialTransport: CurrentPathSignalingCredentialTransport = .headers
    ) -> URL? {
        let origin = signalingServerOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionID = normalizedSessionID(sessionID)
        let sessionToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientVersion = clientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolVersion = protocolVersion.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let canonicalOrigin = try? CurrentPathOriginPolicy.canonicalOrigin(origin),
              isValidCredentialValue(normalizedSessionID, maxLength: maxSessionIDLength),
              isValidCredentialValue(sessionToken, maxLength: maxSessionTokenLength),
              isValidCredentialValue(clientVersion, maxLength: maxVersionLength),
              isValidCredentialValue(protocolVersion, maxLength: maxVersionLength),
              var components = URLComponents(string: canonicalOrigin),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let path = try? validatedWebSocketPath(wsPath) else {
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

    public static func webSocketHeaders(
        sessionID: String,
        sessionToken: String,
        clientVersion: String,
        protocolVersion: String,
        credentialTransport: CurrentPathSignalingCredentialTransport = .headers
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
