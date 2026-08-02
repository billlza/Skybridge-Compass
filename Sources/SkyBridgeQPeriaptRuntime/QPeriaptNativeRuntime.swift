import CQPeriapt
import Dispatch
import Foundation
import os

public enum QPeriaptCryptoAdmissionError: Error, LocalizedError, Sendable, Equatable {
    case waiterLimitExceeded(maximum: Int)
    case waitDeadlineExceeded
    case invalidMaximumWaiters(Int)
    case invalidMaximumWaitDuration
    case ownerMismatch

    public var errorDescription: String? {
        switch self {
        case .waiterLimitExceeded(let maximum):
            return "Q-Periapt crypto admission waiter limit exceeded: maximum=\(maximum)"
        case .waitDeadlineExceeded:
            return "Q-Periapt crypto admission wait exceeded the operation deadline"
        case .invalidMaximumWaiters(let value):
            return "Q-Periapt crypto admission maximum waiters must not be negative: \(value)"
        case .invalidMaximumWaitDuration:
            return "Q-Periapt crypto admission maximum wait duration must be positive"
        case .ownerMismatch:
            return "Q-Periapt crypto admission permit owner mismatch"
        }
    }
}

public enum QPeriaptNativeError: Error, LocalizedError, Sendable, Equatable {
    case runtimeContract(QPeriaptRuntimeContractError)
    case emptyApplicationContext
    case applicationContextTooLarge(actual: Int, maximum: Int)
    case invalidRecipientPublicKeyLength(expected: Int, actual: Int)
    case invalidPrivateKeyLength(expected: Int, actual: Int)
    case invalidCiphertextLength(expected: Int, actual: Int)
    case keyBlobAssemblyFailed
    case keyGenerationFailed(status: Int32, name: String)
    case encapsulationFailed(status: Int32, name: String)
    case decapsulationFailed(status: Int32, name: String)

    public var errorDescription: String? {
        switch self {
        case .runtimeContract(let error):
            return error.localizedDescription
        case .emptyApplicationContext:
            return "Q-Periapt ABI2 application context must not be empty"
        case .applicationContextTooLarge(let actual, let maximum):
            return "Q-Periapt application context is too large: \(actual) > \(maximum)"
        case .invalidRecipientPublicKeyLength(let expected, let actual):
            return "Invalid Q-Periapt ABI2 public-key length: expected \(expected), got \(actual)"
        case .invalidPrivateKeyLength(let expected, let actual):
            return "Invalid Q-Periapt ABI2 private-key length: expected \(expected), got \(actual)"
        case .invalidCiphertextLength(let expected, let actual):
            return "Invalid Q-Periapt ABI2 ciphertext length: expected \(expected), got \(actual)"
        case .keyBlobAssemblyFailed:
            return "Q-Periapt ABI2 key blob assembly failed"
        case .keyGenerationFailed(_, let name):
            return "Q-Periapt ABI2 generate_keypair failed: \(name)"
        case .encapsulationFailed(_, let name):
            return "Q-Periapt ABI2 encapsulate failed: \(name)"
        case .decapsulationFailed(_, let name):
            return "Q-Periapt ABI2 decapsulate failed: \(name)"
        }
    }
}

