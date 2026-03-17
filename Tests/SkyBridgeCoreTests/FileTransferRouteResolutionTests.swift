import XCTest
@testable import SkyBridgeCore

@MainActor
final class FileTransferRouteResolutionTests: XCTestCase {
    func testResolveActivePeerRoutesPrefersPublishedPresenceRouteDescriptor() async throws {
        let manager = FileTransferManager()
        let peerId = "route-priority-\(UUID().uuidString)"
        defer { ConnectionPresenceService.shared.markDisconnected(peerId: peerId) }

        ConnectionPresenceService.shared.markConnected(
            peerId: peerId,
            displayName: "Compatibility Peer",
            address: "10.0.0.9",
            cryptoKind: "Classic",
            suite: "X25519"
        )

        let preferredRoute = ConnectionPresenceService.PresenceRouteDescriptor(
            peerId: peerId,
            deviceName: "Precise Peer",
            displayAddress: "10.0.0.9",
            transferAddress: "10.0.0.42",
            transferPort: 9443,
            routeSource: .inbound
        )
        _ = ConnectionPresenceService.shared.publishConnectedAtomically(
            peerId: peerId,
            displayName: "Precise Peer",
            address: "10.0.0.9",
            cryptoKind: "Classic",
            suite: "X25519",
            routeDescriptor: preferredRoute
        )

        let routes = await manager.resolveActivePeerRoutes()
        let selected = try XCTUnwrap(routes.first(where: { $0.deviceId == peerId }))

        XCTAssertEqual(selected.ipAddress, "10.0.0.42")
        XCTAssertEqual(selected.port, 9443)
        XCTAssertEqual(selected.routeSource, "presence:inbound")
    }
}
