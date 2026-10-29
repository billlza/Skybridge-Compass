import XCTest
@testable import SkyBridgeCore

final class InboundHandshakeAdapterTests: XCTestCase {
    private func makeTLV(type: UInt16, value: Data) -> Data {
        var raw = Data()
        raw.append(UInt8(type & 0xFF))
        raw.append(UInt8((type >> 8) & 0xFF))
        raw.append(UInt8(value.count & 0xFF))
        raw.append(UInt8((value.count >> 8) & 0xFF))
        raw.append(value)
        return raw
    }

    private func makeMessageA(extensionsRaw: Data = Data()) -> HandshakeMessageA {
        let nonce = Data(repeating: 0x11, count: 32)
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["Ed25519"],
            supportedAuthProfiles: ["classic"],
            supportedAEAD: ["AES-GCM"],
            pqcAvailable: false,
            platformVersion: "test",
            providerType: .classic
        )
        let policy = HandshakePolicy(
            requirePQC: false,
            allowClassicFallback: false,
            minimumTier: .classic,
            requireSecureEnclavePoP: false
        )
        let identity = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x22, count: 32),
            protocolAlgorithm: .ed25519,
            secureEnclavePublicKey: nil
        )
        let keyShare = HandshakeKeyShare(
            suite: .x25519Ed25519,
            shareBytes: Data(repeating: 0x33, count: 32)
        )
        return HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [keyShare],
            clientNonce: nonce,
            policy: policy,
            capabilities: capabilities,
            signature: Data(repeating: 0x44, count: 64),
            identityPublicKeys: identity,
            extensionsRaw: extensionsRaw
        )
    }

    func testBindSOAStateWithoutExtensionKeepsStateUnset() {
        let localPeerId = Data(repeating: 0xAA, count: 32)
        let messageA = makeMessageA()

        let binding = InboundHandshakeAdapter.bindSOAState(from: messageA, localPeerId: localPeerId)

        XCTAssertNil(binding.expectedRemotePeerId)
        XCTAssertNil(binding.pairKey)
        XCTAssertFalse(binding.usedAuthenticatedInitiator)
    }

    func testBindSOAStateUsesAuthenticatedInitiatorIdentity() throws {
        let localPeerId = Data(repeating: 0xAB, count: 32)
        let initiatorPeerId = Data(repeating: 0x01, count: 32)
        let targetPeerId = Data(repeating: 0x02, count: 32)
        let attemptId = Data(repeating: 0x03, count: 16)
        let soa = try HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerId,
            targetPeerId: targetPeerId,
            attemptId: attemptId
        )
        let messageA = makeMessageA(extensionsRaw: soa.encodedTLV)

        let binding = InboundHandshakeAdapter.bindSOAState(from: messageA, localPeerId: localPeerId)
        let expectedPairKey = PeerSessionArbiter.pairKey(
            localPeerId: localPeerId,
            remotePeerId: initiatorPeerId
        )

        XCTAssertEqual(binding.expectedRemotePeerId, initiatorPeerId)
        XCTAssertEqual(binding.pairKey, expectedPairKey)
        XCTAssertTrue(binding.usedAuthenticatedInitiator)
    }

    func testBindSOAStatePreservesUnknownTLVBytesAndUsesSOAInitiator() throws {
        let localPeerId = Data(repeating: 0xCC, count: 32)
        let initiatorPeerId = Data(repeating: 0x21, count: 32)
        let targetPeerId = Data(repeating: 0x22, count: 32)
        let attemptId = Data(repeating: 0x23, count: 16)
        let soa = try HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerId,
            targetPeerId: targetPeerId,
            attemptId: attemptId
        )

        let unknownPrefix = makeTLV(type: 0x7101, value: Data([0x01, 0x02]))
        let unknownSuffix = makeTLV(type: 0x7102, value: Data([0x03]))
        let raw = unknownPrefix + soa.encodedTLV + unknownSuffix
        let messageA = makeMessageA(extensionsRaw: raw)

        let encoded = messageA.encoded
        let decoded = try HandshakeMessageA.decode(from: encoded)
        XCTAssertEqual(decoded.extensionsRaw, raw)

        let binding = InboundHandshakeAdapter.bindSOAState(from: decoded, localPeerId: localPeerId)
        let expectedPairKey = PeerSessionArbiter.pairKey(localPeerId: localPeerId, remotePeerId: initiatorPeerId)

        XCTAssertEqual(binding.expectedRemotePeerId, initiatorPeerId)
        XCTAssertEqual(binding.pairKey, expectedPairKey)
        XCTAssertTrue(binding.usedAuthenticatedInitiator)
    }
}
