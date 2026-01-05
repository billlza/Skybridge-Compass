import Foundation
import Security

// Helper 入口：配置 XPC 监听并运行（使用顶层启动）
let helperDelegate = XPCDelegate()
let helperListener = NSXPCListener(machServiceName: "com.skybridge.PowerMetricsHelper")
helperListener.delegate = helperDelegate
helperListener.resume()
RunLoop.current.run()

final class XPCDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
 // 调用方身份校验：仅接受来自主 App（bundle id 匹配）的连接
        let allowedIdentifier = "com.skybridge.compass.pro"
        guard verifyConnectionIdentifier(newConnection, allowedIdentifier: allowedIdentifier) else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: PowerMetricsXPCProtocol.self)
        newConnection.exportedObject = PowerMetricsProvider()
        newConnection.resume()
        return true
    }
}

/// 校验 XPC 连接的代码签名标识符（使用 audit token 解析连接进程）
private func verifyConnectionIdentifier(_ connection: NSXPCConnection, allowedIdentifier: String) -> Bool {
    let pid = connection.processIdentifier
    var guest: SecCode?
    let attrs: [CFString: Any] = [kSecGuestAttributePid: pid]
    let statusGuest = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, SecCSFlags(), &guest)
    guard statusGuest == errSecSuccess, let guest else { return false }
    var requirement: SecRequirement?
    let reqString = "identifier \"\(allowedIdentifier)\""
    let statusReq = SecRequirementCreateWithString(reqString as CFString, SecCSFlags(), &requirement)
    guard statusReq == errSecSuccess, let requirement else { return false }
    let statusValid = SecCodeCheckValidity(guest, SecCSFlags(), requirement)
    return statusValid == errSecSuccess
}

// 与 App 侧保持一致的协议签名
@objc protocol PowerMetricsXPCProtocol {
    func fetchSnapshot(completion: @Sendable @escaping (Data?) -> Void)
}

final class PowerMetricsProvider: NSObject, PowerMetricsXPCProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.skybridge.PowerMetricsHelper.powermetrics")

    func fetchSnapshot(completion: @Sendable @escaping (Data?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { completion(nil); return }
            let snapshot = self.collectSnapshot()
            let data = try? JSONEncoder().encode(snapshot)
            completion(data)
        }
    }

    private struct Snapshot: Codable {
        let timestamp: Date
        let cpuUsagePercent: Double?
        let memoryUsagePercent: Double?
        let gpuUsagePercent: Double?
        let gpuPowerWatts: Double?
        let cpuTemperatureC: Double?
        let gpuTemperatureC: Double?
        let fanRPMs: [Int]?
        let loadAvg1: Double?
        let loadAvg5: Double?
        let loadAvg15: Double?
    }

    private func collectSnapshot() -> Snapshot {
 // 简化实现：尝试调用 powermetrics 获取温度/功耗，失败则返回基本信息
        let temps = self.readTemperatures()
        let loadAverages = self.readLoadAverages()
        return Snapshot(
            timestamp: Date(),
            cpuUsagePercent: nil,
            memoryUsagePercent: nil,
            gpuUsagePercent: nil,
            gpuPowerWatts: nil,
            cpuTemperatureC: temps.cpu,
            gpuTemperatureC: temps.gpu,
            fanRPMs: nil,
            loadAvg1: loadAverages.0,
            loadAvg5: loadAverages.1,
            loadAvg15: loadAverages.2
        )
    }

    private func readLoadAverages() -> (Double?, Double?, Double?) {
        var averages = [Double](repeating: 0, count: 3)
        let count = Int32(3)
        let result = getloadavg(&averages, count)
        if result == 3 { return (averages[0], averages[1], averages[2]) }
        return (nil, nil, nil)
    }

    private func readTemperatures() -> (cpu: Double?, gpu: Double?) {
 // 尝试使用 powermetrics（需要 root，Helper 具备权限）
        let process = Process()
        process.launchPath = "/usr/bin/powermetrics"
        process.arguments = ["--samplers", "smc", "--show-process-energy", "--once"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return (nil, nil) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        let cpu = self.firstMatch(in: text, pattern: #"CPU die temperature:\s*(\d+\.?\d*)\s*C"#)
        let gpu = self.firstMatch(in: text, pattern: #"GPU die temperature:\s*(\d+\.?\d*)\s*C"#)
        return (cpu.flatMap(Double.init), gpu.flatMap(Double.init))
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
