//
// CinematicSnowEffectView.swift
// SkyBridgeCompassApp
//
// 电影级真实感雪天效果 + 交互式粒子驱散
// 重构版本：增强雪花渲染、景深模糊、光晕效果
// Created: 2025-10-19
//

import SwiftUI

/// 物理真实雪花粒子（增强版）
struct PhysicsSnowflake: Identifiable {
    let id = UUID()
    var x: CGFloat           // 归一化坐标 (0-1)
    var y: CGFloat
    var velocityX: CGFloat   // 水平速度
    var velocityY: CGFloat   // 垂直速度
    var acceleration: CGFloat = 98
    let mass: CGFloat
    var rotation: CGFloat
    let rotationSpeed: CGFloat
    let size: CGFloat
    let shape: Int           // 0=圆形, 1=六角星, 2=精细晶体, 3=软焦点
    let opacity: Double
    let layer: Int           // 景深层次 (0=远景模糊, 1=中景, 2=近景清晰)
    var swayPhase: CGFloat
    let blur: CGFloat        // 景深模糊程度
    let glowIntensity: CGFloat // 光晕强度
}

/// 底部积雪堆
struct SnowPile: Identifiable {
    let id = UUID()
    let x: CGFloat
    let width: CGFloat
    let height: CGFloat
    let opacity: Double
}

@available(macOS 14.0, *)
public struct CinematicSnowEffectView: View {
    private static let animationEpoch = Date()

 // 物理粒子状态
    @State private var snowflakes: [PhysicsSnowflake] = []
    @State private var snowPiles: [SnowPile] = []
    
 // 天气状态
    @State private var isRemoteDesktopActive: Bool = false
    
 // 交互式驱散管理器（由统一入口 WeatherEffectView 注入；避免重复创建/重复监听）
    @ObservedObject private var clearManager: InteractiveClearManager
    
    public init(clearManager: InteractiveClearManager) {
        self.clearManager = clearManager
    }
    
