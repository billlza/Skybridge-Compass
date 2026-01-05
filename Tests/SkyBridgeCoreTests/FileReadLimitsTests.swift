// MARK: - FileReadLimitsTests.swift
// SkyBridge Compass - Security Hardening Tests
// Copyright © 2024 SkyBridge. All rights reserved.

import XCTest
@testable import SkyBridgeCore

// MARK: - Property 21: File read timeout by scan level
// **Feature: security-hardening, Property 21: File read timeout by scan level**
// **Validates: Requirements 12.1**

final class FileReadLimitsTests: XCTestCase {
    
    var tempDirectory: URL!
    
    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileReadLimitsTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
    
 // MARK: - Helper Methods
    
 /// Creates a test file with specified size
    private func createTestFile(size: Int, name: String = "test.bin") throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent(name)
        let data = Data(repeating: 0xAB, count: size)
        try data.write(to: fileURL)
        return fileURL
    }
    
 // MARK: - Property 21: Hash timeout varies by scan level
    
 /// Property: For any scan level, the hash timeout should match the level-specific value
 /// Quick: 2s, Standard: 5s, Deep: 10s
    func testProperty21_HashTimeoutVariesByScanLevel() async throws {
 // Test all scan levels
        let levels: [FileScanService.ScanLevel] = [.quick, .standard, .deep]
        let expectedTimeouts: [FileScanService.ScanLevel: TimeInterval] = [
            .quick: 2.0,
            .standard: 5.0,
            .deep: 10.0
        ]
        
        for level in levels {
            let policy = ScanPolicy(level: level)
            let expectedTimeout = expectedTimeouts[level]!
            
            XCTAssertEqual(
                policy.hashTimeout,
                expectedTimeout,
                "Hash timeout for \(level.rawValue) should be \(expectedTimeout)s"
            )
        }
    }
    
 /// Property: For any scan level, Quick < Standard < Deep timeout ordering is preserved
    func testProperty21_TimeoutOrderingIsPreserved() async throws {
        let quickPolicy = ScanPolicy(level: .quick)
        let standardPolicy = ScanPolicy(level: .standard)
        let deepPolicy = ScanPolicy(level: .deep)
        
        XCTAssertLessThan(
            quickPolicy.hashTimeout,
            standardPolicy.hashTimeout,
            "Quick timeout should be less than Standard"
        )
        
        XCTAssertLessThan(
            standardPolicy.hashTimeout,
            deepPolicy.hashTimeout,
            "Standard timeout should be less than Deep"
        )
    }
    
 /// Property: For any file, streaming hash respects the timeout
    func testProperty21_StreamingHashRespectsTimeout() async throws {
 // Create a small test file
        let fileURL = try createTestFile(size: 1024, name: "timeout_test.bin")
        
        let hasher = StreamingHasher()
        
 // Test with a generous timeout - should complete
        let result = await hasher.hash(url: fileURL, timeout: 10.0)
        
        XCTAssertTrue(result.isComplete, "Hash should complete within timeout")
        XCTAssertFalse(result.hash.isEmpty, "Hash should not be empty")
        XCTAssertEqual(result.bytesHashed, 1024, "Should hash all bytes")
        XCTAssertNil(result.error, "Should have no error")
    }
    
 /// Property: For any file, hash result includes correct byte count
    func testProperty21_HashResultIncludesByteCount() async throws {
 // Test with various file sizes
        let sizes = [0, 100, 1024, 10240, 65536]
        
        let hasher = StreamingHasher()
        
        for size in sizes {
            let fileURL = try createTestFile(size: size, name: "size_\(size).bin")
            let result = await hasher.hash(url: fileURL, timeout: 10.0)
            
            XCTAssertEqual(
                result.bytesHashed,
                Int64(size),
                "Bytes hashed should equal file size \(size)"
            )
        }
    }
    
 /// Property: For any scan policy, hash uses the correct timeout
    func testProperty21_HashUsesPolicyTimeout() async throws {
        let fileURL = try createTestFile(size: 1024, name: "policy_test.bin")
        
        let hasher = StreamingHasher()
        
 // Test with each scan level policy
        let levels: [FileScanService.ScanLevel] = [.quick, .standard, .deep]
        
        for level in levels {
            let policy = ScanPolicy(level: level)
            let result = await hasher.hash(url: fileURL, policy: policy)
            
            XCTAssertTrue(
                result.isComplete,
                "Hash should complete for \(level.rawValue) level"
            )
            XCTAssertLessThanOrEqual(
                result.duration,
                policy.hashTimeout,
                "Hash duration should be within timeout for \(level.rawValue)"
            )
        }
    }
    
 /// Property: For any non-existent file, hash returns appropriate error
    func testProperty21_NonExistentFileReturnsError() async throws {
        let nonExistentURL = tempDirectory.appendingPathComponent("does_not_exist.bin")
        
        let hasher = StreamingHasher()
        let result = await hasher.hash(url: nonExistentURL, timeout: 5.0)
        
        XCTAssertFalse(result.isComplete, "Hash should not complete for non-existent file")
        XCTAssertNotNil(result.error, "Should have an error")
        
        if case .fileNotFound = result.error {
 // Expected
        } else {
            XCTFail("Expected fileNotFound error, got \(String(describing: result.error))")
        }
    }
    
 /// Property: For any file, hash result is deterministic
    func testProperty21_HashIsDeterministic() async throws {
        let fileURL = try createTestFile(size: 4096, name: "deterministic.bin")
        
        let hasher = StreamingHasher()
        
 // Hash the same file multiple times
        var hashes: [String] = []
        for _ in 0..<5 {
            let result = await hasher.hash(url: fileURL, timeout: 10.0)
            XCTAssertTrue(result.isComplete)
            hashes.append(result.hash)
        }
        
 // All hashes should be identical
        let firstHash = hashes[0]
        for hash in hashes {
            XCTAssertEqual(hash, firstHash, "Hash should be deterministic")
        }
    }
    
 /// Property: For any empty file, hash completes successfully
    func testProperty21_EmptyFileHashCompletes() async throws {
        let fileURL = try createTestFile(size: 0, name: "empty.bin")
        
        let hasher = StreamingHasher()
        let result = await hasher.hash(url: fileURL, timeout: 5.0)
        
        XCTAssertTrue(result.isComplete, "Empty file hash should complete")
        XCTAssertFalse(result.hash.isEmpty, "Empty file should still have a hash")
        XCTAssertEqual(result.bytesHashed, 0, "Bytes hashed should be 0")
        
 // SHA256 of empty data is a known value
        let expectedEmptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertEqual(result.hash, expectedEmptyHash, "Empty file hash should match expected SHA256")
    }
}

