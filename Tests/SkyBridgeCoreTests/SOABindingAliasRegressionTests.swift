import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class SOABindingAliasRegressionTests: XCTestCase {
    func testAliasMixKeepsInitiatorBindingAndPairKeyStable() throws {
        let localUUID = "11111111-1111-1111-1111-111111111111"
        let remoteUUID = "22222222-2222-2222-2222-222222222222"
        let localAliases = [
            "id:\(localUUID)",
            "recent:id:\(localUUID)"
        ]
        let remoteAliases = [
            "id:\(remoteUUID)",
            "recent:id:\(remoteUUID)"
        ]

        let canonicalLocalPeerId = PeerSessionArbiter.soaPeerId(from: localAliases[0])
        let canonicalRemotePeerId = PeerSessionArbiter.soaPeerId(from: remoteAliases[0])
        let expectedPairKey = PeerSessionArbiter.pairKey(
            localPeerId: canonicalLocalPeerId,
            remotePeerId: canonicalRemotePeerId
        )

        for alias in localAliases {
            XCTAssertEqual(PeerSessionArbiter.soaPeerId(from: alias), canonicalLocalPeerId)
        }
        for alias in remoteAliases {
            XCTAssertEqual(PeerSessionArbiter.soaPeerId(from: alias), canonicalRemotePeerId)
            XCTAssertEqual(
                PeerSessionArbiter.pairKey(localIdentifier: localAliases[0], remoteIdentifier: alias),
                expectedPairKey
            )
        }

        let messageA = try makeMessageA(
            initiatorPeerId: canonicalRemotePeerId,
            targetPeerId: canonicalLocalPeerId,
            attemptId: Data(repeating: 0x33, count: 16)
        )
        for alias in localAliases {
            let binding = InboundHandshakeAdapter.bindSOAState(
                from: messageA,
                localPeerIdentifier: alias
            )
            XCTAssertTrue(binding.usedAuthenticatedInitiator)
            XCTAssertEqual(binding.expectedRemotePeerId, canonicalRemotePeerId)
            XCTAssertEqual(binding.pairKey, expectedPairKey)
        }
    }

    func testSyntheticBonjourAndHostUUIDsDoNotCollapseToStableDeviceId() {
        let uuid = "33333333-3333-3333-3333-333333333333"
        let canonicalId = PeerSessionArbiter.canonicalSOAIdentifier("id:\(uuid)")

        XCTAssertEqual(canonicalId, uuid)
        XCTAssertNotEqual(
            PeerSessionArbiter.canonicalSOAIdentifier("bonjour:\(uuid)@local."),
            canonicalId
        )
        XCTAssertNotEqual(
            PeerSessionArbiter.canonicalSOAIdentifier("host:\(uuid)"),
            canonicalId
        )
    }

    func testEmbeddedUUIDCannotCollideWithExactStableIdentifier() {
        let uuid = "44444444-4444-4444-8444-444444444444"
        let canonicalUUID = PeerSessionArbiter.canonicalSOAIdentifier(uuid)

        for attackerControlledIdentifier in [
            "attacker-\(uuid)-suffix",
            "id:attacker-\(uuid)-suffix",
            "recent:mac:id:attacker-\(uuid)-suffix",
        ] {
            XCTAssertNotEqual(
                PeerSessionArbiter.canonicalSOAIdentifier(attackerControlledIdentifier),
                canonicalUUID
            )
            XCTAssertNotEqual(
                PeerSessionArbiter.soaPeerId(from: attackerControlledIdentifier),
                PeerSessionArbiter.soaPeerId(from: uuid)
            )
        }
    }

    func testAllowlistedExactUUIDAliasesRemainCanonical() {
        let uppercaseUUID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let canonicalUUID = uppercaseUUID.lowercased()

        for alias in [
            uppercaseUUID,
            "id:\(uppercaseUUID)",
            "recent:id:\(uppercaseUUID)",
            "recent:mac:id:\(uppercaseUUID)",
        ] {
            XCTAssertEqual(
                PeerSessionArbiter.canonicalSOAIdentifier(alias),
                canonicalUUID
            )
            XCTAssertEqual(
                PeerSessionArbiter.soaPeerId(from: alias),
                PeerSessionArbiter.soaPeerId(from: canonicalUUID)
            )
        }
    }

    func testSupersedeRequiresAuthenticatedIncoming() async {
        let arbiter = PeerSessionArbiter()
        let localPeerId = Data(repeating: 0xF0, count: 32)
        let remotePeerId = Data(repeating: 0x01, count: 32)
        let pairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: remotePeerId)
        let localAttemptId = Data(repeating: 0xAA, count: 16)
        let remoteAttemptId = Data(repeating: 0xBB, count: 16)

        let register = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: localAttemptId,
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted = register else {
            XCTFail("Expected outgoing registration to succeed")
            return
        }

        let unauthenticatedDecision = await arbiter.evaluateIncoming(
            pairKey: pairKey,
            remoteInitiatorPeerId: remotePeerId,
            remoteAttemptId: remoteAttemptId,
            targetPeerId: localPeerId,
            expectedRemotePeerId: remotePeerId,
            localPeerId: localPeerId,
            authenticationState: .unauthenticated
        )
        if case .rejectBinding = unauthenticatedDecision {
            // expected
        } else {
            XCTFail("Expected unauthenticated incoming handshake to be rejected before supersede")
        }

        let authenticatedDecision = await arbiter.evaluateIncoming(
            pairKey: pairKey,
            remoteInitiatorPeerId: remotePeerId,
            remoteAttemptId: remoteAttemptId,
            targetPeerId: localPeerId,
            expectedRemotePeerId: remotePeerId,
            localPeerId: localPeerId,
            authenticationState: .authenticated
        )
        switch authenticatedDecision {
        case .acceptAndSupersedeLocal(let winnerPeerId, let winnerAttemptId):
            XCTAssertEqual(winnerPeerId, remotePeerId)
            XCTAssertEqual(winnerAttemptId, remoteAttemptId)
        default:
            XCTFail("Expected authenticated incoming handshake to supersede local attempt")
        }
    }

    func testEstablishedReplacementRequiresAuthenticatedBoundIncoming() async throws {
        let arbiter = PeerSessionArbiter()
        let localPeerId = Data(repeating: 0x10, count: 32)
        let remotePeerId = Data(repeating: 0x20, count: 32)
        let forgedTargetPeerId = Data(repeating: 0x30, count: 32)
        let pairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: remotePeerId)

        let initialRegistration = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x3F, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted(let initialReservation) = initialRegistration else {
            XCTFail("Expected initial owner registration")
            return
        }
        let initialLease = try await arbiter.commitEstablished(
            initialReservation,
            sessionId: "initial-session"
        )
        let unauthenticatedDecision = await arbiter.evaluateIncoming(
            pairKey: pairKey,
            remoteInitiatorPeerId: remotePeerId,
            remoteAttemptId: Data(repeating: 0x40, count: 16),
            targetPeerId: localPeerId,
            expectedRemotePeerId: remotePeerId,
            localPeerId: localPeerId,
            authenticationState: .unauthenticated,
            establishedPolicy: .replaceAuthenticated
        )
        XCTAssertEqualDecision(unauthenticatedDecision, .rejectBinding)

        let forgedBindingDecision = await arbiter.evaluateIncoming(
            pairKey: pairKey,
            remoteInitiatorPeerId: remotePeerId,
            remoteAttemptId: Data(repeating: 0x41, count: 16),
            targetPeerId: forgedTargetPeerId,
            expectedRemotePeerId: remotePeerId,
            localPeerId: localPeerId,
            authenticationState: .authenticated,
            establishedPolicy: .replaceAuthenticated
        )
        XCTAssertEqualDecision(forgedBindingDecision, .rejectBinding)

        let authenticatedDecision = await arbiter.evaluateIncomingWithReservation(
            pairKey: pairKey,
            remoteInitiatorPeerId: remotePeerId,
            remoteAttemptId: Data(repeating: 0x42, count: 16),
            targetPeerId: localPeerId,
            expectedRemotePeerId: remotePeerId,
            localPeerId: localPeerId,
            authenticationState: .authenticated,
            establishedPolicy: .replaceAuthenticated
        )
        guard case .acceptAndReplaceEstablished(let replacementReservation) = authenticatedDecision else {
            XCTFail("Expected authenticated replacement reservation")
            return
        }

        let reconnectBeforeCommit = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x43, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .alreadyConnected = reconnectBeforeCommit else {
            XCTFail("Replacement admission must retain the old owner until CAS commit")
            return
        }
        let replacementLease = try await arbiter.commitEstablished(
            replacementReservation,
            sessionId: "replacement-session"
        )
        let initialLeaseCleared = await arbiter.clearEstablished(initialLease)
        let replacementLeaseCleared = await arbiter.clearEstablished(replacementLease)
        XCTAssertFalse(initialLeaseCleared)
        XCTAssertTrue(replacementLeaseCleared)
    }

    func testSupersedeReasonIsFixedToConcurrentAttempt() {
        let winnerPeerId = Data([0x10, 0x20, 0x30])
        let winnerAttemptId = Data([0xAA, 0xBB, 0xCC])
        let reason = PeerSessionArbiter.supersededFailureReason(
            winnerPeerId: winnerPeerId,
            winnerAttemptId: winnerAttemptId
        )

        switch reason {
        case .supersededByConcurrentAttempt(let winnerPeerHex, let winnerAttemptHex):
            XCTAssertEqual(winnerPeerHex, "102030")
            XCTAssertEqual(winnerAttemptHex, "aabbcc")
        default:
            XCTFail("Supersede must map to supersededByConcurrentAttempt")
        }
    }

    func testEstablishedGuardCanBeReleasedForRekeyAndRestoredOnFailure() async {
        let arbiter = PeerSessionArbiter()
        let localPeerId = Data(repeating: 0x11, count: 32)
        let remotePeerId = Data(repeating: 0x22, count: 32)
        let pairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: remotePeerId)

        await arbiter.markEstablished(pairKey: pairKey)

        let blocked = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0xA1, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .alreadyConnected = blocked else {
            XCTFail("Expected established guard to block duplicate rekey registration")
            return
        }

        await arbiter.clearEstablished(pairKey: pairKey)
        await arbiter.clearOutgoing(pairKey: pairKey, attemptId: nil)

        let accepted = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0xA2, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted = accepted else {
            XCTFail("Expected rekey registration to succeed after releasing established guard")
            return
        }

        await arbiter.clearOutgoing(pairKey: pairKey, attemptId: nil)
        await arbiter.markEstablished(pairKey: pairKey)

        let blockedAgain = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0xA3, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .alreadyConnected = blockedAgain else {
            XCTFail("Expected established guard to be restorable after failed rekey")
            return
        }
    }

    func testStaleEstablishedLeaseCannotClearReplacementSession() async throws {
        let arbiter = PeerSessionArbiter()
        let localPeerId = Data(repeating: 0x31, count: 32)
        let remotePeerId = Data(repeating: 0x32, count: 32)
        let pairKey = PeerSessionArbiter.pairKey(
            localPeerId: localPeerId,
            remotePeerId: remotePeerId
        )

        let initialDecision = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x30, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted(let initialReservation) = initialDecision else {
            XCTFail("Expected initial reservation")
            return
        }
        let staleLease = try await arbiter.commitEstablished(
            initialReservation,
            sessionId: "stale-session"
        )
        let replacementDecision = await arbiter.evaluateIncomingWithReservation(
            pairKey: pairKey,
            remoteInitiatorPeerId: remotePeerId,
            remoteAttemptId: Data(repeating: 0x31, count: 16),
            targetPeerId: localPeerId,
            expectedRemotePeerId: remotePeerId,
            localPeerId: localPeerId,
            authenticationState: .authenticated,
            establishedPolicy: .replaceAuthenticated
        )
        guard case .acceptAndReplaceEstablished(let replacementReservation) = replacementDecision else {
            XCTFail("Expected replacement reservation")
            return
        }
        let replacementLease = try await arbiter.commitEstablished(
            replacementReservation,
            sessionId: "replacement-session"
        )

        let staleLeaseCleared = await arbiter.clearEstablished(staleLease)
        XCTAssertFalse(
            staleLeaseCleared,
            "A stale teardown must not clear the replacement session's established guard"
        )

        let blockedByReplacement = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x33, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .alreadyConnected = blockedByReplacement else {
            XCTFail("Replacement lease must remain active after stale teardown")
            return
        }

        let replacementLeaseCleared = await arbiter.clearEstablished(replacementLease)
        XCTAssertTrue(replacementLeaseCleared)
        let acceptedAfterExactClear = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x34, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted = acceptedAfterExactClear else {
            XCTFail("Exact owner teardown must release the established guard")
            return
        }
        await arbiter.clearOutgoing(pairKey: pairKey, attemptId: nil)
    }

    func testReplacementCommitFailsWhenExpectedOwnerChanges() async throws {
        let arbiter = PeerSessionArbiter()
        let localPeerId = Data(repeating: 0x41, count: 32)
        let remotePeerId = Data(repeating: 0x42, count: 32)
        let pairKey = PeerSessionArbiter.pairKey(
            localPeerId: localPeerId,
            remotePeerId: remotePeerId
        )

        let initialDecision = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x43, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted(let initialReservation) = initialDecision else {
            XCTFail("Expected initial reservation")
            return
        }
        let initialLease = try await arbiter.commitEstablished(
            initialReservation,
            sessionId: "initial-owner"
        )

        let replacementDecision = await arbiter.evaluateIncomingWithReservation(
            pairKey: pairKey,
            remoteInitiatorPeerId: remotePeerId,
            remoteAttemptId: Data(repeating: 0x44, count: 16),
            targetPeerId: localPeerId,
            expectedRemotePeerId: remotePeerId,
            localPeerId: localPeerId,
            authenticationState: .authenticated,
            establishedPolicy: .replaceAuthenticated
        )
        guard case .acceptAndReplaceEstablished(let replacementReservation) = replacementDecision else {
            XCTFail("Expected replacement reservation")
            return
        }

        let initialLeaseCleared = await arbiter.clearEstablished(initialLease)
        XCTAssertTrue(initialLeaseCleared)
        do {
            _ = try await arbiter.commitEstablished(
                replacementReservation,
                sessionId: "stale-replacement"
            )
            XCTFail("CAS commit must fail after its expected owner disappears")
        } catch let error as PeerSessionArbiter.EstablishmentCommitError {
            XCTAssertEqual(error, .establishedOwnerChanged)
        }

        let finalDecision = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x45, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted(let finalReservation) = finalDecision else {
            XCTFail("Failed replacement commit must leave the vacant slot usable")
            return
        }
        let finalLease = try await arbiter.commitEstablished(
            finalReservation,
            sessionId: "final-owner"
        )
        let forgedLease = PeerSessionArbiter.EstablishedLease(
            pairKey: pairKey,
            sessionId: finalLease.sessionId
        )
        let forgedLeaseCleared = await arbiter.clearEstablished(forgedLease)
        let forgedLeaseRestored = await arbiter.restoreEstablishedIfVacant(forgedLease)
        let finalLeaseCleared = await arbiter.clearEstablished(finalLease)
        XCTAssertFalse(forgedLeaseCleared)
        XCTAssertFalse(forgedLeaseRestored)
        XCTAssertTrue(finalLeaseCleared)
    }

    func testLegacyPairKeyClearCannotDeleteModernSessionOwner() async throws {
        let arbiter = PeerSessionArbiter()
        let localPeerId = Data(repeating: 0x61, count: 32)
        let remotePeerId = Data(repeating: 0x62, count: 32)
        let pairKey = PeerSessionArbiter.pairKey(
            localPeerId: localPeerId,
            remotePeerId: remotePeerId
        )

        let modernDecision = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x63, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted(let modernReservation) = modernDecision else {
            XCTFail("Expected modern reservation")
            return
        }
        let modernLease = try await arbiter.commitEstablished(
            modernReservation,
            sessionId: "modern-owner"
        )

        await arbiter.clearEstablished(pairKey: pairKey)
        await arbiter.markEstablished(pairKey: pairKey)
        let duplicateDecision = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x64, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .alreadyConnected = duplicateDecision else {
            XCTFail("Legacy clear/mark must not replace a modern owner")
            return
        }
        let modernLeaseCleared = await arbiter.clearEstablished(modernLease)
        XCTAssertTrue(modernLeaseCleared)

        // The compatibility API still owns and clears its own legacy slot.
        await arbiter.markEstablished(pairKey: pairKey)
        await arbiter.clearEstablished(pairKey: pairKey)
        let acceptedAfterLegacyClear = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: pairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x65, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted(let cleanupReservation) = acceptedAfterLegacyClear else {
            XCTFail("Legacy clear must release a legacy-owned slot")
            return
        }
        let cleanupCleared = await arbiter.clearOutgoing(cleanupReservation)
        XCTAssertTrue(cleanupCleared)
    }

    func testRemoteControlSOAScopeDoesNotCollideWithEstablishedP2PSession() async {
        let arbiter = PeerSessionArbiter()
        let localPeerId = Data(repeating: 0x51, count: 32)
        let remotePeerId = Data(repeating: 0x52, count: 32)
        let p2pPairKey = PeerSessionArbiter.pairKey(
            localPeerId: localPeerId,
            remotePeerId: remotePeerId
        )
        let remoteControlPairKey = PeerSessionArbiter.pairKey(
            localPeerId: localPeerId,
            remotePeerId: remotePeerId,
            scope: .remoteControl
        )

        XCTAssertNotEqual(p2pPairKey, remoteControlPairKey)
        await arbiter.markEstablished(pairKey: p2pPairKey)

        let remoteControlRegistration = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: remoteControlPairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x53, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .accepted = remoteControlRegistration else {
            XCTFail("Remote control must be allowed to establish an independent SOA channel while P2P/file-transfer is already connected")
            return
        }

        await arbiter.markEstablished(pairKey: remoteControlPairKey)
        let duplicateRemoteControlRegistration = await arbiter.registerOutgoing(
            PeerSessionArbiter.OutgoingAttempt(
                pairKey: remoteControlPairKey,
                initiatorPeerId: localPeerId,
                attemptId: Data(repeating: 0x54, count: 16),
                startedAt: Date(),
                onSuperseded: { _, _ in }
            )
        )
        guard case .alreadyConnected = duplicateRemoteControlRegistration else {
            XCTFail("Remote control duplicates inside the same SOA scope must still be rejected")
            return
        }
    }

    private func makeMessageA(
        initiatorPeerId: Data,
        targetPeerId: Data,
        attemptId: Data
    ) throws -> HandshakeMessageA {
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["Ed25519"],
            supportedAuthProfiles: ["classic"],
            supportedAEAD: ["AES-256-GCM"],
            pqcAvailable: false,
            platformVersion: "soa-regression",
            providerType: .classic
        )
        let identity = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x11, count: 32),
            protocolAlgorithm: .ed25519,
            secureEnclavePublicKey: nil
        )
        let soa = try HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerId,
            targetPeerId: targetPeerId,
            attemptId: attemptId
        )
        return HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: Data(repeating: 0x22, count: 32))],
            clientNonce: Data(repeating: 0x23, count: 32),
            policy: .default,
            capabilities: capabilities,
            signature: Data(repeating: 0x44, count: 64),
            identityPublicKeys: identity,
            extensionsRaw: soa.encodedTLV,
            secureEnclaveSignature: nil,
            initiatorContribution: nil
        )
    }

    private func XCTAssertEqualDecision(
        _ actual: PeerSessionArbiter.IncomingDecision,
        _ expected: PeerSessionArbiter.IncomingDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.accept, .accept),
             (.rejectAlreadyConnected, .rejectAlreadyConnected),
             (.rejectBinding, .rejectBinding),
             (.rejectRateLimited, .rejectRateLimited),
             (.rejectLocalWinner, .rejectLocalWinner),
             (.acceptAndReplaceEstablished, .acceptAndReplaceEstablished):
            return
        case let (.acceptAndSupersedeLocal(actualPeer, actualAttempt), .acceptAndSupersedeLocal(expectedPeer, expectedAttempt)):
            XCTAssertEqual(actualPeer, expectedPeer, file: file, line: line)
            XCTAssertEqual(actualAttempt, expectedAttempt, file: file, line: line)
        default:
            XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }
}
