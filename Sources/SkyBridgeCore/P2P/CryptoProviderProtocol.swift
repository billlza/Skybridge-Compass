//
// CryptoProviderProtocol.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - PQC Provider Architecture Refactoring
// Requirements: 1.1, 1.5, 13.1, 13.2, 13.3
//
// 统一的加密 Provider 协议和类型定义：
// - CryptoProvider 协议：调用方只使用此协议，不关心具体实现
// - CryptoSuite：算法套件（使用 struct 支持前向兼容）
// - CryptoTier：Provider 层级
// - KeyUsage：密钥用途
// - KeyPair/KeyMaterial：类型化密钥材料
// - HPKESealedBox：HPKE 密封盒（含 DoS 防护）
// - CryptoProviderError：错误类型
//

import Foundation

// MARK: - CryptoProvider Protocol

/// 统一的加密 Provider 协议
/// 调用方只使用此协议，不关心具体实现
public protocol CryptoProvider: Sendable {
 /// Provider 标识（用于日志和事件）
    var providerName: String { get }
    
 /// Provider 层级（用于事件，避免字符串判断）
    var tier: CryptoTier { get }
    
 /// 当前使用的算法套件
    var activeSuite: CryptoSuite { get }
    
 /// 支持的所有算法套件（用于 HandshakeOfferedSuites.build）
 ///
 /// ** 7.2**: 数据来源必须是 provider 实际支持的 suites
 /// 不使用静态的 CryptoSuite.allPQCSuites（会 offer 本地不支持的 suite）
    var supportedSuites: [CryptoSuite] { get }

 /// 是否支持指定算法套件
    func supportsSuite(_ suite: CryptoSuite) -> Bool
    
 /// HPKE 封装（KEM）
    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox

 /// KEM-DEM 封装（论文协议的接口）
    func kemDemSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox

 /// KEM-DEM 封装（导出共享密钥）
    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes)
    
 /// HPKE 解封装
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data
    
 /// HPKE 解封装（SecureBytes 版本，避免 Data 复制）
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data

 /// KEM-DEM 解封装（论文协议的接口）
    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data

 /// KEM-DEM 解封装（导出共享密钥）
    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes)
    
 /// KEM 封装（仅导出共享密钥与封装结果）
    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes)
    
 /// KEM 解封装（仅导出共享密钥）
    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes
    
 /// 数字签名
    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data
    
 /// 签名验证
    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool
    
 /// 生成密钥对
    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair
}

// MARK: - SecureBytes Default Implementations

public extension CryptoProvider {
 /// 默认实现：supportedSuites 返回仅包含 activeSuite
    var supportedSuites: [CryptoSuite] {
        [activeSuite]
    }
    
 /// 默认实现：仅支持当前 activeSuite
    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        suite.wireId == activeSuite.wireId
    }

 /// 默认实现：KEM-DEM 使用现有 HPKE 兼容封装
    func kemDemSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info)
    }

 /// 默认实现：KEM-DEM 使用现有 HPKE 兼容解封装
    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        try await hpkeOpen(sealedBox: sealedBox, privateKey: privateKey, info: info)
    }

 /// 默认实现：不支持共享密钥导出时抛错
    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.notImplemented("Shared secret export not supported")
    }

 /// 默认实现：不支持共享密钥导出时抛错
    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.notImplemented("Shared secret export not supported")
    }

 /// 默认实现：不支持 KEM 封装时抛错
    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.notImplemented("KEM encapsulation not supported")
    }

 /// 默认实现：不支持 KEM 解封装时抛错
    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        throw CryptoProviderError.notImplemented("KEM decapsulation not supported")
    }

 /// 默认实现：将 Data 包装成 SecureBytes 后调用 SecureBytes 版本
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        let secureKey = SecureBytes(data: privateKey)
        return try await hpkeOpen(sealedBox: sealedBox, privateKey: secureKey, info: info)
    }

 /// 默认实现：将 Data 包装成 SecureBytes 后调用 KEM-DEM 版本
    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        let secureKey = SecureBytes(data: privateKey)
        return try await kemDemOpen(sealedBox: sealedBox, privateKey: secureKey, info: info)
    }
}

