import SwiftUI

/// A glass surface measured in the rain view's coordinate space, in points.
public struct WeatherGlassRegion: Equatable, Sendable {
    public let bounds: CGRect
    public let cornerRadius: CGFloat
    public let clipBounds: CGRect?

    public init(bounds: CGRect, cornerRadius: CGFloat, clipBounds: CGRect? = nil) {
        precondition(bounds.origin.x.isFinite && bounds.origin.y.isFinite &&
                     bounds.width.isFinite && bounds.height.isFinite && cornerRadius.isFinite)
        precondition(bounds.width >= 0 && bounds.height >= 0 && cornerRadius >= 0)
        self.bounds = bounds
        self.cornerRadius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        if let clipBounds {
            precondition(clipBounds.isNull || (clipBounds.origin.x.isFinite && clipBounds.origin.y.isFinite &&
                         clipBounds.width.isFinite && clipBounds.height.isFinite))
        }
        self.clipBounds = clipBounds
    }
}

/// An interaction footprint; the existing platform interaction controller owns its lifetime.
public struct WeatherRainClearZone: Equatable, Sendable {
    public let center: CGPoint
    public let radius: CGFloat
    public let strength: Float

    public init(center: CGPoint, radius: CGFloat, strength: Float) {
        precondition(center.x.isFinite && center.y.isFinite && radius.isFinite && strength.isFinite)
        precondition(radius >= 0 && (0...1).contains(strength))
        self.center = center
        self.radius = radius
        self.strength = strength
    }
}

/// Textureless rain, shallow water and beading. The native Metal surface owns the frame clock.
public struct CinematicRainView: View {
    private let intensity: Float
    private let wind: Float
    private let quality: Float
    private let storm: Bool
    private let allowsLightning: Bool
    private let framesPerSecond: Int
    private let isAnimating: Bool
    private let glassRegions: [WeatherGlassRegion]
    private let clearZones: [WeatherRainClearZone]
    private let scene: WeatherRainScene?
    private let glassOpacity: Float

    public init(intensity: Float = 0.68, wind: Float = 0.25, quality: Float = 1, storm: Bool = false,
                allowsLightning: Bool = true, framesPerSecond: Int = 60, isAnimating: Bool = true,
                glassRegions: [WeatherGlassRegion] = [], clearZones: [WeatherRainClearZone] = [],
                scene: WeatherRainScene? = nil, glassOpacity: Float = 1) {
        self.intensity = intensity
        self.wind = wind
        self.quality = quality
        self.storm = storm
        self.allowsLightning = allowsLightning
        self.framesPerSecond = framesPerSecond
        self.isAnimating = isAnimating
        self.glassRegions = glassRegions
        self.clearZones = clearZones
        self.scene = scene
        self.glassOpacity = glassOpacity
    }

    public var body: some View {
        GeometryReader { geometry in
            AtmosphereView(kind: .rain, intensity: intensity, wind: wind, quality: quality,
                           framesPerSecond: framesPerSecond, isAnimating: isAnimating,
                           rain: RainAppearance(size: geometry.size, storm: storm,
                                                allowsLightning: allowsLightning && isAnimating,
                                                regions: glassRegions, zones: clearZones, glassOpacity: glassOpacity),
                           rainScene: scene)
        }
        .allowsHitTesting(false)
    }
}

struct RainParameters: Equatable {
    var storm: Float = 0
    var allowFlash: Float = 0
    var glassCount: UInt32 = 0
    var clearCount: UInt32 = 0
    var glassOptions = SIMD4<Float>(1, 0, 0, 0)
}

struct RainAppearance: Equatable {
    // Fixed bounds on fragment work and constant-buffer size. The largest visible surfaces
    // receive water first; recent interaction footprints take priority over older ones.
    static let maximumGlassRegions = 12
    static let maximumClearZones = 8
    private(set) var parameters = RainParameters()
    private(set) var glass: [SIMD4<Float>] = [.zero]
    private(set) var clearZones: [SIMD4<Float>] = [.zero]
    private(set) var clips: [CGRect] = []

    init(size: CGSize = .zero, storm: Bool = false, allowsLightning: Bool = false,
         regions: [WeatherGlassRegion] = [], zones: [WeatherRainClearZone] = [], glassOpacity: Float = 1) {
        precondition(glassOpacity.isFinite && (0...1).contains(glassOpacity))
        parameters.glassOptions.x = glassOpacity
        parameters.storm = storm ? 1 : 0
        parameters.allowFlash = allowsLightning ? 1 : 0
        precondition(size.width.isFinite && size.height.isFinite)
        guard size.width > 0 && size.height > 0 else { return } // Unmeasured layout has no surface geometry.
        let viewport = CGRect(origin: .zero, size: size)
        let visible = regions.filter {
            !$0.bounds.isEmpty && $0.bounds.intersects(viewport) &&
                $0.bounds.intersects($0.clipBounds ?? viewport)
        }
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .prefix(Self.maximumGlassRegions)
        if !visible.isEmpty {
            glass = visible.flatMap { region in
                [SIMD4(Float(region.bounds.minX / size.width), Float(region.bounds.minY / size.height),
                       Float(region.bounds.width / size.width), Float(region.bounds.height / size.height)),
                 SIMD4(Float(region.cornerRadius / size.height), 0, 0, 0)]
            }
            parameters.glassCount = UInt32(visible.count)
            clips = visible.map { region in
                let clip = (region.clipBounds ?? viewport).intersection(viewport)
                return CGRect(x: clip.minX / size.width, y: clip.minY / size.height,
                              width: clip.width / size.width, height: clip.height / size.height)
            }
        }
        let active = zones.filter { $0.radius > 0 && $0.strength > 0 }.suffix(Self.maximumClearZones)
        if !active.isEmpty {
            clearZones = active.map { SIMD4(Float($0.center.x / size.width), Float($0.center.y / size.height),
                                           Float($0.radius / size.height), $0.strength) }
            parameters.clearCount = UInt32(active.count)
        }
    }
}
