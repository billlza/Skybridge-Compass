//
// P2PConnectionManager.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Connection Management
// Requirements: 10.1, 10.2, 10.3, 10.4, 11.1, 11.2, 11.3, 11.4
//

import Foundation
import Network
import CryptoKit

// MARK: - Auto-Reconnect Manager

/// P2P 自动重连管理器
@available(macOS 14.0, iOS 17.0, *)
public actor P2PAutoReconnectManager {
    
 // MARK: - Configuration
    
 /// 重连配置
    public struct Configuration: Sendable {
 /// 重连延迟（秒）
        public let reconnectDelaySeconds: TimeInterval
        
 /// 最大重试次数
        public let maxRetries: Int
        
 /// 重试间隔倍数
        public let backoffMultiplier: Double
        
 /// 最大重试间隔（秒）
        public let maxBackoffSeconds: TimeInterval
        
        public init(
            reconnectDelaySeconds: TimeInterval = P2PConstants.autoReconnectDelaySeconds,
            maxRetries: Int = P2PConstants.maxReconnectAttempts,
            backoffMultiplier: Double = 1.5,
            maxBackoffSeconds: TimeInterval = 30
        ) {
            self.reconnectDelaySeconds = reconnectDelaySeconds
            self.maxRetries = maxRetries
            self.backoffMultiplier = backoffMultiplier
            self.maxBackoffSeconds = maxBackoffSeconds
        }
    }
    
 // MARK: - Properties
    
    private let config: Configuration
    private var currentRetryCount: Int = 0
    private var isReconnecting: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var lastDisconnectTime: Date?
    private var savedSessionState: P2PSessionStateSnapshot?
    
 /// 重连状态回调
    public var onReconnectStateChanged: (@Sendable (ReconnectState) -> Void)?
    
 /// 重连成功回调
    public var onReconnectSuccess: (@Sendable () -> Void)?
    
 /// 重连失败回调（达到最大重试次数）
    public var onReconnectFailed: (@Sendable (Int) -> Void)?
    
 // MARK: - Initialization
    
    public init(config: Configuration = Configuration()) {
        self.config = config
    }
    
 // MARK: - Public Interface
    
 /// 处理连接断开
    public func handleDisconnect(
        sessionState: P2PSessionStateSnapshot?,
        reconnectAction: @escaping @Sendable () async throws -> Void
    ) {
        guard !isReconnecting else { return }
        
        lastDisconnectTime = Date()
        savedSessionState = sessionState
        currentRetryCount = 0
        
        startReconnect(action: reconnectAction)
    }
    
 /// 取消重连
    public func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        currentRetryCount = 0
        onReconnectStateChanged?(.cancelled)
    }
    
 /// 获取保存的会话状态
    public func getSavedSessionState() -> P2PSessionStateSnapshot? {
        savedSessionState
    }
    
 /// 清除保存的会话状态
    public func clearSavedSessionState() {
        savedSessionState = nil
    }
    
 // MARK: - Private Methods
    
    private func startReconnect(action: @escaping @Sendable () async throws -> Void) {
        isReconnecting = true
        
        reconnectTask = Task { [weak self] in
            guard let self = self else { return }
            
            while await self.currentRetryCount < self.config.maxRetries {
                let retryCount = await self.currentRetryCount
                let delay = await self.calculateDelay(retryCount: retryCount)
                
                await self.onReconnectStateChanged?(.waiting(
                    attempt: retryCount + 1,
                    maxAttempts: self.config.maxRetries,
                    delaySeconds: delay
                ))
                
 // 等待重连延迟
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
 // 任务被取消
                    return
                }
                
                if Task.isCancelled { return }
                
                await self.onReconnectStateChanged?(.attempting(
                    attempt: retryCount + 1,
                    maxAttempts: self.config.maxRetries
                ))
                
 // 尝试重连
                do {
                    try await action()
                    
 // 重连成功
                    await self.handleReconnectSuccess()
                    return
                    
                } catch {
 // 重连失败，继续重试
                    await self.incrementRetryCount()
                }
            }
            
 // 达到最大重试次数
            await self.handleReconnectFailed()
        }
    }
    
    private func calculateDelay(retryCount: Int) -> TimeInterval {
        let baseDelay = config.reconnectDelaySeconds
 // 防止 retryCount 过大导致 pow 溢出（Double.infinity）
        let clampedRetryCount = min(retryCount, 30)
        let multiplier = pow(config.backoffMultiplier, Double(clampedRetryCount))
        let delay = baseDelay * multiplier
        return min(delay, config.maxBackoffSeconds)
    }
    
    private func incrementRetryCount() {
        currentRetryCount += 1
    }
    
    private func handleReconnectSuccess() {
        isReconnecting = false
        currentRetryCount = 0
        onReconnectStateChanged?(.connected)
        onReconnectSuccess?()
    }
    
    private func handleReconnectFailed() {
        isReconnecting = false
        let attempts = currentRetryCount
        currentRetryCount = 0
        onReconnectStateChanged?(.failed(attempts: attempts))
        onReconnectFailed?(attempts)
    }
}

