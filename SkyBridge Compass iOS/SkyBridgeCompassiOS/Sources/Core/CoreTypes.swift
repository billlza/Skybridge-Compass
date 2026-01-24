//
// CoreTypes.swift
// SkyBridgeCompassiOS
//
// 核心类型定义 - 所有其他模块依赖的基础类型
// 确保此文件在编译顺序中优先
//

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - CryptoTier

/// 加密提供者层级
public enum CryptoTier: String, Sendable, Codable, Equatable {
    /// Apple 原生 PQC（macOS 26+/iOS 26+）
    case nativePQC = "nativePQC"
    
    /// liboqs PQC（较早系统版本）
    case liboqsPQC = "liboqsPQC"
    
    /// 经典加密（X25519 + Ed25519）
    case classic = "classic"
}

// MARK: - CryptoSuite

/// 加密套件（与 macOS Wire 格式完全一致）
public enum CryptoSuite: String, Sendable, Codable, Equatable, Hashable {
    /// ML-KEM-768 + ML-DSA-65（纯 PQC）
    case mlkem768 = "ML-KEM-768"
    
    /// X-Wing: X25519 + ML-KEM-768（混合）
    case xwing = "X-Wing"
    
    /// X25519 + Ed25519（经典）
    case x25519Ed25519 = "X25519-Ed25519"
    
    /// X25519（经典 KEM）
    case x25519 = "X25519"
    
    /// P-256（经典，兼容）
    case p256 = "P-256"
    
    /// Wire ID（用于协议编码）
    public var wireId: UInt16 {
        switch self {
        case .xwing: return 0x0001      // Hybrid: X-Wing
        case .mlkem768: return 0x0101   // PQC: ML-KEM-768
        case .x25519Ed25519: return 0x1001  // Classic: X25519+Ed25519
        case .x25519: return 0x1001     // Classic: X25519
        case .p256: return 0x1002       // Classic: P-256
        }
    }
    
    /// 从 Wire ID 创建
    public init(wireId: UInt16) {
        switch wireId {
        case 0x0001: self = .xwing
        case 0x0101: self = .mlkem768
        case 0x1001: self = .x25519Ed25519
        case 0x1002: self = .p256
        default: self = .x25519Ed25519  // 默认回退
        }
    }
    
    /// 是否是 PQC 套件
    public var isPQC: Bool {
        switch self {
        case .mlkem768: return true
        case .xwing: return true
        default: return false
        }
    }
    
    /// 是否是混合套件
    public var isHybrid: Bool {
        self == .xwing
    }
    
    /// 是否属于 PQC 组（用于签名算法选择）
    public var isPQCGroup: Bool {
        isPQC || isHybrid
    }
    
    /// 所有 PQC 套件
    public static var allPQCSuites: [CryptoSuite] {
        [.mlkem768, .xwing]
    }
    
    /// 所有 Classic 套件
    public static var allClassicSuites: [CryptoSuite] {
        [.x25519, .x25519Ed25519, .p256]
    }
}

// MARK: - macOS naming aliases (compat)

public extension CryptoSuite {
    /// macOS Core naming: X-Wing + ML-DSA-65 (v1 uses suite group for signature selection)
    static let xwingMLDSA: CryptoSuite = .xwing
    /// macOS Core naming: ML-KEM-768 + ML-DSA-65
    static let mlkem768MLDSA65: CryptoSuite = .mlkem768
    /// macOS Core naming: P-256 + ECDSA (legacy)
    static let p256ECDSA: CryptoSuite = .p256
}

// MARK: - KeyUsage

/// 密钥用途
public enum KeyUsage: String, Sendable {
    /// 密钥交换（KEM）
    case keyExchange = "keyExchange"
    
    /// 数字签名
    case signing = "signing"
    
    /// 临时密钥（握手用）
    case ephemeral = "ephemeral"
}

// MARK: - KeyPair

/// 密钥对
public struct KeyPair: Sendable {
    public let publicKey: KeyMaterial
    public let privateKey: KeyMaterial
    
    public init(publicKey: KeyMaterial, privateKey: KeyMaterial) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
    
    public init(publicKey: Data, privateKey: Data) {
        self.publicKey = KeyMaterial(data: publicKey)
        self.privateKey = KeyMaterial(data: privateKey)
    }
}

// MARK: - KeyMaterial

/// 密钥材料（可以是 Data 或 SecureBytes）
public struct KeyMaterial: Sendable {
    private let storage: Storage
    
    private enum Storage: Sendable {
        case data(Data)
        case secure(SecureBytes)
    }
    
    public init(data: Data) {
        self.storage = .data(data)
    }
    
    public init(secure: SecureBytes) {
        self.storage = .secure(secure)
    }
    
    /// 获取字节（会复制）
    public var bytes: Data {
        switch storage {
        case .data(let data): return data
        case .secure(let secure): return secure.data
        }
    }
}

// MARK: - HPKESealedBox

