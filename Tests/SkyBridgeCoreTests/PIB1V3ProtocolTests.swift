import XCTest
import CryptoKit
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class PIB1V3ProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var requesterFingerprint: String {
        ProtocolIdentityPublicKeys(
            protocolPublicKey: Data(repeating: 1, count: 32),
            protocolAlgorithm: .ed25519
        ).authoritativeFingerprint.lowercased()
    }
    private let responderFingerprint = String(repeating: "b", count: 64)

    func testV2RequestAndLegacyCandidateFailClosed() throws {
        let request = makeRequest(version: 2)
        let candidate = makeCandidate(request: request, version: 1)

        XCTAssertThrowsError(try candidate.validatedForOOBBinding(request: request, now: now)) { error in
            XCTAssertEqual(error as? AppMessage.ProtocolIdentityBindingValidationError, .invalidVersion)
        }
        XCTAssertNotEqual(request.version, AppMessage.ProtocolIdentityBindingRequestPayload.currentVersion)
    }

    func testRequestedProtocolSigningAlgorithmsAreNonEmptyKnownCanonicalAndUnique() throws {
        let cases: [([String], AppMessage.ProtocolIdentityBindingValidationError)] = [
            ([], .missingRequestedProtocolSigningAlgorithms),
            ([ProtocolSigningAlgorithm.mlDSA65.rawValue, "unknown"], .invalidRequestedProtocolSigningAlgorithm),
            ([ProtocolSigningAlgorithm.mlDSA65.rawValue, " ML-DSA-87"], .invalidRequestedProtocolSigningAlgorithm),
            ([ProtocolSigningAlgorithm.mlDSA87.rawValue, ProtocolSigningAlgorithm.mlDSA87.rawValue], .duplicateRequestedProtocolSigningAlgorithm)
        ]

        for (algorithms, expectedError) in cases {
            let request = requestWithAlgorithms(algorithms)
            XCTAssertThrowsError(try request.validatedRequestedProtocolSigningAlgorithms()) { error in
                XCTAssertEqual(
                    error as? AppMessage.ProtocolIdentityBindingValidationError,
                    expectedError
                )
            }
        }

        XCTAssertEqual(
            try requestWithAlgorithms([
                ProtocolSigningAlgorithm.mlDSA87.rawValue,
                ProtocolSigningAlgorithm.mlDSA65.rawValue
            ]).validatedRequestedProtocolSigningAlgorithms(),
            [.mlDSA87, .mlDSA65]
        )
    }

    func testCandidateCannotSelectAnUnrequestedProtocolSigningAlgorithm() throws {
        let request = requestWithAlgorithms([ProtocolSigningAlgorithm.ed25519.rawValue])
        let publicKey = Data(repeating: 0x65, count: 1_952)
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA65,
            publicKeyBytes: publicKey
        )
        let candidate = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: request.transactionId,
            deviceId: request.targetDeviceId,
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: publicKey,
            protocolIdentityFingerprint: fingerprint,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            signature: Data(repeating: 0x5A, count: 3_309)
        )

        XCTAssertThrowsError(try candidate.validatedForOOBBinding(request: request, now: now)) { error in
            XCTAssertEqual(
                error as? AppMessage.ProtocolIdentityBindingValidationError,
                .unrequestedResponseProtocolSigningAlgorithm
            )
        }
    }

    func testPIB1V3CrossPlatformGoldenVector() {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let transactionId = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let request = AppMessage.ProtocolIdentityBindingRequestPayload(
            transactionId: transactionId,
            requesterDeviceId: "id:ios-golden",
            targetDeviceId: "id:mac-golden",
            requestedProtocolSigningAlgorithms: ["Ed25519"],
            requesterProtocolSigningAlgorithm: "Ed25519",
            requesterProtocolIdentityPublicKey: Data(repeating: 0x22, count: 32),
            requesterProtocolIdentityFingerprint: String(repeating: "a", count: 64),
            requesterSignature: Data(repeating: 0x11, count: 64),
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: Data(0..<24),
            sentAt: fixedDate
        )
        let candidate = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: transactionId,
            deviceId: "id:mac-golden",
            aliases: ["id:mac-golden", "bonjour:mac-golden@local."],
            protocolSigningAlgorithm: "Ed25519",
            protocolIdentityPublicKey: Data(repeating: 0x44, count: 32),
            protocolIdentityFingerprint: String(repeating: "b", count: 64),
            deviceName: "Golden Mac",
            sentAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data(repeating: 0x33, count: 64)
        )
        let confirm = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: candidate.deviceId,
            requesterProtocolIdentityFingerprint: String(repeating: "a", count: 64),
            responderProtocolIdentityFingerprint: String(repeating: "b", count: 64),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: candidate.canonicalCandidateHashHex,
            sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
            confirmationNonce: Data(repeating: 0x55, count: 24),
            sentAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(300),
            requesterSignature: Data(repeating: 0x66, count: 64)
        )
        let ack = makeGoldenAck(
            request: request,
            candidate: candidate,
            confirm: confirm,
            fixedDate: fixedDate
        )
        XCTAssertEqual(
            request.canonicalRequestHashHex,
            "0b57a8713f6eba3c41061d38c1b33dcfa11750885976f0d5828916d3ac8f01ad"
        )
        XCTAssertEqual(
            candidate.canonicalCandidateHashHex,
            "4cbf643a7041361d658f6ba4d7960ec42a962e76275e38098de6a09ebf581e1a"
        )
        XCTAssertEqual(
            candidate.sasTranscriptHashHex(request: request),
            "724f79895460bfcb6e7136e637998b22285dca087573ed257678293c95ecd950"
        )
        XCTAssertEqual(
            confirm.canonicalConfirmHashHex,
            "78a1f5b29b7535479de0ea576fb778624b5bab359483e3024bbb61acf223566a"
        )
        XCTAssertEqual(
            SHA256.hash(data: ack.signaturePreimage)
                .map { String(format: "%02x", $0) }
                .joined(),
            "f6edad1347d9b1bd805e326491ca5a4fe52870dbfed233af6fc56ee38a89f760"
        )
    }

    func testConfirmBindsTransactionRequestCandidateAndFullSASTranscript() throws {
        let request = makeRequest()
        let candidate = makeCandidate(request: request)
        let confirm = makeConfirm(request: request, candidate: candidate)
        XCTAssertNoThrow(try confirm.validatedForCandidate(request: request, candidate: candidate, now: now))

        let wrongTranscript = AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: confirm.transactionId,
            requesterDeviceId: confirm.requesterDeviceId,
            responderDeviceId: confirm.responderDeviceId,
            requesterProtocolIdentityFingerprint: confirm.requesterProtocolIdentityFingerprint,
            responderProtocolIdentityFingerprint: confirm.responderProtocolIdentityFingerprint,
            requestNonce: confirm.requestNonce,
            requestHashHex: confirm.requestHashHex,
            candidateHashHex: confirm.candidateHashHex,
            sasTranscriptHashHex: String(repeating: "c", count: 64),
            confirmationNonce: confirm.confirmationNonce,
            sentAt: confirm.sentAt,
            expiresAt: confirm.expiresAt,
            requesterSignature: confirm.requesterSignature
        )
        XCTAssertThrowsError(try wrongTranscript.validatedForCandidate(request: request, candidate: candidate, now: now)) { error in
            XCTAssertEqual(error as? AppMessage.ProtocolIdentityBindingValidationError, .transcriptHashMismatch)
        }
    }

    func testTransactionStoreCapsActiveEntriesAndRejectsConflictingReuse() async throws {
        let store = ProtocolIdentityBindingTransactionStore.shared
        await store.clearForTesting()
        defer { Task { await store.clearForTesting() } }

        for index in 0..<32 {
            let request = makeRequest(
                transactionId: deterministicUUID(index),
                requesterKeyByte: UInt8(index + 1)
            )
            let candidate = makeCandidate(request: request)
            _ = try await store.register(request: request, candidate: candidate, now: now)
        }
        let activeCount = await store.countForTesting(now: now)
        XCTAssertEqual(activeCount, 32)

        let overflow = makeRequest(
            transactionId: deterministicUUID(32),
            requesterKeyByte: 33
        )
        await XCTAssertThrowsErrorAsync(
            try await store.register(request: overflow, candidate: makeCandidate(request: overflow), now: now)
        )

        let original = makeRequest(
            transactionId: deterministicUUID(0),
            requesterKeyByte: 1
        )
        let conflict = AppMessage.ProtocolIdentityBindingRequestPayload(
            transactionId: original.transactionId,
            requesterDeviceId: original.requesterDeviceId,
            targetDeviceId: "id:different-target",
            requestedProtocolSigningAlgorithms: original.requestedProtocolSigningAlgorithms,
            requesterProtocolSigningAlgorithm: original.requesterProtocolSigningAlgorithm,
            requesterProtocolIdentityPublicKey: original.requesterProtocolIdentityPublicKey,
            requesterProtocolIdentityFingerprint: original.requesterProtocolIdentityFingerprint,
            requesterSignature: original.requesterSignature,
            nonce: original.nonce,
            sentAt: original.sentAt
        )
        await XCTAssertThrowsErrorAsync(
            try await store.register(request: conflict, candidate: makeCandidate(request: conflict), now: now)
        )
    }

    func testTransactionStoreEnforcesRequesterFairShareWithoutBlockingAnotherIdentity() async throws {
        let store = ProtocolIdentityBindingTransactionStore.shared
        await store.clearForTesting()
        defer { Task { await store.clearForTesting() } }

        for index in 0..<4 {
            let request = makeRequest(transactionId: deterministicUUID(100 + index))
            let candidate = makeCandidate(request: request)
            _ = try await store.register(
                request: request,
                candidate: candidate,
                now: now
            )
            if index == 0 {
                for _ in 0..<12 {
                    _ = try await store.register(
                        request: request,
                        candidate: candidate,
                        now: now
                    )
                }
            }
        }
        let overQuota = makeRequest(transactionId: deterministicUUID(104))
        await XCTAssertThrowsErrorAsync(
            try await store.register(
                request: overQuota,
                candidate: makeCandidate(request: overQuota),
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtocolIdentityBindingTransactionStore.TransactionError,
                .requesterQuotaReached
            )
        }

        let otherRequester = makeRequest(
            transactionId: deterministicUUID(105),
            requesterKeyByte: 2
        )
        await XCTAssertNoThrowAsync(
            try await store.register(
                request: otherRequester,
                candidate: makeCandidate(request: otherRequester),
                now: now
            )
        )
    }

    func testTransactionStoreRateLimitsRapidFailedFinalizations() async throws {
        enum FixtureError: Error { case rejected }
        let store = ProtocolIdentityBindingTransactionStore.shared
        await store.clearForTesting()
        defer { Task { await store.clearForTesting() } }

        for index in 0..<8 {
            let request = makeRequest(transactionId: deterministicUUID(200 + index))
            let candidate = makeCandidate(request: request)
            _ = try await store.register(request: request, candidate: candidate, now: now)
            let confirm = makeConfirm(request: request, candidate: candidate)
            await XCTAssertThrowsErrorAsync(
                try await store.resolveConfirmation(confirm, now: now) { _ in
                    throw FixtureError.rejected
                }
            )
        }

        let limited = makeRequest(transactionId: deterministicUUID(208))
        await XCTAssertThrowsErrorAsync(
            try await store.register(
                request: limited,
                candidate: makeCandidate(request: limited),
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? ProtocolIdentityBindingTransactionStore.TransactionError,
                .requesterRateLimited
            )
        }

        let afterWindow = now.addingTimeInterval(11)
        let admitted = makeRequest(transactionId: deterministicUUID(209))
        _ = try await store.register(
            request: admitted,
            candidate: makeCandidate(request: admitted, sentAt: afterWindow),
            now: afterWindow
        )
    }

    func testInFlightFinalizationIsNotPurgedOrCancelledByAdmissionCleanup() async throws {
        let store = ProtocolIdentityBindingTransactionStore.shared
        await store.clearForTesting()
        defer { Task { await store.clearForTesting() } }
        let request = makeRequest(transactionId: deterministicUUID(300))
        let candidate = makeCandidate(request: request)
        _ = try await store.register(request: request, candidate: candidate, now: now)
        let confirm = makeConfirm(request: request, candidate: candidate)
        let expectedAck = makeAck(request: request, candidate: candidate, confirm: confirm)
        let gate = AsyncFinalizationGate()
        let finalizationNow = now

        let finalization = Task {
            try await store.resolveConfirmation(confirm, now: finalizationNow) { _ in
                await gate.waitForRelease()
                return expectedAck
            }
        }
        await gate.waitUntilStarted()

        let retainedCount = await store.countForTesting(now: now.addingTimeInterval(301))
        XCTAssertEqual(retainedCount, 1)
        await gate.release()
        let completedAck = try await finalization.value
        XCTAssertEqual(completedAck, expectedAck)
    }

    func testClearForTestingCancelsInFlightFinalization() async throws {
        let store = ProtocolIdentityBindingTransactionStore.shared
        await store.clearForTesting()
        let request = makeRequest(transactionId: deterministicUUID(400))
        let candidate = makeCandidate(request: request)
        _ = try await store.register(request: request, candidate: candidate, now: now)
        let confirm = makeConfirm(request: request, candidate: candidate)
        let started = AsyncCounter()
        let expectedAck = makeAck(request: request, candidate: candidate, confirm: confirm)
        let finalizationNow = now

        let finalization = Task {
            try await store.resolveConfirmation(confirm, now: finalizationNow) { _ in
                await started.increment()
                try await Task.sleep(for: .seconds(60))
                return expectedAck
            }
        }
        while await started.value == 0 {
            await Task.yield()
        }
        await store.clearForTesting()

        await XCTAssertThrowsErrorAsync(try await finalization.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testDuplicateConfirmationReturnsSameAckAndRunsCommitOnce() async throws {
        let store = ProtocolIdentityBindingTransactionStore.shared
        await store.clearForTesting()
        defer { Task { await store.clearForTesting() } }
        let request = makeRequest()
        let candidate = makeCandidate(request: request)
        _ = try await store.register(request: request, candidate: candidate, now: now)
        let confirm = makeConfirm(request: request, candidate: candidate)
        let expectedAck = makeAck(request: request, candidate: candidate, confirm: confirm)
        let counter = AsyncCounter()

        let first = try await store.resolveConfirmation(confirm, now: now) { _ in
            await counter.increment()
            return expectedAck
        }
        let replay = try await store.resolveConfirmation(confirm, now: now) { _ in
            XCTFail("Idempotent replay must return the stored final ACK")
            return expectedAck
        }

        let commitCount = await counter.value
        XCTAssertEqual(first, replay)
        XCTAssertEqual(commitCount, 1)
    }

    private func makeRequest(
        version: Int = AppMessage.ProtocolIdentityBindingRequestPayload.currentVersion,
        transactionId: UUID = UUID(),
        requesterKeyByte: UInt8 = 1
    ) -> AppMessage.ProtocolIdentityBindingRequestPayload {
        let publicKey = Data(repeating: requesterKeyByte, count: 32)
        let fingerprint = ProtocolIdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: .ed25519
        ).authoritativeFingerprint.lowercased()
        return AppMessage.ProtocolIdentityBindingRequestPayload(
            version: version,
            transactionId: transactionId,
            requesterDeviceId: "id:requester",
            targetDeviceId: "id:responder",
            requestedProtocolSigningAlgorithms: [ProtocolSigningAlgorithm.ed25519.rawValue],
            requesterProtocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            requesterProtocolIdentityPublicKey: publicKey,
            requesterProtocolIdentityFingerprint: fingerprint,
            requesterSignature: Data(repeating: 2, count: 64),
            nonce: Data(repeating: 3, count: 24),
            sentAt: now
        )
    }

    private func requestWithAlgorithms(
        _ algorithms: [String]
    ) -> AppMessage.ProtocolIdentityBindingRequestPayload {
        let original = makeRequest()
        return AppMessage.ProtocolIdentityBindingRequestPayload(
            version: original.version,
            transactionId: original.transactionId,
            requesterDeviceId: original.requesterDeviceId,
            targetDeviceId: original.targetDeviceId,
            requestedProtocolSigningAlgorithms: algorithms,
            requesterProtocolSigningAlgorithm: original.requesterProtocolSigningAlgorithm,
            requesterProtocolIdentityPublicKey: original.requesterProtocolIdentityPublicKey,
            requesterProtocolIdentityFingerprint: original.requesterProtocolIdentityFingerprint,
            requesterSignature: original.requesterSignature,
            policyRequirePQC: original.policyRequirePQC,
            policyAllowClassicFallback: original.policyAllowClassicFallback,
            routeScope: original.routeScope,
            bonjourEndpointDigest: original.bonjourEndpointDigest,
            nonce: original.nonce,
            sentAt: original.sentAt
        )
    }

    private func makeCandidate(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        version: Int = AppMessage.SignedProtocolIdentityBindingPayload.currentVersion,
        sentAt: Date? = nil
    ) -> AppMessage.SignedProtocolIdentityBindingPayload {
        let candidateSentAt = sentAt ?? now
        return AppMessage.SignedProtocolIdentityBindingPayload(
            version: version,
            transactionId: request.transactionId,
            deviceId: "id:responder",
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: Data(repeating: 4, count: 32),
            protocolIdentityFingerprint: responderFingerprint,
            sentAt: candidateSentAt,
            expiresAt: candidateSentAt.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            signature: Data(repeating: 5, count: 64)
        )
    }

    private func makeConfirm(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        candidate: AppMessage.SignedProtocolIdentityBindingPayload
    ) -> AppMessage.ProtocolIdentityBindingConfirmPayload {
        AppMessage.ProtocolIdentityBindingConfirmPayload(
            transactionId: request.transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: candidate.deviceId,
            requesterProtocolIdentityFingerprint: request.requesterProtocolIdentityFingerprint ?? "",
            responderProtocolIdentityFingerprint: responderFingerprint,
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: candidate.canonicalCandidateHashHex,
            sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
            confirmationNonce: Data(repeating: 6, count: 24),
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requesterSignature: Data(repeating: 7, count: 64)
        )
    }

    private func makeAck(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        candidate: AppMessage.SignedProtocolIdentityBindingPayload,
        confirm: AppMessage.ProtocolIdentityBindingConfirmPayload
    ) -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload {
        AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
            transactionId: request.transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: candidate.deviceId,
            requesterProtocolIdentityFingerprint: request.requesterProtocolIdentityFingerprint ?? "",
            responderProtocolIdentityFingerprint: responderFingerprint,
            requestNonce: request.nonce,
            confirmationNonce: confirm.confirmationNonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: candidate.canonicalCandidateHashHex,
            sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
            confirmHashHex: confirm.canonicalConfirmHashHex,
            accepted: true,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            responderSignature: Data(repeating: 8, count: 64)
        )
    }

    private func makeGoldenAck(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        candidate: AppMessage.SignedProtocolIdentityBindingPayload,
        confirm: AppMessage.ProtocolIdentityBindingConfirmPayload,
        fixedDate: Date
    ) -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload {
        AppMessage.SignedProtocolIdentityBindingFinalAckPayload(
            transactionId: request.transactionId,
            requesterDeviceId: request.requesterDeviceId,
            responderDeviceId: candidate.deviceId,
            requesterProtocolIdentityFingerprint: request.requesterProtocolIdentityFingerprint ?? "",
            responderProtocolIdentityFingerprint: candidate.protocolIdentityFingerprint,
            requestNonce: request.nonce,
            confirmationNonce: confirm.confirmationNonce,
            requestHashHex: request.canonicalRequestHashHex,
            candidateHashHex: candidate.canonicalCandidateHashHex,
            sasTranscriptHashHex: candidate.sasTranscriptHashHex(request: request),
            confirmHashHex: confirm.canonicalConfirmHashHex,
            accepted: true,
            sentAt: fixedDate,
            expiresAt: fixedDate.addingTimeInterval(300),
            responderSignature: Data(repeating: 0x77, count: 64)
        )
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

private actor AsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor AsyncFinalizationGate {
    private var started = false
    private var released = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        started = true
        let pendingStartContinuations = startContinuations
        startContinuations.removeAll()
        for continuation in pendingStartContinuations {
            continuation.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let pendingReleaseContinuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in pendingReleaseContinuations {
            continuation.resume()
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private func XCTAssertNoThrowAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Expected async expression not to throw: \(error)", file: file, line: line)
    }
}
