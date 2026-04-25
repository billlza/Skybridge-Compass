import XCTest

final class RemoteControlAudioSchedulingTests: XCTestCase {
    func testP2PAudioDrainIsDecoupledFromVideoFramePump() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("scheduleAudioDrainIfNeeded()"),
            "Remote audio payloads should be drained by their own bounded background path."
        )
        XCTAssertFalse(
            source.contains("await drainQueuedAudioPayloads(limit: 1)"),
            "Video frame sends must not synchronously wait for one audio packet after every frame."
        )
        XCTAssertTrue(
            source.contains("private var sendingAudio = false"),
            "Audio drain should be independently guarded so it cannot spawn unbounded sends."
        )
        XCTAssertTrue(
            source.contains("audioDrainGeneration &+="),
            "Stopping or restarting remote control must fence old audio drain tasks."
        )
        XCTAssertTrue(
            source.contains("audioDrainTask?.cancel()"),
            "Stopping or restarting remote control should cancel in-flight audio drain work."
        )
        XCTAssertTrue(
            source.contains("private let maxQueuedAudioPayloads = 3"),
            "P2P audio must keep only a tiny live queue because it shares the LAN remote-control connection with video frames."
        )
        XCTAssertTrue(
            source.contains("private let maxAudioVideoFrameGap: TimeInterval = 0.08"),
            "Audio should be suppressed when video is already below an acceptable live cadence."
        )
        XCTAssertTrue(
            source.contains("guard canSendAudioWithoutCompetingWithVideo else"),
            "Audio should be dropped whenever the video sender has backlog or an in-flight frame send."
        )
        XCTAssertTrue(
            source.contains("Date().timeIntervalSince(lastSentFrameAt) <= maxAudioVideoFrameGap"),
            "The video-priority gate must stop audio if video cadence has already collapsed."
        )
        XCTAssertTrue(
            source.contains("Task.detached(priority: .utility) {\n                    await outboundFramePump.submitAudioPayload(wirePayload)\n                }"),
            "Captured audio chunks should enter the outbound pump at utility priority so they cannot preempt screen-frame work."
        )
        XCTAssertFalse(
            source.contains("Task.detached(priority: .userInitiated) {\n                    await outboundFramePump.submitAudioPayload(wirePayload)"),
            "Audio chunk submission must not run at the same priority as latency-critical video."
        )
    }

    func testWebRTCFallbackAudioDoesNotUseMainActorSendLoop() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("WebRTCAudioFallbackSender"),
            "WebRTC fallback audio should use a dedicated bounded sender."
        )
        XCTAssertTrue(
            source.contains("generation &+="),
            "WebRTC fallback audio sender should fence old-key sends across close/rekey."
        )
        XCTAssertTrue(
            source.contains("drainTask?.cancel()"),
            "WebRTC fallback audio sender should cancel in-flight background drain work on close."
        )
        XCTAssertFalse(
            source.contains("Task { @MainActor [weak self] in\n                                guard let self else { return }\n                                do {\n                                    let ciphertext = try encryptAppPayload(audioWire"),
            "WebRTC fallback audio must not encrypt and send every audio chunk from MainActor."
        )
        XCTAssertFalse(
            source.contains("await directAudioFallbackSender?.close()\n                    }\n#endif\n                    encodedFrameStore.clear()"),
            "WebRTC fallback audio close should not be fire-and-forget from the screen streaming defer."
        )
    }

    func testRemoteAudioPlaybackOverflowUsesBackpressureBeforeReset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteDesktop/AudioRedirection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("queued-audio-overflow"),
            "Normal live-audio jitter must not repeatedly stop/reset the player node; that creates audible crackle."
        )
        XCTAssertTrue(
            source.contains("logPlaybackBackpressureIfNeeded("),
            "Playback queue pressure should drop excess live chunks and let already scheduled audio drain naturally."
        )
        XCTAssertTrue(
            source.contains("queued-audio-runaway"),
            "A hard player reset should remain as a last-resort runaway guard, not the normal overflow path."
        )
        XCTAssertTrue(
            source.contains("queuedFrameCount + chunk.frameLength > currentMaxQueuedFrames"),
            "The soft cap must be checked before scheduling more audio into an already full player queue."
        )
        XCTAssertTrue(
            source.contains("Task.detached(priority: .utility) { [weak self, decodeWorker, chunk, generation] in"),
            "Remote audio decoding should stay below video/render priority to avoid starving the display path."
        )
        XCTAssertFalse(
            source.contains("Task.detached(priority: .userInitiated) { [weak self, decodeWorker, chunk, generation] in"),
            "Audio decoding must not run at userInitiated priority while the screen pipeline is active."
        )
    }

    func testP2PAudioDoesNotFallbackToPCMWhenAACEncodingFails() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/ScreenCaptureKitStreamer.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("系统音频 AAC 编码失败，已丢弃该音频块以保护远控视频帧率"),
            "If AAC encoding fails, remote-control audio should be dropped instead of falling back to high-bitrate PCM on the shared P2P pipe."
        )
        XCTAssertTrue(
            source.contains("if requestedAudioEncoding == .aacLC {\n            return\n        }"),
            "AAC-requested transport must not continue into PCM fallback after compression failure."
        )
        XCTAssertFalse(
            source.contains("系统音频 AAC 编码失败，已回退为 PCM 传输"),
            "PCM fallback can flood the shared P2P connection and collapse video frame rate."
        )
    }
}
