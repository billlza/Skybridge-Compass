//
// HandshakeMessages.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 10.2: 握手消息定义
// Requirements: 4.1
//
// 握手消息结构定义：
// - HandshakeMessageA: 发起方发送的第一条消息
// - HandshakeMessageB: 响应方发送的回复消息
//

import Foundation
import CryptoKit

private enum HandshakeSignatureDomain {
    static let protocolA = "SkyBridge-A"
    static let protocolB = "SkyBridge-B"
    static let secureEnclaveA = "SkyBridge-SE-A"
    static let secureEnclaveB = "SkyBridge-SE-B"
}

// MARK: - HandshakeKeyShare

/// 握手 KeyShare
public struct HandshakeKeyShare: Sendable, Equatable {
    public let suite: CryptoSuite
    public let shareBytes: Data
    
    public init(suite: CryptoSuite, shareBytes: Data) {
        self.suite = suite
        self.shareBytes = shareBytes
    }
}

// MARK: - IdentityPublicKeys ( 6.1)

/// 身份公钥结构
///
/// 包含协议签名公钥和可选的 Secure Enclave PoP 公钥。
/// 用于 MessageA/MessageB 中的身份公钥字段。
///
/// **向后兼容策略**:
/// - 解码时：旧格式 `identityPubKey: Data` 解析为 `IdentityPublicKeys(protocolPublicKey: oldData, protocolAlgorithm: .p256ECDSA, secureEnclavePublicKey: nil)`
/// - 编码时：新版本永远只编码新结构
///
/// **Requirements: 2.1**
public struct IdentityPublicKeys: Sendable, Equatable, Codable {
 /// 协议签名公钥 (Ed25519 或 ML-DSA-65)
    public let protocolPublicKey: Data
    
 /// 协议签名算法
    public let protocolAlgorithm: SignatureAlgorithm
    
 /// Secure Enclave PoP 公钥 (P-256, 可选)
    public let secureEnclavePublicKey: Data?
    
    public init(
        protocolPublicKey: Data,
        protocolAlgorithm: SignatureAlgorithm,
        secureEnclavePublicKey: Data? = nil
    ) {
        self.protocolPublicKey = protocolPublicKey
        self.protocolAlgorithm = protocolAlgorithm
        self.secureEnclavePublicKey = secureEnclavePublicKey
    }
    
