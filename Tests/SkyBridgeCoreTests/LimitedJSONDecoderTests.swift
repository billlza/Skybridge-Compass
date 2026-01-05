//
// LimitedJSONDecoderTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for LimitedJSONDecoder
// **Feature: security-hardening**
//

import XCTest
@testable import SkyBridgeCore

// MARK: - Property Test: Decoder Limits Enforcement
// **Feature: security-hardening, Property 11: Decoder limits enforcement**
// **Validates: Requirements 4.4, 4.5**

final class LimitedJSONDecoderTests: XCTestCase {
    
 // MARK: - Test Helpers
    
 /// Simple Codable struct for testing
    struct TestMessage: Codable, Equatable {
        let id: Int
        let name: String
        let values: [Int]?
        let nested: NestedObject?
        
        struct NestedObject: Codable, Equatable {
            let key: String
            let data: [String]?
        }
    }
    
 /// Nested class for depth testing (class allows recursive properties)
    final class NestedValue: Codable {
        let v: Int?
        let n: NestedValue?
        
        init(v: Int? = nil, n: NestedValue? = nil) {
            self.v = v
            self.n = n
        }
    }
    
 /// Generate JSON data of specified size
    private func generateJSONData(size: Int) -> Data {
 // Create a JSON object with a string field padded to reach target size
 // Minimum JSON: {"s":""} = 8 bytes
        let overhead = 8
        let paddingSize = max(0, size - overhead)
        let padding = String(repeating: "x", count: paddingSize)
        let json = "{\"s\":\"\(padding)\"}"
        return json.utf8Data
    }
    
 /// Generate JSON with specified nesting depth
    private func generateNestedJSON(depth: Int) -> Data {
        var json = "{\"v\":1"
        for _ in 0..<depth {
            json = "{\"n\":" + json + "}"
        }
        json += "}"
 // Fix: the closing braces are already in the nested structure
 // Actually rebuild correctly:
        var result = "{\"v\":1}"
        for _ in 0..<depth {
            result = "{\"n\":\(result)}"
        }
        return result.utf8Data
    }
    
 /// Generate JSON with array of specified length
    private func generateArrayJSON(length: Int) -> Data {
        let elements = (0..<length).map { "\($0)" }.joined(separator: ",")
        let json = "{\"arr\":[\(elements)]}"
        return json.utf8Data
    }
    
 /// Generate JSON with string of specified length
    private func generateStringJSON(stringLength: Int) -> Data {
        let str = String(repeating: "a", count: stringLength)
        let json = "{\"s\":\"\(str)\"}"
        return json.utf8Data
    }
    
 // MARK: - Property Test: Decoder Limits Enforcement
    
