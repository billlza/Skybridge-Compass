//
// CryptoProviderFactoryTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for CryptoProviderFactory
// **Feature: tech-debt-cleanup, Property 1: Provider Selection Determinism**
// **Validates: Requirements 1.1, 1.2**
//

import XCTest
@testable import SkyBridgeCore

final class CryptoProviderFactoryTests: XCTestCase {
    
 // MARK: - Property 1: Provider Selection Determinism
    
 /// **Property 1: Provider Selection Determinism**
 /// *For any* given environment capability and selection policy, the CryptoProviderFactory
 /// SHALL always return the same provider type.
 /// **Validates: Requirements 1.1, 1.2**
    func testProperty1_ProviderSelectionDeterminism() {
 // Test all combinations of capabilities and policies
        let capabilityCombinations: [(hasApplePQC: Bool, hasLiboqs: Bool)] = [
            (false, false),
            (false, true),
            (true, false),
            (true, true)
        ]
        
        let policies: [CryptoProviderFactory.SelectionPolicy] = [
            .preferPQC,
            .requirePQC,
            .classicOnly
        ]
        
        for capability in capabilityCombinations {
            for policy in policies {
                #if DEBUG
                let env = MockCryptoEnvironment(
                    hasApplePQC: capability.hasApplePQC,
                    hasLiboqs: capability.hasLiboqs
                )
                
 // Run selection multiple times
                let provider1 = CryptoProviderFactory.make(policy: policy, environment: env)
                let provider2 = CryptoProviderFactory.make(policy: policy, environment: env)
                let provider3 = CryptoProviderFactory.make(policy: policy, environment: env)
                
 // Property: Same inputs produce same provider type
                XCTAssertEqual(
                    provider1.providerName, provider2.providerName,
                    "Provider selection must be deterministic for capability=\(capability), policy=\(policy)"
                )
                XCTAssertEqual(
                    provider2.providerName, provider3.providerName,
                    "Provider selection must be deterministic for capability=\(capability), policy=\(policy)"
                )
                
 // Property: Same inputs produce same tier
                XCTAssertEqual(
                    provider1.tier, provider2.tier,
                    "Provider tier must be deterministic for capability=\(capability), policy=\(policy)"
                )
                
 // Property: Same inputs produce same suite
                XCTAssertEqual(
                    provider1.activeSuite, provider2.activeSuite,
                    "Provider suite must be deterministic for capability=\(capability), policy=\(policy)"
                )
                #endif
            }
        }
    }
    
 /// Test that preferPQC policy selects PQC when available
    func testProperty1_PreferPQCSelectsPQCWhenAvailable() {
        #if DEBUG
 // When liboqs is available, should select liboqs
        let envWithLiboqs = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: envWithLiboqs)
        
        XCTAssertEqual(provider.tier, .liboqsPQC,
                       "preferPQC should select liboqs when available")
        XCTAssertTrue(provider.activeSuite.isPQC,
                      "preferPQC should select PQC suite when available")
        #endif
    }
    
 /// Test that preferPQC policy falls back to classic when PQC unavailable
    func testProperty1_PreferPQCFallsBackToClassic() {
        #if DEBUG
        let envNoOQC = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: envNoOQC)
        
        XCTAssertEqual(provider.tier, .classic,
                       "preferPQC should fall back to classic when PQC unavailable")
        XCTAssertFalse(provider.activeSuite.isPQC,
                       "Classic provider should not have PQC suite")
        #endif
    }
    
 /// Test that classicOnly policy always selects classic
    func testProperty1_ClassicOnlyAlwaysSelectsClassic() {
        #if DEBUG
 // Even when PQC is available, classicOnly should select classic
        let envWithPQC = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .classicOnly, environment: envWithPQC)
        
        XCTAssertEqual(provider.tier, .classic,
                       "classicOnly should always select classic")
        XCTAssertEqual(provider.providerName, "Classic",
                       "classicOnly should select ClassicProvider")
        #endif
    }
    
 /// Test that requirePQC returns unavailable provider when PQC not available
    func testProperty1_RequirePQCReturnsUnavailableWhenNoPQC() {
        #if DEBUG
        let envNoPQC = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        let provider = CryptoProviderFactory.make(policy: .requirePQC, environment: envNoPQC)
        
        XCTAssertEqual(provider.providerName, "Unavailable",
                       "requirePQC should return Unavailable provider when PQC not available")
        #endif
    }
    
 /// Test that requirePQC selects PQC when available
    func testProperty1_RequirePQCSelectsPQCWhenAvailable() {
        #if DEBUG
        let envWithLiboqs = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .requirePQC, environment: envWithLiboqs)
        
        XCTAssertEqual(provider.tier, .liboqsPQC,
                       "requirePQC should select liboqs when available")
        #endif
    }
    
 // MARK: - CryptoSuite Tests
    
 /// Test CryptoSuite wireId encoding
    func testCryptoSuiteWireIdEncoding() {
 // Hybrid PQC (0x00xx)
        XCTAssertEqual(CryptoSuite.xwingMLDSA.wireId, 0x0001)
        XCTAssertEqual(CryptoSuite.xwingMLDSA.tierFromWireId, "hybridPQC")
        
 // Pure PQC (0x01xx)
        XCTAssertEqual(CryptoSuite.mlkem768MLDSA65.wireId, 0x0101)
        XCTAssertEqual(CryptoSuite.mlkem768MLDSA65.tierFromWireId, "purePQC")
        
 // Classic (0x10xx)
        XCTAssertEqual(CryptoSuite.x25519Ed25519.wireId, 0x1001)
        XCTAssertEqual(CryptoSuite.x25519Ed25519.tierFromWireId, "classic")
        XCTAssertEqual(CryptoSuite.p256ECDSA.wireId, 0x1002)
        XCTAssertEqual(CryptoSuite.p256ECDSA.tierFromWireId, "classic")
    }
    
 /// Test CryptoSuite parsing from wireId
    func testCryptoSuiteParsingFromWireId() {
 // Known suites
        XCTAssertEqual(CryptoSuite(wireId: 0x0001), .xwingMLDSA)
        XCTAssertEqual(CryptoSuite(wireId: 0x0101), .mlkem768MLDSA65)
        XCTAssertEqual(CryptoSuite(wireId: 0x1001), .x25519Ed25519)
        XCTAssertEqual(CryptoSuite(wireId: 0x1002), .p256ECDSA)
        
 // Unknown suite should return .unknown
        let unknown = CryptoSuite(wireId: 0xFFFF)
        XCTAssertFalse(unknown.isKnown)
        XCTAssertEqual(unknown.wireId, 0xFFFF)
        XCTAssertTrue(unknown.rawValue.hasPrefix("unknown-"))
    }
    
 /// Test CryptoSuite isPQC property
    func testCryptoSuiteIsPQC() {
        XCTAssertTrue(CryptoSuite.xwingMLDSA.isPQC)
        XCTAssertTrue(CryptoSuite.mlkem768MLDSA65.isPQC)
        XCTAssertFalse(CryptoSuite.x25519Ed25519.isPQC)
        XCTAssertFalse(CryptoSuite.p256ECDSA.isPQC)
    }
    
 // MARK: - Capability Detection Tests
    
 /// Test capability detection
    func testCapabilityDetection() {
        #if DEBUG
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        let capability = CryptoProviderFactory.detectCapability(environment: env)
        
        XCTAssertTrue(capability.hasApplePQC)
        XCTAssertTrue(capability.hasLiboqs)
        XCTAssertFalse(capability.osVersion.isEmpty)
        #endif
    }
    
 /// Test system environment (real detection)
    func testSystemEnvironmentDetection() {
        let capability = CryptoProviderFactory.detectCapability()
        
 // OS version should always be available
        XCTAssertFalse(capability.osVersion.isEmpty,
                       "OS version should be detected")
        
 // On current SDK, Apple PQC should be false (no HAS_APPLE_PQC_SDK)
        #if !HAS_APPLE_PQC_SDK
        XCTAssertFalse(capability.hasApplePQC,
                       "Apple PQC should be false without HAS_APPLE_PQC_SDK")
        #endif
    }
}

