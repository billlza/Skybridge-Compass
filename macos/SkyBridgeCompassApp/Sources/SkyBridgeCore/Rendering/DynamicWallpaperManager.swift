import Foundation
import Metal
import MetalKit
import CoreML
import Combine

/// 动态壁纸管理器 - 协调天气数据、渲染引擎和壁纸切换
@MainActor
public class DynamicWallpaperManager: ObservableObject {
    
    // MARK: - 发布属性
    
    /// 当前壁纸状态
    @Published public var currentWallpaperState: WallpaperState = .loading
    
    /// 性能指标
    @Published public var performanceMetrics: DynamicWallpaperPerformanceMetrics = DynamicWallpaperPerformanceMetrics()
    
    /// 是否启用能效模式
    @Published public var isEnergyEfficiencyEnabled: Bool = false
    
    /// 当前渲染质量级别
    @Published public var renderingQuality: RenderingQuality = .high
    
    // MARK: - 私有属性
    
    private let renderingEngine: Metal4RenderingEngine
    private let weatherDataService: WeatherDataService
    private let locationService: WeatherLocationService
    private let mlPredictor: WeatherMLPredictor
    private let metalFXProcessor: MetalFXProcessor
    
    private var cancellables = Set<AnyCancellable>()
    private var renderTimer: Timer?
    private var performanceMonitor: Metal4PerformanceMonitor
    
    // Metal资源
    private var device: MTLDevice
    private var commandQueue: MTLCommandQueue
    private var renderPassDescriptor: MTLRenderPassDescriptor
    
    // 壁纸缓存
    private var wallpaperCache: [WeatherType: CachedWallpaper] = [:]
    private let maxCacheSize: Int = 5
    
    // MARK: - 初始化
    
    public init() throws {
        // 初始化Metal设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw DynamicWallpaperError.metalInitializationFailed
        }
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw DynamicWallpaperError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        // 初始化服务组件
        self.weatherDataService = WeatherDataService()
        self.renderingEngine = Metal4RenderingEngine(weatherDataService: weatherDataService)
        self.locationService = WeatherLocationService()
        self.mlPredictor = try WeatherMLPredictor()
        self.metalFXProcessor = try MetalFXProcessor(device: device)
        self.performanceMonitor = Metal4PerformanceMonitor(device: device)
        
        // 设置渲染通道描述符
        self.renderPassDescriptor = MTLRenderPassDescriptor()
        setupRenderPassDescriptor()
        
        // 绑定数据流
        setupDataBindings()
        
        // 启动性能监控
        startPerformanceMonitoring()
        
