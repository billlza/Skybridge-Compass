#if os(macOS)
import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import os
import SkyBridgeProtocolCore

public enum CoreAudioOpusOutputError: Error, Equatable, Sendable {
    case invalidOwner, wrongOwner, invalidState, invalidFormat, invalidSourceCount, busy
    case authorizationLost, insufficientPrefill, endpointChanged, engineStopped, underrun
    case invalidCallback, invalidTimeline, timedOut, cleanupUnconfirmed
    case native(OSStatus)
}

public struct CoreAudioOpusOutputSnapshot: Sendable, Equatable {
    public enum State: Sendable, Equatable { case idle, prepared, running, draining, completed, failed, closing, closed }
    public let state: State
    public let acceptedSourceFrames: UInt64
    public let playedSourceFrames: UInt64
    public let pendingBuffers: Int
    public let failure: String?
    public let cleanupPending: Bool
}

struct CoreAudioOpusDriverStatus: Sendable {
    let endpointCurrent: Bool
    let engineRunning: Bool
    let playerPlaying: Bool
    /// Nil means no sample timeline is available. A negative value can precede source frame zero
    /// while the engine starts; neither observation establishes source progress.
    let renderedSourceFrame: Int64?
}

/// Calls are serialized by the output owner. Callbacks only enter its separate bounded ledger.
protocol CoreAudioOpusDriver: Sendable {
    func schedule(_ pcm16LE: Data, completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) throws
    func start() throws
    func status() throws -> CoreAudioOpusDriverStatus
    func close() throws
}

/// Explicit compatible output for decoded Opus only: 48 kHz PCM16 mono/stereo becomes exact
/// Float32 input to the system mixer. Device conversion/mixing is allowed here. This class is
/// never used as a fallback for CoreAudioExactPcmOutput and grants no playback permission.
///
/// Retain until close reports released, including after a failed stream. The mandatory effect
/// check must inspect captured atomic/clock authorization, without reentering this owner.
public final class CoreAudioOpusOutput: Sendable {
    /// Legacy profile constants retained for existing callers. An owned output always uses
    /// its immutable offered buffering profile, including the separate buffered-file policy.
    public static let capacityFrames = AudioStreamingOpusBuffering.legacy.capacityFrames
    public static let minimumPrefillFrames = AudioStreamingOpusBuffering.legacy.minimumPrefillFrames
    private struct Failure: Sendable {
        let cause: any Error
        let diagnostic: String
    }
    private struct State: Sendable {
        var phase = CoreAudioOpusOutputSnapshot.State.idle
        var driver: (any CoreAudioOpusDriver)?
        var channels = 0
        var expected: UInt64?
        var failure: Failure?
        var cleanupFailures: [String] = []
        var deadline: ContinuousClock.Instant?
        var lastRenderFrame: Int64?
        var currentRenderFrame: Int64?
        var observedRenderFrame: Int64?
    }
    public let ownerID: UUID
    public let buffering: AudioStreamingOpusBuffering
    private let requireAuthorization: @Sendable () throws -> Void
    private let makeDriver: @Sendable (String, Int) throws -> any CoreAudioOpusDriver
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let ledger: CoreAudioOpusOutputLedger
    private let monitor: DispatchSourceTimer?

    public convenience init(ownerID: UUID, buffering: AudioStreamingOpusBuffering = .legacy,
                            requireAuthorization: @escaping @Sendable () throws -> Void) throws {
        try self.init(ownerID: ownerID, buffering: buffering, requireAuthorization: requireAuthorization,
            makeDriver: { try NativeCoreAudioOpusDriver(endpointUID: $0, channels: $1) }, automaticMonitoring: true)
    }

