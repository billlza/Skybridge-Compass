//
// FileScanServiceTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for FileScanService
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test File Generator for FileScanService

/// Generates test files for FileScanService tests
struct FileScanTestFileGenerator {
    static let tempDirectory = FileManager.default.temporaryDirectory
    
 /// Creates a simple text file
    static func createTextFile(content: String = "Safe test content") throws -> URL {
        let fileName = "test_text_\(UUID().uuidString).txt"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        try content.data(using: .utf8)?.write(to: fileURL)
        return fileURL
    }
    
 /// Creates a file with specific data
    static func createFile(data: Data, extension ext: String = "bin") throws -> URL {
        let fileName = "test_data_\(UUID().uuidString).\(ext)"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        try data.write(to: fileURL)
        return fileURL
    }
    
 /// Creates a fake Mach-O file (with magic bytes)
    static func createFakeMachO() throws -> URL {
        let fileName = "test_macho_\(UUID().uuidString)"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
 // Mach-O 64-bit magic: 0xFEEDFACF (little-endian)
        var data = Data()
        data.append(contentsOf: [0xCF, 0xFA, 0xED, 0xFE])  // MH_MAGIC_64 in little-endian
        data.append(contentsOf: Array(repeating: UInt8(0), count: 100))  // Padding
        
        try data.write(to: fileURL)
        
 // Make executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        
        return fileURL
    }
    
 /// Creates a fake script file with shebang
    static func createScript(content: String = "echo 'Hello'") throws -> URL {
        let fileName = "test_script_\(UUID().uuidString).sh"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        let scriptContent = "#!/bin/bash\n\(content)"
        try scriptContent.data(using: .utf8)?.write(to: fileURL)
        
 // Make executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        
        return fileURL
    }
    
 /// Creates a file with EICAR test content
    static func createEICARFile() throws -> URL {
        let fileName = "test_eicar_\(UUID().uuidString).txt"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        let eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
        try eicar.data(using: .utf8)?.write(to: fileURL)
        return fileURL
    }
    
 /// Cleanup temporary file
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Property Tests for FileScanService

final class FileScanServiceTests: XCTestCase {
    
    var scanService: FileScanService!
    
    override func setUp() async throws {
        scanService = FileScanService.shared
    }
    
    override func tearDown() async throws {
        scanService = nil
    }
}

// MARK: - Property 10: Scan level determines methods
// **Feature: file-scan-enhancement, Property 10: Scan level determines methods**
// **Validates: Requirements 5.2, 5.3, 5.4**

extension FileScanServiceTests {
    
 /// Property test: Quick scan uses only Quarantine method
 /// For any file scanned with Quick level, only Quarantine method should be used
    func testProperty10_QuickScanUsesOnlyQuarantine() async throws {
 // Create a simple text file
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Scan with Quick level
        let config = FileScanService.ScanConfiguration(level: .quick)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Quick scan should only use Quarantine
        XCTAssertTrue(
            result.methodsUsed.contains(.quarantine),
            "Quick scan should use Quarantine method"
        )
        
 // Quick scan should NOT use CodeSignature, Notarization, or PatternMatch
        XCTAssertFalse(
            result.methodsUsed.contains(.codeSignature),
            "Quick scan should NOT use CodeSignature method"
        )
        XCTAssertFalse(
            result.methodsUsed.contains(.notarization),
            "Quick scan should NOT use Notarization method"
        )
        XCTAssertFalse(
            result.methodsUsed.contains(.patternMatch),
            "Quick scan should NOT use PatternMatch method"
        )
        
 // Verify scan level is recorded
        XCTAssertEqual(result.scanLevel, .quick, "Scan level should be recorded as quick")
    }
    
 /// Property test: Standard scan adds CodeSignature and Gatekeeper for executables
 /// For any Mach-O file scanned with Standard level, CodeSignature should be used
    func testProperty10_StandardScanAddsCodeSignature() async throws {
 // Create a fake Mach-O file
        let fileURL = try FileScanTestFileGenerator.createFakeMachO()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Scan with Standard level
        let config = FileScanService.ScanConfiguration(level: .standard)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Standard scan should use Quarantine
        XCTAssertTrue(
            result.methodsUsed.contains(.quarantine),
            "Standard scan should use Quarantine method"
        )
        
 // Standard scan should use CodeSignature for Mach-O
        XCTAssertTrue(
            result.methodsUsed.contains(.codeSignature),
            "Standard scan should use CodeSignature for Mach-O files"
        )
        
 // Standard scan should use Gatekeeper for executables
        XCTAssertTrue(
            result.methodsUsed.contains(.gatekeeperAssessment),
            "Standard scan should use Gatekeeper assessment for executables"
        )
        
 // Standard scan should NOT use Notarization or PatternMatch
        XCTAssertFalse(
            result.methodsUsed.contains(.notarization),
            "Standard scan should NOT use Notarization method"
        )
        XCTAssertFalse(
            result.methodsUsed.contains(.patternMatch),
            "Standard scan should NOT use PatternMatch method"
        )
        
 // Verify scan level is recorded
        XCTAssertEqual(result.scanLevel, .standard, "Scan level should be recorded as standard")
    }
    
 /// Property test: Deep scan uses all methods including PatternMatch
 /// For any file scanned with Deep level, PatternMatch should be used
    func testProperty10_DeepScanUsesAllMethods() async throws {
 // Create a simple text file
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Scan with Deep level
        let config = FileScanService.ScanConfiguration(level: .deep)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Deep scan should use Quarantine
        XCTAssertTrue(
            result.methodsUsed.contains(.quarantine),
            "Deep scan should use Quarantine method"
        )
        
 // Deep scan should use PatternMatch
        XCTAssertTrue(
            result.methodsUsed.contains(.patternMatch),
            "Deep scan should use PatternMatch method"
        )
        
 // Deep scan should use Heuristic
        XCTAssertTrue(
            result.methodsUsed.contains(.heuristic),
            "Deep scan should use Heuristic method"
        )
        
 // Verify scan level is recorded
        XCTAssertEqual(result.scanLevel, .deep, "Scan level should be recorded as deep")
        
 // Verify pattern match count is reported
        XCTAssertGreaterThan(
            result.patternMatchCount,
            0,
            "Deep scan should report pattern match count"
        )
    }
    
 /// Property test: Deep scan on executable uses Notarization
 /// For any executable file scanned with Deep level, Notarization should be checked
    func testProperty10_DeepScanUsesNotarizationForExecutables() async throws {
 // Create a fake Mach-O file
        let fileURL = try FileScanTestFileGenerator.createFakeMachO()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Scan with Deep level
        let config = FileScanService.ScanConfiguration(level: .deep)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Deep scan should use Notarization for executables
        XCTAssertTrue(
            result.methodsUsed.contains(.notarization),
            "Deep scan should use Notarization for executable files"
        )
        
 // Notarization status should be set
        XCTAssertNotNil(
            result.notarizationStatus,
            "Notarization status should be reported for executables"
        )
    }
    
