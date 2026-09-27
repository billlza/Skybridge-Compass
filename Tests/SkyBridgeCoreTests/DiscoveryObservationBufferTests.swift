import XCTest
@testable import SkyBridgeCore

@MainActor
final class DiscoveryObservationBufferTests: XCTestCase {
    private let deviceID = "11111111-1111-4111-8111-111111111111"
    private let fingerprint = String(repeating: "a", count: 64)

    private func key(_ service: String = BonjourInteropContract.remoteControlServiceType) -> DiscoveryObservationBuffer.Key {
        .bonjour(instance: "workstation", serviceType: service, domain: "local.")
    }

    private func device(recordID: UUID = UUID(), port: Int, service: String = BonjourInteropContract.remoteControlServiceType) -> DiscoveredDevice {
        DiscoveredDevice(id: recordID, name: "Workstation", ipv4: port == 0 ? nil : "192.0.2.10", ipv6: nil,
            services: [service], portMap: [service: port], routeIdentifiers: ["bonjour:Workstation@local."],
            source: .skybridgeBonjour, deviceId: deviceID, pubKeyFP: fingerprint)
    }

    private func accepted(_ admission: DiscoveryObservationBuffer.Admission, file: StaticString = #filePath, line: UInt = #line) throws -> DiscoveryObservationBuffer.Lease {
        guard case .accepted(let lease) = admission else {
            XCTFail("Observation was not admitted: \(admission)", file: file, line: line)
            throw NSError(domain: "DiscoveryObservationBufferTests", code: 1)
        }
        return lease
    }

