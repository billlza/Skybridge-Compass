import Foundation
import Network

/// STUN客户端类，用于NAT穿透
public final class STUNClient: ObservableObject, @unchecked Sendable {
    
 // MARK: - 属性
    
 /// STUN服务器
    private let server: STUNServer
    private let networkQueue: DispatchQueue
    private var udpConnection: NWConnection?
    
 // STUN消息类型
    private enum STUNMessageType: UInt16 {
        case bindingRequest = 0x0001
        case bindingResponse = 0x0101
        case bindingErrorResponse = 0x0111
    }
    
 // STUN属性类型
    private enum STUNAttributeType: UInt16 {
        case mappedAddress = 0x0001
        case responseAddress = 0x0002
        case changeRequest = 0x0003
        case sourceAddress = 0x0004
        case changedAddress = 0x0005
        case username = 0x0006
        case password = 0x0007
        case messageIntegrity = 0x0008
        case errorCode = 0x0009
        case unknownAttributes = 0x000A
        case reflectedFrom = 0x000B
        case xorMappedAddress = 0x0020
    }
    
 // MARK: - 初始化
    
    public init(server: STUNServer) {
        self.server = server
        self.networkQueue = DispatchQueue(label: "com.skybridge.stun.client", qos: .userInitiated)
        
        SkyBridgeLogger.p2p.debugOnly("🎯 STUN客户端初始化: \(server.host):\(server.port)")
    }
    
    deinit {
 // 在 deinit 中避免使用 ，直接调用同步方法
        udpConnection?.cancel()
        udpConnection = nil
    }
    
 // MARK: - 公共方法
    
 /// 获取公网IP地址和端口
    public func getPublicEndpoint(completion: @escaping @Sendable (Result<NWEndpoint, STUNError>) -> Void) {
        SkyBridgeLogger.p2p.debugOnly("🌐 开始获取公网端点")
        
        Task {
            await performSTUNBinding { result in
                Task { @MainActor in
                    completion(result)
                }
            }
        }
    }
    
 /// 检测NAT类型
    public func detectNATType(completion: @escaping @Sendable (Result<NATType, STUNError>) -> Void) {
        SkyBridgeLogger.p2p.debugOnly("🔍 开始检测NAT类型")
        
        Task {
            await performNATTypeDetection { result in
 // 直接调用 completion，避免跨任务传递
                completion(result)
            }
        }
    }
    
 /// 断开STUN连接
    public func disconnect() {
        udpConnection?.cancel()
        udpConnection = nil
        SkyBridgeLogger.p2p.debugOnly("🔌 STUN客户端已断开连接")
    }
    
 // MARK: - 私有方法
    
 /// 执行STUN绑定请求
    private func performSTUNBinding(completion: @escaping @Sendable (Result<NWEndpoint, STUNError>) -> Void) async {
 // 创建UDP连接到STUN服务器
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(integerLiteral: server.port)
        )
        
        let parameters = NWParameters.udp
        udpConnection = NWConnection(to: endpoint, using: parameters)
        
        udpConnection?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                SkyBridgeLogger.p2p.debugOnly("✅ STUN连接已建立")
                Task {
                    await self.sendBindingRequest(completion: completion)
                }
                
            case .failed(let error):
                SkyBridgeLogger.p2p.error("❌ STUN连接失败: \(error.localizedDescription, privacy: .private)")
                completion(.failure(.connectionFailed))
                
            case .cancelled:
                SkyBridgeLogger.p2p.debugOnly("🔌 STUN连接已取消")
                completion(.failure(.connectionCancelled))
                
