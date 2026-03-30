import XCTest
@testable import SkyBridgeCore

final class NebulaIdentityAndConnectionPresentationTests: XCTestCase {
    func testAuthSessionDecodesWithoutNebulaIdFromLegacyPayload() throws {
        let data = """
        {
          "accessToken": "token",
          "refreshToken": "refresh",
          "userIdentifier": "user-1",
          "displayName": "Tester",
          "issuedAt": "2026-03-15T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AuthSession.self, from: data)

        XCTAssertNil(session.nebulaId)
        XCTAssertEqual(session.userIdentifier, "user-1")
    }

    func testDisplayedNebulaIdPrefersResolvedThenSessionThenCanonicalUserIdentifier() {
        XCTAssertEqual(
            NebulaIdentityContract.displayedNebulaId(
                resolvedNebulaId: "NEBULA-2026-AAA",
                sessionNebulaId: "NEBULA-2026-BBB",
                sessionUserIdentifier: "NEBULA-2026-CCC"
            ),
            "NEBULA-2026-AAA"
        )

        XCTAssertEqual(
            NebulaIdentityContract.displayedNebulaId(
                resolvedNebulaId: nil,
                sessionNebulaId: "NEBULA-2026-BBB",
                sessionUserIdentifier: "NEBULA-2026-CCC"
            ),
            "NEBULA-2026-BBB"
        )

        XCTAssertEqual(
            NebulaIdentityContract.displayedNebulaId(
                resolvedNebulaId: nil,
                sessionNebulaId: nil,
                sessionUserIdentifier: "NEBULA-2026-CCC"
            ),
            "NEBULA-2026-CCC"
        )
    }

    func testNebulaIdentityPhaseBecomesDeferredWhenConfigurationArrivesLate() {
        XCTAssertEqual(
            NebulaIdentityContract.recommendedPhase(
                accessToken: "supabase.jwt.token",
                isSupabaseSession: true,
                isSupabaseConfigured: false,
                resolvedNebulaId: nil,
                sessionNebulaId: nil
            ),
            .deferred
        )

        XCTAssertEqual(
            NebulaIdentityContract.recommendedPhase(
                accessToken: "supabase.jwt.token",
                isSupabaseSession: true,
                isSupabaseConfigured: true,
                resolvedNebulaId: nil,
                sessionNebulaId: nil
            ),
            .loading
        )

        XCTAssertEqual(
            NebulaIdentityContract.recommendedPhase(
                accessToken: "supabase.jwt.token",
                isSupabaseSession: true,
                isSupabaseConfigured: true,
                resolvedNebulaId: "NEBULA-2026-AAA",
                sessionNebulaId: nil
            ),
            .hydrated
        )
    }

    func testAsyncNebulaIdentityResultIsIgnoredAfterAccountSwitchOrLogout() {
        XCTAssertFalse(
            NebulaIdentityContract.shouldApplyAsyncResult(
                expectedGeneration: 1,
                currentGeneration: 2,
                expectedSessionKey: "user-a|token-a",
                currentSessionKey: "user-b|token-b"
            )
        )

        XCTAssertFalse(
            NebulaIdentityContract.shouldApplyAsyncResult(
                expectedGeneration: 3,
                currentGeneration: 3,
                expectedSessionKey: "user-a|token-a",
                currentSessionKey: nil
            )
        )

        XCTAssertTrue(
            NebulaIdentityContract.shouldApplyAsyncResult(
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedSessionKey: "user-a|token-a",
                currentSessionKey: "user-a|token-a"
            )
        )
    }

    func testTopConnectionPresentationPrefersPeerThenCrossNetworkThenFallbacks() {
        let now = Date(timeIntervalSince1970: 1_742_000_000)
        let labels = ConnectionPresentationLabels(
            connectedText: "已连接",
            disconnectedText: "未连接",
            connectingText: "连接中",
            reconnectingText: "重连中",
            defaultGuardStatus: "守护中",
            crossNetworkGuardStatus: "跨网已连接"
        )

        let peerPresentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: ConnectionPresentationPeer(
                    displayName: "Peer",
                    cryptoKind: nil,
                    suite: "X25519",
                    guardStatus: "守护中",
                    connectedAt: now
                ),
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    sessionId: "session-1",
                    source: .code,
                    phase: .transportReady,
                    deviceId: "peer-2",
                    deviceName: "Remote Device",
                    negotiatedSuite: "ML-KEM-768",
                    updatedAt: now
                ),
                defaultPQCModeLabel: "Apple PQC",
                compatibilityModeEnabled: false
            )
        )
        XCTAssertEqual(peerPresentation.phase, .connected)
        XCTAssertEqual(peerPresentation.statusText, "Classic已连接")

        let crossNetworkPresentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    snapshotToken: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    sessionId: "session-2",
                    source: .qr,
                    phase: .transportReady,
                    deviceId: "peer-3",
                    deviceName: "Mac mini",
                    negotiatedSuite: "ML-KEM-768",
                    updatedAt: now
                ),
                defaultPQCModeLabel: "Apple PQC",
                compatibilityModeEnabled: false
            )
        )
        XCTAssertEqual(crossNetworkPresentation.phase, .connected)
        XCTAssertEqual(crossNetworkPresentation.statusText, "Apple PQC已连接")
        XCTAssertEqual(crossNetworkPresentation.detailText, "Apple PQC · ML-KEM-768 · 跨网已连接")

        let transferFallbackPresentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: true,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: nil,
                defaultPQCModeLabel: nil,
                compatibilityModeEnabled: false
            )
        )
        XCTAssertEqual(transferFallbackPresentation.phase, .connected)
        XCTAssertEqual(transferFallbackPresentation.statusText, "已连接")
    }

    func testReconnectWindowAndLateCleanupDoNotDeleteNewSnapshot() {
        let originalToken = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let replacementToken = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let reconnecting = ActiveSessionSnapshotContract.disconnect(
            current: ActiveSessionSnapshot(
                snapshotToken: originalToken,
                sessionId: "session-1",
                source: .code,
                phase: .transportReady,
                deviceId: "peer-1",
                deviceName: "Peer A",
                negotiatedSuite: "X25519"
            ),
            sessionId: "session-1",
            snapshotToken: originalToken,
            kind: .transient
        )
        XCTAssertEqual(reconnecting?.phase, .reconnecting)

        let newerSnapshot = ActiveSessionSnapshotContract.activate(
            sessionId: "session-1",
            source: .reused,
            phase: .handshakeComplete,
            deviceId: "peer-1",
            deviceName: "Peer A",
            negotiatedSuite: "X-Wing",
            snapshotToken: replacementToken
        )

        let afterLateCleanup = ActiveSessionSnapshotContract.disconnect(
            current: newerSnapshot,
            sessionId: "session-1",
            snapshotToken: originalToken,
            kind: .explicit
        )
        XCTAssertEqual(afterLateCleanup, newerSnapshot)
    }

    func testCrossNetworkFallbackPresentationKeepsMacStatusResponsiveWhenSnapshotMissing() {
        let labels = ConnectionPresentationLabels(
            connectedText: "已连接",
            disconnectedText: "未连接",
            connectingText: "连接中",
            reconnectingText: "重连中",
            defaultGuardStatus: "守护中",
            crossNetworkGuardStatus: "跨网已连接"
        )

        let fallbackConnected = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: nil,
                crossNetworkFallback: ActiveSessionSnapshot(
                    sessionId: "session-fallback",
                    source: .reused,
                    phase: .transportReady,
                    deviceId: nil,
                    deviceName: "Mac mini",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC",
                compatibilityModeEnabled: false
            )
        )

        XCTAssertEqual(fallbackConnected.phase, .connected)
        XCTAssertEqual(fallbackConnected.statusText, "Apple PQC已连接")
        XCTAssertEqual(fallbackConnected.detailText, "Apple PQC · ML-KEM-768 · 跨网已连接")

        let fallbackConnecting = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: nil,
                crossNetworkFallback: ActiveSessionSnapshot(
                    sessionId: "session-connecting",
                    source: .reused,
                    phase: .connecting,
                    deviceId: nil,
                    deviceName: "Remote Device",
                    negotiatedSuite: nil
                ),
                defaultPQCModeLabel: nil,
                compatibilityModeEnabled: false
            )
        )

        XCTAssertEqual(fallbackConnecting.phase, .connecting)
        XCTAssertEqual(fallbackConnecting.statusText, "连接中")
        XCTAssertEqual(fallbackConnecting.detailText, "Remote Device")
    }

    func testCrossNetworkSnapshotUsesDegradedDisplayStateWhenSignalingIsDegraded() {
        let labels = ConnectionPresentationLabels(
            connectedText: "已连接",
            disconnectedText: "未连接",
            connectingText: "连接中",
            reconnectingText: "重连中",
            defaultGuardStatus: "守护中",
            crossNetworkGuardStatus: "跨网已连接"
        )

        let degradedPresentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    sessionId: "session-degraded",
                    source: .qr,
                    phase: .handshakeComplete,
                    deviceId: "peer-1",
                    deviceName: "Mac mini",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC",
                compatibilityModeEnabled: false,
                signalingHealth: .degradedFatal
            )
        )

        XCTAssertEqual(degradedPresentation.phase, .connected)
        XCTAssertEqual(degradedPresentation.displayState, .connectedDegradedSignaling)
        XCTAssertEqual(degradedPresentation.statusText, "Apple PQC已连接")
        XCTAssertTrue(degradedPresentation.detailText?.contains("信令降级") == true)
    }

    func testCrossNetworkSnapshotKeepsHealthyDisplayStateWhenSignalingIsRecoverablyDegraded() {
        let labels = ConnectionPresentationLabels(
            connectedText: "已连接",
            disconnectedText: "未连接",
            connectingText: "连接中",
            reconnectingText: "重连中",
            defaultGuardStatus: "守护中",
            crossNetworkGuardStatus: "跨网已连接"
        )

        let presentation = ConnectionPresentationContract.evaluate(
            ConnectionPresentationInput(
                labels: labels,
                fileTransferActive: false,
                latestPeerConnection: nil,
                latestConnectedDevice: nil,
                activeSessionSnapshot: ActiveSessionSnapshot(
                    sessionId: "session-recoverable",
                    source: .qr,
                    phase: .handshakeComplete,
                    deviceId: "peer-2",
                    deviceName: "Mac Studio",
                    negotiatedSuite: "ML-KEM-768"
                ),
                defaultPQCModeLabel: "Apple PQC",
                compatibilityModeEnabled: false,
                signalingHealth: .degradedRecoverable
            )
        )

        XCTAssertEqual(presentation.phase, .connected)
        XCTAssertNotEqual(presentation.displayState, .connectedDegradedSignaling)
        XCTAssertFalse(presentation.detailText?.contains("信令降级") == true)
    }
}
