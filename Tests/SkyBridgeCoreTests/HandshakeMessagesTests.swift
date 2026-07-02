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

    func testMessageAV2ContributionRoundTrip() throws {
        let capabilities = CryptoCapabilities(
            supportedKEM: ["ML-KEM-768"],
            supportedSignature: ["ML-DSA-65"],
            supportedAuthProfiles: [AuthProfile.pqc.displayName],
            supportedAEAD: ["AES-GCM"],
            pqcAvailable: true,
            platformVersion: "26.0",
            providerType: .cryptoKitPQC
        )
        let message = HandshakeMessageA(
            supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            keyShares: [
                HandshakeKeyShare(suite: .mlkem768MLDSA65FS, shareBytes: Data(repeating: 0x31, count: 1088)),
                HandshakeKeyShare(suite: .mlkem768MLDSA65, shareBytes: Data(repeating: 0x32, count: 1088))
            ],
            clientNonce: Data(repeating: 0x22, count: 32),
            policy: .default,
            capabilities: capabilities,
            signature: Data(repeating: 0xA1, count: 64),
            identityPublicKey: Data(repeating: 0xB2, count: 32),
            initiatorContribution: Data(repeating: 0x5A, count: 32)
        )

        let decoded = try HandshakeMessageA.decode(from: message.encoded)
        XCTAssertEqual(decoded.supportedSuites, message.supportedSuites)
        XCTAssertEqual(decoded.initiatorContribution, message.initiatorContribution)
        XCTAssertEqual(decoded.keyShares.count, 2)
    }

    func testMessageAQPeriaptProviderTypeRoundTrip() throws {
        let capabilities = CryptoCapabilities(
            supportedKEM: [P2PCryptoAlgorithm.qperiaptContextBound.rawValue],
            supportedSignature: ["ML-DSA-65"],
            supportedAuthProfiles: [QPeriaptPlatformPolicy.authProfile],
            supportedAEAD: ["AES-GCM"],
            pqcAvailable: true,
            platformVersion: "Android 16 / API 36",
            providerType: .qPeriapt
        )
        let message = HandshakeMessageA(
            supportedSuites: [.qperiaptContextBound],
            keyShares: [
                HandshakeKeyShare(
                    suite: .qperiaptContextBound,
                    shareBytes: Data(repeating: 0x31, count: 1_120)
                )
            ],
            clientNonce: Data(repeating: 0x22, count: 32),
            policy: HandshakePolicy(requirePQC: true, allowClassicFallback: false, minimumTier: .qperiaptPQC),
            capabilities: capabilities,
            signature: Data(repeating: 0xA1, count: 64),
            identityPublicKey: Data(repeating: 0xB2, count: 32),
            initiatorContribution: Data(repeating: 0x5A, count: 32)
        )

        let decoded = try HandshakeMessageA.decode(from: message.encoded)
        XCTAssertEqual(decoded.capabilities.providerType, CryptoProviderType.qPeriapt)
        XCTAssertEqual(decoded.capabilities.supportedKEM, [P2PCryptoAlgorithm.qperiaptContextBound.rawValue])
        XCTAssertEqual(decoded.policy.minimumTier, .qperiaptPQC)
        XCTAssertEqual(decoded.supportedSuites, [CryptoSuite.qperiaptContextBound])
    }

    func testMessageBQPeriaptAllowsEmptyResponderShare() throws {
        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(),
            nonce: Data(repeating: 0x44, count: 12),
            ciphertext: Data(repeating: 0x55, count: 16),
            tag: Data(repeating: 0x66, count: 16)
        )
        let message = HandshakeMessageB(
            selectedSuite: .qperiaptContextBound,
            responderShare: Data(),
            serverNonce: Data(repeating: 0x88, count: 32),
            encryptedPayload: sealedBox,
            signature: Data(repeating: 0xC3, count: 3_309),
            identityPublicKey: Data(repeating: 0xD4, count: 1_952)
        )

        let decoded = try HandshakeMessageB.decode(from: message.encoded)
        XCTAssertEqual(decoded.selectedSuite, .qperiaptContextBound)
        XCTAssertEqual(decoded.responderShare.count, 0)
        XCTAssertEqual(decoded.encryptedPayload.encapsulatedKey.count, 0)
    }

    func testMessageBV2RejectsMissingResponderContribution() throws {
        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(),
            nonce: Data(repeating: 0x44, count: 12),
            ciphertext: Data(repeating: 0x55, count: 16),
            tag: Data(repeating: 0x66, count: 16)
        )
        let message = HandshakeMessageB(
            selectedSuite: .mlkem768MLDSA65FS,
            responderShare: Data(),
            serverNonce: Data(repeating: 0x88, count: 32),
            encryptedPayload: sealedBox,
            signature: Data(repeating: 0xC3, count: 64),
            identityPublicKey: Data(repeating: 0xD4, count: 32)
        )

        XCTAssertThrowsError(try HandshakeMessageB.decode(from: message.encoded)) { error in
            guard case HandshakeError.failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed")
                return
            }
            guard case .invalidMessageFormat = reason else {
                XCTFail("Expected invalidMessageFormat")
                return
            }
        }
    }

    func testMessageADecodeRejectsOversizedPayload() throws {
        let oversized = Data(repeating: 0x00, count: HandshakeConstants.maxMessageALength + 1)
        XCTAssertThrowsError(try HandshakeMessageA.decode(from: oversized)) { error in
            guard case HandshakeError.failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed")
                return
            }
            guard case .invalidMessageFormat = reason else {
                XCTFail("Expected invalidMessageFormat")
                return
            }
        }
    }

    func testMessageBDecodeRejectsOversizedPayload() throws {
        let oversized = Data(repeating: 0x00, count: HandshakeConstants.maxMessageBLength + 1)
        XCTAssertThrowsError(try HandshakeMessageB.decode(from: oversized)) { error in
            guard case HandshakeError.failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed")
                return
            }
            guard case .invalidMessageFormat = reason else {
                XCTFail("Expected invalidMessageFormat")
                return
            }
        }
    }

    func testMessageADecodeRejectsUnknownSupportedSuite() throws {
        var encoded = makeClassicMessageA().encoded
        encoded[3] = 0x00
        encoded[4] = 0x00

        assertThrowsSuiteNotSupported {
            _ = try HandshakeMessageA.decode(from: encoded)
        }
    }

    func testMessageADecodeRejectsUnknownKeyShareSuite() throws {
        var encoded = makeClassicMessageA().encoded
        encoded[7] = 0x00
        encoded[8] = 0x00

        assertThrowsSuiteNotSupported {
            _ = try HandshakeMessageA.decode(from: encoded)
        }
    }

    func testMessageBDecodeRejectsUnknownSelectedSuite() throws {
        var encoded = makeClassicMessageB().encoded
        encoded[1] = 0x00
        encoded[2] = 0x00

        assertThrowsSuiteNotSupported {
            _ = try HandshakeMessageB.decode(from: encoded)
        }
    }

    private func makeClassicMessageA() -> HandshakeMessageA {
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["P-256"],
            supportedAuthProfiles: [AuthProfile.classic.displayName],
            supportedAEAD: ["AES-GCM"],
            pqcAvailable: false,
            platformVersion: "14.0",
            providerType: .classic
        )
        return HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [
                HandshakeKeyShare(suite: .x25519Ed25519, shareBytes: Data(repeating: 0x11, count: 32))
            ],
            clientNonce: Data(repeating: 0x22, count: 32),
            policy: HandshakePolicy(requirePQC: false, allowClassicFallback: true, minimumTier: .classic),
            capabilities: capabilities,
            signature: Data(repeating: 0xA5, count: 64),
            identityPublicKey: Data(repeating: 0xB7, count: 32)
        )
    }

    private func makeClassicMessageB() -> HandshakeMessageB {
        let sealedBox = HPKESealedBox(
            encapsulatedKey: Data(repeating: 0x33, count: 32),
            nonce: Data(repeating: 0x44, count: 12),
            ciphertext: Data(repeating: 0x55, count: 16),
            tag: Data(repeating: 0x66, count: 16)
        )
        return HandshakeMessageB(
            selectedSuite: .x25519Ed25519,
            responderShare: Data(repeating: 0x77, count: 32),
            serverNonce: Data(repeating: 0x88, count: 32),
            encryptedPayload: sealedBox,
            signature: Data(repeating: 0xC3, count: 64),
            identityPublicKey: Data(repeating: 0xD4, count: 32)
        )
    }

    private func assertThrowsSuiteNotSupported(
        _ expression: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case HandshakeError.failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed", file: file, line: line)
                return
            }
            XCTAssertEqual(reason, .suiteNotSupported, file: file, line: line)
        }
    }
}
