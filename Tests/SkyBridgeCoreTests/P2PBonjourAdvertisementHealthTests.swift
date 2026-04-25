import XCTest
@testable import SkyBridgeCore

final class P2PBonjourAdvertisementHealthTests: XCTestCase {
    func testAdvertisementSnapshotRequiresReadyListenerAndPort() {
        let absent = ServiceAdvertisementSnapshot(serviceType: "_skybridge._tcp")
        XCTAssertFalse(absent.isAdvertising)
        XCTAssertFalse(absent.isConnectable)

        let starting = ServiceAdvertisementSnapshot(
            serviceType: "_skybridge._tcp",
            owner: "P2PDiscoveryService",
            port: nil,
            state: .starting
        )
        XCTAssertTrue(starting.isAdvertising)
        XCTAssertTrue(starting.isStarting)
        XCTAssertFalse(starting.isConnectable)

        let readyWithoutPort = ServiceAdvertisementSnapshot(
            serviceType: "_skybridge._tcp",
            owner: "P2PDiscoveryService",
            port: nil,
            state: .ready
        )
        XCTAssertFalse(readyWithoutPort.isConnectable)

        let ready = ServiceAdvertisementSnapshot(
            serviceType: "_skybridge._tcp",
            owner: "P2PDiscoveryService",
            port: 56432,
            state: .ready
        )
        XCTAssertTrue(ready.isConnectable)
        XCTAssertTrue(ready.isOwned(by: "P2PDiscoveryService"))
    }

    func testServiceAdvertiserCenterTracksOwnerAndInvalidatesDeadListeners() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")

        XCTAssertTrue(source.contains("public struct ServiceAdvertisementSnapshot"))
        XCTAssertTrue(source.contains("owner: String? = nil"))
        XCTAssertTrue(source.contains("public func advertisementSnapshot(for serviceType: String)"))
        XCTAssertTrue(source.contains("private func handleListenerStateUpdate("))
        XCTAssertTrue(source.contains("case .failed, .cancelled:"))
        XCTAssertTrue(
            source.contains("records.removeValue(forKey: serviceType)"),
            "Failed or cancelled listeners must be removed so Bonjour visibility is not mistaken for a live TCP listener."
        )

        let recordWrite = try XCTUnwrap(source.range(of: "records[serviceType] = ListenerRecord("))
        let listenerStart = try XCTUnwrap(source.range(of: "listener.start(queue:"))
        XCTAssertLessThan(
            recordWrite.lowerBound,
            listenerStart.lowerBound,
            "The center must register the listener before start() so early ready/failed callbacks cannot be lost."
        )
    }

    func testP2PAdvertisingUsesCentralHealthSnapshot() throws {
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let localServices = try readSource("Sources/SkyBridgeCompassApp/LocalPeerServiceCoordinator.swift")

        XCTAssertTrue(p2p.contains("private static let controlAdvertisementOwner = \"P2PDiscoveryService\""))
        XCTAssertTrue(p2p.contains("advertisementSnapshot(for: Self.controlServiceType)"))
        XCTAssertTrue(p2p.contains("ensureAdvertisingHealthy()"))
        XCTAssertTrue(p2p.contains("owner: Self.controlAdvertisementOwner"))
        XCTAssertTrue(localServices.contains("await p2pDiscoveryService.ensureAdvertisingHealthy()"))
    }

    func testLegacyDiscoveryManagersCannotStopP2POwnedSkybridgeAdvertiser() throws {
        let manager = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift")
        let optimized = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")

        XCTAssertFalse(manager.contains("ServiceAdvertiserCenter.shared.stopAdvertising(\"_skybridge._tcp\")"))
        XCTAssertFalse(optimized.contains("ServiceAdvertiserCenter.shared.stopAdvertising(\"_skybridge._tcp\")"))
        XCTAssertFalse(p2p.contains("ServiceAdvertiserCenter.shared.stopAdvertising(\"_skybridge._tcp\")"))

        XCTAssertTrue(manager.contains("owner: advertisementOwner"))
        XCTAssertTrue(optimized.contains("owner: Self.advertisementOwner"))
        XCTAssertTrue(manager.contains("owner: advertisementOwner\n            )"))
        XCTAssertTrue(optimized.contains("owner: Self.advertisementOwner\n            )"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
