import Foundation

struct RemoteDesktopVideoFrameTraits: Equatable, Sendable {
    let normalizedFormat: String
    let isPredictiveVideo: Bool
    let isIndependentlyDecodableFrame: Bool
    let isDecoderBootstrapFrame: Bool
}

struct RemoteDesktopClassifiedScreenFrame: Sendable {
    let screenData: ScreenData
    let traits: RemoteDesktopVideoFrameTraits
}

enum RemoteDesktopVideoFrameClassificationError: Error, Equatable, LocalizedError, Sendable {
    case accessUnitTooLarge(actualBytes: Int, maximumBytes: Int)
    case tooManyNALUnits(actual: Int, maximum: Int)
    case parameterSetTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidNALHeader
    case malformedAccessUnit

    var errorDescription: String? {
        switch self {
        case .accessUnitTooLarge(let actualBytes, let maximumBytes):
            return "Video access unit contains \(actualBytes) bytes, exceeding the \(maximumBytes)-byte classification limit."
        case .tooManyNALUnits(let actual, let maximum):
            return "Video access unit contains \(actual) NAL units, exceeding the \(maximum)-unit classification limit."
        case .parameterSetTooLarge(let actualBytes, let maximumBytes):
            return "Video parameter set contains \(actualBytes) bytes, exceeding the \(maximumBytes)-byte classification limit."
        case .invalidNALHeader:
            return "Video access unit contains an invalid NAL header."
        case .malformedAccessUnit:
            return "Video access unit framing is malformed."
        }
    }
}

/// Serial non-UI executor for untrusted frame classification. Camera callers await this actor
/// in wire order, so classification adds bounded backpressure without occupying MainActor.
actor RemoteDesktopVideoFrameClassificationWorker {
    func classify(_ screenData: ScreenData) throws -> RemoteDesktopClassifiedScreenFrame {
        try Task.checkCancellation()
        let classifiedFrame = RemoteDesktopClassifiedScreenFrame(
            screenData: screenData,
            traits: try RemoteDesktopScreenFrameWire.classifyVideoFrame(
                format: screenData.format,
                imageData: screenData.imageData
            )
        )
        try Task.checkCancellation()
        return classifiedFrame
    }
}

enum RemoteDesktopScreenFrameWire {
    private static let magic: UInt32 = 0x53425246 // "SBRF"
    private static let versionV1: UInt8 = 1
    private static let versionV2: UInt8 = 2
    private static let headerSizeV1 = 28
    private static let headerSizeV2 = 36
    static let screenChunkHeaderByteCount = 36
    private static let screenChunkMagic: UInt32 = 0x5342_4332 // "SBC2"
    private static let screenChunkVersion: UInt8 = 1

    struct ChunkEnvelope: Equatable {
        let frameId: UInt64
        let chunkIndex: Int
        let chunkCount: Int
        let totalBytes: Int
        let chunkOffset: Int
        let payload: Data
    }

    struct ChunkedPayloadReassembler {
        enum Result: Equatable {
            case waiting(frameId: UInt64, chunkIndex: Int, chunkCount: Int)
            case complete(frameId: UInt64, payload: Data)
            case dropped(reason: String, frameId: UInt64?)
            case suppressed(frameId: UInt64, reason: String)
        }

        private let maxFrameBytes: Int
        private let maxChunkCount = 2_048
        private let frameTTL: TimeInterval = 1.0
        private var frameId: UInt64?
        private var suppressedFrameReasons: [UInt64: String] = [:]
        private var suppressedFrameOrder: [UInt64] = []
        private var expectedChunkCount = 0
        private var expectedTotalBytes = 0
        private var nextChunkIndex = 0
        private var receivedBytes = 0
        private var chunks: [Data] = []
        private var lastUpdatedAt: Date = .distantPast

        init(maxFrameBytes: Int) {
            self.maxFrameBytes = maxFrameBytes
        }

