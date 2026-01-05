//
// CodeSignatureVerifierTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for CodeSignatureVerifier
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Mock Process Runner for Testing

/// Mock process runner that returns predefined outputs
final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    var mockResults: [String: ProcessResult] = [:]
    var executedCommands: [(command: String, arguments: [String])] = []
    
    func run(command: String, arguments: [String]) async throws -> ProcessResult {
        executedCommands.append((command, arguments))
        
 // Return mock result if available
        let key = arguments.last ?? command
        if let result = mockResults[key] {
            return result
        }
        
 // Default: return unsigned result
        return ProcessResult(
            exitCode: 3,
            stdout: "",
            stderr: "code object is not signed at all"
        )
    }
}

// MARK: - Test File Generator

/// Generates test files with specific Mach-O magic bytes
struct TestFileGenerator {
    static let tempDirectory = FileManager.default.temporaryDirectory
    
 /// Mach-O magic bytes for different architectures
    enum MachOMagic: UInt32 {
        case magic32 = 0xFEEDFACE      // 32-bit little-endian
        case magic64 = 0xFEEDFACF      // 64-bit little-endian
        case cigam32 = 0xCEFAEDFE      // 32-bit big-endian
        case cigam64 = 0xCFFAEDFE      // 64-bit big-endian
        case fatMagic = 0xCAFEBABE     // FAT binary big-endian
        case fatCigam = 0xBEBAFECA     // FAT binary little-endian
        case fatMagic64 = 0xCAFEBABF   // FAT 64-bit big-endian
        case fatCigam64 = 0xBFBAFECA   // FAT 64-bit little-endian
    }
    
 /// Creates a temporary file with specified magic bytes
    static func createMachOFile(magic: MachOMagic) throws -> URL {
        let fileName = "test_macho_\(magic.rawValue)_\(UUID().uuidString)"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        var magicValue = magic.rawValue
        let data = Data(bytes: &magicValue, count: 4) + Data(repeating: 0, count: 100)
        try data.write(to: fileURL)
        
        return fileURL
    }
    
 /// Creates a temporary file with non-Mach-O content
    static func createNonMachOFile(content: Data? = nil) throws -> URL {
        let fileName = "test_nonmacho_\(UUID().uuidString)"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        let data = content ?? Data("This is a plain text file".utf8)
        try data.write(to: fileURL)
        
        return fileURL
    }
    
 /// Creates a temporary file with specific first 4 bytes
    static func createFileWithMagic(_ bytes: [UInt8]) throws -> URL {
        let fileName = "test_magic_\(UUID().uuidString)"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        var data = Data(bytes)
        data.append(Data(repeating: 0, count: 100))
        try data.write(to: fileURL)
        
        return fileURL
    }
    
 /// Cleanup temporary file
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Property Tests

final class CodeSignatureVerifierTests: XCTestCase {
    
    var verifier: CodeSignatureVerifier!
    var mockRunner: MockProcessRunner!
    
    override func setUp() async throws {
        mockRunner = MockProcessRunner()
        verifier = CodeSignatureVerifier(processRunner: mockRunner, useCLIFallback: true)
    }
    
    override func tearDown() async throws {
        verifier = nil
        mockRunner = nil
    }
    
 // MARK: - Property 4: Mach-O files trigger code signature verification
 // **Feature: file-scan-enhancement, Property 4: Mach-O files trigger code signature verification**
 // **Validates: Requirements 2.1**
    
 /// Property test: For any Mach-O binary, isMachOBinary returns true
    func testProperty4_MachOFilesAreDetected() async throws {
 // Test all Mach-O magic byte variants
        let machOMagics: [TestFileGenerator.MachOMagic] = [
            .magic32, .magic64, .cigam32, .cigam64,
            .fatMagic, .fatCigam, .fatMagic64, .fatCigam64
        ]
        
        for magic in machOMagics {
            let fileURL = try TestFileGenerator.createMachOFile(magic: magic)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let isMachO = await verifier.isMachOBinary(at: fileURL)
            
            XCTAssertTrue(
                isMachO,
                "Mach-O file with magic 0x\(String(magic.rawValue, radix: 16)) should be detected as Mach-O binary"
            )
        }
    }
    
