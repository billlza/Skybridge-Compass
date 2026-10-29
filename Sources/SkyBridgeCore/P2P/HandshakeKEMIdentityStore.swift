import Foundation

/// Runtime-provided local KEM identity material used during PQC handshakes.
public struct HandshakeKEMIdentityMaterial: Sendable {
    public let publicKey: Data
    public let privateKey: SecureBytes

    public init(publicKey: Data, privateKey: SecureBytes) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

/// Narrow runtime seam for loading or provisioning local KEM identity keys.
///
/// Keeping this contract thin lets future Android / Ubuntu runtimes plug in
/// their own key storage without changing the handshake state machine.
public protocol HandshakeKEMIdentityStore: Sendable {
    func getOrCreateKEMIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> HandshakeKEMIdentityMaterial
}

struct DefaultHandshakeKEMIdentityStore: HandshakeKEMIdentityStore, Sendable {
    func getOrCreateKEMIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> HandshakeKEMIdentityMaterial {
        let keyRecord = try await DeviceIdentityKeyManager.shared.getOrCreateKEMIdentityKey(
            for: suite,
            provider: provider
        )
        return HandshakeKEMIdentityMaterial(
            publicKey: keyRecord.publicKey,
            privateKey: keyRecord.privateKey
        )
    }
}
