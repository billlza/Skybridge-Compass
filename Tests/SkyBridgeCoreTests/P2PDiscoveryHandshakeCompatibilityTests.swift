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
    }

    private func makeHandshakeMessageA() -> HandshakeMessageA {
        HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [
                HandshakeKeyShare(
                    suite: .x25519Ed25519,
                    shareBytes: Data(repeating: 0x11, count: 32)
                )
            ],
            clientNonce: Data(repeating: 0x22, count: 32),
            policy: .default,
            capabilities: CryptoCapabilities(
                supportedKEM: ["X25519"],
                supportedSignature: ["Ed25519"],
                supportedAuthProfiles: ["default"],
                supportedAEAD: ["AES.GCM"],
                pqcAvailable: false,
                platformVersion: "test",
                providerType: .classic
            ),
            signature: Data(repeating: 0x33, count: 64),
            identityPublicKeys: IdentityPublicKeys(
                protocolPublicKey: Data(repeating: 0x44, count: 32),
                protocolAlgorithm: .ed25519
            )
        )
    }
}
