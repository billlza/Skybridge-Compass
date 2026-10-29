import CryptoKit
import Foundation

enum RTSPDigestAlgorithm: String, Sendable, Equatable {
    case md5 = "MD5"
    case sha256 = "SHA-256"
}

struct RTSPDigestChallenge: Sendable, Equatable {
    let realm: String
    let nonce: String
    let algorithm: RTSPDigestAlgorithm
    let opaque: String?
    let isStale: Bool

    init(
        realm: String,
        nonce: String,
        algorithm: RTSPDigestAlgorithm,
        opaque: String? = nil,
        isStale: Bool = false
    ) {
        self.realm = realm
        self.nonce = nonce
        self.algorithm = algorithm
        self.opaque = opaque
        self.isStale = isStale
    }
}

enum RTSPAuthenticationSelection: Sendable, Equatable {
    case digest(RTSPDigestChallenge)
    case basic
}

enum RTSPAuthentication {
    private struct ChallengeInventory {
        var digestChallenges: [RTSPDigestChallenge] = []
        var offeredDigest = false
        var offeredBasic = false
        var unsupportedReasons: [String] = []
    }

    static func selectChallenge(
        from headerValues: [String],
        isSecureTransport: Bool
    ) throws -> RTSPAuthenticationSelection {
        let inventory = try challengeInventory(from: headerValues)

        if let strongest = inventory.digestChallenges.max(by: { lhs, rhs in
            strength(of: lhs.algorithm) < strength(of: rhs.algorithm)
        }) {
            return .digest(strongest)
        }
        if inventory.offeredDigest {
            let reason = inventory.unsupportedReasons.isEmpty
                ? "no supported Digest challenge was offered"
                : inventory.unsupportedReasons.joined(separator: "; ")
            throw SkyBridgeCameraError.unsupportedAuthentication(reason)
        }
        if inventory.offeredBasic {
            guard isSecureTransport else {
                throw SkyBridgeCameraError.basicAuthenticationRequiresTLS
            }
            return .basic
        }

        let reason = inventory.unsupportedReasons.isEmpty
            ? "no supported challenge was offered"
            : inventory.unsupportedReasons.joined(separator: "; ")
        throw SkyBridgeCameraError.unsupportedAuthentication(reason)
    }

