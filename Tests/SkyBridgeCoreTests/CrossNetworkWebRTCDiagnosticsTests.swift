import XCTest
@testable import SkyBridgeCore

final class CrossNetworkWebRTCDiagnosticsTests: XCTestCase {
    func testSanitizeStatusRemovesLineBreaks() {
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.sanitizeStatus("alpha\nbeta\rgamma"),
            "alpha beta gamma"
        )
    }

    func testSanitizeStatusRedactsAdmissionSecretsAndPeerIdentifiers() {
        let raw = #"code 6BJ34VQR status waiting(code: "6BJ34VQR") session=6BJ34VQR sessionId: "6BJ34VQR" deviceId=device-alpha peerId=peer-beta fingerprint=abcdef012345 from=mac-device to=android-device"#
        let sanitized = CrossNetworkWebRTCDiagnostics.sanitizeStatus(raw)

        XCTAssertTrue(sanitized.contains("code <redacted>"))
        XCTAssertTrue(sanitized.contains(#"code: "<redacted>""#))
        XCTAssertTrue(sanitized.contains("session=<redacted>"))
        XCTAssertTrue(sanitized.contains(#"sessionId: "<redacted>""#))
        XCTAssertTrue(sanitized.contains("deviceId=<redacted>"))
        XCTAssertTrue(sanitized.contains("peerId=<redacted>"))
        XCTAssertTrue(sanitized.contains("fingerprint=<redacted>"))
        XCTAssertTrue(sanitized.contains("from=<redacted>"))
        XCTAssertTrue(sanitized.contains("to=<redacted>"))
        XCTAssertFalse(sanitized.contains("6BJ34VQR"))
        XCTAssertFalse(sanitized.contains("device-alpha"))
        XCTAssertFalse(sanitized.contains("peer-beta"))
        XCTAssertFalse(sanitized.contains("abcdef012345"))
    }

    func testDescribeScreenPayloadMagicDetectsKnownFormats() {
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x53, 0x42, 0x50, 0x32, 0x00])),
            "SBP2"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x53, 0x42, 0x52, 0x46, 0x00])),
            "SBRF"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x01, 0x02, 0x03, 0x04])),
            "cipher"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x01, 0x02, 0x03])),
            "raw"
        )
    }
}
