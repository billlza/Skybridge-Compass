import Foundation

struct RTPPacket: Sendable, Equatable {
    let marker: Bool
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let sourceIdentifier: UInt32
    let payload: Data

    static func parse(_ data: Data) throws -> RTPPacket {
        guard data.count >= 12 else {
            throw SkyBridgeCameraError.malformedRTP("the RTP header is shorter than 12 bytes")
        }
        let first = data[data.startIndex]
        guard first >> 6 == 2 else {
            throw SkyBridgeCameraError.malformedRTP("only RTP version 2 is supported")
        }
        let hasPadding = first & 0x20 != 0
        let hasExtension = first & 0x10 != 0
        let csrcCount = Int(first & 0x0F)
        var payloadStart = 12 + (csrcCount * 4)
        guard payloadStart <= data.count else {
            throw SkyBridgeCameraError.malformedRTP("the CSRC list exceeds the packet")
        }

        if hasExtension {
            guard payloadStart <= data.count - 4 else {
                throw SkyBridgeCameraError.malformedRTP("the extension header is truncated")
            }
            let wordCount = Int(readUInt16(data, atByteOffset: payloadStart + 2))
            let extensionBytes = 4 + (wordCount * 4)
            guard extensionBytes <= data.count - payloadStart else {
                throw SkyBridgeCameraError.malformedRTP("the extension payload is truncated")
            }
            payloadStart += extensionBytes
        }

        var payloadEnd = data.count
        if hasPadding {
            guard payloadEnd > payloadStart else {
                throw SkyBridgeCameraError.malformedRTP("padding is present without a payload")
            }
            let paddingCount = Int(data[data.index(before: data.endIndex)])
            guard paddingCount > 0, paddingCount <= payloadEnd - payloadStart else {
                throw SkyBridgeCameraError.malformedRTP("the padding count is invalid")
            }
            payloadEnd -= paddingCount
        }
        guard payloadEnd > payloadStart else {
            throw SkyBridgeCameraError.malformedRTP("the RTP payload is empty")
        }

        let secondHeaderByte = data[data.index(after: data.startIndex)]
        let payloadStartIndex = data.index(data.startIndex, offsetBy: payloadStart)
        let payloadEndIndex = data.index(data.startIndex, offsetBy: payloadEnd)

        return RTPPacket(
            marker: secondHeaderByte & 0x80 != 0,
            payloadType: secondHeaderByte & 0x7F,
            sequenceNumber: readUInt16(data, atByteOffset: 2),
            timestamp: readUInt32(data, atByteOffset: 4),
            sourceIdentifier: readUInt32(data, atByteOffset: 8),
            payload: data.subdata(in: payloadStartIndex..<payloadEndIndex)
        )
    }

    private static func readUInt16(_ data: Data, atByteOffset offset: Int) -> UInt16 {
        data.withUnsafeBytes { bytes in
            UInt16(
                bigEndian: bytes.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt16.self
                )
            )
        }
    }

    private static func readUInt32(_ data: Data, atByteOffset offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(
                bigEndian: bytes.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
            )
        }
    }
}

public struct H264AccessUnit: Sendable, Equatable {
    public let data: Data
    public let rtpTimestamp: UInt32
    public let firstSequenceNumber: UInt16
    public let lastSequenceNumber: UInt16
    /// Zero-based continuity sequence for VCL frames; metadata-only access units do not consume it.
    public let frameSequenceNumber: UInt64
    public let isKeyFrame: Bool
    public let containsVideoCodingLayer: Bool

    init(
        data: Data,
        rtpTimestamp: UInt32,
        firstSequenceNumber: UInt16,
        lastSequenceNumber: UInt16,
        frameSequenceNumber: UInt64,
        isKeyFrame: Bool,
        containsVideoCodingLayer: Bool
    ) {
        self.data = data
        self.rtpTimestamp = rtpTimestamp
        self.firstSequenceNumber = firstSequenceNumber
        self.lastSequenceNumber = lastSequenceNumber
        self.frameSequenceNumber = frameSequenceNumber
        self.isKeyFrame = isKeyFrame
        self.containsVideoCodingLayer = containsVideoCodingLayer
    }
}

