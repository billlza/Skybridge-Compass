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

    func testPairingIdentityBootstrapPayloadRejectsEmptyDeviceIdOrEmptyKEMKeys() {
        let validKey = KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data(repeating: 0xAA, count: 1_184))

        XCTAssertNil(
            AppMessage.PairingIdentityExchangePayload(
                deviceId: "  ",
                kemPublicKeys: [validKey]
            ).normalizedBootstrapPayload
        )
        XCTAssertNil(
            AppMessage.PairingIdentityExchangePayload(
                deviceId: "peer-device",
                kemPublicKeys: [KEMPublicKeyInfo(suiteWireId: 257, publicKey: Data())]
            ).normalizedBootstrapPayload
        )

        let normalized = AppMessage.PairingIdentityExchangePayload(
            deviceId: " peer-device ",
            kemPublicKeys: [
                KEMPublicKeyInfo(suiteWireId: 258, publicKey: Data()),
                validKey
            ]
        ).normalizedBootstrapPayload

        XCTAssertEqual(normalized?.deviceId, "peer-device")
        XCTAssertEqual(normalized?.kemPublicKeys, [validKey])
    }

    func testAssuranceClassificationStrictPQCWithoutBootstrap() {
        let assurance = P2PConnection.classifySessionAssurance(
            policy: .strictPQC,
            negotiatedSuite: .mlkem768MLDSA65,
            bootstrapAssisted: false
        )

        XCTAssertEqual(assurance, .pqcStrict)
    }

    func testAssuranceClassificationDoesNotMislabelOptionalOrLegacyPQCAsStrict() {
        XCTAssertEqual(
            P2PConnection.classifySessionAssurance(
                policy: .default,
                negotiatedSuite: .mlkem768MLDSA65,
                bootstrapAssisted: false
            ),
            .pqcNegotiated
        )
        XCTAssertEqual(
            P2PConnection.classifySessionAssurance(
                policy: .strictPQC,
                negotiatedSuite: .qperiaptContextBound,
                bootstrapAssisted: false
            ),
            .unknown
        )
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
        func encodedMessageA(suite: CryptoSuite, keyShareLength: Int) -> Data {
            HandshakeMessageA(
                supportedSuites: [suite],
                keyShares: [
                    HandshakeKeyShare(
                        suite: suite,
                        shareBytes: Data(repeating: 0x11, count: keyShareLength)
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
        }

        let messageA = encodedMessageA(suite: .x25519Ed25519, keyShareLength: 32)
        let legacyMessageA = encodedMessageA(suite: .qperiaptContextBound, keyShareLength: 1_120)

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
        XCTAssertFalse(
            P2PConnection.shouldRestartInboundHandshakeForRekey(
                state: .established(sessionKeys: sessionKeys),
                frame: legacyMessageA
            ),
            "Decode-only ABI1 must not replace an established P2P driver"
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

    func testPairingIdentityExchangeFreshRequestBypassesReplyRateLimit() {
        let now = Date()
        let lastReply = PairingIdentityExchangeReplyThrottleState(
            requestKey: "old-request",
            requestSentAt: now.addingTimeInterval(-2),
            repliedAt: now.addingTimeInterval(-2)
        )

        XCTAssertFalse(
            P2PDiscoveryService.shouldSendPairingIdentityExchangeReply(
                lastReply: lastReply,
                requestKey: "old-request",
                requestSentAt: now.addingTimeInterval(-2),
                now: now
            )
        )
        XCTAssertTrue(
            P2PDiscoveryService.shouldSendPairingIdentityExchangeReply(
                lastReply: lastReply,
                requestKey: "fresh-request",
                requestSentAt: now,
                now: now
            )
        )
    }

    func testPairingIdentityExchangeRequestKeyChangesWithSentAt() {
        let kemKey = KEMPublicKeyInfo(suiteWireId: 1, publicKey: Data(repeating: 0xA5, count: 32))
        let first = AppMessage.PairingIdentityExchangePayload(
            deviceId: "peer-device",
            kemPublicKeys: [kemKey],
            sentAt: Date(timeIntervalSince1970: 100)
        )
        let second = AppMessage.PairingIdentityExchangePayload(
            deviceId: "peer-device",
            kemPublicKeys: [kemKey],
            sentAt: Date(timeIntervalSince1970: 101)
        )

        XCTAssertNotEqual(
            P2PDiscoveryService.pairingIdentityExchangeRequestKey(first),
            P2PDiscoveryService.pairingIdentityExchangeRequestKey(second)
        )
    }
}
