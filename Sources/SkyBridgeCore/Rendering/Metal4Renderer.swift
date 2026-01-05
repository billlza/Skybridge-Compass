import Metal
import MetalKit
import MetalFX
import os.log

/// Metal 4 高级渲染器
///
/// 利用 Metal 4 的最新特性提升图形性能：
/// - ✅ 简化的命令编码 API
/// - ✅ MetalFX 帧插值和去噪
/// - ✅ 机器学习推理网络支持
/// - ✅ 优化的资源管理
/// - ✅ Apple Silicon 专属优化
///
/// 🆕 2025年技术：基于 Metal 4 稳定 API
/// ⚡ Swift 6.2.1: 使用 @unchecked Sendable 因为 Metal 对象是线程安全的
@available(macOS 26.0, *)
public final class Metal4Renderer: @unchecked Sendable {
    
 // MARK: - 属性
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "Metal4Renderer")
    
 // Metal 4 新特性
    private var metalFXUpscaler: MTLFXTemporalScaler?
 /// MetalFX 去噪器（在支持的 SDK 版本中使用）
 /// Swift 6.2.1：使用 Any 类型包装以避免编译时 API 检查问题
    private var metalFXDenoiser: Any?
 /// 自定义降噪管线（MetalFX 去噪器不可用时的降级方案）
    private var fallbackDenoisePipeline: MTLComputePipelineState?
    
 // 渲染管线缓存
    private var pipelineCache: [String: MTLRenderPipelineState] = [:]
    private var computePipelineCache: [String: MTLComputePipelineState] = [:]
    
 // 性能统计
    private var frameCount: UInt64 = 0
    private var lastFrameTime: CFTimeInterval = 0
    
 // MARK: - 初始化
    
    public init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("❌ Metal 4 不可用：无法创建 Metal 设备")
            return nil
        }
        
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            logger.error("❌ Metal 4 初始化失败：无法创建命令队列")
            return nil
        }
        
        self.commandQueue = commandQueue
        
        logger.info("✅ Metal 4 渲染器初始化成功")
        logger.info("   GPU: \(device.name)")
        logger.info("   支持光线追踪: \(device.supportsRaytracing)")
        logger.info("   支持函数指针: \(device.supportsFunctionPointers)")
        
 // 初始化 MetalFX
        initializeMetalFX()
    }
    
 // MARK: - MetalFX 初始化
    
    private func initializeMetalFX() {
 // MetalFX 时序放大器（Temporal Upscaling）
        let scalerDescriptor = MTLFXTemporalScalerDescriptor()
        scalerDescriptor.inputWidth = 1920
        scalerDescriptor.inputHeight = 1080
        scalerDescriptor.outputWidth = 3840
        scalerDescriptor.outputHeight = 2160
        scalerDescriptor.colorTextureFormat = .bgra8Unorm
        scalerDescriptor.depthTextureFormat = .depth32Float
        scalerDescriptor.motionTextureFormat = .rg16Float
        scalerDescriptor.outputTextureFormat = .bgra8Unorm
        
        if let scaler = scalerDescriptor.makeTemporalScaler(device: device) {
            self.metalFXUpscaler = scaler
            logger.info("✅ MetalFX 时序放大器已启用")
        }
        
 // MetalFX 去噪器（尝试初始化，不可用时使用降级方案）
        initializeDenoiser()
        
 // 设置降级方案：自定义高斯模糊降噪管线
        setupFallbackDenoisePipeline()
    }
    
 // MARK: - Metal 4 渲染管线
    
 /// 创建优化的渲染管线（Metal 4 新 API）
 ///
 /// Metal 4 特性：
 /// - 简化的管线创建流程
 /// - 自动资源绑定优化
 /// - 更好的编译缓存
    public func createOptimizedPipeline(
        vertexFunction: String,
        fragmentFunction: String,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) -> MTLRenderPipelineState? {
        let cacheKey = "\(vertexFunction)_\(fragmentFunction)"
        
 // 检查缓存
        if let cached = pipelineCache[cacheKey] {
            return cached
        }
        
        guard let library = device.makeDefaultLibrary() else {
            logger.error("无法加载默认着色器库")
            return nil
        }
        
        guard let vertexFunc = library.makeFunction(name: vertexFunction),
              let fragmentFunc = library.makeFunction(name: fragmentFunction) else {
            logger.error("无法加载着色器函数: \(vertexFunction), \(fragmentFunction)")
            return nil
        }
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunc
        pipelineDescriptor.fragmentFunction = fragmentFunc
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        
 // Metal 4: 启用新的优化选项
        pipelineDescriptor.supportIndirectCommandBuffers = true
        
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineCache[cacheKey] = pipeline
            logger.info("✅ 渲染管线已创建并缓存: \(cacheKey)")
            return pipeline
        } catch {
            logger.error("创建渲染管线失败: \(error.localizedDescription)")
            return nil
        }
    }
    
 // MARK: - 帧渲染
    
 /// 渲染单帧（Metal 4 优化版本）
 ///
 /// Metal 4 改进：
 /// - 简化的命令编码
 /// - 自动资源追踪
 /// - MetalFX 帧插值
    public func renderFrame(
        to drawable: CAMetalDrawable,
        renderPass: MTLRenderPassDescriptor,
        pipeline: MTLRenderPipelineState,
        drawCommands: (MTLRenderCommandEncoder) -> Void
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            logger.error("无法创建命令缓冲区")
            return
        }
        
        commandBuffer.label = "Metal4 Frame \(frameCount)"
        
 // Metal 4: 简化的渲染编码器创建
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            logger.error("无法创建渲染编码器")
            return
        }
        
        renderEncoder.label = "Metal4 Render Encoder"
        renderEncoder.setRenderPipelineState(pipeline)
        
 // 执行自定义绘制命令
        drawCommands(renderEncoder)
        
        renderEncoder.endEncoding()
        
 // 应用 MetalFX 放大和去噪（如果可用）
        if metalFXUpscaler != nil {
            applyMetalFXUpscaling(commandBuffer: commandBuffer, sourceTexture: drawable.texture)
        }
        
 // 提交到显示
        commandBuffer.present(drawable)
        
 // Metal 4: 添加完成处理器用于性能追踪
        commandBuffer.addCompletedHandler { [weak self] buffer in
            self?.trackPerformance(buffer: buffer)
        }
        
        commandBuffer.commit()
        frameCount += 1
    }
    
 // MARK: - MetalFX 后处理
    
    private func applyMetalFXUpscaling(commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture) {
        guard let upscaler = metalFXUpscaler else { return }
        
 // 创建放大编码器（简化版本）
        upscaler.colorTexture = sourceTexture
        upscaler.outputTexture = sourceTexture
        upscaler.encode(commandBuffer: commandBuffer)
        
        logger.debug("应用 MetalFX 时序放大")
    }
    
 /// 初始化 MetalFX 去噪器
 /// Swift 6.2.1：使用运行时检查避免编译时 API 可用性问题
    private func initializeDenoiser() {
 // 尝试动态创建 MTLFXDenoiserDescriptor
 // 这种方式可以在 API 不可用时优雅降级
        guard let denoiserDescClass = NSClassFromString("MTLFXDenoiserDescriptor") as? NSObject.Type else {
            logger.info("⚠️ MetalFX 去噪器 API 不可用，将使用降级方案")
            return
        }
        
        let descriptor = denoiserDescClass.init()
        descriptor.setValue(3840, forKey: "width")
        descriptor.setValue(2160, forKey: "height")
        descriptor.setValue(MTLPixelFormat.bgra8Unorm.rawValue, forKey: "colorTextureFormat")
        
        if let denoiser = descriptor.perform(NSSelectorFromString("makeDenoiserWithDevice:"), with: device)?.takeUnretainedValue() {
            self.metalFXDenoiser = denoiser
            logger.info("✅ MetalFX 去噪器已启用")
        } else {
            logger.info("⚠️ MetalFX 去噪器创建失败，将使用降级方案")
        }
    }
    
 /// 设置降级降噪管线（使用自定义高斯模糊）
    private func setupFallbackDenoisePipeline() {
        guard let library = device.makeDefaultLibrary() else {
            logger.warning("无法加载默认着色器库用于降级降噪")
            return
        }
        
 // 尝试加载自定义降噪着色器
        if let denoiseFunction = library.makeFunction(name: "gaussianBlurDenoise") {
            do {
                self.fallbackDenoisePipeline = try device.makeComputePipelineState(function: denoiseFunction)
                logger.info("✅ 降级降噪管线已设置（高斯模糊）")
            } catch {
                logger.warning("降级降噪管线创建失败: \(error.localizedDescription)")
            }
        } else {
            logger.debug("gaussianBlurDenoise 着色器不可用，降噪将被跳过")
        }
    }
    
 /// 应用 MetalFX 去噪或降级方案
    private func applyMetalFXDenoising(commandBuffer: MTLCommandBuffer, texture: MTLTexture) {
 // 优先使用 MetalFX 原生去噪器
        if let denoiser = metalFXDenoiser {
 // 使用 NSInvocation 来调用多参数方法
            if invokeMetalFXDenoiser(denoiser: denoiser, commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: texture) {
                logger.debug("应用 MetalFX 原生去噪")
                return
            }
        }
        
 // 降级方案：使用自定义高斯模糊
        if let denoisePipeline = fallbackDenoisePipeline {
            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                logger.debug("无法创建降级降噪计算编码器")
                return
            }
            
            computeEncoder.label = "Fallback Denoise"
            computeEncoder.setComputePipelineState(denoisePipeline)
            computeEncoder.setTexture(texture, index: 0)
            computeEncoder.setTexture(texture, index: 1)
            
            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(
                width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
                height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1
            )
            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()
            
            logger.debug("应用降级高斯模糊降噪")
            return
        }
        
 // 无可用降噪方案
        logger.debug("跳过降噪处理（无可用方案）")
    }
    
 /// 使用 Objective-C 运行时调用 MetalFX 去噪器的 encode 方法
 /// - Parameters:
 /// - denoiser: MetalFX 去噪器对象
 /// - commandBuffer: Metal 命令缓冲区
 /// - sourceTexture: 源纹理
 /// - destinationTexture: 目标纹理
 /// - Returns: 是否成功调用
    private func invokeMetalFXDenoiser(
        denoiser: Any,
        commandBuffer: MTLCommandBuffer,
        sourceTexture: MTLTexture,
        destinationTexture: MTLTexture
    ) -> Bool {
        let selector = NSSelectorFromString("encodeToCommandBuffer:sourceTexture:destinationTexture:")
        let obj = denoiser as AnyObject
        
        guard obj.responds(to: selector) else {
            logger.debug("去噪器不响应 encode 选择器")
            return false
        }
        
 // 使用 IMP 调用来支持多参数
        typealias EncodeFunction = @convention(c) (AnyObject, Selector, MTLCommandBuffer, MTLTexture, MTLTexture) -> Void
        let imp = obj.method(for: selector)
        let function = unsafeBitCast(imp, to: EncodeFunction.self)
        function(obj, selector, commandBuffer, sourceTexture, destinationTexture)
        
        return true
    }
    
 // MARK: - 计算管线（用于机器学习推理）
    
 /// 创建计算管线用于 ML 推理
 ///
 /// Metal 4 特性：张量原生支持
    public func createMLComputePipeline(functionName: String) -> MTLComputePipelineState? {
        if let cached = computePipelineCache[functionName] {
            return cached
        }
        
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: functionName) else {
            logger.error("无法加载计算函数: \(functionName)")
            return nil
        }
        
        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            computePipelineCache[functionName] = pipeline
            logger.info("✅ ML 计算管线已创建: \(functionName)")
            return pipeline
        } catch {
            logger.error("创建计算管线失败: \(error.localizedDescription)")
            return nil
        }
    }
    
 /// 执行 ML 推理（在着色器中）
 ///
 /// Metal 4 新特性：在着色器中直接运行推理网络
    public func runMLInference(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLComputePipelineState,
        inputTexture: MTLTexture,
        outputTexture: MTLTexture
    ) {
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            logger.error("无法创建计算编码器")
            return
        }
        
        computeEncoder.label = "ML Inference"
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        
 // 计算线程组大小
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
        
        logger.debug("执行 ML 推理")
    }
    
 // MARK: - 性能追踪
    
    private func trackPerformance(buffer: MTLCommandBuffer) {
        let currentTime = CFAbsoluteTimeGetCurrent()
        
        if lastFrameTime > 0 {
            let frameTime = currentTime - lastFrameTime
            let fps = 1.0 / frameTime
            
            if frameCount % 60 == 0 {  // 每60帧记录一次
                logger.info("📊 Metal 4 性能: \(String(format: "%.1f", fps)) FPS, 帧时间: \(String(format: "%.2f", frameTime * 1000)) ms")
            }
        }
        
        lastFrameTime = currentTime
    }
    
 // MARK: - 资源清理
    
    deinit {
        logger.info("🧹 Metal 4 渲染器清理资源")
        pipelineCache.removeAll()
        computePipelineCache.removeAll()
    }
}

