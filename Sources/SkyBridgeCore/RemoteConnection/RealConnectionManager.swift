//
// RealConnectionManager.swift
// SkyBridgeCore
//
// 真正可用的跨网络连接管理器
// 实现动态二维码和智能连接码的完整功能
//
// Swift 6.2.1 最佳实践
//

import Foundation
import Network
import CryptoKit
import Combine
import OSLog
import CoreImage

/// 真正可用的跨网络连接管理器
/// 实现宣传的"动态加密二维码"和"智能连接码"功能
@MainActor
public final class RealConnectionManager: ObservableObject {
    
 // MARK: - 单例
    
    public static let shared = RealConnectionManager()
    
 // MARK: - 发布属性
    
    @Published public var connectionCode: String?
    @Published public var connectionCodeExpiry: Date?
    @Published public var qrCodeImage: CGImage?
    @Published public var qrCodeExpiry: Date?
    @Published public var connectionStatus: ConnectionState = .idle
    @Published public var connectedDevice: ConnectedDeviceInfo?
    @Published public var errorMessage: String?
    
 /// 连接状态
    public enum ConnectionState: Sendable {
        case idle
        case generatingCode
        case waitingForConnection(code: String, expiresIn: TimeInterval)
        case connecting
        case connected(deviceName: String)
        case failed(reason: String)
    }
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.connection", category: "RealConnection")
    private let signalService: LocalSignalService
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var sessionPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var cancellables = Set<AnyCancellable>()
    
 // 设备信息
    private lazy var deviceFingerprint: String = {
        generateDeviceFingerprint()
    }()
    
    private lazy var deviceName: String = {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }()
    
 // MARK: - 初始化
    
    private init() {
        self.signalService = LocalSignalService.shared
        
        Task {
            try? await signalService.start()
        }
    }
    
 // MARK: - 1️⃣ 智能连接码功能
    
 /// 生成 6 位智能连接码
 /// - Parameter validDuration: 有效期（默认 10 分钟）
 /// - Returns: 生成的连接码
    public func generateConnectionCode(validDuration: TimeInterval = 600) async throws -> String {
        logger.info("🔢 生成智能连接码，有效期: \(validDuration)秒")
        connectionStatus = .generatingCode
        
 // 1. 生成 6 位码
        let code = ConnectionCodeGenerator.generate()
        
 // 2. 生成密钥对
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        sessionPrivateKey = privateKey
        
 // 3. 获取本地地址
        let localAddresses = getLocalIPAddresses()
        
 // 4. 启动监听器
        let port = try await startConnectionListener()
        
 // 5. 注册到信号服务
        let registration = ConnectionCodeRegistration(
            code: code,
            deviceFingerprint: deviceFingerprint,
            deviceName: deviceName,
            publicKey: publicKey.rawRepresentation,
            expiresAt: Date().addingTimeInterval(validDuration),
            localAddresses: localAddresses,
            localPort: port
        )
        
        try await signalService.registerConnectionCode(registration)
        
 // 6. 更新状态
        self.connectionCode = code
        self.connectionCodeExpiry = Date().addingTimeInterval(validDuration)
        self.connectionStatus = .waitingForConnection(code: code, expiresIn: validDuration)
        
        logger.info("✅ 连接码生成成功: \(code)，端口: \(port)")
        
 // 7. 设置过期定时器
        Task {
            try? await Task.sleep(nanoseconds: UInt64(validDuration * 1_000_000_000))
            await MainActor.run {
                if self.connectionCode == code {
                    self.connectionCode = nil
                    self.connectionCodeExpiry = nil
                    self.connectionStatus = .idle
                    self.stopListener()
                    self.logger.info("⏰ 连接码已过期: \(code)")
                }
            }
        }
        
        return code
    }
    
 /// 使用连接码连接到远程设备
 /// - Parameter code: 6 位连接码
    public func connectWithCode(_ code: String) async throws {
        let normalizedCode = ConnectionCodeGenerator.normalize(code)
        
        guard ConnectionCodeGenerator.isValid(normalizedCode) else {
            throw CrossNetworkError.invalidCode
        }
        
        logger.info("🔗 使用连接码连接: \(normalizedCode)")
        connectionStatus = .connecting
        
 // 1. 查询连接码信息
        guard let info = try await signalService.queryConnectionCode(normalizedCode) else {
            connectionStatus = .failed(reason: "连接码不存在或已过期")
            throw CrossNetworkError.codeNotFound
        }
        
 // 检查过期
        guard !info.isExpired else {
            connectionStatus = .failed(reason: "连接码已过期")
            throw CrossNetworkError.codeExpired
        }
        
 // 2. 尝试连接
        try await connectToDevice(info: info)
    }
    