// MARK: - CryptoSuite

/// 算法套件（使用 struct 支持前向兼容）
///
/// **设计决策**：
/// - 使用 struct + RawRepresentable 而非 enum
/// - 解析未知 wireId 时不崩，返回 .unknown(wireId)
/// - 这样未来新增套件时旧版本可以安全 reject
///
/// **wireId 分段编码**：
/// - 0x00xx: 混合 PQC（原生/首选）
/// - 0x01xx: 纯 PQC
/// - 0x10xx: 经典算法
/// - 0xF0xx: 实验/临时（不承诺兼容）
public struct CryptoSuite: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public let wireId: UInt16
    
    public init(rawValue: String, wireId: UInt16) {
        self.rawValue = rawValue
        self.wireId = wireId
    }
    
    public init?(rawValue: String) {
        switch rawValue {
        case Self.xwingMLDSA.rawValue, "X-Wing+ML-DSA-65": self = .xwingMLDSA
        case Self.mlkem768MLDSA65.rawValue, "ML-KEM-768+ML-DSA-65": self = .mlkem768MLDSA65
        case Self.x25519Ed25519.rawValue, "X25519+Ed25519": self = .x25519Ed25519
        case Self.p256ECDSA.rawValue, "P-256+ECDSA": self = .p256ECDSA
        default: return nil
        }
    }
    
 // MARK: - Known Suites
    
    public static let xwingMLDSA = CryptoSuite(rawValue: "X-Wing", wireId: 0x0001)
    
    public static let mlkem768MLDSA65 = CryptoSuite(rawValue: "ML-KEM-768", wireId: 0x0101)
    
    public static let x25519Ed25519 = CryptoSuite(rawValue: "X25519", wireId: 0x1001)
    
    public static let p256ECDSA = CryptoSuite(rawValue: "P-256", wireId: 0x1002)
    
 /// 未知套件（用于前向兼容）
    public static func unknown(_ wireId: UInt16) -> CryptoSuite {
        CryptoSuite(rawValue: "unknown-\(wireId)", wireId: wireId)
    }
    
 /// 从线上 ID 解析（未知 ID 返回 .unknown 而非 nil）
    public init(wireId: UInt16) {
        switch wireId {
        case 0x0001: self = .xwingMLDSA
        case 0x0101: self = .mlkem768MLDSA65
        case 0x1001: self = .x25519Ed25519
        case 0x1002: self = .p256ECDSA
        default: self = .unknown(wireId)
        }
    }
    
 /// wireId 分段判断（用于日志/调试）
    public var tierFromWireId: String {
        switch wireId >> 8 {
        case 0x00: return "hybridPQC"
        case 0x01: return "purePQC"
        case 0x10: return "classic"
        case 0xF0: return "experimental"
        default: return "unknown"
        }
    }
    
 /// 是否为已知套件
    public var isKnown: Bool {
        !rawValue.hasPrefix("unknown-")
    }
    
 /// 是否为 PQC 套件
    public var isPQC: Bool {
        let tier = wireId >> 8
        return tier == 0x00 || tier == 0x01
    }
    
    public var isHybrid: Bool {
        (wireId >> 8) == 0x00
    }
    
 /// 是否属于 PQC 组（用于同质性验证）
 ///
 /// **唯一分类函数**: 按 KEM 判定
 /// - mlkem/xwing → true (PQC 组)
 /// - x25519 → false (Classic 组)
 ///
 /// **Requirements: 4.1, 4.2, 4.3, 4.4, 4.5**
    public var isPQCGroup: Bool {
 // 按 KEM 判定：wireId 高字节 0x00 (hybrid) 或 0x01 (pure PQC) 为 PQC 组
        let tier = wireId >> 8
        return tier == 0x00 || tier == 0x01
    }
}

