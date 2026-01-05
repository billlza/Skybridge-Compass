import XCTest
@testable import SkyBridgeCore

final class ConnectionMethodTests: XCTestCase {
    func testPriorities() {
        XCTAssertGreaterThan(ConnectionMethod.thunderbolt(interface: "tb").priority, ConnectionMethod.usbc(interface: "usb").priority)
        XCTAssertGreaterThan(ConnectionMethod.usbc(interface: "usb").priority, ConnectionMethod.wifi(interface: "en0").priority)
    }
    func testDescriptions() {
        XCTAssertTrue(ConnectionMethod.wifi(interface: "en0").description.contains("Wi-Fi"))
        XCTAssertTrue(ConnectionMethod.thunderbolt(interface: "bridge100").description.contains("Thunderbolt"))
        XCTAssertTrue(ConnectionMethod.usbc(interface: "en5").description.contains("USB-C"))
    }
}
