import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

final class RemoteControlScreenSharingStartupPolicyTests: XCTestCase {
    func testSharedRealtimeMediaStartupErrorsHaveStableRoleNeutralCodes() {
        XCTAssertEqual(
            RemoteControlRealtimeMediaStartupError
                .missingAuthenticatedMediaSessionKeys.stableCode,
            "missing_authenticated_media_session_keys"
        )
        XCTAssertEqual(
            RemoteControlRealtimeMediaStartupError
                .missingAuthenticatedMediaAudioEndpoint.stableCode,
            "missing_authenticated_media_audio_endpoint"
        )
        XCTAssertEqual(
            RemoteControlRealtimeMediaStartupError.relayLeaseUnavailable.stableCode,
            "relay_lease_unavailable"
        )
        XCTAssertEqual(
            RemoteControlRealtimeMediaStartupError.transportUnavailable.stableCode,
            "transport_unavailable"
        )
    }

    func testInitialDecisionStartsImmediatelyWhenViewerConfigurationExists() {
        let decision = RemoteControlScreenSharingStartupPolicy.decision(
            hasInitialStreamConfiguration: true
        )

        XCTAssertEqual(decision, .startImmediately)
    }

    func testInitialDecisionWaitsForAuthenticatedViewerConfigurationWithoutFallback() {
        let decision = RemoteControlScreenSharingStartupPolicy.decision(
            hasInitialStreamConfiguration: false
        )

        XCTAssertEqual(decision, .awaitViewerConfiguration)
    }

    func testAttemptGateInvalidatesStaleScreenSharingStarts() {
        var gate = RemoteControlScreenSharingAttemptGate()

        let firstAttempt = gate.beginAttempt(for: "peer-1")
        let secondAttempt = gate.beginAttempt(for: "peer-1")

        XCTAssertFalse(gate.isCurrentAttempt(firstAttempt, for: "peer-1"))
        XCTAssertTrue(gate.isCurrentAttempt(secondAttempt, for: "peer-1"))

        gate.invalidateAttempts(for: "peer-1")

        XCTAssertFalse(gate.isCurrentAttempt(secondAttempt, for: "peer-1"))
    }

    func testAttemptGateSuppressesDuplicateStartWhileCurrentStartIsInFlight() {
        var gate = RemoteControlScreenSharingAttemptGate()

        let firstAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(firstAttempt)
        XCTAssertNil(gate.beginAttemptIfIdle(for: "peer-1"))

        if let firstAttempt {
            gate.finishAttempt(firstAttempt, for: "peer-1")
        }

        let secondAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(secondAttempt)
        XCTAssertNotEqual(firstAttempt, secondAttempt)
    }

    func testAttemptGateAllowsFreshStartAfterInvalidatingInFlightStart() {
        var gate = RemoteControlScreenSharingAttemptGate()

        let firstAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(firstAttempt)

        gate.invalidateAttempts(for: "peer-1")

        let secondAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(secondAttempt)
        XCTAssertNotEqual(firstAttempt, secondAttempt)
    }

    func testAttemptGateSerializesSupersededStartAndRestartsLatestOnce() {
        var gate = RemoteControlScreenSharingAttemptGate()

        let firstAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(firstAttempt)
        XCTAssertTrue(
            gate.supersedeInFlightAttemptAndRequestRestart(for: "peer-1")
        )
        if let firstAttempt {
            XCTAssertFalse(gate.isCurrentAttempt(firstAttempt, for: "peer-1"))
        }
        XCTAssertNil(
            gate.beginAttemptIfIdle(for: "peer-1"),
            "The replacement must wait for the retiring attempt instead of starting concurrently."
        )

        let shouldRestartLatest = firstAttempt.map {
            gate.finishAttempt($0, for: "peer-1")
        }
        XCTAssertEqual(shouldRestartLatest, true)

        let replacement = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(replacement)
        if let replacement {
            XCTAssertFalse(gate.finishAttempt(replacement, for: "peer-1"))
        }
    }

