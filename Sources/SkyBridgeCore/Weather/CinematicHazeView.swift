import SwiftUI
import MetalKit
import Foundation

// MARK: - 电影级雾霾效果主视图
@MainActor
public struct CinematicHazeView: View {
    @ObservedObject public var weatherManager: WeatherIntegrationManager
    @ObservedObject public var clearManager: InteractiveClearManager
    
    public let tint: Color
    public let enableGrain: Bool
    public let showDebugZones: Bool
    
    @State private var performanceConfig: PerformanceConfiguration?
    @State private var animationTime: Double = 0
    
    public init(
        weatherManager: WeatherIntegrationManager,
        clearManager: InteractiveClearManager,
        tint: Color = Color(red: 0.78, green: 0.72, blue: 0.58), // 真实雾霾：暖黄灰色
        enableGrain: Bool = true,
        showDebugZones: Bool = false
    ) {
        self.weatherManager = weatherManager
        self.clearManager = clearManager
        self.tint = tint
        self.enableGrain = enableGrain
        self.showDebugZones = showDebugZones
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            
            GeometryReader { geo in
                ZStack {
 // 1️⃣ 大气背景渐变 - 模拟污染天空
                    CinematicHazeBackground(time: time, intensity: effectiveIntensity)
                        .opacity(clearManager.globalOpacity)
                        .ignoresSafeArea()
                    
 // 2️⃣ 多层体积雾 - 使用 Canvas 绘制动态噪声
                    VolumetricHazeLayer(
                        time: time,
                        intensity: effectiveIntensity,
                        tint: tint,
                        size: geo.size
                    )
                    .opacity(0.7 * clearManager.globalOpacity)
                    .blendMode(.plusLighter)
                    .ignoresSafeArea()
                    
 // 3️⃣ 动态光芒散射 - 多束丁达尔效应
                    CinematicGodRaysLayer(
                        time: time,
                        intensity: effectiveIntensity,
                        size: geo.size
                    )
                    .opacity((0.35 + effectiveIntensity * 0.25) * clearManager.globalOpacity)
                    .blendMode(.screen)
                    .ignoresSafeArea()
                    
 // 4️⃣ Metal 粒子系统
                    if effectiveIntensity > 0 {
                        MetalHazeParticleView(
                            tint: tint,
                            intensity: effectiveIntensity,
                            clearManager: clearManager
                        )
                        .opacity(0.85 * effectiveIntensity)
                        .blendMode(.plusLighter)
                        .ignoresSafeArea()
                    }
                    
 // 5️⃣ 色彩分级覆盖层 - 增强电影感
                    CinematicColorGrading(tint: tint, intensity: effectiveIntensity)
                        .opacity(clearManager.globalOpacity * 0.4)
                        .blendMode(.overlay)
                        .ignoresSafeArea()
                    
 // 6️⃣ 暗角效果 - 增加沉浸感
                    VignetteLayer(intensity: 0.3 + effectiveIntensity * 0.2)
                        .opacity(clearManager.globalOpacity)
                        .ignoresSafeArea()
                    
 // 7️⃣ 胶片颗粒 - 真实感纹理
                    if enableGrain {
                        CinematicFilmGrain(time: time, intensity: effectiveIntensity)
                            .opacity((0.08 + effectiveIntensity * 0.06) * clearManager.globalOpacity)
                            .blendMode(.overlay)
                            .ignoresSafeArea()
                    }
                    
 // 调试视图
                    if showDebugZones && SettingsManager.shared.enableVerboseLogging {
                        ClearZoneDebugView(manager: clearManager)
                            .allowsHitTesting(false)
                            .ignoresSafeArea()
                    }
                }
            }
        }
        .onAppear {
            loadPerformanceConfig()
            clearManager.start()
        }
        .onDisappear {
            clearManager.stop()
        }
    }
    
    private var effectiveIntensity: Double {
        max(0.05, min(1.0, weatherManager.currentTheme.effectIntensity))
    }

    private func loadPerformanceConfig() {
        Task { @MainActor in
            do {
                let manager = try PerformanceModeManager()
                performanceConfig = manager.currentConfiguration
            } catch {
                performanceConfig = PerformanceConfiguration(
                    renderScale: 1.0,
                    maxParticles: 6000,
                    targetFrameRate: 60,
                    metalFXQuality: 0.8,
                    shadowQuality: 1,
                    postProcessingLevel: 1,
                    gpuFrequencyHint: 0.8,
                    memoryBudget: 1024
                )
            }
        }
    }
}

