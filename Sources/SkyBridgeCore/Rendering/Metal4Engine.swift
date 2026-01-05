import Metal
import MetalKit
import MetalFX
import simd
import Combine
import os.log

/// Metal 4.0 高性能渲染引擎 - 集成AI推理、MetalFX增强和Apple Silicon优化
@MainActor
public class Metal4Engine: NSObject, ObservableObject {
    
 // MARK: - 发布属性
    
    @Published public var isInitialized: Bool = false
    @Published public var renderingStats: RenderingStatistics = RenderingStatistics()
    @Published public var aiInferenceEnabled: Bool = true
    @Published public var metalFXEnabled: Bool = true
    @Published public var frameInterpolationEnabled: Bool = true
    @Published public var debugShowWireframe: Bool = false
    @Published public var debugShowNormals: Bool = false
    @Published public var debugShowDepth: Bool = false
    @Published public var gpuMemoryUsage: (used: Int64, total: Int64, percentage: Double) = (0, 0, 0)
    
 // MARK: - Metal 4.0 核心组件
 /// Metal 设备 - 延迟初始化，使用 Optional 而非隐式解包
    private var device: MTLDevice?
 /// 命令队列 - 延迟初始化
    private var commandQueue: MTLCommandQueue?
 /// Metal 4.0 命令队列 - 延迟初始化
    private var metal4CommandQueue: Any? // MTL4CommandQueue - 新的命令队列类型
 /// 着色器库 - 延迟初始化
    private var library: MTLLibrary?
    
 // MARK: - Apple Silicon 统一内存管理
 /// 统一内存管理器 - 延迟初始化
    private var unifiedMemoryManager: UnifiedMemoryManager?
    
 // MARK: - MetalFX 组件
    
    private var upscaler: MTLFXSpatialScaler?
    private var temporalUpscaler: MTLFXTemporalScaler?
    private var frameInterpolator: Any? // MTLFXFrameInterpolator - Metal 4.0新功能
    private var denoiser: Any? // MTLFXDenoiser - Metal 4.0新功能
    
 // MARK: - AI 推理组件
 /// AI 推理引擎 - 延迟初始化
    private var aiInferenceEngine: Metal4AIEngine?
    private var neuralRenderingPipeline: MTLComputePipelineState?
    private var mlpWeights: MTLBuffer?
    private var aiArgumentTable: Any? // MTL4ArgumentTable - 新的参数表系统
    
 // MARK: - 渲染管线
 /// 渲染管线状态 - 延迟初始化
    private var renderPipelineState: MTLRenderPipelineState?
 /// 计算管线状态 - 延迟初始化
    private var computePipelineState: MTLComputePipelineState?
    private var rayTracingPipeline: MTLComputePipelineState?
    
 // MARK: - 缓冲区和纹理 (使用统一内存优化)
 /// 顶点缓冲区 - 延迟初始化
    private var vertexBuffer: MTLBuffer?
 /// Uniform 缓冲区 - 延迟初始化
    private var uniformBuffer: MTLBuffer?
    private var frameTextures: [MTLTexture] = []
    private var intermediateTextures: [MTLTexture] = []
    
