import CryptoKit
import Dispatch
import Network
import class SkyBridgeProtocolCore.InboundFileTransferIOActor
import struct SkyBridgeProtocolCore.CrossNetworkFileTransferMessage
import SkyBridgeRealtimeMedia
import UIKit
import XCTest

@testable import SkyBridgeCompass_iOS

final class SkyBridgeLoggerPrivacyTests: XCTestCase {
  func testSanitizerRedactsStructuredSecretsAndIdentifiers() {
    let message = "connected sessionId=session-123 token=secret-token fileName=private.mov host=192.168.1.20 email=person@example.com"

    let sanitized = SkyBridgeLogger.sanitizedMessage(message)

    XCTAssertFalse(sanitized.contains("session-123"))
    XCTAssertFalse(sanitized.contains("secret-token"))
    XCTAssertFalse(sanitized.contains("private.mov"))
    XCTAssertFalse(sanitized.contains("192.168.1.20"))
    XCTAssertFalse(sanitized.contains("person@example.com"))
    XCTAssertTrue(sanitized.contains("sessionId=<redacted>"))
    XCTAssertTrue(sanitized.contains("token=<redacted>"))
    XCTAssertTrue(sanitized.contains("fileName=<redacted>"))
    XCTAssertTrue(sanitized.contains("host=<redacted>"))
    XCTAssertTrue(sanitized.contains("email=<redacted-email>"))
  }

  func testSanitizerRedactsBearerURLPathAndDigestButPreservesOperationalFields() {
    let digest = String(repeating: "ab", count: 32)
    let identifier = "C0A80114-1234-4ABC-8DEF-0123456789AB"
    let message = "stage=handshake attempt=2 Bearer abc.def-123 rtsp://camera.local/live /private/var/mobile/secret.mov 192.168.1.20:554 [fd00::20]:554 \(identifier) \(digest)"

    let sanitized = SkyBridgeLogger.sanitizedMessage(message)

    XCTAssertTrue(sanitized.contains("stage=handshake attempt=2"))
    XCTAssertTrue(sanitized.contains("Bearer <redacted>"))
    XCTAssertTrue(sanitized.contains("<redacted-url>"))
    XCTAssertTrue(sanitized.contains("<redacted-path>"))
    XCTAssertTrue(sanitized.contains("<redacted-endpoint>"))
    XCTAssertTrue(sanitized.contains("<redacted-identifier>"))
    XCTAssertTrue(sanitized.contains("<redacted-digest>"))
    XCTAssertFalse(sanitized.contains("abc.def-123"))
    XCTAssertFalse(sanitized.contains("camera.local"))
    XCTAssertFalse(sanitized.contains("secret.mov"))
    XCTAssertFalse(sanitized.contains("192.168.1.20"))
    XCTAssertFalse(sanitized.contains("fd00::20"))
    XCTAssertFalse(sanitized.contains(identifier))
    XCTAssertFalse(sanitized.contains(digest))
  }
}

final class SecureBytesHardeningTests: XCTestCase {
  private final class CoherenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _observedTornCopy = false

    var observedTornCopy: Bool {
      lock.lock()
      defer { lock.unlock() }
      return _observedTornCopy
    }

    func recordTornCopy() {
      lock.lock()
      _observedTornCopy = true
      lock.unlock()
    }
  }

  func testCopiedDataRemainsValidAfterOwnerDeinit() {
    let expected = Data([0x10, 0x20, 0x30, 0x40])

    let copy = autoreleasepool {
      SecureBytes(data: expected).copyData()
    }

    XCTAssertEqual(copy, expected)
  }

  func testConcurrentReadsAndWritesReturnCoherentCopies() throws {
    let secureBytes = try SecureBytes(count: 64)
    let probe = CoherenceProbe()

    DispatchQueue.concurrentPerform(iterations: 1_000) { iteration in
      if iteration.isMultiple(of: 2) {
        let value = UInt8(truncatingIfNeeded: iteration)
        secureBytes.withUnsafeMutableBytes { buffer in
          for index in buffer.indices {
            buffer[index] = value
          }
        }
      } else {
        let copy = secureBytes.copyData()
        guard let first = copy.first,
              copy.allSatisfy({ $0 == first }) else {
          probe.recordTornCopy()
          return
        }
      }
    }

    XCTAssertFalse(probe.observedTornCopy)
  }
}

@available(iOS 17.0, *)
@MainActor
private final class PairingPromptActivationGate {
  var allowsPresentation = false
}

private enum PreparedFileProtectionTestError: Error {
  case rejected
}

private final class PreparedFileProtectionFailingFileManager: FileManager, @unchecked Sendable {
  var rejectsPreparedFileProtection = false
  var rejectedProtectionLastPathComponent: String?

  override func setAttributes(
    _ attributes: [FileAttributeKey: Any],
    ofItemAtPath path: String
  ) throws {
    let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
    if (rejectsPreparedFileProtection && lastPathComponent.contains(".prepared-"))
        || lastPathComponent == rejectedProtectionLastPathComponent {
      throw PreparedFileProtectionTestError.rejected
    }
    try super.setAttributes(attributes, ofItemAtPath: path)
  }
}

@available(iOS 17.0, *)
@MainActor
private final class PairingPromptSceneHost {
  let viewController = UIViewController()

  private let appWindow: UIWindow

  init(scene: UIWindowScene) throws {
    appWindow = try XCTUnwrap(
      scene.windows.first { window in
        window.isKeyWindow
          && window.windowLevel == .normal
          && window.rootViewController != nil
      } ?? scene.windows.first { window in
        !window.isHidden
          && window.windowLevel == .normal
          && window.rootViewController != nil
      }
    )
    viewController.view.frame = .zero
    viewController.view.isUserInteractionEnabled = false
    viewController.view.accessibilityElementsHidden = true
  }

  func attach() {
    guard viewController.view.superview == nil else { return }
    // Keep the scene probe above the SwiftUI hosting controller's view. UIKit only needs the
    // view/window relationship here; participating in controller appearance would make this
    // fixture less faithful than the UIViewControllerRepresentable lifecycle used in production.
    appWindow.addSubview(viewController.view)
  }

  func detach() {
    guard viewController.view.superview != nil else { return }
    viewController.view.removeFromSuperview()
  }
}