private struct H264ParameterSetPair: Sendable, Equatable {
    let sequenceParameterSets: [Data]
    let pictureParameterSets: [Data]
}

private struct H264ParameterSetResolution: Sendable {
    let parameterSetsForInjection: H264ParameterSetPair?
    let hasIncompleteTransition: Bool
}

struct H264RTPDepacketizer: Sendable {
    private static let startCode = Data([0, 0, 0, 1])

    private let payloadType: UInt8
    private let packetizationMode: UInt8
    private let maximumAccessUnitBytes: Int
    private let maximumNALUnits: Int
    private let initialSequenceParameterSets: [Data]
    private let initialPictureParameterSets: [Data]

    private var expectedSequenceNumber: UInt16?
    private var sourceIdentifier: UInt32?
    private var currentTimestamp: UInt32?
    private var firstSequenceNumber: UInt16?
    private var accessUnit = Data()
    private var nalUnitCount = 0
    private var containsIDR = false
    private var containsVideoCodingLayer = false
    private var fragmentedNAL: Data?
    private var nextFrameSequenceNumber: UInt64 = 0
    private var activeParameterSets: H264ParameterSetPair?
    private var pendingSequenceParameterSets: [Data]?
    private var pendingPictureParameterSets: [Data]?
    private var awaitingIDRAfterParameterSetCommit = false
    private var sequenceParameterSetsInCurrentAccessUnit: [Data] = []
    private var pictureParameterSetsInCurrentAccessUnit: [Data] = []

    init(
        payloadType: UInt8,
        packetizationMode: UInt8,
        sequenceParameterSets: [Data] = [],
        pictureParameterSets: [Data] = [],
        maximumAccessUnitBytes: Int = 8 * 1_024 * 1_024,
        maximumNALUnits: Int = 512
    ) {
        precondition(payloadType <= 127)
        precondition(packetizationMode == 0 || packetizationMode == 1)
        precondition(maximumAccessUnitBytes > 4)
        precondition(maximumNALUnits > 0)
        self.payloadType = payloadType
        self.packetizationMode = packetizationMode
        precondition(sequenceParameterSets.count <= 32)
        precondition(pictureParameterSets.count <= 32)
        precondition(sequenceParameterSets.allSatisfy { !$0.isEmpty && $0.count <= 64 * 1_024 })
        precondition(pictureParameterSets.allSatisfy { !$0.isEmpty && $0.count <= 64 * 1_024 })
        self.initialSequenceParameterSets = sequenceParameterSets
        self.initialPictureParameterSets = pictureParameterSets
        if !sequenceParameterSets.isEmpty, !pictureParameterSets.isEmpty {
            self.activeParameterSets = H264ParameterSetPair(
                sequenceParameterSets: sequenceParameterSets,
                pictureParameterSets: pictureParameterSets
            )
            self.pendingSequenceParameterSets = nil
            self.pendingPictureParameterSets = nil
        } else {
            self.activeParameterSets = nil
            self.pendingSequenceParameterSets = sequenceParameterSets.isEmpty
                ? nil
                : sequenceParameterSets
            self.pendingPictureParameterSets = pictureParameterSets.isEmpty
                ? nil
                : pictureParameterSets
        }
        self.maximumAccessUnitBytes = maximumAccessUnitBytes
        self.maximumNALUnits = maximumNALUnits
    }

    mutating func consume(_ packetData: Data) throws -> H264AccessUnit? {
        do {
            let packet = try RTPPacket.parse(packetData)
            return try consume(packet)
        } catch {
            // A packet that cannot be parsed creates an unknown gap in the RTP
            // stream. Never let an incomplete generation survive that gap and
            // pair with unrelated parameter sets later.
            resetAccessUnit()
            discardIncompleteParameterSetTransition()
            throw error
        }
    }

