import XCTest
import Security
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class TrustSyncConcurrencyHardeningTests: XCTestCase {
    func testRevocationSignsFinalTombstoneAndBlocksCurrentPathAuthority() async throws {
        let deviceId = "id:revoke-round-trip-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)
        let service = TrustSyncService(
            initialRecordsForTesting: [makeRecord(deviceId: deviceId, fingerprint: fingerprint)]
        )

        try await service.revokeTrustRecord(deviceId: deviceId)

        let storedRecord = await service.rawTrustRecordForTesting(deviceId: deviceId)
        let tombstone = try XCTUnwrap(storedRecord)
        XCTAssertTrue(tombstone.isTombstone)
        XCTAssertEqual(tombstone.lifecycleState, .revoked)
        let signatureIsValid = try await service.verifyRecordSignature(tombstone)
        XCTAssertTrue(signatureIsValid)
        let assessment = try await service.currentPathTrustAssessment(
            deviceId: deviceId,
            protocolPublicKeyFingerprint: fingerprint
        )
        XCTAssertEqual(assessment, .conflict(.revokedIdentity))
    }

    func testRevocationPublishesAliasAndFingerprintInvalidationAfterCommit() async throws {
        let canonicalId = "id:revocation-event-\(UUID().uuidString.lowercased())"
        let aliasId = "bonjour:revocation-event-\(UUID().uuidString.lowercased())@local."
        let fingerprint = String(repeating: "7", count: 64)
        let service = TrustSyncService(
            initialRecordsForTesting: [
                makeRecord(
                    deviceId: canonicalId,
                    fingerprint: fingerprint,
                    knownDeviceIds: [canonicalId, aliasId]
                )
            ]
        )
        var observedEvent: TrustInvalidationEvent?
        let observation = service.trustInvalidationPublisher.sink { event in
            observedEvent = event
        }

        try await service.revokeTrustRecord(deviceId: canonicalId)

        let event = try XCTUnwrap(observedEvent)
        XCTAssertTrue(event.matches(deviceId: canonicalId))
        XCTAssertTrue(event.matches(deviceId: aliasId))
        XCTAssertTrue(event.matches(deviceId: nil, protocolFingerprint: fingerprint))
        withExtendedLifetime(observation) {}
    }

    func testCompleteSignaturePayloadRejectsSecurityFieldTampering() async throws {
        let deviceId = "id:signature-v2-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "6", count: 64)
        let service = TrustSyncService(
            initialRecordsForTesting: [makeRecord(deviceId: deviceId, fingerprint: fingerprint)]
        )
        try await service.revokeTrustRecord(deviceId: deviceId)
        let storedTombstone = await service.rawTrustRecordForTesting(deviceId: deviceId)
        let tombstone = try XCTUnwrap(storedTombstone)
        XCTAssertEqual(tombstone.signaturePayloadVersion, TrustRecord.currentSignaturePayloadVersion)
        let originalSignatureIsValid = try await service.verifyRecordSignature(tombstone)
        XCTAssertTrue(originalSignatureIsValid)

        let tamperedRecords = [
            copyRecord(tombstone, revokedAt: .distantPast),
            copyRecord(tombstone, legacyP256PublicKey: Data(repeating: 0x41, count: 65)),
            copyRecord(tombstone, signatureAlgorithm: .p256ECDSA),
            copyRecord(tombstone, attestationData: Data([0x99]))
        ]
        for tampered in tamperedRecords {
            let tamperedSignatureIsValid = try await service.verifyRecordSignature(tampered)
            XCTAssertFalse(tamperedSignatureIsValid)
        }
        XCTAssertFalse(
            tamperedRecords[0].isExpired,
            "historically-unbound revokedAt must never shorten signed updatedAt retention"
        )
    }

    func testKeyRotationFailureStillInvalidatesDurablyRevokedOldAuthority() async throws {
        let oldId = "id:rotation-old-\(UUID().uuidString.lowercased())"
        let oldAlias = "bonjour:rotation-old-\(UUID().uuidString.lowercased())@local."
        let newId = "id:rotation-new-\(UUID().uuidString.lowercased())"
        let oldFingerprint = String(repeating: "4", count: 64)
        let newFingerprint = String(repeating: "5", count: 64)
        let oldRecord = makeRecord(
            deviceId: oldId,
            fingerprint: oldFingerprint,
            knownDeviceIds: [oldId, oldAlias]
        )
        let blockedNewRecord = makeRecord(deviceId: newId, fingerprint: newFingerprint)
            .revoked(signature: Data(repeating: 0xEE, count: 64), at: Date())
        let service = TrustSyncService(initialRecordsForTesting: [oldRecord, blockedNewRecord])
        var events: [TrustInvalidationEvent] = []
        let observation = service.trustInvalidationPublisher.sink { events.append($0) }
        let certificate = P2PIdentityCertificate(
            deviceId: newId,
            publicKey: Data([0x10]),
            pubKeyFP: newFingerprint,
            attestationLevel: .none,
            capabilities: [],
            signerType: .selfSigned,
            signature: Data([0x20])
        )

        await XCTAssertThrowsErrorAsync {
            try await service.handleKeyRotation(
                oldDeviceId: oldId,
                newDeviceId: newId,
                newCertificate: certificate
            )
        }

        let storedOldRecord = await service.rawTrustRecordForTesting(deviceId: oldId)
        XCTAssertTrue(try XCTUnwrap(storedOldRecord).isTombstone)
        XCTAssertTrue(events.contains { event in
            event.matches(deviceId: oldId)
                && event.matches(deviceId: oldAlias)
                && event.matches(deviceId: newId)
                && event.matches(deviceId: nil, protocolFingerprint: oldFingerprint)
        })
        withExtendedLifetime(observation) {}
    }

    func testCapabilityOnlyAliasDenialSuppressesActiveSnapshot() async throws {
        let activeId = "id:capability-active-\(UUID().uuidString.lowercased())"
        let deniedStorageKey = "legacy-route-\(UUID().uuidString.lowercased())"
        let activeFingerprint = String(repeating: "1", count: 64)
        let deniedFingerprint = String(repeating: "2", count: 64)
        let active = makeRecord(
            deviceId: activeId,
            fingerprint: activeFingerprint,
            capabilities: ["peerEndpoint=\(deniedStorageKey)"]
        )
        let rejected = makeRecord(
            deviceId: deniedStorageKey,
            fingerprint: deniedFingerprint,
            capabilities: ["declaredDeviceId=\(activeId)"]
        ).revoked(signature: Data(repeating: 0xEE, count: 64), at: Date())
        let service = TrustSyncService(
            initialRecordsForTesting: [active],
            rejectedRecordsForTesting: [rejected]
        )

        let trustedSnapshot = try await service.trustedRecordsSnapshot()
        XCTAssertTrue(trustedSnapshot.isEmpty)
        XCTAssertNil(service.getTrustRecord(deviceId: activeId))
    }

    func testClaimedDeviceCannotBorrowDifferentTrustedDeviceFingerprint() {
        let firstId = "id:first-\(UUID().uuidString.lowercased())"
        let secondId = "id:second-\(UUID().uuidString.lowercased())"
        let firstFingerprint = String(repeating: "a", count: 64)
        let secondFingerprint = String(repeating: "b", count: 64)
        let service = TrustSyncService(initialRecordsForTesting: [
            makeRecord(deviceId: firstId, fingerprint: firstFingerprint),
            makeRecord(deviceId: secondId, fingerprint: secondFingerprint)
        ])

        XCTAssertEqual(
            service.evaluateCurrentPathBinding(
                deviceId: secondId,
                protocolPublicKeyFingerprint: firstFingerprint
            ),
            .identityConflict
        )
    }

    func testRejectedRepairKeyCannotExpandDestructiveScopeIntoVerifiedAliases() async throws {
        let verifiedId = "id:verified-safe-\(UUID().uuidString.lowercased())"
        let rejectedKey = "id:rejected-opaque-\(UUID().uuidString.lowercased())"
        let sharedForgedFingerprint = String(repeating: "c", count: 64)
        let verified = makeRecord(
            deviceId: verifiedId,
            fingerprint: sharedForgedFingerprint
        )
        let forgedRejected = makeRecord(
            deviceId: rejectedKey,
            fingerprint: sharedForgedFingerprint,
            knownDeviceIds: [rejectedKey, verifiedId],
            capabilities: ["declaredDeviceId=\(verifiedId)"]
        )
        let service = TrustSyncService(
            initialRecordsForTesting: [verified],
            rejectedRecordsForTesting: [forgedRejected]
        )

        let repairRecord = try XCTUnwrap(service.trustRepairRecords.first)
        XCTAssertEqual(repairRecord.knownDeviceIds, [rejectedKey])
        XCTAssertEqual(repairRecord.pubKeyFP, "")
        XCTAssertNil(repairRecord.deviceName)
        XCTAssertNil(repairRecord.protocolPublicKey)
        XCTAssertNil(repairRecord.kemPublicKeys)
        let structurallyAliasedRepairRecord = TrustRecord(
            deviceId: String(rejectedKey.dropFirst("id:".count)),
            pubKeyFP: sharedForgedFingerprint,
            publicKey: Data(),
            capabilities: ["trust_repair_required"],
            signature: Data(),
            lifecycleState: .quarantined
        )
        let repairGroups = TrustSyncService.buildTrustRepairDisplayGroups(
            from: [repairRecord, structurallyAliasedRepairRecord]
        )
        XCTAssertEqual(repairGroups.count, 2)
        XCTAssertTrue(repairGroups.allSatisfy { $0.relatedRecords.count == 1 })
        try await service.revokeOrRemoveUnverifiableTrust(deviceIds: [rejectedKey])

        let retainedVerifiedRecord = await service.rawTrustRecordForTesting(deviceId: verifiedId)
        XCTAssertTrue(try XCTUnwrap(retainedVerifiedRecord).isAuthenticationEligible)
        let removedRejectedRecord = await service.rawTrustRecordForTesting(deviceId: rejectedKey)
        XCTAssertNil(removedRejectedRecord)
    }

    func testForgetExpandsOnlyThroughVerifiedAliasesAndCannotResurrectActiveTrust() async throws {
        let verifiedId = "id:verified-linked-\(UUID().uuidString.lowercased())"
        let rejectedExactKey = "id:rejected-linked-\(UUID().uuidString.lowercased())"
        let verifiedFingerprint = String(repeating: "6", count: 64)
        let verified = makeRecord(
            deviceId: verifiedId,
            fingerprint: verifiedFingerprint,
            knownDeviceIds: [verifiedId, rejectedExactKey]
        )
        let rejected = makeRecord(
            deviceId: rejectedExactKey,
            fingerprint: String(repeating: "7", count: 64)
        ).revoked(signature: Data(repeating: 0xEE, count: 64), at: Date())
        let service = TrustSyncService(
            initialRecordsForTesting: [verified],
            rejectedRecordsForTesting: [rejected]
        )

        let scope = try await service.verifiedForgetScopeForForget(
            exactDeviceIds: [rejectedExactKey]
        )
        XCTAssertTrue(scope.deviceIds.contains(rejectedExactKey))
        XCTAssertTrue(scope.deviceIds.contains(verifiedId))
        XCTAssertEqual(scope.autoConnectFingerprints, [verifiedFingerprint])

        try await service.revokeOrRemoveUnverifiableTrust(deviceIds: [rejectedExactKey])

        let linkedVerifiedRecord = await service.rawTrustRecordForTesting(deviceId: verifiedId)
        let linkedVerified = try XCTUnwrap(linkedVerifiedRecord)
        XCTAssertTrue(linkedVerified.isTombstone)
        let removedRejected = await service.rawTrustRecordForTesting(
            deviceId: rejectedExactKey
        )
        XCTAssertNil(removedRejected)
        let trustedSnapshot = try await service.trustedRecordsSnapshot()
        XCTAssertTrue(trustedSnapshot.isEmpty)
    }

    func testSameExactKeyRepairRemainsFailClosedAsSignedForget() async throws {
        let deviceId = "id:same-key-repair-\(UUID().uuidString.lowercased())"
        let active = makeRecord(
            deviceId: deviceId,
            fingerprint: String(repeating: "8", count: 64)
        )
        let rejectedCopy = makeRecord(
            deviceId: deviceId,
            fingerprint: String(repeating: "9", count: 64)
        )
        let service = TrustSyncService(
            initialRecordsForTesting: [active],
            rejectedRecordsForTesting: [rejectedCopy]
        )

        try await service.revokeOrRemoveUnverifiableTrust(deviceIds: [deviceId])

        let storedValue = await service.rawTrustRecordForTesting(deviceId: deviceId)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertTrue(stored.isTombstone)
        XCTAssertTrue(service.trustRepairRecords.isEmpty)
        let trustedSnapshot = try await service.trustedRecordsSnapshot()
        XCTAssertTrue(trustedSnapshot.isEmpty)
    }

    func testRejectedLegacyTombstoneRequiresExplicitRepairAcrossAliases() async throws {
        let canonicalId = "id:legacy-revoked-\(UUID().uuidString.lowercased())"
        let aliasId = "bonjour:legacy-revoked-\(UUID().uuidString.lowercased())@local."
        let fingerprint = String(repeating: "b", count: 64)
        let active = makeRecord(
            deviceId: canonicalId,
            fingerprint: fingerprint,
            knownDeviceIds: [canonicalId, aliasId]
        )
        let rejectedTombstone = active.revoked(
            signature: Data(repeating: 0xEE, count: 64),
            at: .distantPast
        )
        let service = TrustSyncService(
            initialRecordsForTesting: [],
            rejectedRecordsForTesting: [rejectedTombstone]
        )

        let rejectedAssessment = try await service.currentPathTrustAssessment(
            deviceId: aliasId,
            protocolPublicKeyFingerprint: fingerprint
        )
        XCTAssertEqual(rejectedAssessment, .conflict(.revokedIdentity))

        do {
            _ = try await service.addTrustRecord(
                makeRecord(deviceId: aliasId, fingerprint: fingerprint)
            )
            XCTFail("rejected authority must not be recreated through an alias")
        } catch let error as TrustSyncError {
            guard case .verificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        try await service.revokeOrRemoveUnverifiableTrust(deviceIds: [canonicalId])
        let repairedAssessment = try await service.currentPathTrustAssessment(
            deviceId: aliasId,
            protocolPublicKeyFingerprint: fingerprint
        )
        XCTAssertEqual(repairedAssessment, .selfAsserted)
        _ = try await service.addTrustRecord(
            makeRecord(deviceId: aliasId, fingerprint: fingerprint)
        )
    }

    func testVerifiedTombstoneBlocksAuthenticatedAuthorityResurrectionAcrossAliasMigration() async throws {
        let canonicalId = "id:verified-revoked-\(UUID().uuidString.lowercased())"
        let aliasId = "bonjour:verified-revoked-\(UUID().uuidString.lowercased())@local."
        let fingerprint = String(repeating: "f", count: 64)
        let active = makeRecord(
            deviceId: aliasId,
            fingerprint: fingerprint,
            currentDeviceId: canonicalId,
            knownDeviceIds: [aliasId, canonicalId]
        )
        let service = TrustSyncService(initialRecordsForTesting: [active])

        try await service.revokeTrustRecord(deviceId: aliasId)
        let storedTombstone = await service.rawTrustRecordForTesting(deviceId: aliasId)
        let tombstone = try XCTUnwrap(storedTombstone)
        XCTAssertTrue(tombstone.isTombstone)
        let signatureIsValid = try await service.verifyRecordSignature(tombstone)
        XCTAssertTrue(signatureIsValid)

        do {
            _ = try await service.recordAuthenticatedRemoteAuthority(
                deviceId: canonicalId,
                preferredCurrentDeviceId: canonicalId,
                knownDeviceIds: [aliasId, canonicalId],
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: fingerprint
            )
            XCTFail("an authenticated alias migration must not resurrect verified revoked trust")
        } catch let error as TrustSyncError {
            guard case .verificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let resurrectedRecord = await service.rawTrustRecordForTesting(deviceId: canonicalId)
        XCTAssertNil(resurrectedRecord)
        let retainedTombstone = await service.rawTrustRecordForTesting(deviceId: aliasId)
        XCTAssertTrue(try XCTUnwrap(retainedTombstone).isTombstone)
    }

    func testRejectedTombstoneSuppressesMatchingAcceptedActiveSnapshot() async throws {
        let canonicalId = "id:mixed-denial-\(UUID().uuidString.lowercased())"
        let aliasId = "bonjour:mixed-denial-\(UUID().uuidString.lowercased())@local."
        let fingerprint = String(repeating: "9", count: 64)
        let accepted = makeRecord(
            deviceId: canonicalId,
            fingerprint: fingerprint,
            knownDeviceIds: [canonicalId, aliasId]
        )
        let rejected = makeRecord(
            deviceId: aliasId,
            fingerprint: fingerprint,
            currentDeviceId: canonicalId,
            knownDeviceIds: [canonicalId, aliasId]
        ).revoked(signature: Data(repeating: 0xEE, count: 64), at: .distantPast)
        let service = TrustSyncService(
            initialRecordsForTesting: [accepted],
            rejectedRecordsForTesting: [rejected]
        )

        let trustedSnapshot = try await service.trustedRecordsSnapshot()
        XCTAssertTrue(trustedSnapshot.isEmpty)
        XCTAssertEqual(service.trustRepairRecords.count, 1)
        XCTAssertEqual(service.trustRepairRecords.first?.lifecycleState, .quarantined)
        XCTAssertTrue(
            service.trustRepairRecords.first?.capabilities.contains("trust_repair_required") == true
        )
        XCTAssertNil(service.getTrustRecord(deviceId: canonicalId))
        XCTAssertFalse(service.isTrusted(deviceId: canonicalId))
        let assessment = try await service.currentPathTrustAssessment(
            deviceId: canonicalId,
            protocolPublicKeyFingerprint: fingerprint
        )
        XCTAssertEqual(assessment, .conflict(.revokedIdentity))
    }

    func testInitialLoadFailureRejectsSecurityAssessmentAndMutation() async throws {
        let service = TrustSyncService(initialLoadOperationForTesting: {
            throw TrustSyncError.keychainError(errSecParam)
        })
        let fingerprint = String(repeating: "c", count: 64)

        do {
            _ = try await service.currentPathTrustAssessment(
                deviceId: "id:unavailable",
                protocolPublicKeyFingerprint: fingerprint
            )
            XCTFail("failed trust-store readiness must reject security assessment")
        } catch let error as TrustSyncError {
            guard case .keychainError(let status) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(status, errSecParam)
        }

        let requiresPinning = await service.requiresPinnedProtocolIdentity(for: "id:unavailable")
        XCTAssertTrue(requiresPinning)
        await XCTAssertThrowsErrorAsync {
            _ = try await service.addTrustRecord(
                self.makeRecord(deviceId: "id:unavailable", fingerprint: fingerprint)
            )
        }
    }

    func testKeychainAccountIdentityMustMatchEmbeddedRecordDeviceId() {
        XCTAssertTrue(
            TrustSyncService.keychainAccount(
                "trust_record_id:expected",
                matchesRecordDeviceId: "id:expected"
            )
        )
        XCTAssertFalse(
            TrustSyncService.keychainAccount(
                "trust_record_id:storage-key",
                matchesRecordDeviceId: "id:payload-key"
            )
        )
    }

    func testAuthenticatedAuthorityMergeNeverUsesDisplayNameAsIdentityAnchor() throws {
        let trustedId = "id:trusted-name-collision-\(UUID().uuidString.lowercased())"
        let incomingId = "id:incoming-name-collision-\(UUID().uuidString.lowercased())"
        let trustedFingerprint = String(repeating: "3", count: 64)
        let incomingPublicKey = Data(repeating: 0x44, count: 32)
        let incomingFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: incomingPublicKey
        )
        let trusted = TrustRecord(
            deviceId: trustedId,
            pubKeyFP: trustedFingerprint,
            publicKey: Data([0x99]),
            protocolPublicKey: Data(repeating: 0x33, count: 32),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: trustedFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: 257,
                    publicKey: Data(repeating: 0x55, count: 1_184)
                )
            ],
            attestationData: Data([0x77]),
            signature: Data([0x01]),
            deviceName: "Shared Office Mac",
            currentDeviceId: trustedId,
            knownDeviceIds: [trustedId],
            lifecycleState: .active
        )

        let resolved = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [trusted],
                deviceId: incomingId,
                displayName: "Shared Office Mac",
                preferredCurrentDeviceId: incomingId,
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: incomingFingerprint,
                authenticatedProtocolPublicKey: incomingPublicKey,
                pinSource: .authenticatedHandshake
            )
        )

        XCTAssertEqual(resolved.deviceId, incomingId)
        XCTAssertTrue(resolved.knownDeviceIds.contains(incomingId))
        XCTAssertEqual(resolved.protocolPublicKey, incomingPublicKey)
        XCTAssertEqual(resolved.pubKeyFP, "")
        XCTAssertNil(resolved.kemPublicKeys)
        XCTAssertNil(resolved.attestationData)
        XCTAssertFalse(resolved.knownDeviceIds.contains(trustedId))
    }

    func testAuthenticatedAuthorityIgnoresIncomingAliasGraftWithoutBorrowingMaterial() async throws {
        let authenticatedId = "id:authenticated-\(UUID().uuidString.lowercased())"
        let victimId = "id:victim-\(UUID().uuidString.lowercased())"
        let victimFingerprint = String(repeating: "a", count: 64)
        let incomingPublicKey = Data(repeating: 0x24, count: 32)
        let incomingFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: incomingPublicKey
        )
        let victim = TrustRecord(
            deviceId: victimId,
            pubKeyFP: victimFingerprint,
            publicKey: Data([0x91]),
            secureEnclavePublicKey: Data([0x92]),
            protocolPublicKey: Data(repeating: 0x33, count: 32),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: victimFingerprint,
            legacyP256PublicKey: Data(repeating: 0x44, count: 65),
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: 257,
                    publicKey: Data(repeating: 0x55, count: 1_184)
                )
            ],
            attestationData: Data([0x93]),
            signature: Data([0x01]),
            currentDeviceId: victimId,
            knownDeviceIds: [victimId],
            lifecycleState: .active
        )

        let resolved = try XCTUnwrap(TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
            existingRecords: [victim],
            deviceId: authenticatedId,
            preferredCurrentDeviceId: authenticatedId,
            knownDeviceIds: [authenticatedId, victimId],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: incomingFingerprint,
            authenticatedProtocolPublicKey: incomingPublicKey
        ))

        XCTAssertEqual(resolved.deviceId, authenticatedId)
        XCTAssertEqual(resolved.protocolPublicKey, incomingPublicKey)
        XCTAssertFalse(resolved.knownDeviceIds.contains(victimId))
        XCTAssertNil(resolved.kemPublicKeys)
        XCTAssertNil(resolved.attestationData)
        XCTAssertNil(resolved.legacyP256PublicKey)

        let service = TrustSyncService(initialRecordsForTesting: [victim])
        let accepted = try await service.recordAuthenticatedRemoteAuthority(
            deviceId: authenticatedId,
            preferredCurrentDeviceId: authenticatedId,
            knownDeviceIds: [authenticatedId, victimId],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: incomingFingerprint,
            authenticatedProtocolPublicKey: incomingPublicKey
        )
        XCTAssertTrue(accepted)
        let retainedVictim = await service.rawTrustRecordForTesting(deviceId: victimId)
        XCTAssertEqual(retainedVictim, victim)
        let storedAuthenticatedRecord = await service.rawTrustRecordForTesting(
            deviceId: authenticatedId
        )
        let storedAuthenticated = try XCTUnwrap(storedAuthenticatedRecord)
        XCTAssertFalse(storedAuthenticated.knownDeviceIds.contains(victimId))
        XCTAssertNil(storedAuthenticated.kemPublicKeys)
        XCTAssertNil(storedAuthenticated.attestationData)
    }

    func testLateAuthenticatedIdentityDoesNotSelectLegacyPreclaimedAlias() throws {
        let squatterId = "id:squatter-\(UUID().uuidString.lowercased())"
        let victimId = "id:late-victim-\(UUID().uuidString.lowercased())"
        let squatter = TrustRecord(
            deviceId: squatterId,
            pubKeyFP: String(repeating: "1", count: 64),
            publicKey: Data([0x71]),
            protocolPublicKey: Data(repeating: 0x72, count: 32),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: String(repeating: "1", count: 64),
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: 257,
                    publicKey: Data(repeating: 0x73, count: 1_184)
                )
            ],
            attestationData: Data([0x74]),
            signature: Data([0x75]),
            currentDeviceId: squatterId,
            knownDeviceIds: [squatterId, victimId],
            lifecycleState: .active
        )
        let victimPublicKey = Data(repeating: 0x62, count: 32)
        let victimFingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: victimPublicKey
        )

        let resolvedVictim = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [squatter],
                deviceId: victimId,
                preferredCurrentDeviceId: victimId,
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: victimFingerprint,
                authenticatedProtocolPublicKey: victimPublicKey
            )
        )

        XCTAssertEqual(resolvedVictim.deviceId, victimId)
        XCTAssertEqual(resolvedVictim.protocolPublicKey, victimPublicKey)
        XCTAssertNil(resolvedVictim.kemPublicKeys)
        XCTAssertNil(resolvedVictim.attestationData)
        XCTAssertFalse(resolvedVictim.knownDeviceIds.contains(squatterId))
    }

    func testForgetFingerprintClosureTombstonesEverySiblingAndInvalidatesEachIdentity() async throws {
        let firstId = "id:fingerprint-sibling-a-\(UUID().uuidString.lowercased())"
        let secondId = "id:fingerprint-sibling-b-\(UUID().uuidString.lowercased())"
        let thirdId = "id:fingerprint-sibling-c-\(UUID().uuidString.lowercased())"
        let sharedProtocolFingerprint = String(repeating: "c", count: 64)
        let sharedLegacyFingerprint = String(repeating: "2", count: 64)
        let first = makeRecord(
            deviceId: firstId,
            legacyFingerprint: String(repeating: "1", count: 64),
            protocolFingerprint: sharedProtocolFingerprint
        )
        let second = makeRecord(
            deviceId: secondId,
            legacyFingerprint: sharedLegacyFingerprint,
            protocolFingerprint: sharedProtocolFingerprint
        )
        let third = makeRecord(
            deviceId: thirdId,
            legacyFingerprint: sharedLegacyFingerprint,
            protocolFingerprint: String(repeating: "e", count: 64)
        )
        let service = TrustSyncService(initialRecordsForTesting: [first, second, third])
        var events: [TrustInvalidationEvent] = []
        let observation = service.trustInvalidationPublisher.sink { events.append($0) }

        let scope = try await service.verifiedForgetScopeForForget(
            exactDeviceIds: [firstId]
        )
        XCTAssertTrue(
            Set(scope.deviceIds).isSuperset(of: Set([firstId, secondId, thirdId]))
        )
        XCTAssertEqual(
            Set(scope.autoConnectFingerprints),
            Set([first.pubKeyFP, second.pubKeyFP, third.pubKeyFP])
        )

        try await service.revokeOrRemoveUnverifiableTrust(
            deviceIds: [firstId],
            expectedScope: scope
        )

        let storedFirst = await service.rawTrustRecordForTesting(deviceId: firstId)
        let storedSecond = await service.rawTrustRecordForTesting(deviceId: secondId)
        let storedThird = await service.rawTrustRecordForTesting(deviceId: thirdId)
        XCTAssertTrue(try XCTUnwrap(storedFirst).isTombstone)
        XCTAssertTrue(try XCTUnwrap(storedSecond).isTombstone)
        XCTAssertTrue(try XCTUnwrap(storedThird).isTombstone)
        XCTAssertTrue(events.contains {
            $0.matches(deviceId: firstId)
                && $0.matches(deviceId: secondId)
                && $0.matches(deviceId: thirdId)
        })
        XCTAssertTrue(events.contains { $0.matches(deviceId: nil, protocolFingerprint: sharedProtocolFingerprint) })

        await service.removeRecordsForTesting(deviceIds: [firstId])
        do {
            _ = try await service.addTrustRecord(first)
            XCTFail("a retained same-key sibling tombstone must block resurrection")
        } catch let error as TrustSyncError {
            guard case .verificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        withExtendedLifetime(observation) {}
    }

    func testDirectRevocationIsIdentityWideAcrossFingerprintOnlySiblings() async throws {
        let firstId = "id:direct-revoke-a-\(UUID().uuidString.lowercased())"
        let secondId = "id:direct-revoke-b-\(UUID().uuidString.lowercased())"
        let sharedFingerprint = String(repeating: "4", count: 64)
        let service = TrustSyncService(initialRecordsForTesting: [
            makeRecord(deviceId: firstId, fingerprint: sharedFingerprint),
            makeRecord(deviceId: secondId, fingerprint: sharedFingerprint)
        ])
        var observedEvents: [TrustInvalidationEvent] = []
        let observation = service.trustInvalidationPublisher.sink {
            observedEvents.append($0)
        }

        try await service.revokeTrustRecord(deviceId: firstId)

        let storedFirst = await service.rawTrustRecordForTesting(deviceId: firstId)
        let storedSecond = await service.rawTrustRecordForTesting(deviceId: secondId)
        XCTAssertTrue(try XCTUnwrap(storedFirst).isTombstone)
        XCTAssertTrue(try XCTUnwrap(storedSecond).isTombstone)
        XCTAssertTrue(observedEvents.contains {
            $0.matches(deviceId: firstId) && $0.matches(deviceId: secondId)
        })
        withExtendedLifetime(observation) {}
    }

    func testForgetRejectsStaleScopeAfterIdentityGraphMutation() async throws {
        let firstId = "id:forget-scope-a-\(UUID().uuidString.lowercased())"
        let secondId = "id:forget-scope-b-\(UUID().uuidString.lowercased())"
        let sharedFingerprint = String(repeating: "d", count: 64)
        let first = makeRecord(deviceId: firstId, fingerprint: sharedFingerprint)
        let second = makeRecord(deviceId: secondId, fingerprint: sharedFingerprint)
        let service = TrustSyncService(initialRecordsForTesting: [first])
        let staleScope = try await service.verifiedForgetScopeForForget(
            exactDeviceIds: [firstId]
        )

        _ = try await service.addTrustRecord(second)

        do {
            try await service.revokeOrRemoveUnverifiableTrust(
                deviceIds: [firstId],
                expectedScope: staleScope
            )
            XCTFail("stale forget scope must not cross a changed identity graph")
        } catch let error as TrustSyncError {
            guard case .forgetScopeChanged = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let retainedFirst = await service.rawTrustRecordForTesting(deviceId: firstId)
        let retainedSecond = await service.rawTrustRecordForTesting(deviceId: secondId)
        XCTAssertTrue(try XCTUnwrap(retainedFirst).isAuthenticationEligible)
        XCTAssertTrue(try XCTUnwrap(retainedSecond).isAuthenticationEligible)
    }

    func testMutationAdmissionIsBoundedAndCancellationRemovesWaiter() async throws {
        let zeroQueueGate = TrustMutationAdmissionGate(maximumWaiters: 0)
        let firstBlocker = TrustMutationTestBlocker()
        let owner = Task { @MainActor in
            try await zeroQueueGate.run {
                await firstBlocker.block()
                return 1
            }
        }
        await firstBlocker.waitUntilEntered()

        do {
            _ = try await zeroQueueGate.run { 2 }
            XCTFail("zero-capacity wait queue must reject immediately")
        } catch let error as TrustSyncError {
            guard case .mutationWaiterLimitExceeded(let maximum) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(maximum, 0)
        }
        await firstBlocker.release()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult, 1)

        let cancellableGate = TrustMutationAdmissionGate(maximumWaiters: 1)
        let secondBlocker = TrustMutationTestBlocker()
        let secondOwner = Task { @MainActor in
            try await cancellableGate.run {
                await secondBlocker.block()
                return 3
            }
        }
        await secondBlocker.waitUntilEntered()
        let waiter = Task { @MainActor in
            try await cancellableGate.run { 4 }
        }
        await cancellableGate.waitUntilPendingWaiterCountForTesting(1)
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("cancelled waiter must not enter the mutation closure")
        } catch is CancellationError {
            // Expected.
        }
        await cancellableGate.waitUntilPendingWaiterCountForTesting(0)
        await secondBlocker.release()
        let secondOwnerResult = try await secondOwner.value
        XCTAssertEqual(secondOwnerResult, 3)

        let deadlineGate = TrustMutationAdmissionGate(
            maximumWaiters: 1,
            maximumWaitDuration: .milliseconds(20)
        )
        let deadlineBlocker = TrustMutationTestBlocker()
        let deadlineOwner = Task { @MainActor in
            try await deadlineGate.run {
                await deadlineBlocker.block()
                return 5
            }
        }
        await deadlineBlocker.waitUntilEntered()
        let expiringWaiter = Task { @MainActor in
            try await deadlineGate.run { 6 }
        }
        await deadlineGate.waitUntilPendingWaiterCountForTesting(1)
        do {
            _ = try await expiringWaiter.value
            XCTFail("expired waiter must not enter the mutation closure")
        } catch let error as TrustSyncError {
            guard case .mutationWaitDeadlineExceeded = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        await deadlineGate.waitUntilPendingWaiterCountForTesting(0)
        await deadlineBlocker.release()
        let deadlineOwnerResult = try await deadlineOwner.value
        let capacityReuseResult = try await deadlineGate.run { 7 }
        XCTAssertEqual(deadlineOwnerResult, 5)
        XCTAssertEqual(capacityReuseResult, 7)
    }

    func testAtomicTransformPreservesMultiPinAuthorityMetadata() async throws {
        let deviceId = "id:atomic-bootstrap-\(UUID().uuidString.lowercased())"
        let firstFingerprint = String(repeating: "d", count: 64)
        let secondFingerprint = String(repeating: "e", count: 64)
        let pins = [
            ProtocolIdentityPin(
                algorithm: .ed25519,
                fingerprint: firstFingerprint,
                source: .authenticatedHandshake
            ),
            ProtocolIdentityPin(
                algorithm: .mlDSA65,
                fingerprint: secondFingerprint,
                source: .pib1OperatorApproval
            )
        ]
        let original = TrustRecord(
            deviceId: deviceId,
            pubKeyFP: firstFingerprint,
            publicKey: Data([0x01]),
            protocolPublicKey: Data([0x02]),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: firstFingerprint,
            protocolIdentityPins: pins,
            signature: Data([0x03]),
            currentDeviceId: deviceId,
            knownDeviceIds: [deviceId],
            lifecycleState: .active
        )
        let service = TrustSyncService(initialRecordsForTesting: [original])

        let updated = try await service.upsertTrustRecordAtomically(deviceId: deviceId) { existing in
            let existing = try XCTUnwrap(existing)
            return TrustRecord(
                deviceId: existing.deviceId,
                pubKeyFP: existing.pubKeyFP,
                publicKey: existing.publicKey,
                protocolPublicKey: existing.protocolPublicKey,
                protocolSigningAlgorithm: existing.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: existing.protocolPublicKeyFingerprint,
                protocolIdentityPins: existing.protocolIdentityPins,
                kemPublicKeys: [
                    KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data(repeating: 0x44, count: 1_184))
                ],
                capabilities: existing.capabilities + ["pqc_bootstrap"],
                signature: Data(),
                currentDeviceId: existing.currentDeviceIdMetadata,
                knownDeviceIds: existing.knownDeviceIdsMetadata,
                lifecycleState: existing.lifecycleStateMetadata
            )
        }

        XCTAssertEqual(updated.currentPathAuthorityPins, original.currentPathAuthorityPins)
        XCTAssertEqual(updated.lifecycleState, .active)
        XCTAssertEqual(updated.kemPublicKeys?.count, 1)
    }

    func testConcurrentAtomicTransformsDoNotLoseEitherUpdate() async throws {
        let deviceId = "id:atomic-concurrent-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "9", count: 64)
        let service = TrustSyncService(
            initialRecordsForTesting: [
                makeRecord(deviceId: deviceId, fingerprint: fingerprint)
            ]
        )

        let first = Task { @MainActor in
            try await service.upsertTrustRecordAtomically(deviceId: deviceId) { existing in
                try Self.recordByAddingCapability(
                    XCTUnwrap(existing),
                    capability: "concurrent-update-a"
                )
            }
        }
        let second = Task { @MainActor in
            try await service.upsertTrustRecordAtomically(deviceId: deviceId) { existing in
                try Self.recordByAddingCapability(
                    XCTUnwrap(existing),
                    capability: "concurrent-update-b"
                )
            }
        }

        _ = try await first.value
        _ = try await second.value
        let finalRecordValue = await service.rawTrustRecordForTesting(deviceId: deviceId)
        let finalRecord = try XCTUnwrap(finalRecordValue)
        XCTAssertTrue(finalRecord.capabilities.contains("concurrent-update-a"))
        XCTAssertTrue(finalRecord.capabilities.contains("concurrent-update-b"))
    }

    private nonisolated static func recordByAddingCapability(
        _ record: TrustRecord,
        capability: String
    ) -> TrustRecord {
        TrustRecord(
            deviceId: record.deviceId,
            pubKeyFP: record.pubKeyFP,
            publicKey: record.publicKey,
            secureEnclavePublicKey: record.secureEnclavePublicKey,
            protocolPublicKey: record.protocolPublicKey,
            protocolSigningAlgorithm: record.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: record.protocolPublicKeyFingerprint,
            protocolIdentityPins: record.protocolIdentityPins,
            legacyP256PublicKey: record.legacyP256PublicKey,
            signatureAlgorithm: record.signatureAlgorithm,
            kemPublicKeys: record.kemPublicKeys,
            attestationLevel: record.attestationLevel,
            attestationData: record.attestationData,
            capabilities: Array(Set(record.capabilities + [capability])).sorted(),
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            version: record.version,
            signature: Data(),
            recordType: record.recordType,
            revokedAt: record.revokedAt,
            deviceName: record.deviceName,
            currentDeviceId: record.currentDeviceIdMetadata,
            knownDeviceIds: record.knownDeviceIdsMetadata,
            lifecycleState: record.lifecycleStateMetadata
        )
    }

    func testPairingAuthoritySupersededAfterSigningNeverReachesDurableState() async throws {
        let service = TrustSyncService(initialRecordsForTesting: [])
        let blocker = TrustMutationTestBlocker()
        let deviceId = "id:pairing-authority-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "a", count: 64)
        var isCurrent = true

        service.pairingAuthorityPostSignBarrierForTesting = {
            await blocker.block()
        }
        defer {
            service.pairingAuthorityPostSignBarrierForTesting = nil
        }

        let task = Task { @MainActor in
            try await service.recordAuthenticatedRemoteAuthorityForPairing(
                deviceId: deviceId,
                displayName: "Pairing Authority",
                preferredCurrentDeviceId: deviceId,
                knownDeviceIds: [deviceId],
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: fingerprint,
                isCurrent: { isCurrent }
            )
        }

        await blocker.waitUntilEntered()
        isCurrent = false
        await blocker.release()

        do {
            _ = try await task.value
            XCTFail("a superseded pairing authority must fail before durable persistence")
        } catch let error as TrustSyncError {
            guard case .pairingAuthorityCommitSuperseded = error else {
                return XCTFail("unexpected trust error: \(error)")
            }
        }
        let persistedRecord = await service.rawTrustRecordForTesting(deviceId: deviceId)
        XCTAssertNil(persistedRecord)
    }

    private func makeRecord(
        deviceId: String,
        fingerprint: String,
        currentDeviceId: String? = nil,
        knownDeviceIds: [String]? = nil,
        capabilities: [String] = []
    ) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: fingerprint,
            publicKey: Data([0x01]),
            protocolPublicKey: Data([0x02]),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fingerprint,
            protocolIdentityPins: [
                ProtocolIdentityPin(
                    algorithm: .ed25519,
                    fingerprint: fingerprint,
                    source: .authenticatedHandshake
                )
            ],
            capabilities: capabilities,
            signature: Data([0x03]),
            currentDeviceId: currentDeviceId ?? deviceId,
            knownDeviceIds: knownDeviceIds ?? [deviceId],
            lifecycleState: .active
        )
    }

    private func makeRecord(
        deviceId: String,
        legacyFingerprint: String,
        protocolFingerprint: String
    ) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: legacyFingerprint,
            publicKey: Data([0x01]),
            protocolPublicKey: Data([0x02]),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: protocolFingerprint,
            protocolIdentityPins: [
                ProtocolIdentityPin(
                    algorithm: .ed25519,
                    fingerprint: protocolFingerprint,
                    source: .authenticatedHandshake
                )
            ],
            signature: Data([0x03]),
            currentDeviceId: deviceId,
            knownDeviceIds: [deviceId],
            lifecycleState: .active
        )
    }

    private func copyRecord(
        _ record: TrustRecord,
        revokedAt: Date? = nil,
        legacyP256PublicKey: Data? = nil,
        signatureAlgorithm: SignatureAlgorithm? = nil,
        attestationData: Data? = nil
    ) -> TrustRecord {
        TrustRecord(
            deviceId: record.deviceId,
            pubKeyFP: record.pubKeyFP,
            publicKey: record.publicKey,
            secureEnclavePublicKey: record.secureEnclavePublicKey,
            protocolPublicKey: record.protocolPublicKey,
            protocolSigningAlgorithm: record.protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: record.protocolPublicKeyFingerprint,
            protocolIdentityPins: record.protocolIdentityPins,
            legacyP256PublicKey: legacyP256PublicKey ?? record.legacyP256PublicKey,
            signatureAlgorithm: signatureAlgorithm ?? record.signatureAlgorithm,
            kemPublicKeys: record.kemPublicKeys,
            attestationLevel: record.attestationLevel,
            attestationData: attestationData ?? record.attestationData,
            capabilities: record.capabilities,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            version: record.version,
            signaturePayloadVersion: record.signaturePayloadVersion,
            signature: record.signature,
            recordType: record.recordType,
            revokedAt: revokedAt ?? record.revokedAt,
            deviceName: record.deviceName,
            currentDeviceId: record.currentDeviceIdMetadata,
            knownDeviceIds: record.knownDeviceIdsMetadata,
            lifecycleState: record.lifecycleStateMetadata
        )
    }
}

private actor TrustMutationTestBlocker {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func block() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
