// macOS-exclusive: built on macOS-only APIs (AppKit / IOKit / ScreenCaptureKit / CoreWLAN /
// MetalFX / ServiceManagement / ApplicationServices / CoreGraphics display services).
// Excluded from other platforms so SkyBridgeCore can be the single shared core for iOS as
// well. No behaviour changes on macOS.
#if os(macOS)
//
// CinematicRainEffectView.swift
// SkyBridgeCompassApp
//
// 电影级真实感雨天效果 + 交互式粒子驱散
// Created: 2025-10-19
//

import SwiftUI
import Combine

/// 物理真实雨滴粒子
struct PhysicsRaindrop: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var velocityX: CGFloat  // 水平速度（受风影响）
    var velocityY: CGFloat  // 垂直速度（受重力影响）
    var acceleration: CGFloat = 980  // 重力加速度
    let mass: CGFloat  // 质量（影响惯性）
    var rotation: CGFloat = 0  // 旋转角度
    var deformation: CGFloat = 1.0  // 形变系数（下落时拉长）
    let baseLength: CGFloat
    let thickness: CGFloat
    let opacity: Double
    let layer: Int  // 景深层次
    var trail: [CGPoint] = []  // 尾迹点
}

/// 动态玻璃水珠
struct DynamicGlassDrop: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var lifetime: TimeInterval
    var slideSpeed: CGFloat
}

/// 水面涟漪
struct CinematicRainWaterRipple: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    var radius: CGFloat
    var opacity: Double
    var lifetime: TimeInterval
}

/// 🌟 OPPO风格：挂壁水珠（附着在玻璃组件上，慢慢向下流动）
struct WallWaterDrop: Identifiable {
    let id = UUID()
    var x: CGFloat           // 水平位置（归一化或屏幕坐标）
    var y: CGFloat           // 垂直位置（归一化或屏幕坐标）
    var size: CGFloat        // 水珠大小
    var slideProgress: CGFloat = 0  // 下滑进度（0-1）
    var opacity: Double      // 透明度
    var glassRectIndex: Int  // 所属玻璃组件的索引（-1表示自由下落）
    var lifetime: TimeInterval = 0  // 存在时间
    let maxLifetime: TimeInterval    // 最大存在时间
    var accumulated: Bool = false   // 是否已累积（静态附着阶段）
    
 // 🌟 新增：物理状态
    enum DropState {
        case accumulating    // 累积阶段（静态附着）
        case sliding          // 下滑阶段（在玻璃上）
        case falling          // 自由下落阶段（脱离玻璃）
        case fading           // 淡出消失阶段
    }
    var state: DropState = .accumulating
    
 // 🌟 新增：形变参数（用于从玻璃滑到玻璃的形变效果）
    var deformationFactor: CGFloat = 1.0  // 形变因子（1.0=正常，>1.0=拉长）
    var velocityY: CGFloat = 0  // 下落速度（自由下落时使用）
    
 // 🌟 新增：是否使用屏幕坐标（false=归一化，true=屏幕坐标）
    var useScreenCoordinates: Bool = false
    
    init(x: CGFloat, y: CGFloat, size: CGFloat, glassRectIndex: Int) {
        self.x = x
        self.y = y
        self.size = size
        self.glassRectIndex = glassRectIndex
        self.opacity = Double.random(in: 0.6...0.9)
        self.maxLifetime = TimeInterval.random(in: 15...30)  // 15-30秒后消失
    }
}

/// 🌟 底部积水系统
struct CinematicRainWaterPuddle {
    var waterLevel: CGFloat = 0  // 水位高度（0-1，相对于屏幕底部）
    var maxWaterLevel: CGFloat = 0.08  // 最大水位（屏幕高度的8%）
    var ripples: [CinematicRainWaterRipple] = []  // 积水表面的涟漪
    var waveOffset: CGFloat = 0  // 水波动画偏移
    var reflectionOpacity: Double = 0.3  // 反射透明度
    
    mutating func addWater(amount: CGFloat) {
        waterLevel = min(waterLevel + amount, maxWaterLevel)
    }
    
    mutating func evaporate(rate: CGFloat) {
        waterLevel = max(0, waterLevel - rate)
    }
}

@available(macOS 14.0, *)
public struct CinematicRainEffectView: View {
 // 物理粒子状态
    @State private var raindrops: [PhysicsRaindrop] = []
    @State private var glassDrops: [DynamicGlassDrop] = []
    @State private var ripples: [CinematicRainWaterRipple] = []
    
 // 🌟 OPPO风格：挂壁水珠系统
    @State private var wallWaterDrops: [WallWaterDrop] = []
    
 // 🌟 底部积水系统
    @State private var waterPuddle = CinematicRainWaterPuddle()
    
 // 天气状态
    @State private var windSpeed: CGFloat = 0
    @State private var windDirection: CGFloat = 0
    @State private var lightningOpacity: Double = 0
    @State private var lastFrameTime: TimeInterval = 0
    
 // Perlin噪声云层
 // 云层噪声偏移改为纯时间驱动，不再持久化为状态，避免并发更新期间写入

 // MARK: - 远程桌面渲染暂停控制
 // 当远程桌面存在活跃会话时，暂停天气效果的所有绘制与状态更新；
 // 连接断开后自动恢复，避免与远程桌面高密度图形任务产生资源竞争。
    @State private var isRemoteDesktopActive: Bool = false
    
 // 交互式驱散管理器（由统一入口 WeatherEffectView 注入；避免重复创建/重复监听）
    @ObservedObject private var clearManager: InteractiveClearManager
    
 // UI组件边界检测（液态玻璃组件位置）
    @State private var glassComponentRects: [CGRect] = []
    
 // ✅ 窗口实际尺寸（用于修复窗口模式下的尺寸问题）
    @State private var currentWindowSize: CGSize = CGSize(width: 1920, height: 1080)
    
 // 性能配置
    @State private var performanceConfig: PerformanceConfiguration?
    
 // 🌟 动态帧率（根据性能模式）
    @State private var currentFrameRate: Double = 60.0
    
 // 统一计时器管理（远程桌面激活时集中暂停/恢复）
 // 说明：所有特效系统的计时器都以属性持有，便于在需要时取消，防止视图更新期间写入状态导致并发警告
    @State private var lightningTimer: Timer?
    @State private var windTimer: Timer?
    @State private var wallDropDetectTimer: Timer?
    @State private var wallDropUpdateTimer: Timer?
    @State private var waterPuddleTimer: Timer?
 // 🌬️ 风噪系统计时器与状态（用于调制雾效强度）
    @State private var windNoiseTimer: Timer?
    @State private var ambientWindNoiseLevel: Double = 0.0
 // ✨ 镜面反射闪烁计时器与调制因子（用于积水反射高光）
    @State private var reflectionFlickerTimer: Timer?
    @State private var reflectionFlickerFactor: Double = 1.0

 // 统一时间累加器（替换原有多个 Timer），借助 TimelineView 的帧节拍触发
    @State private var lastTick: Date = .now
    @State private var windAcc: TimeInterval = 0
    @State private var windNoiseAcc: TimeInterval = 0
    @State private var reflectionAcc: TimeInterval = 0
    @State private var wallUpdateAcc: TimeInterval = 0
    @State private var puddleAcc: TimeInterval = 0
    @State private var lightningAcc: TimeInterval = 0
    @State private var nextLightningInterval: TimeInterval = 8.0
    
 // 天气类型（用于区分普通雨天和暴风雨）
    @ObservedObject private var weatherManager = WeatherIntegrationManager.shared
    private var rainIntensity: RainIntensity {
        guard let weather = weatherManager.currentWeather else { return .normal }
        return weather.condition == .stormy ? .heavy : .normal
    }
    
 // 雨滴强度枚举
    private enum RainIntensity {
        case normal   // 普通雨天
        case heavy    // 暴风雨
        
        var velocityMultiplier: CGFloat {
            switch self {
            case .normal: return 1.0
            case .heavy: return 1.8  // 暴风雨速度更快
            }
        }
        
        var dropCountMultiplier: CGFloat {
            switch self {
            case .normal: return 1.0
            case .heavy: return 1.5  // 暴风雨雨滴更多
            }
        }
        
        var windMultiplier: CGFloat {
            switch self {
            case .normal: return 1.0
            case .heavy: return 2.5  // 暴风雨风力更强
            }
        }
    }
    
