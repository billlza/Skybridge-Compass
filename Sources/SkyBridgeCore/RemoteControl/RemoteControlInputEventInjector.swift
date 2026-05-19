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

        switch event.type {
        case .mouseMoved:
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        case .leftMouseDown:
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
        case .leftMouseUp:
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
        case .rightMouseDown:
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right))
        case .rightMouseUp:
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
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
