//
// RemoteControlInputEventInjector.swift
// SkyBridgeCore
//

import ApplicationServices
import CoreGraphics
import Foundation

enum RemoteControlInputEventInjector {
    static func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() { return true }
        // Trigger the system prompt; the user still grants the permission in System Settings.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        return AXIsProcessTrusted()
    }

    static func postMouseEvent(_ event: RemoteMouseEvent) {
        // Viewer input and stream-side cursor/damage telemetry already share a top-left
        // display coordinate space. Do not flip Y again on injection, or taps in the
        // upper half land in the lower half (and vice versa).
        let point = mouseInjectionPoint(for: event)
        let clickState = Int64(max(1, min(event.clickCount ?? 1, 2)))

        func mouseEvent(_ type: CGEventType, button: CGMouseButton) -> CGEvent? {
            let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            cgEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
            return cgEvent
        }

        switch event.type {
        case .mouseMoved:
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        case .leftMouseDown:
            post(mouseEvent(.leftMouseDown, button: .left))
        case .leftMouseUp:
            post(mouseEvent(.leftMouseUp, button: .left))
        case .rightMouseDown:
            post(mouseEvent(.rightMouseDown, button: .right))
        case .rightMouseUp:
            post(mouseEvent(.rightMouseUp, button: .right))
        case .scrollUp:
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
        case .scrollDown:
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0))
        }
    }

    static func mouseInjectionPoint(for event: RemoteMouseEvent) -> CGPoint {
        CGPoint(x: event.x, y: event.y)
    }

    static func postKeyboardEvent(_ event: RemoteKeyboardEvent) {
        let down = event.type == .keyDown
        let code = CGKeyCode(event.keyCode)
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        post(cgEvent)
    }

    private static func post(_ cgEvent: CGEvent?) {
        guard let cgEvent else { return }
        cgEvent.post(tap: .cghidEventTap)
    }
}
