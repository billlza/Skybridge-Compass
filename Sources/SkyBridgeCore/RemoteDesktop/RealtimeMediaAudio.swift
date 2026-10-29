import Foundation
import Dispatch
@preconcurrency import AVFoundation
import OSLog
import SkyBridgeOpus
import SkyBridgeRealtimeMedia

@available(macOS 14.0, *)
final class RemoteRealtimePCM16SubmissionPipe: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let hasSender: Bool
        let submittedBeforeAttach: UInt64
        let droppedBeforeAttach: UInt64
        let pendingBeforeAttach: Int
    }

    private enum SubmitAction {
        case yield(RemoteDesktopAudioChunkPayload)
        case buffered
        case closed
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let bufferedChunkLimit: Int
        private let replayBufferedOnAttach: Bool
        private var sender: RemoteRealtimeMediaAudioSender?
        private var pendingBeforeAttach: [RemoteDesktopAudioChunkPayload] = []
        private var closed = false
        private var submittedBeforeAttach: UInt64 = 0
        private var droppedBeforeAttach: UInt64 = 0

        init(
            sender: RemoteRealtimeMediaAudioSender?,
            bufferedChunkLimit: Int,
            replayBufferedOnAttach: Bool
        ) {
            self.sender = sender
            self.bufferedChunkLimit = max(1, bufferedChunkLimit)
            self.replayBufferedOnAttach = replayBufferedOnAttach
        }

        func submit(_ chunk: RemoteDesktopAudioChunkPayload) -> SubmitAction {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return .closed }
            guard sender == nil else { return .yield(chunk) }
            submittedBeforeAttach &+= 1
            pendingBeforeAttach.append(chunk)
            if pendingBeforeAttach.count > bufferedChunkLimit {
                let overflow = pendingBeforeAttach.count - bufferedChunkLimit
                pendingBeforeAttach.removeFirst(overflow)
                droppedBeforeAttach &+= UInt64(overflow)
            }
            return .buffered
        }

        func attach(_ sender: RemoteRealtimeMediaAudioSender) -> [RemoteDesktopAudioChunkPayload] {
            lock.lock()
            self.sender = sender
            let pending = replayBufferedOnAttach ? pendingBeforeAttach : []
            if !replayBufferedOnAttach {
                droppedBeforeAttach &+= UInt64(pendingBeforeAttach.count)
            }
            pendingBeforeAttach.removeAll(keepingCapacity: false)
            lock.unlock()
            return pending
        }

        func detach() {
            lock.lock()
            sender = nil
            lock.unlock()
        }

        func currentSender() -> RemoteRealtimeMediaAudioSender? {
            lock.lock()
            defer { lock.unlock() }
            return sender
        }

        func close() {
            lock.lock()
            closed = true
            droppedBeforeAttach &+= UInt64(pendingBeforeAttach.count)
            pendingBeforeAttach.removeAll(keepingCapacity: false)
            sender = nil
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                hasSender: sender != nil,
                submittedBeforeAttach: submittedBeforeAttach,
                droppedBeforeAttach: droppedBeforeAttach,
                pendingBeforeAttach: pendingBeforeAttach.count
            )
        }
    }

    private let continuation: AsyncStream<RemoteDesktopAudioChunkPayload>.Continuation
    private let drainTask: Task<Void, Never>
    private let state: State

    init(
        sender: RemoteRealtimeMediaAudioSender? = nil,
        bufferedChunkLimit: Int = 128,
        replayBufferedOnAttach: Bool = true
    ) {
        let state = State(
            sender: sender,
            bufferedChunkLimit: bufferedChunkLimit,
            replayBufferedOnAttach: replayBufferedOnAttach
        )
        var continuation: AsyncStream<RemoteDesktopAudioChunkPayload>.Continuation?
        let stream = AsyncStream<RemoteDesktopAudioChunkPayload>(
            bufferingPolicy: .bufferingNewest(max(1, bufferedChunkLimit))
        ) { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation!
        self.state = state
        self.drainTask = Task(priority: .utility) {
            for await chunk in stream {
                guard let sender = state.currentSender() else { continue }
                await sender.submitPCM16Chunk(chunk)
            }
        }
    }

    func submit(_ chunk: RemoteDesktopAudioChunkPayload) {
        switch state.submit(chunk) {
        case .yield(let chunk):
            continuation.yield(chunk)
        case .buffered, .closed:
            break
        }
    }

    func attach(sender: RemoteRealtimeMediaAudioSender) {
        let pending = state.attach(sender)
        for chunk in pending {
            continuation.yield(chunk)
        }
    }

    func detachSender() {
        state.detach()
    }

    func snapshot() -> Snapshot {
        state.snapshot()
    }

    func close() {
        state.close()
        continuation.finish()
        drainTask.cancel()
    }

    deinit {
        close()
    }
}