    mutating func consume(_ packet: RTPPacket) throws -> H264AccessUnit? {
        guard packet.payloadType == payloadType else {
            try fail("unexpected RTP payload type \(packet.payloadType)")
        }
        if let expectedSequenceNumber, packet.sequenceNumber != expectedSequenceNumber {
            resetAccessUnit()
            discardIncompleteParameterSetTransition()
            self.expectedSequenceNumber = packet.sequenceNumber &+ 1
            throw SkyBridgeCameraError.rtpSequenceDiscontinuity(
                expected: expectedSequenceNumber,
                actual: packet.sequenceNumber
            )
        }
        expectedSequenceNumber = packet.sequenceNumber &+ 1

        if let sourceIdentifier, sourceIdentifier != packet.sourceIdentifier {
            self.sourceIdentifier = packet.sourceIdentifier
            try fail("the RTP SSRC changed during the stream")
        }
        sourceIdentifier = packet.sourceIdentifier

        if let currentTimestamp, currentTimestamp != packet.timestamp {
            try fail("the RTP timestamp changed before the access unit marker")
        }
        if currentTimestamp == nil {
            currentTimestamp = packet.timestamp
            firstSequenceNumber = packet.sequenceNumber
        }

        guard let firstPayloadByte = packet.payload.first else {
            try fail("the H.264 RTP payload is empty")
        }
        guard firstPayloadByte & 0x80 == 0 else {
            try fail("the H.264 forbidden_zero_bit is set")
        }
        let nalType = firstPayloadByte & 0x1F
        switch nalType {
        case 1...23:
            guard fragmentedNAL == nil else {
                try fail("a complete NAL unit interrupted an FU-A fragment")
            }
            try appendNAL(packet.payload)

        case 24:
            guard packetizationMode == 1 else {
                try fail("STAP-A is forbidden by packetization-mode=0")
            }
            guard fragmentedNAL == nil else {
                try fail("STAP-A interrupted an FU-A fragment")
            }
            try appendSTAPA(packet.payload)

        case 28:
            guard packetizationMode == 1 else {
                try fail("FU-A is forbidden by packetization-mode=0")
            }
            try appendFUA(packet.payload)

        default:
            try fail("unsupported H.264 RTP NAL unit type \(nalType)")
        }

        guard packet.marker else { return nil }
        guard fragmentedNAL == nil else {
            try fail("the RTP marker arrived before FU-A completion")
        }
        guard !accessUnit.isEmpty,
              let timestamp = currentTimestamp,
              let firstSequenceNumber
        else {
            try fail("the RTP marker completed an empty access unit")
        }

        let parameterSetResolution = resolveParameterSetsForCompletedAccessUnit()
        if containsIDR,
           !parameterSetResolution.hasIncompleteTransition,
           parameterSetResolution.parameterSetsForInjection != nil {
            awaitingIDRAfterParameterSetCommit = false
        }
        if containsVideoCodingLayer,
           (parameterSetResolution.hasIncompleteTransition
                || awaitingIDRAfterParameterSetCommit) {
            // Publishing any VCL while a changed generation is incomplete can
            // make consumers submit it against the old format description. A
            // newly committed generation likewise needs an IDR before any
            // predictive frame is safe. Keep the staged/active parameter sets,
            // but drop this ambiguous AU.
            resetAccessUnit()
            return nil
        }

        var completed = accessUnit
        if containsIDR,
           let parameterSetsForInjection = parameterSetResolution.parameterSetsForInjection {
            var prefix = Data()
            if sequenceParameterSetsInCurrentAccessUnit.isEmpty {
                for parameterSet in parameterSetsForInjection.sequenceParameterSets {
                    try appendAnnexB(parameterSet, to: &prefix)
                }
            }
            if pictureParameterSetsInCurrentAccessUnit.isEmpty {
                for parameterSet in parameterSetsForInjection.pictureParameterSets {
                    try appendAnnexB(parameterSet, to: &prefix)
                }
            }
            if !prefix.isEmpty {
                guard prefix.count <= maximumAccessUnitBytes - completed.count else {
                    resetAccessUnit()
                    discardIncompleteParameterSetTransition()
                    throw SkyBridgeCameraError.accessUnitTooLarge(limit: maximumAccessUnitBytes)
                }
                prefix.append(completed)
                completed = prefix
            }
        }

        // This counter is consumed by downstream decode continuity checks, so
        // it describes published VCL frames rather than internal parameter-set
        // state updates. Parameter-set-only access units are intentionally
        // returned to the RTSP client so it can commit metadata, but that client
        // never publishes them through frames(). Advancing here would create an
        // invisible sequence hole and make the next predictive frame look lost.
        if containsVideoCodingLayer {
            guard nextFrameSequenceNumber < UInt64.max else {
                try fail("the video-frame sequence counter is exhausted")
            }
        }
        let result = H264AccessUnit(
            data: completed,
            rtpTimestamp: timestamp,
            firstSequenceNumber: firstSequenceNumber,
            lastSequenceNumber: packet.sequenceNumber,
            frameSequenceNumber: nextFrameSequenceNumber,
            isKeyFrame: containsIDR,
            containsVideoCodingLayer: containsVideoCodingLayer
        )
        if containsVideoCodingLayer {
            nextFrameSequenceNumber += 1
        }
        resetAccessUnit()
        return result
    }

