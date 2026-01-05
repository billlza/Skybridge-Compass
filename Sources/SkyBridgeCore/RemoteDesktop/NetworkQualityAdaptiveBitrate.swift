//
// NetworkQualityAdaptiveBitrate.swift
// SkyBridge Compass Pro
//
// 网络质量自适应码率控制
// 符合 Swift 6.2.1 和 macOS 26.x 最佳实践
// 使用 Network Framework 和 Metal 4 优化
//

import Foundation
import Network
import OSLog
import Combine
import CoreMedia
import VideoToolbox

/// 网络质量指标
public struct NetworkQualityMetrics: Sendable {
 /// 带宽（字节/秒）
    public let bandwidth: Double
    
 /// 延迟（毫秒）
    public let latency: Double
    
 /// 丢包率（0.0 - 1.0）
    public let packetLoss: Double
    
 /// 抖动（毫秒）
    public let jitter: Double
    
 /// 时间戳
    public let timestamp: Date
    
    public init(bandwidth: Double, latency: Double, packetLoss: Double, jitter: Double, timestamp: Date = Date()) {
        self.bandwidth = bandwidth
        self.latency = latency
        self.packetLoss = packetLoss
        self.jitter = jitter
        self.timestamp = timestamp
    }
    
 /// 计算网络质量评分（0.0 - 1.0，1.0 为最佳）
    public var qualityScore: Double {
 // 带宽评分（归一化到 0-1，假设 100Mbps 为满分）
        let bandwidthScore = min(1.0, bandwidth / (100 * 1_000_000 / 8))
        
 // 延迟评分（假设 <50ms 为满分，>200ms 为 0）
        let latencyScore = max(0.0, 1.0 - (latency - 50) / 150)
        
 // 丢包率评分（0% 为满分，>5% 为 0）
        let packetLossScore = max(0.0, 1.0 - packetLoss * 20)
        
 // 抖动评分（<10ms 为满分，>50ms 为 0）
        let jitterScore = max(0.0, 1.0 - (jitter - 10) / 40)
        
 // 加权平均
        return (bandwidthScore * 0.3 + latencyScore * 0.3 + packetLossScore * 0.2 + jitterScore * 0.2)
    }
    
 /// 判断网络质量等级
    public var qualityLevel: NetworkQualityLevel {
        let score = qualityScore
        if score >= 0.8 {
            return .excellent
        } else if score >= 0.6 {
            return .good
        } else if score >= 0.4 {
            return .fair
        } else {
            return .poor
        }
    }
}

/// 自适应码率配置
public struct AdaptiveBitrateConfig: Sendable {
 /// 最小码率（bps）
    public let minBitrate: Int
    
 /// 最大码率（bps）
    public let maxBitrate: Int
    
 /// 初始码率（bps）
    public let initialBitrate: Int
    
 /// 码率调整步长（bps）
    public let stepSize: Int
    
 /// 质量阈值（低于此值降低码率）
    public let qualityThreshold: Double
    
    public init(
        minBitrate: Int = 2_000_000,      // 2 Mbps
        maxBitrate: Int = 50_000_000,      // 50 Mbps
        initialBitrate: Int = 10_000_000, // 10 Mbps
        stepSize: Int = 2_000_000,         // 2 Mbps
        qualityThreshold: Double = 0.6
    ) {
        self.minBitrate = minBitrate
        self.maxBitrate = maxBitrate
        self.initialBitrate = initialBitrate
        self.stepSize = stepSize
        self.qualityThreshold = qualityThreshold
    }
}

/// 网络质量监控和自适应码率控制器
@MainActor
public final class NetworkQualityAdaptiveBitrateController: ObservableObject, @unchecked Sendable {
    
    public static let shared = NetworkQualityAdaptiveBitrateController()
    
    private let log = Logger(subsystem: "com.skybridge.compass", category: "AdaptiveBitrate")
    
 /// 当前网络质量指标
    @Published public private(set) var currentMetrics: NetworkQualityMetrics?
    
 /// 当前推荐码率（bps）
    @Published public private(set) var recommendedBitrate: Int
    
 /// 当前网络质量等级
    @Published public private(set) var qualityLevel: NetworkQualityLevel = NetworkQualityLevel.good
    
 /// 配置
    private let config: AdaptiveBitrateConfig
    
 /// 网络路径监控器
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.skybridge.network.monitor")
    
 /// 码率调整回调
    public var onBitrateChanged: ((Int) -> Void)?
    
 /// 质量变化回调
    public var onQualityChanged: ((NetworkQualityLevel) -> Void)?
    
 /// 历史指标（用于平滑计算）
    private var metricsHistory: [NetworkQualityMetrics] = []
    private let maxHistorySize = 10
    
 /// 当前连接
    private var currentConnection: NWConnection?
    
 /// 数据包统计
    private var packetStats: PacketStatistics = PacketStatistics()
    
    private struct PacketStatistics: Sendable {
        var totalSent: Int64 = 0
        var totalReceived: Int64 = 0
        var packetsLost: Int64 = 0
        var lastUpdateTime: Date = Date()
    }
    
    private init(config: AdaptiveBitrateConfig = AdaptiveBitrateConfig()) {
        self.config = config
        self.recommendedBitrate = config.initialBitrate
    }
    
