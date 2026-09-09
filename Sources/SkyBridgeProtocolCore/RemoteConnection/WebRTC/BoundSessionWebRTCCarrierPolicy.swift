import Foundation

/// Closed BoundSessionV1 record kinds admitted by the WebRTC carrier.
///
/// These values and limits mirror the frozen BoundSessionV1 revision-1 wire
/// contract. They are transport admission limits, not a substitute for the
/// canonical BoundSession decoder or its typestate checks.
@available(macOS 14.0, iOS 17.0, *)
public enum BoundSessionWebRTCRecordKindV1: UInt16, CaseIterable, Sendable {
    case grantReady = 0x0004
    case effectReceipt = 0x0005
    case messageA = 0x0007
    case messageB = 0x0008
    case finished = 0x0009

    public var maximumRecordByteCount: Int {
        switch self {
        case .messageA:
            5_635
        case .messageB:
            3_821
        case .finished:
            279
        case .grantReady:
            193
        case .effectReceipt:
            492
        }
    }

    /// Maximum BSC1 carrier payload, excluding the existing four-byte outer
    /// DataChannel length prefix.
    public var maximumCarrierPayloadByteCount: Int {
        BoundSessionWebRTCCarrierPolicyV1.carrierAndSecureEnvelopeOverheadByteCount
            + maximumRecordByteCount
    }

