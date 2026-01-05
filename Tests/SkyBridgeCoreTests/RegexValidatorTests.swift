// MARK: - RegexValidatorTests.swift
// SkyBridge Compass - Security Hardening Tests
// Copyright © 2024 SkyBridge. All rights reserved.

import XCTest
@testable import SkyBridgeCore

/// Unit tests for RegexValidator.
/// Tests tokenization, dangerous construct detection, and complexity limits.
final class RegexValidatorTests: XCTestCase {
    
    var validator: RegexValidator!
    
    override func setUp() async throws {
        validator = RegexValidator(limits: .default)
    }
    
    override func tearDown() async throws {
        validator = nil
    }
    
 // MARK: - Tokenization Tests
    
    func testTokenizeLiteralCharacters() async {
        let tokens = await validator.tokenize("abc")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0], .literal("a"))
        XCTAssertEqual(tokens[1], .literal("b"))
        XCTAssertEqual(tokens[2], .literal("c"))
    }
    
    func testTokenizeEscapedCharacters() async {
        let tokens = await validator.tokenize("\\d\\w\\+")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0], .escaped("d"))
        XCTAssertEqual(tokens[1], .escaped("w"))
        XCTAssertEqual(tokens[2], .escaped("+"))
    }
    
    func testTokenizeCharacterClass() async {
        let tokens = await validator.tokenize("[a-z]")
        XCTAssertEqual(tokens.count, 1)
        if case .characterClass(let content) = tokens[0] {
            XCTAssertEqual(content, "a-z")
        } else {
            XCTFail("Expected character class token")
        }
    }
    
    func testTokenizeNegatedCharacterClass() async {
        let tokens = await validator.tokenize("[^0-9]")
        XCTAssertEqual(tokens.count, 1)
        if case .characterClass(let content) = tokens[0] {
            XCTAssertEqual(content, "^0-9")
        } else {
            XCTFail("Expected character class token")
        }
    }
    
    func testTokenizeCapturingGroup() async {
        let tokens = await validator.tokenize("(abc)")
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(tokens[0], .group(isCapturing: true))
        XCTAssertEqual(tokens[4], .groupEnd)
    }
    
    func testTokenizeNonCapturingGroup() async {
        let tokens = await validator.tokenize("(?:abc)")
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(tokens[0], .group(isCapturing: false))
    }
    
    func testTokenizeQuantifiers() async {
        let tokens = await validator.tokenize("a*b+c?")
        XCTAssertEqual(tokens.count, 6)
        XCTAssertEqual(tokens[1], .quantifier("*"))
        XCTAssertEqual(tokens[3], .quantifier("+"))
        XCTAssertEqual(tokens[5], .quantifier("?"))
    }
    
    func testTokenizeAlternation() async {
        let tokens = await validator.tokenize("a|b")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[1], .alternation)
    }
    
    func testTokenizeAnchors() async {
        let tokens = await validator.tokenize("^abc$")
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(tokens[0], .anchor("^"))
        XCTAssertEqual(tokens[4], .anchor("$"))
    }
    
    func testTokenizeDot() async {
        let tokens = await validator.tokenize("a.b")
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[1], .dot)
    }
    
    func testTokenizePositiveLookahead() async {
        let tokens = await validator.tokenize("a(?=b)")
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[1], .lookahead(isPositive: true))
    }
    
    func testTokenizeNegativeLookahead() async {
        let tokens = await validator.tokenize("a(?!b)")
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[1], .lookahead(isPositive: false))
    }
    
    func testTokenizeBackreference() async {
        let tokens = await validator.tokenize("(a)\\1")
        XCTAssertTrue(tokens.contains(.backreference(1)))
    }
    
    func testTokenizeLookbehind() async {
        let tokens = await validator.tokenize("(?<=a)b")
        XCTAssertTrue(tokens.contains(.lookbehind(isPositive: true)))
    }
    
    func testTokenizeNegativeLookbehind() async {
        let tokens = await validator.tokenize("(?<!a)b")
        XCTAssertTrue(tokens.contains(.lookbehind(isPositive: false)))
    }
    
    func testTokenizeInlineFlag() async {
        let tokens = await validator.tokenize("(?i)abc")
        XCTAssertTrue(tokens.contains(where: { 
            if case .inlineFlag = $0 { return true }
            return false
        }))
    }
    
    func testTokenizeNamedCapture() async {
        let tokens = await validator.tokenize("(?<name>abc)")
        XCTAssertTrue(tokens.contains(where: {
            if case .namedCapture = $0 { return true }
            return false
        }))
    }
    
 // MARK: - Dangerous Construct Detection Tests
    
    func testDetectNestedQuantifiers() async {
 // (a+)+ is a classic ReDoS pattern
        let tokens = await validator.tokenize("(a+)+")
        let hasNested = await validator.detectNestedQuantifiers(tokens)
        XCTAssertTrue(hasNested, "Should detect nested quantifiers in (a+)+")
    }
    
    func testDetectNestedQuantifiersWithStar() async {
 // (a*)* is also dangerous
        let tokens = await validator.tokenize("(a*)*")
        let hasNested = await validator.detectNestedQuantifiers(tokens)
        XCTAssertTrue(hasNested, "Should detect nested quantifiers in (a*)*")
    }
    
    func testNoNestedQuantifiersInSimplePattern() async {
        let tokens = await validator.tokenize("a+b*c?")
        let hasNested = await validator.detectNestedQuantifiers(tokens)
        XCTAssertFalse(hasNested, "Should not detect nested quantifiers in simple pattern")
    }
    
    func testNoNestedQuantifiersInGroupWithoutInnerQuantifier() async {
        let tokens = await validator.tokenize("(abc)+")
        let hasNested = await validator.detectNestedQuantifiers(tokens)
        XCTAssertFalse(hasNested, "Should not detect nested quantifiers when group has no inner quantifier")
    }
    
    func testDetectBackreferences() async {
        let tokens = await validator.tokenize("(a)\\1")
        let hasBackref = await validator.detectBackreferences(tokens)
        XCTAssertTrue(hasBackref)
    }
    
    func testNoBackreferencesInSimplePattern() async {
        let tokens = await validator.tokenize("abc")
        let hasBackref = await validator.detectBackreferences(tokens)
        XCTAssertFalse(hasBackref)
    }
    
    func testDetectLookbehind() async {
        let tokens = await validator.tokenize("(?<=a)b")
        let hasLookbehind = await validator.detectLookbehind(tokens)
        XCTAssertTrue(hasLookbehind)
    }
    
    func testDetectInlineFlags() async {
        let tokens = await validator.tokenize("(?i)abc")
        let hasFlags = await validator.detectInlineFlags(tokens)
        XCTAssertTrue(hasFlags)
    }
    
    func testDetectNamedCaptures() async {
        let tokens = await validator.tokenize("(?<name>abc)")
        let hasNamed = await validator.detectNamedCaptures(tokens)
        XCTAssertTrue(hasNamed)
    }
    
 // MARK: - Complexity Counting Tests
    
    func testCountGroups() async {
        let tokens = await validator.tokenize("(a)(b)(c)")
        let count = await validator.countGroups(tokens)
        XCTAssertEqual(count, 3)
    }
    
    func testCountGroupsIncludesLookaheads() async {
        let tokens = await validator.tokenize("(a)(?=b)")
        let count = await validator.countGroups(tokens)
        XCTAssertEqual(count, 2)
    }
    
    func testCountQuantifiers() async {
        let tokens = await validator.tokenize("a*b+c?d{2}")
        let count = await validator.countQuantifiers(tokens)
        XCTAssertEqual(count, 4)
    }
    
    func testCountAlternations() async {
        let tokens = await validator.tokenize("a|b|c|d")
        let count = await validator.countAlternations(tokens)
        XCTAssertEqual(count, 3)
    }
    
    func testCountLookaheads() async {
        let tokens = await validator.tokenize("(?=a)(?!b)(?=c)")
        let count = await validator.countLookaheads(tokens)
        XCTAssertEqual(count, 3)
    }
    
 // MARK: - Validation Tests
    
    func testValidateSimplePattern() async {
        let result = await validator.validate(pattern: "abc")
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.rejectionReason)
    }
    
    func testValidatePatternTooLong() async {
        let longPattern = String(repeating: "a", count: 1001)
        let result = await validator.validate(pattern: longPattern)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .tooLong)
    }
    
    func testValidateRejectsNestedQuantifiers() async {
        let result = await validator.validate(pattern: "(a+)+")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .nestedQuantifiers)
    }
    
    func testValidateRejectsBackreferences() async {
        let result = await validator.validate(pattern: "(a)\\1")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .backreference)
    }
    
    func testValidateRejectsLookbehind() async {
        let result = await validator.validate(pattern: "(?<=a)b")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .lookbehind)
    }
    
    func testValidateRejectsInlineFlags() async {
        let result = await validator.validate(pattern: "(?i)abc")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .inlineFlags)
    }
    
    func testValidateRejectsNamedCaptures() async {
        let result = await validator.validate(pattern: "(?<name>abc)")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .namedCapture)
    }
    
    func testValidateRejectsTooManyGroups() async {
 // Create pattern with 11 groups (limit is 10)
        let pattern = String(repeating: "(a)", count: 11)
        let result = await validator.validate(pattern: pattern)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .tooManyGroups)
    }
    
    func testValidateRejectsTooManyQuantifiers() async {
 // Create pattern with 21 quantifiers (limit is 20)
        let pattern = String(repeating: "a+", count: 21)
        let result = await validator.validate(pattern: pattern)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .tooManyQuantifiers)
    }
    
    func testValidateRejectsTooManyAlternations() async {
 // Create pattern with 11 alternations (limit is 10)
        let parts = (0...11).map { "a\($0)" }
        let pattern = parts.joined(separator: "|")
        let result = await validator.validate(pattern: pattern)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .tooManyAlternations)
    }
    
    func testValidateRejectsTooManyLookaheads() async {
 // Create pattern with 4 lookaheads (limit is 3)
        let pattern = "(?=a)(?=b)(?=c)(?=d)"
        let result = await validator.validate(pattern: pattern)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.rejectionReason, .tooManyLookaheads)
    }
    
    func testValidateAcceptsPatternAtLimits() async {
 // Pattern with exactly 10 groups (including lookaheads), 10 quantifiers, 10 alternations, 3 lookaheads
 // Note: lookaheads count as groups, so 7 capturing groups + 3 lookaheads = 10 groups
        let pattern = "(a)+(b)+(c)+(d)+(e)+(f)+(g)+|k|l|m|n|o|p|q|r|s|t(?=u)(?=v)(?=w)"
        let result = await validator.validate(pattern: pattern)
 // This pattern has 7 capturing groups + 3 lookaheads = 10 groups total
 // 7 quantifiers, 10 alternations, 3 lookaheads
        XCTAssertTrue(result.isValid, "Pattern at limits should be valid, got: \(result.rejectionReason?.rawValue ?? "nil"), complexity: \(result.complexity)")
    }
    
    func testValidateAllowsPositiveLookahead() async {
        let result = await validator.validate(pattern: "a(?=b)c")
        XCTAssertTrue(result.isValid)
    }
    
    func testValidateAllowsNegativeLookahead() async {
        let result = await validator.validate(pattern: "a(?!b)c")
        XCTAssertTrue(result.isValid)
    }
    
 // MARK: - Edge Cases
    
    func testTokenizeEscapedBracket() async {
        let tokens = await validator.tokenize("\\[abc\\]")
        XCTAssertEqual(tokens[0], .escaped("["))
        XCTAssertEqual(tokens[4], .escaped("]"))
    }
    
    func testTokenizeEscapedParenthesis() async {
        let tokens = await validator.tokenize("\\(abc\\)")
        XCTAssertEqual(tokens[0], .escaped("("))
        XCTAssertEqual(tokens[4], .escaped(")"))
    }
    
    func testTokenizeCharacterClassWithBracket() async {
 // []] means a character class containing ]
        let tokens = await validator.tokenize("[]]")
        XCTAssertEqual(tokens.count, 1)
        if case .characterClass(let content) = tokens[0] {
            XCTAssertEqual(content, "]")
        } else {
            XCTFail("Expected character class token")
        }
    }
    
    func testEmptyPattern() async {
        let result = await validator.validate(pattern: "")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.complexity.length, 0)
    }
    
    func testComplexValidPattern() async {
 // A complex but valid pattern
        let pattern = "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"
        let result = await validator.validate(pattern: pattern)
        XCTAssertTrue(result.isValid, "Email-like pattern should be valid")
    }
}

