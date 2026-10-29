import XCTest
import Foundation
import CryptoKit
import Network
import os
import struct SkyBridgeProtocolCore.AudioProtocolIdentity
import struct SkyBridgeProtocolCore.AudioStreamingMessage
import struct SkyBridgeProtocolCore.ProtocolIdentityBinding
import struct SkyBridgeProtocolCore.ClassicTransferApprovalRequest
import enum SkyBridgeProtocolCore.AudioStreamingWire
import enum SkyBridgeProtocolCore.AudioStreamingLANEnvelope
import enum SkyBridgeProtocolCore.P2PControlFramePolicy
import enum SkyBridgeProtocolCore.ClassicTransferApprovalContract
import enum SkyBridgeProtocolCore.ClassicTransferCanonicalTranscript
import enum SkyBridgeProtocolCore.ClassicTransferAuthenticationContract
import enum SkyBridgeProtocolCore.ClassicTransferInboundPolicy
@testable import SkyBridgeCompass_iOS

/// The classic file connection is real loopback TCP, including wire framing,
/// metadata HMAC, chunk AEAD and receipt HMAC. MAIN keys, the accepted peer and
/// account authorization are explicit controlled inputs: this is not a handshake,
/// account-service, device interoperability, or native audio playback test.
@available(iOS 17.0, *)
@MainActor
final class IOSAudioFileTransferTests: XCTestCase {
    func testALACMetadataAndOriginalBytesCrossRealTCPForNetworkAndUSBReturnRoutes() async throws {
        let bytes = try IOSAudioALACFixture.data()
        for usbReturn in [false, true] {
            try await withFixture(mode: .receipt(validMAC: true), usbReturn: usbReturn, alacBytes: bytes) { fixture in
                let content = try await fixture.prepareAndOffer()
                XCTAssertEqual(content.mimeType, "audio/mp4")
                XCTAssertEqual(content.format.sampleRate, 48_000)
                XCTAssertEqual(content.format.declaredValidBits, 24)
                fixture.startSending()
                let receipt = try await fixture.senderResult()
                let report = try await fixture.server.result()
                XCTAssertEqual(report.bytes, bytes)
                XCTAssertTrue(report.metadataMACVerified && report.receiptSent && report.peerClosed)
                try assertReceiptMAC(receipt, key: fixture.server.key)
                XCTAssertEqual(fixture.mainCancellations.count, 0)
                await fixture.assertResourcesClosed()
            }
        }
    }

    func testUSBReturnRoutePublishesOnePortAndPreservesOriginalBytesOverHostInitiatedTCP() async throws {
        try await withFixture(mode: .receipt(validMAC: true), usbReturn: true) { fixture in
            _ = try await fixture.prepareAndOffer()
            fixture.startSending()
            let receipt = try await fixture.senderResult()
            let report = try await fixture.server.result()
            XCTAssertEqual(report.bytes, fixture.wave)
            XCTAssertTrue(report.metadataMACVerified && report.receiptSent && report.peerClosed)
            try assertReceiptMAC(receipt, key: fixture.server.key)
            XCTAssertEqual(fixture.server.returnPorts.count, 1)
            XCTAssertEqual(fixture.server.acceptedConnections, 0, "USB selection must not use the old network listener")
            XCTAssertEqual(fixture.mainFrames.count, 2)
            XCTAssertEqual(fixture.mainCancellations.count, 0)
            await fixture.assertResourcesClosed()
        }
    }

    func testUSBReturnCancellationBeforeFileApprovalClosesListenerAndFileConnection() async throws {
        try await withFixture(mode: .withholdApproval, usbReturn: true) { fixture in
            _ = try await fixture.prepareAndOffer()
            fixture.startSending()
            try await fixture.server.waitForAuthenticatedMetadata()
            fixture.cancelSender()
            do { _ = try await fixture.senderResult(); XCTFail("Cancelled return stream succeeded") }
            catch is CancellationError { XCTAssertTrue(fixture.progressBytes.isEmpty) }
            catch FileTransferError.transferCancelled { XCTAssertTrue(fixture.progressBytes.isEmpty) }
            XCTAssertTrue(fixture.senderFinished)
            let report = try await fixture.server.result()
            XCTAssertTrue(report.bytes.isEmpty && report.peerClosed)
            XCTAssertEqual(fixture.server.returnPorts.count, 1)
            XCTAssertEqual(fixture.server.acceptedConnections, 0)
            await fixture.assertResourcesClosed()
            XCTAssertEqual(fixture.mainCancellations.count, 0)
        }
    }

    func testUSBReturnListenerCanCloseBeforeAnyPeerConnectsAndReleasesSlotOnce() async throws {
        let owner = IOSAudioFileConnection(), releases = IOSAudioFileTestCounter()
        try owner.holdTransferSlot { releases.increment() }
        let port = try await owner.prepareUSBReturnListener(requireAuthorization: {})
        XCTAssertGreaterThan(port, 0)
        try await owner.close(); try await owner.close()
        XCTAssertTrue(owner.isClosed); XCTAssertEqual(releases.count, 1)
    }

