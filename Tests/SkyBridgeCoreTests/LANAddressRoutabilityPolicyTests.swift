import XCTest
@testable import SkyBridgeProtocolCore

/// 共享的局域网地址字面量规则（macOS 广播过滤与 iOS 本机地址枚举共用）。
final class LANAddressRoutabilityPolicyTests: XCTestCase {
    func testParsesCanonicalLiteralsAndStripsBracketsAndZones() throws {
        let ipv4 = try XCTUnwrap(LANAddressRoutabilityPolicy.parse(" 192.168.31.20 "))
        XCTAssertEqual(ipv4.family, .ipv4)
        XCTAssertEqual(ipv4.canonical, "192.168.31.20")
        XCTAssertEqual(ipv4.bytes, [192, 168, 31, 20])

        let scoped = try XCTUnwrap(LANAddressRoutabilityPolicy.parse("[FE80::468:F5A1:462B:29D3%en0]"))
        XCTAssertEqual(scoped.family, .ipv6)
        XCTAssertEqual(scoped.canonical, "fe80::468:f5a1:462b:29d3")
        XCTAssertFalse(scoped.isRoutableLANAddress)

        XCTAssertNil(LANAddressRoutabilityPolicy.parse("example.com"))
        XCTAssertNil(LANAddressRoutabilityPolicy.parse("192.168.1"))
        XCTAssertNil(LANAddressRoutabilityPolicy.parse(""))
        XCTAssertNil(LANAddressRoutabilityPolicy.parse(String(repeating: "1", count: 70)))
    }

    func testRoutabilityMatchesTheSharedRule() {
        for good in ["192.168.31.20", "10.0.0.5", "172.16.4.4", "100.64.0.1", "fd12:3456:789a:1::1", "fc00::1", "2001:db8::10"] {
            XCTAssertTrue(LANAddressRoutabilityPolicy.isAdvertisableRoutableLANAddress(good), good)
        }
        for bad in [
            "169.254.10.20", "127.0.0.1", "0.0.0.0", "0.1.2.3", "224.0.0.1", "255.255.255.255",
            "::", "::1", "fe80::1", "fe80::468:f5a1:462b:29d3%en0", "feb0::1", "ff02::1", "::ffff:192.168.1.1"
        ] {
            XCTAssertFalse(LANAddressRoutabilityPolicy.isAdvertisableRoutableLANAddress(bad), bad)
        }
    }

    func testRoutableAddressesFilterDedupeKeepCallerOrderAndCap() {
        let result = LANAddressRoutabilityPolicy.routableAddresses(
            from: ["fd12::2", "10.0.0.9", "127.0.0.1", "10.0.0.5", "FD12::2", "fe80::1%en0", "10.0.0.5"],
            limit: 3
        )
        XCTAssertEqual(result, ["fd12::2", "10.0.0.9", "10.0.0.5"], "the caller's interface preference order is the contract")
        XCTAssertEqual(
            LANAddressRoutabilityPolicy.routableAddresses(from: ["10.0.0.9", "fd12::2", "10.0.0.5"], limit: 2),
            ["10.0.0.9", "fd12::2"]
        )
        XCTAssertEqual(LANAddressRoutabilityPolicy.routableAddresses(from: ["10.0.0.1"], limit: 0), [])
    }
}
