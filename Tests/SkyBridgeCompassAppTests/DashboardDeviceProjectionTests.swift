import SkyBridgeCore
import XCTest

@testable import SkyBridgeCompassApp

final class DashboardDeviceProjectionTests: XCTestCase {
  func testRemoteDesktopMetricsCannotOverwriteCurrentDashboardCounts() {
    var metrics = DashboardMetrics()
    metrics.onlineDevices = 2; metrics.activeSessions = 1; metrics.fileTransfers = 3
    metrics.merge(with: .init(onlineDevices: 0, activeSessions: 0, transferCount: 0,
                              alertCount: 4, cpuTimeline: [:]))
    XCTAssertEqual(metrics.onlineDevices, 2)
    XCTAssertEqual(metrics.activeSessions, 1)
    XCTAssertEqual(metrics.fileTransfers, 3)
    XCTAssertEqual(metrics.alerts, 4)
  }

  func testConnectedRowRequiresTheSameStableIdentityAndProtocolFingerprint() {
    let device = peer()
    let pin = String(repeating: "a", count: 64)
    XCTAssertEqual(DashboardDeviceProjection.connectedTransport(for: device,
      authenticatedPeerId: "PEER-00000001", authenticatedFingerprint: pin, transport: .usb), .usb)
    XCTAssertEqual(DashboardDeviceProjection.connectedTransport(for: device,
      authenticatedPeerId: "id:peer-00000001", authenticatedFingerprint: pin, transport: .network), .network)
    XCTAssertNil(DashboardDeviceProjection.connectedTransport(for: device,
      authenticatedPeerId: "id:peer-00000002", authenticatedFingerprint: pin, transport: .usb))
    XCTAssertNil(DashboardDeviceProjection.connectedTransport(for: device,
      authenticatedPeerId: "id:peer-00000001", authenticatedFingerprint: String(repeating: "b", count: 64), transport: .usb))
    var partial = device
    partial.pubKeyFP = nil
    XCTAssertNil(DashboardDeviceProjection.connectedTransport(for: partial,
      authenticatedPeerId: "id:peer-00000001", authenticatedFingerprint: pin, transport: .usb))
  }

  func peer(
    _ stable: String = "id:peer-00000001", pin: String = String(repeating: "a", count: 64),
    ip: String = "192.0.2.10", local: Bool = false, source: DeviceSource = .skybridgeBonjour,
    services: [String] = ["_skybridge._tcp"]
  ) -> DiscoveredDevice {
    DiscoveredDevice(
      id: UUID(), name: "Same peer name", ipv4: ip, ipv6: "2001:db8::1", platformName: "Android",
      osVersion: "Android 16 (API 36)", modelName: "model", chip: "chip", services: services,
      portMap: ["_skybridge._tcp": 8080], remoteVideoFormats: ["h264"], connectionTypes: [.wifi],
      uniqueIdentifier: stable, routeIdentifiers: ["bonjour:peer._skybridge._tcp.local."],
      signalStrength: 70, source: source, isLocalDevice: local, deviceId: stable, pubKeyFP: pin,
      macSet: ["aa:bb:cc:dd:ee:ff"])
  }
  func project(
    _ peers: [DiscoveredDevice], extra: [DiscoveredDevice] = [], usb: [DiscoveredDevice] = [],
    compat: Bool = false
  ) -> [DiscoveredDevice] {
    DashboardDeviceProjection.project(
      currentPeers: peers, connectedUSBPeers: usb, supplementary: extra, compatibilityMode: compat)
  }
  func testDifferentStableIDsWithSamePinNameAndAddressRemainDistinct() {
    let first = peer()
    let second = peer("id:peer-00000002")
    XCTAssertEqual(project([first, second]).count, 2)
  }
  func testSameStableIDWithDifferentPinsRemainsDistinct() {
    let first = peer()
    let second = peer(pin: String(repeating: "b", count: 64))
    XCTAssertEqual(project([first, second]).count, 2)
  }
  func testDuplicateObservationPreservesEveryCurrentField() {
    let current = peer()
    XCTAssertEqual(project([current, current]), [current])
  }
  func testCurrentRouteWinsOverStaleSupplementaryAndUSBObservation() {
    let stale = peer(ip: "192.0.2.9")
    let current = peer(ip: "192.0.2.10")
    XCTAssertEqual(project([current], extra: [stale], usb: [stale]), [current])
  }
  func testLocalAndHistoricalSkyBridgeExtrasAreNotCurrentPeers() {
    let current = peer()
    let local = peer("id:local-0000001", local: true)
    let stale = peer("id:stale-0000001")
    XCTAssertEqual(project([current, local], extra: [stale]), [current])
  }
  func testCompatibilityFlagControlsActualAuxiliaryRecordsWithoutMakingPeers() {
    let current = peer()
    var printer = peer("id:printer-00001", source: .thirdPartyBonjour, services: ["_ipp._tcp"])
    printer.deviceId = nil
    printer.pubKeyFP = nil
    XCTAssertEqual(project([current], extra: [printer]), [current])
    XCTAssertEqual(project([current], extra: [printer], compat: true), [current, printer])
  }
  func testSameNameAndIPWithoutIdentityDoesNotMergeCurrentRecords() {
    var first = peer()
    first.deviceId = nil
    first.pubKeyFP = nil
    first.uniqueIdentifier = nil
    var second = peer()
    second.deviceId = nil
    second.pubKeyFP = nil
    second.uniqueIdentifier = nil
    XCTAssertEqual(project([first, second]).count, 2)
  }
}

