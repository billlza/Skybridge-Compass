import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class P2PDiscoveryHandshakeCompatibilityTests: XCTestCase {
    func testNormalizeInboundControlFrameUnwrapsHandshakePaddingBeforeClassification() throws {
        UserDefaults.standard.set(true, forKey: "sb_handshake_padding_enabled")
        defer { UserDefaults.standard.removeObject(forKey: "sb_handshake_padding_enabled") }

        let finished = HandshakeFinished(
            direction: .initiatorToResponder,
            mac: Data(repeating: 0xAB, count: 32)
        ).encoded
        let padded = try HandshakePadding.wrapIfEnabled(finished, label: "test/finished")

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

    func testEstablishedChannelAuthenticatesAppFrameBeforeHandshakeHeuristics() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "if let keys = sessionKeys {")
        )
        let end = try XCTUnwrap(
            source.range(
                of: "// 延迟初始化",
                range: start.lowerBound..<source.endIndex
            )
        )
        let authenticatedFrameBody = String(
            source[start.lowerBound..<end.lowerBound]
        )

        XCTAssertTrue(
            authenticatedFrameBody.contains(
                "let plaintext = try decryptAppPayload(frame, with: keys)"
            )
        )
        XCTAssertTrue(
            authenticatedFrameBody.contains(
                "guard (try? HandshakeMessageA.decode(from: frame)) != nil"
            )
        )
        XCTAssertFalse(
            authenticatedFrameBody.contains(
                "if let keys = sessionKeys, !isLikelyHandshakeControlPacket(frame)"
            ),
            "Authenticated AES-GCM ciphertext must not be skipped because a byte-shape heuristic resembles a handshake frame."
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
                    shareBytes: Data(repeating: 0x11, count: 32)
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
