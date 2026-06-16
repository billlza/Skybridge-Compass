import Foundation
import OSLog
#if canImport(CryptoKit)
import CryptoKit
#endif

/// PQC密钥迁移工具
/// 用于在OQS和Apple原生PQC之间迁移密钥
public class PQCKeyMigrationTool {
    
    private static let logger = Logger(subsystem: "com.skybridge.quantum", category: "PQCKeyMigration")
    
    public enum MigrationError: Error {
        case unsupportedPlatform
        case keyNotFound
        case migrationFailed(String)
        case backupFailed
    }
    
 /// 迁移策略
    public enum MigrationStrategy {
        case keepBothKeys      // 保留两个实现的密钥
        case replaceOQSKey     // 替换OQS密钥
        case testOnly          // 仅测试，不实际迁移
    }

 /// 确定性（可被 rollbackMigration 发现）的 OQS 私钥备份服务名。
 /// 旧实现用 `Date().timeIntervalSince1970` 拼接，导致备份无法被回滚定位——改为固定后缀。
    private static func oqsBackupService(_ algorithm: String) -> String {
        let param = algorithm == "ML-DSA-65" ? "65" : "87"
        return "\(PQCKeyTags.service("MLDSA", param, "Priv"))-backup-v1"
    }

 // MARK: - OQS到Apple迁移
    
 /// 将OQS密钥迁移到Apple CryptoKit格式
    @available(macOS 26.0, *)
    public static func migrateOQSToApple(
        peerId: String,
        algorithm: String,
        strategy: MigrationStrategy = .keepBothKeys
    ) async throws {
        #if HAS_APPLE_PQC_SDK
        
        logger.info("🔄 开始密钥迁移: \(peerId), 算法: \(algorithm)")
        
 // 1. 检查OQS密钥是否存在（testOnly 策略跳过此检查）
        let oqsPrivService = PQCKeyTags.service("MLDSA", algorithm == "ML-DSA-65" ? "65" : "87", "Priv")
        let _ = PQCKeyTags.service("MLDSA", algorithm == "ML-DSA-65" ? "65" : "87", "Pub")  // 公钥服务标识符
        
 // KeychainManager 方法是 nonisolated 的，不需要 await
        let oqsPrivKey = KeychainManager.shared.exportKey(service: oqsPrivService, account: peerId)
        
        if strategy != .testOnly {
            guard oqsPrivKey != nil else {
                throw MigrationError.keyNotFound
            }
            logger.info("✅ 找到OQS密钥")
        } else {
            logger.info("ℹ️ testOnly模式，跳过OQS密钥检查")
        }
        
 // 2. 创建备份（如果需要且密钥存在）
        if let key = oqsPrivKey, (strategy == .keepBothKeys || strategy == .replaceOQSKey) {
            let backupService = oqsBackupService(algorithm)
 // KeychainManager 方法是 nonisolated 的，不需要 await
            let success = KeychainManager.shared.importKey(
                data: key,
                service: backupService,
                account: peerId
            )
            if !success {
                throw MigrationError.backupFailed
            }
            logger.info("💾 OQS密钥已备份: \(backupService)")
        }

 // 3. 生成新的Apple原生密钥
 //    注意：这并非「转码」。OQS 的扩展私钥无法导入 Apple 基于种子(seed)的
 //    integrityCheckedRepresentation，因此迁移本质上是一次「重新生成身份(re-key)」。
 //    迁移完成后【必须】与对端重新建立信任(re-pin)，否则对端原先固定的旧公钥会拒绝新签名。
        let appleKey: Data
        let applePubKey: Data
        
        switch algorithm {
        case "ML-DSA-65":
            let key = try MLDSA65.PrivateKey()
            appleKey = key.integrityCheckedRepresentation
            applePubKey = key.publicKey.rawRepresentation
            
        case "ML-DSA-87":
            let key = try MLDSA87.PrivateKey()
            appleKey = key.integrityCheckedRepresentation
            applePubKey = key.publicKey.rawRepresentation
            
        default:
            throw MigrationError.migrationFailed("不支持的算法: \(algorithm)")
        }
        
        logger.info("🔑 生成Apple原生密钥")
        
 // 4. 存储Apple密钥
        let applePrivService = PQCKeyTags.service("Apple-MLDSA", algorithm == "ML-DSA-65" ? "65" : "87", "Mem")
        let applePubService = PQCKeyTags.service("Apple-MLDSA", algorithm == "ML-DSA-65" ? "65" : "87", "Pub")
        
        if strategy != .testOnly {
 // KeychainManager 方法是 nonisolated 的，不需要 await
            let privSuccess = KeychainManager.shared.importKey(
                data: appleKey,
                service: applePrivService,
                account: peerId
            )
            let pubSuccess = KeychainManager.shared.importKey(
                data: applePubKey,
                service: applePubService,
                account: peerId
            )
            
            guard privSuccess && pubSuccess else {
                throw MigrationError.migrationFailed("无法存储Apple密钥")
            }
            
            logger.info("✅ Apple密钥已存储")
        }
        
 // 5. 根据策略处理OQS密钥
        if strategy == .replaceOQSKey && strategy != .testOnly {
 // 删除OQS密钥（保留备份）
 // 注意：KeychainManager的importKey会自动删除旧密钥，这里标记为已删除
            logger.info("🗑️ OQS密钥将在下次导入时被替换（已备份）")
        }
        
        logger.info("🎉 密钥迁移完成: \(peerId)")
        
 // 6. 发送迁移完成通知
        NotificationCenter.default.post(
            name: .pqcKeyMigrated,
            object: nil,
            userInfo: [
                "peerId": peerId,
                "algorithm": algorithm,
                "provider": "Apple CryptoKit",
 // 迁移是一次 re-key（身份变更）：调用方据此触发与对端的重新配对/信任刷新。
                "requiresRePinning": true
            ]
        )
        #else
        throw MigrationError.unsupportedPlatform
        #endif
    }
    
