import CryptoKit
import Foundation
import SkyBridgeQPeriaptRuntime

enum QPeriaptIOSRuntimePreparationResult: Sendable, Equatable {
    case unprovisioned
    case activated
}

enum QPeriaptIOSRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case ambiguousProductionRoots(count: Int)
    case unsupportedOS
    case trustRootIdentifierMismatch
    case invalidRootFingerprintLength(actual: Int)
    case runtimeProbeFailed

    var errorDescription: String? {
        switch self {
        case .ambiguousProductionRoots(let count):
            return "Q-Periapt production registry has \(count) active roots; exactly one is required"
        case .unsupportedOS:
            return "Q-Periapt ABI2 requires iOS 26 or newer"
        case .trustRootIdentifierMismatch:
            return "Q-Periapt trusted-state store received a different registry identifier"
        case .invalidRootFingerprintLength(let actual):
            return "Q-Periapt root-key fingerprint must be 32 bytes, got \(actual)"
        case .runtimeProbeFailed:
            return "Q-Periapt ABI2 native runtime round-trip probe failed"
        }
    }
}

/// One code-reviewed production root entry. The policy bytes and detached
/// signature may be bundled data, but the ML-DSA-65 verification-key fingerprint
/// must be independently pinned here. No development/test root is compiled into
/// the production registry.
struct QPeriaptProductionTrustRootEntry: Sendable {
    let material: QPeriaptSignedPolicyMaterial
    let enrollmentMode: QPeriaptEnrollmentMode
}

enum QPeriaptProductionTrustRootRegistry {
    /// Intentionally empty until real production policy material and its
    /// independently reviewed root-key pin are provisioned. An empty registry
    /// is a normal fail-closed state and can never advertise suite 0x0012.
    static let entries: [QPeriaptProductionTrustRootEntry] = []
}

/// Immutable admission identity captured when a handshake driver is created.
/// Runtime settings and the process registry are intentionally not consulted
/// again after this value has been constructed.
@available(iOS 17.0, *)
enum QPeriaptHandshakeAdmissionSnapshot: Sendable, Equatable {
    case unavailable
    case admitted(
        authProfile: String,
        trustRootFingerprint: Data,
        protocolIdentityConfiguration: ProtocolIdentityConfigurationRecord
    )

    static func freeze(
        provider: any CryptoProvider,
        protocolIdentityConfiguration: ProtocolIdentityConfigurationRecord
    ) -> Self {
        guard protocolIdentityConfiguration.algorithm == .mlDSA65,
              let provider = provider as? any QPeriaptHandshakeBoundCryptoProvider,
              provider.qPeriaptProtocolIdentityConfiguration == protocolIdentityConfiguration,
              !provider.qPeriaptAuthProfile.isEmpty,
              provider.qPeriaptTrustRootFingerprint.count == SHA256.byteCount else {
            return .unavailable
        }
        return .admitted(
            authProfile: provider.qPeriaptAuthProfile,
            trustRootFingerprint: provider.qPeriaptTrustRootFingerprint,
            protocolIdentityConfiguration: protocolIdentityConfiguration
        )
    }

