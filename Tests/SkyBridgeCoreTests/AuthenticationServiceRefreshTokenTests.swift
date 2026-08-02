import XCTest
import Network
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
        let staleReplacement = AuthSession(
            accessToken: "stale-access-token",
            refreshToken: "stale-refresh-token",
            userIdentifier: "source-user",
            displayName: "Stale",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_012)
        )
        try await keychain.storeAuthSession(source)

        let firstReplacement = try await keychain.replaceAuthSession(
            expected: source,
            with: replacement
        )
        let staleResult = try await keychain.replaceAuthSession(
            expected: source,
            with: staleReplacement
        )
        XCTAssertTrue(firstReplacement)
        XCTAssertFalse(staleResult)
        let persisted = try await keychain.loadAuthSessionStrict()
        XCTAssertEqual(persisted, replacement)
        try await keychain.deleteAuthSession()
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

    init(
        accessTokenProvider: @escaping @Sendable () -> String,
        blockResponses: Bool = false
    ) async throws {
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
            var response = Data("HTTP/1.1 200 OK\r\n".utf8)
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
