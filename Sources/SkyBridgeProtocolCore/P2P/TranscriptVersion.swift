//
// TranscriptVersion.swift
// SkyBridgeCore
//
// 15.1-15.3: Transcript TLV Canonical
// Requirements: 5.1, 5.2, 5.3, 5.4, 14.1
//
// Transcript 编码版本化：
// - V1: 现有 deterministic encoding（向后兼容）
// - V2: TLV canonical encoding（新版本）
//
// 版本选择规则：
// - 双方 capability 协商
// - 强制同版本（升级期明确 fail-fast）
//

import Foundation
import CryptoKit

// MARK: - TranscriptVersion

/// Transcript 编码版本
///
/// **Requirements: 5.1, 14.1**
public enum TranscriptVersion: UInt8, Codable, Sendable, Equatable {
 /// V1: 现有 deterministic encoding
 /// - 使用 DeterministicEncoder
 /// - 字段按声明顺序编码
 /// - 向后兼容
    case v1 = 0x01
    
 /// V2: TLV canonical encoding
 /// - 每个字段使用 tag + len + value
 /// - 支持字段扩展
 /// - 更强的前向兼容性
    case v2 = 0x02
    
 /// 当前默认版本
    public static let current: TranscriptVersion = .v1
    
 /// 支持的所有版本
    public static let supported: [TranscriptVersion] = [.v1, .v2]
    
 /// 版本名称
    public var name: String {
        switch self {
        case .v1: return "V1-Deterministic"
        case .v2: return "V2-TLV-Canonical"
        }
    }
}

// MARK: - TLV Tags

/// TLV 标签定义
///
/// **Requirements: 5.2, 5.3**
public enum TranscriptTLVTag: UInt8, Sendable {
 // MARK: - Header Tags (0x01-0x0F)
    
 /// 协议版本
    case protocolVersion = 0x01
    
 /// 角色 (initiator/responder)
    case role = 0x02
    
 /// 域分离器
    case domainSeparator = 0x03
    
 /// Transcript 版本
    case transcriptVersion = 0x04
    
 // MARK: - Negotiation Tags (0x10-0x1F)
    
 /// 协商的套件 wireId
    case suiteWireId = 0x10
    
 /// 本地能力
    case localCapabilities = 0x11
    
 /// 对端能力
    case peerCapabilities = 0x12
    
 /// 握手策略
    case policy = 0x13
    
 /// 签名算法
    case signatureAlgorithm = 0x14
    
 // MARK: - Message Tags (0x20-0x2F)
    
 /// MessageA 内容
    case messageA = 0x20
    
 /// MessageB 内容
    case messageB = 0x21
    
 /// Finished 消息
    case finished = 0x22
    
 // MARK: - Identity Tags (0x30-0x3F)
    
 /// Initiator 公钥
    case initiatorPublicKey = 0x30
    
 /// Responder 公钥
    case responderPublicKey = 0x31
    
 /// Initiator nonce
    case initiatorNonce = 0x32
    
 /// Responder nonce
    case responderNonce = 0x33
    
 // MARK: - Extension Tags (0xF0-0xFF)
    
 /// 扩展字段（预留）
    case extension0 = 0xF0
}

// MARK: - TLV Encoder

/// TLV 编码器
///
/// 格式: tag(1 byte) + len(4 bytes, big-endian) + value(len bytes)
///
/// **Requirements: 5.2, 5.3, 5.4**
public struct TLVEncoder {
    
    private var data: Data
    
    public init() {
        self.data = Data()
    }
    
 /// 获取编码结果
    public func finalize() -> Data {
        return data
    }
    
