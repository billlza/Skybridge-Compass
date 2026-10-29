import Foundation

struct LANRemoteSecureReceiveResult: Sendable {
    struct RawChunkTelemetry: Sendable {
        let chunkBytes: Int
        let receivedAt: Date
        let handlingStartedAt: Date
        let parseTaskScheduledAt: Date?
        let parseTaskStartedAt: Date?
    }

    struct ParserStageTelemetry: Sendable {
        let stageName: String
        let durationMs: Double
        let payloadBytes: Int
        let receiveBufferBytes: Int
    }

    struct SecureReplayDrop: Sendable {
        let packetType: RemoteControlSecurePacketType
        let counter: UInt64
        let highestCounter: UInt64
        let reason: RemoteControlSecureReplayRejectionReason
        let bodyReceivedAt: Date
    }

    struct SBC2FrameDrop: Sendable {
        let reason: String
        let frameId: UInt64?
        let bodyReceivedAt: Date
        let suppressed: Bool
    }

    enum Event: Sendable {
        case audio(RemoteDesktopAudioChunkPayload)
        case screen(ScreenData, payloadBytes: Int, bodyReceivedAt: Date)
        case control(RemoteMessage, payloadBytes: Int, bodyReceivedAt: Date)
    }

    let rawChunk: RawChunkTelemetry?
    let parserDrainStartedAt: Date
    let parserDrainEndedAt: Date
    let payloads: Int
    let completeFrames: Int
    let sbc2Chunks: Int
    let sbc2Frames: Int
    let events: [Event]
    let secureReplayDrops: [SecureReplayDrop]
    let sbc2Drops: [SBC2FrameDrop]
    let parserTimeBudgetHit: Bool
    let hasCompletePayloadPending: Bool
    let receiveBufferBytesAfterDrain: Int
    let parserStageTelemetry: ParserStageTelemetry?
}

