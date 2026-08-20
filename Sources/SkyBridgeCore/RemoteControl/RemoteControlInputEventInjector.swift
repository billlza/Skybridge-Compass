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

struct RemoteControlInputOwner: Hashable, Sendable {
    enum Transport: String, Sendable {
        case p2p
        case webRTC
    }

    let transport: Transport
    let sessionID: String
    let generation: UUID
}

enum RemoteControlInjectionMappingSnapshot: Sendable {
    case available(RemoteControlInjectionMapping)
    case missing
    case ownerConflict
}

struct RemoteControlInjectionMappingLease: Hashable, Sendable {
    let owner: RemoteControlInputOwner
    fileprivate let generation: UUID
}

/// Process-wide mapping for the one active remote-control video capture. The
/// mapping is leased to an exact transport/session/generation owner. Publishing
/// a replacement is atomic and a stale stream can clear only its own lease.
enum RemoteControlInjectionMappingStore {
    private struct OwnedMapping: Sendable {
        let lease: RemoteControlInjectionMappingLease
        let mapping: RemoteControlInjectionMapping
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: OwnedMapping?

    @discardableResult
    static func publish(
        _ mapping: RemoteControlInjectionMapping,
        for owner: RemoteControlInputOwner
    ) -> RemoteControlInjectionMappingLease {
        let lease = RemoteControlInjectionMappingLease(
            owner: owner,
            generation: UUID()
        )
        lock.lock(); defer { lock.unlock() }
        current = OwnedMapping(lease: lease, mapping: mapping)
        return lease
    }

    static func clear(_ lease: RemoteControlInjectionMappingLease) {
        lock.lock(); defer { lock.unlock() }
        guard current?.lease == lease else { return }
        current = nil
    }

    static func snapshot(
        for owner: RemoteControlInputOwner
    ) -> RemoteControlInjectionMappingSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let current else { return .missing }
        guard current.lease.owner == owner else { return .ownerConflict }
        return .available(current.mapping)
    }

    /// 逐帧驱动的发布口（CGDisplay JPEG 回退路径专用）：仅当商店中当前不是
    /// 「同 owner + 同 displayID + 同 visibleSize」时才原子替换，避免每帧生成
    /// 新租约。返回新租约；未发生替换时返回 nil（调用方保留旧租约）。
    static func publishIfChanged(
        _ mapping: RemoteControlInjectionMapping,
        for owner: RemoteControlInputOwner
    ) -> RemoteControlInjectionMappingLease? {
        lock.lock(); defer { lock.unlock() }
        if let current,
           current.lease.owner == owner,
           current.mapping.displayID == mapping.displayID,
           current.mapping.visibleSize == mapping.visibleSize {
            return nil
        }
        let lease = RemoteControlInjectionMappingLease(
            owner: owner,
            generation: UUID()
        )
        current = OwnedMapping(lease: lease, mapping: mapping)
        return lease
    }
}

struct ResolvedRemoteControlInjectionMapping: Sendable {
    let visibleSize: CGSize
    let displayBounds: CGRect
}

enum RemoteControlInjectionMappingResolution: Sendable {
    case available(ResolvedRemoteControlInjectionMapping)
    case missing
    case ownerConflict
    case invalidDisplay
}

enum RemoteControlMouseButton: Hashable, Sendable {
    case left
    case right
}

