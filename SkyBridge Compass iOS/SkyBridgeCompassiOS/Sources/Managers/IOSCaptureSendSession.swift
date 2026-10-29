import Foundation
import Combine
import CryptoKit
import SkyBridgeProtocolCore

struct IOSCaptureSendReceipt: Sendable {
    let streamID: UUID
    let format: AudioStreamingPCMFormat
    let sentBytes: UInt64
    let sourceFrames: UInt64
    let sha256: Data
    let preparationFrames: UInt64
    let trailingPaddingFrames: UInt32
}

struct IOSCaptureSendFailure: Error, Sendable {
    let reason: AudioStreamingStopReason
    let underlying: any Error
    let cleanupFailures: [String]
}

enum IOSCaptureSendError: Error, Equatable, Sendable {
    case alreadyStarted, invalidOptions, invalidSourceState, leaseBindingMismatch
    case unexpectedControl, wrongStream, invalidWindow, invalidCredit, invalidProgress
    case contentMismatch, timedOut, stopped, cleanupPending, noSamples
    case peerStopped(AudioStreamingStopReason)
}

/// One source, one authenticated channel, one finite account lease. Preparation
/// learns actual PCM metadata without retaining/transmitting audio. Accept and
/// exact OutputReady establish a new stream boundary; no prepared audio is part
/// of the formal stream. A receipt is the peer's report, not a DAC measurement.
@MainActor
final class IOSCaptureSendSession: ObservableObject {
    enum Phase: Equatable {
        case idle, authorizing, selecting, probing, awaitingAcceptance, streaming
        case draining, awaitingContent, awaitingPlayback, stopping, completed, failed
    }
    struct Options {
        var authorizationTimeout: Duration = .seconds(45)
        var formatTimeout: Duration = .seconds(5)
        var acceptanceTimeout: Duration = .seconds(120)
        var inputTimeout: Duration = .seconds(10)
        var creditTimeout: Duration = .seconds(5)
        var drainTimeout: Duration = .seconds(30)
        var completionTimeout: Duration = .seconds(30)
        var maximumCaptureDuration: Duration = .seconds(14_400)
        var pollInterval: Duration = .milliseconds(50)
        func validate() throws {
            guard [authorizationTimeout, formatTimeout, acceptanceTimeout, inputTimeout,
                   creditTimeout, drainTimeout, completionTimeout].allSatisfy({ $0 > .zero && $0 <= .seconds(120) }),
                  maximumCaptureDuration > .zero, maximumCaptureDuration <= .seconds(86_400),
                  pollInterval > .zero, pollInterval <= .milliseconds(100) else {
                throw IOSCaptureSendError.invalidOptions
            }
        }
    }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var format: AudioStreamingPCMFormat?
    @Published private(set) var sentBytes: UInt64 = 0
    @Published private(set) var receipt: IOSCaptureSendReceipt?
    @Published private(set) var failure: IOSCaptureSendFailure?
    @Published private(set) var authorizationExpiresAt: Date?
    @Published private(set) var authorizationRenewalState: AudioMembershipRenewalState?
    private(set) var lastAuthorizationRenewalFailure: (any Error)?
    var cleanupPending: Bool { ownsSource && source.cleanupPending }
    let streamID: UUID
    private let source: IOSAudioCaptureSource
    private let channel: IOSAudioChannel
    private let authorize: @MainActor (IOSAudioChannel) async throws -> AudioMembershipLease
    private let renewMembership: IOSAudioMembershipRenewal?
    private let options: Options
    private let now: @MainActor () -> ContinuousClock.Instant
    private var sourceObservation: AnyCancellable?
    private var started = false, finished = false, offerAttempted = false, peerStopped = false
    private let operationID = UUID()
    private var ownsSource = false, ownsChannel = false
    private var lease: AudioMembershipLease?
    private var primary: (reason: AudioStreamingStopReason, error: any Error)?
    private var execution: Task<IOSCaptureSendReceipt, Error>?
    private var reader: Task<Void, Never>?, pump: Task<Void, Never>?, watcher: Task<Void, Never>?
    private var stoppingSource: Task<Void, Error>?
    private var membershipRenewal: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var creditWake: CheckedContinuation<Void, Never>?
    private var acceptedWindow: UInt64?
    private var outputReady = false, finishRequested = false, endAttempted = false, endWritten = false
    private var contentVerified = false
    private var completion: (frames: UInt64, padding: UInt32)?
    private var confirmedBytes: UInt64 = 0, attemptedBytes: UInt64 = 0, retiredBytes: UInt64 = 0
    private var receivedFrames: UInt64 = 0
    private var digest = SHA256()
    private var finalDigest: Data?
    private var phaseBegan: ContinuousClock.Instant?
    private var captureBegan: ContinuousClock.Instant?
    private var inputProgress: ContinuousClock.Instant?
    private var creditWaiting: ContinuousClock.Instant?
    private var finishBegan: ContinuousClock.Instant?
    private var endBegan: ContinuousClock.Instant?
    private var publishedAt: ContinuousClock.Instant?

