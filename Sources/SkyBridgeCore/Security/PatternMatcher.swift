//
// PatternMatcher.swift
// SkyBridgeCore
//
// 模式匹配引擎 - 用于恶意软件签名检测
// 支持 hex/string/regex 模式匹配，带 DoS 防护
//

import Foundation
import OSLog
import CryptoKit

// MARK: - SignaturePattern

/// 签名模式类型
public enum SignaturePatternType: String, Codable, Sendable {
    case hex       // 十六进制字节序列（默认启用）
    case string    // 字符串（默认启用）
    case regex     // 正则表达式（仅 Deep 模式，有 DoS 风险）
}

/// 签名模式
public struct SignaturePattern: Codable, Sendable, Equatable {
    public let type: SignaturePatternType
    public let value: String
    public let offset: Int?  // nil = anywhere
    
    public init(type: SignaturePatternType, value: String, offset: Int? = nil) {
        self.type = type
        self.value = value
        self.offset = offset
    }
}

// MARK: - MalwareSignature

/// 恶意软件签名
public struct MalwareSignature: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let category: String  // "malware", "pup", "suspicious"
    public let patterns: [SignaturePattern]
    public let severity: Int  // 1-10
    
    public init(id: String, name: String, category: String, patterns: [SignaturePattern], severity: Int) {
        self.id = id
        self.name = name
        self.category = category
        self.patterns = patterns
        self.severity = severity
    }
}

// MARK: - SignatureDatabase

/// 签名数据库（可更新 + 可验证）
public struct SignatureDatabase: Codable, Sendable {
    public let version: Int              // 单调递增，防降级
    public let lastUpdated: Date
    public let signatures: [MalwareSignature]
    public let signatureData: Data?      // Ed25519 签名（验证完整性）
    
    public init(version: Int, lastUpdated: Date, signatures: [MalwareSignature], signatureData: Data? = nil) {
        self.version = version
        self.lastUpdated = lastUpdated
        self.signatures = signatures
        self.signatureData = signatureData
    }
    
 /// 内置默认签名库（包含 EICAR 测试文件和常见模式）
    public static let bundled: SignatureDatabase = {
        let signatures: [MalwareSignature] = [
 // EICAR 测试文件 - 标准防病毒测试签名
            MalwareSignature(
                id: "eicar-test-file",
                name: "EICAR-Test-File",
                category: "test",
                patterns: [
                    SignaturePattern(
                        type: .string,
                        value: "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*",
                        offset: 0
                    )
                ],
                severity: 1
            ),
 // EICAR 变体（hex 模式）
            MalwareSignature(
                id: "eicar-test-hex",
                name: "EICAR-Test-Hex",
                category: "test",
                patterns: [
                    SignaturePattern(
                        type: .hex,
                        value: "5835 4F21 5025 4041 505B 345C 505A 5835 3428 505E 2937 4343 2937 7D24 4549 4341 522D 5354 414E 4441 5244",
                        offset: nil
                    )
                ],
                severity: 1
            ),
 // 可疑 PowerShell 下载器模式
            MalwareSignature(
                id: "ps-downloader-1",
                name: "Suspicious-PowerShell-Downloader",
                category: "suspicious",
                patterns: [
                    SignaturePattern(
                        type: .string,
                        value: "IEX(New-Object Net.WebClient).DownloadString",
                        offset: nil
                    )
                ],
                severity: 7
            ),
 // 可疑 Base64 编码执行
            MalwareSignature(
                id: "ps-encoded-cmd",
                name: "Suspicious-Encoded-Command",
                category: "suspicious",
                patterns: [
                    SignaturePattern(
                        type: .string,
                        value: "-EncodedCommand",
                        offset: nil
                    )
                ],
                severity: 5
            ),
 // macOS 恶意软件常见模式 - 隐藏启动项
            MalwareSignature(
                id: "macos-hidden-launchd",
                name: "Suspicious-Hidden-LaunchAgent",
                category: "suspicious",
                patterns: [
                    SignaturePattern(
                        type: .string,
                        value: "~/Library/LaunchAgents/.",
                        offset: nil
                    )
                ],
                severity: 6
            )
        ]
        
        return SignatureDatabase(
            version: 1,
            lastUpdated: Date(),
            signatures: signatures,
            signatureData: nil
        )
    }()
}


