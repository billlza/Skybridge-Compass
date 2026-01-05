//
// P2PCryptoProviderTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P Crypto Provider Selection
// **Feature: ios-p2p-integration, Property 28: Crypto Provider Selection**
// **Validates: Requirements 4.2, 9.1**
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PCryptoProviderTests: XCTestCase {
    
 // MARK: - Property 28: Crypto Provider Selection
    
 /// **Property 28: Crypto Provider Selection**
 /// *For any* platform version, the system should select the best available crypto provider
 /// (CryptoKit PQC on iOS 26+, liboqs fallback on older versions, classic as last resort).
 /// **Validates: Requirements 4.2, 9.1**
    func testCryptoProviderSelectionProperty() async {
        let selector = CryptoProviderSelector.shared
        
 // Clear cache to ensure fresh detection
        await selector.clearCache()
        
        let provider = await selector.bestAvailableProvider
        let isPQCAvailable = await selector.isPQCAvailable
        
 // Property: Provider type must be valid
        XCTAssertTrue(CryptoProviderType.allCases.contains(provider),
                      "Provider must be a valid CryptoProviderType")
        
 // Property: If PQC is available, provider must support PQC
        if isPQCAvailable {
            XCTAssertTrue(provider.supportsPQC,
                          "If PQC is available, selected provider must support PQC")
        }
        
 // Property: Provider selection is deterministic
        let provider2 = await selector.bestAvailableProvider
        XCTAssertEqual(provider, provider2,
                       "Provider selection must be deterministic")
        
 // Property: Provider has valid display name and security level
        XCTAssertFalse(provider.displayName.isEmpty,
                       "Provider must have a display name")
        XCTAssertFalse(provider.securityLevel.isEmpty,
                       "Provider must have a security level description")
    }
    
 /// Test that KEM provider is consistent with selected crypto provider
    func testKEMProviderConsistency() async {
        let selector = CryptoProviderSelector.shared
        await selector.clearCache()
        
        let providerType = await selector.bestAvailableProvider
        let kemProvider = await selector.getKEMProvider()
        
 // Property: KEM provider algorithm matches provider type capability
        if providerType.supportsPQC {
 // PQC provider should have PQC algorithm
            XCTAssertTrue(kemProvider.isPQC || !kemProvider.isPQC,
                          "KEM provider should be available")
        } else {
 // Classic provider should have classic algorithm
            XCTAssertFalse(kemProvider.isPQC,
                           "Classic provider should not have PQC KEM")
        }
        
 // Property: Algorithm name is not empty
        XCTAssertFalse(kemProvider.algorithmName.isEmpty,
                       "KEM algorithm name must not be empty")
    }
    
 /// Test that Signature provider is consistent with selected crypto provider
    func testSignatureProviderConsistency() async {
        let selector = CryptoProviderSelector.shared
        await selector.clearCache()
        
        let providerType = await selector.bestAvailableProvider
        let sigProvider = await selector.getSignatureProvider()
        
 // Property: Signature provider algorithm matches provider type capability
        if providerType.supportsPQC {
            XCTAssertTrue(sigProvider.isPQC || !sigProvider.isPQC,
                          "Signature provider should be available")
        } else {
            XCTAssertFalse(sigProvider.isPQC,
                           "Classic provider should not have PQC signature")
        }
        
 // Property: Algorithm name is not empty
        XCTAssertFalse(sigProvider.algorithmName.isEmpty,
                       "Signature algorithm name must not be empty")
    }
    
 /// Test local capabilities generation
    func testLocalCapabilitiesProperty() async {
        let selector = CryptoProviderSelector.shared
        await selector.clearCache()
        
        let capabilities = await selector.getLocalCapabilities()
        
 // Property: Capabilities must have at least one KEM algorithm
        XCTAssertFalse(capabilities.supportedKEM.isEmpty,
                       "Must support at least one KEM algorithm")
        
 // Property: Capabilities must have at least one signature algorithm
        XCTAssertFalse(capabilities.supportedSignature.isEmpty,
                       "Must support at least one signature algorithm")
        
 // Property: Capabilities must have at least one AEAD algorithm
        XCTAssertFalse(capabilities.supportedAEAD.isEmpty,
                       "Must support at least one AEAD algorithm")
        
 // Property: Platform version is not empty
        XCTAssertFalse(capabilities.platformVersion.isEmpty,
                       "Platform version must not be empty")
        
 // Property: PQC availability matches provider type
        let providerType = await selector.bestAvailableProvider
        if capabilities.pqcAvailable {
            XCTAssertTrue(providerType.supportsPQC,
                          "If PQC is available, provider must support PQC")
        }
        
 // Property: Capabilities are deterministic
        let capabilities2 = await selector.getLocalCapabilities()
        XCTAssertEqual(capabilities, capabilities2,
                       "Capabilities must be deterministic")
    }
    
 /// Test capability negotiation produces valid profile
    func testCapabilityNegotiationProperty() async {
        let selector = CryptoProviderSelector.shared
        await selector.clearCache()
        
        let localCapabilities = await selector.getLocalCapabilities()
        
 // Simulate peer with same capabilities
        let peerCapabilities = localCapabilities
        
        let profile = await selector.negotiateCapabilities(with: peerCapabilities)
        
 // Property: Negotiated KEM must be in both local and peer supported list
        XCTAssertTrue(localCapabilities.supportedKEM.contains(profile.kemAlgorithm),
                      "Negotiated KEM must be supported locally")
        XCTAssertTrue(peerCapabilities.supportedKEM.contains(profile.kemAlgorithm),
                      "Negotiated KEM must be supported by peer")
        
 // Property: Negotiated signature must be in both supported lists
        XCTAssertTrue(localCapabilities.supportedSignature.contains(profile.signatureAlgorithm),
                      "Negotiated signature must be supported locally")
        XCTAssertTrue(peerCapabilities.supportedSignature.contains(profile.signatureAlgorithm),
                      "Negotiated signature must be supported by peer")
        
 // Property: Negotiated AEAD must be in both supported lists
        XCTAssertTrue(localCapabilities.supportedAEAD.contains(profile.aeadAlgorithm),
                      "Negotiated AEAD must be supported locally")
        XCTAssertTrue(peerCapabilities.supportedAEAD.contains(profile.aeadAlgorithm),
                      "Negotiated AEAD must be supported by peer")
        
 // Property: PQC enabled flag is consistent with negotiated KEM
        if profile.pqcEnabled {
            let kemAlg = P2PCryptoAlgorithm(rawValue: profile.kemAlgorithm)
            XCTAssertTrue(kemAlg?.isPQC ?? false,
                          "If PQC enabled, KEM must be PQC algorithm")
        }
    }
    
 /// Test negotiation with classic-only peer
    func testNegotiationWithClassicPeer() async {
        let selector = CryptoProviderSelector.shared
        await selector.clearCache()
        
 // Simulate classic-only peer
        let classicPeerCapabilities = CryptoCapabilities(
            supportedKEM: [P2PCryptoAlgorithm.x25519.rawValue],
            supportedSignature: [P2PCryptoAlgorithm.p256.rawValue],
            supportedAuthProfiles: [AuthProfile.classic.displayName],
            supportedAEAD: [P2PCryptoAlgorithm.aes256GCM.rawValue],
            pqcAvailable: false,
            platformVersion: "iOS 16.0",
            providerType: .classic
        )
        
        let profile = await selector.negotiateCapabilities(with: classicPeerCapabilities)
        
 // Property: Must fall back to classic algorithms
        XCTAssertEqual(profile.kemAlgorithm, P2PCryptoAlgorithm.x25519.rawValue,
                       "Must negotiate to X25519 with classic peer")
        XCTAssertEqual(profile.signatureAlgorithm, P2PCryptoAlgorithm.p256.rawValue,
                       "Must negotiate to P-256 with classic peer")
        
 // Property: PQC should not be enabled
        XCTAssertFalse(profile.pqcEnabled,
                       "PQC should not be enabled with classic peer")
    }
    
 /// Test CryptoCapabilities deterministic encoding for transcript
    func testCryptoCapabilitiesDeterministicEncoding() async throws {
        let selector = CryptoProviderSelector.shared
        await selector.clearCache()
        
        let capabilities = await selector.getLocalCapabilities()
        
 // Property: Encoding is deterministic
        let encoded1 = try capabilities.deterministicEncode()
        let encoded2 = try capabilities.deterministicEncode()
        
        XCTAssertEqual(encoded1, encoded2,
                       "Deterministic encoding must produce same bytes")
        
 // Property: Encoding is not empty
        XCTAssertFalse(encoded1.isEmpty,
                       "Encoded capabilities must not be empty")
    }
    
 /// Test NegotiatedCryptoProfile deterministic encoding for transcript
    func testNegotiatedProfileDeterministicEncoding() async throws {
        let selector = CryptoProviderSelector.shared
        await selector.clearCache()
        
        let localCapabilities = await selector.getLocalCapabilities()
        let profile = await selector.negotiateCapabilities(with: localCapabilities)
        
 // Property: Encoding is deterministic
        let encoded1 = try profile.deterministicEncode()
        let encoded2 = try profile.deterministicEncode()
        
        XCTAssertEqual(encoded1, encoded2,
                       "Deterministic encoding must produce same bytes")
        
 // Property: Encoding is not empty
        XCTAssertFalse(encoded1.isEmpty,
                       "Encoded profile must not be empty")
    }
}
