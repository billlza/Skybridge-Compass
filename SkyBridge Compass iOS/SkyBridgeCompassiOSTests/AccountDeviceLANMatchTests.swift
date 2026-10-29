import Foundation
import XCTest

@testable import SkyBridgeCompass_iOS

/// 账号设备行 ↔ 附近发现设备的身份匹配：注册表存原始 deviceId，发现侧存 `id:` 前缀的规范化形式，
/// 两边必须过同一个解析器，否则「局域网可达 / 连接设备」永远不会出现。
final class AccountDeviceLANMatchTests: XCTestCase {
    private let rawDeviceId = "8f14e45fceea167a5a36dedd4bea2543"
    private let fingerprint = String(repeating: "a", count: 64)

    func testRawRegistryIdMatchesThePrefixedDiscoveryId() {
        // 这正是修复前失败的场景：两个字符串本身并不相等。
        XCTAssertNotEqual(rawDeviceId, "id:\(rawDeviceId)")
        XCTAssertTrue(
            AccountDeviceLANMatch.matches(
                accountDeviceId: rawDeviceId,
                accountFingerprint: fingerprint,
                discoveredDeviceId: "id:\(rawDeviceId)",
                discoveredFingerprint: fingerprint
            )
        )
    }

    func testMatchIsCaseInsensitiveOnTheFingerprintAndAcceptsBothIdShapes() {
        XCTAssertTrue(
            AccountDeviceLANMatch.matches(
                accountDeviceId: "id:\(rawDeviceId)",
                accountFingerprint: fingerprint.uppercased(),
                discoveredDeviceId: rawDeviceId,
                discoveredFingerprint: "  \(fingerprint)  "
            )
        )
    }

    func testDifferentDeviceIdNeverMatches() {
        XCTAssertFalse(
            AccountDeviceLANMatch.matches(
                accountDeviceId: rawDeviceId,
                accountFingerprint: fingerprint,
                discoveredDeviceId: "id:0000000000000000000000000000dead",
                discoveredFingerprint: fingerprint
            )
        )
    }

    func testFingerprintIsMandatoryAndMustAgree() {
        // 发现侧没有已验证指纹：不能只凭 deviceId 就放出连接入口。
        XCTAssertFalse(
            AccountDeviceLANMatch.matches(
                accountDeviceId: rawDeviceId,
                accountFingerprint: fingerprint,
                discoveredDeviceId: "id:\(rawDeviceId)",
                discoveredFingerprint: nil
            )
        )
        XCTAssertFalse(
            AccountDeviceLANMatch.matches(
                accountDeviceId: rawDeviceId,
                accountFingerprint: fingerprint,
                discoveredDeviceId: "id:\(rawDeviceId)",
                discoveredFingerprint: "   "
            )
        )
        XCTAssertFalse(
            AccountDeviceLANMatch.matches(
                accountDeviceId: rawDeviceId,
                accountFingerprint: "",
                discoveredDeviceId: "id:\(rawDeviceId)",
                discoveredFingerprint: fingerprint
            )
        )
        XCTAssertFalse(
            AccountDeviceLANMatch.matches(
                accountDeviceId: rawDeviceId,
                accountFingerprint: fingerprint,
                discoveredDeviceId: "id:\(rawDeviceId)",
                discoveredFingerprint: String(repeating: "b", count: 64)
            )
        )
    }

    func testUnusableIdentifiersNeverMatch() {
        for unusable in ["", "   ", "host:mac.local", "bonjour:printer", "192.168.1.20", "id:10.0.0.5"] {
            XCTAssertFalse(
                AccountDeviceLANMatch.matches(
                    accountDeviceId: unusable,
                    accountFingerprint: fingerprint,
                    discoveredDeviceId: "id:\(rawDeviceId)",
                    discoveredFingerprint: fingerprint
                ),
                "account id \(unusable) must not match"
            )
            XCTAssertFalse(
                AccountDeviceLANMatch.matches(
                    accountDeviceId: rawDeviceId,
                    accountFingerprint: fingerprint,
                    discoveredDeviceId: unusable,
                    discoveredFingerprint: fingerprint
                ),
                "discovered id \(unusable) must not match"
            )
        }
    }
}
