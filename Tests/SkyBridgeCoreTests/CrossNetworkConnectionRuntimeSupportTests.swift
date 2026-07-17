import XCTest
@testable import SkyBridgeCore

final class CrossNetworkConnectionRuntimeSupportTests: XCTestCase {
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