// MARK: - SignatureDatabaseLoader

/// 签名数据库加载器（带安全验证）
public actor SignatureDatabaseLoader {
    
 /// 内置 Ed25519 公钥（用于验证签名库更新）
 /// 注意：生产环境应使用真实密钥
    private static let publicKeyBase64 = "MCowBQYDK2VwAyEAZGV2ZWxvcG1lbnQta2V5LW5vdC1mb3ItcHJvZHVjdGlvbg=="
    
    private let logger = Logger(subsystem: "com.skybridge.security", category: "SignatureDB")
    
 /// 当前加载的数据库版本
    private var currentVersion: Int = 0
    
 /// 从 JSON 数据加载签名库（带签名验证）
    public func load(from data: Data, verifySignature: Bool = true) throws -> SignatureDatabase {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let database = try decoder.decode(SignatureDatabase.self, from: data)
        
 // 回滚保护：拒绝 version < 当前版本
        guard database.version >= currentVersion else {
            logger.warning("⚠️ 拒绝加载旧版本签名库: v\(database.version) < v\(self.currentVersion)")
            throw SignatureDatabaseError.rollbackAttempt(
                currentVersion: currentVersion,
                attemptedVersion: database.version
            )
        }
        
 // 签名验证（如果启用且有签名数据）
        if verifySignature, let signatureData = database.signatureData {
            let isValid = try verifyDatabaseSignature(data: data, signature: signatureData)
            guard isValid else {
                logger.error("❌ 签名库签名验证失败")
                throw SignatureDatabaseError.invalidSignature
            }
        }
        
 // 更新当前版本
        currentVersion = database.version
        logger.info("✅ 加载签名库 v\(database.version)，包含 \(database.signatures.count) 个签名")
        
        return database
    }
    
 /// 验证签名库的 Ed25519 签名
    private func verifyDatabaseSignature(data: Data, signature: Data) throws -> Bool {
 // 移除签名字段后的数据用于验证
 // 简化实现：生产环境应使用规范化的签名验证流程
        
        guard let publicKeyData = Data(base64Encoded: Self.publicKeyBase64) else {
            throw SignatureDatabaseError.invalidPublicKey
        }
        
 // 使用 CryptoKit 验证 Ed25519 签名
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData.suffix(32))
            return publicKey.isValidSignature(signature, for: data)
        } catch {
            logger.error("❌ 签名验证错误: \(error.localizedDescription)")
            return false
        }
    }
    
 /// 获取当前版本
    public func getCurrentVersion() -> Int {
        currentVersion
    }
    
 /// 重置版本（仅用于测试）
    internal func resetVersion() {
        currentVersion = 0
    }
}

// MARK: - SignatureDatabaseError

/// 签名数据库错误
public enum SignatureDatabaseError: Error, Sendable {
    case rollbackAttempt(currentVersion: Int, attemptedVersion: Int)
    case invalidSignature
    case invalidPublicKey
    case loadFailed(underlying: Error)
}

// MARK: - PatternMatcherError

/// PatternMatcher errors
/// Requirements: 7.1-7.6 (Key verification errors)
public enum PatternMatcherError: Error, Sendable {
 /// Key verification failed (Requirements: 7.2, 7.5)
    case keyVerificationFailed(SignatureDBKeyVerificationResult)
 /// PatternMatcher not ready (key verification not passed)
    case notReady
}

// MARK: - PatternMatchResult

