//
// RainEffectSystem.swift
// SkyBridgeCore
//
// 完整的雨天拟真系统 - 支持4种性能模式
// Created: 2025-10-19
//

import SwiftUI
import AppKit
import OSLog

/// 雨天效果配置（根据性能模式）
public struct RainEffectConfiguration: Sendable {
    let raindropsCount: Int        // 雨滴数量
    let cloudLayers: Int           // 云层数量
    let waterDropsOnGlass: Int     // 玻璃上的水珠数量
    let puddleEnabled: Bool        // 是否启用积水
    let ripplesEnabled: Bool       // 是否启用涟漪
    let glassWaterDropsEnabled: Bool // 玻璃水珠
    
 /// 根据性能模式获取配置
    public static func configuration(for mode: String) -> RainEffectConfiguration {
        switch mode.lowercased() {
        case "extreme", "极致":
            return RainEffectConfiguration(
                raindropsCount: 200,
                cloudLayers: 3,
                waterDropsOnGlass: 30,
                puddleEnabled: true,
                ripplesEnabled: true,
                glassWaterDropsEnabled: true
            )
        case "balanced", "平衡":
            return RainEffectConfiguration(
                raindropsCount: 100,
                cloudLayers: 2,
                waterDropsOnGlass: 15,
                puddleEnabled: true,
                ripplesEnabled: true,
                glassWaterDropsEnabled: true
            )
        case "energysaving", "节能":
            return RainEffectConfiguration(
                raindropsCount: 50,
                cloudLayers: 1,
                waterDropsOnGlass: 8,
                puddleEnabled: false,
                ripplesEnabled: false,
                glassWaterDropsEnabled: true
            )
        case "adaptive", "自适应":
            return RainEffectConfiguration(
                raindropsCount: 100,
                cloudLayers: 2,
                waterDropsOnGlass: 15,
                puddleEnabled: true,
                ripplesEnabled: true,
                glassWaterDropsEnabled: true
            )
        default:
            return RainEffectConfiguration(
                raindropsCount: 100,
                cloudLayers: 2,
                waterDropsOnGlass: 15,
                puddleEnabled: true,
                ripplesEnabled: true,
                glassWaterDropsEnabled: true
            )
        }
    }
}

// MARK: - 完整雨天效果视图

@MainActor
public struct CompleteRainEffectView: View {
    public let config: RainEffectConfiguration
    public let clearZones: [ClearZone]
    
