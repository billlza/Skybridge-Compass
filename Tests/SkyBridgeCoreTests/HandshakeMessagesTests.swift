import XCTest
@testable import SkyBridgeCore

final class HandshakeMessagesWireEncodingTests: XCTestCase {
    func testMessageADataToSignMatchesWirePrefix() throws {
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["P-256"],
            supportedAuthProfiles: [AuthProfile.classic.displayName],
            supportedAEAD: ["AES-GCM"],
            pqcAvailable: false,
            platformVersion: "14.0",
            providerType: .classic
        )
        let policy = HandshakePolicy(requirePQC: false, allowClassicFallback: true, minimumTier: .classic)
        let keyShare = HandshakeKeyShare(
            suite: .x25519Ed25519,
            shareBytes: Data(repeating: 0x11, count: 32)
        )
        let message = HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [keyShare],
            clientNonce: Data(repeating: 0x22, count: 32),
            policy: policy,
            capabilities: capabilities,
            signature: Data(repeating: 0xA5, count: 64),
            identityPublicKey: Data(repeating: 0xB7, count: 32)
        )

        let encoded = message.encoded
        let seSigLen = message.secureEnclaveSignature?.count ?? 0
        let prefixLen = encoded.count - 2 - message.signature.count - 2 - seSigLen
        XCTAssertEqual(message.transcriptBytes, Data(encoded.prefix(prefixLen)))
        var expectedPreimage = Data("SkyBridge-A".utf8)
        expectedPreimage.append(message.transcriptBytes)
        XCTAssertEqual(message.signaturePreimage, expectedPreimage)

        let sigLen = UInt16(message.signature.count)
        let sigLenBytes = Data([UInt8(sigLen & 0xff), UInt8(sigLen >> 8)])
        let sigLenStart = encoded.index(encoded.endIndex, offsetBy: -(2 + seSigLen + 2 + message.signature.count))
        let sigLenEnd = encoded.index(sigLenStart, offsetBy: 2)
        XCTAssertEqual(Data(encoded[sigLenStart..<sigLenEnd]), sigLenBytes)
        let sigDataStart = encoded.index(sigLenEnd, offsetBy: 0)
        let sigDataEnd = encoded.index(sigDataStart, offsetBy: message.signature.count)
        XCTAssertEqual(Data(encoded[sigDataStart..<sigDataEnd]), message.signature)
    }

    func testMessageBDataToSignMatchesWirePrefix() throws {
        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(repeating: 0x33, count: 32),
            nonce: Data(repeating: 0x44, count: 12),
            ciphertext: Data(repeating: 0x55, count: 16),
            tag: Data(repeating: 0x66, count: 16)
        )
        let message = HandshakeMessageB(
            selectedSuite: .x25519Ed25519,
            responderShare: Data(repeating: 0x77, count: 32),
            serverNonce: Data(repeating: 0x88, count: 32),
            encryptedPayload: sealedBox,
            signature: Data(repeating: 0xC3, count: 64),
            identityPublicKey: Data(repeating: 0xD4, count: 32)
        )

        let encoded = message.encoded
        let seSigLen = message.secureEnclaveSignature?.count ?? 0
        let prefixLen = encoded.count - 2 - message.signature.count - 2 - seSigLen
        XCTAssertEqual(message.transcriptBytes, Data(encoded.prefix(prefixLen)))

        let sigLen = UInt16(message.signature.count)
        let sigLenBytes = Data([UInt8(sigLen & 0xff), UInt8(sigLen >> 8)])
        let sigLenStart = encoded.index(encoded.endIndex, offsetBy: -(2 + seSigLen + 2 + message.signature.count))
        let sigLenEnd = encoded.index(sigLenStart, offsetBy: 2)
        XCTAssertEqual(Data(encoded[sigLenStart..<sigLenEnd]), sigLenBytes)
        let sigDataStart = encoded.index(sigLenEnd, offsetBy: 0)
        let sigDataEnd = encoded.index(sigDataStart, offsetBy: message.signature.count)
        XCTAssertEqual(Data(encoded[sigDataStart..<sigDataEnd]), message.signature)
    }
}
