import XCTest
import CFNetwork
import Network
@testable import SkyBridgeCore
@testable import SkyBridgeAppleTransport

@MainActor
final class SignalingLifecycleContractTests: XCTestCase {
    func testOlderGenerationOpenAndBoundCannotOverrideCurrentHandle() {
        let manager = CrossNetworkConnectionManager()
        let currentHandle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-A",
            backend: .urlSession,
            generation: 2
        )
        manager.testingSeedSignalingState(
            sessionID: "SESSION-A",
            generation: 2,
            handle: currentHandle,
            health: .healthy,
            phase: .connecting
        )

        manager.handleSignalingLifecycleEvent(.init(
            handleId: .init(sessionId: "SESSION-A", backend: .native, generation: 1),
            phase: .socketOpen
        ))
        XCTAssertEqual(manager.testingCurrentSignalingHandle(), currentHandle)
        XCTAssertEqual(manager.signalingLifecyclePhase, .connecting)

        manager.handleSignalingLifecycleEvent(.init(
            handleId: .init(sessionId: "SESSION-A", backend: .native, generation: 1),
            phase: .bound
        ))
        XCTAssertEqual(manager.testingCurrentSignalingHandle(), currentHandle)
        XCTAssertEqual(manager.signalingLifecyclePhase, .connecting)
        XCTAssertEqual(manager.signalingHealth, .healthy)
    }

    func testPostTransportFatalFailureBecomesDegradedFatalWithoutDroppingReadiness() {
        let manager = CrossNetworkConnectionManager()
        let currentHandle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-B",
            backend: .urlSession,
            generation: 4
        )
        manager.testingSeedSignalingState(
            sessionID: "SESSION-B",
            generation: 4,
            handle: currentHandle,
            health: .healthy,
            phase: .bound
        )
        manager.testingSetReadiness(.handshakeComplete(sessionId: "SESSION-B", negotiatedSuite: "X25519"))

        manager.handleSignalingLifecycleEvent(.init(
            handleId: currentHandle,
            phase: .failed,
            failureClass: .authBindRejected,
            errorDescription: "unauthorized"
        ))

        XCTAssertEqual(manager.signalingHealth, .degradedFatal)
        XCTAssertEqual(manager.readiness, .handshakeComplete(sessionId: "SESSION-B", negotiatedSuite: "X25519"))
        XCTAssertFalse(manager.testingCanPerformSignalingOperation(sessionID: "SESSION-B"))
    }

    func testTransportClientAllocatesDistinctHandleGenerationsPerAttempt() async {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-C",
            generation: 7
        )

        let first = await client.testOnlyReserveNextHandleId(for: .urlSession)
        let second = await client.testOnlyReserveNextHandleId(for: .urlSession)

        XCTAssertEqual(first.generation, 7)
        XCTAssertEqual(second.generation, 8)
        XCTAssertNotEqual(first, second)
    }

    func testAutoPolicyIncludesNativeProxyBypassAttempt() async {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-D",
            generation: 1,
            selectionPolicy: .auto,
            nativeFallbackEnabled: true
        )

        let labels = await client.testOnlyTransportAttemptLabels()

        #if os(macOS)
        XCTAssertEqual(labels, [
            "native",
            "urlsession",
            "native-proxy-bypass",
            "urlsession-proxy-bypass"
        ])
        #else
        XCTAssertEqual(labels, [
            "urlsession",
            "urlsession-proxy-bypass",
            "native",
            "native-proxy-bypass"
        ])
        #endif
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

    func testNoProxyConfigurationDisablesSystemProxyMechanisms() {
        let dictionary = WebSocketSignalingClient.testOnlyNoProxyConnectionProxyDictionary()

        XCTAssertEqual(dictionary[kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPEnable as String] as? Bool, false)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPSEnable as String] as? Bool, false)
        XCTAssertEqual(dictionary[kCFNetworkProxiesSOCKSEnable as String] as? Bool, false)
        XCTAssertEqual(dictionary[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Bool, false)
        XCTAssertEqual(dictionary[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? Bool, false)
    }

    func testDifferentTargetTransitionSupersedesSuspendedCandidateWithoutClearingReplacement() async throws {
        let manager = CrossNetworkConnectionManager()
        let barrier = SignalingConnectBarrier(suspendedTarget: "SESSION-Y")
        manager.testingInstallSignalingToken("token-y", for: "SESSION-Y")
        manager.testingInstallSignalingToken("token-z", for: "SESSION-Z")
        manager.testingConfigureSignalingTransitionOperations(
            connect: { _, target in try await barrier.connect(target: target) },
            close: { _, target in await barrier.recordClose(target: target) }
        )

        let first = Task { @MainActor in
            try await manager.testingEnsureSignalingConnected(shardKey: "SESSION-Y")
        }
        await barrier.waitUntilEntered(target: "SESSION-Y")
        let supersededWaiter = Task { @MainActor in
            try await manager.testingEnsureSignalingConnected(shardKey: "SESSION-Y")
        }
        for _ in 0..<100 where manager.testingSignalingTransitionWaiterCount() == 0 {
            await Task.yield()
        }
        XCTAssertEqual(manager.testingSignalingTransitionWaiterCount(), 1)

        let replacement = Task { @MainActor in
            try await manager.testingEnsureSignalingConnected(shardKey: "SESSION-Z")
        }
        try await replacement.value
        do {
            try await supersededWaiter.value
            XCTFail("superseded same-target waiter unexpectedly completed")
        } catch is CancellationError {
        }
        var installation = manager.testingSignalingInstallation()
        XCTAssertEqual(installation.sessionID, "SESSION-Z")
        XCTAssertNotNil(installation.client)

        await barrier.release(target: "SESSION-Y")
        do {
            try await first.value
            XCTFail("superseded transition unexpectedly completed")
        } catch is CancellationError {
        }

        installation = manager.testingSignalingInstallation()
        XCTAssertEqual(installation.sessionID, "SESSION-Z")
        XCTAssertNotNil(installation.client)
        let yConnectCount = await barrier.connectCount(target: "SESSION-Y")
        let zConnectCount = await barrier.connectCount(target: "SESSION-Z")
        let closedTargets = await barrier.closedTargets()
        XCTAssertEqual(yConnectCount, 1)
        XCTAssertEqual(zConnectCount, 1)
        XCTAssertTrue(
            closedTargets.allSatisfy { $0 == "SESSION-Y" },
            "a superseded continuation must never close the replacement candidate"
        )
    }

    func testSameTargetConcurrentEnsureWaitsForOneTransition() async throws {
        let manager = CrossNetworkConnectionManager()
        let barrier = SignalingConnectBarrier(suspendedTarget: "SESSION-Y")
        manager.testingInstallSignalingToken("token-y", for: "SESSION-Y")
        manager.testingConfigureSignalingTransitionOperations(
            connect: { _, target in try await barrier.connect(target: target) },
            close: { _, target in await barrier.recordClose(target: target) }
        )

        let leader = Task { @MainActor in
            try await manager.testingEnsureSignalingConnected(shardKey: "SESSION-Y")
        }
        await barrier.waitUntilEntered(target: "SESSION-Y")
        let waiter = Task { @MainActor in
            try await manager.testingEnsureSignalingConnected(shardKey: "SESSION-Y")
        }
        await Task.yield()
        var connectCount = await barrier.connectCount(target: "SESSION-Y")
        XCTAssertEqual(connectCount, 1)

        await barrier.release(target: "SESSION-Y")
        try await leader.value
        try await waiter.value
        connectCount = await barrier.connectCount(target: "SESSION-Y")
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(manager.testingSignalingInstallation().sessionID, "SESSION-Y")
    }

    func testCancelledSleepingRecoveryCannotReclaimOrDetachReplacement() async throws {
        let manager = CrossNetworkConnectionManager()
        let harness = SignalingRecoveryCancellationHarness(staleTarget: "SESSION-Y")
        manager.testingInstallSignalingToken("token-y", for: "SESSION-Y")
        manager.testingInstallSignalingToken("token-z", for: "SESSION-Z")
        manager.testingConfigureSignalingTransitionOperations(
            connect: { _, target in try await harness.connect(target: target) },
            close: { _, target in await harness.recordClose(target: target) }
        )
        manager.testingConfigureSignalingRecoverySleepOperation { target, attempt in
            try await harness.sleepBeforeRetry(target: target, attempt: attempt)
        }

        manager.testingScheduleSignalingRecovery(for: "SESSION-Y")
        await harness.waitUntilSleeping()
        let cancelledRecovery = try XCTUnwrap(
            manager.testingCancelSignalingRecovery(for: "SESSION-Y")
        )

        try await manager.testingEnsureSignalingConnected(shardKey: "SESSION-Z")
        XCTAssertEqual(manager.testingSignalingInstallation().sessionID, "SESSION-Z")

        await harness.releaseSleep()
        await cancelledRecovery.value

        let installation = manager.testingSignalingInstallation()
        XCTAssertEqual(installation.sessionID, "SESSION-Z")
        XCTAssertNotNil(installation.client)
        let yConnectCount = await harness.connectCount(target: "SESSION-Y")
        let zConnectCount = await harness.connectCount(target: "SESSION-Z")
        let closedTargets = await harness.closedTargets()
        XCTAssertEqual(yConnectCount, 1, "cancelled recovery must not retry or reclaim its old shard")
        XCTAssertEqual(zConnectCount, 1)
        XCTAssertFalse(
            closedTargets.contains("SESSION-Z"),
            "cancelled recovery must never detach or close the installed replacement"
        )
    }

    func testCloseSuspensionRejectsQueuedCallbacksAndCannotReviveRetiredHandle() async throws {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-CLOSE",
            generation: 1
        )
        let handle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-CLOSE",
            backend: .urlSession,
            generation: 1
        )
        let recorder = SignalingCallbackRecorder()
        let barrier = SignalingSuspensionBarrier()
        await client.setOnEnvelope { _, envelope in recorder.recordEnvelope(envelope.type) }
        await client.setOnServerFrame { _, frame in recorder.recordServerFrame(frame.type) }
        await client.setOnLifecycleEvent { event in recorder.recordLifecycle(event.phase) }
        await client.testOnlyInstallCurrentHandle(handle)

        let closing = Task {
            await client.testOnlyCloseDuringSuspendedCleanup {
                await barrier.suspend()
            }
        }
        await barrier.waitUntilSuspended()

        let offer = WebRTCSignalingEnvelope(
            sessionId: handle.sessionId,
            from: "peer",
            type: .offer,
            payload: .init(sdp: "stale")
        )
        await client.testOnlyHandleSocketOpen(handleId: handle)
        await client.testOnlyHandleText(
            handleId: handle,
            text: String(decoding: try JSONEncoder().encode(offer), as: UTF8.self)
        )
        await client.testOnlyHandleErrored(handleId: handle)
        await client.testOnlyHandleClosed(handleId: handle)

        XCTAssertEqual(recorder.envelopeTypes, [])
        XCTAssertEqual(recorder.serverFrameTypes, [])
        XCTAssertEqual(recorder.lifecyclePhases, [.closing])
        var currentHandle = await client.currentHandleID()
        var currentPhase = await client.currentLifecyclePhase()
        XCTAssertNil(currentHandle)
        XCTAssertEqual(currentPhase, .closing)

        await barrier.resume()
        await closing.value
        XCTAssertEqual(recorder.lifecyclePhases, [.closing, .closed])
        currentHandle = await client.currentHandleID()
        currentPhase = await client.currentLifecyclePhase()
        XCTAssertNil(currentHandle)
        XCTAssertEqual(currentPhase, .closed)
    }

    func testFailedBackendCallbacksCannotPolluteSecondHandleDelivery() async throws {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-FALLBACK",
            generation: 1
        )
        let first = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-FALLBACK",
            backend: .native,
            generation: 1
        )
        let second = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-FALLBACK",
            backend: .urlSession,
            generation: 2
        )
        let recorder = SignalingCallbackRecorder()
        await client.setOnEnvelope { _, envelope in recorder.recordEnvelope(envelope.type) }
        await client.setOnServerFrame { _, frame in recorder.recordServerFrame(frame.type) }
        await client.setOnLifecycleEvent { event in recorder.recordLifecycle(event.phase) }

        await client.testOnlyInstallCurrentHandle(first)
        await client.testOnlyHandleErrored(handleId: first)
        await client.testOnlyInstallCurrentHandle(second)

        let staleLeave = WebRTCSignalingEnvelope(
            sessionId: first.sessionId,
            from: "peer",
            type: .leave
        )
        await client.testOnlyHandleText(
            handleId: first,
            text: String(decoding: try JSONEncoder().encode(staleLeave), as: UTF8.self)
        )
        await client.testOnlyHandleClosed(handleId: first)
        await client.testOnlyHandleSocketOpen(handleId: second)
        await client.testOnlyHandleText(
            handleId: second,
            text: #"{"type":"bound","sessionId":"SESSION-FALLBACK"}"#
        )
        let offer = WebRTCSignalingEnvelope(
            sessionId: second.sessionId,
            from: "peer",
            type: .offer,
            payload: .init(sdp: "current")
        )
        await client.testOnlyHandleText(
            handleId: second,
            text: String(decoding: try JSONEncoder().encode(offer), as: UTF8.self)
        )

        XCTAssertEqual(recorder.envelopeTypes, [.offer])
        XCTAssertEqual(recorder.serverFrameTypes, ["bound"])
        let currentHandle = await client.currentHandleID()
        let currentPhase = await client.currentLifecyclePhase()
        XCTAssertEqual(currentHandle, second)
        XCTAssertEqual(currentPhase, .bound)
    }

    func testIOSManagerMirrorsTransitionAuthorityAndSendRevalidation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
            ),
            encoding: .utf8
        )
        let ensureStart = try XCTUnwrap(source.range(of: "private func ensureSignalingConnected("))
        let ensureEnd = try XCTUnwrap(
            source.range(
                of: "private func signalingGeneration(",
                range: ensureStart.upperBound..<source.endIndex
            )
        )
        let ensure = String(source[ensureStart.lowerBound..<ensureEnd.lowerBound])
        let claim = try XCTUnwrap(ensure.range(of: "signalingTransition = transition"))
        let firstAwait = try XCTUnwrap(ensure.range(of: "await detachedClient.close()"))
        XCTAssertLessThan(claim.lowerBound, firstAwait.lowerBound)
        XCTAssertTrue(ensure.contains("cancelSignalingTransition(supersededTransition)"))
        XCTAssertGreaterThanOrEqual(
            ensure.components(separatedBy: "try Task.checkCancellation()").count - 1,
            4
        )
        XCTAssertTrue(ensure.contains("try requireSignalingTransition(transition)"))
        XCTAssertTrue(ensure.contains("self.signaling === newSignaling"))
        XCTAssertTrue(ensure.contains("self.signalingShardKey == sessionId"))
        XCTAssertTrue(source.contains("try requireCurrentSignalingInstallation("))
        XCTAssertTrue(source.contains("private struct SignalingRecoveryTask"))
        XCTAssertTrue(source.contains("finishSignalingRecoveryTask(sessionID: sessionId, id: recoveryID)"))
        XCTAssertFalse(source.contains("try? await Task.sleep(for: .milliseconds(500 * (attempt + 1)))"))
    }

    func testSharedManagerSendContinuationRequiresExactClientAndShard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )
        let sendStart = try XCTUnwrap(source.range(of: "private func sendSignal("))
        let sendEnd = try XCTUnwrap(
            source.range(
                of: "private func handleSignalingServerFrame(",
                range: sendStart.upperBound..<source.endIndex
            )
        )
        let send = String(source[sendStart.lowerBound..<sendEnd.lowerBound])
        XCTAssertGreaterThanOrEqual(
            send.components(separatedBy: "requireCurrentSignalingInstallation(").count - 1,
            2
        )
        XCTAssertTrue(send.contains("signalingShardKey == authorizedEnvelope.sessionId"))
        XCTAssertTrue(send.contains("try await ensureSignalingConnected(shardKey: authorizedEnvelope.sessionId)"))
    }
}