    func testOriginalFileSessionJoinsRealTCPReceiptWithSeparateNativePlaybackReports() async throws {
        try await withFixture(mode: .receipt(validMAC: true)) { fixture in
            let channel = try fixture.requireChannel()
            let sender = IOSOriginalFileSendSession(renewMembership: nil, source: fixture.source, channel: channel,
                connection: fixture.fileOwner, authorize: { try makeControlledAudioMembershipLease(channel: $0) })
            let operation = Task { try await sender.run() }
            let watchdog = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(10)) }
                catch is CancellationError { return }
                catch { XCTFail("Session watchdog failed: \(error)") }
                XCTFail("Original-file session exceeded the test deadline"); sender.stop()
            }
            defer { watchdog.cancel() }
            do {
                try await waitFor { fixture.mainFrames.count == 1 }
                let session = try fixture.requireSession()
                XCTAssertEqual(try session.receive(.init(streamID: sender.streamID, body: .accept(receiveWindowBytes: 0))), .delivered)
                try await fixture.server.waitForAuthenticatedMetadata()
                let report = try await fixture.server.result()
                XCTAssertEqual(report.bytes, fixture.wave)
                XCTAssertTrue(report.receiptSent); XCTAssertTrue(report.peerClosed)
                try await waitFor { sender.phase == .awaitingOutput }
                XCTAssertNil(sender.receipt, "Real classic success is not playback completion")
                let format = try XCTUnwrap(sender.sourceFormat)
                XCTAssertEqual(try session.receive(.init(streamID: sender.streamID, body: .outputReady(format))), .delivered)
                XCTAssertEqual(try session.receive(.init(streamID: sender.streamID,
                    body: .playbackComplete(sourceFrames: UInt64((fixture.wave.count - 44) / Int(format.bytesPerFrame)),
                                            trailingPaddingFrames: 0))), .delivered)
                let receipt = try await operation.value
                try assertReceiptMAC(receipt.file, key: fixture.server.key)
                XCTAssertEqual(receipt.file.receivedBytes, Int64(fixture.wave.count))
                XCTAssertEqual(sender.phase, .completed)
                await fixture.assertResourcesClosed()
                XCTAssertEqual(fixture.mainCancellations.count, 0)
            } catch {
                sender.stop(); _ = await operation.result
                throw error
            }
        }
    }

    func testOriginalWaveCrossesMoreThanTwoTCPChunksAndRequiresSignedReceipt() async throws {
        try await withFixture(mode: .receipt(validMAC: true)) { fixture in
            let content = try await fixture.prepareAndOffer()
            let channel = try fixture.requireChannel()
            fixture.startSending()
            let receipt = try await fixture.senderResult()
            let received = try await fixture.server.result()

            XCTAssertEqual(received.bytes, fixture.wave)
            XCTAssertEqual(received.chunkSizes, [65_536, 65_536, 65_536, fixture.wave.count - 196_608])
            XCTAssertTrue(received.metadataMACVerified)
            XCTAssertTrue(received.completeReceived)
            XCTAssertTrue(received.receiptSent)
            XCTAssertTrue(received.peerClosed)
            XCTAssertEqual(fixture.progressBytes, [65_536, 131_072, 196_608, Int64(fixture.wave.count)])
            XCTAssertEqual(receipt.transferId, content.transferID)
            XCTAssertEqual(receipt.receivedBytes, content.length)
            XCTAssertEqual(receipt.fileHash, hex(content.digest))
            XCTAssertTrue(receipt.success)
            try assertReceiptMAC(receipt, key: fixture.server.key)
            await fixture.assertResourcesClosed()
            try channel.requireCurrent()
            XCTAssertEqual(fixture.mainCancellations.count, 0)
            XCTAssertEqual(fixture.mainFrames.count, 1, "File receipt must not synthesize playbackComplete on MAIN")
        }
    }

    func testWrongReceiptMACCannotReturnSuccessfulTransfer() async throws {
        try await withFixture(mode: .receipt(validMAC: false)) { fixture in
            _ = try await fixture.prepareAndOffer()
            fixture.startSending()
            do {
                _ = try await fixture.senderResult()
                XCTFail("Unauthenticated receipt was accepted")
            } catch FileTransferError.receiptWaitFailed(let stage, _) {
                XCTAssertEqual(stage, .authFailed)
            }
            let received = try await fixture.server.result()
            XCTAssertEqual(received.bytes, fixture.wave)
            XCTAssertTrue(received.completeReceived)
            XCTAssertTrue(received.receiptSent)
            XCTAssertTrue(received.peerClosed)
            await fixture.assertResourcesClosed()
            try fixture.requireChannel().requireCurrent()
            XCTAssertEqual(fixture.mainCancellations.count, 0)
        }
    }

    func testAuthorizationRevokedInFirstProgressPreventsEveryLaterChunkAndKeepsMain() async throws {
        try await withFixture(mode: .receiveUntilClose) { fixture in
            _ = try await fixture.prepareAndOffer()
            fixture.revokeAtFirstProgress = true
            fixture.startSending()
            do {
                _ = try await fixture.senderResult()
                XCTFail("Revoked transfer returned success")
            } catch let error as IOSAudioFileTestFailure {
                XCTAssertEqual(error, .authorizationRevoked)
            }
            let received = try await fixture.server.result()
            XCTAssertTrue(received.metadataMACVerified)
            XCTAssertEqual(received.chunkSizes, [65_536])
            XCTAssertEqual(received.bytes, Data(fixture.wave.prefix(65_536)))
            XCTAssertEqual(fixture.progressBytes, [65_536])
            XCTAssertFalse(received.completeReceived)
            XCTAssertFalse(received.receiptSent)
            XCTAssertTrue(received.peerClosed)
            await fixture.assertResourcesClosed()
            try fixture.requireChannel().requireCurrent()
            XCTAssertEqual(fixture.mainCancellations.count, 0)
        }
    }

    func testSameOfferUUIDWithDifferentLengthOrDigestIsRejectedBeforeFileConnection() async throws {
        for mismatch in [OfferMismatch.length, .digest] {
            try await withFixture(mode: .receiveUntilClose) { fixture in
                let content = try await fixture.prepareAndOffer(mismatch: mismatch)
                let authority = try fixture.requireChannel().classicFileAuthority(transferID: content.transferID)
                // The UUID matches; the differing content binding is the only rejection trigger.
                XCTAssertEqual(UUID(uuidString: content.transferID), fixture.transferID)
                switch mismatch {
                case .length: XCTAssertNotEqual(authority.offeredLength, UInt64(content.length))
                case .digest: XCTAssertNotEqual(authority.offeredSHA256, content.digest)
                }
                fixture.startSending()
                do {
                    _ = try await fixture.senderResult()
                    XCTFail("Mismatching offered file was accepted")
                } catch FileTransferError.invalidMetadata {
                    XCTAssertTrue(fixture.progressBytes.isEmpty)
                }
                // Finish the listener and observe its terminal state before checking
                // admission. No production connection may have reached this listener.
                try await fixture.server.stopListening()
                XCTAssertEqual(fixture.server.acceptedConnections, 0)
                XCTAssertFalse(fixture.server.hasConnection)
                await fixture.assertResourcesClosed()
                try fixture.requireChannel().requireCurrent()
                XCTAssertEqual(fixture.mainCancellations.count, 0)
            }
        }
    }

    func testCancellationAfterMetadataWhileClassicApprovalIsWithheldClosesFileResourcesOnly() async throws {
        try await withFixture(mode: .withholdApproval) { fixture in
            _ = try await fixture.prepareAndOffer()
            fixture.startSending()
            try await fixture.server.waitForAuthenticatedMetadata()
            // This observes the real peer's metadata receive. It does not claim
            // to instrument when the sender's native approval receive is armed.
            XCTAssertFalse(fixture.senderFinished)
            fixture.cancelSender()
            do {
                _ = try await fixture.senderResult()
                XCTFail("Cancelled approval wait returned success")
            } catch is CancellationError {
                // Cancellation may be observed by the source/authorization boundary.
                XCTAssertTrue(fixture.progressBytes.isEmpty)
            } catch FileTransferError.transferCancelled {
                // The classic receive operation maps its cancellation to this type.
                XCTAssertTrue(fixture.progressBytes.isEmpty)
            }
            let received = try await fixture.server.result()
            XCTAssertTrue(received.metadataMACVerified)
            XCTAssertTrue(received.peerClosed)
            XCTAssertTrue(received.bytes.isEmpty)
            XCTAssertTrue(received.chunkSizes.isEmpty)
            XCTAssertFalse(received.completeReceived)
            XCTAssertFalse(received.receiptSent)
            XCTAssertTrue(fixture.progressBytes.isEmpty)
            await fixture.assertResourcesClosed()
            try fixture.requireChannel().requireCurrent()
            XCTAssertEqual(fixture.mainCancellations.count, 0)
        }
    }

    func testCloseWithoutObservedNativeCancellationRetainsOwnerUntilActualReceiptIsForwarded() async throws {
        try await withFixture(mode: .connectionOnly) { fixture in
            let owner = IOSAudioFileConnection()
            let connection = NWConnection(to: try fixture.server.endpoint(), using: .tcp)
            fixture.ownAuxiliaryConnection(connection, owner: owner)
            var slotReleases = 0
            try owner.holdTransferSlot { slotReleases += 1 }
            try owner.attach(connection)
            // Deliberately withhold forwarding the native state to the owner.
            // The later receipt comes from connection.state, not a fabricated state.
            connection.start(queue: .main)
            try await waitFor { if case .ready = connection.state { true } else { false } }
            do {
                try await owner.close()
                XCTFail("close succeeded without observing native cancellation")
            } catch let error as IOSAudioFileConnectionError {
                XCTAssertEqual(error, .closeUnconfirmed)
            }
            XCTAssertFalse(owner.isClosed)
            XCTAssertEqual(slotReleases, 0, "An unconfirmed close must keep the global transfer slot")
            XCTAssertThrowsError(try owner.attach(connection)) {
                XCTAssertEqual($0 as? IOSAudioFileConnectionError, .closed)
            }
            try await waitFor { if case .cancelled = connection.state { true } else { false } }
            owner.observe(connection.state)
            try await owner.close()
            XCTAssertTrue(owner.isClosed)
            XCTAssertEqual(slotReleases, 1)
            owner.observe(connection.state)
            try await owner.close()
            XCTAssertEqual(slotReleases, 1, "Duplicate terminal observation cannot release another owner's slot")
            let received = try await fixture.server.result()
            XCTAssertTrue(received.peerClosed)
            XCTAssertTrue(received.bytes.isEmpty)
        }
    }

    func testRepeatedSourceOrConnectionOwnerCannotCloseFirstTransferAwaitingApproval() async throws {
        // This overlap requires two slots. Do not modify persisted settings or
        // silently skip when the test host was configured with a single slot.
        guard SettingsManager.instance.fileTransferMaxConcurrentTransfers >= 2 else {
            throw IOSAudioFileTestFailure.unsuitableTransferSettings
        }
        try await withFixture(mode: .withholdApproval) { fixture in
            let content = try await fixture.prepareAndOffer()
            fixture.startSending()
            try await fixture.server.waitForAuthenticatedMetadata()
            let channel = try fixture.requireChannel()
            let secondOwner = IOSAudioFileConnection()
            do {
                _ = try await fixture.attemptSendingAgain(connectionOwner: secondOwner)
                XCTFail("Source was claimed twice")
            } catch let error as IOSPreparedAudioFileError {
                XCTAssertEqual(error, .alreadyClaimed)
            }
            XCTAssertTrue(secondOwner.isClosed)
            XCTAssertFalse(fixture.fileOwner.isClosed)
            XCTAssertFalse(fixture.senderFinished)
            XCTAssertTrue(fixture.server.isConnectionReady)
            let closedBeforeCancel = await fixture.source.isClosed
            XCTAssertFalse(closedBeforeCancel)
            let firstRead = try await content.reader.read(offset: 0, length: 44)
            XCTAssertEqual(firstRead, Data(fixture.wave.prefix(44)))
            XCTAssertEqual(fixture.scope.counts.stopped, 0)

            do {
                _ = try await fixture.attemptSendingAgain(connectionOwner: fixture.fileOwner)
                XCTFail("Connection owner was acquired twice")
            } catch let error as IOSAudioFileConnectionError {
                XCTAssertEqual(error, .closed)
            }
            XCTAssertFalse(fixture.fileOwner.isClosed)
            XCTAssertFalse(fixture.senderFinished)
            XCTAssertTrue(fixture.server.isConnectionReady)
            let secondRead = try await content.reader.read(offset: 44, length: 16)
            XCTAssertEqual(secondRead, fixture.wave.subdata(in: 44..<60))
            XCTAssertEqual(fixture.scope.counts.stopped, 0)
            XCTAssertEqual(fixture.server.acceptedConnections, 1)

            fixture.cancelSender()
            do {
                _ = try await fixture.senderResult()
                XCTFail("Cancelled original transfer returned success")
            } catch is CancellationError {
                XCTAssertTrue(fixture.server.authenticatedMetadataReceived)
            } catch FileTransferError.transferCancelled {
                XCTAssertTrue(fixture.progressBytes.isEmpty)
            }
            let received = try await fixture.server.result()
            XCTAssertTrue(received.peerClosed)
            XCTAssertTrue(received.bytes.isEmpty)
            XCTAssertFalse(received.completeReceived)
            await fixture.assertResourcesClosed()
            try channel.requireCurrent()
            XCTAssertEqual(fixture.mainCancellations.count, 0)
        }
    }

    private enum OfferMismatch: Equatable { case length, digest }

    private func withFixture(mode: IOSAudioFileTCPServer.Mode, usbReturn: Bool = false, alacBytes: Data? = nil,
                             body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(mode: mode, alacBytes: alacBytes)
        do {
            try await fixture.start(usbReturn: usbReturn)
            try await body(fixture)
            try await fixture.shutdown()
        } catch {
            let primary = error
            do { try await fixture.shutdown() }
            catch { XCTFail("Fixture cleanup failed in addition to test error: \(error)") }
            throw primary
        }
    }

    private func assertReceiptMAC(_ receipt: TransferReceipt, key: SymmetricKey) throws {
        let transcript = try ClassicTransferCanonicalTranscript.receipt(transferID: receipt.transferId,
            success: receipt.success, receivedBytes: receipt.receivedBytes, fileHash: receipt.fileHash,
            error: receipt.error, securityVersion: receipt.securityVersion ?? 0)
        XCTAssertTrue(ClassicTransferAuthenticationContract.isValidHMACSHA256(receipt.authTag,
            authenticating: transcript, using: key))
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let transferID = UUID()
        let wave: Data
        let source: IOSPreparedAudioFile
        let fileOwner = IOSAudioFileConnection()
        let scope: IOSAudioFileTestScope
        let mainCancellations = IOSAudioFileTestCounter()
        let server: IOSAudioFileTCPServer
        private let keys: SkyBridgeCompass_iOS.SessionKeys
        private var session: IOSAudioSession?
        private var channel: IOSAudioChannel?
        private var sending: Task<TransferReceipt, Error>?
        private var additionalSends: [Task<TransferReceipt, Error>] = []
        private var additionalOwners: [IOSAudioFileConnection] = []
        private var auxiliaryConnections: [(NWConnection, IOSAudioFileConnection)] = []
        private var removedStorage = false
        private(set) var mainFrames: [Data] = []
        private(set) var progressBytes: [Int64] = []
        private(set) var senderFinished = false
        var revokeAtFirstProgress = false
        private var authorized = true

        init(mode: IOSAudioFileTCPServer.Mode, alacBytes: Data? = nil) throws {
            let scope = IOSAudioFileTestScope()
            self.scope = scope
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-audio-file-\(UUID())", isDirectory: true)
            wave = alacBytes ?? makeWave()
            let fileName = alacBytes == nil ? "original.wav" : "original.m4a"
            let mimeType = alacBytes == nil ? "audio/wav" : "audio/mp4"
            keys = SkyBridgeCompass_iOS.SessionKeys(sendKey: Data(repeating: 0x21, count: 32),
                receiveKey: Data(repeating: 0x43, count: 32), negotiatedSuite: .qperiaptABI2PolicyBound,
                role: .initiator, transcriptHash: Data(repeating: 0x65, count: 32))
            let material = SkyBridgeCompass_iOS.P2PConnectionManager.ClassicFileTransferKeyMaterial(
                sessionKeys: keys, transferId: transferID.uuidString, connectionGeneration: UUID(), approvalCapability: true)
            server = try IOSAudioFileTCPServer(mode: mode, expected: wave, transferID: transferID.uuidString,
                                               key: material.transferKey, expectedFileName: fileName, expectedMIME: mimeType)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let url = directory.appendingPathComponent(fileName)
            do {
                try wave.write(to: url)
                source = try IOSPreparedAudioFile(url: url, transferID: transferID.uuidString,
                    startScope: { _ in scope.start(); return true }, stopScope: { _ in scope.stop() })
            } catch {
                try FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func start(usbReturn: Bool = false) async throws {
            try await server.start()
            let generation = UUID(), endpoint = try server.endpoint()
            let local = try ProtocolIdentityBinding(deviceId: "audio-file-ios-fixture-local", protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyBytes: Data(repeating: 0x12, count: 32))
            let peer = IOSAudioPeerSnapshot(generation: generation, sessionID: keys.sessionId,
                identity: try AudioProtocolIdentity(deviceID: "audio-file-ios-fixture-peer", algorithm: .ed25519,
                    fingerprint: String(repeating: "ab", count: 32)),
                capabilities: Set([AudioStreamingWire.fileReceiveCapability, "classic_approval_v1"] +
                    (usbReturn ? [AudioStreamingWire.usbFileReceiveCapability] : [])),
                filePort: try XCTUnwrap(server.listener.port).rawValue,
                acceptedMaterialDigest: Data(repeating: 0x34, count: 32))
            let cancellations = mainCancellations
            let session = try IOSAudioSession(generation: generation, keys: keys, localIdentity: local, peer: peer,
                fileRoute: usbReturn ? .usbReturn : .network(endpoint), requireConnection: {}, sendFrame: { [weak self] frame, completion in
                    guard let self else { completion.completeWrite(.failure(IOSAudioFileTestFailure.invalidFrame)); return }
                    self.mainFrames.append(frame)
                    do {
                        if usbReturn {
                            guard frame.count >= 4 else { throw IOSAudioFileTestFailure.invalidFrame }
                            let count = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                            guard try P2PControlFramePolicy.inboundBodyByteCount(from: count) == frame.count - 4 else {
                                throw IOSAudioFileTestFailure.invalidFrame
                            }
                            let ciphertext = try SkyBridgeCompass_iOS.TrafficPadding.unwrapIfNeeded(Data(frame.dropFirst(4)),
                                label: "usb-file-test", maximumOutputByteCount: P2PControlFramePolicy.maximumBodyByteCount)
                            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: SymmetricKey(data: self.keys.sendKey))
                            let message = try XCTUnwrap(AudioStreamingLANEnvelope.decodeIfPresent(plaintext))
                            if case .usbFileRoute(let port) = message.body { try self.server.connectToReturnPort(port) }
                        }
                        completion.completeWrite(.success(()))
                    } catch { completion.completeWrite(.failure(error)) }
                }, cancelTransport: { cancellations.increment() })
            self.session = session
            channel = try session.open(requiringFingerprint: peer.identity.fingerprint)
        }

        func requireChannel() throws -> IOSAudioChannel { try XCTUnwrap(channel) }
        func requireSession() throws -> IOSAudioSession { try XCTUnwrap(session) }

        func prepareAndOffer(mismatch: OfferMismatch? = nil) async throws -> IOSPreparedAudioFile.Content {
            let content = try await source.prepare()
            let length = UInt64(content.length) + (mismatch == .length ? 4 : 0)
            var digest = content.digest
            if mismatch == .digest { digest[0] ^= 1 }
            let streamID = UUID()
            let channel = try requireChannel()
            try await channel.send(.init(streamID: streamID, body: .fileOffer(
                transferID: transferID, length: length, sha256: digest)), requireEffectAuthorization: { [self] in
                    try requireAuthorization()
                })
            // The MAIN accept is controlled; only the subsequent classic connection
            // traverses TCP in these tests. Consume it through the actual mailbox.
            let accept = AudioStreamingMessage(streamID: streamID, body: .accept(receiveWindowBytes: 0))
            XCTAssertEqual(try XCTUnwrap(session).receive(accept), .delivered)
            var replies = channel.messages.makeAsyncIterator()
            let accepted = try await replies.next()
            XCTAssertEqual(accepted, accept)
            return content
        }

        func startSending() {
            precondition(sending == nil)
            sending = Task { @MainActor [self] in
                defer { senderFinished = true }
                return try await FileTransferManager.instance.sendPreparedAudioFile(source,
                    channel: requireChannel(), connectionOwner: fileOwner,
                    requireEffectAuthorization: { [self] in try requireAuthorization() },
                    progress: { [self] transferred, total in
                        XCTAssertEqual(total, Int64(wave.count))
                        progressBytes.append(transferred)
                        if revokeAtFirstProgress { authorized = false }
                    })
            }
        }

        func requireAuthorization() throws {
            guard authorized else { throw IOSAudioFileTestFailure.authorizationRevoked }
        }
        func cancelSender() { sending?.cancel() }
        func senderResult() async throws -> TransferReceipt { try await XCTUnwrap(sending).value }

        func attemptSendingAgain(connectionOwner: IOSAudioFileConnection) async throws -> TransferReceipt {
            additionalOwners.append(connectionOwner)
            let task = Task { @MainActor [self] in
                try await FileTransferManager.instance.sendPreparedAudioFile(source,
                    channel: requireChannel(), connectionOwner: connectionOwner,
                    requireEffectAuthorization: { [self] in try requireAuthorization() },
                    progress: { _, _ in XCTFail("Rejected repeated send submitted file bytes") })
            }
            additionalSends.append(task)
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(4)) }
                catch is CancellationError { return }
                catch { XCTFail("Repeated-send watchdog failed: \(error)"); task.cancel(); return }
                XCTFail("Repeated send exceeded bounded rejection wait")
                task.cancel()
            }
            defer { timeout.cancel() }
            return try await task.value
        }

        func ownAuxiliaryConnection(_ connection: NWConnection, owner: IOSAudioFileConnection) {
            auxiliaryConnections.append((connection, owner))
        }

        func assertResourcesClosed(file: StaticString = #filePath, line: UInt = #line) async {
            XCTAssertTrue(fileOwner.isClosed, file: file, line: line)
            let closed = await source.isClosed
            XCTAssertTrue(closed, file: file, line: line)
            XCTAssertEqual(scope.counts.started, 1, file: file, line: line)
            XCTAssertEqual(scope.counts.stopped, 1, file: file, line: line)
        }

        func shutdown() async throws {
            // Cancel both ends before joining either task. Every test owns its
            // accepted socket, source, stream and actual receiving task.
            sending?.cancel(); additionalSends.forEach { $0.cancel() }; server.cancel()
            auxiliaryConnections.forEach { $0.0.cancel() }
            if let sending { _ = await sending.result }
            for task in additionalSends { _ = await task.result }
            var failures: [String] = []
            do { try await fileOwner.close() } catch { failures.append("file connection: \(error)") }
            for owner in additionalOwners {
                do { try await owner.close() } catch { failures.append("repeated-send connection: \(error)") }
            }
            do { try await source.close() } catch { failures.append("source: \(error)") }
            channel?.close(); session?.invalidate()
            for (connection, owner) in auxiliaryConnections {
                do {
                    try await waitFor { if case .cancelled = connection.state { true } else { false } }
                    owner.observe(connection.state)
                    try await owner.close()
                } catch { failures.append("auxiliary connection: \(error)") }
            }
            do { try await server.shutdown() } catch { failures.append("server: \(error)") }
            if failures.isEmpty, !removedStorage {
                try FileManager.default.removeItem(at: directory)
                removedStorage = true
            }
            guard failures.isEmpty else { throw IOSAudioFileTestFailure.cleanup(failures.joined(separator: "; ")) }
        }
    }
}