    static func selectStaleDigestChallenge(
        from headerValues: [String],
        replacing current: RTSPDigestChallenge
    ) throws -> RTSPDigestChallenge? {
        let inventory = try challengeInventory(from: headerValues)
        let staleChallenges = inventory.digestChallenges.filter(\.isStale)
        guard !staleChallenges.isEmpty else { return nil }

        let compatible = staleChallenges.filter {
            $0.realm == current.realm && $0.algorithm == current.algorithm
        }
        guard !compatible.isEmpty else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "a stale Digest challenge changed the authentication realm or algorithm"
            )
        }

        var uniqueCompatible: [RTSPDigestChallenge] = []
        for challenge in compatible where !uniqueCompatible.contains(challenge) {
            uniqueCompatible.append(challenge)
        }
        guard uniqueCompatible.count == 1, let replacement = uniqueCompatible.first else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "the response contained conflicting stale Digest challenges"
            )
        }
        guard replacement.nonce != current.nonce else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "a stale Digest challenge reused the previous nonce"
            )
        }
        return replacement
    }

    private static func challengeInventory(
        from headerValues: [String]
    ) throws -> ChallengeInventory {
        guard !headerValues.isEmpty else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "the response did not include WWW-Authenticate"
            )
        }

        var inventory = ChallengeInventory()
        for headerValue in headerValues {
            for challenge in try parseChallenges(headerValue) {
                switch challenge.scheme {
                case "digest":
                    inventory.offeredDigest = true
                    do {
                        inventory.digestChallenges.append(
                            try makeDigestChallenge(challenge.parameters)
                        )
                    } catch let error as SkyBridgeCameraError {
                        inventory.unsupportedReasons.append(error.localizedDescription)
                    }
                case "basic":
                    inventory.offeredBasic = true
                default:
                    inventory.unsupportedReasons.append(
                        "unsupported scheme \(challenge.scheme)"
                    )
                }
            }
        }
        return inventory
    }

    private struct ParsedChallenge {
        let scheme: String
        let parameters: [String: String]
    }

    private struct ChallengeBuilder {
        let scheme: String
        var parameterSegments: [Substring]
    }

    private static func parseChallenges(_ value: String) throws -> [ParsedChallenge] {
        let segments = try splitOnUnquotedCommas(value)
        var builders: [ChallengeBuilder] = []

        for rawSegment in segments {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else {
                throw SkyBridgeCameraError.unsupportedAuthentication(
                    "an authentication challenge contains an empty segment"
                )
            }

            if let (scheme, firstParameter) = challengeStart(segment) {
                var builder = ChallengeBuilder(scheme: scheme, parameterSegments: [])
                if !firstParameter.isEmpty {
                    builder.parameterSegments.append(firstParameter[...])
                }
                builders.append(builder)
            } else {
                guard !builders.isEmpty else {
                    throw SkyBridgeCameraError.unsupportedAuthentication(
                        "an authentication parameter appears before its scheme"
                    )
                }
                builders[builders.count - 1].parameterSegments.append(segment[...])
            }
        }

        guard !builders.isEmpty else {
            throw SkyBridgeCameraError.unsupportedAuthentication("the challenge is empty")
        }

        return try builders.map { builder in
            var parameters: [String: String] = [:]
            for segment in builder.parameterSegments {
                let pair = try parseParameter(segment)
                guard parameters.updateValue(pair.value, forKey: pair.name) == nil else {
                    throw SkyBridgeCameraError.unsupportedAuthentication(
                        "duplicate \(pair.name) authentication parameter"
                    )
                }
            }
            return ParsedChallenge(scheme: builder.scheme, parameters: parameters)
        }
    }

    private static func challengeStart(_ segment: String) -> (String, String)? {
        guard let whitespace = segment.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            let lowercased = segment.lowercased()
            return lowercased == "basic" || lowercased == "digest"
                ? (lowercased, "")
                : nil
        }
        let scheme = segment[..<whitespace].lowercased()
        guard scheme == "basic" || scheme == "digest" else { return nil }
        let remainder = segment[whitespace...].trimmingCharacters(in: .whitespaces)
        return (scheme, remainder)
    }

    private static func splitOnUnquotedCommas(_ value: String) throws -> [Substring] {
        var result: [Substring] = []
        var start = value.startIndex
        var index = value.startIndex
        var insideQuotes = false
        var escaped = false

        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" && insideQuotes {
                escaped = true
            } else if character == "\"" {
                insideQuotes.toggle()
            } else if character == "," && !insideQuotes {
                result.append(value[start..<index])
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        guard !insideQuotes, !escaped else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "an authentication challenge contains an unterminated quoted value"
            )
        }
        result.append(value[start..<value.endIndex])
        return result
    }

    private static func parseParameter(_ segment: Substring) throws -> (name: String, value: String) {
        guard let equals = segment.firstIndex(of: "=") else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "authentication parameter is missing '='"
            )
        }
        let rawName = segment[..<equals].trimmingCharacters(in: .whitespaces)
        let rawValue = segment[segment.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
        guard isToken(rawName), !rawValue.isEmpty else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "authentication parameter name or value is invalid"
            )
        }
        let value: String
        if rawValue.first == "\"" {
            value = try parseQuotedString(rawValue)
        } else {
            guard isToken(rawValue) else {
                throw SkyBridgeCameraError.unsupportedAuthentication(
                    "authentication token value contains invalid characters"
                )
            }
            value = rawValue
        }
        return (rawName.lowercased(), value)
    }

    private static func parseQuotedString(_ rawValue: String) throws -> String {
        guard rawValue.count >= 2, rawValue.last == "\"" else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "authentication quoted value is not terminated"
            )
        }
        var output = ""
        var index = rawValue.index(after: rawValue.startIndex)
        let finalQuote = rawValue.index(before: rawValue.endIndex)
        while index < finalQuote {
            let character = rawValue[index]
            if character == "\\" {
                index = rawValue.index(after: index)
                guard index < finalQuote else {
                    throw SkyBridgeCameraError.unsupportedAuthentication(
                        "authentication quoted value ends with an escape"
                    )
                }
                output.append(rawValue[index])
            } else {
                guard character != "\r", character != "\n" else {
                    throw SkyBridgeCameraError.unsupportedAuthentication(
                        "authentication quoted value contains a line break"
                    )
                }
                output.append(character)
            }
            index = rawValue.index(after: index)
        }
        return output
    }

    private static func makeDigestChallenge(
        _ parameters: [String: String]
    ) throws -> RTSPDigestChallenge {
        guard let realm = parameters["realm"], !realm.isEmpty,
              let nonce = parameters["nonce"], !nonce.isEmpty
        else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "Digest requires non-empty realm and nonce"
            )
        }
        guard let qop = parameters["qop"] else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "Digest without qop=auth is not supported"
            )
        }
        let qualityOfProtection = qop.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard qualityOfProtection.contains("auth") else {
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "Digest challenge does not offer qop=auth"
            )
        }

        let rawAlgorithm = parameters["algorithm"] ?? RTSPDigestAlgorithm.md5.rawValue
        let algorithm: RTSPDigestAlgorithm
        switch rawAlgorithm.uppercased() {
        case RTSPDigestAlgorithm.md5.rawValue:
            algorithm = .md5
        case RTSPDigestAlgorithm.sha256.rawValue:
            algorithm = .sha256
        default:
            throw SkyBridgeCameraError.unsupportedAuthentication(
                "unsupported Digest algorithm \(rawAlgorithm)"
            )
        }
        return RTSPDigestChallenge(
            realm: realm,
            nonce: nonce,
            algorithm: algorithm,
            opaque: parameters["opaque"],
            isStale: parameters["stale"]?.caseInsensitiveCompare("true") == .orderedSame
        )
    }

    private static func strength(of algorithm: RTSPDigestAlgorithm) -> Int {
        switch algorithm {
        case .md5: 1
        case .sha256: 2
        }
    }

    private static func isToken<S: StringProtocol>(_ value: S) -> Bool {
        guard !value.isEmpty else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 33, 35...39, 42...43, 45...46, 48...57, 65...90, 94...122:
                true
            default:
                false
            }
        }
    }
}

