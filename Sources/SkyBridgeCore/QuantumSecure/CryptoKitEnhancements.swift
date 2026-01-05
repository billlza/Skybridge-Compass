import Foundation
import CryptoKit
import OSLog
import os.lock

/// CryptoKit 增强功能
/// 基于Apple 2025最佳实践
public class CryptoKitEnhancements {
    
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "CryptoKitEnhancements")
    private let lock = OSAllocatedUnfairLock<[String: SessionKeyInfo]>(initialState: [:])
    
 // MARK: - 会话密钥信息结构
    
    public struct SessionKeyInfo: Sendable {
        public let sessionKey: SymmetricKey
        public let derivedAt: Date
        public let keyId: String
        
        public init(sessionKey: SymmetricKey, derivedAt: Date = Date(), keyId: String = UUID().uuidString) {
            self.sessionKey = sessionKey
            self.derivedAt = derivedAt
            self.keyId = keyId
        }
    }
    
 // MARK: - 1. HKDF 密钥派生（会话密钥管理）
    
 /// 使用HKDF从主密钥派生会话密钥
 /// HKDF (HMAC-based Key Derivation Function) 是NIST推荐的密钥派生方法
    public static func deriveSessionKey(
        from masterKey: SymmetricKey,
        salt: Data? = nil,
        info: Data? = nil,
        outputLength: Int = 32 // 256位
    ) throws -> SymmetricKey {
        let logger = Logger(subsystem: "com.skybridge.quantum", category: "HKDF")
        
        logger.info("🔑 使用HKDF派生会话密钥")
        
 // 使用SHA256作为哈希函数
        let hkdf = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt ?? Data(),
            info: info ?? "quantum-session-key".utf8Data,
            outputByteCount: outputLength
        )
        
        logger.info("✅ 会话密钥派生成功，长度: \(outputLength) 字节（\(outputLength * 8)位）")
        return hkdf
    }
    
 /// 为特定会话派生密钥
    public static func deriveSessionKey(
        for sessionId: String,
        from masterKey: SymmetricKey,
        salt: Data? = nil
    ) throws -> SymmetricKey {
 // 使用会话ID作为info
        let info = "session-\(sessionId)".utf8Data
        return try deriveSessionKey(
            from: masterKey,
            salt: salt,
            info: info
        )
    }
    
 /// 批量派生多个会话密钥（用于并行处理）
    public static func deriveMultipleSessionKeys(
        count: Int,
        from masterKey: SymmetricKey,
        salt: Data? = nil
    ) throws -> [SymmetricKey] {
        let logger = Logger(subsystem: "com.skybridge.quantum", category: "HKDF")
        logger.info("🔑 批量派生 \(count) 个会话密钥")
        
        return try (0..<count).map { index in
            let info = "session-batch-\(index)".utf8Data
            return try deriveSessionKey(
                from: masterKey,
                salt: salt,
                info: info
            )
        }
    }
    
 // MARK: - 2. 密钥轮换策略
    
 /// 密钥轮换管理器
    public class KeyRotationManager: @unchecked Sendable {
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "KeyRotation")
        private let keyInfoLock = OSAllocatedUnfairLock<[String: SessionKeyInfo]>(initialState: [:])
        
 // 轮换策略配置
        public struct RotationPolicy {
            public let maxKeyAge: TimeInterval // 密钥最大寿命（秒）
            public let maxUsageCount: Int? // 最大使用次数（可选）
            public let preRotationInterval: TimeInterval // 预轮换时间间隔
            
            public static var `default`: RotationPolicy {
                RotationPolicy(
                    maxKeyAge: 3600, // 1小时
                    maxUsageCount: nil,
                    preRotationInterval: 300 // 5分钟前预轮换
                )
            }
            
            public init(
                maxKeyAge: TimeInterval = 3600,
                maxUsageCount: Int? = nil,
                preRotationInterval: TimeInterval = 300
            ) {
                self.maxKeyAge = maxKeyAge
                self.maxUsageCount = maxUsageCount
                self.preRotationInterval = preRotationInterval
            }
        }
        
        private let policy: RotationPolicy
        private var usageCounts: [String: Int] = [:]
        
        public init(policy: RotationPolicy = .default) {
            self.policy = policy
        }
        
 /// 检查密钥是否需要轮换
        public func shouldRotateKey(for sessionId: String) -> Bool {
            return keyInfoLock.withLock { keyInfos in
                guard let keyInfo = keyInfos[sessionId] else {
 // 没有密钥，需要生成
                    return true
                }
                
 // 检查密钥年龄
                let age = Date().timeIntervalSince(keyInfo.derivedAt)
                if age >= policy.maxKeyAge {
                    logger.info("⏰ 密钥 \(sessionId) 已过期（\(Int(age))秒）")
                    return true
                }
                
 // 检查是否接近过期（预轮换）
                if age >= (policy.maxKeyAge - policy.preRotationInterval) {
                    logger.info("⏳ 密钥 \(sessionId) 即将过期，建议预轮换")
 // 返回true以触发预轮换
                    return true
                }
                
 // 检查使用次数（如果启用）
                if let maxUsage = policy.maxUsageCount {
                    let count = usageCounts[sessionId] ?? 0
                    if count >= maxUsage {
                        logger.info("🔢 密钥 \(sessionId) 已达到最大使用次数（\(count)）")
                        return true
                    }
                }
                
                return false
            }
        }
        
 /// 轮换密钥
        public func rotateKey(
            for sessionId: String,
            masterKey: SymmetricKey,
            salt: Data? = nil
        ) throws -> SymmetricKey {
            logger.info("🔄 轮换密钥: \(sessionId)")
            
 // 派生新密钥
            let newSessionKey = try CryptoKitEnhancements.deriveSessionKey(
                for: sessionId,
                from: masterKey,
                salt: salt
            )
            
 // 更新密钥信息
            let keyInfo = SessionKeyInfo(sessionKey: newSessionKey)
            keyInfoLock.withLock { keyInfos in
                keyInfos[sessionId] = keyInfo
            }
            
 // 重置使用计数
            usageCounts[sessionId] = 0
            
            logger.info("✅ 密钥轮换完成: \(sessionId)")
            return newSessionKey
        }
        
 /// 记录密钥使用
        public func recordKeyUsage(for sessionId: String) {
            usageCounts[sessionId] = (usageCounts[sessionId] ?? 0) + 1
        }
        
 /// 获取当前密钥
        public func getCurrentKey(for sessionId: String) -> SymmetricKey? {
            return keyInfoLock.withLock { keyInfos in
                return keyInfos[sessionId]?.sessionKey
            }
        }
    }
    
 // MARK: - 3. 前向安全（Forward Secrecy）
    
 /// 前向安全密钥交换
 /// 使用Diffie-Hellman密钥交换实现前向安全
    public class ForwardSecrecyManager {
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "ForwardSecrecy")
        
 // 存储每个会话的临时密钥对
        private let ephemeralKeysLock = OSAllocatedUnfairLock<[String: P256.KeyAgreement.PrivateKey]>(initialState: [:])
        
 /// 生成临时密钥对（用于密钥交换）
        public func generateEphemeralKeyPair(for sessionId: String) -> P256.KeyAgreement.PrivateKey {
            logger.info("🔑 为会话 \(sessionId) 生成临时密钥对（前向安全）")
            
            let privateKey = P256.KeyAgreement.PrivateKey()
            
            ephemeralKeysLock.withLock { ephemeralKeys in
                ephemeralKeys[sessionId] = privateKey
            }
            
            return privateKey
        }
        
 /// 执行密钥交换（ECDH）
 /// 从本地临时私钥和远程公钥派生共享密钥
        public func performKeyExchange(
            sessionId: String,
            remotePublicKey: P256.KeyAgreement.PublicKey
        ) throws -> SymmetricKey {
            logger.info("🤝 执行密钥交换: \(sessionId)")
            
 // 获取临时私钥
            guard let localPrivateKey = ephemeralKeysLock.withLock({ ephemeralKeys in
                ephemeralKeys[sessionId]
            }) else {
                logger.error("❌ 找不到临时私钥: \(sessionId)")
                throw NSError(domain: "ForwardSecrecy", code: 1, userInfo: [NSLocalizedDescriptionKey: "临时密钥未找到"])
            }
            
 // 执行密钥协商
            let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
            
 // 派生会话密钥
            let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(),
                sharedInfo: "quantum-forward-secrecy".utf8Data,
                outputByteCount: 32
            )
            
            logger.info("✅ 密钥交换成功，已派生会话密钥")
            
 // 清理临时私钥（前向安全：一旦使用立即删除）
 // removeValue 返回被删除的值（可选类型），我们不需要它，明确忽略
            _ = ephemeralKeysLock.withLock { ephemeralKeys in
                ephemeralKeys.removeValue(forKey: sessionId)
            }
            logger.info("🗑️ 已清理临时私钥（前向安全）")
            
            return sessionKey
        }
        
 /// 清理所有临时密钥
        public func clearAllEphemeralKeys() {
            logger.info("🧹 清理所有临时密钥")
            ephemeralKeysLock.withLock { ephemeralKeys in
                ephemeralKeys.removeAll()
            }
        }
    }
    
 // MARK: - 组合使用示例
    
 /// 创建完整的密钥管理方案
 /// 结合HKDF、密钥轮换和前向安全
    public static func createCompleteKeyManager(
        masterKey: SymmetricKey? = nil
    ) -> (keyManager: EnhancedQuantumKeyManager, rotationManager: KeyRotationManager, forwardSecrecyManager: ForwardSecrecyManager) {
        let keyManager = EnhancedQuantumKeyManager()
        let rotationManager = KeyRotationManager()
        let forwardSecrecyManager = ForwardSecrecyManager()
        
        return (keyManager, rotationManager, forwardSecrecyManager)
    }
}

