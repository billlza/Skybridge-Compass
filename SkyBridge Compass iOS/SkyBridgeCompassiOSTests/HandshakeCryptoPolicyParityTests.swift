import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class HandshakeCryptoPolicyParityTests: XCTestCase {
    func testPrepareAttemptForXWingCarriesHybridCryptoPolicy() throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: AppleXWingCryptoProvider()
        )

        XCTAssertEqual(preparation.offeredSuites, [.xwing])
        XCTAssertEqual(preparation.cryptoPolicy.minimumSecurityTier, .hybridPreferred)
        XCTAssertTrue(preparation.cryptoPolicy.allowExperimentalHybrid)
        XCTAssertTrue(preparation.cryptoPolicy.advertiseHybrid)
        XCTAssertTrue(preparation.cryptoPolicy.requireHybridIfAvailable)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionRejectsXWingWhenAttemptDidNotEnableHybrid() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple PQC provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: ApplePQCCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x11, count: 32),
            policy: .strictPQC,
            cryptoPolicy: .default
        )

        let messageA = makeMessageA(supportedSuites: [.xwing], keyShareSuites: [.xwing])

        do {
            _ = try await context.selectResponderSuite(for: messageA)
            XCTFail("Expected X-Wing to be rejected when hybrid policy is disabled")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionAcceptsXWingWhenResolverEnabledHybrid() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: AppleXWingCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x22, count: 32),
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing])
        )

        let messageA = makeMessageA(supportedSuites: [.xwing], keyShareSuites: [.xwing])
        let selected = try await context.selectResponderSuite(for: messageA)

        XCTAssertEqual(selected, .xwing)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    func testResponderSelectionPrefersHybridWhenPolicyRequiresIt() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Apple X-Wing provider unavailable on this runtime")
        }

        let context = HandshakeContext(
            role: .responder,
            cryptoProvider: AppleXWingCryptoProvider(),
            protocolSignatureProvider: PQCSignatureProvider(),
            identityKeyHandle: nil,
            identityPublicKey: Data(repeating: 0x33, count: 32),
            policy: .strictPQC,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: [.xwing, .mlkem768])
        )

        let messageA = makeMessageA(
            supportedSuites: [.xwing, .mlkem768],
            keyShareSuites: [.xwing, .mlkem768]
        )
        let selected = try await context.selectResponderSuite(for: messageA)

        XCTAssertEqual(selected, .xwing)
        #else
        throw XCTSkip("HAS_APPLE_PQC_SDK not enabled")
        #endif
    }

    private func makeMessageA(
        supportedSuites: [CryptoSuite],
        keyShareSuites: [CryptoSuite]
    ) -> HandshakeMessageA {
        let keyShares = keyShareSuites.map { suite in
            HandshakeKeyShare(
                suite: suite,
                shareBytes: Data(repeating: UInt8(truncatingIfNeeded: suite.wireId & 0x00FF), count: 32)
            )
        }

        return HandshakeMessageA(
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: Data(repeating: 0x44, count: HandshakeConstants.nonceSize),
            policy: .strictPQC,
            capabilities: CryptoCapabilities(),
            signature: Data(),
            identityPublicKey: Data(repeating: 0x55, count: 32)
        )
    }
}
