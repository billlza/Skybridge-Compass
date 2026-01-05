// MARK: - AuthTokenValidator.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

// MARK: - TokenFormat

/// Token format types supported by SkyBridge.
///
/// **Design Decision:** SkyBridge currently uses base64url or UUID format tokens.
/// **JWT is NOT supported** - JWT contains `.` separators which are rejected.
/// If JWT support is needed in the future, this validator must be updated.
public enum TokenFormat: String, Sendable, CaseIterable {
 /// Base64url format: [A-Za-z0-9_-]+
    case base64url
    
 /// UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (8-4-4-4-12)
    case uuid
    
 // Note: JWT format is intentionally NOT supported.
 // JWT contains `.` separators (header.payload.signature) which
 // are rejected by the current character set validation.
 // If JWT support is required, add: case jwt
}

// MARK: - AuthTokenValidationResult

/// Result of authentication token validation.
///
/// Contains validity status, detected format, and rejection reason if invalid.
/// **Validates: Requirements 9.5, 9.6**
public struct AuthTokenValidationResult: Sendable, Equatable {
 /// Whether the token is valid according to security rules
    public let isValid: Bool
    
 /// Detected token format (if valid or partially valid)
    public let detectedFormat: TokenFormat?
    
 /// Reason for rejection (if invalid)
    public let rejectionReason: RejectionReason?
    
 /// Rejection reasons for auth tokens
    public enum RejectionReason: String, Sendable, CaseIterable {
 /// Token is empty string
        case empty = "token_empty"
        
 /// Token is shorter than minimum required length (32 chars)
        case tooShort = "token_too_short"
        
 /// Token contains invalid characters (not base64url or UUID charset)
        case invalidCharacters = "invalid_characters"
        
 /// Token contains whitespace characters
        case containsWhitespace = "contains_whitespace"
        
 /// Token format is invalid (doesn't match base64url or UUID pattern)
        case invalidFormat = "invalid_format"
    }
    
 // MARK: - Factory Methods
    
 /// Create a valid result with detected format
    public static func valid(format: TokenFormat) -> AuthTokenValidationResult {
        AuthTokenValidationResult(isValid: true, detectedFormat: format, rejectionReason: nil)
    }
    
 /// Create an invalid result with rejection reason
    public static func invalid(reason: RejectionReason) -> AuthTokenValidationResult {
        AuthTokenValidationResult(isValid: false, detectedFormat: nil, rejectionReason: reason)
    }
    
 /// Create an invalid result with detected format (partial match)
    public static func invalid(reason: RejectionReason, detectedFormat: TokenFormat?) -> AuthTokenValidationResult {
        AuthTokenValidationResult(isValid: false, detectedFormat: detectedFormat, rejectionReason: reason)
    }
}

// MARK: - AuthTokenValidator

/// Authentication token validator.
///
/// Validates auth tokens against security rules to prevent unauthenticated access.
/// Implements format validation per Requirements 9.5, 9.6.
///
/// **Validation Rules:**
/// - Non-empty (Release builds reject empty tokens)
/// - Minimum 32 characters
/// - No whitespace characters
/// - Valid character set:
/// - base64url: [A-Za-z0-9_-]
/// - UUID: [A-Fa-f0-9-] with 8-4-4-4-12 format
///
/// **Important:** JWT format is NOT supported (contains `.` separator).
public struct AuthTokenValidator: Sendable {
    
 // MARK: - Constants
    
 /// Minimum token length (32 characters)
    public static let minimumTokenLength: Int = 32
    
 /// UUID pattern: 8-4-4-4-12 hex digits with hyphens
    private static let uuidPattern = "^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$"
    
 /// Base64url character set (no padding)
    private static let base64urlCharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    
 /// UUID character set (hex + hyphen)
    private static let uuidCharacterSet = CharacterSet(charactersIn: "ABCDEFabcdef0123456789-")
    
 // MARK: - Initialization
    
    public init() {}
    
 // MARK: - Public API
    
 /// Validate an authentication token.
 ///
 /// **Validation order:**
 /// 1. Check for empty token
 /// 2. Check for whitespace
 /// 3. Check minimum length
 /// 4. Check character set validity
 /// 5. Detect and validate format
 ///
 /// - Parameter token: The authentication token to validate
 /// - Returns: Validation result with validity, format, and rejection reason
 ///
 /// **Validates: Requirements 9.5, 9.6**
    public func validate(_ token: String) -> AuthTokenValidationResult {
 // 1. Check for empty token
        if token.isEmpty {
            return .invalid(reason: .empty)
        }
        
 // 2. Check for whitespace (before trimming to detect it)
        if containsWhitespace(token) {
            return .invalid(reason: .containsWhitespace)
        }
        
 // 3. Check minimum length
        if token.count < Self.minimumTokenLength {
            return .invalid(reason: .tooShort)
        }
        
 // 4. Detect format and validate character set
        if let format = detectFormat(token) {
            return .valid(format: format)
        }
        
 // 5. Check if it's invalid characters vs invalid format
        if hasInvalidCharacters(token) {
            return .invalid(reason: .invalidCharacters)
        }
        
 // Token has valid characters but doesn't match any known format
        return .invalid(reason: .invalidFormat)
    }
    
