//
// FileScanService.swift
// SkyBridgeCore
//
// macOS 文件安全扫描服务
// 使用 XProtect 和系统恶意软件检测 API
//

import Foundation
import OSLog
import CryptoKit

// MARK: - FileScanError

/// 文件扫描错误类型
/// 安全策略：失败 ⇒ verdict=unknown (Quick/Standard) 或 warning (Deep)
/// 避免攻击者通过制造错误将恶意文件变"safe"
public enum FileScanError: Error, Sendable, Equatable {
    case fileNotFound(URL)
    case permissionDenied(URL)
    case timeout(URL, TimeInterval)
    case cancelled
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case invalidFileType(URL)
    case resourceExhausted
    case archiveLimitExceeded(reason: String)
    case symlinkDepthExceeded(URL, depth: Int)
    case fileBeingWritten(URL)
    case unknown(String)
    
 /// 错误描述
    public var localizedDescription: String {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .permissionDenied(let url):
            return "Permission denied: \(url.lastPathComponent)"
        case .timeout(let url, let duration):
            return "Scan timeout after \(String(format: "%.1f", duration))s: \(url.lastPathComponent)"
        case .cancelled:
            return "Scan was cancelled"
        case .commandFailed(let command, let exitCode, let stderr):
            return "Command '\(command)' failed with exit code \(exitCode): \(stderr)"
        case .invalidFileType(let url):
            return "Invalid file type: \(url.lastPathComponent)"
        case .resourceExhausted:
            return "System resources exhausted"
        case .archiveLimitExceeded(let reason):
            return "Archive limit exceeded: \(reason)"
        case .symlinkDepthExceeded(let url, let depth):
            return "Symbolic link depth exceeded (\(depth)): \(url.lastPathComponent)"
        case .fileBeingWritten(let url):
            return "File is being written: \(url.lastPathComponent)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
    
 /// 错误代码（用于 ScanWarning）
    public var code: String {
        switch self {
        case .fileNotFound: return "FILE_NOT_FOUND"
        case .permissionDenied: return "PERMISSION_DENIED"
        case .timeout: return "SCAN_TIMEOUT"
        case .cancelled: return "SCAN_CANCELLED"
        case .commandFailed: return "COMMAND_FAILED"
        case .invalidFileType: return "INVALID_FILE_TYPE"
        case .resourceExhausted: return "RESOURCE_EXHAUSTED"
        case .archiveLimitExceeded: return "ARCHIVE_LIMIT_EXCEEDED"
        case .symlinkDepthExceeded: return "SYMLINK_DEPTH_EXCEEDED"
        case .fileBeingWritten: return "FILE_BEING_WRITTEN"
        case .unknown: return "UNKNOWN_ERROR"
        }
    }
    
 /// 错误严重程度
    public var severity: ScanWarning.Severity {
        switch self {
        case .fileNotFound, .permissionDenied, .timeout, .commandFailed:
            return .critical
        case .cancelled, .resourceExhausted:
            return .warning
        case .invalidFileType, .archiveLimitExceeded, .symlinkDepthExceeded, .fileBeingWritten:
            return .warning
        case .unknown:
            return .critical
        }
    }
    
 /// 转换为 ScanWarning
    public func toWarning() -> ScanWarning {
        ScanWarning(code: code, message: localizedDescription, severity: severity)
    }
}

// MARK: - ErrorRecoveryPolicy

/// 错误恢复策略
/// 安全策略：unknown-by-default，避免攻击者通过制造错误将恶意文件变"safe"
public struct ErrorRecoveryPolicy: Sendable {
 /// 根据扫描级别和错误类型确定裁决
 /// - Quick/Standard: 失败 ⇒ verdict=unknown
 /// - Deep: 失败 ⇒ verdict=warning（更严格）
    public static func determineVerdict(
        for error: FileScanError,
        scanLevel: FileScanService.ScanLevel
    ) -> ScanVerdict {
        switch error {
        case .cancelled:
 // 取消不是错误，返回 unknown
            return .unknown
        case .fileNotFound:
 // 文件不存在，返回 unknown
            return .unknown
        case .permissionDenied, .timeout, .commandFailed, .resourceExhausted, .unknown:
 // 这些错误可能被攻击者利用，根据级别返回
            return scanLevel == .deep ? .warning : .unknown
        case .invalidFileType, .archiveLimitExceeded, .symlinkDepthExceeded, .fileBeingWritten:
 // 这些是限制性错误，返回 warning
            return .warning
        }
    }
    
 /// 创建错误恢复结果
    public static func createErrorResult(
        for error: FileScanError,
        fileURL: URL,
        scanId: UUID,
        scanLevel: FileScanService.ScanLevel,
        startTime: Date,
        methodsUsed: Set<ScanMethod> = [.skipped],
        targetType: ScanTargetType = .file
    ) -> FileScanResult {
        let verdict = determineVerdict(for: error, scanLevel: scanLevel)
        let warning = error.toWarning()
        
        return FileScanResult(
            id: scanId,
            fileURL: fileURL,
            scanDuration: Date().timeIntervalSince(startTime),
            timestamp: Date(),
            verdict: verdict,
            methodsUsed: methodsUsed,
            threats: [],
            warnings: [warning],
            scanLevel: scanLevel,
            targetType: targetType
        )
    }
}

// MARK: - ScanVerdict

/// 扫描裁决结果
public enum ScanVerdict: String, Codable, Sendable {
    case safe       // 所有检查通过
    case warning    // 通过但有警告（如未签名）
    case unsafe     // 检测到威胁
    case unknown    // 无法确定（如权限不足）
}

// MARK: - ScanMethod

/// 扫描方法枚举
public enum ScanMethod: String, Codable, Sendable, Hashable {
    case quarantine = "Quarantine"           // xattr 检查
    case gatekeeperAssessment = "Gatekeeper" // spctl 评估
    case codeSignature = "CodeSignature"     // Security.framework API
    case notarization = "Notarization"       // 公证验证
    case patternMatch = "PatternMatch"       // 签名匹配
    case heuristic = "Heuristic"             // 启发式分析
    case archiveScan = "ArchiveScan"         // 归档展开扫描
    case xprotect = "XProtect"               // XProtect 扫描
    case signatureCheck = "SignatureCheck"   // 签名检查（兼容旧版）
    case skipped = "Skipped"
}

// MARK: - ScanTargetType

/// 扫描目标类型
public enum ScanTargetType: String, Codable, Sendable {
    case file       // 普通文件
    case bundle     // .app/.pkg/.plugin/.appex
    case archive    // .zip/.dmg/.tar.gz
    case directory  // 目录
    case machO      // 裸 Mach-O 可执行文件
    case script     // 带 shebang 的脚本
}

// MARK: - ThreatHit

/// 威胁命中详情
public struct ThreatHit: Codable, Sendable, Equatable {
    public let signatureId: String
    public let signatureName: String
    public let category: String           // "malware", "pup", "suspicious"
    public let matchType: MatchType
    public let region: ScanRegion
    public let offset: Int64?             // 流式扫描可选
    public let snippetHash: String        // SHA256 of matched snippet（避免存原始片段）
    public let confidence: Double
    
    public enum MatchType: String, Codable, Sendable {
        case hex
        case string
        case regex
    }
    
    public enum ScanRegion: String, Codable, Sendable {
        case head               // 文件头部
        case tail               // 文件尾部
        case full               // 全文扫描
        case extractedEntry     // 归档内条目
    }
    
    public init(
        signatureId: String,
        signatureName: String,
        category: String,
        matchType: MatchType,
        region: ScanRegion,
        offset: Int64? = nil,
        snippetHash: String,
        confidence: Double
    ) {
        self.signatureId = signatureId
        self.signatureName = signatureName
        self.category = category
        self.matchType = matchType
        self.region = region
        self.offset = offset
        self.snippetHash = snippetHash
        self.confidence = confidence
    }
}

// MARK: - FileScanProgress

/// 文件扫描进度报告结构
public struct FileScanProgress: Sendable {
    public let totalFiles: Int
    public let completedFiles: Int
    public let currentFile: URL?
    public let currentPhase: ScanPhase
    public let overallProgress: Double  // 0.0 - 1.0
    
    public enum ScanPhase: String, Sendable {
        case preparing
        case quarantineCheck
        case xprotectScan
        case codeSignatureVerify
        case notarizationCheck
        case patternMatching
        case heuristicAnalysis
        case completing
    }
    