private enum SignalingRecoveryHarnessError: Error {
    case injectedFirstAttemptFailure
}

private actor SignalingRecoveryCancellationHarness {
    private let staleTarget: String
    private var connects: [String: Int] = [:]
    private var closes: [String?] = []
    private var sleepEntered = false
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepContinuation: CheckedContinuation<Void, Never>?

    init(staleTarget: String) {
        self.staleTarget = staleTarget
    }

    func connect(target: String) async throws {
        connects[target, default: 0] += 1
        if target == staleTarget, connects[target] == 1 {
            throw SignalingRecoveryHarnessError.injectedFirstAttemptFailure
        }
    }

    func sleepBeforeRetry(target: String, attempt: Int) async throws {
        guard target == staleTarget, attempt == 1 else { return }
        sleepEntered = true
        let waiters = sleepWaiters
        sleepWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            sleepContinuation = continuation
        }
    }

    func waitUntilSleeping() async {
        if sleepEntered { return }
        await withCheckedContinuation { continuation in
            sleepWaiters.append(continuation)
        }
    }

    func releaseSleep() {
        sleepContinuation?.resume()
        sleepContinuation = nil
    }

    func recordClose(target: String?) {
        closes.append(target)
    }

    func connectCount(target: String) -> Int {
        connects[target, default: 0]
    }

    func closedTargets() -> [String?] {
        closes
    }
}

