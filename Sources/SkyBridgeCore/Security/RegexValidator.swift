// MARK: - RegexValidator.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

// MARK: - RegexToken

/// Token types for regex pattern parsing.
/// Used by the tokenizer to identify regex constructs for validation.
internal enum RegexToken: Sendable, Equatable {
 /// A literal character
    case literal(Character)
    
 /// An escaped character (e.g., \d, \w, \+)
    case escaped(Character)
    
 /// A character class (e.g., [a-z], [^0-9])
    case characterClass(String)
    
 /// Start of a group - only (...) and (?:...) allowed
    case group(isCapturing: Bool)
    
 /// End of a group
    case groupEnd
    
 /// A quantifier character (*, +, ?, {)
    case quantifier(Character)
    
 /// Alternation operator (|)
    case alternation
    
 /// Positive lookahead (?=...) or negative lookahead (?!...)
    case lookahead(isPositive: Bool)
    
 /// Lookbehind - detected and rejected
    case lookbehind(isPositive: Bool)
    
 /// Backreference (e.g., \1, \2) - detected and rejected
    case backreference(Int)
    
 /// Inline flag (e.g., (?i), (?m)) - detected and rejected
    case inlineFlag(String)
    
 /// Named capture (e.g., (?<name>...)) - detected and rejected
    case namedCapture(String)
    
 /// Anchor (^, $)
    case anchor(Character)
    
 /// Dot (matches any character)
    case dot
}

// MARK: - RegexValidationResult

/// Result of regex pattern validation.
internal struct RegexValidationResult: Sendable {
 /// Whether the pattern is valid according to security rules
    let isValid: Bool
    
 /// Reason for rejection (if invalid)
    let rejectionReason: RejectionReason?
    
 /// Complexity metrics of the pattern
    let complexity: RegexComplexity
    
 /// Rejection reasons for regex patterns
    enum RejectionReason: String, Sendable, CaseIterable {
        case tooLong = "pattern_too_long"
        case nestedQuantifiers = "nested_quantifiers"
        case backreference = "backreference_detected"
        case lookbehind = "lookbehind_detected"
        case tooManyGroups = "too_many_groups"
        case tooManyQuantifiers = "too_many_quantifiers"
        case tooManyAlternations = "too_many_alternations"
        case tooManyLookaheads = "too_many_lookaheads"
        case inlineFlags = "inline_flags_detected"
        case namedCapture = "named_capture_detected"
        case invalidSyntax = "invalid_syntax"
    }
    
 /// Complexity metrics for a regex pattern
    struct RegexComplexity: Sendable, Equatable {
        let groups: Int
        let quantifiers: Int
        let alternations: Int
        let lookaheads: Int
        let length: Int
        
        static let zero = RegexComplexity(
            groups: 0,
            quantifiers: 0,
            alternations: 0,
            lookaheads: 0,
            length: 0
        )
    }
    
 /// Create a valid result
    static func valid(complexity: RegexComplexity) -> RegexValidationResult {
        RegexValidationResult(isValid: true, rejectionReason: nil, complexity: complexity)
    }
    
 /// Create an invalid result
    static func invalid(reason: RejectionReason, complexity: RegexComplexity) -> RegexValidationResult {
        RegexValidationResult(isValid: false, rejectionReason: reason, complexity: complexity)
    }
}

// MARK: - RegexValidator

