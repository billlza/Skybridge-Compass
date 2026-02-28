//
// ScanHistoryStore.swift
// SkyBridgeCore
//
// 扫描历史存储服务
// 负责持久化和管理文件扫描结果历史
//
// Security Hardening Enhancement:
// - Summary/Detail separation for storage optimization
// - Atomic detail file writing with concurrency safety
// - detailHash computation and verification
// - Storage limit enforcement with purge
//

import Foundation
import OSLog
import CryptoKit

// MARK: - ScanHistorySummary

/// Scan history summary (stored in main store)
/// Contains only essential fields for listing and quick access.
/// Requirements: 3.1, 3.2, 3.8
public struct ScanHistorySummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let fileURL: String  // Relative path or hash, not absolute path
    public let verdict: String
    public let methodsUsed: [String]
    public let threatCount: Int
    public let duration: TimeInterval
    public let fileHash: String
    public let timestamp: Date
    public let detailHash: String?  // SHA256 of detail file bytes (NOT re-encoded object)
    public let hasDetails: Bool

    public init(
        id: UUID,
        fileURL: String,
        verdict: String,
        methodsUsed: [String],
        threatCount: Int,
        duration: TimeInterval,
        fileHash: String,
        timestamp: Date,
        detailHash: String?,
        hasDetails: Bool
    ) {
        self.id = id
        self.fileURL = fileURL
        self.verdict = verdict
        self.methodsUsed = methodsUsed
        self.threatCount = threatCount
        self.duration = duration
        self.fileHash = fileHash
        self.timestamp = timestamp
        self.detailHash = detailHash
        self.hasDetails = hasDetails
    }

 /// Create summary from FileScanResult
    public init(from result: FileScanResult, fileHash: String, detailHash: String?, hasDetails: Bool) {
        self.id = result.id
 // Use sanitized path (basename only) for privacy
        self.fileURL = result.fileURL.lastPathComponent
        self.verdict = result.verdict.rawValue
        self.methodsUsed = result.methodsUsed.map { $0.rawValue }
        self.threatCount = result.threats.count
        self.duration = result.scanDuration
        self.fileHash = fileHash
        self.timestamp = result.timestamp
        self.detailHash = detailHash
        self.hasDetails = hasDetails
    }
}

// MARK: - ScanHistoryDetail

/// Scan history detail (stored in separate file)
/// Contains detailed threat information, warnings, and signature data.
/// Requirements: 3.1, 3.2, 3.8
public struct ScanHistoryDetail: Codable, Sendable, Equatable {
    public let id: UUID  // Must match summary id
    public let threats: [EncodedThreat]
    public let warnings: [EncodedWarning]
    public let notarizationStatus: String?
    public let codeSignature: EncodedCodeSignature?

    public init(
        id: UUID,
        threats: [EncodedThreat],
        warnings: [EncodedWarning],
        notarizationStatus: String?,
        codeSignature: EncodedCodeSignature?
    ) {
        self.id = id
        self.threats = threats
        self.warnings = warnings
        self.notarizationStatus = notarizationStatus
        self.codeSignature = codeSignature
    }

 /// Create detail from FileScanResult
    public init(from result: FileScanResult) {
        self.id = result.id
        self.threats = result.threats.map { EncodedThreat(from: $0) }
        self.warnings = result.warnings.map { EncodedWarning(from: $0) }
        self.notarizationStatus = result.notarizationStatus?.rawValue
        self.codeSignature = result.codeSignature.map { EncodedCodeSignature(from: $0) }
    }
}

// MARK: - EncodedCodeSignature

/// Encoded code signature info for persistence
public struct EncodedCodeSignature: Codable, Sendable, Equatable {
    public let isSigned: Bool
    public let isValid: Bool
    public let signerIdentity: String?
    public let teamIdentifier: String?
    public let isAdHoc: Bool
    public let trustLevel: String

    public init(
        isSigned: Bool,
        isValid: Bool,
        signerIdentity: String?,
        teamIdentifier: String?,
        isAdHoc: Bool,
        trustLevel: String
    ) {
        self.isSigned = isSigned
        self.isValid = isValid
        self.signerIdentity = signerIdentity
        self.teamIdentifier = teamIdentifier
        self.isAdHoc = isAdHoc
        self.trustLevel = trustLevel
    }

