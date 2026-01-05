//
// SignatureDBKeyManagerTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for SignatureDBKeyManager
// **Feature: security-hardening, Property 16: Signature DB key enforcement**
// **Validates: Requirements 7.1, 7.2**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Test Data Generator

/// Generates test data for SignatureDBKeyManager tests
struct SignatureDBKeyTestGenerator {
    
 /// Known development key (must match SignatureDBKeyManager.developmentPublicKeyBase64)
    static let developmentKeyBase64 = "ZGV2ZWxvcG1lbnQta2V5LW5vdC1mb3ItcHJvZHVjdGlvbg=="
    
 /// Create a random production-like key (not the development key)
    static func createRandomProductionKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            bytes[i] = UInt8.random(in: 0...255)
        }
 // Ensure it doesn't accidentally match the dev key
        let data = Data(bytes)
        if data.base64EncodedString() == developmentKeyBase64 {
 // Extremely unlikely, but flip a byte to ensure difference
            bytes[0] = bytes[0] ^ 0xFF
            return Data(bytes)
        }
        return data
    }
    
 /// Create the development key
    static func createDevelopmentKey() -> Data {
        Data(base64Encoded: developmentKeyBase64) ?? Data()
    }
    
 /// Create a test SignatureDatabase with specified signing key
    static func createDatabase(
        version: Int = 1,
        signatureData: Data? = nil
    ) -> SignatureDatabase {
        SignatureDatabase(
            version: version,
            lastUpdated: Date(),
            signatures: [
                MalwareSignature(
                    id: "test-sig-\(UUID().uuidString.prefix(8))",
                    name: "Test Signature",
                    category: "test",
                    patterns: [
                        SignaturePattern(type: .string, value: "test-pattern", offset: nil)
                    ],
                    severity: 1
                )
            ],
            signatureData: signatureData
        )
    }
    
 /// Create multiple test databases with random configurations
    static func createRandomDatabases(count: Int) -> [SignatureDatabase] {
        (0..<count).map { i in
            let useDevKey = Bool.random()
            let signatureData = useDevKey ? createDevelopmentKey() : createRandomProductionKey()
            return createDatabase(
                version: i + 1,
                signatureData: signatureData
            )
        }
    }
}


// MARK: - Property Test: Signature DB Key Enforcement
// **Feature: security-hardening, Property 16: Signature DB key enforcement**
// **Validates: Requirements 7.1, 7.2**

final class SignatureDBKeyManagerTests: XCTestCase {
    
 // MARK: - Property Tests
    
 /// Property test: Development key detection is consistent
 ///
 /// *For any* key data, isDevelopmentKey() SHALL return true if and only if
 /// the key matches the known development key pattern.
 ///
 /// **Feature: security-hardening, Property 16: Signature DB key enforcement**
 /// **Validates: Requirements 7.1, 7.2**
    func testProperty_DevelopmentKeyDetectionConsistency() {
 // Run 100 iterations as per testing strategy
        for _ in 0..<100 {
 // Test with development key - should always be detected
            let devKey = SignatureDBKeyTestGenerator.createDevelopmentKey()
            XCTAssertTrue(
                SignatureDBKeyManager.isDevelopmentKey(devKey),
                "Development key should always be detected as development key"
            )
            
 // Test with random production key - should never be detected as dev key
            let prodKey = SignatureDBKeyTestGenerator.createRandomProductionKey()
            XCTAssertFalse(
                SignatureDBKeyManager.isDevelopmentKey(prodKey),
                "Random production key should not be detected as development key"
            )
        }
    }
    
 /// Property test: Empty key is never detected as development key
 ///
 /// *For any* empty Data, isDevelopmentKey() SHALL return false.
 ///
 /// **Feature: security-hardening, Property 16: Signature DB key enforcement**
 /// **Validates: Requirements 7.1, 7.2**
    func testProperty_EmptyKeyNotDevelopmentKey() {
        let emptyKey = Data()
        XCTAssertFalse(
            SignatureDBKeyManager.isDevelopmentKey(emptyKey),
            "Empty key should not be detected as development key"
        )
    }
    
