import Network
import XCTest
@testable import SkyBridgeCore
import SkyBridgeProtocolCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PDiscoveryBootstrapControlTests: XCTestCase {
    private actor SOAPeerIDLoaderProbe {
        enum Failure: Error {
            case unavailable
        }

        private var calls = 0

        func fail() throws -> Data {
            calls += 1
            throw Failure.unavailable
        }

        func load(_ value: Data) -> Data {
            calls += 1
            return value
        }

        func invocationCount() -> Int {
            calls
        }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let protocolPublicKey = Data(repeating: 0x33, count: 1184)
    private var fingerprint: String {
        ProtocolIdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: .mlDSA65
        ).authoritativeFingerprint
    }

    func testSharedInboundAdmissionPolicyDefinesAppleRoleParity() {
        XCTAssertEqual(P2PInboundAdmissionPolicy.maximumConcurrentConnections, 32)
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.maximumConcurrentConnectionsPerRemoteEndpoint,
            4
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.deadlineSeconds(for: .awaitingFirstFrame),
            12
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.deadlineSeconds(for: .bootstrapCrypto),
            45
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.deadlineSeconds(for: .initialHandshake),
            45
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.deadlineSeconds(
                for: .protocolIdentityConfirmation
            ),
            195
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.releaseMilestone(for: .awaitingFirstFrame),
            .transitionWithoutRelease
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.releaseMilestone(for: .bootstrapCrypto),
            .responseSubmitted
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.releaseMilestone(
                for: .protocolIdentityConfirmation
            ),
            .responseSubmitted
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.releaseMilestone(for: .initialHandshake),
            .authenticatedSessionEstablished
        )

        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.maximumTransactions,
            32
        )
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.maximumTransactionsPerRequester,
            4
        )
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.admissionWindowSeconds,
            10
        )
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy
                .maximumAdmissionsPerRequesterPerWindow,
            8
        )
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.maximumRequestAgeSeconds,
            120
        )
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.maximumRequestFutureSkewSeconds,
            30
        )
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.candidateResponseTimeoutSeconds,
            30
        )
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.defaultFinalAckResponseTimeoutSeconds,
            195
        )
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            P2PProtocolIdentityBindingAdmissionPolicy.boundedChildExpiry(
                parentExpiry: issuedAt.addingTimeInterval(20),
                issuedAt: issuedAt
            ),
            issuedAt.addingTimeInterval(20)
        )
    }

    func testProtocolIdentityConfirmationBudgetIsFiniteAndBounded() {
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.deadlineSeconds(
                for: .protocolIdentityConfirmation,
                protocolIdentityConfirmationResponseBudgetSeconds: .infinity
            ),
            195
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.deadlineSeconds(
                for: .protocolIdentityConfirmation,
                protocolIdentityConfirmationResponseBudgetSeconds: 1
            ),
            45
        )
        XCTAssertEqual(
            P2PInboundAdmissionPolicy.deadlineSeconds(
                for: .protocolIdentityConfirmation,
                protocolIdentityConfirmationResponseBudgetSeconds: 10_000
            ),
            315
        )
    }

    func testFirstFrameBudgetUsesMonotonicDeadlineWithoutReset() throws {
        let now = ContinuousClock.now
        let deadline = now.advanced(by: .seconds(12))
        let remaining = try XCTUnwrap(
            P2PInboundAdmissionPolicy.remainingSeconds(
                until: deadline,
                now: now.advanced(by: .seconds(5))
            )
        )
        XCTAssertEqual(remaining, 7, accuracy: 0.000_001)
        XCTAssertNil(
            P2PInboundAdmissionPolicy.remainingSeconds(
                until: deadline,
                now: deadline
            )
        )
        XCTAssertNil(
            P2PInboundAdmissionPolicy.remainingSeconds(
                until: deadline,
                now: deadline.advanced(by: .milliseconds(1))
            )
        )
    }

    func testMacAndIOSInboundAdaptersUseSharedStagedAdmissionContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mac = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
            ),
            encoding: .utf8
        )
        let ios = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
            ),
            encoding: .utf8
        )

        for (platform, source) in [("macOS", mac), ("iOS", ios)] {
            XCTAssertTrue(
                source.contains(
                    "P2PInboundAdmissionPolicy.maximumConcurrentConnections"
                ),
                platform
            )
            XCTAssertTrue(
                source.contains("stage: .awaitingFirstFrame"),
                platform
            )
            XCTAssertTrue(source.contains("stage: .initialHandshake"), platform)
            XCTAssertTrue(
                source.contains("stage = .protocolIdentityConfirmation")
                    || source.contains("processingStage = .protocolIdentityConfirmation")
                    || source.contains("return .protocolIdentityConfirmation"),
                platform
            )
            XCTAssertTrue(
                source.contains("ifOwnedBy: processingLease"),
                platform
            )
        }

        let macTimeout = try sourceSlice(
            mac,
            from: "private func armProvisionalInboundTimeout(",
            to: "private func beginProcessingProvisionalInboundConnection("
        )
        XCTAssertTrue(macTimeout.contains("inboundControlSessions.first(where:"))
        XCTAssertTrue(
            macTimeout.contains(
                "ObjectIdentifier($0.value.connection) == identifier"
            )
        )
        XCTAssertTrue(macTimeout.contains("?.value.task?.cancel()"))
        XCTAssertTrue(
            macTimeout.contains(
                "provisionalInboundTimeoutTasks[identifier]?.token == token"
            )
        )
        XCTAssertFalse(
            macTimeout.contains("provisionalInboundConnections.removeValue")
        )

        let iosTimeout = try sourceSlice(
            ios,
            from: "private func armProvisionalInboundTimeout(",
            to: "private func beginProcessingProvisionalInboundConnection("
        )
        XCTAssertTrue(
            iosTimeout.contains("inboundControlSessionTasks[identifier]?.task.cancel()")
        )
        XCTAssertTrue(
            iosTimeout.contains(
                "provisionalInboundTimeoutTasks[identifier]?.token == token"
            )
        )
        XCTAssertFalse(
            iosTimeout.contains("provisionalInboundConnections.removeValue")
        )

        let iosInbound = try sourceSlice(
            ios,
            from: "private func handleIncomingConnection(",
            to: "/// 开始从连接接收消息"
        )
        XCTAssertTrue(iosInbound.contains("Self.inboundFramedReader(for: connection)"))
        XCTAssertTrue(iosInbound.contains("hasActiveAuthenticatedSession("))
        XCTAssertFalse(iosInbound.contains("startReceivingOutboundFrames("))
        XCTAssertFalse(ios.contains("private static let provisionalInboundTimeoutSeconds: TimeInterval = 10"))

        let iosSessionOwner = try sourceSlice(
            ios,
            from: "private func startInboundControlSession(",
            to: "private nonisolated static func inboundFramedReader("
        )
        XCTAssertTrue(iosSessionOwner.contains("Task { @MainActor [weak self] in"))
        XCTAssertFalse(iosSessionOwner.contains("weak connection"))
        let iosOwnerDefer = try XCTUnwrap(iosSessionOwner.range(of: "defer {"))
        let iosOwnerReceive = try XCTUnwrap(
            iosSessionOwner.range(of: "await self.handleIncomingConnection(")
        )
        XCTAssertLessThan(iosOwnerDefer.lowerBound, iosOwnerReceive.lowerBound)
        XCTAssertTrue(
            iosSessionOwner[iosOwnerDefer.lowerBound..<iosOwnerReceive.lowerBound]
                .contains("self.finishProvisionalInboundConnection(connection)")
        )
        XCTAssertTrue(
            iosSessionOwner[iosOwnerDefer.lowerBound..<iosOwnerReceive.lowerBound]
                .contains("inboundControlSessionTasks[identifier]?.token == token")
        )

        let macInbound = try sourceSlice(
            mac,
            from: "nonisolated private func handleInboundControlChannel(",
            to: "private static func localProtocolIdentityPublicKeysForPairing()"
        )
        let driverHandle = try XCTUnwrap(
            macInbound.range(of: "await activeDriver.handleMessage(frame, from: peer)")
        )
        let driverState = try XCTUnwrap(
            macInbound.range(
                of: "let st = await activeDriver.getCurrentState()",
                range: driverHandle.upperBound..<macInbound.endIndex
            )
        )
        let established = try XCTUnwrap(
            macInbound.range(
                of: "case .established(let keys):",
                range: driverState.upperBound..<macInbound.endIndex
            )
        )
        let authenticatedAuthority = try XCTUnwrap(
            macInbound.range(
                of: ".getAuthenticatedRemoteAuthority()",
                range: established.upperBound..<macInbound.endIndex
            )
        )
        let arbiterLease = try XCTUnwrap(
            macInbound.range(
                of: "getEstablishedArbiterLease()",
                range: authenticatedAuthority.upperBound..<macInbound.endIndex
            )
        )
        let pairKeyBinding = try XCTUnwrap(
            macInbound.range(
                of: "newArbiterLease.pairKey == inboundPairKey",
                range: arbiterLease.upperBound..<macInbound.endIndex
            )
        )
        let sessionBinding = try XCTUnwrap(
            macInbound.range(
                of: "newArbiterLease.sessionId == keys.sessionId",
                range: pairKeyBinding.upperBound..<macInbound.endIndex
            )
        )
        let sessionPublish = try XCTUnwrap(
            macInbound.range(
                of: "sessionKeys = keys",
                range: sessionBinding.upperBound..<macInbound.endIndex
            )
        )
        let exactRelease = try XCTUnwrap(
            macInbound.range(
                of: "finishProvisionalInboundConnection(",
                range: sessionPublish.upperBound..<macInbound.endIndex
            )
        )
        for earlier in [
            driverHandle,
            driverState,
            established,
            authenticatedAuthority,
            arbiterLease,
            pairKeyBinding,
            sessionBinding,
            sessionPublish,
        ] {
            XCTAssertLessThan(earlier.lowerBound, exactRelease.lowerBound)
        }
        XCTAssertTrue(
            macInbound[exactRelease.lowerBound...].contains("ifOwnedBy: processingLease")
        )

        let failedBranch = try XCTUnwrap(macInbound.range(of: "if case .failed(let reason) = st"))
        let stateSwitch = try XCTUnwrap(
            macInbound.range(
                of: "switch st {",
                range: failedBranch.upperBound..<macInbound.endIndex
            )
        )
        XCTAssertFalse(
            macInbound[failedBranch.lowerBound..<stateSwitch.lowerBound]
                .contains("finishProvisionalInboundConnection(")
        )
        XCTAssertFalse(
            macInbound[driverState.upperBound..<established.lowerBound]
                .contains("finishProvisionalInboundConnection(")
        )

        let iosDiscovery = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(iosDiscovery.contains("claimProtocolInboundAdmission("))
        XCTAssertTrue(
            iosDiscovery.contains(
                "P2PInboundAdmissionPolicy.remainingSeconds("
            )
        )
    }

    private func sourceSlice(
        _ source: String,
        from start: String,
        to end: String
    ) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound..<source.endIndex)
        )
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    func testProvenBootstrapEndpointIsPromotedWithoutChangingCandidateSet() {
        let first = NWEndpoint.hostPort(host: "192.0.2.10", port: 9_527)
        let second = NWEndpoint.hostPort(host: "192.0.2.11", port: 9_527)
        let proven = NWEndpoint.hostPort(host: "192.0.2.12", port: 9_527)
        let original = [first, second, proven]

        let prioritized = P2PDiscoveryService.prioritizingProvenEndpoint(
            proven,
            in: original
        )

        XCTAssertEqual(prioritized.map(\.debugDescription), [
            proven.debugDescription,
            first.debugDescription,
            second.debugDescription
        ])
        XCTAssertEqual(Set(prioritized.map(\.debugDescription)), Set(original.map(\.debugDescription)))
    }

    func testUnknownOrMissingBootstrapEndpointDoesNotChangeCandidateOrder() {
        let first = NWEndpoint.hostPort(host: "192.0.2.10", port: 9_527)
        let second = NWEndpoint.hostPort(host: "192.0.2.11", port: 9_527)
        let unknown = NWEndpoint.hostPort(host: "192.0.2.99", port: 9_527)
        let original = [first, second]
        let originalKeys = original.map(\.debugDescription)

        XCTAssertEqual(
            P2PDiscoveryService.prioritizingProvenEndpoint(nil, in: original)
                .map(\.debugDescription),
            originalKeys
        )
        XCTAssertEqual(
            P2PDiscoveryService.prioritizingProvenEndpoint(unknown, in: original)
                .map(\.debugDescription),
            originalKeys
        )
    }

    func testAuthenticatedBootstrapEndpointFeedsEachSubsequentConnectionPhase() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "let confirmationEndpoints = Self.prioritizingProvenEndpoint(\n            exchange.endpoint"
        ))
        XCTAssertTrue(source.contains(
            "let refreshEndpoints = Self.prioritizingProvenEndpoint(\n                identityBinding.endpoint"
        ))
        XCTAssertTrue(source.contains("return exchange.endpoint"))
        XCTAssertTrue(source.contains(
            "let provenPreflightEndpoint = try await ensureStrictPQCOutboundPreflightReady("
        ))
        XCTAssertTrue(source.contains(
            "endpointAttempts = Self.prioritizingProvenEndpoint(\n            provenPreflightEndpoint"
        ))
    }

    func testKEMRefreshRequestMapsSuccessToSignedRefreshAndServedStatus() async throws {
        let request = kemRefreshRequest()
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .kemRefreshRequest(request),
            makeSignedKEMRefreshPayload: { request in
                self.signedKEMRefreshPayload(for: request)
            },
            makeSignedProtocolIdentityBindingPayload: { _ in
                throw Self.testError("unexpected PIB-1 path")
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .signedKEMRefreshServed = controlResponse.kind else {
            return XCTFail("Expected SKR-1 served response")
        }
        guard case .signedKEMRefresh(let payload) = controlResponse.message else {
            return XCTFail("Expected signedKEMRefresh message")
        }
        XCTAssertEqual(payload.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertEqual(payload.requestNonce, request.nonce)
        XCTAssertEqual(payload.policyAllowClassicFallback, false)
        XCTAssertEqual(payload.routeScope, "lan")
        XCTAssertFalse(payload.signature.isEmpty)
        XCTAssertTrue(controlResponse.statusLine.contains("SKR-1 signed LAN KEM refresh served"))
        XCTAssertTrue(controlResponse.statusLine.contains("wireId=0x0001"))
        XCTAssertTrue(controlResponse.statusLine.contains("responderLatencyMs="))
        XCTAssertFalse(controlResponse.statusLine.contains(request.requesterDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains(request.targetDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains(payload.keyId))
        XCTAssertTrue(controlResponse.statusLine.contains("requester=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("target=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("keyId=<redacted>"))
        XCTAssertFalse(controlResponse.isFailure)
    }

    func testKEMRefreshServesMLKEM768WireID0101ForStrictImport() async throws {
        XCTAssertEqual(CryptoSuite.mlkem768MLDSA65.wireId, 0x0101)
        let request = kemRefreshRequest(
            requestedSuiteWireIds: [CryptoSuite.mlkem768MLDSA65.wireId]
        )
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .kemRefreshRequest(request),
            makeSignedKEMRefreshPayload: { request in
                self.signedKEMRefreshPayload(
                    for: request,
                    suite: .mlkem768MLDSA65,
                    publicKeyByteCount: 1_184
                )
            },
            makeSignedProtocolIdentityBindingPayload: { _ in
                throw Self.testError("unexpected PIB-1 path")
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .signedKEMRefresh(let payload) = controlResponse.message else {
            return XCTFail("Expected signed ML-KEM-768 refresh")
        }
        XCTAssertEqual(payload.kemPublicKeys.map(\.suiteWireId), [0x0101])
        XCTAssertEqual(payload.kemPublicKeys.first?.publicKey.count, 1_184)
        XCTAssertTrue(controlResponse.statusLine.contains("wireId=0x0101"))
        XCTAssertFalse(payload.signature.isEmpty)

        let validated = try payload.validatedForStrictPQCImport(
            request: request,
            now: now,
            pinnedProtocolFingerprints: [fingerprint],
            minimumGeneration: 8
        )
        XCTAssertEqual(validated.kemPublicKeys.map(\.suiteWireId), [0x0101])
    }

    func testKEMRefreshRequestMapsGeneratorFailureToDiagnosticFailure() async throws {
        let request = kemRefreshRequest(requestedSuiteWireIds: [0x0000])
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .kemRefreshRequest(request),
            makeSignedKEMRefreshPayload: { _ in
                throw Self.testError("SKR-1 rejected unknown suite wireId=0x0000")
            },
            makeSignedProtocolIdentityBindingPayload: { _ in
                throw Self.testError("unexpected PIB-1 path")
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .signedKEMRefreshRejected = controlResponse.kind else {
            return XCTFail("Expected SKR-1 rejected response")
        }
        guard case .kemRefreshFailure(let failure) = controlResponse.message else {
            return XCTFail("Expected diagnostic kemRefreshFailure")
        }
        XCTAssertEqual(failure.stage, "kem_refresh")
        XCTAssertEqual(failure.reasonCode, "unknown_suite")
        XCTAssertEqual(failure.reason, failure.reasonCode)
        XCTAssertFalse(failure.reason.contains("0x0000"))
        XCTAssertEqual(failure.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=request>rejected"))
        XCTAssertTrue(controlResponse.statusLine.contains("responderLatencyMs="))
        XCTAssertFalse(controlResponse.statusLine.contains(request.requesterDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains(request.targetDeviceId))
        XCTAssertFalse(controlResponse.statusLine.contains("SKR-1 rejected unknown suite"))
        XCTAssertTrue(controlResponse.statusLine.contains("requester=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("target=<redacted>"))
        XCTAssertTrue(controlResponse.statusLine.contains("reason=<redacted>"))
        XCTAssertTrue(controlResponse.isFailure)
    }

    func testKEMRefreshResponderLocalFailureCodesRemainNonSecretAndActionable() {
        let cases: [(reason: String, code: String)] = [
            (
                "local protocol identity unavailable",
                "local_protocol_identity_unavailable"
            ),
            (
                "local PQC KEM material unavailable",
                "local_pqc_kem_unavailable"
            ),
            (
                "local protocol identity signing unavailable",
                "local_protocol_identity_signing_unavailable"
            ),
            (
                "local device id unavailable",
                "local_device_id_unavailable"
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                P2PDiscoveryService.signedKEMRefreshFailureCode(
                    for: Self.testError(testCase.reason)
                ),
                testCase.code
            )
        }
    }

    func testKEMRefreshRequestResponderRejectsStrictPolicyFailuresAsDiagnosticOnly() async throws {
        let cases: [(name: String, request: AppMessage.KEMRefreshRequestPayload, reasonCode: String)] = [
            (
                "policy hash mismatch",
                kemRefreshRequest(policyHashHex: String(repeating: "0", count: 64), sentAt: Date()),
                "policy_hash_mismatch"
            ),
            (
                "missing requested suite",
                kemRefreshRequest(requestedSuiteWireIds: [], sentAt: Date()),
                "missing_requested_suite"
            ),
            (
                "unknown suite",
                kemRefreshRequest(requestedSuiteWireIds: [0x0000], sentAt: Date()),
                "unknown_suite"
            ),
            (
                "classic suite",
                kemRefreshRequest(requestedSuiteWireIds: [CryptoSuite.x25519Ed25519.wireId], sentAt: Date()),
                "classic_suite_rejected"
            ),
            (
                "invalid target identity",
                kemRefreshRequest(targetProtocolIdentityFingerprint: "not-a-fingerprint", sentAt: Date()),
                "invalid_target_protocol_identity"
            )
        ]

        for entry in cases {
            let response = await P2PDiscoveryService.makeBootstrapControlResponse(for: .kemRefreshRequest(entry.request))
            let controlResponse = try XCTUnwrap(response, entry.name)
            guard case .signedKEMRefreshRejected = controlResponse.kind else {
                return XCTFail("Expected \(entry.name) to reject SKR-1 before any success path")
            }
            guard case .kemRefreshFailure(let failure) = controlResponse.message else {
                return XCTFail("Expected \(entry.name) to return diagnostic kemRefreshFailure")
            }

            XCTAssertTrue(controlResponse.isFailure, entry.name)
            XCTAssertEqual(failure.stage, "kem_refresh", entry.name)
            XCTAssertEqual(failure.reasonCode, entry.reasonCode, entry.name)
            XCTAssertEqual(failure.reason, failure.reasonCode, entry.name)
            XCTAssertEqual(failure.requestHashHex, entry.request.canonicalRequestHashHex, entry.name)
            XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=request>rejected"), entry.name)
            XCTAssertFalse(controlResponse.statusLine.contains("served"), entry.name)
        }
    }

    func testKEMRefreshRequestResponderReportsPinnedTargetReplayAndRateLimitFailures() async throws {
        let identityContext = try DeviceIdentityKeychainTestContext()
        _ = try await identityContext.manager.getProtocolSigningIdentity(
            for: .mlDSA65,
            protection: .softwareKeychain
        )
        defer { try? identityContext.reset() }
        let store = PeerProtocolIdentityBootstrapStore.shared
        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
        await store.upsert(deviceIds: ["id:ios-1"], fingerprints: [fingerprint])

        let mismatchedTarget = String(repeating: "a", count: 64)
        let first = kemRefreshRequest(
            targetProtocolIdentityFingerprint: mismatchedTarget,
            sentAt: Date()
        )
        try await assertKEMRefreshRejected(
            first,
            reasonCode: "pinned_protocol_identity_mismatch_requires_oob",
            keyManager: identityContext.manager
        )

        try await assertKEMRefreshRejected(
            first,
            reasonCode: "request_replay_detected",
            keyManager: identityContext.manager
        )

        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
        for index in 0..<10 {
            let request = kemRefreshRequest(
                targetProtocolIdentityFingerprint: mismatchedTarget,
                nonce: Data(repeating: UInt8(index + 1), count: 24),
                sentAt: Date()
            )
            try await assertKEMRefreshRejected(
                request,
                reasonCode: "pinned_protocol_identity_mismatch_requires_oob",
                "attempt \(index)",
                keyManager: identityContext.manager
            )
        }

        let rateLimited = kemRefreshRequest(
            targetProtocolIdentityFingerprint: mismatchedTarget,
            nonce: Data(repeating: 0x7f, count: 24),
            sentAt: Date()
        )
        try await assertKEMRefreshRejected(
            rateLimited,
            reasonCode: "requester_rate_limited",
            keyManager: identityContext.manager
        )

        await store.clearForTesting()
        await SignedKEMRefreshRequestAdmissionGate.shared.clearForTesting()
    }

    func testProtocolIdentityBindingRequestMapsSuccessToSignedBindingAndServedStatus() async throws {
        let request = protocolIdentityBindingRequest()
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .protocolIdentityBindingRequest(request),
            makeSignedKEMRefreshPayload: { _ in
                throw Self.testError("unexpected SKR-1 path")
            },
            makeSignedProtocolIdentityBindingPayload: { request in
                self.signedProtocolIdentityBindingPayload(for: request)
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .protocolIdentityBindingServed = controlResponse.kind else {
            return XCTFail("Expected PIB-1 served response")
        }
        guard case .signedProtocolIdentityBinding(let payload) = controlResponse.message else {
            return XCTFail("Expected signedProtocolIdentityBinding message")
        }
        XCTAssertEqual(controlResponse.protocolIdentityBindingRequest, request)
        XCTAssertEqual(controlResponse.protocolIdentityBindingPayload, payload)
        XCTAssertEqual(payload.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertEqual(payload.policyAllowClassicFallback, false)
        XCTAssertEqual(payload.routeScope, "lan")
        XCTAssertEqual(controlResponse.protocolIdentityBindingCode?.count, 6)
        XCTAssertTrue(controlResponse.statusLine.contains("PIB-1 protocol identity binding served"))
        XCTAssertFalse(controlResponse.isFailure)
    }

    func testProtocolIdentityBindingRequestMapsGeneratorFailureToDiagnosticFailure() async throws {
        let request = protocolIdentityBindingRequest()
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(
            for: .protocolIdentityBindingRequest(request),
            makeSignedKEMRefreshPayload: { _ in
                throw Self.testError("unexpected SKR-1 path")
            },
            makeSignedProtocolIdentityBindingPayload: { _ in
                throw Self.testError("policy mismatch")
            }
        )

        let controlResponse = try XCTUnwrap(response)
        guard case .protocolIdentityBindingRejected = controlResponse.kind else {
            return XCTFail("Expected PIB-1 rejected response")
        }
        guard case .kemRefreshFailure(let failure) = controlResponse.message else {
            return XCTFail("Expected diagnostic kemRefreshFailure")
        }
        XCTAssertEqual(failure.stage, "identity_binding")
        XCTAssertEqual(failure.reasonCode, "policy_mismatch")
        XCTAssertEqual(failure.reason, failure.reasonCode)
        XCTAssertEqual(failure.requestHashHex, request.canonicalRequestHashHex)
        XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=identity-oob>rejected"))
        XCTAssertTrue(controlResponse.isFailure)
    }

    func testProtocolIdentityBindingPrefersActiveIdentityWithoutLoadingUnrelatedCompatibilitySlot() async throws {
        let active = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA65,
            protection: .softwareKeychain,
            publicKey: Data(repeating: 0x41, count: 1_952),
            keyHandle: .softwareKey(Data(repeating: 0x42, count: 4_032))
        )

        let selected = try await CommittedLocalProtocolIdentitySnapshot.selectPreferred(
            matching: [.mlDSA65, .ed25519],
            active: active
        ) { _ in
            throw Self.testError("unrelated malformed compatibility identity was loaded")
        }

        XCTAssertEqual(selected?.algorithm, .mlDSA65)
        XCTAssertEqual(selected?.publicKey, active.publicKey)
    }

    func testSignedKEMRefreshPrefersPinnedActiveIdentityWithoutLoadingUnrelatedCompatibilitySlot() async throws {
        let active = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA65,
            protection: .softwareKeychain,
            publicKey: Data(repeating: 0x51, count: 1_952),
            keyHandle: .softwareKey(Data(repeating: 0x52, count: 4_032))
        )

        let selected = try await CommittedLocalProtocolIdentitySnapshot.selectPreferred(
            matchingAuthoritativeFingerprint: active.authoritativeFingerprint,
            active: active
        ) { _ in
            throw Self.testError("unrelated malformed compatibility identity was loaded")
        }

        XCTAssertEqual(selected?.authoritativeFingerprint, active.authoritativeFingerprint)
        XCTAssertEqual(selected?.publicKey, active.publicKey)

        let unpinnedTarget = try await CommittedLocalProtocolIdentitySnapshot.selectPreferred(
            matchingAuthoritativeFingerprint: nil,
            active: active
        ) { _ in
            throw Self.testError("target-less SKR loaded an unrelated compatibility identity")
        }
        XCTAssertEqual(unpinnedTarget?.authoritativeFingerprint, active.authoritativeFingerprint)
    }

    func testSignedKEMRefreshCompatibilityIdentityRequiresExactPinnedFingerprint() async throws {
        let active = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA87,
            protection: .softwareKeychain,
            publicKey: Data(repeating: 0x61, count: 2_592),
            keyHandle: .softwareKey(Data(repeating: 0x62, count: 4_896))
        )
        let compatibility = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .ed25519,
            protection: .softwareKeychain,
            publicKey: Data(repeating: 0x63, count: 32),
            keyHandle: .softwareKey(Data(repeating: 0x64, count: 32))
        )

        let selected = try await CommittedLocalProtocolIdentitySnapshot.selectPreferred(
            matchingAuthoritativeFingerprint: compatibility.authoritativeFingerprint,
            active: active
        ) { algorithm in
            algorithm == .ed25519 ? compatibility : nil
        }

        XCTAssertEqual(selected?.algorithm, .ed25519)
        XCTAssertEqual(selected?.authoritativeFingerprint, compatibility.authoritativeFingerprint)

        let mismatch = try await CommittedLocalProtocolIdentitySnapshot.selectPreferred(
            matchingAuthoritativeFingerprint: String(repeating: "f", count: 64),
            active: active
        ) { algorithm in
            algorithm == .ed25519 ? compatibility : nil
        }
        XCTAssertNil(mismatch)

        do {
            _ = try await CommittedLocalProtocolIdentitySnapshot.selectPreferred(
                matchingAuthoritativeFingerprint: String(repeating: "e", count: 64),
                active: active
            ) { _ in
                throw Self.testError("requested compatibility identity is malformed")
            }
            XCTFail("A compatibility identity load failure must remain fail-closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("requested compatibility identity is malformed"))
        }
    }

    func testProtocolIdentityBindingFailsClosedWhenRequestedCompatibilitySlotIsMalformed() async throws {
        let active = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA87,
            protection: .softwareKeychain,
            publicKey: Data(repeating: 0x87, count: 2_592),
            keyHandle: .softwareKey(Data(repeating: 0x88, count: 4_896))
        )

        do {
            _ = try await CommittedLocalProtocolIdentitySnapshot.selectPreferred(
                matching: [.ed25519],
                active: active
            ) { algorithm in
                throw Self.testError("malformed requested \(algorithm.rawValue) identity")
            }
            XCTFail("A malformed requested compatibility identity must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("malformed requested Ed25519 identity"))
        }
    }

    func testProtocolIdentityBindingAlgorithmCandidatesMatchIOSOrdering() {
        XCTAssertEqual(
            P2PDiscoveryService.protocolIdentityBindingAlgorithmCandidates(activeAlgorithm: .mlDSA65),
            [.mlDSA65, .ed25519]
        )
        XCTAssertEqual(
            P2PDiscoveryService.protocolIdentityBindingAlgorithmCandidates(activeAlgorithm: .mlDSA87),
            [.mlDSA87, .mlDSA65, .ed25519]
        )
    }

    func testProtocolIdentityBindingTargetMatchRequiresLocalIdOrAlias() {
        XCTAssertTrue(
            P2PDiscoveryService.localResponderMatchesProtocolIdentityBindingTarget(
                targetDeviceId: "id:mac-1",
                localId: "id:mac-1",
                aliases: ["host:Studio"]
            )
        )
        XCTAssertTrue(
            P2PDiscoveryService.localResponderMatchesProtocolIdentityBindingTarget(
                targetDeviceId: "host:Studio",
                localId: "id:mac-1",
                aliases: ["host:Studio"]
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.localResponderMatchesProtocolIdentityBindingTarget(
                targetDeviceId: "id:other-device",
                localId: "id:mac-1",
                aliases: ["host:Studio"]
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.localResponderMatchesProtocolIdentityBindingTarget(
                targetDeviceId: "   ",
                localId: "id:mac-1",
                aliases: []
            )
        )
    }

    func testProtocolIdentityBindingTargetMismatchMapsToDiagnosticReasonCode() {
        let error = NSError(
            domain: "SkyBridge.ProtocolIdentityBinding",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "request target does not identify local responder"]
        )
        XCTAssertEqual(
            P2PDiscoveryService.protocolIdentityBindingFailureCode(for: error),
            "request_target_mismatch"
        )
    }

    func testInboundBootstrapControlRequestClassifierMatchesOwnedFramesOnly() {
        XCTAssertTrue(
            P2PDiscoveryService.isInboundBootstrapControlRequest(
                .protocolIdentityBindingRequest(protocolIdentityBindingRequest())
            )
        )
        XCTAssertTrue(
            P2PDiscoveryService.isInboundBootstrapControlRequest(
                .kemRefreshRequest(kemRefreshRequest())
            )
        )
        XCTAssertFalse(
            P2PDiscoveryService.isInboundBootstrapControlRequest(.ping(.init(id: 7)))
        )
        XCTAssertFalse(
            P2PDiscoveryService.isInboundBootstrapControlRequest(
                .signedKEMRefresh(signedKEMRefreshPayload(for: kemRefreshRequest()))
            )
        )
    }

    func testNonBootstrapControlMessageDoesNotProduceResponse() async {
        let response = await P2PDiscoveryService.makeBootstrapControlResponse(for: .ping(.init(id: 7)))
        XCTAssertNil(response)
    }

    func testInboundBootstrapPathTransitionsDeadlineBeforeSigning() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
                .path,
            encoding: .utf8
        )
        let marker = "Self.isInboundBootstrapControlRequest(plaintextControl)"
        guard let markerRange = source.range(of: marker) else {
            return XCTFail("Missing inbound bootstrap control request classifier")
        }
        let branchEnd = try XCTUnwrap(
            source.range(
                of: "if let currentDriver = driver,",
                range: markerRange.upperBound..<source.endIndex
            )
        )
        let window = String(
            source[markerRange.lowerBound..<branchEnd.lowerBound]
        )
        let transitionIndex = window.range(
            of: "beginProcessingProvisionalInboundConnection("
        )?.lowerBound
        let responseIndex = window.range(of: "makeBootstrapControlResponse(for: plaintextControl)")?.lowerBound
        let sendIndex = window.range(of: "try await sendFramed(encoded)")?.lowerBound
        let finishIndex = window.range(
            of: "finishProvisionalInboundConnection("
        )?.lowerBound
        XCTAssertNotNil(transitionIndex)
        XCTAssertNotNil(responseIndex)
        XCTAssertNotNil(sendIndex)
        XCTAssertNotNil(finishIndex)
        if let transitionIndex, let responseIndex, let sendIndex, let finishIndex {
            XCTAssertLessThan(
                transitionIndex,
                responseIndex,
                "The first-frame deadline must transition before SKR/PIB signing"
            )
            XCTAssertLessThan(responseIndex, sendIndex)
            XCTAssertLessThan(
                sendIndex,
                finishIndex,
                "The bounded admission slot must remain owned until response submission"
            )
        }
    }

    func testPIBFirstFrameDoesNotInvokeSOAPeerIDLoader() async throws {
        let probe = SOAPeerIDLoaderProbe()
        let frame = try JSONEncoder().encode(
            AppMessage.protocolIdentityBindingRequest(protocolIdentityBindingRequest())
        )

        let prepared = try await P2PDiscoveryService.prepareInboundHandshakeFrame(
            frame,
            cachedLocalSOAPeerId: nil,
            loadLocalSOAPeerId: {
                try await probe.fail()
            }
        )

        XCTAssertNil(prepared)
        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        let decoded = try AppMessage.decodeWireMessage(from: frame)
        XCTAssertTrue(P2PDiscoveryService.isInboundBootstrapControlRequest(decoded))
    }

    func testInboundControlReadsFirstFrameBeforeLoadingCommittedSOAIdentity() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
                .path,
            encoding: .utf8
        )
        let handlerStart = try XCTUnwrap(
            source.range(of: "nonisolated private func handleInboundControlChannel(")
        )
        let handlerEnd = try XCTUnwrap(
            source.range(
                of: "nonisolated private static func stableEndpointLabel(",
                range: handlerStart.upperBound..<source.endIndex
            )
        )
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        let receiveIndex = try XCTUnwrap(
            handler.range(of: "Self.receiveBootstrapFrame(")?.lowerBound
        )
        let classifierIndex = try XCTUnwrap(
            handler.range(of: "Self.isInboundBootstrapControlRequest(plaintextControl)")?.lowerBound
        )
        let soaLoadIndex = try XCTUnwrap(
            handler.range(of: "Self.localSOAPeerIdBytes()")?.lowerBound
        )

        XCTAssertLessThan(receiveIndex, soaLoadIndex)
        XCTAssertLessThan(classifierIndex, soaLoadIndex)
        XCTAssertTrue(handler.contains("cachedLocalSOAPeerId: localSOAPeerId"))
        XCTAssertTrue(source.contains("existingProtocolIdentityDeviceIdReadOnly()"))
    }

    func testMessageARequiresSOAPeerIDAndFailsClosedWhenLoaderFails() async {
        let probe = SOAPeerIDLoaderProbe()
        let frame = makeHandshakeMessageA().encoded

        do {
            _ = try await P2PDiscoveryService.prepareInboundHandshakeFrame(
                frame,
                cachedLocalSOAPeerId: nil,
                loadLocalSOAPeerId: {
                    try await probe.fail()
                }
            )
            XCTFail("MessageA preparation must fail when committed SOA identity is unavailable")
        } catch SOAPeerIDLoaderProbe.Failure.unavailable {
            // Expected fail-closed result.
        } catch {
            XCTFail("Unexpected MessageA preparation error: \(error)")
        }

        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testMessageAReusesOneSOAPeerIDAndBindsAuthenticatedInitiator() async throws {
        let probe = SOAPeerIDLoaderProbe()
        let localPeerID = Data(repeating: 0xA1, count: 32)
        let initiatorPeerID = Data(repeating: 0xB2, count: 32)
        let targetPeerID = Data(repeating: 0xC3, count: 32)
        let attemptID = Data(repeating: 0xD4, count: 16)
        let soa = try HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerID,
            targetPeerId: targetPeerID,
            attemptId: attemptID
        )
        let frame = makeHandshakeMessageA(extensionsRaw: soa.encodedTLV).encoded

        let firstPreparation = try await P2PDiscoveryService.prepareInboundHandshakeFrame(
            frame,
            cachedLocalSOAPeerId: nil,
            loadLocalSOAPeerId: {
                await probe.load(localPeerID)
            }
        )
        let first = try XCTUnwrap(firstPreparation)
        let secondPreparation = try await P2PDiscoveryService.prepareInboundHandshakeFrame(
            frame,
            cachedLocalSOAPeerId: first.localSOAPeerId,
            loadLocalSOAPeerId: {
                await probe.load(Data(repeating: 0xEE, count: 32))
            }
        )
        let second = try XCTUnwrap(secondPreparation)

        let invocationCount = await probe.invocationCount()
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(second.localSOAPeerId, localPeerID)
        let binding = InboundHandshakeAdapter.bindSOAState(
            from: second.messageA,
            localPeerId: second.localSOAPeerId
        )
        XCTAssertEqual(binding.expectedRemotePeerId, initiatorPeerID)
        XCTAssertEqual(
            binding.pairKey,
            PeerSessionArbiter.pairKey(
                localPeerId: localPeerID,
                remotePeerId: initiatorPeerID
            )
        )
        XCTAssertTrue(binding.usedAuthenticatedInitiator)
    }

    func testMacSignedLANRefreshUsesCryptographicResponseBudget() throws {
        XCTAssertEqual(
            P2PDiscoveryService.signedLANRefreshResponseTimeoutSeconds(),
            30
        )

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(
                "let responseTimeoutSeconds = Self.signedLANRefreshResponseTimeoutSeconds()"
            )
        )
        XCTAssertTrue(source.contains("responseTimeoutSeconds=\\(Int(responseTimeoutSeconds))"))
        XCTAssertTrue(source.contains("timeoutSeconds: responseTimeoutSeconds"))
        XCTAssertFalse(source.contains("timeoutSeconds: 8.0"))
    }

    func testMacBootstrapRequestDiagnosticsPrecedePotentialExchangeFailure() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )
        let pibStart = try XCTUnwrap(
            source.range(of: "private func attemptOutboundOOBProtocolIdentityBinding(")
        )
        let skrStart = try XCTUnwrap(
            source.range(
                of: "private func attemptOutboundSignedLANKEMRefresh(",
                range: pibStart.upperBound..<source.endIndex
            )
        )
        let exchangeStart = try XCTUnwrap(
            source.range(
                of: "private func exchangeBootstrapControlMessage(",
                range: skrStart.upperBound..<source.endIndex
            )
        )
        let pibSource = String(source[pibStart.lowerBound..<skrStart.lowerBound])
        let skrSource = String(source[skrStart.lowerBound..<exchangeStart.lowerBound])

        for (label, methodSource) in [("PIB-1", pibSource), ("SKR-1", skrSource)] {
            let requestLog = try XCTUnwrap(
                methodSource.range(of: "RemoteControlSmokeStatusWriter.append(requestLine)"),
                "\(label) request status log missing"
            )
            let exchange = try XCTUnwrap(
                methodSource.range(of: "let exchange = try await exchangeBootstrapControlMessage("),
                "\(label) exchange missing"
            )
            XCTAssertLessThan(
                requestLog.lowerBound,
                exchange.lowerBound,
                "\(label) request must remain observable when connection or response exchange fails"
            )
        }
    }

    func testBootstrapRecoveryDiagnosticsPreserveRootCauseAndStage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            encoding: .utf8
        )
        let responderSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/SkyBridgeCore/P2P/P2PDiscoveryService+BootstrapControl.swift"),
            encoding: .utf8
        )
        let iOSSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
            ),
            encoding: .utf8
        )
        let inboundResponseStart = try XCTUnwrap(
            iOSSource.range(of: "private func makeInboundBootstrapControlResponse(")
        )
        let inboundResponseEnd = try XCTUnwrap(
            iOSSource.range(
                of: "private func makeInboundSignedKEMRefreshPayload(",
                range: inboundResponseStart.upperBound..<iOSSource.endIndex
            )
        )
        let iOSInboundResponseSource = String(
            iOSSource[inboundResponseStart.lowerBound..<inboundResponseEnd.lowerBound]
        )

        XCTAssertTrue(
            responderSource.contains(
                "matchingAuthoritativeFingerprint: request.targetProtocolIdentityFingerprint"
            )
        )
        XCTAssertFalse(responderSource.contains("reason: error.localizedDescription"))
        XCTAssertFalse(iOSInboundResponseSource.contains("reason: error.localizedDescription"))
        XCTAssertTrue(responderSource.contains("code=local_device_id_unavailable"))
        XCTAssertTrue(responderSource.contains(#"throw makeSKRFailure("local device id unavailable")"#))
        XCTAssertTrue(macSource.contains("var localNetworkPermissionError: Error?"))
        XCTAssertTrue(macSource.contains("throw localNetworkPermissionError"))
        XCTAssertTrue(macSource.contains("var identityBindingCompleted = false"))
        XCTAssertTrue(macSource.contains("if identityBindingCompleted"))
        XCTAssertTrue(
            macSource.contains(
                "stage=preflight-kem-refresh reason=\\(Self.protocolIdentityLogRedaction)"
            )
        )
        XCTAssertTrue(iOSSource.contains("var identityBindingCompleted = false"))
        XCTAssertTrue(iOSSource.contains("if identityBindingCompleted"))
        XCTAssertTrue(
            iOSSource.contains(
                "SKR-1 signed LAN KEM refresh failed after PIB-1"
            )
        )
    }

    private func kemRefreshRequest(
        requestedSuiteWireIds: [UInt16] = [CryptoSuite.xwingMLDSA.wireId],
        policyHashHex: String? = nil,
        targetProtocolIdentityFingerprint: String? = nil,
        nonce: Data? = nil,
        sentAt: Date? = nil
    ) -> AppMessage.KEMRefreshRequestPayload {
        AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requesterProtocolIdentityFingerprint: fingerprint,
            targetProtocolIdentityFingerprint: targetProtocolIdentityFingerprint ?? fingerprint,
            requestedSuiteWireIds: requestedSuiteWireIds,
            policyHashHex: policyHashHex,
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: nonce ?? Data(repeating: 0x44, count: 24),
            sentAt: sentAt ?? now
        )
    }

    private func assertKEMRefreshRejected(
        _ request: AppMessage.KEMRefreshRequestPayload,
        reasonCode: String,
        _ message: String = "",
        keyManager: DeviceIdentityKeyManager? = nil
    ) async throws {
        let response: P2PDiscoveryService.BootstrapControlResponse?
        if let keyManager {
            response = await P2PDiscoveryService.makeBootstrapControlResponse(
                for: .kemRefreshRequest(request),
                makeSignedKEMRefreshPayload: { request in
                    try await P2PDiscoveryService.makeSignedKEMRefreshPayload(
                        for: request,
                        keyManager: keyManager,
                        loadLocalIdentities: {
                            [
                                try await CommittedLocalProtocolIdentitySnapshot.load(
                                    algorithm: .mlDSA65,
                                    protection: .softwareKeychain,
                                    keyManager: keyManager
                                )
                            ]
                        }
                    )
                },
                makeSignedProtocolIdentityBindingPayload: { request in
                    try await P2PDiscoveryService.makeSignedProtocolIdentityBindingPayload(for: request)
                }
            )
        } else {
            response = await P2PDiscoveryService.makeBootstrapControlResponse(
                for: .kemRefreshRequest(request)
            )
        }
        let controlResponse = try XCTUnwrap(response, message)
        guard case .signedKEMRefreshRejected = controlResponse.kind else {
            return XCTFail("Expected SKR-1 rejection \(message)")
        }
        guard case .kemRefreshFailure(let failure) = controlResponse.message else {
            return XCTFail("Expected diagnostic kemRefreshFailure \(message)")
        }

        XCTAssertTrue(controlResponse.isFailure, message)
        XCTAssertEqual(failure.stage, "kem_refresh", message)
        XCTAssertEqual(failure.reasonCode, reasonCode, message)
        XCTAssertEqual(failure.reason, failure.reasonCode, message)
        XCTAssertEqual(failure.requestHashHex, request.canonicalRequestHashHex, message)
        XCTAssertTrue(controlResponse.statusLine.contains("lifecycle=request>rejected"), message)
        XCTAssertFalse(controlResponse.statusLine.contains("lifecycle=request>served"), message)
    }

    private func signedKEMRefreshPayload(
        for request: AppMessage.KEMRefreshRequestPayload,
        suite: CryptoSuite = .xwingMLDSA,
        publicKeyByteCount: Int = 1_216
    ) -> AppMessage.SignedKEMRefreshPayload {
        AppMessage.SignedKEMRefreshPayload(
            deviceId: "id:mac-1",
            aliases: ["id:mac-1", "bonjour:mac@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: suite.wireId,
                    publicKey: Data(repeating: 0x55, count: publicKeyByteCount)
                )
            ],
            keyId: "skr1-test",
            generation: 9,
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data(repeating: 0x99, count: 64)
        )
    }

    private func makeHandshakeMessageA(extensionsRaw: Data = Data()) -> HandshakeMessageA {
        let capabilities = CryptoCapabilities(
            supportedKEM: ["X25519"],
            supportedSignature: ["Ed25519"],
            supportedAuthProfiles: ["classic"],
            supportedAEAD: ["AES-GCM"],
            pqcAvailable: false,
            platformVersion: "test",
            providerType: .classic
        )
        let policy = HandshakePolicy(
            requirePQC: false,
            allowClassicFallback: false,
            minimumTier: .classic,
            requireSecureEnclavePoP: false
        )
        let identity = IdentityPublicKeys(
            protocolPublicKey: Data(repeating: 0x22, count: 32),
            protocolAlgorithm: .ed25519,
            secureEnclavePublicKey: nil
        )
        let keyShare = HandshakeKeyShare(
            suite: .x25519Ed25519,
            shareBytes: Data(repeating: 0x33, count: 32)
        )
        return HandshakeMessageA(
            supportedSuites: [.x25519Ed25519],
            keyShares: [keyShare],
            clientNonce: Data(repeating: 0x11, count: 32),
            policy: policy,
            capabilities: capabilities,
            signature: Data(repeating: 0x44, count: 64),
            identityPublicKeys: identity,
            extensionsRaw: extensionsRaw
        )
    }

    private func protocolIdentityBindingRequest() -> AppMessage.ProtocolIdentityBindingRequestPayload {
        AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: "id:ios-1",
            targetDeviceId: "id:mac-1",
            requestedProtocolSigningAlgorithms: [
                ProtocolSigningAlgorithm.mlDSA65.rawValue,
                ProtocolSigningAlgorithm.ed25519.rawValue
            ],
            bonjourEndpointDigest: String(repeating: "c", count: 64),
            nonce: Data(repeating: 0x66, count: 24),
            sentAt: now
        )
    }

    private func signedProtocolIdentityBindingPayload(
        for request: AppMessage.ProtocolIdentityBindingRequestPayload
    ) -> AppMessage.SignedProtocolIdentityBindingPayload {
        AppMessage.SignedProtocolIdentityBindingPayload(
            transactionId: request.transactionId,
            deviceId: "id:mac-1",
            aliases: ["id:mac-1", "bonjour:mac@local."],
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: protocolPublicKey,
            protocolIdentityFingerprint: fingerprint,
            deviceName: "MacBook",
            sentAt: now,
            expiresAt: now.addingTimeInterval(300),
            requestNonce: request.nonce,
            requestHashHex: request.canonicalRequestHashHex,
            policyAllowClassicFallback: false,
            routeScope: "lan",
            bonjourEndpointDigest: request.bonjourEndpointDigest,
            signature: Data(repeating: 0x77, count: 64)
        )
    }

    private static func testError(_ reason: String) -> NSError {
        NSError(
            domain: "SkyBridge.Tests.BootstrapControl",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }
}
