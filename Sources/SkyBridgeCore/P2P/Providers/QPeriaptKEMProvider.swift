import Foundation
import SkyBridgeProtocolCore
import SkyBridgeQPeriaptRuntime

/// ABI2 policy-bound KEM adapter for call sites that use the narrow
/// ``KEMProvider`` protocol. A verified runtime session and a protocol-derived,
/// non-empty application context are mandatory at construction time.
@available(macOS 14.0, iOS 17.0, *)
public struct QPeriaptKEMProvider: KEMProvider, Sendable {
    public var algorithmName: String {
        P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue
    }

    public var isPQC: Bool { true }

    private let adapter: QPeriaptNativeAdapter
    private let applicationContext: Data

    public init(
        session: QPeriaptRuntimeSession,
        applicationContext: Data
    ) throws {
        guard !applicationContext.isEmpty else {
            throw CryptoProviderError.operationFailed(
                "Q-Periapt ABI2 KEM provider requires a non-empty application context"
            )
        }
        guard applicationContext.count <= QPeriaptNativeAdapter.maximumApplicationContextLength else {
            throw CryptoProviderError.lengthExceeded(
                "Q-Periapt application context",
                applicationContext.count,
                QPeriaptNativeAdapter.maximumApplicationContextLength
            )
        }
        self.adapter = QPeriaptNativeAdapter(session: session)
        self.applicationContext = applicationContext
    }

    public func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        let keys = try await adapter.generateKeyPair()
        return (publicKey: keys.publicKey, privateKey: keys.privateKey.copyData())
    }

    public func encapsulate(publicKey: Data) async throws -> (sharedSecret: Data, encapsulated: Data) {
        let result = try await adapter.encapsulate(
            recipientPublicKey: publicKey,
            applicationContext: applicationContext
        )
        return (
            sharedSecret: result.sharedSecret.copyData(),
            encapsulated: result.encapsulatedKey
        )
    }

    public func decapsulate(encapsulated: Data, privateKey: Data) async throws -> Data {
        let secret = try await adapter.decapsulate(
            encapsulatedKey: encapsulated,
            privateKey: SecureBytes(data: privateKey),
            applicationContext: applicationContext
        )
        return secret.copyData()
    }
}
