import Foundation
import Network
@testable import SkyBridgeCore
import XCTest

@MainActor
final class P2PControlDevicePresentationTests: XCTestCase {
    private func target(_ peer: String, id: UUID = UUID(), cable: Bool = false) -> DiscoveredDevice {
        .init(id: id, name: "Shared device name", ipv4: cable ? nil : "192.0.2.14", ipv6: nil,
              platformName: "ipados", services: ["_skybridge._tcp"], portMap: [:],
              connectionTypes: cable ? [.usb] : [.wifi], uniqueIdentifier: cable ? "usb:test-cable" : nil,
              deviceId: peer)
    }

    private func ownedConnection(_ peer: String) -> P2PConnection {
        let device = P2PDevice(id: peer, name: "Shared device name", type: .iOS, address: "192.0.2.14",
            port: 1, osVersion: "test", capabilities: [], publicKey: Data(), lastSeen: Date())
        // Presentation-only fixture: never starts a carrier or creates trust.
        let connection = P2PConnection(device: device, connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp))
        connection.testingSetStatus(.authenticated)
        return connection
    }

    func testSeveralDiscoveryRecordsForOneOwnerRetainTheCableRepresentative() async {
        let peer = UUID().uuidString
        let owner = ownedConnection(peer)
        let service = P2PDiscoveryService()
        service.testingReplaceAuthenticatedConnections([peer: owner])
        let cable = target(peer, cable: true), first = target(peer), refreshed = target(peer)
        XCTAssertEqual(service.uniqueControlDeviceCandidates([cable, first, refreshed]).map(\.id), [cable.id])
        await owner.disconnectAndWait()
    }

    func testDifferentOwnersWithTheSameNameAndAddressRemainSelectable() async {
        let firstID = UUID().uuidString, secondID = UUID().uuidString
        let first = ownedConnection(firstID), second = ownedConnection(secondID)
        let service = P2PDiscoveryService()
        service.testingReplaceAuthenticatedConnections([firstID: first, secondID: second])
        let targets = [target(firstID), target(secondID)]
        XCTAssertEqual(service.uniqueControlDeviceCandidates(targets).map(\.id), targets.map(\.id))
        await first.disconnectAndWait(); await second.disconnectAndWait()
    }

    func testUnauthenticatedClaimsDoNotBorrowAnOwnersDeduplicationAuthority() async {
        let peer = UUID().uuidString
        let owner = ownedConnection(peer)
        owner.testingSetStatus(.authenticating)
        let service = P2PDiscoveryService()
        service.testingReplaceAuthenticatedConnections([peer: owner])
        let first = target(peer), second = target(peer)
        XCTAssertEqual(service.uniqueControlDeviceCandidates([first, first, second]).map(\.id), [first.id, second.id])
        await owner.disconnectAndWait()
    }
}
