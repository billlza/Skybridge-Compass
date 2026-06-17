//
// RemoteControlInputEventInjector.swift
// SkyBridgeCore
//

import ApplicationServices
import CoreGraphics
import Foundation

/// 被采集显示器 → 鼠标注入坐标映射的快照。
///
/// 控制端发来的指针坐标位于「可见视频帧像素空间」（= 控制端 normalized[0,1] × 它收到的帧尺寸，
/// 即被控端 `onEncodedFrame` 发出的 `visibleWidth/visibleHeight`）。要正确注入，必须把它还原为
/// 本机**全局点坐标**：
///   global = CGDisplayBounds(displayID).origin + (incoming / visibleSize) × CGDisplayBounds(displayID).size
/// 这样可同时正确处理：① 采集非主屏时的原点偏移（否则点击落到主屏）；② 画质降档 / Retina 缩放下
/// 「帧像素尺寸 ≠ 显示点尺寸」的比例。对「主屏 + 满分辨率 1:1」场景，结果与旧的直通行为完全一致。
struct RemoteControlInjectionMapping: Sendable {
    let displayID: CGDirectDisplayID
    let visibleSize: CGSize
}

/// 进程内「当前活动采集会话」的注入映射单一真相。被控端任一时刻只有一个视频采集会话，鼠标注入的
/// 两条路径（P2P 与 WebRTC）注入的是同一台机器的同一被采集屏，因此共用同一映射。由
/// `ScreenCaptureKitStreamer` 在解析到实际采集显示器后发布、停止时清除（仅视频采集流参与，
/// 音频专用流 `captureVideoOutput == false` 不参与）。映射为 nil 时注入回退到旧的直通行为。
enum RemoteControlInjectionMappingStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: RemoteControlInjectionMapping?

    static func publish(_ mapping: RemoteControlInjectionMapping?) {
        lock.lock(); defer { lock.unlock() }
        current = mapping
    }

    static func snapshot() -> RemoteControlInjectionMapping? {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}

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
        // 无活动映射（单元测试 / 映射尚未发布）：保持旧的直通行为，把坐标当作全局点。
        guard let mapping = RemoteControlInjectionMappingStore.snapshot(),
              mapping.visibleSize.width > 0, mapping.visibleSize.height > 0 else {
            return CGPoint(x: event.x, y: event.y)
        }
        // CGDisplayBounds 与 CGEvent 注入共用「左上原点、Y 向下」的全局显示点坐标系，
        // 与控制端帧坐标系一致，无需再次翻转 Y（见 postMouseEvent 注释）。
        let bounds = CGDisplayBounds(mapping.displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            // 采集屏已失效（如被拔出）：回退直通，避免注入到非法坐标。
            return CGPoint(x: event.x, y: event.y)
        }
        let normalizedX = event.x / Double(mapping.visibleSize.width)
        let normalizedY = event.y / Double(mapping.visibleSize.height)
        let globalX = Double(bounds.minX) + normalizedX * Double(bounds.width)
        let globalY = Double(bounds.minY) + normalizedY * Double(bounds.height)
        return CGPoint(x: globalX, y: globalY)
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
