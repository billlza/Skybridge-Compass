// MARK: - AuthTokenValidatorTests.swift
// SkyBridge Compass - Security Hardening Tests
// Copyright © 2024 SkyBridge. All rights reserved.

import XCTest
@testable import SkyBridgeCore

/// Unit tests for AuthTokenValidator.
/// Tests format validation, character set validation, and Release/Debug handling.
final class AuthTokenValidatorTests: XCTestCase {
    
    var validator: AuthTokenValidator!
    
    override func setUp() async throws {
        validator = AuthTokenValidator()
    }
    
    override func tearDown() async throws {
        validator = nil
    }
    
 // MARK: - Empty Token Tests
    
    func testValidateEmptyToken() {
        let result = validator.validate("")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .empty)
    }
    
 // MARK: - Whitespace Tests
    
    func testValidateTokenWithLeadingWhitespace() {
        let result = validator.validate(" abcdefghijklmnopqrstuvwxyz123456")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .containsWhitespace)
    }
    
    func testValidateTokenWithTrailingWhitespace() {
        let result = validator.validate("abcdefghijklmnopqrstuvwxyz123456 ")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .containsWhitespace)
    }
    
    func testValidateTokenWithMiddleWhitespace() {
        let result = validator.validate("abcdefghijklmnop qrstuvwxyz12345")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .containsWhitespace)
    }
    
    func testValidateTokenWithTab() {
        let result = validator.validate("abcdefghijklmnop\tqrstuvwxyz12345")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .containsWhitespace)
    }
    
    func testValidateTokenWithNewline() {
        let result = validator.validate("abcdefghijklmnop\nqrstuvwxyz12345")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .containsWhitespace)
    }
    
 // MARK: - Length Tests
    
    func testValidateTokenTooShort() {
        let result = validator.validate("abc123") // 6 chars, need 32
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .tooShort)
    }
    
    func testValidateTokenExactlyMinLength() {
 // Exactly 32 characters
        let token = "abcdefghijklmnopqrstuvwxyz123456"
        XCTAssertEqual(token.count, 32)
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
    func testValidateTokenOneCharShort() {
 // 31 characters
        let token = "abcdefghijklmnopqrstuvwxyz12345"
        XCTAssertEqual(token.count, 31)
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .tooShort)
    }
    
 // MARK: - Base64url Format Tests
    
    func testValidateValidBase64urlToken() {
        let token = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
    func testValidateBase64urlWithUnderscore() {
        let token = "abcdefghijklmnopqrstuvwxyz_12345"
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
    func testValidateBase64urlWithHyphen() {
        let token = "abcdefghijklmnopqrstuvwxyz-12345"
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
 // MARK: - UUID Format Tests
    
    func testValidateValidUUID() {
        let token = "550e8400-e29b-41d4-a716-446655440000"
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .uuid)
    }
    
    func testValidateUUIDUppercase() {
        let token = "550E8400-E29B-41D4-A716-446655440000"
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .uuid)
    }
    
    func testValidateUUIDMixedCase() {
        let token = "550e8400-E29B-41d4-A716-446655440000"
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .uuid)
    }
    
    func testValidateUUIDFromFoundation() {
        let uuid = UUID()
        let result = validator.validate(uuid.uuidString)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .uuid)
    }
    
 // MARK: - Invalid Character Tests
    
    func testValidateTokenWithDot() {
 // JWT-like token with dots - should be rejected
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .invalidCharacters)
    }
    
    func testValidateTokenWithPlus() {
 // Standard base64 uses + but base64url uses - instead
        let token = "abcdefghijklmnopqrstuvwxyz+12345"
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .invalidCharacters)
    }
    
    func testValidateTokenWithSlash() {
 // Standard base64 uses / but base64url uses _ instead
        let token = "abcdefghijklmnopqrstuvwxyz/12345"
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .invalidCharacters)
    }
    
    func testValidateTokenWithEquals() {
 // Base64 padding character - not allowed in base64url
        let token = "abcdefghijklmnopqrstuvwxyz12345="
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .invalidCharacters)
    }
    
    func testValidateTokenWithSpecialChars() {
        let token = "abcdefghijklmnopqrstuvwxyz!@#$%^"
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .invalidCharacters)
    }
    
 // MARK: - Invalid UUID Format Tests
    
    func testValidateUUIDWrongSegmentLengths() {
 // Wrong segment lengths (should be 8-4-4-4-12)
        let token = "550e8400-e29b-41d4-a716-4466554400" // Last segment too short
        let result = validator.validate(token)
 // This will be detected as base64url since it has valid chars but wrong UUID format
        XCTAssertTrue(result.isValid) // Valid as base64url
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
    func testValidateUUIDMissingHyphens() {
 // UUID without hyphens - valid as base64url
        let token = "550e8400e29b41d4a716446655440000"
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
 // MARK: - Format Detection Tests
    
    func testDetectFormatBase64url() {
        let token = "abcdefghijklmnopqrstuvwxyz123456"
        let format = validator.detectFormat(token)
        XCTAssertEqual(format, .base64url)
    }
    
    func testDetectFormatUUID() {
        let token = "550e8400-e29b-41d4-a716-446655440000"
        let format = validator.detectFormat(token)
        XCTAssertEqual(format, .uuid)
    }
    
    func testDetectFormatNilForInvalidChars() {
        let token = "invalid.token.with.dots.here!!!"
        let format = validator.detectFormat(token)
        XCTAssertNil(format)
    }
    
 // MARK: - Debug Support Tests
    
    func testShouldAcceptEmptyTokenInDebug() {
 // This test behavior depends on build configuration
        let shouldAccept = validator.shouldAcceptEmptyToken("")
        #if DEBUG
        XCTAssertTrue(shouldAccept)
        #else
        XCTAssertFalse(shouldAccept)
        #endif
    }
    
    func testShouldNotAcceptNonEmptyToken() {
        let shouldAccept = validator.shouldAcceptEmptyToken("some-token")
        XCTAssertFalse(shouldAccept)
    }
    
    func testValidateWithDebugSupportEmptyToken() {
        let result = validator.validateWithDebugSupport("")
        #if DEBUG
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.detectedFormat) // Special debug case
        #else
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .empty)
        #endif
    }
    
    func testValidateWithDebugSupportValidToken() {
        let token = "abcdefghijklmnopqrstuvwxyz123456"
        let result = validator.validateWithDebugSupport(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
 // MARK: - Edge Cases
    
    func testValidateLongToken() {
 // Very long token should still be valid if chars are valid
        let token = String(repeating: "a", count: 1000)
        let result = validator.validate(token)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
    func testValidateAllBase64urlChars() {
 // Test all valid base64url characters
        let allChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        let result = validator.validate(allChars)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.detectedFormat, .base64url)
    }
    
    func testValidateUnicodeCharacters() {
 // Unicode characters should be rejected
        let token = "abcdefghijklmnopqrstuvwxyz12345é"
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .invalidCharacters)
    }
    
    func testValidateEmojiCharacters() {
 // Emoji should be rejected - use a longer base to ensure >= 32 chars after emoji
        let token = "abcdefghijklmnopqrstuvwxyz123456😀"
        let result = validator.validate(token)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .invalidCharacters)
    }
}


