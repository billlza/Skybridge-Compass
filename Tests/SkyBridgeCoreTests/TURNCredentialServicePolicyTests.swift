import XCTest
@testable import SkyBridgeCore
@testable import SkyBridgeProtocolCore

final class TURNCredentialServicePolicyTests: XCTestCase {
    func testNewAdmissionLeaseDoesNotReuseSameSessionCachedCredentials() async throws {
        let leaseA = SignalServerClient.TurnAdmissionLease(token: "turn-lease-a", expiresIn: 60)
        let leaseB = SignalServerClient.TurnAdmissionLease(token: "turn-lease-b", expiresIn: 60)
        let recorder = TURNCredentialFetchRecorder(credentialsByToken: [
            leaseA.token: Self.credentials(username: "relay-a"),
            leaseB.token: Self.credentials(username: "relay-b")
        ])
        let service = TURNCredentialService { token in
            try await recorder.fetch(token: token)
        }

        let credentialsA = try await service.getCredentials(
            sessionID: "same-session",
            turnAdmissionLease: leaseA
        )
        let credentialsB = try await service.getCredentials(
            sessionID: "same-session",
            turnAdmissionLease: leaseB
        )
        let fetchedTokens = await recorder.fetchedTokens()

        XCTAssertEqual(credentialsA.username, "relay-a")
        XCTAssertEqual(credentialsB.username, "relay-b")
        XCTAssertEqual(fetchedTokens, [leaseA.token, leaseB.token])
    }

    func testConditionalClearFromOldLeaseDoesNotDeleteSameSessionReplacementCache() async throws {
        let leaseA = SignalServerClient.TurnAdmissionLease(token: "turn-lease-a", expiresIn: 60)
        let leaseB = SignalServerClient.TurnAdmissionLease(token: "turn-lease-b", expiresIn: 60)
        let recorder = TURNCredentialFetchRecorder(credentialsByToken: [
            leaseB.token: Self.credentials(username: "relay-b")
        ])
        let service = TURNCredentialService { token in
            try await recorder.fetch(token: token)
        }

        let first = try await service.getCredentials(
            sessionID: "same-session",
            turnAdmissionLease: leaseB
        )
        let didClearReplacement = await service.clearCache(
            sessionID: "same-session",
            ifBoundTo: leaseA
        )
        let second = try await service.getCredentials(
            sessionID: "same-session",
            turnAdmissionLease: leaseB
        )
        let didClearCurrent = await service.clearCache(
            sessionID: "same-session",
            ifBoundTo: leaseB
        )
        let third = try await service.getCredentials(
            sessionID: "same-session",
            turnAdmissionLease: leaseB
        )
        let fetchedTokens = await recorder.fetchedTokens()

        XCTAssertEqual(first.username, "relay-b")
        XCTAssertFalse(didClearReplacement)
        XCTAssertEqual(second.username, "relay-b")
        XCTAssertTrue(didClearCurrent)
        XCTAssertEqual(third.username, "relay-b")
        XCTAssertEqual(fetchedTokens, [leaseB.token, leaseB.token])
    }

    func testOutOfOrderOldLeaseFetchCannotOverwriteReplacementCredentials() async throws {
        let leaseA = SignalServerClient.TurnAdmissionLease(token: "turn-lease-a", expiresIn: 60)
        let leaseB = SignalServerClient.TurnAdmissionLease(token: "turn-lease-b", expiresIn: 60)
        let fetchGate = TURNCredentialOutOfOrderFetchGate(
            blockedToken: leaseA.token,
            credentialsByToken: [
                leaseA.token: Self.credentials(username: "relay-a"),
                leaseB.token: Self.credentials(username: "relay-b")
            ]
        )
        let service = TURNCredentialService { token in
            try await fetchGate.fetch(token: token)
        }

        let oldRequest = Task {
            try await service.getCredentials(
                sessionID: "same-session",
                turnAdmissionLease: leaseA
            )
        }
        await fetchGate.waitUntilBlockedFetchStarts()

        let replacement = try await service.getCredentials(
            sessionID: "same-session",
            turnAdmissionLease: leaseB
        )
        await fetchGate.releaseBlockedFetch()

        do {
            _ = try await oldRequest.value
            XCTFail("Expected the stale TURN request to be rejected as superseded")
        } catch let error as TURNCredentialService.TURNCredentialError {
            guard case .requestSuperseded = error else {
                XCTFail("Unexpected TURN error: \(error)")
                return
            }
        }

        let cachedReplacement = try await service.getCredentials(
            sessionID: "same-session",
            turnAdmissionLease: leaseB
        )
        let fetchedTokens = await fetchGate.fetchedTokens()

        XCTAssertEqual(replacement.username, "relay-b")
        XCTAssertEqual(cachedReplacement.username, "relay-b")
        XCTAssertEqual(fetchedTokens, [leaseA.token, leaseB.token])
    }