    public init(
        totalFiles: Int,
        completedFiles: Int,
        currentFile: URL? = nil,
        currentPhase: ScanPhase = .preparing,
        overallProgress: Double = 0.0
    ) {
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.currentFile = currentFile
        self.currentPhase = currentPhase
        self.overallProgress = overallProgress
    }
}

// MARK: - GatekeeperAssessment

/// Gatekeeper 评估结果（是否允许执行/安装）
public enum GatekeeperAssessment: String, Codable, Sendable {
    case allow          // 允许执行
    case deny           // 拒绝执行
    case unknown        // 无法确定
}

// MARK: - NotarizationStatus

/// Notarization 状态（Apple 公证）
public enum NotarizationStatus: String, Codable, Sendable {
    case notarized      // 已公证（≠ 一定安全）
    case notNotarized   // 未公证（≠ 一定恶意，开源/本地编译常见）
    case unknown        // 无法确定
}

// MARK: - CodeSignatureInfo

/// 代码签名信息
public struct CodeSignatureInfo: Codable, Sendable, Equatable {
    public let isSigned: Bool
    public let isValid: Bool
    public let signerIdentity: String?
    public let teamIdentifier: String?
    public let isAdHoc: Bool
    public let trustLevel: TrustLevel
    
    public enum TrustLevel: String, Codable, Sendable {
        case trusted        // Apple 或已知开发者
        case identified     // 已识别开发者
        case adHoc          // 本地签名
        case unsigned       // 未签名
        case invalid        // 签名无效
    }
    
    public init(
        isSigned: Bool,
        isValid: Bool,
        signerIdentity: String? = nil,
        teamIdentifier: String? = nil,
        isAdHoc: Bool = false,
        trustLevel: TrustLevel
    ) {
        self.isSigned = isSigned
        self.isValid = isValid
        self.signerIdentity = signerIdentity
        self.teamIdentifier = teamIdentifier
        self.isAdHoc = isAdHoc
        self.trustLevel = trustLevel
    }
}

// MARK: - ScanWarning

/// 扫描警告
public struct ScanWarning: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let severity: Severity
    
    public enum Severity: String, Codable, Sendable {
        case info
        case warning
        case critical
    }
    
    public init(code: String, message: String, severity: Severity) {
        self.code = code
        self.message = message
        self.severity = severity
    }
}

// MARK: - FileScanResult

/// 文件扫描结果
public struct FileScanResult: Sendable {
    public let id: UUID
    public let fileURL: URL
    public let scanDuration: TimeInterval
    public let timestamp: Date
    
 // 核心裁决（verdict）- 可解释的结论
    public let verdict: ScanVerdict
    public let methodsUsed: Set<ScanMethod>
    public let threats: [ThreatHit]
    public let warnings: [ScanWarning]
    
 // 详细信息
    public let notarizationStatus: NotarizationStatus?
    public let gatekeeperAssessment: GatekeeperAssessment?
    public let codeSignature: CodeSignatureInfo?
    public let patternMatchCount: Int
    public let scanLevel: FileScanService.ScanLevel
    public let targetType: ScanTargetType
    
 // 兼容旧版 API
    public var isSafe: Bool { verdict == .safe || verdict == .warning }
    public var threatName: String? { threats.first?.signatureName }
    public var scanMethod: ScanMethod { methodsUsed.first ?? .skipped }
    
    public init(
        id: UUID = UUID(),
        fileURL: URL,
        scanDuration: TimeInterval = 0,
        timestamp: Date = Date(),
        verdict: ScanVerdict,
        methodsUsed: Set<ScanMethod> = [],
        threats: [ThreatHit] = [],
        warnings: [ScanWarning] = [],
        notarizationStatus: NotarizationStatus? = nil,
        gatekeeperAssessment: GatekeeperAssessment? = nil,
        codeSignature: CodeSignatureInfo? = nil,
        patternMatchCount: Int = 0,
        scanLevel: FileScanService.ScanLevel = .standard,
        targetType: ScanTargetType = .file
    ) {
        self.id = id
        self.fileURL = fileURL
        self.scanDuration = scanDuration
        self.timestamp = timestamp
        self.verdict = verdict
        self.methodsUsed = methodsUsed
        self.threats = threats
        self.warnings = warnings
        self.notarizationStatus = notarizationStatus
        self.gatekeeperAssessment = gatekeeperAssessment
        self.codeSignature = codeSignature
        self.patternMatchCount = patternMatchCount
        self.scanLevel = scanLevel
        self.targetType = targetType
    }
    
 // 兼容旧版初始化器
    public init(fileURL: URL, isSafe: Bool, threatName: String? = nil, scanDuration: TimeInterval = 0, scanMethod: ScanMethod = .skipped) {
        self.id = UUID()
        self.fileURL = fileURL
        self.scanDuration = scanDuration
        self.timestamp = Date()
        self.verdict = isSafe ? .safe : .unsafe
        self.methodsUsed = [scanMethod]
        self.threats = threatName.map { name in
            [ThreatHit(
                signatureId: "legacy-\(name)",
                signatureName: name,
                category: "unknown",
                matchType: .string,
                region: .full,
                snippetHash: "",
                confidence: 1.0
            )]
        } ?? []
        self.warnings = []
        self.notarizationStatus = nil
        self.gatekeeperAssessment = nil
        self.codeSignature = nil
        self.patternMatchCount = 0
        self.scanLevel = .standard
        self.targetType = .file
    }
}

extension FileScanResult: Codable {}

