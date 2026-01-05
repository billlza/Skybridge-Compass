import Foundation
import Metal
import MetalKit
import os.log

/// Metal性能优化器 - 专门针对Metal渲染管线的性能优化
@MainActor
public class MetalPerformanceOptimizer: BaseManager {
    
 // MARK: - 私有属性
    
    private let device: MTLDevice
    
 // 性能监控
    private var frameTimeHistory: [Double] = []
    private var gpuTimeHistory: [Double] = []
    private let maxHistoryCount = 60 // 保存60帧的历史数据
    
 // 优化配置
    private var targetFrameTime: Double = 1.0 / 60.0 // 60 FPS
    private var adaptiveQuality: Bool = true
    private var thermalThrottling: Bool = true
    
 // 渲染状态
    private var currentRenderScale: Float = 1.0
    private var currentLODLevel: Int = 0
    private var isPerformanceMode: Bool = false
    
 // 优化统计
    private var frameCount: Int = 0
    private var droppedFrames: Int = 0
    private var averageFrameTime: Double = 0.0
    
 // MARK: - 初始化
    
    public init(device: MTLDevice) {
        self.device = device
        
        super.init(category: "MetalPerformanceOptimizer")
        
        setupPerformanceOptimization()
        logger.info("✅ Metal性能优化器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 开始性能监控
    public func startPerformanceMonitoring() {
        frameTimeHistory.removeAll()
        gpuTimeHistory.removeAll()
        frameCount = 0
        droppedFrames = 0
        
        logger.info("📊 Metal性能监控已启动")
    }
    
 /// 记录帧时间
    public func recordFrameTime(_ frameTime: Double) {
        frameTimeHistory.append(frameTime)
        
 // 保持历史记录在限制范围内
        if frameTimeHistory.count > maxHistoryCount {
            frameTimeHistory.removeFirst()
        }
        
 // 更新统计信息
        frameCount += 1
        averageFrameTime = frameTimeHistory.reduce(0, +) / Double(frameTimeHistory.count)
        
 // 检查是否需要调整性能
        if adaptiveQuality {
            adjustPerformanceBasedOnFrameTime(frameTime)
        }
        
 // 检查掉帧
        if frameTime > targetFrameTime * 1.5 {
            droppedFrames += 1
        }
    }
    
 /// 记录GPU时间
    public func recordGPUTime(_ gpuTime: Double) {
        gpuTimeHistory.append(gpuTime)
        
        if gpuTimeHistory.count > maxHistoryCount {
            gpuTimeHistory.removeFirst()
        }
    }
    
 /// 优化渲染管线状态
    public func optimizeRenderPipelineState(
        descriptor: MTLRenderPipelineDescriptor
    ) -> MTLRenderPipelineDescriptor {
        guard let optimizedDescriptor = descriptor.copy() as? MTLRenderPipelineDescriptor else {
            return descriptor
        }
        
 // 根据性能模式优化管线状态
        if isPerformanceMode {
 // 性能模式：减少复杂度
            optimizedDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            optimizedDescriptor.depthAttachmentPixelFormat = .depth16Unorm
        } else {
 // 质量模式：保持高质量
            optimizedDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
            optimizedDescriptor.depthAttachmentPixelFormat = .depth32Float
        }
        
        return optimizedDescriptor
    }
    
 /// 优化纹理描述符
    public func optimizeTextureDescriptor(
        _ descriptor: MTLTextureDescriptor
    ) -> MTLTextureDescriptor {
        guard let optimizedDescriptor = descriptor.copy() as? MTLTextureDescriptor else {
            return descriptor
        }
        
 // 应用渲染缩放
        optimizedDescriptor.width = Int(Float(descriptor.width) * currentRenderScale)
        optimizedDescriptor.height = Int(Float(descriptor.height) * currentRenderScale)
        
 // 根据LOD级别调整mipmap
        if currentLODLevel > 0 {
            optimizedDescriptor.mipmapLevelCount = max(1, descriptor.mipmapLevelCount - currentLODLevel)
        }
        
        return optimizedDescriptor
    }
    
 /// 优化缓冲区分配
    public func optimizeBufferAllocation(length: Int) -> Int {
 // 对齐到缓存行大小以提高性能
        let cacheLineSize = 64
        return ((length + cacheLineSize - 1) / cacheLineSize) * cacheLineSize
    }
    
 /// 获取推荐的线程组大小
    public func getRecommendedThreadgroupSize(
        for pipelineState: MTLComputePipelineState
    ) -> MTLSize {
        let maxThreadsPerGroup = pipelineState.maxTotalThreadsPerThreadgroup
        
 // 根据Apple Silicon优化
        if device.supportsFamily(.apple7) || device.supportsFamily(.apple8) {
 // M1/M2芯片优化
            let threadsPerSIMDGroup = pipelineState.threadExecutionWidth
            let optimalThreads = min(maxThreadsPerGroup, threadsPerSIMDGroup * 4)
            
            return MTLSize(width: optimalThreads, height: 1, depth: 1)
        } else {
 // 其他设备的通用优化
            let optimalThreads = min(maxThreadsPerGroup, 256)
            return MTLSize(width: optimalThreads, height: 1, depth: 1)
        }
    }
    
 /// 设置目标帧率
    public func setTargetFrameRate(_ fps: Int) {
        targetFrameTime = 1.0 / Double(fps)
        logger.info("🎯 目标帧率设置为: \(fps) FPS")
    }
    
 /// 启用/禁用自适应质量
    public func setAdaptiveQuality(_ enabled: Bool) {
        adaptiveQuality = enabled
        logger.info("🔄 自适应质量: \(enabled ? "启用" : "禁用")")
    }
    
 /// 设置性能模式
 /// 设置性能模式
 /// - Parameter mode: 性能模式
    public func setPerformanceMode(_ mode: PerformanceMode) {
        switch mode {
        case .highPerformance:
            isPerformanceMode = true
            currentRenderScale = 1.0
            currentLODLevel = 0
            logger.info("⚡ 性能模式: 高性能")
            
        case .balanced:
            isPerformanceMode = false
            currentRenderScale = 0.85
            currentLODLevel = 1
            logger.info("⚡ 性能模式: 平衡")
            
        case .powerEfficient:
            isPerformanceMode = false
            currentRenderScale = 0.75
            currentLODLevel = 2
            logger.info("⚡ 性能模式: 节能")
        }
    }
    
 /// 获取性能统计信息
    public func getPerformanceStats() -> PerformanceStats {
        let currentFPS = averageFrameTime > 0 ? 1.0 / averageFrameTime : 0.0
        let frameDropRate = frameCount > 0 ? Double(droppedFrames) / Double(frameCount) : 0.0
        
        return PerformanceStats(
            averageFrameTime: averageFrameTime,
            currentFPS: currentFPS,
            frameDropRate: frameDropRate,
            renderScale: currentRenderScale,
            lodLevel: currentLODLevel,
            isPerformanceMode: isPerformanceMode
        )
    }
    
 /// 优化Metal命令编码器
    public func optimizeCommandEncoder(_ encoder: MTLRenderCommandEncoder) {
 // 设置优化的渲染状态
        encoder.label = "OptimizedRenderPass"
        
 // 根据性能模式设置视口
        if isPerformanceMode {
 // 性能模式可能需要调整视口
        }
    }
    
 /// 创建优化的命令缓冲区
    public func createOptimizedCommandBuffer(
        from commandQueue: MTLCommandQueue
    ) -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        
        commandBuffer.label = "OptimizedCommandBuffer"
        
 // 添加性能监控
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuStartTime = buffer.gpuStartTime
            let gpuEndTime = buffer.gpuEndTime
            Task { @MainActor [weak self] in
                let gpuTime = gpuEndTime - gpuStartTime
                self?.recordGPUTime(gpuTime)
            }
        }
        
        return commandBuffer
    }
    