 /// 编码 TLV 字段
 /// - Parameters:
 /// - tag: 标签
 /// - value: 值
    public mutating func encode(tag: TranscriptTLVTag, value: Data) {
 // Tag: 1 byte
        data.append(tag.rawValue)
        
 // Length: 4 bytes, big-endian
        var length = UInt32(value.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        
 // Value
        data.append(value)
    }
    
 /// 编码 UInt8
    public mutating func encode(tag: TranscriptTLVTag, uint8 value: UInt8) {
        encode(tag: tag, value: Data([value]))
    }
    
 /// 编码 UInt16 (big-endian)
    public mutating func encode(tag: TranscriptTLVTag, uint16 value: UInt16) {
        var be = value.bigEndian
        encode(tag: tag, value: Data(bytes: &be, count: 2))
    }
    
 /// 编码 UInt32 (big-endian)
    public mutating func encode(tag: TranscriptTLVTag, uint32 value: UInt32) {
        var be = value.bigEndian
        encode(tag: tag, value: Data(bytes: &be, count: 4))
    }
    
 /// 编码 String (UTF-8)
    public mutating func encode(tag: TranscriptTLVTag, string value: String) {
        encode(tag: tag, value: Data(value.utf8))
    }
    
 /// 编码 Bool
    public mutating func encode(tag: TranscriptTLVTag, bool value: Bool) {
        encode(tag: tag, value: Data([value ? 0x01 : 0x00]))
    }
}

// MARK: - TLV Decoder

/// TLV 解码器
///
/// **Requirements: 5.2, 5.3**
public struct TLVDecoder {
    
    private var data: Data
    private var offset: Int
    
    public init(data: Data) {
        self.data = data
        self.offset = 0
    }
    
 /// 是否已到达末尾
    public var isAtEnd: Bool {
        return offset >= data.count
    }
    
 /// 解码下一个 TLV 字段
 /// - Returns: (tag, value) 元组
 /// - Throws: 解码错误
    public mutating func decodeNext() throws -> (tag: UInt8, value: Data) {
 // Tag: 1 byte
        guard offset < data.count else {
            throw TranscriptError.decodingError("Unexpected end of TLV data")
        }
        let tag = data[offset]
        offset += 1
        
 // Length: 4 bytes, big-endian
        guard offset + 4 <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of TLV length")
        }
        let length = data.subdata(in: offset..<offset+4).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }
        offset += 4
        
 // Value
        guard offset + Int(length) <= data.count else {
            throw TranscriptError.decodingError("TLV value exceeds data bounds")
        }
        let value = data.subdata(in: offset..<offset+Int(length))
        offset += Int(length)
        
        return (tag, value)
    }
    
 /// 解码所有 TLV 字段
 /// - Returns: 字典 [tag: value]
    public mutating func decodeAll() throws -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        while !isAtEnd {
            let (tag, value) = try decodeNext()
            result[tag] = value
        }
        return result
    }
}

// MARK: - Versioned Transcript Builder

/// 版本化 Transcript 构建器
///
/// 支持 V1 和 V2 两种编码格式。
///
/// **Requirements: 5.1, 5.2, 5.3, 5.4, 5.5**
@available(macOS 14.0, iOS 17.0, *)
public final class VersionedTranscriptBuilder: @unchecked Sendable {
    
 // MARK: - Properties
    
 /// Transcript 版本
    public let version: TranscriptVersion
    
 /// 当前角色
    public let role: P2PRole
    
 /// 协议版本
    public let protocolVersion: P2PProtocolVersion
    
 /// 域分离器
    public let domainSeparator: P2PDomainSeparator
    
 /// 线程安全锁
    private let lock = NSLock()
    
 // MARK: - Transcript Fields
    
    private var suiteWireId: UInt16?
    private var localCapabilities: CryptoCapabilities?
    private var peerCapabilities: CryptoCapabilities?
    private var policy: HandshakePolicy?
    private var signatureAlgorithm: ProtocolSigningAlgorithm?
    
    private var initiatorPublicKey: Data?
    private var responderPublicKey: Data?
    private var initiatorNonce: Data?
    private var responderNonce: Data?
    
    private var messageABytes: Data?
    private var messageBBytes: Data?
    
 // MARK: - Initialization
    
    public init(
        version: TranscriptVersion = .current,
        role: P2PRole,
        protocolVersion: P2PProtocolVersion = .current,
        domainSeparator: P2PDomainSeparator = .transcript
    ) {
        self.version = version
        self.role = role
        self.protocolVersion = protocolVersion
        self.domainSeparator = domainSeparator
    }
    
 // MARK: - Setters
    
