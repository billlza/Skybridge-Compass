import Foundation
import SkyBridgeProtocolCore
import XCTest

@testable import SkyBridgeCompass_iOS

/// iOS 账号设备心跳/列表：控制端专用的上报形状、失败映射、生命周期，以及"共享实现不分叉"的源码契约。
@MainActor
final class AccountPresenceServiceTests: XCTestCase {
  private func identity(platform: DevicePlatform, name: String = "Ziang的iPad") -> AppleMobileDeviceIdentity.Snapshot {
    AppleMobileDeviceIdentity.Snapshot(
      vendorDeviceId: nil,
      deviceName: name,
      platform: platform,
      platformName: platform.displayName,
      osVersion: "26.6",
      modelIdentifier: "iPad16,3",
      modelName: "iPad Pro 11-inch (M4)",
      chip: "Apple M4"
    )
  }

  func testReportNeverAdvertisesRemoteDesktopHostingAndMapsThePlatform() throws {
    let ipad = try IOSDevicePresenceReportBuilder.makeReport(
      identity: identity(platform: .iPadOS),
      lanAddresses: ["fe80::1%en0", "192.168.1.20", "127.0.0.1", "192.168.1.20", "fd12::1"]
    )
    XCTAssertEqual(ipad.platform, .iPadOS)
    XCTAssertEqual(ipad.deviceName, "Ziang的iPad")
    XCTAssertEqual(ipad.deviceModel, "iPad Pro 11-inch (M4)")
    XCTAssertEqual(ipad.osVersion, "26.6")
    XCTAssertEqual(ipad.lanAddresses, ["192.168.1.20", "fd12::1"])
    XCTAssertEqual(ipad.capabilities, ["clipboard", "file_transfer"])
    XCTAssertFalse(ipad.capabilities.contains(AccountDeviceCapability.remoteDesktop.rawValue), "iOS is control-only")

    let iphone = try IOSDevicePresenceReportBuilder.makeReport(identity: identity(platform: .iOS), lanAddresses: [])
    XCTAssertEqual(iphone.platform, .iOS)
    XCTAssertEqual(iphone.lanAddresses, [])

    let capped = try IOSDevicePresenceReportBuilder.makeReport(
      identity: identity(platform: .iOS),
      lanAddresses: (1...12).map { "10.0.0.\($0)" }
    )
    XCTAssertEqual(capped.lanAddresses.count, AccountDevicePresenceReport.maximumLANAddresses)
  }

  func testLocalNetworkInspectorOnlyReturnsRoutableAddressesWithNetworkTypes() {
    for entry in LocalNetworkAddressInspector.routableAddresses() {
      XCTAssertTrue(LANAddressRoutabilityPolicy.isAdvertisableRoutableLANAddress(entry.address), entry.address)
      XCTAssertFalse(entry.address.hasPrefix("169.254."))
      XCTAssertFalse(entry.address.hasPrefix("127."))
      XCTAssertFalse(entry.address.contains("%"))
      XCTAssertTrue(["wifi", "cellular", "unknown"].contains(entry.networkType))
    }
    XCTAssertEqual(LocalNetworkAddressInspector.networkType(for: "pdp_ip0"), "cellular")
    XCTAssertEqual(LocalNetworkAddressInspector.networkType(for: "en0"), "wifi")
    XCTAssertEqual(LocalNetworkAddressInspector.networkType(for: "awdl0"), "wifi")
    XCTAssertEqual(LocalNetworkAddressInspector.networkType(for: "en5"), "unknown")
  }

