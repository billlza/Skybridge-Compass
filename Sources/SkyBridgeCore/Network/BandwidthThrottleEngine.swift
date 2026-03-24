//
// BandwidthThrottleEngine.swift
// SkyBridgeCore
//
// 带宽限速引擎 - 使用令牌桶算法
// 支持 macOS 14.0+
//

import Foundation
import OSLog

// MARK: - 带宽限速配置

/// 带宽限制配置
public struct BandwidthLimit: Codable, Sendable, Equatable {
    /// 全局限速 (bytes/sec, nil = 无限制)
    public var globalLimit: Int64?

    /// 每设备限速
    public var perDeviceLimits: [String: Int64]

    /// 时段限速规则
    public var schedules: [BandwidthSchedule]

    /// 无限制配置
    public static let unlimited = BandwidthLimit(
        globalLimit: nil,
        perDeviceLimits: [:],
        schedules: []
    )

    public init(
        globalLimit: Int64? = nil,
        perDeviceLimits: [String: Int64] = [:],
        schedules: [BandwidthSchedule] = []
    ) {
        self.globalLimit = globalLimit
        self.perDeviceLimits = perDeviceLimits
        self.schedules = schedules
    }

    /// 获取当前生效的限速值
    public func effectiveLimit(for deviceID: String? = nil, at date: Date = Date()) -> Int64? {
        // 检查时段限制
        for schedule in schedules where schedule.isActive(at: date) {
            if let deviceID, let deviceLimit = perDeviceLimits[deviceID] {
                return min(schedule.limit, deviceLimit)
            }
            return schedule.limit
        }

        // 检查设备限制
        if let deviceID, let deviceLimit = perDeviceLimits[deviceID] {
            if let global = globalLimit {
                return min(deviceLimit, global)
            }
            return deviceLimit
        }

        return globalLimit
    }
}

// MARK: - 时段限速配置

/// 时段限速规则
public struct BandwidthSchedule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var startHour: Int
    public var endHour: Int
    public var limit: Int64          // bytes/sec
    public var daysOfWeek: Set<Int>  // 1=周日, 2=周一, ..., 7=周六
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        startHour: Int,
        endHour: Int,
        limit: Int64,
        daysOfWeek: Set<Int> = Set(1...7),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.startHour = startHour
        self.endHour = endHour
        self.limit = limit
        self.daysOfWeek = daysOfWeek
        self.isEnabled = isEnabled
    }

    /// 检查当前时间是否在时段内
    public func isActive(at date: Date = Date()) -> Bool {
        guard isEnabled else { return false }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)

        guard daysOfWeek.contains(weekday) else { return false }

        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        } else {
            // 跨夜: 如 22:00 - 06:00
            return hour >= startHour || hour < endHour
        }
    }

    /// 预设: 工作时间限速
    public static let workHours = BandwidthSchedule(
        name: "工作时间",
        startHour: 9,
        endHour: 18,
        limit: 50 * 1024 * 1024,  // 50 MB/s
        daysOfWeek: Set(2...6)    // 周一到周五
    )

    /// 预设: 夜间无限制
    public static let nightUnlimited = BandwidthSchedule(
        name: "夜间无限制",
        startHour: 0,
        endHour: 6,
        limit: Int64.max,
        daysOfWeek: Set(1...7)
    )
}

// MARK: - 带宽使用统计

/// 带宽使用统计
public struct BandwidthUsageStats: Sendable {
    public let deviceID: String
    public let bytesUsed: Int64
    public let bytesAllowed: Int64
    public let timestamp: Date

    public var usageRatio: Double {
        guard bytesAllowed > 0 else { return 0 }
        return Double(bytesUsed) / Double(bytesAllowed)
    }

    public init(deviceID: String, bytesUsed: Int64, bytesAllowed: Int64) {
        self.deviceID = deviceID
        self.bytesUsed = bytesUsed
        self.bytesAllowed = bytesAllowed
        self.timestamp = Date()
    }
}

// MARK: - 带宽限速引擎

/// 带宽限速引擎 - 使用令牌桶算法
@MainActor
public final class BandwidthThrottleEngine: ObservableObject {

    // MARK: - Singleton

    public static let shared = BandwidthThrottleEngine()
    private static let configStore = CodablePersistenceStore<BandwidthLimit>(
        location: .protectedApplicationSupport(
            path: "Network/bandwidth-limit.json",
            legacyUserDefaultsKey: "com.skybridge.bandwidth.config"
        )
    )

