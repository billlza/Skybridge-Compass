// BonjourServiceEnhanced.swift
// SkyBridgeCore
//
// 增强的 Bonjour 服务模块 - 支持完整的 TXT 记录
// Created for web-agent-integration spec 11

import Foundation
import Network
import OSLog

// MARK: - Bonjour TXT Record Builder

/// Bonjour TXT 记录构建器
/// 用于构建符合 SkyBridge Protocol 规范的 TXT 记录
@available(macOS 14.0, *)
public struct BonjourTXTRecordBuilder: Sendable {
    
 /// 必需字段
    public var deviceId: String
    public var pubKeyFP: String
    public var uniqueId: String
    
 /// 可选字段
    public var platform: String?
    public var version: String?
    /// 操作系统版本（用于 iOS/macOS UI 展示，例如 "macOS 26.2"）
    public var osVersion: String?
    public var capabilities: [String]?
    public var name: String?
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        uniqueId: String,
        platform: String? = nil,
        version: String? = nil,
        osVersion: String? = nil,
        capabilities: [String]? = nil,
        name: String? = nil
    ) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.uniqueId = uniqueId
        self.platform = platform
        self.version = version
        self.osVersion = osVersion
        self.capabilities = capabilities
        self.name = name
    }
    
 /// 构建 TXT 记录字典
    public func build() -> [String: String] {
        var record: [String: String] = [:]
        
 // 必需字段
        record["deviceId"] = deviceId
        record["pubKeyFP"] = pubKeyFP
        record["uniqueId"] = uniqueId
        
 // 可选字段
        if let platform = platform {
            record["platform"] = platform
        }
        if let version = version {
            record["version"] = version
        }
        if let osVersion = osVersion {
            record["osVersion"] = osVersion
        }
        if let capabilities = capabilities, !capabilities.isEmpty {
            record["capabilities"] = capabilities.joined(separator: ",")
        }
        if let name = name {
            record["name"] = name
        }
        
        return record
    }
    
 /// 构建 TXT 记录数据
    public func buildData() -> Data {
        let dict = build()
        return Self.encodeToData(dict)
    }
    
 /// 将字典编码为 TXT 记录数据格式
    public static func encodeToData(_ dict: [String: String]) -> Data {
        var data = Data()
        
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            let entry = "\(key)=\(value)"
            if let entryData = entry.data(using: .utf8), entryData.count < 256 {
                data.append(UInt8(entryData.count))
                data.append(entryData)
            }
        }
        
        return data
    }
    
 /// 验证 TXT 记录是否包含所有必需字段
    public static func validate(_ dict: [String: String]) -> Bool {
        let requiredFields = ["deviceId", "pubKeyFP", "uniqueId"]
        return requiredFields.allSatisfy { dict[$0] != nil && !dict[$0]!.isEmpty }
    }
}

// MARK: - Enhanced Bonjour Service