// MARK: - 电影级大气背景

struct CinematicHazeBackground: View {
    let time: Double
    let intensity: Double
    
    var body: some View {
        Canvas { context, size in
 // 创建多层渐变模拟污染大气
            let gradient1 = Gradient(colors: [
                Color(red: 0.55, green: 0.50, blue: 0.42), // 顶部：黄褐色
                Color(red: 0.65, green: 0.60, blue: 0.52), // 中部：浅灰黄
                Color(red: 0.50, green: 0.48, blue: 0.45)  // 底部：灰褐色
            ])
            
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    gradient1,
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            
 // 添加动态的光晕区域模拟太阳透过雾霾
            let sunX = size.width * (0.7 + 0.1 * sin(time * 0.05))
            let sunY = size.height * 0.2
            let sunGradient = Gradient(colors: [
                Color(red: 1.0, green: 0.95, blue: 0.85).opacity(0.3 * intensity),
                Color(red: 0.95, green: 0.88, blue: 0.75).opacity(0.15 * intensity),
                Color.clear
            ])
            
            context.fill(
                Path(ellipseIn: CGRect(
                    x: sunX - 200,
                    y: sunY - 150,
                    width: 400,
                    height: 300
                )),
                with: .radialGradient(
                    sunGradient,
                    center: CGPoint(x: sunX, y: sunY),
                    startRadius: 0,
                    endRadius: 250
                )
            )
        }
    }
}

// MARK: - 体积雾层 (使用 Perlin 噪声模拟)

struct VolumetricHazeLayer: View {
    let time: Double
    let intensity: Double
    let tint: Color
    let size: CGSize
    
    var body: some View {
        Canvas { context, size in
 // 多层雾气，每层有不同的运动速度和密度
            for layer in 0..<4 {
                let layerOpacity = intensity * (0.4 - Double(layer) * 0.08)
                let speed = 0.02 + Double(layer) * 0.01
                let scale = 80.0 + Double(layer) * 30.0
                
                drawFogLayer(
                    context: &context,
                    size: size,
                    time: time,
                    speed: speed,
                    scale: scale,
                    opacity: layerOpacity,
                    yOffset: CGFloat(layer) * 50
                )
            }
        }
    }
    