// MARK: - Property 22: Large file sequential processing
// **Feature: security-hardening, Property 22: Large file sequential processing**
// **Validates: Requirements 12.4**

extension FileReadLimitsTests {
    
 /// Property: For any file exceeding largeFileThreshold, it is classified as large
    func testProperty22_LargeFileClassification() async throws {
        let processor = LargeFileProcessor()
        let threshold = await processor.largeFileThreshold
        
 // Create files at boundary
        let smallFile = try createTestFile(size: Int(threshold - 1), name: "small.bin")
        let exactFile = try createTestFile(size: Int(threshold), name: "exact.bin")
        let largeFile = try createTestFile(size: Int(threshold + 1), name: "large.bin")
        
        let smallClass = await processor.classify(url: smallFile)
        let exactClass = await processor.classify(url: exactFile)
        let largeClass = await processor.classify(url: largeFile)
        
        XCTAssertEqual(smallClass.sizeClass, .normal, "File below threshold should be normal")
        XCTAssertEqual(exactClass.sizeClass, .normal, "File at threshold should be normal")
        XCTAssertEqual(largeClass.sizeClass, .large, "File above threshold should be large")
    }
    
 /// Property: For any batch of files, partition correctly separates normal and large
    func testProperty22_PartitionSeparatesCorrectly() async throws {
 // Use a smaller threshold for testing
        let testLimits = SecurityLimits(
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
            pakeRecordTTL: 600.0,
            pakeMaxRecords: 10_000,
            pakeCleanupInterval: 128,
            maxSymlinkDepth: 10,
            maxRetryCount: 20,
            maxRetryDelay: 300.0,
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: 500 * 1024 * 1024,
            maxNestingDepth: 3,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 10.0,
            maxBytesPerFile: 100 * 1024 * 1024,
            largeFileThreshold: 1024,  // 1KB for testing
            hashTimeoutQuick: 2.0,
            hashTimeoutStandard: 5.0,
            hashTimeoutDeep: 10.0,
            maxEventQueueSize: 10_000,
            maxPendingPerSubscriber: 1_000
        )
        
        let processor = LargeFileProcessor(limits: testLimits)
        
 // Create test files
        let small1 = try createTestFile(size: 500, name: "small1.bin")
        let small2 = try createTestFile(size: 800, name: "small2.bin")
        let large1 = try createTestFile(size: 2000, name: "large1.bin")
        let large2 = try createTestFile(size: 3000, name: "large2.bin")
        
        let urls = [small1, large1, small2, large2]
        let (normal, large) = await processor.partition(urls: urls)
        
        XCTAssertEqual(normal.count, 2, "Should have 2 normal files")
        XCTAssertEqual(large.count, 2, "Should have 2 large files")
        
        XCTAssertTrue(normal.contains(small1), "small1 should be in normal")
        XCTAssertTrue(normal.contains(small2), "small2 should be in normal")
        XCTAssertTrue(large.contains(large1), "large1 should be in large")
        XCTAssertTrue(large.contains(large2), "large2 should be in large")
    }
    
