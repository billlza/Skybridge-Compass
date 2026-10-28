import XCTest
import os
import Network
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class P2PAudioChannelTests: XCTestCase {
    private struct OutboundFixture {
        let connection: P2PConnection
        let keys: SessionKeys
        let generation: UInt64
        let local: ProtocolIdentityBinding
        let peer: ProtocolIdentityBinding
        let binding: AuthenticatedHandshakePeerBinding
    }

    private func outboundFixture(_ registry: P2PAudioIncomingChannelRegistry?,
                                 transport: P2PConnection.ControlTransport = .network,
                                 commitPairing: Bool = true, usbDeviceID: String? = nil,
                                 peerCapabilities: Set<String> = []) throws -> OutboundFixture {
        let local = try ProtocolIdentityBinding(deviceId: "outbound-audio-local", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x21, count: 32))
        let peer = try ProtocolIdentityBinding(deviceId: "outbound-audio-peer", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x31, count: 32))
        let binding = AuthenticatedHandshakePeerBinding(authority: .init(protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: peer.protocolPublicKeyFingerprint, protocolPublicKey: peer.protocolPublicKeyBytes),
            authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(from: peer.deviceId))
        let keys = SessionKeys(sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32),
            negotiatedSuite: .x25519Ed25519, role: .initiator, transcriptHash: Data(repeating: 3, count: 32))
        let device = P2PDevice(id: peer.deviceId, name: "Outbound audio fixture", type: .iOS,
            address: "127.0.0.1", port: 9, osVersion: "test", capabilities: [], publicKey: Data(), lastSeen: Date())
        // The socket is deliberately never started. The regression uses the
        // actual outbound dispatcher with explicit controlled epoch inputs.
        let connection = P2PConnection(device: device, connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            controlTransport: transport, incomingAudioRegistry: registry, usbDeviceID: usbDeviceID)
        let generation = try connection.testingInstallAudioEpoch(keys: keys, peerBinding: binding,
            local: local, peer: peer, commitPairing: commitPairing, peerCapabilities: peerCapabilities)
        return .init(connection: connection, keys: keys, generation: generation, local: local, peer: peer, binding: binding)
    }

    func testOutboundAdvertisementRequiresInstalledConsumerAndUsableFileRoute() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let network = try outboundFixture(registry), usb = try outboundFixture(registry, transport: .usb)
        XCTAssertTrue(network.connection.currentAudioReceiveCapabilities().isEmpty)
        let token = try registry.install(advertiseCapture: true, originalFileSupport: .waveAndFlac) { _ in }
        XCTAssertEqual(Set(network.connection.currentAudioReceiveCapabilities()),
            Set([AudioStreamingWire.captureReceiveCapability, AudioStreamingWire.fileReceiveCapability,
                 AudioStreamingWire.flacFileReceiveCapability]))
        XCTAssertEqual(usb.connection.currentAudioReceiveCapabilities(), [AudioStreamingWire.captureReceiveCapability])
        let standalone = try outboundFixture(nil)
        XCTAssertTrue(standalone.connection.currentAudioReceiveCapabilities().isEmpty)
        registry.remove(ifOwnedBy: token)
        XCTAssertTrue(network.connection.currentAudioReceiveCapabilities().isEmpty)
        XCTAssertTrue(usb.connection.currentAudioReceiveCapabilities().isEmpty)
    }

    func testAuthenticatedAudioChannelKeepsItsExactControlCarrier() async throws {
        for transport in [P2PConnection.ControlTransport.network, .usb] {
            let registry = P2PAudioIncomingChannelRegistry()
            // Both fixtures use NWConnection. A usbmux connection must not be
            // classified as network merely because of its socket representation.
            let fixture = try outboundFixture(registry, transport: transport)
            let received = OSAllocatedUnfairLock<[P2PAudioChannel]>(initialState: [])
            let token = try registry.install(advertiseCapture: true) { channel in
                received.withLock { $0.append(channel) }
            }
            let message = try offer()
            let handled = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(message),
                keys: fixture.keys, connectionGeneration: fixture.generation)
            XCTAssertTrue(handled)
            let channel = try XCTUnwrap(received.withLock { $0.first })
            XCTAssertEqual(channel.controlTransport, transport)
            registry.remove(ifOwnedBy: token)
            XCTAssertThrowsError(try channel.requireCurrent())
            XCTAssertEqual(channel.controlTransport, transport, "A retired operation retains its own carrier description")
        }
    }

    func testALACCapabilityRequiresItsConsumerAndTheActualFileRoute() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
        let legacy = try registry.install(originalFileSupport: .waveAndFlac) { _ in }
        XCTAssertFalse(registry.advertisedReceiveCapabilities.contains(AudioStreamingWire.alacFileReceiveCapability))
        registry.remove(ifOwnedBy: legacy)
        let current = try registry.install(originalFileSupport: .waveFlacAndAlac) { _ in }
        XCTAssertEqual(Set(registry.receiveCapabilities(originalFileRouteReady: true)),
                       [AudioStreamingWire.fileReceiveCapability, AudioStreamingWire.flacFileReceiveCapability,
                        AudioStreamingWire.alacFileReceiveCapability])
        XCTAssertTrue(registry.receiveCapabilities(originalFileRouteReady: false).isEmpty)
        XCTAssertTrue(registry.receiveCapabilities(originalFileRouteReady: false, usbLogicalFileReady: true).isEmpty)
        XCTAssertEqual(Set(registry.receiveCapabilities(originalFileRouteReady: true, usbLogicalFileReady: true)),
                       [AudioStreamingWire.fileReceiveCapability, AudioStreamingWire.flacFileReceiveCapability,
                        AudioStreamingWire.alacFileReceiveCapability, AudioStreamingWire.usbStreamFileReceiveCapability])
        registry.remove(ifOwnedBy: current)
        XCTAssertTrue(registry.advertisedReceiveCapabilities.isEmpty)
    }

    func testFileOutputProgressAdvertisementRequiresInstalledReporterAndFileRoute() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let role = AudioStreamingWire.fileOutputProgressReportCapability
        let legacy = try registry.install(originalFileSupport: .waveFlacAndAlac) { _ in }
        XCTAssertFalse(registry.advertisedReceiveCapabilities.contains(role))
        registry.remove(ifOwnedBy: legacy)
        let noFileConsumer = try registry.install(advertiseFileOutputProgress: true) { _ in }
        XCTAssertFalse(registry.advertisedReceiveCapabilities.contains(role))
        registry.remove(ifOwnedBy: noFileConsumer)
        let current = try registry.install(originalFileSupport: .waveFlacAndAlac,
            advertiseFileOutputProgress: true) { _ in }
        XCTAssertTrue(registry.receiveCapabilities(originalFileRouteReady: true).contains(role))
        XCTAssertFalse(registry.receiveCapabilities(originalFileRouteReady: false).contains(role))
        registry.remove(ifOwnedBy: current)
        XCTAssertFalse(registry.advertisedReceiveCapabilities.contains(role))
    }

    func testUSBOriginalFileAdvertisementRequiresExactDeviceAndBothPeerCapabilities() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let token = try registry.install(originalFileSupport: .waveAndFlac) { _ in }
        defer { registry.remove(ifOwnedBy: token) }
        let udid = "00000000-0000000000000000"
        let incomplete: [Set<String>] = [[], [AudioStreamingWire.usbFileSendCapability], ["classic_approval_v1"]]
        for capabilities in incomplete {
            let fixture = try outboundFixture(registry, transport: .usb, usbDeviceID: udid, peerCapabilities: capabilities)
            XCTAssertTrue(fixture.connection.currentAudioReceiveCapabilities().isEmpty)
        }
        let both: Set<String> = [AudioStreamingWire.usbFileSendCapability, "classic_approval_v1"]
        let missingDevice = try outboundFixture(registry, transport: .usb, peerCapabilities: both)
        XCTAssertTrue(missingDevice.connection.currentAudioReceiveCapabilities().isEmpty)
        let available = try outboundFixture(registry, transport: .usb, usbDeviceID: udid, peerCapabilities: both)
        XCTAssertEqual(Set(available.connection.currentAudioReceiveCapabilities()),
            [AudioStreamingWire.fileReceiveCapability, AudioStreamingWire.flacFileReceiveCapability,
             AudioStreamingWire.usbFileReceiveCapability])
        let network = try outboundFixture(registry, usbDeviceID: udid, peerCapabilities: both)
        XCTAssertFalse(network.connection.currentAudioReceiveCapabilities().contains(AudioStreamingWire.usbFileReceiveCapability))
    }

    func testCommittedUSBPeerWithoutFileReturnCanStillAdvertiseCaptureAndBluetooth() throws {
        let registry = P2PAudioIncomingChannelRegistry()
        let token = try registry.install(advertiseCapture: true, originalFileSupport: .waveAndFlac,
                                         advertiseBluetoothOpus: true) { _ in }
        defer { registry.remove(ifOwnedBy: token) }
        let fixture = try outboundFixture(registry, transport: .usb, peerCapabilities: [])
        XCTAssertEqual(Set(fixture.connection.currentAudioReceiveCapabilities()),
                       [AudioStreamingWire.captureReceiveCapability, AudioStreamingWire.opusReceiveCapability,
                        AudioStreamingWire.bluetoothAttachmentCapability, AudioStreamingWire.bufferedOpusFileReceiveCapability])
        let network = try outboundFixture(registry, commitPairing: false)
        XCTAssertEqual(Set(network.connection.currentAudioReceiveCapabilities()),
                       Set(registry.advertisedReceiveCapabilities))
    }

    func testOutboundDispatcherDeliversSequentialOffersAndReceiverRetirementClosesItsChannel() async throws {
        let registry = P2PAudioIncomingChannelRegistry(), fixture = try outboundFixture(registry)
        let received = OSAllocatedUnfairLock<[P2PAudioChannel]>(initialState: [])
        let token = try registry.install(advertiseCapture: true) { channel in received.withLock { $0.append(channel) } }
        for index in 0..<2 {
            let message = try offer()
            let handled = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(message),
                keys: fixture.keys, connectionGeneration: fixture.generation)
            XCTAssertTrue(handled)
            XCTAssertEqual(received.withLock { $0.count }, index + 1)
            let channel = try XCTUnwrap(received.withLock { $0.last })
            var iterator = channel.messages.makeAsyncIterator()
            let delivered = try await iterator.next()
            XCTAssertEqual(delivered, message)
            if index == 0 { channel.close() }
        }
        let current = try XCTUnwrap(received.withLock { $0.last })
        registry.remove(ifOwnedBy: UUID())
        try current.requireCurrent()
        registry.remove(ifOwnedBy: token)
        XCTAssertThrowsError(try current.requireCurrent())
        let handled = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(offer()),
            keys: fixture.keys, connectionGeneration: fixture.generation)
        XCTAssertTrue(handled, "A refused audio offer must not fall through to JSON")
        XCTAssertEqual(received.withLock { $0.count }, 2)
    }

    func testOutboundUSBRefusesFileOfferUntilReverseRouteExistsButStillDeliversPCM() async throws {
        let registry = P2PAudioIncomingChannelRegistry(), fixture = try outboundFixture(registry, transport: .usb)
        let received = OSAllocatedUnfairLock<[P2PAudioChannel]>(initialState: [])
        let token = try registry.install(advertiseCapture: true, originalFileSupport: .waveAndFlac) {
            channel in received.withLock { $0.append(channel) }
        }
        let file = AudioStreamingMessage(streamID: UUID(), body: .fileOffer(transferID: UUID(), length: 128,
            sha256: Data(repeating: 0x45, count: 32)))
        let refused = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(file),
            keys: fixture.keys, connectionGeneration: fixture.generation)
        XCTAssertTrue(refused); XCTAssertTrue(received.withLock { $0.isEmpty })
        let capture = try offer()
        let handled = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(capture),
            keys: fixture.keys, connectionGeneration: fixture.generation)
        XCTAssertTrue(handled); XCTAssertEqual(received.withLock { $0.count }, 1)
        registry.remove(ifOwnedBy: token)
    }

    func testOutboundDispatcherRejectsUncommittedPeerOldEpochAndOldGeneration() async throws {
        let registry = P2PAudioIncomingChannelRegistry(), fixture = try outboundFixture(registry, commitPairing: false)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let token = try registry.install(advertiseCapture: true) { channel in
            count.withLock { $0 += 1 }; channel.close()
        }
        let refused = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(offer()),
            keys: fixture.keys, connectionGeneration: fixture.generation)
        XCTAssertTrue(refused); XCTAssertEqual(count.withLock { $0 }, 0)
        let replacement = SessionKeys(sendKey: Data(repeating: 4, count: 32), receiveKey: Data(repeating: 5, count: 32),
            negotiatedSuite: .x25519Ed25519, role: .initiator, transcriptHash: Data(repeating: 6, count: 32))
        _ = try fixture.connection.testingInstallAudioEpoch(keys: replacement, peerBinding: fixture.binding,
            local: fixture.local, peer: fixture.peer)
        for (keys, generation) in [(fixture.keys, fixture.generation), (replacement, UInt64.max)] {
            do {
                _ = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(offer()),
                    keys: keys, connectionGeneration: generation)
                XCTFail("Stale input reached the current outbound receiver")
            } catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
        }
        XCTAssertEqual(count.withLock { $0 }, 0)
        let handled = try await fixture.connection.routeAuthenticatedAudio(AudioStreamingLANEnvelope.encode(offer()),
            keys: replacement, connectionGeneration: fixture.generation)
        XCTAssertTrue(handled); XCTAssertEqual(count.withLock { $0 }, 1)
        registry.remove(ifOwnedBy: token)
    }

    private func offer(_ id: UUID = UUID()) throws -> AudioStreamingMessage {
        .init(streamID: id, body: .captureOffer(try .init(
            sampleRate: 44_100, channels: 2, encoding: .signed24,
            declaredValidBits: 24, waveChannelMask: 3
        )))
    }

    func testAccountCallerBindingUsesCapturedKeyAndChecksCurrentChannel() throws {
        let local = try ProtocolIdentityBinding(deviceId: "audio-local-device-0001", protocolSigningAlgorithm: .mlDSA87,
                                               protocolPublicKeyBytes: Data(repeating: 0x47, count: 2_592))
        let peer = try AudioProtocolIdentity(deviceID: "audio-remote-device-0002", algorithm: .ed25519,
                                            fingerprint: String(repeating: "ab", count: 32))
        let mailbox = P2PAudioMailbox()
        let current = OSAllocatedUnfairLock(initialState: true)
        let channel = P2PAudioChannel(mailbox: mailbox, remoteIdentity: peer, localIdentityBinding: local, controlTransport: .network,
            validateOwner: { if !current.withLock({ $0 }) { throw P2PAudioTransportError.staleOwner } },
            send: { _, effect in try effect?() }, close: { mailbox.finish(.closed) })
        XCTAssertEqual(try channel.localIdentityBindingForAccountRequest(), local)
        try channel.requireCurrent()
        current.withLock { $0 = false }
        XCTAssertThrowsError(try channel.localIdentityBindingForAccountRequest()) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .staleOwner)
        }
        current.withLock { $0 = true }
        channel.close()
        XCTAssertThrowsError(try channel.requireCurrent())
        XCTAssertThrowsError(try channel.localIdentityBindingForAccountRequest())
    }

    func testLocalIdentitySnapshotRollsBackExactlyAndClearRemovesIt() async throws {
        #if DEBUG || SKYBRIDGE_TESTING
        let previous = try ProtocolIdentityBinding(deviceId: "audio-original-local-0001", protocolSigningAlgorithm: .ed25519,
                                                  protocolPublicKeyBytes: Data(repeating: 0x12, count: 32))
        let replacement = try ProtocolIdentityBinding(deviceId: previous.deviceId, protocolSigningAlgorithm: .mlDSA87,
                                                     protocolPublicKeyBytes: Data(repeating: 0x34, count: 2_592))
        let keys = SessionKeys(sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32),
            negotiatedSuite: .x25519Ed25519, role: .initiator, transcriptHash: Data(repeating: 3, count: 32))
        let peer = AuthenticatedHandshakePeerBinding(authority: .init(protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: String(repeating: "ab", count: 32)), authenticatedRemoteSOAPeerId: nil)
        let device = P2PDevice(id: "audio-rollback-" + UUID().uuidString, name: "Audio rollback test", type: .macOS,
            address: "127.0.0.1", port: 9, osVersion: "test", capabilities: [], publicKey: Data(), lastSeen: Date())
        let connection = P2PConnection(device: device, connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        let result = try await connection.testingLocalIdentityRollback(keys: keys, peerBinding: peer,
                                                                      previous: previous, replacement: replacement)
        XCTAssertEqual(result.restored, previous); XCTAssertNil(result.cleared)
        // A legacy previous epoch must restore nil, never retain the replacement's identity.
        let legacy = try await connection.testingLocalIdentityRollback(keys: keys, peerBinding: peer,
                                                                      previous: nil, replacement: replacement)
        XCTAssertNil(legacy.restored); XCTAssertNil(legacy.cleared)
        #endif
    }

    func testLANCarrierUsesKindTwoAndPreservesTheCompleteSBAUPayload() throws {
        let message = try offer()
        let wire = try AudioStreamingLANEnvelope.encode(message)
        XCTAssertEqual(Array(wire.prefix(13)), [0x53, 0x42, 0x45, 0x31, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Data(wire.dropFirst(13)), try AudioStreamingWire.encode(message))
        XCTAssertEqual(try AudioStreamingLANEnvelope.decodeIfPresent(wire), message)
        var slice = Data([0xff]); slice.append(wire)
        XCTAssertEqual(try AudioStreamingLANEnvelope.decodeIfPresent(slice.dropFirst()), message)
    }

    func testMalformedAudioCannotFallBackToJSONOrRemoteDesktop() throws {
        let wire = try AudioStreamingLANEnvelope.encode(offer())
        for length in 5..<wire.count {
            XCTAssertThrowsError(try AudioStreamingLANEnvelope.decodeIfPresent(Data(wire.prefix(length))))
        }
        var timestamp = wire; timestamp[12] = 1
        XCTAssertThrowsError(try AudioStreamingLANEnvelope.decodeIfPresent(timestamp))
        var oversized = wire
        oversized.append(Data(repeating: 0, count: AudioStreamingLANEnvelope.maximumBytes))
        XCTAssertThrowsError(try AudioStreamingLANEnvelope.decodeIfPresent(oversized))
        var video = wire; video[4] = 1
        XCTAssertNil(try AudioStreamingLANEnvelope.decodeIfPresent(video))
        XCTAssertNil(try AudioStreamingLANEnvelope.decodeIfPresent(Data("{}".utf8)))
    }

    func testUnadvertisedPeerCannotBindOrSendAnOffer() throws {
        let mailbox = P2PAudioMailbox()
        let message = try offer()
        XCTAssertThrowsError(try mailbox.prepareSend(message, peerCapabilities: [], completion: .init())) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .unsupportedPeer)
        }
        XCTAssertNil(mailbox.streamID)
        let completion = P2PAudioSendCompletion()
        try mailbox.prepareSend(message, peerCapabilities: [AudioStreamingWire.captureReceiveCapability], completion: completion)
        XCTAssertEqual(mailbox.streamID, message.streamID)
        mailbox.finishSend(completion)
    }

    func testOnlyAnOfferCanOpenAStreamAndAnotherStreamCannotEnterItsQueue() throws {
        let mailbox = P2PAudioMailbox()
        XCTAssertThrowsError(try mailbox.receive(.init(streamID: UUID(), body: .credit(retiredBytes: 0)))) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .offerRequired)
        }
        try mailbox.receive(offer())
        XCTAssertThrowsError(try mailbox.receive(offer())) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .unexpectedStream)
        }
    }

    func testQueueOverflowIsTerminalAndNoBufferedSampleEscapes() async throws {
        let mailbox = P2PAudioMailbox()
        let message = try offer()
        try mailbox.receive(message)
        for index in 0..<7 {
            try mailbox.receive(.init(streamID: message.streamID, body: .credit(retiredBytes: UInt64(index))))
        }
        XCTAssertThrowsError(try mailbox.receive(.init(streamID: message.streamID, body: .stop(.userStopped)))) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .queueOverflow)
        }
        var iterator = P2PAudioMessages(mailbox: mailbox, validateOwner: {}).makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("overflowed queue delivered a buffered message") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .queueOverflow) }
    }

    func testRetiredMailboxRejectsAlreadyQueuedData() async throws {
        let mailbox = P2PAudioMailbox()
        try mailbox.receive(offer())
        var iterator = P2PAudioMessages(mailbox: mailbox, validateOwner: {}).makeAsyncIterator()
        mailbox.finish(.staleOwner)
        do { _ = try await iterator.next(); XCTFail("retired owner delivered data") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
    }

    func testSingleOrderedConsumerAndNormalRoundTrip() async throws {
        let mailbox = P2PAudioMailbox()
        let message = try offer()
        let messages = P2PAudioMessages(mailbox: mailbox, validateOwner: {})
        var first = messages.makeAsyncIterator()
        var second = messages.makeAsyncIterator()
        try mailbox.receive(message)
        let received = try await first.next()
        XCTAssertEqual(received, message)
        do { _ = try await second.next(); XCTFail("second consumer competed for messages") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .duplicateConsumer) }
    }

    func testOutputIsRecheckedAfterAnAwait() async throws {
        let mailbox = P2PAudioMailbox()
        let validation = ValidationCount()
        try mailbox.receive(offer())
        var iterator = P2PAudioMessages(mailbox: mailbox, validateOwner: {
            try validation.check()
        }).makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("owner changed after dequeue") }
        catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
        XCTAssertEqual(validation.count, 2)
    }

    func testOnlyOneSendMayBePendingAndRetirementCompletesIt() async throws {
        let mailbox = P2PAudioMailbox()
        let message = try offer()
        let completion = P2PAudioSendCompletion()
        try mailbox.prepareSend(message, peerCapabilities: [AudioStreamingWire.captureReceiveCapability], completion: completion)
        XCTAssertThrowsError(try mailbox.prepareSend(message, peerCapabilities: [AudioStreamingWire.captureReceiveCapability], completion: .init())) {
            XCTAssertEqual($0 as? P2PAudioTransportError, .sendInProgress)
        }
        mailbox.finish(.staleOwner)
        do {
            try await withCheckedThrowingContinuation { completion.install($0) }
            XCTFail("retirement left the write successful")
        } catch { XCTAssertEqual(error as? P2PAudioTransportError, .staleOwner) }
        XCTAssertFalse(completion.finish(.success(())))
    }

    func testCompletionBeforeInstallationAndLateDeadlineCannotWin() async throws {
        let completion = P2PAudioSendCompletion()
        XCTAssertTrue(completion.finish(.success(())))
        XCTAssertFalse(completion.finish(.failure(P2PAudioTransportError.timedOut)))
        try await withCheckedThrowingContinuation { completion.install($0) }
    }

    func testAnUnsubmittedOperationCannotCancelTheTransport() {
        let completion = P2PAudioSendCompletion()
        let cancellation = CancellationCount()
        completion.expireWrite { cancellation.increment() }
        XCTAssertEqual(cancellation.count, 0)
        XCTAssertTrue(completion.isPending)
        completion.finish(.failure(CancellationError()))
        XCTAssertFalse(completion.markSubmitted())
    }

    func testClosingTheMailboxDoesNotRemoveAnEnqueuedWriteDeadline() throws {
        let mailbox = P2PAudioMailbox()
        let completion = P2PAudioSendCompletion()
        let cancellation = CancellationCount()
        try mailbox.prepareSend(offer(), peerCapabilities: [AudioStreamingWire.captureReceiveCapability], completion: completion)
        XCTAssertTrue(completion.markSubmitted())
        mailbox.finish(.closed)
        XCTAssertFalse(completion.isPending) // The caller has already been released.
        completion.expireWrite { cancellation.increment() }
        XCTAssertEqual(cancellation.count, 1) // The unfinished I/O still had a deadline.
        completion.completeWrite(.success(()))
        completion.expireWrite { cancellation.increment() }
        XCTAssertEqual(cancellation.count, 1)
    }

    func testACompletedNativeWriteMakesLateTimeoutHarmless() async throws {
        let completion = P2PAudioSendCompletion()
        let cancellation = CancellationCount()
        XCTAssertTrue(completion.markSubmitted())
        completion.completeWrite(.success(()))
        completion.startWriteDeadline { cancellation.increment() }
        completion.expireWrite { cancellation.increment() }
        try await withCheckedThrowingContinuation { completion.install($0) }
        XCTAssertEqual(cancellation.count, 0)
    }

    func testHandshakeBarrierBeginsBeforeDriverInstallationAndSequenceSurvivesFinish() {
        var registry = P2PHandshakeOperationRegistry<AudioHandshakeDriver>()
        XCTAssertFalse(registry.hasActiveOperation)
        let previousPairingSequence = registry.operationSequence
        guard case .started(let token) = registry.begin(kind: .outboundRekey) else {
            return XCTFail("could not reserve handshake")
        }
        XCTAssertTrue(registry.hasActiveOperation)
        XCTAssertNil(registry.currentOwnedDriver())
        XCTAssertNotEqual(previousPairingSequence, registry.operationSequence)
        XCTAssertTrue(registry.finish(token))
        XCTAssertFalse(registry.hasActiveOperation)
        XCTAssertNotEqual(previousPairingSequence, registry.operationSequence)
    }
}

private final class AudioHandshakeDriver: Sendable {}

private final class CancellationCount: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

private final class ValidationCount: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    func check() throws {
        try value.withLock {
            $0 += 1
            if $0 == 2 { throw P2PAudioTransportError.staleOwner }
        }
    }
}
