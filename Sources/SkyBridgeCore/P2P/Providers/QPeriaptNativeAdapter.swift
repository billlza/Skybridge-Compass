import Dispatch
import Foundation
import os
import SkyBridgeProtocolCore

#if canImport(CQPeriapt)
import CQPeriapt

public enum QPeriaptCryptoAdmissionError: Error, LocalizedError, Sendable, Equatable {
    case waiterLimitExceeded(maximum: Int)
    case waitDeadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .waiterLimitExceeded(let maximum):
            return "Q-Periapt crypto admission waiter limit exceeded: maximum=\(maximum)"
        case .waitDeadlineExceeded:
            return "Q-Periapt crypto admission wait exceeded the handshake deadline"
        }
    }
}

/// Bounds both execution and queued work before CPU-heavy Q-Periapt FFI calls.
actor QPeriaptCryptoAdmissionGate {
    static let shared = QPeriaptCryptoAdmissionGate()

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<UUID, any Error>
        let deadlineTask: Task<Void, Never>
    }

    private let maximumWaiters: Int
    private let maximumWaitDuration: Duration
    private let sleepUntilDeadline: @Sendable (Duration) async throws -> Void
    private var ownerToken: UUID?
    private var waiters: [Waiter] = []

    init(
        maximumWaiters: Int = 8,
        maximumWaitDuration: Duration = HandshakeConstants.defaultTimeout,
        sleepUntilDeadline: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        precondition(maximumWaiters >= 0)
        precondition(maximumWaitDuration > .zero)
        self.maximumWaiters = maximumWaiters
        self.maximumWaitDuration = maximumWaitDuration
        self.sleepUntilDeadline = sleepUntilDeadline
    }

    var pendingWaiterCount: Int {
        waiters.count
    }

    func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let token = try await acquire()
        defer { release(token: token) }
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    private func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let token = UUID()
        if ownerToken == nil {
            ownerToken = token
            return token
        }
        guard waiters.count < maximumWaiters else {
            throw QPeriaptCryptoAdmissionError.waiterLimitExceeded(maximum: maximumWaiters)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { [maximumWaitDuration, sleepUntilDeadline] in
                    do {
                        try await sleepUntilDeadline(maximumWaitDuration)
                    } catch {
                        return
                    }
                    self.expireWaiter(token: token)
                }
                waiters.append(
                    Waiter(
                        token: token,
                        continuation: continuation,
                        deadlineTask: deadlineTask
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
    }

    private func cancelWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: QPeriaptCryptoAdmissionError.waitDeadlineExceeded)
    }

    private func release(token: UUID) {
        precondition(ownerToken == token, "Only the active Q-Periapt admission owner may release it")
        guard !waiters.isEmpty else {
            ownerToken = nil
            return
        }
        let next = waiters.removeFirst()
        next.deadlineTask.cancel()
        ownerToken = next.token
        next.continuation.resume(returning: next.token)
    }
}

private final class QPeriaptCancellationState: Sendable {
    private let isCancelledStorage = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        isCancelledStorage.withLock { isCancelled in
            isCancelled = true
        }
    }

    func checkCancellation() throws {
        if isCancelledStorage.withLock({ $0 }) {
            throw CancellationError()
        }
    }
}

/// Executes native Q-Periapt FFI work on one private serial queue so synchronous
/// cryptography never occupies Swift's cooperative executor. Admission owns the
/// permit until the queue operation really returns; cancellation never pretends
/// that in-process native work was interrupted.
final class QPeriaptCryptoExecutor: Sendable {
    static let shared = QPeriaptCryptoExecutor()

    private let workerQueue: DispatchQueue

    init(workerQueue: DispatchQueue = DispatchQueue(
        label: "com.skybridge.compass.qperiapt.crypto",
        qos: .userInitiated
    )) {
        self.workerQueue = workerQueue
    }

    func resolveDecision(
        policyTOML: Data,
        signature: Data,
        verificationKey: Data,
        previousTrustedState: Data
    ) async throws -> QPeriaptPolicyDecision {
        try await execute {
            var encoded = Data(repeating: 0, count: QPeriaptPolicyDecision.encodedLength)
            let status = policyTOML.withUnsafeBytes { policyRaw in
                signature.withUnsafeBytes { signatureRaw in
                    verificationKey.withUnsafeBytes { keyRaw in
                        previousTrustedState.withUnsafeBytes { stateRaw in
                            encoded.withUnsafeMutableBytes { decisionRaw in
                                q_periapt_decision_from_signed_policy(
                                    policyRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(policyRaw.count),
                                    signatureRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(signatureRaw.count),
                                    keyRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(keyRaw.count),
                                    stateRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(stateRaw.count),
                                    decisionRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(decisionRaw.count)
                                )
                            }
                        }
                    }
                }
            }
            guard status == Int32(Q_PERIAPT_OK) else {
                encoded.resetBytes(in: 0..<encoded.count)
                throw QPeriaptPolicyRuntimeError.nativePolicyRejected(
                    status: status,
                    name: QPeriaptRuntimeContract.statusDescription(status)
                )
            }
            return try QPeriaptPolicyDecision(validating: encoded)
        }
    }

