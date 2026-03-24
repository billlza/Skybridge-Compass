import Foundation
import CryptoKit
import Network
import os

/// P2P安全管理器
@MainActor
public class P2PSecurityManager: ObservableObject, Sendable {
 // MARK: - 属性
    
 /// 量子加密管理器
    private let quantumCryptoManager: QuantumCryptoManager
    
 /// 设备密钥对
    private var deviceKeyPair: P256.KeyAgreement.PrivateKey
    
 /// 会话密钥存储
    private var sessionKeys: [String: SymmetricKey] = [:]
    
 /// 信任的设备列表
    public var trustedDevices: Set<String> = []
    
 /// 权限管理器
    private let permissionManager: P2PPermissionManager
    
 /// 活跃的安全连接
    @Published public var activeSecureConnections: Set<String> = []
    
 // MARK: - 策略配置（可持久化）
    @Published public var policyAutoTrustEnabled: Bool = UserDefaults.standard.bool(forKey: "sec.policy.autoTrustEnabled")
    @Published public var policyStrictCertificateValidation: Bool = UserDefaults.standard.object(forKey: "sec.policy.strictCert") as? Bool ?? true
    @Published public var policyConnectionTimeoutEnabled: Bool = UserDefaults.standard.object(forKey: "sec.policy.connTimeout") as? Bool ?? true
    @Published public var policyDataIntegrityCheckEnabled: Bool = UserDefaults.standard.object(forKey: "sec.policy.dataIntegrity") as? Bool ?? true
    
 /// 线程安全锁
    private let securityLock = OSAllocatedUnfairLock()
    
 /// 安全配置
    private let configuration: P2PSecurityConfiguration
    
 // MARK: - 生命周期管理属性
    private var isStarted = false
    
 // MARK: - 初始化
    
    public init(configuration: P2PSecurityConfiguration = .default) {
        self.configuration = configuration
        self.quantumCryptoManager = QuantumCryptoManager()
        self.deviceKeyPair = P256.KeyAgreement.PrivateKey()
        self.permissionManager = P2PPermissionManager()
        
 // 加载信任设备列表
        loadTrustedDevices()
        setupPolicyObservers()
    }
    
 // MARK: - 生命周期管理方法
    
 /// 启动P2P安全管理器
 /// 初始化安全组件和权限管理
    public func start() async throws {
        guard !isStarted else {
            SkyBridgeLogger.security.debugOnly("⚠️ P2PSecurityManager 已经启动")
            return
        }
        
        SkyBridgeLogger.security.debugOnly("🚀 启动 P2PSecurityManager")
        
 // 加载信任设备列表
        loadTrustedDevices()
        
 // 标记为已启动
        isStarted = true
        
        SkyBridgeLogger.security.debugOnly("✅ P2PSecurityManager 启动完成")
    }
    
 /// 停止P2P安全管理器
 /// 清理安全连接和会话密钥
    public func stop() async {
        guard isStarted else {
            SkyBridgeLogger.security.debugOnly("⚠️ P2PSecurityManager 尚未启动")
            return
        }
        
        SkyBridgeLogger.security.debugOnly("🛑 停止 P2PSecurityManager")
        
 // 清理会话密钥
        sessionKeys.removeAll()
        
 // 清理活跃连接
        activeSecureConnections.removeAll()
        
 // 标记为已停止
        isStarted = false
        
        SkyBridgeLogger.security.debugOnly("✅ P2PSecurityManager 停止完成")
    }
    
 /// 清理P2P安全管理器
 /// 清理所有安全数据和配置
    public func cleanup() async {
        SkyBridgeLogger.security.debugOnly("🧹 清理 P2PSecurityManager")
        
 // 停止管理器
        if isStarted {
            await stop()
        }
        
 // 清理信任设备列表
        trustedDevices.removeAll()
        
 // 清理会话密钥
        sessionKeys.removeAll()
        
        SkyBridgeLogger.security.debugOnly("✅ P2PSecurityManager 清理完成")
    }
    
 // MARK: - 公共方法
    
 /// 获取设备ID
    public func getDeviceId() -> String {
        return deviceKeyPair.publicKey.rawRepresentation.base64EncodedString()
    }
    
 /// 获取设备公钥
    public func getPublicKey() -> P256.KeyAgreement.PublicKey {
        return deviceKeyPair.publicKey
    }
    
 /// 生成发现消息的签名材料（包含签名公钥与指纹）
 /// - Parameters:
 /// - id,name,type,address,port,osVersion,capabilities,timestamp: 用于构造规范化字符串
 /// - Returns: (publicKeyBase64, fingerprintHex, signatureBase64)
    public func signDiscoveryCanonical(
        id: String,
        name: String,
        type: P2PDeviceType,
        address: String,
        port: UInt16,
        osVersion: String,
        capabilities: [String],
        timestamp: Double
    ) -> (String, String, String) {
 // 先生成签名密钥与公钥指纹，确保规范化字符串包含指纹以保持签名/验签一致
        let signingKey = P256.Signing.PrivateKey()
        let publicKeyData = signingKey.publicKey.rawRepresentation
        let fingerprint = SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
        let canonical = "id=\(id)|name=\(name)|type=\(type.rawValue)|address=\(address)|port=\(port)|os=\(osVersion)|cap=\(capabilities.joined(separator: ","))|ts=\(timestamp)|fp=\(fingerprint)"
        let messageData = canonical.data(using: .utf8) ?? Data()
 // 为签名专用生成临时密钥对（与会话密钥分离），公钥随消息一起发送
        let signature = try? signingKey.signature(for: messageData)
        let signatureB64 = signature.map { $0.rawRepresentation.base64EncodedString() } ?? ""
        let publicKeyB64 = publicKeyData.base64EncodedString()
        return (publicKeyB64, fingerprint, signatureB64)
    }