 /// 从 legacy 格式创建（向后兼容）
 ///
 /// 旧版本只有一个 P-256 公钥，用于所有签名。
 /// 迁移期间，将其视为 legacy P-256 ECDSA 公钥。
    public static func fromLegacy(_ publicKey: Data) -> IdentityPublicKeys {
        IdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: .p256ECDSA,
            secureEnclavePublicKey: nil
        )
    }
    
 /// 编码为二进制格式
 ///
 /// 格式：
 /// ```
 /// protocolAlgorithm(1B) || protocolPublicKeyLen(2B LE) || protocolPublicKey ||
 /// hasSecureEnclaveKey(1B) || [secureEnclavePublicKeyLen(2B LE) || secureEnclavePublicKey]
 /// ```
    public var encoded: Data {
        var data = Data()
        
 // Protocol algorithm (1 byte)
        let algorithmByte: UInt8
        switch protocolAlgorithm {
        case .ed25519: algorithmByte = 0x01
        case .mlDSA65: algorithmByte = 0x02
        case .p256ECDSA: algorithmByte = 0x03
        }
        data.append(algorithmByte)
        
 // Protocol public key
        var keyLen = UInt16(protocolPublicKey.count).littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &keyLen) { Data($0) })
        data.append(protocolPublicKey)
        
 // Secure Enclave public key (optional)
        if let seKey = secureEnclavePublicKey {
            data.append(0x01) // has SE key
            var seKeyLen = UInt16(seKey.count).littleEndian
            data.append(contentsOf: withUnsafeBytes(of: &seKeyLen) { Data($0) })
            data.append(seKey)
        } else {
            data.append(0x00) // no SE key
        }
        
        return data
    }
    
 /// 从二进制格式解码
    public static func decode(from data: Data) throws -> IdentityPublicKeys {
        guard data.count >= 4 else {
            throw HandshakeError.failed(.invalidMessageFormat("IdentityPublicKeys too short"))
        }
        
        var offset = 0
        
 // Protocol algorithm
        let algorithmByte = data[offset]
        offset += 1
        
        let protocolAlgorithm: SignatureAlgorithm
        switch algorithmByte {
        case 0x01: protocolAlgorithm = .ed25519
        case 0x02: protocolAlgorithm = .mlDSA65
        case 0x03: protocolAlgorithm = .p256ECDSA
        default:
            throw HandshakeError.failed(.invalidMessageFormat("Unknown signature algorithm: \(algorithmByte)"))
        }
        
 // Protocol public key length
        guard offset + 2 <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("IdentityPublicKeys truncated"))
        }
        let keyLen = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        
 // Protocol public key
        guard offset + Int(keyLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Protocol public key truncated"))
        }
        let protocolPublicKey = data[offset..<(offset + Int(keyLen))]
        offset += Int(keyLen)
        
 // Secure Enclave public key (optional)
        var secureEnclavePublicKey: Data?
        if offset < data.count {
            let hasSEKey = data[offset]
            offset += 1
            
            if hasSEKey == 0x01 {
                guard offset + 2 <= data.count else {
                    throw HandshakeError.failed(.invalidMessageFormat("SE key length truncated"))
                }
                let seKeyLen = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                offset += 2
                
                guard offset + Int(seKeyLen) <= data.count else {
                    throw HandshakeError.failed(.invalidMessageFormat("SE public key truncated"))
                }
                secureEnclavePublicKey = Data(data[offset..<(offset + Int(seKeyLen))])
            }
        }
        
        return IdentityPublicKeys(
            protocolPublicKey: Data(protocolPublicKey),
            protocolAlgorithm: protocolAlgorithm,
            secureEnclavePublicKey: secureEnclavePublicKey
        )
    }
    
 /// 尝试从 legacy 格式解码（向后兼容）
 ///
 /// 如果数据不是新格式，则**严格验证**是否为 legacy P-256 公钥。
 ///
 /// **安全加固**：
 /// - 只有满足 "标准未压缩 P-256 公钥" 格式（0x04 + 64 bytes = 65 bytes）时才允许 legacy
 /// - 其他情况直接报错，防止任意垃圾数据被当作 legacy 公钥接受
    public static func decodeWithLegacyFallback(from data: Data) throws -> IdentityPublicKeys {
 // 尝试新格式
        if data.count >= 4 {
            let algorithmByte = data[0]
            if algorithmByte >= 0x01 && algorithmByte <= 0x03 {
 // 可能是新格式，尝试解码
                if let result = try? decode(from: data) {
                    return result
                }
            }
        }

 // 严格验证 legacy P-256 公钥格式：
 // - 标准未压缩格式：0x04 前缀 + 64 bytes (X || Y 坐标)
 // - 总长度必须为 65 bytes
        guard data.count == 65, data.first == 0x04 else {
            throw HandshakeError.failed(.invalidMessageFormat(
                "IdentityPublicKeys not decodable: expected new format or legacy P-256 uncompressed public key (65 bytes starting with 0x04), got \(data.count) bytes"
            ))
        }

        return fromLegacy(data)
    }
    
 /// 转换为内部已验证模型
 ///
 /// **设计原则**:
 /// - Wire 层 (IdentityPublicKeys) 保持 SignatureAlgorithm 用于 Codable 兼容
 /// - 内部模型 (ProtocolIdentityPublicKeys) 使用 ProtocolSigningAlgorithm，类型层面排除 P-256
 ///
 /// - Throws: SignatureAlignmentError.invalidAlgorithmForProtocolSigning if algorithm is .p256ECDSA
 /// - Returns: ProtocolIdentityPublicKeys with validated algorithm
 ///
 /// **Requirements: 1.1, 1.2**
    public func asProtocolIdentityKeys() throws -> ProtocolIdentityPublicKeys {
        guard let protocolAlg = ProtocolSigningAlgorithm(from: protocolAlgorithm) else {
            throw SignatureAlignmentError.invalidAlgorithmForProtocolSigning(
                algorithm: protocolAlgorithm
            )
        }
        return ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: protocolAlg,
            sePoPPublicKey: secureEnclavePublicKey
        )
    }
}

// MARK: - IdentityPublicKeysWire (Wire Layer Alias)

/// Wire 层身份公钥（用于 Codable 编解码）
///
/// **设计原则**:
/// - 保持 SignatureAlgorithm 类型，可解码 legacy .p256ECDSA
/// - 不改变现有 MessageA/MessageB 的 Codable 格式
/// - 与 IdentityPublicKeys 结构相同，作为语义别名使用
///
/// **Requirements: 1.1, 1.2**
public typealias IdentityPublicKeysWire = IdentityPublicKeys

// MARK: - ProtocolIdentityPublicKeys (Validated Internal Model)

/// 内部已验证身份公钥（类型层面排除 P-256）
///
/// **设计原则**:
/// - 使用 ProtocolSigningAlgorithm，类型层面保证 P-256 不参与 sigA/sigB
/// - 只在 HandshakeDriver 内部使用
/// - 从 IdentityPublicKeysWire 通过 asProtocolIdentityKeys() 转换得到
///
/// **Requirements: 1.1, 1.2**
public struct ProtocolIdentityPublicKeys: Sendable, Equatable {
 /// 协议签名公钥 (Ed25519 或 ML-DSA-65)
    public let protocolPublicKey: Data
    