    init(ownerID: UUID, buffering: AudioStreamingOpusBuffering = .legacy,
         requireAuthorization: @escaping @Sendable () throws -> Void,
         makeDriver: @escaping @Sendable (String, Int) throws -> any CoreAudioOpusDriver,
         automaticMonitoring: Bool, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) throws {
        guard ownerID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw CoreAudioOpusOutputError.invalidOwner
        }
        self.ownerID = ownerID; self.requireAuthorization = requireAuthorization
        self.buffering = buffering; ledger = CoreAudioOpusOutputLedger(buffering: buffering)
        self.makeDriver = makeDriver; self.now = now
        monitor = automaticMonitoring ? DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SkyBridge Opus Output")) : nil
        monitor?.setEventHandler { [weak self] in self?.poll() }
        monitor?.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        monitor?.resume()
    }

    deinit {
        monitor?.cancel(); ledger.retire()
        state.withLock { value in
            // Correct callers retain this owner until explicit cleanup. Do not leave a player
            // running if an owner is dropped; an unobserved destructor is never a cleanup receipt.
            if let driver = value.driver {
                do { try driver.close() }
                catch { Logger(subsystem: "com.skybridge.audio", category: "opus-output").error("Dropped output cleanup failed: \(String(describing: error), privacy: .public)") }
            }
        }
    }

    public func prepare(endpointUID: String, channels: UInt8) throws {
        try state.withLock { value in
            guard value.phase == .idle else { throw CoreAudioOpusOutputError.invalidState }
            guard !endpointUID.isEmpty, endpointUID.utf8.count <= 4096, (1...2).contains(channels) else {
                throw CoreAudioOpusOutputError.invalidFormat
            }
            do {
                try requireAuthorization()
                value.driver = try makeDriver(endpointUID, Int(channels))
                try requireAuthorization()
                guard try value.driver?.status().endpointCurrent == true else { throw CoreAudioOpusOutputError.endpointChanged }
                value.channels = Int(channels); value.phase = .prepared
                value.deadline = now().advanced(by: .seconds(30))
            } catch { fail(&value, error); throw error }
        }
    }

    public func enqueue(_ pcm16LE: Data, firstSourceFrame: UInt64, ownerID: UUID) throws {
        try requireOwner(ownerID)
        try state.withLock { value in
            if let failure = value.failure { throw failure.cause }
            guard value.phase == .prepared || value.phase == .running, value.expected == nil, let driver = value.driver else {
                throw CoreAudioOpusOutputError.invalidState
            }
            do {
                try validate(&value)
                let stride = value.channels * 2
                guard !pcm16LE.isEmpty, pcm16LE.count % stride == 0, pcm16LE.count / stride <= 960 else {
                    throw CoreAudioOpusOutputError.invalidFormat
                }
                let frames = UInt64(pcm16LE.count / stride)
                let token = try ledger.reserve(first: firstSourceFrame, frames: frames)
                try requireAuthorization()
                try driver.schedule(pcm16LE) { [ledger] kind in ledger.played(token, valid: kind == .dataPlayedBack) }
                try ledger.commit(token)
            } catch CoreAudioOpusReservationError.full { throw CoreAudioOpusOutputError.busy }
            catch { fail(&value, error); throw error }
        }
    }

    public func start(ownerID: UUID) throws {
        try requireOwner(ownerID)
        try state.withLock { value in
            if let failure = value.failure { throw failure.cause }
            guard value.phase == .prepared, let driver = value.driver else { throw CoreAudioOpusOutputError.invalidState }
            let counters = ledger.snapshot()
            guard counters.accepted >= buffering.minimumPrefillFrames || (value.expected != nil && counters.accepted > 0) else {
                throw CoreAudioOpusOutputError.insufficientPrefill
            }
            do {
                try validate(&value)
                ledger.started()
                try requireAuthorization(); try driver.start()
                value.phase = value.expected == nil ? .running : .draining
                value.deadline = now().advanced(by: .seconds(value.expected == nil ? 2 : 5))
                try validate(&value)
            } catch { fail(&value, error); throw error }
        }
    }

    public func finishInput(ownerID: UUID, expectedSourceFrames: UInt64) throws {
        try requireOwner(ownerID)
        try state.withLock { value in
            if let failure = value.failure { throw failure.cause }
            guard value.phase == .prepared || value.phase == .running, value.expected == nil else { throw CoreAudioOpusOutputError.invalidState }
            do {
                try validate(&value)
                guard expectedSourceFrames > 0, expectedSourceFrames == ledger.snapshot().accepted else {
                    throw CoreAudioOpusOutputError.invalidSourceCount
                }
                value.expected = expectedSourceFrames
                if value.phase == .running { value.phase = .draining; value.deadline = now().advanced(by: .seconds(5)) }
            } catch { fail(&value, error); throw error }
        }
    }

    public func snapshot() -> CoreAudioOpusOutputSnapshot {
        poll()
        return state.withLock { snapshot($0) }
    }

    /// Playback control must preserve the typed terminal cause even when no new packet arrives.
    /// The nonthrowing snapshot remains available for diagnostics after failure or cleanup.
    func checkedSnapshot(ownerID: UUID) throws -> CoreAudioOpusOutputSnapshot {
        try requireOwner(ownerID)
        poll()
        return try state.withLock { value in
            if let failure = value.failure { throw failure.cause }
            return snapshot(value)
        }
    }

    private func snapshot(_ value: State) -> CoreAudioOpusOutputSnapshot {
        let count = ledger.snapshot()
        return .init(state: value.phase, acceptedSourceFrames: count.accepted, playedSourceFrames: count.played,
            pendingBuffers: count.pending, failure: value.failure?.diagnostic, cleanupPending: value.driver != nil)
    }

    public func close(ownerID: UUID) throws -> AudioOutputCleanupOutcome {
        try requireOwner(ownerID)
        return state.withLock { value in
            ledger.retire() // stop also invokes dataPlayedBack: fence it before touching native state.
            value.phase = .closing; monitor?.cancel()
            cleanup(&value)
            if value.driver == nil { value.phase = .closed }
            return .init(state: value.driver == nil ? .released : .pending,
                diagnostics: value.cleanupFailures, preservedExternalChanges: [])
        }
    }

    private func requireOwner(_ id: UUID) throws { guard id == ownerID else { throw CoreAudioOpusOutputError.wrongOwner } }
    private func poll() {
        state.withLock { value in
            guard value.phase == .prepared || value.phase == .running || value.phase == .draining else { return }
            do {
                try validate(&value)
                if value.phase == .draining, let expected = value.expected, ledger.snapshot().played == expected,
                   let position = value.currentRenderFrame, position >= 0, UInt64(position) >= expected {
                    ledger.retire(); cleanup(&value)
                    guard value.driver == nil, value.cleanupFailures.isEmpty else { throw CoreAudioOpusOutputError.cleanupUnconfirmed }
                    value.phase = .completed; monitor?.cancel()
                }
            } catch { fail(&value, error) }
        }
    }
    private func validate(_ value: inout State) throws {
        try requireAuthorization()
        let count = ledger.snapshot()
        if count.invalid { throw CoreAudioOpusOutputError.invalidCallback }
        guard let driver = value.driver else { throw CoreAudioOpusOutputError.invalidState }
        let native = try driver.status()
        value.observedRenderFrame = native.renderedSourceFrame
        guard native.endpointCurrent else { throw CoreAudioOpusOutputError.endpointChanged }
        if let deadline = value.deadline, now() >= deadline { throw CoreAudioOpusOutputError.timedOut }
        guard value.phase == .running || value.phase == .draining else { return }
        guard native.engineRunning, native.playerPlaying else { throw CoreAudioOpusOutputError.engineStopped }
        value.currentRenderFrame = nil
        if let position = native.renderedSourceFrame {
            if position < 0 {
                // AVAudioPlayerNode can report pre-start render times (observed -1024, -512).
                // Keep the original bounded startup wait; do not turn them into zero progress.
                guard value.lastRenderFrame == nil, count.played == 0 else { throw CoreAudioOpusOutputError.invalidTimeline }
                return
            }
            guard value.lastRenderFrame.map({ position >= $0 }) ?? true else { throw CoreAudioOpusOutputError.invalidTimeline }
            if value.expected == nil, UInt64(position) > count.accepted { throw CoreAudioOpusOutputError.underrun }
            if value.phase == .running, value.lastRenderFrame.map({ position > $0 }) ?? true {
                value.deadline = now().advanced(by: .seconds(2))
            }
            value.lastRenderFrame = position; value.currentRenderFrame = position
        }
    }
    private func fail(_ value: inout State, _ error: any Error) {
        if value.failure == nil {
            // A monitor can retire the native player before the next producer
            // call arrives. Keep its typed cause as well as stable snapshot text;
            // later calls must not replace it with a phase-related invalidState.
            value.failure = Failure(cause: error, diagnostic: String(describing: error))
            let code = AudioPlaybackFailureDiagnostic.label(for: error)
            let counters = ledger.snapshot()
            let phase = String(describing: value.phase)
            let rendered = value.observedRenderFrame.map(String.init) ?? "unavailable"
            // Once per failure, before stop callbacks retire the queue. Only closed error
            // codes, state and frame counts are public; never file/device/account values.
            Logger(subsystem: "com.skybridge.audio", category: "opus-output").error(
                "Opus output failure cause=\(code, privacy: .public) phase=\(phase, privacy: .public) accepted=\(counters.accepted, privacy: .public) played=\(counters.played, privacy: .public) pending=\(counters.pending, privacy: .public) rendered=\(rendered, privacy: .public)")
        }
        value.phase = .failed; ledger.retire(); cleanup(&value)
        monitor?.cancel()
    }
    private func cleanup(_ value: inout State) {
        guard let driver = value.driver else { return }
        do { try driver.close(); value.driver = nil }
        catch {
            let text = String(describing: error)
            if !value.cleanupFailures.contains(text) { value.cleanupFailures.append(text) }
        }
    }
}

