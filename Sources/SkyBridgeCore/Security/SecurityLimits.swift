// MARK: - SecurityLimits.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Unified security limits configuration.
/// This struct is Sendable but NOT Codable to prevent external config tampering.
/// All limits have sensible defaults for production use.
public struct SecurityLimits: Sendable {
    
 // MARK: - Batch Scan Limits
    
 /// Maximum number of files in a batch scan (default: 10,000)
    public let maxTotalFiles: Int
    
 /// Maximum total bytes in a batch scan (default: 50GB)
    public let maxTotalBytes: Int64
    
 /// Global timeout for batch scan operations (default: 300s)
    public let globalTimeout: TimeInterval
    
 // MARK: - Regex Limits
    
 /// Maximum regex pattern length (default: 1000 chars)
    public let maxRegexPatternLength: Int
    
 /// Maximum number of regex patterns (default: 100)
    public let maxRegexPatternCount: Int
    
 /// Maximum capture groups in a regex (default: 10)
    public let maxRegexGroups: Int
    
 /// Maximum quantifiers in a regex (default: 20)
    public let maxRegexQuantifiers: Int
    
 /// Maximum alternations (|) in a regex (default: 10)
    public let maxRegexAlternations: Int
    
 /// Maximum lookaheads in a regex (default: 3)
    public let maxRegexLookaheads: Int
    
 /// Per-pattern matching timeout (default: 50ms)
    public let perPatternTimeout: TimeInterval
    
 /// Per-pattern input size limit (default: 1MB)
    public let perPatternInputLimit: Int
    
 // MARK: - History Limits
    
 /// Maximum total history storage bytes (default: 10MB)
    public let maxTotalHistoryBytes: Int64
    
 // MARK: - Agent Connection Limits
    
 /// Token bucket refill rate (messages per second, default: 100)
    public let tokenBucketRate: Double
    
 /// Token bucket burst capacity (default: 200)
    public let tokenBucketBurst: Int

    
 /// Maximum message size in bytes (default: 64KB)
    public let maxMessageBytes: Int
    
 /// JSON decode depth limit (default: 10)
    public let decodeDepthLimit: Int
    
 /// JSON decode array length limit (default: 1000)
    public let decodeArrayLengthLimit: Int
    
 /// JSON decode string length limit (default: 64KB)
    public let decodeStringLengthLimit: Int
    
 /// Dropped messages threshold for disconnect (default: 500)
    public let droppedMessagesThreshold: Int
    
 /// Sliding window for dropped messages (default: 10s)
    public let droppedMessagesWindow: TimeInterval
    
 // MARK: - PAKE Limits
    
 /// PAKE record TTL (default: 10 minutes)
    public let pakeRecordTTL: TimeInterval
    
 /// Maximum PAKE records in memory (default: 10,000)
    public let pakeMaxRecords: Int
    
 /// PAKE cleanup trigger interval (default: every 128 writes)
    public let pakeCleanupInterval: Int
    
 // MARK: - Symlink Limits
    
 /// Maximum symlink chain depth (default: 10)
    public let maxSymlinkDepth: Int
    
 // MARK: - Retry Limits
    
 /// Maximum retry count (default: 20)
    public let maxRetryCount: Int
    
 /// Maximum retry delay (default: 300s)
    public let maxRetryDelay: TimeInterval
    
 // MARK: - Extraction Limits
    
 /// Maximum extracted files from archive (default: 1,000)
    public let maxExtractedFiles: Int
    
 /// Maximum total extracted bytes (default: 500MB)
    public let maxTotalExtractedBytes: Int64
    
 /// Maximum archive nesting depth (default: 3)
    public let maxNestingDepth: Int
    
 /// Maximum compression ratio before suspicious (default: 100:1)
    public let maxCompressionRatio: Double
    
 /// Maximum extraction time (default: 10s)
    public let maxExtractionTime: TimeInterval
    
 // MARK: - File Read Limits
    
 /// Maximum bytes per file for pattern matching (default: 100MB)
    public let maxBytesPerFile: Int64
    
 /// Large file threshold for sequential processing (default: 500MB)
    public let largeFileThreshold: Int64
    
 /// Hash timeout for Quick scan level (default: 2s)
    public let hashTimeoutQuick: TimeInterval
    
 /// Hash timeout for Standard scan level (default: 5s)
    public let hashTimeoutStandard: TimeInterval
    
 /// Hash timeout for Deep scan level (default: 10s)
    public let hashTimeoutDeep: TimeInterval
    
 // MARK: - Event Emitter Limits
    
 /// Maximum event queue size (default: 10,000)
    public let maxEventQueueSize: Int
    
 /// Maximum pending events per subscriber (default: 1,000)
    public let maxPendingPerSubscriber: Int
    
