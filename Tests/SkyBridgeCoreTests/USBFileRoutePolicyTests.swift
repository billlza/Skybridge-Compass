import Foundation
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class USBFileRoutePolicyTests: XCTestCase {
    func testUSBSessionOwnsItsPeerEvenBeforeTheFilePortHintArrives() {
        let usb = FileTransferManager.ActivePeerRoute(deviceId: "id:phone-device", deviceName: "Phone",
            ipAddress: "usb:physical-device", port: 8080, routeSource: "authenticated-usb-session",
            usbUDID: "physical-device", authenticatedConnectionID: UUID())
        let lan = FileTransferManager.ActivePeerRoute(deviceId: "id:phone-device", deviceName: "Phone",
            ipAddress: "192.0.2.1", port: 8080, routeSource: "live-bonjour-transfer")
        let other = FileTransferManager.ActivePeerRoute(deviceId: "id:other-device", deviceName: "Other",
            ipAddress: "192.0.2.2", port: 8080, routeSource: "authenticated-session")
        XCTAssertEqual(FileTransferManager.routesPreservingUSBPriority([lan, usb, other],
                                                                       usbPeerIDs: ["id:phone-device"]), [usb, other])
        XCTAssertEqual(FileTransferManager.routesPreservingUSBPriority([lan, other],
                                                                       usbPeerIDs: ["id:phone-device"]), [other])
        XCTAssertFalse(FileTransferManager.shouldAwaitLiveTransferRoute(routes: [usb],
                        matchingPeerIds: ["id:phone-device"], discoveredDevices: []))
    }
}