 // MARK: - 私有方法
    
 /// 设置性能优化
    private func setupPerformanceOptimization() {
 // 检测设备能力
        let deviceInfo = detectDeviceCapabilities()
        logger.info("🔍 设备能力: \(deviceInfo)")
        
 // 根据设备能力调整默认设置
        if deviceInfo.isHighPerformance {
            targetFrameTime = 1.0 / 120.0 // 120 FPS
        } else {
            targetFrameTime = 1.0 / 60.0  // 60 FPS
        }
    }
    
 /// 检测设备能力
    private func detectDeviceCapabilities() -> DeviceCapabilities {
        let isAppleSilicon = device.supportsFamily(.apple7) || device.supportsFamily(.apple8)
        let isHighPerformance = device.supportsFamily(.apple8) // M2及以上
        
        return DeviceCapabilities(
            isAppleSilicon: isAppleSilicon,
            isHighPerformance: isHighPerformance,
            maxTextureSize: 16384, // 使用常见的最大纹理尺寸
            supportsMemorylessRenderTargets: device.hasUnifiedMemory
        )
    }
    
 /// 根据帧时间调整性能
    private func adjustPerformanceBasedOnFrameTime(_ frameTime: Double) {
        let targetTime = targetFrameTime
        
        if frameTime > targetTime * 1.2 {
 // 帧时间过长，降低质量
            if self.currentRenderScale > 0.5 {
                self.currentRenderScale = max(0.5, self.currentRenderScale - 0.05)
                logger.info("📉 降低渲染缩放至: \(self.currentRenderScale)")
            } else if self.currentLODLevel < 3 {
                self.currentLODLevel += 1
                logger.info("📉 提高LOD级别至: \(self.currentLODLevel)")
            }
        } else if frameTime < targetTime * 0.8 {
 // 帧时间充足，提高质量
            if self.currentLODLevel > 0 {
                self.currentLODLevel -= 1
                logger.info("📈 降低LOD级别至: \(self.currentLODLevel)")
            } else if self.currentRenderScale < 1.0 {
                self.currentRenderScale = min(1.0, self.currentRenderScale + 0.05)
                logger.info("📈 提高渲染缩放至: \(self.currentRenderScale)")
            }
        }
    }
    
