import XCTest
@testable import SkyBridgeProtocolCore

/// 锁定 `/api/devices/list` 与 `/api/presence/register` 的 JSON 契约：epoch 毫秒整数、可缺省字段、未知平台不报错。
final class AccountDeviceRecordDecodingTests: XCTestCase {
    private static let listResponse = """
    {
      "generatedAt": 1757073600123,
      "callerDeviceId": "caller-device",
      "truncated": true,
      "devices": [
        {
          "deviceId": "caller-device",
          "deviceName": "Studio Mac",
          "status": "active",
          "protocolSigningAlgorithm": "Ed25519",
          "protocolPublicKeyFingerprint": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "platform": "macos",
          "deviceModel": "Mac16,7",
          "osVersion": "26.6.0",
          "appVersion": "1.0.2",
          "lanAddresses": ["10.0.0.5", "fd12::1"],
          "publicAddress": "203.0.113.9",
          "capabilities": ["clipboard", "remote_desktop"],
          "registeredAt": 1756720800000,
          "lastSeenAt": 1757073590000,
          "presenceUpdatedAt": 1757073590000,
          "online": true,
          "isCaller": true
        },
        {
          "deviceId": "legacy-row",
          "deviceName": null,
          "status": "pending",
          "protocolSigningAlgorithm": "ML-DSA-65",
          "protocolPublicKeyFingerprint": "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
          "platform": "visionos",
          "lastSeenAt": null,
          "online": false
        }
      ]
    }
    """

