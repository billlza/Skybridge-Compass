import XCTest
@testable import SkyBridgeCore

@MainActor
final class P2PHandshakeTests: XCTestCase {
    func testKEMHandshakeStoresSessionKeys() async throws {
        if PQCProviderFactory.currentProvider == "不可用" { return }
        let secA = P2PSecurityManager()
        let secB = P2PSecurityManager()
        try await secA.start()
        try await secB.start()
        let hmA = P2PHandshakeManager(security: secA)
        let hmB = P2PHandshakeManager(security: secB)
        let deviceId = "peer-B"
        let encapsulated = try await hmA.initiate(deviceId: deviceId)
        try await hmB.complete(deviceId: deviceId, encapsulated: encapsulated)
        XCTAssertTrue(secA.hasSessionKey(for: deviceId))
        XCTAssertTrue(secB.hasSessionKey(for: deviceId))
    }
}