 // MARK: - Default Configuration
    
 /// Default security limits for production use
    public static let `default` = SecurityLimits(
        maxTotalFiles: 10_000,
        maxTotalBytes: 50 * 1024 * 1024 * 1024, // 50GB
        globalTimeout: 300.0,
        maxRegexPatternLength: 1000,
        maxRegexPatternCount: 100,
        maxRegexGroups: 10,
        maxRegexQuantifiers: 20,
        maxRegexAlternations: 10,
        maxRegexLookaheads: 3,
        perPatternTimeout: 0.05, // 50ms
        perPatternInputLimit: 1024 * 1024, // 1MB
        maxTotalHistoryBytes: 10 * 1024 * 1024, // 10MB
        tokenBucketRate: 100.0,
        tokenBucketBurst: 200,
        maxMessageBytes: 64 * 1024, // 64KB
        decodeDepthLimit: 10,
        decodeArrayLengthLimit: 1000,
        decodeStringLengthLimit: 64 * 1024, // 64KB
        droppedMessagesThreshold: 500,
        droppedMessagesWindow: 10.0,
        pakeRecordTTL: 600.0, // 10 minutes
        pakeMaxRecords: 10_000,
        pakeCleanupInterval: 128,
        maxSymlinkDepth: 10,
        maxRetryCount: 20,
        maxRetryDelay: 300.0,
        maxExtractedFiles: 1000,
        maxTotalExtractedBytes: 500 * 1024 * 1024, // 500MB
        maxNestingDepth: 3,
        maxCompressionRatio: 100.0,
        maxExtractionTime: 10.0,
        maxBytesPerFile: 100 * 1024 * 1024, // 100MB
        largeFileThreshold: 500 * 1024 * 1024, // 500MB
        hashTimeoutQuick: 2.0,
        hashTimeoutStandard: 5.0,
        hashTimeoutDeep: 10.0,
        maxEventQueueSize: 10_000,
        maxPendingPerSubscriber: 1_000
    )

    
 // MARK: - Memberwise Initializer
    
    public init(
        maxTotalFiles: Int,
        maxTotalBytes: Int64,
        globalTimeout: TimeInterval,
        maxRegexPatternLength: Int,
        maxRegexPatternCount: Int,
        maxRegexGroups: Int,
        maxRegexQuantifiers: Int,
        maxRegexAlternations: Int,
        maxRegexLookaheads: Int,
        perPatternTimeout: TimeInterval,
        perPatternInputLimit: Int,
        maxTotalHistoryBytes: Int64,
        tokenBucketRate: Double,
        tokenBucketBurst: Int,
        maxMessageBytes: Int,
        decodeDepthLimit: Int,
        decodeArrayLengthLimit: Int,
        decodeStringLengthLimit: Int,
        droppedMessagesThreshold: Int,
        droppedMessagesWindow: TimeInterval,
        pakeRecordTTL: TimeInterval,
        pakeMaxRecords: Int,
        pakeCleanupInterval: Int,
        maxSymlinkDepth: Int,
        maxRetryCount: Int,
        maxRetryDelay: TimeInterval,
        maxExtractedFiles: Int,
        maxTotalExtractedBytes: Int64,
        maxNestingDepth: Int,
        maxCompressionRatio: Double,
        maxExtractionTime: TimeInterval,
        maxBytesPerFile: Int64,
        largeFileThreshold: Int64,
        hashTimeoutQuick: TimeInterval,
        hashTimeoutStandard: TimeInterval,
        hashTimeoutDeep: TimeInterval,
        maxEventQueueSize: Int,
        maxPendingPerSubscriber: Int
    ) {
        self.maxTotalFiles = maxTotalFiles
        self.maxTotalBytes = maxTotalBytes
        self.globalTimeout = globalTimeout
        self.maxRegexPatternLength = maxRegexPatternLength
        self.maxRegexPatternCount = maxRegexPatternCount
        self.maxRegexGroups = maxRegexGroups
        self.maxRegexQuantifiers = maxRegexQuantifiers
        self.maxRegexAlternations = maxRegexAlternations
        self.maxRegexLookaheads = maxRegexLookaheads
        self.perPatternTimeout = perPatternTimeout
        self.perPatternInputLimit = perPatternInputLimit
        self.maxTotalHistoryBytes = maxTotalHistoryBytes
        self.tokenBucketRate = tokenBucketRate
        self.tokenBucketBurst = tokenBucketBurst
        self.maxMessageBytes = maxMessageBytes
        self.decodeDepthLimit = decodeDepthLimit
        self.decodeArrayLengthLimit = decodeArrayLengthLimit
        self.decodeStringLengthLimit = decodeStringLengthLimit
        self.droppedMessagesThreshold = droppedMessagesThreshold
        self.droppedMessagesWindow = droppedMessagesWindow
        self.pakeRecordTTL = pakeRecordTTL
        self.pakeMaxRecords = pakeMaxRecords
        self.pakeCleanupInterval = pakeCleanupInterval
        self.maxSymlinkDepth = maxSymlinkDepth
        self.maxRetryCount = maxRetryCount
        self.maxRetryDelay = maxRetryDelay
        self.maxExtractedFiles = maxExtractedFiles
        self.maxTotalExtractedBytes = maxTotalExtractedBytes
        self.maxNestingDepth = maxNestingDepth
        self.maxCompressionRatio = maxCompressionRatio
        self.maxExtractionTime = maxExtractionTime
        self.maxBytesPerFile = maxBytesPerFile
        self.largeFileThreshold = largeFileThreshold
        self.hashTimeoutQuick = hashTimeoutQuick
        self.hashTimeoutStandard = hashTimeoutStandard
        self.hashTimeoutDeep = hashTimeoutDeep
        self.maxEventQueueSize = maxEventQueueSize
        self.maxPendingPerSubscriber = maxPendingPerSubscriber
    }
}