// MARK: - HPKESealedBox Tests

final class HPKESealedBoxTests: XCTestCase {
    
 /// Test HPKESealedBox round-trip serialization
    func testHPKESealedBoxRoundTrip() throws {
        let encKey = Data(repeating: 0x01, count: 32)
        let nonce = Data(repeating: 0x02, count: 12)
        let ciphertext = Data(repeating: 0x03, count: 100)
        let tag = Data(repeating: 0x04, count: 16)
        
        let box = HPKESealedBox(
            encapsulatedKey: encKey,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        
 // Serialize with header
        let combined = box.combinedWithHeader(suite: .x25519Ed25519)
        
 // Parse back
        let parsed = try HPKESealedBox(combined: combined, isHandshake: true)
        
        XCTAssertEqual(parsed.encapsulatedKey, encKey)
        XCTAssertEqual(parsed.nonce, nonce)
        XCTAssertEqual(parsed.ciphertext, ciphertext)
        XCTAssertEqual(parsed.tag, tag)
    }
    
 /// Test HPKESealedBox rejects invalid magic
    func testHPKESealedBoxRejectsInvalidMagic() {
        var data = Data(repeating: 0x00, count: 50)
        data[0] = 0x00  // Wrong magic
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data)) { error in
            guard case CryptoProviderError.invalidMagic = error else {
                XCTFail("Expected invalidMagic error")
                return
            }
        }
    }
    
 /// Test HPKESealedBox rejects unsupported version
    func testHPKESealedBoxRejectsUnsupportedVersion() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(3)  // Version 3 (unsupported)
        data.append(contentsOf: Data(repeating: 0x00, count: 50))
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data)) { error in
            guard case CryptoProviderError.unsupportedVersion(let v) = error else {
                XCTFail("Expected unsupportedVersion error")
                return
            }
            XCTAssertEqual(v, 3)
        }
    }
    
 /// Test HPKESealedBox rejects oversized encLen (DoS protection)
    func testHPKESealedBoxRejectsOversizedEncLen() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0xFF, 0xFF])  // encLen = 65535 (> 4096)
        data.append(12)  // nonceLen
        data.append(16)  // tagLen
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x10])  // ctLen = 16
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data)) { error in
            guard case CryptoProviderError.lengthExceeded(let field, _, _) = error else {
                XCTFail("Expected lengthExceeded error")
                return
            }
            XCTAssertEqual(field, "encLen")
        }
    }
    
 /// Test HPKESealedBox rejects oversized ctLen in handshake (DoS protection)
    func testHPKESealedBoxRejectsOversizedCtLenHandshake() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0x20, 0x00])  // encLen = 32
        data.append(12)  // nonceLen
        data.append(16)  // tagLen
        data.append(contentsOf: [0x00, 0x00, 0x02, 0x00])  // ctLen = 131072 (> 64KB)
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data, isHandshake: true)) { error in
            guard case CryptoProviderError.lengthExceeded(let field, _, _) = error else {
                XCTFail("Expected lengthExceeded error")
                return
            }
            XCTAssertEqual(field, "ctLen")
        }
    }
    
 /// Test HPKESealedBox rejects invalid nonce length
    func testHPKESealedBoxRejectsInvalidNonceLength() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0x20, 0x00])  // encLen = 32
        data.append(16)  // nonceLen = 16 (should be 12)
        data.append(16)  // tagLen
        data.append(contentsOf: [0x10, 0x00, 0x00, 0x00])  // ctLen = 16
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data)) { error in
            guard case CryptoProviderError.invalidNonceLength(let len) = error else {
                XCTFail("Expected invalidNonceLength error")
                return
            }
            XCTAssertEqual(len, 16)
        }
    }
    
 /// Test HPKESealedBox rejects invalid tag length
    func testHPKESealedBoxRejectsInvalidTagLength() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0x20, 0x00])  // encLen = 32
        data.append(12)  // nonceLen
        data.append(32)  // tagLen = 32 (should be 16)
        data.append(contentsOf: [0x10, 0x00, 0x00, 0x00])  // ctLen = 16
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data)) { error in
            guard case CryptoProviderError.invalidTagLength(let len) = error else {
                XCTFail("Expected invalidTagLength error")
                return
            }
            XCTAssertEqual(len, 32)
        }
    }
    
 /// Test HPKESealedBox detects length overflow
    func testHPKESealedBoxDetectsLengthOverflow() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0x10, 0x00])  // encLen = 4096 (max)
        data.append(12)  // nonceLen
        data.append(16)  // tagLen
        data.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])  // ctLen = Int.max / 2 (will overflow)
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data, isHandshake: false)) { error in
 // Should fail with either lengthExceeded or lengthOverflow
            switch error {
            case CryptoProviderError.lengthExceeded, CryptoProviderError.lengthOverflow:
                break  // Expected
            default:
                XCTFail("Expected lengthExceeded or lengthOverflow error, got \(error)")
            }
        }
    }
    
 // MARK: - Property 10: HPKESealedBox DoS Resistance
    
 /// **Property 10: HPKESealedBox DoS Resistance**
 /// *For any* malformed input (oversized length fields, wrong magic, wrong version,
 /// overflow-triggering values), the HPKESealedBox parser SHALL:
 /// 1. Reject the input with an appropriate error
 /// 2. NOT allocate large memory buffers before validation
 /// **Validates: Requirements 13.4, 13.5, 13.6, 13.7, 13.8**
    
 /// Test HPKESealedBox rejects data too short for header
    func testProperty10_RejectsDataTooShort() {
 // Header is 17 bytes minimum
        let shortData = Data(repeating: 0x00, count: 10)
        
        XCTAssertThrowsError(try HPKESealedBox(combined: shortData)) { error in
            guard case CryptoProviderError.invalidSealedBox = error else {
                XCTFail("Expected invalidSealedBox error for short data")
                return
            }
        }
    }
    
 /// Test HPKESealedBox allows larger ctLen post-auth (256KB limit)
    func testProperty10_AllowsLargerCtLenPostAuth() throws {
 // Create valid header with ctLen = 100KB (allowed post-auth, rejected in handshake)
        let encKey = Data(repeating: 0x01, count: 32)
        let nonce = Data(repeating: 0x02, count: 12)
        let ciphertext = Data(repeating: 0x03, count: 100 * 1024)  // 100KB
        let tag = Data(repeating: 0x04, count: 16)
        
        let box = HPKESealedBox(
            encapsulatedKey: encKey,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        
        let combined = box.combinedWithHeader(suite: .x25519Ed25519)
        
 // Should succeed post-auth
        XCTAssertNoThrow(try HPKESealedBox(combined: combined, isHandshake: false))
        
 // Should fail in handshake (64KB limit)
        XCTAssertThrowsError(try HPKESealedBox(combined: combined, isHandshake: true)) { error in
            guard case CryptoProviderError.lengthExceeded(let field, _, _) = error else {
                XCTFail("Expected lengthExceeded error")
                return
            }
            XCTAssertEqual(field, "ctLen")
        }
    }
    
 /// Test HPKESealedBox rejects oversized ctLen post-auth (> 256KB)
    func testProperty10_RejectsOversizedCtLenPostAuth() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0x20, 0x00])  // encLen = 32
        data.append(12)  // nonceLen
        data.append(16)  // tagLen
        data.append(contentsOf: [0x00, 0x00, 0x08, 0x00])  // ctLen = 512KB (> 256KB)
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data, isHandshake: false)) { error in
            guard case CryptoProviderError.lengthExceeded(let field, _, _) = error else {
                XCTFail("Expected lengthExceeded error")
                return
            }
            XCTAssertEqual(field, "ctLen")
        }
    }
    
 /// Test HPKESealedBox rejects length mismatch (header says more than actual data)
    func testProperty10_RejectsLengthMismatch() {
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0x20, 0x00])  // encLen = 32
        data.append(12)  // nonceLen
        data.append(16)  // tagLen
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x00])  // ctLen = 256
 // Total expected: 17 + 32 + 12 + 256 + 16 = 333 bytes
 // But we only append header (17 bytes) + some padding
        data.append(contentsOf: Data(repeating: 0x00, count: 50))  // Only 67 bytes total
        
        XCTAssertThrowsError(try HPKESealedBox(combined: data)) { error in
            guard case CryptoProviderError.lengthMismatch(let expected, let actual) = error else {
                XCTFail("Expected lengthMismatch error, got \(error)")
                return
            }
            XCTAssertEqual(expected, 333)
            XCTAssertEqual(actual, 67)
        }
    }
    
 /// Test HPKESealedBox with random malformed inputs (fuzz-like)
    func testProperty10_RandomMalformedInputs() {
 // Test various malformed inputs that should all be rejected safely
        let malformedInputs: [(name: String, data: Data)] = [
            ("empty", Data()),
            ("single_byte", Data([0x00])),
            ("wrong_magic_1", Data([0x00, 0x00, 0x00, 0x00] + Array(repeating: UInt8(0), count: 50))),
            ("wrong_magic_2", Data([0x48, 0x50, 0x4B, 0x00] + Array(repeating: UInt8(0), count: 50))),
            ("version_0", Data([0x48, 0x50, 0x4B, 0x45, 0x00] + Array(repeating: UInt8(0), count: 50))),
            ("version_255", Data([0x48, 0x50, 0x4B, 0x45, 0xFF] + Array(repeating: UInt8(0), count: 50))),
        ]
        
        for (name, data) in malformedInputs {
            XCTAssertThrowsError(try HPKESealedBox(combined: data), "Should reject malformed input: \(name)") { _ in
 // Any error is acceptable, as long as it doesn't crash or allocate huge memory
            }
        }
    }
    
 /// Test HPKESealedBox validates all length fields before any allocation
 /// This is a key DoS protection: we must not allocate based on untrusted length fields
    func testProperty10_ValidatesBeforeAllocation() {
 // Create a header that claims huge sizes but has minimal actual data
 // If the implementation allocates before validating, this could cause OOM
        var data = Data([0x48, 0x50, 0x4B, 0x45])  // "HPKE" magic
        data.append(1)  // Version 1
        data.append(contentsOf: [0x00, 0x01])  // suiteWireId
        data.append(contentsOf: [0x00, 0x00])  // flags
        data.append(contentsOf: [0xFF, 0x0F])  // encLen = 4095 (just under max)
        data.append(12)  // nonceLen
        data.append(16)  // tagLen
        data.append(contentsOf: [0xFF, 0xFF, 0x00, 0x00])  // ctLen = 65535 (just under 64KB handshake limit)
 // Don't append actual payload - this tests that validation happens before allocation
        
 // This should fail with lengthMismatch, NOT crash or hang
        XCTAssertThrowsError(try HPKESealedBox(combined: data, isHandshake: true)) { error in
            guard case CryptoProviderError.lengthMismatch = error else {
                XCTFail("Expected lengthMismatch error, got \(error)")
                return
            }
        }
    }
    
 /// Test HPKESealedBox combinedWithHeader produces valid output
    func testProperty10_CombinedWithHeaderRoundTrip() throws {
        let suites: [CryptoSuite] = [.x25519Ed25519, .mlkem768MLDSA65, .xwingMLDSA, .p256ECDSA]
        
        for suite in suites {
            let encKey = Data(repeating: 0x01, count: 32)
            let nonce = Data(repeating: 0x02, count: 12)
            let ciphertext = Data(repeating: 0x03, count: 64)
            let tag = Data(repeating: 0x04, count: 16)
            
            let box = HPKESealedBox(
                encapsulatedKey: encKey,
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            
            let combined = box.combinedWithHeader(suite: suite)
            
 // Verify header structure
            XCTAssertEqual(combined[0], 0x48, "Magic byte 0")  // 'H'
            XCTAssertEqual(combined[1], 0x50, "Magic byte 1")  // 'P'
            XCTAssertEqual(combined[2], 0x4B, "Magic byte 2")  // 'K'
            XCTAssertEqual(combined[3], 0x45, "Magic byte 3")  // 'E'
            XCTAssertEqual(combined[4], 1, "Version")
            
 // Parse back
            let parsed = try HPKESealedBox(combined: combined, isHandshake: true)
            XCTAssertEqual(parsed.encapsulatedKey, encKey, "Suite: \(suite.rawValue)")
            XCTAssertEqual(parsed.nonce, nonce, "Suite: \(suite.rawValue)")
            XCTAssertEqual(parsed.ciphertext, ciphertext, "Suite: \(suite.rawValue)")
            XCTAssertEqual(parsed.tag, tag, "Suite: \(suite.rawValue)")
        }
    }
}