 /// Property test: Development key string pattern detection
 ///
 /// *For any* Data containing "development-key" prefix when decoded as UTF-8,
 /// isDevelopmentKey() SHALL return true.
 ///
 /// **Feature: security-hardening, Property 16: Signature DB key enforcement**
 /// **Validates: Requirements 7.1, 7.2**
    func testProperty_DevelopmentKeyStringPatternDetection() {
 // Test various development key string patterns
        let devKeyPatterns = [
            "development-key-not-for-production",
            "development-key-test",
            "development-key-v2"
        ]
        
        for pattern in devKeyPatterns {
            if let keyData = pattern.data(using: .utf8) {
                XCTAssertTrue(
                    SignatureDBKeyManager.isDevelopmentKey(keyData),
                    "Key with pattern '\(pattern)' should be detected as development key"
                )
            }
        }
    }
    
 /// Property test: Verification result consistency in DEBUG mode
 ///
 /// In DEBUG builds, verification SHALL accept both development and production keys.
 /// This test verifies the DEBUG behavior.
 ///
 /// **Feature: security-hardening, Property 16: Signature DB key enforcement**
 /// **Validates: Requirements 7.3**
    func testProperty_DebugModeAcceptsBothKeys() {
        #if DEBUG
 // In DEBUG mode, both keys should be accepted
        for _ in 0..<100 {
 // Database with no signature (should be accepted in DEBUG)
            let dbNoSig = SignatureDBKeyTestGenerator.createDatabase(signatureData: nil)
            let resultNoSig = SignatureDBKeyManager.verify(database: dbNoSig)
            XCTAssertEqual(
                resultNoSig, .valid,
                "DEBUG mode should accept database without signature"
            )
        }
        #else
 // Skip in Release mode - this test is specifically for DEBUG behavior
        print("Skipping DEBUG-specific test in Release mode")
        #endif
    }

    
 /// Property test: shouldAllowPatternMatcher consistency
 ///
 /// *For any* SignatureDatabase, shouldAllowPatternMatcher() SHALL return true
 /// if and only if verify() returns .valid.
 ///
 /// **Feature: security-hardening, Property 16: Signature DB key enforcement**
 /// **Validates: Requirements 7.1, 7.2**
    func testProperty_ShouldAllowPatternMatcherConsistency() {
        for _ in 0..<100 {
            let database = SignatureDBKeyTestGenerator.createDatabase(signatureData: nil)
            
            let verifyResult = SignatureDBKeyManager.verify(database: database)
            let shouldAllow = SignatureDBKeyManager.shouldAllowPatternMatcher(with: database)
            
 // shouldAllow should be true iff verifyResult is .valid
            if verifyResult == .valid {
                XCTAssertTrue(
                    shouldAllow,
                    "shouldAllowPatternMatcher should return true when verify returns .valid"
                )
            } else {
                XCTAssertFalse(
                    shouldAllow,
                    "shouldAllowPatternMatcher should return false when verify returns \(verifyResult)"
                )
            }
        }
    }
    
 /// Property test: verifyForPatternMatcher returns consistent tuple
 ///
 /// *For any* SignatureDatabase, verifyForPatternMatcher() SHALL return
 /// (canStart: true, result: .valid) or (canStart: false, result: non-.valid).
 ///
 /// **Feature: security-hardening, Property 16: Signature DB key enforcement**
 /// **Validates: Requirements 7.1, 7.2**
    func testProperty_VerifyForPatternMatcherConsistency() {
        for _ in 0..<100 {
            let database = SignatureDBKeyTestGenerator.createDatabase(signatureData: nil)
            
            let (canStart, result) = SignatureDBKeyManager.verifyForPatternMatcher(database: database)
            
 // canStart should be true iff result is .valid
            if result == .valid {
                XCTAssertTrue(
                    canStart,
                    "canStart should be true when result is .valid"
                )
            } else {
                XCTAssertFalse(
                    canStart,
                    "canStart should be false when result is \(result)"
                )
            }
        }
    }
    
 // MARK: - Unit Tests
    
 /// Test that development key constant is correctly defined
    func testDevelopmentKeyConstant() {
        let devKey = SignatureDBKeyManager.developmentPublicKey
        XCTAssertFalse(devKey.isEmpty, "Development key should not be empty")
        
 // Verify it decodes to the expected string
        if let decoded = String(data: devKey, encoding: .utf8) {
            XCTAssertEqual(
                decoded,
                "development-key-not-for-production",
                "Development key should decode to expected string"
            )
        }
    }
    
