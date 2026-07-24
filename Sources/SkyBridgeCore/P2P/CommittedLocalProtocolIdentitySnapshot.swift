import Foundation

public enum CommittedLocalProtocolIdentitySnapshotError: Error, LocalizedError, Sendable {
    case missingIdentity(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    )
    case configurationChanged

    public var errorDescription: String? {
        switch self {
        case .missingIdentity(let algorithm, let protection):
            return "The selected \(algorithm.rawValue)/\(protection.rawValue) protocol identity is not committed"
        case .configurationChanged:
            return "The protocol identity configuration changed while the committed authority was loading"
        }
    }
}

/// One atomic runtime view of the active local protocol authority. Consumers
/// must advertise `publicKey` and sign with `keyHandle` from this same value;
/// re-reading settings or using a default-protection getter can cross slots if
/// software and Secure Enclave identities coexist.
@available(macOS 14.0, iOS 17.0, *)
public struct CommittedLocalProtocolIdentitySnapshot: Sendable {
    public let algorithm: ProtocolSigningAlgorithm
    public let protection: ProtocolSigningKeyProtection
    public let publicKey: Data
    public let keyHandle: SigningKeyHandle

    public var authoritativeFingerprint: String {
        ProtocolIdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: algorithm
        ).authoritativeFingerprint.lowercased()
    }

    public init(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection,
        publicKey: Data,
        keyHandle: SigningKeyHandle
    ) {
        self.algorithm = algorithm
        self.protection = protection
        self.publicKey = publicKey
        self.keyHandle = keyHandle
    }

    public static func loadActive(
        keyManager: DeviceIdentityKeyManager = .shared
    ) async throws -> Self {
        let configuration = try await SettingsManager.shared
            .committedProtocolIdentityConfiguration()
        let snapshot = try await load(
            algorithm: configuration.algorithm,
            protection: configuration.protection,
            keyManager: keyManager
        )
        guard try await SettingsManager.shared.committedProtocolIdentityConfiguration()
            == configuration else {
            throw CommittedLocalProtocolIdentitySnapshotError.configurationChanged
        }
        return snapshot
    }

    public static func load(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection,
        keyManager: DeviceIdentityKeyManager
    ) async throws -> Self {
        guard let identity = try await keyManager.existingProtocolSigningIdentity(
            for: algorithm,
            protection: protection
        ) else {
            throw CommittedLocalProtocolIdentitySnapshotError.missingIdentity(
                algorithm: algorithm,
                protection: protection
            )
        }
        return Self(
            algorithm: algorithm,
            protection: protection,
            publicKey: identity.publicKey,
            keyHandle: identity.keyHandle
        )
    }

    /// Returns the active authority first, followed by established software
    /// compatibility identities. Inactive ML-DSA-87 slots are intentionally not
    /// advertised: presence of 87 is the peer-visible active-capability signal.
    public static func loadActiveAndCompatibility(
        keyManager: DeviceIdentityKeyManager = .shared
    ) async throws -> [Self] {
        let active = try await loadActive(keyManager: keyManager)
        var snapshots = [active]
        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .ed25519]
        where algorithm != active.algorithm {
            guard let identity = try await keyManager.existingProtocolSigningIdentity(
                for: algorithm,
                protection: .softwareKeychain
            ) else { continue }
            snapshots.append(
                Self(
                    algorithm: algorithm,
                    protection: .softwareKeychain,
                    publicKey: identity.publicKey,
                    keyHandle: identity.keyHandle
                )
            )
        }
        return snapshots
    }
}