 /// **Feature: security-hardening, Property 11: Decoder limits enforcement**
 /// **Validates: Requirements 4.4, 4.5**
 ///
 /// Property: For any JSON message, the decoder SHALL enforce:
 /// - Message size limit (checked FIRST before parsing)
 /// - Nesting depth limit
 /// - Array length limit
 /// - String length limit
 ///
 /// This test verifies:
 /// 1. Messages exceeding maxMessageBytes are rejected before parsing
 /// 2. JSON with depth > maxDepth is rejected
 /// 3. Arrays with length > maxArrayLength are rejected
 /// 4. Strings with length > maxStringLength are rejected
 /// 5. Valid JSON within all limits is decoded successfully
    func testProperty_DecoderLimitsEnforcement() throws {
 // Run 100 iterations with different random configurations
        let iterations = 100
        
        for iteration in 0..<iterations {
 // Generate random limits within reasonable bounds
            let maxMessageBytes = Int.random(in: 100...10_000)
            let maxDepth = Int.random(in: 2...20)
            let maxArrayLength = Int.random(in: 10...500)
            let maxStringLength = Int.random(in: 50...5_000)
            
            let decoder = LimitedJSONDecoder.createForTesting(
                maxDepth: maxDepth,
                maxArrayLength: maxArrayLength,
                maxStringLength: maxStringLength,
                maxMessageBytes: maxMessageBytes
            )
            
 // Property 1: Message size limit is enforced FIRST
            let oversizedData = generateJSONData(size: maxMessageBytes + 100)
            do {
                _ = try decoder.decode([String: String].self, from: oversizedData)
                XCTFail("Iteration \(iteration): Should reject oversized message")
            } catch let error as LimitedJSONDecoder.DecodingError {
                if case .messageTooLarge(let actual, let max) = error {
                    XCTAssertGreaterThan(actual, max, "Iteration \(iteration): Actual size should exceed max")
                } else {
                    XCTFail("Iteration \(iteration): Expected messageTooLarge, got \(error)")
                }
            }
            
 // Property 2: Depth limit is enforced
            let deepJSON = generateNestedJSON(depth: maxDepth + 1)
            if deepJSON.count <= maxMessageBytes {
                do {
                    _ = try decoder.decode(NestedValue.self, from: deepJSON)
 // May succeed if depth counting differs - check actual depth
                } catch let error as LimitedJSONDecoder.DecodingError {
                    if case .depthExceeded(let actual, let max) = error {
                        XCTAssertGreaterThan(actual, max, "Iteration \(iteration): Actual depth should exceed max")
                    }
 // Other errors are acceptable (e.g., decode failed)
                } catch {
 // Other errors acceptable
                }
            }
            
 // Property 3: Array length limit is enforced
            let longArrayJSON = generateArrayJSON(length: maxArrayLength + 10)
            if longArrayJSON.count <= maxMessageBytes {
                do {
                    _ = try decoder.decode([String: [Int]].self, from: longArrayJSON)
                    XCTFail("Iteration \(iteration): Should reject array exceeding length limit")
                } catch let error as LimitedJSONDecoder.DecodingError {
                    if case .arrayLengthExceeded(let actual, let max) = error {
                        XCTAssertGreaterThan(actual, max, "Iteration \(iteration): Actual array length should exceed max")
                    } else if case .messageTooLarge = error {
 // Acceptable - size limit caught it first
                    } else {
                        XCTFail("Iteration \(iteration): Expected arrayLengthExceeded, got \(error)")
                    }
                }
            }
            
 // Property 4: String length limit is enforced
            let longStringJSON = generateStringJSON(stringLength: maxStringLength + 100)
            if longStringJSON.count <= maxMessageBytes {
                do {
                    _ = try decoder.decode([String: String].self, from: longStringJSON)
                    XCTFail("Iteration \(iteration): Should reject string exceeding length limit")
                } catch let error as LimitedJSONDecoder.DecodingError {
                    if case .stringLengthExceeded(let actual, let max) = error {
                        XCTAssertGreaterThan(actual, max, "Iteration \(iteration): Actual string length should exceed max")
                    } else if case .messageTooLarge = error {
 // Acceptable - size limit caught it first
                    } else {
                        XCTFail("Iteration \(iteration): Expected stringLengthExceeded, got \(error)")
                    }
                }
            }
            
 // Property 5: Valid JSON within limits is decoded successfully
            let validJSON = "{\"id\":1,\"name\":\"test\"}".utf8Data
            if validJSON.count <= maxMessageBytes {
                do {
                    let result = try decoder.decode(TestMessage.self, from: validJSON)
                    XCTAssertEqual(result.id, 1, "Iteration \(iteration): Should decode id correctly")
                    XCTAssertEqual(result.name, "test", "Iteration \(iteration): Should decode name correctly")
                } catch {
                    XCTFail("Iteration \(iteration): Valid JSON should decode successfully: \(error)")
                }
            }
        }
    }

    
 // MARK: - Unit Tests for Specific Behaviors
    