        mutating func reset(clearSuppression: Bool = true) {
            frameId = nil
            expectedChunkCount = 0
            expectedTotalBytes = 0
            nextChunkIndex = 0
            receivedBytes = 0
            chunks.removeAll(keepingCapacity: true)
            lastUpdatedAt = .distantPast
            if clearSuppression {
                clearSuppressedFrames()
            }
        }

        private mutating func clearSuppressedFrames() {
            suppressedFrameReasons.removeAll(keepingCapacity: true)
            suppressedFrameOrder.removeAll(keepingCapacity: true)
        }

        private mutating func drop(
            reason: String,
            frameId droppedFrameId: UInt64?,
            suppressOrphansFor orphanFrameIds: [UInt64] = []
        ) -> Result {
            reset(clearSuppression: orphanFrameIds.isEmpty)
            for orphanFrameId in orphanFrameIds {
                if suppressedFrameReasons[orphanFrameId] == nil {
                    suppressedFrameOrder.append(orphanFrameId)
                }
                suppressedFrameReasons[orphanFrameId] = reason
            }
            while suppressedFrameOrder.count > 2 {
                suppressedFrameReasons.removeValue(forKey: suppressedFrameOrder.removeFirst())
            }
            return .dropped(reason: reason, frameId: droppedFrameId)
        }

        mutating func append(_ envelope: ChunkEnvelope, now: Date) -> Result {
            if let suppressedReason = suppressedFrameReasons[envelope.frameId] {
                return .suppressed(frameId: envelope.frameId, reason: suppressedReason)
            } else if envelope.chunkIndex == 0 {
                clearSuppressedFrames()
            }

            if let currentFrameId = frameId,
               now.timeIntervalSince(lastUpdatedAt) > frameTTL {
                reset()
                if envelope.chunkIndex != 0 {
                    return drop(
                        reason: "sbc2-chunk-timeout",
                        frameId: currentFrameId,
                        suppressOrphansFor: [envelope.frameId]
                    )
                }
            }

            guard envelope.chunkCount > 0,
                  envelope.chunkCount <= maxChunkCount,
                  envelope.chunkCount <= envelope.totalBytes,
                  envelope.chunkIndex >= 0,
                  envelope.chunkIndex < envelope.chunkCount,
                  envelope.totalBytes > 0,
                  envelope.totalBytes <= maxFrameBytes,
                  !envelope.payload.isEmpty,
                  envelope.chunkOffset >= 0,
                  envelope.chunkOffset + envelope.payload.count <= envelope.totalBytes else {
                return drop(reason: "invalid-sbc2-chunk-metadata", frameId: envelope.frameId)
            }

            if frameId == nil {
                guard envelope.chunkIndex == 0, envelope.chunkOffset == 0 else {
                    return drop(
                        reason: "missing-first-sbc2-chunk",
                        frameId: envelope.frameId,
                        suppressOrphansFor: [envelope.frameId]
                    )
                }
                beginFrame(envelope)
            } else if frameId != envelope.frameId
                        || expectedChunkCount != envelope.chunkCount
                        || expectedTotalBytes != envelope.totalBytes {
                let failedFrameId = frameId
                guard envelope.chunkIndex == 0,
                      envelope.chunkOffset == 0,
                      frameId != envelope.frameId else {
                    let orphanFrameIds = frameId == envelope.frameId
                        ? [failedFrameId ?? envelope.frameId]
                        : [failedFrameId, envelope.frameId].compactMap { $0 }
                    return drop(
                        reason: "interleaved-or-restarted-sbc2-frame",
                        frameId: orphanFrameIds.first ?? envelope.frameId,
                        suppressOrphansFor: orphanFrameIds
                    )
                }
                reset()
                beginFrame(envelope)
            }

            guard envelope.chunkIndex == nextChunkIndex,
                  envelope.chunkOffset == receivedBytes else {
                let failedFrameId = frameId ?? envelope.frameId
                return drop(
                    reason: "out-of-order-sbc2-chunk",
                    frameId: failedFrameId,
                    suppressOrphansFor: [failedFrameId]
                )
            }

            chunks.append(envelope.payload)
            receivedBytes += envelope.payload.count
            nextChunkIndex += 1
            lastUpdatedAt = now

            if nextChunkIndex == expectedChunkCount {
                guard receivedBytes == expectedTotalBytes else {
                    let failedFrameId = frameId
                    return drop(reason: "sbc2-total-bytes-mismatch", frameId: failedFrameId)
                }
                let completeFrameId = frameId ?? envelope.frameId
                var payload = Data(capacity: expectedTotalBytes)
                for chunk in chunks {
                    payload.append(chunk)
                }
                reset()
                return .complete(frameId: completeFrameId, payload: payload)
            }

            return .waiting(
                frameId: envelope.frameId,
                chunkIndex: envelope.chunkIndex,
                chunkCount: envelope.chunkCount
            )
        }

