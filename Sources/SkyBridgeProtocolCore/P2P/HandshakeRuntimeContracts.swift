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
    func trustedFingerprint(for deviceId: String) async -> String?
    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data]
    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data?
}