// MARK: - Property Test: Regex Dangerous Construct Rejection
// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
// **Validates: Requirements 2.3, 2.7**

/// Test data generator for regex patterns with dangerous constructs
enum RegexDangerousConstructGenerator {
    
 /// Generate a random nested quantifier pattern (e.g., (a+)+, (b*)+, ([a-z]+)*)
    static func generateNestedQuantifierPattern() -> String {
        let innerChars = ["a", "b", "c", "\\d", "\\w", "[a-z]", "[0-9]", "."]
        let quantifiers = ["+", "*", "?", "{2}", "{1,3}"]
        
        let innerChar = innerChars.randomElement()!
        let innerQuantifier = quantifiers.randomElement()!
        let outerQuantifier = quantifiers.randomElement()!
        
 // Randomly choose between capturing and non-capturing groups
        let groupStart = Bool.random() ? "(" : "(?:"
        
        return "\(groupStart)\(innerChar)\(innerQuantifier))\(outerQuantifier)"
    }
    
 /// Generate a random backreference pattern (e.g., (a)\1, (b)(c)\2)
    static func generateBackreferencePattern() -> String {
        let chars = ["a", "b", "c", "\\d", "\\w", "[a-z]"]
        let groupCount = Int.random(in: 1...3)
        
        var pattern = ""
        for _ in 0..<groupCount {
            let char = chars.randomElement()!
            pattern += "(\(char))"
        }
        
 // Add backreference to one of the groups
        let refNum = Int.random(in: 1...groupCount)
        pattern += "\\\(refNum)"
        
        return pattern
    }
    
 /// Generate a random lookbehind pattern (e.g., (?<=a)b, (?<!x)y)
    static func generateLookbehindPattern() -> String {
        let chars = ["a", "b", "c", "x", "y", "z"]
        let lookbehindChar = chars.randomElement()!
        let followingChar = chars.randomElement()!
        
 // Randomly choose positive or negative lookbehind
        let lookbehind = Bool.random() ? "(?<=\(lookbehindChar))" : "(?<!\(lookbehindChar))"
        
        return "\(lookbehind)\(followingChar)"
    }
    
 /// Generate a random inline flag pattern (e.g., (?i)abc, (?m)xyz)
 /// Note: Inline flags use syntax (?i) NOT (?:i) - the latter is a non-capturing group
    static func generateInlineFlagPattern() -> String {
        let flags = ["i", "m", "s", "x", "u"]
        let flag = flags.randomElement()!
        let chars = ["abc", "xyz", "test", "\\d+", "[a-z]+"]
        let content = chars.randomElement()!
        
 // Correct inline flag syntax: (?i)content, NOT (?:i)content
        return "(?\(flag))\(content)"
    }
    
 /// Generate a random named capture pattern (e.g., (?<name>abc), (?P<id>\d+))
    static func generateNamedCapturePattern() -> String {
        let names = ["name", "id", "value", "group", "match"]
        let name = names.randomElement()!
        let content = ["abc", "\\d+", "[a-z]+", "test"].randomElement()!
        
 // Randomly choose between (?<name>...) and (?P<name>...) syntax
        if Bool.random() {
            return "(?<\(name)>\(content))"
        } else {
            return "(?P<\(name)>\(content))"
        }
    }
    
 /// Generate a safe pattern (no dangerous constructs)
    static func generateSafePattern() -> String {
        let components = [
            "abc",
            "\\d+",
            "[a-z]+",
            "(test)",
            "(?:group)",
            "a|b|c",
            "^start",
            "end$",
            "(?=lookahead)",
            "(?!negative)"
        ]
        
        let count = Int.random(in: 1...3)
        var pattern = ""
        for _ in 0..<count {
            pattern += components.randomElement()!
        }
        
        return pattern
    }
    
