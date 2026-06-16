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
    
    // MARK: - Properties
    
    /// 监听器
    private var listener: NWListener?
    
    /// 活跃连接
    private var activeConnections: [String: NWConnection] = [:]
    
    /// 监听端口
    private let port: UInt16
    
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
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
        
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

        let deviceId = ProtocolDeviceIdentity.stableDeviceId()

        let txtRecord = Self.makeBonjourTXTRecord(
            deviceName: deviceName,
            deviceId: deviceId,
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
            "model": Data(model.utf8),
            "osVersion": Data(systemVersion.utf8),
            "capabilities": Data("file_transfer".utf8),
            "transferPort": Data(portString.utf8),
            "fileTransferPort": Data(portString.utf8),
            "file_transfer_port": Data(portString.utf8),
            "port": Data(portString.utf8)
        ]
    }
    
    /// 停止监听服务
    public func stopListening() {
        listener?.cancel()
        listener = nil
        isListening = false
        listenerHealthState = .stopped
        
        // 关闭所有连接
        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        
        SkyBridgeLogger.shared.info("📁 文件传输服务已停止")
    }
    
    /// 连接到设备
    public func connectToDevice(
        ipAddress: String,
        port: UInt16 = FileTransferConstants.defaultPort,
        deviceId: String,
        deviceName: String
    ) async throws -> NWConnection {
        let normalizedIP = ipAddress.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        if normalizedIP == "127.0.0.1"
            || normalizedIP == "::1"
            || normalizedIP == "0:0:0:0:0:0:0:1"
            || normalizedIP == "::ffff:127.0.0.1"
            || normalizedIP == "localhost" {
            SkyBridgeLogger.shared.warning("⚠️ 已阻止文件传输自连接目标: \(ipAddress)")
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
                        continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))
                    }
                    
                case .cancelled:
                    finishOnce { continuation.resume(throwing: FileTransferError.transferCancelled) }
                    
                default:
                    break
                }
            }
            
            connection.start(queue: queue)
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
            listenerHealthState = .failed
            SkyBridgeLogger.shared.error("❌ 文件传输监听器失败: \(error.localizedDescription)")
            isListening = false
            
        case .cancelled:
            listenerHealthState = .cancelled
            SkyBridgeLogger.shared.info("⏹️ 文件传输监听器已取消")
            isListening = false
            
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID().uuidString
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleConnectionState(state, connectionId: connectionId)
            }
        }
        
        connection.start(queue: queue)
        activeConnections[connectionId] = connection
        
        // 开始接收数据
        Task {
            await receiveMetadata(from: connection, connectionId: connectionId)
        }
    }
    
    private func handleConnectionState(_ state: NWConnection.State, connectionId: String) {
        switch state {
        case .ready:
            SkyBridgeLogger.shared.info("✅ 文件传输连接就绪: \(connectionId)")
            
        case .failed(let error):
            SkyBridgeLogger.shared.error("❌ 文件传输连接失败: \(error.localizedDescription)")
            activeConnections.removeValue(forKey: connectionId)
            
        case .cancelled:
            activeConnections.removeValue(forKey: connectionId)
            
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
            
            if let error = error {
                SkyBridgeLogger.shared.error("❌ 接收头部失败: \(error.localizedDescription)")
                return
            }
            
            guard let headerData = data,
                  let header = TransferHeader.decode(from: headerData) else {
                return
            }
            if header.type == .resumeRequest {
                SkyBridgeLogger.shared.warning("⚠️ iOS classic TCP listener 不支持 resumeRequest，已拒绝该连接")
                connection.cancel()
                return
            }
            guard header.type == .metadata else {
                return
            }
            if header.length <= 0 || header.length > 2_000_000 {
                SkyBridgeLogger.shared.error("❌ 元数据长度异常: \(header.length)")
                connection.cancel()
                return
            }
            
            // 接收元数据
            connection.receive(minimumIncompleteLength: header.length, maximumLength: header.length) { [weak self] metaData, _, _, error in
                guard let self = self else { return }
                
                if let error = error {
                    SkyBridgeLogger.shared.error("❌ 接收元数据失败: \(error.localizedDescription)")
                    return
                }
                
                guard let data = metaData,
                      let metadata = try? JSONDecoder().decode(FileMetadata.self, from: data) else {
                    return
                }
                
                let endpointHostOrIP = self.endpointHostOrIP(from: connection)
                let peerName = endpointHostOrIP ?? self.getPeerName(from: connection)
                let peerContext = FileTransferPeerContext(
                    declaredSenderDeviceId: metadata.senderDeviceId,
                    endpointHostOrIP: endpointHostOrIP,
                    peerLabel: peerName,
                    transferId: metadata.transferId
                )
                
                // 通知文件接收请求
                Task {
                    do {
                        try await self.onFileReceiveRequest?(metadata, connection, peerContext)
                    } catch {
                        SkyBridgeLogger.shared.error("❌ 处理文件接收请求失败: \(error.localizedDescription)")
                    }
                }
            }
        }
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
