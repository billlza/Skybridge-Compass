import Foundation

/// 鼠标事件类型
public enum MouseEventType: String, Codable, Sendable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case scrollUp
    case scrollDown
}

/// 键盘事件类型
public enum KeyboardEventType: String, Codable, Sendable {
    case keyDown
    case keyUp
}

/// 远程鼠标事件
public struct RemoteMouseEvent: Codable, Sendable {
    public let type: MouseEventType
    public let x: Double
    public let y: Double
    public let timestamp: TimeInterval

    public init(type: MouseEventType, x: Double, y: Double, timestamp: TimeInterval) {
        self.type = type
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}

/// 远程键盘事件
public struct RemoteKeyboardEvent: Codable, Sendable {
    public let type: KeyboardEventType
    public let keyCode: Int
    public let timestamp: TimeInterval

    public init(type: KeyboardEventType, keyCode: Int, timestamp: TimeInterval) {
        self.type = type
        self.keyCode = keyCode
        self.timestamp = timestamp
    }
}

/// 远程控制错误
public enum RemoteControlError: Error, LocalizedError {
    case deviceNotConnected
    case connectionClosed
    case invalidMessageLength(Int)
    case permissionDenied
    case screenCaptureFailed
    case handshakeInitializationFailed(String)
    case untrustedPeer(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "设备未连接"
        case .connectionClosed:
            return "连接已关闭"
        case .invalidMessageLength(let length):
            return "消息长度异常: \(length)"
        case .permissionDenied:
            return "权限被拒绝"
        case .screenCaptureFailed:
            return "屏幕捕获失败"
        case .handshakeInitializationFailed(let reason):
            return "远控握手初始化失败: \(reason)"
        case .untrustedPeer(let peerId):
            return "远控目标未建立受信任身份: \(peerId)"
        }
    }
}

enum RemoteControlSessionRole: String, Sendable {
    case controlling
    case beingControlled
}
