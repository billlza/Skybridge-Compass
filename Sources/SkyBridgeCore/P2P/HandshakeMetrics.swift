//
// HandshakeMetrics.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 13: HandshakeMetrics
// Requirements: 6.1, 6.2, 6.3, 6.4
//
// 握手指标收集：
// - HandshakeMetrics: 握手指标结构
// - OptionalNetworkMetrics: 可选网络指标（抽象层，避免绑定系统类型）
// - HandshakeMetricsCollector: 指标收集器 actor
//

import Foundation
import Network

// MARK: - HandshakeMetrics

/// 握手指标
/// Requirements: 6.1, 6.2, 6.3
public struct HandshakeMetrics: Sendable {
 /// 握手往返时间 (ms)
 /// -1 表示无法计算（哨兵值）
 /// Requirement 6.1: RTT = tB - tA
    public let rttMs: Double
    
 /// 重试次数
 /// Requirement 6.2
    public let retryCount: Int
    
 /// 超时次数
 /// Requirement 6.2
    public let timeoutCount: Int

 /// 握手总耗时 (ms)
 /// -1 表示无法计算（哨兵值）
    public let handshakeDurationMs: Double
    
 /// 连接建立耗时 (ms)，来自 Network.framework
 /// nil 表示不可用
 /// Requirement 6.3
    public let establishmentTimeMs: Double?
    
 /// 路径变化次数
 /// nil 表示不可用
 /// Requirement 6.3
    public let pathChangeCount: Int?
    
 /// 使用的加密套件（失败时可能为 nil）
    public let cryptoSuite: CryptoSuite?
    
 /// 是否降级（从 PQC 降级到经典算法），失败或未知时为 nil
    public let isFallback: Bool?
    
 /// 失败原因（成功时为 nil）
    public let failureReason: HandshakeFailureReason?
    
    public init(
        rttMs: Double,
        retryCount: Int,
        timeoutCount: Int,
        establishmentTimeMs: Double?,
        pathChangeCount: Int?,
        handshakeDurationMs: Double,
        cryptoSuite: CryptoSuite?,
        isFallback: Bool?,
        failureReason: HandshakeFailureReason?
    ) {
        self.rttMs = rttMs
        self.retryCount = retryCount
        self.timeoutCount = timeoutCount
        self.establishmentTimeMs = establishmentTimeMs
        self.pathChangeCount = pathChangeCount
        self.handshakeDurationMs = handshakeDurationMs
        self.cryptoSuite = cryptoSuite
        self.isFallback = isFallback
        self.failureReason = failureReason
    }
}

// MARK: - OptionalNetworkMetrics

/// 可选网络指标（抽象层，避免绑定系统类型）
///
/// 由 transport 层填充，如果底层是 Network.framework 且有数据就填，没有就 nil
///
/// **注意**：
/// - establishmentTimeMs 来自 NWConnection.EstablishmentReport.duration（秒）* 1000
/// - 这是 NWConnection 建立到 ready 的总耗时（DNS + TCP/TLS/QUIC 等）
/// - 它不是 P2P 握手 MessageA/MessageB 的 RTT（那个由 HandshakeMetricsCollector 自己算）
/// Requirement 6.3, 6.4
public struct OptionalNetworkMetrics: Sendable {
 /// NWConnection 建立耗时 (ms)
 /// 来自 NWConnection.EstablishmentReport.duration * 1000
    public let establishmentTimeMs: Double?
    
 /// 路径变化次数
    public let pathChangeCount: Int?
    
    public init(establishmentTimeMs: Double? = nil, pathChangeCount: Int? = nil) {
        self.establishmentTimeMs = establishmentTimeMs
        self.pathChangeCount = pathChangeCount
    }
    
 /// 从 NWConnection.EstablishmentReport 创建
 ///
 /// 使用示例：
 /// ```swift
 /// if let report = connection.currentPath?.establishmentReport {
 /// let metrics = OptionalNetworkMetrics(from: report)
 /// }
 /// ```
    @available(macOS 14.0, *)
    public init(from report: NWConnection.EstablishmentReport) {
 // EstablishmentReport.duration 是 TimeInterval（秒）
        self.establishmentTimeMs = report.duration * 1000.0
        self.pathChangeCount = nil  // 需要从 NWPathMonitor 获取
    }
}

// MARK: - HandshakeMetricsCollector