// MARK: - CryptoTier

/// Provider 层级（用于事件，避免字符串判断）
public enum CryptoTier: String, Sendable, Codable {
 /// 原生 PQC (iOS 26+/macOS 26+)
    case nativePQC = "nativePQC"
    
 /// liboqs PQC
    case liboqsPQC = "liboqsPQC"
    
 /// 经典算法
    case classic = "classic"
}

// MARK: - KeyUsage

/// 密钥用途
public enum KeyUsage: String, Sendable {
 /// 密钥交换 (KEM)
    case keyExchange = "keyExchange"
    
 /// 签名
    case signing = "signing"
}

// MARK: - KeyPair

/// 密钥对（类型化，防止喂错）
///
/// **设计决策**：
/// - 带上 suite + usage，provider 入口先校验
/// - 防止"把 X25519 私钥当成 P-256 私钥传进去"的乌龙
public struct KeyPair: Sendable {
    public let publicKey: KeyMaterial
    public let privateKey: KeyMaterial
    
    public init(publicKey: KeyMaterial, privateKey: KeyMaterial) {
        precondition(publicKey.suite == privateKey.suite, "Suite mismatch")
        precondition(publicKey.usage == privateKey.usage, "Usage mismatch")
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

// MARK: - KeyMaterial

/// 密钥材料（类型化）
public struct KeyMaterial: Sendable {
    public let suite: CryptoSuite
    public let usage: KeyUsage
    public let bytes: Data
    public let formatVersion: UInt8
    
    public init(suite: CryptoSuite, usage: KeyUsage, bytes: Data, formatVersion: UInt8 = 1) {
        self.suite = suite
        self.usage = usage
        self.bytes = bytes
        self.formatVersion = formatVersion
    }
    
 /// 验证密钥长度是否符合套件要求
    public func validate(isPublic: Bool = true) throws {
        let expectedLength = Self.expectedLength(suite: suite, usage: usage, isPublic: isPublic)
        guard expectedLength > 0 else {
 // 未知套件，跳过长度检查
            return
        }
        guard bytes.count == expectedLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedLength,
                actual: bytes.count,
                suite: suite.rawValue,
                usage: usage
            )
        }
    }
    
 /// 获取预期密钥长度
    private static func expectedLength(suite: CryptoSuite, usage: KeyUsage, isPublic: Bool) -> Int {
        switch (suite.wireId, usage, isPublic) {
 // X25519 + Ed25519
        case (0x1001, .keyExchange, _): return 32
        case (0x1001, .signing, true): return 32
        case (0x1001, .signing, false): return 64
        
 // P-256 + ECDSA
        case (0x1002, .keyExchange, true): return 65  // uncompressed point
        case (0x1002, .keyExchange, false): return 32
        case (0x1002, .signing, true): return 65
        case (0x1002, .signing, false): return 32
        
 // ML-KEM-768 + ML-DSA-65 (Apple CryptoKit uses seed-based compact private keys)
        case (0x0101, .keyExchange, true): return 1184   // ML-KEM-768 公钥
        case (0x0101, .keyExchange, false): return 96    // ML-KEM-768 私钥 (Apple seed format)
        case (0x0101, .signing, true): return 1952       // ML-DSA-65 公钥
        case (0x0101, .signing, false): return 64        // ML-DSA-65 私钥 (Apple seed format)
        
 // X-Wing + ML-DSA-65 (混合)
        case (0x0001, .keyExchange, true): return 1216   // X25519(32) + ML-KEM-768(1184)
        case (0x0001, .keyExchange, false): return 2432  // X25519(32) + ML-KEM-768(2400)
        case (0x0001, .signing, true): return 1952       // ML-DSA-65 公钥
        case (0x0001, .signing, false): return 4032      // ML-DSA-65 私钥
        
        default: return 0  // 未知套件，跳过长度检查
        }
    }
}

// MARK: - HPKESealedBox

