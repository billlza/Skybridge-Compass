import Foundation
import Security
import LocalAuthentication
import CryptoKit
import OSLog

/// Security Framework 增强功能
/// 基于Apple 2025最佳实践
public class SecurityFrameworkEnhancements {
    
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "SecurityEnhancements")
    
 // MARK: - 1. Secure Enclave 集成（私钥保护）
    
 /// Secure Enclave 密钥管理器
 /// 在支持的设备上使用Secure Enclave存储私钥
    public class SecureEnclaveManager {
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "SecureEnclave")
        
 /// 检查设备是否支持Secure Enclave
        public static func isSecureEnclaveAvailable() -> Bool {
 // Secure Enclave在iPhone 6s及之后和Mac with T2/Apple Silicon上可用
            #if os(macOS)
 // macOS上需要检查是否有Secure Enclave（T2芯片或Apple Silicon）
            return true // 简化：假设Apple Silicon设备都有
            #elseif os(iOS)
            return true // iOS设备通常都有Secure Enclave
            #else
            return false
            #endif
        }
        
 /// 在Secure Enclave中创建P256密钥对
        public func createSecureEnclaveKeyPair(
            tag: String,
            accessControl: SecAccessControl
        ) throws -> (publicKey: P256.Signing.PublicKey, privateKeyRef: SecKey) {
            logger.info("🔐 在Secure Enclave中创建密钥对: \(tag)")
            
            guard Self.isSecureEnclaveAvailable() else {
                throw NSError(domain: "SecureEnclave", code: 1, userInfo: [NSLocalizedDescriptionKey: "Secure Enclave不可用"])
            }
            
 // 删除旧密钥（如果存在）
            try? deleteSecureEnclaveKey(tag: tag)
            
 // 创建密钥属性
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave, // 关键：指定使用Secure Enclave
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: tag.utf8Data,
                    kSecAttrAccessControl as String: accessControl
                ]
            ]
            
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                let errorDescription = error?.takeRetainedValue().localizedDescription ?? "未知错误"
                logger.error("❌ 创建Secure Enclave密钥失败: \(errorDescription)")
                throw NSError(domain: "SecureEnclave", code: 2, userInfo: [NSLocalizedDescriptionKey: errorDescription])
            }
            
 // 获取公钥
            guard let publicKeyRef = SecKeyCopyPublicKey(privateKey) else {
                throw NSError(domain: "SecureEnclave", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法获取公钥"])
            }
            
 // 将SecKey转换为P256公钥
            guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKeyRef, nil) as Data?,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData) else {
                throw NSError(domain: "SecureEnclave", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法转换公钥格式"])
            }
            
            logger.info("✅ Secure Enclave密钥对创建成功")
            return (publicKey, privateKey)
        }
        
 /// 从Secure Enclave加载私钥
        public func loadSecureEnclavePrivateKey(tag: String) throws -> SecKey {
            logger.info("🔍 从Secure Enclave加载私钥: \(tag)")
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag.utf8Data,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecReturnData as String: false
            ]
            
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let anyItem = result, CFGetTypeID(anyItem) == SecKeyGetTypeID() else {
                logger.error("❌ 无法加载Secure Enclave私钥: \(status)")
                throw NSError(domain: "SecureEnclave", code: 5, userInfo: [NSLocalizedDescriptionKey: "密钥未找到或类型不匹配"])
            }
            let privateKey = unsafeDowncast(anyItem, to: SecKey.self)
            
            logger.info("✅ 已从Secure Enclave加载私钥")
            return privateKey
        }
        
 /// 使用Secure Enclave私钥签名
        public func signWithSecureEnclave(
            data: Data,
            privateKeyRef: SecKey,
            algorithm: SecKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
        ) throws -> Data {
            logger.info("✍️ 使用Secure Enclave私钥签名")
            
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                privateKeyRef,
                algorithm,
                data as CFData,
                &error
            ) as Data? else {
                let errorDescription = error?.takeRetainedValue().localizedDescription ?? "未知错误"
                logger.error("❌ 签名失败: \(errorDescription)")
                throw NSError(domain: "SecureEnclave", code: 6, userInfo: [NSLocalizedDescriptionKey: errorDescription])
            }
            
            logger.info("✅ 签名成功")
            return signature
        }
        
 /// 删除Secure Enclave密钥
        public func deleteSecureEnclaveKey(tag: String) throws {
            logger.info("🗑️ 删除Secure Enclave密钥: \(tag)")
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag.utf8Data
            ]
            
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                logger.error("❌ 删除失败: \(status)")
                throw NSError(domain: "SecureEnclave", code: 7, userInfo: [NSLocalizedDescriptionKey: "删除失败"])
            }
            
            logger.info("✅ 密钥已删除")
        }
    }
    
 // MARK: - 2. 访问控制策略
    
 /// 创建访问控制策略
    public static func createAccessControl(
        requireBiometry: Bool = false,
        requireDevicePasscode: Bool = true,
        accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) throws -> SecAccessControl {
        logger.info("🔒 创建访问控制策略（生物识别: \(requireBiometry), 设备密码: \(requireDevicePasscode)）")
        
        var flags: SecAccessControlCreateFlags = []
        
        if requireBiometry {
            flags.insert(.biometryAny)
        }
        
        if requireDevicePasscode {
            flags.insert(.devicePasscode)
        }
        
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            accessibility,
            flags,
            &error
        ) else {
            let errorDescription = error?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw NSError(domain: "AccessControl", code: 1, userInfo: [NSLocalizedDescriptionKey: errorDescription])
        }
        
        logger.info("✅ 访问控制策略已创建")
        return accessControl
    }
    
    private static let logger = Logger(subsystem: "com.skybridge.quantum", category: "AccessControl")
    
 // MARK: - 3. 生物识别认证集成
    
 /// 生物识别认证管理器
    public class BiometricAuthenticationManager {
        private let context = LAContext()
        private let logger = Logger(subsystem: "com.skybridge.quantum", category: "BiometricAuth")
        
 /// 检查生物识别可用性
        public func canEvaluateBiometry() -> (available: Bool, type: LABiometryType?, error: Error?) {
            var error: NSError?
            let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            let biometryType = canEvaluate ? context.biometryType : nil
            
            return (canEvaluate, biometryType, error)
        }
        
 /// 使用生物识别认证
        public func authenticateWithBiometry(reason: String = "访问量子安全密钥") async throws -> Bool {
            logger.info("👆 开始生物识别认证")
            
            let (available, biometryType, error) = canEvaluateBiometry()
            
            guard available else {
                let errorDescription = error?.localizedDescription ?? "生物识别不可用"
                logger.error("❌ 生物识别不可用: \(errorDescription)")
                throw NSError(domain: "BiometricAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: errorDescription])
            }
            
            let biometryName = biometryType == .faceID ? "Face ID" : (biometryType == .touchID ? "Touch ID" : "生物识别")
            logger.info("✅ 使用 \(biometryName) 进行认证")
            
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                )
                
                if success {
                    logger.info("✅ 生物识别认证成功")
                } else {
                    logger.warning("⚠️ 生物识别认证失败（用户取消或其他原因）")
                }
                
                return success
            } catch {
                logger.error("❌ 生物识别认证错误: \(error.localizedDescription)")
                throw error
            }
        }
        
 /// 使用设备密码认证（备用方案）
        public func authenticateWithDevicePasscode(reason: String = "访问量子安全密钥") async throws -> Bool {
            logger.info("🔑 使用设备密码认证")
            
            let context = LAContext()
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
                
                if success {
                    logger.info("✅ 设备密码认证成功")
                }
                
                return success
            } catch {
                logger.error("❌ 设备密码认证错误: \(error.localizedDescription)")
                throw error
            }
        }
        
 /// 组合认证：先尝试生物识别，失败则使用设备密码
        public func authenticateWithFallback(reason: String = "访问量子安全密钥") async throws -> Bool {
            logger.info("🔄 尝试组合认证")
            
 // 先尝试生物识别
            let biometryResult = canEvaluateBiometry()
            if biometryResult.available {
                do {
                    return try await authenticateWithBiometry(reason: reason)
                } catch {
                    logger.info("⚠️ 生物识别失败，回退到设备密码")
                }
            }
            
 // 回退到设备密码
            return try await authenticateWithDevicePasscode(reason: reason)
        }
    }
}
