// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// CinematicFogSystem.swift
// SkyBridgeCore
//
// 电影级体积雾系统 - 基于UE5光线步进技术
// 实现：体积渲染、Perlin噪声、深度感知、光线散射
// Created: 2025-10-19
//

import SwiftUI
import simd

// MARK: - 🌫️ 体积雾配置

public struct CinematicFogConfiguration: Sendable {
    public let targetFPS: Int
    public let fogDensity: Float
    public let rayMarchSteps: Int
    public let noiseOctaves: Int
    public let scatteringEnabled: Bool
    public let depthFadeEnabled: Bool
    public let scrollSpeed: Float
    
    public init(performanceMode: PerformanceConfiguration, intensity: Float = 0.6) {
        self.targetFPS = performanceMode.targetFrameRate
        
 // 根据粒子数量判断性能级别
        if performanceMode.maxParticles >= 3000 {
 // 极致性能
            self.fogDensity = intensity
            self.rayMarchSteps = 64
            self.noiseOctaves = 6
            self.scatteringEnabled = true
            self.depthFadeEnabled = true
            self.scrollSpeed = 1.0
        } else if performanceMode.maxParticles >= 1500 {
 // 平衡模式
            self.fogDensity = intensity * 0.9
            self.rayMarchSteps = 32
            self.noiseOctaves = 4
            self.scatteringEnabled = true
            self.depthFadeEnabled = true
            self.scrollSpeed = 0.8
        } else {
 // 节能模式
            self.fogDensity = intensity * 0.7
            self.rayMarchSteps = 16
            self.noiseOctaves = 3
            self.scatteringEnabled = false
            self.depthFadeEnabled = false
            self.scrollSpeed = 0.6
        }
    }
}

// MARK: - 📐 体积雾数学库

/// 3D体积雾采样器
@MainActor
public class VolumetricFogSampler {
    private let noise: PerlinNoise3D
    private var time: Float = 0
    
    public init(seed: Int = 999) {
        self.noise = PerlinNoise3D(seed: seed)
    }
    
 /// 光线步进采样
 /// - Parameters:
 /// - rayOrigin: 光线起点（2D屏幕坐标 + 深度）
 /// - rayDirection: 光线方向
 /// - steps: 采样步数
 /// - density: 基础雾密度
 /// - Returns: 累积雾密度（0-1）
    public func rayMarchFog(
        rayOrigin: SIMD3<Float>,
        rayDirection: SIMD3<Float>,
        steps: Int,
        density: Float,
        octaves: Int
    ) -> Float {
        var accumulatedDensity: Float = 0
        let stepSize: Float = 200.0 / Float(steps)
        
        for step in 0..<steps {
            let position = rayOrigin + rayDirection * (Float(step) * stepSize)
            
 // 多层噪声采样（FBM）
            let noiseValue = noise.fbm(
                x: position.x * 0.01 + time * 0.5,
                y: position.y * 0.01 + time * 0.3,
                z: position.z * 0.01,
                octaves: octaves
            )
            
 // 密度累积（Beer-Lambert定律）
            let sampleDensity = max(0, noiseValue - 0.4) * density
            accumulatedDensity += sampleDensity * (1.0 - accumulatedDensity)
            
 // 早期退出优化
            if accumulatedDensity > 0.99 {
                break
            }
        }
        
        return min(1.0, accumulatedDensity)
    }
    
 /// 计算光散射（Mie散射）
    public func calculateScattering(depth: Float, lightDir: SIMD3<Float>) -> Float {
        let scatteringStrength: Float = 0.3
        let depthFactor = exp(-depth * 0.01)
        return scatteringStrength * depthFactor
    }
    
    public func update(deltaTime: Float) {
        time += deltaTime
    }
}

// MARK: - 🌫️ 体积雾粒子系统

/// 雾气粒子（用于叠加渲染）
public struct FogParticle: Sendable {
    var position: SIMD3<Float>
    var size: Float
    var density: Float
    var velocity: SIMD3<Float>
    var noisePhase: Float
}

/// 雾粒子管理器
@MainActor
public class FogParticleSystem {
    private var particles: [FogParticle] = []
    private var rng: SeededRandom
    private let noise: PerlinNoise3D
    private var time: Float = 0
    
    public init(count: Int, seed: Int = 888) {
        self.rng = SeededRandom(seed: seed)
        self.noise = PerlinNoise3D(seed: seed + 100)
        
        for _ in 0..<count {
            particles.append(createParticle())
        }
    }
    
    private func createParticle() -> FogParticle {
        let x = rng.next() * 2000 - 1000
        let y = rng.next() * 1500
        let z = rng.next() * 500
        
        return FogParticle(
            position: SIMD3<Float>(x, y, z),
            size: 100 + rng.next() * 200,
            density: 0.1 + rng.next() * 0.2,
            velocity: SIMD3<Float>(
                rng.next() * 2 - 1,
                rng.next() * 0.5 - 0.25,
                0
            ) * 0.3,
            noisePhase: rng.next() * 100
        )
    }
    
