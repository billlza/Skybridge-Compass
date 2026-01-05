// MARK: - DeprecationTracker.swift
// SkyBridge Compass - Tech Debt Cleanup
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation
import OSLog

/// Tracks usage of deprecated APIs in DEBUG mode.
///
/// **Design Decision**: Uses NSLock for thread safety instead of actor
/// to avoid requiring `await` at call sites. This allows synchronous
/// recording from any context without async overhead.
///
/// **Usage**:
/// ```swift
/// // In deprecated API implementation:
/// DeprecationTracker.shared.recordUsage(
/// api: "EnhancedDeviceDiscovery.startScanning()",
/// replacement: "DeviceDiscoveryService.shared.startDiscovery()"
/// )
/// ```
///
/// **Requirements**: 10.2, 12.1
@available(macOS 14.0, iOS 17.0, *)
public final class DeprecationTracker: @unchecked Sendable {
    
 // MARK: - Singleton
    
 /// Shared instance for global deprecation tracking
    public static let shared = DeprecationTracker()
    
 // MARK: - Types
    
 /// Record of a deprecated API usage
    public struct UsageRecord: Sendable {
 /// The deprecated API that was called
        public let api: String
        
 /// The recommended replacement API
        public let replacement: String
        
 /// Number of times this API was called
        public let count: Int
        
 /// First time this API was called
        public let firstUsage: Date
        
 /// Last time this API was called
        public let lastUsage: Date
        
 /// Call site information (file:line)
        public let callSites: [String]
    }
    
 /// Internal mutable record for tracking
    private struct MutableRecord {
        var api: String
        var replacement: String
        var count: Int
        var firstUsage: Date
        var lastUsage: Date
        var callSites: Set<String>
        
        func toUsageRecord() -> UsageRecord {
            UsageRecord(
                api: api,
                replacement: replacement,
                count: count,
                firstUsage: firstUsage,
                lastUsage: lastUsage,
                callSites: Array(callSites).sorted()
            )
        }
    }
    
 // MARK: - Properties
    
 /// Lock for thread-safe access
    private let lock = NSLock()
    
 /// Usage records keyed by API name
    private var records: [String: MutableRecord] = [:]
    
 /// Logger for deprecation warnings
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "DeprecationTracker")
    
 /// Whether tracking is enabled (DEBUG only)
    private let isEnabled: Bool
    
 // MARK: - Initialization
    
    private init() {
        #if DEBUG
        self.isEnabled = true
        #else
        self.isEnabled = false
        #endif
    }
    
 // MARK: - Public API
    
 /// Record usage of a deprecated API.
 ///
 /// Thread-safe and synchronous - can be called from any context.
 /// Only records in DEBUG builds.
 ///
 /// - Parameters:
 /// - api: The deprecated API name (e.g., "EnhancedDeviceDiscovery.startScanning()")
 /// - replacement: The recommended replacement API
 /// - file: Source file (auto-captured)
 /// - line: Source line (auto-captured)
    public func recordUsage(
        api: String,
        replacement: String,
        file: String = #file,
        line: Int = #line
    ) {
        guard isEnabled else { return }
        
        let callSite = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        let now = Date()
        
        lock.lock()
        defer { lock.unlock() }
        
        if var existing = records[api] {
            existing.count += 1
            existing.lastUsage = now
            existing.callSites.insert(callSite)
            records[api] = existing
        } else {
            records[api] = MutableRecord(
                api: api,
                replacement: replacement,
                count: 1,
                firstUsage: now,
                lastUsage: now,
                callSites: [callSite]
            )
            
 // Log first usage warning
            logger.warning("⚠️ Deprecated API used: \(api) → Use \(replacement) instead")
        }
    }
    
 /// Get all usage records.
 ///
 /// Thread-safe snapshot of current usage data.
 ///
 /// - Returns: Array of usage records sorted by count (descending)
    public func getUsageRecords() -> [UsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        
        return records.values
            .map { $0.toUsageRecord() }
            .sorted { $0.count > $1.count }
    }
    
 /// Get total number of deprecated API calls.
    public var totalUsageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        
        return records.values.reduce(0) { $0 + $1.count }
    }
    
 /// Get number of unique deprecated APIs used.
    public var uniqueAPICount: Int {
        lock.lock()
        defer { lock.unlock() }
        
        return records.count
    }
    
 /// Generate a human-readable report of deprecated API usage.
 ///
 /// - Returns: Formatted report string
    public func generateReport() -> String {
        let usageRecords = getUsageRecords()
        
        guard !usageRecords.isEmpty else {
            return "✅ No deprecated API usage detected."
        }
        
        var report = """
        ⚠️ Deprecated API Usage Report
        ==============================
        Total calls: \(totalUsageCount)
        Unique APIs: \(uniqueAPICount)
        
        """
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        
        for record in usageRecords {
            report += """
            
            📍 \(record.api)
               Replacement: \(record.replacement)
               Call count: \(record.count)
               First used: \(dateFormatter.string(from: record.firstUsage))
               Last used: \(dateFormatter.string(from: record.lastUsage))
               Call sites:
            """
            for site in record.callSites {
                report += "\n      - \(site)"
            }
            report += "\n"
        }
        
        return report
    }
    
 /// Print the deprecation report to the console.
 ///
 /// Only prints in DEBUG builds.
    public func printReport() {
        guard isEnabled else { return }
        
        let report = generateReport()
        logger.info("\(report)")
        
        #if DEBUG
        print(report)
        #endif
    }
    
 /// Clear all recorded usage data.
 ///
 /// Primarily for testing purposes.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        records.removeAll()
    }
}

// MARK: - Testing Support

#if DEBUG
@available(macOS 14.0, iOS 17.0, *)
extension DeprecationTracker {
 /// Create a test instance (not singleton) for isolated testing.
    public static func createForTesting() -> DeprecationTracker {
        DeprecationTracker()
    }
    
 /// Check if a specific API has been recorded.
    public func hasRecordedUsage(for api: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return records[api] != nil
    }
    
 /// Get usage count for a specific API.
    public func usageCount(for api: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        return records[api]?.count ?? 0
    }
}
#endif
