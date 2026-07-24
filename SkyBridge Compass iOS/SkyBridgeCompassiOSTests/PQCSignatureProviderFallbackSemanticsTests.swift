import Foundation
import CryptoKit
import XCTest
@testable import SkyBridgeCompass_iOS

/// 锁定 PQCSignatureProvider 双后端回退的决策语义：
/// - 签名回退仅限标准 liboqs 私钥（4032 字节）；Apple 格式（64 字节）与非法长度不得静默换后端。
/// - 验签回退仅限格式完全匹配 ML-DSA-65 的输入（公钥 1952、签名 3309），
///   且只在 Apple 路径抛出运行性异常时触发（确定性拒绝不重验，防止接受面并集化）。
@available(iOS 17.0, *)
final class PQCSignatureProviderFallbackSemanticsTests: XCTestCase {

    #if HAS_APPLE_PQC_SDK
    private func requireLiboqsBackend() throws {
        guard OQSPQCCryptoProvider.quickRuntimeProbe() else {
            throw XCTSkip("liboqs backend unavailable on this runtime")
        }
    }

    func testSignFallbackOnlyForStandardLiboqsPrivateKeyLength() throws {
        try requireLiboqsBackend()

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
    }

    func testSignFallbackNeverAppliesToCallbackKeys() throws {
        try requireLiboqsBackend()

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
    }

    func testVerifyFallbackRequiresExactMLDSA65Lengths() throws {
        try requireLiboqsBackend()

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
    }

    func testMLDSA87NeverEntersTheMLDSA65OQSFallback() throws {
        try requireLiboqsBackend()

        XCTAssertFalse(
            PQCSignatureProvider.shouldRetrySignWithLiboqs(
                algorithm: .mlDSA87,
                key: .softwareKey(Data(count: 4_896))
            )
        )
        XCTAssertFalse(
            PQCSignatureProvider.shouldRetryVerifyWithLiboqs(
                algorithm: .mlDSA87,
                signature: Data(count: 4_627),
                publicKey: Data(count: 2_592)
            )
        )
    }

    func testSelectorPreservesExactMLDSA87Algorithm() {
        let provider = ProtocolSignatureProviderSelector.select(for: .mlDSA87)
        XCTAssertEqual(provider.signatureAlgorithm, .mlDSA87)
    }

