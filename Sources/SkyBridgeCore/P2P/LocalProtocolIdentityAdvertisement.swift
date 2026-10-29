import Foundation

enum LocalProtocolIdentityAdvertisementError: Error, LocalizedError, Sendable {
    case missingActiveIdentity(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    )
    case invalidPublicKey(algorithm: ProtocolSigningAlgorithm, actualLength: Int)

    var errorDescription: String? {
        switch self {
        case .missingActiveIdentity(let algorithm, let protection):
            return "The active \(algorithm.rawValue) identity is missing from the \(protection.rawValue) authority slot"
        case .invalidPublicKey(let algorithm, let actualLength):
            return "The \(algorithm.rawValue) identity public key has invalid length \(actualLength)"
        }
    }
}

/// Builds post-auth pairing identity advertisements from exact, pre-existing
/// `(algorithm, protection)` authority slots. It never calls a default software
/// getter, so advertising a Secure Enclave identity cannot create or select a
/// conflicting software key.
@available(macOS 14.0, iOS 17.0, *)
enum LocalProtocolIdentityAdvertisement {
    static func load() async throws -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        let identities = try await CommittedLocalProtocolIdentitySnapshot
            .loadActiveAndCompatibility()
        return try load(identities: identities)
    }

    static func load(
        identities: [CommittedLocalProtocolIdentitySnapshot]
    ) throws -> [AppMessage.ProtocolIdentityPublicKeyInfo] {
        guard let activeIdentity = identities.first else {
            throw LocalProtocolIdentityAdvertisementError.missingActiveIdentity(
                algorithm: .mlDSA65,
                protection: .softwareKeychain
            )
        }
        guard activeIdentity.algorithm != .ed25519 else {
            throw LocalProtocolIdentityAdvertisementError.missingActiveIdentity(
                algorithm: activeIdentity.algorithm,
                protection: activeIdentity.protection
            )
        }

        var advertised: [AppMessage.ProtocolIdentityPublicKeyInfo] = []
        for identity in identities {
            try validate(publicKey: identity.publicKey, algorithm: identity.algorithm)
            advertised.append(
                AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: identity.algorithm.rawValue,
                    publicKey: identity.publicKey
                )
            )
        }

        let normalized = AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(advertised) ?? []
        guard normalized.contains(where: {
            $0.normalizedAlgorithm == activeIdentity.algorithm
                && $0.publicKey == activeIdentity.publicKey
        }) else {
            throw LocalProtocolIdentityAdvertisementError.missingActiveIdentity(
                algorithm: activeIdentity.algorithm,
                protection: activeIdentity.protection
            )
        }
        return normalized
    }

    static func validate(
        publicKey: Data,
        algorithm: ProtocolSigningAlgorithm
    ) throws {
        let expectedLength: Int
        switch algorithm {
        case .ed25519:
            expectedLength = 32
        case .mlDSA65:
            expectedLength = 1_952
        case .mlDSA87:
            expectedLength = 2_592
        }
        guard publicKey.count == expectedLength else {
            throw LocalProtocolIdentityAdvertisementError.invalidPublicKey(
                algorithm: algorithm,
                actualLength: publicKey.count
            )
        }
    }
}
