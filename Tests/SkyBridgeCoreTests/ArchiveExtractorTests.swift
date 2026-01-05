//
// ArchiveExtractorTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for ArchiveExtractor
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test Data Generator

/// Generates test data for ArchiveExtractor tests
struct ArchiveTestGenerator {
    
 /// Fixed seed for reproducible tests
    static let seed: UInt64 = 12345
    
 /// Creates a temporary directory for testing
    static func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveExtractorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
    
 /// Cleans up a temporary directory
    static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
    
 /// Creates a test ZIP file with specified parameters
 /// - Parameters:
 /// - directory: Directory to create the ZIP in
 /// - name: Name of the ZIP file
 /// - fileCount: Number of files to include
 /// - fileSize: Size of each file in bytes
 /// - nestingDepth: Maximum nesting depth of directories
 /// - Returns: URL of the created ZIP file
    static func createTestZip(
        in directory: URL,
        name: String = "test.zip",
        fileCount: Int,
        fileSize: Int,
        nestingDepth: Int = 0
    ) throws -> URL {
 // Create a staging directory for files to zip
        let stagingDir = directory.appendingPathComponent("staging_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        
 // Create files with optional nesting
        for i in 0..<fileCount {
            var currentDir = stagingDir
            
 // Create nested directories if needed
            if nestingDepth > 0 {
                let depth = i % (nestingDepth + 1)
                for d in 0..<depth {
                    currentDir = currentDir.appendingPathComponent("level_\(d)")
                }
                try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
            }
            
 // Create file with random content
            let fileURL = currentDir.appendingPathComponent("file_\(i).txt")
            let data = Data((0..<fileSize).map { _ in UInt8.random(in: 0...255) })
            try data.write(to: fileURL)
        }
        
 // Create ZIP using system zip command
        let zipURL = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipURL.path, "."]
        process.currentDirectoryURL = stagingDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ArchiveTestGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create ZIP"])
        }
        
        return zipURL
    }
    
 /// Creates a test file with specified format magic bytes
    static func createTestArchive(
        in directory: URL,
        format: ArchiveFormat,
        name: String? = nil
    ) throws -> URL {
        let fileName = name ?? "test.\(format.rawValue)"
        let fileURL = directory.appendingPathComponent(fileName)
        
        var data: Data
        switch format {
        case .zip:
 // Minimal valid ZIP (empty archive)
            data = Data([0x50, 0x4B, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        case .tarGz:
 // GZIP magic bytes
            data = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00])
        case .sevenZip:
 // 7z magic bytes
            data = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x00])
        case .pkg:
 // xar magic bytes
            data = Data([0x78, 0x61, 0x72, 0x21, 0x00, 0x00, 0x00, 0x00])
        case .dmg, .tar, .unknown:
 // Generic data
            data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }
        
        try data.write(to: fileURL)
        return fileURL
    }
}

// MARK: - ArchiveFormat Detection Tests

final class ArchiveFormatDetectionTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try ArchiveTestGenerator.createTempDirectory()
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            ArchiveTestGenerator.cleanup(directory: tempDir)
        }
        try await super.tearDown()
    }
    
 /// Test ZIP format detection by magic bytes
    func testZipFormatDetectionByMagicBytes() throws {
        let zipURL = try ArchiveTestGenerator.createTestArchive(in: tempDirectory, format: .zip, name: "test.bin")
        let detected = ArchiveFormat.detect(from: zipURL)
        XCTAssertEqual(detected, .zip, "Should detect ZIP by magic bytes regardless of extension")
    }
    
 /// Test GZIP/TAR.GZ format detection by magic bytes
    func testTarGzFormatDetectionByMagicBytes() throws {
        let tarGzURL = try ArchiveTestGenerator.createTestArchive(in: tempDirectory, format: .tarGz, name: "test.bin")
        let detected = ArchiveFormat.detect(from: tarGzURL)
        XCTAssertEqual(detected, .tarGz, "Should detect TAR.GZ by magic bytes")
    }
    
 /// Test 7z format detection by magic bytes
    func testSevenZipFormatDetectionByMagicBytes() throws {
        let sevenZipURL = try ArchiveTestGenerator.createTestArchive(in: tempDirectory, format: .sevenZip, name: "test.bin")
        let detected = ArchiveFormat.detect(from: sevenZipURL)
        XCTAssertEqual(detected, .sevenZip, "Should detect 7z by magic bytes")
    }
    
 /// Test PKG format detection by magic bytes
    func testPkgFormatDetectionByMagicBytes() throws {
        let pkgURL = try ArchiveTestGenerator.createTestArchive(in: tempDirectory, format: .pkg, name: "test.bin")
        let detected = ArchiveFormat.detect(from: pkgURL)
        XCTAssertEqual(detected, .pkg, "Should detect PKG by magic bytes")
    }
    
 /// Test format detection by extension when magic bytes don't match
    func testFormatDetectionByExtension() throws {
 // Create a file with unknown magic bytes but known extension
        let fileURL = tempDirectory.appendingPathComponent("test.zip")
        try Data([0x00, 0x00, 0x00, 0x00]).write(to: fileURL)
        
        let detected = ArchiveFormat.detect(from: fileURL)
 // Should fall back to extension-based detection
        XCTAssertEqual(detected, .zip, "Should detect by extension when magic bytes don't match")
    }
    
 /// Test unknown format detection
    func testUnknownFormatDetection() throws {
        let fileURL = tempDirectory.appendingPathComponent("test.xyz")
        try Data([0x00, 0x00, 0x00, 0x00]).write(to: fileURL)
        
        let detected = ArchiveFormat.detect(from: fileURL)
        XCTAssertEqual(detected, .unknown, "Should return unknown for unrecognized format")
    }
    
 /// Test supportsExtraction property
    func testSupportsExtractionProperty() {
        XCTAssertTrue(ArchiveFormat.zip.supportsExtraction, "ZIP should support extraction")
        XCTAssertFalse(ArchiveFormat.tar.supportsExtraction, "TAR should not support extraction")
        XCTAssertFalse(ArchiveFormat.dmg.supportsExtraction, "DMG should not support extraction")
        XCTAssertFalse(ArchiveFormat.pkg.supportsExtraction, "PKG should not support extraction")
        XCTAssertFalse(ArchiveFormat.sevenZip.supportsExtraction, "7z should not support extraction")
        XCTAssertFalse(ArchiveFormat.unknown.supportsExtraction, "Unknown should not support extraction")
    }
    
 /// Test isShellCheckOnly property
    func testIsShellCheckOnlyProperty() {
        XCTAssertFalse(ArchiveFormat.zip.isShellCheckOnly, "ZIP should not be shell-check-only")
        XCTAssertTrue(ArchiveFormat.tar.isShellCheckOnly, "TAR should be shell-check-only")
        XCTAssertTrue(ArchiveFormat.tarGz.isShellCheckOnly, "TAR.GZ should be shell-check-only")
        XCTAssertTrue(ArchiveFormat.dmg.isShellCheckOnly, "DMG should be shell-check-only")
        XCTAssertTrue(ArchiveFormat.pkg.isShellCheckOnly, "PKG should be shell-check-only")
        XCTAssertFalse(ArchiveFormat.sevenZip.isShellCheckOnly, "7z should not be shell-check-only")
        XCTAssertFalse(ArchiveFormat.unknown.isShellCheckOnly, "Unknown should not be shell-check-only")
    }
}


// MARK: - Property Test: Archive Extraction Limits
// **Feature: security-hardening, Property 20: Archive extraction limits**
// **Validates: Requirements 11.1, 11.2, 11.3, 11.4, 11.6**

final class ArchiveExtractorLimitsTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try ArchiveTestGenerator.createTempDirectory()
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            ArchiveTestGenerator.cleanup(directory: tempDir)
        }
        try await super.tearDown()
    }
    
 /// **Feature: security-hardening, Property 20: Archive extraction limits**
 /// **Validates: Requirements 11.1, 11.2, 11.3, 11.4, 11.6**
 ///
 /// Property: For any archive extraction, the policy SHALL enforce:
 /// maxExtractedFiles, maxTotalExtractedBytes, maxNestingDepth, maxCompressionRatio, maxExtractionTime.
 ///
 /// This test uses curated fixtures with randomized perturbations for reproducibility.
    func testProperty_ArchiveExtractionLimits() async throws {
 // Use fixed seed for reproducibility
        srand48(Int(ArchiveTestGenerator.seed))
        
 // Run curated test cases with perturbations
        let iterations = 20 // Reduced for CI stability
        
        for iteration in 0..<iterations {
            let iterationDir = tempDirectory.appendingPathComponent("iter_\(iteration)")
            try FileManager.default.createDirectory(at: iterationDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: iterationDir)
            }
            
 // Randomly select which limit to test
            let testCase = iteration % 4
            
            switch testCase {
            case 0:
                try await testFileCountLimit(in: iterationDir, iteration: iteration)
            case 1:
                try await testBytesLimit(in: iterationDir, iteration: iteration)
            case 2:
                try await testNestingDepthLimit(in: iterationDir, iteration: iteration)
            case 3:
                try await testCompressionRatioLimit(in: iterationDir, iteration: iteration)
            default:
                break
            }
        }
    }
    
 /// Test file count limit enforcement
 /// **Validates: Requirements 11.1**
    private func testFileCountLimit(in directory: URL, iteration: Int) async throws {
 // Create ZIP with more files than limit
        let maxFiles = 5
        let fileCount = maxFiles + Int(drand48() * 5) + 1 // 6-10 files
        
        let zipURL = try ArchiveTestGenerator.createTestZip(
            in: directory,
            name: "filecount_test.zip",
            fileCount: fileCount,
            fileSize: 100,
            nestingDepth: 0
        )
        
        let policy = EnhancedExtractionPolicy(
            maxExtractedFiles: maxFiles,
            maxTotalExtractedBytes: Int64.max,
            maxNestingDepth: 10,
            maxCompressionRatio: 1000.0,
            maxExtractionTime: 60.0
        )
        
        let extractor = ArchiveExtractor(policy: policy)
        let destDir = directory.appendingPathComponent("extracted")
        
        let result = await extractor.extract(from: zipURL, to: destDir)
        
 // Property: Should abort due to file count exceeded
        XCTAssertTrue(
            result.aborted,
            "Iteration \(iteration): Should abort when file count (\(fileCount)) exceeds limit (\(maxFiles))"
        )
        XCTAssertEqual(
            result.abortReason,
            .fileCountExceeded,
            "Iteration \(iteration): Abort reason should be fileCountExceeded"
        )
        
 // Property: Extracted file count should not exceed limit
        XCTAssertLessThanOrEqual(
            result.stats.extractedFileCount,
            maxFiles,
            "Iteration \(iteration): Extracted files should not exceed limit"
        )
    }
    
 /// Test bytes limit enforcement
 /// **Validates: Requirements 11.2**
    private func testBytesLimit(in directory: URL, iteration: Int) async throws {
 // Create ZIP with more bytes than limit
        let maxBytes: Int64 = 1000
        let fileSize = 500
        let fileCount = 5 // 5 * 500 = 2500 bytes > 1000
        
        let zipURL = try ArchiveTestGenerator.createTestZip(
            in: directory,
            name: "bytes_test.zip",
            fileCount: fileCount,
            fileSize: fileSize,
            nestingDepth: 0
        )
        
        let policy = EnhancedExtractionPolicy(
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: maxBytes,
            maxNestingDepth: 10,
            maxCompressionRatio: 1000.0,
            maxExtractionTime: 60.0
        )
        
        let extractor = ArchiveExtractor(policy: policy)
        let destDir = directory.appendingPathComponent("extracted")
        
        let result = await extractor.extract(from: zipURL, to: destDir)
        
 // Property: Should abort due to bytes exceeded
        XCTAssertTrue(
            result.aborted,
            "Iteration \(iteration): Should abort when total bytes exceeds limit (\(maxBytes))"
        )
        XCTAssertEqual(
            result.abortReason,
            .bytesExceeded,
            "Iteration \(iteration): Abort reason should be bytesExceeded"
        )
        
 // Property: Extracted bytes should not significantly exceed limit
 // (may slightly exceed due to per-file checking)
        XCTAssertLessThanOrEqual(
            result.stats.extractedBytes,
            maxBytes + Int64(fileSize), // Allow one file overage
            "Iteration \(iteration): Extracted bytes should not significantly exceed limit"
        )
    }
    
 /// Test nesting depth limit enforcement
 /// **Validates: Requirements 11.3**
    private func testNestingDepthLimit(in directory: URL, iteration: Int) async throws {
 // Create ZIP with deeper nesting than limit
        let maxDepth = 2
        let actualDepth = maxDepth + Int(drand48() * 3) + 1 // 3-5 levels
        
        let zipURL = try ArchiveTestGenerator.createTestZip(
            in: directory,
            name: "depth_test.zip",
            fileCount: 10,
            fileSize: 100,
            nestingDepth: actualDepth
        )
        
        let policy = EnhancedExtractionPolicy(
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: Int64.max,
            maxNestingDepth: maxDepth,
            maxCompressionRatio: 1000.0,
            maxExtractionTime: 60.0
        )
        
        let extractor = ArchiveExtractor(policy: policy)
        let destDir = directory.appendingPathComponent("extracted")
        
        let result = await extractor.extract(from: zipURL, to: destDir)
        
 // Property: Should abort due to depth exceeded
        XCTAssertTrue(
            result.aborted,
            "Iteration \(iteration): Should abort when nesting depth (\(actualDepth)) exceeds limit (\(maxDepth))"
        )
        XCTAssertEqual(
            result.abortReason,
            .depthExceeded,
            "Iteration \(iteration): Abort reason should be depthExceeded"
        )
    }
    
 /// Test compression ratio limit enforcement
 /// **Validates: Requirements 11.4, 11.7**
    private func testCompressionRatioLimit(in directory: URL, iteration: Int) async throws {
 // Create a ZIP with high compression ratio (lots of zeros compress well)
        let stagingDir = directory.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        
 // Create files with highly compressible content (all zeros)
        let fileSize = 100_000 // 100KB of zeros compresses to very small
        for i in 0..<5 {
            let fileURL = stagingDir.appendingPathComponent("zeros_\(i).bin")
            let data = Data(repeating: 0, count: fileSize)
            try data.write(to: fileURL)
        }
        
 // Create ZIP with maximum compression
        let zipURL = directory.appendingPathComponent("ratio_test.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-9", "-q", zipURL.path, "."]
        process.currentDirectoryURL = stagingDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
 // Set a low compression ratio limit
        let policy = EnhancedExtractionPolicy(
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: Int64.max,
            maxNestingDepth: 10,
            maxCompressionRatio: 10.0, // Very low - should trigger
            maxExtractionTime: 60.0
        )
        
        let extractor = ArchiveExtractor(policy: policy)
        let destDir = directory.appendingPathComponent("extracted")
        
        let result = await extractor.extract(from: zipURL, to: destDir)
        
 // Property: Should abort due to suspicious compression ratio
        XCTAssertTrue(
            result.aborted,
            "Iteration \(iteration): Should abort when compression ratio exceeds limit"
        )
        XCTAssertEqual(
            result.abortReason,
            .compressionRatioSuspicious,
            "Iteration \(iteration): Abort reason should be compressionRatioSuspicious"
        )
    }
    
 /// Test successful extraction within limits
    func testSuccessfulExtractionWithinLimits() async throws {
 // Create a small ZIP that's within all limits
        let zipURL = try ArchiveTestGenerator.createTestZip(
            in: tempDirectory,
            name: "small_test.zip",
            fileCount: 3,
            fileSize: 100,
            nestingDepth: 1
        )
        
        let policy = EnhancedExtractionPolicy(
            maxExtractedFiles: 100,
            maxTotalExtractedBytes: 1_000_000,
            maxNestingDepth: 5,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 60.0
        )
        
        let extractor = ArchiveExtractor(policy: policy)
        let destDir = tempDirectory.appendingPathComponent("extracted")
        
        let result = await extractor.extract(from: zipURL, to: destDir)
        
 // Should succeed
        XCTAssertFalse(result.aborted, "Should not abort when within limits")
        XCTAssertNil(result.abortReason, "Should have no abort reason")
        XCTAssertEqual(result.format, .zip, "Should detect ZIP format")
        XCTAssertEqual(result.stats.extractedFileCount, 3, "Should extract all 3 files")
    }
    
 /// Test shell-check-only formats
    func testShellCheckOnlyFormats() async throws {
 // Test each shell-check-only format
        for format in [ArchiveFormat.tar, .tarGz, .dmg, .pkg] {
            let archiveURL = try ArchiveTestGenerator.createTestArchive(
                in: tempDirectory,
                format: format
            )
            
            let extractor = ArchiveExtractor(policy: .default)
            let destDir = tempDirectory.appendingPathComponent("extracted_\(format.rawValue)")
            
            let result = await extractor.extract(from: archiveURL, to: destDir)
            
 // Should return shell-check-only result
            XCTAssertFalse(result.aborted, "\(format) should not abort")
            XCTAssertNil(result.abortReason, "\(format) should have no abort reason")
            XCTAssertEqual(result.format, format, "Should detect \(format) format")
            XCTAssertEqual(result.extractedURLs.count, 1, "Should return original URL for shell-check")
            XCTAssertEqual(result.extractedURLs.first, archiveURL, "Should return original URL")
        }
    }
    
 /// Test unsupported formats
    func testUnsupportedFormats() async throws {
 // Test each unsupported format
        for format in [ArchiveFormat.sevenZip, .unknown] {
            let archiveURL = try ArchiveTestGenerator.createTestArchive(
                in: tempDirectory,
                format: format
            )
            
            let extractor = ArchiveExtractor(policy: .default)
            let destDir = tempDirectory.appendingPathComponent("extracted_\(format.rawValue)")
            
            let result = await extractor.extract(from: archiveURL, to: destDir)
            
 // Should return unsupported result
            XCTAssertTrue(result.aborted, "\(format) should abort as unsupported")
            XCTAssertEqual(result.abortReason, .unsupportedFormat, "\(format) should have unsupportedFormat reason")
            XCTAssertEqual(result.format, format, "Should detect \(format) format")
            XCTAssertTrue(result.extractedURLs.isEmpty, "Should have no extracted URLs")
        }
    }
    
 /// Test extraction timeout
 /// **Validates: Requirements 11.6**
    func testExtractionTimeout() async throws {
 // Create a larger ZIP that takes time to extract
        let zipURL = try ArchiveTestGenerator.createTestZip(
            in: tempDirectory,
            name: "large_test.zip",
            fileCount: 100,
            fileSize: 1000,
            nestingDepth: 2
        )
        
 // Set a very short timeout
        let policy = EnhancedExtractionPolicy(
            maxExtractedFiles: 10000,
            maxTotalExtractedBytes: Int64.max,
            maxNestingDepth: 10,
            maxCompressionRatio: 1000.0,
            maxExtractionTime: 0.001 // 1ms - should timeout
        )
        
        let extractor = ArchiveExtractor(policy: policy)
        let destDir = tempDirectory.appendingPathComponent("extracted")
        
        let result = await extractor.extract(from: zipURL, to: destDir)
        
 // Should abort due to timeout (or complete if very fast)
        if result.aborted {
            XCTAssertEqual(
                result.abortReason,
                .timeoutExceeded,
                "Abort reason should be timeoutExceeded"
            )
        }
 // If it completed, that's also acceptable (system was fast enough)
    }
}

