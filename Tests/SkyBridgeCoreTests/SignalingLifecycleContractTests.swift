import XCTest
import CFNetwork
import Network
@testable import SkyBridgeCore
@testable import SkyBridgeAppleTransport

@MainActor
final class SignalingLifecycleContractTests: XCTestCase {
    func testSignalingSetupOwnerPreventsStaleFinishFromClearingReplacement() {
        let lifecycle = CrossNetworkSignalingLifecycleCoordinator()
        let first = lifecycle.beginSetup(for: "SESSION-A")
        XCTAssertNotNil(first)
        XCTAssertNil(lifecycle.beginSetup(for: "SESSION-B"))

        lifecycle.invalidateSetup()
        let replacement = lifecycle.beginSetup(for: "SESSION-B")
        XCTAssertNotNil(replacement)

        if let first {
            XCTAssertFalse(lifecycle.isCurrentSetup(first))
            lifecycle.finishSetup(first)
        }
        if let replacement {
            XCTAssertTrue(lifecycle.isCurrentSetup(replacement))
            lifecycle.finishSetup(replacement)
            XCTAssertFalse(lifecycle.isCurrentSetup(replacement))
        }
    }

    func testSessionTeardownInvalidatesOnlyItsSignalingSetupOwner() {
        let lifecycle = CrossNetworkSignalingLifecycleCoordinator()
        let owner = lifecycle.beginSetup(for: "SESSION-B")
        XCTAssertNotNil(owner)

        lifecycle.teardown(sessionID: "SESSION-A")
        if let owner {
            XCTAssertTrue(lifecycle.isCurrentSetup(owner))
        }

        lifecycle.teardown(sessionID: "SESSION-B")
        if let owner {
            XCTAssertFalse(lifecycle.isCurrentSetup(owner))
        }
    }

    func testFatalPreTransportLifecycleEventInvokesExactFailureCallback() {
        let sessionID = "SESSION-FATAL"
        let handle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: sessionID,
            backend: .urlSession,
            generation: 3
        )
        let lifecycle = CrossNetworkSignalingLifecycleCoordinator()
        lifecycle.seed(sessionID: sessionID, generation: 3, handle: handle)
        var failures: [(String, WebSocketSignalingClient.SignalingFailureClass)] = []