/// HPKE 密封盒（与 macOS SkyBridgeCore Wire 格式对齐）
///
/// **Header 格式（固化规范）**:
/// ```
/// magic(4B: "HPKE") || version(1B) || suiteWireId(2B little-endian) || flags(2B) ||
/// encLen(2B little-endian) || nonceLen(1B) || tagLen(1B) || ctLen(4B little-endian) ||
/// enc || nonce || ct || tag
/// ```
///
/// **版本语义**:
/// - v1: KEM-DEM 兼容封装（AES-GCM），nonce/tag 固定存在（12/16）
/// - v2: 原生 HPKE 密文封装，允许 nonceLen/tagLen 为 0（nonce/tag 为空）
public struct HPKESealedBox: Sendable {
    public let encapsulatedKey: Data
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data
    
    private static let magic: [UInt8] = [0x48, 0x50, 0x4B, 0x45] // "HPKE"
    private static let headerSize = 17
    private static let maxEncLen = 4096
    private static let expectedNonceLen = 12
    private static let expectedTagLen = 16
    private static let maxCtLenHandshake = 64 * 1024
    private static let maxCtLenPostAuth = 256 * 1024
    
    public init(encapsulatedKey: Data, ciphertext: Data, tag: Data, nonce: Data) {
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
        self.tag = tag
        self.nonce = nonce
    }
    
    /// 从带 header 的合并格式解析
    /// - Parameter isHandshake: true = 握手阶段（64KB 限制），false = 鉴权后（256KB 限制）
    public init(combined: Data, isHandshake: Bool = true) throws {
        guard combined.count >= Self.headerSize else {
            throw HPKESealedBoxParseError.invalidSealedBox("Data too short for header")
        }
        guard combined.prefix(4).elementsEqual(Self.magic) else {
            throw HPKESealedBoxParseError.invalidMagic
        }
        
        let version = combined[4]
        guard version == 1 || version == 2 else {
            throw HPKESealedBoxParseError.unsupportedVersion(Int(version))
        }
        
        // suiteWireId/flags reserved in v1; parsed by caller from outer message if needed.
        let encLen = Int(combined[9]) | (Int(combined[10]) << 8)
        let nonceLen = Int(combined[11])
        let tagLen = Int(combined[12])
        let ctLen = Int(combined[13]) | (Int(combined[14]) << 8) | (Int(combined[15]) << 16) | (Int(combined[16]) << 24)
        
        guard encLen <= Self.maxEncLen else {
            throw HPKESealedBoxParseError.lengthExceeded("encLen", encLen, Self.maxEncLen)
        }
        
        if version == 1 {
            guard nonceLen == Self.expectedNonceLen else { throw HPKESealedBoxParseError.invalidNonceLength(nonceLen) }
            guard tagLen == Self.expectedTagLen else { throw HPKESealedBoxParseError.invalidTagLength(tagLen) }
        } else {
            guard nonceLen == 0 || nonceLen == Self.expectedNonceLen else { throw HPKESealedBoxParseError.invalidNonceLength(nonceLen) }
            guard tagLen == 0 || tagLen == Self.expectedTagLen else { throw HPKESealedBoxParseError.invalidTagLength(tagLen) }
        }
        
        let maxCtLen = isHandshake ? Self.maxCtLenHandshake : Self.maxCtLenPostAuth
        guard ctLen <= maxCtLen else {
            throw HPKESealedBoxParseError.lengthExceeded("ctLen", ctLen, maxCtLen)
        }
        
        var expectedTotal = Self.headerSize
        let (sum1, o1) = expectedTotal.addingReportingOverflow(encLen)
        let (sum2, o2) = sum1.addingReportingOverflow(nonceLen)
        let (sum3, o3) = sum2.addingReportingOverflow(ctLen)
        let (sum4, o4) = sum3.addingReportingOverflow(tagLen)
        guard !o1 && !o2 && !o3 && !o4 else {
            throw HPKESealedBoxParseError.lengthOverflow
        }
        expectedTotal = sum4
        
        guard combined.count == expectedTotal else {
            throw HPKESealedBoxParseError.lengthMismatch(expected: expectedTotal, actual: combined.count)
        }
        
        var offset = Self.headerSize
        self.encapsulatedKey = combined[offset..<(offset + encLen)]
        offset += encLen
        self.nonce = combined[offset..<(offset + nonceLen)]
        offset += nonceLen
        self.ciphertext = combined[offset..<(offset + ctLen)]
        offset += ctLen
        self.tag = combined[offset..<(offset + tagLen)]
    }
    
    /// 无 header 的合并格式（用于内部拼接）: enc || nonce || ct || tag
    public var combined: Data {
        var out = Data()
        out.append(encapsulatedKey)
        out.append(nonce)
        out.append(ciphertext)
        out.append(tag)
        return out
    }
    
