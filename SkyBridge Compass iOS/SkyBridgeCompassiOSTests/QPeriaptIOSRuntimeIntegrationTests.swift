import CryptoKit
import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class QPeriaptIOSRuntimeIntegrationTests: XCTestCase {
    @MainActor
    @available(iOS 26.0, *)
    func testNativeQWireRoundTripBindsEncodedIdentityEnvelope() async throws {
        #if HAS_APPLE_PQC_SDK
        try await withAdmittedProductionProvider { provider, configuration in
            let snapshot = QPeriaptHandshakeAdmissionSnapshot.capture(
                provider: provider, protocolIdentityConfiguration: configuration
            )
            let bound = snapshot.bind(provider: provider)
            XCTAssertTrue(snapshot.admits(provider: bound))
            let recipient = try await P2PKEMIdentityKeyStore.shared.getOrCreateIdentityKey(
                for: .qperiaptABI2PolicyBound, provider: bound
            )
            defer { recipient.privateKey.zeroize() }
            let initiatorKey = try MLDSA65.PrivateKey()
            let responderKey = try MLDSA65.PrivateKey()
            let signatures = PQCSignatureProvider(algorithm: .mlDSA65, backend: .applePQC)
            let policy = HandshakeCryptoPolicyResolver.policy(for: [.qperiaptABI2PolicyBound])
            let initiator = HandshakeContext(
                role: .initiator, cryptoProvider: bound, protocolSignatureProvider: signatures,
                identityKeyHandle: .softwareKey(initiatorKey.integrityCheckedRepresentation),
                identityPublicKey: initiatorKey.publicKey.rawRepresentation,
                policy: .strictPQC, cryptoPolicy: policy,
                offeredSuites: [.qperiaptABI2PolicyBound],
                peerKEMPublicKeys: [.qperiaptABI2PolicyBound: recipient.publicKey]
            )
            let responder = HandshakeContext(
                role: .responder, cryptoProvider: bound, protocolSignatureProvider: signatures,
                identityKeyHandle: .softwareKey(responderKey.integrityCheckedRepresentation),
                identityPublicKey: responderKey.publicKey.rawRepresentation,
                policy: .strictPQC, cryptoPolicy: policy,
                offeredSuites: [.qperiaptABI2PolicyBound]
            )
            do {
                let messageA = try await initiator.buildMessageA()
                let decodedA = try HandshakeMessageA.decode(from: messageA.encoded)
                XCTAssertNotEqual(decodedA.identityPublicKey, initiatorKey.publicKey.rawRepresentation)
                try await responder.processMessageA(decodedA)
                let response = try await responder.buildMessageB()
                defer { response.sharedSecret.zeroize() }
                let decodedB = try HandshakeMessageB.decode(from: response.message.encoded)
                let initiatorKeys = try await initiator.processMessageB(decodedB)
                let responderKeys = try await responder.finalizeResponderSessionKeys(sharedSecret: response.sharedSecret)
                XCTAssertEqual(initiatorKeys.negotiatedSuite, .qperiaptABI2PolicyBound)
                XCTAssertEqual(initiatorKeys.sendKey, responderKeys.receiveKey)
                XCTAssertEqual(initiatorKeys.receiveKey, responderKeys.sendKey)
                XCTAssertEqual(initiatorKeys.transcriptHash, responderKeys.transcriptHash)
            } catch {
                await initiator.zeroize()
                await responder.zeroize()
                throw error
            }
            await initiator.zeroize()
            await responder.zeroize()
        }
        #else
        XCTFail("Native Q wire acceptance requires the Apple PQC SDK lane")
        #endif
    }

    @MainActor
    @available(iOS 26.0, *)
    func testAdmittedFactoryProviderReachesCoreIdentityResolution() async throws {
        try await withAdmittedProductionProvider { provider, _ in
            // Factory output has runtime authority; each driver binds identity separately.
            XCTAssertTrue(provider is any QPeriaptRuntimeBoundCryptoProvider)
            XCTAssertFalse(provider is any QPeriaptHandshakeBoundCryptoProvider)
            let core = SkyBridgeiOSCore(protocolIdentityResolver: { algorithm, selected in
                XCTAssertEqual(algorithm, .mlDSA65)
                XCTAssertEqual(selected?.activeSuite, .qperiaptABI2PolicyBound)
                throw CoreIdentityResolutionProbe.reached
            })
            do {
                try await core.initialize(policy: .requirePQC)
                XCTFail("The identity resolution probe must stop initialization")
            } catch CoreIdentityResolutionProbe.reached {
                // Positive admission must reach the existing identity I/O boundary.
            } catch {
                XCTFail("Verified factory provider was rejected before identity resolution: \(error)")
            }
            XCTAssertFalse(core.isInitialized)
        }
    }

    @MainActor
    @available(iOS 26.0, *)
    func testCoreRejectsProviderFrozenToAnotherIdentityConfiguration() async throws {
        try await withAdmittedProductionProvider { provider, configuration in
            let session = try XCTUnwrap(QPeriaptIOSRuntime.currentSession)
            let otherConfiguration = ProtocolIdentityConfigurationRecord(
                algorithm: .mlDSA65, keyProtection: .secureEnclaveRequired
            )
            XCTAssertNotEqual(configuration, otherConfiguration)
            let snapshot = QPeriaptHandshakeAdmissionSnapshot.admitted(
                authProfile: session.authProfile,
                trustRootFingerprint: session.trustRootFingerprint,
                protocolIdentityConfiguration: otherConfiguration
            )
            let frozen = snapshot.bind(provider: provider)
            XCTAssertTrue(snapshot.admits(provider: frozen))
            let core = SkyBridgeiOSCore(protocolIdentityResolver: { _, _ in
                throw CoreIdentityResolutionProbe.reached
            })
            do {
                try await core.initialize(policy: .requirePQC, providerOverride: frozen)
                XCTFail("An identity-bound override must not be rebound to current settings")
            } catch CoreIdentityResolutionProbe.reached {
                XCTFail("Mismatched frozen authority reached identity resolution")
            } catch SkyBridgeError.handshakeFailed {
                // Rejected before identity I/O, with no fallback or initialization commit.
            }
            XCTAssertFalse(core.isInitialized)
        }
    }

    @MainActor
    @available(iOS 26.0, *)
    private func withAdmittedProductionProvider(
        _ body: @MainActor (any CryptoProvider, ProtocolIdentityConfigurationRecord) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let key = ProtocolSigningIdentityPolicy.configurationDefaultsKey
        let oldConfiguration = defaults.object(forKey: key)
        let oldEnable = ProcessInfo.processInfo.environment["SB_ENABLE_QPERIAPT"]
        XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", "1", 1), 0)
        QPeriaptIOSRuntime.resetForTesting()
        defer {
            if let oldConfiguration { defaults.set(oldConfiguration, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            if let oldEnable { XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", oldEnable, 1), 0) }
            else { XCTAssertEqual(unsetenv("SB_ENABLE_QPERIAPT"), 0) }
            QPeriaptIOSRuntime.resetForTesting()
        }
        let configuration = ProtocolIdentityConfigurationRecord(
            algorithm: .mlDSA65, keyProtection: .softwareKeychain
        )
        try ProtocolSigningIdentityPolicy.persist(configuration)
        _ = try await QPeriaptIOSRuntime.prepareProductionSession()
        let provider = CryptoProviderFactory.make(policy: .requirePQC)
        XCTAssertEqual(provider.tier, .qperiaptPQC)
        try await body(provider, configuration)
    }

    private enum CoreIdentityResolutionProbe: Error { case reached }

    func testRequestedQWithoutAdmissionCannotSelectAnOrdinaryProvider() {
        let previous = ProcessInfo.processInfo.environment["SB_ENABLE_QPERIAPT"]
        XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", "1", 1), 0)
        QPeriaptIOSRuntime.resetForTesting()
        defer {
            if let previous {
                XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", previous, 1), 0)
            } else {
                XCTAssertEqual(unsetenv("SB_ENABLE_QPERIAPT"), 0)
            }
            QPeriaptIOSRuntime.resetForTesting()
        }
        for policy in [CryptoProviderFactory.SelectionPolicy.preferPQC, .requirePQC] {
            let providers = [
                CryptoProviderFactory.make(policy: policy),
                CryptoProviderFactory.makeInboundPQCResponderProvider(
                    policy: policy,
                    peerSupportedSuites: [.qperiaptABI2PolicyBound, .xwingMLDSA]
                )
            ]
            for provider in providers {
                XCTAssertEqual(provider.providerName, "Unavailable")
                XCTAssertTrue(provider.supportedSuites.isEmpty)
            }
        }
    }

    @available(iOS 26.0, *)
    func testAdmittedQResponderDoesNotChangeSuiteFamilyForAnOrdinaryPeer() async throws {
        let previous = ProcessInfo.processInfo.environment["SB_ENABLE_QPERIAPT"]
        XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", "1", 1), 0)
        QPeriaptIOSRuntime.resetForTesting()
        defer {
            if let previous {
                XCTAssertEqual(setenv("SB_ENABLE_QPERIAPT", previous, 1), 0)
            } else {
                XCTAssertEqual(unsetenv("SB_ENABLE_QPERIAPT"), 0)
            }
            QPeriaptIOSRuntime.resetForTesting()
        }
        let preparation = try await QPeriaptIOSRuntime.prepareProductionSession()
        XCTAssertEqual(preparation, .activated)
        let selected = CryptoProviderFactory.make(policy: .requirePQC)
        XCTAssertEqual(selected.tier, .qperiaptPQC)
        for offer in [[CryptoSuite.qperiaptABI2PolicyBound], [.xwingMLDSA]] {
            let responder = CryptoProviderFactory.makeInboundPQCResponderProvider(
                policy: .requirePQC, peerSupportedSuites: offer
            )
            XCTAssertEqual(responder.tier, .qperiaptPQC)
            XCTAssertEqual(responder.supportedSuites, [.qperiaptABI2PolicyBound])
        }
    }

    func testQPeerPlatformsAdmitCanonicalNativeMetadataAndRetainKeyValidation() {
        let key = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
            publicKey: Data(repeating: 0x42, count: 1_216)
        )
        for (platform, version) in [("windows", "10.0.19041"), ("Ubuntu", "24.04")] {
            XCTAssertEqual(
                KEMPublicKeyInfo.normalizedValidKeys([key], platform: platform, osVersion: version),
                [key]
            )
            XCTAssertTrue(
                QPeriaptIOSPlatformPolicy.isPeerHandshakePlatformVersionEligible("\(platform) \(version)")
            )
        }
        for (platform, version) in [
            ("windows", "Windows 11"), ("windows", "10.0.19040"),
            ("Ubuntu", "24.03"), ("Ubuntu", "Windows 10.0.26100")
        ] {
            XCTAssertTrue(
                KEMPublicKeyInfo.normalizedValidKeys([key], platform: platform, osVersion: version).isEmpty
            )
        }
        let truncated = KEMPublicKeyInfo(suiteWireId: key.suiteWireId, publicKey: key.publicKey.dropLast())
        XCTAssertTrue(
            KEMPublicKeyInfo.normalizedValidKeys([truncated], platform: "windows", osVersion: "10.0.26100").isEmpty
        )
    }

    func testInboundResponderFactoryRejectsEmptyAndNonNegotiablePeerSuites() {
        let invalidPeerOffers: [[CryptoSuite]] = [
            [],
            [.qperiaptContextBound],
            [.qperiaptABI2PolicyBound, .qperiaptContextBound]
        ]

        for peerSupportedSuites in invalidPeerOffers {
            let provider = CryptoProviderFactory.makeInboundPQCResponderProvider(
                policy: .requirePQC,
                peerSupportedSuites: peerSupportedSuites
            )
            XCTAssertEqual(provider.providerName, "Unavailable")
            XCTAssertTrue(provider.supportedSuites.isEmpty)
            XCTAssertFalse(provider.supportsSuite(.qperiaptABI2PolicyBound))
        }
    }

    func testClassicOnlyPolicyNeverSelectsQPeriapt() {
        XCTAssertFalse(CryptoProviderFactory.isQPeriaptSelectionAllowed(for: .classicOnly))
        XCTAssertTrue(CryptoProviderFactory.isQPeriaptSelectionAllowed(for: .preferPQC))
        XCTAssertTrue(CryptoProviderFactory.isQPeriaptSelectionAllowed(for: .requirePQC))
    }

    func testMessageAApplicationContextMatchesMacOSGoldenDigest() throws {
        let context = try QPeriaptHandshakeApplicationContext.messageA(
            version: 1,
            suite: .qperiaptABI2PolicyBound,
            clientNonce: Data(repeating: 0x11, count: 32),
            recipientPublicKey: Data(repeating: 0x22, count: 1_216),
            policy: HandshakePolicy(
                requirePQC: true,
                allowClassicFallback: false,
                minimumTier: .qperiaptPQC
            ),
            offeredSuites: [.qperiaptABI2PolicyBound, .mlkem768],
            capabilities: CryptoCapabilities(
                supportedKEM: ["Q-Periapt-ABI2-PolicyBound"],
                supportedSignature: ["ML-DSA-65"],
                supportedAuthProfiles: ["q-periapt-abi2-policy-v1/2/test-digest"],
                supportedAEAD: ["AES-256-GCM"],
                pqcAvailable: true,
                platformVersion: "macOS 26.0",
                providerType: .qPeriapt
            ),
            identityPublicKey: Data(repeating: 0x33, count: 1_952),
            extensionsRaw: Data([0x01, 0x02, 0x03])
        )
        let digest = SHA256.hash(data: context)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            digest,
            "9cdf97efe7d030b4f96cbbbd01f4f7681a3b2991e00159c361105a61948cc14f"
        )
    }

    func testMLDSA87RejectsQOnlyPreparationBeforeExecutor() {
        XCTAssertThrowsError(
            try TwoAttemptHandshakeManager.prepareAttempt(
                strategy: .pqcOnly,
                cryptoProvider: TestQPeriaptProvider(),
                pqcSignatureAlgorithm: .mlDSA87
            )
        ) { error in
            guard case AttemptPreparationError.pqcProviderUnavailable = error else {
                return XCTFail("Expected pqcProviderUnavailable, got \(error)")
            }
        }
    }

    func testRuntimeBoundQProviderCannotHideBehindNonQTierToEnableRetry() async throws {
        let counter = AttemptCounter()
        let provider = TestQPeriaptProvider(tier: .liboqsPQC)

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "q-bound-wrapper-no-downgrade-\(UUID().uuidString)",
                preferPQC: true,
                policy: .default,
                cryptoProvider: provider,
                pqcSignatureAlgorithm: .mlDSA65
            ) { preparation in
                await counter.record(preparation.strategy)
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            XCTFail("A runtime-bound Q provider must preserve the first Q failure")
        } catch HandshakeError.failed(.suiteNegotiationFailed) {
            // Expected: no compatibility or classic retry.
        }

        let counts = await counter.snapshot()
        XCTAssertEqual(counts.pqc, 1)
        XCTAssertEqual(counts.classic, 0)
    }

    func testExactCapabilityAndCompletePlatformAdmission() {
        let snapshot = admittedSnapshot()
        XCTAssertTrue(snapshot.isPeerEligible(capabilities(platformVersion: "iOS 26.0")))
        XCTAssertTrue(snapshot.isPeerEligible(capabilities(platformVersion: "macOS 26.1")))
        XCTAssertTrue(snapshot.isPeerEligible(capabilities(platformVersion: "Android 16 (API 36)")))
        XCTAssertTrue(snapshot.isPeerEligible(capabilities(platformVersion: "Android 16 API 36")))

        XCTAssertFalse(snapshot.isPeerEligible(capabilities(
            kem: ["qperiaptabi2policybound"],
            platformVersion: "iOS 26.0"
        )))
        XCTAssertFalse(snapshot.isPeerEligible(capabilities(
            signature: ["ML_DSA_65"],
            platformVersion: "iOS 26.0"
        )))
        XCTAssertFalse(snapshot.isPeerEligible(capabilities(
            authProfiles: ["q-periapt-test-policy-alias"],
            platformVersion: "iOS 26.0"
        )))
        XCTAssertFalse(snapshot.isPeerEligible(capabilities(
            aead: [],
            platformVersion: "iOS 26.0"
        )))

        for malformed in [
            "iOS 25.9",
            "prefix iOS 26.0",
            "26 iOS 25.0",
            "iPadOS 26.0",
            "iOS 26.0 build 23A",
            "Android 16 (API 35)",
            "Android API 36",
            "Android 15 (API 36)"
        ] {
            XCTAssertFalse(
                snapshot.isPeerEligible(capabilities(platformVersion: malformed)),
                "Malformed or ineligible platform was admitted: \(malformed)"
            )
        }
    }

    func testQCapabilityFailuresNeverTriggerCompatibilityOrClassicAttempt() async throws {
        let snapshot = admittedSnapshot()
        let invalidCapabilities = [
            capabilities(kem: ["qperiaptabi2policybound"], platformVersion: "iOS 26.0"),
            capabilities(authProfiles: [], platformVersion: "iOS 26.0"),
            capabilities(aead: [], platformVersion: "iOS 26.0"),
            capabilities(platformVersion: "proxy iOS 26.0")
        ]

        for (index, peerCapabilities) in invalidCapabilities.enumerated() {
            let counter = AttemptCounter()
            do {
                _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                    deviceId: "q-no-downgrade-\(index)-\(UUID().uuidString)",
                    preferPQC: true,
                    policy: .default,
                    cryptoProvider: TestQPeriaptProvider(),
                    pqcSignatureAlgorithm: .mlDSA65
                ) { preparation in
                    await counter.record(preparation.strategy)
                    guard snapshot.isPeerEligible(peerCapabilities) else {
                        throw HandshakeError.failed(.suiteNegotiationFailed)
                    }
                    return SessionKeys(
                        sendKey: Data(repeating: 1, count: 32),
                        receiveKey: Data(repeating: 2, count: 32),
                        negotiatedSuite: .qperiaptABI2PolicyBound,
                        transcriptHash: Data(repeating: 3, count: 32)
                    )
                }
                XCTFail("Invalid Q capability must fail without downgrade")
            } catch HandshakeError.failed(.suiteNegotiationFailed) {
                // Expected: preserve the original Q failure.
            }

            let counts = await counter.snapshot()
            XCTAssertEqual(counts.pqc, 1)
            XCTAssertEqual(counts.classic, 0)
        }
    }

    func testCorruptIdentityConfigurationDisablesQProviderCreation() async throws {
        let suiteName = "QPeriaptCorruptConfiguration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data([0x00, 0x01]),
            forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey
        )

        XCTAssertFalse(QPeriaptIOSRuntime.isEnabledForLocalRuntime(
            environment: ["SB_ENABLE_QPERIAPT": "1"],
            userDefaults: defaults
        ))
        XCTAssertNil(QPeriaptIOSRuntime.makeCryptoProvider(
            environment: ["SB_ENABLE_QPERIAPT": "1"],
            userDefaults: defaults
        ))

        let captured = QPeriaptHandshakeAdmissionSnapshot.capture(
            provider: TestQPeriaptProvider(),
            protocolIdentityConfiguration: protocolConfiguration,
            environment: ["SB_ENABLE_QPERIAPT": "1"],
            userDefaults: defaults
        )
        XCTAssertEqual(captured, .unavailable)
        let rejectedProvider = captured.bind(provider: TestQPeriaptProvider())
        XCTAssertTrue(rejectedProvider.supportedSuites.isEmpty)
        XCTAssertFalse(rejectedProvider.supportsSuite(.qperiaptABI2PolicyBound))

        let rejectedContext = HandshakeContext(
            role: .initiator,
            cryptoProvider: rejectedProvider,
            protocolSignatureProvider: TestMLDSA65SignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(),
            policy: .default,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(
                for: [.qperiaptABI2PolicyBound]
            ),
            offeredSuites: [.qperiaptABI2PolicyBound]
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await rejectedContext.buildMessageA()
        }
        let rejectedContextWasZeroized = await rejectedContext.isZeroized
        XCTAssertTrue(
            rejectedContextWasZeroized,
            "Rejected Q provider must fail before producing or advertising MessageA"
        )

        let counter = AttemptCounter()
        do {
            _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
                deviceId: "corrupt-q-config-\(UUID().uuidString)",
                preferPQC: true,
                policy: .default,
                cryptoProvider: rejectedProvider,
                pqcSignatureAlgorithm: .mlDSA65
            ) { preparation in
                await counter.record(preparation.strategy)
                return SessionKeys(
                    sendKey: Data(repeating: 1, count: 32),
                    receiveKey: Data(repeating: 2, count: 32),
                    negotiatedSuite: .qperiaptABI2PolicyBound,
                    transcriptHash: Data(repeating: 3, count: 32)
                )
            }
            XCTFail("Corrupt configuration must not start a Q or classic handshake")
        } catch AttemptPreparationError.pqcProviderUnavailable {
            // Expected before executor invocation.
        }
        let counts = await counter.snapshot()
        XCTAssertEqual(counts.pqc, 0)
        XCTAssertEqual(counts.classic, 0)
    }

    @available(iOS 26.0, *)
    func testSharedRuntimeRoundTripAndFrozenSnapshotSurviveSettingsFlipAndRegistryReset() async throws {
        QPeriaptIOSRuntime.resetForTesting()
        defer { QPeriaptIOSRuntime.resetForTesting() }
        // The shipped production registry provisions a real signed-policy
        // session end to end (verification, durable CAS, native probe).
        let productionPreparation = try await QPeriaptIOSRuntime.prepareProductionSession()
        XCTAssertEqual(productionPreparation, .activated)
        let productionSession = try XCTUnwrap(QPeriaptIOSRuntime.currentSession)
        XCTAssertEqual(productionSession.policyVersion, 1)
        XCTAssertTrue(
            productionSession.authProfile.hasPrefix("q-periapt-abi2-policy-v1/")
        )

        // The rest of this test exercises the fixture root; trust-root
        // replacement is forbidden inside one registry lifecycle, so start a
        // fresh lifecycle exactly as the production reset flow would.
        QPeriaptIOSRuntime.resetForTesting()
        let fixture = try loadSignedPolicyFixture()
        try await QPeriaptIOSRuntime.activateSignedPolicyForTesting(
            policyTOML: Data(fixture.policyTOML.utf8),
            detachedSignature: try Data(hex: fixture.signature),
            verificationKey: try Data(hex: fixture.verificationKey),
            verificationKeySHA256Pin: Data(
                SHA256.hash(data: try Data(hex: fixture.verificationKey))
            ),
            trustRootIdentifier: "ios-tests/qperiapt/root-v1"
        )

        let suiteName = "QPeriaptFrozenSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try ProtocolSigningIdentityPolicy.persist(protocolConfiguration, defaults: defaults)
        let environment = ["SB_ENABLE_QPERIAPT": "1"]
        let provider = try XCTUnwrap(QPeriaptIOSRuntime.makeCryptoProvider(
            environment: environment,
            userDefaults: defaults
        ))

        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        let privateKey = try XCTUnwrap(keyPair.privateKey.secureBytesReference)
        defer { privateKey.zeroize() }
        let applicationContext = Data("ios-qperiapt-roundtrip-context-v1".utf8)
        let encapsulated = try await provider.kemEncapsulate(
            recipientPublicKey: keyPair.publicKey.bytes,
            applicationContext: applicationContext
        )
        defer { encapsulated.sharedSecret.zeroize() }
        let decapsulated = try await provider.kemDecapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: privateKey,
            applicationContext: applicationContext
        )
        defer { decapsulated.zeroize() }
        var encapsulatedSecret = encapsulated.sharedSecret.copyData()
        var decapsulatedSecret = decapsulated.copyData()
        defer {
            encapsulatedSecret.resetBytes(in: 0..<encapsulatedSecret.count)
            decapsulatedSecret.resetBytes(in: 0..<decapsulatedSecret.count)
        }
        XCTAssertEqual(encapsulatedSecret, decapsulatedSecret)
        await XCTAssertThrowsErrorAsync {
            _ = try await provider.kemEncapsulate(
                recipientPublicKey: keyPair.publicKey.bytes
            )
        }

        let snapshot = QPeriaptHandshakeAdmissionSnapshot.capture(
            provider: provider,
            protocolIdentityConfiguration: protocolConfiguration,
            environment: environment,
            userDefaults: defaults
        )
        guard case .admitted(let admittedAuthProfile, _, _) = snapshot else {
            return XCTFail("Verified runtime/provider must produce an admitted snapshot")
        }
        let boundProvider = snapshot.bind(provider: provider)

        defaults.set(
            Data([0xFF]),
            forKey: ProtocolSigningIdentityPolicy.configurationDefaultsKey
        )
        XCTAssertNil(QPeriaptIOSRuntime.makeCryptoProvider(
            environment: environment,
            userDefaults: defaults
        ))
        QPeriaptIOSRuntime.resetForTesting()

        XCTAssertTrue(snapshot.admits(provider: boundProvider))
        let peerCapabilities = capabilities(
            authProfiles: [admittedAuthProfile],
            platformVersion: "iOS 26.0"
        )
        XCTAssertTrue(snapshot.isPeerEligible(peerCapabilities))
        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: boundProvider,
            protocolSignatureProvider: TestMLDSA65SignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(),
            policy: .default,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(
                for: [.qperiaptABI2PolicyBound]
            ),
            offeredSuites: [.qperiaptABI2PolicyBound]
        )
        let messageA = HandshakeMessageA(
            supportedSuites: [.qperiaptABI2PolicyBound],
            keyShares: [HandshakeKeyShare(
                suite: .qperiaptABI2PolicyBound,
                shareBytes: Data([0x01])
            )],
            clientNonce: Data(repeating: 0x02, count: HandshakeConstants.nonceSize),
            policy: .default,
            capabilities: peerCapabilities,
            signature: Data(),
            identityPublicKey: Data()
        )
        let selectedSuite = try await context.selectResponderSuite(for: messageA)
        XCTAssertEqual(selectedSuite, .qperiaptABI2PolicyBound)
    }

    private var protocolConfiguration: ProtocolIdentityConfigurationRecord {
        ProtocolIdentityConfigurationRecord(
            algorithm: .mlDSA65,
            keyProtection: .softwareKeychain
        )
    }

    private func admittedSnapshot() -> QPeriaptHandshakeAdmissionSnapshot {
        .admitted(
            authProfile: "q-periapt-test-policy",
            trustRootFingerprint: Data(repeating: 0x42, count: SHA256.byteCount),
            protocolIdentityConfiguration: protocolConfiguration
        )
    }

    private func capabilities(
        kem: [String] = [CryptoSuite.qperiaptABI2PolicyBound.rawValue],
        signature: [String] = [ProtocolSigningAlgorithm.mlDSA65.rawValue],
        authProfiles: [String] = ["q-periapt-test-policy"],
        aead: [String] = ["AES-256-GCM"],
        platformVersion: String
    ) -> CryptoCapabilities {
        CryptoCapabilities(
            supportedKEM: kem,
            supportedSignature: signature,
            supportedAuthProfiles: authProfiles,
            supportedAEAD: aead,
            pqcAvailable: true,
            platformVersion: platformVersion,
            providerType: .qPeriapt
        )
    }

    private func loadSignedPolicyFixture() throws -> SignedPolicyFixture {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "signed-policy-vectors",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(
            SignedPolicyFixture.self,
            from: Data(contentsOf: url)
        )
    }
}