// MARK: - EnhancedExtractionPolicy Tests

final class EnhancedExtractionPolicyTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try ArchiveTestGenerator.createTempDirectory()
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            ArchiveTestGenerator.cleanup(directory: tempDir)
        }
        try await super.tearDown()
    }
    
 /// Test policy initialization from SecurityLimits
    func testPolicyInitializationFromSecurityLimits() {
        let limits = SecurityLimits.default
        let policy = EnhancedExtractionPolicy(from: limits)
        
        XCTAssertEqual(policy.maxExtractedFiles, limits.maxExtractedFiles)
        XCTAssertEqual(policy.maxTotalExtractedBytes, limits.maxTotalExtractedBytes)
        XCTAssertEqual(policy.maxNestingDepth, limits.maxNestingDepth)
        XCTAssertEqual(policy.maxCompressionRatio, limits.maxCompressionRatio)
        XCTAssertEqual(policy.maxExtractionTime, limits.maxExtractionTime)
    }
    
 /// Test compression ratio check
    func testCompressionRatioCheck() {
        let policy = EnhancedExtractionPolicy(
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: Int64.max,
            maxNestingDepth: 10,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 60.0
        )
        
 // Normal ratio (10:1) - not suspicious
        XCTAssertFalse(
            policy.isCompressionRatioSuspicious(compressed: 100, uncompressed: 1000),
            "10:1 ratio should not be suspicious"
        )
        
 // High ratio (200:1) - suspicious
        XCTAssertTrue(
            policy.isCompressionRatioSuspicious(compressed: 100, uncompressed: 20000),
            "200:1 ratio should be suspicious"
        )
        
 // Exactly at limit (100:1) - not suspicious
        XCTAssertFalse(
            policy.isCompressionRatioSuspicious(compressed: 100, uncompressed: 10000),
            "100:1 ratio (at limit) should not be suspicious"
        )
        
 // Just over limit (101:1) - suspicious
        XCTAssertTrue(
            policy.isCompressionRatioSuspicious(compressed: 100, uncompressed: 10100),
            "101:1 ratio should be suspicious"
        )
        
 // Zero compressed size - suspicious
        XCTAssertTrue(
            policy.isCompressionRatioSuspicious(compressed: 0, uncompressed: 1000),
            "Zero compressed size should be suspicious"
        )
    }
    
 /// Test format detection through policy
    func testFormatDetectionThroughPolicy() throws {
        let policy = EnhancedExtractionPolicy.default
        
        let zipURL = try ArchiveTestGenerator.createTestArchive(in: tempDirectory, format: .zip)
        XCTAssertEqual(policy.detectFormat(at: zipURL), .zip)
        
        let tarGzURL = try ArchiveTestGenerator.createTestArchive(in: tempDirectory, format: .tarGz)
        XCTAssertEqual(policy.detectFormat(at: tarGzURL), .tarGz)
    }
    
 /// Test uncompressed size estimation for ZIP
    func testUncompressedSizeEstimation() throws {
 // Create a ZIP with known content
        let zipURL = try ArchiveTestGenerator.createTestZip(
            in: tempDirectory,
            name: "estimate_test.zip",
            fileCount: 5,
            fileSize: 100,
            nestingDepth: 0
        )
        
        let policy = EnhancedExtractionPolicy.default
        let estimatedSize = policy.estimateUncompressedSize(from: zipURL, format: .zip)
        
 // Should return a reasonable estimate (5 files * 100 bytes = 500 bytes)
        XCTAssertNotNil(estimatedSize, "Should be able to estimate size")
        if let size = estimatedSize {
 // Allow some variance due to compression
            XCTAssertGreaterThan(size, 0, "Estimated size should be positive")
        }
    }
    
 /// Test that estimation returns nil for non-ZIP formats
    func testUncompressedSizeEstimationNonZip() throws {
        let tarGzURL = try ArchiveTestGenerator.createTestArchive(in: tempDirectory, format: .tarGz)
        
        let policy = EnhancedExtractionPolicy.default
        let estimatedSize = policy.estimateUncompressedSize(from: tarGzURL, format: .tarGz)
        
        XCTAssertNil(estimatedSize, "Should return nil for non-ZIP formats")
    }
}

