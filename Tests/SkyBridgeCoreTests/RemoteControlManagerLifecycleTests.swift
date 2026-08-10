import XCTest
@testable import SkyBridgeCore

@MainActor
final class RemoteControlManagerLifecycleTests: XCTestCase {
    func testHandshakeFailureDoesNotKeepTransportAliveForEitherRole() {
        XCTAssertFalse(
            RemoteControlManager.shouldKeepTransportAliveAfterHandshakeFailure(for: .beingControlled)
        )
        XCTAssertFalse(
            RemoteControlManager.shouldKeepTransportAliveAfterHandshakeFailure(for: .controlling)
        )
    }

    func testRemovingControllingRolePreservesBeingControlledResources() {
        let manager = RemoteControlManager()

        manager.testingRegisterRole(.controlling, deviceId: "viewer-peer")
        manager.testingRegisterRole(.beingControlled, deviceId: "controller-peer")
        manager.testingSetViewingRenderPipelineMode(.fluid)
        manager.testingSeedBeingControlledResources(
            activeClipboardPeerId: "controller-peer",
            interactionTelemetryPeerIds: ["controller-peer"],
            screenCaptureRetryPeerIds: ["controller-peer"]
        )

        manager.testingRemoveRole(.controlling, deviceId: "viewer-peer")
        let snapshot = manager.testingRoleSnapshot

        XCTAssertFalse(snapshot.isControlling)
        XCTAssertTrue(snapshot.isBeingControlled)
        XCTAssertEqual(snapshot.controllingDeviceIds, [])
        XCTAssertEqual(snapshot.beingControlledDeviceIds, ["controller-peer"])
        XCTAssertEqual(snapshot.connectedDevices, ["controller-peer"])
        XCTAssertEqual(snapshot.currentRenderingMode, .stable)
        XCTAssertTrue(snapshot.screenSharingActive)
        XCTAssertEqual(snapshot.activeClipboardPeerId, "controller-peer")
        XCTAssertTrue(snapshot.hasScreenCaptureWatchdogTask)
        XCTAssertTrue(snapshot.screenCaptureRestartInProgress)
        XCTAssertEqual(snapshot.interactionTelemetryPeerIds, ["controller-peer"])
        XCTAssertEqual(snapshot.screenCaptureRetryPeerIds, ["controller-peer"])
    }

    func testRemovingBeingControlledRolePreservesControllingSession() {
        let manager = RemoteControlManager()

        manager.testingRegisterRole(.controlling, deviceId: "viewer-peer")
        manager.testingRegisterRole(.beingControlled, deviceId: "controller-peer")
        manager.testingSetViewingRenderPipelineMode(.fluid)
        manager.testingSeedBeingControlledResources(
            activeClipboardPeerId: "controller-peer",
            interactionTelemetryPeerIds: ["controller-peer"],
            screenCaptureRetryPeerIds: ["controller-peer"]
        )

        manager.testingRemoveRole(.beingControlled, deviceId: "controller-peer")
        let snapshot = manager.testingRoleSnapshot

        XCTAssertTrue(snapshot.isControlling)
        XCTAssertFalse(snapshot.isBeingControlled)
        XCTAssertEqual(snapshot.controllingDeviceIds, ["viewer-peer"])
        XCTAssertEqual(snapshot.beingControlledDeviceIds, [])
        XCTAssertEqual(snapshot.connectedDevices, ["viewer-peer"])
        XCTAssertEqual(snapshot.currentRenderingMode, .fluid)
        XCTAssertFalse(snapshot.screenSharingActive)
        XCTAssertNil(snapshot.activeClipboardPeerId)
        XCTAssertFalse(snapshot.hasScreenCaptureWatchdogTask)
        XCTAssertFalse(snapshot.screenCaptureRestartInProgress)
        XCTAssertEqual(snapshot.interactionTelemetryPeerIds, [])
        XCTAssertEqual(snapshot.screenCaptureRetryPeerIds, [])
    }

    func testSameDeviceIdCanExistInBothRolesWithoutDroppingRemainingRole() {
        let manager = RemoteControlManager()

        manager.testingRegisterRole(.controlling, deviceId: "shared-peer")
        manager.testingRegisterRole(.beingControlled, deviceId: "shared-peer")
        manager.testingSeedBeingControlledResources(
            activeClipboardPeerId: "shared-peer",
            interactionTelemetryPeerIds: ["shared-peer"]
        )

        manager.testingRemoveRole(.controlling, deviceId: "shared-peer")
        var snapshot = manager.testingRoleSnapshot

        XCTAssertFalse(snapshot.isControlling)
        XCTAssertTrue(snapshot.isBeingControlled)
        XCTAssertEqual(snapshot.connectedDevices, ["shared-peer"])
        XCTAssertEqual(snapshot.beingControlledDeviceIds, ["shared-peer"])
        XCTAssertTrue(snapshot.screenSharingActive)

        manager.testingRemoveRole(.beingControlled, deviceId: "shared-peer")
        snapshot = manager.testingRoleSnapshot

        XCTAssertFalse(snapshot.isControlling)
        XCTAssertFalse(snapshot.isBeingControlled)
        XCTAssertEqual(snapshot.connectedDevices, [])
        XCTAssertEqual(snapshot.beingControlledDeviceIds, [])
        XCTAssertFalse(snapshot.screenSharingActive)
        XCTAssertNil(snapshot.activeClipboardPeerId)
    }
}