    public var body: some View {
        GeometryReader { _ in
            ZStack {
 // 主雪天效果层
                TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
                    let time = timeline.date.timeIntervalSince(Self.animationEpoch)
                    let remoteActive = isRemoteDesktopActive
                    let clearZones = clearManager.clearZones
                    
                    ZStack {
 // 1️⃣ 电影级天空背景 - 应用驱散效果，露出底层主题壁纸
                        CinematicSnowSkyGradient(time: time)
                            .opacity(clearManager.globalOpacity)
                        
 // 2️⃣ 远景大气雾
                        DistantAtmosphericFog(time: time, intensity: 0.4)
                            .opacity(clearManager.globalOpacity)
                        
 // 3️⃣ 雪花渲染层
                        Canvas { context, size in
                            guard !remoteActive else { return }

 // 先绘制远景模糊雪花（Bokeh效果）
                            drawBackgroundSnowflakes(context: &context, size: size, time: time, clearZones: clearZones)
                            
 // 再绘制中景雪花
                            drawMidgroundSnowflakes(context: &context, size: size, time: time, clearZones: clearZones)
                            
 // 最后绘制近景清晰雪花
                            drawForegroundSnowflakes(context: &context, size: size, time: time, clearZones: clearZones)
                        }
                        .opacity(clearManager.globalOpacity)
                        
 // 4️⃣ 底部积雪
                        Canvas { context, size in
                            drawEnhancedSnowPiles(context: &context, size: size, time: time)
                        }
                        .opacity(clearManager.globalOpacity)
                        
 // 5️⃣ 电影级色彩分级
                        SnowColorGrading(time: time)
                            .opacity(0.3 * clearManager.globalOpacity)
                            .blendMode(.overlay)
                        
 // 6️⃣ 暗角效果
                        SnowVignette()
                            .opacity(0.4 * clearManager.globalOpacity)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            initializeEnhancedParticles()
            clearManager.start()
        }
        .onReceive(RemoteDesktopManager.shared.metrics) { snapshot in
            isRemoteDesktopActive = snapshot.activeSessions > 0
        }
 // 🔧 系统唤醒后恢复雪花效果
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in
 // 如果雪花数组为空，重新初始化
            if snowflakes.isEmpty {
                initializeEnhancedParticles()
            }
        }
 // 🔧 屏幕解锁后恢复雪花效果
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
            if snowflakes.isEmpty {
                initializeEnhancedParticles()
            }
        }
 // 🔧 应用激活时检查并恢复效果
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
 // 应用从后台切换到前台时，检查并恢复效果
            if snowflakes.isEmpty {
                initializeEnhancedParticles()
            }
        }
    }
    
 // MARK: - 增强版粒子初始化
    
    private func initializeEnhancedParticles() {
        guard snowflakes.isEmpty, snowPiles.isEmpty else { return }

 // 远景雪花（模糊、小、密集）- Bokeh 效果
        for _ in 0..<80 {
            snowflakes.append(PhysicsSnowflake(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: -0.2...1),
                velocityX: CGFloat.random(in: -10...10),
                velocityY: CGFloat.random(in: 20...50),
                mass: 0.2 * CGFloat.random(in: 0.8...1.2),
                rotation: CGFloat.random(in: 0...360),
                rotationSpeed: CGFloat.random(in: -30...30),
                size: CGFloat.random(in: 2...5),
                shape: 3, // 软焦点
                opacity: Double.random(in: 0.2...0.4),
                layer: 0,
                swayPhase: CGFloat.random(in: 0...(.pi * 2)),
                blur: CGFloat.random(in: 3...6),
                glowIntensity: CGFloat.random(in: 0.3...0.6)
            ))
        }
        
 // 中景雪花（半模糊、中等）
        for _ in 0..<60 {
            snowflakes.append(PhysicsSnowflake(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: -0.2...1),
                velocityX: CGFloat.random(in: -15...15),
                velocityY: CGFloat.random(in: 30...70),
                mass: 0.35 * CGFloat.random(in: 0.8...1.2),
                rotation: CGFloat.random(in: 0...360),
                rotationSpeed: CGFloat.random(in: -50...50),
                size: CGFloat.random(in: 5...10),
                shape: Int.random(in: 0...2),
                opacity: Double.random(in: 0.5...0.7),
                layer: 1,
                swayPhase: CGFloat.random(in: 0...(.pi * 2)),
                blur: CGFloat.random(in: 1...2),
                glowIntensity: CGFloat.random(in: 0.2...0.4)
            ))
        }
        
 // 近景雪花（清晰、大、稀疏）
        for _ in 0..<35 {
            snowflakes.append(PhysicsSnowflake(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: -0.2...1),
                velocityX: CGFloat.random(in: -25...25),
                velocityY: CGFloat.random(in: 40...90),
                mass: 0.5 * CGFloat.random(in: 0.8...1.2),
                rotation: CGFloat.random(in: 0...360),
                rotationSpeed: CGFloat.random(in: -70...70),
                size: CGFloat.random(in: 10...18),
                shape: Int.random(in: 1...2), // 只用精细形状
                opacity: Double.random(in: 0.75...0.95),
                layer: 2,
                swayPhase: CGFloat.random(in: 0...(.pi * 2)),
                blur: 0,
                glowIntensity: CGFloat.random(in: 0.4...0.7)
            ))
        }
        
 // 积雪堆
        for _ in 0..<20 {
            snowPiles.append(SnowPile(
                x: CGFloat.random(in: 0...1),
                width: CGFloat.random(in: 50...120),
                height: CGFloat.random(in: 10...25),
                opacity: Double.random(in: 0.6...0.9)
            ))
        }
    }
    
 // MARK: - 分层渲染方法

    private func positiveModulo(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let result = value.truncatingRemainder(dividingBy: modulus)
        return result >= 0 ? result : result + modulus
    }

    private func renderedSnowflake(
        _ flake: PhysicsSnowflake,
        size: CGSize,
        time: TimeInterval,
        clearZones: [DynamicClearZone]
    ) -> (x: CGFloat, y: CGFloat, rotation: CGFloat) {
        let t = CGFloat(time)
        let layerFactor = CGFloat(1.0 - Double(flake.layer) * 0.2)
        let wind = sin(t * 0.30) * 100 + cos(t * 0.15) * 30
        let windNoise = (sin(t * 0.33) + sin(t * 0.19 + 0.8)) * 0.5
        let windScale = min(1.0, max(0.0, abs(wind) / 150.0))
        let swayMod = 0.8 + 0.4 * max(0.0, min(1.0, (windNoise * 0.5 + 0.5) * windScale))
        let drift = (flake.velocityX + wind * layerFactor * 0.08) * t / 800.0
        let sway = sin(t * 2 + flake.swayPhase) * 0.018 * swayMod * layerFactor
        let normalizedX = positiveModulo(flake.x + drift + sway + 0.1, 1.2) - 0.1
        let normalizedY = positiveModulo(flake.y + flake.velocityY * layerFactor * t / 800.0 + 0.15, 1.3) - 0.15

        var x = normalizedX * size.width
        var y = normalizedY * size.height

        for zone in clearZones {
            let dx = x - zone.center.x
            let dy = y - zone.center.y
            let distanceSquared = dx * dx + dy * dy
            let radiusSquared = zone.radius * zone.radius
            guard distanceSquared < radiusSquared, distanceSquared > 0.01 else { continue }

            let distance = sqrt(distanceSquared)
            let normalizedDistance = distance / zone.radius
            let falloff = 1.0 - normalizedDistance * normalizedDistance
            let displacement = zone.radius * CGFloat(zone.strength) * falloff * 0.18
            x += dx / distance * displacement
            y += dy / distance * displacement
        }

        let rotation = flake.rotation + flake.rotationSpeed * t
        return (x, y, rotation)
    }
    
 /// 远景雪花 - Bokeh 效果
    private func drawBackgroundSnowflakes(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        clearZones: [DynamicClearZone]
    ) {
        for flake in snowflakes where flake.layer == 0 {
            let rendered = renderedSnowflake(flake, size: size, time: time, clearZones: clearZones)
            let x = rendered.x
            let y = rendered.y
            
 // 大光圈 Bokeh 效果
            let bokehSize = flake.size * 3
            let gradient = Gradient(colors: [
                Color.white.opacity(flake.opacity * flake.glowIntensity),
                Color.white.opacity(flake.opacity * 0.5),
                Color.white.opacity(flake.opacity * 0.2),
                Color.clear
            ])
            
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - bokehSize/2,
                    y: y - bokehSize/2,
                    width: bokehSize,
                    height: bokehSize
                )),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: bokehSize/2
                )
            )
        }
    }
    
 /// 中景雪花 - 半清晰带光晕
    private func drawMidgroundSnowflakes(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        clearZones: [DynamicClearZone]
    ) {
        for flake in snowflakes where flake.layer == 1 {
            let rendered = renderedSnowflake(flake, size: size, time: time, clearZones: clearZones)
            let x = rendered.x
            let y = rendered.y
            
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: x, y: y)
            transform = transform.rotated(by: rendered.rotation * .pi / 180)
            
 // 先绘制光晕
            let glowSize = flake.size * 2
            let glowGradient = Gradient(colors: [
                Color.white.opacity(flake.opacity * flake.glowIntensity * 0.4),
                Color.clear
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - glowSize/2,
                    y: y - glowSize/2,
                    width: glowSize,
                    height: glowSize
                )),
                with: .radialGradient(
                    glowGradient,
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: glowSize/2
                )
            )
            
 // 绘制雪花
            switch flake.shape {
            case 0:
                drawSoftCircleSnowflake(context: &context, flake: flake, transform: transform)
            case 1:
                drawEnhancedSixPointedSnowflake(context: &context, flake: flake, transform: transform)
            default:
                drawEnhancedDetailedSnowflake(context: &context, flake: flake, transform: transform)
            }
        }
    }
    
 /// 近景雪花 - 高清晰度 + 强光晕
    private func drawForegroundSnowflakes(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        clearZones: [DynamicClearZone]
    ) {
        for flake in snowflakes where flake.layer == 2 {
            let rendered = renderedSnowflake(flake, size: size, time: time, clearZones: clearZones)
            let x = rendered.x
            let y = rendered.y
            
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: x, y: y)
            transform = transform.rotated(by: rendered.rotation * .pi / 180)
            
 // 强光晕效果
            let glowSize = flake.size * 2.5
            let glowGradient = Gradient(colors: [
                Color.white.opacity(flake.opacity * flake.glowIntensity * 0.6),
                Color(red: 0.9, green: 0.95, blue: 1.0).opacity(flake.opacity * 0.3),
                Color.clear
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - glowSize/2,
                    y: y - glowSize/2,
                    width: glowSize,
                    height: glowSize
                )),
                with: .radialGradient(
                    glowGradient,
                    center: CGPoint(x: x, y: y),
                    startRadius: 0,
                    endRadius: glowSize/2
                )
            )
            
 // 高精度雪花
            switch flake.shape {
            case 1:
                drawEnhancedSixPointedSnowflake(context: &context, flake: flake, transform: transform)
            default:
                drawPremiumDetailedSnowflake(context: &context, flake: flake, transform: transform)
            }
        }
    }
    
 /// 软焦点圆形雪花
    private func drawSoftCircleSnowflake(context: inout GraphicsContext, flake: PhysicsSnowflake, transform: CGAffineTransform) {
        let rect = CGRect(x: -flake.size/2, y: -flake.size/2, width: flake.size, height: flake.size)
        let path = Path(ellipseIn: rect).applying(transform)
        
        context.fill(path, with: .color(Color.white.opacity(flake.opacity)))
    }
    
 /// 增强六角星雪花
    private func drawEnhancedSixPointedSnowflake(context: inout GraphicsContext, flake: PhysicsSnowflake, transform: CGAffineTransform) {
        var path = Path()
        
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            let endX = cos(angle) * Double(flake.size)
            let endY = sin(angle) * Double(flake.size)
            
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: endX, y: endY))
            
 // 添加小分支
            let midX = endX * 0.6
            let midY = endY * 0.6
            let branchSize = Double(flake.size) * 0.3
            
            path.move(to: CGPoint(x: midX, y: midY))
            path.addLine(to: CGPoint(
                x: midX + cos(angle + .pi/4) * branchSize,
                y: midY + sin(angle + .pi/4) * branchSize
            ))
            path.move(to: CGPoint(x: midX, y: midY))
            path.addLine(to: CGPoint(
                x: midX + cos(angle - .pi/4) * branchSize,
                y: midY + sin(angle - .pi/4) * branchSize
            ))
        }
        
 // 中心点
        let centerSize = flake.size * 0.15
        let centerPath = Path(ellipseIn: CGRect(
            x: -centerSize/2,
            y: -centerSize/2,
            width: centerSize,
            height: centerSize
        )).applying(transform)
        
        context.fill(centerPath, with: .color(Color.white.opacity(flake.opacity)))
        context.stroke(
            path.applying(transform),
            with: .color(Color.white.opacity(flake.opacity)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }
    
 /// 增强详细晶体雪花
    private func drawEnhancedDetailedSnowflake(context: inout GraphicsContext, flake: PhysicsSnowflake, transform: CGAffineTransform) {
        var path = Path()
        
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            let endX = cos(angle) * Double(flake.size)
            let endY = sin(angle) * Double(flake.size)
            
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: endX, y: endY))
            
            for branch in 1...3 {
                let branchRatio = Double(branch) / 4.0
                let branchX = cos(angle) * Double(flake.size) * branchRatio
                let branchY = sin(angle) * Double(flake.size) * branchRatio
                let branchSize = Double(flake.size) * 0.25 * (1.0 - branchRatio * 0.3)
                
                path.move(to: CGPoint(x: branchX, y: branchY))
                path.addLine(to: CGPoint(
                    x: branchX + cos(angle + .pi/4) * branchSize,
                    y: branchY + sin(angle + .pi/4) * branchSize
                ))
                path.move(to: CGPoint(x: branchX, y: branchY))
                path.addLine(to: CGPoint(
                    x: branchX + cos(angle - .pi/4) * branchSize,
                    y: branchY + sin(angle - .pi/4) * branchSize
                ))
            }
        }
        
 // 中心六边形
        var hexPath = Path()
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            let x = cos(angle) * Double(flake.size) * 0.2
            let y = sin(angle) * Double(flake.size) * 0.2
            if i == 0 {
                hexPath.move(to: CGPoint(x: x, y: y))
            } else {
                hexPath.addLine(to: CGPoint(x: x, y: y))
            }
        }
        hexPath.closeSubpath()
        
        context.fill(hexPath.applying(transform), with: .color(.white.opacity(flake.opacity * 0.9)))
        context.stroke(
            path.applying(transform),
            with: .color(Color.white.opacity(flake.opacity)),
            style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
        )
    }
    
 /// 高级精细雪花（近景专用）
    private func drawPremiumDetailedSnowflake(context: inout GraphicsContext, flake: PhysicsSnowflake, transform: CGAffineTransform) {
        var mainPath = Path()
        var detailPath = Path()
        
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            let endX = cos(angle) * Double(flake.size)
            let endY = sin(angle) * Double(flake.size)
            
 // 主臂（较粗）
            mainPath.move(to: .zero)
            mainPath.addLine(to: CGPoint(x: endX, y: endY))
            
 // 多级分支
            for branch in 1...4 {
                let branchRatio = Double(branch) / 5.0
                let branchX = cos(angle) * Double(flake.size) * branchRatio
                let branchY = sin(angle) * Double(flake.size) * branchRatio
                let branchSize = Double(flake.size) * 0.28 * (1.0 - branchRatio * 0.25)
                
 // 左分支
                detailPath.move(to: CGPoint(x: branchX, y: branchY))
                detailPath.addLine(to: CGPoint(
                    x: branchX + cos(angle + .pi/3.5) * branchSize,
                    y: branchY + sin(angle + .pi/3.5) * branchSize
                ))
 // 右分支
                detailPath.move(to: CGPoint(x: branchX, y: branchY))
                detailPath.addLine(to: CGPoint(
                    x: branchX + cos(angle - .pi/3.5) * branchSize,
                    y: branchY + sin(angle - .pi/3.5) * branchSize
                ))
                
 // 二级分支（仅前两级）
                if branch <= 2 {
                    let subBranchSize = branchSize * 0.4
                    let subX = branchX + cos(angle + .pi/3.5) * branchSize * 0.6
                    let subY = branchY + sin(angle + .pi/3.5) * branchSize * 0.6
                    
                    detailPath.move(to: CGPoint(x: subX, y: subY))
                    detailPath.addLine(to: CGPoint(
                        x: subX + cos(angle + .pi/2) * subBranchSize,
                        y: subY + sin(angle + .pi/2) * subBranchSize
                    ))
                }
            }
            
 // 末端装饰
            let tipSize = Double(flake.size) * 0.08
            let tipPath = Path(ellipseIn: CGRect(
                x: endX - tipSize/2,
                y: endY - tipSize/2,
                width: tipSize,
                height: tipSize
            ))
            context.fill(tipPath.applying(transform), with: .color(.white.opacity(flake.opacity)))
        }
        
 // 中心装饰 - 双层六边形
        for scale in [0.15, 0.25] {
            var hexPath = Path()
            for i in 0..<6 {
                let angle = Double(i) * .pi / 3 + (scale > 0.2 ? .pi/6 : 0)
                let x = cos(angle) * Double(flake.size) * scale
                let y = sin(angle) * Double(flake.size) * scale
                if i == 0 {
                    hexPath.move(to: CGPoint(x: x, y: y))
                } else {
                    hexPath.addLine(to: CGPoint(x: x, y: y))
                }
            }
            hexPath.closeSubpath()
            context.fill(hexPath.applying(transform), with: .color(.white.opacity(flake.opacity * (scale < 0.2 ? 1.0 : 0.6))))
        }
        
 // 绘制线条
        context.stroke(
            mainPath.applying(transform),
            with: .color(Color.white.opacity(flake.opacity)),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
        )
        context.stroke(
            detailPath.applying(transform),
            with: .color(Color.white.opacity(flake.opacity * 0.9)),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
        )
    }
    
 /// 增强版积雪
    private func drawEnhancedSnowPiles(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let groundY = size.height * 0.88
        
 // 基础积雪层 - 多层渐变
        let baseGradient = Gradient(colors: [
            Color(red: 0.95, green: 0.97, blue: 1.0).opacity(0.7),
            Color.white.opacity(0.85),
            Color(red: 0.9, green: 0.92, blue: 0.95).opacity(0.9)
        ])
        
        context.fill(
            Path(CGRect(x: 0, y: groundY, width: size.width, height: size.height - groundY)),
            with: .linearGradient(
                baseGradient,
                startPoint: CGPoint(x: 0, y: groundY),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        
 // 积雪堆 - 带阴影和高光
        for pile in snowPiles {
            let x = pile.x * size.width
            let startX = x - pile.width / 2
            let endX = x + pile.width / 2
            let baseY = groundY
            let peakY = groundY - pile.height
            
 // 阴影
            var shadowPath = Path()
            shadowPath.move(to: CGPoint(x: startX + 3, y: baseY + 2))
            shadowPath.addQuadCurve(
                to: CGPoint(x: endX + 3, y: baseY + 2),
                control: CGPoint(x: x + 3, y: peakY + 2)
            )
            shadowPath.closeSubpath()
            context.fill(shadowPath, with: .color(Color.black.opacity(0.1)))
            
 // 主体
            var pilePath = Path()
            pilePath.move(to: CGPoint(x: startX, y: baseY))
            pilePath.addQuadCurve(
                to: CGPoint(x: endX, y: baseY),
                control: CGPoint(x: x, y: peakY)
            )
            pilePath.closeSubpath()
            
            let pileGradient = Gradient(colors: [
                Color.white.opacity(pile.opacity * 1.1),
                Color(red: 0.95, green: 0.97, blue: 1.0).opacity(pile.opacity)
            ])
            
            context.fill(
                pilePath,
                with: .linearGradient(
                    pileGradient,
                    startPoint: CGPoint(x: x, y: peakY),
                    endPoint: CGPoint(x: x, y: baseY)
                )
            )
            
 // 高光
            let highlightPath = Path(ellipseIn: CGRect(
                x: x - pile.width * 0.15,
                y: peakY + pile.height * 0.1,
                width: pile.width * 0.3,
                height: pile.height * 0.3
            ))
            context.fill(highlightPath, with: .color(Color.white.opacity(0.4)))
        }
    }

}

// MARK: - 电影级天空背景

struct CinematicSnowSkyGradient: View {
    let time: Double
    
    var body: some View {
        Canvas { context, size in
 // 多层天空渐变 - 冬日阴天
            let skyGradient = Gradient(colors: [
                Color(red: 0.75, green: 0.80, blue: 0.88), // 顶部：淡蓝灰
                Color(red: 0.82, green: 0.85, blue: 0.90), // 中上：浅灰
                Color(red: 0.88, green: 0.90, blue: 0.93), // 中下：亮灰
                Color(red: 0.92, green: 0.93, blue: 0.95)  // 底部：接近白
            ])
            
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    skyGradient,
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            
 // 模糊的太阳光晕（透过云层）
            let sunX = size.width * (0.3 + 0.05 * sin(time * 0.02))
            let sunY = size.height * 0.15
            
            let sunGradient = Gradient(colors: [
                Color.white.opacity(0.25),
                Color(red: 1.0, green: 0.98, blue: 0.95).opacity(0.15),
                Color.clear
            ])
            
            context.fill(
                Path(ellipseIn: CGRect(
                    x: sunX - 150,
                    y: sunY - 100,
                    width: 300,
                    height: 200
                )),
                with: .radialGradient(
                    sunGradient,
                    center: CGPoint(x: sunX, y: sunY),
                    startRadius: 0,
                    endRadius: 180
                )
            )
            
 // 动态云层暗部
            for i in 0..<3 {
                let cloudX = (CGFloat(i) * 0.4 + CGFloat(time * 0.01).truncatingRemainder(dividingBy: 1.2)) * size.width
                let cloudY = size.height * CGFloat(0.1 + Double(i) * 0.08)
                let cloudWidth = size.width * CGFloat(0.3 + Double(i) * 0.1)
                
                let cloudGradient = Gradient(colors: [
                    Color(red: 0.7, green: 0.73, blue: 0.78).opacity(0.3),
                    Color.clear
                ])
                
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: cloudX - cloudWidth/2,
                        y: cloudY - cloudWidth * 0.2,
                        width: cloudWidth,
                        height: cloudWidth * 0.4
                    )),
                    with: .radialGradient(
                        cloudGradient,
                        center: CGPoint(x: cloudX, y: cloudY),
                        startRadius: 0,
                        endRadius: cloudWidth/2
                    )
                )
            }
        }
    }
}

