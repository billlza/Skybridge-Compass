import Foundation
import Dispatch
@preconcurrency import AVFoundation
import OSLog
import SkyBridgeOpus
import SkyBridgeRealtimeMedia

@available(macOS 14.0, *)
final class RemoteRealtimePCM16SubmissionPipe: @unchecked Sendable {
    private let continuation: AsyncStream<RemoteDesktopAudioChunkPayload>.Continuation
    private let drainTask: Task<Void, Never>

    init(sender: RemoteRealtimeMediaAudioSender, bufferedChunkLimit: Int = 24) {
        var continuation: AsyncStream<RemoteDesktopAudioChunkPayload>.Continuation?
        let stream = AsyncStream<RemoteDesktopAudioChunkPayload>(
            bufferingPolicy: .bufferingNewest(max(1, bufferedChunkLimit))
        ) { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation!
        self.drainTask = Task(priority: .utility) {
            for await chunk in stream {
                await sender.submitPCM16Chunk(chunk)
            }
        }
    }

    func submit(_ chunk: RemoteDesktopAudioChunkPayload) {
        continuation.yield(chunk)
    }

    func close() {
        continuation.finish()
        drainTask.cancel()
    }

    deinit {
        close()
    }
}

@available(macOS 14.0, *)
actor RemoteRealtimeMediaAudioSender {
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RealtimeMediaAudio")
    private let sessionId: String
    private let sessionIdHash: UInt64
    private let endpoint: SkyBridgeMediaEndpoint
    private let keys: SkyBridgeMediaDirectionKeys
    private let profile: SkyBridgeMediaAudioProfile
    private let mode: SkyBridgeMediaAudioMode
    private let transport: SkyBridgeRealtimeMediaTransport
    private let encoder: SkyBridgeOpusEncoder
    private let frameBytes: Int
    private var pendingPCM = Data()
    private var drainTask: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var timestampSamples: UInt64 = 0
    private var nonceCounter: UInt64 = UInt64.random(in: 1...(UInt64.max / 2))
    private var started = false
    private var closed = false
    private var capturedPackets: UInt64 = 0
    private var encodedPackets: UInt64 = 0
    private var sentPackets: UInt64 = 0
    private var droppedPackets: UInt64 = 0
    private var invalidDroppedPackets: UInt64 = 0
    private var overflowDroppedPackets: UInt64 = 0
    private var staleDroppedPackets: UInt64 = 0
    private var sendFailedPackets: UInt64 = 0
    private var emptyPacingTicks: UInt64 = 0
    private var lastTelemetryCapturedPackets: UInt64 = 0
    private var lastTelemetryEncodedPackets: UInt64 = 0
    private var lastTelemetrySentPackets: UInt64 = 0
    private var lastTelemetryDroppedPackets: UInt64 = 0
    private var lastTelemetryEmptyPacingTicks: UInt64 = 0
    private var lastTelemetryLogAt = Date.distantPast
    private var lastSendStartedAtNanos: UInt64?
    private var interSendSamplesMs: [Double] = []

    init(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        keys: SkyBridgeMediaDirectionKeys,
        mode: SkyBridgeMediaAudioMode,
        transport: SkyBridgeRealtimeMediaTransport? = nil
    ) throws {
        self.sessionId = sessionId
        self.sessionIdHash = SkyBridgeMediaPacketCodec.sessionIdHash(sessionId)
        self.endpoint = endpoint
        self.keys = keys
        self.mode = mode
        self.profile = SkyBridgeMediaAudioProfile.profile(for: mode)
        self.transport = transport ?? SkyBridgeUDPRealtimeMediaTransport(endpoint: endpoint)
        self.encoder = try SkyBridgeOpusEncoder(
            configuration: SkyBridgeOpusConfiguration(
                sampleRate: profile.sampleRate,
                channels: profile.channels,
                frameDurationMs: profile.frameDurationMs,
                bitrate: profile.targetBitrate,
                complexity: profile.opusComplexity,
                expectedPacketLossPercent: 3,
                inBandFECEnabled: profile.inBandFECEnabled,
                dtxEnabled: false,
                application: mode == .lowLatency ? .lowDelay : .audio,
                signal: .music
            )
        )
        self.frameBytes = profile.samplesPerPacket * profile.channels * MemoryLayout<Int16>.size
    }

    func start() async throws {
        guard !started else { return }
        try await transport.start()
        started = true
        closed = false
        startDrainLoopIfNeeded()
        logger.info(
            """
            🎧 PQC media audio sender ready: endpoint=\(self.endpoint.host, privacy: .public):\(self.endpoint.port, privacy: .public) \
            mode=\(self.mode.rawValue, privacy: .public) codec=opus audioPath=pqc-opus bitrate=\(self.profile.targetBitrate, privacy: .public)
            """
        )
    }

    func matches(sessionId: String, endpoint: SkyBridgeMediaEndpoint, mode: SkyBridgeMediaAudioMode) -> Bool {
        self.sessionId == sessionId && self.endpoint == endpoint && self.mode == mode && !closed
    }

    func telemetryTotals() -> (captured: UInt64, encoded: UInt64, sent: UInt64, dropped: UInt64) {
        (capturedPackets, encodedPackets, sentPackets, droppedPackets)
    }

    func submitPCM16Chunk(_ chunk: RemoteDesktopAudioChunkPayload) async {
        guard !closed, started else { return }
        guard chunk.encoding == .pcmS16LE,
              chunk.sampleRate == profile.sampleRate,
              chunk.channelCount == profile.channels,
              chunk.data.count % (profile.channels * MemoryLayout<Int16>.size) == 0 else {
            droppedPackets &+= 1
            invalidDroppedPackets &+= 1
            logTelemetryIfNeeded()
            return
        }

        capturedPackets &+= 1
        pendingPCM.append(chunk.data)
        trimPendingPCMIfNeeded()
        logTelemetryIfNeeded()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        drainTask?.cancel()
        drainTask = nil
        pendingPCM.removeAll(keepingCapacity: false)
        await transport.stop()
        logger.info(
            """
            🛑 PQC media audio sender closed: sent=\(self.sentPackets, privacy: .public) \
            dropped=\(self.droppedPackets, privacy: .public)
            """
        )
    }

    private func startDrainLoopIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task(priority: .utility) { [weak self] in
            await self?.drainReadyPCMFrames()
        }
    }

