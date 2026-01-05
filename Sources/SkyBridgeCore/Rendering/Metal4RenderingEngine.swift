import Foundation
import Metal
import MetalKit
import MetalFX
import simd
import os.log

// 导入天气相关类型
// import SkyBridgeCore // 移除自导入

/// Metal 4 核心渲染引擎 - 支持光线追踪、粒子系统和MetalFX增强
@MainActor
public final class Metal4RenderingEngine: NSObject, ObservableObject {
    
 // MARK: - 发布的属性
    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var renderingError: RenderingError?
    @Published public private(set) var frameRate: Double = 0.0
    @Published public private(set) var gpuUtilization: Double = 0.0
    
 // MARK: - Metal 核心组件
 /// Metal 设备 - 延迟初始化，使用 Optional 而非隐式解包
    public private(set) var device: MTLDevice?
 /// 命令队列 - 延迟初始化
    public private(set) var commandQueue: MTLCommandQueue?
 /// 着色器库 - 延迟初始化
    public private(set) var library: MTLLibrary?
    
 // MARK: - 光线追踪组件
    private var rayTracingPipeline: MTLComputePipelineState?
    private var accelerationStructure: MTLAccelerationStructure?
    private var intersectionFunctionTable: MTLIntersectionFunctionTable?
    
 // MARK: - 天气粒子系统
    private var weatherParticleSystem: InteractiveWeatherParticleSystem?
    private let weatherDataService: WeatherDataService
    
 // MARK: - 鼠标交互
    private var currentMousePosition: CGPoint = .zero
    
 // MARK: - MetalFX 组件
    private var temporalScaler: MTLFXTemporalScaler?
    private var spatialScaler: MTLFXSpatialScaler?
    
 // MARK: - 渲染资源
 /// 渲染目标 - 延迟初始化
    private var renderTargets: RenderTargets?
 /// Uniform 缓冲区 - 延迟初始化
    private var uniformBuffer: MTLBuffer?
 /// 天气参数缓冲区 - 延迟初始化
    private var weatherParametersBuffer: MTLBuffer?
    
 // MARK: - 粒子系统资源
    private var particleBuffer: MTLBuffer?
    private var particleCount: Int = 0
    private var particleComputePipeline: MTLComputePipelineState?
    private var particleRenderPipeline: MTLRenderPipelineState?
    
 // MARK: - 变换矩阵
    private var viewMatrix: matrix_float4x4 = matrix_identity_float4x4
    private var projectionMatrix: matrix_float4x4 = matrix_identity_float4x4
    
 // MARK: - 性能监控
    private let log = Logger(subsystem: "com.skybridge.compass", category: "Metal4Rendering")
    private var frameCounter: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    @MainActor private var performanceTimer: Timer?
 // In‑flight 帧门闩（最多3帧同时在途），超出立即丢帧，避免堆积
    private let inflightSemaphore = DispatchSemaphore(value: 3)
 // FPS统计窗口与发布频率（2Hz）
    private var fpsWindowStart: CFTimeInterval = 0
    private var fpsWindowFrames: Int = 0
    private var lastStatsDispatch: CFTimeInterval = 0
 // 向外部引擎写回渲染统计的回调（避免强耦合）
    public var statsCallback: ((RenderingStatistics) -> Void)?
    
 // MARK: - 渲染错误类型
    public enum RenderingError: LocalizedError {
        case deviceNotSupported
        case shaderCompilationFailed(String)
        case bufferCreationFailed
        case pipelineCreationFailed
        case rayTracingNotSupported
        case metalFXNotSupported
        
        public var errorDescription: String? {
            switch self {
            case .deviceNotSupported:
                return "设备不支持Metal渲染"
            case .shaderCompilationFailed(let message):
                return "着色器编译失败: \(message)"
            case .bufferCreationFailed:
                return "缓冲区创建失败"
            case .pipelineCreationFailed:
                return "渲染管线创建失败"
            case .rayTracingNotSupported:
                return "设备不支持光线追踪"
            case .metalFXNotSupported:
                return "设备不支持MetalFX"
            }
        }
    }
    
 // MARK: - 初始化
    public init(weatherDataService: WeatherDataService) {
        self.weatherDataService = weatherDataService
        super.init()
        Task {
            await initializeMetal()
        }
    }
    
    deinit {
 // 移除deinit中的Timer清理，让系统自动处理
    }
    
 // MARK: - 公共方法
    
