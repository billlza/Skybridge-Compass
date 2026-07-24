import Foundation

/// Fully resolved local identity material consumed by the handshake runtime.
public struct ResolvedHandshakeIdentity: Sendable {
    public let identityPublicKey: Data
    public let identityKeyHandle: SigningKeyHandle?
    public let secureEnclaveKeyHandle: SigningKeyHandle?
    public let sigAAlgorithm: SignatureAlgorithm?

    public init(
        identityPublicKey: Data,
        identityKeyHandle: SigningKeyHandle? = nil,
        secureEnclaveKeyHandle: SigningKeyHandle? = nil,
        sigAAlgorithm: SignatureAlgorithm? = nil
    ) {
        self.identityPublicKey = identityPublicKey
        self.identityKeyHandle = identityKeyHandle
        self.secureEnclaveKeyHandle = secureEnclaveKeyHandle
        self.sigAAlgorithm = sigAAlgorithm
    }
}

/// Runtime seam for loading the local identity bundle used by `HandshakeDriver`.
///
/// This keeps key-handle / wire-payload assembly out of the state machine so
/// platform-specific key stores can be swapped in without touching handshake flow.
public protocol HandshakeIdentityProvider: Sendable {
    func resolveIdentity() async throws -> ResolvedHandshakeIdentity
}

/// Lightweight provider for already-resolved identity material.
public struct StaticHandshakeIdentityProvider: HandshakeIdentityProvider, Sendable {
    private let identity: ResolvedHandshakeIdentity

    public init(identity: ResolvedHandshakeIdentity) {
        self.identity = identity
    }

    public init(
        identityPublicKey: Data,
        identityKeyHandle: SigningKeyHandle? = nil,
        secureEnclaveKeyHandle: SigningKeyHandle? = nil,
        sigAAlgorithm: SignatureAlgorithm? = nil
    ) {
        self.identity = ResolvedHandshakeIdentity(
            identityPublicKey: identityPublicKey,
            identityKeyHandle: identityKeyHandle,
            secureEnclaveKeyHandle: secureEnclaveKeyHandle,
            sigAAlgorithm: sigAAlgorithm
        )
    }

    public func resolveIdentity() async throws -> ResolvedHandshakeIdentity {
        identity
    }
}

/// Apple runtime implementation backed by `DeviceIdentityKeyManager`.
///
/// The resolved identity is cached after the first lookup, so repeated handshakes
/// do not pay extra key-assembly cost beyond what we already do today.
@available(macOS 14.0, iOS 17.0, *)
public actor DeviceIdentityHandshakeProvider: HandshakeIdentityProvider {
    private let sigAAlgorithm: ProtocolSigningAlgorithm
    private let protocolSigningKeyProtection: ProtocolSigningKeyProtection?
    private let includeSecureEnclavePoP: Bool
    private let keyManager: DeviceIdentityKeyManager
    private var cachedIdentity: ResolvedHandshakeIdentity?

    public init(
        sigAAlgorithm: ProtocolSigningAlgorithm,
        protocolSigningKeyProtection: ProtocolSigningKeyProtection? = nil,
        includeSecureEnclavePoP: Bool = false,
        keyManager: DeviceIdentityKeyManager = .shared
    ) {
        self.sigAAlgorithm = sigAAlgorithm
        self.protocolSigningKeyProtection = protocolSigningKeyProtection
        self.includeSecureEnclavePoP = includeSecureEnclavePoP
        self.keyManager = keyManager
    }

    public func resolveIdentity() async throws -> ResolvedHandshakeIdentity {
        if let cachedIdentity {
            return cachedIdentity
        }

        let protection: ProtocolSigningKeyProtection
        if let protocolSigningKeyProtection {
            protection = protocolSigningKeyProtection
        } else {
            protection = try await keyManager
                .existingProtocolSigningKeyProtection(for: sigAAlgorithm)
                ?? .softwareKeychain
        }
        let protocolIdentity: (publicKey: Data, keyHandle: SigningKeyHandle)
        if protocolSigningKeyProtection != nil, sigAAlgorithm != .ed25519 {
            guard let existing = try await keyManager.existingProtocolSigningIdentity(
                for: sigAAlgorithm,
                protection: protection
            ) else {
                throw DeviceIdentityKeyError.incompleteKeyMaterial(
                    "The selected \(sigAAlgorithm.rawValue)/\(protection.rawValue) protocol identity is not committed"
                )
            }
            protocolIdentity = existing
        } else {
            protocolIdentity = try await keyManager.getProtocolSigningIdentity(
                for: sigAAlgorithm,
                protection: protection
            )
        }
        let protocolPublicKey = protocolIdentity.publicKey
        let signingKeyHandle = protocolIdentity.keyHandle
        let secureEnclavePublicKey = includeSecureEnclavePoP
            ? try await keyManager.getSecureEnclavePublicKey()
            : nil
        let secureEnclaveKeyHandle = includeSecureEnclavePoP
            ? try await keyManager.getSecureEnclaveKeyHandle()
            : nil

        let identityPublicKeyWire = ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: sigAAlgorithm,
            sePoPPublicKey: secureEnclavePublicKey
        ).asWire().encoded

        let resolved = ResolvedHandshakeIdentity(
            identityPublicKey: identityPublicKeyWire,
            identityKeyHandle: signingKeyHandle,
            secureEnclaveKeyHandle: secureEnclaveKeyHandle,
            sigAAlgorithm: sigAAlgorithm.wire
        )
        cachedIdentity = resolved
        return resolved
    }
}
