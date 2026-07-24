//
// FileTransferNetworkService.swift
// SkyBridgeCompassiOS
//
// 文件传输网络服务 - 管理文件传输的网络连接
// 支持作为服务端接收文件，作为客户端发送文件
//

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

// MARK: - File Transfer Network Service

/// 文件传输网络服务
@available(iOS 17.0, *)
public actor FileTransferNetworkService {
    typealias ProtocolIdentityResolver = @Sendable () async throws
        -> ProtocolIdentitySnapshot
    typealias ListenerFactory = @Sendable (
        NWParameters,
        NWEndpoint.Port
    ) throws -> NWListener

    private final class StartState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func finish() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    private enum ListenerHealthState {
        case stopped
        case starting
        case ready
        case failed
        case cancelled
    }

    private enum InboundInitialMetadataError: Error, Equatable, Sendable {
        case headerReceiveFailed
        case missingHeader
        case malformedHeader
        case unsupportedResumeRequest
        case unexpectedInitialMessage
        case invalidMetadataLength
        case metadataReceiveFailed
        case missingMetadataPayload
        case malformedMetadataJSON
        case initialHeaderTimedOut
        case metadataPayloadTimedOut
        case receiveHandlerUnavailable

        var rejectionReason: String {
            switch self {
            case .headerReceiveFailed:
                return "header_receive_failed"
            case .missingHeader:
                return "missing_header"
            case .malformedHeader:
                return "malformed_header"
            case .unsupportedResumeRequest:
                return "unsupported_resume_request"
            case .unexpectedInitialMessage:
                return "unexpected_initial_message"
            case .invalidMetadataLength:
                return "invalid_metadata_length"
            case .metadataReceiveFailed:
                return "metadata_receive_failed"
            case .missingMetadataPayload:
                return "missing_metadata_payload"
            case .malformedMetadataJSON:
                return "malformed_metadata_json"
            case .initialHeaderTimedOut:
                return "initial_header_timed_out"
            case .metadataPayloadTimedOut:
                return "metadata_payload_timed_out"
            case .receiveHandlerUnavailable:
                return "receive_handler_unavailable"
            }
        }
    }
    
    // MARK: - Properties
    
    /// 监听器
    private var listener: NWListener?
    
    /// 活跃连接
    private var activeConnections: [String: NWConnection] = [:]
    private var inboundAdmission = ClassicTransferInboundAdmission()
    private var inboundDeadlineTasks: [String: Task<Void, Never>] = [:]
    private var inboundHandlerTasks: [String: Task<Void, Never>] = [:]
    
    /// 监听端口
    private let port: UInt16
    private let protocolIdentityResolver: ProtocolIdentityResolver
    private let listenerFactory: ListenerFactory
    
    /// 服务队列
    private let queue = DispatchQueue(label: "com.skybridge.filetransfer.network", qos: .userInitiated)
    
    /// 文件接收回调
    var onFileReceiveRequest: (@Sendable (FileMetadata, NWConnection, FileTransferPeerContext) async throws -> Void)?
    
    /// 是否正在监听
    private var isListening = false
    private var listenerHealthState: ListenerHealthState = .stopped
    
    // MARK: - Initialization
    
    public init(port: UInt16 = FileTransferConstants.defaultPort) {
        self.port = port
        protocolIdentityResolver = {
            try await SkyBridgeiOSCore.shared
                .currentProtocolIdentitySnapshot()
        }
        listenerFactory = { parameters, port in
            try NWListener(using: parameters, on: port)
        }
    }

    init(
        port: UInt16,
        protocolIdentityResolver: @escaping ProtocolIdentityResolver,
        listenerFactory: @escaping ListenerFactory
    ) {
        self.port = port
        self.protocolIdentityResolver = protocolIdentityResolver
        self.listenerFactory = listenerFactory
    }
    
    /// 设置文件接收回调（便于从 MainActor 安全注入处理逻辑）
    func setOnFileReceiveRequest(
        _ handler: (@Sendable (FileMetadata, NWConnection, FileTransferPeerContext) async throws -> Void)?
    ) {
        self.onFileReceiveRequest = handler
    }
    
    // MARK: - Public Methods
    
    /// 启动监听服务
    public func startListening() async throws {
        if await isHealthy() {
            return
        }
        if listener != nil {
            stopListening()
        }

        // Resolve the complete bound identity before allocating a listener so
        // cancellation/storage failure cannot leave a half-started service.
        let protocolIdentity = try await protocolIdentityResolver()
        listenerHealthState = .starting
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        
        listener = try listenerFactory(
            parameters,
            NWEndpoint.Port(integerLiteral: port)
        )
        
        // 配置 Bonjour 以便 macOS 端发现 (修复"未建立可用文件传输通道"错误)
        #if canImport(UIKit)
        let deviceName = await Self.currentDeviceName()
        let systemVersion = await Self.currentSystemVersion()
        let model = await Self.currentModel()
        #else
        let deviceName = "iOS Device"
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = "iOS Device"
        #endif

        let deviceId = protocolIdentity.deviceId

        let txtRecord = Self.makeBonjourTXTRecord(
            deviceName: deviceName,
            deviceId: deviceId,
            protocolSigningAlgorithm: protocolIdentity.signingAlgorithm.rawValue,
            protocolIdentityFingerprint: protocolIdentity.signingPublicKeyFingerprint,
            model: model,
            systemVersion: systemVersion,
            port: port
        )
        let txtData = NetService.data(fromTXTRecord: txtRecord)
        
        listener?.service = NWListener.Service(
            name: deviceName,
            type: "_skybridge-transfer._tcp",
            domain: "local.",
            txtRecord: txtData
        )
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let startState = StartState()
                queue.asyncAfter(deadline: .now() + .seconds(8)) {
                    guard startState.finish() else { return }
                    continuation.resume(throwing: POSIXError(.ETIMEDOUT))
                }

                listener?.stateUpdateHandler = { [weak self] state in
                    Task { [weak self] in
                        await self?.handleListenerState(state)
                    }

                    switch state {
                    case .ready:
                        guard startState.finish() else { return }
                        continuation.resume()
                    case .failed(let error):
                        guard startState.finish() else { return }
                        continuation.resume(throwing: error)
                    case .cancelled:
                        guard startState.finish() else { return }
                        continuation.resume(throwing: POSIXError(.ECANCELED))
                    default:
                        break
                    }
                }

                listener?.newConnectionHandler = { [weak self] connection in
                    Task { [weak self] in
                        await self?.handleNewConnection(connection)
                    }
                }

                self.listener?.start(queue: self.queue)
            }
        } catch {
            stopListening()
            throw error
        }
        
        SkyBridgeLogger.shared.info("📁 文件传输服务已启动，端口: \(self.port)")
    }

    public func ensureHealthy() async throws {
        if await isHealthy() {
            return
        }
        SkyBridgeLogger.shared.info(
            "ℹ️ iOS 文件传输 listener 未运行，准备重启: state=\(String(describing: listenerHealthState)) isListening=\(isListening)"
        )
        stopListening()
        try await startListening()
    }

    public func isHealthy() async -> Bool {
        listener != nil && isListening && listenerHealthState == .ready
    }

    #if canImport(UIKit)
    @MainActor
    private static func currentDeviceName() -> String {
        AppleMobileDeviceIdentity.currentSnapshot().deviceName
    }

    @MainActor
    private static func currentSystemVersion() -> String {
        UIDevice.current.systemVersion
    }

    @MainActor
    private static func currentModel() -> String {
        UIDevice.current.model
    }
    #endif

    private static func makeBonjourTXTRecord(
        deviceName: String,
        deviceId: String,
        protocolSigningAlgorithm: String,
        protocolIdentityFingerprint: String,
        model: String,
        systemVersion: String,
        port: UInt16
    ) -> [String: Data] {
        let portString = String(port)
        return [
            "version": Data("1".utf8),
            "platform": Data("ios".utf8),
            "name": Data(deviceName.utf8),
            "device": Data(deviceName.utf8),
            "deviceId": Data(deviceId.utf8),
            "uuid": Data(deviceId.utf8),
            "protocolSigningAlgorithm": Data(protocolSigningAlgorithm.utf8),
            "pubKeyFP": Data(protocolIdentityFingerprint.utf8),
            "identityFingerprint": Data(protocolIdentityFingerprint.utf8),
            "model": Data(model.utf8),
            "osVersion": Data(systemVersion.utf8),
            // The inbound parser explicitly rejects resumeRequest. Advertise
            // only capabilities that this listener can complete end to end.
            "capabilities": Data("file,file_transfer".utf8),
            "transferPort": Data(portString.utf8),
            "fileTransferPort": Data(portString.utf8),
            "file_transfer_port": Data(portString.utf8),
            "port": Data(portString.utf8)
        ]
    }
    
    /// 停止监听服务
    public func stopListening() {
        if let listener {
            Self.cancelListener(listener)
        }
        listener = nil
        isListening = false
        listenerHealthState = .stopped
        
        // 关闭所有连接
        for (_, connection) in activeConnections {
            Self.clearConnectionHandlers(connection)
            connection.cancel()
        }
        activeConnections.removeAll()
        for task in inboundDeadlineTasks.values {
            task.cancel()
        }
        inboundDeadlineTasks.removeAll()
        for task in inboundHandlerTasks.values {
            task.cancel()
        }
        inboundHandlerTasks.removeAll()
        inboundAdmission.removeAll()
        
        SkyBridgeLogger.shared.info("📁 文件传输服务已停止")
    }
    
    /// 连接到设备
    public func connectToDevice(
        ipAddress: String,
        port: UInt16 = FileTransferConstants.defaultPort,
        deviceId: String,
        deviceName _: String
    ) async throws -> NWConnection {
        let normalizedIP = ipAddress.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        if normalizedIP == "127.0.0.1"
            || normalizedIP == "::1"
            || normalizedIP == "0:0:0:0:0:0:0:1"
            || normalizedIP == "::ffff:127.0.0.1"
            || normalizedIP == "localhost" {
            SkyBridgeLogger.shared.warning("⚠️ 已阻止文件传输自连接目标")
            throw FileTransferError.invalidDestination
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ipAddress),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        
        let connection = NWConnection(to: endpoint, using: parameters)
        let endpointDescription = "\(normalizedIP):\(port)"
        
        final class ContinuationGate: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false
            func runOnce(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                body()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()
            
            connection.stateUpdateHandler = { [weak self, connection, deviceId] state in
                func finishOnce(_ body: () -> Void) {
                    connection.stateUpdateHandler = nil
                    gate.runOnce(body)
                }

                switch state {
                case .ready:
                    Task { [weak self, connection, deviceId] in
                        await self?.addConnection(connection, id: deviceId)
                    }
                    finishOnce { continuation.resume(returning: connection) }
                    
                case .failed(let error):
                    finishOnce {
                        continuation.resume(throwing: FileTransferError.networkStageFailed(
                            stage: "connect_failed",
                            endpoint: endpointDescription,
                            details: error.localizedDescription
                        ))
                    }
                    
                case .cancelled:
                    finishOnce { continuation.resume(throwing: FileTransferError.transferCancelled) }

                case .waiting(let error):
                    let waitingError = error as NSError
                    SkyBridgeLogger.shared.warning(
                        "⏳ 文件传输连接等待: domain=\(waitingError.domain) code=\(waitingError.code)"
                    )
                    
                default:
                    break
                }
            }
            
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + FileTransferConstants.connectionTimeout) {
                gate.runOnce {
                    connection.stateUpdateHandler = nil
                    SkyBridgeLogger.shared.error(
                        "❌ 文件传输连接超时: timeout=\(Int(FileTransferConstants.connectionTimeout))s"
                    )
                    connection.cancel()
                    continuation.resume(throwing: FileTransferError.networkStageFailed(
                        stage: "connect_timeout",
                        endpoint: endpointDescription,
                        details: "\(Int(FileTransferConstants.connectionTimeout))s"
                    ))
                }
            }
        }
    }
    
    /// 断开连接
    public func disconnectDevice(_ deviceId: String) {
        if let connection = activeConnections[deviceId] {
            connection.cancel()
            activeConnections.removeValue(forKey: deviceId)
        }
    }
    
    /// 获取连接
    public func getConnection(for deviceId: String) -> NWConnection? {
        activeConnections[deviceId]
    }
    
    // MARK: - Private Methods
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            listenerHealthState = .ready
            isListening = true
            SkyBridgeLogger.shared.info("✅ 文件传输监听器就绪")
            
        case .failed(let error):
            if let listener {
                Self.cancelListener(listener)
            }
            listener = nil
            listenerHealthState = .failed
            let listenerError = error as NSError
            SkyBridgeLogger.shared.error(
                "❌ 文件传输监听器失败: domain=\(listenerError.domain) code=\(listenerError.code)"
            )
            isListening = false
            
        case .cancelled:
            if let listener {
                Self.clearListenerHandlers(listener)
            }
            listener = nil
            listenerHealthState = .cancelled
            SkyBridgeLogger.shared.info("⏹️ 文件传输监听器已取消")
            isListening = false
            
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID().uuidString
        guard inboundAdmission.reserve(connectionID: connectionId) else {
            SkyBridgeLogger.shared.warning(
                "⚠️ 拒绝文件传输入站连接: reason=capacity limit=\(ClassicTransferInboundPolicy.maximumConcurrentConnections)"
            )
            connection.cancel()
            return
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleConnectionState(state, connectionId: connectionId)
            }
        }
        
        connection.start(queue: queue)
        activeConnections[connectionId] = connection
        scheduleInboundDeadline(
            connection,
            connectionId: connectionId,
            timeout: ClassicTransferInboundPolicy.initialHeaderTimeoutSeconds,
            error: .initialHeaderTimedOut
        )
        
        // 开始接收数据
        Task {
            await receiveMetadata(from: connection, connectionId: connectionId)
        }
    }
    
    private func handleConnectionState(_ state: NWConnection.State, connectionId: String) {
        switch state {
        case .ready:
            SkyBridgeLogger.shared.info("✅ 文件传输入站连接就绪")
            
        case .failed(let error):
            let connectionError = error as NSError
            SkyBridgeLogger.shared.error(
                "❌ 文件传输入站连接失败: domain=\(connectionError.domain) code=\(connectionError.code)"
            )
            finishInboundConnection(
                connectionId: connectionId,
                cancelConnection: false
            )
            
        case .cancelled:
            finishInboundConnection(
                connectionId: connectionId,
                cancelConnection: false
            )
            
        default:
            break
        }
    }
    
    private func addConnection(_ connection: NWConnection, id: String) {
        activeConnections[id] = connection
    }
    
    private func receiveMetadata(from connection: NWConnection, connectionId: String) async {
        // 接收头部（8字节：4字节类型 + 4字节长度，big-endian；与 macOS 端对齐）
        connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { [weak self] data, _, _, error in
            guard let self = self else { return }
            
            if error != nil {
                Task { await self.rejectInboundMetadataConnection(connection, connectionId: connectionId, error: .headerReceiveFailed) }
                return
            }

            let headerResult = Self.decodeInboundInitialMetadataHeader(data)
            guard case let .success(header) = headerResult else {
                if case let .failure(validationError) = headerResult {
                    Task { await self.rejectInboundMetadataConnection(connection, connectionId: connectionId, error: validationError) }
                }
                return
            }

            Task { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard await self.beginInboundMetadataPayloadDeadline(
                    connection,
                    connectionId: connectionId
                ) else {
                    return
                }

                // 接收元数据
                connection.receive(minimumIncompleteLength: header.length, maximumLength: header.length) { [weak self] metaData, _, _, error in
                    guard let self else {
                        connection.cancel()
                        return
                    }

                    if error != nil {
                        Task { await self.rejectInboundMetadataConnection(connection, connectionId: connectionId, error: .metadataReceiveFailed) }
                        return
                    }

                    Task { [weak self] in
                        guard let self else {
                            connection.cancel()
                            return
                        }
                        guard await self.isActiveInboundConnection(connection, id: connectionId) else {
                            return
                        }
                        let metadataResult = await Self.decodeInboundInitialMetadataPayload(metaData)
                        guard await self.isActiveInboundConnection(connection, id: connectionId) else {
                            return
                        }
                        guard case let .success(metadata) = metadataResult else {
                            if case let .failure(validationError) = metadataResult {
                                await self.rejectInboundMetadataConnection(
                                    connection,
                                    connectionId: connectionId,
                                    error: validationError
                                )
                            }
                            return
                        }
                        await self.startInboundTransferDispatch(
                            metadata,
                            from: connection,
                            connectionId: connectionId
                        )
                    }
                }
            }
        }
    }

    private func startInboundTransferDispatch(
        _ metadata: FileMetadata,
        from connection: NWConnection,
        connectionId: String
    ) {
        guard activeConnections[connectionId] === connection else {
            return
        }
        inboundHandlerTasks.removeValue(forKey: connectionId)?.cancel()
        inboundHandlerTasks[connectionId] = Task { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            await self.dispatchInboundTransfer(
                metadata,
                from: connection,
                connectionId: connectionId
            )
        }
    }

    private func isActiveInboundConnection(_ connection: NWConnection, id: String) -> Bool {
        activeConnections[id] === connection
    }

    private func beginInboundMetadataPayloadDeadline(
        _ connection: NWConnection,
        connectionId: String
    ) -> Bool {
        guard activeConnections[connectionId] === connection else {
            return false
        }
        scheduleInboundDeadline(
            connection,
            connectionId: connectionId,
            timeout: ClassicTransferInboundPolicy.metadataPayloadTimeoutSeconds,
            error: .metadataPayloadTimedOut
        )
        return true
    }

    private func dispatchInboundTransfer(
        _ metadata: FileMetadata,
        from connection: NWConnection,
        connectionId: String
    ) async {
        guard activeConnections[connectionId] === connection else {
            return
        }
        inboundDeadlineTasks.removeValue(forKey: connectionId)?.cancel()

        guard let onFileReceiveRequest else {
            rejectInboundMetadataConnection(
                connection,
                connectionId: connectionId,
                error: .receiveHandlerUnavailable
            )
            return
        }

        let endpointHostOrIP = endpointHostOrIP(from: connection)
        let peerName = endpointHostOrIP ?? getPeerName(from: connection)
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: metadata.senderDeviceId,
            endpointHostOrIP: endpointHostOrIP,
            peerLabel: peerName,
            transferId: metadata.transferId
        )

        do {
            try await onFileReceiveRequest(metadata, connection, peerContext)
        } catch {
            SkyBridgeLogger.shared.error(
                "❌ 处理文件接收请求失败: reason=file_receive_request_handler_failed"
            )
        }
        finishInboundConnection(connectionId: connectionId, cancelConnection: true)
    }

    private func scheduleInboundDeadline(
        _ connection: NWConnection,
        connectionId: String,
        timeout: TimeInterval,
        error: InboundInitialMetadataError
    ) {
        inboundDeadlineTasks.removeValue(forKey: connectionId)?.cancel()
        inboundDeadlineTasks[connectionId] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch is CancellationError {
                return
            } catch let sleepError {
                guard let self else {
                    connection.cancel()
                    return
                }
                let nsError = sleepError as NSError
                SkyBridgeLogger.shared.error(
                    "❌ classic inbound deadline task failed; rejecting connection domain=\(nsError.domain) code=\(nsError.code)"
                )
                await self.rejectInboundMetadataConnection(
                    connection,
                    connectionId: connectionId,
                    error: error
                )
                return
            }
            guard let self else {
                connection.cancel()
                return
            }
            await self.rejectInboundMetadataConnection(
                connection,
                connectionId: connectionId,
                error: error
            )
        }
    }

    private nonisolated static func decodeInboundInitialMetadataHeader(
        _ data: Data?
    ) -> Result<TransferHeader, InboundInitialMetadataError> {
        guard let data else {
            return .failure(.missingHeader)
        }
        guard let header = TransferHeader.decode(from: data) else {
            return .failure(.malformedHeader)
        }
        switch header.type {
        case .metadata:
            guard header.length > 0 && header.length <= 2_000_000 else {
                return .failure(.invalidMetadataLength)
            }
            return .success(header)
        case .resumeRequest:
            return .failure(.unsupportedResumeRequest)
        case .chunk, .complete, .receipt, .resumeAck, .unknown:
            return .failure(.unexpectedInitialMessage)
        }
    }

    private nonisolated static func decodeInboundInitialMetadataPayload(
        _ data: Data?
    ) async -> Result<FileMetadata, InboundInitialMetadataError> {
        guard let data else {
            return .failure(.missingMetadataPayload)
        }
        do {
            return .success(try await ClassicTransferJSONWorker.shared.decode(
                FileMetadata.self,
                from: data,
                maximumInputSize: 2_000_000
            ))
        } catch {
            return .failure(.malformedMetadataJSON)
        }
    }

    private func rejectInboundMetadataConnection(
        _ connection: NWConnection,
        connectionId: String,
        error: InboundInitialMetadataError
    ) {
        SkyBridgeLogger.shared.error("❌ 拒绝文件传输入站元数据: reason=\(error.rejectionReason)")
        finishInboundConnection(connectionId: connectionId, cancelConnection: true)
    }

    private func finishInboundConnection(
        connectionId: String,
        cancelConnection: Bool
    ) {
        inboundDeadlineTasks.removeValue(forKey: connectionId)?.cancel()
        inboundHandlerTasks.removeValue(forKey: connectionId)?.cancel()
        inboundAdmission.release(connectionID: connectionId)
        guard let connection = activeConnections.removeValue(forKey: connectionId) else {
            return
        }
        Self.clearConnectionHandlers(connection)
        if cancelConnection {
            connection.cancel()
        }
    }

    private nonisolated static func clearListenerHandlers(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    private nonisolated static func cancelListener(_ listener: NWListener) {
        clearListenerHandlers(listener)
        listener.cancel()
    }

    private nonisolated static func clearConnectionHandlers(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        connection.betterPathUpdateHandler = nil
        connection.pathUpdateHandler = nil
    }

    private nonisolated func getPeerName(from connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.endpoint {
            return "\(host)"
        }
        return "Unknown"
    }

    private nonisolated func endpointHostOrIP(from connection: NWConnection) -> String? {
        if case let .hostPort(host, _) = connection.endpoint {
            return "\(host)"
        }
        return nil
    }
}

// MARK: - Connection Info

/// 连接信息
public struct ConnectionInfo: Sendable {
    public let id: String
    public let ipAddress: String
    public let port: UInt16
    public let deviceName: String?
    public let connectedAt: Date
    
    public init(id: String, ipAddress: String, port: UInt16, deviceName: String? = nil) {
        self.id = id
        self.ipAddress = ipAddress
        self.port = port
        self.deviceName = deviceName
        self.connectedAt = Date()
    }
}