// MARK: - SecurityLimitsConfig (Codable for external input)

/// Codable configuration for external input with validation and clamping.
/// Use this to load limits from external sources, then convert to SecurityLimits.
public struct SecurityLimitsConfig: Codable, Sendable {
    
 // All fields are optional - missing fields use defaults
    public var maxTotalFiles: Int?
    public var maxTotalBytes: Int64?
    public var globalTimeout: TimeInterval?
    public var maxRegexPatternLength: Int?
    public var maxRegexPatternCount: Int?
    public var maxRegexGroups: Int?
    public var maxRegexQuantifiers: Int?
    public var maxRegexAlternations: Int?
    public var maxRegexLookaheads: Int?
    public var perPatternTimeout: TimeInterval?
    public var perPatternInputLimit: Int?
    public var maxTotalHistoryBytes: Int64?
    public var tokenBucketRate: Double?
    public var tokenBucketBurst: Int?
    public var maxMessageBytes: Int?
    public var decodeDepthLimit: Int?
    public var decodeArrayLengthLimit: Int?
    public var decodeStringLengthLimit: Int?
    public var droppedMessagesThreshold: Int?
    public var droppedMessagesWindow: TimeInterval?
    public var pakeRecordTTL: TimeInterval?
    public var pakeMaxRecords: Int?
    public var pakeCleanupInterval: Int?
    public var maxSymlinkDepth: Int?
    public var maxRetryCount: Int?
    public var maxRetryDelay: TimeInterval?
    public var maxExtractedFiles: Int?
    public var maxTotalExtractedBytes: Int64?
    public var maxNestingDepth: Int?
    public var maxCompressionRatio: Double?
    public var maxExtractionTime: TimeInterval?
    public var maxBytesPerFile: Int64?
    public var largeFileThreshold: Int64?
    public var hashTimeoutQuick: TimeInterval?
    public var hashTimeoutStandard: TimeInterval?
    public var hashTimeoutDeep: TimeInterval?
    public var maxEventQueueSize: Int?
    public var maxPendingPerSubscriber: Int?
    
    public init() {}
    