 /// 协议签名算法（类型层面排除 P-256）
    public let protocolAlgorithm: ProtocolSigningAlgorithm
    
 /// SE PoP 公钥 (P-256, 可选，用于 seSigA/seSigB)
    public let sePoPPublicKey: Data?
    
    public init(
        protocolPublicKey: Data,
        protocolAlgorithm: ProtocolSigningAlgorithm,
        sePoPPublicKey: Data? = nil
    ) {
        self.protocolPublicKey = protocolPublicKey
        self.protocolAlgorithm = protocolAlgorithm
        self.sePoPPublicKey = sePoPPublicKey
    }
    
 /// 转换为 Wire 层格式（用于发送方）
    public func asWire() -> IdentityPublicKeysWire {
        IdentityPublicKeysWire(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: protocolAlgorithm.wire,
            secureEnclavePublicKey: sePoPPublicKey
        )
    }
}

// MARK: - HandshakeMessageA

/// 握手消息 A（发起方 -> 响应方）
///
/// 格式：
/// ```
/// version(1B) || supportedSuitesCount(2B LE) || supportedSuites[] (2B LE each) ||
/// keySharesCount(2B LE) || keyShares[] (suiteId(2B LE) + shareLen(2B LE) + shareBytes) ||
/// clientNonce(32B) || capabilities(var) || policy(var) || identityPublicKey(var) || signature(var) || seSignature(var)
/// ```
public struct HandshakeMessageA: Sendable {
 /// 协议版本
    public let version: UInt8
    
 /// 支持的加密套件（按优先级排序）
    public let supportedSuites: [CryptoSuite]
    
 /// KeyShares（与 supportedSuites 绑定）
    public let keyShares: [HandshakeKeyShare]
    
 /// 客户端随机 nonce（防重放）
    public let clientNonce: Data
    
 /// 握手策略（用于降级防护）
    public let policy: HandshakePolicy
    
 /// 发起方能力声明
    public let capabilities: CryptoCapabilities
    
 /// 签名（覆盖上述所有字段）
    public let signature: Data
    
 /// 发起方身份公钥（用于验证签名）
 ///
 /// **Wire 格式**: 新版本编码为 `IdentityPublicKeys.encoded`，旧版本为原始公钥 Data
 /// 使用 `identityPublicKeys` 属性获取结构化数据
    public let identityPublicKey: Data
    
 /// Secure Enclave 签名（可选）
    public let secureEnclaveSignature: Data?
    
 /// 结构化身份公钥（ 6.2）
 ///
 /// 解析 `identityPublicKey` 字段为 `IdentityPublicKeys` 结构。
 /// 支持向后兼容：旧格式自动解析为 legacy P-256 ECDSA（严格验证 65 字节 + 0x04 前缀）。
 ///
 /// **安全加固**：移除了无条件 fallback，确保 decodeWithLegacyFallback 的收紧逻辑生效。
 /// 解码失败将抛出错误，调用方需将其映射为可控失败而非崩溃。
    public func decodedIdentityPublicKeys() throws -> IdentityPublicKeys {
        try IdentityPublicKeys.decodeWithLegacyFallback(from: identityPublicKey)
    }

    @available(*, deprecated, message: "Use decodedIdentityPublicKeys() and handle errors explicitly.")
    public var identityPublicKeys: IdentityPublicKeys? {
        try? decodedIdentityPublicKeys()
    }
    
    public init(
        version: UInt8 = HandshakeConstants.protocolVersion,
        supportedSuites: [CryptoSuite],
        keyShares: [HandshakeKeyShare],
        clientNonce: Data,
        policy: HandshakePolicy,
        capabilities: CryptoCapabilities,
        signature: Data,
        identityPublicKey: Data,
        secureEnclaveSignature: Data? = nil
    ) {
        self.version = version
        self.supportedSuites = supportedSuites
        self.keyShares = keyShares
        self.clientNonce = clientNonce
        self.policy = policy
        self.capabilities = capabilities
        self.signature = signature
        self.identityPublicKey = identityPublicKey
        self.secureEnclaveSignature = secureEnclaveSignature
    }
    