 // MARK: - 批量迁移
    
 /// 批量迁移所有OQS密钥到Apple
    @available(macOS 26.0, *)
    public static func migrateAllKeys(
        strategy: MigrationStrategy = .keepBothKeys
    ) async -> MigrationReport {
        
        var report = MigrationReport()
        
 // 获取所有需要迁移的peerId（这需要从某处获取）
 // 这里简化为示例
        let algorithms = ["ML-DSA-65", "ML-DSA-87"]
        
        for algorithm in algorithms {
 // 实际实现需要获取所有使用该算法的peerId
 // 这里只是演示框架
            logger.info("准备迁移算法: \(algorithm)")
            report.totalAlgorithms += 1
        }
        
        return report
    }
    
 // MARK: - 验证和测试
    
 /// 验证迁移后的密钥是否正常工作
    @available(macOS 26.0, *)
    public static func verifyMigratedKey(
        peerId: String,
        algorithm: String
    ) async throws -> Bool {
        #if HAS_APPLE_PQC_SDK
        
        logger.info("🔍 验证迁移后的密钥: \(peerId)")
        
        let testMessage = "Migration Test Message".utf8Data
        
 // 使用Apple密钥签名
        let applePrivService = PQCKeyTags.service("Apple-MLDSA", algorithm == "ML-DSA-65" ? "65" : "87", "Mem")
 // KeychainManager 方法是 nonisolated 的，不需要 await
        guard let appleKeyData = KeychainManager.shared.exportKey(service: applePrivService, account: peerId) else {
            throw MigrationError.keyNotFound
        }
        
        switch algorithm {
        case "ML-DSA-65":
            let key = try MLDSA65.PrivateKey(integrityCheckedRepresentation: appleKeyData)
            let signature = try key.signature(for: testMessage)
            
 // 验证签名
            let isValid = key.publicKey.isValidSignature(signature, for: testMessage)
            logger.info("ML-DSA-65验证结果: \(isValid ? "✅" : "❌")")
            return isValid
            
        case "ML-DSA-87":
            let key = try MLDSA87.PrivateKey(integrityCheckedRepresentation: appleKeyData)
            let signature = try key.signature(for: testMessage)
            
            let isValid = key.publicKey.isValidSignature(signature, for: testMessage)
            logger.info("ML-DSA-87验证结果: \(isValid ? "✅" : "❌")")
            return isValid
            
        default:
            throw MigrationError.migrationFailed("不支持的算法: \(algorithm)")
        }
        #else
        throw MigrationError.unsupportedPlatform
        #endif
    }
    
 // MARK: - 回滚
    
 /// 回滚迁移（从备份恢复OQS密钥）
    public static func rollbackMigration(
        peerId: String,
        algorithm: String
    ) async throws {
        
        logger.info("↩️ 回滚迁移: \(peerId)")

        let oqsPrivService = PQCKeyTags.service("MLDSA", algorithm == "ML-DSA-65" ? "65" : "87", "Priv")
        let backupService = oqsBackupService(algorithm)

 // 1) 从确定性命名的备份恢复 OQS 私钥（不再是 no-op 桩）
        guard let backup = KeychainManager.shared.exportKey(service: backupService, account: peerId) else {
            logger.error("❌ 未找到可回滚的 OQS 备份: \(backupService)")
            throw MigrationError.keyNotFound
        }
        guard KeychainManager.shared.importKey(data: backup, service: oqsPrivService, account: peerId) else {
            throw MigrationError.migrationFailed("无法从备份恢复 OQS 私钥")
        }

 // 2) 移除迁移期间生成的 Apple 密钥，使后续 provider 选择回退到 OQS（best-effort）
        let param = algorithm == "ML-DSA-65" ? "65" : "87"
        try? KeychainManager.shared.deleteAPIKey(
            service: PQCKeyTags.service("Apple-MLDSA", param, "Mem"), account: peerId)
        try? KeychainManager.shared.deleteAPIKey(
            service: PQCKeyTags.service("Apple-MLDSA", param, "Pub"), account: peerId)

 // 3) 通知调用方：身份已回退到 OQS，仍需与对端重新建立信任(re-pin)
        NotificationCenter.default.post(
            name: .pqcKeyMigrated,
            object: nil,
            userInfo: [
                "peerId": peerId,
                "algorithm": algorithm,
                "provider": "OQS/liboqs",
                "rolledBack": true,
                "requiresRePinning": true
            ]
        )
        logger.info("✅ 迁移已回滚，已从备份恢复 OQS 私钥")
    }
}

// MARK: - 数据模型

extension Notification.Name {
    public static let pqcKeyMigrated = Notification.Name("PQCKeyMigrated")
}

/// 迁移报告
public struct MigrationReport {
    public var totalAlgorithms: Int = 0
    public var successCount: Int = 0
    public var failureCount: Int = 0
    public var errors: [String] = []
    
    public var isSuccess: Bool {
        return failureCount == 0 && totalAlgorithms > 0
    }
    
    public func summary() -> String {
        return """
        === PQC密钥迁移报告 ===
        总算法数: \(totalAlgorithms)
        成功: \(successCount)
        失败: \(failureCount)
        状态: \(isSuccess ? "✅ 成功" : "❌ 部分失败")
        """
    }
}