 /// Enum representing dangerous construct types
    enum DangerousConstructType: CaseIterable {
        case nestedQuantifiers
        case backreference
        case lookbehind
        case inlineFlags
        case namedCapture
        
        var expectedRejectionReason: RegexValidationResult.RejectionReason {
            switch self {
            case .nestedQuantifiers: return .nestedQuantifiers
            case .backreference: return .backreference
            case .lookbehind: return .lookbehind
            case .inlineFlags: return .inlineFlags
            case .namedCapture: return .namedCapture
            }
        }
        
        func generatePattern() -> String {
            switch self {
            case .nestedQuantifiers:
                return RegexDangerousConstructGenerator.generateNestedQuantifierPattern()
            case .backreference:
                return RegexDangerousConstructGenerator.generateBackreferencePattern()
            case .lookbehind:
                return RegexDangerousConstructGenerator.generateLookbehindPattern()
            case .inlineFlags:
                return RegexDangerousConstructGenerator.generateInlineFlagPattern()
            case .namedCapture:
                return RegexDangerousConstructGenerator.generateNamedCapturePattern()
            }
        }
    }
}

/// Property-based tests for regex dangerous construct rejection
final class RegexDangerousConstructRejectionTests: XCTestCase {
    
    var validator: RegexValidator!
    
    override func setUp() async throws {
        try await super.setUp()
        validator = RegexValidator(limits: .default)
    }
    
    override func tearDown() async throws {
        validator = nil
        try await super.tearDown()
    }
    
