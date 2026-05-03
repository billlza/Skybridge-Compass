//
// RealtimeMediaAudio.swift
// SkyBridgeCompassiOS
//
// PQC media-plane audio receive path for iOS viewer.
//

import Foundation
import Dispatch
import AVFoundation
import SkyBridgeOpus
import SkyBridgeRealtimeMedia

struct RemoteRealtimeMediaKeySnapshot: Sendable, Equatable {
    let sessionId: String
    let sendKey: Data
    let receiveKey: Data
    let transcriptHash: Data
    let mediaAdmissionToken: String?
}

actor IOSRealtimeMediaAudioPlayer {
    static let shared = IOSRealtimeMediaAudioPlayer()

    struct PlaybackTelemetrySnapshot: Sendable {
        let queuedMs: Double
        let capacityMs: Double
        let underflowEvents: UInt64
        let underflowFrames: UInt64
        let overflowEvents: UInt64
        let overflowFrames: UInt64
        let appendedFrames: UInt64
        let renderedFrames: UInt64
        let rebufferEvents: UInt64
        let startupSilenceFrames: UInt64
        let targetQueuedMs: Double
        let isPrimed: Bool
        let isEngineRunning: Bool
        let audioPath: String
    }

    private enum PlaybackState: String {
        case stopped
        case buffering
        case running
    }

    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var renderBuffer: RealtimePCMRenderBuffer?
    private var activeProfileSignature: String?
    private var targetQueuedFrames: Int = 0
    private var hardQueuedFrames: Int = 0
    private var playbackState: PlaybackState = .stopped
    private var lastDropLogAt = Date.distantPast

    private init() {}

    func playPCM16(
        _ data: Data,
        frameCount: Int,
        sequence: UInt64,
        profile: SkyBridgeMediaAudioProfile,
        mode: SkyBridgeMediaAudioMode
    ) -> Bool {
        guard frameCount > 0 else { return false }
        do {
            try ensureConfigured(profile: profile, mode: mode)
        } catch {
            SkyBridgeLogger.shared.debug("PQC media audio player unavailable: \(error.localizedDescription)")
            return false
        }
        guard let renderBuffer else { return false }
        switch renderBuffer.appendPCM16(data, frameCount: frameCount) {
        case .appended(let queuedFrames):
            if playbackState != .running, queuedFrames >= targetQueuedFrames {
                do {
                    try startEngineIfReady()
                } catch {
                    SkyBridgeLogger.shared.debug("PQC media audio player start failed: \(error.localizedDescription)")
                    return false
                }
            }
            return true
        case .overflow:
            logDropIfNeeded(sequence: sequence)
            return false
        case .invalid:
            return false
        }
    }

    func stop() {
        engine?.stop()
        sourceNode = nil
        engine = nil
        renderBuffer = nil
        activeProfileSignature = nil
        targetQueuedFrames = 0
        hardQueuedFrames = 0
        playbackState = .stopped
    }

    func telemetrySnapshot(reset: Bool) -> PlaybackTelemetrySnapshot? {
        guard let snapshot = renderBuffer?.snapshot(reset: reset) else { return nil }
        return PlaybackTelemetrySnapshot(
            queuedMs: snapshot.queuedMs,
            capacityMs: snapshot.capacityMs,
            underflowEvents: snapshot.underflowEvents,
            underflowFrames: snapshot.underflowFrames,
            overflowEvents: snapshot.overflowEvents,
            overflowFrames: snapshot.overflowFrames,
            appendedFrames: snapshot.appendedFrames,
            renderedFrames: snapshot.renderedFrames,
            rebufferEvents: snapshot.rebufferEvents,
            startupSilenceFrames: snapshot.startupSilenceFrames,
            targetQueuedMs: snapshot.targetQueuedMs,
            isPrimed: snapshot.isPrimed,
            isEngineRunning: engine?.isRunning == true,
            audioPath: "pqc-opus-source-node-ring"
        )
    }

    private func ensureConfigured(profile: SkyBridgeMediaAudioProfile, mode: SkyBridgeMediaAudioMode) throws {
        let signature = "\(profile.sampleRate)-\(profile.channels)-\(profile.frameDurationMs)-\(profile.jitterTargetMs)-\(profile.jitterMaxMs)-\(mode.rawValue)"
        if renderBuffer != nil, sourceNode != nil, activeProfileSignature == signature {
            return
        }
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(Double(profile.sampleRate))
        try session.setPreferredIOBufferDuration(mode == .lowLatency ? 0.005 : 0.01)
        try session.setActive(true)

        let targetMs = max(profile.jitterTargetMs + profile.frameDurationMs, profile.frameDurationMs * 3)
        let hardMs = max(profile.jitterMaxMs + profile.frameDurationMs * 2, targetMs)
        let targetFrames = max(
            profile.samplesPerPacket * 3,
            profile.sampleRate * targetMs / 1_000
        )
        let capacityFrames = max(targetFrames, profile.sampleRate * hardMs / 1_000)
        let renderBuffer = RealtimePCMRenderBuffer(
            sampleRate: Double(profile.sampleRate),
            channels: profile.channels,
            capacityFrames: capacityFrames,
            targetQueuedFrames: targetFrames
        )
        let engine = AVAudioEngine()
        let sourceNode = AVAudioSourceNode { [renderBuffer] isSilence, _, frameCount, outputData in
            isSilence.pointee = false
            return renderBuffer.render(into: outputData, frameCount: frameCount)
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        self.engine = engine
        self.sourceNode = sourceNode
        self.renderBuffer = renderBuffer
        self.activeProfileSignature = signature
        self.targetQueuedFrames = targetFrames
        self.hardQueuedFrames = capacityFrames
        self.playbackState = .buffering
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio playback prebuffering: codec=opus path=pqc-opus-source-node-ring mode=\(mode.rawValue) targetQueuedMs=\(targetMs) capacityMs=\(hardMs)"
        )
    }

    private func startEngineIfReady() throws {
        guard let engine else { return }
        if !engine.isRunning {
            try engine.start()
        }
        playbackState = .running
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio playback active: codec=opus path=pqc-opus-source-node-ring targetQueuedMs=\(Int(targetQueuedMs.rounded())) queuedMs=\(Int((renderBuffer?.snapshot(reset: false).queuedMs ?? 0).rounded()))"
        )
    }

    private var targetQueuedMs: Double {
        Double(targetQueuedFrames) * 1_000 / playbackFormat.sampleRate
    }

    private func logDropIfNeeded(sequence: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastDropLogAt) >= 2 else { return }
        lastDropLogAt = now
        let queuedMs = renderBuffer?.snapshot(reset: false).queuedMs ?? 0
        SkyBridgeLogger.shared.debug("PQC media audio playback backpressure: seq=\(sequence) queuedMs=\(Int(queuedMs.rounded()))")
    }
}

