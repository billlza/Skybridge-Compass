import Foundation
import Combine
import SkyBridgeProtocolCore

/// Two authenticated peer reports, not an independent measurement of the DAC.
struct IOSOriginalFileSendReceipt: Sendable {
    let streamID: UUID
    let file: TransferReceipt
    let format: AudioStreamingPCMFormat
    let sourceFrames: UInt64
    let trailingPaddingFrames: UInt32
}

struct IOSOriginalFileSendFailure: Error, Sendable {
    let reason: AudioStreamingStopReason
    let underlying: any Error
    let cleanupFailures: [String]
}

enum IOSOriginalFileSendError: Error, Equatable, Sendable {
    case alreadyStarted, invalidOptions, leaseBindingMismatch, unsupportedDuration, unsupportedFormat
    case unexpectedControl, wrongStream, receiptMismatch, invalidProgress
    case peerStopped(AudioStreamingStopReason), timeout, stopped, cleanupPending
}

/// Owns one source and one immutable channel until all work and cleanup finish.
/// The classic file receipt, output declaration and native completion can arrive
/// on different connections. All three must agree before this reports success.
@MainActor
final class IOSOriginalFileSendSession: ObservableObject {
    enum Phase: Equatable, Sendable { case idle, authorizing, inspecting, awaitingAcceptance, transferringFile,
        awaitingOutput, awaitingPlayback, stopping, completed, failed }
    struct WorkProgress: Equatable, Sendable {
        let phase: Phase
        let hashedBytes: Int64
        let hashTotal: Int64?
        let transferredBytes: Int64
        let fileBytes: Int64?
        let outputFrames: UInt64
        let sourceFrames: UInt64?
    }
    struct Options {
        var authorizationTimeout: Duration = .seconds(45)
        var inspectionTimeout: Duration = .seconds(30)
        var acceptanceTimeout: Duration = .seconds(120)
        var transferTimeout: Duration = .seconds(300)
        var outputTimeout: Duration = .seconds(15)
        /// Both FLAC and ALAC require complete receiver-side decode validation before output.
        var flacOutputTimeout: Duration = .seconds(200)
        var completionGrace: Duration = .seconds(30)
        var maximumDurationMilliseconds: UInt64 = 14_400_000
        var pollInterval: Duration = .milliseconds(50)

        func validate() throws {
            guard [authorizationTimeout, inspectionTimeout, acceptanceTimeout, outputTimeout, completionGrace]
                .allSatisfy({ $0 > .zero && $0 <= .seconds(120) }),
                transferTimeout > .zero, transferTimeout <= .seconds(1_800),
                flacOutputTimeout > .zero, flacOutputTimeout <= .seconds(300),
                maximumDurationMilliseconds > 0, maximumDurationMilliseconds <= 86_400_000,
                pollInterval > .zero, pollInterval <= .milliseconds(100) else {
                throw IOSOriginalFileSendError.invalidOptions
            }
        }
    }
    typealias Progress = @MainActor (Int64, Int64) async -> Void
    typealias Transfer = @MainActor (IOSPreparedAudioFile, IOSAudioChannel, IOSAudioFileConnection,
        @escaping @MainActor () throws -> Void, @escaping Progress) async throws -> TransferReceipt

    @Published private(set) var phase = Phase.idle
    @Published private(set) var sourceFormat: AudioStreamingPCMFormat?
    @Published private(set) var transferredBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    /// Authenticated native-output observation, not the final drain/completion receipt.
    @Published private(set) var outputSourceFrames: UInt64?
    @Published private(set) var workProgress = WorkProgress(phase: .idle, hashedBytes: 0, hashTotal: nil,
        transferredBytes: 0, fileBytes: nil, outputFrames: 0, sourceFrames: nil)
    @Published private(set) var receipt: IOSOriginalFileSendReceipt?
    @Published private(set) var failure: IOSOriginalFileSendFailure?
    @Published private(set) var cleanupPending = false
    @Published private(set) var authorizationExpiresAt: Date?
    @Published private(set) var authorizationRenewalState: AudioMembershipRenewalState?
    private(set) var lastAuthorizationRenewalFailure: (any Error)?

