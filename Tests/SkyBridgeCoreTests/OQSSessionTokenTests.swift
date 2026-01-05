import XCTest
@testable import SkyBridgeCore
import CryptoKit

final class OQSSessionTokenTests: XCTestCase {
    func testSessionDerivationAndTokenSignVerify() async throws {
 // 中文注释：使用 OQSProvider 在旧系统（macOS 14/15）上进行 ML‑KEM‑768 会话协商与 ML‑DSA‑65 令牌签名/验签
        guard let provider = PQCProviderFactory.makeProvider() else {
            XCTFail("PQCProvider 不可用")
            return
        }

        let peer = "session-peer"

 // 中文注释：KEM 封装（生成共享密钥与密文）
        let enc = try await provider.kemEncapsulate(peerId: peer, kemVariant: "ML-KEM-768")

 // 中文注释：KEM 解封装（恢复共享密钥）
        let ss2 = try await provider.kemDecapsulate(peerId: peer, encapsulated: enc.encapsulated, kemVariant: "ML-KEM-768")

 // 中文注释：HKDF 派生会话密钥（32字节），绑定 peer 与用途（info）
        let salt = Data() // 可按需设置随机盐
        let info = Data("session:\(peer)".utf8)
        let ikm1 = SymmetricKey(data: enc.sharedSecret)
        let ikm2 = SymmetricKey(data: ss2)
        let sk1 = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm1, salt: salt, info: info, outputByteCount: 32)
        let sk2 = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm2, salt: salt, info: info, outputByteCount: 32)
 // 中文注释：派生结果一致
        XCTAssertEqual(sk1.withUnsafeBytes { Data($0) }, sk2.withUnsafeBytes { Data($0) })

 // 中文注释：安全清零共享密钥材料
        var ss1Mutable = enc.sharedSecret
        ss1Mutable.secureErase()
        var ss2Mutable = ss2
        ss2Mutable.secureErase()

 // 中文注释：令牌载荷（最小示例）
        let claims = ["peer": peer, "ts": String(Date().timeIntervalSince1970)]
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [])

 // 中文注释：ML‑DSA‑65 签名令牌
        let tokenSig = try await provider.sign(data: payload, peerId: peer, algorithm: "ML-DSA-65")

 // 中文注释：ML‑DSA‑65 验证令牌
        let ok = await provider.verify(data: payload, signature: tokenSig, peerId: peer, algorithm: "ML-DSA-65")
        XCTAssertTrue(ok)
    }
}

