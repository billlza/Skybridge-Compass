import Foundation
import Combine
import CryptoKit
import Compression
import Starscream
import os.log
import UserNotifications

public final class FileTransferManager: NSObject {
    private let session: URLSession
    private let queue = OperationQueue()
    private let subject = CurrentValueSubject<[FileTransferTask], Never>([])
    private var sockets: [UUID: WebSocket] = [:]
    private let log = Logger(subsystem: "com.skybridge.compass", category: "FileTransfer")
    private let backgroundCoordinator = BackgroundTaskCoordinator.shared
    private let tenantController = TenantAccessController.shared
    private let notificationCenter = UNUserNotificationCenter.current()
    private var completedTaskIDs = Set<UUID>()

    public var transfers: AnyPublisher<[FileTransferTask], Never> { subject.eraseToAnyPublisher() }

    public override init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.skybridge.compass.transfer")
        configuration.allowsExpensiveNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
        super.init()
        queue.maxConcurrentOperationCount = 4
        backgroundCoordinator.register { [weak self] completion in
            self?.resumePendingTransfers()
            completion()
        }
    }

    public func prepare() {
        backgroundCoordinator.registerSystemTasks()
        backgroundCoordinator.schedule()
        log.info("FileTransferManager ready")
    }

    public func stop() {
        subject.send([])
        sockets.values.forEach { $0.disconnect() }
        sockets.removeAll()
        completedTaskIDs.removeAll()
    }

    public func startUpload(url: URL, to destination: URL) {
        guard let tenant = try? tenantController.requirePermission(.fileTransfer) else {
            log.error("Active tenant missing file transfer permission")
            return
        }
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.addValue(tenant.displayName, forHTTPHeaderField: "X-SkyBridge-Tenant")
        let task = session.uploadTask(with: request, fromFile: url)
        task.resume()
    }

    public func startRealtimeChannel(endpoint: URL) {
        guard let tenant = try? tenantController.requirePermission(.fileTransfer) else {
            log.error("Active tenant missing file transfer permission")
            return
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(tenant.id.uuidString, forHTTPHeaderField: "X-SkyBridge-Tenant-ID")
        let socket = WebSocket(request: request)
        let identifier = UUID()
        sockets[identifier] = socket
        socket.onEvent = { [weak self] event in
            self?.handle(event: event, id: identifier)
        }
        socket.connect()
    }

    private func handle(event: WebSocketEvent, id: UUID) {
        switch event {
        case .connected(let headers):
            log.info("WebSocket connected %{public}@", headers.description)
        case .disconnected(let reason, let code):
            log.info("WebSocket disconnected %{public}@ %d", reason, code)
            sockets[id]?.disconnect()
            sockets.removeValue(forKey: id)
        case .binary(let data):
            processIncoming(data: data)
        case .text(let string):
            log.debug("Received text %{public}@", string)
        case .error(let error):
            log.error("Socket error %{public}@", error?.localizedDescription ?? "unknown")
        default:
            break
        }
    }

    private func processIncoming(data: Data) {
        guard let header = try? JSONDecoder().decode(TransferHeader.self, from: data) else { return }
        let decompressed = decompress(data: header.payload)
        let decrypted = decrypt(data: decompressed, using: header.key)
        log.info("Received file chunk %{public}@", header.fileName)
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

    private func resumePendingTransfers() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.resume() }
            self.log.debug("Resumed %d background transfers", tasks.count)
        }
    }

    private func postCompletionNotification(for task: FileTransferTask) {
        guard (try? tenantController.requirePermission(.notifications)) != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "文件传输完成"
        content.body = "\(task.fileName) 已经成功同步"
        let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
        notificationCenter.add(request) { error in
            if let error {
                self.log.error("Failed to schedule notification: %{public}@", error.localizedDescription)
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
