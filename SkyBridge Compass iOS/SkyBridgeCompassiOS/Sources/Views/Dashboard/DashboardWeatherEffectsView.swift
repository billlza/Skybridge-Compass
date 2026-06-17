import SwiftUI
import Foundation

@available(iOS 17.0, *)
struct DashboardWeatherEffectsBackgroundLayer: View {
    @StateObject private var weatherManager = WeatherManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private let isActive: Bool

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    var body: some View {
        let shouldRender = isActive && scenePhase == .active

        Group {
            if shouldRender,
               let snapshot = WeatherAnimationSnapshot(weather: weatherManager.currentWeather) {
                DashboardWeatherEffectsContent(snapshot: snapshot)
            }
        }
        .task(id: shouldRender) {
            guard shouldRender, !weatherManager.isInitialized else { return }
            await weatherManager.start()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

@available(iOS 17.0, *)
private struct DashboardWeatherEffectsContent: View {
    let snapshot: WeatherAnimationSnapshot
    private let field: WeatherParticleField
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var framePolicyGeneration = 0

    init(snapshot: WeatherAnimationSnapshot) {
        self.snapshot = snapshot
        self.field = WeatherParticleField(seed: snapshot.seed, condition: snapshot.condition)
    }

    var body: some View {
        let shouldAnimate = WeatherEffectsFrameRatePolicy.shouldAnimate(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            differentiateWithoutColor: differentiateWithoutColor
        )
        let allowsStormFlash = WeatherEffectsFrameRatePolicy.allowsStormFlash(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            differentiateWithoutColor: differentiateWithoutColor
        )
        let minimumInterval = WeatherEffectsFrameRatePolicy.minimumInterval(for: snapshot)

        Group {
            if !shouldAnimate {
                WeatherEffectsTintGradient(snapshot: snapshot)
                    .opacity(snapshot.tintOpacity * 0.68)
            } else {
                TimelineView(.animation(minimumInterval: minimumInterval, paused: false)) { timeline in
                    ZStack {
                        WeatherEffectsTintGradient(snapshot: snapshot)
                            .opacity(snapshot.tintOpacity)

                        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                            WeatherParticleRenderer.draw(
                                snapshot: snapshot,
                                field: field,
                                allowsStormFlash: allowsStormFlash,
                                time: timeline.date.timeIntervalSinceReferenceDate,
                                in: &context,
                                size: size
                            )
                        }
                    }
                }
            }
        }
        .id(framePolicyGeneration)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            bumpFramePolicyGeneration()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            bumpFramePolicyGeneration()
        }
        .animation(shouldAnimate ? .easeInOut(duration: 0.8) : nil, value: snapshot.condition.rawValue)
        .ignoresSafeArea()
    }

    private func bumpFramePolicyGeneration() {
        framePolicyGeneration = framePolicyGeneration == Int.max ? 0 : framePolicyGeneration + 1
    }
}

@available(iOS 17.0, *)
private struct WeatherAnimationSnapshot: Equatable {
    let condition: WeatherCondition
    let intensity: Double
    let wind: Double
    let humidity: Double
    let haze: Double
    let seed: UInt64

    init?(weather: WeatherInfo?) {
        guard let weather, weather.condition != .unknown else { return nil }

        let wind = Self.clamp(weather.windSpeed / 60.0, 0...1)
        let humidity = Self.clamp(weather.humidity / 100.0, 0...1)
        let haze: Double
        if let visibility = weather.visibility {
            haze = Self.clamp(1.0 - visibility / 10_000.0, 0...1)
        } else {
            haze = weather.condition == .haze || weather.condition == .foggy ? 0.72 : 0.18
        }

        self.condition = weather.condition
        self.wind = wind
        self.humidity = humidity
        self.haze = haze
        self.intensity = Self.intensity(for: weather.condition, wind: wind, humidity: humidity, haze: haze)
        self.seed = Self.stableSeed(condition: weather.condition)
    }

    var isStorm: Bool {
        condition == .stormy
    }

    var tintOpacity: Double {
        switch condition {
        case .clear:
            return 0.34
        case .cloudy:
            return 0.38
        case .rainy, .stormy:
            return 0.44
        case .snowy:
            return 0.34
        case .foggy, .haze:
            return 0.48
        case .unknown:
            return 0
        }
    }