/// 重连状态
public enum ReconnectState: Sendable {
 /// 等待重连
    case waiting(attempt: Int, maxAttempts: Int, delaySeconds: TimeInterval)
    
 /// 正在尝试重连
    case attempting(attempt: Int, maxAttempts: Int)
    
 /// 已连接
    case connected
    
 /// 重连失败
    case failed(attempts: Int)
    
 /// 已取消
    case cancelled
}

// MARK: - Session State Snapshot

/// 会话状态快照（用于重连后恢复）
public struct P2PSessionStateSnapshot: Codable, Sendable {
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥指纹
    public let pubKeyFP: String
    
 /// 协商的加密配置
    public let negotiatedProfile: P2PNegotiatedCryptoProfile
    
 /// 文件传输状态
    public let fileTransferStates: [P2PFileTransferState]
    
 /// 屏幕镜像是否活跃
    public let screenMirroringActive: Bool
    
 /// 屏幕镜像配置
    public let screenMirrorConfig: P2PScreenMirrorConfig?
    
 /// 保存时间
    public let savedAtMillis: Int64
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        negotiatedProfile: P2PNegotiatedCryptoProfile,
        fileTransferStates: [P2PFileTransferState] = [],
        screenMirroringActive: Bool = false,
        screenMirrorConfig: P2PScreenMirrorConfig? = nil,
        savedAtMillis: Int64 = P2PTimestamp.nowMillis
    ) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.negotiatedProfile = negotiatedProfile
        self.fileTransferStates = fileTransferStates
        self.screenMirroringActive = screenMirroringActive
        self.screenMirrorConfig = screenMirrorConfig
        self.savedAtMillis = savedAtMillis
    }
}

// MARK: - Network Change Detector

/// 网络变化检测器
@available(macOS 14.0, iOS 17.0, *)
public actor P2PNetworkChangeDetector {
    
    private var pathMonitor: NWPathMonitor?
    private var currentPath: NWPath?
    private var monitorQueue: DispatchQueue?
    
 /// 网络变化回调
    public var onNetworkChanged: (@Sendable (NetworkChangeEvent) -> Void)?
    
 /// WiFi 网络变化回调
    public var onWiFiNetworkChanged: (@Sendable (String?) -> Void)?
    
    public init() {}
    
 /// 开始监控
    public func startMonitoring() {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.skybridge.p2p.network-monitor")
        
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handlePathUpdate(path)
            }
        }
        
        monitor.start(queue: queue)
        
        self.pathMonitor = monitor
        self.monitorQueue = queue
    }
    
 /// 停止监控
    public func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        monitorQueue = nil
    }
    
 /// 当前网络是否可用
    public var isNetworkAvailable: Bool {
        currentPath?.status == .satisfied
    }
    
 /// 当前是否使用 WiFi
    public var isUsingWiFi: Bool {
        currentPath?.usesInterfaceType(.wifi) == true
    }
    
 // MARK: - Private Methods
    
    private func handlePathUpdate(_ newPath: NWPath) {
        let oldPath = currentPath
        currentPath = newPath
        
 // 检测网络状态变化
        if oldPath?.status != newPath.status {
            let event: NetworkChangeEvent
            switch newPath.status {
            case .satisfied:
                event = .connected
            case .unsatisfied:
                event = .disconnected
            case .requiresConnection:
                event = .requiresConnection
            @unknown default:
                event = .unknown
            }
            onNetworkChanged?(event)
        }
        
 // 检测 WiFi 变化
        let oldUsesWiFi = oldPath?.usesInterfaceType(.wifi) == true
        let newUsesWiFi = newPath.usesInterfaceType(.wifi)
        
        if oldUsesWiFi != newUsesWiFi || (newUsesWiFi && oldPath != nil) {
 // WiFi 状态变化或可能切换了 WiFi 网络
 // 注意：NWPath 不直接提供 SSID，需要通过其他 API 获取
            onWiFiNetworkChanged?(nil)
        }
    }
}

/// 网络变化事件
public enum NetworkChangeEvent: Sendable {
    case connected
    case disconnected
    case requiresConnection
    case unknown
}

// MARK: - Metrics Collector

// 注意：P2PConnectionMetrics 定义在 iOSP2PSessionManager.swift 中

