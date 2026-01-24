//
// WeatherEffectView.swift
// SkyBridgeCore
//
// 动态天气效果视图 - 支持鼠标交互
// Created: 2025-10-19
//

import SwiftUI
import OSLog

/// 天气效果覆盖层（Metal 4高性能渲染）
public struct WeatherEffectView: View {
    let theme: WeatherTheme
    @State private var clearZones: [ClearZone] = []
    @State private var performanceConfig: PerformanceConfiguration?
    @StateObject private var interactiveClear = InteractiveClearManager()
    @State private var didInitialReset: Bool = false

    public init(theme: WeatherTheme) {
        self.theme = theme
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
 // 根据天气条件显示对应效果
                if let config = performanceConfig {
                    weatherEffectView(for: theme.condition, in: geometry.size, config: config)
                }

// ✅ 统一鼠标跟踪入口：所有天气效果共享同一个 InteractiveClearManager
                if shouldEnableInteraction(for: theme.condition) {
                    InteractiveMouseTrackingView { location in
                        interactiveClear.handleMouseMove(location)
                    }
                }
            }
 // 移除顶层不透明度叠乘，避免与 CinematicHazeView 内部层级（以及粒子着色器）
 // 的 globalOpacity 联动产生双重衰减，导致霾/雾的“驱散更快”而显得灵敏度不一致。
        }
        .ignoresSafeArea()
        .allowsHitTesting(shouldEnableInteraction(for: theme.condition)) // 不阻挡用户交互
        .onReceive(interactiveClear.$clearZones) { dynamicZones in
 // 🔄 同步 InteractiveClearManager 的清除区域到本地状态
            clearZones = convertToLegacyClearZones()
        }
        .onChange(of: theme.condition) { _, _ in
            // ✅ 切换天气时复位驱散状态，避免“上一种天气被驱散后下一种天气也看不到”的体验问题
            Task { @MainActor in
                interactiveClear.resetDisperseState()
            }
        }
        .onAppear {
            // ✅ 冷启动/首次进入：不应处于驱散状态（即使之前某次运行驱散过，也不应继承）
            if !didInitialReset {
                didInitialReset = true
                Task { @MainActor in
                    interactiveClear.resetDisperseState()
                }
            }
            SkyBridgeLogger.ui.debugOnly("🌦️ WeatherEffectView appeared - Condition: \(theme.condition.rawValue)")
            SkyBridgeLogger.ui.debugOnly("💡 提示：快速挥动鼠标2-3次即可驱散天气效果，露出星空背景！")
            loadPerformanceConfig()
        }
    }

 /// 根据天气条件返回对应的效果视图（增强版）
    @ViewBuilder
    private func weatherEffectView(for condition: WeatherCondition, in size: CGSize, config: PerformanceConfiguration) -> some View {
        if #available(macOS 14.0, *) {
            switch condition {
            case .clear:
// ☀️ 晴天 - 高级实现（不简化），由统一 clearManager 注入
                CinematicClearSkyEffectView(clearManager: interactiveClear)

            case .cloudy:
// ☁️ 多云 - 高级实现（AAA 风格体积云 + 电影级着色），由统一 clearManager 注入
                CinematicCloudyEffectView(
                    config: config,
                    coverage: max(0.65, theme.effectIntensity),
                    clearManager: interactiveClear
                )

            case .rainy:
// 🌧️ 雨天 - 高级实现（内部已包含暴风雨差异逻辑），由统一 clearManager 注入
                CinematicRainEffectView(clearManager: interactiveClear)

            case .snowy:
// ❄️ 雪天 - 高级实现（不简化），由统一 clearManager 注入
                CinematicSnowEffectView(clearManager: interactiveClear)

            case .foggy:
// 🌫️ 雾天 - 电影级体积雾（基于 clearZones 做清空）
                CinematicFogView(config: config, intensity: 0.6, clearZones: clearZones)
                    .opacity(interactiveClear.globalOpacity)

            case .haze:
                if #available(macOS 14.0, *) {
                    CinematicHazeView(
                        weatherManager: WeatherIntegrationManager.shared,
                        clearManager: interactiveClear
                    )
                } else {
                    EmptyView()
                }

            case .stormy:
 // ⛈️ 暴风雨 - 电影级：强化雨滴 + 闪电系统
                CinematicRainView(config: config)
                    .opacity(interactiveClear.globalOpacity)

            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func effectView(for effect: WeatherTheme.ParticleEffectType, in size: CGSize) -> some View {
        if let config = performanceConfig {
            switch effect {
            case .rain:
 // 🌧️ 雨天 - Apple风格动态雨滴
                if #available(macOS 14.0, *) {
                    AppleStyleRainView(config: config)
                }
            case .snow:
// ❄️ 雪天 - 高级实现
                CinematicSnowEffectView(clearManager: interactiveClear)
            case .fog(let intensity):
 // 🌫️ 雾天 - 可驱散的雾气
                FogEffectView(intensity: intensity, clearZones: clearZones)
            case .haze(let intensity):
 // 😶‍🌫️ 霾天 - 薄雾朦胧感
                if #available(macOS 14.0, *) {
                CinematicHazeView(
                    weatherManager: WeatherIntegrationManager.shared,
                    clearManager: interactiveClear
                )
            } else {
                HazeEffectView(intensity: intensity, clearZones: clearZones)
            }
            }
        } else {
            EmptyView()
        }
    }

 /// 加载性能配置
    private func loadPerformanceConfig() {
        Task { @MainActor in
            if #available(macOS 14.0, *) {
                let manager = PerformanceModeManager.shared

                    performanceConfig = manager.currentConfiguration
                    return
                }


 // 默认配置（极致性能）
            performanceConfig = PerformanceConfiguration(
                renderScale: 1.0,
                maxParticles: 12000,
                targetFrameRate: 120,
                metalFXQuality: 1.0,
                shadowQuality: 2,
                postProcessingLevel: 2,
                gpuFrequencyHint: 1.0,
                memoryBudget: 2048
            )
        }
    }

 /// 判断是否启用交互式驱散（支持所有天气类型）
    private func shouldEnableInteraction(for condition: WeatherCondition) -> Bool {
 // ✅ 所有天气都支持驱散效果！
        return true
    }

 /// 转换为旧版ClearZone格式（兼容现有代码）
    private func convertToLegacyClearZones() -> [ClearZone] {
        return interactiveClear.clearZones.map { zone in
            ClearZone(
                center: zone.center,
                radius: zone.radius,
 // 保留原始创建时间，避免每次刷新导致半径衰减时间戳重置
                timestamp: zone.createdAt
            )
        }
    }

}

