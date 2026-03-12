import XCTest
@testable import SkyBridgeCore

@MainActor
final class BonjourTXTParsingTests: XCTestCase {
    func testParseBonjourTXTVariants() async throws {
        let sample = "deviceId=ABC123,hostname=TV.local,model=AppleTV,type=media,platform=tvOS,version=17.0,brand=Apple,manufacturer=Apple Inc.,mac=AA:BB:CC:DD:EE:FF,remoteVideoFormats=jpeg,h264,hevc"
        let dict = BonjourTXTParser.parseWithRegex(sample)
        XCTAssertEqual(dict["deviceId"], "ABC123")
        XCTAssertEqual(dict["hostname"], "TV.local")
        XCTAssertEqual(dict["mac"], "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(dict["brand"], "Apple")
        XCTAssertEqual(dict["manufacturer"], "Apple Inc.")
        XCTAssertEqual(dict["remoteVideoFormats"], "jpeg,h264,hevc")

        let deviceInfo = BonjourTXTParser.extractDeviceInfo(from: dict)
        XCTAssertEqual(deviceInfo.remoteVideoFormats, ["jpeg", "h264", "hevc"])
    }
}