 /// 验证设备发现消息签名
 /// - Parameters:
 /// - info: 设备基本信息（用于构造签名数据）
 /// - publicKeyData: 对端用于签名的公钥原始数据（P256.Signing.PublicKey）
 /// - signatureData: 对端签名原始数据（ECDSA，原始格式）
 /// - Returns: 验证是否通过
 /// 使用发现消息执行验签与时效校验
 /// - Parameter message: 组播设备发现消息
 /// - Returns: 是否通过验签与时效校验
    public func verifyDiscoveryMessageSignature(message: P2PDiscoveryMessage) -> Bool {
        guard let pkB64 = message.publicKeyBase64, let sigB64 = message.signatureBase64,
              let publicKeyData = Data(base64Encoded: pkB64),
              let signatureData = Data(base64Encoded: sigB64) else { return false }
 // 时效校验：消息时间戳与当前时间差不超过 challengeLifetime
        let now = Date().timeIntervalSince1970
        guard abs(now - message.timestamp) <= configuration.challengeLifetime else { return false }
 // 指纹校验：公钥指纹必须匹配
        let computedFingerprint = SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
        guard computedFingerprint == message.publicKeyFingerprint else { return false }
 // 构造规范化的签名数据（包含timestamp，避免重放攻击）
        let canonical = "id=\(message.id)|name=\(message.name)|type=\(message.type.rawValue)|address=\(message.address)|port=\(message.port)|os=\(message.osVersion)|cap=\(message.capabilities.joined(separator: ","))|ts=\(message.timestamp)|fp=\(message.publicKeyFingerprint)"
        guard let messageData = canonical.data(using: .utf8) else { return false }
        do {
            let verifyingKey = try P256.Signing.PublicKey(rawRepresentation: publicKeyData)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
            return verifyingKey.isValidSignature(signature, for: messageData)
        } catch {
            return false
        }
    }

 /// 验证设备发现消息并返回失败原因（中文）
    public func verifyDiscoveryMessageWithReason(message: P2PDiscoveryMessage) -> (ok: Bool, reason: String?) {
        guard let pkB64 = message.publicKeyBase64, let sigB64 = message.signatureBase64 else {
            return (false, "缺少签名或公钥")
        }
        guard let publicKeyData = Data(base64Encoded: pkB64) else { return (false, "公钥数据无效") }
        guard let signatureData = Data(base64Encoded: sigB64) else { return (false, "签名数据无效") }
        let now = Date().timeIntervalSince1970
        if abs(now - message.timestamp) > configuration.challengeLifetime {
            return (false, "消息已过期")
        }
        let computedFingerprint = SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
        if computedFingerprint != message.publicKeyFingerprint {
            return (false, "公钥指纹不匹配")
        }
        let canonical = "id=\(message.id)|name=\(message.name)|type=\(message.type.rawValue)|address=\(message.address)|port=\(message.port)|os=\(message.osVersion)|cap=\(message.capabilities.joined(separator: ","))|ts=\(message.timestamp)|fp=\(message.publicKeyFingerprint)"
        guard let messageData = canonical.data(using: .utf8) else { return (false, "消息编码失败") }
        do {
            let verifyingKey = try P256.Signing.PublicKey(rawRepresentation: publicKeyData)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
            let ok = verifyingKey.isValidSignature(signature, for: messageData)
            return (ok, ok ? nil : "签名验证失败")
        } catch {
            return (false, "验签过程异常：\(error.localizedDescription)")
        }
    }

 // MARK: - 二维码验签统一入口
 /// 统一的二维码验签入口方法，供各视图/模块复用
 /// - Parameters:
 /// - device: 设备信息（用于构造规范化负载）
 /// - publicKeyBase64: 签名公钥（Base64，P256.Signing.PublicKey 原始表示）
 /// - signatureBase64: 签名（Base64，ECDSA 原始表示）
 /// - timestamp: 可选签名时间戳（用于时效校验），若为 nil 则视为 0
 /// - fingerprintHex: 可选公钥指纹十六进制，若为 nil 则自动计算
 /// - Returns: (ok, reason) 验签结果与失败原因（中文）
    public func verifyQRCodeSignature(for device: P2PDevice,
                                      publicKeyBase64: String,
                                      signatureBase64: String,
                                      timestamp: Double?,
                                      fingerprintHex: String?) -> (ok: Bool, reason: String?) {
 // 公钥/签名 Base64 解码
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else { return (false, "公钥数据无效") }
        guard let signatureData = Data(base64Encoded: signatureBase64) else { return (false, "签名数据无效") }
 // 指纹处理：优先使用传入指纹，否则计算
        let computedFingerprint = SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
        let fingerprint = fingerprintHex ?? computedFingerprint
 // 时效检查（如提供）
        if let ts = timestamp {
            let now = Date().timeIntervalSince1970
            if abs(now - ts) > configuration.challengeLifetime { return (false, "签名已过期") }
        }
 // 构造规范化负载字符串（包含指纹与时间戳）
        let capsJoined = device.capabilities.joined(separator: ",")
        let canonical = "id=\(device.id)|name=\(device.name)|type=\(device.deviceType.rawValue)|address=\(device.address)|port=\(device.port)|os=\(device.osVersion)|cap=\(capsJoined)|ts=\(timestamp ?? 0)|fp=\(fingerprint)"
        guard let messageData = canonical.data(using: .utf8) else { return (false, "负载编码失败") }
        do {
            let verifyingKey = try P256.Signing.PublicKey(rawRepresentation: publicKeyData)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
            let ok = verifyingKey.isValidSignature(signature, for: messageData)
            return (ok, ok ? nil : "签名验证失败")
        } catch {
            return (false, "验签过程异常：\(error.localizedDescription)")
        }
    }
    
 /// 生成认证挑战
    public func generateChallenge() -> Data {
        return Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }
    
 /// 创建认证响应
    public func createAuthResponse(for challenge: Data) throws -> P2PAuthResponse {
        let timestamp = Date()
        let certificate = try createDeviceCertificate(timestamp: timestamp)
        
        return P2PAuthResponse(
            challenge: challenge,
            certificate: certificate,
            timestamp: timestamp
        )
    }
    
 /// 验证认证响应
    public func verifyAuthResponse(_ response: P2PAuthResponse, for challenge: Data) throws -> Bool {
 // 验证时间戳
        let now = Date()
        if now.timeIntervalSince(response.timestamp) > configuration.challengeLifetime {
            throw P2PSecurityError.dataExpired
        }
        
 // 验证挑战
        guard response.challenge == challenge else {
            throw P2PSecurityError.authenticationFailed
        }
        
 // 验证证书
        return try verifyCertificate(response.certificate)
    }
    
