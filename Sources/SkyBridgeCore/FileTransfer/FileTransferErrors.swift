import Foundation

/// 文件传输错误
public enum FileTransferError: Error, LocalizedError {
  case invalidHeader
  case inboundInvalidInitialHeader
  case integrityCheckFailed
  case transferCancelled
  case connectionClosed
  case inboundConnectionClosedBeforeMetadata
  case fileNotFound
  case timeout
  case receiptWaitFailed(stage: FileTransferReceiptWaitStage, details: String?)
  case receiverNotConfirmed
  case receiverRejected
  case secureSessionRequired
  case securityThreatDetected(threatName: String)
  case securityScanReviewRequired(warningCodes: [String])
  case securityScanIncomplete(verdict: ScanVerdict, warningCodes: [String])
  case partialFileCleanupFailed
  case sourceFileCloseFailed
  case committedFileReleaseFailed
  case resumeStatePersistenceFailed
  case resumeStateCleanupFailed
  case automaticResumeFailed
  case capacityExceeded
  case ambiguousTarget
  case invalidPort
  case deliveryConfirmationUnknown
  case invalidTransferState

  public var errorDescription: String? {
    switch self {
    case .invalidHeader:
      return "无效的协议头部"
    case .inboundInvalidInitialHeader:
      return "入站文件传输初始协议头无效"
    case .integrityCheckFailed:
      return "文件完整性检查失败"
    case .transferCancelled:
      return "传输已取消"
    case .connectionClosed:
      return "连接已关闭"
    case .inboundConnectionClosedBeforeMetadata:
      return "入站文件传输连接在元数据前关闭"
    case .fileNotFound:
      return "文件未找到"
    case .timeout:
      return "等待超时"
    case .receiptWaitFailed(let stage, let details):
      let suffix = details.map { ": \($0)" } ?? ""
      return "等待接收端落盘回执失败(\(stage.rawValue))\(suffix)"
    case .receiverNotConfirmed:
      return "接收端未确认文件已落盘"
    case .receiverRejected:
      return "接收端拒绝或处理失败"
    case .secureSessionRequired:
      return "经典文件传输需要已认证的安全会话"
    case .securityThreatDetected(let threatName):
      return "检测到安全威胁: \(threatName)"
    case .securityScanReviewRequired(let warningCodes):
      let codes = warningCodes.isEmpty ? "unspecified" : warningCodes.joined(separator: ",")
      return "文件扫描需要人工复核，自动接收已阻止（\(codes)）"
    case .securityScanIncomplete(let verdict, let warningCodes):
      let codes = warningCodes.isEmpty ? "unspecified" : warningCodes.joined(separator: ",")
      return "文件扫描未给出可自动放行的结论（verdict=\(verdict.rawValue), codes=\(codes)）"
    case .partialFileCleanupFailed:
      return "文件传输失败，且未完成文件清理失败"
    case .sourceFileCloseFailed:
      return "文件传输失败，且源文件关闭失败"
    case .committedFileReleaseFailed:
      return "文件已安全落盘，但入站文件句柄释放失败"
    case .resumeStatePersistenceFailed:
      return "断点续传状态保存失败"
    case .resumeStateCleanupFailed:
      return "断点续传状态清理失败"
    case .automaticResumeFailed:
      return "自动断点续传失败"
    case .capacityExceeded:
      return "文件传输并发等待队列已满"
    case .ambiguousTarget:
      return "检测到多个活跃目标设备，请先明确选择接收设备"
    case .invalidPort:
      return "文件传输端口必须位于 1...65535"
    case .deliveryConfirmationUnknown:
      return "文件数据已发送，但未收到落盘确认；为避免重复文件，系统不会自动重发"
    case .invalidTransferState:
      return "文件传输进入了无效的控制状态"
    }
  }
}
