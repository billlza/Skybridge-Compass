// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// CinematicClearSkyEffectView.swift
// SkyBridgeCompassApp
//
// 🌤️ 优雅晴天效果 - 液态玻璃折射与反光
// 通过光线折射、焦散效应、动态光斑表现阳光
// Created: 2025-10-19
//

import SwiftUI

/// 光斑粒子（阳光在玻璃上的反射）
struct LightSpot: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var intensity: Double
    var hue: Double  // 色调（彩虹色散）
    var velocityX: CGFloat
    var velocityY: CGFloat
    var pulsePhase: Double
}

/// 焦散光线（水波纹状投影）
struct CausticRay: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var angle: CGFloat
    var intensity: Double
    var phase: Double
}

/// 光晕粒子（细微的浮动光点）
struct GlowParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var opacity: Double
    var velocityX: CGFloat
    var velocityY: CGFloat
    let layer: Int
}

@available(macOS 14.0, *)
public struct CinematicClearSkyEffectView: View {
    private static let animationEpoch = Date()

 // 🌈 光效粒子
    @State private var lightSpots: [LightSpot] = []
    @State private var causticRays: [CausticRay] = []
    @State private var glowParticles: [GlowParticle] = []
    
 // 🛰️ 远程桌面门控（统一暂停/恢复）
    @State private var isRemoteDesktopActive: Bool = false
    
 // 🖱️ 交互式驱散（由统一入口 WeatherEffectView 注入；避免重复创建/重复监听）
    @ObservedObject private var clearManager: InteractiveClearManager
    
    public init(clearManager: InteractiveClearManager) {
        self.clearManager = clearManager
    }
    