    private func drawFogLayer(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        speed: Double,
        scale: Double,
        opacity: Double,
        yOffset: CGFloat
    ) {
        let cols = Int(size.width / 40) + 2
        let rows = Int(size.height / 40) + 2
        
        for row in 0..<rows {
            for col in 0..<cols {
                let baseX = CGFloat(col) * 40
                let baseY = CGFloat(row) * 40 + yOffset
                
 // 使用 Perlin 噪声计算位置偏移
                let noiseX = perlinNoise(
                    x: baseX / scale + time * speed,
                    y: baseY / scale
                )
                let noiseY = perlinNoise(
                    x: baseX / scale,
                    y: baseY / scale + time * speed * 0.7
                )
                
                let x = baseX + noiseX * 30
                let y = baseY + noiseY * 20
                
 // 雾团密度变化
                let density = perlinNoise(
                    x: baseX / (scale * 0.5) + time * speed * 0.5,
                    y: baseY / (scale * 0.5)
                )
                let size = 60 + density * 40
                
                if density > -0.3 { // 只绘制密度较高的区域
                    let localOpacity = opacity * (0.5 + density * 0.5)
                    
                    let fogGradient = Gradient(colors: [
                        Color(red: 0.85, green: 0.82, blue: 0.75).opacity(localOpacity),
                        Color(red: 0.80, green: 0.78, blue: 0.72).opacity(localOpacity * 0.5),
                        Color.clear
                    ])
                    
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: x - size / 2,
                            y: y - size / 2,
                            width: size,
                            height: size * 0.7
                        )),
                        with: .radialGradient(
                            fogGradient,
                            center: CGPoint(x: x, y: y),
                            startRadius: 0,
                            endRadius: size / 2
                        )
                    )
                }
            }
        }
    }
    
 // 简化的 Perlin 噪声实现
    private func perlinNoise(x: Double, y: Double) -> CGFloat {
        let xi = Int(floor(x)) & 255
        let yi = Int(floor(y)) & 255
        let xf = x - floor(x)
        let yf = y - floor(y)
        
        let u = fade(xf)
        let v = fade(yf)
        
        let aa = hash(xi, yi)
        let ab = hash(xi, yi + 1)
        let ba = hash(xi + 1, yi)
        let bb = hash(xi + 1, yi + 1)
        
        let x1 = lerp(grad(aa, xf, yf), grad(ba, xf - 1, yf), u)
        let x2 = lerp(grad(ab, xf, yf - 1), grad(bb, xf - 1, yf - 1), u)
        
        return CGFloat(lerp(x1, x2, v))
    }
    
    private func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + t * (b - a) }
    private func hash(_ x: Int, _ y: Int) -> Int { (x * 374761393 + y * 668265263) & 255 }
    private func grad(_ hash: Int, _ x: Double, _ y: Double) -> Double {
        let h = hash & 3
        let u = h < 2 ? x : y
        let v = h < 2 ? y : x
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }
}

// MARK: - 电影级丁达尔效应（God Rays）

struct CinematicGodRaysLayer: View {
    let time: Double
    let intensity: Double
    let size: CGSize
    
    var body: some View {
        Canvas { context, size in
 // 多束光线从不同角度穿透雾霾
            let rays: [(angle: Double, width: CGFloat, opacity: Double)] = [
                (angle: -25, width: 180, opacity: 0.25),
                (angle: -10, width: 120, opacity: 0.35),
                (angle: 5, width: 150, opacity: 0.30),
                (angle: 20, width: 100, opacity: 0.20),
                (angle: 35, width: 80, opacity: 0.15),
            ]
            
            let sunCenter = CGPoint(
                x: size.width * 0.75 + sin(time * 0.03) * 20,
                y: -50 + cos(time * 0.02) * 10
            )
            
            for (index, ray) in rays.enumerated() {
                let animatedAngle = ray.angle + sin(time * 0.1 + Double(index)) * 2
                let animatedOpacity = ray.opacity * intensity * (0.8 + 0.2 * sin(time * 0.15 + Double(index) * 0.5))
                
                drawGodRay(
                    context: &context,
                    size: size,
                    origin: sunCenter,
                    angle: animatedAngle,
                    width: ray.width,
                    opacity: animatedOpacity
                )
            }
        }
    }
    
    private func drawGodRay(
        context: inout GraphicsContext,
        size: CGSize,
        origin: CGPoint,
        angle: Double,
        width: CGFloat,
        opacity: Double
    ) {
        let length = max(size.width, size.height) * 1.5
        let angleRad = angle * .pi / 180
        
        var path = Path()
        
 // 光线起点（太阳位置附近）
        let startWidth = width * 0.3
        let endWidth = width * 2.5
        
        let cos_a = cos(angleRad)
        let sin_a = sin(angleRad)
        
 // 光线的四个角点
        let p1 = CGPoint(
            x: origin.x - startWidth/2 * sin_a,
            y: origin.y + startWidth/2 * cos_a
        )
        let p2 = CGPoint(
            x: origin.x + startWidth/2 * sin_a,
            y: origin.y - startWidth/2 * cos_a
        )
        let p3 = CGPoint(
            x: origin.x + length * cos_a + endWidth/2 * sin_a,
            y: origin.y + length * sin_a - endWidth/2 * cos_a
        )
        let p4 = CGPoint(
            x: origin.x + length * cos_a - endWidth/2 * sin_a,
            y: origin.y + length * sin_a + endWidth/2 * cos_a
        )
        
        path.move(to: p1)
        path.addLine(to: p2)
        path.addLine(to: p3)
        path.addLine(to: p4)
        path.closeSubpath()
        
 // 光线渐变：从亮到暗
        let rayGradient = Gradient(colors: [
            Color(red: 1.0, green: 0.98, blue: 0.90).opacity(opacity),
            Color(red: 0.95, green: 0.92, blue: 0.85).opacity(opacity * 0.5),
            Color(red: 0.90, green: 0.88, blue: 0.80).opacity(opacity * 0.2),
            Color.clear
        ])
        
        context.fill(
            path,
            with: .linearGradient(
                rayGradient,
                startPoint: origin,
                endPoint: CGPoint(
                    x: origin.x + length * cos_a,
                    y: origin.y + length * sin_a
                )
            )
        )
    }
}