    private static func intensity(
        for condition: WeatherCondition,
        wind: Double,
        humidity: Double,
        haze: Double
    ) -> Double {
        let base: Double
        switch condition {
        case .clear:
            base = 0.48
        case .cloudy:
            base = 0.58
        case .rainy:
            base = 0.70
        case .snowy:
            base = 0.64
        case .foggy:
            base = 0.62 + haze * 0.22
        case .haze:
            base = 0.56 + haze * 0.30
        case .stormy:
            base = 0.92
        case .unknown:
            base = 0
        }

        return clamp(base + wind * 0.12 + humidity * 0.08, 0.25...1.0)
    }

    private static func stableSeed(condition: WeatherCondition) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in condition.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash == 0 ? 0x7E57_5EED : hash
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

@available(iOS 17.0, *)
private enum WeatherEffectsFrameRatePolicy {
    static func shouldAnimate(
        reduceMotion: Bool,
        reduceTransparency: Bool,
        differentiateWithoutColor: Bool
    ) -> Bool {
        guard !reduceMotion, !reduceTransparency, !differentiateWithoutColor else {
            return false
        }
        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled else { return false }
        switch processInfo.thermalState {
        case .serious, .critical:
            return false
        case .nominal, .fair:
            return true
        @unknown default:
            return false
        }
    }

    static func allowsStormFlash(
        reduceMotion: Bool,
        reduceTransparency: Bool,
        differentiateWithoutColor: Bool
    ) -> Bool {
        shouldAnimate(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            differentiateWithoutColor: differentiateWithoutColor
        )
    }

    static func minimumInterval(for snapshot: WeatherAnimationSnapshot) -> TimeInterval {
        1.0 / targetFPS(for: snapshot)
    }

    private static func targetFPS(for snapshot: WeatherAnimationSnapshot) -> Double {
        let processInfo = ProcessInfo.processInfo
        switch processInfo.thermalState {
        case .serious, .critical:
            return 1
        case .fair:
            return snapshot.isStorm ? 28 : 30
        case .nominal:
            switch snapshot.condition {
            case .rainy, .snowy, .stormy:
                return 42
            case .clear, .cloudy, .foggy, .haze:
                return 36
            case .unknown:
                return 24
            }
        @unknown default:
            return 30
        }
    }
}

@available(iOS 17.0, *)
private struct WeatherEffectsTintGradient: View {
    let snapshot: WeatherAnimationSnapshot

