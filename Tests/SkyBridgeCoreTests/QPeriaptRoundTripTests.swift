import CryptoKit
import Foundation
import os
import XCTest
@testable import SkyBridgeCore

#if canImport(CQPeriapt)
import CQPeriapt

@available(macOS 14.0, iOS 17.0, *)
final class QPeriaptRoundTripTests: XCTestCase {
    private enum AdmissionTestError: Error {
        case timedOut
        case expectedFailure
    }

    private struct SignedPolicyVector: Decodable {
        let schemaVersion: Int
        let algorithm: String
        let policyTOML: String
        let verificationKey: String
        let signature: String
        let policyVersion: UInt32
        let decisionVersion: UInt8
        let selectedSuiteCode: UInt8
        let selectedProfileCode: UInt8
        let selectedKeyFormatCode: UInt8
        let policyDigest: String
        let lastTrustedVersionAccept: UInt32
        let lastTrustedVersionReject: UInt32
        let tamperSignatureByte: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case algorithm
            case policyTOML = "policy_toml"
            case verificationKey = "verification_key"
            case signature
            case policyVersion = "policy_version"
            case decisionVersion = "decision_version"
            case selectedSuiteCode = "selected_suite_code"
            case selectedProfileCode = "selected_profile_code"
            case selectedKeyFormatCode = "selected_key_format_code"
            case policyDigest = "policy_digest"
            case lastTrustedVersionAccept = "last_trusted_version_accept"
            case lastTrustedVersionReject = "last_trusted_version_reject"
            case tamperSignatureByte = "tamper_signature_byte"
        }
    }

    private actor InMemoryTrustedStateStore: QPeriaptTrustedStateStore {
        private static let fixtureTrustRootIdentifier = "test/q-periapt/abi2/upstream-vector"

        private var stateByTrustRoot: [String: Data]
        private let forceCASConflict: Bool
        private let compareAndSwapBarrier: AdmissionOperationBarrier?
        private var compareAndSwapCalls = 0

        init(
            initialState: Data? = nil,
            forceCASConflict: Bool = false,
            compareAndSwapBarrier: AdmissionOperationBarrier? = nil
        ) {
            if let initialState {
                self.stateByTrustRoot = [Self.fixtureTrustRootIdentifier: initialState]
            } else {
                self.stateByTrustRoot = [:]
            }
            self.forceCASConflict = forceCASConflict
            self.compareAndSwapBarrier = compareAndSwapBarrier
        }

        func loadTrustedState(trustRootIdentifier: String) async throws -> Data? {
            stateByTrustRoot[trustRootIdentifier]
        }

        func compareAndSwapTrustedState(
            expectedPreviousState: Data?,
            newState: Data,
            trustRootIdentifier: String
        ) async throws -> Bool {
            compareAndSwapCalls += 1
            if let compareAndSwapBarrier {
                await compareAndSwapBarrier.suspendUntilReleased()
            }
            guard !forceCASConflict,
                  stateByTrustRoot[trustRootIdentifier] == expectedPreviousState else {
                return false
            }
            stateByTrustRoot[trustRootIdentifier] = newState
            return true
        }

        func currentState(
            trustRootIdentifier: String = fixtureTrustRootIdentifier
        ) -> Data? {
            stateByTrustRoot[trustRootIdentifier]
        }

        func compareAndSwapCallCount() -> Int {
            compareAndSwapCalls
        }
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

    private struct FixedKEMIdentityStore: HandshakeKEMIdentityStore, Sendable {
        let publicKey: Data
        let privateKey: Data

        func getOrCreateKEMIdentityKey(
            for suite: CryptoSuite,
            provider: any CryptoProvider
        ) async throws -> HandshakeKEMIdentityMaterial {
            guard suite == .qperiaptABI2PolicyBound,
                  provider.supportsSuite(.qperiaptABI2PolicyBound) else {
                throw CryptoProviderError.unsupportedAlgorithm(suite.rawValue)
            }
            guard publicKey.count == QPeriaptNativeAdapter.publicKeyLength,
                  privateKey.count == QPeriaptNativeAdapter.privateKeyLength else {
                throw CryptoProviderError.operationFailed(
                    "Q-Periapt E2E fixture contains malformed KEM identity material"
                )
            }
            return HandshakeKEMIdentityMaterial(
                publicKey: publicKey,
                privateKey: SecureBytes(data: privateKey)
            )
        }
    }

    func testQPeriaptRuntimeMetadataMatchesFrozenABI2Contract() throws {
        XCTAssertEqual(q_periapt_abi_version(), QPeriaptRuntimeContract.expectedABIVersion)
        let versionPointer = try XCTUnwrap(q_periapt_version())
        XCTAssertEqual(String(cString: versionPointer), QPeriaptRuntimeContract.expectedRuntimeVersion)
        XCTAssertEqual(Int(q_periapt_fixed_suite_id_len()), QPeriaptRuntimeContract.expectedSuiteID.count)
        XCTAssertTrue(QPeriaptRuntimeContract.isCompatible)
        XCTAssertNoThrow(try QPeriaptRuntimeContract.requireCompatible())

        let suitePointer = try XCTUnwrap(q_periapt_fixed_suite_id())
        let exportedSuite = Data(
            bytes: suitePointer,
            count: Int(q_periapt_fixed_suite_id_len())
        )
        XCTAssertEqual(exportedSuite, Data(QPeriaptRuntimeContract.expectedSuiteID))
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
        let gate = QPeriaptCryptoAdmissionGate(
            maximumWaiters: 1,
            maximumWaitDuration: .seconds(1),
            sleepUntilDeadline: { _ in
                await deadlineBarrier.suspendUntilReleased()
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

        let expiringWaiter = Task {
            try await gate.run { 2 }
        }
        try await waitForAdmissionWaiterCount(1, on: gate)
        await deadlineBarrier.waitUntilEntered()
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

    func testSignedPolicyFixtureIsExactUpstreamReleaseVector() throws {
        let fixtureData = try loadFixtureData()
        XCTAssertEqual(
            Data(SHA256.hash(data: fixtureData)).hexString,
            "83110fa4c73679e7b4b8d117cffe4f8388408500de2a354fb3d7982a129382f5"
        )

        let vector = try decodeFixture(fixtureData)
        XCTAssertEqual(vector.schemaVersion, 1)
        XCTAssertEqual(vector.algorithm, "ML-DSA-65")
        XCTAssertEqual(vector.policyVersion, 2)
        XCTAssertEqual(vector.decisionVersion, UInt8(Q_PERIAPT_POLICY_DECISION_VERSION))
        XCTAssertEqual(vector.selectedSuiteCode, UInt8(Q_PERIAPT_SUITE_MLKEM768_X25519))
        XCTAssertEqual(vector.selectedProfileCode, UInt8(Q_PERIAPT_PROFILE_CONTEXT_BOUND))
        XCTAssertEqual(vector.selectedKeyFormatCode, UInt8(Q_PERIAPT_KEY_FORMAT_EXPANDED))
    }

    func testSignedPolicyResolutionCommitsStateBeforePublishingSession() async throws {
        let vector = try loadFixture()
        let store = InMemoryTrustedStateStore()
        let session = try await QPeriaptPolicyRuntime().resolveSession(
            material: try makeMaterial(vector: vector),
            enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
            trustedStateStore: store
        )

        let expectedDigest = try XCTUnwrap(Data(hexString: vector.policyDigest))
        XCTAssertEqual(session.policyVersion, vector.policyVersion)
        XCTAssertEqual(session.policyDigest, expectedDigest)
        XCTAssertEqual(session.trustRootIdentifier, "test/q-periapt/abi2/upstream-vector")
        XCTAssertEqual(
            session.authProfile,
            "q-periapt-abi2-policy-v1/\(vector.policyVersion)/\(vector.policyDigest)"
        )

        let currentState = await store.currentState()
        let persistedState = try XCTUnwrap(currentState)
        XCTAssertEqual(persistedState.count, Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN))
        XCTAssertEqual(persistedState, session.decision.trustedState)
    }

    func testCancellationAfterNativeDecisionDoesNotAttemptTrustedStateCommit() async throws {
        let vector = try loadFixture()
        let material = try makeMaterial(vector: vector)
        let preCommitBarrier = AdmissionOperationBarrier()
        let store = InMemoryTrustedStateStore()
        let runtime = QPeriaptPolicyRuntime(afterDecisionBeforeCommitForTesting: {
            await preCommitBarrier.suspendUntilReleased()
        })
        let resolution = Task {
            try await runtime.resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: store
            )
        }

        await preCommitBarrier.waitUntilEntered()
        resolution.cancel()
        await preCommitBarrier.release()
        do {
            _ = try await resolution.value
            XCTFail("A policy cancelled after native verification must not enter CAS")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let compareAndSwapCalls = await store.compareAndSwapCallCount()
        let currentState = await store.currentState()
        XCTAssertEqual(compareAndSwapCalls, 0)
        XCTAssertNil(currentState)
    }

    func testCancellationAfterCASBeginsPreservesKnownCommittedResult() async throws {
        let vector = try loadFixture()
        let material = try makeMaterial(vector: vector)
        let commitBarrier = AdmissionOperationBarrier()
        let store = InMemoryTrustedStateStore(compareAndSwapBarrier: commitBarrier)
        let resolution = Task {
            try await QPeriaptPolicyRuntime().resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: store
            )
        }

        await commitBarrier.waitUntilEntered()
        resolution.cancel()
        await commitBarrier.release()
        let session = try await resolution.value

        let compareAndSwapCalls = await store.compareAndSwapCallCount()
        let currentState = await store.currentState()
        XCTAssertEqual(compareAndSwapCalls, 1)
        XCTAssertEqual(currentState, session.decision.trustedState)
    }

    func testExistingEnrollmentRejectsMissingTrustedState() async throws {
        let vector = try loadFixture()
        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: try makeMaterial(vector: vector),
                enrollmentMode: .existingEnrollment,
                trustedStateStore: InMemoryTrustedStateStore()
            )
            XCTFail("existing enrollment must not reinterpret missing state as first use")
        } catch QPeriaptPolicyRuntimeError.missingTrustedState {
            // Expected fail-closed boundary.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSignedPolicyRejectsVerificationKeyPinMismatch() async throws {
        let vector = try loadFixture()
        var material = try makeMaterial(vector: vector)
        material = QPeriaptSignedPolicyMaterial(
            policyTOML: material.policyTOML,
            detachedSignature: material.detachedSignature,
            verificationKey: material.verificationKey,
            verificationKeySHA256Pin: Data(repeating: 0xA5, count: SHA256.byteCount),
            trustRootIdentifier: material.trustRootIdentifier
        )

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: InMemoryTrustedStateStore()
            )
            XCTFail("a verification key that misses its independent pin must be rejected")
        } catch QPeriaptPolicyRuntimeError.verificationKeyPinMismatch {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSignedPolicyRejectsTamperedSignature() async throws {
        let vector = try loadFixture()
        let validMaterial = try makeMaterial(vector: vector)
        var tamperedSignature = validMaterial.detachedSignature
        tamperedSignature[vector.tamperSignatureByte] ^= 0x01
        let tamperedMaterial = QPeriaptSignedPolicyMaterial(
            policyTOML: validMaterial.policyTOML,
            detachedSignature: tamperedSignature,
            verificationKey: validMaterial.verificationKey,
            verificationKeySHA256Pin: validMaterial.verificationKeySHA256Pin,
            trustRootIdentifier: validMaterial.trustRootIdentifier
        )

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: tamperedMaterial,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: InMemoryTrustedStateStore()
            )
            XCTFail("tampered signed policy must not produce a runtime session")
        } catch QPeriaptPolicyRuntimeError.nativePolicyRejected(let status, _) {
            XCTAssertEqual(status, Int32(Q_PERIAPT_ERR_POLICY))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPolicyRollbackAndConcurrentStateChangeAreRejected() async throws {
        let vector = try loadFixture()
        let digest = try XCTUnwrap(Data(hexString: vector.policyDigest))
        let rollbackState = trustedState(version: vector.lastTrustedVersionReject, digest: digest)

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: try makeMaterial(vector: vector),
                enrollmentMode: .existingEnrollment,
                trustedStateStore: InMemoryTrustedStateStore(initialState: rollbackState)
            )
            XCTFail("policy rollback must be rejected by the native ABI2 decision boundary")
        } catch QPeriaptPolicyRuntimeError.nativePolicyRejected(let status, _) {
            XCTAssertEqual(status, Int32(Q_PERIAPT_ERR_POLICY))
        } catch {
            XCTFail("unexpected rollback error: \(error)")
        }

        do {
            _ = try await QPeriaptPolicyRuntime().resolveSession(
                material: try makeMaterial(vector: vector),
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: InMemoryTrustedStateStore(forceCASConflict: true)
            )
            XCTFail("a concurrent trusted-state change must prevent session publication")
        } catch QPeriaptPolicyRuntimeError.trustedStateChangedConcurrently {
            // Expected.
        } catch {
            XCTFail("unexpected CAS error: \(error)")
        }
    }

    func testQPeriaptKEMRoundTripIsBoundToExplicitApplicationContext() async throws {
        let session = try await makeSession()
        let provider = QPeriaptCryptoProvider(session: session)
        XCTAssertEqual(provider.tier, CryptoTier.qperiaptPQC)
        XCTAssertEqual(provider.activeSuite, CryptoSuite.qperiaptABI2PolicyBound)

        let keyPair = try await provider.generateKeyPair(for: KeyUsage.keyExchange)
        XCTAssertEqual(keyPair.publicKey.bytes.count, QPeriaptNativeAdapter.publicKeyLength)
        XCTAssertEqual(keyPair.privateKey.bytes.count, QPeriaptNativeAdapter.privateKeyLength)

        let context = Data("skybridge/qperiapt/abi2/roundtrip-context/v1".utf8)
        let encapsulated = try await provider.kemEncapsulate(
            recipientPublicKey: keyPair.publicKey.bytes,
            applicationContext: context
        )
        XCTAssertEqual(encapsulated.encapsulatedKey.count, QPeriaptNativeAdapter.encapsulatedKeyLength)

        let recipientPrivateKey = SecureBytes(data: keyPair.privateKey.bytes)
        let decapsulated = try await provider.kemDecapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: recipientPrivateKey,
            applicationContext: context
        )
        var senderSecret = encapsulated.sharedSecret.copyData()
        var recipientSecret = decapsulated.copyData()
        defer {
            senderSecret.resetBytes(in: 0..<senderSecret.count)
            recipientSecret.resetBytes(in: 0..<recipientSecret.count)
        }
        XCTAssertEqual(senderSecret.count, QPeriaptNativeAdapter.sharedSecretLength)
        XCTAssertEqual(senderSecret, recipientSecret)
        XCTAssertNotEqual(senderSecret, Data(repeating: 0, count: senderSecret.count))

        let wrongContextSecret = try await provider.kemDecapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: recipientPrivateKey,
            applicationContext: Data("skybridge/qperiapt/abi2/wrong-context/v1".utf8)
        )
        var wrongContextData = wrongContextSecret.copyData()
        defer { wrongContextData.resetBytes(in: 0..<wrongContextData.count) }
        XCTAssertNotEqual(senderSecret, wrongContextData)
    }

    func testContextFreeKEMSurfacesFailClosed() async throws {
        let session = try await makeSession()
        let provider = QPeriaptCryptoProvider(session: session)
        let keyPair = try await provider.generateKeyPair(for: KeyUsage.keyExchange)

        do {
            _ = try await provider.kemEncapsulate(recipientPublicKey: keyPair.publicKey.bytes)
            XCTFail("context-free Q-Periapt encapsulation must be unavailable")
        } catch CryptoProviderError.operationFailed(let reason) {
            XCTAssertTrue(reason.contains("application context"))
        } catch {
            XCTFail("unexpected context-free encapsulation error: \(error)")
        }

        XCTAssertThrowsError(
            try QPeriaptKEMProvider(session: session, applicationContext: Data())
        ) { error in
            guard case CryptoProviderError.operationFailed(let reason) = error else {
                return XCTFail("unexpected empty-context error: \(error)")
            }
            XCTAssertTrue(reason.contains("non-empty application context"))
        }
    }

    func testQPeriaptDEMAuthenticatesCiphertextAndContext() async throws {
        let provider = QPeriaptCryptoProvider(session: try await makeSession())
        let keyPair = try await provider.generateKeyPair(for: KeyUsage.keyExchange)
        let message = Data("Q-Periapt ABI2 policy-bound DEM self-consistency".utf8)
        let context = Data("skybridge/qperiapt/abi2/dem-context/v1".utf8)

        let sealed = try await provider.kemDemSealWithSecret(
            plaintext: message,
            recipientPublicKey: keyPair.publicKey.bytes,
            info: context
        )
        let recipientPrivateKey = SecureBytes(data: keyPair.privateKey.bytes)
        let opened = try await provider.kemDemOpenWithSecret(
            sealedBox: sealed.sealedBox,
            privateKey: recipientPrivateKey,
            info: context
        )
        XCTAssertEqual(opened.plaintext, message)

        var senderSecret = sealed.sharedSecret.copyData()
        var recipientSecret = opened.sharedSecret.copyData()
        defer {
            senderSecret.resetBytes(in: 0..<senderSecret.count)
            recipientSecret.resetBytes(in: 0..<recipientSecret.count)
        }
        XCTAssertEqual(senderSecret, recipientSecret)

        var tamperedCiphertext = sealed.sealedBox.ciphertext
        let firstIndex = try XCTUnwrap(tamperedCiphertext.indices.first)
        tamperedCiphertext[firstIndex] ^= 0x01
        let tamperedBox = HPKESealedBox(
            encapsulatedKey: sealed.sealedBox.encapsulatedKey,
            nonce: sealed.sealedBox.nonce,
            ciphertext: tamperedCiphertext,
            tag: sealed.sealedBox.tag
        )
        do {
            _ = try await provider.kemDemOpenWithSecret(
                sealedBox: tamperedBox,
                privateKey: recipientPrivateKey,
                info: context
            )
            XCTFail("AES-GCM must reject tampered ciphertext")
        } catch CryptoKitError.authenticationFailure {
            // Expected authenticated-encryption failure.
        } catch {
            XCTFail("unexpected tamper error: \(error)")
        }
    }

    func testNativeRuntimeProbePassesWithAuthenticatedSession() async throws {
        let session = try await makeSession()
        let probePassed = try await QPeriaptCryptoProvider.quickRuntimeProbe(session: session)
        XCTAssertTrue(probePassed)
    }

    func testHandshakePeerEligibilityRequiresExactAuthenticatedPolicyIdentity() async throws {
        let session = try await makeSession()
        let exactCapabilities = CryptoCapabilities(
            supportedKEM: [P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue],
            supportedSignature: [P2PCryptoAlgorithm.mlDSA65.rawValue],
            supportedAuthProfiles: [session.authProfile],
            supportedAEAD: [P2PCryptoAlgorithm.aes256GCM.rawValue],
            pqcAvailable: true,
            platformVersion: "macOS 26.0",
            providerType: .qPeriapt
        )
        XCTAssertTrue(QPeriaptPlatformPolicy.isHandshakePeerEligible(exactCapabilities, for: session))

        let wrongPolicy = CryptoCapabilities(
            supportedKEM: exactCapabilities.supportedKEM,
            supportedSignature: exactCapabilities.supportedSignature,
            supportedAuthProfiles: [session.authProfile + "-different"],
            supportedAEAD: exactCapabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: exactCapabilities.platformVersion,
            providerType: .qPeriapt
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(wrongPolicy, for: session))

        let wrongProvider = CryptoCapabilities(
            supportedKEM: exactCapabilities.supportedKEM,
            supportedSignature: exactCapabilities.supportedSignature,
            supportedAuthProfiles: exactCapabilities.supportedAuthProfiles,
            supportedAEAD: exactCapabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: exactCapabilities.platformVersion,
            providerType: .cryptoKitPQC
        )
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(wrongProvider, for: session))
    }

    func testAuthenticatedABI2SessionCompletesNativeHandshakeContextEndToEnd() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("Q-Periapt runtime admission is intentionally unavailable before Apple OS 26.")
        }
        await HandshakeReplayCache.shared.clearForTesting()
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()

        let requestEnvironmentKey = "SB_ENABLE_QPERIAPT"
        let previousRequestValue = ProcessInfo.processInfo.environment[requestEnvironmentKey]
        setenv(requestEnvironmentKey, "1", 1)
        defer {
            if let previousRequestValue {
                setenv(requestEnvironmentKey, previousRequestValue, 1)
            } else {
                unsetenv(requestEnvironmentKey)
            }
            QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        }

        let session = try await makeSession()
        try await QPeriaptPlatformPolicy.activateRuntimeSession(session)
        XCTAssertTrue(QPeriaptPlatformPolicy.isEnabledForLocalRuntime())
        XCTAssertEqual(QPeriaptPlatformPolicy.authProfile, session.authProfile)

        let provider = QPeriaptCryptoProvider(session: session)
        let responderKEMKeyPair = try await provider.generateKeyPair(for: .keyExchange)
        let responderKEMStore = FixedKEMIdentityStore(
            publicKey: responderKEMKeyPair.publicKey.bytes,
            privateKey: responderKEMKeyPair.privateKey.bytes
        )
        let initiatorSigningKeyPair = try await provider.generateKeyPair(for: .signing)
        let responderSigningKeyPair = try await provider.generateKeyPair(for: .signing)
        let signatureProvider = PQCSignatureProvider(backend: .oqs)
        let handshakePolicy = HandshakePolicy(
            requirePQC: true,
            allowClassicFallback: false,
            minimumTier: .qperiaptPQC
        )
        let cryptoPolicy = CryptoPolicy(
            minimumSecurityTier: .hybridPreferred,
            allowExperimentalHybrid: true,
            advertiseHybrid: true,
            requireHybridIfAvailable: true
        )

        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            cryptoPolicy: cryptoPolicy,
            peerKEMPublicKeys: [
                .qperiaptABI2PolicyBound: responderKEMKeyPair.publicKey.bytes
            ]
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            cryptoPolicy: cryptoPolicy,
            kemIdentityStore: responderKEMStore
        )
        addTeardownBlock {
            await initiator.zeroize()
            await responder.zeroize()
        }

        let initiatorIdentity = encodeIdentityPublicKey(
            initiatorSigningKeyPair.publicKey.bytes,
            algorithm: .mlDSA65
        )
        let responderIdentity = encodeIdentityPublicKey(
            responderSigningKeyPair.publicKey.bytes,
            algorithm: .mlDSA65
        )
        let extensionValue = Data("qperiapt-native-handshake-e2e/v1".utf8)
        var extensionBinding = Data([0xEF, 0xBE])
        var extensionLength = UInt16(extensionValue.count).littleEndian
        withUnsafeBytes(of: &extensionLength) { extensionBinding.append(contentsOf: $0) }
        extensionBinding.append(extensionValue)

        let outboundMessageA = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigningKeyPair.privateKey.bytes),
            identityPublicKey: initiatorIdentity,
            policy: handshakePolicy,
            offeredSuites: [.qperiaptABI2PolicyBound],
            extensionsRaw: extensionBinding
        )
        let messageA = try HandshakeMessageA.decode(from: outboundMessageA.encoded)

        XCTAssertEqual(messageA.supportedSuites, [.qperiaptABI2PolicyBound])
        XCTAssertEqual(messageA.keyShares.count, 1)
        XCTAssertEqual(
            messageA.keyShares[0].shareBytes.count,
            QPeriaptNativeAdapter.encapsulatedKeyLength
        )
        XCTAssertEqual(messageA.extensionsRaw, extensionBinding)
        XCTAssertEqual(messageA.capabilities.providerType, .qPeriapt)
        XCTAssertEqual(messageA.capabilities.supportedAuthProfiles.first, session.authProfile)

        try await responder.processMessageA(messageA, policy: handshakePolicy)
        let outboundResponse = try await responder.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigningKeyPair.privateKey.bytes),
            identityPublicKey: responderIdentity,
            policy: handshakePolicy
        )
        let messageB = try HandshakeMessageB.decode(from: outboundResponse.message.encoded)

        XCTAssertEqual(messageB.selectedSuite, .qperiaptABI2PolicyBound)
        XCTAssertTrue(messageB.responderShare.isEmpty)
        XCTAssertTrue(messageB.encryptedPayload.encapsulatedKey.isEmpty)

        let initiatorKeys = try await initiator.processMessageB(
            messageB,
            policy: handshakePolicy
        )
        let responderKeys = try await responder.finalizeResponderSessionKeys(
            sharedSecret: outboundResponse.sharedSecret
        )

        XCTAssertEqual(initiatorKeys.negotiatedSuite, .qperiaptABI2PolicyBound)
        XCTAssertEqual(responderKeys.negotiatedSuite, .qperiaptABI2PolicyBound)
        XCTAssertEqual(initiatorKeys.role, .initiator)
        XCTAssertEqual(responderKeys.role, .responder)
        XCTAssertEqual(initiatorKeys.sendKey, responderKeys.receiveKey)
        XCTAssertEqual(initiatorKeys.receiveKey, responderKeys.sendKey)
        XCTAssertEqual(initiatorKeys.transcriptHash, responderKeys.transcriptHash)
        XCTAssertEqual(initiatorKeys.sessionId, responderKeys.sessionId)

        await initiator.zeroize()
        await responder.zeroize()
        QPeriaptPlatformPolicy.resetRuntimeSessionForTesting()
        XCTAssertFalse(QPeriaptPlatformPolicy.isLocalRuntimeSupported)
        XCTAssertFalse(QPeriaptPlatformPolicy.isHandshakePeerEligible(messageA.capabilities))
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

    private func makeSession() async throws -> QPeriaptRuntimeSession {
        let vector = try loadFixture()
        return try await QPeriaptPolicyRuntime().resolveSession(
            material: try makeMaterial(vector: vector),
            enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
            trustedStateStore: InMemoryTrustedStateStore()
        )
    }

    private func makeMaterial(vector: SignedPolicyVector) throws -> QPeriaptSignedPolicyMaterial {
        let verificationKey = try XCTUnwrap(Data(hexString: vector.verificationKey))
        return QPeriaptSignedPolicyMaterial(
            policyTOML: Data(vector.policyTOML.utf8),
            detachedSignature: try XCTUnwrap(Data(hexString: vector.signature)),
            verificationKey: verificationKey,
            verificationKeySHA256Pin: Data(SHA256.hash(data: verificationKey)),
            trustRootIdentifier: "test/q-periapt/abi2/upstream-vector"
        )
    }

    private func trustedState(version: UInt32, digest: Data) -> Data {
        var state = Data([
            UInt8((version >> 24) & 0xFF),
            UInt8((version >> 16) & 0xFF),
            UInt8((version >> 8) & 0xFF),
            UInt8(version & 0xFF)
        ])
        state.append(digest)
        return state
    }

    private func loadFixture() throws -> SignedPolicyVector {
        try decodeFixture(loadFixtureData())
    }

    private func decodeFixture(_ data: Data) throws -> SignedPolicyVector {
        try JSONDecoder().decode(SignedPolicyVector.self, from: data)
    }

    private func loadFixtureData() throws -> Data {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "signed-policy-vectors", withExtension: "json")
        )
        return try Data(contentsOf: fixtureURL, options: [.mappedIfSafe])
    }
}
#endif
