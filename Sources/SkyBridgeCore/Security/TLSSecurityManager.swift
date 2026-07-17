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

/// Immutable identity binding for one authenticated transport peer. Local and
/// remote roles never share a storage slot, so concurrent client/server
/// connections cannot overwrite the identity used by HPKE AAD.
struct TLSConnectionIdentityContext: Equatable, Sendable {
    static let maximumDeviceIdUTF8Length = 256

    let localDeviceId: String
    let remoteDeviceId: String

    init(localDeviceId: String, remoteDeviceId: String) throws {
        self.localDeviceId = try Self.validatedDeviceId(localDeviceId)
        self.remoteDeviceId = try Self.validatedDeviceId(remoteDeviceId)
        guard self.localDeviceId != self.remoteDeviceId else {
            throw TLSSecurityError.invalidConnectionIdentity
        }
    }

    func outboundHybridAAD(profile: String) -> Data {
        Self.hybridAAD(
            profile: profile,
            senderDeviceId: localDeviceId,
            recipientDeviceId: remoteDeviceId
        )
    }

    func inboundHybridAAD(profile: String) -> Data {
        Self.hybridAAD(
            profile: profile,
            senderDeviceId: remoteDeviceId,
            recipientDeviceId: localDeviceId
        )
    }

    static func validatedDeviceId(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw == trimmed,
              !raw.isEmpty,
              raw.utf8.count <= maximumDeviceIdUTF8Length,
              raw.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw TLSSecurityError.invalidConnectionIdentity
        }
        return raw
    }

    private static func hybridAAD(
        profile: String,
        senderDeviceId: String,
        recipientDeviceId: String
    ) -> Data {
        var aad = Data("SkyBridgeTLSAppPayload".utf8)
        for field in ["v2", profile, senderDeviceId, recipientDeviceId] {
            let encodedLength = withUnsafeBytes(
                of: UInt32(field.utf8.count).bigEndian
            ) { Data($0) }
            aad.append(encodedLength)
            aad.append(contentsOf: field.utf8)
        }
        return aad
    }
}

/// TLS安全管理器 - 负责TLS 1.3加密通信和证书管理；应用层 PQC 只在 HPKE/key material 具备证据时启用
@MainActor
public final class TLSSecurityManager: ObservableObject {

 // MARK: - 生命周期管理

 /// 管理器是否已启动
    @Published public private(set) var isStarted: Bool = false

 // MARK: - 属性

 /// TLS配置
    private let tlsConfiguration: TLSConfiguration
    private enum Usage {
        case certificateOnly
        case transport(localDeviceId: String)
    }
    private let usage: Usage
 /// 证书管理器
    private let certificateManager: CertificateManager
    /// Authenticated, ready connections are private so callers cannot bypass
    /// the profile/identity policy by sending directly on NWConnection.
    private var activeConnections: [String: NWConnection] = [:]
    private var pendingConnections: [String: NWConnection] = [:]
    private var pendingConnectionTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var serverListeners: [String: NWListener] = [:]
    private var cryptoProfileByDeviceId: [String: CryptoProfile] = [:]
 /// TLS统计信息
    @Published public private(set) var tlsStatistics: TLSStatistics = TLSStatistics()
    /// 量子安全加密管理器
    private let quantumCryptoManager: QuantumCryptoManager
    private var pqcProviderByDeviceId: [String: PQCProvider] = [:]
    private var hpkeProviderByDeviceId: [String: PQCHPKEProvider] = [:]
    private var identityContextByRemoteDeviceId: [String: TLSConnectionIdentityContext] = [:]
    public enum CryptoProfile: String, Sendable {
        case classicP256
        case pqcMlKemMlDsa
        case hybridXWing
    }
    private func negotiateProfile(
        offered: [CryptoProfile],
        supported: [CryptoProfile]
    ) -> CryptoProfile? {
        for p in offered { if supported.contains(p) { return p } }
        return nil
    }

    private func negotiateApplicationCryptoProfile(
        peerOfferedProfiles: [CryptoProfile]?
    ) throws -> CryptoProfile {
        guard let peerOfferedProfiles, !peerOfferedProfiles.isEmpty else {
            return .classicP256
        }
        guard let negotiated = negotiateProfile(
            offered: peerOfferedProfiles,
            supported: supportedApplicationCryptoProfiles()
        ) else {
            throw TLSSecurityError.noMutualCryptoProfile
        }
        return negotiated
    }

    private func supportedApplicationCryptoProfiles() -> [CryptoProfile] {
        var supported: [CryptoProfile] = []
        if PQCProviderFactory.supportsSuite(.hybridXWing) {
            supported.append(.hybridXWing)
        }
        if PQCProviderFactory.supportsSuite(.pqcMlKemMlDsa) {
            supported.append(.pqcMlKemMlDsa)
        }
        supported.append(.classicP256)
        return supported
    }
 // MARK: - 初始化

    public init(configuration: TLSConfiguration = .default) {
        self.tlsConfiguration = configuration
        self.usage = .certificateOnly
        self.certificateManager = CertificateManager()
        self.quantumCryptoManager = QuantumCryptoManager()
    }

    private init(
        configuration: TLSConfiguration,
        verifiedLocalDeviceId: String
    ) throws {
        let localDeviceId = try TLSConnectionIdentityContext
            .validatedDeviceId(verifiedLocalDeviceId)
        self.tlsConfiguration = configuration
        self.usage = .transport(localDeviceId: localDeviceId)
        self.certificateManager = CertificateManager()
        self.quantumCryptoManager = QuantumCryptoManager()
    }

