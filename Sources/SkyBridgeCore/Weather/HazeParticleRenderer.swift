//
// HazeParticleRenderer.swift
// SkyBridgeCore
//
// 动态雾霾粒子渲染器 - 真正的粒子系统实现
//

import Foundation
import SwiftUI
import MetalKit
import OSLog

// MARK: - 粒子结构

struct HazeParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var initialPos: SIMD2<Float>
    var size: Float
    var life: Float
    var maxLife: Float
    var opacity: Float
    var rotationSpeed: Float
    var rotation: Float
    
    init(position: SIMD2<Float>, size: Float = 20.0) {
        self.position = position
        self.velocity = SIMD2<Float>(0, 0)
        self.initialPos = position
        self.size = size + Float.random(in: -5...5)
        self.life = 1.0
        self.maxLife = Float.random(in: 3.0...8.0)
        self.opacity = 1.0
        self.rotationSpeed = Float.random(in: -0.5...0.5)
        self.rotation = 0.0
    }
}

struct ParticleUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var deltaTime: Float
    var intensity: Float
    var tint: SIMD4<Float>
    var windStrength: Float
    var windDirection: SIMD2<Float>
    var particleCount: Int32
    var globalOpacity: Float
    var clearZoneCount: Int32
}

struct ParticleClearZone {
    var center: SIMD2<Float>
    var radius: Float
    var strength: Float
}

// MARK: - 粒子渲染器

@MainActor
final class HazeParticleRenderer: NSObject, MTKViewDelegate {
 /// 统一日志记录器（避免使用 print）
    private let logger = Logger(subsystem: "com.skybridge.weather", category: "HazeParticleRenderer")
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    
 // 渲染管线 - 使用 Optional 而非隐式解包，支持优雅降级
    private var renderPipelineState: MTLRenderPipelineState?
    private var computePipelineState: MTLComputePipelineState?
    
 // 缓冲区
    private var particleBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var clearZoneBuffer: MTLBuffer?
    
 // 粒子系统参数
    private let maxParticles: Int = 2000
    private let maxClearZones: Int = 32
    private var particles: [HazeParticle] = []
    
 // 时间管理
    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastUpdateTime: CFTimeInterval = 0
 // 日志节流相关状态：用于降低终端滚动频率，避免影响性能
    private var lastClearZonesLogTime: CFTimeInterval = 0
    private var lastLoggedClearZonesCount: Int = 0
    private var lastLoggedClearZonesSignature: Int = 0
    private let logThrottleInterval: CFTimeInterval = 0.8  // 800毫秒节流间隔
    
 // 渲染参数
    var intensity: Float = 0.6
    var globalOpacity: Float = 1.0
    var tint: SIMD4<Float> = SIMD4(0.50, 0.56, 0.90, 1.0)
    var windStrength: Float = 0.2
    var windDirection: SIMD2<Float> = SIMD2(1.0, 0.0)
    var currentClearZones: [ParticleClearZone] = []
    
    init(view: MTKView) {
        if let dev = MTLCreateSystemDefaultDevice(), let cq = dev.makeCommandQueue() {
            self.device = dev
            self.commandQueue = cq
        } else {
            self.device = nil
            self.commandQueue = nil
            logger.error("❌ Metal 不可用，启用优雅降级（暂停渲染）")
        }
        
        super.init()
        
        if let dev = self.device {
            view.device = dev
        }
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
 // 当 Metal 不可用时暂停渲染循环，避免高频回调
        view.isPaused = (self.device == nil)
        view.enableSetNeedsDisplay = (self.device == nil)
        view.preferredFramesPerSecond = 60
        
        if self.device != nil {
            setupMetal(pixelFormat: view.colorPixelFormat)
 // 粒子初始化应使用像素单位，避免在视网膜屏上出现坐标尺度不一致问题。
 // 这里优先使用 drawableSize（像素），若在初始化阶段尺寸尚未就绪（可能为0），则回退到 bounds.size（点）。
            let initialSize: CGSize = (view.drawableSize.width > 0 && view.drawableSize.height > 0)
                ? view.drawableSize
                : view.bounds.size
            initializeParticles(viewSize: initialSize)
        }
        
        lastUpdateTime = CACurrentMediaTime()
    }
    