/// HPKE 密封盒
/// 注意：在不同版本下字段含义不同
///
/// **Header 格式（固化规范）**:
/// ```
/// magic(4B: "HPKE") || version(1B) || suiteWireId(2B little-endian) || flags(2B) ||
/// encLen(2B little-endian) || nonceLen(1B) || tagLen(1B) || ctLen(4B little-endian) ||
/// enc || nonce || ct || tag
/// ```
///
/// **版本语义**:
/// - v1: KEM-DEM 兼容封装（AES-GCM），nonce/tag 固定存在
/// - v2: 原生 HPKE 密文封装，允许 nonceLen/tagLen 为 0（nonce/tag 为空）
///
/// **长度上限（防 DoS）**:
/// - encLen <= 4096 (足够 ML-KEM-768 的 1088 字节)
/// - v1: nonceLen == 12 (AES-GCM 固定)
/// - v1: tagLen == 16 (AES-GCM 固定)
/// - v2: nonceLen/tagLen 允许为 0（由 HPKE 密文格式决定）
/// - ctLen: 分两档
/// - 握手阶段（未鉴权）: <= 64KB
/// - 鉴权后: <= 256KB
public struct HPKESealedBox: Sendable {
    public let encapsulatedKey: Data  // KEM 封装的临时公钥
    public let nonce: Data            // v1(AES-GCM)=12 bytes；v2(HPKE)=可为空
    public let ciphertext: Data       // 加密后的数据
    public let tag: Data              // v1(AES-GCM)=16 bytes；v2(HPKE)=可为空
    
 // MARK: - Header Constants
    
    private static let magic: [UInt8] = [0x48, 0x50, 0x4B, 0x45]  // "HPKE"
    private static let headerSize = 17  // 4 + 1 + 2 + 2 + 2 + 1 + 1 + 4
    private static let maxEncLen = 4096
    private static let expectedNonceLen = 12
    private static let expectedTagLen = 16
    private static let maxCtLenHandshake = 64 * 1024      // 64KB (未鉴权)
    private static let maxCtLenPostAuth = 256 * 1024      // 256KB (鉴权后)
    
 // MARK: - Initialization
    