private enum IOSAudioFileTestFailure: Error, Equatable {
    case authorizationRevoked, timeout, invalidFrame, truncatedFrame, emptyRead, invalidMetadata
    case invalidChunk, unexpectedMessage, expectedPeerClose, unsuitableTransferSettings, cleanup(String)
}

@available(iOS 17.0, *)
@MainActor
private final class IOSAudioFileTCPServer {
    enum Mode { case receipt(validMAC: Bool), receiveUntilClose, withholdApproval, connectionOnly }
    struct Report {
        var bytes = Data()
        var chunkSizes: [Int] = []
        var metadataMACVerified = false
        var completeReceived = false
        var receiptSent = false
        var peerClosed = false
    }

    let listener: NWListener
    let key: SymmetricKey
    private let mode: Mode
    private let expected: Data
    private let expectedFileName: String
    private let expectedMIME: String
    private let transferID: String
    private var connection: NWConnection?
    private var receiving: Task<Report, Error>?
    private var ready = false
    private var listenerCancelled = false
    private var connectionCancelled = false
    private var stopping = false
    private(set) var acceptedConnections = 0
    private(set) var authenticatedMetadataReceived = false
    private(set) var returnPorts: [UInt16] = []
    var hasConnection: Bool { connection != nil }
    var isConnectionReady: Bool {
        guard let connection else { return false }
        if case .ready = connection.state { return true }
        return false
    }

