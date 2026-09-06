import XCTest
@testable import SkyBridgeProtocolCore

/// 客户端侧的心跳元数据校验必须与服务端 `lib/presence_report.js` 一致（先拒绝，不靠服务端截断）。
final class AccountDevicePresenceReportTests: XCTestCase {
    private func report(
        name: String = "Studio Mac",
        model: String? = "Mac16,7",
        osVersion: String? = "26.6.0",
        lanAddresses: [String] = ["10.0.0.5"],
        capabilities: [AccountDeviceCapability] = [.remoteDesktop]
    ) throws -> AccountDevicePresenceReport {
        try AccountDevicePresenceReport(
            deviceName: name,
            platform: .macOS,
            deviceModel: model,
            osVersion: osVersion,
            lanAddresses: lanAddresses,
            capabilities: capabilities
        )
    }

    func testEncodesTheServerContractFieldsOnly() throws {
        let data = try JSONEncoder().encode(try report(lanAddresses: ["fd12::1", "10.0.0.5"], capabilities: [.remoteDesktop, .clipboard]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["deviceName", "platform", "deviceModel", "osVersion", "lanAddresses", "capabilities"])
        XCTAssertEqual(object["platform"] as? String, "macos")
        XCTAssertEqual(object["lanAddresses"] as? [String], ["fd12::1", "10.0.0.5"], "reporter order is preserved on the wire")
        XCTAssertEqual(object["capabilities"] as? [String], ["clipboard", "remote_desktop"])
    }

    func testDeviceNameIsTrimmedAndTruncatedByScalarWithoutLoneSurrogates() throws {
        let long = String(repeating: "a", count: 127) + "😀tail"
        let truncated = try report(name: "  \(long)  ").deviceName
        XCTAssertEqual(truncated.unicodeScalars.count, 128)
        XCTAssertTrue(truncated.hasSuffix("😀"))
        XCTAssertNotNil(truncated.data(using: .utf8))
    }

    func testDeviceNameRejectsEmptyAndControlCharacters() {
        XCTAssertThrowsError(try report(name: "   ")) { error in
            XCTAssertEqual(error as? AccountDevicePresenceReportError, .invalidDeviceName)
        }
        for bad in ["Mac\nmini", "Mac\u{7F}mini", "Mac\u{85}mini", "Mac\u{2028}mini", "Mac\u{2029}mini"] {
            XCTAssertThrowsError(try report(name: bad), bad)
        }
    }

    func testMetadataStringsAreBoundedByUTF8BytesAndBlankBecomesNil() throws {
        XCTAssertEqual(try report(model: "  ").deviceModel, nil)
        XCTAssertEqual(try report(osVersion: nil).osVersion, nil)
        XCTAssertEqual(try report(model: String(repeating: "a", count: 64)).deviceModel?.count, 64)
        XCTAssertThrowsError(try report(model: String(repeating: "a", count: 65))) { error in
            XCTAssertEqual(error as? AccountDevicePresenceReportError, .invalidMetadata(field: "deviceModel"))
        }
        XCTAssertThrowsError(try report(osVersion: String(repeating: "版", count: 22))) { error in
            XCTAssertEqual(error as? AccountDevicePresenceReportError, .invalidMetadata(field: "osVersion"))
        }
    }

    func testLANAddressesAreValidatedDedupedAndKeptInReporterOrder() throws {
        let normalized = try report(lanAddresses: ["FD12::1", "10.0.0.9", "[fd12::1]", "10.0.0.5", "192.168.1.1%en0"]).lanAddresses
        XCTAssertEqual(normalized, ["fd12::1", "10.0.0.9", "10.0.0.5", "192.168.1.1"], "the first address is the preferred interface")
        XCTAssertThrowsError(try report(lanAddresses: Array(repeating: "10.0.0.1", count: 9))) { error in
            XCTAssertEqual(error as? AccountDevicePresenceReportError, .tooManyLANAddresses(count: 9))
        }
        XCTAssertThrowsError(try report(lanAddresses: ["192.168.1."])) { error in
            XCTAssertEqual(error as? AccountDevicePresenceReportError, .invalidLANAddress("192.168.1."))
        }
        XCTAssertEqual(try report(lanAddresses: []).lanAddresses, [])
    }

    func testCapabilitiesAreDedupedAndSorted() throws {
        XCTAssertEqual(try report(capabilities: [.remoteDesktop, .clipboard, .remoteDesktop]).capabilities, ["clipboard", "remote_desktop"])
        XCTAssertTrue(AccountDevicePresenceReport.isValidCapabilityToken("remote_desktop"))
        XCTAssertFalse(AccountDevicePresenceReport.isValidCapabilityToken("Remote-Desktop"))
        XCTAssertFalse(AccountDevicePresenceReport.isValidCapabilityToken(String(repeating: "a", count: 33)))
        XCTAssertFalse(AccountDevicePresenceReport.isValidCapabilityToken(""))
    }
}
