#if os(macOS)
import CSkyBridgeUSBHost
import Foundation
import os
import XCTest
@testable import SkyBridgeAppleTransport
@testable import SkyBridgeCore

@MainActor
final class AndroidUSBPreparationTests: XCTestCase {
    private enum Failure: Error { case revoked, factory, fixtureTimeout, expectedFailure }

    private final class Driver: USBHostAccessoryDriver {
        struct State: Sendable {
            var calls = 0
            var entered = false
            var block = false
            var released = true
            var confirmStart = true
            var cleanupFailure: USBHostFailure?
        }
        let state: OSAllocatedUnfairLock<State>
        let release = DispatchSemaphore(value: 0)
        init(_ configure: (inout State) -> Void = { _ in }) {
            var initial = State(); configure(&initial)
            state = OSAllocatedUnfairLock(initialState: initial)
        }
        func run(registryID: UInt64, nonce: UUID?, authorize: @escaping @Sendable () -> Bool) -> USBHostAccessoryReceipt {
            let blocked = state.withLock { value in
                value.calls += 1; value.entered = true; return value.block
            }
            if blocked { precondition(release.wait(timeout: .now() + 5) == .success) }
            let admitted = authorize(), snapshot = state.withLock { $0 }
            let started = admitted && nonce != nil && snapshot.confirmStart
            return USBHostAccessoryReceipt(deviceRegistryID: registryID, operationStarted: true,
                protocolVersion: admitted ? 2 : 0, identificationAttempted: started ? 6 : 0,
                identificationCompleted: started ? 6 : 0, startRequested: started,
                startCompletionConfirmed: started, referencesReleased: snapshot.released,
                operationFailure: admitted ? nil : USBHostFailure(SBUSBResult(status: SB_USB_CANCELLED,
                    phase: SB_USB_PHASE_ACCESSORY_QUERY, domain: SB_USB_DOMAIN_NONE,
                    nativeCode: 0, bytesTransferred: 0, byteCountKnown: false)), cleanupFailure: snapshot.cleanupFailure)
        }
    }