    /// Creates the transport-capable manager from the immutable protocol
    /// identity authority. The ordinary initializer remains certificate-only
    /// for settings/CSR tooling and cannot open connections.
    public static func makeTransportManager(
        configuration: TLSConfiguration = .default
    ) async throws -> TLSSecurityManager {
        let identity = try await SelfIdentityProvider.shared
            .snapshotEnsuringProtocolDeviceId(allowCreate: true)
        return try TLSSecurityManager(
            configuration: configuration,
            verifiedLocalDeviceId: identity.deviceId
        )
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

 /// 创建 TLS 1.3 客户端连接；应用层 PQC profile 需要单独的 HPKE/key material 证明
    public func createClientConnection(
        to endpoint: NWEndpoint,
        remoteDeviceId: String
    ) throws -> NWConnection {
        guard isStarted else { throw TLSSecurityError.notStarted }
        guard tlsConfiguration.enableCertificateVerification else {
            throw TLSSecurityError.peerAuthenticationRequired
        }
        let identityContext = try connectionIdentityContext(
            remoteDeviceId: remoteDeviceId
        )
        guard try certificateManager.getIdentity(
            for: identityContext.localDeviceId
        ) != nil else {
            throw TLSSecurityError.localCertificateUnavailable
        }
        guard activeConnections[identityContext.remoteDeviceId] == nil,
              pendingConnections[identityContext.remoteDeviceId] == nil else {
            throw TLSSecurityError.connectionAlreadyExists
        }
 // 创建 TLS 1.3 选项；传输层 PQC 协商不在此处伪造为已证明状态
        let tlsOptions = try createQuantumSecureTLSOptions(
            for: .client,
            identityContext: identityContext
        )

 // 创建TCP选项
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = Int(
            tlsConfiguration.keepaliveInterval.rounded(.up)
        )
        tcpOptions.keepaliveInterval = Int(
            tlsConfiguration.keepaliveInterval.rounded(.up)
        )
        tcpOptions.keepaliveCount = 3
        tcpOptions.connectionTimeout = Int(
            tlsConfiguration.connectionTimeout.rounded(.up)
        )

 // 创建连接参数
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = true

 // 创建连接
        let connection = NWConnection(to: endpoint, using: parameters)

 // 设置连接状态监听
        let profile = CryptoProfile.classicP256
        guard registerPendingConnection(
            connection,
            identityContext: identityContext,
            profile: profile,
            logPrefix: "Client"
        ) else {
            connection.cancel()
            throw TLSSecurityError.connectionAlreadyExists
        }
        SkyBridgeLogger.security.debugOnly("Crypto profile selected: \(profile.rawValue)")

        SkyBridgeLogger.security.debugOnly("🔐 创建 TLS 1.3 客户端连接: \(identityContext.remoteDeviceId) -> \(String(describing: endpoint)); app-layer PQC profile=\(profile.rawValue)")
        return connection
    }

 /// 创建只接受一个已授权远端身份的 TLS 1.3 服务器监听器。
 /// 未完成应用握手身份映射的通用多对端 listener 不得进入此 transport API。
    public func createServerListener(
        on port: UInt16,
        expectedRemoteDeviceId: String
    ) throws -> NWListener {
        guard isStarted else { throw TLSSecurityError.notStarted }
        guard tlsConfiguration.requireClientCertificate else {
            throw TLSSecurityError.peerAuthenticationRequired
        }
        let identityContext = try connectionIdentityContext(
            remoteDeviceId: expectedRemoteDeviceId
        )
        guard serverListeners[identityContext.remoteDeviceId] == nil else {
            throw TLSSecurityError.connectionAlreadyExists
        }
        guard try certificateManager.getIdentity(
            for: identityContext.localDeviceId
        ) != nil else {
            throw TLSSecurityError.localCertificateUnavailable
        }
 // 创建 TLS 1.3 选项；传输层 PQC 协商不在此处伪造为已证明状态
        let tlsOptions = try createQuantumSecureTLSOptions(
            for: .server,
            identityContext: identityContext
        )

 // 创建TCP选项
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = Int(
            tlsConfiguration.keepaliveInterval.rounded(.up)
        )
        tcpOptions.keepaliveInterval = Int(
            tlsConfiguration.keepaliveInterval.rounded(.up)
        )
        tcpOptions.connectionTimeout = Int(
            tlsConfiguration.connectionTimeout.rounded(.up)
        )

 // 创建监听参数
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true

 // 创建监听器
        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port.validated(port)
        )

	 // 设置新连接处理器
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                let negotiatedProfile: CryptoProfile
                do {
                    negotiatedProfile = try self
                        .negotiateApplicationCryptoProfile(
                            peerOfferedProfiles: nil
                        )
                } catch {
                    connection.cancel()
                    SkyBridgeLogger.security.error(
                        "TLS 应用层 profile 协商失败: \(error.localizedDescription, privacy: .private)"
                    )
                    return
                }
                self.handleNewConnection(
                    connection,
                    identityContext: identityContext,
                    profile: negotiatedProfile
                )
                SkyBridgeLogger.security.debugOnly("Crypto profile selected: \(negotiatedProfile.rawValue)")
            }
        }

 // 设置状态变化处理器
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            Task { @MainActor in
                self?.handleListenerStateChange(
                    state,
                    listener: listener,
                    identityContext: identityContext
                )
            }
        }
        serverListeners[identityContext.remoteDeviceId] = listener

        SkyBridgeLogger.security.debugOnly("🔐 创建 TLS 1.3 服务器监听器: local=\(identityContext.localDeviceId) expectedRemote=\(identityContext.remoteDeviceId) port=\(port); app-layer PQC profile is negotiated per connection")
        return listener
    }

 /// 发送 TLS 应用层加密数据；只有 hybrid/PQC profile 成功封装后才记录 PQC 指标
    public func sendSecureData(_ data: Data, to deviceId: String, completion: @escaping @Sendable (Error?) -> Void) {
        guard let connection = activeConnections[deviceId] else {
            completion(TLSSecurityError.connectionNotFound)
            return
        }
        let profile: CryptoProfile
        do {
            profile = try cryptoProfile(for: deviceId)
        } catch {
            completion(error)
            return
        }

        Task {
            do {
                let encryptedData: Data
                switch profile {
                case .hybridXWing:
                    encryptedData = try makeHybridXWingPayload(data, recipientDeviceId: deviceId)
                case .pqcMlKemMlDsa, .classicP256:
                    // 旧路径用「每次随机生成、从不与对端共享」的对称密钥加密，产生的密文对端
                    // 永远无法解开（非互通且具误导性）。应用层安全数据仅支持经真实 HPKE 协商的
                    // hybridXWing profile；其余 profile 一律 fail-closed，绝不发送伪“加密”数据。
                    throw TLSSecurityError.pqcMaterialUnavailable(
                        profile: "non-hybrid",
                        operation: "sendSecureData",
                        reason: "应用层安全数据仅支持 hybridXWing(真实 HPKE)；旧 pqc/classic 直接对称加密路径使用一次性密钥、对端无法解密，已 fail-closed"
                    )
                }
                connection.send(content: encryptedData, completion: .contentProcessed { error in
                    Task { @MainActor in
                        if let error = error {
                            completion(error)
                        } else {
                            self.tlsStatistics.bytesSent += UInt64(encryptedData.count)
                            self.tlsStatistics.messagesSent += 1
                            // 只有 hybridXWing 能到达这里，必为 PQC 路径
                            self.tlsStatistics.pqcBytesSent += UInt64(encryptedData.count)
                            completion(nil)
                        }
                    }
                })
            } catch {
                completion(error)
            }
        }
    }

 /// 接收 TLS 应用层加密数据；只有 hybrid/PQC profile 成功打开后才记录 PQC 指标
    public func receiveSecureData(from deviceId: String, completion: @escaping @Sendable (Data?, Error?) -> Void) {
        guard let connection = activeConnections[deviceId] else {
            completion(nil, TLSSecurityError.connectionNotFound)
            return
        }
        let profile: CryptoProfile
        let identityContext: TLSConnectionIdentityContext
        do {
            profile = try cryptoProfile(for: deviceId)
            identityContext = try requiredIdentityContext(
                for: deviceId
            )
        } catch {
            completion(nil, error)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                if let error = error {
                    completion(nil, error)
                } else if let encryptedData = data {
                    do {
                        guard let strongSelf = self else { completion(nil, TLSSecurityError.connectionNotFound); return }
                        let decryptedData: Data
                        switch profile {
                        case .hybridXWing:
                            decryptedData = try strongSelf.openHybridXWingPayload(
                                encryptedData,
                                identityContext: identityContext
                            )
                        case .pqcMlKemMlDsa, .classicP256:
                            // 与 sendSecureData 对称：非 hybrid profile 的旧一次性密钥路径无法
                            // 互通，fail-closed 而非用错误密钥“解密”得到垃圾数据。
                            throw TLSSecurityError.pqcMaterialUnavailable(
                                profile: "non-hybrid",
                                operation: "receiveSecureData",
                                reason: "应用层安全数据仅支持 hybridXWing(真实 HPKE)；旧 pqc/classic 直接对称解密路径使用一次性密钥，已 fail-closed"
                            )
                        }
                        strongSelf.tlsStatistics.bytesReceived += UInt64(encryptedData.count)
                        strongSelf.tlsStatistics.messagesReceived += 1
                        // 只有 hybridXWing 能到达这里，必为 PQC 路径
                        strongSelf.tlsStatistics.pqcBytesReceived += UInt64(encryptedData.count)
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
    public func getIdentity(for deviceId: String) throws -> SecIdentity? {
 // 中文说明：对内部CertificateManager的获取方法进行公开包装，便于服务端TLS设置本地身份。
        try certificateManager.getIdentity(for: deviceId)
    }

 // MARK: - TLS/设备证书管理

 /// 获取设备 TLS 证书
    public func getDeviceCertificate(for deviceId: String) throws -> SecCertificate? {
        try certificateManager.getCertificate(for: deviceId)
    }

 /// 验证对等设备 TLS 证书
    public func validatePeerCertificate(_ certificate: SecCertificate, for deviceId: String) -> Bool {
        return certificateManager.validateCertificate(certificate, for: deviceId)
    }

 /// 生成本地 P2P 自签名 TLS 证书；证书签名仍是经典 P-256/ECDSA，不作为 PQC 证明。
    public func generateSelfSignedCertificate(for deviceId: String) throws -> SecCertificate {
        try certificateManager.generateSelfSignedCertificate(for: deviceId)
    }

 /// 导入PKCS#12并设置为指定设备的本地身份（服务端/客户端均可复用）
    public func importIdentityFromPKCS12(
        _ p12Data: Data,
        password: String,
        for deviceId: String
    ) throws {
        try certificateManager.importIdentityFromPKCS12(
            p12Data,
            password: password,
            for: deviceId
        )
    }

 /// 生成 PKCS#10 CSR（DER -> PEM）
    public func generateCSRPEM(
        for deviceId: String,
        commonName: String
    ) throws -> String {
        try certificateManager.generateCSRPEM(
            for: deviceId,
            commonName: commonName,
            organization: nil,
            organizationalUnit: nil,
            sanDNS: [],
            sanIP: []
        )
    }

 /// 生成 CSR（支持 CN/O/OU 与 SAN 扩展），返回 PEM
    public func generateCSRPEM(
        for deviceId: String,
        commonName: String,
        organization: String?,
        organizationalUnit: String?,
        sanDNS: [String],
        sanIP: [String]
    ) throws -> String {
        try certificateManager.generateCSRPEM(
            for: deviceId,
            commonName: commonName,
            organization: organization,
            organizationalUnit: organizationalUnit,
            sanDNS: sanDNS,
            sanIP: sanIP
        )
    }

    // MARK: - 后台（off-main）封装：把可能耗时的密钥/证书操作移出主线程，避免设置页卡死。
    // detached 任务内部创建独占的 CertificateManager，只回传 Sendable 结果。

    /// 后台生成或加载自签证书；不跨域传递非 Sendable 的 SecCertificate。
    public func ensureSelfSignedCertificateOffMain(for deviceId: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try CertificateManager().generateSelfSignedCertificate(
                for: deviceId
            )
        }.value
    }

    /// 后台导入 PKCS#12 身份；错误保持 typed 且可观测。
    public func importIdentityFromPKCS12OffMain(
        _ p12Data: Data,
        password: String,
        for deviceId: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try CertificateManager().importIdentityFromPKCS12(
                p12Data,
                password: password,
                for: deviceId
            )
        }.value
    }

    /// 后台生成 CSR（PEM）。
    public func generateCSRPEMOffMain(
        for deviceId: String,
        commonName: String,
        organization: String?,
        organizationalUnit: String?,
        sanDNS: [String],
        sanIP: [String]
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try CertificateManager().generateCSRPEM(
                for: deviceId,
                commonName: commonName,
                organization: organization,
                organizationalUnit: organizationalUnit,
                sanDNS: sanDNS,
                sanIP: sanIP
            )
        }.value
    }

 // MARK: - 连接管理

 /// 关闭指定设备的连接
    public func closeConnection(for deviceId: String) {
        if let connection = activeConnections[deviceId] {
            connection.cancel()
            activeConnections.removeValue(forKey: deviceId)
            cryptoProfileByDeviceId.removeValue(forKey: deviceId)
            identityContextByRemoteDeviceId.removeValue(forKey: deviceId)
            clearPQCProvider(for: deviceId)
        }
        if let pendingConnection = pendingConnections.removeValue(
            forKey: deviceId
        ) {
            pendingConnectionTimeoutTasks.removeValue(forKey: deviceId)?.cancel()
            pendingConnection.cancel()
        }
    }

    public func closeServerListener(for expectedRemoteDeviceId: String) {
        serverListeners.removeValue(forKey: expectedRemoteDeviceId)?.cancel()
    }

 /// 关闭所有连接
    public func closeAllConnections() {
        for connection in activeConnections.values {
            connection.cancel()
        }
        for connection in pendingConnections.values {
            connection.cancel()
        }
        for timeoutTask in pendingConnectionTimeoutTasks.values {
            timeoutTask.cancel()
        }
        for listener in serverListeners.values {
            listener.cancel()
        }
        activeConnections.removeAll()
        pendingConnections.removeAll()
        pendingConnectionTimeoutTasks.removeAll()
        serverListeners.removeAll()
        cryptoProfileByDeviceId.removeAll()
        identityContextByRemoteDeviceId.removeAll()
        pqcProviderByDeviceId.removeAll()
        hpkeProviderByDeviceId.removeAll()
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

    private func connectionIdentityContext(
        remoteDeviceId: String
    ) throws -> TLSConnectionIdentityContext {
        guard case .transport(let localDeviceId) = usage else {
            throw TLSSecurityError.transportIdentityUnavailable
        }
        return try TLSConnectionIdentityContext(
            localDeviceId: localDeviceId,
            remoteDeviceId: remoteDeviceId
        )
    }

    private func bind(
        identityContext: TLSConnectionIdentityContext,
        profile: CryptoProfile
    ) {
        identityContextByRemoteDeviceId[identityContext.remoteDeviceId]
            = identityContext
        cryptoProfileByDeviceId[identityContext.remoteDeviceId] = profile
    }

    private func requiredIdentityContext(
        for remoteDeviceId: String
    ) throws -> TLSConnectionIdentityContext {
        guard let context = identityContextByRemoteDeviceId[remoteDeviceId],
              context.remoteDeviceId == remoteDeviceId else {
            throw TLSSecurityError.connectionIdentityMissing(
                deviceId: remoteDeviceId
            )
        }
        return context
    }

    private func cryptoProfile(for deviceId: String) throws -> CryptoProfile {
        guard let profile = cryptoProfileByDeviceId[deviceId] else {
            throw TLSSecurityError.cryptoProfileMissing(deviceId: deviceId)
        }
        return profile
    }

    private func configurePQCProvider(for profile: CryptoProfile, deviceId: String, logPrefix: String) {
        clearPQCProvider(for: deviceId)

        switch profile {
        case .classicP256:
            return
        case .hybridXWing:
            guard let provider = PQCProviderFactory.makeHPKEProvider(for: .hybridXWing) else {
                SkyBridgeLogger.security.error(
                    "🔐 \(logPrefix) X-Wing HPKE Provider unavailable for selected profile \(profile.rawValue); PQC payloads will fail closed until suite evidence exists"
                )
                return
            }
            pqcProviderByDeviceId[deviceId] = provider
            hpkeProviderByDeviceId[deviceId] = provider
            SkyBridgeLogger.security.debugOnly("🔐 \(logPrefix) X-Wing HPKE Provider: \(String(describing: type(of: provider)))")
        case .pqcMlKemMlDsa:
            guard let provider = PQCProviderFactory.makeProvider(for: .pqcMlKemMlDsa) else {
                SkyBridgeLogger.security.error(
                    "🔐 \(logPrefix) PQC Provider unavailable for selected profile \(profile.rawValue); PQC payloads will fail closed until provider evidence exists"
                )
                return
            }
            pqcProviderByDeviceId[deviceId] = provider
            SkyBridgeLogger.security.debugOnly("🔐 \(logPrefix) PQC Provider: \(String(describing: type(of: provider)))")
        }
    }

    private func clearPQCProvider(for deviceId: String) {
        pqcProviderByDeviceId.removeValue(forKey: deviceId)
        hpkeProviderByDeviceId.removeValue(forKey: deviceId)
    }

    private func makeHybridXWingPayload(_ data: Data, recipientDeviceId: String) throws -> Data {
        let hp = try requireHPKEProvider(for: recipientDeviceId, operation: "send")
        let identityContext = try requiredIdentityContext(
            for: recipientDeviceId
        )
        let recipientPublicKey = try requiredAuthenticatedXWingRemotePublicKey(
            recipientDeviceId: identityContext.remoteDeviceId
        )
        let ctx = try hp.senderContext(recipientPublicKey: recipientPublicKey, suite: .hybridXWing)
        let aad = identityContext.outboundHybridAAD(
            profile: CryptoProfile.hybridXWing.rawValue
        )
        let sealed = try ctx.seal(data, authenticating: aad)
        var header = withUnsafeBytes(of: UInt32(sealed.encapsulatedKey.count).bigEndian) { Data($0) }
        header.append(sealed.encapsulatedKey)
        return header + sealed.ciphertext
    }

    private func openHybridXWingPayload(
        _ encryptedData: Data,
        identityContext: TLSConnectionIdentityContext
    ) throws -> Data {
        let hp = try requireHPKEProvider(
            for: identityContext.remoteDeviceId,
            operation: "receive"
        )
        guard encryptedData.count >= 4 else {
            throw TLSSecurityError.invalidDataFormat
        }

        let encapsulatedKeyLength = encryptedData.prefix(4).reduce(0) {
            ($0 << 8) | Int($1)
        }
        let totalNeeded = 4 + encapsulatedKeyLength
        guard encapsulatedKeyLength > 0,
              encryptedData.count >= totalNeeded else {
            throw TLSSecurityError.invalidDataFormat
        }

        var recipientPrivateKey = try requiredLocalXWingPrivateKey(
            localDeviceId: identityContext.localDeviceId
        )
        defer { PQCKeyPairRecordCodec.wipe(&recipientPrivateKey) }
        let encapsulatedKey = encryptedData.dropFirst(4).prefix(
            encapsulatedKeyLength
        )
        let ciphertext = encryptedData.dropFirst(totalNeeded)
        let ctx = try hp.recipientContext(
            recipientPrivateKey: recipientPrivateKey,
            suite: .hybridXWing,
            encapsulatedKey: Data(encapsulatedKey)
        )
        let aad = identityContext.inboundHybridAAD(
            profile: CryptoProfile.hybridXWing.rawValue
        )
        return try ctx.open(Data(ciphertext), authenticating: aad)
    }

    private func requireHPKEProvider(for deviceId: String, operation: String) throws -> PQCHPKEProvider {
        guard let hpkeProvider = hpkeProviderByDeviceId[deviceId] else {
            throw TLSSecurityError.pqcMaterialUnavailable(
                profile: CryptoProfile.hybridXWing.rawValue,
                operation: operation,
                reason: "missing_hpke_provider"
            )
        }
        return hpkeProvider
    }

    private func requiredAuthenticatedXWingRemotePublicKey(
        recipientDeviceId: String
    ) throws -> Data {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            guard let key = try XWingKeyMaterialStore
                .loadAuthenticatedRemotePublicKey(
                    peerId: recipientDeviceId,
                    authority: .active,
                    scopeSource: .requiredEntitlement
                ) else {
                throw TLSSecurityError.pqcMaterialUnavailable(
                    profile: CryptoProfile.hybridXWing.rawValue,
                    operation: "send",
                    reason: "missing_recipient_public_key"
                )
            }
            return key
        }
        #endif
        throw TLSSecurityError.pqcMaterialUnavailable(
            profile: CryptoProfile.hybridXWing.rawValue,
            operation: "send",
            reason: "apple_xwing_store_unavailable"
        )
    }

    private func requiredLocalXWingPrivateKey(
        localDeviceId: String
    ) throws -> Data {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            guard let key = try XWingKeyMaterialStore
                .loadLocalPrivateRepresentation(
                    peerId: localDeviceId,
                    authority: .active,
                    scopeSource: .requiredEntitlement
                ) else {
                throw TLSSecurityError.pqcMaterialUnavailable(
                    profile: CryptoProfile.hybridXWing.rawValue,
                    operation: "receive",
                    reason: "missing_recipient_private_key"
                )
            }
            return key
        }
        #endif
        throw TLSSecurityError.pqcMaterialUnavailable(
            profile: CryptoProfile.hybridXWing.rawValue,
            operation: "receive",
            reason: "apple_xwing_store_unavailable"
        )
    }

 /// 创建 TLS 1.3 选项（多版本兼容：macOS 14.x/15.x）
    private func createQuantumSecureTLSOptions(
        for mode: TLSMode,
        identityContext: TLSConnectionIdentityContext
    ) throws -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()

 // 使用sec_protocol_options配置TLS 1.3
        let secOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)

 // macOS 15+：保持 TLS 1.3 配置；传输层 PQC 协商必须由真实 negotiated group 证明。
        if #available(macOS 15.0, *) {
 // Apple 平台 TLS 可能具备 hybrid KEX 能力，但当前模块没有读取或强制设置
 // X25519+ML-KEM-768 negotiated group 的公开 API 证明。OS27 lane 只把
 // Network TLS hybrid KEX 作为 transport-only SDK 诊断，不作为 SkyBridge
 // 应用层 HPKE/X-Wing、PQC suite selection 或 release eligibility 证明。

 // 记录 TLS 1.3 配置，不把未证明的 TLS KEX 标成 PQC。
            SkyBridgeLogger.security.debugOnly("🔐 TLS 配置：TLS 1.3；传输层 PQC 协商未由本模块证明")

 // 未来实现：当 Apple 公开可 typecheck 的 TLS hybrid KEX 配置和 negotiated-group
 // metadata API 后，在 AppleTransport/TLS adapter 中接入并保留真实协商证据。
        } else {
 // macOS 14：使用经典 TLS 1.3 密码套件
            SkyBridgeLogger.security.debugOnly("🔐 TLS 配置：使用经典 TLS 1.3（macOS 14）")
        }

        switch mode {
        case .client:
 // 客户端配置
            guard let identity = try certificateManager.getIdentity(
                for: identityContext.localDeviceId
            ), CFGetTypeID(identity) == SecIdentityGetTypeID(),
            let secIdentity = sec_identity_create(identity) else {
                throw TLSSecurityError.localCertificateUnavailable
            }
            sec_protocol_options_set_local_identity(secOptions, secIdentity)
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
                    let result = self?.verifyCertificateChain(
                        trust,
                        for: identityContext.remoteDeviceId,
                        peerIsServer: true
                    ) ?? false
                    complete(result)
                }, .main)
            }

        case .server:
 // 服务器配置
            guard let identity = try certificateManager.getIdentity(
                for: identityContext.localDeviceId
            ), CFGetTypeID(identity) == SecIdentityGetTypeID(),
            let secIdentity = sec_identity_create(identity) else {
                throw TLSSecurityError.localCertificateUnavailable
            }
            sec_protocol_options_set_local_identity(secOptions, secIdentity)

            if tlsConfiguration.requireClientCertificate {
                sec_protocol_options_set_peer_authentication_required(
                    secOptions,
                    true
                )
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
                    let result = self?.verifyCertificateChain(
                        trust,
                        for: identityContext.remoteDeviceId,
                        peerIsServer: false
                    ) ?? false
                    complete(result)
                }, .main)
            }
        }

        return tlsOptions
    }

 /// 在证书验证完成前，连接只存在于 pending 集合；身份上下文和发送 API
 /// 只有在 Network.framework 报告 `.ready` 后才正式发布。
    @discardableResult
    private func registerPendingConnection(
        _ connection: NWConnection,
        identityContext: TLSConnectionIdentityContext,
        profile: CryptoProfile,
        logPrefix: String
    ) -> Bool {
        let deviceId = identityContext.remoteDeviceId
        guard activeConnections[deviceId] == nil,
              pendingConnections[deviceId] == nil else {
            return false
        }
        pendingConnections[deviceId] = connection
        schedulePendingConnectionTimeout(
            connection,
            deviceId: deviceId
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor in
                self?.handleConnectionStateChange(
                    state,
                    connection: connection,
                    identityContext: identityContext,
                    profile: profile,
                    logPrefix: logPrefix
                )
            }
        }
        return true
    }

    private func schedulePendingConnectionTimeout(
        _ connection: NWConnection,
        deviceId: String
    ) {
        let timeoutNanoseconds = UInt64(
            tlsConfiguration.connectionTimeout * 1_000_000_000
        )
        pendingConnectionTimeoutTasks[deviceId]?.cancel()
        pendingConnectionTimeoutTasks[deviceId] = Task { @MainActor [weak self, weak connection] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                SkyBridgeLogger.security.error(
                    "TLS pending timeout task failed: \(error.localizedDescription, privacy: .private)"
                )
                return
            }
            guard let self,
                  let connection,
                  self.pendingConnections[deviceId] === connection else {
                return
            }
            self.pendingConnections.removeValue(forKey: deviceId)
            self.pendingConnectionTimeoutTasks.removeValue(forKey: deviceId)
            self.tlsStatistics.errorCount += 1
            connection.cancel()
            SkyBridgeLogger.security.error(
                "TLS连接认证超时: \(deviceId, privacy: .private)"
            )
        }
    }

 /// 处理连接状态变化
    private func handleConnectionStateChange(
        _ state: NWConnection.State,
        connection: NWConnection,
        identityContext: TLSConnectionIdentityContext,
        profile: CryptoProfile,
        logPrefix: String
    ) {
        let deviceId = identityContext.remoteDeviceId
        switch state {
        case .ready:
            guard pendingConnections[deviceId] === connection else {
                connection.cancel()
                return
            }
            pendingConnections.removeValue(forKey: deviceId)
            pendingConnectionTimeoutTasks.removeValue(forKey: deviceId)?.cancel()
            activeConnections[deviceId] = connection
            bind(identityContext: identityContext, profile: profile)
            configurePQCProvider(
                for: profile,
                deviceId: deviceId,
                logPrefix: logPrefix
            )
            SkyBridgeLogger.security.debugOnly("✅ TLS连接就绪: \(deviceId)")
            tlsStatistics.connectionsEstablished += 1

 // 检测实际使用的算法（macOS 15+）
            if #available(macOS 15.0, *) {
                tlsStatistics.classicConnections += 1
                if profile == .classicP256 {
                    SkyBridgeLogger.security.debugOnly("   🔐 TLS transport profile: classicP256")
                } else {
                    SkyBridgeLogger.security.debugOnly(
                        "   🔐 TLS transport profile: \(profile.rawValue); app-layer PQC payloads require explicit HPKE material and are not counted as negotiated TLS PQC"
                    )
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
            removeConnectionState(
                connection,
                deviceId: deviceId
            )
            tlsStatistics.errorCount += 1

        case .cancelled:
            SkyBridgeLogger.security.debugOnly("⏹️ TLS连接已取消: \(deviceId)")
            removeConnectionState(
                connection,
                deviceId: deviceId
            )

        default:
            break
        }
    }

    private func removeConnectionState(
        _ connection: NWConnection,
        deviceId: String
    ) {
        if pendingConnections[deviceId] === connection {
            pendingConnections.removeValue(forKey: deviceId)
            pendingConnectionTimeoutTasks.removeValue(forKey: deviceId)?.cancel()
        }
        if activeConnections[deviceId] === connection {
            activeConnections.removeValue(forKey: deviceId)
            cryptoProfileByDeviceId.removeValue(forKey: deviceId)
            identityContextByRemoteDeviceId.removeValue(forKey: deviceId)
            clearPQCProvider(for: deviceId)
        }
    }

 /// 处理新连接
    private func handleNewConnection(
        _ connection: NWConnection,
        identityContext: TLSConnectionIdentityContext,
        profile: CryptoProfile
    ) {
        guard registerPendingConnection(
            connection,
            identityContext: identityContext,
            profile: profile,
            logPrefix: "Server"
        ) else {
            connection.cancel()
            SkyBridgeLogger.security.error(
                "拒绝重复的 TLS 入站身份绑定: \(identityContext.remoteDeviceId, privacy: .private)"
            )
            return
        }
        connection.start(queue: .global())
        SkyBridgeLogger.security.debugOnly("🔗 处理新TLS连接: \(identityContext.remoteDeviceId)")
    }

 /// 处理监听器状态变化
    private func handleListenerStateChange(
        _ state: NWListener.State,
        listener: NWListener,
        identityContext: TLSConnectionIdentityContext
    ) {
        let localDeviceId = identityContext.localDeviceId
        let remoteDeviceId = identityContext.remoteDeviceId
        switch state {
        case .ready:
            SkyBridgeLogger.security.debugOnly("✅ TLS监听器就绪: local=\(localDeviceId) expectedRemote=\(remoteDeviceId)")

        case .failed(let error):
            if serverListeners[remoteDeviceId] === listener {
                serverListeners.removeValue(forKey: remoteDeviceId)
            }
            SkyBridgeLogger.security.error("❌ TLS监听器失败: local=\(localDeviceId, privacy: .private) expectedRemote=\(remoteDeviceId, privacy: .private), 错误: \(error.localizedDescription, privacy: .private)")
            tlsStatistics.errorCount += 1

        case .cancelled:
            if serverListeners[remoteDeviceId] === listener {
                serverListeners.removeValue(forKey: remoteDeviceId)
            }
            SkyBridgeLogger.security.debugOnly("⏹️ TLS监听器已取消: local=\(localDeviceId) expectedRemote=\(remoteDeviceId)")

        default:
            break
        }
    }

 /// 验证证书链 - 证书固定、经典密钥强度与信任/有效期检查
    private func verifyCertificateChain(
        _ trust: sec_trust_t,
        for deviceId: String,
        peerIsServer: Bool
    ) -> Bool {
 // 将sec_trust_t转换为SecTrust
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

 // 1. 证书固定验证 - 检查证书指纹
        guard performCertificatePinning(secTrust, for: deviceId) else {
            SkyBridgeLogger.security.error("❌ 证书固定验证失败: \(deviceId, privacy: .private)")
            return false
        }

 // 2. 经典证书密钥强度下限检查；不把 P-256/ECDSA 证书标成 PQC 证明。
        guard validateClassicalCertificateKeyStrength(secTrust, for: deviceId) else {
            SkyBridgeLogger.security.error("❌ TLS证书经典密钥强度验证失败: \(deviceId, privacy: .private)")
            return false
        }

 // 3. 证书有效期和撤销状态检查
        guard validateCertificateValidity(
            secTrust,
            for: deviceId,
            peerIsServer: peerIsServer
        ) else {
            SkyBridgeLogger.security.error("❌ 证书有效性验证失败: \(deviceId, privacy: .private)")
            return false
        }

        SkyBridgeLogger.security.debugOnly("✅ 证书链验证成功: \(deviceId)")
        return true
    }

    /// 执行证书固定验证 - 只接受已授权 pin 或本地证书，不在握手回调中建立 TOFU 信任
    private func performCertificatePinning(_ trust: SecTrust, for deviceId: String) -> Bool {
 // 获取证书链中的叶子证书（使用新API）
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leafCertificate = chain.first else {
            SkyBridgeLogger.security.error("❌ 无法获取叶子证书")
            return false
        }

        return certificateManager.validateCertificate(leafCertificate, for: deviceId)
    }

    /// 验证经典 TLS 证书公钥强度下限；该检查不证明 PQC/quantum-safe 证书。
    private func validateClassicalCertificateKeyStrength(_ trust: SecTrust, for deviceId: String) -> Bool {
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

        guard let keyType = keyAttributes[kSecAttrKeyType as String] as? String,
              let keySize = keyAttributes[kSecAttrKeySizeInBits as String] as? Int else {
            SkyBridgeLogger.security.error("❌ TLS证书缺少公钥类型或位数")
            return false
        }

        switch keyType {
        case String(kSecAttrKeyTypeRSA):
 // RSA密钥至少需要3072位作为经典 TLS 兼容下限；不代表 PQC。
            guard keySize >= 3072 else {
                SkyBridgeLogger.security.error("❌ RSA密钥长度不足，需要至少3072位")
                return false
            }
        case String(kSecAttrKeyTypeECSECPrimeRandom):
 // ECC密钥至少需要256位（P-256）；不代表 PQC。
            guard keySize >= 256 else {
                SkyBridgeLogger.security.error("❌ ECC密钥长度不足，需要至少256位")
                return false
            }
        default:
            SkyBridgeLogger.security.error("❌ 不支持的TLS证书公钥类型")
            return false
        }

        return true
    }

 /// 验证证书有效性 - 检查有效期和撤销状态（OCSP）
 /// 在macOS 14+上，使用SecTrustEvaluateWithError并启用网络抓取，可触发系统级OCSP/CRL撤销检查。
    private func validateCertificateValidity(
        _ trust: SecTrust,
        for deviceId: String,
        peerIsServer: Bool
    ) -> Bool {
 // 设置SSL策略以确保使用服务器身份验证策略。
        let policy = SecPolicyCreateSSL(peerIsServer, nil)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else {
            SkyBridgeLogger.security.error("❌ 无法安装TLS证书验证策略")
            return false
        }

 // 如果证书链长度为1，则视为自签名P2P证书，跳过网络撤销检查但仍进行基本有效期验证。
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []

 // 启用网络抓取以允许系统尝试OCSP/CRL请求（非自签名时）。
        let allowsNetworkFetch = chain.count > 1
        guard SecTrustSetNetworkFetchAllowed(
            trust,
            allowsNetworkFetch
        ) == errSecSuccess else {
            SkyBridgeLogger.security.error("❌ 无法配置TLS证书撤销网络策略")
            return false
        }

 // 使用现代API进行评估；当启用网络抓取且存在撤销端点时，系统将自动进行OCSP检查。
        var evalError: CFError?
        let evaluationSucceeded = SecTrustEvaluateWithError(trust, &evalError)
        if !evaluationSucceeded {
            SkyBridgeLogger.security.error("❌ 证书评估失败: \(String(describing: evalError?.localizedDescription), privacy: .private)")
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
            guard evaluationSucceeded else {
                SkyBridgeLogger.security.error("❌ 证书评估未通过但返回了可接受结果: \(String(describing: result))")
                return false
            }
        case .recoverableTrustFailure:
 // 只有已 pin 的单证书本地 P2P 自签证书可以通过重新锚定验证；链不完整或未知自签名仍失败。
            guard validatePinnedSelfSignedLocalCertificateContract(
                trust,
                for: deviceId,
                peerIsServer: peerIsServer
            ) else {
                SkyBridgeLogger.security.error("❌ 可恢复证书信任失败未满足本地P2P自签pin约束: \(deviceId, privacy: .private)")
                return false
            }
            SkyBridgeLogger.security.debugOnly("✅ 已pin本地P2P自签证书通过重新锚定验证: \(deviceId)")
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

    private func validatePinnedSelfSignedLocalCertificateContract(
        _ trust: SecTrust,
        for deviceId: String,
        peerIsServer: Bool
    ) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              chain.count == 1,
              let leafCertificate = chain.first else {
            return false
        }

        guard isSelfSignedCertificate(leafCertificate) else {
            return false
        }

        guard certificateManager.validateCertificate(leafCertificate, for: deviceId) else {
            return false
        }

        let policy = SecPolicyCreateSSL(peerIsServer, nil)
        var pinnedTrust: SecTrust?
        guard SecTrustCreateWithCertificates(leafCertificate, policy, &pinnedTrust) == errSecSuccess,
              let pinnedTrust else {
            return false
        }

        guard SecTrustSetAnchorCertificates(pinnedTrust, [leafCertificate] as CFArray) == errSecSuccess else {
            return false
        }
        guard SecTrustSetAnchorCertificatesOnly(pinnedTrust, true) == errSecSuccess else {
            return false
        }
        guard SecTrustSetNetworkFetchAllowed(
            pinnedTrust,
            false
        ) == errSecSuccess else {
            return false
        }

        var evalError: CFError?
        guard SecTrustEvaluateWithError(pinnedTrust, &evalError) else {
            SkyBridgeLogger.security.error("❌ 已pin本地P2P自签证书重新锚定验证失败: \(String(describing: evalError?.localizedDescription), privacy: .private)")
            return false
        }

        var anchoredResult: SecTrustResultType = .invalid
        guard SecTrustGetTrustResult(pinnedTrust, &anchoredResult) == errSecSuccess else {
            return false
        }
        return anchoredResult == .unspecified || anchoredResult == .proceed
    }

    private func isSelfSignedCertificate(_ certificate: SecCertificate) -> Bool {
        guard let subject = certificateNameEntries(certificate, oid: kSecOIDX509V1SubjectName),
              let issuer = certificateNameEntries(certificate, oid: kSecOIDX509V1IssuerName),
              !subject.isEmpty else {
            return false
        }
        return subject == issuer
    }

    private func certificateNameEntries(_ certificate: SecCertificate, oid: CFString) -> [String]? {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [CFString: Any],
              let valueDict = values[oid] as? [CFString: Any],
              let entries = valueDict[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return nil
        }

        return entries.compactMap { entry in
            guard let label = entry[kSecPropertyKeyLabel] as? String,
                  let value = entry[kSecPropertyKeyValue] else {
                return nil
            }
            return "\(label)=\(String(describing: value))"
        }
    }

 /// C 字符串安全解码为 Swift 字符串（避免使用不推荐API）
    private func decodeCString(_ cstr: UnsafePointer<CChar>) -> String {
        return String(cString: cstr)
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
    ) throws {
        guard connectionTimeout.isFinite,
              (1...300).contains(connectionTimeout) else {
            throw TLSSecurityError.invalidConfiguration(
                reason: "connectionTimeout must be finite and within 1...300 seconds"
            )
        }
        guard keepaliveInterval.isFinite,
              (1...300).contains(keepaliveInterval) else {
            throw TLSSecurityError.invalidConfiguration(
                reason: "keepaliveInterval must be finite and within 1...300 seconds"
            )
        }
        guard !requireClientCertificate || enableCertificateVerification else {
            throw TLSSecurityError.invalidConfiguration(
                reason: "client-certificate authentication requires certificate verification"
            )
        }
        self.enableCertificateVerification = enableCertificateVerification
        self.requireClientCertificate = requireClientCertificate
        self.connectionTimeout = connectionTimeout
        self.keepaliveInterval = keepaliveInterval
    }

    private init(
        validatedEnableCertificateVerification: Bool,
        validatedRequireClientCertificate: Bool,
        validatedConnectionTimeout: TimeInterval,
        validatedKeepaliveInterval: TimeInterval
    ) {
        enableCertificateVerification = validatedEnableCertificateVerification
        requireClientCertificate = validatedRequireClientCertificate
        connectionTimeout = validatedConnectionTimeout
        keepaliveInterval = validatedKeepaliveInterval
    }

 /// 默认配置
    public static let `default` = TLSConfiguration(
        validatedEnableCertificateVerification: true,
        validatedRequireClientCertificate: false,
        validatedConnectionTimeout: 30,
        validatedKeepaliveInterval: 30
    )

 /// 高安全性配置
    public static let highSecurity = TLSConfiguration(
        validatedEnableCertificateVerification: true,
        validatedRequireClientCertificate: true,
        validatedConnectionTimeout: 15,
        validatedKeepaliveInterval: 15
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
public enum TLSSecurityError: Error, LocalizedError, Sendable {
    case connectionNotFound
    case certificateGenerationFailed
    case certificateValidationFailed
    case invalidDataFormat
    case connectionTimeout
    case tlsHandshakeFailed
    case localCertificateUnavailable
    case peerAuthenticationRequired
    case transportIdentityUnavailable
    case invalidConnectionIdentity
    case connectionIdentityMissing(deviceId: String)
    case connectionAlreadyExists
    case notStarted
    case noMutualCryptoProfile
    case invalidConfiguration(reason: String)
    case pqcMaterialUnavailable(profile: String, operation: String, reason: String)
    case cryptoProfileMissing(deviceId: String)

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
        case .localCertificateUnavailable:
            return "TLS服务器缺少与本机协议身份绑定的本地证书"
        case .peerAuthenticationRequired:
            return "TLS transport 身份绑定要求证书验证；未认证连接不能绑定远端设备身份"
        case .transportIdentityUnavailable:
            return "TLS transport manager 缺少协议身份 authority；certificate-only 实例不能创建连接"
        case .invalidConnectionIdentity:
            return "TLS连接的本机或远端协议身份无效"
        case .connectionIdentityMissing:
            return "TLS连接缺少已认证的本机/远端身份绑定"
        case .connectionAlreadyExists:
            return "同一远端设备已有 pending 或 active TLS 连接"
        case .notStarted:
            return "TLS security manager 尚未启动"
        case .noMutualCryptoProfile:
            return "对端提供的应用层加密 profile 与本机没有交集"
        case .invalidConfiguration(let reason):
            return "TLS配置无效: \(reason)"
        case .pqcMaterialUnavailable(let profile, let operation, let reason):
            return "PQC TLS材料不可用: profile=\(profile) operation=\(operation) reason=\(reason)"
        case .cryptoProfileMissing:
            return "TLS连接缺少已协商的加密 profile"
        }
    }
}

// MARK: - 证书管理器

/// 证书管理器 - 负责证书生成与严格的身份存储事务
private final class CertificateManager {
    private let keychainStore = TLSCertificateKeychainStore()

 /// 获取设备证书
    func getCertificate(for deviceId: String) throws -> SecCertificate? {
        try keychainStore.identity(for: deviceId)?.certificate
    }

 /// 获取设备身份
    func getIdentity(for deviceId: String) throws -> SecIdentity? {
        try keychainStore.identity(for: deviceId)?.identity
    }

    /// 验证证书
    func validateCertificate(_ certificate: SecCertificate, for deviceId: String) -> Bool {
        do {
            guard let known = try keychainStore.identity(for: deviceId) else {
                SkyBridgeLogger.security.error(
                    "❌ 缺少 canonical TLS certificate，拒绝隐式信任: \(deviceId, privacy: .private)"
                )
                return false
            }
            let matches = SecCertificateCopyData(known.certificate) as Data
                == SecCertificateCopyData(certificate) as Data
            if !matches {
                SkyBridgeLogger.security.error(
                    "❌ TLS certificate 与 canonical identity 不匹配: \(deviceId, privacy: .private)"
                )
            }
            return matches
        } catch {
            SkyBridgeLogger.security.error(
                "❌ TLS certificate pinning storage validation failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

 /// 生成自签名证书
    func generateSelfSignedCertificate(for deviceId: String) throws -> SecCertificate {
        let record = try keychainStore.getOrCreateIdentity(for: deviceId) {
            try self.makeSelfSignedCandidate(deviceId: deviceId)
        }
        return record.certificate
    }

    private func makeSelfSignedCandidate(
        deviceId: String
    ) throws -> TLSCertificateCandidate {
 // 生成内存中的 P‑256 candidate；持久化只允许经 create-only 事务完成。
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        var err: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            keyAttrs as CFDictionary,
            &err
        ) else {
            throw TLSCertificateLifecycleError.keyGenerationFailed
        }

        let certificateDER: Data
        do {
            let now = Date()
            certificateDER = try TLSSelfSignedCertificateBuilder
                .buildCertificateDER(
                    privateKey: privateKey,
                    subject: .init(
                        commonName: "SkyBridge Device \(deviceId)",
                        organization: "SkyBridge",
                        organizationalUnit: "Devices"
                    ),
                    serialNumber: try TLSSelfSignedCertificateBuilder
                        .randomSerialNumber(),
                    notBefore: now.addingTimeInterval(-3_600),
                    notAfter: now.addingTimeInterval(365 * 24 * 3_600)
                )
        } catch {
            throw TLSCertificateLifecycleError.certificateGenerationFailed
        }

        guard let certificate = SecCertificateCreateWithData(
            nil,
            certificateDER as CFData
        ) else {
            throw TLSCertificateLifecycleError.certificateGenerationFailed
        }
        return TLSCertificateCandidate(
            certificate: certificate,
            privateKey: privateKey
        )
    }

 /// 以内存隔离方式解析 PKCS#12，再通过同一 create-only 事务持久化。
    func importIdentityFromPKCS12(
        _ p12Data: Data,
        password: String,
        for deviceId: String
    ) throws {
        _ = try TLSCertificateKeychainStore.validatedDeviceId(deviceId)
        guard !p12Data.isEmpty,
              p12Data.count <= TLSCertificateLifecycleLimits.maximumPKCS12Bytes else {
            throw TLSCertificateLifecycleError.invalidPKCS12Input(
                reason: "PKCS#12 payload must contain 1...\(TLSCertificateLifecycleLimits.maximumPKCS12Bytes) bytes"
            )
        }
        guard password.utf8.count
                <= TLSCertificateLifecycleLimits.maximumPKCS12PasswordUTF8Bytes else {
            throw TLSCertificateLifecycleError.invalidPKCS12Input(
                reason: "PKCS#12 password exceeds the UTF-8 size limit"
            )
        }
        var options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        #if os(macOS)
        guard #available(macOS 15.0, *) else {
            throw TLSCertificateLifecycleError.memoryOnlyPKCS12ImportUnavailable
        }
        options[kSecImportToMemoryOnly as String] = true
        #elseif !os(iOS)
        throw TLSCertificateLifecycleError.memoryOnlyPKCS12ImportUnavailable
        #endif

        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw TLSCertificateLifecycleError.pkcs12ImportFailed(status: status)
        }
        guard let array = items as? [[String: Any]] else {
            throw TLSCertificateLifecycleError.invalidPKCS12Container(
                identityCount: 0
            )
        }
        let identities = array.compactMap { item -> SecIdentity? in
            guard let value = item[kSecImportItemIdentity as String],
                  CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
                return nil
            }
            return unsafeDowncast(value as AnyObject, to: SecIdentity.self)
        }
        guard array.count == 1,
              identities.count == 1,
              let identity = identities.first else {
            throw TLSCertificateLifecycleError.invalidPKCS12Container(
                identityCount: identities.count
            )
        }

        var certificate: SecCertificate?
        var privateKey: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey else {
            throw TLSCertificateLifecycleError.candidateIdentityInvalid
        }
        _ = try keychainStore.importIdentity(
            TLSCertificateCandidate(
                certificate: certificate,
                privateKey: privateKey
            ),
            for: deviceId
        )
    }

 /// 生成 PKCS#10 CSR（DER 编码）
    func generateCSRPEM(
        for deviceId: String,
        commonName: String,
        organization: String?,
        organizationalUnit: String?,
        sanDNS: [String],
        sanIP: [String]
    ) throws -> String {
        guard let identity = try getIdentity(for: deviceId) else {
            throw TLSCertificateLifecycleError.identityUnavailable
        }
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey else {
            throw TLSCertificateLifecycleError.csrGenerationFailed
        }
        let der: Data
        do {
            der = try TLSCertificateSigningRequestBuilder.buildDER(
                commonName: commonName,
                organization: organization,
                organizationalUnit: organizationalUnit,
                sanDNS: sanDNS,
                sanIP: sanIP,
                privateKey: privateKey
            )
        } catch let error as TLSCertificateSigningRequestBuilder.BuildError {
            switch error {
            case .invalidSubject:
                throw TLSCertificateLifecycleError.invalidCSRInput(
                    reason: "subject CN/O/OU is empty, aliased, or unbounded"
                )
            case .invalidDNSName:
                throw TLSCertificateLifecycleError.invalidCSRInput(
                    reason: "subjectAltName contains an invalid DNS name"
                )
            case .invalidIPAddress:
                throw TLSCertificateLifecycleError.invalidCSRInput(
                    reason: "subjectAltName contains an invalid IP address"
                )
            case .invalidPrivateKey, .signingFailed:
                throw TLSCertificateLifecycleError.csrGenerationFailed
            }
        }
        let body = der.base64EncodedString(
            options: [.lineLength64Characters, .endLineWithLineFeed]
        )
        return "-----BEGIN CERTIFICATE REQUEST-----\n"
            + body
            + "\n-----END CERTIFICATE REQUEST-----\n"
    }

}