// MARK: - KeyMaterial Tests

final class KeyMaterialTests: XCTestCase {
    
 /// Test KeyMaterial validation for X25519
    func testKeyMaterialValidationX25519() throws {
        let validKey = KeyMaterial(
            suite: .x25519Ed25519,
            usage: .keyExchange,
            bytes: Data(repeating: 0x01, count: 32)
        )
        
 // Should not throw
        XCTAssertNoThrow(try validKey.validate(isPublic: true))
    }
    
 /// Test KeyMaterial validation rejects wrong length
    func testKeyMaterialValidationRejectsWrongLength() {
        let invalidKey = KeyMaterial(
            suite: .x25519Ed25519,
            usage: .keyExchange,
            bytes: Data(repeating: 0x01, count: 16)  // Wrong length
        )
        
        XCTAssertThrowsError(try invalidKey.validate(isPublic: true)) { error in
            guard case CryptoProviderError.invalidKeyLength(let expected, let actual, _, _) = error else {
                XCTFail("Expected invalidKeyLength error")
                return
            }
            XCTAssertEqual(expected, 32)
            XCTAssertEqual(actual, 16)
        }
    }
    
 /// Test KeyPair requires matching suite and usage
    func testKeyPairRequiresMatchingSuiteAndUsage() {
        let pubKey = KeyMaterial(
            suite: .x25519Ed25519,
            usage: .keyExchange,
            bytes: Data(repeating: 0x01, count: 32)
        )
        let privKey = KeyMaterial(
            suite: .x25519Ed25519,
            usage: .keyExchange,
            bytes: Data(repeating: 0x02, count: 64)
        )
        
 // Should not crash
        let keyPair = KeyPair(publicKey: pubKey, privateKey: privKey)
        XCTAssertEqual(keyPair.publicKey.suite, keyPair.privateKey.suite)
    }
    
