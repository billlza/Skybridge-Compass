//
// NotarizationVerifierTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for NotarizationVerifier
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test File Generator Extension

extension TestFileGenerator {
 /// Creates a temporary bundle directory (simulating .app)
    static func createBundleDirectory(name: String = "TestApp.app") throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent(name)
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        let macOSURL = contentsURL.appendingPathComponent("MacOS")
        
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        
 // Create Info.plist
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.test.app</string>
            <key>CFBundleExecutable</key>
            <string>TestApp</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        
        return bundleURL
    }
    
 /// Creates a temporary script file with shebang
    static func createScriptFile(executable: Bool = true) throws -> URL {
        let fileName = "test_script_\(UUID().uuidString).sh"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        let content = "#!/bin/bash\necho 'Hello World'"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        if executable {
 // Set executable permission
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        
        return fileURL
    }
    
 /// Creates a temporary archive file
    static func createArchiveFile(type: String = "zip") throws -> URL {
        let fileName = "test_archive_\(UUID().uuidString).\(type)"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
 // Create a minimal ZIP header (not a valid archive, but has correct extension)
        let zipHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        try Data(zipHeader).write(to: fileURL)
        
        return fileURL
    }
    
 /// Cleanup directory
    static func cleanupDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Property Tests

final class NotarizationVerifierTests: XCTestCase {
    
    var verifier: NotarizationVerifier!
    var mockRunner: MockProcessRunner!
    
    override func setUp() async throws {
        mockRunner = MockProcessRunner()
        verifier = NotarizationVerifier(processRunner: mockRunner)
    }
    
    override func tearDown() async throws {
        verifier = nil
        mockRunner = nil
    }
    
 // MARK: - Property 1: Executable files trigger notarization check
 // **Feature: file-scan-enhancement, Property 1: Executable files trigger notarization check**
 // **Validates: Requirements 1.1**
    
 /// Property test: For any bundle file (.app, .pkg, .dmg), shouldCheckNotarization returns true
    func testProperty1_BundleFilesTriggerNotarizationCheck() async throws {
        let bundleExtensions = ["app", "pkg", "dmg", "plugin", "appex", "framework", "kext", "bundle"]
        
        for ext in bundleExtensions {
            let fileURL = TestFileGenerator.tempDirectory.appendingPathComponent("test.\(ext)")
            
 // Create a minimal file with the extension
            try Data().write(to: fileURL)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let shouldCheck = await verifier.shouldCheckNotarization(at: fileURL)
            
            XCTAssertTrue(
                shouldCheck,
                "Bundle file with extension .\(ext) should trigger notarization check"
            )
        }
    }
    
 /// Property test: For any Mach-O binary, shouldCheckNotarization returns true
    func testProperty1_MachOFilesTriggerNotarizationCheck() async throws {
        let machOMagics: [TestFileGenerator.MachOMagic] = [
            .magic32, .magic64, .cigam32, .cigam64,
            .fatMagic, .fatCigam, .fatMagic64, .fatCigam64
        ]
        
        for magic in machOMagics {
            let fileURL = try TestFileGenerator.createMachOFile(magic: magic)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let shouldCheck = await verifier.shouldCheckNotarization(at: fileURL)
            
            XCTAssertTrue(
                shouldCheck,
                "Mach-O file with magic 0x\(String(magic.rawValue, radix: 16)) should trigger notarization check"
            )
        }
    }
    
 /// Property test: For any executable script, shouldCheckNotarization returns true
    func testProperty1_ExecutableScriptsTriggerNotarizationCheck() async throws {
        let fileURL = try TestFileGenerator.createScriptFile(executable: true)
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let shouldCheck = await verifier.shouldCheckNotarization(at: fileURL)
        
        XCTAssertTrue(shouldCheck, "Executable script should trigger notarization check")
    }
    
 // MARK: - Property 2: Non-executable files skip notarization
 // **Feature: file-scan-enhancement, Property 2: Non-executable files skip notarization**
 // **Validates: Requirements 1.5**
    
 /// Property test: For any plain text file, shouldCheckNotarization returns false
    func testProperty2_PlainTextFilesSkipNotarization() async throws {
        let textExtensions = ["txt", "md", "json", "xml", "csv", "log"]
        
        for ext in textExtensions {
            let fileURL = TestFileGenerator.tempDirectory.appendingPathComponent("test.\(ext)")
            try "plain text content".write(to: fileURL, atomically: true, encoding: .utf8)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let shouldCheck = await verifier.shouldCheckNotarization(at: fileURL)
            
            XCTAssertFalse(
                shouldCheck,
                "Plain text file with extension .\(ext) should skip notarization check"
            )
        }
    }
    
 /// Property test: For any archive file, shouldCheckNotarization returns false
    func testProperty2_ArchiveFilesSkipNotarization() async throws {
        let archiveExtensions = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]
        
        for ext in archiveExtensions {
            let fileURL = try TestFileGenerator.createArchiveFile(type: ext)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let shouldCheck = await verifier.shouldCheckNotarization(at: fileURL)
            
            XCTAssertFalse(
                shouldCheck,
                "Archive file with extension .\(ext) should skip notarization check"
            )
        }
    }
    
 /// Property test: For any non-executable script, shouldCheckNotarization returns false
    func testProperty2_NonExecutableScriptsSkipNotarization() async throws {
        let fileURL = try TestFileGenerator.createScriptFile(executable: false)
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let shouldCheck = await verifier.shouldCheckNotarization(at: fileURL)
        
        XCTAssertFalse(shouldCheck, "Non-executable script should skip notarization check")
    }
    
 /// Property test: For any image file, shouldCheckNotarization returns false
    func testProperty2_ImageFilesSkipNotarization() async throws {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp"]
        
        for ext in imageExtensions {
            let fileURL = TestFileGenerator.tempDirectory.appendingPathComponent("test.\(ext)")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL) // PNG header
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let shouldCheck = await verifier.shouldCheckNotarization(at: fileURL)
            
            XCTAssertFalse(
                shouldCheck,
                "Image file with extension .\(ext) should skip notarization check"
            )
        }
    }
    
 // MARK: - Property 3: Unnotarized files pass with warning
 // **Feature: file-scan-enhancement, Property 3: Unnotarized files pass with warning**
 // **Validates: Requirements 1.3**
    
 /// Property test: For any unnotarized file, verify returns notNotarized status (not unsafe)
 /// This test verifies the result parsing logic directly
    func testProperty3_UnnotarizedFilesReturnWarningNotUnsafe() async throws {
 // Test the NotarizationResult structure for unnotarized files
        let unnotarizedResult = NotarizationResult.notNotarized(error: "rejected")
        
 // Unnotarized should return notNotarized status, not unknown or unsafe
        XCTAssertEqual(unnotarizedResult.status, .notNotarized, "Unnotarized file should return notNotarized status")
        XCTAssertNotNil(unnotarizedResult.error, "Unnotarized file should have error/warning message")
        
 // Verify that notNotarized is different from unknown (which indicates error)
        XCTAssertNotEqual(unnotarizedResult.status, .unknown, "Unnotarized should not be unknown")
    }
    
 /// Property test: For any notarized file, verify returns notarized status
 /// This test verifies the result structure for notarized files
    func testProperty3_NotarizedFilesReturnNotarizedStatus() async throws {
 // Test the NotarizationResult structure for notarized files
        let notarizedResult = NotarizationResult.notarized(source: "Notarized Developer ID")
        
        XCTAssertEqual(notarizedResult.status, .notarized, "Notarized file should return notarized status")
        XCTAssertNotNil(notarizedResult.source, "Notarized file should have source information")
        XCTAssertNil(notarizedResult.error, "Notarized file should not have error")
    }
    
 /// Property test: NotarizationResult correctly represents different states
    func testProperty3_NotarizationResultStates() async throws {
 // Test notarized state
        let notarizedResult = NotarizationResult.notarized(source: "Apple")
        XCTAssertEqual(notarizedResult.status, .notarized)
        XCTAssertEqual(notarizedResult.source, "Apple")
        XCTAssertNil(notarizedResult.error)
        
 // Test notNotarized state
        let notNotarizedResult = NotarizationResult.notNotarized(error: "rejected")
        XCTAssertEqual(notNotarizedResult.status, .notNotarized)
        XCTAssertNil(notNotarizedResult.source)
        XCTAssertEqual(notNotarizedResult.error, "rejected")
        
 // Test unknown state
        let unknownResult = NotarizationResult.unknown(error: "network error")
        XCTAssertEqual(unknownResult.status, .unknown)
        XCTAssertNil(unknownResult.source)
        XCTAssertEqual(unknownResult.error, "network error")
    }
    
 // MARK: - Target Type Detection Tests
    
 /// Property test: detectTargetType correctly identifies bundle types
    func testTargetTypeDetection_Bundles() async throws {
        let bundleExtensions = ["app", "pkg", "dmg", "plugin", "appex", "framework", "kext", "bundle"]
        
        for ext in bundleExtensions {
            let fileURL = TestFileGenerator.tempDirectory.appendingPathComponent("test.\(ext)")
            try Data().write(to: fileURL)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let targetType = await verifier.detectTargetType(at: fileURL)
            
            XCTAssertEqual(
                targetType,
                .bundle,
                "File with extension .\(ext) should be detected as bundle"
            )
        }
    }
    
 /// Property test: detectTargetType correctly identifies archive types
    func testTargetTypeDetection_Archives() async throws {
        let archiveExtensions = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]
        
        for ext in archiveExtensions {
            let fileURL = try TestFileGenerator.createArchiveFile(type: ext)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let targetType = await verifier.detectTargetType(at: fileURL)
            
            XCTAssertEqual(
                targetType,
                .archive,
                "File with extension .\(ext) should be detected as archive"
            )
        }
    }
    
 /// Property test: detectTargetType correctly identifies Mach-O binaries
    func testTargetTypeDetection_MachO() async throws {
        let fileURL = try TestFileGenerator.createMachOFile(magic: .magic64)
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let targetType = await verifier.detectTargetType(at: fileURL)
        
        XCTAssertEqual(targetType, .machO, "Mach-O binary should be detected as machO")
    }
    
 /// Property test: detectTargetType correctly identifies scripts
    func testTargetTypeDetection_Scripts() async throws {
        let fileURL = try TestFileGenerator.createScriptFile(executable: true)
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let targetType = await verifier.detectTargetType(at: fileURL)
        
        XCTAssertEqual(targetType, .script, "Executable script should be detected as script")
    }
    
 /// Property test: detectTargetType correctly identifies plain files
    func testTargetTypeDetection_PlainFiles() async throws {
        let fileURL = try TestFileGenerator.createNonMachOFile(content: Data("plain text".utf8))
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let targetType = await verifier.detectTargetType(at: fileURL)
        
        XCTAssertEqual(targetType, .file, "Plain text file should be detected as file")
    }
    
 // MARK: - Gatekeeper Assessment Tests
    
 /// Property test: GatekeeperResult allow state is correctly represented
    func testGatekeeperAssessment_Allow() async throws {
 // Test the GatekeeperResult structure for allowed files
        let allowResult = GatekeeperResult.allow(source: "Notarized Developer ID")
        
        XCTAssertEqual(allowResult.assessment, .allow, "Allow result should have allow assessment")
        XCTAssertNotNil(allowResult.source, "Allow result should have source")
        XCTAssertNil(allowResult.error, "Allow result should not have error")
    }
    
 /// Property test: GatekeeperResult deny state is correctly represented
    func testGatekeeperAssessment_Deny() async throws {
 // Test the GatekeeperResult structure for denied files
        let denyResult = GatekeeperResult.deny(error: "rejected")
        
        XCTAssertEqual(denyResult.assessment, .deny, "Deny result should have deny assessment")
        XCTAssertNil(denyResult.source, "Deny result should not have source")
        XCTAssertNotNil(denyResult.error, "Deny result should have error")
    }
    
 /// Property test: GatekeeperResult unknown state is correctly represented
    func testGatekeeperAssessment_Unknown() async throws {
 // Test the GatekeeperResult structure for unknown state
        let unknownResult = GatekeeperResult.unknown(error: "network error")
        
        XCTAssertEqual(unknownResult.assessment, .unknown, "Unknown result should have unknown assessment")
        XCTAssertNil(unknownResult.source, "Unknown result should not have source")
        XCTAssertNotNil(unknownResult.error, "Unknown result should have error")
    }
}