private enum CoreAudioOpusReservationError: Error { case full }

private final class CoreAudioOpusOutputLedger: Sendable {
    struct Snapshot { let accepted: UInt64; let played: UInt64; let pending: Int; let invalid: Bool }
    private struct Buffer: Sendable { let id: UInt64; let first: UInt64; let end: UInt64; var committed = false, done = false }
    private struct State: Sendable {
        var active = true, started = false, invalid = false
        var accepted: UInt64 = 0, played: UInt64 = 0, sequence: UInt64 = 0
        var buffers: [Buffer] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let buffering: AudioStreamingOpusBuffering
    init(buffering: AudioStreamingOpusBuffering) { self.buffering = buffering }
    func reserve(first: UInt64, frames: UInt64) throws -> UInt64 {
        try state.withLock { value in
            guard value.active, !value.invalid, first == value.accepted, frames > 0,
                  frames <= UInt64(Int64.max) - value.accepted else { throw CoreAudioOpusOutputError.invalidSourceCount }
            guard value.buffers.count < Int(buffering.windowPackets),
                  value.accepted - value.played + frames <= buffering.capacityFrames else {
                throw CoreAudioOpusReservationError.full
            }
            value.sequence += 1
            value.buffers.append(.init(id: value.sequence, first: first, end: first + frames))
            return value.sequence
        }
    }
    func commit(_ token: UInt64) throws {
        try state.withLock { value in
            guard value.active, !value.invalid, let index = value.buffers.firstIndex(where: { $0.id == token }),
                  !value.buffers[index].committed, value.buffers[index].first == value.accepted else {
                throw CoreAudioOpusOutputError.invalidCallback
            }
            value.accepted = value.buffers[index].end; value.buffers[index].committed = true
            Self.advance(&value)
        }
    }
    func started() { state.withLock { $0.started = true } }
    func played(_ token: UInt64, valid: Bool) {
        state.withLock { value in
            guard value.active else { return }
            guard valid, value.started, let index = value.buffers.firstIndex(where: { $0.id == token }), !value.buffers[index].done else {
                value.invalid = true; return
            }
            value.buffers[index].done = true
            Self.advance(&value)
        }
    }
    private static func advance(_ value: inout State) {
        while let first = value.buffers.first, first.done && first.committed { value.played = value.buffers.removeFirst().end }
    }
    func retire() { state.withLock { $0.active = false } }
    func snapshot() -> Snapshot { state.withLock { .init(accepted: $0.accepted, played: $0.played, pending: $0.buffers.count, invalid: $0.invalid) } }
}

private final class NativeCoreAudioOpusDriver: CoreAudioOpusDriver {
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let endpoint: AudioDeviceID
    private let endpointUID: String
    private let channels: Int