    public init(encapsulatedKey: Data, nonce: Data, ciphertext: Data, tag: Data) {
        self.encapsulatedKey = encapsulatedKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
    
 /// 从合并格式解析（带 header 的自描述格式）
 /// - Parameter combined: 合并的数据
 /// - Parameter isHandshake: true = 握手阶段（64KB 限制），false = 鉴权后（256KB 限制）
    public init(combined: Data, isHandshake: Bool = true) throws {
 // 1. 检查最小长度
        guard combined.count >= Self.headerSize else {
            throw CryptoProviderError.invalidSealedBox("Data too short for header")
        }
        
 // 2. 验证 magic
        guard combined.prefix(4).elementsEqual(Self.magic) else {
            throw CryptoProviderError.invalidMagic
        }
        
 // 3. 解析 header
        let version = combined[4]
        guard version == 1 || version == 2 else {
            throw CryptoProviderError.unsupportedVersion(version)
        }
        
 // suiteWireId 和 flags 预留，暂不使用（little-endian）
 // let suiteWireId = UInt16(combined[5]) | (UInt16(combined[6]) << 8)
 // let flags = UInt16(combined[7]) | (UInt16(combined[8]) << 8)
        
        let encLen = Int(combined[9]) | (Int(combined[10]) << 8)
        let nonceLen = Int(combined[11])
        let tagLen = Int(combined[12])
        let ctLen = Int(combined[13]) | (Int(combined[14]) << 8) |
                    (Int(combined[15]) << 16) | (Int(combined[16]) << 24)
        
 // 4. 验证长度上限（防 DoS）- 先检查每段
        guard encLen <= Self.maxEncLen else {
            throw CryptoProviderError.lengthExceeded("encLen", encLen, Self.maxEncLen)
        }
        if version == 1 {
            guard nonceLen == Self.expectedNonceLen else {
                throw CryptoProviderError.invalidNonceLength(nonceLen)
            }
            guard tagLen == Self.expectedTagLen else {
                throw CryptoProviderError.invalidTagLength(tagLen)
            }
        } else {
            guard nonceLen == 0 || nonceLen == Self.expectedNonceLen else {
                throw CryptoProviderError.invalidNonceLength(nonceLen)
            }
            guard tagLen == 0 || tagLen == Self.expectedTagLen else {
                throw CryptoProviderError.invalidTagLength(tagLen)
            }
        }
        
 // 根据阶段选择 ctLen 上限
        let maxCtLen = isHandshake ? Self.maxCtLenHandshake : Self.maxCtLenPostAuth
        guard ctLen <= maxCtLen else {
            throw CryptoProviderError.lengthExceeded("ctLen", ctLen, maxCtLen)
        }
        
 // 5. 验证总长度（overflow-safe 加法）
        var expectedTotal = Self.headerSize
        let (sum1, overflow1) = expectedTotal.addingReportingOverflow(encLen)
        let (sum2, overflow2) = sum1.addingReportingOverflow(nonceLen)
        let (sum3, overflow3) = sum2.addingReportingOverflow(ctLen)
        let (sum4, overflow4) = sum3.addingReportingOverflow(tagLen)
        
        guard !overflow1 && !overflow2 && !overflow3 && !overflow4 else {
            throw CryptoProviderError.lengthOverflow
        }
        expectedTotal = sum4
        
        guard combined.count == expectedTotal else {
            throw CryptoProviderError.lengthMismatch(expected: expectedTotal, actual: combined.count)
        }
        
 // 6. 切片（长度已验证，安全）
        var offset = Self.headerSize
        self.encapsulatedKey = combined[offset..<(offset + encLen)]
        offset += encLen
        self.nonce = combined[offset..<(offset + nonceLen)]
        offset += nonceLen
        self.ciphertext = combined[offset..<(offset + ctLen)]
        offset += ctLen
        self.tag = combined[offset..<(offset + tagLen)]
    }
    
 // MARK: - Serialization
    
 /// 合并格式（用于传输，无 header）: encapsulatedKey || nonce || ciphertext || tag
    public var combined: Data {
        var out = Data()
        out.append(encapsulatedKey)
        out.append(nonce)
        out.append(ciphertext)
        out.append(tag)
        return out
    }
    
 /// 生成带 header 的合并格式
    public func combinedWithHeader(suite: CryptoSuite) -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)
        let version: UInt8
        if nonce.count == Self.expectedNonceLen && tag.count == Self.expectedTagLen {
            version = 1
        } else {
            version = 2
        }
        out.append(version)
        out.append(UInt8(suite.wireId & 0xFF))
        out.append(UInt8(suite.wireId >> 8))
        out.append(contentsOf: [0, 0])  // flags 预留
        out.append(UInt8(encapsulatedKey.count & 0xFF))
        out.append(UInt8(encapsulatedKey.count >> 8))
        out.append(UInt8(nonce.count & 0xFF))  // nonceLen
        out.append(UInt8(tag.count & 0xFF))    // tagLen
        out.append(UInt8(ciphertext.count & 0xFF))
        out.append(UInt8((ciphertext.count >> 8) & 0xFF))
        out.append(UInt8((ciphertext.count >> 16) & 0xFF))
        out.append(UInt8((ciphertext.count >> 24) & 0xFF))
        out.append(encapsulatedKey)
        out.append(nonce)
        out.append(ciphertext)
        out.append(tag)
        return out
    }
}

// MARK: - CryptoProviderError Extension
// Note: CryptoProviderError is defined in CryptoProviderSelector.swift
// This extension adds new cases for HPKESealedBox and KeyMaterial validation

extension CryptoProviderError {
 // Additional error descriptions are handled in CryptoProviderSelector.swift
}