    private func drainReadyPCMFrames() async {
        defer { drainTask = nil }
        let frameIntervalNanos = UInt64(max(1, profile.frameDurationMs)) * 1_000_000
        let maxPacingLagNanos = UInt64(senderPacingResetFrameLimit) * frameIntervalNanos
        var nextDeadline = DispatchTime.now().uptimeNanoseconds
        while !Task.isCancelled, !closed {
            let now = DispatchTime.now().uptimeNanoseconds
            if nextDeadline > now {
                try? await Task.sleep(nanoseconds: nextDeadline - now)
                guard !Task.isCancelled, !closed else { return }
            } else if now - nextDeadline > maxPacingLagNanos {
                let staleFrames = Int((now - nextDeadline) / frameIntervalNanos)
                dropPendingPCMFrames(staleFrames)
                nextDeadline = now
            }
            if let frame = dequeueNextPCMFrame() {
                await encodeAndSendFrame(frame)
            } else {
                emptyPacingTicks &+= 1
            }
            nextDeadline &+= frameIntervalNanos
            logTelemetryIfNeeded()
        }
    }

    private func dequeueNextPCMFrame() -> Data? {
        guard pendingPCM.count >= frameBytes else { return nil }
        let frame = Data(pendingPCM.prefix(frameBytes))
        pendingPCM.removeSubrange(0..<frameBytes)
        return frame
    }

    private func trimPendingPCMIfNeeded() {
        let maxBytes = maxPendingPCMFrameCount * frameBytes
        guard pendingPCM.count > maxBytes else { return }
        let overflowBytes = pendingPCM.count - maxBytes
        let framesToDrop = max(1, (overflowBytes + frameBytes - 1) / frameBytes)
        let bytesToDrop = min(framesToDrop * frameBytes, pendingPCM.count)
        pendingPCM.removeSubrange(0..<bytesToDrop)
        droppedPackets &+= UInt64(framesToDrop)
        overflowDroppedPackets &+= UInt64(framesToDrop)
    }

    private func dropPendingPCMFrames(_ frameCount: Int) {
        let availableFrames = pendingPCM.count / frameBytes
        guard availableFrames > 1 else { return }
        let framesToDrop = max(0, min(frameCount, availableFrames - 1))
        guard framesToDrop > 0 else { return }
        pendingPCM.removeSubrange(0..<(framesToDrop * frameBytes))
        droppedPackets &+= UInt64(framesToDrop)
        staleDroppedPackets &+= UInt64(framesToDrop)
    }