 // MARK: - 2️⃣ 动态二维码功能
    
 /// 生成动态加密二维码
 /// - Parameter validDuration: 有效期（默认 5 分钟）
 /// - Returns: 二维码图像
    public func generateDynamicQRCode(validDuration: TimeInterval = 300) async throws -> CGImage {
        logger.info("📱 生成动态二维码，有效期: \(validDuration)秒")
        connectionStatus = .generatingCode
        
 // 1. 生成会话密钥
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        sessionPrivateKey = privateKey
        
 // 2. 生成签名密钥
        let signingKey = P256.Signing.PrivateKey()
        let signingPublicKey = signingKey.publicKey
        
 // 3. 获取本地地址
        let localAddresses = getLocalIPAddresses()
        
 // 4. 启动监听器
        let port = try await startConnectionListener()
        
 // 5. 构建二维码数据
        let sessionID = UUID().uuidString
        let expiresAt = Date().addingTimeInterval(validDuration)
        
        let qrPayload = QRCodePayload(
            version: 2,
            sessionID: sessionID,
            deviceFingerprint: deviceFingerprint,
            deviceName: deviceName,
            publicKey: publicKey.rawRepresentation.base64EncodedString(),
            signingPublicKey: signingPublicKey.rawRepresentation.base64EncodedString(),
            localAddresses: localAddresses,
            port: port,
            expiresAt: expiresAt.timeIntervalSince1970
        )
        
 // 6. 签名
        let payloadData = try JSONEncoder().encode(qrPayload)
        let signature = try signingKey.signature(for: payloadData)
        
        let signedPayload = SignedQRPayload(
            payload: qrPayload,
            signature: signature.rawRepresentation.base64EncodedString()
        )
        
 // 7. 生成二维码
        let jsonData = try JSONEncoder().encode(signedPayload)
        let base64 = jsonData.base64EncodedString()
        let qrContent = "skybridge://connect/\(base64)"
        
        guard let qrImage = generateQRCodeImage(from: qrContent) else {
            throw CrossNetworkError.qrGenerationFailed
        }
        
 // 8. 注册会话
        let registration = QRSessionRegistration(
            sessionID: sessionID,
            deviceFingerprint: deviceFingerprint,
            deviceName: deviceName,
            publicKey: publicKey.rawRepresentation,
            signingPublicKey: signingPublicKey.rawRepresentation,
            signature: signature.rawRepresentation,
            expiresAt: expiresAt,
            localAddresses: localAddresses,
            localPort: port
        )
        
        try await signalService.registerQRSession(registration)
        
 // 9. 更新状态
        self.qrCodeImage = qrImage
        self.qrCodeExpiry = expiresAt
        self.connectionStatus = .waitingForConnection(code: sessionID, expiresIn: validDuration)
        
        logger.info("✅ 动态二维码生成成功，会话: \(sessionID)")
        
 // 10. 设置过期定时器
        Task {
            try? await Task.sleep(nanoseconds: UInt64(validDuration * 1_000_000_000))
            await MainActor.run {
                if self.qrCodeExpiry == expiresAt {
                    self.qrCodeImage = nil
                    self.qrCodeExpiry = nil
                    self.connectionStatus = .idle
                    self.stopListener()
                    self.logger.info("⏰ 二维码已过期")
                }
            }
        }
        
        return qrImage
    }
    