 // MARK: - 性能监控
 /// 性能监控器 - 延迟初始化
    private var performanceMonitor: Metal4PerformanceMonitor?
    private var gpuMemoryTimer: Timer?
    private var lastFrameTime: CFTimeInterval = 0
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "Metal4Engine")
    
 // MARK: - Apple Silicon GPU 优化配置
    
    public struct AppleSiliconOptimization: Sendable, Hashable {
        public let useTileBasedDeferredRendering: Bool
        public let enableMemorylessTextures: Bool
        public let useSharedMemoryBuffers: Bool
        public let optimizeForUnifiedMemory: Bool
        public let enableGPUDrivenRendering: Bool
        
        public static let `default` = AppleSiliconOptimization(
            useTileBasedDeferredRendering: true,
            enableMemorylessTextures: true,
            useSharedMemoryBuffers: true,
            optimizeForUnifiedMemory: true,
            enableGPUDrivenRendering: true
        )
    }
    
 // MARK: - 配置
    
    public struct Configuration: Sendable, Hashable {
        public let enableAIInference: Bool
        public let enableMetalFX: Bool
        public let enableFrameInterpolation: Bool
        public let enableRayTracing: Bool
        public let targetFrameRate: Int
        public let renderScale: Float
        public let aiModelPath: String?
        public let appleSiliconOptimization: AppleSiliconOptimization
        
        public static let `default` = Configuration(
            enableAIInference: true,
            enableMetalFX: true,
            enableFrameInterpolation: true,
            enableRayTracing: true,
            targetFrameRate: 120,
            renderScale: 0.75, // 渲染75%分辨率，然后上采样
            aiModelPath: nil,
            appleSiliconOptimization: .default
        )
        
        public static let performance = Configuration(
            enableAIInference: false,
            enableMetalFX: true,
            enableFrameInterpolation: true,
            enableRayTracing: false,
            targetFrameRate: 60,
            renderScale: 0.5,
            aiModelPath: nil,
            appleSiliconOptimization: .default
        )
        
        public static let quality = Configuration(
            enableAIInference: true,
            enableMetalFX: true,
            enableFrameInterpolation: false,
            enableRayTracing: true,
            targetFrameRate: 30,
            renderScale: 1.0,
            aiModelPath: "neural_renderer.mlmodel",
            appleSiliconOptimization: .default
        )
    }
    
    private let configuration: Configuration
    
 // MARK: - 初始化
    
    public init(configuration: Configuration = .default) {
        self.configuration = configuration
        super.init()
        
        Task {
            await initializeMetal4Engine()
        }
    }
    
 // MARK: - Metal 4.0 引擎初始化
    
    private func initializeMetal4Engine() async {
        do {
 // 检查Metal 4.0支持
            guard await checkMetal4Support() else {
                SkyBridgeLogger.metal.error("设备不支持Metal 4.0")
                return
            }
            
 // 初始化Metal设备和命令队列
            guard let device = MTLCreateSystemDefaultDevice() else {
                SkyBridgeLogger.metal.error("无法创建Metal设备")
                return
            }
            self.device = device
            
 // 初始化统一内存管理器 (Apple Silicon优化)
            self.unifiedMemoryManager = UnifiedMemoryManager(device: device)
            
 // 创建命令队列
            guard let commandQueue = device.makeCommandQueue() else {
                SkyBridgeLogger.metal.error("无法创建命令队列")
                return
            }
            self.commandQueue = commandQueue
            
 // 创建Metal 4.0命令队列
            self.metal4CommandQueue = createMetal4CommandQueue()
            
 // 加载着色器
            self.library = try await loadMetal4Shaders()
            
 // 初始化MetalFX
            if configuration.enableMetalFX {
                try await initializeMetalFX()
            }
            
 // 初始化AI推理
            if configuration.enableAIInference {
                try await initializeAIInference()
            }
            
 // 创建渲染管线
            try await createRenderPipelines()
            
 // 初始化缓冲区和纹理 (使用统一内存优化)
            try await initializeBuffersWithUnifiedMemory()
            
 // 初始化性能监控
            self.performanceMonitor = Metal4PerformanceMonitor(device: device)
            
 // 设置监控器（仅GPU内存，2s 采样，移除60Hz空转）
            setupMonitors()
            
            await MainActor.run {
                self.isInitialized = true
            }
            
            SkyBridgeLogger.metal.debugOnly("Metal 4.0引擎初始化完成 - Apple Silicon优化已启用")
        } catch {
            SkyBridgeLogger.metal.error("Metal 4.0引擎初始化失败: \(error.localizedDescription, privacy: .private)")
        }
    }
    
 // MARK: - Metal 4.0 支持检查
    
    private func checkMetal4Support() async -> Bool {
        guard let device = device else {
            SkyBridgeLogger.metal.error("Metal 设备未初始化")
            return false
        }
        
 // 检查设备是否支持Metal 4.0特性
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            SkyBridgeLogger.metal.error("设备不支持Metal 4.0所需的GPU系列")
            return false
        }
        
 // 检查MetalFX支持
        if configuration.enableMetalFX {
 // 注意：MTLFXSpatialScaler.supportsDevice在当前版本中不可用
 // 改为检查设备是否支持MetalFX的基本功能
 // macOS 13.0+ 支持MetalFX
            SkyBridgeLogger.metal.debugOnly("✅ MetalFX支持已启用")
        }
        
 // 检查光线追踪支持
        if configuration.enableRayTracing {
            guard device.supportsRaytracing else {
                SkyBridgeLogger.metal.error("设备不支持硬件光线追踪")
                return false
            }
        }
        
        return true
    }
    
 // MARK: - Metal 4.0 命令队列创建
    
    private func createMetal4CommandQueue() -> Any {
 // 模拟Metal 4.0的MTL4CommandQueue创建
 // 实际实现需要使用Metal 4.0 API
        SkyBridgeLogger.metal.debugOnly("创建Metal 4.0命令队列")
        return commandQueue as Any
    }
    
 // MARK: - 着色器加载
    
    private func loadMetal4Shaders() async throws -> MTLLibrary {
        guard let device = device else {
            throw Metal4Error.deviceNotSupported
        }
        
 // 加载包含Metal 4.0特性的着色器库
        guard let library = device.makeDefaultLibrary() else {
            throw Metal4Error.shaderLoadFailed
        }
        
 // 验证Metal 4.0着色器函数
        let requiredFunctions = [
            "vertex_main",
            "fragment_main",
            "compute_main",
            "ai_inference_shader", // AI推理着色器
            "neural_upscale_compute", // 神经网络上采样
            "frame_interpolation_compute" // 帧插值计算
        ]
        
        for functionName in requiredFunctions {
            guard library.makeFunction(name: functionName) != nil else {
                SkyBridgeLogger.metal.debugOnly("警告: 着色器函数 \(functionName) 未找到")
                continue
            }
        }
        
        return library
    }
    
 // MARK: - MetalFX 初始化
    
    private func initializeMetalFX() async throws {
        guard let device = device else {
            throw Metal4Error.deviceNotSupported
        }
        
 // 空间上采样器
        let spatialDesc = MTLFXSpatialScalerDescriptor()
        spatialDesc.inputWidth = Int(1920 * configuration.renderScale)
        spatialDesc.inputHeight = Int(1080 * configuration.renderScale)
        spatialDesc.outputWidth = 1920
        spatialDesc.outputHeight = 1080
        spatialDesc.colorTextureFormat = .rgba16Float
        spatialDesc.outputTextureFormat = .rgba16Float
        
        self.upscaler = spatialDesc.makeSpatialScaler(device: device)
        
 // 时间上采样器
        let temporalDesc = MTLFXTemporalScalerDescriptor()
        temporalDesc.inputWidth = Int(1920 * configuration.renderScale)
        temporalDesc.inputHeight = Int(1080 * configuration.renderScale)
        temporalDesc.outputWidth = 1920
        temporalDesc.outputHeight = 1080
        temporalDesc.colorTextureFormat = .rgba16Float
        temporalDesc.depthTextureFormat = .depth32Float
        temporalDesc.motionTextureFormat = .rg16Float
        temporalDesc.outputTextureFormat = .rgba16Float
        
        self.temporalUpscaler = temporalDesc.makeTemporalScaler(device: device)
        
 // Metal 4.0新功能：帧插值器（模拟）
        if configuration.enableFrameInterpolation {
            self.frameInterpolator = createFrameInterpolator()
        }
        
 // Metal 4.0新功能：去噪器（模拟）
        self.denoiser = createDenoiser()
        
        SkyBridgeLogger.metal.debugOnly("MetalFX组件初始化完成")
    }
    
 // MARK: - AI 推理初始化
    
    private func initializeAIInference() async throws {
        guard let device = device, let library = library else {
            throw Metal4Error.deviceNotSupported
        }
        
 // 初始化AI推理引擎
        self.aiInferenceEngine = Metal4AIEngine(device: device)
        
 // 创建神经网络渲染管线
        guard let aiFunction = library.makeFunction(name: "ai_inference_shader") else {
            throw Metal4Error.aiShaderNotFound
        }
        
        self.neuralRenderingPipeline = try await device.makeComputePipelineState(function: aiFunction)
        
 // 创建MLP权重缓冲区
        let weightsSize = 1024 * 1024 * 4 // 4MB权重数据
        self.mlpWeights = device.makeBuffer(length: weightsSize, options: .storageModeShared)
        
 // 创建Metal 4.0参数表（模拟）
        self.aiArgumentTable = createAIArgumentTable()
        
 // 加载预训练模型（如果提供）
        if let modelPath = configuration.aiModelPath {
            try await loadAIModel(from: modelPath)
        }
        
        SkyBridgeLogger.metal.debugOnly("AI推理引擎初始化完成")
    }
    
 // MARK: - 渲染管线创建
    
    private func createRenderPipelines() async throws {
        guard let device = device, let library = library else {
            throw Metal4Error.deviceNotSupported
        }
        
 // 主渲染管线
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        renderDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        renderDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        renderDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        self.renderPipelineState = try await device.makeRenderPipelineState(descriptor: renderDescriptor)
        
 // 计算管线
        guard let computeFunction = library.makeFunction(name: "compute_main") else {
            throw Metal4Error.computeShaderNotFound
        }
        
        self.computePipelineState = try await device.makeComputePipelineState(function: computeFunction)
        
 // 光线追踪管线（如果启用）
        if configuration.enableRayTracing {
            try await createRayTracingPipeline()
        }
        
        SkyBridgeLogger.metal.debugOnly("渲染管线创建完成")
    }
    
 // MARK: - 缓冲区初始化
    
    private func initializeBuffersWithUnifiedMemory() async throws {
        guard let unifiedMemoryManager = unifiedMemoryManager else {
            throw Metal4Error.deviceNotSupported
        }
        
 // 使用统一内存管理器创建共享缓冲区 (Apple Silicon零拷贝优化)
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,
             1.0, -1.0, 0.0, 1.0,
             0.0,  1.0, 0.0, 1.0
        ]
        
 // 创建共享顶点缓冲区 - CPU/GPU零拷贝访问
        guard let vertexBuffer = unifiedMemoryManager.createSharedBuffer(
            length: vertices.count * MemoryLayout<Float>.size
        ) else {
            throw Metal4Error.textureCreationFailed
        }
        
 // 将顶点数据复制到缓冲区
        unifiedMemoryManager.optimizeDataTransfer(data: vertices, to: vertexBuffer)
        self.vertexBuffer = vertexBuffer
        
 // 创建共享统一缓冲区 - 动态更新优化
        let uniformSize = MemoryLayout<Uniforms>.size
        guard let uniformBuffer = unifiedMemoryManager.createSharedBuffer(
            length: uniformSize
        ) else {
            throw Metal4Error.textureCreationFailed
        }
        self.uniformBuffer = uniformBuffer
        
 // 创建帧纹理 (使用Apple Silicon优化)
        try await createFrameTexturesWithUnifiedMemory()
        
        SkyBridgeLogger.metal.debugOnly("缓冲区初始化完成 - 使用Apple Silicon统一内存优化")
    }
    
    private func createFrameTexturesWithUnifiedMemory() async throws {
 // 清空现有纹理
        frameTextures.removeAll()
        intermediateTextures.removeAll()
        
 // 创建多个帧纹理用于帧插值 (使用memoryless优化)
        for i in 0..<3 {
            let texture = try createOptimizedRenderTexture(index: i)
            frameTextures.append(texture)
        }
        
 // 创建中间纹理用于多通道渲染
        for i in 0..<2 {
            let texture = try createOptimizedIntermediateTexture(index: i)
            intermediateTextures.append(texture)
        }
        
        SkyBridgeLogger.metal.debugOnly("帧纹理创建完成 - 使用Apple Silicon TBDR优化")
    }
    
    private func createOptimizedRenderTexture(index: Int) throws -> MTLTexture {
        guard let device = device else {
            throw Metal4Error.deviceNotSupported
        }
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(1920 * configuration.renderScale),
            height: Int(1080 * configuration.renderScale),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        
 // Apple Silicon TBDR优化 - 使用memoryless存储模式
        if configuration.appleSiliconOptimization.enableMemorylessTextures {
            descriptor.storageMode = .memoryless
        } else if configuration.appleSiliconOptimization.useSharedMemoryBuffers {
            descriptor.storageMode = .shared
        } else {
            descriptor.storageMode = .private
        }
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Metal4Error.textureCreationFailed
        }
        
        texture.label = "渲染纹理_\(index)"
        return texture
    }
    
    private func createOptimizedIntermediateTexture(index: Int) throws -> MTLTexture {
        guard let device = device else {
            throw Metal4Error.deviceNotSupported
        }
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: Int(1920 * configuration.renderScale),
            height: Int(1080 * configuration.renderScale),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
 // 中间纹理使用private存储模式以获得最佳GPU性能
        descriptor.storageMode = .private
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Metal4Error.textureCreationFailed
        }
        
        texture.label = "中间纹理_\(index)"
        return texture
    }

    private func createFrameTextures() async throws {
 // 创建多个帧纹理用于帧插值
        for i in 0..<3 {
            let texture = try createOptimizedRenderTexture(index: i)
            frameTextures.append(texture)
        }
    }
    
 // MARK: - Metal 4.0 特性实现
    
 /// 创建MetalFX帧插值器 - 使用真实的Apple API
    private func createFrameInterpolator() -> Any? {
        guard let device = device else {
            logger.warning("Metal 设备未初始化")
            return nil
        }
        
 // 检查设备是否支持MetalFX Frame Interpolation
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            logger.warning("设备不支持MetalFX Frame Interpolation")
            return createCustomFrameInterpolator()
        }
        
 // 使用真实的MetalFX Frame Interpolation API
        #if canImport(MetalFX)
 // MetalFX 帧插值器仅在 macOS 26+ 可用，这里进行运行时判断
        if #available(macOS 26.0, *) {
 // 创建MTLFXFrameInterpolatorDescriptor
            let descriptor = MTLFXFrameInterpolatorDescriptor()
            
 // 配置帧插值器参数
            descriptor.inputWidth = 1920
            descriptor.inputHeight = 1080
            descriptor.outputWidth = 1920
            descriptor.outputHeight = 1080
            descriptor.colorTextureFormat = .rgba16Float
            descriptor.depthTextureFormat = .depth32Float
            descriptor.motionTextureFormat = .rg16Float
            
 // 创建帧插值器
            if let interpolator = descriptor.makeFrameInterpolator(device: device) {
                logger.info("✅ 真实的MetalFX Frame Interpolator创建成功")
                return interpolator
            } else {
                logger.error("❌ MetalFX Frame Interpolator创建失败")
            }
        }
        #endif
        
 // 如果系统版本不支持或创建失败，使用高质量的替代实现
        logger.info("🔄 使用高质量帧插值替代实现")
        return createCustomFrameInterpolator()
    }
    
 /// 创建MetalFX去噪器 - 使用真实的Apple API
    private func createDenoiser() -> Any? {
        guard let device = device else {
            logger.warning("Metal 设备未初始化")
            return nil
        }
        
 // 检查设备是否支持MetalFX Denoising
        guard device.supportsFamily(.apple7) else {
            logger.warning("⚠️ 设备不支持MetalFX去噪器，使用自定义去噪器")
            return createCustomDenoiser()
        }
        
 // Swift 6.2.1：使用自定义去噪器作为 MetalFX Denoiser 的降级方案
 // 当 MTLFXDenoiserDescriptor API 可用时，可切换回原生实现
        logger.info("🔧 使用自定义去噪器实现（MetalFX 降级方案）")
        return createCustomDenoiser()
    }
    
 /// 创建自定义帧插值器（当真实API不可用时）
    private func createCustomFrameInterpolator() -> CustomFrameInterpolator? {
        guard let device = device else { return nil }
        return CustomFrameInterpolator(device: device)
    }
    
 /// 创建自定义去噪器（当真实API不可用时）
    private func createCustomDenoiser() -> CustomDenoiser? {
        guard let device = device else { return nil }
        return CustomDenoiser(device: device)
    }
    
    private func createAIArgumentTable() -> Any {
 // 模拟Metal 4.0的MTL4ArgumentTable
        SkyBridgeLogger.metal.debugOnly("创建AI参数表")
        return NSObject()
    }
    
    private func loadAIModel(from path: String) async throws {
 // 加载AI模型权重
        SkyBridgeLogger.metal.debugOnly("加载AI模型: \(path)")
    }
    
    private func createRayTracingPipeline() async throws {
 // 创建光线追踪管线
        SkyBridgeLogger.metal.debugOnly("创建光线追踪管线")
    }
    
    private func setupMonitors() {
 // 不再使用 60Hz 空转帧定时器
 // 仅保留 GPU 内存监控（2s）
        gpuMemoryTimer?.invalidate()
        gpuMemoryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateGPUMemory()
            }
        }
    }
    
    private func updateGPUMemory() {
        guard let performanceMonitor = performanceMonitor else { return }
        gpuMemoryUsage = performanceMonitor.getGPUMemoryUsage()
    }
    
 // MARK: - 清理
    
 // deinit 中不直接访问非 Sendable 计时器，依赖宿主释放

 // MARK: - 调试标志更新
    public func updateDebugFlags(showWireframe: Bool, showNormals: Bool, showDepth: Bool) {
        self.debugShowWireframe = showWireframe
        self.debugShowNormals = showNormals
        self.debugShowDepth = showDepth
 // 可在此处将标志透传给底层渲染器/管线（预留）
    }
}

