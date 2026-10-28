import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class AuthenticationAudioStartupOrderTests: XCTestCase {
    func testMissingRefreshCredentialDoesNotRevokeRestoredAudioAuthority() async throws {
        try await withIsolatedSession { service in
            try await restoreFixture(service)
            let authorization = try service.currentAudioAuthorization()
            do { _ = try await service.validAccessToken(forceRefresh: true); XCTFail("Missing refresh credential accepted") }
            catch {
                guard case AuthenticationService.AuthenticationError.refreshCredentialUnavailable = error else {
                    XCTFail("Local credential absence lost its distinct error: \(error)"); throw error
                }
            }
            XCTAssertTrue(authorization.isCurrent)
            XCTAssertTrue(try service.currentAudioAuthorization() === authorization)
            XCTAssertEqual(service.currentSessionSnapshot(), fixtureSession)
            let loaded = try await KeychainManager.shared.loadAuthSessionRecordStrict()
            let record = try XCTUnwrap(loaded)
            XCTAssertFalse(record.audioRevoked)
            XCTAssertEqual(record.loginID, authorization.loginID)
        }
    }

    func testFirstProviderSelectionAfterRestoreRevokesThePublishedAccount() async throws {
        try await withIsolatedSession { service in
            try await restoreFixture(service)
            let restored = try service.currentAudioAuthorization()

            service.enableSupabaseMode(supabaseConfig: try configuration("late-provider"))

            XCTAssertFalse(restored.isCurrent)
            XCTAssertNil(service.audioAuthorizationSnapshot)
            XCTAssertEqual(service.currentSessionSnapshot(), fixtureSession)
            XCTAssertThrowsError(try service.currentAudioAuthorization()) {
                XCTAssertEqual($0 as? AudioMembershipLeaseFailure, .accountChanged)
            }
        }
    }

    func testProviderSelectionBeforeRestoreSurvivesTheRootUISelectingTheSameProvider() async throws {
        try await withIsolatedSession { service in
            let provider = try configuration("initial-provider")
            service.enableSupabaseMode(supabaseConfig: provider)
            try await restoreFixture(service)
            let restored = try service.currentAudioAuthorization()

            service.enableSupabaseMode(supabaseConfig: provider)

            XCTAssertTrue(restored.isCurrent)
            XCTAssertTrue(try service.currentAudioAuthorization() === restored)
            XCTAssertEqual(service.currentSessionSnapshot(), fixtureSession)
        }
    }

    func testPersistedRejectionRestoresSessionWithoutAudioAuthority() async throws {
        try await withIsolatedSession { service in
            let stored = try await KeychainManager.shared.storeAuthSession(fixtureSession)
            try await KeychainManager.shared.revokeAudioAuthorization(expected: fixtureSession,
                loginID: XCTUnwrap(stored.loginID), intent: AuthenticationMutationIntent())
            service.reloadPersistedSessionIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while service.currentSessionSnapshot() == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(service.currentSessionSnapshot(), fixtureSession)
            XCTAssertNil(service.audioAuthorizationSnapshot)
            XCTAssertThrowsError(try service.currentAudioAuthorization())
        }
    }

    func testInterruptedCredentialObservationCannotPublishRestoredAudioAuthority() async throws {
        try await withIsolatedSession { service in
            let keychain = KeychainManager.shared
            let stored = try await keychain.storeAuthSession(fixtureSession)
            let ticket = try await keychain.beginAccountObservation(kind: .credential,
                expected: fixtureSession, loginID: XCTUnwrap(stored.loginID), intent: AuthenticationMutationIntent())
            await keychain.abandonAccountObservation(ticket)
            service.reloadPersistedSessionIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while service.currentSessionSnapshot() == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(service.currentSessionSnapshot(), fixtureSession)
            XCTAssertNil(service.audioAuthorizationSnapshot)
            let record = try await keychain.loadAuthSessionRecordStrict()
            XCTAssertEqual(record?.loginID, stored.loginID)
            XCTAssertEqual(record?.observations, [ticket.observation])
            XCTAssertEqual(record?.requiresCredentialVerification, true)
        }
    }

    private var fixtureSession: AuthSession {
        AuthSession(accessToken: "audio-startup-fixture-token", refreshToken: nil,
                    userIdentifier: "audio-startup-fixture-user", displayName: "Audio startup fixture",
                    issuedAt: Date(timeIntervalSince1970: 0))
    }

    private func configuration(_ name: String) throws -> SupabaseService.Configuration {
        SupabaseService.Configuration(url: try XCTUnwrap(URL(string: "https://example.invalid")), anonKey: name)
    }

    private func restoreFixture(_ service: AuthenticationService) async throws {
        let session = fixtureSession
        let stored = try await KeychainManager.shared.storeAuthSession(session)
        service.reloadPersistedSessionIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.currentSessionSnapshot() == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.currentSessionSnapshot(), session)
        XCTAssertEqual(try service.currentAudioAuthorization().loginID, stored.loginID)
    }

    private func withIsolatedSession(
        _ operation: (AuthenticationService) async throws -> Void
    ) async throws {
        // XCTest selects the existing in-memory Keychain backend. Guest transition
        // clears it locally; no test token is sent to a logout or refresh endpoint.
        let service = AuthenticationService.shared
        try await clearWithoutNetwork(service)
        let result: Result<Void, Error>
        do {
            try await operation(service)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        try await clearWithoutNetwork(service)
        try result.get()
    }

    private func clearWithoutNetwork(_ service: AuthenticationService) async throws {
        try await service.activateGuestSession()
        let outcome = await service.signOutAndWait()
        XCTAssertEqual(outcome, .localOnly)
    }
}
