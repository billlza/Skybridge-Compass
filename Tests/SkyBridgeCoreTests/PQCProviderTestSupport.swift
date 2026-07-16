import XCTest
@testable import SkyBridgeCore
#if HAS_APPLE_PQC_SDK
import CryptoKit
#endif

@available(macOS 14.0, *)
func requireMLKEMMLDSAProvider(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> any PQCProvider {
    #if canImport(OQSRAII) || HAS_APPLE_PQC_SDK
    return try XCTUnwrap(
        PQCProviderFactory.makeProvider(),
        "The test target declares a PQC backend, so the ML-KEM/ML-DSA provider must be available",
        file: file,
        line: line
    )
    #else
    throw XCTSkip("These tests require a compiled ML-KEM/ML-DSA backend")
    #endif
}

func isMissingAuthenticatedXWingKeyError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "PQC" && (nsError.code == -918 || nsError.code == -919)
}

@available(macOS 14.0, *)
struct AuthenticatedHPKETestFixture {
    let peerId: String
    let sender: any PQCProvider
    let recipient: any PQCProvider

    static func make(peerId: String = "hpke-fixture-\(UUID().uuidString)") async throws -> Self {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
            let fixture = try await AuthenticatedXWingHPKEFixture.make(peerId: peerId)
            return Self(peerId: peerId, sender: fixture.sender, recipient: fixture.recipient)
        }
        #endif

        let provider = try requireMLKEMMLDSAProvider()
        return Self(peerId: peerId, sender: provider, recipient: provider)
    }
}

#if HAS_APPLE_PQC_SDK
@available(macOS 26.0, iOS 26.0, *)
struct AuthenticatedXWingHPKEFixture {
    let peerId: String
    let sender: ApplePQCProvider
    let recipient: ApplePQCProvider

    static func make(peerId: String = "hpke-fixture-\(UUID().uuidString)") async throws -> Self {
        guard let sender = PQCProviderFactory.makeProvider(for: .hybridXWing) as? ApplePQCProvider,
              let recipient = PQCProviderFactory.makeProvider(for: .hybridXWing) as? ApplePQCProvider else {
            throw XCTSkip("The authenticated X-Wing HPKE provider is unavailable")
        }

        let recipientPrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        try await sender.setAuthenticatedXWingRecipientPublicKey(
            recipientPrivateKey.publicKey,
            for: peerId
        )
        try await recipient.setLocalXWingRecipientPrivateKey(
            recipientPrivateKey,
            for: peerId
        )
        return Self(peerId: peerId, sender: sender, recipient: recipient)
    }
}
#endif
