//
// EnhancedRainView.swift
// SkyBridgeCore
//
// 增强雨天效果 - 参考UE5 + Apple Weather
// 新增：雨滴折射、水面反射、动态光照、闪电
// Created: 2025-10-19
//

import SwiftUI
import OSLog

/// 增强雨天视图 - 电影级真实感
@available(macOS 14.0, *)
public struct EnhancedRainView: View {
    let config: PerformanceConfiguration
    
    @State private var particles: [PhotorealisticRaindrop] = []
    @State private var splashes: [RainSplash] = []
    @State private var lightningFlash: Double = 0
    @State private var nextLightning: Double = 0
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "EnhancedRain")
    
    public init(config: PerformanceConfiguration) {
        self.config = config
    }
    
    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                
                if particles.isEmpty {
                    initializeParticles(size: size)
                }
                
 // 1️⃣ 大气层（阴沉感）
                drawAtmosphere(context: context, size: size, time: time)
                
 // 2️⃣ 乌云（体积感 + Perlin噪声）
                if config.shadowQuality > 0 {
                    drawVolumetricClouds(context: context, size: size, time: time)
                }
                
 // 3️⃣ 闪电效果（随机）
                if config.postProcessingLevel > 1 {
                    checkAndDrawLightning(context: context, size: size, time: time)
                }
                
 // 4️⃣ 雨滴（三层景深 + 运动模糊）
                drawEnhancedRaindrops(context: context, size: size, time: time)
                
 // 5️⃣ 溅起的水花
                if config.postProcessingLevel > 0 {
                    drawSplashes(context: context, size: size, time: time)
                }
                
 // 6️⃣ 积水反射
                if config.postProcessingLevel > 1 {
                    drawWaterReflection(context: context, size: size, time: time)
                }
            }
        }
        .onAppear {
            logger.info("🌧️ 增强雨天系统初始化 (目标: \(config.targetFrameRate) FPS)")
            scheduleNextLightning()
        }
    }
    
 // MARK: - 初始化
    
    private func initializeParticles(size: CGSize) {
        let particleCount = Int(Double(config.maxParticles) * 0.25) // 25%预算，但质量更高
        
        particles = (0..<particleCount).map { i in
            let depth = CGFloat.random(in: 0...1)
            
            return PhotorealisticRaindrop(
                position: CGPoint(
                    x: CGFloat.random(in: -100...size.width),
                    y: CGFloat.random(in: -size.height...0)
                ),
                velocity: CGPoint(
                    x: -5 - depth * 10, // 斜向下落
                    y: 400 + depth * 600 // 近处更快
                ),
                length: 25 + depth * 60, // 近处更长
                thickness: 1.5 + depth * 2.5,
                depth: depth,
                opacity: 0.4 + depth * 0.5,
                phase: Double(i) / Double(particleCount),
                brightness: 0.8 + CGFloat.random(in: 0...0.2) // 亮度变化
            )
        }
    }
    
    private func scheduleNextLightning() {
 // 随机10-30秒后闪电
        nextLightning = Date().timeIntervalSinceReferenceDate + Double.random(in: 10...30)
    }
    
 // MARK: - 绘制方法
    
    private func drawAtmosphere(context: GraphicsContext, size: CGSize, time: Double) {
 // 动态阴沉度
        let darkness = 0.3 + sin(time * 0.05) * 0.05
        
        let gradient = Gradient(colors: [
            Color(red: 0.10, green: 0.12, blue: 0.18).opacity(darkness),
            Color(red: 0.15, green: 0.17, blue: 0.23).opacity(darkness * 0.7),
            Color.clear
        ])
        
        context.fill(
            Path(CGRect(origin: .zero, size: CGSize(width: size.width, height: 500))),
            with: .linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: 500)
            )
        )
    }
    
    private func drawVolumetricClouds(context: GraphicsContext, size: CGSize, time: Double) {
        let layerCount = config.shadowQuality + 1
        
        for layer in 0..<layerCount {
            let depth = CGFloat(layer) / CGFloat(layerCount)
            let speed = 2.0 * (1.0 - Double(depth))
            let offset = (time * speed).truncatingRemainder(dividingBy: Double(size.width + 600))
            
            let cloudCount = 4
            for i in 0..<cloudCount {
                let x = CGFloat(offset) + CGFloat(i) * (size.width + 600) / CGFloat(cloudCount) - 300
                let y = 40 + CGFloat(layer) * 45 + sin(time * 0.2 + Double(i)) * 12
                
                drawPerlinCloud(
                    context: context,
                    position: CGPoint(x: x, y: y),
                    time: time,
                    layer: layer,
                    seed: i
                )
            }
        }
    }
    
    private func drawPerlinCloud(context: GraphicsContext, position: CGPoint, time: Double, layer: Int, seed: Int) {
        let blobCount = 12
        let baseOpacity = 0.5 - Double(layer) * 0.1
        
        for i in 0..<blobCount {
            let angle = Double(i) * .pi * 2.0 / Double(blobCount)
            let noiseVal = sin(time * 0.15 + Double(seed) + angle * 2.0) * 0.5 + 0.5
            let radius = (80.0 + noiseVal * 40.0)
            
            let offsetX = cos(angle) * radius
            let offsetY = sin(angle) * radius * 0.65
            
            let width = 90 + sin(time * 0.3 + Double(i)) * 25
            let height = 70 + cos(time * 0.25 + Double(i)) * 20
            
            let rect = CGRect(
                x: position.x + offsetX - width / 2,
                y: position.y + offsetY - height / 2,
                width: width,
                height: height
            )
            
            let gradient = Gradient(colors: [
                Color(white: 0.12, opacity: baseOpacity),
                Color(white: 0.18, opacity: baseOpacity * 0.7),
                Color(white: 0.15, opacity: baseOpacity * 0.3)
            ])
            
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: max(width, height) / 2
                )
            )
        }
    }
    
    private func checkAndDrawLightning(context: GraphicsContext, size: CGSize, time: Double) {
 // 检查是否该闪电
        if time >= nextLightning {
            lightningFlash = 1.0
            scheduleNextLightning()
        }
        
 // 闪电衰减
        if lightningFlash > 0 {
            lightningFlash -= 0.1
            
 // 绘制闪电
            if lightningFlash > 0.5 {
 // 主闪电
                let startX = CGFloat.random(in: size.width * 0.3...size.width * 0.7)
                drawLightningBolt(
                    context: context,
                    start: CGPoint(x: startX, y: 0),
                    end: CGPoint(x: startX + CGFloat.random(in: -100...100), y: size.height * 0.4),
                    intensity: lightningFlash
                )
            }
            
 // 全屏闪光
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.white.opacity(lightningFlash * 0.2))
            )
        }
    }
    
    private func drawLightningBolt(context: GraphicsContext, start: CGPoint, end: CGPoint, intensity: Double) {
        var path = Path()
        path.move(to: start)
        
 // 锯齿状闪电
        let segments = 8
        for i in 1...segments {
            let progress = CGFloat(i) / CGFloat(segments)
            let x = start.x + (end.x - start.x) * progress + CGFloat.random(in: -30...30)
            let y = start.y + (end.y - start.y) * progress
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
 // 主线
        context.stroke(
            path,
            with: .color(.white.opacity(intensity)),
            lineWidth: 4
        )
        
 // 光晕
        context.stroke(
            path,
            with: .color(Color.cyan.opacity(intensity * 0.5)),
            lineWidth: 12
        )
    }
    
    private func drawEnhancedRaindrops(context: GraphicsContext, size: CGSize, time: Double) {
 // 按景深排序
        let sorted = particles.sorted { $0.depth < $1.depth }
        
        for particle in sorted {
            let progress = (time * 0.4 + particle.phase).truncatingRemainder(dividingBy: 2.5) / 2.5
            
            let currentX = particle.position.x + particle.velocity.x * CGFloat(progress) * 2.5
            let currentY = particle.position.y + particle.velocity.y * CGFloat(progress) * 2.5
            
 // 循环
            if currentY > size.height {
 // 生成溅起
                if splashes.count < 50 && config.postProcessingLevel > 0 {
                    splashes.append(RainSplash(
                        position: CGPoint(x: currentX, y: size.height - 60),
                        startTime: time,
                        maxRadius: 15 + particle.depth * 25
                    ))
                }
                continue
            }
            
            let wrappedX = currentX < 0 ? currentX + size.width : (currentX > size.width ? currentX - size.width : currentX)
            
 // 雨滴形状（头部圆润，尾部拉长）
            let start = CGPoint(x: wrappedX, y: currentY)
            let end = CGPoint(
                x: wrappedX + particle.velocity.x * 0.1,
                y: currentY + particle.length
            )
            
 // 运动模糊渐变
            let gradient = Gradient(colors: [
                Color.white.opacity(particle.opacity * Double(particle.brightness)),
                Color.white.opacity(particle.opacity * 0.7),
                Color.white.opacity(particle.opacity * 0.3),
                Color.white.opacity(0)
            ])
            
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            
            context.stroke(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: start,
                    endPoint: end
                ),
                style: StrokeStyle(lineWidth: particle.thickness, lineCap: .round)
            )
            
 // 近处雨滴高光
            if particle.depth > 0.75 && config.postProcessingLevel > 1 {
                let highlight = Path(ellipseIn: CGRect(
                    x: wrappedX - 2,
                    y: currentY - 2,
                    width: 4,
                    height: 4
                ))
                context.fill(highlight, with: .color(.white.opacity(particle.opacity)))
            }
        }
    }
    
    private func drawSplashes(context: GraphicsContext, size: CGSize, time: Double) {
        splashes = splashes.filter { splash in
            let age = time - splash.startTime
            return age < 0.4
        }
        
        for splash in splashes {
            let age = time - splash.startTime
            let progress = age / 0.4
            
            let radius = CGFloat(progress) * splash.maxRadius
            let opacity = (1.0 - progress) * 0.7
            
 // 涟漪
            let rippleRect = CGRect(
                x: splash.position.x - radius,
                y: splash.position.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            
            context.stroke(
                Path(ellipseIn: rippleRect),
                with: .color(.white.opacity(opacity)),
                lineWidth: 1.5
            )
            
 // 飞溅水珠
            if age < 0.2 {
                let dropCount = 6
                for i in 0..<dropCount {
                    let angle = Double(i) * .pi * 2.0 / Double(dropCount)
                    let dist = CGFloat(age / 0.2) * splash.maxRadius * 0.6
                    let x = splash.position.x + cos(angle) * dist
                    let y = splash.position.y + sin(angle) * dist - CGFloat(age) * 50 // 向上飞
                    
                    let dropSize = (1.0 - age / 0.2) * 3.0
                    let dropRect = CGRect(
                        x: x - dropSize / 2,
                        y: y - dropSize / 2,
                        width: dropSize,
                        height: dropSize
                    )
                    
                    context.fill(
                        Path(ellipseIn: dropRect),
                        with: .color(.white.opacity(opacity))
                    )
                }
            }
        }
    }
    
    private func drawWaterReflection(context: GraphicsContext, size: CGSize, time: Double) {
        let waterHeight: CGFloat = 80
        let waterY = size.height - waterHeight
        
 // 波纹水面
        var path = Path()
        path.move(to: CGPoint(x: 0, y: waterY))
        
        for x in stride(from: 0, through: size.width, by: 8) {
            let wave1 = sin(time * 3.0 + Double(x) * 0.03) * 2.5
            let wave2 = sin(time * 2.2 + Double(x) * 0.02) * 3.5
            let y = waterY + wave1 + wave2
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        
 // 水面渐变（深蓝色）
        let gradient = Gradient(colors: [
            Color(red: 0.2, green: 0.25, blue: 0.35).opacity(0.2),
            Color(red: 0.15, green: 0.2, blue: 0.3).opacity(0.3),
            Color(red: 0.1, green: 0.15, blue: 0.25).opacity(0.4)
        ])
        
        context.fill(
            path,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: waterY),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        
 // 水面高光（模拟反射）
        for x in stride(from: 0, through: size.width, by: 40) {
            let shimmer = sin(time * 4.0 + Double(x) * 0.1) * 0.5 + 0.5
            let highlightY = waterY + 20 + sin(time * 2.0 + Double(x) * 0.05) * 5
            
            let highlightRect = CGRect(
                x: x - 15,
                y: highlightY - 2,
                width: 30,
                height: 4
            )
            
            context.fill(
                Path(ellipseIn: highlightRect),
                with: .color(.white.opacity(0.15 * shimmer))
            )
        }
    }
}

// MARK: - 数据模型

struct PhotorealisticRaindrop {
    let position: CGPoint
    let velocity: CGPoint
    let length: CGFloat
    let thickness: CGFloat
    let depth: CGFloat
    let opacity: Double
    let phase: Double
    let brightness: CGFloat
}

struct RainSplash {
    let position: CGPoint
    let startTime: Double
    let maxRadius: CGFloat
}

