import XCTest
@testable import SkyBridgeCore

@MainActor
final class DeviceDiscoveryLocalRecordTests: XCTestCase {
    private let localId = "11111111-1111-4111-8111-111111111111"
    private let remoteId = "22222222-2222-4222-8222-222222222222"
    private let fingerprint = String(repeating: "a", count: 64)
    private let route = "bonjour:Workstation@local."

    private var localIdentity: CanonicalBonjourAdvertisementIdentity {
        CanonicalBonjourAdvertisementIdentity(deviceId: localId, protocolPublicKeyFingerprint: fingerprint)
    }

    private func host(
        id: String? = nil,
        fingerprint override: String? = nil,
        address: String? = "192.0.2.10"
    ) -> DiscoveredDevice {
        DiscoveredDevice(id: UUID(), name: "Workstation", ipv4: address, ipv6: nil,
            services: [BonjourInteropContract.remoteControlServiceType],
            portMap: [BonjourInteropContract.remoteControlServiceType: 5901],
            uniqueIdentifier: "id:\(id ?? localId)", routeIdentifiers: [route],
            source: .skybridgeBonjour, deviceId: id ?? localId, pubKeyFP: override ?? fingerprint)
    }

    private func observation(source: DeviceSource = .thirdPartyBonjour, address: String? = "192.0.2.10") -> DiscoveredDevice {
        DiscoveredDevice(id: UUID(), name: "Workstation", ipv4: address, ipv6: nil,
            services: source == .skybridgeUSB ? [] : ["_device-info._tcp"],
            portMap: source == .skybridgeUSB ? [:] : ["_device-info._tcp": 0],
            connectionTypes: source == .skybridgeUSB ? [.usb] : [.wifi],
            uniqueIdentifier: route, routeIdentifiers: [route], source: source)
    }

    func testOrdinaryBroadcastCannotTurnLocalRemoteDesktopIntoAnAvailablePeer() {
        let manager = DeviceDiscoveryManagerOptimized()
        manager.discoveredDevices = [host()]
        manager.sanitizeCache(localIdentity)
        XCTAssertFalse(manager.supportsRemoteControl(manager.discoveredDevices[0]))

        manager.discoveredDevices[0] = DeviceDiscoveryManagerOptimized.mergingNonSkyBridgeObservation(
            existingDevice: manager.discoveredDevices[0], sanitized: observation())
        manager.sanitizeCache(localIdentity)

        let updated = manager.discoveredDevices[0]
        XCTAssertEqual(updated.deviceId, localId)
        XCTAssertEqual(updated.pubKeyFP, fingerprint)
        XCTAssertEqual(updated.source, .skybridgeBonjour)
        XCTAssertEqual(updated.portMap[BonjourInteropContract.remoteControlServiceType], 5901)
        XCTAssertTrue(updated.isLocalDevice)
        XCTAssertFalse(manager.supportsRemoteControl(updated), "A local desktop must not reappear as a remote target after ordinary Bonjour metadata arrives.")
    }

    func testUSBObservationKeepsLocalIdentityAndAddsPresence() {
        let manager = DeviceDiscoveryManagerOptimized()
        manager.discoveredDevices = [host()]
        manager.sanitizeCache(localIdentity)
        manager.discoveredDevices[0] = DeviceDiscoveryManagerOptimized.mergingNonSkyBridgeObservation(
            existingDevice: manager.discoveredDevices[0], sanitized: observation(source: .skybridgeUSB, address: nil))
        let updated = manager.discoveredDevices[0]
        XCTAssertTrue(updated.connectionTypes.contains(.usb))
        XCTAssertEqual(updated.deviceId, localId)
        XCTAssertTrue(updated.isLocalDevice)
        XCTAssertFalse(manager.supportsRemoteControl(updated))
    }

    func testEveryStrongLocalRecordRemainsExcludedWithoutHidingSameNamedRemote() {
        let manager = DeviceDiscoveryManagerOptimized()
        manager.discoveredDevices = [host(), host(), host(id: remoteId, fingerprint: String(repeating: "b", count: 64))]
        manager.sanitizeCache(localIdentity)
        XCTAssertEqual(manager.discoveredDevices.count, 3)
        XCTAssertEqual(manager.discoveredDevices.filter(\.isLocalDevice).count, 2,
            "A second real local record must never be relabeled as a remote device to satisfy a display count.")
        XCTAssertEqual(manager.discoveredDevices.filter { manager.supportsRemoteControl($0) }.map(\.deviceId), [remoteId])
    }

