import CryptoKit
import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class KEMTrustStoreTests: XCTestCase {
    func testPersistAndRestoreKEMTrustStore() async throws {
        let suiteName = "KEMTrustStoreTests.\(UUID().uuidString)"
        guard let cleanupDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        cleanupDefaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.tests.v1"
        let deviceId = "peer-\(UUID().uuidString)"
        let keyInfo = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0xA5, count: 1_184)
        )

        guard let writerDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create writer UserDefaults suite")
            return
        }
        let writerStore = KEMTrustStore(storageKey: storageKey, userDefaults: writerDefaults)
        await writerStore.upsert(deviceId: deviceId, kemPublicKeys: [keyInfo])

        guard let readerDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create reader UserDefaults suite")
            return
        }
        let readerStore = KEMTrustStore(storageKey: storageKey, userDefaults: readerDefaults)
        let restored = await readerStore.kemPublicKeys(for: deviceId)

        XCTAssertEqual(restored[.mlkem768], keyInfo.publicKey)

        await readerStore.clear(deviceId: deviceId)
        let cleared = await readerStore.kemPublicKeys(for: deviceId)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testLookupSupportsDiscoveryAndDeclaredIdentityAliases() async throws {
        let suiteName = "KEMTrustStoreAliasTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.alias.tests.v1"
        let rawDeviceId = UUID().uuidString.lowercased()
        let discoveryDeviceId = "id:\(rawDeviceId)"
        let endpointAlias = "host:192.168.10.22"
        let keyInfo = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x5A, count: 1_184)
        )

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await store.upsert(deviceId: rawDeviceId, kemPublicKeys: [keyInfo])
        await store.upsert(deviceId: endpointAlias, kemPublicKeys: [keyInfo])

        let fromDiscoveryId = await store.kemPublicKeys(for: discoveryDeviceId)
        let fromRawId = await store.kemPublicKeys(for: rawDeviceId)
        let fromEndpointAlias = await store.kemPublicKeys(for: endpointAlias)

        XCTAssertEqual(fromDiscoveryId[.mlkem768], keyInfo.publicKey)
        XCTAssertEqual(fromRawId[.mlkem768], keyInfo.publicKey)
        XCTAssertNil(fromEndpointAlias[.mlkem768])
    }

    func testLookupAcrossAliasesPrefersNewestKeyMaterial() async throws {
        let suiteName = "KEMTrustStoreAliasLatestTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.alias.latest.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let endpointAlias = "host:192.168.10.23"
        let oldKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x10, count: 1_184)
        )
        let newKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x20, count: 1_184)
        )

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await store.upsert(deviceId: canonicalId, kemPublicKeys: [oldKey])
        try await Task.sleep(for: .milliseconds(20))
        await store.upsert(deviceId: endpointAlias, kemPublicKeys: [newKey])

        let resolved = await store.kemPublicKeys(forAny: [canonicalId, endpointAlias])

        XCTAssertEqual(resolved[.mlkem768], oldKey.publicKey)
    }

    func testRebindCanonicalDeviceIdPrefersNewestKeyMaterial() async throws {
        let suiteName = "KEMTrustStoreRebindTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.rebind.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let legacyAlias = "bonjour:lza的macbook pro@local."
        let oldKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x11, count: 1_184)
        )
        let newKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x22, count: 1_184)
        )

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await store.upsert(deviceId: canonicalId, kemPublicKeys: [oldKey])
        try await Task.sleep(for: .milliseconds(20))
        await store.upsert(deviceId: legacyAlias, kemPublicKeys: [newKey])

        await store.rebindCanonicalDeviceId(canonicalId, legacyIdentifiers: [legacyAlias])

        let rebound = await store.kemPublicKeys(for: canonicalId)
        let legacy = await store.kemPublicKeys(for: legacyAlias)

        XCTAssertEqual(rebound[.mlkem768], newKey.publicKey)
        XCTAssertTrue(legacy.isEmpty)
    }

    func testSignedKEMRefreshImportsXWingAcrossAliasesAndTracksGeneration() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let endpointAlias = "host:192.168.10.44"
        let kemPublicKey = Data(repeating: 0x42, count: 1_216)
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            aliases: [endpointAlias],
            kemPublicKey: kemPublicKey,
            generation: 1_000
        )
        let payload = exchange.payload

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        try await store.upsertSignedKEMRefresh(
            deviceIds: [endpointAlias],
            payload: payload,
            request: exchange.request,
            pinnedProtocolFingerprints: [payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )

        let byCanonical = await store.kemPublicKeys(for: canonicalId)
        let byAlias = await store.kemPublicKeys(for: endpointAlias)
        let endpointOnlyEvidence = await store.signedRefreshEvidence(forAny: [endpointAlias])
        let generation = await store.maximumKEMGeneration(forAny: [canonicalId, endpointAlias])
        let evidence = await store.signedRefreshEvidence(forAny: [canonicalId, endpointAlias])

        XCTAssertEqual(byCanonical[.xwing], kemPublicKey)
        XCTAssertNil(byAlias[.xwing])
        XCTAssertNil(endpointOnlyEvidence)
        XCTAssertEqual(generation, 1_000)
        XCTAssertEqual(evidence?.deviceId, canonicalId)
        XCTAssertEqual(evidence?.suiteWireIds, [CryptoSuite.xwing.wireId])
        XCTAssertEqual(evidence?.source, "signed_lan_kem_refresh")
        XCTAssertEqual(evidence?.generation, 1_000)
        XCTAssertEqual(evidence?.keyId, "skr1-test-1000")
        XCTAssertEqual(evidence?.protocolIdentityFingerprint, payload.protocolIdentityFingerprint)
        XCTAssertEqual(evidence?.signingFingerprint, payload.protocolIdentityFingerprint)
        let evidenceExpiresAt = try XCTUnwrap(evidence?.expiresAt)
        XCTAssertEqual(evidenceExpiresAt.timeIntervalSince1970, payload.expiresAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(evidence?.payloadHashHex, Self.sha256Hex(payload.signaturePreimage))

        let aliasFirstEvidence = await store.signedRefreshEvidence(forAny: [endpointAlias, canonicalId])
        XCTAssertEqual(aliasFirstEvidence?.deviceId, canonicalId)

        await store.upsert(deviceId: canonicalId, kemPublicKeys: payload.kemPublicKeys)
        let preservedEvidence = await store.signedRefreshEvidence(forAny: [canonicalId, endpointAlias])
        XCTAssertEqual(preservedEvidence?.source, "signed_lan_kem_refresh")
        XCTAssertEqual(preservedEvidence?.payloadHashHex, Self.sha256Hex(payload.signaturePreimage))

        let unsignedLegacyKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.mlkem768.wireId,
            publicKey: Data(repeating: 0x24, count: 1_184)
        )
        let legacyAlias = "bonjour:lza的macbook pro@local."
        await store.upsert(deviceId: legacyAlias, kemPublicKeys: [unsignedLegacyKey])
        await store.rebindCanonicalDeviceId(canonicalId, legacyIdentifiers: [endpointAlias, legacyAlias])
        let reboundEvidence = await store.signedRefreshEvidence(forAny: [canonicalId, endpointAlias, legacyAlias])
        XCTAssertEqual(reboundEvidence?.source, "signed_lan_kem_refresh")
        XCTAssertEqual(reboundEvidence?.suiteWireIds, [CryptoSuite.xwing.wireId])
        XCTAssertEqual(reboundEvidence?.payloadHashHex, Self.sha256Hex(payload.signaturePreimage))
    }

    func testSignedRefreshKeyMaterialBeatsNewerUnsignedAliasForSameSuite() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshSelectionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.selection.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let legacyAlias = "bonjour:lza的macbook pro@local."
        let signedKey = Data(repeating: 0x42, count: 1_216)
        let unsignedAliasKey = Data(repeating: 0x99, count: 1_216)
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: signedKey,
            generation: 1_100
        )
        let payload = exchange.payload

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        try await store.upsertSignedKEMRefresh(
            deviceIds: [canonicalId],
            payload: payload,
            request: exchange.request,
            pinnedProtocolFingerprints: [payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )
        try await Task.sleep(for: .milliseconds(20))
        await store.upsert(
            deviceId: legacyAlias,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: unsignedAliasKey
                )
            ]
        )

        let resolved = await store.kemPublicKeys(forAny: [canonicalId, legacyAlias])
        let evidence = await store.signedRefreshEvidence(forAny: [canonicalId, legacyAlias])

        XCTAssertEqual(resolved[.xwing], signedKey)
        XCTAssertEqual(evidence?.suiteWireIds, [CryptoSuite.xwing.wireId])
        XCTAssertEqual(evidence?.source, "signed_lan_kem_refresh")

        await store.rebindCanonicalDeviceId(canonicalId, legacyIdentifiers: [legacyAlias])
        let rebound = await store.kemPublicKeys(for: canonicalId)
        let legacyAfterRebind = await store.kemPublicKeys(for: legacyAlias)
        let reboundEvidence = await store.signedRefreshEvidence(forAny: [canonicalId, legacyAlias])

        XCTAssertEqual(rebound[.xwing], signedKey)
        XCTAssertTrue(legacyAfterRebind.isEmpty)
        XCTAssertEqual(reboundEvidence?.suiteWireIds, [CryptoSuite.xwing.wireId])
        XCTAssertEqual(reboundEvidence?.source, "signed_lan_kem_refresh")
        XCTAssertEqual(reboundEvidence?.keyId, payload.keyId)
        XCTAssertEqual(reboundEvidence?.generation, payload.generation)
        XCTAssertEqual(reboundEvidence?.payloadHashHex, Self.sha256Hex(payload.signaturePreimage))
    }

    func testRawUpsertRejectsUnknownClassicAndWrongLengthKEM() async throws {
        let suiteName = "KEMTrustStoreRawRejectTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.raw.reject.tests.v1"
        let deviceId = "peer-\(UUID().uuidString)"
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        await store.upsert(
            deviceId: deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: 0x0000, publicKey: Data(repeating: 0x00, count: 1_216)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.x25519Ed25519.wireId, publicKey: Data(repeating: 0x11, count: 32)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: Data(repeating: 0x22, count: 32)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: Data(repeating: 0x23, count: 1_184)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768.wireId, publicKey: Data(repeating: 0x24, count: 1_216)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768fs.wireId, publicKey: Data(repeating: 0x25, count: 1_216))
            ]
        )
        let rejected = await store.kemPublicKeys(for: deviceId)
        XCTAssertTrue(rejected.isEmpty)

        let validXWing = Data(repeating: 0x33, count: 1_216)
        let validMLKEM = Data(repeating: 0x34, count: 1_184)
        let validMLKEMFS = Data(repeating: 0x35, count: 1_184)
        await store.upsert(
            deviceId: deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwing.wireId, publicKey: validXWing),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768.wireId, publicKey: validMLKEM),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768fs.wireId, publicKey: validMLKEMFS)
            ]
        )
        let accepted = await store.kemPublicKeys(for: deviceId)
        XCTAssertEqual(accepted[.xwing], validXWing)
        XCTAssertEqual(accepted[.mlkem768], validMLKEM)
        XCTAssertEqual(accepted[.mlkem768fs], validMLKEMFS)
    }

    func testLoadPurgesLegacyPersistedInvalidKEMMaterial() async throws {
        let suiteName = "KEMTrustStoreLegacyPurgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.legacy.purge.tests.v1"
        let validMLKEM = Data(repeating: 0x44, count: 1_184)
        let legacyCache = [
            "peer-legacy": LegacyStoredPeer(
                keys: [
                    0x0000: Data(repeating: 0x00, count: 1_216),
                    CryptoSuite.x25519Ed25519.wireId: Data(repeating: 0x11, count: 32),
                    CryptoSuite.xwing.wireId: Data(repeating: 0x22, count: 32),
                    CryptoSuite.mlkem768.wireId: validMLKEM
                ],
                updatedAt: Date()
            )
        ]
        defaults.set(try JSONEncoder().encode(legacyCache), forKey: storageKey)

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        let loaded = await store.kemPublicKeys(for: "peer-legacy")

        XCTAssertEqual(loaded, [.mlkem768: validMLKEM])
    }

    func testRebindCanonicalDeviceIdKeepsOnlySanitizedSignedKEMMaterial() async throws {
        let suiteName = "KEMTrustStoreRebindSanitizedTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.rebind.sanitized.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let legacyAlias = "bonjour:lza的macbook pro@local."
        let validXWing = Data(repeating: 0x71, count: 1_216)
        let legacyCache = [
            legacyAlias: LegacyStoredPeer(
                keys: [
                    0x0000: Data(repeating: 0x00, count: 1_216),
                    CryptoSuite.x25519Ed25519.wireId: Data(repeating: 0x11, count: 32),
                    CryptoSuite.xwing.wireId: validXWing,
                    CryptoSuite.mlkem768.wireId: Data(repeating: 0x22, count: 32)
                ],
                updatedAt: Date(),
                source: "signed_lan_kem_refresh",
                keyId: "legacy-skr1",
                generation: 7,
                expiresAt: Date().addingTimeInterval(300),
                protocolIdentityFingerprint: String(repeating: "a", count: 64),
                signingFingerprint: String(repeating: "a", count: 64),
                payloadHashHex: String(repeating: "b", count: 64),
                signedSuiteWireIds: [
                    0x0000,
                    CryptoSuite.x25519Ed25519.wireId,
                    CryptoSuite.xwing.wireId,
                    CryptoSuite.mlkem768.wireId
                ]
            )
        ]
        defaults.set(try JSONEncoder().encode(legacyCache), forKey: storageKey)

        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await store.rebindCanonicalDeviceId(canonicalId, legacyIdentifiers: [legacyAlias])

        let rebound = await store.kemPublicKeys(for: canonicalId)
        let evidence = await store.signedRefreshEvidence(forAny: [canonicalId, legacyAlias])

        XCTAssertEqual(rebound, [.xwing: validXWing])
        XCTAssertEqual(evidence?.suiteWireIds, [CryptoSuite.xwing.wireId])
        XCTAssertEqual(evidence?.source, "signed_lan_kem_refresh")
        XCTAssertEqual(evidence?.keyId, "legacy-skr1")
    }

    func testSignedKEMRefreshRejectsExpiredAndRollbackPayloads() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshRejectTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.reject.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let currentKey = Data(repeating: 0x55, count: 1_216)
        let rollbackKey = Data(repeating: 0x66, count: 1_216)
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        let currentExchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: currentKey,
            generation: 2_000
        )
        let currentPayload = currentExchange.payload

        try await store.upsertSignedKEMRefresh(
            deviceIds: [canonicalId],
            payload: currentPayload,
            request: currentExchange.request,
            pinnedProtocolFingerprints: [currentPayload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )

        let rollbackExchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: rollbackKey,
            generation: 1_999
        )
        let rollbackPayload = rollbackExchange.payload
        let existingGeneration = await store.maximumKEMGeneration(forAny: [canonicalId])
        XCTAssertThrowsError(
            try rollbackPayload.validatedForStrictPQCImport(
                request: rollbackExchange.request,
                pinnedProtocolFingerprints: [rollbackPayload.protocolIdentityFingerprint],
                minimumGeneration: existingGeneration
            )
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .generationRollback(current: 2_000, incoming: 1_999)
            )
        }

        let expiredExchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: rollbackKey,
            generation: 2_001,
            payloadSentAt: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 11)
        )
        let expiredPayload = expiredExchange.payload
        await XCTAssertThrowsErrorAsync(
            try await store.upsertSignedKEMRefresh(
                deviceIds: [canonicalId],
                payload: expiredPayload,
                request: expiredExchange.request,
                pinnedProtocolFingerprints: [expiredPayload.protocolIdentityFingerprint],
                minimumGeneration: await store.maximumKEMGeneration(forAny: [canonicalId])
            )
        ) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .expired)
        }

        let storedKeys = await store.kemPublicKeys(for: canonicalId)
        XCTAssertEqual(storedKeys[.xwing], currentKey)
    }

    func testSignedKEMRefreshStoreRejectsMissingExternalPin() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshMissingPinTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.missing.pin.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: Data(repeating: 0x77, count: 1_216),
            generation: 3_000
        )
        let payload = exchange.payload
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        await XCTAssertThrowsErrorAsync(
            try await store.upsertSignedKEMRefresh(
                deviceIds: [canonicalId],
                payload: payload,
                request: exchange.request,
                pinnedProtocolFingerprints: [],
                minimumGeneration: nil
            )
        ) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .missingPinnedProtocolIdentity)
        }
        let storedKeys = await store.kemPublicKeys(for: canonicalId)
        XCTAssertTrue(storedKeys.isEmpty)
    }

    func testSignedKEMRefreshStoreRejectsInvalidSignatureAtImportBoundary() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshInvalidSignatureTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.invalid.signature.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: Data(repeating: 0x88, count: 1_216),
            generation: 4_000
        )
        let payload = exchange.payload
        var badSignature = payload.signature
        badSignature[badSignature.startIndex] ^= 0xFF
        let tampered = AppMessage.SignedKEMRefreshPayload(
            deviceId: payload.deviceId,
            aliases: payload.aliases,
            protocolSigningAlgorithm: payload.protocolSigningAlgorithm,
            protocolIdentityPublicKey: payload.protocolIdentityPublicKey,
            protocolIdentityFingerprint: payload.protocolIdentityFingerprint,
            kemPublicKeys: payload.kemPublicKeys,
            keyId: payload.keyId,
            generation: payload.generation,
            sentAt: payload.sentAt,
            expiresAt: payload.expiresAt,
            requestNonce: payload.requestNonce,
            requestHashHex: payload.requestHashHex,
            policyRequirePQC: payload.policyRequirePQC,
            policyAllowClassicFallback: payload.policyAllowClassicFallback,
            routeScope: payload.routeScope,
            bonjourEndpointDigest: payload.bonjourEndpointDigest,
            signature: badSignature
        )
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        await XCTAssertThrowsErrorAsync(
            try await store.upsertSignedKEMRefresh(
                deviceIds: [canonicalId],
                payload: tampered,
                request: exchange.request,
                pinnedProtocolFingerprints: [payload.protocolIdentityFingerprint],
                minimumGeneration: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? KEMTrustStore.SignedRefreshImportError,
                .signatureVerificationFailed
            )
        }
        let storedKeys = await store.kemPublicKeys(for: canonicalId)
        XCTAssertTrue(storedKeys.isEmpty)
    }

    func testSignedKEMRefreshStoreRejectsUnrequestedSuiteAtImportBoundary() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshUnrequestedSuiteTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.unrequested.suite.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: Data(repeating: 0x91, count: 1_184),
            kemSuite: .mlkem768MLDSA65,
            requestedSuiteWireIds: [CryptoSuite.xwing.wireId],
            generation: 4_100
        )
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        await XCTAssertThrowsErrorAsync(
            try await store.upsertSignedKEMRefresh(
                deviceIds: [canonicalId],
                payload: exchange.payload,
                request: exchange.request,
                pinnedProtocolFingerprints: [exchange.payload.protocolIdentityFingerprint],
                minimumGeneration: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .responseSuiteNotRequested(wireId: CryptoSuite.mlkem768MLDSA65.wireId)
            )
        }

        let storedKeys = await store.kemPublicKeys(for: canonicalId)
        let evidence = await store.signedRefreshEvidence(forAny: [canonicalId])
        XCTAssertTrue(storedKeys.isEmpty)
        XCTAssertNil(evidence)
    }

    func testRawUpsertDoesNotReviveExpiredSignedRefreshKeys() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshExpiryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.expiry.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let signedKey = Data(repeating: 0x92, count: 1_216)
        let rawKey = Data(repeating: 0x93, count: 1_184)
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: signedKey,
            generation: 4_200,
            expiresAt: Date().addingTimeInterval(0.05)
        )
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        try await store.upsertSignedKEMRefresh(
            deviceIds: [canonicalId],
            payload: exchange.payload,
            request: exchange.request,
            pinnedProtocolFingerprints: [exchange.payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )
        try await Task.sleep(for: .milliseconds(80))

        await store.upsert(
            deviceId: canonicalId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: rawKey
                )
            ]
        )

        let storedKeys = await store.kemPublicKeys(for: canonicalId)
        let evidence = await store.signedRefreshEvidence(forAny: [canonicalId])
        XCTAssertNil(storedKeys[.xwing])
        XCTAssertEqual(storedKeys[.mlkem768MLDSA65], rawKey)
        XCTAssertNil(evidence)
    }

    private func makeSignedKEMRefreshExchange(
        deviceId: String,
        aliases: [String] = [],
        kemPublicKey: Data,
        kemSuite: CryptoSuite = .xwing,
        requestedSuiteWireIds: [UInt16]? = nil,
        generation: UInt64,
        payloadSentAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(300)
    ) throws -> (
        request: AppMessage.KEMRefreshRequestPayload,
        payload: AppMessage.SignedKEMRefreshPayload
    ) {
        let signingKey = Curve25519.Signing.PrivateKey()
        let protocolPublicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .ed25519
        ).authoritativeFingerprint.lowercased()
        let bonjourEndpointDigest = String(repeating: "b", count: 64)
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-kem-store-test",
            targetDeviceId: deviceId,
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: requestedSuiteWireIds ?? [kemSuite.wireId],
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: bonjourEndpointDigest,
            nonce: Data(repeating: 0xC1, count: 24)
        )

        let unsigned = AppMessage.SignedKEMRefreshPayload(
            deviceId: deviceId,
            aliases: aliases,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: kemSuite.wireId,
                    publicKey: kemPublicKey
                )
            ],
            keyId: "skr1-test-\(generation)",
            generation: generation,
            sentAt: payloadSentAt,
            expiresAt: expiresAt,
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: bonjourEndpointDigest,
            signature: Data()
        )
        let signature = try signingKey.signature(for: unsigned.signaturePreimage)
        let payload = AppMessage.SignedKEMRefreshPayload(
            deviceId: unsigned.deviceId,
            aliases: unsigned.aliases,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolIdentityPublicKey: unsigned.protocolIdentityPublicKey,
            protocolIdentityFingerprint: unsigned.protocolIdentityFingerprint,
            kemPublicKeys: unsigned.kemPublicKeys,
            keyId: unsigned.keyId,
            generation: unsigned.generation,
            sentAt: unsigned.sentAt,
            expiresAt: unsigned.expiresAt,
            requestNonce: unsigned.requestNonce,
            requestHashHex: unsigned.requestHashHex,
            policyRequirePQC: unsigned.policyRequirePQC,
            policyAllowClassicFallback: unsigned.policyAllowClassicFallback,
            routeScope: unsigned.routeScope,
            bonjourEndpointDigest: unsigned.bonjourEndpointDigest,
            signature: signature
        )
        return (request, payload)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct LegacyStoredPeer: Codable {
        var keys: [UInt16: Data]
        var updatedAt: Date
        var source: String? = "pairing_identity_exchange"
        var keyId: String? = nil
        var generation: UInt64? = nil
        var expiresAt: Date? = nil
        var protocolIdentityFingerprint: String? = nil
        var signingFingerprint: String? = nil
        var payloadHashHex: String? = nil
        var signedSuiteWireIds: [UInt16]? = nil
    }
}

@available(iOS 17.0, *)
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
