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
            appleXWingAvailable: true,
            qPeriaptEnabled: false
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
            appleXWingAvailable: true,
            qPeriaptEnabled: false
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
            appleXWingAvailable: false,
            qPeriaptEnabled: false
        )
        XCTAssertEqual(suites.map(\.wireId), [0x0101, 0x0102])
    }

    func testQPeriaptSuiteIsAdvertisedOnlyWhenExplicitGateIsEnabled() {
        let provider = MockCryptoProvider(
            tier: .liboqsPQC,
            activeSuite: .mlkem768MLDSA65,
            supportedSuites: [
                .qperiaptContextBound,
                .qperiaptABI2PolicyBound,
                .mlkem768MLDSA65FS,
                .mlkem768MLDSA65
            ]
        )

        let disabled = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: false,
            qPeriaptEnabled: false,
            activeProtocolSigningAlgorithm: .mlDSA65
        )
        XCTAssertEqual(disabled.map(\.wireId), [0x0101, 0x0102])

        let enabled = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: false,
            qPeriaptEnabled: true,
            activeProtocolSigningAlgorithm: .mlDSA65
        )
        XCTAssertEqual(enabled.map(\.wireId), [0x0012, 0x0101, 0x0102])

        let activeMLDSA87 = DeviceIdentityKeyManager.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: false,
            qPeriaptEnabled: true,
            activeProtocolSigningAlgorithm: .mlDSA87
        )
        XCTAssertEqual(activeMLDSA87.map(\.wireId), [0x0101, 0x0102])
    }

    func testKEMPublicKeyInfoAcceptsOnlyNegotiableABI2QPeriaptBootstrapKey() {
        let normalized = KEMPublicKeyInfo.normalizedValidKeys([
            KEMPublicKeyInfo(
                suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
                publicKey: Data(repeating: 0x11, count: QPeriaptPlatformPolicy.publicKeyLength)
            ),
            KEMPublicKeyInfo(
                suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
                publicKey: Data(repeating: 0x12, count: 1_184)
            ),
            KEMPublicKeyInfo(
                suiteWireId: CryptoSuite.qperiaptContextBound.wireId,
                publicKey: Data(repeating: 0x13, count: QPeriaptPlatformPolicy.publicKeyLength)
            )
        ])

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized.first?.suiteWireId, CryptoSuite.qperiaptABI2PolicyBound.wireId)
        XCTAssertEqual(normalized.first?.publicKey.count, QPeriaptPlatformPolicy.publicKeyLength)
    }

    func testQPeriaptPolicySeparatesRequestFromRuntimeSupport() {
        let suiteName = "QPeriaptPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(QPeriaptPlatformPolicy.isRequested(environment: [:], userDefaults: defaults))
        XCTAssertTrue(QPeriaptPlatformPolicy.isRequested(environment: ["SB_ENABLE_QPERIAPT": "true"], userDefaults: defaults))
        XCTAssertTrue(QPeriaptPlatformPolicy.isRequested(environment: ["SKYBRIDGE_PQC_PREFERRED_SUITE": "q-periapt"], userDefaults: defaults))

        defaults.set(true, forKey: SettingsStorageKeys.preferQPeriaptBeta)
        XCTAssertTrue(QPeriaptPlatformPolicy.isRequested(environment: [:], userDefaults: defaults))

        XCTAssertEqual(
            QPeriaptPlatformPolicy.isEnabledForLocalRuntime(
                environment: ["SB_ENABLE_QPERIAPT": "1"],
                userDefaults: defaults
            ),
            QPeriaptPlatformPolicy.isLocalRuntimeSupported
        )
    }

    func testQPeriaptPeerPolicyRequiresExplicitSupportedPlatformVersion() {
        XCTAssertTrue(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "macOS", osVersion: "macOS 26.0"))
        XCTAssertTrue(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "iOS", osVersion: "26.1"))
        XCTAssertTrue(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "Android", osVersion: "Android 16 (API 36)"))
        XCTAssertTrue(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "Android", osVersion: "Android 17 (API 37)"))

        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "macOS", osVersion: "macOS 25.9"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "iOS", osVersion: "iOS 25.9"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "Android", osVersion: "Android 16 (API 35)"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "Android", osVersion: "Android 15 (API 36)"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: nil, osVersion: "26.0"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: nil, osVersion: "iOS 26.0"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "Windows", osVersion: "Windows 26"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "iOS", osVersion: "prefix iOS 26.0"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "iOS", osVersion: "iOS 26.0 build 23A"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "macOS", osVersion: "proxy macOS 26.0"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "Android", osVersion: "Android 16 API 36 suffix"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "Android", osVersion: "16"))
        XCTAssertFalse(QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: "iOS", osVersion: "macOS 26.0"))
    }

    func testQPeriaptHandshakePeerPolicyFailsClosedWithoutAdmittedRuntimeSession() {
        let eligible = qPeriaptCapabilities()
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(eligible))
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(
            qPeriaptCapabilities(platformVersion: "iOS 26.0")
        ))

        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(
            qPeriaptCapabilities(providerType: .cryptoKitPQC)
        ))
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(
            qPeriaptCapabilities(authProfiles: [AuthProfile.pqc.displayName])
        ))
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(
            qPeriaptCapabilities(signatures: [P2PCryptoAlgorithm.p256.rawValue])
        ))
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(
            qPeriaptCapabilities(platformVersion: "Android 16 (API 35)")
        ))
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(
            qPeriaptCapabilities(platformVersion: "26.0")
        ))
    }

    func testPairingIdentityNormalizationGatesQPeriaptByPeerPlatform() {
        let qKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
            publicKey: Data(repeating: 0x51, count: QPeriaptPlatformPolicy.publicKeyLength)
        )
        let xWingKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwingMLDSA.wireId,
            publicKey: Data(repeating: 0x52, count: 1_216)
        )

        let ambiguous = AppMessage.PairingIdentityExchangePayload(
            deviceId: "peer-q",
            kemPublicKeys: [qKey, xWingKey],
            platform: nil,
            osVersion: "26.0"
        ).normalizedBootstrapPayload

        XCTAssertEqual(ambiguous?.kemPublicKeys.map(\.suiteWireId), [CryptoSuite.xwingMLDSA.wireId])

        let eligible = AppMessage.PairingIdentityExchangePayload(
            deviceId: "peer-q",
            kemPublicKeys: [qKey, xWingKey],
            platform: "Android",
            osVersion: "Android 16 (API 36)"
        ).normalizedBootstrapPayload

        XCTAssertEqual(eligible?.kemPublicKeys.map(\.suiteWireId), [
            CryptoSuite.xwingMLDSA.wireId,
            CryptoSuite.qperiaptABI2PolicyBound.wireId
        ])
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

    private func qPeriaptCapabilities(
        providerType: CryptoProviderType = .qPeriapt,
        authProfiles: [String] = [QPeriaptPlatformPolicy.authProfile],
        signatures: [String] = [P2PCryptoAlgorithm.mlDSA65.rawValue],
        platformVersion: String = "Android 16 (API 36)"
    ) -> CryptoCapabilities {
        CryptoCapabilities(
            supportedKEM: [P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue],
            supportedSignature: signatures,
            supportedAuthProfiles: authProfiles,
            supportedAEAD: [P2PCryptoAlgorithm.aes256GCM.rawValue],
            pqcAvailable: true,
            platformVersion: platformVersion,
            providerType: providerType
        )
    }

    func testPairingIdentityCarriesCanonicalProtocolIdentityFingerprints() throws {
        let ed25519PublicKey = Data(repeating: 0x11, count: 32)
        let mlDSAPublicKey = Data(repeating: 0x22, count: 1952)
        let mlDSA87PublicKey = Data(repeating: 0x23, count: 2_592)
        let protocolKeys = [
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                publicKey: ed25519PublicKey
            ),
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                publicKey: mlDSAPublicKey
            ),
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA87.rawValue,
                publicKey: mlDSA87PublicKey
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
                .authoritativeFingerprint,
            ProtocolIdentityPublicKeys(protocolPublicKey: mlDSA87PublicKey, protocolAlgorithm: .mlDSA87)
                .authoritativeFingerprint
        ])
        XCTAssertEqual(fingerprints, expected)
    }

#if os(macOS)
    func testLocalProtocolIdentityAdvertisementValidatesExactAlgorithmLengths() throws {
        try LocalProtocolIdentityAdvertisement.validate(
            publicKey: Data(repeating: 0x11, count: 32),
            algorithm: .ed25519
        )
        try LocalProtocolIdentityAdvertisement.validate(
            publicKey: Data(repeating: 0x65, count: 1_952),
            algorithm: .mlDSA65
        )
        try LocalProtocolIdentityAdvertisement.validate(
            publicKey: Data(repeating: 0x87, count: 2_592),
            algorithm: .mlDSA87
        )

        XCTAssertThrowsError(
            try LocalProtocolIdentityAdvertisement.validate(
                publicKey: Data(repeating: 0x87, count: 2_591),
                algorithm: .mlDSA87
            )
        ) { error in
            guard let advertisementError = error as? LocalProtocolIdentityAdvertisementError,
                  case .invalidPublicKey(let algorithm, let actualLength) = advertisementError else {
                XCTFail("Expected exact-length validation failure, got \(error)")
                return
            }
            XCTAssertEqual(algorithm, .mlDSA87)
            XCTAssertEqual(actualLength, 2_591)
        }
    }
#endif
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
