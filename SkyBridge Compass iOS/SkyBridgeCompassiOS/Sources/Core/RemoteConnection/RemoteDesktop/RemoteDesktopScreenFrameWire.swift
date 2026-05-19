import Foundation

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
            case failed(reason: String, frameId: UInt64?)
        }

        private let maxFrameBytes: Int
        private let frameTTL: TimeInterval = 1.0
        private var frameId: UInt64?
        private var expectedChunkCount = 0
        private var expectedTotalBytes = 0
        private var nextChunkIndex = 0
        private var receivedBytes = 0
        private var chunks: [Data] = []
        private var lastUpdatedAt: Date = .distantPast

        init(maxFrameBytes: Int) {
            self.maxFrameBytes = maxFrameBytes
        }

        mutating func reset() {
            frameId = nil
            expectedChunkCount = 0
            expectedTotalBytes = 0
            nextChunkIndex = 0
            receivedBytes = 0
            chunks.removeAll(keepingCapacity: true)
            lastUpdatedAt = .distantPast
        }

        mutating func append(_ envelope: ChunkEnvelope, now: Date) -> Result {
            guard envelope.chunkCount > 0,
                  envelope.chunkIndex >= 0,
                  envelope.chunkIndex < envelope.chunkCount,
                  envelope.totalBytes > 0,
                  envelope.totalBytes <= maxFrameBytes,
                  envelope.chunkOffset >= 0,
                  envelope.chunkOffset + envelope.payload.count <= envelope.totalBytes else {
                reset()
                return .failed(reason: "invalid-sbc2-chunk-metadata", frameId: envelope.frameId)
            }

            if let currentFrameId = frameId,
               now.timeIntervalSince(lastUpdatedAt) > frameTTL {
                reset()
                return .failed(reason: "sbc2-chunk-timeout", frameId: currentFrameId)
            }

            if frameId == nil {
                guard envelope.chunkIndex == 0, envelope.chunkOffset == 0 else {
                    reset()
                    return .failed(reason: "missing-first-sbc2-chunk", frameId: envelope.frameId)
                }
                beginFrame(envelope)
            } else if frameId != envelope.frameId
                        || expectedChunkCount != envelope.chunkCount
                        || expectedTotalBytes != envelope.totalBytes {
                let failedFrameId = frameId
                reset()
                return .failed(reason: "interleaved-or-restarted-sbc2-frame", frameId: failedFrameId ?? envelope.frameId)
            }

            guard envelope.chunkIndex == nextChunkIndex,
                  envelope.chunkOffset == receivedBytes else {
                let failedFrameId = frameId ?? envelope.frameId
                reset()
                return .failed(reason: "out-of-order-sbc2-chunk", frameId: failedFrameId)
            }

            chunks.append(envelope.payload)
            receivedBytes += envelope.payload.count
            nextChunkIndex += 1
            lastUpdatedAt = now

            if nextChunkIndex == expectedChunkCount {
                guard receivedBytes == expectedTotalBytes else {
                    let failedFrameId = frameId
                    reset()
                    return .failed(reason: "sbc2-total-bytes-mismatch", frameId: failedFrameId)
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
        let version = data[4]
        guard version == versionV1 || version == versionV2 else { return nil }
        let headerSize = version == versionV2 ? headerSizeV2 : headerSizeV1
        guard data.count >= headerSize else { return nil }
        guard let codecTag = CodecTag(rawValue: data[5]) else { return nil }

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
            imageData: data.subdata(in: headerSize..<data.count),
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
              data[4] == screenChunkVersion,
              Int(readUInt16(from: data, offset: 6)) == screenChunkHeaderByteCount else {
            return nil
        }

        let flags = data[5]
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

        let payload = data.subdata(in: payloadStart..<data.count)
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

    static func containsSyncFrame(
        format: String?,
        imageData: Data,
        advertisedSyncFrame: Bool?
    ) -> Bool {
        switch CodecTag(format: format) {
        case .jpeg, .bgra, .unknown:
            return advertisedSyncFrame ?? true
        case .h264:
            return parseNALUnits(from: imageData).contains { nalu in
                guard let first = nalu.first else { return false }
                return Int(first & 0x1F) == 5
            }
        case .hevc:
            return parseNALUnits(from: imageData).contains { nalu in
                guard let first = nalu.first else { return false }
                let type = Int((first >> 1) & 0x3F)
                return (16...21).contains(type)
            }
        }
    }

    private static func parseNALUnits(from data: Data) -> [Data] {
        if data.count >= 4,
           data.starts(with: [0x00, 0x00, 0x00, 0x01]) || data.starts(with: [0x00, 0x00, 0x01]) {
            return parseAnnexBNALUnits(from: data)
        }
        return parseLengthPrefixedNALUnits(from: data)
    }

    private static func parseLengthPrefixedNALUnits(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = data.withUnsafeBytes { raw -> Int in
                let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Int(UInt32(bigEndian: value))
            }
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            nalus.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return nalus
    }

    private static func parseAnnexBNALUnits(from data: Data) -> [Data] {
        func startCodeLength(at index: Int) -> Int? {
            guard index + 3 <= data.count else { return nil }
            if index + 4 <= data.count,
               data[index] == 0x00, data[index + 1] == 0x00, data[index + 2] == 0x00, data[index + 3] == 0x01 {
                return 4
            }
            if data[index] == 0x00, data[index + 1] == 0x00, data[index + 2] == 0x01 {
                return 3
            }
            return nil
        }

        var nalus: [Data] = []
        var currentStart: Int?
        var currentSkip = 0
        var index = 0

        while index < data.count {
            if let skip = startCodeLength(at: index) {
                if let start = currentStart {
                    let naluStart = start + currentSkip
                    if naluStart < index {
                        nalus.append(data.subdata(in: naluStart..<index))
                    }
                }
                currentStart = index
                currentSkip = skip
                index += skip
            } else {
                index += 1
            }
        }

        if let start = currentStart {
            let naluStart = start + currentSkip
            if naluStart < data.count {
                nalus.append(data.subdata(in: naluStart..<data.count))
            }
        }
        return nalus
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

extension ScreenData {
    var normalizedFormat: String {
        (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isCompressedPredictiveVideoFrame: Bool {
        switch normalizedFormat {
        case "h264", "hevc":
            return true
        default:
            return false
        }
    }

    var isIndependentlyDecodableFrame: Bool {
        if isCompressedPredictiveVideoFrame {
            return RemoteDesktopScreenFrameWire.containsSyncFrame(
                format: format,
                imageData: imageData,
                advertisedSyncFrame: isSyncFrame
            )
        }
        return true
    }
}

enum RemoteDesktopDecodeQueuePolicy {
    static let maxPredictiveVideoFrames = 12
    static let hardMaxPredictiveVideoFrames = 36
    static let progressStallThresholdSeconds: TimeInterval = 0.35

    enum EnqueueResult: Equatable {
        case enqueued
        case enqueuedAboveSoftLimit
        case replacedStillFrame
        case droppedIncomingPredictiveFrame
        case enteredWaitingForSync
        case recoveredWithIndependentFrame
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

    @discardableResult
    static func enqueue(
        _ screenData: ScreenData,
        into pendingFrames: inout [ScreenData],
        waitingForSyncFrame: inout Bool,
        decoderProgressStalled: Bool = true,
        maxPredictiveVideoFrames: Int = maxPredictiveVideoFrames,
        hardMaxPredictiveVideoFrames: Int = hardMaxPredictiveVideoFrames
    ) -> EnqueueResult {
        guard isPredictiveVideoFormat(screenData.format) else {
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = false
            pendingFrames.append(screenData)
            return .replacedStillFrame
        }

        if screenData.isIndependentlyDecodableFrame {
            if waitingForSyncFrame {
                pendingFrames.removeAll(keepingCapacity: true)
                waitingForSyncFrame = false
                pendingFrames.append(screenData)
                return .recoveredWithIndependentFrame
            }
            pendingFrames.append(screenData)
            return pendingFrames.count > maxPredictiveVideoFrames ? .enqueuedAboveSoftLimit : .enqueued
        }

        guard !waitingForSyncFrame else {
            return .droppedIncomingPredictiveFrame
        }

        if pendingFrames.count >= hardMaxPredictiveVideoFrames
            || (pendingFrames.count >= maxPredictiveVideoFrames && decoderProgressStalled) {
            pendingFrames.removeAll(keepingCapacity: true)
            waitingForSyncFrame = true
            return .enteredWaitingForSync
        }

        pendingFrames.append(screenData)
        return pendingFrames.count > maxPredictiveVideoFrames ? .enqueuedAboveSoftLimit : .enqueued
    }

    static func dequeueNext(from pendingFrames: inout [ScreenData]) -> ScreenData? {
        guard !pendingFrames.isEmpty else { return nil }
        return pendingFrames.removeFirst()
    }
}