 /// Validate token and emit security event if invalid.
 ///
 /// - Parameters:
 /// - token: The authentication token
 /// - connectionId: Optional connection identifier for logging
 /// - Returns: Validation result
    public func validateAndEmit(_ token: String, connectionId: String? = nil) async -> AuthTokenValidationResult {
        let result = validate(token)
        
        if !result.isValid, let reason = result.rejectionReason {
            let event = SecurityEvent.authTokenInvalid(
                reason: reason.rawValue,
                connectionId: connectionId
            )
            await SecurityEventEmitter.shared.emit(event)
        }
        
        return result
    }
    
 // MARK: - Release/Debug Handling
    
 /// Whether empty tokens are allowed (Debug only).
 ///
 /// - Release: Empty tokens are ALWAYS rejected
 /// - Debug: Empty tokens MAY be allowed for testing
 ///
 /// **Validates: Requirements 9.1, 9.2, 9.3**
    public static var allowEmptyInDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
    
 /// Check if an empty token should be accepted.
 ///
 /// - Parameter token: The token to check
 /// - Returns: true if the token is empty and should be accepted (Debug only)
    public func shouldAcceptEmptyToken(_ token: String) -> Bool {
        guard token.isEmpty else { return false }
        return Self.allowEmptyInDebug
    }
    
 /// Validate token with Release/Debug empty token handling.
 ///
 /// In Debug builds, empty tokens may be accepted for testing.
 /// In Release builds, empty tokens are always rejected.
 ///
 /// - Parameter token: The authentication token
 /// - Returns: Validation result
 ///
 /// **Validates: Requirements 9.1, 9.2, 9.3**
    public func validateWithDebugSupport(_ token: String) -> AuthTokenValidationResult {
 // In Debug, allow empty tokens for testing
        if shouldAcceptEmptyToken(token) {
 // Return valid with no format (special debug case)
            return AuthTokenValidationResult(isValid: true, detectedFormat: nil, rejectionReason: nil)
        }
        
        return validate(token)
    }
    
 // MARK: - Format Detection
    
 /// Detect the format of a token.
 ///
 /// - Parameter token: The token to analyze
 /// - Returns: Detected format, or nil if no valid format detected
    public func detectFormat(_ token: String) -> TokenFormat? {
 // Check UUID format first (more specific pattern)
        if isValidUUID(token) {
            return .uuid
        }
        
 // Check base64url format
        if isValidBase64url(token) {
            return .base64url
        }
        
        return nil
    }
    
 // MARK: - Private Helpers
    
 /// Check if token contains whitespace characters.
    private func containsWhitespace(_ token: String) -> Bool {
        token.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    
 /// Check if token has invalid characters (not in any valid charset).
    private func hasInvalidCharacters(_ token: String) -> Bool {
 // Combined valid charset: base64url + UUID chars
        let combinedValidSet = Self.base64urlCharacterSet.union(Self.uuidCharacterSet)
        return token.unicodeScalars.contains { !combinedValidSet.contains($0) }
    }
    
 /// Check if token is valid UUID format.
 ///
 /// UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (8-4-4-4-12)
    private func isValidUUID(_ token: String) -> Bool {
 // Quick length check: UUID is exactly 36 characters
        guard token.count == 36 else { return false }
        
 // Check character set first
        guard token.unicodeScalars.allSatisfy({ Self.uuidCharacterSet.contains($0) }) else {
            return false
        }
        
 // Validate 8-4-4-4-12 format with hyphens at correct positions
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        
        let expectedLengths = [8, 4, 4, 4, 12]
        for (part, expectedLength) in zip(parts, expectedLengths) {
            guard part.count == expectedLength else { return false }
 // Verify all characters are hex digits
            guard part.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        
        return true
    }
    
 /// Check if token is valid base64url format.
 ///
 /// Base64url: [A-Za-z0-9_-]+ (no padding, no `.` character)
    private func isValidBase64url(_ token: String) -> Bool {
 // Must have valid length
        guard token.count >= Self.minimumTokenLength else { return false }
        
 // All characters must be in base64url charset
        return token.unicodeScalars.allSatisfy { Self.base64urlCharacterSet.contains($0) }
    }
}

// MARK: - Character Extension

private extension Character {
 /// Check if character is a hexadecimal digit.
    var isHexDigit: Bool {
        switch self {
        case "0"..."9", "a"..."f", "A"..."F":
            return true
        default:
            return false
        }
    }
}

// MARK: - Testing Support

#if DEBUG
extension AuthTokenValidator {
 /// Generate a valid test token (base64url format).
    public static func generateTestToken(length: Int = 64) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
    
 /// Generate a valid test UUID token.
    public static func generateTestUUID() -> String {
        UUID().uuidString
    }
}
#endif
