import Foundation
import Combine
import CryptoKit
import SkyBridgeAppleTransport
import SkyBridgeOpus
import SkyBridgeProtocolCore
import os

@MainActor
protocol IOSBluetoothAudioSendLink: AnyObject {
    var binding: AudioBluetoothBinding { get }
    func connect() async throws
    func send(_ message: AudioStreamingMessage, authorize: @escaping @Sendable () throws -> Void) async throws
    func receive(authorize: @escaping @Sendable () throws -> Void) async throws -> AudioStreamingMessage
    func closeAndAwait() async throws
}

@MainActor
final class IOSNativeBluetoothAudioSendLink: IOSBluetoothAudioSendLink {
    let binding: AudioBluetoothBinding
    private let connector: BluetoothAudioConnector
    init(attachment: AudioBluetoothAttachment, authorize: @escaping @Sendable () throws -> Void) throws {
        binding = attachment.binding
        connector = try BluetoothAudioConnector(attachment: attachment, requireCurrent: authorize)
    }
    func connect() async throws { try await connector.connect() }
    func send(_ message: AudioStreamingMessage, authorize: @escaping @Sendable () throws -> Void) async throws {
        try await connector.channel.send(message, requireEffectAuthorization: authorize)
    }
    func receive(authorize: @escaping @Sendable () throws -> Void) async throws -> AudioStreamingMessage {
        try await connector.channel.receive(timeout: .seconds(30), requireEffectAuthorization: authorize)
    }
    func closeAndAwait() async throws { try await connector.closeAndAwait() }
}

struct IOSOpusFileSendReceipt: Sendable {
    let streamID: UUID
    let originalFormat: AudioStreamingPCMFormat
    let transmittedFormat: AudioStreamingOpusFormat
    let buffering: AudioStreamingOpusBuffering
    let sourceFrames: UInt64 // Decoded 48 kHz timebase, not original file frames.
    let packetCount: UInt64
    let encodedBytes: UInt64
    let sha256: Data // Compressed packets, not the original file digest.
    let trailingPaddingFrames: UInt32
}

enum IOSOpusFileSendError: Error, Equatable, Sendable {
    case alreadyStarted, invalidOptions, leaseBindingMismatch, bindingMismatch
    case unexpectedControl, wrongStream, invalidCredit, invalidProgress, invalidWindow
    case contentMismatch, timedOut, stopped, cleanupPending
    case peerStopped(AudioStreamingStopReason)
}

struct IOSOpusFileSendFailure: Error, Sendable {
    let reason: AudioStreamingStopReason
    let underlying: any Error
    let cleanupFailures: [String]
}

