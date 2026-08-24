import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

/// 「两条发现记录能否合并」这条规则的契约测试。
///
/// 历史教训：macOS 与 iOS 各写了一套设备去重逻辑，规则并不一致——
/// iOS 先比对持久身份、身份不同就拒绝合并；macOS 却先按 MAC / 序列号 / IP 无条件合并。
/// 结果 iOS 能发现 Mac，Mac 却把不同的对端揉成一行，界面上全是「离线」。
///
/// 这里既锁定规则本身的语义，也锁定「两端都必须走同一份规则」这件事：
/// 任何一端把身份闸门去掉、或者又自己手写一份，这些用例就会红。
final class PeerIdentityFusionPolicyContractTests: XCTestCase {

    private func evidence(id: String? = nil, fingerprint: String? = nil)
        -> PeerIdentityFusionPolicy.IdentityEvidence {
        PeerIdentityFusionPolicy.IdentityEvidence(
            stableDeviceId: id,
            publicKeyFingerprint: fingerprint
        )
    }

    // MARK: - 规则语义

    func testDifferentStableDeviceIdsContradict() {
        XCTAssertTrue(
            PeerIdentityFusionPolicy.identitiesContradict(
                evidence(id: "id:aaaaaaaa-1111"),
                evidence(id: "id:bbbbbbbb-2222")
            )
        )
    }

    func testDifferentFingerprintsContradict() {
        XCTAssertTrue(
            PeerIdentityFusionPolicy.identitiesContradict(
                evidence(fingerprint: String(repeating: "a", count: 64)),
                evidence(fingerprint: String(repeating: "b", count: 64))
            )
        )
    }

    func testMissingIdentityIsNotAContradiction() {
        // 「未知」不等于「不同」：一侧没身份时仍允许靠地址补全，
        // 否则 Bonjour 的裸命中永远接不上已知设备。
        XCTAssertFalse(
            PeerIdentityFusionPolicy.identitiesContradict(
                evidence(id: "id:aaaaaaaa-1111"),
                evidence()
            )
        )
        XCTAssertTrue(
            PeerIdentityFusionPolicy.mayFuseOnCorroboratingSignal(
                lhs: evidence(id: "id:aaaaaaaa-1111"),
                rhs: evidence()
            )
        )
    }

    func testCorroboratingSignalMayNotOverrideContradictingIdentity() {
        // 这就是 Mac 侧「对端全部离线」的根因所对应的规则。
        XCTAssertFalse(
            PeerIdentityFusionPolicy.mayFuseOnCorroboratingSignal(
                lhs: evidence(id: "id:aaaaaaaa-1111", fingerprint: String(repeating: "a", count: 64)),
                rhs: evidence(id: "id:bbbbbbbb-2222", fingerprint: String(repeating: "b", count: 64))
            )
        )
    }

    func testDisplayNameAloneNeverFusesWhenEitherSideHasIdentity() {
        XCTAssertFalse(
            PeerIdentityFusionPolicy.mayFuseOnDisplayNameAlone(
                lhs: evidence(id: "id:aaaaaaaa-1111"),
                rhs: evidence()
            )
        )
        XCTAssertTrue(
            PeerIdentityFusionPolicy.mayFuseOnDisplayNameAlone(
                lhs: evidence(),
                rhs: evidence()
            )
        )
    }

    // MARK: - 归一化（两端必须对「什么算稳定身份」有一致理解）

    func testRouteEndpointsAreNotIdentities() {
        // 这些都是可达性信息：同一台设备换网段就变，不同设备也可能撞上同一个值。
        for raw in [
            "host:192.168.0.104",
            "peer:fe80::c55:97f0:7246:915",
            "bonjour:Ziang的iPad@local.",
            "recent:id:peer-1",
            "Ziang的iPad@local."
        ] {
            XCTAssertNil(
                PeerIdentityFusionPolicy.normalizedStableDeviceId(raw),
                "\(raw) 是路径端点，不应被当作稳定身份"
            )
        }
    }

    func testLiteralIPAddressesAreNotIdentities() {
        for raw in ["192.168.0.104", "10.0.0.1", "fe80::c55:97f0:7246:915", "fe80::1%en0"] {
            XCTAssertNil(
                PeerIdentityFusionPolicy.normalizedStableDeviceId(raw),
                "\(raw) 是地址，不是身份"
            )
        }
    }

    func testStableIdentifiersNormalizeToCanonicalForm() {
        XCTAssertEqual(
            PeerIdentityFusionPolicy.normalizedStableDeviceId("550E8400-E29B-41D4-A716-446655440099"),
            "id:550e8400-e29b-41d4-a716-446655440099"
        )
        XCTAssertEqual(
            PeerIdentityFusionPolicy.normalizedStableDeviceId("id:550E8400-E29B-41D4-A716-446655440099"),
            "id:550e8400-e29b-41d4-a716-446655440099"
        )
        // 大小写差异不得产生两行（同一台设备被拆成两条正是旧实现的症状之一）。
        XCTAssertEqual(
            PeerIdentityFusionPolicy.normalizedStableDeviceId("ID:ABCDEF0123"),
            PeerIdentityFusionPolicy.normalizedStableDeviceId("id:abcdef0123")
        )
    }