    private func setupMetal(pixelFormat: MTLPixelFormat) {
        guard let device = device else {
            logger.error("❌ Metal 设备不可用，跳过渲染管线设置")
            return
        }
        SkyBridgeLogger.metal.debugOnly("🔧 开始设置Metal...")
        
        var library: MTLLibrary?
        
 // 尝试多种方式加载Metal库
        SkyBridgeLogger.metal.debugOnly("🔍 尝试加载Metal库...")
        
 // 方法1: 尝试默认库
        library = device.makeDefaultLibrary()
        if library != nil {
            SkyBridgeLogger.metal.debugOnly("✅ 成功加载默认Metal库")
        } else {
            SkyBridgeLogger.metal.error("❌ 默认Metal库加载失败")
            
 // 方法2: 尝试从Bundle.module加载
            do {
                library = try device.makeDefaultLibrary(bundle: Bundle.module)
                SkyBridgeLogger.metal.debugOnly("✅ 成功从Bundle.module加载Metal库")
            } catch {
                SkyBridgeLogger.metal.error("❌ Bundle.module加载失败: \(error.localizedDescription, privacy: .private)")
                
 // 方法3: 尝试从主Bundle加载
                do {
                    library = try device.makeDefaultLibrary(bundle: Bundle.main)
                    SkyBridgeLogger.metal.debugOnly("✅ 成功从Bundle.main加载Metal库")
                } catch {
                    SkyBridgeLogger.metal.error("❌ Bundle.main加载失败: \(error.localizedDescription, privacy: .private)")
                    
 // 方法4: 尝试通过文件路径加载着色器源码
                    if let shaderPath = Bundle.module.path(forResource: "HazeParticleShaders", ofType: "metal") {
                        SkyBridgeLogger.metal.debugOnly("🔍 找到着色器文件路径: \(shaderPath)")
                        do {
                            let shaderSource = try String(contentsOfFile: shaderPath, encoding: .utf8)
                            library = try device.makeLibrary(source: shaderSource, options: nil)
                            SkyBridgeLogger.metal.debugOnly("✅ 成功从源码编译Metal库")
                        } catch {
                            SkyBridgeLogger.metal.error("❌ 源码编译失败: \(error.localizedDescription, privacy: .private)")
                        }
                    } else {
                        SkyBridgeLogger.metal.error("❌ 无法找到HazeParticleShaders.metal文件")
                    }
                }
            }
        }
        
        guard let metalLibrary = library else {
 // 优雅降级：记录错误并停止渲染流程，避免崩溃
            logger.error("❌ 无法从任何来源加载Metal库，渲染停止")
            return
        }
        
 // 设置渲染管线
        setupRenderPipeline(library: metalLibrary, pixelFormat: pixelFormat)
        
 // 设置计算管线
        setupComputePipeline(library: metalLibrary)
        
 // 创建缓冲区
        createBuffers()
    }
    
