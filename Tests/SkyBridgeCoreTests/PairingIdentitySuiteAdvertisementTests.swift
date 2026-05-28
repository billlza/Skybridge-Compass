import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PairingIdentitySuiteAdvertisementTests: XCTestCase {
    func testNativeTierAddsInteropSuitesWhenActiveSuiteIsXWing() {
        let provider = MockCryptoProvider(
            tier: .nativePQC,
            activeSuite: .xwingMLDSA,
            supportedSuites: [.xwingMLDSA]
        )

        let suites = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: true
        )
        XCTAssertEqual(suites.map(\.wireId), [0x0001, 0x0101, 0x0102])
    }

    func testNativeTierAddsInteropSuitesWhenActiveSuiteIsMLKEM() {
        let provider = MockCryptoProvider(
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        )

        let suites = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: true
        )
        XCTAssertEqual(suites.map(\.wireId), [0x0001, 0x0101, 0x0102])
    }

    func testNativeTierDoesNotAdvertiseXWingWhenRuntimeUnavailable() {
        let provider = MockCryptoProvider(
            tier: .nativePQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        )

        let suites = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: false
        )
        XCTAssertEqual(suites.map(\.wireId), [0x0101, 0x0102])
    }

    func testLiboqsTierKeepsProviderSuites() {
        let provider = MockCryptoProvider(
            tier: .liboqsPQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        )

        let suites = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(using: provider)
        XCTAssertEqual(suites.map(\.wireId), [0x0101, 0x0102])
    }

    func testClassicTierProducesNoPQCAdvertisement() {
        let provider = MockCryptoProvider(
            tier: .classic,
            activeSuite: .x25519Ed25519,
            supportedSuites: [.x25519Ed25519, .p256ECDSA]
        )

        let suites = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(using: provider)
        XCTAssertTrue(suites.isEmpty)
    }

    func testPairingIdentityCarriesCanonicalProtocolIdentityFingerprints() throws {
        let ed25519PublicKey = Data(repeating: 0x11, count: 32)
        let mlDSAPublicKey = Data(repeating: 0x22, count: 1952)
        let protocolKeys = [
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                publicKey: ed25519PublicKey
            ),
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                publicKey: mlDSAPublicKey
            )
        ]

        let payload = AppMessage.PairingIdentityExchangePayload(
            deviceId: "peer-1",
            kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: Data(repeating: 0x33, count: 1_216))
            ],
            protocolIdentityPublicKeys: protocolKeys
        )
        let decoded = try JSONDecoder().decode(
            AppMessage.PairingIdentityExchangePayload.self,
            from: try JSONEncoder().encode(payload)
        )

        let fingerprints = Set((decoded.protocolIdentityPublicKeys ?? []).compactMap(\.authoritativeFingerprint))
        let expected = Set([
            ProtocolIdentityPublicKeys(protocolPublicKey: ed25519PublicKey, protocolAlgorithm: .ed25519)
                .authoritativeFingerprint,
            ProtocolIdentityPublicKeys(protocolPublicKey: mlDSAPublicKey, protocolAlgorithm: .mlDSA65)
                .authoritativeFingerprint
        ])
        XCTAssertEqual(fingerprints, expected)
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct MockCryptoProvider: CryptoProvider, Sendable {
    let providerName: String = "MockCryptoProvider"
    let tier: CryptoTier
    let activeSuite: CryptoSuite
    let supportedSuites: [CryptoSuite]

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains { $0.wireId == suite.wireId }
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.notImplemented("MockCryptoProvider.hpkeSeal")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.notImplemented("MockCryptoProvider.hpkeOpen")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.notImplemented("MockCryptoProvider.sign")
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.notImplemented("MockCryptoProvider.verify")
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.notImplemented("MockCryptoProvider.generateKeyPair")
    }
}