/// 文件扫描服务 - 提供恶意软件检测功能
/// macOS 集成 XProtect 和 Gatekeeper 进行安全扫描
public actor FileScanService {
    
    public static let shared = FileScanService()
    
    private let logger = Logger(subsystem: "com.skybridge.security", category: "FileScan")
    
 // MARK: - Security Hardening Components
    
 /// Batch scan limiter for pre-check, deduplication, and timeout handling
 /// Requirements: 1.1-1.7
    private let batchScanLimiter: BatchScanLimiter
    
 /// Symlink resolver for secure path resolution
 /// Requirements: 6.1-6.8
    private let symlinkResolver: SymlinkResolver
    
 /// Security limits configuration
    private let securityLimits: SecurityLimits
    
 // MARK: - ScanLevel
    
 /// 扫描级别枚举
    public enum ScanLevel: String, Codable, Sendable {
        case quick      // Quarantine + 基础元信息（UTType/大小/哈希）
        case standard   // + Code Signature (Security.framework API) + Gatekeeper Assessment
        case deep       // + Notarization 强校验 + Pattern Matching + 归档展开
    }
    
 // MARK: - ScanConfiguration
    
 /// 扫描配置（含 DoS 防护限制）
    public struct ScanConfiguration: Sendable {
        public let level: ScanLevel
        public let timeout: TimeInterval
        public let maxConcurrentScans: Int
        
 // MARK: - DoS 防护限制
        
 /// 批量扫描最大文件数（防输入规模 DoS）
        public let maxTotalFiles: Int
        
 /// 批量扫描最大总读取字节数（2GB）
        public let maxTotalBytesToRead: Int64
        
 /// 批量扫描最大总时间（秒）
        public let maxTotalScanTime: TimeInterval
        
        public static let `default` = ScanConfiguration(
            level: .standard,
            timeout: 30.0,
            maxConcurrentScans: 4,
            maxTotalFiles: 10_000,
            maxTotalBytesToRead: 2 * 1024 * 1024 * 1024,  // 2GB
            maxTotalScanTime: 300  // 5 分钟
        )
        
        public init(
            level: ScanLevel,
            timeout: TimeInterval = 30.0,
            maxConcurrentScans: Int = 4,
            maxTotalFiles: Int = 10_000,
            maxTotalBytesToRead: Int64 = 2 * 1024 * 1024 * 1024,
            maxTotalScanTime: TimeInterval = 300
        ) {
            self.level = level
            self.timeout = timeout
            self.maxConcurrentScans = maxConcurrentScans
            self.maxTotalFiles = maxTotalFiles
            self.maxTotalBytesToRead = maxTotalBytesToRead
            self.maxTotalScanTime = maxTotalScanTime
        }
    }
    
 /// 已知恶意文件签名（简化实现）
    private let knownMalwareSignatures: [String: String] = [
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*": "EICAR-Test-File",
 // 可扩展更多签名
    ]
    
 /// 可疑文件扩展名
    private let suspiciousExtensions: Set<String> = [
        "exe", "bat", "cmd", "com", "scr", "pif", "vbs", "js", "jar",
        "msi", "dll", "sys", "drv", "cpl", "ocx", "inf", "reg"
    ]
    
    private init() {
        self.securityLimits = .default
        self.batchScanLimiter = BatchScanLimiter(limits: securityLimits)
        self.symlinkResolver = SymlinkResolver(limits: securityLimits)
    }
    
 /// Initialize with custom security limits (for testing)
    internal init(limits: SecurityLimits) {
        self.securityLimits = limits
        self.batchScanLimiter = BatchScanLimiter(limits: limits)
        self.symlinkResolver = SymlinkResolver(limits: limits)
    }
    
 // MARK: - Verifier Instances
    
 /// 代码签名验证器
    private let codeSignatureVerifier = CodeSignatureVerifier()
    
 /// 公证验证器
    private let notarizationVerifier = NotarizationVerifier()
    
 /// 模式匹配器
    private let patternMatcher = PatternMatcher()
    
 // MARK: - Scan Methods
    
 /// 扫描文件（使用配置）
 /// - Parameters:
 /// - url: 文件 URL
 /// - configuration: 扫描配置
 /// - Returns: 扫描结果
    public func scanFile(
        at url: URL,
        configuration: ScanConfiguration = .default
    ) async -> FileScanResult {
        let startTime = Date()
        let scanId = UUID()
        var methodsUsed: Set<ScanMethod> = []
        var warnings: [ScanWarning] = []
        var threats: [ThreatHit] = []
        var codeSignatureInfo: CodeSignatureInfo?
        var notarizationStatus: NotarizationStatus?
        var gatekeeperAssessment: GatekeeperAssessment?
        var patternMatchCount = 0
        
        logger.info("🔍 开始扫描文件: \(url.lastPathComponent) [级别: \(configuration.level.rawValue)]")
        
 // Resolve symbolic links using SymlinkResolver (Requirements: 6.1-6.8)
 // For single file scans, the scan root is the file's parent directory (Requirement 6.6)
        let scanRoot = url.deletingLastPathComponent()
        let resolution = symlinkResolver.resolve(url: url, scanRoot: scanRoot)
        
 // Handle resolution failure (Requirement 6.2: return unknown for resolution failures)
        guard resolution.isSuccess, let resolvedURL = resolution.resolvedURL else {
            if resolution.error == .inaccessible,
               !FileManager.default.fileExists(atPath: url.path) {
                logger.warning("⚠️ 文件不存在: \(url.path)")
                let error = FileScanError.fileNotFound(url)
                return ErrorRecoveryPolicy.createErrorResult(
                    for: error,
                    fileURL: url,
                    scanId: scanId,
                    scanLevel: configuration.level,
                    startTime: startTime
                )
            }

            let errorMessage: String
            let warningCode: String
            
            switch resolution.error {
            case .realpathFailed:
                errorMessage = "Symlink resolution failed"
                warningCode = "SYMLINK_RESOLUTION_FAILED"
            case .outsideScanRoot:
                errorMessage = "Resolved path is outside scan root"
                warningCode = "OUTSIDE_SCAN_ROOT"
            case .depthExceeded:
                errorMessage = "Symlink chain depth exceeded (\(resolution.chainDepth))"
                warningCode = "SYMLINK_DEPTH_EXCEEDED"
            case .circularLink:
                errorMessage = "Circular symlink detected"
                warningCode = "CIRCULAR_SYMLINK"
            case .inaccessible:
                errorMessage = "File is inaccessible"
                warningCode = "INACCESSIBLE"
            case .none:
                errorMessage = "Unknown resolution error"
                warningCode = "UNKNOWN_ERROR"
            }
            
            logger.warning("⚠️ 符号链接解析失败: \(errorMessage)")
            
 // Emit security event for symlink resolution failure (Requirement 6.2)
            await SecurityEventEmitter.shared.emit(
                SecurityEvent.create(
                    type: .symlinkResolutionFailed,
                    message: errorMessage,
                    context: ["url": url.lastPathComponent, "chainDepth": "\(resolution.chainDepth)"]
                )
            )
            
            return FileScanResult(
                id: scanId,
                fileURL: url,
                scanDuration: Date().timeIntervalSince(startTime),
                timestamp: Date(),
                verdict: .unknown,
                methodsUsed: [.skipped],
                threats: [],
                warnings: [ScanWarning(
                    code: warningCode,
                    message: errorMessage,
                    severity: .warning
                )],
                scanLevel: configuration.level,
                targetType: .file
            )
        }
        
        if resolvedURL != url {
            logger.info("🔗 符号链接已解析: \(url.lastPathComponent) -> \(resolvedURL.lastPathComponent) (深度: \(resolution.chainDepth))")
        }
        
 // 使用解析后的 URL 进行后续检查
        let scanURL = resolvedURL
        
 // 检查文件是否存在（使用 unknown-by-default 策略）
        guard FileManager.default.fileExists(atPath: scanURL.path) else {
            logger.warning("⚠️ 文件不存在: \(scanURL.path)")
            let error = FileScanError.fileNotFound(url)
            return ErrorRecoveryPolicy.createErrorResult(
                for: error,
                fileURL: url,
                scanId: scanId,
                scanLevel: configuration.level,
                startTime: startTime
            )
        }
        
 // 检查文件权限（使用 unknown-by-default 策略）
        guard FileManager.default.isReadableFile(atPath: scanURL.path) else {
            logger.warning("⚠️ 无权限读取文件: \(scanURL.path)")
            let error = FileScanError.permissionDenied(url)
            return ErrorRecoveryPolicy.createErrorResult(
                for: error,
                fileURL: url,
                scanId: scanId,
                scanLevel: configuration.level,
                startTime: startTime
            )
        }
        
 // 检查文件是否正在被写入（等待最多 5 秒）
        if let writeCheckResult = await checkFileBeingWritten(at: scanURL, timeout: 5.0) {
            if !writeCheckResult.isReady {
                logger.warning("⚠️ 文件正在被写入: \(scanURL.path)")
                let error = FileScanError.fileBeingWritten(url)
                return ErrorRecoveryPolicy.createErrorResult(
                    for: error,
                    fileURL: url,
                    scanId: scanId,
                    scanLevel: configuration.level,
                    startTime: startTime
                )
            }
        }
        
 // 检测目标类型（使用解析后的 URL）
        let targetType = await notarizationVerifier.detectTargetType(at: scanURL)
        
 // 检查文件扩展名
        let ext = url.pathExtension.lowercased()
        if suspiciousExtensions.contains(ext) {
            logger.warning("⚠️ 检测到可疑文件扩展名: .\(ext)")
            warnings.append(ScanWarning(
                code: "SUSPICIOUS_EXTENSION",
                message: "Suspicious file extension: .\(ext)",
                severity: .warning
            ))
        }
        
 // === Quick 级别：Quarantine + 基础元信息 ===
        
 // 1. 检查 Quarantine 属性（macOS 特有）
        let quarantineResult = await checkQuarantineAttribute(url)
        methodsUsed.insert(.quarantine)
        
        if !quarantineResult.isSafe {
            let duration = Date().timeIntervalSince(startTime)
            return FileScanResult(
                id: scanId,
                fileURL: url,
                scanDuration: duration,
                timestamp: Date(),
                verdict: .unsafe,
                methodsUsed: methodsUsed,
                threats: [ThreatHit(
                    signatureId: "quarantine-blocked",
                    signatureName: quarantineResult.threatName ?? "QuarantinedFile",
                    category: "quarantine",
                    matchType: .string,
                    region: .full,
                    snippetHash: "",
                    confidence: 1.0
                )],
                warnings: warnings,
                scanLevel: configuration.level,
                targetType: targetType
            )
        }
        
 // Quick 级别到此结束
        if configuration.level == .quick {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("✅ Quick 扫描完成: \(url.lastPathComponent) (耗时: \(String(format: "%.2f", duration * 1000))ms)")
            return FileScanResult(
                id: scanId,
                fileURL: url,
                scanDuration: duration,
                timestamp: Date(),
                verdict: warnings.isEmpty ? .safe : .warning,
                methodsUsed: methodsUsed,
                threats: [],
                warnings: warnings,
                scanLevel: configuration.level,
                targetType: targetType
            )
        }
        
 // === Standard 级别：+ Code Signature + Gatekeeper Assessment ===
        
 // 2. 代码签名验证（仅对 Mach-O 和 Bundle）
        if targetType == .machO || targetType == .bundle {
            let signatureResult = await codeSignatureVerifier.verify(at: url)
            methodsUsed.insert(.codeSignature)
            codeSignatureInfo = CodeSignatureInfo(from: signatureResult)
            
            if !signatureResult.isValid && signatureResult.error?.contains("not signed") != true {
                warnings.append(ScanWarning(
                    code: "INVALID_SIGNATURE",
                    message: signatureResult.error ?? "Invalid code signature",
                    severity: .warning
                ))
            } else if signatureResult.error?.contains("not signed") == true {
                warnings.append(ScanWarning(
                    code: "UNSIGNED",
                    message: "File is not code signed",
                    severity: .warning
                ))
            } else if signatureResult.isAdHoc {
                warnings.append(ScanWarning(
                    code: "ADHOC_SIGNATURE",
                    message: "File has ad-hoc signature (reduced trust)",
                    severity: .info
                ))
            }
        }
        
 // 3. Gatekeeper 评估
        if targetType == .machO || targetType == .bundle || targetType == .script {
            let gkResult = await notarizationVerifier.assessGatekeeper(at: url)
            methodsUsed.insert(.gatekeeperAssessment)
            gatekeeperAssessment = gkResult.assessment
            
            if gkResult.assessment == .deny {
                warnings.append(ScanWarning(
                    code: "GATEKEEPER_DENY",
                    message: gkResult.error ?? "Gatekeeper denied execution",
                    severity: .critical
                ))
            }
        }
        
 // Standard 级别到此结束
        if configuration.level == .standard {
            let duration = Date().timeIntervalSince(startTime)
            let verdict = determineVerdict(threats: threats, warnings: warnings, gatekeeperAssessment: gatekeeperAssessment)
            logger.info("✅ Standard 扫描完成: \(url.lastPathComponent) (耗时: \(String(format: "%.2f", duration * 1000))ms)")
            return FileScanResult(
                id: scanId,
                fileURL: url,
                scanDuration: duration,
                timestamp: Date(),
                verdict: verdict,
                methodsUsed: methodsUsed,
                threats: threats,
                warnings: warnings,
                notarizationStatus: notarizationStatus,
                gatekeeperAssessment: gatekeeperAssessment,
                codeSignature: codeSignatureInfo,
                patternMatchCount: patternMatchCount,
                scanLevel: configuration.level,
                targetType: targetType
            )
        }
        
 // === Deep 级别：+ Notarization + PatternMatch + 归档展开 ===
        
 // 4. Notarization 验证（仅对可执行文件）
        if await notarizationVerifier.shouldCheckNotarization(at: url) {
            let notarizationResult = await notarizationVerifier.verify(at: url)
            methodsUsed.insert(.notarization)
            notarizationStatus = notarizationResult.status
            
            if notarizationResult.status == .notNotarized {
                warnings.append(ScanWarning(
                    code: "NOT_NOTARIZED",
                    message: notarizationResult.error ?? "File is not notarized by Apple",
                    severity: .warning
                ))
            }
        }
        
 // 5. 模式匹配（Deep 模式启用正则）
        let patternResult = await patternMatcher.scan(at: url, enableRegex: true)
        methodsUsed.insert(.patternMatch)
        patternMatchCount = patternResult.patternsChecked
        
        if patternResult.hasMatches {
            for match in patternResult.matchedPatterns {
 // 计算 snippet hash
                let snippetHash = SHA256.hash(data: Data(match.name.utf8)).compactMap { String(format: "%02x", $0) }.joined()
                
                threats.append(ThreatHit(
                    signatureId: match.signatureId,
                    signatureName: match.name,
                    category: match.category,
                    matchType: ThreatHit.MatchType(rawValue: match.matchType.rawValue) ?? .string,
                    region: match.region,
                    offset: match.offset,
                    snippetHash: String(snippetHash.prefix(16)),
                    confidence: match.confidence
                ))
            }
        }
        
 // 6. 启发式分析
        let heuristicResult = await performHeuristicAnalysis(url)
        methodsUsed.insert(.heuristic)
        
        if !heuristicResult.isSafe {
            warnings.append(ScanWarning(
                code: "HEURISTIC_WARNING",
                message: heuristicResult.threatName ?? "Suspicious behavior detected",
                severity: .warning
            ))
        }
        
 // 确定最终裁决
        let verdict = determineVerdict(threats: threats, warnings: warnings, gatekeeperAssessment: gatekeeperAssessment)
        
        let duration = Date().timeIntervalSince(startTime)
        logger.info("✅ Deep 扫描完成: \(url.lastPathComponent) [verdict: \(verdict.rawValue)] (耗时: \(String(format: "%.2f", duration * 1000))ms)")
        
        return FileScanResult(
            id: scanId,
            fileURL: url,
            scanDuration: duration,
            timestamp: Date(),
            verdict: verdict,
            methodsUsed: methodsUsed,
            threats: threats,
            warnings: warnings,
            notarizationStatus: notarizationStatus,
            gatekeeperAssessment: gatekeeperAssessment,
            codeSignature: codeSignatureInfo,
            patternMatchCount: patternMatchCount,
            scanLevel: configuration.level,
            targetType: targetType
        )
    }
    
 /// 扫描文件（兼容旧版 API）
 /// - Parameters:
 /// - url: 文件URL
 /// - deepScan: 是否进行深度扫描
 /// - Returns: 扫描结果
    public func scanFile(at url: URL, deepScan: Bool = false) async -> FileScanResult {
        let level: ScanLevel = deepScan ? .deep : .standard
        return await scanFile(at: url, configuration: ScanConfiguration(level: level))
    }
    
 /// 确定扫描裁决
    private func determineVerdict(
        threats: [ThreatHit],
        warnings: [ScanWarning],
        gatekeeperAssessment: GatekeeperAssessment?
    ) -> ScanVerdict {
 // 有威胁 -> unsafe
        if !threats.isEmpty {
            return .unsafe
        }
        
 // Gatekeeper 拒绝 -> warning 或 unsafe
        if gatekeeperAssessment == .deny {
            return .warning
        }
        
 // 有严重警告 -> warning
        if warnings.contains(where: { $0.severity == .critical }) {
            return .warning
        }
        
 // 有普通警告 -> warning
        if warnings.contains(where: { $0.severity == .warning }) {
            return .warning
        }
        
        return .safe
    }
    
 /// 批量扫描文件（兼容旧版 API）
    public func scanFiles(at urls: [URL], deepScan: Bool = false) async -> [FileScanResult] {
        let level: ScanLevel = deepScan ? .deep : .standard
        let config = ScanConfiguration(level: level)
        return await scanFiles(at: urls, configuration: config, progress: nil)
    }
    
 /// 批量扫描文件（带进度报告）
 /// - Parameters:
 /// - urls: 文件 URL 列表
 /// - configuration: 扫描配置
 /// - progress: 进度回调（可选）
 /// - scanRoot: 可选的扫描根目录（用于符号链接边界检查）
 /// - Returns: 扫描结果列表
 /// - Note: 受 DoS 防护限制：maxTotalFiles、maxTotalBytesToRead、maxTotalScanTime
 /// - Requirements: 1.1-1.7 (Batch scan limits), 6.1-6.8 (Symlink security)
    public func scanFiles(
        at urls: [URL],
        configuration: ScanConfiguration = .default,
        progress: (@Sendable (FileScanProgress) -> Void)?,
        scanRoot: URL? = nil
    ) async -> [FileScanResult] {
        let totalFiles = urls.count
        guard totalFiles > 0 else { return [] }
        
        let scanStartTime = Date()
        
 // Report start
        progress?(FileScanProgress(
            totalFiles: totalFiles,
            completedFiles: 0,
            currentFile: urls.first,
            currentPhase: .preparing,
            overallProgress: 0.0
        ))
        
 // MARK: - 1: Pre-check with BatchScanLimiter (Requirements: 1.1, 1.6, 1.7)
 // Performs deduplication by realpath, filters inaccessible files, calculates totals
        let preCheckResult = await batchScanLimiter.preCheck(urls: urls, scanRoot: scanRoot)
        
 // Check if limits exceeded (Requirements: 1.2, 1.3, 1.5)
        if let limitExceeded = preCheckResult.limitExceeded {
            logger.warning("⚠️ 批量扫描限制超出: \(String(describing: limitExceeded))")
            
 // Emit security event
            let (limitType, actual, max) = describeLimitExceededDetails(limitExceeded)
            await SecurityEventEmitter.shared.emit(
                SecurityEvent.limitExceeded(
                    limitType: limitType,
                    actual: actual,
                    max: max,
                    context: ["fileCount": "\(preCheckResult.deduplicatedURLs.count)", "totalBytes": "\(preCheckResult.totalBytes)"]
                )
            )
            
 // Return unknown verdict for all files without scanning (Requirement 1.5)
            return urls.map { url in
                createLimitExceededResult(for: url, limitExceeded: limitExceeded, configuration: configuration)
            }
        }
        
 // Log pre-check stats
        logger.info("📊 预检完成: \(preCheckResult.deduplicatedURLs.count) 去重文件, \(preCheckResult.inaccessibleCount) 不可访问, \(preCheckResult.duplicateCount) 重复")
        
 // MARK: - 2: Scan deduplicated files with timeout (Requirements: 1.4, 1.6)
        let effectiveURLs = preCheckResult.deduplicatedURLs
        let effectiveTotalFiles = effectiveURLs.count
        
 // Use actor to safely collect results and track progress
        let collector = ScanResultCollector(
            totalFiles: effectiveTotalFiles,
            maxTotalBytes: configuration.maxTotalBytesToRead,
            maxTotalTime: configuration.maxTotalScanTime,
            startTime: scanStartTime
        )
        
 // Track scan results by canonical path for merging
        let scanResultsCollector = ScanResultsByPathCollector()
        
 // Limit concurrent scans
        let maxConcurrent = configuration.maxConcurrentScans
        
 // Create timeout for global timeout (Requirement 1.4)
        let globalTimeout = min(configuration.maxTotalScanTime, securityLimits.globalTimeout)
        
        do {
            try await batchScanLimiter.createTimeoutTask(timeout: globalTimeout) {
                await withTaskGroup(of: Void.self) { group in
                    var pendingURLs = effectiveURLs.makeIterator()
                    var activeCount = 0
                    var shouldStop = false
                    
 // Start initial batch
                    while activeCount < maxConcurrent, let url = pendingURLs.next() {
                        activeCount += 1
                        group.addTask {
 // DoS protection: check if budget exceeded
                            if await collector.isBudgetExceeded() {
                                return
                            }
                            
 // Report current file
                            let currentCompleted = await collector.getCompletedCount()
                            progress?(FileScanProgress(
                                totalFiles: effectiveTotalFiles,
                                completedFiles: currentCompleted,
                                currentFile: url,
                                currentPhase: .quarantineCheck,
                                overallProgress: Double(currentCompleted) / Double(effectiveTotalFiles)
                            ))
                            
 // Get file size for budget tracking
                            let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                            await collector.trackBytesScanned(fileSize)
                            
 // Execute scan
                            let result = await self.scanFile(at: url, configuration: configuration)
                            
 // Collect result by canonical path
                            await scanResultsCollector.addResult(result, for: url.path)
                            await collector.addResult(result)
                            
 // Report completion
                            let newCompleted = await collector.getCompletedCount()
                            progress?(FileScanProgress(
                                totalFiles: effectiveTotalFiles,
                                completedFiles: newCompleted,
                                currentFile: url,
                                currentPhase: .completing,
                                overallProgress: Double(newCompleted) / Double(effectiveTotalFiles)
                            ))
                        }
                    }
                    
 // Process remaining files
                    for await _ in group {
                        activeCount -= 1
                        
 // DoS protection: check if budget exceeded
                        if await collector.isBudgetExceeded() {
                            if !shouldStop {
                                shouldStop = true
                                if let reason = await collector.getBudgetExceededReason() {
                                    self.logger.warning("⚠️ 批量扫描预算超限，提前终止: \(reason)")
                                }
                            }
                            continue
                        }
                        
                        if let url = pendingURLs.next() {
                            activeCount += 1
                            group.addTask {
                                if await collector.isBudgetExceeded() {
                                    return
                                }
                                
                                let currentCompleted = await collector.getCompletedCount()
                                progress?(FileScanProgress(
                                    totalFiles: effectiveTotalFiles,
                                    completedFiles: currentCompleted,
                                    currentFile: url,
                                    currentPhase: .quarantineCheck,
                                    overallProgress: Double(currentCompleted) / Double(effectiveTotalFiles)
                                ))
                                
                                let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                                await collector.trackBytesScanned(fileSize)
                                
                                let result = await self.scanFile(at: url, configuration: configuration)
                                await scanResultsCollector.addResult(result, for: url.path)
                                await collector.addResult(result)
                                
                                let newCompleted = await collector.getCompletedCount()
                                progress?(FileScanProgress(
                                    totalFiles: effectiveTotalFiles,
                                    completedFiles: newCompleted,
                                    currentFile: url,
                                    currentPhase: .completing,
                                    overallProgress: Double(newCompleted) / Double(effectiveTotalFiles)
                                ))
                            }
                        }
                    }
                }
            }
        } catch let error as BatchScanError {
 // Timeout occurred (Requirement 1.4)
            switch error {
            case .timeout(let elapsed):
                logger.warning("⚠️ 批量扫描全局超时: \(String(format: "%.1f", elapsed))s")
            case .limitExceeded(let limit):
                logger.warning("⚠️ 批量扫描限制超出: \(String(describing: limit))")
            case .cancelled:
                logger.info("ℹ️ 批量扫描已取消")
            }
        } catch {
 // Other errors
            logger.error("❌ 批量扫描错误: \(error.localizedDescription)")
        }
        
 // MARK: - 3: Merge results with pre-check rejected results (Requirement 1.6)
        let scanResults = await scanResultsCollector.getResults()
        let scannedURLs = Set(scanResults.keys)
        let unscannedURLs = Set(effectiveURLs.map { $0.path }).subtracting(scannedURLs)
        
 // Merge results maintaining input order
        let finalResults = await batchScanLimiter.mergeResults(
            preCheck: preCheckResult,
            scanResults: scanResults.reduce(into: [:]) { dict, pair in
                dict[pair.key] = pair.value
            },
            originalURLs: urls,
            unscannedURLs: Set(unscannedURLs.compactMap { URL(fileURLWithPath: $0) })
        )
        
 // Report completion
        let finalCompleted = await collector.getCompletedCount()
        progress?(FileScanProgress(
            totalFiles: totalFiles,
            completedFiles: finalCompleted,
            currentFile: nil,
            currentPhase: .completing,
            overallProgress: 1.0
        ))
        
 // Log statistics
        let totalBytes = await collector.getTotalBytesScanned()
        let elapsed = Date().timeIntervalSince(scanStartTime)
        logger.info("📊 批量扫描完成: \(finalCompleted)/\(effectiveTotalFiles) 文件, \(totalBytes / 1024 / 1024)MB, \(String(format: "%.1f", elapsed))s")
        
        return finalResults
    }
    
 // MARK: - Private Helper Methods for Batch Scan
    
 /// Create a result for limit exceeded scenario
    private func createLimitExceededResult(
        for url: URL,
        limitExceeded: PreCheckResult.LimitExceeded,
        configuration: ScanConfiguration
    ) -> FileScanResult {
        let warningMessage: String
        switch limitExceeded {
        case .fileCount(let actual, let max):
            warningMessage = "Batch scan file count exceeded: \(actual) > \(max)"
        case .totalBytes(let actual, let max):
            warningMessage = "Batch scan total bytes exceeded: \(actual) > \(max)"
        }
        
        return FileScanResult(
            id: UUID(),
            fileURL: url,
            scanDuration: 0,
            timestamp: Date(),
            verdict: .unknown,
            methodsUsed: [.skipped],
            threats: [],
            warnings: [ScanWarning(
                code: "LIMIT_EXCEEDED",
                message: warningMessage,
                severity: .critical
            )],
            scanLevel: configuration.level,
            targetType: .file
        )
    }
    
 /// Describe limit exceeded for logging
    private func describeLimitExceeded(_ limitExceeded: PreCheckResult.LimitExceeded) -> String {
        switch limitExceeded {
        case .fileCount(let actual, let max):
            return "File count \(actual) exceeds limit \(max)"
        case .totalBytes(let actual, let max):
            return "Total bytes \(actual) exceeds limit \(max)"
        }
    }
    
 /// Get limit exceeded details for SecurityEvent
    private func describeLimitExceededDetails(_ limitExceeded: PreCheckResult.LimitExceeded) -> (limitType: String, actual: Int64, max: Int64) {
        switch limitExceeded {
        case .fileCount(let actual, let max):
            return ("fileCount", Int64(actual), Int64(max))
        case .totalBytes(let actual, let max):
            return ("totalBytes", actual, max)
        }
    }
    
 // MARK: - MainActor-Isolated Progress Callbacks
    
 /// 批量扫描文件（带 MainActor 隔离的进度报告）
 /// 确保所有进度回调都在 MainActor 上执行，适合 UI 更新
 /// - Parameters:
 /// - urls: 文件 URL 列表
 /// - configuration: 扫描配置
 /// - progress: MainActor 隔离的进度回调
 /// - Returns: 扫描结果列表
 /// - Note: 此方法保证 progress 回调在 MainActor 上执行，符合 Requirements 6.2
    public func scanFilesWithMainActorProgress(
        at urls: [URL],
        configuration: ScanConfiguration = .default,
        progress: (@MainActor @Sendable (FileScanProgress) -> Void)?
    ) async -> [FileScanResult] {
 // 包装进度回调以确保在 MainActor 上执行
        let wrappedProgress: (@Sendable (FileScanProgress) -> Void)?
        if let mainActorProgress = progress {
            wrappedProgress = { scanProgress in
                Task { @MainActor in
                    mainActorProgress(scanProgress)
                }
            }
        } else {
            wrappedProgress = nil
        }
        
        return await scanFiles(at: urls, configuration: configuration, progress: wrappedProgress)
    }
    
 /// 扫描单个文件并在 MainActor 上报告结果
 /// - Parameters:
 /// - url: 文件 URL
 /// - configuration: 扫描配置
 /// - onComplete: MainActor 隔离的完成回调
 /// - Note: 扫描在后台执行，结果通过 MainActor 回调传递，符合 Requirements 6.1, 6.2
    public func scanFileWithMainActorCallback(
        at url: URL,
        configuration: ScanConfiguration = .default,
        onComplete: @escaping @MainActor @Sendable (FileScanResult) -> Void
    ) {
        Task {
 // 扫描在后台执行（FileScanService 是 actor，不在 MainActor 上）
            let result = await self.scanFile(at: url, configuration: configuration)
            
 // 结果通过 MainActor 回调传递
            await MainActor.run {
                onComplete(result)
            }
        }
    }
    
 /// 验证当前执行上下文不在 MainActor 上
 /// 用于测试和调试，确保扫描操作在后台执行
 /// - Returns: 是否在后台线程执行
 /// - Note: 此方法用于验证 Requirements 6.1 - 扫描操作不应在 MainActor 上执行
    public nonisolated func isExecutingOnBackgroundThread() -> Bool {
 // 在 Swift 并发中，actor 方法默认不在 MainActor 上执行
 // 除非显式标记为 @MainActor
        return !Thread.isMainThread
    }
    
 /// 获取当前活跃扫描数量
    public func getActiveScanCount() -> Int {
        activeScanCount
    }
    
 // MARK: - Scan Cancellation
    
 /// 活跃扫描任务映射
    private var activeScanTasks: [UUID: Task<FileScanResult, Never>] = [:]
    
 /// 当前活跃扫描数量
    private var activeScanCount: Int = 0
    
 /// 取消指定扫描
 /// - Parameter id: 扫描 ID
 /// - Returns: 是否成功取消
    @discardableResult
    public func cancelScan(id: UUID) -> Bool {
        guard let task = activeScanTasks[id] else {
            logger.warning("⚠️ 未找到扫描任务: \(id)")
            return false
        }
        
        task.cancel()
        activeScanTasks.removeValue(forKey: id)
        activeScanCount = max(0, activeScanCount - 1)
        logger.info("🛑 已取消扫描: \(id)")
        return true
    }
    
 /// 取消所有活跃扫描
    public func cancelAllScans() {
        for (id, task) in activeScanTasks {
            task.cancel()
            logger.info("🛑 已取消扫描: \(id)")
        }
        activeScanTasks.removeAll()
        activeScanCount = 0
        logger.info("🛑 已取消所有扫描")
    }
    
 /// 检查扫描是否已取消
    public func isScanCancelled(id: UUID) -> Bool {
        guard let task = activeScanTasks[id] else {
            return true  // 不存在视为已取消
        }
        return task.isCancelled
    }
    
 /// 注册扫描任务
    private func registerScanTask(id: UUID, task: Task<FileScanResult, Never>) {
        activeScanTasks[id] = task
        activeScanCount += 1
    }
    
 /// 注销扫描任务
    private func unregisterScanTask(id: UUID) {
        activeScanTasks.removeValue(forKey: id)
        activeScanCount = max(0, activeScanCount - 1)
    }
    
 /// 扫描文件（带取消支持）
 /// - Parameters:
 /// - url: 文件 URL
 /// - configuration: 扫描配置
 /// - scanId: 可选的扫描 ID（用于取消）
 /// - Returns: 扫描结果
    public func scanFileWithCancellation(
        at url: URL,
        configuration: ScanConfiguration = .default,
        scanId: UUID = UUID()
    ) async -> FileScanResult {
 // 创建可取消的任务
        let task = Task<FileScanResult, Never> {
 // 检查是否已取消
            if Task.isCancelled {
                return createCancelledResult(for: url, scanId: scanId, configuration: configuration)
            }
            
            return await scanFile(at: url, configuration: configuration)
        }
        
 // 注册任务
        registerScanTask(id: scanId, task: task)
        
 // 等待结果
        let result = await task.value
        
 // 注销任务
        unregisterScanTask(id: scanId)
        
        return result
    }
    
 /// 创建取消结果
    private func createCancelledResult(
        for url: URL,
        scanId: UUID,
        configuration: ScanConfiguration
    ) -> FileScanResult {
        FileScanResult(
            id: scanId,
            fileURL: url,
            scanDuration: 0,
            timestamp: Date(),
            verdict: .unknown,
            methodsUsed: [.skipped],
            threats: [],
            warnings: [ScanWarning(
                code: "SCAN_CANCELLED",
                message: "Scan was cancelled",
                severity: .info
            )],
            scanLevel: configuration.level,
            targetType: .file
        )
    }
    
 // MARK: - 私有方法
    
 /// 检查 Quarantine 扩展属性
    private func checkQuarantineAttribute(_ url: URL) async -> (isSafe: Bool, threatName: String?) {
 // 读取 com.apple.quarantine 扩展属性
        let quarantineKey = "com.apple.quarantine"
        
        var attrSize = getxattr(url.path, quarantineKey, nil, 0, 0, XATTR_NOFOLLOW)
        if attrSize > 0 {
            var buffer = [CChar](repeating: 0, count: attrSize + 1)
            attrSize = getxattr(url.path, quarantineKey, &buffer, attrSize, 0, XATTR_NOFOLLOW)
            
            if attrSize > 0 {
 // Swift 6.2.1 最佳实践：使用 String(decoding:as:) 替代已弃用的 String(cString:)
                let truncatedBuffer = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                let quarantineValue = String(decoding: truncatedBuffer, as: UTF8.self)
                logger.debug("📋 Quarantine 属性: \(quarantineValue)")
                
 // 检查是否被标记为恶意
 // 格式: flags;timestamp;agent;UUID
                let components = quarantineValue.components(separatedBy: ";")
                if let flags = components.first, let flagValue = UInt32(flags, radix: 16) {
 // 0x0040 = kLSQuarantineTypeExecutable
 // 0x0100 = kLSQuarantineTypeOther (可能有风险)
                    if flagValue & 0x0100 != 0 {
                        return (false, "QuarantinedFile")
                    }
                }
            }
        }
        
        return (true, nil)
    }
    
 /// 检查已知恶意软件签名
    private func checkMalwareSignatures(_ url: URL) async -> (isSafe: Bool, threatName: String?) {
        do {
 // 读取文件头部（前 1KB）
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            
            let headerData = handle.readData(ofLength: 1024)
            
 // 转换为字符串检查
            if let headerString = String(data: headerData, encoding: .utf8) {
                for (signature, threatName) in knownMalwareSignatures {
                    if headerString.contains(signature) {
                        logger.warning("🚨 检测到恶意软件签名: \(threatName)")
                        return (false, threatName)
                    }
                }
            }
            
 // 检查可执行文件头
            if headerData.count >= 4 {
                let magicBytes = headerData.prefix(4)
                
 // MZ 头（Windows 可执行文件）
                if magicBytes.starts(with: [0x4D, 0x5A]) {
                    logger.warning("⚠️ 检测到 Windows 可执行文件")
 // 不自动标记为恶意，但记录
                }
                
 // ELF 头（Linux 可执行文件）
                if magicBytes.starts(with: [0x7F, 0x45, 0x4C, 0x46]) {
                    logger.warning("⚠️ 检测到 Linux 可执行文件")
                }
            }
            
        } catch {
            logger.error("❌ 读取文件失败: \(error.localizedDescription)")
        }
        
        return (true, nil)
    }
    
 /// 触发 XProtect 扫描
    private func triggerXProtectScan(_ url: URL) async -> (isSafe: Bool, threatName: String?) {
 // macOS 会在文件首次打开时自动触发 XProtect 扫描
 // 这里我们通过设置 quarantine 属性来触发扫描
        
 // 检查 XProtect 是否阻止了该文件
 // 通过尝试获取文件的 LSQuarantine 信息
        let resourceValues = try? url.resourceValues(forKeys: [.quarantinePropertiesKey])
        
        if let quarantineProps = resourceValues?.quarantineProperties {
            logger.debug("📋 Quarantine 属性: \(quarantineProps)")
            
 // 检查是否有恶意软件标记
            if let type = quarantineProps["LSQuarantineType"] as? String,
               type == "LSQuarantineTypeMalware" {
                return (false, "XProtectBlocked")
            }
        }
        
        return (true, nil)
    }
    
 /// 启发式分析
    private func performHeuristicAnalysis(_ url: URL) async -> (isSafe: Bool, threatName: String?) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            
 // 检查文件大小异常（例如，脚本文件不应该太大）
            if let fileSize = attributes[.size] as? Int64 {
                let ext = url.pathExtension.lowercased()
                
 // 脚本文件超过 10MB 可疑
                if ["js", "vbs", "ps1", "sh", "bat"].contains(ext) && fileSize > 10_000_000 {
                    logger.warning("⚠️ 脚本文件异常大: \(fileSize) bytes")
 // 不自动标记为恶意
                }
            }
            
 // 检查文件权限
            if let permissions = attributes[.posixPermissions] as? Int {
 // 检查是否有执行权限
                if permissions & 0o111 != 0 {
                    logger.debug("📋 文件有执行权限: \(String(permissions, radix: 8))")
                }
            }
            
        } catch {
            logger.error("❌ 读取文件属性失败: \(error.localizedDescription)")
        }
        
        return (true, nil)
    }
    
 /// 移除文件的 Quarantine 属性
    public func removeQuarantine(from url: URL) async throws {
        let quarantineKey = "com.apple.quarantine"
        let result = removexattr(url.path, quarantineKey, XATTR_NOFOLLOW)
        
        if result != 0 {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            if errno != ENOATTR { // 忽略"属性不存在"错误
                throw error
            }
        }
        
        logger.info("🗑️ 已移除 Quarantine 属性: \(url.lastPathComponent)")
    }
    
 // MARK: - Symbolic Link Resolution
    
 /// 解析符号链接
 /// - Parameters:
 /// - url: 文件 URL
 /// - maxDepth: 最大解析深度（防止循环链接）
 /// - Returns: 解析后的目标文件 URL
 /// - Throws: FileScanError.symlinkDepthExceeded 如果超过最大深度
    public func resolveSymbolicLink(at url: URL, maxDepth: Int = 10) throws -> URL {
        var currentURL = url
        var depth = 0
        var visitedPaths: Set<String> = []
        
        while depth < maxDepth {
 // 检查是否为符号链接
            let resourceValues = try? currentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard resourceValues?.isSymbolicLink == true else {
 // 不是符号链接，返回当前 URL
                return currentURL
            }
            
 // 检查循环链接
            let canonicalPath = currentURL.standardizedFileURL.path
            if visitedPaths.contains(canonicalPath) {
                logger.warning("⚠️ 检测到循环符号链接: \(currentURL.path)")
                throw FileScanError.symlinkDepthExceeded(url, depth: depth)
            }
            visitedPaths.insert(canonicalPath)
            
 // 解析符号链接
            do {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: currentURL.path)
                
 // 处理相对路径
                if destination.hasPrefix("/") {
                    currentURL = URL(fileURLWithPath: destination)
                } else {
                    currentURL = currentURL.deletingLastPathComponent().appendingPathComponent(destination)
                }
                
                depth += 1
            } catch {
                logger.warning("⚠️ 无法解析符号链接: \(error.localizedDescription)")
                throw FileScanError.unknown("Failed to resolve symbolic link: \(error.localizedDescription)")
            }
        }
        
 // 超过最大深度
        logger.warning("⚠️ 符号链接深度超过限制: \(maxDepth)")
        throw FileScanError.symlinkDepthExceeded(url, depth: maxDepth)
    }
    
 /// 检查 URL 是否为符号链接
 /// - Parameter url: 文件 URL
 /// - Returns: 是否为符号链接
    public func isSymbolicLink(at url: URL) -> Bool {
        let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return resourceValues?.isSymbolicLink == true
    }
    
 // MARK: - Error Handling Helpers
    
 /// 检查文件是否正在被写入
 /// - Parameters:
 /// - url: 文件 URL
 /// - timeout: 等待超时时间（秒）
 /// - Returns: 文件是否准备好被扫描
    private func checkFileBeingWritten(at url: URL, timeout: TimeInterval) async -> (isReady: Bool, error: FileScanError?)? {
        let startTime = Date()
        var lastSize: Int64 = -1
        
        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let currentSize = (attrs[.size] as? Int64) ?? 0
                
 // 如果文件大小稳定，认为写入完成
                if currentSize == lastSize && lastSize >= 0 {
                    return (isReady: true, error: nil)
                }
                
                lastSize = currentSize
                
 // 等待 100ms 后再检查
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
 // 无法获取文件属性，可能是权限问题
                return (isReady: false, error: .permissionDenied(url))
            }
        }
        
 // 超时，文件可能仍在写入
        return (isReady: false, error: .fileBeingWritten(url))
    }
    
 /// 检查是否为归档文件
 /// - Parameter url: 文件 URL
 /// - Returns: 是否为归档文件
    public func isArchiveFile(at url: URL) -> Bool {
        let archiveExtensions: Set<String> = ["zip", "dmg", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "pkg"]
        return archiveExtensions.contains(url.pathExtension.lowercased())
    }
    
 /// 检查归档文件的扫描能力
 /// - Parameter url: 归档文件 URL
 /// - Returns: 扫描能力描述
    public func checkArchiveScanCapability(at url: URL) async -> (canFullScan: Bool, reason: String) {
        let ext = url.pathExtension.lowercased()
        
 // 加密归档无法完全扫描
        let encryptedExtensions: Set<String> = ["dmg", "pkg"]
        if encryptedExtensions.contains(ext) {
            return (canFullScan: false, reason: "Encrypted or compressed archive - limited scan capability")
        }
        
 // 检查文件大小
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attrs[.size] as? Int64) ?? 0
            
 // 超过 500MB 的归档只做有限扫描
            if fileSize > 500 * 1024 * 1024 {
                return (canFullScan: false, reason: "Archive too large for full extraction - limited scan")
            }
        } catch {
            return (canFullScan: false, reason: "Cannot determine archive size")
        }
        
        return (canFullScan: true, reason: "")
    }
    
 /// 创建带错误恢复的扫描结果
 /// - Parameters:
 /// - error: 扫描错误
 /// - url: 文件 URL
 /// - configuration: 扫描配置
 /// - startTime: 扫描开始时间
 /// - methodsUsed: 已使用的扫描方法
 /// - targetType: 目标类型
 /// - Returns: 扫描结果
    public func createErrorRecoveryResult(
        for error: FileScanError,
        fileURL url: URL,
        configuration: ScanConfiguration,
        startTime: Date,
        methodsUsed: Set<ScanMethod> = [.skipped],
        targetType: ScanTargetType = .file
    ) -> FileScanResult {
        return ErrorRecoveryPolicy.createErrorResult(
            for: error,
            fileURL: url,
            scanId: UUID(),
            scanLevel: configuration.level,
            startTime: startTime,
            methodsUsed: methodsUsed,
            targetType: targetType
        )
    }
}