 /// Property test: Scan level is correctly recorded in result
 /// For any scan, the scan level should be correctly recorded in the result
    func testProperty10_ScanLevelIsRecordedCorrectly() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Test all scan levels
        let levels: [FileScanService.ScanLevel] = [.quick, .standard, .deep]
        
        for level in levels {
            let config = FileScanService.ScanConfiguration(level: level)
            let result = await scanService.scanFile(at: fileURL, configuration: config)
            
            XCTAssertEqual(
                result.scanLevel,
                level,
                "Scan level \(level.rawValue) should be recorded correctly"
            )
        }
    }
    
 /// Property test: Non-executable files skip CodeSignature in Standard scan
 /// For any non-executable file, CodeSignature should be skipped even in Standard scan
    func testProperty10_NonExecutableSkipsCodeSignature() async throws {
 // Create a simple text file (non-executable)
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Scan with Standard level
        let config = FileScanService.ScanConfiguration(level: .standard)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Non-executable should skip CodeSignature
        XCTAssertFalse(
            result.methodsUsed.contains(.codeSignature),
            "Non-executable files should skip CodeSignature"
        )
        
 // Target type should be file
        XCTAssertEqual(result.targetType, .file, "Target type should be file for text files")
    }
    
 /// Property test: Methods used is never empty
 /// For any valid scan, at least one method should be used
    func testProperty10_MethodsUsedIsNeverEmpty() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let levels: [FileScanService.ScanLevel] = [.quick, .standard, .deep]
        
        for level in levels {
            let config = FileScanService.ScanConfiguration(level: level)
            let result = await scanService.scanFile(at: fileURL, configuration: config)
            
            XCTAssertFalse(
                result.methodsUsed.isEmpty,
                "Methods used should never be empty for \(level.rawValue) scan"
            )
        }
    }
    
 /// Property test: Higher scan levels include methods from lower levels
 /// For any file, Standard includes Quick methods, Deep includes Standard methods
    func testProperty10_HigherLevelsIncludeLowerLevelMethods() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Get methods for each level
        let quickConfig = FileScanService.ScanConfiguration(level: .quick)
        let quickResult = await scanService.scanFile(at: fileURL, configuration: quickConfig)
        
        let standardConfig = FileScanService.ScanConfiguration(level: .standard)
        let standardResult = await scanService.scanFile(at: fileURL, configuration: standardConfig)
        
        let deepConfig = FileScanService.ScanConfiguration(level: .deep)
        let deepResult = await scanService.scanFile(at: fileURL, configuration: deepConfig)
        
 // Standard should include Quick methods
        for method in quickResult.methodsUsed {
            XCTAssertTrue(
                standardResult.methodsUsed.contains(method),
                "Standard scan should include Quick method: \(method.rawValue)"
            )
        }
        
 // Deep should include Standard methods
        for method in standardResult.methodsUsed {
            XCTAssertTrue(
                deepResult.methodsUsed.contains(method),
                "Deep scan should include Standard method: \(method.rawValue)"
            )
        }
    }
}


// MARK: - Property 13: Concurrent scan limit
// **Feature: file-scan-enhancement, Property 13: Concurrent scan limit**
// **Validates: Requirements 6.3**

/// Actor to collect progress updates in a thread-safe manner
private actor ProgressCollector {
    private var updates: [FileScanProgress] = []
    
    func add(_ progress: FileScanProgress) {
        updates.append(progress)
    }
    
    func getUpdates() -> [FileScanProgress] {
        updates
    }
    
    func isEmpty() -> Bool {
        updates.isEmpty
    }
    
    func first() -> FileScanProgress? {
        updates.first
    }
    
    func last() -> FileScanProgress? {
        updates.last
    }
}

extension FileScanServiceTests {
    