private final class RealtimePCMRenderBuffer: @unchecked Sendable {
    enum AppendResult {
        case appended(queuedFrames: Int)
        case overflow(queuedFrames: Int, droppedFrames: Int)
        case invalid
    }

    struct Snapshot: Sendable {
        let queuedFrames: Int
        let capacityFrames: Int
        let sampleRate: Double
        let underflowEvents: UInt64
        let underflowFrames: UInt64
        let overflowEvents: UInt64
        let overflowFrames: UInt64
        let appendedFrames: UInt64
        let renderedFrames: UInt64
        let rebufferEvents: UInt64
        let startupSilenceFrames: UInt64
        let targetQueuedFrames: Int
        let isPrimed: Bool

        var queuedMs: Double {
            Double(queuedFrames) * 1_000 / max(sampleRate, 1)
        }

        var targetQueuedMs: Double {
            Double(targetQueuedFrames) * 1_000 / max(sampleRate, 1)
        }

        var capacityMs: Double {
            Double(capacityFrames) * 1_000 / max(sampleRate, 1)
        }
    }

    private let lock = NSLock()
    private let sampleRate: Double
    private let channels: Int
    private let capacityFrames: Int
    private let targetQueuedFrames: Int
    private var storage: [Float]
    private var readFrame = 0
    private var writeFrame = 0
    private var queuedFrames = 0
    private var isPrimed = false
    private var lastSamples: [Float]
    private var underflowEvents: UInt64 = 0
    private var underflowFrames: UInt64 = 0
    private var overflowEvents: UInt64 = 0
    private var overflowFrames: UInt64 = 0
    private var appendedFrames: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var rebufferEvents: UInt64 = 0
    private var startupSilenceFrames: UInt64 = 0

