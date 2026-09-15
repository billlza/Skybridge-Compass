import Foundation
import XCTest
import SkyBridgeProtocolCore

/// 共享账号在线状态引擎的节奏与生命周期测试（macOS `PresenceService` 与 iOS `AccountPresenceService` 共用这份实现）。
///
/// 这里锁定的是「失败后等多久重试」和「挂起/恢复」两条以前没有任何测试覆盖的路径：
/// 前者决定失败时会不会把服务器打爆或反过来长时间不重试，后者决定进入后台再回前台会不会泄漏陈旧状态。
@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class AccountPresenceRefreshEngineTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var current = Date(timeIntervalSince1970: 1_000)
    }

    /// 记录轮询循环请求过的等待时长，并把时钟推进同样多，让循环无需真实等待即可推进。
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TimeInterval] = []
        var intervals: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func record(_ interval: TimeInterval) {
            lock.lock(); storage.append(interval); lock.unlock()
        }
    }

    private static func snapshot(online: [String], caller: String = "current") -> AccountDeviceListSnapshot {
        func record(_ id: String, online: Bool) -> AccountDeviceRecord {
            AccountDeviceRecord(
                deviceId: id,
                deviceName: id,
                status: "active",
                protocolSigningAlgorithm: "Ed25519",
                protocolPublicKeyFingerprint: String(repeating: "b", count: 64),
                platformRawValue: "macos",
                deviceModel: nil,
                osVersion: nil,
                appVersion: nil,
                lanAddresses: [],
                publicAddress: nil,
                capabilities: [],
                registeredAtEpochMilliseconds: nil,
                lastSeenAtEpochMilliseconds: nil,
                presenceUpdatedAtEpochMilliseconds: nil,
                online: online,
                isCaller: id == caller
            )
        }
        return AccountDeviceListSnapshot(
            generatedAtEpochMilliseconds: 1,
            callerDeviceId: caller,
            truncated: false,
            devices: online.map { record($0, online: true) }
        )
    }

    private enum EngineTestError: Error { case heartbeat, list }

    /// 供测试闭包读写的可变开关（闭包是 sendable，不能直接捕获局部 var）。
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Bool
        init(_ value: Bool) { storage = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    func testListFailuresGrowTheRetryDelayAndSuccessResetsIt() async {
        let clock = Clock()
        let listShouldFail = Flag(false)
        let engine = AccountPresenceRefreshEngine(
            refreshInterval: 30,
            onlineStateTTL: 90,
            now: { clock.current },
            registerPresence: {},
            listAccountDevices: {
                if listShouldFail.value { throw EngineTestError.list }
                return Self.snapshot(online: ["peer"])
            },
            trustedDeviceIDs: { ["peer"] },
            classifyFailure: { _ in .transport },
            onStateChange: { _ in },
            sleepOperation: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) }
        )

        engine.start()
        await engine.waitForCurrentRefresh()
        XCTAssertEqual(engine.nextRefreshDelaySeconds, 30, "一次成功刷新后回到常规节奏")

        listShouldFail.value = true
        var observed: [TimeInterval] = []
        for _ in 0..<3 {
            engine.triggerRefresh()
            await engine.waitForCurrentRefresh()
            observed.append(engine.nextRefreshDelaySeconds)
        }
        XCTAssertEqual(observed, [30, 60, 120], "连续失败必须指数退避，而不是固定 30 秒重试")

        listShouldFail.value = false
        engine.triggerRefresh()
        await engine.waitForCurrentRefresh()
        XCTAssertEqual(engine.nextRefreshDelaySeconds, 30, "恢复成功后退避必须清零")
        engine.stop()
    }

    func testHeartbeatOnlyFailuresAlsoGrowTheRetryDelay() async {
        let clock = Clock()
        let heartbeatShouldFail = Flag(true)
        let engine = AccountPresenceRefreshEngine(
            refreshInterval: 30,
            onlineStateTTL: 90,
            now: { clock.current },
            registerPresence: {
                if heartbeatShouldFail.value { throw EngineTestError.heartbeat }
            },
            // 列表一直成功：只有心跳在失败。
            listAccountDevices: { Self.snapshot(online: ["peer"]) },
            trustedDeviceIDs: { ["peer"] },
            classifyFailure: { _ in .transport },
            onStateChange: { _ in },
            sleepOperation: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) }
        )

        engine.start()
        await engine.waitForCurrentRefresh()
        XCTAssertEqual(engine.state.lastHeartbeatFailure, .transport)
        XCTAssertNil(engine.state.lastListFailure)
        XCTAssertEqual(engine.nextRefreshDelaySeconds, 30)

        engine.triggerRefresh()
        await engine.waitForCurrentRefresh()
        XCTAssertEqual(engine.nextRefreshDelaySeconds, 60, "心跳一直失败也必须退避，否则会以固定间隔无限重试")

        heartbeatShouldFail.value = false
        engine.triggerRefresh()
        await engine.waitForCurrentRefresh()
        XCTAssertNil(engine.state.lastHeartbeatFailure)
        XCTAssertEqual(engine.nextRefreshDelaySeconds, 30)
        engine.stop()
    }

    func testLoopSleepsForTheBackoffItComputed() async {
        let clock = Clock()
        let recorder = SleepRecorder()
        let firstSleep = expectation(description: "loop requested its first sleep")
        firstSleep.assertForOverFulfill = false
        let engine = AccountPresenceRefreshEngine(
            refreshInterval: 30,
            onlineStateTTL: 90,
            now: { clock.current },
            registerPresence: {},
            listAccountDevices: { Self.snapshot(online: []) },
            trustedDeviceIDs: { [] },
            classifyFailure: { _ in .transport },
            onStateChange: { _ in },
            sleepOperation: { interval in
                recorder.record(interval)
                firstSleep.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        )

        engine.start()
        await fulfillment(of: [firstSleep], timeout: 5)
        XCTAssertEqual(recorder.intervals.first, 30, "没有在线设备需要过期时，循环按刷新节奏睡眠")
        engine.stop()
    }

    func testSuspendKeepsTheSnapshotStopsTickingAndStartResumes() async {
        let clock = Clock()
        let listCount = ListCounter()
        let engine = AccountPresenceRefreshEngine(
            refreshInterval: 30,
            onlineStateTTL: 90,
            now: { clock.current },
            registerPresence: {},
            listAccountDevices: {
                listCount.value += 1
                return Self.snapshot(online: ["peer"])
            },
            trustedDeviceIDs: { ["peer"] },
            classifyFailure: { _ in .transport },
            onStateChange: { _ in },
            sleepOperation: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        )

        engine.start()
        await engine.waitForCurrentRefresh()
        XCTAssertEqual(listCount.value, 1)
        let snapshot = engine.state.accountDevices
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(engine.state.onlinePeerDeviceIds, ["peer"])

        engine.suspend()
        XCTAssertFalse(engine.isStarted, "挂起后不再计时")
        XCTAssertEqual(engine.state.accountDevices, snapshot, "挂起保留快照（后台回前台不该白屏）")
        XCTAssertEqual(engine.state.onlinePeerDeviceIds, ["peer"])

        engine.triggerRefresh()
        await engine.waitForCurrentRefresh()
        XCTAssertEqual(listCount.value, 1, "挂起期间不得再发请求")

        engine.start()
        await engine.waitForCurrentRefresh()
        XCTAssertEqual(listCount.value, 2, "恢复后立刻刷新一次")
        XCTAssertTrue(engine.isStarted)

        engine.stop()
        XCTAssertNil(engine.state.accountDevices, "停止（登出）必须清空快照，挂起不行")
        XCTAssertTrue(engine.state.onlinePeerDeviceIds.isEmpty)
    }
}

private final class ListCounter: @unchecked Sendable {
    var value = 0
}