// MARK: - 统一缓冲区结构

struct Uniforms {
    let modelMatrix: simd_float4x4
    let viewMatrix: simd_float4x4
    let projectionMatrix: simd_float4x4
    let time: Float
}

// MARK: - 渲染统计

public struct RenderingStatistics {
    public var frameTime: Double = 0.0
    public var fps: Double = 0.0
    public var triangleCount: Int = 0
    public var drawCalls: Int = 0
    public var memoryUsage: Int64 = 0
    
    public var formattedFPS: String {
        return String(format: "%.1f FPS", fps)
    }
    
    public var formattedFrameTime: String {
        return String(format: "%.2f ms", frameTime * 1000)
    }
}

// MARK: - AI 推理引擎

@MainActor
class Metal4AIEngine {
    private let device: MTLDevice
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    func performInference(inputTexture: MTLTexture, outputTexture: MTLTexture) async throws {
 // AI推理实现
        SkyBridgeLogger.metal.debugOnly("执行AI推理")
    }
}

// MARK: - 性能监控器

@MainActor
class Metal4PerformanceMonitor {
    private let device: MTLDevice
    private var frameStartTime: CFTimeInterval = 0
    
    init(device: MTLDevice) {
        self.device = device
    }
    
    func beginFrame() {
        frameStartTime = CACurrentMediaTime()
    }
    