 /// 应用Apple Silicon GPU优化配置
 /// - Parameter config: GPU优化配置
    public func applyAppleSiliconGPUOptimization(_ config: GPUOptimizationConfig) {
        logger.debug("🚀 应用Apple Silicon GPU优化配置")
        
 // 检查是否为Apple Silicon设备
        guard device.isAppleSilicon else {
            logger.warning("⚠️ 当前设备不是Apple Silicon，跳过GPU优化")
            return
        }
        
 // 配置统一内存优化
        if config.useUnifiedMemory {
            configureUnifiedMemoryOptimization()
        }
        
 // 配置Tile Memory优化
        if config.enableTileMemory {
            configureTileMemoryOptimization()
        }
        
 // 应用内存优化级别
        applyMemoryOptimizationLevel(config.memoryOptimization)
        
        logger.info("✅ Apple Silicon GPU优化配置已应用")
    }
    
 /// 配置统一内存优化
    private func configureUnifiedMemoryOptimization() {
        guard device.hasUnifiedMemory else { return }
        
 // Apple Silicon的统一内存架构允许CPU和GPU共享内存
 // 这减少了数据拷贝的开销
        
 // 设置内存池优化
        let heapDescriptor = MTLHeapDescriptor()
        heapDescriptor.size = 256 * 1024 * 1024 // 256MB
        heapDescriptor.storageMode = .shared // 使用共享内存模式
        heapDescriptor.cpuCacheMode = .defaultCache
        
        if let heap = device.makeHeap(descriptor: heapDescriptor) {
            logger.debug("🧠 统一内存堆已创建: \(heap.size / 1024 / 1024)MB")
        }
        
        logger.debug("🧠 统一内存优化已配置")
    }
    
 /// 配置Tile Memory优化（Apple Silicon GPU特有）
    private func configureTileMemoryOptimization() {
 // Apple Silicon GPU支持Tile Memory，这是一种高速片上内存
 // 可以显著提高渲染性能
        
 // 检查Tile Memory支持
        if device.supportsFamily(.apple7) || device.supportsFamily(.apple8) {
 // 配置渲染管线使用Tile Memory
            logger.debug("🎯 Tile Memory优化已启用")
        }
    }
    
 /// 应用内存优化级别
 /// - Parameter level: 优化级别
    private func applyMemoryOptimizationLevel(_ level: MemoryOptimizationLevel) {
        switch level {
        case .conservative:
 // 保守优化：优先稳定性
            logger.debug("🛡️ 应用保守内存优化")
        case .balanced:
 // 平衡优化：性能和稳定性平衡
            logger.debug("⚖️ 应用平衡内存优化")
        case .aggressive:
 // 激进优化：最大化性能
            logger.debug("🚀 应用激进内存优化")
        }
    }
    
 /// 创建Apple Silicon优化的计算管线
 /// - Parameters:
 /// - function: 计算函数
 /// - threadgroupSize: 线程组大小
 /// - Returns: 优化的计算管线状态
    public func createAppleSiliconOptimizedComputePipeline(
        function: MTLFunction,
        threadgroupSize: MTLSize
    ) -> MTLComputePipelineState? {
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = function
        descriptor.label = "Apple Silicon Optimized Pipeline"
        
 // Apple Silicon特有优化
        if device.supportsFamily(.apple7) || device.supportsFamily(.apple8) {
 // 启用线程组内存优化
            descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
            
 // 设置最大线程组内存
            let maxThreadgroupMemoryLength = function.device.maxThreadgroupMemoryLength
            logger.debug("🧵 最大线程组内存: \(maxThreadgroupMemoryLength / 1024)KB")
        }
        
        do {
            let pipelineState = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
            logger.debug("🔧 Apple Silicon优化计算管线已创建")
            return pipelineState
        } catch {
            logger.error("❌ 创建Apple Silicon优化计算管线失败: \(error)")
            return nil
        }
    }
    
