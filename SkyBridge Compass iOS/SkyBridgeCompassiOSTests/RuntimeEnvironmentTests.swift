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

    func testEphemeralKeychainSmokeAlsoUsesEphemeralTrustPersistence() {
        XCTAssertTrue(
            TrustedDeviceStore.usesEphemeralPersistenceForSmoke(
                environment: [
                    "SKYBRIDGE_SMOKE_ROLE": "ios-p2p-client",
                    "SKYBRIDGE_KEYCHAIN_IN_MEMORY": "1"
                ]
            )
        )
        XCTAssertFalse(
            TrustedDeviceStore.usesEphemeralPersistenceForSmoke(
                environment: ["SKYBRIDGE_KEYCHAIN_IN_MEMORY": "1"]
            ),
            "Normal app launches must keep durable trust even in a Debug build."
        )
        XCTAssertFalse(
            TrustedDeviceStore.usesEphemeralPersistenceForSmoke(
                environment: ["SKYBRIDGE_SMOKE_ROLE": "ios-p2p-client"]
            ),
            "A smoke role alone must never downgrade durable trust storage."
        )
    }
}
