import XCTest
import CloudKit
@testable import SkyBridgeCompass_iOS

private actor CloudTrustSyncGate {
    private var invocations = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        invocations += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func invocationCount() -> Int {
        invocations
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor CloudTrustSyncAttemptScript {
    enum InjectedFailure: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "injected CloudKit failure"
        }
    }

    private var attempts = 0

    func run() throws {
        attempts += 1
        if attempts == 1 {
            throw InjectedFailure.unavailable
        }
    }
}

private actor CloudTrustSyncCounter {
    private var invocations = 0

    func run() {
        invocations += 1
    }

    func invocationCount() -> Int {
        invocations
    }
}

private enum SensitiveCloudSyncFailure: LocalizedError {
    case injected

    var errorDescription: String? {
        "record=id:must-not-appear-in-logs"
    }
}

@MainActor
final class CurrentPathTrustedDeviceStoreTests: XCTestCase {
    private enum InjectedPersistenceFailure: Error {
        case load
        case save
    }

    private func canonical(_ raw: String) -> String {
        PeerIdentityAliasResolver.persistentDeviceId(from: raw) ?? raw
    }

    private func protocolIdentityKey(
        _ algorithm: ProtocolSigningAlgorithm,
        seed: UInt8
    ) -> Data {
        let length: Int
        switch algorithm {
        case .ed25519: length = 32
        case .mlDSA65: length = 1_952
        case .mlDSA87: length = 2_592
        }
        return Data(repeating: seed, count: length)
    }

    private func protocolIdentityFingerprint(
        algorithm: ProtocolSigningAlgorithm,
        key: Data
    ) -> String {
        CurrentPathSecurityCompat.computeFingerprint(
            algorithm: algorithm,
            publicKeyBytes: key
        )
    }

