//
// CinematicRainSystem.swift
// SkyBridgeCore
//
// 电影级雨天系统 - 基于UE5和3A游戏技术
// 实现：体积云、物理雨滴、玻璃水珠、水面反射、闪电系统
// Created: 2025-10-19
//

import SwiftUI
import Metal
import simd

// MARK: - 🌧️ 电影级雨天渲染系统

/// 电影级雨天系统配置
public struct CinematicRainConfiguration: Sendable {
    public let targetFPS: Int
    public let rainParticleCount: Int
    public let cloudLayers: Int
    public let glassDropletCount: Int
    public let lightningEnabled: Bool
    public let reflectionsEnabled: Bool
    public let windStrength: Float

    public init(performanceMode: PerformanceConfiguration) {
        self.targetFPS = performanceMode.targetFrameRate

 // 根据粒子数量判断性能级别
        if performanceMode.maxParticles >= 3000 {
 // 极致性能
            self.rainParticleCount = 2500
            self.cloudLayers = 8
            self.glassDropletCount = 120
            self.lightningEnabled = true
            self.reflectionsEnabled = true
            self.windStrength = 1.0
        } else if performanceMode.maxParticles >= 1500 {
 // 平衡模式
            self.rainParticleCount = 1500
            self.cloudLayers = 5
            self.glassDropletCount = 80
            self.lightningEnabled = true
            self.reflectionsEnabled = true
            self.windStrength = 0.8
        } else {
 // 节能模式
            self.rainParticleCount = 800
            self.cloudLayers = 3
            self.glassDropletCount = 40
            self.lightningEnabled = false
            self.reflectionsEnabled = false
            self.windStrength = 0.6
        }
    }
}

// MARK: - 📐 数学工具

/// 3D噪声生成器（基于Perlin噪声）
public struct PerlinNoise3D: Sendable {
    private let permutation: [Int]

    public init(seed: Int = 42) {
        var p = Array(0..<256)
        var rng = SeededRandom(seed: seed)

 // Fisher-Yates shuffle
        for i in stride(from: 255, through: 1, by: -1) {
            let j = Int(rng.next() * Float(i + 1))
            p.swapAt(i, j)
        }

        self.permutation = p + p // 重复以避免边界检查
    }

 /// 3D Perlin噪声
    public func noise(x: Float, y: Float, z: Float) -> Float {
        let X = Int(floor(x)) & 255
        let Y = Int(floor(y)) & 255
        let Z = Int(floor(z)) & 255

        let xf = x - floor(x)
        let yf = y - floor(y)
        let zf = z - floor(z)

        let u = fade(xf)
        let v = fade(yf)
        let w = fade(zf)

        let aaa = permutation[permutation[permutation[X] + Y] + Z]
        let aba = permutation[permutation[permutation[X] + Y + 1] + Z]
        let aab = permutation[permutation[permutation[X] + Y] + Z + 1]
        let abb = permutation[permutation[permutation[X] + Y + 1] + Z + 1]
        let baa = permutation[permutation[permutation[X + 1] + Y] + Z]
        let bba = permutation[permutation[permutation[X + 1] + Y + 1] + Z]
        let bab = permutation[permutation[permutation[X + 1] + Y] + Z + 1]
        let bbb = permutation[permutation[permutation[X + 1] + Y + 1] + Z + 1]

        let x1 = lerp(grad(aaa, xf, yf, zf), grad(baa, xf - 1, yf, zf), u)
        let x2 = lerp(grad(aba, xf, yf - 1, zf), grad(bba, xf - 1, yf - 1, zf), u)
        let y1 = lerp(x1, x2, v)

        let x3 = lerp(grad(aab, xf, yf, zf - 1), grad(bab, xf - 1, yf, zf - 1), u)
        let x4 = lerp(grad(abb, xf, yf - 1, zf - 1), grad(bbb, xf - 1, yf - 1, zf - 1), u)
        let y2 = lerp(x3, x4, v)

        return (lerp(y1, y2, w) + 1) / 2
    }

 /// 分形布朗运动（多层噪声叠加）
    public func fbm(x: Float, y: Float, z: Float, octaves: Int = 4) -> Float {
        var value: Float = 0
        var amplitude: Float = 1.0
        var frequency: Float = 1.0
        var maxValue: Float = 0

        for _ in 0..<octaves {
            value += amplitude * noise(x: x * frequency, y: y * frequency, z: z * frequency)
            maxValue += amplitude
            amplitude *= 0.5
            frequency *= 2.0
        }

        return value / maxValue
    }

