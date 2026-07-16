import CryptoKit
import Foundation

#if canImport(CQPeriapt)
import CQPeriapt

/// Product policy bytes and their detached ML-DSA-65 authentication material.
///
/// This value deliberately contains no default/test fixture. Production callers
/// must provision exact policy bytes, signature, verification key, and an
/// independently pinned SHA-256 digest of that verification key.
public struct QPeriaptSignedPolicyMaterial: Sendable {
    public let policyTOML: Data
    public let detachedSignature: Data
    public let verificationKey: Data
    public let verificationKeySHA256Pin: Data
    public let trustRootIdentifier: String

    public init(
        policyTOML: Data,
        detachedSignature: Data,
        verificationKey: Data,
        verificationKeySHA256Pin: Data,
        trustRootIdentifier: String
    ) {
        self.policyTOML = policyTOML
        self.detachedSignature = detachedSignature
        self.verificationKey = verificationKey
        self.verificationKeySHA256Pin = verificationKeySHA256Pin
        self.trustRootIdentifier = trustRootIdentifier
    }
}

public enum QPeriaptEnrollmentMode: Sendable {
    /// An already enrolled installation. Missing state is a security failure.
    case existingEnrollment
    /// A user/administrator-authorized first enrollment. Only this mode may
    /// resolve a policy with no prior trusted state.
    case explicitlyAuthorizedFirstEnrollment
}

/// Durable state boundary for ABI2's monotonic policy state.
///
/// Implementations must store the 36-byte value atomically in a device-bound,
/// non-synchronizing namespace associated with `trustRootIdentifier`.
public protocol QPeriaptTrustedStateStore: Sendable {
    func loadTrustedState(trustRootIdentifier: String) async throws -> Data?

    /// Atomically replaces the trusted state only when the currently persisted
    /// value still equals `expectedPreviousState` (`nil` means no record).
    /// Implementations shared by apps/extensions must provide cross-process CAS.
    /// Calling this method crosses the policy commit point: cancellation must not
    /// turn a known committed result into an error. Returning `true` means the new
    /// state is durably committed, returning `false` means it was not committed,
    /// and throwing must also mean no state was committed.
    func compareAndSwapTrustedState(
        expectedPreviousState: Data?,
        newState: Data,
        trustRootIdentifier: String
    ) async throws -> Bool
}

public enum QPeriaptPolicyRuntimeError: Error, LocalizedError, Sendable {
    case emptyPolicy
    case policyTooLarge(actual: Int, maximum: Int)
    case invalidSignatureLength(actual: Int, expected: Int)
    case invalidVerificationKeyLength(actual: Int, expected: Int)
    case invalidVerificationKeyPinLength(actual: Int, expected: Int)
    case verificationKeyPinMismatch
    case invalidTrustRootIdentifier
    case missingTrustedState
    case invalidTrustedStateLength(actual: Int, expected: Int)
    case trustedStateChangedConcurrently
    case nativePolicyRejected(status: Int32, name: String)
    case invalidNativeDecision

    public var errorDescription: String? {
        switch self {
        case .emptyPolicy:
            return "Q-Periapt policy is empty"
        case .policyTooLarge(let actual, let maximum):
            return "Q-Periapt policy is too large: \(actual) > \(maximum)"
        case .invalidSignatureLength(let actual, let expected):
            return "Invalid ML-DSA-65 policy signature length: expected \(expected), got \(actual)"
        case .invalidVerificationKeyLength(let actual, let expected):
            return "Invalid ML-DSA-65 policy verification key length: expected \(expected), got \(actual)"
        case .invalidVerificationKeyPinLength(let actual, let expected):
            return "Invalid Q-Periapt verification-key pin length: expected \(expected), got \(actual)"
        case .verificationKeyPinMismatch:
            return "Q-Periapt verification key does not match its independently pinned SHA-256 digest"
        case .invalidTrustRootIdentifier:
            return "Q-Periapt trust-root identifier is empty or malformed"
        case .missingTrustedState:
            return "Q-Periapt trusted policy state is missing for an existing enrollment"
        case .invalidTrustedStateLength(let actual, let expected):
            return "Invalid Q-Periapt trusted-state length: expected \(expected), got \(actual)"
        case .trustedStateChangedConcurrently:
            return "Q-Periapt trusted policy state changed during verification"
        case .nativePolicyRejected(let status, let name):
            return "Q-Periapt signed policy was rejected: \(name) (\(status))"
        case .invalidNativeDecision:
            return "Q-Periapt returned a malformed authenticated policy decision"
        }
    }
}

/// Immutable authenticated decision. Construction is restricted to the native
/// policy verifier so callers cannot assemble a decision from untrusted fields.
struct QPeriaptPolicyDecision: Sendable, Equatable {
    let encoded: Data
    let policyVersion: UInt32
    let policyDigest: Data

    var trustedState: Data {
        encoded.subdata(in: 4..<Self.encodedLength)
    }

    var authProfile: String {
        let digest = policyDigest.map { String(format: "%02x", $0) }.joined()
        return "q-periapt-abi2-policy-v1/\(policyVersion)/\(digest)"
    }

    static let encodedLength = Int(Q_PERIAPT_POLICY_DECISION_LEN)

    init(validating encoded: Data) throws {
        guard encoded.count == Self.encodedLength,
              encoded[0] == UInt8(Q_PERIAPT_POLICY_DECISION_VERSION),
              encoded[1] == UInt8(Q_PERIAPT_SUITE_MLKEM768_X25519),
              encoded[2] == UInt8(Q_PERIAPT_PROFILE_CONTEXT_BOUND),
              encoded[3] == UInt8(Q_PERIAPT_KEY_FORMAT_EXPANDED)
        else {
            throw QPeriaptPolicyRuntimeError.invalidNativeDecision
        }

        let version = encoded[4..<8].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard version != 0 else {
            throw QPeriaptPolicyRuntimeError.invalidNativeDecision
        }

        self.encoded = encoded
        self.policyVersion = version
        self.policyDigest = encoded.subdata(in: 8..<Self.encodedLength)
    }
}

