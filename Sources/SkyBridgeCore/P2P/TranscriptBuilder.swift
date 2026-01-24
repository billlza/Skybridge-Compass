//
// TranscriptBuilder.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Transcript Builder for Deterministic Encoding
// Tech Debt Cleanup - 14: 降级攻击防护
// Requirements: 4.3, 4.8, 14.1, 14.2
//
// Transcript 用于握手签名验证，必须使用确定性编码确保跨平台一致性。
// 设计原则：
// 1. TLV 格式：(tag=messageType, bytes=deterministicEncodedMessage)
// 2. Date 统一编码：Unix epoch 毫秒（Int64 小端序）
// 3. 存储原始字节（debug/regression）+ hash（签名验证）
// 4. 降级攻击防护（downgrade resistance）：
//    - policy-in-transcript：transcript 必须包含 suiteWireId、双方 capabilities、policy（HandshakePolicy 的确定性编码）
//    - transcript binding：sigB/Finished 绑定 transcriptHash，确保协商套件与策略不可被中间人“静默改写”
//

import Foundation
import CryptoKit

// MARK: - Transcript Entry

/// Transcript 条目 - 存储单条消息的确定性编码
public struct TranscriptEntry: Sendable, Equatable {
 /// 消息类型标签
    public let messageType: P2PMessageType

 /// 确定性编码后的原始字节
    public let deterministicBytes: Data

 /// 消息字节的 SHA-256 哈希
    public let messageHash: Data

 /// 创建时间戳（毫秒）
    public let timestampMillis: Int64

    public init(messageType: P2PMessageType, deterministicBytes: Data) {
        self.messageType = messageType
        self.deterministicBytes = deterministicBytes
        self.messageHash = Data(SHA256.hash(data: deterministicBytes))
        self.timestampMillis = P2PTimestamp.nowMillis
    }

 /// TLV 编码：len(4 bytes, little-endian) || tag(1 byte) || bytes
 /// - Returns: TLV 编码后的数据
    public func tlvEncoded() -> Data {
        var result = Data()

 // Length: 1 (tag) + deterministicBytes.count
        let length = UInt32(1 + deterministicBytes.count).littleEndian
        result.append(contentsOf: withUnsafeBytes(of: length) { Data($0) })

 // Tag: messageType raw value
        result.append(messageType.rawValue)

 // Bytes: deterministic encoded message
        result.append(deterministicBytes)

        return result
    }
}

// MARK: - Transcript Builder

/// Transcript 构建器 - 管理握手消息的确定性编码和哈希计算
///
/// 使用方式：
/// ```swift
/// let builder = TranscriptBuilder(role: .initiator)
/// try builder.append(message: handshakeInit, type: .handshakeInit)
/// try builder.append(message: handshakeResponse, type: .handshakeResponse)
/// let hash = builder.computeHash()
/// ```
public final class TranscriptBuilder: @unchecked Sendable {

 // MARK: - Properties

 /// 当前角色
    public let role: P2PRole

 /// 协议版本
    public let protocolVersion: P2PProtocolVersion

 /// 域分离器
    public let domainSeparator: P2PDomainSeparator

 /// 已添加的条目（按顺序）
    private var entries: [TranscriptEntry] = []

 /// 线程安全锁
    private let lock = NSLock()

 // MARK: - Downgrade Protection Fields ( 14.1)
 // Requirement 14.1: transcript hash 必须包含 suiteWireId、双方 capabilities、policy

 /// 协商的套件 wireId
    private var negotiatedSuiteWireId: UInt16?

 /// 本地能力
    private var localCapabilities: CryptoCapabilities?

 /// 对端能力
    private var peerCapabilities: CryptoCapabilities?

 /// 握手策略
    private var handshakePolicy: HandshakePolicy?

 // MARK: - Initialization

    public init(
        role: P2PRole,
        protocolVersion: P2PProtocolVersion = .current,
        domainSeparator: P2PDomainSeparator = .transcript
    ) {
        self.role = role
        self.protocolVersion = protocolVersion
        self.domainSeparator = domainSeparator
    }

 // MARK: - Public Methods

