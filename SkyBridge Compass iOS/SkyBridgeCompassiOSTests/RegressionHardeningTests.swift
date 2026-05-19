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

  func testInboundFileTransferSupportStaysOutsideManager() throws {
    let manager = try crossNetworkWebRTCManagerSource()
    let fileTransfer = try crossNetworkWebRTCFileTransferSource()
    let support = try crossNetworkWebRTCInboundFileTransferSupportSource()

    XCTAssertFalse(manager.contains("static func validateInboundMetadata"))
    XCTAssertFalse(manager.contains("static func expectedInboundChunkSize"))
    XCTAssertFalse(manager.contains("static func sha256File"))
    XCTAssertTrue(support.contains("static func validateInboundMetadata"))
    XCTAssertTrue(support.contains("static func expectedInboundChunkSize"))
    XCTAssertTrue(support.contains("static func sha256File"))
    XCTAssertTrue(fileTransfer.contains("Self.validateInboundMetadata"))
    XCTAssertTrue(fileTransfer.contains("Self.expectedInboundChunkSize"))
    XCTAssertTrue(fileTransfer.contains("Self.sha256File"))
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
    let audioSourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopAudioPlayback.swift"
    )
    let managerSourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
    )
    let audioSource = try String(contentsOf: audioSourceURL, encoding: .utf8)
    let managerSource = try String(contentsOf: managerSourceURL, encoding: .utf8)

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
    XCTAssertTrue(source.contains("payload.mediaAudioEndpoint == nil"))
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
      hevcFailureBody.contains("handleTransportFailure(\"hevc-main-path-failed: \\(reason)\")"),
      "Repeated HEVC failures must fail the main path instead of pushing a refreshed H.264 fallback configuration."
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
        "wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh smoke-evidence:"))
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
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN receive did not prove low-latency read-ahead and bounded drain"))
    XCTAssertTrue(
      scriptSource.contains("iOS LAN screen delivery samples did not cover every telemetry line"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN screen delivery was not strict decoded-to-Metal 60Hz feed for every telemetry line"
      ))
    XCTAssertTrue(scriptSource.contains("iOS LAN screen delivery FPS below"))
    XCTAssertTrue(
      scriptSource.contains(
        "iOS LAN direct screen delivery queued frames instead of immediate Metal feed"))
    XCTAssertTrue(
      scriptSource.contains("iOS LAN screen delivery delay exceeded 100ms inside final pass window")
    )
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
    XCTAssertTrue(scriptSource.contains("iOS LAN receive aggregate screenFPS below"))
    XCTAssertTrue(scriptSource.contains("maxGapMs"))
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
        "Mac remote contentBacklogLimit drifted from the strict 12-frame chunked contentProcessed pipeline"
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
    XCTAssertTrue(scriptSource.contains("SKYBRIDGE_SMOKE_REMOTE_ANIMATION=1"))
    XCTAssertTrue(scriptSource.contains("smoke-capture-source active=1"))
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
        "Mac remote missed cadence slots exceeded strict zero-miss cadence window"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote queuedMax exceeded ordered SBC2 cadence buffer inside final pass window"))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentProcessed backlog exceeded the strict 12-frame limit inside final pass window"
      ))
    XCTAssertTrue(
      scriptSource.contains(
        "Mac remote contentProcessed backlog hit the strict 12-frame ceiling inside final pass window"
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

  func testLANRemoteReceiveReadAheadKeepsSocketArmedBeforeDecode() throws {
    let source = try remoteDesktopManagerSource()
    let runtimeModelsSource = try remoteDesktopRuntimeModelsSource()
    let runtimeSources = source + "\n" + runtimeModelsSource
    let receiveChunk = try sourceSlice(
      from: "private nonisolated func receiveNextLANChunk(from connection: NWConnection)",
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
      runtimeModelsSource.contains("static let lanReceiveChunkMaxBytes: Int = 8 * 1024"))
    XCTAssertTrue(runtimeModelsSource.contains("static let maxLANScreenFramesPerParserDrain = 4"))
    XCTAssertTrue(source.contains("private let metalFeedDeliveryMaxDelayMs: Double = 100.0"))
    XCTAssertTrue(runtimeModelsSource.contains("enum LANInboundPayloadKind: Equatable"))
    XCTAssertTrue(source.contains("private var lanReceiveBufferNewestArrivalAt: Date?"))
    XCTAssertTrue(
      source.contains(
        "private var lanReceiveBufferArrivalMarkers: [(endOffset: Int, receivedAt: Date)] = []"))
    XCTAssertTrue(
      source.contains("private lazy var lanSecureReceivePipeline = LANRemoteSecureReceivePipeline(")
    )
    XCTAssertTrue(source.contains("private var lanSecureReceiveChain: Task<Void, Never>?"))
    XCTAssertTrue(source.contains("lanReceiveBufferNewestArrivalAt = nil"))
    XCTAssertTrue(
      source.contains("lanReceiveBufferArrivalMarkers.removeAll(keepingCapacity: keepingCapacity)"))
    XCTAssertTrue(source.contains("resetMetalFeedDeliveryState(keepingCapacity: keepingCapacity)"))
    XCTAssertTrue(
      source.contains(
        "lanSecureReceivePipeline = LANRemoteSecureReceivePipeline(maxWireMessageBytes: maxLANWireMessageBytes)"
      ))
    XCTAssertTrue(source.contains("lanSecureReceiveChain?.cancel()"))
    XCTAssertTrue(source.contains("lanSecureReceiveChain = nil"))
    XCTAssertTrue(
      receiveChunk.contains(
        "maximumLength: RemoteDesktopManagerRuntimeLimits.lanReceiveChunkMaxBytes"))
    XCTAssertTrue(receiveChunk.contains("private nonisolated func receiveNextLANChunk"))
    XCTAssertTrue(receiveChunk.contains("self?.receiveNextLANChunk(from: connection)"))
    XCTAssertTrue(receiveChunk.contains("self.processSecureLANReceiveChunk("))
    XCTAssertTrue(receiveChunk.contains("self.lanReceiveBufferNewestArrivalAt = receivedAt"))
    XCTAssertTrue(
      receiveChunk.contains("(endOffset: self.lanReceiveBuffer.count, receivedAt: receivedAt)"))
    XCTAssertTrue(receiveChunk.contains("await self.processLANReceiveBuffer(from: connection)"))
    XCTAssertTrue(processBody.contains("noteLANParserDrain("))
    XCTAssertTrue(source.contains("parserDrainMaxMs="))
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
      receiveChunk.range(of: "self?.receiveNextLANChunk(from: connection)")?.lowerBound)
    let processIndex = try XCTUnwrap(
      receiveChunk.range(of: "await self.processLANReceiveBuffer(from: connection)")?.lowerBound)
    XCTAssertLessThan(
      rearmIndex,
      processIndex,
      "LAN video receive must re-arm the socket before parsing/decode handling so MainActor stalls do not create TCP burst gaps."
    )
    XCTAssertTrue(processBody.contains("while isCurrentLANConnection(connection)"))
    XCTAssertTrue(processBody.contains("try nextLANFramedPayloadFromReceiveBuffer()"))
    XCTAssertTrue(
      processBody.contains("let bodyReceivedAt = nextPayload.receivedAt ?? drainStartedAt"))
    XCTAssertTrue(source.contains("lanReceiveBufferArrivalTime(forPayloadEndingAt: totalLength)"))
    XCTAssertTrue(source.contains("consumeLANReceiveBufferBytes(totalLength)"))
    XCTAssertTrue(processBody.contains("try unwrapLANChunkedPayloadIfNeeded("))
    XCTAssertTrue(processBody.contains("guard let completeWirePayload"))
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
      from: "private nonisolated func receiveNextLANChunk(from connection: NWConnection)",
      to: "private func processSecureLANReceiveChunk(",
      in: source
    )
    let secureEntry = try sourceSlice(
      from: "private func processSecureLANReceiveChunk(",
      to: "private func scheduleSecureLANReceiveDrain(",
      in: source
    )

    XCTAssertTrue(actorBody.contains("actor LANRemoteSecureReceivePipeline"))
    XCTAssertTrue(actorBody.contains("AES.GCM.open(sealedBox, using: key)"))
    XCTAssertTrue(actorBody.contains("RemoteDesktopScreenFrameWire.decodeIfPresent(payload)"))
    XCTAssertTrue(actorBody.contains("RemoteDesktopAudioChunkWire.decodeIfPresent(payload)"))
    XCTAssertTrue(
      pipelineSource.contains("case screen(ScreenData, payloadBytes: Int, bodyReceivedAt: Date)"))
    XCTAssertTrue(actorBody.contains("maxCompleteScreenFrames"))
    XCTAssertTrue(
      actorBody.contains("hasCompletePayloadPending: hasCompleteFramedPayloadPending()"))
    XCTAssertTrue(receiveChunk.contains("if let keys = self.lanSessionKeys"))
    XCTAssertTrue(receiveChunk.contains("self.processSecureLANReceiveChunk("))
    XCTAssertFalse(
      secureEntry.contains("@MainActor"),
      "Secure LAN frame decryption and screen-wire decode must be delegated to the off-main actor, not a MainActor task."
    )
    XCTAssertTrue(secureEntry.contains("let previousTask = lanSecureReceiveChain"))
    XCTAssertTrue(secureEntry.contains("Task(priority: .high)"))
    XCTAssertTrue(secureEntry.contains("await previousTask?.value"))
    XCTAssertTrue(secureEntry.contains("lanSecureReceiveChain = task"))
    XCTAssertTrue(secureEntry.contains("pipeline.appendAndDrain("))
    XCTAssertTrue(actorBody.contains("LAN secure decrypt failed bytes="))
    XCTAssertTrue(source.contains("parser=\\(lanInboundReceiveParserMode)"))
    XCTAssertTrue(source.contains("secure-off-main-actor"))
  }

  func testLANRemoteScreenWireUsesChunkedReassemblyAndFailsFastOnCorruption() throws {
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
    XCTAssertTrue(wireBody.contains("case failed(reason: String, frameId: UInt64?)"))
    XCTAssertTrue(wireBody.contains("missing-first-sbc2-chunk"))
    XCTAssertTrue(wireBody.contains("out-of-order-sbc2-chunk"))
    XCTAssertTrue(wireBody.contains("interleaved-or-restarted-sbc2-frame"))
    XCTAssertTrue(unwrapBody.contains("RemoteDesktopScreenFrameWire.startsWithChunkMagic(data)"))
    XCTAssertTrue(
      unwrapBody.contains("RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(data)"))
    XCTAssertTrue(
      unwrapBody.contains("lanScreenChunkReassembler.append(envelope, now: receivedAt)"))
    XCTAssertTrue(unwrapBody.contains("throw RemoteDesktopError.streamingFailed("))
    XCTAssertTrue(unwrapBody.contains("sbc2-chunk-reassembly-failed"))
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
    XCTAssertTrue(source.contains("readAhead=stream-parser-low-latency-8k-4frame-drain-budget"))
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
    let trackerSource = try remoteDesktopSmokeCadenceTrackerSource()

    XCTAssertTrue(trackerSource.contains("final class MetalDisplaySmokeCadenceTracker"))
    XCTAssertTrue(
      source.contains("private let metalDisplaySmokeCadence = MetalDisplaySmokeCadenceTracker()"))
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
  }

  func testStrictRemoteDesktopMediaPolicyRejectsStaticRenderFallbacks() throws {
    let source = try remoteDesktopManagerSource()
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
    let continuityBody = try sourceSlice(
      from: "private func handleStreamContinuityStall(reason: String) async",
      to: "func handleVideoRendererDidEnqueueFrame(",
      in: source
    )

    XCTAssertTrue(source.contains("private var remoteDesktopRenderFallbackForbidden"))
    XCTAssertTrue(source.contains("private func failFastRemoteDesktopRenderMainPath("))
    XCTAssertTrue(source.contains("render-main-path-failed"))
    XCTAssertTrue(cgImageFallbackBody.contains("cgimage-fallback-forbidden"))
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
    XCTAssertTrue(continuityBody.contains("attemptedFallback: \"sampleBufferDisplayLayer\""))
    XCTAssertTrue(continuityBody.contains("attemptedFallback: \"stillImageFallback\""))

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

  func testConnectableAddressCanonicalizerPrefersRoutableLANOverLinkLocalForMediaRoutes() {
    XCTAssertTrue(ConnectableAddressCanonicalizer.isLinkLocal("fe80::468:f5a1:462b:29d3%bridge100"))
    XCTAssertTrue(ConnectableAddressCanonicalizer.isLinkLocal("169.254.10.20"))
    XCTAssertTrue(ConnectableAddressCanonicalizer.isRoutableLANAddress("192.168.31.20"))
    XCTAssertFalse(ConnectableAddressCanonicalizer.prefersPeerToPeer(for: "192.168.31.20"))
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
    let source = try String(
      contentsOf: repoRoot.appendingPathComponent(
        "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
      ),
      encoding: .utf8
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
    let payload = RemoteDesktopManager.instance.makeViewerStreamConfigurationPayload()

    XCTAssertEqual(payload.nativeAudioTrackEnabled, false)
    XCTAssertEqual(
      payload.audioRedirectionEnabled,
      RemoteDesktopManager.instance.viewerSettings.audioRedirectionEnabled)
    XCTAssertEqual(payload.audioTransport, "pqc-media-v1")
    XCTAssertEqual(payload.compatibilityAudioFallbackEnabled, false)
    XCTAssertNil(payload.preferredAudioEncoding)
    XCTAssertEqual(payload.audioSampleRate, 48_000)
    XCTAssertEqual(payload.audioChannelCount, 2)
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
    XCTAssertTrue(configBody.contains("audioMode: realtimeMediaAudioMode.rawValue"))
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
    let source = try remoteDesktopVideoDecoderSource()
    let decodeBody = try sourceSlice(
      from: "private func decodeToPixelBufferFrame(",
      to: "private func makeSampleBuffer(",
      in: source
    )

    XCTAssertTrue(
      decodeBody.contains("flags: [._EnableAsynchronousDecompression]"),
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
      decodeBody.contains("RemoteDesktopError.decodingFailed(\"callback-no-image\")"),
      "A VideoToolbox callback without an image must be surfaced as a real decode failure for fail-fast handling."
    )
    XCTAssertTrue(
      managerSource.contains("private let maxConcurrentVideoDecodes: Int = 1"),
      "Dependent HEVC/H.264 access units must be submitted to one VTDecompressionSession in wire order."
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
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

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

  func testNativeWarmupFallbackGuardDropsAllFallbackBeforeVisibleNativeRender() {
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
        format: "jpeg"
      )
    )
    XCTAssertTrue(
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
        "&& (activeTransportMode == .lan || !refreshStream || !lastSentMediaAudioEndpointPresent)"
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
      pushBody.contains(
        "let strictValidationRequiresAudioEndpoint = viewerSettings.audioRedirectionEnabled"))
    XCTAssertTrue(
      pushBody.contains("activeTransportModeIsCrossNetwork: activeTransportMode == .crossNetwork"))
    XCTAssertTrue(
      pushBody.contains("reason=await_audio_endpoint transport=\\(activeTransportModeLabel())"))
    XCTAssertFalse(
      pushPolicySource.contains("if refreshStream,\n           strictValidationRequiresAudioEndpoint"),
      "Strict LAN/PQC media smoke must defer the first stream config until the audio endpoint is ready instead of starting video and restarting SCK when audio binds late."
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
    XCTAssertTrue(iosSmoke.contains("phase=\\(Self.sanitize(stage))"))
    XCTAssertTrue(iosSmoke.contains("phase=receipt_\\(Self.sanitize(stage.rawValue))"))
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
        of: "wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh smoke-evidence:"),
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

  func testSinglePeerTransferSecurityFallbackUsesOnlyAuthenticatedPeerWhenNoHintsExist() {
    let fallback = FileTransferClassicPeerResolutionPolicy.singlePeerFallbackDeviceId(
      requestedCandidates: [],
      activeConnectionDeviceIDs: ["id:trusted-peer"]
    )

    XCTAssertEqual(fallback, "id:trusted-peer")
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
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
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
    XCTAssertTrue(
      receiveLoopProbe.contains(
        "let published = await publishHighThroughputRemoteDesktopPayloadIfCurrent"))
    XCTAssertTrue(receiveLoopProbe.contains("if published && !usesDirectControlPayloads"))
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
