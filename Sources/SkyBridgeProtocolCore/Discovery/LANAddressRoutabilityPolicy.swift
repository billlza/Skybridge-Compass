import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 跨平台共享的「IP 字面量是否是可用于局域网直连/上报的地址」规则。
///
/// macOS 的 `LocalNetworkAdvertisementAddressProvider` 与 iOS 的本机地址枚举都走这一份，
/// 不允许两端各自维护一套排除表（历史上两端分叉：iOS 曾放行 ULA 却漏掉 fe80::/10 以外的链路本地段）。
///
/// 规则（保留即"可路由的单播地址"）：
/// - IPv4：排除 0.0.0.0/8、127.0.0.0/8（回环）、169.254.0.0/16（链路本地）、224.0.0.0/4 及以上（组播/保留/广播）。
/// - IPv6：排除 `::`、`::1`、fe80::/10（链路本地）、ff00::/8（组播）、IPv4 映射地址（::ffff:a.b.c.d）。
///   ULA（fc00::/7）保留：它就是路由器分配的局域网地址。
/// - 带 zone id（`%en0`）或方括号的字面量先剥离再判定；返回的规范形式不含 zone/括号。
public enum LANAddressRoutabilityPolicy {
    public enum Family: Sendable, Equatable {
        case ipv4
        case ipv6
    }

    /// 解析后的 IP 字面量：`canonical` 是小写、去 zone、去括号的规范形式。
    public struct Literal: Sendable, Equatable {
        public let family: Family
        public let canonical: String
        public let bytes: [UInt8]

        public var isRoutableLANAddress: Bool {
            switch family {
            case .ipv4:
                return LANAddressRoutabilityPolicy.isRoutableIPv4(bytes)
            case .ipv6:
                return LANAddressRoutabilityPolicy.isRoutableIPv6(bytes)
            }
        }
    }

    /// 解析 IP 字面量；非 IP 返回 nil。
    public static func parse(_ raw: String) -> Literal? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let percent = value.firstIndex(of: "%") {
            value = String(value[..<percent])
        }
        guard !value.isEmpty, value.utf8.count < 64 else { return nil }

        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return Literal(family: .ipv4, canonical: value, bytes: bytes)
        }

        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return Literal(family: .ipv6, canonical: value, bytes: bytes)
        }
        return nil
    }

    public static func isAdvertisableRoutableLANAddress(_ raw: String) -> Bool {
        parse(raw)?.isRoutableLANAddress ?? false
    }

    /// 过滤、去重并保持调用方顺序返回可上报的地址：第一个就是调用方的首选接口地址
    /// （macOS `LocalNetworkAdvertisementAddressProvider` / iOS `LocalNetworkAddressInspector` 都已按接口偏好排好序），
    /// 账号设备列表展示的就是第一个地址，这里绝不能重排。
    public static func routableAddresses(from candidates: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var accepted: [Literal] = []
        for candidate in candidates {
            guard let literal = parse(candidate), literal.isRoutableLANAddress else { continue }
            guard seen.insert(literal.canonical).inserted else { continue }
            accepted.append(literal)
        }
        return accepted
            .prefix(limit)
            .map(\.canonical)
    }

    private static func isRoutableIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        if first == 0 || first == 127 || first >= 224 { return false }
        if first == 169, bytes[1] == 254 { return false }
        return true
    }

    private static func isRoutableIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return false }
        return true
    }
}
