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

/// 雨滴粒子。
///
/// 只保留绘制真正会读的字段。此前还带着 y / velocityX / acceleration / mass /
/// rotation / deformation / thickness / opacity / trail 九个字段——它们的读取方
/// 全在逐帧物理模拟里，而现在轨迹是按时间闭式求值的，那套模拟已经删除。
/// 尤其 thickness / opacity 会误导人：它们看着像是每滴雨的绘制参数，实际上
/// 绘制读的是 `activeQualityConfiguration`，改这里不会有任何效果。
struct PhysicsRaindrop: Identifiable {
    let id = UUID()
 /// 归一化的水平起始位置（0-1）
    var x: CGFloat
 /// 初始垂直速度。首次使用时按屏幕高度归一化（>1 视为像素单位）。
    var velocityY: CGFloat
 /// 雨丝基础长度，实际长度再按当前速度拉伸
    let baseLength: CGFloat
    let layer: Int  // 景深层次
 // 预计算的循环相位（0-1）。此前每帧用 `id.hashValue` 现算相位：既是每帧
 // 每滴一次哈希的白白开销，又因为相位只铺满周期的 3/5，导致雨滴成批同时
 // 重生，屏幕上能看见一道道“雨带”和空档——这正是雨看起来很假的主因之一。
    let phase: Double
 // 每滴雨自己的循环时长（秒），让重生时刻彻底错开，不再整屏同步复位。
    let cycle: Double
 // 亮度档位（0=偏暗的更远的一批，1=偏亮的更近的一批）。在同一景深层内再分两档，
 // 既能让雨幕有层次，又不会破坏批量绘制（一档一次 stroke）。
    let brightnessTier: Int
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
 // 动画时间原点。与其他电影级天气效果保持一致：用相对本次运行的秒数驱动动画，
 // 而不是 `timeIntervalSinceReferenceDate` 那个 7.8e8 量级的绝对值——后者会把
 // Double 的有效精度吃掉大半，让 sin/取余在高帧率下产生可见的抖动与跳变。
    private static let animationEpoch = Date()

 // 模拟子系统的节拍间隔（秒）。挂壁水珠、积水、闪电这些是有状态的模拟，
 // 无法写成时间的纯函数，仍需按节拍推进。
    private static let simulationTickInterval: TimeInterval = 0.15

 // 物理粒子状态
    @State private var raindrops: [PhysicsRaindrop] = []
    @State private var glassDrops: [DynamicGlassDrop] = []
    @State private var ripples: [CinematicRainWaterRipple] = []
    
 // 🌟 OPPO风格：挂壁水珠系统
    @State private var wallWaterDrops: [WallWaterDrop] = []
    
 // 🌟 底部积水系统
    @State private var waterPuddle = CinematicRainWaterPuddle()
    
 // 天气状态
 // 风速、风噪、反射闪烁都已改为时间的纯函数（见 `windSpeed(at:multiplier:)` 等），
 // 不再作为 @State 由计时器写入：既省掉每秒几十次的状态写入与视图失效，
 // 也让它们的变化在任意帧率下都完全平滑。
    @State private var lightningOpacity: Double = 0
    
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

 // 质量档位缓存。此前 `getQualityConfiguration()` 每帧都要重新推导一遍
 // （还在 detect 回调里再算一次）；它只依赖 performanceConfig，配置变了才需要重算。
    @State private var activeQualityConfiguration: RainQualityConfig = .balanced

 // 🌟 动态帧率（根据性能模式）
    @State private var currentFrameRate: Double = 60.0
    
 // 自适应帧率计时器。这是本视图仅存的计时器：它只在自适应模式下按 0.5s
 // 采样一次目标帧率，不参与任何逐帧绘制。以属性持有以便视图消失时注销。
    @State private var adaptiveFrameRateTimer: Timer?

 // 模拟节拍状态：`lastTickIndex` 让每个节拍只推进一次（幂等门）。
    @State private var lastTickIndex: Int = -1
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
                    let time = timeline.date.timeIntervalSince(Self.animationEpoch)
 // ✅ 捕获局部常量，避免在 Sendable 闭包中直接访问主线程隔离的 @State
                    let remoteActive = isRemoteDesktopActive
                    let _ = scheduleTick(remoteActive: remoteActive, time: time)

