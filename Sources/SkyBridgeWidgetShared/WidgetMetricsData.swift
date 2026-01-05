// MARK: - Widget Metrics Data
// 系统指标数据文件模型 (widget_metrics.json)
// Requirements: 3.1, 3.2, 3.3

import Foundation

/// 系统指标数据（SystemMonitorWidget 专用）
public struct WidgetMetricsData: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let metrics: WidgetSystemMetrics
    public let lastUpdated: Date
    
    #if DEBUG
    public let updateReason: WidgetUpdateReason?
    #endif
    
 // MARK: - Coding Keys
    
    enum CodingKeys: String, CodingKey {
        case schemaVersion, metrics, lastUpdated
        #if DEBUG
        case updateReason
        #endif
    }
    
 // MARK: - 宽容解码（向后兼容）
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.metrics = try container.decodeIfPresent(WidgetSystemMetrics.self, forKey: .metrics) ?? .empty
        self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date.distantPast
        
        #if DEBUG
        self.updateReason = try container.decodeIfPresent(WidgetUpdateReason.self, forKey: .updateReason)
        #endif
    }
    
 // MARK: - Initializer
    
    public init(
        schemaVersion: Int = kWidgetDataSchemaVersion,
        metrics: WidgetSystemMetrics,
        lastUpdated: Date = Date(),
        updateReason: WidgetUpdateReason? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.metrics = metrics
        self.lastUpdated = lastUpdated
        #if DEBUG
        self.updateReason = updateReason
        #endif
    }
    
 // MARK: - Computed Properties
    
 /// 数据新鲜度判定
    public func isStale(threshold: TimeInterval = 30 * 60) -> Bool {
        Date().timeIntervalSince(lastUpdated) > threshold
    }
    
 // MARK: - Pretty Printer
    
    public var prettyDescription: String {
        """
        WidgetMetricsData v\(schemaVersion):
          CPU: \(String(format: "%.1f", metrics.cpuUsage))%
          Memory: \(String(format: "%.1f", metrics.memoryUsage))%
          Network: ↑\(formatBytes(metrics.networkUpload))/s ↓\(formatBytes(metrics.networkDownload))/s
          Updated: \(lastUpdated)
        """
    }
    
    public var sanitizedDescription: String {
        "WidgetMetricsData v\(schemaVersion): CPU \(String(format: "%.0f", metrics.cpuUsage))%, Mem \(String(format: "%.0f", metrics.memoryUsage))%"
    }
    
    private func formatBytes(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1fGB", bytes / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.1fMB", bytes / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.1fKB", bytes / 1_000)
        } else {
            return String(format: "%.0fB", bytes)
        }
    }
    
 // MARK: - Empty State
    
    public static let empty = WidgetMetricsData(metrics: .empty)
}
