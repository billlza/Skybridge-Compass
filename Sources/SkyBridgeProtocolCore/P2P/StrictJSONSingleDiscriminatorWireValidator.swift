import Foundation

/// Structural validation for authenticated JSON envelopes whose root object
/// contains exactly one message discriminator.
///
/// `JSONDecoder` intentionally exposes a dictionary-like view of keyed
/// containers. Duplicate JSON object keys can therefore be collapsed before a
/// `Decodable` implementation sees them. Authenticated wire bytes must pass
/// this bounded raw-byte scan before model decoding.
public enum StrictJSONSingleDiscriminatorWireValidator {
    public static func validate(
        _ data: Data,
        allowedDiscriminators: Set<String>,
        maximumByteCount: Int = P2PControlFramePolicy.maximumBodyByteCount
    ) throws {
        let rootFields = try validatedRootFields(
            in: data,
            allowedFields: allowedDiscriminators,
            maximumByteCount: maximumByteCount
        )
        guard rootFields.count == 1 else {
            throw StrictJSONSingleDiscriminatorWireError.invalidDiscriminatorCount
        }
    }

    /// Returns validated root fields for legacy envelopes that represented one
    /// payload plus explicit `null` fields for the other message kinds.
    /// Callers must still validate the decoded semantic cardinality.
    public static func validatedRootFields(
        in data: Data,
        allowedFields: Set<String>,
        maximumByteCount: Int = P2PControlFramePolicy.maximumBodyByteCount
    ) throws -> Set<String> {
        guard maximumByteCount > 0, !allowedFields.isEmpty else {
            throw StrictJSONSingleDiscriminatorWireError.invalidConfiguration
        }
        guard !data.isEmpty, data.count <= maximumByteCount else {
            throw StrictJSONSingleDiscriminatorWireError.payloadSizeOutOfRange
        }

        var scanner = StrictJSONStructureScanner(data: data)
        let rootFields = try scanner.scanRootObject()
        guard rootFields.isSubset(of: allowedFields) else {
            throw StrictJSONSingleDiscriminatorWireError.unknownDiscriminator
        }
        return rootFields
    }
}

public enum StrictJSONSingleDiscriminatorWireError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case payloadSizeOutOfRange
    case malformedJSONEnvelope
    case nestingDepthExceeded
    case collectionCapacityExceeded
    case duplicateObjectKey
    case invalidDiscriminatorCount
    case unknownDiscriminator

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Strict JSON wire validation is misconfigured"
        case .payloadSizeOutOfRange:
            return "Strict JSON wire payload size is invalid"
        case .malformedJSONEnvelope:
            return "Strict JSON wire envelope is malformed"
        case .nestingDepthExceeded:
            return "Strict JSON wire envelope exceeds its nesting limit"
        case .collectionCapacityExceeded:
            return "Strict JSON wire collection exceeds its capacity"
        case .duplicateObjectKey:
            return "Strict JSON wire envelope contains a duplicate object key"
        case .invalidDiscriminatorCount:
            return "Strict JSON wire envelope must contain exactly one discriminator"
        case .unknownDiscriminator:
            return "Strict JSON wire envelope contains an unknown discriminator"
        }
    }
}

private struct StrictJSONStructureScanner {
    private static let maximumNestingDepth = 16
    private static let maximumCollectionEntryCount = 512
    private static let maximumEncodedObjectKeyByteCount = 256

    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func scanRootObject() throws -> Set<String> {
        skipWhitespace()
        guard currentByte == 0x7B else { // {
            throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
        }
        let fields = try scanObject(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
        }
        return fields
    }

    private mutating func scanValue(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw StrictJSONSingleDiscriminatorWireError.nestingDepthExceeded
        }
        skipWhitespace()
        guard let byte = currentByte else {
            throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
        }
        switch byte {
        case 0x7B: // {
            _ = try scanObject(depth: depth)
        case 0x5B: // [
            try scanArray(depth: depth)
        case 0x22: // "
            _ = try scanJSONString()
        default:
            try scanPrimitive()
        }
    }

    private mutating func scanObject(depth: Int) throws -> Set<String> {
        guard depth <= Self.maximumNestingDepth else {
            throw StrictJSONSingleDiscriminatorWireError.nestingDepthExceeded
        }
        try expect(0x7B)
        skipWhitespace()
        if consume(0x7D) { return [] }

        var fields: Set<String> = []
        var fieldCount = 0
        while true {
            guard fieldCount < Self.maximumCollectionEntryCount else {
                throw StrictJSONSingleDiscriminatorWireError.collectionCapacityExceeded
            }
            skipWhitespace()
            let field = try decodeObjectKey()
            guard fields.insert(field).inserted else {
                throw StrictJSONSingleDiscriminatorWireError.duplicateObjectKey
            }
            fieldCount += 1
            skipWhitespace()
            try expect(0x3A) // :
            try scanValue(depth: depth + 1)
            skipWhitespace()
            if consume(0x2C) { // ,
                continue
            }
            try expect(0x7D) // }
            return fields
        }
    }

    private mutating func scanArray(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw StrictJSONSingleDiscriminatorWireError.nestingDepthExceeded
        }
        try expect(0x5B)
        skipWhitespace()
        if consume(0x5D) { return }

        var elementCount = 0
        while true {
            guard elementCount < Self.maximumCollectionEntryCount else {
                throw StrictJSONSingleDiscriminatorWireError.collectionCapacityExceeded
            }
            try scanValue(depth: depth + 1)
            elementCount += 1
            skipWhitespace()
            if consume(0x2C) { // ,
                continue
            }
            try expect(0x5D) // ]
            return
        }
    }

    private mutating func decodeObjectKey() throws -> String {
        let range = try scanJSONString()
        guard range.count <= Self.maximumEncodedObjectKeyByteCount else {
            throw StrictJSONSingleDiscriminatorWireError.collectionCapacityExceeded
        }
        do {
            return try JSONDecoder().decode(String.self, from: Data(bytes[range]))
        } catch {
            throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
        }
    }

    /// Returns the complete encoded JSON string range, including quotes.
    private mutating func scanJSONString() throws -> Range<Int> {
        let start = index
        try expect(0x22)
        while let byte = currentByte {
            if byte == 0x22 {
                index += 1
                return start..<index
            }
            guard byte >= 0x20 else {
                throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
            }
            if byte == 0x5C { // backslash
                index += 1
                guard let escaped = currentByte else {
                    throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
                }
                if escaped == 0x75 { // u
                    guard index + 4 < bytes.count else {
                        throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
                    }
                    for digitIndex in (index + 1)...(index + 4) {
                        guard Self.isHexDigit(bytes[digitIndex]) else {
                            throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
                        }
                    }
                    index += 5
                    continue
                }
                guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74]
                    .contains(escaped) else {
                    throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
                }
                index += 1
                continue
            }
            index += 1
        }
        throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
    }

    private mutating func scanPrimitive() throws {
        let start = index
        while let byte = currentByte,
              !Self.isWhitespace(byte),
              ![0x2C, 0x5D, 0x7D].contains(byte) {
            index += 1
        }
        guard index > start else {
            throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
        }
    }

    private mutating func expect(_ expected: UInt8) throws {
        guard consume(expected) else {
            throw StrictJSONSingleDiscriminatorWireError.malformedJSONEnvelope
        }
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }
        index += 1
        return true
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

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}
