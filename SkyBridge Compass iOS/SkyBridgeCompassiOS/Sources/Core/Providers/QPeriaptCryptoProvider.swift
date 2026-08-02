import CryptoKit
import Foundation
import SkyBridgeQPeriaptRuntime

/// Thin iOS bridge over the shared Q-Periapt ABI2 runtime.
///
/// Policy verification, native admission/cancellation, ABI validation, and KEM
/// execution remain owned by `SkyBridgeQPeriaptRuntime`. This type only adapts
/// those operations to the iOS app's `CryptoProvider` types. MessageB's
/// AES-256-GCM payload remains owned by the handshake layer after the canonical
/// MessageA context-bound KEM has established its shared secret.
@available(iOS 17.0, *)
public struct QPeriaptCryptoProvider: QPeriaptRuntimeBoundCryptoProvider, Sendable {
    public let providerName = "QPeriaptABI2PolicyBound"
    public let tier: CryptoTier = .qperiaptPQC
    public let activeSuite: CryptoSuite = .qperiaptABI2PolicyBound
    public let supportedSuites: [CryptoSuite] = [.qperiaptABI2PolicyBound]

    let qPeriaptAuthProfile: String
    let qPeriaptTrustRootFingerprint: Data

    private let adapter: QPeriaptNativeAdapter<SecureBytes>
    private let signatureProvider = OQSPQCCryptoProvider()

    public init(session: QPeriaptRuntimeSession) {
        adapter = QPeriaptNativeAdapter(session: session)
        qPeriaptAuthProfile = session.authProfile
        qPeriaptTrustRootFingerprint = session.trustRootFingerprint
    }

    public func supportsSuite(_ suite: CryptoSuite) -> Bool {
        suite == .qperiaptABI2PolicyBound
    }

    /// Performs the native ABI/keygen/KEM round trip before a session becomes
    /// visible to provider selection or capability advertisement.
    static func quickRuntimeProbe(session: QPeriaptRuntimeSession) async throws -> Bool {
        try QPeriaptRuntimeContract.requireCompatible()
        let adapter = QPeriaptNativeAdapter<SecureBytes>(session: session)
        let keyPair = try await adapter.generateKeyPair()
        defer { keyPair.privateKey.zeroize() }
        guard keyPair.publicKey.count == QPeriaptNativeAdapter<SecureBytes>.publicKeyLength,
              keyPair.privateKey.byteCount == QPeriaptNativeAdapter<SecureBytes>.privateKeyLength else {
            return false
        }

        let context = Data("skybridge/qperiapt/abi2/ios-runtime-probe/v1".utf8)
        let encapsulated = try await adapter.encapsulate(
            recipientPublicKey: keyPair.publicKey,
            applicationContext: context
        )
        defer { encapsulated.sharedSecret.zeroize() }
        let decapsulated = try await adapter.decapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: keyPair.privateKey,
            applicationContext: context
        )
        defer { decapsulated.zeroize() }
        var encapsulatedBytes = encapsulated.sharedSecret.copyData()
        defer { encapsulatedBytes.resetBytes(in: 0..<encapsulatedBytes.count) }
        var decapsulatedBytes = decapsulated.copyData()
        defer { decapsulatedBytes.resetBytes(in: 0..<decapsulatedBytes.count) }
        guard encapsulatedBytes.count == decapsulatedBytes.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(encapsulatedBytes, decapsulatedBytes) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }

    // MARK: - Context-bound KEM

    public func kemEncapsulate(
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        try await adapter.encapsulate(
            recipientPublicKey: recipientPublicKey,
            applicationContext: applicationContext
        )
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) async throws -> SecureBytes {
        try await adapter.decapsulate(
            encapsulatedKey: encapsulatedKey,
            privateKey: privateKey,
            applicationContext: applicationContext
        )
    }

    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation(
            "Q-Periapt ABI2 requires the canonical MessageA application context"
        )
    }

    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        throw CryptoProviderError.unsupportedOperation(
            "Q-Periapt ABI2 requires the canonical MessageA application context"
        )
    }

    // MARK: - Generic HPKE/KEM-DEM rejection

    /// `info` is an untyped caller-controlled value and therefore cannot prove
    /// that the canonical MessageA encoder was used. Q-Periapt accepts only the
    /// typed context-bound KEM surface above; the handshake layer performs DEM.

    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        throw CryptoProviderError.unsupportedOperation(
            "Q-Periapt ABI2 HPKE requires the typed canonical MessageA context path"
        )
    }

    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation(
            "Q-Periapt ABI2 KEM-DEM requires the typed canonical MessageA context path"
        )
    }

    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation(
            "Q-Periapt ABI2 HPKE requires the typed canonical MessageA context path"
        )
    }

    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        throw CryptoProviderError.unsupportedOperation(
            "Q-Periapt ABI2 HPKE requires the typed canonical MessageA context path"
        )
    }

    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.unsupportedOperation(
            "Q-Periapt ABI2 KEM-DEM requires the typed canonical MessageA context path"
        )
    }

    // MARK: - ML-DSA-65 identity operations

    public func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        try await signatureProvider.sign(data: data, using: keyHandle)
    }

    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        try await signatureProvider.verify(data: data, signature: signature, publicKey: publicKey)
    }

    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        switch usage {
        case .keyExchange, .ephemeral:
            let pair = try await adapter.generateKeyPair()
            return KeyPair(
                publicKey: KeyMaterial(data: pair.publicKey),
                privateKey: KeyMaterial(secure: pair.privateKey)
            )
        case .signing:
            return try await signatureProvider.generateKeyPair(for: .signing)
        }
    }

}