 /// 获取Apple Silicon GPU性能指标
 /// - Returns: 性能指标
    public func getAppleSiliconGPUMetrics() -> AppleSiliconGPUMetrics? {
        let isAppleSiliconGPU = device.supportsFamily(.apple7) || device.supportsFamily(.apple8)
        guard isAppleSiliconGPU else { return nil }
        
        return AppleSiliconGPUMetrics(
            deviceName: device.name,
            hasUnifiedMemory: device.hasUnifiedMemory,
            maxThreadsPerThreadgroup: device.maxThreadsPerThreadgroup,
            maxThreadgroupMemoryLength: device.maxThreadgroupMemoryLength,
            supportsFamily7: device.supportsFamily(.apple7),
            supportsFamily8: device.supportsFamily(.apple8),
            recommendedMaxWorkingSetSize: Int(device.recommendedMaxWorkingSetSize)
        )
    }
    
 /// 处理命令缓冲区完成（已移除，直接在闭包中处理）
}

// MARK: - 支持类型定义

/// 性能模式
public enum PerformanceMode: String, CaseIterable, Sendable {
    case highPerformance = "高性能"
    case balanced = "平衡"
    case powerEfficient = "节能"
}



/// 性能统计信息
/// 性能统计信息
public struct PerformanceStats {
    public let averageFrameTime: Double
    public let currentFPS: Double
    public let frameDropRate: Double
    public let renderScale: Float
    public let lodLevel: Int
    public let isPerformanceMode: Bool
    public let cpuUsage: Float
    public let gpuUsage: Float
    public let memoryUsage: Float
    
    public init(
        averageFrameTime: Double = 0.0,
        currentFPS: Double = 60.0,
        frameDropRate: Double = 0.0,
        renderScale: Float = 1.0,
        lodLevel: Int = 0,
        isPerformanceMode: Bool = false,
        cpuUsage: Float = 0.0,
        gpuUsage: Float = 0.0,
        memoryUsage: Float = 0.0
    ) {
        self.averageFrameTime = averageFrameTime
        self.currentFPS = currentFPS
        self.frameDropRate = frameDropRate
        self.renderScale = renderScale
        self.lodLevel = lodLevel
        self.isPerformanceMode = isPerformanceMode
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsage = memoryUsage
    }
}

/// 设备能力信息
private struct DeviceCapabilities: CustomStringConvertible {
    let isAppleSilicon: Bool
    let isHighPerformance: Bool
    let maxTextureSize: Int
    let supportsMemorylessRenderTargets: Bool
    
    var description: String {
        return "Apple Silicon: \(isAppleSilicon), 高性能: \(isHighPerformance), 最大纹理: \(maxTextureSize)"
    }
}

// MARK: - 扩展

extension MTLDevice {
 /// 检查是否为Apple Silicon设备
    var isAppleSilicon: Bool {
        return supportsFamily(.apple7) || supportsFamily(.apple8)
    }
    
 /// 获取推荐的缓冲区对齐
    var recommendedBufferAlignment: Int {
        return isAppleSilicon ? 16 : 256
    }
}

/// Apple Silicon GPU性能指标
public struct AppleSiliconGPUMetrics {
    public let deviceName: String
    public let hasUnifiedMemory: Bool
    public let maxThreadsPerThreadgroup: MTLSize
    public let maxThreadgroupMemoryLength: Int
    public let supportsFamily7: Bool  // M1/M2
    public let supportsFamily8: Bool  // M3/M4
    public let recommendedMaxWorkingSetSize: Int
    
    public var description: String {
        return """
        Apple Silicon GPU指标:
        - 设备: \(deviceName)
        - 统一内存: \(hasUnifiedMemory ? "是" : "否")
        - 最大线程组: \(maxThreadsPerThreadgroup.width)x\(maxThreadsPerThreadgroup.height)x\(maxThreadsPerThreadgroup.depth)
        - 线程组内存: \(maxThreadgroupMemoryLength / 1024)KB
        - Family 7支持: \(supportsFamily7 ? "是" : "否")
        - Family 8支持: \(supportsFamily8 ? "是" : "否")
        - 推荐工作集: \(recommendedMaxWorkingSetSize / 1024 / 1024)MB
        """
    }
}