    @State private var animationTime: Double = 0
    @State private var cloudOffset: CGFloat = 0
    @State private var raindrops: [EnhancedRaindrop] = []
    @State private var glassWaterDrops: [GlassWaterDrop] = []
    @State private var ripples: [Ripple] = []
    @State private var animationTimer: Timer?
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "RainEffect")
    
    public init(config: RainEffectConfiguration, clearZones: [ClearZone]) {
        self.config = config
        self.clearZones = clearZones
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
 // 1️⃣ 顶部乌云层
                if config.cloudLayers > 0 {
                    CloudLayer(
                        layerCount: config.cloudLayers,
                        offset: cloudOffset
                    )
                    .frame(height: geometry.size.height * 0.3)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                
 // 2️⃣ 雨滴下落粒子
                Canvas { context, size in
                    for drop in raindrops {
                        drawRaindrop(drop, in: context, size: size)
                    }
                }
                
 // 3️⃣ 液态玻璃水珠（覆盖层）
                if config.glassWaterDropsEnabled {
                    Canvas { context, size in
                        for waterDrop in glassWaterDrops {
                            drawGlassWaterDrop(waterDrop, in: context)
                        }
                    }
                    .allowsHitTesting(false)
                }
                
 // 4️⃣ 底部积水效果
                if config.puddleEnabled {
                    PuddleLayer()
                        .frame(height: 80)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                
 // 5️⃣ 雨滴落地涟漪
                if config.ripplesEnabled {
                    Canvas { context, size in
                        for ripple in ripples {
                            drawRipple(ripple, in: context, size: size)
                        }
                    }
                }
            }
        }
        .onAppear {
            initializeRaindrops()
            initializeGlassWaterDrops()
            startAnimation()
        }
        .onDisappear {
            stopAnimation()
        }
    }
    
 // MARK: - 初始化
    
    private func initializeRaindrops() {
        raindrops = (0..<config.raindropsCount).map { _ in
            EnhancedRaindrop()
        }
    }
    
    private func initializeGlassWaterDrops() {
        glassWaterDrops = (0..<config.waterDropsOnGlass).map { _ in
            GlassWaterDrop()
        }
    }
    
    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
            Task { @MainActor in
                updateRaindrops()
                updateGlassWaterDrops()
                updateClouds()
                if config.ripplesEnabled {
                    updateRipples()
                }
            }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

 // MARK: - 更新逻辑
    
    private func updateRaindrops() {
        for i in raindrops.indices {
            raindrops[i].position.y += raindrops[i].speed
            raindrops[i].position.x += raindrops[i].windDrift
            
 // 超出屏幕底部时重置
            if raindrops[i].position.y > (NSScreen.main?.frame.height ?? 900) {
                raindrops[i] = EnhancedRaindrop()
                
 // 生成涟漪
                if config.ripplesEnabled {
                    ripples.append(Ripple(
                        position: CGPoint(
                            x: raindrops[i].position.x,
                            y: (NSScreen.main?.frame.height ?? 900) - 80
                        )
                    ))
                }
            }
        }
    }
    
    private func updateGlassWaterDrops() {
        for i in glassWaterDrops.indices {
 // 水珠缓慢下滑
            if glassWaterDrops[i].isSliding {
                glassWaterDrops[i].position.y += glassWaterDrops[i].slideSpeed
                
 // 到达底部后重置
                if glassWaterDrops[i].position.y > (NSScreen.main?.frame.height ?? 900) {
                    glassWaterDrops[i] = GlassWaterDrop()
                }
            }
        }
    }
    
    private func updateClouds() {
        cloudOffset += 0.1
        if cloudOffset > 100 {
            cloudOffset = 0
        }
    }
    
    private func updateRipples() {
 // 移除已完成的涟漪
        ripples.removeAll { $0.progress > 1.0 }
        
 // 更新涟漪进度
        for i in ripples.indices {
            ripples[i].progress += 0.02
        }
    }
    
 // MARK: - 绘制方法
    
    private func drawRaindrop(_ drop: EnhancedRaindrop, in context: GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: drop.position)
        path.addLine(to: CGPoint(
            x: drop.position.x - 1,
            y: drop.position.y + drop.length
        ))
        
        context.stroke(
            path,
            with: .color(.white.opacity(drop.opacity)),
            lineWidth: drop.thickness
        )
    }
    
    private func drawGlassWaterDrop(_ drop: GlassWaterDrop, in context: GraphicsContext) {
 // 绘制水珠主体（椭圆）
        let dropRect = CGRect(
            x: drop.position.x - drop.size / 2,
            y: drop.position.y - drop.size,
            width: drop.size,
            height: drop.size * 1.5
        )
        
        let waterDropPath = Path(ellipseIn: dropRect)
        
 // 填充渐变（模拟光泽）
        let gradient = Gradient(colors: [
            Color.white.opacity(0.3),
            Color.white.opacity(0.1),
            Color.white.opacity(0.05)
        ])
        
        context.fill(
            waterDropPath,
            with: .radialGradient(
                gradient,
                center: CGPoint(x: dropRect.midX, y: dropRect.minY + dropRect.height * 0.3),
                startRadius: 0,
                endRadius: drop.size
            )
        )
        
 // 绘制高光
        let highlightRect = CGRect(
            x: drop.position.x - drop.size / 4,
            y: drop.position.y - drop.size * 0.8,
            width: drop.size / 2,
            height: drop.size / 2
        )
        
        context.fill(
            Path(ellipseIn: highlightRect),
            with: .color(.white.opacity(0.6))
        )
    }
    
    private func drawRipple(_ ripple: Ripple, in context: GraphicsContext, size: CGSize) {
        let radius = ripple.maxRadius * ripple.progress
        let opacity = 1.0 - ripple.progress
        
        let ripplePath = Path(
            ellipseIn: CGRect(
                x: ripple.position.x - radius,
                y: ripple.position.y - radius / 2,
                width: radius * 2,
                height: radius
            )
        )
        
        context.stroke(
            ripplePath,
            with: .color(.white.opacity(opacity * 0.4)),
            lineWidth: 2
        )
    }
}


// MARK: - 雨滴数据模型

struct EnhancedRaindrop {
    var position: CGPoint
    var speed: CGFloat
    var windDrift: CGFloat
    var length: CGFloat
    var thickness: CGFloat
    var opacity: Double
    