        private mutating func beginFrame(_ envelope: ChunkEnvelope) {
            clearSuppressedFrames()
            frameId = envelope.frameId
            expectedChunkCount = envelope.chunkCount
            expectedTotalBytes = envelope.totalBytes
            nextChunkIndex = 0
            receivedBytes = 0
            chunks.removeAll(keepingCapacity: true)
        }
    }

    private enum CodecTag: UInt8 {
        case unknown = 0
        case jpeg = 1
        case h264 = 2
        case hevc = 3
        case bgra = 4

        init(format: String?) {
            switch (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "jpeg", "jpg":
                self = .jpeg
            case "h264":
                self = .h264
            case "hevc":
                self = .hevc
            case "bgra":
                self = .bgra
            default:
                self = .unknown
            }
        }

        var format: String? {
            switch self {
            case .unknown:
                return nil
            case .jpeg:
                return "jpeg"
            case .h264:
                return "h264"
            case .hevc:
                return "hevc"
            case .bgra:
                return "bgra"
            }
        }
    }

    static func decodeIfPresent(_ data: Data) -> ScreenData? {
        guard data.count >= headerSizeV1 else { return nil }
        guard readUInt32(from: data, offset: 0) == magic else { return nil }
        let version = byte(in: data, at: 4)
        guard version == versionV1 || version == versionV2 else { return nil }
        let headerSize = version == versionV2 ? headerSizeV2 : headerSizeV1
        guard data.count >= headerSize else { return nil }
        guard let codecTag = CodecTag(rawValue: byte(in: data, at: 5)) else { return nil }

        let flags = readUInt16(from: data, offset: 6)
        let width = Int(readUInt32(from: data, offset: 8))
        let height = Int(readUInt32(from: data, offset: 12))
        let timestampMicros = readUInt64(from: data, offset: 16)
        let sequenceNumber: UInt64?
        let payloadLength: Int
        if version == versionV2 {
            sequenceNumber = readUInt64(from: data, offset: 24)
            payloadLength = Int(readUInt32(from: data, offset: 32))
        } else {
            sequenceNumber = nil
            payloadLength = Int(readUInt32(from: data, offset: 24))
        }
        guard payloadLength >= 0, data.count == headerSize + payloadLength else { return nil }

        return ScreenData(
            width: width,
            height: height,
            imageData: subdata(in: data, offsetRange: headerSize..<data.count),
            timestamp: TimeInterval(timestampMicros) / 1_000_000.0,
            format: codecTag.format,
            isSyncFrame: (flags & 0x0001) != 0,
            sequenceNumber: sequenceNumber
        )
    }

