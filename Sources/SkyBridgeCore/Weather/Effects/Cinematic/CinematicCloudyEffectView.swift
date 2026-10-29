#if os(macOS)
import SwiftUI
import SkyBridgeWeatherRendering

/// macOS weather policy and interaction adapter for the shared cloud volume.
@available(macOS 14.0, *)
public struct CinematicCloudyEffectView: View {
    private let config: PerformanceConfiguration
    private let coverage: Double
    @ObservedObject private var clearManager: InteractiveClearManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRemoteDesktopActive = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermal = ProcessInfo.processInfo.thermalState

    public init(config: PerformanceConfiguration, coverage: Double = 0.75, clearManager: InteractiveClearManager) {
        self.config = config
        self.coverage = min(max(coverage, 0), 1)
        self.clearManager = clearManager
    }

    public var body: some View {
        CinematicCloudView(
            intensity: Float(coverage), wind: 0.25,
            quality: quality,
            framesPerSecond: min(max(30, config.targetFrameRate), 60),
            isAnimating: scenePhase == .active && !reduceMotion && !lowPower &&
                thermal != .serious && thermal != .critical && !isRemoteDesktopActive
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

    private var quality: Float {
        !lowPower && thermal == .nominal && config.targetFrameRate >= 60 && config.maxParticles >= 8000 ? 1 : 0.45
    }
}
#endif