// MARK: - Property Test Data Generators

/// Test data generator for auth tokens
enum AuthTokenGenerator {
    
 /// Base64url character set
    static let base64urlChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    
 /// Invalid characters (not in base64url or UUID charset)
    static let invalidChars = Array(".+/=!@#$%^&*()[]{}|\\:;\"'<>,?`~")
    
 /// Whitespace characters
    static let whitespaceChars = Array(" \t\n\r")
    
 /// Generate a valid base64url token of specified length
    static func generateValidBase64url(length: Int = 64) -> String {
        String((0..<length).map { _ in base64urlChars.randomElement()! })
    }
    
 /// Generate a valid UUID token
    static func generateValidUUID() -> String {
        UUID().uuidString
    }
    
 /// Generate a token that is too short (< 32 chars)
    static func generateTooShortToken() -> String {
        let length = Int.random(in: 1...31)
        return generateValidBase64url(length: length)
    }
    
 /// Generate a token with whitespace at random position
    static func generateTokenWithWhitespace() -> String {
        var token = Array(generateValidBase64url(length: 32))
        let position = Int.random(in: 0..<token.count)
        let whitespace = whitespaceChars.randomElement()!
        token[position] = whitespace
        return String(token)
    }
    
 /// Generate a token with invalid characters
    static func generateTokenWithInvalidChars() -> String {
        var token = Array(generateValidBase64url(length: 32))
        let position = Int.random(in: 0..<token.count)
        let invalidChar = invalidChars.randomElement()!
        token[position] = invalidChar
        return String(token)
    }
    
