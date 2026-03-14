import Foundation

// MARK: - DiscoveryTransport

/// Minimal transport contract used by the handshake runtime.
///
/// Implementations may use Bonjour, WebSocket, BLE, or any other link layer as
/// long as they can deliver framed handshake payloads to a peer.
public protocol DiscoveryTransport: Sendable {
    func send(to peer: PeerIdentifier, data: Data) async throws
}

// MARK: - HandshakeTrustProvider

/// Trust material lookup used by the handshake runtime for identity pinning and
/// KEM bootstrap.
@available(macOS 14.0, iOS 17.0, *)
public protocol HandshakeTrustProvider: Sendable {
    /// Returns the canonical protocol identity fingerprint for `deviceId`.
    ///
    /// Implementations must use the same construction as
    /// `IdentityPublicKeys.authoritativeProtocolFingerprint()`: lowercase hex
    /// over the protocol signing algorithm tag plus the raw protocol public key
    /// bytes. Do not return a raw SHA-256 of the wire blob or bare public key.
    func trustedFingerprint(for deviceId: String) async -> String?
    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data]
    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data?
}