enum RemoteControlInputPostResult: Equatable, Sendable {
    case posted
    case invalidEvent
    case mappingUnavailable
    case invalidDisplay
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
    private let resolveInjectionMapping: (RemoteControlInputOwner) -> RemoteControlInjectionMappingResolution
    private let postMouseEvent: (RemoteMouseEvent, CGPoint, RemoteControlMouseButton?) -> Bool
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
        resolveInjectionMapping: @escaping (RemoteControlInputOwner) -> RemoteControlInjectionMappingResolution = {
            RemoteControlInputEventInjector.resolveInjectionMapping(for: $0)
        },
        postMouseEvent: @escaping (RemoteMouseEvent, CGPoint, RemoteControlMouseButton?) -> Bool = {
            RemoteControlInputEventInjector.postMouseEvent($0, at: $1, draggingButton: $2)
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
        self.resolveInjectionMapping = resolveInjectionMapping
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

        let mapping: ResolvedRemoteControlInjectionMapping
        switch resolveInjectionMapping(owner) {
        case .available(let resolvedMapping):
            mapping = resolvedMapping
        case .missing:
            // 采集重启窗口内旧流 stop() 先清映射、新映射尚未发布：已跟踪的
            // button-up 绝不能因此被丢弃，否则 pressedMouseStates 永久卡住、
            // 后续 mouseMoved 全部变成拖拽。补发合成 release（释放合成按键
            // 严格安全于让它保持按下）；Down/位置事件仍照常拒绝。
            if Self.isMouseButtonUp(event.type), let button {
                return postTrackedReleaseWithoutMapping(event: event, button: button)
            }
            return .mappingUnavailable
        case .ownerConflict:
            return .ownerConflict
        case .invalidDisplay:
            // 显示器在按住期间失效（拔线/重配）同样不能丢弃已跟踪的 button-up。
            if Self.isMouseButtonUp(event.type), let button {
                return postTrackedReleaseWithoutMapping(event: event, button: button)
            }
            return .invalidDisplay
        }
        guard event.x >= 0,
              event.y >= 0,
              event.x < Double(mapping.visibleSize.width),
              event.y < Double(mapping.visibleSize.height) else {
            // 采集尺寸在按住期间变化（分辨率切换）会让在途 button-up 落在旧坐标
            // 空间之外；已跟踪的 release 用按下时注入点补发，不得丢弃。
            if Self.isMouseButtonUp(event.type), let button {
                return postTrackedReleaseWithoutMapping(event: event, button: button)
            }
            return .invalidEvent
        }
        let injectionPoint = RemoteControlInputEventInjector.mouseInjectionPoint(
            for: event,
            mapping: mapping
        )
        guard injectionPoint.x.isFinite, injectionPoint.y.isFinite else {
            return .invalidEvent
        }
        guard ensureAccessibilityPermission() else {
            return .permissionDenied
        }
        let draggingButton = event.type == .mouseMoved ? activeDragButton() : nil
        guard postMouseEvent(event, injectionPoint, draggingButton) else {
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

        switch resolveInjectionMapping(owner) {
        case .available:
            break
        case .missing:
            // 释放合成键不需要坐标：已跟踪的 keyUp 绝不能因映射缺失被丢弃，
            // 否则合成按键保持按下并持续自动重复，与鼠标卡键同类。
            if event.type == .keyUp {
                return postTrackedKeyReleaseWithoutMapping(event.keyCode)
            }
            return .mappingUnavailable
        case .ownerConflict:
            return .ownerConflict
        case .invalidDisplay:
            if event.type == .keyUp {
                return postTrackedKeyReleaseWithoutMapping(event.keyCode)
            }
            return .invalidDisplay
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

    /// 无映射时补发已跟踪按键的合成 button-up。坐标优先用按下时记录的注入点
    /// （已按当时映射换算为全局点坐标），仅在异常缺失时退回事件透传坐标。
    /// 与 releaseAll 相同：先清跟踪状态再 post，保证清理幂等。
    private func postTrackedReleaseWithoutMapping(
        event: RemoteMouseEvent,
        button: RemoteControlMouseButton
    ) -> RemoteControlInputPostResult {
        let pressedState = pressedMouseStates.removeValue(forKey: button)
        pressedControlOrder.removeAll { $0 == .mouse(button) }
        clearOwnerWhenNoControlsRemain()
        let releasePoint = pressedState?.injectionPoint
            ?? CGPoint(x: event.x, y: event.y)
        let clickCount = pressedState?.clickCount
            ?? max(1, min(event.clickCount ?? 1, 2))
        guard ensureAccessibilityPermission() else {
            return .permissionDenied
        }
        guard postMouseButtonRelease(button, releasePoint, clickCount) else {
            return .injectionFailed
        }
        return .posted
    }

    /// 无映射/显示失效时补发已跟踪按键的合成 keyUp。释放合成键不需要坐标。
    /// 与 releaseAll 相同：先清跟踪状态再 post，保证清理幂等。
    private func postTrackedKeyReleaseWithoutMapping(_ keyCode: Int) -> RemoteControlInputPostResult {
        pressedKeys.remove(keyCode)
        pressedControlOrder.removeAll { $0 == .key(keyCode) }
        clearOwnerWhenNoControlsRemain()
        guard ensureAccessibilityPermission() else {
            return .permissionDenied
        }
        guard postKeyboardRelease(keyCode) else {
            return .injectionFailed
        }
        return .posted
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
    static func resolveInjectionMapping(
        for owner: RemoteControlInputOwner
    ) -> RemoteControlInjectionMappingResolution {
        let mapping: RemoteControlInjectionMapping
        switch RemoteControlInjectionMappingStore.snapshot(for: owner) {
        case .available(let availableMapping):
            mapping = availableMapping
        case .missing:
            return .missing
        case .ownerConflict:
            return .ownerConflict
        }

        guard mapping.visibleSize.width.isFinite,
              mapping.visibleSize.height.isFinite,
              mapping.visibleSize.width > 0,
              mapping.visibleSize.height > 0,
              CGDisplayIsOnline(mapping.displayID) != 0,
              CGDisplayIsActive(mapping.displayID) != 0 else {
            return .invalidDisplay
        }
        let bounds = CGDisplayBounds(mapping.displayID)
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return .invalidDisplay
        }
        return .available(
            ResolvedRemoteControlInjectionMapping(
                visibleSize: mapping.visibleSize,
                displayBounds: bounds
            )
        )
    }

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
        at point: CGPoint,
        draggingButton: RemoteControlMouseButton? = nil
    ) -> Bool {
        guard event.x.isFinite,
              event.y.isFinite,
              event.timestamp.isFinite,
              point.x.isFinite,
              point.y.isFinite else {
            return false
        }
        // Viewer input and stream-side cursor/damage telemetry already share a top-left
        // display coordinate space. Do not flip Y again on injection, or taps in the
        // upper half land in the lower half (and vice versa).
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

    static func mouseInjectionPoint(
        for event: RemoteMouseEvent,
        mapping: ResolvedRemoteControlInjectionMapping
    ) -> CGPoint {
        // CGDisplayBounds 与 CGEvent 注入共用「左上原点、Y 向下」的全局显示点坐标系，
        // 与控制端帧坐标系一致，无需再次翻转 Y（见 postMouseEvent 注释）。
        let scaleX = Double(mapping.displayBounds.width) / Double(mapping.visibleSize.width)
        let scaleY = Double(mapping.displayBounds.height) / Double(mapping.visibleSize.height)
        let globalX = Double(mapping.displayBounds.minX)
            + event.x * scaleX
        let globalY = Double(mapping.displayBounds.minY)
            + event.y * scaleY
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