 /// Generate a JWT-like token (with dots)
    static func generateJWTLikeToken() -> String {
        let header = generateValidBase64url(length: 20)
        let payload = generateValidBase64url(length: 30)
        let signature = generateValidBase64url(length: 20)
        return "\(header).\(payload).\(signature)"
    }
    
 /// Token type for property testing
    enum TokenType: CaseIterable {
        case validBase64url
        case validUUID
        case empty
        case tooShort
        case withWhitespace
        case withInvalidChars
        case jwtLike
        
        var shouldBeValid: Bool {
            switch self {
            case .validBase64url, .validUUID:
                return true
            case .empty, .tooShort, .withWhitespace, .withInvalidChars, .jwtLike:
                return false
            }
        }
        
        var expectedRejectionReason: AuthTokenValidationResult.RejectionReason? {
            switch self {
            case .validBase64url, .validUUID:
                return nil
            case .empty:
                return .empty
            case .tooShort:
                return .tooShort
            case .withWhitespace:
                return .containsWhitespace
            case .withInvalidChars, .jwtLike:
                return .invalidCharacters
            }
        }
        
        func generateToken() -> String {
            switch self {
            case .validBase64url:
                return AuthTokenGenerator.generateValidBase64url()
            case .validUUID:
                return AuthTokenGenerator.generateValidUUID()
            case .empty:
                return ""
            case .tooShort:
                return AuthTokenGenerator.generateTooShortToken()
            case .withWhitespace:
                return AuthTokenGenerator.generateTokenWithWhitespace()
            case .withInvalidChars:
                return AuthTokenGenerator.generateTokenWithInvalidChars()
            case .jwtLike:
                return AuthTokenGenerator.generateJWTLikeToken()
            }
        }
    }
}

// MARK: - Property 17: AuthToken Format Validation
// **Feature: security-hardening, Property 17: AuthToken format validation**
// **Validates: Requirements 9.5, 9.6**

/// Property-based tests for auth token format validation
final class AuthTokenFormatValidationTests: XCTestCase {
    
    var validator: AuthTokenValidator!
    
    override func setUp() async throws {
        try await super.setUp()
        validator = AuthTokenValidator()
    }
    
    override func tearDown() async throws {
        validator = nil
        try await super.tearDown()
    }
    
