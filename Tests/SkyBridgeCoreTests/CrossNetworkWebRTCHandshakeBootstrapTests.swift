import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkWebRTCHandshakeBootstrapTests: XCTestCase {
    func testCompletedHandshakeSetupFailureDoesNotEnterRollback() {
        let disposition = CrossNetworkConnectionManager.webRTCSetupFailureDisposition(
            exactSessionIsCurrent: true,
            isHandshakeComplete: true
        )
        var rollbackCount = 0
        if disposition == .rollback {
            rollbackCount += 1
        }

        XCTAssertEqual(disposition, .preserveCompletedSession)
        XCTAssertEqual(rollbackCount, 0)
        XCTAssertEqual(
            CrossNetworkConnectionManager.webRTCSetupFailureDisposition(
                exactSessionIsCurrent: true,
                isHandshakeComplete: false
            ),
            .rollback
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.webRTCSetupFailureDisposition(
                exactSessionIsCurrent: false,
                isHandshakeComplete: true
            ),
            .rollback
        )
    }

    func testOfferStartGatePreventsStaleSameIDTaskFromClearingReplacement() {
        var gate = WebRTCSessionStartGate()
        let admission = gate.captureAdmissionWitness()
        XCTAssertNotNil(admission)
        let first = admission.flatMap {
            gate.begin(sessionID: "same-session", admissionWitness: $0)
        }
        XCTAssertNotNil(first)
        if let admission {
            XCTAssertNil(
                gate.begin(sessionID: "same-session", admissionWitness: admission)
            )
        }

        gate.invalidate(sessionID: "same-session")
        let replacement = admission.flatMap {
            gate.begin(sessionID: "same-session", admissionWitness: $0)
        }
        XCTAssertNotNil(replacement)
        if let first {
            XCTAssertFalse(gate.isCurrent(first, sessionID: "same-session"))
            XCTAssertFalse(gate.finish(first, sessionID: "same-session"))
        }
        if let replacement {
            XCTAssertTrue(gate.isCurrent(replacement, sessionID: "same-session"))
            XCTAssertTrue(gate.finish(replacement, sessionID: "same-session"))
        }
        XCTAssertFalse(gate.hasPendingStart(sessionID: "same-session"))
    }

    func testOfferStartGateInvalidateAllRetiresEveryPendingStartBeforeReplacement() {
        var gate = WebRTCSessionStartGate()
        let admission = gate.captureAdmissionWitness()
        XCTAssertNotNil(admission)
        let first = admission.flatMap {
            gate.begin(sessionID: "session-a", admissionWitness: $0)
        }
        let second = admission.flatMap {
            gate.begin(sessionID: "session-b", admissionWitness: $0)
        }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        let suspension = gate.suspendAndInvalidateAll()
        XCTAssertNil(gate.captureAdmissionWitness())

        if let first {
            XCTAssertFalse(gate.isCurrent(first, sessionID: "session-a"))
            XCTAssertFalse(gate.finish(first, sessionID: "session-a"))
        }
        if let second {
            XCTAssertFalse(gate.isCurrent(second, sessionID: "session-b"))
            XCTAssertFalse(gate.finish(second, sessionID: "session-b"))
        }
        if let admission {
            XCTAssertNil(
                gate.begin(sessionID: "session-a", admissionWitness: admission)
            )
        }

        gate.resumeAdmission(ifOwnedBy: suspension)
        if let admission {
            XCTAssertFalse(gate.isCurrent(admission))
        }
        let replacementAdmission = gate.captureAdmissionWitness()
        XCTAssertNotNil(replacementAdmission)
        let replacement = replacementAdmission.flatMap {
            gate.begin(sessionID: "session-a", admissionWitness: $0)
        }
        XCTAssertNotNil(replacement)
        if let replacement {
            XCTAssertTrue(gate.isCurrent(replacement, sessionID: "session-a"))
        }
    }

    func testSessionStartAdmissionRemainsSuspendedUntilEveryDisconnectOwnerFinishes() {
        var gate = WebRTCSessionStartGate()
        let initialAdmission = gate.captureAdmissionWitness()
        XCTAssertNotNil(initialAdmission)

        let firstDisconnect = gate.suspendAndInvalidateAll()
        let secondDisconnect = gate.suspendAndInvalidateAll()
        gate.resumeAdmission(ifOwnedBy: firstDisconnect)

        XCTAssertNil(gate.captureAdmissionWitness())
        if let initialAdmission {
            XCTAssertFalse(gate.isCurrent(initialAdmission))
        }

        gate.resumeAdmission(ifOwnedBy: secondDisconnect)
        XCTAssertNotNil(gate.captureAdmissionWitness())
    }

    func testSessionStartTerminalClaimIsExactAndCannotClearReplacement() throws {
        var gate = WebRTCSessionStartGate()
        let admission = try XCTUnwrap(gate.captureAdmissionWitness())
        let original = try XCTUnwrap(
            gate.begin(sessionID: "same-session", admissionWitness: admission)
        )

        XCTAssertTrue(gate.finish(original, sessionID: "same-session"))
        XCTAssertFalse(gate.finish(original, sessionID: "same-session"))

        let replacement = try XCTUnwrap(
            gate.begin(sessionID: "same-session", admissionWitness: admission)
        )
        XCTAssertFalse(gate.finish(original, sessionID: "same-session"))
        XCTAssertTrue(gate.isCurrent(replacement, sessionID: "same-session"))
    }

    func testIssuedConnectionCodeValidationAcceptsCommittedRotationAndRejectsStaleReturn() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let issued = CrossNetworkConnectionManager.IssuedConnectionCode(
            code: "87654321",
            sessionID: "rotated-session",
            expiresAt: expiry,
            leaseMode: .dayStable
        )

        XCTAssertTrue(
            CrossNetworkConnectionManager.issuedConnectionCodeMatchesCurrentState(
                issued,
                admissionAvailable: true,
                currentCode: issued.code,
                currentExpiresAt: expiry,
                currentLeaseMode: .dayStable,
                currentSessionID: issued.sessionID,
                hasCurrentSessionOwner: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.issuedConnectionCodeMatchesCurrentState(
                issued,
                admissionAvailable: false,
                currentCode: issued.code,
                currentExpiresAt: expiry,
                currentLeaseMode: .dayStable,
                currentSessionID: issued.sessionID,
                hasCurrentSessionOwner: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.issuedConnectionCodeMatchesCurrentState(
                issued,
                admissionAvailable: true,
                currentCode: nil,
                currentExpiresAt: nil,
                currentLeaseMode: nil,
                currentSessionID: nil,
                hasCurrentSessionOwner: false
            )
        )
    }

    func testConnectionCodeAnswerersKeepTerminalOwnershipThroughJoinAndRollback() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let codeAnswerer = try sourceSlice(
            from: "private func performConnectWithCode(",
            to: "private func scheduleConnectionCodeLeaseInvalidation(",
            in: source
        )
        XCTAssertFalse(
            codeAnswerer.contains(
                "defer {\n                webRTCSessionStartGate.finish"
            )
        )
        XCTAssertGreaterThanOrEqual(
            codeAnswerer.components(separatedBy: "webRTCSessionStartGate.finish(").count - 1,
            2
        )
        let codeCompletedSession = try XCTUnwrap(
            codeAnswerer.range(of: "Self.webRTCSetupFailureDisposition(")
        )
        let codeRollback = try XCTUnwrap(
            codeAnswerer.range(
                of: "cleanupWebRTCSession(",
                range: codeCompletedSession.upperBound..<codeAnswerer.endIndex
            )
        )
        XCTAssertLessThan(codeCompletedSession.lowerBound, codeRollback.lowerBound)
        XCTAssertTrue(
            codeAnswerer[codeCompletedSession.lowerBound..<codeRollback.lowerBound]
                .contains("return RemoteConnection(")
        )

        let offerer = try sourceSlice(
            from: "private func startWebRTCOfferSessionWithDynamicCredentials(",
            to: "private func establishWebRTCConnection(\n        sessionID: String,",
            in: source
        )
        let offererCompletedSession = try XCTUnwrap(
            offerer.range(of: "Self.webRTCSetupFailureDisposition(")
        )
        let offererRollback = try XCTUnwrap(
            offerer.range(
                of: "cleanupWebRTCSession(",
                range: offererCompletedSession.upperBound..<offerer.endIndex
            )
        )
        XCTAssertLessThan(offererCompletedSession.lowerBound, offererRollback.lowerBound)
        XCTAssertTrue(
            offerer[offererCompletedSession.lowerBound..<offererRollback.lowerBound]
                .contains("return")
        )

        let qrAnswerer = try sourceSlice(
            from: "private func establishWebRTCConnection(\n        sessionID: String,",
            to: "private func authenticatedEnvelope(",
            in: source
        )
        let join = try XCTUnwrap(
            qrAnswerer.range(of: "try await sendWebRTCJoinSignal")
        )
        let rollback = try XCTUnwrap(
            qrAnswerer.range(of: "reason: error is CancellationError")
        )
        let rollbackCatch = try XCTUnwrap(
            qrAnswerer.range(of: "} catch {", options: .backwards)
        )
        XCTAssertLessThan(join.lowerBound, rollbackCatch.lowerBound)
        XCTAssertLessThan(rollbackCatch.lowerBound, rollback.lowerBound)
        XCTAssertTrue(
            qrAnswerer[rollbackCatch.lowerBound..<rollback.lowerBound].contains(
                "webRTCSessionStartGate.finish(sessionStartToken, sessionID: sessionID)"
            )
        )
        let qrCompletedSession = try XCTUnwrap(
            qrAnswerer.range(of: "Self.webRTCSetupFailureDisposition(")
        )
        XCTAssertLessThan(qrCompletedSession.lowerBound, rollback.lowerBound)
        XCTAssertTrue(
            qrAnswerer[qrCompletedSession.lowerBound..<rollback.lowerBound]
                .contains("return RemoteConnection(")
        )
    }

    func testOutboundSignalingBindsExactSessionAndClientAcrossSuspensions() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let joinBootstrap = try sourceSlice(
            from: "private func webRTCJoinBootstrapPayload(",
            to: "private func sendWebRTCJoinSignal(",
            in: source
        )
        XCTAssertTrue(joinBootstrap.contains("for session: WebRTCSession"))
        XCTAssertGreaterThanOrEqual(
            joinBootstrap.components(separatedBy: "requireCurrentWebRTCSession(").count - 1,
            3
        )
        let finalOwnerCheck = try XCTUnwrap(
            joinBootstrap.range(of: "try requireCurrentWebRTCSession(", options: .backwards)
        )
        let cacheCommit = try XCTUnwrap(
            joinBootstrap.range(of: "webrtcJoinBootstrapPayloadBySessionId[sessionID] = payload")
        )
        XCTAssertLessThan(finalOwnerCheck.lowerBound, cacheCommit.lowerBound)

        let requiredSend = try sourceSlice(
            from: "private func sendRequiredSetupSignal(",
            to: "private func connectedSignalingClient(",
            in: source
        )
        XCTAssertTrue(requiredSend.contains("ownerSession: WebRTCSession"))
        XCTAssertTrue(requiredSend.contains("let client = try await connectedSignalingClient("))
        XCTAssertTrue(requiredSend.contains("try await client.send(authorizedEnvelope)"))
        XCTAssertGreaterThanOrEqual(
            requiredSend.components(separatedBy: "requireCurrentWebRTCSession(").count - 1,
            5
        )
        XCTAssertTrue(requiredSend.contains("requireCurrentSignalingClient("))
        XCTAssertTrue(requiredSend.contains("shouldDeferCurrentSignalingSend("))
        XCTAssertTrue(requiredSend.contains("return .supersededByHandshakeCompletion"))

        let joinSend = try sourceSlice(
            from: "private func sendWebRTCJoinSignal(",
            to: "private func ingestWebRTCJoinBootstrapPayload(",
            in: source
        )
        let bootstrapCatch = try XCTUnwrap(joinSend.range(of: "} catch {"))
        let bootstrapSupersession = try XCTUnwrap(
            joinSend.range(of: "return .supersededByHandshakeCompletion")
        )
        let strictPolicy = try XCTUnwrap(
            joinSend.range(of: "if try strictPQCHandshakeRequested")
        )
        XCTAssertLessThan(bootstrapCatch.lowerBound, bootstrapSupersession.lowerBound)
        XCTAssertLessThan(bootstrapSupersession.lowerBound, strictPolicy.lowerBound)

        let ordinarySend = try sourceSlice(
            from: "private func sendSignal(",
            to: "private func handleSignalingServerFrame(",
            in: source
        )
        XCTAssertTrue(ordinarySend.contains("ownerSession: WebRTCSession"))
        XCTAssertTrue(ordinarySend.contains("connectedSignalingClient("))
        XCTAssertTrue(ordinarySend.contains("signalingClient === client"))
        XCTAssertGreaterThanOrEqual(
            ordinarySend.components(separatedBy: "shouldDeferCurrentSignalingSend(").count - 1,
            3
        )
        XCTAssertFalse(ordinarySend.contains("let handshakeComplete ="))
        XCTAssertFalse(
            ordinarySend.contains(
                "if let signalingClient {\n                    try await signalingClient.connectOrThrow()"
            )
        )
        let rejectionPolicy = try XCTUnwrap(
            ordinarySend.range(of: "if error is SignalingOperationRejection")
        )
        let exactAttemptGate = try XCTUnwrap(
            ordinarySend.range(of: "guard let attemptedClient,")
        )
        XCTAssertLessThan(rejectionPolicy.lowerBound, exactAttemptGate.lowerBound)
        XCTAssertTrue(ordinarySend.contains("signalingClient === attemptedClient"))
        XCTAssertFalse(ordinarySend.contains("signalingClient == nil, signalingShardKey == nil"))
        XCTAssertFalse(ordinarySend.contains("signalingAttemptIsCurrent"))
    }

    func testSessionCleanupDetachesExactSignalingClientBeforeOtherTeardown() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let cleanup = try sourceSlice(
            from: "private func cleanupWebRTCSession(",
            to: "func sealWebRTCSecurePayload(",
            in: source
        )
        let teardown = try XCTUnwrap(
            cleanup.range(of: "signalingLifecycle.teardown(sessionID: sessionID)")
        )
        let detachClient = try XCTUnwrap(
            cleanup.range(of: "signalingClient = nil")
        )
        let detachShard = try XCTUnwrap(
            cleanup.range(of: "signalingShardKey = nil")
        )
        let notice = try XCTUnwrap(
            cleanup.range(of: "notifyWebRTCTerminalSessionIfNeeded(")
        )

        XCTAssertLessThan(teardown.lowerBound, notice.lowerBound)
        XCTAssertLessThan(detachClient.lowerBound, notice.lowerBound)
        XCTAssertLessThan(detachShard.lowerBound, notice.lowerBound)
        XCTAssertTrue(cleanup.contains("await signalingClientToClose.close()"))
    }

    func testSignalingFailuresCannotOverwriteAnotherSessionsGlobalState() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let serverFrame = try sourceSlice(
            from: "private func handleSignalingServerFrame(",
            to: "private func handleSignalingEnvelope(",
            in: source
        )
        XCTAssertTrue(serverFrame.contains("let sourceSession = webrtcSessionsBySessionId[sourceShard]"))
        XCTAssertTrue(serverFrame.contains("let sourceOwnsGlobalState = isCurrentGlobalWebRTCSetup("))
        XCTAssertTrue(serverFrame.contains("declaredSessionID != sourceShard"))
        XCTAssertTrue(serverFrame.contains("?? sourceShard"))
        XCTAssertFalse(serverFrame.contains("webrtcSessionsBySessionId.keys.contains"))
        XCTAssertGreaterThanOrEqual(
            serverFrame.components(separatedBy: "if sourceOwnsGlobalState {").count - 1,
            3
        )
        XCTAssertTrue(serverFrame.contains("let shouldCommitGlobalFailure = sourceOwnsGlobalState"))
        XCTAssertTrue(serverFrame.contains("reason: \"signaling_server_error:\\(failureCode)\""))
        XCTAssertTrue(serverFrame.contains("if shouldCommitGlobalFailure {"))

        let codeAnswerer = try sourceSlice(
            from: "private func performConnectWithCode(",
            to: "private func scheduleConnectionCodeLeaseInvalidation(",
            in: source
        )
        XCTAssertTrue(codeAnswerer.contains("shouldCommitGlobalFailure = isCurrentGlobalWebRTCSetup("))

        let qrAnswerer = try sourceSlice(
            from: "private func establishWebRTCConnection(\n        sessionID: String,",
            to: "private func authenticatedEnvelope(",
            in: source
        )
        XCTAssertTrue(qrAnswerer.contains("let shouldCommitGlobalFailure = isCurrentGlobalWebRTCSetup("))
    }

    func testDisconnectInvalidatesPendingOfferStartsBeforeItsFirstSuspension() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let disconnectBody = try sourceSlice(
            from: "public func disconnect() async {",
            to: "// MARK: - Route Attribution",
            in: source
        )
        let invalidation = try XCTUnwrap(
            disconnectBody.range(
                of: "webRTCSessionStartGate.suspendAndInvalidateAll()"
            )
        )
        let trackedTaskCancellation = try XCTUnwrap(
            disconnectBody.range(of: "pendingConnectionCodeTasks.forEach { $0.cancel() }")
        )
        let firstSuspension = try XCTUnwrap(disconnectBody.range(of: "await "))

        XCTAssertLessThan(invalidation.lowerBound, firstSuspension.lowerBound)
        XCTAssertLessThan(trackedTaskCancellation.lowerBound, firstSuspension.lowerBound)
        XCTAssertTrue(
            source.contains(
                "let admissionWitness = try captureWebRTCSessionStartAdmission()"
            )
        )
        XCTAssertTrue(
            source.contains(
                "var admissionWitness = try captureWebRTCSessionStartAdmission()"
            )
        )
        XCTAssertTrue(
            source.contains(
                "admissionWitness: WebRTCSessionStartGate.AdmissionWitness"
            )
        )
        XCTAssertTrue(
            source.contains(
                "guard let sessionStartToken = webRTCSessionStartGate.begin("
            )
        )
        XCTAssertTrue(source.contains("[weak self, weak client] env in"))
        XCTAssertTrue(source.contains("[weak self, weak client] frame in"))
        XCTAssertTrue(source.contains("[weak self, weak client] event in"))
        XCTAssertTrue(source.contains("guard signalingClient === sourceClient,"))

        let signalingSetup = try sourceSlice(
            from: "private func ensureSignalingConnected(shardKey: String) async throws {",
            to: "private func requireCurrentPendingSignalingSetup(",
            in: source
        )
        let envelopeRegistration = try XCTUnwrap(
            signalingSetup.range(of: "await client.setOnEnvelope")
        )
        let serverFrameRegistration = try XCTUnwrap(
            signalingSetup.range(of: "await client.setOnServerFrame")
        )
        let lifecycleRegistration = try XCTUnwrap(
            signalingSetup.range(of: "await client.setOnLifecycleEvent")
        )
        let clientPublication = try XCTUnwrap(
            signalingSetup.range(of: "signalingClient = client")
        )
        let clientConnect = try XCTUnwrap(
            signalingSetup.range(
                of: "try await client.connectOrThrow()",
                range: clientPublication.upperBound..<signalingSetup.endIndex
            )
        )
        XCTAssertLessThan(envelopeRegistration.lowerBound, clientPublication.lowerBound)
        XCTAssertLessThan(serverFrameRegistration.lowerBound, clientPublication.lowerBound)
        XCTAssertLessThan(lifecycleRegistration.lowerBound, clientPublication.lowerBound)
        XCTAssertLessThan(clientPublication.lowerBound, clientConnect.lowerBound)
        XCTAssertGreaterThanOrEqual(
            signalingSetup.components(
                separatedBy: "requireCurrentPendingSignalingSetup("
            ).count - 1,
            3
        )

        let connectWrapper = try sourceSlice(
            from: "public func connectWithCode(_ code: String) async throws -> RemoteConnection {",
            to: "private func performConnectWithCode(",
            in: source
        )
        XCTAssertGreaterThanOrEqual(
            connectWrapper.components(
                separatedBy: "try requireCurrentWebRTCSessionStartAdmission(admissionWitness)"
            ).count - 1,
            3
        )
    }

    func testExactCurrentPathMLDSA87AuthorityRequiresRawKeyFingerprintMatch() {
        let publicKey = Data(repeating: 0x87, count: 2_592)
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: publicKey
        )
        let authority = CurrentPathRemoteAuthority(
            deviceId: "id:remote-device-87",
            protocolSigningAlgorithm: .mlDSA87,
            protocolPublicKeyFingerprint: fingerprint,
            protocolPublicKeyBytes: publicKey,
            deviceName: nil
        )

        XCTAssertTrue(CrossNetworkConnectionManager.isExactMLDSA87Authority(authority))
        XCTAssertFalse(
            CrossNetworkConnectionManager.isExactMLDSA87Authority(
                CurrentPathRemoteAuthority(
                    deviceId: authority.deviceId,
                    protocolSigningAlgorithm: .mlDSA87,
                    protocolPublicKeyFingerprint: String(repeating: "0", count: 64),
                    protocolPublicKeyBytes: publicKey,
                    deviceName: nil
                )
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.isExactMLDSA87Authority(
                CurrentPathRemoteAuthority(
                    deviceId: authority.deviceId,
                    protocolSigningAlgorithm: .mlDSA87,
                    protocolPublicKeyFingerprint: fingerprint,
                    protocolPublicKeyBytes: nil,
                    deviceName: nil
                )
            )
        )
    }

    func testOutboundWebRTCMLDSA87SelectionRequiresExactRemoteAuthority() {
        XCTAssertEqual(
            CrossNetworkConnectionManager.selectWebRTCOutboundProtocolIdentity(
                requestedAlgorithm: .mlDSA87,
                requestedProtection: .secureEnclaveRequired,
                remoteHasExactMLDSA87Authority: false
            ),
            .init(
                algorithm: .mlDSA65,
                protection: .softwareKeychain,
                mode: .peerCompatibilityIdentity
            )
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.selectWebRTCOutboundProtocolIdentity(
                requestedAlgorithm: .mlDSA87,
                requestedProtection: .secureEnclaveRequired,
                remoteHasExactMLDSA87Authority: true
            ),
            .init(
                algorithm: .mlDSA87,
                protection: .secureEnclaveRequired,
                mode: .configuredAuthority
            )
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.selectWebRTCOutboundProtocolIdentity(
                requestedAlgorithm: .mlDSA65,
                requestedProtection: .secureEnclaveRequired,
                remoteHasExactMLDSA87Authority: true
            ),
            .init(
                algorithm: .mlDSA65,
                protection: .secureEnclaveRequired,
                mode: .configuredAuthority
            )
        )
    }

    func testCrossNetworkPresenceUsesStableDeviceIdWhenAvailable() {
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: "remote-device-alpha"
            ),
            "id:remote-device-alpha"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: "id:REMOTE-DEVICE-ALPHA"
            ),
            "id:remote-device-alpha"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: "cross-network:session-route-2"
            ),
            "cross-network:session-route-1"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: nil
            ),
            "cross-network:session-route-1"
        )
    }

    func testInitialWebRTCHandshakeStartsFromOffererOnly() {
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: .offerer)
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: .answerer)
        )
    }

    func testInitialWebRTCHandshakeUsesClassicForAuthorityBoundQRAndCodeSessions() {
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "code-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: "code-session"
            )
        )
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "pqc-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .mlDSA65,
                activeConnectionCodeSessionID: nil
            )
        )
    }

    func testStrictPQCInitialWebRTCHandshakeDoesNotUseClassicAuthorityBootstrap() {
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: nil,
                strictPQCRequested: true
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "code-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: "code-session",
                strictPQCRequested: true
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                activeConnectionCodeSessionID: nil,
                strictPQCRequested: true
            )
        )
    }

    func testStrictInboundInitialRejectsClassicAuthorityBootstrap() {
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: nil
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .mlDSA65
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.mlkem768MLDSA65],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
    }

    func testInitialWebRTCHandshakePeerResolutionPrefersConcreteRemoteDeviceId() {
        let resolution = WebRTCPQCHandshakePolicy.initialWebRTCHandshakePeerResolution(
            expectedRemoteDeviceId: nil,
            learnedRemoteDeviceId: "E0715A9A-D0D3-47E6-B353-DE0A30293E1F",
            endpointDescription: "webrtc:session-1"
        )

        XCTAssertEqual(resolution.resolvedPeerDeviceId, "E0715A9A-D0D3-47E6-B353-DE0A30293E1F")
        XCTAssertEqual(
            resolution.candidateIds,
            ["E0715A9A-D0D3-47E6-B353-DE0A30293E1F", "webrtc:session-1"]
        )
    }

    func testStrictPQCHandshakeWaitsUntilRemoteIdentityAndTrustedKEMAreReady() {
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: nil,
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: "peer-1",
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: "peer-1",
                hasTrustedPeerKEM: true
            )
        )
    }

    func testInitialWebRTCHandshakeBootstrapDecisionPreservesClassicBootstrapOnlyBeforeTrust() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEM: true,
                capability: capability,
                useClassicAuthorityBootstrap: true,
                peerDeviceId: "peer-a"
            ),
            .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_authority_bootstrap",
                usesClassicAuthorityBootstrap: true
            ))
        )
        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEM: false,
                capability: capability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-a"
            ),
            .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_bootstrap",
                usesClassicAuthorityBootstrap: false
            ))
        )
    }

    func testInitialWebRTCHandshakeBootstrapDecisionRequiresPQCWhenTrustAndProviderExist() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: true,
            osVersion: "test"
        )

        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEM: true,
                capability: capability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-a"
            ),
            .proceed(.init(
                selection: .requirePQC,
                bootstrapMode: "trusted_kem",
                usesClassicAuthorityBootstrap: false
            ))
        )
    }

    func testInitialWebRTCHandshakeBootstrapDecisionKeepsNonStrictNoProviderCompatibilityExplicit() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: false,
            osVersion: "test"
        )

        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEM: true,
                capability: capability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-a"
            ),
            .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_bootstrap_no_local_pqc_provider",
                usesClassicAuthorityBootstrap: false
            ))
        )
    }

    func testInitialWebRTCHandshakeBootstrapDecisionRejectsStrictPQCWithoutTrustOrProvider() {
        let noProviderCapability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: false,
            osVersion: "test"
        )

        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: true,
                hasTrustedPeerKEM: false,
                capability: noProviderCapability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-b"
            ),
            .reject(.init(
                code: 701,
                message: "严格 PQC 已启用，但 WebRTC 对端 authoritative deviceId / 受信任 KEM 尚未就绪；当前已拒绝 classic bootstrap。peer=peer-b",
                includeProviderAvailabilityInLog: false
            ))
        )
        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: true,
                hasTrustedPeerKEM: true,
                capability: noProviderCapability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-b"
            ),
            .reject(.init(
                code: 702,
                message: "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；WebRTC 初始握手不会再降级到 Classic。",
                includeProviderAvailabilityInLog: true
            ))
        )
    }

    func testInitialWebRTCHandshakeBootstrapDecisionRejectsStrictPQCClassicAuthorityBootstrap() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        XCTAssertEqual(
            WebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: true,
                hasTrustedPeerKEM: true,
                capability: capability,
                useClassicAuthorityBootstrap: true,
                peerDeviceId: "peer-c"
            ),
            .reject(.init(
                code: 703,
                message: "严格 PQC 已启用，但 WebRTC 初始握手请求 classic authority bootstrap；当前已拒绝 classic bootstrap。peer=peer-c",
                includeProviderAvailabilityInLog: false
            ))
        )
    }

    func testWebRTCPQCRekeyPlansPreferXWingOnlyWhenPeerHasXWing() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let mlkemOnlyPlans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: false,
            appleXWingAvailable: true
        )
        XCTAssertEqual(mlkemOnlyPlans.first?.label, "native-pqc")
        XCTAssertEqual(mlkemOnlyPlans.first?.suites, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])

        let xwingPlans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: true,
            appleXWingAvailable: true
        )
        XCTAssertEqual(xwingPlans.first?.label, "native-xwing")
        XCTAssertEqual(xwingPlans.first?.suites, [.xwingMLDSA])
    }

    func testWebRTCPQCRekeyPlansPreferApplePQCBeforeLiboqsForInteropPeers() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: true,
            peerHasXWing: false,
            appleXWingAvailable: true
        )

        XCTAssertEqual(plans.first?.label, "native-pqc")
        XCTAssertEqual(plans.first?.suites, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
        XCTAssertEqual(plans.dropFirst().first?.label, "liboqs-fallback")
    }

    func testWebRTCPQCRekeyPlansUseLiboqsWhenApplePQCUnavailable() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: true,
            peerHasXWing: false,
            appleXWingAvailable: false
        )

        XCTAssertEqual(plans.first?.label, "liboqs")
        XCTAssertEqual(plans.first?.suites, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
    }

    func testWebRTCInboundResponderFallsBackToClassicOnlyWhenPolicyAllowsIt() {
        let fallbackSelection = CrossNetworkConnectionManager.selectWebRTCInboundResponder(
            peerSupportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            policy: HandshakePolicy(
                requirePQC: false,
                allowClassicFallback: false,
                minimumTier: .classic
            ),
            environment: MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        )

        XCTAssertNotNil(fallbackSelection)
        XCTAssertEqual(fallbackSelection?.selectionPolicy, .classicOnly)
        XCTAssertEqual(fallbackSelection?.cryptoProvider.tier, .classic)
        XCTAssertEqual(fallbackSelection?.sigAAlgorithm, .ed25519)
        XCTAssertTrue(fallbackSelection?.fellBackToClassic == true)
        XCTAssertTrue(fallbackSelection?.offeredSuites.allSatisfy { !$0.isPQCGroup } == true)
    }

    func testWebRTCInboundResponderRejectsClassicOnlyPeerWhenStrictPQCRequiresPQC() {
        let selection = CrossNetworkConnectionManager.selectWebRTCInboundResponder(
            peerSupportedSuites: [.x25519Ed25519],
            policy: .strictPQC,
            environment: MockCryptoEnvironment(hasApplePQC: true, hasLiboqs: true)
        )

        XCTAssertNil(selection)
    }

    func testWebRTCInboundResponderRejectsClassicFallbackWhenStrictPQCRequiresLocalPQC() {
        let selection = CrossNetworkConnectionManager.selectWebRTCInboundResponder(
            peerSupportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            policy: HandshakePolicy(
                requirePQC: true,
                allowClassicFallback: false,
                minimumTier: .nativePQC
            ),
            environment: MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        )

        XCTAssertNil(selection)
    }

    func testWebRTCInboundResponderUsesLiboqsWhenApplePQCUnavailableButLiboqsAvailable() {
        let selection = CrossNetworkConnectionManager.selectWebRTCInboundResponder(
            peerSupportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            policy: HandshakePolicy(
                requirePQC: true,
                allowClassicFallback: false,
                minimumTier: .nativePQC
            ),
            environment: MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)
        )

        XCTAssertEqual(selection?.selectionPolicy, .requirePQC)
        XCTAssertEqual(selection?.cryptoProvider.tier, .liboqsPQC)
        XCTAssertEqual(selection?.sigAAlgorithm, .mlDSA65)
        XCTAssertFalse(selection?.fellBackToClassic == true)
        XCTAssertTrue(selection?.offeredSuites.contains(where: { $0.isPQCGroup }) == true)
    }

    func testWebRTCPQCRekeySharedSuitesCanonicalizeMLKEMForwardSecureKeys() {
        let sharedFromBaseKey = WebRTCPQCHandshakePolicy.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.mlkem768MLDSA65.wireId: Data([0x99])]
        )
        XCTAssertEqual(sharedFromBaseKey, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])

        let sharedFromFSKey = WebRTCPQCHandshakePolicy.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.mlkem768MLDSA65FS.wireId: Data([0x98])]
        )
        XCTAssertEqual(sharedFromFSKey, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
    }

    func testWebRTCPQCRekeySharedSuitesDoNotTreatXWingAsMLKEM() {
        let shared = WebRTCPQCHandshakePolicy.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.xwingMLDSA.wireId: Data([0x42])]
        )
        XCTAssertTrue(shared.isEmpty)
    }

    func testRemoteJoinWakesAuthorityBoundOffererOnlyWhenSessionIsMissing() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: true,
                pendingOfferStart: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: true,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: false,
                authorityBoundBootstrap: false,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: false
            )
        )
    }

    func testRemoteJoinRecoversMissingOfferCacheOnlyForAuthorityBoundOfferer() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: false,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: false,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: true,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: false,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: false
            )
        )
    }

    func testRemoteJoinResendsLocalJoinBootstrapOnlyFromOfferer() throws {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldResendOffererJoinBootstrapForRemoteJoin(isOfferer: true)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldResendOffererJoinBootstrapForRemoteJoin(isOfferer: false)
        )

        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        XCTAssertTrue(source.contains("join-bootstrap-resend session=\\(env.sessionId) reason=remote-join"))
        XCTAssertTrue(source.contains("try await sendWebRTCJoinSignal("))
        XCTAssertTrue(source.contains("session: session"))
        XCTAssertTrue(source.contains("catch is CancellationError"))
        XCTAssertTrue(source.contains("await resendOrRecoverLocalOfferForRemoteJoin(sessionID: env.sessionId, session: session)"))
    }

    func testMacWebRTCQueuesPreSessionOfferAnswerAndIceOnly() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        XCTAssertTrue(source.contains("private static let maxPendingPreSessionSignalingEnvelopes = 32"))
        XCTAssertTrue(source.contains("private static let maxTotalPendingPreSessionSignalingEnvelopes = 128"))
        XCTAssertTrue(source.contains("private static let maxPendingPreSessionSignalingEnvelopeBytes = 768 * 1024"))
        XCTAssertTrue(source.contains("private static let maxTotalPendingPreSessionSignalingEnvelopeBytes = 4 * 1024 * 1024"))
        XCTAssertTrue(source.contains("private static func preSessionSignalingEnvelopeByteCount(_ env: WebRTCSignalingEnvelope) -> Int?"))
        XCTAssertTrue(source.contains("private func pendingPreSessionSignalingQueueMetrics() -> (count: Int, bytes: Int)?"))
        XCTAssertTrue(source.contains("pre_session_signaling_global_queue_overflow"))
        XCTAssertTrue(source.contains("pre_session_signaling_envelope_too_large"))
        XCTAssertTrue(source.contains("private struct PendingPreSessionSignalingEnvelope"))
        XCTAssertTrue(source.contains("let sourceClient: WebSocketSignalingClient"))
        XCTAssertTrue(source.contains("let admissionWitness: WebRTCSessionStartGate.AdmissionWitness"))
        XCTAssertTrue(source.contains("private func enqueuePreSessionSignalingEnvelope("))
        XCTAssertTrue(source.contains("pre-session signaling queue overflow"))
        XCTAssertTrue(source.contains("cleanupReason: \"pre_session_signaling_queue_overflow\""))
        XCTAssertTrue(source.contains("case .offer, .answer, .iceCandidate:"))
        XCTAssertTrue(source.contains("case .join, .leave:"))
        XCTAssertTrue(source.contains("private func drainPendingPreSessionSignalingEnvelopes("))
        XCTAssertTrue(source.contains("sourceClient: record.sourceClient"))
        XCTAssertTrue(source.contains("admissionWitness: record.admissionWitness"))
        XCTAssertTrue(source.contains("ownerSession: session"))
        XCTAssertTrue(source.contains("pendingPreSessionSignalingEnvelopesBySessionId.removeValue(forKey: sessionID)"))
        XCTAssertTrue(
            source.contains(
                "enqueuePreSessionSignalingEnvelope(\n                    env,\n                    sourceClient: sourceClient,\n                    admissionWitness: admissionWitness\n                )"
            ),
            "Offer/answer/ICE arriving before session start must enter the bounded queue with the exact signaling client and admission witness."
        )
    }

    func testMacJoinBootstrapMutationIsAuthorityAndSignalingOwnerBound() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let ingest = try sourceSlice(
            from: "private func ingestWebRTCJoinBootstrapPayload(",
            to: "/// Stores an early-arriving join bootstrap",
            in: source
        )

        XCTAssertTrue(ingest.contains("sourceClient: WebSocketSignalingClient"))
        XCTAssertTrue(ingest.contains("admissionWitness: WebRTCSessionStartGate.AdmissionWitness"))
        XCTAssertTrue(ingest.contains("ownerSession: WebRTCSession?"))
        XCTAssertTrue(ingest.contains("upsertAuthorityBoundPairingKEM("))
        XCTAssertTrue(ingest.contains("rollbackAuthorityBoundPairingKEMMutation(receipt)"))
        XCTAssertTrue(ingest.contains("currentPathExpectedRemoteAuthorityBySessionId[sessionID] == authorityBeforeMutation"))
        XCTAssertFalse(ingest.contains("PeerKEMBootstrapStore.shared.upsert("))
        let receiptMutation = try XCTUnwrap(
            ingest.range(of: "upsertAuthorityBoundPairingKEM(")
        )
        let authorityCommit = try XCTUnwrap(
            ingest.range(of: "currentPathExpectedRemoteAuthorityBySessionId[sessionID] = authorityToCommit")
        )
        XCTAssertLessThan(receiptMutation.lowerBound, authorityCommit.lowerBound)
    }

    func testQRCodeBootstrapUsesLongerStartupWindowsThanRuntimeHeartbeat() {
        XCTAssertGreaterThanOrEqual(
            CrossNetworkConnectionManager.qrCodeGenerationWatchdogTimeoutSeconds,
            30
        )
        XCTAssertGreaterThanOrEqual(
            CrossNetworkConnectionManager.qrCodeScanBootstrapWatchdogTimeoutSeconds,
            90
        )
        XCTAssertGreaterThanOrEqual(
            CrossNetworkConnectionManager.webRTCStartupJoinHeartbeatAttempts,
            60
        )
    }

    func testLocalP2PKEMBootstrapQRCodePathIsRemoved() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let harness = try readSource("Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift")

        XCTAssertFalse(
            source.contains("generateSignedP2PKEMBootstrapQRCode"),
            "P2P KEM recovery must not expose an offline QR generator; stale KEM repair must use SKR-1."
        )
        XCTAssertTrue(source.contains("isP2PKEMBootstrapCapability"))
        XCTAssertTrue(source.contains("P2P KEM QR bootstrap has been removed"))
        XCTAssertTrue(
            source.contains("logVerifiedQRCodeKEMIgnored"),
            "Verified QR material may support route setup, but it must not be persisted as P2P KEM trust."
        )
        XCTAssertTrue(source.contains("不会导入 KEM trust"))
        XCTAssertFalse(
            source.contains("persistVerifiedQRCodeKEMTrust"),
            "A verified QR must not write KEM trust; stale KEM repair must use signed LAN refresh evidence."
        )
        XCTAssertFalse(
            harness.contains("qr-connect-link mode=offline-p2p-kem"),
            "The local file-transfer smoke host must not emit an offline P2P KEM QR link."
        )
        XCTAssertFalse(
            harness.contains("SKYBRIDGE_SMOKE_QR_CONNECT_LINK_FILE"),
            "The smoke host must not accept a QR output path for KEM recovery."
        )
    }

    func testMacFileTransferSmokeKeepsSignedRefreshExplicitAndRejectsQRCode() throws {
        let scriptSource = try readSource("Scripts/run_real_device_file_transfer_smoke.sh")
        XCTAssertTrue(
            scriptSource.contains("SMOKE_BUILD_DIR=\"${SKYBRIDGE_FILE_TRANSFER_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/real-device-file-transfer-smoke}\""),
            "Apple-PQC file-transfer smoke products must not pollute the default SwiftPM build directory."
        )
        XCTAssertTrue(scriptSource.contains("--disable-dependency-cache"))
        XCTAssertTrue(scriptSource.contains("--manifest-cache local"))
        XCTAssertTrue(scriptSource.contains("--scratch-path \"$SMOKE_BUILD_DIR\""))
        XCTAssertTrue(scriptSource.contains("-Xswiftc -warnings-as-errors"))
        XCTAssertTrue(scriptSource.contains("--product LocalLanInteropHost"))
        XCTAssertTrue(scriptSource.contains("MAC_APP_BIN=\"$SMOKE_BUILD_DIR/debug/LocalLanInteropHost\""))
        XCTAssertFalse(scriptSource.contains("$ROOT_DIR/.build/debug/"))
        XCTAssertTrue(
            scriptSource.contains("SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH"),
            "The real-device smoke script must require signed KEM refresh evidence instead of relying on QR bootstrap."
        )
        XCTAssertTrue(
            scriptSource.contains("REQUIRE_SIGNED_KEM_REFRESH=\"${SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH:-0}\""),
            "File-transfer smoke must not clear or rewrite persistent KEM trust by default."
        )
        XCTAssertTrue(
            scriptSource.contains("SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION"),
            "Forced refresh must require an explicit persistent-trust mutation approval."
        )
        XCTAssertFalse(
            scriptSource.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"),
            "File-transfer smoke must exercise explicit or previously-persisted trust, never a runtime auto-approval bypass."
        )
        XCTAssertTrue(
            scriptSource.contains("SKR-1 signed LAN KEM refresh served"),
            "The real-device smoke script must wait for Mac-side SKR-1 served evidence."
        )
        XCTAssertTrue(
            scriptSource.contains("SKR-1 signed LAN KEM refresh verified and imported"),
            "The real-device smoke script must wait for iOS-side SKR-1 verified import evidence."
        )
        XCTAssertTrue(
            scriptSource.contains("SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP has been removed"),
            "Smoke must reject legacy QR KEM bootstrap so a QR path cannot mask KEM recovery."
        )
        XCTAssertFalse(
            scriptSource.contains("qr-connect-link mode=offline-p2p-kem file="),
            "Smoke must not wait for an offline P2P KEM QR link."
        )
        XCTAssertTrue(
            scriptSource.contains("SKYBRIDGE_SMOKE_PIB_APPROVAL_TIMEOUT_SECONDS:-$SMOKE_TIMEOUT_SECONDS"),
            "The real-device smoke script must fail PIB-1 approval as its own stage before the outer smoke timeout hides the cause."
        )
        XCTAssertTrue(
            scriptSource.contains("approve on Mac first if prompted, then approve on iOS within ${PIB_APPROVAL_TIMEOUT_SECONDS}s"),
            "The operator prompt must report the actual bounded PIB-1 approval window and both approval sides."
        )
        XCTAssertTrue(
            scriptSource.contains("requester protocol identity pinned"),
            "The real-device smoke script must wait for Mac-side requester pinning before SKR-1."
        )
        XCTAssertTrue(
            scriptSource.contains("ios_skr_pinned_protocol_identity_pattern"),
            "File-transfer smoke must accept SKR-1 pinnedProtocolIdentity=1 evidence as the iOS-side completion proof for PIB-1-bound trust refresh."
        )
        XCTAssertTrue(
            scriptSource.contains("iOS PIB-1 signature verified or SKR-1 pinned identity proof")
                && scriptSource.contains("iOS PIB-1 pinned or SKR-1 pinned identity proof"),
            "The iOS wait loop must not fail after a completed signed KEM refresh proves the pinned protocol identity."
        )

        let p2pSource = try [
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService+BootstrapControl.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
        XCTAssertTrue(p2pSource.contains("makeBootstrapControlResponse"))
        XCTAssertTrue(p2pSource.contains("RemoteControlSmokeStatusWriter.append(controlResponse.statusLine)"))

        let legacyDiscoverySource = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift")
        XCTAssertTrue(
            legacyDiscoverySource.contains("handlePreHandshakePlaintextControl"),
            "LocalLanInteropHost uses DeviceDiscoveryManager, so its inbound control channel must serve SKR-1 before the handshake."
        )
        XCTAssertTrue(legacyDiscoverySource.contains("P2PDiscoveryService.makeBootstrapControlResponse"))
        XCTAssertTrue(legacyDiscoverySource.contains("RemoteControlSmokeStatusWriter.append(controlResponse.statusLine)"))

        let localHostSource = try readSource("Sources/LocalLanInteropHost/main.swift")
        XCTAssertTrue(localHostSource.contains("ready remote=_skybridge-rd._tcp"))
        XCTAssertTrue(localHostSource.contains("application.run()"))
        XCTAssertTrue(localHostSource.contains("LocalLanInteropHostLifetime.coordinator = coordinator"))
        XCTAssertTrue(localHostSource.contains("RemoteControlSecurityNoticeLocalizationContract.requiredKeys"))
        XCTAssertTrue(localHostSource.contains("appendingPathComponent(\"Resources\", isDirectory: true)"))
        XCTAssertTrue(localHostSource.contains("appendingPathComponent(\"SkyBridgeCompassApp_SkyBridgeCore.bundle\", isDirectory: true)"))
        XCTAssertTrue(localHostSource.contains("embeddedRawKeys=0 managerRawKeys=0 source=embedded-signed-core"))
        XCTAssertTrue(localHostSource.contains("LocalizationManager.shared.localizedString(key) == key"))
        XCTAssertTrue(localHostSource.contains("SKYBRIDGE_SMOKE_REQUIRE_EMBEDDED_CORE_RESOURCES"))
        XCTAssertFalse(localHostSource.contains("SmokeCaptureAnimationSource"))
        XCTAssertFalse(localHostSource.contains("SmokeCaptureAnimationView"))
        XCTAssertFalse(localHostSource.contains("SmokeCaptureMetalRenderer"))
        XCTAssertFalse(localHostSource.contains("SKYBRIDGE_SMOKE_REMOTE_ANIMATION"))
        XCTAssertFalse(localHostSource.contains("import MetalKit"))
        XCTAssertFalse(localHostSource.contains("private let accentLayer = CALayer()"))
        XCTAssertFalse(localHostSource.contains("CATransaction.setDisableActions(true)"))

        let smokeSourceHost = try readSource("Sources/LocalLanSmokeSourceHost/main.swift")
        XCTAssertTrue(smokeSourceHost.contains("beginActivity("))
        XCTAssertTrue(smokeSourceHost.contains(".userInitiatedAllowingIdleSystemSleep"))
        XCTAssertTrue(smokeSourceHost.contains(".latencyCritical"))
        XCTAssertTrue(smokeSourceHost.contains(".suddenTerminationDisabled"))
        XCTAssertTrue(smokeSourceHost.contains(".automaticTerminationDisabled"))
        XCTAssertTrue(smokeSourceHost.contains("appNapDisabled=1"))
        XCTAssertTrue(smokeSourceHost.contains("applyUserInteractiveMainThreadQoS()"))
        XCTAssertTrue(smokeSourceHost.contains("pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE"))
        XCTAssertTrue(smokeSourceHost.contains("mainThreadQOS=userInteractive"))
        XCTAssertTrue(smokeSourceHost.contains("fileprivate static let targetCaptureFramesPerSecond = 60"))
        XCTAssertTrue(smokeSourceHost.contains("private static func renderFramesPerSecond(for _: NSScreen?) -> Int"))
        XCTAssertTrue(smokeSourceHost.contains("targetCaptureFramesPerSecond"))
        XCTAssertTrue(smokeSourceHost.contains("private static let statusReportIntervalSeconds: TimeInterval = 1"))
        XCTAssertTrue(smokeSourceHost.contains("private static let staleRenderRepairThresholdMilliseconds = 100.0"))
        XCTAssertTrue(smokeSourceHost.contains("process=helper"))
        XCTAssertTrue(smokeSourceHost.contains("DispatchSource.makeTimerSource(queue: .main)"))
        XCTAssertTrue(smokeSourceHost.contains("import MetalKit"))
        XCTAssertTrue(smokeSourceHost.contains("MTLCreateSystemDefaultDevice()"))
        XCTAssertTrue(smokeSourceHost.contains("SmokeCaptureAnimationView: MTKView"))
        XCTAssertTrue(smokeSourceHost.contains("SmokeCaptureMetalRenderer: NSObject, MTKViewDelegate"))
        XCTAssertTrue(smokeSourceHost.contains("setRenderingFrameRate(targetRenderFramesPerSecond)"))
        XCTAssertTrue(smokeSourceHost.contains("preferredFramesPerSecond = framesPerSecond"))
        XCTAssertTrue(smokeSourceHost.contains("targetRenderFPS="))
        XCTAssertTrue(smokeSourceHost.contains("screenMaxFPS="))
        XCTAssertTrue(smokeSourceHost.contains("SmokeCaptureVertex"))
        XCTAssertTrue(smokeSourceHost.contains("makeLibrary(source: Self.shaderSource"))
        XCTAssertTrue(smokeSourceHost.contains("smoke_vertex"))
        XCTAssertTrue(smokeSourceHost.contains("smoke_fragment"))
        XCTAssertTrue(smokeSourceHost.contains("makeDynamicFrameVertices(for: frame)"))
        XCTAssertTrue(smokeSourceHost.contains("encoder.drawPrimitives(type: .triangle"))
        XCTAssertTrue(smokeSourceHost.contains("lastSnapshotFrameCount"))
        XCTAssertTrue(smokeSourceHost.contains("maxFrameGapMilliseconds = 0"))
        XCTAssertTrue(smokeSourceHost.contains("mode=metal-vsync"))
        XCTAssertTrue(smokeSourceHost.contains("sourceCadenceDriver=mtkview-display-link"))
        XCTAssertTrue(smokeSourceHost.contains("statusWriter=background-serial"))
        XCTAssertTrue(smokeSourceHost.contains(".withFractionalSeconds"))
        XCTAssertTrue(smokeSourceHost.contains("visibilityRepair=conditional"))
        XCTAssertTrue(smokeSourceHost.contains("renderGapMaxMs="))
        XCTAssertTrue(smokeSourceHost.contains("reason=metal_unavailable"))
        XCTAssertTrue(smokeSourceHost.contains("reason=metal_renderer_unavailable"))
        XCTAssertTrue(smokeSourceHost.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(smokeSourceHost.contains("private func repairCaptureWindowIfNeeded()"))
        XCTAssertTrue(smokeSourceHost.contains("renderIsStale"))
        XCTAssertTrue(smokeSourceHost.contains("visibilityRepair=1"))
        XCTAssertTrue(smokeSourceHost.contains("window?.orderFrontRegardless()"))
        XCTAssertTrue(smokeSourceHost.contains("application.setActivationPolicy(.regular)"))
        XCTAssertTrue(smokeSourceHost.contains("NSRunningApplication.current.activate(options: [.activateAllWindows])"))
        XCTAssertFalse(smokeSourceHost.contains(".activateIgnoringOtherApps"))
        XCTAssertFalse(smokeSourceHost.contains("private let accentLayer = CALayer()"))
        XCTAssertFalse(smokeSourceHost.contains("CATransaction.setDisableActions(true)"))
        XCTAssertTrue(smokeSourceHost.contains("let window = NSWindow("))
        XCTAssertTrue(smokeSourceHost.contains("styleMask: [.titled, .closable, .miniaturizable]"))
        XCTAssertTrue(smokeSourceHost.contains("window.hidesOnDeactivate = false"))
        XCTAssertTrue(smokeSourceHost.contains("window.level = .floating"))
        XCTAssertTrue(smokeSourceHost.contains("window.collectionBehavior = [.moveToActiveSpace]"))
        XCTAssertTrue(smokeSourceHost.contains("window.displayIfNeeded()"))
        XCTAssertTrue(smokeSourceHost.contains("application.updateWindows()"))
        XCTAssertTrue(smokeSourceHost.contains("NSApplication.shared.run()"))
        XCTAssertTrue(smokeSourceHost.contains("let mainDisplayID = CGMainDisplayID()"))
        XCTAssertTrue(smokeSourceHost.contains("Self.screen(for: mainDisplayID)"))
        XCTAssertTrue(smokeSourceHost.contains("displayID=\\(displayID)"))
        XCTAssertTrue(smokeSourceHost.contains("windowVisible=\\(visible)"))
        XCTAssertTrue(smokeSourceHost.contains("windowOcclusionVisible=\\(occlusionVisible)"))
        XCTAssertTrue(smokeSourceHost.contains("windowLevel=\\(level)"))
        XCTAssertTrue(smokeSourceHost.contains("windowFrame=\\(Int(windowFrame.origin.x))"))
        let heartbeatBody = try sourceSlice(
            from: "private func heartbeat()",
            to: "private func repairCaptureWindowIfNeeded()",
            in: smokeSourceHost
        )
        XCTAssertFalse(heartbeatBody.contains("orderFrontRegardless()"))
        XCTAssertFalse(heartbeatBody.contains("displayIfNeeded()"))
        XCTAssertFalse(heartbeatBody.contains("SmokeStatusFileAppender.append"))
        let statusReporterBody = try sourceSlice(
            from: "private final class SmokeStatusReporter",
            to: "private func writeProtectedData",
            in: smokeSourceHost
        )
        XCTAssertTrue(statusReporterBody.contains("DispatchQueue("))
        XCTAssertTrue(statusReporterBody.contains("label: \"com.skybridge.smoke.status-writer\""))
        XCTAssertTrue(statusReporterBody.contains("qos: .utility"))
        XCTAssertTrue(statusReporterBody.contains("queue.async"))
        XCTAssertTrue(statusReporterBody.contains("appendAndWait"))
        XCTAssertTrue(statusReporterBody.contains("SmokeStatusFileAppender.append"))
        XCTAssertFalse(
            smokeSourceHost.contains("window.level = .screenSaver"),
            "The smoke source must stay in a capture-compatible app window level; screen-saver level can be invisible to display capture."
        )
        XCTAssertTrue(
            smokeSourceHost.contains("MTKView"),
            "The smoke capture source must be backed by a real Metal drawable, not a main-queue layer timer."
        )

        let remoteControlSource = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let remoteControlInitBody = try sourceSlice(
            from: "public init() {",
            to: "private func configureViewingRenderersIfNeeded()",
            in: remoteControlSource
        )
        XCTAssertTrue(remoteControlSource.contains("private func configureViewingRenderersIfNeeded()"))
        XCTAssertTrue(remoteControlSource.contains("configureViewingRenderersIfNeeded()\n\n        if let fmt"))
        XCTAssertFalse(
            remoteControlInitBody.contains("fluidRenderer.frameHandler") ||
            remoteControlInitBody.contains("referenceRenderer.frameHandler"),
            "The smoke host is a remote-control server and must not force viewer Metal/resource renderers during startup."
        )

        let remoteSmokeSource = try readSource("Scripts/run_real_device_p2p_remote_smoke.sh")
        let releaseAcceptanceFinalizer = try readSource("Scripts/finalize_release_acceptance_manifests.py")
        let releaseAcceptanceValidator = try readSource("Scripts/validate_real_device_release_acceptance_artifact.py")
        let processOwnershipShellSource = try readSource("Scripts/real_device_ios_process_ownership.sh")
        let processOwnershipPythonSource = try readSource("Scripts/webrtc_smoke_process_ownership.py")
        XCTAssertTrue(remoteSmokeSource.contains("MAC_APP_BUNDLE=\"$MAC_ONLINE_RUNTIME_DIR/LocalLanInteropHost.app\""))
        XCTAssertTrue(remoteSmokeSource.contains("prepare_macos_smoke_host_app_bundle()"))
        XCTAssertTrue(remoteSmokeSource.contains("start_macos_smoke_host()"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_LAUNCH_MODE=\"${SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE:-packaged}\""))
        XCTAssertTrue(remoteSmokeSource.contains("acceptance_violations+=(\"SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged\")"))
        XCTAssertTrue(remoteSmokeSource.contains("packaged|packaged-lab|direct) ;;"))
        XCTAssertTrue(
            remoteSmokeSource.contains(
                "if [[ \"$MAC_HOST_LAUNCH_MODE\" == \"packaged-lab\" && \"$LAB_RUN\" != \"1\" ]]; then"
            )
        )
        XCTAssertTrue(remoteSmokeSource.contains("mac_host_uses_signed_app_bundle()"))
        XCTAssertTrue(
            remoteSmokeSource.contains(
                "MAC_HOST_PRODUCT_APP_BUNDLE=\"${SKYBRIDGE_SMOKE_MAC_PRODUCT_APP_BUNDLE:-$ROOT_DIR/dist/SkyBridge Compass Pro.app}\""
            )
        )
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_BUNDLE_ID=\"com.skybridge.compass.pro\""))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_PROFILE=\"$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/embedded.provisionprofile\""))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID=\"com.skybridge.compass.pro.widgets\""))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_WIDGET_PROFILE=\"$MAC_HOST_PRODUCT_WIDGET_BUNDLE/Contents/embedded.provisionprofile\""))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS=\"$MAC_HOST_SIGNING_DIR/product-widget-entitlements.plist\""))
        XCTAssertTrue(remoteSmokeSource.contains("verify_macos_smoke_host_product_signing_context()"))
        XCTAssertTrue(remoteSmokeSource.contains("validate_macos_smoke_host_product_entitlements()"))
        XCTAssertTrue(remoteSmokeSource.contains("skybridge_write_signed_entitlements \"$MAC_HOST_PRODUCT_APP_BUNDLE\" \"$MAC_HOST_PRODUCT_ENTITLEMENTS\""))
        XCTAssertTrue(remoteSmokeSource.contains("skybridge_validate_provisionprofile_app_identity"))
        XCTAssertTrue(remoteSmokeSource.contains("skybridge_profile_supports_requested_profile_backed_entitlements"))
        XCTAssertTrue(remoteSmokeSource.contains("skybridge_resolve_profile_bound_codesign_identity_hash"))
        XCTAssertTrue(remoteSmokeSource.contains("\"$product_identity_hash\" != \"$product_widget_identity_hash\""))
        XCTAssertTrue(remoteSmokeSource.contains("remove_macos_online_ipad_debug_signature_before_binary_mutation"))
        XCTAssertTrue(remoteSmokeSource.contains("compare_macos_online_ipad_entitlements_exact"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_macos_online_ipad_debug_product_signature"))
        XCTAssertFalse(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_MAC_ONLINE_SIGN_IDENTITY"))
        XCTAssertFalse(remoteSmokeSource.contains("select_macos_online_ipad_debug_signing_identity"))
        XCTAssertFalse(remoteSmokeSource.contains("macos_online_ipad_debug_entitlements_for"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_ONLINE_APP_REGISTERED=0"))
        XCTAssertTrue(remoteSmokeSource.contains("cleanup_macos_online_ipad_launch_services_registration"))
        XCTAssertTrue(remoteSmokeSource.contains("restore_canonical_macos_launch_services_registration_last"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_launch_services_runtime_paths_absent \"$runtime_app\""))
        XCTAssertTrue(remoteSmokeSource.contains("and has_current_packaged_mac_online"))
        XCTAssertTrue(remoteSmokeSource.contains("\"acceptanceEligible\": False"))
        XCTAssertTrue(remoteSmokeSource.contains("\"diagnosticOnly\": True"))
        XCTAssertTrue(remoteSmokeSource.contains("\"cleanupComplete\": False"))
        XCTAssertTrue(remoteSmokeSource.contains("\"preCleanupCandidate\": pre_cleanup_candidate"))
        XCTAssertTrue(remoteSmokeSource.contains("python3 \"$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py\""))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("FINALIZATION_ORDER = \"private-then-public-v1\""))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("final_payload[\"finalizationOrder\"] = FINALIZATION_ORDER"))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("_verify_final_manifest(private_path, final_content, final_payload)"))
        XCTAssertFalse(releaseAcceptanceFinalizer.contains("original_private"))
        XCTAssertFalse(releaseAcceptanceFinalizer.localizedCaseInsensitiveContains("rollback"))
        XCTAssertTrue(
            remoteSmokeSource.contains(
                "if (( original_status == 0 && cleanup_status == 0 )) \\\n" +
                    "    && [[ \"$MAC_HOST_ONLY\" != \"1\" && \"$ACCEPTANCE_CANDIDATE_READY\" == \"1\" ]]; then"
            )
        )
        XCTAssertTrue(remoteSmokeSource.contains("derive_macos_smoke_host_minimal_entitlements"))
        XCTAssertTrue(remoteSmokeSource.contains("validate_macos_smoke_host_minimal_entitlements"))
        XCTAssertTrue(remoteSmokeSource.contains("required_groups = {expected_application_identifier, expected_shared_group}"))
        XCTAssertTrue(remoteSmokeSource.contains("/usr/bin/xcrun stapler validate \"$MAC_HOST_PRODUCT_APP_BUNDLE\""))
        XCTAssertTrue(remoteSmokeSource.contains("/usr/sbin/spctl --assess --type execute \"$MAC_HOST_PRODUCT_APP_BUNDLE\""))
        XCTAssertTrue(remoteSmokeSource.contains("verify_macos_smoke_host_identity_source_unchanged()"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_PROFILE_SHA256"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_WIDGET_PROFILE_SHA256"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_CDHASH"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_PRODUCT_WIDGET_CDHASH"))
        XCTAssertTrue(remoteSmokeSource.contains("identitySourceStaplerValid"))
        XCTAssertTrue(remoteSmokeSource.contains("identitySourceGatekeeperAccepted"))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("macHostLaunchMode\") != \"packaged"))
        XCTAssertTrue(releaseAcceptanceValidator.contains("macHostLaunchMode\") != \"packaged"))
        XCTAssertTrue(remoteSmokeSource.contains("SMOKE_BUILD_DIR=\"${SKYBRIDGE_P2P_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/real-device-p2p-smoke}\""))
        XCTAssertTrue(remoteSmokeSource.contains("\"$XCODE_SWIFT_BIN\" build --scratch-path \"$SMOKE_BUILD_DIR\" --product LocalLanInteropHost"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_DIRECT_BIN=\"$SMOKE_BUILD_DIR/debug/LocalLanInteropHost\""))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_SOURCE_DIRECT_BIN=\"$SMOKE_BUILD_DIR/debug/LocalLanSmokeSourceHost\""))
        XCTAssertTrue(remoteSmokeSource.contains("\"$XCODE_SWIFT_BIN\" build --scratch-path \"$SMOKE_BUILD_DIR\" --product LocalLanSmokeSourceHost"))
        XCTAssertFalse(remoteSmokeSource.contains("$ROOT_DIR/.build/debug/"))
        XCTAssertTrue(remoteSmokeSource.contains("start_macos_smoke_source_host()"))
        XCTAssertTrue(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_ROLE=mac-smoke-source"))
        XCTAssertTrue(remoteSmokeSource.contains("role=mac-smoke-source"))
        XCTAssertTrue(remoteSmokeSource.contains("fail_if_smoke_source_exited"))
        XCTAssertTrue(remoteSmokeSource.contains("fail_if_smoke_source_stale"))
        XCTAssertTrue(remoteSmokeSource.contains("phase=heartbeat-stale"))
        XCTAssertTrue(remoteSmokeSource.contains("case \"$MAC_HOST_LAUNCH_MODE\" in"))
        XCTAssertTrue(remoteSmokeSource.contains("launch method=signed-lab-app-bundle"))
        XCTAssertTrue(remoteSmokeSource.contains("stapler=skipped spctl=skipped diagnosticOnly=1"))
        XCTAssertTrue(remoteSmokeSource.contains("if [[ \"$LAB_RUN\" != \"1\" ]]"))
        XCTAssertTrue(remoteSmokeSource.contains("\"$MAC_DIRECT_BIN\" >\"$HOST_STDOUT\" 2>&1 &"))
        XCTAssertTrue(remoteSmokeSource.contains("launch method=direct-app-binary pid=$HOST_PID mode=direct binary=swiftpm-build-product"))
        XCTAssertFalse(remoteSmokeSource.contains("fallback=direct-app-binary"))
        XCTAssertTrue(remoteSmokeSource.contains("failed stage=mac-host phase=launch reason=packaged-product-open-failed"))
        XCTAssertTrue(remoteSmokeSource.contains("failed stage=mac-host phase=launch reason=packaged-product-app-pid-not-found"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_mac_control_port_reachable \"$MAC_CONTROL_HOST\" \"$MAC_CONTROL_PORT\""))
        XCTAssertTrue(remoteSmokeSource.contains("mac-control-port reachable=1 host=$host port=$port source=local-self-probe"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_host_pid_owns_listener_port \"$MAC_CONTROL_PORT\" \"control\""))
        XCTAssertFalse(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_TARGET_HOST"))
        XCTAssertFalse(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_TARGET_CONTROL_PORT"))
        XCTAssertFalse(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_TARGET_REMOTE_PORT"))
        XCTAssertTrue(remoteSmokeSource.contains("failed stage=mac-host phase=control-port-probe reason=tcp-unreachable"))
        XCTAssertTrue(remoteSmokeSource.contains("/usr/bin/open"))
        XCTAssertTrue(remoteSmokeSource.contains("register_macos_smoke_host_app_bundle()"))
        XCTAssertFalse(remoteSmokeSource.contains("LocalLanInteropHostSmoke.${RUN_ID}"))
        XCTAssertFalse(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_REMOTE_ANIMATION=1"))
        XCTAssertTrue(remoteSmokeSource.contains("launch method=packaged-product-app-bundle"))
        XCTAssertTrue(remoteSmokeSource.contains("windowOcclusionVisible=1"))
        XCTAssertTrue(remoteSmokeSource.contains("local source_webrtc_framework=\"$SMOKE_BUILD_DIR/debug/WebRTC.framework\""))
        XCTAssertTrue(remoteSmokeSource.contains("local source_core_resource_bundle=\"$SMOKE_BUILD_DIR/debug/SkyBridgeCompassApp_SkyBridgeCore.bundle\""))
        XCTAssertTrue(remoteSmokeSource.contains("local embedded_core_resource_bundle=\"$resources_dir/SkyBridgeCompassApp_SkyBridgeCore.bundle\""))
        XCTAssertTrue(remoteSmokeSource.contains("local embedded_core_resource_root=\"$embedded_core_resource_contents/Resources\""))
        XCTAssertTrue(remoteSmokeSource.contains("! -d \"$source_core_resource_bundle\" || -L \"$source_core_resource_bundle\""))
        XCTAssertTrue(remoteSmokeSource.contains("scratch_debug_dir=\"$(cd \"$SMOKE_BUILD_DIR/debug\" && pwd -P)\""))
        XCTAssertTrue(remoteSmokeSource.contains("\"$scratch_debug_dir\" != \"$scratch_root_dir/\"*"))
        XCTAssertTrue(remoteSmokeSource.contains("source \"$ROOT_DIR/Scripts/skybridge_core_resource_bundle_helpers.sh\""))
        XCTAssertTrue(remoteSmokeSource.contains("if source_resource_layout=\"$(skybridge_copy_normalized_core_resource_bundle"))
        XCTAssertTrue(remoteSmokeSource.contains("source_resource_status=$?"))
        XCTAssertTrue(remoteSmokeSource.contains("exit \"$source_resource_status\""))
        XCTAssertTrue(remoteSmokeSource.contains("swiftpm-flat)"))
        XCTAssertTrue(remoteSmokeSource.contains("swiftpm-macos-contents)"))
        XCTAssertTrue(remoteSmokeSource.contains("SkyBridgeCore resource normalizer returned an unknown layout token."))
        XCTAssertTrue(remoteSmokeSource.contains("validate_remote_control_security_notice_localizations \\\n    \"$source_resource_root\" \\\n    \"source-$source_resource_layout\""))
        XCTAssertTrue(remoteSmokeSource.contains("\"$embedded_core_resource_root\" \\\n    \"pre-sign\""))
        XCTAssertTrue(remoteSmokeSource.contains("resourceBundleLayout=normalized-contents-resources resourceBundleSource=dedicated-swiftpm-scratch resourceBundleSourceLayout=$source_resource_layout resourceBundleSealed=1"))
        XCTAssertTrue(remoteSmokeSource.contains("cp -R \"$source_webrtc_framework\" \"$macos_dir/WebRTC.framework\""))
        XCTAssertTrue(remoteSmokeSource.contains("cp \"$MAC_HOST_PRODUCT_PROFILE\" \"$embedded_profile\""))
        XCTAssertTrue(remoteSmokeSource.contains("-c \"Add :CFBundleIdentifier string $MAC_HOST_PRODUCT_BUNDLE_ID\""))
        XCTAssertTrue(remoteSmokeSource.contains("--sign \"$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH\""))
        XCTAssertTrue(remoteSmokeSource.contains("--entitlements \"$MAC_HOST_HELPER_ENTITLEMENTS\""))
        XCTAssertTrue(remoteSmokeSource.contains("cmp -s \"$MAC_HOST_PRODUCT_PROFILE\" \"$embedded_profile\""))
        XCTAssertTrue(remoteSmokeSource.contains("skybridge_write_signed_entitlements \"$MAC_APP_BUNDLE\" \"$MAC_HOST_SIGNED_ENTITLEMENTS\""))
        XCTAssertFalse(remoteSmokeSource.contains("/usr/bin/codesign --force --deep --sign - \"$MAC_APP_BUNDLE\""))
        XCTAssertTrue(remoteSmokeSource.contains("skybridge_smoke_require_safe_run_id \"$RUN_ID\" \"SKYBRIDGE_SMOKE_P2P_REMOTE_RUN_ID\""))
        XCTAssertTrue(remoteSmokeSource.contains("/bin/mkdir -m 700 \"$MAC_ONLINE_RUNTIME_DIR\""))
        XCTAssertTrue(remoteSmokeSource.contains("unregister_launch_services_app_bundle \"$MAC_APP_BUNDLE\""))
        XCTAssertTrue(remoteSmokeSource.contains("register_launch_services_app_bundle \"$MAC_HOST_PRODUCT_APP_BUNDLE\""))
        XCTAssertTrue(remoteSmokeSource.contains("source \"$ROOT_DIR/Scripts/real_device_ios_process_ownership.sh\""))
        let executableAbsenceBody = try sourceSlice(
            from: "skybridge_mac_require_executable_absent() {",
            to: "skybridge_mac_wait_for_single_exact_process() {",
            in: processOwnershipShellSource
        )
        XCTAssertTrue(executableAbsenceBody.contains("skybridge_mac_exact_executable_pids"))
        XCTAssertTrue(executableAbsenceBody.contains("if [[ -n \"$exact_pids\" ]]; then"))
        XCTAssertTrue(
            executableAbsenceBody.contains(
                "Refusing to launch $label because its exact executable is already running; close it normally before retrying."
            )
        )
        let terminateOwnedBody = try sourceSlice(
            from: "skybridge_mac_terminate_owned_process() {",
            to: "skybridge_ios_process_snapshot() {",
            in: processOwnershipShellSource
        )
        let ownershipRevalidationRange = try XCTUnwrap(
            terminateOwnedBody.range(of: "if skybridge_mac_owned_process_status")
        )
        let ownedSignalRange = try XCTUnwrap(
            terminateOwnedBody.range(of: "if python3 \"$ownership_helper\" mac-signal")
        )
        XCTAssertLessThan(ownershipRevalidationRange.lowerBound, ownedSignalRange.lowerBound)
        XCTAssertTrue(processOwnershipPythonSource.contains("\"processIdentifier\": pid"))
        XCTAssertTrue(processOwnershipPythonSource.contains("\"executablePath\": canonical_expected"))
        XCTAssertTrue(processOwnershipPythonSource.contains("\"startTimeToken\": snapshot.start_time_token"))
        XCTAssertTrue(processOwnershipPythonSource.contains("\"auditToken\": list(snapshot.audit_token)"))

        let transitionSource = try sourceSlice(
            from: "transition_to_mac_online_ipad_client() {",
            to: "run_mac_online_ipad_button_smoke() {",
            in: remoteSmokeSource
        )
        let terminateHostRange = try XCTUnwrap(
            transitionSource.range(of: "skybridge_mac_terminate_owned_process")
        )
        let unregisterHelperRange = try XCTUnwrap(
            transitionSource.range(of: "cleanup_macos_smoke_host_launch_services_registration")
        )
        let restoreCanonicalRange = try XCTUnwrap(
            transitionSource.range(of: "restore_canonical_macos_launch_services_registration_last")
        )
        XCTAssertLessThan(terminateHostRange.lowerBound, unregisterHelperRange.lowerBound)
        XCTAssertLessThan(unregisterHelperRange.lowerBound, restoreCanonicalRange.lowerBound)
        XCTAssertTrue(
            remoteSmokeSource.contains(
                "canonical macOS product sharing the P2P host bundle identity"
            )
        )
        let cleanupSource = try sourceSlice(
            from: "cleanup() {",
            to: "exit_mac_host_only_on_signal() {",
            in: remoteSmokeSource
        )
        let processCleanupRange = try XCTUnwrap(
            cleanupSource.range(of: "skybridge_mac_terminate_owned_process")
        )
        let acceptanceFinalizationRange = try XCTUnwrap(
            cleanupSource.range(of: "finalize_release_acceptance_manifests_after_cleanup")
        )
        XCTAssertLessThan(processCleanupRange.lowerBound, acceptanceFinalizationRange.lowerBound)
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :CFBundlePackageType string APPL'"))
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :NSPrincipalClass string NSApplication'"))
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :NSLocalNetworkUsageDescription string SkyBridge Compass uses the local network"))
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :NSBonjourServices:0 string _skybridge._tcp'"))
        XCTAssertFalse(remoteSmokeSource.contains("-c 'Add :LSUIElement bool true'"))
        XCTAssertFalse(remoteSmokeSource.contains("*.bundle"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_APP_BIN=\"$macos_dir/LocalLanInteropHost\""))
        XCTAssertTrue(remoteSmokeSource.contains("detect_macos_loginwindow_occlusion()"))
        XCTAssertTrue(remoteSmokeSource.contains("CGWindowListCopyWindowInfo"))
        XCTAssertTrue(remoteSmokeSource.contains("reason=screen-locked-loginwindow-occlusion"))
        XCTAssertTrue(remoteSmokeSource.contains("detect_macos_loginwindow_occlusion\nwait_for_file_pattern \"$HOST_STATUS\" 'smoke-capture-source active=1 .*windowOcclusionVisible=1'"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_mac_smoke_capture_source_visible()"))
        XCTAssertTrue(remoteSmokeSource.contains("detect_macos_loginwindow_occlusion\n\n  if ! command -v screencapture"))
        XCTAssertTrue(remoteSmokeSource.contains("minimum_source_samples"))
        XCTAssertFalse(remoteSmokeSource.contains("Mac smoke source aggregate renderFPS below live-source budget"))
        XCTAssertTrue(remoteSmokeSource.contains("source_frame_delta = source_frame_end - source_frame_start"))
        XCTAssertTrue(remoteSmokeSource.contains("macSourceRenderProgressFPS="))
        XCTAssertFalse(remoteSmokeSource.contains("Mac smoke source render gap exceeded live-source budget"))
        XCTAssertTrue(remoteSmokeSource.contains("source_render_gap_budget_exceeded = int"))
        XCTAssertTrue(remoteSmokeSource.contains("macSourceRenderGapBudgetExceeded="))
        XCTAssertTrue(remoteSmokeSource.contains("macSourceLastRenderAgeBudgetExceeded="))
        XCTAssertTrue(remoteSmokeSource.contains("sck_source_frame_age_budget_exceeded = int"))
        XCTAssertTrue(remoteSmokeSource.contains("macSourceFrameAgeBudgetExceeded="))
        XCTAssertTrue(remoteSmokeSource.contains("Mac HEVC SCK repeated stale source frames inside final pass window"))
        XCTAssertTrue(remoteSmokeSource.contains("screencapture -x \"$first\""))
        XCTAssertTrue(remoteSmokeSource.contains("changedRatio"))
        XCTAssertTrue(remoteSmokeSource.contains("smoke-capture-source captureVerified=1"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_mac_smoke_capture_source_visible\nwait_for_file_pattern \"$HOST_PQC_REPORT\""))
    }

    func testPIB1StatusLinesRedactProtocolIdentitySecrets() throws {
        let p2pSource = try [
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService+BootstrapControl.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
        let approvalSource = try readSource("Sources/SkyBridgeCore/Security/PairingTrustApprovalService.swift")
        let combinedSource = [p2pSource, approvalSource].joined(separator: "\n")
        let macWebRTCSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let iOSWebRTCSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        let webRTCSources = [macWebRTCSource, iOSWebRTCSource].joined(separator: "\n")

        XCTAssertTrue(combinedSource.contains("protocolIdentityLogRedaction"))
        XCTAssertTrue(combinedSource.contains("code=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(combinedSource.contains("fingerprint=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertFalse(
            webRTCSources.contains("protocol-identity-pins session="),
            "WebRTC must not emit protocol-identity pin status lines from untrusted pairing payload metadata."
        )
        XCTAssertTrue(
            macWebRTCSource.contains(
                "fingerprints.insert(validatedAuthority.protocolPublicKeyFingerprint)"
            ) && macWebRTCSource.contains(
                "currentPathAdditionalProtocolFingerprintsBySessionId[sessionID] = fingerprints"
            ),
            "macOS compatibility fingerprints must come from the authority validated against the authenticated handshake."
        )
        XCTAssertTrue(
            iOSWebRTCSource.contains("authenticatedRemoteAuthority: establishedHandshake.binding.authority"),
            "iOS must persist only the authority returned by the authenticated handshake binding."
        )
        XCTAssertEqual(
            webRTCSources.components(separatedBy: "fingerprint=\\(Self.protocolIdentityLogRedaction").count - 1,
            2,
            "macOS and iOS WebRTC current-path authority rebind logs must redact protocol identity fingerprints."
        )
        XCTAssertTrue(
            p2pSource.contains("protocolIdentityBindingCode: code"),
            "Responder payloads still need the PIB-1 SAS for approval; only logs/status lines are redacted."
        )
        XCTAssertTrue(
            approvalSource.contains("pendingVerificationCode = normalizedVerificationCode"),
            "The operator-facing pending approval state must keep the SAS even though logs redact it."
        )

        [
            "code=\\(code)",
            "code=\\(verificationCode)",
            "fingerprint=\\(validated.protocolIdentityFingerprint)",
            "fingerprint=\\(binding.protocolIdentityFingerprint)",
            "fingerprint=\\(fingerprint)",
            "fingerprint=\\(normalizedFingerprint)",
            "fp=\\(protocolIdentityFingerprint",
            "fp=\\(normalizedFingerprint",
            "PIB-1 protocol identity binding served: requester=\\(request.requesterDeviceId)",
            "PIB-1 protocol identity binding rejected: requester=\\(request.requesterDeviceId)",
            "PIB-1 protocol identity binding connect-start: peer=\\(targetDeviceId)",
            "PIB-1 protocol identity binding request: peer=\\(targetDeviceId)",
            "PIB-1 protocol identity binding pinned: peer=\\(targetDeviceId)",
            "deviceId=\\(validated.deviceId)",
            "deviceId=\\(declaredDeviceId"
        ].forEach { forbidden in
            XCTAssertFalse(
                combinedSource.contains(forbidden),
                "PIB-1 logs/status lines must not persist raw protocol identity secrets: \(forbidden)"
            )
        }

        [
            "protocol-identity-pins session=\\(sessionID) peer=\\(peerDeviceId) declared=\\(payload.deviceId)",
            "protocol-identity-pins session=\\(sessionId) peer=\\(peerDeviceId) declared=\\(payload.deviceId)",
            "current-path protocol identity pins updated: session=\\(sessionID",
            "current-path protocol identity pins updated: session=\\(sessionId",
            "fingerprint=\\(protocolPublicKeyFingerprint",
            "deviceId=\\(deviceId"
        ].forEach { forbidden in
            XCTAssertFalse(
                webRTCSources.contains(forbidden),
                "WebRTC protocol identity logs/status lines must not persist raw session IDs, device IDs, or protocol fingerprints: \(forbidden)"
            )
        }
    }

    func testCurrentPathTrustBridgeLogsRedactStableIdentifiers() throws {
        let handlerSource = try [
            "Sources/SkyBridgeCore/P2P/P2PModels.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
        let coordinatorSource = try readSource(
            "Sources/SkyBridgeCore/P2P/PairingIdentityExchangeCommitCoordinator.swift"
        )
        let currentPathTrustLogLines = handlerSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                $0.contains("current-path trust bridge")
                    || $0.contains("pairingIdentityExchange protocol identity pins")
            }
            .joined(separator: "\n")

        XCTAssertTrue(
            currentPathTrustLogLines.isEmpty ||
                currentPathTrustLogLines.contains("Self.protocolIdentityLogRedaction"),
            "A trust-commit log must be absent or use only the literal redaction marker."
        )

        [
            "peer=\\(self.handshakePeer.deviceId",
            "peer=\\(peer.deviceId",
            "peer=\\(peerDeviceId",
            "declared=\\(payload.deviceId",
            "current=\\(declaredDeviceId",
            "current=\\(payload.deviceId",
            "fp=\\(authority.protocolPublicKeyFingerprint",
            "error.localizedDescription, privacy: .public"
        ].forEach { forbidden in
            XCTAssertFalse(
                currentPathTrustLogLines.contains(forbidden),
                "Current-path trust bridge logs must not persist raw stable identifiers or public failure text: \(forbidden)"
            )
        }

        XCTAssertTrue(
            coordinatorSource.contains("recordAuthenticatedRemoteAuthorityForPairing("),
            "The shared transaction must remain the only pairing authority persistence boundary."
        )
        XCTAssertTrue(
            coordinatorSource.contains("protocolPublicKeyFingerprint: authority.protocolPublicKeyFingerprint"),
            "Only the authenticated, validated fingerprint may reach TrustSyncService for fail-closed current-path trust."
        )
    }

    func testSKR1StatusLinesRedactProtocolIdentitySecrets() throws {
        let macSource = try [
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService+BootstrapControl.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
        let iOSSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift")
        let combinedSource = [macSource, iOSSource].joined(separator: "\n")
        let skrSource = combinedSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("SKR-1") }
            .joined(separator: "\n")

        XCTAssertTrue(skrSource.contains("SKR-1 signed LAN KEM refresh"))
        XCTAssertTrue(
            skrSource.contains(
                "requester=%@ target=%@ skr_ref=%@ payload_ref=%@ keyId=%@"
            ),
            "Served SKR evidence must keep redacted peer placeholders while exposing only typed correlation references."
        )
        XCTAssertTrue(skrSource.contains("requester=%@ target=%@ reasonCode=%@ reason=%@"))
        XCTAssertGreaterThanOrEqual(
            skrSource.components(separatedBy: "Self.protocolIdentityLogRedaction").count - 1,
            10
        )
        XCTAssertTrue(skrSource.contains("requesterProtocolIdentity=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(skrSource.contains("reason=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(skrSource.contains("endpointCount=\\(endpoints.count)"))

        [
            "requester=\\(request.requesterDeviceId)",
            "target=\\(request.targetDeviceId)",
            "keyId=\\(refresh.keyId)",
            "reason=\\(error.localizedDescription)",
            "reason=\\(failure.reason)",
            "peer=\\(targetDeviceId)",
            "endpoint=\\(exchange.endpoint.debugDescription)",
            "requesterProtocolIdentity=\\(requesterFingerprint)",
            "peer=\\(device.id)",
            "endpoints=\\(endpoints.map",
            "endpoint=\\(selectedEndpoint)",
            "requesterProtocolIdentity=\\(requesterProtocolIdentityFingerprint)",
            "reason=\\(error.localizedDescription)",
            "reason=\\(failure.reason)"
        ].forEach { forbidden in
            XCTAssertFalse(
                skrSource.contains(forbidden),
                "SKR-1 logs/status lines must not persist raw stable identifiers or remote failure text: \(forbidden)"
            )
        }
    }

    func testSignalingLogsAndErrorDescriptionsDoNotExposeServerBodiesOrStableIdentifiers() throws {
        let iOSWebRTCSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        let iOSSignalClientSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift")
        let protocolSignalClientSource = try readSource("Sources/SkyBridgeProtocolCore/RemoteConnection/SignalServerClient.swift")
        let macWebSocketSource = try readSource("Sources/SkyBridgeAppleTransport/RemoteConnection/WebRTC/WebSocketSignalingClient.swift")
        let iOSWebSocketSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebSocketSignalingClient.swift")
        let signalingServerSource = try readSource("Server/skybridge-signaling/server.js")
        let localCompatServerSource = try readSource("Server/skybridge-signaling/local_compat_server.js")
        let supabaseClientSource = try readSource("Sources/SkyBridgeCore/Services/SupabaseClient.swift")

        let initialHandshakeLogSlice = try sourceSlice(
            from: "guard shouldInitiate else",
            to: "let establishedHandshake: (",
            in: iOSWebRTCSource
        )
        XCTAssertTrue(initialHandshakeLogSlice.contains("session=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(initialHandshakeLogSlice.contains("peer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertTrue(initialHandshakeLogSlice.contains("trustPeer=\\(Self.protocolIdentityLogRedaction)"))
        XCTAssertFalse(initialHandshakeLogSlice.contains("session=\\(sessionId)"))
        XCTAssertFalse(initialHandshakeLogSlice.contains("peer=\\(peerDeviceId)"))
        XCTAssertFalse(initialHandshakeLogSlice.contains("trustPeer=\\(trustLookupPeerId)"))

        XCTAssertTrue(iOSSignalClientSource.contains("redactedServerRejectedBodyDescription"))
        XCTAssertTrue(iOSSignalClientSource.contains("redactedServerRejectedBodyLogSummary(byteCount: data.count)"))
        XCTAssertTrue(iOSSignalClientSource.contains("sanitizedServerRejectedBodyDescription(from: data)"))
        XCTAssertTrue(iOSSignalClientSource.contains("deviceId=\\(Self.sensitiveLogRedaction"))
        XCTAssertTrue(iOSSignalClientSource.contains("deviceName=\\(Self.sensitiveLogRedaction"))
        XCTAssertTrue(iOSSignalClientSource.contains("sessionId=\\(Self.sensitiveLogRedaction"))
        XCTAssertTrue(iOSSignalClientSource.contains("sessionTokenGeneration=\\(Self.logPresence(response.sessionTokenGeneration)"))
        XCTAssertTrue(iOSSignalClientSource.contains("mediaTokenGeneration=\\(Self.logPresence(response.mediaTokenGeneration)"))
        XCTAssertTrue(iOSSignalClientSource.contains("challengeId=\\(Self.sensitiveLogRedaction"))
        XCTAssertTrue(iOSSignalClientSource.contains("body=\\(bodySummary, privacy: .public)"))
        XCTAssertTrue(iOSSignalClientSource.contains("err=\\(error.localizedDescription, privacy: .private)"))
        XCTAssertFalse(iOSSignalClientSource.contains("body=\\(bodyString, privacy: .public)"))
        XCTAssertFalse(iOSSignalClientSource.contains("throw ClientError.serverRejected(http.statusCode, bodyString)"))
        XCTAssertFalse(iOSSignalClientSource.contains("current-path request start path=/api/webrtc/admission/challenge deviceId=\\(binding.deviceId"))
        XCTAssertFalse(iOSSignalClientSource.contains("current-path request start path=/api/webrtc/admission deviceId=\\(binding.deviceId"))
        XCTAssertFalse(iOSSignalClientSource.contains("challengeId=\\(response.challengeId"))
        XCTAssertFalse(iOSSignalClientSource.contains("sessionId=\\(sessionId, privacy: .public)"))
        XCTAssertFalse(iOSSignalClientSource.contains("sessionId=\\(response.sessionId, privacy: .public)"))
        XCTAssertFalse(iOSSignalClientSource.contains("sessionTokenGeneration=\\(response.sessionTokenGeneration"))
        XCTAssertFalse(iOSSignalClientSource.contains("mediaTokenGeneration=\\(response.mediaTokenGeneration"))
        XCTAssertFalse(iOSSignalClientSource.contains("deviceName=\\(deviceName, privacy: .public)"))

        XCTAssertTrue(protocolSignalClientSource.contains("redactedServerRejectedBodyDescription"))
        XCTAssertTrue(protocolSignalClientSource.contains("sanitizedServerRejectedBodyDescription(from: data)"))
        XCTAssertFalse(protocolSignalClientSource.contains("throw ClientError.serverRejected(httpResponse.statusCode, bodyText)"))
        XCTAssertFalse(protocolSignalClientSource.contains("return \"信令服务器拒绝请求 (\\(status)): \\(body)\""))
        XCTAssertFalse(iOSSignalClientSource.contains("return \"信令服务器拒绝请求 (\\(status)): \\(body)\""))

        for source in [macWebSocketSource, iOSWebSocketSource] {
            XCTAssertTrue(source.contains("redactedServerErrorReasonDescription"))
            XCTAssertTrue(source.contains("sensitiveLogRedaction"))
            XCTAssertTrue(source.contains("name == \"shard\""))
            XCTAssertTrue(source.contains("name.contains(\"token\")"))
            XCTAssertTrue(source.contains("session=\\(Self.sensitiveLogRedaction"))
            XCTAssertTrue(source.contains("transportErrorLogSummary"))
            XCTAssertTrue(source.contains("let redactedReason = Self.redactedServerErrorReasonDescription"))
            XCTAssertTrue(source.contains("errorDescription: redactedReason"))
            XCTAssertTrue(source.contains("logger.error(\"❌ signaling server error: \\(redactedReason"))
            XCTAssertTrue(source.contains("case .unknown:"))
            XCTAssertTrue(source.contains("await failProtocolViolation(handleId: handleId, reasonCode: \"malformed_message\")"))
            XCTAssertTrue(source.contains("logger.error(\"signaling protocol violation code=\\(reasonCode, privacy: .public)\")"))
            XCTAssertFalse(source.contains("logger.error(\"❌ signaling server error: \\(reason, privacy: .public)"))
            XCTAssertFalse(source.contains("ignoring non-envelope message: \\(text.prefix(200), privacy: .public)"))
            XCTAssertFalse(source.contains("session=\\(self.sessionId, privacy: .public)"))
            XCTAssertFalse(source.contains("session=\\(handleId.sessionId, privacy: .public)"))
            XCTAssertFalse(source.contains("err=\\(error.localizedDescription, privacy: .public)"))
        }

        XCTAssertFalse(iOSWebSocketSource.contains("session=\\(envelope.sessionId)"))
        XCTAssertFalse(iOSWebSocketSource.contains("from=\\(envelope.from)"))
        XCTAssertFalse(iOSWebSocketSource.contains("to=\\(envelope.to"))
        XCTAssertFalse(iOSWebSocketSource.contains("session=\\(env.sessionId)"))
        XCTAssertFalse(iOSWebSocketSource.contains("from=\\(env.from)"))
        XCTAssertFalse(iOSWebSocketSource.contains("to=\\(env.to"))
        XCTAssertFalse(iOSWebSocketSource.contains("error=\\(frame.error"))

        XCTAssertTrue(localCompatServerSource.contains("sessionLogId=${sessionLogId(record)}"))
        XCTAssertTrue(localCompatServerSource.contains("token=${tokenPresence(sessionToken)}"))
        XCTAssertFalse(localCompatServerSource.contains("console.log(`[http] register-code code=${code} initiator=${binding.deviceId}`)"))
        XCTAssertFalse(localCompatServerSource.contains("console.log(`[http] lookup denied code=${sessionId}"))
        XCTAssertFalse(localCompatServerSource.contains("console.log(`[http] lookup code=${sessionId} responder=${binding.deviceId}`)"))
        XCTAssertFalse(localCompatServerSource.contains("console.log(`[ws] reject session=${sessionId}"))
        XCTAssertFalse(localCompatServerSource.contains("console.log(`[ws] bound session=${sessionId}"))
        XCTAssertFalse(localCompatServerSource.contains("console.log(`[ws] relay session=${sessionId}"))
        XCTAssertFalse(localCompatServerSource.contains("token=${sessionToken.slice"))
        XCTAssertFalse(localCompatServerSource.contains("catch (_) {}"))

        XCTAssertTrue(signalingServerSource.contains("redactedWSMetaForLog(meta)"))
        XCTAssertTrue(signalingServerSource.contains("safeLogErrorCode(error)"))
        XCTAssertFalse(signalingServerSource.contains("sessionId: meta?.sessionId || null"))
        XCTAssertFalse(signalingServerSource.contains("deviceId: meta?.deviceId || null"))
        XCTAssertFalse(signalingServerSource.contains("message: error?.message || String(error)"))
        XCTAssertFalse(signalingServerSource.contains("stack: error?.stack || null"))

        XCTAssertTrue(supabaseClientSource.contains("redactedPathForLog"))
        XCTAssertTrue(supabaseClientSource.contains("queryItems=\\(query.count"))
        XCTAssertTrue(supabaseClientSource.contains("bodyBytes=\\(body?.utf8.count ?? 0)"))
        XCTAssertFalse(supabaseClientSource.contains("url.absoluteString"))
        XCTAssertFalse(supabaseClientSource.contains("HTTP状态异常: \\(code) \\(body ?? \"\")"))
    }

    func testServerRejectedBodySummaryPreservesSafeClassifiersOnly() throws {
        let iOSSignalClientSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CrossNetworkSignalServerClient.swift")
        let body = Data(
            #"""
            {
              "error": "session_inactive",
              "rejectReason": "remote_kill",
              "mediaTokenRequestGeneration": "aaaa1111bbbb2222",
              "mediaTokenExpectedGeneration": "bbbb2222cccc3333",
              "mediaTokenGeneration": "secret-token",
              "mediaTokenExpectedPresent": false,
              "mediaTokenSessionPresent": false,
              "message": "token secret should not leave the HTTP boundary",
              "email": "operator@example.com",
              "sessionToken": "session-token-secret"
            }
            """#.utf8
        )

        let summary = SignalServerClient.sanitizedServerRejectedBodyDescription(from: body)

        XCTAssertTrue(summary.contains("\"error\":\"session_inactive\""))
        XCTAssertTrue(summary.contains("\"rejectReason\":\"remote_kill\""))
        XCTAssertTrue(summary.contains("\"mediaTokenRequestGeneration\":\"aaaa1111bbbb2222\""))
        XCTAssertTrue(summary.contains("\"mediaTokenExpectedGeneration\":\"bbbb2222cccc3333\""))
        XCTAssertTrue(summary.contains("\"mediaTokenExpectedPresent\":false"))
        XCTAssertTrue(summary.contains("\"mediaTokenSessionPresent\":false"))
        XCTAssertTrue(summary.contains("\"bodyBytes\":"))
        XCTAssertFalse(summary.contains("token secret"))
        XCTAssertFalse(summary.contains("secret-token"))
        XCTAssertFalse(summary.contains("operator@example.com"))
        XCTAssertFalse(summary.contains("session-token-secret"))
        XCTAssertFalse(summary.contains("\"mediaTokenGeneration\""))
        XCTAssertFalse(summary.contains("\"message\""))
        XCTAssertFalse(summary.contains("\"email\""))
        XCTAssertFalse(summary.contains("\"sessionToken\""))

        XCTAssertTrue(iOSSignalClientSource.contains("\"mediaTokenRequestGeneration\""))
        XCTAssertTrue(iOSSignalClientSource.contains("\"mediaTokenExpectedGeneration\""))
        XCTAssertTrue(iOSSignalClientSource.contains("\"mediaTokenGeneration\""))

        let plainTextSummary = SignalServerClient.sanitizedServerRejectedBodyDescription(
            from: Data("plain server error with secret-token".utf8)
        )
        XCTAssertTrue(plainTextSummary.hasPrefix(SignalServerClient.redactedServerRejectedBodyDescription))
        XCTAssertTrue(plainTextSummary.contains("bytes="))
        XCTAssertFalse(plainTextSummary.contains("secret-token"))
    }

    func testBonjourDiscoveryDoesNotImportKEMPublicKeysFromTXT() throws {
        let discoverySource = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let identitySlice = try sourceSlice(
            from: "private struct ValidatedBonjourAdvertisement",
            to: "private func extractDeviceInfo(from fields:",
            in: discoverySource
        )
        XCTAssertFalse(identitySlice.localizedCaseInsensitiveContains("kem"))
        XCTAssertFalse(identitySlice.contains("KEMTrustStore"))
        XCTAssertFalse(identitySlice.contains("PeerKEMBootstrapStore"))

        let contractSource = try readSource(
            "Sources/SkyBridgeProtocolCore/Discovery/BonjourInteropProtocolContract.swift"
        )
        let projectionSlice = try sourceSlice(
            from: "public struct DiscoveryProjection:",
            to: "/// Apple recommends keeping Bonjour TXT payloads",
            in: contractSource
        )
        XCTAssertFalse(projectionSlice.localizedCaseInsensitiveContains("kem"))
        XCTAssertFalse(projectionSlice.contains("capabilities"))
        XCTAssertFalse(projectionSlice.contains("port"))
        XCTAssertTrue(projectionSlice.contains("protocolPublicKeyFingerprint"))
        XCTAssertFalse(discoverySource.contains("txtRecord[\"kemPublicKey\"]"))
        XCTAssertFalse(discoverySource.contains("txtRecord[\"kemPublicKeys\"]"))
    }

    func testP2PDiscoverySettingsRebuildRuntimeBrowserSet() throws {
        let discoverySource = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let settingsSource = try readSource("Sources/SkyBridgeCore/Settings/SettingsManager.swift")

        XCTAssertTrue(discoverySource.contains("browserLifecycleState.configuredServiceTypes"))
        XCTAssertTrue(discoverySource.contains("public func applyDiscoverySettings("))
        XCTAssertTrue(discoverySource.contains("replaceBrowserGeneration(serviceTypes: desired)"))
        XCTAssertTrue(discoverySource.contains("browserLifecycleState.beginScanning(serviceTypes: serviceTypes)"))
        XCTAssertTrue(settingsSource.contains(".combineLatest($enableCompanionLink)"))
        XCTAssertTrue(settingsSource.contains("P2PDiscoveryService.shared.applyDiscoverySettings"))
    }

    func testStrictBootstrapOnlyAcceptsOnlyBootstrapSecurityAndLivenessBeforeRekey() {
        let kemKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwingMLDSA.wireId,
            publicKey: Data(repeating: 0x42, count: 1_216)
        )
        let pairing = AppMessage.PairingIdentityExchangePayload(
            deviceId: "device-a",
            kemPublicKeys: [kemKey]
        )
        let kemRefreshRequest = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "device-a",
            targetDeviceId: "device-b",
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: Data(repeating: 0x01, count: 16)
        )
        let signedKEMRefresh = AppMessage.SignedKEMRefreshPayload(
            deviceId: "device-a",
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: Data([0x02]),
            protocolIdentityFingerprint: "fingerprint-a",
            kemPublicKeys: [kemKey],
            keyId: "key-a",
            generation: 1,
            expiresAt: Date(timeIntervalSince1970: 2_000),
            requestNonce: Data(repeating: 0x03, count: 16),
            signature: Data([0x04])
        )
        let kemRefreshFailure = AppMessage.KEMRefreshFailurePayload(
            requesterDeviceId: "device-a",
            targetDeviceId: "device-b",
            stage: "test",
            reasonCode: "test_reason",
            reason: "test"
        )
        let bindingRequest = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: "device-a",
            targetDeviceId: "device-b",
            requestedProtocolSigningAlgorithms: [ProtocolSigningAlgorithm.ed25519.rawValue],
            nonce: Data(repeating: 0x05, count: 16)
        )
        let signedBinding = AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: bindingRequest.transactionId,
            deviceId: "device-a",
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: Data([0x06]),
            protocolIdentityFingerprint: "fingerprint-b",
            expiresAt: Date(timeIntervalSince1970: 2_000),
            requestNonce: Data(repeating: 0x07, count: 16),
            signature: Data([0x08])
        )

        let bootstrapSecurityMessages: [AppMessage] = [
            .pairingIdentityExchange(pairing),
            .kemRefreshRequest(kemRefreshRequest),
            .signedKEMRefresh(signedKEMRefresh),
            .kemRefreshFailure(kemRefreshFailure),
            .protocolIdentityBindingRequest(bindingRequest),
            .signedProtocolIdentityBinding(signedBinding)
        ]
        for message in bootstrapSecurityMessages {
            XCTAssertEqual(
                WebRTCBootstrapAppMessagePolicy.admission(for: message),
                .continueBootstrapSecurityFlow
            )
        }

        let livenessMessages: [AppMessage] = [
            .heartbeat(.init(deviceId: "device-a")),
            .ping(.init(id: 1)),
            .pong(.init(id: 1)),
            .peerDisconnecting(.init(deviceId: "device-a"))
        ]
        for message in livenessMessages {
            XCTAssertEqual(
                WebRTCBootstrapAppMessagePolicy.admission(for: message),
                .consumeLivenessLocally
            )
        }

        XCTAssertEqual(
            WebRTCBootstrapAppMessagePolicy.admission(
                for: .clipboard(.init(mimeType: "text/plain", dataBase64: "dGVzdA=="))
            ),
            .dropUntilPQCRekey,
            "Business payloads must not start the media/control path before PQC rekey."
        )
        XCTAssertEqual(
            WebRTCBootstrapAppMessagePolicy.admission(for: .authenticatedRouteBinding(routeBindingPayload())),
            .dropUntilPQCRekey,
            "Route binding is product-control authorization material and must not run before PQC rekey."
        )
    }

    func testAuthenticatedRouteBindingAppMessageRoundTripsAsExternallyTaggedControlPayload() throws {
        let payload = routeBindingPayload()
        let encoded = try JSONEncoder().encode(AppMessage.authenticatedRouteBinding(payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let routeBinding = try XCTUnwrap(object["authenticatedRouteBinding"] as? [String: Any])

        XCTAssertEqual(routeBinding["version"] as? Int, 1)
        XCTAssertEqual(routeBinding["kind"] as? String, "fileTransfer")
        XCTAssertEqual(
            routeBinding["serviceType"] as? String,
            BonjourInteropContract.fileTransferServiceType
        )
        XCTAssertEqual(routeBinding["endpointProvenance"] as? String, "resolved-dns-sd-endpoint")
        XCTAssertEqual(routeBinding["routeAuthorityProtocolPublicKeyFingerprint"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(routeBinding["sessionHashHex"] as? String, "0123456789abcdef")
        XCTAssertEqual(routeBinding["transcriptPrefixHex"] as? String, "fedcba9876543210")

        let decoded = try JSONDecoder().decode(AppMessage.self, from: encoded)
        XCTAssertEqual(decoded, .authenticatedRouteBinding(payload))
        XCTAssertEqual(WebRTCControlChannelCodec.bootstrapAppMessageKind(decoded), "authenticatedRouteBinding")
    }

    func testWebRTCSendsAuthenticatedRouteBindingAfterEstablishedBusinessSession() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        XCTAssertTrue(source.contains("func sendLocalAuthenticatedRouteBindings("))
        XCTAssertTrue(source.contains("currentPathExpectedRemoteAuthorityBySessionId[sessionID]"))
        XCTAssertTrue(source.contains("ServiceEndpointRegistry.shared.snapshot()"))
        XCTAssertTrue(source.contains("WebRTCControlChannelCodec.sessionBindingDescriptor(for: keys)"))
        XCTAssertTrue(source.contains("localIdentity.identity.authoritativeFingerprint"))
        XCTAssertFalse(
            source.contains(".pubKeyFP"),
            "Authenticated route bindings must use the committed protocol identity, not the P-256 device-authority fingerprint."
        )
        XCTAssertTrue(source.contains("await sendLocalAuthenticatedRouteBindings(keys: keys, stage: \"initial-handshake\")"))
        XCTAssertTrue(source.contains("await sendLocalAuthenticatedRouteBindings(keys: rekeyed, stage: \"outbound-rekey\")"))
        XCTAssertTrue(source.contains("await sendLocalAuthenticatedRouteBindings(keys: keys, stage: \"inbound-rekey\")"))
        XCTAssertTrue(source.contains("strictPQCClassicBootstrapOnlySessionIds.contains(sessionID)"))
        XCTAssertTrue(source.contains("webrtcRekeyInProgressSessionIds.contains(sessionID)"))
    }

    func testActiveWebRTCRekeyFramesBypassBusinessDecryptAndRouteToDriver() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let receiveLoopPrefix = try sourceSlice(
            from: "let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: \"rx/webrtc\")",
            to: "if handshakeState.driver == nil {",
            in: source
        )
        let driverGate = try sourceSlice(
            from: "guard let activeDriver = handshakeState.driver else { continue }",
            to: "await activeDriver.handleMessage(frame, from: peer)",
            in: source
        )

        XCTAssertTrue(source.contains("func isActiveHandshakeDriverFrame(_ data: Data) -> Bool"))
        XCTAssertFalse(
            source.contains("frame.count >= 5, frame.first == HandshakeConstants.protocolVersion { return true }"),
            "Active rekey routing must not classify random AES-GCM business frames as handshake frames from a first-byte match alone."
        )
        XCTAssertTrue(
            receiveLoopPrefix.contains("!(handshakeState.driver != nil && isActiveHandshakeDriverFrame(frame))"),
            "Active PQC rekey MessageB/Finished frames must not be attempted as business AES-GCM payloads first."
        )
        XCTAssertTrue(
            driverGate.contains("guard isActiveHandshakeDriverFrame(frame) else"),
            "The active rekey driver should be the final validator for handshake-like control frames."
        )
    }

    func testIOSActiveWebRTCRekeyFramesBypassBusinessDecryptAndRouteToDriver() throws {
        let source = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let receiveLoopPrefix = try sourceSlice(
            from: "let handshakeFrame = HandshakePadding.unwrapIfNeeded(",
            to: "if let keys = await sessionKeysIfCurrent(",
            in: source
        )
        let activeDriverBranch = try sourceSlice(
            from: "if let driver = handshakeDriver {",
            to: "if let messageB = try? HandshakeMessageB.decode(from: frame)",
            in: source
        )

        XCTAssertTrue(source.contains("func isActiveHandshakeDriverFrame(_ data: Data) -> Bool"))
        XCTAssertFalse(
            source.contains("frame.count >= 5, frame.first == HandshakeConstants.protocolVersion { return true }"),
            "iOS active rekey routing must not classify random AES-GCM business frames as handshake frames from a first-byte match alone."
        )
        XCTAssertTrue(
            receiveLoopPrefix.contains("isLikelyCompleteHandshakeControlPacket(handshakeFrame)")
        )
        XCTAssertTrue(
            receiveLoopPrefix.contains("hasActiveDriver && isActiveHandshakeDriverFrame(handshakeFrame)"),
            "Inbound PQC rekey frames on iOS must reach the handshake driver before business AES-GCM decoding."
        )
        XCTAssertTrue(
            activeDriverBranch.contains("guard isActiveHandshakeDriverFrame(frame) else"),
            "The iOS active rekey driver must not consume arbitrary post-bootstrap business frames."
        )
    }

    func testRelayOnlySmokeKeepsContinualICEGathering() throws {
        let macSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift")
        let iosSource = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"
        )

        for source in [macSource, iosSource] {
            XCTAssertTrue(source.contains("config.continualGatheringPolicy = .gatherContinually"))
            XCTAssertTrue(source.contains("config.iceTransportPolicy = .relay"))
            XCTAssertFalse(
                source.contains("config.continualGatheringPolicy = .gatherOnce"),
                "Relay-only TURN sessions still need continual gathering on mobile/cellular paths."
            )
        }
    }

    func testPairingTrustApprovalCoalescesDuplicatePromptAndPersistsAlwaysAllowByDeviceId() throws {
        let source = try readSource("Sources/SkyBridgeCore/Security/PairingTrustApprovalService.swift")

        XCTAssertTrue(source.contains("isSameTrustRequest(pendingRequest, request)"))
        XCTAssertTrue(source.contains("Pairing request coalesced with pending prompt"))
        XCTAssertTrue(source.contains("return await waitForDecision(requestId: pendingRequest.id)"))
        XCTAssertTrue(source.contains("waitersByRequestId[requestId, default: [:]][waiterId] = DecisionWaiter("))
        XCTAssertTrue(source.contains("case .alwaysAllow, .reject:"))
        XCTAssertTrue(source.contains("updatedPolicy[deviceId] = decision.rawValue"))
        XCTAssertTrue(source.contains("guard await savePolicySnapshot(updatedPolicy) else { return .reject }"))
        XCTAssertTrue(source.contains("policyByDeviceId = updatedPolicy"))
    }

    func testWebRTCPairingTrustUsesCurrentPathAuthorityBindingKey() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        XCTAssertTrue(source.contains("let policyBindingKey = PairingTrustApprovalService.policyBindingKey("))
        XCTAssertTrue(source.contains("declaredDeviceId: validatedAuthority.declaredDeviceId"))
        XCTAssertTrue(source.contains("algorithmRawValue: validatedAuthority.protocolSigningAlgorithm.rawValue"))
        XCTAssertTrue(source.contains("validatedAuthority.protocolPublicKeyFingerprint"))
        XCTAssertFalse(source.contains("let policyBindingKey = self.currentPathExpectedRemoteAuthorityBySessionId[sessionID].flatMap"))
        XCTAssertTrue(source.contains("PairingTrustApprovalService.policyBindingKey"))
        XCTAssertTrue(source.contains("policyBindingKey: policyBindingKey"))
        XCTAssertTrue(source.contains("PairingTrustApprovalService.shared.updateVerificationCode"))
    }

    func testStrictWebRTCInitialHandshakeRequiresPinnedCurrentPathAuthorityBeforeTrustedKEM() throws {
        let source = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        let guardBody = try sourceSlice(
            from: "if peerIdCandidates.isEmpty {",
            to: "var trustedPeerKEMKeys: [CryptoSuite: Data] = [:]",
            in: source
        )

        XCTAssertTrue(guardBody.contains("if strictPQCRequested,"))
        XCTAssertTrue(guardBody.contains("currentPathExpectedRemoteAuthorityBySessionId[sessionId] == nil"))
        XCTAssertTrue(guardBody.contains("requires pinned current-path protocol identity"))
        XCTAssertTrue(guardBody.contains("throw NSError("))
    }

    func testMacCurrentPathWebRTCKEMTrustUsesSignedRefreshBoundToProtocolPins() throws {
        let managerSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let trustProviderSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/CurrentPathHandshakeTrustProvider.swift")

        XCTAssertTrue(managerSource.contains("private func trustedSignedRefreshKEMPublicKeys("))
        XCTAssertTrue(managerSource.contains("currentPathTrustedProtocolFingerprints(for: sessionID)"))
        XCTAssertTrue(trustProviderSource.contains("signedRefreshKEMPublicKeys("))
        XCTAssertFalse(trustProviderSource.contains("mergedKEMPublicKeys("))

        let initialBootstrapKEMLookup = try sourceSlice(
            from: "var trustedPeerKEMKeys: [UInt16: Data] = [:]",
            to: "if !WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(",
            in: managerSource
        )
        XCTAssertTrue(initialBootstrapKEMLookup.contains("trustedSignedRefreshKEMPublicKeys("))
        XCTAssertFalse(initialBootstrapKEMLookup.contains("mergedKEMPublicKeys("))

        let rekeyKEMLookup = try sourceSlice(
            from: "var peerKEMByCandidateId: [String: [UInt16: Data]] = [:]",
            to: "let peerHasXWing = peerKEMByCandidateId.values.contains",
            in: managerSource
        )
        XCTAssertTrue(rekeyKEMLookup.contains("trustedSignedRefreshKEMPublicKeys("))
        XCTAssertFalse(rekeyKEMLookup.contains("mergedKEMPublicKeys("))
    }

    func testIOSCurrentPathWebRTCKEMTrustUsesSignedRefreshBoundToProtocolPins() throws {
        let managerSource = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        let trustProviderSource = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/CurrentPathHandshakeTrustCompat.swift"
        )

        XCTAssertTrue(managerSource.contains("private func trustedCurrentPathKEMPublicKeys("))
        XCTAssertTrue(managerSource.contains("currentPathTrustedProtocolFingerprints(for: sessionId)"))
        XCTAssertTrue(trustProviderSource.contains("signedRefreshKEMPublicKeys("))
        XCTAssertFalse(trustProviderSource.contains("kemPublicKeys(for: deviceId)"))

        let initialBootstrapKEMLookup = try sourceSlice(
            from: "var trustedPeerKEMKeys: [CryptoSuite: Data] = [:]",
            to: "let hasTrustedPeerKEMKey = !trustedPeerKEMKeys.isEmpty",
            in: managerSource
        )
        XCTAssertTrue(initialBootstrapKEMLookup.contains("currentPathExpectedRemoteAuthorityBySessionId[sessionId] != nil"))
        XCTAssertTrue(initialBootstrapKEMLookup.contains("trustedCurrentPathKEMPublicKeys("))
    }

    func testLegacyBootstrapKEMCacheIsKnownMaterialNotTrustAuthority() throws {
        let source = try readSource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let bootstrapStoreSource = try readSource("Sources/SkyBridgeCore/P2P/PeerKEMBootstrapStore.swift")
        let coordinatorSource = try readSource(
            "Sources/SkyBridgeCore/P2P/PairingIdentityExchangeCommitCoordinator.swift"
        )

        XCTAssertTrue(source.contains("currentKnownPeerKEMPublicKeysByCanonicalWireId"))
        XCTAssertTrue(source.contains("return \"bootstrapCache\""))
        XCTAssertTrue(source.contains("hasTrust: diagnostic.hasTrust"))
        XCTAssertTrue(coordinatorSource.contains("upsertAuthorityBoundPairingKEM("))
        XCTAssertTrue(coordinatorSource.contains("rollbackAuthorityBoundPairingKEMMutation(kemReceipt)"))
        XCTAssertTrue(coordinatorSource.contains("recordAuthenticatedRemoteAuthorityForPairing("))
        XCTAssertFalse(source.contains("using bootstrap cache only"))
        XCTAssertFalse(source.contains("TrustSync degraded"))
        XCTAssertFalse(source.contains("currentTrustedPeerKEMPublicKeysByCanonicalWireId"))
        XCTAssertFalse(source.contains("hasTrust: diagnostic.hasTrust || !cachedSuites.isEmpty"))
        XCTAssertTrue(bootstrapStoreSource.contains("entry.source == \"signed_lan_kem_refresh\""))
        XCTAssertFalse(bootstrapStoreSource.contains("clearPairingIdentityExchangeEntries("))
    }

    func testSignedAppSmokeHasAppLevelPairingApprovalSurface() throws {
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let scriptSource = try readSource("Scripts/run_real_device_file_transfer_smoke.sh")
        let releaseReadiness = try readSource("Scripts/check_macos_release_readiness.sh")

        let mainWindowPrefix = try sourceSlice(
            from: "Window(localizationManager.localizedString(\"app.name\"), id: \"main\")",
            to: ".task {",
            in: appSource
        )
        let rootContainerSource = try sourceSlice(
            from: "private struct RootContainerView: View",
            to: "private struct SupabasePasswordResetSheet: View",
            in: appSource
        )

        XCTAssertTrue(
            mainWindowPrefix.contains("PairingTrustApprovalSheet"),
            "PIB-1/SKR-1 approval must be app-level so signed-app smoke, startup, and unauthenticated states can present it."
        )
        XCTAssertFalse(
            rootContainerSource.contains("PairingTrustApprovalSheet"),
            "Approval must not be trapped behind Dashboard/RootContainer startup state."
        )
        XCTAssertTrue(
            scriptSource.contains("foregrounding signed app so PIB-1 requester approval is visible"),
            "User-realistic signed-app smoke must launch foreground when operator approval is required."
        )
        XCTAssertTrue(
            scriptSource.contains("OPEN_ARGS=(--stdout \"$HOST_STDOUT\" --stderr \"$HOST_STDERR\")")
        )
        XCTAssertFalse(scriptSource.contains("OPEN_ARGS=(-n"))
        XCTAssertTrue(
            releaseReadiness.contains("--package-integrity-only"),
            "Release readiness should expose a narrow package-integrity verifier for smoke preflight without weakening the full release gate."
        )
        XCTAssertTrue(
            releaseReadiness.contains("Package integrity-only validation complete"),
            "The package-integrity mode must exit only after package signing, stapling, and Gatekeeper checks."
        )
        XCTAssertTrue(
            scriptSource.contains("--package-integrity-only"),
            "User-realistic file-transfer smoke should preflight the signed release package without requiring unrelated artifacts before the smoke produces them."
        )
    }

    func testMacOnlineSmokeBootMarkerRunsBeforeHeavyAppStateObjects() throws {
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")

        guard let bootMarker = appSource.range(of: "private let macOnlineSmokeBootMarker"),
              let firstStateObject = appSource.range(of: "@StateObject private var appModel") else {
            XCTFail("Expected mac-online boot marker and first StateObject in SkyBridgeCompassApp.")
            return
        }

        XCTAssertLessThan(
            bootMarker.lowerBound,
            firstStateObject.lowerBound,
            "The packaged LaunchServices smoke marker must run before heavy SwiftUI/App model initialization can block evidence emission."
        )
        XCTAssertTrue(appSource.contains("MacOnlineIPadSmokeBootMarker.appendIfNeeded(uiRole: \"app-init-pre-state\")"))
        XCTAssertTrue(
            appSource.contains("MacOnlineIPadSmokeHarness.isEnabledForCurrentEnvironment || startupCoordinator.isLaunchSettled"),
            "The mac-online packaged-app smoke must render the device-management root before the normal startup gate can block OnlineDeviceCard evidence."
        )
        XCTAssertTrue(appSource.contains("SKYBRIDGE_SMOKE_ROLE"))
        XCTAssertTrue(appSource.contains("SKYBRIDGE_SMOKE_STATUS_FILE"))
        let bootMarkerBody = try sourceSlice(
            from: "private enum MacOnlineIPadSmokeBootMarker",
            to: "private enum VolatileSwiftUIAutosaveDefaultsPruner",
            in: appSource
        )
        XCTAssertTrue(bootMarkerBody.contains("MacSmokeStatusFailClosedWriter.append("))
        XCTAssertTrue(bootMarkerBody.contains("failMissingRequiredStatusFile"))
        XCTAssertFalse(bootMarkerBody.contains("try? SmokeStatusFileAppender.append"))

        guard let reporterStart = appSource.range(of: "private struct SmokeStatusReporter")?.lowerBound else {
            XCTFail("Expected SmokeStatusReporter in SkyBridgeCompassApp.")
            return
        }
        let smokeStatusReporterBody = String(appSource[reporterStart...])
        XCTAssertTrue(smokeStatusReporterBody.contains("MacSmokeStatusFailClosedWriter.reset("))
        XCTAssertTrue(smokeStatusReporterBody.contains("MacSmokeStatusFailClosedWriter.append("))
        XCTAssertFalse(smokeStatusReporterBody.contains("try?"))

        let deviceDiscoverySource = try readSource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")
        let smokeLineAppender = try sourceSlice(
            from: "private func appendSmokeStatusLine",
            to: "private func appendMacOnlineIPadConnectAppActionIfNeeded",
            in: deviceDiscoverySource
        )
        XCTAssertTrue(smokeLineAppender.contains("MacSmokeStatusFailClosedWriter.append("))
        XCTAssertFalse(smokeLineAppender.contains("try? SmokeStatusFileAppender.append"))
    }

    func testMacOnlineStartupAvoidsBundleMainResourceResolutionBeforeRootViewCanRender() throws {
        let dashboardSource = try readSource("Sources/SkyBridgeCompassApp/DashboardViewModel.swift")
        let localizationSource = try readSource("Sources/SkyBridgeCore/Localization/LocalizationManager.swift")
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let startupCoordinatorSource = try readSource("Sources/SkyBridgeCompassApp/Core/StartupCoordinator.swift")
        let appInfoPlist = try readSource("Sources/SkyBridgeCompassApp/Info.plist")
        let xcodeInfoPlist = try readSource("XcodeSupport/SkyBridgeCompassMac/Info.plist")
        let projectYAML = try readSource("project.yml")
        let brandIconSource = try readSource("Sources/SkyBridgeCompassApp/SVGEmbeddedImageView.swift")
        let menuBarControllerSource = try readSource("Sources/SkyBridgeUI/MenuBar/MenuBarController.swift")
        let menuBarIconGeneratorSource = try readSource("Sources/SkyBridgeUI/MenuBar/MenuBarIconGenerator.swift")
        let crossNetworkConnectionViewSource = try readSource("Sources/SkyBridgeCompassApp/Views/CrossNetworkConnectionView.swift")
        let dashboardStoredProperties = try sourceSlice(
            from: "final class DashboardViewModel: ObservableObject",
            to: "// MARK: - 初始化",
            in: dashboardSource
        )
        let brandIconLoaderSource = try sourceSlice(
            from: "private enum BrandIconAssetLoader",
            to: "private extension View",
            in: brandIconSource
        )
        let iconSource = try sourceSlice(
            from: "private static func applyAppIconIfAvailable() -> Bool",
            to: "func resolveDevelopmentIconURL() -> URL?",
            in: appSource
        )
        let appIconFallbackSource = try sourceSlice(
            from: "guard let url = resolveDevelopmentIconURL() else",
            to: "guard let icon = NSImage(contentsOf: url) else",
            in: appSource
        )
        let notificationSource = try sourceSlice(
            from: "private static func configureNotificationsUnified()",
            to: "/// 设置菜单栏通知处理器",
            in: appSource
        )
        let rootServicesContainerSource = try sourceSlice(
            from: "private struct RootAppServicesContainer: View",
            to: "private struct PreferencesSceneContent: View",
            in: appSource
        )
        let rootContainerViewSource = try sourceSlice(
            from: "private struct RootContainerView: View",
            to: "private struct SupabasePasswordResetSheet: View",
            in: appSource
        )
        let rootAuthenticationTask = try sourceSlice(
            from: ".task(id: authModel.currentSession)",
            to: ".overlay(alignment: .topTrailing)",
            in: rootContainerViewSource
        )
        let dashboardAuthenticationUpdate = try sourceSlice(
            from: "func updateAuthentication(session: AuthSession?) async",
            to: "/// 根据当前认证状态启动各项后台服务。",
            in: dashboardSource
        )

        XCTAssertFalse(
            dashboardStoredProperties.contains("LocalizationManager.shared.localizedString"),
            "DashboardViewModel stored property initialization must not synchronously resolve localization bundles before the smoke root view can render."
        )
        XCTAssertTrue(
            dashboardStoredProperties.contains("statusText: ConnectionStatus.disconnected.displayName"),
            "The pre-render disconnected label should come from the non-resource connection status until live presentation bindings install localized labels."
        )
        XCTAssertTrue(
            dashboardStoredProperties.contains("private lazy var discoveryService = DeviceDiscoveryService.shared"),
            "DashboardViewModel must not construct the discovery service while SwiftUI is still creating App-level StateObjects."
        )
        XCTAssertTrue(
            dashboardStoredProperties.contains("private lazy var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared"),
            "The unified online manager starts path monitors, timers, and persisted-device loading; keep it out of App StateObject initialization."
        )
        XCTAssertFalse(
            dashboardStoredProperties.contains("private let unifiedDeviceManager = UnifiedOnlineDeviceManager.shared"),
            "Do not eagerly construct the unified online manager before the startup progress view can render."
        )
        guard let coordinatedLaunch = appSource.range(of: "await startupCoordinator.startCoordinatedLaunch()"),
              let connectionBindings = appSource.range(of: "appModel.bootstrapConnectionPresentationBindings()") else {
            XCTFail("Expected coordinated launch and deferred dashboard bindings in SkyBridgeCompassApp.")
            return
        }
        XCTAssertLessThan(
            coordinatedLaunch.lowerBound,
            connectionBindings.lowerBound,
            "Dashboard presentation bindings subscribe to device/presence managers and must install after coordinated launch settles."
        )
        guard let rootServiceSettledGate = rootServicesContainerSource.range(
            of: "await StartupCoordinator.shared.waitUntilLaunchSettled()"
        ),
              let rootServiceBindings = rootServicesContainerSource.range(
                of: "appModel.bootstrapConnectionPresentationBindings()"
              ) else {
            XCTFail("Expected RootAppServicesContainer to gate service bootstrapping on launch settled.")
            return
        }
        XCTAssertLessThan(
            rootServiceSettledGate.lowerBound,
            rootServiceBindings.lowerBound,
            "Root service bootstrapping must wait for the startup progress stable period before subscribing to device managers."
        )
        XCTAssertTrue(
            rootAuthenticationTask.contains("await dashboardModel.updateAuthentication(session: authModel.currentSession)")
        )
        XCTAssertFalse(
            rootAuthenticationTask.contains("CurrentPathDeviceActivationCoordinator.shared.syncIfNeeded"),
            "Login-to-dashboard auth state changes must not synchronously wait for current-path activation before the dashboard can become interactive."
        )
        XCTAssertTrue(
            dashboardAuthenticationUpdate.contains("session.isAuthenticatedForProtectedServices"),
            "Dashboard protected service startup must reject guest, pending-verification, and empty-token sessions."
        )
        XCTAssertTrue(
            dashboardAuthenticationUpdate.contains("scheduleAuthenticatedStartup(for: session)"),
            "Authenticated dashboard service startup must be scheduled after the auth binding path returns."
        )
        XCTAssertFalse(
            dashboardAuthenticationUpdate.contains("await start()"),
            "Auth binding must not synchronously await the full DashboardViewModel.start() service graph."
        )
        XCTAssertTrue(
            dashboardSource.contains("authenticatedStartupTask?.cancel()"),
            "Post-login startup must be cancellable so logout or rapid account switches cannot keep old service work alive."
        )
        XCTAssertTrue(
            dashboardSource.contains("CurrentPathDeviceActivationCoordinator.shared.syncIfNeeded(session: session)"),
            "Current-path activation should remain part of authenticated startup, but off the root auth task's hot path."
        )
        XCTAssertTrue(
            appSource.contains("AuthenticationService.shared.hasAuthenticatedSessionForProtectedServices()"),
            "App active discovery recovery must not start protected device discovery for guest or pending-verification sessions."
        )
        XCTAssertTrue(
            crossNetworkConnectionViewSource.contains("guard AuthenticationService.shared.hasAuthenticatedSessionForProtectedServices() else"),
            "CrossNetworkConnectionView must not start protected discovery from an unauthenticated standalone window task."
        )
        XCTAssertTrue(
            startupCoordinatorSource.contains("prepareDeferredServiceLaunch()"),
            "StartupCoordinator should show progress for the launch plan without starting Bonjour/P2P/USB listeners before the first interactive frame."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("LocalPeerServiceCoordinator.shared.ensureHealthy()"),
            "Local peer listeners must start from the post-first-frame service queue, not the blocking launch coordinator."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("P2PNetworkManager.shared.start()"),
            "P2P/Bonjour listener startup can create identity TXT and network listeners; keep it out of the startup progress gate."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("UnifiedOnlineDeviceManager.shared.startDiscovery"),
            "USB/Bonjour discovery must not be started by StartupCoordinator before the root view can render."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("try MetalPerformanceOptimizer()"),
            "Metal performance optimizer construction is heavyweight and must not run before first frame."
        )
        XCTAssertTrue(localizationSource.contains("LocalizationBundleLookupCache"))
        XCTAssertFalse(
            localizationSource.contains("bundle.path(forResource:"),
            "Localization lookup must use cached direct resource-directory resolution instead of synchronous CFBundle pathForResource scans on the startup path."
        )
        XCTAssertFalse(
            localizationSource.contains("bundle.urls(forResourcesWithExtension:"),
            "Localization lookup must avoid repeated all-resource Bundle URL enumeration on the startup path."
        )
        XCTAssertTrue(localizationSource.contains("defaultResourceSearchBaseURLs()"))
        XCTAssertTrue(
            localizationSource.contains("A miss in the executable-relative resource roots is not authoritative."),
            "A default executable-resource miss must explicitly continue into the existing Bundle.module fallback chain."
        )
        XCTAssertFalse(
            localizationSource.contains("        return key\n    }\n    \n /// 发现 Bundle.main"),
            "The executable-relative resource lookup must not return the untranslated key as a terminal result."
        )
        XCTAssertTrue(appSource.contains("private static func packagedContentsURL() -> URL?"))
        XCTAssertFalse(iconSource.contains("Bundle.main.bundleURL"))
        XCTAssertFalse(iconSource.contains("Bundle.main.url(forResource"))
        XCTAssertFalse(
            iconSource.contains("NSApplication.shared.applicationIconImage ="),
            "Packaged app startup must not overwrite the Info.plist-declared app icon with a raw PNG or ICNS."
        )
        XCTAssertFalse(
            appSource.contains("resolvePackagedIconURL"),
            "Packaged app icon resolution must stay under Info.plist + LaunchServices ownership."
        )
        XCTAssertTrue(
            iconSource.contains("if isRunningFromPackagedApp"),
            "Packaged app startup should return after confirming LaunchServices owns the app icon."
        )
        XCTAssertTrue(
            appIconFallbackSource.contains("resolveDevelopmentIconURL()")
        )
        XCTAssertFalse(
            appSource.contains("resolveIconURL(named: \"AppIconDock\")"),
            "Debug fallback should not silently switch to the alternate Dock icon resource."
        )
        XCTAssertFalse(
            appSource.contains("withExtension: \"icns\""),
            "Runtime icon setup must not fall back to legacy ICNS resources."
        )
        XCTAssertTrue(appInfoPlist.contains("<key>CFBundleIconFile</key>"))
        XCTAssertTrue(appInfoPlist.contains("<string>AppIcon.icns</string>"))
        XCTAssertTrue(xcodeInfoPlist.contains("<key>CFBundleIconFile</key>"))
        XCTAssertTrue(xcodeInfoPlist.contains("<string>AppIcon.icns</string>"))
        XCTAssertFalse(appInfoPlist.contains("CFBundleIconName"))
        XCTAssertFalse(xcodeInfoPlist.contains("CFBundleIconName"))
        XCTAssertTrue(projectYAML.contains("Scripts/compile_xcode_icon_composer_assets.sh"))
        XCTAssertTrue(projectYAML.contains("inputFiles:"))
        XCTAssertTrue(projectYAML.contains("outputFiles:"))
        XCTAssertTrue(projectYAML.contains("Resources/AppIcon.icon/**"))
        XCTAssertTrue(projectYAML.contains("Resources/Assets.xcassets/**"))
        XCTAssertTrue(
            brandIconLoaderSource.contains("loadImageResource(named: preferredResourceName, withExtension: \"png\", bundle: .main)"),
            "Sidebar brand UI must be able to request the small-size optimized SidebarBrandIcon.png from the main bundle."
        )
        XCTAssertTrue(
            brandIconLoaderSource.contains("loadImageResource(named: \"BrandIcon\", withExtension: \"png\", bundle: .main)"),
            "Packaged in-app brand UI must read the canonical BrandIcon.png so sidebar/header icons do not drift through AppIcon.icns representation selection."
        )
        XCTAssertTrue(
            brandIconLoaderSource.contains("loadImageResource(named: \"AppIcon\", withExtension: \"png\", bundle: .module)"),
            "Non-packaged development runs must read the single canonical AppIcon.png resource."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("NSApplication.shared.applicationIconImage"),
            "Brand UI must not read the mutable/cached applicationIconImage as a visual source of truth."
        )
        XCTAssertTrue(brandIconLoaderSource.contains("return nil"))
        XCTAssertFalse(
            brandIconLoaderSource.contains("image(forResource"),
            "Brand icon startup must not use AppKit Bundle image lookup because it can synchronously initialize the main CoreUI catalog before the root device view renders."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("packagedResourceIconURLs"),
            "Packaged brand icon loading must not scan legacy resource lists."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("\"AppIconDock\""),
            "Brand icon loading must not consult the alternate Dock icon resource."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("\"app_icon\""),
            "Brand icon loading must not consult stale snake-case icon aliases."
        )
        XCTAssertTrue(
            menuBarControllerSource.contains("MenuBarCanonicalAppIconLoader.load()"),
            "Menu bar status icons must derive from the same canonical AppIcon loader as the rest of the brand UI."
        )
        XCTAssertTrue(
            menuBarControllerSource.contains("Bundle.main.url(forResource: \"AppIcon\", withExtension: \"icns\")"),
            "Packaged menu bar icons must read bundled AppIcon.icns directly."
        )
        XCTAssertFalse(
            menuBarControllerSource.contains("NSImage(named: \"MenuBarIcon\")"),
            "Menu bar status icons must not consult alternate named icon resources."
        )
        XCTAssertFalse(
            menuBarControllerSource.contains("systemSymbolName:"),
            "Menu bar status icons must not hide a missing canonical AppIcon behind an SF Symbol fallback."
        )
        XCTAssertFalse(
            menuBarControllerSource.contains("createCompassMenuBarIcon"),
            "Menu bar status icons must not redraw a separate compass glyph instead of using the canonical AppIcon."
        )
        XCTAssertTrue(
            menuBarIconGeneratorSource.contains("Bundle.main.url(forResource: \"AppIcon\", withExtension: \"icns\")"),
            "The legacy menu bar icon generator API must also render from the bundled canonical AppIcon.icns."
        )
        XCTAssertFalse(
            menuBarIconGeneratorSource.contains("NSColor.black.setStroke()"),
            "The legacy menu bar icon generator API must not draw an alternate monochrome signal glyph."
        )
        XCTAssertFalse(
            menuBarIconGeneratorSource.contains("isTemplate = true"),
            "The legacy menu bar icon generator API must not convert the canonical brand icon into a template replacement."
        )
        XCTAssertFalse(
            notificationSource.contains("Bundle.main"),
            "Startup notification setup must not touch Bundle.main before the root view can render."
        )
    }

    func testIOSAppIconPipelineDerivesFromCanonicalAppIcon() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let regenerateScript = try readSource("Scripts/regenerate_app_icons.sh")
        let iosProject = try readSource("SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj")
        let iosAppIconContents = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
        )

        let canonicalAppIcon = try Data(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/Resources/AppIcon.png")
        )
        let iconComposerAppIcon = try Data(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/Resources/AppIcon.icon/Assets/Image.png")
        )
        let iosBrandIcon = try Data(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets/BrandIcon.imageset/BrandIcon.png"
            )
        )
        let sidebarBrandIcon = try Data(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/Resources/SidebarBrandIcon.png")
        )

        XCTAssertEqual(
            iconComposerAppIcon,
            canonicalAppIcon,
            "Icon Composer must use the same canonical AppIcon.png as the runtime brand icon source."
        )
        XCTAssertEqual(
            iosBrandIcon,
            canonicalAppIcon,
            "iOS in-app BrandIcon must not drift from the canonical blue compass AppIcon.png."
        )
        XCTAssertNotEqual(
            sidebarBrandIcon,
            canonicalAppIcon,
            "SidebarBrandIcon.png must stay as a small-size optimized derivative instead of drifting back to the regular icon."
        )
        XCTAssertTrue(regenerateScript.contains("MASTER_PNG=\"$RES_DIR/AppIconMaster.png\""))
        XCTAssertTrue(regenerateScript.contains("SidebarBrandIcon.png"))
        XCTAssertTrue(
            regenerateScript.contains("sidebar_safe_area_padding = 64"),
            "SidebarBrandIcon.png needs an optical safe area so the sidebar icon does not touch the 44pt grid edge."
        )
        XCTAssertFalse(regenerateScript.contains("rsvg-convert"))
        XCTAssertTrue(
            regenerateScript.contains("def ios_app_icon_rgb(image):")
        )
        XCTAssertTrue(
            regenerateScript.contains("cropped = image.crop(alpha_bbox)") &&
                regenerateScript.contains("ImageOps.fit(") &&
                regenerateScript.contains("ios_base = ios_app_icon_rgb(img)"),
            "iOS AppIcon.appiconset must crop away the Mac transparent pre-rounded padding and produce a full-square opaque icon."
        )
        XCTAssertTrue(iosProject.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
        XCTAssertTrue(iosAppIconContents.contains("\"filename\" : \"AppIcon-1024.png\""))
    }

    func testWebRTCInboundControlLoopIgnoresDuplicateMessageAWithoutResettingSessionState() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let loopBody = try sourceSlice(
            from: "let maxInboundFrameBytes = WebRTCFramedPayloadPolicy.maximumPayloadByteCount",
            to: "private func establishP2PConnectionWithCode",
            in: source
        )
        let duplicateMessageABody = try sourceSlice(
            from: "if let activeDriver = handshakeState.driver {",
            to: "if let keys = handshakeState.sessionKeys",
            in: loopBody
        )

        XCTAssertTrue(loopBody.contains("guard totalLen > 0 && totalLen <= maxInboundFrameBytes"))
        XCTAssertTrue(loopBody.contains("var lastInboundFrameLength = 0"))
        XCTAssertTrue(loopBody.contains("var lastDecodedFrameLength = 0"))
        XCTAssertTrue(loopBody.contains("var lastHandshakeDriverState = \"none\""))
        XCTAssertTrue(loopBody.contains("var lastControlLoopEvent = \"start\""))
        XCTAssertTrue(duplicateMessageABody.contains("duplicate_message_a_while_waiting_finished"))
        XCTAssertTrue(duplicateMessageABody.contains("ignored duplicate fresh MessageA while waiting for Finished"))
        XCTAssertTrue(duplicateMessageABody.contains("frameBytes=\\(frame.count"))
        XCTAssertTrue(duplicateMessageABody.contains("continue"))
        XCTAssertFalse(duplicateMessageABody.contains("responder restarting unfinished handshake from fresh MessageA"))
        XCTAssertFalse(duplicateMessageABody.contains("handshakeState.driver = nil"))
        XCTAssertFalse(duplicateMessageABody.contains("self.webrtcSessionKeysBySessionId.removeValue(forKey: sessionID)"))
        XCTAssertTrue(loopBody.contains("lastFrameLen=\\(lastInboundFrameLength"))
        XCTAssertTrue(loopBody.contains("decodedFrameLen=\\(lastDecodedFrameLength"))
        XCTAssertTrue(loopBody.contains("driverState=\\(lastHandshakeDriverState"))
        XCTAssertTrue(loopBody.contains("lastEvent=\\(lastControlLoopEvent"))
        XCTAssertTrue(loopBody.contains("lastRekey=\\(self.lastRekeyEvent ?? \"-\""))
    }

    func testWebRTCPairingBootstrapReplyTaskIsOwnedCancelledAndErrorObservable() throws {
        let source = try readSource(
            "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
        )
        let pairingCase = try sourceSlice(
            from: "guard decision != PairingTrustApprovalService.Decision.reject else",
            to: "case .heartbeat(let payload):",
            in: source
        )
        let sendHelper = try sourceSlice(
            from: "func sendLocalPairingIdentityExchange(",
            to: "func sendLocalAuthenticatedRouteBindings(",
            in: source
        )

        XCTAssertTrue(source.contains("var pairingBootstrapTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("var pairingBootstrapTaskToken: UUID?"))
        XCTAssertTrue(source.contains("func isCurrentPairingBootstrapTaskOwner(_ taskToken: UUID) -> Bool"))
        XCTAssertTrue(source.contains("pairingBootstrapTask?.cancel()\n        }"))
        XCTAssertTrue(pairingCase.contains("pairingBootstrapTaskToken = nil"))
        XCTAssertTrue(pairingCase.contains("let pairingTaskToken = UUID()"))
        XCTAssertTrue(pairingCase.contains("guard isCurrentPairingBootstrapTaskOwner(pairingTaskToken)"))
        XCTAssertTrue(pairingCase.contains("pairingBootstrapTask?.cancel()"))
        XCTAssertTrue(
            pairingCase.contains(
                "pairingBootstrapTask = Task { @MainActor [weak self] in"
            )
        )
        XCTAssertTrue(pairingCase.contains("catch is CancellationError"))
        XCTAssertTrue(pairingCase.contains("appendWebRTCSessionDiagnostic("))
        XCTAssertTrue(pairingCase.contains("sendLocalPairingIdentityExchange("))
        XCTAssertFalse(pairingCase.contains("SelfIdentityProvider.shared"))
        XCTAssertFalse(pairingCase.contains("let sendPairingReply = sendFramed"))
        XCTAssertFalse(pairingCase.contains("fingerprintsBeforeMutation"))
        XCTAssertFalse(pairingCase.contains("fingerprintsAfterMutation"))

        let sendRange = try XCTUnwrap(sendHelper.range(of: "try await sendFramed(outPadded)"))
        let cancellationRange = try XCTUnwrap(
            sendHelper.range(
                of: "try Task.checkCancellation()",
                range: sendRange.upperBound..<sendHelper.endIndex
            )
        )
        let exactSessionRange = try XCTUnwrap(
            sendHelper.range(
                of: "guard self.isCurrentWebRTCControlLoopSecureOwner(",
                range: cancellationRange.upperBound..<sendHelper.endIndex
            )
        )
        XCTAssertTrue(
            sendHelper[exactSessionRange.lowerBound...].contains("keys: keys")
        )
        let fingerprintRange = try XCTUnwrap(
            sendHelper.range(
                of: "self.webrtcBootstrapReplyFingerprintBySessionId[sessionID] = fingerprint",
                range: exactSessionRange.upperBound..<sendHelper.endIndex
            )
        )
        XCTAssertLessThan(sendRange.lowerBound, cancellationRange.lowerBound)
        XCTAssertLessThan(cancellationRange.lowerBound, exactSessionRange.lowerBound)
        XCTAssertLessThan(exactSessionRange.lowerBound, fingerprintRange.lowerBound)
    }

    func testRealDeviceWebRTCSmokeSourceContractUsesVerifiedAppleXWingAndPrivateAuthBoundaries() throws {
        let source = try readSource("Scripts/run_real_device_webrtc_smoke.sh")
        let productAppSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let productOutputSource = try readSource("Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift")
        let noticeSource = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlSecurityNotice.swift")
        let noticePanelSource = try readSource("Sources/SkyBridgeUI/Security/RemoteControlSecurityNoticePanelController.swift")
        let supabaseSource = try readSource("Sources/SkyBridgeCore/Services/SupabaseService.swift")
        let localHostSource = try readSource("Sources/LocalWebRTCSmokeHost/main.swift")
        let localSmokeSource = try readSource("Scripts/run_local_webrtc_smoke.sh")
        let iOSWebRTCHarnessSource = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalWebRTCSmokeHarness.swift"
        )
        let iOSP2PHarnessSource = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/App/Smoke/LocalP2PSmokeHarness.swift"
        )
        let iOSSigningHelpers = try readSource("Scripts/ios_distribution_signing_helpers.sh")
        let iOSSigningResolver = try readSource("Scripts/resolve_ios_distribution_signing.py")
        let iOSIPAExtractor = try readSource("Scripts/extract_ios_ipa.py")
        let iOSProductVerifier = try readSource("Scripts/verify_ios_distribution_product.py")
        let releaseAcceptanceFinalizer = try readSource("Scripts/finalize_release_acceptance_manifests.py")
        let iOSBuildSource = try sourceSlice(
            from: "IOS_XCODEBUILD_SETTINGS=(",
            to: "echo \"==> Starting macOS WebRTC host\"",
            in: source
        )

        XCTAssertTrue(source.contains("source \"$ROOT_DIR/Scripts/apple_pqc_sdk_probe.sh\""))
        XCTAssertTrue(source.contains("skybridge_configure_optional_apple_pqc_sdk_compile_gate macosx"))
        XCTAssertTrue(source.contains("SKYBRIDGE_ENABLE_APPLE_PQC_SDK:-0"))
        XCTAssertTrue(source.contains("skybridge_configure_optional_apple_pqc_sdk_compile_gate iphoneos"))
        XCTAssertTrue(source.contains("skybridge_apple_pqc_sdk_probe_succeeded"))
        XCTAssertTrue(source.contains("SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK"))
        XCTAssertTrue(source.contains("SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1"))
        XCTAssertTrue(source.contains("skybridge_run_xcodebuild \"${IOS_XCODEBUILD_ARGS[@]}\""))
        XCTAssertTrue(source.contains("--disable-dependency-cache"))
        XCTAssertTrue(source.contains("--manifest-cache local"))
        XCTAssertTrue(source.contains("--scratch-path \"$SMOKE_BUILD_DIR\""))
        XCTAssertTrue(source.contains("-Xswiftc -warnings-as-errors"))
        XCTAssertTrue(source.contains(") >\"$MAC_BUILD_LOG\" 2>&1"))
        XCTAssertTrue(
            source.contains(
                "skybridge_run_xcodebuild \"${IOS_XCODEBUILD_ARGS[@]}\" >\"$IOS_BUILD_LOG\" 2>&1"
            )
        )
        XCTAssertTrue(iOSBuildSource.contains("skybridge_archive_ios_distribution_product"))
        XCTAssertTrue(iOSBuildSource.contains("skybridge_export_ios_distribution_archive"))
        XCTAssertTrue(iOSBuildSource.contains("skybridge_extract_single_ios_exported_app"))
        XCTAssertTrue(iOSBuildSource.contains("installed-only"))
        XCTAssertFalse(iOSBuildSource.contains("CODE_SIGN_STYLE=Manual"))
        XCTAssertFalse(iOSBuildSource.contains("CODE_SIGN_IDENTITY=$IOS_DISTRIBUTION_IDENTITY_HASH"))
        let archiveRange = try XCTUnwrap(
            iOSBuildSource.range(of: "skybridge_archive_ios_distribution_product")
        )
        let exportRange = try XCTUnwrap(
            iOSBuildSource.range(of: "skybridge_export_ios_distribution_archive")
        )
        let extractRange = try XCTUnwrap(
            iOSBuildSource.range(of: "skybridge_extract_single_ios_exported_app")
        )
        let proofRange = try XCTUnwrap(
            iOSBuildSource.range(of: "verify_ios_product_app \"$IOS_APP_PATH\"")
        )
        let installRange = try XCTUnwrap(
            iOSBuildSource.range(of: "device install app --device \"$IOS_DEVICE_ID\" \"$IOS_APP_PATH\"")
        )
        XCTAssertLessThan(archiveRange.lowerBound, exportRange.lowerBound)
        XCTAssertLessThan(exportRange.lowerBound, extractRange.lowerBound)
        XCTAssertLessThan(extractRange.lowerBound, proofRange.lowerBound)
        XCTAssertLessThan(proofRange.lowerBound, installRange.lowerBound)
        XCTAssertTrue(source.contains("RejectAuthRedirects"))
        XCTAssertTrue(source.contains("minimum_remaining_seconds=MIN_FINAL_TOKEN_LIFETIME_SECONDS"))
        XCTAssertTrue(source.contains("MAC_TOKEN=\"$AUTH_PRIVATE_DIR/mac.token\""))
        XCTAssertTrue(source.contains("IOS_LAUNCH_JSON=\"$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-launch.raw.json\""))
        XCTAssertFalse(source.contains("IOS_LAUNCH_JSON=\"$AUTH_PRIVATE_DIR/ios-launch.raw.json\""))
        XCTAssertTrue(source.contains("\"rawLaunchContextRetained\": False"))
        XCTAssertTrue(source.contains("write_private_session_atomically"))
        XCTAssertTrue(source.contains("Supabase rejected the real-device smoke auth-session refresh"))
        XCTAssertTrue(source.contains("Supabase auth-session refresh response is missing access_token"))
        XCTAssertTrue(source.contains("write_private_value_atomically(token, token_output_path"))
        XCTAssertTrue(source.contains("precreate_product_output_files"))
        XCTAssertTrue(source.contains("SKYBRIDGE_SMOKE_EXPECTED_AUTH_BINDING_SHA256=$AUTH_BINDING_DIGEST"))
        XCTAssertTrue(source.contains("SkyBridge-WebRTC-Product-Acceptance-V3"))
        XCTAssertFalse(source.contains("SKYBRIDGE_SMOKE_TOKEN_FILE=$MAC_TOKEN"))
        XCTAssertFalse(source.contains("SKYBRIDGE_SMOKE_TENANT_FILE=$MAC_TENANT"))
        XCTAssertTrue(source.contains("KEYCHAIN_MODE=\"${SKYBRIDGE_SMOKE_KEYCHAIN_MODE:-system}\""))
        XCTAssertTrue(source.contains("MAC_HOST_MODE=\"${SKYBRIDGE_SMOKE_MAC_HOST_MODE:-product}\""))
        XCTAssertTrue(source.contains("In-memory identity and the CLI host are diagnostic-only"))
        XCTAssertTrue(source.contains("remoteControlNoticeHumanApproved session=${SESSION_REGEX}"))
        XCTAssertTrue(source.contains("\"keychainMode\": keychain_mode"))
        XCTAssertTrue(source.contains("\"approvalSurface\": \"shared-product-panel\""))
        XCTAssertTrue(source.contains("\"runtimeAutoApproval\": False"))
        XCTAssertTrue(source.contains("\"acceptanceEligible\": False"))
        XCTAssertTrue(source.contains("\"cleanupComplete\": False"))
        XCTAssertTrue(source.contains("finalize_release_acceptance_manifests_after_cleanup"))
        XCTAssertTrue(source.contains("python3 \"$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py\""))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("FINALIZATION_ORDER = \"private-then-public-v1\""))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("_atomic_replace(\n        private_path,"))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("_verify_final_manifest(private_path, final_content, final_payload)"))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("_atomic_replace(\n        public_path,"))
        XCTAssertTrue(releaseAcceptanceFinalizer.contains("_verify_final_manifest(public_path, final_content, final_payload)"))
        XCTAssertTrue(source.contains("exact-process-exit-unverified"))
        XCTAssertTrue(source.contains("IOS_BUILD_CONFIGURATION=\"${SKYBRIDGE_IOS_BUILD_CONFIGURATION:-Release}\""))
        XCTAssertTrue(source.contains("source \"$ROOT_DIR/Scripts/ios_distribution_signing_helpers.sh\""))
        XCTAssertTrue(source.contains("python3 \"$ROOT_DIR/Scripts/resolve_ios_distribution_signing.py\""))
        XCTAssertTrue(source.contains("skybridge_write_ios_distribution_product_proof"))
        XCTAssertTrue(iOSSigningResolver.contains("Physical iOS Automatic export requires exactly one installed matching"))
        XCTAssertTrue(iOSSigningResolver.contains("entitlements.get(\"get-task-allow\") is False"))
        XCTAssertTrue(iOSSigningResolver.contains("profile.get(\"IsXcodeManaged\") is True"))
        XCTAssertTrue(iOSSigningResolver.contains("\"schemaVersion\": 2"))
        XCTAssertTrue(iOSSigningResolver.contains("\"signingStyle\": expected_signing_style"))
        XCTAssertTrue(iOSSigningHelpers.contains("\"CODE_SIGN_STYLE=Automatic\""))
        XCTAssertTrue(iOSSigningHelpers.contains("\"SKYBRIDGE_IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER=\""))
        XCTAssertTrue(iOSSigningHelpers.contains("unset CODE_SIGN_IDENTITY"))
        XCTAssertTrue(iOSSigningHelpers.contains("release-testing"))
        XCTAssertTrue(iOSSigningHelpers.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(iOSIPAExtractor.contains("IPA contains an unsafe path component"))
        XCTAssertTrue(iOSIPAExtractor.contains("IPA contains a link or special file"))
        XCTAssertTrue(iOSIPAExtractor.contains("IPA contains duplicate normalized paths"))
        XCTAssertTrue(iOSIPAExtractor.contains("os.replace(staging_app, destination_app)"))
        XCTAssertTrue(iOSProductVerifier.contains("certificateMatch"))
        XCTAssertTrue(iOSProductVerifier.contains("nestedWidgetVerified"))
        XCTAssertTrue(iOSProductVerifier.contains("releaseProvenanceVerified"))
        XCTAssertFalse(source.contains("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING"))
        XCTAssertFalse(source.contains("Warning: failed to refresh real-device smoke auth session"))

        XCTAssertFalse(localHostSource.contains("SKYBRIDGE_SMOKE_TOKEN_FILE"))
        XCTAssertFalse(localHostSource.contains("SKYBRIDGE_SMOKE_TENANT_FILE"))
        XCTAssertFalse(localHostSource.contains("auth-refresh-fallback"))
        XCTAssertFalse(localHostSource.contains("loadKeychainDataViaSecurityCLI"))
        XCTAssertFalse(localHostSource.contains("process.waitUntilExit()"))
        XCTAssertFalse(localHostSource.contains("try? SmokeStatusFileAppender"))
        XCTAssertTrue(localHostSource.contains("pathMetadata.st_uid == geteuid()"))
        XCTAssertTrue(localHostSource.contains("pathMetadata.st_nlink == 1"))
        XCTAssertTrue(localHostSource.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(localHostSource.contains("O_RDONLY | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(localHostSource.contains("stored auth session is malformed"))
        XCTAssertTrue(localHostSource.contains("Supabase smoke configuration is incomplete"))
        for pqcSmokeSource in [localHostSource, iOSWebRTCHarnessSource, iOSP2PHarnessSource] {
            XCTAssertFalse(pqcSmokeSource.contains("ignoreUnknownCharacters"))
            XCTAssertTrue(pqcSmokeSource.contains("expectedByteCount: 1_216"))
            XCTAssertTrue(pqcSmokeSource.contains("expectedByteCount: 1_184"))
        }
        XCTAssertTrue(
            iOSWebRTCHarnessSource.contains(
                "streamConfigurationTransaction: RemoteDesktopStreamConfigurationTransaction()"
            ),
            "Each logical WebRTC smoke stream configuration must carry the shared transaction correlation required by the production ingress policy."
        )
        XCTAssertTrue(localSmokeSource.contains("read_private_auth_session_field accessToken"))
        XCTAssertFalse(localSmokeSource.contains("read_private_auth_session_field nebulaId"))
        XCTAssertTrue(localSmokeSource.contains("resolve_signaling_tenant_from_access_token \"$ACCESS_TOKEN\""))
        XCTAssertFalse(localSmokeSource.contains("SKYBRIDGE_SMOKE_TOKEN_FILE"))
        XCTAssertFalse(localSmokeSource.contains("SKYBRIDGE_SMOKE_TENANT_FILE"))
        XCTAssertFalse(localSmokeSource.contains("local_webrtc_smoke_auth_cache"))
        XCTAssertFalse(localSmokeSource.contains("using stored access token"))

        XCTAssertFalse(productAppSource.contains("SKYBRIDGE_SMOKE_TOKEN_FILE"))
        XCTAssertFalse(productAppSource.contains("SKYBRIDGE_SMOKE_TENANT_FILE"))
        XCTAssertFalse(productAppSource.contains("exportProductAuthContext"))
        XCTAssertFalse(productAppSource.contains("Data(session.accessToken.utf8)"))
        XCTAssertTrue(productAppSource.contains("fromProductBundle()"))
        XCTAssertTrue(productAppSource.contains("authBinding=verified"))
        XCTAssertTrue(productAppSource.contains("SkyBridge-WebRTC-Product-Acceptance-V3"))
        XCTAssertTrue(productAppSource.contains("validatePrecreatedPrivateFile"))
        XCTAssertTrue(productOutputSource.contains("O_WRONLY | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(productOutputSource.contains("metadata.st_nlink == 1"))
        XCTAssertTrue(productOutputSource.contains("metadata.st_mode & mode_t(0o777) == mode_t(0o600)"))
        XCTAssertTrue(productAppSource.contains("WebRTCSmokeEvidenceReader"))
        XCTAssertTrue(productAppSource.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(productAppSource.contains("maximumChunkBytes = 64 * 1_024"))
        XCTAssertFalse(productAppSource.contains("String(contentsOf: statusURL"))

        XCTAssertTrue(noticeSource.contains("private func approveCurrentNoticeFromUserInteraction()"))
        XCTAssertTrue(noticeSource.contains("@_spi(RemoteControlSecurityNoticeUI)"))
        let ordinaryApproval = try sourceSlice(
            from: "public func approveCurrentNotice()",
            to: "/// Approval entry point reserved for the real user-facing panel action.",
            in: noticeSource
        )
        XCTAssertFalse(ordinaryApproval.contains("HumanApproved"))
        XCTAssertEqual(noticeSource.components(separatedBy: "appendEvidence(event: \"HumanApproved\"").count - 1, 1)
        XCTAssertTrue(noticePanelSource.contains("@_spi(RemoteControlSecurityNoticeUI) import SkyBridgeCore"))
        XCTAssertEqual(
            noticePanelSource.components(separatedBy: ".approveNoticeFromUserInteraction(id:").count - 1,
            1
        )
        let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources", isDirectory: true)
        let sourceEnumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        var humanApprovalUICallSites = 0
        for case let fileURL as URL in sourceEnumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            humanApprovalUICallSites += contents
                .components(separatedBy: ".approveNoticeFromUserInteraction(id:").count - 1
        }
        XCTAssertEqual(humanApprovalUICallSites, 1)

        XCTAssertTrue(supabaseSource.contains("public static func fromProductBundle()"))
        XCTAssertTrue(supabaseSource.contains("#if DEBUG"))
    }

    private func routeBindingPayload() -> AppMessage.AuthenticatedRouteBindingPayload {
        AppMessage.AuthenticatedRouteBindingPayload(
            kind: "fileTransfer",
            serviceType: BonjourInteropContract.fileTransferServiceType,
            instanceName: "Desk Mac._skybridge-xfer._tcp.local",
            hostName: "desk-mac.local",
            port: 9443,
            endpointProvenance: "resolved-dns-sd-endpoint",
            localDeviceId: "mac-device",
            remoteDeviceId: "android-device",
            routeAuthorityProtocolPublicKeyFingerprint: String(repeating: "a", count: 64),
            remoteProtocolPublicKeyFingerprint: String(repeating: "a", count: 64),
            sessionHashHex: "0123456789abcdef",
            transcriptPrefixHex: "fedcba9876543210",
            sentAt: Date(timeIntervalSinceReferenceDate: 42),
            expiresAt: Date(timeIntervalSinceReferenceDate: 72),
            nonce: Data(1...16)
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSlice(
        from startMarker: String,
        to endMarker: String,
        in source: String
    ) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            throw SourceMarkerError(startMarker: startMarker, endMarker: endMarker)
        }
        return String(source[start..<end])
    }

    private struct SourceMarkerError: Error, CustomStringConvertible {
        let startMarker: String
        let endMarker: String

        var description: String {
            "Source marker not found from '\(startMarker)' to '\(endMarker)'"
        }
    }
}
