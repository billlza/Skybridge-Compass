import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class P2PDiscoveryHandshakeCompatibilityTests: XCTestCase {
    func testNormalizeInboundControlFrameUnwrapsHandshakePaddingBeforeClassification() {
        UserDefaults.standard.set(true, forKey: "sb_handshake_padding_enabled")
        defer { UserDefaults.standard.removeObject(forKey: "sb_handshake_padding_enabled") }

        let finished = HandshakeFinished(
            direction: .initiatorToResponder,
            mac: Data(repeating: 0xAB, count: 32)
        ).encoded
        let padded = HandshakePadding.wrapIfEnabled(finished, label: "test/finished")

        XCTAssertNotEqual(padded, finished)

        let normalized = P2PDiscoveryService.normalizeInboundControlFrame(padded)

        XCTAssertEqual(normalized, finished)
        XCTAssertTrue(P2PDiscoveryService.isLikelyHandshakeControlFrame(normalized))
    }

    func testShouldRestartInboundHandshakeForRekeyOnlyWhenNewMessageAArrivesFromConnectedStates() {
        let messageA = makeHandshakeMessageA().encoded
        let sessionKeys = SessionKeys(
            sendKey: Data(repeating: 0x01, count: 32),
            receiveKey: Data(repeating: 0x02, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .responder,
            transcriptHash: Data(repeating: 0x03, count: 32)
        )

        let waitingFinished = HandshakeState.waitingFinished(
            deadline: ContinuousClock().now,
            sessionKeys: sessionKeys,
            expectingFrom: .initiator
        )
        let established = HandshakeState.established(sessionKeys: sessionKeys)
        let waitingMessageB = HandshakeState.waitingMessageB(deadline: ContinuousClock().now)

        XCTAssertTrue(
            P2PDiscoveryService.shouldRestartInboundHandshakeForRekey(
                state: waitingFinished,
                frame: messageA
            )
        )
        XCTAssertTrue(
            P2PDiscoveryService.shouldRestartInboundHandshakeForRekey(
                state: established,
                frame: messageA
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.shouldRestartInboundHandshakeForRekey(
                state: waitingMessageB,
                frame: messageA
            )
        )

        let legacyMessageA = makeHandshakeMessageA(
            supportedSuites: [.qperiaptContextBound],
            providerType: .qPeriapt
        ).encoded
        XCTAssertFalse(
            P2PDiscoveryService.shouldRestartInboundHandshakeForRekey(
                state: established,
                frame: legacyMessageA
            ),
            "Decode-only ABI1 must not mutate an established rekey session"
        )
    }

    func testStrictPQCDiscoveryRejectsClassicOnlyMessageA() {
        let messageA = makeHandshakeMessageA(supportedSuites: [.x25519Ed25519])

        let rejection = StrictPQCAdmissionGate.inboundRejection(
            policy: .strictPQC,
            peerSupportedSuites: messageA.supportedSuites,
            localPQCSuitesAvailable: false
        )

        XCTAssertEqual(rejection, .peerOfferedClassicOnly)
    }

    func testStrictPQCDiscoveryRejectsClassicFallbackWhenLocalPQCUnavailable() {
        let messageA = makeHandshakeMessageA(
            supportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            providerType: .cryptoKitPQC
        )

        let rejection = StrictPQCAdmissionGate.inboundRejection(
            policy: .strictPQC,
            peerSupportedSuites: messageA.supportedSuites,
            localPQCSuitesAvailable: false
        )

        XCTAssertEqual(rejection, StrictPQCAdmissionRejection.localPQCUnavailable)
    }

    @MainActor
    func testStrictPQCKEMFamilyMatchingAllowsOnlyExactOrCanonicalNegotiableFamily() {
        XCTAssertTrue(
            P2PDiscoveryService.suiteSupportsTargetKEM(.xwingMLDSA, target: .xwingMLDSA)
        )
        XCTAssertTrue(
            P2PDiscoveryService.suiteSupportsTargetKEM(.mlkem768MLDSA65FS, target: .mlkem768MLDSA65)
        )
        XCTAssertTrue(
            P2PDiscoveryService.suiteSupportsTargetKEM(.mlkem768MLDSA65, target: .mlkem768MLDSA65FS)
        )

        XCTAssertFalse(
            P2PDiscoveryService.suiteSupportsTargetKEM(.xwingMLDSA, target: .qperiaptABI2PolicyBound),
            "Unrelated hybrid suites must never be treated as the same KEM family"
        )
        XCTAssertFalse(
            P2PDiscoveryService.suiteSupportsTargetKEM(.qperiaptContextBound, target: .qperiaptABI2PolicyBound),
            "Decode-only ABI1 must not satisfy an ABI2 target"
        )
        XCTAssertFalse(
            P2PDiscoveryService.suiteSupportsTargetKEM(.unknown(0x00FF), target: .xwingMLDSA),
            "Unknown hybrid-tier identifiers must not satisfy a known target"
        )
    }

    @MainActor
    func testStrictPQCKEMAdmissionWithoutPreferredTargetRequiresNegotiablePQC() {
        XCTAssertTrue(
            P2PDiscoveryService.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.mlkem768MLDSA65],
                preferredTargetSuite: nil
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.qperiaptContextBound, .unknown(0x00FF)],
                preferredTargetSuite: nil
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.canSatisfyStrictPQCWithTrustedKEM(
                trustedPeerKEMSuites: [.xwingMLDSA],
                preferredTargetSuite: .qperiaptABI2PolicyBound
            ),
            "A different hybrid KEM must not satisfy the preferred target"
        )
    }

    private func makeHandshakeMessageA(
        supportedSuites: [CryptoSuite] = [.x25519Ed25519],
        providerType: CryptoProviderType = .classic
    ) -> HandshakeMessageA {
        HandshakeMessageA(
            supportedSuites: supportedSuites,
            keyShares: supportedSuites.map { suite in
                HandshakeKeyShare(
                    suite: suite,
                    shareBytes: Data(
                        repeating: 0x11,
                        count: suite == .qperiaptContextBound ? 1_120 : 32
                    )
                )
            },
            clientNonce: Data(repeating: 0x22, count: 32),
            policy: .default,
            capabilities: CryptoCapabilities(
                supportedKEM: ["X25519"],
                supportedSignature: ["Ed25519"],
                supportedAuthProfiles: ["default"],
                supportedAEAD: ["AES.GCM"],
                pqcAvailable: supportedSuites.contains { $0.isPQCGroup },
                platformVersion: "test",
                providerType: providerType
            ),
            signature: Data(repeating: 0x33, count: 64),
            identityPublicKeys: IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0x44, count: 32),
                protocolAlgorithm: .ed25519
            )
        )
    }
}
