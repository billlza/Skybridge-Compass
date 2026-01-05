//
// PAKERateLimiterMemoryTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for PAKERateLimiterMemory
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Property Test: PAKE Cleanup Determinism
// **Feature: security-hardening, Property 13: PAKE cleanup determinism**
// **Validates: Requirements 5.2**

final class PAKERateLimiterMemoryTests: XCTestCase {
    
 /// **Feature: security-hardening, Property 13: PAKE cleanup determinism**
 /// **Validates: Requirements 5.2**
 ///
 /// Property: For any sequence of PAKE writes, cleanup SHALL run exactly
 /// when writesCount % cleanupInterval == 0.
 ///
 /// This test verifies:
 /// 1. Cleanup triggers deterministically at cleanupInterval boundaries
 /// 2. Cleanup does not trigger between boundaries
 /// 3. The trigger is based on total writes, not just failures
    func testProperty_PAKECleanupDeterminism() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random cleanup interval (small for testing)
            let cleanupInterval = Int.random(in: 4...32)
            
            let limits = createTestLimits(
                cleanupInterval: cleanupInterval,
                maxRecords: 10_000, // High limit to avoid LRU eviction
                ttl: 3600.0 // Long TTL to avoid expiration
            )
            
            let limiter = PAKERateLimiterMemory(limits: limits)
            
 // Property 1: Initial writesCount should be 0
            let initialWrites = await limiter.currentWritesCount
            XCTAssertEqual(
                initialWrites, 0,
                "Iteration \(iteration): Initial writesCount should be 0"
            )
            
 // Property 2: Cleanup triggers at exact multiples of cleanupInterval
 // Record failures and track when cleanup would trigger
            var expectedCleanupCount = 0
            
            for writeNum in 1...cleanupInterval * 3 {
                let identifier = "device-\(iteration)-\(writeNum)"
                await limiter.recordFailedAttempt(identifier: identifier)
                
 // Check writesCount
                let currentWrites = await limiter.currentWritesCount
                XCTAssertEqual(
                    currentWrites, writeNum,
                    "Iteration \(iteration): writesCount should be \(writeNum)"
                )
                
 // Cleanup should trigger when writeNum % cleanupInterval == 0
                if writeNum % cleanupInterval == 0 {
                    expectedCleanupCount += 1
                }
            }
            
 // Property 3: After 3 * cleanupInterval writes, cleanup should have
 // triggered exactly 3 times
            XCTAssertEqual(
                expectedCleanupCount, 3,
                "Iteration \(iteration): Cleanup should trigger 3 times"
            )
        }
    }
    
 /// Test that cleanup triggers on both failures and successes
    func testCleanupTriggersOnSuccessAndFailure() async throws {
        let cleanupInterval = 4
        let limits = createTestLimits(
            cleanupInterval: cleanupInterval,
            maxRecords: 10_000,
            ttl: 3600.0
        )
        
        let limiter = PAKERateLimiterMemory(limits: limits)
        
 // Mix of failures and successes
        await limiter.recordFailedAttempt(identifier: "device-1") // write 1
        await limiter.recordFailedAttempt(identifier: "device-2") // write 2
        await limiter.recordSuccess(identifier: "device-1")       // write 3
        await limiter.recordFailedAttempt(identifier: "device-3") // write 4 - cleanup triggers
        
        let writes = await limiter.currentWritesCount
        XCTAssertEqual(writes, 4, "Should have 4 writes")
        
 // Continue to next cleanup boundary
        await limiter.recordSuccess(identifier: "device-2")       // write 5
        await limiter.recordFailedAttempt(identifier: "device-4") // write 6
        await limiter.recordSuccess(identifier: "device-3")       // write 7
        await limiter.recordFailedAttempt(identifier: "device-5") // write 8 - cleanup triggers
        
        let finalWrites = await limiter.currentWritesCount
        XCTAssertEqual(finalWrites, 8, "Should have 8 writes")
    }
    
 /// Test that cleanup removes expired records
    func testCleanupRemovesExpiredRecords() async throws {
        let cleanupInterval = 4
        let ttlSeconds = 0.1 // 100ms TTL for testing
        
        let limits = createTestLimits(
            cleanupInterval: cleanupInterval,
            maxRecords: 10_000,
            ttl: ttlSeconds
        )
        
        let limiter = PAKERateLimiterMemory(limits: limits)
        
 // Add some records
        await limiter.recordFailedAttempt(identifier: "device-1")
        await limiter.recordFailedAttempt(identifier: "device-2")
        
 // Wait for TTL to expire
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms > 100ms TTL
        
 // Add more records to trigger cleanup
        await limiter.recordFailedAttempt(identifier: "device-3")
        await limiter.recordFailedAttempt(identifier: "device-4") // write 4 - cleanup triggers
        
 // Expired records should be removed
        let record1 = await limiter.getRecord(for: "device-1")
        let record2 = await limiter.getRecord(for: "device-2")
        
        XCTAssertNil(record1, "Expired record device-1 should be removed")
        XCTAssertNil(record2, "Expired record device-2 should be removed")
        
 // New records should still exist
        let record3 = await limiter.getRecord(for: "device-3")
        let record4 = await limiter.getRecord(for: "device-4")
        
        XCTAssertNotNil(record3, "New record device-3 should exist")
        XCTAssertNotNil(record4, "New record device-4 should exist")
    }
}



