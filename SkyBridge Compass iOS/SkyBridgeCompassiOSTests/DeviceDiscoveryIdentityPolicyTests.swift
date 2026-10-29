import Foundation
import Network
import enum SkyBridgeProtocolCore.BonjourInteropProtocolContract
import XCTest

@testable import SkyBridgeCompass_iOS

final class DeviceDiscoveryIdentityPolicyTests: XCTestCase {
  func testBrowseEndpointIdentityIsStructuralAndNormalizesDNSComponents() {
    let canonical = NWEndpoint.service(
      name: "Office Mac",
      type: "_skybridge._tcp",
      domain: "local.",
      interface: nil
    )
    let equivalent = NWEndpoint.service(
      name: "OFFICE MAC",
      type: "_SKYBRIDGE._TCP.",
      domain: "LOCAL",
      interface: nil
    )
    let differentRoute = NWEndpoint.service(
      name: "Office Mac|_skybridge._tcp",
      type: "_skybridge._tcp",
      domain: "local.",
      interface: nil
    )

    XCTAssertEqual(
      BonjourBrowseEndpointIdentity.key(for: canonical),
      BonjourBrowseEndpointIdentity.key(for: equivalent)
    )
    XCTAssertNotEqual(
      BonjourBrowseEndpointIdentity.key(for: canonical),
      BonjourBrowseEndpointIdentity.key(for: differentRoute),
      "peer-controlled delimiters in a service name must not collide with route components"
    )
  }

  func testBrowseEndpointIdentityIncludesHostPort() {
    let control = NWEndpoint.hostPort(
      host: "192.168.50.12",
      port: 9_527
    )
    let transfer = NWEndpoint.hostPort(
      host: "192.168.50.12",
      port: 9_528
    )

    XCTAssertNotEqual(
      BonjourBrowseEndpointIdentity.key(for: control),
      BonjourBrowseEndpointIdentity.key(for: transfer)
    )
  }

  func testBrowseFloodSelectionIsDeterministicAndRetainsKnownLiveEndpoint() {
    let legitimateEndpoint = "service:legitimate"
    let departedEndpoint = "service:departed"
    let flood = (0..<1_000).map { String(format: "service:attacker-%04d", $0) }
    let forward = [legitimateEndpoint] + flood
    let reverse = Array(forward.reversed())
    let tracked = Set([legitimateEndpoint, departedEndpoint])

    let forwardDecision = BonjourBrowseReconciliationPolicy.decide(
      liveEndpointKeys: forward,
      trackedEndpointKeys: tracked,
      capacity: 8
    )
    let reverseDecision = BonjourBrowseReconciliationPolicy.decide(
      liveEndpointKeys: reverse,
      trackedEndpointKeys: tracked,
      capacity: 8
    )

    XCTAssertEqual(forwardDecision, reverseDecision)
    XCTAssertEqual(forwardDecision.selectedEndpointKeys.count, 8)
    XCTAssertTrue(forwardDecision.selectedEndpointKeys.contains(legitimateEndpoint))
    XCTAssertEqual(forwardDecision.withdrawnEndpointKeys, [departedEndpoint])
  }

  func testBrowseReconciliationDoesNotTruncateWithdrawals() {
    let previouslyTracked = Set((0..<700).map { "service:departed-\($0)" })

    let decision = BonjourBrowseReconciliationPolicy.decide(
      liveEndpointKeys: EmptyCollection<String>(),
      trackedEndpointKeys: previouslyTracked,
      capacity: 256
    )

    XCTAssertTrue(decision.selectedEndpointKeys.isEmpty)
    XCTAssertEqual(Set(decision.withdrawnEndpointKeys), previouslyTracked)
    XCTAssertEqual(decision.withdrawnEndpointKeys.count, 700)
  }

  func testConnectionLivenessProjectsTrustOnlyToExactStableIdentity() throws {
    let stableDeviceId = "id:11111111-2222-4333-8444-555555555555"
    let victimDeviceId = "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    let projection = try XCTUnwrap(
      DiscoveryConnectionLivenessProjectionPolicy.projection(
        presentedDeviceId: stableDeviceId.uppercased(),
        cachedDeviceIds: Set([stableDeviceId, victimDeviceId]),
        isConnected: true,
        authenticatedSessionIsTrusted: true
      )
    )