    // MARK: - Published Properties

    /// 限速配置
    @Published public var config: BandwidthLimit {
        didSet { saveConfig() }
    }

    /// 当前使用量统计
    @Published public private(set) var currentUsage: [String: Int64] = [:]

    /// 是否启用限速
    @Published public var isEnabled: Bool = false {
        didSet {
            if !isEnabled {
                tokenBuckets.removeAll()
            }
            saveConfig()
        }
    }

    // MARK: - Private Properties

    private var tokenBuckets: [String: TokenBucket] = [:]
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "BandwidthThrottle")
    private let configKey = "com.skybridge.bandwidth.config"

    // MARK: - Initialization

    private init() {
        self.config = Self.loadConfig() ?? .unlimited
        self.isEnabled = UserDefaults.standard.bool(forKey: "com.skybridge.bandwidth.enabled")
        logger.info("📊 带宽限速引擎已初始化")
    }

    // MARK: - Public Methods

    /// 请求发送数据的许可
    /// - Parameters:
    ///   - bytes: 请求发送的字节数
    ///   - deviceID: 目标设备 ID
    /// - Returns: 允许发送的字节数
    public func requestPermission(bytes: Int64, deviceID: String) async -> Int64 {
        guard isEnabled else { return bytes }

        let limit = config.effectiveLimit(for: deviceID)

        guard let limit, limit > 0 else {
            // 无限制
            return bytes
        }

        let bucket = await getOrCreateBucket(for: deviceID, limit: limit)
        return await bucket.consume(bytes)
    }

    /// 报告实际使用的带宽
    public func reportUsage(bytes: Int64, deviceID: String) {
        currentUsage[deviceID, default: 0] += bytes
    }

    /// 重置统计
    public func resetStatistics() {
        currentUsage.removeAll()
        logger.info("📊 带宽统计已重置")
    }

    /// 获取设备的使用统计
    public func getUsageStats(for deviceID: String) -> BandwidthUsageStats {
        let used = currentUsage[deviceID] ?? 0
        let limit = config.effectiveLimit(for: deviceID) ?? Int64.max
        return BandwidthUsageStats(deviceID: deviceID, bytesUsed: used, bytesAllowed: limit)
    }

    /// 添加时段规则
    public func addSchedule(_ schedule: BandwidthSchedule) {
        config.schedules.append(schedule)
    }

    /// 移除时段规则
    public func removeSchedule(id: UUID) {
        config.schedules.removeAll { $0.id == id }
    }

    /// 设置设备限速
    public func setDeviceLimit(_ limit: Int64?, for deviceID: String) {
        if let limit {
            config.perDeviceLimits[deviceID] = limit
        } else {
            config.perDeviceLimits.removeValue(forKey: deviceID)
        }
    }

    // MARK: - Private Methods

    private func getOrCreateBucket(for deviceID: String, limit: Int64) async -> TokenBucket {
        if let bucket = tokenBuckets[deviceID] {
            await bucket.updateLimit(limit)
            return bucket
        }

        let bucket = TokenBucket(bytesPerSecond: limit)
        tokenBuckets[deviceID] = bucket
        return bucket
    }

    private func saveConfig() {
        try? Self.configStore.save(config)
        UserDefaults.standard.set(isEnabled, forKey: "com.skybridge.bandwidth.enabled")
    }

    private static func loadConfig() -> BandwidthLimit? {
        Self.configStore.load()
    }
}

// MARK: - 令牌桶限速器

/// 令牌桶限速器 - 使用 Actor 实现线程安全
actor TokenBucket {
    private var tokens: Double
    private var lastRefill: Date
    private var bytesPerSecond: Int64

    init(bytesPerSecond: Int64) {
        self.bytesPerSecond = bytesPerSecond
        self.tokens = Double(bytesPerSecond)
        self.lastRefill = Date()
    }

    func updateLimit(_ newLimit: Int64) {
        bytesPerSecond = newLimit
    }

    func consume(_ requested: Int64) -> Int64 {
        refill()

        let available = min(Double(requested), tokens)
        tokens -= available
        return Int64(available)
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let newTokens = elapsed * Double(bytesPerSecond)

        tokens = min(tokens + newTokens, Double(bytesPerSecond) * 2) // 最多缓存2秒的令牌
        lastRefill = now
    }
}

// MARK: - 格式化工具

public extension Int64 {
    /// 格式化为带宽字符串
    var bandwidthFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: self) + "/s"
    }
}
