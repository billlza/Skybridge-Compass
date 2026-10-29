import Foundation
import XCTest
@testable import SkyBridgeCore

/// `wrapIfEnabled` 在每一帧出站数据上都会解析一次填充配置（屏幕流约 60 赫兹、交互流 62.5 赫兹、
/// 外加每个控制心跳）。此前每次解析都会新建一个 App Group `UserDefaults`，
/// 并把整个进程环境字典物化五次，还要重新生成一遍桶数组。
///
/// 现在句柄、环境快照与桶数组都只解析一次。这里锁定的是**这次优化不能改变语义**：
/// UserDefaults 的键值必须仍然实时读取，运行时改配置照样立刻生效。
final class TrafficPaddingConfigResolutionTests: XCTestCase {
    private let enabledKey = "sb_traffic_padding_enabled"
    private let modeKey = "sb_traffic_padding_mode"
    private let fixedKey = "sb_traffic_padding_fixed_size"

    private func withRestoredDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = [enabledKey, modeKey, fixedKey].map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    func testUserDefaultsChangesTakeEffectImmediatelyDespiteCaching() {
        withRestoredDefaults {
            let defaults = UserDefaults.standard

            defaults.set(false, forKey: enabledKey)
            XCTAssertFalse(
                TrafficPaddingConfig.fromUserDefaults().enabled,
                "关闭状态必须被读到"
            )

            defaults.set(true, forKey: enabledKey)
            XCTAssertTrue(
                TrafficPaddingConfig.fromUserDefaults().enabled,
                "缓存的是句柄与环境快照，不是键值：运行时打开必须立即生效"
            )

            defaults.set(false, forKey: enabledKey)
            XCTAssertFalse(
                TrafficPaddingConfig.fromUserDefaults().enabled,
                "再关掉同样必须立即生效"
            )
        }
    }

    func testModeAndFixedSizeStillResolveFromLiveDefaults() {
        withRestoredDefaults {
            let defaults = UserDefaults.standard
            defaults.set(TrafficPaddingMode.fixed.rawValue, forKey: modeKey)
            defaults.set(4096, forKey: fixedKey)
            let configuration = TrafficPaddingConfig.fromUserDefaults()
            XCTAssertEqual(configuration.mode, .fixed)
            XCTAssertEqual(configuration.fixedSizeBytes, 4096)

            defaults.set(TrafficPaddingMode.bucketed.rawValue, forKey: modeKey)
            XCTAssertEqual(TrafficPaddingConfig.fromUserDefaults().mode, .bucketed)
        }
    }

    func testRepeatedResolutionIsStableAndReturnsTheSameBucketLadder() {
        let first = TrafficPaddingConfig.fromUserDefaults()
        let second = TrafficPaddingConfig.fromUserDefaults()
        XCTAssertEqual(first.bucketSizesBytes, second.bucketSizesBytes)
        XCTAssertFalse(first.bucketSizesBytes.isEmpty)
        // 阶梯必须是 256 起的 2 的幂，且严格递增到 cap（缓存不得改变形状）。
        XCTAssertEqual(first.bucketSizesBytes.first, 256)
        XCTAssertEqual(first.bucketSizesBytes, first.bucketSizesBytes.sorted())
        XCTAssertEqual(Set(first.bucketSizesBytes).count, first.bucketSizesBytes.count)
        XCTAssertGreaterThanOrEqual(first.bucketSizesBytes.last ?? 0, 65_536)
    }

    func testPaddingRoundTripIsUnchangedByTheCaching() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 251) })
        let configuration = TrafficPaddingConfig(
            enabled: true,
            debugLog: false,
            mode: .bucketed,
            fixedSizeBytes: 0,
            bucketSizesBytes: TrafficPaddingConfig.fromUserDefaults().bucketSizesBytes
        )
        let padded = try TrafficPadding.wrapIfEnabled(payload, configuration: configuration, label: "test")
        XCTAssertGreaterThan(padded.count, payload.count)
        XCTAssertEqual(TrafficPadding.unwrapIfNeeded(padded, label: "test"), payload)
    }
}
