import Foundation
import CoreGraphics
import WidgetKit

struct DeviceStatus: Codable, Sendable, Equatable {
    var summary: DeviceSummary
    var cpu: CPUStatus
    var memory: MemoryStatus
    var battery: BatteryStatus
    var timestamp: Date

    static var placeholder: DeviceStatus {
        DeviceStatus(
            summary: .init(deviceName: "iPhone", systemName: "iOS 18", architecture: "arm64", chipset: "Apple A18", gpuName: "Apple GPU"),
            cpu: .init(usage: 0.42, cores: 6, frequencyMHz: 2800, temperatureCelsius: 42, loadAverages: [1.2, 1.0, 0.8]),
            memory: .init(totalBytes: 12 * 1_073_741_824, usedBytes: 6 * 1_073_741_824, pressure: .normal),
            battery: .init(level: 0.68, state: .charging, temperatureCelsius: 33, health: .good),
            timestamp: .init()
        )
    }
}

struct DeviceSummary: Codable, Sendable, Equatable {
    var deviceName: String
    var systemName: String
    var architecture: String
    var chipset: String
    var gpuName: String
}

struct CPUStatus: Codable, Sendable, Equatable {
    var usage: Double
    var cores: Int
    var frequencyMHz: Double?
    var temperatureCelsius: Double?
    var loadAverages: [Double]

    var formattedUsage: String {
        "\(Int(usage * 100))%"
    }

    var formattedFrequency: String {
        guard let frequencyMHz else { return "--" }
        return String(format: "%.0f MHz", frequencyMHz)
    }

    var formattedTemperature: String {
        guard let temperatureCelsius else { return "--" }
        return String(format: "%.0f℃", temperatureCelsius)
    }
}

struct MemoryStatus: Codable, Sendable, Equatable {
    enum Pressure: String, Codable, Sendable {
        case normal
        case warning
        case critical

        var displayName: String {
            switch self {
            case .normal: return "正常"
            case .warning: return "注意"
            case .critical: return "紧张"
            }
        }
    }

    var totalBytes: UInt64
    var usedBytes: UInt64
    var pressure: Pressure

    var usageFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

struct BatteryStatus: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case unplugged
        case charging
        case full
        case unknown

        var displayName: String {
            switch self {
            case .unplugged: return "放电"
            case .charging: return "充电"
            case .full: return "已充满"
            case .unknown: return "未知"
            }
        }
    }

    enum Health: String, Codable, Sendable {
        case excellent
        case good
        case fair
        case poor

        var displayName: String {
            switch self {
            case .excellent: return "优秀"
            case .good: return "良好"
            case .fair: return "一般"
            case .poor: return "较差"
            }
        }
    }

    var level: Double
    var state: State
    var temperatureCelsius: Double?
    var health: Health
}

struct RemoteShellMessage: Identifiable, Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case system
    }

    var id: UUID
    var role: Role
    var text: String
    var timestamp: Date
}

struct RemoteShellSession: Codable, Sendable, Equatable {
    var endpoint: URL?
    var isConnected: Bool
    var latency: TimeInterval?
    var messages: [RemoteShellMessage]
}

struct DeviceStatusSnapshot: TimelineEntry, Codable, Sendable, Equatable {
    var date: Date
    var status: DeviceStatus
}