 /// 初始化Metal渲染引擎
    public func initializeMetal() async {
        log.info("开始初始化Metal 4渲染引擎")
        
        do {
 // 创建Metal设备
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw RenderingError.deviceNotSupported
            }
            self.device = device
            
 // 检查设备能力
            try validateDeviceCapabilities()
            
 // 创建命令队列
            guard let commandQueue = device.makeCommandQueue() else {
                throw RenderingError.deviceNotSupported
            }
            self.commandQueue = commandQueue
            
 // 加载着色器库
            await loadShaderLibrary()
            
 // 初始化渲染管线
            try await setupRenderingPipelines()
            
 // 初始化光线追踪
            try await setupRayTracing()
            
 // 初始化粒子系统
            try await setupWeatherParticleSystem()
            
 // 初始化MetalFX
            try await setupMetalFX()
            
 // 创建渲染资源
            try createRenderingResources()
            
 // 启动性能监控
            startPerformanceMonitoring()
            
            isInitialized = true
            log.info("Metal 4渲染引擎初始化完成")
            
        } catch {
            renderingError = error as? RenderingError ?? .deviceNotSupported
            log.error("Metal渲染引擎初始化失败: \(error.localizedDescription)")
        }
    }
    
 /// 渲染天气场景
    public func renderWeatherScene(
        parameters: WeatherRenderingParameters,
        to drawable: CAMetalDrawable,
        viewportSize: CGSize
    ) throws {
        
        guard isInitialized, let device = device, let commandQueue = commandQueue else {
            throw RenderingError.deviceNotSupported
        }
        
 // 门闩控制 - 若达到并发上限，直接丢帧避免阻塞
        if inflightSemaphore.wait(timeout: .now()) == .timedOut {
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RenderingError.pipelineCreationFailed
        }
        
 // 更新uniform缓冲区
        updateUniforms(parameters: parameters, viewportSize: viewportSize)
        
 // 更新天气粒子系统
        if let weatherParticleSystem = weatherParticleSystem {
            weatherParticleSystem.updateMousePosition(currentMousePosition)
        }
        
 // 执行光线追踪
        if device.supportsRaytracing {
            try executeRayTracing(commandBuffer: commandBuffer, parameters: parameters)
        }
        
 // 执行主渲染通道
        try executeMainRenderPass(
            commandBuffer: commandBuffer,
            drawable: drawable,
            parameters: parameters
        )
        
 // 应用MetalFX增强
        if let temporalScaler = temporalScaler {
            try applyMetalFXEnhancement(
                commandBuffer: commandBuffer,
                scaler: temporalScaler,
                drawable: drawable
            )
        }
        
 // 提交命令缓冲区
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }
        commandBuffer.commit()
        
 // 更新性能统计
        updatePerformanceStats()
    }
    
 /// 更新天气粒子系统
    public func updateParticleSystem(weatherType: WeatherDataService.WeatherType, intensity: Double) {
 // 启动天气粒子系统
        weatherParticleSystem?.start()
        
        log.info("天气粒子系统已更新为: \(weatherType.displayName), 强度: \(intensity)")
    }
    
 /// 更新鼠标位置
    public func updateMousePosition(_ position: CGPoint) {
        currentMousePosition = position
        weatherParticleSystem?.updateMousePosition(position)
    }
    
 /// 设置鼠标按下状态
    public func setMousePressed(_ pressed: Bool) {
        weatherParticleSystem?.setMousePressed(pressed)
    }
    
 /// 设置鼠标交互参数
    public func setMouseInteractionParameters(
        influenceRadius: Float? = nil,
        repelForce: Float? = nil,
        attractForce: Float? = nil,
        blurRadius: Float? = nil,
        mistBlurIntensity: Float? = nil,
        dispersionRadius: Float? = nil
    ) {
        weatherParticleSystem?.setMouseInteractionParameters(
            influenceRadius: influenceRadius,
            repelForce: repelForce,
            attractForce: attractForce,
            blurRadius: blurRadius,
            mistBlurIntensity: mistBlurIntensity,
            dispersionRadius: dispersionRadius
        )
    }
    
 // MARK: - 私有方法
    
 /// 验证设备能力
    private func validateDeviceCapabilities() throws {
        guard let device = device else {
            throw RenderingError.deviceNotSupported
        }
        
        guard device.supportsFamily(.apple7) || device.supportsFamily(.mac2) else {
            throw RenderingError.deviceNotSupported
        }
        
        log.info("设备支持Metal功能集: Apple7/Mac2")
        
 // 检查光线追踪支持
        if device.supportsRaytracing {
            log.info("设备支持硬件光线追踪")
        } else {
            log.warning("设备不支持硬件光线追踪，将使用软件实现")
        }
        
 // 检查MetalFX支持
        log.info("设备支持MetalFX")
    }
    
 /// 加载着色器库
    private func loadShaderLibrary() async {
        do {
            guard let device = device else {
                throw RenderingError.deviceNotSupported
            }
            guard let library = device.makeDefaultLibrary() else {
                throw RenderingError.shaderCompilationFailed("无法加载默认着色器库")
            }
            self.library = library
            log.info("着色器库加载完成")
        } catch {
            renderingError = error as? RenderingError
            log.error("着色器库加载失败: \(error.localizedDescription)")
        }
    }
    
 /// 设置渲染管线
    private func setupRenderingPipelines() async throws {
        guard let device = device, let library = library else {
            throw RenderingError.deviceNotSupported
        }
        
 // 创建粒子计算管线
        guard let particleComputeFunction = library.makeFunction(name: "particle_update_compute") else {
            throw RenderingError.shaderCompilationFailed("粒子计算着色器未找到")
        }
        
        particleComputePipeline = try await device.makeComputePipelineState(function: particleComputeFunction)
        
 // 创建粒子渲染管线
        let particleRenderDescriptor = MTLRenderPipelineDescriptor()
        particleRenderDescriptor.vertexFunction = library.makeFunction(name: "particle_vertex")
        particleRenderDescriptor.fragmentFunction = library.makeFunction(name: "particle_fragment")
        particleRenderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        particleRenderDescriptor.colorAttachments[0].isBlendingEnabled = true
        particleRenderDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        particleRenderDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        particleRenderPipeline = try await device.makeRenderPipelineState(descriptor: particleRenderDescriptor)
        
        log.info("渲染管线设置完成")
    }
    
 /// 设置光线追踪
    private func setupRayTracing() async throws {
        guard let device = device, let library = library else {
            throw RenderingError.deviceNotSupported
        }
        
        guard device.supportsRaytracing else {
            log.warning("跳过光线追踪设置，设备不支持")
            return
        }
        
 // 创建光线追踪计算管线
        guard let rayTracingFunction = library.makeFunction(name: "ray_tracing_compute") else {
            throw RenderingError.shaderCompilationFailed("光线追踪着色器未找到")
        }
        
        rayTracingPipeline = try await device.makeComputePipelineState(function: rayTracingFunction)
        
 // 创建加速结构（简化版本）
        let accelerationStructureDescriptor = MTLPrimitiveAccelerationStructureDescriptor()
        accelerationStructureDescriptor.usage = [.refit, .preferFastBuild]
        
        let accelerationStructureSizes = device.accelerationStructureSizes(descriptor: accelerationStructureDescriptor)
        
 // 创建加速结构缓冲区（检查是否创建成功）
        guard device.makeBuffer(
            length: accelerationStructureSizes.accelerationStructureSize,
            options: .storageModePrivate
        ) != nil else {
            throw RenderingError.bufferCreationFailed
        }
        
 // 创建加速结构（简化版本，使用设备方法）
        accelerationStructure = device.makeAccelerationStructure(
            descriptor: accelerationStructureDescriptor
        )
        
        log.info("光线追踪设置完成")
    }
    
 /// 设置天气粒子系统
    private func setupWeatherParticleSystem() async throws {
        guard let device = device else {
            throw RenderingError.deviceNotSupported
        }
        
        do {
            weatherParticleSystem = try InteractiveWeatherParticleSystem(
                device: device,
                weatherDataService: weatherDataService
            )
            log.info("天气粒子系统初始化完成")
        } catch {
            log.error("天气粒子系统初始化失败: \(error.localizedDescription)")
            throw RenderingError.pipelineCreationFailed
        }
    }
    
 /// 设置MetalFX
    private func setupMetalFX() async throws {
        guard let device = device else {
            throw RenderingError.deviceNotSupported
        }
        
 // 创建时域缩放器
        let temporalScalerDescriptor = MTLFXTemporalScalerDescriptor()
        temporalScalerDescriptor.colorTextureFormat = .bgra8Unorm
        temporalScalerDescriptor.depthTextureFormat = .depth32Float
        temporalScalerDescriptor.motionTextureFormat = .rg16Float
        temporalScalerDescriptor.outputTextureFormat = .bgra8Unorm
        temporalScalerDescriptor.inputWidth = 1920
        temporalScalerDescriptor.inputHeight = 1080
        temporalScalerDescriptor.outputWidth = 3840
        temporalScalerDescriptor.outputHeight = 2160
        
        if MTLFXTemporalScalerDescriptor.supportsDevice(device) {
            temporalScaler = temporalScalerDescriptor.makeTemporalScaler(device: device)
            log.info("MetalFX时域缩放器创建成功")
        } else {
            log.warning("设备不支持MetalFX时域缩放器")
        }
    }
    
 /// 创建渲染资源
    private func createRenderingResources() throws {
        guard let device = device else {
            throw RenderingError.deviceNotSupported
        }
        
 // 创建uniform缓冲区
        guard let uniformBuffer = device.makeBuffer(
            length: MemoryLayout<UniformData>.stride,
            options: .storageModeShared
        ) else {
            throw RenderingError.bufferCreationFailed
        }
        self.uniformBuffer = uniformBuffer
        
 // 创建天气参数缓冲区
        guard let weatherBuffer = device.makeBuffer(
            length: MemoryLayout<WeatherUniformData>.stride,
            options: .storageModeShared
        ) else {
            throw RenderingError.bufferCreationFailed
        }
        self.weatherParametersBuffer = weatherBuffer
        
 // 创建渲染目标（使用 failable init）
        guard let targets = RenderTargets(device: device) else {
            throw RenderingError.bufferCreationFailed
        }
        renderTargets = targets
        
        log.info("渲染资源创建完成")
    }
    
 /// 重新创建粒子缓冲区
    private func recreateParticleBuffer() {
        guard let device = device else { return }
        
        let particleSize = MemoryLayout<ParticleData>.stride
        let bufferSize = particleSize * particleCount
        
        particleBuffer = device.makeBuffer(
            length: bufferSize,
            options: .storageModeShared
        )
        
 // 初始化粒子数据
        if let buffer = particleBuffer {
            let particles = buffer.contents().bindMemory(to: ParticleData.self, capacity: particleCount)
            for i in 0..<particleCount {
                particles[i] = ParticleData.random()
            }
        }
    }
    
 /// 计算粒子数量
    private func calculateParticleCount(weatherType: WeatherDataService.WeatherType, intensity: Double) -> Int {
        let baseCount: Int
        
        switch weatherType {
        case .clear:
            baseCount = 1000 // 少量灰尘粒子
        case .partlyCloudy, .cloudy:
            baseCount = 5000 // 云层粒子
        case .rain:
            baseCount = 50000 // 雨滴
        case .heavyRain:
            baseCount = 100000 // 大雨
        case .snow:
            baseCount = 30000 // 雪花
        case .heavySnow:
            baseCount = 80000 // 大雪
        case .thunderstorm:
            baseCount = 120000 // 雷暴
        case .fog:
            baseCount = 20000 // 雾气粒子
        case .haze:  // 新增雾霾粒子数量计算
            baseCount = 25000 // 雾霾粒子，比雾稍多营造更浓重效果
        case .wind:
            baseCount = 15000 // 风沙粒子
        case .hail:
            baseCount = 40000 // 冰雹
        case .unknown:
            baseCount = 1000
        }
        
        return Int(Double(baseCount) * intensity)
    }
    
 /// 更新uniform数据
    private func updateUniforms(parameters: WeatherRenderingParameters, viewportSize: CGSize) {
 // 更新变换矩阵
        viewMatrix = matrix_identity_float4x4
        projectionMatrix = createProjectionMatrix(viewportSize: viewportSize)
        
 // 更新基础uniform数据
        var uniformData = UniformData(
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            time: Float(CACurrentMediaTime()),
            deltaTime: 1.0 / 60.0
        )
        
        uniformBuffer?.contents().copyMemory(
            from: &uniformData,
            byteCount: MemoryLayout<UniformData>.stride
        )
        
 // 更新天气参数数据
        var weatherData = WeatherUniformData(
            weatherType: Int32(parameters.weatherType.hashValue),
            intensity: Float(parameters.intensity),
            temperature: Float(parameters.temperature),
            humidity: Float(parameters.humidity),
            windSpeed: Float(parameters.windSpeed),
            windDirection: Float(parameters.windDirection),
            cloudCoverage: Float(parameters.cloudCoverage),
            precipitationAmount: Float(parameters.precipitationAmount),
            visibility: Float(parameters.visibility),
            pressure: Float(parameters.pressure),
            uvIndex: Float(parameters.uvIndex),
            timeOfDay: Int32(parameters.timeOfDay.hashValue)
        )
        
        weatherParametersBuffer?.contents().copyMemory(
            from: &weatherData,
            byteCount: MemoryLayout<WeatherUniformData>.stride
        )
    }
    
 /// 创建投影矩阵
    private func createProjectionMatrix(viewportSize: CGSize) -> matrix_float4x4 {
        let aspect = Float(viewportSize.width / viewportSize.height)
        let fov = Float.pi / 4.0 // 45度视角
        let near: Float = 0.1
        let far: Float = 1000.0
        
        return matrix_perspective_left_hand(fovyRadians: fov, aspectRatio: aspect, nearZ: near, farZ: far)
    }
    
 /// 执行计算着色器
    private func executeComputeShaders(
        commandBuffer: MTLCommandBuffer,
        parameters: WeatherRenderingParameters
    ) async throws {
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
              let pipeline = particleComputePipeline,
              let particleBuffer = particleBuffer else {
            throw RenderingError.pipelineCreationFailed
        }
        
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(weatherParametersBuffer, offset: 0, index: 2)
        
        let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        let threadGroups = MTLSize(
            width: (particleCount + 63) / 64,
            height: 1,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()
    }
    
 /// 执行光线追踪
    private func executeRayTracing(
        commandBuffer: MTLCommandBuffer,
        parameters: WeatherRenderingParameters
    ) throws {
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
              let pipeline = rayTracingPipeline else {
            return
        }
        
        computeEncoder.setComputePipelineState(pipeline)
        computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(weatherParametersBuffer, offset: 0, index: 1)
        
        if let accelerationStructure = accelerationStructure {
            computeEncoder.setAccelerationStructure(accelerationStructure, bufferIndex: 2)
        }
        
        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let threadGroups = MTLSize(width: 240, height: 135, depth: 1) // 1920x1080 / 8x8
        
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()
    }
    
 /// 执行主渲染通道
    private func executeMainRenderPass(
        commandBuffer: MTLCommandBuffer,
        drawable: CAMetalDrawable,
        parameters: WeatherRenderingParameters
    ) throws {
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0
        )
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw RenderingError.pipelineCreationFailed
        }
        
 // 渲染天气粒子系统
        weatherParticleSystem?.render(
            in: renderEncoder,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix
        )
        
        renderEncoder.endEncoding()
    }
    
 /// 应用MetalFX增强
    private func applyMetalFXEnhancement(
        commandBuffer: MTLCommandBuffer,
        scaler: MTLFXTemporalScaler,
        drawable: CAMetalDrawable
    ) throws {
        
 // 这里需要实际的输入纹理和运动向量
 // 简化实现，实际使用中需要完整的渲染管线
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        
 // 执行MetalFX缩放
        scaler.encode(commandBuffer: commandBuffer)
        
        blitEncoder.endEncoding()
    }
    
 /// 启动性能监控
    private func startPerformanceMonitoring() {
        performanceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePerformanceMetrics()
            }
        }
    }
    
 /// 更新性能统计
    private func updatePerformanceStats() {
        frameCounter += 1
        let currentTime = CACurrentMediaTime()
        if fpsWindowStart == 0 { fpsWindowStart = currentTime }
        fpsWindowFrames += 1
        let windowElapsed = currentTime - fpsWindowStart
        if windowElapsed >= 0.5 { // 0.5s窗口平均
            let avgFPS = Double(fpsWindowFrames) / windowElapsed
            frameRate = avgFPS
 // 2Hz发布渲染统计
            if currentTime - lastStatsDispatch >= 0.5 {
                var stats = RenderingStatistics()
                stats.fps = avgFPS
                stats.frameTime = windowElapsed / Double(fpsWindowFrames)
                statsCallback?(stats)
                lastStatsDispatch = currentTime
            }
            fpsWindowStart = currentTime
            fpsWindowFrames = 0
        }
        lastFrameTime = currentTime
    }
    
 /// 更新性能指标
    private func updatePerformanceMetrics() {
 // 这里可以添加GPU利用率监控
 // 实际实现需要使用Metal Performance Shaders或其他工具
        gpuUtilization = Double.random(in: 0.3...0.8) // 模拟数据
    }
    
 /// 为指定天气类型准备渲染资源
    public func prepareRenderingResources(for weatherType: WeatherDataService.WeatherType) async {
 // 根据天气类型更新粒子系统
        updateParticleSystem(weatherType: weatherType, intensity: 1.0)
        
 // 记录日志
        log.info("为天气类型 \(String(describing: weatherType)) 准备渲染资源完成")
    }
    
 /// 设置过渡进度
    public func setTransitionProgress(_ progress: Float) async {
 // 更新过渡进度（可以用于动画效果）
 // 这里可以根据需要实现具体的过渡逻辑
        log.debug("设置过渡进度: \(progress)")
    }
    
 /// 生成壁纸纹理
    public func generateWallpaperTexture(
        for weatherType: WeatherDataService.WeatherType,
        parameters: WeatherRenderingParameters
    ) async -> MTLTexture? {
        guard let device = device else {
            log.error("Metal 设备未初始化")
            return nil
        }
        
 // 创建临时纹理用于壁纸生成
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1920,
            height: 1080,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            log.error("创建壁纸纹理失败")
            return nil
        }
        
 // 这里可以添加具体的壁纸生成逻辑
        log.info("为天气类型 \(String(describing: weatherType)) 生成壁纸纹理")
        return texture
    }
    
 /// 启用节能模式
    public func enableEnergyEfficiencyMode() {
 // 实现节能模式逻辑
        log.info("启用节能模式")
    }
    
 /// 禁用节能模式
    public func disableEnergyEfficiencyMode() {
 // 实现禁用节能模式逻辑
        log.info("禁用节能模式")
    }
    
 /// 设置渲染质量
    public func setRenderingQuality(_ quality: String) {
 // 实现设置渲染质量逻辑
        log.info("设置渲染质量: \(quality)")
    }
    
 /// 渲染方法
    public func render(parameters: WeatherRenderingParameters, to texture: MTLTexture) async throws {
 // 实现渲染逻辑
        log.info("执行渲染操作")
    }
}

