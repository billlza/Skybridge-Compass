import Foundation
import Metal
import MetalKit
import simd
import CoreLocation
import WeatherKit
import Combine
import os.log

/// 交互式天气粒子系统 - 基于实时天气数据生成交互式粒子效果
@MainActor
public class InteractiveWeatherParticleSystem: ObservableObject {
    
    // MARK: - 发布属性
    @Published public private(set) var isActive: Bool = false
    @Published public private(set) var currentWeatherType: WeatherDataService.WeatherType = .clear
    @Published public private(set) var particleCount: Int = 0
    @Published public private(set) var mousePosition: CGPoint = .zero
    
    // MARK: - Metal资源
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var particleBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var weatherParametersBuffer: MTLBuffer?
    private var mouseInteractionBuffer: MTLBuffer?
    
    // MARK: - 计算管线
    private var particleUpdatePipeline: MTLComputePipelineState?
    private var particleRenderPipeline: MTLRenderPipelineState?
    
    // MARK: - 粒子系统参数
    private let maxParticles: Int = 10000
    private var particles: [WeatherParticle] = []
    private var lastUpdateTime: CFTimeInterval = 0
    
    // MARK: - 天气数据服务
    private let weatherDataService: WeatherDataService
    
    // MARK: - 鼠标交互参数
    private var mouseInfluenceRadius: Float = 100.0
    private var mouseRepelForce: Float = 50.0
    private var mouseBlurRadius: Float = 20.0
    private var mouseAttractForce: Float = 30.0  // 新增：鼠标吸引力
    private var mistBlurIntensity: Float = 0.8   // 新增：薄雾模糊强度
    private var particleDispersionRadius: Float = 150.0  // 新增：粒子驱散半径
    private var isMousePressed: Bool = false     // 新增：鼠标按下状态
    private var mouseVelocity: CGPoint = .zero   // 新增：鼠标速度
    private var lastMousePosition: CGPoint = .zero // 新增：上次鼠标位置
    
    // MARK: - 日志
    private let logger = Logger(subsystem: "SkyBridgeCore", category: "WeatherParticleSystem")
    
    // MARK: - 初始化
    public init(device: MTLDevice, weatherDataService: WeatherDataService) throws {
        self.device = device
        self.weatherDataService = weatherDataService
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw WeatherParticleError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        try setupMetalResources()
        try setupComputePipelines()
        setupWeatherObserver()
        
        logger.info("🎨 交互式天气粒子系统初始化完成")
    }
    
    // MARK: - 公共方法
    
    /// 启动粒子系统
    public func start() {
        guard !isActive else { return }
        
        isActive = true
        lastUpdateTime = CACurrentMediaTime()
        
        // 根据当前天气初始化粒子
        let weatherType = weatherDataService.getCurrentWeatherType()
        initializeParticlesForWeather(weatherType)
        
        logger.info("🚀 天气粒子系统已启动")
    }
    
    /// 停止粒子系统
    public func stop() {
        guard isActive else { return }
        
        isActive = false
        particles.removeAll()
        particleCount = 0
        
        logger.info("⏹️ 天气粒子系统已停止")
    }
    
    /// 更新鼠标位置
    public func updateMousePosition(_ position: CGPoint) {
        // 计算鼠标速度
        let deltaX = position.x - lastMousePosition.x
        let deltaY = position.y - lastMousePosition.y
        mouseVelocity = CGPoint(x: deltaX, y: deltaY)
        
        lastMousePosition = mousePosition
        mousePosition = position
        updateMouseInteractionBuffer()
    }
    
    /// 设置鼠标按下状态
    public func setMousePressed(_ pressed: Bool) {
        isMousePressed = pressed
        updateMouseInteractionBuffer()
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
        if let radius = influenceRadius { mouseInfluenceRadius = radius }
        if let repel = repelForce { mouseRepelForce = repel }
        if let attract = attractForce { mouseAttractForce = attract }
        if let blur = blurRadius { mouseBlurRadius = blur }
        if let mist = mistBlurIntensity { self.mistBlurIntensity = mist }
        if let dispersion = dispersionRadius { particleDispersionRadius = dispersion }
        
        updateMouseInteractionBuffer()
    }
    