    init(mode: Mode, expected: Data, transferID: String, key: SymmetricKey,
         expectedFileName: String = "original.wav", expectedMIME: String = "audio/wav") throws {
        self.mode = mode; self.expected = expected; self.transferID = transferID; self.key = key
        self.expectedFileName = expectedFileName; self.expectedMIME = expectedMIME
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready = true }
                if case .cancelled = state { self?.listenerCancelled = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.acceptedConnections += 1
                guard !self.stopping, self.connection == nil else { connection.cancel(); return }
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        if case .cancelled = state { self?.connectionCancelled = true }
                    }
                }
                connection.start(queue: .main)
                self.receiving = Task { @MainActor in try await self.receiveTransfer(over: connection) }
            }
        }
        listener.start(queue: .main)
        try await waitFor { self.ready }
    }

    func endpoint() throws -> NWEndpoint { .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)) }
    func connectToReturnPort(_ port: UInt16) throws {
        guard !stopping, connection == nil, returnPorts.isEmpty, let endpointPort = NWEndpoint.Port(rawValue: port), port > 0 else {
            throw IOSAudioFileTestFailure.invalidFrame
        }
        returnPorts.append(port)
        let value = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        connection = value
        value.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in if case .cancelled = state { self?.connectionCancelled = true } }
        }
        value.start(queue: .main)
        receiving = Task { @MainActor in try await self.receiveTransfer(over: value) }
    }
    func waitForAuthenticatedMetadata() async throws { try await waitFor { self.authenticatedMetadataReceived } }
    func result() async throws -> Report { try await XCTUnwrap(receiving).value }
    func cancel() { stopping = true; receiving?.cancel(); connection?.cancel(); listener.cancel() }

    func stopListening() async throws {
        stopping = true; listener.cancel()
        try await waitFor { self.listenerCancelled }
    }

    func shutdown() async throws {
        cancel()
        if let receiving { _ = await receiving.result }
        try await waitFor { self.listenerCancelled && (self.connection == nil || self.connectionCancelled) }
        listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
        connection?.stateUpdateHandler = nil
    }

    private func receiveTransfer(over connection: NWConnection) async throws -> Report {
        // This independent watchdog turns a missing close/receipt into a bounded
        // failure; it never contributes a successful peer-close observation.
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(12)) }
            catch is CancellationError { return }
            catch { XCTFail("Watchdog sleep failed: \(error)"); return }
            XCTFail("TCP fixture exceeded 12-second deadline; configured upload limit is \(SettingsManager.instance.fileTransferUploadLimitKBps) KB/s")
            connection.cancel()
        }
        defer { watchdog.cancel() }
        var report = Report()
        if case .connectionOnly = mode {
            guard try await read(1, from: connection, allowEOF: true) == nil else {
                throw IOSAudioFileTestFailure.unexpectedMessage
            }
            report.peerClosed = true
            return report
        }
        guard let (type, payload) = try await frame(from: connection), type == .metadata else {
            throw IOSAudioFileTestFailure.invalidMetadata
        }
        let metadata = try JSONDecoder().decode(FileMetadata.self, from: payload)
        let transcript = try metadataTranscript(metadata)
        guard metadata.transferId == transferID, metadata.fileSize == Int64(expected.count),
              metadata.fileHash == hex(Data(SHA256.hash(data: expected))), metadata.chunkSize == 65_536,
              metadata.fileName == expectedFileName, metadata.mimeType == expectedMIME,
              metadata.totalChunks == (expected.count + 65_535) / 65_536, metadata.resumeOffset == nil,
              metadata.securityVersion == ClassicTransferInboundPolicy.currentSecurityVersion,
              metadata.compression == nil, metadata.approvalProtocol == ClassicTransferApprovalContract.protocolIdentifier,
              metadata.senderDeviceId == "audio-file-ios-fixture-local",
              ClassicTransferAuthenticationContract.isValidHMACSHA256(metadata.metadataAuthTag,
                  authenticating: transcript, using: key) else { throw IOSAudioFileTestFailure.invalidMetadata }
        report.metadataMACVerified = true
        authenticatedMetadataReceived = true
        if case .withholdApproval = mode {
            if let _ = try await frame(from: connection) { throw IOSAudioFileTestFailure.unexpectedMessage }
            report.peerClosed = true
            return report
        }
        let request = try ClassicTransferApprovalRequest(transferID: transferID, authenticatedMetadataTranscript: transcript)
        let approval = try ClassicTransferApprovalContract.makeResponse(for: request, refusal: nil, using: key)
        try await send(.approval, payload: JSONEncoder().encode(approval), over: connection)

        while let (type, payload) = try await frame(from: connection) {
            switch type {
            case .chunk:
                guard !report.completeReceived else { throw IOSAudioFileTestFailure.unexpectedMessage }
                let chunk = try JSONDecoder().decode(FileChunk.self, from: payload)
                guard chunk.index == report.chunkSizes.count, chunk.size > 0, chunk.size <= 65_536,
                      report.bytes.count + chunk.size <= expected.count,
                      let nonce = chunk.nonce, let tag = chunk.authenticationTag else {
                    throw IOSAudioFileTestFailure.invalidChunk
                }
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: chunk.data, tag: tag)
                let plaintext = try AES.GCM.open(box, using: key)
                guard plaintext.count == chunk.size, chunk.checksum == hex(Data(SHA256.hash(data: plaintext))),
                      plaintext == expected.subdata(in: report.bytes.count..<(report.bytes.count + chunk.size)) else {
                    throw IOSAudioFileTestFailure.invalidChunk
                }
                report.bytes.append(plaintext); report.chunkSizes.append(chunk.size)
            case .complete:
                guard payload.isEmpty, !report.completeReceived, report.bytes == expected,
                      case .receipt(let validMAC) = mode else { throw IOSAudioFileTestFailure.unexpectedMessage }
                report.completeReceived = true
                let digest = hex(Data(SHA256.hash(data: report.bytes)))
                let input = try ClassicTransferCanonicalTranscript.receipt(transferID: transferID, success: true,
                    receivedBytes: Int64(report.bytes.count), fileHash: digest, error: nil,
                    securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion)
                var tag = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
                if !validMAC { tag[0] ^= 1 }
                let receipt = TransferReceipt(transferId: transferID, success: true,
                    receivedBytes: Int64(report.bytes.count), fileHash: digest,
                    securityVersion: ClassicTransferInboundPolicy.currentSecurityVersion, authTag: tag)
                try await send(.receipt, payload: JSONEncoder().encode(receipt), over: connection)
                report.receiptSent = true
            default: throw IOSAudioFileTestFailure.unexpectedMessage
            }
        }
        report.peerClosed = true
        if case .receipt = mode, !report.receiptSent { throw IOSAudioFileTestFailure.expectedPeerClose }
        return report
    }

    private func frame(from connection: NWConnection) async throws -> (TransferMessageType, Data)? {
        guard let header = try await read(8, from: connection, allowEOF: true) else { return nil }
        // Decode the two network-order integers independently of production's header decoder.
        let typeWord = header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let length = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= 2_000_000, let type = TransferMessageType(rawValue: typeWord), type != .unknown else {
            throw IOSAudioFileTestFailure.invalidFrame
        }
        let payload = try await read(Int(length), from: connection, allowEOF: false)
        return (type, try XCTUnwrap(payload))
    }

    private func read(_ count: Int, from connection: NWConnection, allowEOF: Bool) async throws -> Data? {
        var bytes = Data()
        while bytes.count < count {
            let remaining = count - bytes.count
            let part: Data? = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete { continuation.resume(returning: nil) }
                        else { continuation.resume(throwing: IOSAudioFileTestFailure.emptyRead) }
                    }
                }
            } onCancel: { connection.cancel() }
            guard let part else {
                if bytes.isEmpty, allowEOF { return nil }
                throw IOSAudioFileTestFailure.truncatedFrame
            }
            bytes.append(part)
        }
        return bytes
    }

    private func send(_ type: TransferMessageType, payload: Data, over connection: NWConnection) async throws {
        var bytes = Data()
        for word in [type.rawValue, UInt32(payload.count)] {
            bytes.append(contentsOf: withUnsafeBytes(of: word.bigEndian) { Array($0) })
        }
        bytes.append(payload)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }

    private func metadataTranscript(_ metadata: FileMetadata) throws -> Data {
        try ClassicTransferCanonicalTranscript.metadata(transferID: metadata.transferId, fileName: metadata.fileName,
            fileSize: metadata.fileSize, fileHash: metadata.fileHash, chunkSize: metadata.chunkSize,
            securityVersion: metadata.securityVersion ?? 0, compression: metadata.compression,
            senderDeviceID: metadata.senderDeviceId, senderDeviceName: metadata.senderDeviceName,
            senderPlatform: metadata.senderPlatform, senderOSVersion: metadata.senderOSVersion,
            senderModelName: metadata.senderModelName, senderChip: metadata.senderChip,
            approvalProtocol: metadata.approvalProtocol)
    }
}

private final class IOSAudioFileTestCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

private final class IOSAudioFileTestScope: Sendable {
    struct Counts: Sendable { var started = 0; var stopped = 0 }
    private let value = OSAllocatedUnfairLock(initialState: Counts())
    var counts: Counts { value.withLock { $0 } }
    func start() { value.withLock { $0.started += 1 } }
    func stop() { value.withLock { $0.stopped += 1 } }
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw IOSAudioFileTestFailure.timeout }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

private func makeWave() -> Data {
    let pcm = Data((0..<(3 * 65_536 + 100)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
    var bytes = Data("RIFF".utf8)
    func word<T: FixedWidthInteger>(_ value: T) { bytes.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) }) }
    word(UInt32(36 + pcm.count)); bytes.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
    word(UInt16(1)); word(UInt16(2)); word(UInt32(44_100)); word(UInt32(176_400))
    word(UInt16(4)); word(UInt16(16)); bytes.append(Data("data".utf8)); word(UInt32(pcm.count))
    bytes.append(pcm)
    return bytes
}