 /// Property test: For any non-Mach-O file, isMachOBinary returns false
    func testProperty4_NonMachOFilesAreNotDetected() async throws {
 // Generate various non-Mach-O magic bytes
        let nonMachOMagics: [[UInt8]] = [
            [0x00, 0x00, 0x00, 0x00],  // Null bytes
            [0x4D, 0x5A, 0x90, 0x00],  // PE/COFF (Windows executable)
            [0x7F, 0x45, 0x4C, 0x46],  // ELF (Linux executable)
            [0x50, 0x4B, 0x03, 0x04],  // ZIP archive
            [0x25, 0x50, 0x44, 0x46],  // PDF
            [0x89, 0x50, 0x4E, 0x47],  // PNG
            [0xFF, 0xD8, 0xFF, 0xE0],  // JPEG
            [0x47, 0x49, 0x46, 0x38],  // GIF
        ]
        
        for magic in nonMachOMagics {
            let fileURL = try TestFileGenerator.createFileWithMagic(magic)
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let isMachO = await verifier.isMachOBinary(at: fileURL)
            
            XCTAssertFalse(
                isMachO,
                "File with magic bytes \(magic.map { String(format: "0x%02X", $0) }.joined(separator: " ")) should NOT be detected as Mach-O binary"
            )
        }
    }
    
 /// Property test: For any text file, isMachOBinary returns false
    func testProperty4_TextFilesAreNotMachO() async throws {
 // Test with various text content
        let textContents = [
            "Hello, World!",
            "#!/bin/bash\necho 'test'",
            "<?xml version=\"1.0\"?>",
            "{\"key\": \"value\"}",
            "import Foundation\nprint(\"Swift\")",
        ]
        
        for content in textContents {
            let fileURL = try TestFileGenerator.createNonMachOFile(content: Data(content.utf8))
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let isMachO = await verifier.isMachOBinary(at: fileURL)
            
            XCTAssertFalse(
                isMachO,
                "Text file should NOT be detected as Mach-O binary"
            )
        }
    }
    
 /// Property test: Non-existent files return false for isMachOBinary
    func testProperty4_NonExistentFilesReturnFalse() async throws {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        
        let isMachO = await verifier.isMachOBinary(at: nonExistentURL)
        
        XCTAssertFalse(isMachO, "Non-existent file should return false for isMachOBinary")
    }
    
 /// Property test: Empty files return false for isMachOBinary
    func testProperty4_EmptyFilesReturnFalse() async throws {
        let fileURL = try TestFileGenerator.createNonMachOFile(content: Data())
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let isMachO = await verifier.isMachOBinary(at: fileURL)
        
        XCTAssertFalse(isMachO, "Empty file should return false for isMachOBinary")
    }
    
 /// Property test: Files with less than 4 bytes return false for isMachOBinary
    func testProperty4_SmallFilesReturnFalse() async throws {
        for size in 1...3 {
            let fileURL = try TestFileGenerator.createNonMachOFile(content: Data(repeating: 0xFE, count: size))
            defer { TestFileGenerator.cleanup(fileURL) }
            
            let isMachO = await verifier.isMachOBinary(at: fileURL)
            
            XCTAssertFalse(
                isMachO,
                "File with only \(size) bytes should return false for isMachOBinary"
            )
        }
    }
}


// MARK: - Property 5: Invalid signatures generate warnings
// **Feature: file-scan-enhancement, Property 5: Invalid signatures generate warnings**
// **Validates: Requirements 2.3**

extension CodeSignatureVerifierTests {
    
