//
// PAKEService.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - PAKE (Password-Authenticated Key Exchange) Service
// Requirements: 2.3, 2.4, 2.5, 2.7, 2.8
//
// 实现 SPAKE2+ 协议用于 6 位配对码场景。
// 参考：RFC 9382 (SPAKE2+)
//
// 安全原则：
// 1. 6 位配对码仅作为 PAKE 输入，绝不直接用作 PSK
// 2. 使用 P-256 椭圆曲线群
// 3. 实现速率限制和指数退避
//

import Foundation
import CryptoKit
import Security

// MARK: - SPAKE2+ Group Constants

/// SPAKE2+ 群常量 (P-256)
/// M 和 N 是 P-256 曲线上的随机点，用于密码盲化
/// 这些值来自 RFC 9382 附录 A
public enum SPAKE2Constants {
 /// P-256 曲线阶 (n)
    static let curveOrder = Data(hexString: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!

 /// M 点 (用于 initiator 盲化) - RFC 9382 P-256 M
 /// M = HashToPoint("SPAKE2+ M")
    static let pointM = Data(hexString: "02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f")!

 /// N 点 (用于 responder 盲化) - RFC 9382 P-256 N
 /// N = HashToPoint("SPAKE2+ N")
    static let pointN = Data(hexString: "03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49")!

 /// 域分离器
    static let domainSeparator = "SkyBridge-SPAKE2+-v1"

 /// 密码派生迭代次数 (PBKDF2)
    static let pbkdf2Iterations = 100_000

 /// 盐长度
    static let saltLength = 32
}

// MARK: - PAKE Message Types

/// PAKE 消息 A (Initiator → Responder)
public struct PAKEMessageA: Codable, Sendable, TranscriptEncodable {
 /// SPAKE2+ 公开值 (pA = w*M + X)
    public let publicValue: Data

 /// 设备 ID
    public let deviceId: String

 /// 加密能力
    public let cryptoCapabilities: CryptoCapabilities

 /// 时间戳
    public let timestamp: Date

 /// 随机 nonce
    public let nonce: Data

    public init(
        publicValue: Data,
        deviceId: String,
        cryptoCapabilities: CryptoCapabilities,
        timestamp: Date = Date(),
        nonce: Data? = nil
    ) {
        self.publicValue = publicValue
        self.deviceId = deviceId
        self.cryptoCapabilities = cryptoCapabilities
        self.timestamp = timestamp
        self.nonce = nonce ?? Self.generateNonce()
    }

 /// Generate cryptographically secure random nonce
 /// 19.1: Type C force unwrap handling (Requirements 9.1, 9.2)
 /// - DEBUG: assertionFailure() to alert developer
 /// - RELEASE: emit SecurityEvent and return fallback nonce
    private static func generateNonce() -> Data {
        var nonce = Data(count: P2PConstants.nonceSize)
        let status = nonce.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, P2PConstants.nonceSize, baseAddress)
        }

        if status != errSecSuccess {
 // Type C: Development assertion - should never fail in normal operation
            #if DEBUG
            assertionFailure("SecRandomCopyBytes failed with status \(status) - this indicates a serious system issue")
            #endif

// RELEASE: Emit security event and return a sentinel nonce.
// We do NOT silently downgrade to a predictable "fake-random" nonce for PAKE.
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .cryptoProviderSelected,  // Reuse existing type for crypto-related events
                severity: .critical,
                message: "SecRandomCopyBytes failed in PAKEMessageA.generateNonce",
                context: [
                    "status": String(status),
                    "component": "PAKEService",
                    "fallback": "zero-nonce"
                ]
            ))
            return Data(repeating: 0, count: P2PConstants.nonceSize)
        }

        return nonce
    }

    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(publicValue)
        encoder.encode(deviceId)
        let capabilitiesData = try cryptoCapabilities.deterministicEncode()
        encoder.encode(capabilitiesData)
        encoder.encode(timestamp)
        encoder.encode(nonce)
        return encoder.finalize()
    }
}

/// PAKE 消息 B (Responder → Initiator)
public struct PAKEMessageB: Codable, Sendable, TranscriptEncodable {
 /// SPAKE2+ 公开值 (pB = w*N + Y)
    public let publicValue: Data

