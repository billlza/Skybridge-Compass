//
// P2PRemoteInput.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Remote Input Events
// Requirements: 8.1, 8.2, 8.3, 8.4, 8.5
//
// ⚠️ IMPORTANT: This feature is for ENTERPRISE/DEVELOPER use only.
// App Store Review Guidelines 2.5.14 prohibits remote control of iOS devices
// in consumer apps. This code is provided for:
// - Enterprise MDM deployments
// - Developer testing tools
// - Accessibility research
//
// DO NOT enable this feature in App Store submissions.
//

import Foundation

// MARK: - Remote Input Event Types

/// 远程输入事件基础协议
public protocol P2PRemoteInputEvent: Codable, Sendable {
 /// 事件类型标识
    var eventType: P2PRemoteInputEventType { get }
    
 /// 时间戳（毫秒）
    var timestampMillis: Int64 { get }
}

/// 远程输入事件类型
public enum P2PRemoteInputEventType: String, Codable, Sendable {
    case touch = "touch"
    case keystroke = "keystroke"
    case scroll = "scroll"
    case pinch = "pinch"
    case rotation = "rotation"
    case authenticationRequired = "auth_required"
}

// MARK: - Touch Events

/// 触摸事件
public struct P2PTouchEvent: P2PRemoteInputEvent, Equatable {
    public var eventType: P2PRemoteInputEventType { .touch }
    public let timestampMillis: Int64
    
 /// 触摸阶段
    public let phase: P2PTouchPhase
    
 /// 触摸点（归一化坐标 0.0-1.0）
    public let touches: [P2PTouchPoint]
    
    public init(
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        phase: P2PTouchPhase,
        touches: [P2PTouchPoint]
    ) {
        self.timestampMillis = timestampMillis
        self.phase = phase
        self.touches = touches
    }
}

/// 触摸阶段
public enum P2PTouchPhase: String, Codable, Sendable {
    case began = "began"
    case moved = "moved"
    case stationary = "stationary"
    case ended = "ended"
    case cancelled = "cancelled"
}

/// 触摸点
public struct P2PTouchPoint: Codable, Sendable, Equatable {
 /// 触摸 ID（用于多点触控追踪）
    public let touchId: Int
    
 /// X 坐标（归一化 0.0-1.0）
    public let x: Double
    
 /// Y 坐标（归一化 0.0-1.0）
    public let y: Double
    
 /// 压力（0.0-1.0，不支持时为 1.0）
    public let force: Double
    
 /// 主要半径（点）
    public let majorRadius: Double?
    
    public init(
        touchId: Int,
        x: Double,
        y: Double,
        force: Double = 1.0,
        majorRadius: Double? = nil
    ) {
        self.touchId = touchId
        self.x = x
        self.y = y
        self.force = force
        self.majorRadius = majorRadius
    }
}

// MARK: - Keystroke Events

/// 按键事件
public struct P2PKeystrokeEvent: P2PRemoteInputEvent, Equatable {
    public var eventType: P2PRemoteInputEventType { .keystroke }
    public let timestampMillis: Int64
    
 /// 按键类型
    public let keyType: P2PKeyType
    
 /// 按键阶段
    public let phase: P2PKeyPhase
    
 /// 字符（如果是文本输入）
    public let characters: String?
    
 /// 修饰键
    public let modifiers: P2PKeyModifiers
    
    public init(
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        keyType: P2PKeyType,
        phase: P2PKeyPhase,
        characters: String? = nil,
        modifiers: P2PKeyModifiers = []
    ) {
        self.timestampMillis = timestampMillis
        self.keyType = keyType
        self.phase = phase
        self.characters = characters
        self.modifiers = modifiers
    }
}

/// 按键类型
public enum P2PKeyType: String, Codable, Sendable {
 // 特殊键
    case escape = "escape"
    case `return` = "return"
    case tab = "tab"
    case space = "space"
    case delete = "delete"
    case forwardDelete = "forward_delete"
    
 // 方向键
    case upArrow = "up_arrow"
    case downArrow = "down_arrow"
    case leftArrow = "left_arrow"
    case rightArrow = "right_arrow"
    
 // 功能键
    case home = "home"
    case end = "end"
    case pageUp = "page_up"
    case pageDown = "page_down"
    