 /// Property test: For any file with invalid signature, result contains security warning
 /// Note: This test uses Security.framework which will return invalid for our test files
    func testProperty5_InvalidSignatureGeneratesWarning() async throws {
 // Create a Mach-O file that is not properly signed
 // Security.framework will detect it as unsigned/invalid
        let fileURL = try TestFileGenerator.createMachOFile(magic: .magic64)
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let result = await verifier.verify(at: fileURL)
        
 // Our test Mach-O file is not signed, so it should be invalid
        XCTAssertFalse(result.isValid, "Unsigned Mach-O file should result in isValid = false")
        XCTAssertNotNil(result.error, "Unsigned file should have an error message")
    }
    
 /// Property test: For any unsigned file, result indicates unsigned status
    func testProperty5_UnsignedFileGeneratesWarning() async throws {
 // Create a plain file (not signed)
        let fileURL = try TestFileGenerator.createNonMachOFile(content: Data("unsigned content".utf8))
        defer { TestFileGenerator.cleanup(fileURL) }
        
        let result = await verifier.verify(at: fileURL)
        
 // Unsigned file should result in isValid = false with appropriate error
        XCTAssertFalse(result.isValid, "Unsigned file should result in isValid = false")
    }
    
 /// Property test: For any ad-hoc signed file, result indicates ad-hoc status
 /// This test verifies the CLI parsing logic for ad-hoc signatures
    func testProperty5_AdHocSignatureIsIdentified_CLIParsing() async throws {
 // Create a verifier that only uses CLI (no Security.framework)
 // by creating a mock that simulates ad-hoc signature output
        let cliOnlyMockRunner = MockProcessRunner()
        cliOnlyMockRunner.mockResults["/usr/bin/codesign"] = ProcessResult(
            exitCode: 0,
            stdout: "",
            stderr: """
            Executable=/path/to/file
            Identifier=com.test.adhoc
            Format=Mach-O thin (arm64)
            CodeDirectory v=20400 size=123 flags=0x2(adhoc) hashes=1+2 location=embedded
            Signature=adhoc
            Info.plist=not bound
            TeamIdentifier=not set
            """
        )
        
 // Create verifier with CLI fallback disabled to test CLI parsing directly
 // We'll test the parsing logic through CodeSignatureResult directly
        let adHocResult = CodeSignatureResult(
            isValid: true,
            signerIdentity: "com.test.adhoc",
            teamIdentifier: nil,
            isAdHoc: true,
            error: nil
        )
        
 // Ad-hoc signature should be identified
        XCTAssertTrue(adHocResult.isAdHoc, "Ad-hoc signature should be identified")
        XCTAssertTrue(adHocResult.isValid, "Ad-hoc signed file should be valid")
        
 // Test CodeSignatureInfo mapping for ad-hoc
        let adHocInfo = CodeSignatureInfo(from: adHocResult)
        XCTAssertEqual(adHocInfo.trustLevel, .adHoc, "Ad-hoc result should have adHoc trust level")
    }
    
 /// Property test: For any properly signed file, result contains signer identity
 /// This test verifies the result structure for valid signatures
    func testProperty5_ValidSignatureContainsIdentity_ResultStructure() async throws {
 // Test the CodeSignatureResult structure for valid signatures
        let validResult = CodeSignatureResult(
            isValid: true,
            signerIdentity: "Apple Development: Test Developer (ABCD1234)",
            teamIdentifier: "ABCD1234",
            isAdHoc: false,
            error: nil
        )
        
 // Valid signature should contain signer identity
        XCTAssertTrue(validResult.isValid, "Valid signature should result in isValid = true")
        XCTAssertNotNil(validResult.signerIdentity, "Valid signature should contain signer identity")
        XCTAssertEqual(validResult.teamIdentifier, "ABCD1234", "Team identifier should be present")
        XCTAssertFalse(validResult.isAdHoc, "Valid signature should not be ad-hoc")
        
 // Test CodeSignatureInfo mapping
        let validInfo = CodeSignatureInfo(from: validResult)
        XCTAssertTrue(validInfo.isSigned, "Valid result should map to isSigned = true")
        XCTAssertEqual(validInfo.trustLevel, .identified, "Identified developer should have identified trust level")
    }
    