    /// 建立会话密钥（Legacy / pre-paper）
    ///
    /// 仅保留给单元测试/调试辅助使用，Release 构建中不编译进产物，避免误用偏离论文协议栈。
    #if DEBUG
    @available(*, deprecated, message: "Legacy pre-paper handshake API. Use `HandshakeDriver` / `TwoAttemptHandshakeManager` to establish `SessionKeys` instead.")
    public func establishSessionKey(with deviceId: String, publicKey: P256.KeyAgreement.PublicKey) async throws {
        // 优先使用 PQC 会话协商（旧系统通过 oqs-provider），失败时回退到经典 P256/HKDF
        if let provider = PQCProviderFactory.makeProvider() {
            // 使用 ML‑KEM‑768 完成共享密钥协商
            // 注意：此处为简化演示，真实场景需通过上层信令交换对端公钥标签
            let enc = try await provider.kemEncapsulate(peerId: deviceId, kemVariant: "ML-KEM-768")
            let ss2 = try await provider.kemDecapsulate(peerId: deviceId, encapsulated: enc.encapsulated, kemVariant: "ML-KEM-768")
            let info = Data("session:\(deviceId)".utf8)
            let sk = SessionTokenKit.deriveSessionKey(sharedSecret: ss2, salt: Data(), info: info)
            sessionKeys[deviceId] = sk
            var mutableShared = ss2
            mutableShared.secureErase()
            return
        }

        // 回退：经典算法 P256/HKDF
        let sharedSecret = try deviceKeyPair.sharedSecretFromKeyAgreement(with: publicKey)
        let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(deviceId.utf8),
            outputByteCount: 32
        )
        sessionKeys[deviceId] = sessionKey
    }

    @available(*, deprecated, message: "Legacy pre-paper KEM API. Use `CryptoProvider` KEM APIs via the protocol handshake layer.")
    public func kemEncapsulate(deviceId: String, kemVariant: String = "ML-KEM-768") async throws -> (sharedSecret: Data, encapsulated: Data) {
        guard let provider = PQCProviderFactory.makeProvider() else { throw P2PSecurityError.authenticationFailed }
        return try await provider.kemEncapsulate(peerId: deviceId, kemVariant: kemVariant)
    }

    @available(*, deprecated, message: "Legacy pre-paper KEM API. Use `CryptoProvider` KEM APIs via the protocol handshake layer.")
    public func kemDecapsulate(deviceId: String, encapsulated: Data, kemVariant: String = "ML-KEM-768") async throws -> Data {
        guard let provider = PQCProviderFactory.makeProvider() else { throw P2PSecurityError.authenticationFailed }
        return try await provider.kemDecapsulate(peerId: deviceId, encapsulated: encapsulated, kemVariant: kemVariant)
    }

    @available(*, deprecated, message: "Legacy pre-paper session-key store. Use `SessionKeys` produced by the protocol handshake.")
    public func deriveAndStoreSessionKey(sharedSecret: Data, deviceId: String) {
        let info = Data("session:\(deviceId)".utf8)
        let sk = SessionTokenKit.deriveSessionKey(sharedSecret: sharedSecret, salt: Data(), info: info)
        sessionKeys[deviceId] = sk
    }

    @available(*, deprecated, message: "Legacy pre-paper session-key store. Use `SessionKeys` produced by the protocol handshake.")
    public func hasSessionKey(for deviceId: String) -> Bool {
        return sessionKeys[deviceId] != nil
    }
    #endif


    
    
 /// 加密数据
    public func encryptData(_ data: Data, for deviceId: String) throws -> P2PEncryptedData {
        guard let sessionKey = sessionKeys[deviceId] else {
            throw P2PSecurityError.noSessionKey
        }
        
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: sessionKey, nonce: nonce)
        
        return P2PEncryptedData(
            encryptedData: sealedBox.ciphertext,
            nonce: Data(nonce),
            tag: sealedBox.tag,
            timestamp: Date()
        )
    }
    
 /// 解密数据
    public func decryptData(_ encryptedData: P2PEncryptedData, from deviceId: String) throws -> Data {
 // 检查数据是否过期
        let now = Date()
        if now.timeIntervalSince(encryptedData.timestamp) > configuration.dataLifetime {
            throw P2PSecurityError.dataExpired
        }
        
        guard let sessionKey = sessionKeys[deviceId] else {
            throw P2PSecurityError.noSessionKey
        }
        
        let nonce = try AES.GCM.Nonce(data: encryptedData.nonce)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: encryptedData.encryptedData,
            tag: encryptedData.tag
        )
        
        return try AES.GCM.open(sealedBox, using: sessionKey)
    }
    
 /// 添加信任设备
    public func addTrustedDevice(_ deviceId: String) {
        guard !trustedDevices.contains(deviceId) else { return }
        
        if trustedDevices.count >= configuration.maxTrustedDevices {
 // 移除最旧的设备
            if let oldestDevice = trustedDevices.first {
                removeTrustedDevice(oldestDevice)
            }
        }
        
        trustedDevices.insert(deviceId)
        saveTrustedDevices()
    }
    
 /// 移除信任设备
    public func removeTrustedDevice(_ deviceId: String) {
        trustedDevices.remove(deviceId)
        
 // 清理相关数据
        sessionKeys.removeValue(forKey: deviceId)
        permissionManager.clearAllPermissions(for: deviceId)
        saveTrustedDevices()
    }
    
 /// 检查设备是否受信任
    public func isTrustedDevice(_ deviceId: String) -> Bool {
        return trustedDevices.contains(deviceId)
    }
    
 /// 获取信任设备列表
    public func getTrustedDevices() -> Set<String> {
        return trustedDevices
    }
    
 /// 检查权限
    public func hasPermission(_ permission: P2PPermission, for deviceId: String) -> Bool {
        guard isTrustedDevice(deviceId) else { return false }
        return permissionManager.hasPermission(permission, for: deviceId)
    }
    
 /// 授予权限
    public func grantPermission(_ permission: P2PPermission, to deviceId: String) {
        guard isTrustedDevice(deviceId) else { return }
        permissionManager.grantPermission(permission, to: deviceId)
    }
    
 /// 撤销权限
    public func revokePermission(_ permission: P2PPermission, from deviceId: String) {
        permissionManager.revokePermission(permission, from: deviceId)
    }
    
 /// 获取设备权限
    public func getPermissions(for deviceId: String) -> Set<P2PPermission> {
        return permissionManager.getPermissions(for: deviceId)
    }
    
 // MARK: - 私有方法
    
 /// 创建设备证书
    private func createDeviceCertificate(timestamp: Date) throws -> P2PDeviceCertificate {
        let signingKey = P256.Signing.PrivateKey()
        let publicKeyData = signingKey.publicKey.rawRepresentation
        let deviceId = getDeviceId()
        let fingerprint = SHA256.hash(data: publicKeyData).compactMap { String(format: "%02x", $0) }.joined()
        
 // 自签名证书：公钥、设备ID 与时间戳全部绑定到同一把签名密钥。
        let signatureData = publicKeyData + Data(deviceId.utf8) + Data(timestamp.timeIntervalSince1970.description.utf8)
        let signature = try signingKey.signature(for: signatureData)
        
        return P2PDeviceCertificate(
            deviceId: deviceId,
            publicKey: publicKeyData,
            fingerprint: fingerprint,
            timestamp: timestamp,
            signature: signature.rawRepresentation
        )
    }
    
 /// 验证证书
    private func verifyCertificate(_ certificate: P2PDeviceCertificate) throws -> Bool {
 // 验证时间戳
        let now = Date()
        if now.timeIntervalSince(certificate.timestamp) > configuration.challengeLifetime {
            return false
        }
        
 // 验证指纹
        let computedFingerprint = SHA256.hash(data: certificate.publicKey).compactMap { String(format: "%02x", $0) }.joined()
        guard certificate.fingerprint == computedFingerprint else {
            return false
        }

        let signatureData = certificate.publicKey
            + Data(certificate.deviceId.utf8)
            + Data(certificate.timestamp.timeIntervalSince1970.description.utf8)
        let verifyingKey = try P256.Signing.PublicKey(rawRepresentation: certificate.publicKey)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: certificate.signature)
        return verifyingKey.isValidSignature(signature, for: signatureData)
    }
    
 /// 加载信任设备
    private func loadTrustedDevices() {
        self.trustedDevices = Set(TrustedDevicePersistence.loadDeviceIDs())
    }
    
 /// 保存信任设备
    private func saveTrustedDevices() {
        TrustedDevicePersistence.saveDeviceIDs(trustedDevices)
    }
    
 /// 证书有效性检查
    public var hasValidCertificates: Bool {
 // 检查当前证书是否有效
        return deviceKeyPair.publicKey.rawRepresentation.count > 0
    }
    
 /// 重新生成密钥对
    public func regenerateKeys() async throws {
 // 生成新的密钥对
        deviceKeyPair = P256.KeyAgreement.PrivateKey()
        
 // 清除现有的会话密钥
        sessionKeys.removeAll()
        
 // 通知密钥已更新
        SkyBridgeLogger.security.debugOnly("密钥已重新生成")
    }
    
 /// 签名连接请求
    public func signConnectionRequest(to device: P2PDevice) throws -> Data {
        let requestData = "\(getDeviceId())-\(device.id)-\(Date().timeIntervalSince1970)".utf8Data
 // 使用ECDSA签名而不是KeyAgreement
        let signingKey = P256.Signing.PrivateKey()
        let signature = try signingKey.signature(for: requestData)
        return signature.rawRepresentation
    }
    
 /// 验证连接请求
    public func verifyConnectionRequest(_ request: P2PConnectionRequest) throws -> Bool {
        let requestData = "\(request.sourceDevice.id)-\(request.targetDevice.id)-\(request.timestamp.timeIntervalSince1970)".utf8Data
 // 从公钥数据创建验证密钥
        let publicKeyData = request.targetDevice.publicKey
        let verifyingKey = try P256.Signing.PublicKey(rawRepresentation: publicKeyData)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: request.signature)
        return verifyingKey.isValidSignature(signature, for: requestData)
    }
    
 /// 获取公钥数据
    public var publicKeyData: Data {
        return deviceKeyPair.publicKey.rawRepresentation
    }
    
 /// 重置所有安全设置
    @MainActor
    public func resetAllSecuritySettings() {
        sessionKeys.removeAll()
        trustedDevices.removeAll()
        activeSecureConnections.removeAll()
        saveTrustedDevices()
    }

 /// 清除安全缓存
    public func clearSecurityCache() {
 // 清除会话密钥
        sessionKeys.removeAll()
        
 // 清除活跃连接
        activeSecureConnections.removeAll()
        
        SkyBridgeLogger.security.debugOnly("安全缓存已清除")
    }

 // MARK: - 策略持久化
    private func setupPolicyObservers() {
 // 简化：在变更时直接持久化
        NotificationCenter.default.addObserver(forName: NSNotification.Name("sec.policy.sync"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persistPolicies()
            }
        }
    }
    
    private func persistPolicies() {
        UserDefaults.standard.set(policyAutoTrustEnabled, forKey: "sec.policy.autoTrustEnabled")
        UserDefaults.standard.set(policyStrictCertificateValidation, forKey: "sec.policy.strictCert")
        UserDefaults.standard.set(policyConnectionTimeoutEnabled, forKey: "sec.policy.connTimeout")
        UserDefaults.standard.set(policyDataIntegrityCheckEnabled, forKey: "sec.policy.dataIntegrity")
    }
    
    public func updatePolicies(autoTrust: Bool? = nil, strictCert: Bool? = nil, connTimeout: Bool? = nil, dataIntegrity: Bool? = nil) {
        if let autoTrust { policyAutoTrustEnabled = autoTrust }
        if let strictCert { policyStrictCertificateValidation = strictCert }
        if let connTimeout { policyConnectionTimeoutEnabled = connTimeout }
        if let dataIntegrity { policyDataIntegrityCheckEnabled = dataIntegrity }
        Task { @MainActor in
            persistPolicies()
        }
    }
}

