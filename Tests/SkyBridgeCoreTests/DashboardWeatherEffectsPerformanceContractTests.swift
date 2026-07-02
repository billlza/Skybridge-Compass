import XCTest

final class DashboardWeatherEffectsPerformanceContractTests: XCTestCase {
    func testIOSDashboardWeatherEffectsUseSinglePureTimelineRenderer() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/Dashboard/DashboardWeatherEffectsView.swift"
        )

        XCTAssertEqual(
            Self.countOccurrences(of: "TimelineView(", in: source),
            1,
            "Weather effects must have one cadence owner; per-condition TimelineView instances multiply wakeups."
        )
        XCTAssertTrue(source.contains("WeatherParticleField(seed: snapshot.seed, condition: snapshot.condition)"))
        XCTAssertTrue(source.contains("Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true)"))
        XCTAssertTrue(source.contains("shimmerParticles = condition == .clear ?"))
        XCTAssertTrue(source.contains("rainParticles = (condition == .rainy || condition == .stormy) ?"))
        XCTAssertTrue(source.contains("drawStormLightning("))
        XCTAssertTrue(source.contains("Notification.Name.NSProcessInfoPowerStateDidChange"))
        XCTAssertTrue(source.contains("ProcessInfo.thermalStateDidChangeNotification"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceTransparency)"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityDifferentiateWithoutColor)"))
        XCTAssertTrue(source.contains("let shouldAnimate = WeatherEffectsFrameRatePolicy.shouldAnimate"))
        XCTAssertTrue(source.contains("let allowsStormFlash = WeatherEffectsFrameRatePolicy.allowsStormFlash"))
        XCTAssertTrue(source.contains("if !shouldAnimate"))
        XCTAssertTrue(source.contains(".animation(shouldAnimate ? .easeInOut(duration: 0.8) : nil"))
        XCTAssertTrue(source.contains(".id(framePolicyGeneration)"))
        XCTAssertTrue(source.contains("guard !processInfo.isLowPowerModeEnabled else { return false }"))
        XCTAssertTrue(source.contains("case .serious, .critical:\n            return false"))
        XCTAssertTrue(source.contains("if allowsStormFlash"))
        XCTAssertFalse(source.contains("Timer.scheduledTimer"))
        XCTAssertFalse(source.contains("Double.random"))
        XCTAssertFalse(source.contains("Text(\"•\")"))
        XCTAssertFalse(source.contains(".onChange(of: time"))
        XCTAssertFalse(source.contains("@Published"))
        XCTAssertFalse(source.contains("animationTime"))
    }

    func testIOSDashboardViewUsesExtractedWeatherBackgroundLayer() throws {
        let source = try repositorySource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Views/Dashboard/DashboardView.swift"
        )

        XCTAssertTrue(source.contains("DashboardWeatherEffectsBackgroundLayer("))
        XCTAssertTrue(source.contains("isHomeVisible: selectedTab == .home"))
        XCTAssertTrue(source.contains("isHomeVisible &&"))
        XCTAssertTrue(source.contains("let highLoadMode = fileTransferManager.isTransferring || remoteDesktopManager.isStreaming"))
        XCTAssertTrue(source.contains("let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled"))
        XCTAssertTrue(source.contains("let thermalPressureMode = thermalState == .serious || thermalState == .critical"))
        XCTAssertTrue(source.contains("let shouldAnimateBackground ="))
        XCTAssertTrue(source.contains("let shouldRunWeatherEffects ="))
        XCTAssertTrue(source.contains("!highLoadMode &&"))
        XCTAssertTrue(source.contains("!reduceMotion &&"))
        XCTAssertTrue(source.contains("!lowPowerMode &&"))
        XCTAssertTrue(source.contains("!thermalPressureMode &&"))
        XCTAssertTrue(source.contains("!reduceTransparency &&"))
        XCTAssertTrue(source.contains("!differentiateWithoutColor"))
        XCTAssertTrue(source.contains("if shouldAnimateBackground"))
        XCTAssertTrue(source.contains(".id(animationPolicyGeneration)"))
        XCTAssertFalse(source.contains("CinematicRainEffectView_iOS"))
        XCTAssertFalse(source.contains("CinematicSnowEffectView_iOS"))
        XCTAssertFalse(source.contains("CinematicClearSkyEffectView_iOS"))
        XCTAssertFalse(source.contains("private struct WeatherEffectsBackgroundLayer"))
    }

    func testMacCinematicWeatherEffectsDoNotWriteStateEveryFrame() throws {
        let effectSources = try [
            "Sources/SkyBridgeCore/Weather/Effects/Cinematic/CinematicClearSkyEffectView.swift",
            "Sources/SkyBridgeCore/Weather/Effects/Cinematic/CinematicSnowEffectView.swift"
        ].map(repositorySource)

        for source in effectSources {
            XCTAssertTrue(source.contains("TimelineView(.animation"))
            XCTAssertTrue(
                source.contains("timeIntervalSince(Self.animationEpoch)"),
                "Mac cinematic weather effects should render from a stable epoch and avoid huge reference-date phase values."
            )
            XCTAssertFalse(
                source.contains(".onChange(of: time"),
                "TimelineView-backed effects must derive animation from timeline.date without mutating SwiftUI state every frame."
            )
            XCTAssertFalse(
                source.contains("Timer.scheduledTimer"),
                "Per-effect timers compete with scroll tracking and duplicate TimelineView's cadence."
            )
            XCTAssertFalse(
                source.contains("Task { @MainActor"),
                "Frame paths should not enqueue MainActor work; all per-frame rendering must be pure Canvas computation."
            )
        }
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
