//
// DeviceCertificateIssuer.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Device Certificate Issuer
// Requirements: 2.6, 4.1
//
// 设备证书签发和验证：
// 1. 自签名证书（首次配对）
// 2. 配对确认证书（PAKE 成功后）
// 3. 用户域签名证书（可选，企业场景）
//
// pubKeyFP 存储：full SHA-256 hex (64 chars)
// UI 显示：截断到前 12-16 chars 作为 short id
//

import Foundation
import CryptoKit

// MARK: - Certificate Signer Type

/// 证书签名者类型
public enum CertificateSignerType: String, Codable, Sendable {
 /// 自签名（设备自己签名）
    case selfSigned = "self-signed"
    
 /// 配对确认（PAKE 成功后由对端确认）
    case pairingConfirmed = "pairing-confirmed"
    
 /// 用户域签名（企业 CA 签名）
    case userDomainSigned = "user-domain-signed"
}

// MARK: - P2P Device Certificate

/// P2P 设备证书（用于 P2P 认证）
public struct P2PIdentityCertificate: Codable, Sendable, Equatable, TranscriptEncodable {
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥 (DER 编码)
    public let publicKey: Data
    
 /// 公钥指纹 (SHA-256 hex, 64 chars)
    public let pubKeyFP: String

 /// KEM 身份公钥（可选）
    public let kemPublicKeys: [KEMPublicKeyInfo]?
    
 /// 证明等级
    public let attestationLevel: P2PAttestationLevel
    
 /// 证明数据（App Attest 数据，需服务器验证）
    public let attestationData: Data?
    
 /// 设备能力
    public let capabilities: [String]
    
 /// 签名者类型
    public let signerType: CertificateSignerType
    
 /// 签名者 ID（如果是配对确认或域签名）
    public let signerId: String?
    
 /// 证书版本
    public let version: Int
    
 /// 创建时间
    public let createdAt: Date
    
 /// 过期时间
    public let expiresAt: Date
    
 /// 签名
    public let signature: Data

    
 /// 短 ID（用于 UI 显示）
    public var shortId: String {
        String(pubKeyFP.prefix(P2PConstants.pubKeyFPDisplayLength))
    }
    
    public init(
        deviceId: String,
        publicKey: Data,
        pubKeyFP: String,
        kemPublicKeys: [KEMPublicKeyInfo]? = nil,
        attestationLevel: P2PAttestationLevel,
        attestationData: Data? = nil,
        capabilities: [String],
        signerType: CertificateSignerType,
        signerId: String? = nil,
        version: Int = 1,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        signature: Data
    ) {
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.pubKeyFP = pubKeyFP
        self.kemPublicKeys = kemPublicKeys
        self.attestationLevel = attestationLevel
        self.attestationData = attestationData
        self.capabilities = capabilities
        self.signerType = signerType
        self.signerId = signerId
        self.version = version
        self.createdAt = createdAt
 // 默认有效期 1 年
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(365 * 24 * 60 * 60)
        self.signature = signature
    }
    
 /// 证书是否过期
    public var isExpired: Bool {
        Date() > expiresAt
    }
    
 /// 确定性编码（用于 Transcript）
    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(deviceId)
        encoder.encode(publicKey)
        encoder.encode(pubKeyFP)
        encoder.encode(kemPublicKeys, encoder: { enc, keys in
            let sorted = keys.sorted { $0.suiteWireId < $1.suiteWireId }
            enc.encode(sorted, encoder: { inner, key in
                inner.encode(key.suiteWireId)
                inner.encode(key.publicKey)
            })
        })
        encoder.encode(UInt8(attestationLevel.rawValue))
        encoder.encode(attestationData, encoder: { enc, data in enc.encode(data) })
        encoder.encode(capabilities)
        encoder.encode(signerType.rawValue)
        encoder.encode(signerId, encoder: { enc, str in enc.encode(str) })
        encoder.encode(Int64(version))
        encoder.encode(createdAt)
        encoder.encode(expiresAt)
 // 注意：签名不进入编码（签名是对其他字段的签名）
        return encoder.finalize()
    }
    
 /// 获取待签名数据
    public func dataToSign() throws -> Data {
        try deterministicEncode()
    }
}

// MARK: - Certificate Error

/// 证书错误
public enum CertificateError: Error, LocalizedError, Sendable {
    case generationFailed(String)
    case signatureFailed(String)
    case verificationFailed(String)
    case expired
    case invalidSignature
    case invalidPublicKey
    case untrusted
    case attestationRequired
    
    public var errorDescription: String? {
        switch self {
        case .generationFailed(let reason):
            return "Certificate generation failed: \(reason)"
        case .signatureFailed(let reason):
            return "Certificate signature failed: \(reason)"
        case .verificationFailed(let reason):
            return "Certificate verification failed: \(reason)"
        case .expired:
            return "Certificate has expired"
        case .invalidSignature:
            return "Invalid certificate signature"
        case .invalidPublicKey:
            return "Invalid public key in certificate"
        case .untrusted:
            return "Certificate is not trusted"
        case .attestationRequired:
            return "Attestation is required but not provided"
        }
    }
}

