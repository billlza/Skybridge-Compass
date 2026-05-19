import Foundation

/// 远程桌面常量
public enum RemoteDesktopConstants {
    /// 默认端口（5901：避免与系统 VNC 5900 冲突；与 macOS `RemoteControlServer` 对齐）
    public static let defaultPort: UInt16 = 5901

    /// 默认帧率
    public static let defaultFrameRate: Int = 30

    /// 默认比特率 (5 Mbps)
    public static let defaultBitrate: UInt64 = 5_000_000

    /// 心跳间隔（秒）
    public static let heartbeatInterval: TimeInterval = 5

    /// 连接超时（秒）
    public static let connectionTimeout: TimeInterval = 30

    /// 多候选端点探测时，单个候选的建立超时（秒）
    public static let candidateConnectionTimeout: TimeInterval = 12
}

/// 远程消息类型（与 macOS `RemoteControlManager` 对齐）
public enum RemoteMessageType: String, Codable, Sendable {
    case screenData = "screenData"
    case mouseEvent = "mouseEvent"
    case keyboardEvent = "keyboardEvent"
    case clipboard = "clipboard"
    case streamConfiguration = "streamConfiguration"
    // Compile-compatible future hook. The shared Mac/core wire enums do not
    // define this yet; once they do, iOS LAN receive can consume it below.
    case streamConfigurationAck = "streamConfigurationAck"
    case damageReport = "damageReport"
    case cursorUpdate = "cursorUpdate"
    case overlayUpdate = "overlayUpdate"
}

/// 远程消息（与 macOS `RemoteControlManager.RemoteMessage` 对齐）
public struct RemoteMessage: Codable, Sendable {
    public let type: RemoteMessageType
    public let payload: Data

    public init(type: RemoteMessageType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public struct RemoteDesktopStreamConfigurationAckPayload: Codable, Sendable {
    public let acceptedAt: TimeInterval
    public let streamRefreshToken: UInt64?
    public let audioEndpointPresent: Bool
    public let screenFrameTransport: String?

    public init(
        acceptedAt: TimeInterval,
        streamRefreshToken: UInt64?,
        audioEndpointPresent: Bool,
        screenFrameTransport: String?
    ) {
        self.acceptedAt = acceptedAt
        self.streamRefreshToken = streamRefreshToken
        self.audioEndpointPresent = audioEndpointPresent
        self.screenFrameTransport = screenFrameTransport
    }
}

/// 屏幕数据（与 macOS `RemoteControlManager.ScreenData` 对齐）
public struct ScreenData: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let imageData: Data
    public let timestamp: TimeInterval
    public let format: String? // "jpeg" / "hevc" / "h264" / "bgra"
    public let isSyncFrame: Bool?
    public let sequenceNumber: UInt64?

    public init(
        width: Int,
        height: Int,
        imageData: Data,
        timestamp: TimeInterval,
        format: String? = nil,
        isSyncFrame: Bool? = nil,
        sequenceNumber: UInt64? = nil
    ) {
        self.width = width
        self.height = height
        self.imageData = imageData
        self.timestamp = timestamp
        self.format = format
        self.isSyncFrame = isSyncFrame
        self.sequenceNumber = sequenceNumber
    }
}

/// 鼠标事件类型（与 macOS `RemoteControlManager.MouseEventType` 对齐）
public enum MouseEventType: String, Codable, Sendable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case scrollUp
    case scrollDown
}

/// 鼠标事件（与 macOS `RemoteControlManager.RemoteMouseEvent` 对齐）
public struct MouseEvent: Codable, Sendable {
    public let type: MouseEventType
    public let x: Double
    public let y: Double
    public let timestamp: TimeInterval

    public init(type: MouseEventType, x: Double, y: Double, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.type = type
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}

/// 键盘事件类型（与 macOS `RemoteControlManager.KeyboardEventType` 对齐）
public enum KeyboardEventType: String, Codable, Sendable {
    case keyDown
    case keyUp
}

/// 键盘事件（与 macOS `RemoteControlManager.RemoteKeyboardEvent` 对齐）
public struct KeyboardEvent: Codable, Sendable {
    public let type: KeyboardEventType
    public let keyCode: Int
    public let timestamp: TimeInterval

    public init(type: KeyboardEventType, keyCode: Int, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.type = type
        self.keyCode = keyCode
        self.timestamp = timestamp
    }
}

/// 远程桌面连接状态
public enum RemoteDesktopState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case error(String)

    public static func == (lhs: RemoteDesktopState, rhs: RemoteDesktopState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected),
             (.streaming, .streaming):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// 远程桌面错误
public enum RemoteDesktopError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case streamingFailed(String)
    case decodingFailed(String)
    case timeout
    case notSupported(String)
    case permissionDenied
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): return "连接失败: \(reason)"
        case .streamingFailed(let reason): return "流媒体失败: \(reason)"
        case .decodingFailed(let reason): return "解码失败: \(reason)"
        case .timeout: return "连接超时"
        case .notSupported(let feature): return "不支持: \(feature)"
        case .permissionDenied: return "权限被拒绝"
        case .disconnected: return "连接已断开"
        }
    }
}