// MARK: - ScanTarget

/// 扫描目标抽象（文件、包、归档、目录）
public struct ScanTarget: Sendable {
    public let url: URL
    public let type: ScanTargetType
    public let fileSize: Int64
    public let isExecutable: Bool
    public let hasShebang: Bool
    public let machOType: MachOType?
    
    public enum MachOType: String, Codable, Sendable {
        case executable     // MH_EXECUTE
        case dylib          // MH_DYLIB
        case bundle         // MH_BUNDLE
        case fat            // FAT binary
    }
    
    public init(
        url: URL,
        type: ScanTargetType,
        fileSize: Int64,
        isExecutable: Bool = false,
        hasShebang: Bool = false,
        machOType: MachOType? = nil
    ) {
        self.url = url
        self.type = type
        self.fileSize = fileSize
        self.isExecutable = isExecutable
        self.hasShebang = hasShebang
        self.machOType = machOType
    }
    
 /// 从 URL 检测扫描目标类型
    public static func detect(at url: URL) -> ScanTarget? {
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: url.path) else { return nil }
        
 // 获取文件属性
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let permissions = (attrs[.posixPermissions] as? Int) ?? 0
        let isExecutable = (permissions & 0o111) != 0
        
 // 检测目标类型
        let type = detectTargetType(at: url, isExecutable: isExecutable)
        let machOType = detectMachOType(at: url)
        let hasShebang = checkShebang(at: url)
        