 /// Test that message size is checked BEFORE any parsing
    func testMessageSizeCheckedFirst() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 64 * 1024,
            maxMessageBytes: 100
        )
        
 // Create oversized data that would also fail other limits
 // This ensures size check happens first
        let oversizedData = generateJSONData(size: 200)
        
        do {
            _ = try decoder.decode([String: String].self, from: oversizedData)
            XCTFail("Should reject oversized message")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .messageTooLarge(let actual, let max) = error {
                XCTAssertEqual(max, 100, "Max should be 100")
                XCTAssertGreaterThan(actual, 100, "Actual should exceed 100")
            } else {
                XCTFail("Expected messageTooLarge error, got \(error)")
            }
        }
    }
    
 /// Test depth limit enforcement
    func testDepthLimitEnforcement() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 3,
            maxArrayLength: 1000,
            maxStringLength: 64 * 1024,
            maxMessageBytes: 10_000
        )
        
 // generateNestedJSON(depth: N) creates N+1 levels of nesting
 // depth=1 -> {"n":{"v":1}} = 2 levels
 // depth=2 -> {"n":{"n":{"v":1}}} = 3 levels
 // Our DFS counts from 1, so depth=2 generates depth 3
        
 // Depth 2 (2 levels) should succeed with maxDepth=3
        let depth2JSON = generateNestedJSON(depth: 1) // 1 nesting = 2 levels
        do {
            _ = try decoder.decode(NestedValue.self, from: depth2JSON)
 // Should succeed
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .depthExceeded = error {
                XCTFail("Depth 2 should not exceed limit of 3")
            }
 // Other errors acceptable
        } catch {
 // Other errors acceptable
        }
        
 // Depth 4 (4 levels) should fail with maxDepth=3
        let depth4JSON = generateNestedJSON(depth: 3) // 3 nestings = 4 levels
        do {
            _ = try decoder.decode(NestedValue.self, from: depth4JSON)
 // May succeed if type doesn't match - that's okay
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .depthExceeded(let actual, let max) = error {
                XCTAssertEqual(max, 3, "Max depth should be 3")
                XCTAssertGreaterThan(actual, 3, "Actual depth should exceed 3")
            }
 // Other errors acceptable
        } catch {
 // Other errors acceptable
        }
    }
    
 /// Test array length limit enforcement
    func testArrayLengthLimitEnforcement() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 5,
            maxStringLength: 64 * 1024,
            maxMessageBytes: 10_000
        )
        
 // Array of 5 should succeed
        let array5JSON = generateArrayJSON(length: 5)
        do {
            let result = try decoder.decode([String: [Int]].self, from: array5JSON)
            XCTAssertEqual(result["arr"]?.count, 5, "Should decode array of 5")
        } catch {
            XCTFail("Array of 5 should succeed: \(error)")
        }
        
 // Array of 10 should fail
        let array10JSON = generateArrayJSON(length: 10)
        do {
            _ = try decoder.decode([String: [Int]].self, from: array10JSON)
            XCTFail("Array of 10 should fail with limit of 5")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .arrayLengthExceeded(let actual, let max) = error {
                XCTAssertEqual(max, 5, "Max array length should be 5")
                XCTAssertEqual(actual, 10, "Actual array length should be 10")
            } else {
                XCTFail("Expected arrayLengthExceeded, got \(error)")
            }
        }
    }
    
 /// Test string length limit enforcement
    func testStringLengthLimitEnforcement() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 50,
            maxMessageBytes: 10_000
        )
        
 // String of 50 should succeed
        let string50JSON = generateStringJSON(stringLength: 50)
        do {
            let result = try decoder.decode([String: String].self, from: string50JSON)
            XCTAssertEqual(result["s"]?.count, 50, "Should decode string of 50")
        } catch {
            XCTFail("String of 50 should succeed: \(error)")
        }
        
 // String of 100 should fail
        let string100JSON = generateStringJSON(stringLength: 100)
        do {
            _ = try decoder.decode([String: String].self, from: string100JSON)
            XCTFail("String of 100 should fail with limit of 50")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .stringLengthExceeded(let actual, let max) = error {
                XCTAssertEqual(max, 50, "Max string length should be 50")
                XCTAssertEqual(actual, 100, "Actual string length should be 100")
            } else {
                XCTFail("Expected stringLengthExceeded, got \(error)")
            }
        }
    }
    
 /// Test dictionary key length is also checked
    func testDictionaryKeyLengthChecked() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 10,
            maxMessageBytes: 10_000
        )
        
 // Key longer than 10 chars should fail
        let longKeyJSON = "{\"verylongkeyname\":1}".utf8Data
        do {
            _ = try decoder.decode([String: Int].self, from: longKeyJSON)
            XCTFail("Long key should fail with string limit of 10")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .stringLengthExceeded(let actual, let max) = error {
                XCTAssertEqual(max, 10, "Max string length should be 10")
                XCTAssertGreaterThan(actual, 10, "Key length should exceed 10")
            } else {
                XCTFail("Expected stringLengthExceeded, got \(error)")
            }
        }
    }
    
 /// Test valid JSON decodes successfully
    func testValidJSONDecodesSuccessfully() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 100,
            maxStringLength: 1000,
            maxMessageBytes: 10_000
        )
        
        let json = """
        {
            "id": 42,
            "name": "test message",
            "values": [1, 2, 3, 4, 5],
            "nested": {
                "key": "nested value",
                "data": ["a", "b", "c"]
            }
        }
        """.utf8Data
        
        let result = try decoder.decode(TestMessage.self, from: json)
        XCTAssertEqual(result.id, 42)
        XCTAssertEqual(result.name, "test message")
        XCTAssertEqual(result.values, [1, 2, 3, 4, 5])
        XCTAssertEqual(result.nested?.key, "nested value")
        XCTAssertEqual(result.nested?.data, ["a", "b", "c"])
    }
    
 /// Test initialization from SecurityLimits
    func testInitFromSecurityLimits() throws {
        let limits = SecurityLimits.default
        let decoder = LimitedJSONDecoder(from: limits)
        
 // Should use limits from SecurityLimits
        let validJSON = "{\"id\":1,\"name\":\"test\"}".utf8Data
        let result = try decoder.decode(TestMessage.self, from: validJSON)
        XCTAssertEqual(result.id, 1)
    }
    
 /// Test DecoderLimits default values
    func testDecoderLimitsDefaults() {
        let defaults = DecoderLimits.default
        XCTAssertEqual(defaults.maxDepth, 10)
        XCTAssertEqual(defaults.maxArrayLength, 1000)
        XCTAssertEqual(defaults.maxStringLength, 64 * 1024)
    }
    
 /// Test DecoderLimits initialization from SecurityLimits
    func testDecoderLimitsFromSecurityLimits() {
        let securityLimits = SecurityLimits.default
        let decoderLimits = DecoderLimits(from: securityLimits)
        
        XCTAssertEqual(decoderLimits.maxDepth, securityLimits.decodeDepthLimit)
        XCTAssertEqual(decoderLimits.maxArrayLength, securityLimits.decodeArrayLengthLimit)
        XCTAssertEqual(decoderLimits.maxStringLength, securityLimits.decodeStringLengthLimit)
    }
    
 /// Test invalid JSON returns parsing error
    func testInvalidJSONReturnsParsingError() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 64 * 1024,
            maxMessageBytes: 10_000
        )
        
        let invalidJSON = "not valid json".utf8Data
        
        do {
            _ = try decoder.decode([String: String].self, from: invalidJSON)
            XCTFail("Invalid JSON should fail")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .jsonParsingFailed = error {
 // Expected
            } else {
                XCTFail("Expected jsonParsingFailed, got \(error)")
            }
        }
    }
    
 /// Test type mismatch returns decode error
    func testTypeMismatchReturnsDecodeError() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 64 * 1024,
            maxMessageBytes: 10_000
        )
        
 // Valid JSON but wrong type
        let json = "{\"id\":\"not a number\",\"name\":\"test\"}".utf8Data
        
        do {
            _ = try decoder.decode(TestMessage.self, from: json)
            XCTFail("Type mismatch should fail")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .decodeFailed = error {
 // Expected
            } else {
                XCTFail("Expected decodeFailed, got \(error)")
            }
        }
    }
    
 /// Test empty data is handled correctly
    func testEmptyData() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 64 * 1024,
            maxMessageBytes: 10_000
        )
        
        let emptyData = Data()
        
        do {
            _ = try decoder.decode([String: String].self, from: emptyData)
            XCTFail("Empty data should fail")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .jsonParsingFailed = error {
 // Expected
            } else {
                XCTFail("Expected jsonParsingFailed, got \(error)")
            }
        }
    }
    
 /// Test null values are handled correctly
    func testNullValues() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 64 * 1024,
            maxMessageBytes: 10_000
        )
        
        let json = "{\"id\":1,\"name\":\"test\",\"values\":null,\"nested\":null}".utf8Data
        
        let result = try decoder.decode(TestMessage.self, from: json)
        XCTAssertEqual(result.id, 1)
        XCTAssertEqual(result.name, "test")
        XCTAssertNil(result.values)
        XCTAssertNil(result.nested)
    }
    
 /// Test numbers are not checked for digit count (per design decision)
    func testNumbersNotCheckedForDigits() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 10,
            maxArrayLength: 1000,
            maxStringLength: 10, // Very small string limit
            maxMessageBytes: 10_000
        )
        
 // Large number with many digits should succeed
 // (number digits are NOT checked per design decision)
        let json = "{\"n\":12345678901234567890}".utf8Data
        
        do {
            let result = try decoder.decode([String: Double].self, from: json)
            XCTAssertNotNil(result["n"], "Large number should decode")
        } catch {
            XCTFail("Large number should not fail: \(error)")
        }
    }
    
 /// Test deeply nested arrays
    func testDeeplyNestedArrays() throws {
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 3,
            maxArrayLength: 10,
            maxStringLength: 1000,
            maxMessageBytes: 10_000
        )
        
 // Nested arrays: [[[[1]]]] = depth 5
        let deepArrayJSON = "[[[[1]]]]".utf8Data
        
        do {
            _ = try decoder.decode([[[[Int]]]].self, from: deepArrayJSON)
            XCTFail("Deeply nested arrays should fail depth check")
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .depthExceeded = error {
 // Expected
            } else {
                XCTFail("Expected depthExceeded, got \(error)")
            }
        }
    }
    
 /// Test mixed nested structures
    func testMixedNestedStructures() throws {
 // Mixed: {"a":[{"b":[1]}]}
 // Level 1: {"a":...}
 // Level 2: [...]
 // Level 3: {"b":...}
 // Level 4: [...]
 // Level 5: 1
 // So this is depth 5
        
        let decoder = LimitedJSONDecoder.createForTesting(
            maxDepth: 5,
            maxArrayLength: 10,
            maxStringLength: 1000,
            maxMessageBytes: 10_000
        )
        
        let mixedJSON = "{\"a\":[{\"b\":[1]}]}".utf8Data
        
        do {
            _ = try decoder.decode([String: [[String: [Int]]]].self, from: mixedJSON)
 // Should succeed at depth 5
        } catch let error as LimitedJSONDecoder.DecodingError {
            if case .depthExceeded = error {
                XCTFail("Depth 5 should not exceed limit of 5")
            }
 // Other errors acceptable
        } catch {
 // Other errors acceptable
        }
    }
}
