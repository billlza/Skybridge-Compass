#if os(macOS)
import SwiftUI
import SkyBridgeWeatherRendering

/// macOS lifecycle, quality and interaction adapter for the shared rain renderer.
@available(macOS 14.0, *)
public struct CinematicRainEffectView: View {
    @ObservedObject private var clearManager: InteractiveClearManager
    @ObservedObject private var performance = PerformanceModeManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var isRemoteDesktopActive = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermal = ProcessInfo.processInfo.thermalState
    private let storm: Bool
    private let glassRegions: [WeatherGlassRegion]
    private let rainScene: WeatherRainScene?

    public init(clearManager: InteractiveClearManager, storm: Bool = false,
                glassRegions: [WeatherGlassRegion] = [], rainScene: WeatherRainScene? = nil) {
        self.clearManager = clearManager
        self.storm = storm
        self.glassRegions = glassRegions
        self.rainScene = rainScene
    }

    public var body: some View {
        let config = performance.currentConfiguration
        let animate = scenePhase == .active && !reduceMotion && !lowPower &&
            thermal != .serious && thermal != .critical && !isRemoteDesktopActive
        SkyBridgeWeatherRendering.CinematicRainView(
            intensity: storm ? 0.95 : 0.68, wind: 0.25,
            quality: !lowPower && thermal == .nominal && config.targetFrameRate >= 60 ? 1 : 0.45,
            storm: storm, allowsLightning: !differentiateWithoutColor,
            framesPerSecond: min(max(config.targetFrameRate, 30), 60), isAnimating: animate,
            glassRegions: glassRegions,
            clearZones: clearManager.clearZones.map {
                WeatherRainClearZone(center: $0.center, radius: $0.radius, strength: $0.strength)
            }, scene: rainScene, glassOpacity: rainScene == nil ? 1 : Float(clearManager.globalOpacity)
        )
        .opacity(clearManager.globalOpacity)
        .ignoresSafeArea()
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
}
#endif
