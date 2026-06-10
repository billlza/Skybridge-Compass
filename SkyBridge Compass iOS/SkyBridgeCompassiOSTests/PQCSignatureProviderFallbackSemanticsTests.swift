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
            PQCSignatureProvider.shouldRetrySignWithLiboqs(key: .softwareKey(Data(count: 4032))),
            "标准 liboqs 4032 字节私钥必须允许回退"
        )
        XCTAssertFalse(
            PQCSignatureProvider.shouldRetrySignWithLiboqs(key: .softwareKey(Data(count: 64))),
            "Apple 64 字节私钥经 Apple 路径失败即为真失败，不得静默换后端"
        )
        for malformedLength in [0, 100, 4031, 4033] {
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
