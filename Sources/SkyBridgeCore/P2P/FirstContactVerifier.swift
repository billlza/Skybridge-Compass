//
// FirstContactVerifier.swift
// SkyBridgeCore
//
// 13.2: First Contact Verifier
// Requirements: 10.1, 10.2, 10.3, 10.4, 10.5
//
// 首次接触验证器：
// - 根据 MessageA 的编码路径选择验证器
// - Legacy 路径：P-256 验证（需要安全前置条件）
// - Modern 路径：根据 offeredSuites 选择 Ed25519 或 ML-DSA-65
//

import Foundation

// MARK: - FirstContactVerificationResult

/// 首次接触验证结果
public enum FirstContactVerificationResult: Sendable {
 /// 验证成功（Modern 路径）
    case modernVerified(algorithm: ProtocolSigningAlgorithm)
    
 /// 验证成功（Legacy 路径）
    case legacyVerified(precondition: LegacyTrustPrecondition)
    
 /// 验证失败
    case failed(reason: String)
}

// MARK: - MessageEncodingPath

/// MessageA 编码路径
public enum MessageEncodingPath: String, Sendable {
 /// Modern 编码路径（使用 ProtocolSigningAlgorithm）
    case modern
    
 /// Legacy 编码路径（使用 P-256 ECDSA）
    case legacy
}

// MARK: - FirstContactVerifier

/// 首次接触验证器
///
/// 负责验证首次接触时的签名，避免循环依赖。
/// 验证器选择不依赖于 sigA 本身的真实性。
///
/// **Requirements: 10.1, 10.2, 10.3, 10.4, 10.5**
@available(macOS 14.0, iOS 17.0, *)
public struct FirstContactVerifier: Sendable {
    
 // MARK: - Properties
    
 /// Legacy 签名验证器
    private let legacyVerifier: P256LegacyVerifier
    
 /// Classic 签名 Provider
    private let classicProvider: ClassicSignatureProvider
    
 /// PQC 签名 Provider
    private let pqcProvider: PQCSignatureProvider
    
 // MARK: - Initialization
    
    public init() {
        self.legacyVerifier = P256LegacyVerifier()
        self.classicProvider = ClassicSignatureProvider()
        self.pqcProvider = PQCSignatureProvider(backend: .auto)
    }
    
 // MARK: - Public Methods
    
 /// 验证首次接触的签名
 ///
 /// **算法选择规则**（无循环依赖）：
 /// 1. 如果 MessageA 使用 legacy 编码路径（P-256），走 legacy 验证
 /// 2. 如果 MessageA 使用 modern 编码路径：
 /// - 如果 offeredSuites 包含任何 isPQCGroup 的 suite → ML-DSA-65
 /// - 否则 → Ed25519
 ///
 /// - Parameters:
 /// - data: 待验证数据（签名覆盖的 preimage）
 /// - signature: 签名
 /// - publicKey: 公钥
 /// - encodingPath: 编码路径
 /// - offeredSuites: MessageA 中的 offeredSuites（modern 路径需要）
 /// - precondition: Legacy 前置条件（legacy 路径需要）
 /// - Returns: 验证结果
    public func verify(
        data: Data,
        signature: Data,
        publicKey: Data,
        encodingPath: MessageEncodingPath,
        offeredSuites: [CryptoSuite],
        precondition: LegacyTrustPrecondition?
    ) async throws -> FirstContactVerificationResult {
        switch encodingPath {
        case .legacy:
            return try await verifyLegacy(
                data: data,
                signature: signature,
                publicKey: publicKey,
                precondition: precondition
            )
            
        case .modern:
            return try await verifyModern(
                data: data,
                signature: signature,
                publicKey: publicKey,
                offeredSuites: offeredSuites
            )
        }
    }
    
 /// 确定 MessageA 的编码路径
 ///
 /// 根据 wire 层的 signatureAlgorithm 判断编码路径。
 ///
 /// - Parameter wireAlgorithm: Wire 层的签名算法
 /// - Returns: 编码路径
    public func determineEncodingPath(
        wireAlgorithm: SignatureAlgorithm
    ) -> MessageEncodingPath {
        switch wireAlgorithm {
        case .p256ECDSA:
            return .legacy
        case .ed25519, .mlDSA65:
            return .modern
        }
    }
    
 /// 根据 offeredSuites 选择 modern 路径的签名算法
 ///
 /// **Requirements: 10.3, 10.4**
 ///
 /// - Parameter offeredSuites: MessageA 中的 offeredSuites
 /// - Returns: 协议签名算法
    public func selectModernAlgorithm(
        offeredSuites: [CryptoSuite]
    ) -> ProtocolSigningAlgorithm {
 // 如果 offeredSuites 包含任何 isPQCGroup 的 suite → ML-DSA-65
        let hasPQCOrHybrid = offeredSuites.contains { $0.isPQCGroup }
        return hasPQCOrHybrid ? .mlDSA65 : .ed25519
    }
    
 // MARK: - Private Methods
    
