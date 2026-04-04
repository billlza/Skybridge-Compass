import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class BootstrapAssuranceTests: XCTestCase {
    func testBootstrapControlMessageClassification() {
        let controlMessage = AppMessage.pairingIdentityExchange(
            .init(deviceId: "peer-device", kemPublicKeys: [])
        )
        let businessMessage = AppMessage.heartbeat(.init())

        XCTAssertTrue(P2PConnection.isBootstrapControlMessage(controlMessage))
        XCTAssertFalse(P2PConnection.isBootstrapControlMessage(businessMessage))
    }

    func testAssuranceClassificationStrictPQCWithoutBootstrap() {
        let assurance = P2PConnection.classifySessionAssurance(
            policy: .strictPQC,
            negotiatedSuite: .mlkem768MLDSA65,
            bootstrapAssisted: false
        )

        XCTAssertEqual(assurance, .pqcStrict)
    }

    func testAssuranceClassificationBootstrapAssistedWins() {
        let assurance = P2PConnection.classifySessionAssurance(
            policy: .strictPQC,
            negotiatedSuite: .mlkem768MLDSA65,
            bootstrapAssisted: true
        )

        XCTAssertEqual(assurance, .bootstrapAssisted)
    }

    func testAssuranceClassificationLegacyClassic() {
        let assurance = P2PConnection.classifySessionAssurance(
            policy: .default,
            negotiatedSuite: .x25519Ed25519,
            bootstrapAssisted: false
        )

        XCTAssertEqual(assurance, .legacyClassic)
    }

    func testInboundRekeyRestartOnlyFromConnectedStates() {
        let messageA = HandshakeMessageA(
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
        ).encoded

        let sessionKeys = SessionKeys(
            sendKey: Data(repeating: 0x01, count: 32),
            receiveKey: Data(repeating: 0x02, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .responder,
            transcriptHash: Data(repeating: 0x03, count: 32)
        )

        XCTAssertTrue(
            P2PConnection.shouldRestartInboundHandshakeForRekey(
                state: .waitingFinished(
                    deadline: ContinuousClock().now,
                    sessionKeys: sessionKeys,
                    expectingFrom: .initiator
                ),
                frame: messageA
            )
        )
        XCTAssertTrue(
            P2PConnection.shouldRestartInboundHandshakeForRekey(
                state: .established(sessionKeys: sessionKeys),
                frame: messageA
            )
        )
        XCTAssertFalse(
            P2PConnection.shouldRestartInboundHandshakeForRekey(
                state: .waitingMessageB(deadline: ContinuousClock().now),
                frame: messageA
            )
        )
    }

    func testPairingIdentityExchangeReplyIsRateLimited() {
        let now = Date()

        XCTAssertTrue(
            P2PDiscoveryService.shouldSendPairingIdentityExchangeReply(
                lastSentAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.shouldSendPairingIdentityExchangeReply(
                lastSentAt: now.addingTimeInterval(-5),
                now: now
            )
        )
        XCTAssertTrue(
            P2PDiscoveryService.shouldSendPairingIdentityExchangeReply(
                lastSentAt: now.addingTimeInterval(-11),
                now: now
            )
        )
    }
}