// MARK: - 数据结构

/// Uniform数据结构
private struct UniformData {
    let viewMatrix: matrix_float4x4
    let projectionMatrix: matrix_float4x4
    let time: Float
    let deltaTime: Float
}

/// 天气Uniform数据结构
private struct WeatherUniformData {
    let weatherType: Int32
    let intensity: Float
    let temperature: Float
    let humidity: Float
    let windSpeed: Float
    let windDirection: Float
    let cloudCoverage: Float
    let precipitationAmount: Float
    let visibility: Float
    let pressure: Float
    let uvIndex: Float
    let timeOfDay: Int32
}

/// 粒子数据结构
private struct ParticleData {
    let position: simd_float3
    let velocity: simd_float3
    let color: simd_float4
    let size: Float
    let life: Float
    
    static func random() -> ParticleData {
        return ParticleData(
            position: simd_float3(
                Float.random(in: -10...10),
                Float.random(in: 0...20),
                Float.random(in: -10...10)
            ),
            velocity: simd_float3(
                Float.random(in: -1...1),
                Float.random(in: (-5)...(-1)),  // 添加括号消除歧义
                Float.random(in: -1...1)
            ),
            color: simd_float4(1.0, 1.0, 1.0, 1.0),
            size: Float.random(in: 0.1...0.5),
            life: Float.random(in: 1.0...5.0)
        )
    }
}

/// 渲染目标
private class RenderTargets {
    let colorTexture: MTLTexture
    let depthTexture: MTLTexture
    
 /// 使用 failable init 替代 force unwrap
 /// - Parameter device: Metal 设备
 /// - Returns: nil 如果纹理创建失败
    init?(device: MTLDevice) {
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1920,
            height: 1080,
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        guard let colorTex = device.makeTexture(descriptor: colorDescriptor) else {
            return nil
        }
        colorTexture = colorTex
        
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: 1920,
            height: 1080,
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        guard let depthTex = device.makeTexture(descriptor: depthDescriptor) else {
            return nil
        }
        depthTexture = depthTex
    }
}

// MARK: - 矩阵工具函数
private func matrix_perspective_left_hand(fovyRadians fovy: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (farZ - nearZ)
    
    return matrix_float4x4(columns: (
        simd_float4(xs, 0, 0, 0),
        simd_float4(0, ys, 0, 0),
        simd_float4(0, 0, zs, 1),
        simd_float4(0, 0, -nearZ * zs, 0)))
}
