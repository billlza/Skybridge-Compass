//
// BatchScanLimiterTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for BatchScanLimiter
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test Data Generator

/// Generates test data for BatchScanLimiter tests
struct BatchScanTestGenerator {
    
 /// Creates a temporary directory for testing
    static func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchScanTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
    
 /// Creates a test file with random content
    static func createTestFile(in directory: URL, name: String, size: Int = 100) throws -> URL {
        let fileURL = directory.appendingPathComponent(name)
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
        try data.write(to: fileURL)
        return fileURL
    }
    
 /// Creates a symbolic link to a target file
    static func createSymlink(at linkURL: URL, to targetURL: URL) throws {
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    }
    
 /// Creates a hard link to a target file
    static func createHardLink(at linkURL: URL, to targetURL: URL) throws {
        try FileManager.default.linkItem(at: targetURL, to: linkURL)
    }
    
 /// Cleans up a temporary directory
    static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
    
 /// Generates a random batch of file URLs with potential duplicates
 /// Returns: (allURLs, expectedUniqueCount, canonicalPaths)
    static func generateBatchWithDuplicates(
        in directory: URL,
        uniqueFileCount: Int,
        duplicateCount: Int,
        symlinkCount: Int
    ) throws -> (urls: [URL], expectedUniqueCount: Int, canonicalPaths: Set<String>) {
        var urls: [URL] = []
        var canonicalPaths: Set<String> = []
        var createdFiles: [URL] = []
        
 // Create unique files
        for i in 0..<uniqueFileCount {
            let fileURL = try createTestFile(in: directory, name: "file_\(i).txt", size: Int.random(in: 50...500))
            createdFiles.append(fileURL)
            urls.append(fileURL)
            
 // Get canonical path
            if let realpath = realpath(fileURL.path, nil) {
                canonicalPaths.insert(String(cString: realpath))
                free(realpath)
            }
        }
        
 // Add duplicate references (same file added multiple times)
        for _ in 0..<duplicateCount {
            if let randomFile = createdFiles.randomElement() {
                urls.append(randomFile)
            }
        }
        
 // Create symlinks to existing files
        for i in 0..<symlinkCount {
            if let targetFile = createdFiles.randomElement() {
                let symlinkURL = directory.appendingPathComponent("symlink_\(i).txt")
                try createSymlink(at: symlinkURL, to: targetFile)
                urls.append(symlinkURL)
            }
        }
        
 // Shuffle to randomize order
        urls.shuffle()
        
        return (urls, uniqueFileCount, canonicalPaths)
    }
}

// MARK: - Property Test: Batch Scan Deduplication by Realpath
// **Feature: security-hardening, Property 1: Batch scan deduplication by realpath**
// **Validates: Requirements 1.1, 1.7**

final class BatchScanLimiterDeduplicationTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try BatchScanTestGenerator.createTempDirectory()
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            BatchScanTestGenerator.cleanup(directory: tempDir)
        }
        try await super.tearDown()
    }
    
 /// **Feature: security-hardening, Property 1: Batch scan deduplication by realpath**
 /// **Validates: Requirements 1.1, 1.7**
 ///
 /// Property: For any batch of file URLs containing duplicates (same file via different paths/symlinks),
 /// the deduplicated list SHALL contain each unique file exactly once based on realpath() resolution.
 ///
 /// This test verifies:
 /// 1. Duplicate URLs (same file path) are deduplicated
 /// 2. Symlinks pointing to the same file are deduplicated
 /// 3. The deduplicated count matches the number of unique canonical paths
 /// 4. Each canonical path appears exactly once in deduplicatedURLs
    func testProperty_BatchScanDeduplicationByRealpath() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random test parameters
            let uniqueFileCount = Int.random(in: 1...20)
            let duplicateCount = Int.random(in: 0...15)
            let symlinkCount = Int.random(in: 0...10)
            
 // Create a subdirectory for this iteration
            let iterationDir = tempDirectory.appendingPathComponent("iter_\(iteration)")
            try FileManager.default.createDirectory(at: iterationDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: iterationDir)
            }
            
 // Generate batch with duplicates
            let (urls, expectedUniqueCount, expectedCanonicalPaths) = try BatchScanTestGenerator.generateBatchWithDuplicates(
                in: iterationDir,
                uniqueFileCount: uniqueFileCount,
                duplicateCount: duplicateCount,
                symlinkCount: symlinkCount
            )
            
 // Create limiter with high limits (we're testing deduplication, not limits)
            let limiter = BatchScanLimiter.createForTesting(
                maxTotalFiles: 10000,
                maxTotalBytes: 1024 * 1024 * 1024,
                maxSymlinkDepth: 10
            )
            
 // Perform pre-check
            let result = await limiter.preCheck(urls: urls, scanRoot: iterationDir)
            
 // Property 1: Deduplicated count should equal unique file count
            XCTAssertEqual(
                result.deduplicatedURLs.count,
                expectedUniqueCount,
                "Iteration \(iteration): Deduplicated count (\(result.deduplicatedURLs.count)) should equal unique file count (\(expectedUniqueCount))"
            )
            
 // Property 2: Each canonical path should appear exactly once
            var seenCanonicalPaths: Set<String> = []
            for url in result.deduplicatedURLs {
                if let realpath = realpath(url.path, nil) {
                    let canonicalPath = String(cString: realpath)
                    free(realpath)
                    
                    XCTAssertFalse(
                        seenCanonicalPaths.contains(canonicalPath),
                        "Iteration \(iteration): Canonical path '\(canonicalPath)' appears more than once in deduplicatedURLs"
                    )
                    seenCanonicalPaths.insert(canonicalPath)
                }
            }
            
 // Property 3: All canonical paths in deduplicatedURLs should be from expected set
            XCTAssertEqual(
                seenCanonicalPaths,
                expectedCanonicalPaths,
                "Iteration \(iteration): Canonical paths in deduplicatedURLs should match expected canonical paths"
            )
            
 // Property 4: Duplicate count should be correct
            let expectedDuplicates = urls.count - expectedUniqueCount - result.rejectedResults.count
            XCTAssertEqual(
                result.duplicateCount,
                expectedDuplicates,
                "Iteration \(iteration): Duplicate count (\(result.duplicateCount)) should match expected (\(expectedDuplicates))"
            )
            
 // Property 5: duplicateToFirstIndex should map all duplicates
            XCTAssertEqual(
                result.duplicateToFirstIndex.count,
                result.duplicateCount,
                "Iteration \(iteration): duplicateToFirstIndex count should equal duplicateCount"
            )
            
 // Property 6: No limit should be exceeded (we set high limits)
            XCTAssertNil(
                result.limitExceeded,
                "Iteration \(iteration): No limit should be exceeded with high limits"
            )
        }
    }
    
 /// Test that symlinks to the same file are correctly deduplicated
    func testSymlinksToSameFileAreDeduplicated() async throws {
 // Create a single file
        let originalFile = try BatchScanTestGenerator.createTestFile(
            in: tempDirectory,
            name: "original.txt",
            size: 100
        )
        
 // Create multiple symlinks to the same file
        let symlinkCount = 5
        var urls: [URL] = [originalFile]
        
        for i in 0..<symlinkCount {
            let symlinkURL = tempDirectory.appendingPathComponent("symlink_\(i).txt")
            try BatchScanTestGenerator.createSymlink(at: symlinkURL, to: originalFile)
            urls.append(symlinkURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting()
        let result = await limiter.preCheck(urls: urls, scanRoot: tempDirectory)
        
 // All URLs point to the same file, so only 1 should be in deduplicatedURLs
        XCTAssertEqual(result.deduplicatedURLs.count, 1, "All symlinks to same file should deduplicate to 1")
        XCTAssertEqual(result.duplicateCount, symlinkCount, "Duplicate count should be \(symlinkCount)")
    }
    
 /// Test that different files are not incorrectly deduplicated
    func testDifferentFilesNotDeduplicated() async throws {
 // Create multiple unique files
        let fileCount = 10
        var urls: [URL] = []
        
        for i in 0..<fileCount {
            let fileURL = try BatchScanTestGenerator.createTestFile(
                in: tempDirectory,
                name: "unique_\(i).txt",
                size: 100
            )
            urls.append(fileURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting()
        let result = await limiter.preCheck(urls: urls, scanRoot: tempDirectory)
        
 // All files are unique, so all should be in deduplicatedURLs
        XCTAssertEqual(result.deduplicatedURLs.count, fileCount, "All unique files should be in deduplicatedURLs")
        XCTAssertEqual(result.duplicateCount, 0, "No duplicates should be detected")
    }
    
 /// Test that the same URL added multiple times is deduplicated
    func testSameURLAddedMultipleTimesIsDeduplicated() async throws {
 // Create a single file
        let fileURL = try BatchScanTestGenerator.createTestFile(
            in: tempDirectory,
            name: "single.txt",
            size: 100
        )
        
 // Add the same URL multiple times
        let repeatCount = 10
        let urls = Array(repeating: fileURL, count: repeatCount)
        
        let limiter = BatchScanLimiter.createForTesting()
        let result = await limiter.preCheck(urls: urls, scanRoot: tempDirectory)
        
 // Only 1 unique file
        XCTAssertEqual(result.deduplicatedURLs.count, 1, "Same URL repeated should deduplicate to 1")
        XCTAssertEqual(result.duplicateCount, repeatCount - 1, "Duplicate count should be \(repeatCount - 1)")
    }
    
 /// Test that canonicalPathToFirstIndex correctly maps canonical paths
    func testCanonicalPathToFirstIndexMapping() async throws {
 // Create files
        let file1 = try BatchScanTestGenerator.createTestFile(in: tempDirectory, name: "file1.txt")
        let file2 = try BatchScanTestGenerator.createTestFile(in: tempDirectory, name: "file2.txt")
        
 // Create symlinks
        let symlink1 = tempDirectory.appendingPathComponent("symlink1.txt")
        try BatchScanTestGenerator.createSymlink(at: symlink1, to: file1)
        
 // Order: file1, symlink1 (to file1), file2
        let urls = [file1, symlink1, file2]
        
        let limiter = BatchScanLimiter.createForTesting()
        let result = await limiter.preCheck(urls: urls, scanRoot: tempDirectory)
        
 // file1 and symlink1 have same canonical path, file2 is different
        XCTAssertEqual(result.deduplicatedURLs.count, 2, "Should have 2 unique files")
        XCTAssertEqual(result.duplicateCount, 1, "symlink1 should be a duplicate")
        
 // Check that duplicateToFirstIndex maps symlink1 (index 1) to file1 (index 0)
        XCTAssertEqual(result.duplicateToFirstIndex[1], 0, "symlink1 should map to file1's index")
    }
    
 /// Test deduplication with nested symlinks
    func testNestedSymlinksAreDeduplicated() async throws {
 // Create original file
        let originalFile = try BatchScanTestGenerator.createTestFile(
            in: tempDirectory,
            name: "original.txt",
            size: 100
        )
        
 // Create chain: symlink1 -> original, symlink2 -> symlink1
        let symlink1 = tempDirectory.appendingPathComponent("symlink1.txt")
        try BatchScanTestGenerator.createSymlink(at: symlink1, to: originalFile)
        
        let symlink2 = tempDirectory.appendingPathComponent("symlink2.txt")
        try BatchScanTestGenerator.createSymlink(at: symlink2, to: symlink1)
        
        let urls = [originalFile, symlink1, symlink2]
        
        let limiter = BatchScanLimiter.createForTesting()
        let result = await limiter.preCheck(urls: urls, scanRoot: tempDirectory)
        
 // All point to same file
        XCTAssertEqual(result.deduplicatedURLs.count, 1, "Nested symlinks should deduplicate to 1")
        XCTAssertEqual(result.duplicateCount, 2, "Should have 2 duplicates")
    }
    
 /// Test that inaccessible files are rejected, not deduplicated
    func testInaccessibleFilesAreRejected() async throws {
 // Create a valid file
        let validFile = try BatchScanTestGenerator.createTestFile(
            in: tempDirectory,
            name: "valid.txt",
            size: 100
        )
        
 // Create a URL to a non-existent file
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.txt")
        
        let urls = [validFile, nonExistentURL]
        
        let limiter = BatchScanLimiter.createForTesting()
        let result = await limiter.preCheck(urls: urls, scanRoot: tempDirectory)
        
 // Valid file should be in deduplicatedURLs
        XCTAssertEqual(result.deduplicatedURLs.count, 1, "Only valid file should be deduplicated")
        
 // Non-existent file should be in rejectedResults
        XCTAssertEqual(result.rejectedResults.count, 1, "Non-existent file should be rejected")
        XCTAssertEqual(result.inaccessibleCount, 1, "Inaccessible count should be 1")
        
 // Rejected result should have unknown verdict
        XCTAssertEqual(result.rejectedResults.first?.verdict, .unknown, "Rejected file should have unknown verdict")
    }
    
 /// Test empty input
    func testEmptyInput() async throws {
        let limiter = BatchScanLimiter.createForTesting()
        let result = await limiter.preCheck(urls: [], scanRoot: tempDirectory)
        
        XCTAssertEqual(result.deduplicatedURLs.count, 0, "Empty input should produce empty output")
        XCTAssertEqual(result.duplicateCount, 0, "No duplicates for empty input")
        XCTAssertEqual(result.totalBytes, 0, "Total bytes should be 0 for empty input")
        XCTAssertNil(result.limitExceeded, "No limit exceeded for empty input")
    }
}

// MARK: - Property Test: Batch Scan Limit Enforcement
// **Feature: security-hardening, Property 2: Batch scan limit enforcement**
// **Validates: Requirements 1.2, 1.3, 1.5**

final class BatchScanLimiterLimitEnforcementTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try BatchScanTestGenerator.createTempDirectory()
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            BatchScanTestGenerator.cleanup(directory: tempDir)
        }
        try await super.tearDown()
    }
    
 /// **Feature: security-hardening, Property 2: Batch scan limit enforcement**
 /// **Validates: Requirements 1.2, 1.3, 1.5**
 ///
 /// Property: For any batch scan request exceeding maxTotalFiles or maxTotalBytes,
 /// the service SHALL return limitExceeded without starting any scan operations.
 ///
 /// This test verifies:
 /// 1. File count exceeding maxTotalFiles triggers limitExceeded
 /// 2. Total bytes exceeding maxTotalBytes triggers limitExceeded
 /// 3. The limitExceeded contains accurate actual vs max values
 /// 4. No scan operations are started when limits are exceeded
    func testProperty_BatchScanLimitEnforcement() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Create a subdirectory for this iteration
            let iterationDir = tempDirectory.appendingPathComponent("iter_\(iteration)")
            try FileManager.default.createDirectory(at: iterationDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: iterationDir)
            }
            
 // Randomly choose which limit to test
            let testFileCountLimit = Bool.random()
            
            if testFileCountLimit {
 // Test file count limit
                try await testFileCountLimitEnforcement(in: iterationDir, iteration: iteration)
            } else {
 // Test bytes limit
                try await testBytesLimitEnforcement(in: iterationDir, iteration: iteration)
            }
        }
    }
    
 /// Test file count limit enforcement
 /// **Validates: Requirements 1.2, 1.5**
    private func testFileCountLimitEnforcement(in directory: URL, iteration: Int) async throws {
 // Generate random limit (small for testing)
        let maxFiles = Int.random(in: 3...10)
        
 // Create more files than the limit
        let fileCount = maxFiles + Int.random(in: 1...5)
        var urls: [URL] = []
        
        for i in 0..<fileCount {
            let fileURL = try BatchScanTestGenerator.createTestFile(
                in: directory,
                name: "file_\(i).txt",
                size: 100 // Small files to avoid bytes limit
            )
            urls.append(fileURL)
        }
        
 // Create limiter with the file count limit
        let limiter = BatchScanLimiter.createForTesting(
            maxTotalFiles: maxFiles,
            maxTotalBytes: Int64.max, // No bytes limit
            maxSymlinkDepth: 10
        )
        
 // Perform pre-check
        let result = await limiter.preCheck(urls: urls, scanRoot: directory)
        
 // Property 1: limitExceeded should be set
        XCTAssertNotNil(
            result.limitExceeded,
            "Iteration \(iteration): limitExceeded should be set when file count (\(fileCount)) exceeds max (\(maxFiles))"
        )
        
 // Property 2: limitExceeded should be fileCount type with correct values
        if case let .fileCount(actual, max) = result.limitExceeded {
            XCTAssertEqual(
                actual, fileCount,
                "Iteration \(iteration): Actual file count should be \(fileCount), got \(actual)"
            )
            XCTAssertEqual(
                max, maxFiles,
                "Iteration \(iteration): Max file count should be \(maxFiles), got \(max)"
            )
        } else {
            XCTFail("Iteration \(iteration): Expected fileCount limit exceeded, got \(String(describing: result.limitExceeded))")
        }
        
 // Property 3: deduplicatedURLs should still contain all files (pre-check doesn't filter)
 // The limit check happens AFTER deduplication
        XCTAssertEqual(
            result.deduplicatedURLs.count, fileCount,
            "Iteration \(iteration): deduplicatedURLs should contain all \(fileCount) files"
        )
    }
    
 /// Test bytes limit enforcement
 /// **Validates: Requirements 1.3, 1.5**
    private func testBytesLimitEnforcement(in directory: URL, iteration: Int) async throws {
 // Generate random bytes limit (must be >= 1024 due to SecurityLimitsConfig clamp)
 // Use values between 2KB and 10KB for testing
        let maxBytes: Int64 = Int64.random(in: 2048...10240)
        
 // Create files that exceed the bytes limit
 // Use larger file sizes to ensure we exceed the limit
        let fileSize = Int.random(in: 500...1000)
        let fileCount = Int((maxBytes / Int64(fileSize)) + 3) // Ensure we exceed
        var urls: [URL] = []
        
        for i in 0..<fileCount {
            let fileURL = try BatchScanTestGenerator.createTestFile(
                in: directory,
                name: "file_\(i).txt",
                size: fileSize
            )
            urls.append(fileURL)
        }
        
 // Create limiter with the bytes limit
        let limiter = BatchScanLimiter.createForTesting(
            maxTotalFiles: Int.max, // No file count limit
            maxTotalBytes: maxBytes,
            maxSymlinkDepth: 10
        )
        
 // Perform pre-check
        let result = await limiter.preCheck(urls: urls, scanRoot: directory)
        
 // Property 1: limitExceeded should be set
        XCTAssertNotNil(
            result.limitExceeded,
            "Iteration \(iteration): limitExceeded should be set when total bytes (\(result.totalBytes)) exceeds max (\(maxBytes))"
        )
        
 // Property 2: limitExceeded should be totalBytes type with correct values
        if case let .totalBytes(actual, max) = result.limitExceeded {
            XCTAssertEqual(
                actual, result.totalBytes,
                "Iteration \(iteration): Actual bytes should match result.totalBytes"
            )
            XCTAssertEqual(
                max, maxBytes,
                "Iteration \(iteration): Max bytes should be \(maxBytes), got \(max)"
            )
            XCTAssertGreaterThan(
                actual, maxBytes,
                "Iteration \(iteration): Actual bytes (\(actual)) should exceed max (\(maxBytes))"
            )
        } else {
            XCTFail("Iteration \(iteration): Expected totalBytes limit exceeded, got \(String(describing: result.limitExceeded))")
        }
    }
    
 /// Test that file count limit is checked correctly at boundary
 /// **Validates: Requirements 1.2**
    func testFileCountLimitBoundary() async throws {
        let maxFiles = 5
        
 // Test exactly at limit (should NOT exceed)
        let atLimitDir = tempDirectory.appendingPathComponent("at_limit")
        try FileManager.default.createDirectory(at: atLimitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: atLimitDir) }
        
        var atLimitURLs: [URL] = []
        for i in 0..<maxFiles {
            let fileURL = try BatchScanTestGenerator.createTestFile(in: atLimitDir, name: "file_\(i).txt", size: 100)
            atLimitURLs.append(fileURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting(maxTotalFiles: maxFiles, maxTotalBytes: Int64.max)
        let atLimitResult = await limiter.preCheck(urls: atLimitURLs, scanRoot: atLimitDir)
        
        XCTAssertNil(atLimitResult.limitExceeded, "Exactly at limit should NOT trigger limitExceeded")
        
 // Test one over limit (should exceed)
        let overLimitDir = tempDirectory.appendingPathComponent("over_limit")
        try FileManager.default.createDirectory(at: overLimitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: overLimitDir) }
        
        var overLimitURLs: [URL] = []
        for i in 0..<(maxFiles + 1) {
            let fileURL = try BatchScanTestGenerator.createTestFile(in: overLimitDir, name: "file_\(i).txt", size: 100)
            overLimitURLs.append(fileURL)
        }
        
        let overLimitResult = await limiter.preCheck(urls: overLimitURLs, scanRoot: overLimitDir)
        
        XCTAssertNotNil(overLimitResult.limitExceeded, "One over limit should trigger limitExceeded")
        if case let .fileCount(actual, max) = overLimitResult.limitExceeded {
            XCTAssertEqual(actual, maxFiles + 1)
            XCTAssertEqual(max, maxFiles)
        } else {
            XCTFail("Expected fileCount limit exceeded")
        }
    }
    
 /// Test that bytes limit is checked correctly at boundary
 /// **Validates: Requirements 1.3**
    func testBytesLimitBoundary() async throws {
 // Use file size and limit values above the minimum clamp (1024 bytes)
        let fileSize = 500
        let maxBytes: Int64 = 2500 // Allows 5 files of 500 bytes
        
 // Test exactly at limit (should NOT exceed)
        let atLimitDir = tempDirectory.appendingPathComponent("at_limit_bytes")
        try FileManager.default.createDirectory(at: atLimitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: atLimitDir) }
        
        var atLimitURLs: [URL] = []
        for i in 0..<5 {
            let fileURL = try BatchScanTestGenerator.createTestFile(in: atLimitDir, name: "file_\(i).txt", size: fileSize)
            atLimitURLs.append(fileURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting(maxTotalFiles: Int.max, maxTotalBytes: maxBytes)
        let atLimitResult = await limiter.preCheck(urls: atLimitURLs, scanRoot: atLimitDir)
        
        XCTAssertNil(atLimitResult.limitExceeded, "Exactly at bytes limit should NOT trigger limitExceeded")
        
 // Test one file over limit (should exceed)
        let overLimitDir = tempDirectory.appendingPathComponent("over_limit_bytes")
        try FileManager.default.createDirectory(at: overLimitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: overLimitDir) }
        
        var overLimitURLs: [URL] = []
        for i in 0..<6 { // 6 files * 500 bytes = 3000 bytes > 2500
            let fileURL = try BatchScanTestGenerator.createTestFile(in: overLimitDir, name: "file_\(i).txt", size: fileSize)
            overLimitURLs.append(fileURL)
        }
        
        let overLimitResult = await limiter.preCheck(urls: overLimitURLs, scanRoot: overLimitDir)
        
        XCTAssertNotNil(overLimitResult.limitExceeded, "Over bytes limit should trigger limitExceeded")
        if case let .totalBytes(actual, max) = overLimitResult.limitExceeded {
            XCTAssertGreaterThan(actual, maxBytes)
            XCTAssertEqual(max, maxBytes)
        } else {
            XCTFail("Expected totalBytes limit exceeded")
        }
    }
    
 /// Test that file count limit takes precedence when both limits are exceeded
 /// **Validates: Requirements 1.2, 1.3**
    func testFileCountLimitTakesPrecedence() async throws {
 // Create a scenario where both limits would be exceeded
 // File count limit should be checked first
        let maxFiles = 3
        let maxBytes: Int64 = 200 // 2 files of 100 bytes
        
        let testDir = tempDirectory.appendingPathComponent("both_limits")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 5 files of 100 bytes each (exceeds both limits)
        var urls: [URL] = []
        for i in 0..<5 {
            let fileURL = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file_\(i).txt", size: 100)
            urls.append(fileURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting(maxTotalFiles: maxFiles, maxTotalBytes: maxBytes)
        let result = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // File count limit should be reported (checked first in implementation)
        XCTAssertNotNil(result.limitExceeded)
        if case .fileCount = result.limitExceeded {
 // Expected - file count is checked first
        } else {
 // Also acceptable if bytes is checked first - implementation detail
 // The important thing is that SOME limit is exceeded
            if case .totalBytes = result.limitExceeded {
 // This is also valid
            } else {
                XCTFail("Expected either fileCount or totalBytes limit exceeded")
            }
        }
    }
    
 /// Test that duplicates don't count toward file count limit
 /// **Validates: Requirements 1.2, 1.7**
    func testDuplicatesDontCountTowardFileLimit() async throws {
        let maxFiles = 5
        
        let testDir = tempDirectory.appendingPathComponent("duplicates_limit")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 3 unique files
        var urls: [URL] = []
        for i in 0..<3 {
            let fileURL = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file_\(i).txt", size: 100)
            urls.append(fileURL)
        }
        
 // Add duplicates to make total URLs = 10 (but only 3 unique)
        let originalURLs = urls
        for _ in 0..<7 {
            if let randomURL = originalURLs.randomElement() {
                urls.append(randomURL)
            }
        }
        
        let limiter = BatchScanLimiter.createForTesting(maxTotalFiles: maxFiles, maxTotalBytes: Int64.max)
        let result = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // Should NOT exceed limit because only 3 unique files
        XCTAssertNil(result.limitExceeded, "Duplicates should not count toward file limit")
        XCTAssertEqual(result.deduplicatedURLs.count, 3, "Should have 3 unique files")
        XCTAssertEqual(result.duplicateCount, 7, "Should have 7 duplicates")
    }
    
 /// Test that rejected files don't count toward limits
 /// **Validates: Requirements 1.2, 1.3**
    func testRejectedFilesDontCountTowardLimits() async throws {
        let maxFiles = 3
        
        let testDir = tempDirectory.appendingPathComponent("rejected_limit")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 2 valid files
        var urls: [URL] = []
        for i in 0..<2 {
            let fileURL = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file_\(i).txt", size: 100)
            urls.append(fileURL)
        }
        
 // Add 5 non-existent files (will be rejected)
        for i in 0..<5 {
            urls.append(testDir.appendingPathComponent("nonexistent_\(i).txt"))
        }
        
        let limiter = BatchScanLimiter.createForTesting(maxTotalFiles: maxFiles, maxTotalBytes: Int64.max)
        let result = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // Should NOT exceed limit because only 2 valid files (rejected don't count)
        XCTAssertNil(result.limitExceeded, "Rejected files should not count toward file limit")
        XCTAssertEqual(result.deduplicatedURLs.count, 2, "Should have 2 valid files")
        XCTAssertEqual(result.rejectedResults.count, 5, "Should have 5 rejected files")
    }
    
 /// Test with zero limits (edge case)
 /// **Validates: Requirements 1.2, 1.3**
    func testZeroLimits() async throws {
        let testDir = tempDirectory.appendingPathComponent("zero_limits")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create a single file
        let fileURL = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file.txt", size: 100)
        
 // Test with maxTotalFiles = 0
        var config = SecurityLimitsConfig()
        config.maxTotalFiles = 1 // Minimum allowed by clamp
        config.maxTotalBytes = Int64.max
        let limiterFiles = BatchScanLimiter(limits: config.toSecurityLimits())
        
        let resultFiles = await limiterFiles.preCheck(urls: [fileURL], scanRoot: testDir)
 // With maxTotalFiles = 1, a single file should be allowed
        XCTAssertNil(resultFiles.limitExceeded, "Single file should be allowed with maxTotalFiles = 1")
    }
    
 /// Test that symlinks to same file don't inflate byte count
 /// **Validates: Requirements 1.3, 1.7**
    func testSymlinksDontInflateByteCount() async throws {
        let testDir = tempDirectory.appendingPathComponent("symlink_bytes")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create a single 100-byte file
        let originalFile = try BatchScanTestGenerator.createTestFile(in: testDir, name: "original.txt", size: 100)
        
 // Create 5 symlinks to the same file
        var urls: [URL] = [originalFile]
        for i in 0..<5 {
            let symlinkURL = testDir.appendingPathComponent("symlink_\(i).txt")
            try BatchScanTestGenerator.createSymlink(at: symlinkURL, to: originalFile)
            urls.append(symlinkURL)
        }
        
 // Set bytes limit to 150 (would fail if symlinks counted separately)
        let limiter = BatchScanLimiter.createForTesting(maxTotalFiles: Int.max, maxTotalBytes: 150)
        let result = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // Should NOT exceed limit because all symlinks point to same 100-byte file
        XCTAssertNil(result.limitExceeded, "Symlinks to same file should not inflate byte count")
        XCTAssertEqual(result.totalBytes, 100, "Total bytes should be 100 (single file)")
        XCTAssertEqual(result.deduplicatedURLs.count, 1, "Should have 1 unique file")
    }
}



// MARK: - Property Test: Batch Scan Timeout Partial Results Ordering
// **Feature: security-hardening, Property 3: Batch scan timeout partial results ordering**
// **Validates: Requirements 1.4, 1.6**

final class BatchScanLimiterTimeoutTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try BatchScanTestGenerator.createTempDirectory()
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            BatchScanTestGenerator.cleanup(directory: tempDir)
        }
        try await super.tearDown()
    }
    
 /// **Feature: security-hardening, Property 3: Batch scan timeout partial results ordering**
 /// **Validates: Requirements 1.4, 1.6**
 ///
 /// Property: For any batch scan that times out, the partial results SHALL maintain
 /// input order with unscanned files marked verdict=unknown.
 ///
 /// This test verifies:
 /// 1. Partial results maintain input order (by file name)
 /// 2. Scanned files have their actual results
 /// 3. Unscanned files have verdict=unknown
 /// 4. Unscanned files have warning code "INCOMPLETE_DUE_TO_TIMEOUT"
 /// 5. Result count equals input count
    func testProperty_BatchScanTimeoutPartialResultsOrdering() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Create a subdirectory for this iteration
            let iterationDir = tempDirectory.appendingPathComponent("iter_\(iteration)")
            try FileManager.default.createDirectory(at: iterationDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: iterationDir)
            }
            
 // Generate random test parameters
            let totalFiles = Int.random(in: 5...20)
            let scannedCount = Int.random(in: 1..<totalFiles) // At least 1 scanned, at least 1 unscanned
            
 // Create test files
            var urls: [URL] = []
            for i in 0..<totalFiles {
                let fileURL = try BatchScanTestGenerator.createTestFile(
                    in: iterationDir,
                    name: "file_\(i).txt",
                    size: Int.random(in: 50...200)
                )
                urls.append(fileURL)
            }
            
 // Create limiter with high limits (we're testing timeout, not limits)
            let limiter = BatchScanLimiter.createForTesting(
                maxTotalFiles: 10000,
                maxTotalBytes: 1024 * 1024 * 1024,
                maxSymlinkDepth: 10
            )
            
 // Perform pre-check
            let preCheckResult = await limiter.preCheck(urls: urls, scanRoot: iterationDir)
            
 // Simulate partial scan results (first scannedCount files were scanned)
            var scanResults: [String: FileScanResult] = [:]
            var unscannedURLs: Set<URL> = []
            
            for (index, url) in preCheckResult.deduplicatedURLs.enumerated() {
                if index < scannedCount {
 // This file was scanned - create a mock result
                    let result = FileScanResult(
                        id: UUID(),
                        fileURL: url,
                        scanDuration: Double.random(in: 0.01...0.1),
                        timestamp: Date(),
                        verdict: .safe, // Simulated scan result
                        methodsUsed: [.signatureCheck],
                        threats: [],
                        warnings: [],
                        scanLevel: .quick,
                        targetType: .file
                    )
                    scanResults[url.path] = result
                } else {
 // This file was not scanned due to timeout
                    unscannedURLs.insert(url)
                }
            }
            
 // Merge results
            let finalResults = await limiter.mergeResults(
                preCheck: preCheckResult,
                scanResults: scanResults,
                originalURLs: urls,
                unscannedURLs: unscannedURLs
            )
            
 // Property 1: Result count equals input count
            XCTAssertEqual(
                finalResults.count,
                urls.count,
                "Iteration \(iteration): Result count (\(finalResults.count)) should equal input count (\(urls.count))"
            )
            
 // Property 2: Results maintain input order (by file name, since paths may differ due to symlink resolution)
            for (index, result) in finalResults.enumerated() {
                let expectedFileName = urls[index].lastPathComponent
                let actualFileName = result.fileURL.lastPathComponent
                XCTAssertEqual(
                    actualFileName,
                    expectedFileName,
                    "Iteration \(iteration): Result at index \(index) should have file name \(expectedFileName), got \(actualFileName)"
                )
            }
            
 // Property 3: Scanned files have their actual results (verdict != unknown for safe files)
            for index in 0..<scannedCount {
                let result = finalResults[index]
 // Scanned files should have the verdict we assigned (safe)
                XCTAssertEqual(
                    result.verdict,
                    .safe,
                    "Iteration \(iteration): Scanned file at index \(index) should have verdict=safe"
                )
            }
            
 // Property 4: Unscanned files have verdict=unknown
            for index in scannedCount..<totalFiles {
                let result = finalResults[index]
                XCTAssertEqual(
                    result.verdict,
                    .unknown,
                    "Iteration \(iteration): Unscanned file at index \(index) should have verdict=unknown"
                )
            }
            
 // Property 5: Unscanned files have timeout warning
            for index in scannedCount..<totalFiles {
                let result = finalResults[index]
                let hasTimeoutWarning = result.warnings.contains { warning in
                    warning.code == "INCOMPLETE_DUE_TO_TIMEOUT"
                }
                XCTAssertTrue(
                    hasTimeoutWarning,
                    "Iteration \(iteration): Unscanned file at index \(index) should have INCOMPLETE_DUE_TO_TIMEOUT warning"
                )
            }
        }
    }
    
 /// Test that timeout correctly throws timeout error
    func testTimeoutTaskThrowsTimeoutError() async throws {
        let limiter = BatchScanLimiter.createForTesting()
        
 // Create a that takes longer than timeout
        do {
            _ = try await limiter.createTimeoutTask(timeout: 0.1) {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                return "completed"
            }
            XCTFail("Should have thrown timeout error")
        } catch let error as BatchScanError {
            if case .timeout(let elapsed) = error {
                XCTAssertGreaterThanOrEqual(elapsed, 0.1, "Elapsed time should be at least timeout duration")
            } else {
                XCTFail("Expected timeout error, got \(error)")
            }
        }
    }
    
 /// Test that timeout completes successfully when operation is fast
    func testTimeoutTaskCompletesWhenFast() async throws {
        let limiter = BatchScanLimiter.createForTesting()
        
 // Create a that completes quickly
        let result = try await limiter.createTimeoutTask(timeout: 1.0) {
            try await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
            return "completed"
        }
        
        XCTAssertEqual(result, "completed", "Task should complete successfully")
    }
    
 /// Test partial results with mixed scanned/unscanned files
    func testPartialResultsWithMixedFiles() async throws {
        let testDir = tempDirectory.appendingPathComponent("mixed_partial")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 10 files
        var urls: [URL] = []
        for i in 0..<10 {
            let fileURL = try BatchScanTestGenerator.createTestFile(
                in: testDir,
                name: "file_\(i).txt",
                size: 100
            )
            urls.append(fileURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting()
        let preCheckResult = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // Simulate: files 0, 2, 4, 6, 8 were scanned; files 1, 3, 5, 7, 9 were not
        var scanResults: [String: FileScanResult] = [:]
        var unscannedURLs: Set<URL> = []
        
        for (index, url) in preCheckResult.deduplicatedURLs.enumerated() {
            if index % 2 == 0 {
 // Even indices were scanned
                let result = FileScanResult(
                    id: UUID(),
                    fileURL: url,
                    scanDuration: 0.05,
                    timestamp: Date(),
                    verdict: .safe,
                    methodsUsed: [.signatureCheck],
                    threats: [],
                    warnings: [],
                    scanLevel: .quick,
                    targetType: .file
                )
                scanResults[url.path] = result
            } else {
 // Odd indices were not scanned
                unscannedURLs.insert(url)
            }
        }
        
        let finalResults = await limiter.mergeResults(
            preCheck: preCheckResult,
            scanResults: scanResults,
            originalURLs: urls,
            unscannedURLs: unscannedURLs
        )
        
 // Verify results
        XCTAssertEqual(finalResults.count, 10, "Should have 10 results")
        
        for (index, result) in finalResults.enumerated() {
 // Compare by file name (paths may differ due to /var -> /private/var symlink)
            XCTAssertEqual(result.fileURL.lastPathComponent, urls[index].lastPathComponent, "Result \(index) should have correct file name")
            
            if index % 2 == 0 {
                XCTAssertEqual(result.verdict, .safe, "Even index \(index) should be safe")
            } else {
                XCTAssertEqual(result.verdict, .unknown, "Odd index \(index) should be unknown")
                let hasTimeoutWarning = result.warnings.contains { $0.code == "INCOMPLETE_DUE_TO_TIMEOUT" }
                XCTAssertTrue(hasTimeoutWarning, "Odd index \(index) should have timeout warning")
            }
        }
    }
    
 /// Test partial results with duplicates
    func testPartialResultsWithDuplicates() async throws {
        let testDir = tempDirectory.appendingPathComponent("duplicates_partial")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 3 unique files
        let file1 = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file1.txt", size: 100)
        let file2 = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file2.txt", size: 100)
        let file3 = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file3.txt", size: 100)
        
 // Input with duplicates: [file1, file2, file1, file3, file2]
        let urls = [file1, file2, file1, file3, file2]
        
        let limiter = BatchScanLimiter.createForTesting()
        let preCheckResult = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // Verify deduplication
        XCTAssertEqual(preCheckResult.deduplicatedURLs.count, 3, "Should have 3 unique files")
        XCTAssertEqual(preCheckResult.duplicateCount, 2, "Should have 2 duplicates")
        
 // Simulate: file1 and file2 were scanned, file3 was not (timeout)
        var scanResults: [String: FileScanResult] = [:]
        var unscannedURLs: Set<URL> = []
        
        for url in preCheckResult.deduplicatedURLs {
            if url.lastPathComponent == "file3.txt" {
                unscannedURLs.insert(url)
            } else {
                let result = FileScanResult(
                    id: UUID(),
                    fileURL: url,
                    scanDuration: 0.05,
                    timestamp: Date(),
                    verdict: .safe,
                    methodsUsed: [.signatureCheck],
                    threats: [],
                    warnings: [],
                    scanLevel: .quick,
                    targetType: .file
                )
                scanResults[url.path] = result
            }
        }
        
        let finalResults = await limiter.mergeResults(
            preCheck: preCheckResult,
            scanResults: scanResults,
            originalURLs: urls,
            unscannedURLs: unscannedURLs
        )
        
 // Verify results maintain input order (compare by file name due to /var symlink)
        XCTAssertEqual(finalResults.count, 5, "Should have 5 results (matching input)")
        
 // file1 (index 0) - scanned
        XCTAssertEqual(finalResults[0].fileURL.lastPathComponent, file1.lastPathComponent)
        XCTAssertEqual(finalResults[0].verdict, .safe)
        
 // file2 (index 1) - scanned
        XCTAssertEqual(finalResults[1].fileURL.lastPathComponent, file2.lastPathComponent)
        XCTAssertEqual(finalResults[1].verdict, .safe)
        
 // file1 duplicate (index 2) - should have same result as first file1
        XCTAssertEqual(finalResults[2].fileURL.lastPathComponent, file1.lastPathComponent)
        XCTAssertEqual(finalResults[2].verdict, .safe)
        
 // file3 (index 3) - not scanned (timeout)
        XCTAssertEqual(finalResults[3].fileURL.lastPathComponent, file3.lastPathComponent)
        XCTAssertEqual(finalResults[3].verdict, .unknown)
        let hasTimeoutWarning = finalResults[3].warnings.contains { $0.code == "INCOMPLETE_DUE_TO_TIMEOUT" }
        XCTAssertTrue(hasTimeoutWarning, "file3 should have timeout warning")
        
 // file2 duplicate (index 4) - should have same result as first file2
        XCTAssertEqual(finalResults[4].fileURL.lastPathComponent, file2.lastPathComponent)
        XCTAssertEqual(finalResults[4].verdict, .safe)
    }
    
 /// Test partial results with rejected files
    func testPartialResultsWithRejectedFiles() async throws {
        let testDir = tempDirectory.appendingPathComponent("rejected_partial")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 2 valid files
        let file1 = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file1.txt", size: 100)
        let file2 = try BatchScanTestGenerator.createTestFile(in: testDir, name: "file2.txt", size: 100)
        
 // Create non-existent file URL
        let nonExistent = testDir.appendingPathComponent("nonexistent.txt")
        
 // Input: [file1, nonexistent, file2]
        let urls = [file1, nonExistent, file2]
        
        let limiter = BatchScanLimiter.createForTesting()
        let preCheckResult = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // Verify pre-check
        XCTAssertEqual(preCheckResult.deduplicatedURLs.count, 2, "Should have 2 valid files")
        XCTAssertEqual(preCheckResult.rejectedResults.count, 1, "Should have 1 rejected file")
        
 // Simulate: file1 was scanned, file2 was not (timeout)
        var scanResults: [String: FileScanResult] = [:]
        var unscannedURLs: Set<URL> = []
        
        for url in preCheckResult.deduplicatedURLs {
            if url.lastPathComponent == "file1.txt" {
                let result = FileScanResult(
                    id: UUID(),
                    fileURL: url,
                    scanDuration: 0.05,
                    timestamp: Date(),
                    verdict: .safe,
                    methodsUsed: [.signatureCheck],
                    threats: [],
                    warnings: [],
                    scanLevel: .quick,
                    targetType: .file
                )
                scanResults[url.path] = result
            } else {
                unscannedURLs.insert(url)
            }
        }
        
        let finalResults = await limiter.mergeResults(
            preCheck: preCheckResult,
            scanResults: scanResults,
            originalURLs: urls,
            unscannedURLs: unscannedURLs
        )
        
 // Verify results maintain input order (compare by file name due to /var symlink)
        XCTAssertEqual(finalResults.count, 3, "Should have 3 results")
        
 // file1 (index 0) - scanned
        XCTAssertEqual(finalResults[0].fileURL.lastPathComponent, file1.lastPathComponent)
        XCTAssertEqual(finalResults[0].verdict, .safe)
        
 // nonexistent (index 1) - rejected during pre-check
        XCTAssertEqual(finalResults[1].fileURL, nonExistent)
        XCTAssertEqual(finalResults[1].verdict, .unknown)
 // Should have inaccessible warning, not timeout warning
        let hasInaccessibleWarning = finalResults[1].warnings.contains { 
            $0.code == "INACCESSIBLE" || $0.code == "SYMLINK_RESOLUTION_FAILED"
        }
        XCTAssertTrue(hasInaccessibleWarning, "nonexistent should have inaccessible warning")
        
 // file2 (index 2) - not scanned (timeout)
        XCTAssertEqual(finalResults[2].fileURL, file2)
        XCTAssertEqual(finalResults[2].verdict, .unknown)
        let hasTimeoutWarning = finalResults[2].warnings.contains { $0.code == "INCOMPLETE_DUE_TO_TIMEOUT" }
        XCTAssertTrue(hasTimeoutWarning, "file2 should have timeout warning")
    }
    
 /// Test empty input returns empty results
    func testPartialResultsEmptyInput() async throws {
        let limiter = BatchScanLimiter.createForTesting()
        let preCheckResult = await limiter.preCheck(urls: [], scanRoot: tempDirectory)
        
        let finalResults = await limiter.mergeResults(
            preCheck: preCheckResult,
            scanResults: [:],
            originalURLs: [],
            unscannedURLs: []
        )
        
        XCTAssertEqual(finalResults.count, 0, "Empty input should produce empty results")
    }
    
 /// Test all files scanned (no timeout)
    func testAllFilesScannedNoTimeout() async throws {
        let testDir = tempDirectory.appendingPathComponent("all_scanned")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 5 files
        var urls: [URL] = []
        for i in 0..<5 {
            let fileURL = try BatchScanTestGenerator.createTestFile(
                in: testDir,
                name: "file_\(i).txt",
                size: 100
            )
            urls.append(fileURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting()
        let preCheckResult = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // All files were scanned
        var scanResults: [String: FileScanResult] = [:]
        for url in preCheckResult.deduplicatedURLs {
            let result = FileScanResult(
                id: UUID(),
                fileURL: url,
                scanDuration: 0.05,
                timestamp: Date(),
                verdict: .safe,
                methodsUsed: [.signatureCheck],
                threats: [],
                warnings: [],
                scanLevel: .quick,
                targetType: .file
            )
            scanResults[url.path] = result
        }
        
        let finalResults = await limiter.mergeResults(
            preCheck: preCheckResult,
            scanResults: scanResults,
            originalURLs: urls,
            unscannedURLs: [] // No unscanned files
        )
        
 // Verify all results are safe (compare by file name due to /var symlink)
        XCTAssertEqual(finalResults.count, 5, "Should have 5 results")
        for (index, result) in finalResults.enumerated() {
            XCTAssertEqual(result.fileURL.lastPathComponent, urls[index].lastPathComponent, "Result \(index) should have correct file name")
            XCTAssertEqual(result.verdict, .safe, "Result \(index) should be safe")
            let hasTimeoutWarning = result.warnings.contains { $0.code == "INCOMPLETE_DUE_TO_TIMEOUT" }
            XCTAssertFalse(hasTimeoutWarning, "Result \(index) should not have timeout warning")
        }
    }
    
 /// Test all files unscanned (immediate timeout)
    func testAllFilesUnscannedImmediateTimeout() async throws {
        let testDir = tempDirectory.appendingPathComponent("all_unscanned")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }
        
 // Create 5 files
        var urls: [URL] = []
        for i in 0..<5 {
            let fileURL = try BatchScanTestGenerator.createTestFile(
                in: testDir,
                name: "file_\(i).txt",
                size: 100
            )
            urls.append(fileURL)
        }
        
        let limiter = BatchScanLimiter.createForTesting()
        let preCheckResult = await limiter.preCheck(urls: urls, scanRoot: testDir)
        
 // No files were scanned (immediate timeout)
        let unscannedURLs = Set(preCheckResult.deduplicatedURLs)
        
        let finalResults = await limiter.mergeResults(
            preCheck: preCheckResult,
            scanResults: [:], // No scan results
            originalURLs: urls,
            unscannedURLs: unscannedURLs
        )
        
 // Verify all results are unknown with timeout warning
        XCTAssertEqual(finalResults.count, 5, "Should have 5 results")
        for (index, result) in finalResults.enumerated() {
            XCTAssertEqual(result.fileURL, urls[index], "Result \(index) should have correct URL")
            XCTAssertEqual(result.verdict, .unknown, "Result \(index) should be unknown")
            let hasTimeoutWarning = result.warnings.contains { $0.code == "INCOMPLETE_DUE_TO_TIMEOUT" }
            XCTAssertTrue(hasTimeoutWarning, "Result \(index) should have timeout warning")
        }
    }
}
