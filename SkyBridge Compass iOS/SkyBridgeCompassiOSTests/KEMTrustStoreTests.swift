import CryptoKit
import Foundation
import XCTest
@testable import SkyBridgeCompass_iOS

private final class NetworkContentProcessedSubmissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Void, Error>) -> Void)?
    private var submitCount = 0
    private var cancelCount = 0

    func install(
        _ completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        lock.lock()
        submitCount += 1
        self.completion = completion
        lock.unlock()
    }

    func recordCancel() {
        lock.lock()
        cancelCount += 1
        lock.unlock()
    }

    var counts: (submits: Int, cancels: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (submitCount, cancelCount)
    }

    func finish(_ result: Result<Void, Error>) {
        let completion: (@Sendable (Result<Void, Error>) -> Void)?
        lock.lock()
        completion = self.completion
        lock.unlock()
        completion?(result)
    }
}

@available(iOS 17.0, *)
final class KEMTrustStoreTests: XCTestCase {
    func testDefaultPQCSuitesExcludeQPeriaptBeta() {
        XCTAssertEqual(CryptoSuite.explicitBetaPQCSuites, [])
        XCTAssertFalse(CryptoSuite.allPQCSuites.contains(.qperiaptContextBound))
        XCTAssertFalse(CryptoSuite.allPQCSuites.contains(.qperiaptABI2PolicyBound))
        XCTAssertTrue(CryptoSuite.qperiaptContextBound.isLegacyOnly)
        XCTAssertFalse(CryptoSuite.qperiaptContextBound.isNegotiable)
        XCTAssertTrue(CryptoSuite.qperiaptABI2PolicyBound.isNegotiable)
        XCTAssertFalse(CryptoSuite.qperiaptABI2PolicyBound.isDecodeOnly)
        XCTAssertTrue(CryptoSuite.allPQCSuites.contains(.xwing))
    }

