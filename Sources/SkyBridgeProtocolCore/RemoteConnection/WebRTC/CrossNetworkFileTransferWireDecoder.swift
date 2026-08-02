import Foundation

/// Strict top-level JSON decoder for the flat v1 file-transfer envelope.
/// Swift's synthesized `Codable` decoder ignores unknown keys and accepts the
/// last occurrence of a duplicate key, so authenticated wire input must pass
/// this structural gate before model decoding.
public enum CrossNetworkFileTransferWireDecoder {
    public static let maximumEncodedPayloadByteCount = 1 * 1024 * 1024

    private static let allowedFields: Set<String> = [
        "version",
        "op",
        "transferId",
        "senderDeviceId",
        "senderDeviceName",
        "fileName",
        "fileSize",
        "chunkSize",
        "totalChunks",
        "mimeType",
        "chunkIndex",
        "chunkData",
        "chunkSha256",
        "nonce",
        "rawSize",
        "receivedBytes",
        "encryption",
        "fileSha256",
        "merkleRoot",
        "merkleRootSignature",
        "merkleRootSignatureAlg",
        "missingChunks",
        "batchId",
        "batchIndex",
        "batchTotal",
        "relativePath",
        "message",
    ]
    private static let requiredFields: Set<String> = [
        "version", "op", "transferId",
    ]
    private static let canonicalBase64Fields: Set<String> = [
        "chunkData",
        "chunkSha256",
        "nonce",
        "fileSha256",
        "merkleRoot",
        "merkleRootSignature",
    ]

    public static func decode(
        _ data: Data
    ) throws -> CrossNetworkFileTransferMessage {
        guard !data.isEmpty,
              data.count <= maximumEncodedPayloadByteCount else {
            throw CrossNetworkFileTransferWireDecodingError.payloadSizeOutOfRange
        }

        var scanner = TopLevelJSONFieldScanner(
            data: data,
            allowedFields: allowedFields,
            canonicalBase64Fields: canonicalBase64Fields
        )
        let seen = try scanner.scan()
        guard requiredFields.isSubset(of: seen) else {
            throw CrossNetworkFileTransferWireDecodingError.missingRequiredField
        }

        let message: CrossNetworkFileTransferMessage
        do {
            message = try JSONDecoder().decode(
                CrossNetworkFileTransferMessage.self,
                from: data
            )
        } catch {
            throw CrossNetworkFileTransferWireDecodingError.invalidMessage
        }
        try CrossNetworkFileTransferInboundAdmissionPolicy.validateEnvelope(message)
        return message
    }
}

public enum CrossNetworkFileTransferWireDecodingError: Error, LocalizedError, Sendable {
    case payloadSizeOutOfRange
    case malformedJSONEnvelope
    case unknownField
    case duplicateField
    case missingRequiredField
    case arrayElementCapacityExceeded
    case nonCanonicalBase64
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .payloadSizeOutOfRange:
            return "Cross-network file-transfer JSON payload size is invalid"
        case .malformedJSONEnvelope:
            return "Cross-network file-transfer JSON envelope is malformed"
        case .unknownField:
            return "Cross-network file-transfer JSON contains an unknown field"
        case .duplicateField:
            return "Cross-network file-transfer JSON contains a duplicate field"
        case .missingRequiredField:
            return "Cross-network file-transfer JSON is missing a required field"
        case .arrayElementCapacityExceeded:
            return "Cross-network file-transfer JSON array exceeds its capacity"
        case .nonCanonicalBase64:
            return "Cross-network file-transfer JSON contains non-canonical Base64"
        case .invalidMessage:
            return "Cross-network file-transfer JSON value types are invalid"
        }
    }
}

private struct TopLevelJSONFieldScanner {
    private static let maximumNestingDepth = 16
    private static let maximumEncodedFieldNameByteCount = 256
    private static let maximumArrayElementCount = 512

    private let bytes: [UInt8]
    private let allowedFields: Set<String>
    private let canonicalBase64Fields: Set<String>
    private var index = 0

    init(
        data: Data,
        allowedFields: Set<String>,
        canonicalBase64Fields: Set<String>
    ) {
        bytes = Array(data)
        self.allowedFields = allowedFields
        self.canonicalBase64Fields = canonicalBase64Fields
    }