    public var body: some View {
        GeometryReader { _ in
            ZStack {
 // 1️⃣ 天空渐变背景（柔和的蓝到金）
                skyGradientBackground()
                
 // 2️⃣ 主效果层
                TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
                    let time = timeline.date.timeIntervalSince(Self.animationEpoch)
                    
                    Canvas { context, size in
                        guard !isRemoteDesktopActive else { return }

 // 🌊 焦散效应（水波纹状光投影）
                        drawCausticPatterns(context: &context, size: size, time: time)
                        
 // ✨ 动态光斑（阳光在玻璃上的反射）
                        drawDynamicLightSpots(context: &context, size: size, time: time)
                        
 // 💫 细微光晕粒子（漂浮的光点）
                        drawGlowParticles(context: &context, size: size, time: time)
                        
 // 🎭 镜头光晕（柔和的光晕效果）
                        drawLensFlare(context: &context, size: size, time: time)
                    }
                }
            }
            .opacity(clearManager.globalOpacity)  // 🔥 驱散效果应用到整个 ZStack
        }
        .ignoresSafeArea()
        .onAppear {
            initializeParticles()
 // 🔥 启动交互式清空管理器
 // start() 为同步方法，直接调用；移除不必要的 await。
            clearManager.start()
        }
 // 📡 远程桌面会话指标：用于统一暂停/恢复所有系统
        .onReceive(RemoteDesktopManager.shared.metrics) { snapshot in
            isRemoteDesktopActive = snapshot.activeSessions > 0
        }
    }
    
 // MARK: - 天空渐变背景
    
 /// 天空渐变（深蓝 → 浅蓝 → 淡金）
    @ViewBuilder
    private func skyGradientBackground() -> some View {
        LinearGradient(
            colors: [
                Color(red: 0.4, green: 0.6, blue: 0.9),   // 深天蓝
                Color(red: 0.6, green: 0.8, blue: 1.0),   // 浅天蓝
                Color(red: 0.9, green: 0.95, blue: 0.98), // 淡白蓝
                Color(red: 1.0, green: 0.98, blue: 0.9)   // 淡金色（暗示阳光）
            ],
            startPoint: .top,
                endPoint: .bottom
        )
        .opacity(0.6)
    }
    
 // MARK: - 粒子初始化
    
    private func initializeParticles() {
        guard lightSpots.isEmpty, causticRays.isEmpty, glowParticles.isEmpty else { return }

 // 创建 15 个动态光斑（大小不一，缓慢移动）
        for i in 0..<15 {
            lightSpots.append(LightSpot(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                size: CGFloat.random(in: 80...200),
                intensity: Double.random(in: 0.15...0.35),
                hue: Double.random(in: 0...360),  // 彩虹色散
                velocityX: CGFloat.random(in: -5...5),
                velocityY: CGFloat.random(in: -5...5),
                pulsePhase: Double(i) * 0.5
            ))
        }
        
 // 创建 20 条焦散光线（水波纹状）
        for i in 0..<20 {
            causticRays.append(CausticRay(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                width: CGFloat.random(in: 100...300),
                angle: CGFloat.random(in: 0...360),
                intensity: Double.random(in: 0.1...0.25),
                phase: Double(i) * 0.3
            ))
        }
        
 // 创建 100 个细微光晕粒子（三层景深）
        for layer in 0..<3 {
            let count = layer == 0 ? 30 : (layer == 1 ? 40 : 30)
            for _ in 0..<count {
                glowParticles.append(GlowParticle(
                    x: CGFloat.random(in: 0...1),
                    y: CGFloat.random(in: 0...1),
                    size: CGFloat.random(in: 2...8),
                    opacity: Double.random(in: 0.3...0.7),
                    velocityX: CGFloat.random(in: -3...3),
                    velocityY: CGFloat.random(in: -3...3),
                    layer: layer
                ))
            }
        }
    }
    
 // MARK: - 绘制方法
    
 /// 绘制焦散图案（水波纹状光投影）
    private func drawCausticPatterns(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        for ray in causticRays {
            let x = ray.x * size.width
            let y = ray.y * size.height
            
 // 计算动态波动
            let wave = sin(ray.phase + time * 0.5) * 20
            
 // 椭圆形光束
            let rect = CGRect(
                x: x + wave,
                y: y,
                width: ray.width,
                height: ray.width * 0.3
            )
            
 // 渐变光束（模拟焦散）
            let gradient = Gradient(colors: [
                Color.clear,
                Color.white.opacity(ray.intensity * 0.5),
                Color.cyan.opacity(ray.intensity * 0.3),
                Color.clear
            ])
            
            var ctx = context
            ctx.opacity = ray.intensity
            ctx.rotate(by: .degrees(ray.angle))
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: ray.width * 0.5
                )
            )
        }
    }
    
 /// 绘制动态光斑（阳光在玻璃上的反射）
    private func drawDynamicLightSpots(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        for spot in lightSpots {
            let x = spot.x * size.width
            let y = spot.y * size.height
            
 // 脉动强度
            let pulse = sin(spot.pulsePhase + time * 0.8) * 0.3 + 0.7
            let currentIntensity = spot.intensity * pulse
            
 // 色散效果（彩虹色）
            let hue = (spot.hue + time * 10).truncatingRemainder(dividingBy: 360)
            let color = Color(hue: hue / 360.0, saturation: 0.3, brightness: 1.0)
            
 // 多层光晕（模拟折射）
            for layer in 0..<3 {
                let layerSize = spot.size * (1.0 + CGFloat(layer) * 0.4)
                let layerOpacity = currentIntensity / Double(layer + 1)
                
                let rect = CGRect(
                    x: x - layerSize / 2,
                    y: y - layerSize / 2,
                    width: layerSize,
                    height: layerSize
                )
                
 // 径向渐变
                let gradient = Gradient(colors: [
                    color.opacity(layerOpacity * 0.8),
                    color.opacity(layerOpacity * 0.4),
                    Color.white.opacity(layerOpacity * 0.2),
                    Color.clear
                ])
                
                context.opacity = layerOpacity
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        gradient,
                        center: CGPoint(x: x, y: y),
                        startRadius: 0,
                        endRadius: layerSize * 0.6
                    )
                )
            }
        }
    }
    
 /// 绘制细微光晕粒子
    private func drawGlowParticles(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        for particle in glowParticles {
            let x = particle.x * size.width
            let y = particle.y * size.height
            
 // 景深模糊
            let blur: CGFloat = particle.layer == 0 ? 0 : (particle.layer == 1 ? 1.5 : 3.0)
            
            let rect = CGRect(
                x: x - particle.size / 2,
                y: y - particle.size / 2,
                width: particle.size,
                height: particle.size
            )
            
            var ctx = context
            if blur > 0 {
                ctx.addFilter(.blur(radius: blur))
            }
            
            ctx.opacity = particle.opacity * 0.6
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [
                        Color.white.opacity(0.8),
                        Color.cyan.opacity(0.4),
                        Color.clear
                    ]),
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: particle.size * 0.5
                )
            )
        }
    }
    
 /// 绘制镜头光晕（柔和的全屏光晕）
    private func drawLensFlare(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
 // 光晕位置（右上角，模拟阳光方向）
        let flareX = size.width * 0.75
        let flareY = size.height * 0.2
        
 // 动态强度
        let baseIntensity = sin(time * 0.3) * 0.1 + 0.15
 // ✨ 纯时间驱动微弱闪烁（保持在 0.85-1.05 范围内），避免每帧写 @State。
        let flickerSignal = sin(time * 2.4) * 0.5 + sin(time * 3.8 + 1.2) * 0.3
        let flicker = 0.95 + max(-0.1, min(0.1, flickerSignal))
        let intensity = baseIntensity * flicker
        
 // 主光晕
        let mainFlareRect = CGRect(
            x: flareX - 300,
            y: flareY - 300,
            width: 600,
            height: 600
        )
        
        let mainGradient = Gradient(colors: [
            Color.white.opacity(intensity * 0.4),
            Color.yellow.opacity(intensity * 0.3),
            Color.orange.opacity(intensity * 0.2),
            Color.clear
        ])
        
        context.opacity = intensity
        context.fill(
            Path(ellipseIn: mainFlareRect),
            with: .radialGradient(
                mainGradient,
                center: CGPoint(x: flareX, y: flareY),
                startRadius: 0,
                endRadius: 400
            )
        )
        
 // 次级光晕（镜头反射）
        let secondaryX = size.width * 0.3
        let secondaryY = size.height * 0.6
        
        let secondaryRect = CGRect(
            x: secondaryX - 150,
            y: secondaryY - 150,
            width: 300,
            height: 300
        )
        
        context.opacity = intensity * 0.5
        context.fill(
            Path(ellipseIn: secondaryRect),
            with: .radialGradient(
                Gradient(colors: [
                    Color.cyan.opacity(intensity * 0.3),
                    Color.blue.opacity(intensity * 0.2),
                    Color.clear
                ]),
                center: CGPoint(x: secondaryX, y: secondaryY),
                startRadius: 0,
                endRadius: 200
            )
        )
    }
    
}
#endif