 // 字符输入
    case character = "character"
}

/// 按键阶段
public enum P2PKeyPhase: String, Codable, Sendable {
    case down = "down"
    case up = "up"
    case repeat_ = "repeat"
}

/// 修饰键
public struct P2PKeyModifiers: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt16
    
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
    
    public static let shift = P2PKeyModifiers(rawValue: 1 << 0)
    public static let control = P2PKeyModifiers(rawValue: 1 << 1)
    public static let option = P2PKeyModifiers(rawValue: 1 << 2)
    public static let command = P2PKeyModifiers(rawValue: 1 << 3)
    public static let capsLock = P2PKeyModifiers(rawValue: 1 << 4)
    public static let function = P2PKeyModifiers(rawValue: 1 << 5)
}

// MARK: - Scroll Events

/// 滚动事件
public struct P2PScrollEvent: P2PRemoteInputEvent, Equatable {
    public var eventType: P2PRemoteInputEventType { .scroll }
    public let timestampMillis: Int64
    
 /// 滚动阶段
    public let phase: P2PScrollPhase
    
 /// X 方向滚动量（点）
    public let deltaX: Double
    
 /// Y 方向滚动量（点）
    public let deltaY: Double
    
 /// 是否为精确滚动（触控板）
    public let isPrecise: Bool
    
    public init(
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        phase: P2PScrollPhase,
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool = false
    ) {
        self.timestampMillis = timestampMillis
        self.phase = phase
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
    }
}

/// 滚动阶段
public enum P2PScrollPhase: String, Codable, Sendable {
    case began = "began"
    case changed = "changed"
    case ended = "ended"
    case cancelled = "cancelled"
    case mayBegin = "may_begin"
}

// MARK: - Pinch Events

/// 捏合手势事件
public struct P2PPinchEvent: P2PRemoteInputEvent, Equatable {
    public var eventType: P2PRemoteInputEventType { .pinch }
    public let timestampMillis: Int64
    
 /// 手势阶段
    public let phase: P2PGesturePhase
    
 /// 缩放比例（1.0 为原始大小）
    public let scale: Double
    
 /// 缩放速度
    public let velocity: Double
    
 /// 中心点 X（归一化）
    public let centerX: Double
    
 /// 中心点 Y（归一化）
    public let centerY: Double
    
    public init(
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        phase: P2PGesturePhase,
        scale: Double,
        velocity: Double = 0,
        centerX: Double,
        centerY: Double
    ) {
        self.timestampMillis = timestampMillis
        self.phase = phase
        self.scale = scale
        self.velocity = velocity
        self.centerX = centerX
        self.centerY = centerY
    }
}

/// 手势阶段
public enum P2PGesturePhase: String, Codable, Sendable {
    case began = "began"
    case changed = "changed"
    case ended = "ended"
    case cancelled = "cancelled"
}

// MARK: - Rotation Events

/// 旋转手势事件
public struct P2PRotationEvent: P2PRemoteInputEvent, Equatable {
    public var eventType: P2PRemoteInputEventType { .rotation }
    public let timestampMillis: Int64
    
 /// 手势阶段
    public let phase: P2PGesturePhase
    
 /// 旋转角度（弧度）
    public let rotation: Double
    
 /// 旋转速度
    public let velocity: Double
    
 /// 中心点 X（归一化）
    public let centerX: Double
    
 /// 中心点 Y（归一化）
    public let centerY: Double
    
    public init(
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        phase: P2PGesturePhase,
        rotation: Double,
        velocity: Double = 0,
        centerX: Double,
        centerY: Double
    ) {
        self.timestampMillis = timestampMillis
        self.phase = phase
        self.rotation = rotation
        self.velocity = velocity
        self.centerX = centerX
        self.centerY = centerY
    }
}

// MARK: - Authentication Required Event

/// 认证请求事件（Face ID/Touch ID）
public struct P2PAuthenticationRequiredEvent: P2PRemoteInputEvent, Equatable {
    public var eventType: P2PRemoteInputEventType { .authenticationRequired }
    public let timestampMillis: Int64
    
 /// 认证类型
    public let authType: P2PAuthenticationType
    