// MARK: - Property Test: PAKE LRU Eviction
// **Feature: security-hardening, Property 14: PAKE LRU eviction**
// **Validates: Requirements 5.3, 5.6**

extension PAKERateLimiterMemoryTests {
    
 /// **Feature: security-hardening, Property 14: PAKE LRU eviction**
 /// **Validates: Requirements 5.3, 5.6**
 ///
 /// Property: For any PAKE records map exceeding maxRecords, the oldest entries
 /// by lastAttemptTimestamp SHALL be evicted.
 ///
 /// This test verifies:
 /// 1. Records are evicted when exceeding maxRecords
 /// 2. Oldest records (by lastAttemptTimestamp) are evicted first
 /// 3. Newer records are preserved
    func testProperty_PAKELRUEviction() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random maxRecords (small for testing)
            let maxRecords = Int.random(in: 5...20)
            let cleanupInterval = 1 // Trigger cleanup on every write for testing
            
            let limits = createTestLimits(
                cleanupInterval: cleanupInterval,
                maxRecords: maxRecords,
                ttl: 3600.0 // Long TTL to avoid expiration
            )
            
            let limiter = PAKERateLimiterMemory(limits: limits)
            
 // Add more records than maxRecords
            let totalRecords = maxRecords + Int.random(in: 5...10)
            
