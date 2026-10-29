import Foundation

/// Stable wire limits for the length-prefixed P2P control channel.
///
/// The body count excludes the four-byte big-endian length prefix and includes
/// any authenticated-encryption and traffic-padding overhead. Peers that have
/// not negotiated a larger authenticated capability must use this policy.
public enum P2PControlFramePolicy {
    public static let lengthPrefixByteCount = MemoryLayout<UInt32>.size

    /// Compatibility ceiling used by released iOS peers and legacy discovery
    /// transports. Increasing this value requires an authenticated capability
    /// negotiation; a Bonjour advertisement alone is not sufficient.
    public static let maximumBodyByteCount = 1_048_576

    /// Raw clipboard budget for the inline JSON/base64 control-message route.
    /// The authoritative check remains the final encrypted and padded body.
    public static let maximumInlineClipboardByteCount = 750 * 1_024

    public static func validateInlineClipboardByteCount(_ byteCount: Int) throws {
        guard byteCount >= 0 else {
            throw P2PControlFramePolicyError.invalidByteCount(byteCount)
        }
        guard byteCount <= maximumInlineClipboardByteCount else {
            throw P2PControlFramePolicyError.inlineClipboardTooLarge(
                actual: byteCount,
                maximum: maximumInlineClipboardByteCount
            )
        }
    }

    /// Validates a received body length before the caller allocates or reads it.
    public static func inboundBodyByteCount(from encodedLength: UInt32) throws -> Int {
        let byteCount = Int(encodedLength)
        try validateBodyByteCount(byteCount)
        return byteCount
    }

    /// Returns the checked length value used to construct a frame prefix.
    public static func outboundLength(forBodyByteCount byteCount: Int) throws -> UInt32 {
        try validateBodyByteCount(byteCount)
        guard let encodedLength = UInt32(exactly: byteCount) else {
            throw P2PControlFramePolicyError.invalidByteCount(byteCount)
        }
        return encodedLength
    }

    /// Constructs a complete length-prefixed frame after validating the body.
    ///
    /// Keeping allocation behind this boundary prevents call sites from making
    /// a second copy of an oversized attacker- or configuration-controlled
    /// payload before discovering that it cannot be represented on the v1
    /// control channel.
    public static func frame(body: Data) throws -> Data {
        var encodedLength = try outboundLength(forBodyByteCount: body.count).bigEndian
        let (capacity, overflow) = lengthPrefixByteCount.addingReportingOverflow(body.count)
        guard !overflow else {
            throw P2PControlFramePolicyError.byteCountOverflow
        }

        var frame = Data(capacity: capacity)
        frame.append(Data(bytes: &encodedLength, count: lengthPrefixByteCount))
        frame.append(body)
        return frame
    }

    public static func validateBodyByteCount(_ byteCount: Int) throws {
        guard byteCount > 0 else {
            throw P2PControlFramePolicyError.invalidByteCount(byteCount)
        }
        guard byteCount <= maximumBodyByteCount else {
            throw P2PControlFramePolicyError.bodyTooLarge(
                actual: byteCount,
                maximum: maximumBodyByteCount
            )
        }
    }
}

/// JSON encoder for control messages that contain base64 data.
///
/// Foundation's default encoder may escape every `/` in a base64 string as
/// `\/`, making adversarial binary clipboard input almost twice as large. JSON
/// decoders accept the unescaped form, so this option is wire-compatible with
/// existing peers while keeping the size budget deterministic.
public enum P2PControlJSONEncoder {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// MIME values carried by inline clipboard control messages.
public enum P2PClipboardMIMEPolicy {
    public static let plainText = "text/plain"
    public static let utf8PlainText = "text/plain;charset=utf-8"
    public static let png = "image/png"
    public static let jpeg = "image/jpeg"
    public static let uriList = "text/uri-list"
    public static let richText = "text/rtf"
    public static let html = "text/html"

    /// Older macOS builds used this private value for file URLs.
    public static let legacySkyBridgeFileURL = "application/x-skybridge-file-url"

    public static func canonicalWireValue(for value: String) -> String? {
        switch value.lowercased() {
        case plainText: return plainText
        case utf8PlainText: return utf8PlainText
        case png: return png
        case jpeg: return jpeg
        case uriList, legacySkyBridgeFileURL: return uriList
        case richText: return richText
        case html: return html
        default: return nil
        }
    }
}

public enum P2PControlFramePolicyError: Error, Equatable, Sendable, LocalizedError {
    case invalidByteCount(Int)
    case bodyTooLarge(actual: Int, maximum: Int)
    case inlineClipboardTooLarge(actual: Int, maximum: Int)
    case byteCountOverflow
    case invalidPaddingTarget(actual: Int, maximum: Int)
    case payloadExceedsFixedPaddingTarget(required: Int, configured: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidByteCount(let byteCount):
            return "P2P control-frame byte count is invalid: \(byteCount)"
        case .bodyTooLarge(let actual, let maximum):
            return "P2P control-frame body is too large: \(actual) bytes (maximum \(maximum))"
        case .inlineClipboardTooLarge(let actual, let maximum):
            return "Inline clipboard content is too large: \(actual) bytes (maximum \(maximum))"
        case .byteCountOverflow:
            return "P2P control-frame byte-count calculation overflowed"
        case .invalidPaddingTarget(let actual, let maximum):
            return "P2P traffic-padding target is invalid: \(actual) bytes (maximum \(maximum))"
        case .payloadExceedsFixedPaddingTarget(let required, let configured):
            return "P2P payload requires \(required) padded bytes but the fixed target is \(configured)"
        }
    }
}
