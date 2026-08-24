import XCTest
@testable import SkyBridgeProtocolCore

/// 锁定跨平台共享的「本机自识别」规则(macOS `UnifiedOnlineDeviceManager` 与
/// iOS `DeviceDiscoveryManager.isProvenSelfDevice` 现在都走这一份)。
final class SelfDeviceIdentityPolicyTests: XCTestCase {

    private func local(
        id: String? = nil,
        fp: String? = nil,
        ips: Set<String> = [],
        macs: Set<String> = []
    ) -> SelfDeviceIdentityPolicy.LocalIdentity {
        .init(stableDeviceId: id, protocolFingerprint: fp, ipAddresses: ips, macAddresses: macs)
    }

    private func candidate(
        id: String? = nil,
        fp: String? = nil,
        ips: Set<String> = [],
        macs: Set<String> = [],
        loopback: Bool = false
    ) -> SelfDeviceIdentityPolicy.CandidateIdentity {
        .init(
            stableDeviceId: id,
            protocolFingerprint: fp,
            ipAddresses: ips,
            macAddresses: macs,
            hasLoopbackAddress: loopback
        )
    }

    // MARK: - iOS parity (these mirror DeviceDiscoveryIdentityPolicyTests on iOS)

    func testMatchingStableAuthorityIsSelfCaseInsensitively() {
        XCTAssertTrue(SelfDeviceIdentityPolicy.isSelf(
            local: local(id: "ID:LOCAL-IPHONE"),
            candidate: candidate(id: "id:local-iphone")
        ))
    }

    func testDifferentStableAuthoritiesAreNotSelf() {
        XCTAssertFalse(SelfDeviceIdentityPolicy.isSelf(
            local: local(id: "id:local-iphone"),
            candidate: candidate(id: "id:remote-iphone")
        ))
    }

    func testLoopbackIsSelfWithoutAStableAuthority() {
        XCTAssertTrue(SelfDeviceIdentityPolicy.isSelf(
            local: local(id: nil),
            candidate: candidate(id: "bonjour:iphone@local.", loopback: true)
        ))
    }

    // MARK: - macOS extra signals

    func testProtocolFingerprintMatchIsSelf() {
        let fp = String(repeating: "a", count: 64)
        XCTAssertTrue(SelfDeviceIdentityPolicy.isSelf(
            local: local(fp: fp.uppercased()),
            candidate: candidate(id: "id:other", fp: fp)
        ))
    }

    func testOwnInterfaceIPIsSelf() {
        XCTAssertTrue(SelfDeviceIdentityPolicy.isSelf(
            local: local(id: "id:me", ips: ["192.168.0.104"]),
            candidate: candidate(id: "id:looks-different", ips: ["192.168.0.104"])
        ))
    }

    func testOwnInterfaceMACIsSelf() {
        XCTAssertTrue(SelfDeviceIdentityPolicy.isSelf(
            local: local(id: "id:me", macs: ["AA:BB:CC:DD:EE:FF"]),
            candidate: candidate(id: "id:looks-different", macs: ["aa:bb:cc:dd:ee:ff"])
        ))
    }

    // MARK: - Safety: a genuine remote peer is never self

    func testGenuineRemotePeerIsNotSelf() {
        XCTAssertFalse(SelfDeviceIdentityPolicy.isSelf(
            local: local(id: "id:me", fp: String(repeating: "a", count: 64),
                         ips: ["192.168.0.104"], macs: ["aa:bb:cc:dd:ee:ff"]),
            candidate: candidate(
                id: "id:peer",
                fp: String(repeating: "b", count: 64),
                ips: ["192.168.0.101"],
                macs: ["11:22:33:44:55:66"]
            )
        ))
    }

    /// 名称不是身份：策略连名称都不接受，所以两台默认同名设备天然不会互相误吞。
    func testEmptyLocalIdentityNeverClaimsSelf() {
        XCTAssertFalse(SelfDeviceIdentityPolicy.isSelf(
            local: local(),
            candidate: candidate(id: "id:peer", ips: ["192.168.0.101"])
        ))
    }
}
