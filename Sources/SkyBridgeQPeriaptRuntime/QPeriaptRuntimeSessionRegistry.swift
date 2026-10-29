import Foundation
import os

public enum QPeriaptRuntimeSessionRegistryError: Error, LocalizedError, Sendable, Equatable {
    case trustRootReplacementRejected
    case policyRollbackRejected(installed: UInt32, proposed: UInt32)
    case policyVersionDigestConflict(version: UInt32)

    public var errorDescription: String? {
        switch self {
        case .trustRootReplacementRejected:
            return "Q-Periapt trust root replacement requires an explicit reset/re-enrollment flow"
        case .policyRollbackRejected:
            return "Q-Periapt runtime session rollback was rejected"
        case .policyVersionDigestConflict:
            return "Q-Periapt runtime session reused a policy version with a different digest"
        }
    }
}

/// Process-wide admission registry for immutable authenticated sessions.
///
/// The registry permits idempotent reinstall and monotonic upgrades under one
/// trust root. Trust-root replacement has no production reset path; product code
/// must perform an explicit re-enrollment flow in a fresh registry lifecycle.
public final class QPeriaptRuntimeSessionRegistry: Sendable {
    private let installedSession = OSAllocatedUnfairLock<QPeriaptRuntimeSession?>(
        initialState: nil
    )

    public init() {}

    public func snapshot() -> QPeriaptRuntimeSession? {
        installedSession.withLock { $0 }
    }

    public func install(_ session: QPeriaptRuntimeSession) throws {
        try installedSession.withLock { currentSession in
            if let currentSession,
               currentSession.trustRootFingerprint != session.trustRootFingerprint
                || currentSession.trustRootIdentifierSHA256 != session.trustRootIdentifierSHA256 {
                throw QPeriaptRuntimeSessionRegistryError.trustRootReplacementRejected
            }
            if let currentSession {
                guard session.policyVersion >= currentSession.policyVersion else {
                    throw QPeriaptRuntimeSessionRegistryError.policyRollbackRejected(
                        installed: currentSession.policyVersion,
                        proposed: session.policyVersion
                    )
                }
                guard session.policyVersion != currentSession.policyVersion
                        || session.policyDigest == currentSession.policyDigest else {
                    throw QPeriaptRuntimeSessionRegistryError.policyVersionDigestConflict(
                        version: session.policyVersion
                    )
                }
            }
            currentSession = session
        }
    }

    #if DEBUG || SKYBRIDGE_TESTING
    public func resetForTesting() {
        installedSession.withLock { $0 = nil }
    }
    #endif
}