@available(macOS 14.0, *)
final class RemoteRealtimeSyntheticPCM16ToneSource: @unchecked Sendable {
    private let pipe: RemoteRealtimePCM16SubmissionPipe
    private let task: Task<Void, Never>

    init(sender: RemoteRealtimeMediaAudioSender, mode: SkyBridgeMediaAudioMode) {
        self.pipe = RemoteRealtimePCM16SubmissionPipe(sender: sender)
        self.task = Task(priority: .utility) { [pipe] in
            let profile = SkyBridgeMediaAudioProfile.profile(for: mode)
            let frameSamples = profile.samplesPerPacket
            let frameDurationNanos = UInt64(max(1, profile.frameDurationMs)) * 1_000_000
            var sequence: UInt64 = 0
            var phase = 0.0
            let frequency = 440.0
            let phaseStep = 2.0 * Double.pi * frequency / Double(profile.sampleRate)
            while !Task.isCancelled {
                let pcm = Self.makeToneFrame(
                    frameSamples: frameSamples,
                    channels: profile.channels,
                    phase: &phase,
                    phaseStep: phaseStep
                )
                let chunk = RemoteDesktopAudioChunkPayload(
                    sampleRate: profile.sampleRate,
                    channelCount: profile.channels,
                    frameCount: frameSamples,
                    sequenceNumber: sequence,
                    data: pcm
                )
                sequence &+= 1
                pipe.submit(chunk)
                do {
                    try await Task.sleep(nanoseconds: frameDurationNanos)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task.cancel()
        pipe.close()
    }

    deinit {
        stop()
    }

    private static func makeToneFrame(
        frameSamples: Int,
        channels: Int,
        phase: inout Double,
        phaseStep: Double
    ) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(frameSamples * channels)
        for _ in 0..<frameSamples {
            let amplitude = sin(phase) * 8_000.0
            let clamped = max(Double(Int16.min + 1), min(Double(Int16.max), amplitude))
            let value = Int16(clamped)
            for _ in 0..<channels {
                samples.append(value)
            }
            phase += phaseStep
            if phase > 2.0 * Double.pi {
                phase -= 2.0 * Double.pi
            }
        }
        return samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: samples.count * MemoryLayout<Int16>.size)
        }
    }
}

