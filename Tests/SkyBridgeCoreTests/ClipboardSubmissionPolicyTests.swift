#if os(macOS)
import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

@MainActor
final class ClipboardSubmissionPolicyTests: XCTestCase {
    func testStableSnapshotRejectsContentReadAcrossGenerations() {
        var changeCount = 7

        let result = P2PClipboardSnapshotPolicy.read(
            changeCount: { changeCount },
            value: {
                changeCount = 8
                return "stale-value"
            }
        )

        guard case .changed = result else {
            return XCTFail("A value read across pasteboard generations must not create a submission lease")
        }
    }

    func testStableSnapshotBindsValueToOneGeneration() {
        let result = P2PClipboardSnapshotPolicy.read(
            changeCount: { 23 },
            value: { "stable-value" }
        )

        guard case .stable(let value, let changeCount) = result else {
            return XCTFail("Expected a stable clipboard snapshot")
        }
        XCTAssertEqual(value, "stable-value")
        XCTAssertEqual(changeCount, 23)
    }

    func testCommittedHashDoesNotResubmitWithoutDeliveryDebt() {
        let convergence = P2PClipboardDeliveryConvergence()
        XCTAssertFalse(convergence.requiresSubmission(contentHash: "A", committedHash: "A"))
    }

    func testSuspendedRouteMarksCommittedHashForCompensation() async throws {
        let convergence = P2PClipboardDeliveryConvergence()
        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let routeAttempt = Task { @MainActor in
            try await convergence.attemptRoute {
                enteredContinuation.yield(())
                enteredContinuation.finish()
                for await _ in release {
                    break
                }
                try Task.checkCancellation()
            }
        }

        for await _ in entered {
            break
        }
        XCTAssertTrue(
            convergence.requiresSubmission(contentHash: "A", committedHash: "A"),
            "A superseding value must compensate for a possibly delivered B even when A is the committed hash"
        )
        let retryStart = ContinuousClock.now
        XCTAssertFalse(
            convergence.fullySubmitted(generation: 27, now: retryStart),
            "A newer successful route cannot settle while an older route may still deliver afterward"
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 27,
                now: retryStart.advanced(by: .milliseconds(999))
            )
        )

        routeAttempt.cancel()
        releaseContinuation.yield(())
        releaseContinuation.finish()
        do {
            try await routeAttempt.value
            XCTFail("A superseded route must observe cancellation")
        } catch is CancellationError {
            // Expected: cancellation does not erase possible-delivery state.
        }
        XCTAssertTrue(convergence.requiresSubmission(contentHash: "A", committedHash: "A"))

        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 27,
                now: retryStart.advanced(by: .seconds(1))
            )
        )
        XCTAssertTrue(
            convergence.fullySubmitted(
                generation: 27,
                now: retryStart.advanced(by: .seconds(1))
            )
        )
        XCTAssertFalse(convergence.requiresSubmission(contentHash: "A", committedHash: "A"))
    }

    func testFailedGenerationUsesCappedBackoffAndNewGenerationPreempts() throws {
        let convergence = try P2PClipboardDeliveryConvergence(
            initialRetryDelay: 1,
            maximumRetryDelay: 4
        )
        let start = ContinuousClock.now

        convergence.recordFailure(generation: 11, now: start)
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(999))
            )
        )
        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .seconds(1))
            )
        )

        convergence.recordFailure(
            generation: 11,
            now: start.advanced(by: .seconds(1))
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(2_999))
            )
        )
        XCTAssertTrue(
            convergence.mayAttempt(generation: 11, now: start.advanced(by: .seconds(3)))
        )
        convergence.recordFailure(
            generation: 11,
            now: start.advanced(by: .seconds(3))
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(6_999))
            )
        )
        XCTAssertTrue(
            convergence.mayAttempt(generation: 11, now: start.advanced(by: .seconds(7)))
        )
        convergence.recordFailure(
            generation: 11,
            now: start.advanced(by: .seconds(7))
        )
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(10_999))
            ),
            "Retry delay must remain capped at four seconds"
        )
        XCTAssertTrue(
            convergence.mayAttempt(generation: 11, now: start.advanced(by: .seconds(11)))
        )

        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 12,
                now: start.advanced(by: .milliseconds(7_100))
            ),
            "A newer pasteboard generation must not inherit the old generation's backoff"
        )
        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 11,
                now: start.advanced(by: .milliseconds(7_100))
            )
        )
    }

    func testAuthoritativeInboundWithSuspendedOldRouteSchedulesCompensation() async {
        let convergence = P2PClipboardDeliveryConvergence()
        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let oldRoute = Task { @MainActor in
            try await convergence.attemptRoute {
                enteredContinuation.yield(())
                enteredContinuation.finish()
                for await _ in release {
                    break
                }
                try Task.checkCancellation()
            }
        }
        for await _ in entered {
            break
        }

        let retryStart = ContinuousClock.now
        XCTAssertTrue(
            convergence.authoritativeInboundApplied(
                generation: 31,
                now: retryStart
            )
        )
        XCTAssertTrue(convergence.deliveryMayHaveOccurred)
        XCTAssertFalse(
            convergence.mayAttempt(
                generation: 31,
                now: retryStart.advanced(by: .milliseconds(999))
            )
        )

        oldRoute.cancel()
        releaseContinuation.yield(())
        releaseContinuation.finish()
        do {
            try await oldRoute.value
            XCTFail("The superseded route must observe cancellation")
        } catch is CancellationError {
            // Expected: the inbound generation remains pending for compensation.
        } catch {
            XCTFail("Unexpected route error: \(error)")
        }

        XCTAssertTrue(
            convergence.mayAttempt(
                generation: 31,
                now: retryStart.advanced(by: .seconds(1))
            )
        )
        XCTAssertTrue(
            convergence.fullySubmitted(
                generation: 31,
                now: retryStart.advanced(by: .seconds(1))
            )
        )
    }

    func testAuthoritativeInboundWithoutActiveRouteAvoidsReplay() async {
        let convergence = P2PClipboardDeliveryConvergence()
        do {
            try await convergence.attemptRoute {
                throw CancellationError()
            }
        } catch is CancellationError {
            // The potentially delivered route remains dirty until an authority wins.
        } catch {
            XCTFail("Unexpected route error: \(error)")
        }
        XCTAssertFalse(
            convergence.authoritativeInboundApplied(
                generation: 31,
                now: ContinuousClock.now
            )
        )

        XCTAssertFalse(convergence.deliveryMayHaveOccurred)
        XCTAssertFalse(
            convergence.requiresSubmission(contentHash: "remote", committedHash: "remote")
        )
    }

    func testInvalidRetryConfigurationFailsWithTypedError() {
        XCTAssertThrowsError(
            try P2PClipboardDeliveryConvergence(
                initialRetryDelay: 0,
                maximumRetryDelay: 4
            )
        ) { error in
            XCTAssertEqual(
                error as? P2PClipboardDeliveryConvergence.ConfigurationError,
                .invalidInitialRetryDelay(0)
            )
        }
        XCTAssertThrowsError(
            try P2PClipboardDeliveryConvergence(
                initialRetryDelay: 4,
                maximumRetryDelay: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? P2PClipboardDeliveryConvergence.ConfigurationError,
                .invalidMaximumRetryDelay(1)
            )
        }
    }
}
#endif