/// 鼠标清除区域
public struct ClearZone: Identifiable {
    public let id = UUID()
    public let center: CGPoint
    public let radius: Double
    public let timestamp: Date

    public init(center: CGPoint, radius: Double, timestamp: Date) {
        self.center = center
        self.radius = radius
        self.timestamp = timestamp
    }

 /// 获取当前衰减半径
    public var currentRadius: Double {
        let elapsed = Date().timeIntervalSince(timestamp)
        let progress = elapsed / 1.0 // 1秒内完全消散
        return radius * (1.0 - progress)
    }
}

// MARK: - 雾霾效果视图（支持鼠标驱散）

struct HazeEffectView: View {
    let intensity: Double
    let clearZones: [ClearZone]

    @State private var animationOffset: CGFloat = 0

    var body: some View {
        Canvas { context, size in
 // 创建多层雾霾
            for layer in 0..<3 {
                let opacity = intensity * (1.0 - Double(layer) * 0.2)
                let layerOffset = animationOffset * CGFloat(layer + 1) * 10

 // 绘制雾霾纹理
                drawHazeLayer(
                    in: context,
                    size: size,
                    opacity: opacity,
                    offset: layerOffset,
                    clearZones: clearZones
                )
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                animationOffset = 1.0
            }
        }
    }