 /// Property: For any batch, process returns results in input order
    func testProperty22_ProcessReturnsResultsInOrder() async throws {
        let processor = LargeFileProcessor()
        
 // Create test files with identifiable content
        var urls: [URL] = []
        for i in 0..<5 {
            let fileURL = try createTestFile(size: 100 + i * 10, name: "order_\(i).bin")
            urls.append(fileURL)
        }
        
 // Process and verify order
        let results = await processor.process(urls: urls, maxConcurrent: 2) { url -> String in
            return url.lastPathComponent
        }
        
        XCTAssertEqual(results.count, urls.count, "Should have same number of results")
        
        for (index, result) in results.enumerated() {
            let expectedName = "order_\(index).bin"
            XCTAssertEqual(result, expectedName, "Result at index \(index) should match input order")
        }
    }
    
 /// Property: For any batch with large files, large files are processed sequentially
    func testProperty22_LargeFilesProcessedSequentially() async throws {
 // Use a smaller threshold for testing
        let testLimits = SecurityLimits(
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
            pakeRecordTTL: 600.0,
            pakeMaxRecords: 10_000,
            pakeCleanupInterval: 128,
            maxSymlinkDepth: 10,
            maxRetryCount: 20,
            maxRetryDelay: 300.0,
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: 500 * 1024 * 1024,
            maxNestingDepth: 3,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 10.0,
            maxBytesPerFile: 100 * 1024 * 1024,
            largeFileThreshold: 500,  // 500 bytes for testing
            hashTimeoutQuick: 2.0,
            hashTimeoutStandard: 5.0,
            hashTimeoutDeep: 10.0,
            maxEventQueueSize: 10_000,
            maxPendingPerSubscriber: 1_000
        )
        
        let processor = LargeFileProcessor(limits: testLimits)
        
 // Create mix of small and large files
        let small1 = try createTestFile(size: 100, name: "s1.bin")
        let small2 = try createTestFile(size: 200, name: "s2.bin")
        let large1 = try createTestFile(size: 1000, name: "l1.bin")
        let large2 = try createTestFile(size: 1500, name: "l2.bin")
        
        let urls = [small1, large1, small2, large2]
        
 // Track concurrent execution for large files
        let tracker = ConcurrencyTracker()
        
        let results = await processor.process(urls: urls, maxConcurrent: 4) { url -> String in
            let isLarge = url.lastPathComponent.hasPrefix("l")
            
            if isLarge {
                await tracker.startLargeFile()
 // Simulate some work
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                await tracker.endLargeFile()
            }
            
            return url.lastPathComponent
        }
        
        XCTAssertEqual(results.count, 4, "Should process all files")
        
 // Large files should never have been concurrent
        let maxConcurrentLarge = await tracker.maxConcurrentLarge
        XCTAssertLessThanOrEqual(
            maxConcurrentLarge,
            1,
            "Large files should be processed sequentially (max concurrent: \(maxConcurrentLarge))"
        )
    }
    