    func testDecodesServerListResponseExactly() throws {
        let snapshot = try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: Data(Self.listResponse.utf8))
        XCTAssertEqual(snapshot.callerDeviceId, "caller-device")
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.generatedAt.timeIntervalSince1970, 1_757_073_600.123, accuracy: 0.001)
        XCTAssertEqual(snapshot.onlineDeviceIds, ["caller-device"])
        XCTAssertEqual(snapshot.devices.count, 2)

        let caller = try XCTUnwrap(snapshot.devices.first)
        XCTAssertTrue(caller.isCaller)
        XCTAssertEqual(caller.platform, .macOS)
        XCTAssertEqual(caller.lanAddresses, ["10.0.0.5", "fd12::1"])
        XCTAssertEqual(caller.publicAddress, "203.0.113.9")
        XCTAssertEqual(caller.knownCapabilities, [.clipboard, .remoteDesktop])
        XCTAssertEqual(try XCTUnwrap(caller.lastSeenAt).timeIntervalSince1970, 1_757_073_590, accuracy: 0.001)
        XCTAssertEqual(caller.registeredAtEpochMilliseconds, 1_756_720_800_000, "注册时间按 epoch 毫秒整数解码")

        let legacy = snapshot.devices[1]
        XCTAssertNil(legacy.deviceName)
        XCTAssertNil(legacy.platform)
        XCTAssertEqual(legacy.platformRawValue, "visionos")
        XCTAssertEqual(legacy.lanAddresses, [])
        XCTAssertEqual(legacy.capabilities, [])
        XCTAssertNil(legacy.lastSeenAt)
        XCTAssertNil(legacy.appVersion)
        XCTAssertFalse(legacy.isCaller)
        XCTAssertFalse(legacy.online)
    }

    func testMissingTruncatedFlagDefaultsToFalse() throws {
        let json = """
        {"generatedAt": 1, "callerDeviceId": "c", "devices": []}
        """
        let snapshot = try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: Data(json.utf8))
        XCTAssertFalse(snapshot.truncated)
        XCTAssertTrue(snapshot.devices.isEmpty)
    }

    func testISOStringTimestampsAreRejectedRatherThanSilentlyDropped() {
        let json = """
        {"generatedAt": 1, "callerDeviceId": "c", "devices": [{"deviceId": "d", "status": "active",
          "protocolSigningAlgorithm": "Ed25519", "protocolPublicKeyFingerprint": "ff", "online": false,
          "lastSeenAt": "2026-09-05T12:00:00Z"}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: Data(json.utf8)))
    }

    func testRecordRoundTripsThroughCodable() throws {
        let snapshot = try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: Data(Self.listResponse.utf8))
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: encoded)
        XCTAssertEqual(decoded, snapshot)
    }

    func testMarkingAllOfflineKeepsStaticFieldsAndIsIdentityWhenNothingIsOnline() throws {
        let json = """
        {"generatedAt": 1700000000000, "callerDeviceId": "me", "truncated": true, "devices": [
          {"deviceId": "me", "status": "active", "protocolSigningAlgorithm": "Ed25519", "protocolPublicKeyFingerprint": "aa",
           "deviceName": "This Mac", "lanAddresses": ["10.0.0.2"], "capabilities": ["remote_desktop"], "online": true, "isCaller": true},
          {"deviceId": "peer", "status": "active", "protocolSigningAlgorithm": "Ed25519", "protocolPublicKeyFingerprint": "bb",
           "deviceName": "Peer", "lanAddresses": [], "capabilities": [], "online": false}
        ]}
        """
        let snapshot = try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.hasOnlineDevices)
        let offline = snapshot.markingAllOffline()
        XCTAssertFalse(offline.hasOnlineDevices)
        XCTAssertEqual(offline.callerDeviceId, "me")
        XCTAssertTrue(offline.truncated)
        XCTAssertEqual(offline.generatedAtEpochMilliseconds, snapshot.generatedAtEpochMilliseconds)
        XCTAssertEqual(offline.devices.map(\.deviceId), ["me", "peer"])
        XCTAssertEqual(offline.devices[0].deviceName, "This Mac")
        XCTAssertEqual(offline.devices[0].lanAddresses, ["10.0.0.2"])
        XCTAssertEqual(offline.devices[0].capabilities, ["remote_desktop"])
        XCTAssertTrue(offline.devices[0].isCaller)
        XCTAssertEqual(offline.devices[1], snapshot.devices[1], "already-offline records are untouched")
        XCTAssertEqual(offline.markingAllOffline(), offline, "idempotent once nothing is online")
    }
}


extension AccountDeviceRecordDecodingTests {
    private func routeResponse(_ route: [String: Any]?, generated: Int64 = 1_757_073_600_123) throws -> AccountDeviceListSnapshot {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.listResponse.utf8)) as? [String: Any])
        var rows = try XCTUnwrap(json["devices"] as? [[String: Any]])
        if let route { rows[0]["lanControlRoute"] = route } else { rows[0]["lanControlRoute"] = NSNull() }
        json["devices"] = rows; json["generatedAt"] = generated
        json["accountScope"] = "untrusted-wire-scope"
        json["routeRequestStartedAt"] = 999_999
        return try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAccountRouteUsesRequestStartAndNeverImportsClockOrScopeFromJSON() throws {
        let start = ContinuousClock.now
        let route: [String: Any] = ["addresses": ["10.0.0.5", "fd12::1"], "port": 51173, "expiresAt": 1_757_073_690_123]
        let decoded = try routeResponse(route)
        let id = try XCTUnwrap(decoded.devices.first).id
        XCTAssertNil(decoded.accountScope)
        XCTAssertNil(decoded.routeRequestStartedAt)
        XCTAssertNil(decoded.liveRouteDeadline(for: id, at: start))
        let observed = decoded.scoped(to: "verified-account")
            .observingRoutes(requestStartedAt: start, now: start.advanced(by: .seconds(40)))
        XCTAssertEqual(observed.devices.first?.lanControlRoute?.port, 51173)
        XCTAssertEqual(observed.liveRouteDeadline(for: id, at: start.advanced(by: .seconds(89))), start.advanced(by: .seconds(90)))
        XCTAssertNil(observed.liveRouteDeadline(for: id, at: start.advanced(by: .seconds(90))))
        XCTAssertNil(observed.liveRouteDeadline(for: id, at: start.advanced(by: .seconds(-1))))
        let roundTrip = try JSONDecoder().decode(AccountDeviceListSnapshot.self, from: JSONEncoder().encode(observed))
        XCTAssertNil(roundTrip.routeRequestStartedAt)
        XCTAssertNil(roundTrip.accountScope)
        XCTAssertNil(roundTrip.liveRouteDeadline(for: id, at: start))
        XCTAssertNil(observed.markingAllOffline().devices.first?.lanControlRoute)
    }

    func testExpiredArrivalAndOverlongServerTTLDoNotRenewTheRoute() throws {
        let start = ContinuousClock.now
        let route: [String: Any] = ["addresses": ["10.0.0.5"], "port": 51173, "expiresAt": Int64.max]
        let response = try routeResponse(route)
        let observed = response.observingRoutes(requestStartedAt: start, now: start)
        let id = try XCTUnwrap(observed.devices.first).id
        XCTAssertEqual(observed.timeUntilRouteExpiry(at: start), 90)
        XCTAssertNil(observed.liveRouteDeadline(for: id, at: start.advanced(by: .seconds(90))))
        let late = response.observingRoutes(requestStartedAt: start, now: start.advanced(by: .seconds(91)))
        XCTAssertNil(late.devices.first?.lanControlRoute)
        XCTAssertTrue(try XCTUnwrap(late.devices.first).online, "Route expiry does not rewrite ordinary online metadata")
        XCTAssertNil(try routeResponse(nil).devices.first?.lanControlRoute, "Old servers and withdrawals are explicit absence")
    }

    func testMalformedAccountRoutesAreRejectedRatherThanUsedAsDiscoveryMetadata() throws {
        var invalid: [[String: Any]] = []
        for addresses in [[], ["localhost"], ["127.0.0.1"], ["0.0.0.0"], ["fe80::1%en0"], ["[fd12::1]"],
                          ["10.0.0.5/path"], ["10.0.0.5\u{0}ignored"], ["fd12::1\u{0}ignored"],
                          ["10.0.0.5", "10.0.0.5"], (1...9).map { "10.0.0.\($0)" }] {
            invalid.append(["addresses": addresses, "port": 51173, "expiresAt": 1_757_073_690_123])
        }
        let invalidPorts: [Any] = [0, -1, 65536, 1.5, "51173"]
        for port in invalidPorts {
            invalid.append(["addresses": ["10.0.0.5"], "port": port, "expiresAt": 1_757_073_690_123])
        }
        for route in invalid { XCTAssertThrowsError(try routeResponse(route), "Accepted malformed route: \(route)") }
    }
}