  func testClientErrorsMapToSharedPresenceFailures() {
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.serverRejected(403, #"{"bodyBytes":30,"error":"device_frozen"}"#)),
      .deviceNotActive(code: "device_frozen")
    )
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.serverRejected(503, #"{"bodyBytes":30,"error":"registry_not_configured"}"#)),
      .registryUnavailable(code: "registry_not_configured")
    )
    XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.serverRejected(429, "<redacted-server-error-body> bytes=0")), .rateLimited)
    // 只有"确实没有会话"才是未登录。
    XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.missingAuthentication), .notAuthenticated)
    XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.missingTenantID), .notAuthenticated)
    XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.authenticationSessionChanged), .notAuthenticated)
    // 本地钥匙串/声明校验故障不是"未登录"：渲染成登录引导会让用户反复重新登录也无效。
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.tenantIdentityMismatch),
      .localAuthenticationUnavailable(code: "tenant_identity_mismatch")
    )
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.authenticationStorageUnavailable("keychain")),
      .localAuthenticationUnavailable(code: "authentication_storage_unavailable")
    )
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.invalidAuthenticationClaims),
      .localAuthenticationUnavailable(code: "invalid_authentication_claims")
    )
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.conflictingTenantClaims),
      .localAuthenticationUnavailable(code: "conflicting_tenant_claims")
    )
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.userIdentityMismatch),
      .localAuthenticationUnavailable(code: "user_identity_mismatch")
    )
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.missingTenantClaim),
      .localAuthenticationUnavailable(code: "missing_tenant_claim")
    )
    XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.malformedResponse("x")), .malformedResponse)
    XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: SignalServerClientCompat.ClientError.requestTimedOut("/api/devices/list")), .transport)
    XCTAssertEqual(
      SignalServerClientCompat.presenceFailure(for: AccountPresenceClientError.localIdentityUnavailable(underlying: "x")),
      .localIdentityUnavailable
    )
  }

  func testServiceFollowsAuthenticationAndScenePhaseWithoutLeakingStaleState() async throws {
    let service = AccountPresenceService(
      signalServer: SignalServerClientCompat(),
      loadBinding: { throw AccountPresenceTestError.identityUnavailable },
      reportProvider: { try IOSDevicePresenceReportBuilder.makeReport(identity: self.identity(platform: .iOS), lanAddresses: []) },
      refreshInterval: 3_600,
      now: { Date(timeIntervalSince1970: 1_000) }
    )
    XCTAssertFalse(service.isAuthenticated)
    XCTAssertNil(service.lastListFailure)

    let principal = CurrentPathAuthenticationPrincipal(userID: "user-a", tenantID: "tenant-a")
    service.updateAuthentication(principal: principal)
    XCTAssertTrue(service.isAuthenticated)
    await service.waitForCurrentRefresh()
    XCTAssertEqual(service.lastHeartbeatFailure, .localIdentityUnavailable)
    XCTAssertEqual(service.lastListFailure, .localIdentityUnavailable)
    XCTAssertNil(service.accountDevices)
    XCTAssertTrue(service.isSnapshotStale())

    service.handleScenePhase(isActive: false)
    service.handleScenePhase(isActive: true)
    await service.waitForCurrentRefresh()
    XCTAssertEqual(service.lastListFailure, .localIdentityUnavailable)

    service.updateAuthentication(principal: nil)
    XCTAssertFalse(service.isAuthenticated)
    XCTAssertNil(service.lastListFailure)
    XCTAssertNil(service.lastHeartbeatFailure)
    XCTAssertNil(service.accountDevices)

    service.updateAuthentication(principal: CurrentPathAuthenticationPrincipal(userID: "user-b", tenantID: "tenant-a"))
    await service.waitForCurrentRefresh()
    XCTAssertEqual(service.lastListFailure, .localIdentityUnavailable)
    service.updateAuthentication(principal: nil)
  }

  func testIOSAccountDevicesSharesThePolicyEngineAndAddressRules() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func source(_ relativePath: String) throws -> String {
      try readRepositorySourceForSourceShapeTests(at: root.appendingPathComponent(relativePath))
    }
    let ios = "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources"

    let service = try source("\(ios)/Managers/AccountPresenceService.swift")
    XCTAssertTrue(service.contains("AccountPresenceRefreshEngine("), "iOS must wrap the shared engine")
    XCTAssertFalse(service.contains("Task.sleep"), "no second scheduler on iOS")
    XCTAssertTrue(service.contains("capabilities: [.fileTransfer, .clipboard]"))
    XCTAssertFalse(service.contains(".remoteDesktop"), "iOS never advertises remote desktop hosting")

    for path in ["\(ios)/Views/AccountDevicesSectionView.swift", "\(ios)/Views/Dashboard/Components/AccountDevicesCardView.swift"] {
      let view = try source(path)
      XCTAssertTrue(view.contains("AccountDevicePresentationPolicy.orderedDevices("), path)
      XCTAssertTrue(view.contains("AccountDevicePresentationPolicy.connectivity("), path)
      XCTAssertFalse(view.contains("sorted(by:"), "\(path) must not re-implement ordering")
      XCTAssertFalse(view.contains("\"remote_desktop\""), "\(path) must not hard-code capability tokens")
    }
    let section = try source("\(ios)/Views/AccountDevicesSectionView.swift")
    XCTAssertTrue(section.contains("discoveryManager.validatedProtocolFingerprint(for: device)"), "LAN matches must verify the protocol fingerprint")

    let cloudKit = try source("\(ios)/Managers/CloudKitSyncManager.swift")
    XCTAssertTrue(cloudKit.contains("LocalNetworkAddressInspector.routableAddresses().first"))
    XCTAssertFalse(cloudKit.contains("getifaddrs"), "one interface enumerator per platform")
    let inspector = try source("\(ios)/Utilities/LocalNetworkAddressInspector.swift")
    XCTAssertTrue(inspector.contains("LANAddressRoutabilityPolicy.parse(host)"))
    XCTAssertFalse(inspector.contains("169.254"), "the literal rule lives in the shared policy only")

    let dashboard = try source("\(ios)/Views/Dashboard/DashboardView.swift")
    let weatherIndex = try XCTUnwrap(dashboard.range(of: "WeatherCardView()")).lowerBound
    let cardIndex = try XCTUnwrap(dashboard.range(of: "AccountDevicesCardView {")).lowerBound
    let statsIndex = try XCTUnwrap(dashboard.range(of: "statsSection\n")).lowerBound
    XCTAssertLessThan(weatherIndex, cardIndex)
    XCTAssertLessThan(cardIndex, statsIndex)

    let discovery = try source("\(ios)/Views/DeviceDiscoveryView.swift")
    let sectionIndex = try XCTUnwrap(discovery.range(of: "AccountDevicesSectionView(")).lowerBound
    let scanIndex = try XCTUnwrap(discovery.range(of: "scanStatusHeader\n")).lowerBound
    XCTAssertLessThan(sectionIndex, scanIndex, "account devices precede nearby scanning")

    let app = try source("\(ios)/App/SkyBridgeCompassApp.swift")
    XCTAssertTrue(app.contains("AccountPresenceService.shared.updateAuthentication(principal: principal)"))
    XCTAssertTrue(app.contains("AccountPresenceService.shared.handleScenePhase(isActive: true)"))
    XCTAssertTrue(app.contains("AccountPresenceService.shared.handleScenePhase(isActive: false)"))

    for locale in ["en", "ja", "zh-Hans"] {
      let strings = try source("SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/\(locale).lproj/Localizable.strings")
      for key in ["账号设备", "局域网可达", "仅控制端", "可被控", "用连接码连接", "登录后才能看到本账号的设备", "%d 台设备 · %d 台在线"] {
        XCTAssertTrue(strings.contains("\"\(key)\" ="), "\(key) missing from \(locale)")
      }
    }
  }
}

private enum AccountPresenceTestError: Error {
  case identityUnavailable
}