    fileprivate var authenticatorByteCount: Int {
        switch self {
        case .messageA, .messageB:
            3_309
        case .finished, .grantReady, .effectReceipt:
            32
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
public struct BoundSessionWebRTCCarrierHeaderV1: Sendable, Equatable {
    public let recordKind: BoundSessionWebRTCRecordKindV1
    public let recordByteCount: Int

    public init(recordKind: BoundSessionWebRTCRecordKindV1, recordByteCount: Int) {
        self.recordKind = recordKind
        self.recordByteCount = recordByteCount
    }
}

@available(macOS 14.0, iOS 17.0, *)
public enum BoundSessionWebRTCFrameRouteV1: Sendable, Equatable {
    case legacy
    case boundSession(BoundSessionWebRTCCarrierHeaderV1)
}

/// Allocation and post-authentication checks for `BOUND_SESSION_WEBRTC_CARRIER_V1`.
@available(macOS 14.0, iOS 17.0, *)
public enum BoundSessionWebRTCCarrierPolicyV1 {
    public static let stagedPrefixByteCount = 19
    public static let carrierHeaderByteCount = 12
    public static let secureEnvelopeHeaderByteCount = 52
    public static let secureEnvelopeTagByteCount = 16
    public static let secureEnvelopeOverheadByteCount =
        secureEnvelopeHeaderByteCount + secureEnvelopeTagByteCount
    public static let carrierAndSecureEnvelopeOverheadByteCount =
        carrierHeaderByteCount + secureEnvelopeOverheadByteCount

    private static let carrierMagic = Data([0x42, 0x53, 0x43, 0x31])  // BSC1
    private static let secureEnvelopeMagic = Data([0x53, 0x42, 0x57, 0x43])  // SBWC
    private static let trafficPaddingMagic = Data([0x53, 0x42, 0x50, 0x32])  // SBP2
    private static let canonicalRecordMagic = Data([0x42, 0x53, 0x56, 0x31])  // BSV1
    private static let carrierVersion: UInt8 = 1
    private static let secureEnvelopeVersion: UInt8 = 1
    private static let secureEnvelopePacketType: UInt8 = 6
    private static let canonicalRecordVersion: UInt16 = 1
    private static let canonicalEnvelopeHeaderByteCount = 12

    /// Classifies a frame after exactly `min(19, declaredPayloadByteCount)` bytes
    /// have been retained. No declared frame-sized allocation is needed before
    /// this function returns successfully.
    public static func classifyStagedPrefix(
        declaredPayloadByteCount: Int,
        stagedPrefix: Data
    ) throws -> BoundSessionWebRTCFrameRouteV1 {
        guard WebRTCFramedPayloadPolicy.isValidPayloadByteCount(declaredPayloadByteCount) else {
            throw BoundSessionWebRTCCarrierErrorV1.invalidOuterPayloadByteCount(
                declaredPayloadByteCount
            )
        }
        let expectedPrefixByteCount = min(stagedPrefixByteCount, declaredPayloadByteCount)
        guard stagedPrefix.count == expectedPrefixByteCount else {
            throw BoundSessionWebRTCCarrierErrorV1.invalidStagedPrefixByteCount(
                expected: expectedPrefixByteCount,
                actual: stagedPrefix.count
            )
        }

        if stagedPrefix.starts(with: carrierMagic) {
            return .boundSession(
                try decodeAndValidateCarrierPrefix(
                    declaredPayloadByteCount: declaredPayloadByteCount,
                    stagedPrefix: stagedPrefix
                )
            )
        }

        if stagedPrefix.count >= 7,
            stagedPrefix.starts(with: secureEnvelopeMagic),
            stagedPrefix[stagedPrefix.startIndex + 6] == secureEnvelopePacketType
        {
            throw BoundSessionWebRTCCarrierErrorV1.directSecureEnvelopePacketType6
        }

        if stagedPrefix.count >= 15,
            stagedPrefix.starts(with: trafficPaddingMagic)
        {
            let wrappedPayloadByteCount = Int(readUInt32(stagedPrefix, at: 4))
            if wrappedPayloadByteCount >= 7,
                wrappedPayloadByteCount <= declaredPayloadByteCount - 8,
                dataHasPrefix(stagedPrefix, at: 8, prefix: secureEnvelopeMagic),
                stagedPrefix[stagedPrefix.startIndex + 14] == secureEnvelopePacketType
            {
                throw BoundSessionWebRTCCarrierErrorV1.paddedSecureEnvelopePacketType6
            }
        }

        return .legacy
    }

    public static func encodeHeader(
        recordKind: BoundSessionWebRTCRecordKindV1,
        recordByteCount: Int
    ) throws -> Data {
        try validateRecordByteCount(recordByteCount, for: recordKind)
        guard let encodedRecordByteCount = UInt32(exactly: recordByteCount) else {
            throw BoundSessionWebRTCCarrierErrorV1.recordByteCountNotRepresentable(
                recordByteCount
            )
        }

        var header = Data()
        header.reserveCapacity(carrierHeaderByteCount)
        header.append(carrierMagic)
        header.append(carrierVersion)
        header.append(0)
        appendUInt16(recordKind.rawValue, to: &header)
        appendUInt32(encodedRecordByteCount, to: &header)
        return header
    }

    /// Validates the record envelope projection available to the carrier.
    /// The BoundSession service must still run the complete canonical decoder,
    /// signature/MAC verification, and current-typestate transition.
    public static func validateAuthenticatedRecord(
        _ record: Data,
        header: BoundSessionWebRTCCarrierHeaderV1,
        expectedRecordKind: BoundSessionWebRTCRecordKindV1
    ) throws {
        guard header.recordKind == expectedRecordKind else {
            throw BoundSessionWebRTCCarrierErrorV1.unexpectedTypestateRecordKind(
                expected: expectedRecordKind,
                actual: header.recordKind
            )
        }
        guard record.count == header.recordByteCount else {
            throw BoundSessionWebRTCCarrierErrorV1.authenticatedRecordLengthMismatch(
                expected: header.recordByteCount,
                actual: record.count
            )
        }
        try validateRecordEnvelope(record, expectedRecordKind: expectedRecordKind)
    }

    public static func validateRecordEnvelope(
        _ record: Data,
        expectedRecordKind: BoundSessionWebRTCRecordKindV1
    ) throws {
        try validateRecordByteCount(record.count, for: expectedRecordKind)
        let minimumByteCount =
            canonicalEnvelopeHeaderByteCount
            + expectedRecordKind.authenticatorByteCount
        guard record.count >= minimumByteCount else {
            throw BoundSessionWebRTCCarrierErrorV1.truncatedCanonicalRecord
        }
        guard record.starts(with: canonicalRecordMagic) else {
            throw BoundSessionWebRTCCarrierErrorV1.invalidCanonicalRecordMagic
        }
        let version = readUInt16(record, at: 4)
        guard version == canonicalRecordVersion else {
            throw BoundSessionWebRTCCarrierErrorV1.unsupportedCanonicalRecordVersion(version)
        }
        let rawKind = readUInt16(record, at: 6)
        guard rawKind == expectedRecordKind.rawValue else {
            throw BoundSessionWebRTCCarrierErrorV1.canonicalRecordKindMismatch(
                expected: expectedRecordKind.rawValue,
                actual: rawKind
            )
        }
        let bodyByteCount = Int(readUInt32(record, at: 8))
        let envelopeByteCountResult =
            canonicalEnvelopeHeaderByteCount
            .addingReportingOverflow(bodyByteCount)
        guard !envelopeByteCountResult.overflow else {
            throw BoundSessionWebRTCCarrierErrorV1.canonicalRecordLengthOverflow
        }
        let completeByteCountResult = envelopeByteCountResult.partialValue
            .addingReportingOverflow(expectedRecordKind.authenticatorByteCount)
        guard !completeByteCountResult.overflow else {
            throw BoundSessionWebRTCCarrierErrorV1.canonicalRecordLengthOverflow
        }
        guard completeByteCountResult.partialValue == record.count else {
            throw BoundSessionWebRTCCarrierErrorV1.canonicalRecordLengthMismatch(
                expected: completeByteCountResult.partialValue,
                actual: record.count
            )
        }
    }

    private static func decodeAndValidateCarrierPrefix(
        declaredPayloadByteCount: Int,
        stagedPrefix: Data
    ) throws -> BoundSessionWebRTCCarrierHeaderV1 {
        guard stagedPrefix.count == stagedPrefixByteCount else {
            throw BoundSessionWebRTCCarrierErrorV1.truncatedCarrierPrefix
        }
        let version = stagedPrefix[stagedPrefix.startIndex + 4]
        guard version == carrierVersion else {
            throw BoundSessionWebRTCCarrierErrorV1.unsupportedCarrierVersion(version)
        }
        let reserved = stagedPrefix[stagedPrefix.startIndex + 5]
        guard reserved == 0 else {
            throw BoundSessionWebRTCCarrierErrorV1.nonzeroCarrierReservedByte(reserved)
        }
        let rawKind = readUInt16(stagedPrefix, at: 6)
        guard let recordKind = BoundSessionWebRTCRecordKindV1(rawValue: rawKind) else {
            throw BoundSessionWebRTCCarrierErrorV1.unknownRecordKind(rawKind)
        }
        let recordByteCount = Int(readUInt32(stagedPrefix, at: 8))
        try validateRecordByteCount(recordByteCount, for: recordKind)

        let expectedPayloadByteCountResult =
            carrierAndSecureEnvelopeOverheadByteCount
            .addingReportingOverflow(recordByteCount)
        guard !expectedPayloadByteCountResult.overflow else {
            throw BoundSessionWebRTCCarrierErrorV1.carrierLengthOverflow
        }
        let expectedPayloadByteCount = expectedPayloadByteCountResult.partialValue
        guard declaredPayloadByteCount == expectedPayloadByteCount else {
            throw BoundSessionWebRTCCarrierErrorV1.outerPayloadLengthMismatch(
                expected: expectedPayloadByteCount,
                actual: declaredPayloadByteCount
            )
        }

        guard
            dataHasPrefix(
                stagedPrefix,
                at: carrierHeaderByteCount,
                prefix: secureEnvelopeMagic
            )
        else {
            throw BoundSessionWebRTCCarrierErrorV1.invalidInnerSecureEnvelopeMagic
        }
        let innerVersion = stagedPrefix[stagedPrefix.startIndex + 16]
        guard innerVersion == secureEnvelopeVersion else {
            throw BoundSessionWebRTCCarrierErrorV1.unsupportedInnerSecureEnvelopeVersion(
                innerVersion
            )
        }
        let innerHeaderByteCount = stagedPrefix[stagedPrefix.startIndex + 17]
        guard innerHeaderByteCount == UInt8(secureEnvelopeHeaderByteCount) else {
            throw BoundSessionWebRTCCarrierErrorV1.invalidInnerSecureEnvelopeHeaderByteCount(
                innerHeaderByteCount
            )
        }
        let packetType = stagedPrefix[stagedPrefix.startIndex + 18]
        guard packetType == secureEnvelopePacketType else {
            throw BoundSessionWebRTCCarrierErrorV1.invalidInnerSecureEnvelopePacketType(
                packetType
            )
        }
        return BoundSessionWebRTCCarrierHeaderV1(
            recordKind: recordKind,
            recordByteCount: recordByteCount
        )
    }

    private static func validateRecordByteCount(
        _ recordByteCount: Int,
        for recordKind: BoundSessionWebRTCRecordKindV1
    ) throws {
        guard recordByteCount > 0 else {
            throw BoundSessionWebRTCCarrierErrorV1.zeroRecordByteCount
        }
        guard recordByteCount <= recordKind.maximumRecordByteCount else {
            throw BoundSessionWebRTCCarrierErrorV1.recordTooLarge(
                kind: recordKind,
                maximum: recordKind.maximumRecordByteCount,
                actual: recordByteCount
            )
        }
    }

    private static func dataHasPrefix(_ data: Data, at offset: Int, prefix: Data) -> Bool {
        guard offset >= 0,
            offset <= data.count,
            prefix.count <= data.count - offset
        else {
            return false
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: prefix.count)
        return data[start..<end].elementsEqual(prefix)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[data.startIndex + offset]) << 8)
            | UInt16(data[data.startIndex + offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[data.startIndex + offset]) << 24)
            | (UInt32(data[data.startIndex + offset + 1]) << 16)
            | (UInt32(data[data.startIndex + offset + 2]) << 8)
            | UInt32(data[data.startIndex + offset + 3])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}

@available(macOS 14.0, iOS 17.0, *)
public enum BoundSessionWebRTCCarrierErrorV1: Error, Sendable, Equatable, LocalizedError {
    case invalidOuterPayloadByteCount(Int)
    case invalidStagedPrefixByteCount(expected: Int, actual: Int)
    case truncatedCarrierPrefix
    case unsupportedCarrierVersion(UInt8)
    case nonzeroCarrierReservedByte(UInt8)
    case unknownRecordKind(UInt16)
    case zeroRecordByteCount
    case recordByteCountNotRepresentable(Int)
    case recordTooLarge(kind: BoundSessionWebRTCRecordKindV1, maximum: Int, actual: Int)
    case carrierLengthOverflow
    case outerPayloadLengthMismatch(expected: Int, actual: Int)
    case invalidInnerSecureEnvelopeMagic
    case unsupportedInnerSecureEnvelopeVersion(UInt8)
    case invalidInnerSecureEnvelopeHeaderByteCount(UInt8)
    case invalidInnerSecureEnvelopePacketType(UInt8)
    case directSecureEnvelopePacketType6
    case paddedSecureEnvelopePacketType6
    case unexpectedTypestateRecordKind(
        expected: BoundSessionWebRTCRecordKindV1,
        actual: BoundSessionWebRTCRecordKindV1
    )
    case authenticatedRecordLengthMismatch(expected: Int, actual: Int)
    case truncatedCanonicalRecord
    case invalidCanonicalRecordMagic
    case unsupportedCanonicalRecordVersion(UInt16)
    case canonicalRecordKindMismatch(expected: UInt16, actual: UInt16)
    case canonicalRecordLengthOverflow
    case canonicalRecordLengthMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidOuterPayloadByteCount(let actual):
            "invalid WebRTC outer payload byte count: \(actual)"
        case .invalidStagedPrefixByteCount(let expected, let actual):
            "invalid staged prefix byte count: expected \(expected), got \(actual)"
        case .truncatedCarrierPrefix:
            "truncated BSC1 staged prefix"
        case .unsupportedCarrierVersion(let version):
            "unsupported BSC1 version: \(version)"
        case .nonzeroCarrierReservedByte(let value):
            "nonzero BSC1 reserved byte: \(value)"
        case .unknownRecordKind(let raw):
            "unknown BSC1 record kind: \(raw)"
        case .zeroRecordByteCount:
            "BSC1 record byte count is zero"
        case .recordByteCountNotRepresentable(let actual):
            "BSC1 record byte count is not representable: \(actual)"
        case .recordTooLarge(let kind, let maximum, let actual):
            "BSC1 record exceeds kind \(kind.rawValue) limit \(maximum): \(actual)"
        case .carrierLengthOverflow:
            "BSC1 payload length overflow"
        case .outerPayloadLengthMismatch(let expected, let actual):
            "BSC1 outer payload length mismatch: expected \(expected), got \(actual)"
        case .invalidInnerSecureEnvelopeMagic:
            "BSC1 inner SBWC magic mismatch"
        case .unsupportedInnerSecureEnvelopeVersion(let version):
            "BSC1 inner SBWC version mismatch: \(version)"
        case .invalidInnerSecureEnvelopeHeaderByteCount(let actual):
            "BSC1 inner SBWC header length mismatch: \(actual)"
        case .invalidInnerSecureEnvelopePacketType(let actual):
            "BSC1 inner SBWC packet type mismatch: \(actual)"
        case .directSecureEnvelopePacketType6:
            "direct SBWC packet type 6 is forbidden"
        case .paddedSecureEnvelopePacketType6:
            "SBP2-wrapped SBWC packet type 6 is forbidden"
        case .unexpectedTypestateRecordKind(let expected, let actual):
            "BoundSession typestate kind mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .authenticatedRecordLengthMismatch(let expected, let actual):
            "authenticated BoundSession record length mismatch: expected \(expected), got \(actual)"
        case .truncatedCanonicalRecord:
            "truncated canonical BoundSession record"
        case .invalidCanonicalRecordMagic:
            "canonical BoundSession record magic mismatch"
        case .unsupportedCanonicalRecordVersion(let version):
            "unsupported canonical BoundSession record version: \(version)"
        case .canonicalRecordKindMismatch(let expected, let actual):
            "canonical BoundSession record kind mismatch: expected \(expected), got \(actual)"
        case .canonicalRecordLengthOverflow:
            "canonical BoundSession record length overflow"
        case .canonicalRecordLengthMismatch(let expected, let actual):
            "canonical BoundSession record length mismatch: expected \(expected), got \(actual)"
        }
    }
}
