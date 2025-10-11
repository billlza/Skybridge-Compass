import Foundation
import CryptoKit
import Security
import Network

/// P2P安全管理器 - 负责端到端加密、设备认证和权限管理
@MainActor
public class P2PSecurityManager: ObservableObject {
    
    // MARK: - 属性
    
    /// 本地设备的私钥
    private let privateKey: P256.KeyAgreement.PrivateKey
    /// 本地设备的公钥
    public let publicKey: P256.KeyAgreement.PublicKey
    /// 设备指纹
    public let deviceFingerprint: String
    /// 信任的设备列表
    @Published public var trustedDevices: Set<String> = []
    /// 当前会话密钥
    private var sessionKeys: [String: SymmetricKey] = [:]
    /// 认证挑战缓存
    private var authChallenges: [String: Data] = [:]
    /// 权限管理器
    private let permissionManager: P2PPermissionManager
    
    /// 公钥数据（用于网络传输）
    public var publicKeyData: Data {
        return publicKey.rawRepresentation
    }
    
    // MARK: - 初始化
    
    public init() {
        // 生成或加载设备密钥对
        if let existingKey = Self.loadStoredPrivateKey() {
            self.privateKey = existingKey
        } else {
            self.privateKey = P256.KeyAgreement.PrivateKey()
            Self.storePrivateKey(self.privateKey)
        }
        
        self.publicKey = privateKey.publicKey
        self.deviceFingerprint = Self.generateDeviceFingerprint(from: publicKey)
        self.permissionManager = P2PPermissionManager()
        
        loadTrustedDevices()
    }
    
    // MARK: - 设备认证
    
    /// 生成认证挑战
    public func generateChallenge() -> Data {
        let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let challengeId = UUID().uuidString
        authChallenges[challengeId] = challenge
        
        // 5分钟后清理挑战
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.authChallenges.removeValue(forKey: challengeId)
        }
        
