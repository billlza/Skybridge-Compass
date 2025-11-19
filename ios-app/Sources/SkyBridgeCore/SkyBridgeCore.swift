import Foundation
import Observation
import DeviceDiscoveryKit
import RemoteDesktopKit
import QuantumSecurityKit
import SettingsKit

public enum MainTab: String, CaseIterable, Identifiable {
    case dashboard
    case discovery
    case fileTransfer
    case remoteDesktop
    case settings

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dashboard: return "主控台"
        case .discovery: return "设备发现"
        case .fileTransfer: return "文件传输"
        case .remoteDesktop: return "远程桌面"
        case .settings: return "系统设置"
        }
    }
    public var icon: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .discovery: return "antenna.radiowaves.left.and.right"
        case .fileTransfer: return "arrow.triangle.2.circlepath"
        case .remoteDesktop: return "display"
        case .settings: return "gearshape.fill"
        }
    }
}

public struct WeatherSnapshot: Sendable {
    public static let defaultAirQualityIndex = 60

    public let city: String
    public let condition: String
    public let temperature: String
    public let humidity: String
    public let visibility: String
    public let wind: String
    public let airQualityIndex: Int

    public init(city: String, condition: String, temperature: String, humidity: String, visibility: String, wind: String, airQualityIndex: Int) {
        self.city = city
        self.condition = condition
        self.temperature = temperature
        self.humidity = humidity
        self.visibility = visibility
        self.wind = wind
        self.airQualityIndex = airQualityIndex
    }

    public var conditionSymbolName: String {
        let lowercased = condition.lowercased()
        if lowercased.contains("晴") || lowercased.contains("sun") {
            return "sun.max.fill"
        } else if lowercased.contains("云") || lowercased.contains("cloud") {
            return "cloud.sun.fill"
        } else if lowercased.contains("雨") || lowercased.contains("rain") {
            return "cloud.rain.fill"
        } else if lowercased.contains("雪") || lowercased.contains("snow") {
            return "snow"
        } else {
            return "cloud.fill"
        }
    }
}

public struct DashboardSummary: Sendable {
    public let weather: WeatherSnapshot
    public let activeSession: RemoteSessionSummary?
    public let securityStatus: QuantumSecurityStatus
    public let linkSummary: NetworkLinkSummary
    public init(weather: WeatherSnapshot, activeSession: RemoteSessionSummary?, securityStatus: QuantumSecurityStatus, linkSummary: NetworkLinkSummary) {
        self.weather = weather
        self.activeSession = activeSession
        self.securityStatus = securityStatus
        self.linkSummary = linkSummary
    }
}

public struct NetworkLinkSummary: Sendable {
    public let primary: NetworkPath
    public let fallback: NetworkPath?
    public init(primary: NetworkPath, fallback: NetworkPath?) {
        self.primary = primary
        self.fallback = fallback
    }
}

public struct NetworkPath: Sendable {
    public let label: String
    public let latency: String
    public let type: LinkType
    public init(label: String, latency: String, type: LinkType) {
        self.label = label
        self.latency = latency
        self.type = type
    }
}

public enum LinkType: String, Sendable {
    case p2p = "P2P"
    case relay = "中继"
}

@MainActor
@Observable
public final class SkybridgeAppState {
    public var selectedTab: MainTab = .dashboard
    public var dashboardSummary: DashboardSummary
    public var devices: [DiscoveredDevice]
    public var transfers: [TransferTask]
    public var sessions: [RemoteSessionSummary]
    public var performanceSettings: PerformanceSettings
    public var securityStatus: QuantumSecurityStatus

    public private(set) var availableCities: [WeatherLocation]
    public private(set) var selectedCity: WeatherLocation
    public private(set) var isWeatherRefreshing: Bool = false
    public private(set) var weatherError: String?

    private let weatherService: WeatherProviding

    public init(
        dashboardSummary: DashboardSummary = .mock,
        devices: [DiscoveredDevice] = DiscoveredDevice.mockDevices,
        transfers: [TransferTask] = TransferTask.mock,
        sessions: [RemoteSessionSummary] = RemoteSessionSummary.mockSessions,
        performanceSettings: PerformanceSettings = .default,
        securityStatus: QuantumSecurityStatus = .default,
        availableCities: [WeatherLocation] = WeatherLocation.presets,
        selectedCity: WeatherLocation? = nil,
        weatherService: WeatherProviding = WeatherService()
    ) {
        self.dashboardSummary = dashboardSummary
        self.devices = devices
        self.transfers = transfers
        self.sessions = sessions
        self.performanceSettings = performanceSettings
        self.securityStatus = securityStatus
        self.availableCities = availableCities
        self.selectedCity = selectedCity ?? availableCities.first ?? WeatherLocation(displayName: "上海", query: "Shanghai", region: "中国 · CN")
        self.weatherService = weatherService
    }

    public func refreshWeather() async {
        if isWeatherRefreshing { return }
        isWeatherRefreshing = true
        weatherError = nil
        defer { isWeatherRefreshing = false }

        do {
            let snapshot = try await weatherService.fetchSnapshot(for: selectedCity)
            dashboardSummary = DashboardSummary(
                weather: snapshot,
                activeSession: dashboardSummary.activeSession,
                securityStatus: dashboardSummary.securityStatus,
                linkSummary: dashboardSummary.linkSummary
            )
        } catch {
            weatherError = error.localizedDescription
        }
    }

    public func changeCity(to city: WeatherLocation) async {
        guard city != selectedCity else { return }
        selectedCity = city
        await refreshWeather()
    }
}

public extension WeatherSnapshot {
    static let mock = WeatherSnapshot(
        city: "杭州",
        condition: "晴朗",
        temperature: "27°",
        humidity: "52%",
        visibility: "10 km",
        wind: "东南 8 km/h",
        airQualityIndex: 36
    )
}

public extension DashboardSummary {
    static let mock = DashboardSummary(
        weather: .mock,
        activeSession: RemoteSessionSummary.mockSessions.first,
        securityStatus: QuantumSecurityStatus.default,
        linkSummary: NetworkLinkSummary(
            primary: NetworkPath(label: "P2P 直连", latency: "14 ms", type: .p2p),
            fallback: NetworkPath(label: "中继：东京", latency: "38 ms", type: .relay)
        )
    )
}
