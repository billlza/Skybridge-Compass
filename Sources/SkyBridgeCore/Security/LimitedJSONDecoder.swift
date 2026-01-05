// MARK: - LimitedJSONDecoder.swift
// SkyBridge Compass - Security Hardening
// Copyright © 2024 SkyBridge. All rights reserved.

import Foundation

// MARK: - DecoderLimits

/// Limits for JSON/CBOR decoding to prevent DoS attacks.
///
/// This struct defines limits for:
/// - Maximum nesting depth
/// - Maximum array length
/// - Maximum string length
///
/// Note: maxNumberDigits is intentionally NOT included.
/// Reason: In the "JSONSerialization then DFS" path, counting digits precisely is not cost-effective.
/// JSONSerialization already parses numbers into NSNumber, and the original text is not accessible.
/// Number size is indirectly limited by maxMessageBytes + maxStringLength.
/// If precise digit limiting is needed in the future, a custom JSON tokenizer would be required (high cost).
///
/// - Requirements: 4.4
public struct DecoderLimits: Sendable, Equatable {
    
 /// Maximum nesting depth for JSON objects/arrays (default: 10)
    public let maxDepth: Int
    
 /// Maximum length for any single array (default: 1000)
    public let maxArrayLength: Int
    
 /// Maximum length for any single string in bytes (default: 64KB)
    public let maxStringLength: Int
    
 /// Default limits matching SecurityLimits.default
    public static let `default` = DecoderLimits(
        maxDepth: 10,
        maxArrayLength: 1000,
        maxStringLength: 64 * 1024  // 64KB
    )
    
 /// Initialize with custom limits
    public init(maxDepth: Int, maxArrayLength: Int, maxStringLength: Int) {
        self.maxDepth = maxDepth
        self.maxArrayLength = maxArrayLength
        self.maxStringLength = maxStringLength
    }
    
 /// Initialize from SecurityLimits
    public init(from limits: SecurityLimits) {
        self.maxDepth = limits.decodeDepthLimit
        self.maxArrayLength = limits.decodeArrayLengthLimit
        self.maxStringLength = limits.decodeStringLengthLimit
    }
}

// MARK: - LimitedJSONDecoder

/// A JSON decoder that enforces security limits to prevent DoS attacks.
///
/// This decoder implements a two- decode with size check first:
/// 1. FIRST: Check data.count <= maxMessageBytes
/// - If exceeded, immediately throw .messageTooLarge without any parsing
/// - This prevents large payloads from exhausting memory during JSONSerialization
/// 2. THEN: Use JSONSerialization.jsonObject for DFS validation
/// 3. FINALLY: Use JSONDecoder for final decode to target type
///
/// - Requirements: 4.3, 4.4, 4.5
public struct LimitedJSONDecoder: Sendable {
    
 /// Decoder limits for depth, array length, string length
    private let limits: DecoderLimits
    
 /// Maximum message size in bytes (must be checked BEFORE parsing)
    private let maxMessageBytes: Int
    
 /// Initialize with limits
    public init(limits: DecoderLimits = .default, maxMessageBytes: Int = 64 * 1024) {
        self.limits = limits
        self.maxMessageBytes = maxMessageBytes
    }
    
 /// Initialize from SecurityLimits
    public init(from securityLimits: SecurityLimits) {
        self.limits = DecoderLimits(from: securityLimits)
        self.maxMessageBytes = securityLimits.maxMessageBytes
    }
    
 // MARK: - Decoding Errors
    
 /// Errors that can occur during limited JSON decoding
    public enum DecodingError: Error, Equatable, Sendable {
 /// Message size exceeds maxMessageBytes (checked FIRST before any parsing)
        case messageTooLarge(actual: Int, max: Int)
        
 /// Nesting depth exceeds maxDepth
        case depthExceeded(actual: Int, max: Int)
        
 /// Array length exceeds maxArrayLength
        case arrayLengthExceeded(actual: Int, max: Int)
        
 /// String length exceeds maxStringLength
        case stringLengthExceeded(actual: Int, max: Int)
        
 /// JSON parsing failed
        case jsonParsingFailed(String)
        
 /// Final decode to target type failed
        case decodeFailed(String)
    }

    
 // MARK: - Public API
    