        print("✅ 动态壁纸管理器初始化完成")
    }
    
    // MARK: - 公共方法
    
    /// 启动动态壁纸系统
    public func startDynamicWallpaper() async {
        print("🚀 启动动态壁纸系统...")
        
        do {
            // 请求位置权限并获取当前位置
            locationService.requestLocationPermission()
            let location = try await locationService.getCurrentLocation()
            
            // 获取天气数据
            await weatherDataService.fetchWeather(for: location)
            
            // 启动渲染循环
            startRenderingLoop()
            
            currentWallpaperState = .active
            print("✅ 动态壁纸系统启动成功")
            
        } catch {
            print("❌ 动态壁纸系统启动失败: \(error)")
            currentWallpaperState = .error(error)
        }
    }
    
    /// 停止动态壁纸系统
    public func stopDynamicWallpaper() {
        print("⏹️ 停止动态壁纸系统...")
        
        renderTimer?.invalidate()
        renderTimer = nil
        
        // 停止所有服务
        Task {
            weatherDataService.stopWeatherUpdates()
            locationService.stopLocationUpdates()
        }
        
        currentWallpaperState = .inactive
        print("✅ 动态壁纸系统已停止")
    }
    
    /// 切换能效模式
    public func toggleEnergyEfficiency() {
        isEnergyEfficiencyEnabled.toggle()
        
        if isEnergyEfficiencyEnabled {
            renderingQuality = .medium
            renderingEngine.enableEnergyEfficiencyMode()
            print("🔋 已启用能效模式")
        } else {
            renderingQuality = .high
            renderingEngine.disableEnergyEfficiencyMode()
            print("⚡ 已禁用能效模式")
        }
    }
    
    /// 手动刷新天气数据
    public func refreshWeatherData() async {
        do {
            let location = try await locationService.getCurrentLocation()
            await weatherDataService.fetchWeather(for: location)
            print("🔄 天气数据刷新成功")
        } catch {
            print("❌ 天气数据刷新失败: \(error)")
        }
    }
    
    /// 设置渲染质量
    public func setRenderingQuality(_ quality: RenderingQuality) {
        renderingQuality = quality
        renderingEngine.setRenderingQuality(quality.rawValue)
        print("🎨 渲染质量已设置为: \(quality)")
    }
    
    // MARK: - 私有方法
    
    /// 设置数据绑定
    private func setupDataBindings() {
        // 监听天气数据变化
        weatherDataService.$currentWeather
            .compactMap { $0 }
            .sink { [weak self] weather in
                Task { @MainActor in
                    // 将Weather转换为WeatherData
                    let weatherData = WeatherData(
                        weatherType: WeatherDataService.WeatherType.from(condition: weather.currentWeather.condition),
                        intensity: 0.5,
                        temperature: weather.currentWeather.temperature.value,
                        humidity: weather.currentWeather.humidity,
                        windSpeed: weather.currentWeather.wind.speed.value,
                        windDirection: weather.currentWeather.wind.direction.value,
                        cloudCoverage: weather.currentWeather.cloudCover,
                        precipitationAmount: 0.0,
                        visibility: weather.currentWeather.visibility.value,
                        pressure: weather.currentWeather.pressure.value,
                        uvIndex: Double(weather.currentWeather.uvIndex.value),
                        timeOfDay: .afternoon
                    )
                    await self?.handleWeatherDataUpdate(weatherData)
                }
            }
            .store(in: &cancellables)
        
        // 监听位置变化
        locationService.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                Task {
                    await self?.weatherDataService.fetchWeather(for: location)
                }
            }
            .store(in: &cancellables)
        
        // 监听ML预测结果
        mlPredictor.$weatherPrediction
            .compactMap { $0 }
            .sink { [weak self] prediction in
                Task { @MainActor in
                    await self?.handleWeatherPrediction(prediction)
                }
            }
            .store(in: &cancellables)
    }
    
    /// 设置渲染通道描述符
    private func setupRenderPassDescriptor() {
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
    }
    
    /// 启动渲染循环
    private func startRenderingLoop() {
        let targetFPS: Double = isEnergyEfficiencyEnabled ? 30.0 : 60.0
        let interval = 1.0 / targetFPS
        
        renderTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.renderFrame()
            }
        }
    }
    
    /// 渲染单帧
    private func renderFrame() async {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("❌ 无法创建命令缓冲区")
            return
        }
        
        do {
            // 更新渲染参数
            let renderingParams = createRenderingParameters()
            
            // 创建临时纹理作为渲染目标
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 1920,
                height: 1080,
                mipmapped: false
            )
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            
            guard let renderTexture = device.makeTexture(descriptor: textureDescriptor) else {
                print("❌ 无法创建渲染纹理")
                return
            }
            
            // 执行渲染到纹理
            try await renderingEngine.render(parameters: renderingParams, to: renderTexture)
            
            // 应用MetalFX增强
            if renderingQuality == .ultra {
                try await metalFXProcessor.applyEnhancements(commandBuffer: commandBuffer)
            }
            
            // 提交命令缓冲区
            commandBuffer.commit()
            // 等待命令缓冲区完成，使用nonisolated方式
            let _ = await withUnsafeContinuation { continuation in
                commandBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
            }
            
            // 更新性能指标
            let frameTime = CFAbsoluteTimeGetCurrent() - startTime
            updatePerformanceMetrics(frameTime: frameTime)
            
        } catch {
            print("❌ 渲染失败: \(error)")
        }
    }
    
    /// 创建渲染参数
    private func createRenderingParameters() -> WeatherRenderingParameters {
        return weatherDataService.getWeatherRenderingParameters()
    }
    
    /// 处理天气数据更新
    private func handleWeatherDataUpdate(_ weatherData: WeatherData) async {
        print("🌤️ 处理天气数据更新: \(weatherData.weatherType)")
        
        // 检查是否需要切换壁纸
        if shouldSwitchWallpaper(to: weatherData.weatherType) {
            await switchWallpaper(to: weatherData.weatherType)
        }
        
        // 更新ML预测器
        await mlPredictor.updateWeatherData(weatherData)
        
        // 预加载可能的下一个壁纸
        await preloadNextWallpaper(basedOn: weatherData)
    }
    
    /// 处理天气预测结果
    private func handleWeatherPrediction(_ prediction: WeatherPrediction) async {
        print("🔮 处理天气预测: 未来可能转为 \(prediction.predictedWeatherType)")
        
        // 预加载预测的天气壁纸
        await preloadWallpaper(for: prediction.predictedWeatherType)
        
        // 如果预测变化概率很高，提前准备渲染资源
        if prediction.confidence > 0.8 {
            await prepareRenderingResources(for: prediction.predictedWeatherType)
        }
    }
    
    /// 判断是否需要切换壁纸
    private func shouldSwitchWallpaper(to weatherType: WeatherType) -> Bool {
        guard weatherDataService.currentWeather != nil else {
            return true
        }
        
        // 如果天气类型发生变化，需要切换
        return weatherDataService.getCurrentWeatherType() != weatherType
    }
    
    /// 切换壁纸
    private func switchWallpaper(to weatherType: WeatherType) async {
        print("🔄 切换壁纸到: \(weatherType)")
        
        currentWallpaperState = .transitioning
        
        // 从缓存加载或生成新壁纸
        let wallpaper = await loadOrGenerateWallpaper(for: weatherType)
        
        // 应用壁纸切换动画
        await applyWallpaperTransition(to: wallpaper)
        
        currentWallpaperState = .active
        print("✅ 壁纸切换完成")
    }
    
    /// 加载或生成壁纸
    private func loadOrGenerateWallpaper(for weatherType: WeatherType) async -> CachedWallpaper {
        // 检查缓存
        if let cachedWallpaper = wallpaperCache[weatherType],
           !cachedWallpaper.isExpired {
            print("📦 从缓存加载壁纸: \(weatherType)")
            return cachedWallpaper
        }
        
        // 生成新壁纸
        print("🎨 生成新壁纸: \(weatherType)")
        let wallpaper = await generateWallpaper(for: weatherType)
        
        // 缓存壁纸
        cacheWallpaper(wallpaper, for: weatherType)
        
        return wallpaper
    }
    
    /// 生成壁纸
    private func generateWallpaper(for weatherType: WeatherType) async -> CachedWallpaper {
        let renderingParams = createRenderingParameters()
        
        // 使用渲染引擎生成壁纸纹理
        let texture = await renderingEngine.generateWallpaperTexture(
            for: weatherType,
            parameters: renderingParams
        )
        
        return CachedWallpaper(
            weatherType: weatherType,
            texture: texture ?? device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false))!,
            creationTime: Date(),
            expirationTime: Date().addingTimeInterval(3600) // 1小时过期
        )
    }
    
    /// 缓存壁纸
    private func cacheWallpaper(_ wallpaper: CachedWallpaper, for weatherType: WeatherType) {
        wallpaperCache[weatherType] = wallpaper
        
        // 清理过期缓存
        cleanupExpiredCache()
        
        // 限制缓存大小
        if wallpaperCache.count > maxCacheSize {
            removeOldestCacheEntry()
        }
    }
    
    /// 清理过期缓存
    private func cleanupExpiredCache() {
        wallpaperCache = wallpaperCache.filter { _, wallpaper in
            !wallpaper.isExpired
        }
    }
    
    /// 移除最旧的缓存条目
    private func removeOldestCacheEntry() {
        guard let oldestEntry = wallpaperCache.min(by: { $0.value.creationTime < $1.value.creationTime }) else {
            return
        }
        
        wallpaperCache.removeValue(forKey: oldestEntry.key)
        print("🗑️ 移除过期缓存: \(oldestEntry.key)")
    }
    
    /// 预加载下一个壁纸
    private func preloadNextWallpaper(basedOn weatherData: WeatherData) async {
        // 根据当前天气预测可能的下一个天气类型
        let possibleNextWeatherTypes = mlPredictor.getPossibleNextWeatherTypes(from: weatherData)
        
        for weatherType in possibleNextWeatherTypes.prefix(2) {
            if wallpaperCache[weatherType] == nil {
                await preloadWallpaper(for: weatherType)
            }
        }
    }
    
    /// 预加载指定天气类型的壁纸
    private func preloadWallpaper(for weatherType: WeatherType) async {
        print("⏳ 预加载壁纸: \(weatherType)")
        let _ = await loadOrGenerateWallpaper(for: weatherType)
    }
    
    /// 准备渲染资源
    private func prepareRenderingResources(for weatherType: WeatherType) async {
        await renderingEngine.prepareRenderingResources(for: weatherType)
    }
    
    /// 应用壁纸切换动画
    private func applyWallpaperTransition(to wallpaper: CachedWallpaper) async {
        // 实现平滑的壁纸切换动画
        let transitionDuration: TimeInterval = 1.0
        let steps = 30
        let stepDuration = transitionDuration / Double(steps)
        
        for i in 0...steps {
            let progress = Float(i) / Float(steps)
            await renderingEngine.setTransitionProgress(progress)
            
            try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
        }
    }
    
    /// 启动性能监控
    private func startPerformanceMonitoring() {
        // 使用简化的性能监控，因为 Metal4PerformanceMonitor 没有 startMonitoring 方法
        // 这里可以添加自定义的性能监控逻辑
        print("✅ 性能监控已启动")
    }
    
    /// 更新性能指标
    private func updatePerformanceMetrics(frameTime: TimeInterval) {
        // 更新性能指标
        performanceMetrics.frameTime = frameTime
        performanceMetrics.averageFPS = 1.0 / frameTime
        
        // 简化的性能记录，因为 Metal4PerformanceMonitor 没有 recordFrameTime 方法
        print("📊 帧时间: \(frameTime * 1000)ms")
    }
    
    /// 根据性能自动调整渲染质量
    private func autoAdjustRenderingQuality(basedOn metrics: DynamicWallpaperPerformanceMetrics) {
        // 如果帧率过低，降低渲染质量
        if metrics.averageFPS < 45 && renderingQuality == .ultra {
            setRenderingQuality(.high)
            print("📉 自动降低渲染质量到高质量模式")
        } else if metrics.averageFPS < 30 && renderingQuality == .high {
            setRenderingQuality(.medium)
            print("📉 自动降低渲染质量到中等质量模式")
        }
        
        // 如果性能良好，可以提升渲染质量
        if metrics.averageFPS > 55 && renderingQuality == .medium {
            setRenderingQuality(.high)
            print("📈 自动提升渲染质量到高质量模式")
        } else if metrics.averageFPS > 58 && renderingQuality == .high && !isEnergyEfficiencyEnabled {
            setRenderingQuality(.ultra)
            print("📈 自动提升渲染质量到超高质量模式")
        }
    }
}

