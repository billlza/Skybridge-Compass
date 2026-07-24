import CFNetwork
import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class WebRTCSignalingFaultInjectionTests: XCTestCase {
    @MainActor
    func testFileTransferAckWaiterCancellationRemovesOnlyItsTokenAndAllowsKeyReuse() async throws {
        let manager = CrossNetworkWebRTCManager.instance
        let transferID = UUID().uuidString
        let key = CrossNetworkWebRTCManager.fileTransferWaiterKey(
            transferId: transferID,
            op: .metadataAck,
            chunkIndex: nil
        )
        XCTAssertNil(manager.fileTransferWaiters[key])

        var cancelledWaiter: Task<CrossNetworkFileTransferMessage, Error>? = Task { @MainActor in
            try await manager.waitForFileTransferAck(
                transferId: transferID,
                op: .metadataAck,
                timeoutSeconds: 30
            )
        }
        defer { cancelledWaiter?.cancel() }
        try await waitForFileTransferWaiter(key, manager: manager)

        cancelledWaiter?.cancel()
        do {
            _ = try await cancelledWaiter?.value
            XCTFail("A cancelled file-transfer waiter must throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        cancelledWaiter = nil
        XCTAssertNil(manager.fileTransferWaiters[key])

        let replacementWaiter = Task { @MainActor in
            try await manager.waitForFileTransferAck(
                transferId: transferID,
                op: .metadataAck,
                timeoutSeconds: 30
            )
        }
        defer { replacementWaiter.cancel() }
        try await waitForFileTransferWaiter(key, manager: manager)

        manager.handleInboundFileTransferWire(
            CrossNetworkFileTransferMessage(op: .metadataAck, transferId: transferID)
        )
        let response = try await replacementWaiter.value
        XCTAssertEqual(response.op, .metadataAck)
        XCTAssertNil(manager.fileTransferWaiters[key])
    }

    @MainActor
    private func waitForFileTransferWaiter(
        _ key: CrossNetworkWebRTCManager.FileTransferWaiterKey,
        manager: CrossNetworkWebRTCManager
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while manager.fileTransferWaiters[key] == nil {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for file-transfer waiter registration")
                throw WebRTCSignalingFaultInjectionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testSignalServerRejectedDescriptionRedactsResponseBody() {
        let error = SignalServerClientCompat.ClientError.serverRejected(
            503,
            #"{"error":"session_inactive","message":"session-token-secret","sessionToken":"abc"}"#
        )
        let description = error.localizedDescription

        XCTAssertTrue(description.contains("503"))
        XCTAssertTrue(description.contains("<redacted-server-error-body>"))
        XCTAssertFalse(description.contains("session_inactive"))
        XCTAssertFalse(description.contains("session-token-secret"))
        XCTAssertFalse(description.contains("sessionToken"))
    }

    func testAuthenticatedRequestUsesBearerAndTenantFromOneSessionSnapshot() async throws {
        AuthenticatedRequestURLProtocol.reset()
        let firstToken = try makeAuthTestJWT(
            subject: "user-a",
            tenantID: "tenant-a",
            expiration: 4_102_444_800
        )
        let secondToken = try makeAuthTestJWT(
            subject: "user-b",
            tenantID: "tenant-b",
            expiration: 4_102_444_800
        )
        let sessionLoader = SequentialAuthSessionLoader(
            sessions: [
                makeAuthTestSession(token: firstToken, userID: "user-a", tenantID: "tenant-a"),
                makeAuthTestSession(token: secondToken, userID: "user-b", tenantID: "tenant-b")
            ]
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { await sessionLoader.load() },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )

        _ = try await client.requestAdmissionChallenge(binding: makeAuthTestProtocolBinding())

        let sessionLoadCount = await sessionLoader.loadCount()
        XCTAssertEqual(sessionLoadCount, 1)
        let request = try XCTUnwrap(AuthenticatedRequestURLProtocol.requests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(firstToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SkyBridge-Tenant-Id"), "tenant-a")
    }

    func testRegisterCurrentDeviceBindsTheExactAuthenticatedAuthority() async throws {
        AuthenticatedRequestURLProtocol.reset()
        let token = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-a",
            expiration: 4_102_444_800
        )
        let substitutedToken = try makeAuthTestJWT(
            subject: "user-456",
            tenantID: "tenant-b",
            expiration: 4_102_444_800
        )
        let sessionLoader = SequentialAuthSessionLoader(
            sessions: [
                makeAuthTestSession(
                    token: token,
                    userID: "user-123",
                    tenantID: "tenant-a"
                ),
                makeAuthTestSession(
                    token: substitutedToken,
                    userID: "user-456",
                    tenantID: "tenant-b"
                )
            ]
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { await sessionLoader.load() },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )
        let binding = try makeAuthTestProtocolBinding()

        let registered = try await client.registerCurrentDevice(
            binding: binding,
            deviceName: "Test iPad",
            expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope(
                tenantID: "tenant-a",
                userID: "user-123"
            )
        )

        XCTAssertEqual(registered.tenantID, "tenant-a")
        XCTAssertEqual(registered.userID, "user-123")
        XCTAssertEqual(registered.deviceID, binding.deviceId)
        XCTAssertEqual(registered.protocolSigningAlgorithm, binding.protocolSigningAlgorithm)
        XCTAssertEqual(
            registered.protocolPublicKeyFingerprint,
            binding.protocolPublicKeyFingerprint
        )
        XCTAssertEqual(registered.status, "active")
        XCTAssertTrue(registered.activated)
        let sessionLoadCount = await sessionLoader.loadCount()
        XCTAssertEqual(sessionLoadCount, 1)
        let request = try XCTUnwrap(AuthenticatedRequestURLProtocol.requests().last)
        XCTAssertEqual(request.url?.path, "/api/devices/register-current")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SkyBridge-Tenant-Id"), "tenant-a")
        let requestBody = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        XCTAssertEqual(object["deviceId"] as? String, binding.deviceId)
        XCTAssertEqual(
            object["protocolSigningAlgorithm"] as? String,
            binding.protocolSigningAlgorithm.rawValue
        )
        XCTAssertEqual(
            object["protocolPublicKeyFingerprint"] as? String,
            binding.protocolPublicKeyFingerprint
        )
        XCTAssertEqual(object["deviceName"] as? String, "Test iPad")
    }

    func testRegisterCurrentDeviceRejectsAResponseAuthoritySubstitution() async throws {
        AuthenticatedRequestURLProtocol.reset()
        AuthenticatedRequestURLProtocol.setRegistrationFingerprintOverride(
            String(repeating: "0", count: 64)
        )
        defer { AuthenticatedRequestURLProtocol.reset() }
        let token = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-a",
            expiration: 4_102_444_800
        )
        let session = makeAuthTestSession(
            token: token,
            userID: "user-123",
            tenantID: "tenant-a"
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { session },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )

        do {
            _ = try await client.registerCurrentDevice(
                binding: makeAuthTestProtocolBinding(),
                deviceName: "Test iPad",
                expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope(
                    tenantID: "tenant-a",
                    userID: "user-123"
                )
            )
            XCTFail("A substituted registration authority must fail closed")
        } catch SignalServerClientCompat.ClientError.malformedResponse(let reason) {
            XCTAssertTrue(reason.contains("changed the authenticated authority"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegisterCurrentDeviceRejectsScopeChangeBeforeNetworkRequest() async throws {
        AuthenticatedRequestURLProtocol.reset()
        defer { AuthenticatedRequestURLProtocol.reset() }
        let token = try makeAuthTestJWT(
            subject: "user-456",
            tenantID: "tenant-b",
            expiration: 4_102_444_800
        )
        let session = makeAuthTestSession(
            token: token,
            userID: "user-456",
            tenantID: "tenant-b"
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { session },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )

        do {
            _ = try await client.registerCurrentDevice(
                binding: makeAuthTestProtocolBinding(),
                deviceName: "Test iPad",
                expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope(
                    tenantID: "tenant-a",
                    userID: "user-123"
                )
            )
            XCTFail("A changed authentication scope must fail before sending a request")
        } catch SignalServerClientCompat.ClientError.authenticationSessionChanged {
            XCTAssertTrue(AuthenticatedRequestURLProtocol.requests().isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIdentityRotationChallengeRejectsScopeChangeBeforeNetworkRequest() async throws {
        AuthenticatedRequestURLProtocol.reset()
        defer { AuthenticatedRequestURLProtocol.reset() }
        let token = try makeAuthTestJWT(
            subject: "user-456",
            tenantID: "tenant-b",
            expiration: 4_102_444_800
        )
        let session = makeAuthTestSession(
            token: token,
            userID: "user-456",
            tenantID: "tenant-b"
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { session },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )
        let oldIdentity = try makeAuthTestProtocolBinding()
        let newIdentity = try ProtocolIdentityBindingCompat(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x5A, count: 32)
        )

        do {
            _ = try await client.requestIdentityRotationChallenge(
                oldIdentity: oldIdentity,
                newIdentity: newIdentity,
                idempotencyKey: UUID().uuidString.lowercased(),
                expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope(
                    tenantID: "tenant-a",
                    userID: "user-123"
                )
            )
            XCTFail("A changed rotation scope must fail before sending a request")
        } catch SignalServerClientCompat.ClientError.authenticationSessionChanged {
            XCTAssertTrue(AuthenticatedRequestURLProtocol.requests().isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIdentityRotationChallengeRejectsResponseScopeSubstitution() async throws {
        AuthenticatedRequestURLProtocol.reset()
        AuthenticatedRequestURLProtocol.setRotationChallengeScopeOverride(
            tenantID: "tenant-b",
            userID: "user-456"
        )
        defer { AuthenticatedRequestURLProtocol.reset() }
        let token = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-a",
            expiration: 4_102_444_800
        )
        let session = makeAuthTestSession(
            token: token,
            userID: "user-123",
            tenantID: "tenant-a"
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { session },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )
        let oldIdentity = try makeAuthTestProtocolBinding()
        let newIdentity = try ProtocolIdentityBindingCompat(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x5A, count: 32)
        )

        do {
            _ = try await client.requestIdentityRotationChallenge(
                oldIdentity: oldIdentity,
                newIdentity: newIdentity,
                idempotencyKey: UUID().uuidString.lowercased(),
                expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope(
                    tenantID: "tenant-a",
                    userID: "user-123"
                )
            )
            XCTFail("A substituted response scope must fail before transcript signing")
        } catch SignalServerClientCompat.ClientError.malformedResponse(let reason) {
            XCTAssertTrue(reason.contains("changed the requested authority"))
            XCTAssertEqual(AuthenticatedRequestURLProtocol.requests().count, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIdentityRotationCommitRejectsScopeChangeBeforeNetworkRequest() async throws {
        AuthenticatedRequestURLProtocol.reset()
        defer { AuthenticatedRequestURLProtocol.reset() }
        let token = try makeAuthTestJWT(
            subject: "user-456",
            tenantID: "tenant-b",
            expiration: 4_102_444_800
        )
        let session = makeAuthTestSession(
            token: token,
            userID: "user-456",
            tenantID: "tenant-b"
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { session },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )
        let oldIdentity = try makeAuthTestProtocolBinding()
        let newIdentity = try ProtocolIdentityBindingCompat(
            deviceId: oldIdentity.deviceId,
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x5A, count: 32)
        )
        let transcript = try DeviceIdentityRotationTranscriptCompat(
            rotationID: UUID().uuidString.lowercased(),
            nonce: Data(repeating: 0xC3, count: 32),
            expiresAtMilliseconds: 4_102_444_800_000,
            tenantID: "tenant-a",
            userID: "user-123",
            deviceID: oldIdentity.deviceId,
            oldGeneration: 7,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )
        let challenge = try SignalServerClientCompat.IdentityRotationChallenge(
            transcript: transcript,
            issuedAtMilliseconds: 2_000_000_000_000,
            clientVersion: "1.0.0",
            protocolVersion: "1"
        )

        do {
            _ = try await client.commitIdentityRotation(
                challenge: challenge,
                oldSignature: Data(repeating: 0x11, count: 64),
                newSignature: Data(repeating: 0x22, count: 64),
                expectedScope: SignalServerClientCompat.IdentityRotationAuthenticationScope(
                    tenantID: "tenant-a",
                    userID: "user-123"
                )
            )
            XCTFail("A changed commit scope must fail before sending a request")
        } catch SignalServerClientCompat.ClientError.authenticationSessionChanged {
            XCTAssertTrue(AuthenticatedRequestURLProtocol.requests().isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testActivationCoordinatorRegistersOnceAndInvalidatesOnPrincipalChange() async throws {
        AuthenticatedRequestURLProtocol.reset()
        defer { AuthenticatedRequestURLProtocol.reset() }
        let token = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-a",
            expiration: 4_102_444_800
        )
        let session = makeAuthTestSession(
            token: token,
            userID: "user-123",
            tenantID: "tenant-a"
        )
        let replacementToken = try makeAuthTestJWT(
            subject: "user-456",
            tenantID: "tenant-b",
            expiration: 4_102_444_800
        )
        let replacementSession = makeAuthTestSession(
            token: replacementToken,
            userID: "user-456",
            tenantID: "tenant-b"
        )
        let repository = AuthSessionRepositoryProbe(session: session)
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { await repository.load() },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )
        let binding = try makeAuthTestProtocolBinding()
        var recoveryCount = 0
        let coordinator = IOSCurrentPathDeviceActivationCoordinator(
            signalServer: client,
            recoverPendingRotation: {
                recoveryCount += 1
                return false
            },
            loadBinding: { binding },
            deviceName: { "Test iPad" }
        )

        let principalA = CurrentPathAuthenticationPrincipal(
            userID: "user-123",
            tenantID: "tenant-a"
        )
        let firstActivation = try await coordinator.activateCurrentIdentityIfNeeded(
            authenticationPrincipal: principalA
        )
        let repeatedActivation = try await coordinator.activateCurrentIdentityIfNeeded(
            authenticationPrincipal: principalA
        )
        XCTAssertTrue(firstActivation)
        XCTAssertFalse(repeatedActivation)
        XCTAssertEqual(recoveryCount, 2)
        XCTAssertEqual(
            AuthenticatedRequestURLProtocol.requests().filter {
                $0.url?.path == "/api/devices/register-current"
            }.count,
            1
        )

        await coordinator.syncIfNeeded(authenticationPrincipal: principalA)
        XCTAssertEqual(
            AuthenticatedRequestURLProtocol.requests().filter {
                $0.url?.path == "/api/devices/register-current"
            }.count,
            1
        )

        let didReplaceSession = await repository.replace(
            expected: session,
            with: replacementSession
        )
        XCTAssertTrue(didReplaceSession)
        AuthenticatedRequestURLProtocol.setRegistrationUserIDOverride("user-456")
        await coordinator.syncIfNeeded(
            authenticationPrincipal: CurrentPathAuthenticationPrincipal(
                userID: "user-456",
                tenantID: "tenant-b"
            )
        )
        XCTAssertEqual(
            AuthenticatedRequestURLProtocol.requests().filter {
                $0.url?.path == "/api/devices/register-current"
            }.count,
            2
        )
        let replacementRequest = try XCTUnwrap(
            AuthenticatedRequestURLProtocol.requests().last
        )
        XCTAssertEqual(
            replacementRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(replacementToken)"
        )
        XCTAssertEqual(
            replacementRequest.value(forHTTPHeaderField: "X-SkyBridge-Tenant-Id"),
            "tenant-b"
        )
    }

    @MainActor
    func testActivationCoordinatorWaitsForCancelledPrincipalTaskBeforeReregistering() async throws {
        AuthenticatedRequestURLProtocol.reset()
        AuthenticatedRequestURLProtocol.blockNextRegistration()
        defer { AuthenticatedRequestURLProtocol.reset() }
        let token = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-a",
            expiration: 4_102_444_800
        )
        let session = makeAuthTestSession(
            token: token,
            userID: "user-123",
            tenantID: "tenant-a"
        )
        let replacementToken = try makeAuthTestJWT(
            subject: "user-456",
            tenantID: "tenant-b",
            expiration: 4_102_444_800
        )
        let replacementSession = makeAuthTestSession(
            token: replacementToken,
            userID: "user-456",
            tenantID: "tenant-b"
        )
        let repository = AuthSessionRepositoryProbe(session: session)
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { await repository.load() },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let coordinator = IOSCurrentPathDeviceActivationCoordinator(
            signalServer: SignalServerClientCompat(
                urlSession: urlSession,
                authenticationDependencies: dependencies
            ),
            recoverPendingRotation: { false },
            loadBinding: { try makeAuthTestProtocolBinding() },
            deviceName: { "Test iPad" }
        )

        let first = Task { @MainActor in
            await coordinator.syncIfNeeded(
                authenticationPrincipal: CurrentPathAuthenticationPrincipal(
                    userID: "user-123",
                    tenantID: "tenant-a"
                )
            )
        }
        defer { first.cancel() }
        try await waitForAuthenticatedRegistrationRequestCount(1)

        let didReplaceSession = await repository.replace(
            expected: session,
            with: replacementSession
        )
        XCTAssertTrue(didReplaceSession)
        AuthenticatedRequestURLProtocol.setRegistrationUserIDOverride("user-456")
        let replacementPrincipal = CurrentPathAuthenticationPrincipal(
            userID: "user-456",
            tenantID: "tenant-b"
        )
        let second = Task { @MainActor in
            await coordinator.syncIfNeeded(
                authenticationPrincipal: replacementPrincipal
            )
        }
        let third = Task { @MainActor in
            await coordinator.syncIfNeeded(
                authenticationPrincipal: replacementPrincipal
            )
        }
        await second.value
        await third.value
        await first.value

        XCTAssertEqual(AuthenticatedRequestURLProtocol.blockedRegistrationStopCount(), 1)
        XCTAssertEqual(
            AuthenticatedRequestURLProtocol.requests().filter {
                $0.url?.path == "/api/devices/register-current"
            }.count,
            2
        )
        XCTAssertEqual(
            AuthenticatedRequestURLProtocol.recordedRegistrationEvents(),
            [
                "start:tenant-a",
                "stop:tenant-a",
                "start:tenant-b",
                "finish:tenant-b"
            ]
        )
    }

    @MainActor
    func testAuthorityReadinessGateCoalescesConcurrentRecovery() async throws {
        let probe = BlockingAuthorityRecoveryProbe()
        let gate = IOSCurrentPathAuthorityReadinessGate(
            recoverPendingRotation: { await probe.recover() }
        )
        let first = Task { @MainActor in try await gate.ensureReady() }
        let second = Task { @MainActor in try await gate.ensureReady() }
        defer {
            first.cancel()
            second.cancel()
        }

        try await waitForAuthorityRecoveryCount(1, probe: probe)
        let countBeforeRelease = await probe.recoveryCount()
        XCTAssertEqual(countBeforeRelease, 1)
        await probe.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        let finalCount = await probe.recoveryCount()
        XCTAssertEqual(finalCount, 1)
    }

    @MainActor
    private func waitForAuthenticatedRegistrationRequestCount(
        _ expectedCount: Int
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while AuthenticatedRequestURLProtocol.requests().filter({
            $0.url?.path == "/api/devices/register-current"
        }).count < expectedCount {
            guard clock.now < deadline else {
                throw AuthRequestTestError.timedOutWaitingForRegistrationRequest
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private func waitForAuthorityRecoveryCount(
        _ expectedCount: Int,
        probe: BlockingAuthorityRecoveryProbe
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await probe.recoveryCount() < expectedCount {
            guard clock.now < deadline else {
                throw AuthRequestTestError.timedOutWaitingForAuthorityRecovery
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testConcurrentAuthenticatedRequestsCoalesceOneIdentityBoundRefresh() async throws {
        AuthenticatedRequestURLProtocol.reset()
        let expiredToken = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-123",
            expiration: 1
        )
        let refreshedToken = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-123",
            expiration: 4_102_444_800
        )
        let original = makeAuthTestSession(
            token: expiredToken,
            refreshToken: "refresh-original",
            userID: "user-123",
            tenantID: "tenant-123"
        )
        let refreshed = makeAuthTestSession(
            token: refreshedToken,
            refreshToken: "refresh-next",
            userID: "user-123",
            tenantID: "tenant-123"
        )
        let repository = AuthSessionRepositoryProbe(session: original)
        let refreshProbe = BlockingAuthRefreshProbe(response: refreshed)
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { await repository.load() },
            refreshSession: { token in try await refreshProbe.refresh(token: token) },
            validateRefreshedAccessToken: { _ in },
            replacePersistedSession: { expected, replacement in
                await repository.replace(expected: expected, with: replacement)
            }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )
        let binding = try makeAuthTestProtocolBinding()

        async let first = client.requestAdmissionChallenge(binding: binding)
        async let second = client.requestAdmissionChallenge(binding: binding)
        async let third = client.requestAdmissionChallenge(binding: binding)
        try await waitForAuthSessionLoads(repository, minimumCount: 3)
        await refreshProbe.release()
        _ = try await (first, second, third)

        let refreshCount = await refreshProbe.refreshCount()
        let replaceCount = await repository.replaceCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(replaceCount, 1)
        XCTAssertEqual(AuthenticatedRequestURLProtocol.requests().count, 3)
        for request in AuthenticatedRequestURLProtocol.requests() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(refreshedToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SkyBridge-Tenant-Id"), "tenant-123")
        }
    }

    func testIdentityDriftingRefreshIsRejectedBeforePersistenceOrRequestSend() async throws {
        AuthenticatedRequestURLProtocol.reset()
        let expiredToken = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-123",
            expiration: 1
        )
        let driftedToken = try makeAuthTestJWT(
            subject: "attacker-user",
            tenantID: "tenant-123",
            expiration: 4_102_444_800
        )
        let original = makeAuthTestSession(
            token: expiredToken,
            refreshToken: "refresh-original",
            userID: "user-123",
            tenantID: "tenant-123"
        )
        let drifted = makeAuthTestSession(
            token: driftedToken,
            refreshToken: "refresh-next",
            userID: "user-123",
            tenantID: "tenant-123"
        )
        let repository = AuthSessionRepositoryProbe(session: original)
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { await repository.load() },
            refreshSession: { token in
                guard token == "refresh-original" else {
                    throw AuthRequestTestError.unexpectedRefresh
                }
                return drifted
            },
            validateRefreshedAccessToken: { _ in },
            replacePersistedSession: { expected, replacement in
                await repository.replace(expected: expected, with: replacement)
            }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeAuthTestProtocolBinding())
            XCTFail("An identity-drifting refresh must fail closed")
        } catch SignalServerClientCompat.ClientError.userIdentityMismatch {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let replaceCount = await repository.replaceCount()
        XCTAssertEqual(replaceCount, 0)
        XCTAssertTrue(AuthenticatedRequestURLProtocol.requests().isEmpty)
    }

    func testExpiredJWTWithoutRefreshTokenIsRejectedBeforeRequestSend() async throws {
        AuthenticatedRequestURLProtocol.reset()
        let expiredToken = try makeAuthTestJWT(
            subject: "user-123",
            tenantID: "tenant-123",
            expiration: 1
        )
        let repository = AuthSessionRepositoryProbe(
            session: makeAuthTestSession(
                token: expiredToken,
                userID: "user-123",
                tenantID: "tenant-123"
            )
        )
        let dependencies = SignalServerClientCompat.AuthenticationDependencies(
            accessTokenOverride: { "" },
            tenantIDOverride: { "" },
            loadPersistedSession: { await repository.load() },
            refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
            validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
            replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
        )
        let urlSession = makeAuthenticatedRequestTestURLSession()
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: dependencies
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeAuthTestProtocolBinding())
            XCTFail("An expired JWT without a refresh credential must fail closed")
        } catch SignalServerClientCompat.ClientError.invalidAuthenticationClaims {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(AuthenticatedRequestURLProtocol.requests().isEmpty)
    }

    func testSignalingResponseHardLimitRejectsOversizedBody() async throws {
        let urlSession = makeSignalingBoundaryURLSession(OversizedSignalingURLProtocol.self)
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: try makeSignalingBoundaryAuthenticationDependencies(),
            requestTimeoutSeconds: 2,
            resourceTimeoutSeconds: 2,
            maximumResponseBytes: 128
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeAuthTestProtocolBinding())
            XCTFail("An oversized signaling response must fail closed")
        } catch SignalServerClientCompat.ClientError.responseTooLarge(let path, let limitBytes) {
            XCTAssertEqual(path, "/api/webrtc/admission/challenge")
            XCTAssertEqual(limitBytes, 128)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSignalingInvalidResponseLimitFailsBeforeNetworkIO() async throws {
        let urlSession = makeSignalingBoundaryURLSession(OversizedSignalingURLProtocol.self)
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: try makeSignalingBoundaryAuthenticationDependencies(),
            requestTimeoutSeconds: 2,
            resourceTimeoutSeconds: 2,
            maximumResponseBytes: 0
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeAuthTestProtocolBinding())
            XCTFail("Invalid signaling limits must fail before network I/O")
        } catch SignalServerClientCompat.ClientError.invalidRequestLimits {
            // Expected. Limit validation runs before auth resolution and URL loading.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSignalingRequestTimeoutIsMappedExplicitly() async throws {
        let urlSession = makeSignalingBoundaryURLSession(TimedOutSignalingURLProtocol.self)
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: try makeSignalingBoundaryAuthenticationDependencies(),
            requestTimeoutSeconds: 2,
            resourceTimeoutSeconds: 2
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeAuthTestProtocolBinding())
            XCTFail("A timed-out signaling request must fail closed")
        } catch SignalServerClientCompat.ClientError.requestTimedOut(let path) {
            XCTAssertEqual(path, "/api/webrtc/admission/challenge")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSignalingResourceDeadlineCancelsHangingResponse() async throws {
        HangingSignalingURLProtocol.reset()
        let urlSession = makeSignalingBoundaryURLSession(HangingSignalingURLProtocol.self)
        defer { urlSession.invalidateAndCancel() }
        let client = SignalServerClientCompat(
            urlSession: urlSession,
            authenticationDependencies: try makeSignalingBoundaryAuthenticationDependencies(),
            requestTimeoutSeconds: 2,
            resourceTimeoutSeconds: 0.05
        )

        do {
            _ = try await client.requestAdmissionChallenge(binding: makeAuthTestProtocolBinding())
            XCTFail("A hanging signaling response must hit the hard resource deadline")
        } catch SignalServerClientCompat.ClientError.resourceDeadlineExceeded(let path) {
            XCTAssertEqual(path, "/api/webrtc/admission/challenge")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        try await waitForHangingSignalingRequestCancellation()
    }

    func testInboundFrameParserReassemblesValidFragmentedPayload() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let payload = Data("hello-webrtc".utf8)
        let framed = framedPayload(payload)

        parser.append(Data(framed.prefix(3)))
        XCTAssertFalse(parser.canProbeDirectCompatibility)
        XCTAssertNil(parser.nextPayload(sessionId: "S1", logLabel: "test"))

        parser.append(Data(framed.dropFirst(3)))
        XCTAssertEqual(parser.nextPayload(sessionId: "S1", logLabel: "test"), payload)
        XCTAssertTrue(parser.canProbeDirectCompatibility)
    }

    func testInboundFrameParserClearsBufferAfterInvalidLengthPrefix() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        parser.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        XCTAssertNil(parser.nextPayload(sessionId: "S2", logLabel: "test"))
        XCTAssertTrue(parser.canProbeDirectCompatibility)

        let payload = Data("recovered".utf8)
        parser.append(framedPayload(payload))
        XCTAssertEqual(parser.nextPayload(sessionId: "S2", logLabel: "test"), payload)
    }

    func testInboundFrameParserAcceptsExactMaxFrameAndStickyNextFrame() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 8192)
        let exactMaxPayload = Data((0..<8192).map { UInt8($0 % 251) })
        let nextPayload = Data("next".utf8)
        var combined = framedPayload(exactMaxPayload)
        combined.append(framedPayload(nextPayload))

        parser.append(Data(combined.prefix(2)))
        XCTAssertNil(parser.nextPayload(sessionId: "S2-exact", logLabel: "test"))

        parser.append(Data(combined.dropFirst(2)))
        XCTAssertEqual(parser.nextPayload(sessionId: "S2-exact", logLabel: "test"), exactMaxPayload)
        XCTAssertEqual(parser.nextPayload(sessionId: "S2-exact", logLabel: "test"), nextPayload)

        var oversizedParser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 8192)
        oversizedParser.append(framedPayload(Data(repeating: 0xA5, count: 8193)))
        XCTAssertNil(oversizedParser.nextPayload(sessionId: "S2-oversized", logLabel: "test"))
        XCTAssertTrue(oversizedParser.canProbeDirectCompatibility)
    }

    func testInboundFrameParserOnlyAllowsDirectProbeWhenNoPartialFrameIsBuffered() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let payload = Data("frame".utf8)
        let framed = framedPayload(payload)

        XCTAssertTrue(parser.canProbeDirectCompatibility)
        parser.append(Data(framed.prefix(2)))
        XCTAssertFalse(parser.canProbeDirectCompatibility)
        XCTAssertNil(parser.nextPayload(sessionId: "S3", logLabel: "test"))
    }

    func testInboundFrameParserDropsSBP2WithoutInterpretingItAsLength() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let directSBP2 = Data([0x53, 0x42, 0x50, 0x32, 0x00, 0x00, 0x00, 0x10])

        parser.append(directSBP2)
        XCTAssertNil(parser.nextPayload(sessionId: "S4", logLabel: "test"))
        XCTAssertTrue(parser.canProbeDirectCompatibility)

        let payload = Data("recovered".utf8)
        parser.append(framedPayload(payload))
        XCTAssertEqual(parser.nextPayload(sessionId: "S4", logLabel: "test"), payload)
    }

    func testInboundFrameParserDropsSBC2WrongChannelWithoutInterpretingItAsLength() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let sbc2ChunkOnControlChannel = Data([0x53, 0x42, 0x43, 0x32, 0x00, 0x00, 0x00, 0x01])

        parser.append(sbc2ChunkOnControlChannel)
        XCTAssertNil(parser.nextPayload(sessionId: "S5", logLabel: "test"))
        XCTAssertTrue(parser.canProbeDirectCompatibility)

        let payload = Data("recovered-after-sbc2".utf8)
        parser.append(framedPayload(payload))
        XCTAssertEqual(parser.nextPayload(sessionId: "S5", logLabel: "test"), payload)
    }

    func testInvalidWebSocketURLFailsFastWithoutRetry() async {
        await Task { @MainActor in
            let probe = RetryProbe()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .seconds(1),
                sleep: { duration in
                    await probe.recordSleep(duration)
                }
            )

            XCTAssertNil(SignalingRetryController.validatedWebSocketURL("http://example.com/ws"))
            XCTAssertNil(SignalingRetryController.validatedWebSocketURL("wss://"))
            XCTAssertNotNil(SignalingRetryController.validatedWebSocketURL("wss://example.com/ws"))

            do {
                try await controller.sendWithRetry(
                    retries: 3,
                    reconnectIfNeeded: {
                        await probe.recordReconnect()
                    },
                    send: {
                        throw SignalingRetryControllerError.invalidWebSocketURL("wss://")
                    }
                )
                XCTFail("Expected invalid URL error")
            } catch let error as SignalingRetryControllerError {
                XCTAssertEqual(error, .invalidWebSocketURL("wss://"))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let reconnectCount = await probe.reconnectCount()
            let sleepCount = await probe.sleepCount()
            XCTAssertEqual(reconnectCount, 0)
            XCTAssertEqual(sleepCount, 0)
        }.value
    }

    func testReconnectBackoffAfterNotConnectedThenSuccess() async throws {
        try await Task { @MainActor in
            let probe = RetryProbe()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .seconds(1),
                sleep: { duration in
                    await probe.recordSleep(duration)
                }
            )

            try await controller.sendWithRetry(
                retries: 2,
                reconnectIfNeeded: {
                    await probe.recordReconnect()
                },
                send: {
                    let attempt = await probe.nextAttempt()
                    if attempt == 1 {
                        throw WebSocketSignalingClient.SignalingError.notConnected
                    }
                }
            )

            let attemptCount = await probe.attemptCount()
            let reconnectCount = await probe.reconnectCount()
            let sleepCount = await probe.sleepCount()
            XCTAssertEqual(attemptCount, 2)
            XCTAssertEqual(reconnectCount, 1)
            XCTAssertEqual(sleepCount, 1)
        }.value
    }

    func testReconnectFailureIsSurfacedWithoutSendingAnotherAttempt() async {
        await Task { @MainActor in
            let probe = RetryProbe()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .seconds(1),
                sleep: { duration in
                    await probe.recordSleep(duration)
                }
            )

            do {
                try await controller.sendWithRetry(
                    retries: 2,
                    reconnectIfNeeded: {
                        await probe.recordReconnect()
                        throw WebRTCSignalingFaultInjectionTestError.reconnectFailed
                    },
                    send: {
                        _ = await probe.nextAttempt()
                        throw WebSocketSignalingClient.SignalingError.notConnected
                    }
                )
                XCTFail("Expected reconnect failure")
            } catch WebRTCSignalingFaultInjectionTestError.reconnectFailed {
                // Expected: a failed reconnect is a real signaling failure.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let attemptCount = await probe.attemptCount()
            let reconnectCount = await probe.reconnectCount()
            let sleepCount = await probe.sleepCount()
            XCTAssertEqual(attemptCount, 1)
            XCTAssertEqual(reconnectCount, 1)
            XCTAssertEqual(sleepCount, 0)
        }.value
    }

    func testCancellationDuringRetryBackoffDoesNotStartAnotherAttempt() async {
        let probe = RetryProbe()
        let sleepStarted = AsyncOneShotTestLatch()
        let controller = SignalingRetryController(
            retryDelay: .seconds(5),
            attemptTimeout: .seconds(1),
            sleep: { duration in
                await probe.recordSleep(duration)
                await sleepStarted.signal()
                try await Task.sleep(for: duration)
            }
        )
        let retryTask = Task { @MainActor in
            try await controller.sendWithRetry(
                retries: 3,
                reconnectIfNeeded: {
                    await probe.recordReconnect()
                },
                send: {
                    _ = await probe.nextAttempt()
                    throw WebSocketSignalingClient.SignalingError.notConnected
                }
            )
        }

        let didStartBackoff = await sleepStarted.wait(timeout: .seconds(2))
        XCTAssertTrue(didStartBackoff, "Retry task did not enter its injected backoff before the test deadline")
        guard didStartBackoff else {
            retryTask.cancel()
            _ = await retryTask.result
            return
        }
        let sleepCountBeforeCancellation = await probe.sleepCount()
        XCTAssertEqual(sleepCountBeforeCancellation, 1)

        retryTask.cancel()
        do {
            try await retryTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be converted into another retry.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let attemptCount = await probe.attemptCount()
        let reconnectCount = await probe.reconnectCount()
        let sleepCount = await probe.sleepCount()
        XCTAssertEqual(attemptCount, 1)
        XCTAssertEqual(reconnectCount, 1)
        XCTAssertEqual(sleepCount, 1)
    }

    func testTimeoutCancelsHangingSendAttempt() async {
        await Task { @MainActor in
            let cancelFlag = CancellationFlag()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .milliseconds(40),
                sleep: { _ in }
            )

            do {
                try await controller.sendWithRetry(
                    retries: 0,
                    reconnectIfNeeded: {},
                    send: {
                        try await withTaskCancellationHandler {
                            try await Task.sleep(for: .seconds(2))
                        } onCancel: {
                            cancelFlag.markCancelled()
                        }
                    }
                )
                XCTFail("Expected timeout error")
            } catch let error as SignalingRetryControllerError {
                XCTAssertEqual(error, .attemptTimedOut)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(cancelFlag.isCancelled)
        }.value
    }

    func testQRCodeBootstrapUsesLongerNetworkStartupTimeouts() async {
        await Task { @MainActor in
            XCTAssertGreaterThanOrEqual(
                CrossNetworkWebRTCManager.testOnlyCurrentPathRequestTimeoutSeconds(),
                30
            )
            XCTAssertGreaterThanOrEqual(
                CrossNetworkWebRTCManager.testOnlyWebRTCStartupJoinHeartbeatAttempts(),
                60
            )
            XCTAssertGreaterThanOrEqual(
                SignalingRetryController.testOnlyDefaultAttemptTimeoutSeconds(),
                15
            )
            XCTAssertGreaterThanOrEqual(
                WebSocketSignalingClient.testOnlyDefaultConnectionTimeoutSeconds(),
                15
            )
        }.value
    }

    func testSignalingFailureClassificationStaysInPolicy() {
        XCTAssertEqual(
            CrossNetworkWebRTCManager.classifySignalingFailureReason("token expired"),
            .tokenExpired
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.classifySignalingFailureReason("socket is not connected"),
            .transientNetwork
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.classifySignalingFailureReason("malformed signaling payload"),
            .protocolViolation
        )
        XCTAssertTrue(CrossNetworkWebRTCManager.isFatalPreTransportFailure(.authBindRejected))
        XCTAssertTrue(CrossNetworkWebRTCManager.isFatalPostTransportFailure(.protocolViolation))
        XCTAssertFalse(CrossNetworkWebRTCManager.isFatalPreTransportFailure(.tokenExpired))
        XCTAssertFalse(CrossNetworkWebRTCManager.isFatalPostTransportFailure(.transientNetwork))
    }

    func testWebSocketSignalingClientParsesServerFramesAndRedactsTokenizedURL() async {
        await Task { @MainActor in
            let raw = #"{"type":"bound","sessionId":"ROOM1234","role":"initiator","clientId":"client-1"}"#
            let parsed = WebSocketSignalingClient.parseInboundText(raw)

            switch parsed {
            case .serverFrame(let frame):
                XCTAssertEqual(frame.type, "bound")
                XCTAssertEqual(frame.sessionId, "ROOM1234")
                XCTAssertFalse(frame.isError)
            default:
                XCTFail("Expected server frame, got \(parsed)")
            }

            let url = URL(string: "wss://api.example.com/ws?shard=ROOM1234&st=secret-token&cv=1.0&pv=1")!
            let redacted = WebSocketSignalingClient.redactedURLString(url)
            XCTAssertFalse(redacted.contains("secret-token"))
            XCTAssertFalse(redacted.contains("ROOM1234"))
            XCTAssertTrue(redacted.contains("st=%3Credacted%3E") || redacted.contains("st=<redacted>"))
            XCTAssertTrue(redacted.contains("shard=%3Credacted%3E") || redacted.contains("shard=<redacted>"))
        }.value
    }

    func testCurrentPathWebSocketHeadersCarrySessionTokenOutsideURL() {
        let headers = CrossNetworkWebRTCManager.currentPathSignalingWebSocketHeaders(
            sessionID: "room123",
            sessionToken: "session-token",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        )
        XCTAssertEqual(headers?["X-SkyBridge-Session-Id"], "ROOM123")
        XCTAssertEqual(headers?["X-SkyBridge-Session"], "session-token")
        XCTAssertEqual(headers?["X-SkyBridge-Client-Version"], "1.2.3")
        XCTAssertEqual(headers?["X-SkyBridge-Protocol-Version"], "2")

        XCTAssertNil(CrossNetworkWebRTCManager.currentPathSignalingWebSocketHeaders(
            sessionID: "room123",
            sessionToken: "session-token\r\nInjected: value",
            clientVersion: "1.2.3",
            protocolVersion: "2"
        ))
    }

    func testWebSocketSignalingClientAllocatesDistinctHandleGenerationsPerAttempt() async {
        await Task { @MainActor in
            let client = WebSocketSignalingClient(
                url: URL(string: "wss://signal.example.com/ws")!,
                sessionId: "ROOM1234",
                generation: 41
            )

            let first = await client.testOnlyReserveNextHandleId(for: .urlSession)
            let second = await client.testOnlyReserveNextHandleId(for: .urlSession)

            XCTAssertEqual(first.generation, 41)
            XCTAssertEqual(second.generation, 42)
            XCTAssertNotEqual(first, second)
        }.value
    }

    func testNoProxyConfigurationDisablesSystemProxyMechanisms() {
        let dictionary = WebSocketSignalingClient.testOnlyNoProxyConnectionProxyDictionary()

        XCTAssertEqual(dictionary[kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPEnable as String] as? Bool, false)
        XCTAssertEqual(dictionary["HTTPSEnable"] as? Bool, false)
        XCTAssertEqual(dictionary["SOCKSEnable"] as? Bool, false)
        XCTAssertEqual(dictionary["ProxyAutoConfigEnable"] as? Bool, false)
        XCTAssertEqual(dictionary["ProxyAutoDiscoveryEnable"] as? Bool, false)
    }

    func testAutoPolicyUsesNativeProxyBypassBeforeURLSessionFallback() async {
        await Task { @MainActor in
            let client = WebSocketSignalingClient(
                url: URL(string: "wss://signal.example.com/ws")!,
                sessionId: "ROOM1234",
                generation: 1
            )

            let labels = await client.testOnlyTransportAttemptLabels()

            XCTAssertEqual(labels, [
                "native-proxy-bypass",
                "urlsession-proxy-bypass",
                "native",
                "urlsession",
            ])
        }.value
    }

    func testExplicitTestTransportPolicyDoesNotDependOnProcessEnvironment() async {
        await Task { @MainActor in
            let url = URL(string: "wss://signal.example.com/ws")!
            let native = WebSocketSignalingClient(
                url: url,
                sessionId: "ROOM1234",
                generation: 1,
                selectionPolicy: .native,
                nativeFallbackEnabled: false
            )
            let urlSession = WebSocketSignalingClient(
                url: url,
                sessionId: "ROOM1234",
                generation: 1,
                selectionPolicy: .urlSession,
                nativeFallbackEnabled: false
            )
            let automaticWithoutNative = WebSocketSignalingClient(
                url: url,
                sessionId: "ROOM1234",
                generation: 1,
                selectionPolicy: .auto,
                nativeFallbackEnabled: false
            )

            let nativeLabels = await native.testOnlyTransportAttemptLabels()
            let urlSessionLabels = await urlSession.testOnlyTransportAttemptLabels()
            let automaticWithoutNativeLabels =
                await automaticWithoutNative.testOnlyTransportAttemptLabels()

            XCTAssertEqual(nativeLabels, ["native"])
            XCTAssertEqual(urlSessionLabels, ["urlsession"])
            XCTAssertEqual(
                automaticWithoutNativeLabels,
                ["urlsession-proxy-bypass", "urlsession"]
            )
        }.value
    }

    func testSignalingTransportOverridesAreTestOnlyAndInboundCallbacksAreSerialized() throws {
        let clientSource = try repositorySource(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebSocketSignalingClient.swift"
        )
        let nativeSource = try repositorySource(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/NativeWebSocketClient.swift"
        )
        let managerSource = try repositorySource(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )

        XCTAssertTrue(clientSource.contains("#if DEBUG || SKYBRIDGE_TESTING"))
        XCTAssertTrue(clientSource.contains("selectionPolicy: .auto"))
        XCTAssertTrue(clientSource.contains("nativeFallbackEnabled: true"))
        XCTAssertTrue(clientSource.contains("public var onEnvelope: (@Sendable (WebRTCSignalingEnvelope) async -> Void)?"))
        XCTAssertTrue(clientSource.contains("await onEnvelope?(env)"))
        XCTAssertTrue(nativeSource.contains("public var onText: (@Sendable (String) async -> Void)?"))
        XCTAssertTrue(nativeSource.contains("await callbacks.onText?(text)"))
        assertSourceOrder(
            in: nativeSource,
            first: "await callbacks.onText?(text)",
            second: "continueReceiveIfNeeded(on: conn, generation: generation)"
        )
        XCTAssertTrue(managerSource.contains(
            "#if DEBUG || SKYBRIDGE_TESTING\n        await newSignaling.setOnTrace"
        ))
    }

    func testNativeWebSocketParametersHonorPreferNoProxies() {
        let directParameters = NativeWebSocketClient.testOnlyBuildParameters(
            tls: true,
            pingInterval: 30,
            preferNoProxies: true
        )
        XCTAssertTrue(directParameters.preferNoProxies)

        let defaultParameters = NativeWebSocketClient.testOnlyBuildParameters(
            tls: true,
            pingInterval: 30,
            preferNoProxies: false
        )
        XCTAssertFalse(defaultParameters.preferNoProxies)
    }

    @MainActor
    func testConnectingSessionCanScheduleSignalingRecoveryBeforeTransportReady() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: false,
                isSessionConnecting: true,
                suppressRecovery: false
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: false,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: true,
                suppressRecovery: true
            )
        )
    }

    func testInitialWebRTCHandshakeStartsFromOffererOnly() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldInitiateInitialWebRTCHandshake(role: .offerer)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldInitiateInitialWebRTCHandshake(role: .answerer)
        )
    }

    func testInitialWebRTCHandshakeUsesClassicForAuthorityBoundQRAndCodeSessions() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                localConnectionSessionId: nil
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "local-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                localConnectionSessionId: "local-session"
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                localConnectionSessionId: nil
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "pqc-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .mlDSA65,
                localConnectionSessionId: nil
            )
        )
    }

    @MainActor
    func testRedeemedQRSessionArtifactsReuseRequiresMatchingOriginAndAuthority() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldReuseRedeemedQRSessionArtifacts(
                canonicalQRSignalingOrigin: "https://signal.example.com",
                qrDeviceId: "device-a",
                qrProtocolSigningAlgorithm: .ed25519,
                qrProtocolPublicKeyFingerprint: "fingerprint-a",
                qrProtocolPublicKeyBytes: Data([0xAA, 0xBB]),
                signalingToken: " session-token ",
                turnAdmissionToken: " turn-token ",
                cachedSignalingOrigin: "https://signal.example.com",
                cachedAuthorityDeviceId: "device-a",
                cachedAuthorityProtocolSigningAlgorithm: .ed25519,
                cachedAuthorityProtocolPublicKeyFingerprint: "fingerprint-a",
                cachedAuthorityProtocolPublicKeyBytes: Data([0xAA, 0xBB])
            )
        )

        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldReuseRedeemedQRSessionArtifacts(
                canonicalQRSignalingOrigin: "https://signal.example.com",
                qrDeviceId: "device-a",
                qrProtocolSigningAlgorithm: .ed25519,
                qrProtocolPublicKeyFingerprint: "fingerprint-a",
                qrProtocolPublicKeyBytes: Data([0xAA, 0xBB]),
                signalingToken: "session-token",
                turnAdmissionToken: "turn-token",
                cachedSignalingOrigin: "https://other.example.com",
                cachedAuthorityDeviceId: "device-a",
                cachedAuthorityProtocolSigningAlgorithm: .ed25519,
                cachedAuthorityProtocolPublicKeyFingerprint: "fingerprint-a",
                cachedAuthorityProtocolPublicKeyBytes: Data([0xAA, 0xBB])
            )
        )

        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldReuseRedeemedQRSessionArtifacts(
                canonicalQRSignalingOrigin: "https://signal.example.com",
                qrDeviceId: "device-a",
                qrProtocolSigningAlgorithm: .ed25519,
                qrProtocolPublicKeyFingerprint: "fingerprint-a",
                qrProtocolPublicKeyBytes: Data([0xAA, 0xBB]),
                signalingToken: "session-token",
                turnAdmissionToken: "turn-token",
                cachedSignalingOrigin: "https://signal.example.com",
                cachedAuthorityDeviceId: "device-a",
                cachedAuthorityProtocolSigningAlgorithm: .ed25519,
                cachedAuthorityProtocolPublicKeyFingerprint: "fingerprint-b",
                cachedAuthorityProtocolPublicKeyBytes: Data([0xAA, 0xBB])
            )
        )
    }

    @MainActor
    func testActualNativeRenderEvidenceRequiresRendererCallback() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("rtc-mtl-video-view")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("heartbeat-renderer")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("fallback-screen-data-confirmed")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("receiver-stats")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence(
                "receiver-packet-confirmed:fallback-screen-data-confirmed"
            )
        )
    }

    @MainActor
    func testSessionScopedSignalingURLFollowsCurrentPathEndpoint() {
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "https://signal.example.com:8443",
            signalingWebSocketPath: "/tenant/ws"
        )
        XCTAssertEqual(resolved, "wss://signal.example.com:8443/tenant/ws")
    }

    @MainActor
    func testSessionScopedSignalingURLRejectsPublicCleartextButAllowsLoopback() {
        XCTAssertNil(
            CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
                signalingOrigin: "http://signal.example.com:8080",
                signalingWebSocketPath: "/tenant/ws"
            )
        )

        XCTAssertEqual(
            CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
                signalingOrigin: "http://127.0.0.1:8787",
                signalingWebSocketPath: "/tenant/ws"
            ),
            "ws://127.0.0.1:8787/tenant/ws"
        )

        XCTAssertEqual(
            try CurrentPathSecurityCompat.canonicalOrigin("http://[::1]:8787"),
            "http://[::1]:8787"
        )
    }

    @MainActor
    func testSessionScopedSignalingURLFailsClosedForInvalidOrigin() {
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "not a url",
            signalingWebSocketPath: "/tenant/ws"
        )
        XCTAssertNil(resolved)
    }

    @MainActor
    func testSessionScopedSignalingURLFailsClosedForInvalidWebSocketPath() {
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "https://signal.example.com:8443",
            signalingWebSocketPath: "tenant/ws?fallback=/ws"
        )
        XCTAssertNil(resolved)
    }

    @MainActor
    func testSessionScopedSignalingURLRejectsUnsafeWebSocketPaths() {
        for unsafePath in [
            "/../ws",
            "/tenant//ws",
            "/%2e%2e/ws",
            "/%2F/ws",
            "/tenant\\ws",
            "/租户/ws",
            "/" + String(repeating: "a", count: CurrentPathSignalingWebSocketPolicyCompat.maxWebSocketPathLength)
        ] {
            XCTAssertNil(
                CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
                    signalingOrigin: "https://signal.example.com:8443",
                    signalingWebSocketPath: unsafePath
                ),
                "expected unsafe websocket path to fail closed: \(unsafePath)"
            )
        }
    }

    @MainActor
    func testCurrentPathSignalingQueryTokenModeKeepsSessionCredentialsOutOfHeaders() throws {
        let url = try XCTUnwrap(
            CurrentPathSignalingWebSocketPolicyCompat.webSocketURL(
                signalingServerOrigin: "https://signal.example.com:8443",
                wsPath: "/tenant/ws",
                sessionID: "session-1",
                sessionToken: "token-1",
                clientVersion: "1.2.3",
                protocolVersion: "2",
                credentialTransport: .queryToken
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(components.path, "/tenant/ws")
        XCTAssertEqual(queryItems["shard"], "SESSION-1")
        XCTAssertEqual(queryItems["st"], "token-1")
        XCTAssertEqual(queryItems["cv"], "1.2.3")
        XCTAssertEqual(queryItems["pv"], "2")

        let headers = try XCTUnwrap(
            CurrentPathSignalingWebSocketPolicyCompat.webSocketHeaders(
                sessionID: "session-1",
                sessionToken: "token-1",
                clientVersion: "1.2.3",
                protocolVersion: "2",
                credentialTransport: .queryToken
            )
        )
        XCTAssertEqual(headers["X-SkyBridge-Client-Version"], "1.2.3")
        XCTAssertEqual(headers["X-SkyBridge-Protocol-Version"], "2")
        XCTAssertNil(headers["X-SkyBridge-Session-Id"])
        XCTAssertNil(headers["X-SkyBridge-Session"])
    }

    @MainActor
    func testCurrentPathWebSocketPathValidationDistinguishesMissingFromInvalid() {
        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.instance.validateCurrentPathWebSocketPath(nil)
        ) { error in
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "missing current-path signaling websocket path"
            )
        }

        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.instance.validateCurrentPathWebSocketPath("tenant/ws")
        ) { error in
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "invalid current-path signaling websocket path"
            )
        }
    }

    func testCurrentPathArtifactsValidateEndpointBeforeCachingTokens() throws {
        let source = try repositorySource(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )

        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "public func connect(withCode rawCode: String)",
            sectionEnd: "public func generateConnectionCode()",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lookup.signalingServerOrigin,\n                wsPath: lookup.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "public func generateConnectionCode()",
            sectionEnd: "private func scheduleConnectionCodeLeaseInvalidation",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lease.signalingServerOrigin,\n                wsPath: lease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "public func generateConnectLink",
            sectionEnd: "public func disconnect",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lease.signalingServerOrigin,\n                wsPath: lease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "private func parseSkybridgeConnectLink",
            sectionEnd: "nonisolated private static func normalizedNonEmptyToken",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n            origin: redeemed.signalingServerOrigin,\n            wsPath: redeemed.wsPath\n        )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[qr.sessionID] = redeemed.sessionToken"
        )
        XCTAssertFalse(source.contains("cacheCurrentPathSignalingEndpoint("))
    }

    func testStrictPQCRekeyRequiresSignedCurrentPathKEMLookup() throws {
        let source = try repositorySource(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        guard let startRange = source.range(of: "func maybeStartPQCRekeyOverWebRTC("),
              let endRange = source.range(of: "\n}\n\n@available(iOS 17.0, *)\nprivate extension CrossNetworkWebRTCManager", range: startRange.upperBound..<source.endIndex) else {
            XCTFail("Missing WebRTC rekey source section")
            return
        }
        let section = String(source[startRange.lowerBound..<endRange.lowerBound])

        XCTAssertTrue(section.contains("reason: \"missing_current_path_authority\""))
        XCTAssertTrue(section.contains("let requiresSignedCurrentPathKEM = strictPQCRequested"))
        XCTAssertTrue(section.contains("|| currentPathExpectedRemoteAuthorityBySessionId[sessionId] != nil"))
        XCTAssertTrue(section.contains("trustedKeysByCandidateId[candidateId] = await trustedCurrentPathKEMPublicKeys("))
        XCTAssertTrue(section.contains("trustedKeysByCandidateId[candidateId] = await KEMTrustStore.shared.kemPublicKeys(for: candidateId)"))
        assertSourceOrder(
            in: section,
            first: "if requiresSignedCurrentPathKEM {",
            second: "trustedKeysByCandidateId[candidateId] = await KEMTrustStore.shared.kemPublicKeys(for: candidateId)"
        )
    }

    func testCurrentPathLeaseDecodingPreservesSignalingWebSocketPath() throws {
        let registerData = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "SESSION123",
                "sessionToken": "session-token",
                "qrBootstrapToken": "qr-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws"
            ],
            options: [.sortedKeys]
        )
        let sessionLease = try SignalServerClientCompat.testOnlyDecodeRegisterSessionResponse(registerData)
        XCTAssertEqual(sessionLease.signalingServerOrigin, "https://signal.example.com")
        XCTAssertEqual(sessionLease.wsPath, "/tenant/ws")

        let lookupData = try JSONSerialization.data(
            withJSONObject: [
                "found": true,
                "sessionId": "SESSION123",
                "sessionToken": "responder-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws",
                "initiatorDeviceId": "device-123",
                "initiatorProtocolSigningAlgorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                "initiatorProtocolPublicKeyFingerprint": "fingerprint-123",
                "initiatorDeviceName": "SkyBridge Mac"
            ],
            options: [.sortedKeys]
        )
        let lookup = try SignalServerClientCompat.testOnlyDecodeLookupConnectionCodeResponse(lookupData)
        XCTAssertEqual(lookup.signalingServerOrigin, "https://signal.example.com")
        XCTAssertEqual(lookup.wsPath, "/tenant/ws")
    }

    func testCurrentPathLeaseDecodingRejectsIncompleteResponses() throws {
        let registerCodeMissingToken = try JSONSerialization.data(
            withJSONObject: [
                "code": "ABC12345",
                "sessionId": "SESSION123",
                "turnAdmissionToken": "turn-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws"
            ],
            options: [.sortedKeys]
        )
        assertSignalServerCompatMalformedResponse("register code missing token") {
            _ = try SignalServerClientCompat.testOnlyDecodeRegisterCodeResponse(registerCodeMissingToken)
        }

        let registerSessionZeroExpiry = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "SESSION123",
                "sessionToken": "session-token",
                "qrBootstrapToken": "qr-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 0,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws"
            ],
            options: [.sortedKeys]
        )
        assertSignalServerCompatMalformedResponse("register session zero expiry") {
            _ = try SignalServerClientCompat.testOnlyDecodeRegisterSessionResponse(registerSessionZeroExpiry)
        }

        let lookupUnknownAlgorithm = try JSONSerialization.data(
            withJSONObject: [
                "found": true,
                "sessionId": "SESSION123",
                "sessionToken": "responder-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws",
                "initiatorDeviceId": "device-123",
                "initiatorProtocolSigningAlgorithm": "P-256-ECDSA",
                "initiatorProtocolPublicKeyFingerprint": "fingerprint-123",
                "initiatorDeviceName": "SkyBridge Mac"
            ],
            options: [.sortedKeys]
        )
        assertSignalServerCompatMalformedResponse("lookup unknown protocol signing algorithm") {
            _ = try SignalServerClientCompat.testOnlyDecodeLookupConnectionCodeResponse(lookupUnknownAlgorithm)
        }
    }

    func testCurrentPathSessionRefreshRequiresSignalingWebSocketPath() throws {
        let validRefreshData = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "SESSION123",
                "role": "responder",
                "sessionToken": "session-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws",
                "serverBuildFingerprint": "test-build",
                "sessionTokenGeneration": "session-generation",
                "mediaTokenGeneration": "media-generation"
            ],
            options: [.sortedKeys]
        )
        let refresh = try SignalServerClientCompat.testOnlyDecodeSessionRefreshResponse(
            validRefreshData,
            sessionId: "SESSION123",
            role: "responder"
        )
        XCTAssertEqual(refresh.signalingServerOrigin, "https://signal.example.com")
        XCTAssertEqual(refresh.wsPath, "/tenant/ws")

        let missingPathData = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "SESSION123",
                "role": "responder",
                "sessionToken": "session-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com"
            ],
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try SignalServerClientCompat.testOnlyDecodeSessionRefreshResponse(
                missingPathData,
                sessionId: "SESSION123",
                role: "responder"
            )
        )
    }

    @MainActor
    func testSignalingRecoveryIsSuppressedDuringLocalTeardown() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: false,
                suppressRecovery: true
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: false,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
    }

    @MainActor
    func testPostTransportICEFailuresDeferToSharedRecovery() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: false,
                messageType: .iceCandidate
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: false,
                messageType: .offer
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: false,
                messageType: .leave
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: true,
                messageType: .iceCandidate
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: false,
                suppressRecovery: false,
                messageType: .iceCandidate
            )
        )
    }
}