    private func fade(_ t: Float) -> Float {
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + t * (b - a)
    }

    private func grad(_ hash: Int, _ x: Float, _ y: Float, _ z: Float) -> Float {
        let h = hash & 15
        let u = h < 8 ? x : y
        let v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }
}

/// 简单随机数生成器
struct SeededRandom {
    private var state: UInt64

    init(seed: Int) {
        self.state = UInt64(seed)
    }

    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 33) / Float(UInt32.max)
    }
}

// MARK: - ☁️ 体积云系统

/// 体积云粒子
public struct VolumetricCloudParticle: Sendable {
    var position: SIMD3<Float>
    var size: Float
    var density: Float
    var velocity: SIMD2<Float>
    var noiseOffset: SIMD3<Float>
}

/// 体积云层
@MainActor
public class VolumetricCloudLayer {
    private var particles: [VolumetricCloudParticle] = []
    private let noise = PerlinNoise3D(seed: 123)
    private var time: Float = 0

    public init(layerIndex: Int, particleCount: Int, altitude: Float) {
        var rng = SeededRandom(seed: layerIndex * 100)

        for _ in 0..<particleCount {
            let x = rng.next() * 2000 - 1000
            let y = altitude + rng.next() * 50 - 25
            let z = rng.next() * 100

            particles.append(VolumetricCloudParticle(
                position: SIMD3<Float>(x, y, z),
                size: 80 + rng.next() * 120,
                density: 0.3 + rng.next() * 0.4,
                velocity: SIMD2<Float>(rng.next() * 2 - 1, rng.next() * 0.5 - 0.25) * 0.5,
                noiseOffset: SIMD3<Float>(rng.next() * 100, rng.next() * 100, rng.next() * 100)
            ))
        }
    }

    public func update(deltaTime: Float, windStrength: Float) {
        time += deltaTime

        for i in 0..<particles.count {
 // 风力驱动
            particles[i].position.x += particles[i].velocity.x * windStrength * deltaTime * 60
            particles[i].position.y += particles[i].velocity.y * deltaTime * 60

 // 噪声扰动（模拟云的形变）
            let noiseX = particles[i].noiseOffset.x + time * 0.1
            let noiseY = particles[i].noiseOffset.y + time * 0.1
            let noiseZ = particles[i].noiseOffset.z
            let noiseValue = noise.fbm(x: noiseX, y: noiseY, z: noiseZ, octaves: 3)

            particles[i].density = 0.3 + noiseValue * 0.5

 // 循环边界
            if particles[i].position.x > 1000 {
                particles[i].position.x = -1000
            } else if particles[i].position.x < -1000 {
                particles[i].position.x = 1000
            }
        }
    }

    public func render(context: inout GraphicsContext, in size: CGSize, cameraY: Float) {
        for particle in particles {
 // 3D到2D投影（简单透视）
            let depth = particle.position.z + 100
            let scale = 100.0 / depth
            let screenX = size.width / 2 + CGFloat(particle.position.x) * CGFloat(scale)
            let screenY = CGFloat(particle.position.y - cameraY) * CGFloat(scale)

            let screenSize = CGFloat(particle.size) * CGFloat(scale)

 // 深度衰减（越远越淡）
            let depthFade = max(0, 1.0 - depth / 200.0)
            let alpha = particle.density * depthFade * 0.7

            let rect = CGRect(
                x: screenX - screenSize / 2,
                y: screenY,
                width: screenSize,
                height: screenSize / 2
            )

            context.fill(
                Path(ellipseIn: rect),
                with: .color(.white.opacity(Double(alpha)))
            )
        }
    }