    private func waitForCloudSyncInvocation(
        _ gate: CloudTrustSyncGate
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await gate.invocationCount() > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    override func setUp() async throws {
        try await super.setUp()
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([])
    }

    override func tearDown() async throws {
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([])
        try await super.tearDown()
    }

    func testCurrentPathBindingRejectsIdentityConflict() throws {
        let key = protocolIdentityKey(.ed25519, seed: 0xA1)
        let fingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: key)
        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-alpha-1234",
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: key
        )

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: "device-alpha-1234",
            protocolPublicKeyFingerprint: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(conflict, .identityConflict)
    }

    func testCurrentPathBindingAllowsSameAuthorityDeviceIdMigration() throws {
        let key = protocolIdentityKey(.ed25519, seed: 0xA2)
        let fingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: key)
        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-alpha-1234",
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: key
        )

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: "device-beta-5678",
            protocolPublicKeyFingerprint: fingerprint
        )

        XCTAssertNil(conflict)
    }

    func testUniqueCanonicalTrustedDeviceIdRejectsAmbiguousEndpointAlias() throws {
        let endpointAlias = "host:fe80::812:27b6:c448:dad0"
        try TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-a",
                name: "Peer A",
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: "id:peer-a",
                knownDeviceIds: [endpointAlias]
            ),
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-b",
                name: "Peer B",
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: "id:peer-b",
                knownDeviceIds: [endpointAlias]
            )
        ])

        XCTAssertNil(TrustedDeviceStore.shared.uniqueCanonicalTrustedDeviceId(for: endpointAlias))

        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([])
        try TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:peer-a",
                name: "Peer A",
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: "id:peer-a",
                knownDeviceIds: [endpointAlias]
            )
        ])

        XCTAssertEqual(
            TrustedDeviceStore.shared.uniqueCanonicalTrustedDeviceId(for: "host:fe80::812:27b6:c448:dad0%en0.56600"),
            "id:peer-a"
        )
    }

    func testAuthenticatedQRCodeRebindBlocksIdentityConflictHealing() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .identityConflict)
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .deviceIdMigrationRequired)
        )
    }

    func testAuthenticatedQRCodeRebindStillBlocksQuarantinedAndRevokedIdentities() {
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedQRRebind(for: .revokedIdentity)
        )
    }

    func testVerifiedQRCodeCanReactivateQuarantinedAuthorityForSameDeviceOnly() throws {
        let deviceId = "device-alpha-1234"
        let otherDeviceId = "device-beta-1234"
        let fingerprint = String(repeating: "a", count: 64)
        let otherFingerprint = String(repeating: "b", count: 64)
        let key = protocolIdentityKey(.ed25519, seed: 0xA3)
        let authenticatedFingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: key)
        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: authenticatedFingerprint,
            protocolPublicKeyBytes: key
        )
        XCTAssertTrue(TrustedDeviceStore.shared.markReverificationRequired(deviceId: deviceId))

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: authenticatedFingerprint
        )

        XCTAssertEqual(conflict, .quarantinedIdentity)
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .quarantinedIdentity,
                deviceId: deviceId,
                protocolPublicKeyFingerprint: authenticatedFingerprint
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .quarantinedIdentity,
                deviceId: deviceId,
                protocolPublicKeyFingerprint: otherFingerprint
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .quarantinedIdentity,
                deviceId: otherDeviceId,
                protocolPublicKeyFingerprint: otherFingerprint
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowVerifiedQRCodeRebind(
                for: .revokedIdentity,
                deviceId: deviceId,
                protocolPublicKeyFingerprint: fingerprint
            )
        )
    }

    func testAuthenticatedAuthorityRebindPolicyBlocksGenericIdentityConflictHealing() {
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedAuthorityRebind(for: .revokedIdentity)
        )
    }

    func testWebRTCAuthorityBindingUsesAuthenticatedPinAndExpectedStableIdentity() throws {
        let expectedFingerprint = String(repeating: "a", count: 64)
        let authenticatedPublicKey = protocolIdentityKey(.mlDSA65, seed: 0xB1)
        let authenticatedFingerprint = protocolIdentityFingerprint(
            algorithm: .mlDSA65,
            key: authenticatedPublicKey
        )
        let expected = CurrentPathRemoteAuthorityCompat(
            deviceId: "11111111-2222-4333-8444-555555555555",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: expectedFingerprint,
            protocolPublicKeyBytes: nil,
            deviceName: "Verified Mac"
        )
        let authenticated = AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolPublicKeyFingerprint: authenticatedFingerprint,
            protocolPublicKeyBytes: authenticatedPublicKey
        )

        let binding = try CrossNetworkWebRTCManager.authenticatedAuthorityBinding(
            expectedRemoteAuthority: expected,
            authenticatedRemoteAuthority: authenticated
        )

        XCTAssertEqual(binding.stableDeviceId, canonical(expected.deviceId))
        XCTAssertEqual(binding.deviceName, "Verified Mac")
        XCTAssertEqual(binding.protocolSigningAlgorithm, ProtocolSigningAlgorithm.mlDSA65.rawValue)
        XCTAssertEqual(binding.protocolPublicKeyFingerprint, authenticatedFingerprint)
        XCTAssertEqual(binding.protocolPublicKeyBytes, authenticatedPublicKey)
        XCTAssertNotEqual(binding.protocolPublicKeyFingerprint, expectedFingerprint)
    }

    func testWebRTCAuthorityBindingSelectsTheActuallyAuthenticatedPinFromMultiplePins() throws {
        let expected = CurrentPathRemoteAuthorityCompat(
            deviceId: "11111111-2222-4333-8444-555555555555",
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
            protocolPublicKeyBytes: nil,
            deviceName: nil
        )
        let authenticatedKeys = [
            protocolIdentityKey(.ed25519, seed: 0xB2),
            protocolIdentityKey(.ed25519, seed: 0xB3)
        ]
        let authenticatedPins = authenticatedKeys.map {
            protocolIdentityFingerprint(algorithm: .ed25519, key: $0)
        }

        let bindings = try zip(authenticatedPins, authenticatedKeys).map { pair in
            let (fingerprint, key) = pair
            return try CrossNetworkWebRTCManager.authenticatedAuthorityBinding(
                expectedRemoteAuthority: expected,
                authenticatedRemoteAuthority: AuthenticatedRemoteAuthority(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    protocolPublicKeyFingerprint: fingerprint,
                    protocolPublicKeyBytes: key
                )
            )
        }

        XCTAssertEqual(Set(bindings.map(\.protocolPublicKeyFingerprint)), Set(authenticatedPins))
        XCTAssertTrue(bindings.allSatisfy { $0.stableDeviceId == canonical(expected.deviceId) })
    }

    func testAuthenticatedConnectionCodeRebindOnlyAllowsSameDeviceIdentityConflictHealing() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .revokedIdentity)
        )
    }

    func testCurrentPathTrustLookupUsesFingerprintAuthority() throws {
        let key = protocolIdentityKey(.ed25519, seed: 0xC1)
        let fingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: key)
        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-alpha-1234",
            name: "Alpha",
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: key
        )

        let trusted = TrustedDeviceStore.shared.currentPathTrustRecord(
            fingerprint: fingerprint
        )

        XCTAssertEqual(trusted?.currentDeviceId, canonical("device-alpha-1234"))
        XCTAssertEqual(trusted?.protocolPublicKeyFingerprint, fingerprint)
    }

    func testNewerDuplicateRevocationSuppressesOlderActiveAuthority() throws {
        let stableDeviceId = "id:duplicate-authority"
        let fingerprint = String(repeating: "c", count: 64)
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([
            TrustedDeviceStore.TrustedDevice(
                id: "id:legacy-duplicate-authority",
                name: "Legacy active row",
                platform: .macOS,
                ipAddress: "192.0.2.10",
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: fingerprint,
                currentDeviceId: stableDeviceId,
                knownDeviceIds: [stableDeviceId],
                currentPathLifecycleState: .active,
                currentPathLifecycleGeneration: 0
            ),
            TrustedDeviceStore.TrustedDevice(
                id: stableDeviceId,
                name: "Revoked authority",
                platform: .macOS,
                ipAddress: nil,
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: fingerprint,
                currentDeviceId: stableDeviceId,
                knownDeviceIds: [stableDeviceId],
                currentPathLifecycleState: .revoked,
                currentPathLifecycleGeneration: 1
            )
        ])

        XCTAssertFalse(
            TrustedDeviceStore.shared.hasActiveDurableTrust(forAny: [stableDeviceId])
        )
        XCTAssertFalse(TrustedDeviceStore.shared.isTrusted(deviceId: stableDeviceId))
        XCTAssertNil(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: stableDeviceId))
        XCTAssertNil(
            TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: fingerprint)
        )
        XCTAssertTrue(
            TrustedDeviceStore.shared.currentPathFingerprints(forAny: [stableDeviceId]).isEmpty
        )
    }

    func testCloudTrustDecoderRejectsMalformedLifecycleAuthority() throws {
        let invalidStateRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: "id:invalid-state")
        )
        invalidStateRecord["deviceId"] = "id:invalid-state"
        invalidStateRecord["lifecycleState"] = "revokd"

        XCTAssertThrowsError(
            try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(
                record: invalidStateRecord
            )
        )

        let fractionalGenerationRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: "id:fractional-generation")
        )
        fractionalGenerationRecord["deviceId"] = "id:fractional-generation"
        fractionalGenerationRecord["lifecycleState"] = "active"
        fractionalGenerationRecord["lifecycleGeneration"] = NSNumber(value: 1.5)

        XCTAssertThrowsError(
            try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(
                record: fractionalGenerationRecord
            )
        )

        let generationWithoutStateRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: "id:generation-without-state")
        )
        generationWithoutStateRecord["deviceId"] = "id:generation-without-state"
        generationWithoutStateRecord["lifecycleGeneration"] = NSNumber(value: 1)

        XCTAssertThrowsError(
            try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(
                record: generationWithoutStateRecord
            )
        )

        let excessiveAliasesRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: "id:excessive-aliases")
        )
        excessiveAliasesRecord["deviceId"] = "id:excessive-aliases"
        excessiveAliasesRecord["knownDeviceIds"] = (0..<65).map { "id:alias-\($0)" }

        XCTAssertThrowsError(
            try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(
                record: excessiveAliasesRecord
            )
        )
    }

    func testCloudFetchDecoderRejectsPayloadIdentityMismatchBeforeMerge() async throws {
        let stableID = "id:cloud-fetch-binding"
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: stableID,
            name: "Local active authority",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableID,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 4
        )
        var persisted = [localActive]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        let recordID = CKRecord.ID(recordName: stableID)
        let mismatchedRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: recordID
        )
        mismatchedRecord["deviceId"] = "id:different-cloud-authority"
        mismatchedRecord["lifecycleState"] =
            TrustedDeviceStore.CurrentPathLifecycleState.active.rawValue
        mismatchedRecord["lifecycleGeneration"] = NSNumber(value: 99)

        do {
            _ = try await CloudKitSyncManager.instance.decodeTrustedDevicePageForTesting(
                records: [mismatchedRecord],
                trustedDeviceStore: store
            )
            XCTFail("A mismatched fetch record must fail before merge")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("deviceId 与 recordName 不一致"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        let quarantined = try XCTUnwrap(store.trustedDevices.first)
        XCTAssertEqual(quarantined.currentPathLifecycleState, .quarantined)
        XCTAssertEqual(quarantined.currentPathLifecycleGeneration, 5)
        XCTAssertEqual(persisted, [quarantined])
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [stableID]))
    }

    func testIncompleteCloudFetchCommitsRevocationAndQuarantinesMalformedBoundRecord() async throws {
        let revokedID = "id:cloud-fetch-observed-revocation"
        let malformedID = "id:cloud-fetch-malformed-authority"
        let localRevocationTarget = TrustedDeviceStore.TrustedDevice(
            id: revokedID,
            name: "Revocation target",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: revokedID,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        let localMalformedTarget = TrustedDeviceStore.TrustedDevice(
            id: malformedID,
            name: "Malformed target",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: malformedID,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        var persisted = [localRevocationTarget, localMalformedTarget]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        let revokedRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: revokedID)
        )
        revokedRecord["deviceId"] = revokedID
        revokedRecord["lifecycleState"] =
            TrustedDeviceStore.CurrentPathLifecycleState.revoked.rawValue
        revokedRecord["lifecycleGeneration"] = NSNumber(value: 1)

        let malformedRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: malformedID)
        )
        malformedRecord["deviceId"] = malformedID
        malformedRecord["lifecycleState"] = "revokd"

        do {
            _ = try await CloudKitSyncManager.instance.decodeTrustedDevicePageForTesting(
                records: [revokedRecord, malformedRecord],
                trustedDeviceStore: store
            )
            XCTFail("An incomplete fetch page must remain observable")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("读取不完整"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        let revoked = try XCTUnwrap(store.trustedDevices.first { $0.id == revokedID })
        let quarantined = try XCTUnwrap(store.trustedDevices.first { $0.id == malformedID })
        XCTAssertEqual(revoked.currentPathLifecycleState, .revoked)
        XCTAssertEqual(revoked.currentPathLifecycleGeneration, 1)
        XCTAssertEqual(quarantined.currentPathLifecycleState, .quarantined)
        XCTAssertEqual(quarantined.currentPathLifecycleGeneration, 1)
        XCTAssertEqual(persisted, store.trustedDevices)
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [revokedID, malformedID]))
    }

    func testCloudFetchBindsResultKeyRecordIdentityTypeAndFailureAuthority() async throws {
        let keyMismatchID = "id:cloud-fetch-key-mismatch"
        let typeMismatchID = "id:cloud-fetch-type-mismatch"
        let failedResultID = "id:cloud-fetch-failed-result"
        let localDevices = [keyMismatchID, typeMismatchID, failedResultID].map { stableID in
            TrustedDeviceStore.TrustedDevice(
                id: stableID,
                name: stableID,
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: stableID,
                currentPathLifecycleState: .active,
                currentPathLifecycleGeneration: 0
            )
        }
        var persisted = localDevices
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        let keyMismatchRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: typeMismatchID)
        )
        keyMismatchRecord["deviceId"] = typeMismatchID
        let typeMismatchRecord = CKRecord(
            recordType: "UnexpectedRecordType",
            recordID: CKRecord.ID(recordName: typeMismatchID)
        )
        typeMismatchRecord["deviceId"] = typeMismatchID
        let matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)] = [
            (
                CKRecord.ID(recordName: keyMismatchID),
                .success(keyMismatchRecord)
            ),
            (
                CKRecord.ID(recordName: typeMismatchID),
                .success(typeMismatchRecord)
            ),
            (
                CKRecord.ID(recordName: failedResultID),
                .failure(InjectedPersistenceFailure.load)
            ),
        ]

        do {
            _ = try await CloudKitSyncManager.instance.decodeTrustedDeviceFetchResultsForTesting(
                matchResults: matchResults,
                trustedDeviceStore: store
            )
            XCTFail("Every failed or mismatched result binding must fail the fetch")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("读取不完整"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        XCTAssertEqual(persisted, store.trustedDevices)
        XCTAssertTrue(
            store.trustedDevices.allSatisfy {
                $0.currentPathLifecycleState == .quarantined
                    && $0.currentPathLifecycleGeneration == 1
            }
        )
        XCTAssertFalse(
            store.hasActiveDurableTrust(
                forAny: [keyMismatchID, typeMismatchID, failedResultID]
            )
        )
    }

    func testUnboundCloudFetchFailureKeyQuarantinesCurrentLocalBatch() async throws {
        let firstID = "id:cloud-fetch-ambiguous-first"
        let secondID = "id:cloud-fetch-ambiguous-second"
        let localDevices = [firstID, secondID].map { stableID in
            TrustedDeviceStore.TrustedDevice(
                id: stableID,
                name: stableID,
                platform: .macOS,
                ipAddress: nil,
                currentDeviceId: stableID,
                currentPathLifecycleState: .active,
                currentPathLifecycleGeneration: 3
            )
        }
        var persisted = localDevices
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        let unboundRecordID = CKRecord.ID(recordName: " id:uncanonical-cloud-record ")
        let failedResult: Result<CKRecord, any Error> = .failure(
            InjectedPersistenceFailure.load
        )

        do {
            _ = try await CloudKitSyncManager.instance.decodeTrustedDeviceFetchResultsForTesting(
                matchResults: [(unboundRecordID, failedResult)],
                trustedDeviceStore: store
            )
            XCTFail("An unbound failed-result key must fail the fetch")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("读取不完整"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        XCTAssertEqual(persisted, store.trustedDevices)
        XCTAssertTrue(
            store.trustedDevices.allSatisfy {
                $0.currentPathLifecycleState == .quarantined
            }
        )
        XCTAssertTrue(
            store.trustedDevices.allSatisfy { $0.currentPathLifecycleGeneration == 4 }
        )
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [firstID, secondID]))
    }

    func testCloudTrustDecoderUsesRecordNameForLegacyMissingPayloadIdentity() throws {
        let stableID = "id:legacy-record-name-authority"
        let legacyRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: stableID)
        )

        let decoded = try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(
            record: legacyRecord
        )

        XCTAssertEqual(decoded.id, stableID)
    }

    func testCloudTrustDecoderNormalizesPayloadIdentityBeforeBinding() throws {
        let stableID = "id:normalized-cloud-authority"
        let record = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: stableID)
        )
        record["deviceId"] = "  \n\(stableID)\t"

        let decoded = try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(
            record: record
        )

        XCTAssertEqual(decoded.id, stableID)
    }

    func testCloudTrustDecoderRejectsNoncanonicalRecordNameBoundary() throws {
        let record = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: " id:noncanonical-cloud-authority ")
        )

        XCTAssertThrowsError(
            try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(record: record)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("recordName"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }
    }

    func testCloudPointReadIdentityMismatchPersistentlyQuarantinesExpectedAuthority() throws {
        let stableID = "id:cloud-point-read-binding"
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: stableID,
            name: "Local active authority",
            platform: .macOS,
            ipAddress: "192.0.2.93",
            currentDeviceId: stableID,
            knownDeviceIds: [stableID],
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 4
        )
        var persisted = [localActive]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        let recordID = CKRecord.ID(recordName: stableID)
        let mismatchedRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: recordID
        )
        mismatchedRecord["deviceId"] = "id:different-cloud-authority"
        mismatchedRecord["lifecycleState"] =
            TrustedDeviceStore.CurrentPathLifecycleState.active.rawValue
        mismatchedRecord["lifecycleGeneration"] = NSNumber(value: 99)

        XCTAssertThrowsError(
            try CloudKitSyncManager.decodeTrustedDevicePointReadForTesting(
                record: mismatchedRecord,
                expectedRecordID: recordID,
                trustedDeviceStore: store
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("deviceId 与 recordName 不一致"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        let quarantined = try XCTUnwrap(store.trustedDevices.first)
        XCTAssertEqual(store.trustedDevices.count, 1)
        XCTAssertEqual(quarantined.id, stableID)
        XCTAssertEqual(quarantined.currentPathLifecycleState, .quarantined)
        XCTAssertEqual(quarantined.currentPathLifecycleGeneration, 5)
        XCTAssertEqual(persisted, [quarantined])
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [stableID]))
        XCTAssertFalse(store.isTrusted(deviceId: stableID))
    }

    func testCloudPointReadMalformedLifecyclePersistentlyQuarantinesExpectedAuthority() throws {
        let stableID = "id:cloud-point-read-malformed-lifecycle"
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: stableID,
            name: "Local active authority",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableID,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 7
        )
        var persisted = [localActive]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        let recordID = CKRecord.ID(recordName: stableID)
        let malformedRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: recordID
        )
        malformedRecord["deviceId"] = stableID
        malformedRecord["lifecycleState"] = "revokd"

        XCTAssertThrowsError(
            try CloudKitSyncManager.decodeTrustedDevicePointReadForTesting(
                record: malformedRecord,
                expectedRecordID: recordID,
                trustedDeviceStore: store
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("lifecycleState"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        let quarantined = try XCTUnwrap(store.trustedDevices.first)
        XCTAssertEqual(quarantined.currentPathLifecycleState, .quarantined)
        XCTAssertEqual(quarantined.currentPathLifecycleGeneration, 8)
        XCTAssertEqual(persisted, [quarantined])
        XCTAssertFalse(store.isTrusted(deviceId: stableID))
    }

    func testCloudTrustUploadRejectsLocalAuthoritySetBeyondWireLimit() throws {
        XCTAssertNoThrow(
            try CloudKitSyncManager.validateTrustedDeviceUploadCount(2_000)
        )
        XCTAssertThrowsError(
            try CloudKitSyncManager.validateTrustedDeviceUploadCount(2_001)
        )
    }

    func testCloudFetchRecordLimitCommitsObservedRevocationAndQuarantinesLocalBatch() async throws {
        let revokedID = "id:cloud-record-limit-revoked"
        let activeID = "id:cloud-record-limit-active"
        let localRevocationTarget = TrustedDeviceStore.TrustedDevice(
            id: revokedID,
            name: "Observed revocation target",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: revokedID,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: activeID,
            name: "Local active authority",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: activeID,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        var persisted = [localRevocationTarget, localActive]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        var observedRevocation = localRevocationTarget
        observedRevocation.currentPathLifecycleState = .revoked
        observedRevocation.currentPathLifecycleGeneration = 1
        var untrustedPositiveSnapshot = localActive
        untrustedPositiveSnapshot.currentPathLifecycleGeneration = 99

        do {
            try await CloudKitSyncManager.failClosedForTrustedDeviceFetchLimitForTesting(
                fetchedRecordCount: 2_001,
                maximumRecordCount: 2_000,
                observedDevices: [observedRevocation, untrustedPositiveSnapshot],
                trustedDeviceStore: store
            )
            XCTFail("A CloudKit trusted-device snapshot over the hard limit must fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("超过安全上限（2000 条）"),
                "Unexpected error: \(error.localizedDescription)"
            )
        }

        let revoked = try XCTUnwrap(store.trustedDevices.first { $0.id == revokedID })
        let quarantined = try XCTUnwrap(store.trustedDevices.first { $0.id == activeID })
        XCTAssertEqual(revoked.currentPathLifecycleState, .revoked)
        XCTAssertEqual(revoked.currentPathLifecycleGeneration, 1)
        XCTAssertEqual(quarantined.currentPathLifecycleState, .quarantined)
        XCTAssertEqual(
            quarantined.currentPathLifecycleGeneration,
            1,
            "An incomplete positive generation must never be committed before quarantine"
        )
        XCTAssertEqual(persisted, store.trustedDevices)
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [revokedID, activeID]))
    }

    func testCloudUpsertWinnerPreventsStaleClientActiveFromOverwritingNewerRevocation() throws {
        let stableId = "id:cloud-race-authority"
        let staleClientActive = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Stale client",
            platform: .macOS,
            ipAddress: "192.0.2.50",
            currentDeviceId: stableId,
            knownDeviceIds: [
                stableId,
                "host:192.0.2.50",
                "bonjour:stale-client@local."
            ],
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0,
            connectableContext: .init(
                bonjourServiceName: "stale-client",
                bonjourServiceType: "_skybridge._tcp",
                bonjourServiceDomain: "local.",
                lastResolvedIPAddress: "192.0.2.50"
            )
        )
        var newerCloudRevocation = staleClientActive
        newerCloudRevocation.currentPathLifecycleState = .revoked
        newerCloudRevocation.currentPathLifecycleGeneration = 1

        let winner = try CloudKitSyncManager.trustedDeviceForCloudUpsert(
            local: staleClientActive,
            existing: newerCloudRevocation
        )

        XCTAssertEqual(winner.currentPathLifecycleState, .revoked)
        XCTAssertEqual(winner.currentPathLifecycleGeneration, 1)
        XCTAssertNil(winner.ipAddress)
        XCTAssertNil(winner.connectableContext)
        XCTAssertEqual(winner.knownDeviceIds, [stableId])
    }

    func testCloudUpsertWinnerMakesSameGenerationRevocationDominantButAllowsNewerRepair() throws {
        let stableId = "id:cloud-race-repair"
        let activeGenerationOne = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Client A",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableId,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 1
        )
        var revokedGenerationOne = activeGenerationOne
        revokedGenerationOne.currentPathLifecycleState = .revoked

        let sameGenerationWinner = try CloudKitSyncManager.trustedDeviceForCloudUpsert(
            local: activeGenerationOne,
            existing: revokedGenerationOne
        )
        XCTAssertEqual(sameGenerationWinner.currentPathLifecycleState, .revoked)
        XCTAssertEqual(sameGenerationWinner.currentPathLifecycleGeneration, 1)

        var explicitlyRepaired = activeGenerationOne
        explicitlyRepaired.currentPathLifecycleGeneration = 2
        let repairedWinner = try CloudKitSyncManager.trustedDeviceForCloudUpsert(
            local: explicitlyRepaired,
            existing: revokedGenerationOne
        )
        XCTAssertEqual(repairedWinner.currentPathLifecycleState, .active)
        XCTAssertEqual(repairedWinner.currentPathLifecycleGeneration, 2)
    }

    func testObservedCloudRevocationCommitsLocallyBeforeSaveFailurePropagates() async throws {
        let stableId = "id:cloud-save-failure-revocation"
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Local stale active",
            platform: .macOS,
            ipAddress: "192.0.2.81",
            currentDeviceId: stableId,
            knownDeviceIds: [stableId, "host:192.0.2.81"],
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([localActive])

        var observedRevocation = localActive
        observedRevocation.currentPathLifecycleState = .revoked
        observedRevocation.currentPathLifecycleGeneration = 1
        let rejectedSave: () async throws -> Void = {
            throw InjectedPersistenceFailure.save
        }

        do {
            try await CloudKitSyncManager.withObservedLifecycleAuthorityCommitted(
                [observedRevocation],
                perform: rejectedSave
            )
            XCTFail("The CloudKit save failure must remain observable")
        } catch InjectedPersistenceFailure.save {
            // Expected: local revocation commits, while the save error still propagates.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let committed = try XCTUnwrap(TrustedDeviceStore.shared.trustedDevices.first)
        XCTAssertEqual(committed.currentPathLifecycleState, .revoked)
        XCTAssertEqual(committed.currentPathLifecycleGeneration, 1)
        XCTAssertNil(committed.ipAddress)
        XCTAssertEqual(committed.knownDeviceIds, [stableId])
        XCTAssertFalse(TrustedDeviceStore.shared.hasActiveDurableTrust(forAny: [stableId]))
    }

    func testServerRecordChangedRevocationCommitsBeforePartialSaveFailureEscapes() async throws {
        let stableId = "id:cloud-cas-server-revocation"
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Local stale active",
            platform: .macOS,
            ipAddress: "192.0.2.91",
            currentDeviceId: stableId,
            knownDeviceIds: [stableId, "host:192.0.2.91"],
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([localActive])

        let recordID = CKRecord.ID(recordName: stableId)
        let clientRecord = CKRecord(recordType: "SBTrustedDevice", recordID: recordID)
        let serverRecord = CKRecord(recordType: "SBTrustedDevice", recordID: recordID)
        serverRecord["deviceId"] = stableId
        serverRecord["name"] = "Remote revoked authority"
        serverRecord["platform"] = DevicePlatform.macOS.rawValue
        serverRecord["ipAddress"] = "192.0.2.200"
        serverRecord["currentDeviceId"] = stableId
        serverRecord["knownDeviceIds"] = [stableId, "host:192.0.2.200"]
        serverRecord["lifecycleState"] = TrustedDeviceStore.CurrentPathLifecycleState.revoked.rawValue
        serverRecord["lifecycleGeneration"] = NSNumber(value: 1)

        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorClientRecordKey: clientRecord,
                CKRecordChangedErrorServerRecordKey: serverRecord,
            ]
        )
        let partialFailure = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [recordID: conflict]]
        )

        try await CloudKitSyncManager.commitServerConflictLifecycleAuthorityForTesting(
            error: partialFailure,
            expectedDevice: localActive
        )

        let committed = try XCTUnwrap(TrustedDeviceStore.shared.trustedDevices.first)
        XCTAssertEqual(committed.currentPathLifecycleState, .revoked)
        XCTAssertEqual(committed.currentPathLifecycleGeneration, 1)
        XCTAssertNil(committed.ipAddress, "Remote endpoint metadata must not survive a tombstone")
        XCTAssertEqual(committed.knownDeviceIds, [stableId])
        XCTAssertFalse(TrustedDeviceStore.shared.hasActiveDurableTrust(forAny: [stableId]))
    }

    func testServerRecordChangedIdentityMismatchPersistentlyQuarantinesLocalAuthority() async throws {
        let stableId = "id:cloud-cas-identity-mismatch"
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Local active authority",
            platform: .macOS,
            ipAddress: "192.0.2.92",
            currentDeviceId: stableId,
            knownDeviceIds: [stableId],
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 4
        )
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([localActive])

        let recordID = CKRecord.ID(recordName: stableId)
        let serverRecord = CKRecord(recordType: "SBTrustedDevice", recordID: recordID)
        serverRecord["deviceId"] = "id:different-cloud-authority"
        serverRecord["lifecycleState"] = TrustedDeviceStore.CurrentPathLifecycleState.revoked.rawValue
        serverRecord["lifecycleGeneration"] = NSNumber(value: 9)
        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]
        )

        try await CloudKitSyncManager.commitServerConflictLifecycleAuthorityForTesting(
            error: conflict,
            expectedDevice: localActive
        )

        let quarantined = try XCTUnwrap(TrustedDeviceStore.shared.trustedDevices.first)
        XCTAssertEqual(quarantined.id, stableId)
        XCTAssertEqual(quarantined.currentPathLifecycleState, .quarantined)
        XCTAssertEqual(quarantined.currentPathLifecycleGeneration, 5)
        XCTAssertFalse(TrustedDeviceStore.shared.hasActiveDurableTrust(forAny: [stableId]))
        XCTAssertFalse(TrustedDeviceStore.shared.isTrusted(deviceId: stableId))
    }

    func testCloudTrustDecoderAcceptsMissingLegacyLifecycleFields() throws {
        let legacyRecord = CKRecord(
            recordType: "SBTrustedDevice",
            recordID: CKRecord.ID(recordName: "id:legacy-cloud-authority")
        )
        legacyRecord["deviceId"] = "id:legacy-cloud-authority"

        let decoded = try CloudKitSyncManager.instance.decodeTrustedDeviceForTesting(
            record: legacyRecord
        )

        XCTAssertEqual(decoded.id, "id:legacy-cloud-authority")
        XCTAssertNil(decoded.currentPathLifecycleState)
        XCTAssertNil(decoded.currentPathLifecycleGeneration)
    }

    func testCloudTrustLifecycleCoalescesStartupAndForegroundSync() async throws {
        let gate = CloudTrustSyncGate()
        let manager = CloudKitSyncManager(
            testingSyncOperation: {
                await gate.waitForRelease()
            }
        )

        let startup = Task { @MainActor in
            try await manager.refreshTrustedDevices(trigger: .startup)
        }
        let didStart = await waitForCloudSyncInvocation(gate)
        XCTAssertTrue(didStart)

        let foreground = Task { @MainActor in
            try await manager.refreshTrustedDevices(trigger: .foreground)
        }
        for _ in 0..<50 {
            await Task.yield()
        }

        let invocationCount = await gate.invocationCount()
        XCTAssertEqual(invocationCount, 1)
        XCTAssertTrue(manager.isSyncing)

        await gate.releaseAll()
        try await startup.value
        try await foreground.value

        XCTAssertFalse(manager.isSyncing)
        XCTAssertNotNil(manager.lastSyncDate)
        XCTAssertNil(manager.lastSyncErrorMessage)
    }

    func testCloudTrustFlightCompletesAfterCreatingCallerIsCancelled() async throws {
        let gate = CloudTrustSyncGate()
        let manager = CloudKitSyncManager(
            testingSyncOperation: {
                await gate.waitForRelease()
            }
        )

        let creatingCaller = Task { @MainActor in
            try await manager.refreshTrustedDevices(trigger: .startup)
        }
        let didStart = await waitForCloudSyncInvocation(gate)
        XCTAssertTrue(didStart)
        creatingCaller.cancel()

        let foregroundFollower = Task { @MainActor in
            try await manager.refreshTrustedDevices(trigger: .foreground)
        }
        for _ in 0..<50 {
            await Task.yield()
        }
        let concurrentInvocationCount = await gate.invocationCount()
        XCTAssertEqual(concurrentInvocationCount, 1)

        await gate.releaseAll()
        _ = try await creatingCaller.value
        try await foregroundFollower.value

        XCTAssertFalse(manager.isSyncing)
        XCTAssertNotNil(manager.lastSyncDate)
        XCTAssertNil(manager.lastSyncErrorMessage)
    }

    func testRecentForegroundSyncDeduplicatesOnlyUnchangedTrustSnapshot() async throws {
        let counter = CloudTrustSyncCounter()
        let manager = CloudKitSyncManager(
            testingSyncOperation: {
                await counter.run()
            }
        )

        try await manager.refreshTrustedDevices(trigger: .startup)
        try await manager.refreshTrustedDevices(trigger: .foreground)
        let deduplicatedInvocationCount = await counter.invocationCount()
        XCTAssertEqual(deduplicatedInvocationCount, 1)

        let changedTrust = TrustedDeviceStore.TrustedDevice(
            id: "id:foreground-dedup-change",
            name: "Foreground change",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: "id:foreground-dedup-change",
            currentPathLifecycleState: .revoked,
            currentPathLifecycleGeneration: 1
        )
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([changedTrust])

        try await manager.refreshTrustedDevices(trigger: .foreground)
        let changedSnapshotInvocationCount = await counter.invocationCount()
        XCTAssertEqual(changedSnapshotInvocationCount, 2)
    }

    func testAppStoreProfileAbsenceDoesNotDisableCloudKitInitialization() {
        XCTAssertTrue(
            CloudKitSyncManager.shouldAttemptCloudKitForTesting(profileData: nil)
        )

        let profileWithoutCloudKit = Data(
            """
            <plist version="1.0"><dict><key>Entitlements</key><dict>
            <key>com.apple.developer.icloud-services</key>
            <array><string>CloudDocuments</string></array>
            </dict></dict></plist>
            """.utf8
        )
        XCTAssertFalse(
            CloudKitSyncManager.shouldAttemptCloudKitForTesting(
                profileData: profileWithoutCloudKit
            )
        )

        let cloudKitProfile = Data(
            """
            <plist version="1.0"><dict><key>Entitlements</key><dict>
            <key>com.apple.developer.icloud-services</key>
            <array><string>CloudKit</string></array>
            </dict></dict></plist>
            """.utf8
        )
        XCTAssertTrue(
            CloudKitSyncManager.shouldAttemptCloudKitForTesting(
                profileData: cloudKitProfile
            )
        )
    }

    func testCloudSyncLogSummaryDoesNotIncludeLocalizedSensitiveDetails() {
        let summary = CloudKitSyncManager.safeErrorSummary(
            SensitiveCloudSyncFailure.injected
        )

        XCTAssertFalse(summary.contains("must-not-appear-in-logs"))
        XCTAssertTrue(summary.contains("SensitiveCloudSyncFailure"))
    }

    func testAsyncCloudMergeCommitsRevocationGeneration() async throws {
        let stableId = "id:async-cloud-merge"
        let localActive = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Async merge",
            platform: .macOS,
            ipAddress: "192.0.2.20",
            currentDeviceId: stableId,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([localActive])

        var remoteRevocation = localActive
        remoteRevocation.ipAddress = nil
        remoteRevocation.currentPathLifecycleState = .revoked
        remoteRevocation.currentPathLifecycleGeneration = 1

        try await TrustedDeviceStore.shared.mergeFromCloudWithoutBlockingMainActor(
            [remoteRevocation]
        )

        let merged = try XCTUnwrap(TrustedDeviceStore.shared.trustedDevices.first)
        XCTAssertEqual(merged.currentPathLifecycleState, .revoked)
        XCTAssertEqual(merged.currentPathLifecycleGeneration, 1)
        XCTAssertNil(merged.ipAddress)
    }

    func testCloudTrustLifecycleFailureIsObservableAndRetryPreservesLocalTrust() async throws {
        let stableId = "id:cloud-sync-preserved-local-trust"
        let localTrust = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Preserved local trust",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableId,
            currentPathLifecycleState: .revoked,
            currentPathLifecycleGeneration: 1
        )
        try TrustedDeviceStore.shared.replaceTrustedDevicesForTesting([localTrust])

        let script = CloudTrustSyncAttemptScript()
        let manager = CloudKitSyncManager(
            testingSyncOperation: {
                try await script.run()
            }
        )

        do {
            try await manager.refreshTrustedDevices(trigger: .startup)
            XCTFail("Injected CloudKit failure must be propagated")
        } catch {
            XCTAssertEqual(error.localizedDescription, "injected CloudKit failure")
        }

        XCTAssertFalse(manager.isSyncing)
        XCTAssertNil(manager.lastSyncDate)
        XCTAssertEqual(manager.lastSyncErrorMessage, "injected CloudKit failure")
        XCTAssertEqual(TrustedDeviceStore.shared.trustedDevices, [localTrust])

        try await manager.refreshTrustedDevices(trigger: .foreground)

        XCTAssertFalse(manager.isSyncing)
        XCTAssertNotNil(manager.lastSyncDate)
        XCTAssertNil(manager.lastSyncErrorMessage)
        XCTAssertEqual(TrustedDeviceStore.shared.trustedDevices, [localTrust])
    }

    func testCurrentPathBindingMatchesKnownAliasesForConflictEvaluation() throws {
        let stableId = canonical("11111111-2222-4333-8444-555555555555")
        let aliasId = "bonjour:Fixture MacBook Pro@local."
        let device = DiscoveredDevice(
            id: aliasId,
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )
        let key = protocolIdentityKey(.ed25519, seed: 0xD1)
        let fingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: key)

        XCTAssertTrue(
            try TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
                for: device,
                preferredCurrentDeviceId: stableId,
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: fingerprint,
                protocolPublicKeyBytes: key
            )
        )

        let conflict = TrustedDeviceStore.shared.evaluateCurrentPathBinding(
            deviceId: stableId,
            protocolPublicKeyFingerprint: String(repeating: "e", count: 64)
        )

        XCTAssertEqual(conflict, .identityConflict)
    }

    func testCurrentPathTrustLookupMatchesAliasBackToStableDeviceId() throws {
        let stableId = canonical("11111111-2222-4333-8444-555555555555")
        let aliasId = "bonjour:Fixture MacBook Pro@local."
        let device = DiscoveredDevice(
            id: aliasId,
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )
        let key = protocolIdentityKey(.ed25519, seed: 0xD2)
        let fingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: key)

        XCTAssertTrue(
            try TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
                for: device,
                preferredCurrentDeviceId: stableId,
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: fingerprint,
                protocolPublicKeyBytes: key
            )
        )

        let trusted = TrustedDeviceStore.shared.currentPathTrustRecord(
            fingerprint: fingerprint,
            matchingDeviceId: stableId
        )

        XCTAssertEqual(trusted?.currentDeviceId, stableId)
    }

    func testPersistentDeviceIdRejectsDisplayNamePayloads() {
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "Fixture MacBook Pro"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "id:fixture macbook pro"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "192.168.10.22"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "id:192.168.10.22"))
        XCTAssertNil(PeerIdentityAliasResolver.persistentDeviceId(from: "fe80::81d:bb45:8c18:6d6a%en0"))
        XCTAssertEqual(
            PeerIdentityAliasResolver.persistentDeviceId(from: "11111111-2222-4333-8444-555555555555"),
            "id:11111111-2222-4333-8444-555555555555"
        )
    }

    func testCanonicalTrustedDeviceIdFallsBackToUniqueTrustedNameForDiscoveryDevice() throws {
        let key = protocolIdentityKey(.ed25519, seed: 0xD3)
        let fingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: key)
        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: "device-mac-stable",
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: key
        )

        let discoveryDevice = DiscoveredDevice(
            id: "host:fe80::81d:bb45:8c18:6d6a%en0",
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "fe80::81d:bb45:8c18:6d6a%en0"
        )

        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: discoveryDevice),
            canonical("device-mac-stable")
        )
    }

    func testRecordAuthenticatedRemoteAuthorityUpdatesAliasMatchedTrustedRecord() throws {
        let stableId = "id:peer-mac-stable"
        let aliasDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        try TrustedDeviceStore.shared.trustResolvedPeer(aliasDevice, declaredDeviceId: stableId)
        let key = protocolIdentityKey(.mlDSA65, seed: 0xE1)
        let fingerprint = protocolIdentityFingerprint(algorithm: .mlDSA65, key: key)

        let updated = try TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
            for: aliasDevice,
            preferredCurrentDeviceId: stableId,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: key
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice),
            stableId
        )
        let trusted = TrustedDeviceStore.shared.currentPathTrustRecord(
            fingerprint: fingerprint
        )
        XCTAssertEqual(trusted?.currentDeviceId, stableId)
        XCTAssertEqual(trusted?.protocolSigningAlgorithm, "ML-DSA-65")
    }

    func testRecordAuthenticatedRemoteAuthorityRejectsEphemeralOnlyNewRecord() {
        let aliasDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: nil
        )
        let key = protocolIdentityKey(.mlDSA65, seed: 0xE2)
        let fingerprint = protocolIdentityFingerprint(algorithm: .mlDSA65, key: key)

        XCTAssertThrowsError(
            try TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
                for: aliasDevice,
                preferredCurrentDeviceId: nil,
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: fingerprint,
                protocolPublicKeyBytes: key
            )
        ) { error in
            XCTAssertEqual(
                error as? TrustedDeviceStore.AuthorityUpdateError,
                .missingStableDeviceIdentifier
            )
        }
        XCTAssertNil(
            TrustedDeviceStore.shared.currentPathTrustRecord(
                fingerprint: fingerprint
            )
        )
    }

    func testUpsertCurrentPathAuthorityRejectsSameAlgorithmKeyReplacementAndRequiresReverification() throws {
        let deviceId = "11111111-2222-4333-8444-555555555555"
        let canonicalDeviceId = canonical(deviceId)
        let firstKey = protocolIdentityKey(.mlDSA65, seed: 0xF1)
        let firstFingerprint = protocolIdentityFingerprint(algorithm: .mlDSA65, key: firstKey)
        let replacementKey = protocolIdentityKey(.mlDSA65, seed: 0xF2)
        let replacementFingerprint = protocolIdentityFingerprint(algorithm: .mlDSA65, key: replacementKey)

        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "ML-DSA-65",
            protocolPublicKeyFingerprint: firstFingerprint,
            protocolPublicKeyBytes: firstKey
        )
        XCTAssertThrowsError(
            try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
                deviceId: deviceId,
                name: "Fixture MacBook Pro",
                platform: .macOS,
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: replacementFingerprint,
                protocolPublicKeyBytes: replacementKey
            )
        ) { error in
            XCTAssertEqual(
                error as? TrustedDeviceStore.AuthorityUpdateError,
                .conflictingProtocolIdentityKey(algorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue)
            )
        }

        XCTAssertEqual(TrustedDeviceStore.shared.trustedDevices.count, 1)
        let quarantined = try XCTUnwrap(TrustedDeviceStore.shared.trustedDevices.first)
        XCTAssertEqual(quarantined.currentDeviceId, canonicalDeviceId)
        XCTAssertEqual(quarantined.currentPathLifecycleState, .reverificationRequired)
        XCTAssertEqual(quarantined.protocolPublicKeyFingerprint, firstFingerprint)
        XCTAssertEqual(quarantined.protocolIdentityKeyBindings?.first?.publicKeyBytes, firstKey)
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: firstFingerprint))
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: replacementFingerprint))
    }

    func testApprovedProtocolIdentityBindingAddsDifferentAlgorithmAuthorityPin() throws {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)
        let edKey = protocolIdentityKey(.ed25519, seed: 0x31)
        let edFingerprint = protocolIdentityFingerprint(algorithm: .ed25519, key: edKey)
        let mlKey = protocolIdentityKey(.mlDSA65, seed: 0x41)
        let mlFingerprint = protocolIdentityFingerprint(algorithm: .mlDSA65, key: mlKey)

        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: stableId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: edFingerprint,
            protocolPublicKeyBytes: edKey
        )

        XCTAssertTrue(
            try TrustedDeviceStore.shared.recordApprovedProtocolIdentityBinding(
                peerId: "host:fe80::812:27b6:c448:dad0%en0",
                deviceId: canonicalStableId,
                aliases: ["bonjour:Fixture MacBook Pro@local."],
                displayName: "Fixture MacBook Pro",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: mlFingerprint,
                protocolPublicKeyBytes: mlKey
            )
        )

        let fingerprints = TrustedDeviceStore.shared.currentPathFingerprints(forAny: [canonicalStableId])
        XCTAssertEqual(fingerprints, [edFingerprint, mlFingerprint])
        XCTAssertNotNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: edFingerprint))
        XCTAssertNotNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: mlFingerprint))
        XCTAssertEqual(
            TrustedDeviceStore.shared.currentPathProtocolIdentityKeyBinding(
                for: canonicalStableId,
                algorithm: .ed25519
            )?.publicKeyBytes,
            edKey
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.currentPathProtocolIdentityKeyBinding(
                for: canonicalStableId,
                algorithm: .mlDSA65
            )?.publicKeyBytes,
            mlKey
        )
    }

    func testMLDSA65And87RawBindingsCoexistAndResolveByAlgorithm() throws {
        let deviceId = "11111111-2222-4333-8444-555555555555"
        let mlDSA65Key = protocolIdentityKey(.mlDSA65, seed: 0x65)
        let mlDSA65Fingerprint = protocolIdentityFingerprint(
            algorithm: .mlDSA65,
            key: mlDSA65Key
        )
        let mlDSA87Key = protocolIdentityKey(.mlDSA87, seed: 0x87)
        let mlDSA87Fingerprint = protocolIdentityFingerprint(
            algorithm: .mlDSA87,
            key: mlDSA87Key
        )

        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolPublicKeyFingerprint: mlDSA65Fingerprint,
            protocolPublicKeyBytes: mlDSA65Key
        )
        try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
            deviceId: deviceId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA87.rawValue,
            protocolPublicKeyFingerprint: mlDSA87Fingerprint,
            protocolPublicKeyBytes: mlDSA87Key
        )

        XCTAssertEqual(
            TrustedDeviceStore.shared.currentPathFingerprints(forAny: [deviceId]),
            [mlDSA65Fingerprint, mlDSA87Fingerprint]
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.currentPathProtocolIdentityKeyBinding(
                for: deviceId,
                algorithm: .mlDSA65
            )?.publicKeyBytes,
            mlDSA65Key
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.currentPathProtocolIdentityKeyBinding(
                for: deviceId,
                algorithm: .mlDSA87
            )?.publicKeyBytes,
            mlDSA87Key
        )
    }

    func testRawBindingRejectsWrongLengthAndFingerprintMismatchWithoutPublishingTrust() {
        let deviceId = "11111111-2222-4333-8444-555555555555"
        let shortMLDSA65Key = Data(repeating: 0x65, count: 1_951)
        let shortFingerprint = protocolIdentityFingerprint(
            algorithm: .mlDSA65,
            key: shortMLDSA65Key
        )

        XCTAssertThrowsError(
            try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
                deviceId: deviceId,
                name: "Fixture MacBook Pro",
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                protocolPublicKeyFingerprint: shortFingerprint,
                protocolPublicKeyBytes: shortMLDSA65Key
            )
        ) { error in
            XCTAssertEqual(
                error as? TrustedDeviceStore.AuthorityUpdateError,
                .invalidProtocolPublicKey
            )
        }

        let validKey = protocolIdentityKey(.mlDSA87, seed: 0x88)
        XCTAssertThrowsError(
            try TrustedDeviceStore.shared.upsertCurrentPathAuthority(
                deviceId: deviceId,
                name: "Fixture MacBook Pro",
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA87.rawValue,
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                protocolPublicKeyBytes: validKey
            )
        ) { error in
            XCTAssertEqual(
                error as? TrustedDeviceStore.AuthorityUpdateError,
                .protocolPublicKeyFingerprintMismatch
            )
        }

        XCTAssertTrue(TrustedDeviceStore.shared.trustedDevices.isEmpty)
    }

    func testProtocolIdentityTrustStorePersists65And87AndFailsClosedOnSameAlgorithmConflict() async {
        let store = ProtocolIdentityTrustStore.shared
        await store.clearForTesting()

        let deviceId = "id:protocol-store-multi-algorithm"
        let mlDSA65Key = protocolIdentityKey(.mlDSA65, seed: 0x51)
        let mlDSA87Key = protocolIdentityKey(.mlDSA87, seed: 0x71)
        let keys = [
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
                publicKey: mlDSA65Key
            ),
            AppMessage.ProtocolIdentityPublicKeyInfo(
                protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA87.rawValue,
                publicKey: mlDSA87Key
            )
        ]
        await store.upsert(deviceId: deviceId, protocolIdentityPublicKeys: keys)

        let storedMLDSA65Key = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .mlDSA65
        )
        let storedMLDSA87Key = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .mlDSA87
        )
        let storedFingerprints = await store.trustedFingerprints(for: deviceId)
        XCTAssertEqual(storedMLDSA65Key, mlDSA65Key)
        XCTAssertEqual(storedMLDSA87Key, mlDSA87Key)
        XCTAssertEqual(storedFingerprints.count, 2)

        let conflictingMLDSA87Key = protocolIdentityKey(.mlDSA87, seed: 0x72)
        await store.upsert(
            deviceId: deviceId,
            protocolIdentityPublicKeys: [
                AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA87.rawValue,
                    publicKey: conflictingMLDSA87Key
                )
            ]
        )

        let fingerprintsAfterConflict = await store.trustedFingerprints(for: deviceId)
        let mlDSA65AfterConflict = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .mlDSA65
        )
        let mlDSA87AfterConflict = await store.trustedProtocolIdentityPublicKey(
            forAny: [deviceId],
            algorithm: .mlDSA87
        )
        XCTAssertTrue(fingerprintsAfterConflict.isEmpty)
        XCTAssertNil(mlDSA65AfterConflict)
        XCTAssertNil(mlDSA87AfterConflict)
        await store.clearForTesting()
    }

    func testRecordAuthenticatedRemoteAuthorityQuarantinesLegacySameAlgorithmConflicts() throws {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let aliasId = "bonjour:Fixture MacBook Pro@local."
        let deviceName = "Fixture MacBook Pro"
        let oldFingerprint = String(repeating: "a", count: 64)
        let staleFingerprint = String(repeating: "b", count: 64)
        let authenticatedKey = protocolIdentityKey(.mlDSA65, seed: 0xC3)
        let authenticatedFingerprint = protocolIdentityFingerprint(
            algorithm: .mlDSA65,
            key: authenticatedKey
        )

        try TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: stableId,
                name: deviceName,
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: oldFingerprint,
                currentDeviceId: stableId,
                knownDeviceIds: [stableId, aliasId],
                currentPathLifecycleState: .active
            ),
            TrustedDeviceStore.TrustedDevice(
                id: aliasId,
                name: deviceName,
                platform: .macOS,
                ipAddress: "192.168.1.20",
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: staleFingerprint,
                currentDeviceId: stableId,
                knownDeviceIds: [stableId, aliasId],
                currentPathLifecycleState: .active
            )
        ])

        let aliasDevice = DiscoveredDevice(
            id: aliasId,
            name: deviceName,
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "15.0",
            ipAddress: "192.168.1.20"
        )

        XCTAssertThrowsError(
            try TrustedDeviceStore.shared.recordAuthenticatedRemoteAuthority(
                for: aliasDevice,
                preferredCurrentDeviceId: stableId,
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: authenticatedFingerprint,
                protocolPublicKeyBytes: authenticatedKey
            )
        ) { error in
            XCTAssertEqual(
                error as? TrustedDeviceStore.AuthorityUpdateError,
                .conflictingProtocolIdentityKey(algorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue)
            )
        }

        XCTAssertEqual(TrustedDeviceStore.shared.trustedDevices.count, 1)
        XCTAssertTrue(TrustedDeviceStore.shared.trustedDevices.allSatisfy {
            $0.currentPathLifecycleState == .reverificationRequired
        })
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: oldFingerprint))
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: staleFingerprint))
        XCTAssertNil(TrustedDeviceStore.shared.currentPathTrustRecord(fingerprint: authenticatedFingerprint))
        XCTAssertNil(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice))
    }

    func testCanonicalTrustedDeviceIdIgnoresPollutedDisplayNameCurrentDeviceId() throws {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)

        try TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: "id:fixture macbook pro",
                name: "Fixture MacBook Pro",
                platform: .macOS,
                ipAddress: "192.168.1.20",
                currentDeviceId: "id:fixture macbook pro",
                knownDeviceIds: ["bonjour:Fixture MacBook Pro@local.", stableId]
            )
        ])

        let discoveryDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            bonjourServiceName: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )

        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: discoveryDevice),
            canonicalStableId
        )
    }

    func testReverificationRequiredRecordIsNotPresentedAsTrustedOrConnectable() throws {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)
        let aliasDevice = DiscoveredDevice(
            id: "bonjour:Fixture MacBook Pro@local.",
            name: "Fixture MacBook Pro",
            bonjourServiceName: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )

        try TrustedDeviceStore.shared.trustResolvedPeer(aliasDevice, declaredDeviceId: stableId)

        XCTAssertTrue(TrustedDeviceStore.shared.isTrusted(deviceId: aliasDevice.id))
        XCTAssertEqual(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice), canonicalStableId)
        XCTAssertNotNil(TrustedDeviceStore.shared.resolvedConnectableDevice(for: aliasDevice))

        XCTAssertTrue(TrustedDeviceStore.shared.markReverificationRequired(deviceId: stableId))

        XCTAssertFalse(TrustedDeviceStore.shared.isTrusted(deviceId: aliasDevice.id))
        XCTAssertNil(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice))
        XCTAssertNil(TrustedDeviceStore.shared.resolvedConnectableDevice(for: aliasDevice))
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.currentPathLifecycleState,
            .reverificationRequired
        )

        try TrustedDeviceStore.shared.trustResolvedPeer(aliasDevice, declaredDeviceId: stableId)

        XCTAssertTrue(TrustedDeviceStore.shared.isTrusted(deviceId: aliasDevice.id))
        XCTAssertEqual(TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: aliasDevice), canonicalStableId)
        XCTAssertNotNil(TrustedDeviceStore.shared.resolvedConnectableDevice(for: aliasDevice))
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.currentPathLifecycleState,
            .active
        )
    }

    func testRepairLegacyTrustedDeviceIdentityPromotesUniqueLiveStableId() async throws {
        let stableId = "11111111-2222-4333-8444-555555555555"
        let canonicalStableId = canonical(stableId)
        let pollutedId = "id:fixture macbook pro"

        try TrustedDeviceStore.shared.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: pollutedId,
                name: "Fixture MacBook Pro",
                platform: .macOS,
                ipAddress: nil,
                protocolSigningAlgorithm: "ML-DSA-65",
                protocolPublicKeyFingerprint: String(repeating: "a", count: 64),
                currentDeviceId: pollutedId,
                knownDeviceIds: ["bonjour:Fixture MacBook Pro@local.", "host:id:fixture macbook pro"]
            )
        ])

        let requestedDevice = DiscoveredDevice(
            id: pollutedId,
            name: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1"
        )
        let liveDevice = DiscoveredDevice(
            id: canonicalStableId,
            name: "Fixture MacBook Pro",
            bonjourServiceName: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.4.1",
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )

        let migratedAliases = TrustedDeviceStore.shared.repairLegacyTrustedDeviceIdentity(
            requestedDevice: requestedDevice,
            liveDiscoveredDevice: liveDevice
        )

        XCTAssertTrue(migratedAliases.contains(pollutedId))
        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: requestedDevice),
            canonicalStableId
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.canonicalTrustedDeviceId(for: liveDevice),
            canonicalStableId
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.currentDeviceId,
            canonicalStableId
        )
        XCTAssertEqual(
            TrustedDeviceStore.shared.trustedDevices.first?.connectableContext?.bonjourServiceName,
            "Fixture MacBook Pro"
        )
    }

    func testUntrustPersistsAliasAwareRevocationBeforePublishing() throws {
        let stableId = "id:11111111-2222-4333-8444-555555555555"
        let bonjourAlias = "bonjour:Fixture MacBook Pro@local."
        let active = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            ipAddress: "192.168.1.20",
            currentDeviceId: stableId,
            knownDeviceIds: [bonjourAlias],
            currentPathLifecycleState: .active,
            connectableContext: .init(
                bonjourServiceName: "Fixture MacBook Pro",
                bonjourServiceType: "_skybridge._tcp",
                bonjourServiceDomain: "local."
            )
        )
        var persisted = [active]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        let revokedAliases = try store.untrust(deviceId: bonjourAlias)

        XCTAssertTrue(revokedAliases.contains(stableId))
        XCTAssertEqual(persisted, store.trustedDevices)
        XCTAssertEqual(store.trustedDevices.first?.currentPathLifecycleState, .revoked)
        XCTAssertNil(store.trustedDevices.first?.ipAddress)
        XCTAssertNil(store.trustedDevices.first?.connectableContext)
        XCTAssertFalse(store.trustedDevices.first?.knownDeviceIds?.contains(bonjourAlias) ?? false)
        XCTAssertFalse(store.isTrusted(deviceId: stableId))
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [bonjourAlias]))
    }

    func testMatchedRevocationScrubsAllEndpointAliasesFromDurableTombstone() throws {
        let stableId = "id:matched-revocation-authority"
        let active = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Matched endpoint peer",
            platform: .macOS,
            ipAddress: "192.0.2.60",
            currentDeviceId: stableId,
            knownDeviceIds: [
                stableId,
                "192.0.2.60",
                "host:192.0.2.60",
                "peer:192.0.2.60",
                "recent:host:192.0.2.60",
                "bonjour:matched-endpoint@local."
            ],
            currentPathLifecycleState: .active,
            connectableContext: .init(
                bonjourServiceName: "matched-endpoint",
                lastResolvedIPAddress: "192.0.2.60"
            )
        )
        var persisted = [active]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        _ = try store.untrust(deviceId: "host:192.0.2.60")

        let tombstone = try XCTUnwrap(store.trustedDevices.first)
        XCTAssertEqual(tombstone.currentPathLifecycleState, .revoked)
        XCTAssertEqual(tombstone.knownDeviceIds, [stableId])
        XCTAssertNil(tombstone.ipAddress)
        XCTAssertNil(tombstone.connectableContext)
        XCTAssertEqual(persisted, [tombstone])
    }

    func testUnmatchedCloudRevocationDropsEndpointOnlyTombstoneAndScrubsStableTombstone() throws {
        var persisted: [TrustedDeviceStore.TrustedDevice] = []
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )
        let endpointOnly = TrustedDeviceStore.TrustedDevice(
            id: "host:192.0.2.70",
            name: "Reassignable endpoint",
            platform: .macOS,
            ipAddress: "192.0.2.70",
            knownDeviceIds: ["bonjour:reassignable@local."],
            currentPathLifecycleState: .revoked,
            currentPathLifecycleGeneration: 1,
            connectableContext: .init(lastResolvedIPAddress: "192.0.2.70")
        )
        let stableId = "id:unmatched-cloud-revocation"
        let stableTombstone = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Stable revoked peer",
            platform: .macOS,
            ipAddress: "192.0.2.71",
            currentDeviceId: stableId,
            knownDeviceIds: [stableId, "bonjour:stable-revoked@local."],
            currentPathLifecycleState: .revoked,
            currentPathLifecycleGeneration: 1,
            connectableContext: .init(lastResolvedIPAddress: "192.0.2.71")
        )

        try store.mergeFromCloud([endpointOnly, stableTombstone])

        let persistedTombstone = try XCTUnwrap(store.trustedDevices.first)
        XCTAssertEqual(store.trustedDevices.count, 1)
        XCTAssertEqual(persistedTombstone.id, stableId)
        XCTAssertEqual(persistedTombstone.knownDeviceIds, [stableId])
        XCTAssertNil(persistedTombstone.ipAddress)
        XCTAssertNil(persistedTombstone.connectableContext)
        XCTAssertEqual(persisted, [persistedTombstone])
    }

    func testUntrustSaveFailureLeavesPublishedStateUnchangedAndDisablesAuthority() {
        let stableId = "id:11111111-2222-4333-8444-555555555555"
        let active = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableId,
            currentPathLifecycleState: .active
        )
        let store = TrustedDeviceStore(
            testingLoad: { [active] },
            testingSave: { _ in throw InjectedPersistenceFailure.save }
        )
        let publishedBeforeFailedCommit = store.trustedDevices

        XCTAssertThrowsError(try store.untrust(deviceId: stableId))
        XCTAssertEqual(store.trustedDevices, publishedBeforeFailedCommit)
        XCTAssertFalse(store.isAuthorityPersistenceAvailable)
        XCTAssertFalse(store.isTrusted(deviceId: stableId))
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [stableId]))
    }

    func testAuthorityUpsertSaveFailureDoesNotPublishCandidateOrReplaceExistingPin() {
        let stableId = "id:11111111-2222-4333-8444-555555555555"
        let existingFingerprint = String(repeating: "a", count: 64)
        let replacementKey = protocolIdentityKey(.ed25519, seed: 0xB4)
        let replacementFingerprint = protocolIdentityFingerprint(
            algorithm: .ed25519,
            key: replacementKey
        )
        let active = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            ipAddress: nil,
            protocolSigningAlgorithm: "Ed25519",
            protocolPublicKeyFingerprint: existingFingerprint,
            currentDeviceId: stableId,
            currentPathLifecycleState: .active
        )
        let store = TrustedDeviceStore(
            testingLoad: { [active] },
            testingSave: { _ in throw InjectedPersistenceFailure.save }
        )
        let publishedBeforeFailedCommit = store.trustedDevices

        XCTAssertThrowsError(
            try store.upsertCurrentPathAuthority(
                deviceId: stableId,
                name: "Renamed peer",
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: replacementFingerprint,
                protocolPublicKeyBytes: replacementKey
            )
        ) { error in
            XCTAssertTrue(error is TrustedDeviceStore.PersistenceError)
        }
        XCTAssertEqual(store.trustedDevices, publishedBeforeFailedCommit)
        XCTAssertFalse(store.isAuthorityPersistenceAvailable)
        XCTAssertNil(store.currentPathTrustRecord(fingerprint: replacementFingerprint))
    }

    func testStrictLoadFailureDisablesAutomaticTrust() {
        let store = TrustedDeviceStore(
            testingLoad: { throw InjectedPersistenceFailure.load },
            testingSave: { _ in XCTFail("A failed strict load must not attempt a save") }
        )

        XCTAssertTrue(store.trustedDevices.isEmpty)
        XCTAssertFalse(store.isAuthorityPersistenceAvailable)
        XCTAssertFalse(store.isTrusted(deviceId: "id:stale-peer"))
        XCTAssertNotNil(store.persistenceErrorMessage)
    }

    func testCloudActiveRecordCannotResurrectAliasRevocation() throws {
        let stableId = "id:11111111-2222-4333-8444-555555555555"
        let bonjourAlias = "bonjour:Fixture MacBook Pro@local."
        let active = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableId,
            knownDeviceIds: [bonjourAlias],
            currentPathLifecycleState: .active
        )
        var persisted = [active]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        try store.untrust(deviceId: bonjourAlias)
        try store.mergeFromCloud([
            TrustedDeviceStore.TrustedDevice(
                id: stableId,
                name: "Stale Cloud Mac",
                platform: .macOS,
                ipAddress: "192.168.1.99",
                currentDeviceId: stableId,
                knownDeviceIds: [bonjourAlias],
                currentPathLifecycleState: nil
            )
        ])

        XCTAssertEqual(persisted.first?.currentPathLifecycleState, .revoked)
        XCTAssertEqual(persisted.first?.currentPathLifecycleGeneration, 1)
        XCTAssertNil(persisted.first?.ipAddress)
        XCTAssertFalse(store.isTrusted(deviceId: stableId))
        XCTAssertFalse(store.isTrusted(deviceId: bonjourAlias))
    }

    func testEqualGenerationCloudRevocationOutranksActiveState() throws {
        let stableId = "id:equal-generation-authority"
        let active = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Equal generation peer",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableId,
            currentPathLifecycleState: .active,
            currentPathLifecycleGeneration: 0
        )
        let revoked = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Equal generation peer",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableId,
            currentPathLifecycleState: .revoked,
            currentPathLifecycleGeneration: 0
        )
        var persisted = [active]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        try store.mergeFromCloud([revoked])
        XCTAssertEqual(persisted.first?.currentPathLifecycleState, .revoked)
        XCTAssertEqual(persisted.first?.currentPathLifecycleGeneration, 0)

        try store.mergeFromCloud([active])
        XCTAssertEqual(persisted.first?.currentPathLifecycleState, .revoked)
        XCTAssertFalse(store.hasActiveDurableTrust(forAny: [stableId]))
    }

    func testExplicitRePairOutranksOlderCloudRevocationGeneration() throws {
        let stableId = "id:11111111-2222-4333-8444-555555555555"
        let bonjourAlias = "bonjour:Fixture MacBook Pro@local."
        let active = TrustedDeviceStore.TrustedDevice(
            id: stableId,
            name: "Fixture MacBook Pro",
            platform: .macOS,
            ipAddress: nil,
            currentDeviceId: stableId,
            knownDeviceIds: [bonjourAlias],
            currentPathLifecycleState: .active
        )
        var persisted = [active]
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        try store.untrust(deviceId: stableId)
        let cloudRevocation = try XCTUnwrap(store.trustedDevices.first)
        XCTAssertEqual(cloudRevocation.currentPathLifecycleGeneration, 1)

        let explicitlyRePairedDevice = DiscoveredDevice(
            id: bonjourAlias,
            name: "Fixture MacBook Pro",
            bonjourServiceName: "Fixture MacBook Pro",
            modelName: "MacBook Pro",
            platform: .macOS,
            osVersion: "26.5",
            ipAddress: nil,
            bonjourServiceType: "_skybridge._tcp",
            bonjourServiceDomain: "local.",
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527]
        )
        try store.trustResolvedPeer(
            explicitlyRePairedDevice,
            declaredDeviceId: stableId
        )
        XCTAssertEqual(store.trustedDevices.first?.currentPathLifecycleState, .active)
        XCTAssertEqual(store.trustedDevices.first?.currentPathLifecycleGeneration, 2)

        try store.mergeFromCloud([cloudRevocation])

        XCTAssertTrue(store.isTrusted(deviceId: stableId))
        XCTAssertEqual(persisted.first?.currentPathLifecycleState, .active)
        XCTAssertEqual(persisted.first?.currentPathLifecycleGeneration, 2)
    }

    func testUnmatchedEndpointAliasDoesNotCreateDurableTombstone() throws {
        var persisted: [TrustedDeviceStore.TrustedDevice] = []
        let store = TrustedDeviceStore(
            testingLoad: { persisted },
            testingSave: { persisted = $0 }
        )

        _ = try store.untrust(deviceId: "host:192.168.1.20")

        XCTAssertTrue(store.trustedDevices.isEmpty)
        XCTAssertTrue(persisted.isEmpty)
    }

    func testKEMTrustStoreRebindCanonicalDeviceIdClearsLegacyAliases() async {
        let stableId = "id:11111111-2222-4333-8444-555555555555"
        let pollutedId = "id:fixture macbook pro"
        let legacyHostAlias = "host:id:fixture macbook pro"
        let mlkemKey = Data(repeating: 0xAA, count: 1_184)

        await KEMTrustStore.shared.clearForTesting()
        defer {
            Task {
                await KEMTrustStore.shared.clearForTesting()
            }
        }

        await KEMTrustStore.shared.upsert(
            deviceId: pollutedId,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: mlkemKey)]
        )
        await KEMTrustStore.shared.upsert(
            deviceId: legacyHostAlias,
            kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: mlkemKey)]
        )

        await KEMTrustStore.shared.rebindCanonicalDeviceId(
            stableId,
            legacyIdentifiers: [pollutedId, legacyHostAlias]
        )

        let stableKeys = await KEMTrustStore.shared.kemPublicKeys(for: stableId)
        let legacyKeys = await KEMTrustStore.shared.kemPublicKeys(for: legacyHostAlias)

        XCTAssertEqual(stableKeys[CryptoSuite(wireId: 257)], mlkemKey)
        XCTAssertNil(legacyKeys[CryptoSuite(wireId: 257)])
    }
}