/// One owner plus a bounded FIFO of waiters before CPU-heavy native work.
/// Absolute deadlines remain attached to permits across queue handoff.
actor QPeriaptCryptoAdmissionGate {
    static let shared = QPeriaptCryptoAdmissionGate(validatedDefaults: ())

    private struct Permit {
        let token: UUID
        let deadline: ContinuousClock.Instant?
    }

    private struct Waiter {
        let token: UUID
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Permit, any Error>
        let deadlineTask: Task<Void, Never>
    }

    private let maximumWaiters: Int
    private let maximumWaitDuration: Duration
    private let sleepUntilDeadline: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private let beforeWaiterAppendForTesting: @Sendable () -> Void
    private var ownerToken: UUID?
    private var waiters: [Waiter] = []

    private init(validatedDefaults: Void) {
        _ = validatedDefaults
        maximumWaiters = 8
        maximumWaitDuration = .seconds(30)
        sleepUntilDeadline = { duration in
            try await Task.sleep(for: duration)
        }
        now = { ContinuousClock().now }
        beforeWaiterAppendForTesting = {}
    }

    init(
        maximumWaiters: Int = 8,
        maximumWaitDuration: Duration = .seconds(30),
        sleepUntilDeadline: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        beforeWaiterAppendForTesting: @escaping @Sendable () -> Void = {}
    ) throws {
        guard maximumWaiters >= 0 else {
            throw QPeriaptCryptoAdmissionError.invalidMaximumWaiters(maximumWaiters)
        }
        guard maximumWaitDuration > .zero else {
            throw QPeriaptCryptoAdmissionError.invalidMaximumWaitDuration
        }
        self.maximumWaiters = maximumWaiters
        self.maximumWaitDuration = maximumWaitDuration
        self.sleepUntilDeadline = sleepUntilDeadline
        self.now = now
        self.beforeWaiterAppendForTesting = beforeWaiterAppendForTesting
    }

    var pendingWaiterCount: Int {
        waiters.count
    }

    #if DEBUG || SKYBRIDGE_TESTING
    var hasElapsedPendingWaiterForTesting: Bool {
        let currentInstant = now()
        return waiters.contains { currentInstant >= $0.deadline }
    }
    #endif

    func run<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let permit = try await acquire()
        let operationResult: Swift.Result<Result, any Error>
        do {
            try validate(permit: permit)
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            operationResult = .success(result)
        } catch {
            operationResult = .failure(error)
        }
        try release(token: permit.token)
        return try operationResult.get()
    }

    private func acquire() async throws -> Permit {
        try Task.checkCancellation()
        let token = UUID()
        if ownerToken == nil {
            ownerToken = token
            return Permit(token: token, deadline: nil)
        }
        rejectElapsedWaiters()
        guard waiters.count < maximumWaiters else {
            throw QPeriaptCryptoAdmissionError.waiterLimitExceeded(maximum: maximumWaiters)
        }
        let deadline = now().advanced(by: maximumWaitDuration)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { [maximumWaitDuration, sleepUntilDeadline] in
                    do {
                        try await sleepUntilDeadline(maximumWaitDuration)
                    } catch is CancellationError {
                        return
                    } catch {
                        self.failWaiter(token: token, error: error)
                        return
                    }
                    self.expireWaiter(token: token)
                }
                beforeWaiterAppendForTesting()
                waiters.append(
                    Waiter(
                        token: token,
                        deadline: deadline,
                        continuation: continuation,
                        deadlineTask: deadlineTask
                    )
                )
                // Cancellation may race between the initial check and waiter
                // installation. Close that race after the waiter is visible.
                if Task.isCancelled {
                    cancelWaiter(token: token)
                }
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

    private func failWaiter(token: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: error)
    }

    private func expireWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        guard now() >= waiters[index].deadline else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: QPeriaptCryptoAdmissionError.waitDeadlineExceeded)
    }

    private func validate(permit: Permit) throws {
        guard let deadline = permit.deadline else { return }
        guard now() < deadline else {
            throw QPeriaptCryptoAdmissionError.waitDeadlineExceeded
        }
    }

    private func rejectElapsedWaiters() {
        let currentInstant = now()
        var activeWaiters: [Waiter] = []
        activeWaiters.reserveCapacity(waiters.count)
        for waiter in waiters {
            guard currentInstant >= waiter.deadline else {
                activeWaiters.append(waiter)
                continue
            }
            waiter.deadlineTask.cancel()
            waiter.continuation.resume(
                throwing: QPeriaptCryptoAdmissionError.waitDeadlineExceeded
            )
        }
        waiters = activeWaiters
    }

    private func release(token: UUID) throws {
        guard ownerToken == token else {
            throw QPeriaptCryptoAdmissionError.ownerMismatch
        }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.deadlineTask.cancel()
            guard now() < next.deadline else {
                next.continuation.resume(
                    throwing: QPeriaptCryptoAdmissionError.waitDeadlineExceeded
                )
                continue
            }
            ownerToken = next.token
            next.continuation.resume(
                returning: Permit(token: next.token, deadline: next.deadline)
            )
            return
        }
        ownerToken = nil
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

