import XCTest
@testable import SkyBridgeCore

final class RemoteDesktopSessionTerminationPolicyTests: XCTestCase {
    func testRemoteLeaveIsNormalForVisibleSession() {
        XCTAssertEqual(
            RemoteDesktopSessionTerminationPolicy.notificationKind(
                disconnectKind: .remoteLeave,
                reason: "remote_leave",
                hadUserVisibleSession: true
            ),
            .normal
        )
    }

    func testTransientDisconnectIsInterruptedForVisibleSession() {
        XCTAssertEqual(
            RemoteDesktopSessionTerminationPolicy.notificationKind(
                disconnectKind: .transient,
                reason: "remote_heartbeat_timeout",
                hadUserVisibleSession: true
            ),
            .interrupted
        )
    }

    func testExplicitStrictFailureIsInterrupted() {
        XCTAssertEqual(
            RemoteDesktopSessionTerminationPolicy.notificationKind(
                disconnectKind: .explicit,
                reason: "strict_media_validation_failed_audio_missing",
                hadUserVisibleSession: true
            ),
            .interrupted
        )
    }

    func testP2PSupersededSessionIsNormalTermination() {
        XCTAssertEqual(
            RemoteDesktopSessionTerminationPolicy.notificationKind(
                disconnectKind: .explicit,
                reason: "p2p_superseded_by_new_session",
                hadUserVisibleSession: true
            ),
            .normal
        )
    }

    func testRemoteControlPeerReplacementNotifiesBeforeCancelingOldVisibleSession() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let body = try sourceSlice(
            in: source,
            from: "private func replacePeerSessionIfNeeded(",
            to: "    @available(macOS 14.0, *)\n    private func recordSOAState"
        )

        try assertOrder(
            in: body,
            first: "notifyRemoteControlTerminalSessionIfNeeded(",
            second: "previousPeer.connection.cancel()"
        )
        XCTAssertTrue(body.contains("reason: \"p2p_superseded_by_new_session\""))
        XCTAssertTrue(body.contains("RemoteControlSecurityNoticeCenter.shared.endNotice"))
    }

    func testInternalCleanupDoesNotNotifyBeforeSessionIsVisible() {
        XCTAssertNil(
            RemoteDesktopSessionTerminationPolicy.notificationKind(
                disconnectKind: .explicit,
                reason: "replace_stale_answerer_session",
                hadUserVisibleSession: false
            )
        )
    }

    func testNotificationDedupeKeyIncludesRole() {
        let controlling = RemoteDesktopSessionTerminationPolicy.notificationDedupeKey(
            sessionID: "Shared-Peer",
            transport: "P2P",
            role: "controlling"
        )
        let beingControlled = RemoteDesktopSessionTerminationPolicy.notificationDedupeKey(
            sessionID: "shared-peer",
            transport: "p2p",
            role: "beingControlled"
        )

        XCTAssertNotEqual(controlling, beingControlled)
        XCTAssertEqual(controlling, "p2p|controlling|shared-peer")
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSlice(in source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw XCTSkip("Source markers not found")
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func assertOrder(in source: String, first: String, second: String) throws {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            XCTFail("Expected markers not found: \(first) / \(second)")
            return
        }
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
    }
}
