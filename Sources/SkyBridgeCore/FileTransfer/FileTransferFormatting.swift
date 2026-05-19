import Foundation

extension FileTransfer {
  /// 格式化传输速度显示
  public var formattedSpeed: String {
    return formatSpeed(transferSpeed)
  }

  /// 格式化平均速度显示
  public var formattedAverageSpeed: String {
    return formatSpeed(averageSpeed)
  }

  /// 格式化峰值速度显示
  public var formattedPeakSpeed: String {
    return formatSpeed(peakSpeed)
  }

  /// 格式化剩余时间显示
  public var formattedTimeRemaining: String {
    return formatTimeInterval(estimatedTimeRemaining)
  }

  /// 格式化速度
  private func formatSpeed(_ speed: Double) -> String {
    if speed >= 1_000_000_000 {  // GB/s
      return String(format: "%.1f GB/s", speed / 1_000_000_000)
    } else if speed >= 1_000_000 {  // MB/s
      return String(format: "%.1f MB/s", speed / 1_000_000)
    } else if speed >= 1_000 {  // KB/s
      return String(format: "%.1f KB/s", speed / 1_000)
    } else {  // B/s
      return String(format: "%.0f B/s", speed)
    }
  }

  /// 格式化时间间隔
  private func formatTimeInterval(_ interval: TimeInterval) -> String {
    guard interval > 0 && interval.isFinite else { return "计算中..." }

    let hours = Int(interval) / 3600
    let minutes = Int(interval) % 3600 / 60
    let seconds = Int(interval) % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else if minutes > 0 {
      return String(format: "%d:%02d", minutes, seconds)
    } else {
      return String(format: "%d秒", seconds)
    }
  }
}