    public init(clearManager: InteractiveClearManager) {
        self.clearManager = clearManager
    }
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
 // 主雨天效果层
 // 🌟 动态帧率：根据性能模式设置（极致120fps，平衡60fps，节能30fps，自适应30-120fps）
                TimelineView(.animation(minimumInterval: 1.0/currentFrameRate)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
 // ✅ 捕获局部常量，避免在 Sendable 闭包中直接访问主线程隔离的 @State
                    let remoteActive = isRemoteDesktopActive
                    let _ = scheduleTick(remoteActive: remoteActive, now: timeline.date)
                    
                    Canvas { context, size in
 // 🔌 远程桌面处于活跃状态时，立即跳过本帧所有绘制（完全暂停渲染）
                        guard !remoteActive else { return }
 // 🌟 Apple Weather风格：在Canvas中基于时间直接计算位置，不依赖State更新
 // ✅ 使用实际窗口尺寸（Canvas的size参数），而不是硬编码的屏幕尺寸
 // 注意：currentWindowSize会在onChange中更新，用于检测函数
                        
 // 1. 先绘制物理模拟雨滴（最重要的效果）- 基于时间计算位置
                        drawRaindropsWithTime(context: &context, size: size, time: time)
                        
 // 2. 再绘制云层（半透明，不遮挡雨滴）- 保持不变
                        drawVolumetricClouds(context: &context, size: size, time: time)
                        
 // 3. 🌟 挂壁水珠（附着在玻璃组件上）
                        drawWallWaterDrops(context: &context, size: size, time: time)
                        
 // 4. 玻璃水珠（带物理下滑）
                        drawGlassDrops(context: &context, size: size)
                        
 // 5. 🌟 底部积水效果（水位 + 波纹）
                        drawWaterPuddle(context: &context, size: size, time: time)
                        
 // 6. 底部水面涟漪
                        drawRipples(context: &context, size: size)
                        
 // 7. 闪电效果 - 保持不变
                        if lightningOpacity > 0 {
                            context.fill(
                                Path(CGRect(origin: .zero, size: size)),
                                with: .color(.white.opacity(lightningOpacity * 0.8))
                            )
                        }
                        
 // 8. 大气效果（雾蒙蒙的感觉）
                        drawAtmosphericFog(context: &context, size: size, time: time)
                    }
 // 说明：体积云动画已改为纯时间驱动（见 drawVolumetricClouds），
 // 这里不再在视图更新期间写入任何 @State，避免并发告警。
                }
                .opacity(clearManager.globalOpacity)  // 🔥 驱散效果
            }
            .onAppear {
 // ✅ 保存窗口尺寸，用于检测函数
                currentWindowSize = geometry.size
            }
            .onChange(of: geometry.size) { oldSize, newSize in
 // ✅ 窗口尺寸变化时更新
                currentWindowSize = newSize
            }
        }
        .ignoresSafeArea()
        .task {
 // 先加载性能配置
            await loadPerformanceConfig()
 // 再初始化粒子
            initializeAdvancedParticles()
 // 移除所有 Timer 的启动，统一由 TimelineView 累加器驱动
            startParticleUpdateLoop()
 // 🔥 启动交互式清空管理器
 // start() 为同步方法，直接调用；移除不必要的 await。
            clearManager.start()
        }
        .onDisappear {
 // 🛑 视图消失时，统一暂停所有特效系统并释放计时器，避免资源泄漏
            pauseAllEffectSystems()
        }
 // 🔌 订阅远程桌面指标：有活跃会话即暂停天气效果渲染；断开后自动恢复
        .onReceive(RemoteDesktopManager.shared.metrics) { snapshot in
 // 说明：依赖 SkyBridgeCore 暴露的 AnyPublisher<RemoteMetricsSnapshot, Never>
 // 此处仅进行布尔门控，不做阻塞性操作，满足严格并发控制要求
            isRemoteDesktopActive = snapshot.activeSessions > 0
        }
 // 🌐 统一暂停/恢复：远程桌面状态变化时集中管理计时器，避免在视图更新期间写入状态
        .onChange(of: isRemoteDesktopActive) { oldValue, newValue in
            if newValue {
 // ⏸️ 远程桌面激活：取消所有计时器，完全暂停效果系统
                pauseAllEffectSystems()
            } else {
 // ▶️ 远程桌面不活跃：恢复计时器，继续效果系统
                resumeAllEffectSystems()
            }
        }
    }
    
 // MARK: - 性能配置加载
    
 /// 加载性能配置
    @MainActor
    private func loadPerformanceConfig() async {
        do {
            let manager = try PerformanceModeManager()
            performanceConfig = manager.currentConfiguration
            
 // 🌟 根据性能模式设置帧率
            updateFrameRateForPerformanceMode()
        } catch {
            SkyBridgeLogger.ui.error("⚠️ 无法获取PerformanceModeManager配置: \(error.localizedDescription, privacy: .private)")
 // 使用默认配置（平衡模式）
            performanceConfig = PerformanceConfiguration(
                renderScale: 0.85,
                maxParticles: 2000,
                targetFrameRate: 60,
                metalFXQuality: 0.7,
                shadowQuality: 1,
                postProcessingLevel: 1,
                gpuFrequencyHint: 0.7,
                memoryBudget: 1024
            )
            currentFrameRate = 60.0  // 默认平衡模式
        }
    }
    
 /// 根据性能模式更新帧率
    @MainActor
    private func updateFrameRateForPerformanceMode() {
        guard let config = performanceConfig else {
            currentFrameRate = 60.0
            return
        }
        
 // 获取当前性能模式
        do {
            let manager = try PerformanceModeManager()
            let currentMode = manager.currentMode
            
            switch currentMode {
            case .extreme:
 // 极致：120fps
                currentFrameRate = 120.0
            case .balanced:
 // 平衡：60fps
                currentFrameRate = 60.0
            case .energySaving:
 // 节能：30fps
                currentFrameRate = 30.0
            case .adaptive:
 // 自适应：30-120fps（根据系统负载动态调整）
 // 使用targetFrameRate作为动态值（已经在30-120范围内）
                currentFrameRate = min(max(Double(config.targetFrameRate), 30), 120)
            @unknown default:
                currentFrameRate = 60.0
            }
            
            #if DEBUG
            SkyBridgeLogger.ui.debugOnly("🎯 性能模式: \(currentMode) 帧率: \(Int(currentFrameRate))fps")
            #endif
        } catch {
 // 如果无法获取模式，根据targetFrameRate推断
            if config.targetFrameRate >= 100 {
                currentFrameRate = 120.0  // 极致
            } else if config.targetFrameRate >= 55 {
                currentFrameRate = 60.0   // 平衡
            } else {
                currentFrameRate = 30.0  // 节能
            }
        }
        
 // 对于自适应模式，启动动态帧率更新
        do {
            let manager = try PerformanceModeManager()
            if manager.currentMode == .adaptive {
                startAdaptiveFrameRateUpdate()
            }
        } catch {
 // 忽略错误
        }
    }
    
 /// 启动自适应帧率更新（30-120fps动态调整）
    private func startAdaptiveFrameRateUpdate() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            Task { @MainActor in
                guard let config = performanceConfig else { return }
                
 // 根据targetFrameRate动态调整（已在30-120范围内）
                let newFrameRate = min(max(Double(config.targetFrameRate), 30), 120)
                if abs(newFrameRate - currentFrameRate) > 5 {  // 只在变化超过5fps时更新
                    currentFrameRate = newFrameRate
                    #if DEBUG
                    SkyBridgeLogger.ui.debugOnly("🔄 自适应帧率更新: \(Int(currentFrameRate))fps")
                    #endif
                }
            }
        }
    }
    
 // MARK: - 粒子初始化
    
    private func initializeAdvancedParticles() {
 // 根据性能模式动态调整雨滴数量
        let (farCount, midCount, nearCount) = getPerformanceBasedCounts()
        
 // 获取性能配置，优化雨滴效果
        let qualityConfig = getQualityConfiguration()
        
 // 创建三层景深雨滴
        let layers: [(count: Int, layer: Int)] = [
            (farCount, 0),  // 远景
            (midCount, 1),  // 中景
            (nearCount, 2)  // 近景
        ]
        
        for (count, layer) in layers {
            let baseMass: CGFloat = layer == 0 ? 1.5 : (layer == 1 ? 1.0 : 0.7)
            
            for _ in 0..<count {
 // 🌟 修复：雨滴必须从云层（顶部，y < 0）开始
 // 根据景深层分配不同的初始高度：远景更高（更接近云层）
                let startY: CGFloat = layer == 0 ? CGFloat.random(in: -0.5 ... -0.1) :  // 远景从更高位置
                                      layer == 1 ? CGFloat.random(in: -0.3 ... -0.05) : // 中景
                                                    CGFloat.random(in: -0.2 ... -0.02)  // 近景
                
 // 注意：速度将在updateRaindropPhysics中根据屏幕尺寸归一化
 // 这里先使用像素单位，稍后会在首次物理更新时转换
                raindrops.append(PhysicsRaindrop(
                    x: CGFloat.random(in: 0...1),
                    y: startY,  // ✅ 从顶部云层开始
                    velocityX: CGFloat.random(in: -50...50),  // 将在物理更新中归一化
                    velocityY: CGFloat.random(in: 100...300),  // 将在物理更新中归一化，初速度较小，会受重力加速
                    mass: baseMass * CGFloat.random(in: 0.8...1.2),
                    baseLength: qualityConfig.baseLength * CGFloat.random(in: 0.8...1.2),  // 🌟 性能适配长度
                    thickness: qualityConfig.thickness(layer: layer),  // 🌟 性能适配厚度
                    opacity: qualityConfig.opacity(layer: layer),     // 🌟 性能适配透明度
                    layer: layer
                ))
            }
        }
        
 // 不预先创建玻璃水珠，改为由雨滴碰撞生成
 // glassDrops 从空数组开始，由雨滴碰撞动态生成
        
 // 初始化液态玻璃组件位置（模拟）
        detectGlassComponents()
        
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🌧️ 雨天效果初始化: 远景\(farCount) + 中景\(midCount) + 近景\(nearCount)")
        SkyBridgeLogger.ui.debugOnly("🎯 性能模式: \(qualityConfig.name)")
        #endif
    }
    
 /// 获取质量配置（根据性能模式）
    private func getQualityConfiguration() -> RainQualityConfig {
        guard let config = performanceConfig else {
            return RainQualityConfig.balanced
        }
        
        let targetFPS = config.targetFrameRate
        let totalParticles = config.maxParticles
        
        if targetFPS >= 120 && totalParticles >= 3000 {
            return .extreme  // 极致模式
        } else if targetFPS >= 60 && totalParticles >= 2000 {
            return .balanced  // 平衡模式
        } else if targetFPS >= 30 && totalParticles >= 1000 {
            return .energySaving  // 节能模式
        } else {
 // 🌟 自适应模式：根据实际配置动态选择介于极致和节能之间
            return calculateAdaptiveQuality(config: config)
        }
    }
    
 /// 计算自适应模式的质量等级（0.0-1.0，0=节能，1=极致）
    private func calculateAdaptiveQuality(config: PerformanceConfiguration) -> RainQualityConfig {
 // 根据实际配置计算质量等级
 // 使用帧率、粒子数和渲染质量作为指标
        
 // 归一化帧率 (30-120fps -> 0-1)
        let fpsNormalized = Float(config.targetFrameRate - 30) / Float(120 - 30)
        
 // 归一化粒子数 (1000-15000 -> 0-1)
        let particlesNormalized = Float(config.maxParticles - 1000) / Float(15000 - 1000)
        
 // 归一化渲染缩放 (0.5-1.0 -> 0-1)
        let scaleNormalized = Float(config.renderScale - 0.5) / Float(1.0 - 0.5)
        
 // 综合质量分数 (加权平均)
        let qualityScore = (fpsNormalized * 0.4 + particlesNormalized * 0.4 + scaleNormalized * 0.2)
        
 // 🌟 使用插值生成配置（在节能和极致之间平滑过渡）
        return RainQualityConfig(
            interpolationFactor: qualityScore,
            between: .energySaving,
            and: .extreme
        )
    }
    
 /// 根据性能配置获取粒子数量
    private func getPerformanceBasedCounts() -> (far: Int, mid: Int, near: Int) {
        guard let config = performanceConfig else {
 // 默认：平衡模式
            let (far, mid, near) = (80, 60, 40)
            return applyRainIntensity(far: far, mid: mid, near: near)
        }
        
 // 根据粒子总量和帧率计算
        let totalParticles = config.maxParticles
        
 // 根据性能模式分配粒子
        let (far, mid, near): (Int, Int, Int)
        if config.targetFrameRate >= 120 && totalParticles >= 3000 {
 // 极致模式：超高质量雨滴，完整的从云到地面效果
            (far, mid, near) = (200, 150, 100)  // 远景200 + 中景150 + 近景100 = 450
        } else if config.targetFrameRate >= 60 && totalParticles >= 2000 {
 // 平衡模式：标准雨滴
            (far, mid, near) = (100, 80, 50)    // 远景100 + 中景80 + 近景50 = 230
        } else if config.targetFrameRate >= 30 && totalParticles >= 1000 {
 // 节能模式：减少雨滴
            (far, mid, near) = (60, 40, 25)     // 远景60 + 中景40 + 近景25 = 125
        } else {
 // 🌟 自适应模式：根据实际配置在节能和极致之间动态调整
            (far, mid, near) = calculateAdaptiveParticleCounts(config: config)
        }
        
        return applyRainIntensity(far: far, mid: mid, near: near)
    }
    
 /// 根据雨滴强度调整数量
    private func applyRainIntensity(far: Int, mid: Int, near: Int) -> (Int, Int, Int) {
        let multiplier = Int(rainIntensity.dropCountMultiplier)
        return (far * multiplier, mid * multiplier, near * multiplier)
    }
    
 /// 计算自适应模式的粒子数量（在节能和极致之间平滑插值）
    private func calculateAdaptiveParticleCounts(config: PerformanceConfiguration) -> (far: Int, mid: Int, near: Int) {
 // 计算质量分数 (0.0-1.0)
        let fpsNormalized = Float(config.targetFrameRate - 30) / Float(120 - 30)
        let particlesNormalized = Float(config.maxParticles - 1000) / Float(15000 - 1000)
        let scaleNormalized = Float(config.renderScale - 0.5) / Float(1.0 - 0.5)
        let qualityScore = (fpsNormalized * 0.4 + particlesNormalized * 0.4 + scaleNormalized * 0.2)
        
 // 定义极致和节能的粒子数量
        let extreme = (far: 200, mid: 150, near: 100)  // 极致模式
        let energySaving = (far: 60, mid: 40, near: 25)  // 节能模式
        
 // 线性插值计算粒子数量
        let clampedScore = max(0.0, min(1.0, qualityScore))
        let far = Int(Float(energySaving.far) + Float(extreme.far - energySaving.far) * clampedScore)
        let mid = Int(Float(energySaving.mid) + Float(extreme.mid - energySaving.mid) * clampedScore)
        let near = Int(Float(energySaving.near) + Float(extreme.near - energySaving.near) * clampedScore)
        
        return (far, mid, near)
    }
    
 // MARK: - 闪电系统
    
    private func startLightningSystem() {
 // 先取消旧计时器，避免重复启动
        lightningTimer?.invalidate()
        lightningTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 5...12), repeats: true) { _ in
 // ⏸️ 远程桌面活跃时跳过闪电动画，避免突发亮度计算造成额外负载
            Task { @MainActor in
 // 在主线程读取状态以满足并发模型
                guard !isRemoteDesktopActive else { return }
                withAnimation(.linear(duration: 0.05)) {
                    lightningOpacity = Double.random(in: 0.5...1.0)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Task { @MainActor in
 // 仅在主线程读取并判断远程桌面状态
                    guard !isRemoteDesktopActive else { return }
                    withAnimation(.linear(duration: 0.05)) {
                        lightningOpacity = 0.3
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task { @MainActor in
 // 仅在主线程读取并判断远程桌面状态
                    guard !isRemoteDesktopActive else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        lightningOpacity = 0
                    }
                }
            }
        }
    }
    
 // MARK: - 风力系统
    
 /// 风力系统（动态变化）
    private func startWindSystem() {
 // 先取消旧计时器，避免重复启动
        windTimer?.invalidate()
        windTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] _ in
 // ⏸️ 远程桌面活跃时跳过风力更新，避免频繁状态写入
            Task { @MainActor in
 // 在主线程读取状态以满足并发模型
                guard !isRemoteDesktopActive else { return }
                let time = Date().timeIntervalSinceReferenceDate
 // 风速在-150到150之间变化，根据雨强度调整
                let baseSpeed = sin(time * 0.3) * 150 + cos(time * 0.15) * 50
                windSpeed = baseSpeed * rainIntensity.windMultiplier
                windDirection = sin(time * 0.1)
            }
        }
    }

 /// 启动风噪系统（调制雾效强度）
 /// 说明：通过低频噪声与风速耦合，生成 0-1 的风噪等级；在 Canvas 内仅读取该状态，不进行写入
    private func startWindNoiseSystem() {
        windNoiseTimer?.invalidate()
        windNoiseTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [self] _ in
            Task { @MainActor in
 // 仅在主线程读取并判断远程桌面状态
                guard !isRemoteDesktopActive else { return }
                let t = Date().timeIntervalSinceReferenceDate
 // 噪声由两组正弦叠加并受风速影响（归一化至 0-1）
                let base = (sin(t * 0.37) + sin(t * 0.21 + 1.3)) * 0.5
                let windScale = min(1.0, max(0.0, Double(abs(windSpeed) / 200.0)))
                ambientWindNoiseLevel = min(1.0, max(0.0, (base * 0.5 + 0.5) * windScale))
            }
        }
    }
    

 /// 更新帧时间
    private func updateFrameTime(_ time: TimeInterval) {
        if lastFrameTime == 0 {
            lastFrameTime = time
        }
    }
    
 // MARK: - 统一暂停/恢复逻辑
    
 /// 集中暂停所有特效系统（取消计时器）
 /// 说明：只取消计时器，不修改业务状态，避免在视图更新期间写入状态引发并发警告
    private func pauseAllEffectSystems() {
        lightningTimer?.invalidate(); lightningTimer = nil
        windTimer?.invalidate(); windTimer = nil
        windNoiseTimer?.invalidate(); windNoiseTimer = nil
        wallDropDetectTimer?.invalidate(); wallDropDetectTimer = nil
        wallDropUpdateTimer?.invalidate(); wallDropUpdateTimer = nil
        waterPuddleTimer?.invalidate(); waterPuddleTimer = nil
        reflectionFlickerTimer?.invalidate(); reflectionFlickerTimer = nil
    }
    
 /// 恢复所有特效系统（重新启动计时器）
 /// 说明：TimelineView 已负责帧驱动，这里只恢复依赖计时器的子系统
    private func resumeAllEffectSystems() {
 // 采用 TimelineView 帧驱动，无需恢复任何 Timer
    }
    
 // MARK: - 渲染方法
    
 /// 程序化体积云层（Perlin噪声）
    private func drawVolumetricClouds(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
 // 注意：体积云动画改为纯时间驱动，不在视图更新期间写入 @State，
 // 以彻底避免 “Modifying state during view update” 并发警告。
        let cloudOffset: CGFloat = CGFloat(time) * 0.5  // 基于时间的偏移量（稳定、并发安全）
        
 // 多层云（4层，更细腻）
        for layerIndex in 0..<4 {
            let yOffset = CGFloat(layerIndex) * 35 - 20
            let opacity = 0.95 - Double(layerIndex) * 0.15
            let scale = 1.0 + CGFloat(layerIndex) * 0.15
            
 // 每层多个云团（不规则分布）
            for i in 0..<8 {
                let seed = Double(i * 13 + layerIndex * 7)
                let baseX = CGFloat(i) * (size.width / 7) - 80 + sin(seed) * 60
                
 // Perlin噪声模拟（简化版）- 基于时间的稳定偏移
                let noiseX = sin(CGFloat(time) * 0.05 + CGFloat(seed) + cloudOffset * 0.01) * 30
                let noiseY = cos(CGFloat(time) * 0.08 + CGFloat(seed) * 1.5) * 15
                
                let animX = baseX + noiseX
                let y = yOffset + noiseY
                
 // 不规则云团（多个椭圆叠加）
                for subCloud in 0..<5 {
                    let subSeed = seed + Double(subCloud) * 2.5
                    let offsetX = sin(subSeed) * 100 * scale
                    let offsetY = cos(subSeed * 1.3) * 40 * scale
                    let subSize = (180 + sin(subSeed * 2) * 80) * scale
                    
                    let cloudRect = CGRect(
                        x: animX + offsetX,
                        y: y + offsetY,
                        width: subSize,
                        height: subSize * 0.6
                    )
                    
 // 更复杂的渐变（三色）
                    let gradient = Gradient(colors: [
                        Color(red: 0.12, green: 0.12, blue: 0.18).opacity(opacity * 0.9),
                        Color(red: 0.18, green: 0.18, blue: 0.24).opacity(opacity * 0.7),
                        Color(red: 0.25, green: 0.25, blue: 0.32).opacity(opacity * 0.4),
                        Color.clear
                    ])
                    
                    let subOpacity = opacity * (0.7 + sin(subSeed) * 0.3)
                    
                    context.opacity = subOpacity
                    context.fill(
                        Path(ellipseIn: cloudRect),
                        with: .radialGradient(
                            gradient,
                            center: CGPoint(x: cloudRect.midX + 20, y: cloudRect.midY - 10),  // 偏移中心
                            startRadius: 0,
                            endRadius: subSize * 0.8
                        )
                    )
                    context.opacity = 1.0
                }
            }
        }
        
 // 添加云层边缘的光晕效果
        let glowGradient = Gradient(colors: [
            Color.white.opacity(0.03),
            Color.cyan.opacity(0.02),
            Color.clear
        ])
        
        context.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.4)),
            with: .linearGradient(
                glowGradient,
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height * 0.4)
            )
        )
    }
    
 /// 更新所有粒子物理状态（在 Canvas 外部调用）
    private func updateParticlePhysics(time: TimeInterval, screenSize: CGSize) {
 // ✅ 计算 deltaTime，确保有合理的最小值（16ms = 60fps）
        var deltaTime: CGFloat = lastFrameTime > 0 ? CGFloat(time - lastFrameTime) : 0.016
 // 限制最大 deltaTime（防止跳帧过大）
        deltaTime = min(deltaTime, 0.1)  // 最大 100ms
 // 确保最小 deltaTime（防止除零）
        deltaTime = max(deltaTime, 0.001)  // 最小 1ms
        lastFrameTime = time
        
 // 更新雨滴
        for i in 0..<raindrops.count {
            var drop = raindrops[i]
            
 // 物理更新
            updateRaindropPhysics(&drop, deltaTime: deltaTime, screenSize: screenSize)
            
            let x = drop.x * screenSize.width
            let y = drop.y * screenSize.height
            
 // 检查碰撞
            if checkCollisionWithGlass(CGPoint(x: x, y: y)) {
                spawnGlassDrop(at: CGPoint(x: x, y: y), size: screenSize)
 // ✅ 从顶部云层重生（根据景深层分配高度）
                let startY: CGFloat = drop.layer == 0 ? CGFloat.random(in: -0.5 ... -0.1) :  // 远景
                                      drop.layer == 1 ? CGFloat.random(in: -0.3 ... -0.05) : // 中景
                                                          CGFloat.random(in: -0.2 ... -0.02)  // 近景
                drop.y = startY
                drop.x = CGFloat.random(in: 0...1)
 // 根据雨强度调整重生的初始速度
                let baseVelocity = CGFloat.random(in: 100...300)
                drop.velocityY = baseVelocity * rainIntensity.velocityMultiplier
                drop.velocityX = CGFloat.random(in: -50...50)  // 重置水平速度
            }
            
 // 🔥 雨滴落地效果：当雨滴落到屏幕底部时，生成涟漪并消失
            if drop.y > 0.95 && drop.y < 1.05 && screenSize.height > 0 {
 // 检查是否在玻璃组件上
                let isOnGlass = checkCollisionWithGlass(CGPoint(x: x, y: y))
                
 // 只有在底部且不在玻璃上时才生成涟漪
                if !isOnGlass && ripples.count < 20 {
                    ripples.append(CinematicRainWaterRipple(
                        x: x,
                        y: screenSize.height * 0.95,
                        radius: 0,
                        opacity: 1.0,
                        lifetime: 0
                    ))
                }
                
 // ✅ 雨滴消失并从顶部云层重生（根据景深层分配高度）
                let startY: CGFloat = drop.layer == 0 ? CGFloat.random(in: -0.5 ... -0.1) :  // 远景
                                      drop.layer == 1 ? CGFloat.random(in: -0.3 ... -0.05) : // 中景
                                                          CGFloat.random(in: -0.2 ... -0.02)  // 近景
                drop.y = startY
                drop.x = CGFloat.random(in: 0...1)
                let baseVelocity = CGFloat.random(in: 100...300)
                drop.velocityY = baseVelocity * rainIntensity.velocityMultiplier
                drop.velocityX = CGFloat.random(in: -50...50)  // 重置水平速度
            }
            
            raindrops[i] = drop
        }
        
 // 更新玻璃水珠
        for i in 0..<glassDrops.count {
            glassDrops[i].lifetime += Double(deltaTime)
            
 // 如果水珠掉落到底部，移除它
            let y = (glassDrops[i].y * screenSize.height + glassDrops[i].slideSpeed * CGFloat(glassDrops[i].lifetime))
            if y > screenSize.height * 0.9 {
                glassDrops.remove(at: i)
                break
            }
        }
        
 // 更新涟漪
        for i in (0..<ripples.count).reversed() {
            ripples[i].lifetime += Double(deltaTime)
            ripples[i].radius = CGFloat(ripples[i].lifetime) * 80
            ripples[i].opacity = max(0, 1.0 - ripples[i].lifetime / 0.8)
            
            if ripples[i].opacity <= 0 {
                ripples.remove(at: i)
            }
        }
        
 // 移除随机生成涟漪的逻辑，改为由雨滴落地触发
    }
    
 /// 🌟 Apple Weather风格：基于时间直接计算雨滴位置（每帧重新计算，不依赖State）
    private func drawRaindropsWithTime(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard !raindrops.isEmpty else { return }
        
        let qualityConfig = getQualityConfiguration()
        let enableAdvancedEffects = qualityConfig.enableAdvancedEffects
        
 // 🌟 获取清除区域快照用于粒子驱散
        let zones = clearManager.clearZones
        
 // 每个雨滴基于其初始状态和时间计算当前位置
        for drop in raindrops {
 // 计算该雨滴从初始化到现在的经过时间
 // 使用drop的id作为随机种子，确保每个雨滴有不同的相位
            let dropSeed = Double(drop.id.hashValue % 10000) / 10000.0
            let dropStartTime = time - dropSeed * 3.0  // 每个雨滴有不同的开始时间（0-3秒偏移）
            let dropAge = max(0.0, dropStartTime.truncatingRemainder(dividingBy: 5.0))  // 5秒循环
            
 // 计算当前速度（受重力加速）
            let gravityPerSecond: CGFloat = 980.0 / size.height  // 归一化重力
            let initialVelocityY = (drop.velocityY > 1.0 ? drop.velocityY / size.height : drop.velocityY) * rainIntensity.velocityMultiplier
            let currentVelocityY = min(initialVelocityY + CGFloat(dropAge) * gravityPerSecond * CGFloat(rainIntensity.velocityMultiplier),
                                     (1200.0 / size.height) * CGFloat(rainIntensity.velocityMultiplier))  // 终端速度限制
            
 // 计算当前位置 - 确保从云层顶部开始
 // 使用drop的layer信息来确定起始高度
            let startY: CGFloat = drop.layer == 0 ? -0.5 :  // 远景从更高位置
                                  drop.layer == 1 ? -0.3 :  // 中景
                                                    -0.2     // 近景
            let currentY = startY + currentVelocityY * CGFloat(dropAge)
            
 // 横向风力影响
            let normalizedWind = windSpeed / size.width
            let windDrift = normalizedWind * CGFloat(dropAge) * 0.3
            let currentX = drop.x + windDrift
            
 // 如果雨滴已经落地，循环回到顶部（Apple Weather风格）
            let totalHeight = 1.1 - startY
            let normalizedY = (currentY - startY).truncatingRemainder(dividingBy: totalHeight)
            let finalY = normalizedY + startY
            let finalX = currentX.truncatingRemainder(dividingBy: 1.0)
            
            let x = finalX * size.width
            let y = finalY * size.height
            
 // 跳过屏幕外的雨滴
            guard y >= -100 && y <= size.height + 100 && x >= -50 && x <= size.width + 50 else { continue }
            
 // 🌟 计算清除区域内的驱散强度（降低透明度）
            var disperseFactor: Double = 1.0
            for zone in zones {
                let dx = x - zone.center.x
                let dy = y - zone.center.y
                let distanceSquared = dx * dx + dy * dy
                let radiusSquared = zone.radius * zone.radius
                
                if distanceSquared < radiusSquared {
                    let distance = sqrt(distanceSquared)
                    let normalizedDist = distance / zone.radius
                    let falloff = (1.0 - normalizedDist * normalizedDist)
                    let strength = Double(zone.strength) * falloff
                    disperseFactor = min(disperseFactor, 1.0 - strength * 0.9)
                }
            }
            
 // 如果完全被驱散，跳过绘制
            guard disperseFactor > 0.05 else { continue }
            
 // 计算雨滴长度（速度越快越长）
            let speedFactor = min(currentVelocityY / (800.0 / size.height), 1.5)
            let currentLength = drop.baseLength * speedFactor
            
 // 计算倾斜角度
            let angle = atan2(normalizedWind * 0.5, currentVelocityY)
            
 // 应用变换
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: x, y: y)
            transform = transform.rotated(by: angle)
            
 // 🌟 根据性能模式选择绘制方式（应用驱散因子）
            if enableAdvancedEffects {
                drawSingleAdvancedRaindrop(context: &context, drop: drop, currentLength: currentLength, transform: transform, disperseFactor: disperseFactor)
            } else {
                drawSingleSimpleRaindrop(context: &context, drop: drop, currentLength: currentLength, transform: transform, disperseFactor: disperseFactor)
            }
        }
    }
    
 /// 绘制单个高级雨滴
    private func drawSingleAdvancedRaindrop(context: inout GraphicsContext, drop: PhysicsRaindrop, currentLength: CGFloat, transform: CGAffineTransform, disperseFactor: Double = 1.0) {
        let rainPath = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: currentLength))
        }
        
 // 🌟 应用驱散因子到透明度
        let effectiveOpacity = drop.opacity * disperseFactor
        
        let gradient = Gradient(colors: [
            Color.white.opacity(effectiveOpacity),
            Color.cyan.opacity(effectiveOpacity * 0.8),
            Color.blue.opacity(effectiveOpacity * 0.6),
            Color.white.opacity(effectiveOpacity * 0.3)
        ])
        
        context.stroke(
            rainPath.applying(transform),
            with: .linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: currentLength)
            ),
            style: StrokeStyle(
                lineWidth: drop.thickness,
                lineCap: .round,
                lineJoin: .round
            )
        )
        
 // 高光
        let highlightPath = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: currentLength * 0.3))
        }
        
        context.stroke(
            highlightPath.applying(transform),
            with: .color(.white.opacity(0.95 * disperseFactor)),
            style: StrokeStyle(lineWidth: drop.thickness * 0.5, lineCap: .round)
        )
    }
    
 /// 绘制单个简化雨滴
    private func drawSingleSimpleRaindrop(context: inout GraphicsContext, drop: PhysicsRaindrop, currentLength: CGFloat, transform: CGAffineTransform, disperseFactor: Double = 1.0) {
        let rainPath = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: currentLength))
        }
        
 // 🌟 应用驱散因子到透明度
        let effectiveOpacity = drop.opacity * disperseFactor
        
        context.stroke(
            rainPath.applying(transform),
            with: .color(Color.white.opacity(effectiveOpacity)),
            style: StrokeStyle(
                lineWidth: drop.thickness,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
    
 /// 绘制雨滴（纯绘制，不修改状态）- 保留作为备用
    private func drawRaindrops(context: inout GraphicsContext, size: CGSize) {
        let qualityConfig = getQualityConfiguration()
        let enableAdvancedEffects = qualityConfig.enableAdvancedEffects
        
        for drop in raindrops {
            let x = drop.x * size.width
            let y = drop.y * size.height
            
 // 雨滴形变（速度越快越拉长）
            let speedFactor = min(drop.velocityY / 1500, 1.5)
            let currentLength = drop.baseLength * speedFactor
            
 // 计算倾斜角度（受风影响）
            let angle = atan2(drop.velocityX, drop.velocityY)
            
 // 雨滴主体（带旋转）
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: x, y: y)
            transform = transform.rotated(by: angle)
            
 // 🌟 根据性能模式选择绘制方式
            if enableAdvancedEffects {
 // 极致/自适应(高)：完整渐变雨滴
                drawAdvancedRaindrop(context: &context, x: x, y: y, drop: drop, 
                                   currentLength: currentLength, transform: transform)
            } else {
 // 平衡/节能/自适应(低)：简化雨滴
                drawSimpleRaindrop(context: &context, x: x, y: y, drop: drop, 
                                  currentLength: currentLength, transform: transform)
            }
        }
    }
    
 /// 绘制高级雨滴（极致模式）- 完整渐变和特效
    private func drawAdvancedRaindrop(context: inout GraphicsContext, x: CGFloat, y: CGFloat, 
                                     drop: PhysicsRaindrop, currentLength: CGFloat, 
                                     transform: CGAffineTransform) {
 // 主雨滴（三色渐变，模拟光线折射）
            let rainPath = Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 0, y: currentLength))
            }
        
 // 渐变：顶部（白）-> 中部（青）-> 底部（蓝）
        let gradient = Gradient(colors: [
            Color.white.opacity(drop.opacity),
            Color.cyan.opacity(drop.opacity * 0.8),
            Color.blue.opacity(drop.opacity * 0.6),
            Color.white.opacity(drop.opacity * 0.3)
        ])
            
            context.stroke(
                rainPath.applying(transform),
            with: .linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: currentLength)
            ),
                style: StrokeStyle(
                    lineWidth: drop.thickness,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            
 // 高光效果（前景所有层，30%头部）
                let highlightPath = Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 0, y: currentLength * 0.3))
                }
                
                context.stroke(
                    highlightPath.applying(transform),
                    with: .color(.white.opacity(0.95)),
            style: StrokeStyle(lineWidth: drop.thickness * 0.5, lineCap: .round)
                )
            
 // 雨滴尾迹（高速雨滴）- 仅远景
            if drop.velocityY > 800 && drop.layer == 0 {
                let trailPath = Path { path in
                path.move(to: CGPoint(x: x, y: y - currentLength * 0.3))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                context.stroke(
                    trailPath,
                    with: .linearGradient(
                        Gradient(colors: [
                        Color.cyan.opacity(0.35),
                        Color.white.opacity(0.6)
                        ]),
                    startPoint: CGPoint(x: x, y: y - currentLength * 0.3),
                        endPoint: CGPoint(x: x, y: y)
                    ),
                style: StrokeStyle(lineWidth: drop.thickness * 0.3, lineCap: .round)
            )
        }
    }
    
 /// 绘制简化雨滴（节能模式）- 单一颜色
    private func drawSimpleRaindrop(context: inout GraphicsContext, x: CGFloat, y: CGFloat, 
                                   drop: PhysicsRaindrop, currentLength: CGFloat, 
                                   transform: CGAffineTransform) {
        let rainPath = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: currentLength))
        }
        
        context.stroke(
            rainPath.applying(transform),
            with: .color(Color.white.opacity(drop.opacity)),
            style: StrokeStyle(
                lineWidth: drop.thickness,
                lineCap: .round,
                lineJoin: .round
            )
        )
        
 // 仅在平衡模式下添加简单高光
        if let config = performanceConfig, config.targetFrameRate >= 60 && config.maxParticles >= 2000 {
            if drop.layer == 0 {
                let highlightPath = Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 0, y: currentLength * 0.3))
                }
                
                context.stroke(
                    highlightPath.applying(transform),
                    with: .color(.white.opacity(0.9)),
                    style: StrokeStyle(lineWidth: drop.thickness * 0.4, lineCap: .round)
                )
            }
        }
    }
    
 /// 物理更新雨滴
    private func updateRaindropPhysics(_ drop: inout PhysicsRaindrop, deltaTime: CGFloat, screenSize: CGSize) {
 // ✅ 首次运行时，将像素单位的速度归一化（转换为相对于屏幕尺寸的单位）
 // 如果速度看起来像像素单位（> 1），则归一化
        if drop.velocityY > 1.0 || drop.velocityX > 1.0 || drop.velocityX < -1.0 {
            drop.velocityX = drop.velocityX / screenSize.width
            drop.velocityY = drop.velocityY / screenSize.height
        }
        
 // ✅ 修复：速度单位统一为"归一化单位/秒"（相对于屏幕高度）
 // 重力加速度转换为归一化单位：980 px/s² -> 归一化单位/s²
        let normalizedGravity: CGFloat = (drop.acceleration / screenSize.height) * rainIntensity.velocityMultiplier
        drop.velocityY += normalizedGravity * deltaTime
        
 // 风力影响（横向）- 归一化为相对于屏幕宽度
        let normalizedWindSpeed = windSpeed / screenSize.width
        drop.velocityX += (normalizedWindSpeed - drop.velocityX) * 0.1 * deltaTime * 60  // 乘以60以保持响应速度
        
 // 空气阻力（终端速度约为屏幕高度的1.2-1.5倍/秒，暴风雨更快）
        let terminalVelocityNormalized: CGFloat = (1200 / screenSize.height) * rainIntensity.velocityMultiplier
        let drag: CGFloat = 0.002
        let speedSquared = drop.velocityY * drop.velocityY
        let dragForce = drag * speedSquared / drop.mass
        drop.velocityY = min(drop.velocityY - dragForce * deltaTime, terminalVelocityNormalized)
        
 // ✅ 更新位置（速度单位已经是归一化的）
        drop.x += drop.velocityX * deltaTime
        drop.y += drop.velocityY * deltaTime
        
 // ✅ 雨滴超出底部后，从顶部云层重生
        if drop.y > 1.1 {
 // 根据景深层分配不同的重生高度
            let startY: CGFloat = drop.layer == 0 ? CGFloat.random(in: -0.5 ... -0.1) :  // 远景
                                  drop.layer == 1 ? CGFloat.random(in: -0.3 ... -0.05) : // 中景
                                                      CGFloat.random(in: -0.2 ... -0.02)  // 近景
            drop.y = startY
            drop.x = CGFloat.random(in: 0...1)
            let baseVelocity = CGFloat.random(in: 100...300)
            drop.velocityY = baseVelocity * rainIntensity.velocityMultiplier
            drop.velocityX = CGFloat.random(in: -50...50)
        }
        
        if drop.x < -0.1 || drop.x > 1.1 {
            drop.x = CGFloat.random(in: 0...1)
        }
    }
    
 /// 检测与液态玻璃组件碰撞
    private func checkCollisionWithGlass(_ point: CGPoint) -> Bool {
        for rect in glassComponentRects {
            if rect.contains(point) {
                return true
            }
        }
        return false
    }
    
 /// 在碰撞点生成水珠
    private func spawnGlassDrop(at point: CGPoint, size: CGSize) {
        if glassDrops.count < 40 {  // 限制最大数量
            glassDrops.append(DynamicGlassDrop(
                x: point.x / size.width,
                y: point.y / size.height,
                size: CGFloat.random(in: 6...14),
                lifetime: 0,
                slideSpeed: CGFloat.random(in: 20...50)
            ))
        }
    }
    
 /// 检测液态玻璃组件位置
    private func detectGlassComponents() {
 // 模拟常见UI组件位置（实际应该从真实UI获取）
        glassComponentRects = [
            CGRect(x: 320, y: 140, width: 720, height: 180),  // 顶部卡片
            CGRect(x: 320, y: 350, width: 720, height: 300),  // 中部卡片
            CGRect(x: 20, y: 100, width: 260, height: 600),   // 侧边栏
        ]
    }
    
 /// 绘制玻璃水珠（纯绘制）
    private func drawGlassDrops(context: inout GraphicsContext, size: CGSize) {
        for drop in glassDrops {
            let x = drop.x * size.width
            let slideOffset = drop.slideSpeed * CGFloat(drop.lifetime)
            let y = drop.y * size.height + slideOffset
            
 // 如果水珠落到屏幕底部，就移出视图（不再绘制）
            if y > size.height * 0.9 || y < 0 {
                continue
            }
            
 // 主水珠体
            let mainRect = CGRect(
                x: x - drop.size / 2,
                y: y - drop.size / 2,
                width: drop.size,
                height: drop.size * 1.3  // 椭圆形
            )
            
 // 玻璃质感渐变
            let gradient = Gradient(colors: [
                Color.white.opacity(0.6),
                Color.cyan.opacity(0.3),
                Color.clear
            ])
            
            context.fill(
                Path(ellipseIn: mainRect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: mainRect.midX, y: mainRect.midY),
                    startRadius: 0,
                    endRadius: drop.size / 2
                )
            )
            
 // 高光点
            let highlightRect = CGRect(
                x: x - drop.size * 0.2,
                y: y - drop.size * 0.3,
                width: drop.size * 0.4,
                height: drop.size * 0.4
            )
            
            context.fill(
                Path(ellipseIn: highlightRect),
                with: .color(.white.opacity(0.9))
            )
            
 // 阴影部分
            let shadowRect = CGRect(
                x: x + drop.size * 0.1,
                y: y + drop.size * 0.2,
                width: drop.size * 0.5,
                height: drop.size * 0.6
            )
            
            context.fill(
                Path(ellipseIn: shadowRect),
                with: .color(.black.opacity(0.2))
            )
        }
    }
    
 /// 绘制涟漪（纯绘制）
    private func drawRipples(context: inout GraphicsContext, size: CGSize) {
        for ripple in ripples {
            let ripplePath = Path { path in
                path.addEllipse(in: CGRect(
                    x: ripple.x - ripple.radius,
                    y: ripple.y - ripple.radius / 2,
                    width: ripple.radius * 2,
                    height: ripple.radius
                ))
            }
            
            context.stroke(
                ripplePath,
                with: .color(.white.opacity(ripple.opacity * 0.4)),
                lineWidth: 2
            )
        }
    }
    
 // MARK: - 🌟 OPPO风格：挂壁水珠绘制
    
 /// 绘制挂壁水珠（OPPO风格：附着在玻璃组件上，慢慢下滑 + 形变 + 自由下落）
    private func drawWallWaterDrops(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard !wallWaterDrops.isEmpty else { return }
        
        for wallDrop in wallWaterDrops {
            var x: CGFloat
            var y: CGFloat
            
 // 🌟 根据状态计算位置
            if wallDrop.glassRectIndex >= 0 && wallDrop.glassRectIndex < glassComponentRects.count {
 // 在玻璃组件上
                let glassRect = glassComponentRects[wallDrop.glassRectIndex]
                x = glassRect.minX + wallDrop.x * glassRect.width
                y = glassRect.minY + wallDrop.y * glassRect.height
            } else {
 // 自由下落状态（使用屏幕坐标）
                x = wallDrop.x * size.width
                y = wallDrop.y * size.height
            }
            
 // 跳过屏幕外的水珠
            guard x >= -50 && x <= size.width + 50 && y >= -50 && y <= size.height + 50 else { continue }
            
 // 🌟 根据形变因子调整水珠形状
            let baseWidth = wallDrop.size
            let baseHeight = wallDrop.size * 1.4
            let deformedWidth = baseWidth / wallDrop.deformationFactor  // 形变时变细
            let deformedHeight = baseHeight * wallDrop.deformationFactor  // 形变时拉长
            
 // 绘制水珠主体（椭圆形，模拟挂壁效果 + 形变）
            let dropRect = CGRect(
                x: x - deformedWidth / 2,
                y: y - deformedHeight / 2,
                width: deformedWidth,
                height: deformedHeight
            )
            
 // 🌟 修复：自然透明水珠（无色透明，根据背景玻璃色彩变化）
 // 真实水珠是无色的，主要通过反射和折射显示
            let gradient = Gradient(colors: [
                Color.white.opacity(wallDrop.opacity * 0.95),  // 顶部高光（强反射）
                Color.white.opacity(wallDrop.opacity * 0.7),   // 中部（轻微反射）
                Color.white.opacity(wallDrop.opacity * 0.4),   // 底部（透过背景）
                Color.clear                                     // 边缘透明
            ])
            
            context.fill(
                Path(ellipseIn: dropRect),
                with: .radialGradient(
                    gradient,
                    center: CGPoint(x: dropRect.midX, y: dropRect.minY + dropRect.height * 0.3),
                    startRadius: 0,
                    endRadius: max(deformedWidth, deformedHeight) / 2
                )
            )
            
 // 高光点（左上角）- 仅在滑动和累积阶段显示
            if wallDrop.state == .sliding || wallDrop.state == .accumulating {
                let highlightRect = CGRect(
                    x: x - deformedWidth * 0.35,
                    y: y - deformedHeight * 0.4,
                    width: deformedWidth * 0.5,
                    height: deformedWidth * 0.5
                )
                
                context.fill(
                    Path(ellipseIn: highlightRect),
                    with: .color(.white.opacity(wallDrop.opacity * 0.8))
                )
            }
            
 // 🌟 下滑时的尾迹（如果正在下滑）- 无色透明水痕
            if wallDrop.state == .sliding && wallDrop.slideProgress > 0.1 {
                let trailHeight = min(wallDrop.slideProgress * 20, 15) * wallDrop.deformationFactor
                let trailRect = CGRect(
                    x: x - 1,
                    y: y - trailHeight,
                    width: 2,
                    height: trailHeight
                )
                
 // 🌟 修复：尾迹也是无色透明的（模拟水痕）
                let trailGradient = Gradient(colors: [
                    Color.white.opacity(wallDrop.opacity * 0.5),
                    Color.white.opacity(wallDrop.opacity * 0.2),
                    Color.clear
                ])
                
                context.fill(
                    Path { path in path.addRect(trailRect) },
                    with: .linearGradient(
                        trailGradient,
                        startPoint: CGPoint(x: x, y: y - trailHeight),
                        endPoint: CGPoint(x: x, y: y)
                    )
                )
            }
            
 // 🌟 自由下落时的动态尾迹（拉长效果）
            if wallDrop.state == .falling || wallDrop.state == .fading {
                let trailLength = min(deformedHeight * 1.5, 30)
                let trailRect = CGRect(
                    x: x - deformedWidth * 0.3,
                    y: y - trailLength,
                    width: deformedWidth * 0.6,
                    height: trailLength
                )
                
                let fallingTrailGradient = Gradient(colors: [
                    Color.white.opacity(wallDrop.opacity * 0.6),
                    Color.white.opacity(wallDrop.opacity * 0.3),
                    Color.clear
                ])
                
                context.fill(
                    Path { path in path.addEllipse(in: trailRect) },
                    with: .linearGradient(
                        fallingTrailGradient,
                        startPoint: CGPoint(x: x, y: y - trailLength),
                        endPoint: CGPoint(x: x, y: y)
                    )
                )
            }
        }
    }
    
 // MARK: - 🌟 底部积水绘制
    
 /// 绘制底部积水效果（水位 + 波纹动画）
    private func drawWaterPuddle(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard waterPuddle.waterLevel > 0.001 else { return }  // 只有水位足够才绘制
        
        let waterHeight = size.height * waterPuddle.waterLevel
        let waterY = size.height - waterHeight
        
 // 1. 绘制基础积水层（深色渐变）
        let waterGradient = Gradient(colors: [
            Color(red: 0.15, green: 0.2, blue: 0.3).opacity(0.6),
            Color(red: 0.2, green: 0.25, blue: 0.35).opacity(0.7),
            Color(red: 0.25, green: 0.3, blue: 0.4).opacity(0.8)
        ])
        
        context.fill(
            Path(CGRect(x: 0, y: waterY, width: size.width, height: waterHeight)),
            with: .linearGradient(
                waterGradient,
                startPoint: CGPoint(x: 0, y: waterY),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        
 // 2. 绘制水波动画（动态波纹线）
        var wavePath = Path()
        wavePath.move(to: CGPoint(x: 0, y: waterY))
        
        let waveFrequency: CGFloat = 0.02
        let waveAmplitude: CGFloat = 2.0
        let waveSpeed = CGFloat(time * 2.0)
        
 // ✅ 性能优化：降低水波计算精度（从每5像素改为每10像素）
        for x in stride(from: 0, through: size.width, by: 10) {
            let wave1 = sin((x * waveFrequency) + waveSpeed) * waveAmplitude
            let wave2 = sin((x * waveFrequency * 1.5) + waveSpeed * 1.3) * waveAmplitude * 0.5
            let y = waterY + wave1 + wave2
            wavePath.addLine(to: CGPoint(x: x, y: y))
        }
        
        context.stroke(
            wavePath,
            with: .color(.white.opacity(0.3)),
            lineWidth: 1.5
        )
        
 // 3. 绘制积水表面的涟漪
        for ripple in waterPuddle.ripples {
            let ripplePath = Path { path in
                path.addEllipse(in: CGRect(
                    x: ripple.x - ripple.radius,
                    y: ripple.y - ripple.radius / 2,
                    width: ripple.radius * 2,
                    height: ripple.radius
                ))
            }
            
            context.stroke(
                ripplePath,
                with: .color(.white.opacity(ripple.opacity * 0.5)),
                lineWidth: 2
            )
        }
        
 // 4. 绘制水面反射高光（模拟光线反射，加入微弱闪烁调制）
 // 说明：反射高光的透明度受 reflectionFlickerFactor 调制，范围约在 0.9-1.1 之间，保持细腻变化
        let flicker = max(0.8, min(1.2, reflectionFlickerFactor))
        for x in stride(from: 0, through: size.width, by: 80) {
            let shimmer = sin(time * 3.0 + Double(x) * 0.1) * 0.5 + 0.5
            let highlightY = waterY + CGFloat(shimmer) * 5

            let highlightRect = CGRect(
                x: x - 20,
                y: highlightY - 1,
                width: 40,
                height: 2
            )

            context.fill(
                Path(ellipseIn: highlightRect),
                with: .color(.white.opacity(0.2 * shimmer * flicker))
            )
        }
    }
    
 /// 启动粒子更新循环
    private func startParticleUpdateLoop() {
 // TimelineView 的 onChange 会自动触发更新，无需额外 Timer
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("🌧️ 粒子物理系统已启动")
        #endif
    }
    
 // MARK: - 🌟 挂壁水珠系统（OPPO风格）
    
 /// 启动挂壁水珠系统
    private func startWallWaterDropsSystem() {
 // ✅ 性能优化：降低检测频率（从0.1秒改为0.2秒）
 // 先取消旧计时器，避免重复启动
        wallDropDetectTimer?.invalidate()
        wallDropDetectTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [self] _ in
 // ⏸️ 远程桌面活跃时暂停挂壁水珠的碰撞检测与生成
            Task { @MainActor in
                guard !isRemoteDesktopActive else { return }
                detectAndSpawnWallDrops()
            }
        }
 // ✅ 性能优化：分离更新逻辑，降低频率
        wallDropUpdateTimer?.invalidate()
        wallDropUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [self] _ in
 // ⏸️ 远程桌面活跃时暂停挂壁水珠的状态更新
            Task { @MainActor in
                guard !isRemoteDesktopActive else { return }
                updateWallWaterDrops()
            }
        }
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("💧 挂壁水珠系统已启动（性能优化）")
        #endif
    }
    
 /// 检测雨滴碰撞并生成挂壁水珠
    private func detectAndSpawnWallDrops() {
        guard !glassComponentRects.isEmpty else { return }
        
 // ✅ 修复：使用实际窗口尺寸，而不是硬编码的屏幕尺寸
        let screenSize = currentWindowSize
        
 // ✅ 性能优化：采样检测（只检测部分雨滴，而不是全部）
        let step = max(1, raindrops.count / 50)  // 最多检测50个
        for dropIndex in stride(from: 0, to: raindrops.count, by: step) {
            let drop = raindrops[dropIndex]
 // 使用雨滴ID和时间计算位置（与drawRaindropsWithTime保持一致）
            let dropSeed = Double(drop.id.hashValue % 10000) / 10000.0
            let time = Date().timeIntervalSinceReferenceDate
            let dropStartTime = time - dropSeed * 3.0
            let dropAge = max(0.0, dropStartTime.truncatingRemainder(dividingBy: 5.0))
            
 // 计算雨滴当前位置
            let gravityPerSecond: CGFloat = 980.0 / screenSize.height
            let initialVelocityY = (drop.velocityY > 1.0 ? drop.velocityY / screenSize.height : drop.velocityY) * rainIntensity.velocityMultiplier
            let currentVelocityY = min(initialVelocityY + CGFloat(dropAge) * gravityPerSecond * CGFloat(rainIntensity.velocityMultiplier),
                                     (1200.0 / screenSize.height) * CGFloat(rainIntensity.velocityMultiplier))
            
            let startY: CGFloat = drop.layer == 0 ? -0.5 : (drop.layer == 1 ? -0.3 : -0.2)
            let currentY = startY + currentVelocityY * CGFloat(dropAge)
            let normalizedWind = windSpeed / screenSize.width
            let windDrift = normalizedWind * CGFloat(dropAge) * 0.3
            let currentX = (drop.x + windDrift).truncatingRemainder(dividingBy: 1.0)
            
            let x = currentX * screenSize.width
            let y = currentY * screenSize.height
            
 // 检查是否碰撞玻璃组件（仅在组件上半部分碰撞时生成，模拟顶部附着）
            for (index, glassRect) in glassComponentRects.enumerated() {
                let collisionPoint = CGPoint(x: x, y: y)
                if glassRect.contains(collisionPoint) {
 // 只在上半部分生成水珠（模拟在顶部附着）
                    let relativeY = (y - glassRect.minY) / glassRect.height
 // ✅ 性能优化：限制挂壁水珠数量（从50降到30）
                    if relativeY < 0.6 && Double.random(in: 0...1) < 0.15 && wallWaterDrops.count < 30 {
 // 检查该位置是否已经有水珠（避免重叠）
                        let existingDrop = wallWaterDrops.first { existing in
                            existing.glassRectIndex == index &&
                            abs(existing.x - (x - glassRect.minX) / glassRect.width) < 0.05 &&
                            abs(existing.y - relativeY) < 0.05
                        }
                        
                        if existingDrop == nil {
                            let normalizedX = (x - glassRect.minX) / glassRect.width
 // ✅ 更真实：挂壁水珠更细（从8-16改为5-10）
                            wallWaterDrops.append(WallWaterDrop(
                                x: normalizedX,
                                y: relativeY,
                                size: CGFloat.random(in: 5...10),
                                glassRectIndex: index
                            ))
                            break
                        }
                    }
                }
            }
        }
    }
    
 /// 更新挂壁水珠（下滑动画 + 形变 + 自由下落）
    private func updateWallWaterDrops() {
        let deltaTime: CGFloat = 0.1
        let screenSize = currentWindowSize
        let gravity: CGFloat = 980.0 / screenSize.height * CGFloat(deltaTime)  // 归一化重力
        
        for i in (0..<wallWaterDrops.count).reversed() {
            var drop = wallWaterDrops[i]
            drop.lifetime += deltaTime
            
 // 检查是否过期
            if drop.lifetime > drop.maxLifetime {
                wallWaterDrops.remove(at: i)
                continue
            }
            
 // 状态机处理
            switch drop.state {
            case .accumulating:
 // 累积阶段：静止0.5-2秒
                let accumulateTime = drop.maxLifetime * 0.1
                if drop.lifetime > accumulateTime {
                    drop.state = .sliding
                    drop.accumulated = true
                }
                
            case .sliding:
 // 下滑阶段：在玻璃上滑动
                guard drop.glassRectIndex >= 0 && drop.glassRectIndex < glassComponentRects.count else {
                    wallWaterDrops.remove(at: i)
                    continue
                }
                
                let glassRect = glassComponentRects[drop.glassRectIndex]
                let slideSpeed: CGFloat = 0.12  // 下滑速度
                drop.y += slideSpeed * CGFloat(deltaTime)
                drop.slideProgress = min(1.0, drop.slideProgress + CGFloat(deltaTime) * 0.5)
                
 // 🌟 检测是否滑到玻璃底部
                if drop.y > 1.0 {
 // 转换到自由下落状态
                    let screenX = glassRect.minX + drop.x * glassRect.width
                    let screenY = glassRect.maxY  // 从玻璃底部开始
                    
                    drop.x = screenX / screenSize.width  // 转换为屏幕坐标
                    drop.y = screenY / screenSize.height
                    drop.state = .falling
                    drop.glassRectIndex = -1  // 标记为自由下落
                    drop.useScreenCoordinates = true
                    drop.velocityY = 0.01  // 初始下落速度
                    drop.deformationFactor = 1.2  // 开始形变（拉长）
                } else {
 // 🌟 检测是否滑到另一个玻璃组件
                    let screenX = glassRect.minX + drop.x * glassRect.width
                    let screenY = glassRect.minY + drop.y * glassRect.height
                    let currentPoint = CGPoint(x: screenX, y: screenY)
                    
 // 检查是否进入其他玻璃组件
                    for (newIndex, newGlassRect) in glassComponentRects.enumerated() {
                        if newIndex != drop.glassRectIndex && newGlassRect.contains(currentPoint) {
 // 转换到新的玻璃组件
                            drop.glassRectIndex = newIndex
                            drop.x = (screenX - newGlassRect.minX) / newGlassRect.width
                            drop.y = (screenY - newGlassRect.minY) / newGlassRect.height
                            drop.deformationFactor = 1.5  // 形变（拉长），模拟过渡
                            break
                        }
                    }
                    
 // 形变恢复（如果不在过渡中）
                    if drop.deformationFactor > 1.0 {
                        drop.deformationFactor = max(1.0, drop.deformationFactor - CGFloat(deltaTime) * 0.5)
                    }
                }
                
            case .falling:
 // 自由下落阶段：脱离玻璃，掉向积水
                drop.velocityY += gravity  // 重力加速
                drop.y += drop.velocityY
                
 // 形变：下落时拉长
                drop.deformationFactor = min(2.0, drop.deformationFactor + CGFloat(deltaTime) * 2.0)
                
 // 检测是否落到积水（屏幕底部95%处）
                let screenY = drop.y * screenSize.height
                let waterLevel = screenSize.height * (1.0 - waterPuddle.waterLevel)
                
                if screenY >= waterLevel - 5 {
 // 落入积水中，生成涟漪
                    if waterPuddle.ripples.count < 30 {
                        let rippleX = drop.x * screenSize.width
                        waterPuddle.ripples.append(CinematicRainWaterRipple(
                            x: rippleX,
                            y: waterLevel,
                            radius: 0,
                            opacity: 1.0,
                            lifetime: 0
                        ))
                    }
                    
 // 移除水珠
                    wallWaterDrops.remove(at: i)
                    continue
                }
                
 // 如果下落太快或太久，淡出消失
                if drop.velocityY > 0.05 || drop.y > 1.1 {
                    drop.state = .fading
                    drop.velocityY *= 0.95  // 减速
                }
                
            case .fading:
 // 淡出消失阶段
                drop.opacity = max(0, drop.opacity - Double(deltaTime) * 2.0)
                drop.y += drop.velocityY
                drop.deformationFactor = min(3.0, drop.deformationFactor + CGFloat(deltaTime))
                
                if drop.opacity <= 0 || drop.y > 1.2 {
                    wallWaterDrops.remove(at: i)
                    continue
                }
            }
            
            wallWaterDrops[i] = drop
        }
    }
    
 // MARK: - 🌟 底部积水系统
    
 /// 启动积水系统
    private func startWaterPuddleSystem() {
 // ✅ 性能优化：降低检测频率（从0.05秒改为0.15秒）
 // 先取消旧计时器，避免重复启动
        waterPuddleTimer?.invalidate()
        waterPuddleTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [self] _ in
 // ⏸️ 远程桌面活跃时暂停积水检测与更新，避免额外计算
            Task { @MainActor in
                guard !isRemoteDesktopActive else { return }
                detectRaindropsHittingGround()
                updateWaterPuddle()
            }
        }
        #if DEBUG
        SkyBridgeLogger.ui.debugOnly("💧 底部积水系统已启动（性能优化）")
        #endif
    }
    
 /// 检测雨滴落地，增加积水
    private func detectRaindropsHittingGround() {
 // ✅ 修复：使用实际窗口尺寸
        let screenSize = currentWindowSize
        let groundLevel = screenSize.height * 0.95
        
        var hitCount = 0
        
 // ✅ 性能优化：采样检测（只检测部分雨滴，而不是全部）
        let step = max(1, raindrops.count / 100)  // 最多检测100个
        for dropIndex in stride(from: 0, to: raindrops.count, by: step) {
            let drop = raindrops[dropIndex]
            
            let dropSeed = Double(drop.id.hashValue % 10000) / 10000.0
            let time = Date().timeIntervalSinceReferenceDate
            let dropStartTime = time - dropSeed * 3.0
            let dropAge = max(0.0, dropStartTime.truncatingRemainder(dividingBy: 5.0))
            
            let gravityPerSecond: CGFloat = 980.0 / screenSize.height
            let initialVelocityY = (drop.velocityY > 1.0 ? drop.velocityY / screenSize.height : drop.velocityY) * rainIntensity.velocityMultiplier
            let currentVelocityY = min(initialVelocityY + CGFloat(dropAge) * gravityPerSecond * CGFloat(rainIntensity.velocityMultiplier),
                                     (1200.0 / screenSize.height) * CGFloat(rainIntensity.velocityMultiplier))
            
            let startY: CGFloat = drop.layer == 0 ? -0.5 : (drop.layer == 1 ? -0.3 : -0.2)
            let currentY = startY + currentVelocityY * CGFloat(dropAge)
            let y = currentY * screenSize.height
            
 // 检测落地（接近底部）
            if y >= groundLevel - 10 && y <= groundLevel + 10 {
                hitCount += 1
            }
        }
        
 // 根据落地雨滴数量增加水位
        if hitCount > 0 {
            let waterAmount = CGFloat(hitCount) * 0.00005 * CGFloat(rainIntensity.dropCountMultiplier)
            waterPuddle.addWater(amount: waterAmount)
            
 // 生成涟漪
            if waterPuddle.ripples.count < 30 {
                for _ in 0..<min(hitCount, 3) {
                    let rippleX = CGFloat.random(in: 0...screenSize.width)
                    waterPuddle.ripples.append(CinematicRainWaterRipple(
                        x: rippleX,
                        y: groundLevel,
                        radius: 0,
                        opacity: 1.0,
                        lifetime: 0
                    ))
                }
            }
        }
    }
    
 /// 更新积水系统（蒸发、波纹动画）
    private func updateWaterPuddle() {
 // 缓慢蒸发（如果不下雨）
        if waterPuddle.waterLevel > 0 {
            waterPuddle.evaporate(rate: 0.00001)  // 缓慢蒸发
        }
        
 // 更新波纹动画
        waterPuddle.waveOffset += 0.02
        
 // 更新涟漪
        for i in (0..<waterPuddle.ripples.count).reversed() {
            waterPuddle.ripples[i].lifetime += 0.05
            waterPuddle.ripples[i].radius = CGFloat(waterPuddle.ripples[i].lifetime) * 60
            waterPuddle.ripples[i].opacity = max(0, 1.0 - Double(waterPuddle.ripples[i].lifetime) / 1.5)
            
            if waterPuddle.ripples[i].opacity <= 0 {
                waterPuddle.ripples.remove(at: i)
            }
        }
    }
    
 /// 大气雾效
    private func drawAtmosphericFog(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
 // 🌫️ 根据风噪等级动态调制雾层透明度，风越大雾层扰动越明显
        let mod1 = max(0.0, min(0.12, ambientWindNoiseLevel * 0.06 + 0.05))
        let mod2 = max(0.0, min(0.10, ambientWindNoiseLevel * 0.04 + 0.03))
        let fogGradient = Gradient(colors: [
            Color.clear,
            Color(red: 0.5, green: 0.5, blue: 0.55).opacity(mod1),
            Color(red: 0.4, green: 0.4, blue: 0.45).opacity(mod2)
        ])

        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                fogGradient,
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

 /// 启动镜面反射闪烁系统（积水反射的细微抖动）
    private func startReflectionFlickerSystem() {
        reflectionFlickerTimer?.invalidate()
        reflectionFlickerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [self] _ in
            Task { @MainActor in
                guard !isRemoteDesktopActive else { return }
                let t = Date().timeIntervalSinceReferenceDate
 // 两组较快的正弦叠加，产生细微闪烁（范围约 0.9 - 1.1）
                let s = sin(t * 2.4) * 0.5 + sin(t * 3.8 + 1.2) * 0.3
                reflectionFlickerFactor = 0.95 + max(-0.1, min(0.1, s))
            }
        }
    }

 // MARK: - 统一调度用的更新方法（替代原 Timer 回调）
    private func scheduleTick(remoteActive: Bool, now: Date) {
 // 统一帧调度入口，计算dt并按节拍驱动各子系统
        Task { @MainActor in
            let dt = max(0, now.timeIntervalSince(lastTick))
            lastTick = now
            guard !remoteActive else { return }
 // 风力：每 0.05s 更新一次
            windAcc += dt
            if windAcc >= 0.05 {
                updateWind()
                windAcc = 0
            }
 // 风噪：每 0.12s 更新一次
            windNoiseAcc += dt
            if windNoiseAcc >= 0.12 {
                updateWindNoise()
                windNoiseAcc = 0
            }
 // 镜面反射闪烁：按配置自适应更新间隔（极致0.08/平衡0.10/节能0.12）
            let refInterval: TimeInterval = {
                if let cfg = performanceConfig {
                    switch cfg.postProcessingLevel {
                    case 2: return 0.08
                    case 1: return 0.10
                    default: return 0.12
                    }
                } else {
                    return 0.10
                }
            }()
            reflectionAcc += dt
            if reflectionAcc >= refInterval {
                updateReflectionFlicker()
                reflectionAcc = 0
            }
 // 挂壁水珠更新：每 0.15s 一次
            wallUpdateAcc += dt
            if wallUpdateAcc >= 0.15 {
                updateWallWaterDrops()
                wallUpdateAcc = 0
            }
 // 积水系统更新：每 0.15s 一次
            puddleAcc += dt
            if puddleAcc >= 0.15 {
                detectRaindropsHittingGround()
                updateWaterPuddle()
                puddleAcc = 0
            }
 // 闪电事件：随机 5-12 秒一次
            lightningAcc += dt
            if lightningAcc >= nextLightningInterval {
                triggerLightningFlash()
                lightningAcc = 0
                nextLightningInterval = Double.random(in: 5...12)
            }
        }
    }
    private func updateWind() {
 // 风速与方向按时间驱动，并受雨强度影响
        let t = Date().timeIntervalSinceReferenceDate
        let baseSpeed = sin(t * 0.3) * 150 + cos(t * 0.15) * 50
        windSpeed = baseSpeed * rainIntensity.windMultiplier
        windDirection = sin(t * 0.1)
    }

    private func updateWindNoise() {
 // 风噪等级 0-1，受风速幅值影响
        let t = Date().timeIntervalSinceReferenceDate
        let base = (sin(t * 0.37) + sin(t * 0.21 + 1.3)) * 0.5
        let windScale = min(1.0, max(0.0, Double(abs(windSpeed) / 200.0)))
        ambientWindNoiseLevel = min(1.0, max(0.0, (base * 0.5 + 0.5) * windScale))
    }

    private func updateReflectionFlicker() {
 // 积水反射的细微闪烁调制
        let t = Date().timeIntervalSinceReferenceDate
        let s = sin(t * 2.4) * 0.5 + sin(t * 3.8 + 1.2) * 0.3
        reflectionFlickerFactor = 0.95 + max(-0.1, min(0.1, s))
    }

    private func triggerLightningFlash() {
 // 触发一次闪电事件（与原 Timer 动画一致）
        withAnimation(.linear(duration: 0.05)) {
            lightningOpacity = Double.random(in: 0.5...1.0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.linear(duration: 0.05)) {
                lightningOpacity = 0.3
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.3)) {
                lightningOpacity = 0
            }
        }
    }
}