    func testAppleMLDSA87SoftwareKeyRoundTrip() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Apple CryptoKit ML-DSA requires iOS 26 or newer")
        }

        let privateKey = try MLDSA87.PrivateKey()
        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .applePQC)
        let message = Data("ios-provider-mldsa87-roundtrip".utf8)
        let signature = try await provider.sign(
            message,
            key: .softwareKey(privateKey.integrityCheckedRepresentation)
        )
        let isValid = try await provider.verify(
            message,
            signature: signature,
            publicKey: privateKey.publicKey.rawRepresentation
        )

        XCTAssertEqual(signature.count, 4_627)
        XCTAssertEqual(privateKey.publicKey.rawRepresentation.count, 2_592)
        XCTAssertTrue(isValid)
    }

    func testAppleMLDSA65SoftwareKeyRoundTrip() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Apple CryptoKit ML-DSA requires iOS 26 or newer")
        }

        let privateKey = try MLDSA65.PrivateKey()
        let provider = PQCSignatureProvider(algorithm: .mlDSA65, backend: .applePQC)
        let message = Data("ios-provider-mldsa65-roundtrip".utf8)
        let signature = try await provider.sign(
            message,
            key: .softwareKey(privateKey.integrityCheckedRepresentation)
        )
        let isValid = try await provider.verify(
            message,
            signature: signature,
            publicKey: privateKey.publicKey.rawRepresentation
        )

        XCTAssertEqual(signature.count, 3_309)
        XCTAssertEqual(privateKey.publicKey.rawRepresentation.count, 1_952)
        XCTAssertTrue(isValid)
    }

    func testMLDSA87CallbackOutputIsExactLengthCheckedWithoutFallback() async throws {
        struct FixedSignatureCallback: SigningCallback {
            let signature: Data

            func sign(data: Data) async throws -> Data {
                signature
            }
        }

        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .auto)
        let message = Data("ios-provider-mldsa87-callback".utf8)
        let signature = try await provider.sign(
            message,
            key: .callback(FixedSignatureCallback(signature: Data(count: 4_627)))
        )
        XCTAssertEqual(signature.count, 4_627)

        do {
            _ = try await provider.sign(
                message,
                key: .callback(FixedSignatureCallback(signature: Data(count: 4_626)))
            )
            XCTFail("A callback with a non-canonical ML-DSA-87 signature length must fail")
        } catch is SignatureProviderError {
            // Expected fail-closed result.
        } catch {
            XCTFail("Expected SignatureProviderError, got \(error)")
        }
    }

    func testMLDSA87CallbackFailureIsNotRetried() async {
        struct CallbackFailure: Error {}
        struct FailingCallback: SigningCallback {
            func sign(data: Data) async throws -> Data {
                throw CallbackFailure()
            }
        }

        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .auto)
        do {
            _ = try await provider.sign(
                Data("ios-provider-mldsa87-callback-failure".utf8),
                key: .callback(FailingCallback())
            )
            XCTFail("A callback failure must not retry with another backend")
        } catch is CallbackFailure {
            // Exact callback error proves the provider did not wrap or retry it.
        } catch {
            XCTFail("Expected CallbackFailure, got \(error)")
        }
    }

    func testMLDSA87OQSRawPrivateKeyIsExplicitlyUnavailable() async {
        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .oqs)
        do {
            _ = try await provider.sign(
                Data("ios-provider-mldsa87-oqs".utf8),
                key: .softwareKey(Data(count: 4_896))
            )
            XCTFail("ML-DSA-87 must not guess an unsupported OQS raw-key adapter")
        } catch let error as SignatureProviderError {
            guard case .pqcBackendUnavailable = error else {
                return XCTFail("Expected pqcBackendUnavailable, got \(error)")
            }
        } catch {
            XCTFail("Expected SignatureProviderError, got \(error)")
        }
    }

    func testMLDSA87VerifyRejectsNonExactLengths() async {
        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .applePQC)
        do {
            _ = try await provider.verify(
                Data("ios-provider-mldsa87-length".utf8),
                signature: Data(count: 4_627),
                publicKey: Data(count: 2_591)
            )
            XCTFail("A non-canonical ML-DSA-87 public key length must fail")
        } catch is SignatureProviderError {
            // Expected fail-closed result.
        } catch {
            XCTFail("Expected SignatureProviderError, got \(error)")
        }

        do {
            _ = try await provider.verify(
                Data("ios-provider-mldsa87-length".utf8),
                signature: Data(count: 4_626),
                publicKey: Data(count: 2_592)
            )
            XCTFail("A non-canonical ML-DSA-87 signature length must fail")
        } catch is SignatureProviderError {
            // Expected fail-closed result.
        } catch {
            XCTFail("Expected SignatureProviderError, got \(error)")
        }
    }
    #endif
}

/// 控制帧分片常量契约：锁定"一个完整 padded 帧 + 4 字节长度前缀恰好为一条 DataChannel 消息"
/// 的设计关系，防止后续单独修改其中一个常量导致分片与 padding 失配。
final class CrossNetworkWebRTCHandshakeLimitsContractTests: XCTestCase {
    func testControlFrameChunkCoversPaddedFramePlusLengthPrefix() {
        XCTAssertEqual(CrossNetworkWebRTCHandshakeLimits.maxPaddedPayloadBytes, 8188)
        XCTAssertEqual(CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes, 8192)
        XCTAssertEqual(
            CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes,
            CrossNetworkWebRTCHandshakeLimits.maxPaddedPayloadBytes + 4
        )
    }

    func testBufferedAmountLimitExceedsSingleControlFrame() {
        XCTAssertGreaterThan(
            CrossNetworkWebRTCHandshakeLimits.maxBufferedAmountBytes,
            UInt64(CrossNetworkWebRTCHandshakeLimits.maxControlFrameChunkBytes),
            "背压上限必须至少容纳一条完整控制帧消息"
        )
    }
}

final class ApplePQCProviderRuntimeProbeSourceContractTests: XCTestCase {
    func testQuickRuntimeProbeUsesSelfTestInsteadOfConstantTrue() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let providerURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("SkyBridgeCompassiOS/Sources/Core/Providers/ApplePQCProvider.swift")
        let source = try readRepositorySourceForSourceShapeTests(at: providerURL)

        XCTAssertFalse(
            source.contains("public static func quickRuntimeProbe() -> Bool {\n        true\n    }"),
            "Apple PQC runtime probes must prove key-generation support, not report constant success"
        )

