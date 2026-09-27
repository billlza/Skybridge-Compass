import SwiftUI
import SkyBridgeWeatherRendering

@main
struct CloudRenderingHost: App {
    private let isRunningRenderingTests = ProcessInfo.processInfo.arguments.contains("--weather-rendering-tests")

    var body: some Scene {
        WindowGroup {
            Group {
                if isRunningRenderingTests {
                    // Each test owns its rendering workload and any native test window.
                    Color.black
                } else {
                    CinematicHazeView(wind: 0.25)
                }
            }
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