    static func startsWithChunkMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return readUInt32(from: data, offset: 0) == screenChunkMagic
    }

    static func decodeChunkEnvelopeIfPresent(_ data: Data) -> ChunkEnvelope? {
        guard data.count >= screenChunkHeaderByteCount,
              readUInt32(from: data, offset: 0) == screenChunkMagic,
              byte(in: data, at: 4) == screenChunkVersion,
              Int(readUInt16(from: data, offset: 6)) == screenChunkHeaderByteCount else {
            return nil
        }

        let flags = byte(in: data, at: 5)
        let chunkIndex = Int(readUInt32(from: data, offset: 16))
        let chunkCount = Int(readUInt32(from: data, offset: 20))
        let totalBytes = Int(readUInt32(from: data, offset: 24))
        let chunkOffset = Int(readUInt32(from: data, offset: 28))
        let chunkBytes = Int(readUInt32(from: data, offset: 32))
        let payloadStart = screenChunkHeaderByteCount

        guard chunkCount > 0,
              chunkIndex >= 0,
              chunkIndex < chunkCount,
              totalBytes > 0,
              chunkOffset >= 0,
              chunkBytes >= 0,
              data.count == payloadStart + chunkBytes,
              (flags & ~0x03) == 0,
              ((flags & 0x01) != 0) == (chunkIndex == 0),
              ((flags & 0x02) != 0) == (chunkIndex == chunkCount - 1) else {
            return nil
        }

        let payload = subdata(in: data, offsetRange: payloadStart..<data.count)
        guard chunkOffset + payload.count <= totalBytes else { return nil }
        return ChunkEnvelope(
            frameId: readUInt64(from: data, offset: 8),
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            totalBytes: totalBytes,
            chunkOffset: chunkOffset,
            payload: payload
        )
    }

    private static let maximumClassifiedAccessUnitBytes = 8 * 1_024 * 1_024
    private static let maximumClassifiedNALUnits = 512
    private static let maximumClassifiedParameterSetBytes = 64 * 1_024

    private struct VideoNALSummary {
        var nalUnitCount = 0
        var hasVPS = false
        var hasSPS = false
        var hasPPS = false
        var hasSyncFrame = false
    }

    /// Strictly classifies one encoded frame without allocating NAL payload copies. For H.264
    /// and HEVC, advertised sync metadata is intentionally not an input: only actual NAL types
    /// can authorize independent/bootstrap recovery behavior.
    static func classifyVideoFrame(
        format: String?,
        imageData: Data
    ) throws -> RemoteDesktopVideoFrameTraits {
        let normalizedFormat = (format ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let codec = CodecTag(format: normalizedFormat)
        guard codec == .h264 || codec == .hevc else {
            return RemoteDesktopVideoFrameTraits(
                normalizedFormat: normalizedFormat,
                isPredictiveVideo: false,
                isIndependentlyDecodableFrame: true,
                isDecoderBootstrapFrame: true
            )
        }

        guard !imageData.isEmpty else {
            throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
        }
        guard imageData.count <= maximumClassifiedAccessUnitBytes else {
            throw RemoteDesktopVideoFrameClassificationError.accessUnitTooLarge(
                actualBytes: imageData.count,
                maximumBytes: maximumClassifiedAccessUnitBytes
            )
        }

        let summary = try imageData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            if startCodeLength(in: bytes, at: 0) != nil {
                return try classifyAnnexB(bytes, codec: codec)
            }
            return try classifyLengthPrefixed(bytes, codec: codec)
        }
        let isBootstrap: Bool
        switch codec {
        case .h264:
            isBootstrap = summary.hasSPS && summary.hasPPS && summary.hasSyncFrame
        case .hevc:
            isBootstrap = summary.hasVPS && summary.hasSPS && summary.hasPPS && summary.hasSyncFrame
        case .jpeg, .bgra, .unknown:
            throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
        }
        return RemoteDesktopVideoFrameTraits(
            normalizedFormat: normalizedFormat,
            isPredictiveVideo: true,
            isIndependentlyDecodableFrame: summary.hasSyncFrame,
            isDecoderBootstrapFrame: isBootstrap
        )
    }

    private static func classifyLengthPrefixed(
        _ bytes: UnsafeBufferPointer<UInt8>,
        codec: CodecTag
    ) throws -> VideoNALSummary {
        var summary = VideoNALSummary()
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else {
                throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
            }
            let declaredLength =
                (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
            offset += 4
            guard declaredLength > 0, declaredLength <= bytes.count - offset else {
                throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
            }
            let minimumNALBytes = codec == .hevc ? 2 : 1
            guard declaredLength >= minimumNALBytes else {
                throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
            }
            try classifyNAL(
                firstByte: bytes[offset],
                secondByte: codec == .hevc ? bytes[offset + 1] : nil,
                byteCount: declaredLength,
                codec: codec,
                summary: &summary
            )
            offset += declaredLength
        }
        guard summary.nalUnitCount > 0 else {
            throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
        }
        return summary
    }

    private static func classifyAnnexB(
        _ bytes: UnsafeBufferPointer<UInt8>,
        codec: CodecTag
    ) throws -> VideoNALSummary {
        guard let firstStartCodeLength = startCodeLength(in: bytes, at: 0) else {
            throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
        }
        var summary = VideoNALSummary()
        var nalStart = firstStartCodeLength
        var searchOffset = nalStart

        while let nextStartCode = findStartCode(in: bytes, from: searchOffset) {
            try classifyNALRange(
                nalStart..<nextStartCode.offset,
                bytes: bytes,
                codec: codec,
                summary: &summary
            )
            nalStart = nextStartCode.offset + nextStartCode.length
            searchOffset = nalStart
        }
        try classifyNALRange(
            nalStart..<bytes.count,
            bytes: bytes,
            codec: codec,
            summary: &summary
        )
        return summary
    }

    private static func classifyNALRange(
        _ range: Range<Int>,
        bytes: UnsafeBufferPointer<UInt8>,
        codec: CodecTag,
        summary: inout VideoNALSummary
    ) throws {
        let minimumBytes = codec == .hevc ? 2 : 1
        guard range.count >= minimumBytes else {
            throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
        }
        try classifyNAL(
            firstByte: bytes[range.lowerBound],
            secondByte: codec == .hevc ? bytes[range.lowerBound + 1] : nil,
            byteCount: range.count,
            codec: codec,
            summary: &summary
        )
    }

    private static func classifyNAL(
        firstByte: UInt8,
        secondByte: UInt8?,
        byteCount: Int,
        codec: CodecTag,
        summary: inout VideoNALSummary
    ) throws {
        let minimumBytes = codec == .hevc ? 2 : 1
        guard byteCount >= minimumBytes else {
            throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
        }
        guard summary.nalUnitCount < maximumClassifiedNALUnits else {
            throw RemoteDesktopVideoFrameClassificationError.tooManyNALUnits(
                actual: summary.nalUnitCount + 1,
                maximum: maximumClassifiedNALUnits
            )
        }
        summary.nalUnitCount += 1

        let nalType: Int
        let parameterSetType: Bool
        switch codec {
        case .h264:
            guard firstByte & 0x80 == 0 else {
                throw RemoteDesktopVideoFrameClassificationError.invalidNALHeader
            }
            nalType = Int(firstByte & 0x1F)
            guard (1...23).contains(nalType) else {
                throw RemoteDesktopVideoFrameClassificationError.invalidNALHeader
            }
            parameterSetType = nalType == 7 || nalType == 8
            if nalType == 5 { summary.hasSyncFrame = true }
            if nalType == 7 { summary.hasSPS = true }
            if nalType == 8 { summary.hasPPS = true }
        case .hevc:
            guard firstByte & 0x80 == 0,
                  let secondByte,
                  secondByte & 0x07 != 0 else {
                throw RemoteDesktopVideoFrameClassificationError.invalidNALHeader
            }
            nalType = Int((firstByte >> 1) & 0x3F)
            parameterSetType = (32...34).contains(nalType)
            if (16...21).contains(nalType) { summary.hasSyncFrame = true }
            if nalType == 32 { summary.hasVPS = true }
            if nalType == 33 { summary.hasSPS = true }
            if nalType == 34 { summary.hasPPS = true }
        case .jpeg, .bgra, .unknown:
            throw RemoteDesktopVideoFrameClassificationError.malformedAccessUnit
        }
        if parameterSetType, byteCount > maximumClassifiedParameterSetBytes {
            throw RemoteDesktopVideoFrameClassificationError.parameterSetTooLarge(
                actualBytes: byteCount,
                maximumBytes: maximumClassifiedParameterSetBytes
            )
        }
    }

    private static func findStartCode(
        in bytes: UnsafeBufferPointer<UInt8>,
        from startOffset: Int
    ) -> (offset: Int, length: Int)? {
        var offset = startOffset
        while offset + 3 <= bytes.count {
            if let length = startCodeLength(in: bytes, at: offset) {
                return (offset, length)
            }
            offset += 1
        }
        return nil
    }

    private static func startCodeLength(
        in bytes: UnsafeBufferPointer<UInt8>,
        at offset: Int
    ) -> Int? {
        guard offset >= 0, offset + 3 <= bytes.count else { return nil }
        if offset + 4 <= bytes.count,
           bytes[offset] == 0,
           bytes[offset + 1] == 0,
           bytes[offset + 2] == 0,
           bytes[offset + 3] == 1 {
            return 4
        }
        if bytes[offset] == 0,
           bytes[offset + 1] == 0,
           bytes[offset + 2] == 1 {
            return 3
        }
        return nil
    }

    private static func readUInt16(from data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { rawBuffer in
            UInt16(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt16.self
                )
            )
        }
    }

    private static func byte(in data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    private static func subdata(in data: Data, offsetRange: Range<Int>) -> Data {
        let lowerBound = data.index(data.startIndex, offsetBy: offsetRange.lowerBound)
        let upperBound = data.index(data.startIndex, offsetBy: offsetRange.upperBound)
        return data.subdata(in: lowerBound..<upperBound)
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            UInt32(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )
            )
        }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data.withUnsafeBytes { rawBuffer in
            UInt64(
                bigEndian: rawBuffer.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt64.self
                )
            )
        }
    }
}