    private func encodeAndSendFrame(_ pcmFrame: Data) async {
        do {
            recordSendStartInterval()
            let opusPayload = try encoder.encode(
                pcm16Interleaved: pcmFrame,
                maxPacketBytes: SkyBridgeMediaPacketCodec.maxPayloadBytes
            )
            encodedPackets &+= 1
            let reservedSequence = sequence
            let reservedTimestampSamples = timestampSamples
            let reservedNonceCounter = nonceCounter
            sequence &+= 1
            timestampSamples &+= UInt64(profile.samplesPerPacket)
            nonceCounter &+= 1
            let header = SkyBridgeMediaPacketHeader(
                sessionIdHash: sessionIdHash,
                sequence: reservedSequence,
                timestampSamples: reservedTimestampSamples,
                flags: mediaFlags(for: mode),
                keyEpoch: keys.epoch,
                nonceCounter: reservedNonceCounter
            )
            let packet = try SkyBridgeMediaPacketCodec.seal(
                payload: opusPayload,
                header: header,
                keys: keys
            )
            try await transport.send(packet)
            sentPackets &+= 1
        } catch {
            droppedPackets &+= 1
            sendFailedPackets &+= 1
            logger.debug("PQC media audio send dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordSendStartInterval() {
        let now = DispatchTime.now().uptimeNanoseconds
        if let lastSendStartedAtNanos {
            let intervalMs = Double(now - lastSendStartedAtNanos) / 1_000_000
            interSendSamplesMs.append(intervalMs)
            if interSendSamplesMs.count > 512 {
                interSendSamplesMs.removeFirst(interSendSamplesMs.count - 512)
            }
        }
        lastSendStartedAtNanos = now
    }

    private func logTelemetryIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastTelemetryLogAt) >= 5 else { return }
        lastTelemetryLogAt = now
        let captureWindow = capturedPackets &- lastTelemetryCapturedPackets
        let encodeWindow = encodedPackets &- lastTelemetryEncodedPackets
        let sendWindow = sentPackets &- lastTelemetrySentPackets
        let droppedWindow = droppedPackets &- lastTelemetryDroppedPackets
        let emptyTicksWindow = emptyPacingTicks &- lastTelemetryEmptyPacingTicks
        lastTelemetryCapturedPackets = capturedPackets
        lastTelemetryEncodedPackets = encodedPackets
        lastTelemetrySentPackets = sentPackets
        lastTelemetryDroppedPackets = droppedPackets
        lastTelemetryEmptyPacingTicks = emptyPacingTicks
        let intervalStats = Self.intervalStats(interSendSamplesMs)
        interSendSamplesMs.removeAll(keepingCapacity: true)
        logger.info(
            """
            📈 PQC media audio tx: capture=\(captureWindow, privacy: .public) encode=\(encodeWindow, privacy: .public) \
            send=\(sendWindow, privacy: .public) dropped=\(droppedWindow, privacy: .public) \
            captureTotal=\(self.capturedPackets, privacy: .public) sendTotal=\(self.sentPackets, privacy: .public) \
            queued=\(self.pendingPCM.count / max(self.frameBytes, 1), privacy: .public) \
            queuedMs=\((self.pendingPCM.count / max(self.frameBytes, 1)) * self.profile.frameDurationMs, privacy: .public) \
            interSendP50Ms=\(intervalStats.p50, privacy: .public) interSendP95Ms=\(intervalStats.p95, privacy: .public) \
            interSendMaxMs=\(intervalStats.max, privacy: .public) emptyTicks=\(emptyTicksWindow, privacy: .public) \
            invalidDrop=\(self.invalidDroppedPackets, privacy: .public) overflowDrop=\(self.overflowDroppedPackets, privacy: .public) \
            staleDrop=\(self.staleDroppedPackets, privacy: .public) sendFail=\(self.sendFailedPackets, privacy: .public) \
            codec=opus activeCodec=opus audioPath=pqc-opus mode=\(self.mode.rawValue, privacy: .public)
            """
        )
    }

    private static func intervalStats(_ samples: [Double]) -> (p50: String, p95: String, max: String) {
        guard !samples.isEmpty else { return ("-", "-", "-") }
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> String {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
            return String(format: "%.1f", sorted[index])
        }
        return (
            p50: percentile(0.50),
            p95: percentile(0.95),
            max: String(format: "%.1f", sorted.last ?? 0)
        )
    }

    private var maxPendingPCMFrameCount: Int {
        max(4, profile.jitterMaxMs / profile.frameDurationMs)
    }

    private var senderPacingResetFrameLimit: Int {
        max(2, min(6, maxPendingPCMFrameCount / 2))
    }