 // MARK: - Property 4: Regex Dangerous Construct Rejection
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: For any regex pattern containing nested quantifiers, backreferences, or lookbehind,
 /// the validator SHALL reject the pattern.
 ///
 /// This test verifies:
 /// 1. Nested quantifier patterns are always rejected with .nestedQuantifiers reason
 /// 2. Backreference patterns are always rejected with .backreference reason
 /// 3. Lookbehind patterns are always rejected with .lookbehind reason
 /// 4. Inline flag patterns are always rejected with .inlineFlags reason
 /// 5. Named capture patterns are always rejected with .namedCapture reason
    func testProperty4_DangerousConstructsAreRejected() async throws {
 // Run 100 iterations with different random patterns
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Test each dangerous construct type
            for constructType in RegexDangerousConstructGenerator.DangerousConstructType.allCases {
                let pattern = constructType.generatePattern()
                let result = await validator.validate(pattern: pattern)
                
 // Property: Pattern must be rejected
                XCTAssertFalse(
                    result.isValid,
                    "Iteration \(iteration): Pattern '\(pattern)' with \(constructType) should be rejected"
                )
                
 // Property: Rejection reason must match the construct type
                XCTAssertEqual(
                    result.rejectionReason,
                    constructType.expectedRejectionReason,
                    "Iteration \(iteration): Pattern '\(pattern)' should be rejected with reason \(constructType.expectedRejectionReason), got \(result.rejectionReason?.rawValue ?? "nil")"
                )
            }
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: For any safe regex pattern (no dangerous constructs),
 /// the validator SHALL accept the pattern (assuming it's within complexity limits).
    func testProperty4_SafePatternsAreAccepted() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let pattern = RegexDangerousConstructGenerator.generateSafePattern()
            let result = await validator.validate(pattern: pattern)
            
 // Safe patterns should be valid (unless they exceed complexity limits)
 // We only check that they're not rejected for dangerous constructs
            if !result.isValid {
 // If rejected, it should NOT be for dangerous construct reasons
                let dangerousReasons: Set<RegexValidationResult.RejectionReason> = [
                    .nestedQuantifiers,
                    .backreference,
                    .lookbehind,
                    .inlineFlags,
                    .namedCapture
                ]
                
                if let reason = result.rejectionReason {
                    XCTAssertFalse(
                        dangerousReasons.contains(reason),
                        "Iteration \(iteration): Safe pattern '\(pattern)' should not be rejected for dangerous construct reason \(reason)"
                    )
                }
            }
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Nested quantifiers detection is robust across various patterns.
 /// Tests specific nested quantifier patterns that are known ReDoS vectors.
    func testProperty4_NestedQuantifiersRobustDetection() async throws {
 // Known ReDoS patterns with nested quantifiers
        let nestedQuantifierPatterns = [
            "(a+)+",           // Classic ReDoS
            "(a*)*",           // Star-star
            "(a+)*",           // Plus-star
            "(a*)+",           // Star-plus
            "((a+)+)+",        // Triple nested
            "(a+)+b",          // With suffix
            "^(a+)+$",         // With anchors
            "(\\d+)+",         // With escape
            "([a-z]+)+",       // With character class
            "(?:a+)+",         // Non-capturing
            "(a+|b+)+",        // With alternation inside
            "(a{2,})+",        // With range quantifier
            "((ab)+)+",        // Multi-char inside
        ]
        
        for pattern in nestedQuantifierPatterns {
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Pattern '\(pattern)' should be rejected as nested quantifier"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .nestedQuantifiers,
                "Pattern '\(pattern)' should be rejected with .nestedQuantifiers reason, got \(result.rejectionReason?.rawValue ?? "nil")"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Backreference detection works for all valid backreference numbers.
    func testProperty4_BackreferenceDetectionAllNumbers() async throws {
 // Test backreferences \1 through \9
        for refNum in 1...9 {
            let pattern = String(repeating: "(a)", count: refNum) + "\\\(refNum)"
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Pattern with backreference \\(\(refNum)) should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .backreference,
                "Pattern with backreference \\(\(refNum)) should be rejected with .backreference reason"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Lookbehind detection works for both positive and negative lookbehind.
    func testProperty4_LookbehindDetectionBothTypes() async throws {
        let lookbehindPatterns = [
            ("(?<=a)b", true),   // Positive lookbehind
            ("(?<!a)b", false),  // Negative lookbehind
            ("(?<=\\d)x", true), // With escape
            ("(?<![a-z])y", false), // With character class
            ("x(?<=y)z", true),  // In middle
        ]
        
        for (pattern, _) in lookbehindPatterns {
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Pattern '\(pattern)' with lookbehind should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .lookbehind,
                "Pattern '\(pattern)' should be rejected with .lookbehind reason"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Escaped dangerous characters are NOT treated as dangerous constructs.
 /// This verifies that \( \+ etc. are correctly handled as escaped literals.
 ///
 /// Note: In regex, \1 through \9 ARE backreferences, not escaped digits.
 /// To match a literal "1", you don't need to escape it - just use "1".
 /// The escape sequence \1 specifically means "backreference to group 1".
    func testProperty4_EscapedCharactersAreNotDangerous() async throws {
 // Patterns with escaped characters that look like dangerous constructs
 // but are actually safe escaped literals
        let escapedPatterns = [
            "\\(a\\+\\)+",      // Escaped parens and plus - NOT nested quantifiers (literal "(a+)+")
            "\\?\\<\\=a",       // Escaped lookbehind chars - NOT lookbehind (literal "?<=a")
            "a\\(b\\)c",        // Escaped parens - literal "(b)"
            "\\[a-z\\]",        // Escaped brackets - literal "[a-z]"
            "\\*\\+\\?",        // Escaped quantifiers - literal "*+?"
        ]
        
        for pattern in escapedPatterns {
            let result = await validator.validate(pattern: pattern)
            
 // These should NOT be rejected for dangerous construct reasons
 // (they might be rejected for other reasons like complexity)
            if !result.isValid {
                let dangerousReasons: Set<RegexValidationResult.RejectionReason> = [
                    .nestedQuantifiers,
                    .backreference,
                    .lookbehind
                ]
                
                if let reason = result.rejectionReason {
                    XCTAssertFalse(
                        dangerousReasons.contains(reason),
                        "Escaped pattern '\(pattern)' should not be rejected for dangerous construct reason \(reason)"
                    )
                }
            }
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Backreferences \1-\9 ARE correctly detected as dangerous.
 /// Note: In regex, \1 through \9 are backreferences, not escaped digits.
    func testProperty4_BackreferencesAreCorrectlyDetected() async throws {
 // \1 through \9 are backreferences in regex, not escaped digits
 // They should be detected and rejected
        let backreferencePatterns = [
            "(a)\\1",           // Backreference to group 1
            "(a)(b)\\2",        // Backreference to group 2
            "a\\1b",            // Backreference without preceding group (still detected)
        ]
        
        for pattern in backreferencePatterns {
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Pattern '\(pattern)' with backreference should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .backreference,
                "Pattern '\(pattern)' should be rejected with .backreference reason"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Inline flags are detected and rejected.
    func testProperty4_InlineFlagsDetection() async throws {
        let inlineFlagPatterns = [
            "(?i)abc",          // Case insensitive
            "(?m)^line$",       // Multiline
            "(?s)a.b",          // Single line (dot matches newline)
            "(?x) a b c",       // Extended (ignore whitespace)
            "(?u)\\w+",         // Unicode
            "(?im)test",        // Multiple flags
            "(?i-m)test",       // Flag with negation
        ]
        
        for pattern in inlineFlagPatterns {
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Pattern '\(pattern)' with inline flags should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .inlineFlags,
                "Pattern '\(pattern)' should be rejected with .inlineFlags reason, got \(result.rejectionReason?.rawValue ?? "nil")"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Named captures are detected and rejected (both syntaxes).
    func testProperty4_NamedCaptureDetection() async throws {
        let namedCapturePatterns = [
            "(?<name>abc)",         // Standard syntax
            "(?P<name>abc)",        // Python syntax
            "(?<id>\\d+)",          // With escape
            "(?<group>[a-z]+)",     // With character class
            "(?<a>x)(?<b>y)",       // Multiple named captures
        ]
        
        for pattern in namedCapturePatterns {
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Pattern '\(pattern)' with named capture should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .namedCapture,
                "Pattern '\(pattern)' should be rejected with .namedCapture reason, got \(result.rejectionReason?.rawValue ?? "nil")"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 4: Regex dangerous construct rejection**
 /// **Validates: Requirements 2.3, 2.7**
 ///
 /// Property: Lookahead (positive and negative) is ALLOWED (not dangerous).
 /// Only lookbehind is forbidden.
    func testProperty4_LookaheadIsAllowed() async throws {
        let lookaheadPatterns = [
            "a(?=b)",           // Positive lookahead
            "a(?!b)",           // Negative lookahead
            "(?=\\d)x",         // With escape
            "(?![a-z])y",       // With character class
        ]
        
        for pattern in lookaheadPatterns {
            let result = await validator.validate(pattern: pattern)
            
 // Lookahead should be allowed (pattern might fail for other reasons like too many lookaheads)
            if !result.isValid {
                XCTAssertNotEqual(
                    result.rejectionReason,
                    .lookbehind,
                    "Lookahead pattern '\(pattern)' should not be rejected as lookbehind"
                )
            }
        }
    }
}

// MARK: - Property Test: Regex Complexity Limits Enforcement
// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
// **Validates: Requirements 2.4, 2.5, 2.8**

/// Test data generator for regex patterns with varying complexity
enum RegexComplexityGenerator {
    
 /// Generate a pattern with exactly N groups (capturing)
 /// - Parameter count: Number of groups to generate
 /// - Returns: Pattern string with specified number of groups
    static func generatePatternWithGroups(count: Int) -> String {
 // Each (a) adds one group
        return String(repeating: "(a)", count: count)
    }
    
 /// Generate a pattern with exactly N quantifiers
 /// - Parameter count: Number of quantifiers to generate
 /// - Returns: Pattern string with specified number of quantifiers
    static func generatePatternWithQuantifiers(count: Int) -> String {
 // Each a+ adds one quantifier
        let quantifiers = ["+", "*", "?", "{2}"]
        var pattern = ""
        for i in 0..<count {
            let q = quantifiers[i % quantifiers.count]
            pattern += "a\(q)"
        }
        return pattern
    }
    
 /// Generate a pattern with exactly N alternations
 /// - Parameter count: Number of alternations (|) to generate
 /// - Returns: Pattern string with specified number of alternations
    static func generatePatternWithAlternations(count: Int) -> String {
 // N alternations means N+1 alternatives: a|b|c has 2 alternations
        let parts = (0...count).map { "a\($0)" }
        return parts.joined(separator: "|")
    }
    
 /// Generate a pattern with exactly N lookaheads
 /// - Parameter count: Number of lookaheads to generate
 /// - Returns: Pattern string with specified number of lookaheads
    static func generatePatternWithLookaheads(count: Int) -> String {
 // Each (?=a) or (?!a) adds one lookahead
        var pattern = ""
        for i in 0..<count {
            let isPositive = i % 2 == 0
            pattern += isPositive ? "(?=a\(i))" : "(?!b\(i))"
        }
        return pattern
    }
    
 /// Generate a pattern with specified length
 /// - Parameter length: Target pattern length
 /// - Returns: Pattern string of approximately the specified length
    static func generatePatternWithLength(_ length: Int) -> String {
 // Use simple literals to reach the target length
        return String(repeating: "a", count: length)
    }
    
 /// Generate a random complexity within limits
 /// - Parameter limits: The security limits to stay within
 /// - Returns: A valid pattern within all limits
    static func generateValidPattern(limits: SecurityLimits) -> String {
 // Generate random counts within limits
        let groupCount = Int.random(in: 0...min(limits.maxRegexGroups, 5))
        let quantifierCount = Int.random(in: 0...min(limits.maxRegexQuantifiers, 10))
        let alternationCount = Int.random(in: 0...min(limits.maxRegexAlternations, 5))
        let lookaheadCount = Int.random(in: 0...min(limits.maxRegexLookaheads, 2))
        
        var parts: [String] = []
        
 // Add groups
        if groupCount > 0 {
            parts.append(generatePatternWithGroups(count: groupCount))
        }
        
 // Add quantifiers (but not nested with groups to avoid nested quantifier detection)
        if quantifierCount > 0 {
            parts.append(generatePatternWithQuantifiers(count: quantifierCount))
        }
        
 // Add alternations
        if alternationCount > 0 {
            parts.append(generatePatternWithAlternations(count: alternationCount))
        }
        
 // Add lookaheads (these count as groups too, so adjust)
        if lookaheadCount > 0 && groupCount + lookaheadCount <= limits.maxRegexGroups {
            parts.append(generatePatternWithLookaheads(count: lookaheadCount))
        }
        
        let pattern = parts.joined()
        
 // Ensure pattern doesn't exceed length limit
        if pattern.count > limits.maxRegexPatternLength {
            return String(pattern.prefix(limits.maxRegexPatternLength))
        }
        
        return pattern.isEmpty ? "abc" : pattern
    }
    
 /// Generate a pattern that exceeds a specific limit
    enum ExceededLimit: CaseIterable {
        case length
        case groups
        case quantifiers
        case alternations
        case lookaheads
        
        var expectedRejectionReason: RegexValidationResult.RejectionReason {
            switch self {
            case .length: return .tooLong
            case .groups: return .tooManyGroups
            case .quantifiers: return .tooManyQuantifiers
            case .alternations: return .tooManyAlternations
            case .lookaheads: return .tooManyLookaheads
            }
        }
    }
    
 /// Generate a pattern that exceeds the specified limit
 /// - Parameters:
 /// - limit: Which limit to exceed
 /// - limits: The security limits configuration
 /// - Returns: A pattern that exceeds the specified limit
    static func generatePatternExceeding(_ limit: ExceededLimit, limits: SecurityLimits) -> String {
        switch limit {
        case .length:
            return generatePatternWithLength(limits.maxRegexPatternLength + 1)
            
        case .groups:
            return generatePatternWithGroups(count: limits.maxRegexGroups + 1)
            
        case .quantifiers:
            return generatePatternWithQuantifiers(count: limits.maxRegexQuantifiers + 1)
            
        case .alternations:
            return generatePatternWithAlternations(count: limits.maxRegexAlternations + 1)
            
        case .lookaheads:
            return generatePatternWithLookaheads(count: limits.maxRegexLookaheads + 1)
        }
    }
}

/// Property-based tests for regex complexity limits enforcement
final class RegexComplexityLimitsTests: XCTestCase {
    
    var validator: RegexValidator!
    var customLimits: SecurityLimits!
    
    override func setUp() async throws {
        try await super.setUp()
 // Use smaller limits for faster testing
        customLimits = SecurityLimits(
            maxTotalFiles: 10_000,
            maxTotalBytes: 50 * 1024 * 1024 * 1024,
            globalTimeout: 300.0,
            maxRegexPatternLength: 100,  // Smaller for testing
            maxRegexPatternCount: 10,    // Smaller for testing
            maxRegexGroups: 5,           // Smaller for testing
            maxRegexQuantifiers: 10,     // Smaller for testing
            maxRegexAlternations: 5,     // Smaller for testing
            maxRegexLookaheads: 2,       // Smaller for testing
            perPatternTimeout: 0.05,
            perPatternInputLimit: 1024 * 1024,
            maxTotalHistoryBytes: 10 * 1024 * 1024,
            tokenBucketRate: 100.0,
            tokenBucketBurst: 200,
            maxMessageBytes: 64 * 1024,
            decodeDepthLimit: 10,
            decodeArrayLengthLimit: 1000,
            decodeStringLengthLimit: 64 * 1024,
            droppedMessagesThreshold: 500,
            droppedMessagesWindow: 10.0,
            pakeRecordTTL: 600.0,
            pakeMaxRecords: 10_000,
            pakeCleanupInterval: 128,
            maxSymlinkDepth: 10,
            maxRetryCount: 20,
            maxRetryDelay: 300.0,
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: 500 * 1024 * 1024,
            maxNestingDepth: 3,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 10.0,
            maxBytesPerFile: 100 * 1024 * 1024,
            largeFileThreshold: 500 * 1024 * 1024,
            hashTimeoutQuick: 2.0,
            hashTimeoutStandard: 5.0,
            hashTimeoutDeep: 10.0,
            maxEventQueueSize: 10_000,
            maxPendingPerSubscriber: 1_000
        )
        validator = RegexValidator(limits: customLimits)
    }
    
    override func tearDown() async throws {
        validator = nil
        customLimits = nil
        try await super.tearDown()
    }
    
 // MARK: - Property 5: Regex Complexity Limits Enforcement
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: For any regex pattern exceeding maxRegexPatternLength,
 /// the validator SHALL reject with .tooLong reason.
    func testProperty5_PatternLengthLimitEnforcement() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate pattern exceeding length limit by random amount
            let excessLength = Int.random(in: 1...100)
            let pattern = RegexComplexityGenerator.generatePatternWithLength(
                customLimits.maxRegexPatternLength + excessLength
            )
            
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Pattern of length \(pattern.count) (limit: \(customLimits.maxRegexPatternLength)) should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .tooLong,
                "Iteration \(iteration): Pattern exceeding length should be rejected with .tooLong"
            )
            XCTAssertEqual(
                result.complexity.length,
                pattern.count,
                "Iteration \(iteration): Complexity should report actual pattern length"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: For any regex pattern with groups exceeding maxRegexGroups,
 /// the validator SHALL reject with .tooManyGroups reason.
    func testProperty5_GroupsLimitEnforcement() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate pattern exceeding groups limit by random amount
            let excessGroups = Int.random(in: 1...10)
            let pattern = RegexComplexityGenerator.generatePatternWithGroups(
                count: customLimits.maxRegexGroups + excessGroups
            )
            
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Pattern with \(customLimits.maxRegexGroups + excessGroups) groups (limit: \(customLimits.maxRegexGroups)) should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .tooManyGroups,
                "Iteration \(iteration): Pattern exceeding groups should be rejected with .tooManyGroups, got \(result.rejectionReason?.rawValue ?? "nil")"
            )
            XCTAssertGreaterThan(
                result.complexity.groups,
                customLimits.maxRegexGroups,
                "Iteration \(iteration): Complexity should report groups exceeding limit"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: For any regex pattern with quantifiers exceeding maxRegexQuantifiers,
 /// the validator SHALL reject with .tooManyQuantifiers reason.
    func testProperty5_QuantifiersLimitEnforcement() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate pattern exceeding quantifiers limit by random amount
            let excessQuantifiers = Int.random(in: 1...10)
            let pattern = RegexComplexityGenerator.generatePatternWithQuantifiers(
                count: customLimits.maxRegexQuantifiers + excessQuantifiers
            )
            
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Pattern with \(customLimits.maxRegexQuantifiers + excessQuantifiers) quantifiers (limit: \(customLimits.maxRegexQuantifiers)) should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .tooManyQuantifiers,
                "Iteration \(iteration): Pattern exceeding quantifiers should be rejected with .tooManyQuantifiers, got \(result.rejectionReason?.rawValue ?? "nil")"
            )
            XCTAssertGreaterThan(
                result.complexity.quantifiers,
                customLimits.maxRegexQuantifiers,
                "Iteration \(iteration): Complexity should report quantifiers exceeding limit"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: For any regex pattern with alternations exceeding maxRegexAlternations,
 /// the validator SHALL reject with .tooManyAlternations reason.
    func testProperty5_AlternationsLimitEnforcement() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate pattern exceeding alternations limit by random amount
            let excessAlternations = Int.random(in: 1...10)
            let pattern = RegexComplexityGenerator.generatePatternWithAlternations(
                count: customLimits.maxRegexAlternations + excessAlternations
            )
            
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Pattern with \(customLimits.maxRegexAlternations + excessAlternations) alternations (limit: \(customLimits.maxRegexAlternations)) should be rejected"
            )
            XCTAssertEqual(
                result.rejectionReason,
                .tooManyAlternations,
                "Iteration \(iteration): Pattern exceeding alternations should be rejected with .tooManyAlternations, got \(result.rejectionReason?.rawValue ?? "nil")"
            )
            XCTAssertGreaterThan(
                result.complexity.alternations,
                customLimits.maxRegexAlternations,
                "Iteration \(iteration): Complexity should report alternations exceeding limit"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: For any regex pattern with lookaheads exceeding maxRegexLookaheads,
 /// the validator SHALL reject with .tooManyLookaheads reason.
    func testProperty5_LookaheadsLimitEnforcement() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate pattern exceeding lookaheads limit by random amount
            let excessLookaheads = Int.random(in: 1...5)
            let pattern = RegexComplexityGenerator.generatePatternWithLookaheads(
                count: customLimits.maxRegexLookaheads + excessLookaheads
            )
            
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Iteration \(iteration): Pattern with \(customLimits.maxRegexLookaheads + excessLookaheads) lookaheads (limit: \(customLimits.maxRegexLookaheads)) should be rejected"
            )
            
 // Note: Lookaheads also count as groups, so we might get .tooManyGroups instead
 // if the lookahead count also exceeds the groups limit
            let acceptableReasons: Set<RegexValidationResult.RejectionReason> = [.tooManyLookaheads, .tooManyGroups]
            XCTAssertTrue(
                acceptableReasons.contains(result.rejectionReason ?? .invalidSyntax),
                "Iteration \(iteration): Pattern exceeding lookaheads should be rejected with .tooManyLookaheads or .tooManyGroups, got \(result.rejectionReason?.rawValue ?? "nil")"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: For any regex pattern within all complexity limits,
 /// the validator SHALL accept the pattern (assuming no dangerous constructs).
    func testProperty5_PatternsWithinLimitsAreAccepted() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
            let pattern = RegexComplexityGenerator.generateValidPattern(limits: customLimits)
            let result = await validator.validate(pattern: pattern)
            
 // Pattern should be valid since it's within all limits and has no dangerous constructs
            XCTAssertTrue(
                result.isValid,
                "Iteration \(iteration): Pattern '\(pattern)' within limits should be valid, got rejection: \(result.rejectionReason?.rawValue ?? "nil"), complexity: \(result.complexity)"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: For any exceeded limit type, the validator SHALL reject with the correct reason.
    func testProperty5_AllLimitTypesEnforced() async throws {
 // Test each limit type
        for limitType in RegexComplexityGenerator.ExceededLimit.allCases {
            let pattern = RegexComplexityGenerator.generatePatternExceeding(limitType, limits: customLimits)
            let result = await validator.validate(pattern: pattern)
            
            XCTAssertFalse(
                result.isValid,
                "Pattern exceeding \(limitType) should be rejected"
            )
            
 // For lookaheads, we might get .tooManyGroups since lookaheads count as groups
            if limitType == .lookaheads {
                let acceptableReasons: Set<RegexValidationResult.RejectionReason> = [.tooManyLookaheads, .tooManyGroups]
                XCTAssertTrue(
                    acceptableReasons.contains(result.rejectionReason ?? .invalidSyntax),
                    "Pattern exceeding \(limitType) should be rejected with \(limitType.expectedRejectionReason) or .tooManyGroups, got \(result.rejectionReason?.rawValue ?? "nil")"
                )
            } else {
                XCTAssertEqual(
                    result.rejectionReason,
                    limitType.expectedRejectionReason,
                    "Pattern exceeding \(limitType) should be rejected with \(limitType.expectedRejectionReason), got \(result.rejectionReason?.rawValue ?? "nil")"
                )
            }
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: Patterns at exactly the limit boundary should be accepted.
    func testProperty5_BoundaryPatternsAccepted() async throws {
 // Test patterns at exactly the limit (not exceeding)
        
 // Exactly at length limit
        let lengthPattern = RegexComplexityGenerator.generatePatternWithLength(customLimits.maxRegexPatternLength)
        let lengthResult = await validator.validate(pattern: lengthPattern)
        XCTAssertTrue(lengthResult.isValid, "Pattern at exact length limit should be valid")
        
 // Exactly at groups limit
        let groupsPattern = RegexComplexityGenerator.generatePatternWithGroups(count: customLimits.maxRegexGroups)
        let groupsResult = await validator.validate(pattern: groupsPattern)
        XCTAssertTrue(groupsResult.isValid, "Pattern at exact groups limit should be valid, got: \(groupsResult.rejectionReason?.rawValue ?? "nil")")
        
 // Exactly at quantifiers limit
        let quantifiersPattern = RegexComplexityGenerator.generatePatternWithQuantifiers(count: customLimits.maxRegexQuantifiers)
        let quantifiersResult = await validator.validate(pattern: quantifiersPattern)
        XCTAssertTrue(quantifiersResult.isValid, "Pattern at exact quantifiers limit should be valid, got: \(quantifiersResult.rejectionReason?.rawValue ?? "nil")")
        
 // Exactly at alternations limit
        let alternationsPattern = RegexComplexityGenerator.generatePatternWithAlternations(count: customLimits.maxRegexAlternations)
        let alternationsResult = await validator.validate(pattern: alternationsPattern)
        XCTAssertTrue(alternationsResult.isValid, "Pattern at exact alternations limit should be valid, got: \(alternationsResult.rejectionReason?.rawValue ?? "nil")")
        
 // Exactly at lookaheads limit
        let lookaheadsPattern = RegexComplexityGenerator.generatePatternWithLookaheads(count: customLimits.maxRegexLookaheads)
        let lookaheadsResult = await validator.validate(pattern: lookaheadsPattern)
        XCTAssertTrue(lookaheadsResult.isValid, "Pattern at exact lookaheads limit should be valid, got: \(lookaheadsResult.rejectionReason?.rawValue ?? "nil")")
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: Complexity metrics are accurately reported for all patterns.
    func testProperty5_ComplexityMetricsAccuracy() async throws {
        let iterations = 50
        
        for iteration in 0..<iterations {
 // Generate patterns with known complexity
            let groupCount = Int.random(in: 0...customLimits.maxRegexGroups)
            let quantifierCount = Int.random(in: 0...customLimits.maxRegexQuantifiers)
            let alternationCount = Int.random(in: 0...customLimits.maxRegexAlternations)
            
 // Test groups counting
            let groupsPattern = RegexComplexityGenerator.generatePatternWithGroups(count: groupCount)
            let groupsResult = await validator.validate(pattern: groupsPattern)
            XCTAssertEqual(
                groupsResult.complexity.groups,
                groupCount,
                "Iteration \(iteration): Groups count should be \(groupCount), got \(groupsResult.complexity.groups)"
            )
            
 // Test quantifiers counting
            let quantifiersPattern = RegexComplexityGenerator.generatePatternWithQuantifiers(count: quantifierCount)
            let quantifiersResult = await validator.validate(pattern: quantifiersPattern)
            XCTAssertEqual(
                quantifiersResult.complexity.quantifiers,
                quantifierCount,
                "Iteration \(iteration): Quantifiers count should be \(quantifierCount), got \(quantifiersResult.complexity.quantifiers)"
            )
            
 // Test alternations counting
            let alternationsPattern = RegexComplexityGenerator.generatePatternWithAlternations(count: alternationCount)
            let alternationsResult = await validator.validate(pattern: alternationsPattern)
            XCTAssertEqual(
                alternationsResult.complexity.alternations,
                alternationCount,
                "Iteration \(iteration): Alternations count should be \(alternationCount), got \(alternationsResult.complexity.alternations)"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 5: Regex complexity limits enforcement**
 /// **Validates: Requirements 2.4, 2.5, 2.8**
 ///
 /// Property: Length limit is checked first (fast path) before tokenization.
    func testProperty5_LengthCheckIsFirstPriority() async throws {
 // Create a pattern that exceeds length AND has dangerous constructs
 // Length check should reject it before detecting dangerous constructs
        let longDangerousPattern = String(repeating: "(a+)+", count: 50) // Nested quantifiers, but very long
        
 // Ensure it exceeds length limit
        XCTAssertGreaterThan(longDangerousPattern.count, customLimits.maxRegexPatternLength)
        
        let result = await validator.validate(pattern: longDangerousPattern)
        
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(
            result.rejectionReason,
            .tooLong,
            "Length limit should be checked first, got \(result.rejectionReason?.rawValue ?? "nil")"
        )
    }
}

// MARK: - Pattern Counter Tests

final class RegexPatternCounterTests: XCTestCase {
    
    func testCanValidateMoreInitially() async {
        let counter = RegexPatternCounter(maxCount: 100)
        let canValidate = await counter.canValidateMore()
        XCTAssertTrue(canValidate)
    }
    
    func testCannotValidateMoreAfterLimit() async {
        let counter = RegexPatternCounter(maxCount: 2)
        await counter.incrementCount()
        await counter.incrementCount()
        let canValidate = await counter.canValidateMore()
        XCTAssertFalse(canValidate)
    }
    
    func testResetCounter() async {
        let counter = RegexPatternCounter(maxCount: 2)
        await counter.incrementCount()
        await counter.incrementCount()
        await counter.reset()
        let canValidate = await counter.canValidateMore()
        XCTAssertTrue(canValidate)
    }
    
    func testCurrentCount() async {
        let counter = RegexPatternCounter(maxCount: 100)
        await counter.incrementCount()
        await counter.incrementCount()
        await counter.incrementCount()
        let count = await counter.currentCount
        XCTAssertEqual(count, 3)
    }
}


// MARK: - Property Test: Regex Graceful Degradation
// **Feature: security-hardening, Property 6: Regex graceful degradation**
// **Validates: Requirements 2.6, 2.7**

/// Test data generator for mixed valid/invalid pattern databases
enum RegexGracefulDegradationGenerator {
    
 /// Generate a valid regex pattern (safe, within limits)
    static func generateValidPattern() -> String {
        let validPatterns = [
            "abc",
            "\\d+",
            "[a-z]+",
            "test\\d{2,4}",
            "^start",
            "end$",
            "a|b|c",
            "(group)",
            "(?:non-capture)",
            "(?=lookahead)",
            "(?!negative)",
            "[A-Za-z0-9_]+",
            "\\w+@\\w+\\.\\w+",
            "file\\.txt",
            "path/to/file",
        ]
        return validPatterns.randomElement()!
    }
    
 /// Generate an invalid regex pattern (dangerous construct)
    static func generateInvalidPattern() -> (pattern: String, reason: RegexValidationResult.RejectionReason) {
        let invalidPatterns: [(String, RegexValidationResult.RejectionReason)] = [
            ("(a+)+", .nestedQuantifiers),
            ("(b*)*", .nestedQuantifiers),
            ("(c+)*", .nestedQuantifiers),
            ("(a)\\1", .backreference),
            ("(b)(c)\\2", .backreference),
            ("(?<=a)b", .lookbehind),
            ("(?<!x)y", .lookbehind),
            ("(?i)abc", .inlineFlags),
            ("(?m)test", .inlineFlags),
            ("(?<name>abc)", .namedCapture),
            ("(?P<id>\\d+)", .namedCapture),
        ]
        return invalidPatterns.randomElement()!
    }
    
 /// Generate a mixed database with specified counts
 /// - Parameters:
 /// - validCount: Number of valid patterns
 /// - invalidCount: Number of invalid patterns
 /// - Returns: Array of (patternId, pattern, isValid, expectedReason)
    static func generateMixedPatternDatabase(
        validCount: Int,
        invalidCount: Int
    ) -> [(id: String, pattern: String, isValid: Bool, reason: RegexValidationResult.RejectionReason?)] {
        var patterns: [(id: String, pattern: String, isValid: Bool, reason: RegexValidationResult.RejectionReason?)] = []
        
 // Add valid patterns
        for i in 0..<validCount {
            let pattern = generateValidPattern()
            patterns.append((id: "valid-\(i)", pattern: pattern, isValid: true, reason: nil))
        }
        
 // Add invalid patterns
        for i in 0..<invalidCount {
            let (pattern, reason) = generateInvalidPattern()
            patterns.append((id: "invalid-\(i)", pattern: pattern, isValid: false, reason: reason))
        }
        
 // Shuffle to mix valid and invalid patterns
        patterns.shuffle()
        
        return patterns
    }
}

/// Simulates a pattern database processor that uses RegexValidator for graceful degradation
actor PatternDatabaseProcessor {
    private let validator: RegexValidator
    private var processedValidPatterns: [String] = []
    private var rejectedPatterns: [(id: String, reason: RegexValidationResult.RejectionReason)] = []
    private var emittedWarnings: [String] = []
    
    init(limits: SecurityLimits = .default) {
        self.validator = RegexValidator(limits: limits)
    }
    
 /// Process a database of patterns, validating each one
 /// Returns: (validPatterns, rejectedPatterns, warnings)
    func processPatternDatabase(
        patterns: [(id: String, pattern: String)]
    ) async -> (valid: [String], rejected: [(id: String, reason: RegexValidationResult.RejectionReason)], warnings: [String]) {
        processedValidPatterns = []
        rejectedPatterns = []
        emittedWarnings = []
        
        for (id, pattern) in patterns {
            let result = await validator.validate(pattern: pattern)
            
            if result.isValid {
 // Pattern is valid - add to processed list
                processedValidPatterns.append(pattern)
            } else if let reason = result.rejectionReason {
 // Pattern is invalid - record rejection and emit warning
                rejectedPatterns.append((id: id, reason: reason))
                emittedWarnings.append("Pattern '\(id)' rejected: \(reason.rawValue)")
            }
        }
        
        return (processedValidPatterns, rejectedPatterns, emittedWarnings)
    }
    
 /// Check if processing completed without throwing
    func didCompleteWithoutFailure() -> Bool {
 // If we got here, processing completed
        return true
    }
}

/// Property-based tests for regex graceful degradation
final class RegexGracefulDegradationTests: XCTestCase {
    
    var validator: RegexValidator!
    
    override func setUp() async throws {
        try await super.setUp()
        validator = RegexValidator(limits: .default)
    }
    
    override func tearDown() async throws {
        validator = nil
        try await super.tearDown()
    }
    
 // MARK: - Property 6: Regex Graceful Degradation
    
 /// **Feature: security-hardening, Property 6: Regex graceful degradation**
 /// **Validates: Requirements 2.6, 2.7**
 ///
 /// Property: For any signature database with mixed valid/invalid patterns,
 /// the matcher SHALL process all valid patterns and emit warnings for invalid ones
 /// without failing entirely.
 ///
 /// This test verifies:
 /// 1. All valid patterns are processed successfully
 /// 2. Invalid patterns are rejected with appropriate reasons
 /// 3. Warnings are emitted for each rejected pattern
 /// 4. Processing does not fail/throw due to invalid patterns
    func testProperty6_GracefulDegradationWithMixedPatterns() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random counts of valid and invalid patterns
            let validCount = Int.random(in: 1...20)
            let invalidCount = Int.random(in: 1...10)
            
            let database = RegexGracefulDegradationGenerator.generateMixedPatternDatabase(
                validCount: validCount,
                invalidCount: invalidCount
            )
            
            let processor = PatternDatabaseProcessor()
            let patterns = database.map { (id: $0.id, pattern: $0.pattern) }
            
 // Process should complete without throwing
            let (validPatterns, rejectedPatterns, warnings) = await processor.processPatternDatabase(patterns: patterns)
            
 // Property 1: All valid patterns should be processed
            let expectedValidCount = database.filter { $0.isValid }.count
            XCTAssertEqual(
                validPatterns.count,
                expectedValidCount,
                "Iteration \(iteration): Expected \(expectedValidCount) valid patterns, got \(validPatterns.count)"
            )
            
 // Property 2: All invalid patterns should be rejected
            let expectedInvalidCount = database.filter { !$0.isValid }.count
            XCTAssertEqual(
                rejectedPatterns.count,
                expectedInvalidCount,
                "Iteration \(iteration): Expected \(expectedInvalidCount) rejected patterns, got \(rejectedPatterns.count)"
            )
            
 // Property 3: Warnings should be emitted for each rejected pattern
            XCTAssertEqual(
                warnings.count,
                expectedInvalidCount,
                "Iteration \(iteration): Expected \(expectedInvalidCount) warnings, got \(warnings.count)"
            )
            
 // Property 4: Processing completed (implicit - we reached this point)
            let didComplete = await processor.didCompleteWithoutFailure()
            XCTAssertTrue(
                didComplete,
                "Iteration \(iteration): Processing should complete without failure"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 6: Regex graceful degradation**
 /// **Validates: Requirements 2.6, 2.7**
 ///
 /// Property: When all patterns are invalid, processing should still complete
 /// with zero valid patterns and appropriate warnings for all.
    func testProperty6_AllInvalidPatternsStillCompletes() async throws {
        let iterations = 50
        
        for iteration in 0..<iterations {
            let invalidCount = Int.random(in: 5...20)
            
            let database = RegexGracefulDegradationGenerator.generateMixedPatternDatabase(
                validCount: 0,
                invalidCount: invalidCount
            )
            
            let processor = PatternDatabaseProcessor()
            let patterns = database.map { (id: $0.id, pattern: $0.pattern) }
            
            let (validPatterns, rejectedPatterns, warnings) = await processor.processPatternDatabase(patterns: patterns)
            
 // No valid patterns
            XCTAssertEqual(
                validPatterns.count,
                0,
                "Iteration \(iteration): Expected 0 valid patterns when all are invalid"
            )
            
 // All patterns rejected
            XCTAssertEqual(
                rejectedPatterns.count,
                invalidCount,
                "Iteration \(iteration): All \(invalidCount) patterns should be rejected"
            )
            
 // Warnings for all
            XCTAssertEqual(
                warnings.count,
                invalidCount,
                "Iteration \(iteration): Should have \(invalidCount) warnings"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 6: Regex graceful degradation**
 /// **Validates: Requirements 2.6, 2.7**
 ///
 /// Property: When all patterns are valid, processing should complete
 /// with all patterns processed and no warnings.
    func testProperty6_AllValidPatternsProcessed() async throws {
        let iterations = 50
        
        for iteration in 0..<iterations {
            let validCount = Int.random(in: 5...20)
            
            let database = RegexGracefulDegradationGenerator.generateMixedPatternDatabase(
                validCount: validCount,
                invalidCount: 0
            )
            
            let processor = PatternDatabaseProcessor()
            let patterns = database.map { (id: $0.id, pattern: $0.pattern) }
            
            let (validPatterns, rejectedPatterns, warnings) = await processor.processPatternDatabase(patterns: patterns)
            
 // All patterns valid
            XCTAssertEqual(
                validPatterns.count,
                validCount,
                "Iteration \(iteration): All \(validCount) patterns should be valid"
            )
            
 // No rejections
            XCTAssertEqual(
                rejectedPatterns.count,
                0,
                "Iteration \(iteration): Expected 0 rejected patterns"
            )
            
 // No warnings
            XCTAssertEqual(
                warnings.count,
                0,
                "Iteration \(iteration): Expected 0 warnings"
            )
        }
    }
    
 /// **Feature: security-hardening, Property 6: Regex graceful degradation**
 /// **Validates: Requirements 2.6, 2.7**
 ///
 /// Property: Rejection reasons are correctly identified for each invalid pattern type.
    func testProperty6_RejectionReasonsAreCorrect() async throws {
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate a database with known invalid patterns
            let database = RegexGracefulDegradationGenerator.generateMixedPatternDatabase(
                validCount: Int.random(in: 0...5),
                invalidCount: Int.random(in: 1...10)
            )
            
 // Validate each pattern individually and check reasons
            for entry in database {
                let result = await validator.validate(pattern: entry.pattern)
                
                if entry.isValid {
                    XCTAssertTrue(
                        result.isValid,
                        "Iteration \(iteration): Pattern '\(entry.pattern)' should be valid"
                    )
                } else {
                    XCTAssertFalse(
                        result.isValid,
                        "Iteration \(iteration): Pattern '\(entry.pattern)' should be invalid"
                    )
                    XCTAssertEqual(
                        result.rejectionReason,
                        entry.reason,
                        "Iteration \(iteration): Pattern '\(entry.pattern)' should be rejected with \(entry.reason?.rawValue ?? "nil"), got \(result.rejectionReason?.rawValue ?? "nil")"
                    )
                }
            }
        }
    }
    
 /// **Feature: security-hardening, Property 6: Regex graceful degradation**
 /// **Validates: Requirements 2.6, 2.7**
 ///
 /// Property: Order of patterns does not affect graceful degradation behavior.
 /// Invalid patterns at any position should not prevent processing of subsequent valid patterns.
    func testProperty6_OrderIndependence() async throws {
        let iterations = 50
        
        for iteration in 0..<iterations {
 // Create a fixed set of patterns
            let validPatterns = (0..<5).map { _ in RegexGracefulDegradationGenerator.generateValidPattern() }
            let invalidPatterns = (0..<3).map { _ in RegexGracefulDegradationGenerator.generateInvalidPattern() }
            
 // Test different orderings
            let orderings: [[(id: String, pattern: String)]] = [
 // Invalid first, then valid
                invalidPatterns.enumerated().map { (id: "inv-\($0.offset)", pattern: $0.element.pattern) } +
                validPatterns.enumerated().map { (id: "val-\($0.offset)", pattern: $0.element) },
                
 // Valid first, then invalid
                validPatterns.enumerated().map { (id: "val-\($0.offset)", pattern: $0.element) } +
                invalidPatterns.enumerated().map { (id: "inv-\($0.offset)", pattern: $0.element.pattern) },
                
 // Interleaved
                zip(validPatterns.enumerated(), invalidPatterns.enumerated()).flatMap { valid, invalid in
                    [(id: "val-\(valid.offset)", pattern: valid.element),
                     (id: "inv-\(invalid.offset)", pattern: invalid.element.pattern)]
                } + validPatterns.dropFirst(invalidPatterns.count).enumerated().map { (id: "val-extra-\($0.offset)", pattern: $0.element) }
            ]
            
            for (orderIndex, patterns) in orderings.enumerated() {
                let processor = PatternDatabaseProcessor()
                let (validResults, rejectedResults, _) = await processor.processPatternDatabase(patterns: patterns)
                
 // Count expected valid patterns in this ordering
                let expectedValidCount = patterns.filter { entry in
                    validPatterns.contains(entry.pattern)
                }.count
                
                XCTAssertEqual(
                    validResults.count,
                    expectedValidCount,
                    "Iteration \(iteration), Order \(orderIndex): Valid pattern count should be \(expectedValidCount)"
                )
                
 // Count expected invalid patterns
                let expectedInvalidCount = patterns.filter { entry in
                    invalidPatterns.contains { $0.pattern == entry.pattern }
                }.count
                
                XCTAssertEqual(
                    rejectedResults.count,
                    expectedInvalidCount,
                    "Iteration \(iteration), Order \(orderIndex): Rejected pattern count should be \(expectedInvalidCount)"
                )
            }
        }
    }
    
 /// **Feature: security-hardening, Property 6: Regex graceful degradation**
 /// **Validates: Requirements 2.6, 2.7**
 ///
 /// Property: Empty database is handled gracefully.
    func testProperty6_EmptyDatabaseHandledGracefully() async throws {
        let processor = PatternDatabaseProcessor()
        let (validPatterns, rejectedPatterns, warnings) = await processor.processPatternDatabase(patterns: [])
        
        XCTAssertEqual(validPatterns.count, 0, "Empty database should have 0 valid patterns")
        XCTAssertEqual(rejectedPatterns.count, 0, "Empty database should have 0 rejected patterns")
        XCTAssertEqual(warnings.count, 0, "Empty database should have 0 warnings")
    }
    
 /// **Feature: security-hardening, Property 6: Regex graceful degradation**
 /// **Validates: Requirements 2.6, 2.7**
 ///
 /// Property: Pattern count limit (Requirement 2.6) triggers graceful degradation.
 /// When pattern count exceeds maxRegexPatternCount, additional patterns should be
 /// rejected with a warning, not cause a failure.
    func testProperty6_PatternCountLimitGracefulDegradation() async throws {
 // Use custom limits with small pattern count for testing
        let customLimits = SecurityLimits(
            maxTotalFiles: 10_000,
            maxTotalBytes: 50 * 1024 * 1024 * 1024,
            globalTimeout: 300.0,
            maxRegexPatternLength: 1000,
            maxRegexPatternCount: 5,  // Small limit for testing
            maxRegexGroups: 10,
            maxRegexQuantifiers: 20,
            maxRegexAlternations: 10,
            maxRegexLookaheads: 3,
            perPatternTimeout: 0.05,
            perPatternInputLimit: 1024 * 1024,
            maxTotalHistoryBytes: 10 * 1024 * 1024,
            tokenBucketRate: 100.0,
            tokenBucketBurst: 200,
            maxMessageBytes: 64 * 1024,
            decodeDepthLimit: 10,
            decodeArrayLengthLimit: 1000,
            decodeStringLengthLimit: 64 * 1024,
            droppedMessagesThreshold: 500,
            droppedMessagesWindow: 10.0,
            pakeRecordTTL: 600.0,
            pakeMaxRecords: 10_000,
            pakeCleanupInterval: 128,
            maxSymlinkDepth: 10,
            maxRetryCount: 20,
            maxRetryDelay: 300.0,
            maxExtractedFiles: 1000,
            maxTotalExtractedBytes: 500 * 1024 * 1024,
            maxNestingDepth: 3,
            maxCompressionRatio: 100.0,
            maxExtractionTime: 10.0,
            maxBytesPerFile: 100 * 1024 * 1024,
            largeFileThreshold: 500 * 1024 * 1024,
            hashTimeoutQuick: 2.0,
            hashTimeoutStandard: 5.0,
            hashTimeoutDeep: 10.0,
            maxEventQueueSize: 10_000,
            maxPendingPerSubscriber: 1_000
        )
        
        let counter = RegexPatternCounter(maxCount: customLimits.maxRegexPatternCount)
        let validator = RegexValidator(limits: customLimits)
        
 // Generate more patterns than the limit
        let patternCount = 10  // More than limit of 5
        var validatedCount = 0
        var skippedCount = 0
        
        for i in 0..<patternCount {
            let pattern = "test\(i)"
            
 // Check if we can validate more
            if await counter.canValidateMore() {
                let result = await validator.validate(pattern: pattern)
                if result.isValid {
                    await counter.incrementCount()
                    validatedCount += 1
                }
            } else {
 // Pattern count limit reached - skip with warning
                skippedCount += 1
            }
        }
        
 // Should have validated up to the limit
        XCTAssertEqual(
            validatedCount,
            customLimits.maxRegexPatternCount,
            "Should validate exactly \(customLimits.maxRegexPatternCount) patterns"
        )
        
 // Remaining patterns should be skipped
        XCTAssertEqual(
            skippedCount,
            patternCount - customLimits.maxRegexPatternCount,
            "Should skip \(patternCount - customLimits.maxRegexPatternCount) patterns"
        )
        
 // Counter should be at limit
        let currentCount = await counter.currentCount
        XCTAssertEqual(
            currentCount,
            customLimits.maxRegexPatternCount,
            "Counter should be at limit"
        )
    }
}
