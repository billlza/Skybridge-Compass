// MARK: - Metrics Formatter
// 系统指标格式化工具
// **Feature: macos-widgets, Property 5: System Metrics Formatting**
// **Validates: Requirements 3.1, 3.2, 3.3**

import Foundation

/// 系统指标格式化工具
public enum MetricsFormatter {
    
 // MARK: - Percentage Formatting
    
 /// 格式化百分比值
 /// - Parameter value: 百分比值 (0-100)
 /// - Returns: 格式化字符串，包含值和 % 后缀
    public static func formatPercentage(_ value: Double) -> String {
        let clamped = value.clamped(to: 0...100)
        return String(format: "%.1f%%", clamped)
    }
    
 /// 格式化百分比值（整数）
 /// - Parameter value: 百分比值 (0-100)
 /// - Returns: 格式化字符串，包含整数值和 % 后缀
    public static func formatPercentageInt(_ value: Double) -> String {
        let clamped = value.clamped(to: 0...100)
        return String(format: "%.0f%%", clamped)
    }
    
 // MARK: - Bytes Formatting
    
 /// 格式化字节数
 /// - Parameter bytes: 字节数
 /// - Returns: 格式化字符串，包含值和适当的单位后缀 (B/KB/MB/GB)
    public static func formatBytes(_ bytes: Double) -> String {
        let absBytes = abs(bytes)
        
        if absBytes >= 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        } else if absBytes >= 1_000_000 {
            return String(format: "%.1f MB", bytes / 1_000_000)
        } else if absBytes >= 1_000 {
            return String(format: "%.1f KB", bytes / 1_000)
        } else {
            return String(format: "%.0f B", bytes)
        }
    }
    
 /// 格式化字节速率
 /// - Parameter bytesPerSecond: 每秒字节数
 /// - Returns: 格式化字符串，包含值和适当的单位后缀 (B/s, KB/s, MB/s, GB/s)
    public static func formatBytesPerSecond(_ bytesPerSecond: Double) -> String {
        let absBytes = abs(bytesPerSecond)
        
        if absBytes >= 1_000_000_000 {
            return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        } else if absBytes >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if absBytes >= 1_000 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_000)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }
    
 // MARK: - Metrics Formatting
    
 /// 格式化 CPU 使用率
 /// - Parameter metrics: 系统指标
 /// - Returns: 格式化字符串
    public static func formatCPU(_ metrics: WidgetSystemMetrics) -> String {
        formatPercentage(metrics.cpuUsage)
    }
    
 /// 格式化内存使用率
 /// - Parameter metrics: 系统指标
 /// - Returns: 格式化字符串
    public static func formatMemory(_ metrics: WidgetSystemMetrics) -> String {
        formatPercentage(metrics.memoryUsage)
    }
    
 /// 格式化网络上传速率
 /// - Parameter metrics: 系统指标
 /// - Returns: 格式化字符串
    public static func formatNetworkUpload(_ metrics: WidgetSystemMetrics) -> String {
        formatBytesPerSecond(metrics.networkUpload)
    }
    
 /// 格式化网络下载速率
 /// - Parameter metrics: 系统指标
 /// - Returns: 格式化字符串
    public static func formatNetworkDownload(_ metrics: WidgetSystemMetrics) -> String {
        formatBytesPerSecond(metrics.networkDownload)
    }
}
