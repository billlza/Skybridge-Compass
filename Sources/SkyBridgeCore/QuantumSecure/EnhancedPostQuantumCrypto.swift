import Foundation
import CryptoKit
import OSLog

/// 加密数据结构
public struct EncryptedData: Codable, Sendable {
    public let ciphertext: Data
    public let nonce: Data
    public let tag: Data
    
    public init(ciphertext: Data, nonce: Data, tag: Data) {
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.tag = tag
    }
    
 /// 组合为单一数据（用于传输）
    public var combined: Data {
        var data = Data()
        data.append(nonce)
        data.append(tag)
        data.append(ciphertext)
        return data
    }
    
 /// 从组合数据解析
    public static func from(combined data: Data) throws -> EncryptedData {
        guard data.count >= 32 else { // nonce(12) + tag(16) + min ciphertext
            throw QuantumNetworkError.decryptionFailed
        }
        
 // AES-GCM nonce通常是12字节，tag是16字节
        let nonceSize = 12
        let tagSize = 16
        let nonce = data.prefix(nonceSize)
        let tag = data.dropFirst(nonceSize).prefix(tagSize)
        let ciphertext = data.dropFirst(nonceSize + tagSize)
        
        return EncryptedData(
            ciphertext: Data(ciphertext),
            nonce: Data(nonce),
            tag: Data(tag)
        )
    }
}