/// Regex pattern security validator.
///
/// Validates regex patterns against a safe subset to prevent ReDoS attacks.
/// Implements a minimal parser that correctly handles escaping and character classes.
///
/// **Allowed syntax subset (all inline modifiers disabled):**
/// - Literals and escaped characters
/// - Character classes [...]
/// - Groups (...) and (?:...)
/// - Quantifiers *, +, ?, {n}, {n,}, {n,m}
/// - Alternation |
/// - Positive lookahead (?=...) and (?!...)
/// - Anchors ^, $
/// - Dot .
///
/// **Forbidden constructs:**
/// - Nested quantifiers (e.g., (a+)+)
/// - Backreferences (\1, \2, etc.)
/// - Lookbehind ((?<=...), (?<!...))
/// - Inline flags ((?i), (?m), (?s), (?x), etc.)
/// - Named captures ((?<name>...))
internal actor RegexValidator {
    
 // MARK: - Properties
    
    private let limits: SecurityLimits
    
 // MARK: - Initialization
    
    init(limits: SecurityLimits = .default) {
        self.limits = limits
    }
    
 // MARK: - Public API
    
 /// Validate a regex pattern against security rules.
 ///
 /// - Parameter pattern: The regex pattern string to validate
 /// - Returns: Validation result with validity, rejection reason, and complexity
    func validate(pattern: String) -> RegexValidationResult {
 // Check length first (fast path)
        if pattern.count > limits.maxRegexPatternLength {
            return .invalid(
                reason: .tooLong,
                complexity: RegexValidationResult.RegexComplexity(
                    groups: 0,
                    quantifiers: 0,
                    alternations: 0,
                    lookaheads: 0,
                    length: pattern.count
                )
            )
        }
        
 // Tokenize the pattern
        let tokens = tokenize(pattern)
        
 // Check for dangerous constructs
        if detectBackreferences(tokens) {
            return .invalid(reason: .backreference, complexity: computeComplexity(tokens, patternLength: pattern.count))
        }
        
        if detectLookbehind(tokens) {
            return .invalid(reason: .lookbehind, complexity: computeComplexity(tokens, patternLength: pattern.count))
        }
        
        if detectInlineFlags(tokens) {
            return .invalid(reason: .inlineFlags, complexity: computeComplexity(tokens, patternLength: pattern.count))
        }
        
        if detectNamedCaptures(tokens) {
            return .invalid(reason: .namedCapture, complexity: computeComplexity(tokens, patternLength: pattern.count))
        }
        
        if detectNestedQuantifiers(tokens) {
            return .invalid(reason: .nestedQuantifiers, complexity: computeComplexity(tokens, patternLength: pattern.count))
        }
        
 // Compute complexity
        let complexity = computeComplexity(tokens, patternLength: pattern.count)
        
 // Check complexity limits
        if complexity.groups > limits.maxRegexGroups {
            return .invalid(reason: .tooManyGroups, complexity: complexity)
        }
        
        if complexity.quantifiers > limits.maxRegexQuantifiers {
            return .invalid(reason: .tooManyQuantifiers, complexity: complexity)
        }
        
        if complexity.alternations > limits.maxRegexAlternations {
            return .invalid(reason: .tooManyAlternations, complexity: complexity)
        }
        
        if complexity.lookaheads > limits.maxRegexLookaheads {
            return .invalid(reason: .tooManyLookaheads, complexity: complexity)
        }
        
        return .valid(complexity: complexity)
    }
    
 /// Validate a pattern and emit security event if rejected.
 ///
 /// - Parameters:
 /// - pattern: The regex pattern string
 /// - patternId: Identifier for the pattern (for logging)
 /// - Returns: Validation result
    func validateAndEmit(pattern: String, patternId: String) async -> RegexValidationResult {
        let result = validate(pattern: pattern)
        
        if !result.isValid, let reason = result.rejectionReason {
            let event = SecurityEvent.regexPatternRejected(
                patternId: patternId,
                reason: reason.rawValue
            )
            await SecurityEventEmitter.shared.emit(event)
        }
        
        return result
    }
    
 // MARK: - Tokenization

    
 /// Tokenize a regex pattern into a stream of tokens.
 ///
 /// Handles escaping correctly:
 /// - \( \+ etc. are escaped characters, not special constructs
 /// - Character classes [...] are parsed as single tokens
 /// - Detects inline flags, named captures, lookahead/lookbehind
 ///
 /// - Parameter pattern: The regex pattern string
 /// - Returns: Array of tokens
    func tokenize(_ pattern: String) -> [RegexToken] {
        var tokens: [RegexToken] = []
        var index = pattern.startIndex
        
        while index < pattern.endIndex {
            let char = pattern[index]
            
            switch char {
            case "\\":
 // Escape sequence
                let nextIndex = pattern.index(after: index)
                if nextIndex < pattern.endIndex {
                    let nextChar = pattern[nextIndex]
                    
 // Check for backreference (\1 through \9)
                    if nextChar.isNumber, let digit = nextChar.wholeNumberValue, digit >= 1 && digit <= 9 {
                        tokens.append(.backreference(digit))
                    } else {
                        tokens.append(.escaped(nextChar))
                    }
                    index = pattern.index(after: nextIndex)
                } else {
 // Trailing backslash - treat as literal
                    tokens.append(.literal(char))
                    index = pattern.index(after: index)
                }
                
            case "[":
 // Character class
                let (classContent, endIndex) = parseCharacterClass(pattern, from: index)
                tokens.append(.characterClass(classContent))
                index = endIndex
                
            case "(":
 // Group or special construct
                let (groupTokens, endIndex) = parseGroupStart(pattern, from: index)
                tokens.append(contentsOf: groupTokens)
                index = endIndex
                
            case ")":
                tokens.append(.groupEnd)
                index = pattern.index(after: index)
                
            case "*", "+", "?":
                tokens.append(.quantifier(char))
                index = pattern.index(after: index)
                
            case "{":
 // Quantifier {n}, {n,}, {n,m}
                let (_, endIndex) = parseQuantifierBrace(pattern, from: index)
                tokens.append(.quantifier(char))
                index = endIndex
                
            case "|":
                tokens.append(.alternation)
                index = pattern.index(after: index)
                
            case "^", "$":
                tokens.append(.anchor(char))
                index = pattern.index(after: index)
                
            case ".":
                tokens.append(.dot)
                index = pattern.index(after: index)
                
            default:
                tokens.append(.literal(char))
                index = pattern.index(after: index)
            }
        }
        
        return tokens
    }
    
 // MARK: - Parsing Helpers
    
 /// Parse a character class [...] starting at the given index.
 ///
 /// - Parameters:
 /// - pattern: The full pattern string
 /// - from: Starting index (at '[')
 /// - Returns: Tuple of (class content, index after ']')
    private func parseCharacterClass(_ pattern: String, from startIndex: String.Index) -> (String, String.Index) {
        var content = ""
        var index = pattern.index(after: startIndex) // Skip '['
        var isEscaped = false
        
 // Handle negation
        if index < pattern.endIndex && pattern[index] == "^" {
            content.append("^")
            index = pattern.index(after: index)
        }
        
 // Handle ] as first character (literal)
        if index < pattern.endIndex && pattern[index] == "]" {
            content.append("]")
            index = pattern.index(after: index)
        }
        
        while index < pattern.endIndex {
            let char = pattern[index]
            
            if isEscaped {
                content.append(char)
                isEscaped = false
                index = pattern.index(after: index)
            } else if char == "\\" {
                content.append(char)
                isEscaped = true
                index = pattern.index(after: index)
            } else if char == "]" {
 // End of character class
                return (content, pattern.index(after: index))
            } else {
                content.append(char)
                index = pattern.index(after: index)
            }
        }
        
 // Unclosed character class - return what we have
        return (content, index)
    }
    
 /// Parse a group start, detecting special constructs.
 ///
 /// - Parameters:
 /// - pattern: The full pattern string
 /// - from: Starting index (at '(')
 /// - Returns: Tuple of (tokens, index after group start)
    private func parseGroupStart(_ pattern: String, from startIndex: String.Index) -> ([RegexToken], String.Index) {
        let nextIndex = pattern.index(after: startIndex)
        
 // Check for special group syntax
        if nextIndex < pattern.endIndex && pattern[nextIndex] == "?" {
            let afterQuestion = pattern.index(after: nextIndex)
            
            if afterQuestion < pattern.endIndex {
                let specialChar = pattern[afterQuestion]
                
                switch specialChar {
                case ":":
 // Non-capturing group (?:...)
                    return ([.group(isCapturing: false)], pattern.index(after: afterQuestion))
                    
                case "=":
 // Positive lookahead (?=...)
                    return ([.lookahead(isPositive: true)], pattern.index(after: afterQuestion))
                    
                case "!":
 // Negative lookahead (?!...)
                    return ([.lookahead(isPositive: false)], pattern.index(after: afterQuestion))
                    
                case "<":
 // Could be lookbehind or named capture
                    return parseLookbehindOrNamedCapture(pattern, from: afterQuestion)
                    
                case "i", "m", "s", "x", "u", "U", "-":
 // Inline flag
                    let (flag, endIndex) = parseInlineFlag(pattern, from: afterQuestion)
                    return ([.inlineFlag(flag)], endIndex)
                    
                case "P":
 // Python-style named capture (?P<name>...)
                    return parsePythonNamedCapture(pattern, from: afterQuestion)
                    
                default:
 // Unknown special construct - treat as capturing group
                    return ([.group(isCapturing: true)], nextIndex)
                }
            }
        }
        
 // Regular capturing group
        return ([.group(isCapturing: true)], nextIndex)
    }
    
 /// Parse lookbehind or named capture starting at '<'.
    private func parseLookbehindOrNamedCapture(_ pattern: String, from lessThanIndex: String.Index) -> ([RegexToken], String.Index) {
        let afterLessThan = pattern.index(after: lessThanIndex)
        
        if afterLessThan < pattern.endIndex {
            let char = pattern[afterLessThan]
            
            if char == "=" {
 // Positive lookbehind (?<=...)
                return ([.lookbehind(isPositive: true)], pattern.index(after: afterLessThan))
            } else if char == "!" {
 // Negative lookbehind (?<!...)
                return ([.lookbehind(isPositive: false)], pattern.index(after: afterLessThan))
            } else {
 // Named capture (?<name>...)
                let (name, endIndex) = parseNamedCaptureName(pattern, from: afterLessThan)
                return ([.namedCapture(name)], endIndex)
            }
        }
        
 // Malformed - treat as group
        return ([.group(isCapturing: true)], afterLessThan)
    }
    
 /// Parse Python-style named capture (?P<name>...).
    private func parsePythonNamedCapture(_ pattern: String, from pIndex: String.Index) -> ([RegexToken], String.Index) {
        let afterP = pattern.index(after: pIndex)
        
        if afterP < pattern.endIndex && pattern[afterP] == "<" {
            let afterLessThan = pattern.index(after: afterP)
            let (name, endIndex) = parseNamedCaptureName(pattern, from: afterLessThan)
            return ([.namedCapture(name)], endIndex)
        }
        
 // Not a named capture - treat as group
        return ([.group(isCapturing: true)], afterP)
    }
    
 /// Parse the name part of a named capture group.
    private func parseNamedCaptureName(_ pattern: String, from startIndex: String.Index) -> (String, String.Index) {
        var name = ""
        var index = startIndex
        
        while index < pattern.endIndex {
            let char = pattern[index]
            if char == ">" {
                return (name, pattern.index(after: index))
            }
            name.append(char)
            index = pattern.index(after: index)
        }
        
        return (name, index)
    }
    
 /// Parse inline flag sequence.
    private func parseInlineFlag(_ pattern: String, from startIndex: String.Index) -> (String, String.Index) {
        var flag = ""
        var index = startIndex
        
        while index < pattern.endIndex {
            let char = pattern[index]
 // Flags can be: i, m, s, x, u, U, or - for negation
            if char == "i" || char == "m" || char == "s" || char == "x" || char == "u" || char == "U" || char == "-" {
                flag.append(char)
                index = pattern.index(after: index)
            } else if char == ")" || char == ":" {
 // End of flag section
                break
            } else {
                break
            }
        }
        
        return (flag, index)
    }
    
 /// Parse quantifier brace {n}, {n,}, {n,m}.
    private func parseQuantifierBrace(_ pattern: String, from startIndex: String.Index) -> (String, String.Index) {
        var content = ""
        var index = pattern.index(after: startIndex) // Skip '{'
        
        while index < pattern.endIndex {
            let char = pattern[index]
            if char == "}" {
                return (content, pattern.index(after: index))
            }
            content.append(char)
            index = pattern.index(after: index)
        }
        
 // Unclosed brace
        return (content, index)
    }

    
 // MARK: - Dangerous Construct Detection
    
 /// Detect nested quantifiers (e.g., (a+)+, (a*)*).
 ///
 /// Nested quantifiers are a primary cause of ReDoS as they create
 /// exponential backtracking scenarios.
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: true if nested quantifiers detected
    func detectNestedQuantifiers(_ tokens: [RegexToken]) -> Bool {
 // Track group nesting and whether each group level has a quantifier
        var groupStack: [Bool] = [] // true if group contains quantifier
        var lastWasQuantifier = false
        
        for token in tokens {
            switch token {
            case .group, .lookahead:
 // Start of a group - push onto stack
                groupStack.append(false)
                lastWasQuantifier = false
                
            case .groupEnd:
 // End of group - check if group had quantifier
                let groupHadQuantifier = groupStack.popLast() ?? false
 // If the group had a quantifier inside, and we see another quantifier,
 // that's nested quantifiers
                if groupHadQuantifier {
 // Mark that we need to check for following quantifier
                    lastWasQuantifier = true
                } else {
                    lastWasQuantifier = false
                }
                
            case .quantifier:
 // Check for nested quantifier pattern
                if lastWasQuantifier {
 // Quantifier following a group that contained a quantifier
                    return true
                }
                
 // Mark current group level as having a quantifier
                if !groupStack.isEmpty {
                    groupStack[groupStack.count - 1] = true
                }
                
                lastWasQuantifier = false
                
            case .literal, .escaped, .characterClass, .dot:
                lastWasQuantifier = false
                
            case .alternation, .anchor:
                lastWasQuantifier = false
                
            case .backreference, .lookbehind, .inlineFlag, .namedCapture:
 // These are rejected separately
                lastWasQuantifier = false
            }
        }
        
        return false
    }
    
 /// Detect backreferences (\1, \2, etc.).
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: true if backreferences detected
    func detectBackreferences(_ tokens: [RegexToken]) -> Bool {
        for token in tokens {
            if case .backreference = token {
                return true
            }
        }
        return false
    }
    
 /// Detect lookbehind assertions ((?<=...), (?<!...)).
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: true if lookbehind detected
    func detectLookbehind(_ tokens: [RegexToken]) -> Bool {
        for token in tokens {
            if case .lookbehind = token {
                return true
            }
        }
        return false
    }
    
 /// Detect inline flags ((?i), (?m), etc.).
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: true if inline flags detected
    func detectInlineFlags(_ tokens: [RegexToken]) -> Bool {
        for token in tokens {
            if case .inlineFlag = token {
                return true
            }
        }
        return false
    }
    
 /// Detect named captures ((?<name>...), (?P<name>...)).
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: true if named captures detected
    func detectNamedCaptures(_ tokens: [RegexToken]) -> Bool {
        for token in tokens {
            if case .namedCapture = token {
                return true
            }
        }
        return false
    }
    
 // MARK: - Complexity Counting
    
 /// Count the number of groups (capturing and non-capturing).
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: Number of groups
    func countGroups(_ tokens: [RegexToken]) -> Int {
        var count = 0
        for token in tokens {
            switch token {
            case .group:
                count += 1
            case .lookahead:
 // Lookaheads are a type of group
                count += 1
            default:
                break
            }
        }
        return count
    }
    
 /// Count the number of quantifiers.
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: Number of quantifiers
    func countQuantifiers(_ tokens: [RegexToken]) -> Int {
        var count = 0
        for token in tokens {
            if case .quantifier = token {
                count += 1
            }
        }
        return count
    }
    
 /// Count the number of alternations (|).
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: Number of alternations
    func countAlternations(_ tokens: [RegexToken]) -> Int {
        var count = 0
        for token in tokens {
            if case .alternation = token {
                count += 1
            }
        }
        return count
    }
    
 /// Count the number of lookaheads.
 ///
 /// - Parameter tokens: The tokenized pattern
 /// - Returns: Number of lookaheads
    func countLookaheads(_ tokens: [RegexToken]) -> Int {
        var count = 0
        for token in tokens {
            if case .lookahead = token {
                count += 1
            }
        }
        return count
    }
    
 /// Compute overall complexity metrics.
 ///
 /// - Parameters:
 /// - tokens: The tokenized pattern
 /// - patternLength: Original pattern length
 /// - Returns: Complexity metrics
    private func computeComplexity(_ tokens: [RegexToken], patternLength: Int) -> RegexValidationResult.RegexComplexity {
        RegexValidationResult.RegexComplexity(
            groups: countGroups(tokens),
            quantifiers: countQuantifiers(tokens),
            alternations: countAlternations(tokens),
            lookaheads: countLookaheads(tokens),
            length: patternLength
        )
    }
}