    static func capture(
        provider: any CryptoProvider,
        protocolIdentityConfiguration: ProtocolIdentityConfigurationRecord,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Self {
        guard let provider = provider as? any QPeriaptRuntimeBoundCryptoProvider else {
            return .unavailable
        }
        let authProfile = provider.qPeriaptAuthProfile
        let trustRootFingerprint = provider.qPeriaptTrustRootFingerprint
        guard protocolIdentityConfiguration.algorithm == .mlDSA65,
              (try? ProtocolSigningIdentityPolicy.requiredConfiguration(defaults: userDefaults))
                == protocolIdentityConfiguration,
              QPeriaptIOSRuntime.isRequested(
                environment: environment,
                userDefaults: userDefaults
              ),
              let session = QPeriaptIOSRuntime.currentSession,
              !authProfile.isEmpty,
              trustRootFingerprint.count == SHA256.byteCount,
              trustRootFingerprint == session.trustRootFingerprint,
              authProfile == session.authProfile else {
            return .unavailable
        }
        return .admitted(
            authProfile: authProfile,
            trustRootFingerprint: trustRootFingerprint,
            protocolIdentityConfiguration: protocolIdentityConfiguration
        )
    }

    func admits(provider: any CryptoProvider) -> Bool {
        guard case .admitted(
            let authProfile,
            let trustRootFingerprint,
            let protocolIdentityConfiguration
        ) = self,
              let provider = provider as? any QPeriaptHandshakeBoundCryptoProvider else {
            return false
        }
        return provider.qPeriaptAuthProfile == authProfile
            && provider.qPeriaptTrustRootFingerprint == trustRootFingerprint
            && provider.qPeriaptProtocolIdentityConfiguration == protocolIdentityConfiguration
    }

    /// Binds the immutable admission decision to the provider object retained
    /// by a handshake driver. An unavailable Q provider is replaced by an
    /// explicit rejecting provider, so later runtime activation cannot change
    /// the outcome for that driver.
    func bind(provider: any CryptoProvider) -> any CryptoProvider {
        guard let qPeriaptProvider = provider as? any QPeriaptRuntimeBoundCryptoProvider else {
            return provider
        }
        guard case .admitted(
            let authProfile,
            let trustRootFingerprint,
            let protocolIdentityConfiguration
        ) = self,
              qPeriaptProvider.qPeriaptAuthProfile == authProfile,
              qPeriaptProvider.qPeriaptTrustRootFingerprint == trustRootFingerprint else {
            return QPeriaptRejectedHandshakeCryptoProvider(base: provider)
        }
        return QPeriaptFrozenHandshakeCryptoProvider(
            base: qPeriaptProvider,
            authProfile: authProfile,
            trustRootFingerprint: trustRootFingerprint,
            protocolIdentityConfiguration: protocolIdentityConfiguration
        )
    }

    func isPeerEligible(_ capabilities: CryptoCapabilities) -> Bool {
        guard case .admitted(let authProfile, _, _) = self else { return false }
        return capabilities.pqcAvailable
            && capabilities.supportedKEM.contains(CryptoSuite.qperiaptABI2PolicyBound.rawValue)
            && capabilities.supportedSignature.contains(ProtocolSigningAlgorithm.mlDSA65.rawValue)
            && capabilities.supportedAuthProfiles.contains(authProfile)
            && capabilities.supportedAEAD.contains("AES-256-GCM")
            && capabilities.providerType == .qPeriapt
            && QPeriaptIOSPlatformPolicy.isPeerHandshakePlatformVersionEligible(
                capabilities.platformVersion
            )
    }
}

@available(iOS 17.0, *)
private struct QPeriaptFrozenHandshakeCryptoProvider:
    QPeriaptHandshakeBoundCryptoProvider,
    Sendable
{
    let base: any QPeriaptRuntimeBoundCryptoProvider
    let qPeriaptAuthProfile: String
    let qPeriaptTrustRootFingerprint: Data
    let qPeriaptProtocolIdentityConfiguration: ProtocolIdentityConfigurationRecord

    var providerName: String { base.providerName }
    var tier: CryptoTier { base.tier }
    var activeSuite: CryptoSuite { base.activeSuite }
    var supportedSuites: [CryptoSuite] { base.supportedSuites }

    init(
        base: any QPeriaptRuntimeBoundCryptoProvider,
        authProfile: String,
        trustRootFingerprint: Data,
        protocolIdentityConfiguration: ProtocolIdentityConfigurationRecord
    ) {
        precondition(base.qPeriaptAuthProfile == authProfile)
        precondition(base.qPeriaptTrustRootFingerprint == trustRootFingerprint)
        self.base = base
        qPeriaptAuthProfile = authProfile
        qPeriaptTrustRootFingerprint = trustRootFingerprint
        qPeriaptProtocolIdentityConfiguration = protocolIdentityConfiguration
    }

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        base.supportsSuite(suite)
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        try await base.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: recipientPublicKey,
            info: info
        )
    }

    func kemDemSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        try await base.kemDemSeal(
            plaintext: plaintext,
            recipientPublicKey: recipientPublicKey,
            info: info
        )
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        try await base.kemDemSealWithSecret(
            plaintext: plaintext,
            recipientPublicKey: recipientPublicKey,
            info: info
        )
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        try await base.hpkeOpen(sealedBox: sealedBox, privateKey: privateKey, info: info)
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        try await base.hpkeOpen(sealedBox: sealedBox, privateKey: privateKey, info: info)
    }

    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        try await base.kemDemOpen(sealedBox: sealedBox, privateKey: privateKey, info: info)
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        try await base.kemDemOpenWithSecret(
            sealedBox: sealedBox,
            privateKey: privateKey,
            info: info
        )
    }

    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try await base.kemEncapsulate(recipientPublicKey: recipientPublicKey)
    }

    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        try await base.kemDecapsulate(encapsulatedKey: encapsulatedKey, privateKey: privateKey)
    }

    func kemEncapsulate(
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try await base.kemEncapsulate(
            recipientPublicKey: recipientPublicKey,
            applicationContext: applicationContext
        )
    }

    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) async throws -> SecureBytes {
        try await base.kemDecapsulate(
            encapsulatedKey: encapsulatedKey,
            privateKey: privateKey,
            applicationContext: applicationContext
        )
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        try await base.sign(data: data, using: keyHandle)
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        try await base.verify(data: data, signature: signature, publicKey: publicKey)
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        try await base.generateKeyPair(for: usage)
    }
}

