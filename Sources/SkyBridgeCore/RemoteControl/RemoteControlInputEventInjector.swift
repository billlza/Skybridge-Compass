// macOS-exclusive: this file is built on frameworks that exist only on macOS
// (AppKit / IOKit / ScreenCaptureKit / CoreWLAN / MetalFX / ServiceManagement /
// ApplicationServices). It is excluded from other platforms so SkyBridgeCore can be
// the single shared core for iOS as well. No behaviour changes on macOS.
#if os(macOS)
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

struct RemoteControlInputOwner: Hashable, Sendable {
    enum Transport: String, Sendable {
        case p2p
        case webRTC
    }

    let transport: Transport
    let sessionID: String
    let generation: UUID
}

enum RemoteControlMouseButton: Hashable, Sendable {
    case left
    case right
}

enum RemoteControlInputPostResult: Equatable, Sendable {
    case posted
    case invalidEvent
    case permissionDenied
    case ownerConflict
    case untrackedRelease
    case injectionFailed
}

struct RemoteControlInputReleaseResult: Equatable, Sendable {
    let trackedMouseButtonCount: Int
    let trackedKeyCount: Int
    let releasedControlCount: Int
    let failedReleaseCount: Int
    let skippedForMissingPermission: Bool

    var hadTrackedInput: Bool {
        trackedMouseButtonCount > 0 || trackedKeyCount > 0
    }
}

/// Owns the process-wide macOS HID pressed state for one exact remote-control
/// session incarnation at a time. Callers remain responsible for authenticating
/// the session and checking stream admission immediately before posting.
///
/// The coordinator is MainActor-bound so an input commit and an exact-owner
/// teardown have a single linearization order: either the Down commits first and
/// teardown observes/releases it, or teardown retires the owner first and the
/// stale Down is rejected.
@MainActor
final class RemoteControlInputLifecycleCoordinator {
    private enum PressedControl: Hashable {
        case mouse(RemoteControlMouseButton)
        case key(Int)
    }

    private struct PressedMouseState {
        let injectionPoint: CGPoint
        let clickCount: Int
    }

    static let shared = RemoteControlInputLifecycleCoordinator()

    private let ensureAccessibilityPermission: () -> Bool
    private let hasAccessibilityPermission: () -> Bool
    private let mouseInjectionPoint: (RemoteMouseEvent) -> CGPoint
    private let postMouseEvent: (RemoteMouseEvent, RemoteControlMouseButton?) -> Bool
    private let postKeyboardEvent: (RemoteKeyboardEvent) -> Bool
    private let currentPointerLocation: () -> CGPoint?
    private let postMouseButtonRelease: (RemoteControlMouseButton, CGPoint, Int) -> Bool
    private let postKeyboardRelease: (Int) -> Bool

    private var currentOwner: RemoteControlInputOwner?
    private var pressedControlOrder: [PressedControl] = []
    private var pressedMouseStates: [RemoteControlMouseButton: PressedMouseState] = [:]
    private var pressedKeys: Set<Int> = []
    private var lastSuccessfulPointerPoint: CGPoint?

    init(
        ensureAccessibilityPermission: @escaping () -> Bool = {
            RemoteControlInputEventInjector.ensureAccessibilityPermission()
        },
        hasAccessibilityPermission: @escaping () -> Bool = {
            RemoteControlInputEventInjector.hasAccessibilityPermission()
        },
        mouseInjectionPoint: @escaping (RemoteMouseEvent) -> CGPoint = {
            RemoteControlInputEventInjector.mouseInjectionPoint(for: $0)
        },
        postMouseEvent: @escaping (RemoteMouseEvent, RemoteControlMouseButton?) -> Bool = {
            RemoteControlInputEventInjector.postMouseEvent($0, draggingButton: $1)
        },
        postKeyboardEvent: @escaping (RemoteKeyboardEvent) -> Bool = {
            RemoteControlInputEventInjector.postKeyboardEvent($0)
        },
        currentPointerLocation: @escaping () -> CGPoint? = {
            RemoteControlInputEventInjector.currentPointerLocation()
        },
        postMouseButtonRelease: @escaping (RemoteControlMouseButton, CGPoint, Int) -> Bool = {
            RemoteControlInputEventInjector.postMouseButtonRelease($0, at: $1, clickCount: $2)
        },
        postKeyboardRelease: @escaping (Int) -> Bool = {
            RemoteControlInputEventInjector.postKeyboardRelease(keyCode: $0)
        }
    ) {
        self.ensureAccessibilityPermission = ensureAccessibilityPermission
        self.hasAccessibilityPermission = hasAccessibilityPermission
        self.mouseInjectionPoint = mouseInjectionPoint
        self.postMouseEvent = postMouseEvent
        self.postKeyboardEvent = postKeyboardEvent
        self.currentPointerLocation = currentPointerLocation
        self.postMouseButtonRelease = postMouseButtonRelease
        self.postKeyboardRelease = postKeyboardRelease
    }

