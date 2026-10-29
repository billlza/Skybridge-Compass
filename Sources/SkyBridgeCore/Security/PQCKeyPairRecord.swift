import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A versioned, storage-layer representation of a post-quantum key pair.
///
/// The record deliberately keeps storage policy and algorithm-specific
/// validation outside the codec. Callers must validate key lengths and prove
/// that the public/private values form a pair before treating a decoded record
/// as authoritative.
struct PQCKeyPairRecord: Equatable, Sendable {
    static let currentFormatVersion: UInt8 = 3

    let algorithmIdentifier: String
    let publicKey: Data
    var privateKey: Data
}

/// Non-secret structural metadata used to classify canonical records without
/// returning public or private key bytes to discovery code.
struct PQCKeyPairRecordMetadata: Equatable, Sendable {
    let algorithmIdentifier: String
    let publicKeyLength: Int
    let privateKeyLength: Int
}

enum PQCKeyPairRecordCodecError: Error, Equatable, LocalizedError, Sendable {
    case invalidAlgorithmIdentifier
    case keyMaterialTooLarge
    case truncatedRecord
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unexpectedAlgorithm(expected: String, actual: String)
    case invalidPublicKeyLength(expected: Int, actual: Int)
    case invalidPrivateKeyLength(expected: Int, actual: Int)
    case trailingData

    var errorDescription: String? {
        switch self {
        case .invalidAlgorithmIdentifier:
            return "PQC key-pair record has an invalid algorithm identifier"
        case .keyMaterialTooLarge:
            return "PQC key-pair record exceeds the codec size limit"
        case .truncatedRecord:
            return "PQC key-pair record is truncated"
        case .invalidMagic:
            return "PQC key-pair record has an invalid magic value"
        case .unsupportedVersion(let version):
            return "Unsupported PQC key-pair record version: \(version)"
        case .unexpectedAlgorithm(let expected, let actual):
            return "PQC key-pair algorithm mismatch: expected \(expected), got \(actual)"
        case .invalidPublicKeyLength(let expected, let actual):
            return "PQC public key length mismatch: expected \(expected), got \(actual)"
        case .invalidPrivateKeyLength(let expected, let actual):
            return "PQC private key length mismatch: expected \(expected), got \(actual)"
        case .trailingData:
            return "PQC key-pair record contains trailing data"
        }
    }
}

enum PQCKeyPairRecordCodec {
    private static let magic = Data([0x53, 0x42, 0x50, 0x51, 0x4b, 0x50, 0x52, 0x33]) // SBPQKPR3
    private static let maximumAlgorithmIdentifierLength = 64
    private static let maximumKeyMaterialLength = 1 << 20

    private struct ParsedHeader {
        let metadata: PQCKeyPairRecordMetadata
        let publicKeyOffset: Int
    }

    /// Encodes a record without applying an algorithm-specific key contract.
    /// The returned buffer contains the private key and must be wiped by the
    /// caller after it has crossed the persistence boundary.
    static func encode(_ record: PQCKeyPairRecord) throws -> Data {
        let algorithm = try validatedAlgorithmBytes(record.algorithmIdentifier)
        guard record.publicKey.count <= maximumKeyMaterialLength,
              record.privateKey.count <= maximumKeyMaterialLength,
              let publicLength = UInt32(exactly: record.publicKey.count),
              let privateLength = UInt32(exactly: record.privateKey.count) else {
            throw PQCKeyPairRecordCodecError.keyMaterialTooLarge
        }

        var encoded = Data()
        encoded.reserveCapacity(
            magic.count + 1 + 1 + 4 + 4
                + algorithm.count + record.publicKey.count + record.privateKey.count
        )
        encoded.append(magic)
        encoded.append(PQCKeyPairRecord.currentFormatVersion)
        encoded.append(UInt8(algorithm.count))
        appendUInt32(publicLength, to: &encoded)
        appendUInt32(privateLength, to: &encoded)
        encoded.append(contentsOf: algorithm)
        encoded.append(record.publicKey)
        encoded.append(record.privateKey)
        return encoded
    }

    /// Decodes a record and enforces the caller's algorithm and fixed-length
    /// contract before any key material is returned.
    static func decode(
        _ encoded: Data,
        expectedAlgorithmIdentifier: String,
        expectedPublicKeyLength: Int,
        expectedPrivateKeyLength: Int
    ) throws -> PQCKeyPairRecord {
        _ = try validatedAlgorithmBytes(expectedAlgorithmIdentifier)
        guard expectedPublicKeyLength >= 0,
              expectedPrivateKeyLength >= 0,
              expectedPublicKeyLength <= maximumKeyMaterialLength,
              expectedPrivateKeyLength <= maximumKeyMaterialLength else {
            throw PQCKeyPairRecordCodecError.keyMaterialTooLarge
        }

        let header = try parseHeader(encoded)
        let metadata = header.metadata
        guard metadata.algorithmIdentifier == expectedAlgorithmIdentifier else {
            throw PQCKeyPairRecordCodecError.unexpectedAlgorithm(
                expected: expectedAlgorithmIdentifier,
                actual: metadata.algorithmIdentifier
            )
        }
        guard metadata.publicKeyLength == expectedPublicKeyLength else {
            throw PQCKeyPairRecordCodecError.invalidPublicKeyLength(
                expected: expectedPublicKeyLength,
                actual: metadata.publicKeyLength
            )
        }
        guard metadata.privateKeyLength == expectedPrivateKeyLength else {
            throw PQCKeyPairRecordCodecError.invalidPrivateKeyLength(
                expected: expectedPrivateKeyLength,
                actual: metadata.privateKeyLength
            )
        }

        var cursor = header.publicKeyOffset
        let publicKey = try readData(
            count: metadata.publicKeyLength,
            from: encoded,
            cursor: &cursor
        )
        let privateKey = try readData(
            count: metadata.privateKeyLength,
            from: encoded,
            cursor: &cursor
        )
        return PQCKeyPairRecord(
            algorithmIdentifier: metadata.algorithmIdentifier,
            publicKey: publicKey,
            privateKey: privateKey
        )
    }

