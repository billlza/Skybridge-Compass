import Security
import Combine
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class TrustSyncConcurrencyHardeningTests: XCTestCase {
    func testInitialLoadBarrierWaitsAndPropagatesFailure() async throws {
        let blocker = TrustSyncTestBlocker()
        let completion = TrustSyncTestCompletion()
        let waitingService = TrustSyncService(initialLoadOperationForTesting: {
            await blocker.block()
        })

        let waitingTask = Task { @MainActor in
            try await waitingService.requireInitialLoadForTesting()
            await completion.markComplete()
        }
        await blocker.waitUntilEntered()
        let completedBeforeRelease = await completion.value()
        XCTAssertFalse(completedBeforeRelease)

        await blocker.release()
        try await waitingTask.value
        let completedAfterRelease = await completion.value()
        XCTAssertTrue(completedAfterRelease)

        // 每次调用最多补发一次全新加载，因此注入的 op 会被多次调用；
        // 只要失败原因还在，失败就必须对每个调用方保持可见（fail closed）。
        let failureState = TrustSyncTestFailureState(shouldFail: true)
        let failedService = TrustSyncService(initialLoadOperationForTesting: {
            if await failureState.shouldFailNow() {
                throw TrustSyncError.keychainError(errSecParam)
            }
        })
        do {
            try await failedService.requireInitialLoadForTesting()
            XCTFail("A failed trust-store load must remain caller-visible")
        } catch let error as TrustSyncError {
            guard case .keychainError(let status) = error else {
                return XCTFail("Unexpected trust load error: \(error)")
            }
            XCTAssertEqual(status, errSecParam)
        }
        XCTAssertFalse(failedService.isLocalStoreAvailable)

        do {
            _ = try await failedService.addTrustRecord(makeRecord(deviceId: "id:unavailable"))
            XCTFail("A mutation must not race past failed initial trust-store loading")
        } catch let error as TrustSyncError {
            guard case .keychainError(let status) = error else {
                return XCTFail("Unexpected mutation error: \(error)")
            }
            XCTAssertEqual(status, errSecParam)
        }
        XCTAssertFalse(failedService.isLocalStoreAvailable)

        // 最终一致：失败原因消除后，下一次调用的单次重试即自愈，
        // 可用性门回到 true，被拦下的 mutation 也随之恢复。
        await failureState.setShouldFail(false)
        try await failedService.requireInitialLoadForTesting()
        XCTAssertTrue(failedService.isLocalStoreAvailable)
        _ = try await failedService.addTrustRecord(makeRecord(deviceId: "id:recovered"))
        XCTAssertNotNil(failedService.getTrustRecord(deviceId: "id:recovered"))
    }

    func testMutationAdmissionIsBoundedAndCancellationAndDeadlineRemoveWaiters() async throws {
        let zeroQueueGate = TrustMutationAdmissionGate(maximumWaiters: 0)
        let firstBlocker = TrustSyncTestBlocker()
        let owner = Task { @MainActor in
            try await zeroQueueGate.run {
                await firstBlocker.block()
                return 1
            }
        }
        await firstBlocker.waitUntilEntered()

        do {
            _ = try await zeroQueueGate.run { 2 }
            XCTFail("A zero-capacity mutation queue must reject immediately")
        } catch let error as TrustSyncError {
            guard case .mutationWaiterLimitExceeded(let maximum) = error else {
                return XCTFail("Unexpected queue error: \(error)")
            }
            XCTAssertEqual(maximum, 0)
        }
        await firstBlocker.release()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult, 1)

        let cancellableGate = TrustMutationAdmissionGate(maximumWaiters: 1)
        let secondBlocker = TrustSyncTestBlocker()
        let secondOwner = Task { @MainActor in
            try await cancellableGate.run {
                await secondBlocker.block()
                return 3
            }
        }
        await secondBlocker.waitUntilEntered()
        let cancelledWaiter = Task { @MainActor in
            try await cancellableGate.run { 4 }
        }
        await cancellableGate.waitUntilPendingWaiterCountForTesting(1)
        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("A cancelled waiter must never enter the mutation closure")
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
        let deadlineBlocker = TrustSyncTestBlocker()
        let deadlineOwner = Task { @MainActor in
            try await deadlineGate.run {
                await deadlineBlocker.block()
                return 5
            }
        }
        await deadlineBlocker.waitUntilEntered()
        let expiredWaiter = Task { @MainActor in
            try await deadlineGate.run { 6 }
        }
        await deadlineGate.waitUntilPendingWaiterCountForTesting(1)
        do {
            _ = try await expiredWaiter.value
            XCTFail("An expired waiter must never enter the mutation closure")
        } catch let error as TrustSyncError {
            guard case .mutationWaitDeadlineExceeded = error else {
                return XCTFail("Unexpected deadline error: \(error)")
            }
        }
        await deadlineGate.waitUntilPendingWaiterCountForTesting(0)
        await deadlineBlocker.release()
        let deadlineOwnerResult = try await deadlineOwner.value
        let reusedCapacityResult = try await deadlineGate.run { 7 }
        XCTAssertEqual(deadlineOwnerResult, 5)
        XCTAssertEqual(reusedCapacityResult, 7)
    }

    func testAliasCleanupFailureIsExplicitAfterAuthoritativeCommit() async throws {
        let suffix = UUID().uuidString.lowercased()
        let canonicalDeviceId = "id:\(suffix)"
        let aliasDeviceId = "bonjour:skybridge-\(suffix)@local."
        let fingerprint = String(repeating: "a", count: 64)
        let aliasRecord = makeRecord(
            deviceId: aliasDeviceId,
            fingerprint: fingerprint,
            currentDeviceId: canonicalDeviceId,
            knownDeviceIds: [canonicalDeviceId, aliasDeviceId]
        )
        let service = TrustSyncService(initialRecordsForTesting: [aliasRecord])
        service.aliasRecordDeletionForTesting = { _ in
            throw TrustSyncError.keychainError(errSecAuthFailed)
        }
        defer { service.aliasRecordDeletionForTesting = nil }

        do {
            _ = try await service.recordAuthenticatedRemoteAuthority(
                deviceId: aliasDeviceId,
                displayName: "Remote Device",
                preferredCurrentDeviceId: canonicalDeviceId,
                knownDeviceIds: [canonicalDeviceId, aliasDeviceId],
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: fingerprint
            )
            XCTFail("Post-commit alias cleanup failure must not be reported as full success")
        } catch let error as TrustSyncError {
            guard case .aliasCleanupFailedAfterAuthoritativeCommit = error else {
                return XCTFail("Unexpected alias cleanup error: \(error)")
            }
        }

        XCTAssertNotNil(
            service.getTrustRecord(deviceId: canonicalDeviceId),
            "The explicit post-commit error must not pretend the authoritative commit rolled back"
        )
        XCTAssertNotNil(
            service.getTrustRecord(deviceId: aliasDeviceId),
            "A failed alias deletion must leave the alias visible for a later repair"
        )
    }

    func testFinalTombstoneSignatureBindsEverySecuritySensitiveField() async throws {
        let deviceId = "id:revoke-round-trip-\(UUID().uuidString.lowercased())"
        let service = TrustSyncService(initialRecordsForTesting: [
            makeRecord(deviceId: deviceId)
        ])

        try await service.revokeTrustRecord(deviceId: deviceId)

        let storedRecord = await service.rawTrustRecordForTesting(deviceId: deviceId)
        let tombstone = try XCTUnwrap(storedRecord)
        XCTAssertTrue(tombstone.isTombstone)
        XCTAssertEqual(
            tombstone.signaturePayloadVersion,
            TrustRecord.currentSignaturePayloadVersion
        )
        let originalSignatureIsValid = try await service.verifyRecordSignature(tombstone)
        XCTAssertTrue(originalSignatureIsValid)

        let tamperedRecords = [
            copyRecord(tombstone, revokedAt: .distantPast),
            copyRecord(tombstone, legacyP256PublicKey: Data(repeating: 0x41, count: 65)),
            copyRecord(tombstone, signatureAlgorithm: .p256ECDSA),
            copyRecord(tombstone, attestationData: Data([0x99])),
        ]
        for tamperedRecord in tamperedRecords {
            let tamperedSignatureIsValid = try await service.verifyRecordSignature(tamperedRecord)
            XCTAssertFalse(tamperedSignatureIsValid)
        }
        XCTAssertFalse(
            tamperedRecords[0].isExpired,
            "Historically unbound revokedAt must never shorten signed updatedAt retention"
        )
    }

    func testCancellationAfterSigningCannotReachPersistence() async throws {
        let service = TrustSyncService(initialRecordsForTesting: [])
        let blocker = TrustSyncTestBlocker()
        let deviceId = "id:cancelled-after-sign-\(UUID().uuidString.lowercased())"
        service.mutationPostSignBarrierForTesting = {
            await blocker.block()
        }
        defer { service.mutationPostSignBarrierForTesting = nil }

        let task = Task { @MainActor in
            try await service.addTrustRecord(makeRecord(deviceId: deviceId))
        }
        await blocker.waitUntilEntered()
        task.cancel()
        await blocker.release()

        do {
            _ = try await task.value
            XCTFail("A mutation cancelled after signing must fail before persistence")
        } catch is CancellationError {
            // Expected.
        }
        let persistedRecord = await service.rawTrustRecordForTesting(deviceId: deviceId)
        XCTAssertNil(persistedRecord)
    }

    func testRevocationSynchronouslyPublishesOnlyExactProtocolAuthorities() async throws {
        let deviceId = "id:invalidation-\(UUID().uuidString.lowercased())"
        let ed25519Fingerprint = String(repeating: "4", count: 64)
        let mlDSAFingerprint = String(repeating: "5", count: 64)
        let record = TrustRecord(
            deviceId: deviceId,
            pubKeyFP: String(repeating: "6", count: 64),
            publicKey: Data(),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: ed25519Fingerprint,
            protocolIdentityPins: [
                ProtocolIdentityPin(
                    algorithm: .ed25519,
                    fingerprint: ed25519Fingerprint,
                    source: .authenticatedHandshake
                ),
                ProtocolIdentityPin(
                    algorithm: .mlDSA65,
                    fingerprint: mlDSAFingerprint,
                    source: .authenticatedHandshake
                ),
            ],
            signature: Data(repeating: 0xAA, count: 64),
            currentDeviceId: deviceId,
            knownDeviceIds: [deviceId],
            lifecycleState: .active
        )
        let service = TrustSyncService(initialRecordsForTesting: [record])
        var observedEvents: [TrustInvalidationEvent] = []
        let cancellable = service.trustInvalidationPublisher.sink { event in
            observedEvents.append(event)
        }

        try await service.revokeTrustRecord(deviceId: deviceId)

        XCTAssertEqual(observedEvents.count, 1)
        let event = try XCTUnwrap(observedEvents.first)
        XCTAssertTrue(
            event.matches(
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: ed25519Fingerprint.uppercased()
            )
        )
        XCTAssertTrue(
            event.matches(
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: mlDSAFingerprint
            )
        )
        XCTAssertFalse(
            event.matches(
                protocolSigningAlgorithm: .mlDSA65,
                protocolPublicKeyFingerprint: ed25519Fingerprint
            ),
            "A matching fingerprint under another algorithm is not the revoked authority"
        )
        XCTAssertFalse(
            event.matches(
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "7", count: 64)
            )
        )
        withExtendedLifetime(cancellable) {}
    }

    func testTrustInvalidationSubscribersRequireExactAuthorityAndCurrentOwnership() throws {
        let p2p = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )
        XCTAssertTrue(p2p.contains("TrustSyncService.shared.trustInvalidationPublisher"))
        XCTAssertTrue(p2p.contains("connection.matchesTrustInvalidation(event)"))
        XCTAssertTrue(p2p.contains("authenticatedConnections[key] === connection"))
        XCTAssertTrue(p2p.contains("event.matches(authority: authority)"))
        XCTAssertTrue(p2p.contains("authenticatedAuthority: authenticatedRemoteAuthority"))
        XCTAssertTrue(
            p2p.contains(
                "authenticatedRemoteAuthority = resolvedRemoteAuthority\n                    // Bind invalidation ownership"
            )
        )

        let crossNetwork = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        XCTAssertTrue(crossNetwork.contains("TrustSyncService.shared.trustInvalidationPublisher"))
        XCTAssertTrue(crossNetwork.contains("protocolSigningAlgorithm: authority.protocolSigningAlgorithm"))
        XCTAssertTrue(crossNetwork.contains("protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint"))
        XCTAssertTrue(crossNetwork.contains("webrtcSessionsBySessionId[sessionID] === session"))
        XCTAssertTrue(
            crossNetwork.contains(
                "currentPathExpectedRemoteAuthorityBySessionId[sessionID] == authority"
            )
        )

        let remoteControl = try repositorySource(
            "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"
        )
        XCTAssertTrue(remoteControl.contains("TrustSyncService.shared.trustInvalidationPublisher"))
        XCTAssertTrue(remoteControl.contains("event.matches(authority: authority)"))
        XCTAssertTrue(remoteControl.contains("currentPeer(for: peer.role, deviceId: peer.id) === peer"))
        let synchronousRetirement = try XCTUnwrap(
            remoteControl.range(of: "retireConnectionClosedResources(\n                peer: peer")
        )
        let deferredClose = try XCTUnwrap(
            remoteControl.range(of: "Task { @MainActor [weak self]", range: synchronousRetirement.upperBound..<remoteControl.endIndex)
        )
        XCTAssertLessThan(synchronousRetirement.lowerBound, deferredClose.lowerBound)
    }

    func testKeychainAccountMustMatchEmbeddedRecordIdentity() {
        XCTAssertTrue(
            TrustSyncService.keychainAccount(
                "trust_record_id:expected",
                matchesRecordDeviceId: "id:expected"
            )
        )
        XCTAssertFalse(
            TrustSyncService.keychainAccount(
                "trust_record_id:other",
                matchesRecordDeviceId: "id:expected"
            )
        )
        XCTAssertFalse(
            TrustSyncService.keychainAccount(
                "id:expected",
                matchesRecordDeviceId: "id:expected"
            )
        )
    }

    func testAuthenticatedAuthorityDoesNotUseDisplayNameAsIdentityAnchor() throws {
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
                authenticatedProtocolPublicKey: incomingPublicKey
            )
        )

        XCTAssertEqual(resolved.deviceId, incomingId)
        XCTAssertEqual(resolved.protocolPublicKey, incomingPublicKey)
        XCTAssertEqual(resolved.pubKeyFP, "")
        XCTAssertNil(resolved.kemPublicKeys)
        XCTAssertNil(resolved.attestationData)
        XCTAssertFalse(resolved.knownDeviceIds.contains(trustedId))
    }

    func testIncomingAliasGraftCannotBorrowOrDeleteAnotherAuthority() async throws {
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
        XCTAssertEqual(storedAuthenticated.protocolPublicKey, incomingPublicKey)
        XCTAssertFalse(storedAuthenticated.knownDeviceIds.contains(victimId))
        XCTAssertNil(storedAuthenticated.kemPublicKeys)
        XCTAssertNil(storedAuthenticated.attestationData)
        XCTAssertNil(storedAuthenticated.legacyP256PublicKey)
    }

    func testConcurrentAtomicTransformsDoNotLoseEitherUpdate() async throws {
        let deviceId = "id:atomic-merge-\(UUID().uuidString.lowercased())"
        let service = TrustSyncService(initialRecordsForTesting: [
            makeRecord(deviceId: deviceId)
        ])

        let first = Task { @MainActor in
            try await service.upsertTrustRecordAtomically(deviceId: deviceId) { existing in
                guard let existing else { throw TrustSyncError.recordNotFound }
                return Self.recordByAddingCapability(
                    existing,
                    capability: "first-atomic-update"
                )
            }
        }
        let second = Task { @MainActor in
            try await service.upsertTrustRecordAtomically(deviceId: deviceId) { existing in
                guard let existing else { throw TrustSyncError.recordNotFound }
                return Self.recordByAddingCapability(
                    existing,
                    capability: "second-atomic-update"
                )
            }
        }
        _ = try await first.value
        _ = try await second.value

        let storedRecord = await service.rawTrustRecordForTesting(deviceId: deviceId)
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertTrue(stored.capabilities.contains("first-atomic-update"))
        XCTAssertTrue(stored.capabilities.contains("second-atomic-update"))
    }

    func testVerifiedTombstoneBlocksFingerprintResurrectionUnderNewAlias() async throws {
        let revokedId = "id:revoked-authority-\(UUID().uuidString.lowercased())"
        let replacementId = "id:replacement-alias-\(UUID().uuidString.lowercased())"
        let fingerprint = String(repeating: "d", count: 64)
        let tombstone = makeRecord(
            deviceId: revokedId,
            fingerprint: fingerprint
        ).revoked(signature: Data(repeating: 0xEE, count: 64))
        let service = TrustSyncService(initialRecordsForTesting: [tombstone])

        do {
            _ = try await service.addTrustRecord(
                makeRecord(deviceId: replacementId, fingerprint: fingerprint)
            )
            XCTFail("A verified tombstone must block authority resurrection under a new alias")
        } catch let error as TrustSyncError {
            guard case .verificationFailed = error else {
                return XCTFail("Unexpected resurrection error: \(error)")
            }
        }
        let replacement = await service.rawTrustRecordForTesting(deviceId: replacementId)
        XCTAssertNil(replacement)
    }

    func testLocalLoadSkipsUnverifiableRecordsRetainsTombstoneDenialsAndFailsClosedOnHardFailure() async throws {
        let service = TrustSyncService(initialRecordsForTesting: [])
        let suffix = UUID().uuidString.lowercased()
        let firstId = "id:load-first-\(suffix)"
        let secondId = "id:load-second-\(suffix)"
        let bogusId = "id:load-bogus-\(suffix)"
        let firstFingerprint = String(repeating: "1", count: 64)
        let verifiableRecords = [
            try await locallySignedRecord(
                service: service,
                deviceId: firstId,
                fingerprint: firstFingerprint
            ),
            try await locallySignedRecord(
                service: service,
                deviceId: secondId,
                fingerprint: String(repeating: "2", count: 64)
            ),
        ]
        let unverifiableRecord = makeRecord(
            deviceId: bogusId,
            fingerprint: String(repeating: "3", count: 64)
        )

        // N 条中 1 条不可验证（非 tombstone）：其余 N-1 条照常加载，store 保持可用。
        try await service.loadLocalRecordsForTesting(
            keychainRecords: { verifiableRecords + [unverifiableRecord] }
        )
        XCTAssertTrue(service.isLocalStoreAvailable)
        XCTAssertNotNil(service.getTrustRecord(deviceId: firstId))
        XCTAssertNotNil(service.getTrustRecord(deviceId: secondId))
        XCTAssertNil(service.getTrustRecord(deviceId: bogusId))
        XCTAssertTrue(service.isTrusted(deviceId: firstId))
        XCTAssertFalse(service.isTrusted(deviceId: bogusId))
        let activeAfterSkip = await service.getActiveTrustRecords()
        XCTAssertEqual(Set(activeAfterSkip.map(\.deviceId)), [firstId, secondId])

        // 不可验证的 tombstone（iCloud 异设备撤销）保留为仅拒绝记录：
        // 不进入认证面，但仍按 monotonic revocation 阻止同一 authority 复活。
        let revokedId = "id:load-revoked-\(suffix)"
        let revokedFingerprint = String(repeating: "4", count: 64)
        let foreignTombstone = makeRecord(
            deviceId: revokedId,
            fingerprint: revokedFingerprint
        ).revoked(signature: Data(repeating: 0xEE, count: 64))
        try await service.loadLocalRecordsForTesting(
            keychainRecords: { verifiableRecords + [foreignTombstone] }
        )
        XCTAssertTrue(service.isLocalStoreAvailable)
        let retainedTombstone = await service.rawTrustRecordForTesting(deviceId: revokedId)
        XCTAssertEqual(retainedTombstone, foreignTombstone)
        XCTAssertNil(service.getTrustRecord(deviceId: revokedId))
        XCTAssertFalse(service.isTrusted(deviceId: revokedId))
        do {
            _ = try await service.addTrustRecord(
                makeRecord(deviceId: "id:load-resurrect-\(suffix)", fingerprint: revokedFingerprint)
            )
            XCTFail("A deny-only tombstone must still block authority resurrection")
        } catch let error as TrustSyncError {
            guard case .verificationFailed = error else {
                return XCTFail("Unexpected resurrection error: \(error)")
            }
        }

        // keychain 硬失败（store 不可读）：同步准入读取一律 fail closed。
        do {
            try await service.loadLocalRecordsForTesting(
                keychainRecords: { throw TrustSyncError.keychainError(errSecIO) }
            )
            XCTFail("A hard keychain failure must surface as a load failure")
        } catch let error as TrustSyncError {
            guard case .keychainError(let status) = error else {
                return XCTFail("Unexpected hard-failure error: \(error)")
            }
            XCTAssertEqual(status, errSecIO)
        }
        XCTAssertFalse(service.isLocalStoreAvailable)
        XCTAssertEqual(
            service.evaluateCurrentPathBinding(
                deviceId: firstId,
                protocolPublicKeyFingerprint: firstFingerprint
            ),
            .quarantinedIdentity
        )
        XCTAssertFalse(service.isTrusted(deviceId: firstId))
        XCTAssertNil(service.getTrustRecord(deviceId: firstId))
        let activeWhileUnavailable = await service.getActiveTrustRecords()
        XCTAssertTrue(activeWhileUnavailable.isEmpty)

        // 失败原因清除后，一次成功加载即恢复可用性与准入判定。
        try await service.loadLocalRecordsForTesting(keychainRecords: { verifiableRecords })
        XCTAssertTrue(service.isLocalStoreAvailable)
        XCTAssertNotNil(service.getTrustRecord(deviceId: firstId))
        XCTAssertNil(
            service.evaluateCurrentPathBinding(
                deviceId: firstId,
                protocolPublicKeyFingerprint: firstFingerprint
            )
        )
    }

    /// 用本机身份密钥对 legacy 安全字段状态的记录做真实签名，
    /// 使其能通过 verifyRecordSignature 的本地加载验证。
    private func locallySignedRecord(
        service: TrustSyncService,
        deviceId: String,
        fingerprint: String
    ) async throws -> TrustRecord {
        let unsigned = makeRecord(deviceId: deviceId, fingerprint: fingerprint)
        let payload = try service.recordSignaturePayloadForTesting(
            unsigned,
            includeProtocolIdentityPins: true,
            includeProtocolIdentityBindingsV2: true
        )
        let signature = try await DeviceIdentityKeyManager.shared.sign(data: payload)
        return copyRecord(unsigned, signature: signature)
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
            protocolIdentityBindingsV2: record.protocolIdentityBindingsV2,
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

    private func makeRecord(
        deviceId: String,
        fingerprint: String = String(repeating: "b", count: 64),
        currentDeviceId: String? = nil,
        knownDeviceIds: [String]? = nil
    ) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: String(repeating: "c", count: 64),
            publicKey: Data(),
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fingerprint,
            signature: Data(repeating: 0xAA, count: 64),
            deviceName: "Test Device",
            currentDeviceId: currentDeviceId ?? deviceId,
            knownDeviceIds: knownDeviceIds ?? [deviceId],
            lifecycleState: .active
        )
    }

    private func copyRecord(
        _ record: TrustRecord,
        revokedAt: Date? = nil,
        legacyP256PublicKey: Data? = nil,
        signatureAlgorithm: SignatureAlgorithm? = nil,
        attestationData: Data? = nil,
        capabilities: [String]? = nil,
        signature: Data? = nil
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
            protocolIdentityBindingsV2: record.protocolIdentityBindingsV2,
            legacyP256PublicKey: legacyP256PublicKey ?? record.legacyP256PublicKey,
            signatureAlgorithm: signatureAlgorithm ?? record.signatureAlgorithm,
            kemPublicKeys: record.kemPublicKeys,
            attestationLevel: record.attestationLevel,
            attestationData: attestationData ?? record.attestationData,
            capabilities: capabilities ?? record.capabilities,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            version: record.version,
            signaturePayloadVersion: record.signaturePayloadVersion,
            signature: signature ?? record.signature,
            recordType: record.recordType,
            revokedAt: revokedAt ?? record.revokedAt,
            deviceName: record.deviceName,
            currentDeviceId: record.currentDeviceIdMetadata,
            knownDeviceIds: record.knownDeviceIdsMetadata,
            lifecycleState: record.lifecycleStateMetadata
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

private actor TrustSyncTestBlocker {
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

private actor TrustSyncTestCompletion {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func value() -> Bool {
        isComplete
    }
}

private actor TrustSyncTestFailureState {
    private var shouldFail: Bool

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func shouldFailNow() -> Bool {
        shouldFail
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }
}
