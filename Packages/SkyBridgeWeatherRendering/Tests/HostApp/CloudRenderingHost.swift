import SwiftUI
import SkyBridgeWeatherRendering

@main
struct CloudRenderingHost: App {
    var body: some Scene {
        WindowGroup {
            CinematicCloudView(wind: 0.25)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