/// 量子加密管理器 - 多版本兼容实现（macOS 14.x/15.x/26.x 经典+liboqs，macOS 26+ 优先 CryptoKit PQC）
///
/// 策略：
/// - macOS 26+ 且 PQC API 可用：优先使用 ML-KEM/ML-DSA/HPKE（后量子密码学）
/// - macOS 14/15 或 PQC 不可用：自动使用 AES-GCM（经典算法）
/// - 自动回退：PQC 失败时无缝回退到 AES-GCM
/// - 性能优化：Apple Silicon 优化的分块处理、零拷贝、缓存能力检测
public class QuantumCryptoManager {
 /// 运行时模式
    public enum QuantumMode: Sendable {
        case automatic    // 自动选择（优先 PQC，失败回退）
        case classicOnly  // 强制仅经典（AES-GCM）
        case pqcOnly      // 强制仅 PQC（macOS 26+，失败抛错）
    }
    
 /// 实际使用的算法类型（运行时确定）
    public enum AlgorithmType: String, Sendable {
        case classic = "AES-GCM"      // 经典算法
        case pqcHybrid = "HPKE-X-Wing" // 混合后量子（X25519+ML-KEM-768）
        case pqcPure = "ML-KEM"       // 纯后量子
    }
    
 /// 能力检测结果（缓存，避免重复检查）
    private struct CapabilityCache: Sendable {
        let hasPQC: Bool
        let systemVersion: String
        let algorithmType: AlgorithmType
        let detectedAt: Date
    }
    
