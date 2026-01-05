//
// PathSanitizerTests.swift
// SkyBridgeCoreTests
//
// Unit tests for PathSanitizer
// **Feature: security-hardening**
// **Requirements: 12.6** - Sanitized error details (no absolute paths in user-visible output)
//

import XCTest
@testable import SkyBridgeCore

// MARK: - PathSanitizer Tests

final class PathSanitizerTests: XCTestCase {
    
 // MARK: - sanitize(URL) Tests
    
 /// Test that sanitize(URL) returns only the basename for standard paths
    func testSanitizeURL_ReturnsBasename() {
        let url = URL(fileURLWithPath: "/Users/test/Documents/secret.pdf")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "secret.pdf", "Should return only the filename")
    }
    
 /// Test sanitize with nested directory path
    func testSanitizeURL_NestedPath() {
        let url = URL(fileURLWithPath: "/var/folders/abc/xyz/T/temp_file.txt")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "temp_file.txt", "Should return only the filename from nested path")
    }
    
 /// Test sanitize with file without extension
    func testSanitizeURL_NoExtension() {
        let url = URL(fileURLWithPath: "/usr/local/bin/executable")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "executable", "Should return filename without extension")
    }
    
 /// Test sanitize with hidden file (dot prefix)
    func testSanitizeURL_HiddenFile() {
        let url = URL(fileURLWithPath: "/Users/test/.config")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, ".config", "Should return hidden filename with dot prefix")
    }
    
 /// Test sanitize with multiple extensions
    func testSanitizeURL_MultipleExtensions() {
        let url = URL(fileURLWithPath: "/path/to/archive.tar.gz")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "archive.tar.gz", "Should return filename with all extensions")
    }
    
 /// Test sanitize with spaces in filename
    func testSanitizeURL_SpacesInFilename() {
        let url = URL(fileURLWithPath: "/Users/test/My Documents/Important File.docx")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "Important File.docx", "Should handle spaces in filename")
    }
    
 /// Test sanitize with unicode characters
    func testSanitizeURL_UnicodeCharacters() {
        let url = URL(fileURLWithPath: "/Users/test/文档/报告.pdf")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "报告.pdf", "Should handle unicode characters")
    }
    
 /// Test sanitize with root path
    func testSanitizeURL_RootPath() {
        let url = URL(fileURLWithPath: "/")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "/", "Should handle root path")
    }
    
 // MARK: - sanitize(String) Tests
    
 /// Test that sanitize(String) returns only the basename
    func testSanitizeString_ReturnsBasename() {
        let path = "/Users/test/Documents/secret.pdf"
        let result = PathSanitizer.sanitize(path)
        
        XCTAssertEqual(result, "secret.pdf", "Should return only the filename")
    }
    
 /// Test sanitize string with trailing slash
    func testSanitizeString_TrailingSlash() {
        let path = "/Users/test/Documents/"
        let result = PathSanitizer.sanitize(path)
        
 // NSString.lastPathComponent handles trailing slash
        XCTAssertEqual(result, "Documents", "Should return directory name without trailing slash")
    }
    
 /// Test sanitize with relative path
    func testSanitizeString_RelativePath() {
        let path = "relative/path/to/file.txt"
        let result = PathSanitizer.sanitize(path)
        
        XCTAssertEqual(result, "file.txt", "Should handle relative paths")
    }
    
 /// Test sanitize with just filename
    func testSanitizeString_JustFilename() {
        let path = "filename.txt"
        let result = PathSanitizer.sanitize(path)
        
        XCTAssertEqual(result, "filename.txt", "Should return filename as-is")
    }
    
 // MARK: - sanitizeForLog Tests
    
 /// Test sanitizeForLog returns consistent format
 /// Note: In DEBUG builds, this returns full path; in RELEASE, returns hash+extension
    func testSanitizeForLog_URL_ReturnsNonEmptyString() {
        let url = URL(fileURLWithPath: "/Users/test/Documents/secret.pdf")
        let result = PathSanitizer.sanitizeForLog(url)
        
        XCTAssertFalse(result.isEmpty, "Should return non-empty string")
        
        #if DEBUG
 // In DEBUG, should return full path
        XCTAssertEqual(result, "/Users/test/Documents/secret.pdf", "DEBUG should return full path")
        #else
 // In RELEASE, should return hash prefix + extension
        XCTAssertTrue(result.hasSuffix(".pdf"), "RELEASE should preserve extension")
        XCTAssertFalse(result.contains("/"), "RELEASE should not contain path separators")
        XCTAssertTrue(result.count <= 13, "RELEASE format should be 8 hex chars + dot + extension")
        #endif
    }
    
 /// Test sanitizeForLog with path string
    func testSanitizeForLog_String_ReturnsNonEmptyString() {
        let path = "/var/log/system.log"
        let result = PathSanitizer.sanitizeForLog(path)
        
        XCTAssertFalse(result.isEmpty, "Should return non-empty string")
        
        #if DEBUG
        XCTAssertEqual(result, path, "DEBUG should return full path")
        #else
        XCTAssertTrue(result.hasSuffix(".log"), "RELEASE should preserve extension")
        XCTAssertFalse(result.contains("/"), "RELEASE should not contain path separators")
        #endif
    }
    
 /// Test sanitizeForLog with file without extension
    func testSanitizeForLog_NoExtension() {
        let url = URL(fileURLWithPath: "/usr/bin/ls")
        let result = PathSanitizer.sanitizeForLog(url)
        
        XCTAssertFalse(result.isEmpty, "Should return non-empty string")
        
        #if DEBUG
        XCTAssertEqual(result, "/usr/bin/ls", "DEBUG should return full path")
        #else
 // In RELEASE, should return just hash prefix (no extension)
        XCTAssertFalse(result.contains("."), "RELEASE should not have extension for extensionless file")
        XCTAssertEqual(result.count, 8, "RELEASE should return 8 hex characters")
        #endif
    }
    
 /// Test that sanitizeForLog produces consistent hash for same path
    func testSanitizeForLog_ConsistentHash() {
        let path = "/some/path/to/file.txt"
        let result1 = PathSanitizer.sanitizeForLog(path)
        let result2 = PathSanitizer.sanitizeForLog(path)
        
        XCTAssertEqual(result1, result2, "Same path should produce same result")
    }
    
 /// Test that sanitizeForLog produces different hash for different paths
    func testSanitizeForLog_DifferentHashForDifferentPaths() {
        let path1 = "/path/one/file.txt"
        let path2 = "/path/two/file.txt"
        
        let result1 = PathSanitizer.sanitizeForLog(path1)
        let result2 = PathSanitizer.sanitizeForLog(path2)
        
        #if DEBUG
 // In DEBUG, paths are different
        XCTAssertNotEqual(result1, result2, "Different paths should produce different results")
        #else
 // In RELEASE, hashes should be different (same extension but different hash)
        XCTAssertNotEqual(result1, result2, "Different paths should produce different hashes")
        #endif
    }
    
 // MARK: - sanitizeError Tests
    
 /// Test sanitizeError with URL
    func testSanitizeError_URL() {
        let url = URL(fileURLWithPath: "/Users/secret/private/document.pdf")
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "File not found"
        ])
        
        let result = PathSanitizer.sanitizeError(error, url: url)
        
 // Should contain sanitized filename
        XCTAssertTrue(result.contains("document.pdf"), "Should contain filename")
 // Should contain error description
        XCTAssertTrue(result.contains("File not found"), "Should contain error description")
 // Should NOT contain full path
        XCTAssertFalse(result.contains("/Users/secret"), "Should not contain directory path")
    }
    
 /// Test sanitizeError with path string
    func testSanitizeError_String() {
        let path = "/var/private/secrets/config.json"
        let error = NSError(domain: "TestDomain", code: 13, userInfo: [
            NSLocalizedDescriptionKey: "Permission denied"
        ])
        
        let result = PathSanitizer.sanitizeError(error, path: path)
        
        XCTAssertTrue(result.contains("config.json"), "Should contain filename")
        XCTAssertTrue(result.contains("Permission denied"), "Should contain error description")
        XCTAssertFalse(result.contains("/var/private"), "Should not contain directory path")
    }
    
 /// Test sanitizeError format
    func testSanitizeError_Format() {
        let url = URL(fileURLWithPath: "/path/to/file.txt")
        let error = NSError(domain: "Test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Error message"
        ])
        
        let result = PathSanitizer.sanitizeError(error, url: url)
        
 // Format should be "filename: error description"
        XCTAssertEqual(result, "file.txt: Error message", "Should follow 'filename: error' format")
    }
    
 // MARK: - Edge Cases
    
 /// Test with empty path
    func testSanitize_EmptyPath() {
        let path = ""
        let result = PathSanitizer.sanitize(path)
        
        XCTAssertEqual(result, "", "Empty path should return empty string")
    }
    
 /// Test with special characters in filename
    func testSanitize_SpecialCharacters() {
        let url = URL(fileURLWithPath: "/path/to/file[1](2)@#$.txt")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, "file[1](2)@#$.txt", "Should preserve special characters in filename")
    }
    
 /// Test with very long filename
    func testSanitize_LongFilename() {
        let longName = String(repeating: "a", count: 255) + ".txt"
        let url = URL(fileURLWithPath: "/path/to/\(longName)")
        let result = PathSanitizer.sanitize(url)
        
        XCTAssertEqual(result, longName, "Should handle long filenames")
    }
    
 /// Test sanitizeForLog with very long path
    func testSanitizeForLog_LongPath() {
        let longPath = "/" + String(repeating: "directory/", count: 50) + "file.txt"
        let result = PathSanitizer.sanitizeForLog(longPath)
        
        XCTAssertFalse(result.isEmpty, "Should handle long paths")
        
        #if DEBUG
        XCTAssertEqual(result, longPath, "DEBUG should return full long path")
        #else
 // In RELEASE, should still return compact format
        XCTAssertTrue(result.count < 20, "RELEASE should return compact format regardless of path length")
        #endif
    }
}
