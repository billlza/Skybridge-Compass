//
// MetalPerformanceOptimizer.swift
// SkyBridgeCompassApp
//
// Metal 性能优化器
// 专门优化 GPU 渲染和计算性能
//

import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import OSLog

/// Metal 性能优化器 - 专门优化 GPU 渲染和计算性能
@available(macOS 14.0, *)
@MainActor
public final class MetalPerformanceOptimizer: Sendable {
    
 // MARK: - 属性
    
 /// 日志记录器
    private let logger = Logger(subsystem: "SkyBridgeCompassApp", category: "MetalPerformanceOptimizer")
    
 /// Metal 设备
    private let device: MTLDevice?
    
 /// 命令队列
    private let commandQueue: MTLCommandQueue?
    
 /// 渲染管线状态缓存
    private var pipelineStateCache: [String: MTLRenderPipelineState] = [:]
    
 /// 计算管线状态缓存
    private var computePipelineCache: [String: MTLComputePipelineState] = [:]
    
 /// 缓冲区池
    private let bufferPool: MetalBufferPool?
    
 /// 纹理池
    private let texturePool: MetalTexturePool?
    
 /// 性能统计
    private var performanceStats: MetalPerformanceStats = MetalPerformanceStats()
    
 /// 单例实例
    public static let shared: MetalPerformanceOptimizer = {
        do {
            return try MetalPerformanceOptimizer()
        } catch {
            #if os(macOS)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Metal 性能优化器初始化失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
            #endif
            return MetalPerformanceOptimizer.fallback()
        }
    }()
    
 // MARK: - 初始化
    
 /// 初始化 Metal 性能优化器
    public init() throws {
 // 获取 Metal 设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalPerformanceOptimizerError.deviceNotAvailable
        }
        self.device = device
        
 // 创建命令队列
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalPerformanceOptimizerError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
 // 初始化缓冲区池和纹理池
        self.bufferPool = MetalBufferPool(device: device)
        self.texturePool = MetalTexturePool(device: device)
        
        logger.info("Metal 性能优化器初始化完成 - 设备: \(device.name)")
    }
    
    private init(fallback: Void) {
        self.device = nil
        self.commandQueue = nil
        self.bufferPool = nil
        self.texturePool = nil
        self.performanceStats = MetalPerformanceStats()
    }
    
    public static func fallback() -> MetalPerformanceOptimizer {
        return MetalPerformanceOptimizer(fallback: ())
    }
    
 // MARK: - 公共方法
    
 /// 优化渲染管线
    public func optimizeRenderPipeline(descriptor: MTLRenderPipelineDescriptor, key: String) throws -> MTLRenderPipelineState {
 // 检查缓存
        if let cachedState = pipelineStateCache[key] {
            performanceStats.pipelineCacheHits += 1
            return cachedState
        }
        
 // 应用优化配置
        optimizeRenderPipelineDescriptor(descriptor)
        
 // 创建管线状态
        guard let device = device else { throw MetalPerformanceOptimizerError.deviceNotAvailable }
        let pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        
 // 缓存管线状态
        pipelineStateCache[key] = pipelineState
        performanceStats.pipelineCacheMisses += 1
        
        logger.debug("创建并缓存渲染管线状态: \(key)")
        return pipelineState
    }
    
 /// 优化计算管线
    public func optimizeComputePipeline(function: MTLFunction, key: String) throws -> MTLComputePipelineState {
 // 检查缓存
        if let cachedState = computePipelineCache[key] {
            performanceStats.pipelineCacheHits += 1
            return cachedState
        }
        
 // 创建计算管线状态
        guard let device = device else { throw MetalPerformanceOptimizerError.deviceNotAvailable }
        let pipelineState = try device.makeComputePipelineState(function: function)
        
 // 缓存管线状态
        computePipelineCache[key] = pipelineState
        performanceStats.pipelineCacheMisses += 1
        
        logger.debug("创建并缓存计算管线状态: \(key)")
        return pipelineState
    }
    
 /// 获取优化的缓冲区
    public func getOptimizedBuffer(length: Int, options: MTLResourceOptions = []) -> MTLBuffer? {
        return bufferPool?.getBuffer(length: length, options: options)
    }
    
 /// 获取优化的纹理
    public func getOptimizedTexture(descriptor: MTLTextureDescriptor) -> MTLTexture? {
        return texturePool?.getTexture(descriptor: descriptor)
    }
    
 /// 回收缓冲区
    public func recycleBuffer(_ buffer: MTLBuffer) {
        bufferPool?.recycleBuffer(buffer)
    }
    
 /// 回收纹理
    public func recycleTexture(_ texture: MTLTexture) {
        texturePool?.recycleTexture(texture)
    }
    
 /// 优化命令缓冲区
    public func optimizeCommandBuffer() -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
            return nil
        }
        
 // 设置标签以便调试
        commandBuffer.label = "OptimizedCommandBuffer"
        
        return commandBuffer
    }
    
 /// 获取性能统计
    public func getPerformanceStats() -> MetalPerformanceStats {
        return performanceStats
    }
    
 /// 清理缓存
    public func clearCaches() {
        pipelineStateCache.removeAll()
        computePipelineCache.removeAll()
        bufferPool?.clearPool()
        texturePool?.clearPool()
        
        logger.info("Metal 缓存已清理")
    }
    
 // MARK: - 私有方法
    
 /// 优化渲染管线描述符
    private func optimizeRenderPipelineDescriptor(_ descriptor: MTLRenderPipelineDescriptor) {
 // 优化颜色附件
        if let colorAttachment = descriptor.colorAttachments[0] {
 // 如果不需要混合，禁用混合以提高性能
            if !colorAttachment.isBlendingEnabled {
                colorAttachment.writeMask = MTLColorWriteMask.all
            }
        }
        
 // 设置光栅化状态优化
        descriptor.rasterSampleCount = 1 // 默认不使用多重采样
        
        logger.debug("渲染管线描述符已优化")
    }
}