/// 指标收集器 actor
///
/// **设计决策**：
/// - 使用 ContinuousClock 作为成员变量，支持测试注入
/// - 所有时间记录使用 ContinuousClock.Instant
/// - RTT 计算：tB - tA（MessageB 接收时间 - MessageA 发送时间）
/// - 哨兵值 -1 表示无法计算（Requirement 6.4）
///
/// Requirements: 6.1, 6.2, 6.3, 6.4
@available(macOS 14.0, iOS 17.0, *)
public actor HandshakeMetricsCollector {
    
 // MARK: - Properties
    
 /// 时钟（支持测试注入）
    private let clock: ContinuousClock
    
 /// 握手开始时间
    private var startTime: ContinuousClock.Instant?
    
 /// MessageA 发送时间
 /// Requirement 6.1: 用于计算 RTT
    private var messageASentTime: ContinuousClock.Instant?
    
 /// MessageB 接收时间
 /// Requirement 6.1: 用于计算 RTT
    private var messageBReceivedTime: ContinuousClock.Instant?

 /// 握手结束时间
    private var finishTime: ContinuousClock.Instant?
    
 /// 重试次数
 /// Requirement 6.2
    private var retryCount: Int = 0
    
 /// 超时次数
 /// Requirement 6.2
    private var timeoutCount: Int = 0
    
 // MARK: - Initialization
    
    public init(clock: ContinuousClock = ContinuousClock()) {
        self.clock = clock
    }
    
 // MARK: - Recording Methods
    
 /// 记录握手开始
    public func recordStart() {
        startTime = clock.now
    }
    
 /// 记录 MessageA 发送时间
 /// Requirement 6.1
    public func recordMessageASent() {
        messageASentTime = clock.now
    }
    
 /// 记录 MessageB 接收时间
 /// Requirement 6.1
    public func recordMessageBReceived() {
        messageBReceivedTime = clock.now
    }

 /// 记录握手结束
    public func recordFinish() {
        finishTime = clock.now
    }
    
 /// 记录重试
 /// Requirement 6.2
    public func recordRetry() {
        retryCount += 1
    }
    
 /// 记录超时
 /// Requirement 6.2
    public func recordTimeout() {
        timeoutCount += 1
    }
    
 // MARK: - Build Metrics
    
 /// 构建握手指标
 /// - Parameters:
 /// - cryptoSuite: 使用的加密套件（失败时可能为 nil）
 /// - isFallback: 是否降级（失败或未知时为 nil）
 /// - failureReason: 失败原因（成功时为 nil）
 /// - networkMetrics: 可选网络指标
 /// - Returns: 握手指标
 ///
 /// Requirement 6.4: 指标不可用时使用哨兵值 -1
    public func buildMetrics(
        cryptoSuite: CryptoSuite?,
        isFallback: Bool?,
        failureReason: HandshakeFailureReason?,
        networkMetrics: OptionalNetworkMetrics? = nil
    ) -> HandshakeMetrics {
 // 计算 RTT (Requirement 6.1)
        let rttMs: Double
        if let tA = messageASentTime, let tB = messageBReceivedTime {
            let duration = tB - tA
 // Duration 转换为毫秒
            rttMs = Double(duration.components.seconds) * 1000.0 +
                    Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        } else {
 // Requirement 6.4: 哨兵值
            rttMs = -1
        }
        
        let handshakeDurationMs: Double
        if let tStart = startTime, let tEnd = finishTime {
            let duration = tEnd - tStart
            handshakeDurationMs = Double(duration.components.seconds) * 1000.0 +
                Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        } else {
            handshakeDurationMs = -1
        }

        return HandshakeMetrics(
            rttMs: rttMs,
            retryCount: retryCount,
            timeoutCount: timeoutCount,
            establishmentTimeMs: networkMetrics?.establishmentTimeMs,
            pathChangeCount: networkMetrics?.pathChangeCount,
            handshakeDurationMs: handshakeDurationMs,
            cryptoSuite: cryptoSuite,
            isFallback: isFallback,
            failureReason: failureReason
        )
    }
    
 // MARK: - Reset
    
 /// 重置收集器状态
    public func reset() {
        startTime = nil
        messageASentTime = nil
        messageBReceivedTime = nil
        finishTime = nil
        retryCount = 0
        timeoutCount = 0
    }
}