 /// 验证 Legacy 路径签名
    private func verifyLegacy(
        data: Data,
        signature: Data,
        publicKey: Data,
        precondition: LegacyTrustPrecondition?
    ) async throws -> FirstContactVerificationResult {
 // 1. 检查前置条件
        guard let precondition = precondition else {
            throw LegacyFallbackError.legacyFallbackNotAllowed(
                reason: "No precondition provided for legacy verification"
            )
        }
        
        guard precondition.isSatisfied else {
            throw LegacyFallbackError.preconditionNotSatisfied(type: precondition.type)
        }
        
 // 2. 使用 P256LegacyVerifier 验证（verify-only，无 sign）
        let isValid = try await legacyVerifier.verify(
            data,
            signature: signature,
            publicKey: publicKey
        )
        
        if isValid {
            return .legacyVerified(precondition: precondition)
        } else {
            return .failed(reason: "Legacy P-256 signature verification failed")
        }
    }
    
 /// 验证 Modern 路径签名
    private func verifyModern(
        data: Data,
        signature: Data,
        publicKey: Data,
        offeredSuites: [CryptoSuite]
    ) async throws -> FirstContactVerificationResult {
 // 1. 根据 offeredSuites 选择算法
        let algorithm = selectModernAlgorithm(offeredSuites: offeredSuites)
        
 // 2. 选择对应的 Provider 验证
        let isValid: Bool
        switch algorithm {
        case .ed25519:
            isValid = try await classicProvider.verify(
                data,
                signature: signature,
                publicKey: publicKey
            )
        case .mlDSA65:
            isValid = try await pqcProvider.verify(
                data,
                signature: signature,
                publicKey: publicKey
            )
        }
        
        if isValid {
            return .modernVerified(algorithm: algorithm)
        } else {
            return .failed(reason: "\(algorithm.rawValue) signature verification failed")
        }
    }
}

// MARK: - FirstContactVerifier + TrustRecord Integration

@available(macOS 14.0, iOS 17.0, *)
extension FirstContactVerifier {
    
 /// 验证首次接触并更新 TrustRecord
 ///
 /// - Parameters:
 /// - data: 待验证数据
 /// - signature: 签名
 /// - publicKey: 公钥
 /// - wireAlgorithm: Wire 层签名算法
 /// - offeredSuites: MessageA 中的 offeredSuites
 /// - deviceId: 对端设备 ID
 /// - trustRecord: 已有的 TrustRecord（如果存在）
 /// - pairingContext: 配对上下文
 /// - Returns: 验证结果和建议的 TrustRecord 更新
    public func verifyAndSuggestTrustUpdate(
        data: Data,
        signature: Data,
        publicKey: Data,
        wireAlgorithm: SignatureAlgorithm,
        offeredSuites: [CryptoSuite],
        deviceId: String,
        trustRecord: TrustRecord?,
        pairingContext: PairingContext?
    ) async throws -> (result: FirstContactVerificationResult, trustUpdate: TrustRecordUpdate?) {
 // 1. 确定编码路径
        let encodingPath = determineEncodingPath(wireAlgorithm: wireAlgorithm)
        
 // 2. 检查前置条件（仅 legacy 路径需要）
        let precondition: LegacyTrustPrecondition?
        if encodingPath == .legacy {
            precondition = LegacyTrustPreconditionChecker.check(
                deviceId: deviceId,
                trustRecord: trustRecord,
                pairingContext: pairingContext
            )
        } else {
            precondition = nil
        }
        
 // 3. 验证签名
        let result = try await verify(
            data: data,
            signature: signature,
            publicKey: publicKey,
            encodingPath: encodingPath,
            offeredSuites: offeredSuites,
            precondition: precondition
        )
        
 // 4. 生成 TrustRecord 更新建议
        let trustUpdate: TrustRecordUpdate?
        switch result {
        case .legacyVerified:
 // Legacy 验证成功：存储为 legacyP256PublicKey，触发升级流程
            trustUpdate = TrustRecordUpdate(
                deviceId: deviceId,
                legacyP256PublicKey: publicKey,
                protocolPublicKey: nil,
                signatureAlgorithm: .p256ECDSA,
                requiresUpgrade: true
            )
            
        case .modernVerified(let algorithm):
 // Modern 验证成功：存储为 protocolPublicKey
            trustUpdate = TrustRecordUpdate(
                deviceId: deviceId,
                legacyP256PublicKey: nil,
                protocolPublicKey: publicKey,
                signatureAlgorithm: algorithm.wire,
                requiresUpgrade: false
            )
            
        case .failed:
            trustUpdate = nil
        }
        
        return (result, trustUpdate)
    }
}

// MARK: - TrustRecordUpdate

/// TrustRecord 更新建议
public struct TrustRecordUpdate: Sendable {
 /// 设备 ID
    public let deviceId: String
    
 /// Legacy P-256 公钥（如果是 legacy 验证）
    public let legacyP256PublicKey: Data?
    
 /// 协议公钥（如果是 modern 验证）
    public let protocolPublicKey: Data?
    
 /// 签名算法
    public let signatureAlgorithm: SignatureAlgorithm
    
 /// 是否需要升级（legacy → modern）
    public let requiresUpgrade: Bool
    
    public init(
        deviceId: String,
        legacyP256PublicKey: Data?,
        protocolPublicKey: Data?,
        signatureAlgorithm: SignatureAlgorithm,
        requiresUpgrade: Bool
    ) {
        self.deviceId = deviceId
        self.legacyP256PublicKey = legacyP256PublicKey
        self.protocolPublicKey = protocolPublicKey
        self.signatureAlgorithm = signatureAlgorithm
        self.requiresUpgrade = requiresUpgrade
    }
}