/// Serial native executor. Cancellation never pretends an in-process FFI call
/// was interrupted; admission ownership ends only when the queue job returns.
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

    fileprivate func generateKeyPair<Secret: QPeriaptSecretBuffer>(
        adapter: QPeriaptNativeAdapter<Secret>
    ) async throws -> (publicKey: Data, privateKey: Secret) {
        try await execute {
            try adapter.generateKeyPairSynchronously()
        }
    }

    fileprivate func encapsulate<Secret: QPeriaptSecretBuffer>(
        adapter: QPeriaptNativeAdapter<Secret>,
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: Secret) {
        try await execute {
            try adapter.encapsulateSynchronously(
                recipientPublicKey: recipientPublicKey,
                applicationContext: applicationContext
            )
        }
    }

    fileprivate func decapsulate<Secret: QPeriaptSecretBuffer>(
        adapter: QPeriaptNativeAdapter<Secret>,
        encapsulatedKey: Data,
        privateKey: Secret,
        applicationContext: Data
    ) async throws -> Secret {
        try await execute {
            try adapter.decapsulateSynchronously(
                encapsulatedKey: encapsulatedKey,
                privateKey: privateKey,
                applicationContext: applicationContext
            )
        }
    }

    private func execute<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
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
    func executeForTesting<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try await execute(operation)
    }
    #endif
}

public struct QPeriaptNativeAdapter<Secret: QPeriaptSecretBuffer>: Sendable {
    public static var publicKeyLength: Int {
        Int(Q_PERIAPT_MLKEM768_PK_LEN) + Int(Q_PERIAPT_X25519_LEN)
    }

    public static var privateKeyLength: Int {
        Int(Q_PERIAPT_MLKEM768_SK_LEN)
            + Int(Q_PERIAPT_X25519_LEN)
            + Int(Q_PERIAPT_MLKEM768_PK_LEN)
            + Int(Q_PERIAPT_X25519_LEN)
    }

    public static var encapsulatedKeyLength: Int {
        Int(Q_PERIAPT_MLKEM768_CT_LEN) + Int(Q_PERIAPT_X25519_LEN)
    }

    public static var sharedSecretLength: Int {
        Int(Q_PERIAPT_SECRET_LEN)
    }

    public static var maximumApplicationContextLength: Int {
        Int(Q_PERIAPT_MAX_APPLICATION_CONTEXT_BYTES)
    }

    private let session: QPeriaptRuntimeSession