    /// AAA 风格：更“电影级”的体积云绘制（银边高光 + 底部阴影 + 更柔和的密度渐变）
    ///
    /// - Note: 保持 `render(context:in:cameraY:)` 原样不变，避免影响既有雨天系统；
    ///         多云效果会显式调用本方法。
    public func renderCinematic(
        context: inout GraphicsContext,
        in size: CGSize,
        cameraY: Float,
        tint: Color = Color(white: 0.95),
        shadowTint: Color = Color(white: 0.65),
        highlightTint: Color = Color.white
    ) {
        for particle in particles {
            let depth = particle.position.z + 100
            let scale = 100.0 / depth
            let screenX = size.width / 2 + CGFloat(particle.position.x) * CGFloat(scale)
            let screenY = CGFloat(particle.position.y - cameraY) * CGFloat(scale)

            // 让云更“厚”：高度略增
            let baseSize = CGFloat(particle.size) * CGFloat(scale)
            let w = baseSize * 1.25
            let h = (baseSize / 2) * 1.35

            let depthFade = max(0, 1.0 - depth / 240.0)
            let a = Double(particle.density * depthFade)

            let bodyRect = CGRect(x: screenX - w / 2, y: screenY, width: w, height: h)
            let shadowRect = bodyRect.offsetBy(dx: 0, dy: h * 0.18)
            let highlightRect = bodyRect.offsetBy(dx: 0, dy: -h * 0.12)

            // 1) 主体密度（中心更密，边缘更稀）
            let body = Gradient(colors: [
                tint.opacity(0.55 * a),
                tint.opacity(0.18 * a),
                Color.clear
            ])
            context.fill(
                Path(ellipseIn: bodyRect),
                with: .radialGradient(
                    body,
                    center: CGPoint(x: bodyRect.midX, y: bodyRect.midY),
                    startRadius: 0,
                    endRadius: max(bodyRect.width, bodyRect.height) * 0.62
                )
            )

            // 2) 底部阴影（更重的“云底”）
            let shadow = Gradient(colors: [
                shadowTint.opacity(0.16 * a),
                Color.clear
            ])
            context.fill(
                Path(ellipseIn: shadowRect),
                with: .radialGradient(
                    shadow,
                    center: CGPoint(x: shadowRect.midX, y: shadowRect.midY + shadowRect.height * 0.15),
                    startRadius: 0,
                    endRadius: max(shadowRect.width, shadowRect.height) * 0.70
                )
            )

            // 3) 银边高光（受光侧微弱高光）
            let highlight = Gradient(colors: [
                highlightTint.opacity(0.12 * a),
                Color.clear
            ])
            context.fill(
                Path(ellipseIn: highlightRect),
                with: .radialGradient(
                    highlight,
                    center: CGPoint(x: highlightRect.midX, y: highlightRect.midY - highlightRect.height * 0.10),
                    startRadius: 0,
                    endRadius: max(highlightRect.width, highlightRect.height) * 0.55
                )
            )
        }
    }
}

// MARK: - 💧 物理雨滴系统

/// 物理雨滴（3层景深）
public struct PhysicalRaindrop: Sendable {
    var position: SIMD2<Float>
    var velocity: Float
    var length: Float
    var thickness: Float
    var layer: Int  // 0=远景, 1=中景, 2=近景
    var opacity: Float
    var windOffset: Float
}

/// 雨滴渲染器
@MainActor
public class RainParticleSystem {
    private var raindrops: [PhysicalRaindrop] = []
    private var rng: SeededRandom

    public init(count: Int, seed: Int = 456) {
        self.rng = SeededRandom(seed: seed)

        for _ in 0..<count {
            raindrops.append(createRaindrop())
        }
    }

    private func createRaindrop() -> PhysicalRaindrop {
        let layer = Int(rng.next() * 3) // 0, 1, 2
        let layerConfig = getLayerConfig(layer)

        return PhysicalRaindrop(
            position: SIMD2<Float>(rng.next() * 2000 - 1000, -50 - rng.next() * 100),
            velocity: layerConfig.velocity * (0.9 + rng.next() * 0.2),
            length: layerConfig.length * (0.8 + rng.next() * 0.4),
            thickness: layerConfig.thickness,
            layer: layer,
            opacity: layerConfig.opacity * (0.7 + rng.next() * 0.3),
            windOffset: rng.next() * 10
        )
    }

    private func getLayerConfig(_ layer: Int) -> (velocity: Float, length: Float, thickness: Float, opacity: Float) {
        switch layer {
        case 0:  // 远景（慢、短、淡）
            return (velocity: 800, length: 15, thickness: 0.5, opacity: 0.3)
        case 1:  // 中景
            return (velocity: 1200, length: 25, thickness: 1.0, opacity: 0.6)
        case 2:  // 近景（快、长、清晰）
            return (velocity: 1800, length: 40, thickness: 1.5, opacity: 0.9)
        default:
            return (velocity: 1200, length: 25, thickness: 1.0, opacity: 0.6)
        }
    }