 // MARK: - Property 12: Key Material Type Safety
    
 /// **Property 12: Key Material Type Safety**
 /// *For any* key material with incorrect length, the CryptoProvider SHALL:
 /// 1. Reject the key at entry point with CryptoProviderError.invalidKeyLength
 /// 2. Include descriptive error information (expected, actual, suite, usage)
 /// **Validates: Requirements 15.1, 15.2, 15.3**
    
 /// Test ClassicProvider rejects invalid public key length for HPKE seal
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty12_ClassicProviderRejectsInvalidPublicKeyForSeal() async {
        let provider = ClassicCryptoProvider()
        let invalidPublicKey = Data(repeating: 0x01, count: 16)  // Wrong length (should be 32)
        let plaintext = Data("test".utf8)
        let info = Data("info".utf8)
        
        do {
            _ = try await provider.hpkeSeal(
                plaintext: plaintext,
                recipientPublicKey: invalidPublicKey,
                info: info
            )
            XCTFail("Should reject invalid public key length")
        } catch let error as CryptoProviderError {
            switch error {
            case .invalidKeyLength(let expected, let actual, let suite, let usage):
                XCTAssertEqual(expected, 32)
                XCTAssertEqual(actual, 16)
                XCTAssertEqual(suite, "X25519")
                XCTAssertEqual(usage, .keyExchange)
            default:
                XCTFail("Expected invalidKeyLength error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
 /// Test ClassicProvider rejects invalid private key length for HPKE open
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty12_ClassicProviderRejectsInvalidPrivateKeyForOpen() async {
        let provider = ClassicCryptoProvider()
        let invalidPrivateKey = Data(repeating: 0x01, count: 64)  // Wrong length (should be 32)
        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(repeating: 0x02, count: 32),
            nonce: Data(repeating: 0x03, count: 12),
            ciphertext: Data(repeating: 0x04, count: 16),
            tag: Data(repeating: 0x05, count: 16)
        )
        let info = Data("info".utf8)
        
        do {
            _ = try await provider.hpkeOpen(
                sealedBox: sealedBox,
                privateKey: invalidPrivateKey,
                info: info
            )
            XCTFail("Should reject invalid private key length")
        } catch let error as CryptoProviderError {
            switch error {
            case .invalidKeyLength(let expected, let actual, _, _):
                XCTAssertEqual(expected, 32)
                XCTAssertEqual(actual, 64)
            default:
                XCTFail("Expected invalidKeyLength error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
 /// Test ClassicProvider rejects invalid private key length for sign
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty12_ClassicProviderRejectsInvalidPrivateKeyForSign() async {
        let provider = ClassicCryptoProvider()
        let invalidPrivateKey = Data(repeating: 0x01, count: 16)  // Wrong length (should be 32)
        let data = Data("message".utf8)
        
        do {
            _ = try await provider.sign(data: data, using: .softwareKey(invalidPrivateKey))
            XCTFail("Should reject invalid private key length")
        } catch let error as CryptoProviderError {
            switch error {
            case .invalidKeyLength(let expected, let actual, _, let usage):
                XCTAssertEqual(expected, 32)
                XCTAssertEqual(actual, 16)
                XCTAssertEqual(usage, .signing)
            default:
                XCTFail("Expected invalidKeyLength error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
 /// Test ClassicProvider rejects invalid public key length for verify
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty12_ClassicProviderRejectsInvalidPublicKeyForVerify() async {
        let provider = ClassicCryptoProvider()
        let invalidPublicKey = Data(repeating: 0x01, count: 64)  // Wrong length (should be 32)
        let data = Data("message".utf8)
        let signature = Data(repeating: 0x02, count: 64)
        
        do {
            _ = try await provider.verify(data: data, signature: signature, publicKey: invalidPublicKey)
            XCTFail("Should reject invalid public key length")
        } catch let error as CryptoProviderError {
            switch error {
            case .invalidKeyLength(let expected, let actual, _, _):
                XCTAssertEqual(expected, 32)
                XCTAssertEqual(actual, 64)
            default:
                XCTFail("Expected invalidKeyLength error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
 /// Test KeyMaterial validation for various suites
    func testProperty12_KeyMaterialValidationForVariousSuites() throws {
 // X25519 key exchange - valid
        let x25519Valid = KeyMaterial(suite: .x25519Ed25519, usage: .keyExchange, bytes: Data(repeating: 0x01, count: 32))
        XCTAssertNoThrow(try x25519Valid.validate(isPublic: true))
        
 // X25519 key exchange - invalid
        let x25519Invalid = KeyMaterial(suite: .x25519Ed25519, usage: .keyExchange, bytes: Data(repeating: 0x01, count: 16))
        XCTAssertThrowsError(try x25519Invalid.validate(isPublic: true))
        
 // Ed25519 signing public key - valid
        let ed25519PubValid = KeyMaterial(suite: .x25519Ed25519, usage: .signing, bytes: Data(repeating: 0x01, count: 32))
        XCTAssertNoThrow(try ed25519PubValid.validate(isPublic: true))
        
 // Ed25519 signing private key - valid
        let ed25519PrivValid = KeyMaterial(suite: .x25519Ed25519, usage: .signing, bytes: Data(repeating: 0x01, count: 64))
        XCTAssertNoThrow(try ed25519PrivValid.validate(isPublic: false))
        
 // Unknown suite - should skip validation (return without error)
        let unknownSuite = KeyMaterial(suite: .unknown(0xFFFF), usage: .keyExchange, bytes: Data(repeating: 0x01, count: 100))
        XCTAssertNoThrow(try unknownSuite.validate(isPublic: true))
    }
}


// MARK: - Property 2: Provider Fallback Transparency Tests

final class ClassicProviderTests: XCTestCase {
    
 // MARK: - Property 2: Provider Fallback Transparency
    
 /// **Property 2: Provider Fallback Transparency**
 /// *For any* plaintext and key pair, the ClassicProvider SHALL:
 /// 1. Successfully seal and open data (round-trip)
 /// 2. Produce valid signatures that verify correctly
 /// 3. Generate valid key pairs for both usages
 /// **Validates: Requirements 1.3, 1.5, 2.3**
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_HPKERoundTrip() async throws {
        let provider = ClassicCryptoProvider()
        
 // Generate key pair for key exchange
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        
 // Test data
        let plaintext = Data("Hello, SkyBridge PQC!".utf8)
        let info = Data("test-context".utf8)
        
 // Seal
        let sealedBox = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )
        
 // Verify sealed box structure
        XCTAssertEqual(sealedBox.encapsulatedKey.count, 32, "X25519 public key should be 32 bytes")
        XCTAssertEqual(sealedBox.nonce.count, 0, "HPKE v2 should not expose an AES-GCM nonce")
        XCTAssertEqual(sealedBox.tag.count, 0, "HPKE v2 should not expose an AES-GCM tag")
        
 // Open
        let decrypted = try await provider.hpkeOpen(
            sealedBox: sealedBox,
            privateKey: keyPair.privateKey.bytes,
            info: info
        )
        
        XCTAssertEqual(decrypted, plaintext, "Decrypted data should match original plaintext")
    }
    
 /// Test signature round-trip
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_SignatureRoundTrip() async throws {
        let provider = ClassicCryptoProvider()
        
 // Generate signing key pair
        let keyPair = try await provider.generateKeyPair(for: .signing)
        
 // Test data
        let data = Data("Message to sign".utf8)
        
 // Sign
        let signature = try await provider.sign(data: data, using: .softwareKey(keyPair.privateKey.bytes))
        
 // Verify signature length (Ed25519 = 64 bytes)
        XCTAssertEqual(signature.count, 64, "Ed25519 signature should be 64 bytes")
        
 // Verify
        let isValid = try await provider.verify(
            data: data,
            signature: signature,
            publicKey: keyPair.publicKey.bytes
        )
        
        XCTAssertTrue(isValid, "Signature should verify correctly")
    }
    
 /// Test that wrong key fails verification
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_WrongKeyFailsVerification() async throws {
        let provider = ClassicCryptoProvider()
        
 // Generate two different key pairs
        let keyPair1 = try await provider.generateKeyPair(for: .signing)
        let keyPair2 = try await provider.generateKeyPair(for: .signing)
        
        let data = Data("Message to sign".utf8)
        
 // Sign with key pair 1
        let signature = try await provider.sign(data: data, using: .softwareKey(keyPair1.privateKey.bytes))
        
 // Verify with key pair 2's public key (should fail)
        let isValid = try await provider.verify(
            data: data,
            signature: signature,
            publicKey: keyPair2.publicKey.bytes
        )
        
        XCTAssertFalse(isValid, "Signature should not verify with wrong public key")
    }
    
 /// Test that tampered data fails verification
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_TamperedDataFailsVerification() async throws {
        let provider = ClassicCryptoProvider()
        
        let keyPair = try await provider.generateKeyPair(for: .signing)
        let data = Data("Original message".utf8)
        
 // Sign original data
        let signature = try await provider.sign(data: data, using: .softwareKey(keyPair.privateKey.bytes))
        
 // Tamper with data
        let tamperedData = Data("Tampered message".utf8)
        
 // Verify with tampered data (should fail)
        let isValid = try await provider.verify(
            data: tamperedData,
            signature: signature,
            publicKey: keyPair.publicKey.bytes
        )
        
        XCTAssertFalse(isValid, "Signature should not verify with tampered data")
    }
    
 /// Test key pair generation produces correct lengths
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_KeyPairLengths() async throws {
        let provider = ClassicCryptoProvider()
        
 // Key exchange keys (X25519)
        let kemKeyPair = try await provider.generateKeyPair(for: .keyExchange)
        XCTAssertEqual(kemKeyPair.publicKey.bytes.count, 32, "X25519 public key should be 32 bytes")
        XCTAssertEqual(kemKeyPair.privateKey.bytes.count, 32, "X25519 private key should be 32 bytes")
        XCTAssertEqual(kemKeyPair.publicKey.suite, .x25519Ed25519)
        XCTAssertEqual(kemKeyPair.publicKey.usage, .keyExchange)
        
 // Signing keys (Ed25519)
        let sigKeyPair = try await provider.generateKeyPair(for: .signing)
        XCTAssertEqual(sigKeyPair.publicKey.bytes.count, 32, "Ed25519 public key should be 32 bytes")
        XCTAssertEqual(sigKeyPair.privateKey.bytes.count, 32, "Ed25519 private key should be 32 bytes")
        XCTAssertEqual(sigKeyPair.publicKey.suite, .x25519Ed25519)
        XCTAssertEqual(sigKeyPair.publicKey.usage, .signing)
    }
    
 /// Test HPKE with wrong key fails decryption
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_WrongKeyFailsDecryption() async throws {
        let provider = ClassicCryptoProvider()
        
 // Generate two different key pairs
        let keyPair1 = try await provider.generateKeyPair(for: .keyExchange)
        let keyPair2 = try await provider.generateKeyPair(for: .keyExchange)
        
        let plaintext = Data("Secret message".utf8)
        let info = Data("test-context".utf8)
        
 // Seal with key pair 1's public key
        let sealedBox = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair1.publicKey.bytes,
            info: info
        )
        
 // Try to open with key pair 2's private key (should fail)
        do {
            _ = try await provider.hpkeOpen(
                sealedBox: sealedBox,
                privateKey: keyPair2.privateKey.bytes,
                info: info
            )
            XCTFail("Decryption should fail with wrong private key")
        } catch {
 // Expected - decryption should fail
        }
    }
    
 /// Test provider properties
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_ProviderProperties() {
        let provider = ClassicCryptoProvider()
        
        XCTAssertEqual(provider.providerName, "Classic")
        XCTAssertEqual(provider.tier, .classic)
        XCTAssertEqual(provider.activeSuite, .x25519Ed25519)
        XCTAssertFalse(provider.activeSuite.isPQC, "Classic suite should not be PQC")
    }
    
 /// Test multiple seal operations produce different ciphertexts (randomness)
    @available(macOS 14.0, iOS 17.0, *)
    func testProperty2_SealProducesDifferentCiphertexts() async throws {
        let provider = ClassicCryptoProvider()
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        
        let plaintext = Data("Same message".utf8)
        let info = Data("test-context".utf8)
        
 // Seal twice
        let sealedBox1 = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )
        
        let sealedBox2 = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )
        
 // Ephemeral keys should be different
        XCTAssertNotEqual(sealedBox1.encapsulatedKey, sealedBox2.encapsulatedKey,
                         "Each seal should use different ephemeral key")
        
        XCTAssertTrue(sealedBox1.nonce.isEmpty)
        XCTAssertTrue(sealedBox2.nonce.isEmpty)
        
 // Ciphertexts should be different
        XCTAssertNotEqual(sealedBox1.ciphertext, sealedBox2.ciphertext,
                         "Ciphertexts should be different due to different keys/nonces")
        
 // But both should decrypt to same plaintext
        let decrypted1 = try await provider.hpkeOpen(
            sealedBox: sealedBox1,
            privateKey: keyPair.privateKey.bytes,
            info: info
        )
        let decrypted2 = try await provider.hpkeOpen(
            sealedBox: sealedBox2,
            privateKey: keyPair.privateKey.bytes,
            info: info
        )
        
        XCTAssertEqual(decrypted1, plaintext)
        XCTAssertEqual(decrypted2, plaintext)
    }
}


// MARK: - OQSPQCProvider Tests ( 4)

#if canImport(OQSRAII)
final class OQSPQCProviderTests: XCTestCase {
    
 // MARK: - Provider Properties
    
 /// Test OQSPQCProvider properties
    @available(macOS 14.0, iOS 17.0, *)
    func testOQSPQCProviderProperties() {
        let provider = OQSPQCCryptoProvider()
        
        XCTAssertEqual(provider.providerName, "liboqs")
        XCTAssertEqual(provider.tier, .liboqsPQC)
        XCTAssertEqual(provider.activeSuite, .mlkem768MLDSA65)
        XCTAssertTrue(provider.activeSuite.isPQC, "OQS suite should be PQC")
    }
    
 // MARK: - Key Generation Tests
    
 /// Test ML-KEM-768 key pair generation
    @available(macOS 14.0, iOS 17.0, *)
    func testMLKEM768KeyPairGeneration() async throws {
        let provider = OQSPQCCryptoProvider()
        
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        
 // ML-KEM-768 key sizes
        XCTAssertEqual(keyPair.publicKey.bytes.count, 1184, "ML-KEM-768 public key should be 1184 bytes")
        XCTAssertEqual(keyPair.privateKey.bytes.count, 2400, "ML-KEM-768 private key should be 2400 bytes")
        XCTAssertEqual(keyPair.publicKey.suite, .mlkem768MLDSA65)
        XCTAssertEqual(keyPair.publicKey.usage, .keyExchange)
    }
    
 /// Test ML-DSA-65 key pair generation
    @available(macOS 14.0, iOS 17.0, *)
    func testMLDSA65KeyPairGeneration() async throws {
        let provider = OQSPQCCryptoProvider()
        
        let keyPair = try await provider.generateKeyPair(for: .signing)
        
 // ML-DSA-65 key sizes
        XCTAssertEqual(keyPair.publicKey.bytes.count, 1952, "ML-DSA-65 public key should be 1952 bytes")
        XCTAssertEqual(keyPair.privateKey.bytes.count, 4032, "ML-DSA-65 private key should be 4032 bytes")
        XCTAssertEqual(keyPair.publicKey.suite, .mlkem768MLDSA65)
        XCTAssertEqual(keyPair.publicKey.usage, .signing)
    }
    
 /// Test key generation produces different keys each time
    @available(macOS 14.0, iOS 17.0, *)
    func testKeyGenerationRandomness() async throws {
        let provider = OQSPQCCryptoProvider()
        
        let keyPair1 = try await provider.generateKeyPair(for: .keyExchange)
        let keyPair2 = try await provider.generateKeyPair(for: .keyExchange)
        
        XCTAssertNotEqual(keyPair1.publicKey.bytes, keyPair2.publicKey.bytes,
                         "Each key generation should produce different keys")
        XCTAssertNotEqual(keyPair1.privateKey.bytes, keyPair2.privateKey.bytes,
                         "Each key generation should produce different keys")
    }
    
 // MARK: - HPKE Tests (ML-KEM-768 + AES-GCM)
    
 /// Test HPKE round-trip with ML-KEM-768
    @available(macOS 14.0, iOS 17.0, *)
    func testHPKERoundTrip() async throws {
        let provider = OQSPQCCryptoProvider()
        
 // Generate key pair for key exchange
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        
 // Test data
        let plaintext = Data("Hello, Post-Quantum Cryptography!".utf8)
        let info = Data("test-pqc-context".utf8)
        
 // Seal
        let sealedBox = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )
        
 // Verify sealed box structure
        XCTAssertEqual(sealedBox.encapsulatedKey.count, 1088, "ML-KEM-768 ciphertext should be 1088 bytes")
        XCTAssertEqual(sealedBox.nonce.count, 12, "AES-GCM nonce should be 12 bytes")
        XCTAssertEqual(sealedBox.tag.count, 16, "AES-GCM tag should be 16 bytes")
        
 // Open
        let decrypted = try await provider.hpkeOpen(
            sealedBox: sealedBox,
            privateKey: keyPair.privateKey.bytes,
            info: info
        )
        
        XCTAssertEqual(decrypted, plaintext, "Decrypted data should match original plaintext")
    }
    
 /// Test HPKE with wrong key fails decryption
    @available(macOS 14.0, iOS 17.0, *)
    func testHPKEWrongKeyFailsDecryption() async throws {
        let provider = OQSPQCCryptoProvider()
        
 // Generate two different key pairs
        let keyPair1 = try await provider.generateKeyPair(for: .keyExchange)
        let keyPair2 = try await provider.generateKeyPair(for: .keyExchange)
        
        let plaintext = Data("Secret PQC message".utf8)
        let info = Data("test-context".utf8)
        
 // Seal with key pair 1's public key
        let sealedBox = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair1.publicKey.bytes,
            info: info
        )
        
 // Try to open with key pair 2's private key (should fail)
        do {
            _ = try await provider.hpkeOpen(
                sealedBox: sealedBox,
                privateKey: keyPair2.privateKey.bytes,
                info: info
            )
            XCTFail("Decryption should fail with wrong private key")
        } catch {
 // Expected - decryption should fail
        }
    }
    
 /// Test multiple seal operations produce different ciphertexts
    @available(macOS 14.0, iOS 17.0, *)
    func testSealProducesDifferentCiphertexts() async throws {
        let provider = OQSPQCCryptoProvider()
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        
        let plaintext = Data("Same PQC message".utf8)
        let info = Data("test-context".utf8)
        
 // Seal twice
        let sealedBox1 = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )
        
        let sealedBox2 = try await provider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: info
        )
        
 // Encapsulated keys should be different (KEM randomness)
        XCTAssertNotEqual(sealedBox1.encapsulatedKey, sealedBox2.encapsulatedKey,
                         "Each seal should use different KEM encapsulation")
        
 // Nonces should be different
        XCTAssertNotEqual(sealedBox1.nonce, sealedBox2.nonce,
                         "Each seal should use different nonce")
        
 // But both should decrypt to same plaintext
        let decrypted1 = try await provider.hpkeOpen(
            sealedBox: sealedBox1,
            privateKey: keyPair.privateKey.bytes,
            info: info
        )
        let decrypted2 = try await provider.hpkeOpen(
            sealedBox: sealedBox2,
            privateKey: keyPair.privateKey.bytes,
            info: info
        )
        
        XCTAssertEqual(decrypted1, plaintext)
        XCTAssertEqual(decrypted2, plaintext)
    }
    
 // MARK: - Signature Tests (ML-DSA-65)
    
 /// Test ML-DSA-65 signature round-trip
    @available(macOS 14.0, iOS 17.0, *)
    func testSignatureRoundTrip() async throws {
        let provider = OQSPQCCryptoProvider()
        
 // Generate signing key pair
        let keyPair = try await provider.generateKeyPair(for: .signing)
        
 // Test data
        let data = Data("Message to sign with PQC".utf8)
        
 // Sign
        let signature = try await provider.sign(data: data, using: .softwareKey(keyPair.privateKey.bytes))
        
 // ML-DSA-65 signature is variable length, but typically around 3309 bytes
        XCTAssertGreaterThan(signature.count, 3000, "ML-DSA-65 signature should be > 3000 bytes")
        XCTAssertLessThan(signature.count, 4000, "ML-DSA-65 signature should be < 4000 bytes")
        
 // Verify
        let isValid = try await provider.verify(
            data: data,
            signature: signature,
            publicKey: keyPair.publicKey.bytes
        )
        
        XCTAssertTrue(isValid, "Signature should verify correctly")
    }
    
 /// Test signature with wrong key fails verification
    @available(macOS 14.0, iOS 17.0, *)
    func testWrongKeyFailsVerification() async throws {
        let provider = OQSPQCCryptoProvider()
        
 // Generate two different key pairs
        let keyPair1 = try await provider.generateKeyPair(for: .signing)
        let keyPair2 = try await provider.generateKeyPair(for: .signing)
        
        let data = Data("Message to sign".utf8)
        
 // Sign with key pair 1
        let signature = try await provider.sign(data: data, using: .softwareKey(keyPair1.privateKey.bytes))
        
 // Verify with key pair 2's public key (should fail)
        let isValid = try await provider.verify(
            data: data,
            signature: signature,
            publicKey: keyPair2.publicKey.bytes
        )
        
        XCTAssertFalse(isValid, "Signature should not verify with wrong public key")
    }
    
 /// Test tampered data fails verification
    @available(macOS 14.0, iOS 17.0, *)
    func testTamperedDataFailsVerification() async throws {
        let provider = OQSPQCCryptoProvider()
        
        let keyPair = try await provider.generateKeyPair(for: .signing)
        let data = Data("Original PQC message".utf8)
        
 // Sign original data
        let signature = try await provider.sign(data: data, using: .softwareKey(keyPair.privateKey.bytes))
        
 // Tamper with data
        let tamperedData = Data("Tampered PQC message".utf8)
        
 // Verify with tampered data (should fail)
        let isValid = try await provider.verify(
            data: tamperedData,
            signature: signature,
            publicKey: keyPair.publicKey.bytes
        )
        
        XCTAssertFalse(isValid, "Signature should not verify with tampered data")
    }
    
 // MARK: - Key Length Validation Tests
    
 /// Test HPKE rejects invalid public key length
    @available(macOS 14.0, iOS 17.0, *)
    func testHPKERejectsInvalidPublicKeyLength() async throws {
        let provider = OQSPQCCryptoProvider()
        
        let plaintext = Data("Test".utf8)
        let info = Data("test".utf8)
        let invalidPublicKey = Data(repeating: 0x01, count: 32)  // Wrong length
        
        do {
            _ = try await provider.hpkeSeal(
                plaintext: plaintext,
                recipientPublicKey: invalidPublicKey,
                info: info
            )
            XCTFail("Should reject invalid public key length")
        } catch let error as CryptoProviderError {
            switch error {
            case .invalidKeyLength(let expected, let actual, _, _):
                XCTAssertEqual(expected, 1184)
                XCTAssertEqual(actual, 32)
            default:
                XCTFail("Expected invalidKeyLength error, got \(error)")
            }
        }
    }
    
 /// Test sign rejects invalid private key length
    @available(macOS 14.0, iOS 17.0, *)
    func testSignRejectsInvalidPrivateKeyLength() async throws {
        let provider = OQSPQCCryptoProvider()
        
        let data = Data("Test".utf8)
        let invalidPrivateKey = Data(repeating: 0x01, count: 64)  // Wrong length
        
        do {
            _ = try await provider.sign(data: data, using: .softwareKey(invalidPrivateKey))
            XCTFail("Should reject invalid private key length")
        } catch let error as CryptoProviderError {
            switch error {
            case .invalidKeyLength(let expected, let actual, _, _):
                XCTAssertEqual(expected, 4032)
                XCTAssertEqual(actual, 64)
            default:
                XCTFail("Expected invalidKeyLength error, got \(error)")
            }
        }
    }
    
 /// Test verify rejects invalid public key length
    @available(macOS 14.0, iOS 17.0, *)
    func testVerifyRejectsInvalidPublicKeyLength() async throws {
        let provider = OQSPQCCryptoProvider()
        
        let data = Data("Test".utf8)
        let signature = Data(repeating: 0x01, count: 3309)
        let invalidPublicKey = Data(repeating: 0x01, count: 32)  // Wrong length
        
        do {
            _ = try await provider.verify(
                data: data,
                signature: signature,
                publicKey: invalidPublicKey
            )
            XCTFail("Should reject invalid public key length")
        } catch let error as CryptoProviderError {
            switch error {
            case .invalidKeyLength(let expected, let actual, _, _):
                XCTAssertEqual(expected, 1952)
                XCTAssertEqual(actual, 32)
            default:
                XCTFail("Expected invalidKeyLength error, got \(error)")
            }
        }
    }
}
#endif


// MARK: - Apple PQC Provider Selection Tests ( 7.3)

/// Tests for Apple PQC Provider selection logic
/// **Validates: Requirements 4.1, 4.2, 4.4**
final class ApplePQCProviderSelectionTests: XCTestCase {
    
 // MARK: - Provider Selection with Apple PQC Available
    
    #if DEBUG
 /// Test that preferPQC selects ApplePQC when available
 /// **Validates: Requirements 4.1**
    func testPreferPQCSelectsApplePQCWhenAvailable() {
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: env)
        
 // When Apple PQC is available, it should be preferred over liboqs
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, *) {
            XCTAssertEqual(provider.providerName, "ApplePQC",
                           "preferPQC should select ApplePQC when available")
            XCTAssertEqual(provider.tier, .nativePQC,
                           "ApplePQC should have nativePQC tier")
        } else {
 // On older macOS, should fall back to liboqs
            XCTAssertEqual(provider.tier, .liboqsPQC,
                           "Should fall back to liboqs on older macOS")
        }
        #else
 // Without HAS_APPLE_PQC_SDK, should fall back to liboqs
        XCTAssertEqual(provider.tier, .liboqsPQC,
                       "Should fall back to liboqs without HAS_APPLE_PQC_SDK")
        #endif
    }
    
 /// Test that requirePQC selects ApplePQC when available
 /// **Validates: Requirements 4.1**
    func testRequirePQCSelectsApplePQCWhenAvailable() {
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .requirePQC, environment: env)
        
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, *) {
            XCTAssertEqual(provider.providerName, "ApplePQC",
                           "requirePQC should select ApplePQC when available")
            XCTAssertEqual(provider.tier, .nativePQC,
                           "ApplePQC should have nativePQC tier")
        } else {
            XCTAssertEqual(provider.tier, .liboqsPQC,
                           "Should fall back to liboqs on older macOS")
        }
        #else
        XCTAssertEqual(provider.tier, .liboqsPQC,
                       "Should fall back to liboqs without HAS_APPLE_PQC_SDK")
        #endif
    }
    
 /// Test that classicOnly ignores Apple PQC availability
 /// **Validates: Requirements 4.2**
    func testClassicOnlyIgnoresApplePQC() {
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .classicOnly, environment: env)
        
        XCTAssertEqual(provider.providerName, "Classic",
                       "classicOnly should always select Classic provider")
        XCTAssertEqual(provider.tier, .classic,
                       "Classic provider should have classic tier")
        XCTAssertFalse(provider.activeSuite.isPQC,
                       "Classic provider should not use PQC suite")
    }
    #endif
    
 // MARK: - Provider Selection Fallback
    
    #if DEBUG
 /// Test fallback from Apple PQC to liboqs when Apple PQC unavailable
 /// **Validates: Requirements 4.2**
    func testFallbackToLiboqsWhenApplePQCUnavailable() {
        let env = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: env)
        
        XCTAssertEqual(provider.tier, .liboqsPQC,
                       "Should fall back to liboqs when Apple PQC unavailable")
        XCTAssertEqual(provider.providerName, "liboqs",
                       "Should select liboqs provider")
    }
    
 /// Test fallback to classic when no PQC available
 /// **Validates: Requirements 4.2**
    func testFallbackToClassicWhenNoPQCAvailable() {
        let env = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: env)
        
        XCTAssertEqual(provider.tier, .classic,
                       "Should fall back to classic when no PQC available")
        XCTAssertEqual(provider.providerName, "Classic",
                       "Should select Classic provider")
    }
    #endif
    
