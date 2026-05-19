import CoreGraphics

/// 流媒体画质
public enum StreamQuality: String, CaseIterable, Sendable {
    case auto = "自动"
    case low = "低 (720p)"
    case medium = "中 (1080p)"
    case high = "高 (4K)"

    public var resolution: CGSize {
        switch self {
        case .auto: return .zero
        case .low: return CGSize(width: 1280, height: 720)
        case .medium: return CGSize(width: 1920, height: 1080)
        case .high: return CGSize(width: 3840, height: 2160)
        }
    }

    public var bitrate: UInt64 {
        switch self {
        case .auto: return 0
        case .low: return 2_000_000
        case .medium: return 5_000_000
        case .high: return 15_000_000
        }
    }
}

public enum RemoteDesktopRenderPipeline: String, Sendable {
    case waiting
    case webrtcNativeVideo
    case metalRenderer
    case sampleBufferDisplayLayer
    case stillImageFallback

    public var displayName: String {
        switch self {
        case .waiting: return "等待首帧"
        case .webrtcNativeVideo: return "WebRTC 原生视频轨"
        case .metalRenderer: return "Metal Renderer"
        case .sampleBufferDisplayLayer: return "AVSampleBufferDisplayLayer"
        case .stillImageFallback: return "静态帧回退"
        }
    }
}

public enum RemoteDesktopRenderOrientation: String, Sendable {
    case unknown
    case upright
    case verticalFlip
    case horizontalFlip
    case inverted
}

@available(iOS 17.0, *)
extension RemoteDesktopManager {
    /// 从触控转换为鼠标事件
    public func handleTouch(at point: CGPoint, in bounds: CGRect, type: MouseEventType) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let normalizedX = (point.x - bounds.minX) / bounds.width
        let normalizedY = (point.y - bounds.minY) / bounds.height
        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else { return }

        let remoteX = normalizedX * resolution.width
        let remoteY = normalizedY * resolution.height
        let event = MouseEvent(type: type, x: remoteX, y: remoteY)

        Task {
            await sendMouseEvent(event)
        }
    }
}