    @discardableResult
    func postMouseEvent(
        _ event: RemoteMouseEvent,
        owner: RemoteControlInputOwner
    ) -> RemoteControlInputPostResult {
        guard event.x.isFinite, event.y.isFinite, event.timestamp.isFinite else {
            return .invalidEvent
        }

        let button = Self.mouseButton(for: event.type)
        if Self.isMouseButtonUp(event.type) {
            guard currentOwner == owner,
                  let button,
                  pressedMouseStates[button] != nil else {
                return .untrackedRelease
            }
        } else if hasConflictingPressedOwner(owner) {
            return .ownerConflict
        }

        guard ensureAccessibilityPermission() else {
            return .permissionDenied
        }
        let injectionPoint = mouseInjectionPoint(event)
        guard injectionPoint.x.isFinite, injectionPoint.y.isFinite else {
            return .invalidEvent
        }
        let draggingButton = event.type == .mouseMoved ? activeDragButton() : nil
        guard postMouseEvent(event, draggingButton) else {
            return .injectionFailed
        }

        currentOwner = owner
        lastSuccessfulPointerPoint = injectionPoint
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard let button else { return .posted }
            if pressedMouseStates[button] == nil {
                pressedControlOrder.append(.mouse(button))
            }
            pressedMouseStates[button] = PressedMouseState(
                injectionPoint: injectionPoint,
                clickCount: max(1, min(event.clickCount ?? 1, 2))
            )
        case .leftMouseUp, .rightMouseUp:
            guard let button else { return .posted }
            pressedMouseStates.removeValue(forKey: button)
            pressedControlOrder.removeAll { $0 == .mouse(button) }
            clearOwnerWhenNoControlsRemain()
        case .mouseMoved, .scrollUp, .scrollDown:
            break
        }
        return .posted
    }

    @discardableResult
    func postKeyboardEvent(
        _ event: RemoteKeyboardEvent,
        owner: RemoteControlInputOwner
    ) -> RemoteControlInputPostResult {
        guard event.timestamp.isFinite, UInt16(exactly: event.keyCode) != nil else {
            return .invalidEvent
        }
        if event.type == .keyUp {
            guard currentOwner == owner, pressedKeys.contains(event.keyCode) else {
                return .untrackedRelease
            }
        } else if hasConflictingPressedOwner(owner) {
            return .ownerConflict
        }

        guard ensureAccessibilityPermission() else {
            return .permissionDenied
        }
        guard postKeyboardEvent(event) else {
            return .injectionFailed
        }

        currentOwner = owner
        switch event.type {
        case .keyDown:
            if pressedKeys.insert(event.keyCode).inserted {
                pressedControlOrder.append(.key(event.keyCode))
            }
        case .keyUp:
            pressedKeys.remove(event.keyCode)
            pressedControlOrder.removeAll { $0 == .key(event.keyCode) }
            clearOwnerWhenNoControlsRemain()
        }
        return .posted
    }

    /// Releases only the controls committed by the exact owner. The tracked
    /// state is taken and cleared before any CGEvent post so repeated cleanup is
    /// idempotent even if an individual synthetic release cannot be created.
    @discardableResult
    func releaseAll(
        for owner: RemoteControlInputOwner
    ) -> RemoteControlInputReleaseResult {
        guard currentOwner == owner else {
            return RemoteControlInputReleaseResult(
                trackedMouseButtonCount: 0,
                trackedKeyCount: 0,
                releasedControlCount: 0,
                failedReleaseCount: 0,
                skippedForMissingPermission: false
            )
        }

        let controlOrder = pressedControlOrder
        let mouseStates = pressedMouseStates
        let fallbackPointerPoint = lastSuccessfulPointerPoint
        let trackedKeyCount = pressedKeys.count
        let trackedMouseButtonCount = mouseStates.count
        pressedControlOrder.removeAll(keepingCapacity: true)
        pressedMouseStates.removeAll(keepingCapacity: true)
        pressedKeys.removeAll(keepingCapacity: true)
        lastSuccessfulPointerPoint = nil
        currentOwner = nil

        guard !controlOrder.isEmpty else {
            return RemoteControlInputReleaseResult(
                trackedMouseButtonCount: 0,
                trackedKeyCount: 0,
                releasedControlCount: 0,
                failedReleaseCount: 0,
                skippedForMissingPermission: false
            )
        }
        guard hasAccessibilityPermission() else {
            return RemoteControlInputReleaseResult(
                trackedMouseButtonCount: trackedMouseButtonCount,
                trackedKeyCount: trackedKeyCount,
                releasedControlCount: 0,
                failedReleaseCount: 0,
                skippedForMissingPermission: true
            )
        }

        let livePointer = currentPointerLocation().flatMap { point in
            point.x.isFinite && point.y.isFinite ? point : nil
        }
        var releasedControlCount = 0
        var failedReleaseCount = 0
        for control in controlOrder.reversed() {
            let posted: Bool
            switch control {
            case .mouse(let button):
                guard let state = mouseStates[button] else { continue }
                let point = livePointer ?? fallbackPointerPoint ?? state.injectionPoint
                posted = postMouseButtonRelease(button, point, state.clickCount)
            case .key(let keyCode):
                posted = postKeyboardRelease(keyCode)
            }
            if posted {
                releasedControlCount += 1
            } else {
                failedReleaseCount += 1
            }
        }
        return RemoteControlInputReleaseResult(
            trackedMouseButtonCount: trackedMouseButtonCount,
            trackedKeyCount: trackedKeyCount,
            releasedControlCount: releasedControlCount,
            failedReleaseCount: failedReleaseCount,
            skippedForMissingPermission: false
        )
    }

    private func hasConflictingPressedOwner(_ owner: RemoteControlInputOwner) -> Bool {
        guard let currentOwner, currentOwner != owner else { return false }
        return !pressedControlOrder.isEmpty
    }

    private func clearOwnerWhenNoControlsRemain() {
        if pressedControlOrder.isEmpty {
            currentOwner = nil
        }
    }

    /// Selects the most recently pressed mouse button that is still active.
    /// This preserves native macOS drag semantics if both buttons are down,
    /// while falling back to ordinary pointer motion when no button is held.
    private func activeDragButton() -> RemoteControlMouseButton? {
        for control in pressedControlOrder.reversed() {
            guard case .mouse(let button) = control,
                  pressedMouseStates[button] != nil else {
                continue
            }
            return button
        }
        return nil
    }

    private static func mouseButton(for type: MouseEventType) -> RemoteControlMouseButton? {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return .left
        case .rightMouseDown, .rightMouseUp:
            return .right
        case .mouseMoved, .scrollUp, .scrollDown:
            return nil
        }
    }

    private static func isMouseButtonUp(_ type: MouseEventType) -> Bool {
        type == .leftMouseUp || type == .rightMouseUp
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

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func postMouseEvent(
        _ event: RemoteMouseEvent,
        draggingButton: RemoteControlMouseButton? = nil
    ) -> Bool {
        guard event.x.isFinite, event.y.isFinite, event.timestamp.isFinite else {
            return false
        }
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
            let button = draggingButton == .right ? CGMouseButton.right : .left
            return post(
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: pointerMotionEventType(draggingButton: draggingButton),
                    mouseCursorPosition: point,
                    mouseButton: button
                )
            )
        case .leftMouseDown:
            return post(mouseEvent(.leftMouseDown, button: .left))
        case .leftMouseUp:
            return post(mouseEvent(.leftMouseUp, button: .left))
        case .rightMouseDown:
            return post(mouseEvent(.rightMouseDown, button: .right))
        case .rightMouseUp:
            return post(mouseEvent(.rightMouseUp, button: .right))
        case .scrollUp:
            return post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
        case .scrollDown:
            return post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0))
        }
    }

    static func pointerMotionEventType(
        draggingButton: RemoteControlMouseButton?
    ) -> CGEventType {
        switch draggingButton {
        case .left:
            return .leftMouseDragged
        case .right:
            return .rightMouseDragged
        case nil:
            return .mouseMoved
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

    @discardableResult
    static func postKeyboardEvent(_ event: RemoteKeyboardEvent) -> Bool {
        guard event.timestamp.isFinite, let code = CGKeyCode(exactly: event.keyCode) else {
            return false
        }
        let down = event.type == .keyDown
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        return post(cgEvent)
    }

    static func currentPointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    @discardableResult
    static func postMouseButtonRelease(
        _ button: RemoteControlMouseButton,
        at point: CGPoint,
        clickCount: Int
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: cgButton
        )
        cgEvent?.setIntegerValueField(
            .mouseEventClickState,
            value: Int64(max(1, min(clickCount, 2)))
        )
        return post(cgEvent)
    }

    @discardableResult
    static func postKeyboardRelease(keyCode: Int) -> Bool {
        postKeyboardEvent(
            RemoteKeyboardEvent(
                type: .keyUp,
                keyCode: keyCode,
                timestamp: Date().timeIntervalSince1970
            )
        )
    }

    @discardableResult
    private static func post(_ cgEvent: CGEvent?) -> Bool {
        guard let cgEvent else { return false }
        cgEvent.post(tap: .cghidEventTap)
        return true
    }
}
#endif