    private func setupRenderPipeline(library: MTLLibrary, pixelFormat: MTLPixelFormat) {
        guard let device = device else {
            logger.error("❌ Metal 设备不可用，无法创建渲染管线")
            return
        }
        SkyBridgeLogger.metal.debugOnly("🔍 尝试加载着色器函数...")
        
        guard let vertexFunction = library.makeFunction(name: "hazeParticleVertex") else {
            logger.error("❌ 无法找到顶点着色器函数 'hazeParticleVertex'。可用函数: \(library.functionNames)")
            return
        }
        
        guard let fragmentFunction = library.makeFunction(name: "hazeParticleFragment") else {
            logger.error("❌ 无法找到片段着色器函数 'hazeParticleFragment'。可用函数: \(library.functionNames)")
            return
        }
        
        SkyBridgeLogger.metal.debugOnly("✅ 成功加载着色器函数")
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        
 // 启用混合
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            logger.error("❌ 渲染管线创建失败: \(error.localizedDescription)")
            renderPipelineState = nil
        }
    }
    
    private func setupComputePipeline(library: MTLLibrary) {
        guard let device = device else {
            logger.error("❌ Metal 设备不可用，无法创建计算管线")
            return
        }
        SkyBridgeLogger.metal.debugOnly("🔍 尝试加载计算着色器函数...")
        
        guard let computeFunction = library.makeFunction(name: "updateHazeParticles") else {
            logger.error("❌ 无法找到计算着色器函数 'updateHazeParticles'。可用函数: \(library.functionNames)")
            return
        }
        
        SkyBridgeLogger.metal.debugOnly("✅ 成功加载计算着色器函数")
        
        do {
            computePipelineState = try device.makeComputePipelineState(function: computeFunction)
        } catch {
            logger.error("❌ 计算管线创建失败: \(error.localizedDescription)")
            computePipelineState = nil
        }
    }
    
    private func createBuffers() {
        guard let device = device else {
            logger.error("❌ Metal 设备不可用，无法创建缓冲区")
            return
        }
 // 粒子缓冲区
        let particleBufferSize = MemoryLayout<HazeParticle>.stride * maxParticles
        particleBuffer = device.makeBuffer(length: particleBufferSize, options: [.storageModeShared])
        
 // 统一变量缓冲区
        uniformBuffer = device.makeBuffer(length: MemoryLayout<ParticleUniforms>.stride, options: [.storageModeShared])
        
 // 创建缓冲区
        let clearZoneBufferSize = MemoryLayout<ParticleClearZone>.stride * maxClearZones
        clearZoneBuffer = device.makeBuffer(length: clearZoneBufferSize, options: [.storageModeShared])
    }
    
    private func initializeParticles(viewSize: CGSize) {
        particles.removeAll()
        
        let width = Float(viewSize.width)
        let height = Float(viewSize.height)
        
 // 在整个屏幕区域生成粒子
        for _ in 0..<maxParticles {
            let x = Float.random(in: -50...(width + 50))
            let y = Float.random(in: -50...(height + 50))
            let position = SIMD2<Float>(x, y)
            
            let particle = HazeParticle(position: position)
            particles.append(particle)
        }
        
        updateParticleBuffer()
    }
    
    private func updateParticleBuffer() {
        guard let buffer = particleBuffer else { return }
        
        let bufferPointer = buffer.contents().bindMemory(to: HazeParticle.self, capacity: maxParticles)
        for (index, particle) in particles.enumerated() {
            if index < maxParticles {
                bufferPointer[index] = particle
            }
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
 // 重新初始化粒子以适应新的视图大小
        initializeParticles(viewSize: size)
    }
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let cq = commandQueue,
              let commandBuffer = cq.makeCommandBuffer() else {
            return
        }
        
        let currentTime = CACurrentMediaTime()
        let deltaTime = Float(currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        
 // 更新统一变量
        updateUniforms(view: view, deltaTime: deltaTime)
        
 // 计算着色器更新粒子
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder(), let computePipelineState {
            computeEncoder.setComputePipelineState(computePipelineState)
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 1)
            computeEncoder.setBuffer(clearZoneBuffer, offset: 0, index: 2)
            
            let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
            let threadGroups = MTLSize(width: (maxParticles + 63) / 64, height: 1, depth: 1)
            
            computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
            computeEncoder.endEncoding()
        }
        
 // 渲染粒子
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor), let renderPipelineState {
            renderEncoder.setRenderPipelineState(renderPipelineState)
            renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            
 // 渲染所有粒子（每个粒子是一个四边形，6个顶点）
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: particles.count)
            renderEncoder.endEncoding()
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func updateUniforms(view: MTKView, deltaTime: Float) {
        guard let buffer = uniformBuffer else { return }
        
        let currentTime = Float(CACurrentMediaTime() - startTime)
        
        var uniforms = ParticleUniforms(
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: currentTime,
            deltaTime: deltaTime,
            intensity: intensity,
            tint: tint,
            windStrength: windStrength,
            windDirection: windDirection,
            particleCount: Int32(particles.count),
            globalOpacity: globalOpacity,
            clearZoneCount: Int32(min(currentClearZones.count, maxClearZones))
        )
        
        memcpy(buffer.contents(), &uniforms, MemoryLayout<ParticleUniforms>.stride)
        
 // 更新清除区域
        if let clearBuffer = clearZoneBuffer, !currentClearZones.isEmpty {
            let count = min(currentClearZones.count, maxClearZones)

 // 坐标说明：MouseTrackingNSView 已将 AppKit 坐标翻转为「上原点/y向下」屏幕坐标，
 // 本粒子系统的粒子位置与交互坐标一致，计算着色器直接以像素坐标做距离判断。
 // 因此此处不再进行二次翻转，直接写入中心点即可。
            let dst = clearBuffer.contents().bindMemory(to: ParticleClearZone.self, capacity: count)
            for (i, zone) in currentClearZones.prefix(count).enumerated() {
                dst[i] = ParticleClearZone(center: zone.center, radius: zone.radius, strength: zone.strength)
            }

 // 日志门控与节流：仅在开启详细日志时，并且发生显著变化或超过节流间隔时输出
            if SettingsManager.shared.enableVerboseLogging {
                let now = CACurrentMediaTime()

 // 计算当前zones的轻量级签名：采用标准Hasher，组合关键字段，保证在数据显著变化时刷新日志
                var hasher = Hasher()
                for zone in currentClearZones.prefix(count) {
                    hasher.combine(zone.center.x.bitPattern)
                    hasher.combine(zone.center.y.bitPattern)
                    hasher.combine(zone.radius.bitPattern)
                    hasher.combine(zone.strength.bitPattern)
                }
                let signature = hasher.finalize()

                let shouldLog = (now - lastClearZonesLogTime) >= logThrottleInterval
                    || count != lastLoggedClearZonesCount
                    || signature != lastLoggedClearZonesSignature

                if shouldLog {
                    lastClearZonesLogTime = now
                    lastLoggedClearZonesCount = count
                    lastLoggedClearZonesSignature = signature

 // 使用OSLog记录摘要信息（更高性能、结构化）
                    logger.debug("🌫️ 清除区域数量更新: \(count)")

 // 为便于排查，仅在节流通过时打印详细区域数据
                    for (index, zone) in currentClearZones.prefix(count).enumerated() {
                        logger.debug("区域\(index + 1): 中心(\(zone.center.x), \(zone.center.y)), 半径: \(zone.radius), 强度: \(zone.strength)")
                    }
                }
            }
        } else {
 // 当无清除区域时，仅在开启详细日志且满足节流条件下输出一次
            if SettingsManager.shared.enableVerboseLogging {
                let now = CACurrentMediaTime()
                if (now - lastClearZonesLogTime) >= logThrottleInterval || lastLoggedClearZonesCount != 0 {
                    lastClearZonesLogTime = now
                    lastLoggedClearZonesCount = 0
                    lastLoggedClearZonesSignature = 0
                    logger.debug("🌫️ 当前无清除区域")
                }
            }
        }
    }
}

