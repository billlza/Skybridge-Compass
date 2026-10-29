import XCTest
import Foundation
import CryptoKit
import Network
import os
import struct SkyBridgeProtocolCore.AudioProtocolIdentity
import struct SkyBridgeProtocolCore.AudioStreamingMessage
import struct SkyBridgeProtocolCore.AudioStreamingPCMFormat
import struct SkyBridgeProtocolCore.AudioStreamingOpusFormat
import struct SkyBridgeProtocolCore.AudioBluetoothRoute
import struct SkyBridgeProtocolCore.AudioBluetoothNegotiation
import struct SkyBridgeProtocolCore.AudioBluetoothAttachmentSecret
import enum SkyBridgeProtocolCore.AudioBluetoothAttachmentError
import struct SkyBridgeProtocolCore.ProtocolIdentityBinding
import enum SkyBridgeProtocolCore.AudioStreamingChannelError
import enum SkyBridgeProtocolCore.AudioStreamingLANEnvelope
import enum SkyBridgeProtocolCore.AudioStreamingWire
import enum SkyBridgeProtocolCore.AudioStreamingWireError
import enum SkyBridgeProtocolCore.P2PControlFramePolicy
import class SkyBridgeProtocolCore.AudioStreamingSendCompletion
@testable import SkyBridgeCompass_iOS

private typealias NativeSessionKeys = SkyBridgeCompass_iOS.SessionKeys
private typealias NativeAppMessage = SkyBridgeCompass_iOS.AppMessage
private typealias NativePadding = SkyBridgeCompass_iOS.TrafficPadding
private typealias NativePaddingConfig = SkyBridgeCompass_iOS.TrafficPaddingConfig
private typealias NativeClassicMaterial = SkyBridgeCompass_iOS.P2PConnectionManager.ClassicFileTransferKeyMaterial

/// Synthetic, already-established keys and approved peer snapshots with a controlled
/// native enqueue/completion boundary. AES-GCM, framing and the carrier are real;
/// these tests do not establish a handshake, contact an account, or prove phone interop.
@available(iOS 17.0, *)
@MainActor
final class P2PAudioSessionTests: XCTestCase {
    func testImmediateBluetoothRefusalKeepsReasonAcrossNativeOfferCompletion() async throws {
        let fixture = try bluetoothFixture(); defer { fixture.shutdown() }
        let channel = try fixture.open(), (offer, _) = try bluetoothMessages()
        fixture.transport.automaticallyCompletes = false
        let sending = Task { try await channel.send(offer, requireEffectAuthorization: {}) }
        defer { sending.cancel() }
        try await waitUntil { fixture.transport.completions.count == 1 }
        XCTAssertEqual(try fixture.session.receive(.init(streamID: offer.streamID, body: .stop(.receiverDeclined))), .delivered)
        try XCTUnwrap(fixture.transport.completions.first).completeWrite(.success(()))
        do { try await sending.value; XCTFail("A stopped negotiation was committed") }
        catch { XCTAssertEqual(error as? AudioStreamingChannelError, .peerStopped(.receiverDeclined)) }
        XCTAssertThrowsError(try channel.prepareBluetoothAttachment())
        XCTAssertEqual(fixture.transport.cancellations.count, 0)
    }

