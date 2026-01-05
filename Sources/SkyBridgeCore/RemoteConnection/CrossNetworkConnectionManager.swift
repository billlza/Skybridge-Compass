import Foundation
import Network
import CryptoKit
import Combine
import OSLog

/// 跨网络连接管理器 - 2025年创新架构
///
/// 三层连接方案：
/// 1. 动态二维码 + NFC 近场连接
/// 2. Apple ID / iCloud 设备链（零配置）
/// 3. 智能连接码 + P2P 穿透（通用方案）
@MainActor
public final class CrossNetworkConnectionManager: ObservableObject {
    
 // MARK: - 发布属性
    
    @Published public var connectionCode: String?
    @Published public var qrCodeData: Data?
    @Published public var availableCloudDevices: [CloudDevice] = []
    @Published public var connectionStatus: CrossNetworkConnectionStatus = .idle
    @Published public var currentConnection: RemoteConnection?
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.connection", category: "CrossNetwork")
    private let signalServer: SignalServerClient
    private let stunServers: [String] = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
        "stun:stun2.l.google.com:19302"
    ]
    private var activeListeners: [ConnectionListener] = []
    private var deviceFingerprint: String
    
 // MARK: - 连接状态
    
 /// 跨网络连接状态 - 符合Swift 6.2.1的Sendable要求和严格并发控制
 /// 注意：这是CrossNetworkConnectionManager专用的连接状态，与全局ConnectionStatus不同
    public enum CrossNetworkConnectionStatus: Sendable {
        case idle
        case generating
        case waiting(code: String)
        case connecting
        case connected
        case failed(String) // 使用String而不是Error，以符合Sendable要求
    }
    
 // 为了向后兼容，保留类型别名（但建议使用 CrossNetworkConnectionStatus）
    @available(*, deprecated, renamed: "CrossNetworkConnectionStatus", message: "使用 CrossNetworkConnectionStatus 以避免与全局 ConnectionStatus 冲突")
    public typealias ConnectionStatus = CrossNetworkConnectionStatus
    
 // MARK: - 初始化
    
    public init() {
        self.signalServer = SignalServerClient()
        self.deviceFingerprint = Self.generateDeviceFingerprint()
        
        logger.info("跨网络连接管理器初始化完成")
    }
    
 // MARK: - 1️⃣ 动态二维码连接
    
 /// 生成动态加密二维码
 /// 包含：设备指纹 + 临时密钥 + ICE 候选信息 + 过期时间
    public func generateDynamicQRCode(validDuration: TimeInterval = 300) async throws -> Data {
        logger.info("生成动态二维码，有效期: \(validDuration)秒")
        connectionStatus = .generating
        
 // 1. 生成会话密钥对（Curve25519 用于密钥协商）
 // 会话密钥用于后续P2P加密握手，独立于签名密钥
        let agreementPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let agreementPublicKey = agreementPrivateKey.publicKey

 // 1.1 生成签名密钥对（P256 ECDSA 用于二维码内容签名）
 // 统一采用 P256.Signing 以适配安全管理器的验签逻辑
        let signingPrivateKey = P256.Signing.PrivateKey()
        let signingPublicKey = signingPrivateKey.publicKey
        let signingPublicKeyData = signingPublicKey.rawRepresentation
        let signingFingerprintHex = SHA256.hash(data: signingPublicKeyData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
 // 签名时间戳，用于时效与重放保护
        let signatureTimestamp = Date().timeIntervalSince1970
        
 // 2. 注册到信号服务器
        let sessionID = UUID().uuidString
        _ = try await signalServer.registerSession(
            sessionID: sessionID,
            deviceFingerprint: deviceFingerprint,
            publicKey: agreementPublicKey.rawRepresentation,
            validDuration: validDuration
        )
        
 // 3. 构建 QR 码数据结构
 // 为统一验签，签名覆盖规范化负载（参照 P2PSecurityManager）
 // 规范化负载包含：设备ID/名称/类型/地址/端口/系统版本/能力列表/时间戳/指纹
        let canonicalPayload = Self.buildCanonicalSignaturePayload(
            id: deviceFingerprint,
            name: Host.current().localizedName ?? "Mac",
            type: .macOS,
            address: "0.0.0.0",
            port: 0,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: ["p2p", "cross-network"],
            timestamp: signatureTimestamp,
            fingerprintHex: signingFingerprintHex
        )
        let signature = try signingPrivateKey.signature(for: canonicalPayload)
        
        let qrData = DynamicQRCodeData(
            version: 2,
            sessionID: sessionID,
            deviceName: Host.current().localizedName ?? "Mac",
            deviceFingerprint: deviceFingerprint,
            publicKey: agreementPublicKey.rawRepresentation, // 用于密钥协商的公钥
            signingPublicKey: signingPublicKeyData,           // 用于验签的公钥
            signature: signature.rawRepresentation,           // P256 ECDSA 原始签名
            signatureTimestamp: signatureTimestamp,
            iceServers: stunServers,
            expiresAt: Date().addingTimeInterval(validDuration)
        )
        
 // 4. 编码为 JSON + Base64
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(qrData)
        let base64String = jsonData.base64EncodedString()
        
 // 5. 添加协议前缀（用于识别）
        let qrString = "skybridge://connect/\(base64String)"
        
        self.qrCodeData = qrString.data(using: .utf8)
        self.connectionStatus = .waiting(code: sessionID)
        
 // 6. 启动监听
        startListeningForConnection(sessionID: sessionID, privateKey: agreementPrivateKey)
        
        logger.info("✅ 动态二维码生成成功，会话ID: \(sessionID)")
        return qrCodeData!
    }
    
 /// 扫描并解析动态二维码
    public func scanDynamicQRCode(_ data: Data) async throws -> RemoteConnection {
        logger.info("扫描动态二维码")
        
        guard let qrString = String(data: data, encoding: .utf8),
              qrString.hasPrefix("skybridge://connect/") else {
            throw CrossNetworkConnectionError.invalidQRCode
        }
        
 // 1. 解析 QR 码
        let base64Part = qrString.replacingOccurrences(of: "skybridge://connect/", with: "")
        guard let jsonData = Data(base64Encoded: base64Part) else {
            throw CrossNetworkConnectionError.invalidQRCode
        }
        
        let decoder = JSONDecoder()
        let qrData = try decoder.decode(DynamicQRCodeData.self, from: jsonData)
        
 // 2. 验证有效期
        guard qrData.expiresAt > Date() else {
            throw CrossNetworkConnectionError.qrCodeExpired
        }
        
 // 3. 验证签名（统一接入 P2PSecurityManager）
 // 基于二维码中的签名公钥与签名，对规范化负载进行验签
        let securityManager = P2PSecurityManager()
 // 兼容老版本二维码（v1），若缺少签名字段则直接判为无效
        guard let signingKeyData = qrData.signingPublicKey, let signatureData = qrData.signature else {
            logger.error("二维码缺少签名或签名公钥字段")
            throw CrossNetworkConnectionError.invalidSignature
        }
        let deviceForVerify = P2PDevice(
            id: qrData.deviceFingerprint,
            name: qrData.deviceName,
            type: .macOS,
            address: "0.0.0.0",
            port: 0,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            capabilities: ["p2p", "cross-network"],
            publicKey: signingKeyData,
            lastSeen: Date(),
            endpoints: [],
            lastMessageTimestamp: nil,
            isVerified: false,
            verificationFailedReason: nil
        )
        let verifyResult = securityManager.verifyQRCodeSignature(
            for: deviceForVerify,
            publicKeyBase64: signingKeyData.base64EncodedString(),
            signatureBase64: signatureData.base64EncodedString(),
            timestamp: qrData.signatureTimestamp,
            fingerprintHex: nil
        )
        guard verifyResult.ok else {
            logger.error("二维码验签失败：\(verifyResult.reason ?? "未知原因")")
            throw CrossNetworkConnectionError.invalidSignature
        }
        
 // 4. 建立 P2P 连接
        let connection = try await establishP2PConnection(with: qrData)
        
        self.currentConnection = connection
        self.connectionStatus = .connected
        
        logger.info("✅ 通过二维码连接成功")
        return connection
    }
    
 // MARK: - 2️⃣ iCloud 设备链连接
    
 /// 发现同 Apple ID 下的所有设备
    public func discoverCloudDevices() async throws {
        logger.info("🔍 发现 iCloud 设备链")
        
 // 使用 CloudKitService 获取设备列表
        await CloudKitService.shared.refreshDevices()
        
 // 获取设备列表（排除当前设备）
        let currentDeviceId = Self.generateDeviceFingerprint()
        let allDevices = CloudKitService.shared.devices
        
 // 过滤掉当前设备和离线设备（1小时内活跃）
        let activeDevices = allDevices.filter { device in
            device.id != currentDeviceId &&
            device.lastSeenAt.timeIntervalSinceNow > -3600
        }
        
        self.availableCloudDevices = activeDevices
        logger.info("✅ 发现 \(activeDevices.count) 台 iCloud 设备")
    }
    
 /// 通过 iCloud 设备链连接
    public func connectToCloudDevice(_ device: CloudDevice) async throws -> RemoteConnection {
        logger.info("连接到 iCloud 设备: \(device.name)")
        connectionStatus = .connecting
        
 // 1. 通过 iCloud KV Store 交换 ICE 候选
        let sessionID = UUID().uuidString
        let offer = try await createConnectionOffer(sessionID: sessionID)
        
 // 2. 写入 offer 到 iCloud
        let kvStore = NSUbiquitousKeyValueStore.default
        if let offerData = try? JSONEncoder().encode(offer) {
            kvStore.set(offerData, forKey: "skybridge.offer.\(device.id)")
            kvStore.synchronize()
        }
        
 // 3. 等待 answer（轮询或推送）
        let answer = try await waitForAnswer(deviceID: device.id, timeout: 30)
        
 // 4. 建立连接
        let connection = try await finalizeConnection(offer: offer, answer: answer)
        
        self.currentConnection = connection
        self.connectionStatus = .connected
        
        logger.info("✅ 通过 iCloud 连接成功")
        return connection
    }
    
 // MARK: - 3️⃣ 智能连接码
    
 /// 生成智能连接码（6位字母数字）
    public func generateConnectionCode() async throws -> String {
        logger.info("生成智能连接码")
        connectionStatus = .generating
        
 // 1. 生成短码
        let code = Self.generateShortCode()
        
 // 2. 生成密钥对
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
 // 3. 注册到信号服务器
        _ = try await signalServer.registerConnectionCode(
            code: code,
            deviceFingerprint: deviceFingerprint,
            deviceName: Host.current().localizedName ?? "Mac",
            publicKey: publicKey.rawRepresentation,
            validDuration: 600 // 10分钟有效期
        )
        
        self.connectionCode = code
        self.connectionStatus = .waiting(code: code)
        
 // 4. 启动监听
        startListeningForCodeConnection(code: code, privateKey: privateKey)
        
        logger.info("✅ 连接码生成成功: \(code)")
        return code
    }
    
 /// 通过连接码连接
    public func connectWithCode(_ code: String) async throws -> RemoteConnection {
        logger.info("使用连接码连接: \(code)")
        connectionStatus = .connecting
        
 // 1. 从信号服务器查询设备信息
        let deviceInfo = try await signalServer.queryConnectionCode(code: code)
        
 // 2. 验证设备指纹
        guard Self.isValidDeviceFingerprint(deviceInfo.deviceFingerprint) else {
            throw CrossNetworkConnectionError.invalidDevice
        }
        
 // 3. 建立 P2P 连接（STUN/TURN）
        let connection = try await establishP2PConnectionWithCode(
            code: code,
            deviceInfo: deviceInfo
        )
        
        self.currentConnection = connection
        self.connectionStatus = .connected
        
        logger.info("✅ 通过连接码连接成功")
        return connection
    }
    
 // MARK: - 私有方法 - P2P 连接建立
    
    private func establishP2PConnection(with qrData: DynamicQRCodeData) async throws -> RemoteConnection {
        logger.info("建立 P2P 连接（二维码模式）")
        
 // 1. 创建 NWConnection（QUIC over UDP for P2P）
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])
        
 // 2. ICE 候选协商
        let iceCandidate = try await negotiateICE(
            sessionID: qrData.sessionID,
            remotePublicKey: qrData.publicKey
        )
        
 // 3. 建立连接
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(iceCandidate.host),
            port: NWEndpoint.Port(integerLiteral: iceCandidate.port)
        )
        
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInitiated))
        
 // 4. 等待连接就绪
        try await waitForConnection(connection)
        
        return RemoteConnection(
            id: qrData.sessionID,
            deviceName: qrData.deviceName,
            connection: connection,
            encryptionKey: try Self.deriveSharedSecret(
                localPrivateKey: Curve25519.KeyAgreement.PrivateKey(), // 简化示例，真实实现应与会话密钥匹配
                remotePublicKey: qrData.publicKey
            )
        )
    }
    
    private func establishP2PConnectionWithCode(code: String, deviceInfo: CrossNetworkDeviceInfo) async throws -> RemoteConnection {
        logger.info("建立 P2P 连接（连接码模式）")
        
 // 类似二维码模式，但使用连接码查询的设备信息
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])
        
        let iceCandidate = try await negotiateICEWithCode(
            code: code,
            deviceInfo: deviceInfo
        )
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(iceCandidate.host),
            port: NWEndpoint.Port(integerLiteral: iceCandidate.port)
        )
        
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInitiated))
        
        try await waitForConnection(connection)
        
        return RemoteConnection(
            id: code,
            deviceName: deviceInfo.deviceName,
            connection: connection,
            encryptionKey: try Self.deriveSharedSecret(
                localPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
                remotePublicKey: deviceInfo.publicKey
            )
        )
    }
    
    private func negotiateICE(sessionID: String, remotePublicKey: Data) async throws -> ICECandidate {
 // 1. 首先尝试获取本地地址（用于局域网直连）
        let localAddresses = getLocalIPAddresses()
        
 // 2. 尝试使用 STUN 获取公网地址
        if let stunResult = await STUNService.shared.getPublicAddress() {
            logger.info("🌐 STUN 返回公网地址: \(stunResult.address):\(stunResult.port)")
            return ICECandidate(
                host: stunResult.address,
                port: stunResult.port,
                type: .srflx // Server Reflexive (STUN 反射地址)
            )
        }
        
 // 3. 回退到本地地址
        if let firstLocal = localAddresses.first {
            logger.info("📍 使用本地地址: \(firstLocal)")
            return ICECandidate(
                host: firstLocal,
                port: 5000,
                type: .host
            )
        }
        
        throw CrossNetworkConnectionError.networkError
    }
    
    private func negotiateICEWithCode(code: String, deviceInfo: CrossNetworkDeviceInfo) async throws -> ICECandidate {
 // 与 negotiateICE 相同的逻辑
        return try await negotiateICE(sessionID: code, remotePublicKey: deviceInfo.publicKey)
    }
    
 /// 获取本地 IP 地址列表
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let address = String(decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !address.isEmpty && !address.hasPrefix("127.") {
                        addresses.append(address)
                    }
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return addresses
    }
    
    private func waitForConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }
    
 // MARK: - 监听逻辑
    
    private func startListeningForConnection(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        logger.info("开始监听连接请求：\(sessionID)")
        
        let listener = ConnectionListener(sessionID: sessionID, privateKey: privateKey)
        activeListeners.append(listener)
        
        Task {
            await listener.start { [weak self] connection in
                guard let self = self else { return }
                await MainActor.run {
                    self.currentConnection = connection
                    self.connectionStatus = .connected
                }
            }
        }
    }
    
    private func startListeningForCodeConnection(code: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        logger.info("开始监听连接码请求：\(code)")
        
        let listener = ConnectionListener(sessionID: code, privateKey: privateKey)
        activeListeners.append(listener)
        
        Task {
            await listener.start { [weak self] connection in
                guard let self = self else { return }
                await MainActor.run {
                    self.currentConnection = connection
                    self.connectionStatus = .connected
                }
            }
        }
    }
    
 // MARK: - iCloud 连接辅助
    
    private func createConnectionOffer(sessionID: String) async throws -> ConnectionOffer {
        return ConnectionOffer(
            sessionID: sessionID,
            fromDevice: deviceFingerprint,
            iceCandidates: [],
            timestamp: Date()
        )
    }
    
    private func waitForAnswer(deviceID: String, timeout: TimeInterval) async throws -> ConnectionAnswer {
 // 轮询 iCloud KV Store
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let kvStore = NSUbiquitousKeyValueStore.default
            kvStore.synchronize()
            
            if let answerData = kvStore.data(forKey: "skybridge.answer.\(deviceFingerprint)"),
               let answer = try? JSONDecoder().decode(ConnectionAnswer.self, from: answerData) {
                return answer
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        }
        
        throw CrossNetworkConnectionError.timeout
    }
    
    private func finalizeConnection(offer: ConnectionOffer, answer: ConnectionAnswer) async throws -> RemoteConnection {
 // 使用 offer/answer 建立最终连接
        let parameters = NWParameters.quic(alpn: ["skybridge-p2p"])
        
 // 简化实现
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: 5000
        )
        
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInitiated))
        
        try await waitForConnection(connection)
        
        return RemoteConnection(
            id: offer.sessionID,
            deviceName: "Remote Device",
            connection: connection,
            encryptionKey: SymmetricKey(size: .bits256)
        )
    }
    
 // MARK: - 工具方法
    
    private static func generateDeviceFingerprint() -> String {
 // 生成唯一设备指纹（基于硬件信息）
        let deviceInfo = "\(Host.current().localizedName ?? "")\(ProcessInfo.processInfo.hostName)"
        let hash = SHA256.hash(data: deviceInfo.utf8Data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).uppercased()
    }
    
    private static func generateShortCode() -> String {
 // 生成 6 位字母数字码（排除易混淆字符：0/O, 1/I/l）
        let charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).compactMap { _ in charset.randomElement() })
    }
    
    private static func buildCanonicalSignaturePayload(
        id: String,
        name: String,
        type: P2PDeviceType,
        address: String,
        port: UInt16,
        osVersion: String,
        capabilities: [String],
        timestamp: Double,
        fingerprintHex: String
    ) -> Data {
 // 规范化负载构造，确保签名与验签一致
        let capsJoined = capabilities.joined(separator: ",")
        let canonical = "id=\(id)|name=\(name)|type=\(type.rawValue)|address=\(address)|port=\(port)|os=\(osVersion)|cap=\(capsJoined)|ts=\(timestamp)|fp=\(fingerprintHex)"
        return canonical.data(using: .utf8) ?? Data()
    }
    
    private static func isValidDeviceFingerprint(_ fingerprint: String) -> Bool {
 // 验证设备指纹格式
        return fingerprint.count == 16 && fingerprint.allSatisfy { $0.isHexDigit }
    }
    
    private static func deriveSharedSecret(localPrivateKey: Curve25519.KeyAgreement.PrivateKey, remotePublicKey: Data) throws -> SymmetricKey {
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }
}