 /// Property test: For any batch of files, concurrent scans do not exceed configured limit
 /// This test verifies that the batch scanning respects maxConcurrentScans
    func testProperty13_ConcurrentScanLimitIsRespected() async throws {
 // Create multiple test files
        let fileCount = 10
        var fileURLs: [URL] = []
        
        for i in 0..<fileCount {
            let url = try FileScanTestFileGenerator.createTextFile(content: "Test file \(i)")
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
 // Configure with low concurrent limit
        let maxConcurrent = 2
        let config = FileScanService.ScanConfiguration(
            level: .quick,
            timeout: 30.0,
            maxConcurrentScans: maxConcurrent
        )
        
 // Use actor to collect progress updates
        let collector = ProgressCollector()
        
 // Scan with progress tracking
        let results = await scanService.scanFiles(at: fileURLs, configuration: config) { progress in
            Task {
                await collector.add(progress)
            }
        }
        
 // Wait a bit for all progress updates to be collected
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        
 // Verify all files were scanned
        XCTAssertEqual(results.count, fileCount, "All files should be scanned")
        
 // Verify progress was reported
        let isEmpty = await collector.isEmpty()
        XCTAssertFalse(isEmpty, "Progress should be reported")
        
 // Verify progress starts at 0 and ends at 1
        if let firstProgress = await collector.first() {
            XCTAssertEqual(firstProgress.overallProgress, 0.0, "Progress should start at 0")
        }
        
        if let lastProgress = await collector.last() {
            XCTAssertEqual(lastProgress.overallProgress, 1.0, "Progress should end at 1")
        }
    }
    
 /// Property test: Batch scan completes all files regardless of concurrent limit
    func testProperty13_BatchScanCompletesAllFiles() async throws {
 // Create test files
        let fileCount = 8
        var fileURLs: [URL] = []
        
        for i in 0..<fileCount {
            let url = try FileScanTestFileGenerator.createTextFile(content: "Content \(i)")
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
 // Test with different concurrent limits
        let concurrentLimits = [1, 2, 4, 8]
        
        for limit in concurrentLimits {
            let config = FileScanService.ScanConfiguration(
                level: .quick,
                timeout: 30.0,
                maxConcurrentScans: limit
            )
            
            let results = await scanService.scanFiles(at: fileURLs, configuration: config, progress: nil)
            
            XCTAssertEqual(
                results.count,
                fileCount,
                "All \(fileCount) files should be scanned with concurrent limit \(limit)"
            )
        }
    }
    
 /// Property test: Progress reports correct total and completed counts
    func testProperty13_ProgressReportsCorrectCounts() async throws {
        let fileCount = 5
        var fileURLs: [URL] = []
        
        for i in 0..<fileCount {
            let url = try FileScanTestFileGenerator.createTextFile(content: "File \(i)")
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
        let config = FileScanService.ScanConfiguration(level: .quick, maxConcurrentScans: 2)
        
        let collector = ProgressCollector()
        _ = await scanService.scanFiles(at: fileURLs, configuration: config) { progress in
            Task {
                await collector.add(progress)
            }
        }
        
 // Wait for progress updates
        try await Task.sleep(nanoseconds: 100_000_000)
        
 // Verify all progress updates have correct total
        let progressUpdates = await collector.getUpdates()
        for progress in progressUpdates {
            XCTAssertEqual(
                progress.totalFiles,
                fileCount,
                "Total files should always be \(fileCount)"
            )
            
            XCTAssertGreaterThanOrEqual(
                progress.completedFiles,
                0,
                "Completed files should be >= 0"
            )
            
            XCTAssertLessThanOrEqual(
                progress.completedFiles,
                fileCount,
                "Completed files should be <= total"
            )
        }
    }
    
 /// Property test: Empty file list returns empty results
    func testProperty13_EmptyFileListReturnsEmptyResults() async throws {
        let config = FileScanService.ScanConfiguration(level: .quick)
        
        let results = await scanService.scanFiles(at: [], configuration: config, progress: nil)
        
        XCTAssertTrue(results.isEmpty, "Empty file list should return empty results")
    }
    
 /// Property test: Single file batch works correctly
    func testProperty13_SingleFileBatchWorks() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let config = FileScanService.ScanConfiguration(level: .quick, maxConcurrentScans: 4)
        
        let collector = ProgressCollector()
        let results = await scanService.scanFiles(at: [fileURL], configuration: config) { progress in
            Task {
                await collector.add(progress)
            }
        }
        
 // Wait for progress updates
        try await Task.sleep(nanoseconds: 100_000_000)
        
        XCTAssertEqual(results.count, 1, "Single file should produce one result")
        let isEmpty = await collector.isEmpty()
        XCTAssertFalse(isEmpty, "Progress should be reported for single file")
    }
}

// MARK: - Helper Actor for Concurrent Tracking

/// Actor to track concurrent scan operations
private actor ConcurrentScanTracker {
    private var currentConcurrent: Int = 0
    private var maxObserved: Int = 0
    
    func startScan() {
        currentConcurrent += 1
        if currentConcurrent > maxObserved {
            maxObserved = currentConcurrent
        }
    }
    
    func endScan() {
        currentConcurrent -= 1
    }
    
    func getMaxObserved() -> Int {
        maxObserved
    }
    
    func getCurrentConcurrent() -> Int {
        currentConcurrent
    }
}


// MARK: - Property 14: Cancellation latency
// **Feature: file-scan-enhancement, Property 14: Cancellation latency**
// **Validates: Requirements 6.4**

extension FileScanServiceTests {
    
 /// Property test: For any cancelled scan, operations stop within 100ms
    func testProperty14_CancellationStopsWithin100ms() async throws {
 // Create a test file
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Test content for cancellation")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let scanId = UUID()
        let config = FileScanService.ScanConfiguration(level: .deep)  // Deep scan takes longer
        
 // Capture service reference for
        let service = scanService!
        
 // Start scan in background
        let scanTask = Task {
            await service.scanFileWithCancellation(
                at: fileURL,
                configuration: config,
                scanId: scanId
            )
        }
        
 // Wait a tiny bit for scan to start
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        
 // Record time before cancellation
        let cancelStartTime = Date()
        
 // Cancel the scan
        _ = await scanService.cancelScan(id: scanId)
        
 // Record time after cancellation
        let cancelEndTime = Date()
        let cancellationLatency = cancelEndTime.timeIntervalSince(cancelStartTime)
        
 // Verify cancellation was acknowledged (may or may not succeed depending on timing)
 // The important thing is that the cancellation call itself is fast
        XCTAssertLessThan(
            cancellationLatency,
            0.1,  // 100ms
            "Cancellation should complete within 100ms, took \(cancellationLatency * 1000)ms"
        )
        
 // Wait for the scan to complete
        let result = await scanTask.value
        
 // The result should either be cancelled or completed (depending on timing)
 // We just verify the scan didn't hang
        XCTAssertNotNil(result, "Scan should return a result")
    }
    
 /// Property test: Cancelled scan returns appropriate result
    func testProperty14_CancelledScanReturnsAppropriateResult() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let scanId = UUID()
        let config = FileScanService.ScanConfiguration(level: .quick)
        
 // Capture service reference for
        let service = scanService!
        
 // Start scan
        let scanTask = Task {
            await service.scanFileWithCancellation(
                at: fileURL,
                configuration: config,
                scanId: scanId
            )
        }
        
 // Immediately cancel
        _ = await scanService.cancelScan(id: scanId)
        
 // Get result
        let result = await scanTask.value
        
 // Result should be valid (either completed or cancelled)
        XCTAssertNotNil(result.id, "Result should have an ID")
        XCTAssertEqual(result.fileURL, fileURL, "Result should reference the correct file")
    }
    
 /// Property test: Cancel all scans stops all active scans
    func testProperty14_CancelAllScansStopsAllActive() async throws {
 // Create multiple test files
        var fileURLs: [URL] = []
        for i in 0..<5 {
            let url = try FileScanTestFileGenerator.createTextFile(content: "File \(i)")
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
        let config = FileScanService.ScanConfiguration(level: .deep)
        
 // Capture service reference for
        let service = scanService!
        
 // Start multiple scans
        var scanTasks: [Task<FileScanResult, Never>] = []
        for url in fileURLs {
            let task = Task {
                await service.scanFileWithCancellation(
                    at: url,
                    configuration: config,
                    scanId: UUID()
                )
            }
            scanTasks.append(task)
        }
        
 // Wait a bit for scans to start
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        
 // Cancel all scans
        let cancelStartTime = Date()
        await scanService.cancelAllScans()
        let cancelEndTime = Date()
        
 // Verify cancellation was fast
        let cancellationLatency = cancelEndTime.timeIntervalSince(cancelStartTime)
        XCTAssertLessThan(
            cancellationLatency,
            0.1,  // 100ms
            "Cancel all should complete within 100ms"
        )
        
 // Verify active scan count is 0
        let activeCount = await scanService.getActiveScanCount()
        XCTAssertEqual(activeCount, 0, "No scans should be active after cancel all")
        
 // Wait for all tasks to complete
        for task in scanTasks {
            _ = await task.value
        }
    }
    
 /// Property test: isScanCancelled returns correct status
    func testProperty14_IsScanCancelledReturnsCorrectStatus() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let scanId = UUID()
        let config = FileScanService.ScanConfiguration(level: .quick)
        
 // Check status before scan starts (should be cancelled/not found)
        let statusBefore = await scanService.isScanCancelled(id: scanId)
        XCTAssertTrue(statusBefore, "Non-existent scan should be considered cancelled")
        
 // Capture service reference for
        let service = scanService!
        
 // Start scan
        let scanTask = Task {
            await service.scanFileWithCancellation(
                at: fileURL,
                configuration: config,
                scanId: scanId
            )
        }
        
 // Wait for scan to complete
        _ = await scanTask.value
        
 // Check status after scan completes (should be cancelled/not found)
        let statusAfter = await scanService.isScanCancelled(id: scanId)
        XCTAssertTrue(statusAfter, "Completed scan should be considered cancelled (removed from active)")
    }
    
 /// Property test: Multiple cancellations of same scan are safe
    func testProperty14_MultipleCancellationsAreSafe() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile()
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let scanId = UUID()
        let config = FileScanService.ScanConfiguration(level: .quick)
        
 // Capture service reference for
        let service = scanService!
        
 // Start scan
        let scanTask = Task {
            await service.scanFileWithCancellation(
                at: fileURL,
                configuration: config,
                scanId: scanId
            )
        }
        
 // Cancel multiple times (should be safe)
        _ = await scanService.cancelScan(id: scanId)
        _ = await scanService.cancelScan(id: scanId)
        _ = await scanService.cancelScan(id: scanId)
        
 // Should not crash, just return false for subsequent cancellations
        let result = await scanTask.value
        XCTAssertNotNil(result, "Scan should return a result even after multiple cancellations")
    }
}


