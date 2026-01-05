// MARK: - SkyBridgeWidgetShared
// 小组件共享数据模型 - 主 App 和 Widget Extension 共用
// Requirements: 5.1, 5.5, 5.6

import Foundation

// MARK: - Schema Version

/// Schema 版本号，用于向后兼容
public let kWidgetDataSchemaVersion: Int = 1

// MARK: - Device Type

/// 设备类型枚举（避免字符串松散匹配）
public enum WidgetDeviceType: String, Codable, Sendable, CaseIterable {
    case mac
    case iphone
    case ipad
    case windows
    case android
    case linux
    case unknown
    
 /// 宽容解码：未知类型 fallback 到 .unknown
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = WidgetDeviceType(rawValue: rawValue) ?? .unknown
    }
}

// MARK: - Update Reason (Debug)

/// 更新来源（用于调试"为什么刷新这么频繁"）
public enum WidgetUpdateReason: String, Codable, Sendable {
    case deviceStatusChanged
    case deviceOnlineStatusChanged
    case transferProgress
    case transferCompleted
    case metricsTick
    case manualRefresh
    case appLaunch
}

// MARK: - Truncation Info

/// 截断信息（UI 显示 "+N more"）
public struct TruncationInfo: Codable, Sendable, Equatable {
    public let devicesOmitted: Int
    public let transfersOmitted: Int
    
    public init(devicesOmitted: Int = 0, transfersOmitted: Int = 0) {
        self.devicesOmitted = devicesOmitted
        self.transfersOmitted = transfersOmitted
    }
}

// MARK: - Device Info

/// 设备信息（小组件用）
public struct WidgetDeviceInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let deviceType: WidgetDeviceType
    public let isOnline: Bool
    public let lastSeen: Date
    public let ipAddress: String?
    
    public init(
        id: String,
        name: String,
        deviceType: WidgetDeviceType,
        isOnline: Bool,
        lastSeen: Date,
        ipAddress: String?
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.ipAddress = ipAddress
    }
}

// MARK: - System Metrics

/// 系统指标（小组件用）
public struct WidgetSystemMetrics: Codable, Sendable, Equatable {
    public let cpuUsage: Double      // 0-100
    public let memoryUsage: Double   // 0-100
    public let networkUpload: Double  // bytes/s
    public let networkDownload: Double  // bytes/s
    public let timestamp: Date
    
    public init(
        cpuUsage: Double,
        memoryUsage: Double,
        networkUpload: Double,
        networkDownload: Double,
        timestamp: Date = Date()
    ) {
        self.cpuUsage = cpuUsage.clamped(to: 0...100)
        self.memoryUsage = memoryUsage.clamped(to: 0...100)
        self.networkUpload = max(0, networkUpload)
        self.networkDownload = max(0, networkDownload)
        self.timestamp = timestamp
    }
    
 /// 默认空指标
    public static let empty = WidgetSystemMetrics(
        cpuUsage: 0,
        memoryUsage: 0,
        networkUpload: 0,
        networkDownload: 0
    )
}

// MARK: - Transfer Info

/// 传输信息（小组件用）
public struct WidgetTransferInfo: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let fileName: String
    public let progress: Double  // 0.0 - 1.0, clamped
    public let totalBytes: Int64
    public let transferredBytes: Int64
    public let isUpload: Bool
    public let deviceName: String
    
    public init(
        id: String,
        fileName: String,
        progress: Double,
        totalBytes: Int64,
        transferredBytes: Int64,
        isUpload: Bool,
        deviceName: String
    ) {
        self.id = id
        self.fileName = fileName
        self.progress = progress.clamped(to: 0...1)
        self.totalBytes = max(0, totalBytes)
        self.transferredBytes = min(max(0, transferredBytes), max(0, totalBytes))
        self.isUpload = isUpload
        self.deviceName = deviceName
    }
    
 /// 是否正在进行中（未完成）
    public var isActive: Bool {
        progress < 1.0
    }
}

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
