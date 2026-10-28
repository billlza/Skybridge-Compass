import Foundation

@main struct WeatherLifecycleHarness {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(1) }
    }

    @MainActor static func run() async throws {
        let location = TestLocationManager()
        let service = WeatherService()
        let manager = WeatherManager(weatherService: service, locationManager: location, localizationManager: .instance)
        let settings = SettingsManager.instance

        settings.enableRealTimeWeather = true
        await manager.start()
        guard manager.isInitialized, location.requests == 1 else { throw Failure("Initial activation did not request weather location.") }
        service.currentWeather = WeatherInfo(value: 1)
        try await Task.sleep(for: .milliseconds(20))
        guard manager.currentWeather?.value == 1 else { throw Failure("Active weather is not published to the animation surface.") }

        settings.enableRealTimeWeather = false
        await manager.setEnabled(false)
        guard !manager.isInitialized, manager.currentWeather == nil else { throw Failure("Disabling must clear weather AND reset initialization so it can restart.") }
        service.currentWeather = WeatherInfo(value: 2)
        try await Task.sleep(for: .milliseconds(20))
        guard manager.currentWeather == nil else { throw Failure("A late response restored weather while disabled.") }
        let requests = location.requests
        await manager.start()
        await manager.refresh()
        guard location.requests == requests else { throw Failure("Disabled weather performed location work.") }

        settings.enableRealTimeWeather = true
        await manager.setEnabled(true)
        guard manager.isInitialized, location.requests == requests + 1 else { throw Failure("Re-enabling did not restart weather automatically.") }
        service.currentWeather = WeatherInfo(value: 3)
        try await Task.sleep(for: .milliseconds(20))
        guard manager.currentWeather?.value == 3 else { throw Failure("Re-enabled weather did not update the rendering input.") }
        await manager.setEnabled(true)
        guard location.requests == requests + 1 else { throw Failure("Duplicate activation repeated location work.") }
        manager.stop()
        print("PASS iOS weather on/off/on, disabled callbacks, disabled requests, and idempotent start")
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
