import Foundation
import SkyBridgeProtocolCore
import XCTest

final class LanDirectConnectionInfoTests: XCTestCase {
    private func fixture(host: String = "192.168.1.60", port: UInt16 = 50978) throws -> LanDirectConnectionInfo {
        try .init(host: host, port: port, deviceId: "9A770257-EE43-4D15-9031-D39B7A4AE045",
            protocolFingerprint: String(repeating: "ab", count: 32), deviceName: "书房 Mac", platform: "macos")
    }

    func testSharedAndroidWireFixtureRoundTrips() throws {
        let expected = "skybridge://lan/v1/MTkyLjE2OC4xLjYw/50978/" +
            "OUE3NzAyNTctRUU0My00RDE1LTkwMzEtRDM5QjdBNEFFMDQ1/" +
            String(repeating: "ab", count: 32) + "/5Lmm5oi_IE1hYw/macos"
        XCTAssertEqual(try LanDirectConnectionInfoCodec.encode(fixture()), expected)
        XCTAssertEqual(try LanDirectConnectionInfoCodec.decode(expected), try fixture())
    }

    func testRejectsMalformedCanonicalEncodingAndUnsupportedVersions() throws {
        let valid = try LanDirectConnectionInfoCodec.encode(fixture())
        let invalid = [" " + valid, valid + "\n", valid + "/", String(repeating: "x", count: 2049),
            valid.replacingOccurrences(of: "/50978/", with: "/050978/"),
            valid.replacingOccurrences(of: "/50978/", with: "/65536/"),
            valid.replacingOccurrences(of: "v1/", with: "v2/"),
            valid.replacingOccurrences(of: "MTkyLjE2OC4xLjYw", with: "MTkyLjE2OC4xLjYw="),
            valid.replacingOccurrences(of: "MTkyLjE2OC4xLjYw", with: "_w"),
            valid.replacingOccurrences(of: "/macos", with: "/MACOS")]
        for text in invalid { XCTAssertThrowsError(try LanDirectConnectionInfoCodec.decode(text)) }
    }

    func testOnlyNumericRoutablePeerAddressesCanBeExported() throws {
        for host in ["example.com", "127.0.0.1", "0.0.0.0", "224.0.0.251", "255.255.255.255",
                     "192.168.001.60", "169.254.1.2", "::1", "::", "ff02::fb", "fe80::1",
                     "fe80::1%en0", "[2001:db8::1]", "192.168.1.60\n", "::ffff:192.168.1.60",
                     "192.168.1.60\0", "2001:db8::1\0"] {
            XCTAssertThrowsError(try fixture(host: host), host)
        }
        XCTAssertEqual(try fixture(host: "2001:db8::1").host, "2001:db8::1")
        XCTAssertThrowsError(try fixture(port: 0))
    }

    func testIdentityFingerprintAndDisplayBoundaries() throws {
        for id in ["", " identity", "identity\nother", "identity=other", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try LanDirectConnectionInfo(host: "192.168.1.60", port: 50978,
                deviceId: id, protocolFingerprint: String(repeating: "ab", count: 32), deviceName: "Mac", platform: "macos"))
        }
        XCTAssertThrowsError(try LanDirectConnectionInfo(host: "192.168.1.60", port: 50978,
            deviceId: "peer", protocolFingerprint: String(repeating: "AB", count: 32), deviceName: "Mac", platform: "macos"))
        XCTAssertThrowsError(try LanDirectConnectionInfo(host: "192.168.1.60", port: 50978,
            deviceId: "peer", protocolFingerprint: String(repeating: "ab", count: 32) + "\n", deviceName: "Mac", platform: "macos"))
        for text in ["\u{0085}Mac", "Mac\u{200b}", "\u{00a0}Mac", "Mac\u{feff}"] {
            XCTAssertThrowsError(try LanDirectConnectionInfo(host: "192.168.1.60", port: 50978,
                deviceId: "peer", protocolFingerprint: String(repeating: "ab", count: 32), deviceName: text, platform: "macos"))
            XCTAssertThrowsError(try LanDirectConnectionInfo(host: "192.168.1.60", port: 50978,
                deviceId: text, protocolFingerprint: String(repeating: "ab", count: 32), deviceName: "Mac", platform: "macos"))
        }
        let unicodeName = try LanDirectConnectionInfo(host: "192.168.1.60", port: 50978,
            deviceId: "peer", protocolFingerprint: String(repeating: "ab", count: 32), deviceName: "桌面 🧑‍💻", platform: "macos")
        XCTAssertEqual(try LanDirectConnectionInfoCodec.decode(LanDirectConnectionInfoCodec.encode(unicodeName)), unicodeName)
    }
}
