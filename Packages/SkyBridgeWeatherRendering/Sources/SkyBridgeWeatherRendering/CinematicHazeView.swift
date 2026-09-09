import SwiftUI

/// Aerosol extinction and directional scattering. Tint components use sRGB display values.
public struct CinematicHazeView: View {
    private let sky: AtmosphereView

    public init(intensity: Float = 0.68, wind: Float = 0.2, quality: Float = 1,
                framesPerSecond: Int = 30, isAnimating: Bool = true,
                tint: SIMD3<Float> = SIMD3(0.78, 0.72, 0.58), enableGrain: Bool = true) {
        precondition((0...1).contains(tint.x) && (0...1).contains(tint.y) && (0...1).contains(tint.z))
        let appearance = HazeAppearance(tint: tint, grain: enableGrain ? 1 : 0)
        sky = AtmosphereView(kind: .haze, intensity: intensity, wind: wind, quality: quality,
                             framesPerSecond: framesPerSecond, isAnimating: isAnimating, appearance: appearance)
    }

    public var body: some View { sky }
}
