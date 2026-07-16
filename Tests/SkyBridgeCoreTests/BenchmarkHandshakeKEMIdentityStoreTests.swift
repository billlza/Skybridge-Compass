import Foundation
import XCTest
@testable import SkyBridgeCore
import SkyBridgeBenchmarkSupport

@available(macOS 14.0, iOS 17.0, *)
final class BenchmarkHandshakeKEMIdentityStoreTests: XCTestCase {
    func testProviderBindingMismatchesFailClosed() async throws {
        let creationCounter = GenerationCounter()
        let creationProvider = TestCryptoProvider(
            providerName: "native-mlkem",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.mlkemKeyPair(),
            generationCounter: creationCounter
        )
        let store = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.mlkem768MLDSA65],
            provider: creationProvider
        )

        let differentNameProvider = TestCryptoProvider(
            providerName: "different-native-mlkem",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.mlkemKeyPair()
        )
        await assertUnsupportedAlgorithm {
            _ = try await store.getOrCreateKEMIdentityKey(
                for: .mlkem768MLDSA65,
                provider: differentNameProvider
            )
        }

        let differentTierProvider = TestCryptoProvider(
            providerName: creationProvider.providerName,
            tier: .liboqsPQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.mlkemKeyPair(privateKeyLength: 2_400)
        )
        await assertUnsupportedAlgorithm {
            _ = try await store.getOrCreateKEMIdentityKey(
                for: .mlkem768MLDSA65,
                provider: differentTierProvider
            )
        }

        let differentActiveSuiteProvider = TestCryptoProvider(
            providerName: creationProvider.providerName,
            tier: creationProvider.tier,
            activeSuite: .xwingMLDSA,
            supportedSuites: [.mlkem768MLDSA65, .xwingMLDSA],
            generatedKeyPair: Self.xwingKeyPair()
        )
        await assertUnsupportedAlgorithm {
            _ = try await store.getOrCreateKEMIdentityKey(
                for: .mlkem768MLDSA65,
                provider: differentActiveSuiteProvider
            )
        }

        let differentConcreteTypeProvider = AlternateTestCryptoProvider(
            base: TestCryptoProvider(
                providerName: creationProvider.providerName,
                tier: creationProvider.tier,
                activeSuite: creationProvider.activeSuite,
                supportedSuites: creationProvider.supportedSuites,
                generatedKeyPair: Self.mlkemKeyPair()
            )
        )
        await assertUnsupportedAlgorithm {
            _ = try await store.getOrCreateKEMIdentityKey(
                for: .mlkem768MLDSA65,
                provider: differentConcreteTypeProvider
            )
        }

        let generationCount = await creationCounter.value
        XCTAssertEqual(generationCount, 1)
    }

    func testUnsupportedAdmissionAndLateralSuiteLookupFailClosed() async throws {
        let unsupportedCounter = GenerationCounter()
        let mlkemOnlyProvider = TestCryptoProvider(
            providerName: "mlkem-only",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.mlkemKeyPair(),
            generationCounter: unsupportedCounter
        )

        await assertUnsupportedAlgorithm {
            _ = try await BenchmarkHandshakeKEMIdentityStore.make(
                offeredSuites: [.xwingMLDSA],
                provider: mlkemOnlyProvider
            )
        }
        let unsupportedGenerationCount = await unsupportedCounter.value
        XCTAssertEqual(unsupportedGenerationCount, 0)

        let multiSuiteProvider = TestCryptoProvider(
            providerName: "multi-suite-native",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65, .xwingMLDSA],
            generatedKeyPair: Self.mlkemKeyPair()
        )
        let mlkemStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.mlkem768MLDSA65],
            provider: multiSuiteProvider
        )

        await assertUnsupportedAlgorithm {
            _ = try await mlkemStore.getOrCreateKEMIdentityKey(
                for: .xwingMLDSA,
                provider: multiSuiteProvider
            )
        }
        XCTAssertThrowsError(try mlkemStore.trustPublicKeys(for: [.xwingMLDSA])) { error in
            Self.assertUnsupportedAlgorithm(error)
        }
    }

    func testGeneratedKeyUsageAndSuiteMismatchesFailClosed() async {
        let wrongUsageProvider = TestCryptoProvider(
            providerName: "wrong-usage",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.keyPair(
                suite: .mlkem768MLDSA65,
                usage: .signing,
                publicKeyLength: 1_952,
                privateKeyLength: 64
            )
        )
        do {
            _ = try await BenchmarkHandshakeKEMIdentityStore.make(
                offeredSuites: [.mlkem768MLDSA65],
                provider: wrongUsageProvider
            )
            XCTFail("Expected signing material to be rejected for a KEM identity")
        } catch let error as CryptoProviderError {
            guard case .keyUsageMismatch(let expected, let actual) = error else {
                XCTFail("Expected keyUsageMismatch, got \(error)")
                return
            }
            XCTAssertEqual(expected, .keyExchange)
            XCTAssertEqual(actual, .signing)
        } catch {
            XCTFail("Expected CryptoProviderError, got \(error)")
        }

        let wrongSuiteProvider = TestCryptoProvider(
            providerName: "wrong-suite",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.xwingKeyPair()
        )
        await assertUnsupportedAlgorithm {
            _ = try await BenchmarkHandshakeKEMIdentityStore.make(
                offeredSuites: [.mlkem768MLDSA65],
                provider: wrongSuiteProvider
            )
        }
    }

    func testGeneratedPublicAndPrivateKeyLengthMismatchesFailClosed() async {
        let shortPublicKeyProvider = TestCryptoProvider(
            providerName: "short-public-key",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.mlkemKeyPair(publicKeyLength: 1_183)
        )
        await assertInvalidKeyLength(expected: 1_184, actual: 1_183) {
            _ = try await BenchmarkHandshakeKEMIdentityStore.make(
                offeredSuites: [.mlkem768MLDSA65],
                provider: shortPublicKeyProvider
            )
        }

        let shortPrivateKeyProvider = TestCryptoProvider(
            providerName: "short-private-key",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65],
            generatedKeyPair: Self.mlkemKeyPair(privateKeyLength: 95)
        )
        await assertInvalidKeyLength(expected: 96, actual: 95) {
            _ = try await BenchmarkHandshakeKEMIdentityStore.make(
                offeredSuites: [.mlkem768MLDSA65],
                provider: shortPrivateKeyProvider
            )
        }
    }

    func testClassicOfferDoesNotGenerateKEMIdentityAndHasNoTrustedKEMKeys() async throws {
        let counter = GenerationCounter()
        let classicProvider = TestCryptoProvider(
            providerName: "classic",
            tier: .classic,
            activeSuite: .x25519Ed25519,
            supportedSuites: [.x25519Ed25519],
            generatedKeyPair: Self.keyPair(
                suite: .x25519Ed25519,
                usage: .keyExchange,
                publicKeyLength: 32,
                privateKeyLength: 32
            ),
            generationCounter: counter
        )

        let store = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.x25519Ed25519],
            provider: classicProvider
        )

        XCTAssertTrue(try store.trustPublicKeys(for: [.x25519Ed25519]).isEmpty)
        let generationCount = await counter.value
        XCTAssertEqual(generationCount, 0)
        await assertUnsupportedAlgorithm {
            _ = try await store.getOrCreateKEMIdentityKey(
                for: .x25519Ed25519,
                provider: classicProvider
            )
        }
    }

    func testCanonicalAliasSharesOneIdentityAndReturnsIndependentSecrets() async throws {
        let counter = GenerationCounter()
        let provider = TestCryptoProvider(
            providerName: "alias-mlkem",
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            generatedKeyPair: Self.mlkemKeyPair(),
            generationCounter: counter
        )
        let offeredSuites: [CryptoSuite] = [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        let store = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: offeredSuites,
            provider: provider
        )

        let generationCount = await counter.value
        XCTAssertEqual(generationCount, 1)
        let publicKeys = try store.trustPublicKeys(for: offeredSuites)
        XCTAssertEqual(publicKeys.count, 2)
        XCTAssertEqual(publicKeys[.mlkem768MLDSA65FS], publicKeys[.mlkem768MLDSA65])

        let first = try await store.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65FS,
            provider: provider
        )
        let second = try await store.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65,
            provider: provider
        )
        XCTAssertEqual(first.publicKey, second.publicKey)
        XCTAssertFalse(first.privateKey === second.privateKey)

        let expectedSecondSecret = second.privateKey.copyData()
        first.privateKey.zeroize()
        XCTAssertEqual(second.privateKey.copyData(), expectedSecondSecret)
    }

    private func assertUnsupportedAlgorithm(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected unsupportedAlgorithm", file: file, line: line)
        } catch {
            Self.assertUnsupportedAlgorithm(error, file: file, line: line)
        }
    }

    private static func assertUnsupportedAlgorithm(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let providerError = error as? CryptoProviderError,
              case .unsupportedAlgorithm = providerError else {
            XCTFail("Expected unsupportedAlgorithm, got \(error)", file: file, line: line)
            return
        }
    }

    private func assertInvalidKeyLength(
        expected: Int,
        actual: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected invalidKeyLength", file: file, line: line)
        } catch let error as CryptoProviderError {
            guard case .invalidKeyLength(
                let observedExpected,
                let observedActual,
                let suite,
                let usage
            ) = error else {
                XCTFail("Expected invalidKeyLength, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(observedExpected, expected, file: file, line: line)
            XCTAssertEqual(observedActual, actual, file: file, line: line)
            XCTAssertEqual(suite, CryptoSuite.mlkem768MLDSA65.rawValue, file: file, line: line)
            XCTAssertEqual(usage, .keyExchange, file: file, line: line)
        } catch {
            XCTFail("Expected CryptoProviderError, got \(error)", file: file, line: line)
        }
    }

    private static func mlkemKeyPair(
        publicKeyLength: Int = 1_184,
        privateKeyLength: Int = 96
    ) -> KeyPair {
        keyPair(
            suite: .mlkem768MLDSA65,
            usage: .keyExchange,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength
        )
    }

    private static func xwingKeyPair() -> KeyPair {
        keyPair(
            suite: .xwingMLDSA,
            usage: .keyExchange,
            publicKeyLength: 1_216,
            privateKeyLength: 64
        )
    }

    private static func keyPair(
        suite: CryptoSuite,
        usage: KeyUsage,
        publicKeyLength: Int,
        privateKeyLength: Int
    ) -> KeyPair {
        KeyPair(
            publicKey: KeyMaterial(
                suite: suite,
                usage: usage,
                bytes: Data(repeating: 0xA5, count: publicKeyLength)
            ),
            privateKey: KeyMaterial(
                suite: suite,
                usage: usage,
                bytes: Data(repeating: 0x5A, count: privateKeyLength)
            )
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
private actor GenerationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct TestCryptoProvider: CryptoProvider, Sendable {
    let providerName: String
    let tier: CryptoTier
    let activeSuite: CryptoSuite
    let supportedSuites: [CryptoSuite]
    let generatedKeyPair: KeyPair
    let generationCounter: GenerationCounter

    init(
        providerName: String,
        tier: CryptoTier,
        activeSuite: CryptoSuite,
        supportedSuites: [CryptoSuite],
        generatedKeyPair: KeyPair,
        generationCounter: GenerationCounter = GenerationCounter()
    ) {
        self.providerName = providerName
        self.tier = tier
        self.activeSuite = activeSuite
        self.supportedSuites = supportedSuites
        self.generatedKeyPair = generatedKeyPair
        self.generationCounter = generationCounter
    }

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains { $0.wireId == suite.wireId }
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        throw CryptoProviderError.notImplemented("TestCryptoProvider.hpkeSeal")
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        throw CryptoProviderError.notImplemented("TestCryptoProvider.hpkeOpen")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.notImplemented("TestCryptoProvider.sign")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.notImplemented("TestCryptoProvider.verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        await generationCounter.increment()
        return generatedKeyPair
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct AlternateTestCryptoProvider: CryptoProvider, Sendable {
    let base: TestCryptoProvider

    var providerName: String { base.providerName }
    var tier: CryptoTier { base.tier }
    var activeSuite: CryptoSuite { base.activeSuite }
    var supportedSuites: [CryptoSuite] { base.supportedSuites }

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        base.supportsSuite(suite)
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        try await base.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: recipientPublicKey,
            info: info
        )
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        try await base.hpkeOpen(
            sealedBox: sealedBox,
            privateKey: privateKey,
            info: info
        )
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        try await base.sign(data: data, using: keyHandle)
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        try await base.verify(data: data, signature: signature, publicKey: publicKey)
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        try await base.generateKeyPair(for: usage)
    }
}
