import XCTest
import Network
@testable import SkyBridgeCore

@MainActor
final class BonjourTXTParsingTests: XCTestCase {
    func testParseBonjourTXTVariants() async throws {
        let sample = "deviceId=ABC123,hostname=TV.local,model=AppleTV,type=media,platform=tvOS,version=17.0,brand=Apple,manufacturer=Apple Inc.,chip=A15,mac=AA:BB:CC:DD:EE:FF,remoteVideoFormats=jpeg,h264,hevc"
        let dict = BonjourTXTParser.parseWithRegex(sample)
        XCTAssertEqual(dict["deviceId"], "ABC123")
        XCTAssertEqual(dict["hostname"], "TV.local")
        XCTAssertEqual(dict["mac"], "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(dict["brand"], "Apple")
        XCTAssertEqual(dict["manufacturer"], "Apple Inc.")
        XCTAssertEqual(dict["chip"], "A15")
        XCTAssertEqual(dict["remoteVideoFormats"], "jpeg,h264,hevc")

        let deviceInfo = BonjourTXTParser.extractDeviceInfo(from: dict)
        XCTAssertEqual(deviceInfo.chip, "A15")
        XCTAssertEqual(deviceInfo.remoteVideoFormats, ["jpeg", "h264", "hevc"])
    }

    func testStructuredBonjourExtractionIgnoresInjectedKEMMaterial() {
        let maliciousTXT = [
            "deviceId": "id:mac-1",
            "hostname": "MacBook.local",
            "name": "Lza MacBook Pro",
            "platform": "macOS",
            "kemRefreshVersion": "1",
            "kemKeyDigest": String(repeating: "a", count: 64),
            "kemPublicKey": Data(repeating: 0x55, count: 1216).base64EncodedString(),
            "kemPublicKeys": "0x0001:\(Data(repeating: 0x56, count: 1216).base64EncodedString())",
            "suiteWireId": "0x0001",
            "publicKey": Data(repeating: 0x57, count: 1216).base64EncodedString()
        ]

        let extracted = BonjourTXTParser.extractDeviceInfo(from: maliciousTXT)

        XCTAssertEqual(extracted.deviceId, "id:mac-1")
        XCTAssertEqual(extracted.displayName, "Lza MacBook Pro")
        XCTAssertEqual(extracted.platform, "macOS")

        let exposedFields = Mirror(reflecting: extracted).children.compactMap(\.label)
        XCTAssertFalse(exposedFields.contains { $0.localizedCaseInsensitiveContains("kem") })
        XCTAssertFalse(exposedFields.contains { $0.localizedCaseInsensitiveContains("publicKey") })
    }

    func testParseNWTXTRecordFallsBackToDirectKnownKeys() {
        var record = NWTXTRecord()
        record["deviceId"] = "07CB9A6E-7492-4680-9DD7-F37DC8568891"
        record["name"] = "iPad"
        record["skybridgePort"] = "9527"
        record["controlPort"] = "9527"
        record["p2pPort"] = "9527"

        let dict = BonjourTXTParser.parse(record)

        XCTAssertEqual(dict["deviceId"], "07CB9A6E-7492-4680-9DD7-F37DC8568891")
        XCTAssertEqual(dict["name"], "iPad")
        XCTAssertEqual(dict["skybridgePort"], "9527")
        XCTAssertEqual(dict["controlPort"], "9527")
        XCTAssertEqual(dict["p2pPort"], "9527")
    }
}