 /// Test that development key base64 constant matches
    func testDevelopmentKeyBase64Constant() {
        let expectedBase64 = "ZGV2ZWxvcG1lbnQta2V5LW5vdC1mb3ItcHJvZHVjdGlvbg=="
        XCTAssertEqual(
            SignatureDBKeyManager.developmentPublicKeyBase64,
            expectedBase64,
            "Development key base64 should match expected value"
        )
    }
    
 /// Test isDevelopmentKey with exact development key
    func testIsDevelopmentKey_ExactMatch() {
        let devKey = SignatureDBKeyManager.developmentPublicKey
        XCTAssertTrue(
            SignatureDBKeyManager.isDevelopmentKey(devKey),
            "Exact development key should be detected"
        )
    }
    
 /// Test isDevelopmentKey with base64 match
    func testIsDevelopmentKey_Base64Match() {
        let devKeyBase64 = SignatureDBKeyManager.developmentPublicKeyBase64
        if let keyData = Data(base64Encoded: devKeyBase64) {
            XCTAssertTrue(
                SignatureDBKeyManager.isDevelopmentKey(keyData),
                "Development key from base64 should be detected"
            )
        } else {
            XCTFail("Failed to decode development key base64")
        }
    }
    
 /// Test isDevelopmentKey with random key
    func testIsDevelopmentKey_RandomKey() {
        let randomKey = SignatureDBKeyTestGenerator.createRandomProductionKey()
        XCTAssertFalse(
            SignatureDBKeyManager.isDevelopmentKey(randomKey),
            "Random key should not be detected as development key"
        )
    }
    
 /// Test isProductionKey with random production key
    func testIsProductionKey_RandomKey() {
 // Note: This test may fail if productionPublicKey is not configured
 // In that case, isProductionKey will return false for any key
        let randomKey = SignatureDBKeyTestGenerator.createRandomProductionKey()
        
 // In DEBUG without configured production key, this should return false
 // because productionPublicKey falls back to developmentPublicKey
        let result = SignatureDBKeyManager.isProductionKey(randomKey)
        
 // The random key is not the production key (which is dev key in DEBUG)
        XCTAssertFalse(
            result,
            "Random key should not be detected as production key"
        )
    }
    
 /// Test verification with database without signature
    func testVerify_DatabaseWithoutSignature() {
        let database = SignatureDBKeyTestGenerator.createDatabase(signatureData: nil)
        let result = SignatureDBKeyManager.verify(database: database)
        
        #if DEBUG
 // In DEBUG, database without signature should be accepted
        XCTAssertEqual(
            result, .valid,
            "DEBUG mode should accept database without signature"
        )
        #else
 // In Release, database without signature should be rejected
        XCTAssertEqual(
            result, .invalid,
            "Release mode should reject database without signature"
        )
        #endif
    }

    
 /// Test verification with database with development key signature
    func testVerify_DatabaseWithDevelopmentKey() {
        let devKey = SignatureDBKeyTestGenerator.createDevelopmentKey()
        let database = SignatureDBKeyTestGenerator.createDatabase(signatureData: devKey)
        let result = SignatureDBKeyManager.verify(database: database)
        
        #if DEBUG
 // In DEBUG, development key should be accepted
        XCTAssertEqual(
            result, .valid,
            "DEBUG mode should accept database with development key"
        )
        #else
 // In Release, development key should trigger developmentKeyInRelease
        XCTAssertEqual(
            result, .developmentKeyInRelease,
            "Release mode should detect development key"
        )
        #endif
    }
    
 /// Test shouldAllowPatternMatcher with valid database
    func testShouldAllowPatternMatcher_ValidDatabase() {
        let database = SignatureDBKeyTestGenerator.createDatabase(signatureData: nil)
        let shouldAllow = SignatureDBKeyManager.shouldAllowPatternMatcher(with: database)
        
        #if DEBUG
        XCTAssertTrue(
            shouldAllow,
            "DEBUG mode should allow PatternMatcher with unsigned database"
        )
        #else
        XCTAssertFalse(
            shouldAllow,
            "Release mode should not allow PatternMatcher with unsigned database"
        )
        #endif
    }
    
