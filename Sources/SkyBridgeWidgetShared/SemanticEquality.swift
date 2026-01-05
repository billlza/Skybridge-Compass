// MARK: - Semantic Equality
// 语义等价判定函数（用于 round-trip property test）
// Requirements: 5.5

import Foundation

// MARK: - WidgetDeviceInfo

extension WidgetDeviceInfo {
 /// 语义等价判定
 /// - Date: 允许 ±1s（ISO8601 秒级精度）
    public func semanticEquals(_ other: WidgetDeviceInfo) -> Bool {
        id == other.id &&
        name == other.name &&
        deviceType == other.deviceType &&
        isOnline == other.isOnline &&
        abs(lastSeen.timeIntervalSince(other.lastSeen)) <= 1.0 &&
        ipAddress == other.ipAddress
    }
}

// MARK: - WidgetSystemMetrics

extension WidgetSystemMetrics {
 /// 语义等价判定
 /// - Double: cpu/mem ±0.1, network ±100 bytes/s
    public func semanticEquals(_ other: WidgetSystemMetrics) -> Bool {
        abs(cpuUsage - other.cpuUsage) < 0.1 &&
        abs(memoryUsage - other.memoryUsage) < 0.1 &&
        abs(networkUpload - other.networkUpload) < 100 &&
        abs(networkDownload - other.networkDownload) < 100
    }
}

// MARK: - WidgetTransferInfo

extension WidgetTransferInfo {
 /// 语义等价判定
 /// - progress: clamped 后比较，允许 ±0.001
    public func semanticEquals(_ other: WidgetTransferInfo) -> Bool {
        id == other.id &&
        fileName == other.fileName &&
        abs(progress - other.progress) < 0.001 &&
        totalBytes == other.totalBytes &&
        transferredBytes == other.transferredBytes &&
        isUpload == other.isUpload &&
        deviceName == other.deviceName
    }
}

// MARK: - WidgetDevicesData

extension WidgetDevicesData {
 /// 语义等价判定
 /// - arrays: 按 id 排序后逐项比较
    public func semanticEquals(_ other: WidgetDevicesData) -> Bool {
        guard schemaVersion == other.schemaVersion else { return false }
        guard abs(lastUpdated.timeIntervalSince(other.lastUpdated)) <= 1.0 else { return false }
        guard truncationInfo == other.truncationInfo else { return false }
        
 // devices: 按 id 排序后逐项比较
        let sortedSelf = devices.sorted { $0.id < $1.id }
        let sortedOther = other.devices.sorted { $0.id < $1.id }
        guard sortedSelf.count == sortedOther.count else { return false }
        
        for (a, b) in zip(sortedSelf, sortedOther) {
            guard a.semanticEquals(b) else { return false }
        }
        
        return true
    }
}

// MARK: - WidgetMetricsData

extension WidgetMetricsData {
 /// 语义等价判定
    public func semanticEquals(_ other: WidgetMetricsData) -> Bool {
        guard schemaVersion == other.schemaVersion else { return false }
        guard abs(lastUpdated.timeIntervalSince(other.lastUpdated)) <= 1.0 else { return false }
        guard metrics.semanticEquals(other.metrics) else { return false }
        return true
    }
}

// MARK: - WidgetTransfersData

extension WidgetTransfersData {
 /// 语义等价判定
 /// - arrays: 按 id 排序后逐项比较
    public func semanticEquals(_ other: WidgetTransfersData) -> Bool {
        guard schemaVersion == other.schemaVersion else { return false }
        guard abs(lastUpdated.timeIntervalSince(other.lastUpdated)) <= 1.0 else { return false }
        guard truncationInfo == other.truncationInfo else { return false }
        
 // transfers: 按 id 排序后逐项比较
        let sortedSelf = transfers.sorted { $0.id < $1.id }
        let sortedOther = other.transfers.sorted { $0.id < $1.id }
        guard sortedSelf.count == sortedOther.count else { return false }
        
        for (a, b) in zip(sortedSelf, sortedOther) {
            guard a.semanticEquals(b) else { return false }
        }
        
        return true
    }
}