// MARK: - Pattern Count Tracking

/// Tracks the number of validated patterns for enforcing maxRegexPatternCount.
internal actor RegexPatternCounter {
    private var validatedCount: Int = 0
    private let maxCount: Int
    
    init(maxCount: Int = SecurityLimits.default.maxRegexPatternCount) {
        self.maxCount = maxCount
    }
    
 /// Check if we can validate another pattern.
 ///
 /// - Returns: true if under limit, false if limit reached
    func canValidateMore() -> Bool {
        validatedCount < maxCount
    }
    
 /// Increment the validated count.
    func incrementCount() {
        validatedCount += 1
    }
    
 /// Get current count.
    var currentCount: Int {
        validatedCount
    }
    
 /// Reset the counter (for testing or new database load).
    func reset() {
        validatedCount = 0
    }
}

// MARK: - Testing Support

#if DEBUG
extension RegexValidator {
 /// Create a validator with custom limits for testing.
    static func createForTesting(limits: SecurityLimits) -> RegexValidator {
        RegexValidator(limits: limits)
    }
}

extension RegexValidationResult.RegexComplexity: CustomStringConvertible {
    var description: String {
        "Complexity(groups: \(groups), quantifiers: \(quantifiers), alternations: \(alternations), lookaheads: \(lookaheads), length: \(length))"
    }
}
#endif