    public func update(deltaTime: Float, scrollSpeed: Float) {
        time += deltaTime
        
        for i in 0..<particles.count {
 // 风力驱动
            particles[i].position += particles[i].velocity * scrollSpeed * deltaTime * 60
            
 // 噪声扰动
            let noiseX = particles[i].position.x * 0.01 + time * 0.2
            let noiseY = particles[i].position.y * 0.01 + time * 0.15
            let noiseZ = particles[i].noisePhase
            
            let noiseValue = noise.fbm(x: noiseX, y: noiseY, z: noiseZ, octaves: 3)
            particles[i].density = 0.15 + noiseValue * 0.25
            
 // 循环边界
            if particles[i].position.x > 1000 {
                particles[i].position.x = -1000
            } else if particles[i].position.x < -1000 {
                particles[i].position.x = 1000
            }
            
            if particles[i].position.y > 1500 {
                particles[i].position.y = 0
            }
        }
    }
    
    public func render(context: inout GraphicsContext, in size: CGSize, globalDensity: Float) {
 // 按深度排序（远到近）
        let sorted = particles.sorted { $0.position.z < $1.position.z }
        
        for particle in sorted {
 // 3D到2D投影
            let depth = particle.position.z + 100
            let scale = 100.0 / depth
            
            let screenX = size.width / 2 + CGFloat(particle.position.x) * CGFloat(scale)
            let screenY = CGFloat(particle.position.y) * CGFloat(scale)
            let screenSize = CGFloat(particle.size) * CGFloat(scale)
            
 // 深度衰减
            let depthFade = max(0, 1.0 - depth / 600.0)
            let alpha = particle.density * globalDensity * depthFade
            
            let rect = CGRect(
                x: screenX - screenSize / 2,
                y: screenY - screenSize / 2,
                width: screenSize,
                height: screenSize
            )
            
 // 渐变雾气（中心浓，边缘淡）
            let gradient = Gradient(colors: [
                Color.white.opacity(Double(alpha)),
                Color.white.opacity(Double(alpha) * 0.5),
                Color.white.opacity(0)
            ])
            
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: screenSize / 2
                )
            )
        }
    }
}

// MARK: - 🎨 全屏雾效渲染器

/// 全屏体积雾效果
@MainActor
public class FullScreenFogRenderer {
    private let sampler: VolumetricFogSampler
    private let config: CinematicFogConfiguration
    private var cachedDensityMap: [[Float]] = []
    private var cacheUpdateTimer: Float = 0
    private let cacheResolution: Int = 32
    
    public init(config: CinematicFogConfiguration, seed: Int = 777) {
        self.sampler = VolumetricFogSampler(seed: seed)
        self.config = config
        initializeCache()
    }
    
    private func initializeCache() {
        cachedDensityMap = Array(
            repeating: Array(repeating: Float(0), count: cacheResolution),
            count: cacheResolution
        )
    }
    
    public func update(deltaTime: Float) {
        sampler.update(deltaTime: deltaTime * config.scrollSpeed)
        cacheUpdateTimer += deltaTime
        
 // 每0.1秒更新一次密度缓存
        if cacheUpdateTimer > 0.1 {
            cacheUpdateTimer = 0
            updateDensityCache()
        }
    }
    
    private func updateDensityCache() {
        let rayDir = SIMD3<Float>(0, 0, 1)  // 朝向屏幕
        
        for y in 0..<cacheResolution {
            for x in 0..<cacheResolution {
                let screenX = Float(x) / Float(cacheResolution) * 2000 - 1000
                let screenY = Float(y) / Float(cacheResolution) * 1000
                
                let rayOrigin = SIMD3<Float>(screenX, screenY, 0)
                let density = sampler.rayMarchFog(
                    rayOrigin: rayOrigin,
                    rayDirection: rayDir,
                    steps: config.rayMarchSteps,
                    density: config.fogDensity,
                    octaves: config.noiseOctaves
                )
                
                cachedDensityMap[y][x] = density
            }
        }
    }
    
    public func render(context: inout GraphicsContext, in size: CGSize, clearZones: [ClearZone]) {
        let cellWidth = size.width / CGFloat(cacheResolution)
        let cellHeight = size.height / CGFloat(cacheResolution)
        
        for y in 0..<cacheResolution {
            for x in 0..<cacheResolution {
                var density = cachedDensityMap[y][x]
                
                let cellRect = CGRect(
                    x: CGFloat(x) * cellWidth,
                    y: CGFloat(y) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                
 // 应用清空区域
 // 清除区域采用屏幕像素坐标（与 MouseTrackingNSView 翻转后的一致）。
 // 统一半径语义：使用 currentRadius（基于创建时间的1秒内线性衰减）。
 // 为避免极端情况下半径过小导致清除效果不可见，这里加入最小半径保护（12px）。
                for zone in clearZones {
                    let distance = hypot(
                        cellRect.midX - zone.center.x,
                        cellRect.midY - zone.center.y
                    )
                    let safeRadius = max(CGFloat(zone.currentRadius), 12) // 最小半径保护（像素）
                    if distance < safeRadius {
                        let fadeFactor = distance / safeRadius
                        density *= Float(fadeFactor)
                    }
                }
                
                if density > 0.01 {
 // 深度渐变（上淡下浓）
                    let depthGradient = Float(y) / Float(cacheResolution)
                    let finalDensity = density * (0.5 + depthGradient * 0.5)
                    
                    context.fill(
                        Path(cellRect),
                        with: .color(.white.opacity(Double(finalDensity) * 0.4))
                    )
                }
            }
        }
    }
}

// MARK: - 💨 雾气流动效果

/// 雾气流动线条
public struct FogStreamLine: Sendable {
    var points: [SIMD2<Float>]
    var opacity: Float
    var lifetime: Float
}

/// 雾气流动系统
@MainActor
public class FogStreamSystem {
    private var streamLines: [FogStreamLine] = []
    private var rng: SeededRandom
    private var spawnTimer: Float = 0
    
