import Darwin
import Foundation
import SkyBridgeProtocolCore

/// 本机一条可用于局域网直连/上报的地址。
struct LocalNetworkAddress: Equatable, Sendable {
    let address: String
    let interfaceName: String
    /// wifi / cellular / unknown（供 iCloud KVS 心跳展示）。
    let networkType: String
}

/// 本机网络接口枚举（iOS）。字面量的"是否可路由"规则与 macOS 共享 `LANAddressRoutabilityPolicy`，
/// 这里只负责枚举接口与排序：en0 IPv4 > 其它 Wi-Fi IPv4 > 其它 IPv4 > IPv6。
/// iCloud KVS 心跳取第一条；账号设备心跳取前 8 条。
enum LocalNetworkAddressInspector {
    static func routableAddresses() -> [LocalNetworkAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [(rank: Int, entry: LocalNetworkAddress)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let sockaddr = current.pointee.ifa_addr else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(sockaddr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            guard let host = numericHost(from: sockaddr),
                  let literal = LANAddressRoutabilityPolicy.parse(host),
                  literal.isRoutableLANAddress else {
                continue
            }
            let interfaceName = String(cString: current.pointee.ifa_name)
            let entry = LocalNetworkAddress(
                address: literal.canonical,
                interfaceName: interfaceName,
                networkType: networkType(for: interfaceName)
            )
            candidates.append((rank: rank(for: entry, family: literal.family), entry: entry))
        }

        var seen = Set<String>()
        return candidates
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.entry.address < rhs.entry.address
            }
            .compactMap { candidate in
                guard seen.insert(candidate.entry.address).inserted else { return nil }
                return candidate.entry
            }
    }

    static func networkType(for interfaceName: String) -> String {
        if interfaceName.hasPrefix("pdp_ip") { return "cellular" }
        if interfaceName == "en0" || interfaceName.hasPrefix("awdl") { return "wifi" }
        return "unknown"
    }

    private static func rank(for entry: LocalNetworkAddress, family: LANAddressRoutabilityPolicy.Family) -> Int {
        guard family == .ipv4 else { return 3 }
        if entry.interfaceName == "en0" { return 0 }
        if entry.networkType == "wifi" { return 1 }
        return 2
    }

    private static func numericHost(from address: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let byteCount = host.firstIndex(of: 0) ?? host.count
        let bytes = host[..<byteCount].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
