import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class DeviceDiscoveryManagerOptimizedEndpointTests: XCTestCase {
    func testPreferredBonjourEndpointPrefersStableBonjourIdentifierOverIPAddressLikeName() {
        let device = DiscoveredDevice(
            id: UUID(),
            name: "fe80::ce0:3cf9:13d0:85b3%en0",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            uniqueIdentifier: "bonjour:iPad@local."
        )

        let endpoint = DeviceDiscoveryManagerOptimized.preferredBonjourEndpoint(
            for: device,
            defaultDomain: "local."
        )

        XCTAssertEqual(endpoint?.name, "iPad")
        XCTAssertEqual(endpoint?.domain, "local.")
    }

    func testPreferredBonjourEndpointRejectsIPAddressLiteralWithoutStableBonjourIdentifier() {
        let device = DiscoveredDevice(
            id: UUID(),
            name: "fe80::ce0:3cf9:13d0:85b3%en0",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            uniqueIdentifier: nil
        )

        let endpoint = DeviceDiscoveryManagerOptimized.preferredBonjourEndpoint(
            for: device,
            defaultDomain: "local."
        )

        XCTAssertNil(endpoint)
    }

    func testPreferredBonjourEndpointRejectsSyntheticServiceNamesWithoutStableBonjourIdentifier() {
        for name in [
            "id:11111111-1111-1111-1111-111111111111",
            "host:11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111"
        ] {
            let device = DiscoveredDevice(
                id: UUID(),
                name: name,
                ipv4: nil,
                ipv6: nil,
                services: ["_skybridge._tcp"],
                portMap: ["_skybridge._tcp": 9527],
                uniqueIdentifier: nil
            )

            XCTAssertNil(
                DeviceDiscoveryManagerOptimized.preferredBonjourEndpoint(
                    for: device,
                    defaultDomain: "local."
                )
            )
        }
    }
}
