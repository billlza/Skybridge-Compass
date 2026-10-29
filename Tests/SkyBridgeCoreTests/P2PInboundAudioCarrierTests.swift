import XCTest
import CryptoKit
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport
@testable import SkyBridgeCore

@MainActor
final class P2PInboundAudioCarrierTests: XCTestCase {
    private final class Wire: Sendable {
        struct State: Sendable {
            var frames: [Data] = []
            var cancellations = 0
            var holdWrite = false
            var pending: P2PAudioSendCompletion?
            var authorization: P2PAudioCarrier.SendAuthorization?
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        func send(_ frame: Data, authorization: P2PAudioCarrier.SendAuthorization? = nil, completion: P2PAudioSendCompletion) {
            let held = state.withLock {
                $0.frames.append(frame)
                $0.authorization = authorization
                if $0.holdWrite { $0.pending = completion }
                return $0.holdWrite
            }
            if !held { completion.completeWrite(.success(())) }
        }
        func cancel() { state.withLock { $0.cancellations += 1 } }
    }
    private struct Fixture {
        let carrier: P2PAudioCarrier
        let wire: Wire
        let keys: SessionKeys
        let local: ProtocolIdentityBinding
        let peer: ProtocolIdentityBinding
        let binding: AuthenticatedHandshakePeerBinding
    }
    private func fixture(controlTransport: P2PConnection.ControlTransport = .network,
                         acquireLogicalFile: P2PAudioCarrier.LogicalFileAcquisition? = nil,
                         logicalFileAvailable: @escaping @Sendable () -> Bool = { false },
                         carrier: P2PAudioCarrier? = nil) throws -> Fixture {
        let wire = Wire()
        let local = try ProtocolIdentityBinding(deviceId: "inbound-audio-local-0001", protocolSigningAlgorithm: .ed25519,
                                               protocolPublicKeyBytes: Data(repeating: 0x15, count: 32))
        let peer = try ProtocolIdentityBinding(deviceId: "inbound-audio-remote-0002", protocolSigningAlgorithm: .ed25519,
                                              protocolPublicKeyBytes: Data(repeating: 0x25, count: 32))
        let binding = AuthenticatedHandshakePeerBinding(authority: .init(protocolSigningAlgorithm: peer.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: peer.protocolPublicKeyFingerprint, protocolPublicKey: peer.protocolPublicKeyBytes),
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: peer.deviceId))
        return Fixture(carrier: carrier ?? P2PAudioCarrier(controlTransport: controlTransport, sendFrame: { frame, authorization, completion in
            wire.send(frame, authorization: authorization, completion: completion)
        }, cancelTransport: { wire.cancel() }, acquireLogicalFile: acquireLogicalFile,
            logicalFileAvailable: logicalFileAvailable),
            wire: wire, keys: keys(byte: 1), local: local, peer: peer, binding: binding)
    }
    private func keys(byte: UInt8) -> SessionKeys {
        .init(sendKey: Data(repeating: byte, count: 32), receiveKey: Data(repeating: byte &+ 1, count: 32),
              negotiatedSuite: .x25519Ed25519, role: .responder, transcriptHash: Data(repeating: byte &+ 2, count: 32))
    }
    private var capabilities: Set<String> { [AudioStreamingWire.captureReceiveCapability] }

    private enum AcquisitionProbe: Error { case stopped }

