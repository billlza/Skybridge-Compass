import XCTest
@testable import SkyBridgeCore
import CryptoKit

@available(macOS 14.0, *)
func requireMLKEMMLDSAProvider(
    scopeSource: SkyBridgeSharedIdentityScopeSource,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> any PQCProvider {
    #if canImport(OQSRAII) || HAS_APPLE_PQC_SDK
    return try XCTUnwrap(
        PQCProviderFactory.makeProvider(scopeSource: scopeSource),
        "The test target declares a PQC backend, so the ML-KEM/ML-DSA provider must be available",
        file: file,
        line: line
    )
    #else
    throw XCTSkip("These tests require a compiled ML-KEM/ML-DSA backend")
    #endif
}

@available(macOS 14.0, *)
func makePQCProtocolAdapterForTesting(
    keychain: PQCKeychainTestContext = PQCKeychainTestContext(),
    suite: CrossPlatformPQCSuite? = nil
) throws -> PQCProtocolAdapter {
    let provider = try requireMLKEMMLDSAProvider(
        scopeSource: keychain.scopeSource
    )
    return PQCProtocolAdapter(provider: provider, suite: suite)
}

func isMissingAuthenticatedXWingKeyError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "PQC" && (nsError.code == -918 || nsError.code == -919)
}

@available(macOS 14.0, *)
func authenticateLocalSigningKeyForTesting(
    signer: any PQCProvider,
    verifier: any PQCProvider,
    peerId: String,
    algorithm: String = "ML-DSA-65"
) async throws -> Data {
    let source = try XCTUnwrap(
        signer as? any PQCLocalSigningPublicKeyProviding,
        "The signer must expose the public half of its local test identity"
    )
    let consumer = try XCTUnwrap(
        verifier as? any AuthenticatedPQCSigningKeyConsumer,
        "The verifier must accept a key authenticated by the test trust boundary"
    )
    let publicKey = try await source.localSigningPublicKey(
        peerId: peerId,
        algorithm: algorithm
    )
    try await consumer.registerAuthenticatedSigningPublicKey(
        publicKey,
        peerId: peerId,
        algorithm: algorithm
    )
    return publicKey
}

@MainActor
@available(macOS 14.0, iOS 17.0, *)
func installAuthenticatedMLDSATrustRecordForTesting(
    peerId: String,
    publicKey: Data
) async throws -> TrustSyncService {
    let fingerprint = ProtocolIdentityBinding.computeFingerprint(
        algorithm: .mlDSA65,
        publicKeyBytes: publicKey
    )
    let trust = TrustSyncService.shared
    trust.setInMemoryPersistenceForTesting(true)
    await trust.removeRecordsForTesting(deviceIds: [peerId])
    _ = try await trust.addTrustRecord(
        TrustRecord(
            deviceId: peerId,
            pubKeyFP: fingerprint,
            publicKey: publicKey,
            protocolPublicKey: publicKey,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint,
            protocolIdentityPins: [
                ProtocolIdentityPin(
                    algorithm: .mlDSA65,
                    fingerprint: fingerprint,
                    source: .authenticatedHandshake
                )
            ],
            signature: Data(),
            currentDeviceId: peerId,
            knownDeviceIds: [peerId],
            lifecycleState: .active
        )
    )
    return trust
}

@available(macOS 14.0, *)
struct AuthenticatedHPKETestFixture {
    let peerId: String
    let sender: any PQCProvider
    let recipient: any PQCProvider
    let keychain: PQCKeychainTestContext

    static func make(
        peerId: String = "hpke-fixture-\(UUID().uuidString)",
        keychain: PQCKeychainTestContext = PQCKeychainTestContext()
    ) async throws -> Self {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
            let fixture = try await AuthenticatedXWingHPKEFixture.make(
                peerId: peerId,
                keychain: keychain
            )
            return Self(
                peerId: peerId,
                sender: fixture.sender,
                recipient: fixture.recipient,
                keychain: keychain
            )
        }
        #endif

        let provider = try requireMLKEMMLDSAProvider(
            scopeSource: keychain.scopeSource
        )
        return Self(
            peerId: peerId,
            sender: provider,
            recipient: provider,
            keychain: keychain
        )
    }
}

#if HAS_APPLE_PQC_SDK
@available(macOS 26.0, iOS 26.0, *)
struct AuthenticatedXWingHPKEFixture {
    let peerId: String
    let sender: ApplePQCProvider
    let recipient: ApplePQCProvider
    let keychain: PQCKeychainTestContext

    static func make(
        peerId: String = "hpke-fixture-\(UUID().uuidString)",
        keychain: PQCKeychainTestContext = PQCKeychainTestContext()
    ) async throws -> Self {
        guard let sender = PQCProviderFactory.makeProvider(
            for: .hybridXWing,
            scopeSource: keychain.scopeSource
        ) as? ApplePQCProvider,
        let recipient = PQCProviderFactory.makeProvider(
            for: .hybridXWing,
            scopeSource: keychain.scopeSource
        ) as? ApplePQCProvider else {
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
        return Self(
            peerId: peerId,
            sender: sender,
            recipient: recipient,
            keychain: keychain
        )
    }
}
#endif