// MARK: - Metal 缓冲区池

/// Metal 缓冲区池 - 管理和重用缓冲区以减少内存分配
public final class MetalBufferPool {
    private let device: MTLDevice
    private var bufferPool: [Int: [MTLBuffer]] = [:]
    private let poolLock = NSLock()
    
    public init(device: MTLDevice) {
        self.device = device
    }
    
 /// 获取缓冲区
    public func getBuffer(length: Int, options: MTLResourceOptions = []) -> MTLBuffer? {
        poolLock.lock()
        defer { poolLock.unlock() }
        
 // 尝试从池中获取现有缓冲区
        if var buffers = bufferPool[length], !buffers.isEmpty {
            let buffer = buffers.removeLast()
            bufferPool[length] = buffers
            return buffer
        }
        
 // 创建新缓冲区
        return device.makeBuffer(length: length, options: options)
    }
    
 /// 回收缓冲区
    public func recycleBuffer(_ buffer: MTLBuffer) {
        poolLock.lock()
        defer { poolLock.unlock() }
        
        let length = buffer.length
        if bufferPool[length] == nil {
            bufferPool[length] = []
        }
        
 // 限制池大小以避免内存过度使用
        if bufferPool[length]!.count < 10 {
            bufferPool[length]!.append(buffer)
        }
    }
    
 /// 清理池
    public func clearPool() {
        poolLock.lock()
        defer { poolLock.unlock() }
        
        bufferPool.removeAll()
    }
}

// MARK: - Metal 纹理池

/// Metal 纹理池 - 管理和重用纹理以减少内存分配
public final class MetalTexturePool {
    private let device: MTLDevice
    private var texturePool: [String: [MTLTexture]] = [:]
    private let poolLock = NSLock()
    
    public init(device: MTLDevice) {
        self.device = device
    }
    
 /// 获取纹理
    public func getTexture(descriptor: MTLTextureDescriptor) -> MTLTexture? {
        let key = textureDescriptorKey(descriptor)
        
        poolLock.lock()
        defer { poolLock.unlock() }
        
 // 尝试从池中获取现有纹理
        if var textures = texturePool[key], !textures.isEmpty {
            let texture = textures.removeLast()
            texturePool[key] = textures
            return texture
        }
        
 // 创建新纹理
        return device.makeTexture(descriptor: descriptor)
    }
    
 /// 回收纹理
    public func recycleTexture(_ texture: MTLTexture) {
        let key = textureKey(texture)
        
        poolLock.lock()
        defer { poolLock.unlock() }
        
        if texturePool[key] == nil {
            texturePool[key] = []
        }
        
 // 限制池大小以避免内存过度使用
        if texturePool[key]!.count < 5 {
            texturePool[key]!.append(texture)
        }
    }
    
 /// 清理池
    public func clearPool() {
        poolLock.lock()
        defer { poolLock.unlock() }
        
        texturePool.removeAll()
    }
    
 /// 生成纹理描述符的键
    private func textureDescriptorKey(_ descriptor: MTLTextureDescriptor) -> String {
        return "\(descriptor.width)x\(descriptor.height)x\(descriptor.depth)_\(descriptor.pixelFormat.rawValue)_\(descriptor.textureType.rawValue)"
    }
    
 /// 生成纹理的键
    private func textureKey(_ texture: MTLTexture) -> String {
        return "\(texture.width)x\(texture.height)x\(texture.depth)_\(texture.pixelFormat.rawValue)_\(texture.textureType.rawValue)"
    }
}

// MARK: - 数据结构

/// Metal 性能统计
public struct MetalPerformanceStats: Sendable {
    public var pipelineCacheHits: Int = 0
    public var pipelineCacheMisses: Int = 0
    public var buffersAllocated: Int = 0
    public var buffersRecycled: Int = 0
    public var texturesAllocated: Int = 0
    public var texturesRecycled: Int = 0
    
 /// 缓存命中率
    public var cacheHitRate: Double {
        let total = pipelineCacheHits + pipelineCacheMisses
        return total > 0 ? Double(pipelineCacheHits) / Double(total) : 0.0
    }
}

// MARK: - 错误类型

/// Metal 性能优化器错误
public enum MetalPerformanceOptimizerError: Error, LocalizedError {
    case deviceNotAvailable
    case commandQueueCreationFailed
    case pipelineCreationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "Metal 设备不可用"
        case .commandQueueCreationFailed:
            return "命令队列创建失败"
        case .pipelineCreationFailed(let reason):
            return "管线创建失败: \(reason)"
        }
    }
}
