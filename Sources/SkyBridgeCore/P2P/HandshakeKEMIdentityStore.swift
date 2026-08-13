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

/// Immutable KEM identity used by a one-shot, existing-only formal session.
public struct StaticHandshakeKEMIdentityStore: HandshakeKEMIdentityStore, Sendable {
    private let suiteWireID: UInt16
    private let material: HandshakeKEMIdentityMaterial

    public init(
        suiteWireID: UInt16,
        publicKey: Data,
        privateKey: SecureBytes
    ) {
        self.suiteWireID = suiteWireID
        self.material = HandshakeKEMIdentityMaterial(
            publicKey: publicKey,
            privateKey: privateKey
        )
    }

    public func getOrCreateKEMIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> HandshakeKEMIdentityMaterial {
        guard suite.wireId == suiteWireID,
              provider.tier == .liboqsPQC else {
            throw FormalMacInteropError.inconsistentExistingIdentity
        }
        return material
    }
}

struct DefaultHandshakeKEMIdentityStore: HandshakeKEMIdentityStore, Sendable {
    private let manager: DeviceIdentityKeyManager

    init(manager: DeviceIdentityKeyManager = .shared) {
        self.manager = manager
    }

    func getOrCreateKEMIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> HandshakeKEMIdentityMaterial {
        let keyRecord = try await manager.getOrCreateKEMIdentityKey(
            for: suite,
            provider: provider
        )
        return HandshakeKEMIdentityMaterial(
            publicKey: keyRecord.publicKey,
            privateKey: keyRecord.privateKey
        )
    }
}
