import Combine
import Foundation

/// 文件传输对象
public class FileTransfer: ObservableObject, Identifiable {
  public let id: String
  public let fileName: String
  public let fileSize: Int64
  public let deviceId: String
  public let direction: TransferDirection
  public let createdAt: Date

  @Published public var status: TransferStatus = .preparing
  @Published public var progress: Double = 0.0
  @Published public var transferredBytes: Int64 = 0

  // 新增传输统计属性
  @Published public var transferSpeed: Double = 0.0  // 字节/秒
  @Published public var estimatedTimeRemaining: TimeInterval = 0.0  // 剩余时间（秒）
  @Published public var networkQuality: NetworkQuality = .unknown  // 网络质量
  @Published public var averageSpeed: Double = 0.0  // 平均传输速度
  @Published public var peakSpeed: Double = 0.0  // 峰值传输速度

  public var completedAt: Date?
  public var error: String?
  public var fileHash: String?
  public var localPath: URL?
  /// 压缩算法：nil/"" 表示不压缩；当前支持 "zlib"
  public var compression: String?

  // 扫描结果 - 用于 UI 显示扫描状态
  @Published public var scanResult: FileScanResult?

  // 断点续传支持 - 利用macOS 26.x的改进持久化
  public var deviceIPAddress: String?  // 设备IP地址
  public var devicePort: Int = 8080  // 设备端口
  public var deviceName: String?  // 设备名称
  public var resumeOffset: Int64 = 0  // 断点续传偏移量（已传输字节数）
  public var resumeDataPath: URL?  // 断点续传数据保存路径

  // 内部统计数据
  private var lastUpdateTime: Date = Date()
  private var lastTransferredBytes: Int64 = 0
  private var speedSamples: [Double] = []
  private let maxSpeedSamples = 10  // 保留最近10个速度样本用于平均值计算

  public init(
    id: String,
    fileName: String,
    fileSize: Int64,
    deviceId: String,
    direction: TransferDirection,
    status: TransferStatus,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.fileName = fileName
    self.fileSize = fileSize
    self.deviceId = deviceId
    self.direction = direction
    self.status = status
    self.createdAt = createdAt
    self.lastUpdateTime = createdAt
  }

  /// 更新传输进度和统计信息
  public func updateProgress(transferredBytes: Int64) {
    let now = Date()
    let timeDelta = now.timeIntervalSince(lastUpdateTime)
    let clampedBytes = max(0, min(transferredBytes, fileSize))

    // Keep the visible byte counters moving even when we throttle speed
    // statistics. Otherwise small/fast transfers can sit at 0% until the
    // receipt phase finishes.
    self.transferredBytes = clampedBytes
    if fileSize > 0 {
      self.progress = Double(clampedBytes) / Double(fileSize)
    } else {
      self.progress = 1.0
    }

    // 避免过于频繁的更新
    guard timeDelta >= 0.1 else { return }

    let bytesDelta = clampedBytes - lastTransferredBytes

    // 计算当前传输速度
    if timeDelta > 0 {
      let currentSpeed = Double(bytesDelta) / timeDelta
      self.transferSpeed = currentSpeed

      // 更新峰值速度
      if currentSpeed > peakSpeed {
        peakSpeed = currentSpeed
      }

      // 添加到速度样本中
      speedSamples.append(currentSpeed)
      if speedSamples.count > maxSpeedSamples {
        speedSamples.removeFirst()
      }

      // 计算平均速度
      if !speedSamples.isEmpty {
        averageSpeed = speedSamples.reduce(0, +) / Double(speedSamples.count)
      }
    }

    // 计算剩余时间
    if averageSpeed > 0 {
      let remainingBytes = fileSize - clampedBytes
      estimatedTimeRemaining = Double(remainingBytes) / averageSpeed
    }

    // 评估网络质量
    updateNetworkQuality()

    // 更新时间戳
    lastUpdateTime = now
    lastTransferredBytes = clampedBytes
  }

  /// 评估网络质量
  private func updateNetworkQuality() {
    guard !speedSamples.isEmpty else {
      networkQuality = .unknown
      return
    }

    let avgSpeed = averageSpeed
    let speedVariance = calculateSpeedVariance()

    // 基于平均速度和稳定性评估网络质量
    if avgSpeed > 10_000_000 && speedVariance < 0.3 {  // > 10MB/s 且稳定
      networkQuality = .excellent
    } else if avgSpeed > 5_000_000 && speedVariance < 0.5 {  // > 5MB/s 且较稳定
      networkQuality = .good
    } else if avgSpeed > 1_000_000 && speedVariance < 0.7 {  // > 1MB/s
      networkQuality = .fair
    } else if avgSpeed > 100_000 {  // > 100KB/s
      networkQuality = .poor
    } else {
      networkQuality = .veryPoor
    }
  }

  /// 计算速度方差（用于评估网络稳定性）
  private func calculateSpeedVariance() -> Double {
    guard speedSamples.count > 1 else { return 0.0 }

    let mean = averageSpeed
    let variance =
      speedSamples.reduce(0) { sum, speed in
        let diff = speed - mean
        return sum + (diff * diff)
      } / Double(speedSamples.count)

    return sqrt(variance) / mean  // 变异系数
  }

  /// 重置统计信息
  public func resetStatistics() {
    transferSpeed = 0.0
    estimatedTimeRemaining = 0.0
    networkQuality = .unknown
    averageSpeed = 0.0
    peakSpeed = 0.0
    speedSamples.removeAll()
    lastUpdateTime = Date()
    lastTransferredBytes = 0
  }
}

/// 网络质量枚举
public enum NetworkQuality: String, CaseIterable, Codable, Sendable {
  case excellent = "优秀"
  case good = "良好"
  case fair = "一般"
  case poor = "较差"
  case veryPoor = "很差"
  case unknown = "未知"

  /// 获取对应的颜色
  public var color: String {
    switch self {
    case .excellent:
      return "green"
    case .good:
      return "blue"
    case .fair:
      return "orange"
    case .poor:
      return "red"
    case .veryPoor:
      return "red"
    case .unknown:
      return "gray"
    }
  }

  /// 获取对应的图标
  public var icon: String {
    switch self {
    case .excellent:
      return "wifi"
    case .good:
      return "wifi"
    case .fair:
      return "wifi"
    case .poor:
      return "wifi.slash"
    case .veryPoor:
      return "wifi.slash"
    case .unknown:
      return "questionmark.circle"
    }
  }
}

/// 传输方向
public enum TransferDirection: String, CaseIterable, Codable, Sendable {
  case incoming = "接收"
  case outgoing = "发送"
}

/// 传输状态
public enum TransferStatus: String, CaseIterable, Codable, Sendable {
  case preparing = "准备中"
  case transferring = "传输中"
  case paused = "已暂停"
  case completed = "已完成"
  case failed = "失败"
  case cancelled = "已取消"
}