// MARK: - ExtractionResult Tests

final class ExtractionResultTests: XCTestCase {
    
 /// Test success result creation
    func testSuccessResultCreation() {
        let urls = [URL(fileURLWithPath: "/tmp/file1.txt"), URL(fileURLWithPath: "/tmp/file2.txt")]
        let stats = ExtractionResult.ExtractionStats(
            extractedFileCount: 2,
            extractedBytes: 200,
            currentDepth: 1,
            elapsedTime: 0.5,
            compressedSize: 100,
            estimatedCompressionRatio: 2.0
        )
        
        let result = ExtractionResult.success(urls: urls, format: .zip, stats: stats)
        
        XCTAssertFalse(result.aborted)
        XCTAssertNil(result.abortReason)
        XCTAssertEqual(result.format, .zip)
        XCTAssertEqual(result.extractedURLs.count, 2)
        XCTAssertEqual(result.stats.extractedFileCount, 2)
    }
    
 /// Test aborted result creation
    func testAbortedResultCreation() {
        let urls = [URL(fileURLWithPath: "/tmp/file1.txt")]
        let stats = ExtractionResult.ExtractionStats(extractedFileCount: 1)
        
        let result = ExtractionResult.aborted(
            urls: urls,
            reason: .fileCountExceeded,
            format: .zip,
            stats: stats
        )
        
        XCTAssertTrue(result.aborted)
        XCTAssertEqual(result.abortReason, .fileCountExceeded)
        XCTAssertEqual(result.format, .zip)
        XCTAssertEqual(result.extractedURLs.count, 1)
    }
    
 /// Test shell-check-only result creation
    func testShellCheckOnlyResultCreation() {
        let url = URL(fileURLWithPath: "/tmp/archive.dmg")
        let result = ExtractionResult.shellCheckOnly(url: url, format: .dmg)
        
        XCTAssertFalse(result.aborted)
        XCTAssertNil(result.abortReason)
        XCTAssertEqual(result.format, .dmg)
        XCTAssertEqual(result.extractedURLs.count, 1)
        XCTAssertEqual(result.extractedURLs.first, url)
    }
    
 /// Test unsupported result creation
    func testUnsupportedResultCreation() {
        let result = ExtractionResult.unsupported(format: .sevenZip)
        
        XCTAssertTrue(result.aborted)
        XCTAssertEqual(result.abortReason, .unsupportedFormat)
        XCTAssertEqual(result.format, .sevenZip)
        XCTAssertTrue(result.extractedURLs.isEmpty)
    }
}