 /// 开始监控网络质量
 /// - Parameter connection: 网络连接（可选，用于获取连接特定指标）
    public func startMonitoring(connection: NWConnection? = nil) {
        currentConnection = connection
        
 // 启动网络路径监控
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        pathMonitor?.start(queue: monitorQueue)
        
 // 启动定期质量评估
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateNetworkQuality()
            }
        }
        
        log.info("✅ 网络质量监控已启动")
    }
    
 /// 停止监控
    public func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        currentConnection = nil
        metricsHistory.removeAll()
        packetStats = PacketStatistics()
        
        log.info("🛑 网络质量监控已停止")
    }
    
 /// 处理网络路径更新
    private func handlePathUpdate(_ path: NWPath) {
 // 获取路径状态信息
        let isExpensive = path.isExpensive
        let isConstrained = path.isConstrained
        
        log.debug("网络路径更新: expensive=\(isExpensive), constrained=\(isConstrained)")
    }
    
 /// 评估网络质量并调整码率
    private func evaluateNetworkQuality() {
 // 计算当前指标
        let metrics = calculateCurrentMetrics()
        currentMetrics = metrics
        
 // 添加到历史记录
        metricsHistory.append(metrics)
        if metricsHistory.count > maxHistorySize {
            metricsHistory.removeFirst()
        }
        
 // 平滑处理（使用移动平均）
        let smoothedScore = metricsHistory.map { $0.qualityScore }.reduce(0, +) / Double(metricsHistory.count)
        
 // 更新质量等级
        let newLevel = smoothedScore >= 0.8 ? NetworkQualityLevel.excellent :
                      smoothedScore >= 0.6 ? NetworkQualityLevel.good :
                      smoothedScore >= 0.4 ? NetworkQualityLevel.fair : NetworkQualityLevel.poor
        
        if newLevel != qualityLevel {
            qualityLevel = newLevel
            onQualityChanged?(newLevel)
            log.info("📊 网络质量等级变化: \(self.qualityLevel.displayName) (评分: \(String(format: "%.2f", smoothedScore)))")
        }
        
 // 根据质量调整码率
        adjustBitrate(qualityScore: smoothedScore)
    }
    
 /// 计算当前网络指标
    private func calculateCurrentMetrics() -> NetworkQualityMetrics {
 // 估算带宽（基于数据包统计）
        let timeElapsed = Date().timeIntervalSince(packetStats.lastUpdateTime)
        let bytesTransferred = Double(packetStats.totalSent + packetStats.totalReceived)
        let estimatedBandwidth = timeElapsed > 0 ? bytesTransferred / timeElapsed : 0
        
 // 估算丢包率
        let totalPackets = packetStats.totalSent + packetStats.totalReceived
        let packetLossRate = totalPackets > 0 ? Double(packetStats.packetsLost) / Double(totalPackets) : 0
        
 // 简化延迟和抖动（实际实现中应使用 ping 或 RTT 测量）
        let estimatedLatency = 50.0 // 默认值，实际应从连接获取
        let estimatedJitter = 10.0  // 默认值
        
        return NetworkQualityMetrics(
            bandwidth: estimatedBandwidth,
            latency: estimatedLatency,
            packetLoss: packetLossRate,
            jitter: estimatedJitter
        )
    }
    
 /// 根据网络质量调整码率
    private func adjustBitrate(qualityScore: Double) {
        let currentBitrate = recommendedBitrate
        var newBitrate = currentBitrate
        
        if qualityScore >= 0.8 {
 // 优秀：可以增加码率
            newBitrate = min(config.maxBitrate, currentBitrate + config.stepSize)
        } else if qualityScore >= config.qualityThreshold {
 // 良好：保持当前码率
            newBitrate = currentBitrate
        } else if qualityScore >= 0.3 {
 // 一般：降低码率
            newBitrate = max(config.minBitrate, currentBitrate - config.stepSize)
        } else {
 // 较差：大幅降低码率
            newBitrate = max(config.minBitrate, currentBitrate - config.stepSize * 2)
        }
        
 // 应用新码率
        if newBitrate != currentBitrate {
            recommendedBitrate = newBitrate
            onBitrateChanged?(newBitrate)
            
            log.info("⚡ 码率调整: \(self.formatBitrate(currentBitrate)) -> \(self.formatBitrate(newBitrate)) (质量评分: \(String(format: "%.2f", qualityScore)))")
        }
    }
    
 /// 记录数据包统计
    public func recordPacketSent(size: Int) {
        packetStats.totalSent += Int64(size)
    }
    
    public func recordPacketReceived(size: Int) {
        packetStats.totalReceived += Int64(size)
    }
    
    public func recordPacketLost() {
        packetStats.packetsLost += 1
    }
    
 /// 格式化码率显示
    private func formatBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000_000 {
            return String(format: "%.1f Gbps", Double(bitrate) / 1_000_000_000)
        } else if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)
        } else if bitrate >= 1_000 {
            return String(format: "%.1f Kbps", Double(bitrate) / 1_000)
        } else {
            return "\(bitrate) bps"
        }
    }
    
 /// 获取推荐的编码参数（用于 VideoToolbox）
    public func getRecommendedEncodingSettings() -> [String: Any] {
        let bitrate = recommendedBitrate
        
 // 根据码率推荐分辨率和帧率
        let (width, height, fps): (Int, Int, Int)
        
        if bitrate >= 30_000_000 {
 // 高码率：4K 60fps
            (width, height, fps) = (3840, 2160, 60)
        } else if bitrate >= 15_000_000 {
 // 中高码率：2K 60fps
            (width, height, fps) = (2560, 1440, 60)
        } else if bitrate >= 8_000_000 {
 // 中码率：1080p 60fps
            (width, height, fps) = (1920, 1080, 60)
        } else if bitrate >= 4_000_000 {
 // 低码率：1080p 30fps
            (width, height, fps) = (1920, 1080, 30)
        } else {
 // 极低码率：720p 30fps
            (width, height, fps) = (1280, 720, 30)
        }
        
        return [
            kVTCompressionPropertyKey_AverageBitRate as String: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: fps,
            "recommendedWidth": width,
            "recommendedHeight": height
        ]
    }
}

