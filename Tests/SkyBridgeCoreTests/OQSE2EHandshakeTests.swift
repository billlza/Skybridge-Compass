import XCTest
@testable import SkyBridgeCore

final class OQSE2EHandshakeTests: XCTestCase {
    func testE2EHandshakeWithSessionToken() async throws {
        guard let provider = PQCProviderFactory.makeProvider() else { return }
        let peerA = "peer-A"
        let peerB = "peer-B"
 // 中文注释：A 侧封装
        let encA = try await provider.kemEncapsulate(peerId: peerB, kemVariant: "ML-KEM-768")
 // 中文注释：B 侧解封装
        let ssB = try await provider.kemDecapsulate(peerId: peerB, encapsulated: encA.encapsulated, kemVariant: "ML-KEM-768")
        let info = Data("session:E2E".utf8)
        let skB = SessionTokenKit.deriveSessionKey(sharedSecret: ssB, salt: Data(), info: info)
 // 中文注释：令牌签发与校验
        let payload = Data("token-payload".utf8)
        let sig = try await provider.sign(data: payload, peerId: peerA, algorithm: "ML-DSA-65")
        let ok = await provider.verify(data: payload, signature: sig, peerId: peerA, algorithm: "ML-DSA-65")
        XCTAssertTrue(ok)
        _ = skB // 仅校验流程，无需进一步加密演示
    }
}
