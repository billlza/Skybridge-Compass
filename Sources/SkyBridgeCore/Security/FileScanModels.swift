// 文件扫描的模型类型。抽取自 Security/FileScanService.swift。
//
// 扫描器**实现**依赖 macOS 专属能力（隔离属性 xattr、SecCode 代码签名校验、Process），
// 因此 `FileScanService` 本体保持 macOS-only；而这些模型是纯数据，共享层（FileTransferManager
// 的安全设置与扫描结果处理）需要它们在所有平台可用。
//
// 刻意不为其它平台提供一个「永远返回不安全」的假扫描器：有接口没实现正是本仓库在
// Docs/background-wake-capability-ledger.md 中记录并已清除的反模式。

import Foundation

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
        scanLevel: FileScanLevel
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
        scanLevel: FileScanLevel,
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
public enum ScanVerdict: String, Codable, Sendable, Equatable {
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
    public let scanLevel: FileScanLevel
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
        scanLevel: FileScanLevel = .standard,
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

// MARK: - Notifications

public extension Notification.Name {
    static let fileScanCompleted = Notification.Name("com.skybridge.fileScanCompleted")
    static let fileThreatDetected = Notification.Name("com.skybridge.fileThreatDetected")
    static let fileScanAdmissionRejected = Notification.Name(
        "com.skybridge.fileScanAdmissionRejected"
    )
}

extension FileScanResult: Codable {}

/// 文件扫描服务 - 提供恶意软件检测功能
/// macOS 集成 XProtect 和 Gatekeeper 进行安全扫描

 /// 扫描级别枚举
public enum FileScanLevel: String, Codable, Sendable {
    case quick      // Quarantine + 基础元信息（UTType/大小/哈希）
    case standard   // + Code Signature (Security.framework API) + Gatekeeper Assessment
    case deep       // + Notarization 强校验 + Pattern Matching + 归档展开
}

 /// 扫描配置（含 DoS 防护限制）
public struct FileScanConfiguration: Sendable {
    public let level: FileScanLevel
    public let timeout: TimeInterval
    public let maxConcurrentScans: Int
    
 // MARK: - DoS 防护限制
    
 /// 批量扫描最大文件数（防输入规模 DoS）
    public let maxTotalFiles: Int
    
 /// 批量扫描最大总读取字节数（2GB）
    public let maxTotalBytesToRead: Int64
    
 /// 批量扫描最大总时间（秒）
    public let maxTotalScanTime: TimeInterval
    
    public static let `default` = FileScanConfiguration(
        level: .standard,
        timeout: 30.0,
        maxConcurrentScans: 4,
        maxTotalFiles: 10_000,
        maxTotalBytesToRead: 2 * 1024 * 1024 * 1024,  // 2GB
        maxTotalScanTime: 300  // 5 分钟
    )
    
    public init(
        level: FileScanLevel,
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