// MARK: - 电影级色彩分级

struct CinematicColorGrading: View {
    let tint: Color
    let intensity: Double
    
    var body: some View {
        ZStack {
 // 温暖的高光区域
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.95, blue: 0.85).opacity(0.15),
                    Color.clear
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            
 // 冷调阴影区域
            LinearGradient(
                colors: [
                    Color.clear,
                    Color(red: 0.4, green: 0.45, blue: 0.55).opacity(0.1 * intensity)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
 // 整体色调
            tint.opacity(0.08 * intensity)
        }
    }
}

// MARK: - 暗角效果

struct VignetteLayer: View {
    let intensity: Double
    
    var body: some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [
                    Color.clear,
                    Color.clear,
                    Color.black.opacity(intensity * 0.3),
                    Color.black.opacity(intensity * 0.6)
                ],
                center: .center,
                startRadius: min(geo.size.width, geo.size.height) * 0.3,
                endRadius: max(geo.size.width, geo.size.height) * 0.8
            )
        }
    }
}

// MARK: - 电影级胶片颗粒

struct CinematicFilmGrain: View {
    let time: Double
    let intensity: Double
    
    var body: some View {
        Canvas { context, size in
 // 使用多层噪声创建真实的胶片颗粒感
            let grainSize: CGFloat = 2
            let cols = Int(size.width / grainSize)
            let rows = Int(size.height / grainSize)
            
 // 每帧随机种子
            let seed = Int(time * 24) // 24fps 风格的颗粒
            
            for row in stride(from: 0, to: rows, by: 2) {
                for col in stride(from: 0, to: cols, by: 2) {
                    let hash = ((col * 374761393 + row * 668265263 + seed) & 0xFFFFFF)
                    let noise = Double(hash) / Double(0xFFFFFF)
                    
                    if noise > 0.5 {
                        let grainOpacity = (noise - 0.5) * 0.15 * intensity
                        let x = CGFloat(col) * grainSize
                        let y = CGFloat(row) * grainSize
                        
                        context.fill(
                            Path(CGRect(x: x, y: y, width: grainSize, height: grainSize)),
                            with: .color(Color.white.opacity(grainOpacity))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - 兼容性组件（保留旧接口）

struct BackgroundGradient: View {
    var body: some View {
        CinematicHazeBackground(time: Date().timeIntervalSinceReferenceDate, intensity: 0.6)
    }
}

struct ColorGradingOverlay: View {
    let tint: Color
    let strength: Double
    
    var body: some View {
        CinematicColorGrading(tint: tint, intensity: strength)
    }
}

struct GodRaysLayer: View {
    let time: Double
    let intensity: Double
    
    var body: some View {
        GeometryReader { geo in
            CinematicGodRaysLayer(time: time, intensity: intensity, size: geo.size)
        }
    }
}

struct FilmGrainLayer: View {
    let time: Double
    
    var body: some View {
        CinematicFilmGrain(time: time, intensity: 0.5)
    }
}

extension View {
    func noise(time: Double) -> some View {
        self.opacity(0.8 + 0.2 * sin(time * 10))
    }
}