    init(sampleRate: Double, channels: Int, capacityFrames: Int, targetQueuedFrames: Int) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.capacityFrames = max(1, capacityFrames)
        self.targetQueuedFrames = max(1, min(targetQueuedFrames, capacityFrames))
        self.storage = Array(repeating: 0, count: max(1, capacityFrames) * max(1, channels))
        self.lastSamples = Array(repeating: 0, count: max(1, channels))
    }

    func appendPCM16(_ data: Data, frameCount: Int) -> AppendResult {
        guard frameCount > 0 else { return .invalid }
        let expectedBytes = frameCount * channels * MemoryLayout<Int16>.size
        guard data.count == expectedBytes else { return .invalid }

        lock.lock()
        defer { lock.unlock() }

        let freeFrames = capacityFrames - queuedFrames
        guard frameCount <= freeFrames else {
            overflowEvents &+= 1
            overflowFrames &+= UInt64(frameCount)
            return .overflow(queuedFrames: queuedFrames, droppedFrames: frameCount)
        }

        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard samples.count == frameCount * channels else { return }
            for frame in 0..<frameCount {
                let destinationFrame = (writeFrame + frame) % capacityFrames
                let destinationBase = destinationFrame * channels
                let sourceBase = frame * channels
                for channel in 0..<channels {
                    let sample = Float(Int16(littleEndian: samples[sourceBase + channel]))
                    storage[destinationBase + channel] = sample / Float(Int16.max)
                }
            }
        }
        writeFrame = (writeFrame + frameCount) % capacityFrames
        queuedFrames += frameCount
        if queuedFrames >= targetQueuedFrames {
            isPrimed = true
        }
        appendedFrames &+= UInt64(frameCount)
        return .appended(queuedFrames: queuedFrames)
    }

    func render(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> OSStatus {
        let requestedFrames = Int(frameCount)
        guard requestedFrames > 0 else { return noErr }

        let outputBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        lock.lock()
        defer { lock.unlock() }
        guard isPrimed else {
            startupSilenceFrames &+= UInt64(requestedFrames)
            fillSilence(outputBuffers, frameCount: requestedFrames)
            return noErr
        }

        let framesToRead = min(requestedFrames, queuedFrames)
        if framesToRead < requestedFrames {
            underflowEvents &+= 1
            underflowFrames &+= UInt64(requestedFrames - framesToRead)
            rebufferEvents &+= 1
            isPrimed = false
        }

        if outputBuffers.count == 1,
           Int(outputBuffers[0].mNumberChannels) >= channels,
           let rawPointer = outputBuffers[0].mData {
            let output = rawPointer.assumingMemoryBound(to: Float.self)
            for frame in 0..<requestedFrames {
                let hasAudio = frame < framesToRead
                let sourceFrame = (readFrame + frame) % capacityFrames
                let sourceBase = sourceFrame * channels
                let destinationBase = frame * channels
                for channel in 0..<channels {
                    if hasAudio {
                        let sample = storage[sourceBase + channel]
                        output[destinationBase + channel] = sample
                        lastSamples[channel] = sample
                    } else {
                        output[destinationBase + channel] = fadedUnderflowSample(
                            channel: channel,
                            missingFrameIndex: frame - framesToRead,
                            missingFrameCount: requestedFrames - framesToRead
                        )
                    }
                }
            }
            outputBuffers[0].mDataByteSize = UInt32(requestedFrames * channels * MemoryLayout<Float>.size)
        } else {
            for bufferIndex in 0..<outputBuffers.count {
                guard let rawPointer = outputBuffers[bufferIndex].mData else { continue }
                let output = rawPointer.assumingMemoryBound(to: Float.self)
                let channel = min(bufferIndex, channels - 1)
                for frame in 0..<requestedFrames {
                    if frame < framesToRead {
                        let sourceFrame = (readFrame + frame) % capacityFrames
                        let sample = storage[(sourceFrame * channels) + channel]
                        output[frame] = sample
                        lastSamples[channel] = sample
                    } else {
                        output[frame] = fadedUnderflowSample(
                            channel: channel,
                            missingFrameIndex: frame - framesToRead,
                            missingFrameCount: requestedFrames - framesToRead
                        )
                    }
                }
                outputBuffers[bufferIndex].mDataByteSize = UInt32(requestedFrames * MemoryLayout<Float>.size)
            }
        }

        readFrame = (readFrame + framesToRead) % capacityFrames
        queuedFrames -= framesToRead
        renderedFrames &+= UInt64(framesToRead)
        return noErr
    }

    private func fillSilence(
        _ outputBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        if outputBuffers.count == 1,
           Int(outputBuffers[0].mNumberChannels) >= channels,
           let rawPointer = outputBuffers[0].mData {
            let output = rawPointer.assumingMemoryBound(to: Float.self)
            for index in 0..<(frameCount * channels) {
                output[index] = 0
            }
            outputBuffers[0].mDataByteSize = UInt32(frameCount * channels * MemoryLayout<Float>.size)
            return
        }
        for bufferIndex in 0..<outputBuffers.count {
            guard let rawPointer = outputBuffers[bufferIndex].mData else { continue }
            let output = rawPointer.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                output[frame] = 0
            }
            outputBuffers[bufferIndex].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        }
    }

    private func fadedUnderflowSample(
        channel: Int,
        missingFrameIndex: Int,
        missingFrameCount: Int
    ) -> Float {
        guard missingFrameCount > 0 else { return 0 }
        let fade = max(0, 1 - (Float(missingFrameIndex + 1) / Float(missingFrameCount)))
        return lastSamples[min(channel, lastSamples.count - 1)] * fade
    }

    func snapshot(reset: Bool) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = Snapshot(
            queuedFrames: queuedFrames,
            capacityFrames: capacityFrames,
            sampleRate: sampleRate,
            underflowEvents: underflowEvents,
            underflowFrames: underflowFrames,
            overflowEvents: overflowEvents,
            overflowFrames: overflowFrames,
            appendedFrames: appendedFrames,
            renderedFrames: renderedFrames,
            rebufferEvents: rebufferEvents,
            startupSilenceFrames: startupSilenceFrames,
            targetQueuedFrames: targetQueuedFrames,
            isPrimed: isPrimed
        )
        if reset {
            underflowEvents = 0
            underflowFrames = 0
            overflowEvents = 0
            overflowFrames = 0
            appendedFrames = 0
            renderedFrames = 0
            rebufferEvents = 0
            startupSilenceFrames = 0
        }
        return snapshot
    }
}