actor LANRemoteSecureReceivePipeline {
    private struct ParserStageTelemetryAccumulator {
        var maxStageName = "none"
        var maxDurationMs: Double = 0
        var maxPayloadBytes = 0
        var maxReceiveBufferBytes = 0

        mutating func observe(
            stageName: String,
            startedAt: Date,
            payloadBytes: Int,
            receiveBufferBytes: Int
        ) {
            let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1_000)
            maxPayloadBytes = max(maxPayloadBytes, payloadBytes)
            maxReceiveBufferBytes = max(maxReceiveBufferBytes, receiveBufferBytes)
            guard durationMs > maxDurationMs else { return }
            maxStageName = stageName
            maxDurationMs = durationMs
        }

        var snapshot: LANRemoteSecureReceiveResult.ParserStageTelemetry? {
            guard maxDurationMs > 0 else { return nil }
            return .init(
                stageName: maxStageName,
                durationMs: maxDurationMs,
                payloadBytes: maxPayloadBytes,
                receiveBufferBytes: maxReceiveBufferBytes
            )
        }
    }

    private let maxWireMessageBytes: Int
    private var receiveBuffer = Data()
    private var receiveBufferReadOffset = 0
    private var receiveBufferNewestArrivalAt: Date?
    private var receiveBufferArrivalMarkers: [(endOffset: Int, receivedAt: Date)] = []
    private var screenChunkReassembler: RemoteDesktopScreenFrameWire.ChunkedPayloadReassembler
    private var replayWindow = RemoteControlSecureReplayWindow()

    private enum DecryptResult {
        case opened(RemoteControlSecureOpenedPayload)
        case replayDrop(LANRemoteSecureReceiveResult.SecureReplayDrop)
    }

    init(maxWireMessageBytes: Int) {
        self.maxWireMessageBytes = maxWireMessageBytes
        self.screenChunkReassembler = RemoteDesktopScreenFrameWire.ChunkedPayloadReassembler(
            maxFrameBytes: maxWireMessageBytes
        )
    }

    func appendAndDrain(
        chunk: Data,
        receivedAt: Date,
        keys: SessionKeys,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double,
        parseTaskScheduledAt: Date? = nil,
        parseTaskStartedAt: Date? = nil
    ) throws -> LANRemoteSecureReceiveResult {
        let handlingStartedAt = Date()
        receiveBuffer.append(chunk)
        receiveBufferNewestArrivalAt = receivedAt
        receiveBufferArrivalMarkers.append(
            (endOffset: readableReceiveBufferBytes, receivedAt: receivedAt)
        )
        return try drain(
            keys: keys,
            maxCompleteScreenFrames: maxCompleteScreenFrames,
            maxDrainBudgetMs: maxDrainBudgetMs,
            rawChunk: .init(
                chunkBytes: chunk.count,
                receivedAt: receivedAt,
                handlingStartedAt: handlingStartedAt,
                parseTaskScheduledAt: parseTaskScheduledAt,
                parseTaskStartedAt: parseTaskStartedAt
            )
        )
    }

    func drain(
        keys: SessionKeys,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double
    ) throws -> LANRemoteSecureReceiveResult {
        try drain(
            keys: keys,
            maxCompleteScreenFrames: maxCompleteScreenFrames,
            maxDrainBudgetMs: maxDrainBudgetMs,
            rawChunk: nil
        )
    }

    private func drain(
        keys: SessionKeys,
        maxCompleteScreenFrames: Int,
        maxDrainBudgetMs: Double,
        rawChunk: LANRemoteSecureReceiveResult.RawChunkTelemetry?
    ) throws -> LANRemoteSecureReceiveResult {
        let drainStartedAt = Date()
        let screenFrameBudget = max(1, maxCompleteScreenFrames)
        let timeBudgetMs = max(1.0, maxDrainBudgetMs)
        var payloads = 0
        var completeFrames = 0
        var sbc2Chunks = 0
        var sbc2Frames = 0
        var parserTimeBudgetHit = false
        var events: [LANRemoteSecureReceiveResult.Event] = []
        var secureReplayDrops: [LANRemoteSecureReceiveResult.SecureReplayDrop] = []
        var sbc2Drops: [LANRemoteSecureReceiveResult.SBC2FrameDrop] = []
        var stageTelemetry = ParserStageTelemetryAccumulator()

        while completeFrames < screenFrameBudget {
            if payloads > 0,
               Date().timeIntervalSince(drainStartedAt) * 1_000 >= timeBudgetMs {
                parserTimeBudgetHit = hasCompleteFramedPayloadPending()
                break
            }
            let receiveBufferBytesBeforePop = readableReceiveBufferBytes
            let framedPayloadStartedAt = Date()
            guard let nextPayload = try nextFramedPayload() else { break }
            stageTelemetry.observe(
                stageName: "length-frame-pop",
                startedAt: framedPayloadStartedAt,
                payloadBytes: nextPayload.payload.count,
                receiveBufferBytes: receiveBufferBytesBeforePop
            )
            payloads += 1
            let bodyReceivedAt = nextPayload.receivedAt ?? drainStartedAt
            let isChunkedPayload = RemoteDesktopScreenFrameWire.startsWithChunkMagic(nextPayload.payload)
            let unwrapStartedAt = Date()
            let sbc2DropCountBeforeUnwrap = sbc2Drops.count
            guard let completeWirePayload = try unwrapChunkedPayloadIfNeeded(
                nextPayload.payload,
                receivedAt: bodyReceivedAt,
                sbc2Chunks: &sbc2Chunks,
                sbc2Frames: &sbc2Frames,
                sbc2Drops: &sbc2Drops
            ) else {
                let latestSBC2Drop = sbc2Drops.count > sbc2DropCountBeforeUnwrap
                    ? sbc2Drops.last
                    : nil
                stageTelemetry.observe(
                    stageName: latestSBC2Drop.map { "sbc2-reassembly-\($0.suppressed ? "suppressed" : "drop")-\($0.reason)" }
                        ?? "sbc2-reassembly-wait",
                    startedAt: unwrapStartedAt,
                    payloadBytes: nextPayload.payload.count,
                    receiveBufferBytes: receiveBufferBytesBeforePop
                )
                continue
            }
            stageTelemetry.observe(
                stageName: isChunkedPayload ? "sbc2-reassembly-complete" : "payload-bypass",
                startedAt: unwrapStartedAt,
                payloadBytes: nextPayload.payload.count,
                receiveBufferBytes: receiveBufferBytesBeforePop
            )
            let decryptStartedAt = Date()
            let decryptResult = try decryptPayload(
                completeWirePayload,
                with: keys,
                bodyReceivedAt: bodyReceivedAt
            )
            let openedPayload: RemoteControlSecureOpenedPayload
            switch decryptResult {
            case .opened(let payload):
                openedPayload = payload
            case .replayDrop(let drop):
                secureReplayDrops.append(drop)
                stageTelemetry.observe(
                    stageName: "secure-replay-drop-\(drop.reason.rawValue)",
                    startedAt: decryptStartedAt,
                    payloadBytes: completeWirePayload.count,
                    receiveBufferBytes: receiveBufferBytesBeforePop
                )
                continue
            }
            let payload = openedPayload.payload
            stageTelemetry.observe(
                stageName: "decrypt",
                startedAt: decryptStartedAt,
                payloadBytes: completeWirePayload.count,
                receiveBufferBytes: receiveBufferBytesBeforePop
            )
            let decodeStartedAt = Date()
            let event = try decodePayload(
                payload,
                packetType: openedPayload.packetType,
                counter: openedPayload.counter,
                bodyReceivedAt: bodyReceivedAt
            )
            try validatePacketType(openedPayload.packetType, matches: event, counter: openedPayload.counter)
            stageTelemetry.observe(
                stageName: "decode",
                startedAt: decodeStartedAt,
                payloadBytes: payload.count,
                receiveBufferBytes: receiveBufferBytesBeforePop
            )
            if case .screen = event {
                completeFrames += 1
            }
            events.append(event)
            if Date().timeIntervalSince(drainStartedAt) * 1_000 >= timeBudgetMs {
                parserTimeBudgetHit = hasCompleteFramedPayloadPending()
                break
            }
        }

        return LANRemoteSecureReceiveResult(
            rawChunk: rawChunk,
            parserDrainStartedAt: drainStartedAt,
            parserDrainEndedAt: Date(),
            payloads: payloads,
            completeFrames: completeFrames,
            sbc2Chunks: sbc2Chunks,
            sbc2Frames: sbc2Frames,
            events: events,
            secureReplayDrops: secureReplayDrops,
            sbc2Drops: sbc2Drops,
            parserTimeBudgetHit: parserTimeBudgetHit,
            hasCompletePayloadPending: hasCompleteFramedPayloadPending(),
            receiveBufferBytesAfterDrain: readableReceiveBufferBytes,
            parserStageTelemetry: stageTelemetry.snapshot
        )
    }

    private func decryptPayload(
        _ ciphertext: Data,
        with keys: SessionKeys,
        bodyReceivedAt: Date
    ) throws -> DecryptResult {
        do {
            let openedPayload = try RemoteControlSecureEnvelope.open(
                ciphertext,
                keys: keys,
                allowedPacketTypes: [.control, .screen, .audio]
            )
            do {
                try replayWindow.validateAndRecord(openedPayload)
                return .opened(openedPayload)
            } catch let replayError as RemoteControlSecureEnvelopeError {
                guard case .replayDetected(let packetType, let counter, let highestCounter, let reason) = replayError else {
                    throw replayError
                }
                return .replayDrop(
                    .init(
                        packetType: packetType,
                        counter: counter,
                        highestCounter: highestCounter,
                        reason: reason,
                        bodyReceivedAt: bodyReceivedAt
                    )
                )
            }
        } catch {
            throw RemoteDesktopError.streamingFailed(
                "LAN secure decrypt failed bytes=\(ciphertext.count) session=\(keys.sessionId) role=\(keys.role.rawValue) suite=\(keys.negotiatedSuite.rawValue) error=\(error.localizedDescription)"
            )
        }
    }

    private func validatePacketType(
        _ packetType: RemoteControlSecurePacketType,
        matches event: LANRemoteSecureReceiveResult.Event,
        counter: UInt64
    ) throws {
        let expected: RemoteControlSecurePacketType
        switch event {
        case .audio:
            expected = .audio
        case .screen:
            expected = .screen
        case .control:
            expected = .control
        }
        guard packetType == expected else {
            throw RemoteDesktopError.streamingFailed(
                "LAN secure packet type mismatch expected=\(expected.rawValue) actual=\(packetType.rawValue) counter=\(counter)"
            )
        }
    }

    private func decodePayload(
        _ payload: Data,
        packetType: RemoteControlSecurePacketType,
        counter: UInt64,
        bodyReceivedAt: Date
    ) throws -> LANRemoteSecureReceiveResult.Event {
        switch packetType {
        case .audio:
            guard let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(payload) else {
                throw RemoteDesktopError.streamingFailed(
                    "LAN secure audio payload decode failed counter=\(counter)"
                )
            }
            return .audio(audioChunk)
        case .screen:
            if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(payload) {
                return .screen(screenData, payloadBytes: payload.count, bodyReceivedAt: bodyReceivedAt)
            }
            let message = try JSONDecoder().decode(RemoteMessage.self, from: payload)
            guard message.type == .screenData else {
                throw RemoteDesktopError.streamingFailed(
                    "LAN secure screen payload type mismatch counter=\(counter) messageType=\(message.type.rawValue)"
                )
            }
            let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
            return .screen(screenData, payloadBytes: payload.count, bodyReceivedAt: bodyReceivedAt)
        case .control:
            let message = try JSONDecoder().decode(RemoteMessage.self, from: payload)
            guard message.type != .screenData else {
                throw RemoteDesktopError.streamingFailed(
                    "LAN secure control payload carried screenData counter=\(counter)"
                )
            }
            return .control(message, payloadBytes: payload.count, bodyReceivedAt: bodyReceivedAt)
        }
    }

    private func unwrapChunkedPayloadIfNeeded(
        _ data: Data,
        receivedAt: Date,
        sbc2Chunks: inout Int,
        sbc2Frames: inout Int,
        sbc2Drops: inout [LANRemoteSecureReceiveResult.SBC2FrameDrop]
    ) throws -> Data? {
        guard RemoteDesktopScreenFrameWire.startsWithChunkMagic(data) else {
            return data
        }

        guard let envelope = RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(data) else {
            sbc2Drops.append(
                .init(
                    reason: "sbc2-chunk-decode-failed",
                    frameId: nil,
                    bodyReceivedAt: receivedAt,
                    suppressed: false
                )
            )
            return nil
        }
        sbc2Chunks += 1

        switch screenChunkReassembler.append(envelope, now: receivedAt) {
        case .waiting:
            return nil
        case .complete(_, let payload):
            sbc2Frames += 1
            return payload
        case .dropped(let reason, let frameId):
            sbc2Drops.append(
                .init(
                    reason: reason,
                    frameId: frameId,
                    bodyReceivedAt: receivedAt,
                    suppressed: false
                )
            )
            return nil
        case .suppressed(let frameId, let reason):
            sbc2Drops.append(
                .init(
                    reason: reason,
                    frameId: frameId,
                    bodyReceivedAt: receivedAt,
                    suppressed: true
                )
            )
            return nil
        }
    }

    private func nextFramedPayload() throws -> (payload: Data, receivedAt: Date?)? {
        guard readableReceiveBufferBytes >= 4 else { return nil }
        let length = Int(receiveBuffer.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: receiveBufferReadOffset, as: UInt32.self).bigEndian
        })
        if length <= 0 || length > maxWireMessageBytes {
            throw RemoteDesktopError.streamingFailed("消息长度异常：\(length) bytes")
        }

        let totalLength = 4 + length
        guard readableReceiveBufferBytes >= totalLength else { return nil }
        let receivedAt = arrivalTime(forPayloadEndingAt: totalLength)
        let payloadStart = receiveBuffer.index(
            receiveBuffer.startIndex,
            offsetBy: receiveBufferReadOffset + 4
        )
        let payloadEnd = receiveBuffer.index(payloadStart, offsetBy: length)
        let payload = Data(receiveBuffer[payloadStart..<payloadEnd])
        receiveBufferReadOffset += totalLength
        consumeBytes(totalLength)
        compactReceiveBufferIfNeeded()
        return (payload, receivedAt)
    }

    private func arrivalTime(forPayloadEndingAt endOffset: Int) -> Date? {
        receiveBufferArrivalMarkers.first(where: { $0.endOffset >= endOffset })?.receivedAt
            ?? receiveBufferNewestArrivalAt
    }

    private func consumeBytes(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        receiveBufferArrivalMarkers = receiveBufferArrivalMarkers.compactMap { marker in
            let adjustedEndOffset = marker.endOffset - byteCount
            guard adjustedEndOffset > 0 else { return nil }
            return (endOffset: adjustedEndOffset, receivedAt: marker.receivedAt)
        }
        receiveBufferNewestArrivalAt = receiveBufferArrivalMarkers.last?.receivedAt
    }

    private func hasCompleteFramedPayloadPending() -> Bool {
        guard readableReceiveBufferBytes >= 4 else { return false }
        let length = Int(receiveBuffer.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: receiveBufferReadOffset, as: UInt32.self).bigEndian
        })
        guard length > 0, length <= maxWireMessageBytes else { return true }
        return readableReceiveBufferBytes >= 4 + length
    }

    private var readableReceiveBufferBytes: Int {
        max(0, receiveBuffer.count - receiveBufferReadOffset)
    }

    private func compactReceiveBufferIfNeeded() {
        guard receiveBufferReadOffset > 0 else { return }
        if receiveBufferReadOffset >= receiveBuffer.count {
            receiveBuffer.removeAll(keepingCapacity: true)
            receiveBufferReadOffset = 0
            return
        }
        let shouldCompact = receiveBufferReadOffset >= 512 * 1024
            || receiveBufferReadOffset > receiveBuffer.count / 2
        guard shouldCompact else { return }
        let compactEnd = receiveBuffer.index(
            receiveBuffer.startIndex,
            offsetBy: receiveBufferReadOffset
        )
        receiveBuffer.removeSubrange(receiveBuffer.startIndex..<compactEnd)
        receiveBufferReadOffset = 0
    }
}