        return ScanTarget(
            url: url,
            type: type,
            fileSize: fileSize,
            isExecutable: isExecutable,
            hasShebang: hasShebang,
            machOType: machOType
        )
    }
    
 /// 检测目标类型
    private static func detectTargetType(at url: URL, isExecutable: Bool) -> ScanTargetType {
        let ext = url.pathExtension.lowercased()
        
 // Bundle 类型
        let bundleExtensions: Set<String> = ["app", "pkg", "plugin", "appex", "framework", "kext"]
        if bundleExtensions.contains(ext) {
            return .bundle
        }
        
 // Archive 类型
        let archiveExtensions: Set<String> = ["zip", "dmg", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]
        if archiveExtensions.contains(ext) {
            return .archive
        }
        
 // 检查是否为目录
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .directory
        }
        
 // 检查 Mach-O
        if detectMachOType(at: url) != nil {
            return .machO
        }
        
 // 检查脚本
        if isExecutable && checkShebang(at: url) {
            return .script
        }
        
        return .file
    }
    
 /// 检测 Mach-O 类型（通过魔数）
    private static func detectMachOType(at url: URL) -> MachOType? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        
        let headerData = handle.readData(ofLength: 4)
        guard headerData.count >= 4 else { return nil }
        
        let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
 // Mach-O 魔数
 // MH_MAGIC_64 = 0xFEEDFACF (little-endian)
 // MH_MAGIC = 0xFEEDFACE (little-endian)
 // FAT_MAGIC = 0xCAFEBABE (big-endian)
 // FAT_MAGIC_64 = 0xCAFEBABF (big-endian)
        
        switch magic {
        case 0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE:
 // 需要进一步读取 filetype 来区分 executable/dylib/bundle
 // 简化实现：默认返回 executable
            return .executable
        case 0xCAFEBABE, 0xCAFEBABF, 0xBEBAFECA, 0xBFBAFECA:
            return .fat
        default:
            return nil
        }
    }
    
 /// 检查是否有 shebang
    private static func checkShebang(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        
        let headerData = handle.readData(ofLength: 2)
        guard headerData.count >= 2 else { return false }
        
 // #! = 0x23 0x21
        return headerData[0] == 0x23 && headerData[1] == 0x21
    }
}