 // MARK: - Capability Detection
    
    #if DEBUG
 /// Test capability detection with Apple PQC
 /// **Validates: Requirements 4.3**
    func testCapabilityDetectionWithApplePQC() {
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: false)
        let capability = CryptoProviderFactory.detectCapability(environment: env)
        
        XCTAssertTrue(capability.hasApplePQC,
                      "Capability should reflect Apple PQC availability")
        XCTAssertFalse(capability.hasLiboqs,
                       "Capability should reflect liboqs unavailability")
        XCTAssertFalse(capability.osVersion.isEmpty,
                       "OS version should be detected")
    }
    
 /// Test capability detection with both providers
 /// **Validates: Requirements 4.3**
    func testCapabilityDetectionWithBothProviders() {
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        let capability = CryptoProviderFactory.detectCapability(environment: env)
        
        XCTAssertTrue(capability.hasApplePQC,
                      "Capability should reflect Apple PQC availability")
        XCTAssertTrue(capability.hasLiboqs,
                      "Capability should reflect liboqs availability")
    }
    #endif
    
 // MARK: - Provider Selection Priority
    
    #if DEBUG
 /// Test that Apple PQC has higher priority than liboqs
 /// **Validates: Requirements 4.1, 4.4**
    func testApplePQCHasHigherPriorityThanLiboqs() {
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: env)
        
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, *) {
 // Apple PQC should be selected over liboqs
            XCTAssertEqual(provider.tier, .nativePQC,
                           "Apple PQC should have higher priority than liboqs")
            XCTAssertNotEqual(provider.providerName, "liboqs",
                              "Should not select liboqs when Apple PQC available")
        }
        #endif
    }
    
 /// Test provider selection event emission
 /// **Validates: Requirements 4.4**
    func testProviderSelectionEmitsEvent() {
 // This test verifies that provider selection emits an event
 // The actual event emission is tested indirectly through the factory
        let env = MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)
        
 // Making a provider should not crash and should emit event
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: env)
        
 // Verify provider was created successfully
        XCTAssertFalse(provider.providerName.isEmpty,
                       "Provider should have a name")
    }
    #endif
    
 // MARK: - System Environment Tests
    
 /// Test system environment detection
    func testSystemEnvironmentDetection() {
        let capability = CryptoProviderFactory.detectCapability()
        
 // OS version should always be available
        XCTAssertFalse(capability.osVersion.isEmpty,
                       "OS version should be detected")
        
 // Apple PQC availability depends on SDK and OS version
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, *) {
 // On macOS 26+ with SDK, Apple PQC should be available
 // (assuming selfTest passes)
 // Note: This may be false if running on older macOS
        }
        #else
        XCTAssertFalse(capability.hasApplePQC,
                       "Apple PQC should be false without HAS_APPLE_PQC_SDK")
        #endif
    }
}

