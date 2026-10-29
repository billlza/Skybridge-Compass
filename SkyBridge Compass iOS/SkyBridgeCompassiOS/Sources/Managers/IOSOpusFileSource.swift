import Foundation
import SkyBridgeAudioFile
import SkyBridgeOpus
import SkyBridgeProtocolCore
import os

enum IOSOpusFileSourceError: Error, Equatable, Sendable {
    case busy, notPrepared, alreadyStarted, stopped, unsupportedFormat, unsupportedLayout
    case invalidDuration, sourceChanged, invalidProgress, queueCapacity, cleanupTimedOut, invalidCleanupTimeout
}

struct IOSOpusFilePlan: Sendable {
    let originalFormat: AudioStreamingPCMFormat
    let conversionInputFormat: AudioStreamingPCMFormat
    let sourceFrames: UInt64
    let convertedFrames: UInt64
    let opus: AudioStreamingOpusFormat
    let interpretsLegacyWaveLayout: Bool
}

struct IOSOpusFileCompletion: Sendable {
    let conversion: AudioCompatiblePCMCompletion
    let encoding: SkyBridgeOpusEncodeCompletion
}

struct IOSOpusFileSnapshot: Sendable {
    let sourceFramesRead: UInt64
    let returnedPackets: UInt64
    let queuedPackets: Int
    let maximumQueuedPackets: Int
    let sourceVerified: Bool
    let resourcesReleased: Bool
    let cleanupPending: Bool
}