            default:
                break
            }
        }
        
        udpConnection?.start(queue: networkQueue)
    }
    
 /// 发送绑定请求
    private func sendBindingRequest(completion: @escaping @Sendable (Result<NWEndpoint, STUNError>) -> Void) async {
 // 生成随机事务ID
        let transactionId = generateTransactionId()
        
 // 构建STUN绑定请求消息
        let message = buildSTUNMessage(
            type: .bindingRequest,
            transactionId: transactionId
        )
        
        SkyBridgeLogger.p2p.debugOnly("📤 发送STUN绑定请求")
        
        udpConnection?.send(content: message, completion: .contentProcessed { error in
            if let error = error {
                SkyBridgeLogger.p2p.error("❌ STUN请求发送失败: \(error.localizedDescription, privacy: .private)")
                completion(.failure(.requestFailed))
                return
            }
            
 // 接收响应
            Task {
                await self.receiveBindingResponse(
                    expectedTransactionId: transactionId,
                    completion: completion
                )
            }
        })
    }
    
 /// 接收绑定响应
    private func receiveBindingResponse(expectedTransactionId: Data,
                                       completion: @escaping @Sendable (Result<NWEndpoint, STUNError>) -> Void) async {
        
        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
            
            if let error = error {
                SkyBridgeLogger.p2p.error("❌ STUN响应接收失败: \(error.localizedDescription, privacy: .private)")
                completion(.failure(.responseFailed))
                return
            }
            
            guard let data = data, !data.isEmpty else {
                SkyBridgeLogger.p2p.error("❌ 收到空的STUN响应")
                completion(.failure(.invalidResponse))
                return
            }
            
            SkyBridgeLogger.p2p.debugOnly("📥 收到STUN响应: \(data.count)字节")
            
 // 解析STUN响应
            do {
                let endpoint = try self.parseBindingResponse(data, expectedTransactionId: expectedTransactionId)
                SkyBridgeLogger.p2p.debugOnly("✅ 解析到公网端点: \(String(describing: endpoint))")
                completion(.success(endpoint))
            } catch {
                SkyBridgeLogger.p2p.error("❌ STUN响应解析失败: \(error.localizedDescription, privacy: .private)")
                completion(.failure(.invalidResponse))
            }
        }
    }
    
 /// 执行NAT类型检测
    private func performNATTypeDetection(completion: @escaping @Sendable (Result<NATType, STUNError>) -> Void) async {
 // 执行STUN绑定请求
        await performSTUNBinding { result in
            switch result {
            case .success:
 // 简化的NAT类型检测，实际应用中需要更复杂的逻辑
                completion(.success(.fullCone))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
 /// 生成事务ID
    private func generateTransactionId() -> Data {
        var transactionId = Data(count: 12)
        let result = transactionId.withUnsafeMutableBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, 12, base)
        }
        
        if result != errSecSuccess {
 // 如果安全随机数生成失败，使用系统随机数
            for i in 0..<12 {
                transactionId[i] = UInt8.random(in: 0...255)
            }
        }
        
        return transactionId
    }
    
 /// 构建STUN消息
    private func buildSTUNMessage(type: STUNMessageType, transactionId: Data) -> Data {
        var message = Data()
        
 // STUN消息头 (20字节)
 // 消息类型 (2字节)
        message.append(contentsOf: withUnsafeBytes(of: type.rawValue.bigEndian) { Array($0) })
        
 // 消息长度 (2字节) - 占位符，在函数末尾更新为实际长度
        message.append(contentsOf: [0x00, 0x00])
        
 // Magic Cookie (4字节)
        let magicCookie: UInt32 = 0x2112A442
        message.append(contentsOf: withUnsafeBytes(of: magicCookie.bigEndian) { Array($0) })
        
 // 事务ID (12字节)
        message.append(transactionId)
        
 // 更新消息长度
        let bodyLength = UInt16(message.count - 20)
        message.replaceSubrange(2..<4, with: withUnsafeBytes(of: bodyLength.bigEndian) { Array($0) })
        
        return message
    }
    
 /// 解析绑定响应
    private func parseBindingResponse(_ data: Data, expectedTransactionId: Data) throws -> NWEndpoint {
        guard data.count >= 20 else {
            throw STUNError.invalidResponse
        }
        
 // 验证STUN消息头
        let messageType = data.withUnsafeBytes { bytes in
            UInt16(bigEndian: bytes.load(fromByteOffset: 0, as: UInt16.self))
        }
        
        guard messageType == STUNMessageType.bindingResponse.rawValue else {
            throw STUNError.invalidResponse
        }
        
        let messageLength = data.withUnsafeBytes { bytes in
            UInt16(bigEndian: bytes.load(fromByteOffset: 2, as: UInt16.self))
        }
        
        let magicCookie = data.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.load(fromByteOffset: 4, as: UInt32.self))
        }
        
        guard magicCookie == 0x2112A442 else {
            throw STUNError.invalidResponse
        }
        
        let transactionId = data.subdata(in: 8..<20)
        guard transactionId == expectedTransactionId else {
            throw STUNError.invalidResponse
        }
        
 // 解析属性
        var offset = 20
        let endOffset = min(data.count, Int(20 + messageLength))
        
        while offset < endOffset {
            guard offset + 4 <= data.count else { break }
            
            let attributeType = data.withUnsafeBytes { bytes in
                UInt16(bigEndian: bytes.load(fromByteOffset: offset, as: UInt16.self))
            }
            
            let attributeLength = data.withUnsafeBytes { bytes in
                UInt16(bigEndian: bytes.load(fromByteOffset: offset + 2, as: UInt16.self))
            }
            
            offset += 4
            
            guard offset + Int(attributeLength) <= data.count else { break }
            
            if attributeType == STUNAttributeType.xorMappedAddress.rawValue ||
               attributeType == STUNAttributeType.mappedAddress.rawValue {
                
                let attributeData = data.subdata(in: offset..<(offset + Int(attributeLength)))
                
                if let endpoint = parseAddressAttribute(attributeData, isXOR: attributeType == STUNAttributeType.xorMappedAddress.rawValue) {
                    return endpoint
                }
            }
            
 // 移动到下一个属性（4字节对齐）
            offset += Int(attributeLength)
            offset = (offset + 3) & ~3
        }
        
        throw STUNError.noMappedAddress
    }
    
 /// 解析地址属性
    private func parseAddressAttribute(_ data: Data, isXOR: Bool) -> NWEndpoint? {
        guard data.count >= 8 else { return nil }
        
 // 跳过保留字节
        let family = data[1]
        guard family == 0x01 else { return nil } // IPv4
        
        var port = data.withUnsafeBytes { bytes in
            UInt16(bigEndian: bytes.load(fromByteOffset: 2, as: UInt16.self))
        }
        
        var address = data.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.load(fromByteOffset: 4, as: UInt32.self))
        }
        
 // 如果是XOR映射地址，需要进行XOR操作
        if isXOR {
            port ^= 0x2112
            address ^= 0x2112A442
        }
        
 // 转换为IP地址字符串
        let ipBytes = withUnsafeBytes(of: address.bigEndian) { Array($0) }
        let ipString = "\(ipBytes[0]).\(ipBytes[1]).\(ipBytes[2]).\(ipBytes[3])"
        
        return NWEndpoint.hostPort(
            host: NWEndpoint.Host(ipString),
            port: NWEndpoint.Port(integerLiteral: port)
        )
    }
}

