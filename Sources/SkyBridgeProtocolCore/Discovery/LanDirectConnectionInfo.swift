import Foundation

/// Public routing hints. Receiving this text grants neither pairing nor an account capability.
public struct LanDirectConnectionInfo: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let deviceId: String
    public let protocolFingerprint: String
    public let deviceName: String
    public let platform: String

    public init(host: String, port: UInt16, deviceId: String, protocolFingerprint: String,
                deviceName: String, platform: String) throws {
        guard host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains("%"), !host.contains("["), !host.contains("]"),
              host.utf8.count <= 128, port > 0,
              Self.hasCanonicalNumericSyntax(host),
              LANAddressRoutabilityPolicy.isAdvertisableRoutableLANAddress(host),
              Self.validText(deviceId, limit: 256), !deviceId.contains("="),
              protocolFingerprint.utf8.count == 64,
              protocolFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Self.validText(deviceName, limit: 128),
              ["macos", "windows", "linux", "android", "ios"].contains(platform)
        else { throw LanDirectConnectionInfoError.invalidFields }
        self.host = host; self.port = port; self.deviceId = deviceId
        self.protocolFingerprint = protocolFingerprint; self.deviceName = deviceName; self.platform = platform
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last else { return false }
        return !isBoundaryWhitespace(first.value) && !isBoundaryWhitespace(last.value) &&
            value.utf16.count <= limit && !value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
    }

    // Fixed cross-platform contract; Foundation and Kotlin trim different Unicode whitespace sets.
    private static func isBoundaryWhitespace(_ code: UInt32) -> Bool {
        (9...13).contains(code) || code == 32 ||
            [0x85, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff].contains(code) ||
            (0x2000...0x200b).contains(code)
    }

    private static func hasCanonicalNumericSyntax(_ host: String) -> Bool {
        if host.contains(":") {
            return host.unicodeScalars.allSatisfy {
                "0123456789abcdefABCDEF:.".unicodeScalars.contains($0)
            }
        }
        let parts = host.components(separatedBy: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            part.range(of: "^(0|[1-9][0-9]{0,2})$", options: .regularExpression) != nil &&
                (UInt16(part).map { $0 <= 255 } ?? false)
        }
    }
}

public enum LanDirectConnectionInfoError: Error, Sendable {
    case invalidFields
    case invalidEncoding
}

/// Canonical, bounded wire text. It intentionally contains no credentials or automatic trust grant.
public enum LanDirectConnectionInfoCodec {
    private static let prefix = "skybridge://lan/v1/"
    private static let maximumLength = 2048

    public static func encode(_ info: LanDirectConnectionInfo) throws -> String {
        let value = prefix + [encodeText(info.host), String(info.port), encodeText(info.deviceId),
            info.protocolFingerprint, encodeText(info.deviceName), info.platform].joined(separator: "/")
        guard value.utf8.count <= maximumLength else { throw LanDirectConnectionInfoError.invalidEncoding }
        return value
    }

    public static func decode(_ text: String) throws -> LanDirectConnectionInfo {
        guard text.utf8.count <= maximumLength, text.hasPrefix(prefix) else {
            throw LanDirectConnectionInfoError.invalidEncoding
        }
        let fields = String(text.dropFirst(prefix.count)).components(separatedBy: "/")
        guard fields.count == 6,
              fields[1].range(of: "^[1-9][0-9]{0,4}$", options: .regularExpression) != nil,
              let port = UInt16(fields[1]) else { throw LanDirectConnectionInfoError.invalidEncoding }
        let info = try LanDirectConnectionInfo(host: decodeText(fields[0]), port: port,
            deviceId: decodeText(fields[2]), protocolFingerprint: fields[3],
            deviceName: decodeText(fields[4]), platform: fields[5])
        guard try encode(info) == text else { throw LanDirectConnectionInfoError.invalidEncoding }
        return info
    }

    private static func encodeText(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeText(_ token: String) throws -> String {
        guard token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw LanDirectConnectionInfoError.invalidEncoding
        }
        let base = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base + String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), let text = String(data: bytes, encoding: .utf8),
              encodeText(text) == token else { throw LanDirectConnectionInfoError.invalidEncoding }
        return text
    }
}
