import Foundation
import OSLog
import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore
import SkyBridgeRealtimeMedia

@MainActor
final class WebRTCRealtimeAudioSenderCoordinatorTests: XCTestCase {
    @available(macOS 14.0, *)
    func testMakeSenderPropagatesCancellationWithoutUnavailableDiagnostic() async throws {
        var diagnostics: [String] = []
        let coordinator = makeCoordinator(
            reusableAdmissionLease: { _ in .init(token: "cached-token", expiresIn: 60) },
            requestMediaRelayLease: { _ in
                throw CancellationError()
            },
            appendSessionDiagnostic: { line, _ in diagnostics.append(line) }
        )
        let config = RemoteDesktopStreamConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 120,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            mediaSessionId: "media-session",
            mediaAudioEndpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_560),
            compatibilityAudioFallbackEnabled: false
        )

        do {
            _ = try await coordinator.makeSenderIfNeeded(
                sessionID: "session-1",
                keys: Self.sessionKeys(),
                config: config,
                relayBindPolicy: .requireAcknowledgement,
                validateOperationOwner: Self.alwaysCurrentOperationOwner
            )
            XCTFail("Expected cancellation to propagate")
        } catch {
            // The typed-throws contract guarantees this is CancellationError.
        }

        XCTAssertFalse(diagnostics.contains { $0.contains("audioTxUnavailable") })
    }

    @available(macOS 14.0, *)
    func testReusableAdmissionLeaseRequestsRelayWithoutRefresh() async throws {
        var requestedTokens: [String] = []
        var refreshCalls = 0
        var diagnostics: [String] = []
        let coordinator = makeCoordinator(
            reusableAdmissionLease: { _ in .init(token: "cached-token", expiresIn: 60) },
            requestMediaRelayLease: { token in
                requestedTokens.append(token)
                return Self.mediaRelayLease(role: "initiator")
            },
            refreshMediaAdmissionLease: { _, _, _ in
                refreshCalls += 1
                return .init(token: "unexpected-refresh", expiresIn: 60)
            },
            appendSessionDiagnostic: { line, _ in diagnostics.append(line) }
        )

        let endpoint = try await coordinator.requestSenderEndpoint(
            sessionID: "session-1",
            validateOperationOwner: Self.alwaysCurrentOperationOwner
        )

        XCTAssertEqual(endpoint.host, "relay.test")
        XCTAssertEqual(endpoint.port, 44_000)
        XCTAssertEqual(requestedTokens, ["cached-token"])
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertTrue(diagnostics.contains { $0.contains("leaseSource=localRoleLease role=initiator") })
    }

    @available(macOS 14.0, *)
    func testRefreshableRelayFailureRefreshesAdmissionLeaseAndRetries() async throws {
        var requestedTokens: [String] = []
        var refreshedTokens: [String] = []
        var storedTokens: [String] = []
        var diagnostics: [String] = []
        let coordinator = makeCoordinator(
            reusableAdmissionLease: { _ in nil },
            storeAdmissionLease: { lease, _ in
                if let lease {
                    storedTokens.append(lease.token)
                }
            },
            requestMediaRelayLease: { token in
                requestedTokens.append(token)
                if token == "fresh-1" {
                    throw SignalServerClient.ClientError.serverRejected(
                        401,
                        "media_admission_token_expired"
                    )
                }
                return Self.mediaRelayLease(role: "responder", token: "relay-token-2")
            },
            refreshMediaAdmissionLease: { _, _, _ in
                let token = refreshedTokens.isEmpty ? "fresh-1" : "fresh-2"
                refreshedTokens.append(token)
                return .init(token: token, expiresIn: 60)
            },
            appendSessionDiagnostic: { line, _ in diagnostics.append(line) }
        )

        let endpoint = try await coordinator.requestSenderEndpoint(
            sessionID: "session-1",
            validateOperationOwner: Self.alwaysCurrentOperationOwner
        )

        XCTAssertEqual(endpoint.relayToken, "relay-token-2")
        XCTAssertEqual(refreshedTokens, ["fresh-1", "fresh-2"])
        XCTAssertEqual(storedTokens, ["fresh-1", "fresh-2"])
        XCTAssertEqual(requestedTokens, ["fresh-1", "fresh-2"])
        XCTAssertTrue(diagnostics.contains { $0.contains("leaseSource=localRoleLeaseRefreshed role=responder") })
    }

    @available(macOS 14.0, *)
    func testSessionAuthorityLostRelayFailureDoesNotRefreshAdmissionLease() async throws {
        var refreshCalls = 0
        var requestedTokens: [String] = []
        let authorityLostBody = """
        {
          "error": "media_admission_token_superseded",
          "mediaTokenRequestGeneration": "aaaa",
          "mediaTokenExpectedPresent": false,
          "mediaTokenSessionPresent": false,
          "mediaTokenState": "revoked",
          "rejectReason": "remote_kill"
        }
        """
        let coordinator = makeCoordinator(
            reusableAdmissionLease: { _ in .init(token: "stale-token", expiresIn: 60) },
            requestMediaRelayLease: { token in
                requestedTokens.append(token)
                throw SignalServerClient.ClientError.serverRejected(401, authorityLostBody)
            },
            refreshMediaAdmissionLease: { _, _, _ in
                refreshCalls += 1
                return .init(token: "unexpected-refresh", expiresIn: 60)
            }
        )

        do {
            _ = try await coordinator.requestSenderEndpoint(
                sessionID: "session-1",
                validateOperationOwner: Self.alwaysCurrentOperationOwner
            )
            XCTFail("Expected authority-lost relay rejection to fail without refresh")
        } catch SignalServerClient.ClientError.serverRejected(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("Expected serverRejected, got \(error)")
        }
        XCTAssertEqual(requestedTokens, ["stale-token"])
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertFalse(CrossNetworkConnectionManager.isMediaAdmissionLeaseRefreshable(
            SignalServerClient.ClientError.serverRejected(401, authorityLostBody)
        ))
        XCTAssertEqual(
            CrossNetworkConnectionManager.mediaAdmissionFailureReason(
                for: SignalServerClient.ClientError.serverRejected(401, authorityLostBody)
            ),
            "sessionAuthorityLost"
        )
    }

    @available(macOS 14.0, *)
    func testSupersededRelayFailureWithLiveSessionStillRefreshesAdmissionLease() {
        let liveSupersededBody = """
        {
          "error": "media_admission_token_superseded",
          "mediaTokenRequestGeneration": "aaaa",
          "mediaTokenExpectedGeneration": "bbbb",
          "mediaTokenExpectedPresent": true,
          "mediaTokenSessionPresent": true,
          "mediaTokenState": "revoked",
          "rejectReason": "media_admission_refreshed"
        }
        """
        let error = SignalServerClient.ClientError.serverRejected(401, liveSupersededBody)

        XCTAssertTrue(CrossNetworkConnectionManager.isMediaAdmissionLeaseRefreshable(error))
        XCTAssertEqual(
            CrossNetworkConnectionManager.mediaAdmissionFailureReason(for: error),
            "superseded"
        )
    }

    func testLocalNetworkPermissionFailureIsNotCollapsedIntoRelayUnavailable() {
        XCTAssertEqual(
            CrossNetworkConnectionManager.mediaAdmissionFailureReason(
                for: SkyBridgeRealtimeMediaTransportError.udpLocalNetworkPermissionDenied
            ),
            "udpLocalNetworkPermissionDenied"
        )
    }

    @available(macOS 14.0, *)
    func testRelayFailureAfterRefreshMapsSupersededToServerStateMismatch() async throws {
        var refreshedTokens: [String] = []
        var requestedTokens: [String] = []
        var diagnostics: [String] = []
        let expiredBody = #"{"error":"media_admission_token_expired"}"#
        let liveSupersededBody = """
        {
          "error": "media_admission_token_superseded",
          "mediaTokenRequestGeneration": "aaaa",
          "mediaTokenExpectedGeneration": "bbbb",
          "mediaTokenExpectedPresent": true,
          "mediaTokenSessionPresent": true,
          "mediaTokenState": "revoked",
          "rejectReason": "media_admission_refreshed"
        }
        """
        let coordinator = makeCoordinator(
            reusableAdmissionLease: { _ in nil },
            requestMediaRelayLease: { token in
                requestedTokens.append(token)
                if token == "fresh-1" {
                    throw SignalServerClient.ClientError.serverRejected(401, expiredBody)
                }
                throw SignalServerClient.ClientError.serverRejected(401, liveSupersededBody)
            },
            refreshMediaAdmissionLease: { _, _, _ in
                let token = refreshedTokens.isEmpty ? "fresh-1" : "fresh-2"
                refreshedTokens.append(token)
                return .init(token: token, expiresIn: 60)
            },
            appendSessionDiagnostic: { line, _ in diagnostics.append(line) }
        )

        do {
            _ = try await coordinator.requestSenderEndpoint(
                sessionID: "session-1",
                validateOperationOwner: Self.alwaysCurrentOperationOwner
            )
            XCTFail("Expected refreshed relay superseded rejection to fail")
        } catch let failure as WebRTCMediaAdmissionClassifiedFailure {
            XCTAssertEqual(failure.reason, "serverStateMismatch")
        } catch {
            XCTFail("Expected classified media admission failure, got \(error)")
        }
        XCTAssertEqual(refreshedTokens, ["fresh-1", "fresh-2"])
        XCTAssertEqual(requestedTokens, ["fresh-1", "fresh-2"])
        XCTAssertTrue(diagnostics.contains { $0.contains("reason=serverStateMismatch") })
        XCTAssertTrue(diagnostics.contains { $0.contains("requestGeneration=aaaa") })
        XCTAssertTrue(diagnostics.contains { $0.contains("expectedGeneration=bbbb") })
    }

    @available(macOS 14.0, *)
    func testMissingTokenOrRoleDoesNotRefreshOrRequestRelay() async throws {
        var refreshCalls = 0
        var relayRequests = 0
        let missingTokenCoordinator = makeCoordinator(
            reusableAdmissionLease: { _ in nil },
            sessionToken: { _ in "   " },
            requestMediaRelayLease: { _ in
                relayRequests += 1
                return Self.mediaRelayLease()
            },
            refreshMediaAdmissionLease: { _, _, _ in
                refreshCalls += 1
                return .init(token: "unexpected", expiresIn: 60)
            }
        )

        let missingTokenLease = try await missingTokenCoordinator.refreshAdmissionLease(
            sessionID: "session-1",
            validateOperationOwner: Self.alwaysCurrentOperationOwner
        )
        XCTAssertNil(missingTokenLease)

        let missingRoleCoordinator = makeCoordinator(
            reusableAdmissionLease: { _ in nil },
            sessionRoleName: { _ in nil },
            requestMediaRelayLease: { _ in
                relayRequests += 1
                return Self.mediaRelayLease()
            },
            refreshMediaAdmissionLease: { _, _, _ in
                refreshCalls += 1
                return .init(token: "unexpected", expiresIn: 60)
            }
        )

        let missingRoleLease = try await missingRoleCoordinator.refreshAdmissionLease(
            sessionID: "session-1",
            validateOperationOwner: Self.alwaysCurrentOperationOwner
        )
        XCTAssertNil(missingRoleLease)
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertEqual(relayRequests, 0)
    }

    @available(macOS 14.0, *)
    func testOwnerReplacementDuringAdmissionRefreshDoesNotStoreOrCreateSender() async throws {
        let ownerA = UUID()
        let ownerState = WebRTCRealtimeAudioOperationOwnerState(currentOwner: ownerA)
        let refreshGate = WebRTCRealtimeAudioSuspensionGate()
        let startCounter = WebRTCRealtimeAudioCallCounter()
        let closeCounter = WebRTCRealtimeAudioCallCounter()
        var storedTokens: [String] = []
        let coordinator = makeCoordinator(
            storeAdmissionLease: { lease, _ in
                if let lease {
                    storedTokens.append(lease.token)
                }
            },
            refreshMediaAdmissionLease: { _, _, _ in
                await refreshGate.suspend()
                return .init(token: "owner-a-token", expiresIn: 60)
            },
            startSender: { _ in await startCounter.increment() },
            closeSender: { _, _ in await closeCounter.increment() }
        )

        let refreshTask = Task { @MainActor in
            try await coordinator.makeSenderIfNeeded(
                sessionID: "session-1",
                keys: Self.sessionKeys(),
                config: Self.realtimeAudioConfiguration(),
                relayBindPolicy: .requireAcknowledgement,
                validateOperationOwner: ownerState.validator(for: ownerA)
            )
        }
        await refreshGate.waitUntilSuspended()
        ownerState.replaceCurrentOwner(with: UUID())
        await refreshGate.release()

        do {
            _ = try await refreshTask.value
            XCTFail("Expected replaced operation owner to cancel the refresh")
        } catch is CancellationError {
            // Expected exact-owner rejection.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(storedTokens, [])
        let startCount = await startCounter.value()
        let closeCount = await closeCounter.value()
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(closeCount, 0)
    }

    @available(macOS 14.0, *)
    func testCurrentOwnerStoresRefreshedAdmissionLeaseExactlyOnce() async throws {
        let ownerA = UUID()
        let ownerState = WebRTCRealtimeAudioOperationOwnerState(currentOwner: ownerA)
        var storedTokens: [String] = []
        let coordinator = makeCoordinator(
            storeAdmissionLease: { lease, _ in
                if let lease {
                    storedTokens.append(lease.token)
                }
            },
            refreshMediaAdmissionLease: { _, _, _ in
                .init(token: "owner-a-token", expiresIn: 60)
            }
        )

        let lease = try await coordinator.refreshAdmissionLease(
            sessionID: "session-1",
            validateOperationOwner: ownerState.validator(for: ownerA)
        )

        XCTAssertEqual(lease?.token, "owner-a-token")
        XCTAssertEqual(storedTokens, ["owner-a-token"])
    }

    @available(macOS 14.0, *)
    func testCancellationDuringAdmissionRefreshDoesNotStoreLease() async throws {
        let ownerA = UUID()
        let ownerState = WebRTCRealtimeAudioOperationOwnerState(currentOwner: ownerA)
        let refreshGate = WebRTCRealtimeAudioSuspensionGate()
        var storedTokens: [String] = []
        let coordinator = makeCoordinator(
            storeAdmissionLease: { lease, _ in
                if let lease {
                    storedTokens.append(lease.token)
                }
            },
            refreshMediaAdmissionLease: { _, _, _ in
                await refreshGate.suspend()
                return .init(token: "cancelled-token", expiresIn: 60)
            }
        )

        let refreshTask = Task { @MainActor in
            try await coordinator.refreshAdmissionLease(
                sessionID: "session-1",
                validateOperationOwner: ownerState.validator(for: ownerA)
            )
        }
        await refreshGate.waitUntilSuspended()
        refreshTask.cancel()
        await refreshGate.release()

        do {
            _ = try await refreshTask.value
            XCTFail("Expected task cancellation to abort the refresh")
        } catch is CancellationError {
            // Expected task cancellation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(storedTokens, [])
    }

    @available(macOS 14.0, *)
    func testOwnerReplacementAfterSenderStartClosesLocalSenderExactlyOnce() async throws {
        let ownerA = UUID()
        let ownerState = WebRTCRealtimeAudioOperationOwnerState(currentOwner: ownerA)
        let startGate = WebRTCRealtimeAudioSuspensionGate()
        let closeCounter = WebRTCRealtimeAudioCallCounter()
        let coordinator = makeCoordinator(
            reusableAdmissionLease: { _ in .init(token: "cached-token", expiresIn: 60) },
            requestMediaRelayLease: { _ in Self.mediaRelayLease() },
            startSender: { _ in await startGate.suspend() },
            closeSender: { _, _ in await closeCounter.increment() }
        )

        let senderTask = Task { @MainActor in
            try await coordinator.makeSenderIfNeeded(
                sessionID: "session-1",
                keys: Self.sessionKeys(),
                config: Self.realtimeAudioConfiguration(),
                relayBindPolicy: .requireAcknowledgement,
                validateOperationOwner: ownerState.validator(for: ownerA)
            )
        }
        await startGate.waitUntilSuspended()
        ownerState.replaceCurrentOwner(with: UUID())
        await startGate.release()

        do {
            _ = try await senderTask.value
            XCTFail("Expected stale sender operation to be cancelled")
        } catch is CancellationError {
            // Expected exact-owner rejection after sender startup suspension.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let closeCount = await closeCounter.value()
        XCTAssertEqual(closeCount, 1)
    }

    @available(macOS 14.0, *)
    private func makeCoordinator(
        reusableAdmissionLease: @escaping @MainActor (String) -> SignalServerClient.MediaAdmissionLease? = { _ in nil },
        sessionToken: @escaping @MainActor (String) -> String? = { _ in "session-token" },
        sessionRoleName: @escaping @MainActor (String) -> String? = { _ in "initiator" },
        storeAdmissionLease: @escaping @MainActor (SignalServerClient.MediaAdmissionLease?, String) -> Void = { _, _ in },
        requestMediaRelayLease: (@MainActor (String) async throws -> SignalServerClient.MediaRelayLease)? = nil,
        refreshMediaAdmissionLease: @escaping @MainActor (
            String,
            String,
            String
        ) async throws -> SignalServerClient.MediaAdmissionLease = { _, _, _ in
            .init(token: "fresh-token", expiresIn: 60)
        },
        appendSessionDiagnostic: @escaping @MainActor (String, String) -> Void = { _, _ in },
        startSender: @escaping @Sendable (RemoteRealtimeMediaAudioSender) async throws -> Void = { sender in
            try await sender.start()
        },
        closeSender: @escaping @Sendable (RemoteRealtimeMediaAudioSender, String) async -> Void = { sender, reason in
            await sender.close(reason: reason)
        }
    ) -> WebRTCRealtimeAudioSenderCoordinator {
        let resolvedRequestMediaRelayLease = requestMediaRelayLease ?? { _ in
            WebRTCRealtimeAudioSenderCoordinatorTests.mediaRelayLease()
        }
        return WebRTCRealtimeAudioSenderCoordinator(
            logger: Logger(subsystem: "com.skybridge.tests", category: "WebRTCRealtimeAudioSenderCoordinatorTests"),
            dependencies: .init(
                reusableAdmissionLease: reusableAdmissionLease,
                sessionToken: sessionToken,
                sessionRoleName: sessionRoleName,
                storeAdmissionLease: storeAdmissionLease,
                requestMediaRelayLease: resolvedRequestMediaRelayLease,
                refreshMediaAdmissionLease: refreshMediaAdmissionLease,
                appendSessionDiagnostic: appendSessionDiagnostic,
                startSender: startSender,
                closeSender: closeSender
            )
        )
    }

    @available(macOS 14.0, *)
    private static var alwaysCurrentOperationOwner:
        WebRTCRealtimeAudioSenderCoordinator.OperationOwnerValidator {
        { }
    }

    private static func realtimeAudioConfiguration() -> RemoteDesktopStreamConfiguration {
        RemoteDesktopStreamConfiguration(
            targetFrameRate: 60,
            keyFrameInterval: 120,
            lowLatencyMode: true,
            enableHardwareAcceleration: true,
            enableAppleSiliconOptimization: true,
            clipboardSyncEnabled: false,
            audioRedirectionEnabled: true,
            audioTransport: SkyBridgeRealtimeMediaConstants.audioTransportPQCv1,
            mediaSessionId: "media-session",
            mediaAudioEndpoint: SkyBridgeMediaEndpoint(host: "127.0.0.1", port: 55_560),
            compatibilityAudioFallbackEnabled: false
        )
    }

    private static func mediaRelayLease(
        role: String = "initiator",
        token: String = "relay-token"
    ) -> SignalServerClient.MediaRelayLease {
        .init(
            sessionID: "session-1",
            role: role,
            endpointHost: "relay.test",
            endpointPort: 44_000,
            leaseToken: token,
            expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970,
            ttl: 60,
            maxPacketBytes: 1_200
        )
    }

    private static func sessionKeys() -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: "session-1",
            createdAt: Date()
        )
    }
}

@MainActor
private final class WebRTCRealtimeAudioOperationOwnerState {
    private var currentOwner: UUID

    init(currentOwner: UUID) {
        self.currentOwner = currentOwner
    }

    func replaceCurrentOwner(with owner: UUID) {
        currentOwner = owner
    }

    @available(macOS 14.0, *)
    func validator(
        for expectedOwner: UUID
    ) -> WebRTCRealtimeAudioSenderCoordinator.OperationOwnerValidator {
        { [weak self] () throws(CancellationError) in
            guard self?.currentOwner == expectedOwner else {
                throw CancellationError()
            }
        }
    }
}

private actor WebRTCRealtimeAudioSuspensionGate {
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var observationContinuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            precondition(suspendedContinuation == nil)
            suspendedContinuation = continuation
            let observations = observationContinuations
            observationContinuations.removeAll(keepingCapacity: false)
            for observation in observations {
                observation.resume()
            }
        }
    }

    func waitUntilSuspended() async {
        if suspendedContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            observationContinuations.append(continuation)
        }
    }

    func release() {
        let continuation = suspendedContinuation
        suspendedContinuation = nil
        continuation?.resume()
    }
}

private actor WebRTCRealtimeAudioCallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
