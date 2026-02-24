import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class UnknownSuiteFallbackDenyTests: XCTestCase {
    func testSuiteNotSupportedIsBlockedAndNeverFallsBack() async {
        let tracker = AttemptTracker()

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshake(
                deviceId: "unknown-suite-blocked",
                preferPQC: true,
                policy: .default
            ) { strategy, _ in
                _ = await tracker.record(strategy: strategy)
                throw HandshakeError.failed(.suiteNotSupported)
            }
            XCTFail("Unknown/unsupported suite should fail without fallback")
        } catch let HandshakeError.failed(reason) {
            XCTAssertEqual(reason, .suiteNotSupported)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let attempts = await tracker.attempts()
        XCTAssertEqual(attempts.count, 1, "Unknown suite must not trigger classic fallback")
        XCTAssertEqual(attempts.first, .pqcOnly)
    }

    func testSuiteNegotiationFailedRemainsFallbackEligible() async throws {
        let tracker = AttemptTracker()
        _ = try await TwoAttemptHandshakeManager.performHandshake(
            deviceId: "suite-negotiation-fallback",
            preferPQC: true,
            policy: .default
        ) { strategy, _ in
            let index = await tracker.record(strategy: strategy)
            if index == 1 {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            return Self.mockSessionKeys()
        }

        let attempts = await tracker.attempts()
        XCTAssertEqual(attempts, [.pqcOnly, .classicOnly])
    }

    func testSuiteNotSupportedClassifiedAsBlockedReason() {
        XCTAssertFalse(
            TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNotSupported),
            "suiteNotSupported must be blocked and never fallback-eligible"
        )
    }

    private static func mockSessionKeys() -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "unknown-suite-test",
            createdAt: Date()
        )
    }
}

private actor AttemptTracker {
    private var values: [HandshakeAttemptStrategy] = []

    func record(strategy: HandshakeAttemptStrategy) -> Int {
        values.append(strategy)
        return values.count
    }

    func attempts() -> [HandshakeAttemptStrategy] {
        values
    }
}
