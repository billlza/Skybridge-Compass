import Foundation
import SkyBridgeProtocolCore

/// Waits for the existing live mutation owner, then performs the original strict read.
/// It never recovers abandoned journals, sends identity messages, or authorizes a file.
@MainActor
enum ClassicFileApprovalJournalReadiness {
    enum PersistenceState { case ready, journalBusy, unavailable }
    enum Outcome: String { case ready, timedOut = "timed_out", cancelled, bindingChanged = "binding_changed", unavailable, failed }

    // The approval header budget is 90 s and native decision budget is 60 s.
    // At most 3 s is spent here, preserving the existing preparation/transport margin.
    static let waitBudget: Duration = .seconds(3)

    /// One file retains its original authority and a cumulative wait budget. Neither
    /// another preparation boundary nor a later user decision replenishes that budget.
    @MainActor
    final class Authority {
        let context: RemoteFileApprovalContext
        private(set) var remainingJournalWait: Duration

        init(context: RemoteFileApprovalContext, initialPreparation: Duration) {
            self.context = context
            remainingJournalWait = max(.zero, min(waitBudget, waitBudget - initialPreparation))
        }

        func revalidate(
            validateCurrent: @escaping @MainActor () throws -> Void,
            persistenceState: @escaping @MainActor () -> PersistenceState
        ) async throws {
            let clock = ContinuousClock()
            let started = clock.now
            defer {
                remainingJournalWait = max(.zero, remainingJournalWait - started.duration(to: clock.now))
            }
            try await ClassicFileApprovalJournalReadiness.read(
                timeout: remainingJournalWait,
                validateCurrent: validateCurrent,
                persistenceState: persistenceState
            ) { try self.context.revalidate() }
            try validateCurrent()
            try context.revalidate()
        }
    }

    /// Holds only operation lifetimes, never a second authority store. The original
    /// context authorizes registration; durable trust changes can only revoke it.
    @MainActor
    final class PublicationOwners {
        @MainActor
        final class Owner {
            let transferID: String
            let handle: InboundFileTransferIOHandle
            private let store: TrustedDeviceStore
            private let observation: UUID

            fileprivate init(context: RemoteFileApprovalContext, handle: InboundFileTransferIOHandle,
                             store: TrustedDeviceStore) throws {
                try context.revalidate()
                transferID = context.binding.transferID
                self.handle = handle
                self.store = store
                observation = try store.observeCurrentPathAuthorityInvalidation(
                    fingerprint: context.binding.senderFingerprint,
                    matchingDeviceId: context.binding.senderDeviceID,
                    invalidate: { handle.revokePublication() }
                )
            }

            fileprivate func retire() {
                handle.revokePublication()
                store.removeAuthorityInvalidationObserver(observation)
            }
        }

        private var owners: [String: Owner] = [:]

        func register(context: RemoteFileApprovalContext, handle: InboundFileTransferIOHandle,
                      store: TrustedDeviceStore) throws -> Owner {
            let owner = try Owner(context: context, handle: handle, store: store)
            owners.updateValue(owner, forKey: owner.transferID)?.retire()
            return owner
        }

        func finish(_ owner: Owner) {
            // Old completion/cleanup must never retire a replacement's handle.
            if owners[owner.transferID] === owner { owners.removeValue(forKey: owner.transferID) }
            owner.retire()
        }

        func cancel(transferID: String) {
            owners.removeValue(forKey: transferID)?.retire()
        }
    }

    static func persistenceState(
        hasPersistenceError: Bool,
        acceptanceJournalPresent: Bool,
        authorityStoreAvailable: Bool
    ) -> PersistenceState {
        if hasPersistenceError { return .unavailable }
        if acceptanceJournalPresent { return .journalBusy }
        return authorityStoreAvailable ? .ready : .unavailable
    }

    static func read<Value>(
        timeout: Duration = waitBudget,
        validateCurrent: @escaping @MainActor () throws -> Void,
        persistenceState: @escaping @MainActor () -> PersistenceState,
        recordWait: @MainActor (Outcome, Duration) -> Void = recordWaitOutcome,
        _ strictRead: () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        try validateCurrent()
        let initialState = persistenceState()
        guard initialState != .unavailable else { throw RemoteFileApprovalError.unavailable }
        if initialState == .ready { return try strictRead() }

        let clock = ContinuousClock()
        let started = clock.now
        var outcome = Outcome.failed
        defer { recordWait(outcome, started.duration(to: clock.now)) }
        do {
            let value = try await PairingIdentityAuthorityMutationBarrier.readAfterActiveMutation(
                timeout: timeout,
                validateCurrent: {
                    try validateCurrent()
                    guard persistenceState() != .unavailable else {
                        throw RemoteFileApprovalError.unavailable
                    }
                }
            ) {
                // A released permit does not prove durable recovery. An orphan journal,
                // a known write error, or an unavailable store still rejects this read.
                guard persistenceState() == .ready else { throw RemoteFileApprovalError.unavailable }
                return try strictRead()
            }
            try Task.checkCancellation()
            try validateCurrent()
            guard persistenceState() == .ready else { throw RemoteFileApprovalError.unavailable }
            outcome = .ready
            return value
        } catch is CancellationError {
            outcome = .cancelled
            throw CancellationError()
        } catch AuthorityBoundPairingIdentityPersistenceError.transactionInProgress {
            outcome = .timedOut
            throw RemoteFileApprovalError.unavailable
        } catch let error as RemoteFileApprovalError {
            outcome = error == .bindingChanged ? .bindingChanged : .unavailable
            throw error
        } catch {
            outcome = .failed
            throw error
        }
    }

    private static func recordWaitOutcome(_ outcome: Outcome, elapsed: Duration) {
        let parts = elapsed.components
        let milliseconds = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        let line = "file-transfer approval-journal-wait outcome=\(outcome.rawValue) elapsed_ms=\(milliseconds)"
        SignedKEMRefreshSmokeStatusWriter.append(line)
        SkyBridgeLogger.shared.info(line)
    }
}