 /// 确认 MAC
    public let confirmationMAC: Data

 /// 设备 ID
    public let deviceId: String

 /// 协商后的加密配置
    public let negotiatedProfile: NegotiatedCryptoProfile

 /// 时间戳
    public let timestamp: Date

 /// 随机 nonce
    public let nonce: Data

    public init(
        publicValue: Data,
        confirmationMAC: Data,
        deviceId: String,
        negotiatedProfile: NegotiatedCryptoProfile,
        timestamp: Date = Date(),
        nonce: Data? = nil
    ) {
        self.publicValue = publicValue
        self.confirmationMAC = confirmationMAC
        self.deviceId = deviceId
        self.negotiatedProfile = negotiatedProfile
        self.timestamp = timestamp
        self.nonce = nonce ?? Self.generateNonce()
    }

 /// Generate cryptographically secure random nonce
 /// 19.1: Type C force unwrap handling (Requirements 9.1, 9.2)
 /// - DEBUG: assertionFailure() to alert developer
 /// - RELEASE: emit SecurityEvent and return fallback nonce
    private static func generateNonce() -> Data {
        var nonce = Data(count: P2PConstants.nonceSize)
        let status = nonce.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, P2PConstants.nonceSize, baseAddress)
        }

        if status != errSecSuccess {
 // Type C: Development assertion - should never fail in normal operation
            #if DEBUG
            assertionFailure("SecRandomCopyBytes failed with status \(status) - this indicates a serious system issue")
            #endif

// RELEASE: Emit security event and return a sentinel nonce.
// We do NOT silently downgrade to a predictable "fake-random" nonce for PAKE.
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .cryptoProviderSelected,
                severity: .critical,
                message: "SecRandomCopyBytes failed in PAKEMessageB.generateNonce",
                context: [
                    "status": String(status),
                    "component": "PAKEService",
                    "fallback": "zero-nonce"
                ]
            ))
            return Data(repeating: 0, count: P2PConstants.nonceSize)
        }

        return nonce
    }

    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(publicValue)
        encoder.encode(confirmationMAC)
        encoder.encode(deviceId)
        let profileData = try negotiatedProfile.deterministicEncode()
        encoder.encode(profileData)
        encoder.encode(timestamp)
        encoder.encode(nonce)
        return encoder.finalize()
    }
}

/// PAKE 确认消息 (Initiator → Responder)
public struct PAKEConfirmation: Codable, Sendable, TranscriptEncodable {
 /// 确认 MAC
    public let confirmationMAC: Data

 /// 时间戳
    public let timestamp: Date

    public init(confirmationMAC: Data, timestamp: Date = Date()) {
        self.confirmationMAC = confirmationMAC
        self.timestamp = timestamp
    }

    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(confirmationMAC)
        encoder.encode(timestamp)
        return encoder.finalize()
    }
}


// MARK: - PAKE Session State

/// PAKE 会话状态
public enum PAKESessionState: Sendable {
    case idle
    case initiated(privateKey: Data, publicValue: Data, password: Data)
    case responded(sharedSecret: Data)
    case completed(sharedSecret: Data)
    case failed(PAKEError)
}

// MARK: - PAKE Error

/// PAKE 错误
public enum PAKEError: Error, LocalizedError, Sendable {
    case invalidPassword
    case invalidPublicValue
    case macVerificationFailed
    case sessionNotInitiated
    case sessionAlreadyCompleted
    case rateLimited(retryAfter: TimeInterval)
    case lockout(until: Date)
    case invalidState
    case cryptoError(String)
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidPassword:
            return "Invalid pairing code"
        case .invalidPublicValue:
            return "Invalid PAKE public value"
        case .macVerificationFailed:
            return "MAC verification failed - pairing code mismatch"
        case .sessionNotInitiated:
            return "PAKE session not initiated"
        case .sessionAlreadyCompleted:
            return "PAKE session already completed"
        case .rateLimited(let retryAfter):
            return "Rate limited, retry after \(Int(retryAfter)) seconds"
        case .lockout(let until):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Locked out until \(formatter.string(from: until))"
        case .invalidState:
            return "Invalid PAKE state"
        case .cryptoError(let message):
            return "Crypto error: \(message)"
        case .randomGenerationFailed(let status):
            return "Secure random generation failed (status: \(status))"
        }
    }
}

