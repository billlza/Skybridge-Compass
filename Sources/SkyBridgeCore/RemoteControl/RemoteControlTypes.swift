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
    public let clickCount: Int?

    public init(type: MouseEventType, x: Double, y: Double, timestamp: TimeInterval, clickCount: Int? = nil) {
        self.type = type
        self.x = x
        self.y = y
        self.timestamp = timestamp
        self.clickCount = clickCount
    }
}

struct RemoteMouseClickClassifier: Sendable {
    private struct LastClick: Sendable {
        let x: Double
        let y: Double
        let timestamp: TimeInterval
    }

    private var lastClickByRoute: [String: LastClick] = [:]
    private var pendingClickCountByRoute: [String: Int] = [:]

    mutating func classify(
        _ event: RemoteMouseEvent,
        peerKey: String,
        doubleClickIntervalMilliseconds: Int
    ) -> RemoteMouseEvent {
        guard let button = Self.buttonName(for: event.type) else {
            return event
        }
        let routeKey = "\(peerKey)|\(button)"
        if Self.isButtonDown(event.type) {
            let clickCount: Int
            let interval = TimeInterval(max(200, min(doubleClickIntervalMilliseconds, 1_000))) / 1_000.0
            if let last = lastClickByRoute[routeKey],
               event.timestamp > 0,
               event.timestamp - last.timestamp >= 0,
               event.timestamp - last.timestamp <= interval,
               Self.distanceSquared(from: event, to: last) <= 64 {
                clickCount = 2
            } else {
                clickCount = 1
            }
            lastClickByRoute[routeKey] = LastClick(x: event.x, y: event.y, timestamp: event.timestamp)
            pendingClickCountByRoute[routeKey] = clickCount
            return RemoteMouseEvent(
                type: event.type,
                x: event.x,
                y: event.y,
                timestamp: event.timestamp,
                clickCount: clickCount
            )
        }

        let clickCount = pendingClickCountByRoute.removeValue(forKey: routeKey) ?? 1
        return RemoteMouseEvent(
            type: event.type,
            x: event.x,
            y: event.y,
            timestamp: event.timestamp,
            clickCount: clickCount
        )
    }

    private static func buttonName(for type: MouseEventType) -> String? {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return "left"
        case .rightMouseDown, .rightMouseUp:
            return "right"
        case .mouseMoved, .scrollUp, .scrollDown:
            return nil
        }
    }

    private static func isButtonDown(_ type: MouseEventType) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            return true
        case .leftMouseUp, .rightMouseUp, .mouseMoved, .scrollUp, .scrollDown:
            return false
        }
    }

    private static func distanceSquared(from event: RemoteMouseEvent, to last: LastClick) -> Double {
        let dx = event.x - last.x
        let dy = event.y - last.y
        return dx * dx + dy * dy
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
