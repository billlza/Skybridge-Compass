import Foundation

@available(macOS 14.0, iOS 17.0, *)
actor ProtocolIdentityBindingTransactionStore {
    static let shared = ProtocolIdentityBindingTransactionStore()

    struct Context: Sendable {
        let request: AppMessage.ProtocolIdentityBindingRequestPayload
        let candidate: AppMessage.SignedProtocolIdentityBindingPayload
        /// Exact key handle used to sign `candidate`. Production finalization
        /// must reuse it so a concurrent local key rotation cannot produce an
        /// ACK that the requester will reject after the responder has pinned.
        let responderKeyHandle: SigningKeyHandle?
    }

    enum TransactionError: Error, LocalizedError, Sendable, Equatable {
        case capacityReached
        case requesterQuotaReached
        case requesterRateLimited
        case invalidRequesterIdentity
        case conflictingTransaction
        case transactionMissingOrExpired
        case conflictingConfirmation

        var errorDescription: String? {
            switch self {
            case .capacityReached: return "PIB-1 transaction capacity reached"
            case .requesterQuotaReached: return "PIB-1 requester active transaction quota reached"
            case .requesterRateLimited: return "PIB-1 requester admission rate limit reached"
            case .invalidRequesterIdentity: return "PIB-1 requester identity is invalid for admission"
            case .conflictingTransaction: return "PIB-1 transaction id was reused with different request material"
            case .transactionMissingOrExpired: return "PIB-1 transaction is missing or expired"
            case .conflictingConfirmation: return "PIB-1 transaction received a conflicting confirmation"
            }
        }
    }

    private struct Entry {
        let context: Context
        let requesterFingerprint: String
        let expiresAt: Date
        var confirmationHashHex: String?
        var finalizationTask: Task<AppMessage.SignedProtocolIdentityBindingFinalAckPayload, Error>?
        var finalAck: AppMessage.SignedProtocolIdentityBindingFinalAckPayload?
    }

    private struct Admission: Sendable {
        let requesterFingerprint: String
        let admittedAt: Date
    }

    private static let maximumTransactions = 32
    private static let maximumTransactionsPerRequester = 4
    private static let admissionWindow: TimeInterval = 10
    private static let maximumAdmissionsPerRequesterPerWindow = 8
    private static let maximumGlobalAdmissionsPerWindow = 64
    private static let maximumTTL: TimeInterval = 300
    private var entries: [UUID: Entry] = [:]
    private var recentAdmissions: [Admission] = []

    func register(
        request: AppMessage.ProtocolIdentityBindingRequestPayload,
        candidate: AppMessage.SignedProtocolIdentityBindingPayload,
        responderKeyHandle: SigningKeyHandle? = nil,
        now: Date = Date()
    ) throws -> AppMessage.SignedProtocolIdentityBindingPayload {
        purgeExpired(now: now)
        purgeAdmissions(now: now)
        guard request.version == AppMessage.ProtocolIdentityBindingRequestPayload.currentVersion,
              candidate.version == AppMessage.SignedProtocolIdentityBindingPayload.currentVersion,
              request.transactionId == candidate.transactionId,
              candidate.expiresAt > now,
              candidate.expiresAt.timeIntervalSince(now) <= Self.maximumTTL else {
            throw TransactionError.conflictingTransaction
        }
        if let existing = entries[request.transactionId] {
            guard existing.context.request.canonicalRequestHashHex == request.canonicalRequestHashHex else {
                throw TransactionError.conflictingTransaction
            }
            return existing.context.candidate
        }
        guard let requesterIdentity = request.normalizedRequesterProtocolIdentity,
              let requesterFingerprint = requesterIdentity.authoritativeFingerprint?.lowercased() else {
            throw TransactionError.invalidRequesterIdentity
        }
        let activeRequesterTransactions = entries.values.reduce(into: 0) { count, entry in
            if entry.requesterFingerprint == requesterFingerprint {
                count += 1
            }
        }
        guard activeRequesterTransactions < Self.maximumTransactionsPerRequester else {
            throw TransactionError.requesterQuotaReached
        }
        let recentRequesterAdmissions = recentAdmissions.reduce(into: 0) { count, admission in
            if admission.requesterFingerprint == requesterFingerprint {
                count += 1
            }
        }
        guard recentRequesterAdmissions < Self.maximumAdmissionsPerRequesterPerWindow else {
            throw TransactionError.requesterRateLimited
        }
        guard recentAdmissions.count < Self.maximumGlobalAdmissionsPerWindow else {
            throw TransactionError.capacityReached
        }
        guard entries.count < Self.maximumTransactions else {
            throw TransactionError.capacityReached
        }
        entries[request.transactionId] = Entry(
            context: Context(
                request: request,
                candidate: candidate,
                responderKeyHandle: responderKeyHandle
            ),
            requesterFingerprint: requesterFingerprint,
            expiresAt: min(candidate.expiresAt, now.addingTimeInterval(Self.maximumTTL)),
            confirmationHashHex: nil,
            finalizationTask: nil,
            finalAck: nil
        )
        recentAdmissions.append(
            Admission(
                requesterFingerprint: requesterFingerprint,
                admittedAt: now
            )
        )
        return candidate
    }

    func resolveConfirmation(
        _ confirm: AppMessage.ProtocolIdentityBindingConfirmPayload,
        now: Date = Date(),
        finalize: @escaping @Sendable (Context) async throws -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload
    ) async throws -> AppMessage.SignedProtocolIdentityBindingFinalAckPayload {
        purgeExpired(now: now)
        guard var entry = entries[confirm.transactionId], entry.expiresAt > now else {
            throw TransactionError.transactionMissingOrExpired
        }
        _ = try confirm.validatedForCandidate(
            request: entry.context.request,
            candidate: entry.context.candidate,
            now: now
        )
        let confirmationHash = confirm.canonicalConfirmHashHex
        if let existingHash = entry.confirmationHashHex, existingHash != confirmationHash {
            throw TransactionError.conflictingConfirmation
        }
        if let finalAck = entry.finalAck {
            return finalAck
        }
        if let task = entry.finalizationTask {
            return try await task.value
        }

        let context = entry.context
        let task = Task {
            try await finalize(context)
        }
        entry.confirmationHashHex = confirmationHash
        entry.finalizationTask = task
        entries[confirm.transactionId] = entry

        do {
            let ack = try await task.value
            guard var current = entries[confirm.transactionId],
                  current.confirmationHashHex == confirmationHash else {
                throw TransactionError.conflictingConfirmation
            }
            current.finalizationTask = nil
            current.finalAck = ack
            entries[confirm.transactionId] = current
            return ack
        } catch {
            entries.removeValue(forKey: confirm.transactionId)
            throw error
        }
    }

#if DEBUG || SKYBRIDGE_TESTING
    func clearForTesting() {
        for entry in entries.values {
            entry.finalizationTask?.cancel()
        }
        entries.removeAll()
        recentAdmissions.removeAll()
    }

    func countForTesting(now: Date = Date()) -> Int {
        purgeExpired(now: now)
        return entries.count
    }
#endif

    private func purgeExpired(now: Date) {
        let expired = entries.filter {
            $0.value.expiresAt <= now && $0.value.finalizationTask == nil
        }.map(\.key)
        for transactionId in expired {
            entries.removeValue(forKey: transactionId)
        }
    }

    private func purgeAdmissions(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.admissionWindow)
        recentAdmissions.removeAll { $0.admittedAt <= cutoff }
    }
}
