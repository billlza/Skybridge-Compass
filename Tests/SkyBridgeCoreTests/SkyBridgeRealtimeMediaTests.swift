import XCTest
@testable import SkyBridgeCore
import SkyBridgeOpus
import SkyBridgeRealtimeMedia

final class SkyBridgeRealtimeMediaTests: XCTestCase {
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
            transcriptHash: transcriptHash
        )
        let header = SkyBridgeMediaPacketHeader(
            sessionIdHash: SkyBridgeMediaPacketCodec.sessionIdHash(sessionId),
            sequence: 7,
            timestampSamples: 7 * 960,
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
            XCTAssertEqual(error as? SkyBridgeMediaPacketError, .authenticationFailed)
        }
    }

    func testRelayTransportWaitsForBindResultBeforeMediaFlow() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeRealtimeMedia/UDPTransport.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("try await waitForRelayBindResult(on: connection)"))
        XCTAssertTrue(source.contains("type\"") && source.contains("bind-result"))
        XCTAssertTrue(source.contains("relayBindRejected"))
        XCTAssertTrue(source.contains("relayBindTimedOut"))
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
    func testRealtimeAudioSenderCloseDuringPacingSleepDoesNotTouchClearedBuffer() async throws {
        let sessionId = "audio-sender-close-during-pacing"
        let keyMaterial = SkyBridgeMediaKeyMaterial.derive(
            sendSecret: Data(repeating: 0x51, count: 32),
            receiveSecret: Data(repeating: 0x52, count: 32),
            sessionId: sessionId,
            transcriptHash: Data(repeating: 0x53, count: 32)
        )
        let transport = SuspendedCapturingRealtimeMediaTransport(sendDelayMs: 0)
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

        let deadline = Date().addingTimeInterval(1)
        while await transport.packetCount < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let firstPacketCount = await transport.packetCount
        XCTAssertEqual(firstPacketCount, 1)

        try await Task.sleep(for: .milliseconds(5))
        let packetCountBeforeClose = await transport.packetCount
        XCTAssertEqual(
            packetCountBeforeClose,
            1,
            "The second packet should still be held by sender pacing before close races the sleep window."
        )

        await sender.close()
        let sentPacketCountAtClose = await transport.packetCount
        try await Task.sleep(for: .milliseconds(profile.frameDurationMs * 2))
        let sentPacketCountAfterClose = await transport.packetCount
        XCTAssertEqual(
            sentPacketCountAfterClose,
            sentPacketCountAtClose,
            "Closing during the pacing window must cancel the drain loop without sending after close."
        )
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
        let p2pSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(p2pSource.contains("legacyAudioFallbackEnabled"))
        XCTAssertTrue(p2pSource.contains("if legacyAudioFallbackEnabled {\n            policy = policy.protectingRealtimeAudio()"))
        XCTAssertTrue(p2pSource.contains("Remote frame tx telemetry"))
        XCTAssertTrue(p2pSource.contains("submittedFPS="))
        XCTAssertTrue(p2pSource.contains("sentFPS="))
        XCTAssertTrue(p2pSource.contains("avgSendMs="))
        XCTAssertFalse(
            p2pSource.contains("if realtimeAudioSender != nil {\n            policy = policy.protectingRealtimeAudio()"),
            "Dedicated P2P realtime audio runs on its own media plane and must not cap screen FPS."
        )
        XCTAssertTrue(p2pSource.contains("captureSystemAudio: legacyAudioFallbackEnabled"))
        XCTAssertTrue(p2pSource.contains("RemoteRealtimePCM16SubmissionPipe(sender: realtimeAudioSender)"))
        XCTAssertFalse(
            p2pSource.contains("captureSystemAudio: audioRedirectionEnabled"),
            "P2P system audio capture must not automatically enter the shared remote-control channel."
        )

        let webrtcSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(webrtcSource.contains("legacyAudioFallbackEnabled: legacyAudioFallbackEnabled"))
        XCTAssertTrue(webrtcSource.contains("audioRedirectionEnabled && !nativeAudioTrackEnabled && legacyAudioFallbackEnabled"))
        XCTAssertTrue(webrtcSource.contains("let shouldUseFallbackAudioChunks = Self.shouldUseWebRTCAudioFallback("))
        XCTAssertTrue(webrtcSource.contains("shouldUseFallbackAudioChunks\n                ? selectedPolicy.protectingRealtimeAudio()"))
        XCTAssertFalse(
            webrtcSource.contains("shouldUseRealtimeAudio\n                ? selectedPolicy.protectingRealtimeAudio()"),
            "Dedicated WebRTC/PQC media audio runs on its own transport and must not cap the native video path."
        )
        XCTAssertTrue(webrtcSource.contains("RemoteRealtimePCM16SubmissionPipe(sender: directRealtimeAudioSender)"))

        let streamerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(streamerSource.contains("audioSequenceNumber = nativePCMChunk.sequenceNumber"))
        XCTAssertTrue(streamerSource.contains("SCK tx telemetry"))
        XCTAssertTrue(streamerSource.contains("captureFPS="))
        XCTAssertTrue(streamerSource.contains("meaningfulFPS="))
        XCTAssertTrue(streamerSource.contains("encodedFPS="))
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

        let senderSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteDesktop/RealtimeMediaAudio.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(senderSource.contains("final class RemoteRealtimePCM16SubmissionPipe"))
        XCTAssertTrue(senderSource.contains("Task(priority: .utility)"))
        XCTAssertFalse(
            senderSource.contains("Task(priority: .userInitiated)"),
            "Realtime audio encoding should not compete with screen capture and video rendering at userInitiated priority."
        )
        XCTAssertTrue(senderSource.contains("for await chunk in stream"))
        XCTAssertTrue(senderSource.contains("await sender.submitPCM16Chunk(chunk)"))
        XCTAssertTrue(senderSource.contains("let frameIntervalNanos = UInt64(max(1, profile.frameDurationMs)) * 1_000_000"))
        XCTAssertTrue(senderSource.contains("DispatchTime.now().uptimeNanoseconds"))
        XCTAssertTrue(senderSource.contains("dropPendingPCMFrames(staleFrames)"))
        XCTAssertTrue(senderSource.contains("func matches(sessionId: String, endpoint: SkyBridgeMediaEndpoint, mode: SkyBridgeMediaAudioMode) -> Bool"))
        XCTAssertTrue(senderSource.contains("emptyPacingTicks"))
        XCTAssertTrue(senderSource.contains("interSendP95Ms="))
        XCTAssertTrue(senderSource.contains("interSendMaxMs="))
    }

    func testRealtimeAudioEndpointChangesRestartSenderAndViewerKeepsEndpointStable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let p2pSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"),
            encoding: .utf8
        )
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
        XCTAssertTrue(iosViewerSource.contains("private var realtimeMediaAudioEndpoint: SkyBridgeMediaEndpoint?"))
        XCTAssertTrue(iosViewerSource.contains("let endpoint = realtimeMediaAudioEndpoint"))
        XCTAssertTrue(
            iosViewerSource.contains("snapshot = lanRealtimeMediaKeySnapshot()"),
            "LAN realtime audio must be bound to the remote-desktop secure channel keys, not the separate file-transfer/P2P session keys."
        )
        XCTAssertTrue(iosViewerSource.contains("skybridge-lan-remote-media-session-v1"))
        XCTAssertFalse(
            iosViewerSource.contains("let endpoint = lastSentStreamConfiguration?.mediaAudioEndpoint"),
            "The iOS viewer must keep the live UDP receiver endpoint stable across first-frame refresh pushes before lastSentStreamConfiguration settles."
        )
        XCTAssertFalse(
            iosViewerSource.contains("connectionManager.realtimeMediaKeySnapshot(for: deviceId)"),
            "Using the general P2P connection keys causes SBMA authentication failures because LAN remote desktop performs its own secure-channel handshake."
        )
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
        XCTAssertTrue(audioSource.contains("private func playoutNextFrame() async -> Bool"))
        XCTAssertTrue(audioSource.contains("private var playoutBurstFrameLimit: Int"))
        XCTAssertTrue(audioSource.contains("var nextDeadline = DispatchTime.now().uptimeNanoseconds + frameIntervalNanos"))
        XCTAssertTrue(audioSource.contains("let overdueNanos = wokeAt > nextDeadline ? wokeAt - nextDeadline : 0"))
        XCTAssertTrue(audioSource.contains("let dueFrames = max(1, Int(overdueNanos / frameIntervalNanos) + 1)"))
        XCTAssertTrue(audioSource.contains("nextDeadline &+= UInt64(dueFrames) * frameIntervalNanos"))
        XCTAssertTrue(audioSource.contains("while scheduledFrames < frameLimit"))
        XCTAssertTrue(audioSource.contains("switch jitterBuffer.popReadyOrGap(now:"))
        XCTAssertTrue(audioSource.contains("case .gap(let sequence):"))
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
        XCTAssertTrue(audioSource.contains("await IOSRealtimeMediaAudioPlayer.shared.stop()"))
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
        XCTAssertTrue(audioSource.contains("rebuffer="))
        XCTAssertTrue(audioSource.contains("underflow="))
        XCTAssertTrue(audioSource.contains("overflow="))
        XCTAssertTrue(audioSource.contains("playbackDrop=\\(window.playbackDropped)"))

        let transportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeRealtimeMedia/UDPTransport.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(transportSource.contains("public init(port: UInt16? = nil, allowLocalEndpointReuse: Bool = false)"))
        XCTAssertTrue(transportSource.contains("allowLocalEndpointReuse = allowLocalEndpointReuse"))
        XCTAssertFalse(
            transportSource.contains("parameters.allowLocalEndpointReuse = true"),
            "Realtime media UDP sockets should not request local port reuse by default because this path never intentionally shares a port across concurrent flows."
        )

        let viewSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"),
            encoding: .utf8
        )
        guard let duplicateGuardRange = viewSource.range(of: "if !shouldClear, frame != nil"),
              let submittedGuardRange = viewSource.range(of: "frameVersion != submittedVersion"),
              let drawableRange = viewSource.range(of: "let drawable = view.currentDrawable") else {
            XCTFail("Metal renderer must keep duplicate/submitted-frame guards and drawable acquisition visible in source")
            return
        }
        XCTAssertLessThan(
            duplicateGuardRange.lowerBound,
            drawableRange.lowerBound,
            "The Metal renderer must skip duplicate frames before acquiring a CAMetalDrawable; otherwise iOS can reuse/present a stale drawable and trigger fallback."
        )
        XCTAssertLessThan(
            submittedGuardRange.lowerBound,
            drawableRange.lowerBound,
            "The Metal renderer must reject in-flight frame versions before acquiring a CAMetalDrawable."
        )
        XCTAssertTrue(viewSource.contains("private var submittedFrameVersion: UInt64 = 0"))
        XCTAssertTrue(viewSource.contains("submittedFrameVersion = frameVersion"))
        XCTAssertTrue(viewSource.contains("DispatchSemaphore(value: 1)"))
        XCTAssertFalse(
            viewSource.contains("view.currentRenderPassDescriptor"),
            "The Metal renderer must not mix MTKView.currentRenderPassDescriptor with explicit currentDrawable ownership."
        )
        XCTAssertEqual(viewSource.components(separatedBy: "view.currentDrawable").count - 1, 1)
        XCTAssertEqual(viewSource.components(separatedBy: "drawable.texture").count - 1, 1)
        XCTAssertTrue(viewSource.contains("let renderPassDescriptor = MTLRenderPassDescriptor()"))
        XCTAssertTrue(viewSource.contains("renderPassDescriptor.colorAttachments[0].texture"))
        XCTAssertTrue(viewSource.contains("let drawableTexture = drawable.texture"))
        guard let textureRange = viewSource.range(of: "let drawableTexture = drawable.texture"),
              let returnRange = viewSource.range(of: "return DrawableRenderTarget(", range: textureRange.upperBound..<viewSource.endIndex) else {
            XCTFail("The Metal renderer must read drawable.texture only inside the drawable target helper")
            return
        }
        XCTAssertLessThan(textureRange.lowerBound, returnRange.lowerBound)
        guard let renderTextureRange = viewSource.range(of: "guard let renderTexture = makeRenderTexture("),
              let drawableTargetRange = viewSource.range(
                of: "guard let renderTarget = makeDrawableRenderTarget(for: view)",
                range: renderTextureRange.upperBound..<viewSource.endIndex
              ),
              let presentRange = viewSource.range(
                of: "commandBuffer.present(renderTarget.drawable)",
                range: drawableTargetRange.upperBound..<viewSource.endIndex
              ) else {
            XCTFail("The Metal renderer must preflight render texture before acquiring/presenting a CAMetalDrawable")
            return
        }
        XCTAssertLessThan(renderTextureRange.lowerBound, drawableTargetRange.lowerBound)
        XCTAssertLessThan(drawableTargetRange.lowerBound, presentRange.lowerBound)
        XCTAssertTrue(viewSource.contains("commandBuffer.makeBlitCommandEncoder()"))
        XCTAssertTrue(viewSource.contains("metalView.enableSetNeedsDisplay = true"))
        XCTAssertTrue(viewSource.contains("metalView.isPaused = true"))
        XCTAssertTrue(viewSource.contains("view.setNeedsDisplay()"))
        XCTAssertTrue(viewSource.contains("view.draw()"))
        XCTAssertTrue(viewSource.contains("pendingRedraw"))
        XCTAssertTrue(viewSource.contains("requestFollowUpDrawIfPossible"))
        XCTAssertTrue(viewSource.contains("let verticalFlipTransform = CGAffineTransform("))
        XCTAssertTrue(viewSource.contains("d: -scaleY"))
        XCTAssertFalse(viewSource.contains("a: -scaleX"))
        XCTAssertTrue(viewSource.contains("Metal render telemetry"))
        XCTAssertTrue(viewSource.contains("frameAgeMs="))
        XCTAssertTrue(viewSource.contains("orientation=verticalFlip"))
        XCTAssertTrue(viewSource.contains("drawableAccess=single-late"))
        XCTAssertTrue(viewSource.contains("frameDriven=true"))
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
        XCTAssertTrue(managerSource.contains("private let metalFallbackRestoreCooldown: TimeInterval = 30"))
        XCTAssertTrue(managerSource.contains("private let metalFallbackStableFrameRestoreThreshold = 180"))
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
    private var packets: [Data] = []

    init(sendDelayMs: Int) {
        self.sendDelayMs = sendDelayMs
    }

    func start() async throws {}

    func send(_ packet: Data) async throws {
        if sendDelayMs > 0 {
            try await Task.sleep(for: .milliseconds(sendDelayMs))
        }
        packets.append(packet)
    }

    func stop() async {}

    var packetCount: Int {
        packets.count
    }

    func packetsSnapshot() -> [Data] {
        packets
    }
}
