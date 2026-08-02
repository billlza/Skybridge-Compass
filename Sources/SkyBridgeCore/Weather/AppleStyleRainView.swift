// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// AppleStyleRainView.swift
// SkyBridgeCore
//
// Apple风格动态雨天效果 - 参考Apple Weather壁纸
// 特性：景深、物理模拟、流畅动画
// Created: 2025-10-19
//

import SwiftUI
import OSLog

/// Apple风格雨天视图 - 真实物理模拟 + 景深效果
@available(macOS 14.0, *)
public struct AppleStyleRainView: View {
    let config: PerformanceConfiguration
    
    @State private var particles: [RainParticle] = []
    @State private var clouds: [ParallaxCloudLayer] = []
    @State private var glassDroplets: [GlassDroplet] = []
    @State private var ripples: [SurfaceRipple] = []
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "AppleRain")
    
    public init(config: PerformanceConfiguration) {
        self.config = config
    }
    
    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                
 // 使用时间线驱动动画，而非定时器触发状态更新
                updateAndDrawScene(context: context, size: size, time: time)
            }
        }
        .onAppear {
            initializeScene()
        }
    }
    
 // MARK: - 场景初始化
    
    private func initializeScene() {
        let screenWidth = NSScreen.main?.frame.width ?? 1920
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        
 // 🎯 质量优先：基于性能模式动态调整
        let particleCount: Int
        let cloudCount: Int
        let dropletCount: Int
        
        switch config.targetFrameRate {
        case 120: // 极致性能
            particleCount = 300
            cloudCount = 5
            dropletCount = 50
        case 60: // 平衡
            particleCount = 200
            cloudCount = 3
            dropletCount = 30
        case 30: // 节能
            particleCount = 100
            cloudCount = 2
            dropletCount = 15
        default: // 自适应
            particleCount = 150
            cloudCount = 3
            dropletCount = 25
        }
        
 // 初始化雨滴（3个景深层）
        particles = (0..<particleCount).map { i in
            let depth = CGFloat.random(in: 0...1)
            return RainParticle(
                position: CGPoint(
                    x: CGFloat.random(in: 0...screenWidth),
                    y: CGFloat.random(in: -screenHeight...0)
                ),
                velocity: CGPoint(
                    x: CGFloat.random(in: -2...2),
                    y: 300 + depth * 500 // 近处更快
                ),
                length: 20 + depth * 40, // 近处更长
                thickness: 1.5 + depth * 2,
                depth: depth, // 0=远，1=近
                opacity: 0.3 + depth * 0.6,
                phase: Double(i) / Double(particleCount)
            )
        }
        
 // 初始化云层（多层parallax）
        clouds = (0..<cloudCount).map { i in
            ParallaxCloudLayer(
                offset: CGFloat(i) * 400,
                depth: CGFloat(i) / CGFloat(cloudCount),
                scale: 1.0 + CGFloat(i) * 0.3,
                opacity: 0.6 - CGFloat(i) * 0.15
            )
        }
        
 // 初始化玻璃水珠
        glassDroplets = (0..<dropletCount).map { _ in
            GlassDroplet(
                position: CGPoint(
                    x: CGFloat.random(in: 0...screenWidth),
                    y: CGFloat.random(in: 0...screenHeight)
                ),
                radius: CGFloat.random(in: 3...8),
                velocity: 0,
                opacity: Double.random(in: 0.5...0.9)
            )
        }
        
        ripples = []
        
        logger.info("🌧️ Apple风格雨天系统初始化")
        logger.info("  粒子: \(particleCount) | 云层: \(cloudCount) | 水珠: \(dropletCount)")
        logger.info("  目标: \(config.targetFrameRate) FPS")
    }
    
 // MARK: - 场景更新与绘制（TimelineView驱动，无状态更新）
    
    private func updateAndDrawScene(context: GraphicsContext, size: CGSize, time: Double) {
 // 1️⃣ 大气层渐变
        drawAtmosphere(context: context, size: size, time: time)
        
 // 2️⃣ 云层（由远及近，parallax效果）
        if config.shadowQuality > 0 {
            for (index, cloud) in clouds.enumerated() {
                drawCloudLayer(context: context, size: size, time: time, layer: cloud, index: index)
            }
        }
        
 // 3️⃣ 雨滴（按景深排序，先画远处）
        drawRainParticles(context: context, size: size, time: time)
        
 // 4️⃣ 玻璃水珠
        if config.postProcessingLevel > 0 {
            drawGlassDroplets(context: context, size: size, time: time)
        }
        
 // 5️⃣ 涟漪
        if config.postProcessingLevel > 0 {
            drawRipples(context: context, size: size, time: time)
        }
        
 // 6️⃣ 底部水面
        if config.postProcessingLevel > 1 {
            drawWaterSurface(context: context, size: size, time: time)
        }
    }
    
 // MARK: - 绘制方法
    
    private func drawAtmosphere(context: GraphicsContext, size: CGSize, time: Double) {
 // 动态大气（随时间缓慢变化）
        let intensity = 0.25 + sin(time * 0.1) * 0.05
        
        let gradient = Gradient(colors: [
            Color(red: 0.12, green: 0.15, blue: 0.22).opacity(intensity),
            Color(red: 0.18, green: 0.20, blue: 0.28).opacity(intensity * 0.7),
            Color.clear
        ])
        
        context.fill(
            Path(CGRect(origin: .zero, size: CGSize(width: size.width, height: 400))),
            with: .linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: 400)
            )
        )
    }
    
    private func drawCloudLayer(context: GraphicsContext, size: CGSize, time: Double, layer: ParallaxCloudLayer, index: Int) {
 // Parallax移动（不同速度）
        let speed = 5.0 * (1.0 - Double(layer.depth))
        let offset = (time * speed).truncatingRemainder(dividingBy: Double(size.width + 400))
        
 // 绘制多个云朵
        let cloudCount = 4
        for i in 0..<cloudCount {
            let x = CGFloat(offset) + CGFloat(i) * (size.width + 400) / CGFloat(cloudCount) - 200
            let y = 50 + CGFloat(index) * 40 + sin(time * 0.2 + Double(i)) * 15
            
            drawPerlinCloud(
                context: context,
                position: CGPoint(x: x, y: y),
                scale: layer.scale,
                opacity: layer.opacity,
                time: time,
                seed: i
            )
        }
    }
    
    private func drawPerlinCloud(context: GraphicsContext, position: CGPoint, scale: CGFloat, opacity: Double, time: Double, seed: Int) {
 // 使用多个椭圆模拟Perlin噪声云
        let blobs = 8
        
        for i in 0..<blobs {
            let angle = Double(i) * .pi * 2.0 / Double(blobs)
            let radius = 60.0 * scale + sin(time * 0.3 + Double(seed) + angle) * 20
            let offsetX = cos(angle) * radius
            let offsetY = sin(angle) * radius * 0.6
            
            let size = CGSize(
                width: 80 * scale + sin(time * 0.5 + Double(i)) * 20,
                height: 60 * scale + cos(time * 0.4 + Double(i)) * 15
            )
            
            let rect = CGRect(
                x: position.x + offsetX - size.width / 2,
                y: position.y + offsetY - size.height / 2,
                width: size.width,
                height: size.height
            )
            
            let gradient = Gradient(colors: [
                Color(white: 0.15, opacity: opacity * 0.8),
                Color(white: 0.20, opacity: opacity * 0.5),
                Color(white: 0.18, opacity: opacity * 0.2)
            ])
            
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) / 2
                )
            )
        }
    }
    
    private func drawRainParticles(context: GraphicsContext, size: CGSize, time: Double) {
 // 按景深排序（先画远处）
        let sorted = particles.sorted { $0.depth < $1.depth }
        
        for particle in sorted {
 // 计算当前位置（基于时间，无需状态更新）
            let progress = (time + particle.phase).truncatingRemainder(dividingBy: 3.0) / 3.0
            
            let currentX = particle.position.x + particle.velocity.x * CGFloat(progress) * 3.0
            let currentY = particle.position.y + particle.velocity.y * CGFloat(progress) * 3.0
            
 // 循环
            let wrappedY = currentY > size.height ? currentY - size.height - 100 : currentY
            let wrappedX = currentX < 0 ? currentX + size.width : (currentX > size.width ? currentX - size.width : currentX)
            
 // 运动模糊（渐变）
            var path = Path()
            let start = CGPoint(x: wrappedX, y: wrappedY)
            let end = CGPoint(
                x: wrappedX - particle.velocity.x * 0.05,
                y: wrappedY + particle.length
            )
            
            path.move(to: start)
            path.addLine(to: end)
            
 // 景深模糊（远处更透明）
            let depthOpacity = particle.opacity * (0.4 + particle.depth * 0.6)
            
            let gradient = Gradient(colors: [
                Color.white.opacity(depthOpacity),
                Color.white.opacity(depthOpacity * 0.5),
                Color.white.opacity(depthOpacity * 0.1)
            ])
            
            context.stroke(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: start,
                    endPoint: end
                ),
                style: StrokeStyle(lineWidth: particle.thickness, lineCap: .round)
            )
            
 // 高光点（近处粒子）
            if particle.depth > 0.7 && config.postProcessingLevel > 1 {
                let highlight = Path(ellipseIn: CGRect(
                    x: wrappedX - 1.5,
                    y: wrappedY - 1.5,
                    width: 3,
                    height: 3
                ))
                context.fill(highlight, with: .color(.white.opacity(depthOpacity * 0.8)))
            }
        }
    }
    
    private func drawGlassDroplets(context: GraphicsContext, size: CGSize, time: Double) {
        for (index, droplet) in glassDroplets.enumerated() {
 // 缓慢滑落（物理模拟）
            let slideProgress = (time * 0.5 + Double(index) * 0.1).truncatingRemainder(dividingBy: 10.0) / 10.0
            let currentY = droplet.position.y + CGFloat(slideProgress) * 300
            
            if currentY > size.height {
                continue
            }
            
            let center = CGPoint(x: droplet.position.x, y: currentY)
            
 // 水珠形状（椭圆，上小下大）
            let dropShape = Path { path in
                let width = droplet.radius * 2
                let height = droplet.radius * 2.5
                
                let rect = CGRect(
                    x: center.x - width / 2,
                    y: center.y - height / 2,
                    width: width,
                    height: height
                )
                
                path.addEllipse(in: rect)
            }
            
 // 主体渐变
            let gradient = Gradient(colors: [
                Color.white.opacity(droplet.opacity * 0.9),
                Color(red: 0.7, green: 0.8, blue: 1.0).opacity(droplet.opacity * 0.6),
                Color(red: 0.5, green: 0.6, blue: 0.8).opacity(droplet.opacity * 0.3)
            ])
            
            context.fill(
                dropShape,
                with: .radialGradient(
                    gradient,
                    center: center,
                    startRadius: 0,
                    endRadius: droplet.radius
                )
            )
            
 // 高光（左上角）
            let highlightOffset = droplet.radius * 0.4
            let highlightCenter = CGPoint(
                x: center.x - highlightOffset,
                y: center.y - highlightOffset
            )
            let highlightPath = Path(ellipseIn: CGRect(
                x: highlightCenter.x - droplet.radius * 0.3,
                y: highlightCenter.y - droplet.radius * 0.3,
                width: droplet.radius * 0.6,
                height: droplet.radius * 0.6
            ))
            context.fill(highlightPath, with: .color(.white.opacity(droplet.opacity * 0.95)))
            
 // 阴影（右下角）
            let shadowOffset = droplet.radius * 0.5
            let shadowCenter = CGPoint(
                x: center.x + shadowOffset,
                y: center.y + shadowOffset
            )
            let shadowPath = Path(ellipseIn: CGRect(
                x: shadowCenter.x - droplet.radius * 0.2,
                y: shadowCenter.y - droplet.radius * 0.2,
                width: droplet.radius * 0.4,
                height: droplet.radius * 0.4
            ))
            context.fill(shadowPath, with: .color(.black.opacity(droplet.opacity * 0.2)))
        }
    }
    
    private func drawRipples(context: GraphicsContext, size: CGSize, time: Double) {
 // 动态生成涟漪（基于时间）
        let rippleInterval = 0.5 // 每0.5秒一个涟漪
        let activeRipples = Int(time / rippleInterval)
        
        for i in max(0, activeRipples - 10)..<activeRipples {
            let rippleTime = time - Double(i) * rippleInterval
            if rippleTime > 2.0 { continue } // 2秒后消失
            
            let progress = rippleTime / 2.0
            let x = (CGFloat(i) * 123.456).truncatingRemainder(dividingBy: size.width)
            let y = size.height - 80
            
            let radius = CGFloat(progress) * 60
            let opacity = (1.0 - progress) * 0.6
            
            let ripplePath = Path(ellipseIn: CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            
            context.stroke(
                ripplePath,
                with: .color(.white.opacity(opacity)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
    }
    
    private func drawWaterSurface(context: GraphicsContext, size: CGSize, time: Double) {
        let waterHeight: CGFloat = 60
        let waterY = size.height - waterHeight
        
 // 动态波纹
        var path = Path()
        path.move(to: CGPoint(x: 0, y: waterY))
        
        for x in stride(from: 0, through: size.width, by: 10) {
            let wave1 = sin(time * 2.0 + Double(x) * 0.02) * 2
            let wave2 = sin(time * 1.5 + Double(x) * 0.015) * 3
            let y = waterY + wave1 + wave2
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        
        let gradient = Gradient(colors: [
            Color(red: 0.3, green: 0.4, blue: 0.6).opacity(0.15),
            Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.25),
            Color(red: 0.15, green: 0.25, blue: 0.45).opacity(0.3)
        ])
        
        context.fill(
            path,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: waterY),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }
}

// MARK: - 数据模型

struct RainParticle {
    let position: CGPoint
    let velocity: CGPoint
    let length: CGFloat
    let thickness: CGFloat
    let depth: CGFloat // 0=远，1=近
    let opacity: Double
    let phase: Double // 初始相位
}

struct ParallaxCloudLayer {
    let offset: CGFloat
    let depth: CGFloat
    let scale: CGFloat
    let opacity: Double
}

struct GlassDroplet {
    let position: CGPoint
    let radius: CGFloat
    let velocity: CGFloat
    let opacity: Double
}

struct SurfaceRipple {
    let position: CGPoint
    let startTime: Double
}

#endif