    public init(seed: Int = 666) {
        self.rng = SeededRandom(seed: seed)
    }
    
    public func update(deltaTime: Float, screenSize: CGSize) {
        spawnTimer += deltaTime
        
 // 生成新流线
        if spawnTimer > 0.5 && streamLines.count < 20 {
            spawnTimer = 0
            spawnStreamLine(screenSize: screenSize)
        }
        
 // 更新现有流线
        for i in (0..<streamLines.count).reversed() {
            streamLines[i].lifetime += deltaTime
            
 // 移动流线
            for j in 0..<streamLines[i].points.count {
                streamLines[i].points[j].x += 30 * deltaTime
                streamLines[i].points[j].y += sin(streamLines[i].points[j].x * 0.01) * 20 * deltaTime
            }
            
 // 移除过期流线
            if streamLines[i].lifetime > 10.0 ||
               streamLines[i].points.first?.x ?? 0 > Float(screenSize.width) + 100 {
                streamLines.remove(at: i)
            }
        }
    }
    
    private func spawnStreamLine(screenSize: CGSize) {
        let startY = rng.next() * Float(screenSize.height)
        let pointCount = Int(5 + rng.next() * 10)
        var points: [SIMD2<Float>] = []
        
        for i in 0..<pointCount {
            let x = Float(i) * 20 - 100
            let y = startY + (rng.next() * 40 - 20)
            points.append(SIMD2<Float>(x, y))
        }
        
        streamLines.append(FogStreamLine(
            points: points,
            opacity: 0.1 + rng.next() * 0.2,
            lifetime: 0
        ))
    }
    
    public func render(context: inout GraphicsContext, in size: CGSize) {
        for streamLine in streamLines {
            guard streamLine.points.count > 1 else { continue }
            
            var path = Path()
            let first = streamLine.points[0]
            path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
            
            for point in streamLine.points.dropFirst() {
                path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            }
            
            let fadeRatio = max(0, 1.0 - streamLine.lifetime / 10.0)
            
            context.stroke(
                path,
                with: .color(.white.opacity(Double(streamLine.opacity) * Double(fadeRatio))),
                lineWidth: 2
            )
        }
    }
}

// MARK: - 🎬 电影级雾效主视图

@available(macOS 14.0, *)
public struct CinematicFogView: View {
    private let config: CinematicFogConfiguration
    let clearZones: [ClearZone]
    
    @State private var particleSystem: FogParticleSystem?
    @State private var fullScreenRenderer: FullScreenFogRenderer?
    @State private var streamSystem: FogStreamSystem?
    
    public init(config: PerformanceConfiguration, intensity: Float = 0.6, clearZones: [ClearZone] = []) {
        self.config = CinematicFogConfiguration(performanceMode: config, intensity: intensity)
        self.clearZones = clearZones
    }
    
    public var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / Double(config.targetFPS))) { timeline in
                Canvas { context, size in
                    let deltaTime = Float(1.0 / Double(config.targetFPS))
                    
 // 1. 全屏体积雾（光线步进）
                    if config.rayMarchSteps > 0 {
                        fullScreenRenderer?.update(deltaTime: deltaTime)
                        fullScreenRenderer?.render(context: &context, in: size, clearZones: clearZones)
                    }
                    
 // 2. 雾气粒子系统
                    particleSystem?.update(deltaTime: deltaTime, scrollSpeed: config.scrollSpeed)
                    particleSystem?.render(context: &context, in: size, globalDensity: config.fogDensity)
                    
 // 3. 雾气流动效果
                    streamSystem?.update(deltaTime: deltaTime, screenSize: size)
                    streamSystem?.render(context: &context, in: size)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            initializeSystems()
        }
    }
    
    @MainActor
    private func initializeSystems() {
 // 粒子数量根据性能调整
        let particleCount: Int
        switch config.noiseOctaves {
        case 6...:
            particleCount = 150
        case 4...5:
            particleCount = 100
        default:
            particleCount = 60
        }
        
        particleSystem = FogParticleSystem(count: particleCount)
        fullScreenRenderer = FullScreenFogRenderer(config: config)
        streamSystem = FogStreamSystem()
    }
}

// MARK: - 🌫️ 清空区域定义
// ClearZone已在WeatherEffectView.swift中定义

#endif