    /// 生成带 header 的合并格式（用于握手消息 payload 传输/签名）
    public func combinedWithHeader(suite: CryptoSuite) -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)
        
        let version: UInt8 = (nonce.count == Self.expectedNonceLen && tag.count == Self.expectedTagLen) ? 1 : 2
        out.append(version)
        
        // suiteWireId (little-endian) + flags (reserved)
        out.append(UInt8(suite.wireId & 0xFF))
        out.append(UInt8(suite.wireId >> 8))
        out.append(contentsOf: [0, 0])
        
        // lengths
        out.append(UInt8(encapsulatedKey.count & 0xFF))
        out.append(UInt8((encapsulatedKey.count >> 8) & 0xFF))
        out.append(UInt8(nonce.count & 0xFF))
        out.append(UInt8(tag.count & 0xFF))
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

public enum HPKESealedBoxParseError: Error, Sendable {
    case invalidSealedBox(String)
    case invalidMagic
    case unsupportedVersion(Int)
    case invalidNonceLength(Int)
    case invalidTagLength(Int)
    case lengthExceeded(String, Int, Int)
    case lengthOverflow
    case lengthMismatch(expected: Int, actual: Int)
}

// MARK: - SigningCallback

/// 签名回调协议
public protocol SigningCallback: Sendable {
    func sign(data: Data) async throws -> Data
}

// MARK: - SigningKeyHandle

/// 签名密钥句柄
public enum SigningKeyHandle: @unchecked Sendable {
    case softwareKey(Data)
    #if canImport(Security)
    case secureEnclaveRef(SecKey)
    #endif
    case callback(any SigningCallback)
}

// MARK: - SecureBytes

/// 安全字节容器 - deinit 时擦除内存
public final class SecureBytes: @unchecked Sendable {
    
    private let pointer: UnsafeMutableRawPointer
    private let count: Int
    
    nonisolated(unsafe) public static var wipingFunction: (UnsafeMutableRawPointer, Int) -> Void = { ptr, len in
        secureZeroMemory(ptr, len)
    }
    
    public init(count: Int) {
        self.count = count
        let allocSize = max(count, 1)
        self.pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if count > 0 {
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        }
    }
    
    public init(data: Data) {
        self.count = data.count
        let allocSize = max(data.count, 1)
        self.pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if data.count > 0 {
            data.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                pointer.copyMemory(from: base, byteCount: data.count)
            }
        }
    }
    
    public init(bytes: [UInt8]) {
        self.count = bytes.count
        let allocSize = max(bytes.count, 1)
        self.pointer = UnsafeMutableRawPointer.allocate(
            byteCount: allocSize,
            alignment: MemoryLayout<UInt8>.alignment
        )
        if bytes.count > 0 {
            bytes.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                pointer.copyMemory(from: base, byteCount: bytes.count)
            }
        }
    }
    
    deinit {
        if count > 0 {
            Self.wipingFunction(pointer, count)
        }
        pointer.deallocate()
    }
    
    public var byteCount: Int { count }
    public var isEmpty: Bool { count == 0 }
    
    public var data: Data {
        guard count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
    
    public func noCopyData() -> Data {
        guard count > 0 else { return Data() }
        return Data(bytesNoCopy: pointer, count: count, deallocator: .none)
    }
    
    public func unsafeRawBytes() -> Data { data }
    public func copyData() -> Data { data }
    public var bytes: Data { data }
    
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }
    
    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }
    
    public func zeroize() {
        if count > 0 {
            Self.wipingFunction(pointer, count)
        }
    }
}

extension SecureBytes: ContiguousBytes {}

// MARK: - Secure Zero

#if canImport(Darwin)
import Darwin

private typealias ExplicitBzeroFn = @convention(c) (UnsafeMutableRawPointer?, Int) -> Void

private func loadExplicitBzero() -> ExplicitBzeroFn? {
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "explicit_bzero") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ExplicitBzeroFn.self)
}

private func secureZeroMemory(_ ptr: UnsafeMutableRawPointer, _ count: Int) {
    if let fn = loadExplicitBzero() {
        fn(ptr, count)
        return
    }
    let bytes = ptr.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        bytes[i] = 0
    }
    withExtendedLifetime(ptr) { _ in }
}
#else
private func secureZeroMemory(_ ptr: UnsafeMutableRawPointer, _ count: Int) {
    let bytes = ptr.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        bytes[i] = 0
    }
    withExtendedLifetime(ptr) { _ in }
}
#endif

// MARK: - SessionKeys

/// 会话密钥
public struct SessionKeys: Sendable {
    public let sendKey: Data
    public let receiveKey: Data
    public let negotiatedSuite: CryptoSuite
    public let transcriptHash: Data
    
    public init(sendKey: Data, receiveKey: Data, negotiatedSuite: CryptoSuite, transcriptHash: Data) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.negotiatedSuite = negotiatedSuite
        self.transcriptHash = transcriptHash
    }
}

// MARK: - PeerIdentifier

/// 对端标识
public struct PeerIdentifier: Sendable, Hashable {
    public let deviceId: String
    public let endpoint: String?
    
    public init(deviceId: String, endpoint: String? = nil) {
        self.deviceId = deviceId
        self.endpoint = endpoint
    }
}

// MARK: - HandshakeRole

/// 握手角色
public enum HandshakeRole: String, Sendable {
    case initiator
    case responder
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