    private func drawHazeLayer(in context: GraphicsContext, size: CGSize, opacity: Double, offset: CGFloat, clearZones: [ClearZone]) {
 // 使用渐变模拟雾霾
        let gradient = Gradient(colors: [
            Color(red: 0.7, green: 0.7, blue: 0.65).opacity(opacity * 0.8),
            Color(red: 0.8, green: 0.75, blue: 0.7).opacity(opacity * 0.6),
            Color(red: 0.75, green: 0.7, blue: 0.68).opacity(opacity * 0.9)
        ])

        var context = context
        context.opacity = opacity

 // 绘制雾霾块（避开鼠标清除区域）
        let blockSize: CGFloat = 200
        let rows = Int(ceil(size.height / blockSize)) + 2
        let cols = Int(ceil(size.width / blockSize)) + 2

        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * blockSize + offset.truncatingRemainder(dividingBy: blockSize)
                let y = CGFloat(row) * blockSize

                let rect = CGRect(x: x, y: y, width: blockSize, height: blockSize)
                let center = CGPoint(x: rect.midX, y: rect.midY)

 // 计算是否在清除区域内（屏幕像素坐标）
 // 统一使用 currentRadius（基于创建时间的1秒线性衰减），并加入最小半径保护（12px），确保极端情况下清空效果仍然可见。
                var localOpacity = 1.0
                for zone in clearZones {
                    let distance = Double(hypot(center.x - zone.center.x, center.y - zone.center.y))
                    let safeRadius = max(zone.currentRadius, 12)
                    if distance < safeRadius {
                        let fadeOut = distance / safeRadius
                        localOpacity = min(localOpacity, fadeOut)
                    }
                }

                if localOpacity > 0.01 {
                    var localContext = context
                    localContext.opacity = opacity * localOpacity

                    let ellipse = Path(ellipseIn: rect)
                    localContext.fill(
                        ellipse,
                        with: .linearGradient(
                            gradient,
                            startPoint: .zero,
                            endPoint: CGPoint(x: blockSize, y: blockSize)
                        )
                    )
                }
            }
        }
    }
}

// MARK: - 雾效果视图

struct FogEffectView: View {
    let intensity: Double
    let clearZones: [ClearZone]

    @State private var animationOffset: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            for layer in 0..<2 {
                let opacity = intensity * (1.0 - Double(layer) * 0.3)
                let layerOffset = animationOffset * CGFloat(layer + 1) * 15

                drawFogLayer(
                    in: context,
                    size: size,
                    opacity: opacity,
                    offset: layerOffset,
                    clearZones: clearZones
                )
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 25).repeatForever(autoreverses: false)) {
                animationOffset = 1.0
            }
        }
    }

    private func drawFogLayer(in context: GraphicsContext, size: CGSize, opacity: Double, offset: CGFloat, clearZones: [ClearZone]) {
        let gradient = Gradient(colors: [
            Color.white.opacity(opacity * 0.5),
            Color(white: 0.9).opacity(opacity * 0.7),
            Color.white.opacity(opacity * 0.4)
        ])

        var context = context
        context.opacity = opacity

        let blockSize: CGFloat = 250
        let rows = Int(ceil(size.height / blockSize)) + 2
        let cols = Int(ceil(size.width / blockSize)) + 2

        for row in 0..<rows {
            for col in 0..<cols {
                let x = CGFloat(col) * blockSize + offset.truncatingRemainder(dividingBy: blockSize)
                let y = CGFloat(row) * blockSize

                let rect = CGRect(x: x, y: y, width: blockSize, height: blockSize)
                let center = CGPoint(x: rect.midX, y: rect.midY)

                var localOpacity = 1.0
                for zone in clearZones {
                    let distance = Double(hypot(center.x - zone.center.x, center.y - zone.center.y))
                    let safeRadius = max(zone.currentRadius, 12)
                    if distance < safeRadius {
                        localOpacity = min(localOpacity, distance / safeRadius)
                    }
                }

                if localOpacity > 0.01 {
                    var localContext = context
                    localContext.opacity = opacity * localOpacity

                    let ellipse = Path(ellipseIn: rect)
                    localContext.fill(
                        ellipse,
                        with: .radialGradient(
                            gradient,
                            center: CGPoint(x: blockSize / 2, y: blockSize / 2),
                            startRadius: 0,
                            endRadius: blockSize / 2
                        )
                    )
                }
            }
        }
    }
}

