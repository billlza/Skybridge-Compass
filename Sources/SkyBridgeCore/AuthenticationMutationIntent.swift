import Foundation
import os
import SkyBridgeProtocolCore

/// Checked on the existing Keychain executor immediately before a synchronous
/// mutation. Newer UI intent invalidates queued work; an already admitted write
/// finishes before the same executor processes the replacement. Publication is
/// separately checked by AuthenticationService after suspension.
final class AuthenticationMutationIntent: Sendable {
    private let active = OSAllocatedUnfairLock(initialState: true)

    func invalidate() { active.withLock { $0 = false } }

    func requireCurrent() throws {
        guard active.withLock({ $0 }) else { throw ProtectedAccountSessionError.changed }
    }
}

#if DEBUG || SKYBRIDGE_TESTING
/// Selected only by the repository's pre-existing in-memory Keychain test mode.
/// Native acceptance uses DataProtectionAccountSessionStorage in signed processes.
final class InMemoryProtectedAccountSessionStorage: ProtectedAccountSessionStorage, Sendable {
    private let value = OSAllocatedUnfairLock<ProtectedAccountSessionValue?>(initialState: nil)

    func load() throws -> ProtectedAccountSessionValue? { value.withLock { $0 } }

    func insert(_ replacement: ProtectedAccountSessionValue) throws -> Bool {
        value.withLock { value in
            guard value == nil else { return false }
            value = replacement; return true
        }
    }

    func replace(expectedRevision: UUID, with replacement: ProtectedAccountSessionValue) throws -> Bool {
        value.withLock { value in
            guard value?.revision == expectedRevision else { return false }
            value = replacement; return true
        }
    }
}
#endif
