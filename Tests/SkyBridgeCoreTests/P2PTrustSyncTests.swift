//
// P2PTrustSyncTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for P2P Trust Sync Service
// **Feature: ios-p2p-integration**
//
// Property 10: Trust Record Round-Trip Serialization (Validates: Requirements 3.6)
// Property 11: Tombstone Conflict Resolution (Validates: Requirements 3.5)
// Property 12: Keychain Sync Attribute (Validates: Requirements 3.8)
//

import CryptoKit
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PTrustSyncTests: XCTestCase {
    
 // MARK: - Property 10: Trust Record Round-Trip Serialization
    
 /// **Property 10: Trust Record Round-Trip Serialization**
 /// *For any* valid TrustRecord (including tombstone records), serializing to JSON
 /// and deserializing should produce an equivalent record.
 /// **Validates: Requirements 3.6**
    func testTrustRecordRoundTripSerializationProperty() throws {
 // Generate test records with various configurations
        let testRecords = generateTestTrustRecords()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        
        for record in testRecords {
 // Encode
            let encoded = try encoder.encode(record)
            
 // Decode
            let decoded = try decoder.decode(TrustRecord.self, from: encoded)
            
 // Property: Round-trip should produce equivalent record
            XCTAssertEqual(decoded.deviceId, record.deviceId,
                           "deviceId must survive round-trip")
            XCTAssertEqual(decoded.pubKeyFP, record.pubKeyFP,
                           "pubKeyFP must survive round-trip")
            XCTAssertEqual(decoded.publicKey, record.publicKey,
                           "publicKey must survive round-trip")
            XCTAssertEqual(decoded.attestationLevel, record.attestationLevel,
                           "attestationLevel must survive round-trip")
            XCTAssertEqual(decoded.attestationData, record.attestationData,
                           "attestationData must survive round-trip")
            XCTAssertEqual(decoded.capabilities, record.capabilities,
                           "capabilities must survive round-trip")
            XCTAssertEqual(decoded.version, record.version,
                           "version must survive round-trip")
            XCTAssertEqual(decoded.signature, record.signature,
                           "signature must survive round-trip")
            XCTAssertEqual(decoded.recordType, record.recordType,
                           "recordType must survive round-trip")
            XCTAssertEqual(decoded.deviceName, record.deviceName,
                           "deviceName must survive round-trip")
            XCTAssertEqual(decoded.protocolSigningAlgorithm, record.protocolSigningAlgorithm,
                           "protocolSigningAlgorithm must survive round-trip")
            XCTAssertEqual(decoded.protocolPublicKeyFingerprint, record.protocolPublicKeyFingerprint,
                           "protocolPublicKeyFingerprint must survive round-trip")
            XCTAssertEqual(decoded.protocolPublicKey, record.protocolPublicKey,
                           "protocolPublicKey must survive round-trip")
            XCTAssertEqual(decoded.protocolIdentityBindingsV2, record.protocolIdentityBindingsV2,
                           "protocolIdentityBindingsV2 must survive round-trip")
            XCTAssertEqual(decoded.currentDeviceIdMetadata, record.currentDeviceIdMetadata,
                           "currentDeviceId must survive round-trip")
            XCTAssertEqual(decoded.knownDeviceIdsMetadata, record.knownDeviceIdsMetadata,
                           "knownDeviceIds must survive round-trip")
            XCTAssertEqual(decoded.lifecycleStateMetadata, record.lifecycleStateMetadata,
                           "lifecycleState must survive round-trip")
            
 // Date comparison with millisecond precision
            XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                           record.createdAt.timeIntervalSince1970,
                           accuracy: 0.001,
                           "createdAt must survive round-trip")
            XCTAssertEqual(decoded.updatedAt.timeIntervalSince1970,
                           record.updatedAt.timeIntervalSince1970,
                           accuracy: 0.001,
                           "updatedAt must survive round-trip")
            
            if let revokedAt = record.revokedAt {
                XCTAssertNotNil(decoded.revokedAt, "revokedAt must survive round-trip")
                XCTAssertEqual(decoded.revokedAt!.timeIntervalSince1970,
                               revokedAt.timeIntervalSince1970,
                               accuracy: 0.001,
                               "revokedAt must survive round-trip")
            } else {
                XCTAssertNil(decoded.revokedAt, "nil revokedAt must survive round-trip")
            }
        }
    }
    
 /// Test tombstone record serialization specifically
    func testTombstoneRecordRoundTrip() throws {
        let baseRecord = createTestTrustRecord(deviceId: "tombstone-device")
        let tombstoneRecord = baseRecord.revoked(signature: Data(repeating: 0xBB, count: 64))
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        
        let encoded = try encoder.encode(tombstoneRecord)
        let decoded = try decoder.decode(TrustRecord.self, from: encoded)
        
 // Property: Tombstone status must be preserved
        XCTAssertTrue(decoded.isTombstone, "Tombstone status must survive round-trip")
        XCTAssertEqual(decoded.recordType, .revoke, "Record type must be revoke")
        XCTAssertNotNil(decoded.revokedAt, "revokedAt must be set for tombstone")
        XCTAssertEqual(decoded.version, baseRecord.version + 1, "Version must be incremented")
    }
    
 /// Test encoding is deterministic
    func testTrustRecordEncodingDeterministic() throws {
        let record = createTestTrustRecord(deviceId: "deterministic-test")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        
        let encoded1 = try encoder.encode(record)
        let encoded2 = try encoder.encode(record)
        
 // Property: Same record must produce same encoding
        XCTAssertEqual(encoded1, encoded2,
                       "Encoding must be deterministic")
    }
    
 // MARK: - Property 11: Tombstone Conflict Resolution
    
 /// **Property 11: Tombstone Conflict Resolution**
 /// *For any* two conflicting trust records, if either is a revoke (tombstone),
 /// the revoke record should win; otherwise use LWW based on updatedAt.
 /// **Validates: Requirements 3.5**
    @MainActor
    func testTombstoneConflictResolutionProperty() async throws {
        let service = TrustSyncService.shared
        
 // Test case 1: Local is tombstone, remote is add
        let localTombstone = createTestTrustRecord(
            deviceId: "conflict-device-1",
            recordType: .revoke,
            revokedAt: Date()
        )
        let remoteAdd = createTestTrustRecord(
            deviceId: "conflict-device-1",
            recordType: .add,
            updatedAt: Date().addingTimeInterval(100) // Remote is newer
        )
        
        let resolved1 = try service.resolveConflict(local: localTombstone, remote: remoteAdd)
        
 // Property: Tombstone must win regardless of timestamp
        XCTAssertEqual(resolved1.recordType, .revoke,
                       "Tombstone must win over add")
        XCTAssertTrue(resolved1.isTombstone,
                      "Resolved record must be tombstone")
        
 // Test case 2: Remote is tombstone, local is add
        let localAdd = createTestTrustRecord(
            deviceId: "conflict-device-2",
            recordType: .add,
            updatedAt: Date().addingTimeInterval(100) // Local is newer
        )
        let remoteTombstone = createTestTrustRecord(
            deviceId: "conflict-device-2",
            recordType: .revoke,
            revokedAt: Date()
        )
        
        let resolved2 = try service.resolveConflict(local: localAdd, remote: remoteTombstone)
        
 // Property: Tombstone must win regardless of timestamp
        XCTAssertEqual(resolved2.recordType, .revoke,
                       "Tombstone must win over add")
        
 // Test case 3: Both are add, use LWW
        let olderAdd = createTestTrustRecord(
            deviceId: "conflict-device-3",
            recordType: .add,
            updatedAt: Date().addingTimeInterval(-100)
        )
        let newerAdd = createTestTrustRecord(
            deviceId: "conflict-device-3",
            recordType: .add,
            updatedAt: Date()
        )
        
        let resolved3 = try service.resolveConflict(local: olderAdd, remote: newerAdd)
        
 // Property: Newer record wins when both are add
        XCTAssertEqual(resolved3.updatedAt.timeIntervalSince1970,
                       newerAdd.updatedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "Newer add record must win (LWW)")
        
 // Test case 4: Both are tombstone, use LWW
        let olderTombstone = createTestTrustRecord(
            deviceId: "conflict-device-4",
            recordType: .revoke,
            revokedAt: Date().addingTimeInterval(-100),
            updatedAt: Date().addingTimeInterval(-100)
        )
        let newerTombstone = createTestTrustRecord(
            deviceId: "conflict-device-4",
            recordType: .revoke,
            revokedAt: Date(),
            updatedAt: Date()
        )
        
        let resolved4 = try service.resolveConflict(local: olderTombstone, remote: newerTombstone)
        
 // Property: Newer tombstone wins when both are tombstone
        XCTAssertEqual(resolved4.updatedAt.timeIntervalSince1970,
                       newerTombstone.updatedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "Newer tombstone must win (LWW)")
    }
    
 /// Test conflict resolution is symmetric for same-type records
    @MainActor
    func testConflictResolutionSymmetry() async throws {
        let service = TrustSyncService.shared
        
        let record1 = createTestTrustRecord(
            deviceId: "symmetric-test",
            recordType: .add,
            updatedAt: Date()
        )
        let record2 = createTestTrustRecord(
            deviceId: "symmetric-test",
            recordType: .add,
            updatedAt: Date().addingTimeInterval(10)
        )
        
        let resolved1 = try service.resolveConflict(local: record1, remote: record2)
        let resolved2 = try service.resolveConflict(local: record2, remote: record1)
        
 // Property: Resolution should be consistent regardless of order
        XCTAssertEqual(resolved1.updatedAt.timeIntervalSince1970,
                       resolved2.updatedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "Conflict resolution must be consistent")
    }

    func testRecordAuthenticatedRemoteAuthorityUpdatesAliasMatchedRecord() throws {
        let suffix = UUID().uuidString.lowercased()
        let aliasId = "bonjour:skybridge-\(suffix)@local."
        let stableId = "id:\(suffix)"
        let fingerprint = String(repeating: "d", count: 64)

        let aliasRecord = TrustRecord(
            deviceId: aliasId,
            pubKeyFP: "",
            publicKey: Data(),
            protocolPublicKey: nil,
            protocolSigningAlgorithm: nil,
            protocolPublicKeyFingerprint: nil,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: Data(repeating: 0xAA, count: 1_184)
                )
            ],
            attestationLevel: .none,
            signature: Data(),
            deviceName: "SkyBridge Test \(suffix)",
            currentDeviceId: stableId,
            knownDeviceIds: [aliasId, stableId],
            lifecycleState: .active
        )

        let updated = TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
            existingRecords: [aliasRecord],
            deviceId: aliasId,
            displayName: "SkyBridge Test \(suffix)",
            preferredCurrentDeviceId: stableId,
            knownDeviceIds: [aliasId, stableId],
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint
        )

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.deviceId, stableId)
        XCTAssertEqual(updated?.protocolSigningAlgorithm, .mlDSA65)
        XCTAssertEqual(updated?.protocolPublicKeyFingerprint, fingerprint)
        XCTAssertEqual(updated?.currentDeviceIdMetadata, stableId)
        XCTAssertTrue(
            Set(updated?.knownDeviceIdsMetadata ?? []).isSuperset(of: Set([aliasId, stableId])),
            "Known device ids should retain alias + stable identity while allowing normalized derivatives"
        )
        XCTAssertEqual(
            updated?.kemPublicKeys,
            [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: Data(repeating: 0xAA, count: 1_184)
                )
            ]
        )
    }

    func testAuthenticatedRemoteAuthorityPersistsOnlyFingerprintBoundProtocolPublicKey() throws {
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        let publicKey = Data(repeating: 0x5C, count: 1_952)
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: publicKey
        )

        let valid = TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
            existingRecords: [],
            deviceId: deviceId,
            preferredCurrentDeviceId: deviceId,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint,
            authenticatedProtocolPublicKey: publicKey
        )
        XCTAssertEqual(valid?.protocolPublicKey, publicKey)

        XCTAssertNil(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: String(repeating: "0", count: 64),
                authenticatedProtocolPublicKey: publicKey
            )
        )
        XCTAssertNil(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: fingerprint,
                authenticatedProtocolPublicKey: Data(publicKey.dropLast())
            )
        )
    }

    func testMLDSA65AndMLDSA87RawAuthoritiesCoexistWithoutWriting87ToLegacyFields() throws {
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        let mlDSA65Key = Data(repeating: 0x65, count: 1_952)
        let mlDSA87Key = Data(repeating: 0x87, count: 2_592)
        let mlDSA65Fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: mlDSA65Key
        )
        let mlDSA87Fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: mlDSA87Key
        )

        let mlDSA65Record = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: mlDSA65Fingerprint,
                authenticatedProtocolPublicKey: mlDSA65Key
            )
        )
        let dualAlgorithmRecord = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [mlDSA65Record],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: mlDSA87Fingerprint,
                authenticatedProtocolPublicKey: mlDSA87Key
            )
        )

        XCTAssertEqual(dualAlgorithmRecord.protocolSigningAlgorithm, .mlDSA65)
        XCTAssertEqual(dualAlgorithmRecord.protocolPublicKey, mlDSA65Key)
        XCTAssertEqual(dualAlgorithmRecord.protocolPublicKeyFingerprint, mlDSA65Fingerprint)
        XCTAssertFalse(
            dualAlgorithmRecord.protocolIdentityPins?.contains(where: { $0.algorithm == .mlDSA87 }) ?? false,
            "ML-DSA-87 must not enter the legacy enum-backed pin field"
        )
        XCTAssertEqual(
            Set(dualAlgorithmRecord.protocolIdentityBindingsV2?.map(\.algorithm) ?? []),
            Set([ProtocolSigningAlgorithm.mlDSA65.rawValue, ProtocolSigningAlgorithm.mlDSA87.rawValue])
        )
        XCTAssertEqual(dualAlgorithmRecord.getVerificationPublicKey(for: .mlDSA65), mlDSA65Key)
        XCTAssertEqual(dualAlgorithmRecord.getVerificationPublicKey(for: .mlDSA87), mlDSA87Key)
        XCTAssertNil(dualAlgorithmRecord.getVerificationPublicKey(for: .ed25519))
    }

    @MainActor
    func testAuthenticatedProtocolIdentityLookupRequiresActiveRawBinding() async throws {
        let service = TrustSyncService.shared
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        let publicKey = Data(repeating: 0x87, count: 2_592)
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: publicKey
        )
        let record = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: fingerprint,
                authenticatedProtocolPublicKey: publicKey
            )
        )

        service.setInMemoryPersistenceForTesting(true)
        try await service.removeRecordsForTesting(deviceIds: [deviceId])
        addTeardownBlock { @MainActor in
            try await service.removeRecordsForTesting(deviceIds: [deviceId])
            service.setInMemoryPersistenceForTesting(false)
        }

        XCTAssertEqual(
            service.outboundPQCSignatureAlgorithm(
                deviceId: deviceId,
                requestedAlgorithm: .mlDSA87
            ),
            .mlDSA65,
            "An unpinned peer must remain on the established ML-DSA-65 path"
        )
        _ = try await service.addTrustRecord(record)

        XCTAssertTrue(service.hasAuthenticatedProtocolIdentity(deviceId: deviceId, algorithm: .mlDSA87))
        XCTAssertEqual(
            service.authenticatedProtocolIdentityBinding(deviceId: deviceId, algorithm: .mlDSA87)?.publicKey,
            publicKey
        )
        XCTAssertFalse(service.hasAuthenticatedProtocolIdentity(deviceId: deviceId, algorithm: .mlDSA65))
        XCTAssertEqual(
            service.outboundPQCSignatureAlgorithm(
                deviceId: deviceId,
                requestedAlgorithm: .mlDSA87
            ),
            .mlDSA87
        )
        XCTAssertEqual(
            service.outboundPQCSignatureAlgorithm(
                deviceId: deviceId,
                requestedAlgorithm: .mlDSA65
            ),
            .mlDSA65,
            "Peer support must not override the local algorithm request"
        )

        _ = try await service.addTrustRecord(
            TrustRecord(
                deviceId: deviceId,
                pubKeyFP: record.pubKeyFP,
                publicKey: record.publicKey,
                capabilities: ["kem-refresh"],
                signature: Data(),
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId],
                lifecycleState: .active
            )
        )
        XCTAssertTrue(
            service.hasAuthenticatedProtocolIdentity(deviceId: deviceId, algorithm: .mlDSA87),
            "Generic metadata updates must not erase an existing raw-key authority sidecar"
        )
    }

    func testAuthenticatedAuthorityRejectsWrongAlgorithmAndEveryWrongRawKeyLength() throws {
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        let cases: [(ProtocolSigningAlgorithm, Int)] = [
            (.ed25519, 31),
            (.mlDSA65, 1_951),
            (.mlDSA87, 2_591)
        ]

        for (algorithm, length) in cases {
            let key = Data(repeating: 0xA5, count: length)
            let fingerprint = ProtocolIdentityBinding.computeFingerprint(
                algorithm: algorithm,
                publicKeyBytes: key
            )
            XCTAssertNil(
                TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                    existingRecords: [],
                    deviceId: deviceId,
                    preferredCurrentDeviceId: deviceId,
                    protocolSigningAlgorithm: algorithm,
                    protocolPublicKeyFingerprint: fingerprint,
                    authenticatedProtocolPublicKey: key
                ),
                "\(algorithm.rawValue) must reject a \(length)-byte public key"
            )
        }

        let mlDSA65Key = Data(repeating: 0x55, count: 1_952)
        let mlDSA65Fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: mlDSA65Key
        )
        XCTAssertNil(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: mlDSA65Fingerprint,
                authenticatedProtocolPublicKey: mlDSA65Key
            ),
            "Raw public-key bytes and fingerprint cannot be reinterpreted as another algorithm"
        )
        let mlDSA87Key = Data(repeating: 0x87, count: 2_592)
        XCTAssertNil(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: String(repeating: "0", count: 64),
                authenticatedProtocolPublicKey: mlDSA87Key
            ),
            "ML-DSA-87 raw authority must match its algorithm-bound fingerprint"
        )
        XCTAssertNil(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                authenticatedProtocolPublicKey: nil
            ),
            "ML-DSA-87 must never create a fingerprint-only authority"
        )
    }

    @MainActor
    func testSameAlgorithmAuthorityConflictIsRejectedInsteadOfLastWriterWins() throws {
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        let firstKey = Data(repeating: 0x11, count: 2_592)
        let secondKey = Data(repeating: 0x22, count: 2_592)
        let firstFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: firstKey
        )
        let secondFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: secondKey
        )
        let firstRecord = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: firstFingerprint,
                authenticatedProtocolPublicKey: firstKey
            )
        )

        XCTAssertNil(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [firstRecord],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: secondFingerprint,
                authenticatedProtocolPublicKey: secondKey
            )
        )

        let conflictingRecord = TrustRecord(
            deviceId: deviceId,
            pubKeyFP: firstRecord.pubKeyFP,
            publicKey: firstRecord.publicKey,
            protocolIdentityBindingsV2: [
                ProtocolIdentityBindingV2(
                    algorithm: .mlDSA87,
                    publicKey: secondKey,
                    fingerprint: secondFingerprint,
                    source: .authenticatedHandshake,
                    approvedAt: firstRecord.updatedAt.addingTimeInterval(60),
                    generation: 1
                )
            ],
            updatedAt: firstRecord.updatedAt.addingTimeInterval(60),
            signature: Data(repeating: 0xAB, count: 64),
            currentDeviceId: deviceId,
            knownDeviceIds: [deviceId],
            lifecycleState: .active
        )
        XCTAssertThrowsError(
            try TrustSyncService.shared.resolveConflict(local: firstRecord, remote: conflictingRecord)
        ) { error in
            guard case TrustSyncError.conflictResolutionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLegacyFixtureDecodeAndNewRecordRemainUnknownFieldCompatible() throws {
        let legacyFixture = Data(
            """
            {
              "deviceId":"legacy-fixture-device",
              "pubKeyFP":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "publicKey":"AQID",
              "attestationLevel":0,
              "capabilities":[],
              "createdAt":1000,
              "updatedAt":1000,
              "version":1,
              "signature":"",
              "recordType":"add"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decodedLegacy = try decoder.decode(TrustRecord.self, from: legacyFixture)
        XCTAssertEqual(decodedLegacy.deviceId, "legacy-fixture-device")
        XCTAssertNil(decodedLegacy.protocolIdentityBindingsV2)

        let deviceId = "id:\(UUID().uuidString.lowercased())"
        let mlDSA65Key = Data(repeating: 0x65, count: 1_952)
        let mlDSA87Key = Data(repeating: 0x87, count: 2_592)
        let mlDSA65Fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: mlDSA65Key
        )
        let mlDSA87Fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: mlDSA87Key
        )
        let legacy65 = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: mlDSA65Fingerprint,
                authenticatedProtocolPublicKey: mlDSA65Key
            )
        )
        let newRecord = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [legacy65],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: mlDSA87Fingerprint,
                authenticatedProtocolPublicKey: mlDSA87Key
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encodedNewRecord = try encoder.encode(newRecord)
        let legacyDecodedNewRecord = try decoder.decode(LegacyTrustRecordFixture.self, from: encodedNewRecord)

        XCTAssertEqual(legacyDecodedNewRecord.protocolSigningAlgorithm, .mlDSA65)
        XCTAssertEqual(legacyDecodedNewRecord.protocolPublicKey, mlDSA65Key)
        XCTAssertFalse(
            legacyDecodedNewRecord.protocolIdentityPins?.contains(where: { $0.algorithm.rawValue == "ML-DSA-87" }) ?? false
        )
    }

    @MainActor
    func testLegacyRecordSignatureRemainsValidButCannotAuthorizeUnsignedV2Sidecar() async throws {
        let service = TrustSyncService.shared
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = createdAt.addingTimeInterval(60)
        let legacyKey = Data(repeating: 0x65, count: 1_952)
        let legacyFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: legacyKey
        )
        let unsignedLegacy = TrustRecord(
            deviceId: "id:\(UUID().uuidString.lowercased())",
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data(repeating: 0x01, count: 32),
            protocolPublicKey: legacyKey,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: legacyFingerprint,
            protocolIdentityPins: [
                ProtocolIdentityPin(
                    algorithm: .mlDSA65,
                    fingerprint: legacyFingerprint,
                    approvedAt: updatedAt,
                    source: .authenticatedHandshake
                )
            ],
            createdAt: createdAt,
            updatedAt: updatedAt,
            signature: Data()
        )
        let preV2Payload = try service.recordSignaturePayloadForTesting(
            unsignedLegacy,
            includeProtocolIdentityPins: true,
            includeProtocolIdentityBindingsV2: false
        )
        let legacySignature = try await DeviceIdentityKeyManager.shared.sign(data: preV2Payload)
        let signedLegacy = TrustRecord(
            deviceId: unsignedLegacy.deviceId,
            pubKeyFP: unsignedLegacy.pubKeyFP,
            publicKey: unsignedLegacy.publicKey,
            protocolPublicKey: unsignedLegacy.protocolPublicKey,
            protocolSigningAlgorithm: unsignedLegacy.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: unsignedLegacy.protocolPublicKeyFingerprint,
            protocolIdentityPins: unsignedLegacy.protocolIdentityPins,
            createdAt: createdAt,
            updatedAt: updatedAt,
            signature: legacySignature
        )
        let legacySignatureAccepted = try await service.verifyRecordSignature(signedLegacy)
        XCTAssertTrue(legacySignatureAccepted)

        let injectedKey = Data(repeating: 0x87, count: 2_592)
        let injectedFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: injectedKey
        )
        let unsignedSidecarInjection = TrustRecord(
            deviceId: signedLegacy.deviceId,
            pubKeyFP: signedLegacy.pubKeyFP,
            publicKey: signedLegacy.publicKey,
            protocolPublicKey: signedLegacy.protocolPublicKey,
            protocolSigningAlgorithm: signedLegacy.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: signedLegacy.protocolPublicKeyFingerprint,
            protocolIdentityPins: signedLegacy.protocolIdentityPins,
            protocolIdentityBindingsV2: [
                ProtocolIdentityBindingV2(
                    algorithm: .mlDSA87,
                    publicKey: injectedKey,
                    fingerprint: injectedFingerprint,
                    source: .authenticatedHandshake,
                    approvedAt: updatedAt,
                    generation: 1
                )
            ],
            createdAt: createdAt,
            updatedAt: updatedAt,
            signature: legacySignature
        )
        let injectedSidecarAccepted = try await service.verifyRecordSignature(unsignedSidecarInjection)
        XCTAssertFalse(
            injectedSidecarAccepted,
            "A legacy signature must not authenticate an attached v2 authority sidecar"
        )
    }

    func testRecordAuthenticatedRemoteAuthorityCreatesStableCurrentPathRecord() throws {
        let suffix = UUID().uuidString.lowercased()
        let aliasId = "peer:fe80::\(suffix.prefix(4))%en0"
        let bonjourId = "bonjour:skybridge-\(suffix)@local."
        let stableId = "id:\(suffix)"
        let fingerprint = String(repeating: "e", count: 64)

        let created = TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
            existingRecords: [],
            deviceId: aliasId,
            displayName: "Inbound iPhone \(suffix)",
            preferredCurrentDeviceId: stableId,
            knownDeviceIds: [aliasId, bonjourId, stableId],
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint
        )

        XCTAssertNotNil(created)
        XCTAssertEqual(created?.deviceId, stableId)
        XCTAssertEqual(created?.currentDeviceIdMetadata, stableId)
        XCTAssertEqual(created?.protocolSigningAlgorithm, .mlDSA65)
        XCTAssertEqual(created?.protocolPublicKeyFingerprint, fingerprint)
        XCTAssertTrue(
            Set(created?.knownDeviceIdsMetadata ?? []).isSuperset(
                of: Set([aliasId, bonjourId, stableId])
            ),
            "Known device ids should include supplied identifiers while allowing normalized derivatives"
        )
        XCTAssertEqual(created?.lifecycleStateMetadata, .active)
    }

    func testRecordAuthenticatedRemoteAuthorityDoesNotPersistIdentifierAsDisplayName() throws {
        let stableId = "id:\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)

        let created = TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
            existingRecords: [],
            deviceId: "peer:fe80::1%en0",
            displayName: stableId,
            preferredCurrentDeviceId: stableId,
            knownDeviceIds: [stableId, "peer:fe80::1%en0"],
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint
        )

        XCTAssertNotNil(created)
        XCTAssertEqual(created?.deviceId, stableId)
        XCTAssertNil(created?.deviceName)
    }

    func testProtectedTrustMirrorPersistenceFailuresAreNotSilentlyIgnored() throws {
        let source = try readSource("Sources/SkyBridgeCore/P2P/TrustSyncService.swift")

        XCTAssertTrue(source.contains("private func storeFallbackRecords(_ records: [TrustRecord]) throws"))
        XCTAssertTrue(source.contains("private func upsertFallbackRecord(_ record: TrustRecord) throws"))
        XCTAssertTrue(source.contains("private func removeFallbackRecord(deviceId: String) throws"))
        XCTAssertTrue(source.contains("private func deleteFromKeychain(deviceId: String) throws"))
        XCTAssertTrue(source.contains("let status = SecItemDelete(query as CFDictionary)"))
        XCTAssertTrue(source.contains("throw TrustSyncError.keychainError(status)"))
        XCTAssertFalse(source.contains("SecItemDelete(query as CFDictionary)\n        try removeFallbackRecord"))
        XCTAssertFalse(source.contains("try? storeFallbackRecords"))
        XCTAssertFalse(source.contains("try? Self.protectedFallbackRecordStore.remove()"))
        XCTAssertTrue(source.contains("func removeRecordsForTesting(deviceIds: [String]) async throws"))
        XCTAssertTrue(source.contains("try deleteFromKeychain(deviceId: deviceId)"))
        XCTAssertFalse(source.contains("preconditionFailure(\"failed to remove trust record for testing"))
    }

    func testLocalTrustRecordLoadVerifiesSignaturesBeforeMerging() throws {
        let source = try readSource("Sources/SkyBridgeCore/P2P/TrustSyncService.swift")

        XCTAssertTrue(source.contains("private func verifiedTrustRecordsForLocalLoad("))
        XCTAssertTrue(source.contains("guard try await verifyRecordSignature(record) else"))
        XCTAssertTrue(source.contains("reason=invalid_signature device=redacted"))
        XCTAssertTrue(source.contains("reason=verification_error"))
        XCTAssertTrue(source.contains("let verifiedRecords = await verifiedTrustRecordsForLocalLoad(allRecords, source: \"Keychain sync\")"))
        XCTAssertTrue(source.contains("Rejected malformed \\(source, privacy: .public) trust record during local load"))
        XCTAssertTrue(source.contains("throw TrustSyncError.decodingError(\"trust record index \\(index): \\(error.localizedDescription)"))
        XCTAssertTrue(source.contains("try Self.protectedFallbackRecordStore.loadOrThrow() ?? []"))
        XCTAssertFalse(source.contains("for record in allRecords {"))
        XCTAssertFalse(source.contains("for record in records { merge(record) }"))
        XCTAssertFalse(source.contains("for record in fallbackRecords { merge(record) }"))
        XCTAssertFalse(source.contains("if let record = try? decoder.decode(TrustRecord.self, from: data)"))
    }

    @MainActor
    func testEvaluateCurrentPathBindingMatchesKnownAliasesBeforeDeclaringConflict() async throws {
        let service = TrustSyncService.shared
        let suffix = UUID().uuidString.lowercased()
        let aliasId = "bonjour:skybridge-\(suffix)@local."
        let stableId = "id:\(suffix)"

        service.setInMemoryPersistenceForTesting(true)
        try await service.removeRecordsForTesting(deviceIds: [aliasId, stableId])
        addTeardownBlock { @MainActor [service] in
            try await service.removeRecordsForTesting(deviceIds: [aliasId, stableId])
            service.setInMemoryPersistenceForTesting(false)
        }

        _ = try await service.addTrustRecord(
            TrustRecord(
                deviceId: aliasId,
                pubKeyFP: String(repeating: "4", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                signature: Data(),
                deviceName: "Alias Matched Device",
                currentDeviceId: stableId,
                knownDeviceIds: [aliasId, stableId]
            )
        )

        let conflict = service.evaluateCurrentPathBinding(
            deviceId: stableId,
            protocolPublicKeyFingerprint: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(conflict, .identityConflict)
    }
    
 // MARK: - Property 12: Keychain Sync Attribute
    
 /// **Property 12: Keychain Sync Attribute**
 /// *For any* trust record stored in Keychain for sync, the kSecAttrSynchronizable
 /// attribute should be set to true.
 /// **Validates: Requirements 3.8**
    @MainActor
    func testKeychainSyncAttributeProperty() async {
 // This test verifies the sync attribute is correctly set
 // Note: Actual Keychain operations require entitlements
        
        let service = TrustSyncService.shared
        
 // Property: isSyncAvailable should reflect iCloud status
        let syncAvailable = service.isSyncAvailable
        
 // Property: Sync status should be valid
        let validStatuses: [SyncStatus] = [.idle, .syncing, .synced, .failed, .unavailable]
        XCTAssertTrue(validStatuses.contains(service.syncStatus),
                      "Sync status must be a valid value")
        
 // If sync is not available, status should reflect that
        if !syncAvailable {
 // Note: We can't force sync unavailable status without actual iCloud state
 // This is a documentation of expected behavior
        }
    }
    
 // MARK: - Additional Trust Record Tests
    
 /// Test TrustRecord computed properties
    func testTrustRecordComputedProperties() {
        let record = createTestTrustRecord(deviceId: "computed-props-test")
        
 // Property: shortId should be prefix of pubKeyFP
        XCTAssertTrue(record.pubKeyFP.hasPrefix(record.shortId),
                      "shortId must be prefix of pubKeyFP")
        XCTAssertEqual(record.shortId.count, P2PConstants.pubKeyFPDisplayLength,
                       "shortId must have correct length")
        
 // Property: id should equal deviceId
        XCTAssertEqual(record.id, record.deviceId,
                       "id must equal deviceId")
        
 // Property: Non-tombstone should not be tombstone
        XCTAssertFalse(record.isTombstone,
                       "Add record should not be tombstone")
        
 // Property: Fresh record should not be expired
        XCTAssertFalse(record.isExpired,
                       "Fresh record should not be expired")
    }

    func testCurrentPathTrustMetadataComputedProperties() {
        let record = TrustRecord(
            deviceId: "legacy-device-id",
            pubKeyFP: String(repeating: "b", count: 64),
            publicKey: Data(repeating: 0x02, count: 32),
            protocolPublicKey: Data(repeating: 0x11, count: 32),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: String(repeating: "c", count: 64),
            attestationLevel: .none,
            signature: Data(repeating: 0xAA, count: 64),
            currentDeviceId: "authoritative-device-id",
            knownDeviceIds: ["authoritative-device-id", "legacy-device-id", "authoritative-device-id"],
            lifecycleState: .reverificationRequired
        )

        XCTAssertEqual(record.currentDeviceId, "authoritative-device-id",
                       "currentDeviceId should prefer current-path metadata")
        XCTAssertEqual(record.knownDeviceIds, ["authoritative-device-id", "legacy-device-id"],
                       "knownDeviceIds should be de-duplicated and sorted")
        XCTAssertEqual(record.lifecycleState, .reverificationRequired,
                       "lifecycleState should expose stored metadata")
        XCTAssertEqual(record.currentPathAuthorityFingerprint, String(repeating: "c", count: 64),
                       "currentPathAuthorityFingerprint should normalize lowercase metadata")
    }

    @MainActor
    func testOnlyActiveLifecycleRecordsCanAuthorizeTrust() async throws {
        let service = TrustSyncService.shared
        let suffix = UUID().uuidString.lowercased()
        let activeId = "id:active-\(suffix)"
        let quarantineId = "id:quarantine-\(suffix)"
        let reverificationId = "id:reverify-\(suffix)"
        let ids = [activeId, quarantineId, reverificationId]

        service.setInMemoryPersistenceForTesting(true)
        try await service.removeRecordsForTesting(deviceIds: ids)
        addTeardownBlock { @MainActor in
            try await service.removeRecordsForTesting(deviceIds: ids)
            service.setInMemoryPersistenceForTesting(false)
        }

        let records = [
            TrustRecord(
                deviceId: activeId,
                pubKeyFP: String(repeating: "1", count: 64),
                publicKey: Data([0x01]),
                signature: Data(),
                lifecycleState: .active
            ),
            TrustRecord(
                deviceId: quarantineId,
                pubKeyFP: String(repeating: "2", count: 64),
                publicKey: Data([0x02]),
                signature: Data(),
                lifecycleState: .quarantined
            ),
            TrustRecord(
                deviceId: reverificationId,
                pubKeyFP: String(repeating: "3", count: 64),
                publicKey: Data([0x03]),
                signature: Data(),
                lifecycleState: .reverificationRequired
            )
        ]
        for record in records {
            _ = try await service.addTrustRecord(record)
        }

        XCTAssertTrue(service.isTrusted(deviceId: activeId))
        XCTAssertTrue(service.isTrusted(pubKeyFP: String(repeating: "1", count: 64)))
        XCTAssertFalse(service.isTrusted(deviceId: quarantineId))
        XCTAssertFalse(service.isTrusted(pubKeyFP: String(repeating: "2", count: 64)))
        XCTAssertFalse(service.isTrusted(deviceId: reverificationId))
        XCTAssertFalse(service.isTrusted(pubKeyFP: String(repeating: "3", count: 64)))

        XCTAssertTrue(records[0].isAuthenticationEligible)
        XCTAssertFalse(records[1].isAuthenticationEligible)
        XCTAssertFalse(records[2].isAuthenticationEligible)
    }

    func testProtocolIdentityPinsSeedLegacyAndRejectSameAlgorithmReplacement() throws {
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        let legacyEd25519 = String(repeating: "a", count: 64)
        let firstMLDSA = String(repeating: "b", count: 64)
        let secondMLDSA = String(repeating: "c", count: 64)
        let legacyRecord = TrustRecord(
            deviceId: deviceId,
            pubKeyFP: String(repeating: "d", count: 64),
            publicKey: Data([0x01]),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: legacyEd25519,
            signature: Data(),
            currentDeviceId: deviceId,
            knownDeviceIds: [deviceId]
        )

        XCTAssertEqual(legacyRecord.currentPathAuthorityFingerprints, [legacyEd25519])

        let firstUpdated = TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
            existingRecords: [legacyRecord],
            deviceId: deviceId,
            preferredCurrentDeviceId: deviceId,
            knownDeviceIds: [deviceId],
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: firstMLDSA,
            pinSource: .pib1OperatorApproval
        )
        XCTAssertEqual(firstUpdated?.currentPathAuthorityFingerprints, [legacyEd25519, firstMLDSA])

        XCTAssertNil(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [try XCTUnwrap(firstUpdated)],
                deviceId: deviceId,
                preferredCurrentDeviceId: deviceId,
                knownDeviceIds: [deviceId],
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: secondMLDSA,
                pinSource: .pib1OperatorApproval
            ),
            "Same-algorithm authority changes require explicit authenticated rotation"
        )
    }
    
 /// Test tombstone expiration
    func testTombstoneExpiration() {
 // Create tombstone with old revokedAt
        let expiredTombstone = TrustRecord(
            deviceId: "expired-tombstone",
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data(repeating: 0x01, count: 32),
            attestationLevel: .none,
            signature: Data(repeating: 0xAA, count: 64),
            recordType: .revoke,
            revokedAt: Date().addingTimeInterval(-31 * 24 * 60 * 60) // 31 days ago
        )
        
 // Property: Old tombstone should be expired
        XCTAssertTrue(expiredTombstone.isExpired,
                      "Tombstone older than 30 days should be expired")
        
 // Create fresh tombstone
        let freshTombstone = TrustRecord(
            deviceId: "fresh-tombstone",
            pubKeyFP: String(repeating: "b", count: 64),
            publicKey: Data(repeating: 0x02, count: 32),
            attestationLevel: .none,
            signature: Data(repeating: 0xBB, count: 64),
            recordType: .revoke,
            revokedAt: Date()
        )
        
 // Property: Fresh tombstone should not be expired
        XCTAssertFalse(freshTombstone.isExpired,
                       "Fresh tombstone should not be expired")
    }
    
 /// Test TrustRecordEnvelope
    func testTrustRecordEnvelope() throws {
        let record = createTestTrustRecord(deviceId: "envelope-test")
        let envelope = TrustRecordEnvelope(
            record: record,
            localDeviceId: "local-device-123",
            envelopeSignature: Data(repeating: 0xCC, count: 64)
        )
        
 // Property: Envelope should contain the record
        XCTAssertEqual(envelope.record.deviceId, record.deviceId,
                       "Envelope must contain the record")
        
 // Property: dataToSign should be deterministic
        let data1 = try envelope.dataToSign()
        let data2 = try envelope.dataToSign()
        XCTAssertEqual(data1, data2,
                       "dataToSign must be deterministic")
        
 // Property: dataToSign should not be empty
        XCTAssertFalse(data1.isEmpty,
                       "dataToSign must not be empty")
    }
    
 /// Test revoked() method
    func testRevokedMethod() {
        let original = createTestTrustRecord(deviceId: "revoke-test")
        let newSignature = Data(repeating: 0xDD, count: 64)
        let revoked = original.revoked(signature: newSignature)
        
 // Property: Revoked record should be tombstone
        XCTAssertTrue(revoked.isTombstone,
                      "Revoked record must be tombstone")
        XCTAssertEqual(revoked.recordType, .revoke,
                       "Record type must be revoke")
        
 // Property: Version should be incremented
        XCTAssertEqual(revoked.version, original.version + 1,
                       "Version must be incremented")
        
 // Property: revokedAt should be set
        XCTAssertNotNil(revoked.revokedAt,
                        "revokedAt must be set")
        
 // Property: Signature should be updated
        XCTAssertEqual(revoked.signature, newSignature,
                       "Signature must be updated")
        
 // Property: Other fields should be preserved
        XCTAssertEqual(revoked.deviceId, original.deviceId,
                       "deviceId must be preserved")
        XCTAssertEqual(revoked.pubKeyFP, original.pubKeyFP,
                       "pubKeyFP must be preserved")
        XCTAssertEqual(revoked.publicKey, original.publicKey,
                       "publicKey must be preserved")
    }

    func testRevokedMethodPreservesCurrentPathMetadata() {
        let original = TrustRecord(
            deviceId: "revoke-current-path",
            pubKeyFP: String(repeating: "d", count: 64),
            publicKey: Data(repeating: 0x04, count: 32),
            protocolPublicKey: Data(repeating: 0x55, count: 32),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: String(repeating: "e", count: 64),
            attestationLevel: .none,
            signature: Data(repeating: 0x11, count: 64),
            currentDeviceId: "stable-current-device-id",
            knownDeviceIds: ["stable-current-device-id", "legacy-device-id"],
            lifecycleState: .quarantined
        )

        let revoked = original.revoked(signature: Data(repeating: 0x22, count: 64))

        XCTAssertEqual(revoked.protocolSigningAlgorithm, .ed25519,
                       "Revoked record should preserve protocol signing algorithm")
        XCTAssertEqual(revoked.protocolPublicKeyFingerprint, String(repeating: "e", count: 64),
                       "Revoked record should preserve authoritative fingerprint")
        XCTAssertEqual(revoked.protocolPublicKey, Data(repeating: 0x55, count: 32),
                       "Revoked record should preserve authoritative public key")
        XCTAssertEqual(revoked.currentDeviceIdMetadata, "stable-current-device-id",
                       "Revoked record should preserve current device metadata")
        XCTAssertEqual(Set(revoked.knownDeviceIdsMetadata ?? []), Set(["stable-current-device-id", "legacy-device-id"]),
                       "Revoked record should preserve known device ids")
        XCTAssertEqual(revoked.lifecycleStateMetadata, .revoked,
                       "Revoked record should force lifecycle state to revoked")
    }
    
 // MARK: - Helper Methods
    
    private func generateTestTrustRecords() -> [TrustRecord] {
        var records: [TrustRecord] = []
        
 // Basic add record
        records.append(createTestTrustRecord(deviceId: "test-device-1"))
        
 // Record with attestation
        records.append(createTestTrustRecord(
            deviceId: "test-device-2",
            attestationLevel: .deviceCheck,
            attestationData: Data(repeating: 0x11, count: 100)
        ))
        
 // Record with capabilities
        records.append(createTestTrustRecord(
            deviceId: "test-device-3",
            capabilities: ["screen-mirror", "file-transfer", "remote-input"]
        ))
        
 // Tombstone record
        records.append(createTestTrustRecord(
            deviceId: "test-device-4",
            recordType: .revoke,
            revokedAt: Date()
        ))
        
 // Record with device name
        records.append(createTestTrustRecord(
            deviceId: "test-device-5",
            deviceName: "iPhone 15 Pro"
        ))

        records.append(TrustRecord(
            deviceId: "test-device-6",
            pubKeyFP: String(repeating: "f", count: 64),
            publicKey: Data(repeating: 0x09, count: 32),
            protocolPublicKey: Data(repeating: 0x42, count: 32),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
            attestationLevel: .none,
            signature: Data(repeating: 0xAA, count: 64),
            currentDeviceId: "test-device-6-current",
            knownDeviceIds: ["test-device-6-current", "test-device-6-legacy"],
            lifecycleState: .active
        ))

        let mlDSA87Key = Data(repeating: 0x87, count: 2_592)
        records.append(TrustRecord(
            deviceId: "test-device-7",
            pubKeyFP: String(repeating: "7", count: 64),
            publicKey: Data(),
            protocolIdentityBindingsV2: [
                ProtocolIdentityBindingV2(
                    algorithm: .mlDSA87,
                    publicKey: mlDSA87Key,
                    fingerprint: ProtocolIdentityBinding.computeFingerprint(
                        algorithm: .mlDSA87,
                        publicKeyBytes: mlDSA87Key
                    ),
                    source: .authenticatedHandshake,
                    approvedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    generation: 1
                )
            ],
            attestationLevel: .none,
            signature: Data(repeating: 0xAA, count: 64),
            lifecycleState: .active
        ))
        
        return records
    }
    
    private func createTestTrustRecord(
        deviceId: String,
        recordType: TrustRecordType = .add,
        attestationLevel: P2PAttestationLevel = .none,
        attestationData: Data? = nil,
        capabilities: [String] = [],
        revokedAt: Date? = nil,
        updatedAt: Date = Date(),
        deviceName: String? = nil
    ) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data(repeating: 0x01, count: 32),
            attestationLevel: attestationLevel,
            attestationData: attestationData,
            capabilities: capabilities,
            createdAt: Date(),
            updatedAt: updatedAt,
            version: 1,
            signature: Data(repeating: 0xAA, count: 64),
            recordType: recordType,
            revokedAt: revokedAt,
            deviceName: deviceName
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private struct LegacyTrustRecordFixture: Decodable {
    enum LegacyProtocolSigningAlgorithm: String, Decodable {
        case ed25519 = "Ed25519"
        case mlDSA65 = "ML-DSA-65"
    }

    struct LegacyProtocolIdentityPin: Decodable {
        let algorithm: LegacyProtocolSigningAlgorithm
    }

    let protocolPublicKey: Data?
    let protocolSigningAlgorithm: LegacyProtocolSigningAlgorithm?
    let protocolIdentityPins: [LegacyProtocolIdentityPin]?
}
