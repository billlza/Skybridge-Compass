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

/// A strict-PQC signature together with the exact algorithm that produced it.
/// Keeping these values together prevents metadata from observing a different
/// mutable setting between algorithm selection and signature generation.
public struct PQCRequiredSignature: Sendable, Equatable {
    public let bytes: Data
    public let algorithm: String

    public init(bytes: Data, algorithm: String) {
        self.bytes = bytes
        self.algorithm = algorithm
    }
}

public enum EnhancedPostQuantumCryptoError: Error, LocalizedError, Sendable, Equatable {
    case pqcDisabled
    case invalidPQCSignatureAlgorithm(String)
    case pqcProviderUnavailable
    case pqcSigningFailed(algorithm: String)
    case pqcSignatureRequired
    case authenticatedRemoteSigningKeyUnavailable
    case authenticatedRemoteSigningKeyAmbiguous
    case authenticatedRemoteSigningKeyInvalid
    case productionSignatureAlgorithmUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .pqcDisabled:
            return "PQC is disabled by the active security policy"
        case .invalidPQCSignatureAlgorithm(let value):
            return "Unsupported PQC signature algorithm: \(value)"
        case .pqcProviderUnavailable:
            return "A required PQC provider is unavailable"
        case .pqcSigningFailed(let algorithm):
            return "PQC signing failed for \(algorithm)"
        case .pqcSignatureRequired:
            return "A PQC signature is required while PQC is enabled"
        case .authenticatedRemoteSigningKeyUnavailable:
            return "No authenticated remote PQC signing key is available"
        case .authenticatedRemoteSigningKeyAmbiguous:
            return "Multiple authenticated remote PQC signing keys match the peer identity"
        case .authenticatedRemoteSigningKeyInvalid:
            return "The authenticated remote PQC signing key does not satisfy the trust contract"
        case .productionSignatureAlgorithmUnsupported(let algorithm):
            return "The production identity trust contract does not support \(algorithm)"
        }
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
    private let deviceIdentityKeyManager: DeviceIdentityKeyManager
    private let committedLocalIdentityLoader: @Sendable () async throws -> CommittedLocalProtocolIdentitySnapshot
    private let pqcEnabledLoader: @Sendable () async -> Bool

    public init() {
        let keyManager = DeviceIdentityKeyManager.shared
        deviceIdentityKeyManager = keyManager
        committedLocalIdentityLoader = {
            try await CommittedLocalProtocolIdentitySnapshot.loadActive(
                keyManager: keyManager
            )
        }
        pqcEnabledLoader = {
            await MainActor.run { SettingsManager.shared.enablePQC }
        }
    }

    init(deviceIdentityKeyManager: DeviceIdentityKeyManager) {
        self.deviceIdentityKeyManager = deviceIdentityKeyManager
        committedLocalIdentityLoader = {
            try await CommittedLocalProtocolIdentitySnapshot.loadActive(
                keyManager: deviceIdentityKeyManager
            )
        }
        pqcEnabledLoader = {
            await MainActor.run { SettingsManager.shared.enablePQC }
        }
    }

    init(
        deviceIdentityKeyManager: DeviceIdentityKeyManager,
        committedLocalIdentityLoader: @escaping @Sendable () async throws -> CommittedLocalProtocolIdentitySnapshot,
        pqcEnabledLoader: @escaping @Sendable () async -> Bool = {
            await MainActor.run { SettingsManager.shared.enablePQC }
        }
    ) {
        self.deviceIdentityKeyManager = deviceIdentityKeyManager
        self.committedLocalIdentityLoader = committedLocalIdentityLoader
        self.pqcEnabledLoader = pqcEnabledLoader
    }
    
 // MARK: - 并发安全的状态管理
    
 /// 加密/解密操作锁
    private let cryptoLock = OSAllocatedUnfairLock<Void>(initialState: ())
    
 /// 密钥对管理（封装在锁内，每个对等节点一个密钥对）
 /// 所有访问必须通过 signingLock.withLock { } 进行
    private let signingLock = OSAllocatedUnfairLock<[String: (private: P256.Signing.PrivateKey, public: P256.Signing.PublicKey)]>(initialState: [:])

    /// Provider instances own local key state. Keep that state scoped to this
    /// crypto instance, resolve it lazily, and never share it through a global cache.

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
    
 /// 签名数据。启用 PQC 时必须生成 PQC 签名；只有显式关闭 PQC 时才使用 P256。
 /// - Parameters:
 /// - data: 要签名的数据
 /// - peerId: 对等节点ID（用于密钥管理）
 /// - Returns: 签名数据
    public func sign(_ data: Data, for peerId: String) async throws -> Data {
        if await pqcEnabledLoader() {
            let identity = try await committedLocalIdentityLoader()
            return try await signWithProtocolIdentity(data, identity: identity)
        }

        logger.debug("✍️ PQC 已显式关闭；使用 P256 ECDSA 签名")
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

    /// Strict-PQC signing path for production data-transfer metadata.
    /// This deliberately fails closed instead of returning a P-256 signature.
    public func signPQCRequired(_ data: Data, for peerId: String) async throws -> Data {
        try await signPQCRequiredWithAlgorithm(data, for: peerId).bytes
    }

    /// Strict signing variant for protocols that must bind the emitted algorithm
    /// and signature into one immutable metadata snapshot.
    public func signPQCRequiredWithAlgorithm(
        _ data: Data,
        for peerId: String
    ) async throws -> PQCRequiredSignature {
        guard await pqcEnabledLoader() else {
            logger.error("❌ Strict-PQC 签名失败：PQC 已被本地设置关闭")
            throw EnhancedPostQuantumCryptoError.pqcDisabled
        }

        let identity = try await committedLocalIdentityLoader()
        let signature = try await signWithProtocolIdentity(data, identity: identity)
        return PQCRequiredSignature(
            bytes: signature,
            algorithm: identity.algorithm.rawValue
        )
    }

    /// Strict-PQC verification path for production data-transfer metadata.
    /// This requires an explicit ML-DSA metadata algorithm and never falls back to P-256.
    public func verifyPQCRequired(
        _ data: Data,
        signature: Data,
        for peerId: String,
        algorithm rawAlgorithm: String?
    ) async throws -> Bool {
        guard await pqcEnabledLoader() else {
            logger.error("❌ Strict-PQC 验签失败：PQC 已被本地设置关闭")
            throw EnhancedPostQuantumCryptoError.pqcDisabled
        }

        let algorithm = try Self.requiredPQCProtocolSigningAlgorithm(rawAlgorithm)

        let verified = try await verifyWithAuthenticatedProtocolIdentity(
            data,
            signature: signature,
            peerId: peerId,
            algorithm: algorithm
        )
        if verified {
            logger.info("✅ Strict-PQC 验签成功: \(algorithm.rawValue, privacy: .public)")
        } else {
            logger.error("❌ Strict-PQC 验签失败: \(algorithm.rawValue, privacy: .public)")
        }
        return verified
    }

    private func signWithProtocolIdentity(
        _ data: Data,
        identity: CommittedLocalProtocolIdentitySnapshot
    ) async throws -> Data {
        guard identity.algorithm == .mlDSA65 || identity.algorithm == .mlDSA87 else {
            throw EnhancedPostQuantumCryptoError.productionSignatureAlgorithmUnsupported(
                identity.algorithm.rawValue
            )
        }
        do {
            return try await PQCSignatureProvider(algorithm: identity.algorithm)
                .sign(data, key: identity.keyHandle)
        } catch let error as EnhancedPostQuantumCryptoError {
            throw error
        } catch {
            let nsError = error as NSError
            logger.error(
                "❌ Protocol-identity PQC signing failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
            )
            throw EnhancedPostQuantumCryptoError.pqcSigningFailed(
                algorithm: identity.algorithm.rawValue
            )
        }
    }

    private func verifyWithAuthenticatedProtocolIdentity(
        _ data: Data,
        signature: Data,
        peerId: String,
        algorithm: ProtocolSigningAlgorithm
    ) async throws -> Bool {
        guard algorithm == .mlDSA65 || algorithm == .mlDSA87 else {
            throw EnhancedPostQuantumCryptoError.productionSignatureAlgorithmUnsupported(
                algorithm.rawValue
            )
        }
        let publicKey = try await authenticatedRemoteProtocolSigningKey(
            for: peerId,
            algorithm: algorithm
        )
        do {
            return try await PQCSignatureProvider(algorithm: algorithm).verify(
                data,
                signature: signature,
                publicKey: publicKey
            )
        } catch {
            let nsError = error as NSError
            logger.error(
                "❌ Authenticated protocol-identity PQC verification failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
            )
            throw EnhancedPostQuantumCryptoError.authenticatedRemoteSigningKeyInvalid
        }
    }

    private func authenticatedRemoteProtocolSigningKey(
        for peerId: String,
        algorithm: ProtocolSigningAlgorithm
    ) async throws -> Data {
        guard let validatedPeerId = try? PQCIdentityToken.validated(peerId) else {
            throw EnhancedPostQuantumCryptoError.authenticatedRemoteSigningKeyUnavailable
        }

        let records = await TrustSyncService.shared.getActiveTrustRecords()
        return try Self.validatedAuthenticatedRemoteProtocolSigningKey(
            records: records,
            peerId: validatedPeerId,
            algorithm: algorithm
        )
    }

    internal static func validatedAuthenticatedRemoteProtocolSigningKey(
        records: [TrustRecord],
        peerId: String
    ) throws -> Data {
        try validatedAuthenticatedRemoteProtocolSigningKey(
            records: records,
            peerId: peerId,
            algorithm: .mlDSA65
        )
    }

    internal static func validatedAuthenticatedRemoteProtocolSigningKey(
        records: [TrustRecord],
        peerId: String,
        algorithm: ProtocolSigningAlgorithm
    ) throws -> Data {
        guard algorithm == .mlDSA65 || algorithm == .mlDSA87 else {
            throw EnhancedPostQuantumCryptoError.productionSignatureAlgorithmUnsupported(
                algorithm.rawValue
            )
        }
        guard let validatedPeerId = try? PQCIdentityToken.validated(peerId) else {
            throw EnhancedPostQuantumCryptoError.authenticatedRemoteSigningKeyUnavailable
        }
        let lookupCandidates = Set(
            PeerTrustLookup.lookupCandidates(
                primary: validatedPeerId,
                persistent: PeerTrustLookup.persistentDeviceId(from: validatedPeerId)
            )
        )
        let lowercasedCandidates = Set(lookupCandidates.map { $0.lowercased() })
        let matchedKeys = records.compactMap { record -> Data? in
            guard record.isAuthenticationEligible,
                  PeerTrustLookup.recordMatches(
                    record,
                    candidates: lookupCandidates,
                    candidateLowercased: lowercasedCandidates
                  ) else {
                return nil
            }
            if let exactBinding = record.authenticatedProtocolIdentityBinding(for: algorithm) {
                return exactBinding.publicKey
            }
            guard algorithm == .mlDSA65,
                  record.protocolSigningAlgorithm == .mlDSA65,
                  let publicKey = record.protocolPublicKey,
                  publicKey.count == 1_952 else {
                return nil
            }
            let fingerprint = ProtocolIdentityBinding.computeFingerprint(
                algorithm: .mlDSA65,
                publicKeyBytes: publicKey
            )
            guard record.currentPathAuthorityPins.contains(where: { pin in
                pin.algorithm == .mlDSA65
                    && pin.fingerprint == fingerprint
                    && pin.source != .legacyMigration
            }) else {
                return nil
            }
            return publicKey
        }

        let distinctKeys = Set(matchedKeys)
        guard !distinctKeys.isEmpty else {
            throw EnhancedPostQuantumCryptoError.authenticatedRemoteSigningKeyUnavailable
        }
        guard distinctKeys.count == 1, let publicKey = distinctKeys.first else {
            throw EnhancedPostQuantumCryptoError.authenticatedRemoteSigningKeyAmbiguous
        }
        return publicKey
    }

    /// Canonicalizes the deliberately small set of signature identifiers that
    /// can reach a PQC provider. Kept internal so tests can verify this security
    /// boundary directly even though SettingsManager rejects invalid runtime
    /// assignments before an operation is dispatched.
    internal static func requiredPQCSignatureAlgorithm(_ rawValue: String?) throws -> String {
        try requiredPQCProtocolSigningAlgorithm(rawValue).rawValue
    }

    private static func requiredPQCProtocolSigningAlgorithm(
        _ rawValue: String?
    ) throws -> ProtocolSigningAlgorithm {
        guard let rawValue else {
            throw EnhancedPostQuantumCryptoError.invalidPQCSignatureAlgorithm("<missing>")
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ML-DSA", "ML-DSA-65", "MLDSA", "MLDSA-65":
            return .mlDSA65
        case "ML-DSA-87", "MLDSA-87":
            return .mlDSA87
        default:
            throw EnhancedPostQuantumCryptoError.invalidPQCSignatureAlgorithm(rawValue)
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
    
    /// 验证签名。启用 PQC 时绝不回退到 P256。
    public func verify(_ data: Data, signature: Data, for peerId: String) async throws -> Bool {
        if await pqcEnabledLoader() {
            let identity = try await committedLocalIdentityLoader()
            return try await verifyWithAuthenticatedProtocolIdentity(
                data,
                signature: signature,
                peerId: peerId,
                algorithm: identity.algorithm
            )
        }

 // PQC 被显式关闭时验证 P256。
        var publicKey = getPublicKey(for: peerId)
        if publicKey == nil {
 // 尝试从 Keychain 加载持久化的对端签名公钥
 // KeychainManager 方法现在是 nonisolated 的，可以同步调用
            if let raw = KeychainManager.shared.retrievePeerSigningPublicKey(peerId), let pk = try? P256.Signing.PublicKey(rawRepresentation: raw) {
                publicKey = pk
            }
        }
        guard let publicKey else {
            logger.error("❌ 未找到对等节点的 P256 公钥")
            throw QuantumNetworkError.keyNotFound
        }
        
        return try await verify(data, signature: signature, publicKey: publicKey)
    }
    
 // MARK: - 未来扩展：后量子密码学
    
 /// 准备混合签名（P256 + ML-DSA）。仅在 PQC 被显式关闭时返回 `pqc == nil`。
    public func hybridSign(_ data: Data, for peerId: String) async throws -> (classical: Data, pqc: Data?) {
 // 始终使用P256进行传统签名（不受enablePQC设置影响）
        let classical = try cryptoLock.withLock { _ in
            let keyPair = getOrCreateSigningKeyPair(for: peerId)
            let signature = try keyPair.private.signature(for: data)
            return signature.rawRepresentation
        }
        
        guard await pqcEnabledLoader() else {
            return (classical: classical, pqc: nil)
        }

        let identity = try await committedLocalIdentityLoader()
        let pqc = try await signWithProtocolIdentity(data, identity: identity)
        logger.info("✅ PQC混合签名成功: 传统(\(classical.count)字节) + PQC(\(pqc.count)字节)")
        return (classical: classical, pqc: pqc)
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
            logger.error("❌ 混合签名验证失败：未找到对等节点的 P256 公钥")
            throw QuantumNetworkError.keyNotFound
        }
        
        let classicalValid = try await verify(data, signature: classicalSignature, publicKey: publicKey)

        guard await pqcEnabledLoader() else {
            return classicalValid
        }

        guard let pqcSignature else {
            throw EnhancedPostQuantumCryptoError.pqcSignatureRequired
        }
        let identity = try await committedLocalIdentityLoader()
        let pqcValid = try await verifyWithAuthenticatedProtocolIdentity(
            data,
            signature: pqcSignature,
            peerId: peerId,
            algorithm: identity.algorithm
        )
        logger.info("🔍 混合签名验证: 传统=\(classicalValid), PQC=\(pqcValid)")
        return classicalValid && pqcValid
    }
}
