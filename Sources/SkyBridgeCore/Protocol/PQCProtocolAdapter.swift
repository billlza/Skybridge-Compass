// PQCProtocolAdapter.swift
// SkyBridgeCore
//
// PQC 跨平台协议适配器 - 封装现有 PQCProvider 为统一跨平台接口
// Created for web-agent-integration spec 9

import Foundation
import OSLog

// MARK: - 跨平台 PQC 算法套件

/// 跨平台统一的 PQC 算法套件枚举
@available(macOS 14.0, *)
public enum CrossPlatformPQCSuite: String, Codable, Sendable, CaseIterable {
 /// 经典 P-256 ECDH/ECDSA（无 PQC 保护）
    case classic = "classic"
 /// 纯 PQC：ML-KEM + ML-DSA
    case pqc = "pqc"
 /// 混合模式：X-Wing (X25519 + ML-KEM-768)
    case hybrid = "hybrid"
    
 /// 转换为内部 PQCAlgorithmSuite
    public var internalSuite: PQCAlgorithmSuite {
        switch self {
        case .classic: return .classicP256
        case .pqc: return .pqcMlKemMlDsa
        case .hybrid: return .hybridXWing
        }
    }
    
 /// 从内部 PQCAlgorithmSuite 转换
    public init(from internal: PQCAlgorithmSuite) {
        switch `internal` {
        case .classicP256: self = .classic
        case .pqcMlKemMlDsa: self = .pqc
        case .hybridXWing: self = .hybrid
        }
    }
}

/// 跨平台 KEM 变体
@available(macOS 14.0, *)
public enum CrossPlatformKEMVariant: String, Codable, Sendable, CaseIterable {
    case mlkem768 = "ML-KEM-768"
    case mlkem1024 = "ML-KEM-1024"
    
 /// 密钥封装长度（字节）
    public var encapsulatedLength: Int {
        switch self {
        case .mlkem768: return 1088
        case .mlkem1024: return 1568
        }
    }
    
 /// 共享密钥长度（字节）
    public var sharedSecretLength: Int { 32 }
}

/// 跨平台签名算法变体
@available(macOS 14.0, *)
public enum CrossPlatformSignatureVariant: String, Codable, Sendable, CaseIterable {
    case mldsa65 = "ML-DSA-65"
    case mldsa87 = "ML-DSA-87"
    
 /// 签名长度（字节）
    public var signatureLength: Int {
        switch self {
        case .mldsa65: return 3309
        case .mldsa87: return 4627
        }
    }
}

// MARK: - PQC 协议适配器

