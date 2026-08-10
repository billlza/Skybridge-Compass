import XCTest

final class P2PFailurePathHardeningTests: XCTestCase {
    func testQUICVideoDatagramFailsClosedUntilTransportUsesSeparateFlows() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/QUICTransportService.swift"
        )
        let sendVideoFrame = try sourceSlice(
            from: "public func sendVideoFrame(",
            to: "// MARK: - File Channel",
            in: source
        )

        XCTAssertTrue(sendVideoFrame.contains("throw QUICTransportError.datagramNotSupported"))
        XCTAssertFalse(sendVideoFrame.contains("contentContext: .datagram"))
        XCTAssertFalse(source.contains("quicOptions.isDatagram = true"))
        XCTAssertFalse(source.contains("startReceivingDatagrams("))
        XCTAssertFalse(source.contains("conn.receiveMessage"))
        XCTAssertTrue(source.contains("startReceivingReliableStream(connection: conn"))
        XCTAssertTrue(source.contains("NWProtocolQUIC.Options(\n            alpn: [Self.applicationProtocol]"))
        XCTAssertTrue(source.contains("configureSecurity?(quicOptions.securityProtocolOptions)"))
        XCTAssertFalse(source.contains("NWProtocolTLS.Options?"))
        XCTAssertFalse(source.contains("applicationProtocols.insert(tls"))

        let connect = try sourceSlice(
            from: "public func connect(",
            to: "/// 断开连接",
            in: source
        )
        XCTAssertTrue(connect.contains("withTaskCancellationHandler"))
        XCTAssertTrue(connect.contains("timeoutPendingConnect("))
        XCTAssertTrue(connect.contains("cancelConnectIfCurrent("))
        XCTAssertTrue(connect.contains("try Task.checkCancellation()"))
    }

    func testDiscoverySleepFailuresHaveExplicitCancellationAndDiagnostics() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        )
        let dynamicScan = try sourceSlice(
            from: "private func discoverServiceTypesDynamic",
            to: "private func startSingleBrowser",
            in: source
        )
        let flushSchedule = try sourceSlice(
            from: "private func scheduleFlush()",
            to: "private func flushPendingUpdates()",
            in: source
        )

        XCTAssertTrue(dynamicScan.contains("catch is CancellationError"))
        XCTAssertTrue(dynamicScan.contains("browser.cancel()\n            return []"))
        XCTAssertTrue(dynamicScan.contains("动态 Bonjour 服务目录扫描中止"))
        XCTAssertTrue(dynamicScan.contains("String(reflecting: Swift.type(of: error))"))

        XCTAssertTrue(flushSchedule.contains("catch is CancellationError"))
        XCTAssertTrue(flushSchedule.contains("发现更新防抖任务中止"))
        XCTAssertTrue(flushSchedule.contains("String(reflecting: Swift.type(of: error))"))
        XCTAssertFalse(flushSchedule.contains("静默忽略"))
    }

    func testBackgroundScanCancellationStopsBeforePublishingResults() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/BackgroundScanningService.swift"
        )
        let scan = try sourceSlice(
            from: "private func performBackgroundScan() async",
            to: "private func mergeBackgroundDiscoveredDevices()",
            in: source
        )

        XCTAssertTrue(scan.contains("defer { discoveryManager.stopScanning() }"))
        XCTAssertTrue(scan.contains("catch is CancellationError"))
        XCTAssertTrue(scan.contains("后台扫描等待中止"))
        let cancellationReturn = try XCTUnwrap(
            scan.range(of: "logger.debug(\"ℹ️ 后台扫描已取消\")\n            return"))
        let resultRead = try XCTUnwrap(
            scan.range(of: "let newDevices = discoveryManager.discoveredDevices"))
        XCTAssertLessThan(cancellationReturn.lowerBound, resultRead.lowerBound)
    }

    func testAuthenticatedHeartbeatFailureClosesMacInboundSession() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift"
        )
        let heartbeat = try sourceSlice(
            from: "let closeForAuthenticatedHeartbeatFailure:",
            to: "        do {\n            try await runSession()",
            in: source
        )

        XCTAssertTrue(heartbeat.contains("authenticated heartbeat failed; closing session"))
        XCTAssertTrue(heartbeat.contains("connection.cancel()"))
        XCTAssertTrue(heartbeat.contains(".contentProcessed { error in"))
        XCTAssertTrue(heartbeat.contains("guard let error else { return }"))
        XCTAssertEqual(
            heartbeat.components(separatedBy: "closeForAuthenticatedHeartbeatFailure(").count - 1,
            2,
            "The send completion and encode/encrypt catch must share one failure boundary."
        )
        XCTAssertFalse(heartbeat.contains("heartbeat is best-effort"))
    }

    func testP2PMetricsTaskAndDisconnectPresentationHaveExactOwners() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let lifecycle = try sourceSlice(
            from: "public func disconnect()",
            to: "// MARK: - Authentication (HandshakeDriver)",
            in: source
        )
        let metrics = try sourceSlice(
            from: "private func startMetricsIfNeeded()",
            to: "private static func durationSeconds(",
            in: source
        )

        XCTAssertTrue(source.contains("private struct MetricsTaskOwner: Sendable"))
        XCTAssertTrue(source.contains("private let metricsTaskOwnerLock"))
        XCTAssertFalse(source.contains("private var metricsTask: Task<Void, Never>?"))
        XCTAssertTrue(lifecycle.contains("metricsTaskOwnerLock.withLock"))
        XCTAssertTrue(lifecycle.contains("owner = nil"))
        XCTAssertTrue(lifecycle.contains("Task { @MainActor [weak self] in"))

        XCTAssertTrue(metrics.contains("owner = MetricsTaskOwner(token: ownerToken"))
        XCTAssertGreaterThanOrEqual(
            metrics.components(separatedBy: "isCurrentMetricsTask(ownerToken)").count - 1,
            6
        )
        XCTAssertTrue(metrics.contains("owner?.task = task"))
        XCTAssertTrue(metrics.contains("Task { @MainActor [weak self] in"))
    }

    func testTrafficPaddingAutoFlushRetainsFailureAndRateLimitsRetries() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/P2P/TrafficPaddingStats.swift")
        let autoFlush = try sourceSlice(
            from: "private func maybeFlush(cfg: Config) async",
            to: "public func flushToCSV() async throws",
            in: source
        )

        XCTAssertTrue(source.contains("public struct FlushFailureSnapshot: Sendable, Equatable"))
        XCTAssertTrue(source.contains("public func flushFailureSnapshot() -> FlushFailureSnapshot?"))
        XCTAssertTrue(autoFlush.contains("lastFlushAttemptAt = attemptAt"))
        XCTAssertTrue(autoFlush.contains("lastFlushFailure = failure"))
        XCTAssertTrue(autoFlush.contains("TrafficPaddingStats auto-flush failed"))
        XCTAssertFalse(autoFlush.contains("best-effort only"))
        XCTAssertTrue(source.contains("throw PersistenceError.utf8EncodingFailed"))
        XCTAssertFalse(source.contains("data(using: .utf8) ?? Data()"))
    }

    func testConnectionReadinessPollingPropagatesCancellation() throws {
        for relativePath in [
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift",
            "Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift",
        ] {
            let source = try repositorySource(relativePath)
            let readiness = try sourceSlice(
                from: "nonisolated private static func waitUntilReady",
                to: "///",
                in: source
            )
            XCTAssertTrue(readiness.contains("catch is CancellationError"), relativePath)
            XCTAssertTrue(readiness.contains("P2P readiness polling failed"), relativePath)
            XCTAssertFalse(readiness.contains("try? await Task.sleep"), relativePath)
        }
    }

    func testIOSAuthenticatedPongFailureUsesAuthenticatedChannelCleanup() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let handler = try sourceSlice(
            from: "func handleInboundAppMessageOverWebRTC(",
            to: "func maybeStartPQCRekeyOverWebRTC(",
            in: source
        )
        let pongHandler = try sourceSlice(
            from: "case .ping(let payload):",
            to: "case .pong:",
            in: handler
        )
        let decodedControlHandler = try sourceSlice(
            from: "private func handleDecodedControlPlaintext(",
            to: "private func hasActiveHandshakeDriver()",
            in: source
        )

        XCTAssertTrue(handler.contains("sessionObjectIdentifier: ObjectIdentifier"))
        XCTAssertTrue(pongHandler.contains("WebRTC authenticated pong reply failed; closing session"))
        XCTAssertTrue(pongHandler.contains("let diagnosticError = error as NSError"))
        XCTAssertTrue(pongHandler.contains("error_domain=\\(diagnosticError.domain) code=\\(diagnosticError.code)"))
        XCTAssertTrue(pongHandler.contains("reason: \"authenticated_pong_reply_failed\""))
        XCTAssertTrue(pongHandler.contains("originatingReceiveLoop: .control"))
        XCTAssertTrue(pongHandler.contains("return false"))
        XCTAssertFalse(pongHandler.contains("error.localizedDescription"))
        XCTAssertFalse(pongHandler.contains("SkyBridgeDiagnosticRedaction"))
        XCTAssertFalse(pongHandler.contains("// Best-effort reply."))

        XCTAssertTrue(decodedControlHandler.contains("guard await handleInboundAppMessageOverWebRTC("))
        XCTAssertTrue(decodedControlHandler.contains(") else {\n                return false\n            }"))
        XCTAssertTrue(decodedControlHandler.contains("return isCurrentSession("))
    }

    func testIOSAuthenticatedAppSendBindsTheSessionIncarnationAcrossAwait() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let send = try sourceSlice(
            from: "func sendAppMessageOverWebRTC(",
            to: "func sendPairingIdentityExchangeOverWebRTC(",
            in: source
        )
        let inboundPairing = try sourceSlice(
            from: "case .pairingIdentityExchange(let payload):",
            to: "case .kemRefreshRequest",
            in: source
        )
        let sendPairing = try sourceSlice(
            from: "func sendPairingIdentityExchangeOverWebRTC(",
            to: "private func authenticatedConversationFingerprint(",
            in: source
        )

        XCTAssertTrue(send.contains("let sessionObjectIdentifier = ObjectIdentifier(session)"))
        XCTAssertEqual(
            send.components(separatedBy: "guard isCurrentSession(").count - 1,
            2,
            "The app-control send must bind the session before encryption and after the awaited transport send."
        )
        XCTAssertEqual(
            send.components(separatedBy: "throw RemoteDesktopError.disconnected").count - 1,
            3,
            "A stale incarnation and missing keys must remain distinguishable from success."
        )
        XCTAssertFalse(send.contains("guard currentSessionId == sessionId else { return }"))
        XCTAssertTrue(send.contains("keys.sessionId == sessionId"))
        XCTAssertEqual(
            sendPairing.components(separatedBy: "guard isCurrentSession(").count - 1,
            4,
            "Pairing exchange must bind the exact session before material access, after KEM access, immediately before submission, and after content enters the transport."
        )
        XCTAssertFalse(sendPairing.contains("guard currentSessionId == sessionId else { return }"))

        XCTAssertGreaterThanOrEqual(
            inboundPairing.components(separatedBy: "isCurrentSession(").count - 1,
            2,
            "Inbound pairing must validate its incarnation before admission and from the transaction's post-await commit witness."
        )
        XCTAssertTrue(inboundPairing.contains("try await sendPairingIdentityExchangeOverWebRTC("))
        XCTAssertTrue(inboundPairing.contains("error_domain=\\(diagnosticError.domain) code=\\(diagnosticError.code)"))
        XCTAssertFalse(inboundPairing.contains("error.localizedDescription"))

        let rekey = try sourceSlice(
            from: "func maybeStartPQCRekeyOverWebRTC(",
            to: "private func hasActiveHandshakeDriver()",
            in: source
        )
        XCTAssertTrue(rekey.contains("let expectedSessionObjectIdentifier = ObjectIdentifier(session)"))
        XCTAssertTrue(rekey.contains("func isCurrentRekeyOperation() -> Bool"))
        XCTAssertTrue(rekey.contains("activeOutboundRekeyOperationToken == rekeyOperationToken"))
        XCTAssertTrue(rekey.contains("handshakeDriver === driver"))
        XCTAssertTrue(rekey.contains("establishedKeys.sessionId == sessionId"))
    }

    func testIOSControlReceiveFailuresNeverJoinTheirOwnReceiveTask() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let inboundRekeySetup = try sourceSlice(
            from: "private func ensureInboundPQCRekeyDriverIfNeeded(",
            to: "private func ensureInboundInitialHandshakeDriverIfNeeded(",
            in: source
        )
        let inboundInitialSetup = try sourceSlice(
            from: "private func ensureInboundInitialHandshakeDriverIfNeeded(",
            to: "private func failStrictPQCBootstrapSession(",
            in: source
        )
        let inboundRekeyState = try sourceSlice(
            from: "private func syncInboundPQCRekeyState(",
            to: "private func syncInboundInitialHandshakeState(",
            in: source
        )
        let inboundInitialState = try sourceSlice(
            from: "private func syncInboundInitialHandshakeState(",
            to: "func sendAppMessageOverWebRTC(",
            in: source
        )
        let strictFailure = try sourceSlice(
            from: "private func failStrictPQCBootstrapSession(",
            to: "private func syncInboundPQCRekeyState(",
            in: source
        )

        for body in [inboundRekeySetup, inboundInitialSetup] {
            XCTAssertEqual(
                body.components(separatedBy: "await failStrictPQCBootstrapSession(").count - 1,
                body.components(separatedBy: "originatingReceiveLoop: .control").count - 1
            )
        }
        XCTAssertEqual(
            inboundRekeyState.components(separatedBy: "originatingReceiveLoop: .control").count - 1,
            4,
            "Inbound rekey has four exact terminal boundaries, including missing authenticated authority."
        )
        XCTAssertEqual(
            inboundInitialState.components(separatedBy: "originatingReceiveLoop: .control").count - 1,
            4,
            "Inbound initial handshake has four exact terminal boundaries, including missing authenticated authority."
        )
        XCTAssertTrue(strictFailure.contains("originatingReceiveLoop: ReceiveLoopTaskKind? = nil"))
        XCTAssertTrue(strictFailure.contains("originatingReceiveLoop: originatingReceiveLoop"))
    }

    func testIOSPreSessionNetworkOperationsCannotPublishAfterLifecycleInvalidation() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let scannedConnect = try sourceSlice(
            from: "public func connect(fromScannedString string: String) async",
            to: "public func importVerifiedConnectLinkTrust(",
            in: source
        )
        let codeConnect = try sourceSlice(
            from: "public func connect(withCode rawCode: String) async",
            to: "private func performConnectWithCode(",
            in: source
        )
        let codeWorker = try sourceSlice(
            from: "private func performConnectWithCode(",
            to: "public func generateConnectionCode() async -> String?",
            in: source
        )
        let connectionCode = try sourceSlice(
            from: "public func generateConnectionCode() async -> String?",
            to: "private func scheduleConnectionCodeLeaseInvalidation(",
            in: source
        )
        let connectLink = try sourceSlice(
            from: "public func generateConnectLink(validDuration: TimeInterval = 300) async -> String?",
            to: "public func disconnect(clearSnapshot: Bool = true) async",
            in: source
        )
        let qrRedeem = try sourceSlice(
            from: "private func parseSkybridgeConnectLink(",
            to: "nonisolated private static func normalizedNonEmptyToken",
            in: source
        )
        let operationWitness = try sourceSlice(
            from: "private func beginPreSessionOperation(",
            to: "private func beginSessionBootstrapOperation(",
            in: source
        )

        XCTAssertTrue(scannedConnect.contains("let operation = beginPreSessionOperation(kind: .scannedConnect)"))
        XCTAssertGreaterThanOrEqual(
            scannedConnect.components(separatedBy: "expectedOperation: operation").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            scannedConnect.components(separatedBy: "try requireActivePreSessionOperation(operation)").count - 1,
            3
        )
        XCTAssertTrue(scannedConnect.contains("} catch is CancellationError {"))

        XCTAssertTrue(codeConnect.contains("let sessionEpoch = sessionLifecycleEpoch"))
        XCTAssertTrue(codeConnect.contains("expectedSessionLifecycleEpoch: sessionEpoch"))
        XCTAssertTrue(codeConnect.contains("let operation = beginPreSessionOperation(kind: .connectionCodeConnect)"))
        XCTAssertTrue(codeConnect.contains("expectedOperation: operation"))
        XCTAssertGreaterThanOrEqual(
            codeWorker.components(separatedBy: "try requireActivePreSessionOperation(expectedOperation)").count - 1,
            3
        )
        XCTAssertGreaterThanOrEqual(
            codeWorker.components(separatedBy: "sessionLifecycleEpoch == expectedSessionLifecycleEpoch").count - 1,
            3
        )
        XCTAssertTrue(codeWorker.contains("expectedConnectionCodeLifecycleEpoch"))

        XCTAssertTrue(connectionCode.contains("var requestOperation = beginPreSessionOperation(kind: .connectionCodeGeneration)"))
        XCTAssertGreaterThanOrEqual(
            connectionCode.components(separatedBy: "try requireActivePreSessionOperation(requestOperation)").count - 1,
            3
        )
        XCTAssertTrue(connectLink.contains("let requestOperation = beginPreSessionOperation(kind: .connectLinkGeneration)"))
        XCTAssertGreaterThanOrEqual(
            connectLink.components(separatedBy: "try requireActivePreSessionOperation(requestOperation)").count - 1,
            5
        )
        XCTAssertTrue(qrRedeem.contains("expectedOperation: PreSessionOperation"))
        XCTAssertGreaterThanOrEqual(
            qrRedeem.components(separatedBy: "try requireActivePreSessionOperation(expectedOperation)").count - 1,
            6
        )

        XCTAssertTrue(operationWitness.contains("activePreSessionOperation == expected"))
        XCTAssertTrue(operationWitness.contains("try requireSessionLifecycleEpoch(expected.lifecycleEpoch)"))
        XCTAssertTrue(operationWitness.contains("if activePreSessionOperation == expected"))
    }

    func testIOSLANControlMetadataCannotPromoteSelfReportedIdentity() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let handler = try sourceSlice(
            from: "private func handleAppMessage(",
            to: "private func hasStoredSessionMaterial(",
            in: source
        )
        let heartbeat = try sourceSlice(
            from: "case .heartbeat(let payload):",
            to: "case .authenticatedRouteBinding:",
            in: handler
        )
        let disconnecting = try sourceSlice(
            from: "case .peerDisconnecting(let payload):",
            to: "case .ping(let payload):",
            in: handler
        )

        XCTAssertTrue(heartbeat.contains("declaredDeviceId: nil"))
        XCTAssertFalse(heartbeat.contains("declaredDeviceId: payload.deviceId"))
        XCTAssertTrue(disconnecting.contains("declaredDeviceId: nil"))
        XCTAssertFalse(disconnecting.contains("declaredDeviceId: payload.deviceId"))
        XCTAssertTrue(disconnecting.contains("expectedReceipt.lease.connection.cancel()"))
    }

    func testIOSConcurrentHandshakeCannotReplaceCurrentGenerationOwner() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let begin = try sourceSlice(
            from: "private func beginHandshakeOperation(",
            to: "private func isCurrentHandshakeOperation(",
            in: source
        )
        let inboundHandshake = try sourceSlice(
            from: "private func ensureInboundHandshakeDriverIfNeeded(",
            to: "private func processHandshakeFrame(",
            in: source
        )
        let processInboundFrame = try sourceSlice(
            from: "private func processHandshakeFrame(",
            to: "private func ensureInboundRekeyDriverIfNeeded(",
            in: source
        )
        let inboundRekey = try sourceSlice(
            from: "private func ensureInboundRekeyDriverIfNeeded(",
            to: "private func isLikelyHandshakeControlPacket(",
            in: source
        )
        let terminalDetach = try sourceSlice(
            from: "private func detachHandshakeOperationIfOwned(",
            to: "private func isCurrentAuthenticatedConnection(",
            in: source
        )

        XCTAssertTrue(begin.contains("let existingOwner = handshakeOperationOwnerByPeerId[peerId]"))
        XCTAssertTrue(begin.contains("isCurrentHandshakeOperation(existingOwner)"))
        XCTAssertTrue(begin.contains("throw P2PError.handshakeAlreadyInProgress"))

        for driverFactory in [inboundHandshake, inboundRekey] {
            XCTAssertTrue(driverFactory.contains("var operationOwnershipTransferredToDriver = false"))
            XCTAssertTrue(driverFactory.contains("if !operationOwnershipTransferredToDriver"))
            let tokenPublication = try XCTUnwrap(
                driverFactory.range(of: "handshakeDriverOperationTokenByPeerId[peerId] = operationOwner.token")
            )
            let ownershipTransfer = try XCTUnwrap(
                driverFactory.range(
                    of: "operationOwnershipTransferredToDriver = true",
                    range: tokenPublication.upperBound..<driverFactory.endIndex
                )
            )
            XCTAssertLessThan(tokenPublication.lowerBound, ownershipTransfer.lowerBound)
        }

        let exactOwnerLookup = try XCTUnwrap(
            processInboundFrame.range(
                of: "let operationOwner = handshakeOperationOwnerByPeerId[peerId]"
            )
        )
        let postAwaitAuthorityGate = try XCTUnwrap(
            processInboundFrame.range(
                of: "operationOwner.completionAuthority.frameProcessorPostAwaitAction"
            )
        )
        let messageDelivery = try XCTUnwrap(
            processInboundFrame.range(of: "await activeDriver.handleMessage(frame, from: peer)")
        )
        let stateRead = try XCTUnwrap(
            processInboundFrame.range(of: "let state = await activeDriver.getCurrentState()")
        )
        let terminalSwitch = try XCTUnwrap(processInboundFrame.range(of: "switch state"))
        XCTAssertLessThan(exactOwnerLookup.lowerBound, messageDelivery.lowerBound)
        XCTAssertLessThan(messageDelivery.lowerBound, postAwaitAuthorityGate.lowerBound)
        XCTAssertLessThan(postAwaitAuthorityGate.lowerBound, stateRead.lowerBound)
        XCTAssertLessThan(stateRead.lowerBound, terminalSwitch.lowerBound)
        XCTAssertGreaterThanOrEqual(
            processInboundFrame.components(separatedBy: "frameProcessorPostAwaitAction").count - 1,
            2,
            "Both driver awaits must preserve the exact completion owner before further mutation."
        )
        XCTAssertFalse(
            processInboundFrame.contains("let operationOwner = HandshakeOperationOwner("),
            "The frame processor must preserve completion authority from the exact registry owner."
        )
        XCTAssertGreaterThanOrEqual(
            processInboundFrame.components(separatedBy: "isCurrentHandshakeOperation(operationOwner)").count - 1,
            2,
            "Every later inbound frame must retain the exact operation owner until terminal driver cleanup."
        )
        XCTAssertTrue(processInboundFrame.contains("finishHandshakeOperation(operationOwner)"))
        XCTAssertTrue(terminalDetach.contains("operationOwner.connectionGeneration == connectionGeneration"))
        XCTAssertTrue(terminalDetach.contains("operationOwner.token == $0"))
        XCTAssertTrue(terminalDetach.contains("finishHandshakeOperation(operationOwner)"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "detachHandshakeOperationIfOwned(").count - 1,
            11,
            "Every non-handshake terminal teardown must clear the driver and its exact operation owner together."
        )
    }

    func testIOSLANPairingFinalizesLocalJournalBeforeNetworkSubmission() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let commit = try sourceSlice(
            from: "private func commitAcceptedPairingIdentityExchange(",
            to: "public func sendPairingIdentityExchange(to deviceId: String)",
            in: source
        )
        let send = try sourceSlice(
            from: "private func sendPairingIdentityExchange(",
            to: "public func waitForPairingIdentityExchangeActivity(",
            in: source
        )
        let resolution = try sourceSlice(
            from: "public func resolvePairingTrustRequest(",
            to: "public func clearTrustMaterialForForgottenDevice(",
            in: source
        )

        let marker = try XCTUnwrap(
            commit.range(of: "PairingAcceptancePersistence.markReplyMayBeVisible(")
        )
        let completion = try XCTUnwrap(
            commit.range(of: "PairingAcceptancePersistence.completeAfterReplyMayBeVisible(")
        )
        XCTAssertLessThan(marker.lowerBound, completion.lowerBound)
        XCTAssertTrue(commit.contains("try await finalizeBeforeNetworkSubmission()"))

        let finalizationCallback = try XCTUnwrap(
            send.range(of: "try await beforeNetworkSubmit()")
        )
        let networkSubmission = try XCTUnwrap(
            send.range(of: "try await sendPairingIdentityData(")
        )
        XCTAssertLessThan(finalizationCallback.lowerBound, networkSubmission.lowerBound)

        XCTAssertTrue(resolution.contains("case .durableCommitRetained = acceptanceError"))
        XCTAssertTrue(resolution.contains("pendingDecisionWaiter?.continuation.resume(returning: decision)"))
        XCTAssertTrue(resolution.contains("配对身份已在本地持久化，但当前连接未完成"))
        XCTAssertTrue(resolution.contains("当前连接已中止且状态保持隔离"))
        XCTAssertFalse(resolution.contains("配对/信任决策未能持久化，当前请求已拒绝"))
    }

    func testIOSLANControlSendsAreBoundedAndCancellationSafe() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let support = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager+ConnectionSupport.swift"
        )
        let bootstrapSend = try sourceSlice(
            from: "private func sendFramedContentProcessed(",
            to: "private func receivePlainFrame(",
            in: source
        )
        let authenticatedSend = try sourceSlice(
            from: "private func send(\n        data: Data,",
            to: "private func receive(from connection: NWConnection)",
            in: source
        )

        XCTAssertTrue(bootstrapSend.contains("NetworkContentProcessedSubmission.send("))
        XCTAssertTrue(bootstrapSend.contains("Self.lanControlNetworkSubmitTimeoutSeconds"))
        XCTAssertTrue(bootstrapSend.contains("operation: \"bootstrap-control\""))
        XCTAssertFalse(bootstrapSend.contains("withCheckedThrowingContinuation"))

        XCTAssertTrue(authenticatedSend.contains("sendFramedContentProcessed("))
        XCTAssertTrue(authenticatedSend.contains("timeoutSeconds: timeoutSeconds"))
        XCTAssertTrue(authenticatedSend.contains("operation: operation"))
        XCTAssertFalse(authenticatedSend.contains("withCheckedThrowingContinuation"))

        for operation in [
            "authenticated-pong",
            "peer-disconnecting",
            "clipboard",
            "text-message",
            "heartbeat",
            "pairing-identity"
        ] {
            XCTAssertTrue(source.contains("operation: \"\(operation)\""), operation)
        }
        XCTAssertTrue(source.contains("Self.lanInteractiveNetworkSubmitTimeoutSeconds"))

        let submission = try sourceSlice(
            from: "enum NetworkContentProcessedSubmission {",
            to: "final class NetworkContentProcessedTaskOwner",
            in: support
        )
        let cancellationCheck = try XCTUnwrap(
            submission.range(of: "try Task.checkCancellation()")
        )
        let claim = try XCTUnwrap(
            submission.range(
                of: "guard gate.claimSubmission()",
                range: cancellationCheck.upperBound..<submission.endIndex
            )
        )
        let submit = try XCTUnwrap(
            submission.range(
                of: "submit { result in",
                range: claim.upperBound..<submission.endIndex
            )
        )
        let waitAfterSubmit = try XCTUnwrap(
            submission.range(
                of: "try await gate.wait(",
                range: submit.upperBound..<submission.endIndex
            )
        )
        XCTAssertLessThan(cancellationCheck.lowerBound, claim.lowerBound)
        XCTAssertLessThan(claim.lowerBound, submit.lowerBound)
        XCTAssertLessThan(submit.lowerBound, waitAfterSubmit.lowerBound)
        XCTAssertTrue(submission.contains("guard let submissionClaimed = gate.cancelSubmission()"))
        XCTAssertTrue(submission.contains("cancellation.run(cancel)"))
    }

    func testIOSMessagingPreservesCancellationAndNeverFakesClipboardSuccess() throws {
        let manager = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let messaging = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Messaging/DeviceMessagingService.swift"
        )
        let clipboardManager = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/ClipboardManager.swift"
        )
        let macClipboardService = try repositorySource(
            "Sources/SkyBridgeCore/Clipboard/ClipboardSyncService.swift"
        )
        let clipboard = try sourceSlice(
            from: "public func sendClipboard(",
            to: "public func sendTextMessage(",
            in: manager
        )
        let text = try sourceSlice(
            from: "public func sendTextMessage(",
            to: "public func broadcastClipboard(",
            in: manager
        )
        let broadcast = try sourceSlice(
            from: "public func broadcastClipboard(",
            to: "private func handleConnectionStateChange(",
            in: manager
        )
        let send = try sourceSlice(
            from: "public func send(\n        text rawText: String,\n        toDeviceId rawDeviceId: String,",
            to: "private func enqueueOfflineTextMessage(",
            in: messaging
        )
        let queuedDelivery = try sourceSlice(
            from: "private func deliverQueuedMessage(",
            to: "private func encodedQueuePayload(",
            in: messaging
        )

        XCTAssertTrue(clipboard.contains("throw P2PError.handshakeAlreadyInProgress"))
        XCTAssertFalse(clipboard.contains("if rekeyInProgress.contains(deviceId) { return }"))
        XCTAssertTrue(text.contains("catch is CancellationError"))
        XCTAssertTrue(text.contains("throw CancellationError()"))
        XCTAssertTrue(broadcast.contains("try Task.checkCancellation()"))
        XCTAssertTrue(broadcast.contains("catch is CancellationError"))
        XCTAssertTrue(broadcast.contains("throw CancellationError()"))
        XCTAssertTrue(broadcast.contains("throw P2PError.noAuthenticatedClipboardRecipients"))
        XCTAssertTrue(broadcast.contains("if let firstFailure"))
        XCTAssertTrue(clipboardManager.contains("async throws -> Void"))
        XCTAssertTrue(clipboardManager.contains("let submissionID = UUID()"))
        XCTAssertTrue(clipboardManager.contains("private struct LocalSubmissionLease"))
        XCTAssertTrue(clipboardManager.contains("activeLocalSubmission = LocalSubmissionLease("))
        XCTAssertTrue(clipboardManager.contains("guard localSubmissionIsCurrent("))
        XCTAssertTrue(clipboardManager.contains("activeLocalSubmission?.task.cancel()"))
        XCTAssertFalse(clipboardManager.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)"))
        XCTAssertTrue(macClipboardService.contains("private struct LocalSubmissionLease"))
        XCTAssertTrue(macClipboardService.contains("try requireActiveLocalSubmission("))
        XCTAssertTrue(macClipboardService.contains("pasteboard.changeCount == activeLocalSubmission.pasteboardChangeCount"))
        XCTAssertTrue(macClipboardService.contains("activeLocalSubmission?.task.cancel()"))

        let sendCancellation = try XCTUnwrap(send.range(of: "catch is CancellationError"))
        let sendQueueing = try XCTUnwrap(send.range(of: "catch P2PError.connectionFailed"))
        XCTAssertLessThan(sendCancellation.lowerBound, sendQueueing.lowerBound)
        XCTAssertTrue(queuedDelivery.contains("catch is CancellationError"))
        let queuedCancellation = try XCTUnwrap(
            queuedDelivery.range(of: "catch is CancellationError")
        )
        let queuedConnectionFailure = try XCTUnwrap(
            queuedDelivery.range(of: "catch P2PError.connectionFailed")
        )
        XCTAssertFalse(
            String(
                queuedDelivery[
                    queuedCancellation.lowerBound..<queuedConnectionFailure.lowerBound
                ]
            ).contains("markQueuedTextMessageFailed")
        )
    }

    func testBootstrapDropDiagnosticsNeverRenderAssociatedPayloads() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let handler = try sourceSlice(
            from: "private func handleAppMessage(\n        _ message: AppMessage,",
            to: "internal static func isBootstrapControlMessage(",
            in: source
        )
        let classifier = try sourceSlice(
            from: "private static func appMessageKindForDiagnostics(",
            to: "internal static func classifySessionAssurance(",
            in: source
        )

        XCTAssertTrue(handler.contains("Self.appMessageKindForDiagnostics(message)"))
        XCTAssertFalse(handler.contains("String(describing: message)"))
        XCTAssertTrue(classifier.contains("case .clipboard: \"clipboard\""))
        XCTAssertTrue(classifier.contains("case .textMessage: \"textMessage\""))
        XCTAssertTrue(classifier.contains("case .authenticatedRouteBinding: \"authenticatedRouteBinding\""))
        XCTAssertFalse(classifier.contains("payload"))
    }

    func testP2PFramingUsesSharedCompatibilityPolicyOnBothApplePlatforms() throws {
        let macConnection = try repositorySource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let framedReaderAdapter = try repositorySource("Sources/SkyBridgeCore/P2P/FramedReader.swift")
        let sharedFramedReader = try repositorySource(
            "Sources/SkyBridgeProtocolCore/P2P/FramedReader.swift"
        )
        let discoveryTransport = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DiscoveryTransport.swift"
        )
        let iosManager = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/P2PConnectionManager.swift"
        )
        let iosTransport = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Platform/PlatformAdapter.swift"
        )
        for source in [macConnection, discoveryTransport, iosManager, iosTransport] {
            XCTAssertTrue(source.contains("P2PControlFramePolicy.frame(body:"))
        }
        XCTAssertTrue(macConnection.contains("FramedReader.nwConnection("))
        XCTAssertTrue(macConnection.contains("reader.receiveFrame()"))
        XCTAssertTrue(
            framedReaderAdapter.contains(
                "public typealias FramedReader = SkyBridgeProtocolCore.FramedReader"
            )
        )
        XCTAssertTrue(framedReaderAdapter.contains("static func nwConnection("))
        XCTAssertTrue(sharedFramedReader.contains("P2PControlFramePolicy"))
        XCTAssertTrue(sharedFramedReader.contains(".inboundBodyByteCount(from: totalLen)"))
        XCTAssertTrue(sharedFramedReader.contains("if isComplete {"))
        XCTAssertTrue(discoveryTransport.contains("P2PControlFramePolicy.inboundBodyByteCount("))
        XCTAssertTrue(iosManager.contains("P2PControlFramePolicy.inboundBodyByteCount("))
        XCTAssertFalse(macConnection.contains("private let maxFrameBytes: UInt32 = 2_000_000"))
        XCTAssertFalse(iosManager.contains("bodyLen > 0, bodyLen <= 1_048_576"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        from startMarker: String,
        to endMarker: String,
        in source: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