    init(renewMembership: IOSAudioMembershipRenewal?,
         source: IOSAudioCaptureSource, channel: IOSAudioChannel, streamID: UUID = UUID(),
         options: Options = Options(), now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         authorize: @escaping @MainActor (IOSAudioChannel) async throws -> AudioMembershipLease = {
             try await IOSAudioAccountMembershipProvider.shared.lease(for: $0)
         }) {
        self.source = source; self.channel = channel; self.streamID = streamID
        self.options = options; self.now = now; self.authorize = authorize
        self.renewMembership = renewMembership
        sourceObservation = source.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    func run() async throws -> IOSCaptureSendReceipt {
        guard !started else { throw IOSCaptureSendError.alreadyStarted }
        started = true
        if Task.isCancelled { fail(IOSCaptureSendError.stopped) }
        let task = Task { try await execute() }; execution = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: {
            Task { @MainActor [self] in cancel() }
        }
        execution = nil
        if case .failure(let error) = result { fail(error) }
        if Task.isCancelled { fail(IOSCaptureSendError.stopped) }
        membershipRenewal?.cancel()
        watcher?.cancel(); reader?.cancel()
        if primary != nil { pump?.cancel(); if ownsSource { source.cancel() } }
        await watcher?.value; await reader?.value; await pump?.value
        watcher = nil; reader = nil; pump = nil
        var cleanup: [String] = []
        if let stoppingSource {
            do { try await stoppingSource.value } catch { cleanup.append("capture_stop: \(error)") }
        }
        if ownsSource, source.phase != .closed {
            do { try await source.stop() } catch { cleanup.append("capture_close: \(error)") }
        }
        if cleanupPending, primary == nil { fail(IOSCaptureSendError.cleanupPending) }
        if primary == nil {
            do { try requireCurrent() } catch { fail(error) }
        }
        if let primary, ownsChannel, offerAttempted, !peerStopped {
            let stop = Task { @MainActor [channel] in try await channel.sendStop(primary.reason) }
            do { try await stop.value } catch { cleanup.append("stop_delivery: \(error)") }
        }
        if ownsChannel { channel.close() }
        // Capture and the peer's playback stop before account I/O is joined.
        await membershipRenewal?.value
        membershipRenewal = nil
        finished = true; sentBytes = confirmedBytes
        if let primary {
            let value = IOSCaptureSendFailure(reason: primary.reason, underlying: primary.error, cleanupFailures: cleanup)
            failure = value; phase = .failed; throw value
        }
        let value = try result.get(); receipt = value; phase = .completed
        return value
    }

    /// Normal end retains every admitted frame and requires both peer receipts.
    func finishCapture() {
        guard !finished, !finishRequested else { return }
        guard phase == .streaming else { cancel(); return }
        finishRequested = true; finishBegan = now(); changePhase(.draining)
        stoppingSource = Task { [source] in try await source.stop() }
        signal()
    }

    /// Hard stop, including user cancellation, never reports successful playback.
    func cancel() { fail(IOSCaptureSendError.stopped) }

    func retryCleanup() async throws {
        guard finished, ownsSource else { throw IOSCaptureSendError.cleanupPending }
        if source.phase == .closed { return }
        try await source.retryCleanup()
    }

    private func execute() async throws -> IOSCaptureSendReceipt {
        try source.claimForSending(operationID); ownsSource = true
        try channel.claimOperation(operationID); ownsChannel = true
        try options.validate()
        guard streamID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              (source.phase == .idle || source.phase == .prepared), !source.ingress.snapshot.isTransmitting else {
            throw IOSCaptureSendError.invalidSourceState
        }
        try requireCurrent()
        guard channel.peerCapabilities.contains(AudioStreamingWire.captureReceiveCapability) else {
            throw AudioStreamingChannelError.unsupportedPeer
        }
        changePhase(.authorizing)
        watcher = Task { await poll() }
        let membership = try await authorize(channel)
        try requireCurrent()
        let local = try AudioProtocolIdentity(channel.localIdentityBindingForAccountRequest())
        guard membership.ownerID == channel.ownerID, membership.evidence.localIdentity == local,
              membership.evidence.peerIdentity == channel.remoteIdentity else { throw IOSCaptureSendError.leaseBindingMismatch }
        lease = membership; try requireCurrent()
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(membership.evidence.expiresAtMilliseconds) / 1_000)
        if source.phase == .idle { changePhase(.selecting); try await source.prepare() }
        try requireCurrent(); changePhase(.probing)
        try await source.start()
        while source.ingress.snapshot.format == nil {
            try requireCurrent(); try await Task.sleep(for: options.pollInterval)
        }
        try requireCurrent()
        guard let observed = source.ingress.snapshot.format else { throw IOSAudioCaptureError.formatUnavailable }
        format = observed
        reader = Task { await readMessages() }
        changePhase(.awaitingAcceptance); offerAttempted = true
        try await channel.send(.init(streamID: streamID, body: .captureOffer(observed)),
                               requireEffectAuthorization: { [self] in try requireEffect() })
        while acceptedWindow == nil || !outputReady {
            try requireCurrent(); await withCheckedContinuation { wake = $0 }
        }
        try requireCurrent()
        try startMembershipRenewal()
        try source.ingress.beginTransmission(expectedFormat: observed)
        captureBegan = now(); inputProgress = captureBegan; changePhase(.streaming)
        pump = Task { await sendCapturedPCM(format: observed) }
        while true {
            try requireCurrent()
            if endWritten, contentVerified, let completion, let finalDigest {
                guard source.phase == .closed, !source.cleanupPending else { throw IOSCaptureSendError.cleanupPending }
                return .init(streamID: streamID, format: observed, sentBytes: confirmedBytes,
                    sourceFrames: completion.frames, sha256: finalDigest,
                    preparationFrames: source.ingress.snapshot.preparationFrames,
                    trailingPaddingFrames: completion.padding)
            }
            await withCheckedContinuation { wake = $0 }
        }
    }

