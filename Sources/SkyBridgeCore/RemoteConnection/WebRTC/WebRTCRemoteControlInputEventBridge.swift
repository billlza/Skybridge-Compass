// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
import Foundation

enum WebRTCRemoteControlInputEventBridge {
    static func handleMouseEvent(_ event: MouseEventWire) {
        guard let remoteEvent = remoteMouseEvent(from: event),
              RemoteControlInputEventInjector.ensureAccessibilityPermission() else {
            return
        }
        RemoteControlInputEventInjector.postMouseEvent(remoteEvent)
    }

    static func handleKeyboardEvent(_ event: KeyboardEventWire) {
        guard let remoteEvent = remoteKeyboardEvent(from: event),
              RemoteControlInputEventInjector.ensureAccessibilityPermission() else {
            return
        }
        RemoteControlInputEventInjector.postKeyboardEvent(remoteEvent)
    }

    static func remoteMouseEvent(from event: MouseEventWire) -> RemoteMouseEvent? {
        guard let type = MouseEventType(rawValue: event.type.rawValue) else { return nil }
        return RemoteMouseEvent(
            type: type,
            x: event.x,
            y: event.y,
            timestamp: event.timestamp
        )
    }

    static func remoteKeyboardEvent(from event: KeyboardEventWire) -> RemoteKeyboardEvent? {
        guard let type = KeyboardEventType(rawValue: event.type.rawValue) else { return nil }
        return RemoteKeyboardEvent(
            type: type,
            keyCode: event.keyCode,
            timestamp: event.timestamp
        )
    }
}
#endif
