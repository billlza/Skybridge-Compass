import Foundation
import Network
import Darwin

/// SSDP/UPnP 发现器，发送 M-SEARCH 并解析响应中的 USN/UUID 等稳定标识。
public final class SSDPDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ssdp.discovery", qos: .utility)
    private let multicastHost = "239.255.255.250"
    private let multicastPort: UInt16 = 1900

 /// 执行一次轻量的 M-SEARCH 探测，返回 USN/UUID 与 LOCATION。
    public func searchOnce(st: String = "ssdp:all", timeout: TimeInterval = 0.8) async -> [(usn: String, location: String)] {
        var results: [(String, String)] = []
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        if sock < 0 { return results }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(multicastPort).bigEndian
        addr.sin_addr.s_addr = inet_addr(multicastHost)

 // 构造 M-SEARCH 请求报文。
        let payload = "M-SEARCH * HTTP/1.1\r\n" +
                      "HOST: \(multicastHost):\(multicastPort)\r\n" +
                      "MAN: \"ssdp:discover\"\r\n" +
                      "MX: 1\r\n" +
                      "ST: \(st)\r\n\r\n"

        payload.withCString { cstr in
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, cstr, strlen(cstr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

 // 设置接收超时，避免阻塞。
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let count = 2048
        var buffer = [UInt8](repeating: 0, count: count)
        let recvLen = withUnsafeMutablePointer(to: &addr) { ptr -> Int in
            buffer.withUnsafeMutableBytes { bytes in
                guard let rawPtr = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }
                var fromLen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
                return Int(recvfrom(sock, rawPtr, count, 0, UnsafeMutablePointer(ptr).withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }, &fromLen))
            }
        }

        if recvLen > 0 {
            let data = Data(buffer.prefix(recvLen))
            if let text = String(data: data, encoding: .utf8) {
                let usn = parseHeader(text, key: "USN")
                let loc = parseHeader(text, key: "LOCATION")
                if !usn.isEmpty || !loc.isEmpty {
                    results.append((usn, loc))
                }
            }
        }
        return results
    }

 /// 解析响应头中的键值。
    private func parseHeader(_ text: String, key: String) -> String {
        for line in text.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(key.lowercased()) {
                if let range = line.range(of: ":") {
                    let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    return value
                }
            }
        }
        return ""
    }
}
