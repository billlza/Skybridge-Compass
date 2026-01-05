// MARK: - Widget Kinds
// Widget 类型和 Payload 映射
// Requirements: 1.3

import Foundation

/// 数据载荷类型（写入侧）
public enum WidgetPayloadKind: String, CaseIterable, Sendable {
    case devices
    case metrics
    case transfers
}

/// Widget 类型（刷新侧）
public enum WidgetKind: String, CaseIterable, Sendable {
    case deviceStatus = "DeviceStatusWidget"
    case systemMonitor = "SystemMonitorWidget"
    case fileTransfer = "FileTransferWidget"
}

/// Payload → Widget 映射表（单一真相源）
public let payloadToWidgetMapping: [WidgetPayloadKind: WidgetKind] = [
    .devices: .deviceStatus,
    .metrics: .systemMonitor,
    .transfers: .fileTransfer
]

/// 计算受影响的 widget kinds（类型安全）
/// - Parameters:
/// - changedPayloads: 发生变化的数据载荷类型集合
/// - schemaUpgraded: 是否发生了 schema 版本升级
/// - Returns: 需要刷新的 widget 类型集合
public func affectedKinds(
    changedPayloads: Set<WidgetPayloadKind>,
    schemaUpgraded: Bool = false
) -> Set<WidgetKind> {
    if schemaUpgraded {
        return Set(WidgetKind.allCases)  // 全部刷新
    }
    
    return Set(changedPayloads.compactMap { payloadToWidgetMapping[$0] })
}

// MARK: - 测试用例覆盖
// 1. 只有 devices → {deviceStatus}
// 2. devices + metrics → {deviceStatus, systemMonitor}
// 3. 全部变化 → {deviceStatus, systemMonitor, fileTransfer}
// 4. schemaUpgraded = true → ALL
// 5. 空集合 → {}
// 6. truncation only（devices 截断）→ {deviceStatus}