    public func update(deltaTime: Float, windStrength: Float, screenHeight: Float) {
        for i in 0..<raindrops.count {
            let wind = sin(raindrops[i].windOffset + raindrops[i].position.y * 0.01) * windStrength * 100

            raindrops[i].position.x += wind * deltaTime
            raindrops[i].position.y += raindrops[i].velocity * deltaTime

 // 重置越界雨滴
            if raindrops[i].position.y > screenHeight + 50 {
                raindrops[i] = createRaindrop()
            }
        }
    }

    public func render(context: inout GraphicsContext, in size: CGSize) {
 // 按层次排序（先画远景）
        let sorted = raindrops.sorted { $0.layer < $1.layer }

        for drop in sorted {
            let screenX = size.width / 2 + CGFloat(drop.position.x)
            let screenY = CGFloat(drop.position.y)

            guard screenX >= -50 && screenX <= size.width + 50 else { continue }

            let start = CGPoint(x: screenX, y: screenY)
            let end = CGPoint(x: screenX, y: screenY + CGFloat(drop.length))

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)

 // 渐变尾迹（头部透明，尾部不透明）
            let gradient = Gradient(colors: [
                .white.opacity(Double(drop.opacity) * 0.3),
                .white.opacity(Double(drop.opacity) * 0.7),
                .white.opacity(Double(drop.opacity))
            ])

            context.stroke(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: start,
                    endPoint: end
                ),
                lineWidth: CGFloat(drop.thickness)
            )
        }
    }
}

// MARK: - 💎 玻璃水珠系统

/// 玻璃表面水珠
public struct GlassWaterDroplet: Sendable {
    var position: SIMD2<Float>
    var size: Float
    var slideVelocity: Float
    var lifetime: Float
    var maxLifetime: Float
}

/// 玻璃水珠管理器
@MainActor
public class GlassDropletSystem {
    private var droplets: [GlassWaterDroplet] = []
    private var rng: SeededRandom
    private let maxDroplets: Int
    private var spawnTimer: Float = 0

    public init(maxCount: Int, seed: Int = 789) {
        self.maxDroplets = maxCount
        self.rng = SeededRandom(seed: seed)
    }

    public func update(deltaTime: Float, screenSize: CGSize) {
 // 生成新水珠
        spawnTimer += deltaTime
        if spawnTimer > 0.1 && droplets.count < maxDroplets {
            spawnTimer = 0
            spawnDroplet(screenSize: screenSize)
        }

 // 更新现有水珠
        for i in (0..<droplets.count).reversed() {
            droplets[i].position.y += droplets[i].slideVelocity * deltaTime * 60
            droplets[i].lifetime += deltaTime

 // 移除过期或越界水珠
            if droplets[i].lifetime > droplets[i].maxLifetime ||
               droplets[i].position.y > Float(screenSize.height) + 20 {
                droplets.remove(at: i)
            }
        }
    }

    private func spawnDroplet(screenSize: CGSize) {
        let x = rng.next() * Float(screenSize.width)
        let y = rng.next() * Float(screenSize.height) * 0.3  // 上半部分

        droplets.append(GlassWaterDroplet(
            position: SIMD2<Float>(x, y),
            size: 3 + rng.next() * 8,
            slideVelocity: 5 + rng.next() * 15,
            lifetime: 0,
            maxLifetime: 2 + rng.next() * 3
        ))
    }

    public func render(context: inout GraphicsContext, in size: CGSize) {
        for droplet in droplets {
            let center = CGPoint(x: CGFloat(droplet.position.x), y: CGFloat(droplet.position.y))
            let radius = CGFloat(droplet.size)

 // 水珠主体（半透明白色）
            let dropletPath = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))

            let fadeRatio = 1.0 - (droplet.lifetime / droplet.maxLifetime)

            context.fill(
                dropletPath,
                with: .color(.white.opacity(Double(0.3 * fadeRatio)))
            )

 // 高光（左上角）
            let highlightPath = Path(ellipseIn: CGRect(
                x: center.x - radius * 0.8,
                y: center.y - radius * 0.8,
                width: radius * 0.6,
                height: radius * 0.6
            ))

            context.fill(
                highlightPath,
                with: .color(.white.opacity(Double(0.6 * fadeRatio)))
            )

 // 阴影（右下角）
            let shadowPath = Path(ellipseIn: CGRect(
                x: center.x + radius * 0.3,
                y: center.y + radius * 0.3,
                width: radius * 0.5,
                height: radius * 0.5
            ))

            context.fill(
                shadowPath,
                with: .color(.black.opacity(Double(0.2 * fadeRatio)))
            )
        }
    }
}