    public init(from info: CodeSignatureInfo) {
        self.isSigned = info.isSigned
        self.isValid = info.isValid
        self.signerIdentity = info.signerIdentity
        self.teamIdentifier = info.teamIdentifier
        self.isAdHoc = info.isAdHoc
        self.trustLevel = info.trustLevel.rawValue
    }
}

// MARK: - ScanHistoryEntry

/// 扫描历史条目（用于持久化）
public struct ScanHistoryEntry: Codable, Sendable, Equatable {
    public let id: UUID
    public let fileURL: String
    public let fileName: String
    public let fileSize: Int64
    public let scanResult: EncodedScanResult
    public let timestamp: Date

    public init(
        id: UUID,
        fileURL: String,
        fileName: String,
        fileSize: Int64,
        scanResult: EncodedScanResult,
        timestamp: Date
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.scanResult = scanResult
        self.timestamp = timestamp
    }

 /// 从 FileScanResult 创建历史条目
    public init(from result: FileScanResult) {
        self.id = result.id
        self.fileURL = result.fileURL.absoluteString
        self.fileName = result.fileURL.lastPathComponent

 // 获取文件大小
        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: result.fileURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }
        self.fileSize = fileSize

        self.scanResult = EncodedScanResult(from: result)
        self.timestamp = result.timestamp
    }
}

// MARK: - EncodedScanResult

/// 编码后的扫描结果（用于持久化）
public struct EncodedScanResult: Codable, Sendable, Equatable {
    public let verdict: String
    public let isSafe: Bool
    public let threatName: String?
    public let scanDuration: TimeInterval
    public let scanMethods: [String]
    public let warnings: [EncodedWarning]
    public let notarizationStatus: String?
    public let gatekeeperAssessment: String?
    public let codeSignatureValid: Bool?
    public let signerIdentity: String?
    public let patternMatchCount: Int
    public let scanLevel: String
    public let targetType: String
    public let threats: [EncodedThreat]

    public init(
        verdict: String,
        isSafe: Bool,
        threatName: String?,
        scanDuration: TimeInterval,
        scanMethods: [String],
        warnings: [EncodedWarning],
        notarizationStatus: String?,
        gatekeeperAssessment: String?,
        codeSignatureValid: Bool?,
        signerIdentity: String?,
        patternMatchCount: Int,
        scanLevel: String,
        targetType: String,
        threats: [EncodedThreat]
    ) {
        self.verdict = verdict
        self.isSafe = isSafe
        self.threatName = threatName
        self.scanDuration = scanDuration
        self.scanMethods = scanMethods
        self.warnings = warnings
        self.notarizationStatus = notarizationStatus
        self.gatekeeperAssessment = gatekeeperAssessment
        self.codeSignatureValid = codeSignatureValid
        self.signerIdentity = signerIdentity
        self.patternMatchCount = patternMatchCount
        self.scanLevel = scanLevel
        self.targetType = targetType
        self.threats = threats
    }

 /// 从 FileScanResult 创建编码结果
    public init(from result: FileScanResult) {
        self.verdict = result.verdict.rawValue
        self.isSafe = result.isSafe
        self.threatName = result.threatName
        self.scanDuration = result.scanDuration
        self.scanMethods = result.methodsUsed.map { $0.rawValue }
        self.warnings = result.warnings.map { EncodedWarning(from: $0) }
        self.notarizationStatus = result.notarizationStatus?.rawValue
        self.gatekeeperAssessment = result.gatekeeperAssessment?.rawValue
        self.codeSignatureValid = result.codeSignature?.isValid
        self.signerIdentity = result.codeSignature?.signerIdentity
        self.patternMatchCount = result.patternMatchCount
        self.scanLevel = result.scanLevel.rawValue
        self.targetType = result.targetType.rawValue
        self.threats = result.threats.map { EncodedThreat(from: $0) }
    }
}

// MARK: - EncodedWarning

/// 编码后的警告（用于持久化）
public struct EncodedWarning: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let severity: String

    public init(code: String, message: String, severity: String) {
        self.code = code
        self.message = message
        self.severity = severity
    }

    public init(from warning: ScanWarning) {
        self.code = warning.code
        self.message = warning.message
        self.severity = warning.severity.rawValue
    }
}

// MARK: - EncodedThreat