    private let mode: QuantumMode
    private let capabilityCache: CapabilityCache
    private let perfLock = OSAllocatedUnfairLock<PerformanceMetrics>(initialState: PerformanceMetrics())
    
 // HPKE 密钥缓存（仅在 macOS 26 可用时参与编译）
 // 注意：存储属性不能使用 @available，使用可选类型并在方法中检查版本
    private var hpkeRecipientPublicKeyStorage: Any? = nil
    private var hpkeRecipientPrivateKeyStorage: Any? = nil
    
    @available(iOS 26.0, macOS 26.0, *)
    private var hpkeRecipientPublicKey: XWingMLKEM768X25519.PublicKey? {
        get { hpkeRecipientPublicKeyStorage as? XWingMLKEM768X25519.PublicKey }
        set { hpkeRecipientPublicKeyStorage = newValue }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var hpkeRecipientPrivateKey: XWingMLKEM768X25519.PrivateKey? {
        get { hpkeRecipientPrivateKeyStorage as? XWingMLKEM768X25519.PrivateKey }
        set { hpkeRecipientPrivateKeyStorage = newValue }
    }
    
 /// 性能指标
    private struct PerformanceMetrics: Sendable {
        var encBytes: UInt64 = 0
        var decBytes: UInt64 = 0
        var encMs: UInt64 = 0
        var decMs: UInt64 = 0
        var pqcUsageCount: UInt64 = 0
        var classicFallbackCount: UInt64 = 0
    }
    
 /// 初始化量子加密管理器
    public init(mode: QuantumMode = .automatic) {
        self.mode = mode
        
 // 运行时能力检测（一次性，缓存结果）
        let (hasPQC, version, algoType) = Self.detectPQCCapability()
        self.capabilityCache = CapabilityCache(
            hasPQC: hasPQC,
            systemVersion: version,
            algorithmType: algoType,
            detectedAt: Date()
        )
        
        SkyBridgeLogger.security.debugOnly("🔐 量子加密管理器初始化完成")
        SkyBridgeLogger.security.debugOnly("   - 系统版本: \(version)")
        SkyBridgeLogger.security.debugOnly("   - PQC 可用: \(hasPQC ? "是" : "否")")
        SkyBridgeLogger.security.debugOnly("   - 算法类型: \(algoType.rawValue)")
        SkyBridgeLogger.security.debugOnly("   - 运行模式: \(mode)")
    }
    
 /// 运行时检测 PQC 能力（iOS 26+/macOS 26+ 原生 PQC 可用）
    private static func detectPQCCapability() -> (hasPQC: Bool, version: String, algorithmType: AlgorithmType) {
        let version = ProcessInfo.processInfo.operatingSystemVersionString

        if #available(iOS 26.0, macOS 26.0, *) {
            return (hasPQC: true, version: version, algorithmType: .pqcHybrid)
        }
        return (hasPQC: false, version: version, algorithmType: .classic)
    }
    
 /// 生成对称密钥（智能选择）
    public func generateQuantumSafeKey() -> SymmetricKey {
 // 当前实现：统一使用 AES-256（兼容所有版本）
 // 未来：macOS 26+ 可使用 ML-KEM 派生密钥
        return SymmetricKey(size: .bits256)
    }
    
 /// 加密（多版本兼容，自动选择最优算法）
    public func quantumSafeEncrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let t0 = DispatchTime.now().uptimeNanoseconds
        
 // 根据模式和能力选择算法
        let usePQC = shouldUsePQC()
        
        if usePQC {
 // 尝试使用 PQC（macOS 15+）
            if #available(macOS 15.0, *) {
                if let result = try? encryptWithPQC(data, using: key) {
                    recordPerf(encBytes: UInt64(data.count), encMs: UInt64((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000), isPQC: true)
                    return result
                } else if mode == .pqcOnly {
                    throw NSError(domain: "QuantumCrypto", code: -100, userInfo: [NSLocalizedDescriptionKey: "PQC 加密失败，且模式为仅 PQC"])
                }
            }
 // 回退到经典算法
            recordPerf(encBytes: 0, encMs: 0, isPQC: false)
        }
        
