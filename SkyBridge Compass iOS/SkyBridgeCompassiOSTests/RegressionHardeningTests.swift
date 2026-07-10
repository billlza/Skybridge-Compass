import CryptoKit
import Network
import SkyBridgeRealtimeMedia
import XCTest

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
    XCTAssertEqual(lease.localExpiresAt, 1_770_000_000)
  }

  func testCrossNetworkSignalServerClientStaysOutsideManager() throws {
    let manager = try crossNetworkWebRTCManagerSource()
    let managerTestSupport = try crossNetworkWebRTCManagerTestSupportSource()
    let signalClient = try crossNetworkSignalServerClientSource()

    XCTAssertFalse(manager.contains("actor SignalServerClientCompat"))
    XCTAssertTrue(signalClient.contains("actor SignalServerClientCompat"))
    XCTAssertTrue(signalClient.contains("static func testOnlyDecodeMediaRelayLeaseResponse"))
    XCTAssertTrue(signalClient.contains("nonisolated static func testOnlyRequestTimeoutSeconds"))
    XCTAssertFalse(manager.contains("static func testOnlyDecodeMediaRelayLeaseResponse"))
    XCTAssertTrue(
      managerTestSupport.contains("SignalServerClientCompat.testOnlyDecodeMediaRelayLeaseResponse"))
    XCTAssertTrue(
      managerTestSupport.contains("SignalServerClientCompat.testOnlyRequestTimeoutSeconds"))
  }

  func testCrossNetworkServerConfigAndTURNServiceStayOutsideManager() throws {
    let manager = try crossNetworkWebRTCManagerSource()
    let serverConfig = try crossNetworkServerConfigSource()

    XCTAssertFalse(manager.contains("enum CrossNetworkServerConfig"))
    XCTAssertFalse(manager.contains("actor CrossNetworkTURNCredentialService"))
    XCTAssertTrue(serverConfig.contains("enum CrossNetworkServerConfig"))
    XCTAssertTrue(serverConfig.contains("private actor CrossNetworkTURNCredentialService"))
    XCTAssertTrue(serverConfig.contains("static func dynamicICEConfig"))
    XCTAssertTrue(manager.contains("CrossNetworkServerConfig.dynamicICEConfig"))
  }

  func testIOSWebRTCSendsAuthenticatedRouteBindingAfterEstablishedBusinessSession() throws {
    let manager = try crossNetworkWebRTCManagerSource()

    XCTAssertTrue(manager.contains("private func sendLocalAuthenticatedRouteBindings("))
    XCTAssertTrue(manager.contains("CrossNetworkWebRTCLocalAppMessageFactory.authenticatedFileTransferRouteBindingMessages("))
    XCTAssertTrue(manager.contains("FileTransferRuntime.shared.ensureHealthy()"))
    XCTAssertTrue(manager.contains("strict_pqc_rekey_pending"))
    XCTAssertTrue(manager.contains("stage: \"initial-handshake\""))
    XCTAssertTrue(manager.contains("stage: \"inbound-initial-handshake\""))
    XCTAssertTrue(manager.contains("stage: \"inbound-rekey\""))
    XCTAssertTrue(manager.contains("stage: \"outbound-rekey\""))
  }

  func testInboundFileTransferSupportStaysOutsideManager() throws {
    let manager = try crossNetworkWebRTCManagerSource()
    let fileTransfer = try crossNetworkWebRTCFileTransferSource()
    let support = try crossNetworkWebRTCInboundFileTransferSupportSource()

    XCTAssertFalse(manager.contains("static func validateInboundMetadata"))
    XCTAssertFalse(manager.contains("static func expectedInboundChunkSize"))
    XCTAssertFalse(manager.contains("static func sha256File"))
    XCTAssertTrue(support.contains("static func validateInboundMetadata"))
    XCTAssertTrue(support.contains("static func validateInboundTransferId"))
    XCTAssertTrue(support.contains("inboundFileTransferExplicitApprovalRequiredMessage"))
    XCTAssertTrue(support.contains("inboundFileTransferMissingSenderIdentityMessage"))
    XCTAssertTrue(support.contains("static func requiredInboundSenderDeviceId"))
    XCTAssertTrue(support.contains("static func expectedInboundChunkSize"))
    XCTAssertTrue(support.contains("static func sha256File"))
    XCTAssertTrue(manager.contains("var inboundFileTransferApprovalProvider"))
    XCTAssertTrue(fileTransfer.contains("Self.validateInboundMetadata"))
    XCTAssertTrue(fileTransfer.contains("Self.validateInboundTransferId"))
    XCTAssertTrue(fileTransfer.contains("await inboundFileTransferApprovalProvider(approvalRequest)"))
    XCTAssertTrue(fileTransfer.contains("Self.normalizedInboundApprovalRejectionMessage(reason)"))
    XCTAssertTrue(fileTransfer.contains("Self.expectedInboundChunkSize"))
    XCTAssertTrue(fileTransfer.contains("Self.sha256File"))
    XCTAssertTrue(fileTransfer.contains("guard let senderId = Self.requiredInboundSenderDeviceId(msg.senderDeviceId)"))
    XCTAssertTrue(fileTransfer.contains("Self.inboundFileTransferMissingSenderIdentityMessage"))
    XCTAssertFalse(fileTransfer.contains("msg.senderDeviceId ?? (remoteDeviceId ?? \"mac\")"))
  }

  func testInboundFileTransferRequiresProtocolSenderIdentity() {
    XCTAssertEqual(CrossNetworkWebRTCManager.requiredInboundSenderDeviceId(" sender "), "sender")
    XCTAssertNil(CrossNetworkWebRTCManager.requiredInboundSenderDeviceId(nil))
    XCTAssertNil(CrossNetworkWebRTCManager.requiredInboundSenderDeviceId(" \n\t "))
  }

  func testInboundFileTransferRejectsUnsafeFileNamesInsteadOfBasenameFallback() throws {
    XCTAssertNil(CrossNetworkWebRTCManager.validateInboundTransferId(UUID().uuidString))
    XCTAssertEqual(
      CrossNetworkWebRTCManager.validateInboundTransferId("../transfer"),
      "Invalid metadata (invalid transferId)"
    )
    XCTAssertEqual(
      CrossNetworkWebRTCManager.validateInboundTransferId("transfer"),
      "Invalid metadata (invalid transferId)"
    )

    for unsafeName in ["../secret.txt", "nested/report.pdf", "nested\\report.pdf", "nested⁄report.pdf", "nested∕report.pdf"] {
      XCTAssertEqual(
        CrossNetworkWebRTCManager.validateInboundMetadata(
          fileName: unsafeName,
          fileSize: 1,
          chunkSize: 1,
          totalChunks: 1
        ),
        "Invalid metadata (unsafe fileName)"
      )
      XCTAssertThrowsError(
        try CrossNetworkWebRTCManager.makeUniqueDestinationURL(
          baseDir: FileManager.default.temporaryDirectory,
          fileName: unsafeName
        )
      )
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("iOSInboundFileTransfer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let existing = directory.appendingPathComponent("report.pdf", isDirectory: false)
    _ = FileManager.default.createFile(atPath: existing.path, contents: Data())

    XCTAssertNil(
      CrossNetworkWebRTCManager.validateInboundMetadata(
        fileName: "report.pdf",
        fileSize: 1,
        chunkSize: 1,
        totalChunks: 1
      )
    )
    XCTAssertEqual(
      try CrossNetworkWebRTCManager.makeUniqueDestinationURL(
        baseDir: directory,
        fileName: "report.pdf"
      ).lastPathComponent,
      "report (1).pdf"
    )
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

  func testBenignSmokeStartupStatesStayOutOfWarningLogs() throws {
    let liveActivitySource = try liveActivityManagerSource()
    let appSource = try skyBridgeCompassAppSource()
    let fileTransferServiceSource = try iosFileTransferNetworkServiceSource()
    let remoteDesktopSource = try remoteDesktopManagerSource()
    let p2pConnectionSource = try p2pConnectionManagerSource()

    XCTAssertFalse(
      liveActivitySource.contains("SkyBridgeLogger.shared.warning(\"⚠️ Live Activities 未启用\")"),
      "Disabled Live Activities are a normal device setting and must not make smoke logs noisy."
    )
    XCTAssertFalse(
      appSource.contains("SkyBridgeLogger.shared.warning(\"ℹ️ 灵动岛 Live Activity 未启动"),
      "A skipped Live Activity startup is expected when the device setting is off."
    )
    XCTAssertFalse(
      fileTransferServiceSource.contains("SkyBridgeLogger.shared.warning(\n            \"⚠️ iOS 文件传输 listener 不健康"),
      "A stopped listener that is immediately restarted by ensureHealthy should be logged as self-healing info."
    )
    XCTAssertTrue(
      remoteDesktopSource.contains(
        "if crossNetwork.activeRemoteDesktopSessionId == nil {\n            SkyBridgeLogger.shared.info(\"ℹ️ \\(message)\")\n        } else {\n            SkyBridgeLogger.shared.warning(\"⚠️ \\(message)\")\n        }"
      ),
      "Late render-continuity recovery after the remote desktop session has ended must not be emitted as a warning."
    )
    XCTAssertFalse(
      remoteDesktopSource.contains("SkyBridgeLogger.shared.warning(\n                    \"⚠️ 视频解码队列正在等待关键帧，已暂时丢弃预测帧\""),
      "Dropping predictive frames while already waiting for a keyframe is expected decode policy; queue overflow remains the warning."
    )
    XCTAssertFalse(
      p2pConnectionSource.contains("SkyBridgeLogger.shared.warning(\"🔔 收到配对/受信任申请"),
      "Receiving a pairing/trust request is a normal inbound event and should not dirty smoke logs with warnings."
    )
    XCTAssertFalse(
      p2pConnectionSource.contains("SkyBridgeLogger.shared.warning(\"⏹️ 连接已取消/断开"),
      "A cancelled connection state can be ordinary transport teardown; concrete failures should be logged at their failure site."
    )
  }

  func testP2PConnectionReadyGateTimeoutResumesUnresolvedConnection() async {
    let gate = P2PConnectionManager.ConnectionReadyGate()
    let startedAt = Date()

    do {
      try await gate.waitReady(timeoutSeconds: 0.05)
      XCTFail("Connection ready wait should fail when no ready or failed state arrives.")
    } catch {
      XCTAssertLessThan(
        Date().timeIntervalSince(startedAt),
        1.0,
        "Connection candidate timeout must not hang behind an uncancellable continuation."
      )
    }
  }

  func testPlainFrameReceiveGateTimeoutResumesUnresolvedReceive() async {
    let gate = P2PConnectionManager.PlainFrameReceiveGate()
    let startedAt = Date()

    do {
      _ = try await gate.wait(timeoutSeconds: 0.05)
      XCTFail("Plain frame receive should fail when no frame arrives.")
    } catch {
      XCTAssertLessThan(
        Date().timeIntervalSince(startedAt),
        1.0,
        "Plain frame receive timeout must not hang behind an uncancellable continuation."
      )
    }
  }

  func testRealDeviceSmokeUsesDynamicMacControlPortForPIBRoute() throws {
    let hostSource = try repositoryScriptSource("Sources/LocalLanInteropHost/main.swift")
    let smokeScript = try repositoryScriptSource("Scripts/run_real_device_p2p_remote_smoke.sh")
    let harnessSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift"
    )
    let p2pSource = try p2pConnectionManagerSource()

    XCTAssertTrue(hostSource.contains("waitForControlAdvertisementPort()"))
    XCTAssertTrue(hostSource.contains("ready discovery=_skybridge._tcp port=\\(controlPort)"))
    XCTAssertFalse(
      hostSource.contains("ready discovery=_skybridge._tcp port=9527"),
      "The macOS smoke host must report the actual dynamic listener port, not a stale fixed port."
    )

    XCTAssertTrue(smokeScript.contains("MAC_CONTROL_PORT="))
    XCTAssertTrue(smokeScript.contains("SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE:-direct"))
    XCTAssertTrue(smokeScript.contains("MAC_DIRECT_BIN=\"$ROOT_DIR/.build/debug/LocalLanInteropHost\""))
    XCTAssertTrue(smokeScript.contains("if [[ \"$MAC_HOST_LAUNCH_MODE\" == \"direct\" ]]"))
    XCTAssertTrue(smokeScript.contains("\"$MAC_DIRECT_BIN\" >\"$HOST_STDOUT\" 2>&1 &"))
    XCTAssertTrue(smokeScript.contains("launch method=direct-app-binary pid=$HOST_PID mode=direct binary=swiftpm-build-product"))
    XCTAssertFalse(smokeScript.contains("fallbackFrom=open-app-bundle"))
    XCTAssertTrue(smokeScript.contains("failed stage=mac-host"))
    XCTAssertTrue(smokeScript.contains("verify_mac_control_port_reachable \"$MAC_CONTROL_HOST\" \"$MAC_CONTROL_PORT\""))
    XCTAssertTrue(smokeScript.contains("mac-control-port reachable=1 host=$host port=$port source=pre-ios-probe"))
    XCTAssertTrue(smokeScript.contains("failed stage=mac-host phase=control-port-probe reason=tcp-unreachable"))
    XCTAssertTrue(smokeScript.contains("SKYBRIDGE_SMOKE_TARGET_CONTROL_PORT=\"$MAC_CONTROL_PORT\""))
    XCTAssertTrue(smokeScript.contains("SKYBRIDGE_SMOKE_TARGET_HOST=\"$MAC_CONTROL_HOST\""))

    XCTAssertTrue(harnessSource.contains("applySmokePinnedControlRoute"))
    XCTAssertTrue(harnessSource.contains("SKYBRIDGE_SMOKE_TARGET_CONTROL_PORT"))
    XCTAssertTrue(harnessSource.contains("updated.portMap[controlService] = port"))

    XCTAssertTrue(
      p2pSource.contains("connectionEndpointCandidates(for: device, preferDirectHostPort: true)"),
      "PIB-1 OOB binding should try the pinned direct LAN route before Bonjour service fallback."
    )
  }

  func testP2PPathRecoverySocketFailureIsRecoverableOnlyWithRecoveryContext() throws {
    let socketNotConnected = NWError.posix(.ENOTCONN)
    let connectionRefused = NWError.posix(.ECONNREFUSED)
    let source = try p2pConnectionManagerSource()
    let failedStateBody = try sourceSlice(
      from: "private func handleConnectionStateChange",
      to: "private func startHeartbeatIfNeeded",
      in: source
    )

    XCTAssertTrue(
      P2PConnectionManager.isRecoverablePathRecoverySocketFailure(
        socketNotConnected,
        pathRecoveryScheduled: true,
        recoveryMessageActive: false
      )
    )
    XCTAssertTrue(
      P2PConnectionManager.isRecoverablePathRecoverySocketFailure(
        socketNotConnected,
        pathRecoveryScheduled: false,
        recoveryMessageActive: true
      )
    )
    XCTAssertFalse(
      P2PConnectionManager.isRecoverablePathRecoverySocketFailure(
        socketNotConnected,
        pathRecoveryScheduled: false,
        recoveryMessageActive: false
      ),
      "Socket-not-connected without an active path-recovery transition is a real connection failure."
    )
    XCTAssertFalse(
      P2PConnectionManager.isRecoverablePathRecoverySocketFailure(
        connectionRefused,
        pathRecoveryScheduled: true,
        recoveryMessageActive: false
      ),
      "Only the Network.framework ENOTCONN transition emitted during path recovery should be demoted."
    )
    XCTAssertTrue(
      failedStateBody.contains("upsertActiveConnection(device: effectiveDevice, status: .connecting)"),
      "Recoverable path-loss failures must keep the presentation in a reconnecting state."
    )
    XCTAssertTrue(
      failedStateBody.contains("if !isPathRecoverySocketFailure {\n                cancelPeerProtectionRoots"),
      "Recoverable path-loss failures must not reset reconnect budget or protected discovery roots."
    )
  }

  func testRemoteAudioSoftOverflowUsesBackpressureInsteadOfPlayerReset() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let audioSourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopAudioPlayback.swift"
    )
    let managerSourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
    )
    let audioSource = try readRepositorySourceForSourceShapeTests(at: audioSourceURL)
    let managerSource = try readRepositorySourceForSourceShapeTests(at: managerSourceURL)

    XCTAssertFalse(
      audioSource.contains("resetPlayerQueue(on: playerNode, reason: \"queued-audio-overflow\")"),
      "Soft audio backlog must not reset AVAudioPlayerNode; repeated resets cause audible crackle and queue churn."
    )
    XCTAssertTrue(
      audioSource.contains("queuedFrames + chunk.frameLength > currentMaxQueuedFrames"),
      "Soft backlog should be handled before scheduling the next chunk."
    )
    XCTAssertTrue(
      audioSource.contains("远端音频播放队列背压"),
      "Backpressure should be visible in logs without repeatedly rebuilding the player queue."
    )
    XCTAssertTrue(
      audioSource.contains("queued-audio-runaway"),
      "A hard reset should remain available only for truly runaway queued audio."
    )
    XCTAssertTrue(
      managerSource.contains(
        "Task.detached(priority: .utility) { [remoteAudioPlayback] in\n            await remoteAudioPlayback.handle(payload, context: context)\n        }"
      ),
      "Inbound audio playback work should stay below video/render priority so audio backpressure cannot halve the frame rate."
    )
    XCTAssertFalse(
      managerSource.contains(
        "Task.detached(priority: .userInitiated) { [remoteAudioPlayback] in\n            await remoteAudioPlayback.handle(payload, context: context)"
      ),
      "Remote audio playback must not run at userInitiated priority while video frames are being decoded and displayed."
    )
  }

  func testViewerStreamConfigurationDoesNotAwaitRealtimeAudioReceiverStartup() throws {
    let source = try remoteDesktopManagerSource()

    XCTAssertTrue(
      source.contains("let mediaAudioBinding = currentRealtimeMediaAudioBindingIfUsable()"))
    XCTAssertTrue(
      source.contains("ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)"))
    XCTAssertFalse(
      source.contains("let mediaAudioBinding = await prepareRealtimeMediaAudioReceiverIfNeeded"),
      "The viewer must send the video/main config without awaiting realtime audio lease or receiver startup."
    )
    XCTAssertTrue(
      source.contains(
        "await self.pushViewerStreamConfiguration(force: false, refreshStream: false)"),
      "The audio-present update should be a normal deduped config send, not a forced refresh."
    )
    XCTAssertTrue(
      source.contains("event=audioEndpointPrepared"),
      "The viewer should publish the relay endpoint after the configured relay bind policy is satisfied."
    )
    XCTAssertTrue(
      source.contains("strictRelayBindRequired ? .requireAcknowledgement : .optimisticAfterSend"))
    XCTAssertTrue(source.contains("relayBindPolicy: relayBindPolicy"))
    XCTAssertTrue(
      source.contains("payloadIncludesAudioEndpoint: payload.mediaAudioEndpoint != nil"))
  }

  func testRealtimeMediaAudioReceiverStartupIsSingleflightAndObservable() throws {
    let source = try remoteDesktopManagerSource()
    let runtimeModelsSource = try remoteDesktopRuntimeModelsSource()

    XCTAssertTrue(
      source.contains("guard realtimeMediaAudioReceiverStartTask == nil else { return }"))
    XCTAssertTrue(source.contains("realtimeMediaAudioReceiverStartGeneration"))
    XCTAssertTrue(
      runtimeModelsSource.contains(
        "realtimeMediaAudioReceiverSlowDiagnosticDelay: Duration = .seconds(3)"))
    XCTAssertTrue(
      runtimeModelsSource.contains("realtimeMediaAudioReceiverStageTimeout: Duration = .seconds(8)")
    )
    XCTAssertTrue(
      runtimeModelsSource.contains(
        "realtimeMediaAudioReceiverTotalTimeout: Duration = .seconds(15)"))
    XCTAssertTrue(
      source.contains(
        "RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioReceiverSlowDiagnosticDelay"))
    XCTAssertTrue(
      source.contains("RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioReceiverStageTimeout"))
    XCTAssertTrue(
      source.contains("RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioReceiverTotalTimeout"))
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
    XCTAssertTrue(source.contains("SkyBridgeSmokeTraceWriter.appendStatus(streamConfigLine)"))
    XCTAssertFalse(
      source.contains("event=receiverStartTimeout"),
      "The 3s receiver startup diagnostic must no longer hard-cancel or report timeout; it is only receiverStartSlow."
    )
  }

  func testFileTransferSmokeReportsSignedKEMRefreshEvidenceFailureAsNamedPhase() throws {
    let source = try skyBridgeCompassAppSource()
    let failureBody = try sourceSlice(
      from: "private nonisolated static func fileTransferFailureLine",
      to: "private nonisolated static func remoteDesktopFailureLine",
      in: source
    )

    XCTAssertTrue(failureBody.contains("case 4101:"))
    XCTAssertTrue(failureBody.contains("phase=signed_kem_refresh_evidence_missing"))
    XCTAssertTrue(failureBody.contains("case 4102:"))
    XCTAssertTrue(failureBody.contains("phase=signed_kem_refresh_wrong_suite"))
  }

  func testOptimisticRelayBindAckTimeoutUsesGraceInsteadOfImmediateLeaseRetry() throws {
    let source = try remoteDesktopManagerSource()
    let timeoutBody = try sourceSlice(
      from: "case .relayBindAckTimedOut:",
      to: "case .relayBindRejected(let reason):",
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
      try XCTUnwrap(
        failureBody.range(of: "guard realtimeMediaAudioReceiverSessionId == sessionId")?.lowerBound),
      try XCTUnwrap(
        failureBody.range(of: "markRealtimeMediaRelayEndpointUnusableForActiveSession")?.lowerBound)
    )
    XCTAssertTrue(graceBody.contains("if snapshot.received > 0"))
    XCTAssertFalse(
      graceBody.contains("if snapshot.datagramsSeen > 0 || snapshot.received > 0"),
      "Grace success must require authenticated received audio, not just raw UDP bytes."
    )
    XCTAssertTrue(graceBody.contains("relayBindAckTimedOutNoTraffic"))
    XCTAssertTrue(graceBody.contains("relayBindAckTimedOutNoAuthenticatedTraffic"))
    XCTAssertTrue(
      source.contains("pushViewerStreamConfiguration(force: false, refreshStream: false)"))
  }

  func testLANRealtimeAudioNoTrafficRepublishesEndpointInsteadOfWaitingOnJitter() throws {
    let source = try remoteDesktopManagerSource()
    let noTrafficBody = try sourceSlice(
      from: "private func scheduleRealtimeMediaAudioNoTrafficRecovery(",
      to: "private func scheduleRealtimeMediaAudioEndpointRenewal(",
      in: source
    )

    XCTAssertTrue(noTrafficBody.contains("expectedTransportMode == .crossNetwork || expectedTransportMode == .lan"))
    XCTAssertTrue(noTrafficBody.contains("self.activeTransportMode == expectedTransportMode"))
    XCTAssertTrue(noTrafficBody.contains("\"lanNoTrafficRecovery\""))
    XCTAssertTrue(noTrafficBody.contains("\"lanNoTrafficRecoveryExhausted\""))
    XCTAssertTrue(noTrafficBody.contains("\"lan-endpoint-published-but-no-datagrams\""))
    XCTAssertTrue(noTrafficBody.contains("action=stream-config-republish"))
    XCTAssertTrue(noTrafficBody.contains("action=receiver-rebind"))
    XCTAssertTrue(noTrafficBody.contains("reason: \"lan-no-traffic-after-republish\""))
    XCTAssertTrue(noTrafficBody.contains("self.ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mode)"))
    XCTAssertTrue(noTrafficBody.contains("await self.pushViewerStreamConfiguration(force: true, refreshStream: false)"))
    XCTAssertTrue(noTrafficBody.contains("self.scheduleRealtimeMediaAudioNoTrafficRecovery("))
    XCTAssertTrue(noTrafficBody.contains("\"action\": \"doctor-fail\""))
    XCTAssertFalse(
      noTrafficBody.contains("guard activeTransportMode == .crossNetwork else { return }"),
      "LAN realtime audio zero-rx must actively republish the UDP endpoint instead of only letting jitter diagnostics report starvation."
    )
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

  func testStrictRealtimeAudioRenewalUsesMakeBeforeBreakInsteadOfInPlaceRebind() throws {
    let source = try remoteDesktopManagerSource()
    let renewalBody = try sourceSlice(
      from: "private func renewRealtimeMediaAudioRelayEndpoint",
      to: "private func handleRealtimeMediaAudioRelayBindFailure",
      in: source
    )

    XCTAssertTrue(
      source.contains(
        "max(RemoteDesktopManagerRuntimeConfig.realtimeMediaAudioEndpointRenewalLeadTime, 35)"),
      "Strict receiver lease renewal should lead the macOS sender renewal margin instead of reacting after sender rollover."
    )
    XCTAssertTrue(
      renewalBody.contains(
        "let strictRenewalRequiresRollover = strictCrossNetworkMediaValidationActive && sameRelayAddress"
      )
    )
    XCTAssertTrue(
      renewalBody.contains("if !strictRenewalRequiresRollover,\n           sameRelayAddress,"),
      "Strict cross-network media validation must not rebind the live audio receive transport in place."
    )
    XCTAssertTrue(renewalBody.contains("reason=strict-make-before-break"))
    XCTAssertTrue(renewalBody.contains("\"probable\": \"strict-make-before-break\""))
    XCTAssertTrue(renewalBody.contains("Task(priority: .utility)"))
    XCTAssertTrue(renewalBody.contains("await oldTransport.stop()"))
  }

  func testStrictSmokeAudioRenewalUsesMakeBeforeBreakInsteadOfInPlaceRebind() throws {
    let source = try skyBridgeCompassAppSource()
    let renewalBody = try sourceSlice(
      from: "private func renewSmokeAudioRelayEndpoint",
      to: "private func promoteSmokeAudioRelayTransportAfterNewTraffic",
      in: source
    )

    XCTAssertTrue(
      source.contains("max(Self.audioRelayRenewalLeadTime, 35)"),
      "Strict smoke audio renewal should start before the sender renewal margin so the viewer has a ready receive path."
    )
    XCTAssertTrue(
      renewalBody.contains(
        "let sameRelayAddress = skyBridgeIsSameRealtimeMediaRelayAddress(currentEndpoint, newEndpoint)"
      )
    )
    XCTAssertTrue(
      renewalBody.contains("if !requiresStrictAudioRelayRenewal,\n           sameRelayAddress,"),
      "Strict smoke validation must not rebind the live audio receive transport in place."
    )
    XCTAssertTrue(renewalBody.contains("reason=strict-make-before-break"))
    XCTAssertTrue(renewalBody.contains("\"probable\": \"strict-make-before-break\""))
    XCTAssertTrue(
      renewalBody.contains("let renewalTrafficCounter = SmokeAudioRelayTrafficCounter()"))
    XCTAssertTrue(renewalBody.contains("promoteSmokeAudioRelayTransportAfterNewTraffic("))
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
    XCTAssertTrue(failureBody.contains("SkyBridgeSmokeTraceWriter.appendStatus("))
    XCTAssertTrue(failureBody.contains("audioRxReceiverStartFailed"))
    XCTAssertTrue(failureBody.contains("SkyBridgeSmokeTraceWriter.appendMediaDiagnostic("))
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

    XCTAssertTrue(
      source.contains("private let streamDecodeStallRefreshMinimumInterval: TimeInterval = 3.0"))
    XCTAssertTrue(
      source.contains(
        "reason: \"decode-stall-reset\",\n                        minimumInterval: self.streamDecodeStallRefreshMinimumInterval"
      ))

    let hevcFailureBody = try sourceSlice(
      from: "case .failFastHEVC(let reason):",
      to: "case .reenableHEVCProbe:",
      in: source
    )
    XCTAssertTrue(
      hevcFailureBody.contains("await failFastRemoteDesktopRenderMainPath("),
      "Repeated HEVC failures must fail the render main path instead of closing the LAN transport and realtime audio receiver."
    )
    XCTAssertTrue(
      hevcFailureBody.contains("reason: \"hevc-main-path-failed: \\(reason)\"")
    )
    XCTAssertTrue(
      hevcFailureBody.contains("forceSyncFrameWait: true")
    )
    XCTAssertFalse(
      hevcFailureBody.contains("handleTransportFailure"),
      "HEVC render-path failures must not be propagated as transport failures."
    )
    XCTAssertFalse(
      hevcFailureBody.contains("pushViewerStreamConfiguration"),
      "HEVC fail-fast must not push a fallback stream configuration."
    )
  }

  func testSessionAuthorityLostStopsRemoteDesktopRetryLoops() throws {
    let source = try remoteDesktopManagerSource()

    XCTAssertTrue(
      source.contains("handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"stream-config\")"))
    XCTAssertTrue(
      source.contains(
        "handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"first-frame-watchdog\")"))
    XCTAssertTrue(
      source.contains(
        "handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"stream-config-ack-retry\")"))
    XCTAssertTrue(
      source.contains(
        "handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"audio-receiver-start\")"))
    XCTAssertTrue(
      source.contains(
        "handleCrossNetworkSessionAuthorityLostIfNeeded(source: \"stream-refresh:\\(reason)\")"))
    XCTAssertTrue(source.contains("event=sessionAuthorityLost"))
    XCTAssertTrue(source.contains("state = .error(\"sessionAuthorityLost\")"))
  }

  func testStreamConfigurationAckHookStaysCompileCompatibleUntilSharedProducerExists() throws {
    let managerSource = try remoteDesktopManagerSource()
    let typesSource = try remoteDesktopTypesSource()

    XCTAssertTrue(typesSource.contains("Compile-compatible future hook"))
    XCTAssertTrue(typesSource.contains("case streamConfigurationAck = \"streamConfigurationAck\""))
    XCTAssertTrue(managerSource.contains("case .streamConfigurationAck:"))
    XCTAssertTrue(managerSource.contains("handleStreamConfigurationAck"))
    XCTAssertTrue(managerSource.contains("lastAcknowledgedMediaAudioEndpointPresent = ack.audioEndpointPresent"))
    XCTAssertTrue(managerSource.contains("audioEndpointAck=\\(lastAcknowledgedMediaAudioEndpointPresent)"))
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

  private func signedV7ConnectLink(
    deviceId: String,
    protocolPublicKeyBytes: Data,
    protocolPublicKeyFingerprint: String,
    signingKey: Curve25519.Signing.PrivateKey
  ) throws -> String {
    let kemPublicKey = Data(repeating: 0x42, count: 1216)
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    let unsigned = TestDynamicConnectQR(
      v: 7,
      s: "test-session-\(UUID().uuidString)",
      q: "test-bootstrap-\(UUID().uuidString)",
      r: SkyBridgeServerConfig.signalingServerURL,
      d: deviceId,
      n: "Stateful QR Mac",
      y: "macOS",
      o: "macOS 26.5",
      c: ["cross-network", "p2p"],
      a: ProtocolSigningAlgorithm.ed25519.rawValue,
      k: Self.base64URLEncodedString(protocolPublicKeyBytes),
      f: protocolPublicKeyFingerprint,
      m: [
        TestDynamicConnectQR.KEMKey(
          w: CryptoSuite.xwing.wireId,
          p: Self.base64URLEncodedString(kemPublicKey)
        )
      ],
      g: nil,
      t: timestampMs,
      e: timestampMs + 300_000
    )
    let signature = try signingKey.signature(
      for: canonicalQRCodePayload(
        qr: unsigned,
        protocolPublicKeyBytes: protocolPublicKeyBytes,
        kemPublicKeys: [(CryptoSuite.xwing.wireId, kemPublicKey)]
      ))
    let signed = TestDynamicConnectQR(
      v: unsigned.v,
      s: unsigned.s,
      q: unsigned.q,
      r: unsigned.r,
      d: unsigned.d,
      n: unsigned.n,
      y: unsigned.y,
      o: unsigned.o,
      c: unsigned.c,
      a: unsigned.a,
      k: unsigned.k,
      f: unsigned.f,
      m: unsigned.m,
      g: Self.base64URLEncodedString(signature),
      t: unsigned.t,
      e: unsigned.e
    )
    let data = try JSONEncoder().encode(signed)
    return "skybridge://connect/\(Self.base64URLEncodedString(data))"
  }

  private func canonicalQRCodePayload(
    qr: TestDynamicConnectQR,
    protocolPublicKeyBytes: Data,
    kemPublicKeys: [(wireId: UInt16, publicKey: Data)]
  ) -> Data {
    var data = Data()

    func appendUInt16(_ value: UInt16) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    func appendUInt32(_ value: UInt32) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    func appendInt64(_ value: Int64) {
      var littleEndian = value.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    func appendString(_ value: String) {
      let bytes = Data(value.precomposedStringWithCanonicalMapping.utf8)
      appendUInt32(UInt32(bytes.count))
      data.append(bytes)
    }

    func appendData(_ value: Data) {
      appendUInt32(UInt32(value.count))
      data.append(value)
    }

    appendUInt16(UInt16(max(0, qr.v)))
    appendString(qr.s)
    appendString(qr.q)
    appendInt64(qr.e)
    appendString(qr.r)
    appendString(qr.d)
    appendString(qr.n)
    appendString(qr.y)
    appendString(qr.o)
    appendUInt32(UInt32(qr.c.count))
    for capability in qr.c {
      appendString(capability)
    }
    appendString(qr.a)
    appendData(protocolPublicKeyBytes)
    appendString(qr.f)
    appendUInt32(UInt32(kemPublicKeys.count))
    for key in kemPublicKeys.sorted(by: { $0.wireId < $1.wireId }) {
      appendUInt16(key.wireId)
      appendData(key.publicKey)
    }
    appendInt64(qr.t)
    return data
  }

  private func protocolFingerprint(
    algorithm: ProtocolSigningAlgorithm,
    publicKeyBytes: Data
  ) -> String {
    let tagBytes = Array(algorithm.rawValue.utf8)
    var data = Data()
    var tagLength = UInt16(tagBytes.count).littleEndian
    withUnsafeBytes(of: &tagLength) { data.append(contentsOf: $0) }
    data.append(contentsOf: tagBytes)
    var keyLength = UInt32(publicKeyBytes.count).littleEndian
    withUnsafeBytes(of: &keyLength) { data.append(contentsOf: $0) }
    data.append(publicKeyBytes)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func base64URLEncodedString(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private struct TestDynamicConnectQR: Codable {
    struct KEMKey: Codable {
      let w: UInt16
      let p: String
    }

    let v: Int
    let s: String
    let q: String
    let r: String
    let d: String
    let n: String
    let y: String
    let o: String
    let c: [String]
    let a: String
    let k: String
    let f: String
    let m: [KEMKey]?
    let g: String?
    let t: Int64
    let e: Int64
  }

  func testLocalP2PSmokeRejectsQRBootstrapBeforeTrustImport() throws {
    let appSource = try skyBridgeCompassAppSource()
    let managerSource = try crossNetworkWebRTCManagerSource()
    let smokeImport = try sourceSlice(
      from: "private func rejectOOBQRBootstrapIfRequested",
      to: "private func summarizeDiscoveredDevices",
      in: appSource
    )
    XCTAssertTrue(smokeImport.contains("qr_bootstrap_removed_use_pib1_sas_then_skr1"))
    XCTAssertFalse(smokeImport.contains("importVerifiedConnectLinkTrust"))
    XCTAssertFalse(smokeImport.contains("qr-bootstrap trusted source=verified_qr"))
    XCTAssertFalse(
      smokeImport.contains("connect(fromScannedString"),
      "The file-transfer smoke QR bootstrap must fail before importing trust or starting WebRTC."
    )

    let trustImport = try sourceSlice(
      from: "public func importVerifiedConnectLinkTrust",
      to: "#if DEBUG",
      in: managerSource
    )
    XCTAssertTrue(trustImport.contains("throw Self.p2pKEMQRCodeBootstrapDisabledError()"))
    XCTAssertFalse(trustImport.contains("verifyAndPersistSkybridgeConnectLink"))
    XCTAssertFalse(trustImport.contains("requestAdmissionLease"))
    XCTAssertFalse(trustImport.contains("redeemSession"))
  }

  func testDashboardScannedConnectLinkDoesNotImportP2PKEMTrust() throws {
    let dashboardSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/Dashboard/DashboardView.swift"
    )
    let handler = try sourceSlice(
      from: "private func handleScannedConnectLink",
      to: "// MARK: - Live Transfer Banner View",
      in: dashboardSource
    )

    XCTAssertTrue(handler.contains("connect(fromScannedString: link)"))
    XCTAssertFalse(handler.contains("importVerifiedConnectLinkTrust"))
    XCTAssertFalse(handler.contains("isNotP2PKEMBootstrapImportError"))
    XCTAssertFalse(handler.contains("P2P KEM 引导信任"))
  }

  func testDashboardRemovesLocalP2PQRCodePairingFlow() throws {
    let dashboardSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/Dashboard/DashboardView.swift"
    )
    let p2pConnectionViewSource = try repositoryScriptSource(
      "Sources/SkyBridgeCore/UI/P2PConnectionView.swift"
    )

    XCTAssertTrue(dashboardSource.contains("本地 P2P 二维码引导已移除"))
    XCTAssertTrue(dashboardSource.contains("跨网连接"))
    XCTAssertFalse(dashboardSource.contains("private func handleQRCodeScan"))
    XCTAssertFalse(dashboardSource.contains("QRCodePairingConfirmCard"))
    XCTAssertFalse(dashboardSource.contains("onScanPairingData"))
    XCTAssertFalse(dashboardSource.contains("case p2p"))
    XCTAssertFalse(dashboardSource.contains("generateP2PQRCode"))
    XCTAssertFalse(dashboardSource.contains("createAuthenticatedPairingData"))
    XCTAssertFalse(dashboardSource.contains("同一网络下的 iPhone / iPad / Mac 扫描此二维码后直接连接"))

    XCTAssertFalse(p2pConnectionViewSource.contains("showingQRCodeScanner"))
    XCTAssertFalse(p2pConnectionViewSource.contains("showQRCodeScanner"))
    XCTAssertFalse(p2pConnectionViewSource.contains("parseP2PDevice(fromQRCode"))
    XCTAssertFalse(p2pConnectionViewSource.contains("Text(\"扫码连接\")"))
  }

  func testVerifiedQRCodeDoesNotPersistKEMTrustMaterial() throws {
    let managerSource = try crossNetworkWebRTCManagerSource()
    let parser = try sourceSlice(
      from: "private func verifyAndPersistSkybridgeConnectLink",
      to: "private func parseSkybridgeConnectLink",
      in: managerSource
    )
    XCTAssertTrue(parser.contains("logVerifiedQRCodeKEMIgnored(qr)"))
    XCTAssertFalse(parser.contains("persistVerifiedQRCodeKEMTrust"))

    let logger = try sourceSlice(
      from: "private func logVerifiedQRCodeKEMIgnored",
      to: "private func connect(from qr",
      in: managerSource
    )
    XCTAssertTrue(logger.contains("不会导入 KEM trust"))
    XCTAssertFalse(logger.contains("KEMTrustStore.shared.upsert"))
    XCTAssertFalse(logger.contains("ProtocolIdentityTrustStore.shared.upsert"))
    XCTAssertFalse(logger.contains("TrustedDeviceStore.shared.trustResolvedPeer"))
  }

  @MainActor
  func testVerifiedV7QRCodeWithKEMDoesNotMutateTrustStores() async throws {
    let deviceId = "id:qr-stateful-mac-1"
    await KEMTrustStore.shared.clearForTesting()
    await ProtocolIdentityTrustStore.shared.clearForTesting()
    TrustedDeviceStore.shared.clearAll()

    let signingKey = Curve25519.Signing.PrivateKey()
    let publicKey = signingKey.publicKey.rawRepresentation
    let fingerprint = protocolFingerprint(
      algorithm: .ed25519,
      publicKeyBytes: publicKey
    )
    let link = try signedV7ConnectLink(
      deviceId: deviceId,
      protocolPublicKeyBytes: publicKey,
      protocolPublicKeyFingerprint: fingerprint,
      signingKey: signingKey
    )

    let verified = try await CrossNetworkWebRTCManager.instance
      .testOnlyVerifyConnectLinkWithoutRedeem(fromScannedString: link)
    let storedKEMKeys = await KEMTrustStore.shared.kemPublicKeys(forAny: [deviceId])
    let signedRefreshEvidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: [deviceId])
    let storedFingerprints = await ProtocolIdentityTrustStore.shared.trustedFingerprints(forAny: [
      deviceId
    ])

    XCTAssertEqual(verified.deviceID, deviceId)
    XCTAssertEqual(verified.protocolPublicKeyFingerprint, fingerprint)
    XCTAssertEqual(verified.kemSuiteWireIDs, [CryptoSuite.xwing.wireId])
    XCTAssertTrue(storedKEMKeys.isEmpty)
    XCTAssertNil(signedRefreshEvidence)
    XCTAssertTrue(storedFingerprints.isEmpty)
    XCTAssertTrue(TrustedDeviceStore.shared.trustedDevices.isEmpty)
    XCTAssertFalse(TrustedDeviceStore.shared.isTrusted(deviceId: deviceId))
    XCTAssertNil(
      TrustedDeviceStore.shared.currentPathTrustRecord(
        fingerprint: fingerprint,
        matchingDeviceId: deviceId
      ))

    await KEMTrustStore.shared.clearForTesting()
    await ProtocolIdentityTrustStore.shared.clearForTesting()
    TrustedDeviceStore.shared.clearAll()
  }

  func testRemoteDesktopSelectionOverlayIsDiagnosticOnlyByDefault() throws {
    let source = try remoteDesktopViewSource()

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

  func testMacOSReleaseReadinessRunsRustCLIQualityGates() throws {
    let scriptSource = try repositoryScriptSource("Scripts/check_macos_release_readiness.sh")
    let packagePolicySource = try repositoryScriptSource("Scripts/package_build_policy.sh")
    let buildDMGSource = try repositoryScriptSource("Scripts/build_dmg.sh")

    XCTAssertTrue(scriptSource.contains("--p2p-remote-artifact-dir <path>"))
    XCTAssertTrue(scriptSource.contains("--file-transfer-artifact-dir <path>"))
    XCTAssertTrue(
      scriptSource.contains(
        "CLI_COVERAGE_MIN_PERCENT=\"${SKYBRIDGE_RELEASE_GATE_COVERAGE_MIN_PERCENT:-88}\""))
    XCTAssertTrue(scriptSource.contains("run_skybridge_cli check coverage"))
    XCTAssertTrue(scriptSource.contains("--kind operator-check-surface"))
    XCTAssertTrue(scriptSource.contains("--min-percent \"${CLI_COVERAGE_MIN_PERCENT}\""))
    XCTAssertTrue(scriptSource.contains("run_skybridge_cli check performance"))
    XCTAssertTrue(scriptSource.contains("--kind p2p-remote"))
    XCTAssertTrue(scriptSource.contains("--kind file-transfer"))
    XCTAssertTrue(
      scriptSource.contains("missing --p2p-remote-artifact-dir for release performance gate"))
    XCTAssertTrue(
      scriptSource.contains("missing --file-transfer-artifact-dir for release performance gate"))
    XCTAssertTrue(scriptSource.contains("run_skybridge_cli check memory"))
    XCTAssertTrue(scriptSource.contains("--pid \"${pid}\""))
    XCTAssertTrue(
      scriptSource.contains(
        "launch smoke cannot be skipped while the memory leak scan gate is enabled"))
    XCTAssertTrue(
      scriptSource.contains(
        "skybridge_assert_no_smoke_auto_approval_for_release_context \"macOS release readiness\""))
    XCTAssertTrue(
      packagePolicySource.contains("skybridge_assert_no_smoke_auto_approval_for_release_context()"))
    XCTAssertTrue(packagePolicySource.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-0"))
    XCTAssertTrue(
      packagePolicySource.contains(
        "SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 is smoke-only and is forbidden for ${release_context}"
      ))
    XCTAssertTrue(
      packagePolicySource.contains(
        "skybridge_assert_no_smoke_auto_approval_for_release_context \"release_dmg packaging\""))
    XCTAssertTrue(
      buildDMGSource.contains(
        "skybridge_assert_no_smoke_auto_approval_for_release_context \"release_dmg build\""))
  }

  func testP2PRealDeviceSmokeRequiresVisibleRemoteDesktopView() throws {
    let appSource = try skyBridgeCompassAppSource()
    let authSource = try authenticationManagerSource()
    let remoteViewSource = try remoteDesktopViewSource()
    let scriptSource = try repositoryScriptSource("Scripts/run_real_device_p2p_remote_smoke.sh")

    XCTAssertTrue(authSource.contains("shouldAutoAuthenticateAsGuestForP2PSmoke"))
    XCTAssertTrue(
      authSource.contains("environment[\"SKYBRIDGE_SMOKE_ROLE\"] == \"ios-p2p-client\""))
    XCTAssertTrue(authSource.contains("environment[\"SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB\"] == \"1\""))
    XCTAssertTrue(
      authSource.contains("environment[\"SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW\"] == \"1\""))
    XCTAssertTrue(authSource.contains("applyP2PSmokeGuestSession()"))

    XCTAssertTrue(remoteViewSource.contains("shouldAutoConnectP2PSmoke"))
    XCTAssertTrue(remoteViewSource.contains("attemptAutoConnectP2PSmoke()"))
    XCTAssertTrue(remoteViewSource.contains("connectToDevice(connection)"))

    XCTAssertTrue(appSource.contains("requiresVisibleRemoteView"))
    XCTAssertTrue(appSource.contains("remote-desktop ui-gate waiting-for-RemoteDesktopView"))
    XCTAssertTrue(appSource.contains("snapshot.hasActivePresentationOwner"))
    XCTAssertTrue(
      appSource.contains(
        "uiSurface=\\(snapshot.hasActivePresentationOwner ? \"remoteDesktopView\" : \"none\")"))
    XCTAssertTrue(appSource.contains("requiresExtremeMediaValidation ? 59.0 : 30.0"))
    XCTAssertTrue(appSource.contains("snapshot.displayedFramesInStream > 0"))
    XCTAssertTrue(appSource.contains("windowDisplayedFPS >= minFPS"))
    XCTAssertTrue(appSource.contains("windowReceivedFPS >= minFPS"))
    XCTAssertTrue(
      appSource.contains(
        "let canStartRemoteDesktopSmoke = expectsRemoteDesktopSmoke && hasExpectedPQCHandshake"))
    XCTAssertTrue(appSource.contains("passMinTwoSecondDisplayedFrames"))
    XCTAssertTrue(appSource.contains("twoSecondRequiredFrames=\\(twoSecondFrameRequirement)"))
    XCTAssertTrue(
      appSource.contains("let currentTwoSecondCadencePass = currentTwoSecondCombinedCadencePass"))
    XCTAssertTrue(
      appSource.contains("current2sCadencePass=\\(currentTwoSecondCadencePass ? 1 : 0)"))
    XCTAssertTrue(
      appSource.contains("current2sRxCadencePass=\\(currentTwoSecondRxCadencePass ? 1 : 0)"))
    XCTAssertTrue(
      appSource.contains("last2sSocketRxFrames=\\(snapshot.socketArrivalFramesInLastTwoSeconds)"))
    XCTAssertTrue(
      appSource.contains("last2sSourceFrames=\\(snapshot.sourceCadenceFramesInLastTwoSeconds)"))
    XCTAssertTrue(
      appSource.contains(
        "last2sMetalDeliveryFrames=\\(snapshot.metalDeliveryFramesInLastTwoSeconds)"))
    XCTAssertTrue(appSource.contains("remote-desktop pass-window-reset reason=cadence"))
    XCTAssertTrue(appSource.contains("let metalFrameAgeBudgetMs = 100"))
    XCTAssertTrue(appSource.contains("&& metalLatencyPass"))
    XCTAssertTrue(
      appSource.contains("remote-desktop pass-window-reset reason=\\(passWindowResetReason)"))
    XCTAssertTrue(
      appSource.contains(
        "metalFrameAge2sMs=\\(snapshot.metalFrameAgeMaxInLastTwoSecondsMs.map(String.init) ?? \"-\")"
      ))
    XCTAssertTrue(appSource.contains("metalLatencyPass=\\(metalLatencyPass ? 1 : 0)"))
    XCTAssertTrue(
      appSource.contains("rollingDisplayCadencePass=\\(rollingDisplayCadencePass ? 1 : 0)"))
    XCTAssertTrue(appSource.contains("rollingRxCadencePass=\\(rollingRxCadencePass ? 1 : 0)"))
    XCTAssertTrue(appSource.contains("let rollingCadencePass = rollingCombinedCadencePass"))
    XCTAssertTrue(appSource.contains("&& rollingCombinedCadencePass"))
    XCTAssertTrue(
      appSource.contains("windowSeconds >= 2.0 && !currentTwoSecondCombinedCadencePass"))
    XCTAssertTrue(appSource.contains("rollingCadencePass=\\(rollingCadencePass ? 1 : 0)"))
    XCTAssertTrue(appSource.contains("windowFPS=\\(String(format: \"%.1f\", windowDisplayedFPS))"))

    XCTAssertTrue(scriptSource.contains("SMOKE_MIN_FPS=\"${SKYBRIDGE_SMOKE_MIN_FPS:-59}\""))
    XCTAssertTrue(
      scriptSource.contains(
        "IOS_LAUNCH_TIMEOUT_SECONDS=\"${SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS:-$((SMOKE_TIMEOUT_SECONDS + 60))}\""
      ))
    XCTAssertTrue(scriptSource.contains("Unsupported SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS"))
    XCTAssertTrue(
      scriptSource.contains("PQC_TRUST_MODE=\"${SKYBRIDGE_SMOKE_PQC_TRUST_MODE:-injected}\""))
    XCTAssertTrue(
      scriptSource.contains(
        "SMOKE_REQUIRE_SIGNED_KEM_REFRESH=\"${SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH:-1}\""))
    XCTAssertTrue(
      scriptSource.contains(
        "SMOKE_FORCE_SIGNED_KEM_REFRESH=\"${SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH:-$SMOKE_REQUIRE_SIGNED_KEM_REFRESH}\""
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "SMOKE_AUTO_APPROVE_PAIRING=\"${SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-1}\""))
    XCTAssertTrue(
      scriptSource.contains(
        "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH=\"$SMOKE_REQUIRE_SIGNED_KEM_REFRESH\""))
    XCTAssertTrue(
      scriptSource.contains(
        "SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH=\"$SMOKE_FORCE_SIGNED_KEM_REFRESH\""))
    XCTAssertTrue(
      scriptSource.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=\"$SMOKE_AUTO_APPROVE_PAIRING\""))
    XCTAssertTrue(scriptSource.contains("\"SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH\""))
    XCTAssertTrue(scriptSource.contains("\"SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH\""))
    XCTAssertTrue(scriptSource.contains("\"SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING\""))
    XCTAssertTrue(scriptSource.contains("\"SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB\": \"1\""))
    XCTAssertTrue(scriptSource.contains("\"SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW\": \"1\""))
    XCTAssertTrue(
      scriptSource.contains("wait_for_ios_status_pattern 'PIB-1 protocol identity binding request:")
    )
    XCTAssertTrue(
      scriptSource.contains(
        "wait_for_file_pattern \"$HOST_STATUS\" 'PIB-1 protocol identity binding served:"))
    XCTAssertTrue(
      scriptSource.contains(
        "wait_for_ios_status_pattern 'PIB-1 protocol identity binding signature verified:"))
    XCTAssertTrue(
      scriptSource.contains("wait_for_ios_status_pattern 'PIB-1 protocol identity binding pinned:"))
    XCTAssertTrue(
      scriptSource.contains("wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh request:"))
    XCTAssertTrue(
      scriptSource.contains(
        "wait_for_file_pattern \"$HOST_STATUS\" 'SKR-1 signed LAN KEM refresh served:"))
    XCTAssertTrue(
      scriptSource.contains(
        "wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh (smoke-evidence:"))
    XCTAssertTrue(
      scriptSource.contains(
        "verified and imported: .*suites=.*X-Wing.*pinnedProtocolIdentity=1 .*signature=verified .*requestHash=bound"))
    XCTAssertTrue(
      appSource.contains(
        "try await assertSignedKEMRefreshIfRequired(for: target, reporter: reporter)"))
    XCTAssertTrue(scriptSource.contains("HOST_REMOTE_SMOKE_FAILURE_PATTERN"))
    XCTAssertTrue(
      scriptSource.contains("failed stage=(identity|handshake|remote-desktop|remote-control|media)")
    )
    XCTAssertTrue(scriptSource.contains("suite_rejected_unknown"))
    XCTAssertTrue(scriptSource.contains("rollingDisplayCadencePass"))
    XCTAssertTrue(scriptSource.contains("iOS rolling display cadence did not pass"))
    XCTAssertTrue(scriptSource.contains("min2sRxFrames"))
    XCTAssertTrue(scriptSource.contains("iOS worst two-second receive cadence below requirement"))
    XCTAssertTrue(scriptSource.contains("last2sSourceFrames"))
    XCTAssertTrue(scriptSource.contains("last2sMetalDeliveryFrames"))
    XCTAssertTrue(scriptSource.contains("last2sSocketRxFrames"))
    XCTAssertTrue(scriptSource.contains("source-cadence+metal-delivery"))
    XCTAssertTrue(scriptSource.contains("rollingRxCadencePass"))
    XCTAssertTrue(scriptSource.contains("iOS rolling receive cadence did not pass"))
    XCTAssertTrue(scriptSource.contains("rollingCombinedCadencePass"))
    XCTAssertTrue(
      scriptSource.contains("iOS rolling combined display/receive cadence did not pass"))
    XCTAssertTrue(scriptSource.contains("wireId=0x0000"))
    XCTAssertTrue(scriptSource.contains("unknown suite"))
    XCTAssertTrue(scriptSource.contains("signed LAN KEM refresh rejected"))
    XCTAssertTrue(scriptSource.contains("PIB-1 protocol identity binding failed"))
    XCTAssertTrue(scriptSource.contains("lifecycle=identity-oob>failed"))
    XCTAssertTrue(scriptSource.contains("lifecycle=missing-kem>failed"))
    XCTAssertTrue(scriptSource.contains("render-main-path-failed"))
    XCTAssertTrue(scriptSource.contains("strict-media-failed"))
    XCTAssertTrue(scriptSource.contains("mac-sck-encode-failed .*capturesAudio=false"))
    XCTAssertFalse(
      scriptSource.contains(
        "HOST_REMOTE_SMOKE_FAILURE_PATTERN=\"${COMMON_REMOTE_SMOKE_FAILURE_PATTERN}|failed stage=|")
    )
    XCTAssertFalse(scriptSource.contains("mac-remote-frame-tx .*dropped=[1-9][0-9]*"))
    XCTAssertTrue(scriptSource.contains("validate_remote_desktop_performance_window"))
    XCTAssertTrue(scriptSource.contains("validate_remote_desktop_route_evidence"))
    XCTAssertTrue(scriptSource.contains("macOS host process exited while waiting for"))
    XCTAssertTrue(scriptSource.contains("failed stage=mac-host phase=process-exited"))
    XCTAssertTrue(scriptSource.contains("HOST_HANDSHAKE_PATTERN"))
    XCTAssertTrue(scriptSource.contains("mac remote established .*suite=${EXPECTED_TARGET_SUITE}"))
    XCTAssertTrue(scriptSource.contains("IOS_STATUS_APP_CACHE_LOCAL"))
    XCTAssertTrue(scriptSource.contains("IOS_STATUS_CONSOLE_SNAPSHOT"))
    XCTAssertTrue(scriptSource.contains("# source=devicectl-console"))
    XCTAssertTrue(scriptSource.contains("# source=app-cache"))
    XCTAssertTrue(scriptSource.contains("smoke-final result=success validated=1"))
    XCTAssertTrue(scriptSource.contains("=([^\\s]+)"))
    XCTAssertTrue(scriptSource.contains("return match.group(1).strip() if match else None"))
    XCTAssertTrue(scriptSource.contains("(?:\\.\\d{1,9})?"))
    XCTAssertTrue(scriptSource.contains("def parse_console_timestamp(line, anchor_utc):"))
    XCTAssertTrue(scriptSource.contains("def parse_window_timestamp(line, anchor_utc):"))
    XCTAssertTrue(scriptSource.contains("parse_window_timestamp(line, pass_time)"))
    XCTAssertTrue(scriptSource.contains("pass_candidates = ["))
    XCTAssertTrue(scriptSource.contains("max(pass_candidates, key=lambda item: item[1])"))
    XCTAssertTrue(scriptSource.contains("start_index <= idx <= pass_index"))
    XCTAssertTrue(scriptSource.contains("start_time <= timestamp <= pass_time_upper"))
    XCTAssertFalse(scriptSource.contains("window_lines = ios_lines[start_index:pass_index + 1]"))
    XCTAssertTrue(scriptSource.contains("iOS aggregate display windowFPS below"))
    XCTAssertTrue(scriptSource.contains("Mac HEVC aggregate encodedFPS below"))
    XCTAssertTrue(
      scriptSource.contains("no Mac HEVC encoder configuration telemetry before final pass"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac HEVC encoder short-window burst cap drifted from the single-chunk transport budget with bounded headroom"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac HEVC encoder short-window burst cap duration drifted from the single-frame transport budget"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac HEVC encoder DataRateLimits were not accepted and read back by VideoToolbox"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote tx emitted multi-chunk HEVC frames inside final pass window"))
    XCTAssertTrue(scriptSource.contains("Mac remote harmful backpressure was nonzero"))
    XCTAssertTrue(scriptSource.contains("Metal aggregate displayFPS below"))
    XCTAssertTrue(scriptSource.contains("Metal aggregate submittedFPS exceeded strict target"))
    XCTAssertTrue(scriptSource.contains("Metal aggregate displayFPS exceeded strict target"))
    XCTAssertTrue(scriptSource.contains("Metal aggregate inputFPS below"))
    XCTAssertTrue(scriptSource.contains("Metal CI fallback rendered frames were nonzero"))
    XCTAssertTrue(scriptSource.contains("Metal direct BGRA frames did not match submitted frames"))
    XCTAssertTrue(scriptSource.contains("iOS worst two-second display cadence below requirement"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS receive cadence did not expose source-cadence plus Metal-delivery evidence"))
    XCTAssertTrue(
      scriptSource.contains("iOS audio playback did not progress inside final pass window"))
    XCTAssertTrue(scriptSource.contains("ios-lan-remote-rx "))
    XCTAssertTrue(scriptSource.contains("iOS LAN receive did not use sbc2-chunked-v1"))
    XCTAssertTrue(scriptSource.contains("stream-parser-low-latency-256k-4frame-6ms-drain-budget"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN receive did not prove low-latency read-ahead and bounded drain"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN parser drain budget samples did not cover every telemetry line"))
    XCTAssertTrue(scriptSource.contains("iOS LAN parser drain budget exceeded strict 6ms bound"))
    XCTAssertTrue(scriptSource.contains("iOS LAN parser drain exceeded strict budget inside final pass window"))
    XCTAssertTrue(scriptSource.contains("iOS LAN parser drain hit the strict 6ms budget inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains("iOS LAN screen delivery samples did not cover every telemetry line"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN screen delivery was not strict decoded-to-Metal 60Hz feed for every telemetry line"
      ))
    XCTAssertTrue(scriptSource.contains("iOS LAN sampled screen delivery FPS far below final pass marker"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN direct screen delivery queued frames instead of immediate Metal feed"))
    XCTAssertTrue(
      scriptSource.contains("iOS LAN screen delivery delay exceeded 100ms inside final pass window")
    )
    XCTAssertTrue(scriptSource.contains("strict_ios_decode_feed_mode = \"ordered-vt-decode-metal-direct\""))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_feed_samples != lan_rx_count"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN decode feed was not ordered VideoToolbox-to-Metal direct for every telemetry line"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_attempted += int_metric(line, \"decodeAttempted\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_accepted += int_metric(line, \"decodeAccepted\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_dropped += int_metric(line, \"decodeDropped\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_pending_max = max(lan_rx_decode_pending_max, int_metric(line, \"decodePendingMax\"))"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_in_flight_max = max(lan_rx_decode_in_flight_max, int_metric(line, \"decodeInFlightMax\"))"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_waiting_sync += int_metric(line, \"decodeWaitingSyncSamples\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_decode_resets += int_metric(line, \"decodeResets\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN receive did not report SBC2 screen frames inside final pass window"))
    XCTAssertTrue(scriptSource.contains("iOS LAN receive reported fewer SBC2 chunks than frames"))
    XCTAssertTrue(scriptSource.contains("lan_rx_sbc2_frames += int_metric(line, \"sbc2Frames\")"))
    XCTAssertTrue(scriptSource.contains("lan_rx_sample_ms += int_metric(line, \"sampleMs\")"))
    XCTAssertTrue(scriptSource.contains("lan_rx_raw_chunks += int_metric(line, \"rawChunks\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_screen_delivery_attempted += int_metric(line, \"screenDeliveryAttempted\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_screen_delivery_delivered += int_metric(line, \"screenDeliveryDelivered\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_screen_delivery_backpressure += int_metric(line, \"screenDeliveryBackpressure\")"))
    XCTAssertTrue(
      scriptSource.contains("iOS LAN screen delivery accepted more frames than attempted"))
    XCTAssertTrue(
      scriptSource.contains(
        "lan_rx_screen_delivery_queue_depth_max = max(lan_rx_screen_delivery_queue_depth_max, int_metric(line, \"screenDeliveryQueueDepthMax\"))"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN source-to-read latency exceeded 100ms inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN raw receive chunk gap exceeded 12-frame bounded receive budget inside final pass window"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN raw receive MainActor handoff exceeded 100ms inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains("iOS LAN parser drain submitted too many complete screen frames"))
    XCTAssertTrue(scriptSource.contains("remote route validation failed"))
    XCTAssertTrue(
      scriptSource.contains(
        "no routable LAN direct or Bonjour infrastructure route with peerToPeer=false"))
    XCTAssertTrue(scriptSource.contains("no ios-lan-remote-route-ready evidence"))
    XCTAssertTrue(
      scriptSource.contains(
        "no verified LAN hostPort route-ready evidence with resolvedAddressClass=lan-direct resolvedPeerToPeer=false"
      ))
    XCTAssertTrue(scriptSource.contains("iOS LAN ready route was not verified routable hostPort"))
    XCTAssertTrue(scriptSource.contains("iOS LAN route used link-local/peer-to-peer path"))
    XCTAssertTrue(scriptSource.contains("macOS remote tx peer was link-local/peer-to-peer"))
    XCTAssertTrue(
      scriptSource.contains(
        "\"mac remote\" in line or \"mac-remote\" in line or \"mac-stream-config\" in line"))
    XCTAssertTrue(scriptSource.contains("iOS LAN sampled receive screenFPS far below final pass marker"))
    XCTAssertTrue(scriptSource.contains("maxGapMs"))
    XCTAssertTrue(scriptSource.contains("lanSampledScreenFPS="))
    XCTAssertTrue(scriptSource.contains("lanScreenDeliveryFPS="))
    XCTAssertTrue(
      scriptSource.contains("iOS core media gate fell out of pass state inside final window"))
    XCTAssertTrue(scriptSource.contains("metal_sample_ms += int_metric(line, \"sampleMs\")"))
    XCTAssertTrue(
      scriptSource.contains("metal_draw_callbacks += int_metric(line, \"drawCallbacks\")"))
    XCTAssertTrue(
      scriptSource.contains("metal_queue_backpressure += int_metric(line, \"queueBackpressure\")"))
    XCTAssertTrue(scriptSource.contains("Metal aggregate drawCallbackFPS below"))
    XCTAssertTrue(
      scriptSource.contains("Metal aggregate drawCallbackFPS exceeded native pump budget"))
    XCTAssertTrue(scriptSource.contains("max_allowed_metal_coalesced = 0"))
    XCTAssertTrue(
      scriptSource.contains(
        "Metal realtime coalescedBeforeDraw was nonzero inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains(
        "Metal realtime replacement evidence did not match coalescedBeforeDraw inside final pass window"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Metal realtime replacement was nonzero without structured replacement reason inside final pass window"
      ))
    XCTAssertTrue(scriptSource.contains("Metal manualDraw was nonzero inside final pass window"))
    XCTAssertTrue(scriptSource.contains("\nif metal_queue_capacity_max > 3:"))
    XCTAssertTrue(
      scriptSource.contains(
        "Metal queueCapacity exceeded bounded 3-frame realtime render queue inside final pass window"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Metal queueDepthMax exceeded bounded 3-frame realtime render queue inside final pass window"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Metal render telemetry did not report frameAgeMs evidence inside final pass window"))
    XCTAssertTrue(scriptSource.contains("Metal frameAgeMs exceeded 100ms inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains("Metal display driver is not the strict MTKView native path"))
    XCTAssertTrue(
      scriptSource.contains(
        "Metal display cadence is not the strict 60Hz MTKView native-vsync path"))
    XCTAssertTrue(scriptSource.contains("metalDisplayLinkPumpFPS="))
    XCTAssertTrue(scriptSource.contains("metalInputFPS="))
    XCTAssertTrue(scriptSource.contains("metalQueueBackpressure="))
    XCTAssertTrue(scriptSource.contains("lanScreenDeliveryAttempted="))
    XCTAssertTrue(scriptSource.contains("lanScreenDeliveryBackpressure="))
    XCTAssertTrue(scriptSource.contains("tx_sample_ms += int_metric(line, \"sampleMs\")"))
    XCTAssertTrue(scriptSource.contains("tx_raw_backpressure += line_raw_backpressure"))
    XCTAssertTrue(scriptSource.contains("tx_ordered_throttle += line_ordered_throttle"))
    XCTAssertTrue(scriptSource.contains("Mac remote queue backlog was nonzero"))
    XCTAssertTrue(scriptSource.contains("Mac remote tx did not use sbc2-chunked-v1"))
    XCTAssertTrue(
      scriptSource.contains("Mac remote tx did not use the strict DispatchSource writer clock"))
    XCTAssertTrue(scriptSource.contains("tx_writer_clock_ok < tx_count"))
    XCTAssertTrue(scriptSource.contains("Mac remote tx accepted non-SBC2 screen frames"))
    XCTAssertTrue(scriptSource.contains("Mac remote tx reported fewer SBC2 chunks than frames"))
    XCTAssertTrue(scriptSource.contains("Mac remote tx maxChunksPerFrame was invalid"))
    XCTAssertTrue(scriptSource.contains("tx_chunked_frames += int_metric(line, \"chunkedFrames\")"))
    XCTAssertTrue(
      scriptSource.contains(
        "tx_max_chunks_per_frame = max(tx_max_chunks_per_frame, int_metric(line, \"maxChunksPerFrame\"))"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentBacklogLimit drifted from the strict byte-bounded chunked contentProcessed pipeline"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentBacklogByteLimit drifted from the bounded chunked contentProcessed pipeline"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac HEVC SCK cadence recovery limit was not the bounded strict producer path"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac HEVC SCK display cadence exceeded bounded producer recovery inside final pass window"))
    XCTAssertFalse(scriptSource.contains("SKYBRIDGE_SMOKE_REMOTE_ANIMATION=1"))
    XCTAssertTrue(scriptSource.contains("MAC_APP_BUNDLE=\"$ARTIFACT_DIR/LocalLanInteropHost.app\""))
    XCTAssertTrue(scriptSource.contains("prepare_macos_smoke_host_app_bundle()"))
    XCTAssertTrue(scriptSource.contains("start_macos_smoke_host()"))
    XCTAssertTrue(scriptSource.contains("/usr/bin/open"))
    XCTAssertTrue(scriptSource.contains("register_macos_smoke_host_app_bundle()"))
    XCTAssertTrue(scriptSource.contains("LocalLanInteropHostSmoke.${RUN_ID}"))
    XCTAssertTrue(scriptSource.contains("fallback=direct-app-binary"))
    XCTAssertTrue(scriptSource.contains("SKYBRIDGE_SMOKE_ROLE=mac-smoke-source"))
    XCTAssertTrue(scriptSource.contains("windowOcclusionVisible=1"))
    XCTAssertTrue(scriptSource.contains("local source_webrtc_framework=\"$ROOT_DIR/.build/debug/WebRTC.framework\""))
    XCTAssertTrue(scriptSource.contains("cp -R \"$source_webrtc_framework\" \"$macos_dir/WebRTC.framework\""))
    XCTAssertTrue(scriptSource.contains("/usr/bin/codesign --force --deep --sign - \"$MAC_APP_BUNDLE\""))
    XCTAssertTrue(scriptSource.contains("-c 'Add :CFBundlePackageType string APPL'"))
    XCTAssertTrue(scriptSource.contains("-c 'Add :NSPrincipalClass string NSApplication'"))
    XCTAssertFalse(scriptSource.contains("-c 'Add :LSUIElement bool true'"))
    XCTAssertFalse(scriptSource.contains("*.bundle"))
    XCTAssertTrue(scriptSource.contains("MAC_APP_BIN=\"$macos_dir/LocalLanInteropHost\""))
    XCTAssertTrue(scriptSource.contains("smoke-capture-source active=1"))
    XCTAssertTrue(scriptSource.contains("detect_macos_loginwindow_occlusion()"))
    XCTAssertTrue(scriptSource.contains("CGWindowListCopyWindowInfo"))
    XCTAssertTrue(scriptSource.contains("reason=screen-locked-loginwindow-occlusion"))
    XCTAssertTrue(scriptSource.contains("detect_macos_loginwindow_occlusion\nwait_for_file_pattern \"$HOST_STATUS\" 'smoke-capture-source active=1 .*windowOcclusionVisible=1'"))
    XCTAssertTrue(scriptSource.contains("macSCKSourceCallbackBottleneck="))
    XCTAssertFalse(scriptSource.contains("Mac HEVC aggregate captureFPS below"))
    XCTAssertFalse(scriptSource.contains("Mac HEVC aggregate meaningfulFPS below"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac HEVC SCK source frame age exceeded live-source budget inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains("Mac HEVC SCK repeated stale source frames inside final pass window"))
    XCTAssertFalse(scriptSource.contains("iOS LAN receive burst screenFPS exceeded strict target"))
    XCTAssertTrue(
      scriptSource.contains("Mac remote maxFramesPerDrain was not the bounded strict cadence path"))
    XCTAssertTrue(
      scriptSource.contains("Mac remote scheduleBudgetMax exceeded bounded strict cadence recovery")
    )
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote missed cadence slots exceeded strict zero-miss cadence budget"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote queuedMax exceeded ordered SBC2 cadence buffer inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentProcessed backlog exceeded the strict frame limit inside final pass window"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentProcessed backlog hit the strict frame ceiling inside final pass window"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentProcessed byte backlog hit the bounded ceiling inside final pass window")
    )
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentProcessed latency exceeded the 200ms budget inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote encoded-to-sender actor delay exceeded 100ms inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote encoded-frame submit gap exceeded four-frame budget inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote oldest contentProcessed backlog exceeded 300ms inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains("Mac remote queued frame age exceeded 100ms inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains("Mac remote dequeued frame age exceeded 100ms inside final pass window")
    )
    XCTAssertTrue(
      scriptSource.contains("Mac remote stale queue catch-up was nonzero inside final pass window"))
    XCTAssertTrue(scriptSource.contains("macContentBacklogMax="))
    XCTAssertTrue(scriptSource.contains("macOldestContentBacklogMs="))
    XCTAssertTrue(scriptSource.contains("macQueueAgeMaxMs="))
    XCTAssertTrue(scriptSource.contains("macDequeuedAgeMaxMs="))
    XCTAssertTrue(scriptSource.contains("macEncodedToSubmitMaxMs="))
    XCTAssertTrue(scriptSource.contains("macSubmitGapMaxMs="))
    XCTAssertTrue(scriptSource.contains("macStaleQueueCatchUp="))
    XCTAssertTrue(scriptSource.contains("lanReadAheadSamples="))
    XCTAssertTrue(scriptSource.contains("macCaptureFPS="))
    XCTAssertTrue(scriptSource.contains("macMeaningfulFPS="))
    XCTAssertTrue(scriptSource.contains("macSourceFrameAgeMaxMs="))
    XCTAssertTrue(scriptSource.contains("macSourceFrameRepeatMax="))
    XCTAssertTrue(scriptSource.contains("macCaptureMin="))
    XCTAssertTrue(scriptSource.contains("minimum_window_samples = max(1, int(soak_seconds) - 2)"))
    XCTAssertTrue(
      scriptSource.contains("too few Mac HEVC SCK telemetry samples inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains("too few Metal render telemetry samples inside final pass window"))
    XCTAssertTrue(
      remoteViewSource.contains("SkyBridgeSmokeTraceWriter.appendStatus(telemetryLine)"))
    XCTAssertTrue(
      scriptSource.contains(
        "for key in (\"queueDrop\", \"drawableSkip\", \"inflightSkip\", \"failureSkip\"):"))
    XCTAssertFalse(scriptSource.contains("queueDrop=[1-9][0-9]*"))
    XCTAssertTrue(scriptSource.contains("audioRxJitterEvicted=[1-9][0-9]*"))
    XCTAssertTrue(scriptSource.contains("datagrams=[1-9][0-9][0-9]+ .*probable=rx-decode-stalled"))
    XCTAssertFalse(
      scriptSource.contains(
        "grep -qE \"$IOS_REMOTE_SMOKE_FAILURE_PATTERN|$HOST_REMOTE_SMOKE_FAILURE_PATTERN\" \"$path\""
      ),
      "The smoke harness must keep iOS and host failure regexes source-scoped; host audio-only probes can legitimately mention codec=h264."
    )
    XCTAssertTrue(scriptSource.contains("launch_ios_remote_smoke_app"))
    XCTAssertTrue(scriptSource.contains("iOS remote smoke app launch failed before P2P handshake"))
    XCTAssertTrue(
      scriptSource.contains(
        "invalid code signature|inadequate entitlements|profile has not been explicitly trusted"))
    XCTAssertTrue(scriptSource.contains("launch_result_indicates_locked_device"))
    XCTAssertTrue(
      scriptSource.contains("device remained locked for ${IOS_LAUNCH_TIMEOUT_SECONDS}s"))
    XCTAssertTrue(
      scriptSource.contains("this is a real-device precondition, not a remote desktop media pass"))
  }

  func testP2PRealDeviceSmokeRejectsFlippedMetalRenderOrientation() throws {
    let appSource = try skyBridgeCompassAppSource()
    let managerSource = try remoteDesktopManagerSource()
    let presentationTypesSource = try remoteDesktopPresentationTypesSource()
    let remoteViewSource = try remoteDesktopViewSource()
    let scriptSource = try repositoryScriptSource("Scripts/run_real_device_p2p_remote_smoke.sh")

    XCTAssertTrue(presentationTypesSource.contains("public enum RemoteDesktopRenderOrientation"))
    XCTAssertTrue(
      managerSource.contains("@Published public private(set) var renderOrientationStatus"))
    XCTAssertTrue(managerSource.contains("renderOrientation: renderOrientationStatus"))
    XCTAssertTrue(appSource.contains("expectedRenderOrientation"))
    XCTAssertTrue(appSource.contains("snapshot.renderOrientation == expectedRenderOrientation"))
    XCTAssertTrue(appSource.contains("renderOrientation=\\(snapshot.renderOrientation.rawValue)"))

    XCTAssertTrue(remoteViewSource.contains("let uprightTransform = CGAffineTransform("))
    XCTAssertTrue(remoteViewSource.contains("d: scaleY"))
    XCTAssertFalse(remoteViewSource.contains("d: -scaleY"))
    XCTAssertTrue(remoteViewSource.contains("orientation=upright"))

    XCTAssertTrue(scriptSource.contains("SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION"))
    XCTAssertTrue(scriptSource.contains("renderOrientation=${SMOKE_EXPECT_RENDER_ORIENTATION}"))
    XCTAssertTrue(scriptSource.contains("orientation=verticalFlip"))
    XCTAssertTrue(scriptSource.contains("renderOrientation=verticalFlip"))
  }

  func testLANRemoteReceiveRegistersRawChunkBeforeRearmingSocket() throws {
    let source = try remoteDesktopManagerSource()
    let runtimeModelsSource = try remoteDesktopRuntimeModelsSource()
    let runtimeSources = source + "\n" + runtimeModelsSource
    let receiveChunk = try sourceSlice(
      from: "private nonisolated func receiveNextLANChunk(",
      to: "private func processLANReceiveBuffer(from connection: NWConnection) async",
      in: source
    )
    let processBody = try sourceSlice(
      from: "private func processLANReceiveBuffer(from connection: NWConnection) async",
      to:
        "private func nextLANFramedPayloadFromReceiveBuffer() throws -> (payload: Data, receivedAt: Date?)?",
      in: source
    )

    XCTAssertTrue(source.contains("resetLANReceiveParserState()"))
    XCTAssertTrue(receiveChunk.contains("minimumIncompleteLength: 1"))
    XCTAssertTrue(runtimeModelsSource.contains("enum RemoteDesktopManagerRuntimeLimits"))
    XCTAssertTrue(
      runtimeModelsSource.contains("static let lanReceiveChunkMaxBytes: Int = 256 * 1024"))
    XCTAssertTrue(runtimeModelsSource.contains("static let maxLANScreenFramesPerParserDrain = 4"))
    XCTAssertTrue(runtimeModelsSource.contains("static let maxLANParserDrainBudgetMs: Double = 6.0"))
    XCTAssertTrue(source.contains("private let metalFeedDeliveryMaxDelayMs: Double = 100.0"))
    XCTAssertTrue(runtimeModelsSource.contains("enum LANInboundPayloadKind: Equatable"))
    XCTAssertTrue(source.contains("private var lanReceiveBufferNewestArrivalAt: Date?"))
    XCTAssertTrue(
      source.contains(
        "private var lanReceiveBufferArrivalMarkers: [(endOffset: Int, receivedAt: Date)] = []"))
    XCTAssertTrue(
      source.contains("private lazy var lanSecureReceivePipeline = LANRemoteSecureReceivePipeline(")
    )
    XCTAssertTrue(source.contains("private let lanSecureReceiveScheduler = LANSecureReceiveScheduler()"))
    XCTAssertTrue(source.contains("private var lanSecureReceiveApplyChain: Task<Void, Never>?"))
    XCTAssertTrue(source.contains("private var lanSecureReceiveGeneration: UInt64 = 0"))
    XCTAssertTrue(source.contains("lanReceiveBufferNewestArrivalAt = nil"))
    XCTAssertTrue(
      source.contains("lanReceiveBufferArrivalMarkers.removeAll(keepingCapacity: keepingCapacity)"))
    XCTAssertTrue(source.contains("resetMetalFeedDeliveryState(keepingCapacity: keepingCapacity)"))
    XCTAssertTrue(
      source.contains(
        "lanSecureReceivePipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: maxLANWireMessageBytes)"
      ))
    XCTAssertTrue(source.contains("lanSecureReceiveScheduler.cancel()"))
    XCTAssertTrue(source.contains("lanSecureReceiveApplyChain?.cancel()"))
    XCTAssertTrue(source.contains("lanSecureReceiveApplyChain = nil"))
    XCTAssertTrue(
      receiveChunk.contains(
        "maximumLength: RemoteDesktopManagerRuntimeLimits.lanReceiveChunkMaxBytes"))
    XCTAssertTrue(receiveChunk.contains("private nonisolated func receiveNextLANChunk"))
    XCTAssertTrue(
      receiveChunk.contains("self?.receiveNextLANChunk(from: connection, secureContext: secureContext)"))
    XCTAssertTrue(
      receiveChunk.contains("secureContext: self.makeLANSecureReceiveContextIfAvailable(for: connection)"))
    XCTAssertTrue(receiveChunk.contains("!self.shouldContinueLANBootstrapFramingHandoff"))
    XCTAssertTrue(receiveChunk.contains("self.processSecureLANReceiveChunk("))
    XCTAssertTrue(receiveChunk.contains("self.lanReceiveBufferNewestArrivalAt = receivedAt"))
    XCTAssertTrue(
      receiveChunk.contains("(endOffset: self.lanReceiveBuffer.count, receivedAt: receivedAt)"))
    XCTAssertTrue(receiveChunk.contains("await self.processLANReceiveBuffer(from: connection)"))
    XCTAssertTrue(processBody.contains("noteLANBootstrapParserDrain("))
    XCTAssertTrue(source.contains("parserDrainMaxMs="))
    XCTAssertTrue(source.contains("parserBudgetMs="))
    XCTAssertTrue(source.contains("parserBudgetHits="))
    XCTAssertTrue(source.contains("bootstrapParserDrainMaxMs="))
    XCTAssertTrue(source.contains("bootstrapParserBudgetHits="))
    XCTAssertTrue(source.contains("payloadsPerDrainMax="))
    XCTAssertTrue(source.contains("completeFramesPerDrainMax="))
    XCTAssertTrue(source.contains("screenDelivery=immediate-decode-metal-feed-direct"))
    XCTAssertTrue(source.contains("screenDeliveryQueueDepthMax="))
    XCTAssertTrue(source.contains("screenDeliveryDelayMaxMs="))
    XCTAssertTrue(source.contains("metal-feed-delivery-delay-exceeded"))
    XCTAssertFalse(source.contains("metal-feed-backlog-overflow"))
    XCTAssertFalse(source.contains("private var isMetalFeedDeliverySteadyState: Bool"))
    XCTAssertFalse(source.contains("PendingMetalFeedFrame"))
    let rearmIndex = try XCTUnwrap(
      receiveChunk.range(of: "self?.receiveNextLANChunk(from: connection, secureContext: secureContext)")?
        .lowerBound)
    let secureRegistrationIndex = try XCTUnwrap(
      receiveChunk.range(of: "secureContext.scheduler.scheduleChunk(")?.lowerBound)
    let bufferedAppendIndex = try XCTUnwrap(
      receiveChunk.range(of: "self.lanReceiveBuffer.append(chunk)")?.lowerBound)
    let bootstrapRearmIndex = try XCTUnwrap(
      receiveChunk.range(
        of: "secureContext: self.makeLANSecureReceiveContextIfAvailable(for: connection)")?
        .lowerBound)
    XCTAssertLessThan(
      secureRegistrationIndex,
      rearmIndex,
      "LAN secure receive must enqueue raw bytes on the ordered off-main scheduler before re-arming NWConnection; otherwise later callbacks can overtake earlier screen chunks and corrupt AES-GCM frame boundaries."
    )
    XCTAssertLessThan(
      bufferedAppendIndex,
      bootstrapRearmIndex,
      "LAN bootstrap receive must append raw bytes before re-arming NWConnection so handoff into the secure parser preserves TCP byte order."
    )
    XCTAssertTrue(processBody.contains("while isCurrentLANConnection(connection)"))
    XCTAssertTrue(processBody.contains("try nextLANFramedPayloadFromReceiveBuffer()"))
    XCTAssertTrue(
      processBody.contains("let bodyReceivedAt = nextPayload.receivedAt ?? drainStartedAt"))
    XCTAssertTrue(processBody.contains("if let keys = lanSessionKeys"))
    XCTAssertTrue(processBody.contains("let framedPayload = Self.lanLengthPrefixedFrame(for: data)"))
    XCTAssertTrue(
      processBody.contains(
        "processSecureLANReceiveChunk(\n                        framedPayload"))
    XCTAssertTrue(source.contains("lanReceiveBufferArrivalTime(forPayloadEndingAt: totalLength)"))
    XCTAssertTrue(source.contains("consumeLANReceiveBufferBytes(totalLength)"))
    XCTAssertTrue(source.contains("private static func lanLengthPrefixedFrame(for payload: Data) -> Data"))
    XCTAssertTrue(processBody.contains("try unwrapLANChunkedPayloadIfNeeded("))
    XCTAssertTrue(processBody.contains("let completeWirePayload: Data"))
    XCTAssertTrue(processBody.contains("case .complete(let payload):"))
    XCTAssertTrue(processBody.contains("let payloadKind = try await handleInboundLANPayload("))
    XCTAssertTrue(source.contains("await handleScreenData(screenData, receivedAt: bodyReceivedAt)"))
    XCTAssertTrue(source.contains("await enqueueMetalFrameForDisplay("))
    XCTAssertFalse(source.contains("scheduleMetalFeedDeliveryIfNeeded()"))
    XCTAssertFalse(source.contains("lastMetalFeedDeliveryAt"))
    XCTAssertTrue(source.contains("metalVideoFrameFeed.enqueue(frame: frame)"))
    XCTAssertTrue(source.contains("lanInboundScreenDeliveryQueueDepthMax,\n            1"))
    XCTAssertFalse(source.contains("enqueueLANScreenFrameForDecode("))
    XCTAssertFalse(source.contains("PendingLANScreenDecodeFrame"))
    XCTAssertTrue(processBody.contains("if payloadKind == .screen"))
    XCTAssertTrue(
      processBody.contains(
        "completeFramesInDrain >= RemoteDesktopManagerRuntimeLimits.maxLANScreenFramesPerParserDrain"
      ))
    XCTAssertTrue(
      processBody.contains(
        "Date().timeIntervalSince(drainStartedAt) * 1_000 >= RemoteDesktopManagerRuntimeLimits.maxLANParserDrainBudgetMs"
      ))
    XCTAssertTrue(
      processBody.contains("needsLANReceiveBufferDrain = hasCompleteLANFramedPayloadPending()"))
    XCTAssertFalse(
      runtimeSources.contains("static let maxLANScreenFramesPerParserDrain = 1"),
      "The secure LAN parser must absorb small TCP/NW bursts in one actor drain; one-frame drains amplified sourceToRead and rx cadence gaps in the 2056x1329@60fps artifact."
    )
    XCTAssertFalse(
      runtimeSources.contains("static let maxLANScreenFramesPerParserDrain = 2"),
      "Two-frame drains were still too shallow in the 2056x1329@60fps real-device artifact: rx cadence reset with completeFramesPerDrainMax=2 and sourceToReadMax above 100ms."
    )
    XCTAssertFalse(
      runtimeSources.contains("static let maxLANScreenFramesPerParserDrain = 8"),
      "Parser burst absorption must stay tightly bounded so it cannot hide decode/render backpressure by draining an unbounded frame backlog."
    )
    XCTAssertFalse(
      source.contains(
        "startReceiving() {\n        guard let connection = networkConnection else { return }\n        receiveNextMessage(from: connection)"
      ),
      "The LAN 60fps path must not wait for whole-message receive completions before re-arming the socket."
    )
  }

  func testLANRemoteSecureReceivePipelineDecryptsAndDecodesOffMainActor() throws {
    let source = try remoteDesktopManagerSource()
    let pipelineSource = try remoteDesktopLANSecureReceivePipelineSource()
    let actorBody = try sourceSlice(
      from: "actor LANRemoteSecureReceivePipeline",
      to: "private func nextFramedPayload()",
      in: pipelineSource
    )
    let receiveChunk = try sourceSlice(
      from: "private nonisolated func receiveNextLANChunk(",
      to: "private func processSecureLANReceiveChunk(",
      in: source
    )
    let secureEntry = try sourceSlice(
      from: "private func processSecureLANReceiveChunk(",
      to: "private func handleScheduledSecureLANReceiveResult(",
      in: source
    )
    let schedulerBody = try sourceSlice(
      from: "private final class LANSecureReceiveScheduler",
      to: "// MARK: - RemoteDesktopManager",
      in: source
    )
    let nextFramedPayloadBody = try sourceSlice(
      from: "private func nextFramedPayload()",
      to: "private func arrivalTime(forPayloadEndingAt endOffset: Int) -> Date?",
      in: pipelineSource
    )

    XCTAssertTrue(actorBody.contains("actor LANRemoteSecureReceivePipeline"))
    XCTAssertTrue(actorBody.contains("RemoteControlSecureEnvelope.open("))
    XCTAssertTrue(actorBody.contains("allowedPacketTypes: [.control, .screen, .audio]"))
    XCTAssertTrue(actorBody.contains("RemoteControlSecureReplayWindow"))
    XCTAssertTrue(actorBody.contains("replayWindow.validateAndRecord(openedPayload)"))
    XCTAssertTrue(actorBody.contains("validatePacketType(openedPayload.packetType"))
    XCTAssertTrue(actorBody.contains("RemoteDesktopScreenFrameWire.decodeIfPresent(payload)"))
    XCTAssertTrue(actorBody.contains("RemoteDesktopAudioChunkWire.decodeIfPresent(payload)"))
    XCTAssertTrue(
      pipelineSource.contains("case screen(ScreenData, payloadBytes: Int, bodyReceivedAt: Date)"))
    XCTAssertTrue(
      pipelineSource.contains("let chunkBytes: Int"),
      "Slow parser diagnostics must retain the raw NWConnection chunk size for 2K60 SBC2 bottleneck attribution."
    )
    XCTAssertTrue(actorBody.contains("maxCompleteScreenFrames"))
    XCTAssertTrue(actorBody.contains("maxDrainBudgetMs"))
    XCTAssertTrue(actorBody.contains("parserTimeBudgetHit"))
    XCTAssertTrue(
      actorBody.contains("hasCompletePayloadPending: hasCompleteFramedPayloadPending()"))
    XCTAssertTrue(pipelineSource.contains("struct ParserStageTelemetry"))
    XCTAssertTrue(actorBody.contains("stageName: \"length-frame-pop\""))
    XCTAssertTrue(actorBody.contains("\"sbc2-reassembly-complete\""))
    XCTAssertTrue(actorBody.contains("stageName: \"decrypt\""))
    XCTAssertTrue(actorBody.contains("stageName: \"decode\""))
    XCTAssertTrue(pipelineSource.contains("private var receiveBufferReadOffset = 0"))
    XCTAssertTrue(pipelineSource.contains("private var readableReceiveBufferBytes: Int"))
    XCTAssertTrue(pipelineSource.contains("private func compactReceiveBufferIfNeeded()"))
    XCTAssertTrue(nextFramedPayloadBody.contains("receiveBufferReadOffset += totalLength"))
    XCTAssertTrue(nextFramedPayloadBody.contains("compactReceiveBufferIfNeeded()"))
    XCTAssertFalse(
      nextFramedPayloadBody.contains("receiveBuffer.removeSubrange"),
      "Secure LAN parser must not remove every payload from the front of Data; 2K60 SBC2 backlog made that O(n) copy dominate parserDrain."
    )
    XCTAssertTrue(receiveChunk.contains("if let keys = self.lanSessionKeys"))
    XCTAssertTrue(receiveChunk.contains("self.processSecureLANReceiveChunk("))
    XCTAssertFalse(
      secureEntry.contains("@MainActor"),
      "Secure LAN frame decryption and screen-wire decode must be delegated to the off-main actor, not a MainActor task."
    )
    XCTAssertTrue(schedulerBody.contains("Task.detached(priority: .high)"))
    XCTAssertTrue(
      schedulerBody.contains("await previous?.value"),
      "Secure LAN parser must preserve TCP chunk order before appending to the sbc2/length-frame reassembler."
    )
    XCTAssertFalse(
      schedulerBody.contains("await previousTask?.value"),
      "Secure LAN parser must not wait for the previous MainActor apply before parsing the next 256KB sbc2 chunk."
    )
    XCTAssertTrue(secureEntry.contains("lanSecureReceiveScheduler.scheduleChunk("))
    XCTAssertFalse(source.contains("lanSecureReceiveChain"))
    XCTAssertTrue(source.contains("private func scheduleSecureLANReceiveApply("))
    XCTAssertTrue(source.contains("await previousApply?.value"))
    let pendingDrainIndex = try XCTUnwrap(
      schedulerBody.range(of: "if result.hasCompletePayloadPending")?.lowerBound
    )
    let applyScheduleIndex = try XCTUnwrap(
      schedulerBody.range(of: "await completion(.success(result)")?.lowerBound
    )
    XCTAssertLessThan(
      applyScheduleIndex,
      pendingDrainIndex,
      "Secure LAN parser must register the current apply before scheduling the next pending drain so drained follow-up events cannot overtake earlier audio/screen events."
    )
    XCTAssertTrue(schedulerBody.contains("private func scheduleDrain("))
    XCTAssertTrue(schedulerBody.contains("context.pipeline.drain("))
    XCTAssertTrue(secureEntry.contains("let generation = lanSecureReceiveGeneration"))
    XCTAssertTrue(secureEntry.contains("connectionID: connectionID"))
    XCTAssertTrue(secureEntry.contains("generation: generation"))
    XCTAssertTrue(schedulerBody.contains("context.connectionID"))
    XCTAssertTrue(schedulerBody.contains("context.generation"))
    XCTAssertTrue(schedulerBody.contains("private var epoch: UInt64 = 0"))
    XCTAssertTrue(schedulerBody.contains("epoch &+= 1"))
    XCTAssertTrue(schedulerBody.contains("isCurrentEpoch(expectedEpoch)"))
    XCTAssertTrue(
      schedulerBody.contains("let previous = tailTask")
        && schedulerBody.contains("await previous?.value"),
      "A pending secure drain must remain on the same parser scheduler so length-framed screen bytes cannot be drained ahead of earlier append tasks."
    )
    let secureApplyBody = try sourceSlice(
      from: "private func applySecureLANReceiveResult(",
      to: "private func handleSecureLANReceiveFailure(",
      in: source
    )
    XCTAssertFalse(
      secureApplyBody.contains("scheduleSecureLANReceiveDrain"),
      "Pending secure drains must not wait for the MainActor apply chain to start."
    )
    XCTAssertTrue(schedulerBody.contains("context.pipeline.appendAndDrain("))
    XCTAssertTrue(actorBody.contains("LAN secure decrypt failed bytes="))
    let secureFailureBody = try sourceSlice(
      from: "private func handleSecureLANReceiveFailure(",
      to: "private func handleInboundLANRemoteMessage(",
      in: source
    )
    XCTAssertTrue(secureFailureBody.contains("generation: UInt64"))
    XCTAssertTrue(secureFailureBody.contains("generation == lanSecureReceiveGeneration"))
    XCTAssertTrue(secureFailureBody.contains("Ignored stale LAN secure receive failure"))
    XCTAssertTrue(secureApplyBody.contains("handleSecureLANReceiveFailure("))
    XCTAssertTrue(secureApplyBody.contains("connectionID: connectionID"))
    XCTAssertTrue(secureApplyBody.contains("generation: generation"))
    XCTAssertTrue(source.contains("parser=\\(lanInboundReceiveParserMode)"))
    XCTAssertTrue(source.contains("secure-off-main-actor"))
    XCTAssertTrue(source.contains("parseQueueDelayMaxMs="))
    XCTAssertTrue(source.contains("parserActorHopMaxMs="))
    XCTAssertTrue(source.contains("parserStageMax="))
    XCTAssertTrue(source.contains("parserStagePayloadBytesMax="))
    XCTAssertTrue(source.contains("parserStageBufferBytesMax="))
    XCTAssertTrue(source.contains("applyQueueDelayMaxMs="))
    XCTAssertTrue(source.contains("screenApplyMaxMs="))
    XCTAssertTrue(source.contains("ios-lan-parser-slow session="))
    XCTAssertTrue(source.contains("budgetHit=\\(result.parserTimeBudgetHit ? 1 : 0)"))
    XCTAssertTrue(source.contains("rawChunkBytes=\\(rawChunk?.chunkBytes ?? 0)"))
    XCTAssertTrue(source.contains("receiveBufferBytesAfterDrain=\\(result.receiveBufferBytesAfterDrain)"))
    XCTAssertTrue(source.contains("parserStageMax=\\(stageTelemetry?.stageName ?? \"none\")"))
    XCTAssertTrue(source.contains("parserStagePayloadBytes=\\(stageTelemetry?.payloadBytes ?? 0)"))
  }

  func testLANReceiveLoopStartsAfterHandshakeDriverInstall() throws {
    let source = try remoteDesktopManagerSource()
    let preHandshakeBody = try sourceSlice(
      from: "currentConnection = Connection(device: refreshedLANDevice, status: .connected)",
      to: "try await establishLANSecureChannel(for: refreshedLANDevice, over: connection)",
      in: source
    )
    let driverCreatedBody = try sourceSlice(
      from: "onDriverCreated: { driver in",
      to: "try ensureLANBootstrapStillActive(for: connection)",
      in: source
    )

    XCTAssertFalse(
      preHandshakeBody.contains("startReceiving()"),
      "LAN receive may be armed for handshake traffic, but only after the handshake driver exists."
    )
    XCTAssertTrue(driverCreatedBody.contains("installLANHandshakeDriver("))
    XCTAssertTrue(driverCreatedBody.contains("startReceiving()"))
    XCTAssertTrue(source.contains("private func installLANSecureSessionKeys("))

    let installKeysBody = try sourceSlice(
      from: "private func installLANSecureSessionKeys(",
      to: "private func syncLANSecureChannelState(",
      in: source
    )
    XCTAssertTrue(
      installKeysBody.contains(
        "let shouldDrainBootstrapAfterInstall = shouldContinueLANBootstrapFramingHandoff"))
    XCTAssertTrue(installKeysBody.contains("if shouldDrainBootstrapAfterInstall {"))
    XCTAssertTrue(installKeysBody.contains("resetLANSecureReceivePipelineState()"))
    XCTAssertTrue(installKeysBody.contains("needsLANReceiveBufferDrain = true"))
    XCTAssertTrue(installKeysBody.contains("resetLANReceiveParserState()"))
    XCTAssertTrue(installKeysBody.contains("lanSessionKeys = keys"))
    XCTAssertTrue(
      installKeysBody.contains(
        "await self?.processLANReceiveBuffer(from: connection)"))

    let resetParserBody = try sourceSlice(
      from: "private func resetLANReceiveParserState(",
      to: "private func isCrossNetworkDevice(",
      in: source
    )
    XCTAssertTrue(resetParserBody.contains("private func resetLANSecureReceivePipelineState("))
    XCTAssertTrue(resetParserBody.contains("private var shouldContinueLANBootstrapFramingHandoff: Bool"))
    XCTAssertFalse(
      resetParserBody.contains("lanSecureSendCounter = 0"),
      "Receive parser resets must not rewind the LAN secure envelope send counter for an established session."
    )
  }

  func testStrictInboundP2PHandshakeRequiresStablePinnedIdentity() throws {
    let source = try p2pConnectionManagerSource()
    let inboundBody = try sourceSlice(
      from: "private func ensureInboundHandshakeDriverIfNeeded(",
      to: "private func processHandshakeFrame(",
      in: source
    )
    let trustContextBody = try sourceSlice(
      from: "private func strictInboundHandshakeTrustContext(",
      to: "private func preferredStrictPQCHandshakeTargetSuite()",
      in: source
    )
    let messageASOACandidateBody = try sourceSlice(
      from: "private func stableProtocolIdentityCandidates(from messageA: HandshakeMessageA?)",
      to: "private func strictInboundHandshakeTrustContext(",
      in: source
    )
    let connectBody = try sourceSlice(
      from: "public func connect(to device: DiscoveredDevice) async throws",
      to: "let endpoints = connectionEndpointCandidates(for: targetDevice)",
      in: source
    )

    XCTAssertTrue(inboundBody.contains("strictInboundHandshakeTrustContext("))
    XCTAssertTrue(inboundBody.contains("messageA: messageA"))
    XCTAssertTrue(inboundBody.contains("trustProvider: strictTrustContext?.provider"))
    XCTAssertTrue(inboundBody.contains("expectedRemoteSOAPeerId: soaPeerIdBytes(for: strictTrustContext?.stablePeerId ?? peerId)"))
    XCTAssertTrue(messageASOACandidateBody.contains("soa.initiatorPeerId"))
    XCTAssertTrue(messageASOACandidateBody.contains("TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: fingerprint)"))
    XCTAssertTrue(messageASOACandidateBody.contains("ProtocolIdentityTrustStore.shared.deviceIds(containingFingerprint: fingerprint)"))
    XCTAssertTrue(messageASOACandidateBody.contains("TrustedDeviceStore.shared.trustedDevices"))
    XCTAssertTrue(messageASOACandidateBody.contains("lastAcceptedPairingIdentityDeviceIdByPeerId"))
    XCTAssertTrue(messageASOACandidateBody.contains("soaPeerIdBytes(for: normalizedStablePeerId)"))
    XCTAssertTrue(trustContextBody.contains("messageAStableCandidates + [peerId"))
    XCTAssertTrue(trustContextBody.contains("reason=ambiguous_message_a_soa_identity"))
    XCTAssertTrue(trustContextBody.contains("resolved stable peer from MessageA SOA"))
    XCTAssertTrue(trustContextBody.contains("reason=missing_stable_protocol_identity"))
    XCTAssertTrue(trustContextBody.contains("reason=missing_pinned_protocol_identity"))
    XCTAssertTrue(trustContextBody.contains("P2PStoredHandshakeTrustProvider("))
    XCTAssertTrue(source.contains("!PeerIdentityAliasResolver.isEndpointAlias(trimmed)"))
    XCTAssertTrue(connectBody.contains("hasActiveAuthenticatedSession(for: targetDevice.id)"))
    XCTAssertTrue(connectBody.contains("matchingInFlightConnectKey(for: targetDevice, runtimePeerId: runtimePeerId)"))
    XCTAssertTrue(connectBody.contains("await waitForInFlightConnect(inFlightKey)"))
    XCTAssertTrue(connectBody.contains("reason=missing_authenticated_session"))
    XCTAssertFalse(
      connectBody.contains("sessionKeys[targetDevice.id] != nil || connections[targetDevice.id] != nil"),
      "A raw transport connection must not satisfy the connected gate without authenticated session keys."
    )
  }

  func testLANRemoteSecureReceivePipelineOpensTypedEnvelopePayloads() async throws {
    func lengthPrefixedLANPayload(_ payload: Data) -> Data {
      var output = Data()
      var length = UInt32(payload.count).bigEndian
      withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
      output.append(payload)
      return output
    }

    let transcriptHash = Data((0..<32).map(UInt8.init))
    let outboundKey = Data(repeating: 0x31, count: 32)
    let inboundKey = Data(repeating: 0x42, count: 32)
    let senderKeys = SessionKeys(
      sendKey: outboundKey,
      receiveKey: inboundKey,
      negotiatedSuite: .xwing,
      role: .initiator,
      transcriptHash: transcriptHash
    )
    let receiverKeys = SessionKeys(
      sendKey: inboundKey,
      receiveKey: outboundKey,
      negotiatedSuite: .xwing,
      role: .responder,
      transcriptHash: transcriptHash
    )
    let screen = ScreenData(
      width: 2,
      height: 2,
      imageData: Data([0x01, 0x02, 0x03]),
      timestamp: 1_700_000_000,
      format: "hevc",
      isSyncFrame: true,
      sequenceNumber: 9
    )
    let screenMessage = try JSONEncoder().encode(
      RemoteMessage(type: .screenData, payload: JSONEncoder().encode(screen))
    )
    let controlMessage = try JSONEncoder().encode(
      RemoteMessage(type: .clipboard, payload: Data("typed-control".utf8))
    )
    let pipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)

    let screenPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        screenMessage,
        keys: senderKeys,
        packetType: .screen,
        counter: 1
      )
    )
    let screenResult = try await pipeline.appendAndDrain(
      chunk: screenPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_001),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    guard case .screen(let decodedScreen, _, _) = try XCTUnwrap(screenResult.events.first) else {
      XCTFail("expected typed screen envelope to decode as screen")
      return
    }
    XCTAssertEqual(decodedScreen.sequenceNumber, 9)
    XCTAssertEqual(decodedScreen.format, "hevc")

    let controlPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        controlMessage,
        keys: senderKeys,
        packetType: .control,
        counter: 2
      )
    )
    let controlResult = try await pipeline.appendAndDrain(
      chunk: controlPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_002),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    guard case .control(let decodedMessage, _, _) = try XCTUnwrap(controlResult.events.first) else {
      XCTFail("expected typed control envelope to decode as control")
      return
    }
    XCTAssertEqual(decodedMessage.type, .clipboard)

    let replayResult = try await pipeline.appendAndDrain(
      chunk: screenPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_003),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertTrue(replayResult.events.isEmpty)
    XCTAssertEqual(replayResult.secureReplayDrops.count, 1)
    XCTAssertEqual(replayResult.secureReplayDrops.first?.packetType, .screen)
    XCTAssertEqual(replayResult.secureReplayDrops.first?.counter, 1)
    XCTAssertEqual(replayResult.secureReplayDrops.first?.highestCounter, 1)
    XCTAssertEqual(replayResult.secureReplayDrops.first?.reason, .duplicateCounter)

    let mismatchPipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    let mismatchedPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        screenMessage,
        keys: senderKeys,
        packetType: .control,
        counter: 3
      )
    )
    do {
      _ = try await mismatchPipeline.appendAndDrain(
        chunk: mismatchedPacket,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_004),
        keys: receiverKeys,
        maxCompleteScreenFrames: 4,
        maxDrainBudgetMs: 100
      )
      XCTFail("expected packet type mismatch to fail closed")
    } catch RemoteDesktopError.streamingFailed(let message) {
      XCTAssertTrue(message.contains("LAN secure control payload carried screenData"))
    }
  }

  func testLANRemoteSecureReceivePipelineHandlesMixedAudioScreenControlBurstWithoutReplayPollution() async throws {
    func lengthPrefixedLANPayload(_ payload: Data) -> Data {
      var output = Data()
      var length = UInt32(payload.count).bigEndian
      withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
      output.append(payload)
      return output
    }
    func appendUInt32(_ value: UInt32, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt64(_ value: UInt64, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func audioWirePayload(
      samples: Data,
      sequenceNumber: UInt64,
      sampleRate: Int = 48_000,
      channelCount: Int = 2,
      frameCount: Int = 480,
      timestampMicros: UInt64 = 1_700_000_123_000_000
    ) -> Data {
      var wire = Data()
      appendUInt32(0x5342_5241, to: &wire)
      wire.append(2)
      wire.append(1)
      wire.append(UInt8(channelCount))
      wire.append(0)
      appendUInt32(UInt32(sampleRate), to: &wire)
      appendUInt32(UInt32(frameCount), to: &wire)
      appendUInt32(0, to: &wire)
      appendUInt64(sequenceNumber, to: &wire)
      appendUInt64(timestampMicros, to: &wire)
      appendUInt32(0, to: &wire)
      appendUInt32(0, to: &wire)
      appendUInt32(UInt32(samples.count), to: &wire)
      wire.append(samples)
      return wire
    }

    let transcriptHash = Data((0..<32).map(UInt8.init))
    let outboundKey = Data(repeating: 0x71, count: 32)
    let inboundKey = Data(repeating: 0x82, count: 32)
    let senderKeys = SessionKeys(
      sendKey: outboundKey,
      receiveKey: inboundKey,
      negotiatedSuite: .xwing,
      role: .initiator,
      transcriptHash: transcriptHash,
      sessionId: "lan-mixed-burst"
    )
    let receiverKeys = SessionKeys(
      sendKey: inboundKey,
      receiveKey: outboundKey,
      negotiatedSuite: .xwing,
      role: .responder,
      transcriptHash: transcriptHash,
      sessionId: "lan-mixed-burst"
    )
    let audioPayload = audioWirePayload(
      samples: Data([0x10, 0x11, 0x12, 0x13]),
      sequenceNumber: 77
    )
    let screen = ScreenData(
      width: 2,
      height: 2,
      imageData: Data([0x01, 0x02, 0x03]),
      timestamp: 1_700_000_020,
      format: "hevc",
      isSyncFrame: true,
      sequenceNumber: 22
    )
    let screenMessage = try JSONEncoder().encode(
      RemoteMessage(type: .screenData, payload: JSONEncoder().encode(screen))
    )
    let controlMessage = try JSONEncoder().encode(
      RemoteMessage(type: .clipboard, payload: Data("mixed-control".utf8))
    )
    let audioPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        audioPayload,
        keys: senderKeys,
        packetType: .audio,
        counter: 1
      )
    )
    let screenPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        screenMessage,
        keys: senderKeys,
        packetType: .screen,
        counter: 1
      )
    )
    let controlPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        controlMessage,
        keys: senderKeys,
        packetType: .control,
        counter: 1
      )
    )
    let pipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    var mixedChunk = Data()
    mixedChunk.append(audioPacket)
    mixedChunk.append(screenPacket)
    mixedChunk.append(controlPacket)

    let mixedResult = try await pipeline.appendAndDrain(
      chunk: mixedChunk,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_021),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )

    XCTAssertEqual(mixedResult.payloads, 3)
    XCTAssertEqual(mixedResult.secureReplayDrops.count, 0)
    guard mixedResult.events.count == 3 else {
      XCTFail("expected audio, screen, and control events in one LAN secure drain")
      return
    }
    guard case .audio(let decodedAudio) = mixedResult.events[0] else {
      XCTFail("expected audio event first")
      return
    }
    XCTAssertEqual(decodedAudio.sequenceNumber, 77)
    XCTAssertEqual(decodedAudio.sampleRate, 48_000)
    XCTAssertEqual(decodedAudio.channelCount, 2)
    XCTAssertEqual(decodedAudio.data, Data([0x10, 0x11, 0x12, 0x13]))
    guard case .screen(let decodedScreen, _, _) = mixedResult.events[1] else {
      XCTFail("expected screen event second")
      return
    }
    XCTAssertEqual(decodedScreen.sequenceNumber, 22)
    guard case .control(let decodedControl, _, _) = mixedResult.events[2] else {
      XCTFail("expected control event third")
      return
    }
    XCTAssertEqual(decodedControl.type, .clipboard)

    let audioReplay = try await pipeline.appendAndDrain(
      chunk: audioPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_022),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertTrue(audioReplay.events.isEmpty)
    XCTAssertEqual(audioReplay.secureReplayDrops.count, 1)
    XCTAssertEqual(audioReplay.secureReplayDrops.first?.packetType, .audio)
    XCTAssertEqual(audioReplay.secureReplayDrops.first?.counter, 1)
    XCTAssertEqual(audioReplay.secureReplayDrops.first?.highestCounter, 1)
    XCTAssertEqual(audioReplay.secureReplayDrops.first?.reason, .duplicateCounter)

    let isolationPipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    let highScreenPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        screenMessage,
        keys: senderKeys,
        packetType: .screen,
        counter: 2_000
      )
    )
    let lowAudioPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        audioPayload,
        keys: senderKeys,
        packetType: .audio,
        counter: 1
      )
    )
    _ = try await isolationPipeline.appendAndDrain(
      chunk: highScreenPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_023),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    let lowAudioResult = try await isolationPipeline.appendAndDrain(
      chunk: lowAudioPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_024),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertEqual(lowAudioResult.secureReplayDrops.count, 0)
    XCTAssertEqual(lowAudioResult.events.count, 1)
    guard case .audio(let isolatedAudio) = lowAudioResult.events.first else {
      XCTFail("expected audio lane to stay independent from high screen counter")
      return
    }
    XCTAssertEqual(isolatedAudio.sequenceNumber, 77)
  }

  func testLANRemoteSecureReceivePipelineSurvivesOrderedFragmentedScreenBurst() async throws {
    func lengthPrefixedLANPayload(_ payload: Data) -> Data {
      var output = Data()
      var length = UInt32(payload.count).bigEndian
      withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
      output.append(payload)
      return output
    }
    func collectScreenSequences(from result: LANRemoteSecureReceiveResult, into sequences: inout [UInt64]) {
      for event in result.events {
        guard case .screen(let screen, _, _) = event,
              let sequenceNumber = screen.sequenceNumber else {
          continue
        }
        sequences.append(sequenceNumber)
      }
    }

    let transcriptHash = Data((0..<32).map(UInt8.init))
    let outboundKey = Data(repeating: 0xA1, count: 32)
    let inboundKey = Data(repeating: 0xB2, count: 32)
    let senderKeys = SessionKeys(
      sendKey: outboundKey,
      receiveKey: inboundKey,
      negotiatedSuite: .xwing,
      role: .initiator,
      transcriptHash: transcriptHash,
      sessionId: "lan-fragmented-screen-burst"
    )
    let receiverKeys = SessionKeys(
      sendKey: inboundKey,
      receiveKey: outboundKey,
      negotiatedSuite: .xwing,
      role: .responder,
      transcriptHash: transcriptHash,
      sessionId: "lan-fragmented-screen-burst"
    )
    var wire = Data()
    let frameCount = 300
    for counter in 1...frameCount {
      let screen = ScreenData(
        width: 2,
        height: 2,
        imageData: Data(repeating: UInt8(counter % 251), count: 16),
        timestamp: 1_700_000_100 + Double(counter) / 60.0,
        format: "hevc",
        isSyncFrame: counter == 1,
        sequenceNumber: UInt64(counter)
      )
      let message = try JSONEncoder().encode(
        RemoteMessage(type: .screenData, payload: JSONEncoder().encode(screen))
      )
      wire.append(
        try lengthPrefixedLANPayload(
          RemoteControlSecureEnvelope.seal(
            message,
            keys: senderKeys,
            packetType: .screen,
            counter: UInt64(counter)
          )
        )
      )
    }

    let pipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    let chunkSizes = [1, 7, 83, 409, 17, 2048, 3, 512]
    var offset = 0
    var chunkIndex = 0
    var decodedSequences: [UInt64] = []
    while offset < wire.count {
      let nextSize = min(chunkSizes[chunkIndex % chunkSizes.count], wire.count - offset)
      let chunk = Data(wire[offset ..< offset + nextSize])
      offset += nextSize
      chunkIndex += 1
      var result = try await pipeline.appendAndDrain(
        chunk: chunk,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_101 + Double(chunkIndex) / 1_000.0),
        keys: receiverKeys,
        maxCompleteScreenFrames: 4,
        maxDrainBudgetMs: 100
      )
      collectScreenSequences(from: result, into: &decodedSequences)
      XCTAssertTrue(result.secureReplayDrops.isEmpty)
      while result.hasCompletePayloadPending {
        result = try await pipeline.drain(
          keys: receiverKeys,
          maxCompleteScreenFrames: 4,
          maxDrainBudgetMs: 100
        )
        collectScreenSequences(from: result, into: &decodedSequences)
        XCTAssertTrue(result.secureReplayDrops.isEmpty)
      }
    }

    XCTAssertEqual(decodedSequences, (1...frameCount).map(UInt64.init))
  }

  func testLANRemoteSecureReceivePipelineFailsClosedWhenScreenEnvelopeBodyIsSpliced() async throws {
    func lengthPrefixedLANPayload(_ payload: Data) -> Data {
      var output = Data()
      var length = UInt32(payload.count).bigEndian
      withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
      output.append(payload)
      return output
    }
    func screenMessage(sequenceNumber: UInt64, fill: UInt8) throws -> Data {
      let screen = ScreenData(
        width: 2,
        height: 2,
        imageData: Data(repeating: fill, count: 16),
        timestamp: 1_700_000_200 + Double(sequenceNumber) / 60.0,
        format: "hevc",
        isSyncFrame: true,
        sequenceNumber: sequenceNumber
      )
      return try JSONEncoder().encode(
        RemoteMessage(type: .screenData, payload: JSONEncoder().encode(screen))
      )
    }

    let transcriptHash = Data((0..<32).map(UInt8.init))
    let outboundKey = Data(repeating: 0xC1, count: 32)
    let inboundKey = Data(repeating: 0xD2, count: 32)
    let senderKeys = SessionKeys(
      sendKey: outboundKey,
      receiveKey: inboundKey,
      negotiatedSuite: .xwing,
      role: .initiator,
      transcriptHash: transcriptHash,
      sessionId: "lan-spliced-screen-envelope"
    )
    let receiverKeys = SessionKeys(
      sendKey: inboundKey,
      receiveKey: outboundKey,
      negotiatedSuite: .xwing,
      role: .responder,
      transcriptHash: transcriptHash,
      sessionId: "lan-spliced-screen-envelope"
    )
    let firstEnvelope = try RemoteControlSecureEnvelope.seal(
      screenMessage(sequenceNumber: 1, fill: 0x11),
      keys: senderKeys,
      packetType: .screen,
      counter: 1
    )
    let secondEnvelope = try RemoteControlSecureEnvelope.seal(
      screenMessage(sequenceNumber: 2, fill: 0x22),
      keys: senderKeys,
      packetType: .screen,
      counter: 2
    )
    let headerLength = 52
    XCTAssertEqual(firstEnvelope.count, secondEnvelope.count)
    var splicedEnvelope = Data(firstEnvelope.prefix(headerLength))
    splicedEnvelope.append(secondEnvelope.dropFirst(headerLength))

    let pipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    do {
      _ = try await pipeline.appendAndDrain(
        chunk: lengthPrefixedLANPayload(splicedEnvelope),
        receivedAt: Date(timeIntervalSince1970: 1_700_000_201),
        keys: receiverKeys,
        maxCompleteScreenFrames: 4,
        maxDrainBudgetMs: 100
      )
      XCTFail("expected spliced screen envelope to fail authentication")
    } catch RemoteDesktopError.streamingFailed(let message) {
      XCTAssertTrue(message.contains("LAN secure decrypt failed bytes="))
      XCTAssertTrue(message.contains("secure envelope authentication failed packetType=2 counter=1"))
    }
  }

  func testLANRemoteSecureReceivePipelineRejectsOldSessionPacketAfterReconnectWithoutPoisoningNewSession() async throws {
    func lengthPrefixedLANPayload(_ payload: Data) -> Data {
      var output = Data()
      var length = UInt32(payload.count).bigEndian
      withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
      output.append(payload)
      return output
    }
    func pairedKeys(sessionId: String) -> (sender: SessionKeys, receiver: SessionKeys) {
      let transcriptHash = Data((0..<32).map(UInt8.init))
      let outboundKey = Data(repeating: 0x91, count: 32)
      let inboundKey = Data(repeating: 0xA2, count: 32)
      let sender = SessionKeys(
        sendKey: outboundKey,
        receiveKey: inboundKey,
        negotiatedSuite: .xwing,
        role: .initiator,
        transcriptHash: transcriptHash,
        sessionId: sessionId
      )
      let receiver = SessionKeys(
        sendKey: inboundKey,
        receiveKey: outboundKey,
        negotiatedSuite: .xwing,
        role: .responder,
        transcriptHash: transcriptHash,
        sessionId: sessionId
      )
      return (sender, receiver)
    }

    let oldKeys = pairedKeys(sessionId: "lan-reconnect-old")
    let newKeys = pairedKeys(sessionId: "lan-reconnect-new")
    let screen = ScreenData(
      width: 2,
      height: 2,
      imageData: Data([0x01, 0x02, 0x03]),
      timestamp: 1_700_000_030,
      format: "hevc",
      isSyncFrame: true,
      sequenceNumber: 30
    )
    let screenMessage = try JSONEncoder().encode(
      RemoteMessage(type: .screenData, payload: JSONEncoder().encode(screen))
    )
    let oldSessionPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        screenMessage,
        keys: oldKeys.sender,
        packetType: .screen,
        counter: 1
      )
    )
    let oldPipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    let oldResult = try await oldPipeline.appendAndDrain(
      chunk: oldSessionPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_031),
      keys: oldKeys.receiver,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertEqual(oldResult.events.count, 1)

    let newPipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    do {
      _ = try await newPipeline.appendAndDrain(
        chunk: oldSessionPacket,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_032),
        keys: newKeys.receiver,
        maxCompleteScreenFrames: 4,
        maxDrainBudgetMs: 100
      )
      XCTFail("expected old session packet to fail closed after reconnect")
    } catch RemoteDesktopError.streamingFailed(let message) {
      XCTAssertTrue(message.contains("LAN secure decrypt failed"))
      XCTAssertTrue(message.contains("session mismatch"))
    }

    let newSessionPacket = try lengthPrefixedLANPayload(
      RemoteControlSecureEnvelope.seal(
        screenMessage,
        keys: newKeys.sender,
        packetType: .screen,
        counter: 1
      )
    )
    let newResult = try await newPipeline.appendAndDrain(
      chunk: newSessionPacket,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_033),
      keys: newKeys.receiver,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertEqual(newResult.secureReplayDrops.count, 0)
    XCTAssertEqual(newResult.events.count, 1)
  }

  func testLANRemoteSecureReceivePipelineDropsSBC2ReassemblyErrorsAndRecovers() async throws {
    func lengthPrefixedLANPayload(_ payload: Data) -> Data {
      var output = Data()
      var length = UInt32(payload.count).bigEndian
      withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
      output.append(payload)
      return output
    }
    func appendUInt16(_ value: UInt16, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt64(_ value: UInt64, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func makeSBC2Chunks(payload: Data, frameId: UInt64, maxPayloadBytes: Int) -> [Data] {
      let chunkPayloadBytes = max(1, maxPayloadBytes)
      let chunkCount = max(1, (payload.count + chunkPayloadBytes - 1) / chunkPayloadBytes)
      var chunks: [Data] = []
      var offset = 0
      for chunkIndex in 0..<chunkCount {
        let end = min(offset + chunkPayloadBytes, payload.count)
        let fragment = Data(payload[offset..<end])
        var chunk = Data()
        appendUInt32(0x5342_4332, to: &chunk)
        chunk.append(1)
        let flags = UInt8(chunkIndex == 0 ? 0x01 : 0x00)
          | UInt8(chunkIndex == chunkCount - 1 ? 0x02 : 0x00)
        chunk.append(flags)
        appendUInt16(36, to: &chunk)
        appendUInt64(frameId, to: &chunk)
        appendUInt32(UInt32(chunkIndex), to: &chunk)
        appendUInt32(UInt32(chunkCount), to: &chunk)
        appendUInt32(UInt32(payload.count), to: &chunk)
        appendUInt32(UInt32(offset), to: &chunk)
        appendUInt32(UInt32(fragment.count), to: &chunk)
        chunk.append(fragment)
        chunks.append(chunk)
        offset = end
      }
      return chunks
    }

    let transcriptHash = Data((0..<32).map(UInt8.init))
    let outboundKey = Data(repeating: 0x51, count: 32)
    let inboundKey = Data(repeating: 0x62, count: 32)
    let senderKeys = SessionKeys(
      sendKey: outboundKey,
      receiveKey: inboundKey,
      negotiatedSuite: .xwing,
      role: .initiator,
      transcriptHash: transcriptHash
    )
    let receiverKeys = SessionKeys(
      sendKey: inboundKey,
      receiveKey: outboundKey,
      negotiatedSuite: .xwing,
      role: .responder,
      transcriptHash: transcriptHash
    )
    let screen = ScreenData(
      width: 2,
      height: 2,
      imageData: Data([0x01, 0x02, 0x03]),
      timestamp: 1_700_000_010,
      format: "hevc",
      isSyncFrame: true,
      sequenceNumber: 10
    )
    let screenMessage = try JSONEncoder().encode(
      RemoteMessage(type: .screenData, payload: JSONEncoder().encode(screen))
    )
    let corruptedFrameCiphertext = try RemoteControlSecureEnvelope.seal(
      screenMessage,
      keys: senderKeys,
      packetType: .screen,
      counter: 1
    )
    let corruptedChunks = makeSBC2Chunks(
      payload: corruptedFrameCiphertext,
      frameId: 10,
      maxPayloadBytes: 16
    )
    XCTAssertGreaterThan(corruptedChunks.count, 1)

    let pipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: 4096)
    let missingFirstResult = try await pipeline.appendAndDrain(
      chunk: lengthPrefixedLANPayload(corruptedChunks[1]),
      receivedAt: Date(timeIntervalSince1970: 1_700_000_011),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertTrue(missingFirstResult.events.isEmpty)
    XCTAssertEqual(missingFirstResult.sbc2Drops.count, 1)
    XCTAssertEqual(missingFirstResult.sbc2Drops.first?.reason, "missing-first-sbc2-chunk")
    XCTAssertEqual(missingFirstResult.sbc2Drops.first?.frameId, 10)
    XCTAssertEqual(missingFirstResult.sbc2Drops.first?.suppressed, false)

    let suppressedOrphanResult = try await pipeline.appendAndDrain(
      chunk: lengthPrefixedLANPayload(corruptedChunks[1]),
      receivedAt: Date(timeIntervalSince1970: 1_700_000_012),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertTrue(suppressedOrphanResult.events.isEmpty)
    XCTAssertEqual(suppressedOrphanResult.sbc2Drops.count, 1)
    XCTAssertEqual(suppressedOrphanResult.sbc2Drops.first?.reason, "missing-first-sbc2-chunk")
    XCTAssertEqual(suppressedOrphanResult.sbc2Drops.first?.frameId, 10)
    XCTAssertEqual(suppressedOrphanResult.sbc2Drops.first?.suppressed, true)

    let recoveryCiphertext = try RemoteControlSecureEnvelope.seal(
      screenMessage,
      keys: senderKeys,
      packetType: .screen,
      counter: 2
    )
    let recoveryChunk = try XCTUnwrap(
      makeSBC2Chunks(payload: recoveryCiphertext, frameId: 11, maxPayloadBytes: recoveryCiphertext.count).first
    )
    let recoveryResult = try await pipeline.appendAndDrain(
      chunk: lengthPrefixedLANPayload(recoveryChunk),
      receivedAt: Date(timeIntervalSince1970: 1_700_000_013),
      keys: receiverKeys,
      maxCompleteScreenFrames: 4,
      maxDrainBudgetMs: 100
    )
    XCTAssertTrue(recoveryResult.sbc2Drops.isEmpty)
    guard case .screen(let decodedScreen, _, _) = try XCTUnwrap(recoveryResult.events.first) else {
      XCTFail("expected recovery SBC2 frame to decode")
      return
    }
    XCTAssertEqual(decodedScreen.sequenceNumber, 10)
  }

  func testLANRemoteScreenWireUsesChunkedReassemblyAndDropsCorruptMediaFrames() throws {
    let source = try remoteDesktopManagerSource()
    let factorySource = try remoteDesktopViewerStreamConfigurationFactorySource()
    let wireSource = try remoteDesktopScreenFrameWireSource()
    let wireBody = try sourceSlice(
      from: "enum RemoteDesktopScreenFrameWire",
      to: "extension ScreenData",
      in: wireSource
    )
    let unwrapBody = try sourceSlice(
      from: "private func unwrapLANChunkedPayloadIfNeeded(",
      to:
        "private func nextLANFramedPayloadFromReceiveBuffer() throws -> (payload: Data, receivedAt: Date?)?",
      in: source
    )
    let configBody = try sourceSlice(
      from: "static func makePayload(_ input: Input)",
      to: "private static func keyFrameInterval(",
      in: factorySource
    )

    XCTAssertTrue(
      configBody.contains("activeTransportMode == .crossNetwork || activeTransportMode == .lan"))
    XCTAssertTrue(configBody.contains("? \"sbc2-chunked-v1\""))
    XCTAssertTrue(wireBody.contains("static let screenChunkHeaderByteCount = 36"))
    XCTAssertTrue(wireBody.contains("private static let screenChunkMagic: UInt32 = 0x5342_4332"))
    XCTAssertTrue(wireBody.contains("struct ChunkedPayloadReassembler"))
    XCTAssertTrue(wireBody.contains("case dropped(reason: String, frameId: UInt64?)"))
    XCTAssertTrue(wireBody.contains("case suppressed(frameId: UInt64, reason: String)"))
    XCTAssertTrue(wireBody.contains("missing-first-sbc2-chunk"))
    XCTAssertTrue(wireBody.contains("out-of-order-sbc2-chunk"))
    XCTAssertTrue(wireBody.contains("interleaved-or-restarted-sbc2-frame"))
    XCTAssertTrue(unwrapBody.contains("RemoteDesktopScreenFrameWire.startsWithChunkMagic(data)"))
    XCTAssertTrue(
      unwrapBody.contains("RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(data)"))
    XCTAssertTrue(
      unwrapBody.contains("lanScreenChunkReassembler.append(envelope, now: receivedAt)"))
    XCTAssertTrue(unwrapBody.contains("return .mediaDrop("))
    XCTAssertFalse(unwrapBody.contains("throw RemoteDesktopError.streamingFailed("))
    XCTAssertTrue(source.contains("handleLANSBC2FrameDrops"))
    XCTAssertTrue(source.contains("lan-sbc2-frame-drop reason="))
    XCTAssertTrue(source.contains("action=\\(drop.suppressed ? \"drop-orphan\" : \"request-sync\")"))
    XCTAssertTrue(source.contains("requestStreamRefreshIfNeeded("))
  }

  func testLANRemoteReceiveTelemetryExposesCadenceAndMainActorHop() throws {
    let source = try remoteDesktopManagerSource()

    XCTAssertTrue(source.contains("ios-lan-remote-rx sampleMs="))
    XCTAssertTrue(source.contains("screenWire=\\(lanInboundScreenWireFormat)"))
    XCTAssertTrue(source.contains("sbc2Frames=\\(lanInboundChunkedScreenFramesInWindow)"))
    XCTAssertTrue(source.contains("sbc2Chunks=\\(lanInboundScreenChunksInWindow)"))
    XCTAssertTrue(source.contains("maxGapMs="))
    XCTAssertTrue(source.contains("sourceSamples="))
    XCTAssertTrue(source.contains("sourceGapMaxMs="))
    XCTAssertTrue(source.contains("sourceToReadMaxMs="))
    XCTAssertTrue(source.contains("sourceToReadClock=remote-wall-clock-unsynced"))
    XCTAssertTrue(source.contains("rxFrameClock=socket-arrival"))
    XCTAssertTrue(source.contains("socketMetricClock=local-socket-arrival"))
    XCTAssertTrue(source.contains("socketToDecodeFeedSamples="))
    XCTAssertTrue(source.contains("socketToDecodeFeedMaxMs="))
    XCTAssertTrue(source.contains("socketToApplyEndSamples="))
    XCTAssertTrue(source.contains("socketToApplyEndMaxMs="))
    XCTAssertTrue(
      source.contains("scheduleFirstFrameContinuityCheck(for: streamEpoch, firstFrameAt: receiveAccountingAt)"),
      "LAN first-frame continuity checks must use the same socket-arrival clock as lastFrameArrivalAt, otherwise startup freeze detection is silently skipped."
    )
    XCTAssertTrue(source.contains("receivedFrameClock: activeTransportMode == .lan"))
    XCTAssertTrue(source.contains("? \"source-cadence+metal-delivery\""))
    XCTAssertTrue(source.contains("lanInboundSourceFrameTimesInCurrentStream"))
    XCTAssertTrue(source.contains("lanInboundMetalDeliveryTimesInCurrentStream"))
    XCTAssertTrue(source.contains("appendLANSourceFrameTimestamp(sourceTimestamp)"))
    XCTAssertTrue(source.contains("avgMainHopMs="))
    XCTAssertTrue(source.contains("maxMainHopMs="))
    XCTAssertTrue(source.contains("rawChunkGapMaxMs="))
    XCTAssertTrue(source.contains("rawChunkMainHopMaxMs="))
    XCTAssertTrue(source.contains("parser=\\(lanInboundReceiveParserMode)"))
    XCTAssertTrue(source.contains("parserBudgetMs="))
    XCTAssertTrue(source.contains("parserBudgetHits="))
    XCTAssertTrue(source.contains("readAhead=stream-parser-low-latency-256k-4frame-6ms-drain-budget"))
    XCTAssertTrue(source.contains("decodeFeed=ordered-vt-decode-metal-direct"))
    XCTAssertTrue(source.contains("decodeAttempted="))
    XCTAssertTrue(source.contains("decodeAccepted="))
    XCTAssertTrue(source.contains("decodeDropped="))
    XCTAssertTrue(source.contains("decodePendingMax="))
    XCTAssertTrue(source.contains("decodeInFlightMax="))
    XCTAssertTrue(source.contains("decodeWaitingSyncSamples="))
    XCTAssertTrue(source.contains("decodeResets="))
    XCTAssertTrue(source.contains("SkyBridgeSmokeTraceWriter.appendStatus(telemetryLine)"))
  }

  func testSmokeTraceWriterKeepsStatusFileIOOffMediaHotPaths() throws {
    let writerBody = try smokeTraceWriterSource()
    let appendStatusBody = try sourceSlice(
      from: "static func appendStatus(_ line: String)",
      to: "static func append(_ line: String)",
      in: writerBody
    )
    let mediaDiagnosticBody = try sourceSlice(
      from: "static func appendMediaDiagnostic(_ fields: [String: Any])",
      to: "private static func write(_ data: Data, to url: URL)",
      in: writerBody
    )

    XCTAssertTrue(writerBody.contains("private static let writerQueue"))
    XCTAssertTrue(writerBody.contains("private final class WriterState: @unchecked Sendable"))
    XCTAssertTrue(writerBody.contains("private var cachedHandles"))
    XCTAssertTrue(writerBody.contains("writerQueue.async"))
    XCTAssertTrue(writerBody.contains("private static func cachedHandle(for url: URL)"))
    XCTAssertFalse(appendStatusBody.contains("FileHandle"))
    XCTAssertFalse(appendStatusBody.contains("ISO8601DateFormatter().string"))
    XCTAssertFalse(mediaDiagnosticBody.contains("FileHandle"))
    XCTAssertTrue(mediaDiagnosticBody.contains("JSONSerialization.data(withJSONObject: payload"))
    XCTAssertLessThan(
      try XCTUnwrap(mediaDiagnosticBody.range(of: "writerQueue.async")?.lowerBound),
      try XCTUnwrap(
        mediaDiagnosticBody.range(of: "JSONSerialization.data(withJSONObject: payload")?.lowerBound)
    )
    XCTAssertTrue(
      mediaDiagnosticBody.contains("writerQueue.async"),
      "Smoke media diagnostics must serialize JSON and write JSONL on the writer queue, not on the remote desktop receive/render path."
    )
  }

  func testMetalSmokeCadenceUsesCommandBufferCompletionTracker() throws {
    let source = try remoteDesktopManagerSource()
    let runtimeModelsSource = try remoteDesktopRuntimeModelsSource()
    let trackerSource = try remoteDesktopSmokeCadenceTrackerSource()
    let watchdogBody = try sourceSlice(
      from: "private func startStreamContinuityWatchdog(for epoch: UInt64)",
      to: "private func scheduleFirstFrameContinuityCheck(",
      in: source
    )
    let failFastBody = try sourceSlice(
      from: "private func shouldFailFastMetalContinuityStall(reason: String, at now: Date) -> Bool",
      to: "private func handleStreamContinuityStall(reason: String) async",
      in: source
    )

    XCTAssertTrue(trackerSource.contains("final class MetalDisplaySmokeCadenceTracker"))
    XCTAssertTrue(
      source.contains("private let metalDisplaySmokeCadence = MetalDisplaySmokeCadenceTracker()"))
    XCTAssertTrue(source.contains("private typealias MetalDisplayCadenceSnapshot"))
    XCTAssertTrue(source.contains("private func metalDisplayContinuitySnapshot(at now: Date) -> MetalDisplayCadenceSnapshot"))
    XCTAssertTrue(source.contains("private func newerDisplayTime(_ lhs: Date?, _ rhs: Date?) -> Date?"))
    XCTAssertTrue(source.contains("metalDisplaySmokeCadence.reset()"))
    XCTAssertTrue(source.contains("nonisolated func recordMetalRendererDisplayedFramesForSmoke("))
    XCTAssertTrue(source.contains("metalDisplaySmokeCadence.record("))
    XCTAssertTrue(trackerSource.contains("displayedFrameAgeSamplesInCurrentStream"))
    XCTAssertTrue(trackerSource.contains("frameAgeMaxInWindowMs"))
    XCTAssertTrue(source.contains("metalFrameAgeMaxInLastTwoSecondsMs"))
    XCTAssertTrue(
      source.contains("let useMetalDisplayCadence = renderPipelineStatus == .metalRenderer"))
    XCTAssertTrue(source.contains("displayedFramesInStream: displayedFramesForSmoke"))
    XCTAssertTrue(
      source.contains("displayedFramesInLastTwoSeconds: displayedFramesInLastWindowForSmoke"))
    XCTAssertTrue(
      source.contains("lastDisplayedFrameAgeSeconds: lastDisplayedFrameTimeForSmoke.map"))
    XCTAssertTrue(watchdogBody.contains("let metalDisplaySnapshot = self.metalDisplayContinuitySnapshot(at: now)"))
    XCTAssertTrue(watchdogBody.contains("let effectiveLastDisplayedFrameTime = self.newerDisplayTime("))
    XCTAssertTrue(watchdogBody.contains("effectiveLastDisplayedFrameTime == nil"))
    XCTAssertTrue(watchdogBody.contains("lastFrameArrivalAt > effectiveLastDisplayedFrameTime"))
    XCTAssertTrue(watchdogBody.contains("lastDecodedFrameTime > effectiveLastDisplayedFrameTime"))
    XCTAssertTrue(failFastBody.contains("let metalDisplaySnapshot = metalDisplayContinuitySnapshot(at: now)"))
    XCTAssertTrue(source.contains("metalDisplaySnapshot: MetalDisplayCadenceSnapshot? = nil"))
    XCTAssertTrue(source.contains("let displayedFrames = max("))
    XCTAssertTrue(source.contains("metalDisplaySnapshot?.displayedFramesInWindow ?? 0"))
    XCTAssertTrue(source.contains("continuityWindowRates(at: now, metalDisplaySnapshot: metalDisplaySnapshot)"))
    XCTAssertTrue(runtimeModelsSource.contains("let effectiveDisplayedAge = ["))
    XCTAssertTrue(runtimeModelsSource.contains("let displayStaleEnough = effectiveDisplayedAge.map { $0 >= 2.0 } ?? false"))
    XCTAssertTrue(runtimeModelsSource.contains("input.metalDisplayedFramesInStream > 0"))
    XCTAssertTrue(runtimeModelsSource.contains("input.metalDisplayedFramesInWindow > 0"))
    XCTAssertTrue(runtimeModelsSource.contains("(!hasRendererInput || !displayStaleEnough)"))
    XCTAssertTrue(source.contains("metalDisplayedWindow="))
    XCTAssertTrue(source.contains("metalDisplayAgeMs="))
  }

  func testMetalContinuityFailFastPolicyDefersProgressAndLowInputCadence() {
    func evaluate(
      reason: String = "frames-decoding-without-display",
      displayedFramesInStatsWindow: Int = 0,
      displayedFramesInCurrentStream: Int = 10,
      observedDisplayedFramesWatermark: Int = 10,
      metalDisplayedFramesInWindow: Int = 0,
      metalDisplayedFramesInStream: Int = 0,
      observedMetalDisplayedFramesWatermark: Int = 0,
      displayedAgeSeconds: TimeInterval? = 3.0,
      metalDisplayedAgeSeconds: TimeInterval? = nil,
      arrivalAgeSeconds: TimeInterval? = 3.0,
      decodedAgeSeconds: TimeInterval? = 0.5,
      enqueueAgeSeconds: TimeInterval? = 0.5,
      decodedFramesInStatsWindow: Int = 4,
      rendererEnqueuedFramesInStatsWindow: Int = 4,
      inputFPS: Double = 59.0,
      inputFailureThresholdFPS: Double = 57.0
    ) -> RemoteDesktopMetalContinuityStallPolicyResult {
      RemoteDesktopMetalContinuityStallPolicy.evaluate(
        RemoteDesktopMetalContinuityStallPolicyInput(
          reason: reason,
          isMetalRenderer: true,
          hasPresentationOwner: true,
          activeMetalConsumerCount: 1,
          displayedFramesInStatsWindow: displayedFramesInStatsWindow,
          displayedFramesInCurrentStream: displayedFramesInCurrentStream,
          observedDisplayedFramesWatermark: observedDisplayedFramesWatermark,
          metalDisplayedFramesInWindow: metalDisplayedFramesInWindow,
          metalDisplayedFramesInStream: metalDisplayedFramesInStream,
          observedMetalDisplayedFramesWatermark: observedMetalDisplayedFramesWatermark,
          displayedAgeSeconds: displayedAgeSeconds,
          metalDisplayedAgeSeconds: metalDisplayedAgeSeconds,
          arrivalAgeSeconds: arrivalAgeSeconds,
          decodedAgeSeconds: decodedAgeSeconds,
          enqueueAgeSeconds: enqueueAgeSeconds,
          decodedFramesInStatsWindow: decodedFramesInStatsWindow,
          rendererEnqueuedFramesInStatsWindow: rendererEnqueuedFramesInStatsWindow,
          inputFPS: inputFPS,
          inputFailureThresholdFPS: inputFailureThresholdFPS
        )
      )
    }

    XCTAssertEqual(
      evaluate(displayedFramesInStatsWindow: 1).decision,
      .deferStall(classification: "display-progress-present")
    )

    let totalProgress = evaluate(
      displayedFramesInCurrentStream: 12,
      observedDisplayedFramesWatermark: 10
    )
    XCTAssertEqual(totalProgress.decision, .deferStall(classification: "display-total-progress-present"))
    XCTAssertEqual(totalProgress.observedDisplayedFramesWatermark, 12)

    XCTAssertEqual(
      evaluate(inputFPS: 10.5, inputFailureThresholdFPS: 57.0).decision,
      .deferStall(classification: "input-cadence-below-display-failure-threshold")
    )

    XCTAssertEqual(
      evaluate(
        arrivalAgeSeconds: 0.5,
        decodedAgeSeconds: 3.0,
        enqueueAgeSeconds: 3.0,
        inputFPS: 0
      ).decision,
      .deferStall(classification: "input-cadence-window-reset-below-display-failure-threshold")
    )

    XCTAssertEqual(
      evaluate(
        displayedAgeSeconds: 3.0,
        decodedAgeSeconds: 0.5,
        enqueueAgeSeconds: 0.5,
        inputFPS: 59.0,
        inputFailureThresholdFPS: 57.0
      ).decision,
      .failFast
    )
  }

  func testStrictRemoteDesktopMediaPolicyRejectsStaticRenderFallbacks() throws {
    let source = try remoteDesktopManagerSource()
    let runtimeModelsSource = try remoteDesktopRuntimeModelsSource()
    let cgImageFallbackBody = try sourceSlice(
      from: "private func activateCGImageFallbackForDecodedVideo()",
      to: "private func maybeRestoreMetalRendererAfterStableSampleBuffer",
      in: source
    )
    let decodedOutputBody = try sourceSlice(
      from: "private func applyDecodedOutput(",
      to: "private func startDecodeLoopIfNeeded()",
      in: source
    )
    let cgImagePixelBufferBranch = try sourceSlice(
      from: "case .cgImage:",
      to: "case .sampleBuffer(let frame):",
      in: decodedOutputBody
    )
    let sampleBufferPixelBufferBranch = try sourceSlice(
      from: "case .sampleBuffer:",
      to: "case .cgImage:",
      in: decodedOutputBody
    )
    let sampleBufferDecodedBranch = try sourceSlice(
      from: "case .sampleBuffer(let frame):",
      to: "consecutiveDecodeMisses = 0",
      in: decodedOutputBody
    )
    let continuityBody = try sourceSlice(
      from: "private func handleStreamContinuityStall(reason: String) async",
      to: "func handleVideoRendererDidEnqueueFrame(",
      in: source
    )

    XCTAssertTrue(source.contains("private var remoteDesktopRenderFallbackForbidden"))
    XCTAssertTrue(source.contains("private func failFastRemoteDesktopRenderMainPath("))
    XCTAssertTrue(source.contains("private func recoverLANMetalFeedBackpressureSaturation("))
    XCTAssertTrue(source.contains("reason=metal-feed-backpressure-saturated classification=renderer-queue-backpressure"))
    XCTAssertTrue(source.contains("render-main-path-failed"))
    let renderFailFastBody = try sourceSlice(
      from: "private func failFastRemoteDesktopRenderMainPath(",
      to: "private func startStreamContinuityWatchdog(",
      in: source
    )
    let metalFeedRejectionBody = try sourceSlice(
      from: "let reason = \"metal-feed-renderer-rejected consumers=\\(deliveryResult.consumerCount)",
      to: "lanInboundScreenDeliveryDeliveredInWindow += 1",
      in: source
    )
    XCTAssertTrue(cgImageFallbackBody.contains("cgimage-fallback-forbidden"))
    XCTAssertTrue(metalFeedRejectionBody.contains("if deliveryResult.hasQueueBackpressureRejection"))
    XCTAssertTrue(metalFeedRejectionBody.contains("recoverLANMetalFeedBackpressureSaturation(reason: reason"))
    XCTAssertTrue(cgImageFallbackBody.contains("failFastRemoteDesktopRenderMainPath("))
    XCTAssertFalse(cgImageFallbackBody.contains("updateRenderPipeline(.sampleBufferDisplayLayer)"))
    XCTAssertTrue(decodedOutputBody.contains("static-image-fallback-forbidden"))
    XCTAssertTrue(
      decodedOutputBody.contains(
        "let shouldCacheFrozenFrame = independentlyDecodableFrame && !remoteDesktopRenderFallbackForbidden"
      ))
    XCTAssertTrue(
      decodedOutputBody.contains(
        "let frozenCandidate = shouldCacheFrozenFrame ? makeCGImage(from: frame) : nil"))
    XCTAssertFalse(
      decodedOutputBody.contains(
        "let frozenCandidate = independentlyDecodableFrame ? makeCGImage(from: frame) : nil"),
      "Strict Metal sessions must not spend MainActor time preparing a still-image fallback cache that fail-fast policy forbids."
    )
    XCTAssertTrue(
      cgImagePixelBufferBranch.contains("guard !remoteDesktopRenderFallbackForbidden else"))
    XCTAssertTrue(cgImagePixelBufferBranch.contains("cgimage-pixelbuffer-fallback-forbidden"))
    XCTAssertTrue(cgImagePixelBufferBranch.contains("await failFastRemoteDesktopRenderMainPath("))
    XCTAssertTrue(
      sampleBufferPixelBufferBranch.contains("guard !remoteDesktopRenderFallbackForbidden else"))
    XCTAssertTrue(sampleBufferPixelBufferBranch.contains("samplebuffer-pixelbuffer-fallback-forbidden"))
    XCTAssertTrue(sampleBufferPixelBufferBranch.contains("attemptedFallback: \"sampleBufferDisplayLayer\""))
    XCTAssertTrue(
      sampleBufferDecodedBranch.contains("guard !remoteDesktopRenderFallbackForbidden else"))
    XCTAssertTrue(sampleBufferDecodedBranch.contains("samplebuffer-displaylayer-fallback-forbidden"))
    XCTAssertTrue(sampleBufferDecodedBranch.contains("attemptedFallback: \"sampleBufferDisplayLayer\""))
    XCTAssertTrue(continuityBody.contains("attemptedFallback: \"sampleBufferDisplayLayer\""))
    XCTAssertTrue(continuityBody.contains("attemptedFallback: \"stillImageFallback\""))
    XCTAssertTrue(source.contains("fallbackResult=forbidden"))
    XCTAssertTrue(source.contains("fallbackResult=not-attempted"))
    XCTAssertTrue(renderFailFastBody.contains("transportAction=preserve"))
    XCTAssertTrue(renderFailFastBody.contains("audioAction=preserve"))
    XCTAssertTrue(renderFailFastBody.contains("failed stage=remote-desktop phase=render_main_path"))
    XCTAssertTrue(renderFailFastBody.contains("requestStreamRefreshIfNeeded("))
    XCTAssertFalse(
      renderFailFastBody.contains("handleTransportFailure"),
      "Render fail-fast must fail the render main path without closing the LAN transport and realtime audio receiver."
    )
    XCTAssertFalse(renderFailFastBody.contains("stopRealtimeMediaAudioReceiver"))
    XCTAssertFalse(renderFailFastBody.contains("crossNetwork.disconnect"))
    for forbiddenTeardown in [
      "teardownRemoteAudioPlayback",
      "activeTransportMode = .none",
      "isStreaming = false",
      "networkConnection?.cancel",
      "resetLANReceiveParserState",
      "clearLANSecureChannelState"
    ] {
      XCTAssertFalse(
        renderFailFastBody.contains(forbiddenTeardown),
        "Render fail-fast must preserve live transport/audio state, not run teardown path \(forbiddenTeardown)."
      )
    }
    XCTAssertFalse(
      continuityBody.contains("handleTransportFailure"),
      "Continuity stalls must stay on render recovery/fail-fast paths instead of closing transport."
    )
    XCTAssertFalse(
      continuityBody.contains("stopRealtimeMediaAudioReceiver"),
      "Continuity stalls must not stop realtime audio while video asks for a sync frame."
    )
    XCTAssertFalse(
      continuityBody.contains("crossNetwork.disconnect"),
      "Continuity stalls must not disconnect the cross-network session."
    )
    XCTAssertTrue(metalFeedRejectionBody.contains("transportAction=preserve"))
    XCTAssertTrue(metalFeedRejectionBody.contains("audioAction=preserve"))
    XCTAssertTrue(metalFeedRejectionBody.contains("failFastRemoteDesktopRenderMainPath("))
    XCTAssertTrue(metalFeedRejectionBody.contains("attemptedFallback: \"metalVideoFrameFeed\""))
    XCTAssertFalse(
      metalFeedRejectionBody.contains("handleTransportFailure"),
      "Renderer rejection is a render/feed failure and must not close transport or realtime audio."
    )
    XCTAssertTrue(source.contains("private func shouldFailFastMetalContinuityStall(reason: String, at now: Date) -> Bool"))
    XCTAssertTrue(source.contains("RemoteDesktopMetalContinuityStallPolicy.evaluate("))
    XCTAssertTrue(runtimeModelsSource.contains("display-progress-present"))
    XCTAssertTrue(runtimeModelsSource.contains("display-total-progress-present"))
    XCTAssertTrue(runtimeModelsSource.contains("post-first-display-not-renderer-failure"))
    XCTAssertTrue(runtimeModelsSource.contains("remote-view-not-presented"))
    XCTAssertTrue(runtimeModelsSource.contains("metal-consumer-not-active"))
    XCTAssertTrue(runtimeModelsSource.contains("decoded-without-renderer-enqueue"))
    XCTAssertTrue(runtimeModelsSource.contains("arrived-without-renderer-enqueue"))
    XCTAssertTrue(source.contains("presentationOwners=\\(presentationOwners) metalConsumers=\\(metalConsumers)"))
    XCTAssertTrue(source.contains("hasPresentationOwner: !activePresentationOwnerTokens.isEmpty"))
    XCTAssertTrue(source.contains("activeMetalConsumerCount: metalVideoFrameFeed.activeConsumerCount"))
    XCTAssertTrue(runtimeModelsSource.contains("let hasRendererEnqueue = input.rendererEnqueuedFramesInStatsWindow > 0 || hasRecentEnqueuedInput"))
    XCTAssertTrue(runtimeModelsSource.contains("input.reason == \"frames-decoding-without-display\", !hasRendererEnqueue"))
    XCTAssertTrue(runtimeModelsSource.contains("input.reason == \"frames-arriving-without-display\", !hasRendererEnqueue"))
    XCTAssertTrue(runtimeModelsSource.contains("if !hasDisplayedFrame,"))
    XCTAssertTrue(runtimeModelsSource.contains("startup-renderer-input-not-stale"))
    XCTAssertTrue(runtimeModelsSource.contains("startup-input-cadence-below-display-failure-threshold"))
    XCTAssertTrue(source.contains("private func metalContinuityInputFailureThresholdFPS() -> Double"))
    XCTAssertTrue(
      source.contains("lastSentStreamConfiguration?.targetFrameRate ?? viewerSettings.targetFrameRate"))
    XCTAssertTrue(runtimeModelsSource.contains("input.inputFPS > 0, input.inputFPS < input.inputFailureThresholdFPS"))
    XCTAssertTrue(source.contains("inputFailureThresholdFPS="))
    XCTAssertTrue(runtimeModelsSource.contains("input.inputFPS == 0"))
    XCTAssertTrue(runtimeModelsSource.contains("hasRecentArrivingInput || hasRecentDecodedInput || hasRecentEnqueuedInput"))
    XCTAssertTrue(source.contains("input-cadence-window-reset-below-display-failure-threshold"))
    XCTAssertTrue(source.contains("startup-input-cadence-window-reset-below-display-failure-threshold"))
    XCTAssertTrue(source.contains("arrivalAgeMs="))
    XCTAssertTrue(source.contains("private func shouldRequestStreamRefreshForDeferredMetalContinuityStall"))
    XCTAssertTrue(source.contains("case \"display-progress-present\","))
    XCTAssertTrue(source.contains("\"input-cadence-below-display-failure-threshold\","))
    XCTAssertTrue(source.contains("\"startup-input-cadence-below-display-failure-threshold\","))
    XCTAssertTrue(source.contains("\"input-cadence-window-reset-below-display-failure-threshold\","))
    XCTAssertTrue(source.contains("\"startup-input-cadence-window-reset-below-display-failure-threshold\","))
    XCTAssertTrue(source.contains("\"display-total-progress-present\","))
    XCTAssertTrue(source.contains("streamRefresh=suppressed"))
    XCTAssertTrue(source.contains("streamRefresh=requested"))
    XCTAssertTrue(source.contains("attemptedFallback=none fallbackResult=not-attempted streamRefresh="))
    XCTAssertTrue(
      runtimeModelsSource.contains(
        "hasDisplayedFrame,\n           (input.reason == \"frames-arriving-without-display\""
      ),
      "Post-first-display Metal continuity stalls may be deferred, but first-display failures must not be masked by an ungrouped reason predicate."
    )
    XCTAssertTrue(source.contains("reason: \"metal-continuity-deferred-\\(reason)\""))

    let guardIndex = try XCTUnwrap(
      cgImagePixelBufferBranch.range(of: "guard !remoteDesktopRenderFallbackForbidden else")?
        .lowerBound
    )
    let stillImageIndex = try XCTUnwrap(
      cgImagePixelBufferBranch.range(of: "updateRenderPipeline(.stillImageFallback)")?.lowerBound
    )
    XCTAssertLessThan(
      guardIndex,
      stillImageIndex,
      "Strict media mode must reject CGImage pixel-buffer fallback before it can mark the pipeline as stillImageFallback."
    )
  }

  func testLANStreamRefreshIsThrottledUnderDecodeBackpressure() throws {
    let source = try remoteDesktopManagerSource()
    let body = try sourceSlice(
      from: "private func requestStreamRefreshIfNeeded(",
      to: "private func handleCodecGovernanceEvent(",
      in: source
    )

    XCTAssertTrue(
      source.contains("private let lanStreamRefreshMinimumInterval: TimeInterval = 2.0"),
      "LAN/P2P decode backpressure must not send refresh tokens several times per second."
    )
    XCTAssertTrue(
      body.contains(
        "activeTransportMode == .lan\n            ? max(minimumInterval, lanStreamRefreshMinimumInterval)"
      ),
      "LAN/P2P stream refreshes should enforce the shared minimum interval even when callers ask for 0.25s."
    )
    XCTAssertTrue(
      source.contains(
        "requestStreamRefreshIfNeeded(reason: \"decode-queue-overflow\", minimumInterval: 0.25)"),
      "The decode overflow recovery path should still request a refresh, but the LAN throttle must bound it."
    )
  }

  func testRealtimeAudioStopReasonIsLoggedInsteadOfMaskedAsJitter() throws {
    let managerSource = try remoteDesktopManagerSource()
    let audioSource = try realtimeMediaAudioSource()

    XCTAssertTrue(
      managerSource.contains("stopRealtimeMediaAudioReceiver(reason: \"transport-failure:\\(errorMessage)\")"),
      "Video transport failures must close realtime audio with an explicit reason instead of leaving zero-rx to look like jitter."
    )
    XCTAssertTrue(
      managerSource.contains("audioRxStop session=\\(receiverSessionId) reason=\\(reason)"),
      "Realtime audio receiver lifecycle logs must carry close reason and session."
    )
    XCTAssertTrue(
      audioSource.contains("func close(reason: String = \"unspecified\") async"),
      "The iOS realtime audio renderer must accept a close reason for zero-rx cascade diagnostics."
    )
    XCTAssertTrue(
      audioSource.contains("audioRxRendererClose session=\\(sessionId) reason=\\(reason)"),
      "Renderer close telemetry must include the session and reason."
    )
    XCTAssertTrue(
      audioSource.contains("datagramsSeen=\\(datagramsSeen)"),
      "Renderer close telemetry must show whether UDP datagrams ever reached the receiver."
    )
    XCTAssertTrue(
      audioSource.contains("source=\\(sourceEndpoint)"),
      "Renderer close telemetry must include the authenticated source endpoint when one was observed."
    )
    for field in [
      "authRejected=\\(authRejected)",
      "sessionHashRejected=\\(sessionHashRejected)",
      "replayRejected=\\(replayRejected)",
      "sourceRejected=\\(sourceRejected)",
      "sourceMigrated=\\(sourceMigrated)",
      "jitterLate=\\(jitterLate)",
      "jitterDuplicate=\\(jitterDuplicate)",
      "jitterEvicted=\\(jitterEvicted)",
      "playbackDropped=\\(playbackDropped)",
      "lateOrDuplicate=\\(lateOrDuplicate)"
    ] {
      XCTAssertTrue(
        audioSource.contains(field),
        "Renderer close telemetry must include \(field) so packet loss, auth failure, source mismatch, and playout drops are distinguishable."
      )
    }
    XCTAssertTrue(
      audioSource.contains("probable=zero-rx-after-playback"),
      "Zero-rx after playback must stay visible as a transport starvation diagnosis."
    )
    XCTAssertTrue(
      audioSource.contains("action=no-jitter-adaptation reason=transport-starved"),
      "Receiver starvation must not be hidden behind jitter growth."
    )
    XCTAssertTrue(
      audioSource.contains("window.datagramsSeen == 0,\n           window.received == 0"),
      "Jitter adaptation must explicitly gate zero-datagram receive windows."
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
      ),
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

  func testLANRemoteControlTrustResolverIgnoresReverificationRequiredRecords() {
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
        id: "id:peer-mac",
        name: "Lza的MacBook Pro",
        platform: .macOS,
        ipAddress: "192.168.1.20",
        protocolSigningAlgorithm: "ML-DSA-65",
        protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
        currentDeviceId: "id:peer-mac",
        knownDeviceIds: ["bonjour:lza的macbook pro@local.", "id:peer-mac"],
        currentPathLifecycleState: .reverificationRequired
      )
    ]

    XCTAssertEqual(
      LANRemoteControlTrustResolver.resolve(
        device: device,
        trustedPeerId: "id:peer-mac",
        trustedDevices: trustedDevices
      ),
      .missing
    )
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
      ),
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
      ),
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
      XCTFail(
        "Expected fingerprint-bearing record to win equivalent duplicate resolution, got \(resolution)"
      )
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
  func testOfflineQueueCleanupRemovesExpiredPendingAndFailedMessages() throws {
    let queue = OfflineMessageQueue.shared
    try queue.clear()
    defer {
      do {
        try queue.clear()
      } catch {
        XCTFail("Failed to clear offline queue after test: \(error)")
      }
    }

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

    try queue.enqueue(expiredPending)
    try queue.enqueue(expiredFailed)
    try queue.enqueue(liveFailed)

    for _ in 0..<3 {
      try queue.markAsFailed(expiredFailed.id)
      try queue.markAsFailed(liveFailed.id)
    }

    XCTAssertEqual(queue.totalCount, 3)

    try queue.cleanupExpiredMessages()

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

  func testConnectableAddressCanonicalizerPrefersRoutableLANOverLinkLocalForMediaRoutes() {
    XCTAssertTrue(ConnectableAddressCanonicalizer.isLinkLocal("fe80::468:f5a1:462b:29d3%bridge100"))
    XCTAssertTrue(ConnectableAddressCanonicalizer.isLinkLocal("169.254.10.20"))
    XCTAssertTrue(ConnectableAddressCanonicalizer.isRoutableLANAddress("192.168.31.20"))
    XCTAssertFalse(ConnectableAddressCanonicalizer.prefersPeerToPeer(for: "192.168.31.20"))
    XCTAssertFalse(ConnectableAddressCanonicalizer.prefersPeerToPeer(for: "ipad-pro.local"))
    XCTAssertTrue(
      ConnectableAddressCanonicalizer.prefersPeerToPeer(for: "fe80::468:f5a1:462b:29d3%bridge100"))
    XCTAssertEqual(
      ConnectableAddressCanonicalizer.bestLANAddress([
        "fe80::468:f5a1:462b:29d3%bridge100",
        "192.168.31.20",
      ]),
      "192.168.31.20"
    )
  }

  func testRemoteDesktopLANRoutePolicyRejectsUnverifiedAndPeerToPeerRoutes() {
    let routableHost = NWEndpoint.hostPort(
      host: NWEndpoint.Host("192.168.31.20"),
      port: NWEndpoint.Port(integerLiteral: 9527)
    )
    let linkLocalHost = NWEndpoint.hostPort(
      host: NWEndpoint.Host("fe80::468:f5a1:462b:29d3%bridge100"),
      port: NWEndpoint.Port(integerLiteral: 9527)
    )
    let bonjour = NWEndpoint.service(
      name: "Lza's MacBook Pro",
      type: "_skybridge-remote._tcp",
      domain: "local.",
      interface: nil
    )

    XCTAssertEqual(RemoteDesktopLANRoutePolicy.routeAddressClass(for: routableHost), "lan-direct")
    XCTAssertEqual(RemoteDesktopLANRoutePolicy.routeAddressClass(for: bonjour), "bonjour-service")
    XCTAssertEqual(RemoteDesktopLANRoutePolicy.routeAddressClass(for: nil), "unresolved")
    XCTAssertFalse(RemoteDesktopLANRoutePolicy.shouldIncludePeerToPeer(for: routableHost))
    XCTAssertTrue(RemoteDesktopLANRoutePolicy.shouldIncludePeerToPeer(for: linkLocalHost))
    XCTAssertTrue(RemoteDesktopLANRoutePolicy.routePrefersPeerToPeer(for: linkLocalHost))
    XCTAssertEqual(
      RemoteDesktopLANRoutePolicy.statusToken("host 192.168.31.20"), "host_192.168.31.20")

    XCTAssertNil(
      RemoteDesktopLANRoutePolicy.resolvedRouteRejection(
        requestedEndpoint: routableHost,
        resolvedEndpoint: routableHost
      )
    )
    XCTAssertEqual(
      RemoteDesktopLANRoutePolicy.resolvedRouteRejection(
        requestedEndpoint: linkLocalHost,
        resolvedEndpoint: nil
      ),
      "resolved peer-to-peer remote route rejected: requested=\(String(describing: linkLocalHost))"
    )
    XCTAssertEqual(
      RemoteDesktopLANRoutePolicy.resolvedRouteRejection(
        requestedEndpoint: bonjour,
        resolvedEndpoint: nil
      ),
      "unverified Bonjour remote route rejected: requested=\(String(describing: bonjour))"
    )
    XCTAssertEqual(
      RemoteDesktopLANRoutePolicy.resolvedRouteRejection(
        requestedEndpoint: bonjour,
        resolvedEndpoint: linkLocalHost
      ),
      "resolved peer-to-peer remote route rejected: requested=\(String(describing: bonjour)) resolved=\(String(describing: linkLocalHost))"
    )
  }

  func testLANMediaRoutesPreferRoutableHostPortBeforePeerToPeerFallback() throws {
    let remoteDesktopSource = try remoteDesktopManagerSource()
    let remoteDesktopRoutePolicySource = try remoteDesktopLANRoutePolicySource()
    let remoteDesktopEndpointFactorySource = try remoteDesktopLANEndpointCandidateFactorySource()
    let remoteDesktopDeviceResolverSource = try remoteDesktopDeviceResolutionCoordinatorSource()
    let remoteEndpointFactoryBody = try sourceSlice(
      from: "static func makePlan(",
      to: "private static func appendHostEndpoint(",
      in: remoteDesktopEndpointFactorySource
    )
    let remoteLanDirect = try XCTUnwrap(
      remoteEndpointFactoryBody.range(of: "ConnectableAddressCanonicalizer.isRoutableLANAddress")?
        .lowerBound
    )
    let remoteBonjour = try XCTUnwrap(
      remoteEndpointFactoryBody.range(of: "if let bonjourService")?.lowerBound
    )
    let remoteLinkLocal = try XCTUnwrap(
      remoteEndpointFactoryBody.range(of: "ConnectableAddressCanonicalizer.isLinkLocal")?.lowerBound
    )
    let remoteActivePeer = try XCTUnwrap(
      remoteEndpointFactoryBody.range(of: "if let activePeerAddress")?.lowerBound
    )

    XCTAssertLessThan(remoteLanDirect, remoteBonjour)
    XCTAssertLessThan(remoteBonjour, remoteLinkLocal)
    XCTAssertLessThan(remoteLinkLocal, remoteActivePeer)
    XCTAssertTrue(remoteDesktopDeviceResolverSource.contains("RemoteDesktopLANEndpointCandidateFactory.makePlan"))
    XCTAssertTrue(remoteDesktopDeviceResolverSource.contains("SkyBridgeLogger.shared.info(log.message)"))
    XCTAssertTrue(remoteDesktopDeviceResolverSource.contains("plan.missingActivePeerPortHost"))
    XCTAssertTrue(
      remoteDesktopSource.contains(
        "parameters.includePeerToPeer = RemoteDesktopLANRoutePolicy.shouldIncludePeerToPeer(for: endpoint)"
      ))
    XCTAssertTrue(
      remoteDesktopRoutePolicySource.contains(
        "guard case .hostPort(let host, _) = endpoint else { return false }"))
    XCTAssertTrue(remoteDesktopRoutePolicySource.contains("static func resolvedRouteRejection("))
    XCTAssertTrue(
      remoteDesktopRoutePolicySource.contains("unverified Bonjour remote route rejected"))
    XCTAssertTrue(
      remoteDesktopRoutePolicySource.contains("resolved peer-to-peer remote route rejected"))
    XCTAssertTrue(remoteDesktopSource.contains("ios-lan-remote-route candidate="))
    XCTAssertTrue(remoteDesktopSource.contains("ios-lan-remote-route-ready requestedAddressClass="))
    XCTAssertTrue(
      remoteDesktopSource.contains(
        "resolvedAddressClass=\\(RemoteDesktopLANRoutePolicy.routeAddressClass(for: resolvedEndpoint))"
      ))
    XCTAssertTrue(
      remoteDesktopSource.contains(
        "resolvedPeerToPeer=\\(RemoteDesktopLANRoutePolicy.routePrefersPeerToPeer(for: resolvedEndpoint))"
      ))
    XCTAssertTrue(
      remoteDesktopSource.contains("addressClass=\\(addressClass) peerToPeer=\\(peerToPeer)"))
    XCTAssertTrue(remoteDesktopSource.contains("let routeLine = \"ios-lan-remote-route candidate="))
    XCTAssertTrue(remoteDesktopSource.contains("SkyBridgeLogger.shared.info(routeLine)"))
    XCTAssertTrue(remoteDesktopSource.contains("SkyBridgeSmokeTraceWriter.appendStatus(routeLine)"))

    let fileTransferSource = try iosFileTransferManagerSource()
    let fileTransferRoutePolicySource = try iosFileTransferLANRoutePolicySource()
    let fileTransferBody = try sourceSlice(
      from: "private func makeTransferEndpointCandidates",
      to: "private func hasAdvertisedTransferService",
      in: fileTransferSource
    )
    let transferLanDirect = try XCTUnwrap(
      fileTransferBody.range(of: "ConnectableAddressCanonicalizer.isRoutableLANAddress")?.lowerBound
    )
    let transferBonjour = try XCTUnwrap(
      fileTransferBody.range(of: "transferBonjourServiceIdentity")?.lowerBound
    )
    let transferLinkLocal = try XCTUnwrap(
      fileTransferBody.range(of: "ConnectableAddressCanonicalizer.isLinkLocal")?.lowerBound
    )
    let transferActivePeer = try XCTUnwrap(
      fileTransferBody.range(of: "activePeerTransferAddress")?.lowerBound
    )

    XCTAssertLessThan(transferLanDirect, transferBonjour)
    XCTAssertLessThan(transferBonjour, transferLinkLocal)
    XCTAssertLessThan(transferLinkLocal, transferActivePeer)
    XCTAssertTrue(
      fileTransferSource.contains(
        "parameters.includePeerToPeer = FileTransferLANRoutePolicy.shouldIncludePeerToPeer(for: endpoint)"))
    XCTAssertFalse(
      fileTransferSource.contains(
        "parameters.includePeerToPeer = Self.shouldIncludePeerToPeer(for: endpoint)"))
    XCTAssertTrue(
      fileTransferRoutePolicySource.contains(
        "guard case .hostPort(let host, _) = endpoint else { return false }"))
    XCTAssertTrue(fileTransferRoutePolicySource.contains("static func resolvedRouteRejection("))
    XCTAssertFalse(fileTransferSource.contains("private static func resolvedRouteRejection("))
    XCTAssertTrue(fileTransferRoutePolicySource.contains("unverified Bonjour file-transfer route rejected"))
    XCTAssertTrue(fileTransferRoutePolicySource.contains("resolved peer-to-peer file-transfer route rejected"))
    XCTAssertTrue(fileTransferSource.contains("connect_route_rejected"))
    XCTAssertTrue(fileTransferSource.contains("file-transfer-route-ready requestedAddressClass="))
    XCTAssertTrue(
      fileTransferSource.contains(
        "resolvedAddressClass=\\(FileTransferLANRoutePolicy.routeAddressClass(for: resolvedEndpoint))"))
    XCTAssertFalse(
      fileTransferSource.contains(
        "resolvedAddressClass=\\(Self.routeAddressClass(for: resolvedEndpoint))"))
    XCTAssertTrue(
      fileTransferSource.contains(
        "resolvedPeerToPeer=\\(FileTransferLANRoutePolicy.routePrefersPeerToPeer(for: resolvedEndpoint))"))
    XCTAssertFalse(
      fileTransferSource.contains(
        "resolvedPeerToPeer=\\(Self.routePrefersPeerToPeer(for: resolvedEndpoint))"))
    XCTAssertTrue(fileTransferSource.contains("file-transfer-route candidate="))
    XCTAssertTrue(fileTransferSource.contains("tcp.noDelay = true"))

    let discoverySource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
    )
    XCTAssertTrue(
      discoverySource.contains("extractIPAddress(from: endpoint, txtRecord: txtRecord)"))
    XCTAssertTrue(
      discoverySource.contains(
        "txtValue(txtRecord, \"lanHost\", \"host\", \"ip\", \"ipv4\", \"address\", \"hostAddress\")"
      ))
    XCTAssertTrue(
      discoverySource.contains(
        "\"lanHost\", \"lanIPv4\", \"lanIPv6\", \"host\", \"ip\", \"ipv4\", \"ipv6\", \"address\", \"hostAddress\""
      ))
    XCTAssertTrue(discoverySource.contains("ConnectableAddressCanonicalizer.bestLANAddress(["))
    XCTAssertTrue(discoverySource.contains("避免 Bonjour service 解析退回 link-local"))
  }

  func testIOSP2PAdvertisingOnlyBecomesVisibleAfterListenerReady() throws {
    let discoverySource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
    )

    XCTAssertTrue(discoverySource.contains("advertisingStartupContinuation"))
    XCTAssertTrue(discoverySource.contains("public struct AdvertisingReadinessSnapshot"))
    XCTAssertTrue(discoverySource.contains("public var advertisingReadinessSnapshot"))
    XCTAssertTrue(discoverySource.contains("handlerInstalled"))
    XCTAssertTrue(discoverySource.contains("actualPort"))
    XCTAssertTrue(discoverySource.contains("withTaskCancellationHandler"))
    XCTAssertTrue(discoverySource.contains("finishAdvertisingStartup(.failure(CancellationError()))"))
    XCTAssertTrue(discoverySource.contains("activeListener.start(queue: queue)"))
    XCTAssertTrue(discoverySource.contains("case .ready:"))
    XCTAssertTrue(discoverySource.contains("advertisingActualPort = activeListener.port?.rawValue"))
    XCTAssertTrue(discoverySource.contains("appendListenerStatus(\n                \"ready service="))
    XCTAssertTrue(discoverySource.contains("isAdvertising = true"))
    XCTAssertTrue(discoverySource.contains("finishAdvertisingStartup(.success(()))"))
    XCTAssertTrue(discoverySource.contains("AdvertisingStartupError.timedOut"))
    XCTAssertFalse(
      discoverySource.contains("listener?.start(queue: queue)\n        isAdvertising = true"),
      "iOS P2P advertising must not become visible until NWListener reports ready."
    )
  }

  func testIOSP2PForegroundListeningDoesNotSwallowListenerStartupFailures() throws {
    let p2pManagerSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
    )
    let appSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift"
    )

    XCTAssertFalse(
      p2pManagerSource.contains("if discoveryManager.isAdvertising {\n            isListening = true\n            return"),
      "P2PConnectionManager must not treat a discovery flag alone as full listener readiness."
    )
    XCTAssertTrue(p2pManagerSource.contains("let beforeStart = discoveryManager.advertisingReadinessSnapshot"))
    XCTAssertTrue(p2pManagerSource.contains("beforeStart.isReady(for: controlPort)"))
    XCTAssertTrue(p2pManagerSource.contains("let readiness = discoveryManager.advertisingReadinessSnapshot"))
    XCTAssertTrue(p2pManagerSource.contains("readiness.isReady(for: controlPort)"))
    XCTAssertTrue(p2pManagerSource.contains("try await discoveryManager.startAdvertising(port: controlPort)"))
    XCTAssertTrue(p2pManagerSource.contains("P2P 监听状态与 Bonjour 广播状态不一致"))
    XCTAssertTrue(appSource.contains("try await connectionManager.startListening()"))
    XCTAssertTrue(appSource.contains("前台恢复 P2P 监听器失败"))
    XCTAssertFalse(
      appSource.contains("try? await connectionManager.startListening()"),
      "Foreground recovery must log listener startup failures instead of swallowing them."
    )
  }

  @MainActor
  func testICloudPresenceControlListenerReadinessFailsClosed() {
    let missingPort = ICloudDevicePresenceService.ControlListenerReadiness(
      isReady: true,
      controlPort: nil
    )
    let zeroPort = ICloudDevicePresenceService.ControlListenerReadiness(
      isReady: true,
      controlPort: 0
    )
    let listenerNotReady = ICloudDevicePresenceService.ControlListenerReadiness(
      isReady: false,
      controlPort: 9527
    )
    let ready = ICloudDevicePresenceService.ControlListenerReadiness(
      isReady: true,
      controlPort: 9527
    )

    XCTAssertEqual(missingPort, .unavailable)
    XCTAssertEqual(zeroPort, .unavailable)
    XCTAssertEqual(listenerNotReady, .unavailable)
    XCTAssertTrue(ready.isReady)
    XCTAssertEqual(ready.controlPort, 9527)
  }

  func testICloudPresencePublishesAfterListenerStartupAndStopsFailClosed() throws {
    let appSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift"
    )
    let presenceSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CloudKitSyncManager.swift"
    )

    let listenerStart = try XCTUnwrap(appSource.range(of: "try await connectionManager.startListening()"))
    let presenceStart = try XCTUnwrap(
      appSource.range(of: "ICloudDevicePresenceService.shared.start()", range: listenerStart.upperBound..<appSource.endIndex)
    )
    XCTAssertLessThan(listenerStart.lowerBound, presenceStart.lowerBound)
    XCTAssertTrue(appSource.contains("snapshot.isReady(for: 9527)"))
    XCTAssertTrue(appSource.contains("connectionManager.stopListening()"))
    XCTAssertTrue(appSource.contains("ICloudDevicePresenceService.shared.stop()"))
    XCTAssertTrue(presenceSource.contains("publishPresence(readiness: .unavailable, reason: \"listener-stopped\")"))
    XCTAssertTrue(presenceSource.contains("isOnline: readiness.isReady"))
    XCTAssertTrue(presenceSource.contains("listenerReady: readiness.isReady"))
    XCTAssertTrue(presenceSource.contains("controlPort: readiness.controlPort"))
  }

  func testIOSPrimaryBonjourTXTAdvertisesAllControlPortAliases() throws {
    let discoverySource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
    )

    XCTAssertTrue(discoverySource.contains("let portValue = String(port)"))
    XCTAssertTrue(discoverySource.contains("record[\"port\"] = portValue"))
    XCTAssertTrue(discoverySource.contains("record[\"skybridgePort\"] = portValue"))
    XCTAssertTrue(discoverySource.contains("record[\"p2pPort\"] = portValue"))
    XCTAssertTrue(discoverySource.contains("record[\"controlPort\"] = portValue"))
    XCTAssertTrue(discoverySource.contains("record[\"controlPortSource\"] = \"listener\""))
  }

  func testIOSBonjourInteropCapabilitiesStayAlignedWithAndroidAliases() throws {
    let fileTransferSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
    )
    let discoverySource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
    )

    XCTAssertTrue(
      fileTransferSource.contains("\"capabilities\": Data(\"file,file_transfer,\\(ClassicTransferCapability.classicResume)\".utf8)"),
      "iOS file-transfer Bonjour TXT must advertise both file aliases and classic resume support."
    )
    XCTAssertTrue(discoverySource.contains("return [\"file\", \"file_transfer\"]"))
    XCTAssertTrue(
      discoverySource.contains("return [\"screen_sharing\", \"remote_desktop\", \"rdview\", \"remote_control\", \"rdcontrol\"]"),
      "Remote Bonjour service inference must keep Android-compatible screen/control aliases."
    )
    XCTAssertTrue(
      discoverySource.contains("caps.formUnion([\"file\", \"file_transfer\"])")
    )
    XCTAssertTrue(
      discoverySource.contains("caps.formUnion([\"screen_sharing\", \"remote_desktop\", \"rdview\", \"remote_control\", \"rdcontrol\"])")
    )
  }

  func testIOSFileTransferNetworkServiceConnectFailsClosedOnOutboundTimeout() throws {
    let fileTransferSource = try iosFileTransferNetworkServiceSource()

    XCTAssertTrue(fileTransferSource.contains("let endpointDescription = \"\\(normalizedIP):\\(port)\""))
    XCTAssertTrue(fileTransferSource.contains("case .waiting(let error):"))
    XCTAssertTrue(fileTransferSource.contains("queue.asyncAfter(deadline: .now() + FileTransferConstants.connectionTimeout)"))
    XCTAssertTrue(fileTransferSource.contains("gate.runOnce {\n                    connection.stateUpdateHandler = nil"))
    XCTAssertTrue(fileTransferSource.contains("stage: \"connect_timeout\""))
    XCTAssertTrue(fileTransferSource.contains("endpoint: endpointDescription"))
    XCTAssertTrue(fileTransferSource.contains("connection.cancel()"))
    XCTAssertFalse(
      fileTransferSource.contains("continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))"),
      "Outbound connect failures must preserve stage/endpoint context instead of collapsing into a generic networkError."
    )
  }

  func testRemoteDesktopDeviceResolutionLivesOutsideManagerHotPath() throws {
    let managerSource = try remoteDesktopManagerSource()
    let resolverSource = try remoteDesktopDeviceResolutionCoordinatorSource()

    XCTAssertTrue(managerSource.contains("RemoteDesktopDeviceResolutionCoordinator("))
    XCTAssertFalse(managerSource.contains("private func resolveLatestRemoteDesktopDevice"))
    XCTAssertFalse(managerSource.contains("private func makeRemoteDesktopEndpointCandidates"))
    XCTAssertFalse(managerSource.contains("private func remoteDesktopBonjourServiceIdentity"))
    XCTAssertFalse(managerSource.contains("private func resolveRemoteDesktopIPAddress"))
    XCTAssertFalse(managerSource.contains("private func activeP2PBootstrapDevice"))

    XCTAssertTrue(resolverSource.contains("struct RemoteDesktopDeviceResolutionCoordinator"))
    XCTAssertTrue(resolverSource.contains("func makeEndpointCandidates"))
    XCTAssertTrue(resolverSource.contains("func resolveLatestDevice"))
    XCTAssertTrue(resolverSource.contains("func activeP2PBootstrapDevice"))
    XCTAssertTrue(resolverSource.contains("RemoteDesktopLANEndpointCandidateFactory.makePlan"))
    XCTAssertFalse(resolverSource.contains("VideoDecoder"))
    XCTAssertFalse(resolverSource.contains("RemoteMetalVideoFrameFeed"))
    XCTAssertFalse(resolverSource.contains("enqueueMetalFrameForDisplay"))
    XCTAssertFalse(resolverSource.contains("handleScreenData"))
    XCTAssertFalse(resolverSource.contains("handleMetalRendererDidDisplayFrames"))
    XCTAssertFalse(resolverSource.contains("startDecodeLoopIfNeeded"))
    XCTAssertFalse(resolverSource.contains("processLANReceiveBuffer"))
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
  func testDeviceDiscoveryCoalescesStableBonjourAndHostRowsForSameIPad() {
    let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
    let stable = DiscoveredDevice(
      id: "id:07cb9a6e-1111-4222-8333-123456789abc",
      name: "Ziang的iPad",
      bonjourServiceName: nil,
      modelName: "iPad",
      platform: .iOS,
      osVersion: "26.5",
      ipAddress: nil,
      services: [],
      portMap: [:],
      lastSeen: Date().addingTimeInterval(-3),
      isConnected: false,
      isTrusted: true,
      advertisedCapabilities: ["remote_desktop"],
      capabilities: ["remote_desktop"]
    )
    let bonjour = DiscoveredDevice(
      id: "bonjour:Ziang的iPad@local.",
      name: "Ziang的iPad",
      bonjourServiceName: "Ziang的iPad",
      modelName: "iPad Pro",
      platform: .iPadOS,
      osVersion: "26.5",
      ipAddress: nil,
      bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
      bonjourServiceDomain: "local.",
      services: [DiscoveryServiceType.skybridge.rawValue],
      portMap: [DiscoveryServiceType.skybridge.rawValue: 11550],
      lastSeen: Date().addingTimeInterval(-2),
      advertisedCapabilities: ["remote_desktop"],
      capabilities: ["remote_desktop"]
    )
    let host = DiscoveredDevice(
      id: "host:192.168.0.103",
      name: "Ziang的iPad",
      bonjourServiceName: nil,
      modelName: "iPad Pro",
      platform: .iPadOS,
      osVersion: "26.5",
      ipAddress: "192.168.0.103",
      services: [DiscoveryServiceType.skybridgeRemote.rawValue],
      portMap: [DiscoveryServiceType.skybridgeRemote.rawValue: 5901],
      lastSeen: Date().addingTimeInterval(-1),
      advertisedCapabilities: ["remote_control"],
      capabilities: ["remote_control"]
    )

    manager.debugSeedDiscoveryState(
      devices: [stable, bonjour, host],
      lastActivity: Date(),
      endpointToDeviceId: [
        "stable-endpoint": stable.id,
        "bonjour-endpoint": bonjour.id,
        "host-endpoint": host.id
      ],
      liveBrowseEndpointKeysByServiceType: [
        .skybridge: ["bonjour-endpoint"],
        .skybridgeRemote: ["host-endpoint"]
      ]
    )

    XCTAssertEqual(manager.discoveredDevices.count, 1)
    let merged = manager.discoveredDevices[0]
    XCTAssertEqual(merged.id, stable.id)
    XCTAssertEqual(merged.name, "Ziang的iPad")
    XCTAssertEqual(merged.modelName, "iPad Pro")
    XCTAssertEqual(merged.platform, .iPadOS)
    XCTAssertEqual(merged.bonjourServiceName, "Ziang的iPad")
    XCTAssertEqual(merged.ipAddress, "192.168.0.103")
    XCTAssertTrue(merged.services.contains(DiscoveryServiceType.skybridge.rawValue))
    XCTAssertTrue(merged.services.contains(DiscoveryServiceType.skybridgeRemote.rawValue))
    XCTAssertEqual(merged.portMap[DiscoveryServiceType.skybridge.rawValue], 11550)
    XCTAssertEqual(merged.portMap[DiscoveryServiceType.skybridgeRemote.rawValue], 5901)
    XCTAssertTrue(merged.isTrusted)
    XCTAssertEqual(manager.debugCachedDeviceIds, Set([stable.id]))
  }

  @MainActor
  func testDeviceDiscoveryCoalescesMacHardwareModelBonjourAliasWithStableMacRow() {
    let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
    let stable = DiscoveredDevice(
      id: "id:e0715a9a-d0d3-47e6-b353-de0a30293e1f",
      name: "Lza的MacBook Pro",
      bonjourServiceName: nil,
      modelName: "MacBookPro18,2",
      platform: .macOS,
      osVersion: "26.5",
      ipAddress: nil,
      services: [DiscoveryServiceType.skybridge.rawValue],
      portMap: [DiscoveryServiceType.skybridge.rawValue: 51776],
      lastSeen: Date().addingTimeInterval(-2),
      isConnected: true,
      isTrusted: true,
      advertisedCapabilities: ["remote_desktop"],
      capabilities: ["remote_desktop"]
    )
    let hardwareModelAlias = DiscoveredDevice(
      id: "bonjour:MacBookPro18,2@local.",
      name: "MacBookPro18,2",
      bonjourServiceName: "MacBookPro18,2",
      modelName: "MacBookPro18,2",
      platform: .macOS,
      osVersion: "26.5",
      ipAddress: nil,
      bonjourServiceType: DiscoveryServiceType.skybridgeRemote.rawValue,
      bonjourServiceDomain: "local.",
      services: [DiscoveryServiceType.skybridgeRemote.rawValue],
      portMap: [DiscoveryServiceType.skybridgeRemote.rawValue: 5901],
      lastSeen: Date().addingTimeInterval(-1),
      advertisedCapabilities: ["remote_control"],
      capabilities: ["remote_control"]
    )

    manager.debugSeedDiscoveryState(
      devices: [stable, hardwareModelAlias],
      lastActivity: Date(),
      endpointToDeviceId: [
        "stable-endpoint": stable.id,
        "mac-model-endpoint": hardwareModelAlias.id
      ],
      liveBrowseEndpointKeysByServiceType: [
        .skybridge: ["stable-endpoint"],
        .skybridgeRemote: ["mac-model-endpoint"]
      ]
    )

    XCTAssertEqual(manager.discoveredDevices.count, 1)
    let merged = manager.discoveredDevices[0]
    XCTAssertEqual(merged.id, stable.id)
    XCTAssertEqual(merged.name, "Lza的MacBook Pro")
    XCTAssertEqual(merged.modelName, "MacBookPro18,2")
    XCTAssertEqual(merged.platform, .macOS)
    XCTAssertTrue(merged.services.contains(DiscoveryServiceType.skybridge.rawValue))
    XCTAssertTrue(merged.services.contains(DiscoveryServiceType.skybridgeRemote.rawValue))
    XCTAssertEqual(merged.portMap[DiscoveryServiceType.skybridge.rawValue], 51776)
    XCTAssertEqual(merged.portMap[DiscoveryServiceType.skybridgeRemote.rawValue], 5901)
    XCTAssertEqual(manager.debugCachedDeviceIds, Set([stable.id]))
  }

  @MainActor
  func testDeviceDiscoveryDoesNotCoalesceGenericIPadBonjourNameOnlyRows() {
    let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
    let generic = DiscoveredDevice(
      id: "bonjour:iPad@local.",
      name: "iPad",
      bonjourServiceName: "iPad",
      modelName: "iPad Pro",
      platform: .iPadOS,
      osVersion: "26.5",
      ipAddress: nil,
      bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
      bonjourServiceDomain: "local.",
      services: [DiscoveryServiceType.skybridge.rawValue],
      portMap: [DiscoveryServiceType.skybridge.rawValue: 11550],
      lastSeen: Date().addingTimeInterval(-2)
    )
    let personalized = DiscoveredDevice(
      id: "bonjour:Ziang的iPad@local.",
      name: "Ziang的iPad",
      bonjourServiceName: "Ziang的iPad",
      modelName: "iPad Pro",
      platform: .iPadOS,
      osVersion: "26.5",
      ipAddress: nil,
      bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
      bonjourServiceDomain: "local.",
      services: [DiscoveryServiceType.skybridge.rawValue],
      portMap: [DiscoveryServiceType.skybridge.rawValue: 11550],
      lastSeen: Date().addingTimeInterval(-1)
    )

    manager.debugSeedDiscoveryState(
      devices: [generic, personalized],
      lastActivity: Date(),
      endpointToDeviceId: [
        "generic-endpoint": generic.id,
        "personalized-endpoint": personalized.id
      ],
      liveBrowseEndpointKeysByServiceType: [
        .skybridge: ["generic-endpoint", "personalized-endpoint"]
      ]
    )

    XCTAssertEqual(manager.discoveredDevices.count, 2)
    XCTAssertEqual(manager.debugCachedDeviceIds, Set([generic.id, personalized.id]))
  }

  @MainActor
  func testDeviceDiscoveryDoesNotCoalesceSameNameEndpointRowsWithoutAuthorityAnchor() {
    let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
    let bonjour = DiscoveredDevice(
      id: "bonjour:Lab-iPad@local.",
      name: "Lab iPad",
      bonjourServiceName: "Lab-iPad",
      modelName: "iPad Pro",
      platform: .iPadOS,
      osVersion: "26.5",
      ipAddress: nil,
      bonjourServiceType: DiscoveryServiceType.skybridge.rawValue,
      bonjourServiceDomain: "local.",
      services: [DiscoveryServiceType.skybridge.rawValue],
      portMap: [DiscoveryServiceType.skybridge.rawValue: 11550],
      lastSeen: Date().addingTimeInterval(-2)
    )
    let host = DiscoveredDevice(
      id: "host:192.168.0.155",
      name: "Lab iPad",
      bonjourServiceName: nil,
      modelName: "iPad Pro",
      platform: .iPadOS,
      osVersion: "26.5",
      ipAddress: "192.168.0.155",
      services: [DiscoveryServiceType.skybridgeRemote.rawValue],
      portMap: [DiscoveryServiceType.skybridgeRemote.rawValue: 5901],
      lastSeen: Date().addingTimeInterval(-1)
    )

    manager.debugSeedDiscoveryState(
      devices: [bonjour, host],
      lastActivity: Date(),
      endpointToDeviceId: [
        "bonjour-endpoint": bonjour.id,
        "host-endpoint": host.id
      ],
      liveBrowseEndpointKeysByServiceType: [
        .skybridge: ["bonjour-endpoint"],
        .skybridgeRemote: ["host-endpoint"]
      ]
    )

    XCTAssertEqual(manager.discoveredDevices.count, 2)
    XCTAssertEqual(manager.debugCachedDeviceIds, Set([bonjour.id, host.id]))
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
  func testLANRemoteDesktopTrustBootstrapTimeoutFailsFastInsteadOfContinuing() throws {
    XCTAssertNil(
      RemoteDesktopManager.lanRemoteControlTrustBootstrapFailureReason(
        observedReply: true,
        bootstrapReady: true
      )
    )

    let reason = try XCTUnwrap(
      RemoteDesktopManager.lanRemoteControlTrustBootstrapFailureReason(
        observedReply: true,
        bootstrapReady: false
      )
    )
    XCTAssertTrue(reason.contains("stage=lan_remote_trust_bootstrap"))
    XCTAssertTrue(reason.contains("reason=metadata_kem_readiness_timeout"))
    XCTAssertTrue(reason.contains("observedReply=1"))
    XCTAssertTrue(reason.contains("noFallback=1"))
    XCTAssertFalse(reason.contains("继续远控握手"))

    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try readRepositorySourceForSourceShapeTests(
      at: repoRoot.appendingPathComponent(
        "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
      )
    )
    XCTAssertFalse(source.contains("metadata/KEM 就绪，继续远控握手"))
    XCTAssertTrue(source.contains("LAN 远控前置 bootstrap fail-fast"))
    XCTAssertTrue(source.contains("throw RemoteDesktopError.connectionFailed(reason)"))
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

    // 自“媒体就绪门控”改动起，audioRedirectionEnabled 是有效值而非偏好值：
    // 偏好开启但无可用媒体音频端点/原生音频时，payload 仍然必须广告为关闭。
    // 端点就绪时广告为开启的路径由 RemoteDesktopViewerStreamConfigurationFactoryTests
    // .testCrossNetworkAudioEndpointProducesPQCRealtimeAudioPayload 锁定。
    XCTAssertEqual(manager.makeViewerStreamConfigurationPayload().audioRedirectionEnabled, false)
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

  func testRealtimeMediaAudioEndpointPolicyRejectsNearExpiryAndNormalizesRelayAddress() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let freshEndpoint = SkyBridgeMediaEndpoint(
      host: " relay.example.com ",
      port: 34_78,
      relayToken: "token-a",
      expiresAt: now.timeIntervalSince1970 + 30
    )
    let nearExpiryEndpoint = SkyBridgeMediaEndpoint(
      host: "relay.example.com",
      port: 34_78,
      relayToken: "token-b",
      expiresAt: now.timeIntervalSince1970 + 5
    )
    let sameAddressEndpoint = SkyBridgeMediaEndpoint(
      host: "RELAY.EXAMPLE.COM",
      port: 34_78,
      relayToken: "token-c",
      expiresAt: now.timeIntervalSince1970 + 60
    )

    XCTAssertTrue(RemoteDesktopManager.isUsableRealtimeMediaAudioEndpoint(freshEndpoint, now: now))
    XCTAssertFalse(
      RemoteDesktopManager.isUsableRealtimeMediaAudioEndpoint(nearExpiryEndpoint, now: now))
    XCTAssertTrue(
      RemoteDesktopManager.isSameRealtimeMediaRelayAddress(freshEndpoint, sameAddressEndpoint))
    XCTAssertFalse(
      RemoteDesktopManager.isSameRealtimeMediaRelayAddress(
        freshEndpoint,
        SkyBridgeMediaEndpoint(host: "relay.example.com", port: 34_79)
      )
    )
  }

  @MainActor
  func testViewerStreamConfigurationKeepsAudioOnStableFallbackPath() {
    // 无媒体音频绑定时（测试环境默认态），音频字段必须显式广告为关闭，
    // 不得提前广告 pqc-media-v1 或采样率（媒体就绪门控语义；端点就绪路径由
    // RemoteDesktopViewerStreamConfigurationFactoryTests 锁定）。
    let payload = RemoteDesktopManager.instance.makeViewerStreamConfigurationPayload()

    XCTAssertEqual(payload.nativeAudioTrackEnabled, false)
    XCTAssertEqual(payload.audioRedirectionEnabled, false)
    XCTAssertEqual(payload.audioTransport, "disabled")
    XCTAssertNil(payload.audioMode)
    XCTAssertNil(payload.mediaAudioEndpoint)
    XCTAssertEqual(payload.compatibilityAudioFallbackEnabled, false)
    XCTAssertNil(payload.preferredAudioEncoding)
    XCTAssertNil(payload.audioSampleRate)
    XCTAssertNil(payload.audioChannelCount)
  }

  func testStrictVideoValidationDoesNotForceRealtimeAudioLowLatencyMode() throws {
    let source = try remoteDesktopManagerSource()
    let factorySource = try remoteDesktopViewerStreamConfigurationFactorySource()
    let configBody = try sourceSlice(
      from: "static func makePayload(_ input: Input)",
      to: "private static func keyFrameInterval(",
      in: factorySource
    )
    let managerConfigWrapper = try sourceSlice(
      from: "func makeViewerStreamConfigurationPayload(\n        refreshStream: Bool,",
      to: "private func preferredRealtimeMediaAudioMode()",
      in: source
    )
    let pushBody = try sourceSlice(
      from: "private func pushViewerStreamConfiguration(",
      to: "private func sendViewerStreamConfigurationPayload(",
      in: source
    )

    XCTAssertTrue(
      configBody.contains(
        "let videoLowLatencyMode = viewerSettings.lowLatencyMode || strictMediaValidationEnabled"))
    XCTAssertTrue(
      managerConfigWrapper.contains("let realtimeMediaAudioMode = preferredRealtimeMediaAudioMode()"))
    XCTAssertTrue(
      configBody.contains("audioMode: realtimeMediaAudioReady ? realtimeMediaAudioMode.rawValue : nil"))
    XCTAssertFalse(
      configBody.contains("audioMode: lowLatencyMode ? \"low-latency\" : \"high-fidelity\""),
      "Strict 2K60 video validation must not silently switch the host audio sender into duplicate low-latency datagram mode while the receiver is high-fidelity."
    )
    XCTAssertTrue(pushBody.contains("let mediaAudioMode = preferredRealtimeMediaAudioMode()"))
  }

  func testStrictVideoValidationAdvertisesHEVCOnlyMainPath() throws {
    let source = try remoteDesktopViewerStreamConfigurationFactorySource()
    let configBody = try sourceSlice(
      from: "static func makePayload(_ input: Input)",
      to: "private static func keyFrameInterval(",
      in: source
    )

    XCTAssertTrue(configBody.contains("let strictVideoMainPathFormats = [\"hevc\"]"))
    XCTAssertTrue(
      configBody.contains(
        "let advertisedSupportedFormats = strictMediaValidationEnabled ? strictVideoMainPathFormats : supportedFormats"
      ))
    XCTAssertTrue(
      configBody.contains(
        "let advertisedPreferredCodec = strictMediaValidationEnabled ? \"hevc\" : preferredCodec"))
    XCTAssertTrue(
      source.contains("return max(60, targetFrameRate)"))
    XCTAssertTrue(configBody.contains("preferredCodec: advertisedPreferredCodec"))
    XCTAssertTrue(configBody.contains("supportedVideoFormats: advertisedSupportedFormats"))
    XCTAssertTrue(
      configBody.contains(
        "damageTrackingEnabled: strictMediaValidationEnabled ? false : transportTuning.damageTrackingEnabled"
      ))
    XCTAssertTrue(
      configBody.contains(
        "performanceValidationMode: strictMediaValidationEnabled ? \"extreme\" : nil"))
    XCTAssertTrue(
      configBody.contains(
        "mediaFallbackPolicy: activeTransportMode == .crossNetwork ? \"forbidden\" : \"fail-fast\"")
    )
    XCTAssertFalse(configBody.contains("strictMediaValidationEnabled ? [\"hevc\", \"h264\"]"))
  }

  func testRemoteDesktopSmokeStreamOverridesRequireSmokeRoleAndClampFPS() {
    let environment = [
      "SKYBRIDGE_SMOKE_ROLE": "ios",
      "SKYBRIDGE_SMOKE_VIDEO_WIDTH": " 2056 ",
      "SKYBRIDGE_SMOKE_VIDEO_HEIGHT": "1329",
      "SKYBRIDGE_SMOKE_TARGET_FPS": "240",
    ]

    let dimensions = RemoteDesktopSmokeStreamOverrides.requestedDimensions(environment: environment)
    XCTAssertEqual(dimensions?.width, 2056)
    XCTAssertEqual(dimensions?.height, 1329)
    XCTAssertEqual(RemoteDesktopSmokeStreamOverrides.targetFrameRate(environment: environment), 120)
    XCTAssertNil(
      RemoteDesktopSmokeStreamOverrides.requestedDimensions(environment: [
        "SKYBRIDGE_SMOKE_VIDEO_WIDTH": "2056",
        "SKYBRIDGE_SMOKE_VIDEO_HEIGHT": "1329",
      ]))
    XCTAssertNil(
      RemoteDesktopSmokeStreamOverrides.targetFrameRate(environment: [
        "SKYBRIDGE_SMOKE_ROLE": "ios",
        "SKYBRIDGE_SMOKE_TARGET_FPS": "0",
      ]))
  }

  func testHEVCMainPathUsesAsynchronousHardwareDecode() throws {
    let managerSource = try remoteDesktopManagerSource()
    let runtimeModelsSource = try remoteDesktopRuntimeModelsSource()
    let source = try remoteDesktopVideoDecoderSource()
    let decodeBody = try sourceSlice(
      from: "private func decodeToPixelBufferFrame(",
      to: "private func makeSampleBuffer(",
      in: source
    )

    XCTAssertTrue(
      source.contains("flags: [._EnableAsynchronousDecompression]"),
      "2056x1329@60 HEVC must not run VideoToolbox decode synchronously on the MainActor."
    )
    XCTAssertTrue(
      source.contains("key: kVTDecompressionPropertyKey_RealTime"),
      "2056x1329@60 HEVC decode must run as a realtime VideoToolbox session instead of accumulating decoder latency."
    )
    XCTAssertTrue(
      source.contains("Failed to enable realtime hardware decode"),
      "Realtime decoder configuration failure must surface as a real media failure, not a hidden latency regression."
    )
    XCTAssertTrue(
      source.contains("RemoteDesktopError.decodingFailed(\"callback-no-image\")"),
      "A VideoToolbox callback without an image must be surfaced as a real decode failure for fail-fast handling."
    )
    XCTAssertTrue(
      managerSource.contains(
        "private let maxConcurrentVideoDecodes: Int = RemoteDesktopManagerRuntimeLimits.maxPredictiveVideoDecodeInFlight"
      ))
    XCTAssertTrue(
      managerSource.contains("pendingDecodeCompletions[decodeOrder]"),
      "Dependent HEVC/H.264 access units must be submitted with bounded in-flight callbacks and drained in submission order."
    )
    XCTAssertTrue(
      source.contains("func submit(screenData: ScreenData) async throws -> VideoDecodeSubmission"),
      "VideoToolbox submissions must be split from callback waits so access units enter the VT session in actor order."
    )
    XCTAssertTrue(
      managerSource.contains("await previousSubmission?.value"),
      "RemoteDesktopManager must preserve wire-order decode submission while allowing callbacks to complete asynchronously."
    )
    XCTAssertTrue(
      managerSource.contains("decode-completion-gap-reset"),
      "Ordered callback drain must fail visibly and request sync if an earlier VT callback gap blocks display."
    )
    XCTAssertTrue(
      managerSource.contains("decodeCompletionGapWatchdogTask"),
      "A missing earlier VideoToolbox callback must be reset by time, not only by a later completion event."
    )
    XCTAssertTrue(
      runtimeModelsSource.contains("static let decodeCompletionGapWatchdogDelay: Duration = .milliseconds(500)"),
      "The ordered callback watchdog must have an explicit realtime bound."
    )
    XCTAssertTrue(
      runtimeModelsSource.contains("static let maxPredictiveVideoDecodeInFlight = 4"),
      "2056x1329@60 HEVC must keep one realtime VTDecompressionSession fed instead of waiting for each callback before the next submit."
    )
    XCTAssertTrue(
      source.contains("VideoToolbox callback status=\\(status) \\(accessUnitSummary)"),
      "HEVC fail-fast logs must identify the failing access unit rather than collapsing to a generic decoder error."
    )
    XCTAssertFalse(
      decodeBody.contains("flags: []"),
      "The strict HEVC path must not silently fall back to synchronous decode flags."
    )
  }

  func testHEVCDecoderDoesNotTrustAdvertisedSyncAndAnnotatesSampleDependencies() throws {
    let source = try remoteDesktopVideoDecoderSource()
    let decodeBody = try sourceSlice(
      from: "private func decodeVideoFrame(",
      to: "private func resetDecoderState(",
      in: source
    )
    let resetBody = try sourceSlice(
      from: "func resetPreservingLastFrame()",
      to: "func consumeLastFailureReason()",
      in: source
    )

    XCTAssertTrue(
      decodeBody.contains("let containsSyncFrame = containsSyncFrame(in: nalus, codec: codec)"))
    XCTAssertFalse(
      decodeBody.contains("(isSyncFrame == true) ||"),
      "HEVC fail-fast cannot trust remote metadata to turn a predictive frame into a sync frame."
    )
    XCTAssertTrue(decodeBody.contains("isSyncFrame: containsSyncFrame"))
    XCTAssertTrue(
      decodeBody.contains(
        "let accessUnitSummary = videoAccessUnitSummary(codec: codec, nalus: nalus)"))
    XCTAssertTrue(
      source.contains("private func videoAccessUnitSummary(codec: Codec, nalus: [Data]) -> String"))
    XCTAssertTrue(source.contains("video-decode-first-au codec="))

    let sampleBody = try sourceSlice(
      from: "private func makeSampleBuffer(",
      to: "private func nextDecodePresentationTimeStamp()",
      in: source
    )
    XCTAssertTrue(
      sampleBody.contains("setDecoderSampleAttachments(on: sampleBuffer, isSyncFrame: isSyncFrame)")
    )
    XCTAssertTrue(sampleBody.contains("kCMSampleAttachmentKey_NotSync"))
    XCTAssertTrue(sampleBody.contains("kCMSampleAttachmentKey_DependsOnOthers"))
    XCTAssertTrue(
      resetBody.contains("clearVideoParameterSets()"),
      "After a decoder reset, HEVC/H.264 must require fresh VPS/SPS/PPS before accepting the next sync frame."
    )
  }

  func testP2PRemoteSmokeFailsImmediatelyOnMediaMainPathError() throws {
    let source = try skyBridgeCompassAppSource()
    let body = try sourceSlice(
      from: "private func performRemoteDesktopSmoke(",
      to: "private func requestedSmokeVideoSize()",
      in: source
    )

    XCTAssertTrue(body.contains("snapshot.stateDescription.lowercased().contains(\"error\")"))
    XCTAssertTrue(body.contains("failed stage=remote-desktop phase=media_main_path_error error="))
    XCTAssertTrue(body.contains("P2P 远控媒体主路径失败"))
    XCTAssertFalse(body.contains("failed stage=remote-desktop error="))

    XCTAssertTrue(
      source.contains(
        "private nonisolated static func remoteDesktopFailureLine(for error: Error) -> String"))
    XCTAssertTrue(source.contains("phase = \"performance_window_timeout\""))
    XCTAssertTrue(source.contains("phase = \"media_main_path_error\""))
    XCTAssertTrue(source.contains("phase = \"remote_desktop_error\""))
    XCTAssertTrue(source.contains("failed stage=remote-desktop phase=\\(phase) domain="))
  }

  func testP2PRemoteSmokeRejectsDuplicateRealtimeAudioDatagrams() throws {
    let source = try skyBridgeCompassAppSource()
    let body = try sourceSlice(
      from: "private func performRemoteDesktopSmoke(",
      to: "private func activeP2PSmokeSummary()",
      in: source
    )

    XCTAssertTrue(body.contains("(audio?.datagramsSeen ?? 0) > 0"))
    XCTAssertTrue(body.contains("(audio?.replayRejectedPackets ?? 0) == 0"))
    XCTAssertTrue(body.contains("(audio?.jitterEvictedPackets ?? 0) == 0"))
    XCTAssertTrue(body.contains("audioRxReplayRejected="))
    XCTAssertTrue(body.contains("audioRxJitterEvicted="))
  }

  func testPQCRealtimeAudioReceiverUsesOpusRingBufferPath() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/RealtimeMediaAudio.swift"
    )
    let source = try readRepositorySourceForSourceShapeTests(at: sourceURL)

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
    XCTAssertTrue(source.contains("decodeStallMinimumReceivedPackets"))
    XCTAssertTrue(source.contains("window.received >= decodeStallMinimumReceivedPackets"))
    XCTAssertTrue(source.contains("window.decoded >= playbackStallMinimumDecodedPackets"))
    XCTAssertTrue(source.contains("return max(profile.jitterTargetMs, 2_400)"))
    XCTAssertTrue(source.contains("return max(profile.jitterMaxMs, 4_800)"))
    XCTAssertTrue(source.contains("return max(profile.jitterTargetMs, 520)"))
    XCTAssertTrue(source.contains("return max(profile.jitterMaxMs, 900)"))
    XCTAssertTrue(source.contains("orderingJitterTargetMs"))
    XCTAssertTrue(source.contains("orderingJitterMaxMs"))
    XCTAssertTrue(source.contains("return max(profile.jitterTargetMs, 3_200)"))
    XCTAssertTrue(source.contains("return max(profile.jitterMaxMs, 5_600)"))
    XCTAssertTrue(source.contains("private var gapPlayoutBufferedThresholdPacketCount: Int"))
    XCTAssertTrue(source.contains("bufferedFrameCount >= gapPlayoutBufferedThresholdPacketCount"))
    XCTAssertTrue(source.contains("rx-ordering-gap-wait"))
    XCTAssertTrue(source.contains("stableJitterWindowCount >= 6"))
    XCTAssertTrue(source.contains("underflow > 0"))
    XCTAssertTrue(source.contains("scheduleLeadMs < -60"))
    XCTAssertTrue(source.contains("scheduleLeadMs < -100"))
    XCTAssertTrue(source.contains("evictRatio="))
    XCTAssertTrue(source.contains("transport-starved:zero-rx-after-playback"))
    XCTAssertTrue(source.contains("action=no-jitter-adaptation reason=transport-starved"))
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
    XCTAssertTrue(
      source.contains("setPreferredIOBufferDuration(mode == .lowLatency ? 0.005 : 0.01)"))
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
    let source = try readRepositorySourceForSourceShapeTests(at: sourceURL)

    XCTAssertTrue(source.contains("lastFallbackOnlyNativeVideoDiagnosticAt"))
    XCTAssertTrue(
      source.contains("now.timeIntervalSince(lastFallbackOnlyNativeVideoDiagnosticAt) >= 2.0"))
    XCTAssertEqual(
      source.components(separatedBy: "fallback screen data confirms only degraded screen path")
        .count - 1,
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
    let source = try readRepositorySourceForSourceShapeTests(at: profileURL)
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
      to:
        "guard CrossNetworkWebRTCNativeVideoPolicy.isActualNativeRenderEvidence(source: source) else { return }",
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
      from:
        "private func handleScreenData(_ screenData: ScreenData, receivedAt: Date? = nil) async",
      to:
        "private func handleIncomingStreamTopologyChangeIfNeeded(for screenData: ScreenData) async",
      in: remoteDesktopSource
    )
    guard
      let preStreamingGuardRange = handleScreenDataBody.range(of: "dropReason=pre-streaming-frame"),
      let hasRemoteNativeTrackRange = handleScreenDataBody.range(
        of: "let hasRemoteNativeVideoTrack: Bool"),
      let warmupAllowRange = handleScreenDataBody.range(
        of: "shouldAllowNativeWarmupJPEGFallbackFrame"),
      let strictValidationRange = handleScreenDataBody.range(
        of: "strictCrossNetworkMediaValidationActive && !allowsNativeWarmupJPEGFallback"),
      let warmupDropGuardRange = handleScreenDataBody.range(
        of: "shouldDropNativeWarmupNonJPEGFallbackFrame"),
      let renderedGuardRange = handleScreenDataBody.range(
        of: "shouldIgnoreFallbackFrameAfterNativeVideoRendered"),
      let noteReceivedRange = handleScreenDataBody.range(of: "noteReceivedFrame"),
      let topologyRange = handleScreenDataBody.range(
        of: "handleIncomingStreamTopologyChangeIfNeeded")
    else {
      return XCTFail(
        "Expected native warmup/rendered fallback guards and topology handler in handleScreenData.")
    }
    XCTAssertLessThan(
      preStreamingGuardRange.lowerBound,
      warmupDropGuardRange.lowerBound,
      "Frames that arrive before the viewer enters streaming must be dropped before any codec/topology handling can consume an early predictive frame."
    )
    XCTAssertLessThan(
      hasRemoteNativeTrackRange.lowerBound,
      warmupAllowRange.lowerBound,
      "Strict media validation must know whether a native track exists before classifying bounded JPEG warmup."
    )
    XCTAssertLessThan(
      warmupAllowRange.lowerBound,
      strictValidationRange.lowerBound,
      "Bounded JPEG warmup must be classified before strict fallback rejection, otherwise iOS rejects the frame that prevents native warmup black screens."
    )
    XCTAssertLessThan(
      strictValidationRange.lowerBound,
      warmupDropGuardRange.lowerBound,
      "Strict validation should still fail non-warmup fallback frames before topology handling."
    )
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

  func testTopologyChangeWaitsForDecoderBootstrapBeforeRecoveringPredictiveStream() throws {
    let remoteDesktopSource = try remoteDesktopManagerSource()
    let topologyBody = try sourceSlice(
      from:
        "private func handleIncomingStreamTopologyChangeIfNeeded(for screenData: ScreenData) async",
      to: "private func acceptFrameSequenceForDecode(_ screenData: ScreenData, now: Date) -> Bool",
      in: remoteDesktopSource
    )

    XCTAssertTrue(
      topologyBody.contains("let incomingFrameHasDecoderBootstrap = screenData.isDecoderBootstrapFrame"))
    XCTAssertTrue(
      topologyBody.contains(
        "let lightweightFlapTransition = isFallbackProducerFlap && incomingFrameHasDecoderBootstrap"))
    XCTAssertTrue(
      topologyBody.contains(
        "decodeQueueWaitingForSyncFrame = RemoteDesktopDecodeQueuePolicy.isPredictiveVideoFormat(normalizedFormat)"))
    XCTAssertTrue(topologyBody.contains("&& !incomingFrameHasDecoderBootstrap"))
    XCTAssertFalse(
      topologyBody.contains("RemoteDesktopScreenFrameWire.containsSyncFrame"),
      "Topology changes must not clear waiting-for-sync on HEVC IRAP-only or H264 IDR-only frames that lack decoder parameter sets."
    )
  }

  func testPredictiveSequenceGapRequestsStreamRefreshWithoutTransportTeardown() throws {
    let remoteDesktopSource = try remoteDesktopManagerSource()
    let gapBody = try sourceSlice(
      from: "case .gapRequiresSync(let previous, let current, let missing):",
      to: "private func enqueueFrameForDecode(_ screenData: ScreenData, receivedAt: Date? = nil)",
      in: remoteDesktopSource
    )

    XCTAssertTrue(gapBody.contains("lastInboundVideoFrameSequence = current"))
    XCTAssertTrue(gapBody.contains("pendingFrames.removeAll(keepingCapacity: true)"))
    XCTAssertTrue(gapBody.contains("decodeQueueWaitingForSyncFrame = true"))
    XCTAssertTrue(
      gapBody.contains("requestStreamRefreshIfNeeded(reason: \"decode-sequence-gap\", minimumInterval: 0.25)")
    )
    XCTAssertTrue(gapBody.contains("return false"))
    XCTAssertFalse(gapBody.contains("handleTransportFailure"))
    XCTAssertFalse(gapBody.contains("crossNetwork.disconnect"))
    XCTAssertFalse(gapBody.contains("clearLANSecureChannelState"))
  }

  func testNativeWarmupFallbackGuardDropsNonJPEGBeforeVisibleNativeRender() {
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
    XCTAssertTrue(
      RemoteDesktopManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: true,
        hasRemoteNativeVideoTrack: true,
        nativeVideoTrackHasRenderedFrame: false,
        format: nil
      )
    )
    XCTAssertTrue(
      RemoteDesktopManager.shouldDropNativeWarmupNonJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: true,
        hasRemoteNativeVideoTrack: true,
        nativeVideoTrackHasRenderedFrame: false,
        format: " bgra "
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
        format: " JPG "
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

  func testStrictMediaValidationAllowsOnlyBoundedJPEGDuringNativeWarmup() {
    XCTAssertTrue(
      RemoteDesktopManager.shouldAllowNativeWarmupJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: true,
        hasRemoteNativeVideoTrack: true,
        nativeVideoTrackHasRenderedFrame: false,
        format: "jpeg"
      )
    )
    XCTAssertTrue(
      RemoteDesktopManager.shouldAllowNativeWarmupJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: true,
        hasRemoteNativeVideoTrack: true,
        nativeVideoTrackHasRenderedFrame: false,
        format: " JPG "
      )
    )
    XCTAssertFalse(
      RemoteDesktopManager.shouldAllowNativeWarmupJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: true,
        hasRemoteNativeVideoTrack: true,
        nativeVideoTrackHasRenderedFrame: false,
        format: "h264"
      )
    )
    XCTAssertFalse(
      RemoteDesktopManager.shouldAllowNativeWarmupJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: true,
        hasRemoteNativeVideoTrack: false,
        nativeVideoTrackHasRenderedFrame: false,
        format: "jpeg"
      )
    )
    XCTAssertFalse(
      RemoteDesktopManager.shouldAllowNativeWarmupJPEGFallbackFrame(
        activeTransportModeIsCrossNetwork: true,
        hasRemoteNativeVideoTrack: true,
        nativeVideoTrackHasRenderedFrame: true,
        format: "jpeg"
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
    XCTAssertTrue(
      fallbackBody.contains("native promotion still waits for real RTP/render evidence"))

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
    guard
      let actualEvidenceGuard = renderedFrameBody.range(
        of:
          "guard CrossNetworkWebRTCNativeVideoPolicy.isActualNativeRenderEvidence(source: source) else { return }"
      ),
      let watchdogCancel = renderedFrameBody.range(
        of: "remoteVideoTrackConfirmationTask?.cancel()"),
      let pipelinePromotion = renderedFrameBody.range(of: "noteCrossNetworkNativeVideoFrame")
    else {
      return XCTFail(
        "Expected actual-evidence guard, watchdog cancel, and native pipeline promotion in rendered frame handler."
      )
    }
    XCTAssertLessThan(actualEvidenceGuard.lowerBound, watchdogCancel.lowerBound)
    XCTAssertLessThan(actualEvidenceGuard.lowerBound, pipelinePromotion.lowerBound)
    guard let promotionReady = renderedFrameBody.range(of: "markRemoteVideoTrackReadyForPromotion")
    else {
      return XCTFail(
        "Expected actual rendered frame evidence to mark native video promotion-ready.")
    }
    XCTAssertLessThan(
      actualEvidenceGuard.lowerBound,
      promotionReady.lowerBound,
      "Receiver stats, heartbeat renderer, and packet evidence must not set promotion-ready before actual visible native render evidence."
    )
    XCTAssertTrue(renderedFrameBody.contains("renderEpoch: UInt64?"))
    XCTAssertTrue(renderedFrameBody.contains("uiSurface: String"))
    XCTAssertTrue(renderedFrameBody.contains("nativeRenderUISurface = uiSurface"))
    XCTAssertTrue(renderedFrameBody.contains("uiSurface=\\(uiSurface)"))
    XCTAssertTrue(renderedFrameBody.contains("guard let renderEpoch,"))
    XCTAssertTrue(renderedFrameBody.contains("renderEpoch == remoteVideoTrackRenderEpoch"))
    XCTAssertTrue(renderedFrameBody.contains("ignore stale native render evidence"))
    XCTAssertTrue(renderedFrameBody.contains("reason=probe-inactive"))
    XCTAssertTrue(renderedFrameBody.contains("reason=track-mismatch"))
    XCTAssertTrue(renderedFrameBody.contains("reason=epoch-mismatch"))
    XCTAssertTrue(
      crossNetworkSource.contains("@Published public private(set) var remoteVideoTrackRenderEpoch"))
    XCTAssertTrue(crossNetworkSource.contains("remoteVideoTrackRenderEpoch &+= 1"))
    XCTAssertTrue(
      crossNetworkSource.contains(
        "func currentRemoteVideoTrackRenderToken(trackId: String?) -> UInt64"))
    XCTAssertFalse(
      crossNetworkSource.contains(
        "let shouldPreserveRenderedEvidence = track != nil && isTrackRebind && preservedRenderedFrame"
      ),
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
    let viewSource = try remoteDesktopViewSource()

    XCTAssertTrue(
      crossNetworkSource.contains("@Published public private(set) var nativeVideoProbeActive"))
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
    XCTAssertTrue(
      viewSource.contains("crossNetworkManager.remoteVideoTrackHasReceiverFrameEvidence"))
    XCTAssertTrue(viewSource.contains("&& !crossNetworkManager.remoteVideoTrackHasRenderedFrame"))

    let remoteScreenBody = try sourceSlice(
      from: "private func remoteScreenView(geometry: GeometryProxy) -> some View",
      to: "#else\n            RemoteDesktopCompositedSurface",
      in: viewSource
    )
    let nativeSurfaceCount =
      remoteScreenBody.components(
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
    XCTAssertTrue(
      evidenceLoop.contains(
        "remote-video-frame-evidence session=\\(self.sessionId) \\(candidate.summary)"))
    XCTAssertTrue(refreshBody.contains("receiverStatsProbeRemoteVideoTrackRefreshAction"))
    XCTAssertTrue(
      refreshBody.contains(
        "guard refreshAction == .rebind else {\n            return false\n        }"))
    let sameTrackIdGuard =
      refreshBody.range(
        of: "guard refreshAction == .rebind"
      )?.lowerBound ?? refreshBody.endIndex
    let syncLog =
      refreshBody.range(of: "remote native video track refreshed from receiver stats probe")?
      .lowerBound
      ?? refreshBody.startIndex
    XCTAssertLessThan(
      sameTrackIdGuard,
      syncLog,
      "Receiver stats polling may return a fresh Swift wrapper for the same native track; same trackId must be a no-op before rebind logging or handler publication."
    )
    let syncIndex =
      evidenceLoop.range(of: "refreshRemoteVideoTrackFromReceiverIfNeeded")?.lowerBound
      ?? evidenceLoop.endIndex
    let evidenceIndex =
      evidenceLoop.range(of: "remote-video-frame-evidence")?.lowerBound
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
    XCTAssertTrue(
      refreshBody.contains(
        "guard refreshAction == .rebind else {\n            return false\n        }"))
    XCTAssertFalse(
      refreshBody.contains("remoteVideoTracksShareNativeBacking"),
      "Receiver stats probe must not use backing identity as a rebind trigger; wrapper churn is exactly what caused repeated same-track rebinds."
    )
    XCTAssertFalse(
      refreshBody.contains("remoteVideoTrack !== receiverTrack"),
      "Receiver stats probe must not compare RTCVideoTrack wrapper identity directly; receiver.track can return a fresh wrapper."
    )
    let noOpGuardIndex =
      refreshBody.range(of: "guard refreshAction == .rebind")?.lowerBound
      ?? refreshBody.endIndex
    let refreshLogIndex =
      refreshBody.range(of: "remote native video track refreshed from receiver stats probe")?
      .lowerBound
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

    XCTAssertTrue(
      installBody.contains(
        "CrossNetworkWebRTCNativeVideoPolicy.remoteVideoTracksShareNativeBacking"))
    XCTAssertTrue(
      installBody.contains(
        "scheduleRemoteVideoTrackConfirmationIfNeeded(trigger: \"track-unchanged\")"))
    let sameBackingGuardIndex =
      installBody.range(of: "guard !tracksShareNativeBacking")?.lowerBound
      ?? installBody.endIndex
    let epochBumpIndex =
      installBody.range(of: "remoteVideoTrackRenderEpoch &+= 1")?.lowerBound
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

  func testVideoRefreshPayloadPreservesLANAudioEndpointAndForbidsFallback() throws {
    let source = try remoteDesktopManagerSource()
    let factorySource = try remoteDesktopViewerStreamConfigurationFactorySource()
    let pushPolicySource = try remoteDesktopViewerStreamConfigurationPushPolicySource()
    let pushBody = try sourceSlice(
      from:
        "private func pushViewerStreamConfiguration(force: Bool, refreshStream: Bool = false) async",
      to: "private func sendViewerStreamConfigurationPayload",
      in: source
    )
    let payloadBody = try sourceSlice(
      from: "static func makePayload(_ input: Input)",
      to: "private static func keyFrameInterval(",
      in: factorySource
    )

    XCTAssertTrue(
      pushPolicySource.contains(
        "|| !lastAcknowledgedMediaAudioEndpointPresent"
      ))
    XCTAssertTrue(
      pushBody.contains(
        "lastAcknowledgedMediaAudioEndpointPresent: lastAcknowledgedMediaAudioEndpointPresent"
      ))
    XCTAssertTrue(
      pushBody.contains(
        "mediaAudioEndpoint: preparationPlan.includeAudioEndpointInStreamConfig ? mediaAudioBinding?.endpoint : nil"
      ))
    XCTAssertTrue(
      pushBody.contains(
        "mediaSessionId: preparationPlan.includeAudioEndpointInStreamConfig ? mediaAudioBinding?.mediaSessionId : nil"
      ))
    XCTAssertTrue(pushBody.contains("if preparationPlan.includeAudioEndpointInStreamConfig"))
    XCTAssertTrue(
      pushBody.contains("activeTransportMode: activeTransportMode,"),
      "Push policy preparation must receive the active transport mode."
    )
    XCTAssertTrue(
      pushBody.contains("ensureRealtimeMediaAudioReceiverStartedIfNeeded(mode: mediaAudioMode)"))
    XCTAssertFalse(
      pushBody.contains("reason=await_audio_endpoint"))
    XCTAssertFalse(
      pushPolicySource.contains("shouldDeferUntilAudioEndpointReady"))
    XCTAssertTrue(
      factorySource.contains("let realtimeMediaAudioReady = viewerSettings.audioRedirectionEnabled"))
    XCTAssertTrue(
      factorySource.contains("audioRedirectionEnabled: effectiveAudioRedirectionEnabled"))
    XCTAssertTrue(
      factorySource.contains("SkyBridgeRealtimeMediaConstants.audioTransportDisabled"))
    XCTAssertFalse(
      pushPolicySource.contains("if refreshStream,\n           strictValidationRequiresAudioEndpoint"),
      "Strict LAN/PQC media smoke must not hide video startup behind refresh-only audio endpoint gating."
    )
    XCTAssertTrue(
      source.contains("func handleCrossNetworkNativeVideoWarmupEvidence(reason: String)"))
    XCTAssertTrue(
      source.contains("await self?.pushViewerStreamConfiguration(force: true, refreshStream: true)")
    )
    XCTAssertFalse(payloadBody.contains("shouldUseJPEGOnlyFallbackDuringNativeWarmup"))
    XCTAssertFalse(payloadBody.contains("? [\"jpeg\"]"))
    XCTAssertFalse(payloadBody.contains("? \"jpeg\""))
    XCTAssertTrue(
      payloadBody.contains(
        "screenFrameTransport: activeTransportMode == .crossNetwork\n                ? \"webrtc-native-main\""
      ))
    XCTAssertTrue(
      payloadBody.contains("screenDataChannelEnabled: activeTransportMode != .crossNetwork"))
    XCTAssertTrue(
      payloadBody.contains(
        "mediaFallbackPolicy: activeTransportMode == .crossNetwork ? \"forbidden\" : \"fail-fast\"")
    )
    XCTAssertTrue(
      payloadBody.contains("nativeVideoTrackReady: activeTransportMode == .crossNetwork")
    )
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

    XCTAssertFalse(
      manager.activeConnections.contains { connection in
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
  func testDashboardSecurityBadgeDoesNotClaimPQCWithoutNegotiatedEvidence() {
    let badge = DashboardView.securityBadgePresentation(
      for: ConnectionPresentation(
        phase: .connected,
        isConnected: true,
        statusText: RuntimeLocalization.string("已连接"),
        detailText: RuntimeLocalization.string("守护中")
      )
    )

    XCTAssertEqual(badge.label, "待确认")
    XCTAssertEqual(badge.tone, .pending)
  }

  @MainActor
  func testDashboardSecurityBadgeShowsClassicForClassicSuite() {
    let badge = DashboardView.securityBadgePresentation(
      for: ConnectionPresentation(
        phase: .connected,
        isConnected: true,
        statusText: "Classic \(RuntimeLocalization.string("已连接"))",
        detailText: "X25519 · \(RuntimeLocalization.string("守护中"))",
        securityEvidence: .classic
      )
    )

    XCTAssertEqual(badge.label, "Classic")
    XCTAssertEqual(badge.tone, .classic)
  }

  @MainActor
  func testDashboardSecurityBadgeShowsPQCOnlyForNegotiatedPQCEvidence() {
    let applePQC = DashboardView.securityBadgePresentation(
      for: ConnectionPresentation(
        phase: .connected,
        isConnected: true,
        statusText: "Apple PQC \(RuntimeLocalization.string("已连接"))",
        detailText: "ML-KEM-768 · \(RuntimeLocalization.string("跨网已连接"))",
        securityEvidence: .pqc
      )
    )
    let xwing = DashboardView.securityBadgePresentation(
      for: ConnectionPresentation(
        phase: .connected,
        isConnected: true,
        statusText: "X-Wing \(RuntimeLocalization.string("已连接"))",
        detailText: RuntimeLocalization.string("跨网已连接"),
        securityEvidence: .pqc
      )
    )

    XCTAssertEqual(applePQC.label, "PQC")
    XCTAssertEqual(applePQC.tone, .verifiedPQC)
    XCTAssertEqual(xwing.label, "PQC")
    XCTAssertEqual(xwing.tone, .verifiedPQC)
  }

  @MainActor
  func testDashboardSecurityBadgeIgnoresPQCWordsWithoutStructuredEvidence() {
    let badge = DashboardView.securityBadgePresentation(
      for: ConnectionPresentation(
        phase: .connected,
        isConnected: true,
        statusText: "Apple PQC \(RuntimeLocalization.string("已连接"))",
        detailText: "Provider 与本地密钥就绪"
      )
    )

    XCTAssertEqual(badge.label, "待确认")
    XCTAssertEqual(badge.tone, .pending)
  }

  @MainActor
  func testSettingsPQCPolicyStatusShowsClassicWhenStrictPolicyIsOff() {
    let status = SettingsView.pqcPolicyStatusPresentation(
      enforcePQCHandshake: false,
      currentTier: .nativePQC,
      currentSuite: .mlkem768,
      hasKeyPair: true
    )

    XCTAssertEqual(status.label, "Classic")
    XCTAssertEqual(status.detail, "未强制")
    XCTAssertEqual(status.tone, .classic)
  }

  @MainActor
  func testSettingsPQCPolicyStatusDoesNotClaimStrictWhenProviderUnavailable() {
    let status = SettingsView.pqcPolicyStatusPresentation(
      enforcePQCHandshake: true,
      currentTier: .classic,
      currentSuite: .unknown(0xFFFF),
      hasKeyPair: false
    )

    XCTAssertEqual(status.label, "PQC 不可用")
    XCTAssertEqual(status.detail, "严格策略请求中，Provider 不可用")
    XCTAssertEqual(status.tone, .unavailable)
  }

  @MainActor
  func testSettingsPQCPolicyStatusWaitsForLocalKeysBeforeClaimingStrictPQC() {
    let status = SettingsView.pqcPolicyStatusPresentation(
      enforcePQCHandshake: true,
      currentTier: .nativePQC,
      currentSuite: .mlkem768,
      hasKeyPair: false
    )

    XCTAssertEqual(status.label, "待初始化")
    XCTAssertEqual(status.detail, "严格 PQC 已请求，待生成本地密钥")
    XCTAssertEqual(status.tone, .pending)
  }

  @MainActor
  func testSettingsPQCPolicyStatusClaimsStrictOnlyWhenProviderAndKeysAreReady() {
    let status = SettingsView.pqcPolicyStatusPresentation(
      enforcePQCHandshake: true,
      currentTier: .nativePQC,
      currentSuite: .xwing,
      hasKeyPair: true
    )

    XCTAssertEqual(status.label, "PQC 就绪")
    XCTAssertEqual(status.detail, "严格 PQC 已请求，Provider 与本地密钥就绪，等待会话协商证明")
    XCTAssertEqual(status.tone, .ready)
  }

  @MainActor
  func testSettingsPQCPolicyStatusSupportsLiboqsReadyState() {
    let status = SettingsView.pqcPolicyStatusPresentation(
      enforcePQCHandshake: true,
      currentTier: .liboqsPQC,
      currentSuite: .mlkem768,
      hasKeyPair: true
    )

    XCTAssertEqual(status.label, "PQC 就绪")
    XCTAssertEqual(status.tone, .ready)
  }

  @MainActor
  func testSettingsPQCPolicyStatusRejectsClassicSuiteEvenWhenTierIsPQC() {
    let status = SettingsView.pqcPolicyStatusPresentation(
      enforcePQCHandshake: true,
      currentTier: .nativePQC,
      currentSuite: .x25519Ed25519,
      hasKeyPair: true
    )

    XCTAssertEqual(status.label, "PQC 不可用")
    XCTAssertEqual(status.tone, .unavailable)
  }

  @MainActor
  func testDashboardViewModelPreservesClassicPresentationWhenActiveConnectionsTemporarilyClear()
    async
  {
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
    XCTAssertNotEqual(
      viewModel.topConnectionPresentation.statusText, RuntimeLocalization.string("在线"))

    manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
  }

  @MainActor
  func testDashboardViewModelDoesNotPretendTargetSuiteIsConnectedDuringRekey() async {
    let manager = P2PConnectionManager.instance
    let viewModel = DashboardViewModel.shared
    let runtimePeerId = "host:192.168.1.63"
    let declaredDeviceId = UUID().uuidString.lowercased()
    let connectedText = RuntimeLocalization.string("已连接")
    let rekeyingText = RuntimeLocalization.string("Rekey 中")

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
    XCTAssertEqual(viewModel.topConnectionPresentation.detailText, "Classic → X-Wing · \(rekeyingText)")
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

  func testP2PPairingIdentityExchangeAdvertisesProtocolIdentityKeys() throws {
    let iosP2P = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
    )
    let macP2P = try repositoryScriptSource("Sources/SkyBridgeCore/P2P/P2PModels.swift")

    XCTAssertTrue(
      iosP2P.contains(
        "protocolIdentityPublicKeys: await localProtocolIdentityPublicKeysForPairing()"))
    XCTAssertTrue(iosP2P.contains("ProtocolIdentityTrustStore.shared.upsert"))
    XCTAssertTrue(macP2P.contains("protocolIdentityPublicKeys: protocolIdentityPublicKeys"))
  }

  func testLANRemoteControlTrustProviderUsesBoundMultiFingerprintPins() throws {
    let source = try remoteDesktopManagerSource()
    let trustBootstrapSource = try remoteDesktopLANHandshakeTrustSource()

    XCTAssertTrue(
      trustBootstrapSource.contains(
        "struct LANRemoteControlHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider"),
      "LAN remote desktop must validate against the full active protocol-identity pin set, not only one stale fingerprint."
    )
    XCTAssertTrue(
      trustBootstrapSource.contains("ProtocolIdentityTrustStore.shared.trustedFingerprints"))
    XCTAssertTrue(
      trustBootstrapSource.contains("if supplementalFingerprints.contains(primaryFingerprint)"),
      "Supplemental pins may only be used when the authenticated P2P exchange also includes the already trusted primary pin."
    )
    XCTAssertFalse(source.contains("struct LANRemoteControlHandshakeTrustProvider"))
  }

  func testWebRTCFileTransferCompletionRequiresDurableReceipt() throws {
    let iosSender = try iosFileTransferManagerSource()
    let iosReceiver = try crossNetworkWebRTCFileTransferSource()
    let macConnection = try [
      "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift",
      "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift",
      "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCOutboundFileTransferSupport.swift",
    ].map { path in
      try repositoryScriptSource(path)
    }.joined(separator: "\n")

    XCTAssertTrue(iosSender.contains("completionAck.receivedBytes == metadata.fileSize"))
    XCTAssertTrue(iosSender.contains("completionAck.fileSha256 == fileSha256"))
    XCTAssertTrue(
      iosReceiver.contains(
        "op: .completeAck,\n                                transferId: st.transferId,\n                                receivedBytes: st.receivedBytes,\n                                fileSha256:"
      ))
    XCTAssertTrue(macConnection.contains("WebRTCOutboundFileTransferSupport.validateCompletionAck"))
    XCTAssertTrue(macConnection.contains("ack.receivedBytes == expectedFileSize"))
    XCTAssertTrue(macConnection.contains("ack.fileSha256 == expectedFileSha256"))
  }

  func testWebRTCFileTransferIntegrityValidationStaysCentralized() throws {
    let iosReceiver = try crossNetworkWebRTCFileTransferSource()
    let integrity = try crossNetworkFileTransferIntegritySource()

    XCTAssertTrue(integrity.contains("enum CrossNetworkFileTransferIntegrityValidator"))
    XCTAssertTrue(integrity.contains("static func verifiedChunkHash"))
    XCTAssertTrue(integrity.contains("static func validateMerkleProof"))
    XCTAssertTrue(integrity.contains("CrossNetworkMerkleAuthCompat.signatureAlgV1"))
    XCTAssertTrue(
      iosReceiver.contains("CrossNetworkFileTransferIntegrityValidator.verifiedChunkHash"))
    XCTAssertTrue(
      iosReceiver.contains("CrossNetworkFileTransferIntegrityValidator.validateMerkleProof"))
    XCTAssertTrue(
      iosReceiver.contains("CrossNetworkFileTransferIntegrityValidator.hasRequiredProof"))
  }

  func testFileTransferFailuresExposeConcreteStagesToSmokeHarness() throws {
    let iosSender = try iosFileTransferManagerSource()
    let iosSmoke = try skyBridgeCompassAppSource()

    XCTAssertTrue(
      iosSender.contains(
        "case networkStageFailed(stage: String, endpoint: String?, details: String)"))
    XCTAssertTrue(iosSender.contains("stage: \"connect_failed\""))
    XCTAssertTrue(iosSender.contains("stage: \"connect_timeout\""))
    XCTAssertTrue(iosSender.contains("stage: \"send_metadata\""))
    XCTAssertTrue(iosSender.contains("stage: \"send_chunk_\\(chunk.index)\""))
    XCTAssertTrue(iosSender.contains("stage: \"send_complete\""))
    XCTAssertTrue(iosSender.contains("stage: \"receipt_header\""))
    XCTAssertTrue(iosSender.contains("stage: \"receipt_payload\""))
    XCTAssertTrue(iosSender.contains("stage: \"webrtc_chunk_ack_retries_exhausted\""))
    XCTAssertTrue(
      iosSmoke.contains(
        "private nonisolated static func fileTransferFailureLine(for error: Error) -> String"))
    XCTAssertTrue(
      iosSmoke.contains("phase=\\(Self.sanitize(phase)) category=\\(Self.sanitize(category))"))
    XCTAssertTrue(iosSmoke.contains("fileTransferFailureCategory(forNetworkStage: stage)"))
    XCTAssertTrue(iosSmoke.contains("phase: \"receipt_\\(stage.rawValue)\""))
    XCTAssertTrue(iosSmoke.contains("category: \"discovery\""))
    XCTAssertTrue(iosSmoke.contains("category: \"handshake\""))
    XCTAssertTrue(iosSmoke.contains("category: \"secure_channel\""))
    XCTAssertTrue(iosSmoke.contains("category: \"payload_framing\""))
    XCTAssertTrue(iosSmoke.contains("category: \"auth_policy\""))
    XCTAssertFalse(
      iosSmoke.contains(
        "failed stage=file-transfer error=\\(Self.sanitize(error.localizedDescription))"),
      "Smoke output must not collapse file-transfer failures into one generic network error line."
    )
  }

  func testRealDeviceFileSmokeDoesNotEnableClassicBootstrapRekeyFallback() throws {
    let script = try repositoryScriptSource("Scripts/run_real_device_file_transfer_smoke.sh")
    let iosSmoke = try skyBridgeCompassAppSource()
    let p2pManager = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
    )

    XCTAssertTrue(script.contains("DEFAULT_EXPECT_PQC_REKEY=\"0\""))
    XCTAssertTrue(
      script.contains("EXPECTED_TARGET_SUITE=\"${SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE:-X-Wing}\""))
    XCTAssertTrue(
      script.contains(
        "Strict file-transfer smoke requires SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE to resolve to a concrete suite."
      ))
    XCTAssertFalse(
      script.contains("wait_for_file_pattern \"$HOST_STATUS\" 'success .*fileTransfer=1'"))
    guard
      let hostFailureRange = script.range(
        of: "if [[ -f \"$path\" ]] && grep -qE 'failed stage=' \"$path\""),
      let hostSuccessRange = script.range(
        of: "if [[ -f \"$path\" ]] && grep -qE \"$pattern\" \"$path\""),
      let iosFailureRange = script.range(
        of: "if [[ -f \"$IOS_STATUS_LOCAL\" ]] && grep -qE 'failed stage=' \"$IOS_STATUS_LOCAL\""),
      let iosSuccessRange = script.range(
        of: "if [[ -f \"$IOS_STATUS_LOCAL\" ]] && grep -qE \"$pattern\" \"$IOS_STATUS_LOCAL\"")
    else {
      XCTFail(
        "File-transfer smoke must keep explicit failed-stage checks in both host and iOS wait loops."
      )
      return
    }
    let hostWaitBody = try sourceSlice(
      from: "wait_for_file_pattern()",
      to: "copy_ios_status() {",
      in: script
    )
    guard let copyStatusInHostWaitRange = hostWaitBody.range(of: "copy_ios_status"),
      let iosFailureInHostWaitRange = hostWaitBody.range(
        of: "if [[ -f \"$IOS_STATUS_LOCAL\" ]] && grep -qE 'failed stage=' \"$IOS_STATUS_LOCAL\""),
      let hostSuccessInHostWaitRange = hostWaitBody.range(
        of: "if [[ -f \"$path\" ]] && grep -qE \"$pattern\" \"$path\"")
    else {
      XCTFail(
        "Mac-side file-transfer wait loop must copy and inspect iOS failed-stage status before accepting host success."
      )
      return
    }
    XCTAssertLessThan(hostFailureRange.lowerBound, hostSuccessRange.lowerBound)
    XCTAssertLessThan(iosFailureRange.lowerBound, iosSuccessRange.lowerBound)
    XCTAssertLessThan(copyStatusInHostWaitRange.lowerBound, iosFailureInHostWaitRange.lowerBound)
    XCTAssertLessThan(iosFailureInHostWaitRange.lowerBound, hostSuccessInHostWaitRange.lowerBound)
    guard let launchRange = script.range(of: "launch_ios_smoke_app"),
      let bootStatusRange = script.range(
        of: "wait_for_ios_status_pattern 'boot role=ios-p2p-client'"),
      let macInboundRange = script.range(
        of:
          "wait_for_file_pattern \"$HOST_STATUS\" 'file-transfer inbound-complete name=ios-smoke-'")
    else {
      XCTFail(
        "File-transfer smoke must confirm the iOS status file exists before waiting on the Mac inbound-transfer marker."
      )
      return
    }
    XCTAssertLessThan(launchRange.lowerBound, bootStatusRange.lowerBound)
    XCTAssertLessThan(bootStatusRange.lowerBound, macInboundRange.lowerBound)
    XCTAssertTrue(script.contains("no longer supports SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1"))
    XCTAssertTrue(script.contains("launch_result_indicates_ios_profile_trust_failure"))
    XCTAssertTrue(script.contains("launch_result_indicates_locked_device"))
    XCTAssertTrue(
      script.contains("Timed out launching iOS smoke app because the real device stayed locked"))
    XCTAssertTrue(
      script.contains(
        "iOS smoke app launch failed at launch stage: code signature/profile/trust rejected by device."
      ))
    XCTAssertTrue(
      script.contains(
        "invalid code signature|inadequate entitlements|profile has not been explicitly trusted"))
    XCTAssertTrue(script.contains("host_completed_file_transfer_smoke()"))
    XCTAssertTrue(
      script.contains(
        "Timed out waiting for ${label} after macOS host completed file-transfer smoke"))
    guard
      let verifiedSKRRange = script.range(
        of: "wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh verified and imported:"),
      let iosInboundRange = script.range(
        of: "wait_for_ios_status_pattern 'file-transfer inbound-complete name=mac-smoke-'"),
      let smokeEvidenceRange = script.range(
        of: "wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh (smoke-evidence:"),
      let smokeSuccessRange = script.range(of: "echo \"==> Waiting for smoke success markers\"")
    else {
      XCTFail(
        "File-transfer smoke must wait for SKR-1 import, then transfer completion, then SKR-1 smoke proof before accepting success."
      )
      return
    }
    XCTAssertLessThan(verifiedSKRRange.lowerBound, macInboundRange.lowerBound)
    XCTAssertLessThan(macInboundRange.lowerBound, iosInboundRange.lowerBound)
    XCTAssertLessThan(iosInboundRange.lowerBound, smokeEvidenceRange.lowerBound)
    XCTAssertLessThan(smokeEvidenceRange.lowerBound, smokeSuccessRange.lowerBound)
    XCTAssertFalse(script.contains("ensure_ios_classic_fallback_pref"))
    XCTAssertFalse(script.contains("pqc_allow_classic_fallback"))
    XCTAssertFalse(
      script.contains(
        "env.get(\"SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY\") == \"1\" or env.get(\"SKYBRIDGE_SMOKE_USER_REALISTIC\") == \"1\""
      ))
    XCTAssertTrue(
      iosSmoke.contains("failed stage=pqc-policy error=classic_bootstrap_rekey_disabled_strict_pqc")
    )
    XCTAssertTrue(
      iosSmoke.contains("connectFailure = connectionManager.resolvedConnectionError(for: target)"))
    XCTAssertTrue(
      iosSmoke.contains("let failureContext = [connectFailure, lastError, lastHandshakeState]"))
    XCTAssertTrue(
      iosSmoke.contains("let failureStage = Self.p2pConnectFailureStage(failureContext)"))
    XCTAssertTrue(iosSmoke.contains("let failureDetail = Self.p2pConnectFailureDetail("))
    XCTAssertTrue(
      iosSmoke.contains("failed stage=\\(failureStage) error=\\(Self.sanitize(failureDetail))"))
    let fileTransferLoop = try sourceSlice(
      from: "if expectsPQCRekey {",
      to: "reporter.append(\"failed stage=timeout",
      in: iosSmoke
    )
    let signedProofNeedle =
      "try await assertSignedKEMRefreshIfRequired(for: target, reporter: reporter)"
    let fileTransferNeedle = "try await performBidirectionalFileTransferSmoke"
    var remaining = fileTransferLoop[...]
    var signedProofBeforeTransferCount = 0
    while let proofRange = remaining.range(of: signedProofNeedle) {
      let afterProof = remaining[proofRange.upperBound...]
      guard let transferRange = afterProof.range(of: fileTransferNeedle) else {
        XCTFail("Signed KEM refresh proof must happen before every file-transfer smoke send.")
        return
      }
      signedProofBeforeTransferCount += 1
      remaining = afterProof[transferRange.upperBound...]
    }
    XCTAssertGreaterThanOrEqual(signedProofBeforeTransferCount, 2)
    XCTAssertGreaterThanOrEqual(
      fileTransferLoop.components(separatedBy: signedProofNeedle).count - 1,
      4,
      "Signed KEM refresh proof must guard both remote-desktop and file-transfer smoke success paths."
    )
    XCTAssertTrue(iosSmoke.contains("return \"pqc-trust-preflight\""))
    XCTAssertTrue(iosSmoke.contains("normalized.contains(\"missing peer kem\")"))
    XCTAssertTrue(iosSmoke.contains("normalized.contains(\"missingpeerkempublickey\")"))
    XCTAssertTrue(
      p2pManager.contains(
        "private func ensureStrictPQCKEMTrustReady(for device: DiscoveredDevice) async throws"))
    XCTAssertTrue(p2pManager.contains("strictPQC trust preflight failed: missing peer KEM"))
    XCTAssertTrue(p2pManager.contains("try await ensureStrictPQCKEMTrustReady(for: targetDevice)"))
    guard
      let preflightRange = p2pManager.range(
        of: "try await ensureStrictPQCKEMTrustReady(for: targetDevice)"),
      let transportRange = p2pManager.range(
        of: "let (connection, selectedEndpoint) = try await establishReadyConnection")
    else {
      XCTFail("Strict PQC trust preflight must happen before opening a transport connection.")
      return
    }
    XCTAssertLessThan(preflightRange.lowerBound, transportRange.lowerBound)
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
    let resolved = FileTransferClassicPeerResolutionPolicy.preferredSenderDeviceId(
      stableDeviceId: "keychain-device-id",
      vendorDeviceId: "vendor-id"
    )

    XCTAssertEqual(resolved, "keychain-device-id")
  }

  func testClassicTransferSenderDeviceIdFallsBackToVendorWhenStableIdentityMissing() {
    let resolved = FileTransferClassicPeerResolutionPolicy.preferredSenderDeviceId(
      stableDeviceId: "   ",
      vendorDeviceId: "vendor-id"
    )

    XCTAssertEqual(resolved, "vendor-id")
  }

  func testSinglePeerTransferSecurityFallbackFailsClosedWhenNoHintsExist() {
    let fallback = FileTransferClassicPeerResolutionPolicy.singlePeerFallbackDeviceId(
      requestedCandidates: [],
      activeConnectionDeviceIDs: ["id:trusted-peer"]
    )

    XCTAssertNil(fallback)
  }

  func testSinglePeerTransferSecurityFallbackDoesNotGuessWhenHintsMismatch() {
    let fallback = FileTransferClassicPeerResolutionPolicy.singlePeerFallbackDeviceId(
      requestedCandidates: ["host:stale-peer"],
      activeConnectionDeviceIDs: ["id:trusted-peer"]
    )

    XCTAssertNil(fallback)
  }

  func testSinglePeerTransferSecurityFallbackDoesNotGuessWhenMultiplePeersExist() {
    let fallback = FileTransferClassicPeerResolutionPolicy.singlePeerFallbackDeviceId(
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
      ClassicTransferAuthenticatedPeerCandidate(
        matchDeviceId: "id:trusted-peer",
        resolvedPeerDeviceId: "id:trusted-peer",
        aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20", "192.168.31.20"],
        endpointHostOrIP: "192.168.31.20",
        capabilities: []
      )
    ]

    let resolved = FileTransferClassicPeerResolutionPolicy.resolvePeer(
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
      ClassicTransferAuthenticatedPeerCandidate(
        matchDeviceId: "id:peer-a",
        resolvedPeerDeviceId: "id:peer-a",
        aliases: ["id:peer-a", "host:192.168.31.20", "192.168.31.20"],
        endpointHostOrIP: "192.168.31.20",
        capabilities: []
      ),
      ClassicTransferAuthenticatedPeerCandidate(
        matchDeviceId: "id:peer-b",
        resolvedPeerDeviceId: "id:peer-b",
        aliases: ["id:peer-b", "host:192.168.31.20", "192.168.31.20"],
        endpointHostOrIP: "192.168.31.20",
        capabilities: []
      ),
    ]

    let resolved = FileTransferClassicPeerResolutionPolicy.resolvePeer(
      peerContext: peerContext,
      authenticatedPeers: peers
    )

    XCTAssertNil(resolved)
  }

  func testClassicTransferPeerResolutionDoesNotUseSingleFallbackWhenHintsMismatch() {
    let peerContext = FileTransferPeerContext(
      declaredSenderDeviceId: "id:offline-ios",
      endpointHostOrIP: "192.168.31.20",
      peerLabel: "iPhone",
      transferId: "transfer-mismatch"
    )
    let peers = [
      ClassicTransferAuthenticatedPeerCandidate(
        matchDeviceId: "id:stale-mac",
        resolvedPeerDeviceId: "id:stale-mac",
        aliases: ["id:stale-mac", "host:10.0.0.44", "10.0.0.44"],
        endpointHostOrIP: "10.0.0.44",
        capabilities: []
      )
    ]

    let resolved = FileTransferClassicPeerResolutionPolicy.resolvePeer(
      peerContext: peerContext,
      authenticatedPeers: peers
    )

    XCTAssertNil(resolved)
  }

  func testClassicTransferPeerResolutionRequiresExplicitEvidenceWithSingleAuthenticatedPeer() {
    let peerContext = FileTransferPeerContext(
      declaredSenderDeviceId: nil,
      endpointHostOrIP: nil,
      peerLabel: "iPad",
      transferId: "transfer-no-hints"
    )
    let peers = [
      ClassicTransferAuthenticatedPeerCandidate(
        matchDeviceId: "id:trusted-peer",
        resolvedPeerDeviceId: "id:trusted-peer",
        aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20"],
        endpointHostOrIP: "192.168.31.20",
        capabilities: []
      )
    ]

    let resolved = FileTransferClassicPeerResolutionPolicy.resolvePeer(
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

  func testRemoteDesktopAutomaticViewerPolicyPrefersHEVCAt60FPS() {
    XCTAssertEqual(RemoteDesktopViewerFrameRate.adaptive.targetFPS, 60)
    XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.width, 5120)
    XCTAssertEqual(RemoteDesktopViewerResolution.uhd5k.dimensions?.height, 2880)
    XCTAssertEqual(RemoteDesktopViewerSettings().activePreset, .automatic)
    XCTAssertEqual(
      RemoteDesktopViewerCodec.automatic.resolvedWireValue(
        supportedFormats: ["hevc", "jpeg", "h264"]
      ),
      "hevc"
    )
    XCTAssertEqual(
      RemoteDesktopViewerCodec.automatic.resolvedWireValue(
        supportedFormats: ["jpeg", "h264"]
      ),
      "jpeg"
    )
  }

  func testAutomaticCrossNetworkViewerRequestsFailFastNativeValidation() {
    let automatic = RemoteDesktopViewerSettings()

    XCTAssertEqual(automatic.activePreset, .automatic)
    XCTAssertTrue(
      RemoteDesktopManager.shouldRequestExtremeMediaValidation(
        activeTransportModeIsCrossNetwork: true,
        viewerSettings: automatic,
        environment: [:]
      )
    )
    XCTAssertFalse(
      RemoteDesktopManager.shouldRequestExtremeMediaValidation(
        activeTransportModeIsCrossNetwork: false,
        viewerSettings: automatic,
        environment: [:]
      )
    )

    var fluid = RemoteDesktopViewerSettings()
    fluid.applyPreset(.fluid)
    XCTAssertTrue(
      RemoteDesktopManager.shouldRequestExtremeMediaValidation(
        activeTransportModeIsCrossNetwork: true,
        viewerSettings: fluid,
        environment: [:]
      )
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

  func testRemoteDesktopCodecGovernanceFailsFastAfterRepeatedDecoderFailures() {
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

    guard case .failFastHEVC(let reason) = event else {
      return XCTFail("Expected HEVC circuit breaker to fail fast instead of disabling HEVC")
    }

    XCTAssertEqual(reason, "callback-no-image")
    XCTAssertEqual(
      governance.effectiveSupportedFormats(
        from: ["hevc", "h264", "jpeg"],
        at: start.addingTimeInterval(1)
      ),
      ["hevc", "h264", "jpeg"]
    )
    XCTAssertEqual(
      governance.effectivePreferredCodec(
        userPreference: .hevc,
        supportedFormats: ["hevc", "h264", "jpeg"],
        at: start.addingTimeInterval(1)
      ),
      "hevc"
    )
  }

  func testRemoteDesktopCodecGovernanceDoesNotTreatFallbackFramesAsRecovery() {
    var governance = RemoteDesktopCodecGovernance()
    let start = Date(timeIntervalSince1970: 1_700_000_100)

    _ = governance.noteDecodeFailure(format: "hevc", reason: "callback-no-image", at: start)
    _ = governance.noteDecodeFailure(
      format: "hevc", reason: "callback-no-image", at: start.addingTimeInterval(0.1))
    let failFastEvent = governance.noteDecodeFailure(
      format: "hevc",
      reason: "callback-no-image",
      at: start.addingTimeInterval(0.2)
    )
    guard case .failFastHEVC = failFastEvent else {
      return XCTFail("Expected HEVC to fail fast first")
    }

    var probeEvent: RemoteDesktopCodecGovernanceEvent = .none
    for frameIndex in 0..<24 {
      probeEvent = governance.noteDecodeSuccess(
        format: "h264",
        at: start.addingTimeInterval(1 + Double(frameIndex) * 0.05)
      )
    }

    XCTAssertEqual(probeEvent, .none)
    XCTAssertEqual(
      governance.effectiveSupportedFormats(
        from: ["hevc", "h264", "jpeg"],
        at: start.addingTimeInterval(2)
      ),
      ["hevc", "h264", "jpeg"]
    )
  }

  func testRemoteDesktopCodecGovernanceEscalatesRepeatedSyncFrameWaitsToFailFast() {
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

    guard case .failFastHEVC(let reason) = event else {
      return XCTFail("Expected repeated sync-frame waits to fail fast")
    }

    XCTAssertEqual(reason, "waiting-for-sync-frame")
    XCTAssertEqual(
      governance.effectiveSupportedFormats(
        from: ["hevc", "h264", "jpeg"],
        at: start.addingTimeInterval(1)
      ),
      ["hevc", "h264", "jpeg"]
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

  func testPeerIdentityAliasResolverNormalizesScopedIPv6HostAliases() {
    XCTAssertEqual(
      PeerIdentityAliasResolver.hostAlias(fromIPAddress: "fe80::812:27b6:c448:dad0%en0"),
      "host:fe80::812:27b6:c448:dad0"
    )
    XCTAssertEqual(
      PeerIdentityAliasResolver.hostAlias(fromIPAddress: "host:[fe80::812:27b6:c448:dad0%en0].56600"),
      "host:fe80::812:27b6:c448:dad0"
    )

    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host("fe80::812:27b6:c448:dad0%en0"),
      port: NWEndpoint.Port(integerLiteral: 56600)
    )
    let resolved = PeerIdentityAliasResolver.resolveDeviceId(
      for: endpoint,
      endpointKey: endpoint.debugDescription,
      exactEndpointMap: [:],
      aliasMap: ["host:fe80::812:27b6:c448:dad0": "id:peer-ipv6"]
    )

    XCTAssertEqual(resolved, "id:peer-ipv6")
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
  func testResolveBestRemoteDesktopDevicePrefersReachableRemoteCandidateOverCapabilityOnlySnapshot()
  {
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
  func testLiveLANMacConnectionIsEligibleForRemoteDesktopWithoutExplicitRemoteServiceAdvertisement()
  {
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

  private func assertMissingTranscriptHashA(
    _ error: Error, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case HandshakeError.failed(let reason) = error else {
      XCTFail("Expected HandshakeError.failed, got \(error)", file: file, line: line)
      return
    }
    guard case .cryptoError(let message) = reason else {
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
    XCTAssertEqual(presentation.securityEvidence, .none)
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
    XCTAssertEqual(presentation.securityEvidence, .classic)
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
    XCTAssertEqual(presentation.securityEvidence, .classic)
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
    XCTAssertEqual(classic.securityEvidence, .classic)

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
    XCTAssertEqual(xwing.securityEvidence, .pqc)

    let genericPQC = ConnectionPresentationContract.evaluate(
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
    XCTAssertEqual(genericPQC.statusText, "PQC 已连接")
    XCTAssertEqual(genericPQC.securityEvidence, .pqc)

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
    XCTAssertEqual(liboqs.securityEvidence, .pqc)
  }

  func testConnectionPresentationContractDoesNotUseDefaultPQCModeLabelWithoutSessionEvidence() {
    let labels = ConnectionPresentationLabels(
      connectedText: "已连接",
      disconnectedText: "离线",
      connectingText: "连接中",
      reconnectingText: "重连中",
      defaultGuardStatus: "守护中",
      crossNetworkGuardStatus: "跨网已连接"
    )

    let fileTransfer = ConnectionPresentationContract.evaluate(
      ConnectionPresentationInput(
        labels: labels,
        fileTransferActive: true,
        latestPeerConnection: nil,
        latestConnectedDevice: nil,
        latestPendingPeer: nil,
        activeSessionSnapshot: nil,
        defaultPQCModeLabel: "Apple PQC"
      )
    )

    let noSuite = ConnectionPresentationContract.evaluate(
      ConnectionPresentationInput(
        labels: labels,
        fileTransferActive: false,
        latestPeerConnection: nil,
        latestConnectedDevice: nil,
        latestPendingPeer: nil,
        activeSessionSnapshot: ActiveSessionSnapshot(
          snapshotToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
          sessionId: "session-no-suite",
          source: .code,
          phase: .handshakeComplete,
          deviceId: "peer-no-suite",
          deviceName: "Unknown Peer",
          negotiatedSuite: nil
        ),
        defaultPQCModeLabel: "Apple PQC"
      )
    )

    XCTAssertEqual(fileTransfer.statusText, "已连接")
    XCTAssertEqual(fileTransfer.securityEvidence, .none)
    XCTAssertEqual(noSuite.statusText, "已连接")
    XCTAssertEqual(noSuite.securityEvidence, .none)
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

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, first.imageData)
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.imageData, second.imageData)
  }

  func testRemoteDesktopDecodeQueuePolicyDoesNotDropPendingFramesOnNormalSyncFrame() {
    var pending: [ScreenData] = []
    var waitingForSyncFrame = false
    let firstPredictive = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x88]),
      timestamp: 1,
      format: "h264"
    )
    let secondPredictive = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x99]),
      timestamp: 2,
      format: "h264"
    )
    let normalSyncFrame = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0xAA]),
      timestamp: 3,
      format: "h264",
      isSyncFrame: false
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        firstPredictive,
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        secondPredictive,
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        normalSyncFrame,
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )

    XCTAssertEqual(
      pending.map(\.imageData),
      [
        firstPredictive.imageData,
        secondPredictive.imageData,
        normalSyncFrame.imageData,
      ])
    XCTAssertFalse(waitingForSyncFrame)
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

  func testRemoteDesktopDecodeQueuePolicyAbsorbsShortBurstWhileDecoderProgresses() {
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
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false
      ),
      .enqueuedAboveSoftLimit
    )
    XCTAssertEqual(pending.count, RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames + 1)
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyEntersWaitingForSyncOnlyWhenProgressStalls() {
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
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: true
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
      imageData: Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42,
        0x00, 0x00, 0x00, 0x01, 0x68, 0xCE,
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88
      ]),
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

  func testRemoteDesktopDecodeQueueDoesNotRecoverFromH264IDRWithoutParameterSets() {
    var pending: [ScreenData] = []
    var waitingForSyncFrame = true
    let idrOnlyFrame = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88]),
      timestamp: 3,
      format: "h264",
      isSyncFrame: true
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        idrOnlyFrame,
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .droppedIncomingPredictiveFrame
    )
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(waitingForSyncFrame)
  }

  func testRemoteDesktopScreenFrameWireDoesNotTrustAdvertisedHEVCSyncWithoutIRAPNAL() {
    let predictiveHEVC = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x88])

    XCTAssertFalse(
      RemoteDesktopScreenFrameWire.containsSyncFrame(
        format: "hevc",
        imageData: predictiveHEVC,
        advertisedSyncFrame: true
      )
    )
  }

  func testRemoteDesktopScreenFrameWireDetectsHEVCIRAPWhenAdvertisedFalse() {
    let hevcIRAP = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88])

    XCTAssertTrue(
      RemoteDesktopScreenFrameWire.containsSyncFrame(
        format: "hevc",
        imageData: hevcIRAP,
        advertisedSyncFrame: false
      )
    )
  }

  func testRemoteDesktopScreenFrameWireRejectsMalformedOneByteHEVCNALHeaders() {
    let malformedIRAP = Data([0x00, 0x00, 0x00, 0x01, 0x26])
    let malformedBootstrap = Data([
      0x00, 0x00, 0x00, 0x01, 0x40,
      0x00, 0x00, 0x00, 0x01, 0x42,
      0x00, 0x00, 0x00, 0x01, 0x44,
      0x00, 0x00, 0x00, 0x01, 0x26
    ])

    XCTAssertFalse(
      RemoteDesktopScreenFrameWire.containsSyncFrame(
        format: "hevc",
        imageData: malformedIRAP,
        advertisedSyncFrame: true
      )
    )
    XCTAssertFalse(
      RemoteDesktopScreenFrameWire.containsDecoderBootstrapFrame(
        format: "hevc",
        imageData: malformedBootstrap,
        advertisedSyncFrame: true
      )
    )
  }

  func testRemoteDesktopDecodeQueueRequiresHEVCParameterSetsForSyncRecovery() {
    var pending: [ScreenData] = []
    var waitingForSyncFrame = true
    let hevcIRAPWithoutParameterSets = ScreenData(
      width: 2056,
      height: 1329,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88]),
      timestamp: 1,
      format: "hevc",
      isSyncFrame: true
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        hevcIRAPWithoutParameterSets,
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .droppedIncomingPredictiveFrame
    )
    XCTAssertTrue(waitingForSyncFrame)
    XCTAssertTrue(pending.isEmpty)

    let hevcBootstrap = ScreenData(
      width: 2056,
      height: 1329,
      imageData: Data([
        0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x42, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x44, 0x01,
        0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88
      ]),
      timestamp: 2,
      format: "hevc",
      isSyncFrame: true
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        hevcBootstrap,
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .recoveredWithIndependentFrame
    )
    XCTAssertFalse(waitingForSyncFrame)
    XCTAssertEqual(pending.first?.imageData, hevcBootstrap.imageData)
  }

  func testRemoteDesktopScreenFrameWireDecodesV2FrameSequenceNumber() {
    func appendUInt16(_ value: UInt16, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt64(_ value: UInt64, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    let payload = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x88])
    var wire = Data()
    appendUInt32(0x5342_5246, to: &wire)
    wire.append(2)
    wire.append(3)
    appendUInt16(0, to: &wire)
    appendUInt32(2056, to: &wire)
    appendUInt32(1329, to: &wire)
    appendUInt64(1_710_000_123_456_789, to: &wire)
    appendUInt64(987_654_321, to: &wire)
    appendUInt32(UInt32(payload.count), to: &wire)
    wire.append(payload)

    let decoded = RemoteDesktopScreenFrameWire.decodeIfPresent(wire)

    XCTAssertEqual(decoded?.format, "hevc")
    XCTAssertEqual(decoded?.width, 2056)
    XCTAssertEqual(decoded?.height, 1329)
    XCTAssertEqual(decoded?.imageData, payload)
    XCTAssertEqual(decoded?.sequenceNumber, 987_654_321)
  }

  func testRemoteDesktopDecodeQueuePolicyRequiresSyncAfterPredictiveSequenceGap() {
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.validatePredictiveSequence(
        previous: 100,
        current: 102,
        isPredictiveVideo: true,
        isIndependentFrame: false
      ),
      .gapRequiresSync(previous: 100, current: 102, missing: 1)
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.validatePredictiveSequence(
        previous: 10,
        current: 12,
        isPredictiveVideo: true,
        isIndependentFrame: false
      ),
      .gapRequiresSync(previous: 10, current: 12, missing: 1)
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.validatePredictiveSequence(
        previous: 12,
        current: 11,
        isPredictiveVideo: true,
        isIndependentFrame: false
      ),
      .duplicateOrReordered(previous: 12, current: 11)
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.validatePredictiveSequence(
        previous: 12,
        current: 1,
        isPredictiveVideo: true,
        isIndependentFrame: true
      ),
      .accepted
    )
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
          "frameHeight": NSNumber(value: 1_329),
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
          "bytesReceived": NSNumber(value: 4_096),
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
          "framesDecoded": NSNumber(value: 0),
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
          "frameHeight": NSNumber(value: 1_328),
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
    let source = try [
      "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift",
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift",
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCMediaAdmissionFailurePolicy.swift",
    ].map { path in
      try readRepositorySource(at: root.appendingPathComponent(path))
    }.joined(separator: "\n")

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
    let source = try [
      "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift",
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift",
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCMediaAdmissionFailurePolicy.swift",
    ].map { path in
      try readRepositorySource(at: root.appendingPathComponent(path))
    }.joined(separator: "\n")

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
    let source = try readRepositorySourceForSourceShapeTests(at: sourceURL)
    let crossNetworkBranch = try sourceSlice(
      from:
        "case .crossNetwork:\n                updateRealtimeMediaAudioReceiverStartPhase(.lease",
      to: "case .lan:",
      in: source
    )
    guard
      let leaseRange = crossNetworkBranch.range(
        of: "crossNetwork.requestRealtimeMediaRelayEndpointForActiveSession()"),
      let rendererRange = crossNetworkBranch.range(
        of: "renderer = try IOSRealtimeMediaAudioReceiver(snapshot: snapshot, mode: mode)",
        range: leaseRange.upperBound..<crossNetworkBranch.endIndex)
    else {
      XCTFail("Expected cross-network media lease preflight before receiver creation")
      return
    }

    XCTAssertLessThan(leaseRange.lowerBound, rendererRange.lowerBound)
    XCTAssertTrue(crossNetworkBranch.contains("event=leaseReady"))
    XCTAssertTrue(crossNetworkBranch.contains("event=audioEndpointPrepared"))
    XCTAssertTrue(crossNetworkBranch.contains("event=udpConnectionStarted"))
    XCTAssertTrue(
      crossNetworkBranch.contains(
        "strictRelayBindRequired ? .requireAcknowledgement : .optimisticAfterSend"))
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
          "framesDecoded": NSNumber(value: 7),
        ]
      ),
      WebRTCSession.RemoteInboundVideoStatsSample(
        type: "track",
        values: [
          "kind": NSString(string: "video"),
          "frameWidth": NSNumber(value: 2_056),
          "frameHeight": NSNumber(value: 1_329),
        ]
      ),
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
          "bytesReceived": NSNumber(value: 48_836_959),
        ]
      ),
      WebRTCSession.RemoteInboundVideoStatsSample(
        type: "data-channel",
        values: [
          "kind": NSString(string: "video"),
          "packetsReceived": NSNumber(value: 20_993),
          "bytesReceived": NSNumber(value: 25_438_840),
        ]
      ),
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

  func testLocalHandshakeContextUsesPreparedOfferedSuiteInsteadOfProviderActiveSuite() async throws
  {
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
  func testCrossNetworkWebRTCInboundInitialAllowsVerifiedAuthorityClassicBootstrapOnlyWhenNonStrict() {
    XCTAssertNil(
      CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeSelectionPolicy(
        supportedSuites: [.x25519Ed25519],
        strictPQCRequested: true,
        localPQCAvailable: true,
        expectedRemoteAuthorityAlgorithm: .ed25519
      )
    )
    XCTAssertEqual(
      CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeSelectionPolicy(
        supportedSuites: [.x25519Ed25519],
        strictPQCRequested: false,
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
    XCTAssertFalse(
      CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeNegotiatedSuiteAllowed(
        .x25519Ed25519,
        strictPQCRequested: true,
        allowsClassicAuthorityBootstrap: true
      )
    )
    XCTAssertTrue(
      CrossNetworkWebRTCManager.testOnlyInboundInitialHandshakeNegotiatedSuiteAllowed(
        .x25519Ed25519,
        strictPQCRequested: false,
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

  func testHandshakeDriverRetainsAuthenticatedAuthorityAfterOutboundHandshakeEstablishes()
    async throws
  {
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

    guard
      case .waitingFinished(_, let sessionKeys, let expectingFrom) =
        await initiator.getCurrentState()
    else {
      XCTFail("Expected initiator handshake to be waiting for Finished after MessageB")
      return
    }
    XCTAssertEqual(expectingFrom, .responder)

    let responderFinished = LocalHandshakeFinishedHelper.responderFinished(for: sessionKeys)
    await initiator.handleMessage(
      responderFinished.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

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
      from: "let openedPayload = try await decrypt(ciphertext: trafficUnwrapped, with: keys)",
      to: "self.appendSmokeTrace(\"rx frame len=\\(length) keys=\\(hasSessionKeys)\")",
      in: source
    )
    let screenPublisher = try sourceSlice(
      from: "private func publishDecodedScreenDataIfCurrent",
      to: "nonisolated func appendSmokeTrace",
      in: source
    )

    XCTAssertTrue(highThroughputPublisher.contains("isStrictPQCClassicBootstrapOnlyCurrentSession"))
    XCTAssertTrue(highThroughputPublisher.contains("source=control-channel"))
    XCTAssertTrue(highThroughputPublisher.contains("return false"))
    XCTAssertTrue(receiveLoopProbe.contains("if openedPayload.packetType == .remoteDesktop"))
    XCTAssertTrue(
      receiveLoopProbe.contains("let decoded = Self.decodeRemoteDesktopHighThroughputPayload(plaintext)")
    )
    XCTAssertTrue(
      receiveLoopProbe.contains("_ = await publishHighThroughputRemoteDesktopPayloadIfCurrent")
    )
    XCTAssertTrue(receiveLoopProbe.contains("packetType: openedPayload.packetType"))
    XCTAssertTrue(
      screenPublisher.contains("strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)"))
    XCTAssertTrue(screenPublisher.contains("source=screen-channel"))
    XCTAssertLessThan(
      try XCTUnwrap(
        screenPublisher.range(of: "strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)")?
          .lowerBound),
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
    XCTAssertTrue(
      livenessWatchdog.contains("strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)"))
    XCTAssertTrue(livenessWatchdog.contains("continue"))
    XCTAssertTrue(bootstrapTimeout.contains("hasFreshActivity || isRekeyActivelyProgressing"))
    XCTAssertTrue(bootstrapTimeout.contains("strictPQCClassicBootstrapMaxGraceSeconds"))
    XCTAssertTrue(bootstrapTimeout.contains("timeout extended while rekey/liveness is active"))
    XCTAssertTrue(bootstrapTimeout.contains("failStrictPQCBootstrapSession"))
  }

  func testRemoteDesktopLANSOAPairKeyIsReleasedDuringSecureChannelCleanup() throws {
    let source = try remoteDesktopManagerSource()
    let clearBody = try sourceSlice(
      from: "private func clearLANSecureChannelState() async",
      to: "private func ensureLANRemoteControlTrustBootstrap",
      in: source
    )
    let connectBody = try sourceSlice(
      from: "public func connect(to device: DiscoveredDevice) async throws",
      to: "public func startStreaming() async throws",
      in: source
    )
    let handshakeBody = try sourceSlice(
      from: "private func establishLANSecureChannel",
      to: "private func installLANHandshakeDriver",
      in: source
    )

    XCTAssertTrue(source.contains("private var lanSOAPairKey: Data?"))
    XCTAssertTrue(source.contains("private var pendingConnectionTarget: DiscoveredDevice?"))
    XCTAssertTrue(clearBody.contains("PeerSessionArbiter.shared.clearEstablished"))
    XCTAssertTrue(clearBody.contains("PeerSessionArbiter.shared.clearOutgoing"))
    XCTAssertTrue(clearBody.contains("lanSOAPairKey = nil"))
    XCTAssertTrue(handshakeBody.contains("PeerSessionArbiter.pairKey"))
    XCTAssertTrue(handshakeBody.contains("lanSOAPairKey = pairKey"))
    XCTAssertTrue(connectBody.contains("pendingConnectionTarget"))
    XCTAssertTrue(connectBody.contains("areEquivalentRemoteDesktopDevices"))
    XCTAssertTrue(connectBody.contains("pushViewerStreamConfiguration(force: true)"))
  }

  func testRemoteDesktopLANHandshakeUsesRemoteControlSOAScope() throws {
    let source = try remoteDesktopManagerSource()
    let handshakeBody = try sourceSlice(
      from: "private func establishLANSecureChannel",
      to: "private func installLANHandshakeDriver",
      in: source
    )

    XCTAssertTrue(handshakeBody.contains("scope: .remoteControl"))
    XCTAssertTrue(handshakeBody.contains("soaSessionScope: .remoteControl"))
  }

  func testRemoteControlSOAStateIsOwnedByPeerLifecycle() throws {
    let source = try repositoryScriptSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")

    XCTAssertTrue(source.contains("var soaPairKey: Data?"))
    XCTAssertTrue(source.contains("recordSOAState(soaPairKey, for: peer)"))
    XCTAssertTrue(source.contains("releaseStaleSOAStateBeforeHandshake(pairKey: soaPairKey, for: peer)"))
    XCTAssertTrue(source.contains("releaseSOAStateIfUnretained(for: previousPeer)"))
    XCTAssertTrue(source.contains("releaseSOAStateIfUnretained(for: peer)"))
    XCTAssertTrue(source.contains("PeerSessionArbiter.shared.clearEstablished"))
    XCTAssertTrue(source.contains("PeerSessionArbiter.shared.clearOutgoing"))
    XCTAssertTrue(source.contains("isSOAPairKeyRetainedByCurrentPeer"))
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

  func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox
  {
    .init(
      encapsulatedKey: Data(repeating: 0x01, count: 32),
      ciphertext: plaintext,
      tag: Data(repeating: 0x02, count: 16),
      nonce: Data(repeating: 0x03, count: 12)
    )
  }

  func kemDemSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws
    -> HPKESealedBox
  {
    try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info)
  }

  func kemDemSealWithSecret(
    plaintext: Data,
    recipientPublicKey: Data,
    info: Data
  ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
    (
      sealedBox: try await hpkeSeal(
        plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info),
      sharedSecret: SecureBytes(data: Data(repeating: 0x11, count: 32))
    )
  }

  func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
    sealedBox.ciphertext
  }

  func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data
  {
    sealedBox.ciphertext
  }

  func kemDemOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws
    -> Data
  {
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

  func kemEncapsulate(recipientPublicKey: Data) async throws -> (
    encapsulatedKey: Data, sharedSecret: SecureBytes
  ) {
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