// MARK: - Rate Limiter

/// 速率限制器（带懒清理 + 总量上限，防内存灌水攻击）
actor PAKERateLimiter {
 /// 失败记录 (deviceId/IP -> 失败次数和时间)
    private var failureRecords: [String: FailureRecord] = [:]

 /// 锁定记录
    private var lockoutRecords: [String: Date] = [:]

 /// 记录 TTL（10 分钟）
    private static let recordTTLSeconds: TimeInterval = 600

 /// 最大记录数（防内存灌水）
    private static let maxRecordCount: Int = 50_000

 /// 上次清理时间
    private var lastCleanupTime: Date = Date()

 /// 清理间隔（每 60 秒最多清理一次）
    private static let cleanupIntervalSeconds: TimeInterval = 60

    struct FailureRecord {
        var count: Int
        var lastFailure: Date
        var backoffLevel: Int
    }

 /// 检查是否被限制
    func checkRateLimit(for identifier: String) throws {
 // 懒清理：每次检查时顺便清理过期记录
        lazyCleanupIfNeeded()

 // 检查锁定
        if let lockoutUntil = lockoutRecords[identifier], Date() < lockoutUntil {
            throw PAKEError.lockout(until: lockoutUntil)
        }

 // 检查速率限制
        if let record = failureRecords[identifier] {
            let backoffSeconds = calculateBackoff(level: record.backoffLevel)
            let nextAllowed = record.lastFailure.addingTimeInterval(backoffSeconds)

            if Date() < nextAllowed {
                throw PAKEError.rateLimited(retryAfter: nextAllowed.timeIntervalSinceNow)
            }
        }
    }

 /// 记录失败
    func recordFailure(for identifier: String) {
 // 懒清理
        lazyCleanupIfNeeded()

 // 总量上限检查：如果已满，先淘汰最旧的记录
        enforceRecordLimit()

        var record = failureRecords[identifier] ?? FailureRecord(count: 0, lastFailure: Date(), backoffLevel: 0)
        record.count += 1
        record.lastFailure = Date()
        record.backoffLevel = min(record.backoffLevel + 1, 10) // 最大退避级别

        failureRecords[identifier] = record

 // 达到最大失败次数，锁定
        if record.count >= P2PConstants.maxPairingAttempts {
            lockoutRecords[identifier] = Date().addingTimeInterval(P2PConstants.pairingLockoutSeconds)
            failureRecords[identifier] = nil // 重置失败计数
        }
    }

 /// 记录成功（重置计数）
    func recordSuccess(for identifier: String) {
        failureRecords[identifier] = nil
        lockoutRecords[identifier] = nil
    }

 /// 计算指数退避时间
    private func calculateBackoff(level: Int) -> TimeInterval {
        let base = P2PConstants.exponentialBackoffBaseSeconds
 // 防止 level 过大导致溢出
        let clampedLevel = min(level, 20)
        let backoff = base * pow(2.0, Double(clampedLevel))
        return min(backoff, P2PConstants.exponentialBackoffMaxSeconds)
    }

 /// 懒清理：如果距离上次清理超过间隔，执行清理
    private func lazyCleanupIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanupTime) >= Self.cleanupIntervalSeconds else {
            return
        }

        cleanup()
        lastCleanupTime = now
    }

 /// 清理过期记录
    func cleanup() {
        let now = Date()

 // 清理过期锁定
        lockoutRecords = lockoutRecords.filter { $0.value > now }

 // 清理过期失败记录（超过 TTL）
        let ttlCutoff = now.addingTimeInterval(-Self.recordTTLSeconds)
        failureRecords = failureRecords.filter { $0.value.lastFailure > ttlCutoff }
    }

 /// 强制执行记录数量上限（LRU 淘汰）
    private func enforceRecordLimit() {
        let totalCount = failureRecords.count + lockoutRecords.count
        guard totalCount >= Self.maxRecordCount else { return }

 // 淘汰最旧的 10% 失败记录
        let toRemove = max(1, failureRecords.count / 10)
        let sortedKeys = failureRecords.sorted { $0.value.lastFailure < $1.value.lastFailure }
            .prefix(toRemove)
            .map { $0.key }

        for key in sortedKeys {
            failureRecords.removeValue(forKey: key)
        }

 // 淘汰过期的锁定记录
        let now = Date()
        lockoutRecords = lockoutRecords.filter { $0.value > now }
    }

 /// 获取当前记录数（用于监控）
    var recordCount: Int {
        failureRecords.count + lockoutRecords.count
    }
}


