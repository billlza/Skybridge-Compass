import XCTest
@testable import SkyBridgeCore

final class CrossNetworkWebRTCDiagnosticsTests: XCTestCase {
    func testSanitizeStatusRemovesLineBreaks() {
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.sanitizeStatus("alpha\nbeta\rgamma"),
            "alpha beta gamma"
        )
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