public enum CAServiceError: Error, LocalizedError, Sendable, Equatable {
    case invalidHTTPSEndpoint
    case invalidCSR
    case invalidRequestId
    case unexpectedHTTPStatus(Int)
    case responseTooLarge(maximumBytes: Int)
    case invalidUTF8Response
    case invalidResponseBody

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPSEndpoint:
            return "CA endpoint must be an HTTPS URL without credentials or a fragment"
        case .invalidCSR:
            return "CA request does not contain one bounded PKCS#10 PEM document"
        case .invalidRequestId:
            return "CA request ID is empty, unbounded, or contains whitespace/control aliases"
        case .unexpectedHTTPStatus(let status):
            return "CA returned unexpected HTTP status \(status)"
        case .responseTooLarge(let maximumBytes):
            return "CA response exceeds the \(maximumBytes)-byte limit"
        case .invalidUTF8Response:
            return "CA response is not valid UTF-8"
        case .invalidResponseBody:
            return "CA response does not match the explicit request-id/pending/certificate contract"
        }
    }
}

/// Minimal HTTPS CA client. It validates response syntax explicitly and never
/// turns malformed data into a synthetic request ID or a successful pending state.
public final class CAServiceManager {
    private static let maximumCSRBytes = 1_048_576
    private static let maximumRequestIdBytes = 512
    private static let maximumCertificateResponseBytes = 2_097_152
    private let session: URLSession