public struct QPeriaptRuntimeSession: Sendable, Equatable {
    public let policyVersion: UInt32
    public let policyDigest: Data
    public let authProfile: String
    public let trustRootIdentifier: String
    let decision: QPeriaptPolicyDecision

    fileprivate init(decision: QPeriaptPolicyDecision, trustRootIdentifier: String) {
        self.policyVersion = decision.policyVersion
        self.policyDigest = decision.policyDigest
        self.authProfile = decision.authProfile
        self.trustRootIdentifier = trustRootIdentifier
        self.decision = decision
    }
}

/// Actor-isolated orchestration for ABI2 policy verification and monotonic state.
/// State is persisted before the authenticated decision becomes observable.
/// Cross-process atomicity comes from the store CAS, not actor isolation.
public actor QPeriaptPolicyRuntime {
    private let afterDecisionBeforeCommit: (@Sendable () async -> Void)?

    public init() {
        afterDecisionBeforeCommit = nil
    }

    init(afterDecisionBeforeCommitForTesting: @escaping @Sendable () async -> Void) {
        afterDecisionBeforeCommit = afterDecisionBeforeCommitForTesting
    }

    public func resolveSession(
        material: QPeriaptSignedPolicyMaterial,
        enrollmentMode: QPeriaptEnrollmentMode,
        trustedStateStore: any QPeriaptTrustedStateStore
    ) async throws -> QPeriaptRuntimeSession {
        try Self.validate(material)

        let loadedState = try await trustedStateStore.loadTrustedState(
            trustRootIdentifier: material.trustRootIdentifier
        )
        let previousState: Data
        switch (enrollmentMode, loadedState) {
        case (.existingEnrollment, nil):
            throw QPeriaptPolicyRuntimeError.missingTrustedState
        case (.explicitlyAuthorizedFirstEnrollment, nil):
            previousState = Data()
        case (_, .some(let state)):
            guard state.count == Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN) else {
                throw QPeriaptPolicyRuntimeError.invalidTrustedStateLength(
                    actual: state.count,
                    expected: Int(Q_PERIAPT_TRUSTED_POLICY_STATE_LEN)
                )
            }
            previousState = state
        }

        let policyPreviousState = previousState
        let decision = try await QPeriaptCryptoAdmissionGate.shared.run {
            try await QPeriaptCryptoExecutor.shared.resolveDecision(
                policyTOML: material.policyTOML,
                signature: material.detachedSignature,
                verificationKey: material.verificationKey,
                previousTrustedState: policyPreviousState
            )
        }
        if let afterDecisionBeforeCommit {
            await afterDecisionBeforeCommit()
        }
        try Task.checkCancellation()

        // This call is the non-cancellable commit point. A definitive successful
        // CAS remains success even if cancellation arrives while the store is
        // committing; reporting cancellation after a known commit would hide a
        // monotonic-state transition from the caller.
        let committed = try await trustedStateStore.compareAndSwapTrustedState(
            expectedPreviousState: loadedState,
            newState: decision.trustedState,
            trustRootIdentifier: material.trustRootIdentifier
        )
        guard committed else {
            throw QPeriaptPolicyRuntimeError.trustedStateChangedConcurrently
        }
        return QPeriaptRuntimeSession(
            decision: decision,
            trustRootIdentifier: material.trustRootIdentifier
        )
    }

    private static func validate(_ material: QPeriaptSignedPolicyMaterial) throws {
        guard !material.policyTOML.isEmpty else {
            throw QPeriaptPolicyRuntimeError.emptyPolicy
        }
        let maximumPolicyLength = Int(Q_PERIAPT_MAX_SIGNED_POLICY_BYTES)
        guard material.policyTOML.count <= maximumPolicyLength else {
            throw QPeriaptPolicyRuntimeError.policyTooLarge(
                actual: material.policyTOML.count,
                maximum: maximumPolicyLength
            )
        }

        // FIPS 204 ML-DSA-65 fixed sizes. The Q-Periapt C ABI intentionally
        // accepts pointer/length pairs, so the host validates these boundaries.
        let signatureLength = 3_309
        let verificationKeyLength = 1_952
        guard material.detachedSignature.count == signatureLength else {
            throw QPeriaptPolicyRuntimeError.invalidSignatureLength(
                actual: material.detachedSignature.count,
                expected: signatureLength
            )
        }
        guard material.verificationKey.count == verificationKeyLength else {
            throw QPeriaptPolicyRuntimeError.invalidVerificationKeyLength(
                actual: material.verificationKey.count,
                expected: verificationKeyLength
            )
        }
        guard material.verificationKeySHA256Pin.count == SHA256.byteCount else {
            throw QPeriaptPolicyRuntimeError.invalidVerificationKeyPinLength(
                actual: material.verificationKeySHA256Pin.count,
                expected: SHA256.byteCount
            )
        }
        let actualPin = Data(SHA256.hash(data: material.verificationKey))
        guard actualPin == material.verificationKeySHA256Pin else {
            throw QPeriaptPolicyRuntimeError.verificationKeyPinMismatch
        }

        let identifier = material.trustRootIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier == material.trustRootIdentifier,
              !identifier.isEmpty,
              identifier.count <= 128,
              identifier.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || "-._/".unicodeScalars.contains(scalar)
              })
        else {
            throw QPeriaptPolicyRuntimeError.invalidTrustRootIdentifier
        }
    }
}
#endif
