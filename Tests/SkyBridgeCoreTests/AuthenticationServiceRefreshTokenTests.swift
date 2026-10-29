import XCTest
import Network
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class AuthenticationServiceRefreshTokenTests: XCTestCase {
    func testMergedRefreshTokenPrefersNonEmptyCandidate() {
        XCTAssertEqual(
            AuthenticationService.mergedRefreshToken(" new-token ", fallback: "old-token"),
            "new-token"
        )
    }

    func testMergedRefreshTokenFallsBackWhenCandidateMissing() {
        XCTAssertEqual(
            AuthenticationService.mergedRefreshToken(nil, fallback: " old-token "),
            "old-token"
        )
        XCTAssertEqual(
            AuthenticationService.mergedRefreshToken("   ", fallback: "old-token"),
            "old-token"
        )
    }

    func testMergedRefreshTokenReturnsNilWhenBothMissing() {
        XCTAssertNil(AuthenticationService.mergedRefreshToken(nil, fallback: nil))
        XCTAssertNil(AuthenticationService.mergedRefreshToken(" ", fallback: " "))
    }

    func testDecodeAppleIdentityTokenReturnsRawJWTString() {
        let token = "header.payload.signature"
        let data = Data(token.utf8)

        XCTAssertEqual(AuthenticationService.decodeAppleIdentityToken(data), token)
    }

    func testDecodeAppleIdentityTokenRejectsBinaryPayload() {
        let data = Data([0xFF, 0x00, 0x80, 0x7F])

        XCTAssertNil(AuthenticationService.decodeAppleIdentityToken(data))
    }

    func testSupabaseRefreshAccessTokenDeduplicatesConcurrentRefreshRequests() async throws {
        let server = try await RefreshTokenHTTPTestServer(accessTokenProvider: { "" })
        defer { server.stop() }
        let baseURL = server.baseURL
        server.updateAccessTokenProvider {
            Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: 3600)
        }

        await MainActor.run {
            SupabaseService.shared.updateConfiguration(.init(url: baseURL, anonKey: "anon-key"))
        }

        async let first = SupabaseService.shared.refreshAccessToken("refresh-token")
        async let second = SupabaseService.shared.refreshAccessToken("refresh-token")
        async let third = SupabaseService.shared.refreshAccessToken("refresh-token")
        let sessions = try await [first, second, third]

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(Set(sessions.map(\.accessToken)).count, 1)

        let lateSession = try await SupabaseService.shared.refreshAccessToken("refresh-token")
        XCTAssertEqual(lateSession.accessToken, sessions[0].accessToken)
        XCTAssertEqual(server.requestCount, 1)

        _ = try await SupabaseService.shared.refreshAccessToken("refresh-token-next")
        XCTAssertEqual(server.requestCount, 2)
    }

    func testAuthenticationServiceValidAccessTokenDeduplicatesConcurrentRefreshRequests() async throws {
        let server = try await RefreshTokenHTTPTestServer(accessTokenProvider: { "" })
        defer { server.stop() }
        let baseURL = server.baseURL
        server.updateAccessTokenProvider {
            Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: 3600)
        }

        await MainActor.run {
            SupabaseService.shared.updateConfiguration(.init(url: baseURL, anonKey: "anon-key"))
        }
        _ = await AuthenticationService.shared.signOutAndWait()
        try await AuthenticationService.shared.updateSession(
            AuthSession(
                accessToken: Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: -3600),
                refreshToken: "refresh-token",
                userIdentifier: "user-1",
                nebulaId: "NEBULA-1",
                displayName: "UITest User",
                avatarURL: nil,
                issuedAt: .distantPast
            )
        )
        defer {
            Task { @MainActor in
                _ = await AuthenticationService.shared.signOutAndWait()
            }
        }

        async let first = AuthenticationService.shared.validAccessToken()
        async let second = AuthenticationService.shared.validAccessToken()
        async let third = AuthenticationService.shared.validAccessToken()
        let tokens = try await [first, second, third]

        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(Set(tokens.compactMap { $0 }).count, 1)
    }

    func testSessionSwitchCannotBeOverwrittenByStaleAccessTokenRefresh() async throws {
        let server = try await RefreshTokenHTTPTestServer(
            accessTokenProvider: { "" },
            blockResponses: true
        )
        defer { server.stop() }
        let baseURL = server.baseURL
        server.updateAccessTokenProvider {
            Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: 3600)
        }
        SupabaseService.shared.updateConfiguration(.init(url: baseURL, anonKey: "anon-key"))

        let service = AuthenticationService.shared
        _ = await service.signOutAndWait()
        let sourceSession = AuthSession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: -3600
            ),
            refreshToken: "refresh-token-a",
            userIdentifier: "user-1",
            nebulaId: "NEBULA-1",
            displayName: "User A",
            issuedAt: .distantPast
        )
        try await service.updateSession(sourceSession)
        let refresh = Task { try await service.validAccessToken() }
        try await waitForRequestCount(1, server: server)

        let replacementSession = AuthSession(
            accessToken: "replacement-access-token",
            refreshToken: "replacement-refresh-token",
            userIdentifier: "user-2",
            nebulaId: "NEBULA-2",
            displayName: "User B",
            issuedAt: Date()
        )
        let replacement = Task {
            try await service.updateSession(replacementSession)
        }
        try await waitForAuthenticationState(
            replacementSession,
            service: service
        )
        try await replacement.value
        XCTAssertEqual(server.requestCount, 1)
        server.releaseResponses()

        assertStaleRefreshRejected(await refresh.result)
        XCTAssertEqual(service.currentSessionSnapshot(), replacementSession)
        let persistedReplacement = try await KeychainManager.shared.loadAuthSessionStrict()
        XCTAssertEqual(persistedReplacement, replacementSession)

        try await service.activateGuestSession()
        _ = await service.signOutAndWait()
    }

    func testSignOutCannotBeUndoneByStaleAccessTokenRefresh() async throws {
        let server = try await RefreshTokenHTTPTestServer(
            accessTokenProvider: { "" },
            blockResponses: true
        )
        defer { server.stop() }
        let baseURL = server.baseURL
        server.updateAccessTokenProvider {
            Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: 3600)
        }
        SupabaseService.shared.updateConfiguration(.init(url: baseURL, anonKey: "anon-key"))

        let service = AuthenticationService.shared
        _ = await service.signOutAndWait()
        try await service.updateSession(
            AuthSession(
                accessToken: Self.makeSupabaseAccessToken(
                    baseURL: baseURL,
                    expirationOffset: -3600
                ),
                refreshToken: "refresh-token-a",
                userIdentifier: "user-1",
                nebulaId: "NEBULA-1",
                displayName: "User A",
                issuedAt: .distantPast
            )
        )
        let refresh = Task { try await service.validAccessToken() }
        try await waitForRequestCount(1, server: server)

        let signOut = Task { await service.signOutAndWait() }
        try await waitForAuthenticationState(nil, service: service)
        XCTAssertEqual(server.requestCount, 1)
        server.releaseResponses()
        _ = await signOut.value

        assertStaleRefreshRejected(await refresh.result)
        XCTAssertNil(service.currentSessionSnapshot())
        let persistedAfterSignOut = try await KeychainManager.shared.loadAuthSessionStrict()
        XCTAssertNil(persistedAfterSignOut)
    }

    func testSessionSwitchThenSignOutCannotBeUndoneByEarlierRefresh() async throws {
        let server = try await RefreshTokenHTTPTestServer(
            accessTokenProvider: { "" },
            blockResponses: true
        )
        defer { server.stop() }
        let baseURL = server.baseURL
        server.updateAccessTokenProvider {
            Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: 3_600)
        }
        SupabaseService.shared.updateConfiguration(.init(url: baseURL, anonKey: "anon-key"))

        let service = AuthenticationService.shared
        _ = await service.signOutAndWait()
        let sourceSession = AuthSession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: -3_600
            ),
            refreshToken: "refresh-token-a",
            userIdentifier: "user-1",
            nebulaId: "NEBULA-1",
            displayName: "User A",
            issuedAt: .distantPast
        )
        try await service.updateSession(sourceSession)
        let refresh = Task { try await service.validAccessToken() }
        try await waitForRequestCount(1, server: server)

        let replacementSession = AuthSession(
            accessToken: "pending_verification",
            refreshToken: nil,
            userIdentifier: "user-2",
            nebulaId: "NEBULA-2",
            displayName: "User B",
            issuedAt: Date()
        )
        try await service.updateSession(replacementSession)
        try await waitForAuthenticationState(replacementSession, service: service)

        let signOut = Task { await service.signOutAndWait() }
        try await waitForAuthenticationState(nil, service: service)
        _ = await signOut.value
        XCTAssertEqual(server.requestCount, 1)

        server.releaseResponses()
        assertStaleRefreshRejected(await refresh.result)
        XCTAssertNil(service.currentSessionSnapshot())
        let persistedAfterSignOut = try await KeychainManager.shared.loadAuthSessionStrict()
        XCTAssertNil(persistedAfterSignOut)
    }

    func testKeychainAuthSessionReplacementIsExactCompareAndSwap() async throws {
        let keychain = KeychainManager.shared
        let source = AuthSession(
            accessToken: "source-access-token",
            refreshToken: "source-refresh-token",
            userIdentifier: "source-user",
            displayName: "Source",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let replacement = AuthSession(
            accessToken: "replacement-access-token",
            refreshToken: "replacement-refresh-token",
            userIdentifier: "source-user",
            displayName: "Replacement",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_011)
        )
        let issuedAtDriftedReplacement = AuthSession(
            accessToken: replacement.accessToken,
            refreshToken: replacement.refreshToken,
            userIdentifier: "source-user",
            displayName: "Replacement",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_012)
        )
        let tokenDriftedReplacement = AuthSession(
            accessToken: "different-access-token",
            refreshToken: "different-refresh-token",
            userIdentifier: "source-user",
            displayName: "Replacement",
            issuedAt: replacement.issuedAt
        )
        let installed = try await keychain.storeAuthSession(source)
        let loginID = try XCTUnwrap(installed.loginID)

        let firstReplacement = try await keychain.replaceAuthSession(
            expected: source, expectedLoginID: loginID,
            with: replacement
        )
        let exactReplay = try await keychain.replaceAuthSession(
            expected: source, expectedLoginID: loginID,
            with: replacement
        )
        let issuedAtDriftResult = try await keychain.replaceAuthSession(
            expected: source, expectedLoginID: loginID,
            with: issuedAtDriftedReplacement
        )
        let tokenDriftResult = try await keychain.replaceAuthSession(
            expected: source, expectedLoginID: loginID,
            with: tokenDriftedReplacement
        )
        XCTAssertTrue(firstReplacement)
        XCTAssertTrue(exactReplay)
        XCTAssertFalse(issuedAtDriftResult)
        XCTAssertFalse(tokenDriftResult)
        let persisted = try await keychain.loadAuthSessionStrict()
        XCTAssertEqual(persisted, replacement)
        try await keychain.deleteAuthSession()
    }

    func testIdenticalCredentialReloginRejectsOldRefreshWitness() async throws {
        let keychain = KeychainManager.shared
        let source = AuthSession(accessToken: "fixture-identical-token", refreshToken: nil,
            userIdentifier: "fixture-identical-user", displayName: "Fixture", issuedAt: .distantPast)
        let first = try await keychain.storeAuthSession(source)
        let second = try await keychain.storeAuthSession(source)
        XCTAssertNotEqual(first.loginID, second.loginID)
        let accepted = try await keychain.replaceAuthSession(expected: source,
            expectedLoginID: XCTUnwrap(first.loginID), with: source)
        XCTAssertFalse(accepted)
        let after = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(after, second)
        try await keychain.deleteAuthSession()
    }

    func testNativeCheckpointWritePreservesCredentialRefreshAndRejectsStaleAudioWitness() async throws {
        let keychain = KeychainManager.shared
        let source = AuthSession(accessToken: "fixture-audio-token", refreshToken: nil,
            userIdentifier: "fixture-audio-user", displayName: "Fixture", issuedAt: .distantPast)
        let refreshed = AuthSession(accessToken: "fixture-audio-refreshed-token", refreshToken: nil,
            userIdentifier: source.userIdentifier, displayName: source.displayName, issuedAt: .distantPast)
        let installed = try await keychain.storeAuthSession(source)
        let loginID = try XCTUnwrap(installed.loginID)
        let intent = AuthenticationMutationIntent()
        let witness = try await keychain.loadAudioMembershipCheckpoint(loginID: loginID, intent: intent)
        let refreshedSuccessfully = try await keychain.replaceAuthSession(expected: source,
            expectedLoginID: loginID, with: refreshed)
        XCTAssertTrue(refreshedSuccessfully)
        let saved = try await keychain.saveAudioMembershipCheckpoint(Data("fixture-checkpoint".utf8),
            replacing: witness.revision, loginID: loginID, intent: intent)
        let record = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(record?.session, refreshed)
        XCTAssertEqual(record?.audioRevision, saved.revision)
        XCTAssertEqual(record?.audioCheckpoint, saved.checkpoint)
        do {
            _ = try await keychain.saveAudioMembershipCheckpoint(nil, replacing: witness.revision,
                loginID: loginID, intent: intent)
            XCTFail("Stale audio revision overwrote a newer checkpoint")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        let after = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(after, record)
        try await keychain.deleteAuthSession()
    }

    func testNativeCheckpointAccessRejectsInvalidatedIntentAndNewLogin() async throws {
        let keychain = KeychainManager.shared
        let source = AuthSession(accessToken: "fixture-audio-owner", refreshToken: nil,
            userIdentifier: "fixture-audio-owner-user", displayName: "Fixture", issuedAt: .distantPast)
        let installed = try await keychain.storeAuthSession(source)
        let loginID = try XCTUnwrap(installed.loginID)
        let intent = AuthenticationMutationIntent()
        let witness = try await keychain.loadAudioMembershipCheckpoint(loginID: loginID, intent: intent)
        intent.invalidate()
        do { _ = try await keychain.loadAudioMembershipCheckpoint(loginID: loginID, intent: intent); XCTFail("Old intent read") }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        do {
            _ = try await keychain.saveAudioMembershipCheckpoint(nil, replacing: witness.revision,
                loginID: loginID, intent: intent)
            XCTFail("Old intent wrote")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        let replacement = try await keychain.storeAuthSession(source)
        do {
            _ = try await keychain.saveAudioMembershipCheckpoint(nil, replacing: witness.revision,
                loginID: loginID, intent: AuthenticationMutationIntent())
            XCTFail("Old login wrote")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        let after = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(after, replacement)
        try await keychain.deleteAuthSession()
    }

    func testNewNativeOwnerCannotRestoreOrOverwriteAnUnresolvedRequest() async throws {
        let keychain = KeychainManager.shared
        let source = AuthSession(accessToken: "fixture-journal-token", refreshToken: nil,
            userIdentifier: "fixture-journal-user", displayName: "Fixture", issuedAt: .distantPast)
        let installed = try await keychain.storeAuthSession(source)
        let loginID = try XCTUnwrap(installed.loginID), firstIntent = AuthenticationMutationIntent()
        let checkpoint = try await keychain.saveAudioMembershipCheckpoint(Data("prior-checkpoint".utf8),
            replacing: installed.audioRevision, loginID: loginID, intent: firstIntent)
        let earlier = try await keychain.beginAccountObservation(kind: .devices, expected: source,
            loginID: loginID, intent: firstIntent)
        let ownRead = try await keychain.loadAudioMembershipCheckpoint(loginID: loginID, intent: firstIntent)
        XCTAssertEqual(ownRead, checkpoint)

        let nextIntent = AuthenticationMutationIntent()
        do {
            _ = try await keychain.loadAudioMembershipCheckpoint(loginID: loginID, intent: nextIntent)
            XCTFail("New owner restored an unresolved checkpoint")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .verificationRequired) }
        do {
            _ = try await keychain.saveAudioMembershipCheckpoint(nil, replacing: checkpoint.revision,
                loginID: loginID, intent: nextIntent)
            XCTFail("New owner wrote over an unresolved checkpoint")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .verificationRequired) }

        let fresh = try await keychain.beginAccountObservation(kind: .devices, expected: source,
            loginID: loginID, intent: nextIntent)
        let prepared = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(prepared?.loginID, loginID)
        XCTAssertNil(prepared?.audioCheckpoint)
        XCTAssertEqual(prepared?.observations, [fresh.observation])
        do {
            _ = try await keychain.finishAccountObservation(earlier)
            XCTFail("Earlier request settled a replacement's marker")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        let afterLateResult = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(afterLateResult, prepared)
        let settled = try await keychain.finishAccountObservation(fresh)
        XCTAssertTrue(settled.observations.isEmpty)
        XCTAssertEqual(settled.loginID, loginID)
        XCTAssertNil(settled.audioCheckpoint)
        try await keychain.deleteAuthSession()
    }

    func testCredentialObservationIsStoredBeforeHTTPAndPreservesTheDeviceRequest() async throws {
        let server = try await RefreshTokenHTTPTestServer(accessTokenProvider: { "" }, blockResponses: true)
        defer { server.releaseResponses(); server.stop() }
        let baseURL = server.baseURL
        server.updateAccessTokenProvider { Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: 3600) }
        SupabaseService.shared.updateConfiguration(.init(url: baseURL, anonKey: "fixture-key"))
        let service = AuthenticationService.shared, keychain = KeychainManager.shared
        try await service.activateGuestSession()
        _ = await service.signOutAndWait()
        let source = AuthSession(accessToken: Self.makeSupabaseAccessToken(baseURL: baseURL, expirationOffset: -3600),
            refreshToken: "fixture-prepared-refresh", userIdentifier: "user-1", displayName: "Fixture", issuedAt: .distantPast)
        try await service.updateSession(source)
        let authorization = try service.currentAudioAuthorization()
        let device = try await service.beginAudioMembershipObservation(for: authorization)
        let refresh = Task { try await service.validAccessToken() }
        try await waitForRequestCount(1, server: server)
        let pending = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(pending?.observations.filter { $0.kind == .credential }.count, 1)
        XCTAssertEqual(pending?.observations.filter { $0.kind == .devices }.count, 1)
        XCTAssertEqual(pending?.session, source)
        XCTAssertTrue(authorization.isCurrent)
        server.releaseResponses()
        _ = try await refresh.value
        let refreshed = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(refreshed?.observations.map(\.kind), [.devices])
        XCTAssertEqual(refreshed?.loginID, authorization.loginID)
        XCTAssertEqual(refreshed?.audioRevision, pending?.audioRevision)
        _ = try await device.finish(refreshed?.audioRevision, .unchanged)
        await device.abandon()
        let settled = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(settled?.observations, [])
        XCTAssertTrue(try service.currentAudioAuthorization() === authorization)
        try await service.activateGuestSession()
        let cleanup = await service.signOutAndWait()
        XCTAssertEqual(cleanup, .localOnly)
    }

    func testCanonicalLoadRetriesLeftoverLegacyRetirementWithoutChangingLogin() async throws {
        let keychain = KeychainManager.shared
        let legacyService = "com.skybridge.compass.authsession"
        let source = AuthSession(accessToken: "fixture-retirement-token", refreshToken: nil,
            userIdentifier: "fixture-retirement-user", displayName: "Fixture", issuedAt: .distantPast)
        let legacyBytes = try JSONEncoder().encode(source)
        // XCTest and the command's explicit environment select the existing
        // in-memory backend. This is the state left after a canonical commit
        // succeeds but retiring its old legacy record is interrupted/fails.
        defer {
            do { try keychain.deleteAPIKey(service: legacyService, account: "primary") }
            catch { XCTFail("Synthetic legacy cleanup failed: \(error)") }
        }
        _ = try await keychain.storeAuthSession(source)
        for cleared in [false, true] {
            if cleared { try await keychain.deleteAuthSession() }
            let expected = try await keychain.loadAuthSessionRecordStrict()
            XCTAssertTrue(keychain.importKey(data: legacyBytes, service: legacyService, account: "primary"))
            XCTAssertEqual(try keychain.exportKeyStrict(service: legacyService, account: "primary"), legacyBytes)
            let restored = try await keychain.loadAuthSessionRecordStrict()
            XCTAssertEqual(restored, expected, "Retirement must preserve the canonical record and login")
            XCTAssertNil(try keychain.exportKeyStrict(service: legacyService, account: "primary"),
                         "Legacy retirement was not retried; cleared=\(cleared)")
        }
        try await keychain.deleteAuthSession()
    }

    func testInvalidatedIntentCannotInstallClearOrRevoke() async throws {
        let keychain = KeychainManager.shared
        let source = AuthSession(accessToken: "fixture-intent-token", refreshToken: nil,
            userIdentifier: "fixture-intent-user", displayName: "Fixture", issuedAt: .distantPast)
        let current = try await keychain.storeAuthSession(source)
        let intent = AuthenticationMutationIntent(); intent.invalidate()
        for action in 0..<3 {
            do {
                switch action {
                case 0: _ = try await keychain.storeAuthSession(source, intent: intent)
                case 1: try await keychain.deleteAuthSession(intent: intent)
                default: try await keychain.revokeAudioAuthorization(expected: source,
                    loginID: XCTUnwrap(current.loginID), intent: intent)
                }
                XCTFail("Stale intent performed mutation \(action)")
            } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        }
        let after = try await keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(after, current)
        try await keychain.deleteAuthSession()
    }

    func testKnownRefreshRejectionPersistsAudioRevocation() async throws {
        let server = try await RefreshTokenHTTPTestServer(accessTokenProvider: { "unused" },
            failure: (status: 400, code: "session_expired"))
        defer { server.stop() }
        SupabaseService.shared.updateConfiguration(.init(url: server.baseURL, anonKey: "fixture-key"))
        let service = AuthenticationService.shared
        try await service.activateGuestSession()
        _ = await service.signOutAndWait()
        let source = AuthSession(accessToken: Self.makeSupabaseAccessToken(baseURL: server.baseURL, expirationOffset: -3600),
            refreshToken: "fixture-rejected-refresh", userIdentifier: "user-1", displayName: "Fixture", issuedAt: .distantPast)
        try await service.updateSession(source)
        let authorization = try service.currentAudioAuthorization()
        do { _ = try await service.validAccessToken(); XCTFail("Known rejection was accepted") }
        catch {
            guard case let SupabaseService.SupabaseError.httpStatus(status, _) = error else {
                XCTFail("Original HTTP failure was lost: \(error)"); throw error
            }
            XCTAssertEqual(status, 400)
        }
        XCTAssertFalse(authorization.isCurrent)
        XCTAssertNil(service.audioAuthorizationSnapshot)
        let loaded = try await KeychainManager.shared.loadAuthSessionRecordStrict()
        let record = try XCTUnwrap(loaded)
        XCTAssertEqual(record.loginID, authorization.loginID)
        XCTAssertTrue(record.audioRevoked)
        XCTAssertNil(record.audioCheckpoint)
        XCTAssertEqual(server.requestCount, 1)
        try await service.activateGuestSession()
        let cleanup = await service.signOutAndWait()
        XCTAssertEqual(cleanup, .localOnly)
    }

    func testGuestSessionDeletionCannotDeleteFollowingAuthenticatedSession() async throws {
        let service = AuthenticationService.shared
        _ = await service.signOutAndWait()
        try await service.activateGuestSession()

        let authenticatedSession = AuthSession(
            accessToken: "authenticated-access-token",
            refreshToken: "authenticated-refresh-token",
            userIdentifier: "authenticated-user",
            displayName: "Authenticated User",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        try await service.updateSession(authenticatedSession)

        let persistedSession = try await KeychainManager.shared.loadAuthSessionStrict()
        XCTAssertEqual(persistedSession, authenticatedSession)

        // Keep cleanup local. The synthetic token is intentionally not a real
        // revocable server session, so asking sign-out to contact production
        // services would turn this unit test into a fixed network-timeout test.
        try await service.activateGuestSession()
        _ = await service.signOutAndWait()
        let sessionAfterSignOut = try await KeychainManager.shared.loadAuthSessionStrict()
        XCTAssertNil(sessionAfterSignOut)
    }

    func testRefreshIdentityContinuityRejectsMalformedJWT() {
        let source = makeRefreshContinuitySession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: URL(string: "https://auth.example.test")!,
                expirationOffset: -3_600
            )
        )
        let refreshed = makeRefreshContinuitySession(accessToken: "not.a-valid.jwt")

        assertRefreshIdentityContinuityRejected(refreshed, replacing: source)
    }

    func testRefreshIdentityContinuityRejectsMissingSubject() {
        let baseURL = URL(string: "https://auth.example.test")!
        let source = makeRefreshContinuitySession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: -3_600
            )
        )
        let refreshed = makeRefreshContinuitySession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: 3_600,
                subject: nil
            )
        )

        assertRefreshIdentityContinuityRejected(refreshed, replacing: source)
    }

    func testRefreshIdentityContinuityRejectsTenantDriftWithoutSessionTenantFallback() {
        let baseURL = URL(string: "https://auth.example.test")!
        let source = makeRefreshContinuitySession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: -3_600,
                tenantID: "tenant-a"
            ),
            nebulaID: nil
        )
        let refreshed = makeRefreshContinuitySession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: 3_600,
                tenantID: "tenant-b"
            ),
            nebulaID: nil
        )

        assertRefreshIdentityContinuityRejected(refreshed, replacing: source)
    }

    func testRefreshIdentityContinuityUsesSubjectWhenBusinessNebulaIdIsPresent() throws {
        let baseURL = URL(string: "https://auth.example.test")!
        let source = makeRefreshContinuitySession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: -3_600,
                tenantID: nil
            ),
            nebulaID: "NEBULA-business-a"
        )
        let refreshed = makeRefreshContinuitySession(
            accessToken: Self.makeSupabaseAccessToken(
                baseURL: baseURL,
                expirationOffset: 3_600,
                tenantID: nil
            ),
            nebulaID: "NEBULA-business-b"
        )

        XCTAssertNoThrow(
            try AuthenticationService.validateRefreshedIdentity(
                refreshed,
                sourceSession: source,
                requiresProviderJWTContinuity: true
            )
        )
    }

    private func makeRefreshContinuitySession(
        accessToken: String,
        nebulaID: String? = "NEBULA-1"
    ) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            userIdentifier: "user-1",
            nebulaId: nebulaID,
            displayName: "User",
            issuedAt: .distantPast
        )
    }

    private func assertRefreshIdentityContinuityRejected(
        _ refreshed: AuthSession,
        replacing source: AuthSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AuthenticationService.validateRefreshedIdentity(
                refreshed,
                sourceSession: source,
                requiresProviderJWTContinuity: true
            ),
            file: file,
            line: line
        ) { error in
            guard case AuthenticationService.AuthenticationError
                .sessionChangedDuringRefresh = error else {
                XCTFail("Unexpected refresh-continuity error: \(error)", file: file, line: line)
                return
            }
        }
    }

    private nonisolated static func makeSupabaseAccessToken(
        baseURL: URL,
        expirationOffset: TimeInterval,
        subject: String? = "user-1",
        tenantID: String? = "NEBULA-1"
    ) -> String {
        let header = ["alg": "HS256", "typ": "JWT"]
        var payload: [String: Any] = [
            "iss": baseURL.appendingPathComponent("auth/v1").absoluteString,
            "exp": Int(Date().addingTimeInterval(expirationOffset).timeIntervalSince1970)
        ]
        if let subject {
            payload["sub"] = subject
        }
        if let tenantID {
            payload["app_metadata"] = ["tenant_id": tenantID]
        }
        return [
            base64URLEncodeJSONObject(header),
            base64URLEncodeJSONObject(payload),
            "signature"
        ].joined(separator: ".")
    }

    private nonisolated static func base64URLEncodeJSONObject(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        server: RefreshTokenHTTPTestServer
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while server.requestCount < expectedCount {
            guard clock.now < deadline else {
                throw RefreshTokenTestError.timedOutWaitingForRequest
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForAuthenticationState(
        _ expected: AuthSession?,
        service: AuthenticationService
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            let persisted = try await KeychainManager.shared.loadAuthSessionStrict()
            if service.currentSessionSnapshot() == expected, persisted == expected {
                return
            }
            guard clock.now < deadline else {
                throw RefreshTokenTestError.timedOutWaitingForAuthenticationState
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertStaleRefreshRejected(
        _ result: Result<String?, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("A stale refresh unexpectedly succeeded", file: file, line: line)
        case .failure(is CancellationError):
            break
        case .failure(AuthenticationService.AuthenticationError.sessionChangedDuringRefresh):
            break
        case .failure(let error):
            XCTFail("Unexpected stale-refresh error: \(error)", file: file, line: line)
        }
    }
}

private enum RefreshTokenTestError: Error {
    case timedOutWaitingForRequest
    case timedOutWaitingForAuthenticationState
}

private final class RefreshTokenHTTPTestServer: @unchecked Sendable {
    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private let continuation: CheckedContinuation<Void, Error>

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<Void, Error>) {
            lock.lock()
            guard !resumed else {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    private let queue = DispatchQueue(label: "AuthenticationServiceRefreshTokenTests.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _requestCount = 0
    private var _boundPort: UInt16 = 0
    private var _responsesReleased: Bool
    private var accessTokenProvider: @Sendable () -> String
    private let responseGate: DispatchGroup?
    private let failureStatus: Int?
    private let failureBody: Data?

    init(
        accessTokenProvider: @escaping @Sendable () -> String,
        blockResponses: Bool = false,
        failure: (status: Int, code: String)? = nil
    ) async throws {
        failureStatus = failure?.status
        failureBody = try failure.map { try JSONSerialization.data(withJSONObject: ["error_code": $0.code]) }
        self.accessTokenProvider = accessTokenProvider
        self._responsesReleased = !blockResponses
        if blockResponses {
            let gate = DispatchGroup()
            gate.enter()
            self.responseGate = gate
        } else {
            self.responseGate = nil
        }
        try await start()
    }

    var baseURL: URL {
        lock.lock()
        let port = _boundPort
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    var requestCount: Int {
        lock.lock()
        let count = _requestCount
        lock.unlock()
        return count
    }

    func updateAccessTokenProvider(_ provider: @escaping @Sendable () -> String) {
        lock.lock()
        accessTokenProvider = provider
        lock.unlock()
    }

    func stop() {
        releaseResponses()
        listener?.cancel()
        listener = nil
    }

    func releaseResponses() {
        lock.lock()
        guard !_responsesReleased else {
            lock.unlock()
            return
        }
        _responsesReleased = true
        let gate = responseGate
        lock.unlock()
        gate?.leave()
    }

    private func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate(continuation)

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    guard let rawPort = listener?.port?.rawValue else {
                        gate.resume(.failure(NSError(domain: "RefreshTokenHTTPTestServer", code: 1)))
                        return
                    }
                    self?.lock.lock()
                    self?._boundPort = rawPort
                    self?.lock.unlock()
                    gate.resume(.success(()))
                case .failed(let error):
                    gate.resume(.failure(error))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] _, _, _, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                return
            }

            let body = self.makeResponseBody()
            self.responseGate?.wait()
            let statusLine = self.failureStatus.map { "HTTP/1.1 \($0) Fixture Error\r\n" } ?? "HTTP/1.1 200 OK\r\n"
            var response = Data(statusLine.utf8)
            response.append(Data("Content-Type: application/json\r\n".utf8))
            response.append(Data("Content-Length: \(body.count)\r\n".utf8))
            response.append(Data("Connection: close\r\n\r\n".utf8))
            response.append(body)

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func makeResponseBody() -> Data {
        lock.lock()
        _requestCount += 1
        let accessToken = accessTokenProvider()
        lock.unlock()

        if let failureBody { return failureBody }
        let payload: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": "refresh-token-next",
            "user": [
                "id": "user-1",
                "email": "user@example.com",
                "user_metadata": [
                    "display_name": "UITest User",
                    "nebula_id": "NEBULA-1"
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
