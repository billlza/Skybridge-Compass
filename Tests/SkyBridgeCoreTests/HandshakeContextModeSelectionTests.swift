import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeContextModeSelectionTests: XCTestCase {
    private struct SelectedKEM: HandshakeKEMIdentityStore {
        let pair: KeyPair
        func getOrCreateKEMIdentityKey(for suite: CryptoSuite, provider: any CryptoProvider) async throws -> HandshakeKEMIdentityMaterial {
            HandshakeKEMIdentityMaterial(publicKey: pair.publicKey.bytes, privateKey: SecureBytes(data: pair.privateKey.bytes))
        }
    }

    func testResponderSelectsAPermittedSuiteBeforeProducingMessageB() async throws {
        let provider = OQSPQCCryptoProvider()
        let signature = ProtocolSignatureProviderSelector.select(for: .mlDSA65)
        let signing = try await provider.generateKeyPair(for: .signing)
        let kem = try await provider.generateKeyPair(for: .keyExchange)
        let identity = IdentityPublicKeys(protocolPublicKey: signing.publicKey.bytes, protocolAlgorithm: .mlDSA65).encoded
        let offered: [CryptoSuite] = [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        let initiator = try await HandshakeContext.create(role: .initiator, cryptoProvider: provider,
            protocolSignatureProvider: signature, peerKEMPublicKeys: [.mlkem768MLDSA65: kem.publicKey.bytes],
            offeredSuites: offered, activeProtocolSigningAlgorithm: .mlDSA65)
        let message = try await initiator.buildMessageA(identityKeyHandle: .softwareKey(signing.privateKey.bytes),
            identityPublicKey: identity, policy: .default, offeredSuites: offered)
        XCTAssertEqual(message.supportedSuites, offered)
        let responder = try await HandshakeContext.create(role: .responder, cryptoProvider: provider,
            protocolSignatureProvider: signature, kemIdentityStore: SelectedKEM(pair: kem),
            offeredSuites: offered, activeProtocolSigningAlgorithm: .mlDSA65,
            pqcModeSelection: PQCModeSelection(preference: .mlkem, strictlyMatchSelectedMode: false))
        try await responder.processMessageA(message)
        let selected = await responder.negotiatedSuite
        XCTAssertEqual(selected, .mlkem768MLDSA65,
            "The responder must not choose the FS variant and reject its own choice only after Finished")
        let strictResponder = try await HandshakeContext.create(role: .responder, cryptoProvider: provider,
            protocolSignatureProvider: signature, kemIdentityStore: SelectedKEM(pair: kem),
            offeredSuites: offered, activeProtocolSigningAlgorithm: .mlDSA65,
            pqcModeSelection: PQCModeSelection(preference: .xwing, strictlyMatchSelectedMode: true))
        do {
            try await strictResponder.processMessageA(message)
            XCTFail("A strict mode with no common suite must fail before MessageB")
        } catch {
            guard case HandshakeError.failed(.suiteNegotiationFailed) = error else { throw error }
        }
        let rejectedSuite = await strictResponder.negotiatedSuite
        XCTAssertNil(rejectedSuite)
        await strictResponder.zeroize()
        await initiator.zeroize()
        await responder.zeroize()
    }
}
