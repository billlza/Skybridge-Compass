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

    func testP2PControlAdvertiserUsesLANDirectListenerParameters() throws {
        let center = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")
        let p2p = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")

        XCTAssertTrue(center.contains("includePeerToPeer: Bool = true"))
        XCTAssertTrue(center.contains("parameters.includePeerToPeer = includePeerToPeer"))
        XCTAssertTrue(center.contains("peerToPeer=\\(includePeerToPeer"))
        XCTAssertTrue(center.contains("LocalNetworkAdvertisementAddressProvider.attachAddressTXT(to: &record)"))
        XCTAssertTrue(center.contains("record[\"skybridgePort\"] = portValue"))
        XCTAssertTrue(center.contains("record[\"controlPort\"] = portValue"))
        XCTAssertTrue(center.contains("record[\"controlPortSource\"] = \"listener\""))
        XCTAssertTrue(
            p2p.contains("includePeerToPeer: false"),
            "P2P control advertising must use LAN-routable listener parameters so direct host:port control probes do not silently fall back to Bonjour/AWDL."
        )
    }

    func testBonjourBrowserDoesNotPinDiscoveryToOtherInterface() throws {
        let source = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManagerOptimized.swift")
        let browser = try sourceSlice(
            from: "private func startSingleBrowser(serviceType:",
            to: "browser.stateUpdateHandler",
            in: source
        )

        XCTAssertTrue(browser.contains("parameters.includePeerToPeer = true"))
        XCTAssertFalse(
            browser.contains("requiredInterfaceType"),
            "Bonjour browsing must not be pinned to .other; that hides normal Wi-Fi/Ethernet/AWDL iPad advertisements."
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testP2PControlPortParsingIsServiceTypeAware() {
        let txt = [
            "port": "51241",
            "skybridgePort": "51242",
            "controlPort": "51243",
            "transferPort": "8080",
            "fileTransferPort": "8080",
            "remoteControlPort": "5901"
        ]

        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.advertisedServicePort(from: txt, serviceType: "_skybridge._tcp"),
            51241
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.advertisedServicePort(from: txt, serviceType: "_skybridge-transfer._tcp"),
            8080
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.advertisedServicePort(from: txt, serviceType: "_skybridge-remote._tcp"),
            5901
        )
    }

    @available(macOS 14.0, iOS 17.0, *)
    func testP2PBonjourPolicySanitizesInferredNamesWithoutWeakIdentityFallbackForStrongDevices() {
        var weakDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad [高速]",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: "recent:name:Bill's iPad [高速]"
        )

        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: weakDevice),
            ["Bill's iPad", "iPad"]
        )

        weakDevice.uniqueIdentifier = nil
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: weakDevice),
            ["iPad", "Bill's iPad"]
        )

        let strongDevice = DiscoveredDevice(
            id: UUID(),
            name: "Bill's iPad",
            ipv4: nil,
            ipv6: nil,
            services: ["_skybridge._tcp"],
            portMap: ["_skybridge._tcp": 9527],
            connectionTypes: [.wifi],
            uniqueIdentifier: nil,
            deviceId: "id:stable-ipad"
        )
        XCTAssertEqual(
            P2PDiscoveryBonjourPolicy.resolvedBonjourServiceNameCandidates(for: strongDevice),
            []
        )
    }

    func testP2PReconnectDiscoveryDoesNotInferWeakNameTargetsForStrongIdentity() throws {
        let source = try [
            readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift"),
            readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryBonjourPolicy.swift")
        ].joined(separator: "\n")

        XCTAssertTrue(
            source.contains("guard !hasStrongIdentity else {\n            return nil\n        }"),
            "Discovery refresh must not graft a supplied strong identity onto a same-name weak Bonjour snapshot."
        )
        XCTAssertTrue(
            source.contains("guard !hasStrongIdentity else {\n            return candidates\n        }"),
            "Strong-identity connection targets may use only a real Bonjour instance, not an inferred iPad/iPhone display name."
        )
        XCTAssertFalse(
            source.contains("let cleanExisting"),
            "Discovered device merge must not collapse records by display name; that can hide stale or wrong-identity Bonjour records."
        )
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

    func testInboundDiscoveryConnectionsDetachStateHandlers() throws {
        let sources = [
            try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift"),
            try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        ]

        for source in sources {
            let handleNewConnection = try sourceSlice(
                from: "private func handleNewConnection(_ connection: NWConnection)",
                to: "private func handleConnectionStateUpdate",
                in: source
            )
            XCTAssertTrue(
                handleNewConnection.contains("connection.stateUpdateHandler = { [weak self, weak connection] state in"),
                "Inbound NWConnection state handlers must not strongly capture the connection they are installed on."
            )
            XCTAssertTrue(
                handleNewConnection.contains("Task { @MainActor [weak self, weak connection] in"),
                "The MainActor hop must preserve weak connection ownership to avoid an indirect closure cycle."
            )

            let handleIncoming = try sourceSlice(
                from: "private func handleIncomingConnectionStateUpdate(_ state: NWConnection.State, connection: NWConnection)",
                to: source.contains("private func resolveInboundPeerIdentifier") ? "private func resolveInboundPeerIdentifier" : "// MARK: - Inbound control channel",
                in: source
            )
            XCTAssertEqual(
                handleIncoming.components(separatedBy: "connection.stateUpdateHandler = nil").count - 1,
                3,
                "Ready, failed, and cancelled inbound states must detach stateUpdateHandler before handoff or cancel."
            )
        }
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

    func testOnlineDeviceConnectFallbackRequiresRealSkyBridgeEndpoint() throws {
        let source = try readSource("Sources/SkyBridgeCompassApp/Services/OnlineDeviceConnectionCoordinator.swift")
        let connector = source

        XCTAssertTrue(
            source.contains("if let fallback = fallbackDiscoveredDevice(for: device)"),
            "Connect must not append a synthetic fallback candidate for stale recent or USB-only rows."
        )
        XCTAssertTrue(
            connector.contains("guard hasSkyBridgeControlService"),
            "Fallback candidates must be gated on an actual SkyBridge control service, port, or Bonjour identity."
        )
        XCTAssertTrue(
            connector.contains("return nil"),
            "Fallback creation should fail closed instead of guessing a generic iPhone/iPad Bonjour service name."
        )
        XCTAssertFalse(
            connector.contains("source: .skybridgeBonjour"),
            "The UI must not mark every fallback as SkyBridge Bonjour; that makes stale rows look connectable."
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
