import Foundation

/// 文件传输错误
public enum FileTransferError: Error, LocalizedError {
  case invalidHeader
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

  public var errorDescription: String? {
    switch self {
    case .invalidHeader:
      return "无效的协议头部"
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
    }
  }
}
