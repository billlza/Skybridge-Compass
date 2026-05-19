import CryptoKit
import Foundation

struct LANRemoteSecureReceiveResult: Sendable {
    struct RawChunkTelemetry: Sendable {
        let receivedAt: Date
        let handlingStartedAt: Date
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
    let hasCompletePayloadPending: Bool
}

actor LANRemoteSecureReceivePipeline {
    private let maxWireMessageBytes: Int
    private var receiveBuffer = Data()
    private var receiveBufferNewestArrivalAt: Date?
    private var receiveBufferArrivalMarkers: [(endOffset: Int, receivedAt: Date)] = []
    private var screenChunkReassembler: RemoteDesktopScreenFrameWire.ChunkedPayloadReassembler

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
        maxCompleteScreenFrames: Int
    ) throws -> LANRemoteSecureReceiveResult {
        let handlingStartedAt = Date()
        receiveBuffer.append(chunk)
        receiveBufferNewestArrivalAt = receivedAt
        receiveBufferArrivalMarkers.append((endOffset: receiveBuffer.count, receivedAt: receivedAt))
        return try drain(
            keys: keys,
            maxCompleteScreenFrames: maxCompleteScreenFrames,
            rawChunk: .init(receivedAt: receivedAt, handlingStartedAt: handlingStartedAt)
        )
    }

    func drain(
        keys: SessionKeys,
        maxCompleteScreenFrames: Int
    ) throws -> LANRemoteSecureReceiveResult {
        try drain(keys: keys, maxCompleteScreenFrames: maxCompleteScreenFrames, rawChunk: nil)
    }

    private func drain(
        keys: SessionKeys,
        maxCompleteScreenFrames: Int,
        rawChunk: LANRemoteSecureReceiveResult.RawChunkTelemetry?
    ) throws -> LANRemoteSecureReceiveResult {
        let drainStartedAt = Date()
        let screenFrameBudget = max(1, maxCompleteScreenFrames)
        var payloads = 0
        var completeFrames = 0
        var sbc2Chunks = 0
        var sbc2Frames = 0
        var events: [LANRemoteSecureReceiveResult.Event] = []

        while completeFrames < screenFrameBudget {
            guard let nextPayload = try nextFramedPayload() else { break }
            payloads += 1
            let bodyReceivedAt = nextPayload.receivedAt ?? drainStartedAt
            guard let completeWirePayload = try unwrapChunkedPayloadIfNeeded(
                nextPayload.payload,
                receivedAt: bodyReceivedAt,
                sbc2Chunks: &sbc2Chunks,
                sbc2Frames: &sbc2Frames
            ) else {
                continue
            }
            let payload = try decryptPayload(completeWirePayload, with: keys)
            let event = try decodePayload(payload, bodyReceivedAt: bodyReceivedAt)
            if case .screen = event {
                completeFrames += 1
            }
            events.append(event)
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
            hasCompletePayloadPending: hasCompleteFramedPayloadPending()
        )
    }

    private func decryptPayload(_ ciphertext: Data, with keys: SessionKeys) throws -> Data {
        let key = SymmetricKey(data: keys.receiveKey)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw RemoteDesktopError.streamingFailed(
                "LAN secure decrypt failed bytes=\(ciphertext.count) error=\(error.localizedDescription)"
            )
        }
    }

    private func decodePayload(
        _ payload: Data,
        bodyReceivedAt: Date
    ) throws -> LANRemoteSecureReceiveResult.Event {
        if let audioChunk = RemoteDesktopAudioChunkWire.decodeIfPresent(payload) {
            return .audio(audioChunk)
        }
        if let screenData = RemoteDesktopScreenFrameWire.decodeIfPresent(payload) {
            return .screen(screenData, payloadBytes: payload.count, bodyReceivedAt: bodyReceivedAt)
        }

        let message = try JSONDecoder().decode(RemoteMessage.self, from: payload)
        if message.type == .screenData {
            let screenData = try JSONDecoder().decode(ScreenData.self, from: message.payload)
            return .screen(screenData, payloadBytes: payload.count, bodyReceivedAt: bodyReceivedAt)
        }
        return .control(message, payloadBytes: payload.count, bodyReceivedAt: bodyReceivedAt)
    }

    private func unwrapChunkedPayloadIfNeeded(
        _ data: Data,
        receivedAt: Date,
        sbc2Chunks: inout Int,
        sbc2Frames: inout Int
    ) throws -> Data? {
        guard RemoteDesktopScreenFrameWire.startsWithChunkMagic(data) else {
            return data
        }

        guard let envelope = RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(data) else {
            throw RemoteDesktopError.streamingFailed("sbc2-chunk-decode-failed")
        }
        sbc2Chunks += 1

        switch screenChunkReassembler.append(envelope, now: receivedAt) {
        case .waiting:
            return nil
        case .complete(_, let payload):
            sbc2Frames += 1
            return payload
        case .failed(let reason, let frameId):
            throw RemoteDesktopError.streamingFailed(
                "sbc2-chunk-reassembly-failed reason=\(reason) frameId=\(frameId.map(String.init) ?? "-")"
            )
        }
    }

    private func nextFramedPayload() throws -> (payload: Data, receivedAt: Date?)? {
        guard receiveBuffer.count >= 4 else { return nil }
        let length = Int(receiveBuffer.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        if length <= 0 || length > maxWireMessageBytes {
            throw RemoteDesktopError.streamingFailed("消息长度异常：\(length) bytes")
        }

        let totalLength = 4 + length
        guard receiveBuffer.count >= totalLength else { return nil }
        let receivedAt = arrivalTime(forPayloadEndingAt: totalLength)
        let payloadStart = receiveBuffer.index(receiveBuffer.startIndex, offsetBy: 4)
        let payloadEnd = receiveBuffer.index(payloadStart, offsetBy: length)
        let payload = Data(receiveBuffer[payloadStart..<payloadEnd])
        receiveBuffer.removeSubrange(receiveBuffer.startIndex..<payloadEnd)
        consumeBytes(totalLength)
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
        guard receiveBuffer.count >= 4 else { return false }
        let length = Int(receiveBuffer.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        guard length > 0, length <= maxWireMessageBytes else { return true }
        return receiveBuffer.count >= 4 + length
    }
}