 // 说明：这里刻意保持 Canvas 的默认参数。
 // `colorMode: .nonLinear` 会改变渐变的混合色彩空间，体积云与涟漪都是渐变绘制的，
 // 换色彩空间就会改变它们的观感；`rendersAsynchronously: true` 则会让绘制闭包
 // 脱离主线程，而本闭包要读取由节拍任务在主线程改写的 @State（积水、挂壁水珠），
 // 那是实打实的数据竞争。两者都不值得为这点收益去换。
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
 // 🔥 驱散效果。任何小于 1 的不透明度都会让 SwiftUI 走离屏合成（每帧多一张全屏缓冲）。
 // 未驱散时 globalOpacity 可能是 0.9999… 这类浮点余数，白白把离屏通道一直开着；
 // 这里吸附到精确的 1.0，让 SwiftUI 能把它当作恒等变换直接跳过。
                .opacity(clearManager.globalOpacity >= 0.999 ? 1.0 : clearManager.globalOpacity)
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
        startAdaptiveFrameRateUpdateIfNeeded()
    }

 /// 启动自适应帧率更新（30-120fps动态调整）。
 /// ⚠️ 旧实现每次调用都新建一个 0.5s 重复计时器且从不注销：视图每次出现、
 /// 每次性能模式变化都会再叠一个，计时器越积越多且视图消失后仍在跑。
 /// 现在以属性持有，重复调用先注销旧的，视图消失时一并停掉。
    private func startAdaptiveFrameRateUpdateIfNeeded() {
        adaptiveFrameRateTimer?.invalidate()
        adaptiveFrameRateTimer = nil

        guard let manager = try? PerformanceModeManager(), manager.currentMode == .adaptive else {
            return
        }

        adaptiveFrameRateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
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

 // 获取性能配置，优化雨滴效果。
 // 质量档只依赖 performanceConfig，这里推导一次并缓存，绘制时直接读缓存。
        let qualityConfig = getQualityConfiguration()
        activeQualityConfiguration = qualityConfig
        
 // 创建三层景深雨滴
        let layers: [(count: Int, layer: Int)] = [
            (farCount, 0),  // 远景
            (midCount, 1),  // 中景
            (nearCount, 2)  // 近景
        ]
        
        for (count, layer) in layers {
            for _ in 0..<count {
 // 说明：起始高度不再逐滴随机存进粒子里——绘制按景深层取固定的
 // startY（远景 -0.5 / 中景 -0.3 / 近景 -0.2），错开靠的是每滴各自的
 // phase 与 cycle，效果更均匀，也少存一个字段。
 // 速度先用像素单位，绘制时按屏幕高度归一化。
                raindrops.append(PhysicsRaindrop(
                    x: CGFloat.random(in: 0...1),
 // 初速度较小，下落过程中受重力加速；绘制时按屏幕高度归一化
                    velocityY: CGFloat.random(in: 100...300),
                    baseLength: qualityConfig.baseLength * CGFloat.random(in: 0.8...1.2),  // 🌟 性能适配长度
                    layer: layer,
 // 相位在整个周期内均匀取样，配合各自不同的周期时长，
 // 让雨幕连续不断而不是一波一波地刷新。
                    phase: Double.random(in: 0..<1),
                    cycle: Double.random(in: 3.2...5.4),
                    brightnessTier: Int.random(in: 0..<Self.rainBrightnessTierCount)
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
    
 // MARK: - 统一暂停/恢复逻辑

 /// 集中暂停所有特效系统。
 /// 逐帧模拟由 TimelineView 的节拍驱动（远程桌面活跃时 `scheduleTick` 直接返回），
 /// 这里只需要停掉唯一的辅助计时器。
    private func pauseAllEffectSystems() {
        adaptiveFrameRateTimer?.invalidate()
        adaptiveFrameRateTimer = nil
    }

 /// 恢复所有特效系统。
 /// 说明：TimelineView 已负责帧驱动，自适应帧率采样会在需要时重新装配。
    private func resumeAllEffectSystems() {
        if performanceConfig != nil {
            startAdaptiveFrameRateUpdateIfNeeded()
        }
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
    
 // MARK: - 雨幕批量渲染

 /// 雨丝颜色：接近中性的冷白。
 /// 旧实现给每滴雨刷了一条 白→青→蓝→白 的渐变外加一条 0.95 不透明度的白色高光，
 /// 那既是最贵的一笔绘制开销，也是雨"看着很假"的直接原因——真实雨丝是低对比度的
 /// 去饱和亮线，不会是饱和的青蓝色霓虹管。
    private static let rainStreakColor = Color(red: 0.86, green: 0.90, blue: 0.97)
 /// 驱散档位数量：最后一档（索引 = count-1）表示"完全没被驱散"的快速路径。
    private static let disperseBucketCount = 5
 /// 同一景深层内再分的亮度档数。
    private static let rainBrightnessTierCount = 2
 /// 各亮度档的透明度 / 线宽系数（档 0 更远更暗更细，档 1 更近更亮更粗）。
    private static let rainTierAlpha: [Double] = [0.68, 1.0]
    private static let rainTierThickness: [CGFloat] = [0.78, 1.0]
    private static let rainDepthLayerCount = 3

 /// 🌧️ 批量渲染雨幕：按「景深层 × 亮度档 × 驱散档」把所有雨丝聚合进极少数几条 Path，
 /// 每个组合只调用一次 `stroke`。
 ///
 /// 旧实现是逐滴绘制：每滴雨都要新建 Path、新建 CGAffineTransform、`path.applying(...)`
 /// 复制一遍几何，再用 `.linearGradient` 描边（每滴一份渐变着色器），外加一条高光描边。
 /// 极致档 450 滴 × 2 次描边 = 每帧约 900 次绘制调用、900 次 Path 分配；120fps 下就是每秒
 /// 十万量级。现在无论多少滴雨，常规情况下每帧只有 6 次描边（3 景深 × 2 亮度档），
 /// 鼠标驱散时最多 30 次。
    private func drawRaindropsWithTime(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard !raindrops.isEmpty, size.width > 0, size.height > 0 else { return }

        let quality = activeQualityConfiguration
        let zones = clearManager.clearZones
        let hasZones = !zones.isEmpty

        let bucketCount = Self.disperseBucketCount
        let tierCount = Self.rainBrightnessTierCount
        let layerCount = Self.rainDepthLayerCount
        let slotCount = layerCount * tierCount * bucketCount
        var batches = [Path](repeating: Path(), count: slotCount)
        var batchUsed = [Bool](repeating: false, count: slotCount)

        let velocityMultiplier = rainIntensity.velocityMultiplier
        let gravityPerSecond: CGFloat = 980.0 / size.height
        let terminalVelocity = (1200.0 / size.height) * velocityMultiplier
 // 风是时间的纯函数，直接在这里求值：既让飘移完全平滑（不再被 20Hz 的
 // 计时器量化成台阶），也省掉一个每帧都要读的 @State。
        let normalizedWind = Self.windSpeed(at: time, multiplier: rainIntensity.windMultiplier) / size.width

        for drop in raindrops {
 // 各自的相位 + 各自的周期时长 → 雨滴在时间轴上均匀铺开，不再成批重生
            let dropAge = (time / drop.cycle + drop.phase).truncatingRemainder(dividingBy: 1.0) * drop.cycle

            let initialVelocityY = (drop.velocityY > 1.0 ? drop.velocityY / size.height : drop.velocityY) * velocityMultiplier
            let currentVelocityY = min(
                initialVelocityY + CGFloat(dropAge) * gravityPerSecond * velocityMultiplier,
                terminalVelocity
            )

 // 起始高度按景深层分配：远景从更高处落下
            let startY: CGFloat = drop.layer == 0 ? -0.5 : (drop.layer == 1 ? -0.3 : -0.2)
            let currentY = startY + currentVelocityY * CGFloat(dropAge)
            let currentX = drop.x + normalizedWind * CGFloat(dropAge) * 0.3

            let totalHeight = 1.1 - startY
            let finalY = (currentY - startY).truncatingRemainder(dividingBy: totalHeight) + startY
 // ✅ 修复：负数取余仍是负数，被风吹到左边的雨滴会被判为屏幕外而整条消失；
 // 这里回绕到 [0,1)，雨幕在有风时才不会缺一块。
            var finalX = currentX.truncatingRemainder(dividingBy: 1.0)
            if finalX < 0 { finalX += 1 }

            let x = finalX * size.width
            let y = finalY * size.height

            guard y >= -100, y <= size.height + 100 else { continue }

 // 只有真的存在驱散区域时才做逐滴的距离判定（常态是零成本）
            var bucket = bucketCount - 1
            if hasZones {
                var disperseFactor: Double = 1.0
                for zone in zones {
                    let dx = x - zone.center.x
                    let dy = y - zone.center.y
                    let distanceSquared = dx * dx + dy * dy
                    let radiusSquared = zone.radius * zone.radius
                    guard distanceSquared < radiusSquared, radiusSquared > 0 else { continue }
                    let normalizedDist = sqrt(distanceSquared) / zone.radius
                    let falloff = 1.0 - normalizedDist * normalizedDist
                    disperseFactor = min(disperseFactor, 1.0 - Double(zone.strength) * falloff * 0.9)
                }
                guard disperseFactor > 0.05 else { continue }
                if disperseFactor < 0.999 {
                    bucket = min(bucketCount - 2, max(0, Int(disperseFactor * Double(bucketCount - 1))))
                }
            }

 // 速度越快拉得越长——这是雨丝该有的运动模糊
            let speedFactor = min(currentVelocityY / (800.0 / size.height), 1.5)
            let length = drop.baseLength * speedFactor
 // 倾斜由风与下落速度的比值决定；直接算出线段终点，
 // 省掉逐滴的 CGAffineTransform 构造与 Path 复制。
 // ✅ 修复：旧代码用 `rotated(by:)` 旋转 (0, length)，得到的水平分量是 -sin(angle)，
 // 于是雨丝的倾斜方向和它自己被风吹的漂移方向恰好相反——雨往右飘、线却往左倒。
 // 这里取 +sin(angle)，让倾斜与漂移一致。
            let angle = atan2(normalizedWind * 0.5, currentVelocityY)

            let slot = ((drop.layer * tierCount) + drop.brightnessTier) * bucketCount + bucket
            batches[slot].move(to: CGPoint(x: x, y: y))
            batches[slot].addLine(to: CGPoint(x: x + sin(angle) * length, y: y + cos(angle) * length))
            batchUsed[slot] = true
        }

 // 高质量档再补一层更宽更淡的底衬，模拟离焦/运动模糊的柔和感。
 // 这是整层一次描边，不是逐滴，所以代价只有几次绘制调用。
        let drawsGlow = quality.enableAdvancedEffects

        for layer in 0..<layerCount {
            let layerAlpha = quality.opacity(layer: layer)
            let layerThickness = quality.thickness(layer: layer)
            for tier in 0..<tierCount {
                let alphaScale = Self.rainTierAlpha[tier]
                let thicknessScale = Self.rainTierThickness[tier]
                for bucket in 0..<bucketCount {
                    let slot = ((layer * tierCount) + tier) * bucketCount + bucket
                    guard batchUsed[slot] else { continue }

                    let disperse = bucket == bucketCount - 1
                        ? 1.0
                        : (Double(bucket) + 0.5) / Double(bucketCount - 1)
                    let alpha = layerAlpha * alphaScale * disperse
                    guard alpha > 0.004 else { continue }
                    let width = layerThickness * thicknessScale

                    if drawsGlow {
                        context.stroke(
                            batches[slot],
                            with: .color(Self.rainStreakColor.opacity(alpha * 0.28)),
                            style: StrokeStyle(lineWidth: width * 2.6, lineCap: .round)
                        )
                    }

                    context.stroke(
                        batches[slot],
                        with: .color(Self.rainStreakColor.opacity(alpha)),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                }
            }
        }
    }

 /// 风速是时间的纯函数（原先由 20Hz 计时器写进 @State）。
 /// 直接求值可以让飘移平滑，并且让绘制路径不再依赖任何计时器节拍。
    private static func windSpeed(at time: TimeInterval, multiplier: CGFloat) -> CGFloat {
        (sin(time * 0.3) * 150 + cos(time * 0.15) * 50) * multiplier
    }

 /// 风噪等级（0-1），同样改为时间的纯函数，用于调制大气雾层。
    private static func ambientWindNoise(at time: TimeInterval, multiplier: CGFloat) -> Double {
        let base = (sin(time * 0.37) + sin(time * 0.21 + 1.3)) * 0.5
        let windScale = min(1.0, max(0.0, Double(abs(windSpeed(at: time, multiplier: multiplier)) / 200.0)))
        return min(1.0, max(0.0, (base * 0.5 + 0.5) * windScale))
    }

 /// 积水反射的细微闪烁，时间的纯函数。
    private static func reflectionFlicker(at time: TimeInterval) -> Double {
        let s = sin(time * 2.4) * 0.5 + sin(time * 3.8 + 1.2) * 0.3
        return 0.95 + max(-0.1, min(0.1, s))
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
 // 说明：闪烁因子范围约在 0.9-1.1 之间，保持细腻变化。
 // 改为按当前帧时间直接求值，取代原先由 12.5Hz 计时器写入的 @State。
        let flicker = max(0.8, min(1.2, Self.reflectionFlicker(at: time)))
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
    
 /// 检测雨滴落地，增加积水。
 /// 轨迹公式必须与 `drawRaindropsWithTime` 完全一致，否则涟漪会在看不见雨滴的
 /// 地方冒出来；这里改用同一套 `phase`/`cycle` 相位，并把时间从调用方传入
 /// （原先在循环里逐滴调用 `Date()`）。
    private func detectRaindropsHittingGround(time: TimeInterval) {
 // ✅ 修复：使用实际窗口尺寸
        let screenSize = currentWindowSize
        guard screenSize.height > 0 else { return }
        let groundLevel = screenSize.height * 0.95

        var hitCount = 0

        let velocityMultiplier = rainIntensity.velocityMultiplier
        let gravityPerSecond: CGFloat = 980.0 / screenSize.height
        let terminalVelocity = (1200.0 / screenSize.height) * velocityMultiplier

 // ✅ 性能优化：采样检测（只检测部分雨滴，而不是全部）
        let step = max(1, raindrops.count / 100)  // 最多检测100个
        for dropIndex in stride(from: 0, to: raindrops.count, by: step) {
            let drop = raindrops[dropIndex]

            let dropAge = (time / drop.cycle + drop.phase).truncatingRemainder(dividingBy: 1.0) * drop.cycle

            let initialVelocityY = (drop.velocityY > 1.0 ? drop.velocityY / screenSize.height : drop.velocityY) * velocityMultiplier
            let currentVelocityY = min(
                initialVelocityY + CGFloat(dropAge) * gravityPerSecond * velocityMultiplier,
                terminalVelocity
            )

            let startY: CGFloat = drop.layer == 0 ? -0.5 : (drop.layer == 1 ? -0.3 : -0.2)
 // ⚠️ 这里刻意**不做**回绕，与绘制路径不同。
 // 落地检测统计的是「一个下落周期里穿过底部检测带的次数」：不回绕时每个周期只算一次，
 // 回绕后每次屏幕穿越都会再算一次，命中数会涨 2.5-10 倍——积水几分钟就涨满、
 // 涟漪常年顶在 30 个上限。积水与涟漪的观感是要保持原样的，所以保持原有口径。
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
 // 🌫️ 根据风噪等级动态调制雾层透明度，风越大雾层扰动越明显。
 // 风噪同样改为按帧时间直接求值，取代原先由 8.3Hz 计时器写入的 @State。
        let noise = Self.ambientWindNoise(at: time, multiplier: rainIntensity.windMultiplier)
        let mod1 = max(0.0, min(0.12, noise * 0.06 + 0.05))
        let mod2 = max(0.0, min(0.10, noise * 0.04 + 0.03))
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

 // MARK: - 统一调度用的更新方法（替代原 Timer 回调）

 /// 按节拍推进有状态的模拟子系统。
 ///
 /// 旧实现每帧都 `Task { @MainActor in ... }` 派发一次：120fps 下每秒 120 次
 /// MainActor 任务入队，而里面绝大多数分支只是把累加器加一点点然后什么也不做。
 /// 风速 / 风噪 / 反射闪烁本来就是时间的纯函数，已改为在绘制时直接求值；
 /// 剩下真正有状态的（挂壁水珠、积水、闪电）按 `simulationTickInterval` 推进，
 /// 每秒只派发约 6.7 次任务。
    private func scheduleTick(remoteActive: Bool, time: TimeInterval) {
        guard !remoteActive else { return }
        let tickIndex = Int(time / Self.simulationTickInterval)
        guard tickIndex != lastTickIndex else { return }

        Task { @MainActor in
 // 同一节拍可能在任务真正执行前被多帧命中；这里做一次幂等门，
 // 保证每个节拍只推进一次模拟。
            guard tickIndex != lastTickIndex else { return }
            lastTickIndex = tickIndex

            updateWallWaterDrops()
            detectRaindropsHittingGround(time: time)
            updateWaterPuddle()

 // 闪电事件：随机 5-12 秒一次
            lightningAcc += Self.simulationTickInterval
            if lightningAcc >= nextLightningInterval {
                lightningAcc = 0
                nextLightningInterval = Double.random(in: 5...12)
                triggerLightningFlash()
            }
        }
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
    
 // ⚠️ 景深修正：旧数值把远景做成了「最粗最亮」（far 3.5px / 0.9），近景反而最细最淡，
 // 深度线索完全是反的——远处的雨看起来比眼前的还实，这是雨"很假"的另一半原因。
 // 现在改回物理正确的排序：远景又细又淡（但数量最多，撑起雨幕），近景更粗更亮（数量最少）。
 // 线宽也整体收窄：3.5px 的雨丝在 Retina 上是一根粗管子，真实雨丝是亚像素到 2px 的细线。

 /// 极致模式：最精细的雨滴效果
    static let extreme = RainQualityConfig(
        name: "极致",
        baseLength: 34.0,  // 长雨滴（速度越快拉得越长）
        enableAdvancedEffects: true,  // ✅ 启用柔化底衬
        farThickness: 1.1,  // 远景纤细
        midThickness: 1.6,  // 中景
        nearThickness: 2.3, // 近景最粗
        farOpacity: 0.28,   // 远景最淡
        midOpacity: 0.42,   // 中景
        nearOpacity: 0.58   // 近景最亮
    )

 /// 自适应模式（优质）：高质量雨滴
    static let adaptiveHigh = RainQualityConfig(
        name: "自适应(优质)",
        baseLength: 30.0,
        enableAdvancedEffects: true,  // ✅ 启用柔化底衬
        farThickness: 1.0,
        midThickness: 1.5,
        nearThickness: 2.1,
        farOpacity: 0.26,
        midOpacity: 0.39,
        nearOpacity: 0.54
    )

 /// 平衡模式：标准雨滴效果
    static let balanced = RainQualityConfig(
        name: "平衡",
        baseLength: 28.0,
        enableAdvancedEffects: false,  // ❌ 不画柔化底衬
        farThickness: 0.9,
        midThickness: 1.4,
        nearThickness: 2.0,
        farOpacity: 0.25,
        midOpacity: 0.38,
        nearOpacity: 0.52
    )

 /// 节能模式：简化雨滴效果
    static let energySaving = RainQualityConfig(
        name: "节能",
        baseLength: 23.0,
        enableAdvancedEffects: false,  // ❌ 不画柔化底衬
        farThickness: 0.8,
        midThickness: 1.2,
        nearThickness: 1.7,
        farOpacity: 0.23,
        midOpacity: 0.34,
        nearOpacity: 0.47
    )

 /// 自适应模式（节能）：最少效果
    static let adaptiveLow = RainQualityConfig(
        name: "自适应(节能)",
        baseLength: 20.0,
        enableAdvancedEffects: false,  // ❌ 不画柔化底衬
        farThickness: 0.8,
        midThickness: 1.1,
        nearThickness: 1.5,
        farOpacity: 0.21,
        midOpacity: 0.31,
        nearOpacity: 0.43
    )
}

#endif
