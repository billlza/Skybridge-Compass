import Foundation
import OSLog
import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

@MainActor
final class WebRTCRealtimeAudioSenderCoordinatorTests: XCTestCase {
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

        let endpoint = try await coordinator.requestSenderEndpoint(sessionID: "session-1")

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

        let endpoint = try await coordinator.requestSenderEndpoint(sessionID: "session-1")

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
            _ = try await coordinator.requestSenderEndpoint(sessionID: "session-1")
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
            _ = try await coordinator.requestSenderEndpoint(sessionID: "session-1")
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

        let missingTokenLease = try await missingTokenCoordinator.refreshAdmissionLease(sessionID: "session-1")
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

        let missingRoleLease = try await missingRoleCoordinator.refreshAdmissionLease(sessionID: "session-1")
        XCTAssertNil(missingRoleLease)
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertEqual(relayRequests, 0)
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
        appendSessionDiagnostic: @escaping @MainActor (String, String) -> Void = { _, _ in }
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
                appendSessionDiagnostic: appendSessionDiagnostic
            )
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
}