    func testSameNamedRemoteKeepsItsOwnIdentityAfterOrdinaryBroadcast() {
        let manager = DeviceDiscoveryManagerOptimized()
        manager.discoveredDevices = [DeviceDiscoveryManagerOptimized.mergingNonSkyBridgeObservation(
            existingDevice: host(id: remoteId, fingerprint: String(repeating: "b", count: 64)), sanitized: observation())]
        manager.sanitizeCache(localIdentity)
        let updated = manager.discoveredDevices[0]
        XCTAssertEqual(updated.deviceId, remoteId)
        XCTAssertFalse(updated.isLocalDevice)
        XCTAssertTrue(manager.supportsRemoteControl(updated))
    }

    func testOrdinaryBroadcastCannotEraseIdentityThenUpgradeToConflictingPeer() {
        let preserved = DeviceDiscoveryManagerOptimized.mergingNonSkyBridgeObservation(
            existingDevice: host(), sanitized: observation())
        let conflicting = host(id: remoteId, fingerprint: String(repeating: "b", count: 64))
        XCTAssertNil(DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(in: [preserved], candidate: conflicting))
        XCTAssertFalse(DeviceDiscoveryManagerOptimized.isRouteBoundProtocolMerge(existing: preserved, candidate: conflicting))
    }

    func testSingleMatchingIdentityFieldDoesNotOverrideAConflictingField() {
        let existing = host()
        for conflicting in [host(fingerprint: String(repeating: "b", count: 64)), host(id: remoteId)] {
            XCTAssertNil(DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(in: [existing], candidate: conflicting))
            XCTAssertFalse(DeviceDiscoveryManagerOptimized.isRouteBoundProtocolMerge(existing: existing, candidate: conflicting))
        }
    }

