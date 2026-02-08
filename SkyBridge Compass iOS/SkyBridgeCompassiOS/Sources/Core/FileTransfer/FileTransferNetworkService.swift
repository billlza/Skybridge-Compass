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
    public var onFileReceiveRequest: (@Sendable (FileMetadata, NWConnection, String) async throws -> Void)?
    
    /// 是否正在监听
    private var isListening = false
    
    // MARK: - Initialization
    
    public init(port: UInt16 = FileTransferConstants.defaultPort) {
        self.port = port
    }
    
    /// 设置文件接收回调（便于从 MainActor 安全注入处理逻辑）
    public func setOnFileReceiveRequest(
        _ handler: (@Sendable (FileMetadata, NWConnection, String) async throws -> Void)?
    ) {
        self.onFileReceiveRequest = handler
    }
    
    // MARK: - Public Methods
    
    /// 启动监听服务
    public func startListening() async throws {
        guard !isListening else { return }
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 15
            tcp.keepaliveCount = 4
        }
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
        
        // 配置 Bonjour 以便 macOS 端发现 (修复"未建立可用文件传输通道"错误)
        #if canImport(UIKit)
        let deviceName = await Self.currentDeviceName()
        #else
        let deviceName = "iOS Device"
        #endif

        let txtRecord: [String: Data] = [
            "version": "1.0".data(using: .utf8) ?? Data(),
            "device": deviceName.data(using: .utf8) ?? Data(),
            "capabilities": "file-transfer".data(using: .utf8) ?? Data()
        ]
        let txtData = NetService.data(fromTXTRecord: txtRecord)
        
        listener?.service = NWListener.Service(type: "_skybridge-transfer._tcp", txtRecord: txtData)
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleListenerState(state)
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handleNewConnection(connection)
            }
        }
        
        listener?.start(queue: queue)
        isListening = true
        
        SkyBridgeLogger.shared.info("📁 文件传输服务已启动，端口: \(self.port)")
    }

    #if canImport(UIKit)
    @MainActor
    private static func currentDeviceName() -> String {
        UIDevice.current.name
    }
    #endif
    
    /// 停止监听服务
    public func stopListening() {
        listener?.cancel()
        listener = nil
        isListening = false
        
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
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ipAddress),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
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
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { [weak self] in
                        await self?.addConnection(connection, id: deviceId)
                    }
                    gate.runOnce { continuation.resume(returning: connection) }
                    
                case .failed(let error):
                    gate.runOnce {
                        continuation.resume(throwing: FileTransferError.networkError(error.localizedDescription))
                    }
                    
                case .cancelled:
                    gate.runOnce { continuation.resume(throwing: FileTransferError.transferCancelled) }
                    
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
            SkyBridgeLogger.shared.info("✅ 文件传输监听器就绪")
            
        case .failed(let error):
            SkyBridgeLogger.shared.error("❌ 文件传输监听器失败: \(error.localizedDescription)")
            isListening = false
            
        case .cancelled:
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
                  let header = TransferHeader.decode(from: headerData),
                  header.type == .metadata else {
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
                
                // 获取对端信息
                let peerName = self.getPeerName(from: connection)
                
                // 通知文件接收请求
                Task {
                    do {
                        try await self.onFileReceiveRequest?(metadata, connection, peerName)
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