    private func device(registryID: UInt64? = 123, locationID: UInt32? = 456,
                        type: USBCDeviceType = .androidDevice) -> USBDeviceInfo {
        USBDeviceInfo(deviceID: "selected-attachment", name: "Selected Android", deviceType: type,
            vendorID: 0x04e8, productID: 0x6860, serialNumber: nil, isMFiCertified: false,
            connectionInterface: "USB", capabilities: [], registryEntryID: registryID, locationID: locationID)
    }
    private func manager(_ driver: Driver) -> USBCConnectionManager {
        USBCConnectionManager { registryID, nonce, authority in
            USBHostAccessoryPreparation(deviceRegistryID: registryID, mode: .start(attachmentNonce: nonce),
                authority: authority, factory: { driver })
        }
    }
    private func waitForEntry(_ driver: Driver) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !driver.state.withLock({ $0.entered }) {
            guard ContinuousClock.now < deadline else { throw Failure.fixtureTimeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func failure(_ action: @MainActor () async throws -> Void) async throws -> any Error {
        do { try await action() } catch { return error }
        XCTFail("Expected an explicit failure"); throw Failure.expectedFailure
    }

    func testPhysicalRoutingIsRequiredBeforeCreatingNativeOwner() async throws {
        var factories = 0
        let manager = USBCConnectionManager { _, _, _ in factories += 1; throw Failure.factory }
        for candidate in [device(registryID: nil), device(registryID: 0), device(locationID: nil),
                          device(locationID: 0), device(type: .externalDrive)] {
            let error = try await failure { _ = try await manager.prepareAndroidUSB(candidate, requireAttemptCurrent: {}) }
            XCTAssertEqual(error as? USBHostByteError, .invalidRegistryEntry)
        }
        XCTAssertEqual(factories, 0)
        XCTAssertFalse(manager.isPreparingAndroidUSB)
        XCTAssertFalse(manager.androidUSBCleanupBlocked)
    }

    func testRevokedAuthorityIsRejectedBeforeFactory() async throws {
        var factories = 0
        let manager = USBCConnectionManager { _, _, _ in factories += 1; throw Failure.factory }
        let error = try await failure {
            _ = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: { throw Failure.revoked })
        }
        XCTAssertTrue(error is Failure)
        XCTAssertEqual(factories, 0)
        XCTAssertFalse(manager.isPreparingAndroidUSB)
    }

    func testPreparationPreservesSelectedRoutingAndFreshAttachmentNonce() async throws {
        let driver = Driver(), manager = manager(driver)
        let first = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: {})
        let second = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: {})
        XCTAssertEqual(first.source.registryEntryID, 123)
        XCTAssertEqual(first.receipt.deviceRegistryID, 123)
        XCTAssertEqual(first.locationID, 456)
        XCTAssertNotEqual(first.attachmentNonce, second.attachmentNonce)
        XCTAssertEqual(first.receipt.identificationCompleted, 6)
        XCTAssertTrue(first.receipt.startCompletionConfirmed)
        XCTAssertFalse(manager.isPreparingAndroidUSB)
        XCTAssertFalse(manager.androidUSBCleanupBlocked)
        XCTAssertEqual(driver.state.withLock { $0.calls }, 2)
    }

    func testQueryReceiptCannotBecomePreparedAttachment() async throws {
        let manager = manager(Driver { $0.confirmStart = false })
        let error = try await failure { _ = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: {}) }
        XCTAssertEqual(error as? USBHostByteError, .notReady)
        XCTAssertEqual(manager.androidUSBPreparationReceipt?.startCompletionConfirmed, false)
        XCTAssertFalse(manager.androidUSBCleanupBlocked)
    }

    func testCancellationAndCleanupObserverDoNotAdmitAnotherLiveOwner() async throws {
        let driver = Driver { $0.block = true }, manager = manager(driver)
        let selected = device()
        let original = Task { try await manager.prepareAndroidUSB(selected, requireAttemptCurrent: {}) }
        try await waitForEntry(driver)
        manager.cancelAndroidUSBPreparation()
        let observer = Task { try await manager.awaitAndroidUSBCleanup() }
        await Task.yield()
        let overlapping = try await failure { _ = try await manager.prepareAndroidUSB(selected, requireAttemptCurrent: {}) }
        XCTAssertEqual(overlapping as? USBHostByteError, .alreadyStarted)
        XCTAssertTrue(manager.isPreparingAndroidUSB)
        driver.release.signal()
        let error = try await failure { _ = try await original.value }
        XCTAssertTrue((error as? USBHostAccessoryPreparationFailure)?.cause is CancellationError)
        try await observer.value
        XCTAssertFalse(manager.isPreparingAndroidUSB)
        XCTAssertFalse(manager.androidUSBCleanupBlocked)
        XCTAssertEqual(driver.state.withLock { $0.calls }, 1)
    }

    func testUnconfirmedReleaseRetainsAdmissionAfterWorkerExit() async throws {
        let driver = Driver { $0.released = false }, manager = manager(driver)
        let error = try await failure { _ = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: {}) }
        XCTAssertTrue(error is AndroidUSBPreparationCleanupFailure)
        XCTAssertFalse(manager.isPreparingAndroidUSB)
        XCTAssertTrue(manager.androidUSBCleanupBlocked)
        XCTAssertEqual(manager.androidUSBPreparationReceipt?.referencesReleased, false)
        let cleanup = try await failure { try await manager.awaitAndroidUSBCleanup() }
        XCTAssertEqual(cleanup as? USBHostByteError, .cleanupUnconfirmed)
        let retry = try await failure { _ = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: {}) }
        XCTAssertEqual(retry as? USBHostByteError, .alreadyStarted)
        XCTAssertEqual(driver.state.withLock { $0.calls }, 1)
    }

    func testConfirmedReleaseDoesNotHideNativeCleanupError() async throws {
        let native = USBHostFailure(SBUSBResult(status: SB_USB_NATIVE_FAILURE, phase: SB_USB_PHASE_RELEASE,
            domain: SB_USB_DOMAIN_IORETURN, nativeCode: -1, bytesTransferred: 0, byteCountKnown: false))
        let manager = manager(Driver { $0.cleanupFailure = native })
        let error = try await failure { _ = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: {}) }
        let failure = try XCTUnwrap(error as? AndroidUSBPreparationCleanupFailure)
        XCTAssertEqual((failure.cleanup as? USBHostFailure)?.nativeCode, -1)
        XCTAssertEqual(manager.androidUSBPreparationReceipt?.referencesReleased, true)
        XCTAssertFalse(manager.androidUSBCleanupBlocked)
    }

    func testFactoryFailureDoesNotLeaveActivePreparation() async throws {
        let manager = USBCConnectionManager { _, _, _ in throw Failure.factory }
        _ = try await failure { _ = try await manager.prepareAndroidUSB(device(), requireAttemptCurrent: {}) }
        XCTAssertFalse(manager.isPreparingAndroidUSB)
        XCTAssertFalse(manager.androidUSBCleanupBlocked)
        XCTAssertNil(manager.androidUSBPreparationReceipt)
    }
}
#endif