// MARK: - 雨效果视图

struct RainEffectView: View {
    @State private var raindrops: [Raindrop] = []

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
 // 更新雨滴
                updateRaindrops(for: size, at: timeline.date)

 // 绘制雨滴
                for drop in raindrops {
                    var path = Path()
                    path.move(to: drop.position)
                    path.addLine(to: CGPoint(x: drop.position.x - 2, y: drop.position.y + 20))

                    context.stroke(
                        path,
                        with: .color(.white.opacity(0.6)),
                        lineWidth: 1.5
                    )
                }
            }
        }
    }

    private func updateRaindrops(for size: CGSize, at date: Date) {
 // 移除超出屏幕的雨滴
        raindrops.removeAll { $0.position.y > size.height }

 // 添加新雨滴
        if raindrops.count < 100 {
            for _ in 0..<5 {
                raindrops.append(Raindrop(size: size))
            }
        }

 // 更新位置
        for i in raindrops.indices {
            raindrops[i].position.y += raindrops[i].speed
            raindrops[i].position.x -= 1
        }
    }

    struct Raindrop {
        var position: CGPoint
        let speed: CGFloat

        init(size: CGSize) {
            self.position = CGPoint(
                x: CGFloat.random(in: 0...size.width),
                y: CGFloat.random(in: -50...0)
            )
            self.speed = CGFloat.random(in: 15...25)
        }
    }
}

// MARK: - 雪效果视图

struct SnowEffectView: View {
    @State private var snowflakes: [Snowflake] = []

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                updateSnowflakes(for: size)

                for flake in snowflakes {
                    let rect = CGRect(
                        x: flake.position.x,
                        y: flake.position.y,
                        width: flake.size,
                        height: flake.size
                    )

                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(0.8))
                    )
                }
            }
        }
    }

    private func updateSnowflakes(for size: CGSize) {
        snowflakes.removeAll { $0.position.y > size.height }

        if snowflakes.count < 50 {
            for _ in 0..<2 {
                snowflakes.append(Snowflake(size: size))
            }
        }

        for i in snowflakes.indices {
            snowflakes[i].position.y += snowflakes[i].speed
            snowflakes[i].position.x += sin(snowflakes[i].position.y / 30) * 0.5
        }
    }

    struct Snowflake {
        var position: CGPoint
        let speed: CGFloat
        let size: CGFloat

        init(size: CGSize) {
            self.position = CGPoint(
                x: CGFloat.random(in: 0...size.width),
                y: CGFloat.random(in: -50...0)
            )
            self.speed = CGFloat.random(in: 1...3)
            self.size = CGFloat.random(in: 3...8)
        }
    }
}

// MARK: - 鼠标追踪视图

struct MouseTrackingView: NSViewRepresentable {
    let onMouseMove: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MouseTrackingNSView()
        view.onMouseMove = onMouseMove
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class MouseTrackingNSView: NSView {
        var onMouseMove: ((CGPoint) -> Void)?
        var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea = trackingArea {
                removeTrackingArea(trackingArea)
            }

            trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )

            if let trackingArea = trackingArea {
                addTrackingArea(trackingArea)
            }
        }

        override func mouseMoved(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
 // 转换为从顶部开始的坐标系
            let flippedY = bounds.height - location.y
            onMouseMove?(CGPoint(x: location.x, y: flippedY))
        }
    }
}

