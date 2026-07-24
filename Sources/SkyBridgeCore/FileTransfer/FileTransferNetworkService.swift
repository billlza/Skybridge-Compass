import Foundation
import Network
import OSLog
import Combine

/// 文件传输网络服务 - 负责建立和管理文件传输的网络连接
@MainActor
public class FileTransferNetworkService: NSObject, ObservableObject {

 // MARK: - 发布的属性
    @Published public var isListening = false
    @Published public var activeConnections: [String: NWConnection] = [:]
    @Published public var connectionRequests: [FileTransferConnectionRequest] = []

 // MARK: - 私有属性
    private let logger = Logger(subsystem: "com.skybridge.transfer", category: "Network")
    private var listener: NWListener?
    private let serviceType = "_skybridge-transfer._tcp"
    private let serviceDomain = "local."
    private var netService: NetService?
    private var cancellables = Set<AnyCancellable>()

 // 连接管理
    private let connectionQueue = DispatchQueue(label: "file-transfer-connections", qos: .userInitiated)
    private let maxConcurrentConnections = 5

    private struct PendingConnectionAttempt {
        let connection: NWConnection
        let deviceId: String
        let deviceName: String
        let continuation: CheckedContinuation<NWConnection, Error>
    }

    private var pendingConnectionAttempts: [UUID: PendingConnectionAttempt] = [:]
    private var outboundDeviceIDByConnectionKey: [String: String] = [:]

    public override init() {
        logger.info("📡 初始化文件传输网络服务")
    }

 // MARK: - 公共方法

 /// 启动文件传输服务监听
    public func startListening() throws {
        guard !isListening else { return }

        logger.info("🚀 启动文件传输服务监听")

 // 创建TCP监听器
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }

        listener = try NWListener(using: parameters)