 /// Convert to SecurityLimits with validation and clamping.
 /// Invalid or out-of-range values are clamped to safe bounds.
    public func toSecurityLimits() -> SecurityLimits {
        let defaults = SecurityLimits.default
        
        return SecurityLimits(
            maxTotalFiles: clamp(maxTotalFiles, min: 1, max: 100_000, default: defaults.maxTotalFiles),
            maxTotalBytes: clamp(maxTotalBytes, min: 1024, max: 100 * 1024 * 1024 * 1024, default: defaults.maxTotalBytes),
            globalTimeout: clamp(globalTimeout, min: 1.0, max: 3600.0, default: defaults.globalTimeout),
            maxRegexPatternLength: clamp(maxRegexPatternLength, min: 10, max: 10_000, default: defaults.maxRegexPatternLength),
            maxRegexPatternCount: clamp(maxRegexPatternCount, min: 1, max: 1000, default: defaults.maxRegexPatternCount),
            maxRegexGroups: clamp(maxRegexGroups, min: 1, max: 50, default: defaults.maxRegexGroups),
            maxRegexQuantifiers: clamp(maxRegexQuantifiers, min: 1, max: 100, default: defaults.maxRegexQuantifiers),
            maxRegexAlternations: clamp(maxRegexAlternations, min: 1, max: 50, default: defaults.maxRegexAlternations),
            maxRegexLookaheads: clamp(maxRegexLookaheads, min: 0, max: 10, default: defaults.maxRegexLookaheads),
            perPatternTimeout: clamp(perPatternTimeout, min: 0.001, max: 10.0, default: defaults.perPatternTimeout),
            perPatternInputLimit: clamp(perPatternInputLimit, min: 1024, max: 100 * 1024 * 1024, default: defaults.perPatternInputLimit),
            maxTotalHistoryBytes: clamp(maxTotalHistoryBytes, min: 1024 * 1024, max: 1024 * 1024 * 1024, default: defaults.maxTotalHistoryBytes),
            tokenBucketRate: clamp(tokenBucketRate, min: 1.0, max: 10_000.0, default: defaults.tokenBucketRate),
            tokenBucketBurst: clamp(tokenBucketBurst, min: 1, max: 10_000, default: defaults.tokenBucketBurst),
            maxMessageBytes: clamp(maxMessageBytes, min: 1024, max: 10 * 1024 * 1024, default: defaults.maxMessageBytes),
            decodeDepthLimit: clamp(decodeDepthLimit, min: 1, max: 100, default: defaults.decodeDepthLimit),
            decodeArrayLengthLimit: clamp(decodeArrayLengthLimit, min: 1, max: 100_000, default: defaults.decodeArrayLengthLimit),
            decodeStringLengthLimit: clamp(decodeStringLengthLimit, min: 1024, max: 10 * 1024 * 1024, default: defaults.decodeStringLengthLimit),
            droppedMessagesThreshold: clamp(droppedMessagesThreshold, min: 10, max: 10_000, default: defaults.droppedMessagesThreshold),
            droppedMessagesWindow: clamp(droppedMessagesWindow, min: 1.0, max: 300.0, default: defaults.droppedMessagesWindow),
            pakeRecordTTL: clamp(pakeRecordTTL, min: 60.0, max: 86400.0, default: defaults.pakeRecordTTL),
            pakeMaxRecords: clamp(pakeMaxRecords, min: 100, max: 1_000_000, default: defaults.pakeMaxRecords),
            pakeCleanupInterval: clamp(pakeCleanupInterval, min: 1, max: 10_000, default: defaults.pakeCleanupInterval),
            maxSymlinkDepth: clamp(maxSymlinkDepth, min: 1, max: 100, default: defaults.maxSymlinkDepth),
            maxRetryCount: clamp(maxRetryCount, min: 0, max: 100, default: defaults.maxRetryCount),
            maxRetryDelay: clamp(maxRetryDelay, min: 0.1, max: 86400.0, default: defaults.maxRetryDelay),
            maxExtractedFiles: clamp(maxExtractedFiles, min: 1, max: 100_000, default: defaults.maxExtractedFiles),
            maxTotalExtractedBytes: clamp(maxTotalExtractedBytes, min: 1024 * 1024, max: 10 * 1024 * 1024 * 1024, default: defaults.maxTotalExtractedBytes),
            maxNestingDepth: clamp(maxNestingDepth, min: 1, max: 10, default: defaults.maxNestingDepth),
            maxCompressionRatio: clamp(maxCompressionRatio, min: 1.0, max: 10_000.0, default: defaults.maxCompressionRatio),
            maxExtractionTime: clamp(maxExtractionTime, min: 1.0, max: 3600.0, default: defaults.maxExtractionTime),
            maxBytesPerFile: clamp(maxBytesPerFile, min: 1024, max: 10 * 1024 * 1024 * 1024, default: defaults.maxBytesPerFile),
            largeFileThreshold: clamp(largeFileThreshold, min: 1024 * 1024, max: 10 * 1024 * 1024 * 1024, default: defaults.largeFileThreshold),
            hashTimeoutQuick: clamp(hashTimeoutQuick, min: 0.1, max: 60.0, default: defaults.hashTimeoutQuick),
            hashTimeoutStandard: clamp(hashTimeoutStandard, min: 0.1, max: 300.0, default: defaults.hashTimeoutStandard),
            hashTimeoutDeep: clamp(hashTimeoutDeep, min: 0.1, max: 600.0, default: defaults.hashTimeoutDeep),
            maxEventQueueSize: clamp(maxEventQueueSize, min: 100, max: 1_000_000, default: defaults.maxEventQueueSize),
            maxPendingPerSubscriber: clamp(maxPendingPerSubscriber, min: 10, max: 100_000, default: defaults.maxPendingPerSubscriber)
        )
    }
    
 // MARK: - Private Helpers
    
    private func clamp<T: Comparable>(_ value: T?, min: T, max: T, default defaultValue: T) -> T {
        guard let value = value else { return defaultValue }
        return Swift.min(Swift.max(value, min), max)
    }
}