 /// Decode JSON data with security limits enforcement.
 ///
 /// Critical implementation order (must reject large payloads BEFORE parsing):
 /// 1. FIRST: Check data.count <= maxMessageBytes
 /// - If exceeded, immediately throw .messageTooLarge without any parsing
 /// - This prevents large payloads from exhausting memory during JSONSerialization
 /// 2. THEN: Use JSONSerialization.jsonObject to get Any tree
 /// 3. Manual DFS traversal to check depth/array length/string length
 /// 4. If any limit exceeded, throw corresponding DecodingError
 /// 5. After passing checks, use JSONDecoder to decode to target type
 ///
 /// Why order matters:
 /// - If JSONSerialization runs first, large payloads will exhaust memory
 /// - Depth/array length limits won't have a chance to take effect
 ///
 /// - Parameters:
 /// - type: The type to decode to
 /// - data: The JSON data to decode
 /// - Returns: The decoded value
 /// - Throws: DecodingError if any limit is exceeded or decoding fails
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
 // 1: Size check FIRST (before any parsing)
        guard data.count <= maxMessageBytes else {
            throw DecodingError.messageTooLarge(actual: data.count, max: maxMessageBytes)
        }
        
 // 2: Parse JSON for DFS validation
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw DecodingError.jsonParsingFailed(error.localizedDescription)
        }
        
 // 3: DFS validation of limits
        try validateLimits(jsonObject, currentDepth: 1)
        
 // 4: Final decode to target type
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(type, from: data)
        } catch {
            throw DecodingError.decodeFailed(error.localizedDescription)
        }
    }
    
 // MARK: - DFS Validation
    
 /// DFS traversal to check depth, array length, and string length limits.
 ///
 /// Checks:
 /// - depth: Current nesting level
 /// - array length: Number of elements in arrays
 /// - string length: Byte length of strings
 ///
 /// Note: Does NOT check number digits (see DecoderLimits documentation)
 ///
 /// - Parameters:
 /// - value: The JSON value to validate
 /// - currentDepth: Current nesting depth (starts at 1)
 /// - Throws: DecodingError if any limit is exceeded
    private func validateLimits(_ value: Any, currentDepth: Int) throws {
 // Check depth limit
        guard currentDepth <= limits.maxDepth else {
            throw DecodingError.depthExceeded(actual: currentDepth, max: limits.maxDepth)
        }
        
        switch value {
        case let dict as [String: Any]:
 // Validate dictionary keys (strings)
            for key in dict.keys {
                let keyLength = key.utf8.count
                guard keyLength <= limits.maxStringLength else {
                    throw DecodingError.stringLengthExceeded(actual: keyLength, max: limits.maxStringLength)
                }
            }
 // Recursively validate values
            for childValue in dict.values {
                try validateLimits(childValue, currentDepth: currentDepth + 1)
            }
            
        case let array as [Any]:
 // Check array length limit
            guard array.count <= limits.maxArrayLength else {
                throw DecodingError.arrayLengthExceeded(actual: array.count, max: limits.maxArrayLength)
            }
 // Recursively validate elements
            for element in array {
                try validateLimits(element, currentDepth: currentDepth + 1)
            }
            
        case let string as String:
 // Check string length limit
            let stringLength = string.utf8.count
            guard stringLength <= limits.maxStringLength else {
                throw DecodingError.stringLengthExceeded(actual: stringLength, max: limits.maxStringLength)
            }
            
        case is NSNumber, is NSNull:
 // Numbers and null are always valid (no digit counting per design decision)
            break
            
        default:
 // Unknown types are passed through (shouldn't happen with valid JSON)
            break
        }
    }
}

// MARK: - Convenience Extensions

extension LimitedJSONDecoder {
    
 /// Create a decoder for testing with custom limits
    public static func createForTesting(
        maxDepth: Int = 10,
        maxArrayLength: Int = 1000,
        maxStringLength: Int = 64 * 1024,
        maxMessageBytes: Int = 64 * 1024
    ) -> LimitedJSONDecoder {
        let limits = DecoderLimits(
            maxDepth: maxDepth,
            maxArrayLength: maxArrayLength,
            maxStringLength: maxStringLength
        )
        return LimitedJSONDecoder(limits: limits, maxMessageBytes: maxMessageBytes)
    }
}