private enum WebRTCSignalingFaultInjectionTestError: Error {
    case reconnectFailed
    case timedOut
}

@available(iOS 17.0, *)
private func framedPayload(_ payload: Data) -> Data {
    var framed = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
    framed.append(payload)
    return framed
}

@available(iOS 17.0, *)
private func repositorySource(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(relativePath)
    return try readRepositorySourceForSourceShapeTests(at: sourceURL)
}

@available(iOS 17.0, *)
private func assertEndpointValidationPrecedesTokenCaching(
    in source: String,
    sectionStart: String,
    sectionEnd: String,
    endpointVariable: String,
    tokenWrite: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let startRange = source.range(of: sectionStart),
          let endRange = source.range(of: sectionEnd, range: startRange.upperBound..<source.endIndex) else {
        XCTFail("Missing source section \(sectionStart)", file: file, line: line)
        return
    }
    let section = source[startRange.lowerBound..<endRange.lowerBound]
    guard let endpointRange = section.range(of: endpointVariable),
          let tokenRange = section.range(of: tokenWrite) else {
        XCTFail("Missing endpoint validation or token write in \(sectionStart)", file: file, line: line)
        return
    }
    XCTAssertLessThan(endpointRange.lowerBound, tokenRange.lowerBound, file: file, line: line)
}

