//
// FileTransferNetworkService.swift
// SkyBridgeCompassiOS
//
// 文件传输网络服务 - 管理文件传输的网络连接
// 支持作为服务端接收文件，作为客户端发送文件
//

import Foundation
import Network
import class SkyBridgeProtocolCore.BonjourRegistrationReadinessGate
import enum SkyBridgeProtocolCore.BonjourInteropProtocolContract
import class SkyBridgeProtocolCore.ClassicTransferJSONWorker
import enum SkyBridgeProtocolCore.ClassicTransferInboundPolicy
import struct SkyBridgeProtocolCore.ClassicTransferInboundAdmission
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
    private var pendingListener: NWListener?
    private var startTask: Task<Void, Error>?
    private var startTaskToken: UUID?
    private var listenerGeneration: UInt64 = 0
    
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
    private var isBonjourPublished = false
    private var listenerHealthState: ListenerHealthState = .stopped
    
    // MARK: - Initialization
    
    public init(port: UInt16 = FileTransferConstants.defaultPort) {
        self.port = port
        protocolIdentityResolver = {
            _ = try await IOSCurrentPathAuthorityReadinessGate.shared.ensureReady()
            return try await SkyBridgeiOSCore.shared
                .committedActiveProtocolIdentitySnapshot()
                .snapshot
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
        try await startListening(authorityOverride: nil)
    }

    private func startListening(
        authorityOverride: ProtocolIdentitySnapshot?
    ) async throws {
        if isHealthy() {
            return
        }
        if let startTask {
            try await startTask.value
            return
        }
        if listener != nil || pendingListener != nil {
            stopListenerPreservingAcceptedConnections()
        }

        listenerGeneration &+= 1
        let generation = listenerGeneration
        let token = UUID()
        listenerHealthState = .starting
        let task = Task { [weak self] in
            guard let self else { throw POSIXError(.ECANCELED) }
            try await self.performStart(
                generation: generation,
                token: token,
                authorityOverride: authorityOverride
            )
        }
        startTask = task
        startTaskToken = token
        do {
            try await task.value
            finishStartTask(token: token)
        } catch {
            finishStartTask(token: token)
            throw error
        }
    }

    private func performStart(
        generation: UInt64,
        token: UUID,
        authorityOverride: ProtocolIdentitySnapshot?
    ) async throws {
        guard listenerGeneration == generation, startTaskToken == token else {
            throw POSIXError(.ECANCELED)
        }
        // Resolve the complete bound identity before allocating a listener so
        // cancellation/storage failure cannot leave a half-started service.
        let protocolIdentity: ProtocolIdentitySnapshot
        if let authorityOverride {
            protocolIdentity = authorityOverride
        } else {
            protocolIdentity = try await protocolIdentityResolver()
        }
        try Task.checkCancellation()
        guard listenerGeneration == generation, startTaskToken == token else {
            throw POSIXError(.ECANCELED)
        }
        let advertisedService = try makeBonjourService(
            authority: protocolIdentity
        )
        
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
        
        let newListener = try listenerFactory(
            parameters,
            NWEndpoint.Port(integerLiteral: port)
        )
        pendingListener = newListener
        newListener.service = advertisedService

        do {
            try await start(listener: newListener, generation: generation)
        } catch {
            if listenerGeneration == generation, startTaskToken == token {
                if pendingListener === newListener {
                    Self.cancelListener(newListener)
                    pendingListener = nil
                }
                listenerHealthState = .failed
                isListening = false
                isBonjourPublished = false
            }
            throw error
        }

        try Task.checkCancellation()
        guard listenerGeneration == generation,
              startTaskToken == token,
              listener === newListener,
              isBonjourPublished else {
            Self.cancelListener(newListener)
            if listener === newListener { listener = nil }
            if pendingListener === newListener { pendingListener = nil }
            isListening = false
            isBonjourPublished = false
            throw POSIXError(.ECANCELED)
        }
        SkyBridgeLogger.shared.info("📁 文件传输服务已启动，端口: \(self.port)")
    }

    public func ensureHealthy() async throws {
        if let startTask {
            try await startTask.value
            return
        }
        if isHealthy() {
            return
        }
        SkyBridgeLogger.shared.info(
            "ℹ️ iOS 文件传输 listener 未运行，准备重启: state=\(String(describing: listenerHealthState)) isListening=\(isListening)"
        )
        stopListenerPreservingAcceptedConnections()
        try await startListening()
    }

    public func isHealthy() -> Bool {
        isListenerReady && isBonjourPublished && listener?.service != nil
    }

    /// Rebind the accepting listener to a new Bonjour authority while preserving
    /// already-authenticated transfer connections. Registration callbacks do not
    /// identify a TXT epoch, so mutating `service` in place cannot prove that a
    /// later `.add` belongs to the new authority.
    func refreshAdvertisingAuthority(
        _ authority: ProtocolIdentitySnapshot
    ) async throws {
        guard isListenerReady else {
            throw FileTransferError.networkError(
                "文件传输监听器未就绪，无法发布协议身份"
            )
        }
        stopListenerPreservingAcceptedConnections()
        try await startListening(authorityOverride: authority)
    }

    private var isListenerReady: Bool {
        listener != nil && isListening && listenerHealthState == .ready
    }

    private func makeBonjourService(
        authority: ProtocolIdentitySnapshot
    ) throws -> NWListener.Service {
        let validatedAuthority = try ProtocolIdentityBindingCompat(
            deviceId: authority.deviceId,
            protocolSigningAlgorithm: authority.signingAlgorithm,
            protocolPublicKeyBytes: authority.signingPublicKey
        )
        guard validatedAuthority.deviceId == authority.deviceId,
              validatedAuthority.protocolPublicKeyFingerprint
                == authority.signingPublicKeyFingerprint else {
            throw FileTransferError.networkError(
                "文件传输 Bonjour 身份指纹与算法标记公钥不匹配"
            )
        }

        let presentation = AppleMobileDeviceIdentity.currentSnapshot()
        guard let advertisementPlatform = BonjourInteropProtocolContract.AdvertisementPlatform(
            rawValue: presentation.platform.rawValue
        ) else {
            throw FileTransferError.networkError(
                "文件传输 Bonjour 平台标识不受版本 2 协议支持"
            )
        }
        let txtRecord = try Self.makeBonjourTXTRecord(
            deviceId: validatedAuthority.deviceId,
            protocolIdentityFingerprint: validatedAuthority
                .protocolPublicKeyFingerprint,
            platform: advertisementPlatform,
            role: .dedicatedService
        )
        return NWListener.Service(
            name: presentation.deviceName,
            type: BonjourInteropProtocolContract.fileTransferServiceType,
            domain: "local.",
            txtRecord: txtRecord
        )
    }

    private static func makeBonjourTXTRecord(
        deviceId: String,
        protocolIdentityFingerprint: String,
        platform: BonjourInteropProtocolContract.AdvertisementPlatform,
        role: BonjourInteropProtocolContract.AdvertisementRole
    ) throws -> Data {
        try BonjourInteropProtocolContract.canonicalAdvertisementWireData(
            deviceId: deviceId,
            pubKeyFingerprint: protocolIdentityFingerprint,
            platform: platform,
            role: role
        )
    }

    private func start(listener: NWListener, generation: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let startupGate = BonjourRegistrationReadinessGate()

                listener.stateUpdateHandler = { [weak self] state in
                    Task { [weak self] in
                        guard let self else {
                            if startupGate.observeTerminal() == .completesStartup {
                                Self.cancelListener(listener)
                                continuation.resume(throwing: POSIXError(.ECANCELED))
                            }
                            return
                        }
                        await self.handleListenerStartupState(
                            state,
                            listener: listener,
                            generation: generation,
                            startupGate: startupGate,
                            continuation: continuation
                        )
                    }
                }

                listener.serviceRegistrationUpdateHandler = { [weak self] change in
                    Task { [weak self] in
                        guard let self else {
                            if startupGate.observeTerminal() == .completesStartup {
                                Self.cancelListener(listener)
                                continuation.resume(throwing: POSIXError(.ECANCELED))
                            }
                            return
                        }
                        await self.handleServiceRegistrationChange(
                            change,
                            listener: listener,
                            generation: generation,
                            startupGate: startupGate,
                            continuation: continuation
                        )
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    Task { [weak self] in
                        guard let self else {
                            connection.cancel()
                            return
                        }
                        await self.acceptNewConnection(
                            connection,
                            from: listener,
                            generation: generation
                        )
                    }
                }

                listener.start(queue: queue)
                Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(8))
                    } catch {
                        return
                    }
                    guard startupGate.claimTimeout() else { return }
                    Self.cancelListener(listener)
                    if let self {
                        await self.handleListenerStartupTimeout(
                            listener: listener,
                            generation: generation
                        )
                    }
                    continuation.resume(throwing: POSIXError(.ETIMEDOUT))
                }
            }
        } onCancel: {
            listener.cancel()
        }
    }

    private func ownsListener(_ candidate: NWListener, generation: UInt64) -> Bool {
        listenerGeneration == generation
            && (pendingListener === candidate || listener === candidate)
    }

    private func handleListenerStartupState(
        _ state: NWListener.State,
        listener candidate: NWListener,
        generation: UInt64,
        startupGate: BonjourRegistrationReadinessGate,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard ownsListener(candidate, generation: generation) else {
            if startupGate.observeTerminal() == .completesStartup {
                Self.cancelListener(candidate)
                continuation.resume(throwing: POSIXError(.ECANCELED))
            }
            return
        }

        switch state {
        case .ready:
            guard let boundPort = candidate.port?.rawValue, boundPort > 0 else {
                if startupGate.observeTerminal() == .completesStartup {
                    Self.cancelListener(candidate)
                    listenerHealthState = .failed
                    isListening = false
                    isBonjourPublished = false
                    continuation.resume(throwing: POSIXError(.EADDRNOTAVAIL))
                }
                return
            }
            let observation = startupGate.observeSocketReady()
            if observation == .completesStartup {
                commitListenerStartup(candidate)
                continuation.resume()
            } else if observation == .runtimeReady {
                listenerHealthState = .ready
                isListening = true
                isBonjourPublished = true
            }
        case .failed(let error):
            let observation = startupGate.observeTerminal()
            clearOwnedListener(candidate, terminalState: .failed)
            if observation == .completesStartup {
                continuation.resume(throwing: error)
            }
        case .cancelled:
            let observation = startupGate.observeTerminal()
            clearOwnedListener(candidate, terminalState: .cancelled)
            if observation == .completesStartup {
                continuation.resume(throwing: POSIXError(.ECANCELED))
            }
        case .waiting:
            _ = startupGate.observeSocketUnavailable()
            if listener === candidate {
                listenerHealthState = .starting
                isBonjourPublished = false
            }
        default:
            break
        }
    }

    private func handleServiceRegistrationChange(
        _ change: NWListener.ServiceRegistrationChange,
        listener candidate: NWListener,
        generation: UInt64,
        startupGate: BonjourRegistrationReadinessGate,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard ownsListener(candidate, generation: generation) else {
            if startupGate.observeTerminal() == .completesStartup {
                Self.cancelListener(candidate)
                continuation.resume(throwing: POSIXError(.ECANCELED))
            }
            return
        }

        let observation: BonjourRegistrationReadinessGate.Observation
        switch change {
        case .add(let endpoint):
            observation = startupGate.observeRegistrationAdded(endpoint.debugDescription)
        case .remove(let endpoint):
            observation = startupGate.observeRegistrationRemoved(endpoint.debugDescription)
        @unknown default:
            Self.cancelListener(candidate)
            if startupGate.observeTerminal() == .completesStartup {
                continuation.resume(throwing: POSIXError(.EPROTO))
            }
            return
        }

        switch observation {
        case .completesStartup:
            commitListenerStartup(candidate)
            continuation.resume()
        case .runtimeReady:
            listenerHealthState = .ready
            isListening = true
            isBonjourPublished = true
        case .runtimeDegraded:
            listenerHealthState = .starting
            isBonjourPublished = false
            SkyBridgeLogger.shared.warning(
                "⚠️ iOS 文件传输 Bonjour registration 已移除"
            )
        case .pending, .runtimeTerminal, .ignored:
            break
        }
    }

    private func commitListenerStartup(_ candidate: NWListener) {
        pendingListener = nil
        listener = candidate
        listenerHealthState = .ready
        isListening = true
        isBonjourPublished = true
    }

    private func clearOwnedListener(
        _ candidate: NWListener,
        terminalState: ListenerHealthState
    ) {
        Self.cancelListener(candidate)
        if pendingListener === candidate { pendingListener = nil }
        if listener === candidate { listener = nil }
        listenerHealthState = terminalState
        isListening = false
        isBonjourPublished = false
    }

    private func handleListenerStartupTimeout(
        listener candidate: NWListener,
        generation: UInt64
    ) {
        guard ownsListener(candidate, generation: generation) else { return }
        clearOwnedListener(candidate, terminalState: .failed)
        SkyBridgeLogger.shared.error(
            "❌ iOS 文件传输 listener 或 Bonjour registration 启动超时"
        )
    }

    private func acceptNewConnection(
        _ connection: NWConnection,
        from sourceListener: NWListener,
        generation: UInt64
    ) {
        guard listenerGeneration == generation,
              listener === sourceListener,
              isBonjourPublished else {
            Self.clearConnectionHandlers(connection)
            connection.cancel()
            return
        }
        handleNewConnection(connection)
    }

    private func finishStartTask(token: UUID) {
        guard startTaskToken == token else { return }
        startTask = nil
        startTaskToken = nil
    }
    
    /// 停止监听服务
    public func stopListening() {
        stopListenerPreservingAcceptedConnections()

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

    private func stopListenerPreservingAcceptedConnections() {
        listenerGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        startTaskToken = nil
        if let pendingListener {
            pendingListener.newConnectionHandler = nil
            pendingListener.serviceRegistrationUpdateHandler = nil
            pendingListener.cancel()
        }
        pendingListener = nil
        if let listener {
            Self.cancelListener(listener)
        }
        listener = nil
        isListening = false
        isBonjourPublished = false
        listenerHealthState = .stopped
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
    
    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID().uuidString
        guard inboundAdmission.reserve(connectionID: connectionId) else {
            SignedKEMRefreshSmokeStatusWriter.append(
                "file-transfer inbound-rejected stage=admission reason=capacity"
            )
            SkyBridgeLogger.shared.warning(
                "⚠️ 拒绝文件传输入站连接: reason=capacity limit=\(ClassicTransferInboundPolicy.maximumConcurrentConnections)"
            )
            connection.cancel()
            return
        }
        SignedKEMRefreshSmokeStatusWriter.append(
            "file-transfer inbound-accepted stage=transport"
        )
        
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
            SignedKEMRefreshSmokeStatusWriter.append(
                "file-transfer inbound-header-accepted stage=metadata length=\(header.length)"
            )

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
                        SignedKEMRefreshSmokeStatusWriter.append(
                            "file-transfer inbound-metadata-decoded stage=metadata"
                        )
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
            let nsError = error as NSError
            SignedKEMRefreshSmokeStatusWriter.append(
                "file-transfer inbound-dispatch-failed domain=\(nsError.domain) code=\(nsError.code)"
            )
            SkyBridgeLogger.shared.error(
                "❌ 处理文件接收请求失败: reason=file_receive_request_handler_failed domain=\(nsError.domain) code=\(nsError.code)"
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
        SignedKEMRefreshSmokeStatusWriter.append(
            "file-transfer inbound-rejected stage=metadata reason=\(error.rejectionReason)"
        )
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
        listener.serviceRegistrationUpdateHandler = nil
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
