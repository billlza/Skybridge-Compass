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

    func testDeviceInfoTreatsUUIDAndUniqueIdAsStableIdentityFallbacks() {
        let uuidOnly = BonjourTXTParser.extractDeviceInfo(from: [
            "uuid": "F951B140-A4D8-4664-AB9D-D90118738C54",
            "name": "iPad",
            "platform": "ipados"
        ])
        XCTAssertEqual(uuidOnly.deviceId, "F951B140-A4D8-4664-AB9D-D90118738C54")

        let uniqueIdOnly = BonjourTXTParser.extractDeviceInfo(from: [
            "uniqueId": "E0715A9A-D0D3-47E6-B353-DE0A30293E1F",
            "name": "Lza MacBook Pro",
            "platform": "macos"
        ])
        XCTAssertEqual(uniqueIdOnly.deviceId, "E0715A9A-D0D3-47E6-B353-DE0A30293E1F")
        var record = NWTXTRecord()
        record["unique_id"] = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        XCTAssertEqual(
            BonjourTXTParser.getDeviceIdentifier(record),
            "ABCDEF12-3456-7890-ABCD-EF1234567890"
        )
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

    func testDisplayNameRejectsIdentifierLikeTXTNameAndUsesModelBeforeHostname() {
        let extracted = BonjourTXTParser.extractDeviceInfo(from: [
            "deviceId": "550E8400-E29B-41D4-A716-446655440099",
            "name": "id:550E8400-E29B-41D4-A716-446655440099",
            "hostname": "192.168.0.103",
            "model": "iPad Pro 11-inch (M4)",
            "platform": "iPadOS"
        ])

        XCTAssertNil(extracted.name)
        XCTAssertNil(extracted.hostname)
        XCTAssertEqual(extracted.displayName, "iPad Pro 11-inch (M4)")
    }

    func testLocalDevicePresentationRejectsRouteIdentifiersAsDisplayNames() {
        XCTAssertNil(LocalDevicePresentation.sanitizedDisplayNameCandidate("host:192.168.0.103"))
        XCTAssertNil(LocalDevicePresentation.sanitizedDisplayNameCandidate("peer:550E8400-E29B-41D4-A716-446655440099"))
        XCTAssertNil(LocalDevicePresentation.sanitizedDisplayNameCandidate("550E8400-E29B-41D4-A716-446655440099"))
        XCTAssertEqual(
            LocalDevicePresentation.displayDeviceName(
                rawDeviceName: "iPad",
                modelName: "iPad Pro 11-inch (M4)",
                platformName: "iPadOS"
            ),
            "iPad Pro 11-inch (M4)"
        )
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

    func testNetworkLinkStatusParsesWiFiRSSIFromTXTRecord() {
        var record = NWTXTRecord()
        record["networkType"] = "wifi"
        record["rssi"] = "-58"

        let status = BonjourTXTParser.extractNetworkLinkStatus(record)

        XCTAssertEqual(status?.kind, .wifi)
        XCTAssertEqual(status?.connectionType, .wifi)
        XCTAssertEqual(status?.displayLabel, "Wi-Fi")
        XCTAssertEqual(status?.rssi, -58)
        XCTAssertGreaterThan(status?.normalizedSignalStrength ?? 0, 0.5)
        XCTAssertLessThan(status?.normalizedSignalStrength ?? 1, 0.8)
    }

    func testNetworkLinkStatusParsesCellularRadioTechnologyAndSignalFraction() {
        let status = BonjourTXTParser.extractNetworkLinkStatus(from: [
            "networkType": "cellular",
            "radioAccessTechnology": "5GUW",
            "signalStrength": "0.82",
            "signalUnit": "fraction"
        ])

        XCTAssertEqual(status?.kind, .cellular)
        XCTAssertEqual(status?.connectionType, .cellular)
        XCTAssertEqual(status?.displayLabel, "5GUW")
        XCTAssertEqual(status?.radioAccessTechnology, "5GUW")
        guard let normalizedSignalStrength = status?.normalizedSignalStrength else {
            XCTFail("Expected cellular signal fraction to parse")
            return
        }
        XCTAssertEqual(normalizedSignalStrength, 0.82, accuracy: 0.001)
    }
}