/// PQC 跨平台协议适配器 - 提供统一的跨平台 PQC 接口
@available(macOS 14.0, *)
public actor PQCProtocolAdapter {
    
 // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "PQCProtocolAdapter")
    private let provider: PQCProvider?
    private let supportedSuites: [CrossPlatformPQCSuite]
    
 /// 当前使用的算法套件
    public private(set) var currentSuite: CrossPlatformPQCSuite
    
 /// 后端类型
    public nonisolated var backend: PQCBackend {
        provider?.backend ?? .none
    }
    
 /// 是否支持 PQC
    public nonisolated var isPQCAvailable: Bool {
        provider != nil
    }
    
 // MARK: - Initialization
    
    public init() {
        self.provider = PQCProviderFactory.makeProvider()
        
        if let p = provider {
            switch p.backend {
            case .applePQC:
 // Apple PQC 支持所有套件
                self.supportedSuites = [.classic, .pqc, .hybrid]
                self.currentSuite = .hybrid
            case .liboqs:
 // OQS 支持经典和纯 PQC（HPKE 降级实现）
                self.supportedSuites = [.classic, .pqc]
                self.currentSuite = .pqc
            case .none:
                self.supportedSuites = [.classic]
                self.currentSuite = .classic
            }
        } else {
            self.supportedSuites = [.classic]
            self.currentSuite = .classic
        }
    }
    
 /// 使用指定 provider 初始化（用于测试）
    public init(provider: PQCProvider?, suite: CrossPlatformPQCSuite = .hybrid) {
        self.provider = provider
        self.currentSuite = suite
        
        if let p = provider {
            switch p.backend {
            case .applePQC:
                self.supportedSuites = [.classic, .pqc, .hybrid]
            case .liboqs:
                self.supportedSuites = [.classic, .pqc]
            case .none:
                self.supportedSuites = [.classic]
            }
        } else {
            self.supportedSuites = [.classic]
        }
    }
    
 // MARK: - Suite Management
    
 /// 获取支持的算法套件列表
    public func getSupportedSuites() -> [CrossPlatformPQCSuite] {
        supportedSuites
    }
    
 /// 设置当前使用的算法套件
    public func setSuite(_ suite: CrossPlatformPQCSuite) throws {
        guard supportedSuites.contains(suite) else {
            throw PQCProtocolError.unsupportedSuite(suite.rawValue)
        }
        currentSuite = suite
        logger.info("🔐 PQC 套件已切换为: \(suite.rawValue)")
    }
    
 // MARK: - KEM Operations
    
 /// KEM 封装 - 生成共享密钥和封装数据
 /// - Parameters:
 /// - peerId: 对端设备 ID
 /// - variant: KEM 变体（默认 ML-KEM-768）
 /// - Returns: (共享密钥, 封装数据)
    public func kemEncapsulate(
        peerId: String,
        variant: CrossPlatformKEMVariant = .mlkem768
    ) async throws -> (sharedSecret: Data, encapsulated: Data) {
        guard let provider = provider else {
            throw PQCProtocolError.providerNotAvailable
        }
        
        guard currentSuite != .classic else {
            throw PQCProtocolError.operationNotSupportedInClassicMode("KEM")
        }
        
        let result = try await provider.kemEncapsulate(peerId: peerId, kemVariant: variant.rawValue)
        logger.debug("✅ KEM 封装完成: peerId=\(peerId), variant=\(variant.rawValue)")
        return result
    }
    
 /// KEM 解封装 - 从封装数据恢复共享密钥
 /// - Parameters:
 /// - peerId: 对端设备 ID
 /// - encapsulated: 封装数据
 /// - variant: KEM 变体（默认 ML-KEM-768）
 /// - Returns: 共享密钥
    public func kemDecapsulate(
        peerId: String,
        encapsulated: Data,
        variant: CrossPlatformKEMVariant = .mlkem768
    ) async throws -> Data {
        guard let provider = provider else {
            throw PQCProtocolError.providerNotAvailable
        }
        
        guard currentSuite != .classic else {
            throw PQCProtocolError.operationNotSupportedInClassicMode("KEM")
        }
        
        let result = try await provider.kemDecapsulate(peerId: peerId, encapsulated: encapsulated, kemVariant: variant.rawValue)
        logger.debug("✅ KEM 解封装完成: peerId=\(peerId), variant=\(variant.rawValue)")
        return result
    }
    
 // MARK: - Digital Signature Operations
    
 /// 数字签名
 /// - Parameters:
 /// - data: 待签名数据
 /// - peerId: 签名者设备 ID
 /// - variant: 签名算法变体（默认 ML-DSA-65）
 /// - Returns: 签名数据
    public func sign(
        data: Data,
        peerId: String,
        variant: CrossPlatformSignatureVariant = .mldsa65
    ) async throws -> Data {
        guard let provider = provider else {
            throw PQCProtocolError.providerNotAvailable
        }
        
        guard currentSuite != .classic else {
            throw PQCProtocolError.operationNotSupportedInClassicMode("Sign")
        }
        
        let signature = try await provider.sign(data: data, peerId: peerId, algorithm: variant.rawValue)
        logger.debug("✅ 签名完成: dataSize=\(data.count), variant=\(variant.rawValue)")
        return signature
    }
    
 /// 验证签名
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名数据
 /// - peerId: 签名者设备 ID
 /// - variant: 签名算法变体（默认 ML-DSA-65）
 /// - Returns: 验证结果
    public func verify(
        data: Data,
        signature: Data,
        peerId: String,
        variant: CrossPlatformSignatureVariant = .mldsa65
    ) async -> Bool {
        guard let provider = provider else {
            logger.warning("⚠️ PQC provider 不可用，验证失败")
            return false
        }
        
        guard currentSuite != .classic else {
            logger.warning("⚠️ 经典模式不支持 PQC 签名验证")
            return false
        }
        
        let result = await provider.verify(data: data, signature: signature, peerId: peerId, algorithm: variant.rawValue)
        logger.debug("✅ 签名验证完成: result=\(result), variant=\(variant.rawValue)")
        return result
    }
    
 // MARK: - HPKE Operations
    
 /// HPKE 封装加密
 /// - Parameters:
 /// - recipientPeerId: 接收方设备 ID
 /// - plaintext: 明文数据
 /// - associatedData: 关联数据（AAD）
 /// - Returns: (密文, 封装密钥)
    public func hpkeSeal(
        recipientPeerId: String,
        plaintext: Data,
        associatedData: Data? = nil
    ) async throws -> (ciphertext: Data, encapsulatedKey: Data) {
        guard let provider = provider else {
            throw PQCProtocolError.providerNotAvailable
        }
        
        guard currentSuite == .hybrid else {
            throw PQCProtocolError.hpkeRequiresHybridMode
        }
        
        let result = try await provider.hpkeSeal(
            recipientPeerId: recipientPeerId,
            plaintext: plaintext,
            associatedData: associatedData
        )
        logger.debug("✅ HPKE Seal 完成: plaintextSize=\(plaintext.count), ciphertextSize=\(result.ciphertext.count)")
        return result
    }
    
 /// HPKE 解封装解密
 /// - Parameters:
 /// - recipientPeerId: 接收方设备 ID
 /// - ciphertext: 密文数据
 /// - encapsulatedKey: 封装密钥
 /// - associatedData: 关联数据（AAD）
 /// - Returns: 明文数据
    public func hpkeOpen(
        recipientPeerId: String,
        ciphertext: Data,
        encapsulatedKey: Data,
        associatedData: Data? = nil
    ) async throws -> Data {
        guard let provider = provider else {
            throw PQCProtocolError.providerNotAvailable
        }
        
        guard currentSuite == .hybrid else {
            throw PQCProtocolError.hpkeRequiresHybridMode
        }
        
        let result = try await provider.hpkeOpen(
            recipientPeerId: recipientPeerId,
            ciphertext: ciphertext,
            encapsulatedKey: encapsulatedKey,
            associatedData: associatedData
        )
        logger.debug("✅ HPKE Open 完成: ciphertextSize=\(ciphertext.count), plaintextSize=\(result.count)")
        return result
    }
}

