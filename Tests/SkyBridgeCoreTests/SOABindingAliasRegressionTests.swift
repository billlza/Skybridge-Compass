import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class SOABindingAliasRegressionTests: XCTestCase {
    func testAliasMixKeepsInitiatorBindingAndPairKeyStable() throws {
        let localUUID = "11111111-1111-1111-1111-111111111111"
        let remoteUUID = "22222222-2222-2222-2222-222222222222"
        let localAliases = [
            "id:\(localUUID)",
            "host:\(localUUID)",
            "bonjour:\(localUUID)@local.",
            "recent:id:\(localUUID)"
        ]
        let remoteAliases = [
            "id:\(remoteUUID)",
            "host:\(remoteUUID)",
            "bonjour:\(remoteUUID)@local.",
            "mac:bonjour:\(remoteUUID)@local."
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
}