 // MARK: - Property 17: AuthToken Format Validation
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: For any authToken, validation SHALL check: non-empty, min 32 chars,
 /// valid charset (base64url/UUID), no whitespace.
 ///
 /// This test verifies:
 /// 1. Empty tokens are rejected with .empty reason
 /// 2. Short tokens (< 32 chars) are rejected with .tooShort reason
 /// 3. Tokens with whitespace are rejected with .containsWhitespace reason
 /// 4. Tokens with invalid characters are rejected with .invalidCharacters reason
 /// 5. Valid base64url tokens are accepted
 /// 6. Valid UUID tokens are accepted
    func testProperty17_FormatValidation() {
 // Run 100 iterations with different random tokens
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Test each token type
            for tokenType in AuthTokenGenerator.TokenType.allCases {
                let token = tokenType.generateToken()
                let result = validator.validate(token)
                
 // Property: Validity must match expected
                XCTAssertEqual(
                    result.isValid,
                    tokenType.shouldBeValid,
                    "Iteration \(iteration): Token type \(tokenType) with value '\(token.prefix(50))...' should be \(tokenType.shouldBeValid ? "valid" : "invalid")"
                )
                
 // Property: Rejection reason must match expected (for invalid tokens)
                if !tokenType.shouldBeValid {
                    XCTAssertEqual(
                        result.rejectionReason,
                        tokenType.expectedRejectionReason,
                        "Iteration \(iteration): Token type \(tokenType) should be rejected with reason \(tokenType.expectedRejectionReason?.rawValue ?? "nil"), got \(result.rejectionReason?.rawValue ?? "nil")"
                    )
                }
            }
        }
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: For any valid base64url token of length >= 32, validation SHALL accept it.
    func testProperty17_ValidBase64urlTokensAccepted() {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random length between 32 and 256
            let length = Int.random(in: 32...256)
            let token = AuthTokenGenerator.generateValidBase64url(length: length)
            let result = validator.validate(token)
            
            XCTAssertTrue(
                result.isValid,
                "Iteration \(iteration): Valid base64url token of length \(length) should be accepted"
            )
            XCTAssertEqual(
                result.detectedFormat,
                .base64url,
                "Iteration \(iteration): Token should be detected as base64url format"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: For any valid UUID token, validation SHALL accept it.
    func testProperty17_ValidUUIDTokensAccepted() {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let token = AuthTokenGenerator.generateValidUUID()
            let result = validator.validate(token)
            
            XCTAssertTrue(
                result.isValid,
                "Iteration \(iteration): Valid UUID token '\(token)' should be accepted"
            )
            XCTAssertEqual(
                result.detectedFormat,
                .uuid,
                "Iteration \(iteration): Token should be detected as UUID format"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: For any token shorter than 32 characters, validation SHALL reject it.
    func testProperty17_ShortTokensRejected() {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let length = Int.random(in: 1...31)
            let token = AuthTokenGenerator.generateValidBase64url(length: length)
            let result = validator.validate(token)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Token of length \(length) should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .tooShort,
                "Iteration \(iteration): Short token should be rejected with .tooShort reason"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: For any token containing whitespace, validation SHALL reject it.
    func testProperty17_WhitespaceTokensRejected() {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let token = AuthTokenGenerator.generateTokenWithWhitespace()
            let result = validator.validate(token)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Token with whitespace should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .containsWhitespace,
                "Iteration \(iteration): Token with whitespace should be rejected with .containsWhitespace reason"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: For any token containing invalid characters (including `.`),
 /// validation SHALL reject it.
    func testProperty17_InvalidCharactersRejected() {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let token = AuthTokenGenerator.generateTokenWithInvalidChars()
            let result = validator.validate(token)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Token with invalid characters should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .invalidCharacters,
                "Iteration \(iteration): Token with invalid chars should be rejected with .invalidCharacters reason"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: JWT-like tokens (containing `.` separator) SHALL be rejected.
 /// This verifies that JWT format is NOT supported.
    func testProperty17_JWTTokensRejected() {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let token = AuthTokenGenerator.generateJWTLikeToken()
            let result = validator.validate(token)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): JWT-like token should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .invalidCharacters,
                "Iteration \(iteration): JWT token should be rejected with .invalidCharacters reason (due to '.')"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: Validation order is deterministic - whitespace check happens before length check.
    func testProperty17_ValidationOrderWhitespaceBeforeLength() {
 // Token with whitespace that is also too short
        let shortTokenWithWhitespace = "abc def" // 7 chars with space
        let result = validator.validate(shortTokenWithWhitespace)
        
        XCTAssertFalse(result.isValid)
 // Whitespace should be detected before length check
        XCTAssertEqual(result.rejectionReason, .containsWhitespace)
    }
    
 /// **Feature: security-hardening, Property 17: AuthToken format validation**
 /// **Validates: Requirements 9.5, 9.6**
 ///
 /// Property: Empty check happens before whitespace check.
    func testProperty17_ValidationOrderEmptyFirst() {
        let result = validator.validate("")
        
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .empty)
    }
}

// MARK: - Property 18: AuthToken Release Enforcement
// **Feature: security-hardening, Property 18: AuthToken Release enforcement**
// **Validates: Requirements 9.1, 9.2**

/// Property-based tests for auth token Release/Debug enforcement
final class AuthTokenReleaseEnforcementTests: XCTestCase {
    
    var validator: AuthTokenValidator!
    
    override func setUp() async throws {
        try await super.setUp()
        validator = AuthTokenValidator()
    }
    
    override func tearDown() async throws {
        validator = nil
        try await super.tearDown()
    }
    
 // MARK: - Property 18: AuthToken Release Enforcement
    
 /// **Feature: security-hardening, Property 18: AuthToken Release enforcement**
 /// **Validates: Requirements 9.1, 9.2**
 ///
 /// Property: For any Release build receiving empty authToken, the handler SHALL reject the message.
 ///
 /// Note: This test verifies the behavior of `validate()` which always rejects empty tokens.
 /// The `validateWithDebugSupport()` method provides Debug-only empty token acceptance.
    func testProperty18_EmptyTokenAlwaysRejectedByValidate() {
        let iterations = 100
        
        for _ in 0..<iterations {
            let result = validator.validate("")
            
 // validate() always rejects empty tokens (Release behavior)
            XCTAssertFalse(result.isValid)
            XCTAssertEqual(result.rejectionReason, .empty)
        }
    }
    
 /// **Feature: security-hardening, Property 18: AuthToken Release enforcement**
 /// **Validates: Requirements 9.1, 9.2**
 ///
 /// Property: The allowEmptyInDebug flag correctly reflects build configuration.
    func testProperty18_AllowEmptyInDebugFlag() {
        #if DEBUG
        XCTAssertTrue(AuthTokenValidator.allowEmptyInDebug)
        #else
        XCTAssertFalse(AuthTokenValidator.allowEmptyInDebug)
        #endif
    }
    
 /// **Feature: security-hardening, Property 18: AuthToken Release enforcement**
 /// **Validates: Requirements 9.1, 9.2**
 ///
 /// Property: validateWithDebugSupport() accepts empty tokens only in Debug builds.
    func testProperty18_ValidateWithDebugSupportEmptyToken() {
        let result = validator.validateWithDebugSupport("")
        
        #if DEBUG
 // Debug: empty tokens accepted
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.rejectionReason)
        #else
 // Release: empty tokens rejected
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .empty)
        #endif
    }
    
 /// **Feature: security-hardening, Property 18: AuthToken Release enforcement**
 /// **Validates: Requirements 9.1, 9.2**
 ///
 /// Property: For any non-empty valid token, both validate() and validateWithDebugSupport()
 /// return the same result.
    func testProperty18_NonEmptyTokensSameBehavior() {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let token = AuthTokenGenerator.generateValidBase64url()
            
            let validateResult = validator.validate(token)
            let debugSupportResult = validator.validateWithDebugSupport(token)
            
            XCTAssertEqual(
                validateResult.isValid,
                debugSupportResult.isValid,
                "Iteration \(iteration): Both methods should return same validity for non-empty token"
            )
            XCTAssertEqual(
                validateResult.detectedFormat,
                debugSupportResult.detectedFormat,
                "Iteration \(iteration): Both methods should detect same format for non-empty token"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 18: AuthToken Release enforcement**
 /// **Validates: Requirements 9.1, 9.2**
 ///
 /// Property: shouldAcceptEmptyToken() returns true only for empty string in Debug builds.
    func testProperty18_ShouldAcceptEmptyTokenBehavior() {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Test with empty string
            let emptyResult = validator.shouldAcceptEmptyToken("")
            #if DEBUG
            XCTAssertTrue(emptyResult, "Iteration \(iteration): Empty token should be accepted in Debug")
            #else
            XCTAssertFalse(emptyResult, "Iteration \(iteration): Empty token should be rejected in Release")
            #endif
            
 // Test with non-empty string
            let nonEmptyToken = AuthTokenGenerator.generateValidBase64url()
            let nonEmptyResult = validator.shouldAcceptEmptyToken(nonEmptyToken)
            XCTAssertFalse(
                nonEmptyResult,
                "Iteration \(iteration): Non-empty token should never trigger empty acceptance"
            )
        }
    }
}
