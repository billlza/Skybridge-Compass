import Foundation
import Combine
import CryptoKit
import Compression
#if canImport(Starscream)
import Starscream
#endif
import os.log
import UserNotifications

/// 文件传输管理器 - 遵循 macOS 最佳实践和 Swift 6.2 并发安全
@MainActor
public final class FileTransferManager: NSObject {
    private let session: URLSession
    private let queue = OperationQueue()
    private let subject = CurrentValueSubject<[FileTransferTask], Never>([])
    #if canImport(Starscream)
    private var sockets: [UUID: WebSocket] = [:]
    #else
    private var sockets: [UUID: Any] = [:]
    #endif
    private let log = Logger(subsystem: "com.skybridge.compass", category: "FileTransfer")
    
    // 在非 .app 打包场景下，直接访问 UNUserNotificationCenter 会触发崩溃。
    // 这里根据 Bundle 是否具有有效标识来安全地创建通知中心实例。
    private let notificationCenter: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()
    private var completedTaskIDs = Set<UUID>()

    public var transfers: AnyPublisher<[FileTransferTask], Never> { subject.eraseToAnyPublisher() }

    public override init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.skybridge.compass.transfer")
        configuration.allowsExpensiveNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
        super.init()
        queue.maxConcurrentOperationCount = 4
        
        // 注册后台处理器，使用 Sendable 闭包
        BackgroundTaskCoordinator.shared.register { [weak self] completion in
            Task { @MainActor in
                await self?.resumePendingTransfers()
                completion()
            }
        }
    }

    /// 准备文件传输管理器
    public func prepare() async {
        // 使用异步方式注册系统任务
        await Task { @MainActor in
            BackgroundTaskCoordinator.shared.registerSystemTasks()
            BackgroundTaskCoordinator.shared.schedule()
        }.value
        log.info("FileTransferManager 已准备就绪")
    }

    public func stop() {
        subject.send([])
        #if canImport(Starscream)
        sockets.values.forEach { $0.disconnect() }
        #endif
        sockets.removeAll()
        completedTaskIDs.removeAll()
    }

    /// 开始上传文件
    public func startUpload(url: URL, to destination: URL) async {
        do {
            let tenant = try await TenantAccessController.shared.requirePermission(.fileTransfer)
            var request = URLRequest(url: destination)
            request.httpMethod = "PUT"
            request.addValue(tenant.displayName, forHTTPHeaderField: "X-SkyBridge-Tenant")
            let task = session.uploadTask(with: request, fromFile: url)
            task.resume()
        } catch {
            log.error("上传失败：租户缺少文件传输权限")
        }
    }

    /// 开始实时通道连接
    public func startRealtimeChannel(endpoint: URL) async {
        do {
            let tenant = try await TenantAccessController.shared.requirePermission(.fileTransfer)
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 5
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue(tenant.id.uuidString, forHTTPHeaderField: "X-SkyBridge-Tenant-ID")
            #if canImport(Starscream)
            let socket = WebSocket(request: request)
            let identifier = UUID()
            sockets[identifier] = socket
            socket.onEvent = { [weak self] event in
                Task { @MainActor in
                    self?.handle(event: event, id: identifier)
                }
            }
            socket.connect()
            #endif
        } catch {
            log.error("实时通道连接失败：租户缺少文件传输权限")
        }
    }

    #if canImport(Starscream)
    private func handle(event: WebSocketEvent, id: UUID) {
        switch event {
        case .connected(let headers):
            log.info("WebSocket connected \(headers.description)")
        case .disconnected(let reason, let code):
            log.info("WebSocket disconnected reason=\(reason) code=\(code)")
            sockets[id]?.disconnect()
            sockets.removeValue(forKey: id)
        case .binary(let data):
            processIncoming(data: data)
        case .text(let string):
            log.debug("Received text \(string)")
        case .error(let error):
            log.error("Socket error \(error?.localizedDescription ?? "unknown")")
        default:
            break
        }
    }
    #endif

    private func processIncoming(data: Data) {
        guard let header = try? JSONDecoder().decode(TransferHeader.self, from: data) else { return }
        let decompressed = decompress(data: header.payload)
        let decrypted = decrypt(data: decompressed, using: header.key)
        log.info("Received file chunk \(header.fileName)")
        updateProgress(for: header, bytes: decrypted.count)
    }

    private func decompress(data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        return data.withUnsafeBytes { inputBuffer in
            let destinationBufferSize = max(256, 4 * data.count)
            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
            defer { destinationBuffer.deallocate() }
            let decodedSize = compression_decode_buffer(destinationBuffer, destinationBufferSize, inputBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            guard decodedSize > 0 else { return data }
            return Data(bytes: destinationBuffer, count: decodedSize)
        }
    }

    private func decrypt(data: Data, using key: SymmetricKeyData) -> Data {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: data) else { return data }
        let key = SymmetricKey(data: key.raw)
        let decrypted = try? AES.GCM.open(sealedBox, using: key)
        return decrypted ?? Data()
    }

    private func updateProgress(for header: TransferHeader, bytes: Int) {
        var tasks = subject.value
        if let index = tasks.firstIndex(where: { $0.id == header.id }) {
            var task = tasks[index]
            let totalBytes = max(header.totalBytes, 1)
            let accumulated = min(Double(header.receivedBytes + bytes) / Double(totalBytes), 1)
            task = FileTransferTask(id: task.id, fileName: task.fileName, progress: accumulated, throughputMbps: header.throughputMbps, remainingTime: header.eta)
            tasks[index] = task
        } else {
            let task = FileTransferTask(id: header.id, fileName: header.fileName, progress: Double(header.receivedBytes) / Double(max(header.totalBytes, 1)), throughputMbps: header.throughputMbps, remainingTime: header.eta)
            tasks.append(task)
        }
        subject.send(tasks)
        if let task = tasks.first(where: { $0.id == header.id }), task.progress >= 0.999, !completedTaskIDs.contains(task.id) {
            completedTaskIDs.insert(task.id)
            postCompletionNotification(for: task)
        }
    }

    /// 恢复待处理的传输任务
    private func resumePendingTransfers() async {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                tasks.forEach { $0.resume() }
                self.log.debug("Resumed \(tasks.count) background transfers")
                continuation.resume()
            }
        }
    }

    /// 发送传输完成通知
    private func postCompletionNotification(for task: FileTransferTask) {
        // 检查租户权限
        Task {
            do {
                _ = try await TenantAccessController.shared.requirePermission(.notifications)
            } catch {
                log.info("跳过通知：租户缺少通知权限")
                return
            }
            
            guard let notificationCenter else {
                log.info("跳过通知：UNUserNotificationCenter 不可用（缺少 bundle identifier）")
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = "文件传输完成"
            content.body = "\(task.fileName) 已经成功同步"
            let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
            
            do {
                try await notificationCenter.add(request)
                log.info("成功发送传输完成通知")
            } catch {
                log.error("发送通知失败：\(error.localizedDescription)")
            }
        }
    }
}

private struct TransferHeader: Decodable {
    let id: UUID
    let fileName: String
    let totalBytes: Int
    let receivedBytes: Int
    let throughputMbps: Double
    let eta: TimeInterval
    let key: SymmetricKeyData
    let payload: Data
}

struct SymmetricKeyData: Decodable {
    let raw: Data
}