/// 增强的 Bonjour 服务
/// 支持完整的 TXT 记录和自动重试
@available(macOS 14.0, *)
public actor EnhancedBonjourService {
    
 // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.skybridge.discovery", category: "EnhancedBonjourService")
    
    private var netService: NetService?
    private var listener: NWListener?
    private var isRegistered: Bool = false
    private var retryCount: Int = 0
    private var retryTask: Task<Void, Never>?
    
 /// 最大重试次数
    public let maxRetries: Int
    
 /// 重试延迟（秒）
    public let retryDelay: TimeInterval
    
 /// 服务类型
    public let serviceType: String
    
 /// 当前 TXT 记录
    private var currentTXTRecord: [String: String] = [:]
    
 /// 分配的端口
    public private(set) var assignedPort: UInt16 = 0
    
 // MARK: - Initialization
    
    public init(
        serviceType: String = "_skybridge._tcp",
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 10.0
    ) {
        self.serviceType = serviceType
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }
    
 // MARK: - Public Interface
    
 /// 注册 Bonjour 服务
 /// - Parameters:
 /// - name: 服务名称
 /// - txtRecord: TXT 记录构建器
 /// - connectionHandler: 连接处理回调
 /// - Returns: 分配的端口号
    public func register(
        name: String,
        txtRecord: BonjourTXTRecordBuilder,
        connectionHandler: (@Sendable (NWConnection) -> Void)? = nil
    ) async throws -> UInt16 {
 // 验证 TXT 记录
        let txtDict = txtRecord.build()
        guard BonjourTXTRecordBuilder.validate(txtDict) else {
            throw BonjourServiceError.invalidTXTRecord("缺少必需字段")
        }
        
        currentTXTRecord = txtDict
        retryCount = 0
        
        return try await doRegister(name: name, connectionHandler: connectionHandler)
    }
    
 /// 更新 TXT 记录
 /// - Parameter txtRecord: 新的 TXT 记录构建器
    public func updateTXTRecord(_ txtRecord: BonjourTXTRecordBuilder) {
        let txtDict = txtRecord.build()
        guard BonjourTXTRecordBuilder.validate(txtDict) else {
            logger.warning("⚠️ 无效的 TXT 记录更新，忽略")
            return
        }
        
        currentTXTRecord = txtDict
        
 // 更新 NetService 的 TXT 记录
        if let netService = netService {
            let txtData = NetService.data(fromTXTRecord: txtDict.mapValues { $0.data(using: .utf8) ?? Data() })
            netService.setTXTRecord(txtData)
            logger.info("📝 TXT 记录已更新")
        }
    }
    
 /// 取消注册服务
    public func unregister() {
        retryTask?.cancel()
        retryTask = nil
        
        listener?.cancel()
        listener = nil
        
        netService?.stop()
        netService = nil
        
        isRegistered = false
        assignedPort = 0
        
        logger.info("⏹️ Bonjour 服务已取消注册")
    }
    
 /// 检查服务是否已注册
    public var isServiceRegistered: Bool {
        isRegistered
    }
    
 // MARK: - Private Methods
    
    private func doRegister(
        name: String,
        connectionHandler: (@Sendable (NWConnection) -> Void)?
    ) async throws -> UInt16 {
 // 创建 NWListener
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        let newListener = try NWListener(using: parameters)
        
 // 设置服务
        let service = NWListener.Service(name: name, type: serviceType)
        newListener.service = service
        
 // 设置连接处理
        if let handler = connectionHandler {
            newListener.newConnectionHandler = { conn in handler(conn) }
        }
        
 // 设置状态处理
        let log = self.logger
        let serviceType = self.serviceType
        
        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    log.info("✅ Bonjour 服务就绪: \(serviceType, privacy: .public)")
                case .failed(let error):
                    log.error("❌ Bonjour 服务失败: \(error.localizedDescription, privacy: .public)")
 // 触发重试
                    if let self = self {
                        Task {
                            await self.scheduleRetry(name: name, connectionHandler: connectionHandler)
                        }
                    }
                case .cancelled:
                    log.info("⏹️ Bonjour 服务已取消")
                default:
                    break
                }
            }
        }
        
 // 启动监听
        newListener.start(queue: .global(qos: .utility))
        self.listener = newListener
        
 // 等待端口分配
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let port = newListener.port?.rawValue ?? 0
        self.assignedPort = UInt16(port)
        
 // 创建 NetService 以设置 TXT 记录
        if port > 0 {
            let ns = NetService(domain: "local.", type: serviceType, name: name, port: Int32(port))
            let txtData = NetService.data(fromTXTRecord: currentTXTRecord.mapValues { $0.data(using: .utf8) ?? Data() })
            ns.setTXTRecord(txtData)
            ns.publish()
            self.netService = ns
            
            logger.info("📡 Bonjour 服务已注册: \(name, privacy: .public) 端口 \(port)")
            logger.debug("📝 TXT 记录: \(self.currentTXTRecord, privacy: .public)")
        }
        
        isRegistered = true
        return UInt16(port)
    }
    
    private func scheduleRetry(
        name: String,
        connectionHandler: (@Sendable (NWConnection) -> Void)?
    ) {
        guard retryCount < maxRetries else {
            logger.error("❌ Bonjour 服务注册失败，已达最大重试次数")
            return
        }
        
        retryCount += 1
        logger.info("🔄 将在 \(self.retryDelay) 秒后重试注册 (第 \(self.retryCount) 次)")
        
        retryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            
            guard !Task.isCancelled else { return }
            
            do {
                _ = try await doRegister(name: name, connectionHandler: connectionHandler)
            } catch {
                logger.error("❌ 重试注册失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Bonjour Service Error

@available(macOS 14.0, *)
public enum BonjourServiceError: Error, LocalizedError, Sendable {
    case invalidTXTRecord(String)
    case registrationFailed(String)
    case alreadyRegistered
    case notRegistered
    
    public var errorDescription: String? {
        switch self {
        case .invalidTXTRecord(let reason):
            return "无效的 TXT 记录: \(reason)"
        case .registrationFailed(let reason):
            return "服务注册失败: \(reason)"
        case .alreadyRegistered:
            return "服务已注册"
        case .notRegistered:
            return "服务未注册"
        }
    }
}

// MARK: - TXT Record Validation Helper

@available(macOS 14.0, *)
public enum TXTRecordValidator {
    
 /// 验证 TXT 记录是否符合 SkyBridge Protocol 规范
 /// - Parameter record: TXT 记录字典
 /// - Returns: 验证结果
    public static func validate(_ record: [String: String]) -> ValidationResult {
        var missingFields: [String] = []
        var invalidFields: [String] = []
        
 // 检查必需字段
        let requiredFields = ["deviceId", "pubKeyFP", "uniqueId"]
        for field in requiredFields {
            if let value = record[field] {
                if value.isEmpty {
                    invalidFields.append("\(field): 不能为空")
                }
            } else {
                missingFields.append(field)
            }
        }
        
 // 验证 pubKeyFP 格式（应为 hex 小写）
        if let pubKeyFP = record["pubKeyFP"], !pubKeyFP.isEmpty {
            let hexPattern = "^[0-9a-f]+$"
            if pubKeyFP.range(of: hexPattern, options: .regularExpression) == nil {
                invalidFields.append("pubKeyFP: 应为 hex 小写格式")
            }
        }
        
        if missingFields.isEmpty && invalidFields.isEmpty {
            return .valid
        } else {
            return .invalid(missing: missingFields, invalid: invalidFields)
        }
    }
    
    public enum ValidationResult: Equatable, Sendable {
        case valid
        case invalid(missing: [String], invalid: [String])
        
        public var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }
}

// MARK: - Convenience Extension for DeviceCapabilities

@available(macOS 14.0, *)
extension BonjourTXTRecordBuilder {
    
 /// 从设备能力创建 TXT 记录构建器
    public static func from(
        deviceId: String,
        pubKeyFP: String,
        uniqueId: String,
        capabilities: SBDeviceCapabilities,
        protocolVersion: SBProtocolVersion = .current
    ) -> BonjourTXTRecordBuilder {
        BonjourTXTRecordBuilder(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            uniqueId: uniqueId,
            platform: SBPlatformType.current.rawValue,
            version: protocolVersion.versionString,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: capabilities.asStringArray,
            name: Host.current().localizedName
        )
    }
}


// MARK: - DiscoveryTransport Integration ( 12.2)

/// Extension to add DiscoveryTransport capabilities to EnhancedBonjourService
@available(macOS 14.0, *)
extension EnhancedBonjourService {
    
 /// 数据接收回调类型
    public typealias DataReceivedHandler = @Sendable (NWEndpoint, Data) async -> Void
    
 /// 发送数据到指定端点
 /// - Parameters:
 /// - data: 要发送的数据
 /// - endpoint: 目标端点
 /// - Throws: BonjourServiceError
    public func sendData(_ data: Data, to endpoint: NWEndpoint) async throws {
 // 创建临时连接发送数据
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
 // 等待连接就绪（使用 actor-isolated 状态追踪）
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
 // 使用 class 包装以支持 Sendable
            final class ResumeGuard: @unchecked Sendable {
                private let lock = NSLock()
                private var _resumed = false
                
                var resumed: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return _resumed
                }
                
                func tryResume() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if _resumed { return false }
                    _resumed = true
                    return true
                }
            }
            
            let guard_ = ResumeGuard()
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guard_.tryResume() {
                        continuation.resume()
                    }
                case .failed(let error):
                    if guard_.tryResume() {
                        continuation.resume(throwing: BonjourServiceError.registrationFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if guard_.tryResume() {
                        continuation.resume(throwing: BonjourServiceError.notRegistered)
                    }
                default:
                    break
                }
            }
            
            connection.start(queue: .global(qos: .userInitiated))
        }
        
 // 发送数据（带长度前缀）
        let framedData = frameData(data)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: framedData,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: BonjourServiceError.registrationFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
        
 // 关闭连接
        connection.cancel()
    }
    
 /// 添加长度前缀帧
    private func frameData(_ data: Data) -> Data {
        var framedData = Data()
        
 // 4 字节长度前缀（big-endian）
        var length = UInt32(data.count).bigEndian
        framedData.append(Data(bytes: &length, count: 4))
        framedData.append(data)
        
        return framedData
    }
}