 /// Property: For any batch, statistics are accurate
    func testProperty22_StatisticsAreAccurate() async throws {
        let processor = LargeFileProcessor()
        
 // Create test files
        let file1 = try createTestFile(size: 1000, name: "stat1.bin")
        let file2 = try createTestFile(size: 2000, name: "stat2.bin")
        let file3 = try createTestFile(size: 3000, name: "stat3.bin")
        
        let urls = [file1, file2, file3]
        let stats = await processor.statistics(for: urls)
        
        XCTAssertEqual(stats.totalFiles, 3, "Should have 3 total files")
        XCTAssertEqual(stats.totalSize, 6000, "Total size should be 6000 bytes")
        XCTAssertEqual(stats.largestFileSize, 3000, "Largest file should be 3000 bytes")
    }
    
 /// Property: For any empty batch, process returns empty results
    func testProperty22_EmptyBatchReturnsEmpty() async throws {
        let processor = LargeFileProcessor()
        
        let results = await processor.process(urls: [], maxConcurrent: 4) { url -> String in
            return url.lastPathComponent
        }
        
        XCTAssertTrue(results.isEmpty, "Empty batch should return empty results")
    }
}

// MARK: - Concurrency Tracker

/// Actor to track concurrent execution of large files
private actor ConcurrencyTracker {
    private var currentConcurrentLarge: Int = 0
    var maxConcurrentLarge: Int = 0
    
    func startLargeFile() {
        currentConcurrentLarge += 1
        if currentConcurrentLarge > maxConcurrentLarge {
            maxConcurrentLarge = currentConcurrentLarge
        }
    }
    
    func endLargeFile() {
        currentConcurrentLarge -= 1
    }
}

// MARK: - Error Sanitization Tests

extension FileReadLimitsTests {
    
 /// Test that error sanitization removes absolute paths
    func testErrorSanitizationRemovesAbsolutePaths() {
        let url = URL(fileURLWithPath: "/Users/testuser/Documents/secret.txt")
        let error = FileScanError.fileNotFound(url)
        
        let sanitized = ScanErrorSanitizer.sanitize(error)
        
        XCTAssertFalse(sanitized.contains("/Users"), "Should not contain /Users")
        XCTAssertFalse(sanitized.contains("testuser"), "Should not contain username")
        XCTAssertTrue(sanitized.contains("secret.txt"), "Should contain filename")
    }
    
 /// Test that log sanitization differs between DEBUG and RELEASE
    func testLogSanitizationForDifferentBuilds() {
        let url = URL(fileURLWithPath: "/Users/testuser/Documents/secret.txt")
        let error = FileScanError.permissionDenied(url)
        
        let logSanitized = ScanErrorSanitizer.sanitizeForLog(error)
        
 // In DEBUG, should contain full path
 // In RELEASE, should contain hash
        #if DEBUG
        XCTAssertTrue(logSanitized.contains("/Users"), "DEBUG should contain full path")
        #else
        XCTAssertFalse(logSanitized.contains("/Users"), "RELEASE should not contain full path")
        #endif
    }
    
 /// Test that ScanWarning can be created from errors
    func testScanWarningFromError() {
        let url = URL(fileURLWithPath: "/tmp/test.bin")
        let error = FileScanError.timeout(url, 5.0)
        
        let warning = ScanWarning.fromError(error)
        
        XCTAssertEqual(warning.code, "SCAN_TIMEOUT")
        XCTAssertFalse(warning.message.contains("/tmp"), "Should not contain path")
        XCTAssertTrue(warning.message.contains("test.bin"), "Should contain filename")
    }
}