// MARK: - ExtractionPolicy

/// 归档展开策略（防 Zip Bomb）
public struct ExtractionPolicy: Sendable {
    public let maxTotalUncompressedBytes: Int64  // 最大总解压大小
    public let maxEntryCount: Int                // 最大条目数
    public let maxNestedDepth: Int               // 最大嵌套层数
    public let maxSingleEntryBytes: Int64        // 单条目最大大小
    public let allowedTypes: Set<String>         // 允许展开的归档类型
    public let maxCompressionRatio: Double       // 最大压缩比（超过则可疑）
    
    public static let `default` = ExtractionPolicy(
        maxTotalUncompressedBytes: 500 * 1024 * 1024,  // 500MB
        maxEntryCount: 1000,
        maxNestedDepth: 3,
        maxSingleEntryBytes: 100 * 1024 * 1024,       // 100MB
        allowedTypes: ["zip", "tar", "gz"],            // dmg 不展开，风险高
        maxCompressionRatio: 100.0                     // >100:1 可疑
    )
    
    public init(
        maxTotalUncompressedBytes: Int64,
        maxEntryCount: Int,
        maxNestedDepth: Int,
        maxSingleEntryBytes: Int64,
        allowedTypes: Set<String>,
        maxCompressionRatio: Double = 100.0
    ) {
        self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
        self.maxEntryCount = maxEntryCount
        self.maxNestedDepth = maxNestedDepth
        self.maxSingleEntryBytes = maxSingleEntryBytes
        self.allowedTypes = allowedTypes
        self.maxCompressionRatio = maxCompressionRatio
    }
    