// MARK: - 🌟 雨滴质量配置（按性能模式优化）

/// 雨滴质量配置结构
struct RainQualityConfig {
    let name: String
    let baseLength: CGFloat
    let enableAdvancedEffects: Bool  // 🌟 是否启用高级效果（渐变、尾迹等）
    
 /// 根据景深层获取雨滴厚度
    func thickness(layer: Int) -> CGFloat {
        switch layer {
        case 0: return farThickness   // 远景
        case 1: return midThickness   // 中景
        case 2: return nearThickness  // 近景
        default: return midThickness
        }
    }
    
 /// 根据景深层获取雨滴透明度
    func opacity(layer: Int) -> Double {
        switch layer {
        case 0: return farOpacity   // 远景
        case 1: return midOpacity   // 中景
        case 2: return nearOpacity  // 近景
        default: return midOpacity
        }
    }
    
 // 各层配置
    let farThickness: CGFloat
    let midThickness: CGFloat
    let nearThickness: CGFloat
    let farOpacity: Double
    let midOpacity: Double
    let nearOpacity: Double
    
 /// 标准初始化器
    init(name: String, baseLength: CGFloat, enableAdvancedEffects: Bool,
         farThickness: CGFloat, midThickness: CGFloat, nearThickness: CGFloat,
         farOpacity: Double, midOpacity: Double, nearOpacity: Double) {
        self.name = name
        self.baseLength = baseLength
        self.enableAdvancedEffects = enableAdvancedEffects
        self.farThickness = farThickness
        self.midThickness = midThickness
        self.nearThickness = nearThickness
        self.farOpacity = farOpacity
        self.midOpacity = midOpacity
        self.nearOpacity = nearOpacity
    }
    
