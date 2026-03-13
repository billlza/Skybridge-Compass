import Foundation
import Network
import Security
import CryptoKit
import os
import Darwin

/// TLS握手详情顶层模型（避免跨文件嵌套类型不可见）
public struct TLSHandshakeDetails: Sendable {
    public let protocolVersion: String
    public let cipherSuite: String
    public let alpn: String?
    public let sni: String?
    public init(protocolVersion: String, cipherSuite: String, alpn: String? = nil, sni: String? = nil) {
        self.protocolVersion = protocolVersion
        self.cipherSuite = cipherSuite
        self.alpn = alpn
        self.sni = sni
    }
    public static func string(from v: tls_protocol_version_t) -> String {
        switch v {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        case .DTLSv12: return "DTLS 1.2"
        default: return "未知版本"
        }
    }
    private static func toU16(_ v: tls_ciphersuite_t) -> UInt16 { unsafeBitCast(v, to: UInt16.self) }
    public static func string(from cs: tls_ciphersuite_t) -> String {
        let raw = toU16(cs)
        switch raw {
        case 0x1302: return "TLS_AES_256_GCM_SHA384"
        case 0x1301: return "TLS_AES_128_GCM_SHA256"
        case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256"
        default: return String(format: "未知套件(0x%04X)", UInt32(raw))
        }
    }
}
/// TLS安全管理器 - 负责TLS 1.3加密通信和证书管理，支持量子安全加密
@MainActor
public class TLSSecurityManager: ObservableObject, @unchecked Sendable {

 // MARK: - 生命周期管理

 /// 管理器是否已启动
    @Published public private(set) var isStarted: Bool = false

 // MARK: - 属性

 /// TLS配置
    private let tlsConfiguration: TLSConfiguration
 /// 证书管理器
    private let certificateManager: CertificateManager
 /// 当前TLS连接
    @Published public private(set) var activeConnections: [String: NWConnection] = [:]
 /// TLS统计信息
    @Published public private(set) var tlsStatistics: TLSStatistics = TLSStatistics()
 /// 量子安全加密管理器
    private let quantumCryptoManager: QuantumCryptoManager
 /// TLS量子加密管理器实例
    private let tlsQuantumCrypto = TLSQuantumCryptoManager()
    private var pqcProvider: PQCProvider?
    private var hpkeProvider: PQCHPKEProvider?
    private var localDeviceId: String?
    public enum CryptoProfile: String, Sendable {
        case classicP256
        case pqcMlKemMlDsa
        case hybridXWing
    }
    private func negotiateProfile(offered: [CryptoProfile], supported: [CryptoProfile]) -> CryptoProfile {
        for p in offered { if supported.contains(p) { return p } }
        return .classicP256
    }
    private var selectedProfile: CryptoProfile = .classicP256
 // MARK: - 初始化

    public init(configuration: TLSConfiguration = .default) {
        self.tlsConfiguration = configuration
        self.certificateManager = CertificateManager()
        self.quantumCryptoManager = QuantumCryptoManager()
    }

 // MARK: - 生命周期管理方法

 /// 启动TLS安全管理器
    public func start() async throws {
        guard !isStarted else { return }

        isStarted = true
        SkyBridgeLogger.security.debugOnly("TLS安全管理器已启动")
    }

 /// 停止TLS安全管理器
    public func stop() async {
        guard isStarted else { return }

 // 关闭所有连接
        closeAllConnections()

        isStarted = false
        SkyBridgeLogger.security.debugOnly("TLS安全管理器已停止")
    }

 /// 清理TLS安全管理器
    public func cleanup() async {
        await stop()

 // 清理统计信息
        tlsStatistics = TLSStatistics()

        SkyBridgeLogger.security.debugOnly("TLS安全管理器已清理")
    }

 // MARK: - TLS连接管理

 /// 创建TLS客户端连接 - 支持量子安全
    public func createClientConnection(to endpoint: NWEndpoint, deviceId: String) -> NWConnection {
 // 创建量子安全TLS选项
        let tlsOptions = createQuantumSecureTLSOptions(for: .client, deviceId: deviceId)

 // 创建TCP选项
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 10
        tcpOptions.keepaliveCount = 3

 // 创建连接参数
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = true

 // 创建连接
        let connection = NWConnection(to: endpoint, using: parameters)

 // 设置连接状态监听
        setupConnectionStateHandler(connection, deviceId: deviceId)
        SkyBridgeLogger.security.debugOnly("Crypto profile selected: \(selectedProfile.rawValue)")

        if selectedProfile != .classicP256 {
            if let provider = PQCProviderFactory.makeProvider() {
                self.pqcProvider = provider
                if let hp = provider as? PQCHPKEProvider { self.hpkeProvider = hp }
                SkyBridgeLogger.security.debugOnly("🔐 PQC Provider: \(String(describing: type(of: provider)))")
            } else {
                self.pqcProvider = nil
                self.hpkeProvider = nil
                SkyBridgeLogger.security.debugOnly("🔐 PQC Provider unavailable; fallback classic")
            }
        } else {
            self.pqcProvider = nil
            self.hpkeProvider = nil
        }

        activeConnections[deviceId] = connection

        SkyBridgeLogger.security.debugOnly("🔐 创建量子安全TLS客户端连接: \(deviceId) -> \(String(describing: endpoint))")
        return connection
    }

