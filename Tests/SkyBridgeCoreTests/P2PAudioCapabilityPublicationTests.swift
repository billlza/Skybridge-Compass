import XCTest
import CryptoKit
import Foundation
import Network
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class P2PAudioCapabilityPublicationTests: XCTestCase {
    private enum Failure: Error { case expected, timeout, malformed, closed }
    @MainActor
    private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    private final class RefreshState {
        var desired = 1
        var values: [Int] = []
        var calls = 0
        var publications = 0
        var failures = 0
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testDeferredCapabilityPublicationCannotAdvertiseRemovedReceiver() async throws {
        typealias Pending = (P2PAudioCapabilityPublication.Authorization, P2PAudioCapabilityPublication.Complete)
        let pending = OSAllocatedUnfairLock<Pending?>(initialState: nil)
        let cancellations = OSAllocatedUnfairLock(initialState: 0)
        let registry = P2PAudioIncomingChannelRegistry()
        let owner = try registry.install(advertiseCapture: true) { _ in }
        let authorization = registry.capturePublicationAuthorization()
        let send = Task { @MainActor in
            try await P2PAudioCapabilityPublication.sendAuthorized(submit: { _, authorize, complete in
                pending.withLock { $0 = (authorize, complete) }
            }, cancelTransport: { cancellations.withLock { $0 += 1 } }, prepare: { enqueue in
                try enqueue(Data([1]), authorization)
            })
        }
        try await waitUntil { pending.withLock { $0 != nil } }
        registry.remove(ifOwnedBy: owner)
        let deferred = try XCTUnwrap(pending.withLock { $0 })
        XCTAssertThrowsError(try deferred.0()) { XCTAssertEqual($0 as? P2PAudioTransportError, .staleOwner) }
        deferred.1(.failure(P2PAudioTransportError.staleOwner))
        do { try await send.value; XCTFail("Removed receiver was advertised") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
        let replacement = try registry.install(advertiseCapture: true) { _ in }
        XCTAssertThrowsError(try authorization())
        XCTAssertNoThrow(try registry.capturePublicationAuthorization()())
        registry.remove(ifOwnedBy: replacement)
        XCTAssertEqual(cancellations.withLock { $0 }, 0)
    }

    func testEscapedBuilderCannotSubmitAfterPreparationCloses() async throws {
        let saved = OSAllocatedUnfairLock<P2PAudioCapabilityPublication.AuthorizedEnqueue?>(initialState: nil)
        let writes = OSAllocatedUnfairLock(initialState: 0)
        do {
            try await P2PAudioCapabilityPublication.sendAuthorized(submit: { _, _, complete in
                writes.withLock { $0 += 1 }; complete(.success(()))
            }, cancelTransport: { XCTFail("No native write was admitted") }, prepare: { enqueue in
                saved.withLock { $0 = enqueue }
            })
            XCTFail("Missing submission was accepted")
        } catch { XCTAssertEqual(error as? P2PAudioCapabilityPublicationError, .missingSubmission) }
        let enqueue = try XCTUnwrap(saved.withLock { $0 })
        XCTAssertThrowsError(try enqueue(Data([1]), {})) {
            XCTAssertEqual($0 as? P2PAudioCapabilityPublicationError, .closedPreparation)
        }
        XCTAssertEqual(writes.withLock { $0 }, 0)
    }

    func testBurstCoalescesToOnePendingRefreshThatReadsLatestState() async throws {
        let gate = Gate()
        let state = RefreshState()
        let refresh = P2PAudioCapabilityRefresh(operation: {
            state.values.append(state.desired)
            if state.values.count == 1 { await gate.wait() }
        }, reportFailure: { _ in state.failures += 1 })
        refresh.request()
        try await waitUntil { gate.entered }
        for value in 2...80 { state.desired = value; refresh.request() }
        gate.open(); await refresh.waitUntilIdle()
        XCTAssertEqual(state.values, [1, 80]); XCTAssertEqual(state.failures, 0)
        refresh.retire()
    }

    func testFailureDoesNotRetryWithoutANewNotification() async {
        let state = RefreshState()
        let refresh = P2PAudioCapabilityRefresh(operation: {
            state.calls += 1; throw Failure.expected
        }, reportFailure: { _ in state.failures += 1 })
        refresh.request(); await refresh.waitUntilIdle()
        await Task.yield()
        XCTAssertEqual(state.calls, 1); XCTAssertEqual(state.failures, 1)
        refresh.request(); await refresh.waitUntilIdle()
        XCTAssertEqual(state.calls, 2); XCTAssertEqual(state.failures, 2)
        refresh.retire(); refresh.request(); await Task.yield()
        XCTAssertEqual(state.calls, 2)
    }

    func testRetirementCancelsPreparationAndDropsPendingRefresh() async throws {
        let gate = Gate()
        let state = RefreshState()
        let refresh = P2PAudioCapabilityRefresh(operation: {
            state.calls += 1; await gate.wait()
            try Task.checkCancellation(); state.publications += 1
        }, reportFailure: { _ in state.failures += 1 })
        refresh.request(); try await waitUntil { gate.entered }
        refresh.request(); refresh.retire(); gate.open()
        await refresh.waitUntilIdle()
        XCTAssertEqual(state.calls, 1); XCTAssertEqual(state.publications, 0); XCTAssertEqual(state.failures, 0)
    }

    private func template() -> AppMessage.PairingIdentityExchangePayload {
        .init(deviceId: "capability-local", kemPublicKeys: [
            .init(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: Data(repeating: 0x21, count: 1_216))
        ], protocolIdentityPublicKeys: [
            .init(protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                  publicKey: Data(repeating: 0x31, count: 32))
        ], deviceName: "Capability fixture", modelName: "Fixture model", platform: "macos",
           osVersion: "27.0", chip: "fixture", accountDisplayName: "test account", nebulaId: "test-nebula",
           remoteVideoFormats: ["h264"], capabilities: ["file_transfer", AudioStreamingWire.captureReceiveCapability,
                                                     "remote_control", AudioStreamingWire.opusReceiveCapability,
                                                     AudioStreamingWire.bufferedOpusFileReceiveCapability,
                                                     AudioStreamingWire.alacFileReceiveCapability],
           fileTransferPort: 42_001, remoteControlPort: 42_002, sentAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testCapabilityReplacementPreservesEveryOtherPairingField() throws {
        let original = template(), replacement = original.replacingAudioReceiveCapabilities([])
        let encoder = JSONEncoder()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        var new = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(replacement)) as? [String: Any])
        XCTAssertEqual(replacement.capabilities, ["file_transfer", "remote_control"])
        old.removeValue(forKey: "capabilities"); new.removeValue(forKey: "capabilities")
        XCTAssertEqual(NSDictionary(dictionary: old), NSDictionary(dictionary: new))
        XCTAssertEqual(original.replacingAudioReceiveCapabilities([AudioStreamingWire.fileReceiveCapability]).capabilities,
                       ["file_transfer", "remote_control", AudioStreamingWire.fileReceiveCapability])
    }

    func testMissingSubmissionAndFailedPreparationNeverWrite() async {
        let writes = OSAllocatedUnfairLock(initialState: 0)
        for missing in [true, false] {
            do {
                try await P2PAudioCapabilityPublication.send(submit: { _, complete in
                    writes.withLock { $0 += 1 }; complete(.success(()))
                }, cancelTransport: { XCTFail("Unsubmitted publication cancelled MAIN") }, prepare: { _ in
                    if !missing { throw Failure.expected }
                })
                XCTFail("An unsubmitted publication succeeded")
            } catch {
                if missing { XCTAssertEqual(error as? P2PAudioCapabilityPublicationError, .missingSubmission) }
                else { XCTAssertTrue(error is Failure) }
            }
        }
        XCTAssertEqual(writes.withLock { $0 }, 0)
    }

    func testImmediateNativeSuccessCannotHidePreparationOrRepeatedSubmissionFailure() async {
        for repeatSubmission in [false, true] {
            let writes = OSAllocatedUnfairLock(initialState: 0)
            do {
                try await P2PAudioCapabilityPublication.send(submit: { _, complete in
                    writes.withLock { $0 += 1 }; complete(.success(()))
                }, cancelTransport: { XCTFail("Completed native write was cancelled") }, prepare: { enqueue in
                    try enqueue(Data([1]))
                    if repeatSubmission { try enqueue(Data([2])) }
                    else { throw Failure.expected }
                })
                XCTFail("Native success hid a preparation failure")
            } catch {
                if repeatSubmission { XCTAssertEqual(error as? P2PAudioCapabilityPublicationError, .repeatedSubmission) }
                else { XCTAssertTrue(error is Failure) }
            }
            XCTAssertEqual(writes.withLock { $0 }, 1)
        }
    }

    func testCancelledWaiterKeepsNativeWriteOwnershipUntilCompletion() async throws {
        let pending = OSAllocatedUnfairLock<P2PAudioCapabilityPublication.Complete?>(initialState: nil)
        let cancelled = OSAllocatedUnfairLock(initialState: 0)
        let operation = Task { @MainActor in
            try await P2PAudioCapabilityPublication.send(submit: { _, complete in
                pending.withLock { $0 = complete }
            }, cancelTransport: { cancelled.withLock { $0 += 1 } }, prepare: { enqueue in
                try enqueue(Data([1, 2, 3]))
            })
        }
        try await waitUntil { pending.withLock { $0 != nil } }
        operation.cancel()
        do { try await operation.value; XCTFail("Cancelled publication waiter succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelled.withLock { $0 }, 0)
        let complete = try XCTUnwrap(pending.withLock { $0 })
        complete(.success(()))
        try await Task.sleep(for: .milliseconds(5_100))
        XCTAssertEqual(cancelled.withLock { $0 }, 0)
    }

    func testNativeWriteDeadlineCancelsOnlyItsCapturedTransportOnce() async throws {
        let pending = OSAllocatedUnfairLock<P2PAudioCapabilityPublication.Complete?>(initialState: nil)
        let cancelled = OSAllocatedUnfairLock(initialState: 0)
        let operation = Task { @MainActor in
            try await P2PAudioCapabilityPublication.send(submit: { _, complete in
                pending.withLock { $0 = complete }
            }, cancelTransport: { cancelled.withLock { $0 += 1 } }, prepare: { enqueue in try enqueue(Data([4])) })
        }
        try await waitUntil { pending.withLock { $0 != nil } }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(7)); operation.cancel() }
            catch is CancellationError { return }
            catch { XCTFail("Publication watchdog failed: \(error)"); operation.cancel() }
        }
        defer { watchdog.cancel() }
        let complete = try XCTUnwrap(pending.withLock { $0 })
        do { try await operation.value; XCTFail("Timed-out native write succeeded") }
        catch { XCTAssertEqual(error as? AudioStreamingChannelError, .timedOut) }
        complete(.success(())); complete(.failure(Failure.expected))
        XCTAssertEqual(cancelled.withLock { $0 }, 1)
    }

    func testActualOutgoingPublicationUsesLatestFlagsOverNativeEncryptedTCP() async throws {
        let pair = try NativePair()
        do {
            try await pair.start()
            let registry = P2PAudioIncomingChannelRegistry()
            let token = try registry.install(advertiseCapture: true) { _ in }
            let prepared = template()
            let local = try ProtocolIdentityBinding(deviceId: prepared.deviceId, protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyBytes: Data(repeating: 0x31, count: 32))
            let peer = try ProtocolIdentityBinding(deviceId: "capability-test-peer", protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyBytes: Data(repeating: 0x41, count: 32))
            let binding = AuthenticatedHandshakePeerBinding(authority: .init(protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: peer.protocolPublicKeyFingerprint, protocolPublicKey: peer.protocolPublicKeyBytes),
                authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: peer.deviceId))
            let keys = SessionKeys(sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32),
                negotiatedSuite: .x25519Ed25519, role: .initiator, transcriptHash: Data(repeating: 3, count: 32))
            let device = P2PDevice(id: peer.deviceId, name: "Capability peer", type: .iOS, address: "127.0.0.1",
                port: try XCTUnwrap(pair.listener.port).rawValue, osVersion: "test", capabilities: [], publicKey: Data(), lastSeen: Date())
            let connection = P2PConnection(device: device, connection: try XCTUnwrap(pair.client), controlTransport: .network,
                incomingAudioRegistry: registry)
            _ = try connection.testingInstallAudioEpoch(keys: keys, peerBinding: binding, local: local, peer: peer)
            // Identity preparation started while reception was enabled. The
            // actual production publisher must read the later disabled state.
            registry.remove(ifOwnedBy: token)
            let reading = Task { @MainActor in try await pair.receiveFrame() }
            try await connection.testingPublishPreparedPairingIdentity(prepared)
            let frame = try await reading.value
            let ciphertext = TrafficPadding.unwrapIfNeeded(frame, label: "capability-test")
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: keys.sendKey))
            guard case .pairingIdentityExchange(let received) = try AppMessage.decodeWireMessage(from: plaintext) else {
                throw Failure.malformed
            }
            XCTAssertEqual(received, prepared.replacingAudioReceiveCapabilities([]))
            XCTAssertGreaterThan(connection.bytesSent, 0)
            let sentBeforeRestart = connection.bytesSent
            let restarted = try registry.install(advertiseCapture: true, originalFileSupport: .waveAndFlac) { _ in }
            let nextReading = Task { @MainActor in try await pair.receiveFrame() }
            try await connection.testingPublishPreparedPairingIdentity(prepared.replacingAudioReceiveCapabilities([]))
            let nextFrame = try await nextReading.value
            let nextCiphertext = TrafficPadding.unwrapIfNeeded(nextFrame, label: "capability-test")
            let nextPlaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: nextCiphertext), using: SymmetricKey(data: keys.sendKey))
            guard case .pairingIdentityExchange(let nextReceived) = try AppMessage.decodeWireMessage(from: nextPlaintext) else {
                throw Failure.malformed
            }
            XCTAssertEqual(nextReceived, prepared.replacingAudioReceiveCapabilities(registry.advertisedReceiveCapabilities))
            XCTAssertGreaterThan(connection.bytesSent, sentBeforeRestart)
            registry.remove(ifOwnedBy: restarted)
            try await pair.close()
        } catch {
            let primary = error
            do { try await pair.close() }
            catch { throw NSError(domain: "CapabilityNativeTestCleanup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Primary: \(primary); cleanup: \(error)"]) }
            throw primary
        }
    }

    func testSamePeerBecomingAudioReadyPublishesUSBFlagsInsideReplyThrottle() async throws {
        let pair = try NativePair()
        do {
            try await pair.start()
            let fixture = try makeUSBFixture(pair)
            defer { fixture.registry.remove(ifOwnedBy: fixture.receiver) }
            let prepared = template()

            // The authenticated identity transaction can finish while the MAIN
            // handshake still owns its operation. Its captured audio sequence is
            // nil, so this first runtime commit must not make audio available.
            let firstReply = try fixture.commit(sequence: nil)
            XCTAssertTrue(firstReply)
            XCTAssertTrue(fixture.connection.currentAudioReceiveCapabilities().isEmpty,
                          "USB must not expose an audio target before peer capability admission commits")
            let started = ContinuousClock.now
            try await fixture.connection.testingSendPreparedPairingIdentity(prepared, force: firstReply)
            let first = try await receivedPairing(pair, keys: fixture.keys)
            XCTAssertTrue(Set(first.capabilities ?? []).isDisjoint(with: fixture.registry.advertisedReceiveCapabilities),
                          "The first native publication exposed an audio source before its USB route was settled")
            let initialBytes = fixture.connection.bytesSent

            // A second identical, accepted exchange now owns the completed
            // handshake. Use the real runtime commit, throttle and encrypted
            // native sender; only the identity/Finished inputs are controlled.
            let readyReply = try fixture.commit(sequence: fixture.connection.testingAudioPairingOperationSequence)
            XCTAssertTrue(readyReply, "First audio admission for the same peer must publish its new USB capabilities")
            try await fixture.connection.testingSendPreparedPairingIdentity(prepared, force: readyReply)
            XCTAssertLessThan(started.duration(to: .now), .seconds(10))
            XCTAssertGreaterThan(fixture.connection.bytesSent, initialBytes,
                                 "Identity reply throttling hid the newly available original-file route")
            if fixture.connection.bytesSent > initialBytes {
                let ready = try await receivedPairing(pair, keys: fixture.keys)
                XCTAssertTrue(ready.capabilities?.contains(AudioStreamingWire.fileReceiveCapability) == true)
                XCTAssertTrue(ready.capabilities?.contains(AudioStreamingWire.usbFileReceiveCapability) == true)
                XCTAssertTrue(ready.capabilities?.contains(AudioStreamingWire.captureReceiveCapability) == true)
                XCTAssertTrue(ready.capabilities?.contains(AudioStreamingWire.opusReceiveCapability) == true)
                XCTAssertTrue(ready.capabilities?.contains(AudioStreamingWire.bluetoothAttachmentCapability) == true)
                XCTAssertTrue(ready.capabilities?.contains(AudioStreamingWire.bufferedOpusFileReceiveCapability) == true)
            }

            // Identical admitted exchanges must still be throttled, preventing
            // the two peers from echoing capability updates indefinitely.
            let readyBytes = fixture.connection.bytesSent
            let duplicateReply = try fixture.commit(sequence: fixture.connection.testingAudioPairingOperationSequence)
            XCTAssertFalse(duplicateReply)
            try await fixture.connection.testingSendPreparedPairingIdentity(prepared, force: duplicateReply)
            XCTAssertEqual(fixture.connection.bytesSent, readyBytes)
            try await pair.close()
        } catch {
            let primary = error
            do { try await pair.close() }
            catch { throw NSError(domain: "CapabilityNativeTestCleanup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Primary: \(primary); cleanup: \(error)"]) }
            throw primary
        }
    }

    func testUncommittedOrStalePairingCannotPublishUSBReadiness() async throws {
        let pair = try NativePair()
        do {
            try await pair.start()
            let fixture = try makeUSBFixture(pair)
            defer { fixture.registry.remove(ifOwnedBy: fixture.receiver) }
            _ = try fixture.commit(sequence: nil)
            let wrongKeys = SessionKeys(sendKey: Data(repeating: 9, count: 32),
                receiveKey: Data(repeating: 8, count: 32), negotiatedSuite: .x25519Ed25519,
                role: .initiator, transcriptHash: Data(repeating: 7, count: 32))
            let wrongAuthority = AuthenticatedRemoteAuthority(protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "ab", count: 32),
                protocolPublicKey: Data(repeating: 0x51, count: 32))
            let sequence = fixture.connection.testingAudioPairingOperationSequence
            let cases: [(String, UInt64?, SessionKeys, AuthenticatedRemoteAuthority)] = [
                ("handshake pending", nil, fixture.keys, fixture.authority),
                ("old operation", UInt64.max, fixture.keys, fixture.authority),
                ("wrong epoch", sequence, wrongKeys, fixture.authority),
                ("wrong authority", sequence, fixture.keys, wrongAuthority)
            ]
            for (label, sequence, keys, authority) in cases {
                let force = try fixture.connection.testingCommitPairingRuntimeCapabilities(fixture.peerPayload,
                    keys: keys, authority: authority, sequence: sequence)
                XCTAssertFalse(force, label)
                XCTAssertTrue(fixture.connection.currentAudioReceiveCapabilities().isEmpty,
                              "Uncommitted USB audio capabilities escaped admission: \(label)")
            }
            XCTAssertTrue(try fixture.commit(sequence: sequence))
            XCTAssertTrue(fixture.connection.currentAudioReceiveCapabilities().contains(AudioStreamingWire.usbFileReceiveCapability))
            XCTAssertFalse(try fixture.commit(sequence: sequence))
            try await pair.close()
        } catch {
            let primary = error
            do { try await pair.close() }
            catch { throw NSError(domain: "CapabilityNativeTestCleanup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Primary: \(primary); cleanup: \(error)"]) }
            throw primary
        }
    }

    private struct USBFixture {
        let connection: P2PConnection
        let registry: P2PAudioIncomingChannelRegistry
        let receiver: UUID
        let keys: SessionKeys
        let authority: AuthenticatedRemoteAuthority
        let peerPayload: AppMessage.PairingIdentityExchangePayload

        func commit(sequence: UInt64?) throws -> Bool {
            try connection.testingCommitPairingRuntimeCapabilities(peerPayload,
                keys: keys, authority: authority, sequence: sequence)
        }
    }

    private func makeUSBFixture(_ pair: NativePair) throws -> USBFixture {
        let registry = P2PAudioIncomingChannelRegistry()
        let local = try ProtocolIdentityBinding(deviceId: "capability-local", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x31, count: 32))
        let peer = try ProtocolIdentityBinding(deviceId: "usb-capability-peer", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x41, count: 32))
        let authority = AuthenticatedRemoteAuthority(protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: peer.protocolPublicKeyFingerprint, protocolPublicKey: peer.protocolPublicKeyBytes)
        let binding = AuthenticatedHandshakePeerBinding(authority: authority,
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: peer.deviceId))
        let keys = SessionKeys(sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32),
            negotiatedSuite: .x25519Ed25519, role: .initiator, transcriptHash: Data(repeating: 3, count: 32))
        let device = P2PDevice(id: peer.deviceId, name: "USB capability fixture", type: .iOS, address: "127.0.0.1",
            port: try XCTUnwrap(pair.listener.port).rawValue, osVersion: "test", capabilities: [], publicKey: Data(), lastSeen: Date())
        let connection = P2PConnection(device: device, connection: try XCTUnwrap(pair.client), controlTransport: .usb,
            incomingAudioRegistry: registry, usbDeviceID: "00000000-0000000000000000")
        _ = try connection.testingInstallAudioEpoch(keys: keys, peerBinding: binding, local: local,
            peer: peer, commitPairing: false)
        let receiver = try registry.install(advertiseCapture: true, originalFileSupport: .waveAndFlac,
                                            advertiseBluetoothOpus: true) { _ in }
        let payload = AppMessage.PairingIdentityExchangePayload(deviceId: peer.deviceId, kemPublicKeys: [],
            capabilities: [AudioStreamingWire.usbFileSendCapability, ClassicTransferApprovalContract.capability])
        return .init(connection: connection, registry: registry, receiver: receiver, keys: keys,
                     authority: authority, peerPayload: payload)
    }

    private func receivedPairing(_ pair: NativePair, keys: SessionKeys) async throws -> AppMessage.PairingIdentityExchangePayload {
        let frame = try await pair.receiveFrame()
        let ciphertext = TrafficPadding.unwrapIfNeeded(frame, label: "usb-capability-test")
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: keys.sendKey))
        guard case .pairingIdentityExchange(let payload) = try AppMessage.decodeWireMessage(from: plaintext) else {
            throw Failure.malformed
        }
        return payload
    }

    @MainActor
    private final class NativePair {
        let listener: NWListener
        var client: NWConnection?
        private var accepted: NWConnection?
        private var listenerReady = false, clientReady = false, acceptedReady = false
        private var listenerClosed = false, clientClosed = false, acceptedClosed = false
        private var stopping = false
        private var failure: Error?
        private let queue = DispatchQueue(label: "capability-publication-test")
        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
        }
        func start() async throws {
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.listenerReady = true
                    case .cancelled: self?.listenerClosed = true
                    case .failed(let error): self?.failure = error
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] value in
                Task { @MainActor in
                    guard let self, !self.stopping, self.accepted == nil else { value.cancel(); return }
                    self.accepted = value
                    value.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in self?.observe(state, client: false) }
                    }
                    value.start(queue: self.queue)
                }
            }
            listener.start(queue: queue)
            try await wait { self.listenerReady }
            let value = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port), using: .tcp)
            client = value
            value.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.observe(state, client: true) }
            }
            value.start(queue: queue)
            try await wait { self.clientReady && self.acceptedReady }
        }
        private func observe(_ state: NWConnection.State, client: Bool) {
            switch state {
            case .ready: if client { clientReady = true } else { acceptedReady = true }
            case .cancelled: if client { clientClosed = true } else { acceptedClosed = true }
            case .failed(let error): failure = error
            default: break
            }
        }
        private func wait(ignoreFailure: Bool = false, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !predicate() {
                if !ignoreFailure, let failure { throw failure }
                guard ContinuousClock.now < deadline else { throw Failure.timeout }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        func receiveFrame() async throws -> Data {
            let connection = try XCTUnwrap(accepted)
            let watchdog = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(5)); connection.cancel() }
                catch is CancellationError { return }
                catch { XCTFail("Native receive watchdog failed: \(error)"); connection.cancel() }
            }
            defer { watchdog.cancel() }
            let header = try await receive(4, from: connection)
            let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= 1_048_576 else { throw Failure.malformed }
            return try await receive(Int(count), from: connection)
        }
        private func receive(_ count: Int, from connection: NWConnection) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, data.count == count { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: Failure.closed) }
                }
            }
        }
        func close() async throws {
            stopping = true
            listener.cancel(); client?.cancel(); accepted?.cancel()
            try await wait(ignoreFailure: true) {
                self.listenerClosed && (self.client == nil || self.clientClosed) && (self.accepted == nil || self.acceptedClosed)
            }
        }
    }
}
