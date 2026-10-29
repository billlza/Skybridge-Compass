import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class DowngradeEventTests: XCTestCase {

    func testStrictPQCEmitsNoFallbackEvents() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let noFallbackEvent = expectation(description: "No fallback event should be emitted")
        noFallbackEvent.isInverted = true

        let subscriptionId = await emitter.subscribe { event in
            if event.type == .cryptoDowngrade {
                noFallbackEvent.fulfill()
            }
        }
        defer { Task { await emitter.unsubscribe(subscriptionId) } }

        do {
            _ = try await TwoAttemptHandshakeManager.performHandshake(
                deviceId: "event-test-device",
                preferPQC: true,
                policy: .strictPQC,
                securityEventEmitter: emitter
            ) { _, _ in
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            XCTFail("Expected strictPQC to throw")
        } catch {
 // expected
        }

        await fulfillment(of: [noFallbackEvent], timeout: 0.2)
    }

    func testFallbackEventContextIsComplete() async throws {
        let emitter = SecurityEventEmitter.createForTesting()
        let fallbackEvent = expectation(description: "Fallback event should be emitted")
        let contextBox = EventContextBox()

        let subscriptionId = await emitter.subscribe { event in
            if event.type == .cryptoDowngrade {
                await contextBox.set(event.context)
                fallbackEvent.fulfill()
            }
        }
        defer { Task { await emitter.unsubscribe(subscriptionId) } }

        _ = try await TwoAttemptHandshakeManager.performHandshake(
            deviceId: "event-test-device",
            preferPQC: true,
            policy: .default,
            securityEventEmitter: emitter
        ) { strategy, _ in
            if strategy == .pqcOnly {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            return Self.makeSessionKeys()
        }

        await fulfillment(of: [fallbackEvent], timeout: 0.5)

        let capturedContext = await contextBox.get()
        XCTAssertEqual(capturedContext["deviceId"], SkyBridgeDiagnosticRedaction.redacted)
        XCTAssertNotEqual(capturedContext["deviceId"], "event-test-device")
        XCTAssertEqual(capturedContext["reason"], HandshakeFailureReason.suiteNegotiationFailed.diagnosticReasonCode)
        XCTAssertEqual(capturedContext["strategy"], HandshakeAttemptStrategy.classicOnly.rawValue)
        XCTAssertEqual(capturedContext["fromStrategy"], HandshakeAttemptStrategy.pqcOnly.rawValue)
        XCTAssertEqual(capturedContext["toStrategy"], HandshakeAttemptStrategy.classicOnly.rawValue)
        XCTAssertEqual(capturedContext["policyAllowClassicFallback"], "1")
    }

    private static func makeSessionKeys() -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "event-session",
            createdAt: Date()
        )
    }
}

private actor EventContextBox {
    private var context: [String: String] = [:]

    func set(_ value: [String: String]) {
        context = value
    }

    func get() -> [String: String] {
        context
    }
}