 /// 添加消息到 transcript
 /// - Parameters:
 /// - message: 要添加的消息（必须符合 TranscriptEncodable）
 /// - type: 消息类型
 /// - Throws: TranscriptError 如果编码失败
    public func append<T: TranscriptEncodable>(message: T, type: P2PMessageType) throws {
        guard type.shouldEnterTranscript else {
            throw TranscriptError.messageTypeNotAllowed(type)
        }

        let bytes = try message.deterministicEncode()
        let entry = TranscriptEntry(messageType: type, deterministicBytes: bytes)

        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

 /// 添加原始字节到 transcript
 /// - Parameters:
 /// - bytes: 已经确定性编码的字节
 /// - type: 消息类型
 /// - Throws: TranscriptError 如果消息类型不允许
    public func appendRaw(bytes: Data, type: P2PMessageType) throws {
        guard type.shouldEnterTranscript else {
            throw TranscriptError.messageTypeNotAllowed(type)
        }

        let entry = TranscriptEntry(messageType: type, deterministicBytes: bytes)

        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

 /// 计算 transcript 哈希
 /// 公式：SHA256(domainSep || version || role || suiteWireId || localCap || peerCap || policy || concat(TLV entries))
 /// - Returns: 32 字节的 transcript 哈希
 ///
 /// Requirement 14.1: transcript hash 必须包含 suiteWireId、双方 capabilities、policy
    public func computeHash() -> Data {
        lock.lock()
        let currentEntries = entries
        let suiteWireId = negotiatedSuiteWireId
        let localCap = localCapabilities
        let peerCap = peerCapabilities
        let policy = handshakePolicy
        lock.unlock()

        var hasher = SHA256()

 // Domain separator
        hasher.update(data: Data(domainSeparator.rawValue.utf8))

 // Protocol version (4 bytes, little-endian)
        var version = UInt32(protocolVersion.rawValue).littleEndian
        hasher.update(data: Data(bytes: &version, count: 4))

 // Role
        hasher.update(data: Data(role.rawValue.utf8))

 // 14.1: suiteWireId (2 bytes, little-endian)
 // Requirement 14.1: suiteWireId 必须写入 transcript hash
        if let wireId = suiteWireId {
            var wireIdLE = wireId.littleEndian
            hasher.update(data: Data(bytes: &wireIdLE, count: 2))
        }

 // 14.1: Local capabilities
 // Requirement 14.1: 双方声明的 capability 必须写入 transcript
        if let cap = localCap, let capData = try? cap.deterministicEncode() {
            hasher.update(data: capData)
        }

 // 14.1: Peer capabilities
        if let cap = peerCap, let capData = try? cap.deterministicEncode() {
            hasher.update(data: capData)
        }

 // 14.1: Policy
 // Requirement 14.1: policy（至少 requirePQC 标志）必须写入 transcript
        if let pol = policy {
            hasher.update(data: pol.deterministicEncode())
        }

 // Concatenated TLV entries
        for entry in currentEntries {
            hasher.update(data: entry.tlvEncoded())
        }

        return Data(hasher.finalize())
    }

 /// 获取所有条目的原始字节（用于调试/回归测试）
 /// - Returns: 所有条目的 TLV 编码拼接
    public func getRawBytes() -> Data {
        lock.lock()
        let currentEntries = entries
        let suiteWireId = negotiatedSuiteWireId
        let localCap = localCapabilities
        let peerCap = peerCapabilities
        let policy = handshakePolicy
        lock.unlock()

        var result = Data()

 // Domain separator
        result.append(Data(domainSeparator.rawValue.utf8))

 // Protocol version (4 bytes, little-endian)
        var version = UInt32(protocolVersion.rawValue).littleEndian
        result.append(Data(bytes: &version, count: 4))

 // Role
        result.append(Data(role.rawValue.utf8))

 // 14.1: suiteWireId (2 bytes, little-endian)
        if let wireId = suiteWireId {
            var wireIdLE = wireId.littleEndian
            result.append(Data(bytes: &wireIdLE, count: 2))
        }

 // 14.1: Local capabilities
        if let cap = localCap, let capData = try? cap.deterministicEncode() {
            result.append(capData)
        }

 // 14.1: Peer capabilities
        if let cap = peerCap, let capData = try? cap.deterministicEncode() {
            result.append(capData)
        }

 // 14.1: Policy
        if let pol = policy {
            result.append(pol.deterministicEncode())
        }

 // Concatenated TLV entries
        for entry in currentEntries {
            result.append(entry.tlvEncoded())
        }

        return result
    }

 /// 获取条目数量
    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

 /// 获取所有条目（只读）
    public var allEntries: [TranscriptEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

 /// 清空所有条目
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        negotiatedSuiteWireId = nil
        localCapabilities = nil
        peerCapabilities = nil
        handshakePolicy = nil
    }

 // MARK: - Downgrade Protection Methods ( 14.1)

 /// 设置协商的套件 wireId
 /// Requirement 14.1: suiteWireId 必须写入 transcript hash
    public func setSuiteWireId(_ wireId: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        negotiatedSuiteWireId = wireId
    }

 /// 设置本地能力
 /// Requirement 14.1: 双方声明的 capability 必须写入 transcript
    public func setLocalCapabilities(_ capabilities: CryptoCapabilities) {
        lock.lock()
        defer { lock.unlock() }
        localCapabilities = capabilities
    }

 /// 设置对端能力
 /// Requirement 14.1: 双方声明的 capability 必须写入 transcript
    public func setPeerCapabilities(_ capabilities: CryptoCapabilities) {
        lock.lock()
        defer { lock.unlock() }
        peerCapabilities = capabilities
    }

 /// 设置握手策略
 /// Requirement 14.1: policy（至少 requirePQC 标志）必须写入 transcript
    public func setPolicy(_ policy: HandshakePolicy) {
        lock.lock()
        defer { lock.unlock() }
        handshakePolicy = policy
    }

 /// 创建副本（用于分支验证）
    public func copy() -> TranscriptBuilder {
        let newBuilder = TranscriptBuilder(
            role: role,
            protocolVersion: protocolVersion,
            domainSeparator: domainSeparator
        )

        lock.lock()
        newBuilder.entries = entries
        newBuilder.negotiatedSuiteWireId = negotiatedSuiteWireId
        newBuilder.localCapabilities = localCapabilities
        newBuilder.peerCapabilities = peerCapabilities
        newBuilder.handshakePolicy = handshakePolicy
        lock.unlock()

        return newBuilder
    }
}

// MARK: - Transcript Encodable Protocol

/// 可确定性编码的协议
/// 实现此协议的类型可以被添加到 transcript
public protocol TranscriptEncodable: Sendable {
 /// 确定性编码
 /// - Returns: 确定性编码后的字节
 /// - Throws: 编码错误
    func deterministicEncode() throws -> Data
}

// MARK: - Deterministic Encoder

/// 确定性编码器 - 确保跨平台一致的字节序列
///
/// 编码规则：
/// 1. 整数：小端序
/// 2. 字符串：UTF-8 编码，前缀 4 字节长度
/// 3. Data：前缀 4 字节长度
/// 4. Date：Unix epoch 毫秒（Int64 小端序）
/// 5. Bool：1 字节（0x00 或 0x01）
/// 6. Optional：1 字节标志 + 值（如果存在）
/// 7. Array：4 字节长度 + 元素
/// 8. 结构体：按字段声明顺序编码
public struct DeterministicEncoder {

    private var data: Data

    public init() {
        self.data = Data()
    }

 /// 获取编码结果
    public func finalize() -> Data {
        return data
    }

 // MARK: - Primitive Types

 /// 编码 UInt8
    public mutating func encode(_ value: UInt8) {
        data.append(value)
    }

 /// 编码 UInt16（小端序）
    public mutating func encode(_ value: UInt16) {
        var littleEndian = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Data($0) })
    }