@available(iOS 17.0, *)
private struct QPeriaptRejectedHandshakeCryptoProvider: CryptoProvider, Sendable {
    let providerName: String
    let tier: CryptoTier
    let activeSuite: CryptoSuite
    let supportedSuites: [CryptoSuite] = []

    init(base: any CryptoProvider) {
        providerName = base.providerName
        tier = base.tier
        activeSuite = base.activeSuite
    }

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        _ = suite
        return false
    }

    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        throw rejection
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw rejection
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        throw rejection
    }

    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        throw rejection
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw rejection
    }

    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw rejection
    }

    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        throw rejection
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw rejection
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw rejection
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw rejection
    }

    private var rejection: CryptoProviderError {
        .pqcNotAvailable
    }
}

/// iOS product admission for the shared Q-Periapt runtime.
///
/// A session becomes observable only after signed-policy verification, durable
/// Keychain CAS, the native ABI round trip, and immutable registry installation.
@available(iOS 17.0, *)
enum QPeriaptIOSRuntime {
    private static let sessionRegistry = QPeriaptRuntimeSessionRegistry()

    static var currentSession: QPeriaptRuntimeSession? {
        sessionRegistry.snapshot()
    }

    static var authProfile: String? {
        currentSession?.authProfile
    }

    static func prepareProductionSession() async throws -> QPeriaptIOSRuntimePreparationResult {
        let entries = QPeriaptProductionTrustRootRegistry.entries
        guard !entries.isEmpty else { return .unprovisioned }
        guard entries.count == 1, let entry = entries.first else {
            throw QPeriaptIOSRuntimeError.ambiguousProductionRoots(count: entries.count)
        }
        try await activate(entry)
        return .activated
    }