// MARK: - 远景大气雾

struct DistantAtmosphericFog: View {
    let time: Double
    let intensity: Double
    
    var body: some View {
        Canvas { context, size in
 // 底部远景雾
            let fogGradient = Gradient(colors: [
                Color.clear,
                Color(red: 0.9, green: 0.92, blue: 0.95).opacity(intensity * 0.3),
                Color(red: 0.85, green: 0.88, blue: 0.92).opacity(intensity * 0.5)
            ])
            
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    fogGradient,
                    startPoint: CGPoint(x: 0, y: size.height * 0.4),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            
 // 动态雾气团
            for i in 0..<5 {
                let phase = time * 0.05 + Double(i) * 1.2
                let x = (sin(phase) * 0.3 + 0.5 + Double(i) * 0.15).truncatingRemainder(dividingBy: 1.2) * size.width
                let y = size.height * (0.6 + Double(i) * 0.08)
                let fogSize = size.width * CGFloat(0.25 + sin(phase * 0.7) * 0.1)
                
                let localFogGradient = Gradient(colors: [
                    Color.white.opacity(intensity * 0.2),
                    Color.clear
                ])
                
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - fogSize/2,
                        y: y - fogSize * 0.3,
                        width: fogSize,
                        height: fogSize * 0.6
                    )),
                    with: .radialGradient(
                        localFogGradient,
                        center: CGPoint(x: x, y: y),
                        startRadius: 0,
                        endRadius: fogSize/2
                    )
                )
            }
        }
    }
}

// MARK: - 雪天色彩分级

struct SnowColorGrading: View {
    let time: Double
    
    var body: some View {
        ZStack {
 // 冷色调高光
            LinearGradient(
                colors: [
                    Color(red: 0.85, green: 0.90, blue: 1.0).opacity(0.15),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
            
 // 暖色调阴影（地面反射）
            LinearGradient(
                colors: [
                    Color.clear,
                    Color(red: 1.0, green: 0.95, blue: 0.90).opacity(0.1)
                ],
                startPoint: .center,
                endPoint: .bottom
            )
            
 // 轻微的蓝色整体色调
            Color(red: 0.9, green: 0.93, blue: 1.0).opacity(0.08)
        }
    }
}

// MARK: - 雪天暗角

struct SnowVignette: View {
    var body: some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [
                    Color.clear,
                    Color.clear,
                    Color(red: 0.3, green: 0.35, blue: 0.45).opacity(0.15),
                    Color(red: 0.2, green: 0.25, blue: 0.35).opacity(0.35)
                ],
                center: .center,
                startRadius: min(geo.size.width, geo.size.height) * 0.35,
                endRadius: max(geo.size.width, geo.size.height) * 0.75
            )
        }
    }
}