/// Owns the selected file immediately, but constructs the converter/encoder only in start().
/// The sender calls start only after authenticated acceptance/output readiness. Pulling one
/// packet advances at most one bounded input step at a time; there is no speculative producer.
/// This owner grants no authority and never claims that encoded packets reached a peer/DAC.
actor IOSOpusFileSource {
    /// The existing 128 kbps profile leaves more refill margin on iOS CoC links.
    /// Higher supported profiles remain explicit; this does not change strict file transport.
    static let defaultBluetoothBitrate: UInt32 = 128_000
    static let maximumQueuedPackets = 80
    nonisolated let fileName: String
    private nonisolated let gate: IOSOpusFileEffectGate
    private let file: IOSPreparedAudioFile
    private let bitrate: UInt32
    private var plan: IOSOpusFilePlan?
    private var content: IOSPreparedAudioFile.Content?
    private var validatedFlac: AudioValidatedFlacFile?
    private var flac: AudioFlacPCMReadSession?
    private var converter: AudioCompatiblePCMConverter?
    private var encoder: SkyBridgeOpusStreamEncoder?
    private var completion: IOSOpusFileCompletion?
    private var pending: [SkyBridgeOpusEncodedPacket] = []
    private var pendingIndex = 0
    private var maximumPending = 0
    private var inputPosition: UInt64 = 0
    private var returnedPackets: UInt64 = 0
    private var attemptedPreparation = false
    private var started = false
    private var sealed = false
    private var fileClosed = false
    private var preparing: Task<IOSOpusFilePlan, Error>?
    private var reading: Task<SkyBridgeOpusEncodedPacket?, Error>?
    private var closing: CloseOperation?

    private struct CloseOperation: Sendable {
        let id: UUID
        let task: Task<Void, Error>
        let completed: OSAllocatedUnfairLock<Bool>
    }

    init(url: URL, bitrate: UInt32 = IOSOpusFileSource.defaultBluetoothBitrate,
         requireEffectAuthorization: @escaping @Sendable () throws -> Void) throws {
        guard [128_000, 192_000, 256_000].contains(bitrate) else { throw AudioStreamingWireError.invalidFormat }
        file = try IOSPreparedAudioFile(url: url)
        fileName = url.lastPathComponent; self.bitrate = bitrate
        gate = IOSOpusFileEffectGate(authorize: requireEffectAuthorization)
    }

    /// Pure captured-state/authority checks: safe in a synchronous native transport write gate.
    nonisolated func requireEffectCurrent() throws { try gate.check() }
    nonisolated func cancel() { gate.fail(IOSOpusFileSourceError.stopped) }

    func prepare() async throws -> IOSOpusFilePlan {
        try gate.check()
        if let plan { return plan }
        guard preparing == nil, !attemptedPreparation else { throw IOSOpusFileSourceError.busy }
        attemptedPreparation = true
        let task = Task { try await self.prepareFile() }; preparing = task
        defer { preparing = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { [gate] in
                gate.fail(CancellationError()); task.cancel()
            }
            try gate.check(); return result
        } catch { gate.fail(error); throw gate.failure ?? error }
    }

    /// Returns the actual native pre-skip for the subsequent opusConfiguration message.
    /// No PCM is read or encoded here; the unique sending operation owns further pulls.
    func start() throws -> SkyBridgeOpusStreamFormat {
        try gate.check()
        guard let plan, content != nil, preparing == nil else { throw IOSOpusFileSourceError.notPrepared }
        guard !started else { throw IOSOpusFileSourceError.alreadyStarted }
        started = true
        do {
            if let validatedFlac { flac = try AudioFlacPCMReadSession(file: validatedFlac) }
            let gate = self.gate
            converter = try AudioCompatiblePCMConverter(sourceFormat: plan.conversionInputFormat,
                sourceFrames: plan.sourceFrames, requireAuthorization: { try gate.check() })
            let encoder = try SkyBridgeOpusStreamEncoder(channels: Int(plan.opus.channels), bitrate: Int(plan.opus.bitrate),
                expectedSourceFrames: plan.convertedFrames, requireAuthorization: { try gate.check() })
            self.encoder = encoder
            try gate.check(); return encoder.format
        } catch { gate.fail(error); throw gate.failure ?? error }
    }

    /// Nil means verified source EOF, completed conversion/encoding, confirmed file cleanup,
    /// and a drained packet queue. Errors, closure and temporary starvation never return nil.
    func nextPacket() async throws -> SkyBridgeOpusEncodedPacket? {
        try gate.check()
        guard started else { throw IOSOpusFileSourceError.notPrepared }
        guard reading == nil else { throw IOSOpusFileSourceError.busy }
        let task = Task { try await self.producePacket() }; reading = task
        defer { reading = nil }
        do {
            let packet = try await withTaskCancellationHandler { try await task.value } onCancel: { [gate] in
                gate.fail(CancellationError()); task.cancel()
            }
            try gate.check()
            if packet != nil { returnedPackets += 1 }
            return packet
        } catch { gate.fail(error); throw gate.failure ?? error }
    }

    func completedEncoding() throws -> IOSOpusFileCompletion {
        try gate.check()
        guard sealed, fileClosed, pendingIndex == pending.count, let completion,
              returnedPackets == completion.encoding.packetCount else { throw IOSOpusFileSourceError.invalidProgress }
        return completion
    }

    /// Retire effects synchronously, then await the same retained cleanup operation. Timing out
    /// does not detach/drop the file owner or release its security scope while work is active.
    /// A later call rejoins that operation, or retries its actual failed file close.
    func close(timeout: Duration = .seconds(2)) async throws {
        guard timeout > .zero, timeout <= .seconds(5) else { throw IOSOpusFileSourceError.invalidCleanupTimeout }
        gate.retire()
        if fileClosed, preparing == nil, reading == nil, converter == nil, encoder == nil, flac == nil {
            pending.removeAll(); pendingIndex = 0; return
        }
        let operation: CloseOperation
        if let closing { operation = closing }
        else {
            let prepare = preparing, read = reading
            prepare?.cancel(); read?.cancel()
            let completed = OSAllocatedUnfairLock(initialState: false)
            let task = Task.detached(priority: .utility) {
                defer { completed.withLock { $0 = true } }
                try await self.finishClose(preparing: prepare, reading: read)
            }
            operation = CloseOperation(id: UUID(), task: task, completed: completed)
            closing = operation
        }
        // Cleanup must remain joinable even when the sending task is already cancelled.
        let wait = Task.detached(priority: .utility) {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while !operation.completed.withLock({ $0 }) {
                guard ContinuousClock.now < deadline else { throw IOSOpusFileSourceError.cleanupTimedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await operation.task.value
        }
        do {
            try await wait.value
            if closing?.id == operation.id { closing = nil }
        } catch {
            if operation.completed.withLock({ $0 }), closing?.id == operation.id { closing = nil }
            throw error
        }
    }

    func snapshot() -> IOSOpusFileSnapshot {
        let released = fileClosed && converter == nil && encoder == nil && flac == nil && preparing == nil && reading == nil
        return .init(sourceFramesRead: inputPosition, returnedPackets: returnedPackets,
            queuedPackets: pending.count - pendingIndex, maximumQueuedPackets: maximumPending,
            sourceVerified: sealed, resourcesReleased: released,
            cleanupPending: gate.isRetired && !released)
    }

    private func prepareFile() async throws -> IOSOpusFilePlan {
        let gate = self.gate
        let inspected = try await file.prepare(validateLifetime: { try gate.check() })
        try gate.check()
        let original = inspected.format
        guard (1...2).contains(original.channels), (8_000...384_000).contains(original.sampleRate) else {
            throw IOSOpusFileSourceError.unsupportedFormat
        }
        guard let frames = inspected.frameCount, frames > 0, frames <= UInt64(original.sampleRate) * 14_400 else {
            throw IOSOpusFileSourceError.invalidDuration
        }
        let mask: UInt32 = original.channels == 1 ? 4 : 3
        let legacy: Bool
        switch inspected.source {
        case .wave: legacy = original.waveChannelMask == nil
        case .flac: legacy = false
        case .alac: throw IOSOpusFileSourceError.unsupportedFormat
        }
        guard original.waveChannelMask == mask || legacy else { throw IOSOpusFileSourceError.unsupportedLayout }
        let input = try AudioStreamingPCMFormat(sampleRate: original.sampleRate, channels: original.channels,
            encoding: original.encoding, declaredValidBits: original.declaredValidBits, waveChannelMask: mask)
        let selected = try await file.claimForSending()
        content = selected // Own the held reader before native validation can fail or suspend.
        try gate.check()
        if case .flac(let expected) = selected.source {
            let validated = try await AudioValidatedFlacFile.validate(reader: selected.reader, requireAuthorization: { try gate.check() })
            guard validated.metadata == expected else { throw IOSOpusFileSourceError.sourceChanged }
            validatedFlac = validated
        }
        try gate.check()
        let plan = IOSOpusFilePlan(originalFormat: original, conversionInputFormat: input,
            sourceFrames: frames, convertedFrames: (frames * 48_000 + UInt64(original.sampleRate) - 1) / UInt64(original.sampleRate),
            opus: try AudioStreamingOpusFormat(channels: UInt8(original.channels), bitrate: bitrate), interpretsLegacyWaveLayout: legacy)
        self.plan = plan
        return plan
    }

    private func producePacket() async throws -> SkyBridgeOpusEncodedPacket? {
        guard let plan, let content else { throw IOSOpusFileSourceError.notPrepared }
        let gate = self.gate
        while true {
            try gate.check()
            if !sealed { try await content.reader.validateSourceIdentity(); try gate.check() }
            if pendingIndex < pending.count {
                let packet = pending[pendingIndex]; pendingIndex += 1
                return packet
            }
            pending.removeAll(keepingCapacity: true); pendingIndex = 0
            if sealed {
                guard fileClosed, let completion, returnedPackets == completion.encoding.packetCount else {
                    throw IOSOpusFileSourceError.invalidProgress
                }
                return nil
            }
            guard let converter, let encoder else { throw IOSOpusFileSourceError.invalidProgress }
            if inputPosition < plan.sourceFrames {
                let frames = Int(min(UInt64(AudioCompatiblePCMConverter.maximumInputFrames), plan.sourceFrames - inputPosition))
                let bytes: Data
                switch content.source {
                case .wave(let wave):
                    bytes = try await content.reader.read(offset: wave.pcmByteOffset + inputPosition * UInt64(wave.format.bytesPerFrame),
                                                         length: frames * Int(wave.format.bytesPerFrame))
                case .flac:
                    guard let flac else { throw IOSOpusFileSourceError.invalidProgress }
                    bytes = try await flac.read(frameOffset: inputPosition, frames: frames, requireAuthorization: { try gate.check() })
                case .alac:
                    throw IOSOpusFileSourceError.unsupportedFormat
                }
                try gate.check()
                try converter.append(bytes) { pcm in
                    try encoder.append(pcm16Interleaved: pcm, emit: self.enqueue)
                }
                inputPosition += UInt64(frames)
            } else {
                if let flac { try await flac.finish(requireAuthorization: { try gate.check() }) }
                try await content.reader.validateSourceIdentity(); try gate.check()
                let converted = try converter.finish { pcm in try encoder.append(pcm16Interleaved: pcm, emit: self.enqueue) }
                let encoded = try encoder.finish(emit: enqueue)
                guard converted.sourceFrames == plan.sourceFrames, converted.convertedFrames == plan.convertedFrames,
                      encoded.sourceFrames == plan.convertedFrames, converter.resourcesReleased, encoder.resourcesReleased else {
                    throw IOSOpusFileSourceError.invalidProgress
                }
                self.converter = nil; self.encoder = nil
                if let flac { await flac.close(); self.flac = nil }
                validatedFlac = nil
                try gate.check()
                try await file.close(); fileClosed = true
                try gate.check()
                completion = IOSOpusFileCompletion(conversion: converted, encoding: encoded)
                sealed = true
            }
        }
    }

    private func enqueue(_ packet: SkyBridgeOpusEncodedPacket) throws {
        try gate.check()
        guard pending.count < Self.maximumQueuedPackets else { throw IOSOpusFileSourceError.queueCapacity }
        pending.append(packet); maximumPending = max(maximumPending, pending.count)
    }

    private func finishClose(preparing: Task<IOSOpusFilePlan, Error>?, reading: Task<SkyBridgeOpusEncodedPacket?, Error>?) async throws {
        // Original failures belong to their callers and remain latched in the effect gate.
        if let preparing { _ = await preparing.result }
        if let reading { _ = await reading.result }
        converter?.cancel(); converter = nil
        encoder?.cancel(); encoder = nil
        if let flac { await flac.close(); self.flac = nil }
        validatedFlac = nil; pending.removeAll(); pendingIndex = 0
        try await file.close(); fileClosed = true
        content = nil
    }
}

/// No file/network I/O or actor hop while a native write holds its own effect gate.
private final class IOSOpusFileEffectGate: Sendable {
    private struct State: Sendable { var retired = false; var failure: (any Error)? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let authorize: @Sendable () throws -> Void
    init(authorize: @escaping @Sendable () throws -> Void) { self.authorize = authorize }
    var failure: (any Error)? { state.withLock { $0.failure } }
    var isRetired: Bool { state.withLock { $0.retired } }
    func retire() { state.withLock { $0.retired = true } }
    func fail(_ error: any Error) {
        state.withLock { value in if value.failure == nil { value.failure = error }; value.retired = true }
    }
    func check() throws {
        do {
            try requireActive(); try Task.checkCancellation(); try authorize()
            try requireActive(); try Task.checkCancellation()
        } catch { fail(error); throw failure ?? error }
    }
    private func requireActive() throws {
        try state.withLock { value in
            if let failure = value.failure { throw failure }
            guard !value.retired else { throw IOSOpusFileSourceError.stopped }
        }
    }
}
