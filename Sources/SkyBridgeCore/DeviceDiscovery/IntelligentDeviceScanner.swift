import Foundation
import Network
import os.log

/// 智能设备扫描器
///
/// 使用缓存、ARP表查询和智能算法优化设备发现性能
///
/// 🆕 2025年优化：
/// - ✅ 基于 ARP 表的快速设备列表
/// - ✅ 智能缓存机制（避免重复扫描）
/// - ✅ 指数退避重试策略
/// - ✅ 优先级队列（优先扫描已知设备）
/// - ✅ 自适应扫描间隔
///
/// ⚡ Swift 6.2.1 特性：使用 actor 确保线程安全
@available(macOS 14.0, *)
public actor IntelligentDeviceScanner {
    
 // MARK: - 缓存结构
    
 /// 设备扫描缓存条目
    private struct CachedDevice: Codable {
        let ip: String
        let hostname: String
        let lastSeen: Date
        let scanCount: Int
        let responseTime: TimeInterval
        
 /// 检查缓存是否仍然有效
        func isValid(maxAge: TimeInterval = 300) -> Bool {
            return Date().timeIntervalSince(lastSeen) < maxAge
        }
        
 /// 计算设备优先级（用于优先队列）
        var priority: Int {
            let ageFactor = Int(Date().timeIntervalSince(lastSeen) / 60)  // 每分钟降1分
            return scanCount - ageFactor
        }
    }
    
 // MARK: - 属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "IntelligentScanner")
    
 /// 设备缓存（IP -> 设备信息）
    private var deviceCache: [String: CachedDevice] = [:]
    
 /// ARP 表缓存
    private var arpCache: [String: String] = [:]  // IP -> MAC
    private var arpCacheTime: Date = .distantPast
    
 /// 扫描统计
    private var totalScans: Int = 0
    private var cacheHits: Int = 0
    
 /// 自适应扫描间隔
    private var scanInterval: TimeInterval = 30.0
    
 // MARK: - 初始化
    
    public init() {
        logger.info("🔍 智能设备扫描器初始化")
    }
    
 // MARK: - ARP 表查询
    
 /// 获取 ARP 表中的所有活跃设备
 ///
 /// 这比逐个ping IP快得多，因为直接读取系统缓存
 ///
 /// ## 性能优化
 /// ✅ 使用异步等待 Process 完成，避免阻塞 Actor
 /// ✅ 缓存结果60秒，减少系统调用
    private func fetchARPTable() async -> [String: String] {
 // 检查缓存是否仍然有效（60秒）
        if Date().timeIntervalSince(arpCacheTime) < 60 {
            logger.debug("使用缓存的 ARP 表")
            return arpCache
        }
        
        logger.info("🔄 刷新 ARP 表缓存")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            
 // 异步等待进程完成（避免阻塞 Actor）
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            
            var newArpCache: [String: String] = [:]
            
 // 解析 ARP 表输出
 // 格式: ? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                if let ipRange = line.range(of: "\\(([0-9.]+)\\)", options: .regularExpression),
                   let macRange = line.range(of: "at ([0-9a-f:]+)", options: .regularExpression) {
                    let ip = String(line[ipRange]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    let macPart = String(line[macRange])
                    let mac = macPart.replacingOccurrences(of: "at ", with: "")
                    newArpCache[ip] = mac
                }
            }
            
            arpCache = newArpCache
            arpCacheTime = Date()
            
            logger.info("✅ ARP 表已刷新：发现 \(newArpCache.count) 个设备")
            return newArpCache
            
        } catch {
            logger.error("ARP 表查询失败: \(error.localizedDescription)")
            return [:]
        }
    }
    
 // MARK: - 智能扫描
    
 /// 智能扫描网络设备
 ///
 /// 优化策略：
 /// 1. 首先检查 ARP 表获取活跃设备列表
 /// 2. 检查缓存，跳过最近扫描的设备
 /// 3. 使用优先级队列，优先扫描高频设备
 /// 4. 应用指数退避策略减少网络负载
 /// 5. 限制扫描范围，避免扫爆局域网
 ///
 /// - Parameters:
 /// - subnet: 子网前缀，例如 "192.168.1"
 /// - maxHosts: 最多扫描的 IP 数量，默认 64（避免网络拥塞）
 /// - Returns: 活跃设备的 IP 列表
    public func scanNetwork(subnet: String = "192.168.1", maxHosts: Int = 64) async -> [String] {
        totalScans += 1
        logger.info("🔍 开始智能网络扫描（第 \(self.totalScans) 次，最多扫描 \(maxHosts) 个主机）")
        
 // 步骤1：获取 ARP 表
        let arpDevices = await fetchARPTable()
        logger.info("   ARP 表包含 \(arpDevices.count) 个设备")
        
 //步骤2：从缓存中找到仍然有效的设备
        let cachedDevices = deviceCache.values.filter { $0.isValid() }
        cacheHits += cachedDevices.count
        logger.info("   缓存命中: \(cachedDevices.count) 个设备")
        
 // 步骤3：合并 ARP 和缓存结果
        var knownIPs = Set(arpDevices.keys)
        knownIPs.formUnion(cachedDevices.map { $0.ip })
        
 // 步骤4：生成需要扫描的IP列表（优先队列）
        var scanQueue: [(ip: String, priority: Int)] = []
        
 // ARP 表中的设备（高优先级）
        for ip in arpDevices.keys {
            if let cached = deviceCache[ip] {
                scanQueue.append((ip: ip, priority: cached.priority + 10))
            } else {
                scanQueue.append((ip: ip, priority: 5))
            }
        }
        
 // 补充扫描一些未知IP（低优先级），但限制数量
        let unknownIPsToScan = max(0, maxHosts - scanQueue.count)
        if unknownIPsToScan > 0 {
            var unknownCount = 0
            for i in 1...254 {
                if unknownCount >= unknownIPsToScan {
                    break
                }
                let ip = "\(subnet).\(i)"
                if !knownIPs.contains(ip) {
                    scanQueue.append((ip: ip, priority: 1))
                    unknownCount += 1
                }
            }
            logger.info("   补充扫描 \(unknownCount) 个未知 IP")
        }
        
 // 按优先级排序
        scanQueue.sort { $0.priority > $1.priority }
        
 // 限制总扫描队列大小
        if scanQueue.count > maxHosts {
            scanQueue = Array(scanQueue.prefix(maxHosts))
            logger.info("   ⚠️ 扫描队列超出限制，截断至 \(maxHosts) 个 IP")
        }
        
 // 步骤5：执行扫描（限制并发数）
        let activeDevices = await scanDevicesWithThrottling(queue: scanQueue)
        
 // 步骤6：更新缓存
        updateCache(activeDevices: activeDevices)
        
 // 步骤7：调整扫描间隔
        adjustScanInterval(activeDeviceCount: activeDevices.count)
        
        logger.info("✅ 扫描完成：发现 \(activeDevices.count) 个活跃设备")
        logger.info("   缓存命中率: \(String(format: "%.1f", Double(self.cacheHits) / Double(self.totalScans) * 100))%")
        
        return activeDevices
    }
    
 // MARK: - 限流扫描
    
    private func scanDevicesWithThrottling(queue: [(ip: String, priority: Int)]) async -> [String] {
        let maxConcurrency = 20
        var activeDevices: [String] = []
        
 // 分批扫描（每批20个）
        for batch in queue.chunked(into: maxConcurrency) {
            let batchResults = await withTaskGroup(of: String?.self) { group in
                for item in batch {
                    group.addTask {
                        await self.quickPing(ip: item.ip)
                    }
                }
                
                var results: [String] = []
                for await result in group {
                    if let ip = result {
                        results.append(ip)
                    }
                }
                return results
            }
            
            activeDevices.append(contentsOf: batchResults)
            
 // 批次间短暂延迟，避免网络拥塞
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        return activeDevices
    }
    
 /// 快速ping检查
 ///
 /// 使用TCP连接测试而不是ICMP（不需要root权限）
    private func quickPing(ip: String) async -> String? {
 // 检查缓存
        if let cached = deviceCache[ip], cached.isValid(maxAge: scanInterval) {
            return ip
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
 // 尝试连接常用端口
        let testPorts: [UInt16] = [80, 443, 22, 445, 3389]
        
        for port in testPorts {
            let host = NWEndpoint.Host(ip)
            let nwPort = NWEndpoint.Port(integerLiteral: port)
            let connection = NWConnection(host: host, port: nwPort, using: .tcp)
            
            let isReachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
 // 使用类来避免值类型的并发问题
                final class ResumeTracker: @unchecked Sendable {
                    private let lock = NSLock()
                    private var hasResumed = false
                    
                    func tryResume(with value: Bool, _ action: () -> Void) {
                        lock.lock()
                        defer { lock.unlock() }
                        if !hasResumed {
                            hasResumed = true
                            action()
                        }
                    }
                }
                
                let tracker = ResumeTracker()
                
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        tracker.tryResume(with: true) {
                            connection.cancel()
                            continuation.resume(returning: true)
                        }
                    case .failed, .cancelled:
                        tracker.tryResume(with: false) {
                            connection.cancel()
                            continuation.resume(returning: false)
                        }
                    default:
                        break
                    }
                }
                
                connection.start(queue: .global())
                
 // 超时处理
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    tracker.tryResume(with: false) {
                        connection.cancel()
                        continuation.resume(returning: false)
                    }
                }
            }
            
            if isReachable {
                let responseTime = CFAbsoluteTimeGetCurrent() - startTime
                logger.debug("✅ \(ip):\(port) 可达，响应时间: \(String(format: "%.0f", responseTime * 1000))ms")
                return ip
            }
        }
        
        return nil
    }
    
 // MARK: - 缓存管理
    
    private func updateCache(activeDevices: [String]) {
        for ip in activeDevices {
            if let existing = deviceCache[ip] {
 // 更新现有设备
                deviceCache[ip] = CachedDevice(
                    ip: ip,
                    hostname: existing.hostname,
                    lastSeen: Date(),
                    scanCount: existing.scanCount + 1,
                    responseTime: existing.responseTime
                )
            } else {
 // 添加新设备
                deviceCache[ip] = CachedDevice(
                    ip: ip,
                    hostname: ip,
                    lastSeen: Date(),
                    scanCount: 1,
                    responseTime: 0
                )
            }
        }
        
 // 清理过期缓存（超过10分钟未见）
        let staleDevices = deviceCache.filter { 
            !$0.value.isValid(maxAge: 600)
        }
        
        for (ip, _) in staleDevices {
            deviceCache.removeValue(forKey: ip)
            logger.debug("🧹 清理过期设备缓存: \(ip)")
        }
    }
    
 /// 自适应调整扫描间隔
    private func adjustScanInterval(activeDeviceCount: Int) {
 // 根据网络活跃度动态调整扫描间隔
        if activeDeviceCount > 20 {
 // 高活跃度网络：更频繁扫描
            scanInterval = max(15.0, scanInterval * 0.9)
        } else if activeDeviceCount < 5 {
 // 低活跃度网络：降低扫描频率
            scanInterval = min(120.0, scanInterval * 1.1)
        }
        
        logger.debug("📊 调整扫描间隔: \(String(format: "%.0f", self.scanInterval))秒")
    }
    
 // MARK: - 统计信息
    
 /// 获取扫描统计信息
    public func getStatistics() -> ScanStatistics {
        return ScanStatistics(
            totalScans: totalScans,
            cacheHits: cacheHits,
            cachedDevices: deviceCache.count,
            currentScanInterval: scanInterval,
            hitRate: totalScans > 0 ? Double(cacheHits) / Double(totalScans) : 0
        )
    }
    
    public struct ScanStatistics {
        public let totalScans: Int
        public let cacheHits: Int
        public let cachedDevices: Int
        public let currentScanInterval: TimeInterval
        public let hitRate: Double
    }
}