struct RTSPAuthenticationContext: Sendable {
    private var selection: RTSPAuthenticationSelection
    private let credentials: RTSPCredentials
    private var nonceCount: UInt32 = 0

    init(
        selection: RTSPAuthenticationSelection,
        credentials: RTSPCredentials,
        secureTransport: Bool
    ) throws {
        if selection == .basic, !secureTransport {
            throw SkyBridgeCameraError.basicAuthenticationRequiresTLS
        }
        self.selection = selection
        self.credentials = credentials
    }

    mutating func authorizationHeader(method: String, uri: String) throws -> String {
        try authorizationHeader(method: method, uri: uri, cnonce: Self.randomCNonce())
    }

    mutating func authorizationHeader(
        method: String,
        uri: String,
        cnonce: String
    ) throws -> String {
        guard !method.isEmpty, method.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }),
              !uri.isEmpty, uri.utf8.allSatisfy({ $0 != 13 && $0 != 10 }),
              !cnonce.isEmpty,
              cnonce.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
              })
        else {
            throw SkyBridgeCameraError.invalidState(
                "authentication inputs are not valid RTSP tokens"
            )
        }

        switch selection {
        case .basic:
            let encoded = Data("\(credentials.username):\(credentials.password)".utf8)
                .base64EncodedString()
            return "Basic \(encoded)"

        case let .digest(challenge):
            guard nonceCount < UInt32.max else {
                throw SkyBridgeCameraError.invalidState("Digest nonce count exhausted")
            }
            nonceCount += 1
            let nc = String(format: "%08x", nonceCount)
            let ha1 = Self.hash(
                "\(credentials.username):\(challenge.realm):\(credentials.password)",
                using: challenge.algorithm
            )
            let ha2 = Self.hash("\(method):\(uri)", using: challenge.algorithm)
            let response = Self.hash(
                "\(ha1):\(challenge.nonce):\(nc):\(cnonce):auth:\(ha2)",
                using: challenge.algorithm
            )
            var fields = [
                "username=\"\(Self.escape(credentials.username))\"",
                "realm=\"\(Self.escape(challenge.realm))\"",
                "nonce=\"\(Self.escape(challenge.nonce))\"",
                "uri=\"\(Self.escape(uri))\"",
                "response=\"\(response)\"",
                "algorithm=\(challenge.algorithm.rawValue)",
                "qop=auth",
                "nc=\(nc)",
                "cnonce=\"\(cnonce)\"",
            ]
            if let opaque = challenge.opaque {
                fields.append("opaque=\"\(Self.escape(opaque))\"")
            }
            return "Digest " + fields.joined(separator: ", ")
        }
    }

    mutating func refreshIfStale(from headerValues: [String]) throws -> Bool {
        guard case let .digest(current) = selection else { return false }
        guard let replacement = try RTSPAuthentication.selectStaleDigestChallenge(
            from: headerValues,
            replacing: current
        ) else {
            return false
        }
        selection = .digest(replacement)
        nonceCount = 0
        return true
    }

    private static func randomCNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    private static func hash(_ value: String, using algorithm: RTSPDigestAlgorithm) -> String {
        let data = Data(value.utf8)
        switch algorithm {
        case .md5:
            return Insecure.MD5.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        case .sha256:
            return SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