enum RemoteDesktopDecodeQueuePolicy {
    static let maxPredictiveVideoFrames = 12
    static let hardMaxPredictiveVideoFrames = 36
    static let maxQueuedEncodedBytes = 32 * 1_024 * 1_024
    static let progressStallThresholdSeconds: TimeInterval = 0.35

    enum EnqueueResult: Equatable {
        case enqueued
        case enqueuedAboveSoftLimit
        case replacedStillFrame
        case droppedIncomingPredictiveFrame
        case droppedIncomingFrameExceedingByteBudget
        case enteredWaitingForSync
        case recoveredWithIndependentFrame
        case compactedWithIndependentFrame
    }

    enum SequenceValidationResult: Equatable {
        case accepted
        case duplicateOrReordered(previous: UInt64, current: UInt64)
        case gapRequiresSync(previous: UInt64, current: UInt64, missing: UInt64)
    }

    static func isPredictiveVideoFormat(_ format: String?) -> Bool {
        switch (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h264", "hevc":
            return true
        default:
            return false
        }
    }

    static func validatePredictiveSequence(
        previous: UInt64?,
        current: UInt64?,
        isPredictiveVideo: Bool,
        isIndependentFrame: Bool
    ) -> SequenceValidationResult {
        guard isPredictiveVideo, let current else { return .accepted }
        guard let previous else { return .accepted }
        if current <= previous {
            return isIndependentFrame
                ? .accepted
                : .duplicateOrReordered(previous: previous, current: current)
        }
        if current > previous + 1, !isIndependentFrame {
            return .gapRequiresSync(
                previous: previous,
                current: current,
                missing: current - previous - 1
            )
        }
        return .accepted
    }

