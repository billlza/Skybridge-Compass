import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class ConnectionCodeFormatTests: XCTestCase {
    func testSmokeArtifactBasenameAcceptsOnlyBoundedLeafNames() throws {
        for rawValue in [
            "skybridge-smoke-status.log",
            "ios-real-webrtc-01234567.status.log",
            "ios_round_3.pqc.json",
        ] {
            let basename = try SmokeArtifactBasename(rawValue)
            XCTAssertEqual(basename.value, rawValue)
        }

        let invalidValues = [
            "",
            " ",
            ".",
            "..",
            "../status.log",
            "/tmp/status.log",
            "nested/status.log",
            "nested\\status.log",
            "status\n.log",
            " status.log",
            "status.log ",
            "状态.log",
            String(repeating: "a", count: SmokeArtifactBasename.maximumUTF8Length + 1),
        ]
        for rawValue in invalidValues {
            XCTAssertThrowsError(try SmokeArtifactBasename(rawValue), "unexpectedly accepted: \(rawValue.debugDescription)")
        }
    }

    func testSmokeArtifactBasenameResolvesInsideConfiguredDirectory() throws {
        let directory = URL(fileURLWithPath: "/tmp/skybridge-smoke-basename-test", isDirectory: true)
        let resolved = try XCTUnwrap(
            SmokeArtifactBasename.resolve(
                environmentValue: nil,
                defaultValue: "ios.status.log"
            )
        )
        let url = resolved.url(in: directory)

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "ios.status.log")
        XCTAssertNil(try SmokeArtifactBasename.resolve(environmentValue: nil))
    }

    func testSmokeListenerArtifactConfigurationFailsClosed() throws {
        let cachesDirectory = URL(
            fileURLWithPath: "/tmp/skybridge-smoke-listener-configuration",
            isDirectory: true
        )
        XCTAssertNil(
            try SkyBridgeDiagnosticTrace.resolveListenerStatusURLForTesting(
                environment: [:],
                cachesDirectory: nil
            )
        )
        XCTAssertNil(
            try SkyBridgeDiagnosticTrace.resolveListenerStatusURLForTesting(
                environment: ["SKYBRIDGE_SMOKE_ROLE": "ios-listener"],
                cachesDirectory: cachesDirectory
            )
        )
        XCTAssertThrowsError(
            try SkyBridgeDiagnosticTrace.resolveListenerStatusURLForTesting(
                environment: [
                    "SKYBRIDGE_SMOKE_ROLE": "ios-listener",
                    "SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME": "../listener.log",
                ],
                cachesDirectory: cachesDirectory
            )
        )
        XCTAssertThrowsError(
            try SkyBridgeDiagnosticTrace.resolveListenerStatusURLForTesting(
                environment: [
                    "SKYBRIDGE_SMOKE_ROLE": "ios-listener",
                    "SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME": "listener.log",
                ],
                cachesDirectory: nil
            )
        )

        let resolved = try SkyBridgeDiagnosticTrace.resolveListenerStatusURLForTesting(
            environment: [
                "SKYBRIDGE_SMOKE_ROLE": "ios-listener",
                "SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME": "listener.log",
            ],
            cachesDirectory: cachesDirectory
        )
        XCTAssertEqual(resolved, cachesDirectory.appendingPathComponent("listener.log"))
    }

    func testSmokeStatusReporterResetPropagatesProtectedWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-smoke-reporter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let blockingParent = root.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("occupied".utf8).write(to: blockingParent, options: .atomic)
        let reporter = SmokeStatusReporter(
            statusURL: blockingParent.appendingPathComponent("status.log", isDirectory: false)
        )

        XCTAssertThrowsError(try reporter.reset())
    }

    func testSmokeStatusReporterResetTruncatesStatusAndAppliesDataProtection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-smoke-reset-\(UUID().uuidString)", isDirectory: true)
        let statusURL = root.appendingPathComponent("status.log", isDirectory: false)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let reporter = SmokeStatusReporter(statusURL: statusURL)
        reporter.append("stale success evidence")
        XCTAssertFalse(try Data(contentsOf: statusURL).isEmpty)

        try reporter.reset()

        XCTAssertTrue(try Data(contentsOf: statusURL).isEmpty)
        XCTAssertTrue(SmokeArtifactFileIO.hasConfiguredProtectionAttribute(at: statusURL))
#if targetEnvironment(simulator)
        // Simulator host filesystems do not consistently surface NSFileProtectionKey even after
        // the throwing FileManager.setAttributes call has completed successfully.
