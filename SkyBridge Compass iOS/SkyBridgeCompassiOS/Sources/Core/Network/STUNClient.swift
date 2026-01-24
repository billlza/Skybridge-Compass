//
// STUNClient.swift
// SkyBridgeCompassiOS
//
// STUN 客户端 - 用于 NAT 类型检测和地址发现
// 支持 RFC 5389 STUN 协议
//

import Foundation
import Network

// MARK: - STUN Message Type

/// STUN 消息类型
public struct STUNMessageType {
    public static let bindingRequest: UInt16 = 0x0001
    public static let bindingResponse: UInt16 = 0x0101
    public static let bindingErrorResponse: UInt16 = 0x0111
}

// MARK: - STUN Attribute Type

/// STUN 属性类型
public struct STUNAttributeType {
    public static let mappedAddress: UInt16 = 0x0001
    public static let responseAddress: UInt16 = 0x0002
    public static let changeRequest: UInt16 = 0x0003
    public static let sourceAddress: UInt16 = 0x0004
    public static let changedAddress: UInt16 = 0x0005
    public static let username: UInt16 = 0x0006
    public static let password: UInt16 = 0x0007
    public static let messageIntegrity: UInt16 = 0x0008
    public static let errorCode: UInt16 = 0x0009
    public static let unknownAttributes: UInt16 = 0x000A
    public static let reflectedFrom: UInt16 = 0x000B
    public static let xorMappedAddress: UInt16 = 0x0020
    public static let software: UInt16 = 0x8022
    public static let alternateServer: UInt16 = 0x8023
    public static let fingerprint: UInt16 = 0x8028
}

// MARK: - STUN Result

/// STUN 查询结果
public struct STUNResult: Sendable {
    public let publicAddress: String
    public let publicPort: UInt16
    public let natType: NATType
    public let localAddress: String?
    public let localPort: UInt16?
    
    public init(
        publicAddress: String,
        publicPort: UInt16,
        natType: NATType = .unknown,
        localAddress: String? = nil,
        localPort: UInt16? = nil
    ) {
        self.publicAddress = publicAddress
        self.publicPort = publicPort
        self.natType = natType
        self.localAddress = localAddress
        self.localPort = localPort
    }
}

// MARK: - STUN Error

/// STUN 错误
public enum STUNError: Error, LocalizedError, Sendable {
    case connectionFailed
    case timeout
    case invalidResponse
    case noMappedAddress
    case serverUnreachable
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "STUN 连接失败"
        case .timeout: return "STUN 请求超时"
        case .invalidResponse: return "无效的 STUN 响应"
        case .noMappedAddress: return "未能获取映射地址"
        case .serverUnreachable: return "STUN 服务器不可达"
        }
    }
}

// MARK: - STUN Client

