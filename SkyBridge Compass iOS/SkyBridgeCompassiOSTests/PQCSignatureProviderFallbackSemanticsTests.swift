import Foundation
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