    func testStaticTurnFallbackIsDisabledByDefault() {
        XCTAssertFalse(
            SkyBridgeServerConfig.staticTURNFallbackAllowed(
                environment: [:],
                infoDictionary: nil
            )
        )
    }

    func testStaticTurnFallbackRequiresExplicitOptIn() {
        XCTAssertTrue(
            SkyBridgeServerConfig.staticTURNFallbackAllowed(
                environment: ["SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK": "true"],
                infoDictionary: nil
            )
        )
        XCTAssertFalse(
            SkyBridgeServerConfig.staticTURNFallbackAllowed(
                environment: ["SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK": "0"],
                infoDictionary: nil
            )
        )
    }

    func testResolvedFallbackCredentialsRemainStunOnlyWithoutOptIn() {
        let credentials = TURNCredentialService.resolvedFallbackCredentials(
            allowStaticTURN: false,
            environment: [
                "SKYBRIDGE_TURN_USERNAME": "operator",
                "SKYBRIDGE_TURN_PASSWORD": "secret"
            ],
            turnURLs: ["turns:relay.example.com:5349?transport=tcp"],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(credentials.username, "")
        XCTAssertEqual(credentials.password, "")
        XCTAssertTrue(credentials.uris.isEmpty)
    }

    func testResolvedFallbackCredentialsUseStaticTURNWhenOptedIn() {
        let credentials = TURNCredentialService.resolvedFallbackCredentials(
            allowStaticTURN: true,
            environment: [
                "SKYBRIDGE_TURN_USERNAME": "operator",
                "SKYBRIDGE_TURN_PASSWORD": "secret"
            ],
            turnURLs: ["turns:relay.example.com:5349?transport=tcp"],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(credentials.username, "operator")
        XCTAssertEqual(credentials.password, "secret")
        XCTAssertEqual(credentials.uris, ["turns:relay.example.com:5349?transport=tcp"])
    }

    func testServerErrorDescriptionNeverIncludesResponseBody() {
        let sensitiveBody = "token=secret-value password=credential"
        let error = TURNCredentialService.TURNCredentialError.serverError(
            statusCode: 401,
            responseBytes: sensitiveBody.utf8.count
        )
        let description = error.localizedDescription

        XCTAssertTrue(description.contains("401"))
        XCTAssertTrue(description.contains("\(sensitiveBody.utf8.count)"))
        XCTAssertFalse(description.contains("secret-value"))
        XCTAssertFalse(description.contains("credential"))
    }

    private static func credentials(username: String) -> TURNCredentialService.TURNCredentials {
        TURNCredentialService.TURNCredentials(
            username: username,
            password: "test-password",
            ttl: 3_600,
            uris: ["turns:relay.example.com:5349?transport=tcp"],
            expiresAt: Date().addingTimeInterval(3_600)
        )
    }
}

private actor TURNCredentialFetchRecorder {
    enum FetchError: Error {
        case unexpectedToken
    }

    private let credentialsByToken: [String: TURNCredentialService.TURNCredentials]
    private var tokens: [String] = []

    init(credentialsByToken: [String: TURNCredentialService.TURNCredentials]) {
        self.credentialsByToken = credentialsByToken
    }

    func fetch(token: String) throws -> TURNCredentialService.TURNCredentials {
        tokens.append(token)
        guard let credentials = credentialsByToken[token] else {
            throw FetchError.unexpectedToken
        }
        return credentials
    }

    func fetchedTokens() -> [String] {
        tokens
    }
}

private actor TURNCredentialOutOfOrderFetchGate {
    enum FetchError: Error {
        case unexpectedToken
    }

    private let blockedToken: String
    private let credentialsByToken: [String: TURNCredentialService.TURNCredentials]
    private var tokens: [String] = []
    private var blockedFetchStarted = false
    private var blockedFetchStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedFetchContinuation: CheckedContinuation<Void, Never>?

    init(
        blockedToken: String,
        credentialsByToken: [String: TURNCredentialService.TURNCredentials]
    ) {
        self.blockedToken = blockedToken
        self.credentialsByToken = credentialsByToken
    }

    func fetch(token: String) async throws -> TURNCredentialService.TURNCredentials {
        tokens.append(token)
        if token == blockedToken {
            blockedFetchStarted = true
            let waiters = blockedFetchStartWaiters
            blockedFetchStartWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                precondition(blockedFetchContinuation == nil)
                blockedFetchContinuation = continuation
            }
        }
        guard let credentials = credentialsByToken[token] else {
            throw FetchError.unexpectedToken
        }
        return credentials
    }

    func waitUntilBlockedFetchStarts() async {
        if blockedFetchStarted {
            return
        }
        await withCheckedContinuation { continuation in
            blockedFetchStartWaiters.append(continuation)
        }
    }

    func releaseBlockedFetch() {
        let continuation = blockedFetchContinuation
        blockedFetchContinuation = nil
        continuation?.resume()
    }

    func fetchedTokens() -> [String] {
        tokens
    }
}