    private func mediaFlags(for mode: SkyBridgeMediaAudioMode) -> UInt16 {
        switch mode {
        case .lowLatency:
            return 0x0001
        case .highFidelity:
            return 0x0002
        }
    }
}

@available(macOS 14.0, *)
actor RemoteRealtimeMediaAudioReceiver {
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RealtimeMediaAudio")
    private let sessionIdHash: UInt64
    private let keys: SkyBridgeMediaDirectionKeys
    private let profile: SkyBridgeMediaAudioProfile
    private let mode: SkyBridgeMediaAudioMode
    private let audioSessionId: UUID
    private let decoder: SkyBridgeOpusDecoder
    private var replayWindow = SkyBridgeMediaReplayWindow()
    private var receivedPackets: UInt64 = 0
    private var decodedPackets: UInt64 = 0
    private var playedPackets: UInt64 = 0
    private var rejectedPackets: UInt64 = 0
    private var plcFrames: UInt64 = 0
    private var lastTelemetryLogAt = Date.distantPast

    init(
        sessionId: String,
        keys: SkyBridgeMediaDirectionKeys,
        mode: SkyBridgeMediaAudioMode,
        audioSessionId: UUID
    ) throws {
        self.sessionIdHash = SkyBridgeMediaPacketCodec.sessionIdHash(sessionId)
        self.keys = keys
        self.mode = mode
        self.profile = SkyBridgeMediaAudioProfile.profile(for: mode)
        self.audioSessionId = audioSessionId
        self.decoder = try SkyBridgeOpusDecoder(
            sampleRate: profile.sampleRate,
            channels: profile.channels,
            frameDurationMs: profile.frameDurationMs
        )
    }

    func handle(packet: Data, latestVideoTimestamp: TimeInterval?) async {
        do {
            let opened = try SkyBridgeMediaPacketCodec.open(packet: packet, keys: keys)
            guard opened.header.sessionIdHash == sessionIdHash,
                  replayWindow.accept(sequence: opened.header.sequence) else {
                rejectedPackets &+= 1
                logTelemetryIfNeeded()
                return
            }
            receivedPackets &+= 1
            let samples = try decoder.decode(
                packet: opened.payload,
                frameSamplesPerChannel: profile.samplesPerPacket
            )
            decodedPackets &+= 1
            let payload = RemoteDesktopAudioChunkPayload(
                encoding: .pcmS16LE,
                sampleRate: profile.sampleRate,
                channelCount: profile.channels,
                frameCount: samples.count / profile.channels,
                sequenceNumber: opened.header.sequence,
                sentAt: Date().timeIntervalSince1970,
                data: Self.data(from: samples)
            )
            let didPlay = await MainActor.run { () -> Bool in
                do {
                    try AudioRedirectionManager.shared.enable(for: audioSessionId)
                    AudioRedirectionManager.shared.updateRemoteVideoTimestamp(latestVideoTimestamp)
                    AudioRedirectionManager.shared.playRemoteAudioChunk(payload)
                    return true
                } catch {
                    logger.debug("PQC media audio playback unavailable: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            if didPlay {
                playedPackets &+= 1
            } else {
                rejectedPackets &+= 1
            }
        } catch {
            rejectedPackets &+= 1
            logger.debug("PQC media audio packet rejected: \(error.localizedDescription, privacy: .public)")
        }
        logTelemetryIfNeeded()
    }

    func close() async {
        await MainActor.run {
            AudioRedirectionManager.shared.disable()
        }
        logger.info(
            """
            🛑 PQC media audio receiver closed: recv=\(self.receivedPackets, privacy: .public) \
            decode=\(self.decodedPackets, privacy: .public) play=\(self.playedPackets, privacy: .public) \
            rejected=\(self.rejectedPackets, privacy: .public)
            """
        )
    }

    private func logTelemetryIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastTelemetryLogAt) >= 5 else { return }
        lastTelemetryLogAt = now
        logger.info(
            """
            📈 PQC media audio rx: recv=\(self.receivedPackets, privacy: .public) \
            decode=\(self.decodedPackets, privacy: .public) play=\(self.playedPackets, privacy: .public) \
            rejected=\(self.rejectedPackets, privacy: .public) plc=\(self.plcFrames, privacy: .public) \
            codec=opus activeCodec=opus audioPath=pqc-opus-via-audio-redirection mode=\(self.mode.rawValue, privacy: .public)
            """
        )
    }

    private static func data(from samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(
                bytes: baseAddress,
                count: samples.count * MemoryLayout<Int16>.size
            )
        }
    }
}