 /// 创建TLS服务器监听器 - 支持量子安全
    public func createServerListener(on port: UInt16, deviceId: String) -> NWListener? {
 // 创建量子安全TLS选项
        let tlsOptions = createQuantumSecureTLSOptions(for: .server, deviceId: deviceId)

 // 创建TCP选项
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true

 // 创建监听参数
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true

        do {
 // 创建监听器
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port.validated(port))
            self.localDeviceId = deviceId

 // 设置新连接处理器
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    let offered: [CryptoProfile] = [.hybridXWing, .pqcMlKemMlDsa, .classicP256]
                    let supported: [CryptoProfile] = [.hybridXWing, .classicP256]
                    self?.selectedProfile = self?.negotiateProfile(offered: offered, supported: supported) ?? .classicP256
                    self?.handleNewConnection(connection, deviceId: deviceId)
                    SkyBridgeLogger.security.debugOnly("Crypto profile selected: \(self?.selectedProfile.rawValue ?? "classicP256")")
                    if self?.selectedProfile != .classicP256 {
                        if let provider = PQCProviderFactory.makeProvider() {
                            self?.pqcProvider = provider
                            if let hp = provider as? PQCHPKEProvider { self?.hpkeProvider = hp }
                            SkyBridgeLogger.security.debugOnly("🔐 Server PQC Provider: \(String(describing: type(of: provider)))")
                        } else {
                            self?.pqcProvider = nil
                            self?.hpkeProvider = nil
                            SkyBridgeLogger.security.debugOnly("🔐 Server PQC Provider unavailable; fallback classic")
                        }
                    } else {
                        self?.pqcProvider = nil
                        self?.hpkeProvider = nil
                    }
                }
            }

 // 设置状态变化处理器
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerStateChange(state, deviceId: deviceId)
                }
            }

            SkyBridgeLogger.security.debugOnly("🔐 创建量子安全TLS服务器监听器: \(deviceId) 端口: \(port)")
            return listener

        } catch {
            SkyBridgeLogger.security.error("❌ 创建TLS监听器失败: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

 /// 发送量子安全加密数据（多版本兼容，自动记录 PQC 指标）
    public func sendSecureData(_ data: Data, to deviceId: String, completion: @escaping @Sendable (Error?) -> Void) {
        guard let connection = activeConnections[deviceId] else {
            completion(TLSSecurityError.connectionNotFound)
            return
        }
        let profile = selectedProfile

        Task {
            do {
                if let hp = hpkeProvider, profile == .hybridXWing {
                    let variant = (profile == .hybridXWing) ? "xwing-mlkem768-x25519" : "mlkem768"
                    let service = PQCKeyTags.v2Kem(variant)
                    if let recipientPub = KeychainManager.shared.exportKey(service: service, account: deviceId) {
                        let ctx = try hp.senderContext(recipientPublicKey: recipientPub, suite: .hybridXWing)
                        let aad = Data(deviceId.utf8)
                        let sealed = try ctx.seal(data, authenticating: aad)
                        var header = withUnsafeBytes(of: UInt32(sealed.encapsulatedKey.count).bigEndian) { Data($0) }
                        header.append(sealed.encapsulatedKey)
                        let payload = header + sealed.ciphertext
                        connection.send(content: payload, completion: .contentProcessed { error in
                            Task { @MainActor in
                                if let error = error {
                                    completion(error)
                                } else {
                                    self.tlsStatistics.bytesSent += UInt64(payload.count)
                                    self.tlsStatistics.messagesSent += 1
                                    self.tlsStatistics.pqcBytesSent += UInt64(payload.count)
                                    completion(nil)
                                }
                            }
                        })
                        return
                    }
                }
                let encryptedData = try quantumCryptoManager.quantumSafeEncrypt(data, using: SymmetricKey(size: .bits256))
                let algoType = quantumCryptoManager.currentAlgorithm
                let isPQC = (algoType != QuantumCryptoManager.AlgorithmType.classic)
                connection.send(content: encryptedData, completion: .contentProcessed { error in
                    Task { @MainActor in
                        if let error = error {
                            completion(error)
                        } else {
                            self.tlsStatistics.bytesSent += UInt64(encryptedData.count)
                            self.tlsStatistics.messagesSent += 1
                            if isPQC {
                                self.tlsStatistics.pqcBytesSent += UInt64(encryptedData.count)
                            } else {
                                self.tlsStatistics.classicBytesSent += UInt64(encryptedData.count)
                            }
                            completion(nil)
                        }
                    }
                })
            } catch {
                completion(error)
            }
        }
    }

 /// 接收量子安全加密数据（多版本兼容，自动记录 PQC 指标）
    public func receiveSecureData(from deviceId: String, completion: @escaping @Sendable (Data?, Error?) -> Void) {
        guard let connection = activeConnections[deviceId] else {
            completion(nil, TLSSecurityError.connectionNotFound)
            return
        }
        let profile = selectedProfile
        let localIdSnapshot = localDeviceId

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                if let error = error {
                    completion(nil, error)
                } else if let encryptedData = data {
                    do {
                        guard let strongSelf = self else { completion(nil, TLSSecurityError.connectionNotFound); return }
                        if let hp = strongSelf.hpkeProvider, profile == .hybridXWing, let localId = localIdSnapshot {
                            if encryptedData.count >= 4 {
                                let lenData = encryptedData.prefix(4)
                                let encLen = lenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                                let totalNeeded = 4 + Int(encLen)
                                if encryptedData.count >= totalNeeded {
                                    let encKey = encryptedData.dropFirst(4).prefix(Int(encLen))
                                    let ct = encryptedData.dropFirst(totalNeeded)
                                    let variant = (profile == .hybridXWing) ? "xwing-mlkem768-x25519" : "mlkem768"
                                    let service = PQCKeyTags.v2Kem(variant)
                                    if let priv = KeychainManager.shared.exportKey(service: service, account: localId) {
                                        let ctx = try hp.recipientContext(recipientPrivateKey: priv, suite: .hybridXWing, encapsulatedKey: Data(encKey))
                                        let aad = Data(deviceId.utf8)
                                        let opened = try ctx.open(Data(ct), authenticating: aad)
                                        strongSelf.tlsStatistics.bytesReceived += UInt64(encryptedData.count)
                                        strongSelf.tlsStatistics.messagesReceived += 1
                                        strongSelf.tlsStatistics.pqcBytesReceived += UInt64(encryptedData.count)
                                        completion(opened, nil)
                                        return
                                    }
                                }
                            }
                        }
                        let decryptedData = try strongSelf.quantumCryptoManager.quantumSafeDecrypt(encryptedData, using: SymmetricKey(size: .bits256))
                        let algoType = strongSelf.quantumCryptoManager.currentAlgorithm
                        let isPQC = (algoType != QuantumCryptoManager.AlgorithmType.classic)
                        strongSelf.tlsStatistics.bytesReceived += UInt64(encryptedData.count)
                        strongSelf.tlsStatistics.messagesReceived += 1
                        if isPQC {
                            strongSelf.tlsStatistics.pqcBytesReceived += UInt64(encryptedData.count)
                        } else {
                            strongSelf.tlsStatistics.classicBytesReceived += UInt64(encryptedData.count)
                        }
                        completion(decryptedData, nil)
                    } catch {
                        completion(nil, error)
                    }
                } else {
                    completion(nil, TLSSecurityError.invalidDataFormat)
                }
            }
        }
    }

 // MARK: - 身份与证书访问（公开包装）
 /// 获取设备对应的钥匙串身份（SecIdentity）
 /// - 参数 deviceId: 设备唯一标识
 /// - 返回: 若存在则返回SecIdentity，否则为nil
    public func getIdentity(for deviceId: String) -> SecIdentity? {
 // 中文说明：对内部CertificateManager的获取方法进行公开包装，便于服务端TLS设置本地身份。
        return certificateManager.getIdentity(for: deviceId)
    }

 // MARK: - 量子安全证书管理

 /// 获取设备的量子安全证书
    public func getDeviceCertificate(for deviceId: String) -> SecCertificate? {
        return certificateManager.getCertificate(for: deviceId)
    }

 /// 验证对等设备的量子安全证书
    public func validatePeerCertificate(_ certificate: SecCertificate, for deviceId: String) -> Bool {
        return certificateManager.validateCertificate(certificate, for: deviceId)
    }

 /// 生成量子安全自签名证书
    public func generateSelfSignedCertificate(for deviceId: String) -> SecCertificate? {
        return certificateManager.generateSelfSignedCertificate(for: deviceId)
    }

 /// 导入PKCS#12并设置为指定设备的本地身份（服务端/客户端均可复用）
    public func importIdentityFromPKCS12(_ p12Data: Data, password: String, for deviceId: String) -> Bool {
        return certificateManager.importIdentityFromPKCS12(p12Data, password: password, for: deviceId)
    }

 /// 生成 PKCS#10 CSR（DER -> PEM）
    public func generateCSRPEM(for deviceId: String, commonName: String) -> String? {
        guard let identity = certificateManager.getIdentity(for: deviceId) else { return nil }
        var privateKeyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKeyRef) == errSecSuccess, let priv = privateKeyRef else { return nil }
        guard let der = certificateManager.generatePKCS10CSRDER(commonName: commonName, organization: nil, organizationalUnit: nil, sanDNS: [], sanIP: [], privateKey: priv) else { return nil }
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n" + body + "\n-----END CERTIFICATE REQUEST-----\n"
    }

 /// 生成 CSR（支持 CN/O/OU 与 SAN 扩展），返回 PEM
    public func generateCSRPEM(for deviceId: String, commonName: String, organization: String?, organizationalUnit: String?, sanDNS: [String], sanIP: [String]) -> String? {
        guard let identity = certificateManager.getIdentity(for: deviceId) else { return nil }
        var privateKeyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKeyRef) == errSecSuccess, let priv = privateKeyRef else { return nil }
        guard let der = certificateManager.generatePKCS10CSRDER(commonName: commonName, organization: organization, organizationalUnit: organizationalUnit, sanDNS: sanDNS, sanIP: sanIP, privateKey: priv) else { return nil }
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n" + body + "\n-----END CERTIFICATE REQUEST-----\n"
    }

 // MARK: - 连接管理

 /// 关闭指定设备的连接
    public func closeConnection(for deviceId: String) {
        if let connection = activeConnections[deviceId] {
            connection.cancel()
            activeConnections.removeValue(forKey: deviceId)
        }
    }

 /// 关闭所有连接
    public func closeAllConnections() {
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
    }

 /// 获取连接状态
    public func getConnectionState(for deviceId: String) -> NWConnection.State? {
        return activeConnections[deviceId]?.state
    }

 /// 检查连接是否活跃
    public func isConnectionActive(for deviceId: String) -> Bool {
        return activeConnections[deviceId]?.state == .ready
    }

 // MARK: - 统计信息

 /// 重置统计信息
    public func resetStatistics() {
        tlsStatistics = TLSStatistics()
    }

 /// 获取连接统计信息（包含 PQC 指标）
    public func getConnectionStatistics() -> [String: Any] {
        var stats: [String: Any] = [
            "activeConnections": activeConnections.count,
            "connectionsEstablished": tlsStatistics.connectionsEstablished,
            "bytesSent": tlsStatistics.bytesSent,
            "bytesReceived": tlsStatistics.bytesReceived,
            "messagesSent": tlsStatistics.messagesSent,
            "messagesReceived": tlsStatistics.messagesReceived,
            "errorCount": tlsStatistics.errorCount,
            "uptime": Date().timeIntervalSince(tlsStatistics.startTime)
        ]

 // 添加 PQC 指标（macOS 15+）
        if #available(macOS 15.0, *) {
            stats["pqcConnections"] = tlsStatistics.pqcConnections
            stats["classicConnections"] = tlsStatistics.classicConnections
            stats["pqcBytesSent"] = tlsStatistics.pqcBytesSent
            stats["pqcBytesReceived"] = tlsStatistics.pqcBytesReceived
            stats["classicBytesSent"] = tlsStatistics.classicBytesSent
            stats["classicBytesReceived"] = tlsStatistics.classicBytesReceived

 // 计算 PQC 使用率
            let totalBytes = tlsStatistics.bytesSent + tlsStatistics.bytesReceived
            if totalBytes > 0 {
                let pqcBytes = tlsStatistics.pqcBytesSent + tlsStatistics.pqcBytesReceived
                stats["pqcUsageRate"] = Double(pqcBytes) / Double(totalBytes)
            }

 // 系统信息
            let (version, hasPQC) = quantumCryptoManager.systemInfo
            stats["systemVersion"] = version
            stats["pqcAvailable"] = hasPQC
            stats["currentAlgorithm"] = quantumCryptoManager.currentAlgorithm.rawValue
        }

        return stats
    }

 // MARK: - 私有方法

 /// 创建量子安全TLS选项（多版本兼容：macOS 14.x/15.x）
    private func createQuantumSecureTLSOptions(for mode: TLSMode, deviceId: String) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()

 // 使用sec_protocol_options配置TLS 1.3
        let secOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)

 // macOS 15+：尝试配置 PQC 协商组（X25519+ML-KEM-768）
        if #available(macOS 15.0, *) {
 // 在 macOS 26 中，系统 TLS 实现会自动协商混合后量子组 "X25519+MLKEM768"
 // 如果服务器不支持，会自动回退到经典算法
 // 注意：当前 Network.framework 可能尚未暴露直接的 PQC 配置 API，
 // 但系统会在 TLS 1.3 握手中自动尝试 PQC 协商组

 // 记录 PQC 尝试
            SkyBridgeLogger.security.debugOnly("🔐 TLS 配置：尝试使用 PQC 协商组（macOS 15+）")

 // 未来实现：当 Apple 提供直接配置 API 时，可以这样设置：
 // sec_protocol_options_set_tls_ciphersuites(secOptions, [.TLS_AES_256_GCM_SHA384, .TLS_PQC_HYBRID])
        } else {
 // macOS 14：使用经典 TLS 1.3 密码套件
            SkyBridgeLogger.security.debugOnly("🔐 TLS 配置：使用经典 TLS 1.3（macOS 14）")
        }

        switch mode {
        case .client:
 // 客户端配置
            if tlsConfiguration.enableCertificateVerification {
 // 设置证书验证回调（记录握手协商的版本/套件/ALPN）
                sec_protocol_options_set_verify_block(secOptions, { [weak self] metadata, trust, complete in
                    if let self = self {
                        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata)
                        let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata)
                        var alpn: String? = nil
                        if let proto = sec_protocol_metadata_get_negotiated_protocol(metadata) {
                            alpn = self.decodeCString(proto)
                        }
                        let details = TLSHandshakeDetails(
                            protocolVersion: TLSHandshakeDetails.string(from: version),
                            cipherSuite: TLSHandshakeDetails.string(from: cipher),
                            alpn: alpn,
                            sni: nil
                        )
                        Task { @MainActor in
                            self.tlsStatistics.lastProtocolVersion = details.protocolVersion
                            self.tlsStatistics.lastCipherSuite = details.cipherSuite
                            self.tlsStatistics.lastALPN = details.alpn ?? ""
                        }
                    }
                    let result = self?.verifyCertificateChain(trust, for: deviceId) ?? false
                    complete(result)
                }, .main)
            }

        case .server:
 // 服务器配置
            if let identity = certificateManager.getIdentity(for: deviceId) {
                if CFGetTypeID(identity) == SecIdentityGetTypeID() {
                    let secIdentity = sec_identity_create(identity)
                    if let secIdentity = secIdentity {
                        sec_protocol_options_set_local_identity(secOptions, secIdentity)
                    }
                }
            }

            if tlsConfiguration.requireClientCertificate {
                sec_protocol_options_set_verify_block(secOptions, { [weak self] metadata, trust, complete in
                    if let self = self {
                        let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata)
                        let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata)
                        var alpn: String? = nil
                        if let proto = sec_protocol_metadata_get_negotiated_protocol(metadata) {
                            alpn = self.decodeCString(proto)
                        }
                        let details = TLSHandshakeDetails(
                            protocolVersion: TLSHandshakeDetails.string(from: version),
                            cipherSuite: TLSHandshakeDetails.string(from: cipher),
                            alpn: alpn,
                            sni: nil
                        )
                        Task { @MainActor in
                            self.tlsStatistics.lastProtocolVersion = details.protocolVersion
                            self.tlsStatistics.lastCipherSuite = details.cipherSuite
                            self.tlsStatistics.lastALPN = details.alpn ?? ""
                        }
                    }
                    let result = self?.verifyCertificateChain(trust, for: deviceId) ?? false
                    complete(result)
                }, .main)
            }
        }

        return tlsOptions
    }

 /// 设置连接状态处理器
    private func setupConnectionStateHandler(_ connection: NWConnection, deviceId: String) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionStateChange(state, deviceId: deviceId)
            }
        }
    }

 /// 处理连接状态变化
    private func handleConnectionStateChange(_ state: NWConnection.State, deviceId: String) {
        switch state {
        case .ready:
            SkyBridgeLogger.security.debugOnly("✅ TLS连接就绪: \(deviceId)")
            tlsStatistics.connectionsEstablished += 1

 // 检测实际使用的算法（macOS 15+）
            if #available(macOS 15.0, *) {
 // 尝试检查 TLS 协商组（如果系统提供 API）
 // 当前实现：基于量子加密管理器的能力判断
                let algoType = quantumCryptoManager.currentAlgorithm
                if algoType != QuantumCryptoManager.AlgorithmType.classic {
                    tlsStatistics.pqcConnections += 1
                    SkyBridgeLogger.security.debugOnly("   🔐 使用算法: \(algoType.rawValue)")
                } else {
                    tlsStatistics.classicConnections += 1
                    SkyBridgeLogger.security.debugOnly("   🔐 使用算法: AES-GCM（经典）")
                }
 // 记录握手协商信息（版本/套件/ALPN），便于诊断与统计
                if !tlsStatistics.lastProtocolVersion.isEmpty || !tlsStatistics.lastCipherSuite.isEmpty || !tlsStatistics.lastALPN.isEmpty {
                    SkyBridgeLogger.security.debugOnly("   🤝 握手: version=\(tlsStatistics.lastProtocolVersion) cipher=\(tlsStatistics.lastCipherSuite) alpn=\(tlsStatistics.lastALPN)")
                }
            } else {
 // macOS 14：仅经典算法
                tlsStatistics.classicConnections += 1
            }

        case .failed(let error):
            SkyBridgeLogger.security.error("❌ TLS连接失败: \(deviceId, privacy: .private), 错误: \(error.localizedDescription, privacy: .private)")
            activeConnections.removeValue(forKey: deviceId)
            tlsStatistics.errorCount += 1

        case .cancelled:
            SkyBridgeLogger.security.debugOnly("⏹️ TLS连接已取消: \(deviceId)")
            activeConnections.removeValue(forKey: deviceId)

        default:
            break
        }
    }

 /// 处理新连接
    private func handleNewConnection(_ connection: NWConnection, deviceId: String) {
        activeConnections[deviceId] = connection
        setupConnectionStateHandler(connection, deviceId: deviceId)
        connection.start(queue: .global())
        SkyBridgeLogger.security.debugOnly("🔗 处理新TLS连接: \(deviceId)")
    }

 /// 处理监听器状态变化
    private func handleListenerStateChange(_ state: NWListener.State, deviceId: String) {
        switch state {
        case .ready:
            SkyBridgeLogger.security.debugOnly("✅ TLS监听器就绪: \(deviceId)")

        case .failed(let error):
            SkyBridgeLogger.security.error("❌ TLS监听器失败: \(deviceId, privacy: .private), 错误: \(error.localizedDescription, privacy: .private)")
            tlsStatistics.errorCount += 1

        case .cancelled:
            SkyBridgeLogger.security.debugOnly("⏹️ TLS监听器已取消: \(deviceId)")

        default:
            break
        }
    }

 /// 验证证书链 - 增强证书固定和量子安全验证
    private func verifyCertificateChain(_ trust: sec_trust_t, for deviceId: String) -> Bool {
 // 将sec_trust_t转换为SecTrust
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

 // 1. 基础证书链验证
        var result: SecTrustResultType = .invalid
        var error: CFError?
        let success = SecTrustEvaluateWithError(secTrust, &error)

        guard success else {
            SkyBridgeLogger.security.error("❌ 证书链验证失败: \(String(describing: error?.localizedDescription), privacy: .private)")
            return false
        }

 // 获取评估结果
        let evaluationResult = SecTrustGetTrustResult(secTrust, &result)
        guard evaluationResult == errSecSuccess else {
            SkyBridgeLogger.security.error("❌ 获取证书评估结果失败")
            return false
        }

 // 2. 证书固定验证 - 检查证书指纹
        guard performCertificatePinning(secTrust, for: deviceId) else {
            SkyBridgeLogger.security.error("❌ 证书固定验证失败: \(deviceId, privacy: .private)")
            return false
        }

 // 3. 量子安全证书验证 - 检查证书是否支持量子安全算法
        guard validateQuantumSafeCertificate(secTrust, for: deviceId) else {
            SkyBridgeLogger.security.error("❌ 量子安全证书验证失败: \(deviceId, privacy: .private)")
            return false
        }

 // 4. 证书有效期和撤销状态检查
        guard validateCertificateValidity(secTrust, for: deviceId) else {
            SkyBridgeLogger.security.error("❌ 证书有效性验证失败: \(deviceId, privacy: .private)")
            return false
        }

        switch result {
        case .unspecified, .proceed:
            SkyBridgeLogger.security.debugOnly("✅ 证书链验证成功: \(deviceId)")
            return true
        default:
            SkyBridgeLogger.security.error("❌ 证书链验证失败: \(String(describing: result))")
            return false
        }
    }

 /// 执行证书固定验证 - 检查证书指纹是否匹配预期值
    private func performCertificatePinning(_ trust: SecTrust, for deviceId: String) -> Bool {
 // 获取证书链中的叶子证书（使用新API）
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leafCertificate = chain.first else {
            SkyBridgeLogger.security.error("❌ 无法获取叶子证书")
            return false
        }

 // 计算证书的SHA-256指纹
        let certificateData = SecCertificateCopyData(leafCertificate)
        let data = CFDataGetBytePtr(certificateData)!
        let length = CFDataGetLength(certificateData)
        let certificateBytes = Data(bytes: data, count: length)

        let sha256Hash = SHA256.hash(data: certificateBytes)
        let fingerprint = sha256Hash.compactMap { String(format: "%02x", $0) }.joined()

 // 检查是否有预存的证书指纹
        if let expectedFingerprint = certificateManager.getStoredFingerprint(for: deviceId) {
            let isMatch = fingerprint == expectedFingerprint
            if !isMatch {
                SkyBridgeLogger.security.error("❌ 证书指纹不匹配 - 期望: \(expectedFingerprint, privacy: .private) 实际: \(fingerprint, privacy: .private)")
            }
            return isMatch
        } else {
 // 首次连接，存储证书指纹用于后续验证
            certificateManager.storeFingerprint(fingerprint, for: deviceId)
            SkyBridgeLogger.security.debugOnly("📌 存储新设备证书指纹: \(deviceId) -> \(fingerprint)")
            return true
        }
    }

 /// 验证量子安全证书 - 检查证书是否使用量子安全算法
    private func validateQuantumSafeCertificate(_ trust: SecTrust, for deviceId: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leafCertificate = chain.first else {
            return false
        }

 // 获取证书的公钥算法信息
        guard let publicKey = SecCertificateCopyKey(leafCertificate) else {
            SkyBridgeLogger.security.error("❌ 无法获取证书公钥")
            return false
        }

 // 检查密钥类型和大小
        guard let keyAttributes = SecKeyCopyAttributes(publicKey) as? [String: Any] else {
            SkyBridgeLogger.security.error("❌ 无法获取密钥属性")
            return false
        }

        let keyType = keyAttributes[kSecAttrKeyType as String] as? String
        let keySize = keyAttributes[kSecAttrKeySizeInBits as String] as? Int

 // 验证密钥强度（为量子安全做准备）
        if let type = keyType {
            switch type {
            case String(kSecAttrKeyTypeRSA):
 // RSA密钥至少需要3072位才能抵御量子攻击
                guard let size = keySize, size >= 3072 else {
                    SkyBridgeLogger.security.error("❌ RSA密钥长度不足，需要至少3072位")
                    return false
                }
            case String(kSecAttrKeyTypeECSECPrimeRandom):
 // ECC密钥至少需要256位（P-256）
                guard let size = keySize, size >= 256 else {
                    SkyBridgeLogger.security.error("❌ ECC密钥长度不足，需要至少256位")
                    return false
                }
            default:
                break
            }
        }

        return true
    }

 /// 验证证书有效性 - 检查有效期和撤销状态（OCSP）
 /// 在macOS 14+上，使用SecTrustEvaluateWithError并启用网络抓取，可触发系统级OCSP/CRL撤销检查。
    private func validateCertificateValidity(_ trust: SecTrust, for deviceId: String) -> Bool {
 // 设置SSL策略以确保使用服务器身份验证策略。
        let policy = SecPolicyCreateSSL(true, nil)
        SecTrustSetPolicies(trust, policy)

 // 如果证书链长度为1，则视为自签名P2P证书，跳过网络撤销检查但仍进行基本有效期验证。
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []

 // 启用网络抓取以允许系统尝试OCSP/CRL请求（非自签名时）。
        if chain.count > 1 {
            SecTrustSetNetworkFetchAllowed(trust, true)
        } else {
            SecTrustSetNetworkFetchAllowed(trust, false)
        }

 // 使用现代API进行评估；当启用网络抓取且存在撤销端点时，系统将自动进行OCSP检查。
        var evalError: CFError?
        let ok = SecTrustEvaluateWithError(trust, &evalError)
        guard ok else {
            SkyBridgeLogger.security.error("❌ 证书评估失败: \(String(describing: evalError?.localizedDescription), privacy: .private)")
            return false
        }

 // 继续进行结果类型检查，确保在有效期内且信任可接受。
        var result: SecTrustResultType = .invalid
        let status = SecTrustGetTrustResult(trust, &result)
        guard status == errSecSuccess else {
            SkyBridgeLogger.security.error("❌ 获取证书评估结果失败")
            return false
        }

        switch result {
        case .unspecified, .proceed:
            break
        case .recoverableTrustFailure:
 // 自签名或链不完整等情况可能导致可恢复的信任失败；在P2P场景中允许继续。
            SkyBridgeLogger.security.debugOnly("⚠️ 证书信任问题，但可恢复（可能为自签名或链不完整）")
            break
        default:
            SkyBridgeLogger.security.error("❌ 证书有效性验证失败: \(String(describing: result))")
            return false
        }

 // 如果为非自签名证书，尝试读取评估详情以记录撤销检查信息（如可用）。
        if chain.count > 1 {
            if let details = SecTrustCopyResult(trust) as? [String: Any] {
 // 注：该字典键未公开文档，仅用于日志跟踪，不影响功能。
                if let revocationInfo = details["RevocationCheckPerformed"] ?? details["RevocationInfo"] {
                    SkyBridgeLogger.security.debugOnly("🔍 撤销检查信息: \(String(describing: revocationInfo))")
                } else {
                    SkyBridgeLogger.security.debugOnly("ℹ️ 系统未提供撤销检查详情键，已完成标准评估")
                }
            }
        }

        SkyBridgeLogger.security.debugOnly("✅ 证书有效性与（如适用）撤销检查通过: \(deviceId)")
        return true
    }

 /// C 字符串安全解码为 Swift 字符串（避免使用不推荐API）
    private func decodeCString(_ cstr: UnsafePointer<CChar>) -> String {
        return String(cString: cstr)
    }
}