// MARK: - ⚡ 闪电系统

/// 闪电生成器
@MainActor
public class LightningSystem {
    private var currentLightning: [CGPoint]? = nil
    private var flashIntensity: Float = 0
    private var nextStrikeTime: Float = 0
    private var rng: SeededRandom

    public init(seed: Int = 321) {
        self.rng = SeededRandom(seed: seed)
        scheduleNextStrike()
    }

    private func scheduleNextStrike() {
        nextStrikeTime = 10 + rng.next() * 20  // 10-30秒
    }

    public func update(deltaTime: Float, in size: CGSize) {
        nextStrikeTime -= deltaTime

        if nextStrikeTime <= 0 {
            generateLightning(in: size)
            flashIntensity = 1.0
            scheduleNextStrike()
        }

 // 闪光衰减
        if flashIntensity > 0 {
            flashIntensity -= deltaTime * 5
            if flashIntensity < 0 {
                flashIntensity = 0
                currentLightning = nil
            }
        }
    }

    private func generateLightning(in size: CGSize) {
        var points: [CGPoint] = []

        let startX = CGFloat(rng.next()) * size.width
        let startY: CGFloat = 0

        points.append(CGPoint(x: startX, y: startY))

        var currentY: CGFloat = startY
        var currentX: CGFloat = startX

 // 生成闪电路径（程序化）
        while currentY < size.height * 0.6 {
            currentY += CGFloat(20 + rng.next() * 40)
            currentX += CGFloat(rng.next() * 40 - 20)

            points.append(CGPoint(x: currentX, y: currentY))

 // 随机分叉
            if rng.next() > 0.7 {
                let branchLength = Int(3 + rng.next() * 5)
                var branchX = currentX
                var branchY = currentY

                for _ in 0..<branchLength {
                    branchX += CGFloat(rng.next() * 30 - 15)
                    branchY += CGFloat(20 + rng.next() * 20)
                    points.append(CGPoint(x: branchX, y: branchY))
                }
            }
        }

        currentLightning = points
    }

    public func render(context: inout GraphicsContext, in size: CGSize) {
 // 全屏闪光
        if flashIntensity > 0 {
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.white.opacity(Double(flashIntensity) * 0.3))
            )
        }

 // 闪电本体
        if let points = currentLightning, flashIntensity > 0.2 {
            var path = Path()
            if let first = points.first {
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }

 // 外光晕
            context.stroke(
                path,
                with: .color(.cyan.opacity(Double(flashIntensity) * 0.5)),
                lineWidth: 8
            )

 // 中层
            context.stroke(
                path,
                with: .color(.white.opacity(Double(flashIntensity) * 0.8)),
                lineWidth: 4
            )

 // 核心
            context.stroke(
                path,
                with: .color(.white.opacity(Double(flashIntensity))),
                lineWidth: 2
            )
        }
    }
}

// MARK: - 🌊 水面反射系统

/// 水面反射
@MainActor
public class WaterSurfaceSystem {
    private var ripples: [Ripple] = []
    private var time: Float = 0
    private var rng: SeededRandom

    struct Ripple {
        var center: CGPoint
        var radius: Float
        var maxRadius: Float
        var lifetime: Float
    }

    public init(seed: Int = 654) {
        self.rng = SeededRandom(seed: seed)
    }

    public func update(deltaTime: Float, screenSize: CGSize, rainIntensity: Float) {
        time += deltaTime

 // 生成新涟漪（雨滴落水）
        if rng.next() < rainIntensity * deltaTime * 10 {
            let x = CGFloat(rng.next()) * screenSize.width
            let y = screenSize.height - CGFloat(rng.next() * 60)

            ripples.append(Ripple(
                center: CGPoint(x: x, y: y),
                radius: 0,
                maxRadius: 20 + rng.next() * 40,
                lifetime: 0
            ))
        }

 // 更新涟漪
        for i in (0..<ripples.count).reversed() {
            ripples[i].lifetime += deltaTime
            ripples[i].radius = ripples[i].maxRadius * min(1.0, ripples[i].lifetime * 2)

            if ripples[i].lifetime > 2.0 {
                ripples.remove(at: i)
            }
        }
    }