    var body: some View {
        LinearGradient(
            colors: colors(for: snapshot.condition),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private func colors(for condition: WeatherCondition) -> [Color] {
        switch condition {
        case .clear:
            return [Color.orange.opacity(0.40), Color.yellow.opacity(0.16), Color.cyan.opacity(0.10)]
        case .cloudy:
            return [Color.gray.opacity(0.30), Color.blue.opacity(0.12), Color.white.opacity(0.08)]
        case .rainy:
            return [Color.blue.opacity(0.30), Color.cyan.opacity(0.14), Color.indigo.opacity(0.12)]
        case .snowy:
            return [Color.cyan.opacity(0.18), Color.white.opacity(0.18), Color.blue.opacity(0.08)]
        case .foggy:
            return [Color.gray.opacity(0.22), Color.white.opacity(0.16), Color.blue.opacity(0.07)]
        case .haze:
            return [Color.orange.opacity(0.18), Color.gray.opacity(0.18), Color.yellow.opacity(0.08)]
        case .stormy:
            return [Color.indigo.opacity(0.30), Color.blue.opacity(0.20), Color.cyan.opacity(0.10)]
        case .unknown:
            return [Color.gray.opacity(0.10), Color.clear]
        }
    }
}

@available(iOS 17.0, *)
private enum WeatherParticleRenderer {
    static func draw(
        snapshot: WeatherAnimationSnapshot,
        field: WeatherParticleField,
        allowsStormFlash: Bool,
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard size.width > 1, size.height > 1 else { return }

        switch snapshot.condition {
        case .clear:
            drawClearSky(snapshot: snapshot, particles: field.shimmerParticles, time: time, in: &context, size: size)
        case .cloudy:
            drawClouds(snapshot: snapshot, clouds: field.cloudParticles, time: time, in: &context, size: size)
        case .rainy:
            drawRain(snapshot: snapshot, drops: field.rainParticles, time: time, in: &context, size: size)
        case .snowy:
            drawSnow(snapshot: snapshot, flakes: field.snowParticles, time: time, in: &context, size: size)
        case .foggy, .haze:
            drawFog(snapshot: snapshot, puffs: field.fogParticles, time: time, in: &context, size: size)
        case .stormy:
            drawRain(snapshot: snapshot, drops: field.rainParticles, time: time, in: &context, size: size)
            if allowsStormFlash {
                drawStormFlash(snapshot: snapshot, time: time, in: &context, size: size)
                drawStormLightning(snapshot: snapshot, time: time, in: &context, size: size)
            }
        case .unknown:
            break
        }
    }

    private static func drawClearSky(
        snapshot: WeatherAnimationSnapshot,
        particles: [WeatherParticle],
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let center = CGPoint(x: size.width * 0.18, y: size.height * 0.16)
        // 柔和的太阳辉光：几层同心圆由内亮到外淡，模拟阳光晕染（仅 5 个 fill，开销极低），缓慢脉动。
        let glowPulse = 0.82 + 0.18 * sin(time * 0.22)
        let baseGlow = min(size.width, size.height) * 0.42
        let glowLayers = 5
        for layer in 0..<glowLayers {
            let t = Double(layer) / Double(glowLayers - 1)   // 0(内)→1(外)
            let r = baseGlow * CGFloat(0.28 + t * 0.95) * CGFloat(glowPulse)
            let alpha = (0.11 * (1.0 - t) + 0.012) * snapshot.intensity
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .color(Color.yellow.opacity(alpha))
            )
        }
        let rayCount = 18
        for index in 0..<rayCount {
            let angle = Double(index) / Double(rayCount) * Double.pi * 2 + time * 0.025
            let length = min(size.width, size.height) * CGFloat(0.20 + 0.06 * sin(time * 0.18 + Double(index)))
            let start = CGPoint(
                x: center.x + CGFloat(cos(angle)) * length * 0.25,
                y: center.y + CGFloat(sin(angle)) * length * 0.25
            )
            let end = CGPoint(
                x: center.x + CGFloat(cos(angle)) * length,
                y: center.y + CGFloat(sin(angle)) * length
            )
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            // 原 0.018 几乎不可见；提高到可感知但仍克制的水平。
            context.stroke(path, with: .color(Color.yellow.opacity(0.05)), lineWidth: 9)
        }

        for particle in particles {
            let drift = sin(time * particle.speed + particle.phase) * 0.042
            let x = (particle.x + drift * particle.depth).wrapped01() * Double(size.width)
            let y = (particle.y + cos(time * particle.speed * 0.8 + particle.phase) * 0.030).wrapped01() * Double(size.height)
            let twinkle = 0.55 + 0.45 * sin(time * particle.twinkle + particle.phase)
            let radius = particle.size * (0.8 + 0.35 * twinkle)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: CGFloat(x - radius),
                    y: CGFloat(y - radius),
                    width: CGFloat(radius * 2),
                    height: CGFloat(radius * 2)
                )),
                with: .color(Color.white.opacity((0.10 + 0.22 * twinkle) * snapshot.intensity * particle.alpha))
            )
        }
    }