/// 模式匹配结果
public struct PatternMatchResult: Sendable {
    public let matchedPatterns: [MatchedPattern]
    public let patternsChecked: Int
    public let bytesScanned: Int64
    public let samplingStrategy: SamplingStrategy
    
    public init(
        matchedPatterns: [MatchedPattern],
        patternsChecked: Int,
        bytesScanned: Int64,
        samplingStrategy: SamplingStrategy = .full
    ) {
        self.matchedPatterns = matchedPatterns
        self.patternsChecked = patternsChecked
        self.bytesScanned = bytesScanned
        self.samplingStrategy = samplingStrategy
    }
    
 /// 是否有匹配
    public var hasMatches: Bool { !matchedPatterns.isEmpty }
}

/// 匹配的模式
public struct MatchedPattern: Sendable {
    public let signatureId: String
    public let name: String
    public let category: String
    public let offset: Int64
    public let confidence: Double
    public let matchType: SignaturePatternType
    public let region: ThreatHit.ScanRegion
    
    public init(
        signatureId: String,
        name: String,
        category: String,
        offset: Int64,
        confidence: Double,
        matchType: SignaturePatternType,
        region: ThreatHit.ScanRegion
    ) {
        self.signatureId = signatureId
        self.name = name
        self.category = category
        self.offset = offset
        self.confidence = confidence
        self.matchType = matchType
        self.region = region
    }
}


// MARK: - PatternMatcher Actor

