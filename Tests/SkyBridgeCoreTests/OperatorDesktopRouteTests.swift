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

    private func session(capabilities: [String], identity: String? = nil, authority: String? = nil,
                         age: TimeInterval = 0, now: Date) -> ClassicTransferSessionSnapshot {
        ClassicTransferSessionSnapshot(sessionId: UUID().uuidString, matchDeviceId: "route-alias",
            resolvedPeerDeviceId: identity ?? "id:" + deviceID, aliases: [deviceID], endpointHostOrIP: "192.0.2.23",
            capabilities: capabilities,
            sessionKeys: SessionKeys(sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32),
                negotiatedSuite: .qperiaptABI2PolicyBound, role: .initiator, transcriptHash: Data(repeating: 3, count: 32)),
            peerAuthority: authority.map { .init(protocolSigningAlgorithm: .mlDSA65, protocolPublicKeyFingerprint: $0) },
            lastSeenAt: now.addingTimeInterval(-age))
    }

    func testCurrentControlConnectionSuppliesPortAndNewerMetadataRetiresOldPort() {
        let now = Date()
        let old = session(capabilities: ["remoteControlPort=61609"], authority: fingerprint, age: 20, now: now)
        let current = session(capabilities: ["remoteControlPort=58503"], authority: fingerprint, now: now)
        XCTAssertEqual(OperatorDesktopRoute.authenticatedRemoteControlPort(for: device(), sessions: [old, current],
            trustedFingerprints: [fingerprint], now: now), 58503)
        let retired = session(capabilities: [], authority: fingerprint, now: now)
        XCTAssertNil(OperatorDesktopRoute.authenticatedRemoteControlPort(for: device(), sessions: [old, retired],
            trustedFingerprints: [fingerprint], now: now))
    }

    func testPortRequiresCurrentPinExactIdentityAndAuthenticatedAuthority() {
        let now = Date()
        let bound = session(capabilities: ["remoteControlPort=58503"], authority: fingerprint, now: now)
        XCTAssertNil(OperatorDesktopRoute.authenticatedRemoteControlPort(for: device(), sessions: [bound],
            trustedFingerprints: [], now: now))
        for candidate in [
            session(capabilities: ["remoteControlPort=58503"], now: now),
            session(capabilities: ["remoteControlPort=58503"], authority: String(repeating: "b", count: 64), now: now),
            session(capabilities: ["remoteControlPort=58503"], identity: UUID().uuidString, authority: fingerprint, now: now),
            session(capabilities: ["remoteControlPort=58503"], identity: "host:192.0.2.23", authority: fingerprint, now: now)
        ] {
            XCTAssertNil(OperatorDesktopRoute.authenticatedRemoteControlPort(for: device(), sessions: [candidate],
                trustedFingerprints: [fingerprint], now: now))
        }
        XCTAssertNil(OperatorDesktopRoute.authenticatedRemoteControlPort(for: device(platform: "ios"), sessions: [bound],
            trustedFingerprints: [fingerprint], now: now))
        XCTAssertNil(OperatorDesktopRoute.authenticatedRemoteControlPort(for: device(local: true), sessions: [bound],
            trustedFingerprints: [fingerprint], now: now))
    }

    func testExpiredAndFutureDatedSessionsCannotSupplyPorts() {
        let now = Date()
        for age in [ClassicTransferSessionRegistry.sessionSnapshotTimeToLive + 0.01, -1] {
            let stale = session(capabilities: ["remoteControlPort=58503"], authority: fingerprint, age: age, now: now)
            XCTAssertNil(OperatorDesktopRoute.authenticatedRemoteControlPort(for: device(), sessions: [stale],
                trustedFingerprints: [fingerprint], now: now))
        }
    }

    func testRemotePortParserRejectsConflictingOrInvalidHints() {
        for hints in [[], ["remoteControlPort=0"], ["remoteControlPort=65536"],
            ["remoteControlPort=58503", "remote_control_port=58509"],
            ["remoteControlPort=58503", "remoteControlPort=broken"]] {
            XCTAssertNil(ClassicTransferPeerResolutionPolicy.advertisedRemoteControlPort(in: hints))
        }
        XCTAssertEqual(ClassicTransferPeerResolutionPolicy.advertisedRemoteControlPort(
            in: ["fileTransferPort=8080", "remote-control-port=58503", "remoteControlPort=58503"]), 58503)
        XCTAssertEqual(ClassicTransferPeerResolutionPolicy.advertisedClassicTransferPort(
            in: ["fileTransferPort=broken", "fileTransferPort=8080", "fileTransferPort=8081"]), 8080)
    }
}
