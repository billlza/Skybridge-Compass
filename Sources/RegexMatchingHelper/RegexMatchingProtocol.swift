// MARK: - RegexMatchingProtocol.swift
// SkyBridge Compass - Security Hardening
// XPC Protocol for isolated regex matching
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

/// XPC protocol for regex matching in isolated helper process.
///
/// **Minimum Privilege Constraints (Critical)**:
/// - Stateless: No persistent state
/// - No file system access entitlement: Does not read files
/// - No network entitlement: Does not connect to network
/// - Input only: pattern string + input bytes (limited to perPatternInputLimit)
/// - Output only: match results or timeout/error
///
/// This prevents the helper from being exploited as a "privileged resident process".
@objc public protocol RegexMatchingProtocol {
    
 /// Perform regex matching in isolated environment.
 ///
 /// - Parameters:
 /// - pattern: The regex pattern string (already validated by RegexValidator)
 /// - inputData: The input data to match against (limited to perPatternInputLimit)
 /// - timeoutMs: Hard timeout in milliseconds
 /// - reply: Callback with results or error
 ///
 /// The helper will terminate matching if timeout is exceeded.
    func matchPattern(
        _ pattern: String,
        in inputData: Data,
        timeoutMs: Int,
        reply: @escaping @Sendable ([RegexMatchResult]?, RegexMatchError?) -> Void
    )
    
 /// Ping to verify helper is alive.
    func ping(reply: @escaping @Sendable (Bool) -> Void)
}

/// Result of a regex match operation.
/// Serializable for XPC transport.
@objc public class RegexMatchResult: NSObject, NSSecureCoding {
    
 /// Range location in the input
    @objc public let location: Int
    
 /// Range length
    @objc public let length: Int
    
 /// Captured groups (if any)
    @objc public let capturedGroups: [String]
    
    public init(location: Int, length: Int, capturedGroups: [String] = []) {
        self.location = location
        self.length = length
        self.capturedGroups = capturedGroups
        super.init()
    }
    
 // MARK: - NSSecureCoding
    
    public static var supportsSecureCoding: Bool { true }
    
    public func encode(with coder: NSCoder) {
        coder.encode(location, forKey: "location")
        coder.encode(length, forKey: "length")
        coder.encode(capturedGroups, forKey: "capturedGroups")
    }
    
    public required init?(coder: NSCoder) {
        self.location = coder.decodeInteger(forKey: "location")
        self.length = coder.decodeInteger(forKey: "length")
        self.capturedGroups = coder.decodeObject(of: [NSArray.self, NSString.self], forKey: "capturedGroups") as? [String] ?? []
        super.init()
    }
}

/// Error types for regex matching operations.
@objc public class RegexMatchError: NSObject, NSSecureCoding {
    
 /// Error code
    @objc public let code: Int
    
 /// Error message
    @objc public let message: String
    
 /// Error codes
    public static let codeTimeout = 1
    public static let codeInvalidPattern = 2
    public static let codeInputTooLarge = 3
    public static let codeInternalError = 4
    public static let codeCancelled = 5
    
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
        super.init()
    }
    
 /// Convenience initializers
    public static func timeout() -> RegexMatchError {
        RegexMatchError(code: codeTimeout, message: "Regex matching timed out")
    }
    
    public static func invalidPattern(_ reason: String) -> RegexMatchError {
        RegexMatchError(code: codeInvalidPattern, message: "Invalid pattern: \(reason)")
    }
    
    public static func inputTooLarge(actual: Int, max: Int) -> RegexMatchError {
        RegexMatchError(code: codeInputTooLarge, message: "Input too large: \(actual) > \(max)")
    }
    
    public static func internalError(_ reason: String) -> RegexMatchError {
        RegexMatchError(code: codeInternalError, message: "Internal error: \(reason)")
    }
    
    public static func cancelled() -> RegexMatchError {
        RegexMatchError(code: codeCancelled, message: "Matching cancelled")
    }
    
 // MARK: - NSSecureCoding
    
    public static var supportsSecureCoding: Bool { true }
    
    public func encode(with coder: NSCoder) {
        coder.encode(code, forKey: "code")
        coder.encode(message, forKey: "message")
    }
    
    public required init?(coder: NSCoder) {
        self.code = coder.decodeInteger(forKey: "code")
        self.message = coder.decodeObject(of: NSString.self, forKey: "message") as? String ?? "Unknown error"
        super.init()
    }
}
