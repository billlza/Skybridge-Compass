import Darwin
import Foundation
import Network

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

    static func attachAddressTXT(to record: inout NWTXTRecord) {
        let addresses = routableLANAddresses()
        guard !addresses.isEmpty else { return }

        let primary = addresses[0]
        record["lanHost"] = primary
        record["host"] = primary
        record["ip"] = primary

        if let ipv4 = addresses.first(where: { IPv4Address($0) != nil }) {
            record["ipv4"] = ipv4
            record["lanIPv4"] = ipv4
        }
        if let ipv6 = addresses.first(where: { IPv6Address(stripInterfaceScope($0)) != nil }) {
            record["ipv6"] = ipv6
            record["lanIPv6"] = ipv6
        }
    }

    static func attachAddressTXT(to record: inout [String: Data]) {
        let addresses = routableLANAddresses()
        guard !addresses.isEmpty else { return }

        func set(_ key: String, _ value: String) {
            record[key] = Data(value.utf8)
        }

        let primary = addresses[0]
        set("lanHost", primary)
        set("host", primary)
        set("ip", primary)

        if let ipv4 = addresses.first(where: { IPv4Address($0) != nil }) {
            set("ipv4", ipv4)
            set("lanIPv4", ipv4)
        }
        if let ipv6 = addresses.first(where: { IPv6Address(stripInterfaceScope($0)) != nil }) {
            set("ipv6", ipv6)
            set("lanIPv6", ipv6)
        }
    }

    static func isAdvertisableRoutableLANAddress(_ raw: String) -> Bool {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return false }

        if let ipv4 = IPv4Address(address) {
            let octets = String(describing: ipv4).split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { return false }
            return octets[0] != 0
                && octets[0] != 127
                && !(octets[0] == 169 && octets[1] == 254)
        }

        let unscoped = stripInterfaceScope(address)
        guard IPv6Address(unscoped) != nil else { return false }
        return unscoped != "::"
            && unscoped != "::1"
            && !unscoped.hasPrefix("fe80:")
            && !unscoped.hasPrefix("fc00:")
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
        if IPv4Address(address) != nil { score += 100 }
        if interface == "en0" {
            score += 50
        } else if interface.hasPrefix("en") {
            score += 40
        } else if interface.hasPrefix("bridge") {
            score -= 20
        }
        return score
    }

    private static func stripInterfaceScope(_ raw: String) -> String {
        guard let percent = raw.firstIndex(of: "%") else { return raw }
        return String(raw[..<percent])
    }
}
