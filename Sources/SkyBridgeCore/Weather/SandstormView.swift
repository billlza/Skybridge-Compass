// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// SandstormView.swift
// SkyBridgeCore
//
// 沙尘暴效果 - 参考UE5 Niagara粒子系统
// 包含：风场模拟、沙尘粒子、光照散射
// Created: 2025-10-19
//

import SwiftUI
import OSLog

/// 沙尘暴视图 - 真实风沙模拟
@available(macOS 14.0, *)
public struct SandstormView: View {
    let config: PerformanceConfiguration
    let intensity: Double
    
    @State private var particles: [SandParticle] = []
    @State private var dustClouds: [DustCloud] = []
    
 // 🌟 交互式驱散管理器
    @StateObject private var clearManager = InteractiveClearManager()
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "Sandstorm")
    
    public init(config: PerformanceConfiguration, intensity: Double = 0.7) {
        self.config = config
        self.intensity = intensity
    }
    
    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                
                if particles.isEmpty {
                    initializeParticles(size: size)
                }
                
 // 1️⃣ 背景沙尘云（大尺度）
                drawDustClouds(context: context, size: size, time: time)
                
 // 2️⃣ 沙尘粒子（三层景深）- 带驱散效果
                drawSandParticles(context: context, size: size, time: time)
                
 // 3️⃣ 光照散射效果
                if config.postProcessingLevel > 1 {
                    drawLightScattering(context: context, size: size, time: time)
                }
            }
        }
        .opacity(clearManager.globalOpacity)
        .background {
 // 🖱️ 鼠标追踪视图（用于交互式驱散）
            InteractiveMouseTrackingView { location in
                clearManager.handleMouseMove(location)
            }
        }
        .onAppear {
            logger.info("🏜️ 沙尘暴系统初始化 (强度: \(Int(intensity * 100))%)")
            clearManager.start()
        }
        .onDisappear {
            clearManager.stop()
        }
    }
    
 // MARK: - 初始化
    
    private func initializeParticles(size: CGSize) {
        let baseCount = Int(Double(config.maxParticles) * 0.2) // 20%预算
        let particleCount = Int(Double(baseCount) * intensity)
        
 // 三层景深的沙尘粒子
        particles = (0..<particleCount).map { i in
            let depth = CGFloat.random(in: 0...1) // 0=远，1=近
            
            return SandParticle(
                position: CGPoint(
                    x: CGFloat.random(in: -200...size.width),
                    y: CGFloat.random(in: 0...size.height)
                ),
                velocity: CGPoint(
                    x: 50 + depth * 100, // 近处更快
                    y: CGFloat.random(in: -5...5) // 轻微垂直运动
                ),
                size: 2 + depth * 6, // 近处更大
                depth: depth,
                opacity: 0.3 + depth * 0.5,
                rotation: Double.random(in: 0...(.pi * 2)),
                rotationSpeed: Double.random(in: -1...1),
                phase: Double(i) / Double(particleCount),
                turbulence: CGPoint(
                    x: CGFloat.random(in: 20...50),
                    y: CGFloat.random(in: 10...30)
                )
            )
        }
        
 // 大尺度沙尘云
        let cloudCount = max(2, config.shadowQuality)
        dustClouds = (0..<cloudCount).map { i in
            DustCloud(
                position: CGPoint(
                    x: CGFloat(i) * size.width / CGFloat(cloudCount),
                    y: size.height * 0.3
                ),
                size: CGSize(
                    width: size.width * 0.8,
                    height: size.height * 0.6
                ),
                opacity: 0.15 + Double(i) * 0.05,
                scrollSpeed: 3.0 + Double(i) * 2.0
            )
        }
    }
    
 // MARK: - 绘制方法
    
 /// 绘制大尺度沙尘云
    private func drawDustClouds(context: GraphicsContext, size: CGSize, time: Double) {
        for (_, cloud) in dustClouds.enumerated() {
            let offset = (time * cloud.scrollSpeed).truncatingRemainder(dividingBy: Double(size.width + 400))
            let x = CGFloat(offset) - 200
            
 // 使用渐变模拟沙尘云
            let gradient = Gradient(colors: [
                Color(red: 0.76, green: 0.65, blue: 0.45).opacity(cloud.opacity * 0.8),
                Color(red: 0.82, green: 0.72, blue: 0.52).opacity(cloud.opacity * 0.5),
                Color(red: 0.88, green: 0.78, blue: 0.58).opacity(cloud.opacity * 0.2),
                Color.clear
            ])
            
            let rect = CGRect(
                x: x,
                y: cloud.position.y,
                width: cloud.size.width,
                height: cloud.size.height
            )
            
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: max(cloud.size.width, cloud.size.height) / 2
                )
            )
        }
    }
    
 /// 绘制沙尘粒子（风场模拟）
    private func drawSandParticles(context: GraphicsContext, size: CGSize, time: Double) {
 // 按景深排序（先画远处）
        let sorted = particles.sorted { $0.depth < $1.depth }
        
 // 🌟 获取清除区域快照用于粒子驱散
        let zones = clearManager.clearZones
        
        for particle in sorted {
 // 风场模拟（使用正弦波模拟湍流）
            let turbulenceX = sin(time * 2.0 + particle.phase * 10.0) * particle.turbulence.x
            let turbulenceY = sin(time * 1.5 + particle.phase * 8.0) * particle.turbulence.y
            
 // 计算当前位置
            let progress = (time * 0.3 + particle.phase).truncatingRemainder(dividingBy: 3.0) / 3.0
            let currentX = particle.position.x + particle.velocity.x * CGFloat(progress) * 3.0 + turbulenceX
            let currentY = particle.position.y + particle.velocity.y * CGFloat(progress) * 3.0 + turbulenceY
            
 // 循环
            let wrappedX = currentX > size.width + 200 ? currentX - size.width - 400 : currentX
            let wrappedY = currentY < 0 ? currentY + size.height : (currentY > size.height ? currentY - size.height : currentY)
            
 // 🌟 计算清除区域内的驱散强度
            var disperseFactor: Double = 1.0
            for zone in zones {
                let dx = wrappedX - zone.center.x
                let dy = wrappedY - zone.center.y
                let distanceSquared = dx * dx + dy * dy
                let radiusSquared = zone.radius * zone.radius
                
                if distanceSquared < radiusSquared {
                    let distance = sqrt(distanceSquared)
                    let normalizedDist = distance / zone.radius
                    let falloff = (1.0 - normalizedDist * normalizedDist)
                    let strength = Double(zone.strength) * falloff
                    disperseFactor = min(disperseFactor, 1.0 - strength * 0.9)
                }
            }
            
 // 如果完全被驱散，跳过绘制
            guard disperseFactor > 0.05 else { continue }
            
 // 旋转
            let rotation = particle.rotation + time * particle.rotationSpeed
            
 // 沙尘颗粒形状（不规则）- 应用驱散因子
            drawSandGrain(
                context: context,
                center: CGPoint(x: wrappedX, y: wrappedY),
                size: particle.size,
                rotation: rotation,
                opacity: particle.opacity * disperseFactor,
                depth: particle.depth
            )
        }
    }
    
 /// 绘制单个沙尘颗粒（不规则形状）
    private func drawSandGrain(context: GraphicsContext, center: CGPoint, size: CGFloat, rotation: Double, opacity: Double, depth: CGFloat) {
        var path = Path()
        
 // 不规则多边形模拟沙粒
        let sides = 5
        for i in 0..<sides {
            let angle = rotation + Double(i) * .pi * 2.0 / Double(sides)
            let radiusVar = size * (0.7 + CGFloat.random(in: 0...0.3))
            let x = center.x + cos(angle) * radiusVar
            let y = center.y + sin(angle) * radiusVar
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        
 // 沙尘颜色（黄褐色）
        let sandColor = Color(
            red: 0.76 + depth * 0.1,
            green: 0.65 + depth * 0.08,
            blue: 0.45 + depth * 0.05
        ).opacity(opacity)
        
        context.fill(path, with: .color(sandColor))
        
 // 高光（近处粒子）
        if depth > 0.7 && config.postProcessingLevel > 0 {
            let highlightCircle = Path(ellipseIn: CGRect(
                x: center.x - size * 0.3,
                y: center.y - size * 0.3,
                width: size * 0.6,
                height: size * 0.6
            ))
            context.fill(highlightCircle, with: .color(.white.opacity(opacity * 0.3)))
        }
    }
    
 /// 光照散射效果（模拟沙尘中的光线）
    private func drawLightScattering(context: GraphicsContext, size: CGSize, time: Double) {
 // 光束从右上角射入
        let lightSource = CGPoint(x: size.width - 100, y: 80)
        let rayCount = 5
        
        for i in 0..<rayCount {
            let angle = -.pi / 6 + Double(i) * .pi / 20
            let length = size.width * 0.4
            
            let endX = lightSource.x + cos(angle) * length
            let endY = lightSource.y + sin(angle) * length
            
 // 光束路径
            var path = Path()
            path.move(to: lightSource)
            path.addLine(to: CGPoint(x: endX, y: endY))
            
 // 光线强度（随时间闪烁）
            let flicker = 0.5 + sin(time * 2.0 + Double(i)) * 0.2
            let opacity = 0.08 * flicker * intensity
            
            context.stroke(
                path,
                with: .color(Color.yellow.opacity(opacity)),
                lineWidth: 30
            )
        }
    }
}

// MARK: - 数据模型

struct SandParticle {
    let position: CGPoint
    let velocity: CGPoint
    let size: CGFloat
    let depth: CGFloat
    let opacity: Double
    let rotation: Double
    let rotationSpeed: Double
    let phase: Double
    let turbulence: CGPoint // 湍流强度
}

struct DustCloud {
    let position: CGPoint
    let size: CGSize
    let opacity: Double
    let scrollSpeed: Double
}

#endif