/// 编码后的威胁（用于持久化）
public struct EncodedThreat: Codable, Sendable, Equatable {
    public let signatureId: String
    public let signatureName: String
    public let category: String
    public let matchType: String
    public let region: String
    public let offset: Int64?
    public let snippetHash: String
    public let confidence: Double

    public init(
        signatureId: String,
        signatureName: String,
        category: String,
        matchType: String,
        region: String,
        offset: Int64?,
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

    public init(from threat: ThreatHit) {
        self.signatureId = threat.signatureId
        self.signatureName = threat.signatureName
        self.category = threat.category
        self.matchType = threat.matchType.rawValue
        self.region = threat.region.rawValue
        self.offset = threat.offset
        self.snippetHash = threat.snippetHash
        self.confidence = threat.confidence
    }
}


// MARK: - ScanHistoryStore

/// 扫描历史存储服务
/// 负责持久化和管理文件扫描结果历史
///
/// Security Hardening Enhancement:
/// - Summary/Detail separation: summaries in main store, details in separate files
/// - Atomic detail file writing: write to temp file (.tmp), then rename
/// - detailHash verification: hash actual file bytes, not re-encoded object
/// - Storage limit enforcement: purge oldest entries when exceeding limit
public actor ScanHistoryStore {

 // MARK: - Constants

 /// 历史记录最大数量阈值（超过此值触发清理）
    public static let maxEntryCount = 1000

 /// 历史记录保留天数
    public static let retentionDays = 30

 /// 最大存储大小（5MB，防 DoS 撑爆 UserDefaults）
    public static let maxStorageSizeBytes: Int = 5 * 1024 * 1024

 /// 单条记录最大大小（50KB）
    public static let maxEntrySizeBytes: Int = 50 * 1024

 /// UserDefaults 存储键
    private static let defaultStorageKey = "com.skybridge.scanHistory"

 /// UserDefaults 存储键 for summaries (new format)
    private static let defaultSummariesStorageKey = "com.skybridge.scanHistorySummaries"

 /// Details directory name
    private static let detailsDirectoryName = "ScanDetails"

 // MARK: - Properties

    private let logger = Logger(subsystem: "com.skybridge.security", category: "ScanHistory")

 /// Security limits configuration
    private let limits: SecurityLimits

 /// Storage backend
    private let userDefaults: UserDefaults

 /// Namespaced storage key for legacy entries
    private let storageKey: String

 /// Namespaced storage key for summaries
    private let summariesStorageKey: String

 /// Optional details directory override for testing
    private let detailsDirectoryOverride: URL?

 /// 内存缓存 (legacy entries)
    private var entries: [ScanHistoryEntry] = []

 /// 内存缓存 (new summaries)
    private var summaries: [ScanHistorySummary] = []

 /// 是否已加载
    private var isLoaded = false

 /// Details directory URL
    private var detailsDirectory: URL {
        if let detailsDirectoryOverride {
            return detailsDirectoryOverride
        }

        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let bundleId = Bundle.main.bundleIdentifier ?? "com.skybridge.compass"
        return appSupport.appendingPathComponent(bundleId).appendingPathComponent(Self.detailsDirectoryName)
    }

 /// 共享实例
    public static let shared = ScanHistoryStore()

 // MARK: - Initialization

    public init(
        limits: SecurityLimits = .default,
        userDefaultsSuiteName: String? = nil,
        storageNamespace: String? = nil,
        detailsDirectoryOverride: URL? = nil
    ) {
        self.limits = limits
        if let userDefaultsSuiteName, let suiteDefaults = UserDefaults(suiteName: userDefaultsSuiteName) {
            self.userDefaults = suiteDefaults
        } else {
            self.userDefaults = .standard
        }
        self.detailsDirectoryOverride = detailsDirectoryOverride

        if let storageNamespace, !storageNamespace.isEmpty {
            self.storageKey = "\(Self.defaultStorageKey).\(storageNamespace)"
            self.summariesStorageKey = "\(Self.defaultSummariesStorageKey).\(storageNamespace)"
        } else {
            self.storageKey = Self.defaultStorageKey
            self.summariesStorageKey = Self.defaultSummariesStorageKey
        }
    }

 // MARK: - Public Methods

 /// 保存扫描结果到历史
 /// - Parameter result: 扫描结果
    public func save(_ result: FileScanResult) async {
        await loadIfNeeded()

        let entry = ScanHistoryEntry(from: result)

 // DoS 防护：检查单条记录大小
        if let entrySize = estimateEntrySize(entry), entrySize > Self.maxEntrySizeBytes {
            logger.warning("⚠️ 扫描历史条目过大，跳过保存: \(entrySize) bytes > \(Self.maxEntrySizeBytes)")
            return
        }

 // 检查是否已存在相同 ID 的条目
        if let existingIndex = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[existingIndex] = entry
            logger.debug("📝 更新扫描历史: \(entry.fileName)")
        } else {
            entries.append(entry)
            logger.debug("📝 保存扫描历史: \(entry.fileName)")
        }

 // DoS 防护：检查总大小并清理
        await enforceStorageLimits()

 // 持久化
        await persist()

 // 检查是否需要清理（基于数量和时间）
        await purgeIfNeeded()
    }

