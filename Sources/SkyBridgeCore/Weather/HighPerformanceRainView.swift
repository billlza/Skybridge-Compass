//
// HighPerformanceRainView.swift
// SkyBridgeCore
//
// 高性能雨天视图 - 120 FPS支持
// Created: 2025-10-19
//

import SwiftUI
import OSLog

/// 高性能雨天视图（基于SwiftUI + TimelineView）
@available(macOS 14.0, *)
public struct HighPerformanceRainView: View {
    let config: PerformanceConfiguration
    
    @State private var raindrops: [RaindropData] = []
    @State private var waterDrops: [WaterDropData] = []
    @State private var cloudOffset: CGFloat = 0
    @State private var ripples: [RippleData] = []
    @State private var frameCount: Int = 0
    
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "HighPerfRain")
    
    public init(config: PerformanceConfiguration) {
        self.config = config
    }
    
    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / Double(config.targetFrameRate))) { timeline in
            Canvas { context, size in
 // 触发更新（确保Canvas在每一帧重新绘制）
                let _ = frameCount
                
 // 1️⃣ 云层
                if config.shadowQuality > 0 {
                    drawClouds(in: context, size: size)
                }
                
 // 2️⃣ 雨滴
                drawRaindrops(in: context, size: size)
                
 // 3️⃣ 玻璃水珠
                drawGlassWaterDrops(in: context, size: size)
                
 // 4️⃣ 涟漪
                if config.postProcessingLevel > 0 {
                    drawRipples(in: context, size: size)
                }
                
 // 5️⃣ 积水层
                if config.postProcessingLevel > 1 {
                    drawPuddle(in: context, size: size)
                }
            }
        }
        .onChange(of: frameCount, initial: false) { _, _ in
 // 触发重绘
        }
        .onAppear {
            initializeParticles()
 // 启动动画循环
            Timer.scheduledTimer(withTimeInterval: 1.0 / Double(config.targetFrameRate), repeats: true) { _ in
                Task { @MainActor in
                    frameCount += 1
                }
            }
        }
    }
    
 // MARK: - 初始化
    
    private func initializeParticles() {
        let total = config.maxParticles
        
 // 雨滴（60%）
        let raindropCount = Int(Float(total) * 0.6)
        raindrops = (0..<raindropCount).map { _ in RaindropData.random() }
        
 // 玻璃水珠（30%）
        let waterDropCount = Int(Float(total) * 0.3)
        waterDrops = (0..<waterDropCount).map { _ in WaterDropData.random() }
        
 // 涟漪（10%）
        let rippleCount = Int(Float(total) * 0.1)
        ripples = (0..<rippleCount).map { _ in RippleData.random() }
        
        logger.info("🌧️ ===============================")
        logger.info("🌧️ 雨天效果系统已启动！")
        logger.info("🌧️ 总粒子数: \(total)")
        logger.info("🌧️ - 雨滴: \(raindropCount)")
        logger.info("🌧️ - 玻璃水珠: \(waterDropCount)")
        logger.info("🌧️ - 涟漪: \(rippleCount)")
        logger.info("⚡ 目标帧率: \(config.targetFrameRate) FPS")
        logger.info("🎨 MetalFX质量: \(Int(config.metalFXQuality * 100))%")
        logger.info("🌧️ ===============================")
    }
    
 // MARK: - 绘制方法
    
    private func drawClouds(in context: GraphicsContext, size: CGSize) {
        let cloudCount = config.shadowQuality * 2
        for i in 0..<cloudCount {
            let x = (CGFloat(i) * size.width / CGFloat(cloudCount) + cloudOffset)
                .truncatingRemainder(dividingBy: size.width + 200) - 100
            let y = CGFloat(i) * 40 + 30
            
            drawSingleCloud(at: CGPoint(x: x, y: y), in: context)
        }
        
        cloudOffset += 0.2
    }
    
    private func drawSingleCloud(at position: CGPoint, in context: GraphicsContext) {
        let parts: [(CGSize, CGPoint)] = [
            (CGSize(width: 100, height: 50), CGPoint(x: 0, y: 0)),
            (CGSize(width: 80, height: 45), CGPoint(x: -40, y: 5)),
            (CGSize(width: 90, height: 48), CGPoint(x: 40, y: 3))
        ]
        
        for (partSize, offset) in parts {
            let rect = CGRect(
                x: position.x + offset.x - partSize.width / 2,
                y: position.y + offset.y - partSize.height / 2,
                width: partSize.width,
                height: partSize.height
            )
            
            let gradient = Gradient(colors: [
                Color(white: 0.2, opacity: 0.8),
                Color(white: 0.3, opacity: 0.6)
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
    
    private func drawRaindrops(in context: GraphicsContext, size: CGSize) {
        for i in raindrops.indices {
 // 更新位置
            raindrops[i].y += raindrops[i].speed
            raindrops[i].x += raindrops[i].windDrift
            
 // 重置超出屏幕的雨滴
            if raindrops[i].y > size.height {
                raindrops[i] = RaindropData.random()
                
 // 添加涟漪
                if config.postProcessingLevel > 0 {
                    ripples.append(RippleData(
                        x: raindrops[i].x,
                        y: size.height - 80,
                        progress: 0
                    ))
                }
            }
            
 // 绘制雨滴
            var path = Path()
            path.move(to: CGPoint(x: raindrops[i].x, y: raindrops[i].y))
            path.addLine(to: CGPoint(
                x: raindrops[i].x - 1,
                y: raindrops[i].y + raindrops[i].length
            ))
            
            context.stroke(
                path,
                with: .color(.white.opacity(raindrops[i].opacity)),
                lineWidth: raindrops[i].thickness
            )
        }
    }
    
    private func drawGlassWaterDrops(in context: GraphicsContext, size: CGSize) {
        for i in waterDrops.indices {
 // 缓慢下滑
            if waterDrops[i].isSliding {
                waterDrops[i].y += waterDrops[i].slideSpeed
                
                if waterDrops[i].y > size.height {
                    waterDrops[i] = WaterDropData.random()
                }
            }
            
 // 绘制椭圆形水珠
            let dropSize = waterDrops[i].size
            let dropRect = CGRect(
                x: waterDrops[i].x - dropSize / 2,
                y: waterDrops[i].y - dropSize * 1.5 / 2,
                width: dropSize,
                height: dropSize * 1.5
            )
            
 // 水珠主体
            let gradient = Gradient(colors: [
                Color.white.opacity(0.4),
                Color.white.opacity(0.2),
                Color.white.opacity(0.1)
            ])
            
            context.fill(
                Path(ellipseIn: dropRect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: dropRect.midX, y: dropRect.minY + dropRect.height * 0.3),
                    startRadius: 0,
                    endRadius: dropSize
                )
            )
            
 // 高光
            let highlightRect = CGRect(
                x: waterDrops[i].x - dropSize / 4,
                y: waterDrops[i].y - dropSize,
                width: dropSize / 2,
                height: dropSize / 2
            )
            
            context.fill(
                Path(ellipseIn: highlightRect),
                with: .color(.white.opacity(waterDrops[i].highlight))
            )
        }
    }
    
    private func drawRipples(in context: GraphicsContext, size: CGSize) {
 // 更新涟漪并移除完成的
        ripples = ripples.compactMap { ripple in
            var updated = ripple
            updated.progress += 0.03
            return updated.progress < 1.0 ? updated : nil
        }
        
        for ripple in ripples {
            let radius = ripple.maxRadius * ripple.progress
            let opacity = 1.0 - ripple.progress
            
            let ripplePath = Path(
                ellipseIn: CGRect(
                    x: ripple.x - radius,
                    y: ripple.y - radius / 2,
                    width: radius * 2,
                    height: radius
                )
            )
            
            context.stroke(
                ripplePath,
                with: .color(.white.opacity(opacity * 0.5)),
                lineWidth: 2
            )
        }
    }
    
    private func drawPuddle(in context: GraphicsContext, size: CGSize) {
        let puddleRect = CGRect(
            x: 0,
            y: size.height - 100,
            width: size.width,
            height: 100
        )
        
        let gradient = Gradient(colors: [
            Color(white: 0.2, opacity: 0.4),
            Color(white: 0.3, opacity: 0.6),
            Color(white: 0.25, opacity: 0.5)
        ])
        
        context.fill(
            Path(puddleRect),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: puddleRect.minY),
                endPoint: CGPoint(x: 0, y: puddleRect.maxY)
            )
        )
    }
}