 /// 检查是否允许展开指定类型的归档
    public func isAllowed(archiveType: String) -> Bool {
        allowedTypes.contains(archiveType.lowercased())
    }
    
 /// 检查压缩比是否可疑
    public func isSuspiciousRatio(compressedSize: Int64, uncompressedSize: Int64) -> Bool {
        guard compressedSize > 0 else { return true }
        let ratio = Double(uncompressedSize) / Double(compressedSize)
        return ratio > maxCompressionRatio
    }
}

// MARK: - SamplingStrategy

/// 采样策略抽象（便于后续升级）
public enum SamplingStrategy: Sendable {
    case full                                           // 全文扫描
    case headTail(headBytes: Int, tailBytes: Int)       // 头尾采样
    case strided(windowSize: Int, step: Int)            // 跨步采样（每隔 step 字节读取 windowSize 字节）
    
    public static let defaultLargeFile = SamplingStrategy.headTail(
        headBytes: 10 * 1024 * 1024,  // 10MB
        tailBytes: 1 * 1024 * 1024    // 1MB
    )
    
 /// 默认跨步采样策略（64KB 窗口，每 1MB 采样一次，约 6.25% 覆盖率）
    public static let defaultStrided = SamplingStrategy.strided(
        windowSize: 64 * 1024,        // 64KB 窗口
        step: 1024 * 1024             // 1MB 步长
    )
    