    func testResolvedSameUUIDReplacesUnresolvedValue() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 2)
        let generation = buffer.start()
        let lease = try accepted(buffer.begin(key: key(), generation: generation))
        let unresolved = device(port: 0)
        let resolved = device(recordID: unresolved.id, port: 5901)
        XCTAssertNotEqual(unresolved, resolved, "DiscoveredDevice value equality does not provide latest-update semantics.")
        XCTAssertTrue(buffer.enqueue(unresolved, lease: lease))
        XCTAssertTrue(buffer.enqueue(resolved, lease: lease))

        let updates = buffer.takePending()
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.device.ipv4, "192.0.2.10")
        XCTAssertEqual(updates.first?.device.portMap[BonjourInteropContract.remoteControlServiceType], 5901)
        XCTAssertFalse(buffer.hasPendingUpdates)
    }

    func testLaterChangedObservationWinsOverEarlierLateResolution() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 2)
        let generation = buffer.start()
        let first = try accepted(buffer.begin(key: key(), generation: generation))
        let second = try accepted(buffer.begin(key: key(), generation: generation))
        var latest = device(port: 5902)
        latest.modelName = "Current Model"
        XCTAssertTrue(buffer.enqueue(latest, lease: second))
        XCTAssertFalse(buffer.enqueue(device(port: 5901), lease: first))

        let updates = buffer.takePending()
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.device.portMap[BonjourInteropContract.remoteControlServiceType], 5902)
        XCTAssertEqual(updates.first?.device.modelName, "Current Model")
    }

    func testSameHostDifferentServicesRemainIndependentThroughBatchApplication() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 2)
        let generation = buffer.start()
        let control = try accepted(buffer.begin(key: key(), generation: generation))
        let transfer = try accepted(buffer.begin(key: key(BonjourInteropContract.fileTransferServiceType), generation: generation))
        XCTAssertTrue(buffer.enqueue(device(port: 5901), lease: control))
        XCTAssertTrue(buffer.enqueue(device(port: 8080, service: BonjourInteropContract.fileTransferServiceType), lease: transfer))
        let updates = buffer.takePending()
        XCTAssertEqual(updates.count, 2)
        let manager = DeviceDiscoveryManagerOptimized()
        manager.applyDiscoveryUpdates(Set(updates.map(\.device)), fingerprints: [:],
            localIdentity: CanonicalBonjourAdvertisementIdentity(deviceId: deviceID, protocolPublicKeyFingerprint: fingerprint))

        XCTAssertEqual(manager.discoveredDevices.count, 1)
        XCTAssertEqual(manager.discoveredDevices[0].portMap[BonjourInteropContract.remoteControlServiceType], 5901)
        XCTAssertEqual(manager.discoveredDevices[0].portMap[BonjourInteropContract.fileTransferServiceType], 8080)
        XCTAssertTrue(manager.discoveredDevices[0].isLocalDevice)
    }

    func testDrainedWorkIsInvalidatedWhenNewerObservationBegins() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 1)
        let generation = buffer.start()
        let first = try accepted(buffer.begin(key: key(), generation: generation))
        XCTAssertTrue(buffer.enqueue(device(port: 5901), lease: first))
        let drained = try XCTUnwrap(buffer.takePending().first)
        let second = try accepted(buffer.begin(key: key(), generation: generation))

        XCTAssertFalse(buffer.isCurrent(drained.lease))
        XCTAssertTrue(buffer.isCurrent(second))
    }

    func testStopRejectsLateResolutionAndClearsPendingWork() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 1)
        let generation = buffer.start()
        let lease = try accepted(buffer.begin(key: key(), generation: generation))
        XCTAssertTrue(buffer.enqueue(device(port: 5901), lease: lease))
        buffer.stop()

        XCTAssertFalse(buffer.enqueue(device(port: 5902), lease: lease))
        XCTAssertFalse(buffer.isCurrent(generation: generation))
        XCTAssertFalse(buffer.hasPendingUpdates)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.begin(key: key(), generation: generation), .staleScan)
    }

    func testRestartRejectsOldScanAndAcceptsCurrentObservation() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 1)
        let firstGeneration = buffer.start()
        let old = try accepted(buffer.begin(key: key(), generation: firstGeneration))
        buffer.stop()
        let nextGeneration = buffer.start()
        let current = try accepted(buffer.begin(key: key(), generation: nextGeneration))

        XCTAssertFalse(buffer.enqueue(device(port: 5901), lease: old))
        XCTAssertEqual(buffer.begin(key: key(), generation: firstGeneration), .staleScan)
        XCTAssertTrue(buffer.enqueue(device(port: 5902), lease: current))
        XCTAssertEqual(buffer.takePending().first?.device.portMap[BonjourInteropContract.remoteControlServiceType], 5902)
    }

    func testRemovalInvalidatesPendingAndAlreadyDrainedResolution() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 1)
        let generation = buffer.start()
        let lease = try accepted(buffer.begin(key: key(), generation: generation))
        XCTAssertTrue(buffer.enqueue(device(port: 5901), lease: lease))
        let drained = try XCTUnwrap(buffer.takePending().first)
        buffer.remove(key: key())

        XCTAssertFalse(buffer.isCurrent(drained.lease))
        XCTAssertFalse(buffer.enqueue(device(port: 5902), lease: lease))
        XCTAssertFalse(buffer.hasPendingUpdates)
        XCTAssertEqual(buffer.count, 0)
    }

    func testCapacityRejectsNewKeysWithoutPreventingKnownObservationUpdates() throws {
        var buffer = DiscoveryObservationBuffer(capacity: 1)
        let generation = buffer.start()
        let first = try accepted(buffer.begin(key: key(), generation: generation))
        XCTAssertTrue(buffer.enqueue(device(port: 5901), lease: first))
        XCTAssertEqual(buffer.begin(key: key("_other._tcp"), generation: generation), .capacityExceeded(limit: 1))
        let update = try accepted(buffer.begin(key: key(), generation: generation))
        XCTAssertTrue(buffer.enqueue(device(port: 5902), lease: update))
        XCTAssertEqual(buffer.takePending().first?.device.portMap[BonjourInteropContract.remoteControlServiceType], 5902)
        XCTAssertEqual(buffer.count, 1)
        buffer.remove(key: key())
        _ = try accepted(buffer.begin(key: key("_other._tcp"), generation: generation))
        XCTAssertEqual(buffer.count, 1)
    }

    func testRemovedIdentityTombstonePreventsLateBatchFromResurrectingDevice() {
        let manager = DeviceDiscoveryManagerOptimized()
        let localIdentity = CanonicalBonjourAdvertisementIdentity(deviceId: deviceID, protocolPublicKeyFingerprint: fingerprint)
        let initial = device(port: 5901)
        manager.applyDiscoveryUpdates([initial], fingerprints: [:], localIdentity: localIdentity)
        manager.removeDiscoveryObservation(key: key(), deviceId: deviceID.uppercased(), name: initial.name)
        manager.applyDiscoveryUpdates([device(port: 5902)], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertTrue(manager.discoveredDevices.isEmpty)
    }

    func testExistingFiveSecondRemovalTombstoneExpires() {
        let manager = DeviceDiscoveryManagerOptimized()
        let localIdentity = CanonicalBonjourAdvertisementIdentity(deviceId: deviceID, protocolPublicKeyFingerprint: fingerprint)
        manager.removeDiscoveryObservation(key: key(), deviceId: deviceID, name: "Workstation",
                                           at: Date().addingTimeInterval(-6))
        manager.applyDiscoveryUpdates([device(port: 5901)], fingerprints: [:], localIdentity: localIdentity)

        XCTAssertEqual(manager.discoveredDevices.count, 1)
        XCTAssertTrue(manager.discoveredDevices[0].isLocalDevice)
    }
}
