// HybridCrypto.swift
// SkyBridgeCore
//
// 混合加密模块 - 实现经典+PQC 混合密钥交换和签名
// Created for web-agent-integration spec 10

import Foundation
import OSLog
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Hybrid Key Exchange

/// 混合密钥交换结果
@available(macOS 14.0, *)
public struct HybridKeyExchangeResult: Sendable {
 /// 经典密钥交换产生的共享密钥
    public let classicSharedSecret: Data
 /// PQC 密钥交换产生的共享密钥
    public let pqcSharedSecret: Data
 /// 组合后的最终共享密钥
    public let combinedSharedSecret: Data
 /// 经典密钥封装数据（如 ECDH 公钥）
    public let classicEncapsulated: Data
 /// PQC 密钥封装数据
    public let pqcEncapsulated: Data
    
    public init(
        classicSharedSecret: Data,
        pqcSharedSecret: Data,
        combinedSharedSecret: Data,
        classicEncapsulated: Data,
        pqcEncapsulated: Data
    ) {
        self.classicSharedSecret = classicSharedSecret
        self.pqcSharedSecret = pqcSharedSecret
        self.combinedSharedSecret = combinedSharedSecret
        self.classicEncapsulated = classicEncapsulated
        self.pqcEncapsulated = pqcEncapsulated
    }
}

/// 混合签名结果
@available(macOS 14.0, *)
public struct HybridSignatureResult: Sendable {
 /// 经典签名（P-256 ECDSA）
    public let classicSignature: Data
 /// PQC 签名（ML-DSA）
    public let pqcSignature: Data
 /// 组合签名（用于传输）
    public let combinedSignature: Data
    
    public init(classicSignature: Data, pqcSignature: Data, combinedSignature: Data) {
        self.classicSignature = classicSignature
        self.pqcSignature = pqcSignature
        self.combinedSignature = combinedSignature
    }
}

// MARK: - Hybrid Crypto Service

