//
// CinematicClearSkyEffectView.swift
// SkyBridgeCompassApp
//
// 🌤️ 优雅晴天效果 - 液态玻璃折射与反光
// 通过光线折射、焦散效应、动态光斑表现阳光
// Created: 2025-10-19
//

import SwiftUI
import SkyBridgeCore

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
 // 🌈 光效粒子
    @State private var lightSpots: [LightSpot] = []
    @State private var causticRays: [CausticRay] = []
    @State private var glowParticles: [GlowParticle] = []
    
 // ⏱️ 时间状态
    @State private var timeOffset: Double = 0
    @State private var lastFrameTime: TimeInterval = 0
    
 // 🎨 动态参数
    @State private var ambientBrightness: Double = 1.0
    @State private var refractionPhase: Double = 0
 // 🛰️ 远程桌面门控（统一暂停/恢复）
    @State private var isRemoteDesktopActive: Bool = false
 // ⏱️ 计时器统一持有
    @State private var ambientTimer: Timer?
    @State private var reflectionFlickerTimer: Timer?
 // ✨ 镜面反射/光晕闪烁调制因子
    @State private var reflectionFlickerFactor: Double = 1.0
 // 统一时间累加器（替换原有 Timer），借助 TimelineView 的帧节拍触发
    @State private var lastTick: Date = .now
    @State private var ambientAcc: TimeInterval = 0
    @State private var reflectionAcc: TimeInterval = 0
    
 // 🖱️ 交互式驱散
    @StateObject private var clearManager = InteractiveClearManager()
    
    public init() {}
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
 // 1️⃣ 天空渐变背景（柔和的蓝到金）
                skyGradientBackground()
                
 // 2️⃣ 主效果层
                TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let _ = scheduleTickClearSky(remoteActive: isRemoteDesktopActive, now: timeline.date)
                    
                    Canvas { context, size in
 // 🌊 焦散效应（水波纹状光投影）
                        drawCausticPatterns(context: &context, size: size, time: time)
                        
 // ✨ 动态光斑（阳光在玻璃上的反射）
                        drawDynamicLightSpots(context: &context, size: size, time: time)
                        
 // 💫 细微光晕粒子（漂浮的光点）
                        drawGlowParticles(context: &context, size: size, time: time)
                        
 // 🎭 镜头光晕（柔和的光晕效果）
                        drawLensFlare(context: &context, size: size, time: time)
                    }
                    .onChange(of: time) { _, newTime in
 // ⚠️ 避免在视图更新过程中直接修改状态，移入主线程
                        Task { @MainActor in
                            updateParticlePhysics(time: newTime, screenSize: geometry.size)
                        }
                    }
                }
            }
            .opacity(clearManager.globalOpacity)  // 🔥 驱散效果应用到整个 ZStack
        }
        .ignoresSafeArea()
        .onAppear {
            initializeParticles()
 // 不再启动 Timer，所有系统由 TimelineView 的累加器统一调度
 // 🔥 启动交互式清空管理器
            Task {
 // start() 为同步方法，直接调用；移除不必要的 await。
            clearManager.start()
            }
        }
        .onDisappear {
 // 🛑 统一暂停所有特效系统并释放计时器
            pauseAllEffectSystems()
 // 🔥 停止交互式清空管理器
            Task {
 // stop() 为同步方法，直接调用；移除不必要的 await。
            clearManager.stop()
            }
        }
 // 🔥 使用 onReceive 自动管理监听器生命周期
        .onReceive(NotificationCenter.default.publisher(for: GlobalMouseTracker.mouseMovedNotification)) { notification in
            if let locationValue = notification.userInfo?["location"] as? NSValue {
                let nsPoint = locationValue.pointValue
                let location = CGPoint(x: nsPoint.x, y: nsPoint.y)
                clearManager.handleMouseMove(location)
            }
        }
 // 📡 远程桌面会话指标：用于统一暂停/恢复所有系统
        .onReceive(RemoteDesktopManager.shared.metrics) { snapshot in
            isRemoteDesktopActive = snapshot.activeSessions > 0
        }
        .onChange(of: isRemoteDesktopActive) { oldValue, newValue in
            if newValue {
                pauseAllEffectSystems()
            } else {
                resumeAllEffectSystems()
            }
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
    
 // MARK: - 粒子更新
    
    private func updateParticlePhysics(time: TimeInterval, screenSize: CGSize) {
        let deltaTime: CGFloat = lastFrameTime > 0 ? CGFloat(time - lastFrameTime) : 0.016
        lastFrameTime = time
        timeOffset = time
        
 // 更新光斑位置
        for i in 0..<lightSpots.count {
            lightSpots[i].x += lightSpots[i].velocityX * deltaTime / screenSize.width
            lightSpots[i].y += lightSpots[i].velocityY * deltaTime / screenSize.height
            
 // 边界循环
            if lightSpots[i].x < -0.2 || lightSpots[i].x > 1.2 {
                lightSpots[i].x = CGFloat.random(in: 0...1)
            }
            if lightSpots[i].y < -0.2 || lightSpots[i].y > 1.2 {
                lightSpots[i].y = CGFloat.random(in: 0...1)
            }
            
 // 脉动效果
            lightSpots[i].pulsePhase += Double(deltaTime)
        }
        
 // 更新焦散光线
        for i in 0..<causticRays.count {
            causticRays[i].phase += Double(deltaTime) * 0.5
            causticRays[i].x += sin(causticRays[i].phase) * 0.01
        }
        
 // 更新光晕粒子
        for i in 0..<glowParticles.count {
            glowParticles[i].x += glowParticles[i].velocityX * deltaTime / screenSize.width
            glowParticles[i].y += glowParticles[i].velocityY * deltaTime / screenSize.height
            
 // 边界循环
            if glowParticles[i].x < -0.1 || glowParticles[i].x > 1.1 {
                glowParticles[i].x = CGFloat.random(in: 0...1)
            }
            if glowParticles[i].y < -0.1 || glowParticles[i].y > 1.1 {
                glowParticles[i].y = CGFloat.random(in: 0...1)
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
 // ✨ 引入微弱闪烁调制（保持在 0.9-1.1 范围内）
        let flicker = max(0.9, min(1.1, reflectionFlickerFactor))
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
    
 // MARK: - 动画控制
    
    private func startAmbientAnimation() {
 // 环境光照变化
        ambientTimer?.invalidate()
        ambientTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
 // 在主线程读取状态以满足并发模型
                guard !isRemoteDesktopActive else { return }
                let time = Date().timeIntervalSinceReferenceDate
                ambientBrightness = sin(time * 0.2) * 0.1 + 0.9
            }
        }
    }

 /// 启动镜面反射/光晕闪烁系统（细微的强度抖动）
    private func startReflectionFlickerSystem() {
        reflectionFlickerTimer?.invalidate()
        reflectionFlickerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            Task { @MainActor in
 // 在主线程读取状态以满足并发模型
                guard !isRemoteDesktopActive else { return }
                let t = Date().timeIntervalSinceReferenceDate
 // 两组较快的正弦叠加，产生细微闪烁（范围约 0.9 - 1.1）
                let s = sin(t * 2.4) * 0.5 + sin(t * 3.8 + 1.2) * 0.3
                reflectionFlickerFactor = 0.95 + max(-0.1, min(0.1, s))
            }
        }
    }

 /// 统一暂停所有特效系统（释放计时器）
    private func pauseAllEffectSystems() {
        ambientTimer?.invalidate(); ambientTimer = nil
        reflectionFlickerTimer?.invalidate(); reflectionFlickerTimer = nil
    }

 /// 统一恢复所有特效系统（重新启动计时器）
    private func resumeAllEffectSystems() {
 // 采用 TimelineView 帧驱动，无需恢复任何 Timer
    }
    
 // MARK: - 统一调度用的更新方法（替代原 Timer 回调）
    private func scheduleTickClearSky(remoteActive: Bool, now: Date) {
        Task { @MainActor in
            let dt = max(0, now.timeIntervalSince(lastTick))
            lastTick = now
            guard !remoteActive else { return }
            ambientAcc += dt
            if ambientAcc >= 0.1 {
                updateAmbient()
                ambientAcc = 0
            }
            reflectionAcc += dt
            if reflectionAcc >= 0.08 {
                updateReflectionFlickerClearSky()
                reflectionAcc = 0
            }
        }
    }
    
    private func updateAmbient() {
 // 环境亮度按时间缓慢变化，范围约 0.8-1.0
        let time = Date().timeIntervalSinceReferenceDate
        ambientBrightness = sin(time * 0.2) * 0.1 + 0.9
    }
    
    private func updateReflectionFlickerClearSky() {
 // 两组正弦叠加产生细微闪烁（范围约 0.9 - 1.1）
        let t = Date().timeIntervalSinceReferenceDate
        let s = sin(t * 2.4) * 0.5 + sin(t * 3.8 + 1.2) * 0.3
        reflectionFlickerFactor = 0.95 + max(-0.1, min(0.1, s))
    }
}
