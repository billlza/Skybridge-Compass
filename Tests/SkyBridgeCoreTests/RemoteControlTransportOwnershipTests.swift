#if os(macOS)
import Network
import XCTest
@testable import SkyBridgeCore

@MainActor
final class RemoteControlTransportOwnershipTests: XCTestCase {
    @MainActor
    private final class LocalEndpoint {
        let listener: NWListener
        let ready = XCTestExpectation(description: "Loopback listener ready")
        var connections: [NWConnection] = []

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.stateUpdateHandler = { [ready] state in
                if case .ready = state { ready.fulfill() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                }
            }
            listener.start(queue: .main)
        }

        func close() {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }

    func testEachControlSessionOwnsANewTransportWithoutReplacingDiscoveryConnection() async throws {
        let endpoint = try LocalEndpoint()
        defer { endpoint.close() }
        await fulfillment(of: [endpoint.ready], timeout: 3)
        let port = try XCTUnwrap(endpoint.listener.port)
        let device = makeDevice(port: Int(port.rawValue))
        let discovery = DeviceDiscoveryManagerOptimized()
        try await discovery.connectToDevice(device)
        let cached = try XCTUnwrap(discovery.activeConnection(for: device.id))
        defer { cached.cancel() }

        let first = try await discovery.makeRemoteControlConnection(to: device)
        var firstToClose: NWConnection? = first
        defer { firstToClose?.cancel() }
        let second = try await discovery.makeRemoteControlConnection(to: device)
        defer { second.cancel() }

        XCTAssertFalse(first === second)
        XCTAssertFalse(first === cached)
        XCTAssertFalse(second === cached)
        XCTAssertTrue(discovery.activeConnection(for: device.id) === cached)
        firstToClose = nil
        first.cancel()
        XCTAssertTrue(discovery.activeConnection(for: device.id) === cached)
        guard case .ready = second.state else { return XCTFail("Retiring one owned transport must preserve its sibling") }
    }

    func testCancelledControlDialReportsCancellationWithoutInstallingACachedConnection() async throws {
        let discovery = DeviceDiscoveryManagerOptimized()
        let device = makeDevice(port: 9)
        let attempt = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await discovery.makeRemoteControlConnection(to: device)
        }
        do {
            let unexpected = try await attempt.value
            unexpected.cancel()
            XCTFail("A cancelled dial must not return a transport")
        } catch {
            XCTAssertTrue(error is CancellationError, "Cancellation must retain its meaning: \(error)")
        }
        XCTAssertNil(discovery.activeConnection(for: device.id))
    }

    func testRemoteControlAdmissionRejectsLocalAndUnrelatedServiceEndpoints() async {
        let discovery = DeviceDiscoveryManagerOptimized()
        for device in [
            makeDevice(port: 9, local: true),
            makeDevice(port: 9, service: "_ssh._tcp"),
            makeDevice(port: 9, service: "_skybridge._tcp"),
            makeDevice(port: 9, service: "_skybridge._udp")
        ] {
            XCTAssertFalse(discovery.supportsRemoteControl(device))
            do {
                let unexpected = try await discovery.makeRemoteControlConnection(to: device)
                unexpected.cancel()
                XCTFail("Only remote SkyBridge control endpoints may be dialled")
            } catch {
                guard case DeviceDiscoveryError.deviceNotConnected = error else {
                    return XCTFail("Unexpected admission error: \(error)")
                }
            }
            XCTAssertNil(discovery.activeConnection(for: device.id))
        }
    }

    func testInvalidAdvertisedPortFailsWithoutIntegerConversionTrap() async {
        let discovery = DeviceDiscoveryManagerOptimized()
        for port in [0, -1, 65_536, Int.max] {
            let device = makeDevice(port: port)
            do {
                let unexpected = try await discovery.makeRemoteControlConnection(to: device)
                unexpected.cancel()
                XCTFail("Invalid advertised ports must not produce a connection")
            } catch {
                XCTAssertEqual(error as? NWError, .posix(.EINVAL))
            }
            XCTAssertNil(discovery.activeConnection(for: device.id))
        }
    }

    func testPrimaryServiceWithExplicitRemotePortUsesOnlyTheRemoteMediaEndpoint() async throws {
        let endpoint = try LocalEndpoint()
        defer { endpoint.close() }
        await fulfillment(of: [endpoint.ready], timeout: 3)
        let remotePort = try XCTUnwrap(endpoint.listener.port)
        let discovery = DeviceDiscoveryManagerOptimized()
        var device = makeDevice(port: 9, service: "_skybridge._tcp")
        device.portMap["_skybridge-rd._tcp"] = Int(remotePort.rawValue)
        XCTAssertTrue(discovery.supportsRemoteControl(device))
        let connection = try await discovery.makeRemoteControlConnection(to: device)
        defer { connection.cancel() }
        guard case .hostPort(_, let selectedPort) = connection.endpoint else {
            return XCTFail("A resolved remote media endpoint must retain its exact port")
        }
        XCTAssertEqual(selectedPort, remotePort)
    }

    func testUnresolvedRemoteServiceDoesNotBorrowAnUnrelatedPrimaryPort() async {
        let discovery = DeviceDiscoveryManagerOptimized()
        var device = makeDevice(port: 9, service: "_skybridge._tcp")
        device.services.append("_skybridge-rd._tcp")
        XCTAssertTrue(discovery.supportsRemoteControl(device))
        do {
            let unexpected = try await discovery.makeRemoteControlConnection(to: device)
            unexpected.cancel()
            XCTFail("A primary service port is not a remote-control port")
        } catch {
            XCTAssertEqual(error as? NWError, .posix(.EINVAL))
        }
    }

    private func makeDevice(port: Int, service: String = "_skybridge-rd._tcp", local: Bool = false) -> DiscoveredDevice {
        DiscoveredDevice(
            id: UUID(), name: "Loopback host", ipv4: "127.0.0.1", ipv6: nil,
            services: [service], portMap: [service: port], isLocalDevice: local,
            deviceId: "transport-ownership-test"
        )
    }
}
#endif