    private static func drawClouds(
        snapshot: WeatherAnimationSnapshot,
        clouds: [WeatherParticle],
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 18))
            for cloud in clouds {
                let progress = (cloud.x + time * cloud.speed * 0.018 * cloud.depth).wrapped01()
                let x = progress * Double(size.width * 1.35) - Double(size.width) * 0.18
                let y = (cloud.y * 0.72 + 0.04 * sin(time * cloud.twinkle + cloud.phase)) * Double(size.height)
                let width = cloud.size * Double(size.width) * (0.48 + cloud.depth * 0.35)
                let height = width * (0.30 + cloud.depth * 0.10)
                let rect = CGRect(
                    x: CGFloat(x - width * 0.5),
                    y: CGFloat(y - height * 0.5),
                    width: CGFloat(width),
                    height: CGFloat(height)
                )
                // 深度着色 + 提高不透明度：近处云团更厚实、远处更轻薄，云层更立体而非平淡一片。
                let depthShade = 0.6 + 0.7 * cloud.depth
                layer.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color.white.opacity((0.09 + cloud.alpha * 0.16) * snapshot.intensity * depthShade))
                )
            }
        }
    }

    private static func drawRain(
        snapshot: WeatherAnimationSnapshot,
        drops: [WeatherParticle],
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        // 阵风：基础风 + 慢速摆动 + 偶发强阵风，让整片雨丝有节奏地倾斜（纯数学，零额外绘制开销）。
        let gust = sin(time * 0.14) * 0.12
            + sin(time * 0.37 + 1.3) * 0.07
            + max(0, sin(time * 0.085) - 0.45) * 0.55
        let wind = (snapshot.wind - 0.35) * (snapshot.isStorm ? 0.78 : 0.46) + gust
        let activeCount = snapshot.isStorm ? drops.count : min(390, drops.count)
        // 提高基础不透明度：原值过低（0.23）在明亮背景上几乎看不见，显得简陋。
        let baseOpacity = snapshot.isStorm ? 0.50 : 0.38

        for drop in drops.prefix(activeCount) {
            let fall = (drop.y + time * drop.speed * (snapshot.isStorm ? 0.18 : 0.13)).wrapped01()
            let x = (drop.x + wind * 0.05 * drop.depth + drop.drift * 0.02).wrapped01() * Double(size.width)
            let y = fall * Double(size.height)
            let length = drop.length * (0.72 + drop.depth * 0.50) * (snapshot.isStorm ? 1.18 : 1.0)
            let dx = wind * length * 0.34
            // 深度着色：近处雨丝更亮更粗、远处更淡更细 → 形成景深层次，而非平铺噪点。
            let depthShade = 0.45 + 0.75 * drop.depth
            let head = CGPoint(x: CGFloat(x), y: CGFloat(y))
            let tail = CGPoint(x: CGFloat(x + dx), y: CGFloat(y + length))

            var path = Path()
            path.move(to: head)
            path.addLine(to: tail)
            context.stroke(
                path,
                with: .color(Color.white.opacity(baseOpacity * snapshot.intensity * drop.alpha * depthShade)),
                lineWidth: CGFloat(drop.size * (0.8 + drop.depth * 0.6))
            )
            // 近处雨丝叠一段更亮的“头部”高光，呈现明显的流线/速度感（仅最近 ~40% 雨丝，限制开销）。
            if drop.depth > 0.62 {
                var headPath = Path()
                headPath.move(to: head)
                headPath.addLine(to: CGPoint(x: CGFloat(x + dx * 0.32), y: CGFloat(y + length * 0.32)))
                context.stroke(
                    headPath,
                    with: .color(Color.white.opacity(min(0.85, baseOpacity * 1.5) * snapshot.intensity * drop.alpha)),
                    lineWidth: CGFloat(drop.size * (1.1 + drop.depth * 0.6))
                )
            }
        }

        let splashCount = snapshot.isStorm ? 48 : 30
        for drop in drops.prefix(splashCount) {
            let phase = sin(time * (1.0 + drop.twinkle) + drop.phase)
            guard phase > 0.62 else { continue }
            let x = drop.x * Double(size.width)
            let y = Double(size.height) * (0.78 + drop.y * 0.18)
            let radius = (phase - 0.62) * 10.0 * snapshot.intensity
            // 双环水花：外环淡、内核亮，落地处更有“溅起”的实感。
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: CGFloat(x - radius),
                    y: CGFloat(y - radius * 0.28),
                    width: CGFloat(radius * 2),
                    height: CGFloat(radius * 0.55)
                )),
                with: .color(Color.cyan.opacity(0.12 * snapshot.intensity)),
                lineWidth: 1.0
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: CGFloat(x - radius * 0.28),
                    y: CGFloat(y - radius * 0.10),
                    width: CGFloat(radius * 0.56),
                    height: CGFloat(radius * 0.22)
                )),
                with: .color(Color.white.opacity(0.10 * snapshot.intensity))
            )
        }
    }

    private static func drawSnow(
        snapshot: WeatherAnimationSnapshot,
        flakes: [WeatherParticle],
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        // 阵风 + 慢速摆动，让雪花成片飘移而非垂直下落（纯数学）。
        let wind = (snapshot.wind - 0.25) * 0.22 + sin(time * 0.10) * 0.055 + sin(time * 0.043 + 0.7) * 0.06
        for flake in flakes {
            let sway = sin(time * flake.twinkle + flake.phase) * 0.034
            let x = (flake.x + sway + wind * flake.depth).wrapped01() * Double(size.width)
            let y = (flake.y + time * flake.speed * 0.060).wrapped01() * Double(size.height)
            let radius = flake.size * (0.75 + flake.depth * 0.55)
            // 提高不透明度 + 深度着色，让雪有层次而不再是淡噪点。
            let core = (0.16 + 0.30 * flake.depth) * snapshot.intensity * flake.alpha
            // 近处雪花加一圈更大更淡的光晕，营造体积与发光感（仅最近雪花，限制开销）。
            if flake.depth > 0.55 {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: CGFloat(x - radius * 1.9),
                        y: CGFloat(y - radius * 1.9),
                        width: CGFloat(radius * 3.8),
                        height: CGFloat(radius * 3.8)
                    )),
                    with: .color(Color.white.opacity(core * 0.28))
                )
            }
            context.fill(
                Path(ellipseIn: CGRect(
                    x: CGFloat(x - radius),
                    y: CGFloat(y - radius),
                    width: CGFloat(radius * 2),
                    height: CGFloat(radius * 2)
                )),
                with: .color(Color.white.opacity(core))
            )
        }
    }

    private static func drawFog(
        snapshot: WeatherAnimationSnapshot,
        puffs: [WeatherParticle],
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let tint: Color = snapshot.condition == .haze
            ? Color(red: 0.96, green: 0.78, blue: 0.46)
            : .white
        let opacity = snapshot.condition == .haze ? 0.085 : 0.10

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 24))
            for puff in puffs {
                let x = (puff.x + sin(time * puff.speed + puff.phase) * 0.080).wrapped01() * Double(size.width)
                let y = (puff.y + cos(time * puff.speed * 0.7 + puff.phase) * 0.055).wrapped01() * Double(size.height)
                let radius = puff.length * (0.85 + 0.18 * sin(time * puff.twinkle + puff.phase))
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: CGFloat(x - radius),
                        y: CGFloat(y - radius * 0.58),
                        width: CGFloat(radius * 2.0),
                        height: CGFloat(radius * 1.16)
                    )),
                    with: .color(tint.opacity(opacity * snapshot.intensity * (0.75 + snapshot.haze * 0.55) * puff.alpha))
                )
            }
        }
    }

    private static func drawStormFlash(
        snapshot: WeatherAnimationSnapshot,
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let flash = max(0, sin(time * 1.45) - 0.86) * 2.6
        guard flash > 0 else { return }
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.white.opacity(0.13 * flash * snapshot.intensity))
        )
    }

    private static func drawStormLightning(
        snapshot: WeatherAnimationSnapshot,
        time: TimeInterval,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let pulse = max(0, sin(time * 1.45) - 0.89) * 3.4
        guard pulse > 0 else { return }

        let strikeIndex = UInt64(max(0, floor(time * 0.45)))
        var rng = WeatherSeededGenerator(seed: snapshot.seed ^ (strikeIndex &* 0x9E37_79B9_7F4A_7C15))
        let startX = CGFloat(rng.next(in: 0.18...0.82)) * size.width
        let topY = CGFloat(rng.next(in: 0.04...0.12)) * size.height
        let segmentCount = 7
        let verticalStep = size.height * CGFloat(rng.next(in: 0.050...0.075))
        var x = startX
        var y = topY

        var bolt = Path()
        bolt.move(to: CGPoint(x: x, y: y))
        for _ in 0..<segmentCount {
            x += CGFloat(rng.next(in: -0.065...0.065)) * size.width
            y += verticalStep * CGFloat(rng.next(in: 0.70...1.18))
            bolt.addLine(to: CGPoint(x: x, y: y))
        }

        context.stroke(
            bolt,
            with: .color(Color.white.opacity(0.30 * pulse * snapshot.intensity)),
            lineWidth: 2.2
        )
        context.stroke(
            bolt,
            with: .color(Color.cyan.opacity(0.10 * pulse * snapshot.intensity)),
            lineWidth: 7.0
        )

        for branch in 0..<2 {
            var branchPath = Path()
            let branchStartY = topY + verticalStep * CGFloat(branch + 2)
            let branchStartX = startX + CGFloat(rng.next(in: -0.06...0.06)) * size.width
            branchPath.move(to: CGPoint(x: branchStartX, y: branchStartY))
            branchPath.addLine(to: CGPoint(
                x: branchStartX + CGFloat(rng.next(in: -0.16...0.16)) * size.width,
                y: branchStartY + CGFloat(rng.next(in: 0.05...0.10)) * size.height
            ))
            context.stroke(
                branchPath,
                with: .color(Color.white.opacity(0.16 * pulse * snapshot.intensity)),
                lineWidth: 1.2
            )
        }
    }
}