@available(macOS 14.0, *)
actor RemoteRealtimeMediaAudioSender {
    struct ContinuityState: Sendable, Equatable {
        let nextSequence: UInt64
        let nextTimestampSamples: UInt64
        let capturedPackets: UInt64
        let encodedPackets: UInt64
        let sentPackets: UInt64
        let droppedPackets: UInt64
    }

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RealtimeMediaAudio")
    private let sessionId: String
    private let diagnosticSessionId: String
    private let sessionIdHash: UInt64
    private let endpoint: SkyBridgeMediaEndpoint
    private let keys: SkyBridgeMediaDirectionKeys
    private let profile: SkyBridgeMediaAudioProfile
    private let mode: SkyBridgeMediaAudioMode
    private let interfaceBindingIdentity: SkyBridgeRealtimeMediaInterfaceBinding.Identity?
    private let transportEventHandler: (@Sendable (SkyBridgeRealtimeMediaTransportEvent) -> Void)?
    private let transport: SkyBridgeRealtimeMediaTransport
    private let encoder: SkyBridgeOpusEncoder
    private let frameBytes: Int
    private var currentRelayToken: String?
    private var relayBindingRefreshTask: Task<Void, Never>?
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
    private var redundantDatagramsSent: UInt64 = 0
    private var emptyPacingTicks: UInt64 = 0
    private var lastTelemetryCapturedPackets: UInt64 = 0
    private var lastTelemetryEncodedPackets: UInt64 = 0
    private var lastTelemetrySentPackets: UInt64 = 0
    private var lastTelemetryDroppedPackets: UInt64 = 0
    private var lastTelemetryEmptyPacingTicks: UInt64 = 0
    private var lastTelemetryLogAt = Date.distantPast
    private var lastSubmitDroppedLogAt = Date.distantPast
    private var didPrimeTelemetryWindow = false
    private var lastSendStartedAtNanos: UInt64?
    private var interSendSamplesMs: [Double] = []

    init(
        sessionId: String,
        diagnosticSessionId: String? = nil,
        endpoint: SkyBridgeMediaEndpoint,
        keys: SkyBridgeMediaDirectionKeys,
        mode: SkyBridgeMediaAudioMode,
        interfaceBinding: SkyBridgeRealtimeMediaInterfaceBinding? = nil,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy = .requireAcknowledgement,
        continuityState: ContinuityState? = nil,
        transport: SkyBridgeRealtimeMediaTransport? = nil,
        transportEventHandler: (@Sendable (SkyBridgeRealtimeMediaTransportEvent) -> Void)? = nil,
        transportTerminalFailureHandler: (@Sendable (Error) -> Void)? = nil
    ) throws {
        self.sessionId = sessionId
        self.diagnosticSessionId = diagnosticSessionId ?? sessionId
        self.sessionIdHash = SkyBridgeMediaPacketCodec.sessionIdHash(sessionId)
        self.endpoint = endpoint
        self.keys = keys
        self.mode = mode
        self.interfaceBindingIdentity = interfaceBinding?.identity
        self.profile = SkyBridgeMediaAudioProfile.profile(for: mode)
        self.transportEventHandler = transportEventHandler
        self.transport = transport ?? SkyBridgeUDPRealtimeMediaTransport(
            endpoint: endpoint,
            interfaceBinding: interfaceBinding,
            relayBindPolicy: relayBindPolicy,
            startEventHandler: transportEventHandler,
            terminalFailureHandler: transportTerminalFailureHandler
        )
        self.currentRelayToken = Self.normalizedRelayToken(endpoint.relayToken)
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
        if let continuityState {
            sequence = continuityState.nextSequence
            timestampSamples = continuityState.nextTimestampSamples
            capturedPackets = continuityState.capturedPackets
            encodedPackets = continuityState.encodedPackets
            sentPackets = continuityState.sentPackets
            droppedPackets = continuityState.droppedPackets
        }
    }

    func start() async throws {
        guard !started else { return }
        try await transport.start()
        started = true
        closed = false
        startDrainLoopIfNeeded()
        startRelayBindingRefreshLoopIfNeeded()
        logger.info(
            """
            🎧 PQC media audio sender ready: endpoint=\(self.endpoint.host, privacy: .public):\(self.endpoint.port, privacy: .public) \
            mode=\(self.mode.rawValue, privacy: .public) codec=opus audioPath=pqc-opus bitrate=\(self.profile.targetBitrate, privacy: .public)
            """
        )
    }

    func rebindRelayToken(
        _ relayToken: String,
        relayBindPolicy: SkyBridgeRealtimeMediaRelayBindPolicy = .optimisticAfterSend
    ) async throws {
        guard started, !closed else {
            throw URLError(.cannotConnectToHost)
        }
        guard let udpTransport = transport as? SkyBridgeUDPRealtimeMediaTransport else {
            throw SkyBridgeRealtimeMediaTransportError.relayBindRejected("transport_does_not_support_rebind")
        }
        let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        try await udpTransport.rebindRelayToken(
            token,
            relayBindPolicy: relayBindPolicy
        )
        currentRelayToken = token
        startRelayBindingRefreshLoopIfNeeded()
    }

    func matches(
        sessionId: String,
        endpoint: SkyBridgeMediaEndpoint,
        mode: SkyBridgeMediaAudioMode,
        interfaceBindingIdentity: SkyBridgeRealtimeMediaInterfaceBinding.Identity? = nil
    ) -> Bool {
        self.sessionId == sessionId
            && self.endpoint == endpoint
            && self.mode == mode
            && self.interfaceBindingIdentity == interfaceBindingIdentity
            && !closed
    }

    func telemetryTotals() -> (captured: UInt64, encoded: UInt64, sent: UInt64, dropped: UInt64) {
        (capturedPackets, encodedPackets, sentPackets, droppedPackets)
    }

    func continuityState() -> ContinuityState {
        ContinuityState(
            nextSequence: sequence,
            nextTimestampSamples: timestampSamples,
            capturedPackets: capturedPackets,
            encodedPackets: encodedPackets,
            sentPackets: sentPackets,
            droppedPackets: droppedPackets
        )
    }

    func diagnosticSnapshot() -> RealtimeMediaAudioSenderDiagnosticSnapshot {
        RealtimeMediaAudioSenderDiagnosticSnapshot(
            capturedPackets: capturedPackets,
            encodedPackets: encodedPackets,
            sentPackets: sentPackets,
            droppedPackets: droppedPackets,
            invalidDroppedPackets: invalidDroppedPackets,
            overflowDroppedPackets: overflowDroppedPackets,
            staleDroppedPackets: staleDroppedPackets,
            sendFailedPackets: sendFailedPackets,
            emptyPacingTicks: emptyPacingTicks,
            queuedFrames: pendingPCM.count / max(frameBytes, 1),
            queuedMs: (pendingPCM.count / max(frameBytes, 1)) * profile.frameDurationMs,
            mode: mode.rawValue
        )
    }

    func submitPCM16Chunk(_ chunk: RemoteDesktopAudioChunkPayload) async {
        guard !closed else {
            logSubmitDroppedIfNeeded(reason: "closed")
            return
        }
        guard started else {
            logSubmitDroppedIfNeeded(reason: "not-started")
            return
        }
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

    private func logSubmitDroppedIfNeeded(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSubmitDroppedLogAt) >= 1.0 else { return }
        lastSubmitDroppedLogAt = now
        RemoteControlSmokeStatusWriter.append(
            "audioTxSubmitDropped session=\(Self.sanitizeSmokeField(diagnosticSessionId)) " +
            "reason=\(Self.sanitizeSmokeField(reason)) started=\(started ? 1 : 0) closed=\(closed ? 1 : 0) " +
            "capturedTotal=\(capturedPackets) encodedTotal=\(encodedPackets) sentTotal=\(sentPackets) " +
            "droppedTotal=\(droppedPackets) endpoint=\(Self.sanitizeSmokeField(endpoint.host)):\(endpoint.port) " +
            "mode=\(Self.sanitizeSmokeField(mode.rawValue))"
        )
    }

    func close(reason: String = "unspecified") async {
        guard !closed else { return }
        closed = true
        drainTask?.cancel()
        drainTask = nil
        relayBindingRefreshTask?.cancel()
        relayBindingRefreshTask = nil
        let queuedFramesAtClose = pendingPCM.count / max(frameBytes, 1)
        let queuedMsAtClose = queuedFramesAtClose * profile.frameDurationMs
        pendingPCM.removeAll(keepingCapacity: false)
        await transport.stop()
        logger.info(
            """
            🛑 PQC media audio sender closed: sent=\(self.sentPackets, privacy: .public) \
            dropped=\(self.droppedPackets, privacy: .public) reason=\(reason, privacy: .public)
            """
        )
        RemoteControlSmokeStatusWriter.append(
            "audioTxSenderClose session=\(Self.sanitizeSmokeField(diagnosticSessionId)) " +
            "reason=\(Self.sanitizeSmokeField(reason)) capturedTotal=\(capturedPackets) " +
            "encodedTotal=\(encodedPackets) sentTotal=\(sentPackets) droppedTotal=\(droppedPackets) " +
            "invalidDrop=\(invalidDroppedPackets) overflowDrop=\(overflowDroppedPackets) " +
            "staleDrop=\(staleDroppedPackets) sendFail=\(sendFailedPackets) " +
            "queuedFrames=\(queuedFramesAtClose) queuedMs=\(queuedMsAtClose) " +
            "endpoint=\(Self.sanitizeSmokeField(endpoint.host)):\(endpoint.port) " +
            "mode=\(Self.sanitizeSmokeField(mode.rawValue))"
        )
        let diagnosticEvent = WebRTCMediaDiagnosticEvent(
            sessionId: diagnosticSessionId,
            kind: "audioTxSenderClosed",
            probable: reason,
            audioTxCapturedTotal: capturedPackets,
            audioTxEncodedTotal: encodedPackets,
            audioTxSentTotal: sentPackets,
            audioDropsTotal: droppedPackets,
            validationMode: mode.rawValue,
            failureReason: reason
        )
        WebRTCMediaDiagnosticWriter.append(diagnosticEvent)
    }

    private static func sanitizeSmokeField(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func startDrainLoopIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task(priority: .utility) { [weak self] in
            await self?.drainReadyPCMFrames()
        }
    }

    private func startRelayBindingRefreshLoopIfNeeded() {
        guard relayBindingRefreshTask == nil,
              currentRelayToken != nil,
              transport is SkyBridgeUDPRealtimeMediaTransport else {
            return
        }
        relayBindingRefreshTask = Task(priority: .utility) { [weak self] in
            await self?.refreshRelayBindingUntilClosed()
        }
    }

    private func refreshRelayBindingUntilClosed() async {
        defer { relayBindingRefreshTask = nil }
        while !Task.isCancelled, !closed {
            do {
                try await Task.sleep(nanoseconds: relayBindingRefreshIntervalNanos)
            } catch {
                return
            }
            guard !Task.isCancelled, !closed,
                  let token = currentRelayToken,
                  let udpTransport = transport as? SkyBridgeUDPRealtimeMediaTransport else {
                continue
            }
            do {
                try await udpTransport.refreshRelayBinding(token)
            } catch {
                logger.debug("PQC media audio relay bind keepalive failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func drainReadyPCMFrames() async {
        defer { drainTask = nil }
        let frameIntervalNanos = UInt64(max(1, profile.frameDurationMs)) * 1_000_000
        var nextDeadline = DispatchTime.now().uptimeNanoseconds
        while !Task.isCancelled, !closed {
            let now = DispatchTime.now().uptimeNanoseconds
            if nextDeadline > now {
                do {
                    try await Task.sleep(nanoseconds: nextDeadline - now)
                } catch {
                    return
                }
                guard !Task.isCancelled, !closed else { return }
            }
            let wokeAt = DispatchTime.now().uptimeNanoseconds
            let overdueNanos = wokeAt > nextDeadline ? wokeAt - nextDeadline : 0
            let dueFrames = min(
                senderCatchUpFrameLimit,
                max(1, Int(overdueNanos / frameIntervalNanos) + 1)
            )
            let pendingFrames = pendingPCM.count / frameBytes
            let backlogCatchUpFrames = pendingFrames > senderCatchUpBacklogFrameTarget
                ? min(senderCatchUpFrameLimit, pendingFrames - senderCatchUpBacklogFrameTarget)
                : 0
            let frameBudget = max(dueFrames, backlogCatchUpFrames)
            var sentOrAttemptedFrames = 0
            for _ in 0..<frameBudget {
                guard !Task.isCancelled, !closed else { return }
                guard let frame = dequeueNextPCMFrame() else { break }
                sentOrAttemptedFrames += 1
                await encodeAndSendFrame(frame)
            }
            if sentOrAttemptedFrames == 0 {
                emptyPacingTicks &+= 1
            }
            let afterSend = DispatchTime.now().uptimeNanoseconds
            nextDeadline = max(
                nextDeadline &+ UInt64(dueFrames) * frameIntervalNanos,
                afterSend &+ frameIntervalNanos
            )
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
                wireDirection: keys.wireDirection,
                transcriptPrefix: keys.transcriptPrefix,
                keyEpoch: keys.epoch,
                nonceCounter: reservedNonceCounter
            )
            let packet = try SkyBridgeMediaPacketCodec.seal(
                payload: opusPayload,
                header: header,
                keys: keys
            )
            let successfulDatagrams = try await sendPacketWithRedundancy(packet)
            sentPackets &+= 1
            if successfulDatagrams > 1 {
                redundantDatagramsSent &+= UInt64(successfulDatagrams - 1)
            }
        } catch {
            droppedPackets &+= 1
            sendFailedPackets &+= 1
            logger.debug("PQC media audio send dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendPacketWithRedundancy(_ packet: Data) async throws -> Int {
        let copyCount = redundantDatagramCopyCount
        var successfulDatagrams = 0
        var firstError: Error?
        for copyIndex in 0..<copyCount {
            if copyIndex > 0 {
                try await Task.sleep(nanoseconds: redundantDatagramStaggerNanos)
            }
            do {
                try await transport.send(packet)
                successfulDatagrams += 1
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        guard successfulDatagrams > 0 else {
            throw firstError ?? URLError(.cannotConnectToHost)
        }
        return successfulDatagrams
    }

    private var redundantDatagramCopyCount: Int {
        switch mode {
        case .lowLatency:
            return 2
        case .highFidelity:
            return 1
        }
    }

    private var redundantDatagramStaggerNanos: UInt64 {
        let staggerMs = max(1, min(5, profile.frameDurationMs / 4))
        return UInt64(staggerMs) * 1_000_000
    }

    private var relayBindingRefreshIntervalNanos: UInt64 {
        10_000_000_000
    }

    private static func normalizedRelayToken(_ raw: String?) -> String? {
        guard let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
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
        let probable = Self.txProbable(
            captureWindow: captureWindow,
            encodeWindow: encodeWindow,
            sendWindow: sendWindow,
            droppedWindow: droppedWindow,
            capturedTotal: capturedPackets
        )
        if didPrimeTelemetryWindow {
            let diagnosticEvent = WebRTCMediaDiagnosticEvent(
                sessionId: diagnosticSessionId,
                kind: "audioTxRolling",
                probable: probable,
                audioTxCaptured: captureWindow,
                audioTxEncoded: encodeWindow,
                audioTxSent: sendWindow,
                audioDrops: droppedWindow,
                audioTxCapturedTotal: capturedPackets,
                audioTxEncodedTotal: encodedPackets,
                audioTxSentTotal: sentPackets,
                audioDropsTotal: droppedPackets,
                validationMode: mode.rawValue
            )
            Task.detached(priority: .utility) {
                WebRTCMediaDiagnosticWriter.append(diagnosticEvent)
            }
        } else {
            didPrimeTelemetryWindow = true
        }
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
            redundantDatagrams=\(self.redundantDatagramsSent, privacy: .public) redundantCopies=\(self.redundantDatagramCopyCount, privacy: .public) \
            codec=opus activeCodec=opus audioPath=pqc-opus mode=\(self.mode.rawValue, privacy: .public)
            """
        )
    }

    private static func txProbable(
        captureWindow: UInt64,
        encodeWindow: UInt64,
        sendWindow: UInt64,
        droppedWindow: UInt64,
        capturedTotal: UInt64
    ) -> String {
        if captureWindow == 0 {
            return capturedTotal == 0 ? "capture-unavailable-or-silent" : "capture-stalled-or-silent"
        }
        if encodeWindow == 0 {
            return "encode-stalled"
        }
        if sendWindow == 0 {
            return "relay-send-not-draining"
        }
        if droppedWindow > 0 {
            return "audio-tx-dropping"
        }
        return "sending"
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
        let profileLimit = profile.jitterMaxMs / profile.frameDurationMs
        switch mode {
        case .lowLatency:
            return max(128, profileLimit)
        case .highFidelity:
            return max(4, profileLimit)
        }
    }

    private var senderCatchUpFrameLimit: Int {
        switch mode {
        case .lowLatency:
            return max(4, min(8, maxPendingPCMFrameCount / 16))
        case .highFidelity:
            return max(2, min(4, maxPendingPCMFrameCount / 2))
        }
    }

    private var senderCatchUpBacklogFrameTarget: Int {
        switch mode {
        case .lowLatency:
            return 4
        case .highFidelity:
            return 2
        }
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
    private enum AuthenticatedSourceDecision: Equatable {
        case accepted
        case migrated
    }

    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RealtimeMediaAudio")
    private let diagnosticSessionId: String
    private let sessionIdHash: UInt64
    private let keys: SkyBridgeMediaDirectionKeys
    private let profile: SkyBridgeMediaAudioProfile
    private let mode: SkyBridgeMediaAudioMode
    nonisolated private let lifecycle = SkyBridgeRealtimeMediaReceiverLifecycle()
    private var didClose = false
    private let decoder: SkyBridgeOpusDecoder
    private var replayWindow = SkyBridgeMediaReplayWindow()
    private var receivedPackets: UInt64 = 0
    private var decodedPackets: UInt64 = 0
    private var playedPackets: UInt64 = 0
    private var rejectedPackets: UInt64 = 0
    private var sourceRejectedPackets: UInt64 = 0
    private var sourceMigratedPackets: UInt64 = 0
    private var plcFrames: UInt64 = 0
    private var lastTelemetryLogAt = Date.distantPast
    private var lockedRemoteEndpoint: SkyBridgeMediaEndpoint?
    private var lastSourceMismatchLogAt = Date.distantPast
    private var lastSourceMigrationLogAt = Date.distantPast

    init(
        sessionId: String,
        keys: SkyBridgeMediaDirectionKeys,
        mode: SkyBridgeMediaAudioMode
    ) throws {
        self.diagnosticSessionId = sessionId
        self.sessionIdHash = SkyBridgeMediaPacketCodec.sessionIdHash(sessionId)
        self.keys = keys
        self.mode = mode
        self.profile = SkyBridgeMediaAudioProfile.profile(for: mode)
        self.decoder = try SkyBridgeOpusDecoder(
            sampleRate: profile.sampleRate,
            channels: profile.channels,
            frameDurationMs: profile.frameDurationMs
        )
    }

    func handle(packet: Data, latestVideoTimestamp: TimeInterval?) async {
        await handle(
            datagram: SkyBridgeMediaReceivedDatagram(packet: packet, remoteEndpoint: nil),
            latestVideoTimestamp: latestVideoTimestamp
        )
    }

    func handle(datagram: SkyBridgeMediaReceivedDatagram, latestVideoTimestamp: TimeInterval?) async {
        guard lifecycle.isActive else { return }
        do {
            let opened = try SkyBridgeMediaPacketCodec.open(
                packet: datagram.packet,
                keys: keys,
                expectedSessionIdHash: sessionIdHash,
                expectedStreamId: SkyBridgeRealtimeMediaConstants.defaultStreamId
            )
            guard let sourceDecision = acceptAuthenticatedSource(
                datagram.remoteEndpoint,
                sequence: opened.header.sequence
            ) else {
                sourceRejectedPackets &+= 1
                rejectedPackets &+= 1
                logTelemetryIfNeeded()
                return
            }
            if sourceDecision == .migrated {
                replayWindow = SkyBridgeMediaReplayWindow()
                sourceMigratedPackets &+= 1
            }
            guard replayWindow.accept(sequence: opened.header.sequence) else {
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
            let lifecycle = self.lifecycle
            guard lifecycle.isActive else { return }
            let didPlay = await MainActor.run { () -> Bool in
                guard lifecycle.isActive else { return false }
                do {
                    guard try AudioRedirectionManager.shared.enable(for: lifecycle) else {
                        return false
                    }
                    guard AudioRedirectionManager.shared.updateRemoteVideoTimestamp(
                        latestVideoTimestamp,
                        ifOwnedBy: lifecycle
                    ) else {
                        return false
                    }
                    return AudioRedirectionManager.shared.playRemoteAudioChunk(
                        payload,
                        ifOwnedBy: lifecycle
                    )
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

    func close(reason: String = "unspecified") async {
        guard !didClose else { return }
        didClose = true
        lifecycle.retire()
        _ = await MainActor.run {
            AudioRedirectionManager.shared.disable(ifOwnedBy: lifecycle)
        }
        logger.info(
            """
            🛑 PQC media audio receiver closed: recv=\(self.receivedPackets, privacy: .public) \
            decode=\(self.decodedPackets, privacy: .public) play=\(self.playedPackets, privacy: .public) \
            rejected=\(self.rejectedPackets, privacy: .public) reason=\(reason, privacy: .public)
            """
        )
        let diagnosticEvent = WebRTCMediaDiagnosticEvent(
            sessionId: diagnosticSessionId,
            kind: "audioRxReceiverClosed",
            probable: receivedPackets == 0 ? "audio-rx-no-positive-evidence" : nil,
            audioRxRecv: receivedPackets,
            audioRxDecoded: decodedPackets,
            audioRxPlayed: playedPackets,
            audioRxRejected: rejectedPackets,
            validationMode: mode.rawValue,
            failureReason: reason
        )
        WebRTCMediaDiagnosticWriter.append(diagnosticEvent)
    }

    nonisolated func retire() {
        lifecycle.retire()
    }

    func diagnosticSnapshot() -> RealtimeMediaAudioReceiverDiagnosticSnapshot {
        RealtimeMediaAudioReceiverDiagnosticSnapshot(
            receivedPackets: receivedPackets,
            decodedPackets: decodedPackets,
            playedPackets: playedPackets,
            rejectedPackets: rejectedPackets,
            plcFrames: plcFrames,
            mode: mode.rawValue
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
            sourceReject=\(self.sourceRejectedPackets, privacy: .public) sourceMigrate=\(self.sourceMigratedPackets, privacy: .public) \
            codec=opus activeCodec=opus audioPath=pqc-opus-via-audio-redirection mode=\(self.mode.rawValue, privacy: .public)
            """
        )
    }

    private func acceptAuthenticatedSource(
        _ remoteEndpoint: SkyBridgeMediaEndpoint?,
        sequence: UInt64
    ) -> AuthenticatedSourceDecision? {
        guard let remoteEndpoint else {
            return .accepted
        }
        if let lockedRemoteEndpoint {
            if Self.normalized(lockedRemoteEndpoint) == Self.normalized(remoteEndpoint) {
                return .accepted
            }
            guard Self.normalizedHost(lockedRemoteEndpoint) == Self.normalizedHost(remoteEndpoint) else {
                logSourceMismatch(locked: lockedRemoteEndpoint, incoming: remoteEndpoint)
                return nil
            }
            self.lockedRemoteEndpoint = remoteEndpoint
            logSourceMigration(from: lockedRemoteEndpoint, to: remoteEndpoint, sequence: sequence)
            return .migrated
        }
        lockedRemoteEndpoint = remoteEndpoint
        let normalized = Self.normalized(remoteEndpoint)
        logger.info(
            "🎧 PQC media audio source locked: host=\(normalized.host, privacy: .public) port=\(normalized.port, privacy: .public)"
        )
        return .accepted
    }

    private func logSourceMismatch(locked: SkyBridgeMediaEndpoint, incoming: SkyBridgeMediaEndpoint) {
        let now = Date()
        guard now.timeIntervalSince(lastSourceMismatchLogAt) >= 2 else { return }
        lastSourceMismatchLogAt = now
        let lockedNormalized = Self.normalized(locked)
        let incomingNormalized = Self.normalized(incoming)
        logger.debug(
            "PQC media audio rejected unexpected source: locked=\(lockedNormalized.host, privacy: .public):\(lockedNormalized.port, privacy: .public) incoming=\(incomingNormalized.host, privacy: .public):\(incomingNormalized.port, privacy: .public)"
        )
    }

    private func logSourceMigration(from locked: SkyBridgeMediaEndpoint, to incoming: SkyBridgeMediaEndpoint, sequence: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastSourceMigrationLogAt) >= 2 else { return }
        lastSourceMigrationLogAt = now
        let lockedNormalized = Self.normalized(locked)
        let incomingNormalized = Self.normalized(incoming)
        logger.info(
            "🎧 PQC media audio source migrated: old=\(lockedNormalized.host, privacy: .public):\(lockedNormalized.port, privacy: .public) incoming=\(incomingNormalized.host, privacy: .public):\(incomingNormalized.port, privacy: .public) seq=\(sequence, privacy: .public)"
        )
    }

    private static func normalized(_ endpoint: SkyBridgeMediaEndpoint) -> SkyBridgeMediaEndpoint {
        SkyBridgeMediaEndpoint(
            host: normalizedHost(endpoint),
            port: endpoint.port,
            relayToken: nil,
            expiresAt: nil
        )
    }

    private static func normalizedHost(_ endpoint: SkyBridgeMediaEndpoint) -> String {
        endpoint.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
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