    mutating func reset() {
        expectedSequenceNumber = nil
        sourceIdentifier = nil
        nextFrameSequenceNumber = 0
        awaitingIDRAfterParameterSetCommit = false
        if !initialSequenceParameterSets.isEmpty,
           !initialPictureParameterSets.isEmpty {
            activeParameterSets = H264ParameterSetPair(
                sequenceParameterSets: initialSequenceParameterSets,
                pictureParameterSets: initialPictureParameterSets
            )
            pendingSequenceParameterSets = nil
            pendingPictureParameterSets = nil
        } else {
            activeParameterSets = nil
            pendingSequenceParameterSets = initialSequenceParameterSets.isEmpty
                ? nil
                : initialSequenceParameterSets
            pendingPictureParameterSets = initialPictureParameterSets.isEmpty
                ? nil
                : initialPictureParameterSets
        }
        resetAccessUnit()
    }

    private mutating func appendSTAPA(_ payload: Data) throws {
        guard payload.count >= 4 else {
            try fail("STAP-A contains no complete aggregated NAL unit")
        }
        guard payload[payload.startIndex] & 0x80 == 0 else {
            try fail("the STAP-A forbidden_zero_bit is set")
        }
        var offset = payload.startIndex + 1
        var appended = 0
        while offset < payload.endIndex {
            guard offset <= payload.endIndex - 2 else {
                try fail("STAP-A NAL size is truncated")
            }
            let length = (Int(payload[offset]) << 8) | Int(payload[offset + 1])
            offset += 2
            guard length > 0, length <= payload.endIndex - offset else {
                try fail("STAP-A NAL size exceeds the aggregation packet")
            }
            let nal = Data(payload[offset..<(offset + length)])
            guard nal[nal.startIndex] & 0x80 == 0 else {
                try fail("a STAP-A NAL unit has forbidden_zero_bit set")
            }
            let type = nal[nal.startIndex] & 0x1F
            guard (1...23).contains(type) else {
                try fail("STAP-A contains an unsupported nested NAL unit")
            }
            try appendNAL(nal)
            appended += 1
            offset += length
        }
        guard appended > 0 else {
            try fail("STAP-A did not contain a NAL unit")
        }
    }

    private mutating func appendFUA(_ payload: Data) throws {
        guard payload.count >= 3 else {
            try fail("FU-A is missing its fragment payload")
        }
        let indicator = payload[payload.startIndex]
        let header = payload[payload.startIndex + 1]
        let isStart = header & 0x80 != 0
        let isEnd = header & 0x40 != 0
        let reserved = header & 0x20 != 0
        let originalType = header & 0x1F
        guard indicator & 0x80 == 0,
              !reserved, originalType >= 1, originalType <= 23, !(isStart && isEnd)
        else {
            try fail("FU-A header flags or original NAL type are invalid")
        }
        let fragment = payload.dropFirst(2)
        guard !fragment.isEmpty else {
            try fail("FU-A has an empty fragment")
        }

        if isStart {
            guard fragmentedNAL == nil else {
                try fail("a new FU-A started before the prior fragment completed")
            }
            var nal = Data([(indicator & 0xE0) | originalType])
            guard fragment.count <= maximumAccessUnitBytes - nal.count,
                  nal.count + fragment.count <= maximumAccessUnitBytes - accessUnit.count
            else {
                resetAccessUnit()
                discardIncompleteParameterSetTransition()
                throw SkyBridgeCameraError.accessUnitTooLarge(limit: maximumAccessUnitBytes)
            }
            nal.append(contentsOf: fragment)
            fragmentedNAL = nal
            return
        }

        guard var nal = fragmentedNAL,
              nal[nal.startIndex] & 0x1F == originalType,
              nal[nal.startIndex] & 0xE0 == indicator & 0xE0
        else {
            try fail("FU-A continuation has no matching start fragment")
        }
        guard fragment.count <= maximumAccessUnitBytes - nal.count,
              nal.count + fragment.count <= maximumAccessUnitBytes - accessUnit.count
        else {
            resetAccessUnit()
            discardIncompleteParameterSetTransition()
            throw SkyBridgeCameraError.accessUnitTooLarge(limit: maximumAccessUnitBytes)
        }
        nal.append(contentsOf: fragment)
        if isEnd {
            fragmentedNAL = nil
            try appendNAL(nal)
        } else {
            fragmentedNAL = nal
        }
    }