@available(iOS 17.0, *)
private struct TestQPeriaptProvider: QPeriaptRuntimeBoundCryptoProvider, Sendable {
    let providerName = "TestQPeriaptProvider"
    let tier: CryptoTier
    let activeSuite: CryptoSuite = .qperiaptABI2PolicyBound
    let supportedSuites: [CryptoSuite] = [.qperiaptABI2PolicyBound]
    let qPeriaptAuthProfile = "q-periapt-test-policy"
    let qPeriaptTrustRootFingerprint = Data(repeating: 0x42, count: SHA256.byteCount)

    init(tier: CryptoTier = .qperiaptPQC) {
        self.tier = tier
    }

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        suite == .qperiaptABI2PolicyBound
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox { throw unsupported }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw unsupported
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data { throw unsupported }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data { throw unsupported }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw unsupported
    }

    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw unsupported
    }

    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes { throw unsupported }

    func kemEncapsulate(
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw unsupported
    }

    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) async throws -> SecureBytes { throw unsupported }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw unsupported
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw unsupported
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw unsupported
    }

    private var unsupported: CryptoProviderError {
        .unsupportedOperation("test provider has no crypto implementation")
    }
}

@available(iOS 17.0, *)
private struct TestMLDSA65SignatureProvider: ProtocolSignatureProvider, Sendable {
    let signatureAlgorithm: ProtocolSigningAlgorithm = .mlDSA65

    func sign(_ data: Data, key: SigningKeyHandle) async throws -> Data {
        Data([0x01])
    }

    func verify(_ data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        true
    }
}

@available(iOS 17.0, *)
private actor AttemptCounter {
    private var pqc = 0
    private var classic = 0

    func record(_ strategy: HandshakeAttemptStrategy) {
        switch strategy {
        case .pqcOnly: pqc += 1
        case .classicOnly: classic += 1
        }
    }

    func snapshot() -> (pqc: Int, classic: Int) {
        (pqc, classic)
    }
}

private struct SignedPolicyFixture: Decodable {
    let policyTOML: String
    let verificationKey: String
    let signature: String

    private enum CodingKeys: String, CodingKey {
        case policyTOML = "policy_toml"
        case verificationKey = "verification_key"
        case signature
    }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw HexFixtureError.invalidLength
        }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw HexFixtureError.invalidByte
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}

private enum HexFixtureError: Error {
    case invalidLength
    case invalidByte
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async operation to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