 /// 获取历史记录（分页）
 /// - Parameters:
 /// - limit: 每页数量
 /// - offset: 偏移量
 /// - Returns: 历史条目列表
    public func getHistory(limit: Int, offset: Int) async -> [ScanHistoryEntry] {
        await loadIfNeeded()

 // 按时间倒序排列
        let sorted = entries.sorted { $0.timestamp > $1.timestamp }

 // 分页
        let startIndex = min(offset, sorted.count)
        let endIndex = min(offset + limit, sorted.count)

        guard startIndex < endIndex else {
            return []
        }

        return Array(sorted[startIndex..<endIndex])
    }

 /// 获取所有历史记录
 /// - Returns: 所有历史条目
    public func getAllHistory() async -> [ScanHistoryEntry] {
        await loadIfNeeded()
        return entries.sorted { $0.timestamp > $1.timestamp }
    }

 /// 获取历史记录数量
 /// - Returns: 条目数量
    public func getCount() async -> Int {
        await loadIfNeeded()
        return entries.count
    }

 /// 根据 ID 获取历史条目
 /// - Parameter id: 条目 ID
 /// - Returns: 历史条目（如果存在）
    public func getEntry(id: UUID) async -> ScanHistoryEntry? {
        await loadIfNeeded()
        return entries.first { $0.id == id }
    }

 /// 删除指定历史条目
 /// - Parameter id: 条目 ID
 /// - Returns: 是否成功删除
    @discardableResult
    public func deleteEntry(id: UUID) async -> Bool {
        await loadIfNeeded()

        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        entries.remove(at: index)
        await persist()
        logger.debug("🗑️ 删除扫描历史: \(id)")
        return true
    }

 /// 清空所有历史记录
    public func clearAll() async {
        entries.removeAll()
        await persist()
        logger.info("🗑️ 已清空所有扫描历史")
    }

 /// 导出为 JSON
 /// - Returns: JSON 数据
    public func exportJSON() async throws -> Data {
        await loadIfNeeded()

        let sorted = entries.sorted { $0.timestamp > $1.timestamp }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(sorted)
        logger.info("📤 导出扫描历史: \(sorted.count) 条记录")
        return data
    }

 /// 清理旧记录
 /// - Parameter days: 保留天数
    public func purgeOldEntries(olderThan days: Int) async {
        await loadIfNeeded()

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let originalCount = entries.count

        entries.removeAll { $0.timestamp < cutoffDate }

        let removedCount = originalCount - entries.count
        if removedCount > 0 {
            await persist()
            logger.info("🧹 清理旧扫描历史: 删除 \(removedCount) 条记录")
        }
    }

 // MARK: - Enhanced Summary/Detail API (Security Hardening)