    public func setSuiteWireId(_ wireId: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        suiteWireId = wireId
    }
    
    public func setLocalCapabilities(_ capabilities: CryptoCapabilities) {
        lock.lock()
        defer { lock.unlock() }
        localCapabilities = capabilities
    }
    
    public func setPeerCapabilities(_ capabilities: CryptoCapabilities) {
        lock.lock()
        defer { lock.unlock() }
        peerCapabilities = capabilities
    }
    
    public func setPolicy(_ policy: HandshakePolicy) {
        lock.lock()
        defer { lock.unlock() }
        self.policy = policy
    }
    
    public func setSignatureAlgorithm(_ algorithm: ProtocolSigningAlgorithm) {
        lock.lock()
        defer { lock.unlock() }
        signatureAlgorithm = algorithm
    }
    
    public func setInitiatorPublicKey(_ key: Data) {
        lock.lock()
        defer { lock.unlock() }
        initiatorPublicKey = key
    }
    
    public func setResponderPublicKey(_ key: Data) {
        lock.lock()
        defer { lock.unlock() }
        responderPublicKey = key
    }
    
    public func setInitiatorNonce(_ nonce: Data) {
        lock.lock()
        defer { lock.unlock() }
        initiatorNonce = nonce
    }
    
    public func setResponderNonce(_ nonce: Data) {
        lock.lock()
        defer { lock.unlock() }
        responderNonce = nonce
    }
    
    public func setMessageA(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        messageABytes = bytes
    }
    
    public func setMessageB(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        messageBBytes = bytes
    }
    
 // MARK: - Compute Hash
    
 /// 计算 transcript 哈希
 ///
 /// **Requirements: 5.1, 5.5**
    public func computeHash() -> Data {
        lock.lock()
        let bytes = encodeTranscript()
        lock.unlock()
        
        return Data(SHA256.hash(data: bytes))
    }
    
 /// 获取原始编码字节
    public func getRawBytes() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return encodeTranscript()
    }
    
 // MARK: - Private Methods
    
    private func encodeTranscript() -> Data {
        switch version {
        case .v1:
            return encodeV1()
        case .v2:
            return encodeV2()
        }
    }
    
 /// V1 编码（现有 deterministic encoding）
    private func encodeV1() -> Data {
        var encoder = DeterministicEncoder()
        
 // Domain separator
        encoder.encode(domainSeparator.rawValue)
        
 // Protocol version
        encoder.encode(UInt32(protocolVersion.rawValue))
        
 // Role
        encoder.encode(role.rawValue)
        
 // Suite wireId
        if let wireId = suiteWireId {
            encoder.encode(wireId)
        }
        
 // Local capabilities
        if let cap = localCapabilities, let capData = try? cap.deterministicEncode() {
            encoder.encode(capData)
        }
        
 // Peer capabilities
        if let cap = peerCapabilities, let capData = try? cap.deterministicEncode() {
            encoder.encode(capData)
        }
        
 // Policy
        if let pol = policy {
            encoder.encode(pol.deterministicEncode())
        }
        
 // Signature algorithm
        if let alg = signatureAlgorithm {
            encoder.encode(alg.wireCode)
        }
        
 // Identity keys and nonces
        if let key = initiatorPublicKey {
            encoder.encode(key)
        }
        if let key = responderPublicKey {
            encoder.encode(key)
        }
        if let nonce = initiatorNonce {
            encoder.encode(nonce)
        }
        if let nonce = responderNonce {
            encoder.encode(nonce)
        }
        
 // Messages
        if let msgA = messageABytes {
            encoder.encode(msgA)
        }
        if let msgB = messageBBytes {
            encoder.encode(msgB)
        }
        
        return encoder.finalize()
    }
    
 /// V2 编码（TLV canonical）
 ///
 /// **Requirements: 5.2, 5.3, 5.4**
    private func encodeV2() -> Data {
        var encoder = TLVEncoder()
        
 // Header
        encoder.encode(tag: .transcriptVersion, uint8: version.rawValue)
        encoder.encode(tag: .domainSeparator, string: domainSeparator.rawValue)
        encoder.encode(tag: .protocolVersion, uint32: UInt32(protocolVersion.rawValue))
        encoder.encode(tag: .role, string: role.rawValue)
        
 // Negotiation
        if let wireId = suiteWireId {
            encoder.encode(tag: .suiteWireId, uint16: wireId)
        }
        
        if let cap = localCapabilities, let capData = try? cap.deterministicEncode() {
            encoder.encode(tag: .localCapabilities, value: capData)
        }
        
        if let cap = peerCapabilities, let capData = try? cap.deterministicEncode() {
            encoder.encode(tag: .peerCapabilities, value: capData)
        }
        
        if let pol = policy {
            encoder.encode(tag: .policy, value: pol.deterministicEncode())
        }
        
        if let alg = signatureAlgorithm {
            encoder.encode(tag: .signatureAlgorithm, uint16: alg.wireCode)
        }
        
 // Identity
        if let key = initiatorPublicKey {
            encoder.encode(tag: .initiatorPublicKey, value: key)
        }
        if let key = responderPublicKey {
            encoder.encode(tag: .responderPublicKey, value: key)
        }
        if let nonce = initiatorNonce {
            encoder.encode(tag: .initiatorNonce, value: nonce)
        }
        if let nonce = responderNonce {
            encoder.encode(tag: .responderNonce, value: nonce)
        }
        
 // Messages
        if let msgA = messageABytes {
            encoder.encode(tag: .messageA, value: msgA)
        }
        if let msgB = messageBBytes {
            encoder.encode(tag: .messageB, value: msgB)
        }
        
        return encoder.finalize()
    }
    
 /// 重置
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        suiteWireId = nil
        localCapabilities = nil
        peerCapabilities = nil
        policy = nil
        signatureAlgorithm = nil
        initiatorPublicKey = nil
        responderPublicKey = nil
        initiatorNonce = nil
        responderNonce = nil
        messageABytes = nil
        messageBBytes = nil
    }
}