/// P2P 连接指标收集器
@available(macOS 14.0, iOS 17.0, *)
public actor P2PMetricsCollector {
    
 // MARK: - Properties
    
    private var pingHistory: [PingRecord] = []
    private var bandwidthSamples: [Double] = []
    private var packetLossSamples: [Double] = []
    private var lastMetrics: P2PConnectionMetrics?
    private var collectionTask: Task<Void, Never>?
    
    private let maxHistorySize: Int = 60 // 保留 60 秒历史
    private let updateIntervalSeconds: TimeInterval = 1.0
    
 /// 指标更新回调
    public var onMetricsUpdated: (@Sendable (P2PConnectionMetrics) -> Void)?
    
 /// 质量警告回调
    public var onQualityWarning: (@Sendable (QualityWarning) -> Void)?
    
 // MARK: - Configuration
    
    private var encryptionMode: String = "unknown"
    private var protocolVersion: String = "v1"
    private var peerCapabilities: [String] = []
    private var pqcEnabled: Bool = false
    
    public init() {}
    
 // MARK: - Public Interface
    
 /// 配置指标收集器
    public func configure(
        encryptionMode: String,
        protocolVersion: String,
        peerCapabilities: [String],
        pqcEnabled: Bool
    ) {
        self.encryptionMode = encryptionMode
        self.protocolVersion = protocolVersion
        self.peerCapabilities = peerCapabilities
        self.pqcEnabled = pqcEnabled
    }
    
 /// 开始收集
    public func startCollecting() {
        collectionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collectAndReport()
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000))
            }
        }
    }
    
 /// 停止收集
    public func stopCollecting() {
        collectionTask?.cancel()
        collectionTask = nil
    }
    
 /// 记录 ping 结果
    public func recordPing(latencyMs: Double) {
        let record = PingRecord(latencyMs: latencyMs, timestamp: Date())
        pingHistory.append(record)
        
 // 保持历史大小
        if pingHistory.count > maxHistorySize {
            pingHistory.removeFirst()
        }
    }
    
 /// 记录带宽样本
    public func recordBandwidth(mbps: Double) {
        bandwidthSamples.append(mbps)
        if bandwidthSamples.count > maxHistorySize {
            bandwidthSamples.removeFirst()
        }
    }
    
 /// 记录丢包
    public func recordPacketLoss(percent: Double) {
        packetLossSamples.append(percent)
        if packetLossSamples.count > maxHistorySize {
            packetLossSamples.removeFirst()
        }
    }
    
 /// 获取当前指标
    public func getCurrentMetrics() -> P2PConnectionMetrics? {
        lastMetrics
    }
    
 // MARK: - Private Methods
    
    private func collectAndReport() {
        let avgLatency = pingHistory.isEmpty ? 0 : pingHistory.map(\.latencyMs).reduce(0, +) / Double(pingHistory.count)
        let avgBandwidth = bandwidthSamples.isEmpty ? 0 : bandwidthSamples.reduce(0, +) / Double(bandwidthSamples.count)
        let avgPacketLoss = packetLossSamples.isEmpty ? 0 : packetLossSamples.reduce(0, +) / Double(packetLossSamples.count)
        
        let metrics = P2PConnectionMetrics(
            latencyMs: avgLatency,
            bandwidthMbps: avgBandwidth,
            packetLossPercent: avgPacketLoss,
            encryptionMode: encryptionMode,
            protocolVersion: protocolVersion,
            peerCapabilities: peerCapabilities,
            pqcEnabled: pqcEnabled
        )
        
        lastMetrics = metrics
        onMetricsUpdated?(metrics)
        
 // 检查质量警告
        checkQualityWarnings(metrics)
    }
    
    private func checkQualityWarnings(_ metrics: P2PConnectionMetrics) {
        var warnings: [QualityWarning] = []
        
        if metrics.latencyMs > 200 {
            warnings.append(.highLatency(ms: metrics.latencyMs))
        }
        
        if metrics.packetLossPercent > 5 {
            warnings.append(.highPacketLoss(percent: metrics.packetLossPercent))
        }
        
        if metrics.bandwidthMbps < 1 && metrics.bandwidthMbps > 0 {
            warnings.append(.lowBandwidth(mbps: metrics.bandwidthMbps))
        }
        
        for warning in warnings {
            onQualityWarning?(warning)
        }
    }
}

/// Ping 记录
private struct PingRecord: Sendable {
    let latencyMs: Double
    let timestamp: Date
}

/// 质量警告
public enum QualityWarning: Sendable {
    case highLatency(ms: Double)
    case highPacketLoss(percent: Double)
    case lowBandwidth(mbps: Double)
    
    public var message: String {
        switch self {
        case .highLatency(let ms):
            return "延迟较高: \(Int(ms))ms"
        case .highPacketLoss(let percent):
            return "丢包率较高: \(String(format: "%.1f", percent))%"
        case .lowBandwidth(let mbps):
            return "带宽较低: \(String(format: "%.1f", mbps)) Mbps"
        }
    }
}

// MARK: - P2PScreenMirrorConfig Codable Extension

extension P2PScreenMirrorConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case targetWidth, targetHeight, targetFPS, targetBitrate, codec, useHardwareEncoder
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetWidth: try container.decode(Int.self, forKey: .targetWidth),
            targetHeight: try container.decode(Int.self, forKey: .targetHeight),
            targetFPS: try container.decode(Int.self, forKey: .targetFPS),
            targetBitrate: try container.decode(Int.self, forKey: .targetBitrate),
            codec: try container.decode(P2PVideoCodec.self, forKey: .codec),
            useHardwareEncoder: try container.decode(Bool.self, forKey: .useHardwareEncoder)
        )
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetWidth, forKey: .targetWidth)
        try container.encode(targetHeight, forKey: .targetHeight)
        try container.encode(targetFPS, forKey: .targetFPS)
        try container.encode(targetBitrate, forKey: .targetBitrate)
        try container.encode(codec, forKey: .codec)
        try container.encode(useHardwareEncoder, forKey: .useHardwareEncoder)
    }
}
