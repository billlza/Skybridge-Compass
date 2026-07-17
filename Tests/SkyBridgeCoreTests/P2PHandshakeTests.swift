import XCTest
@testable import SkyBridgeCore

@MainActor
@available(*, deprecated, message: "Legacy handshake compatibility regression tests.")
final class P2PHandshakeTests: XCTestCase {
    func testKEMHandshakeStoresSessionKeys() async throws {
        let keychain = PQCKeychainTestContext()
        let provider = try XCTUnwrap(
            PQCProviderFactory.makeProvider(scopeSource: keychain.scopeSource),
            "The test target declares a PQC backend, so the legacy KEM fixture must not silently skip"
        )
        let deviceId = "peer-B"
        let storageBackend: PQCKeyPairStoreBackend
        switch provider.backend {
        case .applePQC:
            storageBackend = .appleCryptoKit
        case .liboqs:
            storageBackend = .liboqs
        case .none:
            return XCTFail("A resolved PQC provider must expose a concrete persistence backend")
        }
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: storageBackend,
            purpose: .kem,
            algorithm: "ML-KEM-768",
            identity: deviceId,
            storageScope: keychain.storageScope
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try PQCBackendAuthorityStore.deleteForTesting(
                domain: .quantumAdapter,
                scopeSource: keychain.scopeSource
            )
        }
        let secA = P2PSecurityManager(
            sharedIdentityScopeSource: keychain.scopeSource
        )
        let secB = P2PSecurityManager(
            sharedIdentityScopeSource: keychain.scopeSource
        )
        try await secA.start()
        try await secB.start()
        let hmA = P2PHandshakeManager(security: secA)
        let hmB = P2PHandshakeManager(security: secB)
        let encapsulated = try await hmA.initiate(deviceId: deviceId)
        try await hmB.complete(deviceId: deviceId, encapsulated: encapsulated)
        XCTAssertTrue(secA.hasSessionKey(for: deviceId))
        XCTAssertTrue(secB.hasSessionKey(for: deviceId))
    }
}