    private func readMessages() async {
        do {
            var iterator = channel.messages.makeAsyncIterator()
            while let message = try await iterator.next() { try requireCurrent(); try receive(message) }
            if !Task.isCancelled { fail(AudioStreamingChannelError.closed) }
        } catch { if !Task.isCancelled { fail(error) } }
    }

    private func receive(_ message: AudioStreamingMessage) throws {
        guard message.streamID == streamID else { throw IOSCaptureSendError.wrongStream }
        guard let format else { throw IOSCaptureSendError.unexpectedControl }
        let frameBytes = UInt64(format.bytesPerFrame)
        switch message.body {
        case .accept(let window):
            guard acceptedWindow == nil, window > 0, window <= AudioStreamingWire.maximumReceiveWindowBytes,
                  UInt64(window) % frameBytes == 0 else { throw IOSCaptureSendError.invalidWindow }
            acceptedWindow = UInt64(window)
        case .outputReady(let actual):
            guard acceptedWindow != nil, !outputReady, actual == format else { throw IOSCaptureSendError.unexpectedControl }
            outputReady = true
        case .credit(let bytes):
            guard outputReady, bytes >= retiredBytes, bytes <= attemptedBytes, bytes % frameBytes == 0 else {
                throw IOSCaptureSendError.invalidCredit
            }
            if bytes > retiredBytes { retiredBytes = bytes; creditWaiting = nil; signalCredit() }
        case .contentVerified(let total, let hash):
            guard endAttempted, !contentVerified, total == confirmedBytes, hash == finalDigest else {
                throw IOSCaptureSendError.contentMismatch
            }
            contentVerified = true; changePhase(.awaitingPlayback)
        case .playbackComplete(let frames, let padding):
            guard endAttempted, contentVerified, completion == nil, frames == confirmedBytes / frameBytes else {
                throw IOSCaptureSendError.unexpectedControl
            }
            completion = (frames, padding)
        case .stop(let reason):
            peerStopped = true; throw IOSCaptureSendError.peerStopped(reason)
        default: throw IOSCaptureSendError.unexpectedControl
        }
        signal()
    }

