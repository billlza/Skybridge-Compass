import XCTest
@testable import SkyBridgeCore

/// Guards the anti-fallback-absorption invariants.
///
/// A relay is always available and always works, so without measurement it silently becomes the
/// only route in use and the direct paths rot unnoticed. These tests pin the two properties that
/// make the degradation detectable: relayed sessions are never counted as direct, and an
/// inconclusive observation is never counted as healthy.
@available(macOS 14.0, *)
final class ConnectionRouteAttributionTests: XCTestCase {

    // MARK: - Route classification

    func testRelayedRouteIsNeverClassifiedAsDirect() {
        XCTAssertTrue(ConnectionTransportRoute.relayed.isRelayed)
        XCTAssertFalse(ConnectionTransportRoute.relayed.isDirect)
    }

    func testUnknownRouteIsNeitherDirectNorRelayed() {
        XCTAssertFalse(
            ConnectionTransportRoute.unknown.isDirect,
            "未确定的路径不得被当成直连，否则会把中继会话误记为健康"
        )
        XCTAssertFalse(ConnectionTransportRoute.unknown.isRelayed)
    }

    func testDirectRoutesAreClassifiedAsDirect() {
        XCTAssertTrue(ConnectionTransportRoute.localDirect.isDirect)
        XCTAssertTrue(ConnectionTransportRoute.peerToPeerDirect.isDirect)
        XCTAssertFalse(ConnectionTransportRoute.localDirect.isRelayed)
        XCTAssertFalse(ConnectionTransportRoute.peerToPeerDirect.isRelayed)
    }

    func testICETransportPathMapsRelayToRelayedAndDirectToPeerToPeer() {
        XCTAssertEqual(ConnectionTransportRoute(WebRTCSession.ICETransportPath.relay), .relayed)
        XCTAssertEqual(
            ConnectionTransportRoute(WebRTCSession.ICETransportPath.direct),
            .peerToPeerDirect,
            "ICE 只证明「未选中中继候选」，不得升级成更强的 NAT 穿透断言"
        )
        XCTAssertEqual(ConnectionTransportRoute(WebRTCSession.ICETransportPath.unknown), .unknown)
    }

    @MainActor
    func testWebRTCRouteSourceIsNotAttributedByThePresencePath() {
        XCTAssertNil(
            ConnectionTransportRoute(ConnectionPresenceService.PresenceRouteSource.webrtc),
            """
            WebRTC 归因归 ICE 探测所有（按 sessionID 记录）。presence 侧再记一次会让同一条\
            逻辑连接产生两行，其中一行永远无法收敛
            """
        )
        for source in [
            ConnectionPresenceService.PresenceRouteSource.inbound,
            .outbound,
            .presence,
            .compatibility
        ] {
            XCTAssertEqual(ConnectionTransportRoute(source), .localDirect)
        }
    }