    public init(session: QPeriaptRuntimeSession) {
        self.session = session
    }

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Secret) {
        try await QPeriaptCryptoAdmissionGate.shared.run {
            try await QPeriaptCryptoExecutor.shared.generateKeyPair(adapter: self)
        }
    }

    public func encapsulate(
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: Secret) {
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

    public func decapsulate(
        encapsulatedKey: Data,
        privateKey: Secret,
        applicationContext: Data
    ) async throws -> Secret {
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
            throw QPeriaptNativeError.emptyApplicationContext
        }
        guard context.count <= maximumApplicationContextLength else {
            throw QPeriaptNativeError.applicationContextTooLarge(
                actual: context.count,
                maximum: maximumApplicationContextLength
            )
        }
    }

    private static func validateRecipientPublicKeyLength(_ actual: Int) throws {
        guard actual == publicKeyLength else {
            throw QPeriaptNativeError.invalidRecipientPublicKeyLength(
                expected: publicKeyLength,
                actual: actual
            )
        }
    }

    private static func validatePrivateKeyLength(_ actual: Int) throws {
        guard actual == privateKeyLength else {
            throw QPeriaptNativeError.invalidPrivateKeyLength(
                expected: privateKeyLength,
                actual: actual
            )
        }
    }

    private static func validateEncapsulatedKeyLength(_ actual: Int) throws {
        guard actual == encapsulatedKeyLength else {
            throw QPeriaptNativeError.invalidCiphertextLength(
                expected: encapsulatedKeyLength,
                actual: actual
            )
        }
    }

    private static func requireCompatibleRuntime() throws {
        do {
            try QPeriaptRuntimeContract.requireCompatible()
        } catch let error as QPeriaptRuntimeContractError {
            throw QPeriaptNativeError.runtimeContract(error)
        }
    }

    fileprivate func generateKeyPairSynchronously() throws -> (
        publicKey: Data,
        privateKey: Secret
    ) {
        try Self.requireCompatibleRuntime()

        let skPQ = try Secret(count: Int(Q_PERIAPT_MLKEM768_SK_LEN))
        let skTraditional = try Secret(count: Int(Q_PERIAPT_X25519_LEN))
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
            throw QPeriaptNativeError.keyGenerationFailed(
                status: status,
                name: QPeriaptRuntimeContract.statusDescription(status)
            )
        }

        var publicKey = Data(capacity: Self.publicKeyLength)
        publicKey.append(pkPQ)
        publicKey.append(pkTraditional)

        let privateKey = try Secret(count: Self.privateKeyLength)
        do {
            try privateKey.withUnsafeMutableBytes { privateKeyRaw in
            var destinationOffset = 0
            func append(_ source: UnsafeRawBufferPointer) throws {
                guard destinationOffset <= privateKeyRaw.count,
                      source.count <= privateKeyRaw.count - destinationOffset,
                      let sourceAddress = source.baseAddress,
                      let destinationAddress = privateKeyRaw.baseAddress else {
                    throw QPeriaptNativeError.keyBlobAssemblyFailed
                }
                destinationAddress
                    .advanced(by: destinationOffset)
                    .copyMemory(from: sourceAddress, byteCount: source.count)
                destinationOffset += source.count
            }

                try skPQ.withUnsafeBytes(append)
                try skTraditional.withUnsafeBytes(append)
                try pkPQ.withUnsafeBytes(append)
                try pkTraditional.withUnsafeBytes(append)
                guard destinationOffset == privateKeyRaw.count else {
                    throw QPeriaptNativeError.keyBlobAssemblyFailed
                }
            }
        } catch {
            privateKey.zeroize()
            throw error
        }
        guard publicKey.count == Self.publicKeyLength,
              privateKey.byteCount == Self.privateKeyLength else {
            privateKey.zeroize()
            throw QPeriaptNativeError.keyBlobAssemblyFailed
        }
        return (publicKey, privateKey)
    }

    fileprivate func encapsulateSynchronously(
        recipientPublicKey: Data,
        applicationContext: Data
    ) throws -> (encapsulatedKey: Data, sharedSecret: Secret) {
        try Self.requireCompatibleRuntime()
        try Self.validateRecipientPublicKeyLength(recipientPublicKey.count)

        var ctPQ = Data(repeating: 0, count: Int(Q_PERIAPT_MLKEM768_CT_LEN))
        var ctTraditional = Data(repeating: 0, count: Int(Q_PERIAPT_X25519_LEN))
        let sharedSecret = try Secret(count: Self.sharedSecretLength)

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
                                    publicKey.baseAddress?.advanced(
                                        by: Int(Q_PERIAPT_MLKEM768_PK_LEN)
                                    ),
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
            throw QPeriaptNativeError.encapsulationFailed(
                status: status,
                name: QPeriaptRuntimeContract.statusDescription(status)
            )
        }

        var encapsulatedKey = Data(capacity: Self.encapsulatedKeyLength)
        encapsulatedKey.append(ctPQ)
        encapsulatedKey.append(ctTraditional)
        return (encapsulatedKey, sharedSecret)
    }

    fileprivate func decapsulateSynchronously(
        encapsulatedKey: Data,
        privateKey: Secret,
        applicationContext: Data
    ) throws -> Secret {
        try Self.requireCompatibleRuntime()
        try Self.validatePrivateKeyLength(privateKey.byteCount)
        try Self.validateEncapsulatedKeyLength(encapsulatedKey.count)

        let sharedSecret = try Secret(count: Self.sharedSecretLength)
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
                                ciphertext.baseAddress?.advanced(
                                    by: Int(Q_PERIAPT_MLKEM768_CT_LEN)
                                ),
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
            throw QPeriaptNativeError.decapsulationFailed(
                status: status,
                name: QPeriaptRuntimeContract.statusDescription(status)
            )
        }
        return sharedSecret
    }
}
