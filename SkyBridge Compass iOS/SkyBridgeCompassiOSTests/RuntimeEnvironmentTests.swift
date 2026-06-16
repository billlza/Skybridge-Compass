import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
final class RuntimeEnvironmentTests: XCTestCase {
    func testXCTestHostSkipsInteractiveStartup() {
        XCTAssertTrue(SkyBridgeRuntimeEnvironment.isRunningUnderXCTest)
        XCTAssertTrue(SkyBridgeRuntimeEnvironment.shouldSkipInteractiveStartup)
    }

    func testXCTestHostStartupLeavesDiscoveryStopped() {
        let discoveryManager = DeviceDiscoveryManager.instance
        defer { discoveryManager.stopDiscovery() }

        XCTAssertFalse(
            discoveryManager.isDiscovering,
            "XCTest host startup must not start interactive device discovery."
        )
    }

    func testDashboardRefreshDoesNotStartDiscoveryUnderXCTest() async {
        let discoveryManager = DeviceDiscoveryManager.instance
        discoveryManager.stopDiscovery()

        await DashboardViewModel.shared.refresh()

        XCTAssertFalse(discoveryManager.isDiscovering)
    }
}