    mutating func scan() throws -> Set<String> {
        skipWhitespace()
        try expect(0x7B) // {
        skipWhitespace()
        if consume(0x7D) { // }
            try requireEndOfInput()
            return []
        }

        var fields: Set<String> = []
        while true {
            skipWhitespace()
            let field = try parseFieldName()
            guard allowedFields.contains(field) else {
                throw CrossNetworkFileTransferWireDecodingError.unknownField
            }
            guard fields.insert(field).inserted else {
                throw CrossNetworkFileTransferWireDecodingError.duplicateField
            }
            skipWhitespace()
            try expect(0x3A) // :
            skipWhitespace()
            if canonicalBase64Fields.contains(field), currentByte == 0x22 {
                let value = try parseJSONString()
                guard let decoded = Data(base64Encoded: value, options: []),
                      decoded.base64EncodedString() == value else {
                    throw CrossNetworkFileTransferWireDecodingError
                        .nonCanonicalBase64
                }
            } else {
                try skipValue(depth: 0)
            }
            skipWhitespace()
            if consume(0x2C) { // ,
                continue
            }
            try expect(0x7D) // }
            try requireEndOfInput()
            return fields
        }
    }

    private mutating func parseFieldName() throws -> String {
        let encodedRange = try skipJSONString()
        guard encodedRange.count <= Self.maximumEncodedFieldNameByteCount else {
            throw CrossNetworkFileTransferWireDecodingError.unknownField
        }
        do {
            return try JSONDecoder().decode(
                String.self,
                from: Data(bytes[encodedRange])
            )
        } catch {
            throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
        }
    }

    private mutating func parseJSONString() throws -> String {
        let encodedRange = try skipJSONString()
        do {
            return try JSONDecoder().decode(
                String.self,
                from: Data(bytes[encodedRange])
            )
        } catch {
            throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
        }
    }

    private mutating func skipValue(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
        }
        skipWhitespace()
        guard let byte = currentByte else {
            throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
        }
        switch byte {
        case 0x22: // string
            _ = try skipJSONString()
        case 0x7B: // object
            try skipObject(depth: depth + 1)
        case 0x5B: // array
            try skipArray(depth: depth + 1)
        default:
            try skipPrimitive()
        }
    }

    private mutating func skipObject(depth: Int) throws {
        try expect(0x7B)
        skipWhitespace()
        if consume(0x7D) { return }
        while true {
            skipWhitespace()
            _ = try skipJSONString()
            skipWhitespace()
            try expect(0x3A)
            try skipValue(depth: depth)
            skipWhitespace()
            if consume(0x2C) { continue }
            try expect(0x7D)
            return
        }
    }

    private mutating func skipArray(depth: Int) throws {
        try expect(0x5B)
        skipWhitespace()
        if consume(0x5D) { return }
        var elementCount = 0
        while true {
            guard elementCount < Self.maximumArrayElementCount else {
                throw CrossNetworkFileTransferWireDecodingError
                    .arrayElementCapacityExceeded
            }
            try skipValue(depth: depth)
            elementCount += 1
            skipWhitespace()
            if consume(0x2C) { continue }
            try expect(0x5D)
            return
        }
    }

    /// Returns the complete encoded JSON string range, including quotes.
    private mutating func skipJSONString() throws -> Range<Int> {
        let start = index
        try expect(0x22)
        while let byte = currentByte {
            if byte == 0x22 {
                index += 1
                return start..<index
            }
            if byte < 0x20 {
                throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
            }
            if byte == 0x5C { // backslash
                index += 1
                guard currentByte != nil else {
                    throw CrossNetworkFileTransferWireDecodingError
                        .malformedJSONEnvelope
                }
            }
            index += 1
        }
        throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
    }

    private mutating func skipPrimitive() throws {
        let start = index
        while let byte = currentByte,
              !Self.isWhitespace(byte),
              ![0x2C, 0x5D, 0x7D].contains(byte) { // , ] }
            index += 1
        }
        guard index > start else {
            throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
        }
    }

    private mutating func expect(_ expected: UInt8) throws {
        guard consume(expected) else {
            throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
        }
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }
        index += 1
        return true
    }

    private mutating func requireEndOfInput() throws {
        skipWhitespace()
        guard index == bytes.count else {
            throw CrossNetworkFileTransferWireDecodingError.malformedJSONEnvelope
        }
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, Self.isWhitespace(byte) {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
