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

    public func getOrCreateBootstrapPublicKeys() async throws -> [KEMPublicKeyInfo] {
        var bySuiteWireId: [UInt16: Data] = [:]

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        for suite in provider.supportedSuites where suite.isPQCGroup {
            let (publicKey, _) = try await getOrCreateIdentityKey(for: suite, provider: provider)
            bySuiteWireId[suite.wireId] = publicKey
        }

        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            let nativeProviders: [any CryptoProvider] = [ApplePQCCryptoProvider(), AppleXWingCryptoProvider()]
            for nativeProvider in nativeProviders {
                for suite in nativeProvider.supportedSuites where suite.isPQCGroup {
                    let (publicKey, _) = try await getOrCreateIdentityKey(for: suite, provider: nativeProvider)
                    bySuiteWireId[suite.wireId] = publicKey
                }
            }
        }
        #endif

        return bySuiteWireId
            .keys
            .sorted()
            .compactMap { suiteWireId in
                guard let publicKey = bySuiteWireId[suiteWireId] else { return nil }
                return KEMPublicKeyInfo(suiteWireId: suiteWireId, publicKey: publicKey)
            }
    }
}