    static func isRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if isTruthy(environment["SB_ENABLE_QPERIAPT"]) { return true }
        if let preferredSuite = environment["SB_PQC_PREFERRED_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           preferredSuite == "q-periapt" || preferredSuite == "qperiapt" {
            return true
        }
        return userDefaults.bool(forKey: "Settings.PreferQPeriaptBeta")
    }

    /// ML-DSA-65 is part of the authenticated ABI2 policy contract. A current
    /// ML-DSA-87 authority must not be silently replaced with a second identity.
    static func isEnabledForLocalRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard let configuration = try? ProtocolSigningIdentityPolicy
            .requiredConfiguration(defaults: userDefaults) else {
            return false
        }
        return isRequested(environment: environment, userDefaults: userDefaults)
            && currentSession != nil
            && configuration.algorithm == .mlDSA65
    }

    static func makeCryptoProvider(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> QPeriaptCryptoProvider? {
        guard isEnabledForLocalRuntime(
            environment: environment,
            userDefaults: userDefaults
        ), let session = currentSession else {
            return nil
        }
        return QPeriaptCryptoProvider(session: session)
    }

    private static func activate(_ entry: QPeriaptProductionTrustRootEntry) async throws {
        guard #available(iOS 26.0, *) else {
            throw QPeriaptIOSRuntimeError.unsupportedOS
        }
        let fingerprint = entry.material.verificationKeySHA256Pin
        guard fingerprint.count == SHA256.byteCount else {
            throw QPeriaptIOSRuntimeError.invalidRootFingerprintLength(actual: fingerprint.count)
        }
        let trustedStateStore = IOSQPeriaptTrustedStateStore(
            rootFingerprint: fingerprint,
            expectedTrustRootIdentifier: entry.material.trustRootIdentifier
        )
        let session = try await QPeriaptPolicyRuntime().resolveSession(
            material: entry.material,
            enrollmentMode: entry.enrollmentMode,
            trustedStateStore: trustedStateStore
        )
        guard session.trustRootFingerprint == fingerprint,
              try await QPeriaptCryptoProvider.quickRuntimeProbe(session: session) else {
            throw QPeriaptIOSRuntimeError.runtimeProbeFailed
        }
        try Task.checkCancellation()
        try sessionRegistry.install(session)
    }

    #if DEBUG || SKYBRIDGE_TESTING
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

    /// Test-target bridge that keeps the shared runtime linked only through the
    /// host app. The test bundle supplies fixture bytes but never links a second
    /// copy of the runtime or its process-wide admission registry.
    static func activateSignedPolicyForTesting(
        policyTOML: Data,
        detachedSignature: Data,
        verificationKey: Data,
        verificationKeySHA256Pin: Data,
        trustRootIdentifier: String
    ) async throws {
        try await activateForTesting(
            material: QPeriaptSignedPolicyMaterial(
                policyTOML: policyTOML,
                detachedSignature: detachedSignature,
                verificationKey: verificationKey,
                verificationKeySHA256Pin: verificationKeySHA256Pin,
                trustRootIdentifier: trustRootIdentifier
            ),
            enrollmentMode: .explicitlyAuthorizedFirstEnrollment
        )
    }

    static func resetForTesting() {
        sessionRegistry.resetForTesting()
    }
    #endif

    private static func isTruthy(_ raw: String?) -> Bool {
        guard let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return normalized == "1" || normalized == "true"
            || normalized == "yes" || normalized == "on"
    }

}

@available(iOS 17.0, *)
private struct IOSQPeriaptTrustedStateStore: QPeriaptTrustedStateStore {
    let rootFingerprint: Data
    let expectedTrustRootIdentifier: String

    func loadTrustedState(trustRootIdentifier: String) async throws -> Data? {
        guard trustRootIdentifier == expectedTrustRootIdentifier else {
            throw QPeriaptIOSRuntimeError.trustRootIdentifierMismatch
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
            throw QPeriaptIOSRuntimeError.trustRootIdentifierMismatch
        }
        return try KeychainManager.shared.compareAndSwapQPeriaptTrustedState(
            expectedPreviousState: expectedPreviousState,
            newState: newState,
            rootFingerprint: rootFingerprint
        )
    }
}
