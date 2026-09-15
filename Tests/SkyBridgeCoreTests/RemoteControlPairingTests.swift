import CryptoKit
import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class RemoteControlPairingTests: XCTestCase {
    private func material(deviceId: String = "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", keyByte: UInt8 = 0) throws -> RemoteControlPairingMaterial {
        try RemoteControlPairingMaterial(deviceId: deviceId, name: "Windows host",
            protocolPublicKey: Data(repeating: keyByte, count: 1_952), kemPublicKey: Data(repeating: 7, count: 1_184))
    }

    func testPublicMaterialRoundTripPreservesCanonicalAuthority() throws {
        let input = try material(deviceId: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        let decoded = try RemoteControlPairingMaterial.decode(input.encoded())
        XCTAssertEqual(decoded, input)
        XCTAssertEqual(decoded.deviceId, "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: input.encoded()) as? [String: Any])
        XCTAssertEqual(object["protocolSigningAlgorithm"] as? String, "ML-DSA-65")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "deviceId", "name", "protocolSigningAlgorithm",
            "protocolPublicKey", "protocolPublicKeyFingerprint", "kemPublicKeys"])
        XCTAssertFalse(String(decoding: try input.encoded(), as: UTF8.self).contains("private"))
    }

    func testPolicyBoundPublicMaterialRoundTripPreservesBothSuites() throws {
        let legacy = try material()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any])
        let qKey = Data(repeating: 0x42, count: 1_216)
        object["kemPublicKeys"] = [
            ["suiteWireId": 18, "publicKey": qKey.base64EncodedString()],
            ["suiteWireId": 257, "publicKey": legacy.kemPublicKey.base64EncodedString()]
        ]
        let decoded = try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded.encoded()) as? [String: Any])
        let keys = try XCTUnwrap(exported["kemPublicKeys"] as? [[String: Any]])
        XCTAssertEqual(Set(keys.compactMap { $0["suiteWireId"] as? Int }), [18, 257])
        XCTAssertEqual(decoded.protocolPublicKeyFingerprint, legacy.protocolPublicKeyFingerprint)
        XCTAssertEqual(try RemoteControlPairingMaterial.decode(decoded.encoded()), decoded)
    }

    func testPolicyBoundOnlyPublicMaterialUsesTheSameWireContract() throws {
        let legacy = try material()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any])
        object["kemPublicKeys"] = [["suiteWireId": 18, "publicKey": Data(repeating: 0x42, count: 1_216).base64EncodedString()]]
        let decoded = try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object))
        let record = decoded.trustRecord(approvedAt: Date())
        XCTAssertEqual(record.kemPublicKeys?.map(\.suiteWireId), [18])
        XCTAssertEqual(try RemoteControlPairingMaterial.decode(decoded.encoded()), decoded)
    }

    func testExplicitQUpgradePreservesLegacyAuthorityAndRejectsReplacement() throws {
        let legacy = try material()
        let record = legacy.trustRecord(approvedAt: Date(timeIntervalSince1970: 1_735_689_600))
        let q = try RemoteControlPairingMaterial(deviceId: legacy.deviceId, name: legacy.name,
            protocolPublicKey: legacy.protocolPublicKey, kemPublicKey: legacy.kemPublicKey,
            qPeriaptPublicKey: Data(repeating: 0x42, count: 1_216))
        let upgraded = try XCTUnwrap(q.recordForImport(in: [record], approvedAt: Date()))
        XCTAssertEqual(upgraded.kemPublicKeys?.count, 2)
        XCTAssertEqual(upgraded.kemPublicKeys?.first { $0.suiteWireId == 257 }?.publicKey, legacy.kemPublicKey)
        XCTAssertEqual(upgraded.protocolIdentityBindingsV2, record.protocolIdentityBindingsV2)
        XCTAssertEqual(upgraded.protocolPublicKeyFingerprint, record.protocolPublicKeyFingerprint)
        XCTAssertEqual(upgraded.createdAt, record.createdAt)
        XCTAssertEqual(upgraded.knownDeviceIdsMetadata, record.knownDeviceIdsMetadata)
        XCTAssertEqual(upgraded.lifecycleStateMetadata, record.lifecycleStateMetadata)
        XCTAssertFalse(try q.requiresImport(in: [upgraded]))
        XCTAssertFalse(try legacy.requiresImport(in: [upgraded]), "Legacy reimport must not remove the Q key")
        let changed = try RemoteControlPairingMaterial(deviceId: legacy.deviceId, name: legacy.name,
            protocolPublicKey: legacy.protocolPublicKey, kemPublicKey: legacy.kemPublicKey,
            qPeriaptPublicKey: Data(repeating: 0x43, count: 1_216))
        XCTAssertThrowsError(try changed.requiresImport(in: [upgraded]))
        XCTAssertThrowsError(try q.requiresImport(in: [record.revoked(signature: Data())]))
    }

    func testQOnlyUpgradePreservesExistingLegacyKeyAndMetadata() throws {
        let legacy = try material()
        let original = legacy.trustRecord(approvedAt: Date())
        let record = TrustRecord(deviceId: original.deviceId, pubKeyFP: original.pubKeyFP, publicKey: original.publicKey,
            secureEnclavePublicKey: Data([0x31]), protocolPublicKey: original.protocolPublicKey,
            protocolSigningAlgorithm: original.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: original.protocolPublicKeyFingerprint,
            protocolIdentityBindingsV2: original.protocolIdentityBindingsV2,
            signatureAlgorithm: original.signatureAlgorithm, kemPublicKeys: original.kemPublicKeys,
            attestationData: Data([0x41]), capabilities: ["file_transfer"], createdAt: original.createdAt,
            version: 7, signature: Data(), deviceName: "Established name", currentDeviceId: original.currentDeviceId,
            knownDeviceIds: [original.currentDeviceId, "old-alias"], lifecycleState: .active)
        let q = try RemoteControlPairingMaterial(deviceId: legacy.deviceId, name: "Imported display name",
            protocolPublicKey: legacy.protocolPublicKey, kemPublicKey: Data(),
            qPeriaptPublicKey: Data(repeating: 0x42, count: 1_216))
        let upgraded = try XCTUnwrap(q.recordForImport(in: [record], approvedAt: Date()))
        XCTAssertEqual(upgraded.kemPublicKeys?.count, 2)
        XCTAssertEqual(upgraded.capabilities, record.capabilities)
        XCTAssertEqual(upgraded.attestationData, record.attestationData)
        XCTAssertEqual(upgraded.secureEnclavePublicKey, record.secureEnclavePublicKey)
        XCTAssertEqual(upgraded.deviceName, record.deviceName)
        XCTAssertEqual(upgraded.knownDeviceIdsMetadata, record.knownDeviceIdsMetadata)
    }

    func testMalformedAndDuplicatePolicyBoundKeySharesAreRejected() throws {
        let legacy = try material()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any])
        for length in [0, 1_215, 1_217] {
            object["kemPublicKeys"] = [["suiteWireId": 18, "publicKey": Data(repeating: 0x42, count: length).base64EncodedString()]]
            XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object)))
        }
        let key: [String: Any] = ["suiteWireId": 18, "publicKey": Data(repeating: 0x42, count: 1_216).base64EncodedString()]
        object["kemPublicKeys"] = [key, key]
        XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object)))
    }

    @MainActor
    func testConcurrentQUpgradesKeepOnlyTheFirstExplicitlyApprovedKey() async throws {
        let legacy = try material(deviceId: "id:" + UUID().uuidString.lowercased())
        let original = legacy.trustRecord(approvedAt: Date())
        let trust = TrustSyncService(initialRecordsForTesting: [original])
        let upgrades = try [UInt8(0x42), UInt8(0x43)].map { byte in
            try RemoteControlPairingMaterial(deviceId: legacy.deviceId, name: legacy.name,
                protocolPublicKey: legacy.protocolPublicKey, kemPublicKey: legacy.kemPublicKey,
                qPeriaptPublicKey: Data(repeating: byte, count: 1_216))
        }
        let tasks = upgrades.map { upgrade in Task { @MainActor in
            try await trust.addTrustRecordIfNeeded { try upgrade.recordForImport(in: $0, approvedAt: Date()) }
        } }
        var added = 0
        var conflicts = 0
        for task in tasks {
            do { if try await task.value { added += 1 } }
            catch RemoteControlPairingError.conflictingTrust { conflicts += 1 }
        }
        XCTAssertEqual(added, 1)
        XCTAssertEqual(conflicts, 1)
        let records = trust.activeTrustRecords.filter { $0.currentDeviceId == legacy.deviceId }
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.kemPublicKeys?.first { $0.suiteWireId == 257 }?.publicKey, legacy.kemPublicKey)
        let winner = try XCTUnwrap(record.kemPublicKeys?.first { $0.suiteWireId == 18 }?.publicKey)
        XCTAssertTrue(upgrades.map(\.qPeriaptPublicKey).contains(winner))
    }

    func testMalformedFingerprintAlgorithmAndSuiteAreRejected() throws {
        let source = try material()
        for (field, replacement) in [
            ("protocolPublicKeyFingerprint", String(repeating: "a", count: 64)),
            ("protocolSigningAlgorithm", "ML-DSA-87")
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source.encoded()) as? [String: Any])
            object[field] = replacement
            XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object)))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source.encoded()) as? [String: Any])
        object["kemPublicKeys"] = [["suiteWireId": 258, "publicKey": source.kemPublicKey.base64EncodedString()]]
        XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testDuplicateUnknownAndMissingFieldsAreRejected() throws {
        let source = try material()
        let encoded = String(decoding: try source.encoded(), as: UTF8.self)
        let duplicate = encoded.replacingOccurrences(of: "{", with: "{\"name\":\"duplicate\",", options: [], range: encoded.startIndex..<encoded.index(after: encoded.startIndex))
        XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(Data(duplicate.utf8)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source.encoded()) as? [String: Any])
        object["unknown"] = true
        XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "unknown")
        object.removeValue(forKey: "deviceId")
        XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object)))
        object["deviceId"] = source.deviceId
        object["kemPublicKeys"] = [["suiteWireId": 257, "publicKey": source.kemPublicKey.base64EncodedString(), "unknown": true]]
        XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testRouteNamesSizesAndControlCharactersCannotBecomeIdentityMaterial() throws {
        for deviceId in ["192.168.0.103", "host:windows-laptop", "bonjour:host", "peer@host"] {
            XCTAssertThrowsError(try material(deviceId: deviceId))
        }
        XCTAssertThrowsError(try RemoteControlPairingMaterial(deviceId: "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            name: "Host\nInjected", protocolPublicKey: Data(repeating: 0, count: 1_952), kemPublicKey: Data(repeating: 0, count: 1_184)))
        XCTAssertThrowsError(try RemoteControlPairingMaterial(deviceId: "id:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            name: "Host", protocolPublicKey: Data(repeating: 0, count: 32), kemPublicKey: Data(repeating: 0, count: 1_184)))
        XCTAssertThrowsError(try RemoteControlPairingMaterial.decode(Data(repeating: 0x20, count: 32_769)))
    }

    func testImportedRecordContainsExactRawAuthorityAndTrustedKEM() async throws {
        let source = try material()
        let record = source.trustRecord(approvedAt: Date())
        XCTAssertNil(record.protocolIdentityPins, "New import provenance belongs only in the forward-compatible v2 sidecar")
        XCTAssertEqual(record.protocolIdentityBindingsV2?.first?.source, "manual-pairing-import")
        XCTAssertEqual(record.authenticatedProtocolIdentityBinding(for: .mlDSA65)?.publicKey, source.protocolPublicKey)
        XCTAssertEqual(record.currentDeviceId, source.deviceId)
        let provider = DefaultHandshakeTrustProvider(trustRecordsSnapshot: [record])
        let pins = await provider.trustedFingerprints(for: source.deviceId)
        let keys = await provider.trustedKEMPublicKeys(for: source.deviceId)
        XCTAssertEqual(pins, [source.protocolPublicKeyFingerprint])
        XCTAssertEqual(keys[.mlkem768MLDSA65], source.kemPublicKey)
    }

    func testEquivalentTrustIsIdempotentAndConflictingTrustIsPreserved() throws {
        let source = try material()
        let record = source.trustRecord(approvedAt: Date())
        XCTAssertTrue(try source.requiresImport(in: []))
        XCTAssertFalse(try source.requiresImport(in: [record]))
        let conflict = try material(keyByte: 1)
        XCTAssertThrowsError(try conflict.requiresImport(in: [record])) { error in
            XCTAssertEqual(error as? RemoteControlPairingError, .conflictingTrust)
        }
        let alias = try material(deviceId: "id:cccccccc-cccc-cccc-cccc-cccccccccccc")
        XCTAssertThrowsError(try alias.requiresImport(in: [record]))
        let changedKem = try RemoteControlPairingMaterial(deviceId: source.deviceId, name: source.name,
            protocolPublicKey: source.protocolPublicKey, kemPublicKey: Data(repeating: 8, count: 1_184))
        XCTAssertThrowsError(try changedKem.requiresImport(in: [record]))
        XCTAssertThrowsError(try source.requiresImport(in: [record.revoked(signature: Data())])) { error in
            XCTAssertEqual(error as? RemoteControlPairingError, .inactiveTrust)
        }
    }

    func testExistingKEMPublicReadSelectsMLKEMWithinNativeTierWhenXWingIsPreferred() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("Apple PQC is unavailable on this OS")
        }
        let context = try DeviceIdentityKeychainTestContext()
        addTeardownBlock {
            try await context.manager.clearKEMIdentityRecordsForTesting()
            try context.reset()
        }
        let nativeMLKEM = try await context.manager.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65, provider: ApplePQCCryptoProvider()
        )
        nativeMLKEM.privateKey.zeroize()
        let nativeXWing = try await context.manager.getOrCreateKEMIdentityKey(
            for: .xwingMLDSA, provider: AppleXWingCryptoProvider()
        )
        nativeXWing.privateKey.zeroize()
        let committedMLKEM = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, tier: .nativePQC
        )
        let committedXWing = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.xwingMLDSA.wireId, tier: .nativePQC
        )
        XCTAssertFalse(AppleXWingCryptoProvider().supportsSuite(.mlkem768MLDSA65))

        let publicKey = try await context.manager.existingKEMPublicKey(
            for: .mlkem768MLDSA65, baseProvider: AppleXWingCryptoProvider()
        )

        XCTAssertEqual(publicKey, nativeMLKEM.publicKey)
        XCTAssertNotEqual(publicKey, nativeXWing.publicKey)
        let survivingMLKEM = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, tier: .nativePQC
        )
        let survivingXWing = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.xwingMLDSA.wireId, tier: .nativePQC
        )
        XCTAssertTrue(survivingMLKEM == committedMLKEM)
        XCTAssertTrue(survivingXWing == committedXWing)
        #else
        throw XCTSkip("Apple PQC SDK is unavailable in this build")
        #endif
    }

    func testExistingKEMPublicReadDoesNotProvisionOrUseAnotherProviderTier() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("Apple PQC is unavailable on this OS")
        }
        let context = try DeviceIdentityKeychainTestContext()
        addTeardownBlock {
            try await context.manager.clearKEMIdentityRecordsForTesting()
            try context.reset()
        }
        let liboqs = try await context.manager.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65, provider: OQSPQCProvider()
        )
        liboqs.privateKey.zeroize()
        let committedLiboqs = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, tier: .liboqsPQC
        )

        let publicKey = try await context.manager.existingKEMPublicKey(
            for: .mlkem768MLDSA65, baseProvider: AppleXWingCryptoProvider()
        )

        XCTAssertNil(publicKey)
        let nativeRecord = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, tier: .nativePQC
        )
        let survivingLiboqs = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, tier: .liboqsPQC
        )
        XCTAssertNil(nativeRecord)
        XCTAssertTrue(survivingLiboqs == committedLiboqs)
        #else
        throw XCTSkip("Apple PQC SDK is unavailable in this build")
        #endif
    }

    func testExistingKEMPublicReadPreservesUntieredIdentityAndReportsMigrationRequired() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("Apple PQC is unavailable on this OS")
        }
        let context = try DeviceIdentityKeychainTestContext()
        addTeardownBlock {
            try await context.manager.clearKEMIdentityRecordsForTesting()
            try context.reset()
        }
        let legacy = KEMIdentityKeyRecord(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
            publicKey: Data(repeating: 0x31, count: 1_184),
            privateKey: Data(repeating: 0x42, count: 96),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
        try await context.manager.seedUntieredKEMIdentityRecordForTesting(legacy)

        do {
            _ = try await context.manager.existingKEMPublicKey(
                for: .mlkem768MLDSA65, baseProvider: AppleXWingCryptoProvider()
            )
            XCTFail("Public pairing export must require explicit migration of untiered KEM identity")
        } catch DeviceIdentityKeyError.incompleteKeyMaterial(let reason) {
            XCTAssertTrue(reason.contains("Untiered KEM identity"))
        }

        let survivingLegacy = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, tier: nil
        )
        let nativeRecord = try await context.manager.storedKEMIdentityRecordForTesting(
            suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId, tier: .nativePQC
        )
        XCTAssertTrue(survivingLegacy == legacy)
        XCTAssertNil(nativeRecord)
        #else
        throw XCTSkip("Apple PQC SDK is unavailable in this build")
        #endif
    }

    @MainActor
    func testConcurrentConflictingImportsUseExistingTrustMutationGate() async throws {
        let trust = TrustSyncService(initialRecordsForTesting: [])
        let deviceId = "id:" + UUID().uuidString.lowercased()
        let first = try material(deviceId: deviceId)
        let second = try material(deviceId: deviceId, keyByte: 1)
        let firstTask = Task { @MainActor in
            try await trust.addTrustRecordIfNeeded { try first.recordForImport(in: $0, approvedAt: Date()) }
        }
        let secondTask = Task { @MainActor in
            try await trust.addTrustRecordIfNeeded { try second.recordForImport(in: $0, approvedAt: Date()) }
        }
        var added = 0
        var conflicts = 0
        for task in [firstTask, secondTask] {
            do { if try await task.value { added += 1 } }
            catch RemoteControlPairingError.conflictingTrust { conflicts += 1 }
        }
        XCTAssertEqual(added, 1)
        XCTAssertEqual(conflicts, 1)
        let records = trust.activeTrustRecords.filter { $0.currentDeviceId == deviceId }
        XCTAssertEqual(records.count, 1)
        let pin = try XCTUnwrap(records.first?.authenticatedProtocolIdentityBinding(for: .mlDSA65))
        XCTAssertTrue([first.protocolPublicKeyFingerprint, second.protocolPublicKeyFingerprint].contains(pin.fingerprint))
    }
}
