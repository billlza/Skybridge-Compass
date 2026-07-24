import Darwin
import Foundation

public struct RTSPEndpoint: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Scheme: String, Sendable {
        case rtsp
        case rtsps

        var defaultPort: Int {
            switch self {
            case .rtsp: 554
            case .rtsps: 322
            }
        }

        var isSecure: Bool { self == .rtsps }
    }

    let url: URL
    let scheme: Scheme
    let host: String
    let port: Int

    public var isSecure: Bool { scheme.isSecure }
    public var description: String { "RTSPEndpoint(<redacted>)" }
    public var debugDescription: String { description }

    public init(url: URL) throws {
        let absoluteString = url.absoluteString
        guard absoluteString.utf8.count <= 2_048 else {
            throw SkyBridgeCameraError.invalidEndpoint(
                "the camera URI exceeds the 2048-byte limit"
            )
        }
        guard absoluteString.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
              !Self.containsPercentEncodedControlByte(absoluteString)
        else {
            throw SkyBridgeCameraError.invalidEndpoint(
                "the camera URI contains a control byte"
            )
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SkyBridgeCameraError.invalidEndpoint("the URL cannot be decomposed")
        }
        guard let rawScheme = components.scheme?.lowercased(), !rawScheme.isEmpty else {
            throw SkyBridgeCameraError.invalidEndpoint("a scheme is required")
        }
        guard let scheme = Scheme(rawValue: rawScheme) else {
            throw SkyBridgeCameraError.unsupportedScheme(rawScheme)
        }
        guard components.user == nil, components.password == nil else {
            throw SkyBridgeCameraError.credentialsInURLForbidden
        }
        guard components.fragment == nil else {
            throw SkyBridgeCameraError.invalidEndpoint("fragments are not permitted")
        }
        guard let encodedHost = components.percentEncodedHost, !encodedHost.isEmpty else {
            throw SkyBridgeCameraError.invalidEndpoint("a host is required")
        }
        guard !Self.hasExplicitEmptyPort(absoluteString) else {
            throw SkyBridgeCameraError.invalidEndpoint("an explicit port must not be empty")
        }
        guard components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw SkyBridgeCameraError.invalidEndpoint("the port is outside 1...65535")
        }

        guard !encodedHost.contains("%"), encodedHost.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw SkyBridgeCameraError.invalidEndpoint(
                "the host must be an unescaped ASCII IP literal"
            )
        }
        let normalizedHost: String
        if encodedHost.first == "[" || encodedHost.last == "]" {
            guard encodedHost.first == "[", encodedHost.last == "]", encodedHost.count > 2 else {
                throw SkyBridgeCameraError.invalidEndpoint("the IPv6 brackets are invalid")
            }
            let inner = encodedHost.dropFirst().dropLast()
            guard inner.utf8.allSatisfy({ byte in
                (byte >= 48 && byte <= 57) ||
                    (byte >= 65 && byte <= 70) ||
                    (byte >= 97 && byte <= 102) || byte == 58 || byte == 46
            }) else {
                throw SkyBridgeCameraError.invalidEndpoint(
                    "the IPv6 literal contains invalid characters"
                )
            }
            normalizedHost = inner.lowercased()
        } else {
            guard encodedHost.utf8.allSatisfy({
                ($0 >= 48 && $0 <= 57) || $0 == 46
            }) else {
                throw SkyBridgeCameraError.invalidEndpoint(
                    "the endpoint host must be an IP literal"
                )
            }
            normalizedHost = encodedHost
        }
        guard Self.isAllowedLocalHost(normalizedHost) else {
            throw SkyBridgeCameraError.endpointNotLocal
        }

        self.url = url
        self.scheme = scheme
        self.host = normalizedHost
        self.port = components.port ?? scheme.defaultPort
    }

    public init(_ value: String) throws {
        guard let url = URL(string: value) else {
            throw SkyBridgeCameraError.invalidEndpoint("the URL is not syntactically valid")
        }
        try self.init(url: url)
    }

    func validateSameOrigin(_ candidate: URL) throws -> URL {
        let candidateEndpoint = try RTSPEndpoint(url: candidate)
        guard candidateEndpoint.scheme == scheme,
              candidateEndpoint.host == host,
              candidateEndpoint.port == port
        else {
            throw SkyBridgeCameraError.invalidEndpoint(
                "SDP control URI must use the configured camera origin"
            )
        }
        return candidate
    }

    static func isAllowedLocalHost(_ host: String) -> Bool {
        if let ipv4 = parseIPv4(host) {
            return isAllowedIPv4(ipv4)
        }
        if let ipv6 = parseIPv6(host) {
            return isAllowedIPv6(ipv6)
        }
        return false
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy(\.isNumber),
                  (part.count == 1 || part.first != "0"),
                  let value = UInt8(part)
            else { return nil }
            result.append(value)
        }
        return result
    }

    private static func isAllowedIPv4(_ bytes: [UInt8]) -> Bool {
        switch bytes[0] {
        case 10:
            true
        case 172:
            (16...31).contains(bytes[1])
        case 192:
            bytes[1] == 168
        default:
            false
        }
    }

    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let result = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isAllowedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
        return isUniqueLocal
    }

    private static func hasExplicitEmptyPort(_ absoluteString: String) -> Bool {
        guard let authorityStart = absoluteString.range(of: "://")?.upperBound else {
            return false
        }
        let authorityAndPath = absoluteString[authorityStart...]
        let authorityEnd = authorityAndPath.firstIndex(where: {
            $0 == "/" || $0 == "?" || $0 == "#"
        }) ?? absoluteString.endIndex
        return absoluteString[authorityStart..<authorityEnd].last == ":"
    }

    private static func containsPercentEncodedControlByte(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 3 else { return false }
        for index in 0..<(bytes.count - 2) where bytes[index] == 37 {
            guard let high = hexadecimalValue(bytes[index + 1]),
                  let low = hexadecimalValue(bytes[index + 2])
            else { continue }
            let decoded = (high << 4) | low
            if decoded <= 31 || decoded == 127 { return true }
        }
        return false
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
