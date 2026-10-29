import XCTest
@testable import SkyBridgeCore

/// 账号设备功能在 macOS 界面层的源码契约：标签位置、主控台面板位置、共享玻璃外观、本地化键完整性。
final class AccountDevicesUIContractTests: XCTestCase {
    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testAccountDevicesIsTheFirstDiscoveryTabButNotTheDefaultLanding() throws {
        let source = try repositorySource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")
        let enumStart = try XCTUnwrap(source.range(of: "public enum DiscoveryMode: String, CaseIterable, Identifiable {")).upperBound
        let firstCase = try XCTUnwrap(source.range(of: "case ", range: enumStart..<source.endIndex)).lowerBound
        let firstCaseLine = source[firstCase...].prefix(while: { $0 != "\n" })
        XCTAssertEqual(String(firstCaseLine), "case accountDevices = \"account\"")
        XCTAssertTrue(source.contains("@State private var selectedConnectionMode: DiscoveryMode = .localScan"))
        XCTAssertTrue(source.contains("case .accountDevices:\n                        accountDevicesSection"))
        XCTAssertTrue(source.contains("requestedMode: Binding<DiscoveryMode?> = .constant(nil)"))
        XCTAssertTrue(source.contains("requestedMode = nil"), "a consumed deep-link request must be cleared")
        XCTAssertTrue(source.contains("AccountDevicesSectionView("))
        XCTAssertTrue(source.contains("onConnect: { device in connectToOnlineDevice(device) }"))
    }

    func testDashboardPanelSitsBetweenWeatherAndTheDiscoveryGrid() throws {
        let content = try repositorySource("Sources/SkyBridgeCompassApp/Dashboard/Sections/DashboardContentView.swift")
        let weather = try XCTUnwrap(content.range(of: "WeatherDashboardCard()")).lowerBound
        let panel = try XCTUnwrap(content.range(of: "AccountDevicesPanelView {")).lowerBound
        let grid = try XCTUnwrap(content.range(of: "LazyVGrid(columns: [")).lowerBound
        XCTAssertLessThan(weather, panel)
        XCTAssertLessThan(panel, grid)
        XCTAssertTrue(content.contains("requestedDiscoveryMode = .accountDevices"))
        XCTAssertTrue(content.contains("selectedNavigation = .deviceManagement"))
        XCTAssertEqual(content.components(separatedBy: "ScrollView {").count - 1, 0)

        let dashboard = try repositorySource("Sources/SkyBridgeCompassApp/Dashboard/DashboardView.swift")
        XCTAssertTrue(dashboard.contains("EnhancedDeviceDiscoveryView(requestedMode: $requestedDiscoveryMode)"))
        XCTAssertTrue(dashboard.contains("requestedDiscoveryMode: $requestedDiscoveryMode,"))
    }

    func testDashboardGlassChromeIsSharedByWeatherAndAccountPanels() throws {
        let weather = try repositorySource("Sources/SkyBridgeCompassApp/Views/WeatherDashboardCard.swift")
        let panel = try repositorySource("Sources/SkyBridgeCompassApp/Dashboard/Sections/AccountDevicesPanelView.swift")
        XCTAssertTrue(weather.contains(".dashboardLiquidGlassChrome(accent: weatherColor, isHovering: isHovering, isFlashing: refreshFlash)"))
        XCTAssertTrue(panel.contains(".dashboardLiquidGlassChrome(accent: .cyan, isHovering: isHovering)"))
        XCTAssertFalse(weather.contains(".clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))"), "the chrome must not be duplicated inline")
    }

    func testSectionAndPanelDeriveStateFromSharedPolicyAndPresenceService() throws {
        for path in [
            "Sources/SkyBridgeCompassApp/Views/AccountDevicesSectionView.swift",
            "Sources/SkyBridgeCompassApp/Dashboard/Sections/AccountDevicesPanelView.swift"
        ] {
            let source = try repositorySource(path)
            XCTAssertTrue(source.contains("PresenceService.shared"), path)
            XCTAssertTrue(source.contains("AccountDevicePresentationPolicy.orderedDevices("), path)
            XCTAssertTrue(source.contains("AccountDevicePresentationPolicy.connectivity("), path)
            XCTAssertTrue(source.contains("resolvedOnlineDevice(for: record)"), path)
            XCTAssertTrue(source.contains("hasResolvedConnectableControlRoute(for: device)"), path)
            XCTAssertFalse(source.contains("sorted(by:"), "\(path) must not re-implement ordering")
            XCTAssertFalse(source.contains("\"remote_desktop\""), "\(path) must not hard-code capability tokens")
        }
    }

    func testAccountDeviceLocalizationKeysExistInEveryLanguage() throws {
        let requiredKeys = [
            "discovery.mode.accountDevices",
            "discovery.mode.subtitle.accountDevices",
            "discovery.accountDevices.title",
            "discovery.accountDevices.description",
            "discovery.accountDevices.nebulaId",
            "discovery.accountDevices.empty.title",
            "discovery.accountDevices.empty.message",
            "discovery.accountDevices.signedOut",
            "discovery.accountDevices.loading",
            "discovery.accountDevices.retryHint",
            "discovery.accountDevices.stale",
            "discovery.accountDevices.truncated",
            "discovery.accountDevices.lastUpdated",
            "discovery.accountDevices.status.lanReachable",
            "discovery.accountDevices.status.online",
            "discovery.accountDevices.status.offline",
            "discovery.accountDevices.capability.controllable",
            "discovery.accountDevices.capability.controlOnly",
            "discovery.accountDevices.lan",
            "discovery.accountDevices.public",
            "discovery.accountDevices.deviceId",
            "discovery.accountDevices.lastSeen",
            "discovery.accountDevices.neverSeen",
            "discovery.accountDevices.registration.pending",
            "discovery.accountDevices.registration.frozen",
            "discovery.accountDevices.action.useConnectionCode",
            "discovery.accountDevices.hint.online",
            "discovery.accountDevices.copyAddress",
            "discovery.accountDevices.copyDeviceId",
            "discovery.accountDevices.failure.notAuthenticated",
            "discovery.accountDevices.failure.deviceNotActive",
            "discovery.accountDevices.failure.rateLimited",
            "discovery.accountDevices.failure.registryUnavailable",
            "discovery.accountDevices.failure.serverRejected",
            "discovery.accountDevices.failure.transport",
            "discovery.accountDevices.failure.malformedResponse",
            "discovery.accountDevices.failure.localIdentityUnavailable",
            "dashboard.accountDevices",
            "dashboard.accountDevices.summary",
            "dashboard.accountDevices.viewAll",
            "dashboard.accountDevices.empty"
        ]
        let usedKeys = try [
            "Sources/SkyBridgeCompassApp/Views/AccountDevicesSectionView.swift",
            "Sources/SkyBridgeCompassApp/Views/AccountDevicePresentation.swift",
            "Sources/SkyBridgeCompassApp/Dashboard/Sections/AccountDevicesPanelView.swift"
        ].map(repositorySource).joined()
        for locale in ["en.lproj", "zh-Hans.lproj", "ja.lproj"] {
            let strings = try repositorySource("Sources/SkyBridgeCore/Resources/\(locale)/Localizable.strings")
            for key in requiredKeys {
                XCTAssertTrue(strings.contains("\"\(key)\" ="), "\(key) missing from \(locale)")
            }
        }
        for key in requiredKeys where key.hasPrefix("discovery.accountDevices.") || key.hasPrefix("dashboard.accountDevices") {
            XCTAssertTrue(usedKeys.contains("\"\(key)\""), "\(key) is defined but never used by the account devices UI")
        }
    }
}
