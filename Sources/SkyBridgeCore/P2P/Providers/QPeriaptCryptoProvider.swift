import Foundation
import SkyBridgeProtocolCore
import SkyBridgeQPeriaptRuntime

struct QPeriaptProviderIdentity: Sendable, Equatable {
    let authProfile: String
    let trustRootFingerprint: Data
}

protocol QPeriaptSessionBoundCryptoProvider: ApplicationContextBoundCryptoProvider {
    var qPeriaptProviderIdentity: QPeriaptProviderIdentity { get }
}

/// Q-Periapt ABI2 policy-bound KEM + the existing ML-DSA-65 identity-signature
/// implementation. All Q-Periapt KEM operations reuse one native adapter; this
/// avoids the former duplicated ABI1 implementation in two provider types.
@available(macOS 14.0, iOS 17.0, *)
public struct QPeriaptCryptoProvider: QPeriaptSessionBoundCryptoProvider, Sendable {
    public let providerName = "QPeriaptABI2PolicyBound"
    public let tier: CryptoTier = .qperiaptPQC
    public let activeSuite: CryptoSuite = .qperiaptABI2PolicyBound
    public var supportedSuites: [CryptoSuite] { [.qperiaptABI2PolicyBound] }

    private let adapter: QPeriaptNativeAdapter
    private let signatureProvider = OQSPQCCryptoProvider()
    let qPeriaptProviderIdentity: QPeriaptProviderIdentity

    public init(session: QPeriaptRuntimeSession) {
        self.adapter = QPeriaptNativeAdapter(session: session)
        self.qPeriaptProviderIdentity = QPeriaptProviderIdentity(
            authProfile: session.authProfile,
            trustRootFingerprint: session.trustRootFingerprint
        )
    }

    public func supportsSuite(_ suite: CryptoSuite) -> Bool {
        suite == .qperiaptABI2PolicyBound
    }

    /// Runs the native ABI/runtime/keygen/KEM probe on the bounded crypto actor.
    /// Errors remain typed and observable; callers decide how to surface them.
    public static func quickRuntimeProbe(session: QPeriaptRuntimeSession) async throws -> Bool {
        try QPeriaptRuntimeContract.requireCompatible()
        let adapter = QPeriaptNativeAdapter(session: session)
        let keys = try await adapter.generateKeyPair()
        defer { keys.privateKey.zeroize() }
        guard keys.publicKey.count == QPeriaptNativeAdapter.publicKeyLength,
              keys.privateKey.byteCount == QPeriaptNativeAdapter.privateKeyLength else {
            return false
        }

        let context = Data("skybridge/qperiapt/abi2/runtime-probe/v1".utf8)
        let encapsulated = try await adapter.encapsulate(
            recipientPublicKey: keys.publicKey,
            applicationContext: context
        )
        defer { encapsulated.sharedSecret.zeroize() }
        guard encapsulated.encapsulatedKey.count == QPeriaptNativeAdapter.encapsulatedKeyLength,
              encapsulated.sharedSecret.byteCount == QPeriaptNativeAdapter.sharedSecretLength else {
            return false
        }
        let decapsulated = try await adapter.decapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: keys.privateKey,
            applicationContext: context
        )
        defer { decapsulated.zeroize() }
        guard decapsulated.byteCount == QPeriaptNativeAdapter.sharedSecretLength else {
            return false
        }
        return constantTimeEqual(decapsulated, encapsulated.sharedSecret)
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

    /// ABI2 must never be invoked through a context-free KEM surface.
    public func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.operationFailed(
            "Q-Periapt ABI2 requires the protocol-derived application context"
        )
    }

    /// ABI2 must never be invoked through a context-free KEM surface.
    public func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        throw CryptoProviderError.operationFailed(
            "Q-Periapt ABI2 requires the protocol-derived application context"
        )
    }

    // MARK: - KEM + DEM

    public func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        throw Self.genericSurfaceUnavailable
    }

    public func kemDemSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        throw Self.genericSurfaceUnavailable
    }

    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw Self.genericSurfaceUnavailable
    }

    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        throw Self.genericSurfaceUnavailable
    }

    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        throw Self.genericSurfaceUnavailable
    }

    public func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        throw Self.genericSurfaceUnavailable
    }

    public func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        throw Self.genericSurfaceUnavailable
    }

    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw Self.genericSurfaceUnavailable
    }

    // MARK: - Identity signatures

    public func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        try await signatureProvider.sign(data: data, using: keyHandle)
    }

    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        try await signatureProvider.verify(data: data, signature: signature, publicKey: publicKey)
    }

    public func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        switch usage {
        case .keyExchange:
            let keys = try await adapter.generateKeyPair()
            defer { keys.privateKey.zeroize() }
            return KeyPair(
                publicKey: KeyMaterial(
                    suite: activeSuite,
                    usage: .keyExchange,
                    bytes: keys.publicKey,
                    formatVersion: 2
                ),
                privateKey: KeyMaterial(
                    suite: activeSuite,
                    usage: .keyExchange,
                    bytes: keys.privateKey.copyData(),
                    formatVersion: 2
                )
            )
        case .signing:
            let keys = try await signatureProvider.generateKeyPair(for: .signing)
            return KeyPair(
                publicKey: KeyMaterial(
                    suite: activeSuite,
                    usage: .signing,
                    bytes: keys.publicKey.bytes,
                    formatVersion: keys.publicKey.formatVersion
                ),
                privateKey: KeyMaterial(
                    suite: activeSuite,
                    usage: .signing,
                    bytes: keys.privateKey.bytes,
                    formatVersion: keys.privateKey.formatVersion
                )
            )
        }
    }

    private static let genericSurfaceUnavailable = CryptoProviderError.operationFailed(
        "Q-Periapt ABI2 is available only through the canonical MessageA application-context KEM surface"
    )

    private static func constantTimeEqual(_ lhs: SecureBytes, _ rhs: SecureBytes) -> Bool {
        guard lhs.byteCount == rhs.byteCount else { return false }
        var difference: UInt8 = 0
        lhs.withUnsafeBytes { lhsBytes in
            rhs.withUnsafeBytes { rhsBytes in
                for index in 0..<lhsBytes.count {
                    difference |= lhsBytes[index] ^ rhsBytes[index]
                }
            }
        }
        return difference == 0
    }

}