// MARK: - Device Certificate Issuer

/// 设备证书签发器
@available(macOS 14.0, iOS 17.0, *)
public actor P2PIdentityCertificateIssuer {
    
 // MARK: - Singleton
    
 /// 共享实例
    public static let shared = P2PIdentityCertificateIssuer()
    
 // MARK: - Properties
    
 /// 密钥管理器
    private let keyManager = DeviceIdentityKeyManager.shared
    
 /// 缓存的本机证书
    private var cachedCertificate: P2PIdentityCertificate?
    
 // MARK: - Initialization
    
    private init() {}
    
 // MARK: - Public Methods
    
 /// 获取或创建本机证书
 /// - Returns: 设备证书
    public func getOrCreateLocalCertificate() async throws -> P2PIdentityCertificate {
 // 检查缓存
        if let cached = cachedCertificate, !cached.isExpired {
            return cached
        }
        
 // 创建新证书
        let certificate = try await createSelfSignedCertificate()
        cachedCertificate = certificate
        return certificate
    }
    
 /// 创建自签名证书
 /// - Returns: 自签名设备证书
    public func createSelfSignedCertificate() async throws -> P2PIdentityCertificate {
 // 获取身份密钥
        let keyInfo = try await keyManager.getOrCreateIdentityKey()
        let kemPublicKeys = try await getLocalKEMPublicKeys()
        
 // 获取设备能力
        let capabilities = getDeviceCapabilities()
        
 // 创建未签名证书
        let unsignedCert = P2PIdentityCertificate(
            deviceId: keyInfo.deviceId,
            publicKey: keyInfo.publicKey,
            pubKeyFP: keyInfo.pubKeyFP,
            kemPublicKeys: kemPublicKeys,
            attestationLevel: .none,
            attestationData: nil,
            capabilities: capabilities,
            signerType: .selfSigned,
            signerId: nil,
            signature: Data() // 临时空签名
        )
        
 // 签名
        let dataToSign = try unsignedCert.dataToSign()
        let signature = try await keyManager.sign(data: dataToSign)
        
 // 创建签名后的证书
        let signedCert = P2PIdentityCertificate(
            deviceId: keyInfo.deviceId,
            publicKey: keyInfo.publicKey,
            pubKeyFP: keyInfo.pubKeyFP,
            kemPublicKeys: kemPublicKeys,
            attestationLevel: .none,
            attestationData: nil,
            capabilities: capabilities,
            signerType: .selfSigned,
            signerId: nil,
            signature: signature
        )
        
        SkyBridgeLogger.p2p.info("Created self-signed certificate: \(signedCert.shortId)")
        return signedCert
    }

    private func getLocalKEMPublicKeys() async throws -> [KEMPublicKeyInfo] {
        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        guard provider.activeSuite.isPQC else {
            return []
        }
        
        var keys: [KEMPublicKeyInfo] = []
        
        let primaryPublicKey = try await keyManager.getKEMPublicKey(
            for: provider.activeSuite,
            provider: provider
        )
        keys.append(KEMPublicKeyInfo(suiteWireId: provider.activeSuite.wireId, publicKey: primaryPublicKey))
        
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            if provider.tier == .nativePQC, provider.activeSuite != .xwingMLDSA {
                let xwingProvider = AppleXWingCryptoProvider()
                let xwingPublicKey = try await keyManager.getKEMPublicKey(
                    for: xwingProvider.activeSuite,
                    provider: xwingProvider
                )
                keys.append(KEMPublicKeyInfo(suiteWireId: xwingProvider.activeSuite.wireId, publicKey: xwingPublicKey))
            }
        }
        #endif
        
        return keys
    }

    
 /// 创建配对确认证书
 /// - Parameters:
 /// - peerCertificate: 对端证书
 /// - pairingSecret: 配对共享密钥（用于额外验证）
 /// - Returns: 配对确认证书
    public func createPairingConfirmedCertificate(
        for peerCertificate: P2PIdentityCertificate,
        pairingSecret: Data
    ) async throws -> P2PIdentityCertificate {
 // 获取本机身份密钥
        let keyInfo = try await keyManager.getOrCreateIdentityKey()
        
 // 验证对端证书
        guard try await verifyCertificate(peerCertificate) else {
            throw CertificateError.invalidSignature
        }
        
 // 创建确认证书（本机签名对端的证书）
        let confirmedCert = P2PIdentityCertificate(
            deviceId: peerCertificate.deviceId,
            publicKey: peerCertificate.publicKey,
            pubKeyFP: peerCertificate.pubKeyFP,
            kemPublicKeys: peerCertificate.kemPublicKeys,
            attestationLevel: peerCertificate.attestationLevel,
            attestationData: peerCertificate.attestationData,
            capabilities: peerCertificate.capabilities,
            signerType: .pairingConfirmed,
            signerId: keyInfo.deviceId,
            signature: Data() // 临时空签名
        )
        
 // 使用本机密钥签名
        let dataToSign = try confirmedCert.dataToSign()
        let signature = try await keyManager.sign(data: dataToSign)
        
 // 创建签名后的证书
        let signedCert = P2PIdentityCertificate(
            deviceId: peerCertificate.deviceId,
            publicKey: peerCertificate.publicKey,
            pubKeyFP: peerCertificate.pubKeyFP,
            kemPublicKeys: peerCertificate.kemPublicKeys,
            attestationLevel: peerCertificate.attestationLevel,
            attestationData: peerCertificate.attestationData,
            capabilities: peerCertificate.capabilities,
            signerType: .pairingConfirmed,
            signerId: keyInfo.deviceId,
            signature: signature
        )
        
        SkyBridgeLogger.p2p.info("Created pairing-confirmed certificate for: \(signedCert.shortId)")
        return signedCert
    }
    
 /// 验证证书
 /// - Parameter certificate: 待验证证书
 /// - Returns: 是否验证通过
    public func verifyCertificate(_ certificate: P2PIdentityCertificate) async throws -> Bool {
 // 检查过期
        if certificate.isExpired {
            throw CertificateError.expired
        }
        
 // 验证公钥指纹
        let computedFP = computePublicKeyFingerprint(certificate.publicKey)
        guard computedFP == certificate.pubKeyFP else {
            throw CertificateError.invalidPublicKey
        }
        
 // 根据签名者类型验证签名
        switch certificate.signerType {
        case .selfSigned:
 // 自签名：使用证书中的公钥验证
            return try await verifySignature(
                certificate: certificate,
                signerPublicKey: certificate.publicKey
            )
            
        case .pairingConfirmed:
 // 配对确认：需要签名者的公钥
            guard let signerId = certificate.signerId else {
                throw CertificateError.verificationFailed("Missing signer ID")
            }
            guard let signerRecord = await TrustSyncService.shared.getTrustRecord(deviceId: signerId) else {
                throw CertificateError.untrusted
            }
            SkyBridgeLogger.p2p.debug("Verifying pairing-confirmed cert, signer: \(signerId)")
            return try await verifySignature(
                certificate: certificate,
                signerPublicKey: signerRecord.publicKey
            )
            
        case .userDomainSigned:
 // 用户域签名：需要 CA 公钥
            throw CertificateError.verificationFailed("User domain verification not implemented")
        }
    }
    
 /// 验证证书签名
    private func verifySignature(
        certificate: P2PIdentityCertificate,
        signerPublicKey: Data
    ) async throws -> Bool {
        let dataToVerify = try certificate.dataToSign()
        return try await keyManager.verify(
            data: dataToVerify,
            signature: certificate.signature,
            publicKey: signerPublicKey
        )
    }
    
 /// 计算公钥指纹
    private func computePublicKeyFingerprint(_ publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
 /// 获取设备能力
    private func getDeviceCapabilities() -> [String] {
        var capabilities: [String] = [
            "p2p-v1",
            "file-transfer",
            "screen-mirror"
        ]
        
        #if os(macOS)
        capabilities.append("remote-desktop-host")
        capabilities.append("system-control")
        #endif
        
        #if os(iOS)
        capabilities.append("touch-input")
        capabilities.append("replaykit")
        #endif
        
 // 检查 PQC 支持
        if #available(iOS 26.0, macOS 26.0, *) {
            capabilities.append("pqc-native")
        }
        
        return capabilities
    }
    
 /// 清除缓存
    public func clearCache() {
        cachedCertificate = nil
    }
    
 /// 刷新证书（轮换密钥后调用）
    public func refreshCertificate() async throws -> P2PIdentityCertificate {
        cachedCertificate = nil
        return try await getOrCreateLocalCertificate()
    }
}

// MARK: - Certificate Validation Result

/// 证书验证结果
public struct CertificateValidationResult: Sendable {
 /// 是否有效
    public let isValid: Bool
    
 /// 验证错误（如果有）
    public let error: CertificateError?
    
 /// 信任等级
    public let trustLevel: TrustLevel
    
 /// 信任等级
    public enum TrustLevel: Int, Sendable {
        case untrusted = 0
        case selfSigned = 1
        case pairingConfirmed = 2
        case domainSigned = 3
    }
    
    public init(isValid: Bool, error: CertificateError? = nil, trustLevel: TrustLevel) {
        self.isValid = isValid
        self.error = error
        self.trustLevel = trustLevel
    }
    
 /// 成功结果
    public static func success(trustLevel: TrustLevel) -> CertificateValidationResult {
        CertificateValidationResult(isValid: true, trustLevel: trustLevel)
    }
    
 /// 失败结果
    public static func failure(_ error: CertificateError) -> CertificateValidationResult {
        CertificateValidationResult(isValid: false, error: error, trustLevel: .untrusted)
    }
}
