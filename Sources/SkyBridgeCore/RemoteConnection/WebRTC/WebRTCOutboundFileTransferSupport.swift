import Foundation

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCFileTransferWaitError: LocalizedError, Sendable {
    case timeout
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "跨网文件传输等待超时"
        case .cancelled:
            return "跨网文件传输已取消"
        case .failed(let msg):
            return "跨网文件传输失败: \(msg)"
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCOutboundFileTransferSupport {
    static let dataChannelChunkSize = 16 * 1024

    static func waiterKey(
        sessionID: String,
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int?
    ) -> String {
        let idx = chunkIndex ?? -1
        return "\(sessionID)|\(transferId)|\(op.rawValue)|\(idx)"
    }

    static func waiterPrefix(sessionID: String, transferId: String) -> String {
        "\(sessionID)|\(transferId)|"
    }

    static func sessionWaiterPrefix(sessionID: String) -> String {
        "\(sessionID)|"
    }

    static func totalChunks(fileSize: Int64, chunkSize: Int = dataChannelChunkSize) -> Int? {
        guard fileSize > 0, chunkSize > 0 else { return nil }
        let total = ((fileSize - 1) / Int64(chunkSize)) + 1
        guard total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    static func validateCompletionAck(
        _ ack: CrossNetworkFileTransferMessage,
        expectedFileSize: Int64,
        expectedFileSha256: Data
    ) throws {
        guard ack.receivedBytes == expectedFileSize else {
            throw WebRTCFileTransferWaitError.failed(
                "接收端落盘字节数不一致: \(ack.receivedBytes ?? -1)/\(expectedFileSize)"
            )
        }
        guard ack.fileSha256 == expectedFileSha256 else {
            throw WebRTCFileTransferWaitError.failed("接收端落盘哈希不一致或缺少哈希回执")
        }
    }
}
