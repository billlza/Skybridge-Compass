// MARK: - Widget Devices Data
// 设备状态数据文件模型 (widget_devices.json)
// Requirements: 5.1, 5.2, 5.3

import Foundation

/// 设备状态数据（DeviceStatusWidget 专用）
public struct WidgetDevicesData: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let devices: [WidgetDeviceInfo]
    public let truncationInfo: TruncationInfo?
    public let lastUpdated: Date
    
    #if DEBUG
    public let updateReason: WidgetUpdateReason?
    #endif
    
 // MARK: - Coding Keys
    
    enum CodingKeys: String, CodingKey {
        case schemaVersion, devices, truncationInfo, lastUpdated
        #if DEBUG
        case updateReason
        #endif
    }
    
 // MARK: - 宽容解码（向后兼容）
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
 // schemaVersion 缺失时默认为 1（兼容旧版本文件）
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.devices = try container.decodeIfPresent([WidgetDeviceInfo].self, forKey: .devices) ?? []
        self.truncationInfo = try container.decodeIfPresent(TruncationInfo.self, forKey: .truncationInfo)
        self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date.distantPast
        
        #if DEBUG
        self.updateReason = try container.decodeIfPresent(WidgetUpdateReason.self, forKey: .updateReason)
        #endif
    }
    
 // MARK: - Initializer
    
    public init(
        schemaVersion: Int = kWidgetDataSchemaVersion,
        devices: [WidgetDeviceInfo],
        truncationInfo: TruncationInfo? = nil,
        lastUpdated: Date = Date(),
        updateReason: WidgetUpdateReason? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.devices = devices
        self.truncationInfo = truncationInfo
        self.lastUpdated = lastUpdated
        #if DEBUG
        self.updateReason = updateReason
        #endif
    }
    
 // MARK: - Computed Properties
    
 /// 在线设备数量
    public var onlineCount: Int {
        devices.filter { $0.isOnline }.count
    }
    
 /// 数据新鲜度判定（超过阈值视为过期）
    public func isStale(threshold: TimeInterval = 30 * 60) -> Bool {
        Date().timeIntervalSince(lastUpdated) > threshold
    }
    
 // MARK: - Pretty Printer
    
 /// Debug 详细输出
    public var prettyDescription: String {
        let deviceNames = devices.map { $0.name }.joined(separator: ", ")
        let truncInfo = truncationInfo.map { " (+\($0.devicesOmitted) omitted)" } ?? ""
        return """
        WidgetDevicesData v\(schemaVersion):
          Devices (\(devices.count))\(truncInfo): \(deviceNames.isEmpty ? "none" : deviceNames)
          Online: \(onlineCount)
          Updated: \(lastUpdated)
        """
    }
    
 /// Release-safe 脱敏输出
    public var sanitizedDescription: String {
        "WidgetDevicesData v\(schemaVersion): \(devices.count) devices, \(onlineCount) online"
    }
    
 // MARK: - Empty State
    
    public static let empty = WidgetDevicesData(devices: [])
}