    /// Returns true when appending one encoded frame would exceed the queue budget.
    /// The subtraction-based comparison cannot wrap even when a caller supplies
    /// synthetic byte counts near `Int.max` in a test.
    static func exceedsEncodedByteBudget<QueuedByteCounts: Sequence>(
        queuedEncodedByteCounts: QueuedByteCounts,
        incomingEncodedBytes: Int,
        maximumEncodedBytes: Int
    ) -> Bool where QueuedByteCounts.Element == Int {
        guard incomingEncodedBytes >= 0,
              maximumEncodedBytes >= 0,
              incomingEncodedBytes <= maximumEncodedBytes else {
            return true
        }

        var remainingBytes = maximumEncodedBytes - incomingEncodedBytes
        for queuedBytes in queuedEncodedByteCounts {
            guard queuedBytes >= 0, queuedBytes <= remainingBytes else {
                return true
            }
            remainingBytes -= queuedBytes
        }
        return false
    }

    static func queuedEncodedByteCount(
        in pendingFrames: [RemoteDesktopClassifiedScreenFrame]
    ) -> Int {
        var totalBytes = 0
        for frame in pendingFrames {
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(
                frame.screenData.imageData.count
            )
            if overflow {
                return Int.max
            }
            totalBytes = nextTotal
        }
        return totalBytes
    }