 /// 编码 UInt32（小端序）
    public mutating func encode(_ value: UInt32) {
        var littleEndian = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Data($0) })
    }

 /// 编码 UInt64（小端序）
    public mutating func encode(_ value: UInt64) {
        var littleEndian = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Data($0) })
    }

 /// 编码 Int64（小端序）
    public mutating func encode(_ value: Int64) {
        var littleEndian = value.littleEndian
        data.append(contentsOf: withUnsafeBytes(of: &littleEndian) { Data($0) })
    }

 /// 编码 Int（作为 Int64）
    public mutating func encode(_ value: Int) {
        encode(Int64(value))
    }

 /// 编码 Bool
    public mutating func encode(_ value: Bool) {
        data.append(value ? 0x01 : 0x00)
    }

 /// 编码 String（UTF-8，前缀长度）
    public mutating func encode(_ value: String) {
        let utf8 = Data(value.utf8)
        encode(UInt32(utf8.count))
        data.append(utf8)
    }

 /// 编码 Data（前缀长度）
    public mutating func encode(_ value: Data) {
        encode(UInt32(value.count))
        data.append(value)
    }

 /// 编码 Date（Unix epoch 毫秒）
    public mutating func encode(_ value: Date) {
        let millis = P2PTimestamp.toMillis(value)
        encode(millis)
    }

 /// 编码 Optional
    public mutating func encode<T>(_ value: T?, encoder: (inout DeterministicEncoder, T) -> Void) {
        if let v = value {
            encode(true)
            encoder(&self, v)
        } else {
            encode(false)
        }
    }

 /// 编码 Array
    public mutating func encode<T>(_ values: [T], encoder: (inout DeterministicEncoder, T) -> Void) {
        encode(UInt32(values.count))
        for value in values {
            encoder(&self, value)
        }
    }

 /// 编码字符串数组
    public mutating func encode(_ values: [String]) {
        encode(UInt32(values.count))
        for value in values {
            encode(value)
        }
    }

 /// 编码 Data 数组
    public mutating func encode(_ values: [Data]) {
        encode(UInt32(values.count))
        for value in values {
            encode(value)
        }
    }
}