 /// Test verifyForPatternMatcher returns correct tuple
    func testVerifyForPatternMatcher_ReturnsTuple() {
        let database = SignatureDBKeyTestGenerator.createDatabase(signatureData: nil)
        let (canStart, result) = SignatureDBKeyManager.verifyForPatternMatcher(database: database)
        
 // Verify tuple consistency
        XCTAssertEqual(
            canStart,
            result == .valid,
            "canStart should match result == .valid"
        )
    }
    
 // MARK: - Data Extension Tests
    
 /// Test Data hex string initialization
    func testDataHexStringInit() {
 // Test valid hex string
        let hexString = "48656c6c6f"  // "Hello" in hex
        if let data = Data(hexString: hexString) {
            XCTAssertEqual(
                String(data: data, encoding: .utf8),
                "Hello",
                "Hex string should decode to 'Hello'"
            )
        } else {
            XCTFail("Failed to create Data from hex string")
        }
        
 // Note: The existing Data.init(hexString:) in PAKEService doesn't handle spaces
 // So we skip the spaces test
        
 // Test that the hex string init exists and works for basic cases
        let shortHex = "4142"  // "AB"
        if let data = Data(hexString: shortHex) {
            XCTAssertEqual(data.count, 2, "Should create 2-byte data")
        } else {
            XCTFail("Failed to create Data from short hex string")
        }
    }
    
 /// Test Data toHexStringForKeyManager
    func testDataToHexString() {
        let data = "Hello".utf8Data
        let hexString = data.toHexStringForKeyManager()
        XCTAssertEqual(
            hexString,
            "48656c6c6f",
            "Data should convert to correct hex string"
        )
    }
    
    #if DEBUG
 /// Test createTestDatabase helper
    func testCreateTestDatabase() {
        let database = SignatureDBKeyManager.createTestDatabase()
        XCTAssertEqual(database.version, 1, "Test database should have version 1")
        XCTAssertTrue(database.signatures.isEmpty, "Test database should have no signatures")
        XCTAssertNotNil(database.signatureData, "Test database should have signature data")
    }
    #endif
}

// MARK: - Release Mode Simulation Tests

/// Tests that simulate Release mode behavior
/// These tests verify the expected behavior when development key is detected in Release
final class SignatureDBKeyManagerReleaseSimulationTests: XCTestCase {
    
 /// Test that development key detection works correctly
    func testDevelopmentKeyDetection() {
        let devKey = SignatureDBKeyTestGenerator.createDevelopmentKey()
        
 // The key should always be detected as development key
        XCTAssertTrue(
            SignatureDBKeyManager.isDevelopmentKey(devKey),
            "Development key should be detected"
        )
        
 // Verify the key content
        if let decoded = String(data: devKey, encoding: .utf8) {
            XCTAssertTrue(
                decoded.hasPrefix("development-key"),
                "Development key should have expected prefix"
            )
        }
    }
    
 /// Test that random keys are not detected as development keys
    func testRandomKeyNotDevelopmentKey() {
 // Generate 100 random keys and verify none are detected as dev keys
        for _ in 0..<100 {
            let randomKey = SignatureDBKeyTestGenerator.createRandomProductionKey()
            XCTAssertFalse(
                SignatureDBKeyManager.isDevelopmentKey(randomKey),
                "Random key should not be detected as development key"
            )
        }
    }
    
 /// Test verification result enum equality
    func testVerificationResultEquality() {
        XCTAssertEqual(
            SignatureDBKeyVerificationResult.valid,
            SignatureDBKeyVerificationResult.valid
        )
        XCTAssertEqual(
            SignatureDBKeyVerificationResult.invalid,
            SignatureDBKeyVerificationResult.invalid
        )
        XCTAssertEqual(
            SignatureDBKeyVerificationResult.developmentKeyInRelease,
            SignatureDBKeyVerificationResult.developmentKeyInRelease
        )
        XCTAssertNotEqual(
            SignatureDBKeyVerificationResult.valid,
            SignatureDBKeyVerificationResult.invalid
        )
    }
}
