import Foundation

enum RemoteMessageTypeWire: String, Codable {
    case screenData
    case mouseEvent
    case keyboardEvent
    case clipboard
    case streamConfiguration
    case streamConfigurationAck
    case damageReport
    case cursorUpdate
    case overlayUpdate
}

struct RemoteMessageWire: Codable {
    let type: RemoteMessageTypeWire
    let payload: Data
}

struct RemoteDesktopStreamConfigurationAckWire: Codable, Sendable {
    let acceptedAt: TimeInterval
    let streamRefreshToken: UInt64?
    let audioEndpointPresent: Bool
    let screenFrameTransport: String?
}

enum MouseEventTypeWire: String, Codable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case scrollUp
    case scrollDown
}

struct MouseEventWire: Codable {
    let type: MouseEventTypeWire
    let x: Double
    let y: Double
    let timestamp: TimeInterval
}

enum KeyboardEventTypeWire: String, Codable {
    case keyDown
    case keyUp
}

struct KeyboardEventWire: Codable {
    let type: KeyboardEventTypeWire
    let keyCode: Int
    let timestamp: TimeInterval
}

struct ScreenDataWire: Codable {
    let width: Int
    let height: Int
    let imageData: Data
    let timestamp: TimeInterval
    let format: String?
    let isSyncFrame: Bool?
    let sequenceNumber: UInt64?

    init(
        width: Int,
        height: Int,
        imageData: Data,
        timestamp: TimeInterval,
        format: String?,
        isSyncFrame: Bool?,
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
