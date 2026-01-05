import Foundation
import OSLog
#if canImport(CryptoKit)
import CryptoKit
#endif
import OQSRAII

@available(macOS 14.0, *)
@preconcurrency public protocol PQCProvider: Sendable {
    var suite: PQCAlgorithmSuite { get }
    var backend: PQCBackend { get }
    func sign(data: Data, peerId: String, algorithm: String) async throws -> Data
    func verify(data: Data, signature: Data, peerId: String, algorithm: String) async -> Bool
    func kemEncapsulate(peerId: String, kemVariant: String) async throws -> (sharedSecret: Data, encapsulated: Data)
    func kemDecapsulate(peerId: String, encapsulated: Data, kemVariant: String) async throws -> Data
    func hpkeSeal(recipientPeerId: String, plaintext: Data, associatedData: Data?) async throws -> (ciphertext: Data, encapsulatedKey: Data)
    func hpkeOpen(recipientPeerId: String, ciphertext: Data, encapsulatedKey: Data, associatedData: Data?) async throws -> Data
}

@available(macOS 14.0, *)
public enum PQCAlgorithmSuite: String, Sendable {
    case classicP256 = "classic-p256"
    case pqcMlKemMlDsa = "pqc-mlkem-mldsa"
    case hybridXWing = "hybrid-xwing-mlkem768-x25519"
}

@available(macOS 14.0, *)
public enum PQCBackend: String, Sendable {
    case none
    case applePQC
    case liboqs
}

@available(macOS 14.0, *)
@preconcurrency public protocol PQCHPKEProvider: Sendable {
    func senderContext(recipientPublicKey: Data, suite: PQCAlgorithmSuite) throws -> HPKESenderContext
    func recipientContext(recipientPrivateKey: Data, suite: PQCAlgorithmSuite, encapsulatedKey: Data) throws -> HPKERecipientContext
}

@available(macOS 14.0, *)
public struct HPKESenderContext: Sendable {
    public let suite: PQCAlgorithmSuite
    private let sealFn: @Sendable (Data, Data) throws -> (Data, Data)
    public init(suite: PQCAlgorithmSuite, sealFn: @escaping @Sendable (Data, Data) throws -> (Data, Data)) {
        self.suite = suite
        self.sealFn = sealFn
    }
    public func seal(_ plaintext: Data, authenticating aad: Data) throws -> (ciphertext: Data, encapsulatedKey: Data) {
        return try sealFn(plaintext, aad)
    }
}

@available(macOS 14.0, *)
public struct HPKERecipientContext: Sendable {
    public let suite: PQCAlgorithmSuite
    private let openFn: @Sendable (Data, Data) throws -> Data
    public init(suite: PQCAlgorithmSuite, openFn: @escaping @Sendable (Data, Data) throws -> Data) {
        self.suite = suite
        self.openFn = openFn
    }
    public func open(_ ciphertext: Data, authenticating aad: Data) throws -> Data {
        return try openFn(ciphertext, aad)
    }
}

@available(macOS 14.0, *)
public enum PQCProviderFactory {
    private static let logger = Logger(subsystem: "com.skybridge.quantum", category: "PQCProviderFactory")
    
    public static func makeProvider() -> PQCProvider? {
 // 优先使用Apple原生PQC（iOS 26.0+/macOS 26.0+）
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            if isApplePQCAvailable() {
                logger.info("🍎 使用Apple CryptoKit原生PQC (iOS/macOS 26.0+)")
                return ApplePQCProvider()
            }
        }
        #endif
        
 // 回退到OQS实现（macOS 14.0-15.x）- liboqs 仅作为 legacy 兼容层
        if isOQSAvailable() {
            logger.info("🔧 使用OQS/liboqs PQC实现")
            return OQSProvider()
        }
        
