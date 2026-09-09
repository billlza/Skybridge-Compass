import SwiftUI

/// Volume clouds presented through the shared native atmosphere surface.
public struct CinematicCloudView: View {
    private let sky: AtmosphereView

    public init(intensity: Float = 0.68, wind: Float = 0.2, quality: Float = 1,
                framesPerSecond: Int = 30, isAnimating: Bool = true) {
        sky = AtmosphereView(kind: .clouds, intensity: intensity, wind: wind, quality: quality,
                             framesPerSecond: framesPerSecond, isAnimating: isAnimating)
    }

    public var body: some View { sky }
}