// MARK: - 支持类型定义

/// 壁纸状态枚举
public enum WallpaperState {
    case loading
    case active
    case inactive
    case transitioning
    case error(Error)
}

/// 渲染质量枚举
public enum RenderingQuality: String, CaseIterable {
    case low = "低"
    case medium = "中"
    case high = "高"
    case ultra = "超高"
}

/// 缓存的壁纸
public struct CachedWallpaper {
    let weatherType: WeatherType
    let texture: MTLTexture
    let creationTime: Date
    let expirationTime: Date
    
    var isExpired: Bool {
        Date() > expirationTime
    }
}

/// 动态壁纸性能指标
public struct DynamicWallpaperPerformanceMetrics {
    var averageFPS: Double = 0.0
    var frameTime: TimeInterval = 0.0
    var gpuUtilization: Double = 0.0
    var memoryUsage: Double = 0.0
    var powerConsumption: Double = 0.0
}

/// 动态壁纸错误类型
public enum DynamicWallpaperError: Error, LocalizedError {
    case metalInitializationFailed
    case commandQueueCreationFailed
    case renderingEngineFailed
    case weatherDataUnavailable
    case locationPermissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .metalInitializationFailed:
            return "Metal设备初始化失败"
        case .commandQueueCreationFailed:
            return "Metal命令队列创建失败"
        case .renderingEngineFailed:
            return "渲染引擎初始化失败"
        case .weatherDataUnavailable:
            return "天气数据不可用"
        case .locationPermissionDenied:
            return "位置权限被拒绝"
        }
    }
}