 /// 使用结构化身份公钥初始化（ 6.2）
 ///
 /// 新版本应使用此初始化器，自动编码为新格式。
    public init(
        version: UInt8 = HandshakeConstants.protocolVersion,
        supportedSuites: [CryptoSuite],
        keyShares: [HandshakeKeyShare],
        clientNonce: Data,
        policy: HandshakePolicy,
        capabilities: CryptoCapabilities,
        signature: Data,
        identityPublicKeys: IdentityPublicKeys,
        secureEnclaveSignature: Data? = nil
    ) {
        self.version = version
        self.supportedSuites = supportedSuites
        self.keyShares = keyShares
        self.clientNonce = clientNonce
        self.policy = policy
        self.capabilities = capabilities
        self.signature = signature
        self.identityPublicKey = identityPublicKeys.encoded
        self.secureEnclaveSignature = secureEnclaveSignature
    }
    
 // MARK: - Encoding
    
 /// 编码为二进制格式
    public var encoded: Data {
        var data = encodedWithoutSignature()
        
 // signature length (2B) + data
        HandshakeEncoding.appendUInt16LE(UInt16(signature.count), to: &data)
        data.append(signature)
        
 // secure enclave signature length (2B) + data (optional)
        let seSig = secureEnclaveSignature ?? Data()
        HandshakeEncoding.appendUInt16LE(UInt16(seSig.count), to: &data)
        data.append(seSig)
        
        return data
    }
    
 /// 从二进制格式解码
    public static func decode(from data: Data) throws -> HandshakeMessageA {
        guard data.count >= 5 else {
            throw HandshakeError.failed(.invalidMessageFormat("MessageA too short"))
        }
        
        var offset = 0
        
 // version
        let version = data[offset]
        offset += 1
        
        guard version == HandshakeConstants.protocolVersion else {
            throw HandshakeError.failed(.versionMismatch(
                local: HandshakeConstants.protocolVersion,
                remote: version
            ))
        }
        
 // supportedSuites
        let supportedCount = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard supportedCount > 0,
              supportedCount <= HandshakeConstants.maxSupportedSuites else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid supportedSuites count"))
        }
        
        var supportedSuites: [CryptoSuite] = []
        supportedSuites.reserveCapacity(Int(supportedCount))
        for _ in 0..<supportedCount {
            let suiteId = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
            supportedSuites.append(CryptoSuite(wireId: suiteId))
        }
        
 // keyShares
        let keyShareCount = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard keyShareCount <= HandshakeConstants.maxKeyShareCount,
              keyShareCount <= supportedCount else {
            throw HandshakeError.failed(.invalidMessageFormat("Too many keyShares"))
        }
        
        var keyShares: [HandshakeKeyShare] = []
        keyShares.reserveCapacity(Int(keyShareCount))
        var seenSuites = Set<UInt16>()
        for _ in 0..<keyShareCount {
            let suiteId = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
            let shareLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
            guard offset + Int(shareLen) <= data.count else {
                throw HandshakeError.failed(.invalidMessageFormat("KeyShare truncated"))
            }
            guard seenSuites.insert(suiteId).inserted else {
                throw HandshakeError.failed(.invalidMessageFormat("Duplicate keyShare suite"))
            }
            let shareBytes = data[offset..<(offset + Int(shareLen))]
            offset += Int(shareLen)
            
            let suite = CryptoSuite(wireId: suiteId)
            try HandshakeEncoding.validateKeyShareLength(shareBytes.count, for: suite)
            keyShares.append(HandshakeKeyShare(suite: suite, shareBytes: Data(shareBytes)))
        }
        
 // keyShares 顺序必须与 supportedSuites 保持一致（允许子序列）
        var lastIndex = -1
        for share in keyShares {
            guard let index = supportedSuites.firstIndex(where: { $0.wireId == share.suite.wireId }) else {
                throw HandshakeError.failed(.invalidMessageFormat("keyShare suite not in supportedSuites"))
            }
            guard index >= lastIndex else {
                throw HandshakeError.failed(.invalidMessageFormat("keyShares out of order"))
            }
            lastIndex = index
        }
        