 /// 认证原因描述
    public let reason: String
    
 /// 请求 ID（用于响应匹配）
    public let requestId: UUID
    
    public init(
        timestampMillis: Int64 = P2PTimestamp.nowMillis,
        authType: P2PAuthenticationType,
        reason: String,
        requestId: UUID = UUID()
    ) {
        self.timestampMillis = timestampMillis
        self.authType = authType
        self.reason = reason
        self.requestId = requestId
    }
}

/// 认证类型
public enum P2PAuthenticationType: String, Codable, Sendable {
    case faceID = "face_id"
    case touchID = "touch_id"
    case passcode = "passcode"
    case devicePasscode = "device_passcode"
}

/// 认证响应
public struct P2PAuthenticationResponse: Codable, Sendable, Equatable {
 /// 请求 ID
    public let requestId: UUID
    
 /// 是否成功
    public let success: Bool
    
 /// 错误信息（如果失败）
    public let errorMessage: String?
    
 /// 时间戳
    public let timestampMillis: Int64
    
    public init(
        requestId: UUID,
        success: Bool,
        errorMessage: String? = nil,
        timestampMillis: Int64 = P2PTimestamp.nowMillis
    ) {
        self.requestId = requestId
        self.success = success
        self.errorMessage = errorMessage
        self.timestampMillis = timestampMillis
    }
}

// MARK: - Remote Input Encoder

/// 远程输入事件编码器
public struct P2PRemoteInputEncoder {
    
    private let encoder: JSONEncoder
    
    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
    }
    
 /// 编码触摸事件
    public func encode(_ event: P2PTouchEvent) throws -> Data {
        try encoder.encode(event)
    }
    
 /// 编码按键事件
    public func encode(_ event: P2PKeystrokeEvent) throws -> Data {
        try encoder.encode(event)
    }
    
 /// 编码滚动事件
    public func encode(_ event: P2PScrollEvent) throws -> Data {
        try encoder.encode(event)
    }
    
 /// 编码捏合事件
    public func encode(_ event: P2PPinchEvent) throws -> Data {
        try encoder.encode(event)
    }
    
 /// 编码旋转事件
    public func encode(_ event: P2PRotationEvent) throws -> Data {
        try encoder.encode(event)
    }
    
 /// 编码认证请求事件
    public func encode(_ event: P2PAuthenticationRequiredEvent) throws -> Data {
        try encoder.encode(event)
    }
}

// MARK: - Remote Input Decoder

/// 远程输入事件解码器
public struct P2PRemoteInputDecoder {
    
    private let decoder: JSONDecoder
    
    public init() {
        decoder = JSONDecoder()
    }
    
 /// 解码事件类型
    public func decodeEventType(from data: Data) throws -> P2PRemoteInputEventType {
        struct EventTypeWrapper: Decodable {
            let eventType: P2PRemoteInputEventType
        }
        let wrapper = try decoder.decode(EventTypeWrapper.self, from: data)
        return wrapper.eventType
    }
    
 /// 解码触摸事件
    public func decodeTouchEvent(from data: Data) throws -> P2PTouchEvent {
        try decoder.decode(P2PTouchEvent.self, from: data)
    }
    
 /// 解码按键事件
    public func decodeKeystrokeEvent(from data: Data) throws -> P2PKeystrokeEvent {
        try decoder.decode(P2PKeystrokeEvent.self, from: data)
    }
    
 /// 解码滚动事件
    public func decodeScrollEvent(from data: Data) throws -> P2PScrollEvent {
        try decoder.decode(P2PScrollEvent.self, from: data)
    }
    
 /// 解码捏合事件
    public func decodePinchEvent(from data: Data) throws -> P2PPinchEvent {
        try decoder.decode(P2PPinchEvent.self, from: data)
    }
    
 /// 解码旋转事件
    public func decodeRotationEvent(from data: Data) throws -> P2PRotationEvent {
        try decoder.decode(P2PRotationEvent.self, from: data)
    }
    
 /// 解码认证请求事件
    public func decodeAuthenticationRequiredEvent(from data: Data) throws -> P2PAuthenticationRequiredEvent {
        try decoder.decode(P2PAuthenticationRequiredEvent.self, from: data)
    }
}