    init(endpointUID: String, channels: Int) throws {
        self.endpointUID = endpointUID; self.channels = channels
        endpoint = try CoreAudioExactPcmEndpointInspector.resolve(endpointUID)
        engine = AVAudioEngine(); player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels)) else {
            throw CoreAudioOpusOutputError.invalidFormat
        }
        self.format = format
        guard let unit = engine.outputNode.audioUnit else { throw CoreAudioOpusOutputError.invalidFormat }
        var selected = endpoint
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size)))
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        guard try status().endpointCurrent else { throw CoreAudioOpusOutputError.endpointChanged }
    }
    func schedule(_ pcm16LE: Data, completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) throws {
        let frames = pcm16LE.count / (channels * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let planes = buffer.floatChannelData else { throw CoreAudioOpusOutputError.invalidFormat }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16LE.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * 2
                    let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                    planes[channel][frame] = Float(sample) / 32768
                }
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: completion)
    }
    func start() throws {
        try engine.start()
        if #available(macOS 27.0, *) { try player.playAudio() } else { player.play() }
    }
    func status() throws -> CoreAudioOpusDriverStatus {
        guard let unit = engine.outputNode.audioUnit else { throw CoreAudioOpusOutputError.invalidFormat }
        var selected = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try Self.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, &size))
        let uid = try CoreAudioExactPcmEndpointInspector.string(endpoint, kAudioDevicePropertyDeviceUID)
        let time = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }
        return .init(endpointCurrent: size == UInt32(MemoryLayout<AudioDeviceID>.size) && selected == endpoint && uid == endpointUID,
            engineRunning: engine.isRunning && !engine.isInManualRenderingMode, playerPlaying: player.isPlaying,
            renderedSourceFrame: time?.isSampleTimeValid == true ? time?.sampleTime : nil)
    }
    func close() throws {
        player.stop(); engine.stop()
        guard !player.isPlaying, !engine.isRunning else { throw CoreAudioOpusOutputError.cleanupUnconfirmed }
    }
    private static func check(_ status: OSStatus) throws { if status != noErr { throw CoreAudioOpusOutputError.native(status) } }
}
#endif
