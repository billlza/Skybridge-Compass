import XCTest

final class IOSRemoteDesktopNotificationContractTests: XCTestCase {
    func testIOSRemoteDesktopTerminalNotificationsAreRegisteredAndDedupedBySessionRole() throws {
        let notificationSupport = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Notifications/AppNotificationSupport.swift"
        )
        let app = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/SkyBridgeCompassApp.swift"
        )

        XCTAssertTrue(notificationSupport.contains("enum RemoteDesktopTerminalNotificationKind: String, Sendable"))
        XCTAssertTrue(notificationSupport.contains("case normal"))
        XCTAssertTrue(notificationSupport.contains("case interrupted"))
        XCTAssertTrue(notificationSupport.contains("static let remoteDesktopSessionCategoryIdentifier = \"REMOTE_DESKTOP_SESSION\""))
        XCTAssertTrue(notificationSupport.contains("sentRemoteDesktopTerminalNotificationKeys.remove("))
        XCTAssertTrue(notificationSupport.contains("guard sentRemoteDesktopTerminalNotificationKeys.insert(key).inserted else { return }"))
        XCTAssertTrue(notificationSupport.contains("\"terminalKind\": kind.rawValue"))
        XCTAssertTrue(notificationSupport.contains("identifier: \"remote-desktop-\\(key)\""))
        XCTAssertTrue(notificationSupport.contains("remoteDesktop.notification.ended.title"))
        XCTAssertTrue(notificationSupport.contains("remoteDesktop.notification.interrupted.title"))
        XCTAssertTrue(notificationSupport.contains("(role ?? \"session\").trimmingCharacters"))
        XCTAssertTrue(app.contains("NotificationManager.remoteDesktopSessionCategoryIdentifier"))
    }

    func testIOSWebRTCAndLANRemoteDesktopTerminalNotificationsHaveNormalAndInterruptedPaths() throws {
        let crossNetwork = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let remoteDesktop = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"
        )

        XCTAssertTrue(crossNetwork.contains("private func beginRemoteDesktopNotificationTracking(sessionId: String)"))
        XCTAssertTrue(crossNetwork.contains("NotificationManager.beginRemoteDesktopSession(\n            sessionId: sessionId,\n            transport: \"webrtc\""))
        XCTAssertTrue(crossNetwork.contains("guard hasUserVisibleRemoteDesktopSession(sessionId: sessionId) else { return }"))
        XCTAssertTrue(crossNetwork.contains("public func notifyRemoteDesktopInterruptedForActiveSession(reason: String) async"))
        XCTAssertTrue(crossNetwork.contains("notificationKind: .normal,\n                reason: \"explicit_disconnect\""))
        XCTAssertTrue(crossNetwork.contains("reason: \"remote_peer_timeout\""))
        XCTAssertTrue(crossNetwork.contains("reason: \"transport_disconnected:\\(reason)\""))
        XCTAssertTrue(crossNetwork.contains("reason: \"strict_pqc_bootstrap_failed\""))
        XCTAssertTrue(crossNetwork.contains("expectedSessionObjectIdentifier: ObjectIdentifier(session)"))

        XCTAssertTrue(remoteDesktop.contains("NotificationManager.beginRemoteDesktopSession(\n                sessionId: refreshedLANDevice.id,\n                transport: \"lan\",\n                role: \"viewer\""))
        XCTAssertTrue(remoteDesktop.contains("kind: .normal,\n                reason: \"viewer_disconnect_transport\""))
        XCTAssertTrue(remoteDesktop.contains("kind: .interrupted,\n                reason: errorMessage"))
        XCTAssertTrue(remoteDesktop.contains("_ = await crossNetwork.notifyRemoteDesktopInterruptedIfCurrent("))
        XCTAssertTrue(remoteDesktop.contains("crossNetworkOwner,\n                reason: errorMessage"))
    }

    func testIOSWebRTCTerminalSessionTerminationOwnsLifecycleBeforeNotifying() throws {
        let crossNetwork = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )

        assertContainsInOrder(crossNetwork, [
            "private func terminateRemoteDesktopSession(",
            "guard let expectedIncarnation = sessionIncarnation(",
            "await disconnectInternal(",
            "originatingReceiveLoop: originatingReceiveLoop",
            "terminalFailureMessage: terminalFailureMessage",
            "expectedIncarnation: expectedIncarnation",
            "terminalNotification: DisconnectTerminalNotification("
        ])
        assertContainsInOrder(crossNetwork, [
            "guard let teardownLease = lifecycleGate.beginTeardown() else",
            "defer {",
            "enqueueTerminalNotification(deferredTerminalNotification)",
            "lifecycleGate.finishTeardown(teardownLease)",
            "advanceSessionLifecycleEpoch()",
            "activeSessionIncarnation = nil",
            "currentSessionId = nil",
            "if let terminalNotification",
            "applyActiveSessionDisconnect(",
            "deferredTerminalNotification = DeferredTerminalNotification("
        ])
        assertContainsInOrder(crossNetwork, [
            "case .leave:",
            "switch envelopeLifecycleWitness",
            "case .incarnation(let incarnation):",
            "await terminateRemoteDesktopSession(",
            "expectedSessionObjectIdentifier: incarnation.sessionObjectIdentifier",
            "disconnectKind: .remoteLeave",
            "notificationKind: .normal",
            "reason: \"remote_leave\""
        ])
        assertContainsInOrder(crossNetwork, [
            "private func recordSessionAuthorityLost(sessionId: String, reason: String)",
            "await self.terminateRemoteDesktopSession(",
            "expectedSessionObjectIdentifier: expectedSessionObjectIdentifier",
            "disconnectKind: .transient",
            "notificationKind: .interrupted",
            "reason: \"session_authority_lost:\\(reason)\""
        ])
        XCTAssertTrue(crossNetwork.contains("reason: \"initial_handshake_failed:\\(reason)\""))
        XCTAssertTrue(crossNetwork.contains("reason: \"initial_handshake_failed:\\(keys.negotiatedSuite.rawValue)\""))
        XCTAssertTrue(crossNetwork.contains("reason: \"strict_pqc_rekey_failed:\\(reason)\""))
        XCTAssertTrue(crossNetwork.contains("reason: \"strict_pqc_rekey_failed:\\(error.localizedDescription)\""))
    }

    func testIOSRemoteDesktopNotificationLocalizationsExistForAllSupportedLanguages() throws {
        for locale in ["en", "zh-Hans", "ja"] {
            let strings = try repositorySource(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/\(locale).lproj/Localizable.strings"
            )
            XCTAssertTrue(strings.contains("\"remoteDesktop.notification.ended.title\""))
            XCTAssertTrue(strings.contains("\"remoteDesktop.notification.ended.body\""))
            XCTAssertTrue(strings.contains("\"remoteDesktop.notification.ended.bodyWithDevice\""))
            XCTAssertTrue(strings.contains("\"remoteDesktop.notification.interrupted.title\""))
            XCTAssertTrue(strings.contains("\"remoteDesktop.notification.interrupted.body\""))
            XCTAssertTrue(strings.contains("\"remoteDesktop.notification.interrupted.bodyWithDevice\""))
        }
    }

    private func assertContainsInOrder(
        _ source: String,
        _ needles: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchRange = source.startIndex..<source.endIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: searchRange) else {
                XCTFail("Missing ordered source fragment: \(needle)", file: file, line: line)
                return
            }
            searchRange = range.upperBound..<source.endIndex
        }
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
