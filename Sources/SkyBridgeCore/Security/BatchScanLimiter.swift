// MARK: - BatchScanLimiter.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Batch scan pre-check result with deduplication and limit checking.
///
/// **Output Contract**:
/// - `rejectedResults` maintains input order
/// - Each rejected result has `.verdict = .unknown`
/// - Rejection reasons are distinguishable: `.inaccessible` / `.symlinkResolutionFailed` / `.outsideRoot`
/// - Rejected files don't count toward limits (only `deduplicatedURLs` are counted)
///
/// **Duplicate Handling Strategy**:
/// - Multiple input URLs with same canonical path: only first enters `deduplicatedURLs`
/// - Subsequent duplicates recorded in `duplicateToFirstIndex`
/// - Final result merge: duplicates return same scan result as first occurrence
public struct PreCheckResult: Sendable {
 /// Deduplicated URLs ready for scanning (by canonical path)
    public let deduplicatedURLs: [URL]
    
 /// Total bytes of deduplicated files
    public let totalBytes: Int64
    
 /// Count of inaccessible files
    public let inaccessibleCount: Int
    
 /// Count of duplicate files (same canonical path)
    public let duplicateCount: Int
    
 /// Limit exceeded info (nil if within limits)
    public let limitExceeded: LimitExceeded?
    
 /// Pre-check rejected results (maintains input order).
 /// Includes: realpathFailed / inaccessible / outsideRoot
 /// Note: duplicates don't generate separate results - they map to first occurrence
    public let rejectedResults: [FileScanResult]
    
 /// Input URL index to result mapping (for order preservation).
 /// - key: Input URL index
 /// - value: Corresponding FileScanResult (rejected or duplicate mapping)
    public let inputIndexToResult: [Int: FileScanResult]
    
 /// Duplicate URL to first occurrence index mapping.
 /// - key: Duplicate URL's input index
 /// - value: First occurrence's input index for that canonical path
 /// Used for final result merge: duplicates return same scan result as first
    public let duplicateToFirstIndex: [Int: Int]
    
 /// Canonical path to first input index mapping (internal use)
    internal let canonicalPathToFirstIndex: [String: Int]
    
 /// Limit exceeded types
    public enum LimitExceeded: Sendable, Equatable {
        case fileCount(actual: Int, max: Int)
        case totalBytes(actual: Int64, max: Int64)
    }
    
    public init(
        deduplicatedURLs: [URL],
        totalBytes: Int64,
        inaccessibleCount: Int,
        duplicateCount: Int,
        limitExceeded: LimitExceeded?,
        rejectedResults: [FileScanResult],
        inputIndexToResult: [Int: FileScanResult],
        duplicateToFirstIndex: [Int: Int],
        canonicalPathToFirstIndex: [String: Int]
    ) {
        self.deduplicatedURLs = deduplicatedURLs
        self.totalBytes = totalBytes
        self.inaccessibleCount = inaccessibleCount
        self.duplicateCount = duplicateCount
        self.limitExceeded = limitExceeded
        self.rejectedResults = rejectedResults
        self.inputIndexToResult = inputIndexToResult
        self.duplicateToFirstIndex = duplicateToFirstIndex
        self.canonicalPathToFirstIndex = canonicalPathToFirstIndex
    }
}