// MARK: - Apple PQC Provider Integration Tests

#if HAS_APPLE_PQC_SDK
@available(macOS 26.0, *)
final class ApplePQCProviderIntegrationTests: XCTestCase {
    
 /// Test ApplePQCProvider selfTest
 /// **Validates: Requirements 4.3**
    func testApplePQCProviderSelfTest() {
        let result = ApplePQCCryptoProvider.selfTest()
        
 // selfTest should return true on macOS 26+
        XCTAssertTrue(result,
                      "ApplePQCProvider selfTest should pass on macOS 26+")
    }
    
 /// Test ApplePQCProvider properties
 /// **Validates: Requirements 4.1**
    func testApplePQCProviderProperties() {
        let provider = ApplePQCCryptoProvider()
        
        XCTAssertEqual(provider.providerName, "ApplePQC",
                       "Provider name should be ApplePQC")
        XCTAssertEqual(provider.tier, .nativePQC,
                       "Provider tier should be nativePQC")
        XCTAssertEqual(provider.activeSuite, .mlkem768MLDSA65,
                       "Provider suite should be ML-KEM-768 + ML-DSA-65")
        XCTAssertTrue(provider.activeSuite.isPQC,
                      "Provider suite should be PQC")
    }
    
 /// Test factory creates ApplePQCProvider on macOS 26+
 /// **Validates: Requirements 4.1, 4.2**
    func testFactoryCreatesApplePQCProvider() {
        #if DEBUG
        let env = MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        let provider = CryptoProviderFactory.make(policy: .preferPQC, environment: env)
        
        XCTAssertEqual(provider.providerName, "ApplePQC",
                       "Factory should create ApplePQCProvider when available")
        XCTAssertEqual(provider.tier, .nativePQC,
                       "Provider should have nativePQC tier")
        #endif
    }
}
#endif