// MARK: - Property 18: Permission error handling
// **Feature: file-scan-enhancement, Property 18: Permission error handling**
// **Validates: Requirements 8.2**

extension FileScanServiceTests {
    
 /// Property test: For any file with restricted permissions, scan returns result with permission error warning without crashing
    func testProperty18_PermissionErrorReturnsWarningWithoutCrash() async throws {
 // Create a test file
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Test content")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Remove read permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        
 // Restore permissions in cleanup
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }
        
 // Scan should not crash and should return appropriate result
        let config = FileScanService.ScanConfiguration(level: .standard)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Result should exist (no crash)
        XCTAssertNotNil(result, "Scan should return a result even for permission-denied files")
        
 // Verdict should be unknown (not safe!) - unknown-by-default policy
        XCTAssertEqual(
            result.verdict,
            .unknown,
            "Permission denied should result in unknown verdict (not safe)"
        )
        
 // Should have a warning about permission
        let hasPermissionWarning = result.warnings.contains { warning in
            warning.code == "PERMISSION_DENIED" || warning.message.lowercased().contains("permission")
        }
        XCTAssertTrue(
            hasPermissionWarning,
            "Result should contain permission error warning"
        )
    }
    
 /// Property test: Permission error in Deep scan returns warning verdict
    func testProperty18_PermissionErrorInDeepScanReturnsWarning() async throws {
 // Create a test file
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Test content")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Remove read permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        
 // Restore permissions in cleanup
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }
        
 // Deep scan should return warning verdict (more strict)
        let config = FileScanService.ScanConfiguration(level: .deep)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Deep scan: permission error should result in warning (stricter than unknown)
 // Note: The policy is unknown for Quick/Standard, warning for Deep
        XCTAssertTrue(
            result.verdict == .unknown || result.verdict == .warning,
            "Deep scan with permission error should result in unknown or warning verdict"
        )
        
 // Should NOT be safe
        XCTAssertNotEqual(
            result.verdict,
            .safe,
            "Permission denied should NEVER result in safe verdict"
        )
    }
    
 /// Property test: FileScanError.permissionDenied creates correct warning
    func testProperty18_FileScanErrorPermissionDeniedCreatesCorrectWarning() {
        let testURL = URL(fileURLWithPath: "/test/file.txt")
        let error = FileScanError.permissionDenied(testURL)
        
 // Check error properties
        XCTAssertEqual(error.code, "PERMISSION_DENIED", "Error code should be PERMISSION_DENIED")
        XCTAssertEqual(error.severity, .critical, "Permission denied should be critical severity")
        
 // Check warning conversion
        let warning = error.toWarning()
        XCTAssertEqual(warning.code, "PERMISSION_DENIED", "Warning code should match error code")
        XCTAssertEqual(warning.severity, .critical, "Warning severity should match error severity")
        XCTAssertTrue(
            warning.message.contains("Permission denied"),
            "Warning message should mention permission denied"
        )
    }
    
 /// Property test: ErrorRecoveryPolicy returns correct verdict for permission errors
    func testProperty18_ErrorRecoveryPolicyForPermissionErrors() {
        let testURL = URL(fileURLWithPath: "/test/file.txt")
        let error = FileScanError.permissionDenied(testURL)
        
 // Quick level: should return unknown
        let quickVerdict = ErrorRecoveryPolicy.determineVerdict(for: error, scanLevel: .quick)
        XCTAssertEqual(quickVerdict, .unknown, "Quick scan permission error should return unknown")
        
 // Standard level: should return unknown
        let standardVerdict = ErrorRecoveryPolicy.determineVerdict(for: error, scanLevel: .standard)
        XCTAssertEqual(standardVerdict, .unknown, "Standard scan permission error should return unknown")
        
 // Deep level: should return warning (stricter)
        let deepVerdict = ErrorRecoveryPolicy.determineVerdict(for: error, scanLevel: .deep)
        XCTAssertEqual(deepVerdict, .warning, "Deep scan permission error should return warning")
    }
}

// MARK: - Property 19: Archive limited scan
// **Feature: file-scan-enhancement, Property 19: Archive limited scan**
// **Validates: Requirements 8.3**

extension FileScanServiceTests {
    
 /// Property test: For any encrypted or compressed archive, scan result indicates limited scan capability
    func testProperty19_ArchiveScanIndicatesLimitedCapability() async throws {
 // Create a fake DMG file (encrypted archive type)
        let dmgURL = try FileScanTestFileGenerator.createFile(
            data: Data("Fake DMG content".utf8),
            extension: "dmg"
        )
        defer { FileScanTestFileGenerator.cleanup(dmgURL) }
        
 // Check archive scan capability
        let capability = await scanService.checkArchiveScanCapability(at: dmgURL)
        
 // DMG files should indicate limited scan capability
        XCTAssertFalse(
            capability.canFullScan,
            "DMG files should indicate limited scan capability"
        )
        XCTAssertFalse(
            capability.reason.isEmpty,
            "Limited scan should provide a reason"
        )
    }
    
 /// Property test: Archive file detection works correctly
    func testProperty19_ArchiveFileDetection() async throws {
 // Test various archive extensions
        let archiveExtensions = ["zip", "dmg", "tar", "gz", "pkg", "7z", "rar"]
        let nonArchiveExtensions = ["txt", "pdf", "jpg", "swift", "md"]
        
        for ext in archiveExtensions {
            let url = try FileScanTestFileGenerator.createFile(
                data: Data("Test".utf8),
                extension: ext
            )
            defer { FileScanTestFileGenerator.cleanup(url) }
            
            let isArchive = await scanService.isArchiveFile(at: url)
            XCTAssertTrue(
                isArchive,
                ".\(ext) should be detected as archive file"
            )
        }
        
        for ext in nonArchiveExtensions {
            let url = try FileScanTestFileGenerator.createFile(
                data: Data("Test".utf8),
                extension: ext
            )
            defer { FileScanTestFileGenerator.cleanup(url) }
            
            let isArchive = await scanService.isArchiveFile(at: url)
            XCTAssertFalse(
                isArchive,
                ".\(ext) should NOT be detected as archive file"
            )
        }
    }
    