    /// Validates the complete envelope and returns only non-secret metadata.
    /// The payload lengths are checked against the actual buffer, so truncated
    /// and trailing records cannot become backend-selection evidence.
    static func inspectMetadata(_ encoded: Data) throws -> PQCKeyPairRecordMetadata {
        try parseHeader(encoded).metadata
    }

    static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { bytes in
            wipe(bytes)
        }
        data.removeAll(keepingCapacity: false)
    }

    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            wipe(buffer)
        }
        bytes.removeAll(keepingCapacity: false)
    }

    private static func validatedAlgorithmBytes(_ identifier: String) throws -> [UInt8] {
        guard let bytes = identifier.data(using: .utf8).map(Array.init),
              !bytes.isEmpty,
              bytes.count <= maximumAlgorithmIdentifierLength,
              bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw PQCKeyPairRecordCodecError.invalidAlgorithmIdentifier
        }
        return bytes
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func parseHeader(_ encoded: Data) throws -> ParsedHeader {
        var cursor = 0
        let storedMagic = try readData(count: magic.count, from: encoded, cursor: &cursor)
        guard storedMagic == magic else {
            throw PQCKeyPairRecordCodecError.invalidMagic
        }

        let version = try readByte(from: encoded, cursor: &cursor)
        guard version == PQCKeyPairRecord.currentFormatVersion else {
            throw PQCKeyPairRecordCodecError.unsupportedVersion(version)
        }

        let algorithmLength = Int(try readByte(from: encoded, cursor: &cursor))
        guard algorithmLength > 0,
              algorithmLength <= maximumAlgorithmIdentifierLength else {
            throw PQCKeyPairRecordCodecError.invalidAlgorithmIdentifier
        }
        let publicKeyLength = Int(try readUInt32(from: encoded, cursor: &cursor))
        let privateKeyLength = Int(try readUInt32(from: encoded, cursor: &cursor))
        guard publicKeyLength <= maximumKeyMaterialLength,
              privateKeyLength <= maximumKeyMaterialLength else {
            throw PQCKeyPairRecordCodecError.keyMaterialTooLarge
        }

        let algorithmData = try readData(count: algorithmLength, from: encoded, cursor: &cursor)
        guard let algorithmIdentifier = String(data: algorithmData, encoding: .utf8),
              (try? validatedAlgorithmBytes(algorithmIdentifier)) != nil else {
            throw PQCKeyPairRecordCodecError.invalidAlgorithmIdentifier
        }

        let publicKeyOffset = cursor
        guard publicKeyLength <= encoded.count - cursor else {
            throw PQCKeyPairRecordCodecError.truncatedRecord
        }
        cursor += publicKeyLength
        guard privateKeyLength <= encoded.count - cursor else {
            throw PQCKeyPairRecordCodecError.truncatedRecord
        }
        cursor += privateKeyLength
        guard cursor == encoded.count else {
            throw PQCKeyPairRecordCodecError.trailingData
        }

        return ParsedHeader(
            metadata: PQCKeyPairRecordMetadata(
                algorithmIdentifier: algorithmIdentifier,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength
            ),
            publicKeyOffset: publicKeyOffset
        )
    }

    private static func readByte(from data: Data, cursor: inout Int) throws -> UInt8 {
        guard cursor < data.count else {
            throw PQCKeyPairRecordCodecError.truncatedRecord
        }
        defer { cursor += 1 }
        return data[data.index(data.startIndex, offsetBy: cursor)]
    }

    private static func readUInt32(from data: Data, cursor: inout Int) throws -> UInt32 {
        let bytes = try readData(count: 4, from: data, cursor: &cursor)
        return bytes.reduce(UInt32.zero) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }

    private static func readData(count: Int, from data: Data, cursor: inout Int) throws -> Data {
        guard count >= 0,
              cursor <= data.count,
              count <= data.count - cursor else {
            throw PQCKeyPairRecordCodecError.truncatedRecord
        }
        let lowerBound = data.index(data.startIndex, offsetBy: cursor)
        let upperBound = data.index(lowerBound, offsetBy: count)
        cursor += count
        return Data(data[lowerBound..<upperBound])
    }

    private static func wipe(_ bytes: UnsafeMutableRawBufferPointer) {
        guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
        #if canImport(Darwin)
        _ = memset_s(baseAddress, bytes.count, 0, bytes.count)
        #else
        baseAddress.initializeMemory(as: UInt8.self, repeating: 0, count: bytes.count)
        #endif
    }
}