    func testLocalUUIDMatchingNormalizesCaseWithoutRequiringFingerprint() {
        let uppercaseID = "9A770257-EE43-4D15-9031-D39B7A4AE045"
        let identity = CanonicalBonjourAdvertisementIdentity(deviceId: uppercaseID.lowercased(), protocolPublicKeyFingerprint: fingerprint)
        var local = host(id: uppercaseID)
        local.pubKeyFP = nil

        let manager = DeviceDiscoveryManagerOptimized()
        manager.discoveredDevices = [local]
        manager.sanitizeCache(identity)

        XCTAssertTrue(manager.discoveredDevices[0].isLocalDevice)
        XCTAssertFalse(manager.supportsRemoteControl(manager.discoveredDevices[0]))
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(
            in: [local], candidate: host(id: uppercaseID.lowercased())), 0)
    }

    func testConflictingIdentityCannotBecomeLocalThroughAnotherMatchingFieldOrMAC() {
        let sharedMAC = "02:11:22:33:44:55"
        let identity = CanonicalBonjourAdvertisementIdentity(deviceId: localId, protocolPublicKeyFingerprint: fingerprint)
        for var conflicting in [host(fingerprint: String(repeating: "b", count: 64)), host(id: remoteId)] {
            conflicting.macSet = [sharedMAC]
            XCTAssertFalse(IdentityResolver.resolveIsLocalSynchronously(device: conflicting, localIdentity: identity))
        }
    }

    func testRouteEndpointCannotActAsLocalStableIdentity() {
        let identity = CanonicalBonjourAdvertisementIdentity(deviceId: route, protocolPublicKeyFingerprint: "")
        var routeOnly = host(id: route)
        routeOnly.pubKeyFP = nil

        XCTAssertFalse(IdentityResolver.resolveIsLocalSynchronously(device: routeOnly, localIdentity: identity))
    }

    func testMissingIdentityFieldDoesNotConflictWithMatchingKnownIdentity() {
        var idOnly = host()
        idOnly.pubKeyFP = nil
        var fingerprintOnly = host()
        fingerprintOnly.deviceId = nil

        XCTAssertTrue(IdentityResolver.resolveIsLocalSynchronously(device: idOnly, localIdentity: localIdentity))
        XCTAssertTrue(IdentityResolver.resolveIsLocalSynchronously(device: fingerprintOnly, localIdentity: localIdentity))
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(in: [host()], candidate: idOnly), 0)
        XCTAssertEqual(DeviceDiscoveryManagerOptimized.routeBoundMergeIndex(in: [host()], candidate: fingerprintOnly), 0)
    }

    func testSameNamedOrdinaryBroadcastAtDifferentAddressDoesNotAttachToProtocolRecord() {
        let resolver = IdentityResolver()
        let index = resolver.findMergeIndex(
            in: [host()], candidate: observation(address: "192.0.2.20"), candidateFP: nil)

        XCTAssertNil(index, "A shared display name and service-instance name cannot override a different resolved address.")
    }

    func testOrdinaryBroadcastSelectsMatchingRemoteAddressDespiteSameNamedLocalRecord() {
        let resolver = IdentityResolver()
        let local = host()
        let remote = host(id: remoteId, fingerprint: String(repeating: "b", count: 64), address: "192.0.2.20")
        let index = resolver.findMergeIndex(
            in: [local, remote], candidate: observation(address: "192.0.2.20"), candidateFP: nil)

        XCTAssertEqual(index, 1)
    }

    func testProtocolConflictRejectsWeakMergeEvenForSameRecordAndAddress() {
        let resolver = IdentityResolver()
        let existing = host()
        var conflicting = existing
        conflicting.pubKeyFP = String(repeating: "b", count: 64)
        let index = resolver.findMergeIndex(in: [existing], candidate: conflicting, candidateFP: nil)

        XCTAssertNil(index, "A record UUID is storage identity and cannot authorize overwriting a conflicting peer identity.")
    }

    func testUSBPresenceCannotReplaceNetworkRouteOrMetadata() {
        var existing = host()
        existing.modelName = "MacBook Pro"
        existing.setIsLocalDeviceByDiscovery(true)
        var usb = observation(source: .skybridgeUSB, address: "192.0.2.99")
        usb.uniqueIdentifier = "serial:00008140-000E788401C0801C"
        usb.routeIdentifiers = ["bonjour:Other@local."]
        usb.modelName = "USB Observation"
        let merged = DeviceDiscoveryManagerOptimized.mergingNonSkyBridgeObservation(
            existingDevice: existing, sanitized: usb)

        XCTAssertEqual(merged.ipv4, existing.ipv4)
        XCTAssertEqual(merged.uniqueIdentifier, existing.uniqueIdentifier)
        XCTAssertEqual(merged.routeIdentifiers, existing.routeIdentifiers)
        XCTAssertEqual(merged.modelName, existing.modelName)
        XCTAssertEqual(merged.portMap, existing.portMap)
        XCTAssertEqual(merged.source, existing.source)
        XCTAssertEqual(merged.pubKeyFP, existing.pubKeyFP)
        XCTAssertTrue(merged.isLocalDevice)
        XCTAssertTrue(merged.connectionTypes.contains(.usb))
    }

    func testResolvedBatchKeepsEveryLocalRecordExcludedAfterOrdinaryBroadcast() {
        let manager = DeviceDiscoveryManagerOptimized()
        manager.discoveredDevices = [host(), host()]
        manager.applyDiscoveryUpdates([observation()], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 2)
        XCTAssertTrue(manager.discoveredDevices.allSatisfy(\.isLocalDevice))
        XCTAssertTrue(manager.discoveredDevices.allSatisfy { $0.deviceId == localId && $0.pubKeyFP == fingerprint })
        XCTAssertTrue(manager.discoveredDevices.filter { manager.supportsRemoteControl($0) }.isEmpty)
    }

    func testResolvedBatchDoesNotAttachSameNamedObservationAtDifferentAddress() {
        let manager = DeviceDiscoveryManagerOptimized()
        let existing = host()
        let incoming = observation(address: "192.0.2.20")
        manager.discoveredDevices = [existing]
        manager.applyDiscoveryUpdates([incoming], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 2)
        XCTAssertEqual(manager.discoveredDevices.first(where: { $0.id == existing.id })?.ipv4, existing.ipv4)
        XCTAssertEqual(manager.discoveredDevices.first(where: { $0.id == existing.id })?.services.contains("_device-info._tcp"), false)
        XCTAssertEqual(manager.discoveredDevices.first(where: { $0.id == incoming.id })?.ipv4, "192.0.2.20")
        XCTAssertNil(manager.discoveredDevices.first(where: { $0.id == incoming.id })?.deviceId)
    }

    func testResolvedBatchUpdatesMatchingRemoteWithoutAbsorbingSameNamedLocal() {
        let manager = DeviceDiscoveryManagerOptimized()
        let local = host()
        let remote = host(id: remoteId, fingerprint: String(repeating: "b", count: 64), address: "192.0.2.20")
        manager.discoveredDevices = [local, remote]
        manager.applyDiscoveryUpdates([observation(address: "192.0.2.20")], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 2)
        XCTAssertEqual(manager.discoveredDevices.filter { manager.supportsRemoteControl($0) }.map(\.deviceId), [remoteId])
        XCTAssertFalse(manager.discoveredDevices[0].services.contains("_device-info._tcp"))
        XCTAssertTrue(manager.discoveredDevices[1].services.contains("_device-info._tcp"))
        XCTAssertEqual(manager.discoveredDevices[0].id, local.id)
        XCTAssertEqual(manager.discoveredDevices[1].id, remote.id)
    }

    func testResolvedBatchAcceptsMatchingRouteWhenOrdinaryObservationHasNoAddress() {
        let manager = DeviceDiscoveryManagerOptimized()
        manager.discoveredDevices = [host()]
        manager.applyDiscoveryUpdates([observation(address: nil)], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 1)
        XCTAssertEqual(manager.discoveredDevices[0].deviceId, localId)
        XCTAssertEqual(manager.discoveredDevices[0].uniqueIdentifier, "id:\(localId)")
        XCTAssertEqual(manager.discoveredDevices[0].routeIdentifiers, [route])
        XCTAssertTrue(manager.discoveredDevices[0].services.contains("_device-info._tcp"))
        XCTAssertTrue(manager.discoveredDevices[0].isLocalDevice)
    }

    func testResolvedBatchDoesNotTrustIdentityHintsFromOrdinaryService() {
        let manager = DeviceDiscoveryManagerOptimized()
        var ordinary = observation()
        ordinary.deviceId = localId
        ordinary.pubKeyFP = fingerprint
        ordinary.macSet = ["02:11:22:33:44:55"]
        manager.applyDiscoveryUpdates([ordinary], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 1)
        XCTAssertNil(manager.discoveredDevices[0].deviceId)
        XCTAssertNil(manager.discoveredDevices[0].pubKeyFP)
        XCTAssertTrue(manager.discoveredDevices[0].macSet.isEmpty)
        XCTAssertFalse(manager.discoveredDevices[0].isLocalDevice)
        XCTAssertFalse(manager.supportsRemoteControl(manager.discoveredDevices[0]))
    }

    func testResolvedBatchDoesNotOverwriteProtocolIdentityWhenOneFieldConflicts() {
        let manager = DeviceDiscoveryManagerOptimized()
        let existing = host()
        let conflicting = host(fingerprint: String(repeating: "b", count: 64))
        manager.discoveredDevices = [existing]
        manager.applyDiscoveryUpdates([conflicting], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 2)
        XCTAssertEqual(manager.discoveredDevices.first(where: { $0.id == existing.id })?.pubKeyFP, fingerprint)
        XCTAssertEqual(manager.discoveredDevices.first(where: { $0.id == existing.id })?.isLocalDevice, true)
        XCTAssertEqual(manager.discoveredDevices.first(where: { $0.id == conflicting.id })?.pubKeyFP, conflicting.pubKeyFP)
        XCTAssertEqual(manager.discoveredDevices.first(where: { $0.id == conflicting.id })?.isLocalDevice, false)
    }

    func testOrdinaryRecordStillRefreshesItsOwnMetadata() {
        var existing = observation()
        existing.platformName = "Old Platform"
        existing.osVersion = "1.0"
        existing.modelName = "Old Model"
        existing.chip = "Old Chip"
        var incoming = observation()
        incoming.platformName = "New Platform"
        incoming.osVersion = "2.0"
        incoming.modelName = "New Model"
        incoming.chip = "New Chip"
        let merged = DeviceDiscoveryManagerOptimized.mergingNonSkyBridgeObservation(
            existingDevice: existing, sanitized: incoming)

        XCTAssertEqual(merged.id, existing.id)
        XCTAssertEqual(merged.platformName, incoming.platformName)
        XCTAssertEqual(merged.osVersion, incoming.osVersion)
        XCTAssertEqual(merged.modelName, incoming.modelName)
        XCTAssertEqual(merged.chip, incoming.chip)
        XCTAssertNil(merged.deviceId)
        XCTAssertNil(merged.pubKeyFP)
        XCTAssertFalse(merged.isLocalDevice)
    }

    func testResolvedBatchRejectsConflictingUpdateWithoutDuplicatingRecordUUID() {
        let manager = DeviceDiscoveryManagerOptimized()
        let existing = host()
        var conflicting = existing
        conflicting.pubKeyFP = String(repeating: "b", count: 64)
        manager.discoveredDevices = [existing]
        manager.applyDiscoveryUpdates([conflicting], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 1)
        XCTAssertEqual(manager.discoveredDevices[0].id, existing.id)
        XCTAssertEqual(manager.discoveredDevices[0].pubKeyFP, fingerprint)
        XCTAssertTrue(manager.discoveredDevices[0].isLocalDevice)
    }
}