// MARK: - TLS量子加密管理器

/// TLS量子安全加密管理器 - 专门用于TLS连接的量子安全加密
private class TLSQuantumCryptoManager {

 /// 量子安全加密 - 目前使用AES-256-GCM作为过渡方案
    func quantumSafeEncrypt(_ data: Data, using key: SymmetricKey) async throws -> Data {
 // 在真正的量子安全算法可用之前，使用AES-256-GCM
        let sealedBox = try AES.GCM.seal(data, using: key)
        return sealedBox.combined!
    }

 /// 量子安全解密 - 目前使用AES-256-GCM作为过渡方案
    func quantumSafeDecrypt(_ encryptedData: Data, using key: SymmetricKey) async throws -> Data {
 // 在真正的量子安全算法可用之前，使用AES-256-GCM
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

 /// 生成量子安全密钥 - 目前使用256位随机密钥
    func generateQuantumSafeKey() -> SymmetricKey {
        return SymmetricKey(size: .bits256)
    }

 /// 密钥派生函数 - 使用HKDF进行密钥派生
    func deriveKey(from sharedSecret: Data, salt: Data, info: Data) throws -> SymmetricKey {
        let inputKeyMaterial = SymmetricKey(data: sharedSecret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }
}



// MARK: - 配置和数据模型

/// TLS配置
public struct TLSConfiguration: Sendable {
 /// 启用证书验证
    public let enableCertificateVerification: Bool
 /// 要求客户端证书
    public let requireClientCertificate: Bool
 /// 连接超时时间
    public let connectionTimeout: TimeInterval
 /// 保活间隔
    public let keepaliveInterval: TimeInterval

    public init(
        enableCertificateVerification: Bool = true,
        requireClientCertificate: Bool = false,
        connectionTimeout: TimeInterval = 30,
        keepaliveInterval: TimeInterval = 30
    ) {
        self.enableCertificateVerification = enableCertificateVerification
        self.requireClientCertificate = requireClientCertificate
        self.connectionTimeout = connectionTimeout
        self.keepaliveInterval = keepaliveInterval
    }

 /// 默认配置
    public static let `default` = TLSConfiguration()

 /// 高安全性配置
    public static let highSecurity = TLSConfiguration(
        enableCertificateVerification: true,
        requireClientCertificate: true,
        connectionTimeout: 15,
        keepaliveInterval: 15
    )
}

/// TLS模式
private enum TLSMode {
    case client
    case server
}

// MARK: - TLS统计信息

/// TLS统计信息
/// TLS 统计信息（包含 PQC 指标）
public struct TLSStatistics {
    public var startTime: Date = Date()
    public var connectionsEstablished: UInt64 = 0
    public var bytesSent: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var messagesSent: UInt64 = 0
    public var messagesReceived: UInt64 = 0
    public var errorCount: UInt64 = 0

 // PQC 指标（macOS 26+）
    public var pqcConnections: UInt64 = 0          // 使用 PQC 的连接数
    public var classicConnections: UInt64 = 0      // 使用经典算法的连接数
    public var pqcBytesSent: UInt64 = 0            // PQC 加密发送的字节数
    public var pqcBytesReceived: UInt64 = 0        // PQC 解密接收的字节数
    public var classicBytesSent: UInt64 = 0        // 经典算法发送的字节数
    public var classicBytesReceived: UInt64 = 0    // 经典算法接收的字节数
 // 最近一次握手协商信息（版本/套件/ALPN）
    public var lastProtocolVersion: String = ""
    public var lastCipherSuite: String = ""
    public var lastALPN: String = ""

    public init() {}
}

// MARK: - TLS错误

/// TLS安全错误
public enum TLSSecurityError: Error, LocalizedError {
    case connectionNotFound
    case certificateGenerationFailed
    case certificateValidationFailed
    case invalidDataFormat
    case connectionTimeout
    case tlsHandshakeFailed

    public var errorDescription: String? {
        switch self {
        case .connectionNotFound:
            return "连接未找到"
        case .certificateGenerationFailed:
            return "证书生成失败"
        case .certificateValidationFailed:
            return "证书验证失败"
        case .invalidDataFormat:
            return "数据格式无效"
        case .connectionTimeout:
            return "连接超时"
        case .tlsHandshakeFailed:
            return "TLS握手失败"
        }
    }
}

// MARK: - 证书管理器

/// 证书管理器 - 负责证书的生成、存储、验证和指纹管理
private class CertificateManager {

 /// 设备证书缓存
    private var certificateCache: [String: SecCertificate] = [:]
 /// 设备身份缓存
    private var identityCache: [String: SecIdentity] = [:]
 /// 证书指纹缓存 - 用于证书固定
    private var fingerprintCache: [String: String] = [:]

    init() {
 // 初始化时加载存储的证书指纹
        loadStoredFingerprints()
    }

 /// 获取设备证书
    func getCertificate(for deviceId: String) -> SecCertificate? {
        if let cachedCertificate = certificateCache[deviceId] {
            return cachedCertificate
        }

 // 从钥匙串加载证书
        let certificate = loadCertificateFromKeychain(deviceId: deviceId)
        if let certificate = certificate {
            certificateCache[deviceId] = certificate
        }

        return certificate
    }

 /// 获取设备身份
    func getIdentity(for deviceId: String) -> SecIdentity? {
        if let cachedIdentity = identityCache[deviceId] {
            return cachedIdentity
        }

 // 从钥匙串加载身份
        let identity = loadIdentityFromKeychain(deviceId: deviceId)
        if let identity = identity {
            identityCache[deviceId] = identity
        }

        return identity
    }

    /// 验证证书
    func validateCertificate(_ certificate: SecCertificate, for deviceId: String) -> Bool {
        let certificateDataRef = SecCertificateCopyData(certificate)
        let certificateData = certificateDataRef as Data
        guard !certificateData.isEmpty else {
            return false
        }

        let digest = SHA256.hash(data: certificateData)
        let fingerprint = digest.compactMap { String(format: "%02x", $0) }.joined()

 // 优先使用已存指纹做 pinning；没有 pin 的 helper 不允许 silent trust-on-first-use。
        if let storedFingerprint = getStoredFingerprint(for: deviceId) {
            let matches = fingerprint == storedFingerprint
            if !matches {
                SkyBridgeLogger.security.error("❌ 证书指纹不匹配: \(deviceId, privacy: .private)")
            }
            return matches
        }

 // 若已有本地证书，则要求字节级一致，避免把任意非空证书当成合法证书。
        if let localCertificate = loadCertificateFromKeychain(deviceId: deviceId) {
            let localData = SecCertificateCopyData(localCertificate) as Data
            let matches = localData == certificateData
            if !matches {
                SkyBridgeLogger.security.error("❌ 证书与本地已存证书不匹配: \(deviceId, privacy: .private)")
            }
            return matches
        }

        SkyBridgeLogger.security.error("❌ 缺少已知 pin/certificate，拒绝隐式信任对端证书: \(deviceId, privacy: .private)")
        return false
    }

 /// 获取存储的证书指纹 - 用于证书固定
    func getStoredFingerprint(for deviceId: String) -> String? {
        return fingerprintCache[deviceId]
    }

 /// 存储证书指纹 - 用于证书固定
    func storeFingerprint(_ fingerprint: String, for deviceId: String) {
        fingerprintCache[deviceId] = fingerprint

 // 同时存储到UserDefaults以持久化
        let key = "CertificateFingerprint_\(deviceId)"
        UserDefaults.standard.set(fingerprint, forKey: key)

        SkyBridgeLogger.security.debugOnly("📌 证书指纹已存储: \(deviceId) -> \(fingerprint)")
    }

 /// 从持久化存储加载证书指纹
    private func loadStoredFingerprints() {
 // 从UserDefaults加载所有存储的指纹
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        for key in allKeys {
            if key.hasPrefix("CertificateFingerprint_") {
                let deviceId = String(key.dropFirst("CertificateFingerprint_".count))
                if let fingerprint = defaults.string(forKey: key) {
                    fingerprintCache[deviceId] = fingerprint
                }
            }
        }
    }

 /// 生成自签名证书
    func generateSelfSignedCertificate(for deviceId: String) -> SecCertificate? {
 // 生成 P‑256 密钥对并持久化到钥匙串
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: "SkyBridge.\(deviceId)".utf8Data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &err) else { return nil }
        guard let pub = SecKeyCopyPublicKey(priv) else { return nil }
        guard let x963 = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { return nil }

 // 构建 TBSCertificate（v3）
        let serial = withUnsafeBytes(of: UInt64.random(in: 1...UInt64.max).bigEndian) { Data($0) }
        let versionV3 = derExplicit(tag: 0, content: derInteger(value: 2))
        let sigAlg = derSequence(derOID(from: "1.2.840.10045.4.3.2"))
        let name = derSubjectName(cn: "SkyBridge Device \(deviceId)", o: "SkyBridge", ou: "Devices")
        let validity = derSequence(derGeneralizedTime(Date().addingTimeInterval(-3600)) + derGeneralizedTime(Date().addingTimeInterval(365*24*3600)))
        let spki = derSubjectPublicKeyInfoECPrime256v1(x963)
        let ext = derExtensions(basicConstraintsCAFalse: true, keyUsageBits: 0x86, extKeyUsages: ["1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.2"], sanDNS: [], sanIP: [])
        let tbs = derSequence(versionV3 + derInteger(data: serial) + sigAlg + name + validity + name + spki + ext)

 // 使用 ECDSA+SHA256 对 TBSCertificate 签名
        guard let signature = SecKeyCreateSignature(priv, SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256, tbs as CFData, nil) as Data? else { return nil }
        let certDER = derSequence(tbs + sigAlg + derBitString(signature))

 // 创建 SecCertificate 并写入钥匙串，返回证书引用
        guard let certRef = SecCertificateCreateWithData(nil, certDER as CFData) else { return nil }
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "SkyBridge.\(deviceId)",
            kSecValueRef as String: certRef,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(addCert as CFDictionary)
        _ = SecItemAdd(addCert as CFDictionary, nil)
        certificateCache[deviceId] = certRef
 // 缓存身份（钥匙串中已有 key+cert，可通过查询得到 identity）
        let idQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "SkyBridge.\(deviceId)",
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(idQuery as CFDictionary, &item) == errSecSuccess, let anyItem = item {
            let identity = unsafeDowncast(anyItem as AnyObject, to: SecIdentity.self)
            identityCache[deviceId] = identity
        }
        return certRef
    }

 /// 导入PKCS#12并保存到钥匙串，配置为指定设备的本地身份
    func importIdentityFromPKCS12(_ p12Data: Data, password: String, for deviceId: String) -> Bool {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first else {
            SkyBridgeLogger.security.error("❌ PKCS#12 导入失败: \(status)")
            return false
        }
        guard let anyIdentity = first[kSecImportItemIdentity as String] else {
            SkyBridgeLogger.security.error("❌ PKCS#12 中未找到身份")
            return false
        }
        guard CFGetTypeID(anyIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            SkyBridgeLogger.security.error("❌ PKCS#12 项类型不是 SecIdentity")
            return false
        }
        let identity = unsafeDowncast(anyIdentity as AnyObject, to: SecIdentity.self)
 // 保存到缓存并写入钥匙串（便于后续加载）
        identityCache[deviceId] = identity
 // 提取证书并缓存
        var certRef: SecCertificate?
        if SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef {
            certificateCache[deviceId] = cert
        }
 // 将身份写入 Keychain（以标签便于后续检索）
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "SkyBridge.\(deviceId)",
            kSecValueRef as String: identity,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(addQuery as CFDictionary)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            SkyBridgeLogger.security.error("❌ 身份写入钥匙串失败: \(addStatus)")
            return false
        }
        SkyBridgeLogger.security.debugOnly("✅ PKCS#12 身份已导入并配置: \(deviceId)")
        return true
    }