// MARK: - PQC 能力协商

@available(macOS 14.0, *)
extension PQCProtocolAdapter {
    
 /// PQC 能力声明 - 用于能力协商
    public struct PQCCapabilityDeclaration: Codable, Sendable, Equatable {
        public let supportedSuites: [String]
        public let supportedKEMVariants: [String]
        public let supportedSignatureVariants: [String]
        public let preferredSuite: String
        public let backend: String
        
        public init(
            supportedSuites: [String],
            supportedKEMVariants: [String],
            supportedSignatureVariants: [String],
            preferredSuite: String,
            backend: String
        ) {
            self.supportedSuites = supportedSuites
            self.supportedKEMVariants = supportedKEMVariants
            self.supportedSignatureVariants = supportedSignatureVariants
            self.preferredSuite = preferredSuite
            self.backend = backend
        }
    }
    
 /// 生成本地 PQC 能力声明
    public func generateCapabilityDeclaration() -> PQCCapabilityDeclaration {
        PQCCapabilityDeclaration(
            supportedSuites: supportedSuites.map(\.rawValue),
            supportedKEMVariants: CrossPlatformKEMVariant.allCases.map(\.rawValue),
            supportedSignatureVariants: CrossPlatformSignatureVariant.allCases.map(\.rawValue),
            preferredSuite: currentSuite.rawValue,
            backend: backend.rawValue
        )
    }
    