/// 混合加密服务 - 提供经典+PQC 混合加密功能
@available(macOS 14.0, *)
public actor HybridCryptoService {
    
 // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.skybridge.crypto", category: "HybridCrypto")
    private let pqcAdapter: PQCProtocolAdapter
    
 /// 是否启用混合模式
    public private(set) var isHybridEnabled: Bool
    
 /// 降级警告回调
    public var onDegradationWarning: (@Sendable (String) -> Void)?
    
 // MARK: - Initialization
    
    public init(pqcAdapter: PQCProtocolAdapter? = nil) {
        self.pqcAdapter = pqcAdapter ?? PQCProtocolAdapter()
        self.isHybridEnabled = true
    }
    
 // MARK: - Hybrid Key Exchange
    
 /// 执行混合密钥交换（发起方）
 /// - Parameters:
 /// - peerId: 对端设备 ID
 /// - remoteClassicPublicKey: 对端的经典公钥（P-256）
 /// - Returns: 混合密钥交换结果
    public func initiateHybridKeyExchange(
        peerId: String,
        remoteClassicPublicKey: Data
    ) async throws -> HybridKeyExchangeResult {
 // 1. 经典 ECDH 密钥交换
        let (classicSharedSecret, classicEncapsulated) = try performClassicKeyExchange(
            remotePublicKey: remoteClassicPublicKey
        )
        
 // 2. PQC KEM 密钥交换
        let (pqcSharedSecret, pqcEncapsulated): (Data, Data)
        do {
            let supportedSuites = await pqcAdapter.getSupportedSuites()
            if supportedSuites.contains(.pqc) || supportedSuites.contains(.hybrid) {
                try await pqcAdapter.setSuite(.pqc)
                let result = try await pqcAdapter.kemEncapsulate(peerId: peerId, variant: .mlkem768)
                pqcSharedSecret = result.sharedSecret
                pqcEncapsulated = result.encapsulated
            } else {
 // PQC 不可用，降级
                logger.warning("⚠️ PQC 不可用，降级到纯经典模式")
                onDegradationWarning?("PQC 不可用，使用纯经典加密")
                pqcSharedSecret = Data()
                pqcEncapsulated = Data()
            }
        } catch {
            logger.warning("⚠️ PQC 密钥交换失败，降级到纯经典模式: \(error.localizedDescription)")
            onDegradationWarning?("PQC 密钥交换失败: \(error.localizedDescription)")
            pqcSharedSecret = Data()
            pqcEncapsulated = Data()
        }
        
 // 3. 组合共享密钥
        let combinedSharedSecret = combineSharedSecrets(
            classic: classicSharedSecret,
            pqc: pqcSharedSecret
        )
        
        logger.info("✅ 混合密钥交换完成: classic=\(classicSharedSecret.count)B, pqc=\(pqcSharedSecret.count)B")
        
        return HybridKeyExchangeResult(
            classicSharedSecret: classicSharedSecret,
            pqcSharedSecret: pqcSharedSecret,
            combinedSharedSecret: combinedSharedSecret,
            classicEncapsulated: classicEncapsulated,
            pqcEncapsulated: pqcEncapsulated
        )
    }
    
 /// 完成混合密钥交换（响应方）
 /// - Parameters:
 /// - peerId: 对端设备 ID
 /// - classicEncapsulated: 经典密钥封装数据
 /// - pqcEncapsulated: PQC 密钥封装数据
 /// - localPrivateKey: 本地经典私钥
 /// - Returns: 组合后的共享密钥
    public func completeHybridKeyExchange(
        peerId: String,
        classicEncapsulated: Data,
        pqcEncapsulated: Data,
        localPrivateKey: Data
    ) async throws -> Data {
 // 1. 经典 ECDH 解密
        let classicSharedSecret = try deriveClassicSharedSecret(
            remotePublicKey: classicEncapsulated,
            localPrivateKey: localPrivateKey
        )
        
 // 2. PQC KEM 解封装
        let pqcSharedSecret: Data
        if !pqcEncapsulated.isEmpty {
            do {
                let supportedSuites = await pqcAdapter.getSupportedSuites()
                if supportedSuites.contains(.pqc) || supportedSuites.contains(.hybrid) {
                    try await pqcAdapter.setSuite(.pqc)
                    pqcSharedSecret = try await pqcAdapter.kemDecapsulate(
                        peerId: peerId,
                        encapsulated: pqcEncapsulated,
                        variant: .mlkem768
                    )
                } else {
                    logger.warning("⚠️ PQC 不可用，降级到纯经典模式")
                    onDegradationWarning?("PQC 不可用，使用纯经典加密")
                    pqcSharedSecret = Data()
                }
            } catch {
                logger.warning("⚠️ PQC 解封装失败，降级: \(error.localizedDescription)")
                onDegradationWarning?("PQC 解封装失败: \(error.localizedDescription)")
                pqcSharedSecret = Data()
            }
        } else {
            pqcSharedSecret = Data()
        }
        
 // 3. 组合共享密钥
        return combineSharedSecrets(classic: classicSharedSecret, pqc: pqcSharedSecret)
    }
    
 // MARK: - Hybrid Signature
    
 /// 创建混合签名
 /// - Parameters:
 /// - data: 待签名数据
 /// - peerId: 签名者设备 ID
 /// - classicPrivateKey: 经典私钥（P-256）
 /// - Returns: 混合签名结果
    public func createHybridSignature(
        data: Data,
        peerId: String,
        classicPrivateKey: Data
    ) async throws -> HybridSignatureResult {
 // 1. 经典 ECDSA 签名
        let classicSignature = try createClassicSignature(data: data, privateKey: classicPrivateKey)
        
 // 2. PQC ML-DSA 签名
        let pqcSignature: Data
        do {
            let supportedSuites = await pqcAdapter.getSupportedSuites()
            if supportedSuites.contains(.pqc) || supportedSuites.contains(.hybrid) {
                try await pqcAdapter.setSuite(.pqc)
                pqcSignature = try await pqcAdapter.sign(data: data, peerId: peerId, variant: .mldsa65)
            } else {
                logger.warning("⚠️ PQC 签名不可用，仅使用经典签名")
                onDegradationWarning?("PQC 签名不可用")
                pqcSignature = Data()
            }
        } catch {
            logger.warning("⚠️ PQC 签名失败: \(error.localizedDescription)")
            onDegradationWarning?("PQC 签名失败: \(error.localizedDescription)")
            pqcSignature = Data()
        }
        
 // 3. 组合签名
        let combinedSignature = combineSignatures(classic: classicSignature, pqc: pqcSignature)
        
        logger.info("✅ 混合签名完成: classic=\(classicSignature.count)B, pqc=\(pqcSignature.count)B")
        
        return HybridSignatureResult(
            classicSignature: classicSignature,
            pqcSignature: pqcSignature,
            combinedSignature: combinedSignature
        )
    }
    
 /// 验证混合签名
 /// - Parameters:
 /// - data: 原始数据
 /// - combinedSignature: 组合签名
 /// - peerId: 签名者设备 ID
 /// - classicPublicKey: 经典公钥（P-256）
 /// - Returns: 验证结果
    public func verifyHybridSignature(
        data: Data,
        combinedSignature: Data,
        peerId: String,
        classicPublicKey: Data
    ) async -> Bool {
 // 解析组合签名
        guard let (classicSig, pqcSig) = parseSignatures(combined: combinedSignature) else {
            logger.warning("⚠️ 无法解析组合签名")
            return false
        }
        
 // 1. 验证经典签名
        let classicValid = verifyClassicSignature(data: data, signature: classicSig, publicKey: classicPublicKey)
        if !classicValid {
            logger.warning("⚠️ 经典签名验证失败")
            return false
        }
        
 // 2. 验证 PQC 签名（如果存在）
        if !pqcSig.isEmpty {
            let supportedSuites = await pqcAdapter.getSupportedSuites()
            if supportedSuites.contains(.pqc) || supportedSuites.contains(.hybrid) {
                do {
                    try await pqcAdapter.setSuite(.pqc)
                } catch {
                    logger.warning("⚠️ 无法设置 PQC 套件: \(error.localizedDescription)")
                }
                let pqcValid = await pqcAdapter.verify(data: data, signature: pqcSig, peerId: peerId, variant: .mldsa65)
                if !pqcValid {
                    logger.warning("⚠️ PQC 签名验证失败")
                    return false
                }
            }
        }
        
        logger.info("✅ 混合签名验证通过")
        return true
    }
    
 // MARK: - Private Helpers
    
 /// 执行经典 ECDH 密钥交换
    private func performClassicKeyExchange(remotePublicKey: Data) throws -> (sharedSecret: Data, localPublicKey: Data) {
        #if canImport(CryptoKit)
        let localPrivateKey = P256.KeyAgreement.PrivateKey()
        let localPublicKey = localPrivateKey.publicKey.rawRepresentation
        
        let remoteKey = try P256.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        
        return (sharedSecret.withUnsafeBytes { Data($0) }, localPublicKey)
        #else
        throw HybridCryptoError.cryptoKitUnavailable
        #endif
    }
    
 /// 从经典密钥派生共享密钥
    private func deriveClassicSharedSecret(remotePublicKey: Data, localPrivateKey: Data) throws -> Data {
        #if canImport(CryptoKit)
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: localPrivateKey)
        let publicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return sharedSecret.withUnsafeBytes { Data($0) }
        #else
        throw HybridCryptoError.cryptoKitUnavailable
        #endif
    }
    
 /// 组合共享密钥（使用 HKDF）
    private func combineSharedSecrets(classic: Data, pqc: Data) -> Data {
        #if canImport(CryptoKit)
 // 将两个共享密钥连接后使用 HKDF 派生最终密钥
        var combined = classic
        combined.append(pqc)
        
        let inputKey = SymmetricKey(data: combined)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data("SkyBridgeHybridKDF".utf8),
            info: Data("hybrid-key-exchange".utf8),
            outputByteCount: 32
        )
        
        return derivedKey.withUnsafeBytes { Data($0) }
        #else
 // 降级：简单连接
        var result = classic
        result.append(pqc)
        return result
        #endif
    }
    
 /// 创建经典 ECDSA 签名
    private func createClassicSignature(data: Data, privateKey: Data) throws -> Data {
        #if canImport(CryptoKit)
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        let signature = try key.signature(for: data)
        return signature.rawRepresentation
        #else
        throw HybridCryptoError.cryptoKitUnavailable
        #endif
    }
    
 /// 验证经典 ECDSA 签名
    private func verifyClassicSignature(data: Data, signature: Data, publicKey: Data) -> Bool {
        #if canImport(CryptoKit)
        do {
            let key = try P256.Signing.PublicKey(rawRepresentation: publicKey)
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature)
            return key.isValidSignature(sig, for: data)
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
    
 /// 组合签名（格式：[4字节经典签名长度][经典签名][PQC签名]）
    private func combineSignatures(classic: Data, pqc: Data) -> Data {
        var result = Data()
        
 // 写入经典签名长度（4字节，大端序）
        var length = UInt32(classic.count).bigEndian
        result.append(Data(bytes: &length, count: 4))
        
 // 写入经典签名
        result.append(classic)
        
 // 写入 PQC 签名
        result.append(pqc)
        
        return result
    }
    
 /// 解析组合签名
    private func parseSignatures(combined: Data) -> (classic: Data, pqc: Data)? {
        guard combined.count >= 4 else { return nil }
        
 // 读取经典签名长度
        let lengthData = combined.prefix(4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        guard combined.count >= 4 + Int(length) else { return nil }
        
 // 提取经典签名
        let classicStart = combined.index(combined.startIndex, offsetBy: 4)
        let classicEnd = combined.index(classicStart, offsetBy: Int(length))
        let classic = combined[classicStart..<classicEnd]
        
 // 提取 PQC 签名
        let pqc = combined[classicEnd...]
        
        return (Data(classic), Data(pqc))
    }
}

// MARK: - Hybrid Crypto Error

@available(macOS 14.0, *)
public enum HybridCryptoError: Error, LocalizedError, Sendable {
    case cryptoKitUnavailable
    case invalidPublicKey
    case invalidPrivateKey
    case keyExchangeFailed(String)
    case signatureFailed(String)
    case verificationFailed(String)
    case degradationNotAllowed
    
    public var errorDescription: String? {
        switch self {
        case .cryptoKitUnavailable:
            return "CryptoKit 不可用"
        case .invalidPublicKey:
            return "无效的公钥"
        case .invalidPrivateKey:
            return "无效的私钥"
        case .keyExchangeFailed(let reason):
            return "密钥交换失败: \(reason)"
        case .signatureFailed(let reason):
            return "签名失败: \(reason)"
        case .verificationFailed(let reason):
            return "验证失败: \(reason)"
        case .degradationNotAllowed:
            return "不允许降级到经典模式"
        }
    }
}

// MARK: - Encryption Mode Declaration

@available(macOS 14.0, *)
extension HybridCryptoService {
    
 /// 加密模式声明 - 用于能力协商
    public struct EncryptionModeDeclaration: Codable, Sendable, Equatable {
        public let supportedModes: [String]
        public let preferredMode: String
        public let pqcAvailable: Bool
        public let hybridAvailable: Bool
        
        public init(supportedModes: [String], preferredMode: String, pqcAvailable: Bool, hybridAvailable: Bool) {
            self.supportedModes = supportedModes
            self.preferredMode = preferredMode
            self.pqcAvailable = pqcAvailable
            self.hybridAvailable = hybridAvailable
        }
    }
    
 /// 生成加密模式声明
    public func generateModeDeclaration() async -> EncryptionModeDeclaration {
        let supportedSuites = await pqcAdapter.getSupportedSuites()
        
        var modes: [String] = ["classic"]
        let pqcAvailable = supportedSuites.contains(.pqc)
        let hybridAvailable = supportedSuites.contains(.hybrid)
        
        if pqcAvailable {
            modes.append("pqc")
        }
        if hybridAvailable {
            modes.append("hybrid")
        }
        
        let preferred: String
        if hybridAvailable {
            preferred = "hybrid"
        } else if pqcAvailable {
            preferred = "pqc"
        } else {
            preferred = "classic"
        }
        
        return EncryptionModeDeclaration(
            supportedModes: modes,
            preferredMode: preferred,
            pqcAvailable: pqcAvailable,
            hybridAvailable: hybridAvailable
        )
    }
}