 // clientNonce (32B)
        guard offset + 32 <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Missing nonce"))
        }
        let clientNonce = data[offset..<(offset + 32)]
        offset += 32
        
 // capabilities
        let capLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(capLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Capabilities truncated"))
        }
        let capabilitiesData = data[offset..<(offset + Int(capLen))]
        offset += Int(capLen)
        
 // 解码 capabilities（确定性编码）
        let capabilities = try decodeCapabilities(from: Data(capabilitiesData))
        
 // policy
        let policyLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(policyLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Policy truncated"))
        }
        let policyData = data[offset..<(offset + Int(policyLen))]
        offset += Int(policyLen)
        
        let policy: HandshakePolicy
        if policyData.isEmpty {
            policy = .default
        } else {
            policy = try decodePolicy(from: Data(policyData))
        }
        
 // identityPublicKey
        let idKeyLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(idKeyLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Identity key truncated"))
        }
        let identityPublicKey = data[offset..<(offset + Int(idKeyLen))]
        offset += Int(idKeyLen)
        
 // signature
        let sigLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(sigLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Signature truncated"))
        }
        let signature = data[offset..<(offset + Int(sigLen))]
        offset += Int(sigLen)
        
 // secure enclave signature (optional)
        var secureEnclaveSignature: Data?
        if offset < data.count {
            let seSigLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
            guard offset + Int(seSigLen) <= data.count else {
                throw HandshakeError.failed(.invalidMessageFormat("Secure Enclave signature truncated"))
            }
            let seSig = data[offset..<(offset + Int(seSigLen))]
            if !seSig.isEmpty {
                secureEnclaveSignature = Data(seSig)
            }
        }
        
        return HandshakeMessageA(
            version: version,
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: Data(clientNonce),
            policy: policy,
            capabilities: capabilities,
            signature: Data(signature),
            identityPublicKey: Data(identityPublicKey),
            secureEnclaveSignature: secureEnclaveSignature
        )
    }
    
 /// 获取待签名数据（包含域分离前缀）
    public var signaturePreimage: Data {
        var data = Data(HandshakeSignatureDomain.protocolA.utf8)
        data.append(encodedWithoutSignature())
        return data
    }
    
    var secureEnclaveSignaturePreimage: Data {
        makeSecureEnclavePreimage(
            domain: HandshakeSignatureDomain.secureEnclaveA,
            signaturePreimage: signaturePreimage
        )
    }
    
 /// 生成 MessageA 的 transcript bytes（不含签名）
    public var transcriptBytes: Data {
        encodedWithoutSignature()
    }
    
    func encodedWithoutSignature() -> Data {
        var data = Data()
        data.append(version)
        data.append(HandshakeEncoding.encodeSuites(supportedSuites))
        data.append(HandshakeEncoding.encodeKeyShares(keyShares))
        data.append(clientNonce)
        let capabilitiesData = (try? capabilities.deterministicEncode()) ?? Data()
        HandshakeEncoding.appendUInt16LE(UInt16(capabilitiesData.count), to: &data)
        data.append(capabilitiesData)
        let policyData = policy.deterministicEncode()
        HandshakeEncoding.appendUInt16LE(UInt16(policyData.count), to: &data)
        data.append(policyData)
        HandshakeEncoding.appendUInt16LE(UInt16(identityPublicKey.count), to: &data)
        data.append(identityPublicKey)
        return data
    }
}

// MARK: - HandshakeMessageB

/// 握手消息 B（响应方 -> 发起方）
///
/// 格式：
/// ```
/// version(1B) || selectedSuiteWireId(2B LE) || responderShare(var) || serverNonce(32B) ||
/// encryptedPayload(var) || identityPublicKey(var) || signature(var) || seSignature(var)
/// ```
public struct HandshakeMessageB: Sendable {
 /// 协议版本
    public let version: UInt8
    
 /// 接受的加密套件
    public let selectedSuite: CryptoSuite
    
 /// 响应方 KeyShare
    public let responderShare: Data
    
 /// 服务端随机 nonce
    public let serverNonce: Data
    
 /// 加密的 payload（包含响应方能力等）
    public let encryptedPayload: HPKESealedBox
    
 /// 签名（覆盖上述所有字段）
    public let signature: Data
    
 /// 响应方身份公钥
 ///
 /// **Wire 格式**: 新版本编码为 `IdentityPublicKeys.encoded`，旧版本为原始公钥 Data
 /// 使用 `identityPublicKeys` 属性获取结构化数据
    public let identityPublicKey: Data
    
 /// Secure Enclave 签名（可选）
    public let secureEnclaveSignature: Data?
    
 /// 结构化身份公钥（ 6.3）
 ///
 /// 解析 `identityPublicKey` 字段为 `IdentityPublicKeys` 结构。
 /// 支持向后兼容：旧格式自动解析为 legacy P-256 ECDSA（严格验证 65 字节 + 0x04 前缀）。
 ///
 /// **安全加固**：移除了无条件 fallback，确保 decodeWithLegacyFallback 的收紧逻辑生效。
 /// 解码失败将抛出错误，调用方需将其映射为可控失败而非崩溃。
    public func decodedIdentityPublicKeys() throws -> IdentityPublicKeys {
        try IdentityPublicKeys.decodeWithLegacyFallback(from: identityPublicKey)
    }

    @available(*, deprecated, message: "Use decodedIdentityPublicKeys() and handle errors explicitly.")
    public var identityPublicKeys: IdentityPublicKeys? {
        try? decodedIdentityPublicKeys()
    }
    