 /// 密集跨步采样（64KB 窗口，每 256KB 采样一次，约 25% 覆盖率）
    public static let denseStrided = SamplingStrategy.strided(
        windowSize: 64 * 1024,        // 64KB 窗口
        step: 256 * 1024              // 256KB 步长
    )
    
 /// 大文件阈值（超过此大小使用采样策略）
    public static let largeFileThreshold: Int64 = 100 * 1024 * 1024  // 100MB
    
 /// 计算预估覆盖率（0.0 ~ 1.0）
    public func estimatedCoverage(fileSize: Int64) -> Double {
        switch self {
        case .full:
            return 1.0
        case .headTail(let headBytes, let tailBytes):
            let totalSampled = min(Int64(headBytes + tailBytes), fileSize)
            return fileSize > 0 ? Double(totalSampled) / Double(fileSize) : 1.0
        case .strided(let windowSize, let step):
            guard fileSize > 0, step > 0 else { return 1.0 }
            let effectiveStep = max(step, windowSize)
            let samples = (fileSize + Int64(effectiveStep) - 1) / Int64(effectiveStep)
            let totalSampled = min(samples * Int64(windowSize), fileSize)
            return Double(totalSampled) / Double(fileSize)
        }
    }
}

// MARK: - ScanResultCollector

/// 扫描结果收集器（线程安全，含 DoS 预算追踪）
private actor ScanResultCollector {
    private var results: [FileScanResult] = []
    private let totalFiles: Int
    
 // DoS 预算追踪
    private let maxTotalBytes: Int64
    private let maxTotalTime: TimeInterval
    private let startTime: Date
    private var totalBytesScanned: Int64 = 0
    private var budgetExceeded: Bool = false
    private var budgetExceededReason: String?
    
    init(
        totalFiles: Int,
        maxTotalBytes: Int64 = Int64.max,
        maxTotalTime: TimeInterval = .infinity,
        startTime: Date = Date()
    ) {
        self.totalFiles = totalFiles
        self.maxTotalBytes = maxTotalBytes
        self.maxTotalTime = maxTotalTime
        self.startTime = startTime
    }
    
    func addResult(_ result: FileScanResult) {
        results.append(result)
    }
    
 /// 追踪已扫描字节数
    func trackBytesScanned(_ bytes: Int64) {
        totalBytesScanned += bytes
        if totalBytesScanned > maxTotalBytes && !budgetExceeded {
            budgetExceeded = true
            budgetExceededReason = "总读取字节数超限: \(totalBytesScanned) > \(maxTotalBytes)"
        }
    }
    
 /// 检查是否超时
    func checkTimeoutExceeded() -> Bool {
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed > maxTotalTime && !budgetExceeded {
            budgetExceeded = true
            budgetExceededReason = "总扫描时间超限: \(String(format: "%.1f", elapsed))s > \(maxTotalTime)s"
        }
        return budgetExceeded
    }
    
 /// 检查预算是否已超
    func isBudgetExceeded() -> Bool {
        _ = checkTimeoutExceeded()
        return budgetExceeded
    }
    
 /// 获取预算超限原因
    func getBudgetExceededReason() -> String? {
        budgetExceededReason
    }
    
    func getResults() -> [FileScanResult] {
        results
    }
    
    func getCompletedCount() -> Int {
        results.count
    }
    
    func getTotalBytesScanned() -> Int64 {
        totalBytesScanned
    }
}

// MARK: - ScanResultsByPathCollector

/// Collects scan results indexed by canonical path for merging with pre-check results
private actor ScanResultsByPathCollector {
    private var results: [String: FileScanResult] = [:]
    
    func addResult(_ result: FileScanResult, for path: String) {
        results[path] = result
    }
    
    func getResults() -> [String: FileScanResult] {
        results
    }
    
    func getResult(for path: String) -> FileScanResult? {
        results[path]
    }
}

// MARK: - 通知扩展

public extension Notification.Name {
    static let fileScanCompleted = Notification.Name("com.skybridge.fileScanCompleted")
    static let fileThreatDetected = Notification.Name("com.skybridge.fileThreatDetected")
}