 /// 扫描并连接二维码
 /// - Parameter qrContent: 二维码内容
    public func connectWithQRCode(_ qrContent: String) async throws {
        logger.info("📷 扫描二维码连接")
        connectionStatus = .connecting
        
 // 1. 解析二维码
        guard qrContent.hasPrefix("skybridge://connect/"),
              let base64 = qrContent.components(separatedBy: "skybridge://connect/").last,
              let jsonData = Data(base64Encoded: base64) else {
            throw CrossNetworkError.invalidQRCode
        }
        
        let signedPayload = try JSONDecoder().decode(SignedQRPayload.self, from: jsonData)
        let payload = signedPayload.payload
        
 // 2. 验证过期
        guard Date().timeIntervalSince1970 < payload.expiresAt else {
            connectionStatus = .failed(reason: "二维码已过期")
            throw CrossNetworkError.qrExpired
        }
        
 // 3. 验证签名
        guard let signingKeyData = Data(base64Encoded: payload.signingPublicKey),
              let signatureData = Data(base64Encoded: signedPayload.signature) else {
            throw CrossNetworkError.invalidSignature
        }
        
        let signingKey = try P256.Signing.PublicKey(rawRepresentation: signingKeyData)
        let payloadData = try JSONEncoder().encode(payload)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        
        guard signingKey.isValidSignature(signature, for: payloadData) else {
            connectionStatus = .failed(reason: "签名验证失败")
            throw CrossNetworkError.invalidSignature
        }
        
 // 4. 尝试连接
        try await connectToQRDevice(payload: payload)
    }
    
 // MARK: - 连接建立
    
    private func connectToDevice(info: ConnectionCodeInfo) async throws {
 // 尝试连接顺序：本地地址 -> 公网地址
        var lastError: Error?
        
 // 1. 尝试本地地址
        for address in info.localAddresses {
            do {
                try await establishConnection(host: address, port: info.localPort, publicKey: info.publicKey, deviceName: info.deviceName)
                return
            } catch {
                lastError = error
                logger.debug("本地连接失败 \(address): \(error.localizedDescription)")
            }
        }
        
 // 2. 尝试公网地址
        if let publicAddress = info.publicAddress, let publicPort = info.publicPort {
            do {
                try await establishConnection(host: publicAddress, port: publicPort, publicKey: info.publicKey, deviceName: info.deviceName)
                return
            } catch {
                lastError = error
                logger.debug("公网连接失败: \(error.localizedDescription)")
            }
        }
        
        connectionStatus = .failed(reason: "无法连接到设备")
        throw lastError ?? CrossNetworkError.connectionFailed
    }
    
    private func connectToQRDevice(payload: QRCodePayload) async throws {
        guard let publicKeyData = Data(base64Encoded: payload.publicKey) else {
            throw CrossNetworkError.invalidQRCode
        }
        
 // 尝试连接
        var lastError: Error?
        
        for address in payload.localAddresses {
            do {
                try await establishConnection(host: address, port: payload.port, publicKey: publicKeyData, deviceName: payload.deviceName)
                return
            } catch {
                lastError = error
            }
        }
        
        connectionStatus = .failed(reason: "无法连接到设备")
        throw lastError ?? CrossNetworkError.connectionFailed
    }
    