    XCTAssertEqual(projection.deviceId, stableDeviceId)
    XCTAssertTrue(projection.isConnected)
    XCTAssertTrue(projection.isTrusted)
  }

  func testEndpointAliasCannotProjectAuthenticatedTrustToAnotherDiscoveryRow() throws {
    let endpointAlias = "host:192.168.50.12"
    let victimDeviceId = "id:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    XCTAssertNil(
      DiscoveryConnectionLivenessProjectionPolicy.projection(
        presentedDeviceId: endpointAlias,
        cachedDeviceIds: Set([victimDeviceId]),
        isConnected: true,
        authenticatedSessionIsTrusted: true
      )
    )

    let exactAliasProjection = try XCTUnwrap(
      DiscoveryConnectionLivenessProjectionPolicy.projection(
        presentedDeviceId: endpointAlias,
        cachedDeviceIds: Set([endpointAlias, victimDeviceId]),
        isConnected: true,
        authenticatedSessionIsTrusted: true
      )
    )
    XCTAssertEqual(exactAliasProjection.deviceId, endpointAlias)
    XCTAssertTrue(exactAliasProjection.isConnected)
    XCTAssertFalse(
      exactAliasProjection.isTrusted,
      "an endpoint route may carry liveness for its exact row but is never trust authority"
    )
  }

  func testDifferentStableAuthoritiesAreNotSelfEvenWhenPresentationNamesCouldMatch() {
    XCTAssertFalse(
      DeviceDiscoveryManager.isProvenSelfDevice(
        localStableDeviceId: "id:local-iphone",
        remoteDeviceId: "id:remote-iphone",
        hasLoopbackAddress: false
      ),
      "名称和平台不参与身份判定；两台默认名称相同的 iPhone 必须能互相发现"
    )
  }

  func testMatchingStableAuthorityIsSelfCaseInsensitively() {
    XCTAssertTrue(
      DeviceDiscoveryManager.isProvenSelfDevice(
        localStableDeviceId: "ID:LOCAL-IPHONE",
        remoteDeviceId: "id:local-iphone",
        hasLoopbackAddress: false
      )
    )
  }

  func testLoopbackIsSelfWithoutAStableAuthority() {
    XCTAssertTrue(
      DeviceDiscoveryManager.isProvenSelfDevice(
        localStableDeviceId: nil,
        remoteDeviceId: "bonjour:iphone@local.",
        hasLoopbackAddress: true
      )
    )
  }

  func testPrimaryBonjourWireUsesCanonicalRawKeyOrderDeterministically() throws {
    let deviceId = "id:local-iphone-1"
    let fingerprint = String(repeating: "a", count: 64)
    let expected = encodeTXT([
      ("deviceId", deviceId),
      ("hs_soa", "1"),
      ("platform", "ios"),
      ("pubKeyFP", fingerprint),
      ("version", "2"),
    ])

    for _ in 0..<64 {
      let wireData = try DeviceDiscoveryManager.primaryBonjourInteropAdvertisementWireData(
        validatedDeviceId: deviceId,
        protocolIdentityFingerprint: fingerprint,
        platform: .iOS
      )

      XCTAssertEqual(wireData, expected)
      XCTAssertEqual(NWTXTRecord(wireData).data, expected)
    }

    guard case .version2(let decoded) = try BonjourInteropProtocolContract.decodeAdvertisement(
      expected,
      role: .control
    ) else {
      return XCTFail("Expected the canonical iOS wire bytes to decode as version 2")
    }
    XCTAssertEqual(decoded.deviceId, deviceId)
    XCTAssertEqual(decoded.protocolPublicKeyFingerprint, fingerprint)
    XCTAssertEqual(decoded.platform, .iOS)

    let fields = NetService.dictionary(fromTXTRecord: expected)
    XCTAssertEqual(Set(fields.keys), Set(["version", "deviceId", "pubKeyFP", "platform", "hs_soa"]))
    for unsupportedKey in [
      "name",
      "capabilities",
      "transferPort",
      "fileTransferPort",
      "file_transfer_port",
      "remotePort",
      "remoteControlPort",
      "remote_port",
      "remoteVideoFormats",
      "remote_video_formats",
      "publicKey",
      "protocolPublicKey",
      "pqcPublicKey",
      "trusted",
      "isTrusted",
      "trustState",
    ] {
      XCTAssertNil(fields[unsupportedKey], "must not advertise \(unsupportedKey)")
    }
  }

  func testDiscoveryDiagnosticsDoNotPublishPeerControlledIdentityOrErrorDescriptions() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try readRepositorySourceForSourceShapeTests(
      at: repositoryRoot.appendingPathComponent(
        "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/DeviceDiscoveryManager.swift"
      )
    )

    XCTAssertTrue(source.contains("private nonisolated static func diagnosticReference"))
    XCTAssertTrue(source.contains("private nonisolated static func diagnosticErrorSummary"))
    XCTAssertTrue(source.contains("device_ref=\\(Self.diagnosticReference(device.id))"))
    XCTAssertTrue(source.contains("endpoint_ref=\\(endpointReference)"))
    XCTAssertTrue(source.contains("peer_ref=\\(peerReference)"))
    XCTAssertFalse(source.contains("📡 开始广播服务: \\(deviceName)"))
    XCTAssertFalse(source.contains("➕ 发现设备: \\(device.name)"))
    XCTAssertFalse(source.contains("收到新连接: \\(endpointDescription)"))
    XCTAssertFalse(source.contains("入站连接就绪: \\(peerId)"))
    XCTAssertFalse(source.contains("入站连接失败: \\(error.localizedDescription)"))
  }

  private func encodeTXT(_ entries: [(String, String)]) -> Data {
    var data = Data()
    for (key, value) in entries {
      let entry = Data("\(key)=\(value)".utf8)
      precondition(entry.count <= Int(UInt8.max))
      data.append(UInt8(entry.count))
      data.append(entry)
    }
    return data
  }
}
