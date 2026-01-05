//
// RemoteInputEvents.swift
// SkyBridgeCore
//
// 统一远程输入事件模型（跨平台协议层）
// 跨平台统一的鼠标、键盘、滚动事件定义
// 使用归一化坐标（0.0-1.0）确保跨平台兼容性
//
// 注意：这些类型用于跨平台 SkyBridge Protocol，与 RemoteControlManager 中的
// 本地远程控制类型（RemoteMouseEvent, RemoteKeyboardEvent）不同
//
// Requirements: 11.1, 11.2, 11.3, 11.4
//

import Foundation

// MARK: - SkyBridge Protocol Mouse Event

/// 跨平台远程鼠标事件（SkyBridge Protocol）
/// 使用归一化坐标和修饰键，用于跨平台通信
public struct SBRemoteMouseEvent: Codable, Sendable, Equatable {
 /// 事件类型
    public let type: SBMouseEventType
 /// 归一化 X 坐标 (0.0-1.0)
    public let x: Double
 /// 归一化 Y 坐标 (0.0-1.0)
    public let y: Double
 /// 鼠标按钮（可选，用于点击事件）
    public let button: SBMouseButton?
 /// X 方向增量（用于拖拽）
    public let deltaX: Double?
 /// Y 方向增量（用于拖拽）
    public let deltaY: Double?
 /// 修饰键状态
    public let modifiers: SBKeyModifiers
 /// 时间戳
    public let timestamp: TimeInterval
    
    public init(
        type: SBMouseEventType,
        x: Double,
        y: Double,
        button: SBMouseButton? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        modifiers: SBKeyModifiers = .none,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
 // 确保坐标在有效范围内
        self.type = type
        self.x = max(0.0, min(1.0, x))
        self.y = max(0.0, min(1.0, y))
        self.button = button
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
    
 /// 验证坐标是否在有效范围内
    public var isValidCoordinate: Bool {
        x >= 0.0 && x <= 1.0 && y >= 0.0 && y <= 1.0
    }
}

/// 跨平台鼠标事件类型
public enum SBMouseEventType: String, Codable, Sendable {
 /// 鼠标移动
    case move = "mouse-move"
 /// 鼠标点击（按下+释放）
    case click = "mouse-click"
 /// 鼠标双击
    case doubleClick = "mouse-double-click"
 /// 鼠标按下
    case down = "mouse-down"
 /// 鼠标释放
    case up = "mouse-up"
 /// 鼠标滚动
    case scroll = "mouse-scroll"
}

/// 跨平台鼠标按钮
public enum SBMouseButton: String, Codable, Sendable {
 /// 左键
    case left = "left"
 /// 右键
    case right = "right"
 /// 中键
    case middle = "middle"
}

// MARK: - SkyBridge Protocol Keyboard Event

/// 跨平台远程键盘事件（SkyBridge Protocol）
public struct SBRemoteKeyboardEvent: Codable, Sendable, Equatable {
 /// 事件类型
    public let type: SBKeyboardEventType
 /// 虚拟键码
    public let keyCode: Int
 /// 按键字符（可选）
    public let key: String?
 /// 修饰键状态
    public let modifiers: SBKeyModifiers
 /// 时间戳
    public let timestamp: TimeInterval
    
    public init(
        type: SBKeyboardEventType,
        keyCode: Int,
        key: String? = nil,
        modifiers: SBKeyModifiers = .none,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.type = type
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

/// 跨平台键盘事件类型
public enum SBKeyboardEventType: String, Codable, Sendable {
 /// 按键按下
    case down = "key-down"
 /// 按键释放
    case up = "key-up"
}

// MARK: - SkyBridge Protocol Scroll Event

/// 跨平台远程滚动事件（SkyBridge Protocol）
public struct SBRemoteScrollEvent: Codable, Sendable, Equatable {
 /// X 方向滚动量
    public let deltaX: Double
 /// Y 方向滚动量
    public let deltaY: Double
 /// 修饰键状态
    public let modifiers: SBKeyModifiers
 /// 时间戳
    public let timestamp: TimeInterval
    
    public init(
        deltaX: Double,
        deltaY: Double,
        modifiers: SBKeyModifiers = .none,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.modifiers = modifiers
        self.timestamp = timestamp
    }
}

// MARK: - SkyBridge Protocol Key Modifiers

/// 跨平台键盘修饰键
public struct SBKeyModifiers: Codable, Sendable, Equatable {
 /// Ctrl 键
    public let ctrl: Bool
 /// Alt 键 (Option on Mac)
    public let alt: Bool
 /// Shift 键
    public let shift: Bool
 /// Meta 键 (Command on Mac, Windows key on Windows)
    public let meta: Bool
    
    public init(
        ctrl: Bool = false,
        alt: Bool = false,
        shift: Bool = false,
        meta: Bool = false
    ) {
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.meta = meta
    }
    
 /// 无修饰键
    public static let none = SBKeyModifiers()
    
 /// 是否有任何修饰键按下
    public var hasAnyModifier: Bool {
        ctrl || alt || shift || meta
    }
}

// MARK: - Type Aliases for Backward Compatibility

/// 远程鼠标事件（跨平台协议）- 类型别名
public typealias RemoteMouseEventProtocol = SBRemoteMouseEvent

/// 远程键盘事件（跨平台协议）- 类型别名
public typealias RemoteKeyboardEventProtocol = SBRemoteKeyboardEvent

/// 远程滚动事件（跨平台协议）- 类型别名
public typealias RemoteScrollEventProtocol = SBRemoteScrollEvent

/// 键盘修饰键（跨平台协议）- 类型别名
public typealias KeyModifiersProtocol = SBKeyModifiers