    func testTooShortPayloadIsNotAnIdentity() {
        XCTAssertNil(PeerIdentityFusionPolicy.normalizedStableDeviceId("abc"))
        XCTAssertNil(PeerIdentityFusionPolicy.normalizedStableDeviceId("id:abc"))
    }

    // MARK: - 反分叉护栏
    //
    // 下面两个用例读源码文本。它们的作用不是验证行为，而是保证 macOS 与 iOS
    // 都确实走同一份规则——一旦哪端又自己手写一套，这里立刻红。

    func testMacDiscoveryPathsRouteThroughSharedFusionPolicy() throws {
        for path in [
            "Sources/SkyBridgeCore/DeviceDiscovery/UnifiedOnlineDeviceManager.swift",
            "Sources/SkyBridgeCore/DeviceDiscoveryService.swift"
        ] {
            let source = try Self.repositorySource(path)
            XCTAssertTrue(
                source.contains("PeerIdentityFusionPolicy.mayFuseOnCorroboratingSignal("),
                "\(path) 必须通过共享规则判定 MAC/序列号/IP 这类佐证信号是否可用于合并。"
            )
            XCTAssertTrue(
                source.contains("PeerIdentityFusionPolicy.mayFuseOnDisplayNameAlone("),
                "\(path) 必须通过共享规则判定是否允许仅凭名称合并。"
            )
        }
    }

    func testIOSDiscoveryRoutesThroughSharedFusionPolicy() throws {
        // iOS 有自己的 DeviceDiscoveryManager（不链接 SkyBridgeCore），但它**链接**
        // SkyBridgeProtocolCore —— 该文件已经从中导入多个符号，所以共享规则是真的被
        // iOS 编译进去的，不是靠这条文本断言假装统一。
        // 这条断言只负责防回退：谁把 iOS 改回自己手写一套，这里立刻红。
        let source = try Self.repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
        )
        XCTAssertTrue(
            source.contains("import enum SkyBridgeProtocolCore.PeerIdentityFusionPolicy"),
            "iOS 必须导入共享的 PeerIdentityFusionPolicy。"
        )
        XCTAssertTrue(
            source.contains("PeerIdentityFusionPolicy.mayFuseOnCorroboratingSignal("),
            "iOS 的 shouldCoalesceDiscoveryDevices 必须通过共享规则判定身份是否矛盾。"
        )
        XCTAssertFalse(
            source.contains("if let lhsPersistent, let rhsPersistent, lhsPersistent != rhsPersistent {"),
            "iOS 不应再保留自己那份手写的身份比对——那正是两端分叉的起点。"
        )
    }

    /// 共享归一化必须和 iOS 原先使用的 `Network.IPv4Address` 判定一致。
    /// `IPv4Address` 会接受 inet_aton 的整数写法，所以纯数字串必须同样被判成地址；
    /// 两端对「什么算身份」的理解一旦不同，共享规则就名存实亡。
    func testIntegerFormsAreTreatedAsAddressesToMatchNetworkFrameworkParsing() {
        for raw in ["12345678", "2130706433", "1234567890123456", "0x7f000001"] {
            XCTAssertNil(
                PeerIdentityFusionPolicy.normalizedStableDeviceId(raw),
                "\(raw) 会被 Network.IPv4Address 解析成地址，共享规则必须同样处理"
            )
        }
        // 真实设备 id（UUID / Apple 序列号）不受影响，两端本来就一致。
        XCTAssertNotNil(
            PeerIdentityFusionPolicy.normalizedStableDeviceId("550e8400-e29b-41d4-a716-446655440099")
        )
        XCTAssertNotNil(
            PeerIdentityFusionPolicy.normalizedStableDeviceId("00008103-0011223344556677")
        )
        XCTAssertNotNil(PeerIdentityFusionPolicy.normalizedStableDeviceId("abcdef0123"))
    }

    /// BUG A 回归守卫：发现页用的 USB 枚举器必须同时匹配旧版 `kIOUSBDeviceClassName`
    /// 与新版 `IOUSBHostDevice`。现代 Apple Silicon Mac 上接入的 iPhone/iPad 只挂在
    /// 新版栈下，只匹配旧类会让发现页对 USB 在线态全盲（USB 明明插着却判离线）。
    /// 这条断言防止有人把新版类删回去。
    func testDiscoveryUSBEnumeratorCoversModernIOUSBHostDeviceClass() throws {
        let source = try Self.repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/USBDeviceDiscoveryManager.swift"
        )
        XCTAssertTrue(
            source.contains("IOUSBHostDevice"),
            "USBDeviceDiscoveryManager 必须枚举新版 IOUSBHostDevice 栈，否则接入的 iPhone/iPad 不会被发现。"
        )
        XCTAssertTrue(
            source.contains("kIOUSBDeviceClassName"),
            "同时仍需保留旧版 kIOUSBDeviceClassName 以覆盖传统 USB 设备。"
        )
    }

    // MARK: - Helpers

    private static func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SkyBridgeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