// MARK: - SwiftUI 包装器

@MainActor
public struct MetalHazeParticleView: NSViewRepresentable {
    public var tint: Color
    public var intensity: Double
    @ObservedObject public var clearManager: InteractiveClearManager
    
    public init(tint: Color, intensity: Double, clearManager: InteractiveClearManager) {
        self.tint = tint
        self.intensity = intensity
        self.clearManager = clearManager
    }
    
    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        let renderer = HazeParticleRenderer(view: view)
        context.coordinator.renderer = renderer
        view.delegate = renderer
        
 // 初始化阶段即同步渲染器配置，并进行点→像素坐标的统一转换
        updateRenderer(renderer, nsView: view)
        return view
    }
    
    public func updateNSView(_ nsView: MTKView, context: Context) {
        if let renderer = context.coordinator.renderer {
 // 🔥 每次视图更新时都更新渲染器，确保状态同步
 // 传入 nsView 以便进行点→像素转换，确保与 GPU 使用的像素坐标一致。
            updateRenderer(renderer, nsView: nsView)
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public final class Coordinator {
        var renderer: HazeParticleRenderer?
    }
    
    private func updateRenderer(_ renderer: HazeParticleRenderer, nsView: MTKView) {
        renderer.intensity = Float(intensity)
        renderer.globalOpacity = Float(clearManager.globalOpacity)
        
 // 转换颜色
        let cgColor = tint.cgColor ?? NSColor(tint).cgColor
        let components = cgColor.components ?? [0.5, 0.56, 0.9, 1.0]
        let r = Float(components.indices.contains(0) ? components[0] : 0.5)
        let g = Float(components.indices.contains(1) ? components[1] : 0.56)
        let b = Float(components.indices.contains(2) ? components[2] : 0.9)
        let a = Float(components.indices.contains(3) ? components[3] : 1.0)
        renderer.tint = SIMD4(r, g, b, a)
        
 // 转换清除区域
 // 坐标与半径统一为像素单位
 // - AppKit事件坐标为“点”（points），而 GPU 的 drawableSize/粒子更新均以“像素”（pixels）为单位。
 // - 因此需要根据内容缩放因子将点坐标/半径转换为像素，避免视网膜屏导致的单位不一致。
 // - 同时保留最小半径保护，避免过小半径使清除效果不可见。
        var zones: [ParticleClearZone] = []
        let minRadiusPixels: Float = 12.0  // 最小半径保护（像素）

 // 计算点→像素缩放因子（通常与 window.backingScaleFactor 一致）
        var scaleX = (nsView.bounds.size.width > 0) ? (nsView.drawableSize.width / nsView.bounds.size.width) : 0.0
        if !scaleX.isFinite || scaleX <= 0 {
            scaleX = Double(nsView.window?.backingScaleFactor ?? 1.0)
        }
        let scale = Float(max(scaleX, 1.0))

        for zone in clearManager.clearZones {
            let centerPixels = SIMD2(
                Float(zone.center.x) * scale,
                Float(zone.center.y) * scale
            )
            let radiusPixels = max(Float(zone.radius) * scale, minRadiusPixels)

            let clearZone = ParticleClearZone(
                center: centerPixels,
                radius: radiusPixels,
                strength: Float(zone.strength)
            )
            zones.append(clearZone)
            if zones.count >= 32 { break }
        }
        renderer.currentClearZones = zones
    }
}