/// STUN 客户端
@available(iOS 17.0, *)
public actor STUNClient {
    
    // MARK: - Properties
    
    private let servers: [STUNServer]
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.skybridge.stun", qos: .utility)
    
    /// Magic Cookie (RFC 5389)
    private let magicCookie: UInt32 = 0x2112A442
    
    // MARK: - Initialization
    
    public init(servers: [STUNServer] = STUNServer.defaultServers, timeout: TimeInterval = 5.0) {
        self.servers = servers
        self.timeout = timeout
    }
    
    // MARK: - Public Methods
    
    /// 发现公网地址
    public func discoverPublicAddress() async throws -> STUNResult {
        // 尝试所有 STUN 服务器
        for server in servers {
            do {
                let result = try await queryServer(server)
                SkyBridgeLogger.shared.info("✅ STUN 发现公网地址: \(result.publicAddress):\(result.publicPort)")
                return result
            } catch {
                SkyBridgeLogger.shared.warning("⚠️ STUN 服务器 \(server.host) 失败: \(error.localizedDescription)")
                continue
            }
        }
        
        throw STUNError.serverUnreachable
    }
    
    /// 检测 NAT 类型
    public func detectNATType() async throws -> NATType {
        // 简化的 NAT 类型检测
        // 完整实现需要多次查询不同的 STUN 服务器
        
        guard let firstResult = try? await discoverPublicAddress() else {
            return .unknown
        }
        
        // 如果公网地址与本地地址相同，则没有 NAT
        if firstResult.publicAddress == firstResult.localAddress {
            return .noNAT
        }
        
        // 尝试第二个服务器
        if servers.count > 1 {
            let secondServer = servers[1]
            if let secondResult = try? await queryServer(secondServer) {
                // 如果两个服务器返回相同的映射地址，可能是锥形 NAT
                if firstResult.publicAddress == secondResult.publicAddress &&
                   firstResult.publicPort == secondResult.publicPort {
                    return .fullCone
                } else {
                    return .symmetric
                }
            }
        }
        
        return .unknown
    }
    
    // MARK: - Private Methods
    
    private func queryServer(_ server: STUNServer) async throws -> STUNResult {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(integerLiteral: server.port)
        )
        
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
        // 等待连接就绪
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: STUNError.connectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        
        defer { connection.cancel() }
        
        // 构建并发送 STUN 绑定请求
        let request = buildBindingRequest()
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: request, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        
        // 接收响应
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 20, maximumLength: 1024) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: STUNError.invalidResponse)
                }
            }
        }
        
        // 解析响应
        return try parseBindingResponse(response)
    }
    
    /// 构建 STUN 绑定请求
    private func buildBindingRequest() -> Data {
        var data = Data()
        
        // 消息类型 (Binding Request)
        data.append(contentsOf: withUnsafeBytes(of: STUNMessageType.bindingRequest.bigEndian) { Array($0) })
        
        // 消息长度 (0 for simple binding request)
        data.append(contentsOf: [0x00, 0x00])
        
        // Magic Cookie
        data.append(contentsOf: withUnsafeBytes(of: magicCookie.bigEndian) { Array($0) })
        
        // Transaction ID (12 bytes random)
        var transactionId = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            transactionId[i] = UInt8.random(in: 0...255)
        }
        data.append(contentsOf: transactionId)
        
        return data
    }
    
    /// 解析 STUN 绑定响应
    private func parseBindingResponse(_ data: Data) throws -> STUNResult {
        guard data.count >= 20 else {
            throw STUNError.invalidResponse
        }
        
        // 检查消息类型
        let messageType = UInt16(data[0]) << 8 | UInt16(data[1])
        guard messageType == STUNMessageType.bindingResponse else {
            throw STUNError.invalidResponse
        }
        
        // 消息长度
        let messageLength = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        
        // 跳过头部 (20 bytes)，解析属性
        var offset = 20
        var publicAddress: String?
        var publicPort: UInt16?
        
        while offset + 4 <= 20 + messageLength && offset + 4 <= data.count {
            let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            
            offset += 4
            
            guard offset + attrLength <= data.count else { break }
            
            if attrType == STUNAttributeType.xorMappedAddress {
                // XOR-MAPPED-ADDRESS
                if attrLength >= 8 {
                    let family = data[offset + 1]
                    let xorPort = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
                    publicPort = xorPort ^ UInt16(magicCookie >> 16)
                    
                    if family == 0x01 { // IPv4
                        let xorIP = UInt32(data[offset + 4]) << 24 |
                                    UInt32(data[offset + 5]) << 16 |
                                    UInt32(data[offset + 6]) << 8 |
                                    UInt32(data[offset + 7])
                        let ip = xorIP ^ magicCookie
                        publicAddress = "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
                    }
                }
            } else if attrType == STUNAttributeType.mappedAddress && publicAddress == nil {
                // MAPPED-ADDRESS (fallback)
                if attrLength >= 8 {
                    let family = data[offset + 1]
                    publicPort = UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3])
                    
                    if family == 0x01 { // IPv4
                        publicAddress = "\(data[offset + 4]).\(data[offset + 5]).\(data[offset + 6]).\(data[offset + 7])"
                    }
                }
            }
            
            // 对齐到 4 字节边界
            let padding = (4 - (attrLength % 4)) % 4
            offset += attrLength + padding
        }
        
        guard let address = publicAddress, let port = publicPort else {
            throw STUNError.noMappedAddress
        }
        
        return STUNResult(publicAddress: address, publicPort: port)
    }
}

// MARK: - NAT Traversal Helper

/// NAT 穿透辅助
@available(iOS 17.0, *)
public actor NATTraversalHelper {
    
    private let stunClient: STUNClient
    private var cachedNATType: NATType?
    private var cachedPublicEndpoint: (address: String, port: UInt16)?
    private var lastDiscoveryTime: Date?
    
    public init(stunClient: STUNClient = STUNClient()) {
        self.stunClient = stunClient
    }
    
    /// 获取公网端点（带缓存）
    public func getPublicEndpoint(forceRefresh: Bool = false) async throws -> (address: String, port: UInt16) {
        // 检查缓存是否有效（5分钟内）
        if !forceRefresh,
           let cached = cachedPublicEndpoint,
           let lastTime = lastDiscoveryTime,
           Date().timeIntervalSince(lastTime) < 300 {
            return cached
        }
        
        let result = try await stunClient.discoverPublicAddress()
        cachedPublicEndpoint = (result.publicAddress, result.publicPort)
        lastDiscoveryTime = Date()
        
        return (result.publicAddress, result.publicPort)
    }
    
    /// 获取 NAT 类型（带缓存）
    public func getNATType(forceRefresh: Bool = false) async throws -> NATType {
        if !forceRefresh, let cached = cachedNATType {
            return cached
        }
        
        let natType = try await stunClient.detectNATType()
        cachedNATType = natType
        
        return natType
    }
    
    /// 判断是否可以进行 P2P 直连
    public func canEstablishDirectConnection(with peerNATType: NATType) async -> Bool {
        // 获取本地 NAT 类型
        let localNATType: NATType
        if let cached = cachedNATType {
            localNATType = cached
        } else if let detected = try? await getNATType() {
            localNATType = detected
        } else {
            return false
        }
        
        // NAT 兼容性矩阵
        return checkNATCompatibility(local: localNATType, peer: peerNATType)
    }
    
    /// 检查 NAT 兼容性
    private func checkNATCompatibility(local: NATType, peer: NATType) -> Bool {
        switch (local, peer) {
        case (.noNAT, _), (_, .noNAT):
            return true
        case (.fullCone, .fullCone), (.fullCone, .restrictedCone), (.restrictedCone, .fullCone):
            return true
        case (.restrictedCone, .restrictedCone):
            return true
        case (.portRestrictedCone, .fullCone), (.fullCone, .portRestrictedCone):
            return true
        case (.symmetric, .fullCone), (.fullCone, .symmetric):
            return true
        case (.symmetric, .symmetric):
            return false // 需要 TURN 服务器
        default:
            return false
        }
    }
}