 // 设置新连接处理器
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.handleNewConnection(connection)
            }
        }

 // 设置状态更新处理器
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                await self?.handleListenerStateChange(state)
            }
        }

 // 启动监听器
        listener?.start(queue: connectionQueue)

 // 注册Bonjour服务
        try registerBonjourService()

        isListening = true
        logger.info("✅ 文件传输服务监听已启动")
    }

 /// 停止文件传输服务监听
    public func stopListening() {
        guard isListening else {
            cancelAllConnections()
            return
        }

        logger.info("🛑 停止文件传输服务监听")

 // 停止监听器
        listener?.cancel()
        listener = nil

 // 取消Bonjour服务
        netService?.stop()
        netService = nil

 // 关闭所有活动连接
        cancelAllConnections()

        isListening = false
        logger.info("✅ 文件传输服务监听已停止")
    }

 /// 连接到指定设备进行文件传输
    public func connectToDevice(ipAddress: String, port: Int, deviceId: String, deviceName: String) async throws -> NWConnection {
        guard (1...65535).contains(port) else {
            throw FileTransferError.invalidPort
        }
        logger.info("🔗 连接到设备: \(deviceName) (\(ipAddress))")

        let host = NWEndpoint.Host(ipAddress)
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }

        let connection = NWConnection(host: host, port: nwPort, using: parameters)
        let attemptID = UUID()

        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingConnectionAttempts[attemptID] = PendingConnectionAttempt(
                    connection: connection,
                    deviceId: deviceId,
                    deviceName: deviceName,
                    continuation: continuation
                )
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.handleConnectionAttemptState(state, attemptID: attemptID)
                    }
                }
                connection.start(queue: connectionQueue)

                connectionQueue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.timeoutConnectionAttempt(attemptID)
                    }
                }
            }
        }, onCancel: {
            connection.cancel()
            Task { @MainActor [weak self] in
                self?.cancelConnectionAttempt(attemptID)
            }
        })
    }

    private func handleConnectionAttemptState(
        _ state: NWConnection.State,
        attemptID: UUID
    ) {
        switch state {
        case .ready:
            completeConnectionAttempt(attemptID, result: .success(()))
        case .failed(let error):
            completeConnectionAttempt(attemptID, result: .failure(error))
        case .cancelled:
            completeConnectionAttempt(
                attemptID,
                result: .failure(FileTransferNetworkError.connectionCancelled)
            )
        default:
            break
        }
    }

    private func timeoutConnectionAttempt(_ attemptID: UUID) {
        guard let attempt = pendingConnectionAttempts[attemptID] else { return }
        attempt.connection.cancel()
        completeConnectionAttempt(
            attemptID,
            result: .failure(FileTransferNetworkError.connectionTimeout)
        )
    }

    private func cancelConnectionAttempt(_ attemptID: UUID) {
        guard let attempt = pendingConnectionAttempts[attemptID] else { return }
        attempt.connection.cancel()
        completeConnectionAttempt(
            attemptID,
            result: .failure(FileTransferNetworkError.connectionCancelled)
        )
    }

    private func completeConnectionAttempt(
        _ attemptID: UUID,
        result: Result<Void, Error>
    ) {
        guard let attempt = pendingConnectionAttempts.removeValue(forKey: attemptID) else {
            return
        }
        attempt.connection.stateUpdateHandler = nil
        switch result {
        case .success:
            let connectionKey = "outbound-\(attemptID.uuidString)"
            activeConnections[connectionKey] = attempt.connection
            outboundDeviceIDByConnectionKey[connectionKey] = attempt.deviceId
            logger.info("✅ 成功连接到设备: \(attempt.deviceName)")
            attempt.continuation.resume(returning: attempt.connection)
        case .failure(let error):
            logger.error("❌ 连接设备失败: \(attempt.deviceName) - \(error)")
            attempt.continuation.resume(throwing: error)
        }
    }

    func cancelPendingConnections() {
        let attemptIDs = Array(pendingConnectionAttempts.keys)
        for attemptID in attemptIDs {
            cancelConnectionAttempt(attemptID)
        }
    }

    func cancelAllConnections() {
        cancelPendingConnections()
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        outboundDeviceIDByConnectionKey.removeAll()
    }

 /// 断开与设备的连接
    public func disconnectFromDevice(_ deviceId: String) {
        logger.info("🔌 断开与设备的连接: \(deviceId)")
        let connectionKeys = outboundDeviceIDByConnectionKey.compactMap { key, value in
            value == deviceId ? key : nil
        }
        for connectionKey in connectionKeys {
            activeConnections.removeValue(forKey: connectionKey)?.cancel()
            outboundDeviceIDByConnectionKey.removeValue(forKey: connectionKey)
        }
        let pendingAttemptIDs = pendingConnectionAttempts.compactMap { key, value in
            value.deviceId == deviceId ? key : nil
        }
        for attemptID in pendingAttemptIDs {
            cancelConnectionAttempt(attemptID)
        }
    }

    func disconnect(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        let connectionKeys = activeConnections.compactMap { key, value in
            ObjectIdentifier(value) == connectionID ? key : nil
        }
        for connectionKey in connectionKeys {
            activeConnections.removeValue(forKey: connectionKey)
            outboundDeviceIDByConnectionKey.removeValue(forKey: connectionKey)
        }
        connection.cancel()
    }

 /// 发送文件传输请求
    public func sendTransferRequest(to connection: NWConnection, request: FileTransferNetworkRequest) async throws {
        logger.info("📤 发送文件传输请求")

        let requestData = try JSONEncoder().encode(request)
        let header = createMessageHeader(type: .transferRequest, length: requestData.count)

 // 发送消息头
        try await sendData(header, to: connection)

 // 发送请求数据
        try await sendData(requestData, to: connection)

        logger.info("✅ 文件传输请求已发送")
    }

 /// 接收文件传输请求
    public func receiveTransferRequest(from connection: NWConnection) async throws -> FileTransferNetworkRequest {
        logger.info("📥 接收文件传输请求")

 // 接收消息头
        let headerData = try await receiveData(length: 8, from: connection)
        let (type, length) = parseMessageHeader(headerData)

        guard type == .transferRequest else {
            throw FileTransferNetworkError.invalidMessageType
        }

 // 接收请求数据
        let requestData = try await receiveData(length: length, from: connection)
        let request = try JSONDecoder().decode(FileTransferNetworkRequest.self, from: requestData)

        logger.info("✅ 文件传输请求已接收: \(request.fileName)")
        return request
    }

 // MARK: - 私有方法

 /// 注册Bonjour服务
    private func registerBonjourService() throws {
        guard let port = listener?.port?.rawValue else {
            throw FileTransferNetworkError.invalidPort
        }

        let txtRecord = Self.makeBonjourTXTRecord(
            deviceName: Host.current().localizedName ?? "Unknown",
            port: port
        )

        let txtData = NetService.data(fromTXTRecord: txtRecord)

 // 创建并启动NetService
        netService = NetService(domain: serviceDomain, type: self.serviceType, name: "", port: Int32(port))
        netService?.setTXTRecord(txtData)
        netService?.delegate = self
        netService?.publish()

        logger.info("📡 Bonjour服务已注册: \(self.serviceType) 端口: \(port)")
    }

    nonisolated static func makeBonjourTXTRecord(deviceName: String, port: UInt16) -> [String: Data] {
        var record: [String: Data] = [
            "version": Data("1.0".utf8),
            "device": Data(deviceName.utf8),
            "name": Data(deviceName.utf8),
            "platform": Data("macos".utf8)
        ]
        BonjourInteropContract.attachFileTransferAdvertisementTXT(to: &record, port: port)
        return record
    }

 /// 处理新连接
    private func handleNewConnection(_ connection: NWConnection) async {
        logger.info("📞 收到新的文件传输连接")

 // 检查连接数限制
        guard activeConnections.count < maxConcurrentConnections else {
            logger.warning("⚠️ 达到最大连接数限制，拒绝新连接")
            connection.cancel()
            return
        }

        let connectionId = UUID().uuidString
        activeConnections[connectionId] = connection

 // 设置连接状态监听
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                await self?.handleConnectionStateChange(connectionId, state: state)
            }
        }

 // 启动连接
        connection.start(queue: connectionQueue)

 // 开始接收数据
        setupDataReceiving(for: connection, connectionId: connectionId)
    }

 /// 处理监听器状态变化
    private func handleListenerStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            logger.info("✅ 文件传输监听器就绪")

        case .failed(let error):
            logger.error("❌ 文件传输监听器失败: \(error)")
            isListening = false

        case .cancelled:
            logger.info("🛑 文件传输监听器已取消")
            isListening = false

        default:
            break
        }
    }

 /// 处理连接状态变化
    private func handleConnectionStateChange(_ connectionId: String, state: NWConnection.State) async {
        switch state {
        case .ready:
            logger.info("✅ 连接就绪: \(connectionId)")

        case .failed(let error):
            logger.error("❌ 连接失败: \(connectionId) - \(error)")
            activeConnections.removeValue(forKey: connectionId)

        case .cancelled:
            logger.info("🔌 连接已断开: \(connectionId)")
            activeConnections.removeValue(forKey: connectionId)

        default:
            break
        }
    }

 /// 设置数据接收
    private func setupDataReceiving(for connection: NWConnection, connectionId: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                await self?.handleReceivedData(data, connectionId: connectionId, isComplete: isComplete, error: error, connection: connection)
            }
        }
    }

 /// 处理接收到的数据
    private func handleReceivedData(_ data: Data?, connectionId: String, isComplete: Bool, error: NWError?, connection: NWConnection) async {
        if let error = error {
            logger.error("❌ 接收数据错误: \(connectionId) - \(error)")
            activeConnections.removeValue(forKey: connectionId)
            return
        }

        if let data = data, !data.isEmpty {
 // 处理接收到的数据
            await processReceivedData(data, from: connectionId)
        }

        if !isComplete {
 // 继续接收数据
            setupDataReceiving(for: connection, connectionId: connectionId)
        }
    }

 /// 处理接收到的数据
 /// Swift 6.2.1：通过通知中心发布接收到的数据，供上层（如 FileTransferManager）处理
    private func processReceivedData(_ data: Data, from connectionId: String) async {
        logger.info("📨 收到数据: \(data.count) 字节 来自: \(connectionId)")

 // 通过通知中心发布数据接收事件，供 FileTransferManager 等上层处理
        NotificationCenter.default.post(
            name: Notification.Name("FileTransferDataReceived"),
            object: nil,
            userInfo: [
                "connectionId": connectionId,
                "data": data,
                "timestamp": Date()
            ]
        )
    }

 /// 发送数据
    private func sendData(_ data: Data, to connection: NWConnection) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

 /// 接收数据
    private func receiveData(length: Int, from connection: NWConnection) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, data.count == length {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: FileTransferNetworkError.incompleteData)
                }
            }
        }
    }

 /// 创建消息头
    private func createMessageHeader(type: MessageType, length: Int) -> Data {
        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: type.rawValue.bigEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(length).bigEndian) { Array($0) })
        return header
    }

 /// 解析消息头
    private func parseMessageHeader(_ data: Data) -> (type: MessageType, length: Int) {
        let typeValue = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let lengthValue = data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        let type = MessageType(rawValue: typeValue) ?? .unknown
        return (type: type, length: Int(lengthValue))
    }
}

