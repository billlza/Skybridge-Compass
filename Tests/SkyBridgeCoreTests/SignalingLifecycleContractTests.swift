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
}
