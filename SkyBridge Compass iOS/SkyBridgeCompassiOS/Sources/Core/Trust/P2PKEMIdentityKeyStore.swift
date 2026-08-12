import Foundation

/// Persistent local KEM identity keys (per CryptoSuite).
/// Responder needs the private key to `kemDecapsulate()` PQC keyShares from initiator.
@available(iOS 17.0, *)
public actor P2PKEMIdentityKeyStore {
    public static let shared = P2PKEMIdentityKeyStore()

    public enum ExistingIdentityError: Error, Equatable, Sendable {
        case missingKeyPair(UInt16)
        case incompleteKeyPair(UInt16)
        case noExistingPQCIdentity
    }

    private let keychain = KeychainManager.shared

    private init() {}

    public func getOrCreateIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> (publicKey: Data, privateKey: SecureBytes) {
        let storageSuite = suite.canonicalKEMSuite
        let pubId = "p2p.kem.public.\(storageSuite.wireId)"
        let privId = "p2p.kem.private.\(storageSuite.wireId)"

        let storedPrivateKey = try? keychain.loadPrivateKey(identifier: privId)
        let storedPublicKey = try? keychain.loadPublicKey(identifier: pubId)
        if let priv = storedPrivateKey, let pub = storedPublicKey {
            return (publicKey: pub, privateKey: SecureBytes(data: priv))
        }

        if requiresExistingIdentityWithoutMutation {
            if storedPrivateKey != nil || storedPublicKey != nil {
                throw ExistingIdentityError.incompleteKeyPair(storageSuite.wireId)
            }
            throw ExistingIdentityError.missingKeyPair(storageSuite.wireId)
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

        let keys: [KEMPublicKeyInfo] = bySuiteWireId
            .keys
            .sorted()
            .compactMap { suiteWireId -> KEMPublicKeyInfo? in
                guard let publicKey = bySuiteWireId[suiteWireId] else { return nil }
                return KEMPublicKeyInfo(suiteWireId: suiteWireId, publicKey: publicKey)
            }
        if requiresExistingIdentityWithoutMutation, keys.isEmpty {
            throw ExistingIdentityError.noExistingPQCIdentity
        }
        return keys
    }

    private var requiresExistingIdentityWithoutMutation: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil
            && ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXISTING_TRUST_ONLY"] == "1"
    }
}