private actor SignalingConnectBarrier {
    private let suspendedTarget: String
    private var enteredTargets: [String: Int] = [:]
    private var enteredWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedTargets: Set<String> = []
    private var closes: [String?] = []

    init(suspendedTarget: String) {
        self.suspendedTarget = suspendedTarget
    }

    func connect(target: String) async throws {
        enteredTargets[target, default: 0] += 1
        let waiters = enteredWaiters.removeValue(forKey: target) ?? []
        for waiter in waiters { waiter.resume() }
        guard target == suspendedTarget, !releasedTargets.contains(target) else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[target, default: []].append(continuation)
        }
    }

    func waitUntilEntered(target: String) async {
        if enteredTargets[target, default: 0] > 0 { return }
        await withCheckedContinuation { continuation in
            enteredWaiters[target, default: []].append(continuation)
        }
    }

    func release(target: String) {
        releasedTargets.insert(target)
        let waiters = releaseWaiters.removeValue(forKey: target) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func connectCount(target: String) -> Int {
        enteredTargets[target, default: 0]
    }

    func recordClose(target: String?) {
        closes.append(target)
    }

    func closedTargets() -> [String?] {
        closes
    }
}

private actor SignalingSuspensionBarrier {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            resumeWaiter = continuation
        }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private final class SignalingCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEnvelopeTypes: [WebRTCSignalingEnvelope.MessageType] = []
    private var storedServerFrameTypes: [String] = []
    private var storedLifecyclePhases: [WebSocketSignalingClient.SignalingLifecyclePhase] = []

    var envelopeTypes: [WebRTCSignalingEnvelope.MessageType] {
        lock.withLock { storedEnvelopeTypes }
    }

    var serverFrameTypes: [String] {
        lock.withLock { storedServerFrameTypes }
    }

    var lifecyclePhases: [WebSocketSignalingClient.SignalingLifecyclePhase] {
        lock.withLock { storedLifecyclePhases }
    }

    func recordEnvelope(_ type: WebRTCSignalingEnvelope.MessageType) {
        lock.withLock { storedEnvelopeTypes.append(type) }
    }

    func recordServerFrame(_ type: String) {
        lock.withLock { storedServerFrameTypes.append(type) }
    }

    func recordLifecycle(_ phase: WebSocketSignalingClient.SignalingLifecyclePhase) {
        lock.withLock { storedLifecyclePhases.append(phase) }
    }
}