 /// Save scan result with summary/detail separation
 /// - Parameter result: The scan result to save
 /// - Requirements: 3.1, 3.2, 3.6, 3.8
    public func saveWithDetails(_ result: FileScanResult) async {
        await loadSummariesIfNeeded()

 // Calculate file hash for the summary
        let fileHash = await calculateFileHash(for: result.fileURL)

 // Determine if we need to store details (has threats or warnings)
        let hasDetails = !result.threats.isEmpty || !result.warnings.isEmpty ||
                         result.codeSignature != nil || result.notarizationStatus != nil

        var detailHash: String? = nil

        if hasDetails {
 // Create detail and write atomically
            let detail = ScanHistoryDetail(from: result)
            do {
                detailHash = try await writeDetailAtomically(detail)
                logger.debug("📝 Detail file written for: \(result.id)")
            } catch {
                logger.error("❌ Failed to write detail file: \(error.localizedDescription)")
 // Continue without detail - summary will have hasDetails=false
            }
        }

 // Create summary
        let summary = ScanHistorySummary(
            from: result,
            fileHash: fileHash,
            detailHash: detailHash,
            hasDetails: detailHash != nil
        )

 // Check if entry already exists
        if let existingIndex = summaries.firstIndex(where: { $0.id == summary.id }) {
 // Delete old detail file if exists
            let oldSummary = summaries[existingIndex]
            if oldSummary.hasDetails {
                await deleteDetailFile(for: oldSummary.id)
            }
            summaries[existingIndex] = summary
            logger.debug("📝 Updated scan history summary: \(summary.fileURL)")
        } else {
            summaries.append(summary)
            logger.debug("📝 Saved scan history summary: \(summary.fileURL)")
        }

 // Enforce storage limits
        await enforceStorageLimitsForSummaries()

 // Persist summaries
        await persistSummaries()
    }

 /// Get history summaries (paginated)
 /// - Parameters:
 /// - limit: Page size
 /// - offset: Offset
 /// - Returns: List of summaries
 /// - Requirements: 3.4
    public func getSummaries(limit: Int, offset: Int) async -> [ScanHistorySummary] {
        await loadSummariesIfNeeded()

 // Sort by timestamp (newest first)
        let sorted = summaries.sorted { $0.timestamp > $1.timestamp }

 // Paginate
        let startIndex = min(offset, sorted.count)
        let endIndex = min(offset + limit, sorted.count)

        guard startIndex < endIndex else {
            return []
        }

        return Array(sorted[startIndex..<endIndex])
    }

 /// Get all summaries
 /// - Returns: All summaries sorted by timestamp (newest first)
    public func getAllSummaries() async -> [ScanHistorySummary] {
        await loadSummariesIfNeeded()
        return summaries.sorted { $0.timestamp > $1.timestamp }
    }

 /// Get summary count
    public func getSummaryCount() async -> Int {
        await loadSummariesIfNeeded()
        return summaries.count
    }

 /// Load detail for a summary
 /// - Parameter id: Summary ID
 /// - Returns: Detail if available and valid, nil otherwise
 /// - Requirements: 3.5, 3.9
    public func loadDetail(for id: UUID) async -> ScanHistoryDetail? {
        await loadSummariesIfNeeded()

 // Find the summary
        guard let summary = summaries.first(where: { $0.id == id }) else {
            logger.warning("⚠️ Summary not found for id: \(id)")
            return nil
        }

 // Check if has details
        guard summary.hasDetails, let expectedHash = summary.detailHash else {
            logger.debug("📂 No details available for: \(id)")
            return nil
        }

 // Verify and load detail
        return await verifyAndLoadDetail(for: id, expectedHash: expectedHash)
    }

 /// Check if detail is available for a summary
 /// - Parameter id: Summary ID
 /// - Returns: True if detail file exists and is valid
    public func isDetailAvailable(for id: UUID) async -> Bool {
        await loadSummariesIfNeeded()

        guard let summary = summaries.first(where: { $0.id == id }),
              summary.hasDetails,
              let expectedHash = summary.detailHash else {
            return false
        }

 // Check if file exists and hash matches
        let detailURL = detailFileURL(for: id)
        guard FileManager.default.fileExists(atPath: detailURL.path) else {
            return false
        }

 // Verify hash
        guard let fileData = try? Data(contentsOf: detailURL) else {
            return false
        }

        let actualHash = computeSHA256(fileData)
        return actualHash == expectedHash
    }

 /// Delete a summary and its detail file
 /// - Parameter id: Summary ID
 /// - Returns: True if deleted
    @discardableResult
    public func deleteSummary(id: UUID) async -> Bool {
        await loadSummariesIfNeeded()

        guard let index = summaries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let summary = summaries[index]

 // Delete detail file if exists
        if summary.hasDetails {
            await deleteDetailFile(for: id)
        }

        summaries.remove(at: index)
        await persistSummaries()
        logger.debug("🗑️ Deleted scan history summary: \(id)")
        return true
    }

