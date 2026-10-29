#if os(macOS)
import Foundation
import XCTest
@testable import SkyBridgeAppleTransport
@testable import SkyBridgeCore

@MainActor
final class AndroidUSBReenumerationTests: XCTestCase {
    private func device(registry: UInt64? = 101, location: UInt32 = 200,
                        vendor: UInt16 = 0x18d1, product: UInt16 = 0x2d01) -> USBDeviceInfo {
        USBDeviceInfo(deviceID: "same-hardware-serial", name: "Same name", deviceType: .androidDevice,
            vendorID: vendor, productID: product, serialNumber: "same-hardware-serial",
            isMFiCertified: false, connectionInterface: "USB", capabilities: [],
            registryEntryID: registry, locationID: location)
    }
    private func prepared() -> AndroidUSBPreparedAttachment {
        .init(source: device(registry: 100, vendor: 0x04e8, product: 0x6860), locationID: 200,
              attachmentNonce: UUID(), linkProfile: .epochV2, receipt: USBHostAccessoryReceipt(deviceRegistryID: 100,
              operationStarted: true, protocolVersion: 2, requestedLinkProfile: .epochV2, identificationAttempted: 6,
              identificationCompleted: 6, startRequested: true, startCompletionConfirmed: true,
              referencesReleased: true, operationFailure: nil, cleanupFailure: nil))
    }
    func testSamePortNewRegistryAccessoryIsSelected() throws {
        for product: UInt16 in [0x2d00, 0x2d01] {
            let found = try AndroidUSBConnectionRuntime.reenumeratedDevice(
                [device(location: 300), device(product: product)], prepared: prepared())
            XCTAssertEqual(found?.registryEntryID, 101)
            XCTAssertEqual(found?.locationID, 200)
        }
    }
    func testReopenSelectsOnlyTheStillCurrentAccessoryGeneration() throws {
        for product: UInt16 in [0x2d00, 0x2d01] {
            let selected = device(product: product)
            let current = try AndroidUSBConnectionRuntime.currentAccessoryDevice(
                [device(registry: 999, location: 300), selected], selected: selected)
            XCTAssertEqual(current.registryEntryID, selected.registryEntryID)
            XCTAssertEqual(current.locationID, selected.locationID)
        }
    }
    func testReopenRejectsMissingChangedAndAmbiguousAttachmentsDespiteMatchingSerial() {
        let selected = device()
        for candidates in [[], [device(registry: 102)], [device(location: 300)],
                           [device(product: 0x2d00)], [device(vendor: 0x04e8, product: 0x6860)],
                           [device(), device(registry: 102)]] {
            XCTAssertThrowsError(try AndroidUSBConnectionRuntime.currentAccessoryDevice(candidates, selected: selected))
        }
        for invalid in [device(registry: nil), device(registry: 0), device(location: 0),
                        device(vendor: 0x04e8, product: 0x6860)] {
            XCTAssertThrowsError(try AndroidUSBConnectionRuntime.currentAccessoryDevice([selected], selected: invalid))
        }
    }
    func testNameSerialOrOtherPortCannotSubstituteAttachment() throws {
        XCTAssertNil(try AndroidUSBConnectionRuntime.reenumeratedDevice(
            [device(location: 300), device(vendor: 0x04e8, product: 0x6860)], prepared: prepared()))
    }
    func testSameOrMissingRegistryIsRejected() {
        for registry: UInt64? in [nil, 0, 100] {
            XCTAssertThrowsError(try AndroidUSBConnectionRuntime.reenumeratedDevice(
                [device(registry: registry)], prepared: prepared()))
        }
    }
    func testAmbiguousPortIsNotDeduplicatedUsingHardwareSerial() {
        XCTAssertThrowsError(try AndroidUSBConnectionRuntime.reenumeratedDevice(
            [device(), device(registry: 102)], prepared: prepared()))
    }
}
#endif
