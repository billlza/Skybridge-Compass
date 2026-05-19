import XCTest
@testable import SkyBridgeCore

final class WebRTCRemoteControlInputEventBridgeTests: XCTestCase {
    func testMouseWireEventMapsToSharedRemoteControlInputEvent() {
        let wire = MouseEventWire(
            type: .rightMouseDown,
            x: 123.5,
            y: 456.25,
            timestamp: 789
        )

        let event = WebRTCRemoteControlInputEventBridge.remoteMouseEvent(from: wire)

        XCTAssertEqual(event?.type, .rightMouseDown)
        XCTAssertEqual(event?.x, 123.5)
        XCTAssertEqual(event?.y, 456.25)
        XCTAssertEqual(event?.timestamp, 789)
    }

    func testKeyboardWireEventMapsToSharedRemoteControlInputEvent() {
        let wire = KeyboardEventWire(
            type: .keyUp,
            keyCode: 36,
            timestamp: 111
        )

        let event = WebRTCRemoteControlInputEventBridge.remoteKeyboardEvent(from: wire)

        XCTAssertEqual(event?.type, .keyUp)
        XCTAssertEqual(event?.keyCode, 36)
        XCTAssertEqual(event?.timestamp, 111)
    }

    func testCrossNetworkManagerDoesNotOwnCGEventInjectionImplementation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift"),
            encoding: .utf8
        )
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCRemoteControlInputEventBridge.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(managerSource.contains("AXIsProcessTrusted"))
        XCTAssertFalse(managerSource.contains("cghidEventTap"))
        XCTAssertFalse(managerSource.contains("CGEvent(mouseEventSource:"))
        XCTAssertTrue(managerSource.contains("WebRTCRemoteControlInputEventBridge.handleMouseEvent(evt)"))
        XCTAssertTrue(managerSource.contains("WebRTCRemoteControlInputEventBridge.handleKeyboardEvent(evt)"))
        XCTAssertTrue(bridgeSource.contains("RemoteControlInputEventInjector.postMouseEvent(remoteEvent)"))
        XCTAssertTrue(bridgeSource.contains("RemoteControlInputEventInjector.postKeyboardEvent(remoteEvent)"))
    }
}