 /// Clear all summaries and detail files
    public func clearAllSummaries() async {
        await loadSummariesIfNeeded()

 // Delete all detail files
        for summary in summaries where summary.hasDetails {
            await deleteDetailFile(for: summary.id)
        }

        summaries.removeAll()
        await persistSummaries()

 // Also clean up any orphaned detail files
        await cleanupOrphanedDetailFiles()

        logger.info("🗑️ Cleared all scan history summaries")
    }

 /// Get total storage size (summaries + details)
    public func getTotalStorageSize() async -> Int64 {
        await loadSummariesIfNeeded()

        var totalSize: Int64 = 0

 // Estimate summaries size
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let summariesData = try? encoder.encode(summaries) {
            totalSize += Int64(summariesData.count)
        }

 // Add detail files size
        let fm = FileManager.default
        if fm.fileExists(atPath: detailsDirectory.path) {
            if let enumerator = fm.enumerator(at: detailsDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
                while let fileURL = enumerator.nextObject() as? URL {
 // Skip .tmp files
                    guard !fileURL.lastPathComponent.hasSuffix(".tmp") else { continue }

                    if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                       let size = attrs[.size] as? Int64 {
                        totalSize += size
                    }
                }
            }
        }

        return totalSize
    }

 // MARK: - Private Methods (Summary/Detail)

 /// Load summaries if needed
    private func loadSummariesIfNeeded() async {
        guard !isLoaded else { return }

        await loadSummaries()
        await load() // Also load legacy entries
        isLoaded = true
    }

 /// Load summaries from UserDefaults
    private func loadSummaries() async {
        guard let data = userDefaults.data(forKey: summariesStorageKey) else {
            logger.debug("📂 No summaries data found")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            summaries = try decoder.decode([ScanHistorySummary].self, from: data)
            logger.debug("📂 Loaded \(self.summaries.count) summaries")
        } catch {
            logger.error("❌ Failed to load summaries: \(error.localizedDescription)")
            summaries = []
        }
    }

