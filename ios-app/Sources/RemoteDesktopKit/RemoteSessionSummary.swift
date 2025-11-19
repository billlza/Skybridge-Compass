import Foundation

public struct RemoteSessionSummary: Identifiable, Sendable {
    public let id: UUID
    public let deviceName: String
    public let resolution: String
    public let fps: Int
    public let latency: Int
    public let mode: String
    public let thumbnail: String

    public init(id: UUID = .init(), deviceName: String, resolution: String, fps: Int, latency: Int, mode: String, thumbnail: String) {
        self.id = id
        self.deviceName = deviceName
        self.resolution = resolution
        self.fps = fps
        self.latency = latency
        self.mode = mode
        self.thumbnail = thumbnail
    }
}

public extension RemoteSessionSummary {
    static let mockSessions: [RemoteSessionSummary] = [
        RemoteSessionSummary(deviceName: "Skybridge Studio", resolution: "2560×1600", fps: 90, latency: 12, mode: "极致", thumbnail: "studio"),
        RemoteSessionSummary(deviceName: "Diagnostics NUC", resolution: "1920×1080", fps: 60, latency: 22, mode: "平衡", thumbnail: "nuc"),
        RemoteSessionSummary(deviceName: "Quantum Node", resolution: "3840×2160", fps: 30, latency: 38, mode: "省电", thumbnail: "quantum")
    ]
}

public struct TransferTask: Identifiable, Sendable {
    public enum Direction: String { case upload = "上传"; case download = "下载" }
    public let id: UUID
    public let fileName: String
    public let progress: Double
    public let speed: String
    public let eta: String
    public let direction: Direction

    public init(id: UUID = .init(), fileName: String, progress: Double, speed: String, eta: String, direction: Direction) {
        self.id = id
        self.fileName = fileName
        self.progress = progress
        self.speed = speed
        self.eta = eta
        self.direction = direction
    }
}

public extension TransferTask {
    static let mock: [TransferTask] = [
        TransferTask(fileName: "vision-pro-kit.dmg", progress: 0.72, speed: "38 MB/s", eta: "00:01:12", direction: .download),
        TransferTask(fileName: "design-language.sketch", progress: 0.41, speed: "12 MB/s", eta: "00:02:48", direction: .upload)
    ]
}