actor IOSRealtimeMediaAudioReceiver {
    private enum AuthenticatedSourceDecision: Equatable {
        case accepted
        case migrated
    }

    private struct ReceiverTelemetryCounters: Sendable {
        var received: UInt64 = 0
        var decoded: UInt64 = 0
        var played: UInt64 = 0
        var rejected: UInt64 = 0
        var replayRejected: UInt64 = 0
        var jitterLate: UInt64 = 0
        var jitterDuplicate: UInt64 = 0
        var jitterEvicted: UInt64 = 0
        var jitterGapStopped: UInt64 = 0
        var playbackDropped: UInt64 = 0
        var plcFrames: UInt64 = 0
        var sourceRejected: UInt64 = 0
        var sourceMigrated: UInt64 = 0

        static func - (lhs: ReceiverTelemetryCounters, rhs: ReceiverTelemetryCounters) -> ReceiverTelemetryCounters {
            ReceiverTelemetryCounters(
                received: lhs.received &- rhs.received,
                decoded: lhs.decoded &- rhs.decoded,
                played: lhs.played &- rhs.played,
                rejected: lhs.rejected &- rhs.rejected,
                replayRejected: lhs.replayRejected &- rhs.replayRejected,
                jitterLate: lhs.jitterLate &- rhs.jitterLate,
                jitterDuplicate: lhs.jitterDuplicate &- rhs.jitterDuplicate,
                jitterEvicted: lhs.jitterEvicted &- rhs.jitterEvicted,
                jitterGapStopped: lhs.jitterGapStopped &- rhs.jitterGapStopped,
                playbackDropped: lhs.playbackDropped &- rhs.playbackDropped,
                plcFrames: lhs.plcFrames &- rhs.plcFrames,
                sourceRejected: lhs.sourceRejected &- rhs.sourceRejected,
                sourceMigrated: lhs.sourceMigrated &- rhs.sourceMigrated
            )
        }
    }

    private let sessionIdHash: UInt64
    private let keys: SkyBridgeMediaDirectionKeys
    private let profile: SkyBridgeMediaAudioProfile
    private let mode: SkyBridgeMediaAudioMode
    private var decoder: SkyBridgeOpusDecoder
    private var replayWindow = SkyBridgeMediaReplayWindow()
    private var jitterBuffer: SkyBridgeMediaJitterBuffer<SkyBridgeMediaOpenedPacket>
    private var playoutTask: Task<Void, Never>?
    private var received: UInt64 = 0
    private var decoded: UInt64 = 0
    private var played: UInt64 = 0
    private var rejected: UInt64 = 0
    private var lateOrDuplicate: UInt64 = 0
    private var replayRejected: UInt64 = 0
    private var jitterLate: UInt64 = 0
    private var jitterDuplicate: UInt64 = 0
    private var jitterEvicted: UInt64 = 0
    private var jitterGapStopped: UInt64 = 0
    private var playbackDropped: UInt64 = 0
    private var plcFrames: UInt64 = 0
    private var sourceRejected: UInt64 = 0
    private var sourceMigrated: UInt64 = 0
    private var lockedRemoteEndpoint: SkyBridgeMediaEndpoint?
    private var lastSourceMismatchLogAt = Date.distantPast
    private var lastSourceMigrationLogAt = Date.distantPast
    private var lastTelemetryAt = Date.distantPast
    private var lastTelemetryCounters = ReceiverTelemetryCounters()
    private var consecutivePLCFrames = 0

    init(snapshot: RemoteRealtimeMediaKeySnapshot, mode: SkyBridgeMediaAudioMode) throws {
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: snapshot.sendKey,
            receiveSecret: snapshot.receiveKey,
            sessionId: snapshot.sessionId,
            transcriptHash: snapshot.transcriptHash
        )
        self.sessionIdHash = SkyBridgeMediaPacketCodec.sessionIdHash(snapshot.sessionId)
        self.keys = keyMaterial.receive
        self.mode = mode
        self.profile = SkyBridgeMediaAudioProfile.profile(for: mode)
        self.jitterBuffer = SkyBridgeMediaJitterBuffer(
            targetDelayMs: self.profile.jitterTargetMs,
            maxDelayMs: self.profile.jitterMaxMs,
            packetDurationMs: self.profile.frameDurationMs
        )
        self.decoder = try SkyBridgeOpusDecoder(
            sampleRate: profile.sampleRate,
            channels: profile.channels,
            frameDurationMs: profile.frameDurationMs
        )
    }

    func handle(datagram: SkyBridgeMediaReceivedDatagram) async {
        do {
            let opened = try SkyBridgeMediaPacketCodec.open(packet: datagram.packet, keys: keys)
            guard opened.header.sessionIdHash == sessionIdHash else {
                rejected &+= 1
                await logTelemetryIfNeeded()
                return
            }
            guard let sourceDecision = acceptAuthenticatedSource(
                datagram.remoteEndpoint,
                sequence: opened.header.sequence
            ) else {
                sourceRejected &+= 1
                rejected &+= 1
                await logTelemetryIfNeeded()
                return
            }
            if sourceDecision == .migrated {
                await resetReceiveOrderingState(reason: "source-migration")
            }
            guard replayWindow.accept(sequence: opened.header.sequence) else {
                replayRejected &+= 1
                lateOrDuplicate &+= 1
                await logTelemetryIfNeeded()
                return
            }
            received &+= 1
            let insertResult = jitterBuffer.insert(
                SkyBridgeMediaJitterFrame(
                    sequence: opened.header.sequence,
                    timestampSamples: opened.header.timestampSamples,
                    insertedAt: Date().timeIntervalSinceReferenceDate,
                    payload: opened
                ),
                now: Date().timeIntervalSinceReferenceDate
            )
            switch insertResult {
            case .accepted:
                startPlayoutLoopIfNeeded()
            case .duplicate:
                jitterDuplicate &+= 1
                lateOrDuplicate &+= 1
            case .droppedLate:
                jitterLate &+= 1
                lateOrDuplicate &+= 1
            case .evictedOldest:
                jitterEvicted &+= 1
                lateOrDuplicate &+= 1
            }
        } catch {
            rejected &+= 1
            SkyBridgeLogger.shared.debug("PQC media audio packet rejected: \(error.localizedDescription)")
        }
        await logTelemetryIfNeeded()
    }

    func close() async {
        playoutTask?.cancel()
        playoutTask = nil
        await IOSRealtimeMediaAudioPlayer.shared.stop()
    }

    func receivedPacketCount() -> UInt64 {
        received
    }

    private func acceptAuthenticatedSource(
        _ remoteEndpoint: SkyBridgeMediaEndpoint?,
        sequence: UInt64
    ) -> AuthenticatedSourceDecision? {
        guard let remoteEndpoint else {
            return .accepted
        }
        let normalized = Self.normalized(remoteEndpoint)
        if let lockedRemoteEndpoint {
            let lockedNormalized = Self.normalized(lockedRemoteEndpoint)
            if lockedNormalized == normalized {
                return .accepted
            }
            guard Self.normalizedHost(lockedRemoteEndpoint) == Self.normalizedHost(remoteEndpoint) else {
                logSourceMismatch(locked: lockedRemoteEndpoint, incoming: remoteEndpoint)
                return nil
            }
            self.lockedRemoteEndpoint = remoteEndpoint
            sourceMigrated &+= 1
            logSourceMigration(from: lockedRemoteEndpoint, to: remoteEndpoint, sequence: sequence)
            return .migrated
        }
        lockedRemoteEndpoint = remoteEndpoint
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio source locked: host=\(normalized.host) port=\(normalized.port)"
        )
        return .accepted
    }

    private func resetReceiveOrderingState(reason: String) async {
        replayWindow = SkyBridgeMediaReplayWindow()
        jitterBuffer = SkyBridgeMediaJitterBuffer(
            targetDelayMs: profile.jitterTargetMs,
            maxDelayMs: profile.jitterMaxMs,
            packetDurationMs: profile.frameDurationMs
        )
        consecutivePLCFrames = 0
        playoutTask?.cancel()
        playoutTask = nil
        if let freshDecoder = try? SkyBridgeOpusDecoder(
            sampleRate: profile.sampleRate,
            channels: profile.channels,
            frameDurationMs: profile.frameDurationMs
        ) {
            decoder = freshDecoder
        }
        await IOSRealtimeMediaAudioPlayer.shared.stop()
        SkyBridgeLogger.shared.info("🎧 PQC media audio receive ordering reset: reason=\(reason)")
    }

    private func startPlayoutLoopIfNeeded() {
        guard playoutTask == nil else { return }
        let tickMs = profile.frameDurationMs
        playoutTask = Task { [weak self] in
            let frameIntervalNanos = UInt64(max(1, tickMs)) * 1_000_000
            var nextDeadline = DispatchTime.now().uptimeNanoseconds + frameIntervalNanos
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > now {
                    try? await Task.sleep(nanoseconds: nextDeadline - now)
                }
                let wokeAt = DispatchTime.now().uptimeNanoseconds
                let overdueNanos = wokeAt > nextDeadline ? wokeAt - nextDeadline : 0
                let dueFrames = max(1, Int(overdueNanos / frameIntervalNanos) + 1)
                nextDeadline &+= UInt64(dueFrames) * frameIntervalNanos
                await self?.playoutTick(maxFrames: dueFrames)
                await self?.logTelemetryIfNeeded()
            }
        }
    }

    private func playoutTick(maxFrames dueFrames: Int) async {
        var scheduledFrames = 0
        let frameLimit = max(1, min(playoutBurstFrameLimit, dueFrames))
        while scheduledFrames < frameLimit {
            guard await playoutNextFrame() else { return }
            scheduledFrames += 1
        }
    }

    private var playoutBurstFrameLimit: Int {
        max(2, min(6, profile.jitterTargetMs / profile.frameDurationMs))
    }

    private var maxConsecutivePLCFrameCount: Int {
        max(3, profile.jitterMaxMs / profile.frameDurationMs)
    }

    private func playoutNextFrame() async -> Bool {
        switch jitterBuffer.popReadyOrGap(now: Date().timeIntervalSinceReferenceDate) {
        case .wait:
            return false
        case .gap(let sequence):
            guard consecutivePLCFrames < maxConsecutivePLCFrameCount else {
                jitterGapStopped &+= 1
                lateOrDuplicate &+= 1
                return false
            }
            await playPLCFrame(sequence: sequence)
            return true
        case .frame(let frame):
            do {
                let samples = try decoder.decode(
                    packet: frame.payload.payload,
                    frameSamplesPerChannel: profile.samplesPerPacket
                )
                decoded &+= 1
                consecutivePLCFrames = 0
                await schedule(samples: samples, sequence: frame.sequence)
                return true
            } catch {
                rejected &+= 1
                SkyBridgeLogger.shared.debug("PQC media audio decode rejected: \(error.localizedDescription)")
                return true
            }
        }
    }

    private func playPLCFrame(sequence: UInt64) async {
        do {
            let samples = try decoder.decode(
                packet: nil,
                frameSamplesPerChannel: profile.samplesPerPacket
            )
            plcFrames &+= 1
            consecutivePLCFrames += 1
            await schedule(samples: samples, sequence: sequence)
        } catch {
            rejected &+= 1
            SkyBridgeLogger.shared.debug("PQC media audio PLC rejected: \(error.localizedDescription)")
        }
    }

    private func schedule(samples: [Int16], sequence: UInt64) async {
        let pcm = samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: samples.count * MemoryLayout<Int16>.size)
        }
        let didSchedule = await IOSRealtimeMediaAudioPlayer.shared.playPCM16(
            pcm,
            frameCount: samples.count / profile.channels,
            sequence: sequence,
            profile: profile,
            mode: mode
        )
        if didSchedule {
            played &+= 1
        } else {
            playbackDropped &+= 1
            rejected &+= 1
        }
    }

    private func currentCounters() -> ReceiverTelemetryCounters {
        ReceiverTelemetryCounters(
            received: received,
            decoded: decoded,
            played: played,
            rejected: rejected,
            replayRejected: replayRejected,
            jitterLate: jitterLate,
            jitterDuplicate: jitterDuplicate,
            jitterEvicted: jitterEvicted,
            jitterGapStopped: jitterGapStopped,
            playbackDropped: playbackDropped,
            plcFrames: plcFrames,
            sourceRejected: sourceRejected,
            sourceMigrated: sourceMigrated
        )
    }

    private func logTelemetryIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastTelemetryAt) >= 5 else { return }
        lastTelemetryAt = now
        let counters = currentCounters()
        let window = counters - lastTelemetryCounters
        lastTelemetryCounters = counters
        let playback = await IOSRealtimeMediaAudioPlayer.shared.telemetrySnapshot(reset: true)
        let queuedMs = playback.map { String(format: "%.0f", $0.queuedMs) } ?? "-"
        let targetQueuedMs = playback.map { String(format: "%.0f", $0.targetQueuedMs) } ?? "-"
        let capacityMs = playback.map { String(format: "%.0f", $0.capacityMs) } ?? "-"
        let underflow = playback?.underflowEvents ?? 0
        let overflow = playback?.overflowEvents ?? 0
        let rebuffer = playback?.rebufferEvents ?? 0
        let startupSilenceFrames = playback?.startupSilenceFrames ?? 0
        let renderedFrames = playback?.renderedFrames ?? 0
        let primed = playback?.isPrimed ?? false
        let engineRunning = playback?.isEngineRunning ?? false
        let scheduleLeadMs = playback.map { String(format: "%.0f", $0.queuedMs) } ?? "-"
        let windowLate = window.replayRejected + window.jitterLate + window.jitterDuplicate + window.jitterEvicted
        let windowArrivals = window.received + windowLate
        let lateRatio = windowArrivals > 0 ? Double(windowLate) / Double(windowArrivals) : 0
        let plcRatio = window.played > 0 ? Double(window.plcFrames) / Double(window.played) : 0
        let lateRatioText = String(format: "%.3f", lateRatio)
        let plcRatioText = String(format: "%.3f", plcRatio)
        let audioPath = playback?.audioPath ?? "pqc-opus-source-node-ring"
        SkyBridgeLogger.shared.info(
            "📈 PQC media audio rx: recv=\(window.received) decode=\(window.decoded) play=\(window.played) rejected=\(window.rejected) recvTotal=\(received) decodeTotal=\(decoded) playTotal=\(played) replayRejected=\(window.replayRejected) jitterLate=\(window.jitterLate) jitterDuplicate=\(window.jitterDuplicate) jitterEvicted=\(window.jitterEvicted) jitterGapStop=\(window.jitterGapStopped) plc=\(window.plcFrames) sourceReject=\(window.sourceRejected) sourceMigrate=\(window.sourceMigrated) playbackDrop=\(window.playbackDropped) jitter=\(jitterBuffer.bufferedFrameCount) codec=opus activeCodec=opus audioPath=\(audioPath) queuedMs=\(queuedMs) targetQueuedMs=\(targetQueuedMs) capacityMs=\(capacityMs) scheduleLeadMs=\(scheduleLeadMs) primed=\(primed) engineRunning=\(engineRunning) underflow=\(underflow) rebuffer=\(rebuffer) overflow=\(overflow) startupSilenceFrames=\(startupSilenceFrames) renderedFrames=\(renderedFrames) plcRatio=\(plcRatioText) lateRatio=\(lateRatioText)"
        )
    }

    private func logSourceMismatch(locked: SkyBridgeMediaEndpoint, incoming: SkyBridgeMediaEndpoint) {
        let now = Date()
        guard now.timeIntervalSince(lastSourceMismatchLogAt) >= 2 else { return }
        lastSourceMismatchLogAt = now
        let lockedNormalized = Self.normalized(locked)
        let incomingNormalized = Self.normalized(incoming)
        SkyBridgeLogger.shared.debug(
            "PQC media audio rejected unexpected source: locked=\(lockedNormalized.host):\(lockedNormalized.port) incoming=\(incomingNormalized.host):\(incomingNormalized.port)"
        )
    }

    private func logSourceMigration(from locked: SkyBridgeMediaEndpoint, to incoming: SkyBridgeMediaEndpoint, sequence: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastSourceMigrationLogAt) >= 2 else { return }
        lastSourceMigrationLogAt = now
        let lockedNormalized = Self.normalized(locked)
        let incomingNormalized = Self.normalized(incoming)
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio source migrated: old=\(lockedNormalized.host):\(lockedNormalized.port) incoming=\(incomingNormalized.host):\(incomingNormalized.port) seq=\(sequence)"
        )
    }

    private static func normalized(_ endpoint: SkyBridgeMediaEndpoint) -> SkyBridgeMediaEndpoint {
        SkyBridgeMediaEndpoint(
            host: endpoint.host
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased(),
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
}