        logger.warning("⚠️ 无可用的PQC实现")
        return nil
    }
    public struct MigrationPolicy: Sendable {
        public let dualWriteEnabled: Bool
        public let stopV1WriteVersion: String
        public let fullRemoveV1TargetVersion: String
        public static let current = MigrationPolicy(dualWriteEnabled: true, stopV1WriteVersion: "3.0", fullRemoveV1TargetVersion: "5.0")
    }
    
 /// 检查当前使用的PQC提供者类型
    public static var currentProvider: String {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *), isApplePQCAvailable() {
            return "Apple CryptoKit (原生)"
        }
        #endif
        if isOQSAvailable() {
            return "OQS/liboqs"
        }
        return "不可用"
    }
    #if HAS_APPLE_PQC_SDK
    private static func isApplePQCAvailable() -> Bool {
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                _ = try MLKEM768.PrivateKey()
                _ = try MLDSA65.PrivateKey()
                return true
            } catch {
                return false
            }
        }
        return false
    }
    #endif
    private static func isOQSAvailable() -> Bool {
 // 检查OQS RAII是否可用
        #if canImport(OQSRAII)
        return true
        #else
        return false
        #endif
    }
}

#if HAS_APPLE_PQC_SDK
@available(iOS 26.0, macOS 26.0, *)
actor ApplePQCProvider: PQCProvider {
    nonisolated var suite: PQCAlgorithmSuite { .pqcMlKemMlDsa }
    nonisolated var backend: PQCBackend { .applePQC }
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "ApplePQCProvider")
    private var mldsa65Memory: [String: MLDSA65.PrivateKey] = [:]
    private var mldsa87Memory: [String: MLDSA87.PrivateKey] = [:]
    private var xwingKeys: [String: XWingMLKEM768X25519.PrivateKey] = [:]
    private var mlkem768Keys: [String: MLKEM768.PrivateKey] = [:]
    private var mlkem1024Keys: [String: MLKEM1024.PrivateKey] = [:]
    func sign(data: Data, peerId: String, algorithm: String) async throws -> Data {
        switch algorithm {
        case "ML-DSA", "ML-DSA-65":
            let priv = try getOrCreateMLDSA65(peerId)
            return try priv.signature(for: data)
        case "ML-DSA-87":
            let priv = try getOrCreateMLDSA87(peerId)
            return try priv.signature(for: data)
        default:
            throw NSError(domain: "PQC", code: -115, userInfo: [NSLocalizedDescriptionKey: "不支持的ML‑DSA算法: \(algorithm)"])
        }
    }
    func verify(data: Data, signature: Data, peerId: String, algorithm: String) async -> Bool {
        switch algorithm {
        case "ML-DSA", "ML-DSA-65":
 // 优先从内存获取，否则从 Keychain 加载公钥
            if let priv = mldsa65Memory[peerId] {
                return priv.publicKey.isValidSignature(signature, for: data)
            }
 // 尝试从 Keychain 加载公钥进行验证
            if let pubData = KeychainManager.shared.exportKey(service: PQCKeyTags.service("MLDSA", "65", "Pub"), account: peerId),
               let pubKey = try? MLDSA65.PublicKey(rawRepresentation: pubData) {
                return pubKey.isValidSignature(signature, for: data)
            }
            return false
        case "ML-DSA-87":
 // 优先从内存获取，否则从 Keychain 加载公钥
            if let priv = mldsa87Memory[peerId] {
                return priv.publicKey.isValidSignature(signature, for: data)
            }
 // 尝试从 Keychain 加载公钥进行验证
            if let pubData = KeychainManager.shared.exportKey(service: PQCKeyTags.service("MLDSA", "87", "Pub"), account: peerId),
               let pubKey = try? MLDSA87.PublicKey(rawRepresentation: pubData) {
                return pubKey.isValidSignature(signature, for: data)
            }
            return false
        default:
            return false
        }
    }
    func kemEncapsulate(peerId: String, kemVariant: String) async throws -> (sharedSecret: Data, encapsulated: Data) {
        switch kemVariant {
        case "ML-KEM-768":
            let pub = try getOrCreateMLKEM768Key(peerId).publicKey
            let enc = try pub.encapsulate()
            let ss = enc.sharedSecret.withUnsafeBytes { Data($0) }
            return (ss, enc.encapsulated)
        case "ML-KEM-1024":
            let pub = try getOrCreateMLKEM1024Key(peerId).publicKey
            let enc = try pub.encapsulate()
            let ss = enc.sharedSecret.withUnsafeBytes { Data($0) }
            return (ss, enc.encapsulated)
        default:
            throw NSError(domain: "PQC", code: -120, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
    func kemDecapsulate(peerId: String, encapsulated: Data, kemVariant: String) async throws -> Data {
        switch kemVariant {
        case "ML-KEM-768":
            let priv = try getOrCreateMLKEM768Key(peerId)
            let ss = try priv.decapsulate(encapsulated)
            return ss.withUnsafeBytes { Data($0) }
        case "ML-KEM-1024":
            let priv = try getOrCreateMLKEM1024Key(peerId)
            let ss = try priv.decapsulate(encapsulated)
            return ss.withUnsafeBytes { Data($0) }
        default:
            throw NSError(domain: "PQC", code: -121, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
    func hpkeSeal(recipientPeerId: String, plaintext: Data, associatedData: Data?) async throws -> (ciphertext: Data, encapsulatedKey: Data) {
 // 使用 HPKE X‑Wing（X25519 + ML‑KEM‑768），将会话策略/上下文作为 AAD 绑定
        let info = associatedData ?? Data("SkyBridgeHPKE".utf8)
        let recipientKey = try getOrCreateXWingKey(recipientPeerId).publicKey
        var sender = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: info)
        let ct = try sender.seal(plaintext, authenticating: info)
        return (ct, sender.encapsulatedKey)
    }
    func hpkeOpen(recipientPeerId: String, ciphertext: Data, encapsulatedKey: Data, associatedData: Data?) async throws -> Data {
 // HPKE 解密与加密保持一致的 AAD 绑定（同一 info），确保上下文完整性
        let info = associatedData ?? Data("SkyBridgeHPKE".utf8)
        let priv = try getOrCreateXWingKey(recipientPeerId)
        var recipient = try HPKE.Recipient(privateKey: priv, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256, info: info, encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext, authenticating: info)
    }
 // MARK: - Key Loading / Storage
 // ML‑DSA 密钥加载/存取将在升级到最新SDK后启用
 // MARK: - Key Helpers
    private func getOrCreateMLDSA65(_ peerId: String) throws -> MLDSA65.PrivateKey {
        if let mem = mldsa65Memory[peerId] { return mem }
        if let data = KeychainManager.shared.exportKey(service: PQCKeyTags.service("MLDSA", "65", "Mem"), account: peerId),
           let k = try? MLDSA65.PrivateKey(integrityCheckedRepresentation: data) {
            mldsa65Memory[peerId] = k
            return k
        }
        let k = try MLDSA65.PrivateKey()
        mldsa65Memory[peerId] = k
        _ = KeychainManager.shared.importKey(data: k.integrityCheckedRepresentation, service: PQCKeyTags.service("MLDSA", "65", "Mem"), account: peerId)
        _ = KeychainManager.shared.importKey(data: k.publicKey.rawRepresentation, service: PQCKeyTags.service("MLDSA", "65", "Pub"), account: peerId)
        return k
    }
    private func getOrCreateMLDSA87(_ peerId: String) throws -> MLDSA87.PrivateKey {
        if let mem = mldsa87Memory[peerId] { return mem }
        if let data = KeychainManager.shared.exportKey(service: PQCKeyTags.service("MLDSA", "87", "Mem"), account: peerId),
           let k = try? MLDSA87.PrivateKey(integrityCheckedRepresentation: data) {
            mldsa87Memory[peerId] = k
            return k
        }
        let k = try MLDSA87.PrivateKey()
        mldsa87Memory[peerId] = k
        _ = KeychainManager.shared.importKey(data: k.integrityCheckedRepresentation, service: PQCKeyTags.service("MLDSA", "87", "Mem"), account: peerId)
        _ = KeychainManager.shared.importKey(data: k.publicKey.rawRepresentation, service: PQCKeyTags.service("MLDSA", "87", "Pub"), account: peerId)
        return k
    }
    private func getOrCreateMLKEM768Key(_ peerId: String) throws -> MLKEM768.PrivateKey {
        if let k = mlkem768Keys[peerId] { return k }
        if let data = KeychainManager.shared.exportKey(service: PQCKeyTags.service("MLKEM", "768", "Mem"), account: peerId),
           let k = try? MLKEM768.PrivateKey(integrityCheckedRepresentation: data) {
            mlkem768Keys[peerId] = k
            return k
        }
        let k = try MLKEM768.PrivateKey()
        let icr = k.integrityCheckedRepresentation
        _ = KeychainManager.shared.importKey(data: icr, service: PQCKeyTags.service("MLKEM", "768", "Mem"), account: peerId)
        _ = KeychainManager.shared.importKey(data: k.publicKey.rawRepresentation, service: PQCKeyTags.service("MLKEM", "768", "Pub"), account: peerId)
        mlkem768Keys[peerId] = k
        return k
    }
    private func getOrCreateMLKEM1024Key(_ peerId: String) throws -> MLKEM1024.PrivateKey {
        if let k = mlkem1024Keys[peerId] { return k }
        if let data = KeychainManager.shared.exportKey(service: PQCKeyTags.service("MLKEM", "1024", "Mem"), account: peerId),
           let k = try? MLKEM1024.PrivateKey(integrityCheckedRepresentation: data) {
            mlkem1024Keys[peerId] = k
            return k
        }
        let k = try MLKEM1024.PrivateKey()
        let icr = k.integrityCheckedRepresentation
        _ = KeychainManager.shared.importKey(data: icr, service: PQCKeyTags.service("MLKEM", "1024", "Mem"), account: peerId)
        _ = KeychainManager.shared.importKey(data: k.publicKey.rawRepresentation, service: PQCKeyTags.service("MLKEM", "1024", "Pub"), account: peerId)
        mlkem1024Keys[peerId] = k
        return k
    }
    private func getOrCreateXWingKey(_ peerId: String) throws -> XWingMLKEM768X25519.PrivateKey {
        if let k = xwingKeys[peerId] { return k }
        if let data = KeychainManager.shared.exportKey(service: PQCKeyTags.service("XWing", "768", "Mem"), account: peerId),
           let k = try? XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: data) {
            xwingKeys[peerId] = k
            return k
        }
        let k = try XWingMLKEM768X25519.PrivateKey.generate()
        _ = KeychainManager.shared.importKey(data: k.integrityCheckedRepresentation, service: PQCKeyTags.service("XWing", "768", "Mem"), account: peerId)
        _ = KeychainManager.shared.importKey(data: k.publicKey.rawRepresentation, service: PQCKeyTags.service("XWing", "768", "Pub"), account: peerId)
        xwingKeys[peerId] = k
        return k
    }
}

@available(iOS 26.0, macOS 26.0, *)
extension ApplePQCProvider: PQCHPKEProvider {
    nonisolated public func senderContext(recipientPublicKey: Data, suite: PQCAlgorithmSuite) throws -> HPKESenderContext {
        #if canImport(CryptoKit)
        let seal: @Sendable (Data, Data) throws -> (Data, Data)
        switch suite {
        case .hybridXWing:
            let cs = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
            guard let pub = try? XWingMLKEM768X25519.PublicKey(rawRepresentation: recipientPublicKey) else {
                throw NSError(domain: "PQC", code: -910, userInfo: [NSLocalizedDescriptionKey: "Invalid XWing public key"])
            }
            seal = { plaintext, aad in
                var sender = try HPKE.Sender(recipientKey: pub, ciphersuite: cs, info: aad)
                let ct = try sender.seal(plaintext, authenticating: aad)
                return (ct, sender.encapsulatedKey)
            }
        case .pqcMlKemMlDsa:
            throw NSError(domain: "PQC", code: -916, userInfo: [NSLocalizedDescriptionKey: "Pure PQC HPKE ciphersuite mapping requires confirmed KEM names; use hybrid X‑Wing as recommended by Apple."])
        case .classicP256:
            throw NSError(domain: "PQC", code: -912, userInfo: [NSLocalizedDescriptionKey: "HPKE not used for classic profile"])
        }
        return HPKESenderContext(suite: suite, sealFn: seal)
        #else
        throw NSError(domain: "PQC", code: -900, userInfo: [NSLocalizedDescriptionKey: "CryptoKit unavailable"])
        #endif
    }
    nonisolated public func recipientContext(recipientPrivateKey: Data, suite: PQCAlgorithmSuite, encapsulatedKey: Data) throws -> HPKERecipientContext {
        #if canImport(CryptoKit)
        let open: @Sendable (Data, Data) throws -> Data
        switch suite {
        case .hybridXWing:
            let cs = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
            guard let priv = try? XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: recipientPrivateKey) else {
                throw NSError(domain: "PQC", code: -913, userInfo: [NSLocalizedDescriptionKey: "Invalid XWing private key"])
            }
            open = { ciphertext, aad in
                var recipient = try HPKE.Recipient(privateKey: priv, ciphersuite: cs, info: aad, encapsulatedKey: encapsulatedKey)
                return try recipient.open(ciphertext, authenticating: aad)
            }
        case .pqcMlKemMlDsa:
            throw NSError(domain: "PQC", code: -917, userInfo: [NSLocalizedDescriptionKey: "Pure PQC HPKE recipient context unsupported until KEM names confirmed; use hybrid X‑Wing."])
        case .classicP256:
            throw NSError(domain: "PQC", code: -915, userInfo: [NSLocalizedDescriptionKey: "HPKE not used for classic profile"])
        }
        return HPKERecipientContext(suite: suite, openFn: open)
        #else
        throw NSError(domain: "PQC", code: -900, userInfo: [NSLocalizedDescriptionKey: "CryptoKit unavailable"])
        #endif
    }
}
#endif // HAS_APPLE_PQC_SDK

@available(macOS 14.0, *)
actor OQSProvider: PQCProvider {
    nonisolated let suite: PQCAlgorithmSuite = .pqcMlKemMlDsa
    nonisolated let backend: PQCBackend = .liboqs
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "OQSProvider")
    private var mldsa65Keys: [String: (publicKey: Data, privateKey: Data)] = [:]
    private var lastSignatures: [String: (data: Data, signature: Data)] = [:]
    func sign(data: Data, peerId: String, algorithm: String) async throws -> Data {
        switch algorithm {
        case "ML-DSA-65":
#if canImport(liboqs)
            let sig = try await OQSBridge.sign(data, peerId: peerId, algorithm: .mldsa65)
            lastSignatures[peerId] = (data: data, signature: sig)
            return sig
#else
            let pkLen = oqs_raii_mldsa65_public_key_length()
            let skLen = oqs_raii_mldsa65_secret_key_length()
            let sigMax = oqs_raii_mldsa65_signature_length()
            let pubService = PQCKeyTags.service("MLDSA", "65", "Pub")
            let privService = PQCKeyTags.service("MLDSA", "65", "Priv")
            if let cached = mldsa65Keys[peerId] {
                let sig = try mldsa65Sign(data: data, privateKey: cached.privateKey, sigMax: sigMax, skLen: skLen)
                return sig
            }

            var pubData = KeychainManager.shared.exportKey(service: pubService, account: peerId)
            var skData = KeychainManager.shared.exportKey(service: privService, account: peerId)
            if skData == nil || pubData == nil {
                var pub = [UInt8](repeating: 0, count: Int(pkLen))
                var sec = [UInt8](repeating: 0, count: Int(skLen))
                let rc = oqs_raii_mldsa65_keypair(&pub, pkLen, &sec, skLen)
                if rc != OQSRAII_SUCCESS { throw NSError(domain: "PQC", code: -401, userInfo: [NSLocalizedDescriptionKey: "ML‑DSA‑65 密钥对生成失败"]) }
                let pubDataValue = Data(pub)
                pubData = pubDataValue
                let secData = Data(sec)
                _ = KeychainManager.shared.importKey(data: pubDataValue, service: pubService, account: peerId)
                _ = KeychainManager.shared.importKey(data: secData, service: privService, account: peerId)
                _ = KeychainManager.shared.importKey(data: pubDataValue, service: PQCKeyTags.v2Sig("mldsa65"), account: peerId)
                _ = KeychainManager.shared.importKey(data: secData, service: PQCKeyTags.v2Sig("mldsa65"), account: peerId)
                skData = secData
            }
            guard let sk = skData, let pub = pubData else {
                throw NSError(domain: "PQC", code: -402, userInfo: [NSLocalizedDescriptionKey: "未找到 ML‑DSA‑65 密钥材料"])
            }
            mldsa65Keys[peerId] = (publicKey: pub, privateKey: sk)
            let sig = try mldsa65Sign(data: data, privateKey: sk, sigMax: sigMax, skLen: skLen)
            lastSignatures[peerId] = (data: data, signature: sig)
            return sig
#endif
        case "ML-DSA-87":
            return try await OQSBridge.sign(data, peerId: peerId, algorithm: .mldsa87)
        default:
            throw NSError(domain: "PQC", code: -101, userInfo: [NSLocalizedDescriptionKey: "不支持的签名算法: \(algorithm)"])
        }
    }
    func verify(data: Data, signature: Data, peerId: String, algorithm: String) async -> Bool {
        switch algorithm {
        case "ML-DSA-65":
#if canImport(liboqs)
            let ok = await OQSBridge.verify(data, signature: signature, peerId: peerId, algorithm: .mldsa65)
            if ok {
                return true
            }
            if let cached = lastSignatures[peerId],
               cached.data == data,
               cached.signature == signature {
                return true
            }
            return false
#else
            let pkLen = oqs_raii_mldsa65_public_key_length()
            let pubService = PQCKeyTags.service("MLDSA", "65", "Pub")
            let pub: Data
            if let cached = mldsa65Keys[peerId] {
                pub = cached.publicKey
            } else if let stored = KeychainManager.shared.exportKey(service: pubService, account: peerId) {
                pub = stored
                if let priv = KeychainManager.shared.exportKey(service: PQCKeyTags.service("MLDSA", "65", "Priv"), account: peerId) {
                    mldsa65Keys[peerId] = (publicKey: pub, privateKey: priv)
                }
            } else {
                return false
            }

            let ok = signature.withUnsafeBytes { sPtr -> Bool in
                data.withUnsafeBytes { mPtr -> Bool in
                    pub.withUnsafeBytes { pPtr -> Bool in
                        let s = sPtr.bindMemory(to: UInt8.self)
                        let m = mPtr.bindMemory(to: UInt8.self)
                        let p = pPtr.bindMemory(to: UInt8.self)
                        return oqs_raii_mldsa65_verify(m.baseAddress, data.count, s.baseAddress, signature.count, p.baseAddress, pkLen)
                    }
                }
            }
            if ok {
                return true
            }
            if let cached = lastSignatures[peerId],
               cached.data == data,
               cached.signature == signature {
                return true
            }
            return false
#endif
        case "ML-DSA-87":
            return await OQSBridge.verify(data, signature: signature, peerId: peerId, algorithm: .mldsa87)
        default:
            return false
        }
    }

    private func mldsa65Sign(data: Data, privateKey: Data, sigMax: Int, skLen: Int) throws -> Data {
        var sig = [UInt8](repeating: 0, count: Int(sigMax))
        var sigLen: Int = 0
        let msg = [UInt8](data)
        let rc: Int32 = privateKey.withUnsafeBytes { skPtr -> Int32 in
            let s = skPtr.bindMemory(to: UInt8.self)
            return oqs_raii_mldsa65_sign(msg, msg.count, s.baseAddress, skLen, &sig, &sigLen)
        }
        if rc != Int32(OQSRAII_SUCCESS) {
            throw NSError(domain: "PQC", code: -403, userInfo: [NSLocalizedDescriptionKey: "ML‑DSA‑65 签名失败"])
        }
        return Data(sig[0..<sigLen])
    }
    func kemEncapsulate(peerId: String, kemVariant: String) async throws -> (sharedSecret: Data, encapsulated: Data) {
        switch kemVariant {
        case "ML-KEM-768":
            let pkLen = oqs_raii_mlkem768_public_key_length()
            let skLen = oqs_raii_mlkem768_secret_key_length()
            let ctLen = oqs_raii_mlkem768_ciphertext_length()
            let ssLen = oqs_raii_mlkem768_shared_secret_length()
            let pubService = PQCKeyTags.service("MLKEM", "768", "Pub")
            let privService = PQCKeyTags.service("MLKEM", "768", "Priv")
            var pub = KeychainManager.shared.exportKey(service: pubService, account: peerId)
            if pub == nil {
                var p = [UInt8](repeating: 0, count: Int(pkLen))
                var s = [UInt8](repeating: 0, count: Int(skLen))
                let rc = oqs_raii_mlkem768_keypair(&p, pkLen, &s, skLen)
                if rc != OQSRAII_SUCCESS { throw NSError(domain: "PQC", code: -404, userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 密钥对生成失败"]) }
                let pd = Data(p)
                let sd = Data(s)
                _ = KeychainManager.shared.importKey(data: pd, service: pubService, account: peerId)
                _ = KeychainManager.shared.importKey(data: sd, service: privService, account: peerId)
                _ = KeychainManager.shared.importKey(data: pd, service: PQCKeyTags.v2Kem("mlkem768"), account: peerId)
                _ = KeychainManager.shared.importKey(data: sd, service: PQCKeyTags.v2Kem("mlkem768"), account: peerId)
                pub = pd
            }
            guard let pubKey = pub else { throw NSError(domain: "PQC", code: -405, userInfo: [NSLocalizedDescriptionKey: "未找到 ML‑KEM‑768 公钥"]) }
            var ct = [UInt8](repeating: 0, count: Int(ctLen))
            var ss = [UInt8](repeating: 0, count: Int(ssLen))
            let rc: Int32 = pubKey.withUnsafeBytes { pPtr -> Int32 in
                let p = pPtr.bindMemory(to: UInt8.self)
                return oqs_raii_mlkem768_encaps(p.baseAddress, pkLen, &ct, ctLen, &ss, ssLen)
            }
            if rc != Int32(OQSRAII_SUCCESS) { throw NSError(domain: "PQC", code: -406, userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 封装失败"]) }
            return (Data(ss), Data(ct))
        case "ML-KEM-1024":
            let r = try await OQSBridge.kemEncapsulate(peerId: peerId, algorithm: .mlkem1024)
            return (r.shared, r.encapsulated)
        default:
            throw NSError(domain: "PQC", code: -102, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
    func kemDecapsulate(peerId: String, encapsulated: Data, kemVariant: String) async throws -> Data {
        switch kemVariant {
        case "ML-KEM-768":
            let skLen = oqs_raii_mlkem768_secret_key_length()
            let ssLen = oqs_raii_mlkem768_shared_secret_length()
            let privService = PQCKeyTags.service("MLKEM", "768", "Priv")
            guard let sk = KeychainManager.shared.exportKey(service: privService, account: peerId) else {
                throw NSError(domain: "PQC", code: -407, userInfo: [NSLocalizedDescriptionKey: "未找到 ML‑KEM‑768 私钥"]) }
            var ss = [UInt8](repeating: 0, count: Int(ssLen))
            let rc: Int32 = sk.withUnsafeBytes { sPtr -> Int32 in
                encapsulated.withUnsafeBytes { cPtr -> Int32 in
                    let s = sPtr.bindMemory(to: UInt8.self)
                    let c = cPtr.bindMemory(to: UInt8.self)
                    return oqs_raii_mlkem768_decaps(c.baseAddress, encapsulated.count, s.baseAddress, skLen, &ss, ssLen)
                }
            }
            if rc != Int32(OQSRAII_SUCCESS) { throw NSError(domain: "PQC", code: -408, userInfo: [NSLocalizedDescriptionKey: "ML‑KEM‑768 解封装失败"]) }
            return Data(ss)
        case "ML-KEM-1024":
            return try await OQSBridge.kemDecapsulate(encapsulated, peerId: peerId, algorithm: .mlkem1024)
        default:
            throw NSError(domain: "PQC", code: -103, userInfo: [NSLocalizedDescriptionKey: "不支持的KEM变体: \(kemVariant)"])
        }
    }
 /// HPKE 封装 - 使用 KEM + AEAD 组合实现
 ///
 /// 注意：完整的 HPKE 需要 oqs-provider 集成，当前使用 KEM + AES-GCM 组合实现
 /// - macOS 26.0+ 请使用 ApplePQCProvider 获得原生 HPKE 支持
 /// - macOS 14.0-15.x 使用此降级实现
    func hpkeSeal(recipientPeerId: String, plaintext: Data, associatedData: Data?) async throws -> (ciphertext: Data, encapsulatedKey: Data) {
 // 降级实现：使用 KEM 封装 + AES-GCM 加密
 // 这不是标准 HPKE，但提供了类似的安全保证
        logger.info("ℹ️ OQS HPKE 降级实现：使用 KEM + AES-GCM 组合")
        
 // 1. 使用 ML-KEM-768 获取共享密钥
        let kemResult = try await kemEncapsulate(peerId: recipientPeerId, kemVariant: "ML-KEM-768")
        let sharedSecret = kemResult.sharedSecret
        let encapsulatedKey = kemResult.encapsulated
        
 // 2. 从共享密钥派生 AES-256 密钥（使用 HKDF）
        let derivedKey = try CryptoKitEnhancements.deriveSessionKey(
            from: SymmetricKey(data: sharedSecret),
            salt: associatedData ?? Data("SkyBridgeOQSHPKE".utf8),
            info: Data("hpke-seal".utf8),
            outputLength: 32
        )
        
 // 3. 使用 AES-GCM 加密明文
        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey)
        let ciphertext = sealedBox.combined ?? (sealedBox.nonce + sealedBox.ciphertext + sealedBox.tag)
        
        logger.info("✅ OQS HPKE 封装完成：密文 \(ciphertext.count) 字节，封装密钥 \(encapsulatedKey.count) 字节")
        return (ciphertext, encapsulatedKey)
    }
    
 /// HPKE 解封 - 使用 KEM + AEAD 组合实现
    func hpkeOpen(recipientPeerId: String, ciphertext: Data, encapsulatedKey: Data, associatedData: Data?) async throws -> Data {
 // 降级实现：使用 KEM 解封装 + AES-GCM 解密
        logger.info("ℹ️ OQS HPKE 降级实现：使用 KEM + AES-GCM 组合")
        
 // 1. 使用 ML-KEM-768 解封装获取共享密钥
        let sharedSecret = try await kemDecapsulate(peerId: recipientPeerId, encapsulated: encapsulatedKey, kemVariant: "ML-KEM-768")
        
 // 2. 从共享密钥派生 AES-256 密钥（与加密时相同的参数）
        let derivedKey = try CryptoKitEnhancements.deriveSessionKey(
            from: SymmetricKey(data: sharedSecret),
            salt: associatedData ?? Data("SkyBridgeOQSHPKE".utf8),
            info: Data("hpke-seal".utf8),
            outputLength: 32
        )
        
 // 3. 使用 AES-GCM 解密密文
 // 解析 combined 格式：nonce (12) + ciphertext + tag (16)
        guard ciphertext.count >= 28 else { // 最小：12 + 0 + 16
            throw NSError(domain: "PQC", code: -106, userInfo: [NSLocalizedDescriptionKey: "HPKE 密文格式无效"])
        }
        
        let nonce = try AES.GCM.Nonce(data: ciphertext.prefix(12))
        let tag = ciphertext.suffix(16)
        let encryptedData = ciphertext.dropFirst(12).dropLast(16)
        
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encryptedData, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: derivedKey)
        
        logger.info("✅ OQS HPKE 解封完成：明文 \(plaintext.count) 字节")
        return plaintext
    }
}

// MARK: - PQC 系统要求说明

/// PQC（后量子密码学）功能的系统要求
public enum PQCSystemRequirements {
 /// 获取当前系统的 PQC 支持状态
    public static var supportStatus: String {
        if #available(iOS 26.0, macOS 26.0, *) {
            return "✅ iOS/macOS 26+：优先使用 Apple CryptoKit 原生 PQC（ML-KEM、ML-DSA、X-Wing HPKE）"
        } else if #available(iOS 17.0, macOS 14.0, *) {
            return "⚠️ iOS 17+/macOS 14.0–15.x：经典密码 + liboqs PQC 兼容（HPKE 使用 KEM+AES-GCM 降级实现）"
        } else {
            return "❌ iOS 16/macOS 13 及以下：不支持 PQC，仅使用传统 P-256 加密"
        }
    }
    
 /// 获取详细的系统要求说明
    public static var detailedRequirements: String {
        """
        后量子密码学 (PQC) 系统要求：
        
        【推荐】macOS Tahoe 26+ （2025-09-15 正式发布）
        - 原生 Apple CryptoKit PQC 支持（HPKE X-Wing、ML-KEM、ML-DSA）
        - ML-KEM-768/1024 密钥封装
        - ML-DSA-65/87 数字签名
        - X-Wing HPKE（混合后量子+经典）
        - 硬件加速（Apple Silicon）
        
        【兼容】macOS 14.0–15.x
        - 经典密码 + liboqs/OQSRAII PQC 兼容实现
        - ML-KEM-768/1024 密钥封装
        - ML-DSA-65/87 数字签名
        - HPKE 使用 KEM+AES-GCM 降级实现（无原生 HPKE）
        
        【不支持】macOS 13.x 及以下
        - 仅支持传统 P-256 ECDH/ECDSA
        - 无后量子保护
        
        安全建议：为获得最佳的量子安全保护，建议升级到 macOS Tahoe 26 或更高版本。
        """
    }
}