 /// 协商 PQC 算法套件
 /// - Parameter remoteCapability: 远端设备的 PQC 能力声明
 /// - Returns: 协商结果（共同支持的最高安全级别套件）
    public func negotiateSuite(with remoteCapability: PQCCapabilityDeclaration) throws -> CrossPlatformPQCSuite {
        let localSuites = Set(supportedSuites.map(\.rawValue))
        let remoteSuites = Set(remoteCapability.supportedSuites)
        let commonSuites = localSuites.intersection(remoteSuites)
        
        guard !commonSuites.isEmpty else {
            throw PQCProtocolError.noCommonSuite
        }
        
 // 优先级：hybrid > pqc > classic
        if commonSuites.contains(CrossPlatformPQCSuite.hybrid.rawValue) {
            return .hybrid
        } else if commonSuites.contains(CrossPlatformPQCSuite.pqc.rawValue) {
            return .pqc
        } else {
            return .classic
        }
    }
    
 /// 协商 KEM 变体
    public func negotiateKEMVariant(with remoteVariants: [String]) -> CrossPlatformKEMVariant? {
        let localVariants = Set(CrossPlatformKEMVariant.allCases.map(\.rawValue))
        let remoteSet = Set(remoteVariants)
        let common = localVariants.intersection(remoteSet)
        
 // 优先选择更高安全级别
        if common.contains(CrossPlatformKEMVariant.mlkem1024.rawValue) {
            return .mlkem1024
        } else if common.contains(CrossPlatformKEMVariant.mlkem768.rawValue) {
            return .mlkem768
        }
        return nil
    }
    
 /// 协商签名算法变体
    public func negotiateSignatureVariant(with remoteVariants: [String]) -> CrossPlatformSignatureVariant? {
        let localVariants = Set(CrossPlatformSignatureVariant.allCases.map(\.rawValue))
        let remoteSet = Set(remoteVariants)
        let common = localVariants.intersection(remoteSet)
        
 // 优先选择更高安全级别
        if common.contains(CrossPlatformSignatureVariant.mldsa87.rawValue) {
            return .mldsa87
        } else if common.contains(CrossPlatformSignatureVariant.mldsa65.rawValue) {
            return .mldsa65
        }
        return nil
    }
}

// MARK: - PQC 协议错误

@available(macOS 14.0, *)
public enum PQCProtocolError: Error, LocalizedError, Sendable {
    case providerNotAvailable
    case unsupportedSuite(String)
    case operationNotSupportedInClassicMode(String)
    case hpkeRequiresHybridMode
    case noCommonSuite
    case kemEncapsulationFailed(String)
    case kemDecapsulationFailed(String)
    case signatureFailed(String)
    case verificationFailed(String)
    case hpkeSealFailed(String)
    case hpkeOpenFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .providerNotAvailable:
            return "PQC provider 不可用"
        case .unsupportedSuite(let suite):
            return "不支持的算法套件: \(suite)"
        case .operationNotSupportedInClassicMode(let op):
            return "经典模式不支持 \(op) 操作"
        case .hpkeRequiresHybridMode:
            return "HPKE 需要混合模式"
        case .noCommonSuite:
            return "没有共同支持的算法套件"
        case .kemEncapsulationFailed(let reason):
            return "KEM 封装失败: \(reason)"
        case .kemDecapsulationFailed(let reason):
            return "KEM 解封装失败: \(reason)"
        case .signatureFailed(let reason):
            return "签名失败: \(reason)"
        case .verificationFailed(let reason):
            return "验证失败: \(reason)"
        case .hpkeSealFailed(let reason):
            return "HPKE Seal 失败: \(reason)"
        case .hpkeOpenFailed(let reason):
            return "HPKE Open 失败: \(reason)"
        }
    }
}

// MARK: - 跨平台状态报告

@available(macOS 14.0, *)
extension PQCProtocolAdapter {
    
 /// PQC 状态报告
    public struct StatusReport: Sendable {
        public let isAvailable: Bool
        public let backend: String
        public let currentSuite: String
        public let supportedSuites: [String]
        public let systemInfo: String
    }
    
 /// 生成状态报告
    public func generateStatusReport() -> StatusReport {
        StatusReport(
            isAvailable: isPQCAvailable,
            backend: backend.rawValue,
            currentSuite: currentSuite.rawValue,
            supportedSuites: supportedSuites.map(\.rawValue),
            systemInfo: PQCSystemRequirements.supportStatus
        )
    }
}