    public init(
        version: UInt8 = HandshakeConstants.protocolVersion,
        selectedSuite: CryptoSuite,
        responderShare: Data,
        serverNonce: Data,
        encryptedPayload: HPKESealedBox,
        signature: Data,
        identityPublicKey: Data,
        secureEnclaveSignature: Data? = nil
    ) {
        self.version = version
        self.selectedSuite = selectedSuite
        self.responderShare = responderShare
        self.serverNonce = serverNonce
        self.encryptedPayload = encryptedPayload
        self.signature = signature
        self.identityPublicKey = identityPublicKey
        self.secureEnclaveSignature = secureEnclaveSignature
    }
    
 /// 使用结构化身份公钥初始化（ 6.3）
 ///
 /// 新版本应使用此初始化器，自动编码为新格式。
    public init(
        version: UInt8 = HandshakeConstants.protocolVersion,
        selectedSuite: CryptoSuite,
        responderShare: Data,
        serverNonce: Data,
        encryptedPayload: HPKESealedBox,
        signature: Data,
        identityPublicKeys: IdentityPublicKeys,
        secureEnclaveSignature: Data? = nil
    ) {
        self.version = version
        self.selectedSuite = selectedSuite
        self.responderShare = responderShare
        self.serverNonce = serverNonce
        self.encryptedPayload = encryptedPayload
        self.signature = signature
        self.identityPublicKey = identityPublicKeys.encoded
        self.secureEnclaveSignature = secureEnclaveSignature
    }
    
 // MARK: - Encoding
    
 /// 编码为二进制格式
    public var encoded: Data {
        var data = encodedWithoutSignature()
        
 // signature length (2B) + data
        HandshakeEncoding.appendUInt16LE(UInt16(signature.count), to: &data)
        data.append(signature)
        
 // secure enclave signature length (2B) + data (optional)
        let seSig = secureEnclaveSignature ?? Data()
        HandshakeEncoding.appendUInt16LE(UInt16(seSig.count), to: &data)
        data.append(seSig)
        
        return data
    }
    
 /// 从二进制格式解码
    public static func decode(from data: Data) throws -> HandshakeMessageB {
        guard data.count >= 5 else {
            throw HandshakeError.failed(.invalidMessageFormat("MessageB too short"))
        }
        
        var offset = 0
        
 // version
        let version = data[offset]
        offset += 1
        
        guard version == HandshakeConstants.protocolVersion else {
            throw HandshakeError.failed(.versionMismatch(
                local: HandshakeConstants.protocolVersion,
                remote: version
            ))
        }
        
 // selectedSuiteWireId
        let suiteWireId = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        let selectedSuite = CryptoSuite(wireId: suiteWireId)
        
 // responderShare
        let shareLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(shareLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Responder share truncated"))
        }
        let responderShare = data[offset..<(offset + Int(shareLen))]
        offset += Int(shareLen)
        try HandshakeEncoding.validateResponderShareLength(responderShare.count, for: selectedSuite)
        
 // serverNonce (32B)
        guard offset + 32 <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Missing nonce"))
        }
        let serverNonce = data[offset..<(offset + 32)]
        offset += 32
        
 // encryptedPayload
        let payloadLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(payloadLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Payload truncated"))
        }
        let payloadData = data[offset..<(offset + Int(payloadLen))]
        offset += Int(payloadLen)
        
 // 解析 HPKESealedBox（握手阶段）
        let encryptedPayload = try HPKESealedBox(combined: Data(payloadData), isHandshake: true)
        
 // identityPublicKey
        let idKeyLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(idKeyLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Identity key truncated"))
        }
        let identityPublicKey = data[offset..<(offset + Int(idKeyLen))]
        offset += Int(idKeyLen)
        