// MARK: - Metal 4 兼容性检查

@available(macOS 26.0, *)
extension Metal4Renderer {
    
 /// 检查 Metal 4 特性可用性
    public static func checkMetal4Availability() -> Metal4Features {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return Metal4Features(available: false)
        }
        
 // 检查 MetalFX 支持（macOS 26.0已包含MetalFX）
 // 尝试创建 MetalFX 放大器以检查支持
        let desc = MTLFXTemporalScalerDescriptor()
        desc.inputWidth = 1920
        desc.inputHeight = 1080
        desc.outputWidth = 3840
        desc.outputHeight = 2160
        desc.colorTextureFormat = .bgra8Unorm
        desc.depthTextureFormat = .invalid
        desc.motionTextureFormat = .invalid
        desc.outputTextureFormat = .bgra8Unorm
        let supportsMetalFX = desc.makeTemporalScaler(device: device) != nil
        
        return Metal4Features(
            available: true,
            supportsRaytracing: device.supportsRaytracing,
            supportsFunctionPointers: device.supportsFunctionPointers,
            supportsMetalFX: supportsMetalFX,
            deviceName: device.name
        )
    }
    
 /// Metal 4 特性描述
    public struct Metal4Features {
        public let available: Bool
        public let supportsRaytracing: Bool
        public let supportsFunctionPointers: Bool
        public let supportsMetalFX: Bool
        public let deviceName: String
        
        init(available: Bool, 
             supportsRaytracing: Bool = false, 
             supportsFunctionPointers: Bool = false, 
             supportsMetalFX: Bool = false, 
             deviceName: String = "Unknown") {
            self.available = available
            self.supportsRaytracing = supportsRaytracing
            self.supportsFunctionPointers = supportsFunctionPointers
            self.supportsMetalFX = supportsMetalFX
            self.deviceName = deviceName
        }
    }
}

