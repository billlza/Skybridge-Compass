import Foundation
import CryptoKit
import Darwin

@available(macOS 14.0, iOS 17.0, *)
actor WebRTCOutboundFileReader {
    typealias PReadOperation = @Sendable (
        _ descriptor: Int32,
        _ buffer: UnsafeMutableRawPointer,
        _ count: Int,
        _ offset: off_t
    ) -> Int

    private struct DescriptorIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let owner: uid_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
    }

    nonisolated let fileSize: Int64
    private let handle: FileHandle
    private let identity: DescriptorIdentity
    private var hasher = SHA256()
    private var isClosed = false

    private init(descriptor: Int32, identity: DescriptorIdentity) {
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.identity = identity
        self.fileSize = Int64(identity.size)
    }

    static func open(url: URL) async throws -> WebRTCOutboundFileReader {
        let openTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let descriptor = url.withUnsafeFileSystemRepresentation { fileSystemPath in
                guard let fileSystemPath else { return Int32(-1) }
                return Darwin.open(fileSystemPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw WebRTCFileTransferWaitError.failed(
                    "无法安全打开本地文件（errno=\(errno)）"
                )
            }

            do {
                let identity = try descriptorIdentity(descriptor)
                try Task.checkCancellation()
                return WebRTCOutboundFileReader(
                    descriptor: descriptor,
                    identity: identity
                )
            } catch {
                let closeResult = Darwin.close(descriptor)
                if closeResult != 0 {
                    throw WebRTCFileTransferWaitError.failed(
                        "本地文件校验失败（\(error.localizedDescription)），且句柄关闭失败（errno=\(errno)）"
                    )
                }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await openTask.value
        } onCancel: {
            openTask.cancel()
        }
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        guard !isClosed, length > 0 else {
            throw WebRTCFileTransferWaitError.failed("文件读取器状态无效")
        }
        try Task.checkCancellation()
        guard offset <= UInt64(Int64.max),
              Int64(length) <= fileSize,
              Int64(offset) <= fileSize - Int64(length) else {
            throw WebRTCFileTransferWaitError.failed("文件读取范围超出已验证大小")
        }
        try validateUnchangedDescriptor()
        let data = try Self.readExactly(
            descriptor: handle.fileDescriptor,
            offset: offset,
            length: length
        )
        try validateUnchangedDescriptor()
        hasher.update(data: data)
        return data
    }

    func finalizeAndClose() throws -> Data {
        guard !isClosed else {
            throw WebRTCFileTransferWaitError.failed("文件读取器已关闭")
        }
        try validateUnchangedDescriptor()
        try handle.close()
        isClosed = true
        return Data(hasher.finalize())
    }

    func close() throws {
        guard !isClosed else { return }
        try handle.close()
        isClosed = true
    }

    nonisolated static func readExactly(
        descriptor: Int32,
        offset: UInt64,
        length: Int,
        readOperation: PReadOperation = { descriptor, buffer, count, offset in
            Darwin.pread(descriptor, buffer, count, offset)
        }
    ) throws -> Data {
        guard descriptor >= 0,
              length > 0,
              offset <= UInt64(Int64.max),
              UInt64(length) <= UInt64(Int64.max) - offset else {
            throw WebRTCFileTransferWaitError.failed("文件读取参数无效")
        }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw WebRTCFileTransferWaitError.failed("文件读取缓冲区不可用")
            }
            var totalRead = 0
            while totalRead < length {
                try Task.checkCancellation()
                let result = readOperation(
                    descriptor,
                    baseAddress.advanced(by: totalRead),
                    length - totalRead,
                    off_t(offset) + off_t(totalRead)
                )
                if result > 0 {
                    guard result <= length - totalRead else {
                        throw WebRTCFileTransferWaitError.failed("文件读取返回了无效长度")
                    }
                    totalRead += result
                    continue
                }
                if result < 0, errno == EINTR {
                    continue
                }
                if result == 0 {
                    throw WebRTCFileTransferWaitError.failed("文件在预期长度前结束")
                }
                throw WebRTCFileTransferWaitError.failed(
                    "文件读取失败（errno=\(errno)）"
                )
            }
            try Task.checkCancellation()
        }
        return data
    }

    private func validateUnchangedDescriptor() throws {
        let current = try Self.descriptorIdentity(handle.fileDescriptor)
        guard current == identity else {
            throw WebRTCFileTransferWaitError.failed("文件在传输期间发生变化")
        }
    }

    private nonisolated static func descriptorIdentity(
        _ descriptor: Int32
    ) throws -> DescriptorIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw WebRTCFileTransferWaitError.failed(
                "无法读取本地文件元数据（errno=\(errno)）"
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_ino > 0,
              metadata.st_size >= 0 else {
            throw WebRTCFileTransferWaitError.failed(
                "本地文件必须是当前用户拥有的单链接普通文件"
            )
        }
        return DescriptorIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            size: metadata.st_size,
            owner: metadata.st_uid,
            modificationSeconds: metadata.st_mtimespec.tv_sec,
            modificationNanoseconds: metadata.st_mtimespec.tv_nsec
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
