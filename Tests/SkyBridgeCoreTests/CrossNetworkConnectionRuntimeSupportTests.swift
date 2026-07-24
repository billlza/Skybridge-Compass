import XCTest
@testable import SkyBridgeCore

final class CrossNetworkConnectionRuntimeSupportTests: XCTestCase {
    func testDeviceFingerprintIsStableUppercaseHex() {
        let first = CrossNetworkConnectionRuntimeSupport.deviceFingerprint(
            localizedName: "MacBook Pro",
            hostName: "skybridge-host"
        )
        let second = CrossNetworkConnectionRuntimeSupport.deviceFingerprint(
            localizedName: "MacBook Pro",
            hostName: "skybridge-host"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 16)
        XCTAssertTrue(first.allSatisfy { Set("0123456789ABCDEF").contains($0) })
    }

    func testDeviceFingerprintHandlesMissingLocalizedName() {
        let fingerprint = CrossNetworkConnectionRuntimeSupport.deviceFingerprint(
            localizedName: nil,
            hostName: "skybridge-host"
        )

        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertTrue(fingerprint.allSatisfy { Set("0123456789ABCDEF").contains($0) })
    }

    func testLocalIPv4AddressFilterAcceptsOnlyRoutableEthernetOrBridgeAddresses() {
        XCTAssertTrue(
            CrossNetworkConnectionRuntimeSupport.shouldIncludeLocalIPv4Address(
                interfaceName: "en0",
                address: "192.168.1.10"
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionRuntimeSupport.shouldIncludeLocalIPv4Address(
                interfaceName: "bridge100",
                address: "10.0.0.5"
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionRuntimeSupport.shouldIncludeLocalIPv4Address(
                interfaceName: "lo0",
                address: "192.168.1.10"
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionRuntimeSupport.shouldIncludeLocalIPv4Address(
                interfaceName: "en0",
                address: "127.0.0.1"
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionRuntimeSupport.shouldIncludeLocalIPv4Address(
                interfaceName: "en0",
                address: ""
            )
        )
    }
}