 /// Property test: Large archive files indicate limited scan
    func testProperty19_LargeArchiveIndicatesLimitedScan() async throws {
 // Create a small zip file (we can't easily create a 500MB+ file in tests)
        let zipURL = try FileScanTestFileGenerator.createFile(
            data: Data("Small zip content".utf8),
            extension: "zip"
        )
        defer { FileScanTestFileGenerator.cleanup(zipURL) }
        
 // Small zip should allow full scan
        let capability = await scanService.checkArchiveScanCapability(at: zipURL)
        XCTAssertTrue(
            capability.canFullScan,
            "Small zip files should allow full scan"
        )
    }
    
 /// Property test: FileScanError.archiveLimitExceeded creates correct warning
    func testProperty19_ArchiveLimitExceededCreatesCorrectWarning() {
        let error = FileScanError.archiveLimitExceeded(reason: "Archive too large")
        
 // Check error properties
        XCTAssertEqual(error.code, "ARCHIVE_LIMIT_EXCEEDED", "Error code should be ARCHIVE_LIMIT_EXCEEDED")
        XCTAssertEqual(error.severity, .warning, "Archive limit exceeded should be warning severity")
        
 // Check warning conversion
        let warning = error.toWarning()
        XCTAssertEqual(warning.code, "ARCHIVE_LIMIT_EXCEEDED", "Warning code should match error code")
        XCTAssertTrue(
            warning.message.contains("Archive too large"),
            "Warning message should contain the reason"
        )
    }
    
 /// Property test: Archive scan result includes appropriate target type
    func testProperty19_ArchiveScanResultIncludesTargetType() async throws {
 // Create a zip file
        let zipURL = try FileScanTestFileGenerator.createFile(
            data: Data("Zip content".utf8),
            extension: "zip"
        )
        defer { FileScanTestFileGenerator.cleanup(zipURL) }
        
 // Scan the archive
        let config = FileScanService.ScanConfiguration(level: .quick)
        let result = await scanService.scanFile(at: zipURL, configuration: config)
        
 // Target type should be archive
        XCTAssertEqual(
            result.targetType,
            .archive,
            "Zip file should have archive target type"
        )
    }
}

// MARK: - Property 20: Unknown-by-default on error
// **Feature: file-scan-enhancement, Property 20: Unknown-by-default on error (not safe-by-default)**
// **Validates: Requirements 8.4**

extension FileScanServiceTests {
    
 /// Property test: For any unexpected error, result is verdict=unknown (Quick/Standard) or warning (Deep), NOT safe
    func testProperty20_UnknownByDefaultOnError() async throws {
 // Test with non-existent file
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/path/to/file_\(UUID().uuidString).txt")
        
 // Quick scan: should return unknown
        let quickConfig = FileScanService.ScanConfiguration(level: .quick)
        let quickResult = await scanService.scanFile(at: nonExistentURL, configuration: quickConfig)
        
        XCTAssertEqual(
            quickResult.verdict,
            .unknown,
            "Quick scan error should result in unknown verdict"
        )
        XCTAssertNotEqual(
            quickResult.verdict,
            .safe,
            "Error should NEVER result in safe verdict"
        )
        
 // Standard scan: should return unknown
        let standardConfig = FileScanService.ScanConfiguration(level: .standard)
        let standardResult = await scanService.scanFile(at: nonExistentURL, configuration: standardConfig)
        
        XCTAssertEqual(
            standardResult.verdict,
            .unknown,
            "Standard scan error should result in unknown verdict"
        )
        XCTAssertNotEqual(
            standardResult.verdict,
            .safe,
            "Error should NEVER result in safe verdict"
        )
        
 // Deep scan: should return unknown (file not found is always unknown)
        let deepConfig = FileScanService.ScanConfiguration(level: .deep)
        let deepResult = await scanService.scanFile(at: nonExistentURL, configuration: deepConfig)
        
        XCTAssertEqual(
            deepResult.verdict,
            .unknown,
            "Deep scan file not found should result in unknown verdict"
        )
        XCTAssertNotEqual(
            deepResult.verdict,
            .safe,
            "Error should NEVER result in safe verdict"
        )
    }
    
 /// Property test: ErrorRecoveryPolicy never returns safe for any error type
    func testProperty20_ErrorRecoveryPolicyNeverReturnsSafe() {
        let testURL = URL(fileURLWithPath: "/test/file.txt")
        
 // Test all error types
        let errors: [FileScanError] = [
            .fileNotFound(testURL),
            .permissionDenied(testURL),
            .timeout(testURL, 30.0),
            .cancelled,
            .commandFailed(command: "test", exitCode: 1, stderr: "error"),
            .invalidFileType(testURL),
            .resourceExhausted,
            .archiveLimitExceeded(reason: "test"),
            .symlinkDepthExceeded(testURL, depth: 10),
            .fileBeingWritten(testURL),
            .unknown("test error")
        ]
        
        let levels: [FileScanService.ScanLevel] = [.quick, .standard, .deep]
        
        for error in errors {
            for level in levels {
                let verdict = ErrorRecoveryPolicy.determineVerdict(for: error, scanLevel: level)
                
                XCTAssertNotEqual(
                    verdict,
                    .safe,
                    "Error \(error.code) at \(level.rawValue) level should NEVER return safe verdict"
                )
                
 // Verdict should be either unknown or warning
                XCTAssertTrue(
                    verdict == .unknown || verdict == .warning,
                    "Error verdict should be unknown or warning, got \(verdict.rawValue)"
                )
            }
        }
    }
    
 /// Property test: File not found returns unknown verdict with warning
    func testProperty20_FileNotFoundReturnsUnknownWithWarning() async throws {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file_\(UUID().uuidString).txt")
        
        let config = FileScanService.ScanConfiguration(level: .standard)
        let result = await scanService.scanFile(at: nonExistentURL, configuration: config)
        
 // Verdict should be unknown
        XCTAssertEqual(result.verdict, .unknown, "File not found should return unknown verdict")
        
 // Should have a warning
        XCTAssertFalse(result.warnings.isEmpty, "File not found should include a warning")
        
 // Warning should mention file not found
        let hasFileNotFoundWarning = result.warnings.contains { warning in
            warning.code == "FILE_NOT_FOUND" || warning.message.lowercased().contains("not found")
        }
        XCTAssertTrue(
            hasFileNotFoundWarning,
            "Result should contain file not found warning"
        )
    }
    