    public func render(context: inout GraphicsContext, in size: CGSize) {
 // 水面基础层
        let waterRect = CGRect(
            x: 0,
            y: size.height - 60,
            width: size.width,
            height: 60
        )

        let gradient = Gradient(colors: [
            Color(red: 0.1, green: 0.2, blue: 0.3, opacity: 0.4),
            Color(red: 0.05, green: 0.15, blue: 0.25, opacity: 0.6)
        ])

        context.fill(
            Path(waterRect),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: waterRect.minY),
                endPoint: CGPoint(x: 0, y: waterRect.maxY)
            )
        )

 // 渲染涟漪
        for ripple in ripples {
            let alpha = 1.0 - (ripple.lifetime / 2.0)

            for wave in 0..<3 {
                let radius = CGFloat(ripple.radius) + CGFloat(wave) * 5
                let ripplePath = Path(ellipseIn: CGRect(
                    x: ripple.center.x - radius,
                    y: ripple.center.y - radius / 2,
                    width: radius * 2,
                    height: radius
                ))

                context.stroke(
                    ripplePath,
                    with: .color(.white.opacity(Double(alpha) * 0.3 / Double(wave + 1))),
                    lineWidth: 2
                )
            }
        }

 // 水面波动（Sine波）
        var wavePath = Path()
        let waveHeight: CGFloat = 5
        let waveFrequency: CGFloat = 0.02
        let waveSpeed = time * 2

        wavePath.move(to: CGPoint(x: 0, y: waterRect.minY))

        for x in stride(from: 0, through: size.width, by: 5) {
            let y = waterRect.minY + waveHeight * sin((x * waveFrequency) + CGFloat(waveSpeed))
            wavePath.addLine(to: CGPoint(x: x, y: y))
        }

        context.stroke(
            wavePath,
            with: .color(.white.opacity(0.2)),
            lineWidth: 1.5
        )
    }
}

// MARK: - 🎬 电影级雨天主视图

@available(macOS 14.0, *)
public struct CinematicRainView: View {
    private let config: CinematicRainConfiguration
    @State private var cloudLayers: [VolumetricCloudLayer] = []
    @State private var rainSystem: RainParticleSystem?
    @State private var glassSystem: GlassDropletSystem?
    @State private var lightningSystem: LightningSystem?
    @State private var waterSystem: WaterSurfaceSystem?
    @State private var time: Float = 0

    public init(config: PerformanceConfiguration) {
        self.config = CinematicRainConfiguration(performanceMode: config)
    }

    public var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / Double(config.targetFPS))) { timeline in
                Canvas { context, size in
                    let deltaTime = Float(1.0 / Double(config.targetFPS))

 // 1. 渲染体积云层
                    for layer in cloudLayers {
                        layer.update(deltaTime: deltaTime, windStrength: config.windStrength)
                        layer.render(context: &context, in: size, cameraY: 0)
                    }

 // 2. 渲染闪电
                    if config.lightningEnabled {
                        lightningSystem?.update(deltaTime: deltaTime, in: size)
                        lightningSystem?.render(context: &context, in: size)
                    }

 // 3. 渲染雨滴
                    rainSystem?.update(deltaTime: deltaTime, windStrength: config.windStrength, screenHeight: Float(size.height))
                    rainSystem?.render(context: &context, in: size)

 // 4. 渲染水面
                    if config.reflectionsEnabled {
                        waterSystem?.update(deltaTime: deltaTime, screenSize: size, rainIntensity: 0.5)
                        waterSystem?.render(context: &context, in: size)
                    }

 // 5. 渲染玻璃水珠
                    glassSystem?.update(deltaTime: deltaTime, screenSize: size)
                    glassSystem?.render(context: &context, in: size)

                    time += deltaTime
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            initializeSystems(size: NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080))
        }
    }

    @MainActor
    private func initializeSystems(size: CGSize) {
 // 初始化云层
        cloudLayers.removeAll()
        for i in 0..<config.cloudLayers {
            let altitude = Float(50 + i * 30)
            let particlesPerLayer = 12
            cloudLayers.append(VolumetricCloudLayer(
                layerIndex: i,
                particleCount: particlesPerLayer,
                altitude: altitude
            ))
        }

 // 初始化雨滴系统
        rainSystem = RainParticleSystem(count: config.rainParticleCount)

 // 初始化玻璃水珠
        glassSystem = GlassDropletSystem(maxCount: config.glassDropletCount)

 // 初始化闪电
        if config.lightningEnabled {
            lightningSystem = LightningSystem()
        }

 // 初始化水面
        if config.reflectionsEnabled {
            waterSystem = WaterSurfaceSystem()
        }
    }
}