    private mutating func appendNAL(_ nal: Data) throws {
        guard let first = nal.first else { try fail("a NAL unit is empty") }
        guard nalUnitCount < maximumNALUnits else {
            try fail("an access unit exceeds \(maximumNALUnits) NAL units")
        }
        guard nal.count + Self.startCode.count <= maximumAccessUnitBytes - accessUnit.count else {
            resetAccessUnit()
            discardIncompleteParameterSetTransition()
            throw SkyBridgeCameraError.accessUnitTooLarge(limit: maximumAccessUnitBytes)
        }
        accessUnit.append(Self.startCode)
        accessUnit.append(nal)
        nalUnitCount += 1
        switch first & 0x1F {
        case 1...4:
            containsVideoCodingLayer = true
        case 5:
            containsIDR = true
            containsVideoCodingLayer = true
        case 7:
            guard nal.count <= 64 * 1_024 else {
                try fail("an SPS exceeds the 65536-byte cache limit")
            }
            guard sequenceParameterSetsInCurrentAccessUnit.count < 32 else {
                try fail("an access unit contains more than 32 SPS NAL units")
            }
            sequenceParameterSetsInCurrentAccessUnit.append(nal)
        case 8:
            guard nal.count <= 64 * 1_024 else {
                try fail("a PPS exceeds the 65536-byte cache limit")
            }
            guard pictureParameterSetsInCurrentAccessUnit.count < 32 else {
                try fail("an access unit contains more than 32 PPS NAL units")
            }
            pictureParameterSetsInCurrentAccessUnit.append(nal)
        default: break
        }
    }

