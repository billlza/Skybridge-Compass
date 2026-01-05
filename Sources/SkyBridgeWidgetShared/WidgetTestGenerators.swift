// MARK: - Widget Test Generators
// 测试数据生成器 - 受控随机生成，避免无意义噪声
// Requirements: Testing infrastructure

import Foundation

/// 测试数据生成器
public enum WidgetTestGenerators {
    
 // MARK: - Basic Types
    
 /// 生成有效的设备 ID（UUID 格式）
    public static func deviceId() -> String {
        UUID().uuidString
    }
    
 /// 生成有效的设备名称（避免超长/特殊字符）
    public static func deviceName(maxLength: Int = 32) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -_"
        let length = Int.random(in: 1...min(maxLength, 32))
        return String((0..<length).map { _ in chars.randomElement()! })
    }
    
 /// 生成有效的文件名（避免非法路径字符）
    public static func fileName(maxLength: Int = 64) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        let length = Int.random(in: 1...min(maxLength, 60))
        let name = String((0..<length).map { _ in chars.randomElement()! })
        let extensions = ["txt", "pdf", "jpg", "png", "zip", "mp4", "doc", "xlsx"]
        return "\(name).\(extensions.randomElement()!)"
    }
    
 /// 生成有效的百分比值（0-100）
    public static func percentage() -> Double {
        Double.random(in: 0...100)
    }
    
 /// 生成有效的进度值（0-1）
    public static func progress() -> Double {
        Double.random(in: 0...1)
    }
    
 /// 生成有效的字节数
    public static func bytes(max: Int64 = 10_000_000_000) -> Int64 {
        Int64.random(in: 0...max)
    }
    
 /// 生成有效的 IP 地址（可能为 nil）
    public static func ipAddress() -> String? {
        Bool.random() ? "\(Int.random(in: 1...255)).\(Int.random(in: 0...255)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))" : nil
    }
    
 /// 生成有效的日期（最近 30 天内）
    public static func recentDate() -> Date {
        Date().addingTimeInterval(-Double.random(in: 0...(30 * 24 * 60 * 60)))
    }
    
 // MARK: - Model Types
    
 /// 生成随机 WidgetDeviceType
    public static func deviceType() -> WidgetDeviceType {
        WidgetDeviceType.allCases.randomElement()!
    }
    
 /// 生成随机 WidgetDeviceInfo
    public static func deviceInfo() -> WidgetDeviceInfo {
        WidgetDeviceInfo(
            id: deviceId(),
            name: deviceName(),
            deviceType: deviceType(),
            isOnline: Bool.random(),
            lastSeen: recentDate(),
            ipAddress: ipAddress()
        )
    }
    
 /// 生成随机 WidgetTransferInfo
    public static func transferInfo() -> WidgetTransferInfo {
        let total = bytes(max: 1_000_000_000)
        let transferred = Int64.random(in: 0...max(1, total))
        let prog = total > 0 ? Double(transferred) / Double(total) : 0
        
        return WidgetTransferInfo(
            id: deviceId(),
            fileName: fileName(),
            progress: prog,
            totalBytes: total,
            transferredBytes: transferred,
            isUpload: Bool.random(),
            deviceName: deviceName()
        )
    }
    
 /// 生成随机 WidgetSystemMetrics
    public static func systemMetrics() -> WidgetSystemMetrics {
        WidgetSystemMetrics(
            cpuUsage: percentage(),
            memoryUsage: percentage(),
            networkUpload: Double(bytes(max: 100_000_000)),
            networkDownload: Double(bytes(max: 100_000_000))
        )
    }
    
 /// 生成随机 WidgetDevicesData
    public static func devicesData(
        deviceCount: Int? = nil,
        includeOnline: Bool = true,
        includeOffline: Bool = true
    ) -> WidgetDevicesData {
        let count = deviceCount ?? Int.random(in: 0...10)
        var devices: [WidgetDeviceInfo] = []
        
        for _ in 0..<count {
            var device = deviceInfo()
            if !includeOnline && device.isOnline {
                device = WidgetDeviceInfo(
                    id: device.id, name: device.name, deviceType: device.deviceType,
                    isOnline: false, lastSeen: device.lastSeen, ipAddress: device.ipAddress
                )
            }
            if !includeOffline && !device.isOnline {
                device = WidgetDeviceInfo(
                    id: device.id, name: device.name, deviceType: device.deviceType,
                    isOnline: true, lastSeen: device.lastSeen, ipAddress: device.ipAddress
                )
            }
            devices.append(device)
        }
        
        return WidgetDevicesData(devices: devices)
    }
    
 /// 生成随机 WidgetMetricsData
    public static func metricsData() -> WidgetMetricsData {
        WidgetMetricsData(metrics: systemMetrics())
    }
    
 /// 生成随机 WidgetTransfersData
    public static func transfersData(
        transferCount: Int? = nil,
        includeActive: Bool = true,
        includeCompleted: Bool = true
    ) -> WidgetTransfersData {
        let count = transferCount ?? Int.random(in: 0...5)
        var transfers: [WidgetTransferInfo] = []
        
        for _ in 0..<count {
            var transfer = transferInfo()
            if !includeActive && transfer.isActive {
                transfer = WidgetTransferInfo(
                    id: transfer.id, fileName: transfer.fileName, progress: 1.0,
                    totalBytes: transfer.totalBytes, transferredBytes: transfer.totalBytes,
                    isUpload: transfer.isUpload, deviceName: transfer.deviceName
                )
            }
            if !includeCompleted && !transfer.isActive {
                transfer = WidgetTransferInfo(
                    id: transfer.id, fileName: transfer.fileName, progress: 0.5,
                    totalBytes: transfer.totalBytes, transferredBytes: transfer.totalBytes / 2,
                    isUpload: transfer.isUpload, deviceName: transfer.deviceName
                )
            }
            transfers.append(transfer)
        }
        
        return WidgetTransfersData(transfers: transfers)
    }
    
 // MARK: - Batch Generation
    
 /// 生成多个随机设备
    public static func devices(count: Int) -> [WidgetDeviceInfo] {
        (0..<count).map { _ in deviceInfo() }
    }
    
 /// 生成多个随机传输
    public static func transfers(count: Int) -> [WidgetTransferInfo] {
        (0..<count).map { _ in transferInfo() }
    }
}