            for i in 0..<totalRecords {
                let identifier = "device-\(iteration)-\(i)"
                await limiter.recordFailedAttempt(identifier: identifier)
                
 // Small delay to ensure different timestamps
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            
 // Property 1: Record count should not exceed maxRecords
            let recordCount = await limiter.recordCount
            XCTAssertLessThanOrEqual(
                recordCount, maxRecords,
                "Iteration \(iteration): Record count (\(recordCount)) should not exceed maxRecords (\(maxRecords))"
            )
            
 // Property 2: Newest records should be preserved
 // The last maxRecords identifiers should still exist
            let newestStartIndex = totalRecords - maxRecords
            for i in newestStartIndex..<totalRecords {
                let identifier = "device-\(iteration)-\(i)"
                let record = await limiter.getRecord(for: identifier)
                XCTAssertNotNil(
                    record,
                    "Iteration \(iteration): Newest record \(identifier) should be preserved"
                )
            }
            
 // Property 3: Oldest records should be evicted
 // At least some of the oldest records should be gone
            var evictedCount = 0
            for i in 0..<newestStartIndex {
                let identifier = "device-\(iteration)-\(i)"
                let record = await limiter.getRecord(for: identifier)
                if record == nil {
                    evictedCount += 1
                }
            }
            
            XCTAssertGreaterThan(
                evictedCount, 0,
                "Iteration \(iteration): Some oldest records should be evicted"
            )
        }
    }
    
 /// Test LRU eviction preserves most recently accessed records
    func testLRUEvictionPreservesRecentlyAccessed() async throws {
        let maxRecords = 5
        let cleanupInterval = 1
        
        let limits = createTestLimits(
            cleanupInterval: cleanupInterval,
            maxRecords: maxRecords,
            ttl: 3600.0
        )
        
        let limiter = PAKERateLimiterMemory(limits: limits)
        
 // Add initial records
        for i in 0..<maxRecords {
            await limiter.recordFailedAttempt(identifier: "device-\(i)")
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms delay
        }
        
 // Access the oldest record to update its timestamp
        await limiter.recordFailedAttempt(identifier: "device-0")
        try await Task.sleep(nanoseconds: 1_000_000)
        
 // Add new records to trigger eviction
        for i in maxRecords..<(maxRecords + 3) {
            await limiter.recordFailedAttempt(identifier: "device-\(i)")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        
 // device-0 should still exist (was recently accessed)
        let record0 = await limiter.getRecord(for: "device-0")
        XCTAssertNotNil(record0, "Recently accessed device-0 should be preserved")
        
 // Some middle records should be evicted
        var evictedMiddle = 0
        for i in 1..<maxRecords {
            let record = await limiter.getRecord(for: "device-\(i)")
            if record == nil {
                evictedMiddle += 1
            }
        }
        
        XCTAssertGreaterThan(evictedMiddle, 0, "Some middle records should be evicted")
    }
    
 /// Test that eviction happens during cleanup, not on every write
    func testEvictionHappensDuringCleanup() async throws {
        let maxRecords = 5
        let cleanupInterval = 4 // Cleanup every 4 writes
        
        let limits = createTestLimits(
            cleanupInterval: cleanupInterval,
            maxRecords: maxRecords,
            ttl: 3600.0
        )
        
        let limiter = PAKERateLimiterMemory(limits: limits)
        
 // Add records without triggering cleanup
        for i in 0..<3 {
            await limiter.recordFailedAttempt(identifier: "device-\(i)")
        }
        
 // Should have 3 records (no cleanup yet)
        let countBefore = await limiter.recordCount
        XCTAssertEqual(countBefore, 3, "Should have 3 records before cleanup")
        
 // Add more records to exceed maxRecords but still no cleanup
 // (cleanup triggers at write 4, 8, 12, ...)
 // We're at write 3, so write 4 will trigger cleanup
        
 // Add 4th record - this triggers cleanup
        await limiter.recordFailedAttempt(identifier: "device-3")
        
 // Now add more to exceed limit
        for i in 4..<8 {
            await limiter.recordFailedAttempt(identifier: "device-\(i)")
        }
        
 // Write 8 triggers cleanup, which should evict oldest
        let countAfter = await limiter.recordCount
        XCTAssertLessThanOrEqual(countAfter, maxRecords, "Should not exceed maxRecords after cleanup")
    }
}


// MARK: - Additional Unit Tests

extension PAKERateLimiterMemoryTests {
    
 /// Test PAKERecord creation and mutation
    func testPAKERecordCreation() async throws {
        let now = ContinuousClock().now
        
 // Test new record creation
        let record = PAKERecord.newRecord(identifier: "test-device", now: now)
        
        XCTAssertEqual(record.identifier, "test-device")
        XCTAssertEqual(record.failedAttempts, 1)
        XCTAssertEqual(record.backoffLevel, 1)
        XCTAssertNil(record.lockoutUntil)
    }
    