// MARK: - BonjourDiscoveryTransportAdapter

/// 适配器：将 EnhancedBonjourService 适配为 DiscoveryTransport
///
/// 这个适配器允许 HandshakeDriver 使用 EnhancedBonjourService 进行通信
@available(macOS 14.0, *)
public actor BonjourDiscoveryTransportAdapter: DiscoveryTransport {
    
 /// 底层 Bonjour 服务
    private let bonjourService: EnhancedBonjourService
    
 /// 端点映射（deviceId -> endpoint）
    private var endpointMap: [String: NWEndpoint] = [:]
    
 /// 消息处理回调
    private var messageHandler: (@Sendable (PeerIdentifier, Data) async -> Void)?
    
    public init(bonjourService: EnhancedBonjourService) {
        self.bonjourService = bonjourService
    }
    
 // MARK: - DiscoveryTransport Protocol
    
    public func send(to peer: PeerIdentifier, data: Data) async throws {
        guard let endpoint = endpointMap[peer.deviceId] else {
 // 尝试从地址创建端点
            if let address = peer.address {
                let (host, port) = parseAddress(address)
                let endpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(host),
                    port: NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 8765)!
                )
                try await bonjourService.sendData(data, to: endpoint)
                return
            }
            throw DiscoveryTransportError.peerUnreachable(peer)
        }
        
        try await bonjourService.sendData(data, to: endpoint)
    }
    
 // MARK: - Public API
    
 /// 注册对端端点
 /// - Parameters:
 /// - peer: 对端标识
 /// - endpoint: 网络端点
    public func registerEndpoint(_ endpoint: NWEndpoint, for peer: PeerIdentifier) {
        endpointMap[peer.deviceId] = endpoint
    }
    
 /// 移除对端端点
 /// - Parameter peer: 对端标识
    public func removeEndpoint(for peer: PeerIdentifier) {
        endpointMap.removeValue(forKey: peer.deviceId)
    }
    
 /// 设置消息处理回调
    public func setMessageHandler(
        _ handler: @escaping @Sendable (PeerIdentifier, Data) async -> Void
    ) {
        messageHandler = handler
    }
    
 /// 处理接收到的数据
 /// - Parameters:
 /// - data: 接收到的数据
 /// - endpoint: 来源端点
    public func handleReceivedData(_ data: Data, from endpoint: NWEndpoint) async {
 // 查找对应的 peer
        let peer = findPeer(for: endpoint)
        await messageHandler?(peer, data)
    }
    
 // MARK: - Private Methods
    
 /// 查找端点对应的 peer
    private func findPeer(for endpoint: NWEndpoint) -> PeerIdentifier {
 // 反向查找
        for (deviceId, ep) in endpointMap {
            if endpointsMatch(ep, endpoint) {
                return PeerIdentifier(deviceId: deviceId)
            }
        }
        
 // 未找到，创建临时标识
        var address: String?
        if case .hostPort(let host, let port) = endpoint {
            address = "\(host):\(port)"
        }
        return PeerIdentifier(
            deviceId: "unknown-\(endpoint.hashValue)",
            address: address
        )
    }
    
 /// 比较两个端点是否匹配
    private func endpointsMatch(_ ep1: NWEndpoint, _ ep2: NWEndpoint) -> Bool {
        switch (ep1, ep2) {
        case (.hostPort(let h1, let p1), .hostPort(let h2, let p2)):
            return h1 == h2 && p1 == p2
        default:
            return false
        }
    }
    
 /// 解析地址字符串
    private func parseAddress(_ address: String) -> (host: String, port: UInt16) {
        let components = address.split(separator: ":")
        if components.count == 2,
           let port = UInt16(components[1]) {
            return (String(components[0]), port)
        }
        return (address, 8765)
    }
}