 /// 🌟 插值初始化（用于自适应模式的平滑过渡）
    init(interpolationFactor: Float, between energySaving: RainQualityConfig, and extreme: RainQualityConfig) {
        let t = CGFloat(max(0.0, min(1.0, interpolationFactor)))
        
        self.name = t > 0.75 ? "自适应(极致)" : (t > 0.5 ? "自适应(平衡)" : "自适应(节能)")
        self.baseLength = energySaving.baseLength + (extreme.baseLength - energySaving.baseLength) * t
        self.enableAdvancedEffects = t > 0.6  // 60%以上启用高级效果
        
 // 插值计算各层参数
        self.farThickness = energySaving.farThickness + (extreme.farThickness - energySaving.farThickness) * t
        self.midThickness = energySaving.midThickness + (extreme.midThickness - energySaving.midThickness) * t
        self.nearThickness = energySaving.nearThickness + (extreme.nearThickness - energySaving.nearThickness) * t
        
        self.farOpacity = energySaving.farOpacity + (extreme.farOpacity - energySaving.farOpacity) * Double(t)
        self.midOpacity = energySaving.midOpacity + (extreme.midOpacity - energySaving.midOpacity) * Double(t)
        self.nearOpacity = energySaving.nearOpacity + (extreme.nearOpacity - energySaving.nearOpacity) * Double(t)
    }
    