    let streamID: UUID
    var fileRoute: IOSAudioFileRoute? { channel.fileRoute }
    private let source: IOSPreparedAudioFile
    private let channel: IOSAudioChannel
    private let connection: IOSAudioFileConnection
    private let authorize: @MainActor (IOSAudioChannel) async throws -> AudioMembershipLease
    private let renewMembership: IOSAudioMembershipRenewal?
    private let transfer: Transfer
    private let options: Options
    private let now: @MainActor () -> ContinuousClock.Instant
    private var started = false
    private var finished = false
    private var lease: AudioMembershipLease?
    private var content: IOSPreparedAudioFile.Content?
    private var execution: Task<IOSOriginalFileSendReceipt, Error>?
    private var reader: Task<Void, Never>?
    private var transferring: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var membershipRenewal: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var primary: (reason: AudioStreamingStopReason, error: any Error)?
    private var transferCleanup: IOSAudioFileTransferCleanupError?
    private var offerAttempted = false
    private var peerStopped = false
    private var accepted = false
    private var ready: AudioStreamingPCMFormat?
    private var completion: (frames: UInt64, padding: UInt32)?
    private var fileReceipt: TransferReceipt?
    private var phaseBegan: ContinuousClock.Instant?
    private var transferBegan: ContinuousClock.Instant?
    private var receiptBegan: ContinuousClock.Instant?
    private var readyBegan: ContinuousClock.Instant?
    private var duration: Duration = .zero
    private var hashProgress: (completed: Int64, total: Int64)?

    init(renewMembership: IOSAudioMembershipRenewal?,
         source: IOSPreparedAudioFile, channel: IOSAudioChannel, streamID: UUID = UUID(),
         connection: IOSAudioFileConnection = IOSAudioFileConnection(), options: Options = Options(),
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         authorize: @escaping @MainActor (IOSAudioChannel) async throws -> AudioMembershipLease = {
             try await IOSAudioAccountMembershipProvider.shared.lease(for: $0)
         }, transfer: @escaping Transfer = { source, channel, connection, authorize, progress in
             try await FileTransferManager.instance.sendPreparedAudioFile(source, channel: channel,
                 connectionOwner: connection, requireEffectAuthorization: authorize, progress: progress)
         }) {
        self.source = source; self.channel = channel; self.streamID = streamID
        self.connection = connection; self.options = options; self.now = now
        self.authorize = authorize; self.transfer = transfer
        self.renewMembership = renewMembership
    }

    func run() async throws -> IOSOriginalFileSendReceipt {
        guard !started else { throw IOSOriginalFileSendError.alreadyStarted }
        started = true
        do { try channel.claimOperation(UUID()) }
        catch {
            // Neither the source nor carrier was claimed by this operation.
            // They may belong to a still-running file/capture operation.
            let value = IOSOriginalFileSendFailure(reason: Self.reason(error), underlying: error, cleanupFailures: [])
            failure = value; phase = .failed; finished = true; publishWorkProgress()
            throw value
        }
        if Task.isCancelled { fail(IOSOriginalFileSendError.stopped) }
        let task = Task { try await execute() }; execution = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: {
            Task { @MainActor [self] in stop() }
        }
        execution = nil
        if case .failure(let error) = result { fail(error) }
        if Task.isCancelled { fail(IOSOriginalFileSendError.stopped) }
        membershipRenewal?.cancel()
        watcher?.cancel(); reader?.cancel(); transferring?.cancel()
        if primary != nil { connection.cancel() }
        await watcher?.value; await reader?.value; await transferring?.value
        watcher = nil; reader = nil; transferring = nil
        membershipRenewal?.cancel()
        if primary == nil {
            do { try requireCurrent() } catch { fail(error) }
        }
        let cleanup = await closeResources(retrying: false)
        if !cleanup.isEmpty, primary == nil { fail(IOSOriginalFileSendError.cleanupPending) }
        if primary == nil {
            do { try requireCurrent() } catch { fail(error) }
        }
        var diagnostics = cleanup
        if let primary, offerAttempted, !peerStopped {
            // A Stop grants nothing. Send it on this exact owner even if account
            // authorization was revoked; the carrier enforces its native deadline.
            let stop = Task { @MainActor [channel] in try await channel.sendStop(primary.reason) }
            do { try await stop.value } catch { diagnostics.append("stop_delivery: \(error)") }
        }
        channel.close()
        // Stop the peer and close source/transport before joining account I/O.
        await membershipRenewal?.value
        membershipRenewal = nil
        finished = true
        if let primary {
            let error = IOSOriginalFileSendFailure(reason: primary.reason, underlying: primary.error,
                                                   cleanupFailures: diagnostics)
            failure = error; phase = .failed; publishWorkProgress()
            throw error
        }
        let value = try result.get()
        receipt = value; phase = .completed; publishWorkProgress()
        return value
    }

