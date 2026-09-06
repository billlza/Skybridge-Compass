import Darwin
import Foundation
import SkyBridgeProtocolCore

enum LocalNetworkAdvertisementAddressProvider {
    static func routableLANAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [(score: Int, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let sockaddr = current.pointee.ifa_addr else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let interfaceName = String(cString: current.pointee.ifa_name)
            guard isCandidateInterface(interfaceName) else { continue }

            guard let address = numericAddress(from: sockaddr),
                  isAdvertisableRoutableLANAddress(address) else {
                continue
            }

            candidates.append((score: routeScore(interface: interfaceName, address: address), address: address))
        }

        var seen = Set<String>()
        return candidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.address < rhs.address
            }
            .compactMap { candidate in
                guard seen.insert(candidate.address).inserted else { return nil }
                return candidate.address
            }
    }

    /// 字面量规则与 iOS 共享（`LANAddressRoutabilityPolicy`）；本文件只负责接口枚举与排序。
    static func isAdvertisableRoutableLANAddress(_ raw: String) -> Bool {
        LANAddressRoutabilityPolicy.isAdvertisableRoutableLANAddress(raw)
    }

    private static func isCandidateInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !lower.hasPrefix("lo")
            && !lower.hasPrefix("awdl")
            && !lower.hasPrefix("llw")
            && !lower.hasPrefix("utun")
    }

    private static func numericAddress(from sockaddr: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(sockaddr.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length: socklen_t = family == AF_INET
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(
            sockaddr,
            length,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else {
            return nil
        }
        let endIndex = host.firstIndex(of: 0) ?? host.count
        let bytes = host[..<endIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func routeScore(interface: String, address: String) -> Int {
        var score = 0
        if LANAddressRoutabilityPolicy.parse(address)?.family == .ipv4 { score += 100 }
        if interface == "en0" {
            score += 50
        } else if interface.hasPrefix("en") {
            score += 40
        } else if interface.hasPrefix("bridge") {
            score -= 20
        }
        return score
    }

}