// MARK: - 数据结构

/// 动态二维码数据结构
struct DynamicQRCodeData: Codable {
 // 数据结构版本，用于兼容升级
    let version: Int
 // 会话标识
    let sessionID: String
 // 设备名称
    let deviceName: String
 // 设备指纹（稳定ID）
    let deviceFingerprint: String
 // 密钥协商公钥（Curve25519）
    let publicKey: Data
 // 签名公钥（P256.Signing）
    let signingPublicKey: Data?
 // P256 ECDSA 原始签名
    let signature: Data?
 // 签名时间戳（秒）
    let signatureTimestamp: Double?
 // ICE服务器列表
    let iceServers: [String]
 // 二维码过期时间
    let expiresAt: Date
}


/// 设备信息（连接码查询结果）- 重命名以避免与FileTransfer中的DeviceInfo冲突
/// 符合Swift 6.2.1的Sendable要求
struct CrossNetworkDeviceInfo: Sendable {
    let deviceFingerprint: String
    let deviceName: String
    let publicKey: Data
}

/// ICE 候选
struct ICECandidate {
    let host: String
    let port: UInt16
    let type: CandidateType
    
    enum CandidateType {
        case host, srflx, relay
    }
}

/// 连接 Offer
struct ConnectionOffer: Codable {
    let sessionID: String
    let fromDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

/// 连接 Answer
struct ConnectionAnswer: Codable {
    let sessionID: String
    let toDevice: String
    let iceCandidates: [String]
    let timestamp: Date
}

/// 远程连接对象
public struct RemoteConnection: Sendable {
    public let id: String
    public let deviceName: String
    public let connection: NWConnection
    public let encryptionKey: SymmetricKey
}

/// 连接监听器
actor ConnectionListener {
    let sessionID: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    
    init(sessionID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.sessionID = sessionID
        self.privateKey = privateKey
    }
    
    func start(onConnection: @escaping @Sendable (RemoteConnection) async -> Void) async {
 // 监听逻辑（简化）
    }
}

/// 信号服务器客户端
actor SignalServerClient {
    func registerSession(sessionID: String, deviceFingerprint: String, publicKey: Data, validDuration: TimeInterval) async throws -> String {
 // 注册会话到信号服务器
        return sessionID
    }
    
    func registerConnectionCode(code: String, deviceFingerprint: String, deviceName: String, publicKey: Data, validDuration: TimeInterval) async throws -> String {
 // 注册连接码
        return code
    }
    
    func queryConnectionCode(code: String) async throws -> CrossNetworkDeviceInfo {
 // 查询连接码对应的设备信息
        return CrossNetworkDeviceInfo(
            deviceFingerprint: "1234567890ABCDEF",
            deviceName: "Remote Mac",
            publicKey: Data()
        )
    }
}

/// 跨网络连接错误
public enum CrossNetworkConnectionError: Error {
    case invalidQRCode
    case qrCodeExpired
    case invalidSignature
    case invalidDevice
    case timeout
    case networkError
}

