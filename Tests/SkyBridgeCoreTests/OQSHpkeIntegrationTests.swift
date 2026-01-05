import XCTest
@testable import SkyBridgeCore

final class OQSHpkeIntegrationTests: XCTestCase {
    func testHpkeSealOpenWithAADAndToken() async throws {
 // 中文注释：仅在 macOS 26+ 上执行 ApplePQCProvider 的 HPKE 集成测试
        if #available(macOS 26.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else {
                XCTFail("PQCProvider 不可用")
                return
            }

            let peer = "hpke-peer"
            let plaintext = Data("Hello HPKE".utf8)
            let aad = Data("SkyBridgeHPKE-AAD".utf8)

 // 中文注释：HPKE 封装
            let sealed = try await provider.hpkeSeal(recipientPeerId: peer, plaintext: plaintext, associatedData: aad)

 // 中文注释：HPKE 解封装（使用相同 AAD）
            let opened = try await provider.hpkeOpen(recipientPeerId: peer, ciphertext: sealed.ciphertext, encapsulatedKey: sealed.encapsulatedKey, associatedData: aad)
            XCTAssertEqual(opened, plaintext)

 // 中文注释：令牌签发与校验（ML‑DSA‑65）
            let claims = ["peer": peer, "ts": String(Date().timeIntervalSince1970)]
            let payload = try JSONSerialization.data(withJSONObject: claims, options: [])
            let sig = try await provider.sign(data: payload, peerId: peer, algorithm: "ML-DSA-65")
            let ok = await provider.verify(data: payload, signature: sig, peerId: peer, algorithm: "ML-DSA-65")
            XCTAssertTrue(ok)

 // 中文注释：使用不同 AAD 解封装应失败
            let badAAD = Data("SkyBridgeHPKE-AAD-Mismatch".utf8)
            do {
                _ = try await provider.hpkeOpen(recipientPeerId: peer, ciphertext: sealed.ciphertext, encapsulatedKey: sealed.encapsulatedKey, associatedData: badAAD)
                XCTFail("不同AAD不应成功解封装")
            } catch {
 // 预期失败
                XCTAssertTrue(true)
            }
        }
    }

    func testHpkeMismatchAADFails() async throws {
        if #available(macOS 26.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else { return }
            let peer = "hpke-peer-2"
            let pt = Data("HPKE-AAD-Mismatch".utf8)
            let aad1 = Data("AAD-1".utf8)
            let aad2 = Data("AAD-2".utf8)
            let sealed = try await provider.hpkeSeal(recipientPeerId: peer, plaintext: pt, associatedData: aad1)
            do {
                _ = try await provider.hpkeOpen(recipientPeerId: peer, ciphertext: sealed.ciphertext, encapsulatedKey: sealed.encapsulatedKey, associatedData: aad2)
                XCTFail("不同AAD不应成功解密")
            } catch { XCTAssertTrue(true) }
        }
    }


    func testHpkeTamperedEncapsulatedKeyFails() async throws {
        if #available(macOS 26.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else { return }
            let peer = "hpke-peer-4"
            let pt = Data("HPKE-Tamper-EncKey".utf8)
            let aad = Data("AAD".utf8)
            var sealed = try await provider.hpkeSeal(recipientPeerId: peer, plaintext: pt, associatedData: aad)
 // 中文注释：篡改封装密钥
            if !sealed.encapsulatedKey.isEmpty { sealed.encapsulatedKey[0] ^= 0xAA }
            do {
                _ = try await provider.hpkeOpen(recipientPeerId: peer, ciphertext: sealed.ciphertext, encapsulatedKey: sealed.encapsulatedKey, associatedData: aad)
                XCTFail("篡改封装密钥不应成功解密")
            } catch { XCTAssertTrue(true) }
        }
    }

    func testHpkeEmptyAndLongAAD() async throws {
        if #available(macOS 26.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else { return }
            let peer = "hpke-peer-5"
            let pt = Data("HPKE-AAD-length".utf8)
            let emptyAAD = Data()
            let longAAD = Data(repeating: 0x42, count: 4096)
            let sealed1 = try await provider.hpkeSeal(recipientPeerId: peer, plaintext: pt, associatedData: emptyAAD)
            let opened1 = try await provider.hpkeOpen(recipientPeerId: peer, ciphertext: sealed1.ciphertext, encapsulatedKey: sealed1.encapsulatedKey, associatedData: emptyAAD)
            XCTAssertEqual(opened1, pt)
            let sealed2 = try await provider.hpkeSeal(recipientPeerId: peer, plaintext: pt, associatedData: longAAD)
            let opened2 = try await provider.hpkeOpen(recipientPeerId: peer, ciphertext: sealed2.ciphertext, encapsulatedKey: sealed2.encapsulatedKey, associatedData: longAAD)
            XCTAssertEqual(opened2, pt)
        }
    }
}