@available(iOS 17.0, *)
private func assertSignalServerCompatMalformedResponse(
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () throws -> Void
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        guard case SignalServerClientCompat.ClientError.malformedResponse = error else {
            XCTFail("Expected malformed response for \(label), got \(error)", file: file, line: line)
            return
        }
    }
}

@available(iOS 17.0, *)
private func assertSourceOrder(
    in source: String,
    first: String,
    second: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let firstRange = source.range(of: first),
          let secondRange = source.range(of: second) else {
        XCTFail("Missing source fragments for order assertion", file: file, line: line)
        return
    }
    XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound, file: file, line: line)
}

@available(iOS 17.0, *)
private actor RetryProbe {
    private var attempts: Int = 0
    private var reconnects: Int = 0
    private var sleeps: Int = 0

    func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }

    func recordReconnect() {
        reconnects += 1
    }

    func recordSleep(_ duration: Duration) {
        _ = duration
        sleeps += 1
    }

    func attemptCount() -> Int { attempts }
    func reconnectCount() -> Int { reconnects }
    func sleepCount() -> Int { sleeps }
}

@available(iOS 17.0, *)
private actor AsyncOneShotTestLatch {
    private var isSignaled = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let waitingContinuation = waiter
        waiter = nil
        waitingContinuation?.resume(returning: true)
    }

    func wait(timeout: Duration) async -> Bool {
        if isSignaled { return true }
        precondition(waiter == nil, "AsyncOneShotTestLatch supports exactly one waiter")

        return await withCheckedContinuation { continuation in
            if isSignaled {
                continuation.resume(returning: true)
                return
            }

            waiter = continuation
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.timeOutWaiterIfNeeded()
                    return
                }
                await self?.timeOutWaiterIfNeeded()
            }
        }
    }

    private func timeOutWaiterIfNeeded() {
        guard !isSignaled, let waitingContinuation = waiter else { return }
        timeoutTask = nil
        waiter = nil
        waitingContinuation.resume(returning: false)
    }
}