/// One selected file, one finite account lease, one exact MAIN and one CoC child.
/// MAIN carries only preparation/Stop. Native encoding waits for child Accept and
/// OutputReady. Every packet write and codec operation uses the captured effect
/// gate; no storage, discovery or MainActor hop occurs inside a native write gate.
/// A successful result is the authenticated receiver's report, not a DAC measurement.
@MainActor
final class IOSOpusFileSendSession: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle, authorizing, inspecting, awaitingRoute, connectingBluetooth
        case awaitingAcceptance, streaming, awaitingContent, awaitingPlayback
        case stopping, completed, failed
    }
    /// Finite work, not an estimate of audible position. Receiver credit retires
    /// packet contributions; only its validated terminal receipt completes output.
    struct WorkProgress: Equatable, Sendable {
        let phase: Phase
        let preparationCompleted: Bool
        let totalPackets: UInt64?
        let sentPackets: UInt64
        let retiredPackets: UInt64
    }
    struct Options {
        /// Explicit local qualification only; no timing collection in normal file playback.
        var recordsTiming = false
        var authorizationTimeout: Duration = .seconds(45)
        var inspectionTimeout: Duration = .seconds(180)
        var routeTimeout: Duration = .seconds(120)
        var outputTimeout: Duration = .seconds(15)
        var progressTimeout: Duration = .seconds(10)
        var creditTimeout: Duration = .seconds(5)
        var completionTimeout: Duration = .seconds(30)
        var pollInterval: Duration = .milliseconds(50)
        func validate() throws {
            guard [authorizationTimeout, routeTimeout, outputTimeout, progressTimeout,
                   creditTimeout, completionTimeout].allSatisfy({ $0 > .zero && $0 <= .seconds(120) }),
                  inspectionTimeout > .zero, inspectionTimeout <= .seconds(180),
                  pollInterval > .zero, pollInterval <= .milliseconds(100) else {
                throw IOSOpusFileSendError.invalidOptions
            }
        }
    }
    struct Timing {
        struct Stage {
            var count = 0
            var total: Duration = .zero
            var maximum: Duration = .zero
            mutating func record(since began: ContinuousClock.Instant?) {
                guard let began else { return }
                let elapsed = began.duration(to: .now)
                count += 1; total += elapsed; maximum = max(maximum, elapsed)
            }
            var diagnostic: String {
                func milliseconds(_ value: Duration) -> Double {
                    let parts = value.components
                    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
                }
                return "count=\(count),totalMs=\(milliseconds(total)),maxMs=\(milliseconds(maximum))"
            }
        }
        var source = Stage(), credit = Stage(), write = Stage()
    }
    private(set) var timing = Timing()
    var timingDiagnostic: String {
        let window = offeredBuffering.map { String($0.windowPackets) } ?? "unavailable"
        return "windowPackets=\(window) packets=\(packets) confirmed=\(confirmedBytes) retired=\(retiredBytes) source[\(timing.source.diagnostic)] credit[\(timing.credit.diagnostic)] write[\(timing.write.diagnostic)]"
    }
    typealias MakeLink = @MainActor (AudioBluetoothAttachment, @escaping @Sendable () throws -> Void) throws -> any IOSBluetoothAudioSendLink
    @Published private(set) var phase = Phase.idle
    @Published private(set) var plan: IOSOpusFilePlan?
    @Published private(set) var sentBytes: UInt64 = 0
    @Published private(set) var workProgress = WorkProgress(phase: .idle,
        preparationCompleted: false, totalPackets: nil, sentPackets: 0, retiredPackets: 0)
    @Published private(set) var receipt: IOSOpusFileSendReceipt?
    @Published private(set) var failure: IOSOpusFileSendFailure?
    @Published private(set) var cleanupPending = false
    @Published private(set) var authorizationExpiresAt: Date?
    @Published private(set) var authorizationRenewalState: AudioMembershipRenewalState?
    private(set) var lastAuthorizationRenewalFailure: (any Error)?
    let streamID: UUID
    let source: IOSOpusFileSource
    private let channel: IOSAudioChannel
    private let authority: IOSOpusFileSendAuthority
    private let authorize: @MainActor (IOSAudioChannel) async throws -> AudioMembershipLease
    private let renewMembership: IOSAudioMembershipRenewal?
    private let makeLink: MakeLink
    private let options: Options
    private let operationID = UUID()
    private var lease: AudioMembershipLease?
    private var link: (any IOSBluetoothAudioSendLink)?
    private var attachment: AudioBluetoothAttachment?
    private var started = false, finished = false, ownsChannel = false, finishingIO = false
    private var sourceClosed = false, offerAttempted = false, peerStopped = false
    private var primary: (reason: AudioStreamingStopReason, error: any Error)?
    private var execution: Task<IOSOpusFileSendReceipt, Error>?
    private var mainReader: Task<Void, Never>?, mediaReader: Task<Void, Never>?, watcher: Task<Void, Never>?
    private var membershipRenewal: Task<Void, Never>?
    private var cleanup: (UUID, Task<[String], Never>)?
    private var wake: CheckedContinuation<Void, Never>?
    private var route: AudioStreamingMessage?
    private var accepted = false, ready = false, configured = false
    private var offeredBuffering: AudioStreamingOpusBuffering?
    private var confirmedBytes: UInt64 = 0, attemptedBytes: UInt64 = 0, retiredBytes: UInt64 = 0, packets: UInt64 = 0
    private var expectedPackets: UInt64?
    private var digest = SHA256(), finalDigest: Data?
    private var endAttempted = false, endWritten = false, verified = false
    private var playback: (frames: UInt64, padding: UInt32)?
    private var phaseBegan: ContinuousClock.Instant = .now
    private var progress: ContinuousClock.Instant = .now
    private var creditBegan: ContinuousClock.Instant?
    private var endBegan: ContinuousClock.Instant?
    private var publishedAt: ContinuousClock.Instant = .now

    init(url: URL, channel: IOSAudioChannel, renewMembership: IOSAudioMembershipRenewal?,
         bitrate: UInt32 = IOSOpusFileSource.defaultBluetoothBitrate, streamID: UUID = UUID(), options: Options = Options(),
         authorize: @escaping @MainActor (IOSAudioChannel) async throws -> AudioMembershipLease = {
             try await IOSAudioAccountMembershipProvider.shared.lease(for: $0)
         }, makeLink: @escaping MakeLink = { try IOSNativeBluetoothAudioSendLink(attachment: $0, authorize: $1) }) throws {
        let authority = IOSOpusFileSendAuthority()
        source = try IOSOpusFileSource(url: url, bitrate: bitrate, requireEffectAuthorization: { try authority.check() })
        self.authority = authority; self.channel = channel; self.renewMembership = renewMembership
        self.streamID = streamID; self.options = options; self.authorize = authorize; self.makeLink = makeLink
    }

    func run() async throws -> IOSOpusFileSendReceipt {
        guard !started else { throw IOSOpusFileSendError.alreadyStarted }
        started = true
        if Task.isCancelled { stop() }
        let work = Task { try await execute() }; execution = work
        let result = await withTaskCancellationHandler { await work.result } onCancel: {
            Task { @MainActor [self] in stop() }
        }
        execution = nil
        if case .failure(let error) = result { fail(error) }
        if Task.isCancelled { stop() }
        if primary == nil { do { try requireCurrent() } catch { fail(error) } }
        // Retire effects before joining any background work or account request.
        finishingIO = true; authority.retire(); source.cancel()
        watcher?.cancel(); mediaReader?.cancel(); membershipRenewal?.cancel()
        await watcher?.value; await mediaReader?.value
        watcher = nil; mediaReader = nil
        var failures = await closeResources()
        if cleanupPending, primary == nil { fail(IOSOpusFileSendError.cleanupPending) }
        if let primary, ownsChannel, offerAttempted, !peerStopped {
            // A negative terminal control never authorizes audio. Its existing
            // carrier enforces the exact owner and bounded native write deadline.
            let stop = Task { @MainActor [channel] in try await channel.sendStop(primary.reason) }
            do { try await stop.value } catch { failures.append("stop_delivery: \(error)") }
        }
        if ownsChannel { channel.close() }
        mainReader?.cancel(); await mainReader?.value; mainReader = nil
        await membershipRenewal?.value; membershipRenewal = nil
        finished = true; sentBytes = confirmedBytes
        if let primary {
            let value = IOSOpusFileSendFailure(reason: primary.reason, underlying: primary.error, cleanupFailures: failures)
            failure = value; changePhase(.failed); throw value
        }
        let value = try result.get(); receipt = value; changePhase(.completed)
        return value
    }

    func stop() { fail(IOSOpusFileSendError.stopped) }
    func retryCleanup() async throws {
        guard finished else { throw IOSOpusFileSendError.cleanupPending }
        let failures = await closeResources()
        if cleanupPending { throw IOSOpusFileSendFailure(reason: .sourceFailed,
            underlying: IOSOpusFileSendError.cleanupPending, cleanupFailures: failures) }
    }

    private func execute() async throws -> IOSOpusFileSendReceipt {
        try channel.claimOperation(operationID); ownsChannel = true
        try options.validate(); try requireCurrent()
        guard channel.peerCapabilities.contains(AudioStreamingWire.opusReceiveCapability),
              channel.peerCapabilities.contains(AudioStreamingWire.bluetoothAttachmentCapability) else {
            throw AudioStreamingChannelError.unsupportedPeer
        }
        changePhase(.authorizing); watcher = Task { await poll() }
        let membership = try await authorize(channel)
        try requireCurrent()
        let local = try AudioProtocolIdentity(channel.localIdentityBindingForAccountRequest())
        guard membership.ownerID == channel.ownerID, membership.evidence.localIdentity == local,
              membership.evidence.peerIdentity == channel.remoteIdentity else { throw IOSOpusFileSendError.leaseBindingMismatch }
        lease = membership; try authority.bind(membership); try requireCurrent()
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(membership.evidence.expiresAtMilliseconds) / 1_000)
        changePhase(.inspecting)
        let prepared = try await source.prepare(); try requireCurrent(); plan = prepared
        // Only an authenticated receiver capability can select the extended offer. An older
        // receiver keeps the original opcode, window and child-key context without retries.
        let buffering: AudioStreamingOpusBuffering = channel.peerCapabilities.contains(
            AudioStreamingWire.bufferedOpusFileReceiveCapability) ? .bufferedFile : .legacy
        offeredBuffering = buffering
        let windowBytes = buffering.windowPackets * prepared.opus.packetBytes
        let offer = AudioStreamingMessage(streamID: streamID, body: buffering == .bufferedFile
            ? .bufferedOpusFileOffer(prepared.opus) : .opusOffer(source: .originalFile, format: prepared.opus))
        mainReader = Task { await readMain() }
        changePhase(.awaitingRoute); offerAttempted = true
        try await channel.send(offer, requireEffectAuthorization: { [self] in try requireEffect() })
        while route == nil { try requireCurrent(); await waitForChange() }
        try requireCurrent()
        let attachment = try channel.prepareBluetoothAttachment(); self.attachment = attachment
        guard attachment.binding.role == .source, attachment.binding.offer == offer,
              attachment.binding.route == route else { throw IOSOpusFileSendError.bindingMismatch }
        let source = self.source
        let effect: @Sendable () throws -> Void = { try source.requireEffectCurrent() }
        changePhase(.connectingBluetooth)
        let link = try makeLink(attachment, effect); self.link = link
        guard link.binding.role == .source, link.binding.offer == offer, link.binding.route == route else {
            throw IOSOpusFileSendError.bindingMismatch
        }
        try await link.connect(); try requireCurrent()
        changePhase(.awaitingAcceptance); mediaReader = Task { await readMedia(link, effect: effect) }
        while !accepted || !ready { try requireCurrent(); await waitForChange() }
        try requireCurrent(); try startRenewal(membership)
        let configuration = try await source.start(); try requireCurrent()
        guard configuration.channels == Int(prepared.opus.channels), configuration.sampleRate == 48_000,
              configuration.bitrate == Int(prepared.opus.bitrate) else { throw IOSOpusFileSendError.invalidProgress }
        guard let skip = UInt64(exactly: configuration.preSkipFrames) else { throw IOSOpusFileSendError.invalidProgress }
        let (decodedFrames, overflow) = prepared.convertedFrames.addingReportingOverflow(skip)
        let (roundedFrames, roundingOverflow) = decodedFrames.addingReportingOverflow(959)
        guard !overflow, !roundingOverflow, roundedFrames / 960 > 0,
              roundedFrames / 960 <= AudioStreamingWire.maximumOpusPacketCount else {
            throw IOSOpusFileSendError.invalidProgress
        }
        expectedPackets = roundedFrames / 960
        try await link.send(.init(streamID: streamID, body: .opusConfiguration(preSkipFrames: UInt16(configuration.preSkipFrames))), authorize: effect)
        try requireCurrent(); configured = true; progress = .now; changePhase(.streaming)
        while let packet = try await nextPacket() {
            try requireCurrent()
            guard let expectedPackets, packets < expectedPackets,
                  packet.sequence == packets, packet.firstDecodedFrame == packets * 960,
                  packet.bytes.count == Int(prepared.opus.packetBytes), packets < AudioStreamingWire.maximumOpusPacketCount else {
                throw IOSOpusFileSendError.invalidProgress
            }
            progress = .now
            do {
                // Credit receipt resets the timeout anchor, so diagnostics need their own
                // local start. Defer also records a wait which ends through cancellation.
                let began: ContinuousClock.Instant? = options.recordsTiming &&
                    attemptedBytes - retiredBytes + UInt64(prepared.opus.packetBytes) > UInt64(windowBytes) ? .now : nil
                defer { timing.credit.record(since: began) }
                while attemptedBytes - retiredBytes + UInt64(prepared.opus.packetBytes) > UInt64(windowBytes) {
                    try requireCurrent()
                    if creditBegan == nil { creditBegan = .now }
                    await waitForChange()
                }
            }
            creditBegan = nil; try requireCurrent()
            attemptedBytes = confirmedBytes + UInt64(packet.bytes.count)
            do {
                let began: ContinuousClock.Instant? = options.recordsTiming ? .now : nil
                defer { timing.write.record(since: began) }
                try await link.send(.init(streamID: streamID, body: .opusData(sequence: packets, bytes: packet.bytes)), authorize: effect)
            }
            try requireCurrent()
            confirmedBytes = attemptedBytes; packets += 1; digest.update(data: packet.bytes); progress = .now
        }
        let completion = try await source.completedEncoding(); try requireCurrent()
        let state = await source.snapshot()
        guard let expectedPackets, state.sourceVerified, state.resourcesReleased, !state.cleanupPending,
              completion.conversion.sourceFrames == prepared.sourceFrames,
              completion.conversion.convertedFrames == prepared.convertedFrames,
              completion.encoding.sourceFrames == prepared.convertedFrames,
              completion.encoding.packetCount == packets, packets == expectedPackets,
              completion.encoding.encodedBytes == confirmedBytes,
              completion.encoding.preSkipFrames == configuration.preSkipFrames,
              packets * 960 == prepared.convertedFrames + UInt64(configuration.preSkipFrames) + UInt64(completion.encoding.trailingPaddingFrames),
              (0..<960).contains(completion.encoding.trailingPaddingFrames), packets > 0 else {
            throw IOSOpusFileSendError.invalidProgress
        }
        let hash = Data(digest.finalize()); finalDigest = hash
        endAttempted = true; endBegan = .now; changePhase(.awaitingContent)
        try await link.send(.init(streamID: streamID, body: .opusEnd(sourceFrames: prepared.convertedFrames,
            packetCount: packets, totalEncodedBytes: confirmedBytes, sha256: hash)), authorize: effect)
        try requireCurrent(); endWritten = true
        while !verified || playback == nil { try requireCurrent(); await waitForChange() }
        try requireCurrent()
        guard endWritten, let playback else { throw IOSOpusFileSendError.invalidProgress }
        return .init(streamID: streamID, originalFormat: prepared.originalFormat, transmittedFormat: prepared.opus,
            buffering: buffering,
            sourceFrames: playback.frames, packetCount: packets, encodedBytes: confirmedBytes,
            sha256: hash, trailingPaddingFrames: playback.padding)
    }

    private func nextPacket() async throws -> SkyBridgeOpusEncodedPacket? {
        let began: ContinuousClock.Instant? = options.recordsTiming ? .now : nil
        defer { timing.source.record(since: began) }
        return try await source.nextPacket()
    }

    private func readMain() async {
        do {
            var iterator = channel.messages.makeAsyncIterator()
            while let message = try await iterator.next() {
                try requireCurrent()
                guard message.streamID == streamID else { throw IOSOpusFileSendError.wrongStream }
                switch message.body {
                case .bluetoothRoute:
                    guard route == nil, phase == .awaitingRoute else { throw IOSOpusFileSendError.unexpectedControl }
                    route = message; signal()
                case .stop(let reason): peerStopped = true; throw IOSOpusFileSendError.peerStopped(reason)
                default: throw IOSOpusFileSendError.unexpectedControl
                }
            }
            if !finishingIO { throw AudioStreamingChannelError.closed }
        } catch { if !finishingIO { fail(error) } }
    }
    private func readMedia(_ link: any IOSBluetoothAudioSendLink, effect: @escaping @Sendable () throws -> Void) async {
        do {
            while !finishingIO {
                let message = try await link.receive(authorize: effect)
                try requireCurrent(); try receive(message)
                // The validated playback receipt is the final peer control.
                // Do not race it with another receive of the peer's normal EOF.
                // execute() still requires the local End write and current authority.
                if playback != nil { return }
            }
        } catch { if !finishingIO { fail(error) } }
    }
    private func receive(_ message: AudioStreamingMessage) throws {
        guard message.streamID == streamID, let plan else { throw IOSOpusFileSendError.wrongStream }
        switch message.body {
        case .accept(let bytes):
            guard !accepted, phase == .awaitingAcceptance, let offeredBuffering,
                  bytes == offeredBuffering.windowPackets * plan.opus.packetBytes else { throw IOSOpusFileSendError.invalidWindow }
            accepted = true
        case .opusOutputReady:
            guard accepted, !ready, phase == .awaitingAcceptance else { throw IOSOpusFileSendError.unexpectedControl }
            ready = true
        case .credit(let bytes):
            guard configured, bytes >= retiredBytes, bytes <= attemptedBytes,
                  bytes % UInt64(plan.opus.packetBytes) == 0 else { throw IOSOpusFileSendError.invalidCredit }
            if bytes > retiredBytes { retiredBytes = bytes; creditBegan = nil }
        case .contentVerified(let total, let hash):
            guard endAttempted, !verified, total == confirmedBytes, hash == finalDigest else { throw IOSOpusFileSendError.contentMismatch }
            verified = true; changePhase(.awaitingPlayback)
        case .playbackComplete(let frames, let padding):
            guard endAttempted, verified, playback == nil, frames == plan.convertedFrames else { throw IOSOpusFileSendError.unexpectedControl }
            playback = (frames, padding)
        case .stop(let reason): peerStopped = true; throw IOSOpusFileSendError.peerStopped(reason)
        default: throw IOSOpusFileSendError.unexpectedControl
        }
        signal()
    }
    private func poll() async {
        do {
            while !Task.isCancelled {
                try requireCurrent()
                let now = ContinuousClock.now
                let limit: Duration?
                switch phase {
                case .authorizing: limit = options.authorizationTimeout
                case .inspecting: limit = options.inspectionTimeout
                case .awaitingRoute: limit = options.routeTimeout
                case .connectingBluetooth: limit = .seconds(30)
                case .awaitingAcceptance: limit = options.outputTimeout
                default: limit = nil
                }
                if let limit, now - phaseBegan >= limit { throw IOSOpusFileSendError.timedOut }
                if let creditBegan, now - creditBegan >= options.creditTimeout { throw IOSOpusFileSendError.timedOut }
                if phase == .streaming, creditBegan == nil, now - progress >= options.progressTimeout { throw IOSOpusFileSendError.timedOut }
                if let endBegan, now - endBegan >= options.completionTimeout { throw IOSOpusFileSendError.timedOut }
                if now - publishedAt >= .milliseconds(250) {
                    sentBytes = confirmedBytes; publishWorkProgress(); publishedAt = now
                }
                try await Task.sleep(for: options.pollInterval)
            }
        } catch { if !Task.isCancelled { fail(error) } }
    }
    private func startRenewal(_ membership: AudioMembershipLease) throws {
        try requireCurrent()
        guard membershipRenewal == nil else { throw IOSOpusFileSendError.leaseBindingMismatch }
        guard let renewMembership else { return }
        membershipRenewal = Task { [weak self] in
            await AudioMembershipRenewal(lease: membership, renew: { [weak self] in
                guard let self else { throw IOSOpusFileSendError.stopped }
                try await self.renewAuthorization(membership, using: renewMembership)
            }, observe: { [weak self] update in await self?.publishRenewal(update) }).run()
        }
    }
    private func renewAuthorization(_ membership: AudioMembershipLease, using renew: IOSAudioMembershipRenewal) async throws {
        try requireCurrent()
        guard lease === membership else { throw IOSOpusFileSendError.leaseBindingMismatch }
        let continued = try await renew(channel, membership)
        try requireCurrent()
        guard lease === membership, continued === membership else { throw IOSOpusFileSendError.leaseBindingMismatch }
    }
    private func publishRenewal(_ update: AudioMembershipRenewalUpdate) {
        guard !finished, membershipRenewal != nil else { return }
        lastAuthorizationRenewalFailure = update.failure
        guard primary == nil, membershipRenewal?.isCancelled == false else { return }
        authorizationExpiresAt = Date(timeIntervalSince1970: Double(update.evidence.expiresAtMilliseconds) / 1_000)
        authorizationRenewalState = update.state
    }
    private func requireCurrent() throws {
        if let primary { throw primary.error }
        try Task.checkCancellation(); try channel.requireCurrent()
        if let lease { try authority.check(); if let failure = lease.failure { throw failure } }
    }
    private func requireEffect() throws { try requireCurrent(); try source.requireEffectCurrent() }
    private func fail(_ error: any Error) {
        guard primary == nil, !finished else { return }
        if case .peerStopped = error as? AudioStreamingChannelError { peerStopped = true }
        primary = (Self.reason(error), error); changePhase(.stopping)
        authority.fail(error); source.cancel(); execution?.cancel(); membershipRenewal?.cancel(); signal()
    }
    private func changePhase(_ value: Phase) { phase = value; phaseBegan = .now; publishWorkProgress() }
    private func publishWorkProgress() {
        // A valid PlaybackComplete proves final native drain even if the last
        // credit observation was coalesced. It still cannot finish the system job
        // before run() has checked its End write and joined resource cleanup.
        let retired = playback != nil ? packets : plan.map { retiredBytes / UInt64($0.opus.packetBytes) } ?? 0
        let value = WorkProgress(phase: phase, preparationCompleted: plan != nil,
            totalPackets: expectedPackets, sentPackets: packets, retiredPackets: retired)
        if value != workProgress { workProgress = value }
    }
    private func waitForChange() async { await withCheckedContinuation { wake = $0 } }
    private func signal() { let value = wake; wake = nil; value?.resume() }

    /// Keep failed owners for explicit cleanup retry. Cancelled callers join the
    /// same cleanup task; no retry can create a second radio/file operation.
    private func closeResources() async -> [String] {
        let owned: (UUID, Task<[String], Never>)
        if let cleanup { owned = cleanup }
        else {
            let id = UUID()
            owned = (id, Task.detached { await self.finishClose() }); cleanup = owned
        }
        defer { if cleanup?.0 == owned.0 { cleanup = nil } }
        return await owned.1.value
    }
    private func finishClose() async -> [String] {
        var failures: [String] = []
        if !sourceClosed {
            do { try await source.close(); sourceClosed = true }
            catch { failures.append("source_close: \(error)") }
        }
        if let link {
            do { try await link.closeAndAwait(); self.link = nil }
            catch { failures.append("bluetooth_close: \(error)") }
        }
        attachment?.close(); attachment = nil
        cleanupPending = !sourceClosed || link != nil
        return failures
    }
    private static func reason(_ error: any Error) -> AudioStreamingStopReason {
        if let value = error as? IOSOpusFileSendError {
            switch value {
            case .peerStopped(let reason): return reason
            case .stopped: return .userStopped
            case .timedOut: return .timedOut
            case .contentMismatch: return .contentMismatch
            case .leaseBindingMismatch: return .accountRevoked
            case .cleanupPending: return .sourceFailed
            default: return .protocolViolation
            }
        }
        if error is AudioMembershipLeaseFailure || error is AudioMembershipError || error is AudioAccountProviderError { return .accountRevoked }
        if let value = error as? IOSOpusFileSourceError {
            switch value {
            case .unsupportedFormat, .unsupportedLayout, .invalidDuration: return .unsupportedSource
            case .sourceChanged: return .contentMismatch
            case .queueCapacity: return .queueOverflow
            case .cleanupTimedOut: return .timedOut
            default: return .sourceFailed
            }
        }
        if error is IOSPreparedAudioFileError { return .unsupportedSource }
        if error is AudioStreamingWireError { return .protocolViolation }
        switch error {
        case AudioStreamingChannelError.peerStopped(let reason): return reason
        case BluetoothControlStreamError.timedOut, BluetoothAudioConnectorError.timedOut,
             AudioStreamingChannelError.timedOut: return .timedOut
        case AudioStreamingChannelError.unsupportedPeer: return .unsupportedOutput
        default: break
        }
        if error is BluetoothControlStreamError || error is BluetoothAudioConnectorError || error is BluetoothAudioChannelError || error is AudioBluetoothAttachmentError { return .sessionReplaced }
        if error is AudioStreamingChannelError { return .sessionReplaced }
        if error is CancellationError { return .userStopped }
        return .sourceFailed
    }
}

/// One captured lease and synchronous stop flag. Peer lifetime is checked by
/// the exact carrier/attachment outside this lock, avoiding native-write reentry.
private final class IOSOpusFileSendAuthority: Sendable {
    private struct State: Sendable { var lease: AudioMembershipLease?; var failure: (any Error)? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func bind(_ lease: AudioMembershipLease) throws {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            guard $0.lease == nil else { throw IOSOpusFileSendError.leaseBindingMismatch }
            $0.lease = lease
        }
    }
    func check() throws {
        let value = state.withLock { $0 }
        if let failure = value.failure { throw failure }
        guard let lease = value.lease else { throw IOSOpusFileSendError.leaseBindingMismatch }
        try lease.requireEffectCurrent()
    }
    func fail(_ error: any Error) { state.withLock { if $0.failure == nil { $0.failure = error } } }
    func retire() { fail(IOSOpusFileSendError.stopped) }
}