    /// Resolves parameter sets only after an access unit is complete. Active
    /// SPS/PPS are always a complete, atomically committed pair; a changed
    /// single-sided update remains pending and cannot borrow its counterpart
    /// from the active generation.
    private mutating func resolveParameterSetsForCompletedAccessUnit() -> H264ParameterSetResolution {
        let currentSequenceParameterSets = sequenceParameterSetsInCurrentAccessUnit.isEmpty
            ? nil
            : sequenceParameterSetsInCurrentAccessUnit
        let currentPictureParameterSets = pictureParameterSetsInCurrentAccessUnit.isEmpty
            ? nil
            : pictureParameterSetsInCurrentAccessUnit

        if let currentSequenceParameterSets,
           let currentPictureParameterSets {
            let completePair = H264ParameterSetPair(
                sequenceParameterSets: currentSequenceParameterSets,
                pictureParameterSets: currentPictureParameterSets
            )
            commitParameterSets(completePair)
            return H264ParameterSetResolution(
                parameterSetsForInjection: completePair,
                hasIncompleteTransition: false
            )
        }

        let hasPendingTransition = pendingSequenceParameterSets != nil
            || pendingPictureParameterSets != nil
        guard currentSequenceParameterSets != nil
                || currentPictureParameterSets != nil else {
            // A bare IDR may reuse only an unambiguous complete generation.
            // Once a changed single-sided update is pending, injecting the old
            // active pair could make downstream decoders accept the wrong
            // format, so wait for the pending generation to become complete.
            return H264ParameterSetResolution(
                parameterSetsForInjection: hasPendingTransition ? nil : activeParameterSets,
                hasIncompleteTransition: hasPendingTransition
            )
        }

        if !hasPendingTransition, let activeParameterSets {
            if let currentSequenceParameterSets,
               currentSequenceParameterSets == activeParameterSets.sequenceParameterSets {
                return H264ParameterSetResolution(
                    parameterSetsForInjection: activeParameterSets,
                    hasIncompleteTransition: false
                )
            }
            if let currentPictureParameterSets,
               currentPictureParameterSets == activeParameterSets.pictureParameterSets {
                return H264ParameterSetResolution(
                    parameterSetsForInjection: activeParameterSets,
                    hasIncompleteTransition: false
                )
            }
        }

        if hasPendingTransition, let activeParameterSets {
            // A changed side cannot be completed across access units by a
            // counterpart that is merely the active generation repeated. That
            // is ambiguous between a legitimate one-sided update and delayed
            // old traffic. Senders that intentionally retain one side must put
            // the complete pair in one AU so the generation is explicit.
            if pendingSequenceParameterSets != nil,
               pendingPictureParameterSets == nil,
               currentSequenceParameterSets == nil,
               currentPictureParameterSets == activeParameterSets.pictureParameterSets {
                return H264ParameterSetResolution(
                    parameterSetsForInjection: nil,
                    hasIncompleteTransition: true
                )
            }
            if pendingPictureParameterSets != nil,
               pendingSequenceParameterSets == nil,
               currentPictureParameterSets == nil,
               currentSequenceParameterSets == activeParameterSets.sequenceParameterSets {
                return H264ParameterSetResolution(
                    parameterSetsForInjection: nil,
                    hasIncompleteTransition: true
                )
            }
        }

        if let currentSequenceParameterSets {
            pendingSequenceParameterSets = currentSequenceParameterSets
        }
        if let currentPictureParameterSets {
            pendingPictureParameterSets = currentPictureParameterSets
        }

        guard let pendingSequenceParameterSets,
              let pendingPictureParameterSets else {
            return H264ParameterSetResolution(
                parameterSetsForInjection: nil,
                hasIncompleteTransition: true
            )
        }
        let completePair = H264ParameterSetPair(
            sequenceParameterSets: pendingSequenceParameterSets,
            pictureParameterSets: pendingPictureParameterSets
        )
        commitParameterSets(completePair)
        return H264ParameterSetResolution(
            parameterSetsForInjection: completePair,
            hasIncompleteTransition: false
        )
    }

    private mutating func commitParameterSets(_ completePair: H264ParameterSetPair) {
        let changed = activeParameterSets != completePair
        activeParameterSets = completePair
        pendingSequenceParameterSets = nil
        pendingPictureParameterSets = nil
        if changed {
            awaitingIDRAfterParameterSetCommit = !containsIDR
        }
    }

    private func appendAnnexB(_ nal: Data, to data: inout Data) throws {
        guard !nal.isEmpty,
              nal.count + Self.startCode.count <= maximumAccessUnitBytes - data.count
        else {
            throw SkyBridgeCameraError.accessUnitTooLarge(limit: maximumAccessUnitBytes)
        }
        data.append(Self.startCode)
        data.append(nal)
    }

    private mutating func fail(_ reason: String) throws -> Never {
        resetAccessUnit()
        discardIncompleteParameterSetTransition()
        throw SkyBridgeCameraError.malformedRTP(reason)
    }

    private mutating func discardIncompleteParameterSetTransition() {
        pendingSequenceParameterSets = nil
        pendingPictureParameterSets = nil
    }

    private mutating func resetAccessUnit() {
        currentTimestamp = nil
        firstSequenceNumber = nil
        accessUnit.removeAll(keepingCapacity: true)
        nalUnitCount = 0
        containsIDR = false
        containsVideoCodingLayer = false
        fragmentedNAL = nil
        sequenceParameterSetsInCurrentAccessUnit.removeAll(keepingCapacity: true)
        pictureParameterSetsInCurrentAccessUnit.removeAll(keepingCapacity: true)
    }
}
