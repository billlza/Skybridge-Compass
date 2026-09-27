// Test-only collaborators for compiling the real iOS WeatherManager on macOS.
// No location request, HTTP call, Metal surface, simulator or VM is started.
import Foundation
import Combine
import CoreLocation

public struct WeatherInfo: Sendable, Equatable { let value: Int }
public struct LocationInfo: Sendable {
    let latitude: Double
    let longitude: Double
    let city: String?
}
enum WeatherError: Error { case noLocation, apiError(String), networkError, invalidResponse }
@MainActor final class WeatherService {
    static let shared = WeatherService()
    @Published var currentWeather: WeatherInfo?
    @Published var error: WeatherError?
    @Published var isLoading = false
    func fetchWeather(for location: LocationInfo) async {}
}
@MainActor final class SettingsManager {
    static let instance = SettingsManager()
    var enableRealTimeWeather = true
}
@MainActor final class LocalizationManager {
    static let instance = LocalizationManager()
    func localized(_ key: String) -> String { key }
    func localizedFormat(_ key: String, _ value: String) -> String { key + value }
}
@MainActor final class SkyBridgeLogger {
    static let shared = SkyBridgeLogger()
    func info(_ message: String) {}
    func error(_ message: String) {}
}
final class TestLocationManager: CLLocationManager {
    var requests = 0
    var stops = 0
    override var authorizationStatus: CLAuthorizationStatus { .authorizedAlways }
    override func requestLocation() { requests += 1 }
    override func stopUpdatingLocation() { stops += 1 }
}