    func testBluetoothBindingWaitsForActualWriteAndMatchesCommittedKeys() async throws {
        let fixture = try bluetoothFixture(); defer { fixture.shutdown() }
        let channel = try fixture.open(); try channel.claimOperation(UUID())
        let (offer, route) = try bluetoothMessages()
        XCTAssertThrowsError(try channel.prepareBluetoothAttachment()) {
            XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .notReady)
        }
        fixture.transport.automaticallyCompletes = false
        let sending = Task { try await channel.send(offer, requireEffectAuthorization: {}) }
        defer { sending.cancel() }
        try await waitUntil { fixture.transport.completions.count == 1 }
        XCTAssertEqual(try fixture.session.receive(route), .delivered)
        XCTAssertThrowsError(try channel.prepareBluetoothAttachment()) {
            XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .notReady,
                           "A received route cannot substitute for completed native offer I/O")
        }
        try XCTUnwrap(fixture.transport.completions.first).completeWrite(.success(()))
        try await sending.value
        let child = try channel.prepareBluetoothAttachment()
        XCTAssertEqual(child.binding.role, .source)
        XCTAssertEqual(child.binding.offer, offer); XCTAssertEqual(child.binding.route, route)
        XCTAssertThrowsError(try channel.prepareBluetoothAttachment()) {
            XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .alreadyIssued)
        }
        var sink = AudioBluetoothNegotiation(role: .sink, streamID: offer.streamID)
        try sink.receive(offer); try sink.prepareSend(route); try sink.commitSend(route)
        let counterpart = try AudioBluetoothAttachmentSecret(binding: sink.takeBinding(),
            sendKey: fixture.keys.receiveKey, receiveKey: fixture.keys.sendKey,
            transcriptHash: fixture.keys.transcriptHash, suite: fixture.keys.negotiatedSuite.wireId)
        let sourceNonce = Data(repeating: 0x61, count: 32), sinkNonce = Data(repeating: 0x62, count: 32)
        XCTAssertEqual(try child.confirmation(sourceNonce: sourceNonce, sinkNonce: sinkNonce),
            try counterpart.confirmation(role: .source, sourceNonce: sourceNonce, sinkNonce: sinkNonce))
        try child.verifyPeer(counterpart.confirmation(role: .sink, sourceNonce: sourceNonce, sinkNonce: sinkNonce),
                             sourceNonce: sourceNonce, sinkNonce: sinkNonce)
        child.close()
    }

    func testBluetoothAttachmentRetiresOnMainStopBeforeChannelCleanup() async throws {
        for incoming in [true, false] {
            let fixture = try bluetoothFixture(); defer { fixture.shutdown() }
            let channel = try fixture.open(), (offer, route) = try bluetoothMessages()
            try await channel.send(offer, requireEffectAuthorization: {})
            XCTAssertEqual(try fixture.session.receive(route), .delivered)
            let child = try channel.prepareBluetoothAttachment()
            XCTAssertGreaterThan(try child.handshakeRemainingTime(), .zero)
            if incoming {
                XCTAssertEqual(try fixture.session.receive(.init(streamID: offer.streamID, body: .stop(.userStopped))), .delivered)
            } else { try await channel.sendStop(.userStopped) }
            XCTAssertThrowsError(try child.handshakeRemainingTime()) {
                XCTAssertEqual($0 as? AudioBluetoothAttachmentError, .closed)
            }
            try channel.requireCurrent() // MAIN can still deliver the reason and close normally.
            XCTAssertEqual(fixture.transport.cancellations.count, 0)
        }
    }

    func testBluetoothAttachmentCannotFollowEpochReplacementOrReopenedMailbox() async throws {
        for invalidateEpoch in [false, true] {
            let fixture = try bluetoothFixture(); defer { fixture.shutdown() }
            let channel = try fixture.open(), (offer, route) = try bluetoothMessages()
            try await channel.send(offer, requireEffectAuthorization: {})
            XCTAssertEqual(try fixture.session.receive(route), .delivered)
            let child = try channel.prepareBluetoothAttachment()
            if invalidateEpoch { fixture.session.invalidate() }
            else { channel.close(); _ = try fixture.open() }
            XCTAssertThrowsError(try child.handshakeRemainingTime()) {
                XCTAssertEqual($0 as? AudioStreamingChannelError, invalidateEpoch ? .staleOwner : .closed)
            }
        }
    }

    func testFailedCancelledOrStaleNativeOfferCannotIssueBluetoothAttachment() async throws {
        for termination in 0..<3 {
            let fixture = try bluetoothFixture(); defer { fixture.shutdown() }
            fixture.transport.automaticallyCompletes = false
            let channel = try fixture.open(), (offer, route) = try bluetoothMessages()
            let sending = Task { try await channel.send(offer, requireEffectAuthorization: {}) }
            defer { sending.cancel() }
            try await waitUntil { fixture.transport.completions.count == 1 }
            XCTAssertEqual(try fixture.session.receive(route), .delivered)
            let completion = try XCTUnwrap(fixture.transport.completions.first)
            if termination == 0 { completion.completeWrite(.failure(FixtureFailure.denied)) }
            else if termination == 1 {
                sending.cancel()
                do { try await sending.value; XCTFail("Cancelled offer succeeded") } catch { XCTAssertTrue(error is CancellationError) }
                completion.completeWrite(.success(()))
            } else {
                completion.completeWrite(.success(()))
                fixture.session.invalidate()
            }
            do { try await sending.value; XCTFail("Uncommitted offer succeeded") }
            catch {
                if termination == 0 { XCTAssertEqual(error as? FixtureFailure, .denied) }
                if termination == 2 { XCTAssertEqual(error as? AudioStreamingChannelError, .staleOwner) }
            }
            XCTAssertThrowsError(try channel.prepareBluetoothAttachment())
        }
    }

    private func bluetoothFixture() throws -> Fixture {
        try Fixture(capabilities: [AudioStreamingWire.opusReceiveCapability, AudioStreamingWire.bluetoothAttachmentCapability],
                    filePort: nil, endpoint: nil)
    }

    private func bluetoothMessages() throws -> (AudioStreamingMessage, AudioStreamingMessage) {
        let stream = UUID()
        return (.init(streamID: stream, body: .opusOffer(source: .originalFile,
                    format: try AudioStreamingOpusFormat(channels: 2, bitrate: 192_000))),
                .init(streamID: stream, body: .bluetoothRoute(try AudioBluetoothRoute(serviceID: UUID(), publicationID: UUID(), psm: 129))))
    }

    func testPlaybackPresentationRequiresExactCapabilityAndFileEndpointOnlyForFiles() throws {
        let identity = try AudioProtocolIdentity(deviceID: "presentation-peer", algorithm: .ed25519,
                                                fingerprint: String(repeating: "ab", count: 32))
        let file = AudioStreamingWire.fileReceiveCapability, capture = AudioStreamingWire.captureReceiveCapability
        let cases: [(Set<String>, UInt16?, Set<IOSAudioPlaybackSource>?)] = [
            ([], 80, nil), ([file], nil, nil), ([file], 0, nil), ([file], 80, [.originalFile]),
            ([capture], nil, [.systemCapture]), ([file, capture], 0, [.systemCapture]),
            ([file, capture], 80, [.originalFile, .systemCapture]), ([capture + "-unknown"], 80, nil),
            ([file, AudioStreamingWire.usbFileReceiveCapability, "classic_approval_v1"], nil, [.originalFile]),
            ([file, AudioStreamingWire.usbFileReceiveCapability], 80, nil),
            ([AudioStreamingWire.usbFileReceiveCapability, "classic_approval_v1"], nil, nil)
        ]
        for (capabilities, port, expected) in cases {
            let peer = IOSAudioPeerSnapshot(generation: UUID(), sessionID: "approved-presentation-session",
                identity: identity, capabilities: capabilities, filePort: port, acceptedMaterialDigest: Data(repeating: 3, count: 32))
            let target = IOSAudioPlaybackTarget(deviceID: "runtime-alias", name: "Computer", peer: peer)
            XCTAssertEqual(target?.sources, expected)
            if let target {
                XCTAssertEqual(target.identity, identity); XCTAssertEqual(target.deviceID, "runtime-alias")
            }
        }
    }

    func testInboundControlsPassBothHandshakeProbesWithoutRetiringAudio() async throws {
        let manager = P2PConnectionManager.instance
        let peerID = UUID().uuidString
        defer { manager.testSimulateTerminalCleanup(runtimePeerId: peerID) }
        try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: peerID)
        let session = try manager.testInstallAudioSession(for: peerID)
        let channel = try session.open(requiringFingerprint: session.peer.identity.fingerprint)
        defer { channel.close() }
        let offer = fileOffer(transfer: UUID())
        try await channel.send(offer, requireEffectAuthorization: {})
        let accepted = AudioStreamingMessage(streamID: offer.streamID, body: .accept(receiveWindowBytes: 0))
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let control = try AES.GCM.seal(AudioStreamingLANEnvelope.encode(accepted), using: key)
        let heartbeat = NativeAppMessage.heartbeat(.init())
        let ordinary = try AES.GCM.seal(JSONEncoder().encode(heartbeat), using: key)
        for frame in [try XCTUnwrap(control.combined), try XCTUnwrap(ordinary.combined)] {
            try await manager.testReceiveEstablishedControlFrame(frame, for: peerID)
            XCTAssertFalse(session.isInvalidated, "Probing an ordinary frame must not retire the active stream")
            try channel.requireCurrent()
        }
        var reader = channel.messages.makeAsyncIterator()
        let received = try await reader.next()
        XCTAssertEqual(received, accepted)

        // Actual replacement still retires the old audio owner on the same socket.
        try manager.testReplaceSessionOnCurrentTransport(for: peerID)
        XCTAssertTrue(session.isInvalidated)
        XCTAssertThrowsError(try channel.requireCurrent()) {
            XCTAssertEqual($0 as? AudioStreamingChannelError, .staleOwner)
        }
    }

    func testNativeSendContainsExactLengthPaddingAESAndSBE1Message() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open(); let message = try captureOffer()
        var effects = 0
        try await channel.send(message, requireEffectAuthorization: { effects += 1 })
        XCTAssertEqual(effects, 1); XCTAssertEqual(fixture.transport.frames.count, 1)
        let frame = try XCTUnwrap(fixture.transport.frames.first)
        let ciphertext = try unframe(frame)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
                                        using: SymmetricKey(data: fixture.keys.sendKey))
        XCTAssertEqual(Array(plaintext.prefix(13)), [0x53, 0x42, 0x45, 0x31, 2, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Data(plaintext.dropFirst(13)), try AudioStreamingWire.encode(message))
        guard case let .audio(decoded) = try IOSAuthenticatedControlPayload.decode(plaintext) else {
            return XCTFail("Encrypted audio was dispatched as an app message")
        }
        XCTAssertEqual(decoded, message)
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
                                            using: SymmetricKey(data: fixture.keys.receiveKey)))
        var corrupt = ciphertext; corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: corrupt),
                                            using: SymmetricKey(data: fixture.keys.sendKey)))

        // Exercise deterministic enabled SBP2 without changing any UserDefaults.
        // The actual send above independently honors the host's existing config.
        let padded = try NativePadding.wrapForP2PControlFrame(ciphertext, configuration: NativePaddingConfig(
            enabled: true, debugLog: false, mode: .fixed, fixedSizeBytes: 256, bucketSizesBytes: [256]), label: "audio-test")
        XCTAssertEqual(padded.count, 256); XCTAssertEqual(Data(padded.prefix(4)), Data("SBP2".utf8))
        let explicitFrame = try P2PControlFramePolicy.frame(body: padded)
        XCTAssertEqual(try unframe(explicitFrame), ciphertext)
    }

    func testUSBReturnRouteNeedsFileAcceptanceAndCannotBePublishedTwice() async throws {
        let fixture = try Fixture(capabilities: [AudioStreamingWire.fileReceiveCapability,
            AudioStreamingWire.usbFileReceiveCapability, "classic_approval_v1"], filePort: nil,
            endpoint: nil, usbReturn: true)
        defer { fixture.shutdown() }
        let channel = try fixture.open(), transferID = UUID(), offer = fileOffer(transfer: transferID)
        try await channel.send(offer, requireEffectAuthorization: {})
        XCTAssertEqual(try channel.classicFileAuthority(transferID: transferID.uuidString).route, .usbReturn)
        do {
            try await channel.announceUSBFileReturn(port: 49_153, transferID: transferID.uuidString, requireEffectAuthorization: {})
            XCTFail("A route was published before receiver acceptance")
        } catch { XCTAssertEqual(error as? AudioStreamingChannelError, .fileTransferMismatch) }
        XCTAssertEqual(fixture.transport.frames.count, 1)
        XCTAssertEqual(try fixture.session.receive(.init(streamID: offer.streamID, body: .accept(receiveWindowBytes: 0))), .delivered)
        try await channel.announceUSBFileReturn(port: 49_153, transferID: transferID.uuidString, requireEffectAuthorization: {})
        let ciphertext = try unframe(XCTUnwrap(fixture.transport.frames.last))
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: fixture.keys.sendKey))
        XCTAssertEqual(try AudioStreamingLANEnvelope.decodeIfPresent(plaintext),
            .init(streamID: offer.streamID, body: .usbFileRoute(port: 49_153)))
        do {
            try await channel.announceUSBFileReturn(port: 49_154, transferID: transferID.uuidString, requireEffectAuthorization: {})
            XCTFail("A file stream published a second listener")
        } catch { XCTAssertEqual(error as? AudioStreamingChannelError, .fileTransferMismatch) }
        XCTAssertEqual(fixture.transport.frames.count, 2)
    }

    func testJSONAndAudioDemuxRejectsRecognizedMalformedAudioWithoutFallback() throws {
        let app = NativeAppMessage.textMessage(.init(text: "fixture", sentAt: Date(timeIntervalSince1970: 1234)))
        guard case let .app(decoded) = try IOSAuthenticatedControlPayload.decode(JSONEncoder().encode(app)) else {
            return XCTFail("JSON was dispatched to audio")
        }
        XCTAssertEqual(decoded, app)
        let message = try captureOffer(); let bytes = try AudioStreamingLANEnvelope.encode(message)
        guard case let .audio(audio) = try IOSAuthenticatedControlPayload.decode(bytes) else {
            return XCTFail("SBE1 audio was dispatched to JSON")
        }
        XCTAssertEqual(audio, message)
        for length in 5..<bytes.count {
            XCTAssertThrowsError(try IOSAuthenticatedControlPayload.decode(Data(bytes.prefix(length)))) {
                XCTAssertNotNil($0 as? AudioStreamingWireError, "Recognized audio fell into the JSON error path")
            }
        }
        var timestamp = bytes; timestamp[12] = 1
        XCTAssertThrowsError(try IOSAuthenticatedControlPayload.decode(timestamp)) {
            XCTAssertEqual($0 as? AudioStreamingWireError, .malformed)
        }
        let oversized = bytes + Data(repeating: 0, count: AudioStreamingLANEnvelope.maximumBytes)
        XCTAssertThrowsError(try IOSAuthenticatedControlPayload.decode(oversized)) {
            XCTAssertEqual($0 as? AudioStreamingWireError, .oversized)
        }
    }

    func testRequiredEffectDenialNeverEnqueuesNativeBytes() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open()
        do {
            try await channel.send(captureOffer(), requireEffectAuthorization: { throw FixtureFailure.denied })
            XCTFail("Denied effect was sent")
        } catch { XCTAssertEqual(error as? FixtureFailure, .denied) }
        XCTAssertTrue(fixture.transport.frames.isEmpty)
        XCTAssertEqual(fixture.transport.cancellations.count, 0)
        XCTAssertThrowsError(try channel.requireCurrent())
    }

    func testOwnerChangedInsideEffectIsRecheckedBeforeNativeEnqueue() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open()
        await assertChannelError(.staleOwner) {
            try await channel.send(self.captureOffer(), requireEffectAuthorization: { fixture.connection.current = false })
        }
        XCTAssertTrue(fixture.session.isInvalidated)
        XCTAssertTrue(fixture.transport.frames.isEmpty)
        XCTAssertEqual(fixture.transport.cancellations.count, 0)
    }

    func testUnsupportedCapabilitiesAndMissingOrMismatchedFileEndpointNeverSend() async throws {
        let unsupported = try Fixture(capabilities: []); defer { unsupported.shutdown() }
        let channel = try unsupported.open()
        await assertChannelError(.unsupportedPeer) {
            try await channel.send(self.captureOffer(), requireEffectAuthorization: {})
        }
        await assertChannelError(.unsupportedPeer) {
            try await channel.send(self.fileOffer(), requireEffectAuthorization: {})
        }
        XCTAssertTrue(unsupported.transport.frames.isEmpty)
        for (port, endpoint) in [(UInt16?.none, Fixture.endpoint), (UInt16?(0), Fixture.endpoint), (UInt16?(8080), NWEndpoint?.none),
                                 (UInt16?(8081), Fixture.endpoint)] {
            let fixture = try Fixture(filePort: port, endpoint: endpoint); defer { fixture.shutdown() }
            let fileChannel = try fixture.open()
            await assertChannelError(.unavailable) {
                try await fileChannel.send(self.fileOffer(), requireEffectAuthorization: {})
            }
            XCTAssertTrue(fixture.transport.frames.isEmpty)
        }
    }

    func testOnlyOneConsumerMayReceiveAndDuplicateDoesNotStealReply() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open(); let offer = try captureOffer()
        try await channel.send(offer, requireEffectAuthorization: {})
        let reply = AudioStreamingMessage(streamID: offer.streamID, body: .accept(receiveWindowBytes: 4096))
        XCTAssertEqual(try fixture.session.receive(reply), .delivered)
        var first = channel.messages.makeAsyncIterator(); var second = channel.messages.makeAsyncIterator()
        do { _ = try await second.next(); XCTFail("Duplicate consumer received a reply") }
        catch { XCTAssertEqual(error as? AudioStreamingChannelError, .duplicateConsumer) }
        let received = try await first.next()
        XCTAssertEqual(received, reply)
    }

    func testEightRepliesRemainBoundedAndOrderedWithoutDropping() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open(); let offer = try captureOffer()
        try await channel.send(offer, requireEffectAuthorization: {})
        let replies = (0..<8).map { AudioStreamingMessage(streamID: offer.streamID, body: .credit(retiredBytes: UInt64($0))) }
        for reply in replies { XCTAssertEqual(try fixture.session.receive(reply), .delivered) }
        var iterator = channel.messages.makeAsyncIterator()
        for expected in replies {
            let actual = try await iterator.next(); XCTAssertEqual(actual, expected)
        }
        try channel.requireCurrent(); XCTAssertEqual(fixture.transport.cancellations.count, 0)
    }

    func testNinthReplyTerminatesOnlyAudioAndNoBufferedReplyEscapes() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open(); let offer = try captureOffer()
        try await channel.send(offer, requireEffectAuthorization: {})
        for index in 0..<8 {
            XCTAssertEqual(try fixture.session.receive(.init(streamID: offer.streamID, body: .credit(retiredBytes: UInt64(index)))), .delivered)
        }
        XCTAssertEqual(try fixture.session.receive(.init(streamID: offer.streamID, body: .credit(retiredBytes: 8))), .retired)
        var iterator = channel.messages.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Overflowed mailbox delivered a buffered reply") }
        catch { XCTAssertEqual(error as? AudioStreamingChannelError, .queueOverflow) }
        XCTAssertFalse(fixture.session.isInvalidated); XCTAssertEqual(fixture.transport.cancellations.count, 0)
        let next = try fixture.open(); let nextOffer = try captureOffer()
        try await next.send(nextOffer, requireEffectAuthorization: {})
        XCTAssertEqual(try fixture.session.receive(.init(streamID: offer.streamID, body: .credit(retiredBytes: 9))), .retired)
        XCTAssertEqual(try fixture.session.receive(.init(streamID: nextOffer.streamID, body: .accept(receiveWindowBytes: 4096))), .delivered)
    }

    func testCloseAndEpochInvalidationRejectAlreadyBufferedReplies() async throws {
        for invalidate in [false, true] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let channel = try fixture.open(); let offer = try captureOffer()
            try await channel.send(offer, requireEffectAuthorization: {})
            XCTAssertEqual(try fixture.session.receive(.init(streamID: offer.streamID, body: .credit(retiredBytes: 4))), .delivered)
            var iterator = channel.messages.makeAsyncIterator()
            if invalidate { fixture.session.invalidate() } else { channel.close() }
            do { _ = try await iterator.next(); XCTFail("Retired owner delivered a buffered reply") }
            catch { XCTAssertEqual(error as? AudioStreamingChannelError, invalidate ? .staleOwner : .closed) }
            XCTAssertEqual(fixture.transport.cancellations.count, 0)
        }
    }

    func testCloseAndEpochInvalidationWakeAnAwaitingConsumer() async throws {
        for invalidate in [false, true] {
            let fixture = try Fixture(); defer { fixture.shutdown() }
            let channel = try fixture.open(); let offer = try captureOffer()
            try await channel.send(offer, requireEffectAuthorization: {})
            var entered = false
            let waiting = Task { @MainActor in
                var iterator = channel.messages.makeAsyncIterator()
                entered = true
                return try await iterator.next()
            }
            defer { waiting.cancel() }
            try await waitUntil { entered }
            if invalidate { fixture.session.invalidate() } else { channel.close() }
            await assertChannelError(invalidate ? .staleOwner : .closed) { _ = try await waiting.value }
        }
    }

    func testSixtyFourRetiredStreamsAreNeverEvictedOrReopened() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        var ids: [UUID] = []
        for _ in 0..<64 {
            let channel = try fixture.open(); let offer = try captureOffer(); ids.append(offer.streamID)
            try await channel.send(offer, requireEffectAuthorization: {}); channel.close()
        }
        XCTAssertThrowsError(try fixture.open()) { XCTAssertEqual($0 as? AudioStreamingChannelError, .epochCapacity) }
        for id in ids {
            XCTAssertEqual(try fixture.session.receive(.init(streamID: id, body: .credit(retiredBytes: 0))), .retired)
        }
        XCTAssertEqual(fixture.transport.frames.count, 64)
        XCTAssertFalse(fixture.session.isInvalidated); XCTAssertEqual(fixture.transport.cancellations.count, 0)
    }

    func testSameEpochRollbackPreservesTombstonesAndCannotReviveOldChannel() async throws {
        let original = try Fixture(); defer { original.shutdown() }
        let oldChannel = try original.open(); let oldOffer = try captureOffer()
        try await oldChannel.send(oldOffer, requireEffectAuthorization: {})
        original.session.invalidate()
        let rollback = try Fixture(generation: original.generation, keys: original.keys, history: original.session.streamHistory())
        defer { rollback.shutdown() }
        XCTAssertTrue(rollback.session.matches(generation: original.generation, keys: original.keys))
        let channel = try rollback.open()
        await assertChannelError(.unexpectedStream) { try await channel.send(oldOffer, requireEffectAuthorization: {}) }
        XCTAssertTrue(rollback.transport.frames.isEmpty)
        XCTAssertThrowsError(try oldChannel.requireCurrent()) { XCTAssertEqual($0 as? AudioStreamingChannelError, .staleOwner) }
        let newOffer = try captureOffer(); try await channel.send(newOffer, requireEffectAuthorization: {})
        XCTAssertEqual(try rollback.session.receive(.init(streamID: oldOffer.streamID, body: .credit(retiredBytes: 0))), .retired)
        XCTAssertEqual(rollback.transport.frames.count, 1)
    }

    func testCancelledCallerRetainsActualWriteDeadlineAndCancelsOnlyOriginalTransport() async throws {
        let original = try Fixture(); defer { original.shutdown() }
        original.transport.automaticallyCompletes = false
        let channel = try original.open(); let offer = try captureOffer()
        let sending = Task { @MainActor in try await channel.send(offer, requireEffectAuthorization: {}) }
        defer { sending.cancel() }
        try await waitUntil { original.transport.completions.count == 1 }
        sending.cancel()
        do { try await sending.value; XCTFail("Canceled caller succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(original.transport.cancellations.count, 0)
        original.session.invalidate()

        let replacement = try Fixture(keys: original.keys); defer { replacement.shutdown() }
        let replacementChannel = try replacement.open()
        try await replacementChannel.send(captureOffer(), requireEffectAuthorization: {})
        // Real five-second production deadline: no synthetic call to expireWrite.
        try await waitUntil(timeout: .seconds(7)) { original.transport.cancellations.count == 1 }
        XCTAssertEqual(replacement.transport.cancellations.count, 0)
        try replacementChannel.requireCurrent()
        let old = try XCTUnwrap(original.transport.completions.first)
        old.completeWrite(.success(()))
        let oldCancellation = original.transport.cancellations
        old.expireWrite { oldCancellation.increment() }
        XCTAssertEqual(original.transport.cancellations.count, 1)
    }

    func testActualIOCompletionAfterCallerCancellationNeutralizesLateExpiry() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        fixture.transport.automaticallyCompletes = false
        let channel = try fixture.open(); let offer = try captureOffer()
        let sending = Task { @MainActor in try await channel.send(offer, requireEffectAuthorization: {}) }
        defer { sending.cancel() }
        try await waitUntil { fixture.transport.completions.count == 1 }
        let completion = try XCTUnwrap(fixture.transport.completions.first)
        sending.cancel()
        do { try await sending.value; XCTFail("Canceled caller succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        completion.completeWrite(.success(()))
        let cancellation = fixture.transport.cancellations
        completion.expireWrite { cancellation.increment() }
        XCTAssertEqual(cancellation.count, 0)
        fixture.transport.automaticallyCompletes = true
        let next = try fixture.open(); try await next.send(captureOffer(), requireEffectAuthorization: {})
        try next.requireCurrent()
    }

    func testClassicMaterialRequiresFileOfferAndPreservesRawUUIDKDFAndGeneration() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open()
        let upper = "ABCDEFAB-1234-5678-9ABC-ABCDEFABCDEF", lower = upper.lowercased()
        let transfer = try XCTUnwrap(UUID(uuidString: upper))
        XCTAssertThrowsError(try channel.classicFileAuthority(transferID: upper)) {
            XCTAssertEqual($0 as? AudioStreamingChannelError, .fileTransferMismatch)
        }
        try await channel.send(fileOffer(transfer: transfer), requireEffectAuthorization: {})
        let exact = try channel.classicFileAuthority(transferID: upper)
        let alternateSpelling = try channel.classicFileAuthority(transferID: lower)
        XCTAssertEqual(exact.route, .network(try XCTUnwrap(Fixture.endpoint)))
        XCTAssertEqual(exact.material.connectionGeneration, fixture.generation)
        XCTAssertEqual(exact.material.approvalCapability, true)
        let expected = NativeClassicMaterial(sessionKeys: fixture.keys, transferId: upper, connectionGeneration: fixture.generation)
        XCTAssertTrue(exact.material.matches(expected))
        XCTAssertEqual(keyBytes(exact.material.transferKey), independentlyDerivedKey(fixture.keys, rawTransferID: upper))
        XCTAssertNotEqual(keyBytes(exact.material.transferKey), keyBytes(alternateSpelling.material.transferKey))
        let replaced = NativeClassicMaterial(sessionKeys: fixture.keys, transferId: upper, connectionGeneration: UUID())
        XCTAssertFalse(exact.material.matches(replaced))
        XCTAssertThrowsError(try channel.classicFileAuthority(transferID: UUID().uuidString))
        fixture.session.invalidate()
        XCTAssertThrowsError(try channel.classicFileAuthority(transferID: upper))

        let captured = try Fixture(); defer { captured.shutdown() }
        let capture = try captured.open(); try await capture.send(captureOffer(), requireEffectAuthorization: {})
        XCTAssertThrowsError(try capture.classicFileAuthority(transferID: upper)) {
            XCTAssertEqual($0 as? AudioStreamingChannelError, .fileTransferMismatch)
        }
    }

    func testUserStopNeedsCurrentOfferedChannelButNoPositiveEffectGrant() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open()
        await assertChannelError(.offerRequired) { try await channel.sendStop(.userStopped) }
        XCTAssertTrue(fixture.transport.frames.isEmpty)
        var effects = 0; let offer = try captureOffer()
        try await channel.send(offer, requireEffectAuthorization: { effects += 1 })
        try await channel.sendStop(.userStopped)
        XCTAssertEqual(effects, 1); XCTAssertEqual(fixture.transport.frames.count, 2)
        let frame = try XCTUnwrap(fixture.transport.frames.last)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: unframe(frame)), using: SymmetricKey(data: fixture.keys.sendKey))
        XCTAssertEqual(try AudioStreamingLANEnvelope.decodeIfPresent(plaintext),
                       AudioStreamingMessage(streamID: offer.streamID, body: .stop(.userStopped)))
        channel.close()
        let replacement = try fixture.open(); try await replacement.send(captureOffer(), requireEffectAuthorization: {})
        await assertChannelError(.closed) { try await channel.sendStop(.userStopped) }
        XCTAssertEqual(fixture.transport.frames.count, 3); try replacement.requireCurrent()
    }

    func testOnePendingNativeWriteAndOneChannelCannotBeStolenByAnotherOperation() async throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        fixture.transport.automaticallyCompletes = false
        let channel = try fixture.open(); let offer = try captureOffer()
        let sending = Task { @MainActor in try await channel.send(offer, requireEffectAuthorization: {}) }
        defer { sending.cancel() }
        try await waitUntil { fixture.transport.completions.count == 1 }
        XCTAssertThrowsError(try fixture.open()) { XCTAssertEqual($0 as? AudioStreamingChannelError, .alreadyRegistered) }
        await assertChannelError(.sendInProgress) { try await channel.sendStop(.userStopped) }
        XCTAssertEqual(fixture.transport.frames.count, 1)
        try XCTUnwrap(fixture.transport.completions.first).completeWrite(.success(()))
        try await sending.value
        fixture.transport.automaticallyCompletes = true
        try await channel.sendStop(.userStopped)
        XCTAssertEqual(fixture.transport.frames.count, 2); XCTAssertEqual(fixture.transport.cancellations.count, 0)
    }

    func testExactSessionMatchAndAccountBindingCannotFollowReplacement() throws {
        let fixture = try Fixture(); defer { fixture.shutdown() }
        let channel = try fixture.open()
        XCTAssertEqual(try channel.localIdentityBindingForAccountRequest(), fixture.localIdentity)
        XCTAssertEqual(channel.remoteIdentity, fixture.peer.identity)
        XCTAssertTrue(fixture.session.matches(generation: fixture.generation, keys: fixture.keys))
        XCTAssertFalse(fixture.session.matches(generation: UUID(), keys: fixture.keys))
        let replacedKeys = NativeSessionKeys(sendKey: Data(repeating: 9, count: 32), receiveKey: fixture.keys.receiveKey,
            negotiatedSuite: fixture.keys.negotiatedSuite, role: fixture.keys.role,
            transcriptHash: fixture.keys.transcriptHash, sessionId: fixture.keys.sessionId)
        XCTAssertFalse(fixture.session.matches(generation: fixture.generation, keys: replacedKeys))
        XCTAssertThrowsError(try fixture.session.open(requiringFingerprint: String(repeating: "cd", count: 32))) {
            XCTAssertEqual($0 as? AudioStreamingChannelError, .staleOwner)
        }
        fixture.connection.current = false
        XCTAssertThrowsError(try channel.localIdentityBindingForAccountRequest()) {
            XCTAssertEqual($0 as? AudioStreamingChannelError, .staleOwner)
        }
        XCTAssertTrue(fixture.session.isInvalidated)
    }

    // These are deterministic admission-gate tests. The suspended task models an
    // old UI/durable-commit continuation; it does not invoke Manager or a network.
    func testAdmissionBeforeFirstPublicationRejectsOldCommitAfterNewProposalOrRejection() async throws {
        let original = admissionProposal()
        for reject in [false, true] {
            let state = AdmissionState(generation: UUID()); let gate = AdmissionGate()
            let ticket = state.value.observe(original)
            XCTAssertTrue(state.value.permits(ticket, proposal: original))
            let oldCommit = Task { @MainActor in
                await gate.wait()
                return state.value.permits(ticket, proposal: original)
            }
            defer { gate.release(); oldCommit.cancel() }
            try await waitUntil { gate.isWaiting }
            // No audio peer/session has been published. A newer proposal or a
            // rejection must still supersede this first in-flight transaction.
            if reject {
                state.value.invalidate()
            } else {
                let newer = admissionProposal(digestByte: 0x45)
                let newerTicket = state.value.observe(newer)
                XCTAssertTrue(state.value.permits(newerTicket, proposal: newer))
                XCTAssertFalse(state.value.permits(ticket, proposal: newer))
            }
            gate.release()
            let permitted = await oldCommit.value
            XCTAssertFalse(permitted, "Old first-publication commit recovered authority after supersession")
        }
    }

    func testAdmissionIdenticalProposalObservationIsIdempotent() {
        var admission = IOSAudioAdmission(generation: UUID(), deviceID: "audio-peer-native-0002")
        let first = admissionProposal()
        let reordered = IOSAudioAdmission.Proposal(materialDigest: first.materialDigest,
            capabilities: Set(first.capabilities.sorted().reversed()), filePort: first.filePort)
        let initial = admission.observe(first)
        for _ in 0..<4 {
            let duplicate = admission.observe(reordered)
            XCTAssertEqual(duplicate, initial)
            XCTAssertTrue(admission.permits(initial, proposal: first))
            XCTAssertTrue(admission.permits(duplicate, proposal: reordered))
        }
    }

    func testAdmissionCapabilityOnlyAndPortOnlyChangesInvalidateTicketsWithSamePairingDigest() {
        let original = admissionProposal()
        let changed = [
            IOSAudioAdmission.Proposal(materialDigest: original.materialDigest,
                capabilities: [], filePort: original.filePort),
            IOSAudioAdmission.Proposal(materialDigest: original.materialDigest,
                capabilities: original.capabilities.union([AudioStreamingWire.captureReceiveCapability]), filePort: original.filePort),
            IOSAudioAdmission.Proposal(materialDigest: original.materialDigest,
                capabilities: original.capabilities, filePort: 8081),
            IOSAudioAdmission.Proposal(materialDigest: original.materialDigest,
                capabilities: original.capabilities, filePort: nil)
        ]
        for replacement in changed {
            var admission = IOSAudioAdmission(generation: UUID(), deviceID: "audio-peer-native-0002")
            let old = admission.observe(original), current = admission.observe(replacement)
            XCTAssertEqual(original.materialDigest, replacement.materialDigest)
            XCTAssertNotEqual(old, current)
            XCTAssertFalse(admission.permits(old, proposal: original))
            XCTAssertFalse(admission.permits(old, proposal: replacement))
            XCTAssertTrue(admission.permits(current, proposal: replacement))
            // Restoring identical bytes later is a new admission, not revival.
            let restored = admission.observe(original)
            XCTAssertNotEqual(restored, old)
            XCTAssertFalse(admission.permits(old, proposal: original))
            XCTAssertTrue(admission.permits(restored, proposal: original))
        }
    }

    func testAdmissionClearThenSameProposalCannotReviveSuspendedCommit() async throws {
        let state = AdmissionState(generation: UUID()); let gate = AdmissionGate()
        let proposal = admissionProposal()
        let oldTicket = state.value.observe(proposal)
        let oldCommit = Task { @MainActor in
            await gate.wait()
            // Use the original ticket. Obtaining a new ticket here would hide
            // exactly the post-await publication race being tested.
            return state.value.permits(oldTicket, proposal: proposal)
        }
        defer { gate.release(); oldCommit.cancel() }
        try await waitUntil { gate.isWaiting }
        state.value.invalidate()
        XCTAssertFalse(state.value.permits(oldTicket, proposal: proposal))
        let newTicket = state.value.observe(proposal)
        XCTAssertNotEqual(newTicket, oldTicket)
        XCTAssertTrue(state.value.permits(newTicket, proposal: proposal))
        gate.release()
        let permitted = await oldCommit.value
        XCTAssertFalse(permitted, "Cleared admission revived a pre-clear asynchronous commit")
    }

    func testAdmissionReplacementGenerationCannotBorrowOldSuspendedTicket() async throws {
        let firstGeneration = UUID(), secondGeneration = UUID()
        let state = AdmissionState(generation: firstGeneration); let gate = AdmissionGate()
        let proposal = admissionProposal()
        let oldTicket = state.value.observe(proposal)
        let oldSnapshot = state.value
        let oldCommit = Task { @MainActor in
            await gate.wait()
            return state.value.permits(oldTicket, proposal: proposal)
        }
        defer { gate.release(); oldCommit.cancel() }
        try await waitUntil { gate.isWaiting }
        state.value = IOSAudioAdmission(generation: secondGeneration, deviceID: "audio-peer-native-0002")
        let replacement = state.value.observe(proposal)
        XCTAssertNotEqual(firstGeneration, state.value.generation)
        XCTAssertTrue(oldSnapshot.permits(oldTicket, proposal: proposal))
        XCTAssertTrue(state.value.permits(replacement, proposal: proposal))
        XCTAssertFalse(state.value.permits(oldTicket, proposal: proposal))
        XCTAssertFalse(oldSnapshot.permits(replacement, proposal: proposal))
        gate.release()
        let permitted = await oldCommit.value
        XCTAssertFalse(permitted, "Old generation's commit was admitted by its replacement")
    }

    private func admissionProposal(digestByte: UInt8 = 0x34) -> IOSAudioAdmission.Proposal {
        .init(materialDigest: Data(repeating: digestByte, count: 32),
              capabilities: [AudioStreamingWire.fileReceiveCapability, "classic_approval_v1"], filePort: 8080)
    }

    private func captureOffer(_ streamID: UUID = UUID()) throws -> AudioStreamingMessage {
        .init(streamID: streamID, body: .captureOffer(try AudioStreamingPCMFormat(sampleRate: 48000, channels: 2,
            encoding: .float32, declaredValidBits: 32, waveChannelMask: 3)))
    }
    private func fileOffer(transfer: UUID = UUID()) -> AudioStreamingMessage {
        .init(streamID: UUID(), body: .fileOffer(transferID: transfer, length: 4096, sha256: Data(repeating: 0x45, count: 32)))
    }
    private func unframe(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw FixtureFailure.badFrame }
        let count = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(try P2PControlFramePolicy.inboundBodyByteCount(from: count), frame.count - 4)
        return try NativePadding.unwrapIfNeeded(Data(frame.dropFirst(4)), label: "audio-test",
                                                maximumOutputByteCount: P2PControlFramePolicy.maximumBodyByteCount)
    }
    private func independentlyDerivedKey(_ keys: NativeSessionKeys, rawTransferID: String) -> Data {
        let ordered = [keys.sendKey, keys.receiveKey].sorted { $0.lexicographicallyPrecedes($1) }
        return keyBytes(HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ordered[0] + ordered[1]),
            salt: Data("skybridge-classic-file-transfer-v1".utf8), info: Data(rawTransferID.utf8), outputByteCount: 32))
    }
    private func keyBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
    private func assertChannelError(_ expected: AudioStreamingChannelError,
        file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AudioStreamingChannelError, expected, file: file, line: line) }
    }
    private func waitUntil(timeout: Duration = .seconds(2), condition: () -> Bool) async throws {
        let clock = ContinuousClock(); let end = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= end { throw FixtureFailure.waitTimedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private enum FixtureFailure: Error, Equatable { case denied, badFrame, waitTimedOut }

    @MainActor
    private final class AdmissionState {
        var value: IOSAudioAdmission
        init(generation: UUID) {
            value = IOSAudioAdmission(generation: generation, deviceID: "audio-peer-native-0002")
        }
    }
    @MainActor
    private final class AdmissionGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var isWaiting = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
        }
        func release() {
            released = true
            let pending = continuation; continuation = nil
            pending?.resume()
        }
    }

    @MainActor
    private final class Fixture {
        nonisolated static let endpoint: NWEndpoint? = .hostPort(host: "192.0.2.20", port: 8080)
        let generation: UUID
        let keys: NativeSessionKeys
        let localIdentity: ProtocolIdentityBinding
        let peer: IOSAudioPeerSnapshot
        let connection: ConnectionState
        let transport: Transport
        let session: IOSAudioSession

        init(capabilities: Set<String> = [AudioStreamingWire.captureReceiveCapability, AudioStreamingWire.fileReceiveCapability, "classic_approval_v1"],
             filePort: UInt16? = 8080, endpoint: NWEndpoint? = Fixture.endpoint,
             generation: UUID = UUID(), keys: NativeSessionKeys? = nil, history: IOSAudioSession.StreamHistory? = nil,
             usbReturn: Bool = false) throws {
            self.generation = generation
            let selected = keys ?? NativeSessionKeys(sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32),
                negotiatedSuite: .qperiaptABI2PolicyBound, role: .initiator, transcriptHash: Data(repeating: 3, count: 32))
            self.keys = selected
            let local = try ProtocolIdentityBinding(deviceId: "audio-local-native-0001", protocolSigningAlgorithm: .ed25519,
                                                    protocolPublicKeyBytes: Data(repeating: 0x12, count: 32))
            localIdentity = local
            let approved = IOSAudioPeerSnapshot(generation: generation, sessionID: selected.sessionId,
                identity: try AudioProtocolIdentity(deviceID: "audio-peer-native-0002", algorithm: .ed25519,
                    fingerprint: String(repeating: "ab", count: 32)), capabilities: capabilities,
                filePort: filePort, acceptedMaterialDigest: Data(repeating: 0x34, count: 32))
            peer = approved
            let connection = ConnectionState(), transport = Transport()
            self.connection = connection; self.transport = transport
            let cancellation = transport.cancellations
            session = try IOSAudioSession(generation: generation, keys: selected, localIdentity: local, peer: approved,
                fileRoute: usbReturn ? .usbReturn : endpoint.map(IOSAudioFileRoute.network), history: history,
                requireConnection: { if !connection.current { throw AudioStreamingChannelError.staleOwner } },
                sendFrame: { frame, completion in transport.enqueue(frame, completion: completion) },
                cancelTransport: { cancellation.increment() })
        }
        func open() throws -> IOSAudioChannel { try session.open(requiringFingerprint: peer.identity.fingerprint) }
        func shutdown() {
            session.invalidate()
            // Finish the controlled actual I/O even if a test failed early, so no
            // five-second watchdog is left alive after this fixture is released.
            for completion in transport.completions { completion.completeWrite(.success(())) }
        }
    }
    @MainActor
    private final class ConnectionState { var current = true }
    @MainActor
    private final class Transport {
        var automaticallyCompletes = true
        var frames: [Data] = []
        var completions: [AudioStreamingSendCompletion] = []
        let cancellations = IOSAudioCancellationCounter()
        func enqueue(_ frame: Data, completion: AudioStreamingSendCompletion) {
            frames.append(frame); completions.append(completion)
            if automaticallyCompletes { completion.completeWrite(.success(())) }
        }
    }
}

private final class IOSAudioCancellationCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}