    private func sendCapturedPCM(format: AudioStreamingPCMFormat) async {
        do {
            let frameBytes = UInt64(format.bytesPerFrame)
            let packetLimit = AudioStreamingWire.maximumPCMDataBytes / Int(frameBytes) * Int(frameBytes)
            guard packetLimit > 0, let window = acceptedWindow else { throw IOSCaptureSendError.invalidWindow }
            while let chunk = try await source.ingress.next() {
                try requireCurrent()
                guard chunk.block.format == format, chunk.frameOffset == receivedFrames,
                      chunk.block.frameCount > 0, UInt64(chunk.block.bytes.count) == chunk.block.frameCount * frameBytes else {
                    throw IOSCaptureSendError.invalidProgress
                }
                let nextFrames = receivedFrames.addingReportingOverflow(chunk.block.frameCount)
                guard !nextFrames.overflow, nextFrames.partialValue <= AudioStreamingWire.maximumCounter / frameBytes else {
                    throw IOSCaptureSendError.invalidProgress
                }
                receivedFrames = nextFrames.partialValue; inputProgress = now()
                var position = 0
                while position < chunk.block.bytes.count {
                    try requireCurrent()
                    guard attemptedBytes == confirmedBytes, attemptedBytes >= retiredBytes else { throw IOSCaptureSendError.invalidCredit }
                    // A credit can arrive before the local native write callback.
                    // attemptedBytes includes only this single bounded in-flight
                    // message; success still requires every write to complete.
                    let outstanding = attemptedBytes - retiredBytes
                    guard outstanding <= window else { throw IOSCaptureSendError.invalidCredit }
                    let available = window - outstanding
                    if available < frameBytes {
                        if creditWaiting == nil { creditWaiting = now() }
                        await withCheckedContinuation { creditWake = $0 }
                        continue
                    }
                    creditWaiting = nil
                    let count = min(chunk.block.bytes.count - position, packetLimit, Int(available)) / Int(frameBytes) * Int(frameBytes)
                    guard count > 0, UInt64(count) <= AudioStreamingWire.maximumCounter - confirmedBytes else {
                        throw IOSCaptureSendError.invalidProgress
                    }
                    let bytes = chunk.block.bytes.subdata(in: position..<(position + count))
                    let offset = confirmedBytes; attemptedBytes = offset + UInt64(count)
                    try await channel.send(.init(streamID: streamID, body: .pcmData(byteOffset: offset, bytes: bytes)),
                                           requireEffectAuthorization: { [self] in try requireEffect() })
                    try requireCurrent()
                    confirmedBytes = attemptedBytes; digest.update(data: bytes); position += count
                }
            }
            try requireCurrent()
            guard finishRequested, let stoppingSource else { throw IOSCaptureSendError.invalidSourceState }
            try await stoppingSource.value
            try requireCurrent()
            guard source.phase == .closed, !source.cleanupPending else { throw IOSCaptureSendError.cleanupPending }
            guard confirmedBytes > 0 else { throw IOSCaptureSendError.noSamples }
            guard confirmedBytes == receivedFrames * frameBytes else { throw IOSCaptureSendError.invalidProgress }
            finalDigest = Data(digest.finalize()); endAttempted = true; endBegan = now()
            changePhase(.awaitingContent)
            guard let finalDigest else { throw IOSCaptureSendError.invalidProgress }
            try await channel.send(.init(streamID: streamID, body: .end(totalBytes: confirmedBytes, sha256: finalDigest)),
                                   requireEffectAuthorization: { [self] in try requireEffect() })
            try requireCurrent(); endWritten = true; sentBytes = confirmedBytes; signal()
        } catch { fail(error) }
    }

    private func startMembershipRenewal() throws {
        try requireCurrent()
        guard let lease, membershipRenewal == nil else { throw IOSCaptureSendError.leaseBindingMismatch }
        guard let renewMembership else { return }
        membershipRenewal = Task { [weak self] in
            await AudioMembershipRenewal(lease: lease, renew: { [weak self] in
                guard let self else { throw IOSCaptureSendError.stopped }
                try await self.renewAuthorization(lease, using: renewMembership)
            }, observe: { [weak self] update in
                await self?.publishAuthorization(update)
            }).run()
        }
    }