// MARK: - Deterministic Decoder

/// 确定性解码器
public struct DeterministicDecoder {

    private var data: Data
    private var offset: Int

    public init(data: Data) {
        self.data = data
        self.offset = 0
    }

 /// 剩余字节数
    public var remainingBytes: Int {
        return data.count - offset
    }

 /// 是否已到达末尾
    public var isAtEnd: Bool {
        return offset >= data.count
    }

 // MARK: - Primitive Types

 /// 解码 UInt8
    public mutating func decode() throws -> UInt8 {
        guard offset < data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let value = data[offset]
        offset += 1
        return value
    }

 /// 解码 UInt16（小端序）
    public mutating func decodeUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let value = data.subdata(in: offset..<offset+2).withUnsafeBytes {
            $0.load(as: UInt16.self).littleEndian
        }
        offset += 2
        return value
    }

 /// 解码 UInt32（小端序）
    public mutating func decodeUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let value = data.subdata(in: offset..<offset+4).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
        offset += 4
        return value
    }

 /// 解码 UInt64（小端序）
    public mutating func decodeUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let value = data.subdata(in: offset..<offset+8).withUnsafeBytes {
            $0.load(as: UInt64.self).littleEndian
        }
        offset += 8
        return value
    }

 /// 解码 Int64（小端序）
    public mutating func decodeInt64() throws -> Int64 {
        guard offset + 8 <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let value = data.subdata(in: offset..<offset+8).withUnsafeBytes {
            $0.load(as: Int64.self).littleEndian
        }
        offset += 8
        return value
    }

 /// 解码 Bool
    public mutating func decodeBool() throws -> Bool {
        let byte: UInt8 = try decode()
        return byte != 0
    }

 /// 解码 String
    public mutating func decodeString() throws -> String {
        let length = try decodeUInt32()
        guard offset + Int(length) <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let stringData = data.subdata(in: offset..<offset+Int(length))
        offset += Int(length)
        guard let string = String(data: stringData, encoding: .utf8) else {
            throw TranscriptError.decodingError("Invalid UTF-8 string")
        }
        return string
    }

 /// 解码 Data
    public mutating func decodeData() throws -> Data {
        let length = try decodeUInt32()
        guard offset + Int(length) <= data.count else {
            throw TranscriptError.decodingError("Unexpected end of data")
        }
        let result = data.subdata(in: offset..<offset+Int(length))
        offset += Int(length)
        return result
    }

 /// 解码 Date
    public mutating func decodeDate() throws -> Date {
        let millis = try decodeInt64()
        return P2PTimestamp.fromMillis(millis)
    }

 /// 解码字符串数组
    public mutating func decodeStringArray() throws -> [String] {
        let count = try decodeUInt32()
        var result: [String] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            result.append(try decodeString())
        }
        return result
    }

 /// 解码 Data 数组
    public mutating func decodeDataArray() throws -> [Data] {
        let count = try decodeUInt32()
        var result: [Data] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            result.append(try decodeData())
        }
        return result
    }
}

