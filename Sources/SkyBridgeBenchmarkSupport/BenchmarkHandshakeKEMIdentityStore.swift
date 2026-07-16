import Foundation
import SkyBridgeCore

/// Benchmark-scoped, immutable KEM identity storage.
///
/// The store deliberately keeps private key bytes in process memory only. Each
/// handshake request receives a new `SecureBytes` value, so benchmark drivers do
/// not share mutable secret containers or touch the process-wide device identity.
public struct BenchmarkHandshakeKEMIdentityStore: HandshakeKEMIdentityStore, Sendable {
    private struct StoredIdentity: Sendable {
        let suite: CryptoSuite
        let publicKey: Data
        let privateKey: SecureBytes
    }

    private let providerName: String
    private let providerTypeIdentifier: ObjectIdentifier
    private let providerTier: CryptoTier
    private let providerActiveCanonicalWireID: UInt16
    private let identitiesByCanonicalWireID: [UInt16: StoredIdentity]

    private init(
        providerName: String,
        providerTypeIdentifier: ObjectIdentifier,
        providerTier: CryptoTier,
        providerActiveCanonicalWireID: UInt16,
        identitiesByCanonicalWireID: [UInt16: StoredIdentity]
    ) {
        self.providerName = providerName
        self.providerTypeIdentifier = providerTypeIdentifier
        self.providerTier = providerTier
        self.providerActiveCanonicalWireID = providerActiveCanonicalWireID
        self.identitiesByCanonicalWireID = identitiesByCanonicalWireID
    }

    /// Generates one identity for every distinct canonical PQC KEM suite in an
    /// offer. V2 and V1 aliases therefore share the same static KEM identity.
    public static func make(
        offeredSuites: [CryptoSuite],
        provider: any CryptoProvider
    ) async throws -> Self {
        var identities: [UInt16: StoredIdentity] = [:]

        for offeredSuite in offeredSuites where offeredSuite.isPQC {
            let canonicalSuite = offeredSuite.canonicalKEMSuite
            guard identities[canonicalSuite.wireId] == nil else { continue }
            guard provider.supportsSuite(canonicalSuite) else {
                throw CryptoProviderError.unsupportedAlgorithm(
                    "\(provider.providerName) does not support benchmark KEM suite \(canonicalSuite.rawValue)"
                )
            }

            let keyPair = try await provider.generateKeyPair(for: .keyExchange)
            try validate(
                keyPair: keyPair,
                canonicalSuite: canonicalSuite,
                providerName: provider.providerName,
                providerTier: provider.tier
            )
            identities[canonicalSuite.wireId] = StoredIdentity(
                suite: canonicalSuite,
                publicKey: keyPair.publicKey.bytes,
                privateKey: SecureBytes(data: keyPair.privateKey.bytes)
            )
        }

        return Self(
            providerName: provider.providerName,
            providerTypeIdentifier: ObjectIdentifier(type(of: provider)),
            providerTier: provider.tier,
            providerActiveCanonicalWireID: provider.activeSuite.canonicalKEMSuite.wireId,
            identitiesByCanonicalWireID: identities
        )
    }

    /// Builds the authenticated peer-public-key map for the exact offered suite
    /// set. Forward-secure aliases retain their own dictionary key while sharing
    /// their canonical static KEM public key.
    public func trustPublicKeys(
        for offeredSuites: [CryptoSuite]
    ) throws -> [CryptoSuite: Data] {
        var result: [CryptoSuite: Data] = [:]
        for offeredSuite in offeredSuites where offeredSuite.isPQC {
            let canonicalSuite = offeredSuite.canonicalKEMSuite
            guard let identity = identitiesByCanonicalWireID[canonicalSuite.wireId] else {
                throw CryptoProviderError.unsupportedAlgorithm(
                    "benchmark KEM identity is missing for \(canonicalSuite.rawValue)"
                )
            }
            result[offeredSuite] = identity.publicKey
        }
        return result
    }

    public func getOrCreateKEMIdentityKey(
        for requestedSuite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> HandshakeKEMIdentityMaterial {
        let canonicalSuite = requestedSuite.canonicalKEMSuite
        guard provider.providerName == providerName,
              ObjectIdentifier(type(of: provider)) == providerTypeIdentifier,
              provider.tier == providerTier,
              provider.activeSuite.canonicalKEMSuite.wireId == providerActiveCanonicalWireID else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "benchmark KEM identity is bound to \(providerName) at tier \(providerTier.rawValue)"
            )
        }
        guard provider.supportsSuite(canonicalSuite) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "\(provider.providerName) does not support benchmark KEM suite \(canonicalSuite.rawValue)"
            )
        }
        guard let identity = identitiesByCanonicalWireID[canonicalSuite.wireId],
              identity.suite.wireId == canonicalSuite.wireId else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "benchmark KEM identity is missing for \(canonicalSuite.rawValue)"
            )
        }
        return HandshakeKEMIdentityMaterial(
            publicKey: identity.publicKey,
            privateKey: SecureBytes(data: identity.privateKey.copyData())
        )
    }

    private static func validate(
        keyPair: KeyPair,
        canonicalSuite: CryptoSuite,
        providerName: String,
        providerTier: CryptoTier
    ) throws {
        guard keyPair.publicKey.usage == .keyExchange else {
            throw CryptoProviderError.keyUsageMismatch(
                expected: .keyExchange,
                actual: keyPair.publicKey.usage
            )
        }
        guard keyPair.privateKey.usage == .keyExchange else {
            throw CryptoProviderError.keyUsageMismatch(
                expected: .keyExchange,
                actual: keyPair.privateKey.usage
            )
        }
        guard keyPair.publicKey.suite.canonicalKEMSuite.wireId == canonicalSuite.wireId,
              keyPair.privateKey.suite.canonicalKEMSuite.wireId == canonicalSuite.wireId else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "\(providerName) generated benchmark key material for a different KEM suite"
            )
        }
        guard let contract = KEMIdentityKeyLengthContract.resolve(
            suite: canonicalSuite,
            providerTier: providerTier
        ) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "no benchmark KEM length contract for \(canonicalSuite.rawValue) at tier \(providerTier.rawValue)"
            )
        }
        guard keyPair.publicKey.bytes.count == contract.publicKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: contract.publicKeyLength,
                actual: keyPair.publicKey.bytes.count,
                suite: canonicalSuite.rawValue,
                usage: .keyExchange
            )
        }
        guard keyPair.privateKey.bytes.count == contract.privateKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: contract.privateKeyLength,
                actual: keyPair.privateKey.bytes.count,
                suite: canonicalSuite.rawValue,
                usage: .keyExchange
            )
        }
    }
}