    func testManagerWiresLatestConfigurationIntoSerializedReplacementStart() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                ".supersedeInFlightAttemptAndRequestRestart(for: peer.id)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "let shouldRestartLatest = screenSharingAttemptGate.finishAttempt("
            )
        )
        XCTAssertTrue(source.contains("if shouldRestartLatest {"))
        XCTAssertTrue(
            source.contains("await self.startScreenSharing(to: peer)")
        )
        XCTAssertTrue(
            source.contains(
                "guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else"
            )
        )
    }

    func testManagerRequiresAcknowledgementBeforePublishingOrStartingStream() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"
            ),
            encoding: .utf8
        )
        let pumpSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteControl/RemoteControlOutboundFramePump.swift"
            ),
            encoding: .utf8
        )

        let applyStart = try XCTUnwrap(
            managerSource.range(of: "private func applyViewerStreamConfiguration(")
        )
        let ackSend = try XCTUnwrap(
            managerSource.range(
                of: "guard try await sendStreamConfigurationAcknowledgement(",
                range: applyStart.upperBound..<managerSource.endIndex
            )
        )
        let publish = try XCTUnwrap(
            managerSource.range(
                of: "peer.lastAcceptedRawStreamConfiguration = config",
                range: ackSend.upperBound..<managerSource.endIndex
            )
        )
        XCTAssertLessThan(ackSend.lowerBound, publish.lowerBound)
        XCTAssertTrue(
            managerSource.contains(
                "guard let acknowledgedConfiguration = peer.requestedStreamConfiguration else"
            )
        )
        XCTAssertFalse(managerSource.contains("scheduleDeferredScreenSharingFallback"))
        XCTAssertTrue(pumpSource.contains("private var streamingEnabled = false"))
        XCTAssertTrue(
            pumpSource.contains(
                "streamingEnabled = requestedStreamConfiguration.map { !$0.isStopRequest } ?? false"
            )
        )
    }

    func testManagerRevalidatesExactAttemptAfterCaptureAndCleanupSuspensions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"
            ),
            encoding: .utf8
        )

        let videoStart = try XCTUnwrap(source.range(of: "try await streamer.start("))
        let audioStart = try XCTUnwrap(
            source.range(
                of: "if let realtimeAudioCaptureStreamerForAttempt {",
                range: videoStart.upperBound..<source.endIndex
            )
        )
        let postVideoStart = String(source[videoStart.lowerBound..<audioStart.lowerBound])
        XCTAssertTrue(
            postVideoStart.contains(
                "guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else"
            )
        )

        let senderClose = try XCTUnwrap(
            source.range(of: "await realtimeAudioSender.close(reason: \"screen-sharing-start-failed\")")
        )
        let retry = try XCTUnwrap(
            source.range(
                of: "if !scheduleScreenSharingStartupRetry(",
                range: senderClose.upperBound..<source.endIndex
            )
        )
        let postClose = String(source[senderClose.lowerBound..<retry.lowerBound])
        XCTAssertTrue(
            postClose.contains(
                "guard isCurrentScreenSharingAttempt(attemptGeneration, for: peer) else"
            )
        )
        XCTAssertFalse(postClose.contains("guard isCurrentPeer(peer) else"))
    }

    func testRequestedStrictRealtimeAudioFailsClosedWhenSenderStartupFails() {
        XCTAssertEqual(
            RemoteControlRealtimeMediaStartupPolicy.failureAction(
                strictMediaFallbacks: true,
                audioRedirectionEnabled: true,
                realtimeMediaAudioRequested: true,
                legacyAudioFallbackEnabled: false
            ),
            .failSession
        )
    }

    func testNonStrictOrExplicitLegacyAudioCanPreserveVideoAfterSenderFailure() {
        let cases: [(Bool, Bool, Bool, Bool)] = [
            (false, true, true, false),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, true),
        ]
        for entry in cases {
            XCTAssertEqual(
                RemoteControlRealtimeMediaStartupPolicy.failureAction(
                    strictMediaFallbacks: entry.0,
                    audioRedirectionEnabled: entry.1,
                    realtimeMediaAudioRequested: entry.2,
                    legacyAudioFallbackEnabled: entry.3
                ),
                .preserveVideo
            )
        }
    }

    func testLocalNetworkPermissionFailureHasStableActionableReason() {
        XCTAssertEqual(
            SkyBridgeRealtimeMediaTransportError.udpLocalNetworkPermissionDenied.stableCode,
            "udp_local_network_permission_denied"
        )
        XCTAssertEqual(
            SkyBridgeRealtimeMediaTransportError.udpListenerMissingBoundPort.stableCode,
            "udp_listener_missing_bound_port"
        )
        XCTAssertEqual(
            SkyBridgeRealtimeMediaTransportError.udpListenerReadyTimedOut.stableCode,
            "udp_listener_ready_timed_out"
        )
    }

    func testSharedFallbackPolicyRecognizesStrictWireValues() {
        for fallbackPolicy in ["fail-fast", "disabled", "forbidden"] {
            XCTAssertTrue(
                RemoteControlRealtimeMediaStartupPolicy.forbidsFallback(
                    performanceValidationMode: nil,
                    mediaFallbackPolicy: fallbackPolicy
                )
            )
        }
        XCTAssertTrue(
            RemoteControlRealtimeMediaStartupPolicy.forbidsFallback(
                performanceValidationMode: "extreme",
                mediaFallbackPolicy: nil
            )
        )
        XCTAssertFalse(
            RemoteControlRealtimeMediaStartupPolicy.forbidsFallback(
                performanceValidationMode: nil,
                mediaFallbackPolicy: nil
            )
        )
    }
}
