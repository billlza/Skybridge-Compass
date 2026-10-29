import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

final class P2PControlTrafficPaddingTests: XCTestCase {
    func testDisabledModeStillEnforcesFinalControlFrameBoundary() throws {
        let configuration = TrafficPaddingConfig(
            enabled: false,
            debugLog: false,
            mode: .bucketed,
            fixedSizeBytes: 0,
            bucketSizesBytes: []
        )

        let exact = Data(
            repeating: 0,
            count: P2PControlFramePolicy.maximumBodyByteCount
        )
        XCTAssertEqual(
            try TrafficPadding.wrapForP2PControlFrame(
                exact,
                configuration: configuration
            ).count,
            exact.count
        )

        let oversized = Data(
            repeating: 0,
            count: P2PControlFramePolicy.maximumBodyByteCount + 1
        )
        XCTAssertThrowsError(
            try TrafficPadding.wrapForP2PControlFrame(
                oversized,
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual(
                error as? P2PControlFramePolicyError,
                .bodyTooLarge(
                    actual: oversized.count,
                    maximum: P2PControlFramePolicy.maximumBodyByteCount
                )
            )
        }
    }

    func testFixedModeRejectsInvalidTargetBeforeAllocation() {
        let configuration = TrafficPaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .fixed,
            fixedSizeBytes: Int.max,
            bucketSizesBytes: []
        )

        XCTAssertThrowsError(
            try TrafficPadding.wrapForP2PControlFrame(
                Data([0x01]),
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual(
                error as? P2PControlFramePolicyError,
                .invalidPaddingTarget(
                    actual: Int.max,
                    maximum: P2PControlFramePolicy.maximumBodyByteCount
                )
            )
        }
    }

    func testFixedModeDoesNotSilentlyGrowPastConfiguredTarget() {
        let payload = Data(repeating: 0xA5, count: 64)
        let configuration = TrafficPaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .fixed,
            fixedSizeBytes: 32,
            bucketSizesBytes: []
        )

        XCTAssertThrowsError(
            try TrafficPadding.wrapForP2PControlFrame(
                payload,
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual(
                error as? P2PControlFramePolicyError,
                .payloadExceedsFixedPaddingTarget(required: 72, configured: 32)
            )
        }
    }

    func testBucketedModeProducesValidRoundTripWithinFrameCeiling() throws {
        let payload = Data(repeating: 0x5A, count: 300)
        let configuration = TrafficPaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .bucketed,
            fixedSizeBytes: 0,
            bucketSizesBytes: [256, 512, 1_024]
        )

        let wrapped = try TrafficPadding.wrapForP2PControlFrame(
            payload,
            configuration: configuration
        )

        XCTAssertEqual(wrapped.count, 512)
        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(wrapped), payload)
    }

    func testStatisticsBoundRemoteControlledLabelsAndByteCountBuckets() async {
        let defaults = UserDefaults.standard
        let groupDefaults = UserDefaults(suiteName: "group.com.skybridge.compass")
        let statsEnabledKey = "sb_traffic_padding_stats_enabled"
        let autoFlushKey = "sb_traffic_padding_stats_autoflush"
        defaults.set(true, forKey: statsEnabledKey)
        defaults.set(false, forKey: autoFlushKey)
        groupDefaults?.set(true, forKey: statsEnabledKey)
        groupDefaults?.set(false, forKey: autoFlushKey)
        TrafficPaddingStats.refreshSubmissionAdmission()
        await TrafficPaddingStats.shared.reset()

        for index in 0..<100 {
            await TrafficPaddingStats.shared.recordWrap(
                label: "remote-label-\(index)-\(String(repeating: "x", count: 96))",
                rawBytes: index,
                paddedBytes: index + 1
            )
        }
        for byteCount in stride(from: 1, through: 8 * 1_024 * 1_024, by: 31_337) {
            await TrafficPaddingStats.shared.recordUnwrap(
                label: "bucket-probe",
                totalBytes: byteCount,
                rawBytes: max(0, byteCount - 8)
            )
        }

        let snapshot = await TrafficPaddingStats.shared.snapshot()
        XCTAssertLessThanOrEqual(snapshot.count, 64)
        XCTAssertTrue(snapshot.keys.allSatisfy { $0.count <= 64 })
        XCTAssertTrue(snapshot.values.allSatisfy { $0.bucketCounts.count <= 16 })

        await TrafficPaddingStats.shared.reset()
        defaults.removeObject(forKey: statsEnabledKey)
        defaults.removeObject(forKey: autoFlushKey)
        groupDefaults?.removeObject(forKey: statsEnabledKey)
        groupDefaults?.removeObject(forKey: autoFlushKey)
        TrafficPaddingStats.refreshSubmissionAdmission()
    }
}
