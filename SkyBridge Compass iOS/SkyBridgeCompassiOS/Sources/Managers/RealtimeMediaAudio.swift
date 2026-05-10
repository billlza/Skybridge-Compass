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

struct IOSRealtimeMediaAudioReceiverStartupSnapshot: Sendable {
    let datagramsSeen: UInt64
    let received: UInt64
    let decoded: UInt64
    let played: UInt64
    let rejected: UInt64
    let authRejected: UInt64
    let sessionHashRejected: UInt64
    let replayRejected: UInt64
    let sourceRejected: UInt64
    let sourceMigrated: UInt64
}

struct IOSRealtimeMediaAudioReceiverHeartbeatSnapshot: Sendable {
    let datagramsSeen: UInt64
    let received: UInt64
    let decoded: UInt64
    let played: UInt64
    let rejected: UInt64
    let authRejected: UInt64
    let sessionHashRejected: UInt64
    let replayRejected: UInt64
    let jitterEvicted: UInt64
    let playbackDropped: UInt64
    let renderedFrames: UInt64?
    let underflowEvents: UInt64?
    let rebufferEvents: UInt64?
    let startupSilenceFrames: UInt64?
    let engineRunning: Bool?
}

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
        let bridgedUnderflowFrames: UInt64
        let startupSilenceFrames: UInt64
        let targetQueuedMs: Double
        let isPrimed: Bool
        let isEngineRunning: Bool
        let audioPath: String
    }

    struct EffectivePlaybackProfile: Sendable, Equatable {
        let jitterTargetMs: Int
        let jitterMaxMs: Int
        let maxJitterTargetMs: Int
        let maxJitterMaxMs: Int

        var targetQueuedMs: Int {
            jitterTargetMs + 20
        }

        var rebufferResumeMs: Int {
            max(100, (targetQueuedMs * 3 + 3) / 4)
        }

        var softUnderflowBridgeMs: Int {
            max(40, min(jitterTargetMs, rebufferResumeMs))
        }

        var capacityMs: Int {
            max(maxJitterMaxMs + 40, maxJitterTargetMs + 20)
        }
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
    private var rebufferResumeFrames: Int = 0
    private var softUnderflowBridgeFrames: Int = 0
    private var hardQueuedFrames: Int = 0
    private var playbackState: PlaybackState = .stopped
    private var lastDropLogAt = Date.distantPast

    private init() {}

    func playPCM16(
        _ data: Data,
        frameCount: Int,
        sequence: UInt64,
        profile: SkyBridgeMediaAudioProfile,
        mode: SkyBridgeMediaAudioMode,
        effectiveProfile: EffectivePlaybackProfile
    ) -> Bool {
        guard frameCount > 0 else { return false }
        do {
            try ensureConfigured(profile: profile, mode: mode, effectiveProfile: effectiveProfile)
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
        rebufferResumeFrames = 0
        softUnderflowBridgeFrames = 0
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
            bridgedUnderflowFrames: snapshot.bridgedUnderflowFrames,
            startupSilenceFrames: snapshot.startupSilenceFrames,
            targetQueuedMs: snapshot.targetQueuedMs,
            isPrimed: snapshot.isPrimed,
            isEngineRunning: engine?.isRunning == true,
            audioPath: "pqc-opus-source-node-ring"
        )
    }

    func renderQueueDeficitPacketCount(profile: SkyBridgeMediaAudioProfile) -> Int {
        guard let snapshot = renderBuffer?.snapshot(reset: false) else { return 0 }
        let deficitFrames = max(0, snapshot.targetQueuedFrames - snapshot.queuedFrames)
        guard deficitFrames > 0 else { return 0 }
        return max(1, (deficitFrames + profile.samplesPerPacket - 1) / profile.samplesPerPacket)
    }

    private func ensureConfigured(
        profile: SkyBridgeMediaAudioProfile,
        mode: SkyBridgeMediaAudioMode,
        effectiveProfile: EffectivePlaybackProfile
    ) throws {
        let signature = "\(profile.sampleRate)-\(profile.channels)-\(profile.frameDurationMs)-\(mode.rawValue)-adaptive-\(effectiveProfile.maxJitterTargetMs)-\(effectiveProfile.maxJitterMaxMs)"
        if renderBuffer != nil, sourceNode != nil, activeProfileSignature == signature {
            renderBuffer?.updateTargets(
                targetQueuedFrames: frames(for: effectiveProfile.targetQueuedMs, profile: profile),
                rebufferResumeFrames: frames(for: effectiveProfile.rebufferResumeMs, profile: profile),
                softUnderflowBridgeFrames: frames(for: effectiveProfile.softUnderflowBridgeMs, profile: profile)
            )
            self.targetQueuedFrames = frames(for: effectiveProfile.targetQueuedMs, profile: profile)
            self.rebufferResumeFrames = frames(for: effectiveProfile.rebufferResumeMs, profile: profile)
            self.softUnderflowBridgeFrames = frames(for: effectiveProfile.softUnderflowBridgeMs, profile: profile)
            return
        }
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(Double(profile.sampleRate))
        try session.setPreferredIOBufferDuration(mode == .lowLatency ? 0.005 : 0.01)
        try session.setActive(true)

        let targetMs = effectiveProfile.targetQueuedMs
        let rebufferResumeMs = effectiveProfile.rebufferResumeMs
        let softUnderflowBridgeMs = effectiveProfile.softUnderflowBridgeMs
        let hardMs = effectiveProfile.capacityMs
        let targetFrames = frames(for: targetMs, profile: profile)
        let rebufferResumeFrames = frames(for: rebufferResumeMs, profile: profile)
        let softUnderflowBridgeFrames = frames(for: softUnderflowBridgeMs, profile: profile)
        let capacityFrames = max(targetFrames, frames(for: hardMs, profile: profile))
        let renderBuffer = RealtimePCMRenderBuffer(
            sampleRate: Double(profile.sampleRate),
            channels: profile.channels,
            capacityFrames: capacityFrames,
            targetQueuedFrames: targetFrames,
            rebufferResumeFrames: rebufferResumeFrames,
            softUnderflowBridgeFrames: softUnderflowBridgeFrames
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
        self.rebufferResumeFrames = rebufferResumeFrames
        self.softUnderflowBridgeFrames = softUnderflowBridgeFrames
        self.hardQueuedFrames = capacityFrames
        self.playbackState = .buffering
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio playback prebuffering: codec=opus path=pqc-opus-source-node-ring mode=\(mode.rawValue) targetQueuedMs=\(targetMs) rebufferResumeMs=\(rebufferResumeMs) softUnderflowBridgeMs=\(softUnderflowBridgeMs) capacityMs=\(hardMs)"
        )
    }

    private func frames(for milliseconds: Int, profile: SkyBridgeMediaAudioProfile) -> Int {
        max(profile.samplesPerPacket, profile.sampleRate * max(1, milliseconds) / 1_000)
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
        let bridgedUnderflowFrames: UInt64
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
    private var targetQueuedFrames: Int
    private var rebufferResumeFrames: Int
    private var softUnderflowBridgeFrames: Int
    private var storage: [Float]
    private var readFrame = 0
    private var writeFrame = 0
    private var queuedFrames = 0
    private var isPrimed = false
    private var hasStartedPlayback = false
    private var lastSamples: [Float]
    private var underflowEvents: UInt64 = 0
    private var underflowFrames: UInt64 = 0
    private var overflowEvents: UInt64 = 0
    private var overflowFrames: UInt64 = 0
    private var appendedFrames: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var rebufferEvents: UInt64 = 0
    private var bridgedUnderflowFrames: UInt64 = 0
    private var startupSilenceFrames: UInt64 = 0
    private var softUnderflowBridgeFramesRemaining: Int

    init(
        sampleRate: Double,
        channels: Int,
        capacityFrames: Int,
        targetQueuedFrames: Int,
        rebufferResumeFrames: Int,
        softUnderflowBridgeFrames: Int
    ) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.capacityFrames = max(1, capacityFrames)
        self.targetQueuedFrames = max(1, min(targetQueuedFrames, capacityFrames))
        self.rebufferResumeFrames = max(1, min(rebufferResumeFrames, self.targetQueuedFrames))
        self.softUnderflowBridgeFrames = max(0, softUnderflowBridgeFrames)
        self.softUnderflowBridgeFramesRemaining = max(0, softUnderflowBridgeFrames)
        self.storage = Array(repeating: 0, count: max(1, capacityFrames) * max(1, channels))
        self.lastSamples = Array(repeating: 0, count: max(1, channels))
    }

    func updateTargets(
        targetQueuedFrames: Int,
        rebufferResumeFrames: Int,
        softUnderflowBridgeFrames: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.targetQueuedFrames = max(1, min(targetQueuedFrames, capacityFrames))
        self.rebufferResumeFrames = max(1, min(rebufferResumeFrames, self.targetQueuedFrames))
        self.softUnderflowBridgeFrames = max(0, softUnderflowBridgeFrames)
        self.softUnderflowBridgeFramesRemaining = min(
            max(0, self.softUnderflowBridgeFramesRemaining),
            self.softUnderflowBridgeFrames
        )
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
        let primingThreshold = hasStartedPlayback ? rebufferResumeFrames : targetQueuedFrames
        if queuedFrames >= primingThreshold {
            isPrimed = true
            hasStartedPlayback = true
            softUnderflowBridgeFramesRemaining = softUnderflowBridgeFrames
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
            let missingFrames = requestedFrames - framesToRead
            underflowEvents &+= 1
            underflowFrames &+= UInt64(missingFrames)
            if missingFrames <= softUnderflowBridgeFramesRemaining {
                softUnderflowBridgeFramesRemaining -= missingFrames
                bridgedUnderflowFrames &+= UInt64(missingFrames)
            } else {
                bridgedUnderflowFrames &+= UInt64(softUnderflowBridgeFramesRemaining)
                softUnderflowBridgeFramesRemaining = 0
                rebufferEvents &+= 1
                isPrimed = false
            }
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
        if isPrimed, queuedFrames >= rebufferResumeFrames {
            softUnderflowBridgeFramesRemaining = softUnderflowBridgeFrames
        }
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
            bridgedUnderflowFrames: bridgedUnderflowFrames,
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
            bridgedUnderflowFrames = 0
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
        var datagramsSeen: UInt64 = 0
        var received: UInt64 = 0
        var decoded: UInt64 = 0
        var played: UInt64 = 0
        var rejected: UInt64 = 0
        var authRejected: UInt64 = 0
        var sessionHashRejected: UInt64 = 0
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
                datagramsSeen: lhs.datagramsSeen &- rhs.datagramsSeen,
                received: lhs.received &- rhs.received,
                decoded: lhs.decoded &- rhs.decoded,
                played: lhs.played &- rhs.played,
                rejected: lhs.rejected &- rhs.rejected,
                authRejected: lhs.authRejected &- rhs.authRejected,
                sessionHashRejected: lhs.sessionHashRejected &- rhs.sessionHashRejected,
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
    private let sessionId: String
    private let keys: SkyBridgeMediaDirectionKeys
    private let profile: SkyBridgeMediaAudioProfile
    private let mode: SkyBridgeMediaAudioMode
    private var decoder: SkyBridgeOpusDecoder
    private var replayWindow = SkyBridgeMediaReplayWindow()
    private var jitterBuffer: SkyBridgeMediaJitterBuffer<SkyBridgeMediaOpenedPacket>
    private var playoutTask: Task<Void, Never>?
    private var datagramsSeen: UInt64 = 0
    private var received: UInt64 = 0
    private var decoded: UInt64 = 0
    private var played: UInt64 = 0
    private var rejected: UInt64 = 0
    private var authRejected: UInt64 = 0
    private var sessionHashRejected: UInt64 = 0
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
    private var effectiveJitterTargetMs: Int
    private var effectiveJitterMaxMs: Int
    private var stableJitterWindowCount = 0
    private var lastJitterAdaptationReason = "baseline"
    private var arrivalIntervalStats = RollingMillisecondStats(maxSamples: 96)
    private var lastAcceptedPacketArrivalAt: TimeInterval?

    init(snapshot: RemoteRealtimeMediaKeySnapshot, mode: SkyBridgeMediaAudioMode) throws {
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: snapshot.sendKey,
            receiveSecret: snapshot.receiveKey,
            sessionId: snapshot.sessionId,
            transcriptHash: snapshot.transcriptHash
        )
        self.sessionIdHash = SkyBridgeMediaPacketCodec.sessionIdHash(snapshot.sessionId)
        self.sessionId = snapshot.sessionId
        self.keys = keyMaterial.receive
        self.mode = mode
        self.profile = SkyBridgeMediaAudioProfile.profile(for: mode)
        let initialJitterTargetMs = Self.initialJitterTargetMs(for: self.profile, mode: mode)
        let initialJitterMaxMs = Self.initialJitterMaxMs(for: self.profile, mode: mode)
        self.effectiveJitterTargetMs = initialJitterTargetMs
        self.effectiveJitterMaxMs = initialJitterMaxMs
        self.jitterBuffer = SkyBridgeMediaJitterBuffer(
            targetDelayMs: Self.orderingJitterTargetMs(for: self.profile, mode: mode),
            maxDelayMs: Self.orderingJitterMaxMs(for: self.profile, mode: mode),
            packetDurationMs: self.profile.frameDurationMs,
            reorderGraceMs: 0
        )
        self.decoder = try SkyBridgeOpusDecoder(
            sampleRate: profile.sampleRate,
            channels: profile.channels,
            frameDurationMs: profile.frameDurationMs
        )
    }

    func handle(datagram: SkyBridgeMediaReceivedDatagram) async {
        datagramsSeen &+= 1
        do {
            let opened = try SkyBridgeMediaPacketCodec.open(packet: datagram.packet, keys: keys)
            guard opened.header.sessionIdHash == sessionIdHash else {
                sessionHashRejected &+= 1
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
            let receivedAt = Date().timeIntervalSinceReferenceDate
            recordPacketArrival(now: receivedAt)
            let insertResult = jitterBuffer.insert(
                SkyBridgeMediaJitterFrame(
                    sequence: opened.header.sequence,
                    timestampSamples: opened.header.timestampSamples,
                    insertedAt: receivedAt,
                    payload: opened
                ),
                now: receivedAt
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
            authRejected &+= 1
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

    func startupDiagnosticSnapshot() -> IOSRealtimeMediaAudioReceiverStartupSnapshot {
        IOSRealtimeMediaAudioReceiverStartupSnapshot(
            datagramsSeen: datagramsSeen,
            received: received,
            decoded: decoded,
            played: played,
            rejected: rejected,
            authRejected: authRejected,
            sessionHashRejected: sessionHashRejected,
            replayRejected: replayRejected,
            sourceRejected: sourceRejected,
            sourceMigrated: sourceMigrated
        )
    }

    func heartbeatDiagnosticSnapshot() async -> IOSRealtimeMediaAudioReceiverHeartbeatSnapshot {
        let playback = await IOSRealtimeMediaAudioPlayer.shared.telemetrySnapshot(reset: false)
        return IOSRealtimeMediaAudioReceiverHeartbeatSnapshot(
            datagramsSeen: datagramsSeen,
            received: received,
            decoded: decoded,
            played: played,
            rejected: rejected,
            authRejected: authRejected,
            sessionHashRejected: sessionHashRejected,
            replayRejected: replayRejected,
            jitterEvicted: jitterEvicted,
            playbackDropped: playbackDropped,
            renderedFrames: playback?.renderedFrames,
            underflowEvents: playback?.underflowEvents,
            rebufferEvents: playback?.rebufferEvents,
            startupSilenceFrames: playback?.startupSilenceFrames,
            engineRunning: playback?.isEngineRunning
        )
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
            targetDelayMs: orderingJitterTargetMs,
            maxDelayMs: orderingJitterMaxMs,
            packetDurationMs: profile.frameDurationMs,
            reorderGraceMs: 0
        )
        consecutivePLCFrames = 0
        arrivalIntervalStats.reset()
        lastAcceptedPacketArrivalAt = nil
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
        let renderDeficitFrames = await IOSRealtimeMediaAudioPlayer.shared.renderQueueDeficitPacketCount(
            profile: profile
        )
        let allowPLCGap = renderDeficitFrames >= gapPlayoutDeficitThresholdPacketCount
        let frameLimit = max(1, min(playoutBurstFrameLimit, dueFrames + renderDeficitFrames))
        while scheduledFrames < frameLimit {
            guard await playoutNextFrame(allowPLCGap: allowPLCGap) else { return }
            scheduledFrames += 1
        }
    }

    private var gapPlayoutDeficitThresholdPacketCount: Int {
        let lowWaterMs: Int
        switch mode {
        case .lowLatency:
            lowWaterMs = 700
        case .highFidelity:
            lowWaterMs = 240
        }
        let frameDurationMs = max(1, profile.frameDurationMs)
        let deficitMs = max(frameDurationMs * 8, effectiveJitterTargetMs - lowWaterMs)
        return max(8, min(96, deficitMs / frameDurationMs))
    }

    private var playoutBurstFrameLimit: Int {
        max(2, min(32, effectiveJitterMaxMs / profile.frameDurationMs))
    }

    private var maxConsecutivePLCFrameCount: Int {
        max(3, effectiveJitterMaxMs / profile.frameDurationMs)
    }

    private func playoutNextFrame(allowPLCGap: Bool) async -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        let result: SkyBridgeMediaJitterPopResult<SkyBridgeMediaOpenedPacket>
        if allowPLCGap {
            result = jitterBuffer.popReadyOrGap(now: now)
        } else if let frame = jitterBuffer.popReadyFrame(now: now) {
            result = .frame(frame)
        } else {
            result = .wait
        }
        switch result {
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
            mode: mode,
            effectiveProfile: effectivePlaybackProfile
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
            datagramsSeen: datagramsSeen,
            received: received,
            decoded: decoded,
            played: played,
            rejected: rejected,
            authRejected: authRejected,
            sessionHashRejected: sessionHashRejected,
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

    private static func initialJitterTargetMs(
        for profile: SkyBridgeMediaAudioProfile,
        mode: SkyBridgeMediaAudioMode
    ) -> Int {
        switch mode {
        case .lowLatency:
            return max(profile.jitterTargetMs, 2_400)
        case .highFidelity:
            return max(profile.jitterTargetMs, 520)
        }
    }

    private static func initialJitterMaxMs(
        for profile: SkyBridgeMediaAudioProfile,
        mode: SkyBridgeMediaAudioMode
    ) -> Int {
        switch mode {
        case .lowLatency:
            return max(profile.jitterMaxMs, 4_800)
        case .highFidelity:
            return max(profile.jitterMaxMs, 900)
        }
    }

    private static func orderingJitterTargetMs(
        for profile: SkyBridgeMediaAudioProfile,
        mode: SkyBridgeMediaAudioMode
    ) -> Int {
        switch mode {
        case .lowLatency:
            return min(max(profile.jitterTargetMs, profile.frameDurationMs * 4), 120)
        case .highFidelity:
            return min(max(profile.jitterTargetMs, 180), 320)
        }
    }

    private static func orderingJitterMaxMs(
        for profile: SkyBridgeMediaAudioProfile,
        mode: SkyBridgeMediaAudioMode
    ) -> Int {
        switch mode {
        case .lowLatency:
            return min(max(profile.jitterMaxMs, profile.frameDurationMs * 120), 2_400)
        case .highFidelity:
            return min(max(profile.jitterMaxMs, 900), 1_200)
        }
    }

    private var orderingJitterTargetMs: Int {
        Self.orderingJitterTargetMs(for: profile, mode: mode)
    }

    private var orderingJitterMaxMs: Int {
        Self.orderingJitterMaxMs(for: profile, mode: mode)
    }

    private var minimumAdaptiveJitterTargetMs: Int {
        switch mode {
        case .lowLatency:
            return max(profile.jitterTargetMs, 520)
        case .highFidelity:
            return max(profile.jitterTargetMs, 340)
        }
    }

    private var minimumAdaptiveJitterMaxMs: Int {
        switch mode {
        case .lowLatency:
            return max(profile.jitterMaxMs, 900)
        case .highFidelity:
            return max(profile.jitterMaxMs, 760)
        }
    }

    private var maxAdaptiveJitterTargetMs: Int {
        switch mode {
        case .lowLatency:
            return max(profile.jitterTargetMs, 3_200)
        case .highFidelity:
            return max(profile.jitterTargetMs, 700)
        }
    }

    private var maxAdaptiveJitterMaxMs: Int {
        switch mode {
        case .lowLatency:
            return max(profile.jitterMaxMs, 5_600)
        case .highFidelity:
            return max(profile.jitterMaxMs, 1_200)
        }
    }

    private var effectivePlaybackProfile: IOSRealtimeMediaAudioPlayer.EffectivePlaybackProfile {
        IOSRealtimeMediaAudioPlayer.EffectivePlaybackProfile(
            jitterTargetMs: effectiveJitterTargetMs,
            jitterMaxMs: effectiveJitterMaxMs,
            maxJitterTargetMs: maxAdaptiveJitterTargetMs,
            maxJitterMaxMs: maxAdaptiveJitterMaxMs
        )
    }

    private func recordPacketArrival(now: TimeInterval) {
        if let lastAcceptedPacketArrivalAt {
            let intervalMs = max(0, (now - lastAcceptedPacketArrivalAt) * 1_000)
            arrivalIntervalStats.append(intervalMs)
        }
        lastAcceptedPacketArrivalAt = now
    }

    private func adaptJitterIfNeeded(
        window: ReceiverTelemetryCounters,
        playback: IOSRealtimeMediaAudioPlayer.PlaybackTelemetrySnapshot?
    ) {
        let scheduleLeadMs = playback.map { $0.queuedMs - $0.targetQueuedMs } ?? 0
        let queuedMs = playback?.queuedMs ?? 0
        let targetQueuedMs = playback?.targetQueuedMs ?? 0
        let rebuffer = playback?.rebufferEvents ?? 0
        let underflow = playback?.underflowEvents ?? 0
        let evictionRatio = window.received > 0
            ? Double(window.jitterEvicted) / Double(window.received)
            : 0
        let lowQueueThresholdMs = min(600, max(180, targetQueuedMs * 0.25))
        let severeQueueThresholdMs = min(300, max(80, targetQueuedMs * 0.12))
        let queuePressure = playback != nil
            && scheduleLeadMs < -60
            && queuedMs <= lowQueueThresholdMs
        let severeQueuePressure = playback != nil
            && scheduleLeadMs < -100
            && queuedMs <= severeQueueThresholdMs
        let severePressure = rebuffer > 0 || severeQueuePressure
        let pressure = severePressure
            || underflow > 0
            || window.jitterEvicted > 0
            || evictionRatio >= 0.02
            || queuePressure
        let oldTarget = effectiveJitterTargetMs
        let oldMax = effectiveJitterMaxMs
        if pressure {
            stableJitterWindowCount = 0
            let targetStep = severePressure ? 40 : 20
            let maxStep = severePressure ? 80 : 40
            effectiveJitterTargetMs = min(maxAdaptiveJitterTargetMs, effectiveJitterTargetMs + targetStep)
            effectiveJitterMaxMs = min(maxAdaptiveJitterMaxMs, max(effectiveJitterMaxMs + maxStep, effectiveJitterTargetMs + 220))
            lastJitterAdaptationReason = "pressure:jitterEvicted=\(window.jitterEvicted),evictRatio=\(String(format: "%.3f", evictionRatio)),underflow=\(underflow),rebuffer=\(rebuffer),queuedMs=\(Int(queuedMs.rounded())),targetQueuedMs=\(Int(targetQueuedMs.rounded())),scheduleLeadMs=\(Int(scheduleLeadMs.rounded()))"
        } else {
            stableJitterWindowCount += 1
            if stableJitterWindowCount >= 6 {
                effectiveJitterTargetMs = max(minimumAdaptiveJitterTargetMs, effectiveJitterTargetMs - 20)
                effectiveJitterMaxMs = max(minimumAdaptiveJitterMaxMs, effectiveJitterMaxMs - 40)
                stableJitterWindowCount = 0
                lastJitterAdaptationReason = "stable-decay"
            } else {
                lastJitterAdaptationReason = "stable-hold:\(stableJitterWindowCount)"
            }
        }
        effectiveJitterMaxMs = min(
            maxAdaptiveJitterMaxMs,
            max(effectiveJitterMaxMs, effectiveJitterTargetMs + 2 * profile.frameDurationMs)
        )
        guard oldTarget != effectiveJitterTargetMs || oldMax != effectiveJitterMaxMs else { return }
        jitterBuffer = jitterBuffer.reconfigure(
            targetDelayMs: orderingJitterTargetMs,
            maxDelayMs: orderingJitterMaxMs
        )
        SkyBridgeLogger.shared.info(
            "🎧 PQC media audio jitter adapted: targetMs=\(effectiveJitterTargetMs) maxMs=\(effectiveJitterMaxMs) orderingTargetMs=\(orderingJitterTargetMs) orderingMaxMs=\(orderingJitterMaxMs) reason=\(lastJitterAdaptationReason)"
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
        let arrivalStats = arrivalIntervalStats.snapshot(reset: true)
        adaptJitterIfNeeded(window: window, playback: playback)
        let queuedMs = playback.map { String(format: "%.0f", $0.queuedMs) } ?? "-"
        let targetQueuedMs = playback.map { String(format: "%.0f", $0.targetQueuedMs) } ?? "-"
        let capacityMs = playback.map { String(format: "%.0f", $0.capacityMs) } ?? "-"
        let underflow = playback?.underflowEvents ?? 0
        let overflow = playback?.overflowEvents ?? 0
        let rebuffer = playback?.rebufferEvents ?? 0
        let bridgedUnderflow = playback?.bridgedUnderflowFrames ?? 0
        let startupSilenceFrames = playback?.startupSilenceFrames ?? 0
        let renderedFrames = playback?.renderedFrames ?? 0
        let primed = playback?.isPrimed ?? false
        let engineRunning = playback?.isEngineRunning ?? false
        let scheduleLeadMs = playback.map { String(format: "%.0f", $0.queuedMs - $0.targetQueuedMs) } ?? "-"
        let audioArrivalP50Ms = arrivalStats.map { String(format: "%.0f", $0.p50Ms) } ?? "-"
        let audioArrivalP95Ms = arrivalStats.map { String(format: "%.0f", $0.p95Ms) } ?? "-"
        let audioArrivalMaxMs = arrivalStats.map { String(format: "%.0f", $0.maxMs) } ?? "-"
        let audioJitterBufferDepthMs = jitterBuffer.bufferedFrameCount * profile.frameDurationMs
        let windowLate = window.replayRejected + window.jitterLate + window.jitterDuplicate + window.jitterEvicted
        let windowArrivals = window.received + windowLate
        let lateRatio = windowArrivals > 0 ? Double(windowLate) / Double(windowArrivals) : 0
        let plcRatio = window.played > 0 ? Double(window.plcFrames) / Double(window.played) : 0
        let lateRatioText = String(format: "%.3f", lateRatio)
        let plcRatioText = String(format: "%.3f", plcRatio)
        let audioPath = playback?.audioPath ?? "pqc-opus-source-node-ring"
        let probable: String? = {
            if played > 0 && window.received == 0 {
                return "zero-rx-after-playback"
            }
            if window.received > 0 && window.decoded == 0 {
                return "rx-decode-stalled"
            }
            if window.decoded > 0 && window.played == 0 {
                return "rx-playback-stalled"
            }
            if window.datagramsSeen > 0 && window.received == 0 {
                if window.sessionHashRejected > 0 {
                    return "session-hash-rejected"
                }
                if window.authRejected > 0 {
                    return "auth-decrypt-rejected"
                }
                if window.sourceRejected > 0 {
                    return "source-rejected"
                }
                if window.replayRejected > 0 {
                    return "replay-rejected"
                }
            }
            return nil
        }()
        let probableSuffix = probable.map { " probable=\($0)" } ?? ""
        SkyBridgeLogger.shared.info(
            "📈 PQC media audio rx: datagrams=\(window.datagramsSeen) recv=\(window.received) decode=\(window.decoded) play=\(window.played) rejected=\(window.rejected) recvTotal=\(received) decodeTotal=\(decoded) playTotal=\(played) authRejected=\(window.authRejected) sessionHashRejected=\(window.sessionHashRejected) replayRejected=\(window.replayRejected) jitterLate=\(window.jitterLate) jitterDuplicate=\(window.jitterDuplicate) jitterEvicted=\(window.jitterEvicted) jitterGapStop=\(window.jitterGapStopped) plc=\(window.plcFrames) sourceReject=\(window.sourceRejected) sourceMigrate=\(window.sourceMigrated) playbackDrop=\(window.playbackDropped) jitter=\(jitterBuffer.bufferedFrameCount) audioJitterBufferDepthMs=\(audioJitterBufferDepthMs) codec=opus activeCodec=opus audioPath=\(audioPath) queuedMs=\(queuedMs) targetQueuedMs=\(targetQueuedMs) capacityMs=\(capacityMs) effectiveJitterTargetMs=\(effectiveJitterTargetMs) effectiveJitterMaxMs=\(effectiveJitterMaxMs) orderingJitterTargetMs=\(orderingJitterTargetMs) orderingJitterMaxMs=\(orderingJitterMaxMs) adaptationReason=\(lastJitterAdaptationReason) scheduleLeadMs=\(scheduleLeadMs) audioArrivalP50Ms=\(audioArrivalP50Ms) audioArrivalP95Ms=\(audioArrivalP95Ms) audioArrivalMaxMs=\(audioArrivalMaxMs) primed=\(primed) engineRunning=\(engineRunning) underflow=\(underflow) rebuffer=\(rebuffer) bridgedUnderflow=\(bridgedUnderflow) overflow=\(overflow) startupSilenceFrames=\(startupSilenceFrames) renderedFrames=\(renderedFrames) plcRatio=\(plcRatioText) lateRatio=\(lateRatioText)\(probableSuffix)"
        )
        SkyBridgeSmokeTraceWriter.append(
            "audio-rx audioRxDatagrams=\(window.datagramsSeen) audioRxRecv=\(window.received) audioRxDecoded=\(window.decoded) audioRxPlayed=\(window.played) recvTotal=\(received) decodeTotal=\(decoded) playTotal=\(played) rejected=\(window.rejected) authRejected=\(window.authRejected) sessionHashRejected=\(window.sessionHashRejected) replayRejected=\(window.replayRejected) jitterLate=\(window.jitterLate) jitterDuplicate=\(window.jitterDuplicate) jitterEvicted=\(window.jitterEvicted) jitterGapStop=\(window.jitterGapStopped) plcFrames=\(window.plcFrames) plcRatio=\(plcRatioText) audioJitterBufferDepthMs=\(audioJitterBufferDepthMs) queuedMs=\(queuedMs) targetQueuedMs=\(targetQueuedMs) capacityMs=\(capacityMs) scheduleLeadMs=\(scheduleLeadMs) audioArrivalP50Ms=\(audioArrivalP50Ms) audioArrivalP95Ms=\(audioArrivalP95Ms) audioArrivalMaxMs=\(audioArrivalMaxMs) sourceReject=\(window.sourceRejected) sourceMigrate=\(window.sourceMigrated) engineRunning=\(engineRunning) renderedFrames=\(renderedFrames) underflow=\(underflow) rebuffer=\(rebuffer) bridgedUnderflow=\(bridgedUnderflow) startupSilenceFrames=\(startupSilenceFrames) playbackDrop=\(window.playbackDropped)\(probableSuffix)"
        )
        var diagnosticFields: [String: Any] = [
            "kind": "audioRxRolling",
            "session": sessionId,
            "session_id": sessionId,
            "audioRxDatagrams": window.datagramsSeen,
            "audioRxRecv": window.received,
            "audioRxDecoded": window.decoded,
            "audioRxPlayed": window.played,
            "recvTotal": received,
            "decodeTotal": decoded,
            "playTotal": played,
            "rejected": window.rejected,
            "authRejected": window.authRejected,
            "sessionHashRejected": window.sessionHashRejected,
            "replayRejected": window.replayRejected,
            "jitterLate": window.jitterLate,
            "jitterDuplicate": window.jitterDuplicate,
            "jitterEvicted": window.jitterEvicted,
            "jitterGapStopped": window.jitterGapStopped,
            "plcFrames": window.plcFrames,
            "plcRatio": plcRatio,
            "sourceReject": window.sourceRejected,
            "sourceMigrate": window.sourceMigrated,
            "engineRunning": engineRunning,
            "renderedFrames": renderedFrames,
            "underflow": underflow,
            "rebuffer": rebuffer,
            "effectiveJitterTargetMs": effectiveJitterTargetMs,
            "effectiveJitterMaxMs": effectiveJitterMaxMs,
            "orderingJitterTargetMs": orderingJitterTargetMs,
            "orderingJitterMaxMs": orderingJitterMaxMs,
            "adaptationReason": lastJitterAdaptationReason,
            "audioQueuedMs": playback.map { $0.queuedMs } ?? NSNull(),
            "audioTargetQueuedMs": playback.map { $0.targetQueuedMs } ?? NSNull(),
            "audioCapacityMs": playback.map { $0.capacityMs } ?? NSNull(),
            "scheduleLeadMs": playback.map { $0.queuedMs - $0.targetQueuedMs } ?? NSNull(),
            "audioJitterBufferDepthMs": audioJitterBufferDepthMs,
            "bridgedUnderflow": bridgedUnderflow,
            "startupSilenceFrames": startupSilenceFrames,
            "playbackDrop": window.playbackDropped
        ]
        if let arrivalStats {
            diagnosticFields["audioArrivalP50Ms"] = arrivalStats.p50Ms
            diagnosticFields["audioArrivalP95Ms"] = arrivalStats.p95Ms
            diagnosticFields["audioArrivalMaxMs"] = arrivalStats.maxMs
        }
        if let probable {
            diagnosticFields["probable"] = probable
        }
        SkyBridgeSmokeTraceWriter.appendMediaDiagnostic(
            diagnosticFields
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

private struct RollingMillisecondStats {
    struct Snapshot: Sendable {
        let p50Ms: Double
        let p95Ms: Double
        let maxMs: Double
    }

    private let maxSamples: Int
    private var samples: [Double] = []

    init(maxSamples: Int) {
        self.maxSamples = max(1, maxSamples)
    }

    mutating func append(_ sample: Double) {
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    mutating func snapshot(reset: Bool) -> Snapshot? {
        guard !samples.isEmpty else { return nil }
        let sortedSamples = samples.sorted()
        let snapshot = Snapshot(
            p50Ms: percentile(0.50, in: sortedSamples),
            p95Ms: percentile(0.95, in: sortedSamples),
            maxMs: sortedSamples.last ?? 0
        )
        if reset {
            samples.removeAll(keepingCapacity: true)
        }
        return snapshot
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    private func percentile(_ percentile: Double, in sortedSamples: [Double]) -> Double {
        guard !sortedSamples.isEmpty else { return 0 }
        let clampedPercentile = min(1, max(0, percentile))
        let index = Int((Double(sortedSamples.count - 1) * clampedPercentile).rounded(.up))
        return sortedSamples[min(index, sortedSamples.count - 1)]
    }
}