    @discardableResult
    static func enqueue(
        _ frame: RemoteDesktopClassifiedScreenFrame,
        into pendingFrames: inout [RemoteDesktopClassifiedScreenFrame],
        waitingForSyncFrame: inout Bool,
        decoderProgressStalled: Bool = true,
        maxPredictiveVideoFrames: Int = maxPredictiveVideoFrames,
        hardMaxPredictiveVideoFrames: Int = hardMaxPredictiveVideoFrames,
        maxQueuedEncodedBytes: Int = maxQueuedEncodedBytes
    ) -> EnqueueResult {
        let incomingEncodedBytes = frame.screenData.imageData.count
        let incomingFrameExceedsByteBudget = exceedsEncodedByteBudget(
            queuedEncodedByteCounts: EmptyCollection<Int>(),
            incomingEncodedBytes: incomingEncodedBytes,
            maximumEncodedBytes: maxQueuedEncodedBytes
        )
        if incomingFrameExceedsByteBudget {
            if frame.traits.isPredictiveVideo {
                pendingFrames.removeAll(keepingCapacity: true)
                waitingForSyncFrame = true
            }
            return .droppedIncomingFrameExceedingByteBudget
        }

        guard frame.traits.isPredictiveVideo else {
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = false
            pendingFrames.append(frame)
            return .replacedStillFrame
        }

        if waitingForSyncFrame {
            guard frame.traits.isDecoderBootstrapFrame else {
                return .droppedIncomingPredictiveFrame
            }
            pendingFrames.removeAll(keepingCapacity: true)
            pendingFrames.append(frame)
            waitingForSyncFrame = false
            return .recoveredWithIndependentFrame
        }

        let prospectiveBytesExceedBudget = exceedsEncodedByteBudget(
            queuedEncodedByteCounts: pendingFrames.lazy.map {
                $0.screenData.imageData.count
            },
            incomingEncodedBytes: incomingEncodedBytes,
            maximumEncodedBytes: maxQueuedEncodedBytes
        )
        let queuePressureRequiresRecovery = pendingFrames.count >= hardMaxPredictiveVideoFrames
            || (pendingFrames.count >= maxPredictiveVideoFrames && decoderProgressStalled)
            || prospectiveBytesExceedBudget

        if frame.traits.isIndependentlyDecodableFrame {
            if queuePressureRequiresRecovery {
                pendingFrames.removeAll(keepingCapacity: true)
                pendingFrames.append(frame)
                waitingForSyncFrame = false
                return .compactedWithIndependentFrame
            }
            pendingFrames.append(frame)
            return pendingFrames.count > maxPredictiveVideoFrames ? .enqueuedAboveSoftLimit : .enqueued
        }

        guard !waitingForSyncFrame else {
            return .droppedIncomingPredictiveFrame
        }

        if queuePressureRequiresRecovery {
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = true
            return .enteredWaitingForSync
        }

        pendingFrames.append(frame)
        return pendingFrames.count > maxPredictiveVideoFrames ? .enqueuedAboveSoftLimit : .enqueued
    }

    static func dequeueNext(
        from pendingFrames: inout [RemoteDesktopClassifiedScreenFrame]
    ) -> RemoteDesktopClassifiedScreenFrame? {
        guard !pendingFrames.isEmpty else { return nil }
        return pendingFrames.removeFirst()
    }
}
