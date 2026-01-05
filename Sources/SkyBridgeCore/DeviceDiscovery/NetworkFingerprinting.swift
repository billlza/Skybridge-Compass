import Foundation
import os.lock

/// ARP/NDP 与 HTTP 指纹采集器，提供稳定身份来源与软信号。
public final class NetworkFingerprinting: @unchecked Sendable {
    public init() {}

 /// 异步获取 ARP 邻居表，返回 IP→MAC 映射。
    public func fetchARPTable() async -> [String: String] {
        await runCommand(path: "/usr/sbin/arp", args: ["-n"]) { output in
            var map: [String: String] = [:]
            for line in output.split(separator: "\n") {
 // 示例：? (192.168.1.10) at xx:xx:xx:xx:xx:xx on en0 ifscope [ethernet]
                if let ipRange = line.range(of: #"\((\d+\.\d+\.\d+\.\d+)\)"#, options: .regularExpression) {
                    let ip = String(line[ipRange]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                    if let macRange = line.range(of: #"([0-9a-f]{2}(:[0-9a-f]{2}){5})"#, options: .regularExpression) {
                        let mac = String(line[macRange])
                        map[ip] = mac
                    }
                }
            }
            return map
        }
    }

 /// 异步获取 NDP 邻居表（IPv6），返回 IPv6→MAC 映射。
    public func fetchNDPTable() async -> [String: String] {
        await runCommand(path: "/usr/sbin/ndp", args: ["-a"]) { output in
            var map: [String: String] = [:]
            for line in output.split(separator: "\n") {
 // 简化匹配：IPv6 与 MAC
                if let macRange = line.range(of: #"([0-9a-f]{2}(:[0-9a-f]{2}){5})"#, options: .regularExpression) {
                    let mac = String(line[macRange])
                    let parts = line.split(separator: " ")
                    if let ipv6 = parts.first { map[String(ipv6)] = mac }
                }
            }
            return map
        }
    }

 /// 对指定 IP 进行 HTTP 头指纹采集（HEAD），返回 Server 标头。
    public func fetchHTTPServerHeader(ip: String, port: Int = 80, timeout: TimeInterval = 0.5) async -> String? {
        let urlStr = "http://\(ip):\(port)/"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = timeout
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let httpResp = resp as? HTTPURLResponse {
                return httpResp.value(forHTTPHeaderField: "Server")
            }
        } catch {
            return nil
        }
        return nil
    }

 /// 通用异步命令执行器，非阻塞并返回解析结果。
    private func runCommand<T>(path: String, args: [String], parse: @escaping @Sendable (String) -> T) async -> T {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.launchPath = path
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

 // 保证只恢复一次 continuation。
            let resumed = OSAllocatedUnfairLock(initialState: false)

            process.terminationHandler = { _ in
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    isResumed = true
                    return true
                }
                guard shouldResume else { return }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: parse(output))
            }
            do {
                try process.run()
            } catch {
                let shouldResume = resumed.withLock { isResumed -> Bool in
                    guard !isResumed else { return false }
                    isResumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(returning: parse(""))
            }
        }
    }
}
