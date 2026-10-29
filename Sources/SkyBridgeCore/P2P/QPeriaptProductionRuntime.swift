import CryptoKit
import Foundation
import SkyBridgeQPeriaptRuntime

/// Outcome of one production provisioning attempt.
public enum QPeriaptProductionPreparationResult: Sendable, Equatable {
    /// The registry ships no production trust root; suite 0x0012 stays dark.
    case unprovisioned
    /// A verified session was already installed earlier in this process.
    case alreadyActive
    /// Signed-policy verification, durable CAS, the native round-trip probe,
    /// and immutable registry installation all succeeded just now.
    case activated
}

public enum QPeriaptProductionRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case ambiguousProductionRoots(count: Int)
    case unsupportedOS
    case trustRootIdentifierMismatch
    case rootFingerprintMismatch

    public var errorDescription: String? {
        switch self {
        case .ambiguousProductionRoots(let count):
            return "Q-Periapt production registry has \(count) active roots; exactly one is required"
        case .unsupportedOS:
            return "Q-Periapt ABI2 requires macOS 26 or newer"
        case .trustRootIdentifierMismatch:
            return "Q-Periapt trusted-state store received a different registry identifier"
        case .rootFingerprintMismatch:
            return "Q-Periapt session fingerprint does not match the pinned production root"
        }
    }
}

/// One code-reviewed production root entry. The policy bytes and detached
/// signature are compiled-in generated material, but the ML-DSA-65
/// verification-key fingerprint must stay independently pinned in
/// `QPeriaptProductionTrustRootMaterial`. No development or test root may
/// enter the production registry.
struct QPeriaptProductionTrustRootEntry: Sendable {
    let material: QPeriaptSignedPolicyMaterial
    let enrollmentMode: QPeriaptEnrollmentMode
}

enum QPeriaptProductionTrustRootRegistry {
    /// The single production entry, built from the ceremony-generated shared
    /// material (`QPeriaptProductionTrustRootMaterial`). Fresh installs are
    /// explicitly authorized first enrollments: the material and its pin ship
    /// inside the signed app, which is the enrollment authorization boundary,
    /// and the monotonic Keychain CAS prevents any later rollback.
    static let entries: [QPeriaptProductionTrustRootEntry] = [
        QPeriaptProductionTrustRootEntry(
            material: QPeriaptProductionTrustRootMaterial.makeSignedPolicyMaterial(),
            enrollmentMode: .explicitlyAuthorizedFirstEnrollment
        )
    ]
}

/// macOS product admission for the shared Q-Periapt runtime.
///
/// A session becomes observable only after signed-policy verification, durable
/// Keychain CAS, the native ABI round trip, and immutable registry
/// installation — the exact chain the iOS runtime performs.
@available(macOS 14.0, *)
public enum QPeriaptProductionRuntime {
    public static func prepareProductionSession() async throws
        -> QPeriaptProductionPreparationResult
    {
        guard !QPeriaptPlatformPolicy.isLocalRuntimeSupported else { return .alreadyActive }
        let entries = QPeriaptProductionTrustRootRegistry.entries
        guard !entries.isEmpty else { return .unprovisioned }
        guard entries.count == 1, let entry = entries.first else {
            throw QPeriaptProductionRuntimeError.ambiguousProductionRoots(count: entries.count)
        }
        try await activate(entry)
        return .activated
    }

    private static func activate(_ entry: QPeriaptProductionTrustRootEntry) async throws {
        guard #available(macOS 26.0, *) else {
            throw QPeriaptProductionRuntimeError.unsupportedOS
        }
        let fingerprint = entry.material.verificationKeySHA256Pin
        let trustedStateStore = MacQPeriaptTrustedStateStore(
            rootFingerprint: fingerprint,
            expectedTrustRootIdentifier: entry.material.trustRootIdentifier
        )
        let session = try await QPeriaptPolicyRuntime().resolveSession(
            material: entry.material,
            enrollmentMode: entry.enrollmentMode,
            trustedStateStore: trustedStateStore
        )
        guard session.trustRootFingerprint == fingerprint else {
            throw QPeriaptProductionRuntimeError.rootFingerprintMismatch
        }
        try Task.checkCancellation()
        // Runs the native ABI2 round-trip probe and installs into the
        // process-wide admission registry (idempotent for the same session).
        try await QPeriaptPlatformPolicy.activateRuntimeSession(session)
    }

    #if DEBUG || SKYBRIDGE_TESTING
    /// Test bridge mirroring `QPeriaptIOSRuntime.activateForTesting`: fixture
    /// material exercises the full production activation chain without
    /// compiling a test root into the production registry.
    static func activateForTesting(
        material: QPeriaptSignedPolicyMaterial,
        enrollmentMode: QPeriaptEnrollmentMode
    ) async throws {
        try await activate(
            QPeriaptProductionTrustRootEntry(
                material: material,
                enrollmentMode: enrollmentMode
            )
        )
    }
    #endif
}

/// Durable trusted-state boundary bridging the shared policy runtime to the
/// macOS Keychain append-only CAS chain.
@available(macOS 14.0, *)
private struct MacQPeriaptTrustedStateStore: QPeriaptTrustedStateStore {
    let rootFingerprint: Data
    let expectedTrustRootIdentifier: String

    func loadTrustedState(trustRootIdentifier: String) async throws -> Data? {
        guard trustRootIdentifier == expectedTrustRootIdentifier else {
            throw QPeriaptProductionRuntimeError.trustRootIdentifierMismatch
        }
        return try KeychainManager.shared.loadQPeriaptTrustedState(
            rootFingerprint: rootFingerprint
        )
    }

    func compareAndSwapTrustedState(
        expectedPreviousState: Data?,
        newState: Data,
        trustRootIdentifier: String
    ) async throws -> Bool {
        guard trustRootIdentifier == expectedTrustRootIdentifier else {
            throw QPeriaptProductionRuntimeError.trustRootIdentifierMismatch
        }
        return try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
            expectedPreviousState: expectedPreviousState,
            newState: newState,
            rootFingerprint: rootFingerprint
        )
    }
}