/// 模式匹配引擎（带 DoS 防护）
/// Requirements: 2.1-2.10 (Regex ReDoS protection)
public actor PatternMatcher {
    
    private let logger = Logger(subsystem: "com.skybridge.security", category: "PatternMatcher")
    
 /// 内置签名数据库
    private var signatureDatabase: SignatureDatabase
    
 /// 数据库加载器
    private let databaseLoader: SignatureDatabaseLoader
    
 /// Regex validator for pattern security validation (Requirements: 2.2-2.8)
    private let regexValidator: RegexValidator
    
 /// Security limits configuration
    private let securityLimits: SecurityLimits
    
 /// Set of validated regex pattern IDs (patterns that passed validation)
    private var validatedRegexPatternIds: Set<String> = []
    
 /// Set of rejected regex pattern IDs (patterns that failed validation)
    private var rejectedRegexPatternIds: Set<String> = []
    
 // MARK: - DoS 防护常量
    
 /// 正则表达式输入长度上限（1MB）
    private static let regexInputLimit: Int = 1 * 1024 * 1024
    
 /// 正则表达式数量上限
    private static let regexCountLimit: Int = 100
    
 /// 正则表达式最大长度
    private static let regexMaxLength: Int = 500
    
 /// 正则表达式执行超时（秒）
    private static let regexTimeoutSeconds: TimeInterval = 2.0
    
 /// 大文件阈值（100MB）
    private static let largeFileThreshold: Int64 = 100 * 1024 * 1024
    
 /// 大文件头部扫描大小（10MB）
    private static let largeFileHeadSize: Int = 10 * 1024 * 1024
    
 /// 大文件尾部扫描大小（1MB）
    private static let largeFileTailSize: Int = 1 * 1024 * 1024
    
 /// ReDoS 危险模式检测（静态分析）
 /// 检测可能导致灾难性回溯的模式：
 /// - 嵌套量词：(a+)+, (a*)+, (a?)+, (a+)*, etc.
 /// - 重叠交替：(a|a)+, (.*|.+)+
 /// - 过度回溯：.*.*, .+.+
    private static let redosPatterns: [String] = [
        #"\([^)]*[+*][^)]*\)[+*]"#,     // 嵌套量词 (x+)+, (x*)*
        #"\(\.\*\)[+*]"#,                // (.*)+, (.*)*
        #"\(\.\+\)[+*]"#,                // (.+)+, (.+)*
        #"\.\*\.\*"#,                    // .*.*
        #"\.\+\.\+"#,                    // .+.+
        #"\([^)]+\|[^)]+\)[+*]{2,}"#,   // (a|b)++ 等
    ]
    
 // MARK: - Initialization
    
 /// Whether the PatternMatcher is ready to use (key verification passed)
    private var isReady: Bool = false
    
 /// Key verification result
    private var keyVerificationResult: SignatureDBKeyVerificationResult = .invalid
    
    public init(database: SignatureDatabase = .bundled, limits: SecurityLimits = .default) {
        self.signatureDatabase = database
        self.databaseLoader = SignatureDatabaseLoader()
        self.securityLimits = limits
        self.regexValidator = RegexValidator(limits: limits)
        
 // Verify signature database key on initialization (Requirements: 7.1-7.6)
        let (canStart, result) = SignatureDBKeyManager.verifyForPatternMatcher(database: database)
        self.isReady = canStart
        self.keyVerificationResult = result
        
        if !canStart {
            logger.error("❌ PatternMatcher 初始化失败: 签名库密钥验证未通过 (\(String(describing: result)))")
        } else {
            logger.info("✅ PatternMatcher 初始化成功: 签名库密钥验证通过")
        }
    }
    
 /// Check if PatternMatcher is ready to use
 /// Returns false if key verification failed (Requirements: 7.2)
    public func isPatternMatcherReady() -> Bool {
        isReady
    }
    
 /// Get the key verification result
    public func getKeyVerificationResult() -> SignatureDBKeyVerificationResult {
        keyVerificationResult
    }
    
 // MARK: - Public Methods
    
 /// 扫描文件内容
 /// - Parameters:
 /// - url: 文件 URL
 /// - maxBytes: 最大扫描字节数（nil = 无限制，但大文件会自动采样）
 /// - enableRegex: 是否启用正则匹配（仅 Deep 模式，有 DoS 风险）
 /// - Returns: 模式匹配结果
 /// - Note: Returns empty result if PatternMatcher is not ready (key verification failed)
    public func scan(
        at url: URL,
        maxBytes: Int? = nil,
        enableRegex: Bool = false
    ) async -> PatternMatchResult {
 // Check if PatternMatcher is ready (Requirement 7.2: refuse to start on dev key in Release)
        guard isReady else {
            logger.warning("⚠️ PatternMatcher 未就绪，跳过扫描: \(url.lastPathComponent)")
            return PatternMatchResult(matchedPatterns: [], patternsChecked: 0, bytesScanned: 0)
        }
        
        let startTime = Date()
        
 // 获取文件大小
        guard let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else {
            logger.warning("⚠️ 无法获取文件大小: \(url.lastPathComponent)")
            return PatternMatchResult(matchedPatterns: [], patternsChecked: 0, bytesScanned: 0)
        }
        
 // 确定采样策略
        let strategy = determineSamplingStrategy(fileSize: fileSize, maxBytes: maxBytes)
        
 // 读取文件数据
        let (data, bytesScanned, region) = await readFileData(at: url, fileSize: fileSize, strategy: strategy)
        
        guard !data.isEmpty else {
            logger.warning("⚠️ 无法读取文件数据: \(url.lastPathComponent)")
            return PatternMatchResult(matchedPatterns: [], patternsChecked: 0, bytesScanned: 0, samplingStrategy: strategy)
        }
        
 // 执行模式匹配
        let matches = await performPatternMatching(
            data: data,
            enableRegex: enableRegex,
            region: region
        )
        
        let duration = Date().timeIntervalSince(startTime)
        logger.info("🔍 模式匹配完成: \(url.lastPathComponent), 检查 \(self.signatureDatabase.signatures.count) 个签名, 扫描 \(bytesScanned) 字节, 耗时 \(String(format: "%.2f", duration * 1000))ms")
        
        return PatternMatchResult(
            matchedPatterns: matches,
            patternsChecked: signatureDatabase.signatures.count,
            bytesScanned: bytesScanned,
            samplingStrategy: strategy
        )
    }
    
 /// 重新加载签名数据库
 /// Requirements: 2.1-2.10 (Regex validation on database load)
 /// Requirements: 7.1-7.6 (Key verification on database load)
    public func reloadDatabase(from data: Data, verifySignature: Bool = true) async throws {
        let newDatabase = try await databaseLoader.load(from: data, verifySignature: verifySignature)
        
 // Verify signature database key (Requirements: 7.1-7.6)
        let (canStart, result) = SignatureDBKeyManager.verifyForPatternMatcher(
            database: newDatabase,
            databaseContent: data
        )
        
        if !canStart {
            logger.error("❌ 签名库密钥验证失败: \(String(describing: result))")
            isReady = false
            keyVerificationResult = result
            throw PatternMatcherError.keyVerificationFailed(result)
        }
        
        isReady = true
        keyVerificationResult = result
        
 // Validate regex patterns on load (Requirements: 2.2-2.8)
        await validateRegexPatterns(in: newDatabase)
        
        signatureDatabase = newDatabase
        logger.info("✅ 签名数据库已重新加载: v\(newDatabase.version), 有效正则: \(self.validatedRegexPatternIds.count), 拒绝正则: \(self.rejectedRegexPatternIds.count)")
    }
    
 /// Validate all regex patterns in the database
 /// Requirements: 2.2-2.8
    private func validateRegexPatterns(in database: SignatureDatabase) async {
        validatedRegexPatternIds.removeAll()
        rejectedRegexPatternIds.removeAll()
        
        var regexCount = 0
        
        for signature in database.signatures {
            for pattern in signature.patterns {
                guard pattern.type == .regex else { continue }
                
 // Check pattern count limit (Requirement 2.6)
                regexCount += 1
                if regexCount > self.securityLimits.maxRegexPatternCount {
                    logger.warning("⚠️ 正则模式数量超限: \(regexCount) > \(self.securityLimits.maxRegexPatternCount), 跳过: \(signature.id)")
                    rejectedRegexPatternIds.insert(signature.id)
                    
 // Emit security event
                    await SecurityEventEmitter.shared.emit(
                        SecurityEvent.regexPatternRejected(
                            patternId: signature.id,
                            reason: "pattern_count_exceeded"
                        )
                    )
                    continue
                }
                
 // Validate pattern using RegexValidator (Requirements: 2.3-2.5, 2.7-2.8)
                let validationResult = await regexValidator.validateAndEmit(
                    pattern: pattern.value,
                    patternId: signature.id
                )
                
                if validationResult.isValid {
                    validatedRegexPatternIds.insert(signature.id)
                    logger.debug("✅ 正则模式验证通过: \(signature.id)")
                } else {
                    rejectedRegexPatternIds.insert(signature.id)
                    logger.warning("⚠️ 正则模式验证失败: \(signature.id), 原因: \(validationResult.rejectionReason?.rawValue ?? "unknown")")
 // Security event already emitted by validateAndEmit
                }
            }
        }
    }
    
 /// Check if a regex pattern is validated and safe to use
 /// - Parameter signatureId: The signature ID to check
 /// - Returns: true if the pattern passed validation
    public func isRegexPatternValidated(_ signatureId: String) -> Bool {
        validatedRegexPatternIds.contains(signatureId)
    }
    
 /// Get count of rejected regex patterns
    public func getRejectedRegexPatternCount() -> Int {
        rejectedRegexPatternIds.count
    }
    
 /// 获取当前签名数量
    public func getSignatureCount() -> Int {
        signatureDatabase.signatures.count
    }
    
 /// 获取当前数据库版本
    public func getDatabaseVersion() -> Int {
        signatureDatabase.version
    }
    
 // MARK: - Private Methods
    
 /// 确定采样策略
    private func determineSamplingStrategy(fileSize: Int64, maxBytes: Int?) -> SamplingStrategy {
 // 如果指定了 maxBytes 且小于文件大小，使用头尾采样
        if let maxBytes = maxBytes, Int64(maxBytes) < fileSize {
            let headSize = min(maxBytes * 9 / 10, Self.largeFileHeadSize)  // 90% 给头部
            let tailSize = min(maxBytes / 10, Self.largeFileTailSize)       // 10% 给尾部
            return .headTail(headBytes: headSize, tailBytes: tailSize)
        }
        
 // 大文件自动使用头尾采样
        if fileSize > Self.largeFileThreshold {
            return .headTail(headBytes: Self.largeFileHeadSize, tailBytes: Self.largeFileTailSize)
        }
        
        return .full
    }
    
 /// 读取文件数据
    private func readFileData(
        at url: URL,
        fileSize: Int64,
        strategy: SamplingStrategy
    ) async -> (Data, Int64, ThreatHit.ScanRegion) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (Data(), 0, .full)
        }
        defer { try? handle.close() }
        
        switch strategy {
        case .full:
            let data = handle.readDataToEndOfFile()
            return (data, Int64(data.count), .full)
            
        case .headTail(let headBytes, let tailBytes):
 // 读取头部
            let headData = handle.readData(ofLength: headBytes)
            
 // 读取尾部
            var tailData = Data()
            if fileSize > Int64(headBytes + tailBytes) {
                try? handle.seek(toOffset: UInt64(fileSize) - UInt64(tailBytes))
                tailData = handle.readData(ofLength: tailBytes)
            }
            
 // 合并数据（用于匹配）
            var combinedData = headData
            combinedData.append(tailData)
            
            let bytesScanned = Int64(headData.count + tailData.count)
            return (combinedData, bytesScanned, .head)  // 标记为 head，因为主要扫描头部
            
        case .strided(let windowSize, let step):
 // 跨步采样：每隔 step 字节读取 windowSize 字节
 // 确保 step >= windowSize 以避免重叠读取
            let effectiveStep = max(step, windowSize)
            let maxSampledBytes = Self.largeFileHeadSize + Self.largeFileTailSize  // 11MB 上限
            
 // 计算预期采样次数
            let expectedSamples = (Int(fileSize) + effectiveStep - 1) / effectiveStep
            let estimatedBytes = expectedSamples * windowSize
            
 // 如果预估采样量超过上限，动态调整步长
            let adjustedStep: Int
            if estimatedBytes > maxSampledBytes {
 // 反推需要的步长：maxSampledBytes = (fileSize / adjustedStep) * windowSize
                adjustedStep = max(effectiveStep, Int(fileSize) * windowSize / maxSampledBytes)
            } else {
                adjustedStep = effectiveStep
            }
            
            var sampledData = Data()
            sampledData.reserveCapacity(min(estimatedBytes, maxSampledBytes))
            var offset: UInt64 = 0
            
            while offset < UInt64(fileSize) && sampledData.count < maxSampledBytes {
                try? handle.seek(toOffset: offset)
                let bytesToRead = min(windowSize, Int(UInt64(fileSize) - offset))
                let chunk = handle.readData(ofLength: bytesToRead)
                if chunk.isEmpty { break }
                sampledData.append(chunk)
                offset += UInt64(adjustedStep)
            }
            
 // 确保尾部也被采样（如果最后一个窗口未覆盖尾部）
            let lastSampledEnd = offset - UInt64(adjustedStep) + UInt64(windowSize)
            if lastSampledEnd < UInt64(fileSize) && sampledData.count < maxSampledBytes {
                let tailOffset = max(0, UInt64(fileSize) - UInt64(windowSize))
                if tailOffset > lastSampledEnd {
                    try? handle.seek(toOffset: tailOffset)
                    let tailChunk = handle.readData(ofLength: windowSize)
                    sampledData.append(tailChunk)
                }
            }
            
            return (sampledData, Int64(sampledData.count), .full)
        }
    }
    
 /// 执行模式匹配
 /// Requirements: 2.1-2.10 (Regex patterns disabled by default, validated patterns only)
    private func performPatternMatching(
        data: Data,
        enableRegex: Bool,
        region: ThreatHit.ScanRegion
    ) async -> [MatchedPattern] {
        var matches: [MatchedPattern] = []
        var regexCount = 0
        
        for signature in signatureDatabase.signatures {
            for pattern in signature.patterns {
 // Skip regex patterns (Requirement 2.1: disabled by default, only hex/string enabled)
                if pattern.type == .regex {
 // Requirement 2.1: Regex disabled by default
                    if !enableRegex {
                        continue
                    }
                    
 // Skip rejected patterns (Requirement 2.7: ignore invalid patterns, not fatal)
                    if rejectedRegexPatternIds.contains(signature.id) {
                        logger.debug("⏭️ 跳过已拒绝的正则模式: \(signature.id)")
                        continue
                    }
                    
 // Check runtime count limit
                    if regexCount >= Self.regexCountLimit {
                        continue
                    }
                    regexCount += 1
                }
                
 // 执行匹配
                if let offset = await matchPattern(pattern: pattern, in: data, enableRegex: enableRegex, signatureId: signature.id) {
                    let match = MatchedPattern(
                        signatureId: signature.id,
                        name: signature.name,
                        category: signature.category,
                        offset: Int64(offset),
                        confidence: Double(signature.severity) / 10.0,
                        matchType: pattern.type,
                        region: region
                    )
                    matches.append(match)
                    
                    logger.warning("🚨 检测到恶意模式: \(signature.name) at offset \(offset)")
                    
 // 找到一个匹配就跳过该签名的其他模式
                    break
                }
            }
        }
        
        return matches
    }
    
 /// 匹配单个模式
 /// - Parameters:
 /// - pattern: The signature pattern to match
 /// - data: The data to search in
 /// - enableRegex: Whether regex matching is enabled
 /// - signatureId: The signature ID (for validation check)
 /// - Returns: Offset of match, or nil if no match
    private func matchPattern(pattern: SignaturePattern, in data: Data, enableRegex: Bool, signatureId: String) async -> Int? {
        switch pattern.type {
        case .hex:
            return matchHexPattern(pattern.value, in: data, at: pattern.offset)
            
        case .string:
            return matchStringPattern(pattern.value, in: data, at: pattern.offset)
            
        case .regex:
            guard enableRegex else { return nil }
 // Double-check pattern is validated (defense in depth)
            guard validatedRegexPatternIds.contains(signatureId) || !rejectedRegexPatternIds.contains(signatureId) else {
                return nil
            }
            return await matchRegexPattern(pattern.value, in: data)
        }
    }
    
 /// 匹配十六进制模式
    private func matchHexPattern(_ hexString: String, in data: Data, at offset: Int?) -> Int? {
 // 移除空格并转换为字节数组
        let cleanHex = hexString.replacingOccurrences(of: " ", with: "")
        guard let patternBytes = hexStringToBytes(cleanHex) else { return nil }
        
        if let offset = offset {
 // 固定偏移匹配
            guard offset >= 0, offset + patternBytes.count <= data.count else { return nil }
            let slice = data[offset..<(offset + patternBytes.count)]
            return slice.elementsEqual(patternBytes) ? offset : nil
        } else {
 // 全文搜索
            return findSubsequence(patternBytes, in: data)
        }
    }
    
 /// 匹配字符串模式
    private func matchStringPattern(_ string: String, in data: Data, at offset: Int?) -> Int? {
        guard let patternData = string.data(using: .utf8) else { return nil }
        let patternBytes = [UInt8](patternData)
        
        if let offset = offset {
 // 固定偏移匹配
            guard offset >= 0, offset + patternBytes.count <= data.count else { return nil }
            let slice = data[offset..<(offset + patternBytes.count)]
            return slice.elementsEqual(patternBytes) ? offset : nil
        } else {
 // 全文搜索
            return findSubsequence(patternBytes, in: data)
        }
    }
    
 /// 匹配正则表达式模式（带 DoS 防护）
 /// 防护措施：
 /// 1. 输入长度限制（1MB）
 /// 2. 正则长度限制（500 字符）
 /// 3. ReDoS 危险模式静态检测
 /// 4. 执行超时保护（2 秒）
    private func matchRegexPattern(_ regexString: String, in data: Data) async -> Int? {
 // DoS 防护 1：正则长度限制
        guard regexString.count <= Self.regexMaxLength else {
            logger.warning("⚠️ 正则表达式过长: \(regexString.count) > \(Self.regexMaxLength)")
            return nil
        }
        
 // DoS 防护 2：ReDoS 危险模式检测
        if isReDoSVulnerable(regexString) {
            logger.warning("⚠️ 检测到 ReDoS 危险模式，跳过: \(regexString.prefix(50))...")
            return nil
        }
        
 // DoS 防护 3：限制输入长度
        let limitedData = data.prefix(Self.regexInputLimit)
        
        guard let string = String(data: limitedData, encoding: .utf8) else { return nil }
        
 // DoS 防护 4：带超时的正则执行
        return await matchRegexWithTimeout(regexString, in: string, timeout: Self.regexTimeoutSeconds)
    }
    
 /// 检测正则表达式是否存在 ReDoS 漏洞
 /// 使用静态分析检测危险模式
    private func isReDoSVulnerable(_ pattern: String) -> Bool {
        for redosPattern in Self.redosPatterns {
            do {
                let detector = try NSRegularExpression(pattern: redosPattern, options: [])
                let range = NSRange(pattern.startIndex..., in: pattern)
                if detector.firstMatch(in: pattern, options: [], range: range) != nil {
                    return true
                }
            } catch {
 // 检测模式本身无效，跳过
                continue
            }
        }
        return false
    }
    
 /// 带超时的正则匹配
 /// 使用线程安全的方式执行正则匹配
    private func matchRegexWithTimeout(_ regexString: String, in string: String, timeout: TimeInterval) async -> Int? {
        enum RegexMatchResult {
            case match(Int?)
            case timeout
        }
        
        let result = await withTaskGroup(of: RegexMatchResult.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let regex = try NSRegularExpression(pattern: regexString, options: [])
                            let range = NSRange(string.startIndex..., in: string)
                            
                            if let match = regex.firstMatch(in: string, options: [], range: range) {
                                continuation.resume(returning: .match(match.range.location))
                            } else {
                                continuation.resume(returning: .match(nil))
                            }
                        } catch {
                            continuation.resume(returning: .match(nil))
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
        
        switch result {
        case .timeout:
            logger.warning("⚠️ 正则表达式执行超时: \(regexString.prefix(50))...")
            return nil
        case .match(let value):
            return value
        }
    }
    
 /// 十六进制字符串转字节数组
    private nonisolated func hexStringToBytes(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        
        while index < hex.endIndex {
            guard let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else { break }
            let byteString = String(hex[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        
        return bytes.isEmpty ? nil : bytes
    }
    
 /// 在数据中查找子序列
    private func findSubsequence(_ pattern: [UInt8], in data: Data) -> Int? {
        guard !pattern.isEmpty, pattern.count <= data.count else { return nil }
        
        let dataBytes = [UInt8](data)
        let patternCount = pattern.count
        let dataCount = dataBytes.count
        
 // 简单的滑动窗口搜索
        for i in 0...(dataCount - patternCount) {
            var found = true
            for j in 0..<patternCount {
                if dataBytes[i + j] != pattern[j] {
                    found = false
                    break
                }
            }
            if found {
                return i
            }
        }
        
        return nil
    }
}
