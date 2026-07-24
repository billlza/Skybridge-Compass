import CryptoKit
import XCTest
@testable import SkyBridgeCore

final class AuthenticatedPQCSigningTrustResolverTests: XCTestCase {
    func testPairingPayloadMustMatchTheAuthenticatedAuthorityExactly() throws {
        let publicKey = Data(repeating: 0x31, count: 1_952)
        let payload = AppMessage.PairingIdentityExchangePayload(
            deviceId: "bound-peer",
            kemPublicKeys: [],
            protocolIdentityPublicKeys: [
                .init(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                    publicKey: publicKey
                )
            ]
        )
        let fingerprint = try XCTUnwrap(payload.protocolIdentityPublicKeys?.first?.authoritativeFingerprint)
        let matchingAuthority = AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint
        )
        XCTAssertEqual(
            AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                in: payload,
                authority: matchingAuthority
            ),
            publicKey
        )

        let conflictingRawAuthority = AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKey: Data(repeating: 0x32, count: 1_952)
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                in: payload,
                authority: conflictingRawAuthority
            )
        )

        let mismatchedFingerprint = AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: String(repeating: "0", count: 64)
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                in: payload,
                authority: mismatchedFingerprint
            )
        )

        let mismatchedAlgorithm = AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fingerprint
        )
        XCTAssertNil(
            AuthenticatedProtocolIdentityBinding.matchingPublicKey(
                in: payload,
                authority: mismatchedAlgorithm
            )
        )
    }

    @MainActor
    func testPairingIdentityPayloadPromotesCanonicalRecordUsedByStrictVerifier() async throws {
        SettingsManager.shared.enablePQC = true
        SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        let peerId = "pairing-to-strict-verifier-\(UUID().uuidString)"
        let message = Data("pairing identity to strict verifier".utf8)
        let keychain = PQCKeychainTestContext()
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: peerId,
            storageScope: keychain.storageScope
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try PQCBackendAuthorityStore.deleteForTesting(
                domain: .quantumAdapter,
                scopeSource: keychain.scopeSource
            )
            try deviceIdentity.reset()
        }
        let signer = OQSProvider(scopeSource: keychain.scopeSource)
        let signature = try await signer.sign(
            data: message,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        let publicKey = try await signer.localSigningPublicKey(
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        let payload = AppMessage.PairingIdentityExchangePayload(
            deviceId: peerId,
            kemPublicKeys: [],
            protocolIdentityPublicKeys: [
                .init(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                    publicKey: publicKey
                )
            ]
        )
        let advertisedKey = try XCTUnwrap(payload.protocolIdentityPublicKeys?.first)
        let fingerprint = try XCTUnwrap(advertisedKey.authoritativeFingerprint)
        let promotedRecord = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: payload.deviceId,
                preferredCurrentDeviceId: payload.deviceId,
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: fingerprint,
                authenticatedProtocolPublicKey: advertisedKey.publicKey,
                pinSource: .authenticatedHandshake
            )
        )
        XCTAssertTrue(promotedRecord.isAuthenticationEligible)
        XCTAssertEqual(promotedRecord.protocolPublicKey, publicKey)

        let trust = TrustSyncService.shared
        trust.setInMemoryPersistenceForTesting(true)
        await trust.removeRecordsForTesting(deviceIds: [peerId])
        _ = try await trust.addTrustRecord(promotedRecord)
        addTeardownBlock { @MainActor [trust] in
            await trust.removeRecordsForTesting(deviceIds: [peerId])
            trust.setInMemoryPersistenceForTesting(false)
        }

        let verified = try await EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: deviceIdentity.manager
        ).verifyPQCRequired(
            message,
            signature: signature,
            for: peerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertTrue(verified)
    }

    func testActiveAuthenticatedMLDSA65RecordResolvesExactProtocolKey() throws {
        let peerId = "trusted-pqc-peer-\(UUID().uuidString)"
        let publicKey = Data(repeating: 0x41, count: 1_952)
        let record = makeRecord(deviceId: peerId, publicKey: publicKey)

        let resolved = try EnhancedPostQuantumCrypto.validatedAuthenticatedRemoteProtocolSigningKey(
            records: [record],
            peerId: peerId
        )
        XCTAssertEqual(resolved, publicKey)
    }

    func testRevokedQuarantinedLegacyOrMalformedRecordsNeverAuthorizeVerification() throws {
        let peerId = "rejected-pqc-peer-\(UUID().uuidString)"
        let publicKey = Data(repeating: 0x52, count: 1_952)
        let rejectedRecords = [
            makeRecord(
                deviceId: peerId,
                publicKey: publicKey,
                lifecycleState: .quarantined
            ),
            makeRecord(
                deviceId: peerId,
                publicKey: publicKey,
                pinSource: .legacyMigration
            ),
            makeRecord(
                deviceId: peerId,
                publicKey: Data(publicKey.dropLast())
            ),
            makeRecord(
                deviceId: peerId,
                publicKey: publicKey,
                recordType: .revoke,
                revokedAt: Date()
            )
        ]

        for record in rejectedRecords {
            XCTAssertThrowsError(
                try EnhancedPostQuantumCrypto.validatedAuthenticatedRemoteProtocolSigningKey(
                    records: [record],
                    peerId: peerId
                )
            ) { error in
                XCTAssertEqual(
                    error as? EnhancedPostQuantumCryptoError,
                    .authenticatedRemoteSigningKeyUnavailable
                )
            }
        }
    }

    func testMismatchedPinAndAmbiguousAliasFailClosed() throws {
        let peerId = "ambiguous-pqc-peer-\(UUID().uuidString)"
        let firstKey = Data(repeating: 0x63, count: 1_952)
        let secondKey = Data(repeating: 0x74, count: 1_952)
        let mismatchedPin = String(repeating: "0", count: 64)
        let mismatched = makeRecord(
            deviceId: peerId,
            publicKey: firstKey,
            pinnedFingerprint: mismatchedPin
        )

        XCTAssertThrowsError(
            try EnhancedPostQuantumCrypto.validatedAuthenticatedRemoteProtocolSigningKey(
                records: [mismatched],
                peerId: peerId
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancedPostQuantumCryptoError,
                .authenticatedRemoteSigningKeyUnavailable
            )
        }

        let first = makeRecord(
            deviceId: "first-\(UUID().uuidString)",
            publicKey: firstKey,
            knownDeviceIds: [peerId]
        )
        let second = makeRecord(
            deviceId: "second-\(UUID().uuidString)",
            publicKey: secondKey,
            knownDeviceIds: [peerId]
        )
        XCTAssertThrowsError(
            try EnhancedPostQuantumCrypto.validatedAuthenticatedRemoteProtocolSigningKey(
                records: [first, second],
                peerId: peerId
            )
        ) { error in
            XCTAssertEqual(
                error as? EnhancedPostQuantumCryptoError,
                .authenticatedRemoteSigningKeyAmbiguous
            )
        }
    }

    private func makeRecord(
        deviceId: String,
        publicKey: Data,
        pinnedFingerprint: String? = nil,
        pinSource: ProtocolIdentityPinSource = .authenticatedHandshake,
        lifecycleState: TrustLifecycleState = .active,
        recordType: TrustRecordType = .add,
        revokedAt: Date? = nil,
        knownDeviceIds: [String]? = nil
    ) -> TrustRecord {
        let actualFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: publicKey
        )
        let pinFingerprint = pinnedFingerprint ?? actualFingerprint
        return TrustRecord(
            deviceId: deviceId,
            pubKeyFP: actualFingerprint,
            publicKey: publicKey,
            protocolPublicKey: publicKey,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: pinFingerprint,
            protocolIdentityPins: [
                ProtocolIdentityPin(
                    algorithm: .mlDSA65,
                    fingerprint: pinFingerprint,
                    source: pinSource
                )
            ],
            signature: Data(repeating: 0xA5, count: 64),
            recordType: recordType,
            revokedAt: revokedAt,
            currentDeviceId: deviceId,
            knownDeviceIds: knownDeviceIds ?? [deviceId],
            lifecycleState: lifecycleState
        )
    }
}