    /// 渲染粒子系统
    public func render(in renderEncoder: MTLRenderCommandEncoder, viewMatrix: matrix_float4x4, projectionMatrix: matrix_float4x4) {
        guard isActive, let particleRenderPipeline = particleRenderPipeline else { return }
        
        // 更新粒子
        updateParticles()
        
        // 设置渲染管线
        renderEncoder.setRenderPipelineState(particleRenderPipeline)
        
        // 绑定缓冲区
        if let particleBuffer = particleBuffer {
            renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        }
        
        if let uniformBuffer = uniformBuffer {
            updateUniformBuffer(viewMatrix: viewMatrix, projectionMatrix: projectionMatrix)
            renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        }
        
        // 绘制粒子
        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particles.count)
    }
    
    // MARK: - 私有方法
    
    /// 设置Metal资源
    private func setupMetalResources() throws {
        // 创建粒子缓冲区
        let particleBufferSize = maxParticles * MemoryLayout<WeatherParticle>.stride
        guard let particleBuffer = device.makeBuffer(length: particleBufferSize, options: .storageModeShared) else {
            throw WeatherParticleError.bufferCreationFailed
        }
        self.particleBuffer = particleBuffer
        
        // 创建Uniform缓冲区
        let uniformBufferSize = MemoryLayout<ParticleUniformData>.stride
        guard let uniformBuffer = device.makeBuffer(length: uniformBufferSize, options: .storageModeShared) else {
            throw WeatherParticleError.bufferCreationFailed
        }
        self.uniformBuffer = uniformBuffer
        
        // 创建天气参数缓冲区
        let weatherBufferSize = MemoryLayout<WeatherParametersData>.stride
        guard let weatherBuffer = device.makeBuffer(length: weatherBufferSize, options: .storageModeShared) else {
            throw WeatherParticleError.bufferCreationFailed
        }
        self.weatherParametersBuffer = weatherBuffer
        
        // 创建鼠标交互缓冲区
        let mouseBufferSize = MemoryLayout<MouseInteractionData>.stride
        guard let mouseBuffer = device.makeBuffer(length: mouseBufferSize, options: .storageModeShared) else {
            throw WeatherParticleError.bufferCreationFailed
        }
        self.mouseInteractionBuffer = mouseBuffer
    }
    
    /// 设置计算管线
    private func setupComputePipelines() throws {
        guard let library = device.makeDefaultLibrary() else {
            throw WeatherParticleError.shaderLibraryCreationFailed
        }
        
        // 粒子更新计算着色器
        guard let updateFunction = library.makeFunction(name: "weather_particle_update") else {
            throw WeatherParticleError.shaderFunctionNotFound
        }
        
        particleUpdatePipeline = try device.makeComputePipelineState(function: updateFunction)
        
        // 粒子渲染管线
        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        renderPipelineDescriptor.vertexFunction = library.makeFunction(name: "weather_particle_vertex")
        renderPipelineDescriptor.fragmentFunction = library.makeFunction(name: "weather_particle_fragment")
        renderPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        renderPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        renderPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        particleRenderPipeline = try device.makeRenderPipelineState(descriptor: renderPipelineDescriptor)
    }
    
    /// 设置天气观察者
    private func setupWeatherObserver() {
        // 监听天气数据变化
        weatherDataService.$currentWeather
            .compactMap { $0 }
            .sink { [weak self] weather in
                Task { @MainActor in
                    await self?.handleWeatherChange(weather)
                }
            }
            .store(in: &cancellables)
    }
    
    /// 处理天气变化
    private func handleWeatherChange(_ weather: Weather) async {
        let newWeatherType = WeatherDataService.WeatherType.from(condition: weather.currentWeather.condition)
        
        if newWeatherType != currentWeatherType {
            currentWeatherType = newWeatherType
            
            // 平滑过渡到新的天气粒子效果
            await transitionToWeatherType(newWeatherType)
            
            logger.info("🌤️ 天气粒子效果已切换到: \(newWeatherType.displayName)")
        }
        
        // 更新天气参数
        updateWeatherParametersBuffer()
    }
    
    /// 初始化特定天气的粒子
    private func initializeParticlesForWeather(_ weatherType: WeatherDataService.WeatherType) {
        particles.removeAll()
        
        let particleCount = getParticleCountForWeather(weatherType)
        
        for i in 0..<particleCount {
            let particle = createParticleForWeather(weatherType, index: i)
            particles.append(particle)
        }
        
        self.particleCount = particles.count
        updateParticleBuffer()
    }
    
    /// 获取特定天气的粒子数量
    private func getParticleCountForWeather(_ weatherType: WeatherDataService.WeatherType) -> Int {
        switch weatherType {
        case .snow, .heavySnow:
            return weatherType == .heavySnow ? 8000 : 4000
        case .rain, .heavyRain:
            return weatherType == .heavyRain ? 6000 : 3000
        case .fog:
            return 2000
        case .haze:  // 新增雾霾粒子数量
            return 3000  // 雾霾粒子数量比雾稍多，营造更浓重的效果
        case .cloudy, .partlyCloudy:
            return 1000
        default:
            return 500
        }
    }
    
    /// 为特定天气创建粒子
    private func createParticleForWeather(_ weatherType: WeatherDataService.WeatherType, index: Int) -> WeatherParticle {
        let position = simd_float3(
            Float.random(in: -20...20),
            Float.random(in: 0...15),
            Float.random(in: -20...20)
        )
        
        let velocity: simd_float3
        let color: simd_float4
        let size: Float
        let life: Float
        let particleType: Int32
        
        switch weatherType {
        case .rain, .heavyRain:
            velocity = simd_float3(0, -8.0, 0)
            color = simd_float4(0.7, 0.8, 1.0, 0.8)
            size = weatherType == .heavyRain ? 1.2 : 0.8
            life = Float.random(in: 2...5)
            particleType = 0 // 雨滴
            
        case .snow, .heavySnow:
            velocity = simd_float3(0, -2.0, 0)
            color = simd_float4(1.0, 1.0, 1.0, 0.9)
            size = weatherType == .heavySnow ? 1.8 : 1.2
            life = Float.random(in: 3...8)
            particleType = 1 // 雪花
            
        case .fog:
            velocity = simd_float3(
                Float.random(in: -0.5...0.5),
                Float.random(in: -0.2...0.2),
                Float.random(in: -0.5...0.5)
            )
            color = simd_float4(0.9, 0.9, 0.9, 0.3)
            size = Float.random(in: 2.0...4.0)
            life = Float.random(in: 8...15)
            particleType = 3 // 雾气
            
        case .haze:  // 新增雾霾粒子创建逻辑
            velocity = simd_float3(
                Float.random(in: -0.3...0.3),
                Float.random(in: -0.1...0.1),
                Float.random(in: -0.3...0.3)
            )
            // 雾霾粒子颜色 - 黄灰色调，透明度较低营造朦胧感
            color = simd_float4(0.8, 0.7, 0.5, 0.25)
            size = Float.random(in: 1.5...3.5)
            life = Float.random(in: 10...20)  // 雾霾粒子存在时间较长
            particleType = 4 // 雾霾粒子（新类型）
            
        case .cloudy, .partlyCloudy:
            velocity = simd_float3(
                Float.random(in: -1.0...1.0),
                Float.random(in: -0.5...0.5),
                Float.random(in: -1.0...1.0)
            )
            color = simd_float4(0.8, 0.8, 0.8, 0.4)
            size = Float.random(in: 3.0...6.0)
            life = Float.random(in: 5...12)
            particleType = 2 // 云朵
            
        case .thunderstorm:
            velocity = simd_float3(0, -12.0, 0)
            color = simd_float4(0.5, 0.6, 0.9, 0.9)
            size = 1.0
            life = Float.random(in: 1...3)
            particleType = 0 // 雨滴
            
        default:
            velocity = simd_float3(0, -1.0, 0)
            color = simd_float4(0.8, 0.8, 0.8, 0.5)
            size = 0.6
            life = Float.random(in: 2...6)
            particleType = 3 // 默认雾气
        }
        
        return WeatherParticle(
            position: position,
            velocity: velocity,
            color: color,
            size: size,
            life: life,
            maxLife: life,
            type: particleType
        )
    }
    
    /// 平滑过渡到新天气类型
    private func transitionToWeatherType(_ weatherType: WeatherDataService.WeatherType) async {
        // 实现粒子效果的平滑过渡
        let targetCount = getParticleCountForWeather(weatherType)
        
        // 如果需要更多粒子，添加新粒子
        while particles.count < targetCount {
            let particle = createParticleForWeather(weatherType, index: particles.count)
            particles.append(particle)
        }
        
        // 如果粒子太多，逐渐移除
        if particles.count > targetCount {
            particles = Array(particles.prefix(targetCount))
        }
        
        // 更新现有粒子的属性以匹配新天气
        for i in 0..<particles.count {
            updateParticleForWeatherTransition(&particles[i], weatherType: weatherType)
        }
        
        particleCount = particles.count
        updateParticleBuffer()
    }
    
    /// 更新粒子以适应天气过渡
    private func updateParticleForWeatherTransition(_ particle: inout WeatherParticle, weatherType: WeatherDataService.WeatherType) {
        // 平滑过渡粒子属性
        switch weatherType {
        case .snow, .heavySnow:
            particle.type = 1
            particle.color = simd_mix(particle.color, simd_float4(0.9, 0.95, 1.0, 0.8), simd_float4(0.1, 0.1, 0.1, 0.1))
            
        case .rain, .heavyRain:
            particle.type = 0
            particle.color = simd_mix(particle.color, simd_float4(0.6, 0.8, 1.0, 0.7), simd_float4(0.1, 0.1, 0.1, 0.1))
            
        case .fog:
            particle.type = 3
            particle.color = simd_mix(particle.color, simd_float4(0.8, 0.8, 0.9, 0.3), simd_float4(0.1, 0.1, 0.1, 0.1))
            
        default:
            particle.type = 2
            particle.color = simd_mix(particle.color, simd_float4(1, 1, 1, 0.5), simd_float4(0.1, 0.1, 0.1, 0.1))
        }
    }
    
    /// 更新粒子
    private func updateParticles() {
        let currentTime = CACurrentMediaTime()
        let deltaTime = Float(currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
              let updatePipeline = particleUpdatePipeline else { return }
        
        // 设置计算管线
        computeEncoder.setComputePipelineState(updatePipeline)
        
        // 绑定缓冲区
        if let particleBuffer = particleBuffer {
            computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
        }
        
        if let weatherBuffer = weatherParametersBuffer {
            computeEncoder.setBuffer(weatherBuffer, offset: 0, index: 1)
        }
        
        if let mouseBuffer = mouseInteractionBuffer {
            computeEncoder.setBuffer(mouseBuffer, offset: 0, index: 2)
        }
        
        // 设置时间参数
        var timeData = TimeData(time: Float(currentTime), deltaTime: deltaTime)
        computeEncoder.setBytes(&timeData, length: MemoryLayout<TimeData>.stride, index: 3)
        
        // 执行计算
        let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        let threadGroups = MTLSize(width: (particles.count + 63) / 64, height: 1, depth: 1)
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
    }
    
    /// 更新粒子缓冲区
    private func updateParticleBuffer() {
        guard let buffer = particleBuffer else { return }
        
        let bufferPointer = buffer.contents().bindMemory(to: WeatherParticle.self, capacity: maxParticles)
        for (index, particle) in particles.enumerated() {
            bufferPointer[index] = particle
        }
    }
    
    /// 更新Uniform缓冲区
    private func updateUniformBuffer(viewMatrix: matrix_float4x4, projectionMatrix: matrix_float4x4) {
        guard let buffer = uniformBuffer else { return }
        
        let uniformData = ParticleUniformData(
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            time: Float(CACurrentMediaTime()),
            deltaTime: 1.0/60.0
        )
        
        let bufferPointer = buffer.contents().bindMemory(to: ParticleUniformData.self, capacity: 1)
        bufferPointer[0] = uniformData
    }
    
    /// 更新天气参数缓冲区
    private func updateWeatherParametersBuffer() {
        guard let buffer = weatherParametersBuffer else { return }
        
        let weatherParams = weatherDataService.getWeatherRenderingParameters()
        let weatherData = WeatherParametersData(
            weatherType: Int32(weatherParams.weatherType.hashValue),
            intensity: Float(weatherParams.intensity),
            temperature: Float(weatherParams.temperature),
            humidity: Float(weatherParams.humidity),
            windSpeed: Float(weatherParams.windSpeed),
            windDirection: Float(weatherParams.windDirection),
            visibility: Float(weatherParams.visibility)
        )
        
        let bufferPointer = buffer.contents().bindMemory(to: WeatherParametersData.self, capacity: 1)
        bufferPointer[0] = weatherData
    }
    
    /// 更新鼠标交互缓冲区
    private func updateMouseInteractionBuffer() {
        guard let buffer = mouseInteractionBuffer else { return }
        
        let mouseData = EnhancedMouseInteractionData(
            mousePosition: simd_float2(Float(mousePosition.x), Float(mousePosition.y)),
            mouseVelocity: simd_float2(Float(mouseVelocity.x), Float(mouseVelocity.y)),
            influenceRadius: mouseInfluenceRadius,
            repelForce: mouseRepelForce,
            attractForce: mouseAttractForce,
            blurRadius: mouseBlurRadius,
            mistBlurIntensity: mistBlurIntensity,
            dispersionRadius: particleDispersionRadius,
            isPressed: isMousePressed ? 1 : 0,
            time: Float(CACurrentMediaTime())
        )
        
        let bufferPointer = buffer.contents().bindMemory(to: EnhancedMouseInteractionData.self, capacity: 1)
        bufferPointer[0] = mouseData
    }
    
    // MARK: - 私有属性
    private var cancellables = Set<AnyCancellable>()
}

