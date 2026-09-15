import SwiftUI

/// Layout preferences keep geometry local to the dashboard; no view-tree polling or global registry.
public struct WeatherGlassAnchor {
    public let bounds: Anchor<CGRect>
    public let cornerRadius: CGFloat
    var clips: [Anchor<CGRect>] = []

    public func resolve(in geometry: GeometryProxy) -> WeatherGlassRegion {
        let clip = clips.map { geometry[$0] }.reduce(nil as CGRect?) { result, next in
            result.map { $0.intersection(next) } ?? next
        }
        return WeatherGlassRegion(bounds: geometry[bounds], cornerRadius: cornerRadius, clipBounds: clip)
    }
}

public struct WeatherGlassPreferenceKey: PreferenceKey {
    public static var defaultValue: [WeatherGlassAnchor] { [] }

    public static func reduce(value: inout [WeatherGlassAnchor], nextValue: () -> [WeatherGlassAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

public extension View {
    func weatherGlassSurface(cornerRadius: CGFloat) -> some View {
        anchorPreference(key: WeatherGlassPreferenceKey.self, value: .bounds) {
            [WeatherGlassAnchor(bounds: $0, cornerRadius: cornerRadius)]
        }
    }

    /// Preserve the full component shape while clipping its water to a scrolling viewport.
    func weatherGlassClippingRegion() -> some View {
        transformAnchorPreference(key: WeatherGlassPreferenceKey.self, value: .bounds) { anchors, clip in
            for index in anchors.indices { anchors[index].clips.append(clip) }
        }
    }
}
