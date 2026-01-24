import Foundation

/// Persistent local KEM identity keys (per CryptoSuite).
/// Responder needs the private key to `kemDecapsulate()` PQC keyShares from initiator.
@available(iOS 17.0, *)
public actor P2PKEMIdentityKeyStore {
    public static let shared = P2PKEMIdentityKeyStore()

    private let keychain = KeychainManager.shared

    private init() {}

    public func getOrCreateIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> (publicKey: Data, privateKey: SecureBytes) {
        let pubId = "p2p.kem.public.\(suite.wireId)"
        let privId = "p2p.kem.private.\(suite.wireId)"

        if let priv = try? keychain.loadPrivateKey(identifier: privId),
           let pub = try? keychain.loadPublicKey(identifier: pubId) {
            return (publicKey: pub, privateKey: SecureBytes(data: priv))
        }

        let pair = try await provider.generateKeyPair(for: .keyExchange)
        try keychain.savePublicKey(pair.publicKey.bytes, identifier: pubId)
        try keychain.savePrivateKey(pair.privateKey.bytes, identifier: privId)
        return (publicKey: pair.publicKey.bytes, privateKey: SecureBytes(data: pair.privateKey.bytes))
    }
}