 /// 极致模式：最精细的雨滴效果
    static let extreme = RainQualityConfig(
        name: "极致",
        baseLength: 30.0,  // 长雨滴
        enableAdvancedEffects: true,  // ✅ 启用完整效果
        farThickness: 3.5,  // 远景清晰
        midThickness: 3.0,  // 中景清晰
        nearThickness: 2.5, // 近景清晰
        farOpacity: 0.9,    // 远景高可见度
        midOpacity: 0.75,   // 中景高可见度
        nearOpacity: 0.6    // 近景高可见度
    )
    
 /// 自适应模式（优质）：高质量雨滴
    static let adaptiveHigh = RainQualityConfig(
        name: "自适应(优质)",
        baseLength: 25.0,  // 较长雨滴
        enableAdvancedEffects: true,  // ✅ 启用完整效果
        farThickness: 3.0,
        midThickness: 2.5,
        nearThickness: 2.0,
        farOpacity: 0.85,
        midOpacity: 0.7,
        nearOpacity: 0.55
    )
    
 /// 平衡模式：标准雨滴效果
    static let balanced = RainQualityConfig(
        name: "平衡",
        baseLength: 22.0,  // 标准长度
        enableAdvancedEffects: false,  // ❌ 简化效果
        farThickness: 2.5,
        midThickness: 2.0,
        nearThickness: 1.8,
        farOpacity: 0.8,
        midOpacity: 0.65,
        nearOpacity: 0.5
    )
    
 /// 节能模式：简化雨滴效果
    static let energySaving = RainQualityConfig(
        name: "节能",
        baseLength: 18.0,  // 较短雨滴
        enableAdvancedEffects: false,  // ❌ 简化效果
        farThickness: 2.0,
        midThickness: 1.5,
        nearThickness: 1.5,
        farOpacity: 0.7,
        midOpacity: 0.55,
        nearOpacity: 0.4
    )
    
 /// 自适应模式（节能）：最少效果
    static let adaptiveLow = RainQualityConfig(
        name: "自适应(节能)",
        baseLength: 15.0,  // 短雨滴
        enableAdvancedEffects: false,  // ❌ 简化效果
        farThickness: 1.8,
        midThickness: 1.5,
        nearThickness: 1.2,
        farOpacity: 0.6,
        midOpacity: 0.45,
        nearOpacity: 0.3
    )
}

#endif
