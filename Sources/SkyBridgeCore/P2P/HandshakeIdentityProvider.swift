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
    private let includeSecureEnclavePoP: Bool
    private let keyManager: DeviceIdentityKeyManager
    private var cachedIdentity: ResolvedHandshakeIdentity?

    public init(
        sigAAlgorithm: ProtocolSigningAlgorithm,
        includeSecureEnclavePoP: Bool = false,
        keyManager: DeviceIdentityKeyManager = .shared
    ) {
        self.sigAAlgorithm = sigAAlgorithm
        self.includeSecureEnclavePoP = includeSecureEnclavePoP
        self.keyManager = keyManager
    }

    public func resolveIdentity() async throws -> ResolvedHandshakeIdentity {
        if let cachedIdentity {
            return cachedIdentity
        }

        let protocolPublicKey = try await keyManager.getProtocolSigningPublicKey(for: sigAAlgorithm)
        let signingKeyHandle = try await keyManager.getProtocolSigningKeyHandle(for: sigAAlgorithm)
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
