import XCTest

@available(iOS 17.0, *)
extension RegressionHardeningTests {
  func remoteDesktopManagerSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func p2pConnectionManagerSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func liveActivityManagerSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/LiveActivityManager.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func iosFileTransferNetworkServiceSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/FileTransfer/FileTransferNetworkService.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopRuntimeModelsSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopManagerRuntimeModels.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopViewerStreamConfigurationFactorySource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopViewerStreamConfigurationFactory.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopViewerStreamConfigurationPushPolicySource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopViewerStreamConfigurationPushPolicy.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopLANEndpointCandidateFactorySource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopLANEndpointCandidateFactory.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopDeviceResolutionCoordinatorSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopDeviceResolutionCoordinator.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopTypesSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopTypes.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopPresentationTypesSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopPresentationTypes.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopScreenFrameWireSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopScreenFrameWire.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopLANSecureReceivePipelineSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopLANSecureReceivePipeline.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopLANHandshakeTrustSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopLANHandshakeTrust.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopLANRoutePolicySource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopLANRoutePolicy.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopVideoDecoderSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopVideoDecoder.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func realtimeMediaAudioSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/RealtimeMediaAudio.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopSmokeCadenceTrackerSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/RemoteDesktop/RemoteDesktopSmokeCadenceTracker.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func crossNetworkWebRTCManagerSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func crossNetworkWebRTCFileTransferSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager+FileTransfer.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func crossNetworkFileTransferIntegritySource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkFileTransferIntegrity.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func crossNetworkWebRTCManagerTestSupportSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOSTests/CrossNetworkWebRTCManager+TestSupport.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func crossNetworkWebRTCInboundFileTransferSupportSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCInboundFileTransferSupport.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func crossNetworkSignalServerClientSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func crossNetworkServerConfigSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkServerConfig.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func smokeTraceWriterSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Utilities/SkyBridgeSmokeTraceWriter.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func skyBridgeCompassAppSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcePaths = [
      "SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift",
      "SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift",
      "SkyBridgeCompassiOS/Sources/App/Smoke/SmokeSupport.swift",
      "SkyBridgeCompassiOS/Sources/App/Smoke/LocalWebRTCSmokeHarness.swift",
      "SkyBridgeCompassiOS/Sources/App/Smoke/SmokeStatusReporter.swift",
    ]
    return try sourcePaths.map { path in
      try readRepositorySource(at: root.appendingPathComponent(path))
    }.joined(separator: "\n")
  }

  func iosFileTransferManagerSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcePaths = [
      "SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift",
      "SkyBridgeCompassiOS/Sources/Managers/FileTransfer/FileTransferWireTypes.swift",
      "SkyBridgeCompassiOS/Sources/Managers/FileTransfer/FileTransferDeviceResolution.swift",
    ]
    return try sourcePaths.map { path in
      try readRepositorySource(at: root.appendingPathComponent(path))
    }.joined(separator: "\n")
  }

  func iosFileTransferLANRoutePolicySource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/FileTransfer/FileTransferLANRoutePolicy.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func authenticationManagerSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(
      "SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift"
    )
    return try readRepositorySource(at: sourceURL)
  }

  func remoteDesktopViewSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcePaths = [
      "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopView.swift",
      "SkyBridgeCompassiOS/Sources/Views/RemoteDesktopRTCVideoView.swift",
    ]
    return try sourcePaths.map { path in
      try readRepositorySource(at: root.appendingPathComponent(path))
    }.joined(separator: "\n")
  }

  func repositoryScriptSource(_ relativePath: String) throws -> String {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repoRoot.appendingPathComponent(relativePath)
    return try readRepositorySource(at: sourceURL)
  }

  func webRTCSessionSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcePaths = [
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift",
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession+SDP.swift",
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSessionLifecycleSupport.swift",
      "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSessionRemoteVideoStats.swift",
    ]
    return try sourcePaths.map { path in
      try readRepositorySource(at: root.appendingPathComponent(path))
    }.joined(separator: "\n")
  }

  func readRepositorySource(at sourceURL: URL) throws -> String {
    if FileManager.default.fileExists(atPath: sourceURL.path) {
      return try String(contentsOf: sourceURL, encoding: .utf8)
    }
    #if os(iOS) && !targetEnvironment(simulator)
      throw XCTSkip(
        "Repository source files are not mounted inside the physical-device test sandbox; run source-shape regression tests on macOS or iOS Simulator."
      )
    #else
      return try String(contentsOf: sourceURL, encoding: .utf8)
    #endif
  }

  func sourceSlice(from startMarker: String, to endMarker: String, in source: String) throws
    -> String
  {
    let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
    let suffix = source[start...]
    let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
    return String(suffix[..<end])
  }
}
