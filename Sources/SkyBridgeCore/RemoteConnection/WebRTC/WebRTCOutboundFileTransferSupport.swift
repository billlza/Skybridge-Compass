import Foundation
import CryptoKit
import Darwin
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
actor WebRTCOutboundFileReader {
    typealias PReadOperation = PreparedOutboundFileReadSession.PReadOperation
    nonisolated let fileSize: Int64
    nonisolated let selectedContentSHA256: Data
    private let source: PreparedOutboundFileReadSession
    private var bytesRead: Int64 = 0
    private var readInFlight = false
    private var closingTask: Task<Void, Error>?

    private init(source: PreparedOutboundFileReadSession) {
        self.source = source
        fileSize = source.metadata.fileSize
        selectedContentSHA256 = source.metadata.contentSHA256
    }

    static func open(
        url: URL,
        validateLifetime: @escaping @Sendable () async throws -> Void = { try Task.checkCancellation() }
    ) async throws -> WebRTCOutboundFileReader {
        let source = try await PreparedOutboundFileReadSession.prepare(
            url: url, maximumSize: WebRTCInboundFileTransferSupport.maxFileSize,
            sourcePolicy: .ownedSingleLinkStableMetadata, validateLifetime: validateLifetime
        )
        return WebRTCOutboundFileReader(source: source)
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        guard closingTask == nil, !readInFlight, offset == UInt64(bytesRead) else {
            throw WebRTCFileTransferWaitError.failed("文件读取器状态或顺序无效")
        }
        readInFlight = true
        defer { readInFlight = false }
        let data = try await source.read(offset: offset, length: length)
        guard closingTask == nil else {
            throw WebRTCFileTransferWaitError.failed("文件读取器已关闭")
        }
        bytesRead += Int64(data.count)
        return data
    }

    func finalizeAndClose() async throws -> Data {
        guard closingTask == nil, !readInFlight, bytesRead == fileSize else {
            throw WebRTCFileTransferWaitError.failed("文件读取尚未完整结束")
        }
        try await source.validateSourceIdentity()
        try await close()
        return selectedContentSHA256
    }

    func close() async throws {
        if let closingTask { return try await closingTask.value }
        let source = self.source
        let task = Task { try await source.close() }
        closingTask = task
        do { try await task.value }
        catch {
            closingTask = nil // Retain the failure and allow an explicit cleanup retry.
            throw error
        }
    }

    nonisolated static func readExactly(
        descriptor: Int32,
        offset: UInt64,
        length: Int,
        readOperation: PReadOperation = { descriptor, buffer, count, offset in
            Darwin.pread(descriptor, buffer, count, offset)
        }
    ) throws -> Data {
        guard offset <= UInt64(Int64.max) else {
            throw WebRTCFileTransferWaitError.failed("文件读取参数无效")
        }
        return try PreparedOutboundFileReadSession.readExactly(
            descriptor, offset: Int64(offset), length: length, readOperation: readOperation
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCFileTransferWaitError: LocalizedError, Sendable {
    case timeout
    case cancelled
    case remoteRejected(String)
    case transportClosed(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "跨网文件传输等待超时"
        case .cancelled:
            return "跨网文件传输已取消"
        case .remoteRejected(let msg):
            return "接收端拒绝跨网文件传输: \(msg)"
        case .transportClosed(let msg):
            return "跨网文件传输通道已关闭: \(msg)"
        case .failed(let msg):
            return "跨网文件传输失败: \(msg)"
        }
    }
}

@MainActor
final class WebRTCOutboundFileTransferCancellationFlag {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    func check() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct WebRTCOutboundFileTransferWaiterKey: Hashable, Sendable {
    let sessionID: String
    let transferID: String
    let operation: String
    let chunkIndex: Int?

    init(
        sessionID: String,
        transferID: String,
        operation: CrossNetworkFileTransferOp,
        chunkIndex: Int?
    ) {
        self.sessionID = sessionID
        self.transferID = transferID
        self.operation = operation.rawValue
        self.chunkIndex = chunkIndex
    }
}

@available(macOS 14.0, iOS 17.0, *)
enum WebRTCOutboundFileTransferSupport {
    static let dataChannelChunkSize = 16 * 1024

    static func dataChannelChunkSize(forFileSize fileSize: Int64) -> Int? {
        guard fileSize >= 0,
              fileSize <= WebRTCInboundFileTransferSupport.maxFileSize else {
            return nil
        }
        if fileSize == 0 { return dataChannelChunkSize }
        let maximumChunks = Int64(WebRTCInboundFileTransferSupport.maxTotalChunks)
        let minimumChunkSize = (fileSize + maximumChunks - 1) / maximumChunks
        let granularity = Int64(dataChannelChunkSize)
        let roundedChunkSize = ((minimumChunkSize + granularity - 1) / granularity) * granularity
        let selected = max(Int64(dataChannelChunkSize), roundedChunkSize)
        guard selected <= Int64(WebRTCInboundFileTransferSupport.maxChunkSize) else {
            return nil
        }
        return Int(selected)
    }

    static func shouldRetryChunkAcknowledgment(after error: Error) -> Bool {
        guard let waitError = error as? WebRTCFileTransferWaitError else {
            return false
        }
        if case .timeout = waitError {
            return true
        }
        return false
    }

    static func waiterKey(
        sessionID: String,
        transferId: String,
        op: CrossNetworkFileTransferOp,
        chunkIndex: Int?
    ) -> WebRTCOutboundFileTransferWaiterKey {
        WebRTCOutboundFileTransferWaiterKey(
            sessionID: sessionID,
            transferID: transferId,
            operation: op,
            chunkIndex: chunkIndex
        )
    }

    static func totalChunks(fileSize: Int64, chunkSize: Int = dataChannelChunkSize) -> Int? {
        guard fileSize >= 0, chunkSize > 0 else { return nil }
        if fileSize == 0 { return 0 }
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

    static func validateChunkAck(
        _ ack: CrossNetworkFileTransferMessage,
        expectedReceivedBytes: Int64
    ) throws {
        guard ack.receivedBytes == expectedReceivedBytes else {
            throw WebRTCFileTransferWaitError.failed(
                "接收端分块累计字节数不一致: \(ack.receivedBytes ?? -1)/\(expectedReceivedBytes)"
            )
        }
    }

    /// Normalizes only the terminal commit-confirmation phase. Metadata and
    /// chunk failures must never be classified as a possibly committed file.
    static func normalizedCompletionWaitError(_ error: Error) -> Error {
        if error is CancellationError {
            // The terminal frame may already have reached the receiver and caused
            // an atomic commit before local cancellation interrupted its ACK wait.
            return FileTransferError.deliveryConfirmationUnknown
        }
        guard let waitError = error as? WebRTCFileTransferWaitError else {
            return FileTransferError.deliveryConfirmationUnknown
        }
        switch waitError {
        case .cancelled:
            return waitError
        case .remoteRejected:
            return waitError
        case .timeout, .transportClosed:
            return FileTransferError.deliveryConfirmationUnknown
        case .failed:
            return waitError
        }
    }
}
