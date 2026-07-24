//
// PQCSignatureProviderAutoFallbackSemanticsTests.swift
// SkyBridgeCoreTests
//
// 锁定 PQCSignatureProvider(.auto) 的双后端回退语义：
// - 互操作回退仅限运行性失败（Apple 抛错），不得在 Apple 确定性拒绝（返回 false）后用 OQS 重验
//   （否则验签接受面变成两个实现的并集）。
// - 签名回退仅限标准 liboqs 私钥（4032 字节）；Apple 64 字节、callback 和非法长度不得静默换后端。
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

    #if HAS_APPLE_PQC_SDK
    func testSignFallbackOnlyForStandardLiboqsPrivateKeyLength() throws {
        #if canImport(OQSRAII)
        XCTAssertTrue(
            PQCSignatureProvider.shouldUseLiboqsForSigningBeforeApple(key: .softwareKey(Data(count: 4032))),
            "标准 liboqs 4032 字节私钥必须在调用 Apple 前直接选择 liboqs，避免 smoke 中出现误导性 apple_failed 诊断"
        )
        XCTAssertTrue(
            PQCSignatureProvider.shouldRetrySignWithLiboqs(key: .softwareKey(Data(count: 4032))),
            "标准 liboqs 4032 字节私钥必须允许回退"
        )
        XCTAssertFalse(
            PQCSignatureProvider.shouldUseLiboqsForSigningBeforeApple(key: .softwareKey(Data(count: 64))),
            "Apple 64 字节私钥必须保留 Apple 首选路径"
        )
        XCTAssertFalse(
            PQCSignatureProvider.shouldRetrySignWithLiboqs(key: .softwareKey(Data(count: 64))),
            "Apple 64 字节私钥经 Apple 路径失败即为真失败，不得静默换后端"
        )
        for malformedLength in [0, 100, 4031, 4033] {
            XCTAssertFalse(
                PQCSignatureProvider.shouldUseLiboqsForSigningBeforeApple(key: .softwareKey(Data(count: malformedLength))),
                "非法长度 \(malformedLength) 字节的私钥不得预选 liboqs"
            )
            XCTAssertFalse(
                PQCSignatureProvider.shouldRetrySignWithLiboqs(key: .softwareKey(Data(count: malformedLength))),
                "非法长度 \(malformedLength) 字节的私钥不得进入 liboqs 回退路径"
            )
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testSignFallbackNeverAppliesToCallbackKeys() throws {
        #if canImport(OQSRAII)
        struct FailingCallback: SigningCallback {
            func sign(data: Data) async throws -> Data {
                throw SignatureProviderError.signatureFailed("test callback")
            }
        }
        XCTAssertFalse(
            PQCSignatureProvider.shouldUseLiboqsForSigningBeforeApple(key: .callback(FailingCallback())),
            "callback 密钥句柄不得在调用前预选 liboqs"
        )
        XCTAssertFalse(
            PQCSignatureProvider.shouldRetrySignWithLiboqs(key: .callback(FailingCallback())),
            "callback 密钥句柄不得回退 liboqs"
        )
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testVerifyFallbackRequiresExactMLDSA65Lengths() throws {
        #if canImport(OQSRAII)
        XCTAssertTrue(
            PQCSignatureProvider.shouldRetryVerifyWithLiboqs(
                signature: Data(count: 3309),
                publicKey: Data(count: 1952)
            )
        )
        let mismatches: [(signature: Int, publicKey: Int)] = [
            (3308, 1952), (3310, 1952), (3309, 1951), (3309, 1953), (0, 0)
        ]
        for mismatch in mismatches {
            XCTAssertFalse(
                PQCSignatureProvider.shouldRetryVerifyWithLiboqs(
                    signature: Data(count: mismatch.signature),
                    publicKey: Data(count: mismatch.publicKey)
                ),
                "签名 \(mismatch.signature)/公钥 \(mismatch.publicKey) 字节不得进入 liboqs 回退路径"
            )
        }
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
    }

    func testMLDSA87UsesOQSOnlyForTheExplicitPublicKeyVerifier() throws {
        #if canImport(OQSRAII)
        XCTAssertFalse(
            PQCSignatureProvider.shouldRetrySignWithLiboqs(
                algorithm: .mlDSA87,
                key: .softwareKey(Data(count: 4_896))
            )
        )
        #if canImport(liboqs)
        XCTAssertTrue(
            PQCSignatureProvider.shouldRetryVerifyWithLiboqs(
                algorithm: .mlDSA87,
                signature: Data(count: 4_627),
                publicKey: Data(count: 2_592)
            )
        )
        #else
        XCTAssertFalse(
            PQCSignatureProvider.shouldRetryVerifyWithLiboqs(
                algorithm: .mlDSA87,
                signature: Data(count: 4_627),
                publicKey: Data(count: 2_592)
            )
        )
        #endif
        #else
        throw XCTSkip("OQSRAII not available")
        #endif
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