#else
        let attributes = try FileManager.default.attributesOfItem(atPath: statusURL.path)
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
#endif
    }

    func testSmokeStatusArtifactResetPropagatesListenerFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-smoke-listener-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let primaryURL = root.appendingPathComponent("primary.log", isDirectory: false)
        try Data("stale success evidence\n".utf8).write(to: primaryURL, options: .atomic)
        let blockingParent = root.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("occupied".utf8).write(to: blockingParent, options: .atomic)
        let listenerURL = blockingParent.appendingPathComponent("listener.log", isDirectory: false)

        XCTAssertThrowsError(
            try SkyBridgeDiagnosticTrace.resetStatusArtifactsForTesting(
                primaryStatusURL: primaryURL,
                listenerStatusURL: listenerURL
            )
        )
        XCTAssertTrue(try Data(contentsOf: primaryURL).isEmpty)
    }

    func testSmokeStatusConcurrentAppendsDoNotLoseOrOverwriteLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-smoke-concurrent-\(UUID().uuidString)", isDirectory: true)
        let statusURL = root.appendingPathComponent("status.log", isDirectory: false)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        try SmokeArtifactFileIO.resetProtectedFile(at: statusURL)
        let expectedLineCount = 200
        let queue = DispatchQueue(label: "com.skybridge.tests.smoke-status", attributes: .concurrent)
        let group = DispatchGroup()
        let failureRecorder = SmokeAppendFailureRecorder()
        for index in 0..<expectedLineCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try SmokeArtifactFileIO.appendProtectedData(
                        Data("line-\(index)\n".utf8),
                        to: statusURL
                    )
                } catch {
                    failureRecorder.record(error)
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(failureRecorder.failures, [])

        let lines = try String(contentsOf: statusURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, expectedLineCount)
        XCTAssertEqual(Set(lines).count, expectedLineCount)
    }

    func testSmokeStatusReporterWriteFailureIsTerminalAndCannotEmitLaterSuccess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-smoke-terminal-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: root)
        }

        let blockingParent = root.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("occupied".utf8).write(to: blockingParent, options: .atomic)
        let statusURL = blockingParent.appendingPathComponent("status.log", isDirectory: false)
        let stdoutMirrorURL = root.appendingPathComponent("stdout.log", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: stdoutMirrorURL.path, contents: nil))
        let stdoutMirror = try FileHandle(forWritingTo: stdoutMirrorURL)
        let reporter = SmokeStatusReporter(
            statusURL: statusURL,
            stdoutMirrorDescriptor: stdoutMirror.fileDescriptor
        )

        reporter.append("first-write-must-fail")
        XCTAssertTrue(reporter.hasTerminalWriteFailure)

        try FileManager.default.removeItem(at: blockingParent)
        try FileManager.default.createDirectory(at: blockingParent, withIntermediateDirectories: true)
        reporter.append("success must never be written after a terminal sink failure")
        try stdoutMirror.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))
        XCTAssertTrue(try Data(contentsOf: stdoutMirrorURL).isEmpty)
    }

    func testSanitizeConnectionCodeInputUppercasesFiltersAndCapsLength() {
        let raw = "ab-cd12 34efghjkmnpqrstuvwxyz23456789"
        let sanitized = CrossNetworkWebRTCManager.sanitizeConnectionCodeInput(raw)

        XCTAssertEqual(sanitized, "ABCD234EFGHJKMNP")
        XCTAssertEqual(sanitized.count, CrossNetworkWebRTCManager.maximumConnectionCodeLength)
    }

    func testCanSubmitConnectionCodeAcceptsLegacyAndCurrentLengths() {
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEF"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGH"))
        XCTAssertTrue(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFGHJK"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDE"))
        XCTAssertFalse(CrossNetworkWebRTCManager.canSubmitConnectionCode("ABCDEFG"))
    }

    func testConnectionCodeLeaseReuseRequiresUnexpiredServerLease() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            CrossNetworkWebRTCManager.isReusableConnectionCodeLease(
                expiresAt: now.addingTimeInterval(60),
                now: now
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.isReusableConnectionCodeLease(
                expiresAt: now.addingTimeInterval(10),
                now: now
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.isReusableConnectionCodeLease(
                expiresAt: nil,
                now: now
            )
        )
    }

    func testGenerateConnectionCodeDoesNotReuseExpiredWaitingCode() throws {
        let source = try Self.crossNetworkWebRTCManagerSource()

        XCTAssertTrue(
            source.contains("Self.isReusableConnectionCodeLease(expiresAt: localConnectionCodeExpiresAt)"),
            "Displayed connection codes must not be reused after their server lease is expired or near expiry."
        )
        XCTAssertTrue(
            source.contains("scheduleConnectionCodeLeaseInvalidation("),
            "A displayed code should be removed before its server lease becomes non-reusable, avoiding stale UI codes that lookup as found=false."
        )
        XCTAssertTrue(
            source.contains("本地连接码不可复用"),
            "Regenerating an expired or authority-stale displayed code should clean up the stale local offerer state."
        )
        XCTAssertTrue(
            source.contains("connection_code_lease_not_reusable"),
            "Regenerating an expired displayed code should emit a stable cleanup reason for post-release log audits."
        )
        XCTAssertTrue(
            source.contains("connection_code_lease_expired"),
            "The expiry task should emit a stable reason when it removes a displayed stale connection code."
        )
        XCTAssertFalse(
            source.contains("code=\\(existing"),
            "A connection code is an admission secret and must not be logged in plaintext when regenerating."
        )
        XCTAssertFalse(
            source.contains("code=\\(code"),
            "A connection code is an admission secret and must not be logged in plaintext when expiring."
        )
        XCTAssertTrue(
            source.contains("code=<redacted>"),
            "Connection-code lifecycle logs may expose stable reasons, but never the raw user-entered or server-issued code."
        )
        XCTAssertFalse(
            source.contains("activeSessionID == sessionID,\n               self.currentRole == .offerer"),
            "Connection-code lease expiry must only remove stale UI/code state; it must not close an active or in-flight WebRTC session."
        )
    }

    func testPreSessionSignalingFramesAreBoundedAndDrainedAfterSessionStart() throws {
        let source = try Self.crossNetworkWebRTCManagerSource()

        XCTAssertTrue(source.contains("maxPendingPreSessionSignalingEnvelopes = 32"))
        XCTAssertTrue(source.contains("pendingPreSessionSignalingEnvelopesBySessionId"))
        XCTAssertTrue(source.contains("pending.count < Self.maxPendingPreSessionSignalingEnvelopes"))
        XCTAssertTrue(source.contains("state = .failed(message)"))
        XCTAssertTrue(source.contains("pre-session-queued"))
        XCTAssertTrue(source.contains("pre-session-drain"))
        XCTAssertTrue(source.contains("case .offer, .answer, .iceCandidate:\n            return true"))

        XCTAssertTrue(source.contains("guard let session else {\n                    enqueuePreSessionSignalingEnvelope(env)\n                    return\n                }\n                session.setRemoteOffer(sdp)"))
        XCTAssertTrue(source.contains("guard let session else {\n                    enqueuePreSessionSignalingEnvelope(env)\n                    return\n                }\n                session.setRemoteAnswer(sdp)"))
        XCTAssertTrue(source.contains("guard let session else {\n                    enqueuePreSessionSignalingEnvelope(env)\n                    return\n                }\n                session.addRemoteICECandidate"))
        XCTAssertFalse(source.contains("session?.setRemoteOffer"))
        XCTAssertFalse(source.contains("session?.setRemoteAnswer"))
        XCTAssertFalse(source.contains("session?.addRemoteICECandidate"))

        let sessionStart = try XCTUnwrap(source.range(of: "try await s.startAsync()"))
        let drain = try XCTUnwrap(source.range(of: "drainPendingPreSessionSignalingEnvelopes(sessionId: sessionId)"))
        let join = try XCTUnwrap(
            source.range(
                of: "try await sendRequiredSetupEnvelope(",
                range: drain.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(sessionStart.lowerBound, drain.lowerBound)
        XCTAssertLessThan(drain.lowerBound, join.lowerBound)
    }

    func testConnectionCodeConnectIsSingleOwnerAndExplicitDisconnectInvalidatesQueuedCalls() throws {
        let source = try Self.crossNetworkWebRTCManagerSource()
        let connectStart = try XCTUnwrap(
            source.range(of: "public func connect(withCode rawCode: String) async")
        )
        let connectEnd = try XCTUnwrap(
            source.range(
                of: "private func performConnectWithCode",
                range: connectStart.upperBound..<source.endIndex
            )
        )
        let connectBody = String(source[connectStart.lowerBound..<connectEnd.lowerBound])

        XCTAssertTrue(connectBody.contains("while let existingOwner = connectionCodeConnectOwner"))
        XCTAssertTrue(connectBody.contains("await existingOwner.task.value"))
        XCTAssertTrue(connectBody.contains("guard connectionCodeLifecycleEpoch == lifecycleEpoch,"))
        XCTAssertTrue(connectBody.contains("!Task.isCancelled else { return }"))
        XCTAssertTrue(connectBody.contains("connectionCodeConnectOwner = ConnectionCodeConnectOwner("))
        XCTAssertFalse(connectBody.contains("connectionCodeConnectTasks"))

        let disconnectStart = try XCTUnwrap(
            source.range(of: "public func disconnect(clearSnapshot: Bool = true) async")
        )
        let disconnectEnd = try XCTUnwrap(
            source.range(
                of: "private func disconnectInternal",
                range: disconnectStart.upperBound..<source.endIndex
            )
        )
        let disconnectBody = String(source[disconnectStart.lowerBound..<disconnectEnd.lowerBound])
        XCTAssertTrue(disconnectBody.contains("connectionCodeLifecycleEpoch &+= 1"))
    }

    func testTenantIDBindsDeclaredSessionTenantToJWTClaimBeforeLegacyFallback() throws {
        let source = try Self.crossNetworkSignalServerClientSource()

        XCTAssertTrue(
            source.contains("Self.resolveAuthenticatedTenantID("),
            "iOS WebRTC signaling must resolve tenant identity through the strict JWT binding policy."
        )
        XCTAssertTrue(
            source.contains("throw ClientError.missingTenantClaim"),
            "A stored tenant must fail closed when the token has no tenant-bearing claim."
        )
        XCTAssertTrue(
            source.contains("throw ClientError.tenantIdentityMismatch"),
            "A token and local tenant disagreement must not be sent to the signaling server."
        )
    }

    func testAuthenticatedTenantResolutionAcceptsMatchingTokenAndLocalIdentities() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(
            payload: [
                "sub": "user-123",
                "app_metadata": ["tenant_id": "NEBULA-123"]
            ]
        )

        let tenant = try SignalServerClientCompat.resolveAuthenticatedTenantID(
            accessToken: token,
            explicitTenantID: "NEBULA-123",
            sessionTenantID: "NEBULA-123",
            legacyUserIdentifier: "user-123"
        )

        XCTAssertEqual(tenant, "NEBULA-123")
    }

    func testAuthenticatedTenantResolutionRejectsTokenTenantMismatch() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(
            payload: [
                "sub": "user-123",
                "app_metadata": ["tenant_id": "NEBULA-token"]
            ]
        )

        XCTAssertThrowsError(
            try SignalServerClientCompat.resolveAuthenticatedTenantID(
                accessToken: token,
                explicitTenantID: "NEBULA-local",
                sessionTenantID: "NEBULA-local",
                legacyUserIdentifier: "user-123"
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.tenantIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthenticatedTenantResolutionRejectsMissingClaimWhenSessionHasTenant() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(
            payload: ["sub": "NEBULA-local", "exp": 4_102_444_800]
        )

        XCTAssertThrowsError(
            try SignalServerClientCompat.resolveAuthenticatedTenantID(
                accessToken: token,
                explicitTenantID: nil,
                sessionTenantID: "NEBULA-local",
                legacyUserIdentifier: "NEBULA-local"
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.missingTenantClaim = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthenticatedTenantResolutionUsesJWTSubjectOnlyWithoutDeclaredTenant() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(payload: ["sub": "user-123"])

        let tenant = try SignalServerClientCompat.resolveAuthenticatedTenantID(
            accessToken: token,
            explicitTenantID: nil,
            sessionTenantID: nil,
            legacyUserIdentifier: "user-123"
        )

        XCTAssertEqual(tenant, "user-123")
    }

    func testAuthenticatedJWTIdentitySeparatesExplicitAndEffectiveTenant() throws {
        let subjectOnlyToken = try Self.makeUnsignedJWTForTenantTests(
            payload: ["sub": "user-123"]
        )
        let subjectOnlyIdentity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
            accessToken: subjectOnlyToken,
            expectedUserIdentifier: "user-123"
        )
        XCTAssertEqual(subjectOnlyIdentity.subject, "user-123")
        XCTAssertNil(subjectOnlyIdentity.explicitTenantID)
        XCTAssertEqual(subjectOnlyIdentity.effectiveTenantID, "user-123")

        let explicitTenantToken = try Self.makeUnsignedJWTForTenantTests(
            payload: [
                "sub": "user-123",
                "app_metadata": ["tenant_id": "tenant-123"]
            ]
        )
        let explicitTenantIdentity = try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
            accessToken: explicitTenantToken,
            expectedUserIdentifier: "user-123"
        )
        XCTAssertEqual(explicitTenantIdentity.subject, "user-123")
        XCTAssertEqual(explicitTenantIdentity.explicitTenantID, "tenant-123")
        XCTAssertEqual(explicitTenantIdentity.effectiveTenantID, "tenant-123")
    }

    func testAuthenticatedJWTIdentityRejectsExpectedUserMismatch() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(payload: ["sub": "user-123"])

        XCTAssertThrowsError(
            try SignalServerClientCompat.resolveAuthenticatedJWTIdentity(
                accessToken: token,
                expectedUserIdentifier: "different-user"
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.userIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthenticatedTenantResolutionRejectsJWTSubjectAndSessionUserMismatch() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(payload: ["sub": "token-user"])

        XCTAssertThrowsError(
            try SignalServerClientCompat.resolveAuthenticatedTenantID(
                accessToken: token,
                explicitTenantID: nil,
                sessionTenantID: nil,
                legacyUserIdentifier: "different-session-user"
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.userIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthenticatedTenantResolutionRejectsJWTSubjectMismatchWithDeclaredTenant() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(
            payload: [
                "sub": "token-user",
                "app_metadata": ["tenant_id": "tenant-123"]
            ]
        )

        XCTAssertThrowsError(
            try SignalServerClientCompat.resolveAuthenticatedTenantID(
                accessToken: token,
                explicitTenantID: "tenant-123",
                sessionTenantID: "tenant-123",
                legacyUserIdentifier: "different-session-user"
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.userIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthenticatedTenantResolutionRejectsConflictingSignedTenantClaims() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(
            payload: [
                "sub": "user-123",
                "tenant_id": "root-tenant",
                "app_metadata": ["tenant_id": "app-tenant"]
            ]
        )

        XCTAssertThrowsError(
            try SignalServerClientCompat.resolveAuthenticatedTenantID(
                accessToken: token,
                explicitTenantID: "root-tenant",
                sessionTenantID: "root-tenant",
                legacyUserIdentifier: "user-123"
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.conflictingTenantClaims = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthenticatedTenantResolutionIgnoresUserControlledMetadataForTenantAuthority() throws {
        let token = try Self.makeUnsignedJWTForTenantTests(
            payload: [
                "sub": "user-123",
                "user_metadata": ["tenant_id": "attacker-selected-tenant"]
            ]
        )

        XCTAssertThrowsError(
            try SignalServerClientCompat.resolveAuthenticatedTenantID(
                accessToken: token,
                explicitTenantID: "attacker-selected-tenant",
                sessionTenantID: "attacker-selected-tenant",
                legacyUserIdentifier: "user-123"
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.missingTenantClaim = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAuthenticatedTenantResolutionKeepsOpaqueLegacyFallbackWithoutDeclaredTenant() throws {
        let tenant = try SignalServerClientCompat.resolveAuthenticatedTenantID(
            accessToken: "opaque-legacy-token",
            explicitTenantID: nil,
            sessionTenantID: nil,
            legacyUserIdentifier: "legacy-user"
        )

        XCTAssertEqual(tenant, "legacy-user")
    }

    func testRefreshedSessionRejectsJWTSubjectDriftBeforePersistence() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = AuthSession(
            accessToken: try Self.makeUnsignedJWTForTenantTests(
                payload: [
                    "sub": "user-123",
                    "app_metadata": ["tenant_id": "tenant-123"],
                    "exp": now.timeIntervalSince1970 - 1
                ]
            ),
            refreshToken: "refresh-original",
            userIdentifier: "user-123",
            displayName: "User",
            nebulaId: "tenant-123",
            issuedAt: now.addingTimeInterval(-3_600)
        )
        let refreshed = AuthSession(
            accessToken: try Self.makeUnsignedJWTForTenantTests(
                payload: [
                    "sub": "attacker-user",
                    "app_metadata": ["tenant_id": "tenant-123"],
                    "exp": now.timeIntervalSince1970 + 3_600
                ]
            ),
            refreshToken: "refresh-next",
            userIdentifier: "user-123",
            displayName: "Ignored",
            nebulaId: "tenant-123",
            issuedAt: now
        )

        XCTAssertThrowsError(
            try SignalServerClientCompat.validatedRefreshedAuthSession(
                refreshed,
                replacing: original,
                explicitTenantID: "tenant-123",
                now: now
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.userIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRefreshedSessionRejectsJWTTenantDriftBeforePersistence() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = AuthSession(
            accessToken: try Self.makeUnsignedJWTForTenantTests(
                payload: [
                    "sub": "user-123",
                    "app_metadata": ["tenant_id": "tenant-original"],
                    "exp": now.timeIntervalSince1970 - 1
                ]
            ),
            refreshToken: "refresh-original",
            userIdentifier: "user-123",
            displayName: "User",
            nebulaId: "tenant-original",
            issuedAt: now.addingTimeInterval(-3_600)
        )
        let refreshed = AuthSession(
            accessToken: try Self.makeUnsignedJWTForTenantTests(
                payload: [
                    "sub": "user-123",
                    "app_metadata": ["tenant_id": "tenant-drifted"],
                    "exp": now.timeIntervalSince1970 + 3_600
                ]
            ),
            refreshToken: "refresh-next",
            userIdentifier: "user-123",
            displayName: "Ignored",
            nebulaId: "tenant-drifted",
            issuedAt: now
        )

        XCTAssertThrowsError(
            try SignalServerClientCompat.validatedRefreshedAuthSession(
                refreshed,
                replacing: original,
                explicitTenantID: "tenant-original",
                now: now
            )
        ) { error in
            guard case SignalServerClientCompat.ClientError.tenantIdentityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRefreshedSessionRejectsOpaqueOrUnsignedAccessToken() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = AuthSession(
            accessToken: try Self.makeUnsignedJWTForTenantTests(
                payload: [
                    "sub": "user-123",
                    "app_metadata": ["tenant_id": "tenant-123"],
                    "exp": now.timeIntervalSince1970 - 1
                ]
            ),
            refreshToken: "refresh-original",
            userIdentifier: "user-123",
            displayName: "User",
            nebulaId: "tenant-123",
            issuedAt: now.addingTimeInterval(-3_600)
        )

        for invalidToken in ["opaque-refresh-response", "e30.e30."] {
            let refreshed = AuthSession(
                accessToken: invalidToken,
                refreshToken: "refresh-next",
                userIdentifier: "user-123",
                displayName: "Ignored",
                nebulaId: "tenant-123",
                issuedAt: now
            )
            XCTAssertThrowsError(
                try SignalServerClientCompat.validatedRefreshedAuthSession(
                    refreshed,
                    replacing: original,
                    explicitTenantID: "tenant-123",
                    now: now
                )
            ) { error in
                guard case SignalServerClientCompat.ClientError.invalidAuthenticationClaims = error else {
                    return XCTFail("Unexpected error for \(invalidToken): \(error)")
                }
            }
        }
    }

    func testSupabaseAuthenticatedTokenClassifierRequiresExactIssuerAudienceAndRole() throws {
        let expectedIssuer = "https://project.supabase.co/auth/v1"
        let valid = try Self.makeUnsignedJWTForTenantTests(
            payload: [
                "sub": "user-123",
                "iss": expectedIssuer,
                "aud": "authenticated",
                "role": "authenticated"
            ]
        )
        XCTAssertTrue(
            SupabaseService.isAuthenticatedAccessToken(valid, expectedIssuer: expectedIssuer)
        )
        XCTAssertFalse(
            SupabaseService.isAuthenticatedAccessToken(
                String(repeating: "a", count: 65_537),
                expectedIssuer: expectedIssuer
            )
        )

        let invalidPayloads: [[String: Any]] = [
            [
                "sub": "user-123",
                "iss": expectedIssuer + ".attacker.example",
                "aud": "authenticated",
                "role": "authenticated"
            ],
            [
                "sub": "user-123",
                "iss": " \(expectedIssuer) ",
                "aud": "authenticated",
                "role": "authenticated"
            ],
            [
                "sub": "user-123",
                "iss": expectedIssuer,
                "aud": "anon",
                "role": "authenticated"
            ],
            [
                "sub": "user-123",
                "iss": expectedIssuer,
                "aud": "authenticated",
                "role": "service_role"
            ]
        ]
        for payload in invalidPayloads {
            let token = try Self.makeUnsignedJWTForTenantTests(payload: payload)
            XCTAssertFalse(
                SupabaseService.isAuthenticatedAccessToken(token, expectedIssuer: expectedIssuer)
            )
        }
    }

    func testRealDeviceWebRTCSmokeBootstrapValidatesBoundTenantCodeAndXWingKey() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = try Self.makeWebRTCSmokeBootstrapData(
            runID: "run-123",
            tenantID: "NEBULA-123",
            expiresAtEpochSeconds: 1_300
        )

        let bootstrap = try LocalWebRTCSmokeBootstrap.validate(
            data: data,
            expectedRunID: "run-123",
            now: now
        )

        XCTAssertEqual(bootstrap.runID, "run-123")
        XCTAssertEqual(bootstrap.tenantID, "NEBULA-123")
        XCTAssertEqual(bootstrap.connectionCode, "ABCDEFGH")
        XCTAssertEqual(bootstrap.peerDeviceID, "peer-device")
        XCTAssertEqual(bootstrap.peerKEMPublicKeys.map(\.suiteWireId), [0x0001])
        XCTAssertEqual(bootstrap.peerKEMPublicKeys.first?.publicKey.count, 1_216)
    }

    func testRealDeviceWebRTCSmokeBootstrapAcceptsSubjectAsEffectiveTenant() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = try Self.makeWebRTCSmokeBootstrapData(
            runID: "run-subject-fallback",
            tenantID: "fixture-user",
            includeTokenTenantClaim: false,
            expiresAtEpochSeconds: 1_300
        )

        let bootstrap = try LocalWebRTCSmokeBootstrap.validate(
            data: data,
            expectedRunID: "run-subject-fallback",
            now: now
        )

        XCTAssertEqual(bootstrap.tenantID, "fixture-user")
    }

    func testRealDeviceWebRTCSmokeBootstrapRejectsUntrustedTenantMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = try Self.makeWebRTCSmokeBootstrapData(
            runID: "run-user-metadata",
            tenantID: "attacker-selected-tenant",
            includeTokenTenantClaim: false,
            tokenUserMetadataTenantID: "attacker-selected-tenant",
            expiresAtEpochSeconds: 1_300
        )

        XCTAssertThrowsError(
            try LocalWebRTCSmokeBootstrap.validate(
                data: data,
                expectedRunID: "run-user-metadata",
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalWebRTCSmokeBootstrap.ValidationError,
                .tenantBindingFailed
            )
        }
    }

    func testRealDeviceWebRTCSmokeSessionSeparatesAuthUserFromProtocolDevice() throws {
        let harnessSource = try Self.localWebRTCSmokeHarnessSource()
        let authSource = try Self.authenticationManagerSource()

        XCTAssertTrue(
            harnessSource.contains("effectiveTenantID: bootstrap.tenantID")
        )
        XCTAssertFalse(
            harnessSource.contains("userIdentifier: resolvedLocalDeviceID()")
        )
        XCTAssertTrue(authSource.contains("userIdentifier: identity.subject"))
        XCTAssertTrue(authSource.contains("nebulaId: identity.explicitTenantID"))
        XCTAssertTrue(authSource.contains("nebulaId: identity.effectiveTenantID"))
    }

    func testRealDeviceWebRTCSmokeBootstrapRejectsTenantAndRunBindingFailures() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let tenantMismatch = try Self.makeWebRTCSmokeBootstrapData(
            runID: "run-123",
            tenantID: "NEBULA-other",
            tokenTenantID: "NEBULA-token",
            expiresAtEpochSeconds: 1_300
        )
        XCTAssertThrowsError(
            try LocalWebRTCSmokeBootstrap.validate(
                data: tenantMismatch,
                expectedRunID: "run-123",
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalWebRTCSmokeBootstrap.ValidationError,
                .tenantBindingFailed
            )
        }

        let valid = try Self.makeWebRTCSmokeBootstrapData(
            runID: "run-123",
            tenantID: "NEBULA-123",
            expiresAtEpochSeconds: 1_300
        )
        XCTAssertThrowsError(
            try LocalWebRTCSmokeBootstrap.validate(
                data: valid,
                expectedRunID: "different-run",
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalWebRTCSmokeBootstrap.ValidationError,
                .runIDMismatch
            )
        }
    }

    func testRealDeviceWebRTCSmokeBootstrapRejectsExpiredAndInvalidKEMMaterial() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let expired = try Self.makeWebRTCSmokeBootstrapData(
            runID: "run-123",
            tenantID: "NEBULA-123",
            expiresAtEpochSeconds: 999
        )
        XCTAssertThrowsError(
            try LocalWebRTCSmokeBootstrap.validate(
                data: expired,
                expectedRunID: "run-123",
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? LocalWebRTCSmokeBootstrap.ValidationError, .expired)
        }

        let invalidKey = try Self.makeWebRTCSmokeBootstrapData(
            runID: "run-123",
            tenantID: "NEBULA-123",
            expiresAtEpochSeconds: 1_300,
            xwingPublicKey: Data(repeating: 0xAA, count: 32)
        )
        XCTAssertThrowsError(
            try LocalWebRTCSmokeBootstrap.validate(
                data: invalidKey,
                expectedRunID: "run-123",
                now: now
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalWebRTCSmokeBootstrap.ValidationError,
                .invalidPeerKEMPublicKeys
            )
        }
    }

    func testRealDeviceWebRTCSmokeBootstrapFileIsConsumedOffTheLaunchPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove bootstrap test directory: \(error)")
            }
        }
        let file = directory.appendingPathComponent("bootstrap.json")
        let expected = Data("bootstrap-fixture".utf8)
        try expected.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )

        let consumed = try await LocalWebRTCSmokeHarness.consumeBootstrapFile(at: file)

        XCTAssertEqual(consumed, expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRealDeviceWebRTCSmokeBootstrapFileRejectsSymlinkWithoutConsumingTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("Failed to remove bootstrap test directory: \(error)")
            }
        }
        let target = directory.appendingPathComponent("target.json")
        let symlink = directory.appendingPathComponent("bootstrap.json")
        let expected = Data("bootstrap-fixture".utf8)
        try expected.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        do {
            _ = try await LocalWebRTCSmokeHarness.consumeBootstrapFile(at: symlink)
            XCTFail("A symbolic-link bootstrap path must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? LocalWebRTCSmokeBootstrap.ConsumptionError,
                .unsafeFile
            )
        }

        XCTAssertEqual(try Data(contentsOf: target), expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testRealDeviceWebRTCSmokeBootstrapFileUsesDescriptorBoundConsumption() throws {
        let source = try Self.localWebRTCSmokeHarnessSource()

        XCTAssertTrue(source.contains("O_RDONLY | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(source.contains("Darwin.fstat(descriptor, &openedMetadata)"))
        XCTAssertTrue(source.contains("finalMetadata.st_ino == openedMetadata.st_ino"))
        XCTAssertTrue(source.contains("pathMetadata.st_ino == openedMetadata.st_ino"))
        XCTAssertTrue(source.contains("Darwin.unlink(url.path)"))
        XCTAssertFalse(source.contains("Data(contentsOf: url"))
    }

    func testRealDeviceWebRTCSmokeAudioLifecycleOwnsRolloverAndPropagatesCancellation() throws {
        let source = try Self.localWebRTCSmokeHarnessSource()

        XCTAssertTrue(source.contains("private var smokeAudioRelayRolloverTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("private func stopSmokeAudioReceiver() async"))
        XCTAssertTrue(source.contains("await rolloverTask?.value"))
        XCTAssertTrue(source.contains("await transport?.stop()"))
        XCTAssertTrue(source.contains("await receiver?.close()"))
        XCTAssertTrue(source.contains("previousTask?.cancel()\n        await previousTask?.value"))
        XCTAssertTrue(source.contains("await newTransport.stop()"))
        XCTAssertTrue(source.contains("await oldTransport.stop()"))
        XCTAssertFalse(
            source.contains("try?"),
            "The smoke harness must not swallow file-write, sleep cancellation, or relay teardown errors."
        )
    }

    func testConnectionCodeLookupAllowsAuthenticatedAuthorityRotation() throws {
        let managerSource = try Self.crossNetworkWebRTCManagerSource()
        let rebindPolicySource = try Self.crossNetworkWebRTCRebindPolicySource()
        let handshakePolicySource = try Self.crossNetworkWebRTCPQCHandshakePolicySource()
        let source = managerSource + "\n" + rebindPolicySource + "\n" + handshakePolicySource

        XCTAssertTrue(
            source.contains("? .verifiedQRCode\n                : .verifiedConnectionCode"),
            "Connection-code lookup is itself a user-mediated fresh authority proof and must not fall back to unauthenticated rebind handling."
        )
        XCTAssertTrue(
            source.contains("activeConnectionCodeMatchesCurrentAuthority(localBinding)"),
            "A long-lived connection code must be regenerated when the local authoritative key changes."
        )
        XCTAssertTrue(
            source.contains("connection_code_authority_changed"),
            "Stale connection-code regeneration should leave a stable post-release log reason."
        )
        XCTAssertTrue(
            source.contains("let useClassicAuthorityBootstrap ="),
            "Connection-code WebRTC bootstrap must explicitly bind the initial handshake policy to the advertised authority identity."
        )
        XCTAssertTrue(
            source.contains("localConnectionSessionId == sessionId"),
            "The local connection-code offerer must use classic authority bootstrap even when trusted KEM material is available."
        )
        XCTAssertTrue(
            source.contains("authorityBoundWebRTCBootstrapSessionIds.insert(lease.sessionID)"),
            "iOS connection-code and connect-link offerer sessions must be marked as authority-bound for identity-pinned bootstrap."
        )
        XCTAssertTrue(
            source.contains("expectedRemoteAuthorityAlgorithm"),
            "The connection-code joiner must honor the Ed25519 authority fingerprint returned by lookup instead of switching to a PQC identity key."
        )
        XCTAssertTrue(
            source.contains("authorityBootstrap=\\(useClassicAuthorityBootstrap)"),
            "Release logs must expose whether identityMismatch prevention used authority-bound bootstrap."
        )
        XCTAssertTrue(
            source.contains("shouldAllowAuthenticatedConnectionCodeRebind"),
            "Connection codes should have an explicit, narrower rebind policy instead of borrowing QR wording or refusing stale key rotations."
        )
        XCTAssertTrue(
            source.contains("case .identityConflict:\n            return true"),
            "A verified connection code should heal the common stale-key conflict for the same deviceId."
        )
        XCTAssertFalse(
            source.contains("case .verifiedQRCode, .verifiedConnectionCode:"),
            "QR and connection-code rebind policies should stay separate so future hardening can tune them independently."
        )
    }

    func testIOSDeviceSupportGateKeepsExplicit2018And2019A12FamilyDevicesAppStartSupported() {
        let legacyA12Devices = [
            "iPhone11,2": "iPhone XS",
            "iPhone11,8": "iPhone XR",
            "iPad8,1": "iPad Pro 11-inch (2018)",
            "iPad11,3": "iPad Air (3rd generation)"
        ]

        for (modelIdentifier, displayName) in legacyA12Devices {
            XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: modelIdentifier))
            XCTAssertTrue(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: modelIdentifier))
            XCTAssertEqual(
                IOSDeviceSupportGate.legacyLimitedDevice(forModelIdentifier: modelIdentifier),
                LegacyLimitedIOSDevice(modelIdentifier: modelIdentifier, displayName: displayName)
            )
        }
    }

    func testIOSDeviceSupportGateAllows2020AndLaterDevices() {
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone12,8"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPhone13,2"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad11,6"))
        XCTAssertTrue(IOSDeviceSupportGate.isSupported(modelIdentifier: "iPad13,1"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPhone12,8"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPhone13,2"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPad11,6"))
        XCTAssertFalse(IOSDeviceSupportGate.isLegacyLimited(modelIdentifier: "iPad13,1"))
    }

    func testSupabaseServiceNormalizesRelativeAvatarURLs() {
        let baseURL = URL(string: "https://demo.example.com")!

        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "/storage/v1/object/public/avatars/user.jpg",
                baseURL: baseURL
            ),
            "https://demo.example.com/storage/v1/object/public/avatars/user.jpg"
        )
        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "storage/v1/object/public/avatars/user.jpg",
                baseURL: baseURL
            ),
            "https://demo.example.com/storage/v1/object/public/avatars/user.jpg"
        )
        XCTAssertEqual(
            SupabaseService.normalizedRemoteAssetURL(
                "https://cdn.example.com/avatar.jpg",
                baseURL: baseURL
            ),
            "https://cdn.example.com/avatar.jpg"
        )
    }

    func testRemoteUserProfileCarriesAvatarAndNebulaFields() {
        let profile = SupabaseService.RemoteUserProfile(
            userId: "user-1",
            email: "person@example.com",
            displayName: "Primary Name",
            avatarURL: "https://demo.example.com/avatar.jpg",
            nebulaId: "NEBULA-123"
        )

        XCTAssertEqual(profile.userId, "user-1")
        XCTAssertEqual(profile.displayName, "Primary Name")
        XCTAssertEqual(profile.avatarURL, "https://demo.example.com/avatar.jpg")
        XCTAssertEqual(profile.nebulaId, "NEBULA-123")
    }

    func testAuthSessionStrictLoaderDistinguishesMissingCorruptAndValidData() async throws {
        let keychain = KeychainManager.shared
        try await keychain.deleteAuthSession()
        addTeardownBlock {
            try await keychain.deleteAuthSession()
        }

        let missingSession = try await keychain.loadAuthSessionStrict()
        XCTAssertNil(missingSession)

        try keychain.savePublicKey(Data("not-json".utf8), identifier: "auth.session")
        do {
            _ = try await keychain.loadAuthSessionStrict()
            XCTFail("Expected corrupt auth.session data to throw.")
        } catch {
            guard case KeychainError.decodingError = error else {
                return XCTFail("Expected corrupt auth.session data to throw KeychainError.decodingError, got \(error).")
            }
        }

        let expected = AuthSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            userIdentifier: "user-123",
            displayName: "Primary User",
            email: "primary@example.com",
            avatarURL: "https://example.com/avatar.png",
            nebulaId: "NEBULA-123",
            issuedAt: Date(timeIntervalSince1970: 1_234_567)
        )
        try await keychain.storeAuthSession(expected)

        let loadedSession = try await keychain.loadAuthSessionStrict()
        XCTAssertEqual(loadedSession, expected)
    }

    func testKeychainActorExecutorLeavesMainActor() async {
        let probe = IOSKeychainExecutorProbe()
        let isMainThread = await probe.isRunningOnMainThread()
        XCTAssertFalse(isMainThread)
    }

    func testKeychainAuthSessionStorageUsesUpdateFirstAndStrictDecoding() throws {
        let source = try Self.keychainManagerSource()

        XCTAssertTrue(
            source.contains("SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)"),
            "Generic password writes should update existing Keychain items before adding missing items."
        )
        XCTAssertFalse(
            source.contains("SecItemDelete(query as CFDictionary)\n        let status = SecItemAdd(query as CFDictionary, nil)"),
            "Generic password writes must not delete an existing auth item before adding its replacement."
        )
        XCTAssertTrue(
            source.contains("func loadAuthSessionStrict() throws -> AuthSession?"),
            "Critical auth paths need a throwing loader so corrupt storage is not collapsed into a signed-out state."
        )
        XCTAssertTrue(
            source.contains("public nonisolated var unownedExecutor: UnownedSerialExecutor") &&
                source.contains("final class IOSKeychainSerialExecutor: SerialExecutor"),
            "Auth-session Keychain calls must run on the dedicated serial executor instead of inheriting MainActor."
        )
        XCTAssertTrue(
            source.contains("throw KeychainError.decodingError"),
            "Corrupt auth.session JSON must surface as a decoding error instead of nil."
        )
    }

    func testKeychainConfigFallbackDoesNotMaskStorageErrors() throws {
        let source = try Self.keychainManagerSource()

        XCTAssertTrue(
            source.contains("public nonisolated func exportKeyStrict(service: String, account: String) throws -> Data?"),
            "Service/account Keychain reads need a strict API so callers can distinguish missing items from OSStatus failures."
        )
        XCTAssertTrue(
            source.contains("throw KeychainError.unexpectedError(status)"),
            "Unexpected Keychain OSStatus values must propagate instead of collapsing to nil."
        )
        XCTAssertTrue(
            source.contains("} catch KeychainError.itemNotFound {\n            // Fallback: macOS-style keys (service-based)"),
            "Legacy service-key fallback should only run when the current iOS keys are genuinely absent."
        )
        XCTAssertFalse(
            source.contains("try? storeSupabaseConfig(url: url, anonKey: anon)"),
            "Supabase legacy migration failures must not be silently ignored."
        )
        XCTAssertFalse(
            source.contains("try? storeNebulaConfig(baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)"),
            "Nebula legacy migration failures must not be silently ignored."
        )
    }

    func testSignalingAuthPathFailsClosedOnAuthSessionStorageErrors() throws {
        let source = try Self.crossNetworkSignalServerClientSource()

        XCTAssertTrue(
            source.contains("case authenticationStorageUnavailable(String)"),
            "Signaling admission should expose Keychain/session storage failures distinctly from missing authentication."
        )
        XCTAssertTrue(
            source.contains("try await KeychainManager.shared.loadAuthSessionStrict()"),
            "Signaling auth should use the throwing auth-session loader instead of the legacy optional wrapper."
        )
        XCTAssertFalse(
            source.contains("try? KeychainManager.shared.storeAuthSession(merged)"),
            "Refreshed signaling tokens must not continue after Keychain persistence fails."
        )
    }

    func testAuthenticationManagerPersistsSessionBeforePublishingAuthenticatedState() throws {
        let source = try Self.authenticationManagerSource()

        XCTAssertTrue(
            source.contains("try await KeychainManager.shared.loadAuthSessionStrict()"),
            "Launch-time auth restoration should distinguish absent sessions from corrupt Keychain data."
        )
        XCTAssertTrue(
            source.contains("try await persistSession(session)\n        self.session = session"),
            "Login success should persist the session before publishing authenticated in-memory state."
        )
        XCTAssertFalse(
            source.contains("try? KeychainManager.shared.storeAuthSession"),
            "AuthenticationManager must not silently discard auth-session persistence failures."
        )
        XCTAssertTrue(
            source.contains("public func signOut() async throws {\n        let sessionToRevoke = session\n        try await clearSession()") &&
                source.contains("public func signInAsGuest() async throws {\n        try await clearSession()"),
            "Sign-out and guest transitions must delete persisted auth state before publishing a new UI state."
        )
        XCTAssertTrue(
            source.contains("@Published public private(set) var isRestoringSession: Bool = true"),
            "Launch must hold a restoration phase while the asynchronous Keychain read completes."
        )
    }

    func testSupabaseConfigurationLoadsKeychainAsynchronouslyAndFailsClosed() throws {
        let source = try Self.supabaseServiceSource()

        XCTAssertTrue(
            source.contains("private func requireConfiguration(logIfMissing: Bool = true) async throws") &&
                source.contains("try await KeychainManager.shared.retrieveSupabaseConfig()"),
            "Supabase configuration should cross the Keychain actor asynchronously."
        )
        XCTAssertTrue(
            source.contains("case configurationStorageUnavailable(String)") &&
                source.contains("case invalidStoredConfiguration"),
            "Storage failures and invalid stored configuration must remain distinct from an absent configuration."
        )
        XCTAssertFalse(
            source.contains("try? KeychainManager.shared.retrieveSupabaseConfig()"),
            "Supabase configuration lookup must not collapse Keychain failures into a missing configuration."
        )
    }

    func testIOSPersistentIdentityKeychainFailuresDoNotRegenerateIdentityMaterial() throws {
        let platformSource = try Self.platformAdapterSource()
        let kemStoreSource = try Self.p2pKEMIdentityKeyStoreSource()
        let pqcManagerSource = try Self.pqcCryptoManagerSource()
        let protocolDeviceIdentitySource = try Self.protocolDeviceIdentitySource()
        let keychainSource = try Self.keychainManagerSource()

        XCTAssertFalse(
            platformSource.contains("try? loadIdentityKeyFromKeychain"),
            "Platform identity loading must not collapse Keychain failures into missing identity material."
        )
        XCTAssertTrue(
            protocolDeviceIdentitySource.contains("case keychainProbeFailed(OSStatus)") &&
                protocolDeviceIdentitySource.contains("throw KeychainError.unexpectedError(status)") &&
                platformSource.contains("Stored identity key failed self-test"),
            "Platform identity storage must propagate Keychain failures and fail closed on corrupt stored signing keys."
        )
        XCTAssertTrue(
            protocolDeviceIdentitySource.contains("SkyBridgeRuntimeEnvironment.isRunningUnderXCTest") &&
                protocolDeviceIdentitySource.contains("TEST.group.com.skybridge.compass") &&
                keychainSource.contains("SKYBRIDGE_KEYCHAIN_IN_MEMORY") &&
                keychainSource.contains("SkyBridgeRuntimeEnvironment.isRunningUnderXCTest"),
            "Simulator identity storage must use an explicit isolated authority backed by the test-only in-memory Keychain."
        )
        XCTAssertFalse(
            kemStoreSource.contains("try? keychain.loadPrivateKey") ||
            kemStoreSource.contains("try? keychain.loadPublicKey"),
            "P2P KEM identity storage must only generate when both public and private keys are genuinely absent."
        )
        XCTAssertTrue(
            kemStoreSource.contains("P2P KEM identity keypair is incomplete"),
            "P2P KEM identity storage must fail closed on half-present keypairs."
        )
        XCTAssertTrue(
            pqcManagerSource.contains("private func loadKeysFromKeychain() throws") &&
            pqcManagerSource.contains("PQC primary KEM/signing key set is incomplete"),
            "PQC primary key loading must expose storage errors and partial keysets before generating."
        )
        XCTAssertFalse(
            pqcManagerSource.contains("try? keychainManager.loadPrivateKey") ||
            pqcManagerSource.contains("try? keychainManager.loadPublicKey"),
            "PQC key loading must not use try? to convert Keychain errors into missing keys."
        )
        XCTAssertTrue(
            protocolDeviceIdentitySource.contains("private func resolveDeviceIdForAuthority() throws") &&
                protocolDeviceIdentitySource.contains("insertDeviceAuthorityIfAbsent") &&
                protocolDeviceIdentitySource.contains("authorityWinnerMissing"),
            "Protocol device ID creation must use a compare-and-set authority transaction so storage failures cannot rotate IDs."
        )
    }

    private static func makeUnsignedJWTForTenantTests(payload: [String: Any]) throws -> String {
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
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "\(base64URL(header)).\(base64URL(body)).test-signature"
    }

    private static func makeWebRTCSmokeBootstrapData(
        runID: String,
        tenantID: String,
        tokenTenantID: String? = nil,
        includeTokenTenantClaim: Bool = true,
        tokenUserMetadataTenantID: String? = nil,
        expiresAtEpochSeconds: Int64,
        xwingPublicKey: Data = Data(repeating: 0xA5, count: 1_216)
    ) throws -> Data {
        var tokenPayload: [String: Any] = ["sub": "fixture-user"]
        if includeTokenTenantClaim {
            tokenPayload["app_metadata"] = ["tenant_id": tokenTenantID ?? tenantID]
        }
        if let tokenUserMetadataTenantID {
            tokenPayload["user_metadata"] = ["tenant_id": tokenUserMetadataTenantID]
        }
        let token = try makeUnsignedJWTForTenantTests(payload: tokenPayload)
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "runId": runID,
                "expiresAtEpochSeconds": expiresAtEpochSeconds,
                "accessToken": token,
                "tenantId": tenantID,
                "connectionCode": "ABCDEFGH",
                "peerDeviceId": "peer-device",
                "peerKEMPublicKeys": [
                    [
                        "suiteWireId": 0x0001,
                        "publicKeyBase64": xwingPublicKey.base64EncodedString()
                    ]
                ]
            ],
            options: [.sortedKeys]
        )
    }

    private static func crossNetworkWebRTCManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func localWebRTCSmokeHarnessSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/App/Smoke/LocalWebRTCSmokeHarness.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func platformAdapterSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/Platform/PlatformAdapter.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func p2pKEMIdentityKeyStoreSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/Trust/P2PKEMIdentityKeyStore.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func pqcCryptoManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/PQCCryptoManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func protocolDeviceIdentitySource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/ProtocolDeviceIdentity.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func crossNetworkWebRTCRebindPolicySource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCManager+CurrentPathRebindPolicy.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func crossNetworkWebRTCPQCHandshakePolicySource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkWebRTCPQCHandshakePolicy.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func crossNetworkSignalServerClientSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func keychainManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Core/Security/KeychainManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func authenticationManagerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Managers/AuthenticationManager.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

    private static func supabaseServiceSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "SkyBridgeCompassiOS/Sources/Auth/SupabaseService.swift"
        )
        return try readRepositorySourceForSourceShapeTests(at: sourceURL)
    }

}

private final class SmokeAppendFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFailures: [String] = []

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailures
    }

    func record(_ error: Error) {
        lock.lock()
        recordedFailures.append(String(describing: error))
        lock.unlock()
    }
}

@available(iOS 17.0, *)
private actor IOSKeychainExecutorProbe {
    private nonisolated let executor = IOSKeychainSerialExecutor(
        label: "com.skybridge.compass.ios.keychain.tests"
    )

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func isRunningOnMainThread() -> Bool {
        Thread.isMainThread
    }
}