// MARK: - Transcript Error

/// Transcript 相关错误
public enum TranscriptError: Error, LocalizedError, Sendable {
    case messageTypeNotAllowed(P2PMessageType)
    case encodingError(String)
    case decodingError(String)
    case hashMismatch
    case invalidTranscript

    public var errorDescription: String? {
        switch self {
        case .messageTypeNotAllowed(let type):
            return "Message type '\(type.name)' is not allowed in transcript"
        case .encodingError(let message):
            return "Encoding error: \(message)"
        case .decodingError(let message):
            return "Decoding error: \(message)"
        case .hashMismatch:
            return "Transcript hash mismatch"
        case .invalidTranscript:
            return "Invalid transcript"
        }
    }
}

// MARK: - Transcript Verifier

/// Transcript 验证器 - 用于验证对端的 transcript
public struct TranscriptVerifier: Sendable {

 /// 验证两个 transcript 哈希是否匹配
 /// - Parameters:
 /// - local: 本地计算的哈希
 /// - remote: 远端提供的哈希
 /// - Returns: 是否匹配
    public static func verify(local: Data, remote: Data) -> Bool {
        guard local.count == 32, remote.count == 32 else {
            return false
        }
 // 使用常量时间比较防止时序攻击
        return constantTimeCompare(local, remote)
    }

 /// 常量时间比较
    private static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }
}


// MARK: - HandshakePolicy ( 14.1)

/// 握手策略
/// Requirement 14.1: policy（至少 requirePQC 标志）必须写入 transcript（policy-in-transcript）
/// Requirement 14.4: requirePQC 策略下 PQC 不可用时直接失败
public struct HandshakePolicy: Sendable, Equatable, Codable {
 /// 是否强制要求 PQC
 /// Requirement 14.4: requirePQC 策略下 PQC 不可用时直接失败，不允许 fallback 到 classic
    public let requirePQC: Bool

 /// 是否允许降级到经典算法
    public let allowClassicFallback: Bool

 /// 最低可接受的套件 tier
    public let minimumTier: CryptoTier

 /// 是否强制要求 Secure Enclave PoP
    public let requireSecureEnclavePoP: Bool

    public init(
        requirePQC: Bool = false,
        allowClassicFallback: Bool = true,
        minimumTier: CryptoTier = .classic,
        requireSecureEnclavePoP: Bool = false
    ) {
        self.requirePQC = requirePQC
        self.allowClassicFallback = requirePQC ? false : allowClassicFallback
        self.minimumTier = minimumTier
        self.requireSecureEnclavePoP = requireSecureEnclavePoP
    }

 /// 默认策略（优先 PQC，允许降级）
    public static let `default` = HandshakePolicy(
        requirePQC: false,
        allowClassicFallback: true,
        minimumTier: .classic,
        requireSecureEnclavePoP: false
    )

 /// 严格 PQC 策略（不允许降级）
    public static let strictPQC = HandshakePolicy(
        requirePQC: true,
        allowClassicFallback: false,
        // macOS/iOS 26+ 默认优先原生 PQC；若运行环境只有 liboqs，该字段仅用于策略/观测，不影响 suite.isPQC 判定
        minimumTier: .nativePQC,
        requireSecureEnclavePoP: false
    )

    /// 推荐默认策略（用于 26.2 对齐）：
    /// - macOS/iOS 26+ 且未开启兼容模式：strictPQC（禁止 classic fallback）
    /// - 其他情况：default（允许 classic fallback）
    public static func recommendedDefault(compatibilityModeEnabled: Bool) -> HandshakePolicy {
        if compatibilityModeEnabled {
            return .default
        }
        if #available(iOS 26.0, macOS 26.0, *) {
            return .strictPQC
        }
        return .default
    }

 /// 确定性编码（用于 Transcript）
    public func deterministicEncode() -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(requirePQC)
        encoder.encode(allowClassicFallback)
        encoder.encode(minimumTier.rawValue)
        encoder.encode(requireSecureEnclavePoP)
        return encoder.finalize()
    }
}