private enum AuthRequestTestError: Error {
    case unexpectedRefresh
    case timedOutWaitingForConcurrentLoads
    case timedOutWaitingForRequestCancellation
    case timedOutWaitingForRegistrationRequest
    case timedOutWaitingForAuthorityRecovery
    case missingRequestBody
    case requestBodyTooLarge
    case malformedRequestBody
}

@available(iOS 17.0, *)
private func makeAuthTestJWT(
    subject: String,
    tenantID: String,
    expiration: TimeInterval
) throws -> String {
    func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    let header = try JSONSerialization.data(
        withJSONObject: ["alg": "ES256", "typ": "JWT"],
        options: [.sortedKeys]
    )
    let payload = try JSONSerialization.data(
        withJSONObject: [
            "sub": subject,
            "app_metadata": ["tenant_id": tenantID],
            "exp": expiration
        ],
        options: [.sortedKeys]
    )
    return "\(base64URL(header)).\(base64URL(payload)).test-signature"
}

@available(iOS 17.0, *)
private func makeAuthTestSession(
    token: String,
    refreshToken: String? = nil,
    userID: String,
    tenantID: String
) -> AuthSession {
    AuthSession(
        accessToken: token,
        refreshToken: refreshToken,
        userIdentifier: userID,
        displayName: "Test User",
        nebulaId: tenantID,
        issuedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
}

@available(iOS 17.0, *)
private func makeAuthTestProtocolBinding() throws -> ProtocolIdentityBindingCompat {
    try ProtocolIdentityBindingCompat(
        deviceId: "test-device-0001",
        protocolSigningAlgorithm: .ed25519,
        protocolPublicKeyBytes: Data(repeating: 0xA5, count: 32)
    )
}

@available(iOS 17.0, *)
private func makeAuthenticatedRequestTestURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AuthenticatedRequestURLProtocol.self]
    return URLSession(configuration: configuration)
}