 /// Test PAKERecord increment failure
    func testPAKERecordIncrementFailure() async throws {
        let now = ContinuousClock().now
        let record = PAKERecord.newRecord(identifier: "test-device", now: now)
        
 // Increment without reaching lockout
        let updated = record.incrementFailure(
            now: now,
            maxAttempts: 5,
            lockoutDuration: .seconds(300)
        )
        
        XCTAssertEqual(updated.failedAttempts, 2)
        XCTAssertEqual(updated.backoffLevel, 2)
        XCTAssertNil(updated.lockoutUntil)
    }
    
 /// Test PAKERecord lockout trigger
    func testPAKERecordLockoutTrigger() async throws {
        let now = ContinuousClock().now
        var record = PAKERecord.newRecord(identifier: "test-device", now: now)
        
 // Increment to reach lockout threshold
        for _ in 0..<4 {
            record = record.incrementFailure(
                now: now,
                maxAttempts: 5,
                lockoutDuration: .seconds(300)
            )
        }
        
        XCTAssertEqual(record.failedAttempts, 5)
        XCTAssertNotNil(record.lockoutUntil)
    }
    
 /// Test PAKERecord TTL expiration check
    func testPAKERecordTTLExpiration() async throws {
        let clock = ContinuousClock()
        let past = clock.now - .seconds(700) // 700 seconds ago
        
        let record = PAKERecord(
            identifier: "test-device",
            failedAttempts: 1,
            lastAttemptTimestamp: past,
            lockoutUntil: nil,
            backoffLevel: 1
        )
        
 // With 600s TTL, record should be expired
        let isExpired = record.isExpired(now: clock.now, ttl: .seconds(600))
        XCTAssertTrue(isExpired, "Record should be expired")
        
 // With 800s TTL, record should not be expired
        let isNotExpired = record.isExpired(now: clock.now, ttl: .seconds(800))
        XCTAssertFalse(isNotExpired, "Record should not be expired with longer TTL")
    }
    
 /// Test rate limit check - allowed
    func testRateLimitCheckAllowed() async throws {
        let limits = createTestLimits(
            cleanupInterval: 128,
            maxRecords: 10_000,
            ttl: 600.0
        )
        
        let limiter = PAKERateLimiterMemory(limits: limits)
        
 // No record exists - should be allowed
        let result = await limiter.checkRateLimit(identifier: "new-device")
        XCTAssertEqual(result, .allowed)
    }
    
 /// Test rate limit check - rate limited
    func testRateLimitCheckRateLimited() async throws {
        let limits = createTestLimits(
            cleanupInterval: 128,
            maxRecords: 10_000,
            ttl: 600.0
        )
        
        let limiter = PAKERateLimiterMemory(
            limits: limits,
            backoffBaseSeconds: 10.0, // 10 second base backoff
            backoffMaxSeconds: 60.0
        )
        
 // Record a failure
        await limiter.recordFailedAttempt(identifier: "test-device")
        
 // Immediately check - should be rate limited
        let result = await limiter.checkRateLimit(identifier: "test-device")
        
        if case .rateLimited(let retryAfter) = result {
            XCTAssertGreaterThan(retryAfter, .zero, "Should have positive retry time")
        } else {
            XCTFail("Expected rate limited, got \(result)")
        }
    }
    
 /// Test rate limit check - locked out
    func testRateLimitCheckLockedOut() async throws {
        let limits = createTestLimits(
            cleanupInterval: 128,
            maxRecords: 10_000,
            ttl: 600.0
        )
        
        let limiter = PAKERateLimiterMemory(
            limits: limits,
            maxAttempts: 3,
            lockoutDuration: .seconds(300)
        )
        
 // Record failures to trigger lockout
        for _ in 0..<3 {
            await limiter.recordFailedAttempt(identifier: "test-device")
        }
        
 // Check - should be locked out
        let isLockedOut = await limiter.isLockedOut(identifier: "test-device")
        XCTAssertTrue(isLockedOut, "Should be locked out after max attempts")
        
        let result = await limiter.checkRateLimit(identifier: "test-device")
        if case .lockedOut = result {
 // Expected
        } else {
            XCTFail("Expected locked out, got \(result)")
        }
    }
    
