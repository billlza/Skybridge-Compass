import Foundation

@MainActor
public final class P2PHandshakeManager {
    private let security: P2PSecurityManager
    public init(security: P2PSecurityManager) { self.security = security }
    public func initiate(deviceId: String) async throws -> Data {
        let r = try await security.kemEncapsulate(deviceId: deviceId, kemVariant: "ML-KEM-768")
        security.deriveAndStoreSessionKey(sharedSecret: r.sharedSecret, deviceId: deviceId)
        return r.encapsulated
    }
    public func complete(deviceId: String, encapsulated: Data) async throws {
        let ss = try await security.kemDecapsulate(deviceId: deviceId, encapsulated: encapsulated, kemVariant: "ML-KEM-768")
        security.deriveAndStoreSessionKey(sharedSecret: ss, deviceId: deviceId)
    }
}
