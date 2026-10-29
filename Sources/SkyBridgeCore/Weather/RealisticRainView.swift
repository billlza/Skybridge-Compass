// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// RealisticRainView.swift
// SkyBridgeCore
//
// 真实雨天效果 - 优先质量，性能优化
// Created: 2025-10-19
//

import SwiftUI
import OSLog

/// 真实雨天视图 - 减少粒子，提升质量
@available(macOS 14.0, *)
public struct RealisticRainView: View {
    let config: PerformanceConfiguration
    
    @State private var raindrops: [RealisticRaindrop] = []
    @State private var glassDrops: [GlassDrop] = []
    @State private var ripples: [WaterRipple] = []
    @State private var frameCount: Int = 0
    @State private var time: Double = 0
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "RealisticRain")
    
    public init(config: PerformanceConfiguration) {
        self.config = config
    }
    
    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / Double(config.targetFrameRate))) { timeline in
            Canvas { context, size in
                let _ = frameCount
                time += 1.0 / Double(config.targetFrameRate)
                
 // 1️⃣ 大气渐变（雨天阴沉的天空）
                drawAtmosphere(in: context, size: size)
                
 // 2️⃣ 云层（体积感云朵）
                if config.shadowQuality > 0 {
                    drawRealisticClouds(in: context, size: size)
                }
                
 // 3️⃣ 雨滴（少而精，带模糊尾迹）
                drawRealisticRaindrops(in: context, size: size)
                
 // 4️⃣ 玻璃水珠（真实的透镜效果）
                if config.postProcessingLevel > 0 {
                    drawRealisticGlassDrops(in: context, size: size)
                }
                
 // 5️⃣ 涟漪（细腻的水面扩散）
                if config.postProcessingLevel > 0 {
                    drawRealisticRipples(in: context, size: size)
                }
                
 // 6️⃣ 底部水面反射
                if config.postProcessingLevel > 1 {
                    drawWaterSurface(in: context, size: size)
                }
            }
        }
        .onChange(of: frameCount, initial: false) { _, _ in }
        .onAppear {
            initializeParticles()
            startAnimation()
        }
    }
    
 // MARK: - 初始化
    
    private func initializeParticles() {
        let screenWidth = NSScreen.main?.frame.width ?? 1200
        let screenHeight = NSScreen.main?.frame.height ?? 800
        
 // 🎯 质量优先：大幅减少粒子数量
        let baseRainCount = Int(Double(config.maxParticles) * 0.15) // 只用15%的预算
        let baseGlassCount = Int(Double(config.maxParticles) * 0.05) // 5%
        
 // 生成雨滴（均匀分布）
        raindrops = (0..<baseRainCount).map { i in
            let phase = Double(i) / Double(baseRainCount)
            return RealisticRaindrop(
                x: CGFloat(phase) * screenWidth,
                y: CGFloat.random(in: -screenHeight...0),
                speed: CGFloat.random(in: 15...25),
                length: CGFloat.random(in: 30...50),
                thickness: CGFloat.random(in: 2...3),
                opacity: Double.random(in: 0.4...0.7)
            )
        }
        
 // 生成玻璃水珠（随机分布）
        glassDrops = (0..<baseGlassCount).map { _ in
            GlassDrop(
                x: CGFloat.random(in: 0...screenWidth),
                y: CGFloat.random(in: 0...screenHeight),
                radius: CGFloat.random(in: 2...6),
                opacity: Double.random(in: 0.6...0.9)
            )
        }
        
        ripples = []
        
        logger.info("🌧️ 真实雨天系统启动")
        logger.info("  雨滴: \(baseRainCount) | 玻璃水珠: \(baseGlassCount)")
        logger.info("  目标: \(config.targetFrameRate) FPS | 质量优先模式")
    }
    
    private func startAnimation() {
        let interval = 1.0 / Double(config.targetFrameRate)
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
 Task { @MainActor in
            frameCount += 1
    }
}

}

 // MARK: - 渲染方法
    
 /// 绘制大气层渐变
    private func drawAtmosphere(in context: GraphicsContext, size: CGSize) {
        let gradient = Gradient(colors: [
            Color(red: 0.15, green: 0.18, blue: 0.25).opacity(0.3),
            Color(red: 0.25, green: 0.28, blue: 0.35).opacity(0.15),
            Color.clear
        ])
        
        let rect = CGRect(origin: .zero, size: CGSize(width: size.width, height: 300))
        context.fill(
            Path(rect),
            with: .linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: 300)
            )
        )
    }
    
 /// 绘制真实云层（体积感）
    private func drawRealisticClouds(in context: GraphicsContext, size: CGSize) {
        let cloudCount = max(3, config.shadowQuality)
        
        for i in 0..<cloudCount {
            let xBase = size.width * CGFloat(i) / CGFloat(cloudCount)
            let x = xBase + sin(time * 0.1 + Double(i)) * 20
            let y = 40 + sin(time * 0.15 + Double(i) * 0.5) * 10
            
            drawVolumetricCloud(at: CGPoint(x: x, y: y), in: context, index: i)
        }
    }
    
 /// 绘制单个体积云
    private func drawVolumetricCloud(at position: CGPoint, in context: GraphicsContext, index: Int) {
 // 多层椭圆组成云朵，产生体积感
        let layers: [(width: CGFloat, height: CGFloat, offsetX: CGFloat, offsetY: CGFloat, opacity: Double)] = [
            (200, 80, 0, 0, 0.4),
            (160, 70, -60, 10, 0.35),
            (180, 75, 60, 5, 0.3),
            (140, 60, -30, -15, 0.25),
            (150, 65, 40, -10, 0.2)
        ]
        
        for layer in layers {
            let rect = CGRect(
                x: position.x + layer.offsetX - layer.width / 2,
                y: position.y + layer.offsetY - layer.height / 2,
                width: layer.width,
                height: layer.height
            )
            
            let gradient = Gradient(colors: [
                Color(white: 0.15, opacity: layer.opacity),
                Color(white: 0.25, opacity: layer.opacity * 0.6),
                Color(white: 0.2, opacity: layer.opacity * 0.3)
            ])
            
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: max(layer.width, layer.height) / 2
                )
            )
        }
    }
    
 /// 绘制真实雨滴（带模糊尾迹）
    private func drawRealisticRaindrops(in context: GraphicsContext, size: CGSize) {
        for i in raindrops.indices {
 // 更新位置
            raindrops[i].y += raindrops[i].speed
            raindrops[i].x += sin(time * 2 + Double(i)) * 0.5 // 轻微摇摆
            
 // 重置超出屏幕的雨滴
            if raindrops[i].y > size.height {
                raindrops[i].y = -50
                raindrops[i].x = CGFloat.random(in: 0...size.width)
                
 // 创建涟漪
                if config.postProcessingLevel > 0 && ripples.count < 20 {
                    ripples.append(WaterRipple(
                        x: raindrops[i].x,
                        y: size.height - 60,
                        radius: 0,
                        maxRadius: 40,
                        opacity: 0.6
                    ))
                }
            }
            
 // 绘制雨滴（渐变线条，模拟运动模糊）
            var path = Path()
            let startPoint = CGPoint(x: raindrops[i].x, y: raindrops[i].y)
            let endPoint = CGPoint(x: raindrops[i].x - 2, y: raindrops[i].y + raindrops[i].length)
            
            path.move(to: startPoint)
            path.addLine(to: endPoint)
            
 // 渐变效果（头部亮，尾部淡）
            let gradient = Gradient(colors: [
                Color.white.opacity(raindrops[i].opacity),
                Color.white.opacity(raindrops[i].opacity * 0.3)
            ])
            
            context.stroke(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: startPoint,
                    endPoint: endPoint
                ),
                lineWidth: raindrops[i].thickness
            )
            
 // 添加光晕（高质量模式）
            if config.postProcessingLevel > 1 {
                let glowCircle = Path(ellipseIn: CGRect(
                    x: raindrops[i].x - 1,
                    y: raindrops[i].y - 1,
                    width: 2,
                    height: 2
                ))
                context.fill(glowCircle, with: .color(.white.opacity(raindrops[i].opacity * 0.5)))
            }
        }
    }
    
 /// 绘制真实玻璃水珠（透镜效果）
    private func drawRealisticGlassDrops(in context: GraphicsContext, size: CGSize) {
        for i in glassDrops.indices {
 // 缓慢下滑
            if Double.random(in: 0...1) < 0.02 {
                glassDrops[i].y += 1
            }
            
 // 超出屏幕则重置
            if glassDrops[i].y > size.height {
                glassDrops[i].y = 0
                glassDrops[i].x = CGFloat.random(in: 0...size.width)
            }
            
            let drop = glassDrops[i]
            let center = CGPoint(x: drop.x, y: drop.y)
            
 // 水珠主体（高光 + 阴影）
            let mainCircle = Path(ellipseIn: CGRect(
                x: center.x - drop.radius,
                y: center.y - drop.radius,
                width: drop.radius * 2,
                height: drop.radius * 2
            ))
            
            let gradient = Gradient(colors: [
                Color.white.opacity(drop.opacity * 0.8),
                Color.blue.opacity(drop.opacity * 0.4),
                Color.clear
            ])
            
            context.fill(
                mainCircle,
                with: .radialGradient(
                    gradient,
                    center: center,
                    startRadius: 0,
                    endRadius: drop.radius
                )
            )
            
 // 高光点（模拟透镜反射）
            let highlightCircle = Path(ellipseIn: CGRect(
                x: center.x - drop.radius * 0.3,
                y: center.y - drop.radius * 0.3,
                width: drop.radius * 0.6,
                height: drop.radius * 0.6
            ))
            context.fill(highlightCircle, with: .color(.white.opacity(drop.opacity * 0.9)))
        }
    }
    
 /// 绘制真实涟漪
    private func drawRealisticRipples(in context: GraphicsContext, size: CGSize) {
        ripples = ripples.filter { ripple in
            ripple.radius < ripple.maxRadius
        }
        
        for i in ripples.indices {
            ripples[i].radius += 2
            ripples[i].opacity -= 0.03
            
            let rect = CGRect(
                x: ripples[i].x - ripples[i].radius,
                y: ripples[i].y - ripples[i].radius,
                width: ripples[i].radius * 2,
                height: ripples[i].radius * 2
            )
            
            let ripplePath = Path(ellipseIn: rect)
            context.stroke(
                ripplePath,
                with: .color(.white.opacity(max(0, ripples[i].opacity))),
                lineWidth: 1.5
            )
        }
    }
    
 /// 绘制底部水面
    private func drawWaterSurface(in context: GraphicsContext, size: CGSize) {
        let waterHeight: CGFloat = 50
        let waterY = size.height - waterHeight
        
 // 水面波纹效果
        var path = Path()
        path.move(to: CGPoint(x: 0, y: waterY))
        
        for x in stride(from: 0, through: size.width, by: 20) {
            let wave = sin(time + Double(x) * 0.02) * 3
            path.addLine(to: CGPoint(x: x, y: waterY + wave))
        }
        
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        
        let gradient = Gradient(colors: [
            Color.blue.opacity(0.15),
            Color.blue.opacity(0.25)
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

struct RealisticRaindrop {
    var x: CGFloat
    var y: CGFloat
    var speed: CGFloat
    var length: CGFloat
    var thickness: CGFloat
    var opacity: Double
}

struct GlassDrop {
    var x: CGFloat
    var y: CGFloat
    var radius: CGFloat
    var opacity: Double
}

struct WaterRipple {
    var x: CGFloat
    var y: CGFloat
    var radius: CGFloat
    var maxRadius: CGFloat
    var opacity: Double
}

#endif
