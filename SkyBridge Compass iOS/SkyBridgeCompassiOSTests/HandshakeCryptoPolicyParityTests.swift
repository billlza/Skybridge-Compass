import XCTest
import Darwin
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class HandshakeCryptoPolicyParityTests: XCTestCase {
    func testPrepareAttemptForXWingCarriesHybridCryptoPolicy() throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: AppleXWingCryptoProvider()
        )

        XCTAssertEqual(preparation.offeredSuites, [.xwing])
        XCTAssertEqual(preparation.cryptoPolicy.minimumSecurityTier, .hybridPreferred)
        XCTAssertTrue(preparation.cryptoPolicy.allowExperimentalHybrid)
        XCTAssertTrue(preparation.cryptoPolicy.advertiseHybrid)
        XCTAssertTrue(preparation.cryptoPolicy.requireHybridIfAvailable)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testPrepareAttemptCompatibilityRetryDropsToPurePQCWhenXWingWasPreferred() throws {
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: MockNativeHybridProvider(),
            pqcOfferMode: .compatRetry
        )

        XCTAssertEqual(preparation.offeredSuites, [.mlkem768])
        XCTAssertEqual(preparation.cryptoPolicy, .default)
    }

    func testExplicitXWingPreferenceDoesNotSilentlyOfferMLKEMOnLiboqsProvider() throws {
        setenv("SB_PQC_PREFERRED_SUITE", "xwing", 1)
        defer { unsetenv("SB_PQC_PREFERRED_SUITE") }

        XCTAssertThrowsError(
            try TwoAttemptHandshakeManager.prepareAttempt(
                strategy: .pqcOnly,
                cryptoProvider: MockLiboqsPQCProvider()
            )
        ) { error in
            guard case AttemptPreparationError.pqcProviderUnavailable = error else {
                XCTFail("Expected pqcProviderUnavailable, got \(error)")
                return
            }
        }
    }

    func testStrictPQCDoesNotRetryPurePQCCompatibilityAfterXWingFailure() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "xwing-strict-device",
                preferPQC: true,
                policy: .strictPQC,
                cryptoProvider: provider
            ) { preparation in
                let attempt = await tracker.record(preparation.offeredSuites)
                XCTAssertEqual(attempt, 1)
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            XCTFail("strictPQC must fail fast instead of retrying a compatibility suite")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }

        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts, [initialPreparation.offeredSuites])
    }

    func testDefaultPolicyRetriesPurePQCBeforeClassicFallback() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        let keys = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
            deviceId: "xwing-compat-device",
            preferPQC: true,
            policy: .default,
            cryptoProvider: provider
        ) { preparation in
            let attempt = await tracker.record(preparation.offeredSuites)
            if attempt == 1 {
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }

            XCTAssertEqual(preparation.offeredSuites, [.mlkem768])
            return Self.makeSessionKeys(suite: .mlkem768)
        }

        XCTAssertEqual(keys.negotiatedSuite, .mlkem768)
        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], initialPreparation.offeredSuites)
        XCTAssertEqual(attempts[1], [.mlkem768])
    }

    func testMissingPeerKEMForPreferredXWingDoesNotRetryPureMLKEM() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "xwing-missing-kem-device",
                preferPQC: true,
                policy: .default,
                cryptoProvider: provider
            ) { preparation in
                let attempt = await tracker.record(preparation.offeredSuites)
                XCTAssertEqual(attempt, 1)
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: CryptoSuite.xwing.rawValue))
            }
            XCTFail("missing peer KEM must surface as provisioning failure, not retry another PQC suite")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .missingPeerKEMPublicKey(suite: CryptoSuite.xwing.rawValue))
        }

        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts, [initialPreparation.offeredSuites])
    }

    func testSuiteNotSupportedDoesNotFallbackOrRetry() async throws {
        let tracker = AttemptTracker()
        let provider = MockNativeHybridProvider()
        let initialPreparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )

        XCTAssertFalse(
            TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNotSupported),
            "Unsupported or unknown wire suites must fail closed instead of becoming fallback-eligible."
        )

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "unsupported-suite-device",
                preferPQC: true,
                policy: .default,
                cryptoProvider: provider
            ) { preparation in
                let attempt = await tracker.record(preparation.offeredSuites)
                XCTAssertEqual(attempt, 1)
                XCTAssertEqual(preparation.offeredSuites, initialPreparation.offeredSuites)
                throw HandshakeError.failed(.suiteNotSupported)
            }
            XCTFail("suiteNotSupported must fail without compatibility retry or classic fallback")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNotSupported)
        }

        let attempts = await tracker.snapshot()
        XCTAssertEqual(attempts, [initialPreparation.offeredSuites])
    }

    func testResponderSelectionRejectsXWingWhenAttemptDidNotEnableHybrid() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple PQC provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: ApplePQCCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x11, count: 32),
            policy: .strictPQC,
            cryptoPolicy: .default
        )

        let messageA = makeMessageA(supportedSuites: [.xwing], keyShareSuites: [.xwing])

        do {
            _ = try await context.selectResponderSuite(for: messageA)
            XCTFail("Expected X-Wing to be rejected when hybrid policy is disabled")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionAcceptsXWingWhenResolverEnabledHybrid() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: AppleXWingCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x22, count: 32),
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing])
        )

        let messageA = makeMessageA(supportedSuites: [.xwing], keyShareSuites: [.xwing])
        let selected = try await context.selectResponderSuite(for: messageA)

        XCTAssertEqual(selected, .xwing)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionPrefersHybridWhenPolicyRequiresIt() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: AppleXWingCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x33, count: 32),
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing, .mlkem768])
        )

        let messageA = makeMessageA(
            supportedSuites: [.xwing, .mlkem768],
            keyShareSuites: [.xwing, .mlkem768]
        )
        let selected = try await context.selectResponderSuite(for: messageA)

        XCTAssertEqual(selected, .xwing)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    private func makeMessageA(
        supportedSuites: [CryptoSuite],
        keyShareSuites: [CryptoSuite]
    ) -> HandshakeMessageA {
        let keyShares = keyShareSuites.map { suite in
            HandshakeKeyShare(
                suite: suite,
                shareBytes: Data(repeating: UInt8(truncatingIfNeeded: suite.wireId & 0x00FF), count: 32)
            )
        }

        return HandshakeMessageA(
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: Data(repeating: 0x44, count: HandshakeConstants.nonceSize),
            policy: .strictPQC,
            capabilities: CryptoCapabilities(),
            signature: Data(),
            identityPublicKey: Data(repeating: 0x55, count: 32)
        )
    }

    private static func makeSessionKeys(suite: CryptoSuite) -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: suite,
            transcriptHash: Data(repeating: 0x33, count: 32)
        )
    }
}