    private func renewAuthorization(_ current: AudioMembershipLease, using renew: IOSAudioMembershipRenewal) async throws {
        try requireCurrent()
        guard lease === current else { throw IOSCaptureSendError.leaseBindingMismatch }
        let continued = try await renew(channel, current)
        try requireCurrent()
        guard lease === current, continued === current else { throw IOSCaptureSendError.leaseBindingMismatch }
    }

    private func publishAuthorization(_ update: AudioMembershipRenewalUpdate) {
        guard !finished, membershipRenewal != nil else { return }
        lastAuthorizationRenewalFailure = update.failure
        guard primary == nil, membershipRenewal?.isCancelled == false else { return }
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(update.evidence.expiresAtMilliseconds) / 1_000)
        authorizationRenewalState = update.state
    }

    private func poll() async {
        do {
            while !Task.isCancelled {
                try requireCurrent()
                let instant = now()
                func deadline(_ began: ContinuousClock.Instant?, _ limit: Duration) throws {
                    if let began, instant - began >= limit { throw IOSCaptureSendError.timedOut }
                }
                switch phase {
                case .authorizing: try deadline(phaseBegan, options.authorizationTimeout)
                case .probing: try deadline(phaseBegan, options.formatTimeout)
                case .awaitingAcceptance: try deadline(phaseBegan, options.acceptanceTimeout)
                case .streaming:
                    try deadline(captureBegan, options.maximumCaptureDuration)
                    if creditWaiting == nil { try deadline(inputProgress, options.inputTimeout) }
                default: break
                }
                try deadline(creditWaiting, options.creditTimeout)
                if !endAttempted { try deadline(finishBegan, options.drainTimeout) }
                try deadline(endBegan, options.completionTimeout)
                if publishedAt == nil || instant - (publishedAt ?? instant) >= .milliseconds(250) {
                    if sentBytes != confirmedBytes { sentBytes = confirmedBytes }
                    publishedAt = instant
                }
                try await Task.sleep(for: options.pollInterval)
            }
        } catch { if !Task.isCancelled { fail(error) } }
    }

    private func checkSourceAndOperation() throws {
        if let primary { throw primary.error }
        try Task.checkCancellation(); try source.ingress.requireHealthy()
        if let failure = source.failure { throw failure }
    }
    private func requireEffect() throws {
        try checkSourceAndOperation()
        guard let lease else { throw IOSCaptureSendError.leaseBindingMismatch }
        try lease.requireEffectCurrent()
    }
    private func requireCurrent() throws {
        try checkSourceAndOperation(); try channel.requireCurrent(); try lease?.requireEffectCurrent()
        if let failure = lease?.failure { throw failure }
    }
    private func fail(_ error: any Error) {
        guard primary == nil, !finished else { return }
        primary = (Self.reason(error), error); phase = .stopping
        membershipRenewal?.cancel()
        execution?.cancel(); pump?.cancel()
        if ownsSource { source.cancel(error) }
        signal(); signalCredit()
    }
    private func signal() { let value = wake; wake = nil; value?.resume() }
    private func signalCredit() { let value = creditWake; creditWake = nil; value?.resume() }
    private func changePhase(_ value: Phase) { phase = value; phaseBegan = now() }

    private static func reason(_ error: any Error) -> AudioStreamingStopReason {
        if let error = error as? IOSCaptureSendError {
            switch error {
            case .peerStopped(let reason): return reason
            case .stopped: return .userStopped
            case .timedOut: return .timedOut
            case .leaseBindingMismatch: return .accountRevoked
            case .contentMismatch: return .contentMismatch
            case .cleanupPending, .invalidSourceState, .noSamples: return .sourceFailed
            default: return .protocolViolation
            }
        }
        if error is AudioMembershipLeaseFailure || error is AudioMembershipError || error is AudioAccountProviderError { return .accountRevoked }
        if let error = error as? IOSAudioCaptureError {
            switch error {
            case .overflow: return .queueOverflow
            case .cancelled: return .userStopped
            case .timedOut: return .timedOut
            default: return .sourceFailed
            }
        }
        if let error = error as? AudioStreamingChannelError {
            switch error {
            case .queueOverflow: return .queueOverflow
            case .timedOut: return .timedOut
            case .unsupportedPeer: return .unsupportedOutput
            default: return .sessionReplaced
            }
        }
        if error is CancellationError { return .userStopped }
        return .sourceFailed
    }
}
