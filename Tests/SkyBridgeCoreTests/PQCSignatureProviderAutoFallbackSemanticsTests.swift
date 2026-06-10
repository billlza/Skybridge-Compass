//
// PQCSignatureProviderAutoFallbackSemanticsTests.swift
// SkyBridgeCoreTests
//
// 锁定 PQCSignatureProvider(.auto) 的双后端回退语义：
// - 互操作回退仅限运行性失败（Apple 抛错），不得在 Apple 确定性拒绝（返回 false）后用 OQS 重验
//   （否则验签接受面变成两个实现的并集）。
// - liboqs 私钥（4032 字节）经 .auto 签名必须成功（Apple 失败 → OQS 回退路径）。
// - 非法密钥必须显式失败，不得静默成功或吞掉任一后端的错误。
//

import XCTest
@testable import SkyBridgeCore
#if canImport(OQSRAII)
import OQSRAII
#endif

@available(macOS 14.0, iOS 17.0, *)
final class PQCSignatureProviderAutoFallbackSemanticsTests: XCTestCase {

    #if canImport(OQSRAII)
    private func makeOQSKeyPair() throws -> (publicKey: Data, privateKey: Data) {
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(skLen))
        let result = oqs_raii_mldsa65_keypair(&publicKeyBytes, pkLen, &privateKeyBytes, skLen)
        guard result == OQSRAII_SUCCESS else {
            throw XCTSkip("liboqs ML-DSA-65 keypair generation unavailable")
        }
        return (Data(publicKeyBytes), Data(privateKeyBytes))
    }
    #endif

    /// liboqs 4032 字节私钥经 .auto 签名必须成功（覆盖 Apple 失败 → OQS 回退），
    /// 且签名能被 .auto 验签接受（覆盖跨后端互操作）。
    func testAutoSignWithOQSPrivateKeySucceedsAndVerifies() async throws {
        #if canImport(OQSRAII)
        let provider = PQCSignatureProvider(backend: .auto)
        let keys = try makeOQSKeyPair()
        let message = Data("auto-fallback-roundtrip".utf8)

        let signature = try await provider.sign(message, key: .softwareKey(keys.privateKey))
        XCTAssertEqual(signature.count, 3309, "ML-DSA-65 signature must be 3309 bytes")

        let isValid = try await provider.verify(message, signature: signature, publicKey: keys.publicKey)
        XCTAssertTrue(isValid, ".auto must verify a signature produced via the OQS fallback path")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    /// 篡改签名后 .auto 验签必须返回 false（确定性密码学拒绝），不得抛错。
    /// 回归保护：Apple 返回 false 时不得被包装为错误，也不得借 OQS 重验扩大接受面。
    func testAutoVerifyTamperedSignatureReturnsFalse() async throws {
        #if canImport(OQSRAII)
        let provider = PQCSignatureProvider(backend: .auto)
        let keys = try makeOQSKeyPair()
        let message = Data("auto-fallback-tamper".utf8)

        var signature = try await provider.sign(message, key: .softwareKey(keys.privateKey))
        signature[0] ^= 0xFF

        let isValid = try await provider.verify(message, signature: signature, publicKey: keys.publicKey)
        XCTAssertFalse(isValid, "Tampered signature must be rejected deterministically (false, not throw)")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    /// 篡改消息后 .auto 验签必须返回 false。
    func testAutoVerifyTamperedMessageReturnsFalse() async throws {
        #if canImport(OQSRAII)
        let provider = PQCSignatureProvider(backend: .auto)
        let keys = try makeOQSKeyPair()
        let message = Data("auto-fallback-message-tamper".utf8)

        let signature = try await provider.sign(message, key: .softwareKey(keys.privateKey))
        var tampered = message
        tampered[0] ^= 0xFF

        let isValid = try await provider.verify(tampered, signature: signature, publicKey: keys.publicKey)
        XCTAssertFalse(isValid, "Signature over different message must be rejected")
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    /// 非法私钥（既非 Apple 64 字节也非 liboqs 4032 字节）必须显式抛错，不得静默成功。
    func testAutoSignWithMalformedKeyThrows() async throws {
        let provider = PQCSignatureProvider(backend: .auto)
        let malformedKey = Data(repeating: 0xAB, count: 10)
        let message = Data("auto-fallback-malformed-key".utf8)

        do {
            _ = try await provider.sign(message, key: .softwareKey(malformedKey))
            XCTFail("Signing with a malformed key must throw")
        } catch {
            // 任一后端的显式错误均可接受；关键是不得静默成功。
        }
    }
}