    func testSessionLevelProbeOwnsWebRTCAttributionForAllSessionTypes() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )

        XCTAssertTrue(
            source.contains("private func startRouteAttributionProbeIfNeeded()"),
            "路径探测必须是会话级通用能力，不能只存在于远程桌面循环里"
        )
        XCTAssertTrue(source.contains("beginRouteAttribution(sessionID: sessionID)"))
        XCTAssertTrue(source.contains("endRouteAttribution(sessionID: sessionID)"))
        XCTAssertTrue(
            source.contains("endAllRouteAttribution()"),
            "全量断开必须清理归因行，否则会残留已结束会话"
        )
        XCTAssertTrue(
            source.contains("guard !sessions.isEmpty else { return }"),
            "无会话时探测必须退出，空闲进程不得常驻定时器"
        )
        XCTAssertTrue(
            source.contains("StableICETransportPathState()"),
            "必须复用既有稳定化状态机，瞬时 unknown 探测不得擦掉已确定的归因"
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

    // MARK: - Relay budget

    func testRelayedShareIsNilBelowMinimumSampleCount() {
        let minimum = ConnectionRouteAttributionRecorder.budgetMinimumSampleCount
        let routes = Array(repeating: ConnectionTransportRoute.relayed, count: minimum - 1)

        XCTAssertNil(
            ConnectionRouteAttributionRecorder.relayedShare(in: routes),
            "样本不足时必须返回 nil（证据不足），调用方不得把它读成健康"
        )
        XCTAssertFalse(
            ConnectionRouteAttributionRecorder.isOverRelayBudget(routes),
            "证据不足不应触发告警，避免噪声"
        )
    }

    func testUnknownSamplesDoNotDiluteRelayedShare() {
        let routes: [ConnectionTransportRoute] = [
            .relayed, .relayed, .relayed, .relayed,
            .unknown, .unknown, .unknown, .unknown, .unknown, .unknown
        ]

        XCTAssertEqual(
            ConnectionRouteAttributionRecorder.relayedShare(in: routes),
            1.0,
            "未确定样本会稀释占比，从而掩盖一个完全依赖中继的部署"
        )
        XCTAssertTrue(ConnectionRouteAttributionRecorder.isOverRelayBudget(routes))
    }

    func testAllDirectDeploymentIsWithinBudget() {
        let routes = Array(repeating: ConnectionTransportRoute.peerToPeerDirect, count: 8)

        XCTAssertEqual(ConnectionRouteAttributionRecorder.relayedShare(in: routes), 0)
        XCTAssertFalse(ConnectionRouteAttributionRecorder.isOverRelayBudget(routes))
    }

    func testBudgetTriggersOnlyAboveThreshold() {
        let threshold = ConnectionRouteAttributionRecorder.relayedShareWarningThreshold
        XCTAssertEqual(threshold, 0.5)

        // Exactly at the threshold is not a violation; the check is strictly greater-than.
        let atThreshold: [ConnectionTransportRoute] = [.relayed, .relayed, .localDirect, .localDirect]
        XCTAssertEqual(ConnectionRouteAttributionRecorder.relayedShare(in: atThreshold), 0.5)
        XCTAssertFalse(ConnectionRouteAttributionRecorder.isOverRelayBudget(atThreshold))

        let overThreshold: [ConnectionTransportRoute] = [
            .relayed, .relayed, .relayed, .localDirect
        ]
        XCTAssertEqual(ConnectionRouteAttributionRecorder.relayedShare(in: overThreshold), 0.75)
        XCTAssertTrue(ConnectionRouteAttributionRecorder.isOverRelayBudget(overThreshold))
    }

    // MARK: - Recorder behaviour

    @MainActor
    func testRecorderRefinesUnknownRouteAndTracksBudgetState() {
        let recorder = ConnectionRouteAttributionRecorder()
        let session = "peer-under-test"

        recorder.record(sessionKey: session, route: .unknown)
        XCTAssertEqual(recorder.attributionsBySessionKey[session]?.route, .unknown)
        XCTAssertEqual(
            recorder.conclusiveSampleCount,
            0,
            "未确定观测不得进入预算窗口"
        )

        recorder.record(sessionKey: session, route: .relayed)
        XCTAssertEqual(recorder.attributionsBySessionKey[session]?.route, .relayed)
        XCTAssertEqual(recorder.conclusiveSampleCount, 1)

        // Repeated identical probes must not inflate the window; the ICE probe runs every 2 s.
        recorder.record(sessionKey: session, route: .relayed)
        XCTAssertEqual(
            recorder.conclusiveSampleCount,
            1,
            "同一路径的重复探测不得反复计入预算，否则单条会话就能触发告警"
        )
    }

    @MainActor
    func testRecorderLatchesOverBudgetStateAndRecovers() {
        let recorder = ConnectionRouteAttributionRecorder()

        for index in 0..<4 {
            recorder.record(sessionKey: "relayed-\(index)", route: .relayed)
        }
        XCTAssertTrue(recorder.isOverRelayBudget)
        XCTAssertEqual(recorder.relayedShare, 1.0)

        for index in 0..<8 {
            recorder.record(sessionKey: "direct-\(index)", route: .localDirect)
        }
        XCTAssertFalse(
            recorder.isOverRelayBudget,
            "直连恢复后预算状态必须回落，否则告警会永久粘住并被忽略"
        )
    }

    @MainActor
    func testForgettingSessionKeepsBudgetSampleSoDegradationStaysVisible() {
        let recorder = ConnectionRouteAttributionRecorder()

        for index in 0..<4 {
            recorder.record(sessionKey: "relayed-\(index)", route: .relayed)
        }
        for index in 0..<4 {
            recorder.forget(sessionKey: "relayed-\(index)")
        }

        XCTAssertTrue(recorder.attributionsBySessionKey.isEmpty)
        XCTAssertEqual(
            recorder.conclusiveSampleCount,
            4,
            "会话结束不得清空预算窗口，否则短会话为主的部署永远测不出中继占比"
        )
        XCTAssertTrue(recorder.isOverRelayBudget)
    }

    @MainActor
    func testBudgetWindowIsBounded() {
        let recorder = ConnectionRouteAttributionRecorder()
        let windowSize = ConnectionRouteAttributionRecorder.budgetWindowSize

        for index in 0..<(windowSize * 3) {
            recorder.record(sessionKey: "session-\(index)", route: .localDirect)
        }

        XCTAssertEqual(
            recorder.conclusiveSampleCount,
            windowSize,
            "预算窗口必须有界，否则长时间运行会无界增长"
        )
    }

    @MainActor
    func testEmptySessionKeyIsRejectedRatherThanRecordedUnderABlankKey() {
        let recorder = ConnectionRouteAttributionRecorder()

        recorder.record(sessionKey: "   ", route: .relayed)

        XCTAssertTrue(recorder.attributionsBySessionKey.isEmpty)
        XCTAssertEqual(recorder.conclusiveSampleCount, 0)
    }
}
