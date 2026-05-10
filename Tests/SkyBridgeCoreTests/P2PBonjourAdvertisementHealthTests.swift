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

    func testTrustedBonjourTXTResolverHasBoundedCallbackLifetime() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/Views/EnhancedDeviceDiscoveryView.swift")
        let resolver = try sourceSlice(
            from: "private final class BonjourTXTLookupResolver",
            to: "struct InfoBanner",
            in: source
        )

        XCTAssertTrue(
            resolver.contains("private let resumed = OSAllocatedUnfairLock(initialState: false)"),
            "NetService resolve callbacks and timeout callbacks must share a one-shot completion gate."
        )
        XCTAssertTrue(
            resolver.contains("service.delegate = nil"),
            "The resolver must detach the NetService delegate before releasing its self-retain."
        )
        XCTAssertTrue(
            resolver.contains("service.remove(from: .main, forMode: .common)"),
            "NetService should be removed from the run loop during completion cleanup."
        )
        XCTAssertTrue(
            resolver.contains("process.terminationHandler"),
            "dns-sd fallback should use terminationHandler instead of blocking a cooperative Swift task thread."
        )
        XCTAssertFalse(
            resolver.contains("process.waitUntilExit()"),
            "Blocking waitUntilExit can run Foundation run-loop callbacks on the cooperative worker and revive stale weak delegates."
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceSlice(from start: String, to end: String, in source: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