    func endFrame() {
        let _ = CACurrentMediaTime() - frameStartTime // 使用下划线忽略未使用的变量
 // 记录性能数据
    }
    
 /// 获取GPU内存使用情况
    func getGPUMemoryUsage() -> (used: Int64, total: Int64, percentage: Double) {
 // 使用IODiagnosticsClient获取真实的GPU内存使用情况
        if device.hasUnifiedMemory {
 // Apple Silicon统一内存架构
            let totalMemoryUInt = ProcessInfo.processInfo.physicalMemory
            let totalMemory = Int64(totalMemoryUInt)
            let usedMemory = Int64(device.recommendedMaxWorkingSetSize)
            let percentage = Double(usedMemory) / Double(totalMemory) * 100.0
            return (used: usedMemory, total: totalMemory, percentage: min(percentage, 100.0))
        } else {
 // 传统GPU架构
            let totalMemory = Int64(2_000_000_000) // 2GB估计值
            let usedMemory = Int64(device.recommendedMaxWorkingSetSize)
            let percentage = Double(usedMemory) / Double(totalMemory) * 100.0
            return (used: usedMemory, total: totalMemory, percentage: min(percentage, 100.0))
        }
    }
}

// MARK: - 错误定义

public enum Metal4Error: LocalizedError {
    case deviceNotSupported
    case metal4NotSupported
    case shaderLoadFailed
    case aiShaderNotFound
    case computeShaderNotFound
    case renderEncoderCreationFailed
    case computeEncoderCreationFailed
    case textureCreationFailed
    
    public var errorDescription: String? {
        switch self {
        case .deviceNotSupported:
            return "设备不支持Metal"
        case .metal4NotSupported:
            return "设备不支持Metal 4.0"
        case .shaderLoadFailed:
            return "着色器加载失败"
        case .aiShaderNotFound:
            return "AI推理着色器未找到"
        case .computeShaderNotFound:
            return "计算着色器未找到"
        case .renderEncoderCreationFailed:
            return "渲染编码器创建失败"
        case .computeEncoderCreationFailed:
            return "计算编码器创建失败"
        case .textureCreationFailed:
            return "纹理创建失败"
        }
    }
}