// MARK: - Version Negotiation

/// Transcript 版本协商
///
/// **Requirements: 5.1**
public struct TranscriptVersionNegotiator {
    
 /// 协商版本
 /// - Parameters:
 /// - localSupported: 本地支持的版本
 /// - peerSupported: 对端支持的版本
 /// - Returns: 协商结果（最高共同支持版本）
 /// - Throws: 如果没有共同支持的版本
    public static func negotiate(
        localSupported: [TranscriptVersion],
        peerSupported: [TranscriptVersion]
    ) throws -> TranscriptVersion {
 // 找到双方都支持的最高版本
        let common = Set(localSupported).intersection(Set(peerSupported))
        
        guard !common.isEmpty else {
            throw TranscriptVersionError.noCommonVersion(
                local: localSupported,
                peer: peerSupported
            )
        }
        
 // 返回最高版本
        return common.max(by: { $0.rawValue < $1.rawValue })!
    }
    
 /// 验证版本兼容性
 /// - Parameters:
 /// - expected: 预期版本
 /// - actual: 实际版本
 /// - Returns: 是否兼容
    public static func isCompatible(expected: TranscriptVersion, actual: TranscriptVersion) -> Bool {
 // 严格版本匹配（升级期 fail-fast）
        return expected == actual
    }
}

// MARK: - TranscriptVersionError

/// Transcript 版本错误
public enum TranscriptVersionError: Error, LocalizedError, Sendable {
 /// 没有共同支持的版本
    case noCommonVersion(local: [TranscriptVersion], peer: [TranscriptVersion])
    
 /// 版本不匹配
    case versionMismatch(expected: TranscriptVersion, actual: TranscriptVersion)
    
 /// 不支持的版本
    case unsupportedVersion(UInt8)
    
    public var errorDescription: String? {
        switch self {
        case .noCommonVersion(let local, let peer):
            return "No common transcript version: local=\(local.map { $0.name }), peer=\(peer.map { $0.name })"
        case .versionMismatch(let expected, let actual):
            return "Transcript version mismatch: expected \(expected.name), got \(actual.name)"
        case .unsupportedVersion(let version):
            return "Unsupported transcript version: 0x\(String(format: "%02X", version))"
        }
    }
}