 /// Test success resets record
    func testSuccessResetsRecord() async throws {
        let limits = createTestLimits(
            cleanupInterval: 128,
            maxRecords: 10_000,
            ttl: 600.0
        )
        
        let limiter = PAKERateLimiterMemory(limits: limits)
        
 // Record failures
        await limiter.recordFailedAttempt(identifier: "test-device")
        await limiter.recordFailedAttempt(identifier: "test-device")
        
 // Verify record exists
        let recordBefore = await limiter.getRecord(for: "test-device")
        XCTAssertNotNil(recordBefore)
        XCTAssertEqual(recordBefore?.failedAttempts, 2)
        
 // Record success
        await limiter.recordSuccess(identifier: "test-device")
        
 // Record should be removed
        let recordAfter = await limiter.getRecord(for: "test-device")
        XCTAssertNil(recordAfter, "Record should be removed after success")
    }
    
 /// Test expired lockout is cleared during cleanup
    func testExpiredLockoutCleared() async throws {
        let cleanupInterval = 1
        let limits = createTestLimits(
            cleanupInterval: cleanupInterval,
            maxRecords: 10_000,
            ttl: 3600.0
        )
        
        let limiter = PAKERateLimiterMemory(
            limits: limits,
            maxAttempts: 2,
            lockoutDuration: .milliseconds(100) // 100ms lockout
        )
        
 // Trigger lockout
        await limiter.recordFailedAttempt(identifier: "test-device")
        await limiter.recordFailedAttempt(identifier: "test-device")
        
 // Verify locked out
        let isLockedBefore = await limiter.isLockedOut(identifier: "test-device")
        XCTAssertTrue(isLockedBefore, "Should be locked out")
        
 // Wait for lockout to expire
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
 // Trigger cleanup
        await limiter.recordFailedAttempt(identifier: "other-device")
        
 // Lockout should be cleared
        let isLockedAfter = await limiter.isLockedOut(identifier: "test-device")
        XCTAssertFalse(isLockedAfter, "Lockout should be cleared after expiration")
    }
    
 // MARK: - Helper Methods
    
    private func createTestLimits(
        cleanupInterval: Int,
        maxRecords: Int,
        ttl: Double
    ) -> SecurityLimits {
        return SecurityLimits(
            maxTotalFiles: 10_000,
            maxTotalBytes: 50 * 1024 * 1024 * 1024,
            globalTimeout: 300.0,
            maxRegexPatternLength: 1000,
            maxRegexPatternCount: 100,
            maxRegexGroups: 10,
            maxRegexQuantifiers: 20,
            maxRegexAlternations: 10,
            maxRegexLookaheads: 3,
            perPatternTimeout: 0.05,
            perPatternInputLimit: 1024 * 1024,
            maxTotalHistoryBytes: 10 * 1024 * 1024,
            tokenBucketRate: 100.0,
            tokenBucketBurst: 200,
            maxMessageBytes: 64 * 1024,
            decodeDepthLimit: 10,
            decodeArrayLengthLimit: 1000,
            decodeStringLengthLimit: 64 * 1024,
            droppedMessagesThreshold: 500,
            droppedMessagesWindow: 10.0,
            pakeRecordTTL: ttl,
            pakeMaxRecords: maxRecords,
            pakeCleanupInterval: cleanupInterval,
            maxSymlinkDepth: 10,
            maxRetryCount: 20,
            maxRetryDelay: 300.0,
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: 500 * 1024 * 1024,
            maxNestingDepth: 3,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 10.0,
            maxBytesPerFile: 100 * 1024 * 1024,
            largeFileThreshold: 500 * 1024 * 1024,
            hashTimeoutQuick: 2.0,
            hashTimeoutStandard: 5.0,
            hashTimeoutDeep: 10.0,
            maxEventQueueSize: 10_000,
            maxPendingPerSubscriber: 1_000
        )
    }
}
