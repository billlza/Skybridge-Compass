// MARK: - Widget Data Limits
// 数据体积预算常量
// Requirements: 5.1

import Foundation

/// 数据体积限制常量（可配置）
public enum WidgetDataLimits {
 // MARK: - 文件大小限制
 // 使用 nonisolated(unsafe) 允许 DEBUG 构建覆盖，生产环境视为常量
    nonisolated(unsafe) public static var maxDevicesFileSize: Int = 32 * 1024  // 32KB
    nonisolated(unsafe) public static var maxMetricsFileSize: Int = 1 * 1024   // 1KB
    nonisolated(unsafe) public static var maxTransfersFileSize: Int = 16 * 1024 // 16KB
    
 // MARK: - 条目数量限制
    nonisolated(unsafe) public static var maxDevices: Int = 50
    nonisolated(unsafe) public static var maxTransfers: Int = 20
    
 // MARK: - 文件名
    public static let devicesFileName = "widget_devices.json"
    public static let metricsFileName = "widget_metrics.json"
    public static let transfersFileName = "widget_transfers.json"
    
 // MARK: - App Group Identifier
    public static let appGroupIdentifier = "group.com.skybridge.compass"
    
    #if DEBUG
 /// Debug 构建允许通过环境变量覆盖阈值
    public static func loadFromEnvironment() {
        if let val = ProcessInfo.processInfo.environment["WIDGET_MAX_DEVICES"],
           let num = Int(val) {
            maxDevices = num
        }
        if let val = ProcessInfo.processInfo.environment["WIDGET_MAX_TRANSFERS"],
           let num = Int(val) {
            maxTransfers = num
        }
        if let val = ProcessInfo.processInfo.environment["WIDGET_MAX_DEVICES_FILE_SIZE"],
           let num = Int(val) {
            maxDevicesFileSize = num
        }
        if let val = ProcessInfo.processInfo.environment["WIDGET_MAX_TRANSFERS_FILE_SIZE"],
           let num = Int(val) {
            maxTransfersFileSize = num
        }
    }
    #endif
}

// MARK: - Truncation Event (Telemetry)

/// 截断事件（用于 telemetry/调试）
public struct TruncationEvent: Sendable {
    public let payloadKind: WidgetPayloadKind
    public let originalCount: Int
    public let truncatedCount: Int
    public let omittedCount: Int
    public let originalBytes: Int
    public let timestamp: Date
    
    public init(
        payloadKind: WidgetPayloadKind,
        originalCount: Int,
        truncatedCount: Int,
        omittedCount: Int,
        originalBytes: Int,
        timestamp: Date = Date()
    ) {
        self.payloadKind = payloadKind
        self.originalCount = originalCount
        self.truncatedCount = truncatedCount
        self.omittedCount = omittedCount
        self.originalBytes = originalBytes
        self.timestamp = timestamp
    }
    
    public var debugDescription: String {
        "Truncation[\(payloadKind.rawValue)]: \(originalCount)→\(truncatedCount) (-\(omittedCount)), \(originalBytes) bytes"
    }
}