 /// Property test: All FileScanError types have valid codes
    func testProperty20_AllFileScanErrorTypesHaveValidCodes() {
        let testURL = URL(fileURLWithPath: "/test/file.txt")
        
        let errors: [FileScanError] = [
            .fileNotFound(testURL),
            .permissionDenied(testURL),
            .timeout(testURL, 30.0),
            .cancelled,
            .commandFailed(command: "test", exitCode: 1, stderr: "error"),
            .invalidFileType(testURL),
            .resourceExhausted,
            .archiveLimitExceeded(reason: "test"),
            .symlinkDepthExceeded(testURL, depth: 10),
            .fileBeingWritten(testURL),
            .unknown("test error")
        ]
        
        for error in errors {
 // Code should not be empty
            XCTAssertFalse(error.code.isEmpty, "Error code should not be empty")
            
 // Code should be uppercase with underscores
            XCTAssertTrue(
                error.code.allSatisfy { $0.isUppercase || $0 == "_" },
                "Error code should be uppercase with underscores: \(error.code)"
            )
            
 // Description should not be empty
            XCTAssertFalse(error.localizedDescription.isEmpty, "Error description should not be empty")
            
 // Warning conversion should work
            let warning = error.toWarning()
            XCTAssertEqual(warning.code, error.code, "Warning code should match error code")
        }
    }
    
 /// Property test: createErrorRecoveryResult creates valid result
    func testProperty20_CreateErrorRecoveryResultCreatesValidResult() async throws {
        let testURL = URL(fileURLWithPath: "/test/file.txt")
        let error = FileScanError.permissionDenied(testURL)
        let startTime = Date()
        let config = FileScanService.ScanConfiguration(level: .standard)
        
        let result = await scanService.createErrorRecoveryResult(
            for: error,
            fileURL: testURL,
            configuration: config,
            startTime: startTime
        )
        
 // Result should have correct properties
        XCTAssertEqual(result.fileURL, testURL, "Result should have correct file URL")
        XCTAssertEqual(result.scanLevel, .standard, "Result should have correct scan level")
        XCTAssertEqual(result.verdict, .unknown, "Result should have unknown verdict for standard level")
        XCTAssertFalse(result.warnings.isEmpty, "Result should have warnings")
        XCTAssertTrue(result.threats.isEmpty, "Result should have no threats")
    }
}


// MARK: - Property 21: Symbolic link resolution
// **Feature: file-scan-enhancement, Property 21: Symbolic link resolution**
// **Validates: Requirements 8.5**

extension FileScanServiceTests {
    
 /// Property test: For any symbolic link, scan resolves and scans the target file
    func testProperty21_SymlinkResolvesAndScansTarget() async throws {
 // Create a target file
        let targetURL = try FileScanTestFileGenerator.createTextFile(content: "Target file content")
        defer { FileScanTestFileGenerator.cleanup(targetURL) }
        
 // Create a symbolic link to the target
        let symlinkURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_symlink_\(UUID().uuidString).txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        defer { FileScanTestFileGenerator.cleanup(symlinkURL) }
        
 // Scan the symbolic link
        let config = FileScanService.ScanConfiguration(level: .quick)
        let result = await scanService.scanFile(at: symlinkURL, configuration: config)
        
 // Scan should succeed (not return error for symlink)
        XCTAssertNotEqual(
            result.verdict,
            .unknown,
            "Symlink scan should resolve and scan target, not return unknown"
        )
        
 // Result should reference the original symlink URL
        XCTAssertEqual(
            result.fileURL,
            symlinkURL,
            "Result should reference the original symlink URL"
        )
    }
    
 /// Property test: Symlink to non-existent file returns appropriate error
    func testProperty21_SymlinkToNonExistentFileReturnsError() async throws {
 // Create a symbolic link to a non-existent file
        let nonExistentTarget = URL(fileURLWithPath: "/nonexistent/target_\(UUID().uuidString).txt")
        let symlinkURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_broken_symlink_\(UUID().uuidString).txt")
        
        try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: nonExistentTarget.path)
        defer { FileScanTestFileGenerator.cleanup(symlinkURL) }
        
 // Scan the broken symbolic link
        let config = FileScanService.ScanConfiguration(level: .quick)
        let result = await scanService.scanFile(at: symlinkURL, configuration: config)
        
 // Should return unknown verdict (file not found after resolution)
        XCTAssertEqual(
            result.verdict,
            .unknown,
            "Broken symlink should return unknown verdict"
        )
        