    func generateKeyPair(
        adapter: QPeriaptNativeAdapter
    ) async throws -> (publicKey: Data, privateKey: SecureBytes) {
        try await execute {
            try adapter.generateKeyPairSynchronously()
        }
    }

    func encapsulate(
        adapter: QPeriaptNativeAdapter,
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try await execute {
            try adapter.encapsulateSynchronously(
                recipientPublicKey: recipientPublicKey,
                applicationContext: applicationContext
            )
        }
    }

    func decapsulate(
        adapter: QPeriaptNativeAdapter,
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) async throws -> SecureBytes {
        try await execute {
            try adapter.decapsulateSynchronously(
                encapsulatedKey: encapsulatedKey,
                privateKey: privateKey,
                applicationContext: applicationContext
            )
        }
    }

    private func execute<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let cancellationState = QPeriaptCancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workerQueue.async {
                    do {
                        try cancellationState.checkCancellation()
                        let result = try operation()
                        try cancellationState.checkCancellation()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }

    #if DEBUG || SKYBRIDGE_TESTING
    func executeForTesting<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await execute(operation)
    }
    #endif
}

struct QPeriaptNativeAdapter: Sendable {
    static let publicKeyLength = Int(Q_PERIAPT_MLKEM768_PK_LEN) + Int(Q_PERIAPT_X25519_LEN)
    static let privateKeyLength = Int(Q_PERIAPT_MLKEM768_SK_LEN)
        + Int(Q_PERIAPT_X25519_LEN)
        + Int(Q_PERIAPT_MLKEM768_PK_LEN)
        + Int(Q_PERIAPT_X25519_LEN)
    static let encapsulatedKeyLength = Int(Q_PERIAPT_MLKEM768_CT_LEN) + Int(Q_PERIAPT_X25519_LEN)
    static let sharedSecretLength = Int(Q_PERIAPT_SECRET_LEN)
    static let maximumApplicationContextLength = Int(Q_PERIAPT_MAX_APPLICATION_CONTEXT_BYTES)

    let session: QPeriaptRuntimeSession

    func generateKeyPair() async throws -> (publicKey: Data, privateKey: SecureBytes) {
        try await QPeriaptCryptoAdmissionGate.shared.run {
            try await QPeriaptCryptoExecutor.shared.generateKeyPair(adapter: self)
        }
    }

    func encapsulate(
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try Self.validateApplicationContext(applicationContext)
        try Self.validateRecipientPublicKeyLength(recipientPublicKey.count)
        return try await QPeriaptCryptoAdmissionGate.shared.run {
            try await QPeriaptCryptoExecutor.shared.encapsulate(
                adapter: self,
                recipientPublicKey: recipientPublicKey,
                applicationContext: applicationContext
            )
        }
    }