// MARK: - NetService Delegate

extension FileTransferNetworkService: NetServiceDelegate {
    nonisolated public func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in
            self.logger.info("✅ Bonjour服务发布成功")
        }
    }

    nonisolated public func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        Task { @MainActor in
            self.logger.error("❌ Bonjour服务发布失败: \(errorDict)")
        }
    }
}

// MARK: - 数据模型

/// 文件传输连接请求
public struct FileTransferConnectionRequest: Codable, Identifiable {
    public var id = UUID()
    public let deviceName: String
    public let deviceId: String
    public let timestamp: Date
    public let capabilities: [String]
}

/// 文件传输网络请求
public struct FileTransferNetworkRequest: Codable {
    public let id: String
    public let fileName: String
    public let fileSize: Int64
    public let fileHash: String
    public let timestamp: Date
    public let senderName: String
}

/// 消息类型
private enum MessageType: UInt32 {
    case transferRequest = 1
    case transferResponse = 2
    case fileData = 3
    case unknown = 0
}

// MARK: - 错误类型

public enum FileTransferNetworkError: Error, LocalizedError {
    case connectionTimeout
    case connectionCancelled
    case invalidPort
    case invalidMessageType
    case incompleteData
    case maxConnectionsReached

    public var errorDescription: String? {
        switch self {
        case .connectionTimeout:
            return "连接超时"
        case .connectionCancelled:
            return "连接已取消"
        case .invalidPort:
            return "无效端口"
        case .invalidMessageType:
            return "无效消息类型"
        case .incompleteData:
            return "数据不完整"
        case .maxConnectionsReached:
            return "达到最大连接数"
        }
    }
}