    public init() {
        session = .shared
    }

    init(session: URLSession) {
        self.session = session
    }

    /// Submit one PKCS#10 CSR. A successful response must be one strict,
    /// nonempty opaque request ID; malformed UTF-8 never becomes a UUID fallback.
    public func submitCSR(_ csrPEM: String, to endpoint: URL) async throws -> String {
        let endpoint = try Self.validatedEndpoint(endpoint)
        let csrData = try Self.validatedCSRData(csrPEM)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(
            "application/x-pem-file",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = csrData
        let (data, response) = try await session.data(for: request)
        try Self.validate(
            response: response,
            maximumBytes: Self.maximumRequestIdBytes,
            actualBytes: data.count
        )
        guard let rawRequestId = String(data: data, encoding: .utf8) else {
            throw CAServiceError.invalidUTF8Response
        }
        return try Self.validatedRequestId(rawRequestId)
    }

    /// Polling accepts exactly `pending` or one parseable certificate PEM.
    public func pollCertificateStatus(
        requestId: String,
        from endpoint: URL
    ) async throws -> (issued: Bool, pem: String?) {
        let requestId = try Self.validatedRequestId(requestId)
        let endpoint = try Self.validatedEndpoint(endpoint)
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "requestId" }
        queryItems.append(URLQueryItem(name: "requestId", value: requestId))
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw CAServiceError.invalidHTTPSEndpoint
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try Self.validate(
            response: response,
            maximumBytes: Self.maximumCertificateResponseBytes,
            actualBytes: data.count
        )
        guard let body = String(data: data, encoding: .utf8) else {
            throw CAServiceError.invalidUTF8Response
        }
        return try Self.parsePollingResponse(body)
    }

