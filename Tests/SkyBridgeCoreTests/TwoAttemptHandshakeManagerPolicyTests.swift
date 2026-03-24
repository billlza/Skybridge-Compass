import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class TwoAttemptHandshakeManagerPolicyTests: XCTestCase {

    private final class MockCryptoProvider: CryptoProvider, @unchecked Sendable {
        let providerName = "PolicyTestMockProvider"
        let tier: CryptoTier = .nativePQC
        let activeSuite: CryptoSuite = .mlkem768MLDSA65
        let supportedSuites: [CryptoSuite] = [.mlkem768MLDSA65, .x25519Ed25519]

        func supportsSuite(_ suite: CryptoSuite) -> Bool {
            supportedSuites.contains { $0.wireId == suite.wireId }
        }

        func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
            throw CryptoProviderError.notImplemented("Mock")
        }

        func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
            throw CryptoProviderError.notImplemented("Mock")
        }

        func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
            throw CryptoProviderError.notImplemented("Mock")
        }

        func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
            throw CryptoProviderError.notImplemented("Mock")
        }

        func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
            throw CryptoProviderError.notImplemented("Mock")
        }
    }

    func testStrictPQCBlocksFallbackOnPQCUnavailable() async {
        let tracker = AttemptTracker()
        let strategyTracker = StrategyTracker()

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshake(
                deviceId: "policy-test-device",
                preferPQC: true,
                policy: .strictPQC
            ) { strategy, _ in
                await strategyTracker.record(strategy)
                let count = await tracker.increment()
                if count == 1 {
                    throw HandshakeError.failed(.suiteNegotiationFailed)
                }
                return Self.makeSessionKeys()
            }
            XCTFail("Expected strictPQC to fail without fallback")
        } catch {
            let attempts = await tracker.count
            XCTAssertEqual(attempts, 1, "strictPQC should not attempt classic fallback")
            let strategies = await strategyTracker.strategies()
            XCTAssertEqual(strategies, [.pqcOnly], "strictPQC should only attempt PQC")
        }
    }

    func testDefaultPolicyAllowsClassicFallback() async throws {
        let tracker = AttemptTracker()
        let strategyTracker = StrategyTracker()

        _ = try await TwoAttemptHandshakeManager.performHandshake(
            deviceId: "policy-test-device",
            preferPQC: true,
            policy: .default
        ) { strategy, _ in
            await strategyTracker.record(strategy)
            let count = await tracker.increment()
            if count == 1 {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            return Self.makeSessionKeys()
        }

        let attempts = await tracker.count
        XCTAssertEqual(attempts, 2, "default policy should allow classic fallback after PQC failure")
        let strategies = await strategyTracker.strategies()
        XCTAssertEqual(strategies, [.pqcOnly, .classicOnly], "default policy should fallback to classic")
    }

    func testDefaultPolicyFallsBackToClassicWhenBridgeRetryFails() async throws {
        let tracker = AttemptTracker()
        let strategyTracker = StrategyTracker()
        let provider = MockCryptoProvider()

        _ = try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
            deviceId: "policy-test-device",
            preferPQC: true,
            policy: .default,
            cryptoProvider: provider
        ) { preparation in
            await strategyTracker.record(preparation.strategy)
            let count = await tracker.increment()
            if count <= 2 {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            XCTAssertEqual(preparation.strategy, .classicOnly, "third attempt should be classic fallback")
            return Self.makeSessionKeys()
        }

        let attempts = await tracker.count
        XCTAssertEqual(attempts, 3, "bridge retry failure should still allow classic fallback")
        let strategies = await strategyTracker.strategies()
        XCTAssertEqual(strategies, [.pqcOnly, .pqcOnly, .classicOnly])
    }

    func testRequirePQCOverridesAllowClassicFallback() {
        let policy = HandshakePolicy(requirePQC: true, allowClassicFallback: true, minimumTier: .classic)
        XCTAssertTrue(policy.requirePQC)
        XCTAssertFalse(policy.allowClassicFallback, "requirePQC must force allowClassicFallback=false")
    }

    private static func makeSessionKeys() -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "policy-session",
            createdAt: Date()
        )
    }
}

private actor AttemptTracker {
    private var value = 0

    var count: Int { value }

    func increment() -> Int {
        value += 1
        return value
    }
}

private actor StrategyTracker {
    private var recorded: [HandshakeAttemptStrategy] = []

    func record(_ strategy: HandshakeAttemptStrategy) {
        recorded.append(strategy)
    }

    func strategies() -> [HandshakeAttemptStrategy] {
        recorded
    }
}