@available(iOS 17.0, *)
final class RegressionHardeningTests: XCTestCase {
  private enum PairingTimerTestError: Error, Sendable {
    case injectedFailure
  }

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
    XCTAssertTrue(manager.contains("stage: \"pairing-material-admission\""))
    XCTAssertFalse(manager.contains("stage: \"initial-handshake\""))
    XCTAssertFalse(manager.contains("stage: \"inbound-initial-handshake\""))
    XCTAssertTrue(manager.contains("stage: \"inbound-rekey\""))
    XCTAssertTrue(manager.contains("stage: \"outbound-rekey\""))
  }

    func testFileTransferCapabilityTracksHealthyListenerAndStartupFailureIsVisible() throws {
    let runtime = try iosFileTransferRuntimeSource()
    let manager = try p2pConnectionManagerSource()
    let app = try skyBridgeCompassAppSource()

        XCTAssertTrue(runtime.contains("public func startIfNeeded() async throws"))
        XCTAssertTrue(runtime.contains("private var startAttempt: StartAttempt?"))
        XCTAssertTrue(runtime.contains("refreshAdvertisingAuthorityIfActive"))
    XCTAssertTrue(runtime.contains("@Published public private(set) var isReady = false"))
    XCTAssertTrue(runtime.contains("isReady = false"))
    XCTAssertTrue(runtime.contains("throw error"))
    XCTAssertTrue(manager.contains("guard FileTransferRuntime.shared.isReady else"))
    XCTAssertTrue(manager.contains("return (capabilities, nil, nil)"))
        XCTAssertTrue(app.contains("try await FileTransferRuntime.shared.startIfNeeded()"))
        XCTAssertTrue(app.contains("前台恢复文件传输监听器失败"))
    XCTAssertTrue(app.contains("已撤销本机文件传输能力广告"))
        XCTAssertFalse(app.contains("\n        await FileTransferRuntime.shared.startIfNeeded()"))
    }

    func testIOSFileTransferAuthorityUsesCommittedIdentityAndExactListenerRebind() throws {
        let service = try iosFileTransferNetworkServiceSource()
        let settings = try repositoryScriptSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/SettingsView.swift"
        )

        XCTAssertTrue(service.contains("IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()"))
        XCTAssertTrue(service.contains("committedActiveProtocolIdentitySnapshot()"))
        XCTAssertFalse(service.contains(".currentProtocolIdentitySnapshot()"))
        XCTAssertTrue(service.contains("stopListenerPreservingAcceptedConnections()"))
        XCTAssertTrue(service.contains("try await startListening(authorityOverride: authority)"))
        XCTAssertTrue(service.contains("listenerGeneration &+= 1"))
        XCTAssertTrue(service.contains("pendingListener === candidate"))
        XCTAssertTrue(service.contains("listener === sourceListener"))
        XCTAssertTrue(service.contains("isBonjourPublished"))
        XCTAssertTrue(settings.contains("FileTransferRuntime.shared"))
        XCTAssertTrue(settings.contains("refreshLocalProtocolIdentityAdvertisements("))
        XCTAssertTrue(settings.contains("refreshAdvertisingAuthorityIfActive(authority)"))
        XCTAssertTrue(settings.contains("var failures: [String] = []"))
    }

    func testCurrentPathPrincipalNeverUsesBusinessNebulaIdentifierAsTenant() throws {
        let authentication = try repositoryScriptSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift"
        )
        let signaling = try crossNetworkSignalServerClientSource()

        let principal = try sourceSlice(
            from: "var currentPathAuthenticationPrincipal:",
            to: "public var remoteControlSecurityIdentityMetadata:",
            in: authentication
        )
        XCTAssertTrue(principal.contains("resolveAuthenticatedJWTIdentity("))
        XCTAssertTrue(principal.contains("tenantID: identity.effectiveTenantID"))
        XCTAssertFalse(principal.contains("nebulaId"))
        XCTAssertFalse(signaling.contains("sessionTenantID: identitySession?.nebulaId"))
        XCTAssertFalse(signaling.contains("sessionTenantID: original.nebulaId"))
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
    XCTAssertFalse(support.contains("static func sha256File"))
    XCTAssertTrue(manager.contains("var inboundFileTransferApprovalProvider"))
    XCTAssertTrue(manager.contains("let inboundFileTransferIO = InboundFileTransferIOActor.shared"))
    XCTAssertTrue(fileTransfer.contains("Self.validateInboundMetadata"))
    XCTAssertTrue(fileTransfer.contains("Self.validateInboundTransferId"))
    XCTAssertTrue(fileTransfer.contains("await inboundFileTransferApprovalProvider(approvalRequest)"))
    XCTAssertTrue(fileTransfer.contains("Self.normalizedInboundApprovalRejectionMessage(reason)"))
    XCTAssertTrue(fileTransfer.contains("Self.expectedInboundChunkSize"))
    XCTAssertFalse(fileTransfer.contains("Self.sha256File"))
    XCTAssertFalse(fileTransfer.contains("FileHandle"))
    XCTAssertFalse(fileTransfer.contains("FileManager.default.moveItem"))
    XCTAssertTrue(fileTransfer.contains("inboundFileTransferIO.closeAndDigest"))
    XCTAssertTrue(fileTransfer.contains("inboundFileTransferIO.releaseCommittedFile"))
    XCTAssertTrue(fileTransfer.contains("guard let senderId = Self.requiredInboundSenderDeviceId(msg.senderDeviceId)"))
    XCTAssertTrue(fileTransfer.contains("Self.inboundFileTransferMissingSenderIdentityMessage"))
    XCTAssertFalse(fileTransfer.contains("msg.senderDeviceId ?? (remoteDeviceId ?? \"mac\")"))
  }

  func testInboundFileTransferRequiresProtocolSenderIdentity() {
    XCTAssertEqual(CrossNetworkWebRTCManager.requiredInboundSenderDeviceId(" sender "), "sender")
    XCTAssertNil(CrossNetworkWebRTCManager.requiredInboundSenderDeviceId(nil))
    XCTAssertNil(CrossNetworkWebRTCManager.requiredInboundSenderDeviceId(" \n\t "))
  }

  func testInboundFileTransferMetadataHasFiniteFileAndChunkCountLimits() {
    XCTAssertEqual(
      CrossNetworkWebRTCManager.validateInboundMetadata(
        fileName: "payload.bin",
        fileSize: CrossNetworkWebRTCManager.maxInboundWebRTCFileSize + 1,
        chunkSize: 512 * 1024,
        totalChunks: 1
      ),
      "Invalid metadata (fileSize out of range)"
    )
    XCTAssertEqual(
      CrossNetworkWebRTCManager.validateInboundMetadata(
        fileName: "payload.bin",
        fileSize: Int64(CrossNetworkWebRTCManager.maxInboundWebRTCFileTransferChunks + 1),
        chunkSize: 1,
        totalChunks: CrossNetworkWebRTCManager.maxInboundWebRTCFileTransferChunks + 1
      ),
      "Invalid metadata (totalChunks out of range)"
    )
  }

  @MainActor
  func testInboundFileTransferTerminalReceiptCacheIsPerSessionBoundedAndTTLBounded() {
    let now = Date(timeIntervalSince1970: 2_000)
    let metadata = CrossNetworkWebRTCManager.InboundFileTransferMetadataBinding(
      version: 1,
      senderDeviceId: "mac",
      senderDeviceName: "Mac",
      fileName: "payload.bin",
      fileSize: 4,
      chunkSize: 4,
      totalChunks: 1,
      mimeType: nil,
      encryption: nil,
      batchId: nil,
      batchIndex: nil,
      batchTotal: nil,
      relativePath: nil
    )
    let completionMessage = CrossNetworkFileTransferMessage(
      op: .complete,
      transferId: "binding-only",
      receivedBytes: 4,
      fileSha256: Data(repeating: 9, count: 32)
    )
    let completion = CrossNetworkWebRTCManager.InboundFileTransferCompletionBinding(
      message: completionMessage
    )
    var cache = CrossNetworkWebRTCManager.InboundFileTransferTerminalReceiptCache(
      maxReceiptsPerSession: 1,
      timeToLive: 10
    )

    cache.store(
      sessionID: "session-a",
      transferID: "transfer-a",
      metadataBinding: metadata,
      completionBinding: completion,
      response: .init(op: .completeAck, transferId: "transfer-a", receivedBytes: 4),
      label: "completeAck",
      now: now
    )
    cache.store(
      sessionID: "session-b",
      transferID: "transfer-a",
      metadataBinding: metadata,
      completionBinding: completion,
      response: .init(op: .error, transferId: "transfer-a", message: "terminal"),
      label: "completeError",
      now: now
    )
    cache.store(
      sessionID: "session-a",
      transferID: "transfer-b",
      metadataBinding: metadata,
      completionBinding: completion,
      response: .init(op: .completeAck, transferId: "transfer-b", receivedBytes: 4),
      label: "completeAck",
      now: now
    )

    XCTAssertNil(cache.receipt(sessionID: "session-a", transferID: "transfer-a", now: now))
    XCTAssertEqual(
      cache.receipt(sessionID: "session-a", transferID: "transfer-b", now: now)?.response.op,
      .completeAck
    )
    XCTAssertEqual(
      cache.receipt(sessionID: "session-b", transferID: "transfer-a", now: now)?.response.op,
      .error
    )
    XCTAssertNil(
      cache.receipt(
        sessionID: "session-a",
        transferID: "transfer-b",
        now: now.addingTimeInterval(10)
      )
    )
  }

  func testInboundFileTransferTerminalReceiptIsRecordedBeforeActiveStateRemoval() throws {
    let fileTransfer = try crossNetworkWebRTCFileTransferSource()
    let support = try crossNetworkWebRTCInboundFileTransferSupportSource()

    guard let helperStart = fileTransfer.range(of: "private func terminateInboundFileTransfer("),
          let helperEnd = fileTransfer.range(of: "private func finalizeInboundFileTransfer(", range: helperStart.upperBound..<fileTransfer.endIndex),
          let record = fileTransfer.range(
            of: "recordInboundFileTransferTerminalReceipt(",
            range: helperStart.upperBound..<helperEnd.lowerBound
          ),
          let removal = fileTransfer.range(
            of: "removeInboundFileTransferState(state.transferId)",
            range: helperStart.upperBound..<helperEnd.lowerBound
          ) else {
      return XCTFail("terminateInboundFileTransfer must cache the exact terminal receipt before removing active state")
    }

    XCTAssertLessThan(
      fileTransfer.distance(from: fileTransfer.startIndex, to: record.lowerBound),
      fileTransfer.distance(from: fileTransfer.startIndex, to: removal.lowerBound)
    )
    XCTAssertTrue(fileTransfer.contains("receipt.completionBinding == InboundFileTransferCompletionBinding(message: msg)"))
    XCTAssertTrue(fileTransfer.contains("receipt.metadataBinding == metadataBinding"))
    XCTAssertTrue(fileTransfer.contains("transferId metadata conflict"))
    XCTAssertTrue(fileTransfer.contains("scheduleInboundFileTransferIdleTimeout"))
    XCTAssertTrue(fileTransfer.contains("current.stateToken == state.stateToken"))
    XCTAssertTrue(fileTransfer.contains("current.revision == state.revision"))
    XCTAssertTrue(fileTransfer.contains("activeTransfersForSession + pendingTransfersForSession < Self.maxConcurrentInboundWebRTCFileTransfersPerSession"))
    XCTAssertTrue(fileTransfer.contains("inboundFileTransferLifecycleToken == expectedLifecycleToken"))
    XCTAssertTrue(fileTransfer.contains("sessionKeys?.sessionId == sessionID"))
    XCTAssertTrue(fileTransfer.contains("inboundFileTransferPendingAdmissions[msg.transferId]?.token == admissionToken"))
    XCTAssertTrue(support.contains("struct InboundFileTransferTerminalReceiptCache"))
    XCTAssertTrue(support.contains("maxReceiptsPerSession: Int = 128"))
    XCTAssertTrue(support.contains("timeToLive: TimeInterval = 300"))
    XCTAssertTrue(support.contains("maxInboundWebRTCFileSize: Int64 = 2 * 1024 * 1024 * 1024"))
    XCTAssertTrue(support.contains("maxInboundWebRTCFileTransferChunks = 65_536"))
  }

  func testInboundFileTransferIOActorSupportsCancellationAndTwoPhaseRollback() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("iOSInboundIOActor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let ioActor = InboundFileTransferIOActor(maxOpenTransfers: 1)
    let temporaryURL = directory.appendingPathComponent("payload.partial")
    let handle = try await ioActor.createTemporaryFile(at: temporaryURL, declaredFileSize: 1)
    _ = try await ioActor.write(Data([7]), atOffset: 0, using: handle)
    _ = try await ioActor.closeAndDigest(using: handle)
    let committedURL = try await ioActor.commit(
      using: handle,
      destinationDirectory: directory,
      fileName: "payload.bin"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL.path))
    try await ioActor.discard(handle)
    XCTAssertFalse(FileManager.default.fileExists(atPath: committedURL.path))

    let cancelledDigest = Task {
      withUnsafeCurrentTask { task in task?.cancel() }
      return try await ioActor.digest(Data([1]))
    }
    do {
      _ = try await cancelledDigest.value
      XCTFail("Cancelled digest must throw CancellationError")
    } catch is CancellationError {
      // Expected.
    }
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
    } catch let error as P2PConnectionManager.ConnectionReadyTimeoutError {
      XCTAssertEqual(error.lastState, .setup)
      XCTAssertNil(error.lastWaitingError)
      XCTAssertLessThan(
        Date().timeIntervalSince(startedAt),
        1.0,
        "Connection candidate timeout must not hang behind an uncancellable continuation."
      )
    } catch {
      XCTFail("Connection timeout must preserve typed state, got: \(error)")
    }
  }

  func testP2PConnectionReadyGatePreservesLastWaitingNetworkErrorAtTimeout() async {
    let gate = P2PConnectionManager.ConnectionReadyGate()
    gate.onState(.preparing)
    gate.onState(.waiting(.posix(.ENETDOWN)))

    do {
      try await gate.waitReady(timeoutSeconds: 0.01)
      XCTFail("A waiting connection must still respect the bounded deadline.")
    } catch let error as P2PConnectionManager.ConnectionReadyTimeoutError {
      XCTAssertEqual(error.lastState, .waiting)
      XCTAssertEqual(error.lastWaitingError, .posix(.ENETDOWN))
    } catch {
      XCTFail("Connection timeout must preserve the last NWError, got: \(error)")
    }
  }

  func testP2PConnectionReadyGateNetworkCancellationResumesImmediately() async {
    let gate = P2PConnectionManager.ConnectionReadyGate()
    gate.onState(.cancelled)

    do {
      try await gate.waitReady(timeoutSeconds: 30)
      XCTFail("A network-cancelled connection must not wait for the timeout.")
    } catch is P2PConnectionManager.ConnectionReadyCancelledError {
      // Expected typed transport cancellation.
    } catch {
      XCTFail("Network cancellation must preserve its typed error, got: \(error)")
    }
  }

  func testP2PConnectionReadyGateCancellationResumesImmediately() async {
    let gate = P2PConnectionManager.ConnectionReadyGate()
    let waitTask = Task {
      try await gate.waitReady(timeoutSeconds: 30)
    }
    await Task.yield()

    let cancelledAt = Date()
    waitTask.cancel()
    do {
      try await waitTask.value
      XCTFail("Cancelled ready wait must not succeed.")
    } catch is CancellationError {
      XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.0)
    } catch {
      XCTFail("Cancelled ready wait must preserve CancellationError, got: \(error)")
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

  func testPlainFrameReceiveGateCancellationResumesImmediately() async {
    let gate = P2PConnectionManager.PlainFrameReceiveGate()
    let waitTask = Task {
      try await gate.wait(timeoutSeconds: 30)
    }
    await Task.yield()

    let cancelledAt = Date()
    waitTask.cancel()
    do {
      _ = try await waitTask.value
      XCTFail("Cancelled receive wait must not succeed.")
    } catch is CancellationError {
      XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.0)
    } catch {
      XCTFail("Cancelled receive wait must preserve CancellationError, got: \(error)")
    }
  }

  @MainActor
  func testPendingPairingApprovalCancellationRejectsAndCleansExactWaiter() async {
    let manager = P2PConnectionManager.instance
    manager.testOnlyResetPendingPairingDecisionState()
    defer { manager.testOnlyResetPendingPairingDecisionState() }

    let approvalTask = Task { @MainActor in
      await manager.testOnlyAwaitPairingDecision(timeout: .seconds(30))
    }
    for _ in 0..<20 where manager.testOnlyPendingPairingDecisionWaiterCount == 0 {
      await Task.yield()
    }
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 1)
    XCTAssertTrue(manager.testOnlyHasPendingPairingApproval)

    approvalTask.cancel()
    let decision = await approvalTask.value

    XCTAssertEqual(decision, .reject)
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 0)
    XCTAssertFalse(manager.testOnlyHasPendingPairingApproval)
  }

  @MainActor
  func testPendingPairingApprovalTimeoutCleansState() async {
    let manager = P2PConnectionManager.instance
    manager.testOnlyResetPendingPairingDecisionState()
    defer { manager.testOnlyResetPendingPairingDecisionState() }

    let decision = await manager.testOnlyAwaitPairingDecision(timeout: .milliseconds(20))

    XCTAssertEqual(decision, .timedOut)
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 0)
    XCTAssertFalse(manager.testOnlyHasPendingPairingApproval)
  }

  @MainActor
  func testPendingPairingApprovalIsBoundedAndDoesNotReplaceVisiblePrompt() async {
    let manager = P2PConnectionManager.instance
    manager.testOnlyResetPendingPairingDecisionState()
    defer { manager.testOnlyResetPendingPairingDecisionState() }

    let firstApprovalTask = Task { @MainActor in
      await manager.testOnlyAwaitPairingDecision(timeout: .seconds(30))
    }
    for _ in 0..<20 where manager.testOnlyPendingPairingDecisionWaiterCount == 0 {
      await Task.yield()
    }
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 1)

    let secondDecision = await manager.testOnlyAwaitPairingDecision(timeout: .seconds(30))

    XCTAssertEqual(secondDecision, .reject)
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 1)
    XCTAssertTrue(manager.testOnlyHasPendingPairingApproval)

    firstApprovalTask.cancel()
    let firstDecision = await firstApprovalTask.value
    XCTAssertEqual(firstDecision, .reject)
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 0)
    XCTAssertFalse(manager.testOnlyHasPendingPairingApproval)

    // Re-present immediately after the busy -> cancellation teardown. This exercises the same
    // rapid state sequence that previously deallocated the prompt's hosting controller while its
    // UIKit appearance transition was still closing.
    let replacementApprovalTask = Task { @MainActor in
      await manager.testOnlyAwaitPairingDecision(timeout: .seconds(30))
    }
    for _ in 0..<20 where manager.testOnlyPendingPairingDecisionWaiterCount == 0 {
      await Task.yield()
    }
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 1)
    XCTAssertTrue(manager.testOnlyHasPendingPairingApproval)

    replacementApprovalTask.cancel()
    let replacementDecision = await replacementApprovalTask.value
    XCTAssertEqual(replacementDecision, .reject)
    XCTAssertEqual(manager.testOnlyPendingPairingDecisionWaiterCount, 0)
    XCTAssertFalse(manager.testOnlyHasPendingPairingApproval)
  }

  @MainActor
  func testStandalonePairingApprovalTimeoutCleansAllOwnedState() async throws {
    let manager = P2PConnectionManager.instance
    manager.testOnlyResetPendingPairingDecisionState()
    defer { manager.testOnlyResetPendingPairingDecisionState() }

    _ = try manager.testOnlyInstallStandalonePairingApproval(
      timeout: .milliseconds(20)
    )
    XCTAssertTrue(manager.testOnlyHasPendingPairingApproval)
    XCTAssertEqual(manager.testOnlyStandalonePairingTimeoutTaskCount, 1)
    let expiredRequest = try XCTUnwrap(manager.pendingPairingTrustRequest)

    for _ in 0..<100 where manager.testOnlyHasPendingPairingApproval {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertFalse(manager.testOnlyHasPendingPairingApproval)
    XCTAssertEqual(manager.testOnlyStandalonePairingTimeoutTaskCount, 0)

    let replacementRequestID = try manager.testOnlyInstallStandalonePairingApproval(
      timeout: .seconds(30)
    )
    do {
      try await manager.resolvePairingTrustRequest(expiredRequest, decision: .allowOnce)
      XCTFail("An expired standalone request must not be revived by a stale UI decision.")
    } catch let error as P2PConnectionManager.PairingTrustResolutionError {
      XCTAssertEqual(error, .requestNoLongerPending)
    }
    XCTAssertEqual(manager.pendingPairingTrustRequest?.id, replacementRequestID)
    XCTAssertEqual(manager.testOnlyStandalonePairingTimeoutTaskCount, 1)
  }

  @MainActor
  func testStandalonePairingApprovalTimerFailureRejectsWithoutCrashing() async throws {
    let manager = P2PConnectionManager.instance
    manager.testOnlyResetPendingPairingDecisionState()
    defer { manager.testOnlyResetPendingPairingDecisionState() }

    _ = try manager.testOnlyInstallStandalonePairingApproval(
      timeout: .seconds(30),
      sleep: { _ in throw PairingTimerTestError.injectedFailure }
    )
    for _ in 0..<100 where manager.testOnlyHasPendingPairingApproval {
      await Task.yield()
    }

    XCTAssertFalse(manager.testOnlyHasPendingPairingApproval)
    XCTAssertEqual(manager.testOnlyStandalonePairingTimeoutTaskCount, 0)
    XCTAssertEqual(
      manager.lastError,
      "Pairing approval timer failed; request rejected fail closed"
    )
  }

  @MainActor
  func testPairingDecisionClaimRejectsASecondResolutionWithTypedError() async throws {
    let manager = P2PConnectionManager.instance
    manager.testOnlyResetPendingPairingDecisionState()
    defer { manager.testOnlyResetPendingPairingDecisionState() }

    let approvalTask = Task { @MainActor in
      await manager.testOnlyAwaitPairingDecision(timeout: .seconds(30))
    }
    for _ in 0..<20 where manager.pendingPairingTrustRequest == nil {
      await Task.yield()
    }
    let request = try XCTUnwrap(manager.pendingPairingTrustRequest)

    try await manager.resolvePairingTrustRequest(request, decision: .timedOut)
    let firstDecision = await approvalTask.value
    XCTAssertEqual(firstDecision, .timedOut)

    let replacementRequestID = try manager.testOnlyInstallStandalonePairingApproval(
      timeout: .seconds(30)
    )

    do {
      try await manager.resolvePairingTrustRequest(request, decision: .timedOut)
      XCTFail("A pairing request must be atomically claimed at most once.")
    } catch let error as P2PConnectionManager.PairingTrustResolutionError {
      XCTAssertEqual(error, .requestNoLongerPending)
    }
    XCTAssertEqual(manager.pendingPairingTrustRequest?.id, replacementRequestID)
    XCTAssertEqual(manager.testOnlyStandalonePairingTimeoutTaskCount, 1)
  }

  @MainActor
  func testPairingTrustPromptWindowPresenterKeepsStableControllerAcrossRapidTeardown() async throws {
    let coordinator = PairingTrustPromptWindowPresenter.Coordinator(
      sceneActivationEvaluator: { _ in true }
    )

    func makeRequest(id: UUID, name: String) -> P2PConnectionManager.PairingTrustRequest {
      P2PConnectionManager.PairingTrustRequest(
        id: id,
        purpose: .protocolIdentityBinding,
        peerId: "peer-\(id.uuidString)",
        declaredDeviceId: "device-\(id.uuidString)",
        deviceName: name,
        platform: .macOS,
        modelName: "Test Mac",
        osVersion: "TestOS",
        kemKeyCount: 0,
        verificationCode: "000000",
        protocolIdentityFingerprint: "test-fingerprint",
        receivedAt: Date()
      )
    }

    func drainMainQueue() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          continuation.resume()
        }
      }
    }

    let firstRequest = makeRequest(id: UUID(), name: "First Peer")
    let replacementRequest = makeRequest(id: UUID(), name: "Replacement Peer")
    let hostScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    let sceneHost = try PairingPromptSceneHost(scene: hostScene)
    let hostViewController = sceneHost.viewController
    var forwardedRequestIDs: [UUID] = []
    var forwardedDecisions: [P2PConnectionManager.PairingTrustDecision] = []
    let forwardDecision: @MainActor (
      P2PConnectionManager.PairingTrustRequest,
      P2PConnectionManager.PairingTrustDecision
    ) -> Void = { request, decision in
      forwardedRequestIDs.append(request.id)
      forwardedDecisions.append(decision)
    }

    // A request can arrive before SwiftUI has attached the representable host to a scene. It must
    // remain pending without guessing a global scene, then present when this exact host is mounted.
    coordinator.update(
      request: firstRequest,
      hostViewController: hostViewController,
      sceneIsActive: true,
      onDecision: forwardDecision
    )
    XCTAssertNil(coordinator.testOnlyWindowIdentifier)

    sceneHost.attach()
    await drainMainQueue()
    XCTAssertTrue(hostViewController.view.window?.windowScene === hostScene)
    defer {
      coordinator.retireWindow()
      sceneHost.detach()
    }

    coordinator.hostWindowSceneDidChange(hostScene)
    let windowIdentifier = try XCTUnwrap(coordinator.testOnlyWindowIdentifier)
    let hostingControllerIdentifier = try XCTUnwrap(
      coordinator.testOnlyHostingControllerIdentifier)
    let staleDecisionHandler = try XCTUnwrap(coordinator.testOnlyDecisionHandler())
    XCTAssertEqual(coordinator.testOnlyIsWindowHidden, false)
    XCTAssertTrue(coordinator.testOnlyHasPromptContent)

    coordinator.update(
      request: firstRequest,
      hostViewController: hostViewController,
      sceneIsActive: false,
      onDecision: forwardDecision
    )
    XCTAssertEqual(coordinator.testOnlyWindowIdentifier, windowIdentifier)
    XCTAssertTrue(coordinator.testOnlyIsWindowConcealed)
    XCTAssertEqual(coordinator.testOnlyIsWindowKey, false)
    XCTAssertTrue(
      hostScene.windows.contains { window in
        window.isKeyWindow && window !== coordinator.testOnlyWindowObject
      }
    )
    staleDecisionHandler(.allowOnce)
    XCTAssertTrue(forwardedRequestIDs.isEmpty)

    coordinator.update(
      request: firstRequest,
      hostViewController: hostViewController,
      sceneIsActive: true,
      onDecision: forwardDecision
    )
    XCTAssertEqual(coordinator.testOnlyWindowIdentifier, windowIdentifier)
    XCTAssertEqual(
      coordinator.testOnlyHostingControllerIdentifier,
      hostingControllerIdentifier
    )
    XCTAssertFalse(coordinator.testOnlyIsWindowConcealed)
    XCTAssertEqual(coordinator.testOnlyIsWindowKey, true)
    let reactivatedDecisionHandler = try XCTUnwrap(coordinator.testOnlyDecisionHandler())

    coordinator.dismissWindow()
    XCTAssertEqual(coordinator.testOnlyIsWindowHidden, false)
    XCTAssertTrue(coordinator.testOnlyIsWindowConcealed)
    XCTAssertEqual(coordinator.testOnlyIsWindowKey, false)
    XCTAssertTrue(
      hostScene.windows.contains { window in
        window.isKeyWindow && window !== coordinator.testOnlyWindowObject
      }
    )
    XCTAssertTrue(
      coordinator.testOnlyHasPromptContent,
      "Prompt content must remain retained until UIKit can finish its appearance transition."
    )

    // Reuse the hidden window before its deferred cleanup runs. The old cleanup must be scoped to
    // the dismissed presentation and must not clear or hide this replacement request.
    coordinator.update(
      request: replacementRequest,
      hostViewController: hostViewController,
      sceneIsActive: true,
      onDecision: forwardDecision
    )
    await drainMainQueue()

    XCTAssertEqual(coordinator.testOnlyWindowIdentifier, windowIdentifier)
    XCTAssertEqual(
      coordinator.testOnlyHostingControllerIdentifier,
      hostingControllerIdentifier
    )
    XCTAssertEqual(coordinator.testOnlyIsWindowHidden, false)
    XCTAssertFalse(coordinator.testOnlyIsWindowConcealed)
    XCTAssertTrue(coordinator.testOnlyHasPromptContent)

    staleDecisionHandler(.reject)
    reactivatedDecisionHandler(.reject)
    XCTAssertTrue(forwardedRequestIDs.isEmpty)
    XCTAssertEqual(coordinator.testOnlyIsWindowHidden, false)
    XCTAssertFalse(coordinator.testOnlyIsWindowConcealed)

    let replacementDecisionHandler = try XCTUnwrap(coordinator.testOnlyDecisionHandler())
    replacementDecisionHandler(.allowOnce)
    replacementDecisionHandler(.reject)
    XCTAssertEqual(forwardedRequestIDs, [replacementRequest.id])
    XCTAssertEqual(forwardedDecisions, [.allowOnce])
    XCTAssertTrue(coordinator.testOnlyIsWindowConcealed)
    XCTAssertEqual(coordinator.testOnlyIsWindowKey, false)
    XCTAssertTrue(
      hostScene.windows.contains { window in
        window.isKeyWindow && window !== coordinator.testOnlyWindowObject
      }
    )

    // SwiftUI may deliver one more update before the manager publishes nil. A settled request must
    // remain concealed and must never mint a fresh decision token.
    coordinator.update(
      request: replacementRequest,
      hostViewController: hostViewController,
      sceneIsActive: true,
      onDecision: forwardDecision
    )
    XCTAssertTrue(coordinator.testOnlyIsWindowConcealed)
    replacementDecisionHandler(.alwaysAllow)
    XCTAssertEqual(forwardedRequestIDs, [replacementRequest.id])
    XCTAssertEqual(forwardedDecisions, [.allowOnce])

    for _ in 0..<100 where coordinator.testOnlyHasPromptContent {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(coordinator.testOnlyHasPromptContent)
    XCTAssertEqual(coordinator.testOnlyIsWindowHidden, false)
    XCTAssertTrue(coordinator.testOnlyIsWindowConcealed)
    XCTAssertEqual(coordinator.testOnlyWindowIdentifier, windowIdentifier)
    XCTAssertEqual(
      coordinator.testOnlyHostingControllerIdentifier,
      hostingControllerIdentifier
    )

    weak var retiredPromptWindow: UIWindow?
    weak var retiredHostingController: UIViewController?
    retiredPromptWindow = coordinator.testOnlyWindowObject
    retiredHostingController = coordinator.testOnlyHostingControllerObject
    coordinator.retireWindow()
    XCTAssertNil(coordinator.testOnlyWindowIdentifier)
    XCTAssertNil(coordinator.testOnlyHostingControllerIdentifier)
    for _ in 0..<100 where retiredPromptWindow != nil || retiredHostingController != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(retiredPromptWindow)
    XCTAssertNil(retiredHostingController)
  }

  @MainActor
  func testPairingTrustPromptWaitsForBothActivationSignalsAndRebindsAfterDetach()
    async throws
  {
    let activationGate = PairingPromptActivationGate()
    let coordinator = PairingTrustPromptWindowPresenter.Coordinator(
      sceneActivationEvaluator: { _ in activationGate.allowsPresentation }
    )
    let hostScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    let sceneHost = try PairingPromptSceneHost(scene: hostScene)
    let hostViewController = sceneHost.viewController
    sceneHost.attach()
    defer {
      coordinator.retireWindow()
      sceneHost.detach()
    }

    let request = P2PConnectionManager.PairingTrustRequest(
      id: UUID(),
      purpose: .protocolIdentityBinding,
      peerId: "activation-test-peer",
      declaredDeviceId: "activation-test-device",
      deviceName: "Activation Test Peer",
      platform: .macOS,
      modelName: "Test Mac",
      osVersion: "TestOS",
      kemKeyCount: 0,
      verificationCode: "000000",
      protocolIdentityFingerprint: "activation-test-fingerprint",
      receivedAt: Date()
    )
    var forwardedDecisions: [P2PConnectionManager.PairingTrustDecision] = []
    let forwardDecision: @MainActor (
      P2PConnectionManager.PairingTrustRequest,
      P2PConnectionManager.PairingTrustDecision
    ) -> Void = { _, decision in
      forwardedDecisions.append(decision)
    }

    coordinator.update(
      request: request,
      hostViewController: hostViewController,
      sceneIsActive: false,
      onDecision: forwardDecision
    )
    coordinator.hostWindowSceneDidChange(hostScene)
    XCTAssertNil(coordinator.testOnlyWindowIdentifier)

    activationGate.allowsPresentation = true
    coordinator.update(
      request: request,
      hostViewController: hostViewController,
      sceneIsActive: false,
      onDecision: forwardDecision
    )
    XCTAssertNil(coordinator.testOnlyWindowIdentifier)

    coordinator.update(
      request: request,
      hostViewController: hostViewController,
      sceneIsActive: true,
      onDecision: forwardDecision
    )
    let originalWindow = try XCTUnwrap(coordinator.testOnlyWindowObject)
    let detachedHandler = try XCTUnwrap(coordinator.testOnlyDecisionHandler())

    sceneHost.detach()
    coordinator.hostWindowSceneDidChange(nil)
    XCTAssertNil(coordinator.testOnlyWindowIdentifier)
    XCTAssertFalse(originalWindow.isKeyWindow)
    XCTAssertEqual(originalWindow.alpha, 0)
    XCTAssertFalse(originalWindow.isUserInteractionEnabled)
    XCTAssertTrue(originalWindow.accessibilityElementsHidden)
    detachedHandler(.allowOnce)
    XCTAssertTrue(forwardedDecisions.isEmpty)

    sceneHost.attach()
    coordinator.hostWindowSceneDidChange(hostScene)
    let reboundWindow = try XCTUnwrap(coordinator.testOnlyWindowObject)
    XCTAssertFalse(reboundWindow === originalWindow)
    XCTAssertTrue(reboundWindow.windowScene === hostScene)

    for _ in 0..<100
      where !originalWindow.isHidden || originalWindow.rootViewController != nil
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(originalWindow.isHidden)
    XCTAssertNil(originalWindow.rootViewController)
    XCTAssertTrue(coordinator.testOnlyWindowObject === reboundWindow)
    XCTAssertFalse(reboundWindow.isHidden)
    XCTAssertEqual(reboundWindow.alpha, 1)
    XCTAssertTrue(reboundWindow.isUserInteractionEnabled)

    let reboundHandler = try XCTUnwrap(coordinator.testOnlyDecisionHandler())
    reboundHandler(.reject)
    XCTAssertEqual(forwardedDecisions, [.reject])
  }

  func testRealDeviceSmokeKeepsDynamicPortsDiagnosticAndUsesProductBonjourRoute() throws {
    let hostSource = try repositoryScriptSource("Sources/LocalLanInteropHost/main.swift")
    let smokeScript = try repositoryScriptSource("Scripts/run_real_device_p2p_remote_smoke.sh")
    let harnessSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift"
    )
    let p2pSource = try p2pConnectionManagerSource()

    XCTAssertTrue(hostSource.contains("waitForControlAdvertisementPort()"))
    XCTAssertTrue(hostSource.contains("private let p2pDiscoveryService = P2PDiscoveryService.shared"))
    XCTAssertTrue(hostSource.contains("try await p2pDiscoveryService.ensureStartedAndScanning()"))
    XCTAssertFalse(hostSource.contains("private let discoveryManager = DeviceDiscoveryManager()"))
    XCTAssertTrue(hostSource.contains("ready discovery=_skybridge._tcp port=\\(controlPort)"))
    XCTAssertFalse(
      hostSource.contains("ready discovery=_skybridge._tcp port=9527"),
      "The macOS smoke host must report the actual dynamic listener port, not a stale fixed port."
    )

    XCTAssertTrue(smokeScript.contains("MAC_CONTROL_PORT="))
    XCTAssertTrue(smokeScript.contains("SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE:-packaged"))
    XCTAssertTrue(smokeScript.contains("acceptance_violations+=(\"SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged\")"))
    XCTAssertTrue(smokeScript.contains("SMOKE_BUILD_DIR=\"${SKYBRIDGE_P2P_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/real-device-p2p-smoke}\""))
    XCTAssertTrue(smokeScript.contains("MAC_DIRECT_BIN=\"$SMOKE_BUILD_DIR/debug/LocalLanInteropHost\""))
    XCTAssertTrue(smokeScript.contains("MAC_SOURCE_DIRECT_BIN=\"$SMOKE_BUILD_DIR/debug/LocalLanSmokeSourceHost\""))
    XCTAssertTrue(smokeScript.contains("case \"$MAC_HOST_LAUNCH_MODE\" in"))
    XCTAssertTrue(
      smokeScript.contains("direct)\n      start_macos_smoke_host_directly")
    )
    XCTAssertTrue(smokeScript.contains("if [[ \"$LAB_RUN\" != \"1\" ]]"))
    XCTAssertTrue(smokeScript.contains("\"$MAC_DIRECT_BIN\" >\"$HOST_STDOUT\" 2>&1 &"))
    XCTAssertTrue(smokeScript.contains("launch method=direct-app-binary pid=$HOST_PID mode=direct binary=swiftpm-build-product"))
    XCTAssertFalse(smokeScript.contains("fallbackFrom=open-app-bundle"))
    XCTAssertTrue(smokeScript.contains("failed stage=mac-host"))
    XCTAssertTrue(smokeScript.contains("verify_mac_control_port_reachable \"$MAC_CONTROL_HOST\" \"$MAC_CONTROL_PORT\""))
    XCTAssertTrue(smokeScript.contains("mac-control-port reachable=1 host=$host port=$port source=local-self-probe"))
    XCTAssertTrue(smokeScript.contains("failed stage=mac-host phase=control-port-probe reason=tcp-unreachable"))
    XCTAssertTrue(smokeScript.contains("verify_host_pid_owns_listener_port \"$MAC_CONTROL_PORT\" \"control\""))
    XCTAssertTrue(smokeScript.contains("record_macos_smoke_host_launch_evidence"))
    XCTAssertFalse(smokeScript.contains("SKYBRIDGE_SMOKE_TARGET_CONTROL_PORT"))
    XCTAssertFalse(smokeScript.contains("SKYBRIDGE_SMOKE_TARGET_HOST"))
    XCTAssertFalse(smokeScript.contains("SKYBRIDGE_SMOKE_TARGET_REMOTE_PORT"))

    XCTAssertTrue(harnessSource.contains("verifyDiscoveredControlRoute"))
    XCTAssertTrue(harnessSource.contains("liveBonjourServiceEndpoints("))
    XCTAssertTrue(harnessSource.contains("liveBonjourControlEndpoints: liveEndpoints"))
    XCTAssertTrue(harnessSource.contains("preferredInterface="))
    XCTAssertTrue(harnessSource.contains("source=bonjour-service"))
    XCTAssertFalse(harnessSource.contains("applySmokePinnedControlRoute"))
    XCTAssertFalse(harnessSource.contains("control-route-preflight"))

    XCTAssertTrue(
      p2pSource.contains("let endpoints = connectionEndpointCandidates(for: device)"),
      "PIB-1 OOB binding must use the provenance-bound DNS-SD control route."
    )
  }

  func testIOSSmokeRuntimeIsCompileIsolatedAndReleaseSmokeScriptsOptInExplicitly() throws {
    let smokeRuntimePaths = [
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift",
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalWebRTCSmokeHarness.swift",
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/SmokeStatusReporter.swift",
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/SmokeSupport.swift",
    ]

    for path in smokeRuntimePaths {
      let source = try repositoryScriptSource(path)
      XCTAssertTrue(
        source.hasPrefix("#if DEBUG || SKYBRIDGE_TESTING\n"),
        "\(path) must be absent from an ordinary Release compilation."
      )
    }

    let p2pScript = try repositoryScriptSource("Scripts/run_real_device_p2p_remote_smoke.sh")
    let webRTCScript = try repositoryScriptSource("Scripts/run_real_device_webrtc_smoke.sh")
    let releaseOptIn = "OTHER_SWIFT_FLAGS=\\$(inherited) -D SKYBRIDGE_TESTING"

    XCTAssertTrue(p2pScript.contains(releaseOptIn))
    XCTAssertTrue(webRTCScript.contains(releaseOptIn))
  }

  func testRealDeviceSmokeRejectsStalePIBV3MacClientAndPreservesIOSProtocolTrace() throws {
    let smokeScript = try repositoryScriptSource("Scripts/run_real_device_p2p_remote_smoke.sh")
    let freshnessGate = try sourceSlice(
      from: "verify_macos_online_ipad_pib_v3_wire_freshness()",
      to: "verify_macos_online_ipad_app_bundle()",
      in: smokeScript
    )
    let appVerification = try sourceSlice(
      from: "verify_macos_online_ipad_app_bundle()",
      to: "verify_macos_online_ipad_framework_resolution()",
      in: smokeScript
    )
    let cleanup = try sourceSlice(
      from: "cleanup()",
      to: "trap cleanup EXIT",
      in: smokeScript
    )

    XCTAssertTrue(freshnessGate.contains("SkyBridge-PIB-1-V3-Confirm"))
    XCTAssertTrue(freshnessGate.contains("SkyBridge-PIB-1-V3-SignedFinalAck"))
    XCTAssertTrue(
      freshnessGate.contains("LC_ALL=C /usr/bin/grep -aFq -- \"$marker\" \"$MAC_ONLINE_APP_BIN\"")
    )
    XCTAssertTrue(freshnessGate.contains("[[ \"$wire_source\" -nt \"$MAC_ONLINE_APP_BIN\" ]]"))
    XCTAssertTrue(
      freshnessGate.contains("Refusing a protocol-incompatible packaged client that iOS must reject fail closed.")
    )
    XCTAssertTrue(appVerification.contains("verify_macos_online_ipad_pib_v3_wire_freshness"))

    XCTAssertTrue(smokeScript.contains("IOS_TRACE_NAME=\"${IOS_STATUS_NAME}.trace.log\""))
    XCTAssertTrue(
      smokeScript.contains(
        "IOS_TRACE_LOCAL=\"$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.trace.log\""
      )
    )
    XCTAssertTrue(
      smokeScript.contains(
        "copy_ios_app_cache_file \"$IOS_TRACE_NAME\" \"$IOS_TRACE_LOCAL\" \"trace\""
      )
    )
    XCTAssertTrue(cleanup.contains("copy_ios_trace || true"))
    XCTAssertFalse(
      freshnessGate.contains("PIB-1-v2"),
      "A stale packaged client must be rebuilt; the release smoke must not enable a PIB-v2 compatibility path."
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
      audioSource.contains("private var activatedSession: AVAudioSession?"),
      "Audio teardown must track session activation independently from engine construction."
    )
    XCTAssertTrue(audioSource.contains("activatedSession = session"))
    XCTAssertTrue(
      audioSource.contains(
        "self.engine = engine\n        self.playerNode = playerNode\n        do {\n            try engine.start()"
      ),
      "A partially constructed engine must be owned before start can fail."
    )
    XCTAssertTrue(
      audioSource.contains("teardown(deactivateSession: true, resetFailureState: false)"),
      "Engine-start failure must release the controller-owned audio session."
    )
    XCTAssertTrue(audioSource.contains("if deactivateSession, let activatedSession"))
    XCTAssertTrue(audioSource.contains("self.activatedSession = nil"))
    XCTAssertFalse(
      audioSource.contains("hadPlaybackPipeline"),
      "Engine/player existence is not proof of AVAudioSession activation ownership."
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
    XCTAssertTrue(source.contains("SkyBridgeDiagnosticTrace.appendStatus(streamConfigLine)"))
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
    XCTAssertTrue(failureBody.contains("SkyBridgeDiagnosticTrace.appendStatus("))
    XCTAssertTrue(failureBody.contains("audioRxReceiverStartFailed"))
    XCTAssertTrue(failureBody.contains("SkyBridgeDiagnosticTrace.appendMediaDiagnostic("))
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
    let trustedDeviceStore = TrustedDeviceStore.shared
    let originalTrustedDevices = trustedDeviceStore.trustedDevices
    try trustedDeviceStore.replaceTrustedDevicesForTesting([])
    defer {
      XCTAssertNoThrow(
        try trustedDeviceStore.replaceTrustedDevicesForTesting(originalTrustedDevices)
      )
    }
    await KEMTrustStore.shared.clearForTesting()
    await ProtocolIdentityTrustStore.shared.clearForTesting()

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
      scriptSource.contains("PQC_TRUST_MODE=\"${SKYBRIDGE_SMOKE_PQC_TRUST_MODE:-actual}\""))
    XCTAssertTrue(scriptSource.contains("if [[ \"$LAB_RUN\" != \"1\" ]]; then"))
    XCTAssertTrue(
      scriptSource.contains("SKYBRIDGE_SMOKE_PQC_TRUST_MODE=user|actual"),
      "Injected trust must remain a lab-only diagnostic and cannot satisfy release acceptance."
    )
    XCTAssertTrue(
      scriptSource.contains(
        "SMOKE_REQUIRE_SIGNED_KEM_REFRESH=\"${SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH:-1}\""))
    XCTAssertTrue(
      scriptSource.contains(
        "SMOKE_FORCE_SIGNED_KEM_REFRESH=\"${SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH:-$SMOKE_REQUIRE_SIGNED_KEM_REFRESH}\""
      ))
    XCTAssertFalse(scriptSource.contains("SMOKE_AUTO_APPROVE_PAIRING=\"${"))
    XCTAssertTrue(
      scriptSource.contains(
        "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH=\"$SMOKE_REQUIRE_SIGNED_KEM_REFRESH\""))
    XCTAssertTrue(
      scriptSource.contains(
        "SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH=\"$SMOKE_FORCE_SIGNED_KEM_REFRESH\""))
    XCTAssertFalse(scriptSource.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=\"$SMOKE_AUTO_APPROVE_PAIRING\""))
    XCTAssertTrue(scriptSource.contains("\"SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH\""))
    XCTAssertTrue(scriptSource.contains("\"SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH\""))
    XCTAssertFalse(scriptSource.contains("\"SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING\""))
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
    XCTAssertTrue(scriptSource.contains("MAC_APP_BUNDLE=\"$MAC_ONLINE_RUNTIME_DIR/LocalLanInteropHost.app\""))
    XCTAssertTrue(scriptSource.contains("prepare_macos_smoke_host_app_bundle()"))
    XCTAssertTrue(scriptSource.contains("start_macos_smoke_host()"))
    XCTAssertTrue(scriptSource.contains("/usr/bin/open"))
    XCTAssertTrue(scriptSource.contains("register_macos_smoke_host_app_bundle()"))
    XCTAssertTrue(scriptSource.contains("MAC_HOST_PRODUCT_APP_BUNDLE=\"$ROOT_DIR/dist/SkyBridge Compass Pro.app\""))
    XCTAssertTrue(scriptSource.contains("MAC_HOST_PRODUCT_BUNDLE_ID=\"com.skybridge.compass.pro\""))
    XCTAssertTrue(scriptSource.contains("skybridge_resolve_profile_bound_codesign_identity_hash"))
    XCTAssertTrue(scriptSource.contains("derive_macos_smoke_host_minimal_entitlements"))
    XCTAssertFalse(scriptSource.contains("LocalLanInteropHostSmoke.${RUN_ID}"))
    XCTAssertFalse(scriptSource.contains("fallback=direct-app-binary"))
    XCTAssertTrue(scriptSource.contains("SKYBRIDGE_SMOKE_ROLE=mac-smoke-source"))
    XCTAssertTrue(scriptSource.contains("windowOcclusionVisible=1"))
    XCTAssertTrue(
      scriptSource.contains(
        "local source_webrtc_framework=\"$SMOKE_BUILD_DIR/debug/WebRTC.framework\""))
    XCTAssertTrue(scriptSource.contains("cp -R \"$source_webrtc_framework\" \"$macos_dir/WebRTC.framework\""))
    XCTAssertTrue(scriptSource.contains("cp \"$MAC_HOST_PRODUCT_PROFILE\" \"$embedded_profile\""))
    XCTAssertTrue(scriptSource.contains("--sign \"$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH\""))
    XCTAssertTrue(scriptSource.contains("--entitlements \"$MAC_HOST_HELPER_ENTITLEMENTS\""))
    XCTAssertFalse(scriptSource.contains("/usr/bin/codesign --force --deep --sign - \"$MAC_APP_BUNDLE\""))
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
      remoteViewSource.contains("SkyBridgeDiagnosticTrace.appendStatus(telemetryLine)"))
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
    XCTAssertTrue(
      inboundBody.contains(
        "expectedRemoteSOAPeerId: soaPeerIdBytes(for: stablePeerId)"
      )
    )
    XCTAssertTrue(messageASOACandidateBody.contains("soa.initiatorPeerId"))
    XCTAssertTrue(messageASOACandidateBody.contains("TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: fingerprint)"))
    XCTAssertTrue(messageASOACandidateBody.contains("ProtocolIdentityTrustStore.shared.deviceIds(containingFingerprint: fingerprint)"))
    XCTAssertTrue(messageASOACandidateBody.contains("activeAuthoritySnapshot()"))
    XCTAssertTrue(messageASOACandidateBody.contains("return []"))
    XCTAssertFalse(messageASOACandidateBody.contains("TrustedDeviceStore.shared.trustedDevices"))
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
      to: "enum RemoteDesktopDecodeQueuePolicy",
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
    XCTAssertTrue(source.contains("SkyBridgeDiagnosticTrace.appendStatus(telemetryLine)"))
  }

  func testSmokeTraceWriterKeepsStatusFileIOOffMediaHotPaths() throws {
    let writerBody = try diagnosticTraceSource()
    let smokeHarness = try skyBridgeCompassAppSource()
    let appendStatusBody = try sourceSlice(
      from: "static func appendStatus(_ line: @autoclosure () -> String)",
      to: "static func append(_ line: @autoclosure () -> String)",
      in: writerBody
    )
    let mediaDiagnosticBody = try sourceSlice(
      from: "static func appendMediaDiagnostic(_ fields: @autoclosure () -> [String: Any])",
      to: "private static func write(_ data: Data, to url: URL)",
      in: writerBody
    )

    XCTAssertTrue(writerBody.contains("private static let writerQueue"))
    XCTAssertTrue(writerBody.contains("private final class WriterState: @unchecked Sendable"))
    XCTAssertTrue(writerBody.contains("writerQueue.async"))
    XCTAssertTrue(writerBody.contains("static func flush()"))
    XCTAssertTrue(writerBody.contains("writerQueue.sync {}"))
    XCTAssertTrue(smokeHarness.contains("defer { SkyBridgeDiagnosticTrace.flush() }"))
    XCTAssertTrue(writerBody.contains("try SmokeArtifactFileIO.appendProtectedData(data, to: url)"))
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

  func testViewerSettingsPersistenceIsSerializedOffMainActorAndReportsFailures() throws {
    let managerSource = try remoteDesktopManagerSource()
    let runtimeModelsSource = try remoteDesktopRuntimeModelsSource()

    XCTAssertFalse(managerSource.contains("try? RemoteDesktopManagerRuntimeConfig.viewerSettingsStore.save"))
    XCTAssertFalse(managerSource.contains("viewerSettingsStore.load()"))
    XCTAssertTrue(runtimeModelsSource.contains("actor RemoteDesktopViewerSettingsPersistenceCoordinator"))
    XCTAssertTrue(runtimeModelsSource.contains("try store.loadOrThrow()"))
    XCTAssertTrue(runtimeModelsSource.contains("guard revision > latestSavedRevision else { return }"))
    XCTAssertTrue(managerSource.contains("pendingViewerSettingsPersistence"))
    XCTAssertTrue(managerSource.contains("viewerSettingsPersistenceError"))
    XCTAssertTrue(managerSource.contains("revision == self.viewerSettingsRevision"))
  }

  func testSampleBufferFramePumpDoesNotRetainCoordinatorAcrossSuspension() throws {
    let source = try remoteDesktopViewSource()
    let framePumpBody = try sourceSlice(
      from: "private func ensureFramePumpRunning()",
      to: "private func scheduleBufferedFrameDrain()",
      in: source
    )

    XCTAssertTrue(framePumpBody.contains("Task { @MainActor [weak self] in"))
    XCTAssertTrue(framePumpBody.contains("guard self != nil else { return }"))
    XCTAssertFalse(
      framePumpBody.contains("guard let self else { return }"),
      "The coordinator-owned frame pump must not promote weak self for the lifetime of its infinite loop."
    )
  }

  func testReleaseStartupAndTrustMigrationConstantsRemainAvailableWithoutTestHooks() throws {
    let appSource = try skyBridgeCompassAppSource()
    let startupPolicyBody = try sourceSlice(
      from: "private var shouldSkipInteractiveStartup: Bool",
      to: "private var shouldDisableAnimationsForUITests: Bool",
      in: appSource
    )
    let trustedDeviceStoreSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/TrustedDeviceStore.swift"
    )

    XCTAssertTrue(startupPolicyBody.contains("#if DEBUG || SKYBRIDGE_TESTING"))
    XCTAssertTrue(startupPolicyBody.contains("SkyBridgeRuntimeEnvironment.shouldSkipInteractiveStartup"))
    XCTAssertTrue(startupPolicyBody.contains("#else\n        false"))
    XCTAssertTrue(
      trustedDeviceStoreSource.contains(
        "private nonisolated static let authenticatedHandshakePinSource"
      )
    )
    XCTAssertTrue(
      trustedDeviceStoreSource.contains("private nonisolated static let legacyMigrationPinSource")
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
        "let shouldCacheFrozenFrame = RemoteDesktopFrozenFramePolicy.shouldCache("
      ))
    XCTAssertTrue(
      decodedOutputBody.contains(
        "renderFallbackForbidden: remoteDesktopRenderFallbackForbidden"
      ))
    XCTAssertTrue(
      decodedOutputBody.contains(
        "isReadOnlyCameraSession: isReadOnlyCameraSession"
      ),
      "Read-only camera sessions must skip the MainActor still-image cache as well as strict desktop sessions."
    )
    XCTAssertTrue(
      source.contains("&& !isReadOnlyCameraSession"),
      "The centralized frozen-frame policy must reject camera frames before CI-to-CGImage allocation."
    )
    XCTAssertTrue(
      decodedOutputBody.contains(
        "let frozenCandidate = shouldCacheFrozenFrame ? makeCGImage(from: presentationFrame) : nil"))
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
    let error = NWError.dns(DeviceDiscoveryManager.bonjourNoAuthDNSCode)

    XCTAssertTrue(DeviceDiscoveryManager.isBonjourAuthorizationError(error))
    XCTAssertEqual(DeviceDiscoveryManager.bonjourAuthorizationFailure(error), .noAuth)
    XCTAssertFalse(DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: error))
  }

  func testPolicyDeniedBrowseFailureIsAnAuthorizationBlocker() {
    let error = NWError.dns(DeviceDiscoveryManager.bonjourPolicyDeniedDNSCode)

    XCTAssertTrue(DeviceDiscoveryManager.isBonjourAuthorizationError(error))
    XCTAssertEqual(DeviceDiscoveryManager.bonjourAuthorizationFailure(error), .policyDenied)
    XCTAssertFalse(DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: error))
  }

  func testBonjourTimeoutIsRetryableButUnknownDNSErrorsAreNot() {
    XCTAssertTrue(
      DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: NWError.dns(-65568))
    )
    XCTAssertFalse(
      DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: NWError.dns(-65790)),
      "未知 DNS 错误不得被无限重建掩盖"
    )
  }

  func testTransientBrowserFailuresStillAutoRecover() {
    let error = NWError.posix(.ENETDOWN)

    XCTAssertFalse(DeviceDiscoveryManager.isBonjourAuthorizationError(error))
    XCTAssertTrue(DeviceDiscoveryManager.shouldAutoRecoverBrowser(after: error))
  }

  func testLateLocalNetworkAuthorizationRemainsRecoverableAtBoundedCadence() {
    XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 1), 2)
    XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 2), 5)
    XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 3), 10)
    XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 4), 30)
    XCTAssertEqual(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 40), 30)
    XCTAssertNil(DeviceDiscoveryManager.authorizationRecoveryDelay(forAttempt: 0))

    XCTAssertEqual(DeviceDiscoveryManager.nextAuthorizationRecoveryAttempt(after: 0), 1)
    XCTAssertEqual(DeviceDiscoveryManager.nextAuthorizationRecoveryAttempt(after: 3), 4)
    XCTAssertEqual(
      DeviceDiscoveryManager.nextAuthorizationRecoveryAttempt(after: 4),
      4,
      "权限弹窗在应用保持前台时晚于 17 秒处理，恢复监督仍必须存活，且重试状态不得无界增长"
    )
    XCTAssertEqual(DeviceDiscoveryManager.nextAuthorizationRecoveryAttempt(after: .max), 4)
  }

  // MARK: - Advertising startup recovery
  //
  // 回归背景：广播启动是一次性 fail-closed 事务，浏览器侧有完整的授权识别 + 指数
  // 重试，广播侧一个都没有。首次启动时 NWListener 发布 Bonjour 服务会触发本地网络
  // 权限弹窗，用户点“允许”之前 listener 停在 `.waiting`（此前落到 `default: break`
  // 完全不可见），8 秒硬超时后广播被取消且永不重试 —— 表现就是“启动后没有进入广播”。

  func testPendingLocalNetworkAuthorizationIsRetryable() {
    XCTAssertTrue(
      DeviceDiscoveryManager.shouldRetryAdvertising(
        after: DeviceDiscoveryManager.AdvertisingStartupError
          .localNetworkAuthorizationPending(seconds: 45)
      ),
      "等待本地网络授权是用户可解除的阻塞，必须保留自动恢复路径"
    )
  }

  func testAdvertisingStartupTimeoutIsRetryable() {
    XCTAssertTrue(
      DeviceDiscoveryManager.shouldRetryAdvertising(
        after: DeviceDiscoveryManager.AdvertisingStartupError.timedOut(seconds: 8)
      )
    )
  }

  func testTransientListenerFailuresAreRetryable() {
    XCTAssertTrue(
      DeviceDiscoveryManager.shouldRetryAdvertising(after: NWError.posix(.EADDRINUSE)),
      "端口尚未释放等瞬态失败必须重试，否则本机永久不可被发现"
    )
  }

  func testSupersededAndCancelledAdvertisingStartupsAreNotRetried() {
    XCTAssertFalse(
      DeviceDiscoveryManager.shouldRetryAdvertising(
        after: DeviceDiscoveryManager.AdvertisingStartupError.superseded
      ),
      "被新启动请求替换时重试会与当前所有者互相拆台"
    )
    XCTAssertFalse(
      DeviceDiscoveryManager.shouldRetryAdvertising(
        after: DeviceDiscoveryManager.AdvertisingStartupError.cancelledBeforeReady
      )
    )
    XCTAssertFalse(
      DeviceDiscoveryManager.shouldRetryAdvertising(after: CancellationError()),
      "显式停止监听不得被自动恢复重新拉起"
    )
  }

  func testListeningRecoveryDelayEscalatesThenHoldsAtCeiling() throws {
    XCTAssertEqual(try P2PConnectionManager.listeningRecoveryDelay(forAttempt: 1).get(), 3)
    XCTAssertEqual(try P2PConnectionManager.listeningRecoveryDelay(forAttempt: 2).get(), 8)
    XCTAssertEqual(try P2PConnectionManager.listeningRecoveryDelay(forAttempt: 3).get(), 20)
    XCTAssertEqual(try P2PConnectionManager.listeningRecoveryDelay(forAttempt: 4).get(), 45)

    let delays = try (1...40).map {
      try P2PConnectionManager.listeningRecoveryDelay(forAttempt: $0).get()
    }
    for index in delays.indices.dropFirst() {
      XCTAssertGreaterThanOrEqual(
        delays[index],
        delays[index - 1],
        "退避不得随重试次数变小"
      )
    }
    for delay in delays.dropFirst(4) {
      XCTAssertEqual(
        delay,
        60,
        "可发现性是期望状态：退避收敛到上限后必须继续重试，而不是放弃"
      )
      XCTAssertGreaterThan(delay, 0, "间隔为 0 会退化成忙等")
    }
  }

  func testListeningRecoveryDelayRejectsInvalidAttempt() {
    XCTAssertEqual(
      P2PConnectionManager.listeningRecoveryDelay(forAttempt: 0),
      .failure(.invalidAttempt(0))
    )
  }

  func testPendingLocalNetworkAuthorizationIsSurfacedAsUserActionable() {
    XCTAssertTrue(
      DeviceDiscoveryManager.isPendingLocalNetworkAuthorization(
        DeviceDiscoveryManager.AdvertisingStartupError
          .localNetworkAuthorizationPending(seconds: 45)
      )
    )
    XCTAssertTrue(
      DeviceDiscoveryManager.isPendingLocalNetworkAuthorization(
        NWError.dns(DeviceDiscoveryManager.bonjourNoAuthDNSCode)
      )
    )
    XCTAssertTrue(
      DeviceDiscoveryManager.isPendingLocalNetworkAuthorization(
        NWError.dns(DeviceDiscoveryManager.bonjourPolicyDeniedDNSCode)
      )
    )
    XCTAssertFalse(
      DeviceDiscoveryManager.isPendingLocalNetworkAuthorization(
        DeviceDiscoveryManager.AdvertisingStartupError.timedOut(seconds: 8)
      ),
      "普通挂死不得被误报成权限问题，否则会把用户引向错误的系统设置页"
    )
    XCTAssertFalse(
      DeviceDiscoveryManager.isPendingLocalNetworkAuthorization(NWError.posix(.EADDRINUSE))
    )
  }

  func testAdvertisingLifecycleOnlyFlagsAuthorizationAsUserAction() {
    typealias State = P2PConnectionManager.AdvertisingLifecycleState

    XCTAssertTrue(
      State.awaitingLocalNetworkAuthorization(nextRetryInSeconds: 45).requiresUserAction
    )
    XCTAssertFalse(State.idle.requiresUserAction)
    XCTAssertFalse(State.starting.requiresUserAction)
    XCTAssertFalse(State.advertising(port: 9527).requiresUserAction)
    XCTAssertFalse(State.retrying(attempt: 2, nextRetryInSeconds: 8).requiresUserAction)
    XCTAssertFalse(State.blockedByStartupFailure(reason: "no authority").requiresUserAction)
  }

  func testOnlyAdvertisingStateCountsAsNotSilent() {
    typealias State = P2PConnectionManager.AdvertisingLifecycleState

    XCTAssertFalse(State.advertising(port: 9527).isSilent)
    for state: State in [
      .idle,
      .starting,
      .awaitingLocalNetworkAuthorization(nextRetryInSeconds: 45),
      .retrying(attempt: 1, nextRetryInSeconds: 3),
      .blockedByStartupFailure(reason: "no authority")
    ] {
      XCTAssertTrue(
        state.isSilent,
        "只有真正处于 advertising 才算「对端可见」，其余状态都必须算静默"
      )
    }
  }

  func testStartupBlockedStateIsDistinctFromIdle() {
    typealias State = P2PConnectionManager.AdvertisingLifecycleState

    XCTAssertNotEqual(
      State.blockedByStartupFailure(reason: "no authority"),
      State.idle,
      """
      「未启用」与「已启用但被拒绝」必须可区分：两者合并成 idle 正是身份恢复失败后\
      界面完全静默、只有一行日志的成因
      """
    )
  }

  /// 身份 authority 恢复失败时，广播必须停用（TXT 里的身份会被对端 pin），
  /// 但浏览不需要任何本机身份，不应被一并关掉。
  func testAuthorityRecoveryFailureStopsAdvertisingButNotBrowsing() throws {
    let appSource = try readRepositorySource(
      at: iOSSourceURL("Sources/App/SkyBridgeCompassApp.swift")
    )
    let managerSource = try readRepositorySource(
      at: iOSSourceURL("Sources/Managers/P2PConnectionManager.swift")
    )

    let initializeServices = try XCTUnwrap(
      appSource.range(of: "private func initializeServices() async")
    )
    let discovery = try XCTUnwrap(
      appSource.range(
        of: "applyDiscoverySettings()",
        range: initializeServices.upperBound..<appSource.endIndex
      )
    )
    let requestListening = try XCTUnwrap(
      appSource.range(
        of: "try await connectionManager.startListening()",
        range: discovery.upperBound..<appSource.endIndex
      )
    )

    XCTAssertLessThan(
      discovery.lowerBound,
      requestListening.lowerBound,
      "浏览必须先独立启动，随后才请求受 authority 门控的广播监听"
    )
    let appStartupPrefix = String(
      appSource[initializeServices.lowerBound..<requestListening.lowerBound]
    )
    XCTAssertFalse(
      appStartupPrefix.contains("IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()"),
      "App 层不得在浏览启动前执行 authority 门控，否则恢复失败会同时关闭发现与广播"
    )

    let startListening = try XCTUnwrap(
      managerSource.range(of: "public func startListening() async throws")
    )
    let transactionDeclaration = try XCTUnwrap(
      managerSource.range(
        of: "private func performStartListeningTransaction() async throws",
        range: startListening.upperBound..<managerSource.endIndex
      )
    )
    let startListeningBody = String(
      managerSource[startListening.lowerBound..<transactionDeclaration.lowerBound]
    )
    let beginSupervision = try XCTUnwrap(
      startListeningBody.range(of: "beginListeningSupervision()")
    )
    let performTransaction = try XCTUnwrap(
      startListeningBody.range(of: "try await self.performStartListeningTransaction()")
    )
    XCTAssertLessThan(
      beginSupervision.lowerBound,
      performTransaction.lowerBound,
      "必须先登记 desired state/监督器，再执行可能失败的 authority 事务"
    )
    XCTAssertTrue(startListeningBody.contains("self.discoveryManager.stopAdvertising()"))
    XCTAssertTrue(startListeningBody.contains("self.isListening = false"))
    XCTAssertTrue(
      startListeningBody.contains("self.scheduleListeningRecovery(after: error)"),
      "authority 失败必须保持可观测且由 desired-state supervisor 分类恢复"
    )

    let transactionEnd = try XCTUnwrap(
      managerSource.range(
        of: "func refreshAdvertisingAuthorityIfActive",
        range: transactionDeclaration.upperBound..<managerSource.endIndex
      )
    )
    let transactionBody = String(
      managerSource[transactionDeclaration.lowerBound..<transactionEnd.lowerBound]
    )
    let authorityGate = try XCTUnwrap(
      transactionBody.range(
        of: "IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()"
      )
    )
    let advertise = try XCTUnwrap(
      transactionBody.range(of: "self.discoveryManager.startAdvertising(")
    )
    XCTAssertLessThan(
      authorityGate.lowerBound,
      advertise.lowerBound,
      "广播必须在读取并稳定 authority 之后才能发布可被对端 pin 的 TXT 身份"
    )
  }

  func testDeniedLocalNetworkAccessIsPublishedForTheBrowseSideToo() throws {
    let source = try readRepositorySource(
      at: iOSSourceURL("Sources/Managers/DeviceDiscoveryManager.swift")
    )

    XCTAssertTrue(
      source.contains("@Published public private(set) var isBrowseAuthorizationBlocked"),
      "权限被拒会同时打断两个方向，浏览侧的阻塞必须可被 UI 观测"
    )
    XCTAssertTrue(
      source.contains("isBrowseAuthorizationBlocked = true"),
      "命中 -65555 授权错误时必须置位"
    )
    XCTAssertTrue(
      source.contains("isBrowseAuthorizationBlocked = !authorizationBlockedServiceTypes.isEmpty"),
      "浏览器就绪后必须按剩余阻塞集合复位，避免告警粘住"
    )
  }

  func testAdvertisingIsSupervisedByDesiredStateNotASingleStartup() throws {
    let source = try readRepositorySource(
      at: iOSSourceURL("Sources/Managers/P2PConnectionManager.swift")
    )

    XCTAssertTrue(
      source.contains("private var desiredListening: Bool = false"),
      "广播必须建模为期望状态，而不是一次性事务"
    )
    XCTAssertTrue(
      source.contains("beginListeningSupervision()"),
      "启动必须登记期望状态并安装监督触发源"
    )
    XCTAssertTrue(
      source.contains("discoveryManager.$isAdvertising"),
      "监督器必须能感知已就绪的监听器意外消失"
    )
    XCTAssertTrue(
      source.contains("NWPathMonitor()") && source.contains("handleListeningPathUpdate"),
      "网络路径恢复必须能立即触发重建，而不是等下一次退避"
    )
    XCTAssertTrue(
      source.contains("supervisorNudgeMinimumInterval"),
      "立即重试触发源必须有抖动抑制，否则网络抖动会不断重置退避"
    )
    let healthStart = try XCTUnwrap(
      source.range(of: "private func handleAdvertisingHealthChange(")
    )
    let pathStart = try XCTUnwrap(
      source.range(
        of: "private func handleListeningPathUpdate(",
        range: healthStart.upperBound..<source.endIndex
      )
    )
    let healthBody = String(source[healthStart.lowerBound..<pathStart.lowerBound])
    XCTAssertTrue(healthBody.contains("guard isListening,"))
    XCTAssertTrue(healthBody.contains("listeningStartupOperation == nil,"))
    XCTAssertTrue(healthBody.contains("!advertisingAuthorityRefreshInProgress"))
    XCTAssertTrue(healthBody.contains("nudgeListeningSupervisor("))
    XCTAssertFalse(
      healthBody.contains("scheduleListeningRecovery("),
      "健康度观察不得与启动失败恢复双重驱动退避"
    )

    let stopListening = try XCTUnwrap(source.range(of: "public func stopListening() {"))
    let stopBody = String(source[stopListening.lowerBound...].prefix(320))
    XCTAssertTrue(
      stopBody.contains("endListeningSupervision()"),
      "只有显式停止监听才允许清除期望状态并拆除监督"
    )
  }

  func testAdvertisingStartupHandlesWaitingStateAndExtendsAuthorizationDeadline() throws {
    let source = try readRepositorySource(
      at: iOSSourceURL("Sources/Managers/DeviceDiscoveryManager.swift")
    )

    XCTAssertTrue(
      source.contains("case .waiting(let waitError):"),
      "`.waiting` 不得再落入 `default: break`，否则首次启动的授权等待完全不可观测"
    )
    XCTAssertTrue(
      source.contains("advertisingAuthorizationDeadlineExtended"),
      "授权等待必须只延长一次启动窗口，避免反复 `.waiting` 无限推迟失败"
    )
    XCTAssertTrue(
      source.contains("advertisingAuthorizationWaitTimeoutSeconds: TimeInterval = 45"),
      "授权等待必须有一个明确的、用户可响应的窗口常量"
    )
    let waitingCase = try XCTUnwrap(source.range(of: "case .waiting(let waitError):"))
    let waitingEnd = try XCTUnwrap(
      source.range(of: "\n        default:", range: waitingCase.upperBound..<source.endIndex)
    )
    let waitingBody = String(source[waitingCase.upperBound..<waitingEnd.lowerBound])
    XCTAssertTrue(
      waitingBody.contains("scheduleAdvertisingStartupTimeout(")
        && waitingBody.contains("Self.advertisingAuthorizationWaitTimeoutSeconds"),
      "授权等待期间必须改用更长窗口重排超时，而不是沿用 8 秒挂死判定"
    )
    XCTAssertTrue(
      waitingBody.contains("advertisingStartupContinuation != nil"),
      "只有仍在启动窗口内才允许延长；已就绪的监听器不得被超时逻辑影响"
    )
    XCTAssertTrue(
      source.contains(".localNetworkAuthorizationPending(seconds: seconds)"),
      "超时错误必须区分“未获授权”与“真正挂死”"
    )
  }

  func testFailedListeningStartupSchedulesBoundedRecovery() throws {
    let source = try readRepositorySource(
      at: iOSSourceURL("Sources/Managers/P2PConnectionManager.swift")
    )

    XCTAssertTrue(source.contains("self.scheduleListeningRecovery(after: error)"))
    XCTAssertTrue(source.contains("self.cancelListeningRecovery()"))
    XCTAssertTrue(
      source.contains("DeviceDiscoveryManager.shouldRetryAdvertising(after: error)"),
      "恢复调度必须复用广播失败分类，不得自行重新判定"
    )
    XCTAssertTrue(
      source.contains("self.desiredListening,\n                  !self.isListening else {"),
      "恢复重试必须在期望状态已撤销或已就绪时自行退出"
    )

    let stopListening = try XCTUnwrap(source.range(of: "public func stopListening() {"))
    let stopBody = String(source[stopListening.lowerBound...].prefix(320))
    XCTAssertTrue(
      stopBody.contains("cancelListeningRecovery()"),
      "显式停止监听必须同时取消恢复调度"
    )
  }

  private func iOSSourceURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("SkyBridgeCompassiOS")
      .appendingPathComponent(relativePath)
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
      createdAt: Date().addingTimeInterval(-120),
      expiresAt: Date().addingTimeInterval(-60)
    )

    let expiredFailed = OfflineMessage(
      id: "expired-failed-\(UUID().uuidString)",
      targetDeviceId: "peer-b",
      messageType: .text,
      payload: Data("f".utf8),
      createdAt: Date().addingTimeInterval(-120),
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
  func testTrustedDeviceStoreTreatsDiscoveryIdAsTrustedAlias() throws {
    let store = TrustedDeviceStore.shared
    let original = store.trustedDevices
    try store.replaceTrustedDevicesForTesting([])
    defer {
      XCTAssertNoThrow(try store.replaceTrustedDevicesForTesting(original))
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
  func testTrustedDeviceStoreResolvesHostAliasBackToCanonicalTrustedID() throws {
    let store = TrustedDeviceStore.shared
    let original = store.trustedDevices
    try store.replaceTrustedDevicesForTesting([])
    defer {
      XCTAssertNoThrow(try store.replaceTrustedDevicesForTesting(original))
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
      host: NWEndpoint.Host("fe80::468:f5a1:462b:29d3%lo0"),
      port: NWEndpoint.Port(integerLiteral: 9527)
    )
    let bonjour = NWEndpoint.service(
      name: "Lza's MacBook Pro",
      type: DiscoveredDevice.remoteControlServiceType,
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
    XCTAssertTrue(remoteDesktopSource.contains("SkyBridgeDiagnosticTrace.appendStatus(routeLine)"))

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
    XCTAssertTrue(discoverySource.contains("txtValue(txtRecord, \"lanIPv4\")"))
    XCTAssertTrue(discoverySource.contains("txtValue(txtRecord, \"lanIPv6\", \"ipv6\")"))
    XCTAssertTrue(
      discoverySource.contains(
        "ConnectableAddressCanonicalizer.isRoutableLANAddress($0) ? $0 : nil"
      ))
    XCTAssertTrue(discoverySource.contains("ConnectableAddressCanonicalizer.bestLANAddress(["))
    XCTAssertTrue(discoverySource.contains("避免 Bonjour service 解析退回 link-local"))
  }

  func testIOSP2PAdvertisingOnlyBecomesVisibleAfterExactSocketAndRegistrationReady() throws {
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
    XCTAssertTrue(
      discoverySource.contains(
        "advertisingReadinessGate = BonjourRegistrationReadinessGate()"
      )
    )
    XCTAssertTrue(discoverySource.contains("activeListener.serviceRegistrationUpdateHandler ="))

    let listenerStateStart = try XCTUnwrap(
      discoverySource.range(of: "private func handleListenerStateChange(")
    )
    let registrationStart = try XCTUnwrap(
      discoverySource.range(
        of: "private func handleServiceRegistrationChange(",
        range: listenerStateStart.upperBound..<discoverySource.endIndex
      )
    )
    let completionStart = try XCTUnwrap(
      discoverySource.range(
        of: "private func completeAdvertisingReadiness(",
        range: registrationStart.upperBound..<discoverySource.endIndex
      )
    )
    let incomingStart = try XCTUnwrap(
      discoverySource.range(
        of: "private func handleNewIncomingConnection(",
        range: completionStart.upperBound..<discoverySource.endIndex
      )
    )
    let listenerStateBody = String(
      discoverySource[listenerStateStart.lowerBound..<registrationStart.lowerBound]
    )
    let registrationBody = String(
      discoverySource[registrationStart.lowerBound..<completionStart.lowerBound]
    )
    let completionBody = String(
      discoverySource[completionStart.lowerBound..<incomingStart.lowerBound]
    )

    XCTAssertTrue(listenerStateBody.contains("let observation = gate.observeSocketReady()"))
    XCTAssertTrue(listenerStateBody.contains("completeAdvertisingReadiness("))
    XCTAssertFalse(listenerStateBody.contains("isAdvertising = true"))
    XCTAssertTrue(registrationBody.contains("gate.observeRegistrationAdded("))
    XCTAssertTrue(registrationBody.contains("gate.observeRegistrationRemoved("))
    XCTAssertTrue(registrationBody.contains("completeAdvertisingReadiness("))
    XCTAssertFalse(registrationBody.contains("isAdvertising = true"))
    XCTAssertTrue(completionBody.contains("listener === activeListener"))
    XCTAssertTrue(completionBody.contains("listenerGeneration == generation"))
    XCTAssertTrue(completionBody.contains("let port = activeListener.port?.rawValue"))
    XCTAssertTrue(completionBody.contains("port > 0"))
    XCTAssertTrue(completionBody.contains("advertisingActualPort = port"))
    XCTAssertTrue(completionBody.contains("isAdvertising = true"))
    XCTAssertTrue(completionBody.contains("finishAdvertisingStartup(.success(()))"))
    XCTAssertTrue(completionBody.contains("registration=confirmed"))
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
    XCTAssertTrue(
      p2pManagerSource.contains(
        "let beforeStart = self.discoveryManager.advertisingReadinessSnapshot"
      ))
    XCTAssertTrue(p2pManagerSource.contains("IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()"))
    XCTAssertTrue(p2pManagerSource.contains("P2PAdvertisingAuthorityStabilizer.applyLatest("))
    XCTAssertTrue(p2pManagerSource.contains("authority: authority"))
    XCTAssertTrue(
      p2pManagerSource.contains(
        "readiness.isReady(for: controlPort, authority: latestAuthority)"
      ))
    XCTAssertTrue(p2pManagerSource.contains("let readiness = discoveryManager.advertisingReadinessSnapshot"))
    XCTAssertTrue(p2pManagerSource.contains("refreshAdvertisingAuthorityIfActive"))
    XCTAssertTrue(p2pManagerSource.contains("try await self.discoveryManager.startAdvertising("))
    XCTAssertTrue(p2pManagerSource.contains("P2P 监听状态与 Bonjour 广播状态不一致"))
    XCTAssertTrue(appSource.contains("try await connectionManager.startListening()"))
    XCTAssertTrue(appSource.contains("前台恢复 P2P 监听器失败"))
    XCTAssertFalse(
      appSource.contains("try? await connectionManager.startListening()"),
      "Foreground recovery must log listener startup failures instead of swallowing them."
    )
  }

  @MainActor
  func testIOSBonjourTXTUsesTheExplicitCommittedMLDSA87Authority() async throws {
    let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
    let publicKey = Data(repeating: 0x87, count: 2_592)
    let authority = ProtocolIdentitySnapshot(
      deviceId: "device-authority-87",
      signingAlgorithm: .mlDSA87,
      signingPublicKey: publicKey,
      signingPublicKeyFingerprint: CurrentPathSecurityCompat.computeFingerprint(
        algorithm: .mlDSA87,
        publicKeyBytes: publicKey
      )
    )

    let record = try manager.debugCreateAdvertisingTXTRecord(authority: authority)
    let dictionary = try XCTUnwrap(record.dictionary)
    XCTAssertEqual(dictionary["deviceId"], authority.deviceId)
    XCTAssertEqual(dictionary["version"], "2")
    XCTAssertEqual(dictionary["pubKeyFP"], authority.signingPublicKeyFingerprint)
    XCTAssertEqual(dictionary["hs_soa"], "1")
    XCTAssertNil(dictionary["protocolSigningAlgorithm"])
    XCTAssertNil(dictionary["identityFingerprint"])
    XCTAssertNil(dictionary["controlPort"])
  }

  @MainActor
  func testIOSBonjourTXTRejectsMismatchedAuthorityFingerprint() async throws {
    let manager = DeviceDiscoveryManager.debugMakeIsolatedInstance()
    let authority = ProtocolIdentitySnapshot(
      deviceId: "device-authority-87",
      signingAlgorithm: .mlDSA87,
      signingPublicKey: Data(repeating: 0x87, count: 2_592),
      signingPublicKeyFingerprint: String(repeating: "0", count: 64)
    )

    do {
      _ = try manager.debugCreateAdvertisingTXTRecord(authority: authority)
      XCTFail("A mismatched authority fingerprint must fail before Bonjour publication")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains(
          "fingerprint does not match its algorithm-tagged public key"
        )
      )
    }
  }

  func testIOSAdvertisingReadinessIncludesExactAuthority() {
    let publicKey = Data(repeating: 0x87, count: 2_592)
    let authority = ProtocolIdentitySnapshot(
      deviceId: "device-authority-87",
      signingAlgorithm: .mlDSA87,
      signingPublicKey: publicKey,
      signingPublicKeyFingerprint: CurrentPathSecurityCompat.computeFingerprint(
        algorithm: .mlDSA87,
        publicKeyBytes: publicKey
      )
    )
    func makeReadiness(
      requestedPort: UInt16 = 9_527,
      actualPort: UInt16 = 9_527,
      serviceType: String = DiscoveryServiceType.skybridge.rawValue,
      readyGeneration: UInt64 = 1
    ) -> DeviceDiscoveryManager.AdvertisingReadinessSnapshot {
      DeviceDiscoveryManager.AdvertisingReadinessSnapshot(
        isAdvertising: true,
        listenerPresent: true,
        handlerInstalled: true,
        requestedPort: requestedPort,
        actualPort: actualPort,
        serviceType: serviceType,
        readyGeneration: readyGeneration,
        authorityDeviceID: authority.deviceId,
        authorityAlgorithm: authority.signingAlgorithm,
        authorityFingerprint: authority.signingPublicKeyFingerprint
      )
    }
    let readiness = makeReadiness()
    let replacement = ProtocolIdentitySnapshot(
      deviceId: authority.deviceId,
      signingAlgorithm: .mlDSA65,
      signingPublicKey: Data(repeating: 0x65, count: 1_952),
      signingPublicKeyFingerprint: String(repeating: "c", count: 64)
    )

    XCTAssertTrue(readiness.isReady(for: 9_527, authority: authority))
    XCTAssertFalse(readiness.isReady(for: 9_527, authority: replacement))
    XCTAssertFalse(
      makeReadiness(serviceType: DiscoveryServiceType.skybridgeRemote.rawValue)
        .isReady(for: 9_527, authority: authority)
    )
    XCTAssertFalse(
      makeReadiness(readyGeneration: 0)
        .isReady(for: 9_527, authority: authority)
    )
    XCTAssertFalse(
      makeReadiness(requestedPort: 0)
        .isReady(for: 9_527, authority: authority)
    )
    XCTAssertTrue(
      makeReadiness(requestedPort: 0, actualPort: 49_152)
        .isReady(for: 0, authority: authority)
    )
  }

  @MainActor
  func testP2PAdvertisingStartupConvergesToAuthorityCommittedDuringAsyncApply() async throws {
    func authority(fill: UInt8) -> ProtocolIdentitySnapshot {
      let publicKey = Data(repeating: fill, count: 2_592)
      return ProtocolIdentitySnapshot(
        deviceId: "device-authority-87",
        signingAlgorithm: .mlDSA87,
        signingPublicKey: publicKey,
        signingPublicKeyFingerprint: CurrentPathSecurityCompat.computeFingerprint(
          algorithm: .mlDSA87,
          publicKeyBytes: publicKey
        )
      )
    }

    let authorityA = authority(fill: 0xA1)
    let authorityB = authority(fill: 0xB2)
    var committedLoads = [authorityA, authorityB, authorityB, authorityB]
    var appliedAuthorities: [ProtocolIdentitySnapshot] = []

    let stabilized = try await P2PAdvertisingAuthorityStabilizer.applyLatest(
      loadCommittedAuthority: {
        XCTAssertFalse(committedLoads.isEmpty)
        return committedLoads.removeFirst()
      },
      applyAuthority: { authority in
        appliedAuthorities.append(authority)
        await Task.yield()
      }
    )

    XCTAssertEqual(stabilized, authorityB)
    XCTAssertEqual(appliedAuthorities, [authorityA, authorityB])
    XCTAssertTrue(committedLoads.isEmpty)
  }

  @MainActor
  func testP2PAdvertisingStartupRejectsInvalidAttemptBudget() async {
    do {
      _ = try await P2PAdvertisingAuthorityStabilizer.applyLatest(
        maximumAttempts: 0,
        loadCommittedAuthority: {
          XCTFail("Invalid attempt budget must fail before loading identity")
          throw CancellationError()
        },
        applyAuthority: { _ in
          XCTFail("Invalid attempt budget must fail before applying identity")
        }
      )
      XCTFail("Expected invalid maximum-attempt error")
    } catch let error as P2PAdvertisingAuthorityStabilizationError {
      XCTAssertEqual(error, .invalidMaximumAttempts(0))
    } catch {
      XCTFail("Unexpected attempt-budget error: \(error)")
    }
  }

  func testSupersededBonjourAuthorityUpdateCannotStopTheNewListener() {
    XCTAssertFalse(
      DeviceDiscoveryManager.shouldFailClosedAfterAuthorityUpdateFailure(
        failedGeneration: 7,
        currentGeneration: 8,
        listenerStillMatches: true
      )
    )
    XCTAssertTrue(
      DeviceDiscoveryManager.shouldFailClosedAfterAuthorityUpdateFailure(
        failedGeneration: 8,
        currentGeneration: 8,
        listenerStillMatches: true
      )
    )
    XCTAssertFalse(
      DeviceDiscoveryManager.shouldFailClosedAfterAuthorityUpdateFailure(
        failedGeneration: 8,
        currentGeneration: 8,
        listenerStillMatches: false
      )
    )
  }

  func testIOSBonjourAuthorityRotationOwnsAnExactListenerGeneration() throws {
    let discovery = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
    )
    let manager = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
    )
    let app = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift"
    )
    let runtime = try iosFileTransferRuntimeSource()

    XCTAssertFalse(app.contains("refreshAdvertisingCapabilities"))

    let startup = try sourceSlice(
      from: "func startAdvertising(\n",
      to: "private func performStartAdvertising(",
      in: discovery
    )
    XCTAssertTrue(startup.contains("existingTask.cancel()"))
    XCTAssertTrue(startup.contains("stopAdvertising()"))
    XCTAssertTrue(startup.contains("try Task.checkCancellation()"))
    XCTAssertFalse(startup.contains("try await existingTask.value\n            stopAdvertising()"))

    let rotation = try sourceSlice(
      from: "func updateAdvertisingAuthority(",
      to: "public func stopAdvertising()",
      in: discovery
    )
    XCTAssertTrue(rotation.contains("let replacedListenerGeneration = listenerGeneration"))
    XCTAssertTrue(rotation.contains("listenerGeneration &+= 1"))
    XCTAssertTrue(rotation.contains("Self.cancelListener(activeListener)"))
    XCTAssertTrue(rotation.contains("try await performStartAdvertising("))
    XCTAssertTrue(rotation.contains("advertisingReadinessSnapshot.isReady("))

    XCTAssertTrue(manager.contains("private var advertisingAuthorityRefreshInProgress = false"))
    XCTAssertTrue(manager.contains("advertisingAuthorityRefreshInProgress = true"))
    XCTAssertTrue(manager.contains("!advertisingAuthorityRefreshInProgress else { return }"))

    let stop = try sourceSlice(
      from: "public func stop() async",
      to: "\n}",
      in: runtime
    )
    let listenerStop = try XCTUnwrap(stop.range(of: "await networkService.stopListening()"))
    let wrapperAwait = try XCTUnwrap(stop.range(of: "_ = try? await inFlightStart.value"))
    XCTAssertLessThan(listenerStop.lowerBound, wrapperAwait.lowerBound)
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

  func testIOSPrimaryBonjourTXTContainsOnlyCanonicalVersion2IdentityFields() throws {
    let fields = try DeviceDiscoveryManager.primaryBonjourInteropAdvertisementFields(
      validatedDeviceId: "id:canonical-ios-device",
      protocolIdentityFingerprint: String(repeating: "a", count: 64),
      platform: .iOS
    )

    XCTAssertEqual(
      Set(fields.keys),
      Set(["version", "deviceId", "pubKeyFP", "platform", "hs_soa"])
    )
    XCTAssertEqual(fields["version"], "2")
    XCTAssertEqual(fields["hs_soa"], "1")
    XCTAssertNil(fields["port"])
    XCTAssertNil(fields["controlPort"])
    XCTAssertNil(fields["capabilities"])
  }

  func testIOSBonjourServiceTypesCarryCapabilitiesWithoutMutableTXTClaims() throws {
    let fileTransferSource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
    )
    let discoverySource = try repositoryScriptSource(
      "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
    )
    let compactDiscoverySource = discoverySource.filter { !$0.isWhitespace }

    XCTAssertTrue(
      fileTransferSource.contains("BonjourInteropProtocolContract.canonicalAdvertisementFields(")
    )
    XCTAssertTrue(fileTransferSource.contains("role: .dedicatedService"))
    XCTAssertFalse(fileTransferSource.contains("\"capabilities\": Data("))
    XCTAssertFalse(fileTransferSource.contains("\"transferPort\": Data("))
    XCTAssertFalse(
      fileTransferSource.contains("ClassicTransferCapability.classicResume"),
      "iOS must not advertise classic resume until its inbound protocol implements resume semantics."
    )
    XCTAssertTrue(compactDiscoverySource.contains("return[\"file\",\"file_transfer\"]"))
    XCTAssertTrue(
      compactDiscoverySource.contains("return[\"screen_sharing\",\"remote_desktop\",\"rdview\",\"remote_control\",\"rdcontrol\"]"),
      "Remote Bonjour service inference must keep Android-compatible screen/control aliases."
    )
    XCTAssertTrue(
      compactDiscoverySource.contains("caps.formUnion([\"file\",\"file_transfer\"])")
    )
    XCTAssertTrue(
      compactDiscoverySource.contains("caps.formUnion([\"screen_sharing\",\"remote_desktop\",\"rdview\",\"remote_control\",\"rdcontrol\"])")
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
  func testViewerStreamConfigurationRespectsAudioRedirectionPreference() async throws {
    try await SkyBridgeiOSCore.shared.initialize(policy: .classicOnly)
    let manager = RemoteDesktopManager.instance
    let originalSettings = manager.viewerSettings
    defer { manager.viewerSettings = originalSettings }

    var disabledSettings = originalSettings
    disabledSettings.audioRedirectionEnabled = false
    manager.viewerSettings = disabledSettings

    XCTAssertEqual(try manager.makeViewerStreamConfigurationPayload().audioRedirectionEnabled, false)

    var enabledSettings = originalSettings
    enabledSettings.audioRedirectionEnabled = true
    manager.viewerSettings = enabledSettings

    // 自“媒体就绪门控”改动起，audioRedirectionEnabled 是有效值而非偏好值：
    // 偏好开启但无可用媒体音频端点/原生音频时，payload 仍然必须广告为关闭。
    // 端点就绪时广告为开启的路径由 RemoteDesktopViewerStreamConfigurationFactoryTests
    // .testCrossNetworkAudioEndpointProducesPQCRealtimeAudioPayload 锁定。
    XCTAssertEqual(try manager.makeViewerStreamConfigurationPayload().audioRedirectionEnabled, false)
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
  func testViewerStreamConfigurationKeepsAudioOnStableFallbackPath() async throws {
    try await SkyBridgeiOSCore.shared.initialize(policy: .classicOnly)
    // 无媒体音频绑定时（测试环境默认态），音频字段必须显式广告为关闭，
    // 不得提前广告 pqc-media-v1 或采样率（媒体就绪门控语义；端点就绪路径由
    // RemoteDesktopViewerStreamConfigurationFactoryTests 锁定）。
    let payload = try RemoteDesktopManager.instance.makeViewerStreamConfigurationPayload()

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
      from: "private func submitPixelBufferDecode(",
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
      from: "private func submitVideoFrame(",
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
      resetBody.contains("clearVideoParameterSets(requiresCompleteSyncSet: true)"),
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
      from: "private func acceptScreenFrameIfSessionActive",
      to: "private func handleIncomingStreamTopologyChangeIfNeeded(",
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
      from: "private func handleIncomingStreamTopologyChangeIfNeeded(",
      to: "private func acceptFrameSequenceForDecode(",
      in: remoteDesktopSource
    )

    XCTAssertTrue(
      topologyBody.contains(
        "let incomingFrameHasDecoderBootstrap = classifiedFrame.traits.isDecoderBootstrapFrame"))
    XCTAssertTrue(
      topologyBody.contains(
        "let lightweightFlapTransition = isFallbackProducerFlap && incomingFrameHasDecoderBootstrap"))
    XCTAssertTrue(
      topologyBody.contains(
        "decodeQueueWaitingForSyncFrame = classifiedFrame.traits.isPredictiveVideo"))
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
      to: "private func enqueueFrameForDecode(",
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
  func testTrustResolvedPeerPersistsDeclaredDeviceIdForFutureBootstrap() throws {
    let store = TrustedDeviceStore.shared
    let original = store.trustedDevices
    try store.replaceTrustedDevicesForTesting([])
    defer {
      XCTAssertNoThrow(try store.replaceTrustedDevicesForTesting(original))
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

    try store.trustResolvedPeer(runtimeAliasDevice, declaredDeviceId: declaredDeviceId)

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
  func testCodablePersistenceStoreProtectionFailureCannotReplaceCommittedPrimary() throws {
    let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
    let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
    let relativePath = "Tests/atomic-protection.json"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Expected isolated UserDefaults suite")
      return
    }

    let fileManager = PreparedFileProtectionFailingFileManager()
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
    let rootURL = applicationSupport
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent(rootDirectoryName, isDirectory: true)
    let primaryURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
    defer {
      if fileManager.fileExists(atPath: rootURL.path) {
        XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
      }
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = CodablePersistenceStore<[String]>(
      location: .protectedApplicationSupport(path: relativePath),
      rootDirectoryName: rootDirectoryName,
      defaults: defaults,
      fileManager: fileManager
    )
    let committed = ["committed"]
    try store.save(committed)
    let committedBytes = try Data(contentsOf: primaryURL)

    fileManager.rejectsPreparedFileProtection = true
    XCTAssertThrowsError(try store.save(["must-not-commit"])) { error in
      XCTAssertTrue(error is PreparedFileProtectionTestError)
    }
    fileManager.rejectsPreparedFileProtection = false

    XCTAssertEqual(try Data(contentsOf: primaryURL), committedBytes)
    XCTAssertEqual(try store.loadOrThrow(), committed)
    let siblingNames = try fileManager.contentsOfDirectory(
      atPath: primaryURL.deletingLastPathComponent().path
    )
    XCTAssertFalse(siblingNames.contains(where: { $0.contains(".prepared-") }))
  }

  @MainActor
  func testCodablePersistenceStoreReplacesExistingPrimaryWithProtectedFile() throws {
    let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
    let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
    let relativePath = "Tests/atomic-replacement.json"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Expected isolated UserDefaults suite")
      return
    }

    let fileManager = FileManager.default
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
    let rootURL = applicationSupport
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent(rootDirectoryName, isDirectory: true)
    let primaryURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
    defer {
      if fileManager.fileExists(atPath: rootURL.path) {
        XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
      }
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = CodablePersistenceStore<[String]>(
      location: .protectedApplicationSupport(path: relativePath),
      rootDirectoryName: rootDirectoryName,
      defaults: defaults,
      fileManager: fileManager
    )
    try store.save(["first"])
    try store.save(["second"])

    XCTAssertEqual(try store.loadOrThrow(), ["second"])
#if targetEnvironment(simulator)
    // Simulator host filesystems do not consistently surface NSFileProtectionKey.
#else
    let attributes = try fileManager.attributesOfItem(atPath: primaryURL.path)
    XCTAssertEqual(
      attributes[.protectionKey] as? FileProtectionType,
      .completeUntilFirstUserAuthentication
    )
#endif
  }

  @MainActor
  func testCodablePersistenceStoreQuarantineProtectionFailureKeepsPrimaryInPlace() throws {
    let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
    let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
    let relativePath = "Tests/quarantine-protection.json"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Expected isolated UserDefaults suite")
      return
    }

    let fileManager = PreparedFileProtectionFailingFileManager()
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
    let rootURL = applicationSupport
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent(rootDirectoryName, isDirectory: true)
    let primaryURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
    defer {
      if fileManager.fileExists(atPath: rootURL.path) {
        XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
      }
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = CodablePersistenceStore<[String]>(
      location: .protectedApplicationSupport(path: relativePath),
      rootDirectoryName: rootDirectoryName,
      defaults: defaults,
      fileManager: fileManager
    )
    let committed = ["corrupt-but-preserved"]
    try store.save(committed)
    let committedBytes = try Data(contentsOf: primaryURL)

    fileManager.rejectedProtectionLastPathComponent = primaryURL.lastPathComponent
    XCTAssertThrowsError(try store.quarantine()) { error in
      XCTAssertTrue(error is PreparedFileProtectionTestError)
    }
    fileManager.rejectedProtectionLastPathComponent = nil

    XCTAssertEqual(try Data(contentsOf: primaryURL), committedBytes)
    XCTAssertEqual(try store.loadOrThrow(), committed)
    let siblingNames = try fileManager.contentsOfDirectory(
      atPath: primaryURL.deletingLastPathComponent().path
    )
    XCTAssertFalse(siblingNames.contains(where: { $0.contains(".quarantine-") }))
  }

  @MainActor
  func testCodablePersistenceStoreDoesNotFallBackToLegacyWhenPrimaryIsCorrupt() throws {
    let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
    let legacyKey = "legacy.persistence.payload"
    let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
    let relativePath = "Tests/authority.json"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Expected isolated UserDefaults suite")
      return
    }

    let fileManager = FileManager.default
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
    let rootURL = applicationSupport
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent(rootDirectoryName, isDirectory: true)
    let primaryURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
    try fileManager.createDirectory(
      at: primaryURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not-json".utf8).write(to: primaryURL, options: .atomic)
    defaults.set(try JSONEncoder().encode(["stale-legacy-authority"]), forKey: legacyKey)
    defer {
      if fileManager.fileExists(atPath: rootURL.path) {
        XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
      }
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = CodablePersistenceStore<[String]>(
      location: .protectedApplicationSupport(
        path: relativePath,
        legacyUserDefaultsKey: legacyKey
      ),
      rootDirectoryName: rootDirectoryName,
      defaults: defaults,
      fileManager: fileManager
    )

    XCTAssertThrowsError(try store.loadOrThrow())
    XCTAssertNotNil(defaults.data(forKey: legacyKey))
    XCTAssertEqual(try Data(contentsOf: primaryURL), Data("not-json".utf8))
  }

  @MainActor
  func testCodablePersistenceStoreKeepsLegacyWhenMigrationSaveFails() throws {
    let suiteName = "RegressionHardeningTests.\(UUID().uuidString)"
    let legacyKey = "legacy.persistence.payload"
    let rootDirectoryName = "SkyBridgeStateTests-\(UUID().uuidString)"
    let relativePath = "Tests/authority.json"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Expected isolated UserDefaults suite")
      return
    }

    let fileManager = FileManager.default
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
    let rootURL = applicationSupport
      .appendingPathComponent(bundleIdentifier, isDirectory: true)
      .appendingPathComponent(rootDirectoryName, isDirectory: true)
    try fileManager.createDirectory(
      at: rootURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("blocks-directory-creation".utf8).write(to: rootURL, options: .atomic)
    let legacyValue = ["legacy-authority-must-survive"]
    let legacyData = try JSONEncoder().encode(legacyValue)
    defaults.set(legacyData, forKey: legacyKey)
    defer {
      if fileManager.fileExists(atPath: rootURL.path) {
        XCTAssertNoThrow(try fileManager.removeItem(at: rootURL))
      }
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = CodablePersistenceStore<[String]>(
      location: .protectedApplicationSupport(
        path: relativePath,
        legacyUserDefaultsKey: legacyKey
      ),
      rootDirectoryName: rootDirectoryName,
      defaults: defaults,
      fileManager: fileManager
    )

    XCTAssertThrowsError(try store.loadOrThrow())
    XCTAssertEqual(defaults.data(forKey: legacyKey), legacyData)
    XCTAssertEqual(try Data(contentsOf: rootURL), Data("blocks-directory-creation".utf8))
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
    manager.testInstallNegotiatedSuitePresentationCache(.mlkem768, for: runtimePeerId)

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
  func testDashboardViewModelRefreshesStatusWhenNegotiatedSuitePublishes() async throws {
    let manager = P2PConnectionManager.instance
    let viewModel = DashboardViewModel.shared
    let runtimePeerId = "host:192.168.1.57"
    let declaredDeviceId = UUID().uuidString.lowercased()
    let stablePeerId = "id:\(declaredDeviceId)"
    let connectedText = RuntimeLocalization.string("已连接")
    defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId) }

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

    try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: runtimePeerId)

    await Task.yield()
    XCTAssertEqual(manager.getNegotiatedSuite(for: stablePeerId), .x25519Ed25519)
    XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")

    manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
    XCTAssertNil(manager.negotiatedSuiteByDeviceId[stablePeerId])
  }

  @MainActor
  func testDashboardViewModelDoesNotClaimSuiteFromPresentationOnlyCache() async {
    let manager = P2PConnectionManager.instance
    let viewModel = DashboardViewModel.shared
    let runtimePeerId = "host:192.168.1.59"
    let declaredDeviceId = UUID().uuidString.lowercased()
    let stablePeerId = "id:\(declaredDeviceId)"
    let connectedText = RuntimeLocalization.string("已连接")
    defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId) }

    manager.installTestPeerRuntimeState(
      runtimePeerId: runtimePeerId,
      status: .connected,
      name: "Presentation Cache Peer",
      ipAddress: "192.168.1.59"
    )
    _ = manager.testPromotePeerPresentationIdentity(
      runtimePeerId: runtimePeerId,
      declaredDeviceId: declaredDeviceId,
      deviceName: "Presentation Cache Mac",
      modelName: "MacBook Pro",
      platform: "macOS",
      osVersion: "15.0"
    )
    manager.testInstallNegotiatedSuitePresentationCache(
      .x25519Ed25519,
      for: runtimePeerId
    )

    await Task.yield()
    XCTAssertNil(manager.getNegotiatedSuite(for: stablePeerId))
    XCTAssertEqual(viewModel.topConnectionPresentation.statusText, connectedText)
    XCTAssertFalse(viewModel.topConnectionPresentation.statusText.contains("Classic"))
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
    async throws
  {
    let manager = P2PConnectionManager.instance
    let viewModel = DashboardViewModel.shared
    let runtimePeerId = "host:192.168.1.58"
    let declaredDeviceId = UUID().uuidString.lowercased()
    let connectedText = RuntimeLocalization.string("已连接")
    defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId) }

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
    try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: runtimePeerId)

    await Task.yield()
    XCTAssertEqual(manager.getNegotiatedSuite(for: runtimePeerId), .x25519Ed25519)
    XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")

    manager.testClearActiveConnectionsPreservingState()

    await Task.yield()
    XCTAssertEqual(viewModel.topConnectionPresentation.phase, .connected)
    XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")
    XCTAssertNotEqual(
      viewModel.topConnectionPresentation.statusText, RuntimeLocalization.string("在线"))

  }

  @MainActor
  func testDashboardViewModelDoesNotPretendTargetSuiteIsConnectedDuringRekey() async throws {
    let manager = P2PConnectionManager.instance
    let viewModel = DashboardViewModel.shared
    let runtimePeerId = "host:192.168.1.63"
    let declaredDeviceId = UUID().uuidString.lowercased()
    let connectedText = RuntimeLocalization.string("已连接")
    let rekeyingText = RuntimeLocalization.string("Rekey 中")
    defer { manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId) }

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
    try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: runtimePeerId)
    manager.testInstallRekeyStatus(
      fromSuite: "Classic",
      toSuite: "X-Wing",
      for: runtimePeerId
    )

    await Task.yield()

    XCTAssertEqual(viewModel.topConnectionPresentation.statusText, "Classic \(connectedText)")
    XCTAssertEqual(viewModel.topConnectionPresentation.detailText, "Classic → X-Wing · \(rekeyingText)")
    XCTAssertFalse(viewModel.topConnectionPresentation.statusText.contains("X-Wing"))

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
  func testResolvedConnectionStatusPrefersLiveConnectionOverStaleAliasFailure() throws {
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

    XCTAssertEqual(manager.resolvedConnectionStatus(for: device), .failed)
    XCTAssertEqual(manager.resolvedConnectionError(for: device), "stale failure")

    try manager.testInstallAuthenticatedSession(.x25519Ed25519, for: runtimePeerId)
    defer {
      manager.testSimulateTerminalCleanup(runtimePeerId: runtimePeerId)
    }

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

  func testHandshakeControlPlaneWireDecodersAcceptNonZeroStartIndexSlices() throws {
    func offsetSlice(_ payload: Data, prefixCount: Int = 17) -> Data {
      var storage = Data(repeating: 0xEE, count: prefixCount)
      storage.append(payload)
      let slice = storage.dropFirst(prefixCount)
      XCTAssertNotEqual(slice.startIndex, 0)
      return slice
    }

    let capabilities = CryptoCapabilities(
      supportedKEM: ["X25519"],
      supportedSignature: ["Ed25519"],
      supportedAuthProfiles: ["Classic"],
      supportedAEAD: ["AES-256-GCM"],
      pqcAvailable: false,
      platformVersion: "iOS 17.0",
      providerType: .classic
    )
    let messageA = HandshakeMessageA(
      supportedSuites: [.x25519Ed25519],
      keyShares: [
        HandshakeKeyShare(
          suite: .x25519Ed25519,
          shareBytes: Data(repeating: 0x11, count: 32)
        )
      ],
      clientNonce: Data(repeating: 0x22, count: HandshakeConstants.nonceSize),
      policy: .default,
      capabilities: capabilities,
      signature: Data(repeating: 0x33, count: 64),
      identityPublicKey: Data(repeating: 0x44, count: 32)
    )
    let decodedA = try HandshakeMessageA.decode(from: offsetSlice(messageA.encoded))
    XCTAssertEqual(decodedA.supportedSuites, messageA.supportedSuites)
    XCTAssertEqual(decodedA.capabilities.supportedKEM, capabilities.supportedKEM)
    XCTAssertEqual(decodedA.capabilities.providerType, capabilities.providerType)

    let messageB = makeMinimalMessageB()
    let decodedB = try HandshakeMessageB.decode(from: offsetSlice(messageB.encoded))
    XCTAssertEqual(decodedB.selectedSuite, messageB.selectedSuite)
    XCTAssertEqual(decodedB.encryptedPayload.ciphertext, messageB.encryptedPayload.ciphertext)

    let finished = HandshakeFinished(
      direction: .responderToInitiator,
      mac: Data(repeating: 0x55, count: 32)
    )
    XCTAssertEqual(try HandshakeFinished.decode(from: offsetSlice(finished.encoded)).mac, finished.mac)

    let identity = IdentityPublicKeys(
      protocolPublicKey: Data(repeating: 0x66, count: 32),
      protocolAlgorithm: .ed25519,
      secureEnclavePublicKey: Data(repeating: 0x67, count: 65)
    )
    let decodedIdentity = try IdentityPublicKeys.decode(from: offsetSlice(identity.encoded))
    XCTAssertEqual(decodedIdentity.protocolPublicKey, identity.protocolPublicKey)
    XCTAssertEqual(decodedIdentity.secureEnclavePublicKey, identity.secureEnclavePublicKey)

    let soa = try HandshakeSOAExtension(
      initiatorPeerId: Data(repeating: 0x71, count: HandshakeSOAExtension.initiatorPeerIdLength),
      targetPeerId: Data(repeating: 0x72, count: HandshakeSOAExtension.targetPeerIdLength),
      attemptId: Data(repeating: 0x73, count: HandshakeSOAExtension.attemptIdLength)
    )
    let decodedSOA = try HandshakeSOAExtension.decodeValue(offsetSlice(soa.encodedValue))
    XCTAssertEqual(decodedSOA.initiatorPeerId, soa.initiatorPeerId)
    XCTAssertEqual(decodedSOA.targetPeerId, soa.targetPeerId)
    XCTAssertEqual(decodedSOA.attemptId, soa.attemptId)

    let sealedBoxWire = messageB.encryptedPayload.combinedWithHeader(suite: messageB.selectedSuite)
    let decodedBox = try HPKESealedBox(combined: offsetSlice(sealedBoxWire), isHandshake: true)
    XCTAssertEqual(decodedBox.encapsulatedKey, messageB.encryptedPayload.encapsulatedKey)
    XCTAssertEqual(decodedBox.nonce, messageB.encryptedPayload.nonce)
    XCTAssertEqual(decodedBox.ciphertext, messageB.encryptedPayload.ciphertext)
    XCTAssertEqual(decodedBox.tag, messageB.encryptedPayload.tag)
    XCTAssertEqual(decodedBox.encapsulatedKey.startIndex, 0)
    XCTAssertEqual(decodedBox.nonce.startIndex, 0)
    XCTAssertEqual(decodedBox.ciphertext.startIndex, 0)
    XCTAssertEqual(decodedBox.tag.startIndex, 0)

    var padded = Data([0x53, 0x42, 0x50, 0x31])
    var messageLength = UInt32(messageA.encoded.count).bigEndian
    padded.append(Data(bytes: &messageLength, count: 4))
    padded.append(messageA.encoded)
    padded.append(Data(repeating: 0xA5, count: 24))
    XCTAssertEqual(
      try HandshakeMessageA.decode(from: offsetSlice(padded)).supportedSuites,
      messageA.supportedSuites
    )

    let truncated = offsetSlice(Data(messageA.encoded.dropLast()))
    XCTAssertThrowsError(try HandshakeMessageA.decode(from: truncated)) { error in
      guard case HandshakeError.failed = error else {
        XCTFail("Expected HandshakeError.failed, got \(error)")
        return
      }
    }
  }

  func testTrafficPaddingRoundTripAndMalformedFrameBehavior() throws {
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
    let wrapped = try TrafficPadding.wrapIfEnabled(payload, label: "unit")

    XCTAssertEqual(wrapped.count, 128)
    XCTAssertEqual(TrafficPadding.unwrapIfNeeded(wrapped, label: "unit"), payload)
    var offsetStorage = Data(repeating: 0xEE, count: 17)
    offsetStorage.append(wrapped)
    let wrappedSlice = offsetStorage.dropFirst(17)
    XCTAssertNotEqual(wrappedSlice.startIndex, 0)
    XCTAssertEqual(TrafficPadding.unwrapIfNeeded(wrappedSlice, label: "unit/slice"), payload)

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
      iosP2P.contains("let protocolIdentityPublicKeys = try await localProtocolIdentityPublicKeysForPairing()"))
    XCTAssertTrue(iosP2P.contains("protocolIdentityPublicKeys: protocolIdentityPublicKeys"))
    XCTAssertTrue(
      iosP2P.contains("let configuration = try ProtocolSigningIdentityPolicy.requiredConfiguration()"),
      "iOS pairing advertisements must resolve the committed protocol-identity algorithm, not an implicit default.")
    XCTAssertTrue(
      iosP2P.contains("let active = try await skyBridgeCore.committedActiveProtocolIdentitySnapshot()"),
      "The configured identity must be loaded before optional compatibility identities.")
    XCTAssertTrue(
      iosP2P.contains("Configured protocol identity is missing from the pairing advertisement"),
      "A missing active identity must fail the advertisement instead of silently publishing compatibility-only keys.")
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
    XCTAssertTrue(iosReceiver.contains("op: .completeAck"))
    XCTAssertTrue(iosReceiver.contains("receivedBytes: state.receivedBytes"))
    XCTAssertTrue(iosReceiver.contains("fileSha256: actualFileSHA256"))
    XCTAssertTrue(macConnection.contains("WebRTCOutboundFileTransferSupport.validateCompletionAck"))
    XCTAssertTrue(macConnection.contains("ack.receivedBytes == expectedFileSize"))
    XCTAssertTrue(macConnection.contains("ack.fileSha256 == expectedFileSha256"))
  }

  func testClassicFileTransferCompressionNeverChangesWireEncodingAfterFailure() throws {
    let iosSender = try iosFileTransferManagerSource()

    XCTAssertTrue(
      iosSender.contains("ClassicTransferZlibCompressionWorker.shared.compress"),
      "A zlib-advertised chunk must be bounded and fail explicitly when compression fails."
    )
    XCTAssertFalse(
      iosSender.contains("(try? compressData(chunkData)) ?? chunkData"),
      "The sender must never advertise zlib while silently sending plaintext bytes."
    )
    XCTAssertTrue(iosSender.contains("if metadata.compression == \"zlib\""))
    XCTAssertFalse(
      iosSender.contains("(try? decompressData(decrypted)) ?? decrypted"),
      "The receiver must derive decoding exclusively from authenticated transfer metadata."
    )
  }

  func testWebRTCFileTransferIntegrityValidationStaysCentralized() throws {
    let iosReceiver = try crossNetworkWebRTCFileTransferSource()
    let integrity = try crossNetworkFileTransferIntegritySource()

    XCTAssertTrue(integrity.contains("enum CrossNetworkFileTransferIntegrityValidator"))
    XCTAssertTrue(integrity.contains("static func verifiedChunkHash"))
    XCTAssertTrue(integrity.contains("static func validateMerkleProof"))
    XCTAssertTrue(integrity.contains("CrossNetworkMerkleAuthCompat.signatureAlgV1"))
    XCTAssertFalse(
      iosReceiver.contains("CrossNetworkFileTransferIntegrityValidator.verifiedChunkHash"))
    XCTAssertTrue(iosReceiver.contains("expectedSHA256: msg.chunkSha256"))
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

  func testIOSWebRTCStatsCallbackBridgeAcceptsOnlyFirstCompletion() async {
    let outcome = await WebRTCSession.awaitBoundedStatsCallback(
      timeoutSeconds: 0.5
    ) { completion in
      completion(7)
      completion(9)
    }

    guard case .completed(let value) = outcome else {
      XCTFail("The first callback must complete the bounded bridge")
      return
    }
    XCTAssertEqual(value, 7)
  }

  func testIOSWebRTCStatsCallbackBridgeTimesOutWhenCallbackNeverArrives() async {
    let clock = ContinuousClock()
    let startedAt = clock.now
    let outcome: WebRTCSession.BoundedCallbackOutcome<Int> =
      await WebRTCSession.awaitBoundedStatsCallback(timeoutSeconds: 0.03) { _ in }
    let elapsed = startedAt.duration(to: clock.now)

    guard case .timedOut = outcome else {
      XCTFail("A missing libwebrtc callback must resolve as an explicit timeout")
      return
    }
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(20))
    XCTAssertLessThan(elapsed, .seconds(1))
  }

  func testIOSWebRTCStatsCallbackBridgeCancellationResumesWaiter() async {
    let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = Task<WebRTCSession.BoundedCallbackOutcome<Int>, Never> {
      await WebRTCSession.awaitBoundedStatsCallback(
        timeoutSeconds: 5
      ) { _ in
        startedContinuation.yield(())
      }
    }

    for await _ in started {
      break
    }
    startedContinuation.finish()
    task.cancel()
    let outcome = await task.value

    guard case .cancelled = outcome else {
      XCTFail("Cancellation must resume the callback waiter without waiting for timeout")
      return
    }
  }

  func testIOSWebRTCQueuedCallbacksAreLifecycleGatedAtExecution() throws {
    let source = try webRTCSessionSource()
    let callbackBody = try sourceSlice(
      from: "private func dispatchActiveLifecycleCallback",
      to: "public nonisolated static let screenChunkedWireFormat",
      in: source
    )

    XCTAssertTrue(callbackBody.contains("let expectedLifecycleToken = withState { lifecycleToken }"))
    XCTAssertTrue(callbackBody.contains("Self.lifecycleGuardAllowsCallback("))
    XCTAssertTrue(callbackBody.contains("currentLifecycleToken: self.lifecycleToken"))
    XCTAssertTrue(callbackBody.contains("expectedLifecycleToken: expectedLifecycleToken"))
    XCTAssertTrue(callbackBody.contains("guard remainsActive else { return }"))
    XCTAssertTrue(source.contains("lifecycleToken &+= 1"))
    XCTAssertTrue(source.contains("dispatchActiveLifecycleCallback {"))
  }

  func testIOSWebRTCDisconnectJoinsReceiveLoopsWithoutSelfAwait() throws {
    let source = try crossNetworkWebRTCManagerSource()
    let disconnectBody = try sourceSlice(
      from: "private func disconnectInternal(",
      to: "private func rollbackFailedSessionSetup",
      in: source
    )
    let failureBody = try sourceSlice(
      from: "private func failAuthenticatedWebRTCChannel(",
      to: "nonisolated func receiveScreenLoop",
      in: source
    )

    XCTAssertTrue(disconnectBody.contains("originatingReceiveLoop: ReceiveLoopTaskKind? = nil"))
    XCTAssertTrue(disconnectBody.contains("controlReceiveTask?.cancel()"))
    XCTAssertTrue(disconnectBody.contains("detachedScreenReceiveTask?.cancel()"))
    XCTAssertTrue(disconnectBody.contains("let closingHandshakeDriver = handshakeDriver"))
    XCTAssertTrue(disconnectBody.contains("handshakeDriver = nil"))
    XCTAssertTrue(disconnectBody.contains("handshakeDriverCancellationTask = Task {"))
    XCTAssertTrue(disconnectBody.contains("await closingHandshakeDriver.cancel()"))
    XCTAssertTrue(disconnectBody.contains("await joinDetachedHandshakeDriverCancellationTask("))
    XCTAssertTrue(disconnectBody.contains("let closingSignaling = signaling"))
    XCTAssertTrue(disconnectBody.contains("signaling = nil"))
    XCTAssertTrue(disconnectBody.contains("signalingCloseTask = Task {"))
    XCTAssertTrue(disconnectBody.contains("await closingSignaling.close()"))
    XCTAssertTrue(disconnectBody.contains("await joinDetachedSignalingCloseTask("))
    XCTAssertTrue(disconnectBody.contains("await controlInboundQueue.finish()"))
    XCTAssertTrue(disconnectBody.contains("await detachedScreenInboundQueue.finish()"))
    XCTAssertTrue(disconnectBody.contains("await joinDetachedReceiveLoopTasks("))
    XCTAssertTrue(disconnectBody.contains("originatingReceiveLoop: originatingReceiveLoop"))
    XCTAssertTrue(failureBody.contains("originatingReceiveLoop: ReceiveLoopTaskKind"))
    XCTAssertTrue(failureBody.contains("sessionObjectIdentifier: ObjectIdentifier"))
    XCTAssertTrue(failureBody.contains("guard isCurrentSession("))
    XCTAssertTrue(failureBody.contains("sessionId: sessionId"))
    XCTAssertTrue(failureBody.contains("sessionObjectIdentifier: sessionObjectIdentifier"))
    XCTAssertTrue(failureBody.contains("originatingReceiveLoop: originatingReceiveLoop"))
    XCTAssertFalse(failureBody.contains("await disconnect(clearSnapshot: true)"))

    let screenCancel = try XCTUnwrap(disconnectBody.range(of: "detachedScreenReceiveTask?.cancel()"))
    let sessionClose = try XCTUnwrap(disconnectBody.range(of: "closingSession?.close()"))
    let fileTransferInvalidation = try XCTUnwrap(
      disconnectBody.range(of: "invalidateInboundFileTransferOperationsForTeardown()")
    )
    let handshakeDriverCapture = try XCTUnwrap(
      disconnectBody.range(of: "let closingHandshakeDriver = handshakeDriver")
    )
    let handshakeDriverDetach = try XCTUnwrap(
      disconnectBody.range(of: "handshakeDriver = nil")
    )
    let handshakeDriverCancellationSchedule = try XCTUnwrap(
      disconnectBody.range(of: "handshakeDriverCancellationTask = Task {")
    )
    let handshakeDriverCancellationJoin = try XCTUnwrap(
      disconnectBody.range(of: "await joinDetachedHandshakeDriverCancellationTask(")
    )
    let signalingCapture = try XCTUnwrap(
      disconnectBody.range(of: "let closingSignaling = signaling")
    )
    let signalingDetach = try XCTUnwrap(disconnectBody.range(of: "signaling = nil"))
    let signalingCloseSchedule = try XCTUnwrap(
      disconnectBody.range(of: "signalingCloseTask = Task {")
    )
    let signalingCloseJoin = try XCTUnwrap(
      disconnectBody.range(of: "await joinDetachedSignalingCloseTask(")
    )
    XCTAssertLessThan(handshakeDriverCapture.lowerBound, handshakeDriverDetach.lowerBound)
    XCTAssertLessThan(handshakeDriverDetach.lowerBound, handshakeDriverCancellationSchedule.lowerBound)
    XCTAssertLessThan(handshakeDriverCancellationSchedule.lowerBound, handshakeDriverCancellationJoin.lowerBound)
    XCTAssertLessThan(signalingCapture.lowerBound, signalingDetach.lowerBound)
    XCTAssertLessThan(signalingDetach.lowerBound, signalingCloseSchedule.lowerBound)
    XCTAssertLessThan(signalingCloseSchedule.lowerBound, signalingCloseJoin.lowerBound)
    XCTAssertLessThan(handshakeDriverCancellationJoin.lowerBound, signalingCloseJoin.lowerBound)
    XCTAssertLessThan(screenCancel.lowerBound, signalingCloseJoin.lowerBound)
    XCTAssertLessThan(sessionClose.lowerBound, signalingCloseJoin.lowerBound)
    XCTAssertLessThan(fileTransferInvalidation.lowerBound, signalingCloseJoin.lowerBound)
    let controlJoin = try XCTUnwrap(disconnectBody.range(of: "await joinDetachedReceiveLoopTasks("))
    let transferCleanup = try XCTUnwrap(disconnectBody.range(of: "await cleanupInboundFileTransfers()"))
    let keyClear = try XCTUnwrap(disconnectBody.range(of: "sessionKeys = nil"))
    XCTAssertLessThan(controlJoin.lowerBound, transferCleanup.lowerBound)
    XCTAssertLessThan(transferCleanup.lowerBound, keyClear.lowerBound)

    let handshakeCancellationJoinBody = try sourceSlice(
      from: "private func joinDetachedHandshakeDriverCancellationTask(",
      to: "public func disconnect(clearSnapshot:",
      in: source
    )
    XCTAssertTrue(
      handshakeCancellationJoinBody.contains(
        "timeoutSeconds: Self.handshakeDriverTeardownJoinTimeoutSeconds"
      )
    )
    XCTAssertTrue(handshakeCancellationJoinBody.contains("pendingDisconnectFailure == nil"))
    XCTAssertTrue(handshakeCancellationJoinBody.contains("handshake-driver-quarantined"))

    let signalingCloseJoinBody = try sourceSlice(
      from: "private func joinDetachedSignalingCloseTask(",
      to: "public func disconnect(clearSnapshot:",
      in: source
    )
    XCTAssertTrue(
      signalingCloseJoinBody.contains(
        "timeoutSeconds: Self.signalingTeardownJoinTimeoutSeconds"
      )
    )
    XCTAssertTrue(signalingCloseJoinBody.contains("pendingDisconnectFailure == nil"))
    XCTAssertTrue(signalingCloseJoinBody.contains("signaling-close-quarantined"))
  }

  func testIOSCrossNetworkProductionDiagnosticsRedactIdentifiersAndRawErrors() throws {
    let source = try crossNetworkWebRTCManagerSource()

    XCTAssertTrue(source.contains("private static func diagnosticErrorSummary(_ error: Error)"))
    XCTAssertTrue(
      source.contains(
        "join heartbeat start: session_ref=\\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
      )
    )
    XCTAssertTrue(
      source.contains(
        "QR parse phase=decoded session_ref=\\(SkyBridgeDiagnosticReference.stableReference(qr.sessionID)) device_ref=\\(SkyBridgeDiagnosticReference.stableReference(qr.deviceID))"
      )
    )
    XCTAssertTrue(
      source.contains(
        "WebRTC rekey start: session_ref=\\(SkyBridgeDiagnosticReference.stableReference(sessionId))"
      )
    )
    XCTAssertTrue(source.contains("Self.diagnosticErrorSummary(error)"))

    let forbiddenProductionLogFragments = [
      "join heartbeat start: session=\\(sessionId)",
      "join heartbeat exhausted before transportReady: session=\\(sessionId)",
      "QR parse phase=decoded session=\\(qr.sessionID) device=\\(qr.deviceID)",
      "cross-network phase=signaling_bound session=\\(sessionId)",
      "WebRTC transport ready: session=\\(sessionId)",
      "cross-network phase=session_started session=\\(sessionId)",
      "cross-network phase=join_sent session=\\(sessionId)",
      "WebRTC rekey start: session=\\(sessionId)",
      "WebRTC heartbeat send failed: \\(error.localizedDescription)",
      "inbound WebRTC rekey driver 初始化失败: session=\\(sessionId), err=\\(error.localizedDescription)",
      "screen-channel payload 解密/解析失败，已重置 length parser: wireMode=lengthFramed \\(error.localizedDescription)"
    ]
    for fragment in forbiddenProductionLogFragments {
      XCTAssertFalse(source.contains(fragment), "Production diagnostic still contains raw data: \(fragment)")
    }
  }

  func testIOSInboundFileTransferAckFailureClosesAuthenticatedControlChannel() throws {
    let source = try crossNetworkWebRTCFileTransferSource()
    let sendAckBody = try sourceSlice(
      from: "func sendAck(_ ack: CrossNetworkFileTransferMessage, label: String) async",
      to: "if let validationError = Self.validateInboundTransferId",
      in: source
    )

    XCTAssertTrue(sendAckBody.contains("try await sendFileTransferMessage(ack)"))
    XCTAssertTrue(sendAckBody.contains("failInboundFileTransferControlChannel("))
    XCTAssertTrue(sendAckBody.contains("inboundFileTransferLifecycleToken == expectedLifecycleToken"))
    XCTAssertTrue(sendAckBody.contains("sessionKeys?.sessionId == sessionID"))
    XCTAssertTrue(
      sendAckBody.contains("WebRTC file-transfer acknowledgement delivery failed"),
      "A failed authenticated ACK must be surfaced as a session failure instead of being logged and ignored."
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
    XCTAssertEqual(
      WebRTCSession.pendingRemoteICEPlan(
        isDuplicate: false,
        hasRemoteDescription: false,
        pendingCount: 256
      ),
      .overflow
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
  func testResolveBestTransferDeviceFailsClosedForAmbiguousOrIncompleteScopedHostCandidates() {
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

    func candidate(
      id: String,
      name: String,
      domain: String?,
      port: UInt16?
    ) -> DiscoveredDevice {
      DiscoveredDevice(
        id: id,
        name: name,
        bonjourServiceName: name,
        modelName: "Mac",
        platform: .macOS,
        osVersion: "26.3.1",
        ipAddress: "fe80::468:f5a1:462b:29d3",
        bonjourServiceType: DiscoveredDevice.fileTransferServiceType,
        bonjourServiceDomain: domain,
        services: [DiscoveredDevice.fileTransferServiceType],
        portMap: port.map { [DiscoveredDevice.fileTransferServiceType: $0] } ?? [:],
        signalStrength: -38,
        lastSeen: Date(),
        isConnected: false,
        isTrusted: true,
        publicKey: nil,
        advertisedCapabilities: ["file_transfer"],
        capabilities: ["file_transfer"]
      )
    }

    let first = candidate(
      id: "id:peer-transfer-a",
      name: "MacBook Pro A",
      domain: "local.",
      port: 8080
    )
    let second = candidate(
      id: "id:peer-transfer-b",
      name: "MacBook Pro B",
      domain: "local.",
      port: 8080
    )
    let incomplete = candidate(
      id: "id:peer-transfer-incomplete",
      name: "MacBook Pro Incomplete",
      domain: nil,
      port: nil
    )

    XCTAssertEqual(
      FileTransferManager.resolveBestTransferDevice(
        target: target,
        discovered: [first, second]
      ).id,
      target.id
    )
    XCTAssertEqual(
      FileTransferManager.resolveBestTransferDevice(
        target: target,
        discovered: [incomplete]
      ).id,
      target.id
    )
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

  private func makeH264BootstrapScreenData(
    sequence: UInt64,
    encodedByteCount: Int? = nil
  ) -> ScreenData {
    var imageData = Data([
      0x00, 0x00, 0x00, 0x01, 0x67, 0x42,
      0x00, 0x00, 0x00, 0x01, 0x68, 0xCE,
      0x00, 0x00, 0x00, 0x01, 0x65, UInt8(truncatingIfNeeded: sequence),
    ])
    if let encodedByteCount {
      precondition(encodedByteCount >= imageData.count)
      imageData.append(
        Data(repeating: 0xAB, count: encodedByteCount - imageData.count)
      )
    }
    return ScreenData(
      width: 1280,
      height: 720,
      imageData: imageData,
      timestamp: TimeInterval(sequence),
      format: "h264",
      isSyncFrame: false,
      sequenceNumber: sequence
    )
  }

  private func makeH264PredictiveScreenData(
    sequence: UInt64,
    encodedByteCount: Int
  ) -> ScreenData {
    var imageData = Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x55])
    precondition(encodedByteCount >= imageData.count)
    imageData.append(
      Data(repeating: 0xAB, count: encodedByteCount - imageData.count)
    )
    return ScreenData(
      width: 1280,
      height: 720,
      imageData: imageData,
      timestamp: TimeInterval(sequence),
      format: "h264",
      isSyncFrame: false,
      sequenceNumber: sequence
    )
  }

  private func classifiedScreenFrame(
    _ screenData: ScreenData
  ) throws -> RemoteDesktopClassifiedScreenFrame {
    RemoteDesktopClassifiedScreenFrame(
      screenData: screenData,
      traits: try RemoteDesktopScreenFrameWire.classifyVideoFrame(
        format: screenData.format,
        imageData: screenData.imageData
      )
    )
  }

  func testRemoteDesktopDecodeQueuePolicyPreservesPredictiveVideoOrder() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    let first = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x01]),
      timestamp: 1,
      format: "h264"
    )
    let second = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x02]),
      timestamp: 2,
      format: "h264"
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(first),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(second),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.screenData.imageData,
      first.imageData)
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.dequeueNext(from: &pending)?.screenData.imageData,
      second.imageData)
  }

  func testRemoteDesktopDecodeQueuePolicyDoesNotDropPendingFramesOnNormalSyncFrame() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
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
        try classifiedScreenFrame(firstPredictive),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(secondPredictive),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(normalSyncFrame),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .enqueued
    )

    XCTAssertEqual(
      pending.map(\.screenData.imageData),
      [
        firstPredictive.imageData,
        secondPredictive.imageData,
        normalSyncFrame.imageData,
      ])
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyKeepsNormalIndependentBurstInOrder() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    let frames = (0..<(RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames - 1)).map {
      makeH264BootstrapScreenData(sequence: UInt64($0))
    }

    for frame in frames {
      XCTAssertEqual(
        RemoteDesktopDecodeQueuePolicy.enqueue(
          try classifiedScreenFrame(frame),
          into: &pending,
          waitingForSyncFrame: &waitingForSyncFrame,
          decoderProgressStalled: false
        ),
        .enqueued
      )
    }

    XCTAssertEqual(
      pending.compactMap(\.screenData.sequenceNumber),
      frames.compactMap(\.sequenceNumber)
    )
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyAcceptsExactEncodedByteBudget() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    let byteBudget = 64
    let first = makeH264PredictiveScreenData(sequence: 1, encodedByteCount: 31)
    let second = makeH264PredictiveScreenData(sequence: 2, encodedByteCount: 33)

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(first),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false,
        maxPredictiveVideoFrames: 100,
        hardMaxPredictiveVideoFrames: 100,
        maxQueuedEncodedBytes: byteBudget
      ),
      .enqueued
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(second),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false,
        maxPredictiveVideoFrames: 100,
        hardMaxPredictiveVideoFrames: 100,
        maxQueuedEncodedBytes: byteBudget
      ),
      .enqueued
    )

    XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.queuedEncodedByteCount(in: pending), byteBudget)
    XCTAssertEqual(pending.compactMap(\.screenData.sequenceNumber), [1, 2])
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyRejectsProspectiveBudgetByOneByte() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    let byteBudget = 64
    let first = makeH264PredictiveScreenData(sequence: 1, encodedByteCount: 31)
    let overflow = makeH264PredictiveScreenData(sequence: 2, encodedByteCount: 34)

    _ = RemoteDesktopDecodeQueuePolicy.enqueue(
      try classifiedScreenFrame(first),
      into: &pending,
      waitingForSyncFrame: &waitingForSyncFrame,
      decoderProgressStalled: false,
      maxPredictiveVideoFrames: 100,
      hardMaxPredictiveVideoFrames: 100,
      maxQueuedEncodedBytes: byteBudget
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(overflow),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false,
        maxPredictiveVideoFrames: 100,
        hardMaxPredictiveVideoFrames: 100,
        maxQueuedEncodedBytes: byteBudget
      ),
      .enteredWaitingForSync
    )

    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyCompactsContinuousLargeIndependentFramesByBytes() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    let frameBytes = 64
    let byteBudget = frameBytes * 3
    var sawCompaction = false

    for sequence in 0..<11 {
      let result = RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(
          makeH264BootstrapScreenData(
            sequence: UInt64(sequence),
            encodedByteCount: frameBytes
          )
        ),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false,
        maxPredictiveVideoFrames: 100,
        hardMaxPredictiveVideoFrames: 100,
        maxQueuedEncodedBytes: byteBudget
      )
      sawCompaction = sawCompaction || result == .compactedWithIndependentFrame
      XCTAssertLessThanOrEqual(
        RemoteDesktopDecodeQueuePolicy.queuedEncodedByteCount(in: pending),
        byteBudget
      )
      XCTAssertLessThanOrEqual(pending.count, 3)
      XCTAssertFalse(waitingForSyncFrame)
    }

    XCTAssertTrue(sawCompaction)
    XCTAssertEqual(pending.last?.screenData.sequenceNumber, 10)
    XCTAssertTrue(pending.last?.traits.isDecoderBootstrapFrame == true)
  }

  func testRemoteDesktopDecodeQueuePolicyBytePressureClearsPredictiveChainAndRequiresBootstrap() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    let byteBudget = 64

    _ = RemoteDesktopDecodeQueuePolicy.enqueue(
      try classifiedScreenFrame(
        makeH264PredictiveScreenData(sequence: 1, encodedByteCount: byteBudget)
      ),
      into: &pending,
      waitingForSyncFrame: &waitingForSyncFrame,
      decoderProgressStalled: false,
      maxPredictiveVideoFrames: 100,
      hardMaxPredictiveVideoFrames: 100,
      maxQueuedEncodedBytes: byteBudget
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(
          makeH264PredictiveScreenData(sequence: 2, encodedByteCount: 6)
        ),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false,
        maxPredictiveVideoFrames: 100,
        hardMaxPredictiveVideoFrames: 100,
        maxQueuedEncodedBytes: byteBudget
      ),
      .enteredWaitingForSync
    )
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(waitingForSyncFrame)

    let idrWithoutParameterSets = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88]),
      timestamp: 3,
      format: "h264",
      isSyncFrame: true,
      sequenceNumber: 3
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(idrWithoutParameterSets),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false,
        maxPredictiveVideoFrames: 100,
        hardMaxPredictiveVideoFrames: 100,
        maxQueuedEncodedBytes: byteBudget
      ),
      .droppedIncomingPredictiveFrame
    )

    let bootstrap = makeH264BootstrapScreenData(sequence: 4, encodedByteCount: byteBudget)
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(bootstrap),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false,
        maxPredictiveVideoFrames: 100,
        hardMaxPredictiveVideoFrames: 100,
        maxQueuedEncodedBytes: byteBudget
      ),
      .recoveredWithIndependentFrame
    )
    XCTAssertEqual(RemoteDesktopDecodeQueuePolicy.queuedEncodedByteCount(in: pending), byteBudget)
    XCTAssertEqual(pending.first?.screenData.sequenceNumber, 4)
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyRejectsSingleFrameLargerThanByteBudget() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    let oversizedBootstrap = makeH264BootstrapScreenData(sequence: 1)

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(oversizedBootstrap),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        maxQueuedEncodedBytes: oversizedBootstrap.imageData.count - 1
      ),
      .droppedIncomingFrameExceedingByteBudget
    )
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueueBudgetArithmeticDoesNotOverflow() {
    XCTAssertFalse(
      RemoteDesktopDecodeQueuePolicy.exceedsEncodedByteBudget(
        queuedEncodedByteCounts: [Int.max - 2],
        incomingEncodedBytes: 2,
        maximumEncodedBytes: Int.max
      )
    )
    XCTAssertTrue(
      RemoteDesktopDecodeQueuePolicy.exceedsEncodedByteBudget(
        queuedEncodedByteCounts: [Int.max - 2],
        incomingEncodedBytes: 3,
        maximumEncodedBytes: Int.max
      )
    )
    XCTAssertTrue(
      RemoteDesktopDecodeQueuePolicy.exceedsEncodedByteBudget(
        queuedEncodedByteCounts: [Int.max],
        incomingEncodedBytes: 1,
        maximumEncodedBytes: Int.max
      )
    )
  }

  func testPendingDecodeCompletionRetainsOnlySourceFrameSequenceMetadata() {
    let completion = RemoteDesktopManager.PendingDecodeCompletion(
      decoded: nil,
      decodeFailureReason: "callback-no-image",
      isStillImageFrame: false,
      sourceFrameSequenceNumber: 42,
      frameTraits: RemoteDesktopVideoFrameTraits(
        normalizedFormat: "h264",
        isPredictiveVideo: true,
        isIndependentlyDecodableFrame: false,
        isDecoderBootstrapFrame: false
      ),
      format: "h264",
      decoder: VideoDecoder(),
      generation: 7
    )

    XCTAssertEqual(completion.sourceFrameSequenceNumber, 42)
    XCTAssertEqual(completion.decodeFailureReason, "callback-no-image")
    XCTAssertEqual(completion.generation, 7)
  }

  func testCameraWatchdogFailureIsTypedAndTerminatesVisibleSession() {
    let failure = CameraRemoteDesktopRuntimeError.watchdogFailed
    let presentation = CameraTerminalFailurePresentationPolicy.resolve(
      hadVisibleFrame: true,
      intendedState: .error(failure.localizedDescription),
      terminalFailure: failure,
      cleanupFailure: nil
    )

    XCTAssertEqual(failure.localizedDescription, "The camera progress watchdog failed.")
    XCTAssertEqual(presentation.state, .error(failure.localizedDescription))
    XCTAssertEqual(presentation.message, failure.localizedDescription)
  }

  func testRemoteDesktopDecodeQueuePolicyBoundsContinuousIndependentFramesAndKeepsNewest() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
    var waitingForSyncFrame = false
    var sawCompaction = false
    let frameCount = RemoteDesktopDecodeQueuePolicy.hardMaxPredictiveVideoFrames * 4 + 7

    for index in 0..<frameCount {
      let frame = makeH264BootstrapScreenData(sequence: UInt64(index))
      let result = RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(frame),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false
      )
      if result == .compactedWithIndependentFrame {
        sawCompaction = true
        XCTAssertEqual(pending.count, 1)
      }
      XCTAssertLessThanOrEqual(
        pending.count,
        RemoteDesktopDecodeQueuePolicy.hardMaxPredictiveVideoFrames
      )
      XCTAssertFalse(waitingForSyncFrame)
    }

    XCTAssertTrue(sawCompaction)
    XCTAssertEqual(pending.last?.screenData.sequenceNumber, UInt64(frameCount - 1))
    XCTAssertTrue(pending.last?.traits.isDecoderBootstrapFrame == true)
  }

  func testRemoteDesktopDecodeQueuePolicyCompactsToIndependentFrameWhenProgressStalls() throws {
    var pending = try (0..<RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames).map { index in
      try classifiedScreenFrame(ScreenData(
        width: 1280,
        height: 720,
        imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, UInt8(index)]),
        timestamp: TimeInterval(index),
        format: "h264"
      ))
    }
    var waitingForSyncFrame = false
    let newestIndependentFrame = makeH264BootstrapScreenData(sequence: 10_000)

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(newestIndependentFrame),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: true
      ),
      .compactedWithIndependentFrame
    )
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.screenData.sequenceNumber, newestIndependentFrame.sequenceNumber)
    XCTAssertTrue(pending.first?.traits.isDecoderBootstrapFrame == true)
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyStillImagesReplaceLatestFrame() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
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
      try classifiedScreenFrame(stale),
      into: &pending,
      waitingForSyncFrame: &waitingForSyncFrame
    )
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(latest),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .replacedStillFrame
    )

    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.screenData.imageData, latest.imageData)
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyAbsorbsShortBurstWhileDecoderProgresses() throws {
    var pending = try (0..<RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames).map { index in
      try classifiedScreenFrame(ScreenData(
        width: 1280,
        height: 720,
        imageData: Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, UInt8(index)]),
        timestamp: TimeInterval(index),
        format: "hevc"
      ))
    }
    var waitingForSyncFrame = false
    let overflow = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xFE]),
      timestamp: 99,
      format: "hevc"
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(overflow),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false
      ),
      .enqueuedAboveSoftLimit
    )
    XCTAssertEqual(pending.count, RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames + 1)
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyEntersWaitingForSyncOnlyWhenProgressStalls() throws {
    var pending = try (0..<RemoteDesktopDecodeQueuePolicy.maxPredictiveVideoFrames).map { index in
      try classifiedScreenFrame(ScreenData(
        width: 1280,
        height: 720,
        imageData: Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, UInt8(index)]),
        timestamp: TimeInterval(index),
        format: "hevc"
      ))
    }
    var waitingForSyncFrame = false
    let overflow = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xFE]),
      timestamp: 99,
      format: "hevc"
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(overflow),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: true
      ),
      .enteredWaitingForSync
    )
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyPredictiveFrameStillEntersWaitingAtHardLimit() throws {
    var pending = try (0..<RemoteDesktopDecodeQueuePolicy.hardMaxPredictiveVideoFrames).map { index in
      try classifiedScreenFrame(ScreenData(
        width: 1280,
        height: 720,
        imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, UInt8(index)]),
        timestamp: TimeInterval(index),
        format: "h264"
      ))
    }
    var waitingForSyncFrame = false
    let predictiveFrame = ScreenData(
      width: 1280,
      height: 720,
      imageData: Data([0x00, 0x00, 0x00, 0x01, 0x41, 0xFE]),
      timestamp: 100,
      format: "h264"
    )

    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.enqueue(
        try classifiedScreenFrame(predictiveFrame),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame,
        decoderProgressStalled: false
      ),
      .enteredWaitingForSync
    )
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueuePolicyRecoversWhenSyncFrameArrives() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
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
        try classifiedScreenFrame(syncFrame),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .recoveredWithIndependentFrame
    )
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending.first?.screenData.imageData, syncFrame.imageData)
    XCTAssertFalse(waitingForSyncFrame)
  }

  func testRemoteDesktopDecodeQueueDoesNotRecoverFromH264IDRWithoutParameterSets() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
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
        try classifiedScreenFrame(idrOnlyFrame),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .droppedIncomingPredictiveFrame
    )
    XCTAssertTrue(pending.isEmpty)
    XCTAssertTrue(waitingForSyncFrame)
  }

  func testRemoteDesktopScreenFrameWireDoesNotTrustAdvertisedHEVCSyncWithoutIRAPNAL() throws {
    let predictiveHEVC = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x88])

    let traits = try RemoteDesktopScreenFrameWire.classifyVideoFrame(
      format: "hevc",
      imageData: predictiveHEVC
    )
    XCTAssertFalse(traits.isIndependentlyDecodableFrame)
  }

  func testRemoteDesktopScreenFrameWireDetectsHEVCIRAPWhenAdvertisedFalse() throws {
    let hevcIRAP = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88])

    let traits = try RemoteDesktopScreenFrameWire.classifyVideoFrame(
      format: "hevc",
      imageData: hevcIRAP
    )
    XCTAssertTrue(traits.isIndependentlyDecodableFrame)
  }

  func testRemoteDesktopScreenFrameWireRejectsMalformedOneByteHEVCNALHeaders() {
    let malformedIRAP = Data([0x00, 0x00, 0x00, 0x01, 0x26])
    let malformedBootstrap = Data([
      0x00, 0x00, 0x00, 0x01, 0x40,
      0x00, 0x00, 0x00, 0x01, 0x42,
      0x00, 0x00, 0x00, 0x01, 0x44,
      0x00, 0x00, 0x00, 0x01, 0x26
    ])

    XCTAssertThrowsError(
      try RemoteDesktopScreenFrameWire.classifyVideoFrame(
        format: "hevc",
        imageData: malformedIRAP
      )
    )
    XCTAssertThrowsError(
      try RemoteDesktopScreenFrameWire.classifyVideoFrame(
        format: "hevc",
        imageData: malformedBootstrap
      )
    )
  }

  func testRemoteDesktopScreenFrameWireRejectsMaliciousH264AndHEVCNALHeaders() {
    let maliciousFrames: [(format: String, data: Data)] = [
      ("h264", Data([0x00, 0x00, 0x00, 0x01, 0xE5, 0x88])),
      ("h264", Data([0x00, 0x00, 0x00, 0x01, 0x78, 0x88])),
      ("hevc", Data([0x00, 0x00, 0x00, 0x01, 0xA6, 0x01, 0x88])),
      ("hevc", Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x00, 0x88])),
    ]

    for frame in maliciousFrames {
      XCTAssertThrowsError(
        try RemoteDesktopScreenFrameWire.classifyVideoFrame(
          format: frame.format,
          imageData: frame.data
        )
      ) { error in
        XCTAssertEqual(
          error as? RemoteDesktopVideoFrameClassificationError,
          .invalidNALHeader
        )
      }
    }
  }

  func testRemoteDesktopScreenFrameWireClassifierEnforcesStructuralAndAllocationBounds() {
    let oversizedAccessUnit = Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)
    XCTAssertThrowsError(
      try RemoteDesktopScreenFrameWire.classifyVideoFrame(
        format: "h264",
        imageData: oversizedAccessUnit
      )
    ) { error in
      XCTAssertEqual(
        error as? RemoteDesktopVideoFrameClassificationError,
        .accessUnitTooLarge(actualBytes: 8 * 1_024 * 1_024 + 1, maximumBytes: 8 * 1_024 * 1_024)
      )
    }

    let truncatedLengthPrefixed = Data([0x00, 0x00, 0x00, 0x02, 0x65])
    XCTAssertThrowsError(
      try RemoteDesktopScreenFrameWire.classifyVideoFrame(
        format: "h264",
        imageData: truncatedLengthPrefixed
      )
    )

    var tooManyNALUnits = Data()
    for _ in 0...512 {
      tooManyNALUnits.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x41])
    }
    XCTAssertThrowsError(
      try RemoteDesktopScreenFrameWire.classifyVideoFrame(
        format: "h264",
        imageData: tooManyNALUnits
      )
    ) { error in
      XCTAssertEqual(
        error as? RemoteDesktopVideoFrameClassificationError,
        .tooManyNALUnits(actual: 513, maximum: 512)
      )
    }

    var oversizedSPS = Data([0x00, 0x00, 0x00, 0x01, 0x67])
    oversizedSPS.append(Data(repeating: 0, count: 65_536))
    XCTAssertThrowsError(
      try RemoteDesktopScreenFrameWire.classifyVideoFrame(
        format: "h264",
        imageData: oversizedSPS
      )
    ) { error in
      XCTAssertEqual(
        error as? RemoteDesktopVideoFrameClassificationError,
        .parameterSetTooLarge(actualBytes: 65_537, maximumBytes: 65_536)
      )
    }
  }

  func testRemoteDesktopDecodeQueueRequiresHEVCParameterSetsForSyncRecovery() throws {
    var pending: [RemoteDesktopClassifiedScreenFrame] = []
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
        try classifiedScreenFrame(hevcIRAPWithoutParameterSets),
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
        try classifiedScreenFrame(hevcBootstrap),
        into: &pending,
        waitingForSyncFrame: &waitingForSyncFrame
      ),
      .recoveredWithIndependentFrame
    )
    XCTAssertFalse(waitingForSyncFrame)
    XCTAssertEqual(pending.first?.screenData.imageData, hevcBootstrap.imageData)
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

    var storage = Data([0xA0, 0xA1, 0xA2])
    storage.append(wire)
    storage.append(0xA3)
    let wireSlice = storage[3..<(3 + wire.count)]
    XCTAssertEqual(wireSlice.startIndex, 3)

    let slicedDecoded = RemoteDesktopScreenFrameWire.decodeIfPresent(wireSlice)
    XCTAssertEqual(slicedDecoded?.format, "hevc")
    XCTAssertEqual(slicedDecoded?.imageData, payload)
    XCTAssertEqual(slicedDecoded?.sequenceNumber, 987_654_321)
    XCTAssertNil(RemoteDesktopScreenFrameWire.decodeIfPresent(wireSlice.dropLast()))
  }

  func testRemoteDesktopAudioChunkWireDecodesNonZeroStartIndexSliceAndRejectsTruncation() {
    func appendUInt32(_ value: UInt32, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt64(_ value: UInt64, to data: inout Data) {
      var bigEndian = value.bigEndian
      withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    let magicCookie = Data([0x11, 0x22])
    let audioPayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
    var wire = Data()
    appendUInt32(0x5342_5241, to: &wire)
    wire.append(2)
    wire.append(2)
    wire.append(2)
    wire.append(0)
    appendUInt32(48_000, to: &wire)
    appendUInt32(1_024, to: &wire)
    appendUInt32(1, to: &wire)
    appendUInt64(55, to: &wire)
    appendUInt64(123_500_000, to: &wire)
    appendUInt32(UInt32(magicCookie.count), to: &wire)
    appendUInt32(1, to: &wire)
    appendUInt32(UInt32(audioPayload.count), to: &wire)
    wire.append(magicCookie)
    appendUInt32(0, to: &wire)
    appendUInt32(1_024, to: &wire)
    appendUInt32(UInt32(audioPayload.count), to: &wire)
    wire.append(audioPayload)

    var storage = Data([0xB0, 0xB1])
    storage.append(wire)
    storage.append(0xB2)
    let wireSlice = storage[2..<(2 + wire.count)]
    XCTAssertEqual(wireSlice.startIndex, 2)

    let decoded = RemoteDesktopAudioChunkWire.decodeIfPresent(wireSlice)
    XCTAssertEqual(decoded?.encoding, .aacLC)
    XCTAssertEqual(decoded?.sampleRate, 48_000)
    XCTAssertEqual(decoded?.channelCount, 2)
    XCTAssertEqual(decoded?.frameCount, 1_024)
    XCTAssertEqual(decoded?.packetCount, 1)
    XCTAssertEqual(decoded?.packetDescriptions?.first?.startOffset, 0)
    XCTAssertEqual(decoded?.packetDescriptions?.first?.variableFramesInPacket, 1_024)
    XCTAssertEqual(decoded?.packetDescriptions?.first?.dataByteSize, 4)
    XCTAssertEqual(decoded?.magicCookie, magicCookie)
    XCTAssertEqual(decoded?.sequenceNumber, 55)
    XCTAssertEqual(decoded?.sentAt, 123.5)
    XCTAssertEqual(decoded?.data, audioPayload)
    XCTAssertNil(RemoteDesktopAudioChunkWire.decodeIfPresent(wireSlice.dropLast()))
  }

  func testRemoteDesktopDecodeQueuePolicyRequiresSyncAfterPredictiveSequenceGap() {
    XCTAssertEqual(
      RemoteDesktopDecodeQueuePolicy.validatePredictiveSequence(
        previous: 0,
        current: 1,
        isPredictiveVideo: true,
        isIndependentFrame: false
      ),
      .accepted
    )
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
    let fixture = try await makeWaitingFinishedSOAHandshake()
    let authorityBeforeFinished = await fixture.initiator.getAuthenticatedRemoteAuthority()
    let bindingBeforeFinished = await fixture.initiator.getAuthenticatedHandshakePeerBinding()
    XCTAssertNil(
      authorityBeforeFinished,
      "Signature validation alone must not publish authority before Finished key confirmation"
    )
    XCTAssertNil(bindingBeforeFinished)

    let responderFinished = LocalHandshakeFinishedHelper.responderFinished(
      for: fixture.sessionKeys)
    await fixture.initiator.handleMessage(
      responderFinished.encoded, from: PeerIdentifier(deviceId: "mac-peer"))

    let establishedKeys = try await fixture.handshakeTask.value
    XCTAssertEqual(establishedKeys.negotiatedSuite, .x25519Ed25519)

    guard case .established = await fixture.initiator.getCurrentState() else {
      XCTFail("Expected initiator handshake to establish")
      return
    }

    let initiatorAuthority = await fixture.initiator.getAuthenticatedRemoteAuthority()
    XCTAssertEqual(
      initiatorAuthority,
      try LocalHandshakeAuthorityHelper.authority(
        identityPublicKey: fixture.responderIdentity,
        signatureAlgorithm: fixture.signatureProvider.signatureAlgorithm
      )
    )
    let establishedBinding = await fixture.initiator.getAuthenticatedHandshakePeerBinding()
    let binding = try XCTUnwrap(establishedBinding)
    XCTAssertEqual(binding.authority, initiatorAuthority)
    XCTAssertEqual(binding.authenticatedRemoteSOAPeerId, fixture.remoteSOAPeerId)
  }

  func testHandshakeDriverCancellationDuringArbiterCommitDoesNotPublishOrLeakLease()
    async throws
  {
    let fixture = try await makeWaitingFinishedSOAHandshake(
      suspendEstablishmentCommit: true
    )
    let responderFinished = LocalHandshakeFinishedHelper.responderFinished(
      for: fixture.sessionKeys)
    let finishTask = Task {
      await fixture.initiator.handleMessage(
        responderFinished.encoded,
        from: PeerIdentifier(deviceId: "mac-peer")
      )
    }

    var enteredArbiterCommit = false
    for _ in 0..<100 {
      if await fixture.arbiter.testOnlyIsEstablishmentCommitSuspended() {
        enteredArbiterCommit = true
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(
      enteredArbiterCommit,
      "Finished handling never reached the suspended arbiter commit"
    )

    // Model the manager superseding A while its actor call is suspended. Driver
    // cancellation owns the exact reservation capability; tests must not widen
    // production teardown back to public pair/attempt deletion.
    await fixture.initiator.cancel()
    let replacementAttemptId = Data(
      repeating: 0x77,
      count: HandshakeSOAExtension.attemptIdLength
    )
    let replacementDecision = await fixture.arbiter.registerOutgoing(
      .init(
        pairKey: fixture.pairKey,
        initiatorPeerId: fixture.localSOAPeerId,
        attemptId: replacementAttemptId,
        startedAt: Date(),
        onSuperseded: { _, _ in }
      )
    )
    guard case .accepted(let replacementReservation) = replacementDecision else {
      XCTFail("Cancelled Finished commit retained its outgoing reservation")
      return
    }
    let replacementLease = try await fixture.arbiter.commitEstablished(
      replacementReservation,
      sessionId: "replacement-session"
    )

    // B now owns the slot. Late resumption of A must be exact and therefore
    // cannot clear, overwrite, or restore across B.
    try await fixture.arbiter.testOnlyResumeEstablishmentCommit(
      attemptId: fixture.attemptId
    )
    await finishTask.value
    await XCTAssertThrowsErrorAsync(try await fixture.handshakeTask.value) { _ in }

    guard case .failed(let reason) = await fixture.initiator.getCurrentState() else {
      XCTFail("Cancellation during arbiter commit must leave the handshake failed")
      return
    }
    XCTAssertEqual(reason, .cancelled)
    let authority = await fixture.initiator.getAuthenticatedRemoteAuthority()
    let binding = await fixture.initiator.getAuthenticatedHandshakePeerBinding()
    let lease = await fixture.initiator.getEstablishedArbiterLease()
    XCTAssertNil(authority)
    XCTAssertNil(binding)
    XCTAssertNil(lease)

    let staleLease = PeerSessionArbiter.EstablishedLease(
      pairKey: fixture.pairKey,
      sessionId: fixture.sessionKeys.sessionId
    )
    let staleClearSucceeded = await fixture.arbiter.clearEstablished(staleLease)
    let staleRestoreSucceeded = await fixture.arbiter.restoreEstablishedIfVacant(staleLease)
    XCTAssertFalse(staleClearSucceeded)
    XCTAssertFalse(staleRestoreSucceeded)

    let blockedByReplacement = await fixture.arbiter.registerOutgoing(
      .init(
        pairKey: fixture.pairKey,
        initiatorPeerId: fixture.localSOAPeerId,
        attemptId: Data(repeating: 0x78, count: HandshakeSOAExtension.attemptIdLength),
        startedAt: Date(),
        onSuperseded: { _, _ in }
      )
    )
    guard case .alreadyConnected = blockedByReplacement else {
      XCTFail("Stale A completion removed replacement B")
      return
    }
    let replacementClearSucceeded = await fixture.arbiter.clearEstablished(replacementLease)
    XCTAssertTrue(replacementClearSucceeded)
  }

  func testPeerSessionArbiterReplacementUsesExpectedOwnerCAS() async throws {
    let arbiter = PeerSessionArbiter()
    let localPeerId = Data(repeating: 0x10, count: HandshakeSOAExtension.initiatorPeerIdLength)
    let remotePeerId = Data(repeating: 0x20, count: HandshakeSOAExtension.initiatorPeerIdLength)
    let pairKey = PeerSessionArbiter.pairKey(
      localPeerId: localPeerId,
      remotePeerId: remotePeerId
    )
    let firstAttemptId = Data(repeating: 0x31, count: HandshakeSOAExtension.attemptIdLength)
    let firstDecision = await arbiter.registerOutgoing(
      .init(
        pairKey: pairKey,
        initiatorPeerId: localPeerId,
        attemptId: firstAttemptId,
        startedAt: Date(),
        onSuperseded: { _, _ in }
      )
    )
    guard case .accepted(let firstReservation) = firstDecision else {
      XCTFail("Initial establishment reservation was rejected")
      return
    }
    let firstLease = try await arbiter.commitEstablished(
      firstReservation,
      sessionId: "first-session"
    )

    let replacementAttemptId = Data(
      repeating: 0x32,
      count: HandshakeSOAExtension.attemptIdLength
    )
    let incomingDecision = await arbiter.evaluateIncoming(
      pairKey: pairKey,
      remoteInitiatorPeerId: remotePeerId,
      remoteAttemptId: replacementAttemptId,
      targetPeerId: localPeerId,
      expectedRemotePeerId: remotePeerId,
      localPeerId: localPeerId,
      establishedPolicy: .replaceAuthenticated
    )
    guard case .acceptAndReplaceEstablished(let replacementReservation) = incomingDecision else {
      XCTFail("Authenticated replacement was not reserved")
      return
    }

    let ownerStillBlocksOutgoing = await arbiter.registerOutgoing(
      .init(
        pairKey: pairKey,
        initiatorPeerId: localPeerId,
        attemptId: Data(repeating: 0x33, count: HandshakeSOAExtension.attemptIdLength),
        startedAt: Date(),
        onSuperseded: { _, _ in }
      )
    )
    guard case .alreadyConnected = ownerStillBlocksOutgoing else {
      XCTFail("Replacement evaluation removed the established owner before commit")
      return
    }

    let firstClearSucceeded = await arbiter.clearEstablished(firstLease)
    XCTAssertTrue(firstClearSucceeded)
    do {
      _ = try await arbiter.commitEstablished(
        replacementReservation,
        sessionId: "stale-replacement"
      )
      XCTFail("Replacement committed after its expected owner changed")
    } catch let error as PeerSessionArbiter.EstablishmentCommitError {
      XCTAssertEqual(error, .establishedOwnerChanged)
    }

    let finalAttemptId = Data(repeating: 0x34, count: HandshakeSOAExtension.attemptIdLength)
    let finalDecision = await arbiter.registerOutgoing(
      .init(
        pairKey: pairKey,
        initiatorPeerId: localPeerId,
        attemptId: finalAttemptId,
        startedAt: Date(),
        onSuperseded: { _, _ in }
      )
    )
    guard case .accepted(let finalReservation) = finalDecision else {
      XCTFail("Final establishment reservation was rejected")
      return
    }
    let finalLease = try await arbiter.commitEstablished(
      finalReservation,
      sessionId: "final-session"
    )
    let staleClearSucceeded = await arbiter.clearEstablished(firstLease)
    let staleRestoreSucceeded = await arbiter.restoreEstablishedIfVacant(firstLease)
    XCTAssertFalse(staleClearSucceeded)
    XCTAssertFalse(staleRestoreSucceeded)
    let finalClearSucceeded = await arbiter.clearEstablished(finalLease)
    XCTAssertTrue(finalClearSucceeded)
  }

  func testPeerSessionArbiterEmbeddedUUIDCannotCollideWithExactStableIdentifier() {
    let uuid = "55555555-5555-4555-8555-555555555555"
    let canonicalUUID = PeerSessionArbiter.canonicalSOAIdentifier(uuid)
    let exactPeerId = PeerSessionArbiter.soaPeerId(from: uuid)

    for attackerControlledIdentifier in [
      "attacker-\(uuid)-suffix",
      "id:attacker-\(uuid)-suffix",
      "recent:mac:id:attacker-\(uuid)-suffix",
    ] {
      XCTAssertNotEqual(
        PeerSessionArbiter.canonicalSOAIdentifier(attackerControlledIdentifier),
        canonicalUUID
      )
      XCTAssertNotEqual(
        PeerSessionArbiter.soaPeerId(from: attackerControlledIdentifier),
        exactPeerId
      )
    }
  }

  func testPeerSessionArbiterAllowlistedExactUUIDAliasesRemainCanonical() {
    let uppercaseUUID = "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"
    let canonicalUUID = uppercaseUUID.lowercased()
    let canonicalPeerId = PeerSessionArbiter.soaPeerId(from: canonicalUUID)

    for alias in [
      uppercaseUUID,
      "id:\(uppercaseUUID)",
      "recent:id:\(uppercaseUUID)",
      "recent:mac:id:\(uppercaseUUID)",
    ] {
      XCTAssertEqual(PeerSessionArbiter.canonicalSOAIdentifier(alias), canonicalUUID)
      XCTAssertEqual(PeerSessionArbiter.soaPeerId(from: alias), canonicalPeerId)
    }
  }

  func testNWConnectionTransportRejectsStaleAndUnboundSequencedAccess() async throws {
    let transport = NWConnectionTransport()
    let firstConnection = makeUnstartedHandshakeTestConnection(port: 9)
    let replacementConnection = makeUnstartedHandshakeTestConnection(port: 10)
    let conflictingConnection = makeUnstartedHandshakeTestConnection(port: 11)

    let installedFirst = await transport.setConnection(
      firstConnection,
      for: "peer",
      leaseSequence: 1
    )
    XCTAssertTrue(installedFirst)
    let firstCapability = try await transport.boundTransport(
      for: "peer",
      expectedConnection: firstConnection,
      leaseSequence: 1
    )

    let installedReplacement = await transport.setConnection(
      replacementConnection,
      for: "peer",
      leaseSequence: 2
    )
    let staleSequenceAccepted = await transport.setConnection(
      firstConnection,
      for: "peer",
      leaseSequence: 1
    )
    let conflictingSocketAccepted = await transport.setConnection(
      conflictingConnection,
      for: "peer",
      leaseSequence: 2
    )
    let legacyOverwriteAccepted = await transport.setConnection(firstConnection, for: "peer")
    XCTAssertTrue(installedReplacement)
    XCTAssertFalse(staleSequenceAccepted)
    XCTAssertFalse(conflictingSocketAccepted)
    XCTAssertFalse(legacyOverwriteAccepted)

    do {
      try await firstCapability.send(
        to: PeerIdentifier(deviceId: "peer"),
        data: Data([0x01])
      )
      XCTFail("Stale capability unexpectedly sent through replacement socket")
    } catch let error as NWConnectionTransportBindingError {
      XCTAssertEqual(error, .staleBinding)
    }

    do {
      try await transport.send(
        to: PeerIdentifier(deviceId: "peer"),
        data: Data([0x02])
      )
      XCTFail("Shared transport unexpectedly accessed a sequenced binding")
    } catch let error as NWConnectionTransportBindingError {
      XCTAssertEqual(error, .boundCapabilityRequired)
    }

    _ = try await transport.boundTransport(
      for: "peer",
      expectedConnection: replacementConnection,
      leaseSequence: 2
    )
    let socketOnlyRemovalSucceeded = await transport.removeConnection(
      replacementConnection,
      for: "peer"
    )
    let staleRemovalSucceeded = await transport.removeConnection(
      firstConnection,
      for: "peer",
      leaseSequence: 1
    )
    let replacementRemovalSucceeded = await transport.removeConnection(
      replacementConnection,
      for: "peer",
      leaseSequence: 2
    )
    XCTAssertFalse(socketOnlyRemovalSucceeded)
    XCTAssertFalse(staleRemovalSucceeded)
    XCTAssertTrue(replacementRemovalSucceeded)
  }

  func testHandshakeDriverWithExactTransportCannotBorrowReplacementSocket() async throws {
    let transport = NWConnectionTransport()
    let firstConnection = makeUnstartedHandshakeTestConnection(port: 12)
    let replacementConnection = makeUnstartedHandshakeTestConnection(port: 13)
    let installedFirst = await transport.setConnection(
      firstConnection,
      for: "mac-peer",
      leaseSequence: 1
    )
    XCTAssertTrue(installedFirst)
    let firstCapability = try await transport.boundTransport(
      for: "mac-peer",
      expectedConnection: firstConnection,
      leaseSequence: 1
    )
    let installedReplacement = await transport.setConnection(
      replacementConnection,
      for: "mac-peer",
      leaseSequence: 2
    )
    XCTAssertTrue(installedReplacement)

    let signatureProvider = LocalHandshakeTestSignatureProvider()
    let driver = HandshakeDriver(
      transport: firstCapability,
      cryptoProvider: LocalHandshakeTestCryptoProvider(
        tier: .classic,
        activeSuite: .x25519Ed25519,
        supportedSuites: [.x25519Ed25519]
      ),
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: .callback(FixedSignatureCallback(signature: Data([0xAA]))),
      sigAAlgorithm: signatureProvider.signatureAlgorithm,
      protocolSigningKeyProtection: .softwareKeychain,
      identityPublicKey: Data(repeating: 0x10, count: 1_952)
    )

    await XCTAssertThrowsErrorAsync(
      try await driver.initiateHandshake(with: PeerIdentifier(deviceId: "mac-peer"))
    ) { error in
      guard let handshakeError = error as? HandshakeError,
        case .failed(.transportError(let reason)) = handshakeError
      else {
        XCTFail("Unexpected error: \(error)")
        return
      }
      XCTAssertEqual(
        reason,
        NWConnectionTransportBindingError.staleBinding.localizedDescription
      )
    }

    _ = try await transport.boundTransport(
      for: "mac-peer",
      expectedConnection: replacementConnection,
      leaseSequence: 2
    )
  }

  func testHandshakeCancellationDuringOutboundTrustPreflightReleasesExactArbiterAttempt()
    async throws
  {
    let transport = CaptureOnlyDiscoveryTransport()
    let trustProvider = SuspendedKEMLookupHandshakeTrustProvider()
    let arbiter = PeerSessionArbiter()
    let localSOAPeerId = Data(
      repeating: 0x31,
      count: HandshakeSOAExtension.initiatorPeerIdLength
    )
    let remoteSOAPeerId = Data(
      repeating: 0x32,
      count: HandshakeSOAExtension.targetPeerIdLength
    )
    let attemptId = Data(repeating: 0x33, count: HandshakeSOAExtension.attemptIdLength)
    let pairKey = PeerSessionArbiter.pairKey(
      localPeerId: localSOAPeerId,
      remotePeerId: remoteSOAPeerId
    )
    let signatureProvider = LocalHandshakeTestSignatureProvider()
    let driver = HandshakeDriver(
      transport: transport,
      cryptoProvider: LocalHandshakeTestCryptoProvider(
        tier: .classic,
        activeSuite: .x25519Ed25519,
        supportedSuites: [.x25519Ed25519]
      ),
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: .callback(FixedSignatureCallback(signature: Data([0x34]))),
      sigAAlgorithm: signatureProvider.signatureAlgorithm,
      protocolSigningKeyProtection: .softwareKeychain,
      identityPublicKey: Data(repeating: 0x35, count: 1_952),
      trustProvider: trustProvider,
      soaMetadata: try HandshakeSOAMetadata(
        initiatorPeerId: localSOAPeerId,
        targetPeerId: remoteSOAPeerId,
        attemptId: attemptId
      ),
      localSOAPeerId: localSOAPeerId,
      expectedRemoteSOAPeerId: remoteSOAPeerId,
      sessionArbiter: arbiter
    )

    let handshakeTask = Task {
      try await driver.initiateHandshake(with: PeerIdentifier(deviceId: "remote-peer"))
    }
    await trustProvider.waitUntilKEMLookupStarts()
    guard case .sendingMessageA = await driver.getCurrentState() else {
      XCTFail("Outbound preflight must be observable as an in-flight handshake")
      await trustProvider.resumeKEMLookup()
      return
    }

    await driver.cancel()
    await trustProvider.resumeKEMLookup()
    await XCTAssertThrowsErrorAsync(try await handshakeTask.value) { error in
      guard let handshakeError = error as? HandshakeError,
        case .failed(.cancelled) = handshakeError
      else {
        XCTFail("Expected exact cancellation, got \(error)")
        return
      }
    }
    let capturedFrame = await transport.latestFrame()
    XCTAssertNil(capturedFrame, "A cancelled preflight must never send MessageA")

    let replacementAttemptId = Data(
      repeating: 0x36,
      count: HandshakeSOAExtension.attemptIdLength
    )
    let replacementDecision = await arbiter.registerOutgoing(.init(
      pairKey: pairKey,
      initiatorPeerId: localSOAPeerId,
      attemptId: replacementAttemptId,
      startedAt: Date(),
      onSuperseded: { _, _ in }
    ))
    guard case .accepted(let replacementReservation) = replacementDecision else {
      XCTFail("Cancelled preflight leaked its exact outgoing arbiter reservation")
      return
    }
    let replacementCleanupSucceeded = await arbiter.clearOutgoing(replacementReservation)
    XCTAssertTrue(replacementCleanupSucceeded)
  }

  func testHandshakeEarlyFinishedWhileMessageASendIsSuspendedReturnsAuthenticatedSuccess()
    async throws
  {
    func verifyEarlyFinished(failFirstSendOnResume: Bool) async throws {
    let transport = SuspendedFirstSendDiscoveryTransport(
      failFirstSendOnResume: failFirstSendOnResume
    )
    let signatureProvider = LocalHandshakeTestSignatureProvider()
    let cryptoProvider = LocalHandshakeTestCryptoProvider(
      tier: .classic,
      activeSuite: .x25519Ed25519,
      supportedSuites: [.x25519Ed25519]
    )
    let driver = HandshakeDriver(
      transport: transport,
      cryptoProvider: cryptoProvider,
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: .callback(FixedSignatureCallback(signature: Data([0x41]))),
      sigAAlgorithm: signatureProvider.signatureAlgorithm,
      protocolSigningKeyProtection: .softwareKeychain,
      identityPublicKey: Data(repeating: 0x42, count: 1_952)
    )
    let handshakeTask = Task {
      try await driver.initiateHandshake(with: PeerIdentifier(deviceId: "remote-peer"))
    }
    let messageAFrame = await transport.waitForFirstFrame()
    let messageA = try HandshakeMessageA.decode(
      from: HandshakePadding.unwrapIfNeeded(messageAFrame, label: "test/early-finished")
    )

    let responder = HandshakeContext(
      role: .responder,
      cryptoProvider: cryptoProvider,
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: .callback(FixedSignatureCallback(signature: Data([0x43]))),
      identityPublicKey: Data(repeating: 0x44, count: 1_952),
      policy: .default
    )
    try await responder.processMessageA(messageA)
    let response = try await responder.buildMessageB()
    defer { response.sharedSecret.zeroize() }
    await driver.handleMessage(
      response.message.encoded,
      from: PeerIdentifier(deviceId: "remote-peer")
    )
    guard case .waitingFinished(_, let sessionKeys, _) = await driver.getCurrentState() else {
      XCTFail("MessageB did not advance the suspended outbound send to waitingFinished")
      await transport.resumeFirstSend()
      await responder.zeroize()
      return
    }

    await driver.handleMessage(
      LocalHandshakeFinishedHelper.responderFinished(for: sessionKeys).encoded,
      from: PeerIdentifier(deviceId: "remote-peer")
    )
    guard case .established = await driver.getCurrentState() else {
      XCTFail("Authenticated Finished did not establish before MessageA send returned")
      await transport.resumeFirstSend()
      await responder.zeroize()
      return
    }

    await transport.resumeFirstSend()
    let establishedKeys = try await handshakeTask.value
    XCTAssertEqual(establishedKeys.sessionId, sessionKeys.sessionId)
    XCTAssertEqual(establishedKeys.negotiatedSuite, .x25519Ed25519)
    await responder.zeroize()
    }

    try await verifyEarlyFinished(failFirstSendOnResume: false)
    try await verifyEarlyFinished(failFirstSendOnResume: true)
  }

  func testPeerSessionArbiterExactCleanupCannotDeleteSameAttemptReplacement() async {
    let arbiter = PeerSessionArbiter()
    let localPeerId = Data(
      repeating: 0x51,
      count: HandshakeSOAExtension.initiatorPeerIdLength
    )
    let remotePeerId = Data(
      repeating: 0x52,
      count: HandshakeSOAExtension.targetPeerIdLength
    )
    let pairKey = PeerSessionArbiter.pairKey(
      localPeerId: localPeerId,
      remotePeerId: remotePeerId
    )
    let reusedAttemptId = Data(
      repeating: 0x53,
      count: HandshakeSOAExtension.attemptIdLength
    )
    let staleDecision = await arbiter.registerOutgoing(.init(
      pairKey: pairKey,
      initiatorPeerId: localPeerId,
      attemptId: reusedAttemptId,
      startedAt: Date(timeIntervalSinceNow: -11),
      onSuperseded: { _, _ in }
    ))
    guard case .accepted(let staleReservation) = staleDecision else {
      XCTFail("Failed to create stale reservation fixture")
      return
    }
    let replacementDecision = await arbiter.registerOutgoing(.init(
      pairKey: pairKey,
      initiatorPeerId: localPeerId,
      attemptId: reusedAttemptId,
      startedAt: Date(),
      onSuperseded: { _, _ in }
    ))
    guard case .accepted(let replacementReservation) = replacementDecision else {
      XCTFail("Expired registration did not admit an exact replacement")
      return
    }

    let staleCleanupSucceeded = await arbiter.clearOutgoing(staleReservation)
    XCTAssertFalse(staleCleanupSucceeded)
    let blockedDecision = await arbiter.registerOutgoing(.init(
      pairKey: pairKey,
      initiatorPeerId: localPeerId,
      attemptId: Data(repeating: 0x54, count: HandshakeSOAExtension.attemptIdLength),
      startedAt: Date(),
      onSuperseded: { _, _ in }
    ))
    guard case .alreadyInProgress = blockedDecision else {
      XCTFail("Stale exact cleanup deleted the same-attempt replacement")
      return
    }
    let replacementCleanupSucceeded = await arbiter.clearOutgoing(replacementReservation)
    XCTAssertTrue(replacementCleanupSucceeded)
  }

  func testLANRemoteDesktopRetainsAndClearsExactArbiterLease() throws {
    let source = try remoteDesktopManagerSource()

    XCTAssertTrue(
      source.contains(
        "private var lanEstablishedArbiterLease: PeerSessionArbiter.EstablishedLease?"
      )
    )
    XCTAssertTrue(source.contains("try await captureLANEstablishedArbiterLease("))
    XCTAssertTrue(
      source.contains(
        "PeerSessionArbiter.shared.clearEstablished(closingArbiterLease)"
      )
    )
    XCTAssertFalse(source.contains("clearEstablished(pairKey: lanSOAPairKey)"))
    XCTAssertFalse(source.contains("clearOutgoing(pairKey: lanSOAPairKey, attemptId: nil)"))
  }

  func testLocalHandshakeContextRetainsValidatedResponderCapabilities() async throws {
    let signatureProvider = LocalHandshakeTestSignatureProvider()
    let provider = LocalHandshakeTestCryptoProvider(
      tier: .classic,
      activeSuite: .x25519Ed25519,
      supportedSuites: [.x25519Ed25519]
    )
    let initiator = HandshakeContext(
      role: .initiator,
      cryptoProvider: provider,
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: .callback(FixedSignatureCallback(signature: Data([0xA1]))),
      identityPublicKey: Data(repeating: 0x01, count: 1_952),
      policy: .default
    )
    let responder = HandshakeContext(
      role: .responder,
      cryptoProvider: provider,
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: .callback(FixedSignatureCallback(signature: Data([0xB1]))),
      identityPublicKey: Data(repeating: 0x05, count: 1_952),
      policy: .default
    )

    let messageA = try await initiator.buildMessageA()
    let suiteBeforeMessageB = await initiator.negotiatedSuite
    XCTAssertNil(
      suiteBeforeMessageB,
      "An offered suite must not be published as negotiated before MessageB validation"
    )
    try await responder.processMessageA(messageA)
    let response = try await responder.buildMessageB()
    defer { response.sharedSecret.zeroize() }
    // Exercise nested Data slices produced by the real wire decoder. Their
    // startIndex is not guaranteed to be zero.
    let decodedMessageB = try HandshakeMessageB.decode(from: response.message.encoded)
    _ = try await initiator.processMessageB(decodedMessageB)

    let capabilities = await initiator.peerCapabilities
    XCTAssertTrue(capabilities?.supportedKEM.contains("X25519") == true)
    XCTAssertTrue(capabilities?.supportedAuthProfiles.contains("Classic") == true)
    await initiator.zeroize()
    await responder.zeroize()
  }

  func testLocalHandshakeContextRejectsResponderCapabilitiesThatContradictSelectedSuite()
    async throws
  {
    let signatureProvider = LocalHandshakeTestSignatureProvider()
    let provider = LocalHandshakeTestCryptoProvider(
      tier: .classic,
      activeSuite: .x25519Ed25519,
      supportedSuites: [.x25519Ed25519]
    )
    let initiator = HandshakeContext(
      role: .initiator,
      cryptoProvider: provider,
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: .callback(FixedSignatureCallback(signature: Data([0xA2]))),
      identityPublicKey: Data(repeating: 0x11, count: 1_952),
      policy: .default
    )
    _ = try await initiator.buildMessageA()

    let contradictoryCapabilities = CryptoCapabilities(
      supportedKEM: ["ML-KEM-768"],
      supportedSignature: ["Ed25519"],
      supportedAuthProfiles: ["Classic"],
      supportedAEAD: ["AES-256-GCM"],
      pqcAvailable: false,
      platformVersion: "iOS 26.0",
      providerType: .classic
    )
    let encapsulatedKey = Data(repeating: 0x31, count: 32)
    let sealedBox = HPKESealedBox(
      encapsulatedKey: encapsulatedKey,
      ciphertext: try contradictoryCapabilities.deterministicEncode(),
      tag: Data(repeating: 0x32, count: 16),
      nonce: Data(repeating: 0x33, count: 12)
    )
    let responderIdentity = IdentityPublicKeys(
      protocolPublicKey: Data(repeating: 0x21, count: 1_952),
      protocolAlgorithm: signatureProvider.signatureAlgorithm.wire,
      secureEnclavePublicKey: nil
    )
    let messageB = HandshakeMessageB(
      selectedSuite: .x25519Ed25519,
      responderShare: encapsulatedKey,
      serverNonce: Data(repeating: 0x34, count: HandshakeConstants.nonceSize),
      encryptedPayload: sealedBox,
      signature: Data([0x35]),
      identityPublicKeys: responderIdentity
    )

    do {
      _ = try await initiator.processMessageB(messageB)
      XCTFail("Authenticated capabilities that omit the selected KEM must fail closed")
    } catch let HandshakeError.failed(reason) {
      guard case .invalidMessageFormat(let message) = reason else {
        XCTFail("Expected invalidMessageFormat, got \(reason)")
        return
      }
      XCTAssertTrue(message.contains("Responder capabilities do not match MessageB"))
    }
    let acceptedCapabilities = await initiator.peerCapabilities
    XCTAssertNil(acceptedCapabilities)
    let acceptedAuthority = await initiator.getAuthenticatedRemoteAuthority()
    XCTAssertNil(acceptedAuthority)
    let isZeroized = await initiator.isZeroized
    let negotiatedSuite = await initiator.negotiatedSuite
    XCTAssertTrue(isZeroized)
    XCTAssertNil(negotiatedSuite)
    await initiator.zeroize()
  }

  func testHandshakeDriverClearsAuthenticatedAuthorityAfterCancellation() async throws {
    let provider = LocalHandshakeTestCryptoProvider(
      tier: .classic,
      activeSuite: .x25519Ed25519,
      supportedSuites: [.x25519Ed25519]
    )
    let signatureProvider = LocalHandshakeTestSignatureProvider()
    let initiatorIdentity = Data(repeating: 0x01, count: 1_952)
    let responderIdentity = Data(repeating: 0x89, count: 1_952)
    let transport = CaptureOnlyDiscoveryTransport()
    let initiator = HandshakeDriver(
      transport: transport,
      cryptoProvider: provider,
      protocolSignatureProvider: signatureProvider,
      identityKeyHandle: SigningKeyHandle.callback(FixedSignatureCallback(signature: Data([0xCC]))),
      sigAAlgorithm: .mlDSA65,
      protocolSigningKeyProtection: .softwareKeychain,
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
    let bindingBeforeCancel = await initiator.getAuthenticatedHandshakePeerBinding()
    XCTAssertNil(authorityBeforeCancel)
    XCTAssertNil(bindingBeforeCancel)

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
    XCTAssertTrue(
      bootstrapFilter.contains(
        "lastRekey_ref=\\(SkyBridgeDiagnosticReference.stableReference(lastRekeyEvent))"))
    XCTAssertFalse(bootstrapFilter.contains("lastRekey=\\(lastRekeyEvent ?? \"-\")"))
    XCTAssertTrue(bootstrapFilter.contains("ignored non-bootstrap app message"))
  }

  func testStrictBootstrapOnlyDropsMediaPayloadsBeforePQCRekey() throws {
    let source = try crossNetworkWebRTCManagerSource()
    let highThroughputPublisher = try sourceSlice(
      from: "private func publishHighThroughputRemoteDesktopPayloadIfCurrent",
      to: "private func handleDecodedControlPlaintext(",
      in: source
    )
    let receiveLoopProbe = try sourceSlice(
      from: "let openedPayload = try await decrypt(ciphertext: trafficUnwrapped, with: keys)",
      to: "self.appendSmokeTrace(\"rx frame len=\\(length) keys=false\")",
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
    let admissionGate = try XCTUnwrap(
      livenessWatchdog.range(of: "if !self.isPairingMaterialAdmitted("))
    let strictBootstrapDefer = try XCTUnwrap(
      livenessWatchdog.range(
        of: "if self.strictPQCClassicBootstrapOnlySessionIds.contains(sessionId)"))
    let normalActivityDeadline = try XCTUnwrap(
      livenessWatchdog.range(of: "Date().timeIntervalSince(lastActivityAt) > timeoutSeconds"))
    XCTAssertLessThan(admissionGate.lowerBound, strictBootstrapDefer.lowerBound)
    XCTAssertLessThan(strictBootstrapDefer.lowerBound, normalActivityDeadline.lowerBound)
    XCTAssertTrue(livenessWatchdog.contains("pairing_material_admission_timeout"))
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
    XCTAssertTrue(source.contains("private var lanEstablishedArbiterLease: PeerSessionArbiter.EstablishedLease?"))
    XCTAssertTrue(source.contains("private var pendingConnectionTarget: DiscoveredDevice?"))
    XCTAssertTrue(clearBody.contains("let closingArbiterLease = lanEstablishedArbiterLease"))
    XCTAssertTrue(clearBody.contains("PeerSessionArbiter.shared.clearEstablished(closingArbiterLease)"))
    XCTAssertFalse(clearBody.contains("PeerSessionArbiter.shared.clearOutgoing"))
    XCTAssertTrue(clearBody.contains("lanSOAPairKey = nil"))
    XCTAssertTrue(handshakeBody.contains("PeerSessionArbiter.pairKey"))
    XCTAssertTrue(handshakeBody.contains("lanSOAPairKey = pairKey"))
    XCTAssertTrue(handshakeBody.contains("captureLANEstablishedArbiterLease("))
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
    XCTAssertTrue(source.contains("var soaEstablishedLease: PeerSessionArbiter.EstablishedLease?"))
    XCTAssertTrue(source.contains("recordSOAState(soaPairKey, for: peer)"))
    XCTAssertTrue(source.contains("releaseStaleSOAStateBeforeHandshake(for: peer)"))
    XCTAssertTrue(source.contains("releaseSOAState(for: previousPeer)"))
    XCTAssertTrue(source.contains("releaseSOAState(for: peer)"))
    XCTAssertTrue(source.contains("PeerSessionArbiter.shared.clearEstablished"))
    XCTAssertFalse(source.contains("PeerSessionArbiter.shared.clearOutgoing"))
    XCTAssertTrue(source.contains("lease.pairKey == pairKey"))
    XCTAssertTrue(source.contains("lease.sessionId == sessionKeys.sessionId"))
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

private struct WaitingFinishedSOAHandshakeFixture {
  let initiator: HandshakeDriver
  let handshakeTask: Task<SessionKeys, Error>
  let sessionKeys: SessionKeys
  let signatureProvider: LocalHandshakeTestSignatureProvider
  let responderIdentity: Data
  let arbiter: PeerSessionArbiter
  let localSOAPeerId: Data
  let remoteSOAPeerId: Data
  let pairKey: Data
  let attemptId: Data
}

private func makeWaitingFinishedSOAHandshake(
  suspendEstablishmentCommit: Bool = false
) async throws -> WaitingFinishedSOAHandshakeFixture {
  let signatureProvider = LocalHandshakeTestSignatureProvider()
  let provider = LocalHandshakeTestCryptoProvider(
    tier: .classic,
    activeSuite: .x25519Ed25519,
    supportedSuites: [.x25519Ed25519]
  )
  let initiatorIdentity = Data(repeating: 0x10, count: 1_952)
  let responderIdentity = Data(repeating: 0x50, count: 1_952)
  let transport = CaptureOnlyDiscoveryTransport()
  let localSOAPeerId = PeerSessionArbiter.soaPeerId(
    from: "id:11111111-2222-4333-8444-555555555555")
  let remoteSOAPeerId = PeerSessionArbiter.soaPeerId(
    from: "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
  let arbiter = PeerSessionArbiter()
  let attemptId = Data(repeating: 0x42, count: HandshakeSOAExtension.attemptIdLength)
  if suspendEstablishmentCommit {
    try await arbiter.testOnlySuspendEstablishmentCommit(attemptId: attemptId)
  }
  let initiator = HandshakeDriver(
    transport: transport,
    cryptoProvider: provider,
    protocolSignatureProvider: signatureProvider,
    identityKeyHandle: SigningKeyHandle.callback(
      FixedSignatureCallback(signature: Data([0xAA]))),
    sigAAlgorithm: .mlDSA65,
    protocolSigningKeyProtection: .softwareKeychain,
    identityPublicKey: initiatorIdentity,
    soaMetadata: try HandshakeSOAMetadata(
      initiatorPeerId: localSOAPeerId,
      targetPeerId: remoteSOAPeerId,
      attemptId: attemptId
    ),
    localSOAPeerId: localSOAPeerId,
    expectedRemoteSOAPeerId: remoteSOAPeerId,
    sessionArbiter: arbiter
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
    identityKeyHandle: SigningKeyHandle.callback(
      FixedSignatureCallback(signature: Data([0xBB]))),
    identityPublicKey: responderIdentity,
    policy: .default,
    cryptoPolicy: .default
  )
  try await responderContext.processMessageA(messageA)
  let (messageB, _) = try await responderContext.buildMessageB()
  await responderContext.zeroize()
  await initiator.handleMessage(
    messageB.encoded,
    from: PeerIdentifier(deviceId: "mac-peer")
  )

  guard case .waitingFinished(_, let sessionKeys, let expectingFrom) =
    await initiator.getCurrentState(),
    expectingFrom == .responder else {
    throw LocalHandshakeTestError.unexpectedState
  }
  return WaitingFinishedSOAHandshakeFixture(
    initiator: initiator,
    handshakeTask: handshakeTask,
    sessionKeys: sessionKeys,
    signatureProvider: signatureProvider,
    responderIdentity: responderIdentity,
    arbiter: arbiter,
    localSOAPeerId: localSOAPeerId,
    remoteSOAPeerId: remoteSOAPeerId,
    pairKey: PeerSessionArbiter.pairKey(
      localPeerId: localSOAPeerId,
      remotePeerId: remoteSOAPeerId
    ),
    attemptId: attemptId
  )
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
      protocolPublicKeyFingerprint: try identityKeys.authoritativeProtocolFingerprint().lowercased(),
      protocolPublicKeyBytes: identityKeys.protocolPublicKey
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

@available(iOS 17.0, *)
private actor SuspendedFirstSendDiscoveryTransport: DiscoveryTransport {
  private let failFirstSendOnResume: Bool
  private var sendCount = 0
  private var firstFrame: Data?
  private var firstFrameWaiters: [CheckedContinuation<Data, Never>] = []
  private var firstSendContinuation: CheckedContinuation<Void, Error>?

  init(failFirstSendOnResume: Bool) {
    self.failFirstSendOnResume = failFirstSendOnResume
  }

  func send(to peer: PeerIdentifier, data: Data) async throws {
    _ = peer
    sendCount += 1
    guard sendCount == 1 else { return }

    firstFrame = data
    let waiters = firstFrameWaiters
    firstFrameWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: data)
    }
    try await withCheckedThrowingContinuation { continuation in
      precondition(firstSendContinuation == nil, "Only the first send may be suspended")
      firstSendContinuation = continuation
    }
  }

  func waitForFirstFrame() async -> Data {
    if let firstFrame { return firstFrame }
    return await withCheckedContinuation { continuation in
      firstFrameWaiters.append(continuation)
    }
  }

  func resumeFirstSend() {
    let continuation = firstSendContinuation
    firstSendContinuation = nil
    if failFirstSendOnResume {
      continuation?.resume(throwing: NSError(
        domain: "SkyBridge.HandshakeEarlyFinishedTest",
        code: 1
      ))
    } else {
      continuation?.resume()
    }
  }
}

@available(iOS 17.0, *)
private actor SuspendedKEMLookupHandshakeTrustProvider: HandshakeTrustProvider {
  private var lookupStarted = false
  private var lookupStartedWaiters: [CheckedContinuation<Void, Never>] = []
  private var lookupContinuation: CheckedContinuation<Void, Never>?

  func trustedFingerprint(for deviceId: String) async -> String? {
    _ = deviceId
    return nil
  }

  func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
    _ = deviceId
    lookupStarted = true
    let waiters = lookupStartedWaiters
    lookupStartedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      precondition(lookupContinuation == nil, "Only one KEM lookup may be suspended")
      lookupContinuation = continuation
    }
    return [:]
  }

  func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
    _ = deviceId
    return nil
  }

  func waitUntilKEMLookupStarts() async {
    guard !lookupStarted else { return }
    await withCheckedContinuation { continuation in
      lookupStartedWaiters.append(continuation)
    }
  }

  func resumeKEMLookup() {
    let continuation = lookupContinuation
    lookupContinuation = nil
    continuation?.resume()
  }
}

private func makeUnstartedHandshakeTestConnection(port: UInt16) -> NWConnection {
  guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
    preconditionFailure("Test port must be valid")
  }
  return NWConnection(
    host: NWEndpoint.Host("127.0.0.1"),
    port: endpointPort,
    using: .tcp
  )
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
  case unexpectedState
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