    func stop() {
        guard !finished else { return }
        fail(IOSOriginalFileSendError.stopped)
    }

    /// A failed stream stays failed. Retained native resources may be explicitly
    /// closed again only after its workers exited; this never resumes playback.
    func retryCleanup() async throws {
        guard finished, cleanupPending else { throw IOSOriginalFileSendError.cleanupPending }
        let errors = await closeResources(retrying: true)
        if !errors.isEmpty { throw IOSOriginalFileSendFailure(reason: .sourceFailed,
            underlying: IOSOriginalFileSendError.cleanupPending, cleanupFailures: errors) }
    }

    private func execute() async throws -> IOSOriginalFileSendReceipt {
        try options.validate()
        guard streamID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw AudioStreamingWireError.invalidIdentifier
        }
        try requireCurrent()
        changePhase(.authorizing)
        watcher = Task { await poll() }
        let membership = try await authorize(channel)
        try requireCurrent()
        let local = try AudioProtocolIdentity(channel.localIdentityBindingForAccountRequest())
        guard membership.ownerID == channel.ownerID, membership.evidence.localIdentity == local,
              membership.evidence.peerIdentity == channel.remoteIdentity else {
            throw IOSOriginalFileSendError.leaseBindingMismatch
        }
        lease = membership
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(membership.evidence.expiresAtMilliseconds) / 1_000)
        try requireCurrent()
        changePhase(.inspecting)
        let prepared = try await source.prepare(onHashProgress: { [weak self] completed, total in
            guard let self else { throw IOSOriginalFileSendError.stopped }
            try await self.recordHashProgress(completed, total: total)
        }) { [weak self] in
            guard let self else { throw IOSOriginalFileSendError.stopped }
            try await self.requireCurrent()
        }
        try requireCurrent()
        if !channel.peerCapabilities.contains(prepared.requiredReceiverCapability) {
            throw IOSOriginalFileSendError.unsupportedFormat
        }
        guard let frames = prepared.frameCount, !prepared.requiresReceiverValidation || frames > 0 else {
            throw IOSOriginalFileSendError.unsupportedDuration
        }
        let milliseconds = (frames * 1_000 + UInt64(prepared.format.sampleRate) - 1) / UInt64(prepared.format.sampleRate)
        guard milliseconds <= options.maximumDurationMilliseconds else { throw IOSOriginalFileSendError.unsupportedDuration }
        duration = .milliseconds(Int64(milliseconds))
        content = prepared; sourceFormat = prepared.format; totalBytes = prepared.length
        guard let transferID = UUID(uuidString: prepared.transferID) else { throw IOSPreparedAudioFileError.invalidTransferID }
        reader = Task { await readMessages() }
        changePhase(.awaitingAcceptance)
        offerAttempted = true
        try await channel.send(.init(streamID: streamID,
            body: .fileOffer(transferID: transferID, length: UInt64(prepared.length), sha256: prepared.digest)),
            requireEffectAuthorization: { [self] in try requireEffect() })
        while true {
            try requireCurrent()
            if let fileReceipt, let ready, let completion {
                return .init(streamID: streamID, file: fileReceipt, format: ready,
                             sourceFrames: completion.frames, trailingPaddingFrames: completion.padding)
            }
            await withCheckedContinuation { wake = $0 }
        }
    }

    private func readMessages() async {
        do {
            var iterator = channel.messages.makeAsyncIterator()
            while let message = try await iterator.next() {
                try requireCurrent()
                try receive(message)
            }
            if !Task.isCancelled { fail(AudioStreamingChannelError.closed) }
        } catch { if !Task.isCancelled { fail(error) } }
    }

    private func receive(_ message: AudioStreamingMessage) throws {
        guard message.streamID == streamID else { throw IOSOriginalFileSendError.wrongStream }
        guard let content else { throw IOSOriginalFileSendError.unexpectedControl }
        switch message.body {
        case .accept(let window):
            guard !accepted, window == 0 else { throw IOSOriginalFileSendError.unexpectedControl }
            try startMembershipRenewal()
            accepted = true; transferBegan = now(); changePhase(.transferringFile)
            transferring = Task { await sendFile(content) }
        case .outputReady(let format):
            guard accepted, ready == nil, format == content.format else { throw IOSOriginalFileSendError.unexpectedControl }
            ready = format; readyBegan = now()
            if fileReceipt != nil { changePhase(.awaitingPlayback) }
        case .fileOutputProgress(let frames):
            guard channel.peerCapabilities.contains(AudioStreamingWire.fileOutputProgressReportCapability),
                  accepted, ready != nil, completion == nil else { throw IOSOriginalFileSendError.unexpectedControl }
            guard let total = content.frameCount, frames <= total, frames >= (outputSourceFrames ?? 0) else {
                throw IOSOriginalFileSendError.invalidProgress
            }
            guard frames > (outputSourceFrames ?? 0) else { return }
            outputSourceFrames = frames
        case .playbackComplete(let frames, let padding):
            guard accepted, ready != nil, completion == nil, frames == content.frameCount else {
                throw IOSOriginalFileSendError.unexpectedControl
            }
            completion = (frames, padding)
        case .stop(let reason):
            peerStopped = true
            throw IOSOriginalFileSendError.peerStopped(reason)
        default: throw IOSOriginalFileSendError.unexpectedControl
        }
        signal()
    }

    private func sendFile(_ content: IOSPreparedAudioFile.Content) async {
        do {
            try requireCurrent()
            let value = try await transfer(source, channel, connection,
                { [self] in try requireEffect() }, { [self] sent, total in
                    guard primary == nil else { return }
                    guard total == content.length, sent >= transferredBytes, sent <= total else {
                        fail(IOSOriginalFileSendError.invalidProgress); return
                    }
                    transferredBytes = sent
                })
            try requireCurrent()
            guard value.success, value.transferId == content.transferID, value.receivedBytes == content.length,
                  value.fileHash?.lowercased() == content.digest.map({ String(format: "%02x", $0) }).joined() else {
                throw IOSOriginalFileSendError.receiptMismatch
            }
            fileReceipt = value; receiptBegan = now()
            changePhase(ready == nil ? .awaitingOutput : .awaitingPlayback)
            signal()
        } catch {
            if let cleanup = error as? IOSAudioFileTransferCleanupError { transferCleanup = cleanup }
            fail(error)
        }
    }

    private func startMembershipRenewal() throws {
        try requireCurrent()
        guard let lease, membershipRenewal == nil else { throw IOSOriginalFileSendError.leaseBindingMismatch }
        guard let renewMembership else { return } // Explicit finite/offline consumer.
        membershipRenewal = Task { [weak self] in
            await AudioMembershipRenewal(lease: lease, renew: { [weak self] in
                guard let self else { throw IOSOriginalFileSendError.stopped }
                try await self.renewAuthorization(lease, using: renewMembership)
            }, observe: { [weak self] update in
                await self?.publishAuthorization(update)
            }).run()
        }
    }

    private func renewAuthorization(_ current: AudioMembershipLease, using renew: IOSAudioMembershipRenewal) async throws {
        try requireCurrent()
        guard lease === current else { throw IOSOriginalFileSendError.leaseBindingMismatch }
        let continued = try await renew(channel, current)
        try requireCurrent()
        guard lease === current, continued === current else { throw IOSOriginalFileSendError.leaseBindingMismatch }
    }

    private func publishAuthorization(_ update: AudioMembershipRenewalUpdate) {
        guard !finished, membershipRenewal != nil else { return }
        // Polling can observe revocation and begin cleanup before this actor hop.
        // Keep the originating request error while ignoring stale presentation updates.
        lastAuthorizationRenewalFailure = update.failure
        guard primary == nil, membershipRenewal?.isCancelled == false else { return }
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(update.evidence.expiresAtMilliseconds) / 1_000)
        authorizationRenewalState = update.state
    }

    private func poll() async {
        do {
            while !Task.isCancelled {
                try requireCurrent()
                let current = now()
                func deadline(_ began: ContinuousClock.Instant?, _ limit: Duration) throws {
                    if let began, current - began >= limit { throw IOSOriginalFileSendError.timeout }
                }
                switch phase {
                case .authorizing: try deadline(phaseBegan, options.authorizationTimeout)
                case .inspecting: try deadline(phaseBegan, options.inspectionTimeout)
                case .awaitingAcceptance: try deadline(phaseBegan, options.acceptanceTimeout)
                default: break
                }
                if accepted, fileReceipt == nil { try deadline(transferBegan, options.transferTimeout) }
                if fileReceipt != nil, ready == nil {
                    guard let content else { throw IOSOriginalFileSendError.unexpectedControl }
                    try deadline(receiptBegan, content.requiresReceiverValidation ? options.flacOutputTimeout : options.outputTimeout)
                }
                if ready != nil, completion == nil { try deadline(readyBegan, duration + options.completionGrace) }
                publishWorkProgress()
                try await Task.sleep(for: options.pollInterval)
            }
        } catch { if !Task.isCancelled { fail(error) } }
    }

    private func requireCurrent() throws {
        try requireEffect()
        try channel.requireCurrent()
        if let failure = lease?.failure { throw failure }
    }

    private func requireEffect() throws {
        if let primary { throw primary.error }
        try Task.checkCancellation()
        try lease?.requireEffectCurrent()
    }

    private func fail(_ error: any Error) {
        guard primary == nil, !finished else { return }
        let diagnostic = AudioPlaybackFailureDiagnostic.label(for: error)
        SkyBridgeLogger.shared.error("Audio file send failure phase=\(phase) reason=\(Self.reason(error)) cause=\(diagnostic)")
        primary = (Self.reason(error), error); phase = .stopping; publishWorkProgress()
        membershipRenewal?.cancel()
        execution?.cancel(); transferring?.cancel(); connection.cancel(); signal()
    }

    private func signal() { let continuation = wake; wake = nil; continuation?.resume() }
    private func recordHashProgress(_ completed: Int64, total: Int64) throws {
        try requireCurrent()
        guard phase == .inspecting, total >= 0, completed >= 0, completed <= total,
              hashProgress.map({ $0.total == total && completed >= $0.completed }) ?? true else {
            throw IOSOriginalFileSendError.invalidProgress
        }
        hashProgress = (completed, total)
    }
    private func publishWorkProgress() {
        let snapshot = WorkProgress(phase: phase, hashedBytes: hashProgress?.completed ?? 0,
            hashTotal: hashProgress?.total, transferredBytes: receipt?.file.receivedBytes ?? transferredBytes, fileBytes: content?.length,
            outputFrames: receipt?.sourceFrames ?? outputSourceFrames ?? 0, sourceFrames: content?.frameCount)
        if snapshot != workProgress { workProgress = snapshot }
    }
    private func changePhase(_ value: Phase) { phase = value; phaseBegan = now(); publishWorkProgress() }

    private func closeResources(retrying: Bool) async -> [String] {
        var errors: [String] = []
        if !retrying, let previous = transferCleanup?.connectionFailure { errors.append(previous) }
        else { do { try await connection.close() } catch { errors.append("connection: \(error)") } }
        if !retrying, let previous = transferCleanup?.sourceFailure { errors.append(previous) }
        else { do { try await source.close() } catch { errors.append("source: \(error)") } }
        let sourceClosed = await source.isClosed
        cleanupPending = !connection.isClosed || !sourceClosed
        return errors
    }

    private static func reason(_ error: any Error) -> AudioStreamingStopReason {
        if let error = error as? IOSOriginalFileSendError {
            switch error {
            case .peerStopped(let reason): return reason
            case .timeout: return .timedOut
            case .stopped: return .userStopped
            case .leaseBindingMismatch: return .accountRevoked
            case .receiptMismatch: return .contentMismatch
            case .unsupportedDuration, .unsupportedFormat: return .unsupportedSource
            case .cleanupPending: return .sourceFailed
            default: return .protocolViolation
            }
        }
        if error is AudioMembershipLeaseFailure || error is AudioMembershipError || error is AudioAccountProviderError { return .accountRevoked }
        if let error = error as? AudioStreamingChannelError {
            switch error {
            case .timedOut: return .timedOut
            case .queueOverflow: return .queueOverflow
            case .unsupportedPeer: return .unsupportedOutput
            default: return .sessionReplaced
            }
        }
        if error is CancellationError { return .userStopped }
        if error is AudioWavePCMFileError || error is AudioFlacMetadataError || error is AudioAlacFileError { return .unsupportedSource }
        return .sourceFailed
    }
}