 // signature
        let sigLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
        guard offset + Int(sigLen) <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Signature truncated"))
        }
        let signature = data[offset..<(offset + Int(sigLen))]
        offset += Int(sigLen)
        
 // secure enclave signature (optional)
        var secureEnclaveSignature: Data?
        if offset < data.count {
            let seSigLen = try HandshakeEncoding.readUInt16LE(from: data, offset: &offset)
            guard offset + Int(seSigLen) <= data.count else {
                throw HandshakeError.failed(.invalidMessageFormat("Secure Enclave signature truncated"))
            }
            let seSig = data[offset..<(offset + Int(seSigLen))]
            if !seSig.isEmpty {
                secureEnclaveSignature = Data(seSig)
            }
        }
        
        return HandshakeMessageB(
            version: version,
            selectedSuite: selectedSuite,
            responderShare: Data(responderShare),
            serverNonce: Data(serverNonce),
            encryptedPayload: encryptedPayload,
            signature: Data(signature),
            identityPublicKey: Data(identityPublicKey),
            secureEnclaveSignature: secureEnclaveSignature
        )
    }
    
 /// 构建 MessageB 的签名 preimage（包含 transcriptA）
    public func signaturePreimage(transcriptHashA: Data) -> Data {
        var data = Data(HandshakeSignatureDomain.protocolB.utf8)
        data.append(transcriptHashA)
        HandshakeEncoding.appendUInt16LE(selectedSuite.wireId, to: &data)
        HandshakeEncoding.appendUInt16LE(UInt16(responderShare.count), to: &data)
        data.append(responderShare)
        data.append(serverNonce)
        let payloadData = encryptedPayload.combinedWithHeader(suite: selectedSuite)
        let payloadHash = SHA256.hash(data: payloadData)
        data.append(contentsOf: payloadHash)
        HandshakeEncoding.appendUInt16LE(UInt16(identityPublicKey.count), to: &data)
        data.append(identityPublicKey)
        return data
    }
    
    func secureEnclaveSignaturePreimage(transcriptHashA: Data) -> Data {
        makeSecureEnclavePreimage(
            domain: HandshakeSignatureDomain.secureEnclaveB,
            signaturePreimage: signaturePreimage(transcriptHashA: transcriptHashA)
        )
    }
    
 /// 生成 MessageB 的 transcript bytes（不含签名）
    public var transcriptBytes: Data {
        encodedWithoutSignature()
    }
    
    func encodedWithoutSignature() -> Data {
        var data = Data()
        data.append(version)
        HandshakeEncoding.appendUInt16LE(selectedSuite.wireId, to: &data)
        HandshakeEncoding.appendUInt16LE(UInt16(responderShare.count), to: &data)
        data.append(responderShare)
        data.append(serverNonce)
        let payloadData = encryptedPayload.combinedWithHeader(suite: selectedSuite)
        HandshakeEncoding.appendUInt16LE(UInt16(payloadData.count), to: &data)
        data.append(payloadData)
        HandshakeEncoding.appendUInt16LE(UInt16(identityPublicKey.count), to: &data)
        data.append(identityPublicKey)
        return data
    }
}

public struct HandshakeFinished: Sendable {
    public enum Direction: UInt8, Sendable {
        case responderToInitiator = 0x01
        case initiatorToResponder = 0x02
    }
    
    public let version: UInt8
    public let direction: Direction
    public let mac: Data
    
    private static let magic: [UInt8] = [0x46, 0x49, 0x4E, 0x31] // "FIN1"
    private static let expectedMacLength = 32
    private static let encodedLength = 4 + 1 + 1 + expectedMacLength
    
    public init(
        version: UInt8 = HandshakeConstants.protocolVersion,
        direction: Direction,
        mac: Data
    ) {
        self.version = version
        self.direction = direction
        self.mac = mac
    }
    
    public var encoded: Data {
        var data = Data()
        data.append(contentsOf: Self.magic)
        data.append(version)
        data.append(direction.rawValue)
        data.append(mac)
        return data
    }
    
    public static func decode(from data: Data) throws -> HandshakeFinished {
        guard data.count == Self.encodedLength else {
            throw HandshakeError.failed(.invalidMessageFormat("Finished length mismatch"))
        }
        guard data.prefix(4).elementsEqual(Self.magic) else {
            throw HandshakeError.failed(.invalidMessageFormat("Finished magic mismatch"))
        }
        let version = data[4]
        guard version == HandshakeConstants.protocolVersion else {
            throw HandshakeError.failed(.versionMismatch(local: HandshakeConstants.protocolVersion, remote: version))
        }
        guard let direction = Direction(rawValue: data[5]) else {
            throw HandshakeError.failed(.invalidMessageFormat("Finished direction invalid"))
        }
        let mac = data[6..<data.count]
        guard mac.count == Self.expectedMacLength else {
            throw HandshakeError.failed(.invalidMessageFormat("Finished MAC length invalid"))
        }
        return HandshakeFinished(version: version, direction: direction, mac: Data(mac))
    }
}

extension HandshakeMessageA: TranscriptEncodable {
    public func deterministicEncode() throws -> Data {
        transcriptBytes
    }
}

extension HandshakeMessageB: TranscriptEncodable {
    public func deterministicEncode() throws -> Data {
        transcriptBytes
    }
}

// MARK: - Helper Functions

