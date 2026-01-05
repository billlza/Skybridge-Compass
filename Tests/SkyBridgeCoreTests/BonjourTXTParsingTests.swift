import XCTest
@testable import SkyBridgeCore

@MainActor
final class BonjourTXTParsingTests: XCTestCase {
    func testParseBonjourTXTVariants() async throws {
        let svc = DeviceDiscoveryService()
        let sample = "deviceId=ABC123,hostname=TV.local,model=AppleTV,type=media,platform=tvOS,version=17.0,brand=Apple,manufacturer=Apple Inc.,mac=AA:BB:CC:DD:EE:FF"
        let dict = await svc.parseBonjourTXTString(sample)
        XCTAssertEqual(dict["deviceId"], "ABC123")
        XCTAssertEqual(dict["hostname"], "TV.local")
        XCTAssertEqual(dict["mac"], "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(dict["brand"], "Apple")
        XCTAssertEqual(dict["manufacturer"], "Apple Inc.")
    }
}
