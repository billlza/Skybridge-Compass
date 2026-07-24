import CryptoKit
import Foundation
import os
import XCTest
@testable import SkyBridgeQPeriaptRuntime

@available(macOS 14.0, iOS 17.0, *)
final class QPeriaptAdmissionRuntimeTests: XCTestCase {
    private enum AdmissionTestError: Error {
        case timedOut
        case expectedFailure
    }

    private actor AdmissionOperationBarrier {
        private var didEnter = false
        private var isReleased = false
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func suspendUntilReleased() async {
            precondition(!didEnter)
            didEnter = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                precondition(releaseContinuation == nil)
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            guard !didEnter else { return }
            await withCheckedContinuation { continuation in
                precondition(enteredContinuation == nil)
                enteredContinuation = continuation
            }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor AdmissionExecutionProbe {
        private var count = 0

        func record() {
            count += 1
        }

        func snapshot() -> Int {
            count
        }
    }

    private final class AdmissionManualClock: Sendable {
        private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock().now)

        func now() -> ContinuousClock.Instant {
            instant.withLock { $0 }
        }

        func advance(by duration: Duration) {
            instant.withLock { value in
                value = value.advanced(by: duration)
            }
        }
    }

    private final class NativeWorkerProbe: Sendable {
        private struct State: Sendable {
            var firstOperationEntered = false
            var firstOperationReleased = false
            var cancelledOperationExecutions = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func blockFirstOperationUntilReleased() {
            state.withLock { $0.firstOperationEntered = true }
            while !state.withLock({ $0.firstOperationReleased }) {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        func releaseFirstOperation() {
            state.withLock { $0.firstOperationReleased = true }
        }

        func hasEnteredFirstOperation() -> Bool {
            state.withLock { $0.firstOperationEntered }
        }

        func recordCancelledOperationExecution() {
            state.withLock { $0.cancelledOperationExecutions += 1 }
        }

        func cancelledOperationExecutionCount() -> Int {
            state.withLock { $0.cancelledOperationExecutions }
        }
    }

    func testQPeriaptCryptoAdmissionRejectsWhenQueueIsDisabled() async throws {
        let boundedGate = QPeriaptCryptoAdmissionGate(maximumWaiters: 0)
        let boundedBarrier = AdmissionOperationBarrier()
        let owner = Task {
            try await boundedGate.run {
                await boundedBarrier.suspendUntilReleased()
                return 1
            }
        }
        await boundedBarrier.waitUntilEntered()
        do {
            _ = try await boundedGate.run { 2 }
            XCTFail("Admission must fail fast when the configured queue is full")
        } catch {
            XCTAssertEqual(
                error as? QPeriaptCryptoAdmissionError,
                .waiterLimitExceeded(maximum: 0)
            )
        }
        await boundedBarrier.release()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult, 1)
    }

    func testQPeriaptCryptoAdmissionRemovesCancelledQueuedWorkBeforeOwnerRelease() async throws {
        let cancellationGate = QPeriaptCryptoAdmissionGate(maximumWaiters: 1)
        let cancellationBarrier = AdmissionOperationBarrier()
        let executionProbe = AdmissionExecutionProbe()
        let cancellationOwner = Task {
            try await cancellationGate.run {
                await cancellationBarrier.suspendUntilReleased()
                return 1
            }
        }
        defer {
            cancellationOwner.cancel()
            Task { await cancellationBarrier.release() }
        }
        await cancellationBarrier.waitUntilEntered()
        let cancelledWaiter = Task {
            try await cancellationGate.run {
                await executionProbe.record()
                return 2
            }
        }
        try await waitForAdmissionWaiterCount(1, on: cancellationGate)
        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("A cancelled queued crypto operation must never execute")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let pendingWaiterCountAfterCancellation = await cancellationGate.pendingWaiterCount
        XCTAssertEqual(
            pendingWaiterCountAfterCancellation,
            0,
            "Cancellation must remove the waiter while the current owner is still running"
        )
        let executionCount = await executionProbe.snapshot()
        XCTAssertEqual(executionCount, 0)

        let replacementWaiter = Task {
            try await cancellationGate.run { 3 }
        }
        defer { replacementWaiter.cancel() }
        try await waitForAdmissionWaiterCount(1, on: cancellationGate)
        await cancellationBarrier.release()
        let cancellationOwnerResult = try await cancellationOwner.value
        XCTAssertEqual(cancellationOwnerResult, 1)
        let replacementResult = try await replacementWaiter.value
        XCTAssertEqual(replacementResult, 3)
    }

    func testQPeriaptCryptoAdmissionClosesCancellationRaceBeforeWaiterAppend() async throws {
        let ownerBarrier = AdmissionOperationBarrier()
        let executionProbe = AdmissionExecutionProbe()
        let gate = QPeriaptCryptoAdmissionGate(
            maximumWaiters: 1,
            beforeWaiterAppendForTesting: {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
        )
        let owner = Task {
            try await gate.run {
                await ownerBarrier.suspendUntilReleased()
                return 1
            }
        }
        defer {
            owner.cancel()
            Task { await ownerBarrier.release() }
        }
        await ownerBarrier.waitUntilEntered()

        let cancelledWaiter = Task {
            try await gate.run {
                await executionProbe.record()
                return 2
            }
        }
        do {
            _ = try await cancelledWaiter.value
            XCTFail("Cancellation before waiter append must reject admission")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let pendingWaiterCount = await gate.pendingWaiterCount
        let executionCount = await executionProbe.snapshot()
        XCTAssertEqual(pendingWaiterCount, 0)
        XCTAssertEqual(executionCount, 0)
        await ownerBarrier.release()
        let ownerValue = try await owner.value
        XCTAssertEqual(ownerValue, 1)
    }

    func testQPeriaptCryptoAdmissionDefaultQueueRejectsNinthWaiter() async throws {
        let gate = QPeriaptCryptoAdmissionGate()
        let ownerBarrier = AdmissionOperationBarrier()
        let owner = Task {
            try await gate.run {
                await ownerBarrier.suspendUntilReleased()
                return -1
            }
        }
        defer {
            owner.cancel()
            Task { await ownerBarrier.release() }
        }
        await ownerBarrier.waitUntilEntered()

        let acceptedWaiters = (0..<8).map { value in
            Task {
                try await gate.run { value }
            }
        }
        defer { acceptedWaiters.forEach { $0.cancel() } }
        try await waitForAdmissionWaiterCount(8, on: gate)

        do {
            _ = try await gate.run { 8 }
            XCTFail("The ninth queued operation must fail at the production admission limit")
        } catch {
            XCTAssertEqual(
                error as? QPeriaptCryptoAdmissionError,
                .waiterLimitExceeded(maximum: 8)
            )
        }

        await ownerBarrier.release()
        let ownerValue = try await owner.value
        XCTAssertEqual(ownerValue, -1)
        var completedValues: [Int] = []
        for waiter in acceptedWaiters {
            completedValues.append(try await waiter.value)
        }
        XCTAssertEqual(Set(completedValues), Set(0..<8))
    }

    func testQPeriaptCryptoAdmissionRejectsResultCancelledAfterOperation() async {
        let gate = QPeriaptCryptoAdmissionGate(maximumWaiters: 0)
        let executionProbe = AdmissionExecutionProbe()
        let operation = Task {
            try await gate.run {
                await executionProbe.record()
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return 1
            }
        }

        do {
            _ = try await operation.value
            XCTFail("Cancellation observed after native work must reject its result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let executionCount = await executionProbe.snapshot()
        XCTAssertEqual(executionCount, 1)
    }

    func testQPeriaptCryptoAdmissionDeadlineRemovesWaiterAndRestoresCapacity() async throws {
        let deadlineBarrier = AdmissionOperationBarrier()
        let ownerBarrier = AdmissionOperationBarrier()
        let clock = AdmissionManualClock()
        let gate = QPeriaptCryptoAdmissionGate(
            maximumWaiters: 1,
            maximumWaitDuration: .seconds(1),
            sleepUntilDeadline: { _ in
                await deadlineBarrier.suspendUntilReleased()
            },
            now: { clock.now() }
        )
        let owner = Task {
            try await gate.run {
                await ownerBarrier.suspendUntilReleased()
                return 1
            }
        }
        defer {
            owner.cancel()
            Task { await ownerBarrier.release() }
        }
        await ownerBarrier.waitUntilEntered()

        let expiringWaiter = Task {
            try await gate.run { 2 }
        }
        try await waitForAdmissionWaiterCount(1, on: gate)
        await deadlineBarrier.waitUntilEntered()
        clock.advance(by: .seconds(1))
        await deadlineBarrier.release()
        do {
            _ = try await expiringWaiter.value
            XCTFail("A queued crypto operation must not outlive its admission deadline")
        } catch {
            XCTAssertEqual(
                error as? QPeriaptCryptoAdmissionError,
                .waitDeadlineExceeded
            )
        }
        let pendingWaiterCountAfterDeadline = await gate.pendingWaiterCount
        XCTAssertEqual(pendingWaiterCountAfterDeadline, 0)

        await ownerBarrier.release()
        let ownerValue = try await owner.value
        let replacementValue = try await gate.run { 3 }
        XCTAssertEqual(ownerValue, 1)
        XCTAssertEqual(replacementValue, 3)
    }

    func testQPeriaptCryptoAdmissionReleaseRejectsAlreadyExpiredWaiterBeforeSleeperRuns() async throws {
        let deadlineBarrier = AdmissionOperationBarrier()
        let ownerBarrier = AdmissionOperationBarrier()
        let executionProbe = AdmissionExecutionProbe()
        let clock = AdmissionManualClock()
        let gate = QPeriaptCryptoAdmissionGate(
            maximumWaiters: 1,
            maximumWaitDuration: .seconds(1),
            sleepUntilDeadline: { _ in
                await deadlineBarrier.suspendUntilReleased()
            },
            now: { clock.now() }
        )
        let owner = Task {
            try await gate.run {
                await ownerBarrier.suspendUntilReleased()
                return 1
            }
        }
        defer {
            owner.cancel()
            Task {
                await ownerBarrier.release()
                await deadlineBarrier.release()
            }
        }
        await ownerBarrier.waitUntilEntered()

        let waiter = Task {
            try await gate.run {
                await executionProbe.record()
                return 2
            }
        }
        try await waitForAdmissionWaiterCount(1, on: gate)
        await deadlineBarrier.waitUntilEntered()
        clock.advance(by: .seconds(1))

        // Deliberately release the owner before waking the sleeper. The gate
        // itself must observe the absolute deadline and reject the waiter.
        await ownerBarrier.release()
        let ownerValue = try await owner.value
        XCTAssertEqual(ownerValue, 1)
        do {
            _ = try await waiter.value
            XCTFail("An expired waiter must not receive a permit when release wins actor scheduling")
        } catch {
            XCTAssertEqual(error as? QPeriaptCryptoAdmissionError, .waitDeadlineExceeded)
        }
        let expiredExecutionCount = await executionProbe.snapshot()
        let expiredPendingCount = await gate.pendingWaiterCount
        XCTAssertEqual(expiredExecutionCount, 0)
        XCTAssertEqual(expiredPendingCount, 0)
        await deadlineBarrier.release()
    }

    func testQPeriaptCryptoAdmissionPrunesExpiredWaiterBeforeCapacityCheck() async throws {
        let ownerBarrier = AdmissionOperationBarrier()
        let clock = AdmissionManualClock()
        let gate = QPeriaptCryptoAdmissionGate(
            maximumWaiters: 1,
            maximumWaitDuration: .seconds(1),
            sleepUntilDeadline: { _ in
                try await Task.sleep(for: .seconds(60))
            },
            now: { clock.now() }
        )
        let owner = Task {
            try await gate.run {
                await ownerBarrier.suspendUntilReleased()
                return 1
            }
        }
        defer {
            owner.cancel()
            Task { await ownerBarrier.release() }
        }
        await ownerBarrier.waitUntilEntered()

        let expiredWaiter = Task {
            try await gate.run { 2 }
        }
        try await waitForAdmissionWaiterCount(1, on: gate)
        clock.advance(by: .seconds(1))

        let replacement = Task {
            try await gate.run { 3 }
        }
        let replacementDeadline = ContinuousClock().now.advanced(by: .seconds(2))
        while await gate.hasElapsedPendingWaiterForTesting {
            guard ContinuousClock().now < replacementDeadline else {
                XCTFail("Replacement admission did not prune the expired waiter")
                throw AdmissionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let replacementWaiterCount = await gate.pendingWaiterCount
        XCTAssertEqual(replacementWaiterCount, 1)
        do {
            _ = try await expiredWaiter.value
            XCTFail("Expired waiters must be evicted before a new capacity decision")
        } catch {
            XCTAssertEqual(error as? QPeriaptCryptoAdmissionError, .waitDeadlineExceeded)
        }

        await ownerBarrier.release()
        let ownerValue = try await owner.value
        let replacementValue = try await replacement.value
        XCTAssertEqual(ownerValue, 1)
        XCTAssertEqual(replacementValue, 3)
    }

    func testQPeriaptCryptoAdmissionKeepsCancelledOwnerPermitUntilOperationReturns() async throws {
        let gate = QPeriaptCryptoAdmissionGate(maximumWaiters: 1)
        let ownerBarrier = AdmissionOperationBarrier()
        let secondExecution = AdmissionExecutionProbe()
        let owner = Task {
            try await gate.run {
                await ownerBarrier.suspendUntilReleased()
                return 1
            }
        }
        defer {
            owner.cancel()
            Task { await ownerBarrier.release() }
        }
        await ownerBarrier.waitUntilEntered()

        let second = Task {
            try await gate.run {
                await secondExecution.record()
                return 2
            }
        }
        defer { second.cancel() }
        try await waitForAdmissionWaiterCount(1, on: gate)

        owner.cancel()
        try await Task.sleep(for: .milliseconds(20))
        let executionCountBeforeOwnerReturn = await secondExecution.snapshot()
        XCTAssertEqual(
            executionCountBeforeOwnerReturn,
            0,
            "Cancelling an active owner must not release admission while its operation is still running"
        )

        await ownerBarrier.release()
        do {
            _ = try await owner.value
            XCTFail("The cancelled owner result must be rejected after its operation returns")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, 2)
        let finalExecutionCount = await secondExecution.snapshot()
        let finalPendingCount = await gate.pendingWaiterCount
        XCTAssertEqual(finalExecutionCount, 1)
        XCTAssertEqual(finalPendingCount, 0)
    }

    func testQPeriaptCryptoAdmissionReleasesPermitAfterOperationFailure() async throws {
        let gate = QPeriaptCryptoAdmissionGate(maximumWaiters: 1)
        do {
            _ = try await gate.run { () -> Int in
                throw AdmissionTestError.expectedFailure
            }
            XCTFail("The fixture operation must throw")
        } catch AdmissionTestError.expectedFailure {
            // Expected; defer must still release the owner permit.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let nextValue = try await gate.run { 7 }
        let pendingWaiterCount = await gate.pendingWaiterCount
        XCTAssertEqual(nextValue, 7)
        XCTAssertEqual(pendingWaiterCount, 0)
    }

    @MainActor
    func testQPeriaptNativeExecutorUsesDedicatedQueueAndSkipsCancelledQueuedWork() async throws {
        let executor = QPeriaptCryptoExecutor()
        let executesOnMainThread = try await executor.executeForTesting { Thread.isMainThread }
        XCTAssertFalse(executesOnMainThread)

        let probe = NativeWorkerProbe()
        let owner = Task {
            try await executor.executeForTesting {
                probe.blockFirstOperationUntilReleased()
                return 1
            }
        }
        defer {
            probe.releaseFirstOperation()
            owner.cancel()
        }
        try await Self.waitForNativeWorkerEntry(probe)

        let cancelled = Task {
            try await executor.executeForTesting {
                probe.recordCancelledOperationExecution()
                return 2
            }
        }
        cancelled.cancel()
        probe.releaseFirstOperation()
        let ownerValue = try await owner.value
        XCTAssertEqual(ownerValue, 1)
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled queued operation must not enter native work")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.cancelledOperationExecutionCount(), 0)
    }

    func testNativeKEMBoundaryValidationRunsBeforeSharedAdmission() async throws {
        let adapter = QPeriaptNativeAdapter<QPeriaptSecretBytes>(
            session: try makeSession()
        )
        let ownerBarrier = AdmissionOperationBarrier()
        let owner = Task {
            try await QPeriaptCryptoAdmissionGate.shared.run {
                await ownerBarrier.suspendUntilReleased()
            }
        }
        defer {
            owner.cancel()
            Task { await ownerBarrier.release() }
        }
        await ownerBarrier.waitUntilEntered()

        do {
            _ = try await adapter.encapsulate(
                recipientPublicKey: Data(repeating: 0, count: 1),
                applicationContext: Data("context".utf8)
            )
            XCTFail("malformed public key reached admission")
        } catch let error as QPeriaptNativeError {
            XCTAssertEqual(
                error,
                .invalidRecipientPublicKeyLength(
                    expected: QPeriaptNativeAdapter<QPeriaptSecretBytes>.publicKeyLength,
                    actual: 1
                )
            )
        }

        do {
            _ = try await adapter.encapsulate(
                recipientPublicKey: Data(
                    repeating: 0,
                    count: QPeriaptNativeAdapter<QPeriaptSecretBytes>.publicKeyLength
                ),
                applicationContext: Data()
            )
            XCTFail("empty context reached admission")
        } catch let error as QPeriaptNativeError {
            XCTAssertEqual(error, .emptyApplicationContext)
        }

        let nativeBoundaryWaiters = await QPeriaptCryptoAdmissionGate.shared.pendingWaiterCount
        XCTAssertEqual(nativeBoundaryWaiters, 0)
        await ownerBarrier.release()
        try await owner.value
    }

    func testPolicyBoundaryValidationRunsBeforeSharedAdmission() async throws {
        let verificationKey = Data(repeating: 0x42, count: 1_952)
        let material = QPeriaptSignedPolicyMaterial(
            policyTOML: Data(),
            detachedSignature: Data(repeating: 0x24, count: 3_309),
            verificationKey: verificationKey,
            verificationKeySHA256Pin: Data(SHA256.hash(data: verificationKey)),
            trustRootIdentifier: "test/q-periapt/admission"
        )
        let ownerBarrier = AdmissionOperationBarrier()
        let owner = Task {
            try await QPeriaptCryptoAdmissionGate.shared.run {
                await ownerBarrier.suspendUntilReleased()
            }
        }
        defer {
            owner.cancel()
            Task { await ownerBarrier.release() }
        }
        await ownerBarrier.waitUntilEntered()

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: UnreachableTrustedStateStore()
            )
            XCTFail("malformed policy reached admission")
        } catch QPeriaptPolicyRuntimeError.emptyPolicy {
            // Expected before store load or native admission.
        }

        let policyBoundaryWaiters = await QPeriaptCryptoAdmissionGate.shared.pendingWaiterCount
        XCTAssertEqual(policyBoundaryWaiters, 0)
        await ownerBarrier.release()
        try await owner.value
    }

    private func waitForAdmissionWaiterCount(
        _ expectedCount: Int,
        on gate: QPeriaptCryptoAdmissionGate,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await gate.pendingWaiterCount != expectedCount {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for Q-Periapt admission waiter count \(expectedCount)")
                throw AdmissionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func waitForNativeWorkerEntry(
        _ probe: NativeWorkerProbe,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !probe.hasEnteredFirstOperation() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for the Q-Periapt native worker")
                throw AdmissionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeSession() throws -> QPeriaptRuntimeSession {
        var encoded = Data([1, 1, 2, 1])
        var version = UInt32(1).bigEndian
        withUnsafeBytes(of: &version) { encoded.append(contentsOf: $0) }
        encoded.append(Data(repeating: 0x5A, count: 32))
        return QPeriaptRuntimeSession(
            decision: try QPeriaptPolicyDecision(validating: encoded),
            trustRootIdentifier: "test/q-periapt/admission",
            trustRootFingerprint: Data(repeating: 0xA5, count: 32)
        )
    }

}

private struct UnreachableTrustedStateStore: QPeriaptTrustedStateStore {
    func loadTrustedState(trustRootIdentifier: String) async throws -> Data? {
        XCTFail("policy boundary validation must run before state load")
        return nil
    }

    func compareAndSwapTrustedState(
        expectedPreviousState: Data?,
        newState: Data,
        trustRootIdentifier: String
    ) async throws -> Bool {
        XCTFail("policy boundary validation must run before state commit")
        return false
    }
}