    static func validatedEndpoint(_ endpoint: URL) throws -> URL {
        guard let components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ),
        components.scheme?.lowercased() == "https",
        let host = components.host,
        !host.isEmpty,
        components.user == nil,
        components.password == nil,
        components.fragment == nil else {
            throw CAServiceError.invalidHTTPSEndpoint
        }
        return endpoint
    }

    static func validatedRequestId(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw == trimmed,
              !raw.isEmpty,
              raw.utf8.count <= maximumRequestIdBytes,
              raw.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CAServiceError.invalidRequestId
        }
        return raw
    }

    static func validatedCSRData(_ pem: String) throws -> Data {
        let encoded = Data(pem.utf8)
        guard !encoded.isEmpty,
              encoded.count <= maximumCSRBytes,
              pem.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      || scalar.value == 0x0A
                      || scalar.value == 0x0D
              }) else {
            throw CAServiceError.invalidCSR
        }

        let lineNormalized = pem.replacingOccurrences(of: "\r\n", with: "\n")
        guard !lineNormalized.contains("\r") else {
            throw CAServiceError.invalidCSR
        }
        let normalized = lineNormalized.hasSuffix("\n")
            ? String(lineNormalized.dropLast())
            : lineNormalized
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count >= 3,
              lines.first == "-----BEGIN CERTIFICATE REQUEST-----",
              lines.last == "-----END CERTIFICATE REQUEST-----" else {
            throw CAServiceError.invalidCSR
        }
        let base64Lines = lines.dropFirst().dropLast()
        guard base64Lines.allSatisfy({ !$0.isEmpty }),
              let der = Data(
                  base64Encoded: base64Lines.joined(),
                  options: []
              ),
              !der.isEmpty else {
            throw CAServiceError.invalidCSR
        }
        return encoded
    }

    static func parsePollingResponse(
        _ body: String
    ) throws -> (issued: Bool, pem: String?) {
        if body == "pending" {
            return (false, nil)
        }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r"),
              normalized.hasPrefix(begin),
              normalized.hasSuffix(end)
                || normalized.hasSuffix(end + "\n") else {
            throw CAServiceError.invalidResponseBody
        }
        let base64 = normalized
            .split(whereSeparator: \Character.isNewline)
            .filter { !$0.hasPrefix("---") }
            .joined()
        guard let der = Data(base64Encoded: String(base64)),
              SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw CAServiceError.invalidResponseBody
        }
        return (true, body)
    }

    private static func validate(
        response: URLResponse,
        maximumBytes: Int,
        actualBytes: Int
    ) throws {
        guard actualBytes <= maximumBytes else {
            throw CAServiceError.responseTooLarge(
                maximumBytes: maximumBytes
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw CAServiceError.invalidResponseBody
        }
        _ = try validatedEndpoint(try requiredResponseURL(http.url))
        guard (200...299).contains(http.statusCode) else {
            throw CAServiceError.unexpectedHTTPStatus(http.statusCode)
        }
    }

    private static func requiredResponseURL(_ url: URL?) throws -> URL {
        guard let url else { throw CAServiceError.invalidHTTPSEndpoint }
        return url
    }

 /// Issued certificates cannot bypass private-key matching or rotation policy.
        public func importIssuedCertificate(
            _ pem: String,
            for deviceId: String
        ) throws {
            _ = pem
            _ = try TLSCertificateKeychainStore.validatedDeviceId(deviceId)
            throw TLSCertificateLifecycleError.issuedCertificateImportUnavailable
        }
}