// MARK: - 支持类型

// 删除重复的枚举定义，使用P2PModels.swift中的定义
// public enum NATType: String, CaseIterable {
// case fullCone = "完全锥形NAT"
// case restrictedCone = "限制锥形NAT"
// case portRestrictedCone = "端口限制锥形NAT"
// case symmetric = "对称NAT"
// case noNAT = "无NAT"
// case unknown = "未知"
//
// public var displayName: String {
// return rawValue
// }
//
// public var traversalDifficulty: TraversalDifficulty {
// switch self {
// case .noNAT, .fullCone:
// return .easy
// case .restrictedCone, .portRestrictedCone:
// return .medium
// case .symmetric:
// return .hard
// case .unknown:
// return .unknown
// }
// }
// }

// 删除重复的枚举定义，使用P2PModels.swift中的定义
// public enum TraversalDifficulty: String, CaseIterable {
// case easy = "简单"
// case medium = "中等"
// case hard = "困难"
// case unknown = "未知"
//
// public var displayName: String {
// return rawValue
// }
// }

/// STUN错误
public enum STUNError: LocalizedError {
    case connectionFailed
    case connectionCancelled
    case requestFailed
    case responseFailed
    case invalidResponse
    case noMappedAddress
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "STUN服务器连接失败"
        case .connectionCancelled:
            return "STUN连接被取消"
        case .requestFailed:
            return "STUN请求发送失败"
        case .responseFailed:
            return "STUN响应接收失败"
        case .invalidResponse:
            return "无效的STUN响应"
        case .noMappedAddress:
            return "未找到映射地址"
        case .timeout:
            return "STUN请求超时"
        }
    }
}
