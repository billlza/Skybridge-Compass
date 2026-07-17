import CryptoKit
import Foundation
import SkyBridgeProtocolCore

#if canImport(CQPeriapt)
import CQPeriapt
#if canImport(Security)
import Security
#endif

/// Q-Periapt ABI2 policy-bound KEM + the existing ML-DSA-65 identity-signature
/// implementation. All Q-Periapt KEM operations reuse one native adapter; this
/// avoids the former duplicated ABI1 implementation in two provider types.
@available(macOS 14.0, iOS 17.0, *)
public struct QPeriaptCryptoProvider: ApplicationPolicyBoundCryptoProvider, Sendable {
    public let providerName = "QPeriaptABI2PolicyBound"
    public let tier: CryptoTier = .qperiaptPQC
    public let activeSuite: CryptoSuite = .qperiaptABI2PolicyBound
    public var supportedSuites: [CryptoSuite] { [.qperiaptABI2PolicyBound] }

    private static let nonceSize = 12
    private static let aesKeySize = 32
    private static let hkdfSaltLabel = "SkyBridge-KDF-Salt-v1|"

    private let adapter: QPeriaptNativeAdapter
    private let signatureProvider = OQSPQCCryptoProvider()

    public init(session: QPeriaptRuntimeSession) {
        self.adapter = QPeriaptNativeAdapter(session: session)
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
        guard keys.publicKey.count == QPeriaptNativeAdapter.publicKeyLength,
              keys.privateKey.byteCount == QPeriaptNativeAdapter.privateKeyLength else {
            return false
        }

        let context = Data("skybridge/qperiapt/abi2/runtime-probe/v1".utf8)
        let encapsulated = try await adapter.encapsulate(
            recipientPublicKey: keys.publicKey,
            applicationContext: context
        )
        guard encapsulated.encapsulatedKey.count == QPeriaptNativeAdapter.encapsulatedKeyLength,
              encapsulated.sharedSecret.byteCount == QPeriaptNativeAdapter.sharedSecretLength else {
            return false
        }
        let decapsulated = try await adapter.decapsulate(
            encapsulatedKey: encapsulated.encapsulatedKey,
            privateKey: keys.privateKey,
            applicationContext: context
        )
        var decapsulatedData = decapsulated.copyData()
        defer { decapsulatedData.resetBytes(in: 0..<decapsulatedData.count) }
        var encapsulatedData = encapsulated.sharedSecret.copyData()
        defer { encapsulatedData.resetBytes(in: 0..<encapsulatedData.count) }
        return decapsulatedData == encapsulatedData
    }

    // MARK: - Policy-bound application-context KEM

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
        let result = try await kemDemSealWithSecret(
            plaintext: plaintext,
            recipientPublicKey: recipientPublicKey,
            info: info
        )
        return result.sealedBox
    }

    public func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        let kem = try await adapter.encapsulate(
            recipientPublicKey: recipientPublicKey,
            applicationContext: info
        )
        let key = Self.deriveSymmetricKey(from: kem.sharedSecret, info: info)
        let nonceData = try Self.randomNonce()
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return (
            HPKESealedBox(
                encapsulatedKey: kem.encapsulatedKey,
                nonce: nonceData,
                ciphertext: sealed.ciphertext,
                tag: sealed.tag
            ),
            kem.sharedSecret
        )
    }

    public func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        let result = try await kemDemOpenWithSecret(
            sealedBox: sealedBox,
            privateKey: privateKey,
            info: info
        )
        return result.plaintext
    }

    public func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        let secret = try await adapter.decapsulate(
            encapsulatedKey: sealedBox.encapsulatedKey,
            privateKey: privateKey,
            applicationContext: info
        )
        let key = Self.deriveSymmetricKey(from: secret, info: info)
        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let sealed = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return (try AES.GCM.open(sealed, using: key), secret)
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

    private static func deriveSymmetricKey(from sharedSecret: SecureBytes, info: Data) -> SymmetricKey {
        var saltInput = Data(hkdfSaltLabel.utf8)
        saltInput.append(info)
        let salt = Data(SHA256.hash(data: saltInput))
        var secretData = sharedSecret.copyData()
        defer { secretData.resetBytes(in: 0..<secretData.count) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secretData),
            salt: salt,
            info: info,
            outputByteCount: aesKeySize
        )
    }

    private static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceSize)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CryptoProviderError.keyGenerationFailed(
                "SecRandomCopyBytes failed while generating an AES-GCM nonce (\(status))"
            )
        }
        #else
        throw CryptoProviderError.providerNotAvailable(.qPeriapt)
        #endif
        return Data(bytes)
    }
}
#endif