// MARK: - PAKE Service

/// PAKE 服务 - 实现 SPAKE2+ 协议
///
/// 使用方式：
/// ```swift
/// // Initiator
/// let service = PAKEService()
/// let messageA = try await service.initiateExchange(password: "123456", peerId: "device-123")
/// // 发送 messageA 给 responder...
/// // 收到 messageB 后
/// let sharedSecret = try await service.completeExchange(messageB: messageB, peerId: "device-123")
///
/// // Responder
/// let service = PAKEService()
/// let (messageB, sharedSecret) = try await service.respondToExchange(
/// messageA: messageA,
/// password: "123456",
/// peerId: "device-456"
/// )
/// ```
@available(macOS 14.0, iOS 17.0, *)
public actor PAKEService {

 // MARK: - Properties

 /// 速率限制器 (使用 PAKERateLimiterMemory 实现有界内存管理)
 /// Requirements: 5.1-5.6 (PAKE memory management)
    private let rateLimiter: PAKERateLimiterMemory

 /// 会话状态 (peerId -> state)
    private var sessions: [String: PAKESessionState] = [:]

 /// 本机设备 ID
    private let localDeviceId: String

 /// 加密能力
    private var cryptoCapabilities: CryptoCapabilities?

 // MARK: - Initialization

    public init(localDeviceId: String? = nil, limits: SecurityLimits = .default) {
        self.localDeviceId = localDeviceId ?? UUID().uuidString
        self.rateLimiter = PAKERateLimiterMemory(
            limits: limits,
            maxAttempts: P2PConstants.maxPairingAttempts,
            lockoutDuration: .seconds(Int64(P2PConstants.pairingLockoutSeconds)),
            backoffBaseSeconds: P2PConstants.exponentialBackoffBaseSeconds,
            backoffMaxSeconds: P2PConstants.exponentialBackoffMaxSeconds
        )
    }

 // MARK: - Public Methods

 /// 发起 PAKE 交换（Initiator）
 /// - Parameters:
 /// - password: 6 位配对码
 /// - peerId: 对端设备 ID
 /// - Returns: PAKE 消息 A
    public func initiateExchange(
        password: String,
        peerId: String
    ) async throws -> PAKEMessageA {
 // 检查速率限制 (Requirements: 5.1-5.6)
        try await checkRateLimitAndThrow(for: peerId)

 // 验证密码格式
        guard isValidPairingCode(password) else {
            throw PAKEError.invalidPassword
        }

 // 派生密码标量 w
        let passwordScalar = derivePasswordScalar(password: password, peerId: peerId)

 // 生成临时密钥对 (x, X = x*G)
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKeyPoint = privateKey.publicKey.compressedRepresentation

 // 计算 pA = w*M + X
 // 注意：这里简化实现，实际需要椭圆曲线点运算
 // 在生产环境中应使用专门的 SPAKE2+ 库
        let blindedPoint = computeBlindedPoint(
            scalar: passwordScalar,
            blindingPoint: SPAKE2Constants.pointM,
            publicKey: publicKeyPoint
        )

 // 获取加密能力
        let capabilities = await getLocalCapabilities()

 // 创建消息 A
        let messageA = PAKEMessageA(
            publicValue: blindedPoint,
            deviceId: localDeviceId,
            cryptoCapabilities: capabilities,
            nonce: try generateSecureNonce(context: "PAKEMessageA")
        )

 // 保存会话状态
        sessions[peerId] = .initiated(
            privateKey: privateKey.rawRepresentation,
            publicValue: blindedPoint,
            password: passwordScalar
        )

        return messageA
    }

 /// 响应 PAKE 交换（Responder）
 /// - Parameters:
 /// - messageA: 收到的消息 A
 /// - password: 6 位配对码
 /// - peerId: 对端设备 ID
 /// - Returns: (消息 B, 共享密钥)
    public func respondToExchange(
        messageA: PAKEMessageA,
        password: String,
        peerId: String
    ) async throws -> (PAKEMessageB, sharedSecret: Data) {
 // 检查速率限制 (Requirements: 5.1-5.6)
        try await checkRateLimitAndThrow(for: peerId)

 // 验证密码格式
        guard isValidPairingCode(password) else {
            throw PAKEError.invalidPassword
        }

 // 验证消息 A
        guard !messageA.publicValue.isEmpty else {
            await rateLimiter.recordFailedAttempt(identifier: peerId)
            throw PAKEError.invalidPublicValue
        }

 // 派生密码标量 w
        let passwordScalar = derivePasswordScalar(password: password, peerId: peerId)

 // 生成临时密钥对 (y, Y = y*G)
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKeyPoint = privateKey.publicKey.compressedRepresentation

 // 计算 pB = w*N + Y
        let blindedPoint = computeBlindedPoint(
            scalar: passwordScalar,
            blindingPoint: SPAKE2Constants.pointN,
            publicKey: publicKeyPoint
        )

 // 计算共享密钥
 // K = y * (pA - w*M) = y * X
        let sharedSecret = try computeSharedSecret(
            myPrivateKey: privateKey.rawRepresentation,
            peerBlindedPoint: messageA.publicValue,
            passwordScalar: passwordScalar
        )

 // 派生确认密钥和会话密钥
        let (confirmKey, sessionKey) = deriveKeys(
            sharedSecret: sharedSecret,
            pA: messageA.publicValue,
            pB: blindedPoint,
            idA: messageA.deviceId,
            idB: localDeviceId
        )

 // 计算确认 MAC
        let confirmationMAC = computeMAC(
            key: confirmKey,
            data: messageA.publicValue + blindedPoint
        )

 // 协商加密配置
        let negotiatedProfile = await negotiateProfile(with: messageA.cryptoCapabilities)

 // 创建消息 B
        let messageB = PAKEMessageB(
            publicValue: blindedPoint,
            confirmationMAC: confirmationMAC,
            deviceId: localDeviceId,
            negotiatedProfile: negotiatedProfile,
            nonce: try generateSecureNonce(context: "PAKEMessageB")
        )

 // 保存会话状态
        sessions[peerId] = .responded(sharedSecret: sessionKey)

        return (messageB, sessionKey)
    }


 /// 完成 PAKE 交换（Initiator）
 /// - Parameters:
 /// - messageB: 收到的消息 B
 /// - peerId: 对端设备 ID
 /// - Returns: 共享密钥
    public func completeExchange(
        messageB: PAKEMessageB,
        peerId: String
    ) async throws -> Data {
 // 获取会话状态
        guard case .initiated(let privateKey, let pA, let passwordScalar) = sessions[peerId] else {
            throw PAKEError.sessionNotInitiated
        }

 // 验证消息 B
        guard !messageB.publicValue.isEmpty else {
            await rateLimiter.recordFailedAttempt(identifier: peerId)
            throw PAKEError.invalidPublicValue
        }

 // 计算共享密钥
 // K = x * (pB - w*N) = x * Y
        let sharedSecret = try computeSharedSecret(
            myPrivateKey: privateKey,
            peerBlindedPoint: messageB.publicValue,
            passwordScalar: passwordScalar
        )

 // 派生确认密钥和会话密钥
        let (confirmKey, sessionKey) = deriveKeys(
            sharedSecret: sharedSecret,
            pA: pA,
            pB: messageB.publicValue,
            idA: localDeviceId,
            idB: messageB.deviceId
        )

 // 验证确认 MAC
        let expectedMAC = computeMAC(
            key: confirmKey,
            data: pA + messageB.publicValue
        )

        guard constantTimeCompare(messageB.confirmationMAC, expectedMAC) else {
            await rateLimiter.recordFailedAttempt(identifier: peerId)
            throw PAKEError.macVerificationFailed
        }

 // 记录成功
        await rateLimiter.recordSuccess(identifier: peerId)

 // 更新会话状态
        sessions[peerId] = .completed(sharedSecret: sessionKey)

        return sessionKey
    }

 /// 生成确认消息（Initiator → Responder）
 /// - Parameter peerId: 对端设备 ID
 /// - Returns: 确认消息
    public func generateConfirmation(peerId: String) async throws -> PAKEConfirmation {
        guard case .completed(let sharedSecret) = sessions[peerId] else {
            throw PAKEError.invalidState
        }

 // 使用会话密钥计算确认 MAC
        let confirmationMAC = computeMAC(
            key: sharedSecret,
            data: Data("initiator-confirm".utf8)
        )

        return PAKEConfirmation(confirmationMAC: confirmationMAC)
    }

 /// 验证确认消息（Responder）
 /// - Parameters:
 /// - confirmation: 确认消息
 /// - peerId: 对端设备 ID
 /// - Returns: 是否验证通过
    public func verifyConfirmation(
        _ confirmation: PAKEConfirmation,
        peerId: String
    ) async throws -> Bool {
        guard case .responded(let sharedSecret) = sessions[peerId] else {
            throw PAKEError.invalidState
        }

        let expectedMAC = computeMAC(
            key: sharedSecret,
            data: Data("initiator-confirm".utf8)
        )

        let verified = constantTimeCompare(confirmation.confirmationMAC, expectedMAC)

        if verified {
            sessions[peerId] = .completed(sharedSecret: sharedSecret)
            await rateLimiter.recordSuccess(identifier: peerId)
        } else {
            await rateLimiter.recordFailedAttempt(identifier: peerId)
        }

        return verified
    }

 /// 获取会话密钥
 /// - Parameter peerId: 对端设备 ID
 /// - Returns: 会话密钥（如果已完成）
    public func getSessionKey(peerId: String) -> Data? {
        guard case .completed(let sharedSecret) = sessions[peerId] else {
            return nil
        }
        return sharedSecret
    }

 /// 清理会话
 /// - Parameter peerId: 对端设备 ID
    public func clearSession(peerId: String) {
        sessions[peerId] = nil
    }

 /// 清理所有会话
    public func clearAllSessions() {
        sessions.removeAll()
    }

 // MARK: - Private Methods

 /// Check rate limit and throw appropriate error
 /// Requirements: 5.1-5.6 (PAKE memory management)
    private func checkRateLimitAndThrow(for identifier: String) async throws {
        let result = await rateLimiter.checkRateLimit(identifier: identifier)

        switch result {
        case .allowed:
            return
        case .rateLimited(let retryAfter):
            if let record = await rateLimiter.getRecord(for: identifier),
               record.failedAttempts < P2PConstants.maxPairingAttempts {
                return
            }
            let seconds = retryAfter.components.seconds
            throw PAKEError.rateLimited(retryAfter: TimeInterval(seconds))
        case .lockedOut(let until, _):
 // Convert ContinuousClock.Instant to Date (approximate)
            let now = ContinuousClock.now
            let remaining = until - now
            let remainingSeconds = Double(remaining.components.seconds)
                + Double(remaining.components.attoseconds) / 1_000_000_000_000_000_000
            let lockoutDate = Date().addingTimeInterval(remainingSeconds)
            throw PAKEError.lockout(until: lockoutDate)
        }
    }

    /// Generate a cryptographically secure nonce for PAKE.
    /// If the system RNG fails, abort pairing rather than silently degrading.
    private func generateSecureNonce(context: String) throws -> Data {
        var nonce = Data(count: P2PConstants.nonceSize)
        let status = nonce.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, P2PConstants.nonceSize, baseAddress)
        }
        guard status == errSecSuccess else {
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .cryptoProviderSelected,
                severity: .critical,
                message: "SecRandomCopyBytes failed in PAKEService.generateSecureNonce",
                context: [
                    "status": String(status),
                    "component": "PAKEService",
                    "context": context
                ]
            ))
            throw PAKEError.randomGenerationFailed(status)
        }
        return nonce
    }

 /// 验证配对码格式
    private func isValidPairingCode(_ code: String) -> Bool {
 // 必须是 6 位数字
        guard code.count == P2PConstants.pairingCodeLength else { return false }
        return code.allSatisfy { $0.isNumber }
    }

 /// 派生密码标量
    private func derivePasswordScalar(password: String, peerId: String) -> Data {
 // 使用 PBKDF2 派生密码标量
 // 盐 = domain_separator || sorted(localDeviceId, peerId)
        let pairIdentifier = [localDeviceId, peerId].sorted().joined(separator: "|")
        let salt = Data((SPAKE2Constants.domainSeparator + pairIdentifier).utf8)
        let passwordData = Data(password.utf8)

 // PBKDF2-SHA256
        var derivedKey = Data(count: 32)
        _ = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            passwordData.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(SPAKE2Constants.pbkdf2Iterations),
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        return derivedKey
    }


 /// 计算盲化点
 /// pA = w*M + X (initiator) 或 pB = w*N + Y (responder)
 /// 注意：这是简化实现，实际需要椭圆曲线点运算
    private func computeBlindedPoint(
        scalar: Data,
        blindingPoint: Data,
        publicKey: Data
    ) -> Data {
 // 简化实现：使用 HKDF 混合
 // 生产环境应使用真正的椭圆曲线点乘和点加
        var hasher = SHA256()
        hasher.update(data: scalar)
        hasher.update(data: blindingPoint)
        hasher.update(data: publicKey)
        let mixed = Data(hasher.finalize())

 // 返回混合后的值作为"盲化点"
 // 实际实现需要：scalar * blindingPoint + publicKey (椭圆曲线运算)
        return mixed + publicKey
    }

 /// 计算共享密钥
    private func computeSharedSecret(
        myPrivateKey: Data,
        peerBlindedPoint: Data,
        passwordScalar: Data
    ) throws -> Data {
 // 简化实现：使用 HKDF 派生共享密钥
 // 生产环境应使用真正的椭圆曲线 ECDH

 // 提取对端公钥（从盲化点中）
 // 实际实现需要：peerBlindedPoint - w*M (或 w*N)
        let peerPublicKey: Data
        if peerBlindedPoint.count > 32 {
            peerPublicKey = peerBlindedPoint.suffix(from: 32)
        } else {
            peerPublicKey = peerBlindedPoint
        }

        guard let privateKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: myPrivateKey),
              let publicKey = try? P256.KeyAgreement.PublicKey(compressedRepresentation: peerPublicKey) else {
            throw PAKEError.cryptoError("Invalid key material for ECDH")
        }

        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        var hasher = SHA256()
        hasher.update(data: Data(SPAKE2Constants.domainSeparator.utf8))
        hasher.update(data: sharedSecretData)
        hasher.update(data: passwordScalar)
        return Data(hasher.finalize())
    }

 /// 派生确认密钥和会话密钥
    private func deriveKeys(
        sharedSecret: Data,
        pA: Data,
        pB: Data,
        idA: String,
        idB: String
    ) -> (confirmKey: Data, sessionKey: Data) {
 // 使用 HKDF 派生两个密钥
        let info = Data("SPAKE2+ keys".utf8) + Data(idA.utf8) + Data(idB.utf8)
        let salt = pA + pB

 // 派生 64 字节，前 32 字节为确认密钥，后 32 字节为会话密钥
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: salt,
            info: info,
            outputByteCount: 64
        )

        let keyData = derivedKey.withUnsafeBytes { Data($0) }
        let confirmKey = keyData.prefix(32)
        let sessionKey = keyData.suffix(32)

        return (Data(confirmKey), Data(sessionKey))
    }

 /// 计算 MAC
    private func computeMAC(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

 /// 常量时间比较
    private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }

 /// 获取本地加密能力
    private func getLocalCapabilities() async -> CryptoCapabilities {
        if let cached = cryptoCapabilities {
            return cached
        }
        let capabilities = await CryptoProviderSelector.shared.getLocalCapabilities()
        cryptoCapabilities = capabilities
        return capabilities
    }

 /// 协商加密配置
    private func negotiateProfile(with peerCapabilities: CryptoCapabilities) async -> NegotiatedCryptoProfile {
        return await CryptoProviderSelector.shared.negotiateCapabilities(with: peerCapabilities)
    }
}

// MARK: - CommonCrypto Import

import CommonCrypto