        let regex = try NSRegularExpression(
            pattern: #"public static func quickRuntimeProbe\(\) -> Bool \{\s+selfTest\(\)\s+\}"#
        )
        let matchCount = regex.numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        XCTAssertEqual(matchCount, 2, "Both ApplePQC and AppleXWing probes must delegate to selfTest()")
    }
}

final class ApplePQCProviderRuntimeSelfTestTests: XCTestCase {
    func testApplePQCAndXWingProbesGenerateKeysOnAvailableRuntime() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Apple CryptoKit PQC runtime APIs require iOS 26 or newer.")
        }

        #if HAS_APPLE_PQC_SDK
        let plaintext = Data("skybridge-ios27-apple-pqc-runtime".utf8)
        let info = Data("skybridge-ios27-runtime-test".utf8)

        let pqcSelfTestResult = ApplePQCCryptoProvider.selfTest()
        XCTAssertTrue(pqcSelfTestResult, "ApplePQC self-test must generate ML-KEM and ML-DSA keys on iOS 26+.")
        XCTAssertEqual(
            ApplePQCCryptoProvider.quickRuntimeProbe(),
            pqcSelfTestResult,
            "ApplePQC quickRuntimeProbe must reflect the real self-test result."
        )

        let pqcProvider = ApplePQCCryptoProvider()
        let pqcKEMKeyPair = try await pqcProvider.generateKeyPair(for: .keyExchange)
        let pqcSealedBox = try await pqcProvider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: pqcKEMKeyPair.publicKey.bytes,
            info: info
        )
        let pqcOpened = try await pqcProvider.hpkeOpen(
            sealedBox: pqcSealedBox,
            privateKey: pqcKEMKeyPair.privateKey.bytes,
            info: info
        )
        XCTAssertEqual(pqcOpened, plaintext, "ApplePQC ML-KEM seal/open must round-trip on iOS 26+.")

        let pqcSigningKeyPair = try await pqcProvider.generateKeyPair(for: .signing)
        let pqcSignature = try await pqcProvider.sign(
            data: plaintext,
            using: .softwareKey(pqcSigningKeyPair.privateKey.bytes)
        )
        let pqcSignatureIsValid = try await pqcProvider.verify(
            data: plaintext,
            signature: pqcSignature,
            publicKey: pqcSigningKeyPair.publicKey.bytes
        )
        XCTAssertTrue(
            pqcSignatureIsValid,
            "ApplePQC ML-DSA sign/verify must pass on iOS 26+."
        )

        let xwingSelfTestResult = AppleXWingCryptoProvider.selfTest()
        XCTAssertTrue(xwingSelfTestResult, "AppleXWing self-test must generate X-Wing and ML-DSA keys on iOS 26+.")
        XCTAssertEqual(
            AppleXWingCryptoProvider.quickRuntimeProbe(),
            xwingSelfTestResult,
            "AppleXWing quickRuntimeProbe must reflect the real self-test result."
        )

        let xwingProvider = AppleXWingCryptoProvider()
        let xwingKEMKeyPair = try await xwingProvider.generateKeyPair(for: .keyExchange)
        let xwingSealedBox = try await xwingProvider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: xwingKEMKeyPair.publicKey.bytes,
            info: info
        )
        let xwingOpened = try await xwingProvider.hpkeOpen(
            sealedBox: xwingSealedBox,
            privateKey: xwingKEMKeyPair.privateKey.bytes,
            info: info
        )
        XCTAssertEqual(xwingOpened, plaintext, "AppleXWing HPKE seal/open must round-trip on iOS 26+.")

        let xwingSigningKeyPair = try await xwingProvider.generateKeyPair(for: .signing)
        let xwingSignature = try await xwingProvider.sign(
            data: plaintext,
            using: .softwareKey(xwingSigningKeyPair.privateKey.bytes)
        )
        let xwingSignatureIsValid = try await xwingProvider.verify(
            data: plaintext,
            signature: xwingSignature,
            publicKey: xwingSigningKeyPair.publicKey.bytes
        )
        XCTAssertTrue(
            xwingSignatureIsValid,
            "AppleXWing ML-DSA sign/verify must pass on iOS 26+."
        )
        #else
        throw XCTSkip("Apple CryptoKit PQC symbols are not present in the selected SDK.")
        #endif
    }
}
