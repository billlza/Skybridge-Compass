import XCTest
import AVFoundation
import Network
@testable import SkyBridgeCore
import SkyBridgeOpus
import SkyBridgeRealtimeMedia

final class SkyBridgeRealtimeMediaTests: XCTestCase {
    @available(macOS 14.0, *)
    func testRealtimeAudioSenderOwnershipRejectsRetiredSenderTerminalLease() {
        var ownership = RemoteControlRealtimeAudioSenderOwnership()
        let first = ownership.reserve()
        XCTAssertEqual(ownership.currentLease, first)
        XCTAssertTrue(ownership.isCurrent(first))

        let replacement = ownership.reserve()
        XCTAssertEqual(ownership.currentLease, replacement)
        XCTAssertFalse(ownership.isCurrent(first))
        XCTAssertTrue(ownership.isCurrent(replacement))

        ownership.invalidate()
        XCTAssertNil(ownership.currentLease)
        XCTAssertFalse(ownership.isCurrent(first))
        XCTAssertFalse(ownership.isCurrent(replacement))
    }

    @available(macOS 14.0, *)
    func testRealtimeAudioSenderPublishesPendingLeaseAndRejectsStaleExistingSender() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"
            ),
            encoding: .utf8
        )
        let makeBody = try XCTUnwrap(
            source.range(of: "private func makeP2PRealtimeAudioSenderIfNeeded(")
        )
        let detachBody = try XCTUnwrap(
            source.range(
                of: "private func detachRealtimeAudioSender(",
                range: makeBody.upperBound..<source.endIndex
            )
        )
        let slice = String(source[makeBody.lowerBound..<detachBody.lowerBound])

        let exactExistingGuard = try XCTUnwrap(
            slice.range(of: "peer.realtimeAudioSender === existingSender")
        )
        let staleFailure = try XCTUnwrap(
            slice.range(
                of: "throw CancellationError()",
                range: exactExistingGuard.upperBound..<slice.endIndex
            )
        )
        let reserve = try XCTUnwrap(
            slice.range(
                of: "let senderLease = peer.realtimeAudioSenderOwnership.reserve()",
                range: staleFailure.upperBound..<slice.endIndex
            )
        )
        let firstAwaitAfterReserve = try XCTUnwrap(
            slice.range(
                of: "await senderToClose.close",
                range: reserve.upperBound..<slice.endIndex
            )
        )
        XCTAssertLessThan(exactExistingGuard.lowerBound, staleFailure.lowerBound)
        XCTAssertLessThan(staleFailure.lowerBound, reserve.lowerBound)
        XCTAssertLessThan(reserve.lowerBound, firstAwaitAfterReserve.lowerBound)
        XCTAssertTrue(source.contains("let sender = peer.realtimeAudioSender\n        if let expectedSender"))
        XCTAssertTrue(source.contains("peer.realtimeAudioSenderOwnership.invalidate()"))
        XCTAssertTrue(source.contains("owner: .screenSharingAttempt(attemptGeneration)"))
        XCTAssertTrue(source.contains("owner: .realtimeAudioSender(senderLease)"))
    }
    private func remoteControlSource(root: URL) throws -> String {
        let pumpSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlOutboundFramePump.swift"),
            encoding: .utf8
        )
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"),
            encoding: .utf8
        )
        let videoSubmissionPipeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlEncodedFrameSubmissionPipe.swift"),
            encoding: .utf8
        )
        return [pumpSource, managerSource, videoSubmissionPipeSource].joined(separator: "\n")
    }

    func testRetiredPlaybackOwnerCannotReclaimOrReleaseReplacement() async {
        let ownership = SkyBridgeRealtimeMediaPlaybackOwnership()
        let firstOwner = SkyBridgeRealtimeMediaReceiverLifecycle()
        let replacementOwner = SkyBridgeRealtimeMediaReceiverLifecycle()
        let lateCallbackGate = RealtimeMediaTestGate()

        XCTAssertEqual(ownership.claim(firstOwner), .acquiredVacant)
        XCTAssertEqual(ownership.claim(firstOwner), .alreadyOwned)
        XCTAssertEqual(ownership.claim(replacementOwner), .rejectedLiveOwner)

        let lateClaim = Task {
            await lateCallbackGate.wait()
            return ownership.claim(firstOwner)
        }

        XCTAssertTrue(firstOwner.retire())
        XCTAssertFalse(firstOwner.retire())
        let replacementClaim = ownership.claim(replacementOwner)
        XCTAssertEqual(replacementClaim, .replacedRetiredOwner)
        XCTAssertTrue(replacementClaim.requiresPipelineReset)
        await lateCallbackGate.open()

        let lateClaimDisposition = await lateClaim.value
        XCTAssertEqual(lateClaimDisposition, .rejectedInactiveCandidate)
        XCTAssertFalse(ownership.release(ifOwnedBy: firstOwner))
        XCTAssertTrue(ownership.isOwned(by: replacementOwner))
        XCTAssertTrue(ownership.release(ifOwnedBy: replacementOwner))
        XCTAssertFalse(ownership.isOwned(by: replacementOwner))

        let finalOwner = SkyBridgeRealtimeMediaReceiverLifecycle()
        XCTAssertEqual(ownership.claim(finalOwner), .acquiredVacant)
        XCTAssertTrue(ownership.retireCurrentOwnerAndClear())
        XCTAssertFalse(finalOwner.isActive)
        XCTAssertEqual(ownership.claim(finalOwner), .rejectedInactiveCandidate)
    }

    func testRealtimeAudioReceiverReuseKeyRequiresExactPeerSessionModeAndInterface() {
        let firstPeer = NSObject()
        let replacementPeer = NSObject()
        let interfaceIdentity = SkyBridgeRealtimeMediaInterfaceBinding.Identity(
            normalizedName: "en0",
            index: 14,
            expectedRemoteScope: "en0"
        )
        let baseline = RemoteControlRealtimeAudioReceiverReuseKey(
            peerId: "peer-a",
            peerIdentity: ObjectIdentifier(firstPeer),
            secureSessionId: "session-a",
            sendKey: Data(repeating: 1, count: 32),
            receiveKey: Data(repeating: 2, count: 32),
            role: .initiator,
            transcriptHash: Data(repeating: 3, count: 32),
            mode: .lowLatency,
            interfaceBindingIdentity: interfaceIdentity,
            authenticatedRemoteHost: "fe80::1"
        )

        XCTAssertEqual(
            baseline,
            RemoteControlRealtimeAudioReceiverReuseKey(
                peerId: "peer-a",
                peerIdentity: ObjectIdentifier(firstPeer),
                secureSessionId: "session-a",
                sendKey: Data(repeating: 1, count: 32),
                receiveKey: Data(repeating: 2, count: 32),
                role: .initiator,
                transcriptHash: Data(repeating: 3, count: 32),
                mode: .lowLatency,
                interfaceBindingIdentity: interfaceIdentity,
                authenticatedRemoteHost: "fe80::1"
            )
        )
        XCTAssertNotEqual(
            baseline,
            RemoteControlRealtimeAudioReceiverReuseKey(
                peerId: "peer-a",
                peerIdentity: ObjectIdentifier(replacementPeer),
                secureSessionId: "session-a",
                sendKey: Data(repeating: 1, count: 32),
                receiveKey: Data(repeating: 2, count: 32),
                role: .initiator,
                transcriptHash: Data(repeating: 3, count: 32),
                mode: .lowLatency,
                interfaceBindingIdentity: interfaceIdentity,
                authenticatedRemoteHost: "fe80::1"
            )
        )
        XCTAssertNotEqual(
            baseline,
            RemoteControlRealtimeAudioReceiverReuseKey(
                peerId: "peer-a",
                peerIdentity: ObjectIdentifier(firstPeer),
                secureSessionId: "session-a",
                sendKey: Data(repeating: 1, count: 32),
                receiveKey: Data(repeating: 2, count: 32),
                role: .initiator,
                transcriptHash: Data(repeating: 3, count: 32),
                mode: .highFidelity,
                interfaceBindingIdentity: interfaceIdentity,
                authenticatedRemoteHost: "fe80::1"
            )
        )
        XCTAssertNotEqual(
            baseline,
            RemoteControlRealtimeAudioReceiverReuseKey(
                peerId: "peer-a",
                peerIdentity: ObjectIdentifier(firstPeer),
                secureSessionId: "session-a",
                sendKey: Data(repeating: 9, count: 32),
                receiveKey: Data(repeating: 2, count: 32),
                role: .initiator,
                transcriptHash: Data(repeating: 3, count: 32),
                mode: .lowLatency,
                interfaceBindingIdentity: interfaceIdentity,
                authenticatedRemoteHost: "fe80::1"
            )
        )
    }

    func testRemoteControlInboundAdmissionBoundsAndReleasesUnauthenticatedConnections() throws {
        let admission = RemoteControlInboundAdmission(
            maximumConnections: 3,
            maximumConnectionsPerEndpoint: 2
        )
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
        let connections = (0..<4).map { _ in NWConnection(to: endpoint, using: .tcp) }
        defer { connections.forEach { $0.cancel() } }

        let first = try XCTUnwrap(admission.reserve(connection: connections[0], endpointKey: "peer:a"))
        XCTAssertNotNil(admission.reserve(connection: connections[1], endpointKey: "peer:a"))
        XCTAssertNil(admission.reserve(connection: connections[2], endpointKey: "peer:a"))
        XCTAssertNotNil(admission.reserve(connection: connections[2], endpointKey: "peer:b"))
        XCTAssertNil(admission.reserve(connection: connections[3], endpointKey: "peer:c"))
        XCTAssertEqual(admission.activeConnectionCount, 3)
        XCTAssertEqual(admission.activeConnectionCount(for: "peer:a"), 2)

        admission.release(first)
        XCTAssertNotNil(admission.reserve(connection: connections[3], endpointKey: "peer:c"))
        XCTAssertEqual(admission.activeConnectionCount, 3)
        XCTAssertEqual(admission.activeConnectionCount(for: "peer:a"), 1)

        admission.cancelAll()
        XCTAssertEqual(admission.activeConnectionCount, 0)
        XCTAssertEqual(admission.activeConnectionCount(for: "peer:a"), 0)
    }

    func testOpusRoundTripAndPLC() throws {
        let configuration = SkyBridgeOpusConfiguration.lowLatency
        let encoder = try SkyBridgeOpusEncoder(configuration: configuration)
        let decoder = try SkyBridgeOpusDecoder(
            sampleRate: configuration.sampleRate,
            channels: configuration.channels,
            frameDurationMs: configuration.frameDurationMs
        )

        let pcm = makeSinePCM(
            samplesPerChannel: configuration.samplesPerChannel,
            channels: configuration.channels
        )
        let packet = try encoder.encode(pcm16Interleaved: pcm)
        XCTAssertFalse(packet.isEmpty)

        let decoded = try decoder.decode(packet: packet)
        XCTAssertEqual(decoded.count, configuration.interleavedSampleCount)
        XCTAssertGreaterThan(decoded.map { abs(Int($0)) }.max() ?? 0, 0)

        let plc = try decoder.decode(packet: nil)
        XCTAssertEqual(plc.count, configuration.interleavedSampleCount)
    }

    func testPCM16ChunkBuilderReadsInterleavedAudioBufferList() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        XCTAssertEqual(audioBuffers.count, 1)
        let samples: [Int16] = [1, -1, 2, -2, 3, -3]
        samples.withUnsafeBufferPointer { source in
            let destination = audioBuffers[0].mData!.bindMemory(to: Int16.self, capacity: samples.count)
            destination.update(from: source.baseAddress!, count: samples.count)
            audioBuffers[0].mDataByteSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        }

        let chunk = RemotePCM16AudioChunkBuilder.makeChunk(from: buffer, sequenceNumber: 77)

        XCTAssertEqual(chunk?.sampleRate, 48_000)
        XCTAssertEqual(chunk?.channelCount, 2)
        XCTAssertEqual(chunk?.frameCount, 3)
        XCTAssertEqual(chunk?.sequenceNumber, 77)
        XCTAssertEqual(chunk?.data, data(from: samples))
    }

    func testMediaPacketAEADReplayAndTamperProtection() throws {
        let keys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x11, count: 32),
            receiveSecret: Data(repeating: 0x22, count: 32),
            sessionId: "media-session-test",
            transcriptHash: Data(repeating: 0x33, count: 32),
            epoch: 7
        )
        let header = SkyBridgeMediaPacketHeader(
            sessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash("media-session-test"),
            sequence: 42,
            timestampSamples: 42 * 960,
            wireDirection: keys.send.wireDirection,
            transcriptPrefix: keys.send.transcriptPrefix,
            keyEpoch: keys.send.epoch,
            nonceCounter: 42
        )
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let packet = try SkyBridgeMediaPacketCodec.seal(payload: payload, header: header, keys: keys.send)
        let opened = try SkyBridgeMediaPacketCodec.open(packet: packet, keys: keys.send)
        XCTAssertEqual(opened.header, header)
        XCTAssertEqual(opened.payload, payload)

        var replayWindow = SkyBridgeMediaReplayWindow(windowSize: 32)
        XCTAssertTrue(replayWindow.accept(sequence: opened.header.sequence))
        XCTAssertFalse(replayWindow.accept(sequence: opened.header.sequence))

        var tampered = packet
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try SkyBridgeMediaPacketCodec.open(packet: tampered, keys: keys.send)) { error in
            XCTAssertEqual(error as? SkyBridgeMediaPacketError, .authenticationFailed)
        }
    }

    func testMediaPacketRejectsWrongSessionAndStreamBeforeAuthentication() throws {
        let keys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x11, count: 32),
            receiveSecret: Data(repeating: 0x22, count: 32),
            sessionId: "media-session-test",
            transcriptHash: Data(repeating: 0x33, count: 32),
            epoch: 7
        )
        let header = SkyBridgeMediaPacketHeader(
            sessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash("media-session-test"),
            streamId: 99,
            sequence: 43,
            timestampSamples: 43 * 960,
            wireDirection: keys.send.wireDirection,
            transcriptPrefix: keys.send.transcriptPrefix,
            keyEpoch: keys.send.epoch,
            nonceCounter: 43
        )
        let packet = try SkyBridgeMediaPacketCodec.seal(
            payload: Data([0xca, 0xfe]),
            header: header,
            keys: keys.send
        )

        XCTAssertThrowsError(
            try SkyBridgeMediaPacketCodec.open(
                packet: packet,
                keys: keys.send,
                expectedSessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash("other-session"),
                expectedStreamId: 99
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeMediaPacketError,
                .sessionIdMismatch(
                    expected: SkyBridgeMediaPacketCodec.sessionIdHash("other-session"),
                    actual: header.sessionIdHash
                )
            )
        }

        XCTAssertThrowsError(
            try SkyBridgeMediaPacketCodec.open(
                packet: packet,
                keys: keys.send,
                expectedSessionIdHash: header.sessionIdHash,
                expectedStreamId: SkyBridgeRealtimeMediaConstants.defaultStreamId
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeMediaPacketError,
                .streamMismatch(expected: SkyBridgeRealtimeMediaConstants.defaultStreamId, actual: 99)
            )
        }
    }

    func testMediaPacketRejectsKeyEpochMismatchBeforeAuthentication() throws {
        let epoch7Keys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x11, count: 32),
            receiveSecret: Data(repeating: 0x22, count: 32),
            sessionId: "media-session-test",
            transcriptHash: Data(repeating: 0x33, count: 32),
            epoch: 7
        )
        let epoch8Keys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x11, count: 32),
            receiveSecret: Data(repeating: 0x22, count: 32),
            sessionId: "media-session-test",
            transcriptHash: Data(repeating: 0x33, count: 32),
            epoch: 8
        )
        let header = SkyBridgeMediaPacketHeader(
            sessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash("media-session-test"),
            sequence: 44,
            timestampSamples: 44 * 960,
            wireDirection: epoch7Keys.send.wireDirection,
            transcriptPrefix: epoch7Keys.send.transcriptPrefix,
            keyEpoch: epoch7Keys.send.epoch,
            nonceCounter: 44
        )
        let packet = try SkyBridgeMediaPacketCodec.seal(
            payload: Data([0xba, 0xad]),
            header: header,
            keys: epoch7Keys.send
        )

        XCTAssertThrowsError(
            try SkyBridgeMediaPacketCodec.open(
                packet: packet,
                keys: epoch8Keys.send,
                expectedSessionIdHash: header.sessionIdHash,
                expectedStreamId: header.streamId
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeMediaPacketError,
                .epochMismatch(expected: epoch8Keys.send.epoch, actual: epoch7Keys.send.epoch)
            )
        }
    }

    func testMediaPacketRejectsWrongDirectionAndTranscriptBeforeAuthentication() throws {
        let sessionId = "media-session-direction-transcript"
        let keys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x11, count: 32),
            receiveSecret: Data(repeating: 0x22, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x33, count: 32),
            epoch: 7
        )
        let wrongTranscriptKeys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x11, count: 32),
            receiveSecret: Data(repeating: 0x22, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x44, count: 32),
            epoch: 7
        )
        let header = SkyBridgeMediaPacketHeader(
            sessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash(sessionId),
            sequence: 45,
            timestampSamples: 45 * 960,
            wireDirection: keys.send.wireDirection,
            transcriptPrefix: keys.send.transcriptPrefix,
            keyEpoch: keys.send.epoch,
            nonceCounter: 45
        )
        let packet = try SkyBridgeMediaPacketCodec.seal(
            payload: Data([0x45, 0x45]),
            header: header,
            keys: keys.send
        )

        XCTAssertThrowsError(
            try SkyBridgeMediaPacketCodec.open(
                packet: packet,
                keys: keys.receive,
                expectedSessionIdHash: header.sessionIdHash,
                expectedStreamId: header.streamId
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeMediaPacketError,
                .directionMismatch(
                    expected: keys.receive.wireDirection.rawValue,
                    actual: keys.send.wireDirection.rawValue
                )
            )
        }

        XCTAssertThrowsError(
            try SkyBridgeMediaPacketCodec.open(
                packet: packet,
                keys: wrongTranscriptKeys.send,
                expectedSessionIdHash: header.sessionIdHash,
                expectedStreamId: header.streamId
            )
        ) { error in
            XCTAssertEqual(
                error as? SkyBridgeMediaPacketError,
                .transcriptMismatch(
                    expected: wrongTranscriptKeys.send.transcriptPrefix,
                    actual: keys.send.transcriptPrefix
                )
            )
        }
    }

    func testMediaKeysOpenAcrossPeerDirections() throws {
        let initiatorToResponder = Data(repeating: 0x41, count: 32)
        let responderToInitiator = Data(repeating: 0x52, count: 32)
        let transcriptHash = Data(repeating: 0x77, count: 32)
        let sessionId = "lan-cross-peer-media"
        let initiatorKeys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: initiatorToResponder,
            receiveSecret: responderToInitiator,
            sessionId: sessionId,
            transcriptHash: transcriptHash
        )
        let responderKeys = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: responderToInitiator,
            receiveSecret: initiatorToResponder,
            sessionId: sessionId,
            transcriptHash: transcriptHash,
            localRole: .responder
        )
        let header = SkyBridgeMediaPacketHeader(
            sessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash(sessionId),
            sequence: 7,
            timestampSamples: 7 * 960,
            wireDirection: initiatorKeys.send.wireDirection,
            transcriptPrefix: initiatorKeys.send.transcriptPrefix,
            keyEpoch: initiatorKeys.send.epoch,
            nonceCounter: 99
        )
        let payload = Data([0x73, 0x62, 0x6d, 0x61])
        let packet = try SkyBridgeMediaPacketCodec.seal(
            payload: payload,
            header: header,
            keys: initiatorKeys.send
        )

        let openedByPeer = try SkyBridgeMediaPacketCodec.open(packet: packet, keys: responderKeys.receive)
        XCTAssertEqual(openedByPeer.header, header)
        XCTAssertEqual(openedByPeer.payload, payload)
        XCTAssertThrowsError(try SkyBridgeMediaPacketCodec.open(packet: packet, keys: initiatorKeys.receive)) { error in
            XCTAssertEqual(
                error as? SkyBridgeMediaPacketError,
                .directionMismatch(
                    expected: initiatorKeys.receive.wireDirection.rawValue,
                    actual: initiatorKeys.send.wireDirection.rawValue
                )
            )
        }
    }

    func testRelayTransportSeparatesUdpReadyFromRelayBindAck() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeRealtimeMedia/UDPTransport.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("try await sendRelayBindAndWaitForResult(token: relayToken, on: connection)"))
        XCTAssertTrue(source.contains("connection.receiveMessage { content, _, _, error in"))
        XCTAssertTrue(source.contains("connection.send(content: data"))
        XCTAssertTrue(source.contains("ensureReceiveLoopStarted(on: connection)\n        try await sendRelayBind(token: token)"))
        XCTAssertTrue(source.contains("startEventHandler?(.relayBindAckTimedOut)"))
        XCTAssertTrue(source.contains("startEventHandler?(.relayBindMalformed)"))
        XCTAssertTrue(source.contains("startEventHandler?(.relayBindRejected(reason))"))
        XCTAssertTrue(source.contains("SkyBridgeRealtimeMediaRelayBindPolicy"))
        XCTAssertTrue(source.contains("case optimisticAfterSend"))
        XCTAssertTrue(source.contains("case udpConnectionReady"))
        XCTAssertTrue(source.contains("case relayBindAckTimedOut"))
        XCTAssertTrue(source.contains("udpConnectionReadyTimedOut"))
        XCTAssertTrue(source.contains("udpReadyPathMismatch"))
        XCTAssertTrue(source.contains("type\"") && source.contains("bind-result"))
        XCTAssertTrue(source.contains("relayBindRejected"))
        XCTAssertTrue(source.contains("relayBindTimedOut"))
    }

    func testUDPTransportPreservesLocalNetworkPrivacyDenial() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeRealtimeMedia/UDPTransport.swift"),
            encoding: .utf8
        )
        let senderStart = try XCTUnwrap(
            source.range(of: "private func waitForConnectionReady(on connection: NWConnection)")
        )
        let waiting = try XCTUnwrap(
            source.range(of: "case .waiting(let error):", range: senderStart.lowerBound..<source.endIndex)
        )
        let failed = try XCTUnwrap(
            source.range(of: "case .failed(let error):", range: waiting.upperBound..<source.endIndex)
        )
        let timeout = try XCTUnwrap(
            source.range(
                of: "queue.asyncAfter(deadline: .now() + connectionReadyTimeout)",
                range: failed.upperBound..<source.endIndex
            )
        )
        let waitingBody = source[waiting.lowerBound..<failed.lowerBound]
        let failedBody = source[failed.lowerBound..<timeout.lowerBound]
        let timeoutBody = source[timeout.lowerBound..<source.endIndex]

        XCTAssertTrue(source.contains("import SkyBridgeAppleTransport"))
        XCTAssertTrue(
            waitingBody.contains("NetworkFrameworkLocalNetworkPermissionClassifier.isDenied(")
        )
        XCTAssertTrue(waitingBody.contains(".udpLocalNetworkPermissionDenied"))
        XCTAssertTrue(
            failedBody.contains("NetworkFrameworkLocalNetworkPermissionClassifier")
        )
        XCTAssertTrue(failedBody.contains(".udpLocalNetworkPermissionDenied"))
        XCTAssertTrue(
            timeoutBody.contains("NetworkFrameworkLocalNetworkPermissionClassifier")
        )
        XCTAssertTrue(timeoutBody.contains(".udpLocalNetworkPermissionDenied"))
        XCTAssertEqual(
            SkyBridgeRealtimeMediaTransportError.udpLocalNetworkPermissionDenied
                .errorDescription,
            "udp local network permission denied"
        )
        XCTAssertTrue(
            source.contains("case .udpListenerMissingBoundPort:")
                && source.contains("guard let port = listener.port?.rawValue, port > 0")
        )
        XCTAssertTrue(source.contains("private var pendingListener: NWListener?"))
        XCTAssertTrue(source.contains("private var pendingStartState: StartState?"))
        XCTAssertTrue(source.contains("private static let maximumActiveConnections = 4"))
        XCTAssertTrue(source.contains("throw SkyBridgeRealtimeMediaTransportError.udpReceiverAlreadyStarted"))
        XCTAssertTrue(
            source.contains(
                ".failure(SkyBridgeRealtimeMediaTransportError.udpListenerReadyTimedOut)"
            )
        )
        XCTAssertTrue(source.contains("let pendingListener = self.pendingListener"))
        XCTAssertTrue(source.contains("let pendingStartState = self.pendingStartState"))
        XCTAssertTrue(
            source.contains(
                "_ = pendingStartState?.complete(.failure(CancellationError()))"
            )
        )
        XCTAssertTrue(source.contains("pendingListener?.cancel()"))
        XCTAssertTrue(source.contains("self.listener === listener"))
        XCTAssertTrue(source.contains("self.receiveNext(on: connection, ownedBy: listener)"))
        let listenerStart = try XCTUnwrap(source.range(of: "let startState = StartState()"))
        let listenerWaiting = try XCTUnwrap(
            source.range(
                of: "case .waiting(let error):",
                range: listenerStart.lowerBound..<senderStart.lowerBound
            )
        )
        let listenerFailed = try XCTUnwrap(
            source.range(
                of: "case .failed(let error):",
                range: listenerWaiting.upperBound..<senderStart.lowerBound
            )
        )
        let listenerWaitingBody = source[listenerWaiting.lowerBound..<listenerFailed.lowerBound]
        XCTAssertTrue(
            listenerWaitingBody.contains(
                "NetworkFrameworkLocalNetworkPermissionClassifier.isDenied("
            )
        )
        XCTAssertTrue(listenerWaitingBody.contains(".udpLocalNetworkPermissionDenied"))
        XCTAssertTrue(
            source.contains(
                "case .cancelled:\n                let didComplete = startState.complete(.failure(CancellationError()))"
            )
        )
        XCTAssertTrue(
            source.contains(
                "if !didComplete, self?.isCurrent(listener: listener) == true"
            )
        )
        XCTAssertTrue(source.contains("self?.terminalFailureHandler?(CancellationError())"))
    }

    func testOptimisticRelayBindWatchdogDoesNotFireAfterStop() async throws {
        let relay = LocalUDPDropRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let bindSent = expectation(description: "relay bind was sent")
        let staleTimeout = expectation(description: "stale relay bind timeout")
        staleTimeout.isInverted = true
        let transport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: SkyBridgeMediaEndpoint(
                host: "127.0.0.1",
                port: port,
                relayToken: "test-relay-token"
            ),
            receiveHandler: { _ in },
            relayBindPolicy: .optimisticAfterSend,
            connectionReadyTimeout: 0.5,
            relayBindAckTimeout: 0.2,
            startEventHandler: { event in
                switch event {
                case .relayBindSent:
                    bindSent.fulfill()
                case .relayBindAckTimedOut:
                    staleTimeout.fulfill()
                default:
                    break
                }
            }
        )

        try await transport.start()
        await fulfillment(of: [bindSent], timeout: 1.0)
        await transport.stop()
        await fulfillment(of: [staleTimeout], timeout: 0.4)
    }

    func testOptimisticRelayBindReadsAckWithoutReceiveHandler() async throws {
        let relay = LocalUDPAckRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let bindAccepted = expectation(description: "relay bind ack was observed")
        let staleTimeout = expectation(description: "ack timeout should not fire after accepted bind")
        staleTimeout.isInverted = true
        let transport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: SkyBridgeMediaEndpoint(
                host: "127.0.0.1",
                port: port,
                relayToken: "test-relay-token"
            ),
            relayBindPolicy: .optimisticAfterSend,
            connectionReadyTimeout: 0.5,
            relayBindAckTimeout: 0.2,
            startEventHandler: { event in
                switch event {
                case .relayBindAccepted:
                    bindAccepted.fulfill()
                case .relayBindAckTimedOut:
                    staleTimeout.fulfill()
                default:
                    break
                }
            }
        )

        try await transport.start()
        await fulfillment(of: [bindAccepted], timeout: 1.0)
        await fulfillment(of: [staleTimeout], timeout: 0.4)
        await transport.stop()
    }

    func testRequiredRelayBindPostsReceiveBeforeSendingAndAcceptsFastAck() async throws {
        let relay = LocalUDPAckRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let bindSent = expectation(description: "relay bind was sent")
        let bindAccepted = expectation(description: "relay bind ack was accepted")
        let transport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: SkyBridgeMediaEndpoint(
                host: "127.0.0.1",
                port: port,
                relayToken: "test-relay-token"
            ),
            relayBindPolicy: .requireAcknowledgement,
            connectionReadyTimeout: 0.5,
            relayBindAckTimeout: 0.5,
            startEventHandler: { event in
                switch event {
                case .relayBindSent:
                    bindSent.fulfill()
                case .relayBindAccepted:
                    bindAccepted.fulfill()
                default:
                    break
                }
            }
        )

        try await transport.start()
        await fulfillment(of: [bindSent, bindAccepted], timeout: 1.0)
        await transport.stop()
    }

    func testRequiredRelayBindEmitsTimeoutBeforeStartThrows() async throws {
        let relay = LocalUDPDropRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let bindSent = expectation(description: "relay bind was sent")
        let bindTimedOut = expectation(description: "relay bind timeout was reported")
        let transport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: SkyBridgeMediaEndpoint(
                host: "127.0.0.1",
                port: port,
                relayToken: "test-relay-token"
            ),
            relayBindPolicy: .requireAcknowledgement,
            connectionReadyTimeout: 0.5,
            relayBindAckTimeout: 0.2,
            startEventHandler: { event in
                switch event {
                case .relayBindSent:
                    bindSent.fulfill()
                case .relayBindAckTimedOut:
                    bindTimedOut.fulfill()
                default:
                    break
                }
            }
        )

        do {
            try await transport.start()
            XCTFail("Required relay bind should time out when the relay drops bind acks")
        } catch SkyBridgeRealtimeMediaTransportError.relayBindTimedOut {
            await fulfillment(of: [bindSent, bindTimedOut], timeout: 1.0)
        } catch {
            XCTFail("Expected relayBindTimedOut, got \(error)")
        }
    }

    func testRequiredRelayRebindEmitsTimeoutBeforeReturning() async throws {
        let relay = LocalUDPDropRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let bindSent = expectation(description: "relay rebind was sent")
        let bindTimedOut = expectation(description: "relay rebind timeout was reported")
        let transport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: SkyBridgeMediaEndpoint(
                host: "127.0.0.1",
                port: port,
                relayToken: nil
            ),
            relayBindPolicy: .requireAcknowledgement,
            connectionReadyTimeout: 0.5,
            relayBindAckTimeout: 0.2,
            startEventHandler: { event in
                switch event {
                case .relayBindSent:
                    bindSent.fulfill()
                case .relayBindAckTimedOut:
                    bindTimedOut.fulfill()
                default:
                    break
                }
            }
        )
        try await transport.start()
        defer {
            Task {
                await transport.stop()
            }
        }

        do {
            try await transport.rebindRelayToken(
                "test-relay-token",
                relayBindPolicy: .requireAcknowledgement
            )
            XCTFail("Required relay rebind should time out when the relay drops bind acks")
        } catch SkyBridgeRealtimeMediaTransportError.relayBindTimedOut {
            await fulfillment(of: [bindSent, bindTimedOut], timeout: 1.0)
        } catch {
            XCTFail("Expected relayBindTimedOut, got \(error)")
        }
    }

    func testRequiredRelayRebindAcceptsAckWhileReceiveLoopIsActive() async throws {
        let relay = LocalUDPAckRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let bindSent = expectation(description: "relay rebind was sent")
        let bindAccepted = expectation(description: "relay rebind ack was accepted")
        let transport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: SkyBridgeMediaEndpoint(
                host: "127.0.0.1",
                port: port,
                relayToken: nil
            ),
            receiveHandler: { _ in },
            relayBindPolicy: .requireAcknowledgement,
            connectionReadyTimeout: 0.5,
            relayBindAckTimeout: 0.5,
            startEventHandler: { event in
                switch event {
                case .relayBindSent:
                    bindSent.fulfill()
                case .relayBindAccepted:
                    bindAccepted.fulfill()
                default:
                    break
                }
            }
        )
        try await transport.start()
        defer {
            Task {
                await transport.stop()
            }
        }

        try await transport.rebindRelayToken(
            "test-relay-token",
            relayBindPolicy: .requireAcknowledgement
        )
        await fulfillment(of: [bindSent, bindAccepted], timeout: 1.0)
    }

    func testRequiredRelayRebindAcceptsFastAckWithoutExistingReceiveLoop() async throws {
        let relay = LocalUDPAckRelay()
        let port = try await relay.start()
        defer { relay.stop() }

        let bindSent = expectation(description: "relay rebind was sent")
        let bindAccepted = expectation(description: "relay rebind ack was accepted")
        let transport = SkyBridgeUDPRealtimeMediaTransport(
            endpoint: SkyBridgeMediaEndpoint(
                host: "127.0.0.1",
                port: port,
                relayToken: nil
            ),
            relayBindPolicy: .requireAcknowledgement,
            connectionReadyTimeout: 0.5,
            relayBindAckTimeout: 0.5,
            startEventHandler: { event in
                switch event {
                case .relayBindSent:
                    bindSent.fulfill()
                case .relayBindAccepted:
                    bindAccepted.fulfill()
                default:
                    break
                }
            }
        )
        try await transport.start()
        defer {
            Task {
                await transport.stop()
            }
        }

        try await transport.rebindRelayToken(
            "test-relay-token",
            relayBindPolicy: .requireAcknowledgement
        )
        await fulfillment(of: [bindSent, bindAccepted], timeout: 1.0)
    }

    func testJitterBufferOrdersFramesAndDropsLatePackets() {
        var buffer = SkyBridgeMediaJitterBuffer<Data>(
            targetDelayMs: 40,
            maxDelayMs: 100,
            packetDurationMs: 20
        )
        let now: TimeInterval = 1_000
        XCTAssertEqual(
            buffer.insert(.init(sequence: 2, timestampSamples: 1_920, insertedAt: now, payload: Data([2])), now: now),
            .accepted
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 1, timestampSamples: 960, insertedAt: now, payload: Data([1])), now: now),
            .accepted
        )
        XCTAssertNil(buffer.popReady(now: now + 0.020))
        XCTAssertEqual(buffer.popReady(now: now + 0.045)?.sequence, 1)
        XCTAssertEqual(buffer.popReady(now: now + 0.045)?.sequence, 2)
        XCTAssertEqual(
            buffer.insert(.init(sequence: 1, timestampSamples: 960, insertedAt: now, payload: Data([1])), now: now + 0.050),
            .droppedLate
        )
    }

    func testJitterBufferWaitsForReorderedMissingFrameBeforeSkippingGap() {
        var buffer = SkyBridgeMediaJitterBuffer<Data>(
            targetDelayMs: 40,
            maxDelayMs: 100,
            packetDurationMs: 20
        )
        let now: TimeInterval = 2_000
        XCTAssertEqual(
            buffer.insert(.init(sequence: 1, timestampSamples: 960, insertedAt: now, payload: Data([1])), now: now),
            .accepted
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 3, timestampSamples: 2_880, insertedAt: now + 0.001, payload: Data([3])), now: now + 0.001),
            .accepted
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 4, timestampSamples: 3_840, insertedAt: now + 0.002, payload: Data([4])), now: now + 0.002),
            .accepted
        )

        XCTAssertEqual(buffer.popReady(now: now + 0.045)?.sequence, 1)
        XCTAssertNil(
            buffer.popReady(now: now + 0.046),
            "Future audio frames alone should not immediately force PLC; the missing sequence still gets a short reorder grace window."
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 2, timestampSamples: 1_920, insertedAt: now + 0.047, payload: Data([2])), now: now + 0.047),
            .accepted
        )
        XCTAssertEqual(buffer.popReady(now: now + 0.088)?.sequence, 2)
        XCTAssertEqual(buffer.popReady(now: now + 0.088)?.sequence, 3)
    }

    func testJitterBufferSkipsMissingFrameAfterReorderGraceExpires() {
        var buffer = SkyBridgeMediaJitterBuffer<Data>(
            targetDelayMs: 40,
            maxDelayMs: 100,
            packetDurationMs: 20
        )
        let now: TimeInterval = 3_000
        XCTAssertEqual(
            buffer.insert(.init(sequence: 1, timestampSamples: 960, insertedAt: now, payload: Data([1])), now: now),
            .accepted
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 3, timestampSamples: 2_880, insertedAt: now + 0.001, payload: Data([3])), now: now + 0.001),
            .accepted
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 4, timestampSamples: 3_840, insertedAt: now + 0.002, payload: Data([4])), now: now + 0.002),
            .accepted
        )

        XCTAssertEqual(buffer.popReady(now: now + 0.045)?.sequence, 1)
        XCTAssertNil(buffer.popReady(now: now + 0.046))
        switch buffer.popReadyOrGap(now: now + 0.087) {
        case .gap(let sequence):
            XCTAssertEqual(
                sequence,
                2,
                "The jitter buffer should emit one explicit missing sequence so the audio receiver generates exactly one PLC frame."
            )
        default:
            XCTFail("Expected an explicit jitter-buffer gap after the bounded reorder grace window.")
        }
        switch buffer.popReadyOrGap(now: now + 0.087) {
        case .frame(let frame):
            XCTAssertEqual(frame.sequence, 3)
        default:
            XCTFail("Expected sequence 3 to play immediately after PLC consumes missing sequence 2.")
        }
        XCTAssertEqual(
            buffer.insert(.init(sequence: 2, timestampSamples: 1_920, insertedAt: now + 0.088, payload: Data([2])), now: now + 0.088),
            .droppedLate
        )
    }

    func testJitterBufferCanDeferGapWhenPlaybackHasHeadroom() {
        var buffer = SkyBridgeMediaJitterBuffer<Data>(
            targetDelayMs: 40,
            maxDelayMs: 100,
            packetDurationMs: 20
        )
        let now: TimeInterval = 3_500
        XCTAssertEqual(
            buffer.insert(.init(sequence: 1, timestampSamples: 960, insertedAt: now, payload: Data([1])), now: now),
            .accepted
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 3, timestampSamples: 2_880, insertedAt: now + 0.001, payload: Data([3])), now: now + 0.001),
            .accepted
        )

        XCTAssertEqual(buffer.popReadyFrame(now: now + 0.045)?.sequence, 1)
        XCTAssertNil(
            buffer.popReadyFrame(now: now + 0.087),
            "Playback with enough queued audio should be able to defer PLC for a missing sequence."
        )
        XCTAssertNil(
            buffer.popReady(now: now + 0.087),
            "Once the caller chooses the normal path, the jitter buffer should start its bounded reorder grace."
        )
        switch buffer.popReadyOrGap(now: now + 0.128) {
        case .gap(let sequence):
            XCTAssertEqual(sequence, 2)
        default:
            XCTFail("The normal pop path should still emit a gap when the caller needs PLC.")
        }
    }

    func testJitterBufferCanSkipMissingFrameWithoutAdditionalReorderGrace() {
        var buffer = SkyBridgeMediaJitterBuffer<Data>(
            targetDelayMs: 180,
            maxDelayMs: 420,
            packetDurationMs: 20,
            reorderGraceMs: 0
        )
        let now: TimeInterval = 4_000
        XCTAssertEqual(
            buffer.insert(.init(sequence: 1, timestampSamples: 960, insertedAt: now, payload: Data([1])), now: now),
            .accepted
        )
        XCTAssertEqual(
            buffer.insert(.init(sequence: 3, timestampSamples: 2_880, insertedAt: now + 0.040, payload: Data([3])), now: now + 0.040),
            .accepted
        )

        XCTAssertEqual(buffer.popReady(now: now + 0.181)?.sequence, 1)
        switch buffer.popReadyOrGap(now: now + 0.200) {
        case .gap(let sequence):
            XCTAssertEqual(sequence, 2)
        default:
            XCTFail("Expected zero-grace audio jitter mode to emit PLC for a missing sequence without an extra stall.")
        }
        XCTAssertNil(
            buffer.popReady(now: now + 0.200),
            "The future frame should still honor its target delay after the missing frame is concealed."
        )
        XCTAssertEqual(buffer.popReady(now: now + 0.221)?.sequence, 3)
    }

    func testHighFidelityAudioProfileKeepsCrossNetworkJitterHeadroom() {
        let lowLatency = SkyBridgeMediaAudioProfile.profile(for: .lowLatency)
        XCTAssertEqual(lowLatency.jitterTargetMs, 40)
        XCTAssertEqual(lowLatency.jitterMaxMs, 100)

        let highFidelity = SkyBridgeMediaAudioProfile.profile(for: .highFidelity)
        XCTAssertEqual(highFidelity.frameDurationMs, 20)
        XCTAssertGreaterThanOrEqual(
            highFidelity.jitterTargetMs,
            140,
            "High-fidelity PQC media commonly runs over cross-network relay; keeping less than 7 packets of target jitter made otherwise valid 50pps Opus streams churn under normal WAN burstiness."
        )
        XCTAssertGreaterThanOrEqual(
            highFidelity.jitterMaxMs,
            360,
            "The receiver and sender need enough bounded headroom to absorb relay bursts without evicting authenticated packets."
        )
    }

    @available(macOS 14.0, *)
    func testRealtimeAudioSubmissionPipeBuffersBeforeAttachAndFlushesNewestChunks() async throws {
        let sessionId = "audio-pipe-attach"
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x41, count: 32),
            receiveSecret: Data(repeating: 0x42, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x43, count: 32)
        )
        let transport = SuspendedCapturingRealtimeMediaTransport(sendDelayMs: 0)
        let sender = try RemoteRealtimeMediaAudioSender(
            sessionId: sessionId,
            endpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_560),
            keys: keyMaterial.send,
            mode: .highFidelity,
            transport: transport
        )
        try await sender.start()
        defer { Task { await sender.close() } }

        let profile = SkyBridgeMediaAudioProfile.profile(for: .highFidelity)
        let pcmData = data(from: makeSinePCM(samplesPerChannel: profile.samplesPerPacket, channels: profile.channels))
        let pipe = RemoteRealtimePCM16SubmissionPipe(bufferedChunkLimit: 2)
        defer { pipe.close() }

        for sequence in 0..<3 {
            pipe.submit(
                RemoteDesktopAudioChunkPayload(
                    sampleRate: profile.sampleRate,
                    channelCount: profile.channels,
                    frameCount: profile.samplesPerPacket,
                    sequenceNumber: UInt64(sequence),
                    data: pcmData
                )
            )
        }
        let pendingSnapshot = pipe.snapshot()
        XCTAssertFalse(pendingSnapshot.hasSender)
        XCTAssertEqual(pendingSnapshot.submittedBeforeAttach, 3)
        XCTAssertEqual(pendingSnapshot.pendingBeforeAttach, 2)
        XCTAssertEqual(pendingSnapshot.droppedBeforeAttach, 1)

        pipe.attach(sender: sender)
        let attachedSnapshot = pipe.snapshot()
        XCTAssertTrue(attachedSnapshot.hasSender)
        XCTAssertEqual(attachedSnapshot.pendingBeforeAttach, 0)

        let deadline = Date().addingTimeInterval(1)
        while await transport.packetCount < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = await sender.diagnosticSnapshot()
        let packetCount = await transport.packetCount
        XCTAssertEqual(snapshot.capturedPackets, 2)
        XCTAssertEqual(packetCount, 2)
    }

    @available(macOS 14.0, *)
    func testRealtimeAudioSenderSerializesConcurrentSubmissionsBeforeTransportAwait() async throws {
        let sessionId = "audio-sender-reentrancy"
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x61, count: 32),
            receiveSecret: Data(repeating: 0x62, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x63, count: 32)
        )
        let transport = SuspendedCapturingRealtimeMediaTransport(sendDelayMs: 15)
        let sender = try RemoteRealtimeMediaAudioSender(
            sessionId: sessionId,
            endpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_555),
            keys: keyMaterial.send,
            mode: .highFidelity,
            transport: transport
        )

        try await sender.start()

        let profile = SkyBridgeMediaAudioProfile.profile(for: .highFidelity)
        let pcm = makeSinePCM(samplesPerChannel: profile.samplesPerPacket, channels: profile.channels)
        let pcmData = data(from: pcm)
        let packetCount = 6
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<packetCount {
                let chunk = RemoteDesktopAudioChunkPayload(
                    sampleRate: profile.sampleRate,
                    channelCount: profile.channels,
                    frameCount: profile.samplesPerPacket,
                    sequenceNumber: UInt64(index),
                    data: pcmData
                )
                group.addTask {
                    await sender.submitPCM16Chunk(chunk)
                }
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while await transport.packetCount < packetCount, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await sender.close()

        let packets = await transport.packetsSnapshot()
        XCTAssertEqual(packets.count, packetCount)
        let headers = try packets.map {
            try SkyBridgeMediaPacketCodec.open(packet: $0, keys: keyMaterial.send).header
        }
        XCTAssertEqual(headers.map(\.sequence), (0..<packetCount).map(UInt64.init))
        XCTAssertEqual(
            headers.map(\.timestampSamples),
            (0..<packetCount).map { UInt64($0 * profile.samplesPerPacket) }
        )
        let nonces = headers.map(\.nonceCounter)
        XCTAssertEqual(Set(nonces).count, packetCount)
        XCTAssertEqual(
            zip(nonces, nonces.dropFirst()).map { $1 - $0 },
            Array(repeating: UInt64(1), count: packetCount - 1)
        )
    }

    @available(macOS 14.0, *)
    func testLowLatencyRealtimeAudioSenderDuplicatesDatagramsForCellularRelayLoss() async throws {
        let sessionId = "audio-sender-redundant-low-latency"
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x21, count: 32),
            receiveSecret: Data(repeating: 0x22, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x23, count: 32)
        )
        let transport = SuspendedCapturingRealtimeMediaTransport(sendDelayMs: 0)
        let sender = try RemoteRealtimeMediaAudioSender(
            sessionId: sessionId,
            endpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_564),
            keys: keyMaterial.send,
            mode: .lowLatency,
            transport: transport
        )

        try await sender.start()
        let profile = SkyBridgeMediaAudioProfile.profile(for: .lowLatency)
        let pcmData = data(from: makeSinePCM(samplesPerChannel: profile.samplesPerPacket, channels: profile.channels))
        await sender.submitPCM16Chunk(
            RemoteDesktopAudioChunkPayload(
                sampleRate: profile.sampleRate,
                channelCount: profile.channels,
                frameCount: profile.samplesPerPacket,
                sequenceNumber: 0,
                data: pcmData
            )
        )

        let deadline = Date().addingTimeInterval(1)
        while await transport.packetCount < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await sender.close()

        let packets = await transport.packetsSnapshot()
        XCTAssertEqual(packets.count, 2)
        let headers = try packets.map {
            try SkyBridgeMediaPacketCodec.open(packet: $0, keys: keyMaterial.send).header
        }
        XCTAssertEqual(headers.map(\.sequence), [0, 0])
        XCTAssertEqual(Set(headers.map(\.nonceCounter)).count, 1)
        let snapshot = await sender.diagnosticSnapshot()
        XCTAssertEqual(snapshot.sentPackets, 1)
        XCTAssertEqual(snapshot.droppedPackets, 0)
    }

    @available(macOS 14.0, *)
    func testRealtimeAudioSenderCloseDuringPacingSleepDoesNotTouchClearedBuffer() async throws {
        let sessionId = "audio-sender-close-during-pacing"
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x51, count: 32),
            receiveSecret: Data(repeating: 0x52, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x53, count: 32)
        )
        let transport = SuspendedCapturingRealtimeMediaTransport(
            sendDelayMs: 0,
            suspendBeforeAppendingSendNumber: 2
        )
        let sender = try RemoteRealtimeMediaAudioSender(
            sessionId: sessionId,
            endpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_556),
            keys: keyMaterial.send,
            mode: .highFidelity,
            transport: transport
        )

        try await sender.start()

        let profile = SkyBridgeMediaAudioProfile.profile(for: .highFidelity)
        let pcmData = data(from: makeSinePCM(samplesPerChannel: profile.samplesPerPacket, channels: profile.channels))
        for sequence in 0..<2 {
            await sender.submitPCM16Chunk(
                RemoteDesktopAudioChunkPayload(
                    sampleRate: profile.sampleRate,
                    channelCount: profile.channels,
                    frameCount: profile.samplesPerPacket,
                    sequenceNumber: UInt64(sequence),
                    data: pcmData
                )
            )
        }

        let didSuspendSecondSend = await transport.waitForSuspendedSend(timeoutMs: 1_000)
        XCTAssertTrue(didSuspendSecondSend, "第二帧必须进入可控的 send 挂起点，才能验证 close 取消真实发送路径。")
        let sendAttemptCount = await transport.sendAttemptCount
        XCTAssertEqual(sendAttemptCount, 2)
        let firstPacketCount = await transport.packetCount
        XCTAssertEqual(
            firstPacketCount,
            1,
            "The gated test transport keeps the second frame out of the capture list until close cancels the drain task."
        )

        await sender.close()
        let sentPacketCountAtClose = await transport.packetCount
        try await Task.sleep(for: .milliseconds(profile.frameDurationMs * 2))
        let sentPacketCountAfterClose = await transport.packetCount
        let closeSnapshot = await sender.diagnosticSnapshot()
        XCTAssertEqual(
            sentPacketCountAtClose,
            1,
            "Only the first frame should be sent before close; the second submitted frame must remain cancellable."
        )
        XCTAssertEqual(
            sentPacketCountAfterClose,
            sentPacketCountAtClose,
            "Closing during the pacing window must cancel the drain loop without sending after close."
        )
        XCTAssertEqual(closeSnapshot.queuedFrames, 0)
    }

    @available(macOS 14.0, *)
    func testRealtimeAudioSenderDiagnosticSnapshotReportsInvalidDrops() async throws {
        let sessionId = "audio-sender-diagnostics"
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x31, count: 32),
            receiveSecret: Data(repeating: 0x32, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x33, count: 32)
        )
        let sender = try RemoteRealtimeMediaAudioSender(
            sessionId: sessionId,
            endpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_559),
            keys: keyMaterial.send,
            mode: .lowLatency,
            transport: SuspendedCapturingRealtimeMediaTransport(sendDelayMs: 0)
        )
        try await sender.start()
        await sender.submitPCM16Chunk(
            RemoteDesktopAudioChunkPayload(
                sampleRate: 44_100,
                channelCount: 2,
                frameCount: 1,
                sequenceNumber: 1,
                data: Data([0, 0, 0, 0])
            )
        )

        let snapshot = await sender.diagnosticSnapshot()
        await sender.close()

        XCTAssertEqual(snapshot.capturedPackets, 0)
        XCTAssertEqual(snapshot.droppedPackets, 1)
        XCTAssertEqual(snapshot.invalidDroppedPackets, 1)
        XCTAssertEqual(snapshot.mode, SkyBridgeMediaAudioMode.lowLatency.rawValue)
    }

    @available(macOS 14.0, *)
    func testRealtimeAudioSenderIdentityMatchesStableMediaConfiguration() async throws {
        let sessionId = "audio-sender-stable-identity"
        let endpoint = SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_557)
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x71, count: 32),
            receiveSecret: Data(repeating: 0x72, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x73, count: 32)
        )
        let sender = try RemoteRealtimeMediaAudioSender(
            sessionId: sessionId,
            endpoint: endpoint,
            keys: keyMaterial.send,
            mode: .highFidelity,
            transport: SuspendedCapturingRealtimeMediaTransport(sendDelayMs: 0)
        )

        try await sender.start()
        let matchesStableConfiguration = await sender.matches(
            sessionId: sessionId,
            endpoint: endpoint,
            mode: .highFidelity
        )
        let matchesWrongMode = await sender.matches(
            sessionId: sessionId,
            endpoint: endpoint,
            mode: .lowLatency
        )
        let matchesWrongEndpoint = await sender.matches(
            sessionId: sessionId,
            endpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_558),
            mode: .highFidelity
        )
        XCTAssertTrue(matchesStableConfiguration)
        XCTAssertFalse(matchesWrongMode)
        XCTAssertFalse(matchesWrongEndpoint)
        await sender.close()
        let matchesAfterClose = await sender.matches(
            sessionId: sessionId,
            endpoint: endpoint,
            mode: .highFidelity
        )
        XCTAssertFalse(matchesAfterClose)
    }

    func testPQCAndLegacyAudioTransportDecisionsStaySeparated() {
        let pqc = RemoteDesktopStreamConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 120,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            audioMode: SkyBridgeMediaAudioMode.highFidelity.rawValue,
            compatibilityAudioFallbackEnabled: false,
            preferredAudioEncoding: nil
        )

        XCTAssertTrue(pqc.requestsRealtimeMediaAudio)
        XCTAssertFalse(pqc.allowsLegacyAudioChunkFallback)
        XCTAssertNil(pqc.preferredAudioEncoding)

        let legacy = RemoteDesktopStreamConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 120,
            lowLatencyMode: false,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportLegacyChunkV1,
            compatibilityAudioFallbackEnabled: true,
            preferredAudioEncoding: RemoteDesktopAudioChunkPayload.Encoding.aacLC.rawValue
        )

        XCTAssertFalse(legacy.requestsRealtimeMediaAudio)
        XCTAssertTrue(legacy.allowsLegacyAudioChunkFallback)
        XCTAssertEqual(legacy.preferredAudioEncoding, RemoteDesktopAudioChunkPayload.Encoding.aacLC.rawValue)
    }

    func testP2PAndWebRTCAudioFallbackRequireExplicitLegacySwitch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let p2pSource = try remoteControlSource(root: root)
        XCTAssertTrue(p2pSource.contains("legacyAudioFallbackEnabled"))
        XCTAssertTrue(p2pSource.contains("if legacyAudioFallbackEnabled {\n            policy = policy.protectingRealtimeAudio()"))
        XCTAssertTrue(p2pSource.contains("private var realtimeAudioCaptureStreamer: ScreenCaptureKitStreamer?"))
        XCTAssertTrue(p2pSource.contains("private var realtimeAudioCaptureStrictMediaFallbacks: Bool?"))
        XCTAssertTrue(p2pSource.contains("let shouldPreserveRealtimeAudioCaptureStreamer = didReuseRealtimeAudioSender"))
        XCTAssertTrue(p2pSource.contains("&& realtimeAudioCaptureStrictMediaFallbacks == strictMediaFallbacks"))
        XCTAssertTrue(p2pSource.contains("let preservedRealtimeAudioCaptureStreamer = shouldPreserveRealtimeAudioCaptureStreamer"))
        XCTAssertTrue(p2pSource.contains("if !shouldPreserveRealtimeAudioCaptureStreamer {\n            realtimeAudioCaptureStreamer?.stop()"))
        XCTAssertTrue(p2pSource.contains("if preservedRealtimeAudioCaptureStreamer != nil {\n                realtimeAudioCaptureStreamerForAttempt = nil"))
        XCTAssertTrue(p2pSource.contains("preservedRealtimeAudioCaptureStreamer?.stop()"))
        XCTAssertTrue(p2pSource.contains("if reason.hasPrefix(\"p2p-realtime-audio-\") {\n            realtimeAudioCaptureStreamer?.stop()"))
        XCTAssertTrue(p2pSource.contains("realtimeAudioCapture=\\(preservedRealtimeAudioCaptureStreamer != nil ? \"preserved-sck\""))
        XCTAssertTrue(p2pSource.contains("startedRealtimeAudioCaptureStreamer?.stop()"))
        XCTAssertTrue(p2pSource.contains("p2p-realtime-audio-start-failed"))
        XCTAssertTrue(p2pSource.contains("action=video-preserved"))
        XCTAssertTrue(p2pSource.contains("didCloseRealtimeAudioSenderForAudioStartFailure"))
        XCTAssertFalse(
            p2pSource.contains("captureStreamer = nil\n                    realtimeAudioCaptureStreamer?.stop()"),
            "Viewer video config restarts must not cut a reused realtime audio capture before the new attempt is ready."
        )
        XCTAssertTrue(p2pSource.contains("Remote frame tx telemetry"))
        XCTAssertTrue(p2pSource.contains("sampleMs=\\(sampleMs"))
        XCTAssertTrue(p2pSource.contains("submittedFPS="))
        XCTAssertTrue(p2pSource.contains("sentFPS="))
        XCTAssertTrue(p2pSource.contains("submitted=\\(snapshot.submittedFrames"))
        XCTAssertTrue(p2pSource.contains("rawBackpressure=\\(snapshot.rawBackpressureEvents"))
        XCTAssertTrue(p2pSource.contains("orderedThrottle=\\(snapshot.orderedThrottleEvents"))
        XCTAssertTrue(p2pSource.contains("queueBacklog=\\(snapshot.queueBacklogEvents"))
        XCTAssertTrue(p2pSource.contains("avgSendMs="))
        XCTAssertFalse(
            p2pSource.contains("if realtimeAudioSender != nil {\n            policy = policy.protectingRealtimeAudio()"),
            "Dedicated P2P realtime audio must not use the legacy 24fps shared-channel protection."
        )
        XCTAssertTrue(p2pSource.contains("captureSystemAudio: legacyAudioFallbackEnabled"))
        XCTAssertFalse(p2pSource.contains("captureSystemAudio: legacyAudioFallbackEnabled || realtimeAudioSender"))
        XCTAssertTrue(p2pSource.contains("targetFPS: 1"))
        XCTAssertTrue(p2pSource.contains("captureVideoOutput: false"))
        XCTAssertTrue(p2pSource.contains("captureSystemAudio: true"))
        XCTAssertTrue(p2pSource.contains("RemoteRealtimePCM16SubmissionPipe(sender: realtimeAudioSender)"))
        XCTAssertFalse(
            p2pSource.contains("captureSystemAudio: audioRedirectionEnabled"),
            "P2P system audio capture must not automatically enter the shared remote-control channel."
        )

        let webrtcSource = try [
            String(
                contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
                encoding: .utf8
            ),
            String(
                contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCScreenStreamingPolicy.swift"),
                encoding: .utf8
            ),
            String(
                contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRealtimeAudioSenderCoordinator.swift"),
                encoding: .utf8
            )
        ].joined(separator: "\n")
        XCTAssertTrue(webrtcSource.contains("legacyAudioFallbackEnabled: legacyAudioFallbackEnabled"))
        XCTAssertTrue(webrtcSource.contains("audioRedirectionEnabled && !nativeAudioTrackEnabled && legacyAudioFallbackEnabled"))
        XCTAssertTrue(webrtcSource.contains("let shouldUseFallbackAudioChunks = Self.shouldUseWebRTCAudioFallback("))
        XCTAssertTrue(webrtcSource.contains("return shouldUseFallbackAudioChunks"))
        XCTAssertTrue(webrtcSource.contains("? strictSelectedPolicy.protectingRealtimeAudio()"))
        XCTAssertFalse(
            webrtcSource.contains("shouldUseRealtimeAudio\n                ? strictSelectedPolicy.protectingRealtimeAudio()"),
            "Dedicated WebRTC/PQC media audio runs on its own transport and must not cap the native video path."
        )
        XCTAssertTrue(webrtcSource.contains("RemoteRealtimePCM16SubmissionPipe(\n                                replayBufferedOnAttach: false\n                            )"))
        XCTAssertTrue(webrtcSource.contains("realtimePCMSubmissionPipe.attach(sender: realtimeSender.sender)"))
        XCTAssertTrue(webrtcSource.contains("captureSystemAudio: shouldUseNativeAudioTrack\n                                || shouldUseFallbackAudioChunks\n                                || shouldUseRealtimeAudio"))
        XCTAssertTrue(webrtcSource.contains("audioTxCapturePipeReady session="))

        let streamerSource = try [
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+CaptureTypes.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+VideoPolicy.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer+JPEGEncoding.swift",
            "Sources/SkyBridgeCore/RemoteControl/ScreenCaptureTelemetrySnapshot.swift"
        ].map { path in
            try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")
        XCTAssertTrue(streamerSource.contains("captureVideoOutput: Bool = true"))
        XCTAssertTrue(streamerSource.contains("Self.shouldRegisterScreenOutput("))
        XCTAssertTrue(streamerSource.contains("try stream?.addStreamOutput(streamOutput, type: .screen"))
        XCTAssertTrue(streamerSource.contains("ScreenCaptureKit 系统音频采集启动：audio-only"))
        XCTAssertTrue(streamerSource.contains("encodeCadenceFrameIfAvailable(from: sampleBuffer)"))
        XCTAssertTrue(streamerSource.contains("latestVideoPixelBufferSnapshotForCadence()"))
        XCTAssertTrue(streamerSource.contains("audioSequenceNumber = nativePCMChunk.sequenceNumber"))
        XCTAssertTrue(streamerSource.contains("SCK tx telemetry"))
        XCTAssertTrue(streamerSource.contains("sampleMs=\\(sampleMs"))
        XCTAssertTrue(streamerSource.contains("captureFPS="))
        XCTAssertTrue(streamerSource.contains("meaningfulFPS="))
        XCTAssertTrue(streamerSource.contains("encodedFPS="))
        XCTAssertTrue(streamerSource.contains("encoded=\\(snapshot.encodedFrames"))
        XCTAssertTrue(streamerSource.contains("mac-sck-tx targetFPS="))
        XCTAssertTrue(streamerSource.contains("visible=\\(snapshot.visibleWidth)x\\(snapshot.visibleHeight)"))
        XCTAssertTrue(streamerSource.contains("encodedBackingCaptureSize("))
        XCTAssertTrue(streamerSource.contains("RemoteControlSmokeStatusWriter.append"))
        let smokeWriterSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlSmokeStatusWriter.swift"),
            encoding: .utf8
        )
        let smokeAppenderSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeSmokeSupport/SmokeStatusFileAppender.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(smokeWriterSource.contains("private static let writerQueue"))
        XCTAssertTrue(smokeWriterSource.contains("writerQueue.async"))
        XCTAssertTrue(smokeWriterSource.contains("private final class WriterState: @unchecked Sendable"))
        XCTAssertTrue(smokeWriterSource.contains("import SkyBridgeSmokeSupport"))
        XCTAssertTrue(smokeWriterSource.contains("SmokeStatusFileAppender.append(data, to: statusURL)"))
        XCTAssertFalse(smokeWriterSource.contains("cachedHandle"))
        XCTAssertFalse(smokeWriterSource.contains("FileHandle(forWritingTo:"))
        XCTAssertTrue(smokeAppenderSource.contains("O_APPEND"))
        XCTAssertTrue(smokeAppenderSource.contains("O_NOFOLLOW"))
        XCTAssertTrue(smokeAppenderSource.contains("Darwin.fstat"))
        XCTAssertTrue(smokeAppenderSource.contains("S_IFREG"))
        XCTAssertTrue(smokeAppenderSource.contains("Darwin.write"))
        XCTAssertFalse(
            smokeWriterSource.contains("NSLock"),
            "Smoke status diagnostics must not serialize media hot paths behind a synchronous lock and file open/seek/write."
        )
        XCTAssertTrue(streamerSource.contains("var onCaptureTelemetry"))
        XCTAssertTrue(streamerSource.contains("onCaptureTelemetry?(snapshot)"))
        XCTAssertTrue(streamerSource.contains("static func encodePresentationTimeStamp(from sampleBuffer: CMSampleBuffer) -> CMTime"))
        XCTAssertTrue(streamerSource.contains("static func encodeFrameDuration(forConfiguredFPS fps: Int) -> CMTime"))
        XCTAssertTrue(streamerSource.contains("presentationTimeStamp: ScreenCaptureKitStreamer.encodePresentationTimeStamp(from: sampleBuffer)"))
        XCTAssertTrue(streamerSource.contains("duration: ScreenCaptureKitStreamer.encodeFrameDuration(forConfiguredFPS: owner.configuredFPS)"))
        XCTAssertFalse(
            streamerSource.contains("presentationTimeStamp: CMTime(value: CMTimeValue(Date().timeIntervalSince1970"),
            "VT encode timestamps must come from ScreenCaptureKit sample PTS, not wall-clock Date."
        )
        XCTAssertFalse(
            streamerSource.contains("duration: CMTime.zero"),
            "Realtime VT encode should carry a non-zero frame duration derived from the requested FPS."
        )
        let sckDiagnosticsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteDesktop/WebRTCMediaDiagnostics.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sckDiagnosticsSource.contains("sckCaptured"))
        XCTAssertTrue(sckDiagnosticsSource.contains("sckEncodedFPS"))
        XCTAssertTrue(sckDiagnosticsSource.contains("sckEncodeLatencyP95Ms"))
        XCTAssertTrue(streamerSource.contains("sourceFrameRefcon: encodeTimingRefcon"))
        let remoteControlSource = try remoteControlSource(root: root)
        XCTAssertTrue(remoteControlSource.contains("mac-remote-frame-tx peer="))
        XCTAssertTrue(remoteControlSource.contains("avgSendMs="))
        XCTAssertTrue(remoteControlSource.contains("maxSendMs="))
        XCTAssertTrue(remoteControlSource.contains("source=encoded-direct-pump"))
        XCTAssertTrue(remoteControlSource.contains("scheduleGapMaxMs="))
        XCTAssertTrue(remoteControlSource.contains("scheduleJitterMaxMs="))
        XCTAssertTrue(remoteControlSource.contains("completionGapMaxMs="))
        XCTAssertTrue(remoteControlSource.contains("RemoteControlFrameSequenceGenerator"))
        XCTAssertTrue(remoteControlSource.contains("RemoteControlEncodedFrameSubmissionPipe"))
        XCTAssertTrue(remoteControlSource.contains("bufferingPolicy: .bufferingNewest(Self.bufferedFrameLimit)"))
        XCTAssertTrue(remoteControlSource.contains("mac-video-submit-pipe result=dropped reason=bounded-newest"))
        XCTAssertTrue(remoteControlSource.contains("let videoFrameSubmissionPipe = RemoteControlEncodedFrameSubmissionPipe("))
        XCTAssertTrue(remoteControlSource.contains("videoFrameSubmissionPipe.submit(frame)"))
        XCTAssertTrue(remoteControlSource.contains("sequenceNumber: videoFrameSequence.next()"))
        XCTAssertTrue(remoteControlSource.contains("sequenceNumber: frame.sequenceNumber"))
        XCTAssertFalse(
            remoteControlSource.contains("Task(priority: .userInitiated) {\n                await outboundFramePump.submitFrame(frame)\n            }"),
            "Encoded video frames must use a single high-priority submission pipe instead of spawning one Swift task per frame."
        )
        XCTAssertFalse(
            remoteControlSource.contains("peer.queue.async {\n                let frame = ScreenData("),
            "Encoded video frames must enter the sender pump directly so peer queue stalls cannot be hidden from telemetry."
        )
        XCTAssertTrue(streamerSource.contains("consumeEncodeFrameTimingRefcon"))
        XCTAssertTrue(streamerSource.contains("encodeLatencyP95Ms"))
        XCTAssertTrue(streamerSource.contains("actualEncodeLatencyP95Ms"))
        XCTAssertTrue(streamerSource.contains("encodeSubmissionDelayMaxMs"))
        XCTAssertTrue(streamerSource.contains("encodeSubmissionBacklogMax"))
        XCTAssertTrue(webrtcSource.contains("kind: \"sckTxTelemetry\""))
        XCTAssertTrue(webrtcSource.contains("sckEncodeLatencyP95Ms: snapshot.encodeLatencyP95Ms"))
        XCTAssertTrue(webrtcSource.contains("probable: snapshot.meaningfulSamples == 0"))

        let senderSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteDesktop/RealtimeMediaAudio.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(senderSource.contains("final class RemoteRealtimePCM16SubmissionPipe"))
        XCTAssertTrue(senderSource.contains("func attach(sender: RemoteRealtimeMediaAudioSender)"))
        XCTAssertTrue(senderSource.contains("pendingBeforeAttach"))
        XCTAssertTrue(senderSource.contains("droppedBeforeAttach"))
        XCTAssertTrue(senderSource.contains("Task(priority: .utility)"))
        XCTAssertFalse(
            senderSource.contains("Task(priority: .userInitiated)"),
            "Realtime audio encoding should not compete with screen capture and video rendering at userInitiated priority."
        )
        XCTAssertTrue(senderSource.contains("for await chunk in stream"))
        XCTAssertTrue(senderSource.contains("await sender.submitPCM16Chunk(chunk)"))
        XCTAssertTrue(senderSource.contains("let frameIntervalNanos = UInt64(max(1, profile.frameDurationMs)) * 1_000_000"))
        XCTAssertTrue(senderSource.contains("DispatchTime.now().uptimeNanoseconds"))
        XCTAssertTrue(senderSource.contains("senderCatchUpFrameLimit"))
        XCTAssertTrue(senderSource.contains("senderCatchUpBacklogFrameTarget"))
        XCTAssertTrue(senderSource.contains("sentOrAttemptedFrames"))
        XCTAssertTrue(senderSource.contains("interfaceBindingIdentity: SkyBridgeRealtimeMediaInterfaceBinding.Identity? = nil"))
        XCTAssertTrue(senderSource.contains("self.interfaceBindingIdentity == interfaceBindingIdentity"))
        XCTAssertTrue(senderSource.contains("func diagnosticSnapshot() -> RealtimeMediaAudioSenderDiagnosticSnapshot"))
        XCTAssertTrue(senderSource.contains("func close(reason: String = \"unspecified\") async"))
        XCTAssertTrue(senderSource.contains("kind: \"audioTxSenderClosed\""))
        XCTAssertTrue(senderSource.contains("failureReason: reason"))
        XCTAssertTrue(senderSource.contains("RemoteControlSmokeStatusWriter.append("))
        XCTAssertTrue(senderSource.contains("audioTxSenderClose session="))
        XCTAssertTrue(senderSource.contains("reason=\\(Self.sanitizeSmokeField(reason))"))
        XCTAssertTrue(senderSource.contains("sentTotal=\\(sentPackets)"))
        XCTAssertTrue(senderSource.contains("sendFail=\\(sendFailedPackets)"))
        XCTAssertTrue(senderSource.contains("let queuedFramesAtClose = pendingPCM.count / max(frameBytes, 1)"))
        XCTAssertTrue(senderSource.contains("let queuedMsAtClose = queuedFramesAtClose * profile.frameDurationMs"))
        XCTAssertTrue(senderSource.contains("queuedFrames=\\(queuedFramesAtClose)"))
        XCTAssertTrue(senderSource.contains("queuedMs=\\(queuedMsAtClose)"))
        XCTAssertTrue(senderSource.contains("endpoint=\\(Self.sanitizeSmokeField(endpoint.host)):\\(endpoint.port)"))
        XCTAssertTrue(senderSource.contains("audioTxCapturedTotal: capturedPackets"))
        XCTAssertTrue(senderSource.contains("audioTxEncodedTotal: encodedPackets"))
        XCTAssertTrue(senderSource.contains("private let diagnosticSessionId: String"))
        XCTAssertTrue(senderSource.contains("diagnosticSessionId: String? = nil"))
        XCTAssertTrue(senderSource.contains("self.diagnosticSessionId = diagnosticSessionId ?? sessionId"))
        XCTAssertTrue(senderSource.contains("kind: \"audioRxReceiverClosed\""))
        XCTAssertTrue(senderSource.contains("audioRxRecv: receivedPackets"))
        XCTAssertTrue(senderSource.contains("audioRxDecoded: decodedPackets"))
        XCTAssertTrue(senderSource.contains("audioRxPlayed: playedPackets"))
        XCTAssertTrue(senderSource.contains("audioRxRejected: rejectedPackets"))
        XCTAssertTrue(senderSource.contains("probable: receivedPackets == 0 ? \"audio-rx-no-positive-evidence\" : nil"))
        XCTAssertTrue(
            senderSource.contains("self.diagnosticSessionId = sessionId"),
            "Realtime audio receiver close diagnostics must preserve the session id for zero-rx correlation."
        )
        XCTAssertTrue(senderSource.contains("if didPrimeTelemetryWindow"))
        XCTAssertTrue(senderSource.contains("sessionId: diagnosticSessionId"))
        XCTAssertTrue(senderSource.contains("RemoteRealtimeSyntheticPCM16ToneSource"))
        XCTAssertTrue(senderSource.contains("emptyPacingTicks"))
        XCTAssertTrue(senderSource.contains("interSendP95Ms="))
        XCTAssertTrue(senderSource.contains("interSendMaxMs="))
        XCTAssertTrue(senderSource.contains("sendPacketWithRedundancy"))
        XCTAssertTrue(senderSource.contains("redundantCopies="))
        XCTAssertTrue(senderSource.contains("refreshRelayBinding(token)"))
        XCTAssertTrue(senderSource.contains("relayBindingRefreshIntervalNanos"))
        XCTAssertTrue(senderSource.contains("kind: \"audioTxRolling\""))
        XCTAssertTrue(senderSource.contains("audioTxCaptured: captureWindow"))
        XCTAssertTrue(senderSource.contains("audioTxEncoded: encodeWindow"))
        XCTAssertTrue(senderSource.contains("audioTxSent: sendWindow"))
        XCTAssertTrue(senderSource.contains("audioTxCapturedTotal: capturedPackets"))
        XCTAssertTrue(senderSource.contains("audioTxEncodedTotal: encodedPackets"))
        XCTAssertTrue(senderSource.contains("audioTxSentTotal: sentPackets"))
        XCTAssertTrue(senderSource.contains("validationMode: mode.rawValue"))

        let audioSenderFailure = try XCTUnwrap(
            remoteControlSource.range(of: "audioTxSenderStartFailed session=")
        )
        let strictFailure = try XCTUnwrap(
            remoteControlSource.range(
                of: "await failStrictMediaCapture(",
                range: audioSenderFailure.upperBound..<remoteControlSource.endIndex
            )
        )
        let videoCaptureStart = try XCTUnwrap(
            remoteControlSource.range(
                of: "try await streamer.start(",
                range: strictFailure.upperBound..<remoteControlSource.endIndex
            )
        )
        XCTAssertLessThan(audioSenderFailure.lowerBound, strictFailure.lowerBound)
        XCTAssertLessThan(strictFailure.lowerBound, videoCaptureStart.lowerBound)
        XCTAssertTrue(remoteControlSource.contains("action=\\(strictAudioRequired ? \"strict-fail-closed\" : \"video-preserved\")"))
        XCTAssertFalse(
            remoteControlSource.contains("P2P PQC media audio sender unavailable; keeping video-only"),
            "A requested strict audio stream must not silently continue as video-only after route or UDP startup failure."
        )

        let iosRemoteDesktopSource = try String(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(iosRemoteDesktopSource.contains(".resolveAuthenticatedControlPath("))
        XCTAssertTrue(iosRemoteDesktopSource.contains("interfaceBinding: interfaceBinding"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("preparedInterfaceBinding = interfaceBinding"))
        XCTAssertTrue(
            iosRemoteDesktopSource.contains(
                "realtimeMediaAudioInterfaceBinding = preparedInterfaceBinding"
            )
        )
        XCTAssertTrue(iosRemoteDesktopSource.contains("interfaceBound=1 interfaceClass=infrastructure scopeMatch=1 transport=lan"))
        XCTAssertTrue(
            remoteControlSource.contains(
                "let interfaceBinding = try SkyBridgeRealtimeMediaInterfaceBinding"
            )
        )
        XCTAssertTrue(
            remoteControlSource.contains(
                "let receiver = SkyBridgeUDPRealtimeMediaReceiver(\n            interfaceBinding: interfaceBinding"
            )
        )
        XCTAssertTrue(remoteControlSource.contains("let reuseKey = RemoteControlRealtimeAudioReceiverReuseKey("))
        XCTAssertTrue(remoteControlSource.contains("peerIdentity: ObjectIdentifier(peer)"))
        XCTAssertTrue(remoteControlSource.contains("secureSessionId: keys.sessionId"))
        XCTAssertTrue(remoteControlSource.contains("mode: mode"))
        XCTAssertTrue(remoteControlSource.contains("interfaceBindingIdentity: interfaceBinding.identity"))
        XCTAssertTrue(remoteControlSource.contains("p2pRealtimeAudioReceiverReuseKey == reuseKey"))
        XCTAssertTrue(remoteControlSource.contains("mediaFallbackPolicy: \"fail-fast\""))
        XCTAssertTrue(remoteControlSource.contains("audioRxReceiverStartFailed reason="))
        XCTAssertTrue(remoteControlSource.contains("if failureAction == .failSession"))
        XCTAssertTrue(
            remoteControlSource.contains(
                "guard isCurrentPeer(peer) else { return }"
            )
        )
        XCTAssertFalse(
            remoteControlSource.contains(
                "!(error is CancellationError)"
            ),
            "A CancellationError owned by the current peer must enter strict failure handling."
        )
        XCTAssertTrue(
            remoteControlSource.contains(
                "p2p-realtime-audio-receiver-start-failed-before-install"
            )
        )
        XCTAssertTrue(
            remoteControlSource.contains(
                "p2p-realtime-audio-receiver-start-stale-before-install"
            )
        )
        XCTAssertTrue(
            remoteControlSource.contains(
                "let currentKeys = peer.sessionKeys,"
            )
        )
        XCTAssertTrue(
            remoteControlSource.contains(
                "Self.isSameRemoteControlSecureSession(currentKeys, keys)"
            )
        )
        XCTAssertTrue(
            remoteControlSource.contains(
                "receiver.stop()\n            await renderer.close("
            )
        )
        XCTAssertFalse(
            remoteControlSource.contains(
                "P2P PQC media audio receiver unavailable; keeping video-only"
            )
        )
        XCTAssertTrue(
            iosRemoteDesktopSource.contains(
                "RemoteControlRealtimeMediaStartupPolicy.failureAction("
            )
        )
        XCTAssertTrue(
            iosRemoteDesktopSource.contains(
                "await self.handleTransportFailure(\n                        \"realtime media audio startup failed [\\(reason)]\""
            )
        )
        XCTAssertTrue(
            iosRemoteDesktopSource.contains(
                "receiver-start-failed-before-install"
            )
        )
        XCTAssertFalse(
            iosRemoteDesktopSource.contains(
                "PQC media audio receiver unavailable; keeping video-only"
            )
        )

        XCTAssertTrue(webrtcSource.contains("diagnosticSessionId: sessionID"))
        XCTAssertTrue(webrtcSource.contains("kind: \"videoStats\""))
        XCTAssertTrue(webrtcSource.contains("framesEncoded: rtcStats.framesEncoded"))
        XCTAssertTrue(webrtcSource.contains("framesSent: rtcStats.framesSent"))
        XCTAssertTrue(webrtcSource.contains("codec: rtcStats.codec"))
        XCTAssertTrue(webrtcSource.contains("encoder: rtcStats.encoderImplementation"))
        XCTAssertTrue(webrtcSource.contains("targetBitrate: rtcStats.targetBitrate"))
        XCTAssertTrue(webrtcSource.contains("availableOutgoingBitrate: rtcStats.availableOutgoingBitrate"))
        XCTAssertTrue(webrtcSource.contains("currentRTT: rtcStats.currentRoundTripTime"))
        XCTAssertTrue(webrtcSource.contains("remotePacketsLost: rtcStats.remotePacketsLost"))

        let diagnosticsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteDesktop/WebRTCMediaDiagnostics.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            diagnosticsSource.contains(
                "let filename = \"webrtc-media-\\(safeSessionReference).jsonl\""
            )
        )
        XCTAssertTrue(diagnosticsSource.contains("payload.removeValue(forKey: \"session_id\")"))
        XCTAssertTrue(diagnosticsSource.contains("payload[\"session_ref\"] = safeSessionReference(event.sessionId)"))
        XCTAssertTrue(diagnosticsSource.contains("case videoFPS = \"video_fps\""))
        XCTAssertTrue(diagnosticsSource.contains("case framesEncoded"))
        XCTAssertTrue(diagnosticsSource.contains("case framesSent"))
        XCTAssertTrue(diagnosticsSource.contains("case codec"))
        XCTAssertTrue(diagnosticsSource.contains("case encoder"))
        XCTAssertTrue(diagnosticsSource.contains("case targetBitrate"))
        XCTAssertTrue(diagnosticsSource.contains("case availableOutgoingBitrate"))
        XCTAssertTrue(diagnosticsSource.contains("audioTxCaptured"))
        XCTAssertTrue(diagnosticsSource.contains("audioTxSentTotal"))
    }

    func testP2PRemoteDesktopVideoTransportUsesTCPNoDelayAndSendLatencyTelemetry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let remoteControlSource = try remoteControlSource(root: root)
        XCTAssertTrue(remoteControlSource.contains("try await sendRemoteFrame(payload, packetType: .audio)"))
        XCTAssertTrue(remoteControlSource.contains("makeOutboundRemoteFrame("))
        XCTAssertTrue(remoteControlSource.contains("sampleMs=\\(sampleMs"))
        XCTAssertTrue(remoteControlSource.contains("sentFPS=\\(sentFPS)"))
        XCTAssertTrue(remoteControlSource.contains("submitted=\\(snapshot.submittedFrames)"))
        XCTAssertTrue(remoteControlSource.contains("dropped=\\(snapshot.droppedFrames)"))
        XCTAssertTrue(remoteControlSource.contains("avgSendMs=\\(averageLatency)"))
        XCTAssertTrue(remoteControlSource.contains("maxSendMs=\\(maxLatency)"))
        XCTAssertTrue(remoteControlSource.contains("chunkCapBytes=\\(Self.maxChunkedScreenFrameMessageBytes)"))
        XCTAssertTrue(remoteControlSource.contains("chunkSend=\\(chunkSendMode)"))
        XCTAssertTrue(remoteControlSource.contains("chunkedFrames=\\(snapshot.chunkedFrames)"))
        XCTAssertTrue(remoteControlSource.contains("sentChunks=\\(snapshot.sentChunks)"))
        XCTAssertTrue(remoteControlSource.contains("maxChunksPerFrame=\\(snapshot.maxChunksPerFrame)"))
        XCTAssertTrue(remoteControlSource.contains("private static let maxInFlightVideoSends = 3"))
        XCTAssertTrue(remoteControlSource.contains("private static let maxChunkedContentProcessedBacklogFrames = 18"))
        XCTAssertTrue(remoteControlSource.contains("private static let maxChunkedContentProcessedBacklogBytes = 12 * 256 * 1024"))
        XCTAssertTrue(remoteControlSource.contains("private static let maxChunkedVideoFramesPerDrain = 1"))
        XCTAssertTrue(remoteControlSource.contains("private static let maxChunkedHighFPSVideoFramesPerDrain = 1"))
        XCTAssertTrue(remoteControlSource.contains("private static let boundedCadenceCatchUpFrameAgeLimitMs: Double = 50"))
        XCTAssertFalse(remoteControlSource.contains("maxChunkedStaleQueueCatchUpFramesPerDrain"))
        XCTAssertFalse(remoteControlSource.contains("staleQueuedFrameCatchUpEligible"))
        XCTAssertTrue(remoteControlSource.contains("let staleQueueCatchUpBudgetActive = false"))
        XCTAssertTrue(remoteControlSource.contains("private var effectiveMaxContentProcessedBacklogFrames: Int"))
        XCTAssertTrue(remoteControlSource.contains("usesChunkedScreenFrameWire ? Self.maxChunkedContentProcessedBacklogFrames : Self.maxInFlightVideoSends"))
        XCTAssertTrue(remoteControlSource.contains("private static let maxChunkedScreenFrameMessageBytes = 256 * 1024"))
        XCTAssertTrue(remoteControlSource.contains("let contentBacklogFull = isContentProcessedBacklogFull"))
        XCTAssertTrue(remoteControlSource.contains("let delay = isContentProcessedBacklogFull"))
        XCTAssertTrue(remoteControlSource.contains("noteVideoScheduleBudget(0, elapsedCadenceSlots: elapsedCadenceSlots)"))
        XCTAssertTrue(remoteControlSource.contains("usesChunkedScreenFrameWire = frameTransport == .binaryWire"))
        XCTAssertTrue(remoteControlSource.contains("makeOutboundScreenWireMessages(from: outboundData)"))
        XCTAssertTrue(remoteControlSource.contains("RemoteDesktopScreenFrameWire.encodeChunkEnvelope("))
        XCTAssertTrue(remoteControlSource.contains("Self.sendFramedMessages(\n            wireMessages,\n            over: connection,\n            mode: sendMode"))
        XCTAssertTrue(remoteControlSource.contains("sendFramedMessagesBatchedInOrder("))
        XCTAssertTrue(remoteControlSource.contains("connection.batch {"))
        XCTAssertTrue(remoteControlSource.contains("FramedMessageBatchCompletionState"))
        XCTAssertTrue(remoteControlSource.contains("RemoteDesktopStreamConfiguration.screenChannelWireFormatSBC2ChunkedV1"))
        XCTAssertTrue(remoteControlSource.contains("completeVideoFrameSend("))
        XCTAssertTrue(remoteControlSource.contains("inFlight=\\(snapshot.inFlightVideoSends)"))
        XCTAssertTrue(remoteControlSource.contains("inFlightMax=\\(snapshot.inFlightVideoSendsMax)"))
        XCTAssertTrue(remoteControlSource.contains("contentBacklogMax=\\(snapshot.inFlightVideoSendsMax)"))
        XCTAssertTrue(remoteControlSource.contains("contentBacklogBytesMax=\\(snapshot.contentBacklogBytesMax)"))
        XCTAssertTrue(remoteControlSource.contains("contentBacklogByteLimit=\\(snapshot.contentBacklogByteLimit)"))
        XCTAssertTrue(remoteControlSource.contains("maxFramesPerDrain=\\(snapshot.maxVideoFramesPerDrain)"))
        XCTAssertTrue(remoteControlSource.contains("scheduleBudgetMax=\\(snapshot.scheduleBudgetMax)"))
        XCTAssertTrue(remoteControlSource.contains("missedCadenceSlotsMax=\\(snapshot.missedCadenceSlotsMax)"))
        XCTAssertTrue(remoteControlSource.contains("contentBacklogFull=\\(snapshot.contentBacklogFullEvents)"))
        XCTAssertTrue(remoteControlSource.contains("oldestContentBacklogMs=\\(String(format: \"%.1f\", snapshot.oldestContentBacklogMs))"))
        XCTAssertTrue(remoteControlSource.contains("queueAgeMaxMs=\\(String(format: \"%.1f\", snapshot.queuedFrameAgeMaxMs))"))
        XCTAssertTrue(remoteControlSource.contains("dequeuedAgeMaxMs=\\(String(format: \"%.1f\", snapshot.dequeuedFrameAgeMaxMs))"))
        XCTAssertTrue(remoteControlSource.contains("queuedMax=\\(snapshot.queuedFramesMax)"))
        XCTAssertTrue(remoteControlSource.contains("paceWake=\\(snapshot.paceWakeDrains)"))
        XCTAssertTrue(remoteControlSource.contains("boundedCadenceCatchUp=\\(snapshot.boundedCadenceCatchUpFrames)"))
        XCTAssertTrue(remoteControlSource.contains("staleQueueCatchUp=\\(snapshot.staleQueueCatchUpFrames)"))
        XCTAssertTrue(remoteControlSource.contains("writerClock=dispatch-source-userinteractive"))
        XCTAssertTrue(remoteControlSource.contains("sendScheduler=dispatch-clock-only"))
        XCTAssertTrue(remoteControlSource.contains("encodedToSubmitMaxMs=\\(encodedToSubmitMaxMs)"))
        XCTAssertTrue(remoteControlSource.contains("submitGapMaxMs=\\(submitGapMaxMs)"))
        XCTAssertTrue(remoteControlSource.contains("clockFireToDrainMaxMs=\\(clockFireToDrainMaxMs)"))
        XCTAssertTrue(remoteControlSource.contains("final class RemoteControlVideoPaceClock"))
        XCTAssertTrue(remoteControlSource.contains("DispatchSource.makeTimerSource(flags: .strict, queue: queue)"))
        XCTAssertTrue(remoteControlSource.contains("leeway: .nanoseconds(100_000)"))
        XCTAssertTrue(remoteControlSource.contains("interval: videoSendInterval"))
        XCTAssertFalse(remoteControlSource.contains("try await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded(.up)))"))
        XCTAssertTrue(remoteControlSource.contains("scheduleVideoPaceWakeIfNeeded()"))
        XCTAssertTrue(remoteControlSource.contains("await drainIfNeeded(maxVideoFramesToSchedule: videoScheduleBudget(now: firedAt))"))
        XCTAssertTrue(remoteControlSource.contains("catchUp=bounded-cadence-catch-up-no-stale"))
        XCTAssertTrue(remoteControlSource.contains("writerClockStrict=1"))

        let remoteControlManagerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(remoteControlManagerSource.contains("beginRealtimeStreamingActivity(for: peer, strictMediaFallbacks: strictMediaFallbacks)"))
        XCTAssertTrue(remoteControlManagerSource.contains("ProcessInfo.processInfo.beginActivity("))
        XCTAssertTrue(remoteControlManagerSource.contains(".latencyCritical"))
        XCTAssertTrue(remoteControlManagerSource.contains("mac-remote-realtime-activity active=1 appNapDisabled=1"))

        let remoteServerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlServer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(remoteServerSource.contains("tcp.noDelay = true"))
        XCTAssertFalse(remoteServerSource.contains("parameters.serviceClass = .interactiveVideo"))
        XCTAssertTrue(remoteServerSource.contains("qos: .userInteractive"))
        XCTAssertTrue(remoteServerSource.contains("listener.start(queue: queue)"))
        XCTAssertTrue(remoteServerSource.contains("connection.start(queue: connectionQueue)"))
        XCTAssertTrue(
            remoteServerSource.contains(
                "ApplePeerConnectivityPolicy.remoteControlMediaAllowsPeerToPeer"
            )
        )
        XCTAssertFalse(remoteServerSource.contains("parameters.includePeerToPeer = true"))
        XCTAssertTrue(remoteServerSource.contains("BonjourInteropContract.makeCanonicalAdvertisementTXT("))
        XCTAssertFalse(remoteServerSource.contains("LocalNetworkAdvertisementAddressProvider.attachAddressTXT"))

        let fileTransferListenerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(fileTransferListenerSource.contains("parameters.includePeerToPeer = true"))
        XCTAssertTrue(fileTransferListenerSource.contains("BonjourInteropContract.makeCanonicalAdvertisementTXT("))
        XCTAssertFalse(fileTransferListenerSource.contains("LocalNetworkAdvertisementAddressProvider.attachAddressTXT"))

        XCTAssertTrue(LocalNetworkAdvertisementAddressProvider.isAdvertisableRoutableLANAddress("192.168.31.20"))
        XCTAssertFalse(LocalNetworkAdvertisementAddressProvider.isAdvertisableRoutableLANAddress("169.254.10.20"))
        XCTAssertFalse(LocalNetworkAdvertisementAddressProvider.isAdvertisableRoutableLANAddress("fe80::468:f5a1:462b:29d3%en0"))

        let iosRemoteDesktopSource = try [
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift",
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopViewerStreamConfigurationFactory.swift"
        ].map { path in
            try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")
        let iosSecurePipelineSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopLANSecureReceivePipeline.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(iosRemoteDesktopSource.contains("tcp.noDelay = true"))
        XCTAssertFalse(iosRemoteDesktopSource.contains("parameters.serviceClass = .interactiveVideo"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("activeTransportMode == .crossNetwork || activeTransportMode == .lan"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("RemoteDesktopScreenFrameWire.ChunkedPayloadReassembler"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("unwrapLANChunkedPayloadIfNeeded("))
        XCTAssertTrue(iosRemoteDesktopSource.contains("handleLANSBC2FrameDrops"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("lan-sbc2-frame-drop reason="))
        XCTAssertTrue(iosRemoteDesktopSource.contains("screenWire=\\(lanInboundScreenWireFormat)"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("sbc2Frames=\\(lanInboundChunkedScreenFramesInWindow)"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("sbc2Chunks=\\(lanInboundScreenChunksInWindow)"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("parser=\\(lanInboundReceiveParserMode)"))
        XCTAssertTrue(iosSecurePipelineSource.contains("actor LANRemoteSecureReceivePipeline"))
        XCTAssertTrue(iosSecurePipelineSource.contains("RemoteControlSecureEnvelope.open("))
        XCTAssertTrue(iosRemoteDesktopSource.contains("pipeline.appendAndDrain("))
        XCTAssertTrue(iosRemoteDesktopSource.contains("private var needsLANReceiveBufferDrain = false"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("needsLANReceiveBufferDrain = true"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("let shouldDrainAgain = needsLANReceiveBufferDrain || hasCompleteLANFramedPayloadPending()"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("await self?.processLANReceiveBuffer(from: connection)"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("let shouldContinueReceiving = error == nil && !isComplete"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("self?.receiveNextLANChunk(from: connection, secureContext: secureContext)"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("private final class LANSecureReceiveScheduler"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("lanSecureReceiveScheduler.scheduleChunk("))
        XCTAssertTrue(iosRemoteDesktopSource.contains("await previous?.value"))
        XCTAssertFalse(iosRemoteDesktopSource.contains("if error == nil, !isComplete {\n                self?.receiveNextLANChunk(from: connection)\n            }"))
        XCTAssertTrue(iosRemoteDesktopSource.contains("private func hasCompleteLANFramedPayloadPending() -> Bool"))
    }

    func testRealtimeAudioEndpointChangesRestartSenderAndViewerKeepsEndpointStable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let p2pSource = try [
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift",
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlStreamRequestPolicy.swift"
        ].map { path in
            try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
        }.joined(separator: "\n")
        XCTAssertTrue(
            p2pSource.contains("previous.mediaAudioEndpoint != current.mediaAudioEndpoint"),
            "If the viewer advertises a new UDP audio endpoint, the host must restart capture so the realtime audio sender does not keep sending to a stale port."
        )
        XCTAssertTrue(p2pSource.contains("previous.mediaSessionId != current.mediaSessionId"))
        XCTAssertTrue(p2pSource.contains("previous.audioTransport != current.audioTransport"))
        XCTAssertTrue(p2pSource.contains("P2P PQC media audio sender reused across video refresh"))
        XCTAssertTrue(p2pSource.contains("didReuseRealtimeAudioSender"))
        XCTAssertFalse(
            p2pSource.contains("if #available(macOS 14.0, *), let existingSender = peer.realtimeAudioSender {\n            await existingSender.close()"),
            "Video capture restarts must not unconditionally close a stable PQC audio sender; that causes UDP source migration and sequence resets on iOS."
        )

        let iosViewerSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"),
            encoding: .utf8
        )
        let iosRemoteDesktopMediaPolicySource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopCrossNetworkMediaPolicy.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(iosViewerSource.contains("private var realtimeMediaAudioEndpoint: SkyBridgeMediaEndpoint?"))
        XCTAssertTrue(iosViewerSource.contains("let endpoint = realtimeMediaAudioEndpoint"))
        XCTAssertTrue(
            iosViewerSource.contains("snapshot = lanRealtimeMediaKeySnapshot()"),
            "LAN realtime audio must be bound to the remote-desktop secure channel keys, not the separate file-transfer/P2P session keys."
        )
        XCTAssertTrue(iosRemoteDesktopMediaPolicySource.contains("skybridge-lan-remote-media-session-v1"))
        XCTAssertFalse(
            iosViewerSource.contains("let endpoint = lastSentStreamConfiguration?.mediaAudioEndpoint"),
            "The iOS viewer must keep the live UDP receiver endpoint stable across first-frame refresh pushes before lastSentStreamConfiguration settles."
        )
        XCTAssertFalse(
            iosViewerSource.contains("connectionManager.realtimeMediaKeySnapshot(for: deviceId)"),
            "Using the general P2P connection keys causes SBMA authentication failures because LAN remote desktop performs its own secure-channel handshake."
        )
    }

    func testP2PViewerAdvertisesAudioOnlyAfterRealtimeEndpointIsReady() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let p2pSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            p2pSource.contains(
                "let audioRedirectionEnabled = settings.interactionSettings.enableAudioRedirection"
            )
        )
        XCTAssertTrue(p2pSource.contains("let realtimeMediaAudioReady = audioRedirectionEnabled"))
        XCTAssertTrue(p2pSource.contains("&& mediaAudioEndpoint != nil"))
        XCTAssertTrue(p2pSource.contains("&& mediaSessionId != nil"))
        XCTAssertTrue(p2pSource.contains("audioRedirectionEnabled: realtimeMediaAudioReady"))
        XCTAssertTrue(p2pSource.contains("audioTransport: realtimeMediaAudioReady"))
        XCTAssertTrue(p2pSource.contains("audioMode: realtimeMediaAudioReady ? mediaAudioMode.rawValue : nil"))
        XCTAssertTrue(p2pSource.contains("mediaSessionId: realtimeMediaAudioReady ? mediaSessionId : nil"))
        XCTAssertTrue(p2pSource.contains("mediaAudioEndpoint: realtimeMediaAudioReady ? mediaAudioEndpoint : nil"))
    }

    func testIOSRealtimeAudioIsJitterPacedAndMetalSkipsBeforeDrawable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let audioSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RealtimeMediaAudio.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(audioSource.contains("private var jitterBuffer: SkyBridgeMediaJitterBuffer<SkyBridgeMediaOpenedPacket>"))
        XCTAssertTrue(audioSource.contains("private var playoutTask: Task<Void, Never>?"))
        XCTAssertTrue(audioSource.contains("private func playoutTick(maxFrames dueFrames: Int) async"))
        XCTAssertTrue(audioSource.contains("private func playoutNextFrame(allowPLCGap: Bool) async -> Bool"))
        XCTAssertTrue(audioSource.contains("private var playoutBurstFrameLimit: Int"))
        XCTAssertTrue(audioSource.contains("private var gapPlayoutDeficitThresholdPacketCount: Int"))
        XCTAssertTrue(audioSource.contains("private var gapPlayoutBufferedThresholdPacketCount: Int"))
        XCTAssertTrue(audioSource.contains("bufferedFrameCount >= gapPlayoutBufferedThresholdPacketCount"))
        XCTAssertTrue(audioSource.contains("lowWaterMs = 700"))
        XCTAssertTrue(audioSource.contains("min(96, deficitMs / frameDurationMs)"))
        XCTAssertTrue(audioSource.contains("min(32, effectiveJitterMaxMs / profile.frameDurationMs)"))
        XCTAssertTrue(audioSource.contains("var nextDeadline = DispatchTime.now().uptimeNanoseconds + frameIntervalNanos"))
        XCTAssertTrue(audioSource.contains("let overdueNanos = wokeAt > nextDeadline ? wokeAt - nextDeadline : 0"))
        XCTAssertTrue(audioSource.contains("let dueFrames = max(1, Int(overdueNanos / frameIntervalNanos) + 1)"))
        XCTAssertTrue(audioSource.contains("nextDeadline &+= UInt64(dueFrames) * frameIntervalNanos"))
        XCTAssertTrue(audioSource.contains("while scheduledFrames < frameLimit"))
        XCTAssertTrue(audioSource.contains("jitterBuffer.popReadyOrGap(now: now)"))
        XCTAssertTrue(audioSource.contains("jitterBuffer.popReadyFrame(now: now)"))
        XCTAssertTrue(audioSource.contains("case .gap(let sequence):"))
        XCTAssertTrue(audioSource.contains("rx-ordering-gap-wait"))
        XCTAssertTrue(audioSource.contains("case .frame(let frame):"))
        XCTAssertTrue(audioSource.contains("consecutivePLCFrames < maxConsecutivePLCFrameCount"))
        XCTAssertTrue(audioSource.contains("consecutivePLCFrames = 0"))
        XCTAssertFalse(
            audioSource.contains("nextPlayoutSequence"),
            "The iOS PQC receiver must not maintain a second playout sequence clock beside the jitter buffer."
        )
        XCTAssertFalse(
            audioSource.contains("heldPlayoutFrame"),
            "The iOS PQC receiver should not park jitter-buffer frames while independently advancing PLC state."
        )
        XCTAssertTrue(audioSource.contains("private var lockedRemoteEndpoint: SkyBridgeMediaEndpoint?"))
        XCTAssertTrue(audioSource.contains("commonFormat: .pcmFormatFloat32"))
        XCTAssertTrue(audioSource.contains("interleaved: false"))
        XCTAssertTrue(audioSource.contains("private final class RealtimePCMRenderBuffer"))
        XCTAssertTrue(audioSource.contains("AVAudioSourceNode"))
        XCTAssertTrue(audioSource.contains("pqc-opus-source-node-ring"))
        XCTAssertTrue(audioSource.contains("output[frame] = 0"))
        XCTAssertTrue(audioSource.contains("engine.prepare()"))
        XCTAssertTrue(audioSource.contains("engine.start()"))
        XCTAssertTrue(audioSource.contains("private func configureAudioSession("))
        XCTAssertTrue(audioSource.contains("private func setSessionPreferences("))
        XCTAssertTrue(audioSource.contains("activateSession(session, stage: \"playback_set_active\")"))
        XCTAssertTrue(audioSource.contains("PQC media audio session stage=\\(stage)"))
        XCTAssertTrue(audioSource.contains("PQC media audio session active with non-interrupting ambient category"))
        XCTAssertTrue(audioSource.contains("[domain=\\(nsError.domain) code=\\(nsError.code)]"))
        XCTAssertFalse(
            audioSource.contains("try session.setPreferredSampleRate(Double(profile.sampleRate))\n        try session.setPreferredIOBufferDuration"),
            "AVAudioSession preferences are not contractual capabilities; preference failures should be logged with domain/code instead of killing PQC media playback."
        )
        XCTAssertFalse(
            audioSource.contains("PQC media audio player unavailable: \\(error.localizedDescription)"),
            "Audio-session activation failures need domain/code diagnostics and throttled logging; localized text alone hides the production root cause."
        )
        XCTAssertFalse(audioSource.contains("scheduleBuffer("))
        XCTAssertFalse(
            audioSource.contains("resetPlayerQueue(playerNode, reason: \"playback-backpressure\")"),
            "Soft realtime audio backpressure should drop the newest frame, not reset AVAudioPlayerNode and destroy playout continuity."
        )
        XCTAssertTrue(audioSource.contains("overflowEvents &+= 1"))
        XCTAssertTrue(audioSource.contains("underflowEvents &+= 1"))
        XCTAssertTrue(audioSource.contains("return false"))
        XCTAssertTrue(audioSource.contains("private func acceptAuthenticatedSource("))
        XCTAssertTrue(audioSource.contains("guard let sourceDecision = acceptAuthenticatedSource("))
        XCTAssertTrue(audioSource.contains("if sourceDecision == .migrated"))
        XCTAssertTrue(audioSource.contains("await resetReceiveOrderingState(reason: \"source-migration\")"))
        XCTAssertTrue(audioSource.contains("private func resetReceiveOrderingState(reason: String) async"))
        XCTAssertTrue(audioSource.contains("replayWindow = SkyBridgeMediaReplayWindow()"))
        XCTAssertTrue(
            audioSource.contains(
                "await IOSRealtimeMediaAudioPlayer.shared.stop(ifOwnedBy: lifecycle)"
            )
        )
        XCTAssertFalse(
            audioSource.contains("guard acceptSource(datagram.remoteEndpoint) else"),
            "The iOS receiver must authenticate media packets before applying source endpoint policy; Network.framework can migrate the Mac sender's UDP port mid-session."
        )
        XCTAssertFalse(
            audioSource.contains("guard replayWindow.accept(sequence: opened.header.sequence) else {\n                rejected &+= 1\n                logTelemetryIfNeeded()\n                return\n            }\n            guard let sourceDecision"),
            "Authenticated source migration must reset replay/jitter state before replay-window duplicate checks can reject a restarted media sender."
        )
        XCTAssertTrue(audioSource.contains("decoder.decode("))
        XCTAssertTrue(audioSource.contains("packet: nil"))
        XCTAssertTrue(audioSource.contains("replayRejected=\\(window.replayRejected)"))
        XCTAssertTrue(audioSource.contains("jitterLate=\\(window.jitterLate)"))
        XCTAssertTrue(audioSource.contains("jitterDuplicate=\\(window.jitterDuplicate)"))
        XCTAssertTrue(audioSource.contains("plc=\\(window.plcFrames)"))
        XCTAssertTrue(audioSource.contains("sourceReject=\\(window.sourceRejected)"))
        XCTAssertTrue(audioSource.contains("sourceMigrate=\\(window.sourceMigrated)"))
        XCTAssertTrue(audioSource.contains("PQC media audio source migrated"))
        XCTAssertTrue(audioSource.contains("Self.normalizedHost(lockedRemoteEndpoint) == Self.normalizedHost(remoteEndpoint)"))
        XCTAssertTrue(audioSource.contains("func handle(datagram: SkyBridgeMediaReceivedDatagram) async"))
        XCTAssertTrue(audioSource.contains("actor IOSRealtimeMediaAudioPlayer"))
        XCTAssertFalse(
            audioSource.contains("@MainActor\nfinal class IOSRealtimeMediaAudioPlayer"),
            "Realtime audio playout must not schedule AVAudioPlayerNode buffers on the UI MainActor; Metal/UI stalls can otherwise starve audio and force jitter-buffer evictions."
        )
        XCTAssertTrue(audioSource.contains("func playPCM16("))
        XCTAssertTrue(audioSource.contains("profile: SkyBridgeMediaAudioProfile"))
        XCTAssertTrue(audioSource.contains("queuedMs="))
        XCTAssertTrue(audioSource.contains("targetQueuedMs="))
        XCTAssertTrue(audioSource.contains("primed="))
        XCTAssertTrue(
            audioSource.contains("return max(profile.jitterTargetMs, 2_400)") &&
            audioSource.contains("return max(profile.jitterMaxMs, 4_800)") &&
            audioSource.contains("orderingJitterTargetMs") &&
            audioSource.contains("orderingJitterMaxMs") &&
            audioSource.contains("return max(profile.jitterTargetMs, 520)") &&
            audioSource.contains("return max(profile.jitterMaxMs, 900)") &&
            audioSource.contains("return max(profile.jitterTargetMs, 3_200)") &&
            audioSource.contains("return max(profile.jitterMaxMs, 5_600)") &&
            audioSource.contains("minimumAdaptiveJitterTargetMs"),
            "iOS realtime audio should keep a large render prebuffer for cellular relay bursts while using a short ordering buffer so jitter pacing does not starve playback."
        )
        XCTAssertTrue(audioSource.contains("rebuffer="))
        XCTAssertTrue(audioSource.contains("underflow="))
        XCTAssertTrue(audioSource.contains("overflow="))
        XCTAssertTrue(audioSource.contains("playbackDrop=\\(window.playbackDropped)"))

        let transportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeRealtimeMedia/UDPTransport.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(transportSource.contains("interfaceBinding: SkyBridgeRealtimeMediaInterfaceBinding? = nil"))
        XCTAssertTrue(transportSource.contains("allowLocalEndpointReuse = allowLocalEndpointReuse"))
        XCTAssertEqual(
            transportSource.components(separatedBy: "parameters.requiredInterface = interfaceBinding.interface").count - 1,
            2,
            "The LAN audio sender and receiver must both preserve the authenticated control-path interface."
        )
        XCTAssertEqual(
            transportSource.components(separatedBy: "parameters.includePeerToPeer = false").count - 1,
            2,
            "Dedicated remote-control media must stay on the infrastructure interface in both directions."
        )
        XCTAssertTrue(transportSource.contains("interfaceBinding.validatesReadyPath(connection.currentPath)"))
        XCTAssertTrue(transportSource.contains("withTaskCancellationHandler"))
        XCTAssertFalse(
            transportSource.contains("parameters.allowLocalEndpointReuse = true"),
            "Realtime media UDP sockets should not request local port reuse by default because this path never intentionally shares a port across concurrent flows."
        )

        let viewSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"),
            encoding: .utf8
        )
        guard let emptyQueueGuardRange = viewSource.range(of: "guard shouldClear || hasPendingFrame else"),
              let renderTargetRange = viewSource.range(of: "guard let renderTarget = makeDrawableRenderTarget(for: view)"),
              let completionRange = viewSource.range(of: "private func addDisplayedFrameCompletion("),
              let submittedFrameResetRange = viewSource.range(of: "if self.submittedFrameVersion == frameVersion") else {
            XCTFail("Metal renderer must keep empty-queue/submitted-frame guards and drawable acquisition visible in source")
            return
        }
        XCTAssertLessThan(
            emptyQueueGuardRange.lowerBound,
            renderTargetRange.lowerBound,
            "The Metal renderer must skip empty display-link ticks before acquiring a CAMetalDrawable; otherwise iOS can reuse/present a stale drawable and trigger fallback."
        )
        XCTAssertLessThan(
            completionRange.lowerBound,
            submittedFrameResetRange.lowerBound,
            "The Metal renderer must reset submitted frame ownership only after the owned command buffer completes."
        )
        XCTAssertTrue(viewSource.contains("private var submittedFrameVersion: UInt64 = 0"))
        XCTAssertTrue(viewSource.contains("submittedFrameVersion = frameVersion"))
        XCTAssertTrue(viewSource.contains("emptyQueueTick="))
        XCTAssertTrue(viewSource.contains("recordRenderSkip(.emptyQueue"))
        XCTAssertTrue(viewSource.contains("DispatchSemaphore(value: MetalVideoRenderer.inFlightLimit)"))
        XCTAssertFalse(viewSource.contains("view.currentRenderPassDescriptor"))
        XCTAssertEqual(viewSource.components(separatedBy: "view.currentDrawable").count - 1, 1)
        XCTAssertTrue(viewSource.contains("let renderPassDescriptor = MTLRenderPassDescriptor()"))
        XCTAssertTrue(viewSource.contains("renderPassDescriptor.colorAttachments[0].texture = drawable.texture"))
        guard let currentDrawableRange = viewSource.range(of: "let drawable = view.currentDrawable"),
              let descriptorRange = viewSource.range(of: "let renderPassDescriptor = MTLRenderPassDescriptor()", range: currentDrawableRange.upperBound..<viewSource.endIndex),
              let textureRange = viewSource.range(of: "renderPassDescriptor.colorAttachments[0].texture = drawable.texture", range: descriptorRange.upperBound..<viewSource.endIndex),
              let returnRange = viewSource.range(of: "return DrawableRenderTarget(", range: textureRange.upperBound..<viewSource.endIndex) else {
            XCTFail("The Metal renderer must acquire exactly one currentDrawable and build one render-pass descriptor around it")
            return
        }
        XCTAssertLessThan(currentDrawableRange.lowerBound, descriptorRange.lowerBound)
        XCTAssertLessThan(descriptorRange.lowerBound, textureRange.lowerBound)
        XCTAssertLessThan(textureRange.lowerBound, returnRange.lowerBound)
        guard let framePathRange = viewSource.range(of: "let drawableWidth ="),
              let drawableTargetRange = viewSource.range(
                of: "guard let renderTarget = makeDrawableRenderTarget(for: view)",
                range: framePathRange.upperBound..<viewSource.endIndex
              ),
              let directRenderRange = viewSource.range(
                of: "encodeDirectTextureFrame(",
                range: drawableTargetRange.upperBound..<viewSource.endIndex
              ),
              let presentRange = viewSource.range(
                of: "commandBuffer.present(renderTarget.drawable)",
                range: directRenderRange.upperBound..<viewSource.endIndex
              ) else {
            XCTFail("The Metal renderer must render directly into one owned CAMetalDrawable and present that drawable once")
            return
        }
        XCTAssertLessThan(drawableTargetRange.lowerBound, directRenderRange.lowerBound)
        XCTAssertLessThan(drawableTargetRange.lowerBound, presentRange.lowerBound)
        XCTAssertTrue(viewSource.contains("CVMetalTextureCacheCreateTextureFromImage"))
        XCTAssertTrue(viewSource.contains("texture2d<float, access::sample> frameTexture"))
        XCTAssertTrue(viewSource.contains("passthroughPipelineState"))
        XCTAssertFalse(viewSource.contains("makeRenderTexture("))
        XCTAssertFalse(viewSource.contains("commandBuffer.makeBlitCommandEncoder()"))
        XCTAssertTrue(viewSource.contains("metalView.enableSetNeedsDisplay = false"))
        XCTAssertTrue(viewSource.contains("metalView.isPaused = false"))
        XCTAssertFalse(viewSource.contains("startDisplayLinkIfNeeded()"))
        XCTAssertTrue(viewSource.contains("displayLinkTargetFPS(for screen: UIScreen)"))
        XCTAssertTrue(viewSource.contains("displayLinkPumpFPS(for screen: UIScreen)"))
        XCTAssertTrue(viewSource.contains("metalView.preferredFramesPerSecond = pumpFPS"))
        XCTAssertTrue(viewSource.contains("private static let strictRemoteDisplayFPS = 60"))
        XCTAssertTrue(viewSource.contains("min(strictRemoteDisplayFPS, max(1, screen.maximumFramesPerSecond))"))
        XCTAssertTrue(viewSource.contains("private static func displayLinkPumpFPS(for screen: UIScreen) -> Int {\n            max(displayLinkTargetFPS(for: screen), screen.maximumFramesPerSecond)\n        }"))
        XCTAssertTrue(viewSource.contains("let hasNativePumpHeadroom = displayLinkPumpFPS > displayLinkTargetFPS"))
        XCTAssertTrue(viewSource.contains("let shouldUseNativePumpCatchUp = hasNativePumpHeadroom"))
        XCTAssertTrue(viewSource.contains("&& lateBy > Self.frameCadenceTolerance"))
        XCTAssertTrue(viewSource.contains("&& lateBy <= Self.missedCadenceResetThreshold"))
        XCTAssertTrue(viewSource.contains("|| shouldUseNativePumpCatchUp else {"))
        XCTAssertTrue(viewSource.contains("guard shouldUseNativePumpBacklogCatchUpLocked("))
        XCTAssertTrue(viewSource.contains("private static let nativePumpBacklogCatchUpMinimumDepth = 2"))
        XCTAssertTrue(viewSource.contains("private static let nativePumpBacklogCatchUpFrameAgeMs = 80"))
        XCTAssertTrue(viewSource.contains("private static let nativePumpBacklogCatchUpMinimumInterval: TimeInterval = 0.5"))
        XCTAssertTrue(viewSource.contains("renderNativePumpBacklogCatchUpFrames += 1"))
        XCTAssertTrue(viewSource.contains("now.timeIntervalSince(lastNativePumpBacklogCatchUpAt) >= Self.nativePumpBacklogCatchUpMinimumInterval"))
        XCTAssertFalse(viewSource.contains("let hasBurstBacklog = pendingFrames.count > 1"))
        XCTAssertTrue(viewSource.contains("private static let frameCadenceTolerance: TimeInterval = 0.004"))
        XCTAssertTrue(viewSource.contains("screen.maximumFramesPerSecond"))
        XCTAssertFalse(viewSource.contains("CADisplayLink("))
        XCTAssertFalse(viewSource.contains("preferredFrameRateRange = CAFrameRateRange("))
        XCTAssertFalse(viewSource.contains("renderCadenceTick(in: metalView, timestamp: displayLink.timestamp)"))
        XCTAssertFalse(viewSource.contains("func renderCadenceTick(in view: MTKView, timestamp: CFTimeInterval)"))
        XCTAssertFalse(viewSource.contains("private var lastCadenceDrawTimestamp: CFTimeInterval = 0"))
        XCTAssertFalse(viewSource.contains("private var lastCadenceTickTimestamp: CFTimeInterval = 0"))
        XCTAssertFalse(viewSource.contains("private var cadenceFrameCredit: Double = 0"))
        XCTAssertFalse(viewSource.contains("private var lastSubmittedAt = Date.distantPast"))
        XCTAssertTrue(viewSource.contains("private var nextFrameDueAt = Date.distantPast"))
        XCTAssertTrue(viewSource.contains("private static let missedCadenceResetThreshold: TimeInterval = targetFrameInterval"))
        XCTAssertTrue(viewSource.contains("advanceNextFrameDueAtLocked(submittedAt: Date())"))
        XCTAssertTrue(viewSource.contains("lateBy > Self.missedCadenceResetThreshold"))
        XCTAssertTrue(viewSource.contains("nextFrameDueAt = nextFrameDueAt.addingTimeInterval(Self.targetFrameInterval)"))
        XCTAssertFalse(viewSource.contains("private static let videoPaceEarlyDrawTolerance"))
        XCTAssertFalse(viewSource.contains("shouldRequestFrameArrivalDrawLocked(now: enqueuedAt)"))
        XCTAssertFalse(viewSource.contains("private func shouldRequestFrameArrivalDrawLocked(now: Date) -> Bool"))
        XCTAssertFalse(viewSource.contains("elapsed + Self.videoPaceEarlyDrawTolerance >= targetInterval"))
        XCTAssertFalse(viewSource.contains("renderFrameArrivalDrawSkips += 1"))
        XCTAssertFalse(viewSource.contains("private var lastFrameArrivalDrawAt = Date.distantPast"))
        XCTAssertFalse(viewSource.contains("let shouldDrainDecodedBacklog = pendingFrames.count > 1"))
        XCTAssertFalse(viewSource.contains("renderCadenceBacklogDraws += 1"))
        XCTAssertFalse(viewSource.contains("isEarlyBacklogDrain"))
        XCTAssertFalse(viewSource.contains("guard !view.isPaused else { return }"))
        if let displayRange = viewSource.range(of: "func display(frame: DecodedPixelBufferFrame, version: UInt64, in view: MTKView)"),
           let flushRange = viewSource.range(of: "func flush(", range: displayRange.upperBound..<viewSource.endIndex) {
            XCTAssertFalse(
                viewSource[displayRange.lowerBound..<flushRange.lowerBound].contains("view.draw()"),
                "Frame arrival must not manually draw; MTKView native cadence owns every CAMetalDrawable."
            )
        } else {
            XCTFail("Missing Metal display or flush method while checking draw ownership")
        }
        XCTAssertFalse(viewSource.contains("pendingRedraw"))
        XCTAssertTrue(viewSource.contains("private var renderInFlight = false"))
        XCTAssertFalse(viewSource.contains("guard !renderInFlight else"))
        XCTAssertFalse(viewSource.contains("private var frameDeadlineDrawScheduled = false"))
        XCTAssertFalse(viewSource.contains("requestScheduledFollowUpDrawIfPossible"))
        XCTAssertFalse(viewSource.contains("nextFrameDeadlineDrawDelayLocked"))
        XCTAssertFalse(viewSource.contains("private var frameDeadlineDrawGeneration: UInt64 = 0"))
        XCTAssertFalse(viewSource.contains("generation == frameDeadlineDrawGeneration"))
        XCTAssertFalse(viewSource.contains("private func requestDrawableRefresh(on view: MTKView)"))
        XCTAssertFalse(viewSource.contains("view.draw()"))
        XCTAssertFalse(viewSource.contains("private static let realtimeCoalescingQueueBudget"))
        XCTAssertTrue(viewSource.contains("private static let maxQueuedFrames = 3"))
        XCTAssertTrue(viewSource.contains("private var renderFrameAgeMaxMs: Int?"))
        XCTAssertTrue(viewSource.contains("renderFrameAgeMaxMs = max(self.renderFrameAgeMaxMs ?? frameAgeMs, frameAgeMs)"))
        XCTAssertFalse(viewSource.contains("if pendingFrames.count > 1 {\n                renderFrameArrivalDrawSkips += 1\n                return false"))
        XCTAssertFalse(viewSource.contains("renderCoalescedFrames += coalescedCount"))
        XCTAssertFalse(viewSource.contains("lowLatencyCoalescingThreshold"))
        XCTAssertFalse(viewSource.contains("pendingFrames.removeFirst(framesToDiscard)"))
        XCTAssertTrue(viewSource.contains("private var renderCoalescedFrames = 0"))
        XCTAssertFalse(viewSource.contains("pendingDisplayedCallbackCount"))
        XCTAssertFalse(viewSource.contains("lastDisplayedCallbackFlushAt"))
        XCTAssertTrue(viewSource.contains("onFramesDisplayed: @escaping @Sendable ("))
        XCTAssertTrue(viewSource.contains("CameraFramePresentationContext?"))
        XCTAssertTrue(viewSource.contains("displayedCallbackCompletedAt"))
        XCTAssertTrue(viewSource.contains("let uprightTransform = CGAffineTransform("))
        XCTAssertTrue(viewSource.contains("let visibleRect = CGRect("))
        XCTAssertTrue(viewSource.contains("backingImage.cropped(to: visibleRect)"))
        XCTAssertTrue(
            viewSource.range(of: "encodeDirectTextureFrame(")!.lowerBound
                < viewSource.range(of: "ciContext.render(")!.lowerBound,
            "The primary Metal path should use CVMetalTextureCache before the CI fallback."
        )
        XCTAssertTrue(viewSource.contains("d: scaleY"))
        XCTAssertFalse(viewSource.contains("d: -scaleY"))
        XCTAssertFalse(viewSource.contains("a: -scaleX"))
        XCTAssertTrue(viewSource.contains("Metal render telemetry"))
        XCTAssertTrue(viewSource.contains("SkyBridgeDiagnosticTrace.appendStatus(telemetryLine)"))
        XCTAssertTrue(viewSource.contains("inputFPS="))
        XCTAssertTrue(viewSource.contains("frameAgeMs="))
        XCTAssertTrue(viewSource.contains("source="))
        XCTAssertTrue(viewSource.contains("orientation=upright"))
        XCTAssertTrue(viewSource.contains("drawableAccess=single-current-drawable displayLink"))
        XCTAssertTrue(viewSource.contains("displayLink=mtkview-native"))
        XCTAssertTrue(viewSource.contains("displayLinkTargetFPS=\\(snapshot.displayLinkTargetFPS)"))
        XCTAssertTrue(viewSource.contains("displayLinkPumpFPS=\\(snapshot.displayLinkPumpFPS)"))
        XCTAssertTrue(viewSource.contains("screenMaxFPS=\\(snapshot.screenMaxFPS)"))
        XCTAssertTrue(viewSource.contains("displayCadence=strict-60-native-pump-catch-up-vsync"))
        XCTAssertTrue(viewSource.contains("manualDraw=0"))
        XCTAssertTrue(viewSource.contains("nativePumpCatchUp=\\(snapshot.nativePumpBacklogCatchUpFrames)"))
        XCTAssertFalse(viewSource.contains("cadenceNotDueTick="))
        XCTAssertFalse(viewSource.contains("arrivalDraw="))
        XCTAssertFalse(viewSource.contains("arrivalDrawSkip="))
        XCTAssertFalse(viewSource.contains("cadenceBacklogDraw="))
        XCTAssertFalse(viewSource.contains("cadenceLateMaxMs="))
        XCTAssertTrue(viewSource.contains("frameDriven=mtkview-native-vsync"))
        XCTAssertTrue(viewSource.contains("renderPath="))
        XCTAssertTrue(viewSource.contains("directBGRA="))
        XCTAssertTrue(viewSource.contains("ciFallback="))

        let managerSourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift")
        let managerSource = try String(contentsOf: managerSourceURL, encoding: .utf8)
        XCTAssertTrue(managerSource.contains("completedAt: Date"))
        XCTAssertTrue(managerSource.contains("noteDisplayedFrames(count: displayedFrameCount, at: completedAt)"))
        guard let decodeLoopStart = managerSource.range(of: "private func startDecodeLoopIfNeeded()"),
              let finishDecodeStart = managerSource.range(
                  of: "@MainActor\n    private func finishDecodeTask(",
                  range: decodeLoopStart.upperBound..<managerSource.endIndex
              ) else {
            XCTFail("Missing remote desktop decode loop while checking MainActor isolation")
            return
        }
        let decodeLoopBody = managerSource[decodeLoopStart.lowerBound..<finishDecodeStart.lowerBound]
        XCTAssertTrue(decodeLoopBody.contains("let task = Task.detached("))
        XCTAssertTrue(decodeLoopBody.contains("guard await self?.isDecodeGenerationCurrent(decodeGeneration) == true"))
        XCTAssertTrue(decodeLoopBody.contains("try await decoder.submit(screenData: screenData)"))
        XCTAssertTrue(decodeLoopBody.contains("try await handle.wait()"))
        XCTAssertTrue(decodeLoopBody.contains("await previousSubmission?.value"))
        XCTAssertTrue(decodeLoopBody.contains("decodeSubmissionChain = task"))
        XCTAssertFalse(decodeLoopBody.contains("Task { @MainActor"))
        XCTAssertTrue(managerSource.contains("metal-feed-awaiting-renderer-consumer"))
        XCTAssertTrue(managerSource.contains("metal-feed-renderer-rejected"))
        XCTAssertTrue(managerSource.contains("failed stage=remote-desktop phase=metal_feed_not_accepted"))
    }

    func testIOSSampleBufferFallbackRequiresConsecutiveStalls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(managerSource.contains("private let sampleBufferNoEnqueueWindowThreshold: Int = 3"))
        XCTAssertTrue(managerSource.contains("private let sampleBufferDisplayStallRecoveryThreshold: Int = 3"))
        XCTAssertTrue(managerSource.contains("consecutiveSampleBufferNoEnqueueWindows += 1"))
        XCTAssertTrue(managerSource.contains("consecutiveSampleBufferNoEnqueueWindows >= sampleBufferNoEnqueueWindowThreshold"))
        XCTAssertTrue(managerSource.contains("consecutiveSampleBufferNoEnqueueWindows = 0"))
        XCTAssertTrue(managerSource.contains("private let metalFallbackRestoreCooldown: TimeInterval = 0.75"))
        XCTAssertTrue(managerSource.contains("private let metalFallbackStableFrameRestoreThreshold = 2"))
        XCTAssertTrue(managerSource.contains("private let metalFallbackPersistentFailureThreshold = 3"))
        XCTAssertTrue(managerSource.contains("private let metalFallbackExpectedRestoreWindow: TimeInterval = 2"))
        XCTAssertTrue(managerSource.contains("activateSampleBufferFallbackForDecodedVideo(reason: reason)"))
        XCTAssertTrue(managerSource.contains("flushMetalVideoFrameFeed(removeDisplayedImage: false)"))
        XCTAssertTrue(managerSource.contains("restoreProbeMs=\\(Int(metalFallbackRestoreCooldown * 1000))"))
        XCTAssertTrue(managerSource.contains("expectedRestoreMs=\\(Int(metalFallbackExpectedRestoreWindow * 1000))"))
        XCTAssertTrue(managerSource.contains("Metal restore repeated failures suppressed"))
        XCTAssertTrue(managerSource.contains("cooldownMs=\\(cooldownMs)"))
        XCTAssertTrue(managerSource.contains("metalFallbackReason = nil"))
        guard let continuityStallRange = managerSource.range(
            of: "private func handleStreamContinuityStall(reason: String) async"
        ),
              let continuityStallEndRange = managerSource.range(
                of: "func handleVideoRendererDidEnqueueFrame",
                range: continuityStallRange.upperBound..<managerSource.endIndex
              ) else {
            XCTFail("Missing stream continuity recovery function while checking Metal recovery scope")
            return
        }
        let continuityStallBody = String(managerSource[continuityStallRange.lowerBound..<continuityStallEndRange.lowerBound])
        XCTAssertFalse(
            continuityStallBody.contains("guard activeTransportMode == .lan else { return }"),
            "Metal recovery must apply to WebRTC/cross-network renderer stalls, not only LAN."
        )
        XCTAssertTrue(managerSource.contains("minimumInterval: metalFallbackRestoreCooldown"))
        XCTAssertTrue(managerSource.contains("await self?.handleStreamContinuityStall(reason: \"sample-buffer-no-enqueue\")"))
        XCTAssertTrue(managerSource.contains("private func recoverSampleBufferPipeline(reason: String, at now: Date) async"))
        XCTAssertTrue(managerSource.contains("已刷新解码管线并暂缓静态帧降级"))
        XCTAssertFalse(
            managerSource.contains("|| reason == \"sample-buffer-no-enqueue\"),\n           renderPipelineStatus == .sampleBufferDisplayLayer {\n            lastContinuityRecoveryAt = now\n            zeroMeasuredFrameRate(at: now)\n            activateCGImageFallbackForDecodedVideo()"),
            "A single sample-buffer no-enqueue stats window must not immediately demote video to the slow CGImage fallback."
        )
    }

    private func makeSinePCM(samplesPerChannel: Int, channels: Int) -> [Int16] {
        var pcm: [Int16] = []
        pcm.reserveCapacity(samplesPerChannel * channels)
        for sampleIndex in 0..<samplesPerChannel {
            let phase = Double(sampleIndex) / Double(samplesPerChannel)
            let sample = Int16((sin(phase * .pi * 8) * 10_000).rounded())
            for _ in 0..<channels {
                pcm.append(sample)
            }
        }
        return pcm
    }

    private func data(from pcm: [Int16]) -> Data {
        pcm.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Int16>.size)
        }
    }
}

private actor SuspendedCapturingRealtimeMediaTransport: SkyBridgeRealtimeMediaTransport {
    private let sendDelayMs: Int
    private let suspendBeforeAppendingSendNumber: Int?
    private var packets: [Data] = []
    private var attemptedSends = 0
    private var stopRequested = false
    private var suspendedSendContinuation: CheckedContinuation<Void, Never>?

    init(sendDelayMs: Int, suspendBeforeAppendingSendNumber: Int? = nil) {
        self.sendDelayMs = sendDelayMs
        self.suspendBeforeAppendingSendNumber = suspendBeforeAppendingSendNumber
    }

    func start() async throws {}

    func send(_ packet: Data) async throws {
        attemptedSends += 1
        let sendNumber = attemptedSends
        if sendNumber == suspendBeforeAppendingSendNumber {
            await withCheckedContinuation { continuation in
                suspendedSendContinuation = continuation
            }
        }
        if stopRequested || Task.isCancelled {
            throw CancellationError()
        }
        if sendDelayMs > 0 {
            try await Task.sleep(for: .milliseconds(sendDelayMs))
        }
        if stopRequested || Task.isCancelled {
            throw CancellationError()
        }
        packets.append(packet)
    }

    func stop() async {
        stopRequested = true
        suspendedSendContinuation?.resume()
        suspendedSendContinuation = nil
    }

    var packetCount: Int {
        packets.count
    }

    var sendAttemptCount: Int {
        attemptedSends
    }

    func waitForSuspendedSend(timeoutMs: Int) async -> Bool {
        let timeoutNanos = UInt64(max(0, timeoutMs)) * 1_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanos
        while suspendedSendContinuation == nil, DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return suspendedSendContinuation != nil
    }

    func packetsSnapshot() -> [Data] {
        packets
    }
}

private final class LocalUDPDropRelay: @unchecked Sendable {
    private final class StartState: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resumeOnce(_ body: () -> Void) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            body()
        }
    }

    private let queue = DispatchQueue(label: "com.skybridge.tests.udp-drop-relay")
    private var listener: NWListener?

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .udp)
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            self.dropNext(on: connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let state = StartState()
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    state.resumeOnce {
                        self.listener = listener
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    state.resumeOnce {
                        listener.cancel()
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func dropNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] _, _, _, error in
            guard let self, let connection, error == nil else {
                connection?.cancel()
                return
            }
            self.dropNext(on: connection)
        }
    }
}

private actor RealtimeMediaTestGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private final class LocalUDPAckRelay: @unchecked Sendable {
    private final class StartState: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resumeOnce(_ body: () -> Void) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            lock.unlock()
            body()
        }
    }

    private let queue = DispatchQueue(label: "com.skybridge.tests.udp-ack-relay")
    private var listener: NWListener?

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .udp)
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            self.receiveAndAck(on: connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let state = StartState()
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    state.resumeOnce {
                        self.listener = listener
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    state.resumeOnce {
                        listener.cancel()
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receiveAndAck(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection, error == nil else {
                connection?.cancel()
                return
            }
            if let content,
               content.first == 0x7b,
               let object = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
               object["type"] as? String == "bind" {
                let ack = Data(#"{"type":"bind-result","ok":true}"#.utf8)
                connection.send(content: ack, completion: .contentProcessed { _ in })
            }
            self.receiveAndAck(on: connection)
        }
    }
}