/// Batch scan limiter with pre-check, deduplication, and timeout support.
///
/// Key responsibilities:
/// - Pre-check: deduplicate by realpath, filter inaccessible, calculate totals
/// - Limit enforcement: file count, total bytes
/// - Timeout handling: global timeout with partial results
///
/// **Deduplication Strategy**:
/// - Uses SymlinkResolver for canonical path resolution
/// - Same canonical path = same file (only scan once)
/// - Duplicates map to first occurrence's scan result
public actor BatchScanLimiter {
    
 /// Security limits configuration
    private let limits: SecurityLimits
    
 /// Symlink resolver (delegate for path resolution)
    private let symlinkResolver: SymlinkResolver
    
 /// Initialize with security limits
    public init(limits: SecurityLimits = .default) {
        self.limits = limits
        self.symlinkResolver = SymlinkResolver(limits: limits)
    }

    // MARK: - Test Helpers

    /// Create a limiter instance for unit tests with configurable (usually higher) limits.
    ///
    /// Note: kept `internal` so production app targets importing `SkyBridgeCore` cannot call it.
    nonisolated internal static func createForTesting(
        maxTotalFiles: Int = SecurityLimits.default.maxTotalFiles,
        maxTotalBytes: Int64 = SecurityLimits.default.maxTotalBytes,
        maxSymlinkDepth: Int = SecurityLimits.default.maxSymlinkDepth,
        globalTimeout: TimeInterval = SecurityLimits.default.globalTimeout
    ) -> BatchScanLimiter {
        let d = SecurityLimits.default
        let limits = SecurityLimits(
            maxTotalFiles: maxTotalFiles,
            maxTotalBytes: maxTotalBytes,
            globalTimeout: globalTimeout,
            maxRegexPatternLength: d.maxRegexPatternLength,
            maxRegexPatternCount: d.maxRegexPatternCount,
            maxRegexGroups: d.maxRegexGroups,
            maxRegexQuantifiers: d.maxRegexQuantifiers,
            maxRegexAlternations: d.maxRegexAlternations,
            maxRegexLookaheads: d.maxRegexLookaheads,
            perPatternTimeout: d.perPatternTimeout,
            perPatternInputLimit: d.perPatternInputLimit,
            maxTotalHistoryBytes: d.maxTotalHistoryBytes,
            tokenBucketRate: d.tokenBucketRate,
            tokenBucketBurst: d.tokenBucketBurst,
            maxMessageBytes: d.maxMessageBytes,
            decodeDepthLimit: d.decodeDepthLimit,
            decodeArrayLengthLimit: d.decodeArrayLengthLimit,
            decodeStringLengthLimit: d.decodeStringLengthLimit,
            droppedMessagesThreshold: d.droppedMessagesThreshold,
            droppedMessagesWindow: d.droppedMessagesWindow,
            pakeRecordTTL: d.pakeRecordTTL,
            pakeMaxRecords: d.pakeMaxRecords,
            pakeCleanupInterval: d.pakeCleanupInterval,
            maxSymlinkDepth: maxSymlinkDepth,
            maxRetryCount: d.maxRetryCount,
            maxRetryDelay: d.maxRetryDelay,
            maxExtractedFiles: d.maxExtractedFiles,
            maxTotalExtractedBytes: d.maxTotalExtractedBytes,
            maxNestingDepth: d.maxNestingDepth,
            maxCompressionRatio: d.maxCompressionRatio,
            maxExtractionTime: d.maxExtractionTime,
            maxBytesPerFile: d.maxBytesPerFile,
            largeFileThreshold: d.largeFileThreshold,
            hashTimeoutQuick: d.hashTimeoutQuick,
            hashTimeoutStandard: d.hashTimeoutStandard,
            hashTimeoutDeep: d.hashTimeoutDeep,
            maxEventQueueSize: d.maxEventQueueSize,
            maxPendingPerSubscriber: d.maxPendingPerSubscriber
        )
        return BatchScanLimiter(limits: limits)
    }
    
 /// Pre-check batch scan request.
 ///
 /// Performs:
 /// 1. Symlink resolution for each URL (via SymlinkResolver)
 /// 2. Deduplication by canonical path
 /// 3. File count and bytes limit checking
 /// 4. Generation of rejected results for failures
 ///
 /// **Duplicate Processing Strategy**:
 /// - Same canonical path URLs: only first enters deduplicatedURLs
 /// - Subsequent duplicates recorded in duplicateToFirstIndex
 /// - Final result merge:
 /// 1. Scan deduplicatedURLs → [canonicalPath: FileScanResult]
 /// 2. For each input URL:
 /// - If in rejectedResults → use rejected result
 /// - If in duplicateToFirstIndex → use firstIndex's scan result
 /// - Otherwise → use URL's own scan result
 /// 3. This ensures:
 /// - Input order preserved
 /// - Duplicates return same scan result (reference first scan result)
 /// - Each canonical path scanned only once
 ///
 /// - Parameter urls: Input URLs to check
 /// - Returns: PreCheckResult with deduplicated URLs and metadata
    public func preCheck(urls: [URL], scanRoot: URL? = nil) async -> PreCheckResult {
        var deduplicatedURLs: [URL] = []
        var totalBytes: Int64 = 0
        var inaccessibleCount = 0
        var duplicateCount = 0
        var rejectedResults: [FileScanResult] = []
        var inputIndexToResult: [Int: FileScanResult] = [:]
        var duplicateToFirstIndex: [Int: Int] = [:]
        var canonicalPathToFirstIndex: [String: Int] = [:]
        
 // Track canonical paths we've seen
        var seenCanonicalPaths: [String: Int] = [:] // canonical path -> first input index
        
        for (index, url) in urls.enumerated() {
 // Determine scan root for this URL
            let effectiveScanRoot = scanRoot ?? url.deletingLastPathComponent()
            
 // Resolve symlink using SymlinkResolver (the ONLY authority)
            let resolution = symlinkResolver.resolve(url: url, scanRoot: effectiveScanRoot)
            
 // Handle resolution failure
            guard resolution.isSuccess, let resolvedURL = resolution.resolvedURL else {
                let result = createRejectedResult(
                    for: url,
                    error: resolution.error ?? .realpathFailed
                )
                rejectedResults.append(result)
                inputIndexToResult[index] = result
                
                if resolution.error == .inaccessible {
                    inaccessibleCount += 1
                }
                continue
            }
            
            let canonicalPath = resolvedURL.path
            
 // Check for duplicate
            if let firstIndex = seenCanonicalPaths[canonicalPath] {
                duplicateCount += 1
                duplicateToFirstIndex[index] = firstIndex
                continue
            }
            
 // First occurrence of this canonical path
            seenCanonicalPaths[canonicalPath] = index
            canonicalPathToFirstIndex[canonicalPath] = index
            
 // Get file size
            let fileSize = getFileSize(at: resolvedURL)
            totalBytes += fileSize
            
            deduplicatedURLs.append(resolvedURL)
        }
        
 // Check limits (only against deduplicated URLs)
        var limitExceeded: PreCheckResult.LimitExceeded? = nil
        
        if deduplicatedURLs.count > limits.maxTotalFiles {
            limitExceeded = .fileCount(actual: deduplicatedURLs.count, max: limits.maxTotalFiles)
        } else if totalBytes > limits.maxTotalBytes {
            limitExceeded = .totalBytes(actual: totalBytes, max: limits.maxTotalBytes)
        }
        
        return PreCheckResult(
            deduplicatedURLs: deduplicatedURLs,
            totalBytes: totalBytes,
            inaccessibleCount: inaccessibleCount,
            duplicateCount: duplicateCount,
            limitExceeded: limitExceeded,
            rejectedResults: rejectedResults,
            inputIndexToResult: inputIndexToResult,
            duplicateToFirstIndex: duplicateToFirstIndex,
            canonicalPathToFirstIndex: canonicalPathToFirstIndex
        )
    }
    
 /// Create a timeout wrapper.
 ///
 /// - Parameters:
 /// - timeout: Timeout duration in seconds
 /// - operation: The async operation to execute
 /// - Returns: Operation result
 /// - Throws: TimeoutError if operation exceeds timeout
    public func createTimeoutTask<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
 // Add the main operation
            group.addTask {
                try await operation()
            }
            
 // Add timeout
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BatchScanError.timeout(elapsed: timeout)
            }
            
 // Return first completed result
            guard let result = try await group.next() else {
                throw BatchScanError.timeout(elapsed: timeout)
            }
            
 // Cancel remaining tasks
            group.cancelAll()
            
            return result
        }
    }
    
 /// Merge scan results with pre-check results to maintain input order.
 ///
 /// - Parameters:
 /// - preCheck: The pre-check result
 /// - scanResults: Map of canonical path to scan result
 /// - originalURLs: Original input URLs (for order)
 /// - unscannedURLs: URLs that weren't scanned (timeout)
 /// - Returns: Final results in input order
    public func mergeResults(
        preCheck: PreCheckResult,
        scanResults: [String: FileScanResult],
        originalURLs: [URL],
        unscannedURLs: Set<URL> = []
    ) -> [FileScanResult] {
        var finalResults: [FileScanResult] = []
        
        for (index, url) in originalURLs.enumerated() {
 // Check if this URL was rejected during pre-check
            if let rejectedResult = preCheck.inputIndexToResult[index] {
                finalResults.append(rejectedResult)
                continue
            }
            
 // Check if this URL is a duplicate
            if let firstIndex = preCheck.duplicateToFirstIndex[index] {
 // Find the first URL's canonical path and use its result
                let firstURL = originalURLs[firstIndex]
                let resolution = symlinkResolver.resolve(url: firstURL)
                if let canonicalPath = resolution.resolvedURL?.path,
                   let result = scanResults[canonicalPath] {
 // Create a copy with the original URL
                    let duplicateResult = FileScanResult(
                        id: UUID(),
                        fileURL: url,
                        scanDuration: result.scanDuration,
                        timestamp: result.timestamp,
                        verdict: result.verdict,
                        methodsUsed: result.methodsUsed,
                        threats: result.threats,
                        warnings: result.warnings,
                        notarizationStatus: result.notarizationStatus,
                        gatekeeperAssessment: result.gatekeeperAssessment,
                        codeSignature: result.codeSignature,
                        patternMatchCount: result.patternMatchCount,
                        scanLevel: result.scanLevel,
                        targetType: result.targetType
                    )
                    finalResults.append(duplicateResult)
                } else {
 // Fallback: create unknown result
                    finalResults.append(createUnknownResult(for: url, reason: "duplicate_resolution_failed"))
                }
                continue
            }
            
 // This URL should have been scanned
            let resolution = symlinkResolver.resolve(url: url)
            if let resolvedURL = resolution.resolvedURL,
               let canonicalPath = Optional(resolvedURL.path) {
                if let result = scanResults[canonicalPath] {
                    finalResults.append(result)
                } else if unscannedURLs.contains(resolvedURL) {
 // URL wasn't scanned due to timeout (check resolved URL)
                    finalResults.append(createTimeoutResult(for: url))
                } else {
 // Unexpected: URL should have result
                    finalResults.append(createUnknownResult(for: url, reason: "missing_scan_result"))
                }
            } else {
 // Resolution failed (shouldn't happen if pre-check passed)
                finalResults.append(createUnknownResult(for: url, reason: "resolution_failed"))
            }
        }
        
        return finalResults
    }
    
 // MARK: - Private Methods
    
 /// Create a rejected FileScanResult for pre-check failures.
    private func createRejectedResult(
        for url: URL,
        error: SymlinkResolutionResult.ResolutionError
    ) -> FileScanResult {
        let warningCode: String
        let warningMessage: String
        
        switch error {
        case .inaccessible:
            warningCode = "INACCESSIBLE"
            warningMessage = "File is inaccessible"
        case .realpathFailed:
            warningCode = "SYMLINK_RESOLUTION_FAILED"
            warningMessage = "Symlink resolution failed"
        case .outsideScanRoot:
            warningCode = "OUTSIDE_SCAN_ROOT"
            warningMessage = "Resolved path is outside scan root"
        case .depthExceeded:
            warningCode = "SYMLINK_DEPTH_EXCEEDED"
            warningMessage = "Symlink chain depth exceeded limit"
        case .circularLink:
            warningCode = "CIRCULAR_SYMLINK"
            warningMessage = "Circular symlink detected"
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
                code: warningCode,
                message: warningMessage,
                severity: .warning
            )],
            scanLevel: .quick,
            targetType: .file
        )
    }
    
 /// Create an unknown result for unexpected failures.
    private func createUnknownResult(for url: URL, reason: String) -> FileScanResult {
        FileScanResult(
            id: UUID(),
            fileURL: url,
            scanDuration: 0,
            timestamp: Date(),
            verdict: .unknown,
            methodsUsed: [.skipped],
            threats: [],
            warnings: [ScanWarning(
                code: "UNKNOWN_ERROR",
                message: reason,
                severity: .warning
            )],
            scanLevel: .quick,
            targetType: .file
        )
    }
    
 /// Create a timeout result for unscanned files.
    private func createTimeoutResult(for url: URL) -> FileScanResult {
        FileScanResult(
            id: UUID(),
            fileURL: url,
            scanDuration: 0,
            timestamp: Date(),
            verdict: .unknown,
            methodsUsed: [.skipped],
            threats: [],
            warnings: [ScanWarning(
                code: "INCOMPLETE_DUE_TO_TIMEOUT",
                message: "Scan incomplete due to global timeout",
                severity: .warning
            )],
            scanLevel: .quick,
            targetType: .file
        )
    }
    
 /// Get file size at URL.
    private func getFileSize(at url: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
}

// MARK: - BatchScanError

/// Errors that can occur during batch scanning.
public enum BatchScanError: Error, Sendable {
    case timeout(elapsed: TimeInterval)
    case limitExceeded(PreCheckResult.LimitExceeded)
    case cancelled
}

// MARK: - Testing Support

#if DEBUG
extension BatchScanLimiter {
    // Intentionally empty: `createForTesting` is provided as `internal` on the main type
    // and accessed from tests via `@testable import SkyBridgeCore`.
}
#endif