/// 增强版后量子密码学实现 - 完整功能
///
/// 改进点:
/// 1. 完整的加密/解密实现
/// 2. 真正的数字签名和验证
/// 3. 密钥管理和同步
/// 4. 支持未来PQC算法扩展
///
/// ## 并发安全说明 (@unchecked Sendable)
/// 使用 `@unchecked Sendable` 的理由：
/// - ✅ 所有可变状态通过 `OSAllocatedUnfairLock` 保护
/// - ✅ `cryptoLock` 保护加密/解密操作
/// - ✅ `signingLock` 封装密钥对字典，所有访问都在 `withLock` 闭包内
/// - ✅ `logger` 是线程安全的
/// - ⚠️ 需要确保 CryptoKit 类型（SymmetricKey, P256等）本身是线程安全的
public class EnhancedPostQuantumCrypto: @unchecked Sendable {
    
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "EnhancedPostQuantumCrypto")
    
    public init() {
 // 公开初始化器，允许外部模块访问
    }
    
 // MARK: - 并发安全的状态管理
    
 /// 加密/解密操作锁
    private let cryptoLock = OSAllocatedUnfairLock<Void>(initialState: ())
    
 /// 密钥对管理（封装在锁内，每个对等节点一个密钥对）
 /// 所有访问必须通过 signingLock.withLock { } 进行
    private let signingLock = OSAllocatedUnfairLock<[String: (private: P256.Signing.PrivateKey, public: P256.Signing.PublicKey)]>(initialState: [:])
    
 // MARK: - 对称加密/解密
    
 /// 加密消息 - 使用AES-GCM
 /// - Parameters:
 /// - message: 要加密的消息
 /// - key: 加密密钥
 /// - Returns: 加密数据
    public func encrypt(_ message: String, using key: SymmetricKey) async throws -> EncryptedData {
        logger.debug("🔒 加密消息（AES-GCM）")
        
        guard let messageData = message.data(using: .utf8) else {
            throw QuantumNetworkError.encryptionFailed
        }
        
        return try cryptoLock.withLock { _ in
            do {
 // 使用AES-GCM加密
                let sealedBox = try AES.GCM.seal(messageData, using: key)
                
 // 提取各个组件（nonce和tag不是Optional）
                let nonce = sealedBox.nonce
                let tag = sealedBox.tag
                let ciphertext = sealedBox.ciphertext
                
                logger.debug("✅ 加密完成，密文大小: \(ciphertext.count) 字节")
                
                return EncryptedData(
                    ciphertext: ciphertext,
                    nonce: Data(nonce),
                    tag: Data(tag)
                )
            } catch {
                logger.error("❌ 加密失败: \(error)")
                throw QuantumNetworkError.encryptionFailed
            }
        }
    }
    
 /// 解密消息 - 使用AES-GCM
 /// - Parameters:
 /// - encrypted: 加密数据
 /// - key: 解密密钥
 /// - Returns: 解密后的消息
    public func decrypt(_ encrypted: EncryptedData, using key: SymmetricKey) async throws -> String {
        logger.debug("🔓 解密消息（AES-GCM）")
        
        return try cryptoLock.withLock { _ in
            do {
 // 重组SealedBox
                let nonce = try AES.GCM.Nonce(data: encrypted.nonce)
                let sealedBox = try AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: encrypted.ciphertext,
                    tag: encrypted.tag
                )
                
 // 解密
                let decryptedData = try AES.GCM.open(sealedBox, using: key)
                
                guard let decryptedMessage = String(data: decryptedData, encoding: .utf8) else {
                    throw QuantumNetworkError.decryptionFailed
                }
                
                logger.debug("✅ 解密完成")
                return decryptedMessage
            } catch {
                logger.error("❌ 解密失败: \(error)")
                throw QuantumNetworkError.decryptionFailed
            }
        }
    }
    
 // MARK: - 数字签名
    
 /// 获取或创建签名密钥对
    private func getOrCreateSigningKeyPair(for peerId: String) -> (private: P256.Signing.PrivateKey, public: P256.Signing.PublicKey) {
        return signingLock.withLock { keyPairs in
            if let existing = keyPairs[peerId] {
                return existing
            }
            
 // 创建新密钥对
            let privateKey = P256.Signing.PrivateKey()
            let publicKey = privateKey.publicKey
            let pair = (private: privateKey, public: publicKey)
            keyPairs[peerId] = pair
            
            logger.info("✅ 创建新签名密钥对: \(peerId)")
            return pair
        }
    }
    
 /// 签名数据 - 优先使用PQC，不可用时回退到P256 ECDSA
 /// - Parameters:
 /// - data: 要签名的数据
 /// - peerId: 对等节点ID（用于密钥管理）
 /// - Returns: 签名数据
    public func sign(_ data: Data, for peerId: String) async throws -> Data {
 // 🔧 优化：优先使用PQC签名，如果PQC不可用或未启用，回退到P256
        let enablePQC = await SettingsManager.shared.enablePQC
        let algorithm = await SettingsManager.shared.pqcSignatureAlgorithm
        
        if enablePQC {
            if #available(macOS 14.0, *), let provider = PQCProviderFactory.makeProvider() {
                do {
 // 尝试使用PQC签名
                    let pqcSignature = try await provider.sign(data: data, peerId: peerId, algorithm: algorithm)
                    logger.info("✅ PQC签名成功: \(algorithm), 签名长度: \(pqcSignature.count)字节")
                    return pqcSignature
                } catch {
                    logger.warning("⚠️ PQC签名失败，回退到P256: \(error.localizedDescription)")
 // 回退到P256
                }
            } else {
                logger.info("ℹ️ PQC提供者不可用，使用P256签名")
            }
        }
        
 // 回退到P256 ECDSA签名
        logger.debug("✍️ 使用P256 ECDSA签名（回退方案）")
        
        return try cryptoLock.withLock { _ in
            do {
                let keyPair = getOrCreateSigningKeyPair(for: peerId)
                let signature = try keyPair.private.signature(for: data)
                
                logger.debug("✅ P256签名完成")
                return signature.rawRepresentation
            } catch {
                logger.error("❌ 签名失败: \(error)")
                throw QuantumNetworkError.signatureFailed
            }
        }
    }
    
 /// 获取公钥（用于密钥交换）
    public func getPublicKey(for peerId: String) -> P256.Signing.PublicKey? {
        return signingLock.withLock { keyPairs in
            return keyPairs[peerId]?.public
        }
    }
    
 /// 存储对等节点的公钥
    public func storePublicKey(_ publicKey: P256.Signing.PublicKey, for peerId: String) {
        signingLock.withLock { keyPairs in
 // 如果没有私钥，创建一个占位符（仅用于验证）
            if keyPairs[peerId] == nil {
 // 注意：这里我们只能存储公钥，不能创建对应的私钥
 // 实际场景中，应该从密钥交换协议中获取
                logger.info("💾 存储对等节点公钥: \(peerId)")
            }
        }
 // 持久化到 Keychain，便于后续加载进行验签
        let raw = publicKey.rawRepresentation
 // KeychainManager 方法现在是 nonisolated 的，可以同步调用
        _ = KeychainManager.shared.storePeerSigningPublicKey(raw, peerId: peerId)
    }
    
 /// 验证签名 - 使用P256 ECDSA验证
 /// 注意：此方法仅用于P256公钥验证。如需PQC验证，请使用 verify(_:signature:for:) 方法
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名数据
 /// - publicKey: 公钥（P256）
 /// - Returns: 验证是否成功
    public func verify(_ data: Data, signature: Data, publicKey: P256.Signing.PublicKey) async throws -> Bool {
        logger.debug("✅ 验证签名（P256 ECDSA）")
        
        return cryptoLock.withLock { _ in
            do {
                let signature = try P256.Signing.ECDSASignature(rawRepresentation: signature)
                let isValid = publicKey.isValidSignature(signature, for: data)
                
                logger.debug("P256签名验证结果: \(isValid ? "✅ 有效" : "❌ 无效")")
                return isValid
            } catch {
                logger.error("❌ 签名验证失败: \(error)")
                return false
            }
        }
    }
    
 /// 验证签名（使用peerId查找公钥）- 优先使用PQC验证
    public func verify(_ data: Data, signature: Data, for peerId: String) async throws -> Bool {
 // 🔧 优化：优先使用PQC验证
        let enablePQC = await SettingsManager.shared.enablePQC
        let algorithm = await SettingsManager.shared.pqcSignatureAlgorithm
        
        if enablePQC {
            if #available(macOS 14.0, *), let provider = PQCProviderFactory.makeProvider() {
 // 尝试PQC验证
                let pqcValid = await provider.verify(data: data, signature: signature, peerId: peerId, algorithm: algorithm)
                if pqcValid {
                    logger.info("✅ PQC签名验证成功: \(algorithm), peerId: \(peerId)")
                    return true
                } else {
                    logger.debug("ℹ️ PQC验证失败，尝试P256验证")
                }
            }
        }
        
 // 回退到P256验证
        var publicKey = getPublicKey(for: peerId)
        if publicKey == nil {
 // 尝试从 Keychain 加载持久化的对端签名公钥
 // KeychainManager 方法现在是 nonisolated 的，可以同步调用
            if let raw = KeychainManager.shared.retrievePeerSigningPublicKey(peerId), let pk = try? P256.Signing.PublicKey(rawRepresentation: raw) {
                publicKey = pk
            }
        }
        guard let publicKey else {
            logger.error("❌ 未找到对等节点的公钥: \(peerId)")
            throw QuantumNetworkError.keyNotFound
        }
        
        return try await verify(data, signature: signature, publicKey: publicKey)
    }
    
 // MARK: - 未来扩展：后量子密码学
    
 /// 准备混合签名（传统+PQC）
 /// 使用P256作为传统签名，ML-DSA作为PQC签名
    public func hybridSign(_ data: Data, for peerId: String) async throws -> (classical: Data, pqc: Data?) {
 // 始终使用P256进行传统签名（不受enablePQC设置影响）
        let classical = try cryptoLock.withLock { _ in
            let keyPair = getOrCreateSigningKeyPair(for: peerId)
            let signature = try keyPair.private.signature(for: data)
            return signature.rawRepresentation
        }
        
        let enablePQC = await SettingsManager.shared.enablePQC
        let algorithm = await SettingsManager.shared.pqcSignatureAlgorithm
        if enablePQC {
            if #available(macOS 14.0, *), let provider = PQCProviderFactory.makeProvider() {
                do {
                    let pq = try await provider.sign(data: data, peerId: peerId, algorithm: algorithm)
                    logger.info("✅ PQC混合签名成功: 传统(\(classical.count)字节) + PQC(\(pq.count)字节)")
                    return (classical: classical, pqc: pq)
                } catch {
                    logger.warning("⚠️ PQC签名失败，回退传统签名: \(error.localizedDescription)")
                }
            } else {
                logger.info("ℹ️ 当前系统未检测到PQC提供者，使用传统签名")
            }
        }
        return (classical: classical, pqc: nil)
    }
    
 /// 验证混合签名
    public func verifyHybrid(_ data: Data, classicalSignature: Data, pqcSignature: Data?, peerId: String) async throws -> Bool {
 // 验证传统签名（P256）- 直接使用P256验证，不走PQC路径
        var publicKey = getPublicKey(for: peerId)
        if publicKey == nil {
 // 尝试从 Keychain 加载持久化的对端签名公钥
            if let raw = KeychainManager.shared.retrievePeerSigningPublicKey(peerId),
               let pk = try? P256.Signing.PublicKey(rawRepresentation: raw) {
                publicKey = pk
            }
        }
        guard let publicKey else {
            logger.error("❌ 混合签名验证失败：未找到对等节点的P256公钥: \(peerId)")
            throw QuantumNetworkError.keyNotFound
        }
        
        let classicalValid = try await verify(data, signature: classicalSignature, publicKey: publicKey)
        
        let enablePQC = await SettingsManager.shared.enablePQC
        let algorithm = await SettingsManager.shared.pqcSignatureAlgorithm
        if let pqcSig = pqcSignature, enablePQC {
            if #available(macOS 14.0, *), let provider = PQCProviderFactory.makeProvider() {
                let pqcValid = await provider.verify(data: data, signature: pqcSig, peerId: peerId, algorithm: algorithm)
                logger.info("🔍 混合签名验证: 传统=\(classicalValid), PQC=\(pqcValid)")
                return classicalValid && pqcValid
            }
        }
        return classicalValid
    }

 // MARK: - PQC实现（使用OQSBridge提供的ML-DSA算法）
 /// 执行PQC签名（根据算法选择），不可用时返回nil
    private func performPQCSign(data: Data, algorithm: String, peerId: String) async throws -> Data? {
        logger.info("🔐 尝试执行PQC签名: \(algorithm)")
        
 // 检查PQC提供者是否可用
        guard let provider = PQCProviderFactory.makeProvider() else {
            logger.warning("⚠️ PQC提供者不可用（liboqs未集成）")
            return nil
        }
        
        do {
            let signature = try await provider.sign(data: data, peerId: peerId, algorithm: algorithm)
            logger.info("✅ PQC签名成功: \(algorithm), 签名长度: \(signature.count)字节")
            return signature
        } catch {
            logger.error("❌ PQC签名失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 验证PQC签名（根据算法选择），不可用时返回false
    private func verifyPQC(data: Data, signature: Data, peerId: String, algorithm: String) async -> Bool {
        logger.info("🔍 尝试验证PQC签名: \(algorithm)")
        
 // 检查PQC提供者是否可用
        guard let provider = PQCProviderFactory.makeProvider() else {
            logger.warning("⚠️ PQC提供者不可用（liboqs未集成）")
            return false
        }
        
        let isValid = await provider.verify(data: data, signature: signature, peerId: peerId, algorithm: algorithm)
        logger.info("验证结果: \(isValid ? "✅ 有效" : "❌ 无效")")
        return isValid
    }
}