/// 解码 CryptoCapabilities（确定性编码）
private func decodeCapabilities(from data: Data) throws -> CryptoCapabilities {
    do {
        var decoder = DeterministicDecoder(data: data)
        let supportedKEM = try decoder.decodeStringArray()
        let supportedSignature = try decoder.decodeStringArray()
        let supportedAuthProfiles = try decoder.decodeStringArray()
        let supportedAEAD = try decoder.decodeStringArray()
        let pqcAvailable = try decoder.decodeBool()
        let platformVersion = try decoder.decodeString()
        let providerTypeRaw = try decoder.decodeString()
        guard let providerType = CryptoProviderType(rawValue: providerTypeRaw) else {
            throw TranscriptError.decodingError("Unknown providerType: \(providerTypeRaw)")
        }
        guard decoder.isAtEnd else {
            throw TranscriptError.decodingError("Trailing bytes in CryptoCapabilities")
        }
        return CryptoCapabilities(
            supportedKEM: supportedKEM,
            supportedSignature: supportedSignature,
            supportedAuthProfiles: supportedAuthProfiles,
            supportedAEAD: supportedAEAD,
            pqcAvailable: pqcAvailable,
            platformVersion: platformVersion,
            providerType: providerType
        )
    } catch {
        throw HandshakeError.failed(.invalidMessageFormat("Capabilities decode failed: \(error.localizedDescription)"))
    }
}

/// 解码 HandshakePolicy（确定性编码）
private func decodePolicy(from data: Data) throws -> HandshakePolicy {
    do {
        var decoder = DeterministicDecoder(data: data)
        let requirePQC = try decoder.decodeBool()
        let allowClassicFallback = try decoder.decodeBool()
        let minimumTierRaw = try decoder.decodeString()
        guard let minimumTier = CryptoTier(rawValue: minimumTierRaw) else {
            throw TranscriptError.decodingError("Unknown CryptoTier: \(minimumTierRaw)")
        }
        let requireSecureEnclavePoP: Bool
        if decoder.isAtEnd {
            requireSecureEnclavePoP = false
        } else {
            requireSecureEnclavePoP = try decoder.decodeBool()
        }
        guard decoder.isAtEnd else {
            throw TranscriptError.decodingError("Trailing bytes in HandshakePolicy")
        }
        return HandshakePolicy(
            requirePQC: requirePQC,
            allowClassicFallback: allowClassicFallback,
            minimumTier: minimumTier,
            requireSecureEnclavePoP: requireSecureEnclavePoP
        )
    } catch {
        throw HandshakeError.failed(.invalidMessageFormat("Policy decode failed: \(error.localizedDescription)"))
    }
}

private func makeSecureEnclavePreimage(domain: String, signaturePreimage: Data) -> Data {
    let hash = SHA256.hash(data: signaturePreimage)
    var data = Data(domain.utf8)
    data.append(contentsOf: hash)
    return data
}

private enum HandshakeEncoding {
    static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        let littleEndian = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: littleEndian) { Data($0) })
    }
    
    static func readUInt16LE(from data: Data, offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Unexpected end of data"))
        }
        let value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        return value
    }
    
    static func encodeSuites(_ suites: [CryptoSuite]) -> Data {
        var data = Data()
        appendUInt16LE(UInt16(suites.count), to: &data)
        for suite in suites {
            appendUInt16LE(suite.wireId, to: &data)
        }
        return data
    }
    
    static func encodeKeyShares(_ keyShares: [HandshakeKeyShare]) -> Data {
        var data = Data()
        appendUInt16LE(UInt16(keyShares.count), to: &data)
        for share in keyShares {
            appendUInt16LE(share.suite.wireId, to: &data)
            appendUInt16LE(UInt16(share.shareBytes.count), to: &data)
            data.append(share.shareBytes)
        }
        return data
    }
    
    static func validateKeyShareLength(_ length: Int, for suite: CryptoSuite) throws {
        guard let expected = expectedKeyShareLength(for: suite) else {
            return
        }
        guard expected == length else {
            throw HandshakeError.failed(.invalidMessageFormat("KeyShare length mismatch"))
        }
    }

    static func validateResponderShareLength(_ length: Int, for suite: CryptoSuite) throws {
        guard let expected = expectedResponderShareLength(for: suite) else {
            return
        }
        guard expected == length else {
            throw HandshakeError.failed(.invalidMessageFormat("ResponderShare length mismatch"))
        }
    }
    
    static func expectedKeyShareLength(for suite: CryptoSuite) -> Int? {
        switch suite.wireId {
        case 0x0001: return 1120   // X-Wing ciphertext: X25519(32) + ML-KEM-768(1088)
        case 0x0101: return 1088   // ML-KEM-768
        case 0x1001: return 32     // X25519
        case 0x1002: return 65     // P-256
        default: return nil
        }
    }

    static func expectedResponderShareLength(for suite: CryptoSuite) -> Int? {
        if suite.isPQC {
            return 0
        }
        return expectedKeyShareLength(for: suite)
    }
}
