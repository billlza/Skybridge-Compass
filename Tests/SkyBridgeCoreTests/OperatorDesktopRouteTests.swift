import XCTest
@testable import SkyBridgeCore

final class OperatorDesktopRouteTests: XCTestCase {
    private let deviceID = "00000000-0000-0000-0000-000000000002"
    private let fingerprint = String(repeating: "a", count: 64)

    private func device(platform: String = "macos", local: Bool = false) -> DiscoveredDevice {
        DiscoveredDevice(id: UUID(), name: "Paired computer", ipv4: nil, ipv6: "fe80::1%awdl0",
            platformName: platform, services: ["_skybridge._tcp"], portMap: ["_skybridge._tcp": 59101],
            uniqueIdentifier: "id:" + deviceID, routeIdentifiers: ["bonjour:paired@local."],
            isLocalDevice: local, deviceId: deviceID, pubKeyFP: fingerprint)
    }

    func testDirectRoutePreservesIdentityAndSelectsOnlyTheExplicitMediaPort() throws {
        let original = device()
        let endpoint = try OperatorDesktopEndpoint(host: "192.0.2.23", port: 59100)
        let target = try OperatorDesktopRoute.directTarget(original, endpoint: endpoint, trustedFingerprints: [fingerprint])
        XCTAssertEqual(target.id, original.id)
        XCTAssertEqual(target.deviceId, original.deviceId)
        XCTAssertEqual(target.pubKeyFP, original.pubKeyFP)
        XCTAssertEqual(target.ipv4, endpoint.host)
        XCTAssertNil(target.ipv6)
        XCTAssertEqual(target.portMap, ["_skybridge-rd._tcp": 59100])
        XCTAssertTrue(target.services.isEmpty, "A supplied route is not a fabricated Bonjour advertisement")
        XCTAssertTrue(target.routeIdentifiers.isEmpty)
        XCTAssertNil(original.ipv4)
        XCTAssertEqual(original.portMap, ["_skybridge._tcp": 59101])
    }

    func testUntrustedOrViewerOnlyOrLocalIdentityCannotCreateADirectTarget() throws {
        let endpoint = try OperatorDesktopEndpoint(host: "192.0.2.23", port: 59100)
        XCTAssertThrowsError(try OperatorDesktopRoute.directTarget(device(), endpoint: endpoint, trustedFingerprints: []))
        XCTAssertThrowsError(try OperatorDesktopRoute.directTarget(device(platform: "ios"), endpoint: endpoint, trustedFingerprints: [fingerprint]))
        XCTAssertThrowsError(try OperatorDesktopRoute.directTarget(device(local: true), endpoint: endpoint, trustedFingerprints: [fingerprint]))
        var mismatch = device(); mismatch.pubKeyFP = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try OperatorDesktopRoute.directTarget(mismatch, endpoint: endpoint, trustedFingerprints: [fingerprint]))
    }

    func testEndpointRejectsUnsafeAddressesAndOutOfRangePorts() {
        for host in ["0.0.0.0", "127.0.0.1", "224.0.0.1", "255.255.255.255", "paired.local", "192.0.2.23:59100"] {
            XCTAssertThrowsError(try OperatorDesktopEndpoint(host: host, port: 59100))
        }
        for port in [0, -1, 65536] { XCTAssertThrowsError(try OperatorDesktopEndpoint(host: "192.0.2.23", port: port)) }
    }

    func testDirectRequestRequiresItsDistinctMethodAndCompleteTypedEndpoint() throws {
        let id = UUID().uuidString
        let complete: CrossnetControlParams = .init(["device_ref": .string(id), "host": .string("192.0.2.23"), "port": .int(59100)])
        let direct = try OperatorDesktopRequest(action: .startAt, params: complete)
        XCTAssertEqual(direct.reference, id)
        XCTAssertEqual(direct.endpoint?.port, 59100)
        XCTAssertThrowsError(try OperatorDesktopRequest(action: .start, params: complete))
        XCTAssertThrowsError(try OperatorDesktopRequest(action: .startAt, params: .init(["device_ref": .string(id)])))
        XCTAssertThrowsError(try OperatorDesktopRequest(action: .startAt, params: .init(["device_ref": .string(id), "host": .string("192.0.2.23"), "port": .bool(true)])))
    }
}