    func testConcreteEpochV2MainAdmitsOneLogicalFileAndRetiresItsOldWriteWitness() async throws {
        let usb = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2))
        addTeardownBlock { try await usb.close() }
        try await usb.start()
        let (main, peerMain) = try await usb.open()
        let control = try USBHostControlFrameTransport(stream: main)
        addTeardownBlock { try await control.closeAndAwait(); try await peerMain.closeAndAwait() }
        let f = try fixture(carrier: P2PAudioCarrier(usbControl: control, fileConnection: usb.a))
        publish(f)
        XCTAssertFalse(f.carrier.canReceiveLogicalFileOverUSB)
        try commit(f, capabilities: [AudioStreamingWire.usbStreamFileSendCapability, ClassicTransferApprovalContract.capability])
        XCTAssertTrue(f.carrier.canReceiveLogicalFileOverUSB)
        let channel = try f.carrier.open()
        let opening = Task { try await usb.b.openStream(priority: .bulk) }
        let bytes = try await channel.acceptOriginalFileStream()
        let peer = try await opening.value
        addTeardownBlock { try await bytes.closeAndAwait(timeout: .seconds(2)); try await peer.closeAndAwait() }
        XCTAssertNil(bytes.networkConnection)
        try await bytes.send(Data([7, 8]), requireEffectAuthorization: {})
        guard case .bytes(let received) = try await peer.readBytes(maximumBytes: 2, timeout: .seconds(2)) else {
            return XCTFail("Logical file stream ended before its payload")
        }
        XCTAssertEqual(received, Data([7, 8]))
        publish(f, keys: keys(byte: 9))
        do { try await bytes.send(Data([9]), requireEffectAuthorization: {}); XCTFail("Retired MAIN sent file bytes") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
        try await bytes.closeAndAwait(timeout: .seconds(2)); try await peer.closeAndAwait()
        try await usb.sibling()
        XCTAssertTrue(control.isReady)
    }

    func testConcreteLogicalFileRequiresMatchingMainCarrierAndEpochV2() async throws {
        for profile in [USBHostMultiplexConnection.LinkProfile.rawYamuxV1, .epochV2] {
            let usb = try USBMultiplexFixture(configuration: .init(linkProfile: profile))
            try await usb.start()
            let (main, peer) = try await usb.open()
            let control = try USBHostControlFrameTransport(stream: main)
            let f = try fixture(carrier: P2PAudioCarrier(usbControl: control,
                fileConnection: profile == .epochV2 ? usb.b : usb.a))
            publish(f); try commit(f, capabilities: [AudioStreamingWire.usbStreamFileSendCapability, ClassicTransferApprovalContract.capability])
            XCTAssertFalse(f.carrier.canReceiveLogicalFileOverUSB)
            let channel = try f.carrier.open()
            XCTAssertFalse(channel.usesLogicalFileStream)
            do { _ = try await channel.acceptOriginalFileStream(); XCTFail("Incompatible carrier admitted a file") }
            catch { XCTAssertEqual(error as? P2PAudioTransportError, .unavailable) }
            channel.close(); try await control.closeAndAwait(); try await peer.closeAndAwait(); try await usb.close()
        }
    }

    func testLogicalFileAcquisitionAndNativeWitnessRetireWithExactCommittedMain() async throws {
        typealias Proof = (P2PAudioCarrier.SendAuthorization, P2PAudioCarrier.SendAuthorization)
        let captured = OSAllocatedUnfairLock<Proof?>(initialState: nil)
        let available = OSAllocatedUnfairLock(initialState: true)
        let f = try fixture(controlTransport: .usb, acquireLogicalFile: { current, native in
            try current(); try native(); captured.withLock { $0 = (current, native) }
            throw AcquisitionProbe.stopped
        }, logicalFileAvailable: { available.withLock { $0 } })
        let caps: Set<String> = [AudioStreamingWire.usbStreamFileSendCapability, ClassicTransferApprovalContract.capability]
        XCTAssertFalse(f.carrier.canReceiveLogicalFileOverUSB)
        publish(f)
        XCTAssertFalse(f.carrier.canReceiveLogicalFileOverUSB)
        try commit(f, capabilities: [AudioStreamingWire.usbStreamFileSendCapability])
        XCTAssertFalse(f.carrier.canReceiveLogicalFileOverUSB)
        try commit(f, capabilities: caps)
        XCTAssertTrue(f.carrier.canReceiveLogicalFileOverUSB)
        available.withLock { $0 = false }
        XCTAssertFalse(f.carrier.canReceiveLogicalFileOverUSB)
        available.withLock { $0 = true }
        let channel = try f.carrier.open()
        XCTAssertTrue(channel.usesLogicalFileStream); XCTAssertFalse(channel.usesUSBFileReturn)
        do { _ = try await channel.acceptOriginalFileStream(); XCTFail("Probe returned a fabricated file owner") }
        catch { XCTAssertTrue(error is AcquisitionProbe) }
        let proof = try XCTUnwrap(captured.withLock { $0 })
        XCTAssertNoThrow(try proof.0()); XCTAssertNoThrow(try proof.1())
        publish(f, keys: keys(byte: 8))
        XCTAssertThrowsError(try proof.0()) { XCTAssertEqual($0 as? P2PAudioTransportError, .staleOwner) }
        XCTAssertThrowsError(try proof.1()) { XCTAssertEqual($0 as? P2PAudioTransportError, .staleOwner) }
        XCTAssertFalse(f.carrier.canReceiveLogicalFileOverUSB)
    }

    func testLogicalFileReceiveFlagRequiresInstalledConsumerAndReadyFileRoute() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let flag = AudioStreamingWire.usbStreamFileReceiveCapability
        XCTAssertFalse(registry.receiveCapabilities(originalFileRouteReady: true, usbLogicalFileReady: true).contains(flag))
        let owner = try registry.install(originalFileSupport: .waveAndFlac) { _ in }
        XCTAssertFalse(registry.receiveCapabilities(originalFileRouteReady: false, usbLogicalFileReady: true).contains(flag))
        XCTAssertFalse(registry.receiveCapabilities(originalFileRouteReady: true).contains(flag))
        XCTAssertTrue(registry.receiveCapabilities(originalFileRouteReady: true, usbLogicalFileReady: true).contains(flag))
        registry.remove(ifOwnedBy: owner)
        XCTAssertFalse(registry.receiveCapabilities(originalFileRouteReady: true, usbLogicalFileReady: true).contains(flag))
    }

    func testDeferredNativeSendRechecksCapturedEffect() async throws {
        let f = try fixture(); publish(f); try commit(f)
        let allowed = OSAllocatedUnfairLock(initialState: true)
        f.wire.state.withLock { $0.holdWrite = true }
        let channel = try f.carrier.open(), message = try offer()
        let send = Task { try await channel.send(message, requireEffectAuthorization: {
            guard allowed.withLock({ $0 }) else { throw AudioMembershipLeaseFailure.accountChanged }
        }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while f.wire.state.withLock({ $0.pending == nil }) {
            guard ContinuousClock.now < deadline else { throw P2PAudioTransportError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
        let (authorization, pending) = f.wire.state.withLock { ($0.authorization, $0.pending) }
        allowed.withLock { $0 = false }
        XCTAssertThrowsError(try XCTUnwrap(authorization)()) {
            XCTAssertEqual($0 as? AudioMembershipLeaseFailure, .accountChanged)
        }
        try XCTUnwrap(pending).completeWrite(.failure(AudioMembershipLeaseFailure.accountChanged))
        do { try await send.value; XCTFail("Deferred write used revoked effect authority") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
    }

    func testDeferredNativeSendCannotUseReplacementEpoch() async throws {
        let f = try fixture(); publish(f); try commit(f)
        f.wire.state.withLock { $0.holdWrite = true }
        let channel = try f.carrier.open(), message = try offer()
        let send = Task { try await channel.send(message) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while f.wire.state.withLock({ $0.pending == nil }) {
            guard ContinuousClock.now < deadline else { throw P2PAudioTransportError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
        let (authorization, pending) = f.wire.state.withLock { ($0.authorization, $0.pending) }
        publish(f, keys: keys(byte: 9))
        XCTAssertThrowsError(try XCTUnwrap(authorization)()) { XCTAssertTrue($0 is CancellationError) }
        try XCTUnwrap(pending).completeWrite(.success(()))
        do { try await send.value; XCTFail("Old completion revived a retired epoch") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
        XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
    }
    private func publish(_ fixture: Fixture, keys: SessionKeys? = nil,
                         history: P2PAudioCarrier.StreamHistory? = nil) {
        XCTAssertTrue(fixture.carrier.publishFinished(keys: keys ?? fixture.keys, peerBinding: fixture.binding,
                                                     localBinding: fixture.local, restoring: history))
    }
    private func commit(_ fixture: Fixture, keys: SessionKeys? = nil, capabilities: Set<String>? = nil) throws {
        let accepted = try fixture.carrier.acceptCommittedPairing(deviceID: fixture.peer.deviceId,
            capabilities: capabilities ?? self.capabilities, keys: keys ?? fixture.keys, authority: fixture.binding.authority)
        XCTAssertTrue(accepted)
    }
    private func offer(_ id: UUID = UUID()) throws -> AudioStreamingMessage {
        .init(streamID: id, body: .captureOffer(try .init(sampleRate: 44_100, channels: 2,
            encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3)))
    }
    private func dispatch(_ message: AudioStreamingMessage, fixture: Fixture, keys: SessionKeys? = nil) throws -> P2PInboundControlPayload {
        try P2PInboundControlPayload.decode(AudioStreamingLANEnvelope.encode(message), keys: keys ?? fixture.keys,
                                           audioCarrier: fixture.carrier)
    }

    private func bluetoothMessages() throws -> (AudioStreamingMessage, AudioStreamingMessage) {
        let id = UUID()
        return (.init(streamID: id, body: .opusOffer(source: .originalFile, format: try .init(channels: 2, bitrate: 192_000))),
                .init(streamID: id, body: .bluetoothRoute(try .init(serviceID: UUID(), publicationID: UUID(), psm: 129))))
    }

    func testBluetoothPreparationBindsRealSealedSendAndIncomingRouteToThisPairing() async throws {
        let f = try fixture(), (offer, route) = try bluetoothMessages()
        publish(f); try commit(f, capabilities: [AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability])
        let channel = try f.carrier.open()
        XCTAssertThrowsError(try channel.prepareBluetoothAttachment())
        try await channel.send(offer)
        let frame = try XCTUnwrap(f.wire.state.withLock { $0.frames.last })
        let ciphertext = TrafficPadding.unwrapIfNeeded(Data(frame.dropFirst(4)))
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: f.keys.sendKey))
        XCTAssertEqual(try AudioStreamingLANEnvelope.decodeIfPresent(plaintext), offer)
        _ = try dispatch(route, fixture: f)
        let attachment = try channel.prepareBluetoothAttachment()
        XCTAssertEqual(attachment.binding.offer, offer); XCTAssertEqual(attachment.binding.route, route)
        XCTAssertThrowsError(try channel.prepareBluetoothAttachment())
        var sink = AudioBluetoothNegotiation(role: .sink, streamID: offer.streamID)
        try sink.receive(offer); try sink.prepareSend(route); try sink.commitSend(route)
        let peerSecret = try AudioBluetoothAttachmentSecret(binding: sink.takeBinding(), sendKey: f.keys.receiveKey,
            receiveKey: f.keys.sendKey, transcriptHash: f.keys.transcriptHash, suite: f.keys.negotiatedSuite.wireId)
        let sourceNonce = Data(repeating: 0x17, count: 32), sinkNonce = Data(repeating: 0x28, count: 32)
        try attachment.verifyPeer(peerSecret.confirmation(role: .sink, sourceNonce: sourceNonce, sinkNonce: sinkNonce),
                                  sourceNonce: sourceNonce, sinkNonce: sinkNonce)
        publish(f, keys: keys(byte: 9))
        XCTAssertThrowsError(try attachment.confirmation(sourceNonce: sourceNonce, sinkNonce: sinkNonce))
        XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
    }

    func testInboundBluetoothRouteDoesNotIssueBeforeActualWriteCompletion() async throws {
        let f = try fixture(), (offer, route) = try bluetoothMessages()
        publish(f); try commit(f)
        guard case .audioOfferNeedsChannel = try dispatch(offer, fixture: f) else { return XCTFail("Opus preparation was not routed") }
        let channel = try XCTUnwrap(f.carrier.openIncomingOffer(offer, keys: f.keys))
        f.wire.state.withLock { $0.holdWrite = true }
        let send = Task { try await channel.send(route) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while f.wire.state.withLock({ $0.pending == nil }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let completion = try XCTUnwrap(f.wire.state.withLock { $0.pending })
        XCTAssertThrowsError(try channel.prepareBluetoothAttachment())
        completion.completeWrite(.success(()))
        try await send.value
        let attachment = try channel.prepareBluetoothAttachment()
        XCTAssertEqual(attachment.binding.role, .sink)
        channel.close()
        XCTAssertThrowsError(try attachment.confirmation(sourceNonce: Data(repeating: 1, count: 32), sinkNonce: Data(repeating: 2, count: 32)))
        XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
    }

    func testBluetoothPreparationRequiresBothCapabilitiesAndRejectsMediaOnMAIN() async throws {
        let f = try fixture(), (offer, _) = try bluetoothMessages()
        publish(f); try commit(f, capabilities: [AudioStreamingWire.opusReceiveCapability])
        var channel = try f.carrier.open()
        do { try await channel.send(offer); XCTFail("missing attachment capability admitted") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .unsupportedPeer) }
        XCTAssertTrue(f.wire.state.withLock { $0.frames.isEmpty })
        try commit(f, capabilities: [AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability])
        channel = try f.carrier.open()
        try await channel.send(offer)
        let count = f.wire.state.withLock { $0.frames.count }
        do {
            try await channel.send(.init(streamID: offer.streamID, body: .opusData(sequence: 0, bytes: Data(repeating: 0, count: 480))))
            XCTFail("Bluetooth media leaked onto MAIN")
        } catch { XCTAssertEqual(error as? AudioBluetoothAttachmentError, .unexpectedMessage) }
        XCTAssertEqual(f.wire.state.withLock { $0.frames.count }, count)
        XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
    }

    func testIssuedBluetoothAttachmentRetiresAtMainStopWhileParentRemainsAvailableForCleanup() async throws {
        for sink in [true, false] {
            for incomingStop in [true, false] {
                let f = try fixture(), (offer, route) = try bluetoothMessages()
                defer { f.carrier.finish() }
                publish(f)
                try commit(f, capabilities: [AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability])
                let channel: P2PAudioChannel
                if sink {
                    guard case .audioOfferNeedsChannel = try dispatch(offer, fixture: f) else { return XCTFail("Missing sink offer") }
                    channel = try XCTUnwrap(f.carrier.openIncomingOffer(offer, keys: f.keys))
                    try await channel.send(route)
                } else {
                    channel = try f.carrier.open()
                    try await channel.send(offer); _ = try dispatch(route, fixture: f)
                }
                let attachment = try channel.prepareBluetoothAttachment()
                XCTAssertGreaterThan(try attachment.handshakeRemainingTime(), .zero)
                let stop = AudioStreamingMessage(streamID: offer.streamID, body: .stop(.userStopped))
                if incomingStop { _ = try dispatch(stop, fixture: f) }
                else { try await channel.send(stop) }
                XCTAssertThrowsError(try attachment.handshakeRemainingTime()) {
                    XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .closed)
                }
                try channel.requireCurrent()
                XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
            }
        }
    }

    func testActualInboundDispatcherRequiresFinishedAndPairingCommit() async throws {
        let fixture = try fixture(), message = try offer()
        XCTAssertThrowsError(try dispatch(message, fixture: fixture))
        publish(fixture)
        XCTAssertThrowsError(try fixture.carrier.open())
        guard case .audioUnavailable = try dispatch(message, fixture: fixture) else { return XCTFail("Uncommitted peer entered audio") }
        try commit(fixture)
        let channel = try fixture.carrier.open()
        XCTAssertEqual(try channel.localIdentityBindingForAccountRequest(), fixture.local)
        XCTAssertEqual(channel.remoteIdentity, try AudioProtocolIdentity(fixture.peer))
        guard case .audio = try dispatch(message, fixture: fixture) else { return XCTFail("SBE1 reached JSON") }
        var reader = channel.messages.makeAsyncIterator()
        let received = try await reader.next()
        XCTAssertEqual(received, message)
        channel.close()
    }

    func testLegacyFinishedWithoutLocalBindingPreservesMAINButCannotOpenAudio() throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.carrier.publishFinished(keys: fixture.keys, peerBinding: fixture.binding, localBinding: nil))
        XCTAssertFalse(try fixture.carrier.acceptCommittedPairing(deviceID: fixture.peer.deviceId,
            capabilities: capabilities, keys: fixture.keys, authority: fixture.binding.authority))
        XCTAssertThrowsError(try fixture.carrier.open())
        guard case .audioUnavailable = try dispatch(offer(), fixture: fixture) else { return XCTFail("Legacy identity enabled audio") }
        XCTAssertEqual(fixture.wire.state.withLock { $0.cancellations }, 0)
    }

    func testNonAudioJSONIsUnchangedAndMalformedSBAUCannotFallBack() throws {
        let fixture = try fixture()
        let message = AppMessage.ping(.init(id: 42))
        let json = try JSONEncoder().encode(message)
        guard case .appMessage(.ping(let payload)) = try P2PInboundControlPayload.decode(json, keys: fixture.keys,
            audioCarrier: fixture.carrier) else { return XCTFail("Non-audio JSON changed") }
        XCTAssertEqual(payload.id, 42)
        publish(fixture); try commit(fixture)
        var malformed = try AudioStreamingLANEnvelope.encode(offer()); malformed[12] = 1
        XCTAssertThrowsError(try P2PInboundControlPayload.decode(malformed, keys: fixture.keys, audioCarrier: fixture.carrier))
    }

    func testStaleEpochAndAuthorityCannotEnterMailbox() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let channel = try fixture.carrier.open()
        XCTAssertThrowsError(try dispatch(offer(), fixture: fixture, keys: keys(byte: 7)))
        let wrongAuthority = AuthenticatedRemoteAuthority(protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: String(repeating: "ab", count: 32))
        XCTAssertThrowsError(try fixture.carrier.acceptCommittedPairing(deviceID: fixture.peer.deviceId,
            capabilities: capabilities, keys: fixture.keys, authority: wrongAuthority))
        try channel.requireCurrent(); channel.close()
    }

    func testClassicFileBindingUsesExactTransferSpellingAndCurrentEpoch() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let channel = try fixture.carrier.open()
        let transferID = "a0102030-b050-4060-8070-c09010111213"
        let material = ClassicTransferKeyMaterial(sessionKeys: fixture.keys, transferId: transferID)
        try channel.requireClassicFileTransfer(transferID: transferID, material: material)
        XCTAssertThrowsError(try channel.requireClassicFileTransfer(transferID: transferID.uppercased(), material: material)) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .fileTransferMismatch)
        }
        let uppercaseMaterial = ClassicTransferKeyMaterial(sessionKeys: fixture.keys, transferId: transferID.uppercased())
        try channel.requireClassicFileTransfer(transferID: transferID.uppercased(), material: uppercaseMaterial)
        let foreign = ClassicTransferKeyMaterial(sessionKeys: keys(byte: 9), transferId: transferID)
        XCTAssertThrowsError(try channel.requireClassicFileTransfer(transferID: transferID, material: foreign)) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .fileTransferMismatch)
        }
        for invalid in ["pending", "00000000-0000-0000-0000-000000000000"] {
            XCTAssertThrowsError(try channel.requireClassicFileTransfer(transferID: invalid, material: material))
        }
        try channel.requireCurrent()
        XCTAssertEqual(fixture.wire.state.withLock { $0.cancellations }, 0)
        channel.close()
    }

    func testClassicFileBindingRejectsRetiredRegistrationAndRollbackOwners() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let channel = try fixture.carrier.open(), transferID = UUID().uuidString
        let lifetime = ClassicTransferSessionRegistry.SessionLifetime()
        let registration = ClassicTransferSessionRegistry.SessionLifetime()
        let material = ClassicTransferKeyMaterial(sessionKeys: fixture.keys, transferId: transferID,
            lifetime: lifetime, registrationLifetime: registration)
        try channel.requireClassicFileTransfer(transferID: transferID, material: material)
        registration.invalidate()
        XCTAssertThrowsError(try channel.requireClassicFileTransfer(transferID: transferID, material: material))
        let currentMaterial = ClassicTransferKeyMaterial(sessionKeys: fixture.keys, transferId: transferID, lifetime: lifetime)
        try channel.requireClassicFileTransfer(transferID: transferID, material: currentMaterial)
        lifetime.invalidate()
        XCTAssertThrowsError(try channel.requireClassicFileTransfer(transferID: transferID, material: currentMaterial))
        let unretiredMaterial = ClassicTransferKeyMaterial(sessionKeys: fixture.keys, transferId: transferID)
        fixture.carrier.invalidate()
        let history = fixture.carrier.streamHistory()
        publish(fixture, keys: keys(byte: 9)); try commit(fixture, keys: keys(byte: 9))
        let replacement = try fixture.carrier.open()
        fixture.carrier.invalidate()
        publish(fixture, history: history); try commit(fixture)
        let restored = try fixture.carrier.open()
        XCTAssertThrowsError(try channel.requireClassicFileTransfer(transferID: transferID, material: unretiredMaterial))
        XCTAssertThrowsError(try replacement.requireClassicFileTransfer(transferID: transferID, material: unretiredMaterial))
        try restored.requireClassicFileTransfer(transferID: transferID, material: unretiredMaterial)
        XCTAssertEqual(fixture.wire.state.withLock { $0.cancellations }, 0)
        restored.close()
    }

    func testIdenticalPairingPreservesChannelAndChangedCapabilitiesRetireIt() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let channel = try fixture.carrier.open()
        try commit(fixture); try channel.requireCurrent()
        fixture.carrier.withdrawChangedPairing(deviceID: fixture.peer.deviceId, capabilities: [])
        XCTAssertThrowsError(try channel.requireCurrent())
        XCTAssertThrowsError(try fixture.carrier.open())
        try commit(fixture, capabilities: [])
        let replacement = try fixture.carrier.open(); try replacement.requireCurrent()
        channel.close(); try replacement.requireCurrent(); replacement.close()
    }

    func testFailedRekeyRollbackKeepsTombstonesWithoutRevivingOldChannel() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let old = try fixture.carrier.open(), oldMessage = try offer()
        _ = try dispatch(oldMessage, fixture: fixture)
        fixture.carrier.invalidate()
        let history = fixture.carrier.streamHistory()
        XCTAssertThrowsError(try old.requireCurrent())
        publish(fixture, keys: keys(byte: 9)); try commit(fixture, keys: keys(byte: 9))
        let failedReplacement = try fixture.carrier.open()
        fixture.carrier.invalidate()
        publish(fixture, history: history)
        XCTAssertThrowsError(try old.requireCurrent()); XCTAssertThrowsError(try failedReplacement.requireCurrent())
        // A retired old frame is harmless even before pairing is recommitted after rollback.
        guard case .audio = try dispatch(oldMessage, fixture: fixture) else { return XCTFail("Lost old tombstone") }
        XCTAssertThrowsError(try fixture.carrier.open())
        try commit(fixture)
        let restored = try fixture.carrier.open()
        _ = try dispatch(oldMessage, fixture: fixture)
        let fresh = try offer(); _ = try dispatch(fresh, fixture: fixture)
        fixture.carrier.invalidate()
        let retryHistory = fixture.carrier.streamHistory()
        publish(fixture, history: retryHistory); try commit(fixture)
        let retried = try fixture.carrier.open()
        _ = try dispatch(oldMessage, fixture: fixture); _ = try dispatch(fresh, fixture: fixture)
        // A second rekey after a failed driver was retired still retains both old stream IDs.
        _ = try dispatch(offer(), fixture: fixture)
        XCTAssertThrowsError(try restored.requireCurrent()); retried.close()
    }

    func testTombstonesAreBoundedAndOnlyNewFinishedEpochResetsThem() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        for _ in 0..<64 {
            let channel = try fixture.carrier.open()
            _ = try dispatch(offer(), fixture: fixture); channel.close()
        }
        XCTAssertThrowsError(try fixture.carrier.open()) { XCTAssertEqual($0 as? P2PAudioTransportError, .epochCapacity) }
        publish(fixture, keys: keys(byte: 8)); try commit(fixture, keys: keys(byte: 8))
        let channel = try fixture.carrier.open(); channel.close()
    }

    func testReceiverRemovalRetiresDeliveredChannelBeforeConnectionInventoryPublication() throws {
        let f = try fixture(); publish(f); try commit(f)
        let registry = P2PAudioIncomingChannelRegistry()
        let received = OSAllocatedUnfairLock<P2PAudioChannel?>(initialState: nil)
        let token = try registry.install { channel in received.withLock { $0 = channel } }
        XCTAssertTrue(try registry.deliver(f.carrier))
        let channel = try XCTUnwrap(received.withLock { $0 })
        // Outbound authentication can deliver an offer before its caller has
        // published the connection in the discovery inventory.
        registry.remove(ifOwnedBy: token)
        XCTAssertThrowsError(try channel.requireCurrent())
        XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
    }

    func testReceiverRemovalDoesNotCloseLaterUnrelatedChannelOnSameConnection() throws {
        let f = try fixture(); publish(f); try commit(f)
        let registry = P2PAudioIncomingChannelRegistry()
        let received = OSAllocatedUnfairLock<P2PAudioChannel?>(initialState: nil)
        let token = try registry.install { channel in received.withLock { $0 = channel } }
        XCTAssertTrue(try registry.deliver(f.carrier))
        let finished = try XCTUnwrap(received.withLock { $0 })
        finished.close()
        let later = try f.carrier.open()
        registry.remove(ifOwnedBy: token)
        try later.requireCurrent()
        later.close()
        XCTAssertEqual(f.wire.state.withLock { $0.cancellations }, 0)
    }

    func testReceiverBoundsDeliveredChannelsAndDoesNotRetainReleasedConsumers() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let received = OSAllocatedUnfairLock<[P2PAudioChannel]>(initialState: [])
        let token = try registry.install { channel in received.withLock { $0.append(channel) } }
        let fixtures = try (0...P2PAudioIncomingChannelRegistry.maximumDeliveredChannels).map { _ in try fixture() }
        for item in fixtures { publish(item); try commit(item) }
        for item in fixtures.dropLast() { XCTAssertTrue(try registry.deliver(item.carrier)) }
        let next = try XCTUnwrap(fixtures.last)
        XCTAssertThrowsError(try registry.deliver(next.carrier)) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .queueOverflow)
        }
        XCTAssertEqual(received.withLock { $0.count }, P2PAudioIncomingChannelRegistry.maximumDeliveredChannels)
        received.withLock { $0.removeFirst().close() }
        XCTAssertTrue(try registry.deliver(next.carrier))
        XCTAssertEqual(received.withLock { $0.count }, P2PAudioIncomingChannelRegistry.maximumDeliveredChannels)
        registry.remove(ifOwnedBy: token)
        for channel in received.withLock({ $0 }) { XCTAssertThrowsError(try channel.requireCurrent()) }
        for item in fixtures { XCTAssertEqual(item.wire.state.withLock { $0.cancellations }, 0) }
    }

    func testHandlerOwnerRemovalRetiresAudioWithoutCancellingMAIN() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let registry = P2PAudioIncomingChannelRegistry()
        let received = OSAllocatedUnfairLock<P2PAudioChannel?>(initialState: nil)
        let token = try registry.install { channel in received.withLock { $0 = channel } }
        XCTAssertThrowsError(try registry.install { _ in })
        XCTAssertTrue(try registry.deliver(fixture.carrier))
        let old = try XCTUnwrap(received.withLock { $0 })
        let message = try offer(); _ = try dispatch(message, fixture: fixture)
        registry.remove(ifOwnedBy: UUID()); try old.requireCurrent()
        registry.remove(ifOwnedBy: token)
        XCTAssertThrowsError(try old.requireCurrent())
        guard case .audio = try dispatch(message, fixture: fixture) else { return XCTFail("Retired stream reached JSON") }
        let nextOffer = try offer()
        guard case .audioOfferNeedsChannel = try dispatch(nextOffer, fixture: fixture) else { return XCTFail("Missing handler accepted offer") }
        XCTAssertFalse(try registry.deliverIncomingOffer(nextOffer, keys: fixture.keys, carrier: fixture.carrier))
        guard case .audioOfferNeedsChannel = try dispatch(nextOffer, fixture: fixture) else { return XCTFail("No-handler delivery created a mailbox") }
        XCTAssertEqual(fixture.wire.state.withLock { $0.cancellations }, 0)
        let replacementToken = try registry.install { channel in received.withLock { $0 = channel } }
        XCTAssertTrue(try registry.deliver(fixture.carrier))
        let current = try XCTUnwrap(received.withLock { $0 })
        registry.remove(ifOwnedBy: token); try current.requireCurrent()
        registry.remove(ifOwnedBy: replacementToken)
    }

    func testCaptureOnlyAdvertisementRequiresExactReadyInstallation() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
        let passive = try registry.install { _ in }
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
        registry.remove(ifOwnedBy: passive)
        let ready = try registry.install(advertiseCapture: true) { _ in }
        XCTAssertEqual(registry.advertisedReceiveCapabilities, [AudioStreamingWire.captureReceiveCapability])
        registry.remove(ifOwnedBy: passive)
        XCTAssertEqual(registry.advertisedReceiveCapabilities, [AudioStreamingWire.captureReceiveCapability])
        registry.remove(ifOwnedBy: ready)
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
    }

    func testOriginalFileAdvertisementIsExplicitAndRetiresWithExactConsumer() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let old = try registry.install(originalFileSupport: .wave) { _ in }
        XCTAssertEqual(registry.advertisedReceiveCapabilities, [AudioStreamingWire.fileReceiveCapability])
        registry.remove(ifOwnedBy: old)
        let current = try registry.install(advertiseCapture: true, originalFileSupport: .wave) { _ in }
        XCTAssertEqual(Set(registry.advertisedReceiveCapabilities),
                       Set([AudioStreamingWire.captureReceiveCapability, AudioStreamingWire.fileReceiveCapability]))
        registry.remove(ifOwnedBy: old)
        XCTAssertEqual(registry.advertisedReceiveCapabilities.count, 2)
        registry.remove(ifOwnedBy: current)
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
    }

    func testBluetoothAdvertisementAndIncomingOfferRequireInstalledConsumer() throws {
        let registry = P2PAudioIncomingChannelRegistry(), f = try fixture(), (offer, _) = try bluetoothMessages()
        publish(f); try commit(f)
        let delivered = OSAllocatedUnfairLock<[P2PAudioChannel]>(initialState: [])
        let passive = try registry.install { channel in delivered.withLock { $0.append(channel) } }
        XCTAssertFalse(try registry.deliverIncomingOffer(offer, keys: f.keys, carrier: f.carrier))
        XCTAssertTrue(delivered.withLock { $0.isEmpty })
        XCTAssertFalse(registry.advertisedReceiveCapabilities.contains(AudioStreamingWire.opusReceiveCapability))
        registry.remove(ifOwnedBy: passive)
        let active = try registry.install(advertiseBluetoothOpus: true) { channel in delivered.withLock { $0.append(channel) } }
        XCTAssertEqual(Set(registry.advertisedReceiveCapabilities),
            Set([AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability,
                 AudioStreamingWire.bufferedOpusFileReceiveCapability]))
        XCTAssertTrue(try registry.deliverIncomingOffer(offer, keys: f.keys, carrier: f.carrier))
        let channel = try XCTUnwrap(delivered.withLock { $0.first })
        registry.remove(ifOwnedBy: passive)
        try channel.requireCurrent()
        registry.remove(ifOwnedBy: active)
        XCTAssertThrowsError(try channel.requireCurrent())
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
    }

    func testFLACAdvertisementRequiresItsConcreteFileConsumer() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let wave = try registry.install(originalFileSupport: .wave) { _ in }
        XCTAssertFalse(registry.advertisedReceiveCapabilities.contains(AudioStreamingWire.flacFileReceiveCapability))
        registry.remove(ifOwnedBy: wave)
        let flac = try registry.install(originalFileSupport: .waveAndFlac) { _ in }
        XCTAssertEqual(Set(registry.advertisedReceiveCapabilities),
                       Set([AudioStreamingWire.fileReceiveCapability, AudioStreamingWire.flacFileReceiveCapability]))
        registry.remove(ifOwnedBy: wave)
        XCTAssertTrue(registry.advertisedReceiveCapabilities.contains(AudioStreamingWire.flacFileReceiveCapability))
        registry.remove(ifOwnedBy: flac)
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
    }

    func testTwoSequentialInboundOffersReachSeparateOwnedChannels() async throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let registry = P2PAudioIncomingChannelRegistry()
        let received = OSAllocatedUnfairLock<[P2PAudioChannel]>(initialState: [])
        let token = try registry.install { channel in received.withLock { $0.append(channel) } }
        for index in 0..<2 {
            let message = try offer()
            guard case .audioOfferNeedsChannel(let firstOffer) = try dispatch(message, fixture: fixture) else {
                return XCTFail("New stream did not request one channel")
            }
            XCTAssertTrue(try registry.deliverIncomingOffer(firstOffer, keys: fixture.keys, carrier: fixture.carrier))
            XCTAssertEqual(received.withLock { $0.count }, index + 1)
            let channel = try XCTUnwrap(received.withLock { $0.last })
            var iterator = channel.messages.makeAsyncIterator()
            let actual = try await iterator.next()
            XCTAssertEqual(actual, message)
            channel.close(); XCTAssertThrowsError(try channel.requireCurrent())
        }
        registry.remove(ifOwnedBy: token)
        XCTAssertEqual(fixture.wire.state.withLock { $0.cancellations }, 0)
    }

    func testImmediateIncomingCallbackCloseRetiresFirstOfferBeforeLatePCM() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let registry = P2PAudioIncomingChannelRegistry()
        let callbacks = OSAllocatedUnfairLock(initialState: 0)
        let token = try registry.install { channel in
            callbacks.withLock { $0 += 1 }
            channel.close()
        }
        let message = try offer()
        guard case .audioOfferNeedsChannel(let firstOffer) = try dispatch(message, fixture: fixture) else {
            return XCTFail("Offer did not reach incoming admission")
        }
        XCTAssertTrue(try registry.deliverIncomingOffer(firstOffer, keys: fixture.keys, carrier: fixture.carrier))
        let latePCM = AudioStreamingMessage(streamID: message.streamID, body: .pcmData(byteOffset: 0, bytes: Data(repeating: 7, count: 12)))
        guard case .audio = try dispatch(latePCM, fixture: fixture) else { return XCTFail("Immediate close lost the stream tombstone") }
        guard case .audio = try dispatch(message, fixture: fixture) else { return XCTFail("Retired offer reopened a prompt") }
        XCTAssertEqual(callbacks.withLock { $0 }, 1)
        XCTAssertTrue(try registry.deliverIncomingOffer(firstOffer, keys: fixture.keys, carrier: fixture.carrier))
        XCTAssertEqual(callbacks.withLock { $0 }, 1)
        registry.remove(ifOwnedBy: token)
        XCTAssertEqual(fixture.wire.state.withLock { $0.cancellations }, 0)
    }

    func testHandlerInstallRaceDeliversOfferIntoExistingMailboxWithoutSecondConsumer() async throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let registry = P2PAudioIncomingChannelRegistry()
        let received = OSAllocatedUnfairLock<[P2PAudioChannel]>(initialState: [])
        let message = try offer()
        guard case .audioOfferNeedsChannel(let firstOffer) = try dispatch(message, fixture: fixture) else {
            return XCTFail("Expected mailbox-free admission")
        }
        let token = try registry.install { channel in received.withLock { $0.append(channel) } }
        XCTAssertTrue(try registry.deliver(fixture.carrier)) // Installed between dispatch and delivery.
        XCTAssertTrue(try registry.deliverIncomingOffer(firstOffer, keys: fixture.keys, carrier: fixture.carrier))
        XCTAssertEqual(received.withLock { $0.count }, 1)
        let channel = try XCTUnwrap(received.withLock { $0.first })
        var iterator = channel.messages.makeAsyncIterator()
        let actual = try await iterator.next()
        XCTAssertEqual(actual, message)
        registry.remove(ifOwnedBy: token)
    }

    func testSendUsesActualEpochEncryptionAndExistingEnvelope() async throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let channel = try fixture.carrier.open(), message = try offer()
        try await channel.send(message)
        let frame = try XCTUnwrap(fixture.wire.state.withLock { $0.frames.first })
        let ciphertext = TrafficPadding.unwrapIfNeeded(Data(frame.dropFirst(4)), label: "test")
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: fixture.keys.sendKey))
        XCTAssertEqual(try AudioStreamingLANEnvelope.decodeIfPresent(plaintext), message)
        XCTAssertEqual(fixture.wire.state.withLock { $0.frames.count }, 1)
        channel.close()
    }

    func testEffectRevokedWhileWaitingForOwnerLockCannotSubmitAnotherFrame() async throws {
        let template = try fixture()
        let entered = expectation(description: "first native submission holds owner gate")
        let release = DispatchSemaphore(value: 0)
        let first = OSAllocatedUnfairLock(initialState: true)
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let carrier = P2PAudioCarrier(controlTransport: .network, sendFrame: { frame, _, completion in
            if first.withLock({ value in let previous = value; value = false; return previous }) {
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    completion.completeWrite(.failure(P2PAudioTransportError.timedOut)); return
                }
            }
            template.wire.send(frame, completion: completion)
        }, cancelTransport: { template.wire.cancel() })
        let fixture = Fixture(carrier: carrier, wire: template.wire, keys: template.keys,
                              local: template.local, peer: template.peer, binding: template.binding)
        publish(fixture); try commit(fixture)
        let channel = try carrier.open(), message = try offer()
        let initial = Task.detached { try await channel.send(message) }
        await fulfillment(of: [entered], timeout: 2)
        let secondStarted = expectation(description: "second send starts behind owner gate")
        let queued = Task.detached {
            secondStarted.fulfill()
            try await channel.send(message, requireEffectAuthorization: {
                guard allowed.withLock({ $0 }) else { throw AudioMembershipLeaseFailure.accountChanged }
            })
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        allowed.withLock { $0 = false }
        release.signal()
        // The second failure retires the channel, so even a first send whose bytes
        // already reached the stub can correctly fail its post-write owner check.
        do { try await initial.value }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
        do { try await queued.value; XCTFail("Revoked queued write submitted") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertEqual(template.wire.state.withLock { $0.frames.count }, 1)
        XCTAssertEqual(template.wire.state.withLock { $0.cancellations }, 0)
        let replacement = try carrier.open(); try replacement.requireCurrent(); replacement.close()
    }

    func testPendingSendRemainsBoundedAndChannelCloseKeepsNativeWriteOwnership() async throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        fixture.wire.state.withLock { $0.holdWrite = true }
        let channel = try fixture.carrier.open(), message = try offer()
        let first = Task { try await channel.send(message) }
        for _ in 0..<200 {
            if fixture.wire.state.withLock({ $0.pending != nil }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = try XCTUnwrap(fixture.wire.state.withLock { $0.pending })
        do { try await channel.send(message); XCTFail("Second write escaped the bound") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .sendInProgress) }
        fixture.carrier.closeCurrentChannel()
        do { try await first.value; XCTFail("Closed channel reported send success") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .closed) }
        pending.completeWrite(.success(()))
        XCTAssertEqual(fixture.wire.state.withLock { $0.frames.count }, 1)
        XCTAssertEqual(fixture.wire.state.withLock { $0.cancellations }, 0)
    }

    func testTerminalRevocationCannotBeReopenedByLateFinishedOrPairing() throws {
        let fixture = try fixture(); publish(fixture); try commit(fixture)
        let channel = try fixture.carrier.open()
        fixture.carrier.finish()
        XCTAssertThrowsError(try channel.requireCurrent())
        XCTAssertFalse(fixture.carrier.publishFinished(keys: fixture.keys, peerBinding: fixture.binding, localBinding: fixture.local))
        XCTAssertThrowsError(try commit(fixture)); XCTAssertThrowsError(try fixture.carrier.open())
    }
}