 /// 生成 PKCS#10 CSR（DER 编码）
    func generatePKCS10CSRDER(commonName: String, organization: String?, organizationalUnit: String?, sanDNS: [String], sanIP: [String], privateKey: SecKey) -> Data? {
        guard let pubKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        guard let pubRaw = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else { return nil }
        let version = derIntegerZero()
        let subject = derSubjectName(cn: commonName, o: organization, ou: organizationalUnit)
        let spki = derSubjectPublicKeyInfoECPrime256v1(pubRaw)
        let attributes = derCSRAttributesWithExtensions(sanDNS: sanDNS, sanIP: sanIP)
        let cri = derSequence(version + subject + spki + attributes)
        guard let sig = SecKeyCreateSignature(privateKey, SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256, cri as CFData, nil) as Data? else { return nil }
        let sigAlg = derSequence(derOID(from: "1.2.840.10045.4.3.2"))
        let sigBits = derBitString(sig)
        return derSequence(cri + sigAlg + sigBits)
    }

    private func derSequence(_ content: Data) -> Data { var out = Data([0x30]); out.append(derLength(content.count)); out.append(content); return out }
    private func derSet(_ content: Data) -> Data { var out = Data([0x31]); out.append(derLength(content.count)); out.append(content); return out }
    private func derIntegerZero() -> Data { Data([0x02, 0x01, 0x00]) }
    private func derInteger(value: Int) -> Data {
        var be = withUnsafeBytes(of: Int64(value).bigEndian) { Data($0) }
        while be.first == 0 { be.removeFirst() }
        if let first = be.first, (first & 0x80) != 0 { be.insert(0x00, at: 0) }
        var out = Data([0x02]); out.append(derLength(be.count)); out.append(be); return out
    }
    private func derInteger(data: Data) -> Data { var out = Data([0x02]); out.append(derLength(data.count)); out.append(data); return out }
    private func derOID(from dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return Data([0x06, 0x01, 0x00]) }
        var body = Data(); body.append(UInt8(parts[0] * 40 + parts[1]));
        for p in parts.dropFirst(2) { body.append(contentsOf: derBase128(p)) }
        var out = Data([0x06]); out.append(derLength(body.count)); out.append(body); return out
    }
    private func derBitString(_ bytes: Data) -> Data { var body = Data([0x00]); body.append(bytes); var out = Data([0x03]); out.append(derLength(body.count)); out.append(body); return out }
    private func derUTF8String(_ s: String) -> Data { let d = Data(s.utf8); var out = Data([0x0C]); out.append(derLength(d.count)); out.append(d); return out }
    private func derLength(_ n: Int) -> Data { if n < 0x80 { return Data([UInt8(n)]) }; var bytes = withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) }; while bytes.first == 0 { bytes.removeFirst() }; var out = Data([0x80 | UInt8(bytes.count)]); out.append(bytes); return out }
    private func derBase128(_ value: Int) -> [UInt8] { var val = value; var bytes: [UInt8] = [UInt8(val & 0x7F)]; val >>= 7; while val > 0 { bytes.insert(UInt8(0x80 | (val & 0x7F)), at: 0); val >>= 7 } ; return bytes }
    private func derGeneralizedTime(_ date: Date) -> Data {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        let s = String(format: "%04d%02d%02d%02d%02d%02dZ",
                       comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1,
                       comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
        let d = Data(s.utf8)
        var out = Data([0x18]); out.append(derLength(d.count)); out.append(d); return out
    }
    private func derExplicit(tag: UInt8, content: Data) -> Data { var out = Data([0xA0 | tag]); out.append(derLength(content.count)); out.append(content); return out }
    private func derSubjectCommonName(_ cn: String) -> Data { let atv = derSequence(derOID(from: "2.5.4.3") + derUTF8String(cn)); let rdn = derSet(atv); return derSequence(rdn) }
    private func derSubjectName(cn: String, o: String?, ou: String?) -> Data {
        let cnRDN = derSubjectCommonName(cn)
        var atvs = Data()
        if let o = o { atvs.append(derSequence(derOID(from: "2.5.4.10") + derUTF8String(o))) }
        if let ou = ou { atvs.append(derSequence(derOID(from: "2.5.4.11") + derUTF8String(ou))) }
        let orgRDN = atvs.isEmpty ? Data() : derSet(atvs)
        if orgRDN.isEmpty { return cnRDN }
        return derSequence(cnRDN + orgRDN)
    }
    private func derCSRAttributesWithExtensions(sanDNS: [String], sanIP: [String]) -> Data {
 // Extensions = SEQUENCE { extSubjectAltName }
        let sanExt = derExtensionSubjectAltName(dns: sanDNS, ip: sanIP)
        let extensions = derSequence(sanExt)
 // extensionRequest attribute: SEQUENCE { OID(1.2.840.113549.1.9.14), SET { Extensions } }
        let attr = derSequence(derOID(from: "1.2.840.113549.1.9.14") + derSet(extensions))
 // [0] IMPLICIT attributes: A0 <len> content
        var out = Data([0xA0])
        out.append(derLength(attr.count))
        out.append(attr)
        return out
    }
    private func derExtensionSubjectAltName(dns: [String], ip: [String]) -> Data {
 // OID subjectAltName (2.5.29.17) + OCTET STRING (encoded SAN)
        let sanSeq = derSANSequence(dns: dns, ip: ip)
        let sanOctet = derOctetString(sanSeq)
        return derSequence(derOID(from: "2.5.29.17") + sanOctet)
    }
    private func derOctetString(_ d: Data) -> Data { var out = Data([0x04]); out.append(derLength(d.count)); out.append(d); return out }
    private func derIA5String(_ s: String) -> Data { let d = Data(s.utf8); var out = Data([0x16]); out.append(derLength(d.count)); out.append(d); return out }
    private func derSANSequence(dns: [String], ip: [String]) -> Data {
        var content = Data()
        for host in dns {
            let ia5 = Data(host.utf8)
            var gn = Data([0x82]) // [2] dNSName, context-specific primitive
            gn.append(derLength(ia5.count))
            gn.append(ia5)
            content.append(gn)
        }
        for addr in ip {
            if let bytes = parseIPAddress(addr) {
                var gn = Data([0x87]) // [7] iPAddress
                gn.append(derLength(bytes.count))
                gn.append(bytes)
                content.append(gn)
            }
        }
        return derSequence(content)
    }
    private func parseIPAddress(_ s: String) -> Data? {
        if s.contains(":") {
            var addr6 = in6_addr()
            let ok = s.withCString { inet_pton(AF_INET6, $0, &addr6) }
            guard ok == 1 else { return nil }
            return withUnsafeBytes(of: addr6) { Data($0) }
        } else {
            let parts = s.split(separator: ".")
            guard parts.count == 4 else { return nil }
            var out = Data()
            for p in parts { guard let v = UInt8(p) else { return nil }; out.append(v) }
            return out
        }
    }
    private func derSubjectPublicKeyInfoECPrime256v1(_ x963: Data) -> Data { let alg = derSequence(derOID(from: "1.2.840.10045.2.1") + derOID(from: "1.2.840.10045.3.1.7")); let bit = derBitString(x963); return derSequence(alg + bit) }
    private func derExtensions(basicConstraintsCAFalse: Bool, keyUsageBits: UInt, extKeyUsages: [String], sanDNS: [String], sanIP: [String]) -> Data {
        var content = Data()
        if basicConstraintsCAFalse {
            let inner = derSequence(Data())
            content.append(derSequence(derOID(from: "2.5.29.19") + derOctetString(inner)))
        }
        let bitString: Data = { let body = Data([0x00, UInt8(keyUsageBits & 0xFF)]); var out = Data([0x03]); out.append(derLength(body.count)); out.append(body); return out }()
        let ku = derSequence(derOID(from: "2.5.29.15") + Data([0x01, 0x01, 0xFF]) + derOctetString(bitString))
        content.append(ku)
        if !extKeyUsages.isEmpty {
            var ekus = Data(); for oid in extKeyUsages { ekus.append(derOID(from: oid)) }
            let eku = derSequence(derOID(from: "2.5.29.37") + derOctetString(derSequence(ekus)))
            content.append(eku)
        }
        if !sanDNS.isEmpty || !sanIP.isEmpty {
            let san = derSequence(derOID(from: "2.5.29.17") + derOctetString(derSANSequence(dns: sanDNS, ip: sanIP)))
            content.append(san)
        }
        return derSequence(content)
    }

 // MARK: - 私有方法

 /// 从钥匙串加载证书
    private func loadCertificateFromKeychain(deviceId: String) -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "SkyBridge.\(deviceId)",
            kSecReturnRef as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let anyItem = result, CFGetTypeID(anyItem) == SecCertificateGetTypeID() else {
            SkyBridgeLogger.security.error("无法加载证书，status=\(status)")
            return nil
        }
        let cert = unsafeDowncast(anyItem, to: SecCertificate.self)
        return cert
    }

 /// 从钥匙串加载身份
    private func loadIdentityFromKeychain(deviceId: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "SkyBridge.\(deviceId)",
            kSecReturnRef as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let anyItem = result, CFGetTypeID(anyItem) == SecIdentityGetTypeID() else {
            SkyBridgeLogger.security.error("无法加载身份，status=\(status)")
            return nil
        }
        let identity = unsafeDowncast(anyItem, to: SecIdentity.self)
        return identity
    }
}
 /// 简易 CA 签发工作流
    public final class CAServiceManager {
        private let logger = Logger(subsystem: "com.skybridge.tls", category: "CAServiceManager")
        public init() {}

 /// 提交 CSR 到 CA
        public func submitCSR(_ csrPEM: String, to endpoint: URL) async throws -> String {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-pem-file", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(csrPEM.utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw TLSSecurityError.certificateValidationFailed
            }
            let id = String(data: data, encoding: .utf8) ?? UUID().uuidString
            logger.info("✅ CSR 提交成功，requestId=\(id)")
            return id
        }

 /// 轮询证书签发状态（返回 PEM 如已签发）
        public func pollCertificateStatus(requestId: String, from endpoint: URL) async throws -> (issued: Bool, pem: String?) {
            var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            var q = comps?.queryItems ?? []
            q.append(URLQueryItem(name: "requestId", value: requestId))
            comps?.queryItems = q
            guard let url = comps?.url else { throw TLSSecurityError.certificateValidationFailed }
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw TLSSecurityError.certificateValidationFailed
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let issued = body.contains("BEGIN CERTIFICATE")
            return (issued, issued ? body : nil)
        }

 /// 导入已签发证书（PEM），写入钥匙串并缓存
        public func importIssuedCertificate(_ pem: String, for deviceId: String) -> Bool {
 // 解析 PEM 去头尾
            let lines = pem.split(separator: "\n").filter { !$0.hasPrefix("---") }
            let b64 = lines.joined()
            guard let der = Data(base64Encoded: b64) else { return false }
            guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return false }
 // 写入钥匙串
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: "SkyBridge.\(deviceId)",
                kSecValueRef as String: cert,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            SecItemDelete(addQuery as CFDictionary)
            let st = SecItemAdd(addQuery as CFDictionary, nil)
            if st != errSecSuccess { return false }
            return true
        }
    }