@available(iOS 17.0, *)
private struct MockNativeHybridProvider: CryptoProvider, Sendable {
    let providerName = "MockNativeHybridProvider"
    let tier: CryptoTier = .nativePQC
    let activeSuite: CryptoSuite = .xwing
    let supportedSuites: [CryptoSuite] = [.xwing]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains(where: { $0.wireId == suite.wireId })
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.hpkeSeal")
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemDemSealWithSecret")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.hpkeOpen(data)")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.hpkeOpen(secure)")
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemDemOpenWithSecret")
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemEncapsulate")
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.kemDecapsulate")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.sign")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.unsupportedOperation("MockNativeHybridProvider.generateKeyPair")
    }
}

@available(iOS 17.0, *)
private struct MockLiboqsPQCProvider: CryptoProvider, Sendable {
    let providerName = "MockLiboqsPQCProvider"
    let tier: CryptoTier = .liboqsPQC
    let activeSuite: CryptoSuite = .mlkem768
    let supportedSuites: [CryptoSuite] = [.mlkem768]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains(where: { $0.wireId == suite.wireId })
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.hpkeSeal")
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemDemSealWithSecret")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.hpkeOpen(data)")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.hpkeOpen(secure)")
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemDemOpenWithSecret")
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemEncapsulate")
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.kemDecapsulate")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.sign")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.unsupportedOperation("MockLiboqsPQCProvider.generateKeyPair")
    }
}

@available(iOS 17.0, *)
private actor AttemptTracker {
    private var offeredSuitesByAttempt: [[CryptoSuite]] = []

    func record(_ offeredSuites: [CryptoSuite]) -> Int {
        offeredSuitesByAttempt.append(offeredSuites)
        return offeredSuitesByAttempt.count
    }

    func snapshot() -> [[CryptoSuite]] {
        offeredSuitesByAttempt
    }
}