// MARK: - 数据结构

/// 天气粒子结构
public struct WeatherParticle {
    var position: simd_float3
    var velocity: simd_float3
    var color: simd_float4
    var size: Float
    var life: Float
    var maxLife: Float
    var type: Int32 // 0=雨滴，1=雪花，2=云朵，3=雾气，4=雾霾
}

/// 粒子Uniform数据
private struct ParticleUniformData {
    let viewMatrix: matrix_float4x4
    let projectionMatrix: matrix_float4x4
    let time: Float
    let deltaTime: Float
}

/// 天气参数数据
private struct WeatherParametersData {
    let weatherType: Int32
    let intensity: Float
    let temperature: Float
    let humidity: Float
    let windSpeed: Float
    let windDirection: Float
    let visibility: Float
}

/// 鼠标交互数据
private struct MouseInteractionData {
    let mousePosition: simd_float2
    let influenceRadius: Float
    let repelForce: Float
    let blurRadius: Float
}

/// 时间数据
private struct TimeData {
    let time: Float
    let deltaTime: Float
}

// MARK: - 错误类型

public enum WeatherParticleError: Error, LocalizedError {
    case commandQueueCreationFailed
    case bufferCreationFailed
    case shaderLibraryCreationFailed
    case shaderFunctionNotFound
    
    public var errorDescription: String? {
        switch self {
        case .commandQueueCreationFailed:
            return "命令队列创建失败"
        case .bufferCreationFailed:
            return "缓冲区创建失败"
        case .shaderLibraryCreationFailed:
            return "着色器库创建失败"
        case .shaderFunctionNotFound:
            return "着色器函数未找到"
        }
    }
}

// MARK: - 扩展

extension WeatherDataService.WeatherType {
    /// 获取粒子效果的强度系数
    var particleIntensity: Float {
        switch self {
        case .heavyRain, .heavySnow:
            return 1.0
        case .rain, .snow, .thunderstorm:
            return 0.7
        case .fog, .cloudy:
            return 0.5
        case .partlyCloudy:
            return 0.3
        default:
            return 0.1
        }
    }
}

/// 增强的鼠标交互数据
private struct EnhancedMouseInteractionData {
    let mousePosition: simd_float2
    let mouseVelocity: simd_float2
    let influenceRadius: Float
    let repelForce: Float
    let attractForce: Float
    let blurRadius: Float
    let mistBlurIntensity: Float
    let dispersionRadius: Float
    let isPressed: Int32
    let time: Float
}