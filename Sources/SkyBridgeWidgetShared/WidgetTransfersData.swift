// MARK: - Widget Transfers Data
// 文件传输数据文件模型 (widget_transfers.json)
// Requirements: 4.1, 4.2, 4.3

import Foundation

/// 文件传输数据（FileTransferWidget 专用）
public struct WidgetTransfersData: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let transfers: [WidgetTransferInfo]
    public let truncationInfo: TruncationInfo?
    public let lastUpdated: Date
    
    #if DEBUG
    public let updateReason: WidgetUpdateReason?
    #endif
    
 // MARK: - Coding Keys
    
    enum CodingKeys: String, CodingKey {
        case schemaVersion, transfers, truncationInfo, lastUpdated
        #if DEBUG
        case updateReason
        #endif
    }
    
 // MARK: - 宽容解码（向后兼容）
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.transfers = try container.decodeIfPresent([WidgetTransferInfo].self, forKey: .transfers) ?? []
        self.truncationInfo = try container.decodeIfPresent(TruncationInfo.self, forKey: .truncationInfo)
        self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date.distantPast
        
        #if DEBUG
        self.updateReason = try container.decodeIfPresent(WidgetUpdateReason.self, forKey: .updateReason)
        #endif
    }
    
 // MARK: - Initializer
    
    public init(
        schemaVersion: Int = kWidgetDataSchemaVersion,
        transfers: [WidgetTransferInfo],
        truncationInfo: TruncationInfo? = nil,
        lastUpdated: Date = Date(),
        updateReason: WidgetUpdateReason? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.transfers = transfers
        self.truncationInfo = truncationInfo
        self.lastUpdated = lastUpdated
        #if DEBUG
        self.updateReason = updateReason
        #endif
    }
    
 // MARK: - Computed Properties
    
 /// 活跃传输数量
    public var activeCount: Int {
        transfers.filter { $0.isActive }.count
    }
    
 /// 聚合进度（所有传输的总进度）
 /// 边界处理：sum(totalBytes) == 0 → 返回 0.0
    public var aggregateProgress: Double {
        let totalBytes = transfers.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard totalBytes > 0 else { return 0.0 }
        
        let transferredBytes = transfers.reduce(Int64(0)) { $0 + $1.transferredBytes }
        return (Double(transferredBytes) / Double(totalBytes)).clamped(to: 0...1)
    }
    
 /// 数据新鲜度判定
    public func isStale(threshold: TimeInterval = 30 * 60) -> Bool {
        Date().timeIntervalSince(lastUpdated) > threshold
    }
    
 // MARK: - Pretty Printer
    
    public var prettyDescription: String {
        let fileNames = transfers.map { $0.fileName }.joined(separator: ", ")
        let truncInfo = truncationInfo.map { " (+\($0.transfersOmitted) omitted)" } ?? ""
        return """
        WidgetTransfersData v\(schemaVersion):
          Transfers (\(transfers.count))\(truncInfo): \(fileNames.isEmpty ? "none" : fileNames)
          Active: \(activeCount)
          Aggregate Progress: \(String(format: "%.1f", aggregateProgress * 100))%
          Updated: \(lastUpdated)
        """
    }
    
    public var sanitizedDescription: String {
        "WidgetTransfersData v\(schemaVersion): \(transfers.count) transfers, \(activeCount) active"
    }
    
 // MARK: - Empty State
    
    public static let empty = WidgetTransfersData(transfers: [])
}
