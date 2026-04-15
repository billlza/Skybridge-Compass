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
        try await MainActor.run {
            try AuthenticationService.shared.updateSession(
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
        }
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

    private nonisolated static func makeSupabaseAccessToken(baseURL: URL, expirationOffset: TimeInterval) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let payload: [String: Any] = [
            "iss": baseURL.appendingPathComponent("auth/v1").absoluteString,
            "sub": "user-1",
            "exp": Int(Date().addingTimeInterval(expirationOffset).timeIntervalSince1970)
        ]
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
    private var accessTokenProvider: @Sendable () -> String

    init(accessTokenProvider: @escaping @Sendable () -> String) async throws {
        self.accessTokenProvider = accessTokenProvider
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
        listener?.cancel()
        listener = nil
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
