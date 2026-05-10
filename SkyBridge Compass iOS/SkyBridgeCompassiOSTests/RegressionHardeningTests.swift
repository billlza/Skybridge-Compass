import XCTest
import CryptoKit
import Network
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class RegressionHardeningTests: XCTestCase {
    func testMediaRelayLeaseDecoderUsesLocalRoleEndpoint() throws {
        let body = """
        {
          "mode": "skybridge-pqc-media-v1",
          "endpoint": { "host": "203.0.113.10", "port": 3478, "protocol": "udp" },
          "leaseToken": "local-token",
          "role": "responder",
          "sessionId": "session-a",
          "expiresAt": 1770000000000,
          "ttl": 60,
          "maxPacketBytes": 1200
        }
        """.data(using: .utf8)!

        let lease = try CrossNetworkWebRTCManager.testOnlyDecodeMediaRelayLeaseResponse(body)

        XCTAssertEqual(lease.localRole, "responder")
        XCTAssertEqual(lease.localToken, "local-token")
        XCTAssertEqual(lease.localExpiresAt, 1770000000)
    }

    @MainActor
    func testRemoteAudioInsufficientPriorityUsesLongerRetryBackoff() {
        let insufficientPriority = NSError(domain: NSOSStatusErrorDomain, code: 561_017_449)
        let genericFailure = NSError(domain: NSOSStatusErrorDomain, code: -50)

        XCTAssertGreaterThanOrEqual(
            RemoteDesktopManager.remoteAudioPlaybackRetryDelay(for: insufficientPriority),
            5.0
        )
        XCTAssertEqual(
            RemoteDesktopManager.remoteAudioPlaybackRetryDelay(for: genericFailure),
            1.0
        )
    }

    func testRemoteAudioSoftOverflowUsesBackpressureInsteadOfPlayerReset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("resetPlayerQueue(on: playerNode, reason: \"queued-audio-overflow\")"),
            "Soft audio backlog must not reset AVAudioPlayerNode; repeated resets cause audible crackle and queue churn."
        )
        XCTAssertTrue(
            source.contains("queuedFrames + chunk.frameLength > currentMaxQueuedFrames"),
            "Soft backlog should be handled before scheduling the next chunk."
        )
        XCTAssertTrue(
            source.contains("远端音频播放队列背压"),
            "Backpressure should be visible in logs without repeatedly rebuilding the player queue."
        )
        XCTAssertTrue(
            source.contains("queued-audio-runaway"),
            "A hard reset should remain available only for truly runaway queued audio."
        )
        XCTAssertTrue(
            source.contains("Task.detached(priority: .utility) { [remoteAudioPlayback] in\n            await remoteAudioPlayback.handle(payload, context: context)\n        }"),
            "Inbound audio playback work should stay below video/render priority so audio backpressure cannot halve the frame rate."
        )
        XCTAssertFalse(
            source.contains("Task.detached(priority: .userInitiated) { [remoteAudioPlayback] in\n            await remoteAudioPlayback.handle(payload, context: context)"),
            "Remote audio playback must not run at userInitiated priority while video frames are being decoded and displayed."
        )
    }

    func testViewerStreamConfigurationDoesNotAwaitRealtimeAudioReceiverStartup() throws {
        let source = try remoteDesktopManagerSource()

        XCTAssertTrue(source.contains("let mediaAudioBinding = currentRealtimeMediaAudioBindingIfUsable()"))
        XCTAssertTrue(source.contains("ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)"))
        XCTAssertFalse(
            source.contains("let mediaAudioBinding = await prepareRealtimeMediaAudioReceiverIfNeeded"),
            "The viewer must send the video/main config without awaiting realtime audio lease or receiver startup."
        )
        XCTAssertTrue(
            source.contains("await self.pushViewerStreamConfiguration(force: false, refreshStream: false)"),
            "The audio-present update should be a normal deduped config send, not a forced refresh."
        )
        XCTAssertTrue(
            source.contains("event=audioEndpointPrepared"),
            "The viewer should publish the relay endpoint after the configured relay bind policy is satisfied."
        )
        XCTAssertTrue(source.contains("strictRelayBindRequired ? .requireAcknowledgement : .optimisticAfterSend"))
        XCTAssertTrue(source.contains("relayBindPolicy: relayBindPolicy"))
        XCTAssertTrue(source.contains("payload.mediaAudioEndpoint == nil"))
    }

    func testRealtimeMediaAudioReceiverStartupIsSingleflightAndObservable() throws {
        let source = try remoteDesktopManagerSource()

        XCTAssertTrue(source.contains("guard realtimeMediaAudioReceiverStartTask == nil else { return }"))
        XCTAssertTrue(source.contains("realtimeMediaAudioReceiverStartGeneration"))
        XCTAssertTrue(source.contains("realtimeMediaAudioReceiverSlowDiagnosticDelay: Duration = .seconds(3)"))
        XCTAssertTrue(source.contains("realtimeMediaAudioReceiverStageTimeout: Duration = .seconds(8)"))
        XCTAssertTrue(source.contains("realtimeMediaAudioReceiverTotalTimeout: Duration = .seconds(15)"))
        XCTAssertTrue(source.contains("event=receiverStartPending"))
        XCTAssertTrue(source.contains("event=receiverStartSlow"))
        XCTAssertTrue(source.contains("event=leaseReady"))
        XCTAssertTrue(source.contains("event=udpConnectionStarted"))
        XCTAssertTrue(source.contains("event=relayBindSent"))
        XCTAssertTrue(source.contains("event=relayBindAccepted"))
        XCTAssertTrue(source.contains("event=relayBindAckTimedOut"))
        XCTAssertTrue(source.contains("event=receiverStarted"))
        XCTAssertTrue(source.contains("event=receiverStartFailed"))
        XCTAssertTrue(source.contains("event=audioPresentConfigSent"))
        XCTAssertTrue(source.contains("event=streamConfigSent"))
        XCTAssertFalse(
            source.contains("event=receiverStartTimeout"),
            "The 3s receiver startup diagnostic must no longer hard-cancel or report timeout; it is only receiverStartSlow."
        )
    }

    func testOptimisticRelayBindAckTimeoutUsesGraceInsteadOfImmediateLeaseRetry() throws {
        let source = try remoteDesktopManagerSource()
        let timeoutBody = try sourceSlice(
            from: "case .relayBindAckTimedOut:",
            to: "case .relayBindRejected:",
            in: source
        )
        let failureBody = try sourceSlice(
            from: "private func handleRealtimeMediaAudioRelayBindFailure",
            to: "private func scheduleRealtimeMediaAudioRelayBindGrace",
            in: source
        )
        let graceBody = try sourceSlice(
            from: "private func scheduleRealtimeMediaAudioRelayBindGrace",
            to: "private func handleRealtimeMediaAudioRelayTransportEvent",
            in: source
        )

        XCTAssertTrue(timeoutBody.contains("scheduleRealtimeMediaAudioRelayBindGrace"))
        XCTAssertTrue(timeoutBody.contains("action=optimistic-grace"))
        XCTAssertFalse(
            timeoutBody.contains("handleRealtimeMediaAudioRelayBindFailure"),
            "Optimistic relay bind ACK timeout must remain pending during the grace window instead of immediately invalidating the endpoint."
        )
        XCTAssertTrue(
            failureBody.contains("guard realtimeMediaAudioReceiverSessionId == sessionId"),
            "Late rejected/malformed events from an old relay transport must not poison the current endpoint."
        )
        XCTAssertLessThan(
            try XCTUnwrap(failureBody.range(of: "guard realtimeMediaAudioReceiverSessionId == sessionId")?.lowerBound),
            try XCTUnwrap(failureBody.range(of: "markRealtimeMediaRelayEndpointUnusableForActiveSession")?.lowerBound)
        )
        XCTAssertTrue(graceBody.contains("if snapshot.received > 0"))
        XCTAssertFalse(
            graceBody.contains("if snapshot.datagramsSeen > 0 || snapshot.received > 0"),
            "Grace success must require authenticated received audio, not just raw UDP bytes."
        )
        XCTAssertTrue(graceBody.contains("relayBindAckTimedOutNoTraffic"))
        XCTAssertTrue(graceBody.contains("relayBindAckTimedOutNoAuthenticatedTraffic"))
        XCTAssertTrue(source.contains("pushViewerStreamConfiguration(force: false, refreshStream: false)"))
    }

    func testRelayBindRejectedAndMalformedStillFailCurrentEndpoint() throws {
        let source = try remoteDesktopManagerSource()
        let failureCases = try sourceSlice(
            from: "case .relayBindRejected(let reason):",
            to: "private func updateRealtimeMediaAudioReceiverStartPhase",
            in: source
        )

        XCTAssertTrue(failureCases.contains("reason: \"relayBindRejected:"))
        XCTAssertTrue(failureCases.contains("reason: \"relayBindMalformed\""))
        XCTAssertTrue(failureCases.contains("handleRealtimeMediaAudioRelayBindFailure"))
    }

    func testRealtimeMediaAudioReceiverStartupFailureDoesNotRefreshVideoStream() throws {
        let source = try remoteDesktopManagerSource()
        let failureBody = try sourceSlice(
            from: "private func markRealtimeMediaAudioReceiverStartupFailed",
            to: "private func ensureRealtimeMediaAudioReceiverStartedIfNeeded",
            in: source
        )

        XCTAssertTrue(failureBody.contains("event=receiverStartFailed"))
        XCTAssertTrue(failureBody.contains("reason=\\(reason.rawValue)"))
        XCTAssertTrue(failureBody.contains("stage=\\(stage)"))
        XCTAssertFalse(
            failureBody.contains("pushViewerStreamConfiguration"),
            "Audio receiver startup failures must not send stream configuration updates."
        )
        XCTAssertFalse(
            failureBody.contains("refreshStream: true"),
            "Audio receiver startup failures must not request keyframes or topology refresh."
        )
        XCTAssertFalse(
            failureBody.contains("lastRequestedStreamRefreshReason"),
            "Audio receiver startup failures should stay out of video refresh diagnostics."
        )
    }

    func testStreamRefreshStormsAreThrottledDuringAudioPresentSessions() throws {
        let source = try remoteDesktopManagerSource()

        XCTAssertTrue(source.contains("private let streamDecodeStallRefreshMinimumInterval: TimeInterval = 3.0"))
        XCTAssertTrue(source.contains("reason: \"decode-stall-reset\",\n                        minimumInterval: self.streamDecodeStallRefreshMinimumInterval"))

        let hevcDisableBody = try sourceSlice(
            from: "case .disableHEVC(let until):",
            to: "case .reenableHEVCProbe:",
            in: source
        )
        XCTAssertTrue(
            hevcDisableBody.contains("lastRefreshRequestAt = now"),
            "HEVC disable refreshes must participate in the shared stream refresh cooldown so decode-stall reset cannot immediately send another forced config."
        )
    }

    func testSessionAuthorityLostStopsRemoteDesktopRetryLoops() throws {
        let source = try remoteDesktopManagerSource()

        XCTAssertTrue(source.contains("handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"stream-config\")"))
        XCTAssertTrue(source.contains("handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"first-frame-watchdog\")"))
        XCTAssertTrue(source.contains("handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"stream-config-ack-retry\")"))
        XCTAssertTrue(source.contains("handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"audio-receiver-start\")"))
        XCTAssertTrue(source.contains("handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"stream-refresh:\\(reason)\")"))
        XCTAssertTrue(source.contains("event=sessionAuthorityLost"))
        XCTAssertTrue(source.contains("state = .error(\"sessionAuthorityLost\")"))
    }

    func testStreamConfigurationAckHookStaysCompileCompatibleUntilSharedProducerExists() throws {
        let source = try remoteDesktopManagerSource()

        XCTAssertTrue(source.contains("Compile-compatible future hook"))
        XCTAssertTrue(source.contains("case streamConfigurationAck = \"streamConfigurationAck\""))
        XCTAssertTrue(source.contains("case .streamConfigurationAck:"))
        XCTAssertTrue(source.contains("handleStreamConfigurationAck"))
    }

    func testSBC2ReassemblerSuppressesRepeatedOrphanChunksUntilNextFrameStarts() throws {
        let frameId: UInt64 = 42
        var reassembler = CrossNetworkWebRTCManager.ScreenChunkedPayloadReassembler(
            maxFrameBytes: 4096
        )
        let start = Date(timeIntervalSince1970: 1_000)

        let orphan1 = CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope(
            frameId: frameId,
            chunkIndex: 1,
            chunkCount: 3,
            totalBytes: 12,
            chunkOffset: 4,
            payload: Data([1, 2, 3, 4])
        )
        XCTAssertEqual(
            reassembler.append(orphan1, now: start),
            .dropped(reason: "missing-first-chunk", frameId: frameId)
        )

        let orphan2 = CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope(
            frameId: frameId,
            chunkIndex: 2,
            chunkCount: 3,
            totalBytes: 12,
            chunkOffset: 8,
            payload: Data([5, 6, 7, 8])
        )
        XCTAssertEqual(
            reassembler.append(orphan2, now: start.addingTimeInterval(0.01)),
            .suppressed(frameId: frameId, reason: "missing-first-chunk")
        )

        let newFrame0 = CrossNetworkWebRTCManager.ScreenChunkedPayloadEnvelope(
            frameId: frameId + 1,
            chunkIndex: 0,
            chunkCount: 1,
            totalBytes: 4,
            chunkOffset: 0,
            payload: Data([9, 10, 11, 12])
        )
        XCTAssertEqual(
            reassembler.append(newFrame0, now: start.addingTimeInterval(0.02)),
            .complete(frameId: frameId + 1, payload: Data([9, 10, 11, 12]))
        )
    }

    private func remoteDesktopManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func crossNetworkWebRTCManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func webRTCSessionSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"
        )
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    func testRemoteDesktopSelectionOverlayIsDiagnosticOnlyByDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("SkyBridgeRemoteDesktopShowInteractionOverlay"),
            "Selection/focus overlay should be behind an explicit diagnostic toggle."
        )
        XCTAssertTrue(
            source.contains("remoteDesktopManager.frameRate >= 5"),
            "Diagnostic overlays should be suppressed while fallback FPS is too low to trust the screen content."
        )
        XCTAssertFalse(
            source.contains("overlayPayload: remoteDesktopManager.currentOverlayPayload"),
            "Viewer must not pass selection rects straight into the renderer by default; this caused the visible brown/yellow box."
        )
    }

    func testLANRemoteControlTrustResolverCollapsesEquivalentDuplicateRecords() {
        let device = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        let trustedDevices = [
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-a",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 100),
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:peer-mac"]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-mac",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 200),
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "legacy-peer-a"]
            )
        ]

        let resolution = LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: "id:peer-mac",
            trustedDevices: trustedDevices
        )

        switch resolution {
        case .resolved(let record, let canonicalPeerId):
            XCTAssertEqual(canonicalPeerId, "id:peer-mac")
            XCTAssertEqual(record.id, "legacy-peer-a")
        default:
            XCTFail("Expected a unique canonical trust resolution, got \(resolution)")
        }
    }

    func testLANRemoteControlTrustResolverRejectsConflictingRecords() {
        let device = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        let trustedDevices = [
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-a",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: "id:peer-mac-a",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:shared-bonjour-peer"]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-b",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                currentDeviceId: "id:peer-mac-b",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:shared-bonjour-peer"]
            )
        ]

        XCTAssertEqual(
            LANRemoteControlTrustResolver.resolve(
                device: device,
                trustedPeerId: "id:shared-bonjour-peer",
                trustedDevices: trustedDevices
            ),
            .ambiguous(
                deviceIds: ["id:peer-mac-a", "id:peer-mac-b"],
                fingerprints: [String(repeating: "a", count: 64), String(repeating: "b", count: 64)]
            )
        )
    }

    func testLANRemoteControlTrustResolverPrefersRecordWithAuthorityWhenDuplicatesAreEquivalent() {
        let device = DiscoveredDevice(
            id: "bonjour:Lza的MacBook Pro@local.",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        let trustedDevices = [
            TrustedDeviceStore.TrustedDevice(
                id: "legacy-peer-a",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 100),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:peer-mac"]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-mac",
                name: "Lza的MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                addedAt: Date(timeIntervalSince1970: 200),
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
                currentDeviceId: "id:peer-mac",
                knownDeviceIds: ["bonjour:lza的macbook pro@local.", "legacy-peer-a"]
            )
        ]

        let resolution = LANRemoteControlTrustResolver.resolve(
            device: device,
            trustedPeerId: "id:peer-mac",
            trustedDevices: trustedDevices
        )

        switch resolution {
        case .resolved(let record, let canonicalPeerId):
            XCTAssertEqual(canonicalPeerId, "id:peer-mac")
            XCTAssertEqual(record.id, "id:peer-mac")
            XCTAssertEqual(record.protocolPublicKeyFingerprint, String(repeating: "c", count: 64))
        default:
            XCTFail("Expected fingerprint-bearing record to win equivalent duplicate resolution, got \(resolution)")
        }
    }

    func testBonjourPrivacyManifestDeclaresAllBrowsedServiceTypes() {
        XCTAssertTrue(DeviceDiscoveryManager.hasLocalNetworkUsageDescription())

        let declared = DeviceDiscoveryManager.declaredBonjourServices()
        let expected = Set(DiscoveryServiceType.requiredBonjourPrivacyDeclarations)

        XCTAssertEqual(
            declared,
            expected,
            "Info.plist 的 NSBonjourServices 必须覆盖代码实际可浏览的全部服务类型，避免 NoAuth(-65555) 配置漂移。"
        )
    }

    func testNoAuthBrowseFailureDoesNotAutoRecover() {
        let error = NWError.dns(DeviceDiscoveryManager.bonjourAuthorizationDNSCode)

        XCTAssertTrue(DeviceDiscoveryManager.isBonjourAuthorizationError(error))
        XCTAssertFalse(DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: error))
    }

    func testTransientBrowserFailuresStillAutoRecover() {
        let error = NWError.posix(.ENETDOWN)

        XCTAssertFalse(DeviceDiscoveryManager.isBonjourAuthorizationError(error))
        XCTAssertTrue(DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: error))
    }

    func testAuthorizationRecoveryDelayUsesBoundedBackoff() {
        XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 1), 2)
        XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 2), 5)
        XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 3), 10)
        XCTAssertNil(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 4))
    }

    @MainActor
    func testOfflineQueueCleanupRemovesExpiredPendingAndFailedMessages() {
        let queue = OfflineMessageQueue.shared
        queue.clear()
        defer { queue.clear() }

        let expiredPending = OfflineMessage(
            id: "expired-pending-\(UUID().uuidString)",
            targetDeviceId: "peer-a",
            messageType: .text,
            payload: Data("p".utf8),
            expiresAt: Date().addingTimeInterval(-60)
        )

        let expiredFailed = OfflineMessage(
            id: "expired-failed-\(UUID().uuidString)",
            targetDeviceId: "peer-b",
            messageType: .text,
            payload: Data("f".utf8),
            expiresAt: Date().addingTimeInterval(-60)
        )

        let liveFailed = OfflineMessage(
            id: "live-failed-\(UUID().uuidString)",
            targetDeviceId: "peer-c",
            messageType: .text,
            payload: Data("live".utf8),
            expiresAt: Date().addingTimeInterval(3600)
        )

        queue.enqueue(expiredPending)
        queue.enqueue(expiredFailed)
        queue.enqueue(liveFailed)

        for _ in 0..<3 {
            queue.markAsFailed(expiredFailed.id)
            queue.markAsFailed(liveFailed.id)
        }

        XCTAssertEqual(queue.totalCount, 3)

        queue.cleanupExpiredMessages()

        XCTAssertEqual(queue.totalCount, 1)
        XCTAssertTrue(queue.pendingMessages.isEmpty)
        XCTAssertEqual(queue.failedMessages.count, 1)
        XCTAssertEqual(queue.failedMessages.first?.id, liveFailed.id)
    }

    @MainActor
    func testTrustedDeviceStoreTreatsDiscoveryIdAsTrustedAlias() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let rawDeviceId = UUID().uuidString.lowercased()
        let trustedDevice = DiscoveredDevice(
            id: "id:\(rawDeviceId)",
            name: "Trusted Mac",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        store.trust(trustedDevice)

        XCTAssertTrue(store.isTrusted(deviceId: rawDeviceId))
        XCTAssertTrue(store.isTrusted(deviceId: "id:\(rawDeviceId)"))
    }

    @MainActor
    func testTrustedDeviceStoreResolvesHostAliasBackToCanonicalTrustedID() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let rawDeviceId = UUID().uuidString.lowercased()
        let trustedDevice = DiscoveredDevice(
            id: "id:\(rawDeviceId)",
            name: "Trusted iPhone",
            modelName: "iPhone 16 Pro",
            platform: .iOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        store.trust(trustedDevice)

        XCTAssertTrue(store.isTrusted(deviceId: "host:fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            store.canonicalTrustedDeviceId(for: "host:fe80::81d:bb45:8c18:6d6a%en0"),
            "id:\(rawDeviceId)"
        )
    }

    func testConnectableAddressCanonicalizerPreservesLinkLocalScopeForConnectionTargets() {
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.connectionTarget("host:fe80::468:f5a1:462b:29d3%bridge100"),
            "fe80::468:f5a1:462b:29d3%bridge100"
        )
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.connectionTarget("[fe80::468:f5a1:462b:29d3%bridge100].5901"),
            "fe80::468:f5a1:462b:29d3%bridge100"
        )
    }

    func testConnectableAddressCanonicalizerStripsInterfaceScopeForLookupKeys() {
        XCTAssertEqual(
            ConnectableAddressCanonicalizer.lookupKey("host:fe80::468:f5a1:462b:29d3%bridge100"),
            "fe80::468:f5a1:462b:29d3"
        )
    }

    func testViewerCapabilityDoesNotImplyRemoteControlHostSupport() {
        let viewerOnly = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Viewer iPhone",
            modelName: "iPhone 16 Pro",
            platform: .iOS,
            osVersion: "18.0",
            ipAddress: nil,
            services: [],
            portMap: [:],
            signalStrength: -50,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: false,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop_viewer"],
            capabilities: ["remote_desktop_viewer"]
        )
        XCTAssertFalse(viewerOnly.supportsRemoteControl)

        let controlHost = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Remote Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20",
            services: [],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop", "remote_control"],
            capabilities: ["remote_desktop", "remote_control"]
        )
        XCTAssertTrue(controlHost.supportsRemoteControl)
    }

    @MainActor
    func testDeviceDiscoveryCleanupPreservesSilentDeviceWhenBrowserStillHasLiveEndpoint() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let device = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::18ac:9228:7844:60fe%en0"
        )
        let endpointKey = "Lza的MacBook\\032Pro._skybridge._tcp.local."

        manager.debugSeedDiscoveryState(
            devices: [device],
            lastActivity: Date().addingTimeInterval(-180),
            endpointToDeviceId: [endpointKey: device.id],
            liveBrowseEndpointKeysByServiceType: [DiscoveryServiceType.skybridge: [endpointKey]]
        )

        manager.debugRunCleanupStaleDevices()

        XCTAssertTrue(manager.debugCachedDeviceIds.contains(device.id))
        XCTAssertEqual(manager.discoveredDevices.first?.id, device.id)
    }

    @MainActor
    func testDeviceDiscoveryCleanupRemovesTrulyStaleDeviceWithoutLiveEndpoint() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        let device = DiscoveredDevice(
            id: "id:\(UUID().uuidString.lowercased())",
            name: "Old Mac",
            modelName: "Mac mini",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.8"
        )

        manager.debugSeedDiscoveryState(
            devices: [device],
            lastActivity: Date().addingTimeInterval(-180),
            endpointToDeviceId: [:],
            liveBrowseEndpointKeysByServiceType: [:]
        )

        manager.debugRunCleanupStaleDevices()

        XCTAssertFalse(manager.debugCachedDeviceIds.contains(device.id))
        XCTAssertTrue(manager.discoveredDevices.isEmpty)
    }

    @MainActor
    func testRetryAuthorizationBlockedBrowsersClearsBlockedStateAndAttempts() {
        let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
        manager.debugSeedAuthorizationRecoveryState(
            blockedServiceTypes: [.skybridge, .skybridgeTransfer],
            attempts: [.skybridge: 2, .skybridgeTransfer: 1],
            isDiscovering: true
        )

        manager.retryAuthorizationBlockedBrowsers()

        XCTAssertTrue(manager.debugAuthorizationBlockedServiceTypes.isEmpty)
        XCTAssertTrue(manager.debugAuthorizationRecoveryAttempts.isEmpty)
    }

    @MainActor
    func testRemoteDesktopBootstrapGuardRejectsFailedLANSession() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: true,
                isCurrentLANConnection: true,
                state: .error("连接已断开")
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: false,
                isCurrentLANConnection: true,
                state: .connected
            )
        )
        XCTAssertTrue(
            RemoteDesktopManager.shouldContinueLANBootstrap(
                activeTransportModeIsLAN: true,
                isCurrentLANConnection: true,
                state: .connected
            )
        )
    }

    @MainActor
    func testRemoteDesktopPresentationOwnersRequireLastOwnerToDisconnect() {
        let manager = RemoteDesktopManager.instance
        let firstOwner = UUID()
        let secondOwner = UUID()

        manager.registerPresentationOwner(firstOwner)
        manager.registerPresentationOwner(secondOwner)

        XCTAssertFalse(manager.unregisterPresentationOwner(firstOwner))
        XCTAssertTrue(manager.unregisterPresentationOwner(secondOwner))
    }

    @MainActor
    func testRemoteDesktopPresentationOwnerIgnoresUnknownTokenWhileActiveOwnerRemains() {
        let manager = RemoteDesktopManager.instance
        let activeOwner = UUID()

        manager.registerPresentationOwner(activeOwner)

        XCTAssertFalse(manager.unregisterPresentationOwner(UUID()))
        XCTAssertTrue(manager.unregisterPresentationOwner(activeOwner))
    }

    @MainActor
    func testViewerStreamConfigurationRespectsAudioRedirectionPreference() {
        let manager = RemoteDesktopManager.instance
        let originalSettings = manager.viewerSettings
        defer { manager.viewerSettings = originalSettings }

        var disabledSettings = originalSettings
        disabledSettings.audioRedirectionEnabled = false
        manager.viewerSettings = disabledSettings

        XCTAssertEqual(manager.makeViewerStreamConfigurationPayload().audioRedirectionEnabled, false)

        var enabledSettings = originalSettings
        enabledSettings.audioRedirectionEnabled = true
        manager.viewerSettings = enabledSettings

        XCTAssertEqual(manager.makeViewerStreamConfigurationPayload().audioRedirectionEnabled, true)
    }

    func testLegacyViewerSettingsDecodeDefaultsAudioRedirectionToEnabled() throws {
        let data = Data(
            """
            {
              "resolution": "auto",
              "frameRate": "adaptive",
              "preferredCodec": "automatic",
              "clipboardSyncEnabled": true,
              "lowLatencyMode": false
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(RemoteDesktopViewerSettings.self, from: data)

        XCTAssertTrue(decoded.audioRedirectionEnabled)
    }

    func testFallbackRemoteAudioDelayBypassesWaitingWhenNativeReceiveDisabled() {
        XCTAssertNil(
            RemoteDesktopManager.fallbackRemoteAudioUnlockAt(
                activeTransportModeIsCrossNetwork: true,
                nativeAudioReceiveEnabled: false,
                remoteAudioTrackHasReceivedFirstPacket: false,
                currentUnlockAt: nil,
                now: Date(timeIntervalSince1970: 100)
            )
        )
    }

    func testFallbackRemoteAudioDelayWaitsForNativeFirstPacketOnlyWhenNativeReceiveEnabled() {
        let now = Date(timeIntervalSince1970: 100)
        let unlockAt = RemoteDesktopManager.fallbackRemoteAudioUnlockAt(
            activeTransportModeIsCrossNetwork: true,
            nativeAudioReceiveEnabled: true,
            remoteAudioTrackHasReceivedFirstPacket: false,
            currentUnlockAt: nil,
            now: now
        )

        XCTAssertNotNil(unlockAt)
        XCTAssertEqual(unlockAt!.timeIntervalSince1970, 101.25, accuracy: 0.0001)
    }

    @MainActor
    func testViewerStreamConfigurationKeepsAudioOnStableFallbackPath() {
        let payload = RemoteDesktopManager.instance.makeViewerStreamConfigurationPayload()

        XCTAssertEqual(payload.nativeAudioTrackEnabled, false)
        XCTAssertEqual(payload.audioRedirectionEnabled, RemoteDesktopManager.instance.viewerSettings.audioRedirectionEnabled)
        XCTAssertEqual(payload.audioTransport, "pqc-media-v1")
        XCTAssertEqual(payload.compatibilityAudioFallbackEnabled, false)
        XCTAssertNil(payload.preferredAudioEncoding)
        XCTAssertEqual(payload.audioSampleRate, 48_000)
        XCTAssertEqual(payload.audioChannelCount, 2)
    }

    func testPQCRealtimeAudioReceiverUsesOpusRingBufferPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RealtimeMediaAudio.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("AVAudioSourceNode"))
        XCTAssertTrue(source.contains("pqc-opus-source-node-ring"))
        XCTAssertTrue(source.contains("queuedMs="))
        XCTAssertTrue(source.contains("targetQueuedMs="))
        XCTAssertTrue(source.contains("rebufferResumeMs="))
        XCTAssertTrue(source.contains("softUnderflowBridgeMs="))
        XCTAssertTrue(source.contains("bridgedUnderflowFrames"))
        XCTAssertTrue(source.contains("effectiveJitterTargetMs"))
        XCTAssertTrue(source.contains("effectiveJitterMaxMs"))
        XCTAssertTrue(source.contains("adaptationReason"))
        XCTAssertTrue(source.contains("stableJitterWindowCount"))
        XCTAssertTrue(source.contains("initialJitterTargetMs"))
        XCTAssertTrue(source.contains("return max(profile.jitterTargetMs, 700)"))
        XCTAssertTrue(source.contains("return max(profile.jitterMaxMs, 1_400)"))
        XCTAssertTrue(source.contains("return max(profile.jitterTargetMs, 520)"))
        XCTAssertTrue(source.contains("return max(profile.jitterMaxMs, 900)"))
        XCTAssertTrue(source.contains("return max(profile.jitterTargetMs, 900)"))
        XCTAssertTrue(source.contains("return max(profile.jitterMaxMs, 1_600)"))
        XCTAssertTrue(source.contains("stableJitterWindowCount >= 6"))
        XCTAssertTrue(source.contains("underflow > 0"))
        XCTAssertTrue(source.contains("scheduleLeadMs < -60"))
        XCTAssertTrue(source.contains("scheduleLeadMs < -100"))
        XCTAssertTrue(source.contains("evictRatio="))
        XCTAssertTrue(source.contains("audioArrivalP50Ms"))
        XCTAssertTrue(source.contains("audioArrivalP95Ms"))
        XCTAssertTrue(source.contains("audioArrivalMaxMs"))
        XCTAssertTrue(source.contains("audioJitterBufferDepthMs"))
        XCTAssertTrue(source.contains("hasStartedPlayback ? rebufferResumeFrames : targetQueuedFrames"))
        XCTAssertTrue(source.contains("primed="))
        XCTAssertTrue(source.contains("rebuffer="))
        XCTAssertTrue(source.contains("underflow="))
        XCTAssertTrue(source.contains("overflow="))
        XCTAssertTrue(source.contains("playback prebuffering"))
        XCTAssertTrue(source.contains("setPreferredIOBufferDuration(mode == .lowLatency ? 0.005 : 0.01)"))
        XCTAssertFalse(
            source.contains("scheduleBuffer("),
            "PQC realtime audio should use the pull/ring-buffer path, not AVAudioPlayerNode buffer scheduling."
        )
    }

    func testFallbackNativeVideoEvidenceDiagnosticIsThrottled() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("lastFallbackOnlyNativeVideoDiagnosticAt"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(lastFallbackOnlyNativeVideoDiagnosticAt) >= 2.0"))
        XCTAssertEqual(
            source.components(separatedBy: "fallback screen data confirms only degraded screen path").count - 1,
            1
        )
    }

    func testHighFidelityRealtimeAudioProfileKeepsRelayJitterHeadroom() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let profileURL = root.appendingPathComponent(
            "SkyBridge Compass iOS/LocalPackages/SkyBridgeMediaLocal/Sources/SkyBridgeRealtimeMedia/MediaProfile.swift"
        )
        let source = try String(contentsOf: profileURL, encoding: .utf8)
        let highFidelityBody = try sourceSlice(
            from: "case .highFidelity:",
            to: "}\n    }\n\n    public var samplesPerPacket",
            in: source
        )

        XCTAssertTrue(highFidelityBody.contains("jitterTargetMs: 140"))
        XCTAssertTrue(highFidelityBody.contains("jitterMaxMs: 360"))
    }

    func testCrossNetworkFrameNotificationRequiresActiveStreamingSession() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldProcessCrossNetworkFrameNotification(
                isStreaming: false,
                subscribedSessionId: "session-1",
                expectedSessionId: "session-1",
                updateSessionId: "session-1"
            )
        )
    }

    func testNativeVideoRenderedIgnoresFallbackScreenFrames() {
        // Once native WebRTC has rendered a frame, screen-channel fallback must
        // not reclaim topology/decode ownership even if a previous fallback
        // frame already pushed the UI out of the native pipeline.
        XCTAssertTrue(
            RemoteDesktopManager.shouldIgnoreFallbackFrameAfterNativeVideoRendered(
                activeTransportModeIsCrossNetwork: true,
                nativeVideoTrackHasRenderedFrame: true
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldIgnoreFallbackFrameAfterNativeVideoRendered(
                activeTransportModeIsCrossNetwork: true,
                nativeVideoTrackHasRenderedFrame: false
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldIgnoreFallbackFrameAfterNativeVideoRendered(
                activeTransportModeIsCrossNetwork: false,
                nativeVideoTrackHasRenderedFrame: true
            )
        )
    }

    func testReceiverStatsDoNotCountAsActualNativeRenderEvidence() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("rtc-mtl-video-view")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("heartbeat-renderer"),
            "The heartbeat renderer is attached beside the visible view, so it only proves track delivery, not visible native video."
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("receiver-stats"),
            "Receiver stats prove inbound RTP/decode, not that the native video view rendered visible pixels."
        )
    }

    func testHeartbeatRendererFrameCanStartVisibleNativeRenderProbeWithoutPromoting() throws {
        let source = try crossNetworkWebRTCManagerSource()
        let evidenceBody = try sourceSlice(
            from: "func noteRemoteVideoTrackRenderedFrame(\n        _ size: CGSize,",
            to: "@MainActor\n    func noteRemoteVideoTrackReceivedFirstPacket",
            in: source
        )
        let heartbeatBranch = try sourceSlice(
            from: "source == \"receiver-stats\" || source == \"heartbeat-renderer\"",
            to: "guard Self.isActualNativeRenderEvidence(source: source) else { return }",
            in: evidenceBody
        )

        XCTAssertTrue(heartbeatBranch.contains("track-renderer-frame-evidence"))
        XCTAssertTrue(heartbeatBranch.contains("native-heartbeat-frame-evidence"))
        XCTAssertTrue(heartbeatBranch.contains("scheduleNativeRenderProbeIfNeeded(trigger: source)"))
        XCTAssertFalse(
            heartbeatBranch.contains("markRemoteVideoTrackReadyForPromotion"),
            "Heartbeat renderer frames may raise the visible native probe, but only the visible RTCMTLVideoView render path can promote nativeReady."
        )
    }

    func testNativeVideoFallbackScreenGuardRunsBeforeTopologyHandling() throws {
        let remoteDesktopSource = try remoteDesktopManagerSource()
        let handleScreenDataBody = try sourceSlice(
            from: "private func handleScreenData(_ screenData: ScreenData) async",
            to: "private func handleIncomingStreamTopologyChangeIfNeeded(for screenData: ScreenData) async",
            in: remoteDesktopSource
        )
        guard let warmupDropGuardRange = handleScreenDataBody.range(of: "shouldDropNativeWarmupNonJPEGFallbackFrame"),
              let renderedGuardRange = handleScreenDataBody.range(of: "shouldIgnoreFallbackFrameAfterNativeVideoRendered"),
              let noteReceivedRange = handleScreenDataBody.range(of: "noteReceivedFrame"),
              let topologyRange = handleScreenDataBody.range(of: "handleIncomingStreamTopologyChangeIfNeeded") else {
            return XCTFail("Expected native warmup/rendered fallback guards and topology handler in handleScreenData.")
        }
        XCTAssertLessThan(
            warmupDropGuardRange.lowerBound,
            noteReceivedRange.lowerBound,
            "Native warmup non-JPEG fallback frames must be dropped before frame accounting can mark them as a real screen frame."
        )
        XCTAssertLessThan(
            warmupDropGuardRange.lowerBound,
            topologyRange.lowerBound,
            "Native warmup non-JPEG fallback frames must be dropped before topology/decode state can be polluted."
        )
        XCTAssertLessThan(
            renderedGuardRange.lowerBound,
            topologyRange.lowerBound,
            "Native-rendered fallback frames must be ignored before topology/decode state can be reset."
        )
        XCTAssertTrue(handleScreenDataBody.contains("dropReason=native-warmup-non-jpeg-fallback"))
    }

    func testNativeWarmupFallbackGuardAcceptsOnlyJPEGUntilVisibleNativeRender() {
        XCTAssertTrue(
            RemoteDesktopManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                activeTransportModeIsCrossNetwork: true,
                hasRemoteNativeVideoTrack: true,
                nativeVideoTrackHasRenderedFrame: false,
                format: "hevc"
            )
        )
        XCTAssertTrue(
            RemoteDesktopManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                activeTransportModeIsCrossNetwork: true,
                hasRemoteNativeVideoTrack: true,
                nativeVideoTrackHasRenderedFrame: false,
                format: "h264"
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                activeTransportModeIsCrossNetwork: true,
                hasRemoteNativeVideoTrack: true,
                nativeVideoTrackHasRenderedFrame: false,
                format: "jpeg"
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                activeTransportModeIsCrossNetwork: true,
                hasRemoteNativeVideoTrack: true,
                nativeVideoTrackHasRenderedFrame: false,
                format: "jpg"
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
                activeTransportModeIsCrossNetwork: true,
                hasRemoteNativeVideoTrack: true,
                nativeVideoTrackHasRenderedFrame: true,
                format: "hevc"
            )
        )
    }

    func testNativeVideoPipelineOwnershipRejectsImplicitWaitingDemotion() throws {
        let remoteDesktopSource = try remoteDesktopManagerSource()
        let updatePipelineBody = try sourceSlice(
            from: "private func updateRenderPipeline(_ pipeline: RemoteDesktopRenderPipeline)",
            to: "private func flushRenderedVideoFeeds",
            in: remoteDesktopSource
        )

        XCTAssertTrue(updatePipelineBody.contains("crossNetwork.remoteVideoTrackHasRenderedFrame"))
        XCTAssertTrue(updatePipelineBody.contains("renderPipelineStatus == .webrtcNativeVideo"))
        XCTAssertTrue(
            updatePipelineBody.contains("pipeline != .webrtcNativeVideo"),
            "After visible native render evidence, only explicit native pipeline ownership should remain in this stream epoch."
        )
        XCTAssertFalse(
            updatePipelineBody.contains("pipeline != .waiting"),
            "Topology resets must not be able to demote a visible native video pipeline into waiting state."
        )
    }

    func testFallbackEvidenceDoesNotAdvertiseNativeVideoReady() throws {
        let crossNetworkSource = try crossNetworkWebRTCManagerSource()
        let remoteDesktopSource = try remoteDesktopManagerSource()

        let fallbackBody = try sourceSlice(
            from: "private func maybeConfirmRemoteVideoTrackFromFallbackEvidence",
            to: "@MainActor\n    private func markRemoteVideoTrackReadyForPromotion",
            in: crossNetworkSource
        )
        XCTAssertFalse(
            fallbackBody.contains("markRemoteVideoTrackReadyForPromotion"),
            "Fallback screen data must not advance native video promotion; nativeReady is reserved for actual native render evidence."
        )
        XCTAssertTrue(fallbackBody.contains("native promotion still waits for real RTP/render evidence"))

        let promotionReadyBody = try sourceSlice(
            from: "func handleCrossNetworkNativeVideoTrackPromotionReady()",
            to: "func handleCrossNetworkNativeAudioTrackReceivedFirstPacket()",
            in: remoteDesktopSource
        )
        XCTAssertFalse(
            promotionReadyBody.contains("announceCrossNetworkNativeVideoReadyIfNeeded"),
            "Promotion-ready without a rendered native frame must not send nativeVideoTrackReady=true."
        )
    }

    func testReceiverStatsDoNotPromoteBeforeActualNativeRenderEvidence() throws {
        let crossNetworkSource = try crossNetworkWebRTCManagerSource()
        let renderedFrameBody = try sourceSlice(
            from: "func noteRemoteVideoTrackRenderedFrame(_ size: CGSize, source: String)",
            to: "@MainActor\n    func noteRemoteVideoTrackReceivedFirstPacket(source: String)",
            in: crossNetworkSource
        )
        guard let actualEvidenceGuard = renderedFrameBody.range(of: "guard Self.isActualNativeRenderEvidence(source: source) else { return }"),
              let watchdogCancel = renderedFrameBody.range(of: "remoteVideoTrackConfirmationTask?.cancel()"),
              let pipelinePromotion = renderedFrameBody.range(of: "noteCrossNetworkNativeVideoFrame") else {
            return XCTFail("Expected actual-evidence guard, watchdog cancel, and native pipeline promotion in rendered frame handler.")
        }
        XCTAssertLessThan(actualEvidenceGuard.lowerBound, watchdogCancel.lowerBound)
        XCTAssertLessThan(actualEvidenceGuard.lowerBound, pipelinePromotion.lowerBound)
        guard let promotionReady = renderedFrameBody.range(of: "markRemoteVideoTrackReadyForPromotion") else {
            return XCTFail("Expected actual rendered frame evidence to mark native video promotion-ready.")
        }
        XCTAssertLessThan(
            actualEvidenceGuard.lowerBound,
            promotionReady.lowerBound,
            "Receiver stats, heartbeat renderer, and packet evidence must not set promotion-ready before actual visible native render evidence."
        )
        XCTAssertTrue(renderedFrameBody.contains("renderEpoch: UInt64?"))
        XCTAssertTrue(renderedFrameBody.contains("guard let renderEpoch,"))
        XCTAssertTrue(renderedFrameBody.contains("renderEpoch == remoteVideoTrackRenderEpoch"))
        XCTAssertTrue(renderedFrameBody.contains("ignore stale native render evidence"))
        XCTAssertTrue(renderedFrameBody.contains("reason=probe-inactive"))
        XCTAssertTrue(renderedFrameBody.contains("reason=track-mismatch"))
        XCTAssertTrue(renderedFrameBody.contains("reason=epoch-mismatch"))
        XCTAssertTrue(crossNetworkSource.contains("@Published public private(set) var remoteVideoTrackRenderEpoch"))
        XCTAssertTrue(crossNetworkSource.contains("remoteVideoTrackRenderEpoch &+= 1"))
        XCTAssertTrue(crossNetworkSource.contains("func currentRemoteVideoTrackRenderToken(trackId: String?) -> UInt64"))
        XCTAssertFalse(
            crossNetworkSource.contains("let shouldPreserveRenderedEvidence = track != nil && isTrackRebind && preservedRenderedFrame"),
            "A same-id track rebind must require fresh visible render evidence from the new renderer epoch."
        )

        let firstPacketBody = try sourceSlice(
            from: "func noteRemoteVideoTrackReceivedFirstPacket(source: String)",
            to: "@MainActor\n    func noteRemoteAudioTrackReceivedFirstPacket(source: String)",
            in: crossNetworkSource
        )
        XCTAssertFalse(
            firstPacketBody.contains("markRemoteVideoTrackReadyForPromotion"),
            "Inbound packet evidence proves RTP arrival only; it must not satisfy native promotion."
        )

        let resolutionBody = try sourceSlice(
            from: "func noteRemoteVideoTrackResolutionAvailable(_ size: CGSize, source: String)",
            to: "@MainActor\n    private func bestAvailableRemoteVideoEvidenceSize()",
            in: crossNetworkSource
        )
        XCTAssertFalse(
            resolutionBody.contains("markRemoteVideoTrackReadyForPromotion"),
            "Size callbacks can arrive without visible pixels and must not satisfy native promotion."
        )

        let confirmationBody = try sourceSlice(
            from: "private func scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: String)",
            to: "@MainActor\n    func noteRemoteVideoTrackRenderedFrame(_ size: CGSize, source: String)",
            in: crossNetworkSource
        )
        XCTAssertFalse(
            confirmationBody.contains("markRemoteVideoTrackReadyForPromotion"),
            "The native render watchdog should diagnose missing visible frames, not promote from fallback evidence."
        )
    }

    func testNativeRenderProbeRaisesRTCMTLViewWithoutPromotingFromStats() throws {
        let crossNetworkSource = try crossNetworkWebRTCManagerSource()
        let viewSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(crossNetworkSource.contains("@Published public private(set) var nativeVideoProbeActive"))
        XCTAssertTrue(crossNetworkSource.contains("scheduleNativeRenderProbeIfNeeded(trigger: source)"))
        XCTAssertTrue(crossNetworkSource.contains("allowsPacketOnlyEvidence: true"))
        XCTAssertTrue(crossNetworkSource.contains("native-render-probe-packet-active"))
        XCTAssertTrue(crossNetworkSource.contains("handleCrossNetworkNativeVideoWarmupEvidence"))
        XCTAssertTrue(crossNetworkSource.contains("reason: \"native-track-installed\""))
        XCTAssertTrue(crossNetworkSource.contains("\"native-receiver-frame-evidence\""))
        XCTAssertTrue(crossNetworkSource.contains("\"native-heartbeat-frame-evidence\""))
        XCTAssertTrue(crossNetworkSource.contains("reason: warmupReason"))
        XCTAssertTrue(crossNetworkSource.contains("native-render-probe-start"))
        XCTAssertTrue(crossNetworkSource.contains("native-render-probe-timeout"))
        XCTAssertTrue(crossNetworkSource.contains("action=raise-rtc-mtl-video-view"))
        XCTAssertTrue(crossNetworkSource.contains("try await Task.sleep(for: .milliseconds(2_500))"))
        XCTAssertTrue(viewSource.contains("probeNativeVideoAboveFallback"))
        XCTAssertTrue(viewSource.contains("nativeVideoHasInboundFrameEvidence"))
        XCTAssertTrue(viewSource.contains("nativeVideoOwnsSurface"))
        XCTAssertTrue(viewSource.contains("crossNetworkManager.nativeVideoProbeActive"))
        XCTAssertTrue(viewSource.contains("crossNetworkManager.remoteVideoTrackHasReceiverFrameEvidence"))
        XCTAssertTrue(viewSource.contains("&& !crossNetworkManager.remoteVideoTrackHasRenderedFrame"))

        let remoteScreenBody = try sourceSlice(
            from: "private func remoteScreenView(geometry: GeometryProxy) -> some View",
            to: "#else\n            RemoteDesktopCompositedSurface",
            in: viewSource
        )
        let nativeSurfaceCount = remoteScreenBody.components(
            separatedBy: "RemoteDesktopNativeVideoSurface("
        ).count - 1
        XCTAssertEqual(
            nativeSurfaceCount,
            1,
            "The same RTCMTLVideoView wrapper should stay mounted; probe should raise it with zIndex instead of rebuilding it."
        )
        XCTAssertTrue(remoteScreenBody.contains(".zIndex(probeNativeVideoAboveFallback ? 0 : 1)"))
        XCTAssertTrue(remoteScreenBody.contains(".zIndex(nativeVideoOwnsSurface ? 2 : 0)"))
        XCTAssertTrue(remoteScreenBody.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(remoteScreenBody.contains("nativeVideoHasInboundFrameEvidence"))
    }

    func testRemoteVideoStatsProbeResyncsReceiverTrackBeforeEvidence() throws {
        let source = try webRTCSessionSource()
        let evidenceLoop = try sourceSlice(
            from: "private func startRemoteVideoFrameEvidenceObservation()",
            to: "private func remoteInboundVideoStatsSamples",
            in: source
        )
        let refreshBody = try sourceSlice(
            from: "private func refreshRemoteVideoTrackFromReceiverIfNeeded",
            to: "private func remoteInboundVideoStatsSamples",
            in: source
        )

        XCTAssertTrue(source.contains("refreshRemoteVideoTrackFromReceiverIfNeeded"))
        XCTAssertTrue(source.contains("remote-video-track-sync"))
        XCTAssertTrue(evidenceLoop.contains("resolveRemoteVideoReceivers"))
        XCTAssertTrue(evidenceLoop.contains("for receiver in receivers"))
        XCTAssertTrue(evidenceLoop.contains("source: \"receiver-specific\""))
        XCTAssertTrue(evidenceLoop.contains("source: \"peer-fallback\""))
        XCTAssertTrue(evidenceLoop.contains("reason: \"active-receiver-stats\""))
        XCTAssertTrue(evidenceLoop.contains("remote-video-frame-evidence session=\\(self.sessionId) \\(candidate.summary)"))
        XCTAssertTrue(refreshBody.contains("receiverStatsProbeRemoteVideoTrackRefreshAction"))
        XCTAssertTrue(refreshBody.contains("guard refreshAction == .rebind else {\n            return false\n        }"))
        let sameTrackIdGuard = refreshBody.range(
            of: "guard refreshAction == .rebind"
        )?.lowerBound ?? refreshBody.endIndex
        let syncLog = refreshBody.range(of: "remote native video track refreshed from receiver stats probe")?.lowerBound
            ?? refreshBody.startIndex
        XCTAssertLessThan(
            sameTrackIdGuard,
            syncLog,
            "Receiver stats polling may return a fresh Swift wrapper for the same native track; same trackId must be a no-op before rebind logging or handler publication."
        )
        let syncIndex = evidenceLoop.range(of: "refreshRemoteVideoTrackFromReceiverIfNeeded")?.lowerBound
            ?? evidenceLoop.endIndex
        let evidenceIndex = evidenceLoop.range(of: "remote-video-frame-evidence")?.lowerBound
            ?? evidenceLoop.startIndex
        XCTAssertTrue(
            syncIndex < evidenceIndex,
            "The active receiver-backed track must be installed before receiver-stats evidence can start a native render probe."
        )
    }

    func testReceiverStatsProbeSameTrackIdRefreshIsAlwaysNoOp() throws {
        let source = try webRTCSessionSource()
        let refreshBody = try sourceSlice(
            from: "private func refreshRemoteVideoTrackFromReceiverIfNeeded",
            to: "private func remoteInboundVideoStatsSamples",
            in: source
        )

        XCTAssertEqual(
            WebRTCSession.receiverStatsProbeRemoteVideoTrackRefreshAction(
                currentTrackId: "video-1",
                receiverTrackId: " video-1 ",
                hasCurrentRemoteVideoTrack: true
            ),
            .noOp
        )
        XCTAssertEqual(
            WebRTCSession.receiverStatsProbeRemoteVideoTrackRefreshAction(
                currentTrackId: "video-1",
                receiverTrackId: "video-1",
                hasCurrentRemoteVideoTrack: true
            ),
            .noOp,
            "Receiver stats probe can vend fresh RTCVideoTrack wrappers for the same native track; same trackId must never publish a rebind from this polling path."
        )
        XCTAssertEqual(
            WebRTCSession.receiverStatsProbeRemoteVideoTrackRefreshAction(
                currentTrackId: "video-1",
                receiverTrackId: "video-2",
                hasCurrentRemoteVideoTrack: true
            ),
            .rebind
        )
        XCTAssertEqual(
            WebRTCSession.receiverStatsProbeRemoteVideoTrackRefreshAction(
                currentTrackId: nil,
                receiverTrackId: "video-1",
                hasCurrentRemoteVideoTrack: false
            ),
            .rebind
        )

        XCTAssertTrue(refreshBody.contains("receiverStatsProbeRemoteVideoTrackRefreshAction"))
        XCTAssertTrue(refreshBody.contains("guard refreshAction == .rebind else {\n            return false\n        }"))
        XCTAssertFalse(
            refreshBody.contains("tracksShareNativeBacking: Self.remoteVideoTracksShareNativeBacking(remoteVideoTrack, receiverTrack)"),
            "Receiver stats probe must not use backing identity as a rebind trigger; wrapper churn is exactly what caused repeated same-track rebinds."
        )
        XCTAssertFalse(
            refreshBody.contains("remoteVideoTrack !== receiverTrack"),
            "Receiver stats probe must not compare RTCVideoTrack wrapper identity directly; receiver.track can return a fresh wrapper."
        )
        let noOpGuardIndex = refreshBody.range(of: "guard refreshAction == .rebind")?.lowerBound
            ?? refreshBody.endIndex
        let refreshLogIndex = refreshBody.range(of: "remote native video track refreshed from receiver stats probe")?.lowerBound
            ?? refreshBody.startIndex
        XCTAssertTrue(
            noOpGuardIndex < refreshLogIndex,
            "Same-track no-op must return before refresh/rebind logging and onRemoteVideoTrack publication."
        )
    }

    func testRemoteVideoInstallSkipsRenderEpochBumpForSameNativeBacking() throws {
        let crossNetworkSource = try crossNetworkWebRTCManagerSource()
        let installBody = try sourceSlice(
            from: "private func installRemoteVideoTrack(_ track: RTCVideoTrack?)",
            to: "func currentRemoteVideoTrackRenderToken",
            in: crossNetworkSource
        )

        XCTAssertTrue(installBody.contains("Self.remoteVideoTracksShareNativeBacking(remoteVideoTrack, track)"))
        XCTAssertTrue(installBody.contains("scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: \"track-unchanged\")"))
        let sameBackingGuardIndex = installBody.range(of: "guard !tracksShareNativeBacking")?.lowerBound
            ?? installBody.endIndex
        let epochBumpIndex = installBody.range(of: "remoteVideoTrackRenderEpoch &+= 1")?.lowerBound
            ?? installBody.startIndex
        XCTAssertTrue(
            sameBackingGuardIndex < epochBumpIndex,
            "Same native backing must exit before render epoch is bumped."
        )
        XCTAssertTrue(
            installBody.contains("&& currentTrackId == incomingTrackId\n            && track != nil"),
            "Same-trackId real backing replacements should still be treated as a renderer rebind."
        )
    }

    func testVideoRefreshPayloadOmitsAudioEndpointAndAdvertisesJPEGOnlyWarmupFallback() throws {
        let source = try remoteDesktopManagerSource()
        let pushBody = try sourceSlice(
            from: "private func pushViewerStreamConfiguration(force: Bool, refreshStream: Bool = false) async",
            to: "private func sendViewerStreamConfigurationPayload",
            in: source
        )
        let payloadBody = try sourceSlice(
            from: "func makeViewerStreamConfigurationPayload(\n        refreshStream: Bool,",
            to: "private func nextStreamRefreshToken()",
            in: source
        )

        XCTAssertTrue(pushBody.contains("let includeAudioEndpointInStreamConfig = !refreshStream"))
        XCTAssertTrue(pushBody.contains("mediaAudioEndpoint: includeAudioEndpointInStreamConfig ? mediaAudioBinding?.endpoint : nil"))
        XCTAssertTrue(pushBody.contains("mediaSessionId: includeAudioEndpointInStreamConfig ? mediaAudioBinding?.mediaSessionId : nil"))
        XCTAssertTrue(pushBody.contains("if includeAudioEndpointInStreamConfig, payload.mediaAudioEndpoint != nil"))
        XCTAssertTrue(source.contains("func handleCrossNetworkNativeVideoWarmupEvidence(reason: String)"))
        XCTAssertTrue(source.contains("await self?.pushViewerStreamConfiguration(force: true, refreshStream: true)"))
        XCTAssertTrue(payloadBody.contains("shouldUseJPEGOnlyFallbackDuringNativeWarmup"))
        XCTAssertTrue(payloadBody.contains("? [\"jpeg\"]"))
        XCTAssertTrue(payloadBody.contains("? \"jpeg\""))
        XCTAssertTrue(payloadBody.contains("nativeVideoTrackReady: Self.advertisedCrossNetworkNativeVideoReadyFlag"))
    }

    func testCrossNetworkFrameNotificationRejectsStaleOrMismatchedSessions() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldProcessCrossNetworkFrameNotification(
                isStreaming: true,
                subscribedSessionId: "session-2",
                expectedSessionId: "session-1",
                updateSessionId: "session-1"
            )
        )
        XCTAssertFalse(
            RemoteDesktopManager.shouldProcessCrossNetworkFrameNotification(
                isStreaming: true,
                subscribedSessionId: "session-1",
                expectedSessionId: "session-1",
                updateSessionId: "session-2"
            )
        )
        XCTAssertTrue(
            RemoteDesktopManager.shouldProcessCrossNetworkFrameNotification(
                isStreaming: true,
                subscribedSessionId: "session-1",
                expectedSessionId: "session-1",
                updateSessionId: "session-1"
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementAllowsForcedFirstFrameConfirmation() {
        let now = Date()

        XCTAssertTrue(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: true,
                lastAnnouncementAt: now,
                now: now
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementSkipsRedundantResendAfterAck() {
        XCTAssertFalse(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: true,
                force: false,
                lastAnnouncementAt: nil,
                now: Date()
            )
        )
    }

    @MainActor
    func testCrossNetworkNativeReadyAnnouncementThrottlesUntilRetryWindowExpires() {
        let now = Date()

        XCTAssertFalse(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: false,
                lastAnnouncementAt: now.addingTimeInterval(-0.2),
                now: now
            )
        )

        XCTAssertTrue(
            RemoteDesktopManager.shouldAnnounceCrossNetworkNativeVideoReady(
                activeTransportModeIsCrossNetwork: true,
                hasCurrentConnection: true,
                hasRenderedNativeFrame: true,
                lastSentNativeVideoTrackReady: false,
                force: false,
                lastAnnouncementAt: now.addingTimeInterval(-0.8),
                now: now
            )
        )
    }

    @MainActor
    func testTrustResolvedPeerPersistsDeclaredDeviceIdForFutureBootstrap() {
        let store = TrustedDeviceStore.shared
        let original = store.trustedDevices
        store.clearAll()
        defer {
            store.clearAll()
            store.mergeFromCloud(original)
        }

        let declaredDeviceId = "id:\(UUID().uuidString.lowercased())"
        let runtimeAliasDevice = DiscoveredDevice(
            id: "host:fe80::81d:bb45:8c18:6d6a%en0",
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        store.trustResolvedPeer(runtimeAliasDevice, declaredDeviceId: declaredDeviceId)

        XCTAssertTrue(store.isTrusted(deviceId: "host:fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            store.canonicalTrustedDeviceId(for: runtimeAliasDevice),
            declaredDeviceId
        )
    }

    @MainActor
    func testCodablePersistenceStoreMigratesLegacyDefaultsIntoProtectedStateFile() throws {
        let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
        let legacyKey = "legacy.persistence.payload"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }

        let store = CodablePersistenceStore<[String]>(
            location: .protectedApplicationSupport(
                path: "Tests/\(UUID().uuidString).json",
                legacyUserDefaultsKey: legacyKey
            ),
            rootDirectoryName: "SkyBridgeStateTests",
            defaults: defaults
        )
        let expected = ["alpha", "beta", "gamma"]
        defaults.set(try JSONEncoder().encode(expected), forKey: legacyKey)

        XCTAssertEqual(store.load(), expected)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertEqual(store.load(), expected)

        try? store.remove()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testP2PConnectionManagerPromotesPresentationIdentityWithoutBreakingRuntimeLookup() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.42"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.42"
        )

        let resolvedRuntimePeerId = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        XCTAssertEqual(resolvedRuntimePeerId, runtimePeerId)
        XCTAssertEqual(manager.connectionStatusByDeviceId[stablePeerId], .connected)
        XCTAssertTrue(manager.activeConnections.contains(where: { $0.device.id == stablePeerId }))
        XCTAssertEqual(
            manager.activeConnections.first(where: { $0.device.id == stablePeerId })?.device.name,
            "Stable Mac"
        )
        XCTAssertNil(manager.connectionErrorByDeviceId[stablePeerId])
    }

    @MainActor
    func testP2PConnectionManagerTerminalCleanupRemovesPresentationArtifactsAndSuite() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.52"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.52"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testInstallNegotiatedSuite(.mlkem768, for: runtimePeerId)

        XCTAssertTrue(manager.activeConnections.contains(where: { $0.device.id == stablePeerId }))
        XCTAssertEqual(manager.negotiatedSuiteByDeviceId[stablePeerId], .mlkem768)

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)

        XCTAssertFalse(manager.activeConnections.contains { connection in
            let deviceId = connection.device.id
            return deviceId == runtimePeerId || deviceId == stablePeerId
        })
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[runtimePeerId])
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[stablePeerId])
        XCTAssertEqual(manager.connectionStatusByDeviceId[stablePeerId], .disconnected)
    }

    @MainActor
    func testDashboardViewModelRefreshesStatusWhenNegotiatedSuitePublishes() async {
        let manager = P2PConnectionManager.instance
        let viewModel = DashboardViewModel.shared
        let runtimePeerId = "host:192.168.1.57"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"
        let connectedText = RuntimeLocalization.string("已连接")

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Classic Peer",
            ipAddress: "192.168.1.57"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, connectedText)

        manager.testInstallNegotiatedSuite(.x25519Ed25519, for: runtimePeerId)

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
        XCTAssertNil(manager.negotiatedSuiteByDeviceId[stablePeerId])
    }

    @MainActor
    func testDashboardViewModelPreservesClassicPresentationWhenActiveConnectionsTemporarilyClear() async {
        let manager = P2PConnectionManager.instance
        let viewModel = DashboardViewModel.shared
        let runtimePeerId = "host:192.168.1.58"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let connectedText = RuntimeLocalization.string("已连接")

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Classic Peer",
            ipAddress: "192.168.1.58"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testInstallNegotiatedSuite(.x25519Ed25519, for: runtimePeerId)

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")

        manager.testClearActiveConnectionsPreservingState()

        await Task.yield()
        XCTAssertEqual(viewModel.topConnectionPresentation.phase, .connected)
        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")
        XCTAssertNotEqual(viewModel.topConnectionPresentation.statusText, RuntimeLocalization.string("在线"))

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
    }

    @MainActor
    func testDashboardViewModelDoesNotPretendTargetSuiteIsConnectedDuringRekey() async {
        let manager = P2PConnectionManager.instance
        let viewModel = DashboardViewModel.shared
        let runtimePeerId = "host:192.168.1.63"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let connectedText = RuntimeLocalization.string("已连接")

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Rekey Peer",
            ipAddress: "192.168.1.63"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Rekey Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testInstallNegotiatedSuite(.x25519Ed25519, for: runtimePeerId)
        manager.testInstallRekeyStatus(
            fromSuite: "Classic",
            toSuite: "X-Wing",
            for: runtimePeerId
        )

        await Task.yield()

        XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")
        XCTAssertEqual(viewModel.topConnectionPresentation.detailText, "Classic → X-Wing · Rekey 中")
        XCTAssertFalse(viewModel.topConnectionPresentation.statusText.contains("X-Wing"))

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
    }

    @MainActor
    func testP2PConnectionManagerResolvesPresentationPeerIdBackToRuntimePeerId() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.62"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Host Alias Peer",
            ipAddress: "192.168.1.62"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )

        XCTAssertEqual(manager.testResolveRuntimePeerId(forAnyPeerId: stablePeerId), runtimePeerId)
    }

    @MainActor
    func testResolvedConnectionStatusPrefersLiveConnectionOverStaleAliasFailure() {
        let manager = P2PConnectionManager.instance
        let runtimePeerId = "host:192.168.1.72"
        let declaredDeviceId = UUID().uuidString.lowercased()
        let stablePeerId = "id:\(declaredDeviceId)"

        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Alias Peer",
            ipAddress: "192.168.1.72"
        )
        _ = manager.testPromotePeerPresentationIdentity(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: declaredDeviceId,
            deviceName: "Stable Mac",
            modelName: "MacBook Pro",
            platform: "macOS",
            osVersion: "15.0"
        )
        manager.testSimulateTerminalCleanup(
            runtimePeerId: runtimePeerId,
            terminalStatus: .failed,
            error: "stale failure"
        )
        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Alias Peer",
            ipAddress: "192.168.1.72"
        )

        let device = DiscoveredDevice(
            id: stablePeerId,
            name: "Stable Mac",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.72"
        )

        XCTAssertEqual(manager.resolvedConnectionStatus(for: device), .connected)
        XCTAssertNil(manager.resolvedConnectionError(for: device))
    }

    func testProcessMessageBWithoutTranscriptHashAFailsWithExplicitReason() async {
        let context = makeInitiatorContext()
        let messageB = makeMinimalMessageB()

        do {
            _ = try await context.processMessageB(messageB)
            XCTFail("Expected processMessageB to fail when transcript hash A is missing")
        } catch {
            assertMissingTranscriptHashA(error)
        }
    }

    func testConcurrentProcessMessageBWithoutTranscriptHashAFailsDeterministically() async {
        let context = makeInitiatorContext()
        let messageB = makeMinimalMessageB()

        let errors = await withTaskGroup(of: Error?.self, returning: [Error].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        _ = try await context.processMessageB(messageB)
                        return nil
                    } catch {
                        return error
                    }
                }
            }

            var collected: [Error] = []
            for await error in group {
                if let error {
                    collected.append(error)
                }
            }
            return collected
        }

        XCTAssertEqual(errors.count, 12)
        for error in errors {
            assertMissingTranscriptHashA(error)
        }
    }

    func testTrafficPaddingRoundTripAndMalformedFrameBehavior() {
        let defaults = UserDefaults.standard
        let enabledKey = "sb_traffic_padding_enabled"
        let modeKey = "sb_traffic_padding_mode"
        let fixedKey = "sb_traffic_padding_fixed_size"

        let oldEnabled = defaults.object(forKey: enabledKey)
        let oldMode = defaults.object(forKey: modeKey)
        let oldFixed = defaults.object(forKey: fixedKey)

        defer {
            restore(defaults, key: enabledKey, value: oldEnabled)
            restore(defaults, key: modeKey, value: oldMode)
            restore(defaults, key: fixedKey, value: oldFixed)
        }

        defaults.set(true, forKey: enabledKey)
        defaults.set(TrafficPaddingMode.fixed.rawValue, forKey: modeKey)
        defaults.set(128, forKey: fixedKey)

        let payload = Data("traffic-padding-regression".utf8)
        let wrapped = TrafficPadding.wrapIfEnabled(payload, label: "unit")

        XCTAssertEqual(wrapped.count, 128)
        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(wrapped, label: "unit"), payload)

        var malformed = Data([0x53, 0x42, 0x50, 0x32])
        var declaredLen = UInt32(512).bigEndian
        malformed.append(Data(bytes: &declaredLen, count: 4))
        malformed.append(Data(repeating: 0xAA, count: 12))

        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(malformed, label: "unit"), malformed)
    }

    @MainActor
    func testFileTransferPrefersLocalP2POverStaleWebRTCForSamePeer() {
        let shouldPreferCrossNetwork = FileTransferManager.shouldPreferCrossNetworkTransfer(
            targetDeviceId: "id:peer-1",
            crossNetworkState: .connected(sessionId: "ABC123"),
            crossNetworkRemoteDeviceId: "id:peer-1",
            localActiveConnectionDeviceIds: ["id:peer-1"]
        )

        XCTAssertFalse(shouldPreferCrossNetwork)
    }

    @MainActor
    func testFileTransferUsesCrossNetworkWhenNoLocalP2PExists() {
        let shouldPreferCrossNetwork = FileTransferManager.shouldPreferCrossNetworkTransfer(
            targetDeviceId: "id:peer-1",
            crossNetworkState: .connected(sessionId: "ABC123"),
            crossNetworkRemoteDeviceId: "id:peer-1",
            localActiveConnectionDeviceIds: []
        )

        XCTAssertTrue(shouldPreferCrossNetwork)
    }

    func testFileTransferReleaseSlotResumesWaitingTransferWithoutDroppingOccupancy() {
        XCTAssertEqual(
            FileTransferManager.transferSlotReleaseAction(
                inFlightTransferCount: 2,
                waiterCount: 1,
                limit: 2
            ),
            .resumeWaiter(nextInFlightCount: 2)
        )
    }

    func testFileTransferReleaseSlotDropsOccupancyWhenNoWaitersRemain() {
        XCTAssertEqual(
            FileTransferManager.transferSlotReleaseAction(
                inFlightTransferCount: 2,
                waiterCount: 0,
                limit: 2
            ),
            .decrementTo(1)
        )
        XCTAssertEqual(
            FileTransferManager.transferSlotReleaseAction(
                inFlightTransferCount: 1,
                waiterCount: 0,
                limit: 0
            ),
            .decrementTo(0)
        )
    }

    func testClassicTransferSenderDeviceIdPrefersStableKeychainIdentity() {
        let resolved = FileTransferManager.preferredClassicTransferSenderDeviceId(
            stableDeviceId: "keychain-device-id",
            vendorDeviceId: "vendor-id"
        )

        XCTAssertEqual(resolved, "keychain-device-id")
    }

    func testClassicTransferSenderDeviceIdFallsBackToVendorWhenStableIdentityMissing() {
        let resolved = FileTransferManager.preferredClassicTransferSenderDeviceId(
            stableDeviceId: "   ",
            vendorDeviceId: "vendor-id"
        )

        XCTAssertEqual(resolved, "vendor-id")
    }

    func testSinglePeerTransferSecurityFallbackUsesOnlyAuthenticatedPeer() {
        let fallback = FileTransferManager.singlePeerFallbackTransferDeviceId(
            requestedCandidates: ["host:stale-peer"],
            activeConnectionDeviceIDs: ["id:trusted-peer"]
        )

        XCTAssertEqual(fallback, "id:trusted-peer")
    }

    func testSinglePeerTransferSecurityFallbackDoesNotGuessWhenMultiplePeersExist() {
        let fallback = FileTransferManager.singlePeerFallbackTransferDeviceId(
            requestedCandidates: ["host:stale-peer"],
            activeConnectionDeviceIDs: ["id:trusted-peer", "id:other-peer"]
        )

        XCTAssertNil(fallback)
    }

    func testClassicTransferPeerResolutionUsesEndpointHostOrIPWhenDeclaredIdIsStale() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "host:stale-peer",
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "Lza的MacBook Pro",
            transferId: "transfer-1"
        )
        let peers = [
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:trusted-peer",
                resolvedPeerDeviceId: "id:trusted-peer",
                aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = FileTransferManager.resolveClassicTransferPeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertEqual(resolved?.matchDeviceId, "id:trusted-peer")
        XCTAssertEqual(resolved?.matchedBy, .endpointHostOrIP)
    }

    func testClassicTransferPeerResolutionDoesNotGuessWhenMultiplePeersMatchEndpoint() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: nil,
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "Lza的MacBook Pro",
            transferId: "transfer-2"
        )
        let peers = [
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-a",
                resolvedPeerDeviceId: "id:peer-a",
                aliases: ["id:peer-a", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            ),
            FileTransferManager.ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-b",
                resolvedPeerDeviceId: "id:peer-b",
                aliases: ["id:peer-b", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = FileTransferManager.resolveClassicTransferPeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(resolved)
    }

    func testDiscoveredDeviceClassicResumeCapabilityDefaultsToDisabledWithoutCapabilityBit() {
        let device = DiscoveredDevice(
            id: "id:peer-transfer",
            name: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "192.168.31.20",
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        XCTAssertFalse(device.supportsClassicResume)
    }

    func testIOSWebRTCSessionStateAndCallbackPlansReflectQueueAffinity() {
        XCTAssertEqual(WebRTCSession.stateAccessPlan(isOnStateQueue: true), .executeInline)
        XCTAssertEqual(WebRTCSession.stateAccessPlan(isOnStateQueue: false), .syncOnStateQueue)
        XCTAssertEqual(WebRTCSession.callbackDispatchPlan(isOnStateQueue: true), .asyncOffStateQueue)
        XCTAssertEqual(WebRTCSession.callbackDispatchPlan(isOnStateQueue: false), .executeInline)
    }

    func testIOSWebRTCSessionLifecycleGuardRejectsClosedOrStaleCallbacks() {
        XCTAssertTrue(
            WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: true,
                isClosed: false,
                currentLifecycleToken: 11,
                expectedLifecycleToken: 11
            )
        )
        XCTAssertFalse(
            WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: false,
                isClosed: false,
                currentLifecycleToken: 11,
                expectedLifecycleToken: 11
            )
        )
        XCTAssertFalse(
            WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: true,
                isClosed: true,
                currentLifecycleToken: 11,
                expectedLifecycleToken: 11
            )
        )
        XCTAssertFalse(
            WebRTCSession.lifecycleGuardAllowsCallback(
                peerConnectionMatches: true,
                isClosed: false,
                currentLifecycleToken: 12,
                expectedLifecycleToken: 11
            )
        )
    }

    func testIOSWebRTCSessionPendingInboundBufferPlansRespectHandlerAvailability() {
        XCTAssertEqual(
            WebRTCSession.pendingInboundFlushPlan(
                hasHandlerInstalled: false,
                pendingCount: 2
            ),
            .keepBuffered
        )
        XCTAssertEqual(
            WebRTCSession.pendingInboundFlushPlan(
                hasHandlerInstalled: true,
                pendingCount: 2
            ),
            .dispatchBuffered(count: 2)
        )
        XCTAssertEqual(
            WebRTCSession.pendingInboundDeliveryPlan(
                hasHandlerInstalled: false,
                pendingCount: 2
            ),
            .bufferIncoming(nextPendingCount: 3)
        )
        XCTAssertEqual(
            WebRTCSession.pendingInboundDeliveryPlan(
                hasHandlerInstalled: true,
                pendingCount: 2
            ),
            .dispatch(bufferedCount: 2)
        )
    }

    func testIOSWebRTCSessionPendingInboundBufferLimitPlanRejectsOverflow() {
        XCTAssertEqual(
            WebRTCSession.pendingInboundBufferLimitPlan(
                pendingCount: 2,
                pendingBytes: 8_000,
                incomingBytes: 2_000,
                maxCount: 8,
                maxBytes: 16_000
            ),
            .append(nextPendingCount: 3, nextPendingBytes: 10_000)
        )
        XCTAssertEqual(
            WebRTCSession.pendingInboundBufferLimitPlan(
                pendingCount: 8,
                pendingBytes: 8_000,
                incomingBytes: 1_000,
                maxCount: 8,
                maxBytes: 16_000
            ),
            .overflow
        )
        XCTAssertEqual(
            WebRTCSession.pendingInboundBufferLimitPlan(
                pendingCount: 2,
                pendingBytes: 15_500,
                incomingBytes: 600,
                maxCount: 8,
                maxBytes: 16_000
            ),
            .overflow
        )
    }

    func testIOSWebRTCSessionPendingRemoteICEPlanMatchesReadinessAndDedup() {
        XCTAssertEqual(
            WebRTCSession.pendingRemoteICEPlan(
                isDuplicate: true,
                hasRemoteDescription: false,
                pendingCount: 1
            ),
            .ignoreDuplicate
        )
        XCTAssertEqual(
            WebRTCSession.pendingRemoteICEPlan(
                isDuplicate: false,
                hasRemoteDescription: false,
                pendingCount: 1
            ),
            .queueCandidate(nextPendingCount: 2)
        )
        XCTAssertEqual(
            WebRTCSession.pendingRemoteICEPlan(
                isDuplicate: false,
                hasRemoteDescription: true,
                pendingCount: 1
            ),
            .applyImmediately
        )
    }

    func testRemoteDesktopStreamConfigurationPayloadEqualityIgnoresSentAtButTracksRefreshToken() {
        let base = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: nil,
            sentAt: 1
        )

        let sameSettingsDifferentTimestamp = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: nil,
            sentAt: 999
        )

        let refreshed = RemoteDesktopStreamConfigurationPayload(
            width: 1920,
            height: 1080,
            preferredCodec: "h264",
            supportedVideoFormats: ["h264", "jpeg"],
            targetFrameRate: 60,
            keyFrameInterval: 30,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: true,
            streamRefreshToken: 7,
            sentAt: 1000
        )

        XCTAssertEqual(base, sameSettingsDifferentTimestamp)
        XCTAssertNotEqual(base, refreshed)
    }

    func testRemoteDesktopAutomaticViewerPolicyPrefersStableH264At60FPS() {
        XCTAssertEqual(RemoteDesktopViewerFrameRate.adaptive.targetFPS, 60)
        XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.width, 5120)
        XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.height, 2880)
        XCTAssertEqual(RemoteDesktopViewerSettings().activePreset, .automatic)
        XCTAssertEqual(
            RemoteDesktopViewerCodec.automatic.resolvedWireValue(
                supportedFormats: ["hevc", "jpeg", "h264"]
            ),
            "h264"
        )
        XCTAssertEqual(
            RemoteDesktopViewerCodec.automatic.resolvedWireValue(
                supportedFormats: ["jpeg", "h264"]
            ),
            "h264"
        )
    }

    func testRemoteDesktopViewerPresetApplicationSupportsProModes() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.pro5k120)

        XCTAssertEqual(settings.activePreset, .pro5k120)
        XCTAssertEqual(settings.resolution, .uhd5k)
        XCTAssertEqual(settings.frameRate, .fps120)
        XCTAssertEqual(settings.preferredCodec, .hevc)
        XCTAssertTrue(settings.lowLatencyMode)

        settings.resolution = .qhd1440

        XCTAssertEqual(settings.activePreset, .custom)
    }

    func testRemoteDesktopViewerFluidPresetTargetsLowLatencyH264() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.fluid)

        XCTAssertEqual(settings.activePreset, .fluid)
        XCTAssertEqual(settings.resolution, .hd720)
        XCTAssertEqual(settings.frameRate, .fps60)
        XCTAssertEqual(settings.preferredCodec, .h264)
        XCTAssertTrue(settings.lowLatencyMode)
    }

    func testRemoteDesktopViewerPresetCarriesTransportGovernanceHints() {
        var settings = RemoteDesktopViewerSettings()

        settings.applyPreset(.pro4k120)

        XCTAssertEqual(settings.transportTuning.qualityPresetWireValue, "geek4k120")
        XCTAssertEqual(settings.transportTuning.jitterBufferFrames, 1)
        XCTAssertEqual(settings.transportTuning.refreshStrategy, "instant")
        XCTAssertEqual(settings.transportTuning.lossRecoveryMode, "fast-retransmit")
        XCTAssertTrue(settings.transportTuning.damageTrackingEnabled)
        XCTAssertTrue(settings.transportTuning.separateCursorChannelEnabled)
        XCTAssertFalse(settings.transportTuning.interactionOverlayChannelEnabled)
    }

    func testRemoteDesktopCodecGovernanceDisablesHEVCAfterRepeatedDecoderFailures() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start),
            .none
        )
        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "VTDecompressionSessionDecodeFrame status=-12909",
                at: start.addingTimeInterval(0.2)
            ),
            .none
        )

        let event = governance.noteDecodeFailure(
            format: "hevc",
            reason: "callback-no-image",
            at: start.addingTimeInterval(0.4)
        )

        guard case .disableHEVC(let until) = event else {
            return XCTFail("Expected HEVC circuit breaker to disable the codec temporarily")
        }

        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            ["h264", "jpeg"]
        )
        XCTAssertEqual(
            governance.effectivePreferredCodec(
                userPreference: .automatic,
                supportedFormats: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            "h264"
        )
        XCTAssertGreaterThan(until.timeIntervalSince(start), 10)
    }

    func testRemoteDesktopCodecGovernanceReenablesHEVCAfterStableFallbackFrames() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_100)

        _ = governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start)
        _ = governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start.addingTimeInterval(0.1))
        let disableEvent = governance.noteDecodeFailure(
            format: "hevc",
            reason: "callback-no-image",
            at: start.addingTimeInterval(0.2)
        )
        guard case .disableHEVC(let until) = disableEvent else {
            return XCTFail("Expected HEVC to enter cooldown first")
        }

        var probeEvent: RemoteDesktopCodecGovernanceEvent = .none
        for frameIndex in 0..<24 {
            probeEvent = governance.noteDecodeSuccess(
                format: "h264",
                at: until.addingTimeInterval(Double(frameIndex) * 0.05)
            )
        }

        XCTAssertEqual(probeEvent, .reenableHEVCProbe)
        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: until.addingTimeInterval(2)
            ),
            ["hevc", "h264", "jpeg"]
        )
    }

    func testRemoteDesktopCodecGovernanceEscalatesRepeatedSyncFrameWaitsToH264Fallback() {
        var governance = RemoteDesktopCodecGovernance()
        let start = Date(timeIntervalSince1970: 1_700_000_200)

        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "waiting-for-sync-frame",
                at: start
            ),
            .requestRefresh
        )
        XCTAssertEqual(
            governance.noteDecodeFailure(
                format: "hevc",
                reason: "waiting-for-sync-frame",
                at: start.addingTimeInterval(0.2)
            ),
            .requestRefresh
        )

        let event = governance.noteDecodeFailure(
            format: "hevc",
            reason: "waiting-for-sync-frame",
            at: start.addingTimeInterval(0.4)
        )

        guard case .disableHEVC(let until) = event else {
            return XCTFail("Expected repeated sync-frame waits to disable HEVC temporarily")
        }

        XCTAssertGreaterThan(until.timeIntervalSince(start), 10)
        XCTAssertEqual(
            governance.effectiveSupportedFormats(
                from: ["hevc", "h264", "jpeg"],
                at: start.addingTimeInterval(1)
            ),
            ["h264", "jpeg"]
        )
    }

    func testPeerIdentityAliasResolverMapsHostEndpointBackToStableDeviceID() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("192.168.31.20"),
            port: NWEndpoint.Port(integerLiteral: 9527)
        )

        let resolved = PeerIdentityAliasResolver.resolveDeviceId(
            for: endpoint,
            endpointKey: endpoint.debugDescription,
            exactEndpointMap: [:],
            aliasMap: ["host:192.168.31.20": "id:peer-1"]
        )

        XCTAssertEqual(resolved, "id:peer-1")
    }

    func testPeerIdentityAliasResolverMapsBonjourEndpointBackToStableDeviceID() {
        let endpoint = NWEndpoint.service(
            name: "Lza's MacBook Pro",
            type: "_skybridge._tcp",
            domain: "local.",
            interface: nil
        )

        let resolved = PeerIdentityAliasResolver.resolveDeviceId(
            for: endpoint,
            endpointKey: endpoint.debugDescription,
            exactEndpointMap: [:],
            aliasMap: ["bonjour:lza's macbook pro@local.": "id:peer-bonjour"]
        )

        XCTAssertEqual(resolved, "id:peer-bonjour")
    }

    @MainActor
    func testResolveBestTransferDevicePrefersTransferServiceCandidateOverBareSnapshot() {
        let target = DiscoveredDevice(
            id: "id:peer-1",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerTransferCandidate = DiscoveredDevice(
            id: "bonjour:MacBook Pro@local.",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "192.168.31.20",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        let resolved = FileTransferManager.resolveBestTransferDevice(
            target: target,
            discovered: [richerTransferCandidate]
        )

        XCTAssertEqual(resolved.id, richerTransferCandidate.id)
        XCTAssertEqual(resolved.fileTransferPort, 8080)
        XCTAssertEqual(resolved.ipAddress, "192.168.31.20")
    }

    @MainActor
    func testResolveBestTransferDeviceMatchesScopedHostSnapshotToReachableTransferCandidate() {
        let target = DiscoveredDevice(
            id: "host:fe80::468:f5a1:462b:29d3%bridge100",
            name: "fe80::468:f5a1:462b:29d3%bridge100",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerTransferCandidate = DiscoveredDevice(
            id: "id:peer-transfer",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::468:f5a1:462b:29d3",
            bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.fileTransferServiceType],
            portMap: [DiscoveredDevice.fileTransferServiceType: 8080],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        let resolved = FileTransferManager.resolveBestTransferDevice(
            target: target,
            discovered: [richerTransferCandidate]
        )

        XCTAssertEqual(resolved.id, richerTransferCandidate.id)
        XCTAssertEqual(resolved.fileTransferPort, 8080)
    }

    @MainActor
    func testResolveBestRemoteDesktopDevicePrefersReachableRemoteCandidateOverCapabilityOnlySnapshot() {
        let target = DiscoveredDevice(
            id: "id:peer-1",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let richerRemoteCandidate = DiscoveredDevice(
            id: "bonjour:MacBook Pro@local.",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "192.168.31.20",
            bonjourServiceType: DiscoveredDevice.remoteControlServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.remoteControlServiceType],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let resolved = RemoteDesktopManager.resolveBestRemoteDesktopDevice(
            target: target,
            discovered: [richerRemoteCandidate]
        )

        XCTAssertEqual(resolved.id, richerRemoteCandidate.id)
        XCTAssertEqual(resolved.remoteControlPort, 5901)
        XCTAssertEqual(resolved.ipAddress, "192.168.31.20")
    }

    @MainActor
    func testResolveBestRemoteDesktopDeviceMatchesScopedHostSnapshotToReachableRemoteCandidate() {
        let target = DiscoveredDevice(
            id: "host:fe80::468:f5a1:462b:29d3%bridge100",
            name: "fe80::468:f5a1:462b:29d3%bridge100",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -40,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        let richerRemoteCandidate = DiscoveredDevice(
            id: "id:peer-remote",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: "fe80::468:f5a1:462b:29d3",
            bonjourServiceType: DiscoveredDevice.remoteControlServiceType,
            bonjourServiceDomain: "local.",
            services: [DiscoveredDevice.remoteControlServiceType],
            portMap: [DiscoveredDevice.remoteControlServiceType: 5901],
            signalStrength: -38,
            lastSeen: Date(),
            isConnected: false,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        let resolved = RemoteDesktopManager.resolveBestRemoteDesktopDevice(
            target: target,
            discovered: [richerRemoteCandidate]
        )

        XCTAssertEqual(resolved.id, richerRemoteCandidate.id)
        XCTAssertEqual(resolved.remoteControlPort, 5901)
    }

    @MainActor
    func testLiveLANMacConnectionIsEligibleForRemoteDesktopWithoutExplicitRemoteServiceAdvertisement() {
        let connectionManager = P2PConnectionManager.instance
        connectionManager.installUITestActiveConnections([])
        defer {
            connectionManager.installUITestActiveConnections([])
        }

        let runtimePeerId = "host:fe80::b4:98c9:b9a:3bb3%en2"
        connectionManager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "Lza的MacBook Pro",
            ipAddress: "fe80::b4:98c9:b9a:3bb3%en2"
        )

        let device = DiscoveredDevice(
            id: runtimePeerId,
            name: "Lza的MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: nil,
            bonjourServiceDomain: nil,
            services: [],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: [],
            capabilities: []
        )

        XCTAssertTrue(RemoteDesktopManager.instance.canPresentRemoteDesktopOption(for: device))
    }

    @MainActor
    func testCapabilityOnlyTransferDeviceDoesNotExposeExplicitLANTransferService() {
        let device = DiscoveredDevice(
            id: "id:peer-transfer",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["file_transfer"],
            capabilities: ["file_transfer"]
        )

        XCTAssertFalse(FileTransferManager.hasExplicitLANTransferService(device))
    }

    @MainActor
    func testCapabilityOnlyRemoteDesktopDeviceDoesNotExposeExplicitLANEndpoint() {
        let device = DiscoveredDevice(
            id: "id:peer-remote",
            name: "MacBook Pro",
            bonjourServiceName: "MacBook Pro",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "26.3.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: [:],
            signalStrength: -42,
            lastSeen: Date(),
            isConnected: true,
            isTrusted: true,
            publicKey: nil,
            advertisedCapabilities: ["remote_desktop"],
            capabilities: ["remote_desktop"]
        )

        XCTAssertFalse(RemoteDesktopManager.hasExplicitLANRemoteDesktopEndpoint(device))
    }

    @MainActor
    func testP2PPairingCapabilitiesDoNotSynthesizeLANServiceEndpointsWithoutPorts() throws {
        let manager = P2PConnectionManager.instance
        manager.installUITestActiveConnections([])

        let runtimePeerId = "id:p2p-capability-only"
        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "MacBook Pro",
            ipAddress: "fe80::1%en0"
        )

        manager.testMergePeerServiceMetadata(
            runtimePeerId: runtimePeerId,
            declaredDeviceId: runtimePeerId,
            capabilities: ["file_transfer", "remote_desktop", "remote_control"],
            fileTransferPort: nil,
            remoteControlPort: nil
        )

        let merged = try XCTUnwrap(manager.activeConnections.first?.device)
        XCTAssertTrue(merged.capabilities.contains("file_transfer"))
        XCTAssertTrue(merged.capabilities.contains("remote_desktop"))
        XCTAssertTrue(merged.capabilities.contains("remote_control"))
        XCTAssertFalse(merged.services.contains(DiscoveredDevice.fileTransferServiceType))
        XCTAssertFalse(merged.services.contains(DiscoveredDevice.remoteControlServiceType))
        XCTAssertNil(merged.fileTransferPort)
        XCTAssertNil(merged.remoteControlPort)

        manager.installUITestActiveConnections([])
    }

    @MainActor
    func testProtectedDiscoveryIdentifiersDoNotKeepDisconnectedRuntimePeerAlive() {
        let manager = P2PConnectionManager.instance
        manager.installUITestActiveConnections([])

        let runtimePeerId = "host:fe80::468:f5a1:462b:29d3%bridge100"
        manager.installTestPeerRuntimeState(
            runtimePeerId: runtimePeerId,
            status: .connected,
            name: "MacBook Pro",
            ipAddress: "fe80::468:f5a1:462b:29d3%bridge100"
        )

        XCTAssertFalse(manager.activeDiscoveryIdentifiers.isEmpty)
        XCTAssertTrue(manager.protectedDiscoveryIdentifiers.contains("host:fe80::468:f5a1:462b:29d3"))

        manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId, terminalStatus: .disconnected)

        XCTAssertTrue(manager.activeDiscoveryIdentifiers.isEmpty)
        XCTAssertFalse(manager.protectedDiscoveryIdentifiers.contains(runtimePeerId.lowercased()))
        XCTAssertFalse(manager.protectedDiscoveryIdentifiers.contains("host:fe80::468:f5a1:462b:29d3"))

        manager.installUITestActiveConnections([])
    }

    private func makeInitiatorContext() -> HandshakeContext {
        let signingKey = Curve25519.Signing.PrivateKey()
        return HandshakeContext(
            role: .initiator,
            cryptoProvider: ClassicCryptoProvider(),
            protocolSignatureProvider: ClassicSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: signingKey.publicKey.rawRepresentation,
            policy: .default,
            peerKEMPublicKeys: [:]
        )
    }

    private func makeMinimalMessageB() -> HandshakeMessageB {
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x11, count: 32),
            protocolAlgorithm: .ed25519
        )

        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(repeating: 0x22, count: 32),
            ciphertext: Data([0x01, 0x02, 0x03]),
            tag: Data(repeating: 0x33, count: 16),
            nonce: Data(repeating: 0x44, count: 12)
        )

        return HandshakeMessageB(
            selectedSuite: .x25519Ed25519,
            responderShare: Data(repeating: 0x55, count: 32),
            serverNonce: Data(repeating: 0x66, count: HandshakeConstants.nonceSize),
            encryptedPayload: sealedBox,
            signature: Data(repeating: 0x77, count: 64),
            identityPublicKeys: identityKeys
        )
    }

    private func assertMissingTranscriptHashA(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let HandshakeError.failed(reason) = error else {
            XCTFail("Expected HandshakeError.failed, got \(error)", file: file, line: line)
            return
        }
        guard case let .cryptoError(message) = reason else {
            XCTFail("Expected HandshakeFailureReason.cryptoError, got \(reason)", file: file, line: line)
            return
        }
        XCTAssertEqual(message, "Missing transcript hash A", file: file, line: line)
    }

    private func restore(_ defaults: UserDefaults, key: String, value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testConnectionPresentationContractTreatsTransportReadyAsConnecting() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    sessionId: "session-1",
                    source: .code,
                    phase: .transportReady,
                    deviceId: "peer-1",
                    deviceName: "Mac mini",
                    negotiatedSuite: nil
                ),
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.phase, .connecting)
        XCTAssertEqual(presentation.statusText, "连接中")
        XCTAssertEqual(presentation.detailText, "Mac mini")
    }

    func testConnectionPresentationContractPrioritizesPeerOverCrossNetworkSnapshot() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Peer",
                    cryptoKind: nil,
                    suite: "X25519",
                    guardStatus: "守护中"
                ),
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    sessionId: "session-2",
                    source: .qr,
                    phase: .handshakeComplete,
                    deviceId: "peer-2",
                    deviceName: "Remote Device",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.statusText, "Classic 已连接")
    }

    func testConnectionPresentationContractDoesNotClaimTargetSuiteWhileRekeying() {
        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: ConnectionPresentationLabels(
                    connectedText: "已连接",
                    disconnectedText: "离线",
                    connectingText: "连接中",
                    reconnectingText: "重连中",
                    defaultGuardStatus: "守护中",
                    crossNetworkGuardStatus: "跨网已连接"
                ),
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Peer",
                    cryptoKind: "X25519 → X-Wing",
                    suite: nil,
                    guardStatus: "Rekey 中",
                    isRekeying: true
                ),
                latestConnectedDevice: nil,
                activeSessionSnapshot: nil,
                defaultPQCModeLabel: "Apple PQC"
            )
        )

        XCTAssertEqual(presentation.statusText, "Classic 已连接")
        XCTAssertEqual(presentation.detailText, "X25519 → X-Wing · Rekey 中")
    }

    func testConnectionPresentationContractFormatsAllCryptoModeLabelsWithSpacing() {
        let labels = ConnectionPresentationLabels(
            connectedText: "已连接",
            disconnectedText: "离线",
            connectingText: "连接中",
            reconnectingText: "重连中",
            defaultGuardStatus: "守护中",
            crossNetworkGuardStatus: "跨网已连接"
        )

        let classic = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Classic Peer",
                    suite: "X25519",
                    guardStatus: "守护中"
                ),
                latestConnectedDevice: nil,
                latestPendingPeer: nil,
                activeSessionSnapshot: nil,
                defaultPQCModeLabel: "Apple PQC"
            )
        )
        XCTAssertEqual(classic.statusText, "Classic 已连接")

        let xwing = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Hybrid Peer",
                    suite: "X-Wing",
                    guardStatus: "守护中"
                ),
                latestConnectedDevice: nil,
                latestPendingPeer: nil,
                activeSessionSnapshot: nil,
                defaultPQCModeLabel: "Apple PQC"
            )
        )
        XCTAssertEqual(xwing.statusText, "X-Wing 已连接")

        let apple = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                latestPendingPeer: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    sessionId: "session-apple",
                    source: .code,
                    phase: .handshakeComplete,
                    deviceId: "peer-apple",
                    deviceName: "Apple Peer",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC"
            )
        )
        XCTAssertEqual(apple.statusText, "Apple PQC 已连接")

        let liboqs = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "liboqs Peer",
                    cryptoKind: "liboqs",
                    suite: "ML-KEM-768",
                    guardStatus: "守护中"
                ),
                latestConnectedDevice: nil,
                latestPendingPeer: nil,
                activeSessionSnapshot: nil,
                defaultPQCModeLabel: "Apple PQC"
            )
        )
        XCTAssertEqual(liboqs.statusText, "liboqs 已连接")
    }

    func testLateCleanupTokenDoesNotClearNewSnapshot() {
        let originalToken = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let replacementToken = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let newerSnapshot = ActiveSessionSnapshotContract.activate(
            sessionId: "session-1",
            source: .reused,
            phase: .handshakeComplete,
            deviceId: "peer-1",
            deviceName: "Peer A",
            negotiatedSuite: "X-Wing",
            snapshotToken: replacementToken
        )

        let afterLateCleanup = ActiveSessionSnapshotContract.disconnect(
            current: newerSnapshot,
            sessionId: "session-1",
            snapshotToken: originalToken,
            kind: .explicit
        )

        XCTAssertEqual(afterLateCleanup, newerSnapshot)
    }

    func testRemoteDesktopDecodeQueuePolicyPreservesPredictiveVideoOrder() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = false
        let first = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x01]),
            timestamp: 1,
            format: "h264"
        )
        let second = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x02]),
            timestamp: 2,
            format: "h264"
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                first,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enqueued
        )
        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                second,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enqueued
        )

        XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, first.imageData)
        XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, second.imageData)
    }

    func testRemoteDesktopDecodeQueuePolicyStillImagesReplaceLatestFrame() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = false
        let stale = ScreenData(
            width: 1206,
            height: 779,
            imageData: Data([0x11]),
            timestamp: 1,
            format: "jpeg"
        )
        let latest = ScreenData(
            width: 1206,
            height: 779,
            imageData: Data([0x22]),
            timestamp: 2,
            format: "jpeg"
        )

        _ = RemoteDesktopDecodeQueuePolicy.enqueue(
            stale,
            into: &pending,
            waitingForSyncFrame: &waitingForSyncFrame
        )
        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                latest,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .replacedStillFrame
        )

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.imageData, latest.imageData)
        XCTAssertFalse(waitingForSyncFrame)
    }

    func testRemoteDesktopDecodeQueuePolicyEntersWaitingForSyncWhenQueueIsFull() {
        var pending = (0..<RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames).map { index in
            ScreenData(
                width: 1280,
                height: 720,
                imageData: Data([UInt8(index)]),
                timestamp: TimeInterval(index),
                format: "hevc"
            )
        }
        var waitingForSyncFrame = false
        let overflow = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0xFE]),
            timestamp: 99,
            format: "hevc"
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                overflow,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .enteredWaitingForSync
        )
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(waitingForSyncFrame)
    }

    func testRemoteDesktopDecodeQueuePolicyRecoversWhenSyncFrameArrives() {
        var pending: [ScreenData] = []
        var waitingForSyncFrame = true
        let syncFrame = ScreenData(
            width: 1280,
            height: 720,
            imageData: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88]),
            timestamp: 3,
            format: "h264",
            isSyncFrame: false
        )

        XCTAssertEqual(
            RemoteDesktopDecodeQueuePolicy.enqueue(
                syncFrame,
                into: &pending,
                waitingForSyncFrame: &waitingForSyncFrame
            ),
            .recoveredWithIndependentFrame
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.imageData, syncFrame.imageData)
        XCTAssertFalse(waitingForSyncFrame)
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotDetectsDecodedVideoFrameEvidence() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 47),
                    "bytesReceived": NSNumber(value: 94_288),
                    "framesReceived": NSNumber(value: 8),
                    "framesDecoded": NSNumber(value: 7),
                    "frameWidth": NSNumber(value: 2_056),
                    "frameHeight": NSNumber(value: 1_329)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertEqual(snapshot?.statType, "inbound-rtp")
        XCTAssertTrue(snapshot?.hasFrameEvidence == true)
        XCTAssertEqual(snapshot?.size, CGSize(width: 2_056, height: 1_329))
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotIgnoresAudioOnlySamples() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "audio"),
                    "packetsReceived": NSNumber(value: 128),
                    "bytesReceived": NSNumber(value: 4_096)
                ]
            )
        ]

        XCTAssertNil(WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples))
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotDoesNotPromoteZeroFrameVideo() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 0),
                    "bytesReceived": NSNumber(value: 0),
                    "framesReceived": NSNumber(value: 0),
                    "framesDecoded": NSNumber(value: 0)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertNotNil(snapshot)
        XCTAssertFalse(snapshot?.hasFrameEvidence == true)
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotDoesNotPromotePacketOnlyVideo() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 12),
                    "bytesReceived": NSNumber(value: 44_000),
                    "framesReceived": NSNumber(value: 0),
                    "framesDecoded": NSNumber(value: 0),
                    "frameWidth": NSNumber(value: 2_056),
                    "frameHeight": NSNumber(value: 1_328)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertTrue(snapshot?.hasPacketEvidence == true)
        XCTAssertFalse(snapshot?.hasFrameEvidence == true)
    }

    func testWebRTCMediaRelayRefreshUnsupportedIsDiagnosedAndBackedOff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("serverRefreshUnsupported"))
        XCTAssertTrue(source.contains("Cannot POST /api/media/admission/refresh"))
        XCTAssertTrue(source.contains("serverBuildFingerprint"))
        XCTAssertTrue(source.contains("supportsMediaAdmissionRefresh"))
        XCTAssertTrue(source.contains("mediaTokenGeneration"))
        XCTAssertTrue(source.contains("activeMediaAdmissionLeaseBackoffReason"))
    }

    func testWebRTCMediaRelaySessionTokenSupersededUsesSessionRefresh() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("/api/webrtc/session/refresh"))
        XCTAssertTrue(source.contains("refreshWebRTCSessionAdmissionTokens"))
        XCTAssertTrue(source.contains("sessionTokenSuperseded"))
        XCTAssertTrue(source.contains("sessionReauthFailed"))
        XCTAssertTrue(source.contains("backoff: 30"))
    }

    func testRemoteDesktopAudioLeaseFailureDoesNotStartReceiverBeforeLease() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let crossNetworkBranch = try sourceSlice(
            from: "case .crossNetwork:\n                updateRealtimeMediaAudioReceiverStartPhase(.lease",
            to: "case .lan:",
            in: source
        )
        guard let leaseRange = crossNetworkBranch.range(of: "crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()"),
              let rendererRange = crossNetworkBranch.range(of: "renderer = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: mode)", range: leaseRange.upperBound..<crossNetworkBranch.endIndex) else {
            XCTFail("Expected cross-network media lease preflight before receiver creation")
            return
        }

        XCTAssertLessThan(leaseRange.lowerBound, rendererRange.lowerBound)
        XCTAssertTrue(crossNetworkBranch.contains("event=leaseReady"))
        XCTAssertTrue(crossNetworkBranch.contains("event=audioEndpointPrepared"))
        XCTAssertTrue(crossNetworkBranch.contains("event=udpConnectionStarted"))
        XCTAssertTrue(crossNetworkBranch.contains("strictRelayBindRequired ? .requireAcknowledgement : .optimisticAfterSend"))
        XCTAssertTrue(crossNetworkBranch.contains("relayBindPolicy: relayBindPolicy"))
        XCTAssertTrue(source.contains("streamTopologyFlapSuppressedUntil"))
        XCTAssertTrue(source.contains("fallback producer flap suppressed"))
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotMergesInboundAndTrackSamples() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "inbound-rtp",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 47),
                    "bytesReceived": NSNumber(value: 94_288),
                    "framesReceived": NSNumber(value: 8),
                    "framesDecoded": NSNumber(value: 7)
                ]
            ),
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "track",
                values: [
                    "kind": NSString(string: "video"),
                    "frameWidth": NSNumber(value: 2_056),
                    "frameHeight": NSNumber(value: 1_329)
                ]
            )
        ]

        let snapshot = WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples)

        XCTAssertEqual(snapshot?.statType, "inbound-rtp")
        XCTAssertEqual(snapshot?.framesDecoded, 7)
        XCTAssertEqual(snapshot?.size, CGSize(width: 2_056, height: 1_329))
        XCTAssertTrue(snapshot?.hasFrameEvidence == true)
    }

    func testWebRTCSessionRemoteInboundVideoStatsSnapshotIgnoresTransportSideReports() {
        let samples = [
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "candidate-pair",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 40_312),
                    "bytesReceived": NSNumber(value: 48_836_959)
                ]
            ),
            WebRTCSession.RemoteInboundVideoStatsSample(
                type: "data-channel",
                values: [
                    "kind": NSString(string: "video"),
                    "packetsReceived": NSNumber(value: 20_993),
                    "bytesReceived": NSNumber(value: 25_438_840)
                ]
            )
        ]

        XCTAssertNil(WebRTCSession.remoteInboundVideoStatsSnapshot(from: samples))
    }

    func testLocalHandshakeCryptoPolicyResolverEnablesHybridForXWingAttempt() async throws {
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .liboqsPQC,
            activeSuite: .xwing,
            supportedSuites: [.xwing]
        )
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let keyHandle = SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xAA])))
        let identityPublicKey = Data([0xBB, 0xCC, 0xDD])
        let peerKEMKeys: [CryptoSuite: Data] = [.xwing: Data([0x01, 0x02, 0x03])]

        let strictContext = HandshakeContext(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: keyHandle,
            identityPublicKey: identityPublicKey,
            policy: .strictPQC,
            cryptoPolicy: .default,
            offeredSuites: [.xwing],
            peerKEMPublicKeys: peerKEMKeys
        )

        await XCTAssertThrowsErrorAsync(try await strictContext.buildMessageA()) { error in
            guard case HandshakeError.failed(.suiteNegotiationFailed) = error else {
                XCTFail("Expected suiteNegotiationFailed, got \(error)")
                return
            }
        }

        let enabledContext = HandshakeContext(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: keyHandle,
            identityPublicKey: identityPublicKey,
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing]),
            offeredSuites: [.xwing],
            peerKEMPublicKeys: peerKEMKeys
        )

        let messageA = try await enabledContext.buildMessageA()
        XCTAssertEqual(messageA.supportedSuites, [.xwing])
    }

    func testLocalHandshakeContextUsesPreparedOfferedSuiteInsteadOfProviderActiveSuite() async throws {
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .liboqsPQC,
            activeSuite: .mlkem768,
            supportedSuites: [.mlkem768fs, .mlkem768]
        )
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let keyHandle = SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xAB])))
        let context = HandshakeContext(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: keyHandle,
            identityPublicKey: Data([0x10, 0x20, 0x30]),
            policy: .strictPQC,
            cryptoPolicy: .default,
            offeredSuites: [.mlkem768fs],
            peerKEMPublicKeys: [.mlkem768: Data([0x99])]
        )

        let messageA = try await context.buildMessageA()
        XCTAssertEqual(messageA.supportedSuites, [.mlkem768fs])
        XCTAssertNotNil(messageA.initiatorContribution)
    }

    @MainActor
    func testWebRTCRekeyKEMCoverageTreatsCanonicalMLKEMAsForwardSecureReady() {
        let coverage = CrossNetworkWebRTCManager.testOnlyResolveTrustedPeerKEMCoverage(
            requiredSuites: [.mlkem768fs, .mlkem768],
            trustedPeerKEM: [.mlkem768: Data([0x99])]
        )

        XCTAssertEqual(coverage.availableSuites, [.mlkem768fs, .mlkem768])
        XCTAssertTrue(coverage.missingSuites.isEmpty)
    }

    @MainActor
    func testWebRTCRekeyKEMCoverageDoesNotTreatXWingAsMLKEMFamily() {
        let coverage = CrossNetworkWebRTCManager.testOnlyResolveTrustedPeerKEMCoverage(
            requiredSuites: [.mlkem768fs, .mlkem768],
            trustedPeerKEM: [.xwing: Data([0x42])]
        )

        XCTAssertTrue(coverage.availableSuites.isEmpty)
        XCTAssertEqual(coverage.missingSuites, [.mlkem768fs, .mlkem768])
    }

    @MainActor
    func testWebRTCStrictPQCRekeyCandidatesKeepMLKEMInteropWhenXWingIsPreferred() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )
        let candidates = CrossNetworkWebRTCManager.testOnlyStrictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProviderSuites: [.xwing],
            selectedProviderTier: .nativePQC,
            appleXWingAvailable: true
        )

        XCTAssertEqual(candidates, [.xwing, .mlkem768fs, .mlkem768])

        let mlkemOnlyPeer = CrossNetworkWebRTCManager.testOnlyResolveTrustedPeerKEMCoverage(
            requiredSuites: candidates,
            trustedPeerKEM: [.mlkem768: Data([0x99])]
        )
        XCTAssertEqual(mlkemOnlyPeer.availableSuites, [.mlkem768fs, .mlkem768])
        XCTAssertFalse(mlkemOnlyPeer.availableSuites.contains(.xwing))

        let xwingPeer = CrossNetworkWebRTCManager.testOnlyResolveTrustedPeerKEMCoverage(
            requiredSuites: candidates,
            trustedPeerKEM: [.xwing: Data([0x42]), .mlkem768: Data([0x99])]
        )
        XCTAssertEqual(xwingPeer.availableSuites.first, .xwing)
    }

    @MainActor
    func testWebRTCStrictPQCRekeyProviderPlansDoNotUseXWingForMLKEMOnlyPeer() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = CrossNetworkWebRTCManager.testOnlyWebRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: false,
            appleXWingAvailable: true
        )

        XCTAssertEqual(plans.first?.label, "native-pqc")
        XCTAssertEqual(plans.first?.suites, [.mlkem768fs, .mlkem768])
    }

    @MainActor
    func testWebRTCStrictPQCRekeyProviderPlansUseXWingOnlyForXWingPeer() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = CrossNetworkWebRTCManager.testOnlyWebRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: true,
            appleXWingAvailable: true
        )

        XCTAssertEqual(plans.first?.label, "native-xwing")
        XCTAssertEqual(plans.first?.suites, [.xwing])
    }

    @MainActor
    func testWebRTCStrictPQCRekeyProviderPlansPreferApplePQCBeforeLiboqsForInteropPeer() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = CrossNetworkWebRTCManager.testOnlyWebRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: true,
            peerHasXWing: false,
            appleXWingAvailable: true
        )

        XCTAssertEqual(plans.first?.label, "native-pqc")
        XCTAssertEqual(plans.first?.suites, [.mlkem768fs, .mlkem768])
        XCTAssertEqual(plans.dropFirst().first?.label, "liboqs-fallback")
    }

    @MainActor
    func testWebRTCStrictPQCRekeyCandidatesUseLiboqsWhenApplePQCUnavailable() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: true,
            osVersion: "test"
        )
        let candidates = CrossNetworkWebRTCManager.testOnlyStrictPQCRekeyCandidateSuites(
            capability: capability,
            selectedProviderSuites: [.mlkem768fs, .mlkem768],
            selectedProviderTier: .liboqsPQC,
            appleXWingAvailable: false
        )

        XCTAssertEqual(candidates, [.mlkem768fs, .mlkem768])
    }

    @MainActor
    func testWebRTCStrictPQCRekeyProviderPlansUseLiboqsWhenApplePQCUnavailable() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = CrossNetworkWebRTCManager.testOnlyWebRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: true,
            peerHasXWing: false,
            appleXWingAvailable: false
        )

        XCTAssertEqual(plans.first?.label, "liboqs")
        XCTAssertEqual(plans.first?.suites, [.mlkem768fs, .mlkem768])
    }

    @MainActor
    func testP2PConnectionManagerStrictInboundRejectsClassicOnlyPeer() {
        let manager = P2PConnectionManager.instance
        let original = PQCCryptoManager.instance.enforcePQCHandshake
        defer { PQCCryptoManager.instance.enforcePQCHandshake = original }
        PQCCryptoManager.instance.enforcePQCHandshake = true

        XCTAssertTrue(
            manager.testOnlyStrictPQCRejectsInboundHandshake(
                supportedSuites: [.x25519Ed25519]
            )
        )
    }

    @MainActor
    func testP2PConnectionManagerStrictInboundRejectsWhenLocalPQCUnavailable() {
        let manager = P2PConnectionManager.instance
        let original = PQCCryptoManager.instance.enforcePQCHandshake
        defer { PQCCryptoManager.instance.enforcePQCHandshake = original }
        PQCCryptoManager.instance.enforcePQCHandshake = true

        XCTAssertTrue(
            manager.testOnlyStrictPQCRejectsInboundHandshake(
                supportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
                localPQCAvailable: false
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundRekeyRejectsClassicOnlyMessageA() {
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeySelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundInitialAllowsVerifiedAuthorityClassicBootstrap() {
        XCTAssertEqual(
            CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeSelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            ),
            .classicOnly
        )
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeSelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true,
                expectedRemoteAuthorityAlgorithm: nil
            )
        )
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeSelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true,
                expectedRemoteAuthorityAlgorithm: .mlDSA65
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundRekeyRejectsWhenLocalPQCUnavailable() {
        XCTAssertNil(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeySelectionPolicy(
                supportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: false
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundRekeyRejectsEstablishedClassicSuite() {
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeyNegotiatedSuiteAllowed(
                .x25519Ed25519,
                strictPQCRequested: true
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyInboundPQCRekeyNegotiatedSuiteAllowed(
                .mlkem768MLDSA65,
                strictPQCRequested: true
            )
        )
    }

    @MainActor
    func testCrossNetworkWebRTCStrictInboundInitialNegotiatedClassicRequiresVerifiedAuthority() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeNegotiatedSuiteAllowed(
                .x25519Ed25519,
                strictPQCRequested: true,
                allowsClassicAuthorityBootstrap: true
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeNegotiatedSuiteAllowed(
                .x25519Ed25519,
                strictPQCRequested: true,
                allowsClassicAuthorityBootstrap: false
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeNegotiatedSuiteAllowed(
                .mlkem768MLDSA65,
                strictPQCRequested: true,
                allowsClassicAuthorityBootstrap: false
            )
        )
    }

    func testHandshakeDriverRetainsAuthenticatedAuthorityAfterOutboundHandshakeEstablishes() async throws {
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .classic,
            activeSuite: .x25519Ed25519,
            supportedSuites: [.x25519Ed25519]
        )
        let initiatorIdentity = Data([0x10, 0x20, 0x30, 0x40])
        let responderIdentity = Data([0x50, 0x60, 0x70, 0x80])
        let transport = CaptureOnlyDiscoveryTransport()
        let initiator = HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xAA]))),
            sigAAlgorithm: .mlDSA65,
            identityPublicKey: initiatorIdentity
        )
        let handshakeTask = Task {
            try await initiator.initiateHandshake(with: PeerIdentifier(deviceId: "mac-peer"))
        }
        let messageAFrame = try await waitForLatestFrame(from: transport)
        let messageA = try HandshakeMessageA.decode(
            from: HandshakePadding.unwrapIfNeeded(messageAFrame, label: "test/messageA")
        )

        let responderContext = HandshakeContext(
            role: .responder,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xBB]))),
            identityPublicKey: responderIdentity,
            policy: .default,
            cryptoPolicy: .default
        )
        try await responderContext.processMessageA(messageA)
        let (messageB, _) = try await responderContext.buildMessageB()

        await initiator.handleMessage(messageB.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

        guard case .waitingFinished(_, let sessionKeys, let expectingFrom) = await initiator.getCurrentState() else {
            XCTFail("Expected initiator handshake to be waiting for Finished after MessageB")
            return
        }
        XCTAssertEqual(expectingFrom, .responder)

        let responderFinished = LocalHandshakeFinishedHelper.responderFinished(for: sessionKeys)
        await initiator.handleMessage(responderFinished.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

        let establishedKeys = try await handshakeTask.value
        XCTAssertEqual(establishedKeys.negotiatedSuite, .x25519Ed25519)

        guard case .established = await initiator.getCurrentState() else {
            XCTFail("Expected initiator handshake to establish")
            return
        }

        let initiatorAuthority = await initiator.getAuthenticatedRemoteAuthority()
        XCTAssertEqual(
            initiatorAuthority,
            try LocalHandshakeAuthorityHelper.authority(
                identityPublicKey: responderIdentity,
                signatureAlgorithm: signatureProvider.signatureAlgorithm
            )
        )
    }

    func testHandshakeDriverClearsAuthenticatedAuthorityAfterCancellation() async throws {
        let provider = LocalHandshakeTestCryptoProvider(
            tier: .classic,
            activeSuite: .x25519Ed25519,
            supportedSuites: [.x25519Ed25519]
        )
        let signatureProvider = LocalHandshakeTestSignatureProvider()
        let initiatorIdentity = Data([0x01, 0x23, 0x45, 0x67])
        let responderIdentity = Data([0x89, 0xAB, 0xCD, 0xEF])
        let transport = CaptureOnlyDiscoveryTransport()
        let initiator = HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xCC]))),
            sigAAlgorithm: .mlDSA65,
            identityPublicKey: initiatorIdentity
        )
        let handshakeTask = Task {
            try await initiator.initiateHandshake(with: PeerIdentifier(deviceId: "mac-peer"))
        }
        let messageAFrame = try await waitForLatestFrame(from: transport)
        let messageA = try HandshakeMessageA.decode(
            from: HandshakePadding.unwrapIfNeeded(messageAFrame, label: "test/messageA")
        )

        let responderContext = HandshakeContext(
            role: .responder,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xDD]))),
            identityPublicKey: responderIdentity,
            policy: .default,
            cryptoPolicy: .default
        )
        try await responderContext.processMessageA(messageA)
        let (messageB, _) = try await responderContext.buildMessageB()

        await initiator.handleMessage(messageB.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

        guard case .waitingFinished = await initiator.getCurrentState() else {
            XCTFail("Expected initiator to be waiting for Finished after a valid MessageB")
            return
        }
        let authorityBeforeCancel = await initiator.getAuthenticatedRemoteAuthority()
        XCTAssertEqual(
            authorityBeforeCancel,
            try LocalHandshakeAuthorityHelper.authority(
                identityPublicKey: responderIdentity,
                signatureAlgorithm: signatureProvider.signatureAlgorithm
            )
        )

        await initiator.cancel()
        await XCTAssertThrowsErrorAsync(try await handshakeTask.value) { _ in }

        guard case .failed(let reason) = await initiator.getCurrentState() else {
            XCTFail("Expected initiator handshake to transition to failed after cancel")
            return
        }
        XCTAssertEqual(reason, .cancelled)
        let authorityAfterCancel = await initiator.getAuthenticatedRemoteAuthority()
        XCTAssertNil(authorityAfterCancel)
    }

    func testStrictBootstrapOnlyLogsAppMessageTypeAndAcceptsLivenessControls() throws {
        let source = try crossNetworkWebRTCManagerSource()
        let bootstrapFilter = try sourceSlice(
            from: "let messageKind = Self.bootstrapAppMessageKind(appMessage)",
            to: "await handleInboundAppMessageOverWebRTC",
            in: source
        )

        XCTAssertTrue(bootstrapFilter.contains("case .heartbeat, .ping, .pong, .peerDisconnecting:"))
        XCTAssertTrue(bootstrapFilter.contains("accepted control app message before PQC rekey"))
        XCTAssertTrue(bootstrapFilter.contains("type=\\(messageKind)"))
        XCTAssertTrue(bootstrapFilter.contains("lastRekey=\\(lastRekeyEvent ?? \"-\")"))
        XCTAssertTrue(bootstrapFilter.contains("ignored non-bootstrap app message"))
    }

    func testStrictBootstrapOnlyDropsMediaPayloadsBeforePQCRekey() throws {
        let source = try crossNetworkWebRTCManagerSource()
        let highThroughputPublisher = try sourceSlice(
            from: "private func publishHighThroughputRemoteDesktopPayloadIfCurrent",
            to: "@discardableResult\n    private func handleDecodedControlPlaintext",
            in: source
        )
        let receiveLoopProbe = try sourceSlice(
            from: "if let decoded = Self.decodeRemoteDesktopHighThroughputPayload(plaintext)",
            to: "if await handleDecodedControlPlaintext",
            in: source
        )
        let screenPublisher = try sourceSlice(
            from: "private func publishDecodedScreenDataIfCurrent",
            to: "func sendFramed",
            in: source
        )

        XCTAssertTrue(highThroughputPublisher.contains("isStrictPQCClassicBootstrapOnlyCurrentSession"))
        XCTAssertTrue(highThroughputPublisher.contains("source=control-channel"))
        XCTAssertTrue(highThroughputPublisher.contains("return false"))
        XCTAssertTrue(receiveLoopProbe.contains("let published = await publishHighThroughputRemoteDesktopPayloadIfCurrent"))
        XCTAssertTrue(receiveLoopProbe.contains("if published && !usesDirectControlPayloads"))
        XCTAssertTrue(screenPublisher.contains("strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)"))
        XCTAssertTrue(screenPublisher.contains("source=screen-channel"))
        XCTAssertLessThan(
            try XCTUnwrap(screenPublisher.range(of: "strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)")?.lowerBound),
            try XCTUnwrap(screenPublisher.range(of: "publishDecodedScreenData(screenData)")?.lowerBound)
        )
    }

    func testStrictBootstrapTimeoutExtendsWhileLivenessOrRekeyIsActive() throws {
        let source = try crossNetworkWebRTCManagerSource()
        let livenessWatchdog = try sourceSlice(
            from: "private func startRemotePeerLivenessWatchdog",
            to: "private func markStrictPQCClassicBootstrapOnly",
            in: source
        )
        let bootstrapTimeout = try sourceSlice(
            from: "strictPQCClassicBootstrapTimeoutTasksBySessionId[sessionId] = Task",
            to: "private func clearStrictPQCClassicBootstrapOnly",
            in: source
        )

        XCTAssertTrue(source.contains("strictPQCClassicBootstrapMaxGraceSeconds"))
        XCTAssertTrue(livenessWatchdog.contains("strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)"))
        XCTAssertTrue(livenessWatchdog.contains("continue"))
        XCTAssertTrue(bootstrapTimeout.contains("hasFreshActivity || isRekeyActivelyProgressing"))
        XCTAssertTrue(bootstrapTimeout.contains("strictPQCClassicBootstrapMaxGraceSeconds"))
        XCTAssertTrue(bootstrapTimeout.contains("timeout extended while rekey/liveness is active"))
        XCTAssertTrue(bootstrapTimeout.contains("failStrictPQCBootstrapSession"))
    }
}

private struct FixedSignatureCallback: SigningCallback {
    let signature: Data

    func sign(data: Data) async throws -> Data {
        signature
    }
}

private struct LocalHandshakeTestSignatureProvider: ProtocolSignatureProvider {
    let signatureAlgorithm: ProtocolSigningAlgorithm = .mlDSA65

    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        switch key {
        case .callback(let callback):
            return try await callback.sign(data: data)
        case .softwareKey(let data):
            return data
        #if canImport(Security)
        case .secureEnclaveRef:
            return Data([0x01])
        #endif
        }
    }

    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        true
    }
}

private struct LocalHandshakeTestCryptoProvider: CryptoProvider {
    let providerName = "LocalHandshakeTest"
    let tier: CryptoTier
    let activeSuite: CryptoSuite
    let supportedSuites: [CryptoSuite]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains(suite)
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        .init(
            encapsulatedKey: Data(repeating: 0x01, count: 32),
            ciphertext: plaintext,
            tag: Data(repeating: 0x02, count: 16),
            nonce: Data(repeating: 0x03, count: 12)
        )
    }

    func kemDemSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info)
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        (
            sealedBox: try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info),
            sharedSecret: SecureBytes(data: Data(repeating: 0x11, count: 32))
        )
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        sealedBox.ciphertext
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        sealedBox.ciphertext
    }

    func kemDemOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        sealedBox.ciphertext
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        (
            plaintext: sealedBox.ciphertext,
            sharedSecret: SecureBytes(data: Data(repeating: 0x22, count: 32))
        )
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        (Data([0x33, 0x44]), SecureBytes(data: Data(repeating: 0x55, count: 32)))
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        SecureBytes(data: Data(repeating: 0x66, count: 32))
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        Data([0x77])
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        true
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        KeyPair(
            publicKey: Data(repeating: usage == .ephemeral ? 0x10 : 0x11, count: 32),
            privateKey: Data(repeating: usage == .ephemeral ? 0x12 : 0x13, count: 32)
        )
    }
}

private enum LocalHandshakeAuthorityHelper {
    static func authority(
        identityPublicKey: Data,
        signatureAlgorithm: ProtocolSigningAlgorithm
    ) throws -> AuthenticatedRemoteAuthority {
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: identityPublicKey,
            protocolAlgorithm: signatureAlgorithm.wire,
            secureEnclavePublicKey: nil
        )
        return AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: identityKeys.protocolAlgorithm.rawValue,
            protocolPublicKeyFingerprint: try identityKeys.authoritativeProtocolFingerprint().lowercased()
        )
    }
}

private actor CaptureOnlyDiscoveryTransport: DiscoveryTransport {
    private(set) var frames: [Data] = []

    func send(to peer: PeerIdentifier, data: Data) async throws {
        _ = peer
        frames.append(data)
    }

    func latestFrame() -> Data? {
        frames.last
    }
}

private enum LocalHandshakeFinishedHelper {
    static func responderFinished(for sessionKeys: SessionKeys) -> HandshakeFinished {
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKeys.receiveKey),
            salt: Data(),
            info: Data("SkyBridge-FINISHED|R2I|".utf8) + sessionKeys.transcriptHash,
            outputByteCount: 32
        )
        let mac = Data(HMAC<SHA256>.authenticationCode(for: sessionKeys.transcriptHash, using: macKey))
        return HandshakeFinished(direction: .responderToInitiator, mac: mac)
    }
}

private enum LocalHandshakeTestError: Error {
    case timedOutWaitingForCapturedFrame
}

private func waitForLatestFrame(
    from transport: CaptureOnlyDiscoveryTransport,
    iterations: Int = 200,
    sleepNanoseconds: UInt64 = 5_000_000
) async throws -> Data {
    for _ in 0..<iterations {
        if let frame = await transport.latestFrame() {
            return frame
        }
        try? await Task.sleep(nanoseconds: sleepNanoseconds)
    }
    throw LocalHandshakeTestError.timedOutWaitingForCapturedFrame
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        errorHandler(error)
    }
}
