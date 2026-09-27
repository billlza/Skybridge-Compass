#if os(macOS)
import SwiftUI
import AppKit
import SkyBridgeWeatherRendering

/// macOS interaction and power policy for the shared aerosol renderer.
@available(macOS 14.0, *)
@MainActor
public struct CinematicHazeView: View {
    @ObservedObject public var weatherManager: WeatherIntegrationManager
    @ObservedObject public var clearManager: InteractiveClearManager
    @ObservedObject private var performance = PerformanceModeManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRemoteDesktopActive = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermal = ProcessInfo.processInfo.thermalState

    public let tint: Color
    public let enableGrain: Bool
    public let showDebugZones: Bool

    public init(weatherManager: WeatherIntegrationManager, clearManager: InteractiveClearManager,
                tint: Color = Color(red: 0.78, green: 0.72, blue: 0.58),
                enableGrain: Bool = true, showDebugZones: Bool = false) {
        self.weatherManager = weatherManager
        self.clearManager = clearManager
        self.tint = tint
        self.enableGrain = enableGrain
        self.showDebugZones = showDebugZones
    }

    public var body: some View {
        let config = performance.currentConfiguration
        let quality: Float = !lowPower && thermal == .nominal && config.maxParticles >= 8000 ? 1 : 0.45
        SkyBridgeWeatherRendering.CinematicHazeView(
            intensity: Float(weatherManager.currentTheme.effectIntensity),
            wind: Float((weatherManager.currentWeather?.windSpeed ?? 0) / 60),
            quality: quality, framesPerSecond: min(max(24, config.targetFrameRate), 60),
            isAnimating: scenePhase == .active && !reduceMotion && !lowPower &&
                thermal != .serious && thermal != .critical && !isRemoteDesktopActive,
            tint: resolvedTint, enableGrain: enableGrain
        )
        .opacity(clearManager.globalOpacity)
        .overlay {
            if showDebugZones && SettingsManager.shared.enableVerboseLogging {
                ClearZoneDebugView(manager: clearManager).allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear { clearManager.start() }
        .onDisappear { clearManager.stop() }
        .onReceive(RemoteDesktopManager.shared.metrics) { snapshot in
            isRemoteDesktopActive = snapshot.activeSessions > 0
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
    }

    private var resolvedTint: SIMD3<Float> {
        guard let color = NSColor(tint).usingColorSpace(.sRGB) else {
            preconditionFailure("Haze tint must resolve to an RGB color")
        }
        return SIMD3(Float(min(max(color.redComponent, 0), 1)),
                     Float(min(max(color.greenComponent, 0), 1)),
                     Float(min(max(color.blueComponent, 0), 1)))
    }
}
#endif