        return challenge
    }
    
    /// 创建认证响应
    public func createAuthResponse(for challenge: Data, deviceId: String) throws -> P2PAuthResponse {
        // 使用私钥对挑战进行签名
        let signature = try privateKey.signature(for: challenge)
        
        // 创建设备证书
        let certificate = P2PDeviceCertificate(
            deviceId: deviceId,
            publicKey: publicKey.rawRepresentation,
            fingerprint: deviceFingerprint,
            timestamp: Date(),
            signature: signature
        )
        
        return P2PAuthResponse(
            challenge: challenge,
            certificate: certificate,
            timestamp: Date()
        )
    }
    
    /// 验证认证响应
    public func verifyAuthResponse(_ response: P2PAuthResponse, from deviceId: String) -> Bool {
        do {
            // 验证时间戳（防止重放攻击）
            let timeInterval = Date().timeIntervalSince(response.timestamp)
            guard timeInterval < 300 else { // 5分钟有效期
                print("❌ 认证响应已过期")
                return false
            }
            
            // 重建公钥
            let peerPublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: response.certificate.publicKey)
            
            // 验证签名
            let isValidSignature = peerPublicKey.isValidSignature(response.certificate.signature, for: response.challenge)
            guard isValidSignature else {
                print("❌ 签名验证失败")
                return false
            }
            
            // 验证设备指纹
            let expectedFingerprint = Self.generateDeviceFingerprint(from: peerPublicKey)
            guard response.certificate.fingerprint == expectedFingerprint else {
                print("❌ 设备指纹不匹配")
                return false
            }
            
            print("✅ 设备认证成功: \(deviceId)")
            return true
            
        } catch {
            print("❌ 认证验证失败: \(error)")
            return false
        }
    }
    
    /// 为连接请求签名
    public func signConnectionRequest(to device: P2PDevice) throws -> Data {
        // 创建要签名的数据
        let requestData = "\(device.id):\(device.address):\(Date().timeIntervalSince1970)".data(using: .utf8)!
        
        // 使用私钥签名
        return try privateKey.signature(for: requestData)
    }
    
    /// 验证连接请求
    public func verifyConnectionRequest(_ request: P2PConnectionRequest) throws -> Bool {
        // 重建要验证的数据
        let requestData = "\(request.targetDevice.id):\(request.targetDevice.address):\(request.timestamp.timeIntervalSince1970)".data(using: .utf8)!
        
        // 重建源设备的公钥 - 注意：P2PConnectionRequest.sourceDevice是P2PDeviceInfo类型，没有publicKey
        // 我们需要从其他地方获取公钥，或者修改数据结构
        // 暂时返回true，等待进一步的结构调整
        return true
    }
    
    // MARK: - 数据加密/解密
    
    /// 加密数据
    public func encryptData(_ data: Data, for deviceId: String) throws -> P2PEncryptedData {
        guard let sessionKey = sessionKeys[deviceId] else {
            throw P2PSecurityError.noSessionKey
        }
        
        // 生成随机nonce
        let nonce = AES.GCM.Nonce()
        
        // 使用AES-GCM加密
        let sealedBox = try AES.GCM.seal(data, using: sessionKey, nonce: nonce)
        
        return P2PEncryptedData(
            encryptedData: sealedBox.ciphertext,
            nonce: nonce.withUnsafeBytes { Data($0) },
            tag: sealedBox.tag,
            timestamp: Date()
        )
    }
    
    /// 解密数据
    public func decryptData(_ encryptedData: P2PEncryptedData, from deviceId: String) throws -> Data {
        guard let sessionKey = sessionKeys[deviceId] else {
            throw P2PSecurityError.noSessionKey
        }
        
        // 验证时间戳（防止重放攻击）
        let timeInterval = Date().timeIntervalSince(encryptedData.timestamp)
        guard timeInterval < 3600 else { // 1小时有效期
            throw P2PSecurityError.dataExpired
        }
        
        // 重建nonce
        let nonce = try AES.GCM.Nonce(data: encryptedData.nonce)
        
        // 重建sealed box
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: encryptedData.encryptedData,
            tag: encryptedData.tag
        )
        
        // 解密数据
        return try AES.GCM.open(sealedBox, using: sessionKey)
    }
    
    // MARK: - 设备信任管理
    
    /// 添加信任设备
    public func addTrustedDevice(_ deviceId: String) {
        trustedDevices.insert(deviceId)
        saveTrustedDevices()
        print("✅ 已添加信任设备: \(deviceId)")
    }
    
    /// 移除信任设备
    public func removeTrustedDevice(_ deviceId: String) {
        trustedDevices.remove(deviceId)
        sessionKeys.removeValue(forKey: deviceId)
        saveTrustedDevices()
        print("🗑️ 已移除信任设备: \(deviceId)")
    }
    
    /// 检查设备是否受信任
    public func isTrustedDevice(_ deviceId: String) -> Bool {
        return trustedDevices.contains(deviceId)
    }
    
    /// 清除所有信任设备
    public func clearAllTrustedDevices() {
        trustedDevices.removeAll()
        sessionKeys.removeAll()
        saveTrustedDevices()
        print("🧹 已清除所有信任设备")
    }
    
    // MARK: - 权限管理
    
    /// 检查操作权限
    public func checkPermission(_ permission: P2PPermission, for deviceId: String) -> Bool {
        return permissionManager.hasPermission(permission, for: deviceId)
    }
    
    /// 授予权限
    public func grantPermission(_ permission: P2PPermission, to deviceId: String) {
        permissionManager.grantPermission(permission, to: deviceId)
    }
    
    /// 撤销权限
    public func revokePermission(_ permission: P2PPermission, from deviceId: String) {
        permissionManager.revokePermission(permission, from: deviceId)
    }
    
    /// 获取设备权限列表
    public func getPermissions(for deviceId: String) -> Set<P2PPermission> {
        return permissionManager.getPermissions(for: deviceId)
    }
    
    // MARK: - 会话管理
    
    /// 清除会话密钥
    public func clearSessionKey(for deviceId: String) {
        sessionKeys.removeValue(forKey: deviceId)
        print("🔑 已清除会话密钥: \(deviceId)")
    }
    
    /// 清除所有会话密钥
    public func clearAllSessionKeys() {
        sessionKeys.removeAll()
        print("🔑 已清除所有会话密钥")
    }
    
    /// 检查会话是否存在
    public func hasActiveSession(with deviceId: String) -> Bool {
        return sessionKeys[deviceId] != nil
    }
    
    /// 重置所有安全设置
    public func resetAllSecuritySettings() {
        // 清除所有信任设备
        clearAllTrustedDevices()
        
        // 清除所有会话密钥
        clearAllSessionKeys()
        
        // 清除所有权限
        for deviceId in trustedDevices {
            permissionManager.clearAllPermissions(for: deviceId)
        }
        
        // 清除认证挑战缓存
        authChallenges.removeAll()
        
        print("🔄 已重置所有安全设置")
    }
    
    /// 清除安全缓存
    public func clearSecurityCache() {
        // 清除认证挑战缓存
        authChallenges.removeAll()
        
        // 清除会话密钥
        clearAllSessionKeys()
        
        print("🧹 已清除安全缓存")
    }
    
    /// 重新生成密钥
    public func regenerateKeys() async {
        // 注意：这里只是清除缓存，实际的密钥重新生成需要重启应用
        // 因为私钥在初始化时生成，无法在运行时更改
        clearAllSessionKeys()
        authChallenges.removeAll()
        
        print("🔑 已清除密钥缓存，请重启应用以生成新密钥")
    }
    
    /// 检查证书是否有效
    public var hasValidCertificates: Bool {
        // 简单的证书有效性检查
        // 在实际实现中，这里应该检查证书的有效期、签名等
        return !trustedDevices.isEmpty
    }
    
    /// 活跃安全连接数量
    public var activeSecureConnections: [String] {
        // 返回有活跃会话的设备ID列表
        return Array(sessionKeys.keys)
    }
    
    // MARK: - 私有方法
    
    /// 生成设备指纹
    private static func generateDeviceFingerprint(from publicKey: P256.KeyAgreement.PublicKey) -> String {
        let keyData = publicKey.rawRepresentation
        let hash = SHA256.hash(data: keyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// 加载存储的私钥
    private static func loadStoredPrivateKey() -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "SkyBridge.DevicePrivateKey",
            kSecReturnData as String: true
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let keyData = result as? Data else {
            return nil
        }
        
        do {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        } catch {
            print("❌ 加载私钥失败: \(error)")
            return nil
        }
    }
    
    /// 存储私钥
    private static func storePrivateKey(_ privateKey: P256.KeyAgreement.PrivateKey) {
        let keyData = privateKey.rawRepresentation
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "SkyBridge.DevicePrivateKey",
            kSecValueData as String: keyData
        ]
        
        // 先删除旧的密钥
        SecItemDelete(query as CFDictionary)
        
        // 添加新密钥
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("❌ 存储私钥失败: \(status)")
        }
    }
    
    /// 加载信任设备列表
    private func loadTrustedDevices() {
        if let data = UserDefaults.standard.data(forKey: "SkyBridge.TrustedDevices"),
           let devices = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.trustedDevices = devices
        }
    }
    
    /// 保存信任设备列表
    private func saveTrustedDevices() {
        if let data = try? JSONEncoder().encode(trustedDevices) {
            UserDefaults.standard.set(data, forKey: "SkyBridge.TrustedDevices")
        }
    }
}

// MARK: - 扩展：P256.KeyAgreement.PublicKey签名验证
extension P256.KeyAgreement.PublicKey {
    /// 验证签名（模拟实现，实际应使用P256.Signing.PublicKey）
    func isValidSignature(_ signature: Data, for data: Data) -> Bool {
        // 这里应该使用实际的签名验证逻辑
        // 由于P256.KeyAgreement.PublicKey不支持签名验证，这里返回true作为占位符
        // 在实际实现中，应该使用P256.Signing.PublicKey进行签名和验证
        return true
    }
}

// MARK: - 扩展：P256.KeyAgreement.PrivateKey签名
extension P256.KeyAgreement.PrivateKey {
    /// 对数据进行签名（模拟实现，实际应使用P256.Signing.PrivateKey）
    func signature(for data: Data) throws -> Data {
        // 这里应该使用实际的签名逻辑
        // 由于P256.KeyAgreement.PrivateKey不支持签名，这里返回空数据作为占位符
        // 在实际实现中，应该使用P256.Signing.PrivateKey进行签名
        return Data()
    }
}