 /// Persist summaries to UserDefaults
    private func persistSummaries() async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(summaries)
            userDefaults.set(data, forKey: summariesStorageKey)
            logger.debug("💾 Persisted \(self.summaries.count) summaries")
        } catch {
            logger.error("❌ Failed to persist summaries: \(error.localizedDescription)")
        }
    }

 /// Write detail file atomically
 /// - Parameter detail: The detail to write
 /// - Returns: SHA256 hash of the written bytes
 /// - Requirements: 3.2, 3.6, 3.8
 ///
 /// Critical implementation:
 /// 1. Encode detail to JSON Data (this is what will be written to disk)
 /// 2. Compute SHA256 of this Data → this is the detailHash
 /// 3. Write to temp file (.tmp suffix)
 /// 4. Rename to final path
 /// 5. Return detailHash for summary storage
    private func writeDetailAtomically(_ detail: ScanHistoryDetail) async throws -> String {
 // Ensure details directory exists
        try ensureDetailsDirectoryExists()

 // 1. Encode detail to JSON Data
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys] // Consistent ordering
        let jsonData = try encoder.encode(detail)

 // 2. Compute SHA256 of the JSON Data
        let detailHash = computeSHA256(jsonData)

 // 3. Write to temp file
        let finalURL = detailFileURL(for: detail.id)
        let tempURL = finalURL.appendingPathExtension("tmp")

        try jsonData.write(to: tempURL, options: .atomic)

 // 4. Rename to final path
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: tempURL, to: finalURL)

 // 5. Return detailHash
        return detailHash
    }

 /// Verify and load detail file
 /// - Parameters:
 /// - id: Detail ID
 /// - expectedHash: Expected SHA256 hash
 /// - Returns: Detail if valid, nil otherwise
 /// - Requirements: 3.5, 3.9
 ///
 /// Critical implementation:
 /// 1. Read file's raw bytes (don't decode first)
 /// 2. Compute SHA256 of raw bytes
 /// 3. Compare with summary.detailHash
 /// 4. Only decode to ScanHistoryDetail if hash matches
    private func verifyAndLoadDetail(for id: UUID, expectedHash: String) async -> ScanHistoryDetail? {
        let detailURL = detailFileURL(for: id)

 // 1. Read raw bytes
        guard let fileData = try? Data(contentsOf: detailURL) else {
            logger.warning("⚠️ Failed to read detail file for: \(id)")
            return nil
        }

 // 2. Compute SHA256 of raw bytes
        let actualHash = computeSHA256(fileData)

 // 3. Compare hashes
        guard actualHash == expectedHash else {
            logger.warning("⚠️ Detail hash mismatch for \(id): expected \(expectedHash), got \(actualHash)")
 // Emit security event for corrupted detail file
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .detailFileCorrupted,
                severity: .info,
                message: "Detail file hash mismatch",
                context: ["id": id.uuidString, "expected": expectedHash, "actual": actualHash],
                timestamp: Date()
            ))
            return nil
        }

 // 4. Decode to ScanHistoryDetail
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let detail = try decoder.decode(ScanHistoryDetail.self, from: fileData)

 // Verify ID matches
            guard detail.id == id else {
                logger.warning("⚠️ Detail ID mismatch: expected \(id), got \(detail.id)")
                return nil
            }

            return detail
        } catch {
            logger.error("❌ Failed to decode detail file: \(error.localizedDescription)")
            return nil
        }
    }

 /// Delete detail file for a summary
 /// - Parameter id: Summary ID
 /// - Requirements: 3.7
    private func deleteDetailFile(for id: UUID) async {
        let detailURL = detailFileURL(for: id)
        let fm = FileManager.default

        guard fm.fileExists(atPath: detailURL.path) else { return }

        do {
            try fm.removeItem(at: detailURL)
            logger.debug("🗑️ Deleted detail file: \(id)")
        } catch {
            logger.error("❌ Failed to delete detail file: \(error.localizedDescription)")
        }
    }

 /// Get detail file URL for an ID
    private func detailFileURL(for id: UUID) -> URL {
        detailsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

 /// Ensure details directory exists
    private func ensureDetailsDirectoryExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: detailsDirectory.path) {
            try fm.createDirectory(at: detailsDirectory, withIntermediateDirectories: true)
        }
    }

 /// Compute SHA256 hash of data
    private func computeSHA256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

 /// Calculate file hash for a URL
    private func calculateFileHash(for url: URL) async -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "unknown"
        }
        return computeSHA256(data)
    }

 /// Enforce storage limits for summaries
 /// - Requirements: 3.3, 3.7
    private func enforceStorageLimitsForSummaries() async {
        let totalSize = await getTotalStorageSize()

        guard totalSize > limits.maxTotalHistoryBytes else { return }

        logger.warning("⚠️ History storage exceeds limit: \(totalSize) > \(self.limits.maxTotalHistoryBytes)")

 // Sort by timestamp (oldest first)
        summaries.sort { $0.timestamp < $1.timestamp }

        var currentSize = totalSize

 // Remove oldest entries until under limit
        while currentSize > limits.maxTotalHistoryBytes && !summaries.isEmpty {
            let oldest = summaries.removeFirst()

 // Delete detail file if exists and hash matches
            if oldest.hasDetails, let expectedHash = oldest.detailHash {
                let detailURL = detailFileURL(for: oldest.id)
                if let fileData = try? Data(contentsOf: detailURL) {
                    let actualHash = computeSHA256(fileData)
                    if actualHash == expectedHash {
 // Get size before deleting
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: detailURL.path),
                           let size = attrs[.size] as? Int64 {
                            currentSize -= size
                        }
                        await deleteDetailFile(for: oldest.id)
                    }
                }
            }

 // Estimate summary size reduction
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let summaryData = try? encoder.encode(oldest) {
                currentSize -= Int64(summaryData.count)
            }

            logger.debug("🗑️ Purged old summary: \(oldest.fileURL)")
        }

 // Re-sort by timestamp (newest first) for display
        summaries.sort { $0.timestamp > $1.timestamp }
    }

 /// Cleanup orphaned detail files (files without matching summary)
    private func cleanupOrphanedDetailFiles() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: detailsDirectory.path) else { return }

        let summaryIds = Set(summaries.map { $0.id })

        guard let enumerator = fm.enumerator(at: detailsDirectory, includingPropertiesForKeys: nil) else { return }

        while let fileURL = enumerator.nextObject() as? URL {
 // Skip .tmp files (in-progress writes)
            guard !fileURL.lastPathComponent.hasSuffix(".tmp") else { continue }

 // Extract ID from filename
            let filename = fileURL.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: filename) else { continue }

 // Delete if no matching summary
            if !summaryIds.contains(id) {
                try? fm.removeItem(at: fileURL)
                logger.debug("🗑️ Cleaned up orphaned detail file: \(filename)")
            }
        }
    }

 // MARK: - Private Methods (Legacy)

 /// 按需加载历史记录
    private func loadIfNeeded() async {
        guard !isLoaded else { return }

        await load()
        isLoaded = true
    }

 /// 从 UserDefaults 加载历史记录
    private func load() async {
        guard let data = userDefaults.data(forKey: storageKey) else {
            logger.debug("📂 无历史记录数据")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([ScanHistoryEntry].self, from: data)
            logger.debug("📂 加载扫描历史: \(self.entries.count) 条记录")
        } catch {
            logger.error("❌ 加载扫描历史失败: \(error.localizedDescription)")
            entries = []
        }
    }

 /// 持久化到 UserDefaults
    private func persist() async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            userDefaults.set(data, forKey: storageKey)
            logger.debug("💾 持久化扫描历史: \(self.entries.count) 条记录")
        } catch {
            logger.error("❌ 持久化扫描历史失败: \(error.localizedDescription)")
        }
    }

 /// 检查并执行清理（如果需要）
    private func purgeIfNeeded() async {
 // 当条目数超过阈值时，清理超过保留天数的记录
        guard entries.count > Self.maxEntryCount else { return }

        await purgeOldEntries(olderThan: Self.retentionDays)
    }

 /// 强制执行存储大小限制（DoS 防护）
    private func enforceStorageLimits() async {
 // 估算当前总大小
        var totalSize = 0
        for entry in entries {
            totalSize += estimateEntrySize(entry) ?? 0
        }

 // 如果超过限制，按时间顺序删除最旧的记录
        if totalSize > Self.maxStorageSizeBytes {
            logger.warning("⚠️ 扫描历史存储超限: \(totalSize) bytes > \(Self.maxStorageSizeBytes)")

 // 按时间排序，保留最新的
            entries.sort { $0.timestamp > $1.timestamp }

 // 逐个删除最旧的，直到低于限制
            while totalSize > Self.maxStorageSizeBytes && !entries.isEmpty {
                if let removed = entries.popLast() {
                    let removedSize = estimateEntrySize(removed) ?? 0
                    totalSize -= removedSize
                    logger.debug("🗑️ 清理旧记录以释放空间: \(removed.fileName)")
                }
            }
        }
    }

 /// 估算单条记录的序列化大小
    private func estimateEntrySize(_ entry: ScanHistoryEntry) -> Int? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return nil }
        return data.count
    }

 /// 获取当前存储大小（用于监控）
    public func getStorageSize() async -> Int {
        await loadIfNeeded()
        var totalSize = 0
        for entry in entries {
            totalSize += estimateEntrySize(entry) ?? 0
        }
        return totalSize
    }

 // MARK: - Testing Support

 /// 重置存储（仅用于测试）
    internal func reset() async {
        entries.removeAll()
        summaries.removeAll()
        isLoaded = false
        userDefaults.removeObject(forKey: storageKey)
        userDefaults.removeObject(forKey: summariesStorageKey)

 // Clean up detail files
        let fm = FileManager.default
        if fm.fileExists(atPath: detailsDirectory.path) {
            try? fm.removeItem(at: detailsDirectory)
        }
    }

 /// 设置条目（仅用于测试）
    internal func setEntries(_ newEntries: [ScanHistoryEntry]) async {
        entries = newEntries
        isLoaded = true
        await persist()
    }

 /// Set summaries (for testing only)
    internal func setSummaries(_ newSummaries: [ScanHistorySummary]) async {
        summaries = newSummaries
        isLoaded = true
        await persistSummaries()
    }

 /// Get details directory URL (for testing only)
    internal func getDetailsDirectory() -> URL {
        detailsDirectory
    }

 /// Create store with custom limits (for testing)
    public static func createForTesting(limits: SecurityLimits) -> ScanHistoryStore {
        ScanHistoryStore(limits: limits)
    }
}
