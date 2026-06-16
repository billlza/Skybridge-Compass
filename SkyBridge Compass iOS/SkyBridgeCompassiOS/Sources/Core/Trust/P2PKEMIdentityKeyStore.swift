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
        let storageSuite = suite.canonicalKEMSuite
        let pubId = "p2p.kem.public.\(storageSuite.wireId)"
        let privId = "p2p.kem.private.\(storageSuite.wireId)"

        if let (pub, priv) = try loadStoredIdentityKey(publicIdentifier: pubId, privateIdentifier: privId) {
            return (publicKey: pub, privateKey: SecureBytes(data: priv))
        }

        let pair = try await provider.generateKeyPair(for: .keyExchange)
        try keychain.savePublicKey(pair.publicKey.bytes, identifier: pubId)
        try keychain.savePrivateKey(pair.privateKey.bytes, identifier: privId)
        return (publicKey: pair.publicKey.bytes, privateKey: SecureBytes(data: pair.privateKey.bytes))
    }

    private func loadStoredIdentityKey(
        publicIdentifier: String,
        privateIdentifier: String
    ) throws -> (publicKey: Data, privateKey: Data)? {
        let privateKey: Data?
        let publicKey: Data?

        do {
            privateKey = try keychain.loadPrivateKey(identifier: privateIdentifier)
        } catch KeychainError.itemNotFound {
            privateKey = nil
        }

        do {
            publicKey = try keychain.loadPublicKey(identifier: publicIdentifier)
        } catch KeychainError.itemNotFound {
            publicKey = nil
        }

        switch (publicKey, privateKey) {
        case (nil, nil):
            return nil
        case let (publicKey?, privateKey?):
            return (publicKey: publicKey, privateKey: privateKey)
        default:
            throw KeychainError.incompleteKeyMaterial("P2P KEM identity keypair is incomplete")
        }
    }

    public func getOrCreateBootstrapPublicKeys() async throws -> [KEMPublicKeyInfo] {
        var bySuiteWireId: [UInt16: Data] = [:]

        let provider = CryptoProviderFactory.make(policy: .requirePQC)
        for suite in provider.supportedSuites where suite.isPQCGroup {
            let (publicKey, _) = try await getOrCreateIdentityKey(for: suite, provider: provider)
            bySuiteWireId[suite.wireId] = publicKey
        }

        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            var nativeProviders: [any CryptoProvider] = [ApplePQCCryptoProvider()]
            if AppleXWingCryptoProvider.quickRuntimeProbe() {
                nativeProviders.append(AppleXWingCryptoProvider())
            }
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