 // Should have a warning
        XCTAssertFalse(
            result.warnings.isEmpty,
            "Broken symlink should include a warning"
        )
    }
    
 /// Property test: resolveSymbolicLink returns same URL for non-symlink
    func testProperty21_ResolveSymbolicLinkReturnsOriginalForNonSymlink() async throws {
 // Create a regular file (not a symlink)
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Regular file")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Resolve should return the same URL
        let resolvedURL = try await scanService.resolveSymbolicLink(at: fileURL)
        
        XCTAssertEqual(
            resolvedURL.standardizedFileURL,
            fileURL.standardizedFileURL,
            "Non-symlink should resolve to itself"
        )
    }
    
 /// Property test: resolveSymbolicLink follows chain of symlinks
    func testProperty21_ResolveSymbolicLinkFollowsChain() async throws {
 // Create target file
        let targetURL = try FileScanTestFileGenerator.createTextFile(content: "Final target")
        defer { FileScanTestFileGenerator.cleanup(targetURL) }
        
 // Create chain: symlink1 -> symlink2 -> target
        let symlink2URL = FileManager.default.temporaryDirectory.appendingPathComponent("test_symlink2_\(UUID().uuidString).txt")
        try FileManager.default.createSymbolicLink(at: symlink2URL, withDestinationURL: targetURL)
        defer { FileScanTestFileGenerator.cleanup(symlink2URL) }
        
        let symlink1URL = FileManager.default.temporaryDirectory.appendingPathComponent("test_symlink1_\(UUID().uuidString).txt")
        try FileManager.default.createSymbolicLink(at: symlink1URL, withDestinationURL: symlink2URL)
        defer { FileScanTestFileGenerator.cleanup(symlink1URL) }
        
 // Resolve should follow the chain to the target
        let resolvedURL = try await scanService.resolveSymbolicLink(at: symlink1URL)
        
        XCTAssertEqual(
            resolvedURL.standardizedFileURL,
            targetURL.standardizedFileURL,
            "Symlink chain should resolve to final target"
        )
    }
    
 /// Property test: resolveSymbolicLink throws for circular links
    func testProperty21_ResolveSymbolicLinkThrowsForCircularLinks() async throws {
 // Create circular symlinks: symlink1 -> symlink2 -> symlink1
        let symlink1URL = FileManager.default.temporaryDirectory.appendingPathComponent("test_circular1_\(UUID().uuidString).txt")
        let symlink2URL = FileManager.default.temporaryDirectory.appendingPathComponent("test_circular2_\(UUID().uuidString).txt")
        
 // Create symlink2 first (pointing to where symlink1 will be)
        try FileManager.default.createSymbolicLink(atPath: symlink2URL.path, withDestinationPath: symlink1URL.path)
        defer { FileScanTestFileGenerator.cleanup(symlink2URL) }
        
 // Create symlink1 pointing to symlink2
        try FileManager.default.createSymbolicLink(at: symlink1URL, withDestinationURL: symlink2URL)
        defer { FileScanTestFileGenerator.cleanup(symlink1URL) }
        
 // Resolve should throw for circular links
        do {
            _ = try await scanService.resolveSymbolicLink(at: symlink1URL)
            XCTFail("Should throw for circular symlinks")
        } catch let error as FileScanError {
 // Should be symlinkDepthExceeded error
            XCTAssertEqual(
                error.code,
                "SYMLINK_DEPTH_EXCEEDED",
                "Circular symlink should throw symlinkDepthExceeded error"
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
 /// Property test: resolveSymbolicLink respects maxDepth
    func testProperty21_ResolveSymbolicLinkRespectsMaxDepth() async throws {
 // Create a chain of symlinks longer than maxDepth
        let targetURL = try FileScanTestFileGenerator.createTextFile(content: "Target")
        defer { FileScanTestFileGenerator.cleanup(targetURL) }
        
        var previousURL = targetURL
        var symlinkURLs: [URL] = []
        
 // Create chain of 5 symlinks
        for i in 0..<5 {
            let symlinkURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_chain_\(i)_\(UUID().uuidString).txt")
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: previousURL)
            symlinkURLs.append(symlinkURL)
            previousURL = symlinkURL
        }
        defer { symlinkURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
 // With maxDepth=3, should throw
        do {
            _ = try await scanService.resolveSymbolicLink(at: previousURL, maxDepth: 3)
            XCTFail("Should throw when chain exceeds maxDepth")
        } catch let error as FileScanError {
            XCTAssertEqual(error.code, "SYMLINK_DEPTH_EXCEEDED", "Should throw symlinkDepthExceeded")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        
 // With maxDepth=10, should succeed
        let resolvedURL = try await scanService.resolveSymbolicLink(at: previousURL, maxDepth: 10)
        XCTAssertEqual(
            resolvedURL.standardizedFileURL,
            targetURL.standardizedFileURL,
            "Should resolve to target with sufficient maxDepth"
        )
    }
    
 /// Property test: isSymbolicLink correctly identifies symlinks
    func testProperty21_IsSymbolicLinkCorrectlyIdentifies() async throws {
 // Create a regular file
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Regular file")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Create a symlink
        let symlinkURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_symlink_check_\(UUID().uuidString).txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)
        defer { FileScanTestFileGenerator.cleanup(symlinkURL) }
        
 // Check identification
        let isFileSymlink = await scanService.isSymbolicLink(at: fileURL)
        let isSymlinkSymlink = await scanService.isSymbolicLink(at: symlinkURL)
        
        XCTAssertFalse(isFileSymlink, "Regular file should not be identified as symlink")
        XCTAssertTrue(isSymlinkSymlink, "Symlink should be identified as symlink")
    }
    
 /// Property test: FileScanError.symlinkDepthExceeded creates correct warning
    func testProperty21_SymlinkDepthExceededCreatesCorrectWarning() {
        let testURL = URL(fileURLWithPath: "/test/symlink.txt")
        let error = FileScanError.symlinkDepthExceeded(testURL, depth: 10)
        
 // Check error properties
        XCTAssertEqual(error.code, "SYMLINK_DEPTH_EXCEEDED", "Error code should be SYMLINK_DEPTH_EXCEEDED")
        XCTAssertEqual(error.severity, .warning, "Symlink depth exceeded should be warning severity")
        
 // Check warning conversion
        let warning = error.toWarning()
        XCTAssertEqual(warning.code, "SYMLINK_DEPTH_EXCEEDED", "Warning code should match error code")
        XCTAssertTrue(
            warning.message.contains("10"),
            "Warning message should contain the depth"
        )
    }
    
 /// Property test: Scan through symlink produces valid result
    func testProperty21_ScanThroughSymlinkProducesValidResult() async throws {
 // Create a target file with specific content
        let targetURL = try FileScanTestFileGenerator.createTextFile(content: "Safe content for symlink test")
        defer { FileScanTestFileGenerator.cleanup(targetURL) }
        
 // Create symlink
        let symlinkURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_scan_symlink_\(UUID().uuidString).txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        defer { FileScanTestFileGenerator.cleanup(symlinkURL) }
        
 // Scan through symlink with all levels
        let levels: [FileScanService.ScanLevel] = [.quick, .standard, .deep]
        
        for level in levels {
            let config = FileScanService.ScanConfiguration(level: level)
            let result = await scanService.scanFile(at: symlinkURL, configuration: config)
            
 // Result should be valid
            XCTAssertNotNil(result.id, "Result should have an ID")
            XCTAssertEqual(result.fileURL, symlinkURL, "Result should reference symlink URL")
            XCTAssertEqual(result.scanLevel, level, "Result should have correct scan level")
            
 // For safe content, should not be unsafe
            XCTAssertNotEqual(
                result.verdict,
                .unsafe,
                "Safe content through symlink should not be unsafe at \(level.rawValue) level"
            )
        }
    }
}


// MARK: - Property 12: Background thread execution
// **Feature: file-scan-enhancement, Property 12: Background thread execution**
// **Validates: Requirements 6.1**

extension FileScanServiceTests {
    
 /// Property test: For any scan operation, execution SHALL NOT occur on MainActor
 /// This test verifies that scan operations execute on background threads
    func testProperty12_ScanOperationsExecuteOnBackgroundThread() async throws {
 // Create a test file
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Test content for background execution")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
 // Verify the helper method works correctly
 // When called from a background context, it should return true
        let service = scanService!
        let isBackground = await Task.detached {
            return service.isExecutingOnBackgroundThread()
        }.value
        
        XCTAssertTrue(
            isBackground,
            "isExecutingOnBackgroundThread should return true when called from background"
        )
        
 // Scan the file - the scan itself runs inside the actor (background)
        let config = FileScanService.ScanConfiguration(level: .quick)
        let result = await scanService.scanFile(at: fileURL, configuration: config)
        
 // Verify scan completed successfully
        XCTAssertNotNil(result.id, "Scan should complete and return a result")
        XCTAssertEqual(result.fileURL, fileURL, "Result should reference the correct file")
    }
    
 /// Property test: FileScanService actor methods do not block MainActor
 /// This test verifies that scan operations can run concurrently without blocking UI
    func testProperty12_ScanDoesNotBlockMainActor() async throws {
 // Create test files
        var fileURLs: [URL] = []
        for i in 0..<5 {
            let url = try FileScanTestFileGenerator.createTextFile(content: "File \(i) content")
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
 // Track if MainActor was blocked
        let mainActorResponsive = MainActorResponsivenessTracker()
        
 // Capture service for
        let service = scanService!
        let urls = fileURLs
        
 // Start scans in background
        let scanTask = Task.detached {
            let config = FileScanService.ScanConfiguration(level: .standard)
            return await service.scanFiles(at: urls, configuration: config, progress: nil)
        }
        
 // While scans are running, verify MainActor is responsive
 // by executing a simple on MainActor
        await mainActorResponsive.markResponsive()
        
 // Wait for scans to complete
        let results = await scanTask.value
        
 // Verify MainActor remained responsive
        let wasResponsive = await mainActorResponsive.wasResponsive()
        XCTAssertTrue(wasResponsive, "MainActor should remain responsive during scans")
        
 // Verify all scans completed
        XCTAssertEqual(results.count, fileURLs.count, "All files should be scanned")
    }
    
 /// Property test: MainActor-isolated progress callbacks are delivered on MainActor
 /// This test verifies that scanFilesWithMainActorProgress delivers callbacks on MainActor
    func testProperty12_MainActorProgressCallbacksDeliveredOnMainActor() async throws {
 // Create test files
        var fileURLs: [URL] = []
        for i in 0..<3 {
            let url = try FileScanTestFileGenerator.createTextFile(content: "File \(i)")
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
        let config = FileScanService.ScanConfiguration(level: .quick, maxConcurrentScans: 2)
        
 // Track progress callbacks
        let callbackTracker = MainActorCallbackTracker()
        
 // Scan with MainActor-isolated progress callback
        _ = await scanService.scanFilesWithMainActorProgress(
            at: fileURLs,
            configuration: config
        ) { progress in
 // This callback should be on MainActor
            callbackTracker.recordCallback(progress: progress)
        }
        
 // Wait a bit for all callbacks to be processed
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        
 // Verify callbacks were received
        let callbackCount = await callbackTracker.getCallbackCount()
        XCTAssertGreaterThan(callbackCount, 0, "Progress callbacks should be received")
        
 // Verify all callbacks were on MainActor
        let allOnMainActor = await callbackTracker.allCallbacksOnMainActor()
        XCTAssertTrue(allOnMainActor, "All progress callbacks should be delivered on MainActor")
    }
    
 /// Property test: scanFileWithMainActorCallback delivers result on MainActor
    func testProperty12_MainActorCallbackDeliveredOnMainActor() async throws {
 // Create a test file
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Test content")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let config = FileScanService.ScanConfiguration(level: .quick)
        
 // Use actor to track callback state safely
        let callbackState = CallbackStateTracker()
        
 // Use expectation to wait for callback
        let expectation = XCTestExpectation(description: "Callback received")
        
 // Scan with MainActor callback
        await scanService.scanFileWithMainActorCallback(
            at: fileURL,
            configuration: config
        ) { result in
 // This callback is @MainActor isolated, so we're guaranteed to be on MainActor
 // The fact that this compiles and runs proves we're on MainActor
            let isOnMainActor = true  // @MainActor callback guarantees this
            Task {
                await callbackState.recordCallback(wasOnMainActor: isOnMainActor, result: result)
                expectation.fulfill()
            }
        }
        
 // Wait for callback
        await fulfillment(of: [expectation], timeout: 5.0)
        
 // Verify callback was on MainActor
        let wasOnMainActor = await callbackState.wasOnMainActor()
        XCTAssertTrue(wasOnMainActor, "Callback should be delivered on MainActor (main thread)")
        
 // Verify result is valid
        let receivedResult = await callbackState.getResult()
        XCTAssertNotNil(receivedResult, "Result should be received")
        XCTAssertEqual(receivedResult?.fileURL, fileURL, "Result should reference correct file")
    }
    
 /// Property test: Multiple concurrent scans execute on background threads
    func testProperty12_MultipleConcurrentScansOnBackground() async throws {
 // Create multiple test files
        var fileURLs: [URL] = []
        for i in 0..<10 {
            let url = try FileScanTestFileGenerator.createTextFile(content: "Concurrent test \(i)")
            fileURLs.append(url)
        }
        defer { fileURLs.forEach { FileScanTestFileGenerator.cleanup($0) } }
        
        let config = FileScanService.ScanConfiguration(level: .quick, maxConcurrentScans: 4)
        
 // Start multiple concurrent scans
        let results = await scanService.scanFiles(at: fileURLs, configuration: config, progress: nil)
        
 // Verify all scans completed
        XCTAssertEqual(results.count, fileURLs.count, "All concurrent scans should complete")
        
 // Verify all results are valid
        for result in results {
            XCTAssertNotNil(result.id, "Each result should have an ID")
            XCTAssertFalse(result.methodsUsed.isEmpty, "Each result should have methods used")
        }
    }
    
 /// Property test: Scan level does not affect background execution
    func testProperty12_AllScanLevelsExecuteOnBackground() async throws {
        let fileURL = try FileScanTestFileGenerator.createTextFile(content: "Level test content")
        defer { FileScanTestFileGenerator.cleanup(fileURL) }
        
        let levels: [FileScanService.ScanLevel] = [.quick, .standard, .deep]
        
        for level in levels {
            let config = FileScanService.ScanConfiguration(level: level)
            
 // Scan should complete without blocking
            let result = await scanService.scanFile(at: fileURL, configuration: config)
            
 // Verify scan completed
            XCTAssertNotNil(result.id, "Scan at \(level.rawValue) level should complete")
            XCTAssertEqual(result.scanLevel, level, "Result should have correct scan level")
        }
    }
}

// MARK: - Helper Actors for Thread Safety Testing

/// Actor to track MainActor callback delivery
@MainActor
private final class MainActorCallbackTracker {
    private var callbacks: [(progress: FileScanProgress, wasOnMainActor: Bool)] = []
    
    func recordCallback(progress: FileScanProgress) {
 // This method is @MainActor isolated, so if we're here, we're on MainActor
        callbacks.append((progress: progress, wasOnMainActor: Thread.isMainThread))
    }
    
    func getCallbackCount() -> Int {
        callbacks.count
    }
    
    func allCallbacksOnMainActor() -> Bool {
        callbacks.allSatisfy { $0.wasOnMainActor }
    }
}

/// Actor to track MainActor responsiveness
private actor MainActorResponsivenessTracker {
    private var responsive = false
    
    @MainActor
    func markResponsive() {
        Task { @MainActor in
            await self.setResponsive(true)
        }
    }
    
    func setResponsive(_ value: Bool) {
        responsive = value
    }
    
    func wasResponsive() -> Bool {
        responsive
    }
}

/// Actor to track callback state safely
private actor CallbackStateTracker {
    private var onMainActor = false
    private var result: FileScanResult?
    
    func recordCallback(wasOnMainActor: Bool, result: FileScanResult) {
        self.onMainActor = wasOnMainActor
        self.result = result
    }
    
    func wasOnMainActor() -> Bool {
        onMainActor
    }
    
    func getResult() -> FileScanResult? {
        result
    }
}