    init() {
        let screenWidth = NSScreen.main?.frame.width ?? 1200
        self.position = CGPoint(
            x: CGFloat.random(in: 0...screenWidth),
            y: CGFloat.random(in: -100...0)
        )
        self.speed = CGFloat.random(in: 20...30)
        self.windDrift = CGFloat.random(in: -1...1)
        self.length = CGFloat.random(in: 15...25)
        self.thickness = CGFloat.random(in: 1...2)
        self.opacity = Double.random(in: 0.4...0.8)
    }
}

// MARK: - 玻璃水珠模型

struct GlassWaterDrop {
    var position: CGPoint
    var size: CGFloat
    var isSliding: Bool
    var slideSpeed: CGFloat
    
    init() {
        let screenWidth = NSScreen.main?.frame.width ?? 1200
        let screenHeight = NSScreen.main?.frame.height ?? 900
        self.position = CGPoint(
            x: CGFloat.random(in: 0...screenWidth),
            y: CGFloat.random(in: 0...screenHeight)
        )
        self.size = CGFloat.random(in: 4...12)
        self.isSliding = Bool.random()
        self.slideSpeed = CGFloat.random(in: 0.2...0.5)
    }
}

// MARK: - 涟漪模型

struct Ripple {
    let position: CGPoint
    let maxRadius: CGFloat
    var progress: Double
    
    init(position: CGPoint) {
        self.position = position
        self.maxRadius = CGFloat.random(in: 20...40)
        self.progress = 0.0
    }
}

// MARK: - 乌云层视图

struct CloudLayer: View {
    let layerCount: Int
    let offset: CGFloat
    
    var body: some View {
        ZStack {
            ForEach(0..<layerCount, id: \.self) { index in
                GeometryReader { geometry in
                    Canvas { context, size in
                        drawCloudLayer(
                            index: index,
                            in: context,
                            size: size,
                            offset: offset
                        )
                    }
                }
                .opacity(Double(layerCount - index) / Double(layerCount + 1))
            }
        }
    }
    
    private func drawCloudLayer(index: Int, in context: GraphicsContext, size: CGSize, offset: CGFloat) {
        let cloudCount = 5
        let layerOffset = offset + CGFloat(index * 30)
        
        for i in 0..<cloudCount {
            let x = (CGFloat(i) * size.width / CGFloat(cloudCount) + layerOffset)
                .truncatingRemainder(dividingBy: size.width + 200) - 100
            let y = CGFloat(index) * 30 + 20
            
            drawCloud(at: CGPoint(x: x, y: y), in: context, size: size)
        }
    }
    
    private func drawCloud(at position: CGPoint, in context: GraphicsContext, size: CGSize) {
 // 绘制多个椭圆组成的云朵
        let cloudParts: [(CGSize, CGPoint)] = [
            (CGSize(width: 80, height: 40), CGPoint(x: 0, y: 0)),
            (CGSize(width: 60, height: 35), CGPoint(x: -30, y: 5)),
            (CGSize(width: 70, height: 38), CGPoint(x: 30, y: 3)),
            (CGSize(width: 50, height: 30), CGPoint(x: 50, y: 8))
        ]
        
        for (partSize, offset) in cloudParts {
            let rect = CGRect(
                x: position.x + offset.x - partSize.width / 2,
                y: position.y + offset.y - partSize.height / 2,
                width: partSize.width,
                height: partSize.height
            )
            
            let gradient = Gradient(colors: [
                Color(white: 0.2, opacity: 0.8),
                Color(white: 0.3, opacity: 0.6),
                Color(white: 0.25, opacity: 0.7)
            ])
            
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: partSize.width / 2
                )
            )
        }
    }
}

// MARK: - 积水层视图

struct PuddleLayer: View {
    @State private var shimmerOffset: CGFloat = 0
    
    var body: some View {
        ZStack {
 // 基础积水层
            LinearGradient(
                colors: [
                    Color(white: 0.2, opacity: 0.3),
                    Color(white: 0.3, opacity: 0.5),
                    Color(white: 0.25, opacity: 0.4)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
 // 波光粼粼效果
            GeometryReader { geometry in
                Canvas { context, size in
                    for i in 0..<5 {
                        let x = (CGFloat(i) * size.width / 5 + shimmerOffset)
                            .truncatingRemainder(dividingBy: size.width)
                        
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + 50, y: size.height))
                        
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.1)),
                            lineWidth: 1
                        )
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                shimmerOffset = NSScreen.main?.frame.width ?? 1200
            }
        }
    }
}