private struct WeatherParticleField: Equatable {
    let shimmerParticles: [WeatherParticle]
    let cloudParticles: [WeatherParticle]
    let rainParticles: [WeatherParticle]
    let snowParticles: [WeatherParticle]
    let fogParticles: [WeatherParticle]

    init(seed: UInt64, condition: WeatherCondition) {
        var rng = WeatherSeededGenerator(seed: seed)
        shimmerParticles = condition == .clear ? (0..<160).map { _ in
            WeatherParticle(
                x: rng.next(in: 0...1),
                y: rng.next(in: 0...1),
                speed: rng.next(in: 0.025...0.105),
                size: rng.next(in: 0.8...2.4),
                length: rng.next(in: 8...24),
                alpha: rng.next(in: 0.55...1.0),
                phase: rng.next(in: 0...(Double.pi * 2)),
                drift: rng.next(in: -1...1),
                depth: rng.next(in: 0.45...1.0),
                twinkle: rng.next(in: 0.55...1.45)
            )
        } : []
        cloudParticles = condition == .cloudy ? (0..<34).map { _ in
            WeatherParticle(
                x: rng.next(in: 0...1),
                y: rng.next(in: 0.04...0.78),
                speed: rng.next(in: 0.30...1.05),
                size: rng.next(in: 0.12...0.34),
                length: rng.next(in: 80...180),
                alpha: rng.next(in: 0.55...1.0),
                phase: rng.next(in: 0...(Double.pi * 2)),
                drift: rng.next(in: -1...1),
                depth: rng.next(in: 0.35...1.0),
                twinkle: rng.next(in: 0.04...0.15)
            )
        } : []
        rainParticles = (condition == .rainy || condition == .stormy) ? (0..<520).map { _ in
            WeatherParticle(
                x: rng.next(in: 0...1),
                y: rng.next(in: 0...1),
                speed: rng.next(in: 0.72...1.95),
                size: rng.next(in: 0.65...1.35),
                length: rng.next(in: 16...52),
                alpha: rng.next(in: 0.55...1.0),
                phase: rng.next(in: 0...(Double.pi * 2)),
                drift: rng.next(in: -1...1),
                depth: rng.next(in: 0.45...1.0),
                twinkle: rng.next(in: 0.4...1.2)
            )
        } : []
        snowParticles = condition == .snowy ? (0..<310).map { _ in
            WeatherParticle(
                x: rng.next(in: 0...1),
                y: rng.next(in: 0...1),
                speed: rng.next(in: 0.40...1.25),
                size: rng.next(in: 1.0...3.8),
                length: rng.next(in: 4...18),
                alpha: rng.next(in: 0.50...1.0),
                phase: rng.next(in: 0...(Double.pi * 2)),
                drift: rng.next(in: -1...1),
                depth: rng.next(in: 0.40...1.0),
                twinkle: rng.next(in: 0.35...0.95)
            )
        } : []
        fogParticles = (condition == .foggy || condition == .haze) ? (0..<58).map { _ in
            WeatherParticle(
                x: rng.next(in: 0...1),
                y: rng.next(in: 0...1),
                speed: rng.next(in: 0.018...0.080),
                size: rng.next(in: 1.0...2.2),
                length: rng.next(in: 120...360),
                alpha: rng.next(in: 0.48...1.0),
                phase: rng.next(in: 0...(Double.pi * 2)),
                drift: rng.next(in: -1...1),
                depth: rng.next(in: 0.45...1.0),
                twinkle: rng.next(in: 0.02...0.12)
            )
        } : []
    }
}

private struct WeatherParticle: Equatable {
    let x: Double
    let y: Double
    let speed: Double
    let size: Double
    let length: Double
    let alpha: Double
    let phase: Double
    let drift: Double
    let depth: Double
    let twinkle: Double
}

private struct WeatherSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

private extension Double {
    func wrapped01() -> Double {
        let remainder = truncatingRemainder(dividingBy: 1.0)
        return remainder < 0 ? remainder + 1.0 : remainder
    }
}