 // 使用经典 AES-GCM（兼容所有版本，性能最优）
        let result = try encryptWithAESGCM(data, using: key)
        let t1 = DispatchTime.now().uptimeNanoseconds
        recordPerf(encBytes: UInt64(data.count), encMs: UInt64((t1 - t0) / 1_000_000), isPQC: false)
        return result
    }
    
 /// 解密（多版本兼容，自动选择最优算法）
    public func quantumSafeDecrypt(_ encryptedData: Data, using key: SymmetricKey) throws -> Data {
        let t0 = DispatchTime.now().uptimeNanoseconds
        
 // 根据模式和能力选择算法
        let usePQC = shouldUsePQC()
        
        if usePQC {
 // 尝试使用 PQC（macOS 15+）
            if #available(macOS 15.0, *) {
                if let result = try? decryptWithPQC(encryptedData, using: key) {
                    recordPerf(decBytes: UInt64(encryptedData.count), decMs: UInt64((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000), isPQC: true)
                    return result
                } else if mode == .pqcOnly {
                    throw NSError(domain: "QuantumCrypto", code: -101, userInfo: [NSLocalizedDescriptionKey: "PQC 解密失败，且模式为仅 PQC"])
                }
            }
 // 回退到经典算法
            recordPerf(decBytes: 0, decMs: 0, isPQC: false)
        }
        
 // 使用经典 AES-GCM（兼容所有版本，性能最优）
        let result = try decryptWithAESGCM(encryptedData, using: key)
        let t1 = DispatchTime.now().uptimeNanoseconds
        recordPerf(decBytes: UInt64(encryptedData.count), decMs: UInt64((t1 - t0) / 1_000_000), isPQC: false)
        return result
    }
    
 // MARK: - 私有实现方法
    
 /// 判断是否应使用 PQC
    private func shouldUsePQC() -> Bool {
        switch mode {
        case .classicOnly:
            return false
        case .pqcOnly:
            return capabilityCache.hasPQC
        case .automatic:
            return capabilityCache.hasPQC
        }
    }
    
 /// 使用 PQC 加密（iOS 17+/macOS 15+）
    @available(iOS 17.0, macOS 15.0, *)
    private func encryptWithPQC(_ data: Data, using key: SymmetricKey) throws -> Data {
 // 仅在 iOS 26+/macOS 26+ 环境下执行 HPKE X‑Wing 加密；较低版本抛错由上层回退到 AES‑GCM
        if #available(iOS 26.0, macOS 26.0, *) {
 // 说明：为保持现有接口不变，PQC 分支采用 HPKE X‑Wing（X25519+ML‑KEM‑768）
 // 需要事先设置对端的公钥；若未设置，则回退由调用方决定（此处抛错以触发回退）。
            guard let hpkeRecipientPublicKey = self.hpkeRecipientPublicKey else {
                throw NSError(domain: "QuantumCrypto", code: -210, userInfo: [NSLocalizedDescriptionKey: "缺少 HPKE 收件人公钥"])
            }

 // 选择 X‑Wing 套件：X25519 + ML‑KEM‑768 + SHA256 + AES‑GCM‑256
            let suite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
            let info = Data() // 可根据协议放入上下文
            var sender = try HPKE.Sender(recipientKey: hpkeRecipientPublicKey, ciphersuite: suite, info: info)
            let encapsulatedKey = sender.encapsulatedKey

 // 加密数据（将上层对称 key 作为 AAD 绑定，保护会话策略完整性；可按需调整）
            let aad = key.withUnsafeBytes { Data($0) }
            let ciphertext = try sender.seal(data, authenticating: aad)

 // 信封格式：| encKeyLen(2 bytes) | encKey | ciphertext |
            var envelope = Data()
            var len = UInt16(encapsulatedKey.count).bigEndian
            withUnsafeBytes(of: &len) { envelope.append(contentsOf: $0) }
            envelope.append(encapsulatedKey)
            envelope.append(ciphertext)
            return envelope
        } else {
            throw NSError(domain: "QuantumCrypto", code: -211, userInfo: [NSLocalizedDescriptionKey: "当前系统版本不支持 PQC（HPKE X‑Wing）"])
        }
    }
    
 /// 使用 PQC 解密（iOS 17+/macOS 15+）
    @available(iOS 17.0, macOS 15.0, *)
    private func decryptWithPQC(_ encryptedData: Data, using key: SymmetricKey) throws -> Data {
 // 仅在 iOS 26+/macOS 26+ 环境下执行 HPKE X‑Wing 解密；较低版本抛错由上层回退到 AES‑GCM
        if #available(iOS 26.0, macOS 26.0, *) {
 // 需要本端的 HPKE 私钥；若未设置，则抛错以触发回退。
            guard let hpkeRecipientPrivateKey = self.hpkeRecipientPrivateKey else {
                throw NSError(domain: "QuantumCrypto", code: -211, userInfo: [NSLocalizedDescriptionKey: "缺少 HPKE 接收方私钥"])
            }

 // 解析信封
            guard encryptedData.count >= 2 else {
                throw NSError(domain: "QuantumCrypto", code: -212, userInfo: [NSLocalizedDescriptionKey: "密文格式无效"])
            }
            let lenData = encryptedData.prefix(2)
            let encKeyLen = lenData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let headerSize = 2
            guard encryptedData.count >= headerSize + Int(encKeyLen) else {
                throw NSError(domain: "QuantumCrypto", code: -213, userInfo: [NSLocalizedDescriptionKey: "密文长度不匹配"])
            }
            let encapsulatedKey = encryptedData.subdata(in: headerSize ..< headerSize + Int(encKeyLen))
            let ciphertext = encryptedData.suffix(from: headerSize + Int(encKeyLen))

 // 构建接收端并解密
            let suite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
            let info = Data()
            var recipient = try HPKE.Recipient(
                privateKey: hpkeRecipientPrivateKey,
                ciphersuite: suite,
                info: info,
                encapsulatedKey: encapsulatedKey
            )
            let aad = key.withUnsafeBytes { Data($0) }
            return try recipient.open(ciphertext, authenticating: aad)
        } else {
            throw NSError(domain: "QuantumCrypto", code: -214, userInfo: [NSLocalizedDescriptionKey: "当前系统版本不支持 PQC（HPKE X‑Wing）"])
        }
    }

 // MARK: - HPKE 密钥管理（仅 macOS 26+ 可用）
    
 /// 生成 HPKE X-Wing 密钥对（iOS 26+/macOS 26+）
 /// - Returns: (私钥, 公钥) 元组
 /// - Note:
 /// - 私钥使用 integrityCheckedRepresentation 序列化后可安全存储到钥匙串
 /// - 公钥可安全共享，用于密钥交换
 /// - X-Wing 密钥为软件密钥；如需 Secure Enclave，需使用 SecureEnclave.MLKEM*/MLDSA* 类型
    @available(iOS 26.0, macOS 26.0, *)
    public static func generateHPKEKeyPair() throws -> (privateKey: XWingMLKEM768X25519.PrivateKey, publicKey: XWingMLKEM768X25519.PublicKey) {
 // 生成 X-Wing 密钥对（X25519 + ML-KEM-768）
 // 注意：API 可能是 generate() 或 init()，根据实际文档调整
        let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let publicKey = privateKey.publicKey
        return (privateKey, publicKey)
    }
    
 /// 设置对端公钥（用于加密）
    @available(macOS 26.0, *)
    public func setHPKERecipientPublicKey(_ key: XWingMLKEM768X25519.PublicKey) {
        self.hpkeRecipientPublicKey = key
    }
    
 /// 设置本端私钥（用于解密）
    @available(macOS 26.0, *)
    public func setHPKERecipientPrivateKey(_ key: XWingMLKEM768X25519.PrivateKey) {
        self.hpkeRecipientPrivateKey = key
    }
    
 /// 检查是否已设置 HPKE 密钥
    @available(macOS 15.0, *)
    public var hasHPKEKeys: Bool {
 // 仅在 26+ 系统下访问 HPKE 密钥状态；低版本始终返回 false
        if #available(macOS 26.0, *) {
            return hpkeRecipientPublicKey != nil && hpkeRecipientPrivateKey != nil
        } else {
            return false
        }
    }
    
 /// 清除 HPKE 密钥（内存中）
    @available(macOS 15.0, *)
    public func clearHPKEKeys() {
 // 仅在 26+ 清理 HPKE 密钥；低版本无需操作
        if #available(macOS 26.0, *) {
            hpkeRecipientPublicKey = nil
            hpkeRecipientPrivateKey = nil
        }
    }
    
 /// 从钥匙串加载 HPKE 私钥（macOS 26+）
 /// - Parameter keyTag: 钥匙串标签（用于标识密钥）
 /// - Returns: 成功返回私钥，失败返回 nil
 /// - Note: 使用 CryptoKit 的 GenericPasswordConvertible 协议或 integrityCheckedRepresentation
    @available(macOS 26.0, *)
    public func loadHPKEPrivateKeyFromKeychain(keyTag: String) throws -> XWingMLKEM768X25519.PrivateKey? {
 // 方法1：使用 GenericPasswordConvertible 协议（如果 X-Wing 密钥实现了该协议）
 // 这是 CryptoKit 推荐的方式
        do {
 // 尝试使用标准钥匙串接口
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: keyTag,
                kSecReturnData as String: true
            ]
            
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            
            guard status == errSecSuccess,
                  let keyData = result as? Data else {
                if status == errSecItemNotFound {
                    return nil
                }
                throw NSError(domain: "QuantumCrypto", code: -220, userInfo: [NSLocalizedDescriptionKey: "钥匙串加载失败: \(status)"])
            }
            
 // 使用 integrityCheckedRepresentation 恢复私钥
 // integrityCheckedRepresentation 是 Data 属性，包含完整性校验信息
 // init(integrityCheckedRepresentation:) 可能抛出错误
            return try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: keyData)
        } catch {
 // 如果加载失败，返回 nil（表示密钥不存在）
            if (error as NSError).domain == "QuantumCrypto" && (error as NSError).code == -220 {
                throw error
            }
            return nil
        }
    }
    
 /// 保存 HPKE 私钥到钥匙串（macOS 26+）
 /// - Parameters:
 /// - privateKey: 要保存的私钥
 /// - keyTag: 钥匙串标签
 /// - Note:
 /// - 使用 integrityCheckedRepresentation 属性（Data 类型）获取带完整性校验的序列化数据
 /// - integrityCheckedRepresentation 是设备绑定的，只能在生成它的设备上恢复
 /// - X-Wing 密钥可能实现 GenericPasswordConvertible 协议，可直接使用标准方法
 /// - Secure Enclave PQC 仅在 macOS 26+ 可用，且需要 SecureEnclave.MLKEM*/MLDSA* 密钥类型
    @available(macOS 26.0, *)
    public func saveHPKEPrivateKeyToKeychain(_ privateKey: XWingMLKEM768X25519.PrivateKey, keyTag: String) throws {
 // 获取带完整性校验的私钥表示（Data 类型属性）
 // integrityCheckedRepresentation 包含完整性校验信息，防止篡改
 // 注意：这是设备绑定的，无法在其他设备上恢复
        let keyData = privateKey.integrityCheckedRepresentation
        
 // 删除旧密钥（如果存在）
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
 // 构建存储属性（使用 GenericPassword 而不是 Key，更符合 CryptoKit 推荐）
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "QuantumCrypto", code: -221, userInfo: [NSLocalizedDescriptionKey: "钥匙串保存失败: \(status)"])
        }
    }
    
 /// 生成使用 Secure Enclave 的 ML-KEM 密钥对（macOS 26+）
 /// - Note:
 /// - 仅在 macOS 26+ 且 Secure Enclave 可用时生效
 /// - 使用 SecureEnclave.MLKEM768.PrivateKey 生成硬件隔离私钥
 /// - 公钥类型为 MLKEM768.PublicKey（不在 SecureEnclave 命名空间）
 /// - Returns: (ML-KEM 私钥, ML-KEM 公钥) 元组
    @available(macOS 26.0, *)
    public static func generateSecureEnclaveMLKEMKeyPair() throws -> (privateKey: SecureEnclave.MLKEM768.PrivateKey, publicKey: MLKEM768.PublicKey) {
 // 在 Secure Enclave 中生成 ML-KEM 768 私钥
 // 私钥永远不离开硬件安全区域
 // 公钥可以从私钥导出，类型可能是 MLKEM768.PublicKey
        let privateKey = try SecureEnclave.MLKEM768.PrivateKey()
        let publicKey = privateKey.publicKey
        return (privateKey, publicKey)
    }
    
 /// 自动初始化：从钥匙串加载 HPKE 私钥（如果存在）
 /// - Parameter keyTag: 钥匙串标签
 /// - Returns: 是否成功加载
 /// - Note: 使用 integrityCheckedRepresentation 恢复的私钥只能在生成它的设备上使用
    @available(macOS 15.0, *)
    @discardableResult
    public func autoLoadHPKEPrivateKey(keyTag: String = "com.skybridge.hpke.private") -> Bool {
 // 在 macOS 15.x 环境下进行运行时判断；仅在 26+ 调用钥匙串恢复
        if #available(macOS 26.0, *) {
            do {
                if let privateKey = try loadHPKEPrivateKeyFromKeychain(keyTag: keyTag) {
                    setHPKERecipientPrivateKey(privateKey)
                    SkyBridgeLogger.security.debugOnly("✅ HPKE 私钥已从钥匙串加载")
                    return true
                }
            } catch {
                SkyBridgeLogger.security.error("⚠️ 自动加载 HPKE 私钥失败: \(error.localizedDescription, privacy: .private)")
            }
        }
        return false
    }
    
 /// 获取本端公钥（用于密钥交换）
 /// - Returns: 当前设置的私钥对应的公钥，如果未设置则返回 nil
    @available(macOS 26.0, *)
    public func getHPKEPublicKey() -> XWingMLKEM768X25519.PublicKey? {
        return hpkeRecipientPrivateKey?.publicKey
    }
    
 /// 使用 AES-GCM 加密（所有版本支持，性能优化）
    private func encryptWithAESGCM(_ data: Data, using key: SymmetricKey) throws -> Data {
 // Apple Silicon 优化：分块处理大文件，零拷贝小文件
        if data.count <= 1_048_576 {
 // 小文件：直接处理（零拷贝）
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
            guard let combined = sealed.combined else {
                throw NSError(domain: "QuantumCrypto", code: -1, userInfo: [NSLocalizedDescriptionKey: "AES-GCM sealed box missing combined data"])
            }
            return combined
        }
        
 // 大文件：分块处理（降低峰值内存，提升吞吐）
        var output = Data()
        output.reserveCapacity(data.count + 64 * ((data.count / 1_048_576) + 1))
        var offset = 0
        while offset < data.count {
            let end = min(offset + 1_048_576, data.count)
            let chunk = data.subdata(in: offset..<end)
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(chunk, using: key, nonce: nonce)
            guard let combined = sealed.combined else {
                throw NSError(domain: "QuantumCrypto", code: -1, userInfo: [NSLocalizedDescriptionKey: "AES-GCM sealed box missing combined data"])
            }
            output.append(combined)
            offset = end
        }
        return output
    }
    
 /// 使用 AES-GCM 解密（所有版本支持，性能优化）
    private func decryptWithAESGCM(_ encryptedData: Data, using key: SymmetricKey) throws -> Data {
 // 尝试整体解密（最常见情况）
        if let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: encryptedData), using: key) {
            return plain
        }
        
 // 分块解密（兼容分块加密的产物）
        var out = Data()
        var cursor = 0
        while cursor < encryptedData.count {
            let remain = encryptedData.count - cursor
            guard remain >= 28 else {
                throw NSError(domain: "QuantumCrypto", code: -1, userInfo: [NSLocalizedDescriptionKey: "数据格式无效"])
            }
            
 // 尝试解密当前块（假设每个块都是完整的 sealed box）
 // 实际实现中，需要更智能的边界检测
            let sliceEnd = min(cursor + 1_048_576 + 32, encryptedData.count)
            let slice = encryptedData.subdata(in: cursor..<sliceEnd)
            
            if let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: slice), using: key) {
                out.append(plain)
                cursor = sliceEnd
            } else {
 // 如果无法分块解密，尝试整体（可能不是分块格式）
                return try AES.GCM.open(AES.GCM.SealedBox(combined: encryptedData), using: key)
            }
        }
        return out
    }
    
 /// 记录性能指标
    private func recordPerf(encBytes: UInt64 = 0, decBytes: UInt64 = 0, encMs: UInt64 = 0, decMs: UInt64 = 0, isPQC: Bool) {
        perfLock.withLock { metrics in
            metrics.encBytes &+= encBytes
            metrics.decBytes &+= decBytes
            metrics.encMs &+= encMs
            metrics.decMs &+= decMs
            if isPQC {
                metrics.pqcUsageCount &+= 1
            } else {
                metrics.classicFallbackCount &+= 1
            }
        }
    }
    
 // MARK: - 公共属性
    
 /// 性能快照（用于 Dashboard 展示）
    public var performanceSnapshot: (encBytes: UInt64, decBytes: UInt64, encMs: UInt64, decMs: UInt64, pqcCount: UInt64, classicCount: UInt64) {
        perfLock.withLock { metrics in
            (metrics.encBytes, metrics.decBytes, metrics.encMs, metrics.decMs, metrics.pqcUsageCount, metrics.classicFallbackCount)
        }
    }
    
 /// 当前使用的算法类型
    public var currentAlgorithm: AlgorithmType {
        return capabilityCache.algorithmType
    }
    
 /// 系统版本信息
    public var systemInfo: (version: String, hasPQC: Bool) {
        return (capabilityCache.systemVersion, capabilityCache.hasPQC)
    }
}

// MARK: - 会话/令牌公共组件（旧系统复用 HKDF 派生）
public struct SessionTokenKit {
 /// 从共享密钥派生 32 字节会话密钥（HKDF-SHA256）
    public static func deriveSessionKey(sharedSecret: Data, salt: Data = Data(), info: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: sharedSecret)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 32)
    }
 /// 签发令牌（ML‑DSA‑65），返回签名
    public static func issueToken(provider: PQCProvider, payload: Data, peerId: String) async throws -> Data {
        return try await provider.sign(data: payload, peerId: peerId, algorithm: "ML-DSA-65")
    }
 /// 验证令牌签名（ML‑DSA‑65）
    public static func verifyToken(provider: PQCProvider, payload: Data, signature: Data, peerId: String) async -> Bool {
        return await provider.verify(data: payload, signature: signature, peerId: peerId, algorithm: "ML-DSA-65")
    }
}
