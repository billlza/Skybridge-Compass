import Foundation

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    struct InboundFrameParser {
        private(set) var buffer = Data()
        private(set) var readOffset = 0
        let maxInboundFrameBytes: Int

        var canProbeDirectCompatibility: Bool {
            readOffset >= buffer.count
        }

        mutating func append(_ chunk: Data) {
            compact()
            buffer.append(chunk)
        }

        mutating func nextPayload(
            sessionId: String,
            logLabel: String
        ) -> Data? {
            while buffer.count - readOffset >= 4 {
                if Self.startsWithKnownDirectEnvelope(buffer, at: readOffset) {
                    let bufferedBytes = buffer.count - readOffset
                    let prefixEnd = min(buffer.count, readOffset + 8)
                    let prefixStartIndex = buffer.index(buffer.startIndex, offsetBy: readOffset)
                    let prefixEndIndex = buffer.index(buffer.startIndex, offsetBy: prefixEnd)
                    let prefix = buffer[prefixStartIndex..<prefixEndIndex]
                        .map { String(format: "%02x", $0) }
                        .joined()
                    let magic = Self.knownDirectEnvelopeName(buffer, at: readOffset) ?? "unknown"
                    SkyBridgeLogger.shared.warning(
                        "⚠️ drop wrong-channel or unframed direct \(logLabel) envelope before length parser: magic=\(magic) buffered=\(bufferedBytes) prefix=\(prefix) reset=direct-envelope session=\(sessionId)"
                    )
                    reset()
                    return nil
                }

                let length: Int = buffer.withUnsafeBytes { ptr in
                    let b0 = ptr.load(fromByteOffset: readOffset, as: UInt8.self)
                    let b1 = ptr.load(fromByteOffset: readOffset + 1, as: UInt8.self)
                    let b2 = ptr.load(fromByteOffset: readOffset + 2, as: UInt8.self)
                    let b3 = ptr.load(fromByteOffset: readOffset + 3, as: UInt8.self)
                    return (Int(b0) << 24) | (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)
                }

                guard length > 0 && length <= maxInboundFrameBytes else {
                    let bufferedBytes = buffer.count - readOffset
                    let prefixEnd = min(buffer.count, readOffset + 8)
                    let prefixStartIndex = buffer.index(buffer.startIndex, offsetBy: readOffset)
                    let prefixEndIndex = buffer.index(buffer.startIndex, offsetBy: prefixEnd)
                    let prefix = buffer[prefixStartIndex..<prefixEndIndex]
                        .map { String(format: "%02x", $0) }
                        .joined()
                    SkyBridgeLogger.shared.warning(
                        "⚠️ drop invalid \(logLabel) frame length: len=\(length) max=\(maxInboundFrameBytes) buffered=\(bufferedBytes) prefix=\(prefix) reset=invalid-length session=\(sessionId)"
                    )
                    // WebRTC DataChannel is reliable and ordered. If framing is poisoned, byte-by-byte
                    // resync can turn arbitrary ciphertext into a fake handshake packet. Drop the whole
                    // buffered frame state and wait for the next clean prefix instead.
                    reset()
                    return nil
                }

                guard buffer.count - readOffset >= 4 + length else {
                    compact()
                    return nil
                }

                let start = readOffset + 4
                let end = start + length
                let payloadStart = buffer.index(buffer.startIndex, offsetBy: start)
                let payloadEnd = buffer.index(buffer.startIndex, offsetBy: end)
                let payload = buffer.subdata(in: payloadStart..<payloadEnd)
                readOffset = end
                compact()
                return payload
            }

            compact()
            return nil
        }

        private mutating func compact() {
            if readOffset >= buffer.count {
                reset()
                return
            }

            if readOffset > 0, (readOffset >= 4096 || readOffset * 2 >= buffer.count) {
                let consumedEnd = buffer.index(buffer.startIndex, offsetBy: readOffset)
                buffer.removeSubrange(buffer.startIndex..<consumedEnd)
                readOffset = 0
            }

            if buffer.count > maxInboundFrameBytes * 2 {
                reset()
            }
        }

        private mutating func reset() {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }

        static func lengthPrefix(from data: Data) -> Int? {
            guard data.count >= 4 else { return nil }
            return data.withUnsafeBytes { ptr in
                let b0 = ptr.load(fromByteOffset: 0, as: UInt8.self)
                let b1 = ptr.load(fromByteOffset: 1, as: UInt8.self)
                let b2 = ptr.load(fromByteOffset: 2, as: UInt8.self)
                let b3 = ptr.load(fromByteOffset: 3, as: UInt8.self)
                return (Int(b0) << 24) | (Int(b1) << 16) | (Int(b2) << 8) | Int(b3)
            }
        }

        static func startsWithKnownDirectEnvelope(_ data: Data, at offset: Int = 0) -> Bool {
            knownDirectEnvelopeName(data, at: offset) != nil
        }

        static func knownDirectEnvelopeName(_ data: Data, at offset: Int = 0) -> String? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let magicStart = data.index(data.startIndex, offsetBy: offset)
            let magicEnd = data.index(magicStart, offsetBy: 4)
            let magic = data[magicStart..<magicEnd]
            if magic.elementsEqual([0x53, 0x42, 0x50, 0x32]) { return "SBP2" } // traffic padding
            if magic.elementsEqual([0x53, 0x42, 0x52, 0x46]) { return "SBRF" } // screen frame
            if magic.elementsEqual([0x53, 0x42, 0x52, 0x41]) { return "SBRA" } // audio frame
            if magic.elementsEqual([0x53, 0x42, 0x43, 0x32]) { return "SBC2" } // screen chunk
            return nil
        }
    }

    struct ScreenChannelWireDecoder {
        enum Mode: String, Equatable {
            case unknown
            case lengthFramed
            case directPayload
            case chunkedPayload = "sbc2-chunked-v1"
        }

        private(set) var mode: Mode = .unknown
        private(set) var parser: InboundFrameParser
        private var chunkedReassembler: ScreenChunkedPayloadReassembler
        let maxInboundFrameBytes: Int

        private var pendingDirectCandidate: (data: Data, receivedAt: Date)?
        private let pendingCandidateTTL: TimeInterval = 1.0

        init(maxInboundFrameBytes: Int) {
            self.maxInboundFrameBytes = maxInboundFrameBytes
            self.parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            self.chunkedReassembler = ScreenChunkedPayloadReassembler(maxFrameBytes: maxInboundFrameBytes)
        }

        var canProbeDirectPayload: Bool {
            mode != .lengthFramed && parser.canProbeDirectCompatibility
        }

        var hasPendingDirectCandidate: Bool {
            pendingDirectCandidate != nil
        }

        mutating func markDirectPayloadMode() {
            mode = .directPayload
            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            chunkedReassembler.reset()
            pendingDirectCandidate = nil
        }

        mutating func markLengthFramedMode() {
            if mode == .unknown {
                mode = .lengthFramed
            }
            pendingDirectCandidate = nil
        }

        mutating func resetLengthFramedAfterDecodeFailure() {
            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            if mode == .lengthFramed {
                mode = .unknown
            }
            pendingDirectCandidate = nil
        }

        mutating func markChunkedPayloadMode() {
            mode = .chunkedPayload
            parser = InboundFrameParser(maxInboundFrameBytes: maxInboundFrameBytes)
            pendingDirectCandidate = nil
        }

        func isChunkedPayload(_ chunk: Data) -> Bool {
            ScreenChunkedPayloadEnvelope.startsWithMagic(chunk)
        }

        mutating func appendChunkedPayload(_ chunk: Data, now: Date) -> ScreenChunkedPayloadReassembler.Result {
            guard let envelope = ScreenChunkedPayloadEnvelope.decode(chunk) else {
                chunkedReassembler.reset()
                return .dropped(reason: "invalid-sbc2-envelope", frameId: nil)
            }
            return chunkedReassembler.append(envelope, now: now)
        }

        func shouldKeepOutOfLengthParser(_ chunk: Data) -> Bool {
            guard canProbeDirectPayload else { return mode == .directPayload }
            if InboundFrameParser.startsWithKnownDirectEnvelope(chunk) {
                return true
            }
            guard let length = InboundFrameParser.lengthPrefix(from: chunk) else {
                return false
            }
            return length <= 0 || length >= maxInboundFrameBytes
        }

        mutating func cacheDirectCandidateIfPossible(_ chunk: Data, now: Date) -> Bool {
            guard chunk.count <= maxInboundFrameBytes else { return false }
            pendingDirectCandidate = (chunk, now)
            return true
        }

        mutating func takePendingDirectCandidate(now: Date) -> Data? {
            guard let candidate = pendingDirectCandidate else { return nil }
            pendingDirectCandidate = nil
            guard now.timeIntervalSince(candidate.receivedAt) <= pendingCandidateTTL else {
                return nil
            }
            return candidate.data
        }

        mutating func appendLengthChunk(_ chunk: Data) {
            parser.append(chunk)
        }

        mutating func nextLengthPayload(sessionId: String, logLabel: String) -> Data? {
            parser.nextPayload(sessionId: sessionId, logLabel: logLabel)
        }
    }

    enum ScreenChannelLengthFramedDecodeFailureAction: Equatable {
        case dropAuthenticatedReplay(
            packetType: WebRTCAppSecurePacketType,
            counter: UInt64,
            highestCounter: UInt64,
            reason: WebRTCAppSecureReplayRejectionReason
        )
        case resetParser
    }

    nonisolated static func screenLengthFramedDecodeFailureAction(
        for error: Error
    ) -> ScreenChannelLengthFramedDecodeFailureAction {
        guard let envelopeError = error as? WebRTCAppSecureEnvelopeError else {
            return .resetParser
        }
        guard case let .replayDetected(
            packetType,
            counter,
            highestCounter,
            reason
        ) = envelopeError else {
            return .resetParser
        }
        return .dropAuthenticatedReplay(
            packetType: packetType,
            counter: counter,
            highestCounter: highestCounter,
            reason: reason
        )
    }

    struct ScreenChunkedPayloadEnvelope {
        static let magic: UInt32 = 0x5342_4332 // SBC2
        static let version: UInt8 = 1
        static let headerLength = 36

        let frameId: UInt64
        let chunkIndex: Int
        let chunkCount: Int
        let totalBytes: Int
        let chunkOffset: Int
        let payload: Data

        static func startsWithMagic(_ data: Data) -> Bool {
            guard data.count >= 4 else { return false }
            return readUInt32(data, at: 0) == magic
        }

        static func decode(_ data: Data) -> ScreenChunkedPayloadEnvelope? {
            guard data.count >= headerLength,
                  readUInt32(data, at: 0) == magic,
                  byte(in: data, at: 4) == version,
                  Int(readUInt16(data, at: 6)) == headerLength else {
                return nil
            }
            let chunkBytes = Int(readUInt32(data, at: 32))
            guard chunkBytes >= 0,
                  data.count == headerLength + chunkBytes else {
                return nil
            }
            let frameId = readUInt64(data, at: 8)
            let chunkIndex = Int(readUInt32(data, at: 16))
            let chunkCount = Int(readUInt32(data, at: 20))
            let totalBytes = Int(readUInt32(data, at: 24))
            let chunkOffset = Int(readUInt32(data, at: 28))
            let payloadStart = data.index(data.startIndex, offsetBy: headerLength)
            let payload = data.subdata(in: payloadStart..<data.endIndex)
            return ScreenChunkedPayloadEnvelope(
                frameId: frameId,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                totalBytes: totalBytes,
                chunkOffset: chunkOffset,
                payload: payload
            )
        }

        private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
            data.withUnsafeBytes { ptr in
                let b0 = UInt16(ptr.load(fromByteOffset: offset, as: UInt8.self))
                let b1 = UInt16(ptr.load(fromByteOffset: offset + 1, as: UInt8.self))
                return (b0 << 8) | b1
            }
        }

        private static func byte(in data: Data, at offset: Int) -> UInt8 {
            data[data.index(data.startIndex, offsetBy: offset)]
        }

        private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
            data.withUnsafeBytes { ptr in
                let b0 = UInt32(ptr.load(fromByteOffset: offset, as: UInt8.self))
                let b1 = UInt32(ptr.load(fromByteOffset: offset + 1, as: UInt8.self))
                let b2 = UInt32(ptr.load(fromByteOffset: offset + 2, as: UInt8.self))
                let b3 = UInt32(ptr.load(fromByteOffset: offset + 3, as: UInt8.self))
                return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            }
        }

        private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
            data.withUnsafeBytes { ptr in
                var value: UInt64 = 0
                for idx in 0..<8 {
                    value = (value << 8) | UInt64(ptr.load(fromByteOffset: offset + idx, as: UInt8.self))
                }
                return value
            }
        }
    }

    struct ScreenChunkedPayloadReassembler {
        enum Result: Equatable {
            case waiting(frameId: UInt64, chunkIndex: Int, chunkCount: Int)
            case complete(frameId: UInt64, payload: Data)
            case dropped(reason: String, frameId: UInt64?)
            case suppressed(frameId: UInt64, reason: String)
        }

        private let maxFrameBytes: Int
        private let maxChunkCount = 2_048
        private var frameId: UInt64?
        private var suppressedFrameReasons: [UInt64: String] = [:]
        private var suppressedFrameOrder: [UInt64] = []
        private var expectedChunkCount: Int = 0
        private var expectedTotalBytes: Int = 0
        private var nextChunkIndex: Int = 0
        private var receivedBytes: Int = 0
        private var chunks: [Data] = []
        private var lastUpdatedAt: Date = .distantPast
        private let frameTTL: TimeInterval = 1.0

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
                clearSuppressedFrame()
            }
        }

        private mutating func clearSuppressedFrame() {
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

        private mutating func beginFrame(_ envelope: ScreenChunkedPayloadEnvelope) {
            clearSuppressedFrame()
            frameId = envelope.frameId
            expectedChunkCount = envelope.chunkCount
            expectedTotalBytes = envelope.totalBytes
            nextChunkIndex = 0
            receivedBytes = 0
            chunks.removeAll(keepingCapacity: true)
        }

        mutating func append(
            _ envelope: ScreenChunkedPayloadEnvelope,
            now: Date
        ) -> Result {
            if let suppressedReason = suppressedFrameReasons[envelope.frameId] {
                return .suppressed(frameId: envelope.frameId, reason: suppressedReason)
            } else if envelope.chunkIndex == 0 {
                clearSuppressedFrame()
            }

            if frameId != nil, now.timeIntervalSince(lastUpdatedAt) > frameTTL {
                let droppedFrame = frameId
                reset()
                if envelope.chunkIndex != 0 {
                    return drop(
                        reason: "expired-missing-first-chunk",
                        frameId: droppedFrame,
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
                guard envelope.chunkIndex == 0,
                      envelope.chunkOffset == 0 else {
                    return drop(
                        reason: "missing-first-chunk",
                        frameId: envelope.frameId,
                        suppressOrphansFor: [envelope.frameId]
                    )
                }
                beginFrame(envelope)
            } else if frameId != envelope.frameId ||
                        expectedChunkCount != envelope.chunkCount ||
                        expectedTotalBytes != envelope.totalBytes {
                let droppedFrame = frameId
                guard envelope.chunkIndex == 0,
                      envelope.chunkOffset == 0,
                      frameId != envelope.frameId else {
                    let orphanFrames = frameId == envelope.frameId
                        ? [droppedFrame ?? envelope.frameId]
                        : [droppedFrame, envelope.frameId].compactMap { $0 }
                    return drop(
                        reason: "out-of-order-or-new-frame",
                        frameId: orphanFrames.first ?? envelope.frameId,
                        suppressOrphansFor: orphanFrames
                    )
                }
                reset()
                beginFrame(envelope)
            }

            guard envelope.chunkIndex == nextChunkIndex,
                  envelope.chunkOffset == receivedBytes else {
                let droppedFrame = frameId ?? envelope.frameId
                return drop(
                    reason: "out-of-order-or-new-frame",
                    frameId: droppedFrame,
                    suppressOrphansFor: [droppedFrame]
                )
            }

            chunks.append(envelope.payload)
            receivedBytes += envelope.payload.count
            nextChunkIndex += 1
            lastUpdatedAt = now

            if nextChunkIndex == expectedChunkCount {
                guard receivedBytes == expectedTotalBytes else {
                    let droppedFrame = frameId
                    return drop(reason: "total-bytes-mismatch", frameId: droppedFrame)
                }
                let completeFrameId = frameId ?? envelope.frameId
                var payload = Data(capacity: expectedTotalBytes)
                for chunk in chunks { payload.append(chunk) }
                reset()
                return .complete(frameId: completeFrameId, payload: payload)
            }

            return .waiting(
                frameId: envelope.frameId,
                chunkIndex: envelope.chunkIndex,
                chunkCount: envelope.chunkCount
            )
        }
    }
}