        lifecycle.handleLifecycleEvent(
            .init(
                handleId: handle,
                phase: .failed,
                failureClass: .protocolViolation,
                errorDescription: "malformed frame"
            ),
            activeShardKey: sessionID,
            isHandshakeComplete: { _ in false },
            setPhase: { _ in },
            setHealth: { _ in },
            noteDetached: { _, _, _, _ in },
            failPreTransport: { failures.append(($0, $1)) }
        )

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.0, sessionID)
        XCTAssertEqual(failures.first?.1, .protocolViolation)
    }

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
            "native-proxy-bypass",
            "urlsession-proxy-bypass",
            "native",
            "urlsession",
        ])
        #else
        XCTAssertEqual(labels, [
            "urlsession-proxy-bypass",
            "urlsession",
            "native-proxy-bypass",
            "native"
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

    func testDefaultSignalingBoundTimeoutAllowsColdCurrentPathStartup() {
        XCTAssertGreaterThanOrEqual(
            WebSocketSignalingClient.testOnlyDefaultConnectionTimeoutSeconds(),
            15
        )
    }

    func testBoundFrameMustMatchCurrentHandleSession() async {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-E",
            generation: 1
        )
        let handle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-E",
            backend: .urlSession,
            generation: 1
        )
        await client.testOnlySeedCurrentHandle(handle)

        await client.testOnlyHandleText(
            handleId: handle,
            text: #"{"type":"bound","sessionId":"SESSION-OTHER"}"#
        )

        let isBound = await client.testOnlyIsBound()
        let phase = await client.currentLifecyclePhase()
        let terminalErrorCount = await client.testOnlyTerminalErrorCount()
        XCTAssertFalse(isBound)
        XCTAssertEqual(phase, .failed)
        XCTAssertEqual(terminalErrorCount, 1)
    }

    func testMatchingBoundUnlocksOnlyMatchingEnvelope() async {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-F",
            generation: 3
        )
        let handle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-F",
            backend: .urlSession,
            generation: 3
        )
        let deliveries = SignalingDeliveryProbe()
        await client.setOnEnvelope { _ in deliveries.record() }
        await client.testOnlySeedCurrentHandle(handle)
        await client.testOnlyHandleText(
            handleId: handle,
            text: #"{"type":"bound","sessionId":"session-f"}"#
        )
        let boundAfterMatchingFrame = await client.testOnlyIsBound()
        XCTAssertTrue(boundAfterMatchingFrame)

        await client.testOnlyHandleText(
            handleId: handle,
            text: #"{"sessionId":"SESSION-OTHER","from":"peer","type":"offer","payload":{"sdp":"v=0"}}"#
        )

        let boundAfterMismatch = await client.testOnlyIsBound()
        let phase = await client.currentLifecyclePhase()
        XCTAssertFalse(boundAfterMismatch)
        XCTAssertEqual(phase, .failed)
        XCTAssertEqual(deliveries.count, 0)
    }

    func testBackToBackOfferAndICEAwaitEachInboundHandlerInOrder() async throws {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-ORDER",
            generation: 9
        )
        let handle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-ORDER",
            backend: .native,
            generation: 9
        )
        let probe = OrderedSignalingDeliveryProbe()
        await client.setOnEnvelope { envelope in
            await probe.receive(envelope.type)
        }
        await client.testOnlySeedCurrentHandle(handle)
        await client.testOnlyHandleText(
            handleId: handle,
            text: #"{"type":"bound","sessionId":"SESSION-ORDER"}"#
        )
        let offer = WebRTCSignalingEnvelope(
            sessionId: "SESSION-ORDER",
            from: "peer-a",
            type: .offer,
            payload: .init(sdp: "v=0")
        )
        let ice = WebRTCSignalingEnvelope(
            sessionId: "SESSION-ORDER",
            from: "peer-a",
            type: .iceCandidate,
            payload: .init(
                candidate: "candidate:1 1 udp 1 127.0.0.1 9 typ host",
                sdpMid: "0",
                sdpMLineIndex: 0
            )
        )

        await client.testOnlyHandleText(
            handleId: handle,
            text: try encodedEnvelope(offer)
        )
        await client.testOnlyHandleText(
            handleId: handle,
            text: try encodedEnvelope(ice)
        )

        let events = await probe.snapshot()
        XCTAssertEqual(
            events,
            ["start:offer", "finish:offer", "start:iceCandidate", "finish:iceCandidate"]
        )
    }

    func testNativeInboundCallbacksRemainAwaitedBeforeNextReceive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let native = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeAppleTransport/Connection/NativeWebSocketClient.swift"
            ),
            encoding: .utf8
        )
        let signaling = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeAppleTransport/RemoteConnection/WebRTC/WebSocketSignalingClient.swift"
            ),
            encoding: .utf8
        )
        let manager = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(native.contains("public var onText: (@Sendable (String) async -> Void)?"))
        XCTAssertTrue(native.contains("await callbacks.onText?(text)"))
        XCTAssertTrue(native.contains("await callbacks.onBinary?(data)"))
        let textDelivery = try XCTUnwrap(native.range(of: "await callbacks.onText?(text)"))
        let nextReceive = try XCTUnwrap(native.range(
            of: "continueReceiveIfNeeded(on: conn, generation: generation)",
            range: textDelivery.upperBound..<native.endIndex
        ))
        XCTAssertLessThan(textDelivery.lowerBound, nextReceive.lowerBound)
        XCTAssertTrue(signaling.contains(
            "public var onEnvelope: (@Sendable (WebRTCSignalingEnvelope) async -> Void)?"
        ))
        XCTAssertTrue(signaling.contains("await onEnvelope?(env)"))
        XCTAssertTrue(manager.contains(
            "await client.setOnEnvelope { [weak self, weak client] env in"
        ))
        XCTAssertTrue(manager.contains(
            "await self?.handleSignalingEnvelope(env, sourceClient: client)"
        ))
    }

    func testOversizedSignalingMessageFailsClosed() async {
        let client = WebSocketSignalingClient(
            url: URL(string: "wss://signal.example.com/ws")!,
            sessionId: "SESSION-G",
            generation: 5
        )
        let handle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-G",
            backend: .urlSession,
            generation: 5
        )
        await client.testOnlySeedCurrentHandle(handle)

        await client.testOnlyHandleText(
            handleId: handle,
            text: String(repeating: "x", count: (64 * 1024) + 1)
        )

        let phase = await client.currentLifecyclePhase()
        XCTAssertEqual(phase, .failed)
    }

    private func encodedEnvelope(_ envelope: WebRTCSignalingEnvelope) throws -> String {
        let data = try JSONEncoder().encode(envelope)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func testIOSSignalingSourceCarriesSameSessionAndSizeGuards() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebSocketSignalingClient.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("maximumInboundTextBytes = 64 * 1024"))
        XCTAssertTrue(source.contains("sessionIDsMatch(env.sessionId, handleId.sessionId)"))
        XCTAssertTrue(source.contains("bound_session_mismatch"))
        XCTAssertTrue(source.contains("terminalErrorsByHandle.removeAll(keepingCapacity: true)"))
    }

    func testSignalingLifecycleStateLivesInCoordinator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let coordinatorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkSignalingLifecycleCoordinator.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(managerSource.contains("signalingGenerationBySessionId"))
        XCTAssertFalse(managerSource.contains("activeSignalingHandle"))
        XCTAssertFalse(managerSource.contains("signalingRecoveryTasksBySessionId"))
        XCTAssertTrue(managerSource.contains("private let signalingLifecycle = CrossNetworkSignalingLifecycleCoordinator()"))
        XCTAssertTrue(coordinatorSource.contains("private var generationBySessionId: [String: Int]"))
        XCTAssertTrue(coordinatorSource.contains("private var activeHandle: HandleID?"))
        XCTAssertTrue(coordinatorSource.contains("private var recoveryTasksBySessionId: [String: Task<Void, Never>]"))
    }

    func testCancelledRecoveryBackoffDoesNotReconnectOrMutateHealth() async throws {
        enum ProbeError: Error { case failed }

        let coordinator = CrossNetworkSignalingLifecycleCoordinator()
        var attempts = 0
        var healthMutations: [SignalingSessionHealth] = []
        coordinator.scheduleRecovery(
            for: "SESSION-CANCEL",
            tokenExpired: false,
            maxAttempts: 2,
            reconnectDelayMilliseconds: { _ in 500 },
            currentShardKey: { "SESSION-CANCEL" },
            isHandshakeComplete: { _ in false },
            ensureConnected: { _ in
                attempts += 1
                throw ProbeError.failed
            },
            setHealth: { healthMutations.append($0) },
            logCancellation: { _, _ in },
            logFailure: { _, _, _ in }
        )

        for _ in 0..<1_000 {
            if attempts == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(attempts, 1)

        coordinator.cancelRecovery(for: "SESSION-CANCEL")
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(healthMutations.isEmpty)
    }

    func testSessionTeardownRemovesGenerationHandleAndRecoveryTogether() async throws {
        enum ProbeError: Error { case failed }

        let sessionID = "SESSION-TEARDOWN"
        let handle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: sessionID,
            backend: .urlSession,
            generation: 7
        )
        let coordinator = CrossNetworkSignalingLifecycleCoordinator()
        coordinator.seed(sessionID: sessionID, generation: 7, handle: handle)

        var attempts = 0
        coordinator.scheduleRecovery(
            for: sessionID,
            tokenExpired: false,
            maxAttempts: 2,
            reconnectDelayMilliseconds: { _ in 500 },
            currentShardKey: { sessionID },
            isHandshakeComplete: { _ in false },
            ensureConnected: { _ in
                attempts += 1
                throw ProbeError.failed
            },
            setHealth: { _ in },
            logCancellation: { _, _ in },
            logFailure: { _, _, _ in }
        )

        for _ in 0..<1_000 {
            if attempts == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(attempts, 1)

        coordinator.teardown(sessionID: sessionID)
        XCTAssertNil(coordinator.currentHandle())
        XCTAssertEqual(coordinator.generation(for: sessionID), 0)
        XCTAssertEqual(coordinator.nextGeneration(for: sessionID), 1)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(attempts, 1)
    }

    func testRealSessionCleanupUsesFullSignalingTeardownAndClearsPreSessionQueue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(managerSource.contains("signalingLifecycle.teardown(sessionID: sessionID)"))
        XCTAssertTrue(managerSource.contains("pendingPreSessionSignalingEnvelopesBySessionId.removeValue(forKey: sessionID)"))
        XCTAssertTrue(managerSource.contains("pendingPreSessionSignalingEnvelopesBySessionId.removeAll()"))
    }
}

private final class SignalingDeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveryCount = 0

    func record() {
        lock.lock()
        deliveryCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveryCount
    }
}

private actor OrderedSignalingDeliveryProbe {
    private var events: [String] = []

    func receive(_ type: WebRTCSignalingEnvelope.MessageType) async {
        events.append("start:\(type.rawValue)")
        for _ in 0..<8 {
            await Task.yield()
        }
        events.append("finish:\(type.rawValue)")
    }

    func snapshot() -> [String] {
        events
    }
}