    func testQPeriaptMirrorNormalizationRequiresEligiblePeerPlatform() {
        let qPeriaptKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.qperiaptABI2PolicyBound.wireId,
            publicKey: Data(repeating: 0x11, count: 1_216)
        )
        let legacyQPeriaptKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.qperiaptContextBound.wireId,
            publicKey: Data(repeating: 0x12, count: 1_216)
        )
        let xWingKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwing.wireId,
            publicKey: Data(repeating: 0x22, count: 1_216)
        )

        let missingPlatform = KEMPublicKeyInfo.normalizedValidKeys(
            [qPeriaptKey, legacyQPeriaptKey, xWingKey],
            platform: nil,
            osVersion: "iOS 26.0"
        )
        XCTAssertEqual(missingPlatform.map(\.suiteWireId), [CryptoSuite.xwing.wireId])

        let oldAndroidApi = KEMPublicKeyInfo.normalizedValidKeys(
            [qPeriaptKey, legacyQPeriaptKey, xWingKey],
            platform: "Android",
            osVersion: "Android 16 (API 35)"
        )
        XCTAssertEqual(oldAndroidApi.map(\.suiteWireId), [CryptoSuite.xwing.wireId])

        let currentIOS = KEMPublicKeyInfo.normalizedValidKeys(
            [qPeriaptKey, legacyQPeriaptKey, xWingKey],
            platform: "iOS",
            osVersion: "iOS 26.0"
        )
        XCTAssertEqual(
            currentIOS.map(\.suiteWireId),
            [
                CryptoSuite.xwing.wireId,
                CryptoSuite.qperiaptABI2PolicyBound.wireId
            ]
        )
    }

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

    func testAuthorityBoundJoinBootstrapRequiresExactProtocolPin() async throws {
        let suiteName = "KEMTrustStoreAuthorityBoundJoinTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let store = KEMTrustStore(
            storageKey: "kem_trust_store.authority.join.tests.v1",
            userDefaults: defaults
        )
        let deviceId = "device-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)
        let publicKey = Data(repeating: 0x51, count: 1_216)
        try await store.upsertAuthorityBoundBootstrap(
            deviceIds: [deviceId],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: publicKey
                )
            ],
            verifiedProtocolFingerprint: fingerprint
        )

        let unbound = await store.signedRefreshKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprint]
        )
        let wrongPin = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [String(repeating: "b", count: 64)]
        )
        let exactPin = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprint.uppercased()]
        )

        XCTAssertTrue(unbound.isEmpty)
        XCTAssertTrue(wrongPin.isEmpty)
        XCTAssertEqual(exactPin[.xwing], publicKey)
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

    func testRebindCanonicalDeviceIdDoesNotPromoteNewerEndpointAliasMaterial() async throws {
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

        XCTAssertEqual(rebound[.mlkem768], oldKey.publicKey)
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

    func testSignedRefreshKEMLookupRequiresSignedSourceAndPinnedProtocolFingerprint() async throws {
        let suiteName = "KEMTrustStoreSignedRefreshFilteredLookupTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let storageKey = "kem_trust_store.signed.refresh.filtered.lookup.tests.v1"
        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let unsignedKey = Data(repeating: 0x36, count: 1_184)
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        await store.upsert(
            deviceId: canonicalId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768.wireId,
                    publicKey: unsignedKey
                )
            ]
        )

        let unsignedOnly = await store.signedRefreshKEMPublicKeys(
            forAny: [canonicalId],
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)]
        )
        XCTAssertTrue(unsignedOnly.isEmpty)

        let signedKey = Data(repeating: 0x37, count: 1_216)
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: signedKey,
            generation: 1_111
        )
        let payload = exchange.payload
        try await store.upsertSignedKEMRefresh(
            deviceIds: [canonicalId],
            payload: payload,
            request: exchange.request,
            pinnedProtocolFingerprints: [payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )

        let wrongPin = await store.signedRefreshKEMPublicKeys(
            forAny: [canonicalId],
            pinnedProtocolFingerprints: [String(repeating: "f", count: 64)]
        )
        let rightPin = await store.signedRefreshKEMPublicKeys(
            forAny: [canonicalId],
            pinnedProtocolFingerprints: [payload.protocolIdentityFingerprint.uppercased()]
        )

        XCTAssertTrue(wrongPin.isEmpty)
        XCTAssertNil(rightPin[.mlkem768])
        XCTAssertEqual(rightPin[.xwing], signedKey)
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

    func testLoadRejectsLegacyEndpointSignedMetadataInsteadOfPromotingIt() async throws {
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
        let storedPeerCount = await store.testOnlyStoredPeerCount()

        XCTAssertTrue(rebound.isEmpty)
        XCTAssertNil(evidence)
        XCTAssertEqual(storedPeerCount, 0)
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

    func testAuthorityBoundKEMMutationRollbackRestoresMemoryAndPersistence() async throws {
        let suiteName = "KEMTrustStoreRollbackTests.\(UUID().uuidString)"
        let storageKey = "kem_trust_store.rollback.tests.v1"
        let deviceId = "id:11111111-2222-4333-8444-555555555555"
        let fingerprint = String(repeating: "a", count: 64)
        let kemKey = Data(repeating: 0x71, count: 1_216)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        let receipt = try await store.upsertAuthorityBoundBootstrap(
            deviceIds: [deviceId],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: kemKey
                )
            ],
            verifiedProtocolFingerprint: fingerprint
        )
        let committedKeys = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprint]
        )
        XCTAssertEqual(committedKeys[.xwing], kemKey)

        try await store.rollbackAuthorityBoundMutation(receipt)
        let rolledBackKeys = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprint]
        )
        XCTAssertTrue(rolledBackKeys.isEmpty)
        guard let reloadedDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to reopen isolated UserDefaults suite")
            return
        }
        let restored = KEMTrustStore(
            storageKey: storageKey,
            userDefaults: reloadedDefaults
        )
        let reloadedKeys = await restored.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprint]
        )
        XCTAssertTrue(reloadedKeys.isEmpty)
    }

    func testAuthorityBoundKEMRollbackPreservesConcurrentFingerprintOnSamePeer() async throws {
        let suiteName = "KEMTrustStoreFieldRollbackTests.\(UUID().uuidString)"
        let storageKey = "kem_trust_store.field.rollback.tests.v1"
        let deviceId = "id:22222222-3333-4444-8555-666666666666"
        let fingerprintA = String(repeating: "a", count: 64)
        let fingerprintB = String(repeating: "b", count: 64)
        let keyA = Data(repeating: 0x41, count: 1_216)
        let keyB = Data(repeating: 0x42, count: 1_184)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        let receiptA = try await store.upsertAuthorityBoundBootstrap(
            deviceIds: [deviceId],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: keyA
                )
            ],
            verifiedProtocolFingerprint: fingerprintA
        )
        _ = try await store.upsertAuthorityBoundBootstrap(
            deviceIds: [deviceId],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768.wireId,
                    publicKey: keyB
                )
            ],
            verifiedProtocolFingerprint: fingerprintB
        )

        try await store.rollbackAuthorityBoundMutation(receiptA)

        let rolledBackA = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprintA]
        )
        let preservedB = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprintB]
        )
        XCTAssertTrue(rolledBackA.isEmpty)
        XCTAssertEqual(preservedB[.mlkem768], keyB)

        let reloaded = KEMTrustStore(
            storageKey: storageKey,
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        let reloadedB = await reloaded.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId],
            pinnedProtocolFingerprints: [fingerprintB]
        )
        XCTAssertEqual(reloadedB[.mlkem768], keyB)
    }

    func testCorruptedKEMPersistenceFailsClosedWithoutOverwritingStoredBytes() async throws {
        let suiteName = "KEMTrustStoreCorruptionTests.\(UUID().uuidString)"
        let storageKey = "kem_trust_store.corruption.tests.v1"
        let corruptedData = Data("{not-valid-json".utf8)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(corruptedData, forKey: storageKey)
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)

        let keys = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: ["id:11111111-2222-4333-8444-555555555555"],
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)]
        )
        XCTAssertTrue(keys.isEmpty)
        do {
            _ = try await store.upsertAuthorityBoundBootstrap(
                deviceIds: ["id:11111111-2222-4333-8444-555555555555"],
                kemPublicKeys: [
                    KEMPublicKeyInfo(
                        suiteWireId: CryptoSuite.xwing.wireId,
                        publicKey: Data(repeating: 0x41, count: 1_216)
                    )
                ],
                verifiedProtocolFingerprint: String(repeating: "a", count: 64)
            )
            XCTFail("A corrupted trust store must reject authority writes")
        } catch KEMTrustStore.PersistenceError.persistenceUnavailable {
            // Expected: corruption cannot be reinterpreted as an empty trust store.
        } catch {
            XCTFail("Unexpected corruption error: \(String(reflecting: error))")
        }

        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(reopenedDefaults.data(forKey: storageKey), corruptedData)
    }

    func testAuthorityBoundRollbackRestoresPeersEvictedByCapacityPruning() async throws {
        let suiteName = "KEMTrustStoreCapacityRollbackTests.\(UUID().uuidString)"
        let storageKey = "kem_trust_store.capacity.rollback.tests.v1"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = KEMTrustStore(storageKey: storageKey, userDefaults: defaults)
        let fingerprint = String(repeating: "b", count: 64)
        let seedKey = Data(repeating: 0x52, count: 1_216)
        let seedDeviceIds = (0..<1_024).map { index in
            String(format: "id:00000000-0000-4000-8000-%012x", index)
        }
        try await store.testOnlyReplaceWithAuthorityBoundPeers(
            deviceIds: seedDeviceIds,
            kemPublicKey: KEMPublicKeyInfo(
                suiteWireId: CryptoSuite.xwing.wireId,
                publicKey: seedKey
            ),
            protocolFingerprint: fingerprint
        )
        let oldestDeviceId = try XCTUnwrap(seedDeviceIds.first)
        let before = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [oldestDeviceId],
            pinnedProtocolFingerprints: [fingerprint]
        )
        XCTAssertEqual(before[.xwing], seedKey)

        let receipt = try await store.upsertAuthorityBoundBootstrap(
            deviceIds: ["id:ffffffff-ffff-4fff-8fff-ffffffffffff"],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: Data(repeating: 0x63, count: 1_216)
                )
            ],
            verifiedProtocolFingerprint: fingerprint
        )
        let afterPrune = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [oldestDeviceId],
            pinnedProtocolFingerprints: [fingerprint]
        )
        XCTAssertTrue(afterPrune.isEmpty)

        try await store.rollbackAuthorityBoundMutation(receipt)
        let restored = await store.authorityBoundBootstrapKEMPublicKeys(
            forAny: [oldestDeviceId],
            pinnedProtocolFingerprints: [fingerprint]
        )
        let restoredCount = await store.testOnlyStoredPeerCount()
        XCTAssertEqual(restored[.xwing], seedKey)
        XCTAssertEqual(restoredCount, seedDeviceIds.count)
    }

    func testAuthorityBoundProtocolIdentityRollbackAndConflictAreAtomic() async throws {
        let suiteName = "ProtocolIdentityTrustStoreRollbackTests.\(UUID().uuidString)"
        let storageKey = "protocol_identity_trust_store.rollback.tests.v1"
        let deviceId = "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = ProtocolIdentityTrustStore(
            storageKey: storageKey,
            userDefaults: defaults
        )
        let firstKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let replacementKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let firstIdentity = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            publicKey: firstKey
        )
        let replacementIdentity = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            publicKey: replacementKey
        )

        let receipt = try await store.upsertAuthorityBound(
            deviceId: deviceId,
            protocolIdentityPublicKeys: [firstIdentity]
        )
        let committedKey = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .ed25519
        )
        XCTAssertEqual(committedKey, firstKey)
        do {
            _ = try await store.upsertAuthorityBound(
                deviceId: deviceId,
                protocolIdentityPublicKeys: [replacementIdentity]
            )
            XCTFail("A conflicting authority-bound identity must be rejected")
        } catch let error as ProtocolIdentityTrustStore.AuthorityBoundUpdateError {
            XCTAssertEqual(
                error,
                .conflictingIdentity(algorithm: ProtocolSigningAlgorithm.ed25519.rawValue)
            )
        } catch {
            XCTFail("Unexpected conflict error type: \(String(reflecting: error))")
        }
        let unchangedKey = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .ed25519
        )
        XCTAssertEqual(unchangedKey, firstKey)

        try await store.rollbackAuthorityBoundMutation(receipt)
        let rolledBackKey = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .ed25519
        )
        XCTAssertNil(rolledBackKey)
        let restored = ProtocolIdentityTrustStore(
            storageKey: storageKey,
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        let reloadedKey = await restored.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .ed25519
        )
        XCTAssertNil(reloadedKey)
    }

    func testProtocolIdentityRollbackPreservesConcurrentAlgorithmOnSamePeer() async throws {
        let suiteName = "ProtocolIdentityFieldRollbackTests.\(UUID().uuidString)"
        let storageKey = "protocol_identity_trust_store.field.rollback.tests.v1"
        let deviceId = "id:bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ProtocolIdentityTrustStore(
            storageKey: storageKey,
            userDefaults: defaults
        )
        let ed25519Key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let mlDSA65Key = Data(repeating: 0x65, count: 1_952)

        let ed25519Receipt = try await store.upsertAuthorityBound(
            deviceId: deviceId,
            protocolIdentityPublicKeys: [
                AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    publicKey: ed25519Key
                )
            ]
        )
        _ = try await store.upsertAuthorityBound(
            deviceId: deviceId,
            protocolIdentityPublicKeys: [
                AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                    publicKey: mlDSA65Key
                )
            ]
        )

        try await store.rollbackAuthorityBoundMutation(ed25519Receipt)

        let rolledBackEd25519 = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .ed25519
        )
        let preservedMLDSA = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .mlDSA65
        )
        XCTAssertNil(rolledBackEd25519)
        XCTAssertEqual(preservedMLDSA, mlDSA65Key)

        let reloaded = ProtocolIdentityTrustStore(
            storageKey: storageKey,
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        let reloadedMLDSA = await reloaded.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .mlDSA65
        )
        XCTAssertEqual(reloadedMLDSA, mlDSA65Key)
    }

    func testProtocolIdentityLoadRejectsEndpointAndMalformedAuthorityRows() async throws {
        let suiteName = "ProtocolIdentityTrustStoreStableLoadTests.\(UUID().uuidString)"
        let storageKey = "protocol_identity_trust_store.stable.load.tests.v1"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let stableId = "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let endpointAlias = "bonjour:fixture macbook pro@local."
        let malformedId = "id:fixture macbook pro"
        let fingerprint = String(repeating: "a", count: 64)
        let peer = LegacyProtocolIdentityStoredPeer(
            fingerprints: [fingerprint],
            updatedAt: Date()
        )
        defaults.set(
            try JSONEncoder().encode([
                stableId: peer,
                endpointAlias: peer,
                malformedId: peer
            ]),
            forKey: storageKey
        )

        let store = ProtocolIdentityTrustStore(
            storageKey: storageKey,
            userDefaults: defaults
        )
        let matchingDeviceIds = await store.deviceIds(containingFingerprint: fingerprint)
        let endpointFingerprints = await store.trustedFingerprints(for: endpointAlias)
        let malformedFingerprints = await store.trustedFingerprints(for: malformedId)
        let storedPeerCount = await store.testOnlyStoredPeerCount()

        XCTAssertEqual(matchingDeviceIds, [stableId])
        XCTAssertTrue(endpointFingerprints.isEmpty)
        XCTAssertTrue(malformedFingerprints.isEmpty)
        XCTAssertEqual(storedPeerCount, 1)
    }

    @MainActor
    func testPairingIdentityJournalRecoversEveryPreCommitCrashPoint() async throws {
        let mutationShape = try makePairingIdentityJournalFixture()
        let protocolCrashPoints = mutationShape.authorizedDeviceIDs.indices.map {
            AuthorityBoundPairingIdentityCrashPoint.afterProtocolWrite(index: $0)
        }
        let crashPoints: [AuthorityBoundPairingIdentityCrashPoint] = [
            .beforeKEMWrite,
            .afterKEMWrite,
        ] + protocolCrashPoints + [.beforeCommittedMarker]

        for crashPoint in crashPoints {
            let fixture = try makePairingIdentityJournalFixture()
            let harness = try makePairingIdentityJournalHarness()
            defer { harness.removePersistentState() }

            do {
                _ = try await AuthorityBoundPairingIdentityPersistence.commit(
                    payload: fixture.payload,
                    authority: fixture.authority,
                    validateCurrentSession: {},
                    kemStore: harness.kemStore,
                    protocolStore: harness.protocolStore,
                    journalStore: harness.journalStore,
                    shouldSimulateCrash: { $0 == crashPoint }
                )
                XCTFail("Expected simulated crash at \(String(describing: crashPoint))")
            } catch {
                XCTAssertTrue(harness.journalStore.journalExists)
            }

            let reopenedStores = try harness.reopenedStores()
            let quarantinedKEM = await reopenedStores.kem
                .authorityBoundBootstrapKEMPublicKeys(
                    forAny: fixture.authorizedDeviceIDs,
                    pinnedProtocolFingerprints: [fixture.fingerprint]
                )
            let quarantinedProtocol = await reopenedStores.protocolIdentity
                .trustedProtocolIdentityPublicKey(
                    forAny: fixture.authorizedDeviceIDs,
                    algorithm: .ed25519
                )
            XCTAssertTrue(quarantinedKEM.isEmpty)
            XCTAssertNil(quarantinedProtocol)
            do {
                _ = try await reopenedStores.kem.upsertAuthorityBoundBootstrap(
                    deviceIds: fixture.authorizedDeviceIDs,
                    kemPublicKeys: fixture.payload.kemPublicKeys,
                    verifiedProtocolFingerprint: fixture.fingerprint
                )
                XCTFail("KEM authority mutation must be rejected during quarantine")
            } catch let error as KEMTrustStore.PersistenceError {
                XCTAssertEqual(error, .authorityTransactionQuarantined)
            }
            do {
                _ = try await reopenedStores.protocolIdentity.upsertAuthorityBound(
                    deviceId: fixture.declaredDeviceID,
                    protocolIdentityPublicKeys: [
                        AppMessage.ProtocolIdentityPublicKeyInfo(
                            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                            publicKey: fixture.protocolPublicKey
                        )
                    ]
                )
                XCTFail("Protocol authority mutation must be rejected during quarantine")
            } catch let error as ProtocolIdentityTrustStore.AuthorityBoundUpdateError {
                XCTAssertEqual(error, .authorityTransactionQuarantined)
            }

            try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
                kemStore: reopenedStores.kem,
                protocolStore: reopenedStores.protocolIdentity,
                journalStore: harness.journalStore
            )
            XCTAssertFalse(harness.journalStore.journalExists)

            let restoredKEM = await reopenedStores.kem
                .authorityBoundBootstrapKEMPublicKeys(
                    forAny: fixture.authorizedDeviceIDs,
                    pinnedProtocolFingerprints: [fixture.fingerprint]
                )
            let restoredProtocol = await reopenedStores.protocolIdentity
                .trustedProtocolIdentityPublicKey(
                    forAny: fixture.authorizedDeviceIDs,
                    algorithm: .ed25519
                )
            XCTAssertTrue(restoredKEM.isEmpty)
            XCTAssertNil(restoredProtocol)
        }
    }

    @MainActor
    func testPairingIdentityJournalRecoversLegacyV2SnapshotTransaction() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }
        let kemMutation = try await harness.kemStore.prepareAuthorityBoundBootstrap(
            deviceIds: fixture.authorizedDeviceIDs,
            kemPublicKeys: fixture.payload.kemPublicKeys,
            verifiedProtocolFingerprint: fixture.fingerprint
        )
        let protocolMutations = try await harness.protocolStore.prepareAuthorityBoundSequence(
            deviceIds: fixture.authorizedDeviceIDs,
            protocolIdentityPublicKeys: [
                AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    publicKey: fixture.protocolPublicKey
                )
            ]
        )
        let protocolBefore = try XCTUnwrap(protocolMutations.first?.before)
        let legacyJournal = AuthorityBoundPairingIdentityJournal(
            schemaVersion: AuthorityBoundPairingIdentityJournal.legacySnapshotSchemaVersion,
            transactionID: UUID(),
            intent: .commit,
            authorizedDeviceIDs: fixture.authorizedDeviceIDs,
            protocolFingerprint: fixture.fingerprint,
            kemBefore: kemMutation.before,
            kemAfter: kemMutation.after,
            protocolBefore: protocolBefore,
            protocolAfterEachMutation: protocolMutations.map(\.after),
            phase: .applying,
            kemApplied: true,
            appliedProtocolMutationCount: 1
        )
        try harness.journalStore.write(legacyJournal)
        try await harness.kemStore.applyPreparedAuthorityBoundMutation(
            kemMutation,
            permitsJournal: true
        )
        try await harness.protocolStore.applyPreparedAuthorityBoundMutation(
            try XCTUnwrap(protocolMutations.first),
            permitsJournal: true
        )

        let reopenedStores = try harness.reopenedStores()
        try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
            kemStore: reopenedStores.kem,
            protocolStore: reopenedStores.protocolIdentity,
            journalStore: harness.journalStore
        )

        XCTAssertFalse(harness.journalStore.journalExists)
        let restoredKEM = await reopenedStores.kem.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        let restoredProtocol = await reopenedStores.protocolIdentity
            .trustedProtocolIdentityPublicKey(
                forAny: fixture.authorizedDeviceIDs,
                algorithm: .ed25519
            )
        XCTAssertTrue(restoredKEM.isEmpty)
        XCTAssertNil(restoredProtocol)
    }

    @MainActor
    func testLegacyV2DecoderFailsClosedOnReceiptJournalAndLeavesItDurable() async throws {
        struct LegacyV2RequiredImages: Decodable {
            let schemaVersion: Int
            let kemBefore: KEMTrustStore.AuthorityBoundSnapshot
        }

        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }
        let kemMutation = try await harness.kemStore.prepareAuthorityBoundBootstrap(
            deviceIds: fixture.authorizedDeviceIDs,
            kemPublicKeys: fixture.payload.kemPublicKeys,
            verifiedProtocolFingerprint: fixture.fingerprint
        )
        let protocolMutations = try await harness.protocolStore.prepareAuthorityBoundSequence(
            deviceIds: fixture.authorizedDeviceIDs,
            protocolIdentityPublicKeys: [
                AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    publicKey: fixture.protocolPublicKey
                )
            ]
        )
        let receiptJournal = AuthorityBoundPairingIdentityJournal(
            schemaVersion: AuthorityBoundPairingIdentityJournal.currentSchemaVersion,
            transactionID: UUID(),
            intent: .commit,
            authorizedDeviceIDs: fixture.authorizedDeviceIDs,
            protocolFingerprint: fixture.fingerprint,
            kemMutationReceipt: kemMutation.receipt,
            protocolMutationReceipts: protocolMutations.map(\.receipt),
            phase: .prepared,
            kemApplied: false,
            appliedProtocolMutationCount: 0,
            kemRolledBack: false,
            rolledBackProtocolMutationCount: 0
        )
        try harness.journalStore.write(receiptJournal)
        let data = try XCTUnwrap(harness.journalStore.loadProtectedData())

        XCTAssertThrowsError(
            try JSONDecoder().decode(LegacyV2RequiredImages.self, from: data)
        )
        XCTAssertTrue(harness.journalStore.journalExists)
    }

    @MainActor
    func testPairingIdentityJournalNormalCommitClearsOnlyAfterVerifiedSuccess() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        _ = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: fixture.payload,
            authority: fixture.authority,
            validateCurrentSession: {},
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )

        XCTAssertFalse(harness.journalStore.journalExists)
        let committedKEM = await harness.kemStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        let committedProtocol = await harness.protocolStore.trustedProtocolIdentityPublicKey(
            forAny: fixture.authorizedDeviceIDs,
            algorithm: .ed25519
        )
        XCTAssertEqual(committedKEM[.xwing], fixture.kemPublicKey)
        XCTAssertEqual(committedProtocol, fixture.protocolPublicKey)
    }

    @MainActor
    func testPairingIdentityJournalNormalRollbackClearsOnlyAfterVerifiedBeforeImages() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        let receipt = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: fixture.payload,
            authority: fixture.authority,
            validateCurrentSession: {},
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )
        let encodedReceipt = try JSONEncoder().encode(receipt)
        let decodedReceipt = try JSONDecoder().decode(
            AuthorityBoundPairingIdentityPersistenceReceipt.self,
            from: encodedReceipt
        )
        XCTAssertEqual(decodedReceipt, receipt)
        try await AuthorityBoundPairingIdentityPersistence.rollback(
            decodedReceipt,
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )

        XCTAssertFalse(harness.journalStore.journalExists)
        let restoredKEM = await harness.kemStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        let restoredProtocol = await harness.protocolStore.trustedProtocolIdentityPublicKey(
            forAny: fixture.authorizedDeviceIDs,
            algorithm: .ed25519
        )
        XCTAssertTrue(restoredKEM.isEmpty)
        XCTAssertNil(restoredProtocol)
    }

    @MainActor
    func testAuthorityReceiptRollForwardRestoresCommittedRecordsAfterRollback() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        let receipt = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: fixture.payload,
            authority: fixture.authority,
            validateCurrentSession: {},
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )
        try await AuthorityBoundPairingIdentityPersistence.rollback(
            receipt,
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )
        try await AuthorityBoundPairingIdentityPersistence.rollForward(
            receipt,
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore
        )

        let receiptMatches = try await AuthorityBoundPairingIdentityPersistence
            .receiptMatchesCommitted(
                receipt,
                kemStore: harness.kemStore,
                protocolStore: harness.protocolStore
            )
        XCTAssertTrue(receiptMatches)
        let restoredKEM = await harness.kemStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )[.xwing]
        XCTAssertEqual(restoredKEM, fixture.kemPublicKey)
        let restoredProtocol = await harness.protocolStore.trustedProtocolIdentityPublicKey(
            forAny: fixture.authorizedDeviceIDs,
            algorithm: .ed25519
        )
        XCTAssertEqual(restoredProtocol, fixture.protocolPublicKey)
    }

    @MainActor
    func testPairingIdentityRollbackPreservesLaterDifferentAuthorityCommit() async throws {
        let authorityA = try makePairingIdentityJournalFixture()
        let authorityB = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        let receiptA = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: authorityA.payload,
            authority: authorityA.authority,
            validateCurrentSession: {},
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )
        _ = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: authorityB.payload,
            authority: authorityB.authority,
            validateCurrentSession: {},
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )

        try await AuthorityBoundPairingIdentityPersistence.rollback(
            receiptA,
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )

        let rolledBackAKEM = await harness.kemStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: authorityA.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [authorityA.fingerprint]
        )
        let preservedBKEM = await harness.kemStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: authorityB.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [authorityB.fingerprint]
        )
        let rolledBackAProtocol = await harness.protocolStore
            .trustedProtocolIdentityPublicKey(
                forAny: authorityA.authorizedDeviceIDs,
                algorithm: .ed25519
            )
        let preservedBProtocol = await harness.protocolStore
            .trustedProtocolIdentityPublicKey(
                forAny: authorityB.authorizedDeviceIDs,
                algorithm: .ed25519
            )
        XCTAssertTrue(rolledBackAKEM.isEmpty)
        XCTAssertNil(rolledBackAProtocol)
        XCTAssertEqual(preservedBKEM[.xwing], authorityB.kemPublicKey)
        XCTAssertEqual(preservedBProtocol, authorityB.protocolPublicKey)
        XCTAssertFalse(harness.journalStore.journalExists)
    }

    @MainActor
    func testPairingIdentityJournalRecoversEveryRollbackCrashPoint() async throws {
        let mutationShape = try makePairingIdentityJournalFixture()
        let protocolRollbackCrashPoints = mutationShape.authorizedDeviceIDs.indices
            .reversed()
            .map {
                AuthorityBoundPairingIdentityCrashPoint.afterRollbackProtocolWrite(index: $0)
            }
        let crashPoints: [AuthorityBoundPairingIdentityCrashPoint] = [
            .beforeRollbackProtocolWrite,
        ] + protocolRollbackCrashPoints + [
            .beforeRollbackKEMWrite,
            .afterRollbackKEMWrite,
            .beforeRollbackCommittedMarker,
            .afterRollbackCommittedMarker
        ]

        for crashPoint in crashPoints {
            let fixture = try makePairingIdentityJournalFixture()
            let harness = try makePairingIdentityJournalHarness()
            defer { harness.removePersistentState() }
            let receipt = try await AuthorityBoundPairingIdentityPersistence.commit(
                payload: fixture.payload,
                authority: fixture.authority,
                validateCurrentSession: {},
                kemStore: harness.kemStore,
                protocolStore: harness.protocolStore,
                journalStore: harness.journalStore,
                shouldSimulateCrash: { _ in false }
            )

            do {
                try await AuthorityBoundPairingIdentityPersistence.rollback(
                    receipt,
                    kemStore: harness.kemStore,
                    protocolStore: harness.protocolStore,
                    journalStore: harness.journalStore,
                    shouldSimulateCrash: { $0 == crashPoint }
                )
                XCTFail("Expected rollback crash at \(String(describing: crashPoint))")
            } catch {
                XCTAssertTrue(harness.journalStore.journalExists)
            }

            let reopenedStores = try harness.reopenedStores()
            let quarantined = await reopenedStores.kem
                .authorityBoundBootstrapKEMPublicKeys(
                    forAny: fixture.authorizedDeviceIDs,
                    pinnedProtocolFingerprints: [fixture.fingerprint]
                )
            XCTAssertTrue(quarantined.isEmpty)
            try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
                kemStore: reopenedStores.kem,
                protocolStore: reopenedStores.protocolIdentity,
                journalStore: harness.journalStore
            )
            XCTAssertFalse(harness.journalStore.journalExists)
            let restoredKEM = await reopenedStores.kem
                .authorityBoundBootstrapKEMPublicKeys(
                    forAny: fixture.authorizedDeviceIDs,
                    pinnedProtocolFingerprints: [fixture.fingerprint]
                )
            let restoredProtocol = await reopenedStores.protocolIdentity
                .trustedProtocolIdentityPublicKey(
                    forAny: fixture.authorizedDeviceIDs,
                    algorithm: .ed25519
                )
            XCTAssertTrue(restoredKEM.isEmpty)
            XCTAssertNil(restoredProtocol)
        }
    }

    @MainActor
    func testPairingIdentityRollbackPreservesConcurrentDifferentFingerprintMutation() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }
        let receipt = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: fixture.payload,
            authority: fixture.authority,
            validateCurrentSession: {},
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )

        let journalBypass: @Sendable () -> Bool = { false }
        let concurrentWriter = try harness.makeKEMStore(
            authorityJournalExists: journalBypass
        )
        let concurrentFingerprint = String(repeating: "d", count: 64)
        let concurrentKey = Data(repeating: 0x74, count: 1_184)
        _ = try await concurrentWriter.upsertAuthorityBoundBootstrap(
            deviceIds: [fixture.declaredDeviceID],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768.wireId,
                    publicKey: concurrentKey
                )
            ],
            verifiedProtocolFingerprint: concurrentFingerprint
        )

        let currentStores = try harness.reopenedStores()
        try await AuthorityBoundPairingIdentityPersistence.rollback(
            receipt,
            kemStore: currentStores.kem,
            protocolStore: currentStores.protocolIdentity,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )

        XCTAssertFalse(harness.journalStore.journalExists)
        let rolledBackAuthority = await currentStores.kem
            .authorityBoundBootstrapKEMPublicKeys(
                forAny: fixture.authorizedDeviceIDs,
                pinnedProtocolFingerprints: [fixture.fingerprint]
            )
        let preservedConcurrentState = await currentStores.kem
            .authorityBoundBootstrapKEMPublicKeys(
                forAny: fixture.authorizedDeviceIDs,
                pinnedProtocolFingerprints: [concurrentFingerprint]
            )
        let rolledBackProtocol = await currentStores.protocolIdentity
            .trustedProtocolIdentityPublicKey(
                forAny: fixture.authorizedDeviceIDs,
                algorithm: .ed25519
            )
        XCTAssertTrue(rolledBackAuthority.isEmpty)
        XCTAssertNil(rolledBackProtocol)
        XCTAssertEqual(preservedConcurrentState[.mlkem768], concurrentKey)

        let reloaded = try harness.makeKEMStore(
            authorityJournalExists: { false }
        )
        let reloadedConcurrentState = await reloaded
            .authorityBoundBootstrapKEMPublicKeys(
                forAny: fixture.authorizedDeviceIDs,
                pinnedProtocolFingerprints: [concurrentFingerprint]
            )
        XCTAssertEqual(reloadedConcurrentState[.mlkem768], concurrentKey)
    }

    @MainActor
    func testPairingIdentityRollbackConflictOnAffectedFingerprintKeepsJournal() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }
        let receipt = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: fixture.payload,
            authority: fixture.authority,
            validateCurrentSession: {},
            kemStore: harness.kemStore,
            protocolStore: harness.protocolStore,
            journalStore: harness.journalStore,
            shouldSimulateCrash: { _ in false }
        )

        let journalBypass: @Sendable () -> Bool = { false }
        let conflictingWriter = try harness.makeKEMStore(
            authorityJournalExists: journalBypass
        )
        let conflictingKey = Data(repeating: 0x75, count: 1_184)
        _ = try await conflictingWriter.upsertAuthorityBoundBootstrap(
            deviceIds: [fixture.declaredDeviceID],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768.wireId,
                    publicKey: conflictingKey
                )
            ],
            verifiedProtocolFingerprint: fixture.fingerprint
        )

        let currentStores = try harness.reopenedStores()
        do {
            try await AuthorityBoundPairingIdentityPersistence.rollback(
                receipt,
                kemStore: currentStores.kem,
                protocolStore: currentStores.protocolIdentity,
                journalStore: harness.journalStore,
                shouldSimulateCrash: { _ in false }
            )
            XCTFail("Rollback must reject a conflicting write to its affected fingerprint")
        } catch AuthorityBoundPairingIdentityPersistenceError.recoveryFailed {
            XCTAssertTrue(harness.journalStore.journalExists)
        } catch {
            XCTFail("Unexpected rollback conflict error: \(String(reflecting: error))")
        }

        let inspectionStore = try harness.makeKEMStore(
            authorityJournalExists: journalBypass
        )
        let preservedConflict = await inspectionStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: [fixture.declaredDeviceID],
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        XCTAssertEqual(preservedConflict[.mlkem768], conflictingKey)
    }

    @MainActor
    func testCommittedPairingIdentityJournalVerifiesAndClearsWithoutRollback() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        do {
            _ = try await AuthorityBoundPairingIdentityPersistence.commit(
                payload: fixture.payload,
                authority: fixture.authority,
                validateCurrentSession: {},
                kemStore: harness.kemStore,
                protocolStore: harness.protocolStore,
                journalStore: harness.journalStore,
                shouldSimulateCrash: { $0 == .afterCommittedMarker }
            )
            XCTFail("Expected a crash after the committed marker")
        } catch {
            XCTAssertTrue(harness.journalStore.journalExists)
        }

        let reopenedStores = try harness.reopenedStores()
        let quarantinedKEM = await reopenedStores.kem
            .authorityBoundBootstrapKEMPublicKeys(
                forAny: fixture.authorizedDeviceIDs,
                pinnedProtocolFingerprints: [fixture.fingerprint]
            )
        XCTAssertTrue(
            quarantinedKEM.isEmpty,
            "A committed-but-not-cleared journal must still quarantine trust reads"
        )

        try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
            kemStore: reopenedStores.kem,
            protocolStore: reopenedStores.protocolIdentity,
            journalStore: harness.journalStore
        )
        XCTAssertFalse(harness.journalStore.journalExists)
        let committedKEM = await reopenedStores.kem.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        let committedProtocol = await reopenedStores.protocolIdentity
            .trustedProtocolIdentityPublicKey(
            forAny: fixture.authorizedDeviceIDs,
            algorithm: .ed25519
        )
        XCTAssertEqual(committedKEM[.xwing], fixture.kemPublicKey)
        XCTAssertEqual(committedProtocol, fixture.protocolPublicKey)
    }

    @MainActor
    func testPairingIdentityRecoveryPreservesConcurrentDifferentFingerprintMutation() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        do {
            _ = try await AuthorityBoundPairingIdentityPersistence.commit(
                payload: fixture.payload,
                authority: fixture.authority,
                validateCurrentSession: {},
                kemStore: harness.kemStore,
                protocolStore: harness.protocolStore,
                journalStore: harness.journalStore,
                shouldSimulateCrash: { $0 == .afterKEMWrite }
            )
            XCTFail("Expected a crash after the KEM write")
        } catch {
            XCTAssertTrue(harness.journalStore.journalExists)
        }

        let concurrentFingerprint = String(repeating: "b", count: 64)
        let concurrentKey = Data(repeating: 0x62, count: 1_184)
        let journalBypass: @Sendable () -> Bool = { false }
        let concurrentWriter = try harness.makeKEMStore(
            authorityJournalExists: journalBypass
        )
        _ = try await concurrentWriter.upsertAuthorityBoundBootstrap(
            deviceIds: [fixture.declaredDeviceID],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768.wireId,
                    publicKey: concurrentKey
                )
            ],
            verifiedProtocolFingerprint: concurrentFingerprint
        )

        let recoveryKEMStore = try harness.makeKEMStore(
            authorityJournalExists: harness.journalProbe
        )
        let recoveryProtocolStore = try harness.makeProtocolIdentityStore(
            authorityJournalExists: harness.journalProbe
        )
        try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
            kemStore: recoveryKEMStore,
            protocolStore: recoveryProtocolStore,
            journalStore: harness.journalStore
        )
        XCTAssertFalse(harness.journalStore.journalExists)

        let rolledBackAuthority = await recoveryKEMStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: [fixture.declaredDeviceID],
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        let preservedConcurrentState = await recoveryKEMStore
            .authorityBoundBootstrapKEMPublicKeys(
                forAny: [fixture.declaredDeviceID],
                pinnedProtocolFingerprints: [concurrentFingerprint]
            )
        XCTAssertTrue(rolledBackAuthority.isEmpty)
        XCTAssertEqual(preservedConcurrentState[.mlkem768], concurrentKey)
    }

    @MainActor
    func testCommittedPairingIdentityJournalPreservesUnrelatedMutationAndClears() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        do {
            _ = try await AuthorityBoundPairingIdentityPersistence.commit(
                payload: fixture.payload,
                authority: fixture.authority,
                validateCurrentSession: {},
                kemStore: harness.kemStore,
                protocolStore: harness.protocolStore,
                journalStore: harness.journalStore,
                shouldSimulateCrash: { $0 == .afterCommittedMarker }
            )
            XCTFail("Expected a crash after the committed marker")
        } catch {
            XCTAssertTrue(harness.journalStore.journalExists)
        }

        let journalBypass: @Sendable () -> Bool = { false }
        let tamperingStore = try harness.makeKEMStore(
            authorityJournalExists: journalBypass
        )
        let unexpectedFingerprint = String(repeating: "c", count: 64)
        _ = try await tamperingStore.upsertAuthorityBoundBootstrap(
            deviceIds: [fixture.declaredDeviceID],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768.wireId,
                    publicKey: Data(repeating: 0x73, count: 1_184)
                )
            ],
            verifiedProtocolFingerprint: unexpectedFingerprint
        )

        let reopenedStores = try harness.reopenedStores()
        try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
            kemStore: reopenedStores.kem,
            protocolStore: reopenedStores.protocolIdentity,
            journalStore: harness.journalStore
        )
        XCTAssertFalse(harness.journalStore.journalExists)
        let committedAuthority = await reopenedStores.kem.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        let preservedUnexpected = await reopenedStores.kem.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [unexpectedFingerprint]
        )
        XCTAssertEqual(committedAuthority[.xwing], fixture.kemPublicKey)
        XCTAssertEqual(preservedUnexpected[.mlkem768], Data(repeating: 0x73, count: 1_184))
    }

    @MainActor
    func testCorruptPairingIdentityJournalFailsClosedAndRemainsDurable() async throws {
        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }

        try FileManager.default.createDirectory(
            at: harness.journalStore.journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-valid-journal".utf8).write(
            to: harness.journalStore.journalURL,
            options: [.atomic, .completeFileProtection]
        )

        let quarantined = await harness.kemStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: fixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [fixture.fingerprint]
        )
        XCTAssertTrue(quarantined.isEmpty)
        do {
            try await AuthorityBoundPairingIdentityPersistence.recoverIfNeeded(
                kemStore: harness.kemStore,
                protocolStore: harness.protocolStore,
                journalStore: harness.journalStore
            )
            XCTFail("A corrupt journal must not be cleared or treated as an empty transaction")
        } catch {
            XCTAssertTrue(harness.journalStore.journalExists)
        }
    }

    @MainActor
    func testPairingIdentityJournalExclusiveCreateAllowsExactlyOneWriter() async throws {
        enum WriteOutcome: Sendable, Equatable {
            case success
            case transactionMismatch
            case unexpectedFailure
        }

        let fixture = try makePairingIdentityJournalFixture()
        let harness = try makePairingIdentityJournalHarness()
        defer { harness.removePersistentState() }
        let kemMutation = try await harness.kemStore.prepareAuthorityBoundBootstrap(
            deviceIds: fixture.authorizedDeviceIDs,
            kemPublicKeys: fixture.payload.kemPublicKeys,
            verifiedProtocolFingerprint: fixture.fingerprint
        )
        let protocolMutations = try await harness.protocolStore.prepareAuthorityBoundSequence(
            deviceIds: fixture.authorizedDeviceIDs,
            protocolIdentityPublicKeys: [
                AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    publicKey: fixture.protocolPublicKey
                )
            ]
        )
        func journal(transactionID: UUID) -> AuthorityBoundPairingIdentityJournal {
            AuthorityBoundPairingIdentityJournal(
                schemaVersion: AuthorityBoundPairingIdentityJournal.currentSchemaVersion,
                transactionID: transactionID,
                intent: .commit,
                authorizedDeviceIDs: fixture.authorizedDeviceIDs,
                protocolFingerprint: fixture.fingerprint,
                kemMutationReceipt: kemMutation.receipt,
                protocolMutationReceipts: protocolMutations.map(\.receipt),
                phase: .prepared,
                kemApplied: false,
                appliedProtocolMutationCount: 0,
                kemRolledBack: false,
                rolledBackProtocolMutationCount: 0
            )
        }
        let first = journal(transactionID: UUID())
        let second = journal(transactionID: UUID())
        let store = harness.journalStore

        let outcomes = await withTaskGroup(of: WriteOutcome.self) { group in
            for candidate in [first, second] {
                group.addTask {
                    do {
                        try store.write(candidate)
                        return .success
                    } catch AuthorityBoundPairingIdentityJournalStoreError.transactionMismatch {
                        return .transactionMismatch
                    } catch {
                        return .unexpectedFailure
                    }
                }
            }
            var results: [WriteOutcome] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        XCTAssertEqual(outcomes.filter { $0 == .success }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .transactionMismatch }.count, 1)
        XCTAssertFalse(outcomes.contains(.unexpectedFailure))
        XCTAssertNotNil(try harness.journalStore.load())
    }

    func testAppStartupRecoversPairingAcceptanceJournalsBeforeStartingServices() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let iOSRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let appURL = iOSRoot.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift"
        )
        let source = try readRepositorySourceForSourceShapeTests(at: appURL)
        let initialize = try XCTUnwrap(
            source.range(of: "private func initializeServices() async")
        )
        let recovery = try XCTUnwrap(
            source.range(
                of: "try await PairingAcceptancePersistence.recoverIfNeeded(",
                range: initialize.upperBound..<source.endIndex
            )
        )
        let firstRuntimePreparation = try XCTUnwrap(
            source.range(
                of: "QPeriaptIOSRuntime.prepareProductionSession()",
                range: recovery.upperBound..<source.endIndex
            )
        )
        XCTAssertLessThan(recovery.lowerBound, firstRuntimePreparation.lowerBound)
        let recoveryGate = String(source[recovery.lowerBound..<firstRuntimePreparation.lowerBound])
        XCTAssertTrue(
            recoveryGate.contains("reportAdvertisingBlockedByStartupFailure")
        )
        XCTAssertTrue(
            recoveryGate.contains("pairing_identity_authority_recovery_failed")
        )
        XCTAssertTrue(
            recoveryGate.contains("return"),
            "Recovery failure must stop startup before any network-facing service starts"
        )
        XCTAssertFalse(
            recoveryGate.contains("error.localizedDescription"),
            "Startup recovery diagnostics must not log raw nested persistence details"
        )
    }

    func testForegroundRecoveryGatePrecedesEveryNetworkFacingSideEffect() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let iOSRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let appURL = iOSRoot.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift"
        )
        let source = try readRepositorySourceForSourceShapeTests(at: appURL)
        let activeStart = try XCTUnwrap(source.range(of: "case .active:"))
        let backgroundStart = try XCTUnwrap(
            source.range(
                of: "case .background:",
                range: activeStart.upperBound..<source.endIndex
            )
        )
        let activeBranch = String(source[activeStart.lowerBound..<backgroundStart.lowerBound])
        let recoveryOffset = try XCTUnwrap(
            activeBranch.range(of: "PairingAcceptancePersistence.recoverIfNeeded(")
        ).lowerBound
        for marker in [
            "backgroundTeardownTask?.cancel()",
            "retryAuthorizationBlockedBrowsers()",
            "applyDiscoverySettings()",
            "connectionManager.startListening()",
            "FileTransferRuntime.shared.startIfNeeded()",
            "ICloudDevicePresenceService.shared.start()",
            "scheduleCloudKitTrustedDeviceSync(trigger: .foreground)"
        ] {
            let markerOffset = try XCTUnwrap(activeBranch.range(of: marker)).lowerBound
            XCTAssertLessThan(recoveryOffset, markerOffset, marker)
        }
        for failureMarker in [
            "discoveryManager.stopDiscovery()",
            "connectionManager.stopListening()",
            "FileTransferRuntime.shared.stop()",
            "ICloudDevicePresenceService.shared.stop()",
            "reportAdvertisingBlockedByStartupFailure(",
            "return"
        ] {
            XCTAssertTrue(activeBranch.contains(failureMarker), failureMarker)
        }
    }

    func testNetworkContentProcessedGateHasHardTimeout() async {
        let gate = NetworkContentProcessedGate()
        do {
            try await gate.wait(
                timeoutSeconds: 0.02,
                operation: "test-operation",
                transport: "test"
            )
            XCTFail("A missing network completion must time out")
        } catch let error as NetworkContentProcessedError {
            XCTAssertEqual(
                error,
                .timedOut(operation: "test-operation", transport: "test")
            )
        } catch {
            XCTFail("Unexpected timeout error: \(type(of: error))")
        }
    }

    func testNetworkContentProcessedGateCompletionBeforeWaitIsStable() async throws {
        let gate = NetworkContentProcessedGate()
        XCTAssertTrue(gate.finish(.success(())))
        XCTAssertFalse(gate.finish(
            .failure(
                NetworkContentProcessedError.timedOut(
                    operation: "late",
                    transport: "test"
                )
            )
        ))

        try await gate.wait(
            timeoutSeconds: 0.02,
            operation: "completed-before-wait",
            transport: "test"
        )
        try await gate.wait(
            timeoutSeconds: 0.02,
            operation: "repeat",
            transport: "test"
        )
    }

    func testNetworkContentProcessedGateRejectsInvalidConfiguration() async {
        let gate = NetworkContentProcessedGate()
        for (timeout, operation, transport, expected) in [
            (0, "operation", "transport", NetworkContentProcessedError.invalidTimeout),
            (.infinity, "operation", "transport", .invalidTimeout),
            (1, "", "transport", .emptyOperation),
            (1, "operation", "", .emptyTransport),
        ] {
            do {
                try await gate.wait(
                    timeoutSeconds: timeout,
                    operation: operation,
                    transport: transport
                )
                XCTFail("Invalid gate configuration must fail")
            } catch let error as NetworkContentProcessedError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected configuration error: \(type(of: error))")
            }
        }
    }

    func testNetworkContentProcessedGateRejectsSecondWaiterAndPreservesOwner() async throws {
        let gate = NetworkContentProcessedGate()
        let owner = Task {
            try await gate.wait(
                timeoutSeconds: 1,
                operation: "owner",
                transport: "test"
            )
        }

        for _ in 0..<1_000 where !gate.hasPendingWaiterForTesting {
            await Task.yield()
        }
        guard gate.hasPendingWaiterForTesting else {
            owner.cancel()
            XCTFail("Network-submit owner did not arm")
            return
        }

        do {
            try await gate.wait(
                timeoutSeconds: 1,
                operation: "second",
                transport: "test"
            )
            XCTFail("A second waiter must be rejected")
        } catch let error as NetworkContentProcessedError {
            XCTAssertEqual(error, .concurrentWaiter)
        }

        XCTAssertTrue(gate.finish(.success(())))
        try await owner.value
    }

    func testNetworkContentProcessedGatePreSubmissionCancellationBlocksClaim() {
        let gate = NetworkContentProcessedGate()
        XCTAssertEqual(gate.cancelSubmission(), false)
        XCTAssertFalse(gate.claimSubmission())
    }

    func testNetworkContentProcessedGateSuccessWinsLateCancellation() {
        let gate = NetworkContentProcessedGate()
        XCTAssertTrue(gate.claimSubmission())
        XCTAssertTrue(gate.finish(.success(())))
        XCTAssertNil(gate.cancelSubmission())
    }

    func testNetworkContentProcessedGateCancellationWinsLateCallbackOnce() async {
        let gate = NetworkContentProcessedGate()
        let waitTask = Task {
            try await gate.wait(
                timeoutSeconds: 1,
                operation: "test-operation",
                transport: "test-cancel"
            )
        }

        for _ in 0..<1_000 where !gate.hasPendingWaiterForTesting {
            await Task.yield()
        }
        guard gate.hasPendingWaiterForTesting else {
            waitTask.cancel()
            XCTFail("Network-submit waiter did not arm")
            return
        }

        waitTask.cancel()
        let firstResult = await waitTask.result
        gate.finish(.success(()))
        gate.finish(
            .failure(
                NetworkContentProcessedError.timedOut(
                    operation: "late",
                    transport: "late"
                )
            )
        )

        switch firstResult {
        case .success:
            XCTFail("Cancellation must resolve the gate before a late callback")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }

        do {
            try await gate.wait(
                timeoutSeconds: 0.02,
                operation: "repeat",
                transport: "repeat"
            )
            XCTFail("A late callback must not overwrite the first cancellation result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNetworkContentProcessedSubmissionTimeoutCancelsExactlyOnce() async {
        let probe = NetworkContentProcessedSubmissionProbe()
        do {
            try await NetworkContentProcessedSubmission.perform(
                timeoutSeconds: 0.02,
                operation: "timeout-test",
                transport: "test",
                submit: { completion in probe.install(completion) },
                cancel: { probe.recordCancel() }
            )
            XCTFail("A missing content-processed callback must time out")
        } catch let error as NetworkContentProcessedError {
            XCTAssertEqual(
                error,
                .timedOut(operation: "timeout-test", transport: "test")
            )
        } catch {
            XCTFail("Unexpected timeout error: \(type(of: error))")
        }

        XCTAssertEqual(probe.counts.submits, 1)
        XCTAssertEqual(probe.counts.cancels, 1)
        probe.finish(.success(()))
        probe.finish(
            .failure(
                NetworkContentProcessedError.timedOut(
                    operation: "late",
                    transport: "late"
                )
            )
        )
        XCTAssertEqual(probe.counts.cancels, 1)
    }

    func testNetworkContentProcessedSubmissionCancellationCancelsExactlyOnce() async {
        let probe = NetworkContentProcessedSubmissionProbe()
        let submission = Task {
            try await NetworkContentProcessedSubmission.perform(
                timeoutSeconds: 1,
                operation: "cancel-test",
                transport: "test",
                submit: { completion in probe.install(completion) },
                cancel: { probe.recordCancel() }
            )
        }

        for _ in 0..<1_000 where probe.counts.submits == 0 {
            await Task.yield()
        }
        guard probe.counts.submits == 1 else {
            submission.cancel()
            XCTFail("Submission did not start")
            return
        }

        submission.cancel()
        let result = await submission.result
        switch result {
        case .success:
            XCTFail("Cancellation must terminate the pending submission")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.counts.cancels, 1)

        probe.finish(.success(()))
        probe.finish(
            .failure(
                NetworkContentProcessedError.timedOut(
                    operation: "late",
                    transport: "late"
                )
            )
        )
        XCTAssertEqual(probe.counts.cancels, 1)
    }

    func testP2PAcceptanceFinalizesLocalJournalBeforeBoundedSend() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let iOSRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let managerURL = iOSRoot.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let source = try readRepositorySourceForSourceShapeTests(at: managerURL)
        let acceptanceStart = try XCTUnwrap(
            source.range(of: "private func commitAcceptedPairingIdentityExchange(")
        )
        let sendHelperStart = try XCTUnwrap(
            source.range(
                of: "private func sendPairingIdentityExchange(",
                range: acceptanceStart.upperBound..<source.endIndex
            )
        )
        let acceptance = String(
            source[acceptanceStart.lowerBound..<sendHelperStart.lowerBound]
        )
        let markerHelper = try XCTUnwrap(
            acceptance.range(of: "func markReplyVisibilityBeforeNetworkSubmission()")
        )
        let completionHelper = try XCTUnwrap(
            acceptance.range(
                of: "func completeBeforeNetworkSubmission(",
                range: markerHelper.upperBound..<acceptance.endIndex
            )
        )
        let finalizeHelper = try XCTUnwrap(
            acceptance.range(
                of: "func finalizeBeforeNetworkSubmission()",
                range: completionHelper.upperBound..<acceptance.endIndex
            )
        )
        let markerBody = String(
            acceptance[markerHelper.lowerBound..<completionHelper.lowerBound]
        )
        let completionBody = String(
            acceptance[completionHelper.lowerBound..<finalizeHelper.lowerBound]
        )
        let replyBranchStart = try XCTUnwrap(
            acceptance.range(
                of: "// Reply once (rate-limited)",
                range: finalizeHelper.upperBound..<acceptance.endIndex
            )
        )
        let finalizeBody = String(
            acceptance[finalizeHelper.lowerBound..<replyBranchStart.lowerBound]
        )
        XCTAssertTrue(markerBody.contains("markReplyMayBeVisible("))
        XCTAssertTrue(markerBody.contains("requireCurrentConnectionLease("))
        XCTAssertFalse(markerBody.contains("completeAfterReplyMayBeVisible("))
        XCTAssertTrue(completionBody.contains("acceptanceFinalizationAttempted = true"))
        XCTAssertTrue(completionBody.contains("completeAfterReplyMayBeVisible("))
        XCTAssertTrue(completionBody.contains("acceptanceFinalized = true"))
        XCTAssertTrue(finalizeBody.contains("try await markReplyVisibilityBeforeNetworkSubmission()"))
        XCTAssertTrue(finalizeBody.contains("try await completeBeforeNetworkSubmission()"))
        XCTAssertTrue(finalizeBody.contains("requireCurrentConnectionLease("))
        XCTAssertFalse(acceptance.contains("func completeAfterNetworkSubmission("))

        let sendInvocation = try XCTUnwrap(
            acceptance.range(of: "sendOutcome = try await sendPairingIdentityExchange(")
        )
        let finalizationCallback = try XCTUnwrap(
            acceptance.range(
                of: "try await finalizeBeforeNetworkSubmission()",
                range: sendInvocation.upperBound..<acceptance.endIndex
            )
        )
        let sendCatch = String(acceptance[finalizationCallback.upperBound..<acceptance.endIndex])
        XCTAssertTrue(sendCatch.contains("guard visibilityMarkerDurable else"))
        XCTAssertTrue(sendCatch.contains("abortBeforeVisibility(after:"))
        XCTAssertTrue(sendCatch.contains("completeBeforeNetworkSubmission(following:"))
        XCTAssertTrue(sendCatch.contains("if acceptanceFinalizationAttempted"))
        XCTAssertTrue(sendCatch.contains("guard acceptanceFinalized else"))

        let waitHelperStart = try XCTUnwrap(
            source.range(
                of: "public func waitForPairingIdentityExchangeActivity(",
                range: sendHelperStart.upperBound..<source.endIndex
            )
        )
        let sendHelper = String(
            source[sendHelperStart.lowerBound..<waitHelperStart.lowerBound]
        )
        let encrypt = try XCTUnwrap(sendHelper.range(of: "let ciphertext ="))
        let beforeSubmit = try XCTUnwrap(
            sendHelper.range(
                of: "try await beforeNetworkSubmit()",
                range: encrypt.upperBound..<sendHelper.endIndex
            )
        )
        let boundedSend = try XCTUnwrap(
            sendHelper.range(
                of: "try await sendPairingIdentityData(",
                range: beforeSubmit.upperBound..<sendHelper.endIndex
            )
        )
        XCTAssertLessThan(encrypt.lowerBound, beforeSubmit.lowerBound)
        XCTAssertLessThan(beforeSubmit.lowerBound, boundedSend.lowerBound)
    }

    func testTimeoutAfterReplyVisibilityRetainsAfterStateDisposition() {
        XCTAssertEqual(
            PairingAcceptancePersistence.networkFailureDisposition(
                for: .replyMayBeVisible
            ),
            .retainAfterVisibility
        )
        XCTAssertEqual(
            PairingAcceptancePersistence.networkFailureDisposition(for: .committed),
            .retainAfterVisibility
        )
        XCTAssertEqual(
            PairingAcceptancePersistence.networkFailureDisposition(for: .applying),
            .rollbackBeforeVisibility
        )
        XCTAssertEqual(
            PairingAcceptancePersistence.networkFailureDisposition(
                visibilityMarkerDurable: true,
                finalizationAttempted: true
            ),
            .leaveAfterJournalForRecovery,
            "A finalize failure after the durable marker must never attempt BEFORE rollback"
        )
    }

    @MainActor
    func testOuterBeginCrashMatrixRecoversActualParticipantWritesToBefore() async throws {
        struct Scenario {
            let point: PairingAcceptancePersistenceCrashPoint
            let phase: PairingAcceptanceJournal.Phase
            let authorityApplied: Bool
            let trustedDeviceApplied: Bool
            let pairingPolicyApplied: Bool
            let authorityAfter: Bool
            let trustedDeviceAfter: Bool
            let pairingPolicyAfter: Bool
        }
        let scenarios = [
            Scenario(
                point: .afterPlanningJournalWrite,
                phase: .planning,
                authorityApplied: false,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false,
                authorityAfter: false,
                trustedDeviceAfter: false,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .afterPreparedJournalWrite,
                phase: .prepared,
                authorityApplied: false,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false,
                authorityAfter: false,
                trustedDeviceAfter: false,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .afterApplyingJournalWrite,
                phase: .applying,
                authorityApplied: false,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false,
                authorityAfter: false,
                trustedDeviceAfter: false,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .beforeAuthorityWrite,
                phase: .applying,
                authorityApplied: false,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false,
                authorityAfter: false,
                trustedDeviceAfter: false,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .afterAuthorityWrite,
                phase: .applying,
                authorityApplied: false,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false,
                authorityAfter: true,
                trustedDeviceAfter: false,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .beforeTrustedDeviceWrite,
                phase: .applying,
                authorityApplied: true,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false,
                authorityAfter: true,
                trustedDeviceAfter: false,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .afterTrustedDeviceWrite,
                phase: .applying,
                authorityApplied: true,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false,
                authorityAfter: true,
                trustedDeviceAfter: true,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .beforePairingPolicyWrite,
                phase: .applying,
                authorityApplied: true,
                trustedDeviceApplied: true,
                pairingPolicyApplied: false,
                authorityAfter: true,
                trustedDeviceAfter: true,
                pairingPolicyAfter: false
            ),
            Scenario(
                point: .afterPairingPolicyWrite,
                phase: .applying,
                authorityApplied: true,
                trustedDeviceApplied: true,
                pairingPolicyApplied: false,
                authorityAfter: true,
                trustedDeviceAfter: true,
                pairingPolicyAfter: true
            ),
            Scenario(
                point: .afterApplyingProgressWrite,
                phase: .applying,
                authorityApplied: true,
                trustedDeviceApplied: true,
                pairingPolicyApplied: true,
                authorityAfter: true,
                trustedDeviceAfter: true,
                pairingPolicyAfter: true
            )
        ]

        for scenario in scenarios {
            let harness = try await makeOuterRecoveryHarness()
            defer { harness.inner.removePersistentState() }

            do {
                _ = try await harness.begin(crashAt: scenario.point)
                XCTFail("Expected simulated outer crash at \(scenario.point)")
            } catch {
                XCTAssertTrue(harness.outerJournalStore.journalExists)
            }

            let journal = try XCTUnwrap(harness.outerJournalStore.load())
            XCTAssertEqual(journal.phase, scenario.phase)
            XCTAssertEqual(journal.authorityApplied, scenario.authorityApplied)
            XCTAssertEqual(journal.trustedDeviceApplied, scenario.trustedDeviceApplied)
            XCTAssertEqual(journal.pairingPolicyApplied, scenario.pairingPolicyApplied)
            try await harness.assertActiveParticipantState(
                journal: journal,
                authorityAfter: scenario.authorityAfter,
                trustedDeviceAfter: scenario.trustedDeviceAfter,
                pairingPolicyAfter: scenario.pairingPolicyAfter
            )

            try await harness.recover()

            XCTAssertFalse(harness.outerJournalStore.journalExists)
            try await harness.assertBefore(journal.plan)
        }
    }

    @MainActor
    func testOuterReplyVisibleAndCommittedCrashRecoveryRetainsAfterState() async throws {
        let replyVisibleHarness = try await makeOuterRecoveryHarness()
        defer { replyVisibleHarness.inner.removePersistentState() }
        let replyVisibleHandle = try await replyVisibleHarness.begin()
        do {
            try await PairingAcceptancePersistence.markReplyMayBeVisible(
                replyVisibleHandle,
                validateCurrentSession: {},
                shouldSimulateCrash: { $0 == .afterReplyMayBeVisibleMarker }
            )
            XCTFail("Expected a crash after the durable reply-visible marker")
        } catch {
            XCTAssertEqual(
                try replyVisibleHarness.outerJournalStore.load()?.phase,
                .replyMayBeVisible
            )
        }
        let replyVisiblePlan = try XCTUnwrap(
            replyVisibleHarness.outerJournalStore.load()?.plan
        )
        try await replyVisibleHarness.recover()
        XCTAssertFalse(replyVisibleHarness.outerJournalStore.journalExists)
        try await replyVisibleHarness.assertAfter(replyVisiblePlan)

        let committedHarness = try await makeOuterRecoveryHarness()
        defer { committedHarness.inner.removePersistentState() }
        let committedHandle = try await committedHarness.begin()
        try await PairingAcceptancePersistence.markReplyMayBeVisible(
            committedHandle,
            validateCurrentSession: {}
        )
        do {
            try await PairingAcceptancePersistence.completeAfterReplyMayBeVisible(
                committedHandle,
                policyParticipant: committedHarness.policy,
                shouldSimulateCrash: { $0 == .afterCommittedMarker }
            )
            XCTFail("Expected a crash after the durable committed marker")
        } catch {
            XCTAssertEqual(
                try committedHarness.outerJournalStore.load()?.phase,
                .committed
            )
        }
        let committedPlan = try XCTUnwrap(
            committedHarness.outerJournalStore.load()?.plan
        )
        try await committedHarness.recover()
        XCTAssertFalse(committedHarness.outerJournalStore.journalExists)
        try await committedHarness.assertAfter(committedPlan)
    }

    @MainActor
    func testOuterCompleteRemovalFailureIsRecoveredOnNextStartup() async throws {
        let removalFailure = OneShotOuterRemovalFailure()
        let harness = try await makeOuterRecoveryHarness(
            injectedRemovalFailure: { removalFailure.takeReason() }
        )
        defer { harness.inner.removePersistentState() }
        let handle = try await harness.begin()
        try await PairingAcceptancePersistence.markReplyMayBeVisible(
            handle,
            validateCurrentSession: {}
        )

        do {
            try await PairingAcceptancePersistence.completeAfterReplyMayBeVisible(
                handle,
                policyParticipant: harness.policy
            )
            XCTFail("Expected the injected committed-journal removal failure")
        } catch let error as PairingAcceptanceJournalStoreError {
            guard case .removalFailed = error else {
                XCTFail("Unexpected journal error: \(error)")
                return
            }
        }

        let committedJournal = try XCTUnwrap(harness.outerJournalStore.load())
        XCTAssertEqual(committedJournal.phase, .committed)
        XCTAssertTrue(harness.outerJournalStore.journalExists)
        try await harness.assertActiveParticipantState(
            journal: committedJournal,
            authorityAfter: true,
            trustedDeviceAfter: true,
            pairingPolicyAfter: true
        )

        try await harness.recover()

        XCTAssertEqual(removalFailure.attemptCount, 2)
        XCTAssertFalse(harness.outerJournalStore.journalExists)
        try await harness.assertAfter(committedJournal.plan)
    }

    @MainActor
    func testOuterPlanningRecoveryClearsJournalWithoutParticipantMutation() async throws {
        let harness = try await makeOuterRecoveryHarness()
        defer { harness.inner.removePersistentState() }
        let journal = harness.makeJournal(phase: .planning, plan: nil)
        try harness.outerJournalStore.write(journal)

        try await harness.recover()

        XCTAssertFalse(harness.outerJournalStore.journalExists)
        try await harness.assertBefore()
    }

    @MainActor
    func testOuterPreparedAndApplyingRecoveryConvergeEveryParticipantToBefore() async throws {
        struct Scenario {
            let phase: PairingAcceptanceJournal.Phase
            let authorityAfter: Bool
            let trustedAfter: Bool
            let policyAfter: Bool
        }
        let scenarios = [
            Scenario(
                phase: .prepared,
                authorityAfter: false,
                trustedAfter: false,
                policyAfter: false
            ),
            Scenario(
                phase: .applying,
                authorityAfter: true,
                trustedAfter: false,
                policyAfter: false
            ),
            Scenario(
                phase: .applying,
                authorityAfter: true,
                trustedAfter: true,
                policyAfter: false
            ),
            Scenario(
                phase: .applying,
                authorityAfter: true,
                trustedAfter: true,
                policyAfter: true
            ),
            Scenario(
                phase: .rollingBack,
                authorityAfter: true,
                trustedAfter: false,
                policyAfter: true
            )
        ]

        for scenario in scenarios {
            let harness = try await makeOuterRecoveryHarness()
            defer { harness.inner.removePersistentState() }
            try await harness.installParticipantState(
                authorityAfter: scenario.authorityAfter,
                trustedAfter: scenario.trustedAfter,
                policyAfter: scenario.policyAfter
            )
            let journal = harness.makeJournal(
                phase: scenario.phase,
                authorityApplied: scenario.authorityAfter,
                trustedDeviceApplied: scenario.trustedAfter,
                pairingPolicyApplied: scenario.policyAfter
            )
            try harness.outerJournalStore.write(journal)

            try await harness.recover()

            XCTAssertFalse(harness.outerJournalStore.journalExists)
            try await harness.assertBefore()
        }
    }

    @MainActor
    func testOuterReplyVisibleAndCommittedRecoveryConvergeMixedStateToAfter() async throws {
        struct Scenario {
            let phase: PairingAcceptanceJournal.Phase
            let authorityAfter: Bool
            let trustedAfter: Bool
            let policyAfter: Bool
        }
        let scenarios = [
            Scenario(
                phase: .replyMayBeVisible,
                authorityAfter: true,
                trustedAfter: false,
                policyAfter: true
            ),
            Scenario(
                phase: .committed,
                authorityAfter: false,
                trustedAfter: true,
                policyAfter: false
            )
        ]

        for scenario in scenarios {
            let harness = try await makeOuterRecoveryHarness()
            defer { harness.inner.removePersistentState() }
            try await harness.installParticipantState(
                authorityAfter: scenario.authorityAfter,
                trustedAfter: scenario.trustedAfter,
                policyAfter: scenario.policyAfter
            )
            let journal = harness.makeJournal(
                phase: scenario.phase,
                authorityApplied: true,
                trustedDeviceApplied: true,
                pairingPolicyApplied: true
            )
            try harness.outerJournalStore.write(journal)

            try await harness.recover()

            XCTAssertFalse(harness.outerJournalStore.journalExists)
            try await harness.assertAfter()
        }
    }

    @MainActor
    func testOuterBeforeAndAfterCASMismatchRemainDurablyQuarantined() async throws {
        let phases: [PairingAcceptanceJournal.Phase] = [
            .applying,
            .replyMayBeVisible
        ]

        for phase in phases {
            let harness = try await makeOuterRecoveryHarness()
            defer { harness.inner.removePersistentState() }
            let thirdImage = ["third-authority": "reject"]
            harness.policy.values = thirdImage
            let journal = harness.makeJournal(
                phase: phase,
                authorityApplied: phase == .replyMayBeVisible,
                trustedDeviceApplied: phase == .replyMayBeVisible,
                pairingPolicyApplied: phase == .replyMayBeVisible
            )
            try harness.outerJournalStore.write(journal)

            do {
                try await harness.recover()
                XCTFail("Third policy image must remain quarantined for \(phase)")
            } catch {
                XCTAssertTrue(error is PairingAcceptancePersistenceError)
            }
            XCTAssertTrue(harness.outerJournalStore.journalExists)
            XCTAssertEqual(harness.policy.values, thirdImage)
        }
    }

    @MainActor
    func testOuterAuthorityThirdImageRemainsDurablyQuarantined() async throws {
        let harness = try await makeOuterRecoveryHarness()
        defer { harness.inner.removePersistentState() }
        try await harness.kemStore.testOnlyReplaceWithAuthorityBoundPeers(
            deviceIds: harness.authorityFixture.authorizedDeviceIDs,
            kemPublicKey: KEMPublicKeyInfo(
                suiteWireId: CryptoSuite.xwing.wireId,
                publicKey: Data(repeating: 0xE3, count: 1_216)
            ),
            protocolFingerprint: harness.authorityFixture.fingerprint
        )
        try harness.outerJournalStore.write(
            harness.makeJournal(
                phase: .replyMayBeVisible,
                authorityApplied: true,
                trustedDeviceApplied: true,
                pairingPolicyApplied: true
            )
        )

        do {
            try await harness.recover()
            XCTFail("A third authority image must remain quarantined")
        } catch let error as PairingAcceptancePersistenceError {
            guard case .invalidJournal = error else {
                return XCTFail("Unexpected authority quarantine error: \(error)")
            }
        }
        XCTAssertTrue(harness.outerJournalStore.journalExists)
    }

    @MainActor
    func testOuterTrustedDeviceThirdSnapshotRemainsDurablyQuarantined() async throws {
        let harness = try await makeOuterRecoveryHarness()
        defer { harness.inner.removePersistentState() }
        let thirdDeviceID = "id:\(UUID().uuidString.lowercased())"
        let thirdMutation = try harness.trustedDeviceStore.prepareTrustResolvedPeer(
            DiscoveredDevice(
                id: thirdDeviceID,
                name: "Concurrent Trust Writer",
                modelName: "iPad",
                platform: .unknown,
                osVersion: "Test"
            ),
            declaredDeviceId: thirdDeviceID,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolPublicKeyFingerprint: harness.authorityFixture.fingerprint,
            outerPermit: nil
        )
        _ = try harness.trustedDeviceStore.applyPreparedTrustMutation(
            thirdMutation,
            outerPermit: nil
        )
        try harness.outerJournalStore.write(
            harness.makeJournal(
                phase: .replyMayBeVisible,
                authorityApplied: true,
                trustedDeviceApplied: true,
                pairingPolicyApplied: true
            )
        )

        do {
            try await harness.recover()
            XCTFail("A third trusted-device snapshot must remain quarantined")
        } catch let error as PairingAcceptancePersistenceError {
            guard case .invalidJournal = error else {
                return XCTFail("Unexpected trusted-device quarantine error: \(error)")
            }
        }
        XCTAssertTrue(harness.outerJournalStore.journalExists)
    }

    @MainActor
    func testOuterUnsupportedSchemaRemainsDurablyQuarantined() async throws {
        let harness = try await makeOuterRecoveryHarness()
        defer { harness.inner.removePersistentState() }
        try harness.outerJournalStore.write(
            harness.makeJournal(
                schemaVersion: PairingAcceptanceJournal.currentSchemaVersion + 1,
                phase: .prepared
            )
        )

        do {
            try await harness.recover()
            XCTFail("An unsupported outer schema must remain quarantined")
        } catch PairingAcceptanceJournalStoreError.unsupportedSchemaVersion(let version) {
            XCTAssertEqual(version, PairingAcceptanceJournal.currentSchemaVersion + 1)
        }
        XCTAssertTrue(harness.outerJournalStore.journalExists)
    }

    @MainActor
    func testOuterCorruptJSONRemainsDurablyQuarantined() async throws {
        let harness = try await makeOuterRecoveryHarness()
        defer { harness.inner.removePersistentState() }
        let corruptPayload = Data("{\"schemaVersion\":".utf8)
        try AuthorityBoundPairingIdentityJournalStore(
            journalURL: harness.outerJournalStore.journalURL
        ).installProtectedData(corruptPayload, replacingExistingJournal: false)

        do {
            try await harness.recover()
            XCTFail("Corrupt outer JSON must remain quarantined")
        } catch PairingAcceptanceJournalStoreError.decodingFailed {
            // Expected: recovery must not replace or remove unparseable evidence.
        }
        XCTAssertEqual(
            try Data(contentsOf: harness.outerJournalStore.journalURL),
            corruptPayload
        )
    }

    @MainActor
    func testOuterImpossibleProgressRemainsDurablyQuarantined() async throws {
        let harness = try await makeOuterRecoveryHarness()
        defer { harness.inner.removePersistentState() }
        try harness.outerJournalStore.write(
            harness.makeJournal(
                phase: .prepared,
                authorityApplied: true,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false
            )
        )

        do {
            try await harness.recover()
            XCTFail("Impossible outer progress must remain quarantined")
        } catch let error as PairingAcceptancePersistenceError {
            guard case .invalidJournal = error else {
                return XCTFail("Unexpected progress quarantine error: \(error)")
            }
        }
        XCTAssertTrue(harness.outerJournalStore.journalExists)
    }

    @MainActor
    func testOuterRemovalFailureLeavesJournalReleasesBarrierAndCanRetry() async throws {
        let removalFailure = OneShotRemovalFailure(reason: "simulated remove failure")
        let harness = try await makeOuterRecoveryHarness(
            injectedRemovalFailure: { removalFailure.take() }
        )
        defer { harness.inner.removePersistentState() }
        try harness.outerJournalStore.write(
            harness.makeJournal(phase: .planning, plan: nil)
        )

        do {
            try await harness.recover()
            XCTFail("The injected removal failure must be observable")
        } catch let error as PairingAcceptancePersistenceError {
            guard case .invalidJournal = error else {
                return XCTFail("Unexpected removal error: \(error)")
            }
        }
        XCTAssertTrue(harness.outerJournalStore.journalExists)

        try await harness.recover()

        XCTAssertFalse(harness.outerJournalStore.journalExists)
        try await harness.assertBefore()
    }

    @MainActor
    func testOuterJournalQuarantinesRawParticipantAuthorityAccess() async throws {
        let harness = try await makeOuterRecoveryHarness()
        defer { harness.inner.removePersistentState() }
        try await harness.installParticipantState(
            authorityAfter: true,
            trustedAfter: true,
            policyAfter: true
        )
        let journal = harness.makeJournal(
            phase: .applying,
            authorityApplied: true,
            trustedDeviceApplied: true,
            pairingPolicyApplied: true
        )
        try harness.outerJournalStore.write(journal)

        let kemKeys = await harness.kemStore.authorityBoundBootstrapKEMPublicKeys(
            forAny: harness.authorityFixture.authorizedDeviceIDs,
            pinnedProtocolFingerprints: [harness.authorityFixture.fingerprint]
        )
        XCTAssertTrue(kemKeys.isEmpty)
        let protocolKey = await harness.protocolStore.trustedProtocolIdentityPublicKey(
            forAny: harness.authorityFixture.authorizedDeviceIDs,
            algorithm: .ed25519
        )
        XCTAssertNil(protocolKey)

        do {
            _ = try await harness.kemStore.prepareAuthorityBoundBootstrap(
                deviceIds: harness.authorityFixture.authorizedDeviceIDs,
                kemPublicKeys: harness.authorityFixture.payload.kemPublicKeys,
                verifiedProtocolFingerprint: harness.authorityFixture.fingerprint
            )
            XCTFail("Raw KEM authority mutation must fail closed while outer WAL exists")
        } catch KEMTrustStore.PersistenceError.authorityTransactionQuarantined {
            // Expected.
        }
        let protocolIdentityPublicKeys = try XCTUnwrap(
            harness.authorityFixture.payload.protocolIdentityPublicKeys
        )
        do {
            _ = try await harness.protocolStore.prepareAuthorityBoundSequence(
                deviceIds: harness.authorityFixture.authorizedDeviceIDs,
                protocolIdentityPublicKeys: protocolIdentityPublicKeys
            )
            XCTFail("Raw protocol authority mutation must fail closed while outer WAL exists")
        } catch ProtocolIdentityTrustStore.AuthorityBoundUpdateError
            .authorityTransactionQuarantined {
            // Expected.
        }
        XCTAssertThrowsError(try harness.trustedDeviceStore.activeAuthoritySnapshot()) { error in
            XCTAssertEqual(
                error as? TrustedDeviceStore.PersistenceError,
                .authorityTransactionQuarantined
            )
        }
        let unrelatedPermit = harness.outerJournalStore.makePermit(
            transactionID: UUID(),
            ownerNonce: UUID()
        )
        XCTAssertThrowsError(
            try harness.policy.pairingPolicySnapshot(outerPermit: unrelatedPermit)
        ) { error in
            XCTAssertTrue(error is PairingAcceptanceTestPolicyParticipant.TestError)
        }
    }

    func testOuterJournalAllowsExactlyOneConcurrentWriter() async throws {
        enum WriteOutcome: Sendable, Equatable {
            case success
            case transactionMismatch
            case unexpectedFailure
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuterConcurrentWriter.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PairingAcceptanceJournalStore(
            journalURL: root.appendingPathComponent("outer.journal")
        )
        func candidate(_ key: String) -> PairingAcceptanceJournal {
            PairingAcceptanceJournal(
                schemaVersion: PairingAcceptanceJournal.currentSchemaVersion,
                transactionID: UUID(),
                ownerNonce: UUID(),
                canonicalAcceptanceKey: key,
                acceptedMaterialDigest: Data(repeating: 0x5A, count: SHA256.byteCount),
                phase: .planning,
                plan: nil,
                authorityApplied: false,
                trustedDeviceApplied: false,
                pairingPolicyApplied: false
            )
        }
        let candidates = [candidate("first"), candidate("second")]

        let outcomes = await withTaskGroup(of: WriteOutcome.self) { group in
            for journal in candidates {
                group.addTask {
                    do {
                        try store.write(journal)
                        return .success
                    } catch PairingAcceptanceJournalStoreError.transactionMismatch {
                        return .transactionMismatch
                    } catch {
                        return .unexpectedFailure
                    }
                }
            }
            var values: [WriteOutcome] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 == .success }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .transactionMismatch }.count, 1)
        XCTAssertFalse(outcomes.contains(.unexpectedFailure))
        XCTAssertNotNil(try store.load())
    }

    @MainActor
    func testOuterJournalRejectsStalePermitAfterOwnerABA() throws {
        let harnessRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OuterPermitABA.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: harnessRoot) }
        let store = PairingAcceptanceJournalStore(
            journalURL: harnessRoot.appendingPathComponent("outer.journal")
        )
        let first = PairingAcceptanceJournal(
            schemaVersion: PairingAcceptanceJournal.currentSchemaVersion,
            transactionID: UUID(),
            ownerNonce: UUID(),
            canonicalAcceptanceKey: "first",
            acceptedMaterialDigest: Data(repeating: 0x11, count: SHA256.byteCount),
            phase: .planning,
            plan: nil,
            authorityApplied: false,
            trustedDeviceApplied: false,
            pairingPolicyApplied: false
        )
        try store.write(first)
        let stalePermit = store.makePermit(
            transactionID: first.transactionID,
            ownerNonce: first.ownerNonce
        )
        try store.remove(permit: stalePermit)

        let second = PairingAcceptanceJournal(
            schemaVersion: PairingAcceptanceJournal.currentSchemaVersion,
            transactionID: UUID(),
            ownerNonce: UUID(),
            canonicalAcceptanceKey: "second",
            acceptedMaterialDigest: Data(repeating: 0x22, count: SHA256.byteCount),
            phase: .planning,
            plan: nil,
            authorityApplied: false,
            trustedDeviceApplied: false,
            pairingPolicyApplied: false
        )
        try store.write(second)

        XCTAssertFalse(store.ownsActiveJournal(stalePermit))
        XCTAssertThrowsError(try store.remove(permit: stalePermit))
        XCTAssertEqual(try store.load()?.transactionID, second.transactionID)
    }

    private final class OneShotOuterRemovalFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        func takeReason() -> String? {
            lock.lock()
            defer { lock.unlock() }
            attempts += 1
            return attempts == 1 ? "injected committed-journal removal failure" : nil
        }
    }

    private final class TrustedDevicePersistenceBox {
        var devices: [TrustedDeviceStore.TrustedDevice]?
    }

    private final class OneShotRemovalFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: String?

        init(reason: String) {
            self.reason = reason
        }

        func take() -> String? {
            lock.lock()
            defer { lock.unlock() }
            let current = reason
            reason = nil
            return current
        }
    }

    @MainActor
    private struct OuterRecoveryHarness {
        let authorityFixture: PairingIdentityJournalFixture
        let authorityReceipt: AuthorityBoundPairingIdentityPersistenceReceipt
        let inner: PairingIdentityJournalHarness
        let outerJournalStore: PairingAcceptanceJournalStore
        let kemStore: KEMTrustStore
        let protocolStore: ProtocolIdentityTrustStore
        let trustedDeviceStore: TrustedDeviceStore
        let preparedTrustMutation: TrustedDeviceStore.PreparedTrustMutation
        let policy: PairingAcceptanceTestPolicyParticipant
        let preparedPolicyMutation: PreparedPairingPolicyMutation
        let plan: PairingAcceptanceJournal.Plan

        var persistenceStores: PairingAcceptancePersistenceStores {
            PairingAcceptancePersistenceStores(
                trustedDeviceStore: trustedDeviceStore,
                kemStore: kemStore,
                protocolStore: protocolStore,
                authorityJournalStore: inner.journalStore,
                journalStore: outerJournalStore
            )
        }

        func makeJournal(
            schemaVersion: Int = PairingAcceptanceJournal.currentSchemaVersion,
            phase: PairingAcceptanceJournal.Phase,
            plan explicitPlan: PairingAcceptanceJournal.Plan? = nil,
            authorityApplied: Bool = false,
            trustedDeviceApplied: Bool = false,
            pairingPolicyApplied: Bool = false
        ) -> PairingAcceptanceJournal {
            PairingAcceptanceJournal(
                schemaVersion: schemaVersion,
                transactionID: UUID(),
                ownerNonce: UUID(),
                canonicalAcceptanceKey: authorityFixture.declaredDeviceID,
                acceptedMaterialDigest: Data(repeating: 0xA7, count: SHA256.byteCount),
                phase: phase,
                plan: phase == .planning ? explicitPlan : (explicitPlan ?? plan),
                authorityApplied: authorityApplied,
                trustedDeviceApplied: trustedDeviceApplied,
                pairingPolicyApplied: pairingPolicyApplied
            )
        }

        func installParticipantState(
            authorityAfter: Bool,
            trustedAfter: Bool,
            policyAfter: Bool
        ) async throws {
            if authorityAfter {
                try await AuthorityBoundPairingIdentityPersistence.rollForward(
                    authorityReceipt,
                    kemStore: kemStore,
                    protocolStore: protocolStore
                )
            }
            if trustedAfter {
                _ = try trustedDeviceStore.applyPreparedTrustMutation(
                    preparedTrustMutation,
                    outerPermit: nil
                )
            }
            if policyAfter {
                policy.values = preparedPolicyMutation.after.valuesByAuthorityID
            }
        }

        func begin(
            crashAt crashPoint: PairingAcceptancePersistenceCrashPoint? = nil
        ) async throws -> PairingAcceptancePersistenceHandle {
            try await PairingAcceptancePersistence.begin(
                payload: authorityFixture.payload,
                authority: authorityFixture.authority,
                canonicalAcceptanceKey: authorityFixture.declaredDeviceID,
                acceptedMaterialDigest: Data(repeating: 0xA7, count: SHA256.byteCount),
                trustedDevicePreparation: { _ in preparedTrustMutation },
                pairingPolicyPersistedValue: "alwaysAllow",
                policyParticipant: policy,
                injectedStores: persistenceStores,
                shouldSimulateCrash: { $0 == crashPoint },
                validateCurrentSession: {}
            )
        }

        func recover() async throws {
            try await PairingAcceptancePersistence.recoverIfNeeded(
                policyParticipant: policy,
                trustedDeviceStore: trustedDeviceStore,
                kemStore: kemStore,
                protocolStore: protocolStore,
                authorityJournalStore: inner.journalStore,
                journalStore: outerJournalStore
            )
        }

        func assertActiveParticipantState(
            journal: PairingAcceptanceJournal,
            authorityAfter: Bool,
            trustedDeviceAfter: Bool,
            pairingPolicyAfter: Bool
        ) async throws {
            let expectedPlan = journal.plan ?? plan
            let authorityMatches: Bool
            if authorityAfter {
                authorityMatches = try await AuthorityBoundPairingIdentityPersistence
                    .receiptMatchesCommitted(
                        expectedPlan.authority,
                        kemStore: kemStore,
                        protocolStore: protocolStore
                    )
            } else {
                authorityMatches = try await AuthorityBoundPairingIdentityPersistence
                    .receiptMatchesRolledBack(
                        expectedPlan.authority,
                        kemStore: kemStore,
                        protocolStore: protocolStore
                    )
            }
            XCTAssertTrue(authorityMatches)

            let permit = outerJournalStore.makePermit(
                transactionID: journal.transactionID,
                ownerNonce: journal.ownerNonce
            )
            let trustedSnapshot = trustedDeviceAfter
                ? expectedPlan.trustedDeviceAfter
                : expectedPlan.trustedDeviceBefore
            XCTAssertTrue(
                try trustedDeviceStore.pairingAcceptanceSnapshotMatches(
                    trustedSnapshot,
                    outerPermit: permit
                )
            )
            let policySnapshot = pairingPolicyAfter
                ? expectedPlan.pairingPolicyAfter
                : expectedPlan.pairingPolicyBefore
            XCTAssertTrue(
                try policy.pairingPolicySnapshotMatches(
                    policySnapshot,
                    outerPermit: permit
                )
            )
        }

        func assertBefore(
            _ expectedPlan: PairingAcceptanceJournal.Plan? = nil
        ) async throws {
            let expectedPlan = expectedPlan ?? plan
            let authorityMatches = try await AuthorityBoundPairingIdentityPersistence
                .receiptMatchesRolledBack(
                    expectedPlan.authority,
                    kemStore: kemStore,
                    protocolStore: protocolStore
                )
            XCTAssertTrue(authorityMatches)
            let probePermit = outerJournalStore.makePermit(
                transactionID: UUID(),
                ownerNonce: UUID()
            )
            XCTAssertTrue(
                try trustedDeviceStore.pairingAcceptanceSnapshotMatches(
                    expectedPlan.trustedDeviceBefore,
                    outerPermit: probePermit
                )
            )
            XCTAssertEqual(
                policy.values,
                expectedPlan.pairingPolicyBefore.valuesByAuthorityID
            )
        }

        func assertAfter(
            _ expectedPlan: PairingAcceptanceJournal.Plan? = nil
        ) async throws {
            let expectedPlan = expectedPlan ?? plan
            let authorityMatches = try await AuthorityBoundPairingIdentityPersistence
                .receiptMatchesCommitted(
                    expectedPlan.authority,
                    kemStore: kemStore,
                    protocolStore: protocolStore
                )
            XCTAssertTrue(authorityMatches)
            let probePermit = outerJournalStore.makePermit(
                transactionID: UUID(),
                ownerNonce: UUID()
            )
            XCTAssertTrue(
                try trustedDeviceStore.pairingAcceptanceSnapshotMatches(
                    expectedPlan.trustedDeviceAfter,
                    outerPermit: probePermit
                )
            )
            XCTAssertEqual(
                policy.values,
                expectedPlan.pairingPolicyAfter.valuesByAuthorityID
            )
        }
    }

    @MainActor
    private func makeOuterRecoveryHarness(
        injectedRemovalFailure: @escaping @Sendable () -> String? = { nil }
    ) async throws -> OuterRecoveryHarness {
        let authorityFixture = try makePairingIdentityJournalFixture()
        let inner = try makePairingIdentityJournalHarness()
        let outerJournalStore = PairingAcceptanceJournalStore(
            journalURL: inner.journalStore.journalURL
                .deletingLastPathComponent()
                .appendingPathComponent("pairing-acceptance.journal"),
            injectedRemovalFailure: injectedRemovalFailure
        )
        let persistence = TrustedDevicePersistenceBox()
        let trustedDeviceStore = TrustedDeviceStore(
            testingLoad: { persistence.devices },
            testingSave: { persistence.devices = $0 },
            pairingAcceptanceJournalExists: { outerJournalStore.journalExists }
        )
        let policy = PairingAcceptanceTestPolicyParticipant(
            journalStore: outerJournalStore
        )

        let authorityReceipt = try await AuthorityBoundPairingIdentityPersistence.commit(
            payload: authorityFixture.payload,
            authority: authorityFixture.authority,
            validateCurrentSession: {},
            kemStore: inner.kemStore,
            protocolStore: inner.protocolStore,
            journalStore: inner.journalStore,
            shouldSimulateCrash: { _ in false }
        )
        try await AuthorityBoundPairingIdentityPersistence.rollback(
            authorityReceipt,
            kemStore: inner.kemStore,
            protocolStore: inner.protocolStore,
            journalStore: inner.journalStore,
            shouldSimulateCrash: { _ in false }
        )
        let outerAwareStores = try inner.reopenedStores(
            pairingAcceptanceJournalExists: { outerJournalStore.journalExists }
        )

        let probePermit = outerJournalStore.makePermit(
            transactionID: UUID(),
            ownerNonce: UUID()
        )
        let trustedDevice = DiscoveredDevice(
            id: authorityFixture.declaredDeviceID,
            name: "Outer Recovery Peer",
            modelName: "Mac",
            platform: .unknown,
            osVersion: "Test"
        )
        let preparedTrustMutation = try trustedDeviceStore.prepareTrustResolvedPeer(
            trustedDevice,
            declaredDeviceId: authorityFixture.declaredDeviceID,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolPublicKeyFingerprint: authorityFixture.fingerprint,
            outerPermit: probePermit
        )
        let policyBefore = try policy.pairingPolicySnapshot(
            outerPermit: probePermit
        )
        let preparedPolicyMutation = try XCTUnwrap(
            policy.preparePairingPolicyMutation(
                authorityKey: authorityFixture.declaredDeviceID,
                persistedValue: "alwaysAllow",
                outerPermit: probePermit
            )
        )
        let plan = PairingAcceptanceJournal.Plan(
            authority: authorityReceipt,
            trustedDeviceBefore: preparedTrustMutation.before,
            trustedDeviceAfter: preparedTrustMutation.after,
            pairingPolicyBefore: policyBefore,
            pairingPolicyAfter: preparedPolicyMutation.after
        )
        return OuterRecoveryHarness(
            authorityFixture: authorityFixture,
            authorityReceipt: authorityReceipt,
            inner: inner,
            outerJournalStore: outerJournalStore,
            kemStore: outerAwareStores.kem,
            protocolStore: outerAwareStores.protocolIdentity,
            trustedDeviceStore: trustedDeviceStore,
            preparedTrustMutation: preparedTrustMutation,
            policy: policy,
            preparedPolicyMutation: preparedPolicyMutation,
            plan: plan
        )
    }

    private struct PairingIdentityJournalFixture {
        let declaredDeviceID: String
        let authorizedDeviceIDs: [String]
        let fingerprint: String
        let protocolPublicKey: Data
        let kemPublicKey: Data
        let payload: AppMessage.PairingIdentityExchangePayload
        let authority: ValidatedPairingIdentityAuthority
    }

    private struct PairingIdentityJournalHarness {
        let suiteName: String
        let kemStorageKey: String
        let protocolStorageKey: String
        let journalStore: AuthorityBoundPairingIdentityJournalStore
        let journalProbe: @Sendable () -> Bool
        let kemStore: KEMTrustStore
        let protocolStore: ProtocolIdentityTrustStore

        func reopenedStores(
            pairingAcceptanceJournalExists: @escaping @Sendable () -> Bool = { false }
        ) throws -> (
            kem: KEMTrustStore,
            protocolIdentity: ProtocolIdentityTrustStore
        ) {
            return (
                try makeKEMStore(
                    authorityJournalExists: journalProbe,
                    pairingAcceptanceJournalExists: pairingAcceptanceJournalExists
                ),
                try makeProtocolIdentityStore(
                    authorityJournalExists: journalProbe,
                    pairingAcceptanceJournalExists: pairingAcceptanceJournalExists
                )
            )
        }

        func makeKEMStore(
            authorityJournalExists: @escaping @Sendable () -> Bool,
            pairingAcceptanceJournalExists: @escaping @Sendable () -> Bool = { false }
        ) throws -> KEMTrustStore {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            return KEMTrustStore(
                storageKey: kemStorageKey,
                userDefaults: defaults,
                authorityJournalExists: authorityJournalExists,
                pairingAcceptanceJournalExists: pairingAcceptanceJournalExists
            )
        }

        func makeProtocolIdentityStore(
            authorityJournalExists: @escaping @Sendable () -> Bool,
            pairingAcceptanceJournalExists: @escaping @Sendable () -> Bool = { false }
        ) throws -> ProtocolIdentityTrustStore {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            return ProtocolIdentityTrustStore(
                storageKey: protocolStorageKey,
                userDefaults: defaults,
                authorityJournalExists: authorityJournalExists,
                pairingAcceptanceJournalExists: pairingAcceptanceJournalExists
            )
        }

        func removePersistentState(
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            let journalDirectory = journalStore.journalURL.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: journalDirectory.path) else {
                return
            }
            do {
                try FileManager.default.removeItem(at: journalDirectory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Another idempotent cleanup may win between the existence check and removal.
            } catch {
                XCTFail(
                    "Failed to remove pairing identity journal test state: \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func makePairingIdentityJournalFixture() throws -> PairingIdentityJournalFixture {
        let declaredDeviceID = "id:\(UUID().uuidString.lowercased())"
        let boundAlias = "recent:mac:\(declaredDeviceID)"
        let protocolPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let identityKey = AppMessage.ProtocolIdentityPublicKeyInfo(
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            publicKey: protocolPublicKey
        )
        let fingerprint = try XCTUnwrap(identityKey.authoritativeFingerprint)
        let kemPublicKey = Data(repeating: 0x51, count: 1_216)
        let payload = AppMessage.PairingIdentityExchangePayload(
            deviceId: declaredDeviceID,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: kemPublicKey
                )
            ],
            protocolIdentityPublicKeys: [identityKey]
        )
        let authority = try AuthenticatedPairingIdentityAuthorityValidator.issue(
            payload: payload,
            sessionBinding: AuthenticatedHandshakePeerBinding(
                authority: AuthenticatedRemoteAuthority(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    protocolPublicKeyFingerprint: fingerprint,
                    protocolPublicKeyBytes: protocolPublicKey
                ),
                authenticatedRemoteSOAPeerId: PeerSessionArbiter.soaPeerId(
                    from: declaredDeviceID
                )
            ),
            sessionDeviceIds: [boundAlias],
            operatorApproval: nil
        )
        XCTAssertEqual(authority.authorizedDeviceIds, [declaredDeviceID])
        return PairingIdentityJournalFixture(
            declaredDeviceID: declaredDeviceID,
            authorizedDeviceIDs: authority.authorizedDeviceIds,
            fingerprint: fingerprint,
            protocolPublicKey: protocolPublicKey,
            kemPublicKey: kemPublicKey,
            payload: payload,
            authority: authority
        )
    }

    private func makePairingIdentityJournalHarness() throws -> PairingIdentityJournalHarness {
        let suiteName = "PairingIdentityJournalTests.\(UUID().uuidString)"
        let cleanupDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        cleanupDefaults.removePersistentDomain(forName: suiteName)
        let kemDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let protocolDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let journalStore = AuthorityBoundPairingIdentityJournalStore(
            journalURL: root.appendingPathComponent("pairing-identity.journal")
        )
        let journalProbe: @Sendable () -> Bool = {
            journalStore.journalExists
        }
        let kemStorageKey = "kem_trust_store.journal.tests.v1"
        let protocolStorageKey = "protocol_identity_trust_store.journal.tests.v1"
        return PairingIdentityJournalHarness(
            suiteName: suiteName,
            kemStorageKey: kemStorageKey,
            protocolStorageKey: protocolStorageKey,
            journalStore: journalStore,
            journalProbe: journalProbe,
            kemStore: KEMTrustStore(
                storageKey: kemStorageKey,
                userDefaults: kemDefaults,
                authorityJournalExists: journalProbe,
                pairingAcceptanceJournalExists: { false }
            ),
            protocolStore: ProtocolIdentityTrustStore(
                storageKey: protocolStorageKey,
                userDefaults: protocolDefaults,
                authorityJournalExists: journalProbe,
                pairingAcceptanceJournalExists: { false }
            )
        )
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

    private struct LegacyProtocolIdentityStoredPeer: Codable {
        var fingerprints: [String]
        var updatedAt: Date
    }
}

@available(iOS 17.0, *)
@MainActor
private final class PairingAcceptanceTestPolicyParticipant:
    PairingPolicyAuthorityParticipant {
    enum TestError: Error {
        case invalidPermit
        case concurrentModification
        case invalidValue
    }

    let journalStore: PairingAcceptanceJournalStore
    var values: [String: String] = [:]

    init(journalStore: PairingAcceptanceJournalStore) {
        self.journalStore = journalStore
    }

    func preparePairingPolicyMutation(
        authorityKey: String,
        persistedValue: String?,
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> PreparedPairingPolicyMutation? {
        try requirePermit(outerPermit)
        guard let persistedValue else { return nil }
        guard persistedValue == "alwaysAllow" || persistedValue == "reject" else {
            throw TestError.invalidValue
        }
        let before = PairingPolicySnapshot(valuesByAuthorityID: values)
        var candidate = values
        candidate[authorityKey] = persistedValue
        guard candidate != values else { return nil }
        return PreparedPairingPolicyMutation(
            before: before,
            after: PairingPolicySnapshot(valuesByAuthorityID: candidate)
        )
    }

    func applyPreparedPairingPolicyMutation(
        _ prepared: PreparedPairingPolicyMutation,
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws {
        try requirePermit(outerPermit)
        guard values == prepared.before.valuesByAuthorityID else {
            throw TestError.concurrentModification
        }
        values = prepared.after.valuesByAuthorityID
    }

    func pairingPolicySnapshot(
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> PairingPolicySnapshot {
        try requirePermit(outerPermit)
        return PairingPolicySnapshot(valuesByAuthorityID: values)
    }

    func restorePairingPolicySnapshot(
        _ snapshot: PairingPolicySnapshot,
        expectedCurrent: [PairingPolicySnapshot],
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws {
        try requirePermit(outerPermit)
        guard expectedCurrent.contains(where: { $0.valuesByAuthorityID == values }) else {
            throw TestError.concurrentModification
        }
        values = snapshot.valuesByAuthorityID
    }

    func pairingPolicySnapshotMatches(
        _ snapshot: PairingPolicySnapshot,
        outerPermit: PairingIdentityAuthorityMutationPermit
    ) throws -> Bool {
        try requirePermit(outerPermit)
        return values == snapshot.valuesByAuthorityID
    }

    private func requirePermit(
        _ permit: PairingIdentityAuthorityMutationPermit
    ) throws {
        if journalStore.journalExists,
           !journalStore.ownsActiveJournal(permit) {
            throw TestError.invalidPermit
        }
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
