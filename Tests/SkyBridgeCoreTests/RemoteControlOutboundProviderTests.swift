import Darwin
import Foundation
import SkyBridgeBenchmarkSupport
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class RemoteControlOutboundProviderTests: XCTestCase {
    func testXWingPreferenceStillAuthenticatesMLKEMOnlyTrustedPeer() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("Apple PQC is unavailable on this OS")
        }
        let previousPreference = getenv("SB_PQC_PREFERRED_SUITE").map { String(cString: $0) }
        XCTAssertEqual(setenv("SB_PQC_PREFERRED_SUITE", "xwing", 1), 0)
        defer {
            if let previousPreference {
                XCTAssertEqual(setenv("SB_PQC_PREFERRED_SUITE", previousPreference, 1), 0)
            } else {
                XCTAssertEqual(unsetenv("SB_PQC_PREFERRED_SUITE"), 0)
            }
        }
        let preferredProvider = CryptoProviderFactory.make(policy: .requirePQC)
        XCTAssertEqual(preferredProvider.tier, .nativePQC)
        XCTAssertEqual(preferredProvider.activeSuite, .xwingMLDSA)

        let responderProvider = OQSPQCProvider()
        let responderStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.mlkem768MLDSA65], provider: responderProvider
        )
        let responderKEM = try XCTUnwrap(
            responderStore.trustPublicKeys(for: [.mlkem768MLDSA65])[.mlkem768MLDSA65]
        )
        let responderSigningKey = try await responderProvider.generateKeyPair(for: .signing)
        let material = try RemoteControlPairingMaterial(
            deviceId: "id:" + UUID().uuidString.lowercased(), name: "ML-KEM Windows peer",
            protocolPublicKey: responderSigningKey.publicKey.bytes, kemPublicKey: responderKEM
        )
        let trust = DefaultHandshakeTrustProvider(
            trustRecordsSnapshot: [material.trustRecord(approvedAt: Date())]
        )
        let trustedKEMPublicKeys = await trust.trustedKEMPublicKeys(for: material.deviceId)
        XCTAssertEqual(Set(trustedKEMPublicKeys.keys.map(\.wireId)), [0x0101])
        let frozenProvider = CryptoProviderFactory.makeOutboundPQCInitiatorProvider(
            policy: .requirePQC, peerAdvertisedSuites: Array(trustedKEMPublicKeys.keys)
        )
        XCTAssertEqual(frozenProvider.tier, .nativePQC)
        XCTAssertEqual(frozenProvider.activeSuite, .mlkem768MLDSA65)
        let attempt = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly, cryptoProvider: frozenProvider
        )
        XCTAssertEqual(attempt.sigAAlgorithm, .mlDSA65)
        XCTAssertTrue(attempt.offeredSuites.contains(.mlkem768MLDSA65))
        XCTAssertTrue(attempt.offeredSuites.allSatisfy(\.isPQC))

        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: frozenProvider,
            protocolSignatureProvider: PQCSignatureProvider(backend: .applePQC),
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: attempt.offeredSuites),
            peerKEMPublicKeys: trustedKEMPublicKeys,
            offeredSuites: attempt.offeredSuites,
            activeProtocolSigningAlgorithm: .mlDSA65
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: responderProvider,
            protocolSignatureProvider: PQCSignatureProvider(backend: .oqs),
            kemIdentityStore: responderStore,
            offeredSuites: [.mlkem768MLDSA65],
            activeProtocolSigningAlgorithm: .mlDSA65
        )
        addTeardownBlock {
            await initiator.zeroize()
            await responder.zeroize()
        }
        let initiatorSigningKey = try await frozenProvider.generateKeyPair(for: .signing)
        let messageA = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(
                initiatorSigningKey.publicKey.bytes, algorithm: .mlDSA65
            ),
            policy: .strictPQC
        )
        let mlkemShare = try XCTUnwrap(messageA.keyShares.first { $0.suite == .mlkem768MLDSA65 })
        XCTAssertEqual(mlkemShare.shareBytes.count, 1_088)
        XCTAssertFalse(messageA.keyShares.contains { $0.suite == .xwingMLDSA })
        try await responder.processMessageA(
            HandshakeMessageA.decode(from: messageA.encoded), policy: .strictPQC
        )
        let response = try await responder.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigningKey.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(
                responderSigningKey.publicKey.bytes, algorithm: .mlDSA65
            ),
            policy: .strictPQC
        )
        defer { response.sharedSecret.zeroize() }
        let initiatorKeys = try await initiator.processMessageB(
            HandshakeMessageB.decode(from: response.message.encoded), policy: .strictPQC
        )
        let responderKeys = try await responder.finalizeResponderSessionKeys(sharedSecret: response.sharedSecret)
        XCTAssertEqual(initiatorKeys.negotiatedSuite, .mlkem768MLDSA65)
        XCTAssertEqual(responderKeys.negotiatedSuite, .mlkem768MLDSA65)
        XCTAssertTrue(initiatorKeys.sendKey == responderKeys.receiveKey)
        XCTAssertTrue(initiatorKeys.receiveKey == responderKeys.sendKey)
        XCTAssertEqual(initiatorKeys.sessionId, responderKeys.sessionId)
        let authenticatedAuthority = await initiator.getAuthenticatedRemoteAuthority()
        let authority = try XCTUnwrap(authenticatedAuthority)
        XCTAssertEqual(authority.protocolPublicKeyFingerprint, material.protocolPublicKeyFingerprint)

        let hybridPeerProvider = CryptoProviderFactory.makeOutboundPQCInitiatorProvider(
            policy: .requirePQC, peerAdvertisedSuites: [.xwingMLDSA, .mlkem768MLDSA65]
        )
        XCTAssertEqual(hybridPeerProvider.tier, .nativePQC)
        XCTAssertEqual(hybridPeerProvider.activeSuite, .xwingMLDSA)
        #else
        throw XCTSkip("Apple PQC SDK is unavailable in this build")
        #endif
    }
}