extension DashboardDeviceProjectionTests {
  func testUSBOnlyCurrentTargetPreservesItsFullRecord() {
    var usb = peer()
    usb.source = .skybridgeUSB
    usb.connectionTypes = [.usb]
    XCTAssertEqual(project([], usb: [usb]), [usb])
  }
  func testWithdrawnCurrentPeerDoesNotSurviveInNextProjection() {
    let current = peer()
    XCTAssertEqual(project([current]), [current])
    XCTAssertEqual(project([], extra: [current], compat: true), [])
  }
  func testAuxiliarySkyBridgeSourceWithoutServiceIsNotAConnectablePeer() {
    let stale = peer(source: .skybridgeBonjour, services: [])
    XCTAssertEqual(project([stale], extra: [stale], compat: true), [])
  }
  func testStableIDCanonicalAliasesCoalesceWithoutChangingFields() {
    let current = peer("id:peer-00000001")
    let alias = peer("PEER-00000001")
    XCTAssertEqual(project([current, alias]), [current])
  }
  func testPartialIdentityCannotBridgeConflictingStableIDs() {
    var partial = peer()
    partial.deviceId = nil
    let first = peer()
    let second = peer("id:peer-00000002")
    XCTAssertEqual(project([partial, first, second]), [partial, first, second])
  }
  func testPartialIdentityCannotBridgeConflictingPins() {
    var partial = peer()
    partial.pubKeyFP = nil
    let first = peer()
    let second = peer(pin: String(repeating: "b", count: 64))
    XCTAssertEqual(project([partial, first, second]), [partial, first, second])
  }
  func testSearchPreservesMetadataAndUsesCurrentAddress() {
    let old = peer(ip: "192.0.2.9")
    let current = peer(ip: "192.0.2.10")
    let devices = project([current], extra: [old])
    XCTAssertEqual(
      DashboardDeviceProjection.filter(
        devices, searchText: "192.0.2.9", sortBySignalStrength: false), [])
    XCTAssertEqual(
      DashboardDeviceProjection.filter(
        devices, searchText: "SKYBRIDGE", sortBySignalStrength: false), [current])
    XCTAssertEqual(
      DashboardDeviceProjection.filter(devices, searchText: "", sortBySignalStrength: false),
      [current])
  }
  func testSignalOrderingDoesNotChangeRecords() {
    var low = peer("id:peer-00000002")
    low.signalStrength = 20
    let high = peer()
    XCTAssertEqual(
      DashboardDeviceProjection.filter([low, high], searchText: "", sortBySignalStrength: true),
      [high, low])
    XCTAssertEqual(
      DashboardDeviceProjection.filter([low, high], searchText: "", sortBySignalStrength: false),
      [low, high])
  }
}
