import Foundation
import XCTest
@testable import SkyBridgeCore

#if canImport(CQPeriapt)
@available(macOS 14.0, iOS 17.0, *)
final class QPeriaptHandshakeApplicationContextTests: XCTestCase {
    private let nonce = Data(repeating: 0x11, count: 32)
    private let recipientPublicKey = Data(
        repeating: 0x22,
        count: QPeriaptNativeAdapter.publicKeyLength
    )
    private let policy = HandshakePolicy(
        requirePQC: true,
        allowClassicFallback: false,
        minimumTier: .qperiaptPQC
    )
    private let suites: [CryptoSuite] = [
        .qperiaptABI2PolicyBound,
        .mlkem768MLDSA65
    ]
    private let capabilities = CryptoCapabilities(
        supportedKEM: [P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue],
        supportedSignature: [P2PCryptoAlgorithm.mlDSA65.rawValue],
        supportedAuthProfiles: ["q-periapt-abi2-policy-v1/2/test-digest"],
        supportedAEAD: [P2PCryptoAlgorithm.aes256GCM.rawValue],
        pqcAvailable: true,
        platformVersion: "macOS 26.0",
        providerType: .qPeriapt
    )
    private let identityPublicKey = Data(repeating: 0x33, count: 1_952)
    private let extensionsRaw = Data([0x01, 0x02, 0x03])

    func testContextEncodingIsDeterministic() throws {
        let first = try makeContext()
        let second = try makeContext()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, QPeriaptNativeAdapter.maximumApplicationContextLength)
    }

    func testEverySecurityRelevantInputChangesContext() throws {
        let baseline = try makeContext()

        XCTAssertNotEqual(baseline, try makeContext(version: 2))

        var changedNonce = nonce
        changedNonce[0] ^= 0x01
        XCTAssertNotEqual(baseline, try makeContext(clientNonce: changedNonce))

        var changedRecipient = recipientPublicKey
        changedRecipient[0] ^= 0x01
        XCTAssertNotEqual(baseline, try makeContext(recipientPublicKey: changedRecipient))

        XCTAssertNotEqual(
            baseline,
            try makeContext(
                policy: HandshakePolicy(
                    requirePQC: false,
                    allowClassicFallback: false,
                    minimumTier: .qperiaptPQC
                )
            )
        )
        XCTAssertNotEqual(baseline, try makeContext(offeredSuites: Array(suites.reversed())))

        let changedCapabilities = CryptoCapabilities(
            supportedKEM: capabilities.supportedKEM,
            supportedSignature: capabilities.supportedSignature,
            supportedAuthProfiles: ["q-periapt-abi2-policy-v1/3/different-digest"],
            supportedAEAD: capabilities.supportedAEAD,
            pqcAvailable: capabilities.pqcAvailable,
            platformVersion: capabilities.platformVersion,
            providerType: capabilities.providerType
        )
        XCTAssertNotEqual(baseline, try makeContext(capabilities: changedCapabilities))

        var changedIdentity = identityPublicKey
        changedIdentity[0] ^= 0x01
        XCTAssertNotEqual(baseline, try makeContext(identityPublicKey: changedIdentity))
        XCTAssertNotEqual(baseline, try makeContext(extensionsRaw: Data([0x01, 0x02, 0x04])))
    }

    func testInvalidSuiteNonceKeyAndOfferFailClosed() throws {
        XCTAssertThrowsError(try makeContext(suite: .qperiaptContextBound)) { error in
            guard case CryptoProviderError.unsupportedAlgorithm = error else {
                return XCTFail("unexpected legacy-suite error: \(error)")
            }
        }
        XCTAssertThrowsError(try makeContext(clientNonce: Data(repeating: 0, count: 31))) { error in
            guard case CryptoProviderError.lengthMismatch(expected: 32, actual: 31) = error else {
                return XCTFail("unexpected nonce error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try makeContext(recipientPublicKey: Data(repeating: 0, count: recipientPublicKey.count - 1))
        ) { error in
            guard case CryptoProviderError.invalidKeyLength(
                expected: QPeriaptNativeAdapter.publicKeyLength,
                actual: QPeriaptNativeAdapter.publicKeyLength - 1,
                suite: _,
                usage: .keyExchange
            ) = error else {
                return XCTFail("unexpected recipient-key error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try makeContext(offeredSuites: [.qperiaptABI2PolicyBound, .qperiaptABI2PolicyBound])
        ) { error in
            guard case CryptoProviderError.operationFailed(let reason) = error else {
                return XCTFail("unexpected duplicate-offer error: \(error)")
            }
            XCTAssertTrue(reason.contains("non-canonical suite offer"))
        }
        XCTAssertThrowsError(
            try makeContext(offeredSuites: [.qperiaptABI2PolicyBound, .qperiaptContextBound])
        ) { error in
            guard case CryptoProviderError.operationFailed(let reason) = error else {
                return XCTFail("unexpected legacy-offer error: \(error)")
            }
            XCTAssertTrue(reason.contains("non-canonical suite offer"))
        }
    }

    private func makeContext(
        version: UInt8 = 1,
        suite: CryptoSuite = .qperiaptABI2PolicyBound,
        clientNonce: Data? = nil,
        recipientPublicKey: Data? = nil,
        policy: HandshakePolicy? = nil,
        offeredSuites: [CryptoSuite]? = nil,
        capabilities: CryptoCapabilities? = nil,
        identityPublicKey: Data? = nil,
        extensionsRaw: Data? = nil
    ) throws -> Data {
        try QPeriaptHandshakeApplicationContext.messageA(
            version: version,
            suite: suite,
            clientNonce: clientNonce ?? nonce,
            recipientPublicKey: recipientPublicKey ?? self.recipientPublicKey,
            policy: policy ?? self.policy,
            offeredSuites: offeredSuites ?? suites,
            capabilities: capabilities ?? self.capabilities,
            identityPublicKey: identityPublicKey ?? self.identityPublicKey,
            extensionsRaw: extensionsRaw ?? self.extensionsRaw
        )
    }
}
#endif
