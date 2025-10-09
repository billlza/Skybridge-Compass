import Foundation

struct RemoteDesktopEndpoint: Identifiable, Codable, Sendable, Equatable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case available
        case busy
        case offline

        var displayName: String {
            switch self {
            case .available: return "可用"
            case .busy: return "忙碌"
            case .offline: return "离线"
            }
        }

        var systemImage: String {
            switch self {
            case .available: return "display"
            case .busy: return "display.trianglebadge.exclamationmark"
            case .offline: return "display.slash"
            }
        }

        var tint: String {
            switch self {
            case .available: return "green"
            case .busy: return "orange"
            case .offline: return "red"
            }
        }
    }

    var id: UUID
    var name: String
    var location: String
    var status: Status
    var resolution: String
    var frameRate: Double
    var lastLatency: TimeInterval?
    var isSecure: Bool

    var formattedLatency: String {
        guard let lastLatency else { return "--" }
        return String(format: "%.0f ms", lastLatency * 1000)
    }
}

struct RemoteDesktopSession: Identifiable, Codable, Sendable, Equatable {
    enum StreamQuality: String, Codable, CaseIterable, Sendable {
        case efficiency
        case balanced
        case performance

        var displayName: String {
            switch self {
            case .efficiency: return "省电"
            case .balanced: return "均衡"
            case .performance: return "高性能"
            }
        }

        var description: String {
            switch self {
            case .efficiency: return "降低比特率以延长续航"
            case .balanced: return "画质与延迟最佳平衡"
            case .performance: return "高码率获得更清晰画面"
            }
        }
    }

    var id: UUID
    var endpoint: RemoteDesktopEndpoint
    var startedAt: Date
    var bitrate: Int
    var codec: String
    var quality: StreamQuality
    var isSecure: Bool
}

struct RemoteDesktopFrame: Codable, Sendable, Equatable {
    var sessionID: UUID
    var previewImageURL: URL?
    var resolution: String
    var timestamp: Date
    var droppedFrames: Int?
}

struct FileTransferItem: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var modifiedAt: Date

    var iconName: String {
        isDirectory ? "folder" : "doc"
    }

    var formattedSize: String {
        guard !isDirectory else { return "文件夹" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

struct FileTransferJob: Identifiable, Codable, Sendable, Equatable {
    enum Direction: String, Codable, Sendable {
        case upload
        case download

        var displayName: String {
            switch self {
            case .upload: return "上传"
            case .download: return "下载"
            }
        }

        var systemImage: String {
            switch self {
            case .upload: return "arrow.up.circle"
            case .download: return "arrow.down.circle"
            }
        }
    }

    enum State: String, Codable, Sendable {
        case queued
        case running
        case completed
        case failed
        case cancelled

        var displayName: String {
            switch self {
            case .queued: return "排队"
            case .running: return "进行中"
            case .completed: return "完成"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            }
        }

        var systemImage: String {
            switch self {
            case .queued: return "clock"
            case .running: return "arrow.triangle.2.circlepath"
            case .completed: return "checkmark.circle"
            case .failed: return "xmark.octagon"
            case .cancelled: return "minus.circle"
            }
        }
    }

    var id: UUID
    var itemName: String
    var direction: Direction
    var state: State
    var progress: Double
    var bytesTransferred: Int64
    var totalBytes: Int64?
    var startedAt: Date
    var finishedAt: Date?
    var message: String?

    var progressText: String {
        switch state {
        case .completed:
            return "100%"
        case .failed:
            return message ?? "失败"
        case .cancelled:
            return "已取消"
        default:
            let percent = Int(progress * 100)
            return totalBytes.map { total in
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let transferred = formatter.string(fromByteCount: bytesTransferred)
                let totalString = formatter.string(fromByteCount: total)
                return "\(percent)% · \(transferred)/\(totalString)"
            } ?? "\(percent)%"
        }
    }
}

struct SystemSetting: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case toggle
        case selection
        case slider
    }

    var id: UUID
    var key: String
    var name: String
    var description: String
    var kind: Kind
    var boolValue: Bool?
    var selectedOption: String?
    var options: [String]
    var doubleValue: Double?
    var minimumValue: Double?
    var maximumValue: Double?
    var step: Double?
    var category: String

    var displayValue: String {
        switch kind {
        case .toggle:
            return (boolValue ?? false) ? "已开启" : "已关闭"
        case .selection:
            return selectedOption ?? "未选择"
        case .slider:
            guard let value = doubleValue else { return "--" }
            return String(format: "%.1f", value)
        }
    }
}

struct SystemSettingsProfile: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var appliedAt: Date
    var author: String
}

struct SystemSettingsCategory: Identifiable, Hashable {
    var name: String
    var settings: [SystemSetting]

    var id: String { name }
}