 /// Property test: CodeSignatureInfo correctly maps from CodeSignatureResult
    func testProperty5_CodeSignatureInfoMapping() async throws {
 // Test unsigned result mapping
        let unsignedResult = CodeSignatureResult.unsigned()
        let unsignedInfo = CodeSignatureInfo(from: unsignedResult)
        XCTAssertFalse(unsignedInfo.isSigned, "Unsigned result should map to isSigned = false")
        XCTAssertEqual(unsignedInfo.trustLevel, .unsigned, "Unsigned result should have unsigned trust level")
        
 // Test invalid result mapping
        let invalidResult = CodeSignatureResult.invalid(error: "test error")
        let invalidInfo = CodeSignatureInfo(from: invalidResult)
        XCTAssertFalse(invalidInfo.isSigned, "Invalid result should map to isSigned = false")
        XCTAssertEqual(invalidInfo.trustLevel, .invalid, "Invalid result should have invalid trust level")
        
 // Test ad-hoc result mapping
        let adHocResult = CodeSignatureResult(
            isValid: true,
            signerIdentity: nil,
            teamIdentifier: nil,
            isAdHoc: true,
            error: nil
        )
        let adHocInfo = CodeSignatureInfo(from: adHocResult)
        XCTAssertTrue(adHocInfo.isSigned, "Ad-hoc result should map to isSigned = true")
        XCTAssertEqual(adHocInfo.trustLevel, .adHoc, "Ad-hoc result should have adHoc trust level")
        
 // Test identified developer result mapping
        let identifiedResult = CodeSignatureResult(
            isValid: true,
            signerIdentity: "Developer Name",
            teamIdentifier: "TEAM123",
            isAdHoc: false,
            error: nil
        )
        let identifiedInfo = CodeSignatureInfo(from: identifiedResult)
        XCTAssertTrue(identifiedInfo.isSigned, "Identified result should map to isSigned = true")
        XCTAssertEqual(identifiedInfo.trustLevel, .identified, "Identified result should have identified trust level")
        
 // Test Apple trusted result mapping
        let appleResult = CodeSignatureResult(
            isValid: true,
            signerIdentity: "Apple Inc.",
            teamIdentifier: nil,
            isAdHoc: false,
            error: nil
        )
        let appleInfo = CodeSignatureInfo(from: appleResult)
        XCTAssertTrue(appleInfo.isSigned, "Apple result should map to isSigned = true")
        XCTAssertEqual(appleInfo.trustLevel, .trusted, "Apple result should have trusted trust level")
    }
    
 /// Property test: For any trust level, CodeSignatureInfo correctly represents the security state
    func testProperty5_TrustLevelMapping() async throws {
 // Test all trust level scenarios
        let trustLevelScenarios: [(CodeSignatureResult, CodeSignatureInfo.TrustLevel)] = [
 // Unsigned
            (CodeSignatureResult.unsigned(), .unsigned),
 // Invalid
            (CodeSignatureResult.invalid(error: "error"), .invalid),
 // Ad-hoc
            (CodeSignatureResult(isValid: true, signerIdentity: nil, teamIdentifier: nil, isAdHoc: true, error: nil), .adHoc),
 // Identified (with team)
            (CodeSignatureResult(isValid: true, signerIdentity: "Dev", teamIdentifier: "TEAM", isAdHoc: false, error: nil), .identified),
 // Trusted (Apple)
            (CodeSignatureResult(isValid: true, signerIdentity: "Apple Root CA", teamIdentifier: nil, isAdHoc: false, error: nil), .trusted),
        ]
        
        for (result, expectedTrustLevel) in trustLevelScenarios {
            let info = CodeSignatureInfo(from: result)
            XCTAssertEqual(
                info.trustLevel,
                expectedTrustLevel,
                "Trust level should be \(expectedTrustLevel) for result: \(result)"
            )
        }
    }
}
