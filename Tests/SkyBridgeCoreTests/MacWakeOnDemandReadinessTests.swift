#if os(macOS)
import XCTest
@testable import SkyBridgeCore

/// Pins the honesty properties of the Wake on Demand assessment.
///
/// The failure mode this guards against is telling the user "sleep discovery is fine" on the basis
/// of evidence we do not have. Two distinct unknowns exist and neither may collapse into "ready":
/// a probe that has not run or failed, and the "Wake for network access" system setting, which the
/// current macOS SDK exposes no public API for.
@available(macOS 14.0, *)
@MainActor
final class MacWakeOnDemandReadinessTests: XCTestCase {

    func testSleepProxyServiceTypeMatchesTheBonjourTypeProxiesAdvertise() {
        XCTAssertEqual(
            MacWakeOnDemandReadiness.sleepProxyServiceType,
            "_sleep-proxy._udp",
            "服务类型写错会让探测永远返回 absent，从而给出错误的「无 proxy」结论"
        )
    }

    func testUnprobedStateIsNotReportedAsReadyOrAsAbsent() {
        let readiness = MacWakeOnDemandReadiness()

        XCTAssertEqual(readiness.sleepProxyAvailability, .unprobed)
        guard case .notAssessed = readiness.assessment else {
            return XCTFail("未探测必须是 notAssessed，不得被读成 ready 或 noProxyOnLink")
        }
        XCTAssertNil(readiness.lastProbedAt)
    }

    func testProbeFailureIsDistinctFromProxyAbsence() {
        // "我们没能看" 与 "确实没有" 是不同结论：前者不该让用户以为休眠可发现已经坏了，
        // 也不该让用户以为它是好的。
        let failed = MacWakeOnDemandReadiness.SleepProxyAvailability.probeFailed(
            reason: "local network denied"
        )
        let absent = MacWakeOnDemandReadiness.SleepProxyAvailability.absent

        XCTAssertNotEqual(failed, absent)
    }

    func testAssessmentNeverClaimsTheSystemSettingIsVerified() {
        // 只要 SDK 没有公开 API，能给出的最强结论就是「proxy 在，设置无法验证」。
        // 一旦有人把它改成 ready/enabled，这条断言必须失败。
        let cases: [MacWakeOnDemandReadiness.Assessment] = [
            .proxyAvailableSettingUnverifiable(proxyCount: 1),
            .noProxyOnLink,
            .notAssessed(reason: "尚未探测")
        ]

        for assessment in cases {
            switch assessment {
            case .proxyAvailableSettingUnverifiable, .noProxyOnLink, .notAssessed:
                continue
            }
        }

        XCTAssertEqual(
            MacWakeOnDemandReadiness().wakeForNetworkAccessSetting,
            .undetermined,
            "「唤醒以供网络访问」当前无公开 API 可读，必须保持 undetermined 而不是伪造布尔值"
        )
    }

    func testProbeTimeoutIsBoundedAndPositive() {
        let timeout = MacWakeOnDemandReadiness.probeTimeoutSeconds
        XCTAssertGreaterThan(timeout, 0, "超时为 0 会让探测永远得不到答复即判 absent")
        XCTAssertLessThanOrEqual(
            timeout,
            10,
            "探测会阻塞诊断路径，窗口必须有界"
        )
    }

    /// Wake on Demand requires the Bonjour registration to still be live when the machine sleeps.
    /// A `willSleepNotification` handler that stops P2P advertising would silently defeat it, so
    /// the absence of one is a load-bearing invariant rather than an omission.
    func testP2PAdvertisingIsNotWithdrawnOnSleep() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")

        XCTAssertFalse(
            source.contains("willSleepNotification"),
            """
            P2P 广播不得在系统休眠时撤销：Sleep Proxy 必须接管一个仍然注册着的服务，\
            休眠前注销等于彻底废掉 Wake on Demand
            """
        )
    }

    /// The advertisement survives sleep on purpose, but the listener socket may not, so something
    /// has to reconcile after wake or the Mac comes back advertising a service that refuses
    /// connections.
    func testLocalPeerServicesAreReconciledAfterWake() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCompassApp/LocalPeerServiceCoordinator.swift"
        )

        XCTAssertTrue(source.contains("NSWorkspace.didWakeNotification"))
        XCTAssertTrue(source.contains("schedulePostWakeReconcile"))
        XCTAssertTrue(
            source.contains("postWakeReconcileDelay"),
            "唤醒后需要等待接口恢复，立即复核会误报失败"
        )
        XCTAssertTrue(
            source.contains("SkyBridgeLogger.ui.error"),
            "复核失败必须上报：活着的 Bonjour 记录背后是个连不上的监听器，正是「显示在线但连不上」的成因"
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
#endif
