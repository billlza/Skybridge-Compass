// MARK: - ScanPolicy.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// Per-ScanLevel policy settings for file scanning operations.
///
/// This struct provides level-specific configuration that determines:
/// - Hash calculation timeouts
/// - Pattern matching enablement
/// - Archive extraction behavior
/// - Notarization checking
///
/// **Requirements: 12.1** - Per-file timeout based on scan level
public struct ScanPolicy: Sendable {
    
 /// The scan level this policy applies to
    public let level: FileScanService.ScanLevel
    
 /// Security limits for reference
    private let limits: SecurityLimits
    
 // MARK: - Initialization
    
 /// Creates a ScanPolicy for the specified scan level.
 ///
 /// - Parameters:
 /// - level: The scan level to create policy for
 /// - limits: Security limits configuration (defaults to .default)
    public init(level: FileScanService.ScanLevel, limits: SecurityLimits = .default) {
        self.level = level
        self.limits = limits
    }
    
 // MARK: - Hash Timeout (Requirements 12.1)
    
 /// Hash calculation timeout based on scan level.
 ///
 /// - Quick: 2s (fast, for user-initiated quick checks)
 /// - Standard: 5s (balanced, for normal operations)
 /// - Deep: 10s (thorough, for security-critical scans)
 ///
 /// **Requirements: 12.1**
    public var hashTimeout: TimeInterval {
        switch level {
        case .quick:
            return limits.hashTimeoutQuick
        case .standard:
            return limits.hashTimeoutStandard
        case .deep:
            return limits.hashTimeoutDeep
        }
    }
    
 // MARK: - Pattern Matching (Requirements 12.1)
    
 /// Whether pattern matching is enabled for this scan level.
 ///
 /// Pattern matching is computationally expensive and only enabled for Deep scans.
 ///
 /// **Requirements: 12.1**
    public var patternMatchingEnabled: Bool {
        level == .deep
    }
    
 /// Whether regex patterns are enabled (subset of pattern matching).
 ///
 /// Regex is only enabled in Deep scan mode due to ReDoS risk.
    public var regexEnabled: Bool {
        level == .deep
    }
    
 // MARK: - Archive Extraction
    
 /// Whether archive extraction is enabled for this scan level.
 ///
 /// Archive extraction is only performed in Deep scans to avoid
 /// zip bomb attacks in quick/standard scans.
    public var archiveExtractionEnabled: Bool {
        level == .deep
    }
    
 // MARK: - Notarization
    
 /// Whether notarization checking is enabled for this scan level.
 ///
 /// Notarization verification requires network access and is
 /// only performed in Deep scans.
    public var notarizationEnabled: Bool {
        level == .deep
    }
    
 // MARK: - File Size Limits
    
 /// Maximum bytes to read for pattern matching.
 ///
 /// - Quick: 0 (no pattern matching)
 /// - Standard: 0 (no pattern matching)
 /// - Deep: 100MB (full pattern matching)
    public var maxBytesForPatternMatch: Int64 {
        switch level {
        case .quick, .standard:
            return 0  // No pattern matching
        case .deep:
            return limits.maxBytesPerFile
        }
    }
    
 /// Large file threshold for sequential processing.
 ///
 /// Files exceeding this size are processed sequentially
 /// to prevent memory exhaustion.
 ///
 /// **Requirements: 12.4**
    public var largeFileThreshold: Int64 {
        limits.largeFileThreshold
    }
    
 // MARK: - Convenience Methods
    
 /// Creates a ScanPolicy for Quick scan level.
    public static func quick(limits: SecurityLimits = .default) -> ScanPolicy {
        ScanPolicy(level: .quick, limits: limits)
    }
    
 /// Creates a ScanPolicy for Standard scan level.
    public static func standard(limits: SecurityLimits = .default) -> ScanPolicy {
        ScanPolicy(level: .standard, limits: limits)
    }
    
 /// Creates a ScanPolicy for Deep scan level.
    public static func deep(limits: SecurityLimits = .default) -> ScanPolicy {
        ScanPolicy(level: .deep, limits: limits)
    }
}

// MARK: - ScanPolicy + Description

extension ScanPolicy: CustomStringConvertible {
    public var description: String {
        """
        ScanPolicy(\(level.rawValue)):
          hashTimeout: \(hashTimeout)s
          patternMatchingEnabled: \(patternMatchingEnabled)
          archiveExtractionEnabled: \(archiveExtractionEnabled)
          notarizationEnabled: \(notarizationEnabled)
          maxBytesForPatternMatch: \(maxBytesForPatternMatch / 1024 / 1024)MB
          largeFileThreshold: \(largeFileThreshold / 1024 / 1024)MB
        """
    }
}
