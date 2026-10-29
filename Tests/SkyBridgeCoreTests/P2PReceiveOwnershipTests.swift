import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PReceiveOwnershipTests: XCTestCase {
    func testInboundRoutingPolicyCoversHandshakeSessionAndHandoffBoundaries() {
        typealias Phase = P2PInboundFrameRoutingPolicy.DriverPhase
        typealias Route = P2PInboundFrameRoutingPolicy.Route

        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: .established(sessionId: "classic"),
                publishedSessionId: "classic",
                isHandshakeControl: false
            ),
            Route.authenticated(expectedSessionId: "classic")
        )
        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: .established(sessionId: "classic"),
                publishedSessionId: nil,
                isHandshakeControl: false
            ),
            Route.awaitSessionHandoff(sessionId: "classic")
        )
        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: Phase.handshaking,
                publishedSessionId: "interim",
                isHandshakeControl: false
            ),
            Route.authenticated(expectedSessionId: "interim")
        )
        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: Phase.handshaking,
                publishedSessionId: nil,
                isHandshakeControl: false
            ),
            Route.rejectNoOwner
        )
        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: Phase.handshaking,
                publishedSessionId: nil,
                isHandshakeControl: true
            ),
            Route.handshakeDriver
        )
        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: Phase.absent,
                publishedSessionId: "active",
                isHandshakeControl: true
            ),
            Route.restartInboundRekey
        )
        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: Phase.absent,
                publishedSessionId: nil,
                isHandshakeControl: true
            ),
            Route.rejectNoOwner
        )
        XCTAssertEqual(
            P2PInboundFrameRoutingPolicy.route(
                driverPhase: .established(sessionId: "active"),
                publishedSessionId: "active",
                isHandshakeControl: true
            ),
            Route.rejectUnexpectedAuthenticatedHandshake
        )
    }

    func testReceiveActivationOccursAfterDriverInstallAndBeforeInitiation() throws {
        let source = try repositorySource("Sources/SkyBridgeCore/P2P/P2PModels.swift")
        let attempt = try sourceSlice(
            from: "private func performHandshakeAttempt(",
            to: "private func performPQCBootstrapRecoveryIfNeeded(",
            in: source
        )
        let install = try XCTUnwrap(attempt.range(of: "installHandshakeDriver("))
        let receive = try XCTUnwrap(
            attempt.range(
                of: "startReceivingIfNeeded(",
                range: install.upperBound..<attempt.endIndex
            )
        )
        let exactOwnerCheck = try XCTUnwrap(
            attempt.range(
                of: "requireCurrentHandshakeOperation(",
                range: receive.upperBound..<attempt.endIndex
            )
        )
        let initiate = try XCTUnwrap(
            attempt.range(
                of: "driver.initiateHandshake",
                range: exactOwnerCheck.upperBound..<attempt.endIndex
            )
        )

        XCTAssertLessThan(install.lowerBound, receive.lowerBound)
        XCTAssertLessThan(receive.lowerBound, exactOwnerCheck.lowerBound)
        XCTAssertLessThan(exactOwnerCheck.lowerBound, initiate.lowerBound)
    }

    func testTransportReadyPathsCannotStartReceiveBeforeHandshakeOwner() throws {
        let discovery = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"
        )
        let authentication = try sourceSlice(
            from: "private func authenticateConnection(",
            to: "private func makeP2PDeviceForConnection(",
            in: discovery
        )
        XCTAssertFalse(authentication.contains("startReceivingForHandshake()"))

        let network = try repositorySource(
            "Sources/SkyBridgeCore/P2P/P2PNetworkManager.swift"
        )
        let readiness = try sourceSlice(
            from: "private func waitUntilReady(",
            to: "private func startDiscoveryTimer(",
            in: network
        )
        XCTAssertTrue(readiness.contains("p2p?.markTransportReady()"))
        XCTAssertFalse(readiness.contains("markConnectedAndStartReceiving()"))
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
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