    func decapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) async throws -> SecureBytes {
        try Self.validateApplicationContext(applicationContext)
        try Self.validatePrivateKeyLength(privateKey.byteCount)
        try Self.validateEncapsulatedKeyLength(encapsulatedKey.count)
        return try await QPeriaptCryptoAdmissionGate.shared.run {
            try await QPeriaptCryptoExecutor.shared.decapsulate(
                adapter: self,
                encapsulatedKey: encapsulatedKey,
                privateKey: privateKey,
                applicationContext: applicationContext
            )
        }
    }

    private static func validateApplicationContext(_ context: Data) throws {
        guard !context.isEmpty else {
            throw CryptoProviderError.operationFailed("Q-Periapt ABI2 application context must not be empty")
        }
        guard context.count <= maximumApplicationContextLength else {
            throw CryptoProviderError.lengthExceeded(
                "Q-Periapt application context",
                context.count,
                maximumApplicationContextLength
            )
        }
    }

    private static func validateRecipientPublicKeyLength(_ actual: Int) throws {
        guard actual == publicKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: publicKeyLength,
                actual: actual,
                suite: "Q-Periapt-ABI2-PolicyBound",
                usage: .keyExchange
            )
        }
    }

    private static func validatePrivateKeyLength(_ actual: Int) throws {
        guard actual == privateKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: privateKeyLength,
                actual: actual,
                suite: "Q-Periapt-ABI2-PolicyBound",
                usage: .keyExchange
            )
        }
    }

    private static func validateEncapsulatedKeyLength(_ actual: Int) throws {
        guard actual == encapsulatedKeyLength else {
            throw CryptoProviderError.operationFailed(
                "Invalid Q-Periapt ABI2 ciphertext length: expected \(encapsulatedKeyLength), got \(actual)"
            )
        }
    }

    fileprivate func generateKeyPairSynchronously() throws -> (
        publicKey: Data,
        privateKey: SecureBytes
    ) {
        try QPeriaptRuntimeContract.requireCompatible()

        let skPQ = SecureBytes(count: Int(Q_PERIAPT_MLKEM768_SK_LEN))
        let skTraditional = SecureBytes(count: Int(Q_PERIAPT_X25519_LEN))
        var pkPQ = Data(repeating: 0, count: Int(Q_PERIAPT_MLKEM768_PK_LEN))
        var pkTraditional = Data(repeating: 0, count: Int(Q_PERIAPT_X25519_LEN))

        let status = session.decision.encoded.withUnsafeBytes { decisionRaw in
            skPQ.withUnsafeMutableBytes { skPQRaw in
                pkPQ.withUnsafeMutableBytes { pkPQRaw in
                    skTraditional.withUnsafeMutableBytes { skTraditionalRaw in
                        pkTraditional.withUnsafeMutableBytes { pkTraditionalRaw in
                            q_periapt_generate_keypair(
                                decisionRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(decisionRaw.count),
                                skPQRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(skPQRaw.count),
                                pkPQRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(pkPQRaw.count),
                                skTraditionalRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(skTraditionalRaw.count),
                                pkTraditionalRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(pkTraditionalRaw.count)
                            )
                        }
                    }
                }
            }
        }
        guard status == Int32(Q_PERIAPT_OK) else {
            skPQ.zeroize()
            skTraditional.zeroize()
            pkPQ.resetBytes(in: 0..<pkPQ.count)
            pkTraditional.resetBytes(in: 0..<pkTraditional.count)
            throw CryptoProviderError.keyGenerationFailed(
                "Q-Periapt ABI2 generate_keypair failed: \(QPeriaptRuntimeContract.statusDescription(status))"
            )
        }

        var publicKey = Data(capacity: Self.publicKeyLength)
        publicKey.append(pkPQ)
        publicKey.append(pkTraditional)

        let privateKey = SecureBytes(count: Self.privateKeyLength)
        privateKey.withUnsafeMutableBytes { privateKeyRaw in
            var destinationOffset = 0
            func append(_ source: UnsafeRawBufferPointer) {
                precondition(source.count <= privateKeyRaw.count - destinationOffset)
                guard let sourceBaseAddress = source.baseAddress,
                      let destinationBaseAddress = privateKeyRaw.baseAddress else {
                    preconditionFailure("Q-Periapt ABI2 key material unexpectedly had no storage")
                }
                destinationBaseAddress
                    .advanced(by: destinationOffset)
                    .copyMemory(from: sourceBaseAddress, byteCount: source.count)
                destinationOffset += source.count
            }

            skPQ.withUnsafeBytes(append)
            skTraditional.withUnsafeBytes(append)
            pkPQ.withUnsafeBytes(append)
            pkTraditional.withUnsafeBytes(append)
            precondition(destinationOffset == privateKeyRaw.count)
        }
        guard publicKey.count == Self.publicKeyLength,
              privateKey.byteCount == Self.privateKeyLength else {
            privateKey.zeroize()
            throw CryptoProviderError.operationFailed("Q-Periapt ABI2 key blob assembly failed")
        }
        return (publicKey, privateKey)
    }

    fileprivate func encapsulateSynchronously(
        recipientPublicKey: Data,
        applicationContext: Data
    ) throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try QPeriaptRuntimeContract.requireCompatible()
        try Self.validateRecipientPublicKeyLength(recipientPublicKey.count)

        var ctPQ = Data(repeating: 0, count: Int(Q_PERIAPT_MLKEM768_CT_LEN))
        var ctTraditional = Data(repeating: 0, count: Int(Q_PERIAPT_X25519_LEN))
        let sharedSecret = SecureBytes(count: Self.sharedSecretLength)

        let status = session.decision.encoded.withUnsafeBytes { decisionRaw in
            recipientPublicKey.withUnsafeBytes { publicKeyRaw in
                applicationContext.withUnsafeBytes { contextRaw in
                    ctPQ.withUnsafeMutableBytes { ctPQRaw in
                        ctTraditional.withUnsafeMutableBytes { ctTraditionalRaw in
                            sharedSecret.withUnsafeMutableBytes { secretRaw in
                                let publicKey = publicKeyRaw.bindMemory(to: UInt8.self)
                                return q_periapt_encapsulate(
                                    decisionRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(decisionRaw.count),
                                    publicKey.baseAddress,
                                    UInt(Q_PERIAPT_MLKEM768_PK_LEN),
                                    publicKey.baseAddress?.advanced(by: Int(Q_PERIAPT_MLKEM768_PK_LEN)),
                                    UInt(Q_PERIAPT_X25519_LEN),
                                    contextRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(contextRaw.count),
                                    ctPQRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(ctPQRaw.count),
                                    ctTraditionalRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(ctTraditionalRaw.count),
                                    secretRaw.bindMemory(to: UInt8.self).baseAddress,
                                    UInt(secretRaw.count)
                                )
                            }
                        }
                    }
                }
            }
        }
        guard status == Int32(Q_PERIAPT_OK) else {
            ctPQ.resetBytes(in: 0..<ctPQ.count)
            ctTraditional.resetBytes(in: 0..<ctTraditional.count)
            sharedSecret.zeroize()
            throw CryptoProviderError.encapsulationFailed(
                "Q-Periapt ABI2 encapsulate failed: \(QPeriaptRuntimeContract.statusDescription(status))"
            )
        }

        var encapsulatedKey = Data(capacity: Self.encapsulatedKeyLength)
        encapsulatedKey.append(ctPQ)
        encapsulatedKey.append(ctTraditional)
        return (encapsulatedKey, sharedSecret)
    }

    fileprivate func decapsulateSynchronously(
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) throws -> SecureBytes {
        try QPeriaptRuntimeContract.requireCompatible()
        try Self.validatePrivateKeyLength(privateKey.byteCount)
        try Self.validateEncapsulatedKeyLength(encapsulatedKey.count)

        let sharedSecret = SecureBytes(count: Self.sharedSecretLength)
        let status = session.decision.encoded.withUnsafeBytes { decisionRaw in
            privateKey.withUnsafeBytes { privateKeyRaw in
                encapsulatedKey.withUnsafeBytes { ciphertextRaw in
                    applicationContext.withUnsafeBytes { contextRaw in
                        sharedSecret.withUnsafeMutableBytes { secretRaw in
                            let privateKeyBytes = privateKeyRaw.bindMemory(to: UInt8.self)
                            let ciphertext = ciphertextRaw.bindMemory(to: UInt8.self)
                            let skTraditionalOffset = Int(Q_PERIAPT_MLKEM768_SK_LEN)
                            let pkPQOffset = skTraditionalOffset + Int(Q_PERIAPT_X25519_LEN)
                            let pkTraditionalOffset = pkPQOffset + Int(Q_PERIAPT_MLKEM768_PK_LEN)
                            return q_periapt_decapsulate(
                                decisionRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(decisionRaw.count),
                                privateKeyBytes.baseAddress,
                                UInt(Q_PERIAPT_MLKEM768_SK_LEN),
                                ciphertext.baseAddress,
                                UInt(Q_PERIAPT_MLKEM768_CT_LEN),
                                privateKeyBytes.baseAddress?.advanced(by: pkPQOffset),
                                UInt(Q_PERIAPT_MLKEM768_PK_LEN),
                                privateKeyBytes.baseAddress?.advanced(by: skTraditionalOffset),
                                UInt(Q_PERIAPT_X25519_LEN),
                                ciphertext.baseAddress?.advanced(by: Int(Q_PERIAPT_MLKEM768_CT_LEN)),
                                UInt(Q_PERIAPT_X25519_LEN),
                                privateKeyBytes.baseAddress?.advanced(by: pkTraditionalOffset),
                                UInt(Q_PERIAPT_X25519_LEN),
                                contextRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(contextRaw.count),
                                secretRaw.bindMemory(to: UInt8.self).baseAddress,
                                UInt(secretRaw.count)
                            )
                        }
                    }
                }
            }
        }
        guard status == Int32(Q_PERIAPT_OK) else {
            sharedSecret.zeroize()
            throw CryptoProviderError.decapsulationFailed(
                "Q-Periapt ABI2 decapsulate failed: \(QPeriaptRuntimeContract.statusDescription(status))"
            )
        }
        return sharedSecret
    }
}
#endif