    private func establishConnection(host: String, port: UInt16, publicKey: Data, deviceName: String) async throws {
        logger.info("🔗 建立连接到 \(host):\(port)")
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        
 // 使用 TLS 加密
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        
        let connection = NWConnection(to: endpoint, using: parameters)
        
 // 使用 actor 隔离安全的方式处理连接状态
        let connectionActor = ConnectionStateActor()
        
        connection.stateUpdateHandler = { state in
            Task {
                await connectionActor.handleState(state)
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
        
 // 超时
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10秒
            if connection.state != .ready {
                connection.cancel()
                await connectionActor.handleState(.cancelled)
            }
        }
        
 // 等待连接结果
        let result = await connectionActor.waitForResult()
        
        switch result {
        case .success:
            self.activeConnection = connection
            self.connectionStatus = .connected(deviceName: deviceName)
            self.connectedDevice = ConnectedDeviceInfo(
                name: deviceName,
                address: host,
                port: port,
                publicKey: publicKey,
                connectedAt: Date()
            )
            self.logger.info("✅ 连接成功: \(deviceName)")
            
        case .failed(let error):
            throw error
            
        case .cancelled:
            throw CrossNetworkError.connectionCancelled
            
        case .pending:
            throw CrossNetworkError.connectionFailed
        }
    }
    
 // MARK: - 监听器
    
    private func startConnectionListener() async throws -> UInt16 {
        stopListener()
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        let listener = try NWListener(using: parameters)
        
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                await self?.handleIncomingConnection(connection)
            }
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: CrossNetworkError.listenerFailed)
                    }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        }
    }
    
    private func stopListener() {
        listener?.cancel()
        listener = nil
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) async {
        logger.info("📥 收到连接请求")
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.activeConnection = connection
                    self?.connectionStatus = .connected(deviceName: "远程设备")
                    self?.connectedDevice = ConnectedDeviceInfo(
                        name: "远程设备",
                        address: connection.endpoint.debugDescription,
                        port: 0,
                        publicKey: Data(),
                        connectedAt: Date()
                    )
                    self?.logger.info("✅ 接受连接成功")
                    
                case .failed(let error):
                    self?.logger.error("连接失败: \(error.localizedDescription)")
                    
                default:
                    break
                }
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
    }
    
 // MARK: - 工具方法
    
    private func generateDeviceFingerprint() -> String {
 // 使用硬件 UUID 生成指纹
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }
        
        if let serialNumber = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            let hash = SHA256.hash(data: serialNumber.utf8Data)
            return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        }
        
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).lowercased()
    }
    
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }
        
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ptr = current {
            let interface = ptr.pointee
            current = interface.ifa_next
            guard let addressPtr = interface.ifa_addr,
                  let name = decodeOptionalCString(interface.ifa_name) else { continue }
            let addrFamily = addressPtr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) { // IPv4
                if name.hasPrefix("en") || name.hasPrefix("bridge") { // 以太网或桥接
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        addressPtr,
                        socklen_t(addressPtr.pointee.sa_len),
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
        }
        
        return addresses
    }
    
    private func generateQRCodeImage(from content: String) -> CGImage? {
        guard let data = content.data(using: .utf8) else { return nil }
        
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel") // 高容错
        
        guard let ciImage = filter?.outputImage else { return nil }
        
 // 放大
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: scale)
        
        let context = CIContext()
        return context.createCGImage(scaledImage, from: scaledImage.extent)
    }
    
 // MARK: - 断开连接
    
    public func disconnect() {
        activeConnection?.cancel()
        activeConnection = nil
        stopListener()
        connectionStatus = .idle
        connectedDevice = nil
        connectionCode = nil
        qrCodeImage = nil
        logger.info("🔌 已断开连接")
    }
}

// MARK: - 数据模型

/// 二维码负载
struct QRCodePayload: Codable {
    let version: Int
    let sessionID: String
    let deviceFingerprint: String
    let deviceName: String
    let publicKey: String
    let signingPublicKey: String
    let localAddresses: [String]
    let port: UInt16
    let expiresAt: TimeInterval
}

/// 签名的二维码负载
struct SignedQRPayload: Codable {
    let payload: QRCodePayload
    let signature: String
}

/// 已连接设备信息
public struct ConnectedDeviceInfo: Sendable {
    public let name: String
    public let address: String
    public let port: UInt16
    public let publicKey: Data
    public let connectedAt: Date
}

/// 连接状态 Actor - 用于线程安全地处理连接状态
private actor ConnectionStateActor {
    enum Result {
        case pending
        case success
        case failed(Error)
        case cancelled
    }
    
    private var result: Result = .pending
    private var continuation: CheckedContinuation<Result, Never>?
    
    func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            result = .success
            continuation?.resume(returning: .success)
            continuation = nil
            
        case .failed(let error):
            result = .failed(error)
            continuation?.resume(returning: .failed(error))
            continuation = nil
            
        case .cancelled:
            result = .cancelled
            continuation?.resume(returning: .cancelled)
            continuation = nil
            
        default:
            break
        }
    }
    
    func waitForResult() async -> Result {
        if case .pending = result {
            return await withCheckedContinuation { cont in
                self.continuation = cont
            }
        }
        return result
    }
}

/// 跨网络连接错误
public enum CrossNetworkError: LocalizedError {
    case invalidCode
    case codeNotFound
    case codeExpired
    case invalidQRCode
    case qrExpired
    case invalidSignature
    case qrGenerationFailed
    case connectionFailed
    case connectionCancelled
    case listenerFailed
    
    public var errorDescription: String? {
        switch self {
        case .invalidCode: return "无效的连接码格式"
        case .codeNotFound: return "连接码不存在或已过期"
        case .codeExpired: return "连接码已过期"
        case .invalidQRCode: return "无效的二维码"
        case .qrExpired: return "二维码已过期"
        case .invalidSignature: return "签名验证失败"
        case .qrGenerationFailed: return "二维码生成失败"
        case .connectionFailed: return "连接失败"
        case .connectionCancelled: return "连接已取消"
        case .listenerFailed: return "监听器启动失败"
        }
    }
}
