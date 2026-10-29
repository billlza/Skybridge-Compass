#if os(macOS)
import AVFAudio
import Combine
import CryptoKit
import Foundation
import os
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

/// Actual MAIN preparation, account lease, approval, receiver and codec. Native Bluetooth
/// publication/attachment and output hardware are explicit substitutes, not radio/playback proof.
@MainActor
final class AudioBluetoothReceiveSessionTests: XCTestCase {
    private enum Failure: Error { case closed, missingOwner, gateTimeout, completionWrite, cleanup, unexpected }
    private struct Conditions: Sendable {
        var accountCurrent = true, parentCurrent = true
        var holdEstablish = false, holdReady = false, holdOutputPrepare = false
        var failCompletion = false, failLinkClose = false
        var outputAllocations = 0, strictOutputCalls = 0, prepareEntered = false
    }
    private final class Link: AudioBluetoothPlaybackLink {
        struct State: Sendable {
            var current: (@Sendable () throws -> Void)?
            var publications = 0, establishments = 0, receives = 0, closes = 0
            var closed = false, readyAttempted = false, readySent = false
            var sent: [AudioStreamingMessage] = []
            var incoming: [AudioStreamingMessage] = []
            var waitingRead: CheckedContinuation<AudioStreamingMessage, any Error>?
            var waitingEstablish: CheckedContinuation<Void, any Error>?
            var waitingReady: CheckedContinuation<Void, any Error>?
            var binding: AudioBluetoothBinding?
            var attachment: AudioBluetoothAttachment?
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        let conditions: OSAllocatedUnfairLock<Conditions>
        let route: AudioBluetoothRoute
        let offer: AudioStreamingMessage
        init(offer: AudioStreamingMessage, conditions: OSAllocatedUnfairLock<Conditions>) throws {
            self.offer = offer; self.conditions = conditions
            route = try .init(serviceID: UUID(), publicationID: UUID(), psm: 129)
        }
        func configure(_ current: @escaping @Sendable () throws -> Void) {
            state.withLock { $0.current = current }
        }
        private func requireCurrent() throws {
            let callback = state.withLock { $0.current }
            guard let callback else { throw Failure.missingOwner }
            try callback()
            if state.withLock({ $0.closed }) { throw Failure.closed }
        }
        func publish() async throws -> AudioBluetoothRoute {
            try requireCurrent(); state.withLock { $0.publications += 1 }; return route
        }
        func establish(_ attachment: AudioBluetoothAttachment) async throws {
            try requireCurrent()
            guard attachment.binding.role == .sink, attachment.binding.offer == offer,
                  attachment.binding.route == .init(streamID: offer.streamID, body: .bluetoothRoute(route)) else { throw Failure.unexpected }
            state.withLock { $0.establishments += 1; $0.binding = attachment.binding; $0.attachment = attachment }
            if conditions.withLock({ $0.holdEstablish }) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let cancelled = state.withLock { value in
                            if Task.isCancelled || value.closed { return true }
                            value.waitingEstablish = continuation; return false
                        }
                        if cancelled { continuation.resume(throwing: CancellationError()) }
                    }
                } onCancel: { self.cancelWaiters() }
            }
            try Task.checkCancellation(); try requireCurrent()
        }
        func send(_ message: AudioStreamingMessage, requireEffect: @escaping @Sendable () throws -> Void) async throws {
            try requireCurrent(); try requireEffect()
            if case .opusOutputReady = message.body {
                state.withLock { $0.readyAttempted = true }
                if conditions.withLock({ $0.holdReady }) {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { continuation in
                            let cancelled = state.withLock { value in
                                if Task.isCancelled || value.closed { return true }
                                value.waitingReady = continuation; return false
                            }
                            if cancelled { continuation.resume(throwing: CancellationError()) }
                        }
                    } onCancel: { self.cancelWaiters() }
                }
            }
            if case .playbackComplete = message.body, conditions.withLock({ $0.failCompletion }) { throw Failure.completionWrite }
            try requireCurrent(); try requireEffect(); try Task.checkCancellation()
            state.withLock {
                $0.sent.append(message)
                if case .opusOutputReady = message.body { $0.readySent = true }
            }
        }
        func receive(requireEffect: @escaping @Sendable () throws -> Void) async throws -> AudioStreamingMessage {
            try requireCurrent(); try requireEffect()
            let result: AudioStreamingMessage = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let immediate: Result<AudioStreamingMessage, any Error>? = state.withLock { value in
                        value.receives += 1
                        guard value.readySent else { return .failure(Failure.unexpected) }
                        if Task.isCancelled || value.closed { return .failure(CancellationError()) }
                        if !value.incoming.isEmpty { return .success(value.incoming.removeFirst()) }
                        guard value.waitingRead == nil else { return .failure(Failure.unexpected) }
                        value.waitingRead = continuation; return nil // One pending native read.
                    }
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: { self.cancelWaiters() }
            try requireCurrent(); try requireEffect(); return result
        }
        func releaseReady() {
            let waiter = state.withLock { value in let waiter = value.waitingReady; value.waitingReady = nil; return waiter }
            waiter?.resume()
        }
        func closeAndAwait() async throws {
            state.withLock { $0.closes += 1; $0.closed = true }
            cancelWaiters()
            if conditions.withLock({ $0.failLinkClose }) { throw Failure.cleanup }
        }
        private func cancelWaiters() {
            let waiters = state.withLock { value in
                let result = (value.waitingRead, value.waitingEstablish, value.waitingReady)
                value.waitingRead = nil; value.waitingEstablish = nil; value.waitingReady = nil
                return result
            }
            waiters.0?.resume(throwing: CancellationError())
            waiters.1?.resume(throwing: CancellationError())
            waiters.2?.resume(throwing: CancellationError())
        }
    }
    private final class Driver: CoreAudioOpusDriver {
        struct Buffer: Sendable { let end: UInt64; let complete: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void }
        struct State: Sendable {
            var samples = Data(), buffers: [Buffer] = []
            var running = false, allowCompletion = false
            var position: Int64 = 0
            var starts = 0, closes = 0, delivered = 0
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        func schedule(_ pcm16LE: Data, completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
            let running = state.withLock { value in
                value.samples.append(pcm16LE)
                value.buffers.append(.init(end: UInt64(value.samples.count / 4), complete: completion))
                return value.running && value.allowCompletion
            }
            if running { completeAll() }
        }
        func start() {
            let allowed = state.withLock { $0.running = true; $0.starts += 1; return $0.allowCompletion }
            if allowed { completeAll() }
        }
        func status() -> CoreAudioOpusDriverStatus {
            state.withLock { .init(endpointCurrent: true, engineRunning: $0.running, playerPlaying: $0.running, renderedSourceFrame: $0.position) }
        }
        func completeAll() {
            let completed = state.withLock { value in
                let result = Array(value.buffers.dropFirst(value.delivered))
                value.delivered = value.buffers.count
                if let end = result.last?.end { value.position = Int64(end) }
                return result
            }
            completed.forEach { $0.complete(.dataPlayedBack) }
        }
        func close() {
            let callbacks = state.withLock { $0.running = false; $0.closes += 1; return $0.buffers }
            callbacks.forEach { $0.complete(.dataPlayedBack) } // Native stop callback counterexample.
        }
    }
    private struct EncodedFixture: Decodable {
        let name: String
        let expectedPCMFrames: UInt64
        let preSkipFrames: UInt16
        let expectedDecodedSHA256: String
        let packetBase64: [String]
        static func load() throws -> Self {
            struct Root: Decodable { let streams: [EncodedFixture] }
            let url = try XCTUnwrap(Bundle.module.url(forResource: "opus-product-encoder-v1", withExtension: "json"))
            return try XCTUnwrap(JSONDecoder().decode(Root.self, from: Data(contentsOf: url)).streams.first {
                $0.name == "android-product-2-192000-3517-960"
            })
        }
    }
    @MainActor private final class Fixture {
        let id = UUID(), mailbox = P2PAudioMailbox(), driver = Driver()
        let conditions = OSAllocatedUnfairLock(initialState: Conditions())
        let mainSent = OSAllocatedUnfairLock<[AudioStreamingMessage]>(initialState: [])
        let strictFormats = OSAllocatedUnfairLock<[AudioStreamingPCMFormat]>(initialState: [])
        let outputPrepareGate = DispatchSemaphore(value: 0)
        let approvals: AudioPlaybackApprovalService
        let channel: P2PAudioChannel
        let lease: AudioMembershipLease
        let offer: AudioStreamingMessage
        let link: Link
        let encoded: EncodedFixture
        let digest: Data
        private var subscription: AnyCancellable?

        init(autoApprove: Bool = true, buffered: Bool = false) throws {
            approvals = try AudioPlaybackApprovalService()
            encoded = try EncodedFixture.load()
            let packets = try encoded.packetBase64.map { try XCTUnwrap(Data(base64Encoded: $0)) }
            digest = Data(SHA256.hash(data: packets.reduce(into: Data()) { $0.append($1) }))
            let format = try AudioStreamingOpusFormat(channels: 2, bitrate: 192_000)
            offer = .init(streamID: id, body: buffered ? .bufferedOpusFileOffer(format)
                : .opusOffer(source: .originalFile, format: format))
            link = try Link(offer: offer, conditions: conditions)
            let streamID = id
            let input: [AudioStreamingMessage] = [.init(streamID: id, body: .opusConfiguration(preSkipFrames: encoded.preSkipFrames))] +
                packets.enumerated().map { AudioStreamingMessage(streamID: streamID, body: .opusData(sequence: UInt64($0.offset), bytes: $0.element)) } +
                [.init(streamID: id, body: .opusEnd(sourceFrames: encoded.expectedPCMFrames, packetCount: UInt64(packets.count),
                    totalEncodedBytes: UInt64(packets.count * 480), sha256: digest))]
            let wireChecked = try input.map { try AudioStreamingWire.decode(AudioStreamingWire.encode($0)) }
            link.state.withLock { $0.incoming = wireChecked }
            let binding = try ProtocolIdentityBinding(deviceId: "bluetooth-receiver-0001", protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyBytes: Data(repeating: 1, count: 32))
            let local = try AudioProtocolIdentity(binding)
            let peer = try AudioProtocolIdentity(deviceID: "bluetooth-sender-0002", algorithm: .ed25519, fingerprint: String(repeating: "a", count: 64))
            let account = try AudioAccountIdentity(authority: "https://account.invalid", tenantID: "tenant", userID: "user")
            func row(_ identity: AudioProtocolIdentity, caller: Bool) -> AccountDeviceRecord {
                .init(deviceId: identity.deviceID, deviceName: nil, status: "active", protocolSigningAlgorithm: identity.algorithm.rawValue,
                    protocolPublicKeyFingerprint: identity.fingerprint, platformRawValue: nil, deviceModel: nil, osVersion: nil,
                    appVersion: nil, lanAddresses: [], publicAddress: nil, capabilities: [], registeredAtEpochMilliseconds: nil,
                    lastSeenAtEpochMilliseconds: nil, presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: caller)
            }
            let time: Int64 = 100_000, mono = ContinuousClock.now
            let evidence = try AudioAccountMembership.verifyFreshResponse(.init(generatedAtEpochMilliseconds: time,
                callerDeviceId: local.deviceID, truncated: false, devices: [row(local, caller: true), row(peer, caller: false)], accountScope: account.serverScope),
                account: account, local: local, peer: peer, requestStartedMilliseconds: time, receivedMilliseconds: time,
                requestStartedMonotonic: mono, receivedMonotonic: mono)
            let mailbox = mailbox, conditions = conditions, mainSent = mainSent
            let current: @Sendable () throws -> Void = {
                try mailbox.requireActive()
                guard conditions.withLock({ $0.parentCurrent }) else { throw P2PAudioTransportError.staleOwner }
            }
            channel = P2PAudioChannel(mailbox: mailbox, remoteIdentity: peer, localIdentityBinding: binding, controlTransport: .network, validateOwner: current,
                prepareBluetooth: {
                    try current()
                    let binding = try mailbox.takeBluetoothBinding()
                    let secret = try AudioBluetoothAttachmentSecret(binding: binding, sendKey: Data(repeating: 3, count: 32),
                        receiveKey: Data(repeating: 4, count: 32), transcriptHash: Data(repeating: 5, count: 32), suite: 0x1001)
                    return AudioBluetoothAttachment(binding: binding, secret: secret, requireParentCurrent: current)
                }, send: { message, effect in
                    try current(); try effect?()
                    let completion = AudioStreamingSendCompletion()
                    try mailbox.prepareSend(message, peerCapabilities: [], completion: completion)
                    defer { mailbox.finishSend(completion) }
                    mainSent.withLock { $0.append(message) }
                    completion.finish(.success(()))
                    try mailbox.commitSent(message)
                }, close: { mailbox.finish(.closed) })
            lease = try AudioMembershipLease(evidence: evidence, ownerID: channel.ownerID, account: account, local: local, peer: peer,
                wallMilliseconds: { time }, isAccountCurrent: { conditions.withLock { $0.accountCurrent } },
                isPeerCurrent: { conditions.withLock { $0.parentCurrent } && !mailbox.isTerminal })
            if autoApprove {
                let approvals = approvals
                subscription = approvals.$pendingRequest.compactMap { $0 }.sink { _ = approvals.resolve($0, allowOnce: true) }
            }
        }
        var bluetooth: AudioBluetoothPlaybackDependencies {
            let link = link, conditions = conditions, driver = driver, gate = outputPrepareGate
            return .init(makeLink: { _, current in link.configure(current); return link }, makeOutput: { owner, buffering, effect in
                conditions.withLock { $0.outputAllocations += 1 }
                return try CoreAudioOpusOutput(ownerID: owner, buffering: buffering, requireAuthorization: effect, makeDriver: { _, _ in
                    conditions.withLock { $0.prepareEntered = true }
                    if conditions.withLock({ $0.holdOutputPrepare }), gate.wait(timeout: .now() + 3) == .timedOut { throw Failure.gateTimeout }
                    return driver
                }, automaticMonitoring: false)
            })
        }
        func session() -> AudioPlaybackReceiveSession {
            let lease = lease, conditions = conditions, formats = strictFormats
            return AudioPlaybackReceiveSession(channel: channel, selectOutput: { "fixture-output" }, authorize: { _ in lease },
                approvals: approvals, outputFactory: { _, _ in conditions.withLock { $0.strictOutputCalls += 1 }; throw Failure.unexpected },
                bluetooth: bluetooth, onFormat: { format in formats.withLock { $0.append(format) } }, onPhase: { _ in })
        }
    }

    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw Failure.gateTimeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testActualReceiverBindsRouteAndWaitsForNativeCompletionOnBluetoothLane() async throws {
        let f = try Fixture(), session = f.session()
        let task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        try await wait { f.link.state.withLock { $0.sent.contains { if case .contentVerified = $0.body { true } else { false } } } }
        XCTAssertFalse(f.link.state.withLock { $0.sent.contains { if case .playbackComplete = $0.body { true } else { false } } })
        XCTAssertEqual(f.link.state.withLock { $0.binding?.offer }, f.offer)
        XCTAssertEqual(f.mainSent.withLock { $0.map(\.body) }, [.bluetoothRoute(f.link.route)])
        XCTAssertTrue(f.strictFormats.withLock { $0.isEmpty })
        XCTAssertEqual(f.conditions.withLock { $0.strictOutputCalls }, 0)
        f.driver.completeAll()
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 3517); XCTAssertEqual(receipt.sha256, f.digest)
        XCTAssertEqual(receipt.format.sampleRate, 48_000); XCTAssertEqual(receipt.format.encoding, .signed16)
        let samples = f.driver.state.withLock { $0.samples }
        XCTAssertEqual(SHA256.hash(data: samples).map { String(format: "%02x", $0) }.joined(), f.encoded.expectedDecodedSHA256)
        XCTAssertEqual(f.driver.state.withLock { $0.closes }, 1)
        XCTAssertEqual(f.link.state.withLock { $0.closes }, 1)
        XCTAssertTrue(f.conditions.withLock { $0.parentCurrent })
    }

    func testBufferedShortFileUsesExtendedWindowAndStillWaitsForNativeCompletion() async throws {
        let f = try Fixture(buffered: true), session = f.session()
        let task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        try await wait { f.link.state.withLock { $0.sent.contains { if case .contentVerified = $0.body { true } else { false } } } }
        XCTAssertEqual(f.link.state.withLock { $0.sent.first?.body }, .accept(receiveWindowBytes: 64 * 480))
        XCTAssertFalse(f.link.state.withLock { $0.sent.contains { if case .playbackComplete = $0.body { true } else { false } } })
        XCTAssertEqual(f.link.state.withLock { $0.binding?.offer }, f.offer)
        XCTAssertEqual(f.conditions.withLock { $0.strictOutputCalls }, 0)
        f.driver.completeAll()
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 3517)
        XCTAssertEqual(receipt.sha256, f.digest)
        XCTAssertEqual(f.driver.state.withLock { $0.closes }, 1)
        XCTAssertEqual(f.link.state.withLock { $0.closes }, 1)
        XCTAssertTrue(f.conditions.withLock { $0.parentCurrent })
    }

    func testApprovalDeclineDoesNotPublishBluetoothOrAllocateOutput() async throws {
        let f = try Fixture(autoApprove: false), session = f.session()
        let task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        try await wait { f.approvals.pendingRequest != nil }
        let request = try XCTUnwrap(f.approvals.pendingRequest)
        XCTAssertEqual(request.source, try AudioPlaybackSource(offer: f.offer))
        XCTAssertEqual(f.link.state.withLock { $0.publications }, 0)
        XCTAssertEqual(f.conditions.withLock { $0.outputAllocations }, 0)
        XCTAssertTrue(f.approvals.resolve(request, allowOnce: false))
        do { _ = try await task.value; XCTFail("Declined playback completed") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .receiverDeclined) }
        XCTAssertEqual(f.link.state.withLock { $0.publications }, 0)
    }

    func testCancelDuringChildEstablishmentClosesExactOwnerBeforeOutput() async throws {
        let f = try Fixture(); f.conditions.withLock { $0.holdEstablish = true }
        let session = f.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        try await wait { f.link.state.withLock { $0.waitingEstablish != nil } }
        await session.stop()
        do { _ = try await task.value; XCTFail("Cancelled establishment completed") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
        XCTAssertEqual(f.conditions.withLock { $0.outputAllocations }, 0)
        XCTAssertEqual(f.link.state.withLock { $0.closes }, 1)
        let attachment = try XCTUnwrap(f.link.state.withLock { $0.attachment })
        XCTAssertThrowsError(try attachment.handshakeRemainingTime())
        XCTAssertTrue(f.conditions.withLock { $0.parentCurrent })
    }

    func testMediaReaderStartsOnlyAfterOutputReadyWriteCompletes() async throws {
        let f = try Fixture(); f.conditions.withLock { $0.holdReady = true }
        f.driver.state.withLock { $0.allowCompletion = true }
        let session = f.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        try await wait { f.link.state.withLock { $0.waitingReady != nil } }
        XCTAssertEqual(f.link.state.withLock { $0.receives }, 0)
        XCTAssertTrue(f.driver.state.withLock { $0.samples.isEmpty })
        f.link.releaseReady()
        let receipt = try await task.value
        XCTAssertEqual(receipt.sourceFrames, 3517)
    }

    func testAccountRevocationStopsQueuedOutputWithoutCompletion() async throws {
        let f = try Fixture(), session = f.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        try await wait { f.driver.state.withLock { $0.starts == 1 } }
        f.conditions.withLock { $0.accountCurrent = false }
        do { _ = try await task.value; XCTFail("Revoked playback completed") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .accountRevoked) }
        XCTAssertFalse(f.link.state.withLock { $0.sent.contains { if case .playbackComplete = $0.body { true } else { false } } })
        XCTAssertFalse(f.driver.state.withLock { $0.running })
        XCTAssertEqual(f.link.state.withLock { $0.closes }, 1)
    }

    func testCompletionWriteFailureDoesNotReturnSuccessfulPlaybackReceipt() async throws {
        let f = try Fixture(); f.conditions.withLock { $0.failCompletion = true }
        f.driver.state.withLock { $0.allowCompletion = true }
        let session = f.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        do { _ = try await task.value; XCTFail("Failed completion write became success") }
        catch is AudioPlaybackReceiveFailure { XCTAssertEqual(f.link.state.withLock { $0.closes }, 1) }
        XCTAssertFalse(f.link.state.withLock { $0.sent.contains { if case .playbackComplete = $0.body { true } else { false } } })
    }

    func testTransportCleanupFailureRetainsSameOwnerForExplicitRetry() async throws {
        let f = try Fixture(); f.conditions.withLock { $0.failLinkClose = true }
        f.driver.state.withLock { $0.allowCompletion = true }
        let session = f.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        do { _ = try await task.value; XCTFail("Unconfirmed cleanup became success") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertFalse(failure.cleanupFailures.isEmpty) }
        let pending = await session.outputCleanupStatus()
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(f.link.state.withLock { $0.closes }, 1)
        f.conditions.withLock { $0.failLinkClose = false }
        let cleaned = try await session.retryOutputCleanup()
        XCTAssertEqual(cleaned.state, .released)
        XCTAssertEqual(f.link.state.withLock { $0.closes }, 2)
        XCTAssertEqual(f.conditions.withLock { $0.outputAllocations }, 1)
    }

    func testNativePreparationDoesNotBlockSessionCancellation() async throws {
        let f = try Fixture(); f.conditions.withLock { $0.holdOutputPrepare = true }
        defer { f.outputPrepareGate.signal() }
        let session = f.session(), task = Task { try await session.run() }
        addTeardownBlock { await session.stop(); _ = await task.result }
        try f.mailbox.receive(f.offer)
        try await wait { f.conditions.withLock { $0.prepareEntered } }
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let stop = Task { await session.stop(); stopped.withLock { $0 = true } }
        try await wait { stopped.withLock { $0 } }
        f.outputPrepareGate.signal(); await stop.value
        do { _ = try await task.value; XCTFail("Stopped preparation completed") }
        catch let failure as AudioPlaybackReceiveFailure { XCTAssertEqual(failure.reason, .userStopped) }
        XCTAssertEqual(f.driver.state.withLock { $0.starts }, 0)
        XCTAssertEqual(f.link.state.withLock { $0.closes }, 1)
    }
}
#endif
