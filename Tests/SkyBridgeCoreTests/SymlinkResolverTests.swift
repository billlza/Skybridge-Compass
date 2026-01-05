//
// SymlinkResolverTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for SymlinkResolver
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test Data Generator

/// Generates test data for SymlinkResolver tests
struct SymlinkTestGenerator {
    
 /// Creates a temporary directory for testing
    static func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymlinkTests_\(UUID().uuidString)")
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
    
 /// Creates a symbolic link to a target
    static func createSymlink(at linkURL: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)
    }
    
 /// Creates a symbolic link with a relative path target
    static func createRelativeSymlink(at linkURL: URL, relativePath: String) throws {
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: relativePath)
    }
    
 /// Cleans up a temporary directory
    static func cleanup(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
    
 /// Creates a chain of symlinks: link1 -> link2 -> ... -> target
 /// Returns the first link in the chain
    static func createSymlinkChain(
        in directory: URL,
        depth: Int,
        targetFile: URL
    ) throws -> URL {
        guard depth > 0 else { return targetFile }
        
        var currentTarget = targetFile
        var firstLink: URL?
        
 // Create chain from end to beginning
        for i in (0..<depth).reversed() {
            let linkURL = directory.appendingPathComponent("chain_link_\(i).txt")
            try createSymlink(at: linkURL, to: currentTarget)
            currentTarget = linkURL
            if i == 0 {
                firstLink = linkURL
            }
        }
        
        return firstLink ?? targetFile
    }
}

// MARK: - Property Test: Symlink Resolution Security
// **Feature: security-hardening, Property 15: Symlink resolution security**
// **Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5**

final class SymlinkResolverSecurityTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = try SymlinkTestGenerator.createTempDirectory()
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            SymlinkTestGenerator.cleanup(directory: tempDir)
        }
        try await super.tearDown()
    }
    
 /// **Feature: security-hardening, Property 15: Symlink resolution security**
 /// **Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5**
 ///
 /// Property: For any symbolic link, resolution SHALL use realpath() and reject if:
 /// - realpath fails
 /// - resolved path outside scan root
 /// - depth exceeded
 /// - circular link detected
 ///
 /// This test verifies all security aspects of symlink resolution.
    func testProperty_SymlinkResolutionSecurity() async throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Create a subdirectory for this iteration
            let iterationDir = tempDirectory.appendingPathComponent("iter_\(iteration)")
            try FileManager.default.createDirectory(at: iterationDir, withIntermediateDirectories: true)
            
            defer {
                try? FileManager.default.removeItem(at: iterationDir)
            }
            
 // Randomly choose which scenario to test
            let scenario = Int.random(in: 0...4)
            
            switch scenario {
            case 0:
 // Test successful resolution
                try await testSuccessfulResolution(in: iterationDir, iteration: iteration)
            case 1:
 // Test depth limit enforcement
                try await testDepthLimitEnforcement(in: iterationDir, iteration: iteration)
            case 2:
 // Test scan root boundary
                try await testScanRootBoundary(in: iterationDir, iteration: iteration)
            case 3:
 // Test inaccessible file handling
                try await testInaccessibleFileHandling(in: iterationDir, iteration: iteration)
            case 4:
 // Test relative symlink resolution
                try await testRelativeSymlinkResolution(in: iterationDir, iteration: iteration)
            default:
                break
            }
        }
    }
    
 /// Test successful symlink resolution
 /// **Validates: Requirements 6.1**
    private func testSuccessfulResolution(in directory: URL, iteration: Int) async throws {
 // Create a target file
        let targetFile = try SymlinkTestGenerator.createTestFile(
            in: directory,
            name: "target_\(iteration).txt"
        )
        
 // Create a symlink chain with random depth (within limits)
        let maxDepth = 10
        let chainDepth = Int.random(in: 1...min(5, maxDepth))
        
        let firstLink = try SymlinkTestGenerator.createSymlinkChain(
            in: directory,
            depth: chainDepth,
            targetFile: targetFile
        )
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: firstLink, scanRoot: directory)
        
 // Property 1: Resolution should succeed
        XCTAssertTrue(
            result.isSuccess,
            "Iteration \(iteration): Resolution should succeed for valid symlink chain of depth \(chainDepth)"
        )
        
 // Property 2: Resolved URL should point to the target file
        XCTAssertNotNil(result.resolvedURL, "Iteration \(iteration): resolvedURL should not be nil")
        
        if let resolvedURL = result.resolvedURL {
 // Get canonical paths for comparison
            let resolvedCanonical = resolvedURL.standardizedFileURL.path
            let targetCanonical = targetFile.standardizedFileURL.path
            
            XCTAssertEqual(
                resolvedCanonical,
                targetCanonical,
                "Iteration \(iteration): Resolved path should match target file"
            )
        }
        
 // Property 3: Chain depth should be accurate
        XCTAssertEqual(
            result.chainDepth,
            chainDepth,
            "Iteration \(iteration): Chain depth should be \(chainDepth), got \(result.chainDepth)"
        )
        
 // Property 4: No error should be present
        XCTAssertNil(
            result.error,
            "Iteration \(iteration): No error should be present for successful resolution"
        )
    }
    
 /// Test depth limit enforcement
 /// **Validates: Requirements 6.4**
    private func testDepthLimitEnforcement(in directory: URL, iteration: Int) async throws {
 // Create a target file
        let targetFile = try SymlinkTestGenerator.createTestFile(
            in: directory,
            name: "deep_target_\(iteration).txt"
        )
        
 // Use a small max depth for testing
        let maxDepth = Int.random(in: 2...5)
        
 // Create a chain that exceeds the limit
        let chainDepth = maxDepth + Int.random(in: 1...3)
        
        let firstLink = try SymlinkTestGenerator.createSymlinkChain(
            in: directory,
            depth: chainDepth,
            targetFile: targetFile
        )
        
        let resolver = SymlinkResolver.createForTesting(maxSymlinkDepth: maxDepth)
        let result = resolver.resolve(url: firstLink, scanRoot: directory)
        
 // Property 1: Resolution should fail
        XCTAssertFalse(
            result.isSuccess,
            "Iteration \(iteration): Resolution should fail when chain depth (\(chainDepth)) exceeds max (\(maxDepth))"
        )
        
 // Property 2: Error should be depthExceeded
        XCTAssertEqual(
            result.error,
            .depthExceeded,
            "Iteration \(iteration): Error should be depthExceeded"
        )
        
 // Property 3: Chain depth should be at the limit
        XCTAssertEqual(
            result.chainDepth,
            maxDepth,
            "Iteration \(iteration): Chain depth should be at max (\(maxDepth)) when limit exceeded"
        )
        
 // Property 4: resolvedURL should be nil
        XCTAssertNil(
            result.resolvedURL,
            "Iteration \(iteration): resolvedURL should be nil when depth exceeded"
        )
    }
    
 /// Test scan root boundary enforcement
 /// **Validates: Requirements 6.3**
    private func testScanRootBoundary(in directory: URL, iteration: Int) async throws {
 // Create a subdirectory as the scan root
        let scanRoot = directory.appendingPathComponent("scan_root_\(iteration)")
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        
 // Create a file OUTSIDE the scan root (in parent directory)
        let outsideFile = try SymlinkTestGenerator.createTestFile(
            in: directory,
            name: "outside_\(iteration).txt"
        )
        
 // Create a symlink INSIDE the scan root that points OUTSIDE
        let symlinkInRoot = scanRoot.appendingPathComponent("escape_link_\(iteration).txt")
        try SymlinkTestGenerator.createSymlink(at: symlinkInRoot, to: outsideFile)
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: symlinkInRoot, scanRoot: scanRoot)
        
 // Property 1: Resolution should fail
        XCTAssertFalse(
            result.isSuccess,
            "Iteration \(iteration): Resolution should fail when target is outside scan root"
        )
        
 // Property 2: Error should be outsideScanRoot
        XCTAssertEqual(
            result.error,
            .outsideScanRoot,
            "Iteration \(iteration): Error should be outsideScanRoot"
        )
        
 // Property 3: resolvedURL should be nil
        XCTAssertNil(
            result.resolvedURL,
            "Iteration \(iteration): resolvedURL should be nil when outside scan root"
        )
    }
    
 /// Test inaccessible file handling
 /// **Validates: Requirements 6.2**
    private func testInaccessibleFileHandling(in directory: URL, iteration: Int) async throws {
 // Create a symlink to a non-existent file
        _ = directory.appendingPathComponent("nonexistent_\(iteration).txt")
        let brokenSymlink = directory.appendingPathComponent("broken_link_\(iteration).txt")
        
 // Create symlink pointing to non-existent file
        try SymlinkTestGenerator.createRelativeSymlink(
            at: brokenSymlink,
            relativePath: "nonexistent_\(iteration).txt"
        )
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: brokenSymlink, scanRoot: directory)
        
 // Property 1: Resolution should fail
        XCTAssertFalse(
            result.isSuccess,
            "Iteration \(iteration): Resolution should fail for broken symlink"
        )
        
 // Property 2: Error should be realpathFailed or inaccessible
        XCTAssertTrue(
            result.error == .realpathFailed || result.error == .inaccessible,
            "Iteration \(iteration): Error should be realpathFailed or inaccessible, got \(String(describing: result.error))"
        )
        
 // Property 3: resolvedURL should be nil
        XCTAssertNil(
            result.resolvedURL,
            "Iteration \(iteration): resolvedURL should be nil for broken symlink"
        )
    }
    
 /// Test relative symlink resolution
 /// **Validates: Requirements 6.1**
    private func testRelativeSymlinkResolution(in directory: URL, iteration: Int) async throws {
 // Create a subdirectory
        let subDir = directory.appendingPathComponent("subdir_\(iteration)")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        
 // Create a target file in the subdirectory
        let targetFile = try SymlinkTestGenerator.createTestFile(
            in: subDir,
            name: "target.txt"
        )
        
 // Create a symlink in the parent directory with relative path
        let relativeSymlink = directory.appendingPathComponent("relative_link_\(iteration).txt")
        try SymlinkTestGenerator.createRelativeSymlink(
            at: relativeSymlink,
            relativePath: "subdir_\(iteration)/target.txt"
        )
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: relativeSymlink, scanRoot: directory)
        
 // Property 1: Resolution should succeed
        XCTAssertTrue(
            result.isSuccess,
            "Iteration \(iteration): Resolution should succeed for relative symlink"
        )
        
 // Property 2: Resolved URL should point to the target file
        if let resolvedURL = result.resolvedURL {
            let resolvedCanonical = resolvedURL.standardizedFileURL.path
            let targetCanonical = targetFile.standardizedFileURL.path
            
            XCTAssertEqual(
                resolvedCanonical,
                targetCanonical,
                "Iteration \(iteration): Resolved path should match target file"
            )
        }
        
 // Property 3: Chain depth should be 1
        XCTAssertEqual(
            result.chainDepth,
            1,
            "Iteration \(iteration): Chain depth should be 1 for single symlink"
        )
    }
    
 // MARK: - Circular Link Detection Tests
    
 /// Test circular symlink detection
 /// **Validates: Requirements 6.5**
    func testCircularSymlinkDetection() async throws {
 // Create a circular symlink: link1 -> link2 -> link1
        let link1 = tempDirectory.appendingPathComponent("circular1.txt")
        let link2 = tempDirectory.appendingPathComponent("circular2.txt")
        
 // Create link2 first (pointing to where link1 will be)
        try SymlinkTestGenerator.createRelativeSymlink(at: link2, relativePath: "circular1.txt")
        
 // Create link1 pointing to link2
        try SymlinkTestGenerator.createRelativeSymlink(at: link1, relativePath: "circular2.txt")
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: link1, scanRoot: tempDirectory)
        
 // Resolution should fail with circularLink error
        XCTAssertFalse(result.isSuccess, "Resolution should fail for circular symlink")
        XCTAssertEqual(result.error, .circularLink, "Error should be circularLink")
        XCTAssertNil(result.resolvedURL, "resolvedURL should be nil for circular symlink")
    }
    
 /// Test self-referencing symlink
 /// **Validates: Requirements 6.5**
    func testSelfReferencingSymlink() async throws {
 // Create a symlink that points to itself
        let selfLink = tempDirectory.appendingPathComponent("self_ref.txt")
        try SymlinkTestGenerator.createRelativeSymlink(at: selfLink, relativePath: "self_ref.txt")
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: selfLink, scanRoot: tempDirectory)
        
 // Resolution should fail with circularLink error
        XCTAssertFalse(result.isSuccess, "Resolution should fail for self-referencing symlink")
        XCTAssertEqual(result.error, .circularLink, "Error should be circularLink")
    }
    
 // MARK: - Depth Limit Boundary Tests
    
 /// Test exact depth limit boundary
 /// **Validates: Requirements 6.4**
    func testDepthLimitBoundary() async throws {
        let maxDepth = 5
        
 // Test at exactly the limit (should succeed)
        let atLimitDir = tempDirectory.appendingPathComponent("at_limit")
        try FileManager.default.createDirectory(at: atLimitDir, withIntermediateDirectories: true)
        
        let targetAtLimit = try SymlinkTestGenerator.createTestFile(in: atLimitDir, name: "target.txt")
        let chainAtLimit = try SymlinkTestGenerator.createSymlinkChain(
            in: atLimitDir,
            depth: maxDepth,
            targetFile: targetAtLimit
        )
        
        let resolver = SymlinkResolver.createForTesting(maxSymlinkDepth: maxDepth)
        let atLimitResult = resolver.resolve(url: chainAtLimit, scanRoot: atLimitDir)
        
        XCTAssertTrue(atLimitResult.isSuccess, "Resolution at exact depth limit should succeed")
        XCTAssertEqual(atLimitResult.chainDepth, maxDepth, "Chain depth should be exactly \(maxDepth)")
        
 // Test one over the limit (should fail)
        let overLimitDir = tempDirectory.appendingPathComponent("over_limit")
        try FileManager.default.createDirectory(at: overLimitDir, withIntermediateDirectories: true)
        
        let targetOverLimit = try SymlinkTestGenerator.createTestFile(in: overLimitDir, name: "target.txt")
        let chainOverLimit = try SymlinkTestGenerator.createSymlinkChain(
            in: overLimitDir,
            depth: maxDepth + 1,
            targetFile: targetOverLimit
        )
        
        let overLimitResult = resolver.resolve(url: chainOverLimit, scanRoot: overLimitDir)
        
        XCTAssertFalse(overLimitResult.isSuccess, "Resolution over depth limit should fail")
        XCTAssertEqual(overLimitResult.error, .depthExceeded, "Error should be depthExceeded")
    }
    
 // MARK: - Scan Root Tests
    
 /// Test that file within scan root is allowed
 /// **Validates: Requirements 6.3, 6.6, 6.7**
    func testFileWithinScanRootAllowed() async throws {
 // Create nested directories
        let scanRoot = tempDirectory.appendingPathComponent("scan_root")
        let subDir = scanRoot.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        
 // Create a file in the subdirectory
        let targetFile = try SymlinkTestGenerator.createTestFile(in: subDir, name: "nested.txt")
        
 // Create a symlink in scan root pointing to nested file
        let symlink = scanRoot.appendingPathComponent("link_to_nested.txt")
        try SymlinkTestGenerator.createSymlink(at: symlink, to: targetFile)
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: symlink, scanRoot: scanRoot)
        
        XCTAssertTrue(result.isSuccess, "Symlink to file within scan root should succeed")
        XCTAssertNil(result.error, "No error for file within scan root")
    }
    
 /// Test that symlink escaping via .. is detected
 /// **Validates: Requirements 6.3**
    func testSymlinkEscapeViaParentDirectory() async throws {
 // Create scan root
        let scanRoot = tempDirectory.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        
 // Create a file outside scan root (needed for the symlink to have a valid target)
        _ = try SymlinkTestGenerator.createTestFile(in: tempDirectory, name: "secret.txt")
        
 // Create a symlink using .. to escape
        let escapeLink = scanRoot.appendingPathComponent("escape.txt")
        try SymlinkTestGenerator.createRelativeSymlink(at: escapeLink, relativePath: "../secret.txt")
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: escapeLink, scanRoot: scanRoot)
        
        XCTAssertFalse(result.isSuccess, "Symlink escaping via .. should fail")
        XCTAssertEqual(result.error, .outsideScanRoot, "Error should be outsideScanRoot")
    }
    
 // MARK: - Regular File Tests
    
 /// Test that regular files (non-symlinks) resolve correctly
    func testRegularFileResolution() async throws {
        let regularFile = try SymlinkTestGenerator.createTestFile(
            in: tempDirectory,
            name: "regular.txt"
        )
        
        let resolver = SymlinkResolver()
        let result = resolver.resolve(url: regularFile, scanRoot: tempDirectory)
        
        XCTAssertTrue(result.isSuccess, "Regular file should resolve successfully")
        XCTAssertEqual(result.chainDepth, 0, "Chain depth for regular file should be 0")
        XCTAssertNotNil(result.resolvedURL, "resolvedURL should not be nil")
    }
    
 /// Test resolution without explicit scan root (uses parent directory)
    func testResolutionWithoutExplicitScanRoot() async throws {
        let targetFile = try SymlinkTestGenerator.createTestFile(
            in: tempDirectory,
            name: "target.txt"
        )
        
        let symlink = tempDirectory.appendingPathComponent("link.txt")
        try SymlinkTestGenerator.createSymlink(at: symlink, to: targetFile)
        
        let resolver = SymlinkResolver()
 // Use the overload without scanRoot parameter
        let result = resolver.resolve(url: symlink)
        
        XCTAssertTrue(result.isSuccess, "Resolution without explicit scan root should succeed")
    }
}