@available(iOS 17.0, *)
private func waitForAuthSessionLoads(
    _ repository: AuthSessionRepositoryProbe,
    minimumCount: Int
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await repository.loadCount() < minimumCount {
        guard clock.now < deadline else {
            throw AuthRequestTestError.timedOutWaitingForConcurrentLoads
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@available(iOS 17.0, *)
private actor SequentialAuthSessionLoader {
    private let sessions: [AuthSession]
    private var loads = 0

    init(sessions: [AuthSession]) {
        precondition(!sessions.isEmpty)
        self.sessions = sessions
    }

    func load() -> AuthSession? {
        defer { loads += 1 }
        return sessions[min(loads, sessions.count - 1)]
    }

    func loadCount() -> Int { loads }
}

@available(iOS 17.0, *)
private actor AuthSessionRepositoryProbe {
    private var session: AuthSession
    private var loads = 0
    private var replacements = 0

    init(session: AuthSession) {
        self.session = session
    }

    func load() -> AuthSession? {
        loads += 1
        return session
    }

    func replace(expected: AuthSession, with replacement: AuthSession) -> Bool {
        guard session == expected else { return false }
        session = replacement
        replacements += 1
        return true
    }

    func loadCount() -> Int { loads }
    func replaceCount() -> Int { replacements }
}

@available(iOS 17.0, *)
private actor BlockingAuthRefreshProbe {
    private let response: AuthSession
    private var count = 0
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(response: AuthSession) {
        self.response = response
    }

    func refresh(token: String) async throws -> AuthSession {
        guard token == "refresh-original" else {
            throw AuthRequestTestError.unexpectedRefresh
        }
        count += 1
        if !isReleased {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return response
    }

    func release() {
        isReleased = true
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }

    func refreshCount() -> Int { count }
}

@available(iOS 17.0, *)
private actor BlockingAuthorityRecoveryProbe {
    private var count = 0
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func recover() async -> Bool {
        count += 1
        if !isReleased {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return true
    }

    func release() {
        isReleased = true
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }

    func recoveryCount() -> Int { count }
}

@available(iOS 17.0, *)
private final class AuthenticatedRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let maximumRequestBodyBytes = 64 * 1_024
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var registrationFingerprintOverride: String?
    nonisolated(unsafe) private static var registrationUserIDOverride: String?
    nonisolated(unsafe) private static var rotationChallengeTenantIDOverride: String?
    nonisolated(unsafe) private static var rotationChallengeUserIDOverride: String?
    nonisolated(unsafe) private static var blockedRegistrationBudget = 0
    nonisolated(unsafe) private static var registrationStopCount = 0
    nonisolated(unsafe) private static var registrationEvents: [String] = []
    private let instanceLock = NSLock()
    private var isBlockingRegistration = false
    private var blockingRegistrationTenantID: String?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let tenantID = request.value(forHTTPHeaderField: "X-SkyBridge-Tenant-Id") ?? "missing"
        let body: [String: Any]
        var capturedRequest = request
        if request.url?.path == "/api/devices/identity-rotation/challenge" {
            do {
                let requestData = try Self.requestBodyData(from: request)
                capturedRequest.httpBodyStream = nil
                capturedRequest.httpBody = requestData
                body = try Self.makeIdentityRotationChallengeResponse(
                    request: request,
                    requestData: requestData,
                    authenticatedTenantID: tenantID
                )
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        } else if request.url?.path == "/api/devices/register-current" {
            let requestData: Data
            let requestDeviceID: String
            let requestSigningAlgorithm: String
            let requestFingerprint: String
            let requestDeviceName: String
            do {
                requestData = try Self.requestBodyData(from: request)
                guard let decoded = try JSONSerialization.jsonObject(with: requestData)
                    as? [String: Any],
                      let deviceID = decoded["deviceId"] as? String,
                      let signingAlgorithm = decoded["protocolSigningAlgorithm"] as? String,
                      let fingerprint = decoded["protocolPublicKeyFingerprint"] as? String,
                      let deviceName = decoded["deviceName"] as? String else {
                    throw AuthRequestTestError.malformedRequestBody
                }
                requestDeviceID = deviceID
                requestSigningAlgorithm = signingAlgorithm
                requestFingerprint = fingerprint
                requestDeviceName = deviceName
                capturedRequest.httpBodyStream = nil
                capturedRequest.httpBody = requestData
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            Self.lock.lock()
            let overriddenFingerprint = Self.registrationFingerprintOverride
            let overriddenUserID = Self.registrationUserIDOverride
            Self.lock.unlock()
            body = [
                "registered": true,
                "activated": true,
                "device": [
                    "tenant_id": tenantID,
                    "user_id": overriddenUserID ?? "user-123",
                    "device_id": requestDeviceID,
                    "protocol_signing_algorithm": requestSigningAlgorithm,
                    "protocol_public_key_fingerprint": overriddenFingerprint
                        ?? requestFingerprint,
                    "device_name": requestDeviceName,
                    "status": "active",
                    "approval_method": "authenticated-bootstrap"
                ]
            ]
        } else {
            body = [
                "challengeId": "challenge-123",
                "nonce": "nonce-123",
                "tenantId": tenantID,
                "userId": "user-123",
                "deviceId": "test-device-0001",
                "clientIpHash": "client-ip-hash",
                "clientVersion": "1.0.0",
                "protocolVersion": "1",
                "state": "pending",
                "issuedAt": 2_000_000_000_000 as Int64,
                "expiresAt": 2_000_000_060_000 as Int64
            ]
        }
        Self.lock.lock()
        let shouldBlockRegistration = request.url?.path == "/api/devices/register-current"
            && Self.blockedRegistrationBudget > 0
        if request.url?.path == "/api/devices/register-current" {
            Self.registrationEvents.append("start:\(tenantID)")
        }
        if shouldBlockRegistration {
            Self.blockedRegistrationBudget -= 1
            instanceLock.lock()
            isBlockingRegistration = true
            blockingRegistrationTenantID = tenantID
            instanceLock.unlock()
        }
        Self.capturedRequests.append(capturedRequest)
        Self.lock.unlock()
        if shouldBlockRegistration {
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if request.url?.path == "/api/devices/register-current" {
                Self.lock.lock()
                Self.registrationEvents.append("finish:\(tenantID)")
                Self.lock.unlock()
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        instanceLock.lock()
        let wasBlockingRegistration = isBlockingRegistration
        let stoppedTenantID = blockingRegistrationTenantID
        isBlockingRegistration = false
        blockingRegistrationTenantID = nil
        instanceLock.unlock()
        if wasBlockingRegistration {
            Self.registrationStopCount += 1
            if let stoppedTenantID {
                Self.registrationEvents.append("stop:\(stoppedTenantID)")
            }
        }
        Self.lock.unlock()
    }

    private static func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            guard !body.isEmpty else { throw AuthRequestTestError.missingRequestBody }
            guard body.count <= maximumRequestBodyBytes else {
                throw AuthRequestTestError.requestBodyTooLarge
            }
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw AuthRequestTestError.missingRequestBody
        }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if bytesRead == 0 {
                break
            }
            guard body.count <= maximumRequestBodyBytes - bytesRead else {
                throw AuthRequestTestError.requestBodyTooLarge
            }
            body.append(buffer, count: bytesRead)
        }
        guard !body.isEmpty else { throw AuthRequestTestError.missingRequestBody }
        return body
    }

    private static func makeIdentityRotationChallengeResponse(
        request: URLRequest,
        requestData: Data,
        authenticatedTenantID: String
    ) throws -> [String: Any] {
        guard let decoded = try JSONSerialization.jsonObject(with: requestData)
                as? [String: Any],
              let requestID = request.value(forHTTPHeaderField: "Idempotency-Key"),
              let deviceID = decoded["deviceId"] as? String,
              let oldAlgorithmRaw = decoded["protocolSigningAlgorithm"] as? String,
              let oldAlgorithm = ProtocolSigningAlgorithm(rawValue: oldAlgorithmRaw),
              let oldFingerprint = decoded["protocolPublicKeyFingerprint"] as? String,
              let oldPublicKeyBase64 = decoded["protocolPublicKeyBytes"] as? String,
              let oldPublicKey = Data(base64Encoded: oldPublicKeyBase64),
              let newAlgorithmRaw = decoded["newProtocolSigningAlgorithm"] as? String,
              let newAlgorithm = ProtocolSigningAlgorithm(rawValue: newAlgorithmRaw),
              let newFingerprint = decoded["newProtocolPublicKeyFingerprint"] as? String,
              let newPublicKeyBase64 = decoded["newProtocolPublicKeyBytes"] as? String,
              let newPublicKey = Data(base64Encoded: newPublicKeyBase64),
              let clientVersion = decoded["clientVersion"] as? String,
              let protocolVersion = decoded["protocolVersion"] as? String else {
            throw AuthRequestTestError.malformedRequestBody
        }

        lock.lock()
        let tenantID = rotationChallengeTenantIDOverride ?? authenticatedTenantID
        let userID = rotationChallengeUserIDOverride ?? "user-123"
        lock.unlock()

        let oldIdentity = try ProtocolIdentityBindingCompat(
            deviceId: deviceID,
            protocolSigningAlgorithm: oldAlgorithm,
            protocolPublicKeyBytes: oldPublicKey,
            protocolPublicKeyFingerprint: oldFingerprint
        )
        let newIdentity = try ProtocolIdentityBindingCompat(
            deviceId: deviceID,
            protocolSigningAlgorithm: newAlgorithm,
            protocolPublicKeyBytes: newPublicKey,
            protocolPublicKeyFingerprint: newFingerprint
        )
        let rotationID = "11111111-2222-4333-8444-555555555555"
        let issuedAt: Int64 = 2_000_000_000_000
        let expiresAt: Int64 = issuedAt + 60_000
        let nonce = Data(repeating: 0xC3, count: 32)
        let transcript = try DeviceIdentityRotationTranscriptCompat(
            rotationID: rotationID,
            nonce: nonce,
            expiresAtMilliseconds: expiresAt,
            tenantID: tenantID,
            userID: userID,
            deviceID: deviceID,
            oldGeneration: 7,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity
        )
        let canonicalNonce = nonce.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return [
            "requestId": requestID,
            "rotationId": rotationID,
            "nonce": canonicalNonce,
            "state": "issued",
            "issuedAt": issuedAt,
            "expiresAt": expiresAt,
            "transcriptVersion": Int(DeviceIdentityRotationTranscriptCompat.version),
            "transcriptHash": transcript.sha256Hex,
            "transcriptBase64": transcript.encoded.base64EncodedString(),
            "tenantId": tenantID,
            "userId": userID,
            "deviceId": deviceID,
            "oldGeneration": 7,
            "oldProtocolSigningAlgorithm": oldAlgorithm.rawValue,
            "oldProtocolPublicKeyFingerprint": oldFingerprint,
            "newProtocolSigningAlgorithm": newAlgorithm.rawValue,
            "newProtocolPublicKeyFingerprint": newFingerprint,
            "clientVersion": clientVersion,
            "protocolVersion": protocolVersion
        ]
    }

    static func reset() {
        lock.lock()
        capturedRequests.removeAll(keepingCapacity: false)
        registrationFingerprintOverride = nil
        registrationUserIDOverride = nil
        rotationChallengeTenantIDOverride = nil
        rotationChallengeUserIDOverride = nil
        blockedRegistrationBudget = 0
        registrationStopCount = 0
        registrationEvents.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    static func blockNextRegistration() {
        lock.lock()
        blockedRegistrationBudget += 1
        lock.unlock()
    }

    static func blockedRegistrationStopCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return registrationStopCount
    }

    static func recordedRegistrationEvents() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return registrationEvents
    }

    static func setRegistrationFingerprintOverride(_ value: String?) {
        lock.lock()
        registrationFingerprintOverride = value
        lock.unlock()
    }

    static func setRegistrationUserIDOverride(_ value: String?) {
        lock.lock()
        registrationUserIDOverride = value
        lock.unlock()
    }

    static func setRotationChallengeScopeOverride(
        tenantID: String?,
        userID: String?
    ) {
        lock.lock()
        rotationChallengeTenantIDOverride = tenantID
        rotationChallengeUserIDOverride = userID
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }
}

@available(iOS 17.0, *)
private func makeSignalingBoundaryAuthenticationDependencies() throws
    -> SignalServerClientCompat.AuthenticationDependencies {
    let token = try makeAuthTestJWT(
        subject: "boundary-user",
        tenantID: "boundary-tenant",
        expiration: 4_102_444_800
    )
    let session = makeAuthTestSession(
        token: token,
        userID: "boundary-user",
        tenantID: "boundary-tenant"
    )
    return SignalServerClientCompat.AuthenticationDependencies(
        accessTokenOverride: { "" },
        tenantIDOverride: { "" },
        loadPersistedSession: { session },
        refreshSession: { _ in throw AuthRequestTestError.unexpectedRefresh },
        validateRefreshedAccessToken: { _ in throw AuthRequestTestError.unexpectedRefresh },
        replacePersistedSession: { _, _ in throw AuthRequestTestError.unexpectedRefresh }
    )
}

@available(iOS 17.0, *)
private func makeSignalingBoundaryURLSession(_ protocolClass: AnyClass) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return URLSession(configuration: configuration)
}

@available(iOS 17.0, *)
private func waitForHangingSignalingRequestCancellation() async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !HangingSignalingURLProtocol.wasStopped {
        guard clock.now < deadline else {
            throw AuthRequestTestError.timedOutWaitingForRequestCancellation
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@available(iOS 17.0, *)
private class SignalingBoundaryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    func makeResponse(contentLength: Int? = nil) -> HTTPURLResponse? {
        guard let url = request.url else { return nil }
        var headers = ["Content-Type": "application/json"]
        if let contentLength {
            headers["Content-Length"] = String(contentLength)
        }
        return HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }

    override func stopLoading() {}
}

@available(iOS 17.0, *)
private final class OversizedSignalingURLProtocol: SignalingBoundaryURLProtocol, @unchecked Sendable {
    override func startLoading() {
        // Intentionally omit Content-Length: the incremental byte cap must remain
        // authoritative when the peer does not declare a response size.
        guard let response = makeResponse() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 1_024))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@available(iOS 17.0, *)
private final class TimedOutSignalingURLProtocol: SignalingBoundaryURLProtocol, @unchecked Sendable {
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
}

@available(iOS 17.0, *)
private final class HangingSignalingURLProtocol: SignalingBoundaryURLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stopped = false

    override func startLoading() {
        guard let response = makeResponse() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopped = true
        Self.lock.unlock()
    }

    static func reset() {
        lock.lock()
        stopped = false
        lock.unlock()
    }

    static var wasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Bool = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
