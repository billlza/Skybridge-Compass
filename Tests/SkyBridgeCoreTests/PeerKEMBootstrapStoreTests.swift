import CryptoKit
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PeerKEMBootstrapStoreTests: XCTestCase {
    func testLookupAcrossAliasCandidates() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let key257 = KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data(repeating: 0xA1, count: 1_184))
        let key258 = KEMPublicKeyInfo(suiteWireId: 258, publicKey: Data(repeating: 0xA2, count: 1_184))

        let rawId = UUID().uuidString.lowercased()
        let canonicalId = "id:\(rawId)"
        await store.upsert(
            deviceIds: [canonicalId, rawId, "host:192.168.10.22"],
            kemPublicKeys: [key257, key258]
        )

        let merged = await store.mergedKEMPublicKeys(forCandidates: [rawId])
        let endpointOnly = await store.mergedKEMPublicKeys(forCandidates: ["host:192.168.10.22"])
        XCTAssertEqual(merged[257], key257.publicKey)
        XCTAssertEqual(merged[258], key258.publicKey)
        XCTAssertTrue(endpointOnly.isEmpty)
        await store.clearForTesting()
    }

    func testUpsertMergesSuitesOnRepeatedWrites() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let key257 = Data(repeating: 0x10, count: 1_184)
        let key258 = Data(repeating: 0x20, count: 1_184)

        await store.upsert(
            deviceIds: ["peer-a"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: key257)]
        )
        await store.upsert(
            deviceIds: ["peer-a"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 258, publicKey: key258)]
        )

        let merged = await store.mergedKEMPublicKeys(forCandidates: ["peer-a"])
        XCTAssertEqual(Set(merged.keys), Set([257, 258]))
        XCTAssertEqual(merged[257], key257)
        XCTAssertEqual(merged[258], key258)
        await store.clearForTesting()
    }

    func testLatestWriteReplacesSameSuiteKey() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let oldKey = Data(repeating: 0x01, count: 1_184)
        let newKey = Data(repeating: 0x02, count: 1_184)

        await store.upsert(
            deviceIds: ["peer-b"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: oldKey)]
        )
        await store.upsert(
            deviceIds: ["peer-b"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: newKey)]
        )

        let merged = await store.mergedKEMPublicKeys(forCandidates: ["peer-b"])
        XCTAssertEqual(merged[257], newKey)
        await store.clearForTesting()
    }

    func testEmptyPublicKeyDoesNotReplaceStoredBootstrapKey() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let validKey = Data(repeating: 0x10, count: 1_184)

        await store.upsert(
            deviceIds: ["peer-c"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: validKey)]
        )
        await store.upsert(
            deviceIds: ["peer-c"],
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data())]
        )

        let merged = await store.mergedKEMPublicKeys(forCandidates: ["peer-c"])
        XCTAssertEqual(merged[257], validKey)
        await store.clearForTesting()
    }

    func testRawUpsertRejectsUnknownClassicAndWrongLengthKEM() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        await store.upsert(
            deviceIds: ["peer-invalid"],
            kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: 0x0000, publicKey: Data(repeating: 0x00, count: 1_216)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.x25519Ed25519.wireId, publicKey: Data(repeating: 0x11, count: 32)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: Data(repeating: 0x22, count: 32)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: Data(repeating: 0x23, count: 1_184)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, publicKey: Data(repeating: 0x24, count: 1_216)),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768MLDSA65FS.wireId, publicKey: Data(repeating: 0x25, count: 1_216))
            ]
        )

        let rejected = await store.mergedKEMPublicKeys(forCandidates: ["peer-invalid"])
        XCTAssertTrue(rejected.isEmpty)

        let validXWing = Data(repeating: 0x33, count: 1_216)
        let validMLKEM = Data(repeating: 0x34, count: 1_184)
        let validMLKEMFS = Data(repeating: 0x35, count: 1_184)
        await store.upsert(
            deviceIds: ["peer-invalid"],
            kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.xwingMLDSA.wireId, publicKey: validXWing),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, publicKey: validMLKEM),
                KEMPublicKeyInfo(suiteWireId: CryptoSuite.mlkem768MLDSA65FS.wireId, publicKey: validMLKEMFS)
            ]
        )

        let accepted = await store.mergedKEMPublicKeys(forCandidates: ["peer-invalid"])
        XCTAssertEqual(accepted[CryptoSuite.xwingMLDSA.wireId], validXWing)
        XCTAssertEqual(accepted[CryptoSuite.mlkem768MLDSA65.wireId], validMLKEM)
        XCTAssertEqual(accepted[CryptoSuite.mlkem768MLDSA65FS.wireId], validMLKEMFS)
        await store.clearForTesting()
    }

    func testLoadPurgesLegacyPersistedInvalidKEMMaterial() async throws {
        let suiteName = "PeerKEMBootstrapStoreLegacyPurgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let validMLKEM = Data(repeating: 0x44, count: 1_184)
        let snapshot = LegacyBootstrapKEMSnapshot(entries: [
            "peer-legacy": LegacyBootstrapKEMEntry(
                kemPublicKeys: [
                    0x0000: Data(repeating: 0x00, count: 1_216),
                    CryptoSuite.x25519Ed25519.wireId: Data(repeating: 0x11, count: 32),
                    CryptoSuite.xwingMLDSA.wireId: Data(repeating: 0x22, count: 32),
                    CryptoSuite.mlkem768MLDSA65.wireId: validMLKEM
                ],
                updatedAt: Date()
            )
        ])
        defaults.set(
            try JSONEncoder().encode(snapshot),
            forKey: "com.skybridge.p2p.bootstrap_kem_store.v1"
        )

        let store = PeerKEMBootstrapStore(defaults: defaults)
        let loaded = await store.mergedKEMPublicKeys(forCandidates: ["peer-legacy"])

        XCTAssertEqual(loaded, [CryptoSuite.mlkem768MLDSA65.wireId: validMLKEM])
    }

    func testClearRemovesOnlyRequestedBootstrapAliases() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let forgetKey = KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data(repeating: 0xF0, count: 1_184))
        let keepKey = KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data(repeating: 0x0F, count: 1_184))
        await store.upsert(deviceIds: ["id:forgotten", "bonjour:Forgotten@local."], kemPublicKeys: [forgetKey])
        await store.upsert(deviceIds: ["id:kept"], kemPublicKeys: [keepKey])

        await store.clear(deviceIds: ["id:forgotten", "bonjour:Forgotten@local."])

        let forgotten = await store.mergedKEMPublicKeys(forCandidates: ["id:forgotten"])
        let forgottenBonjour = await store.mergedKEMPublicKeys(forCandidates: ["bonjour:Forgotten@local."])
        let kept = await store.mergedKEMPublicKeys(forCandidates: ["id:kept"])
        XCTAssertTrue(forgotten.isEmpty)
        XCTAssertTrue(forgottenBonjour.isEmpty)
        XCTAssertEqual(kept[257], keepKey.publicKey)
        await store.clearForTesting()
    }

    func testSignedKEMRefreshImportsMetadataAndBeatsUnsignedKEM() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let endpointAlias = "host:192.168.10.44"
        let signedKey = Data(repeating: 0x42, count: 1_216)
        let unsignedKey = Data(repeating: 0x99, count: 1_216)
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            aliases: [endpointAlias],
            kemPublicKey: signedKey,
            generation: 41
        )

        try await store.upsertSignedKEMRefresh(
            deviceIds: [endpointAlias],
            payload: exchange.payload,
            request: exchange.request,
            pinnedProtocolFingerprints: [exchange.payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )

        let byCanonical = await store.mergedKEMPublicKeys(forCandidates: [canonicalId])
        let byAlias = await store.mergedKEMPublicKeys(forCandidates: [endpointAlias])
        let endpointOnlyEvidence = await store.signedRefreshEvidence(forCandidates: [endpointAlias])
        let generation = await store.maximumKEMGeneration(forCandidates: [canonicalId, endpointAlias])
        let evidence = await store.signedRefreshEvidence(forCandidates: [canonicalId, endpointAlias])

        XCTAssertEqual(byCanonical[CryptoSuite.xwingMLDSA.wireId], signedKey)
        XCTAssertNil(byAlias[CryptoSuite.xwingMLDSA.wireId])
        XCTAssertNil(endpointOnlyEvidence)
        XCTAssertEqual(generation, 41)
        XCTAssertEqual(evidence?.deviceId, canonicalId)
        XCTAssertEqual(evidence?.source, "signed_lan_kem_refresh")
        XCTAssertEqual(evidence?.suiteWireIds, [CryptoSuite.xwingMLDSA.wireId])
        XCTAssertEqual(evidence?.keyId, "skr1-test-41")
        XCTAssertEqual(evidence?.protocolIdentityFingerprint, exchange.payload.protocolIdentityFingerprint)
        XCTAssertEqual(evidence?.signingFingerprint, exchange.payload.protocolIdentityFingerprint)
        XCTAssertEqual(evidence?.payloadHashHex, Self.sha256Hex(exchange.payload.signaturePreimage))

        let aliasFirstEvidence = await store.signedRefreshEvidence(forCandidates: [endpointAlias, canonicalId])
        XCTAssertEqual(aliasFirstEvidence?.deviceId, canonicalId)

        await store.upsert(
            deviceIds: [canonicalId],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: unsignedKey
                )
            ]
        )
        let preserved = await store.mergedKEMPublicKeys(forCandidates: [canonicalId])
        let preservedEvidence = await store.signedRefreshEvidence(forCandidates: [canonicalId])
        XCTAssertEqual(preserved[CryptoSuite.xwingMLDSA.wireId], signedKey)
        XCTAssertEqual(preservedEvidence?.payloadHashHex, Self.sha256Hex(exchange.payload.signaturePreimage))

        await store.clearForTesting()
    }

    func testSignedRefreshKEMLookupRequiresSignedSourceAndPinnedProtocolFingerprint() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let unsignedKey = Data(repeating: 0x36, count: 1_184)
        await store.upsert(
            deviceIds: [canonicalId],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: unsignedKey
                )
            ]
        )

        let unsignedOnly = await store.signedRefreshKEMPublicKeys(
            forCandidates: [canonicalId],
            pinnedProtocolFingerprints: [String(repeating: "a", count: 64)]
        )
        XCTAssertTrue(unsignedOnly.isEmpty)

        let signedKey = Data(repeating: 0x37, count: 1_216)
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: signedKey,
            generation: 42
        )
        try await store.upsertSignedKEMRefresh(
            deviceIds: [canonicalId],
            payload: exchange.payload,
            request: exchange.request,
            pinnedProtocolFingerprints: [exchange.payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )

        let wrongPin = await store.signedRefreshKEMPublicKeys(
            forCandidates: [canonicalId],
            pinnedProtocolFingerprints: [String(repeating: "f", count: 64)]
        )
        let rightPin = await store.signedRefreshKEMPublicKeys(
            forCandidates: [canonicalId],
            pinnedProtocolFingerprints: [exchange.payload.protocolIdentityFingerprint.uppercased()]
        )

        XCTAssertTrue(wrongPin.isEmpty)
        XCTAssertNil(rightPin[CryptoSuite.mlkem768MLDSA65.wireId])
        XCTAssertEqual(rightPin[CryptoSuite.xwingMLDSA.wireId], signedKey)

        await store.clearForTesting()
    }

    func testSignedKEMRefreshRejectsUnrequestedSuiteAtImportBoundary() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: Data(repeating: 0x51, count: 1_184),
            kemSuite: .mlkem768MLDSA65,
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            generation: 42
        )

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

        let stored = await store.mergedKEMPublicKeys(forCandidates: [canonicalId])
        let evidence = await store.signedRefreshEvidence(forCandidates: [canonicalId])
        XCTAssertTrue(stored.isEmpty)
        XCTAssertNil(evidence)

        await store.clearForTesting()
    }

    func testSignedKEMRefreshRejectsInvalidSignatureAtImportBoundary() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: Data(repeating: 0x58, count: 1_216),
            generation: 44
        )
        let payload = exchange.payload
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
            signature: Data(repeating: 0x00, count: 64)
        )

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
                error as? PeerKEMBootstrapStore.SignedRefreshImportError,
                .signatureVerificationFailed
            )
        }

        let stored = await store.mergedKEMPublicKeys(forCandidates: [canonicalId])
        let evidence = await store.signedRefreshEvidence(forCandidates: [canonicalId])
        XCTAssertTrue(stored.isEmpty)
        XCTAssertNil(evidence)

        await store.clearForTesting()
    }

    func testSignedKEMRefreshRejectsExpiredPayloadAtImportBoundary() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: Data(repeating: 0x59, count: 1_216),
            generation: 45,
            payloadSentAt: Date(timeIntervalSinceNow: -600),
            expiresAt: Date(timeIntervalSinceNow: -300)
        )

        await XCTAssertThrowsErrorAsync(
            try await store.upsertSignedKEMRefresh(
                deviceIds: [canonicalId],
                payload: exchange.payload,
                request: exchange.request,
                pinnedProtocolFingerprints: [exchange.payload.protocolIdentityFingerprint],
                minimumGeneration: nil
            )
        ) { error in
            XCTAssertEqual(error as? AppMessage.KEMRefreshValidationError, .expired)
        }

        let stored = await store.mergedKEMPublicKeys(forCandidates: [canonicalId])
        let evidence = await store.signedRefreshEvidence(forCandidates: [canonicalId])
        XCTAssertTrue(stored.isEmpty)
        XCTAssertNil(evidence)

        await store.clearForTesting()
    }

    func testSignedKEMRefreshRejectsGenerationRollbackAtImportBoundary() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let currentKey = Data(repeating: 0x60, count: 1_216)
        let rollbackKey = Data(repeating: 0x61, count: 1_216)
        let current = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: currentKey,
            generation: 50
        )

        try await store.upsertSignedKEMRefresh(
            deviceIds: [canonicalId],
            payload: current.payload,
            request: current.request,
            pinnedProtocolFingerprints: [current.payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )

        let rollback = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: rollbackKey,
            generation: 49
        )
        let existingGeneration = await store.maximumKEMGeneration(forCandidates: [canonicalId])

        await XCTAssertThrowsErrorAsync(
            try await store.upsertSignedKEMRefresh(
                deviceIds: [canonicalId],
                payload: rollback.payload,
                request: rollback.request,
                pinnedProtocolFingerprints: [rollback.payload.protocolIdentityFingerprint],
                minimumGeneration: existingGeneration
            )
        ) { error in
            XCTAssertEqual(
                error as? AppMessage.KEMRefreshValidationError,
                .generationRollback(current: 50, incoming: 49)
            )
        }

        let stored = await store.mergedKEMPublicKeys(forCandidates: [canonicalId])
        let evidence = await store.signedRefreshEvidence(forCandidates: [canonicalId])
        XCTAssertEqual(stored[CryptoSuite.xwingMLDSA.wireId], currentKey)
        XCTAssertEqual(evidence?.generation, 50)
        XCTAssertEqual(evidence?.payloadHashHex, Self.sha256Hex(current.payload.signaturePreimage))

        await store.clearForTesting()
    }

    func testRawUpsertDoesNotReviveExpiredSignedRefreshKeys() async throws {
        let store = PeerKEMBootstrapStore.shared
        await store.clearForTesting()

        let canonicalId = "id:\(UUID().uuidString.lowercased())"
        let signedKey = Data(repeating: 0x62, count: 1_216)
        let rawKey = Data(repeating: 0x63, count: 1_184)
        let exchange = try makeSignedKEMRefreshExchange(
            deviceId: canonicalId,
            kemPublicKey: signedKey,
            generation: 43,
            expiresAt: Date().addingTimeInterval(0.05)
        )

        try await store.upsertSignedKEMRefresh(
            deviceIds: [canonicalId],
            payload: exchange.payload,
            request: exchange.request,
            pinnedProtocolFingerprints: [exchange.payload.protocolIdentityFingerprint],
            minimumGeneration: nil
        )
        try await Task.sleep(for: .milliseconds(80))

        await store.upsert(
            deviceIds: [canonicalId],
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: rawKey
                )
            ]
        )

        let stored = await store.mergedKEMPublicKeys(forCandidates: [canonicalId])
        let evidence = await store.signedRefreshEvidence(forCandidates: [canonicalId])
        XCTAssertNil(stored[CryptoSuite.xwingMLDSA.wireId])
        XCTAssertEqual(stored[CryptoSuite.mlkem768MLDSA65.wireId], rawKey)
        XCTAssertNil(evidence)

        await store.clearForTesting()
    }

    private func makeSignedKEMRefreshExchange(
        deviceId: String,
        aliases: [String] = [],
        kemPublicKey: Data,
        kemSuite: CryptoSuite = .xwingMLDSA,
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
        let endpointDigest = String(repeating: "b", count: 64)
        let request = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:mac-kem-store-test",
            targetDeviceId: deviceId,
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: fingerprint,
            requestedSuiteWireIds: requestedSuiteWireIds ?? [kemSuite.wireId],
            policyRequirePQC: true,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: endpointDigest,
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
            bonjourEndpointDigest: endpointDigest,
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

    private struct LegacyBootstrapKEMSnapshot: Codable {
        var entries: [String: LegacyBootstrapKEMEntry]
    }

    private struct LegacyBootstrapKEMEntry: Codable {
        var kemPublicKeys: [UInt16: Data]
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

@available(macOS 14.0, iOS 17.0, *)
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