// MARK: - 数据模型

struct RaindropData {
    var x: CGFloat
    var y: CGFloat
    var speed: CGFloat
    var windDrift: CGFloat
    var length: CGFloat
    var thickness: CGFloat
    var opacity: Double
    
    static func random() -> RaindropData {
        let screenWidth = NSScreen.main?.frame.width ?? 1200
        return RaindropData(
            x: CGFloat.random(in: 0...screenWidth),
            y: CGFloat.random(in: -100...0),
            speed: CGFloat.random(in: 25...35),
            windDrift: CGFloat.random(in: -1...1),
            length: CGFloat.random(in: 18...28),
            thickness: CGFloat.random(in: 1.5...2.5),
            opacity: Double.random(in: 0.5...0.9)
        )
    }
}

struct WaterDropData {
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var isSliding: Bool
    var slideSpeed: CGFloat
    var highlight: Double
    
    static func random() -> WaterDropData {
        let screenWidth = NSScreen.main?.frame.width ?? 1200
        let screenHeight = NSScreen.main?.frame.height ?? 900
        return WaterDropData(
            x: CGFloat.random(in: 0...screenWidth),
            y: CGFloat.random(in: 0...screenHeight),
            size: CGFloat.random(in: 8...18),
            isSliding: Bool.random(),
            slideSpeed: CGFloat.random(in: 0.3...0.8),
            highlight: Double.random(in: 0.6...1.0)
        )
    }
}

struct RippleData {
    var x: CGFloat
    var y: CGFloat
    var progress: Double
    let maxRadius: CGFloat = CGFloat.random(in: 30...60)
    
    static func random() -> RippleData {
        let screenWidth = NSScreen.main?.frame.width ?? 1200
        return RippleData(
            x: CGFloat.random(in: 0...screenWidth),
            y: CGFloat.random(in: 0...100),
            progress: 0
        )
    }
}

