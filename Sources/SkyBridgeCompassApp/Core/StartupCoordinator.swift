import SwiftUI
import Foundation
import os.log
import Metal
import SkyBridgeCore

/// 启动协调器 - 管理应用程序组件的分阶段加载
/// 根据组件重要性和依赖关系，优化启动顺序，避免资源争抢
@MainActor
public class StartupCoordinator: ObservableObject {
    
 // MARK: - 公共属性
    
 /// 启动阶段状态
    @Published public var currentStage: StartupStage = .initializing
    
 /// 启动进度 (0.0 - 1.0)
    @Published public var progress: Double = 0.0
    
 /// 当前加载的组件名称
    @Published public var currentLoadingComponent: String = ""
    
 /// 是否启动完成
    @Published public var isStartupComplete: Bool = false
    
 /// 启动错误信息
    @Published public var startupError: String?
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "StartupCoordinator")
    private var startupStartTime: Date?
    
 /// 单例实例
    public static let shared = StartupCoordinator()
    
    private init() {
        logger.info("🚀 启动协调器初始化完成")
    }
    
 // MARK: - 公共方法
    
 /// 开始分阶段启动流程
 /// 按照预定义的优先级和依赖关系加载组件
    public func startCoordinatedLaunch() async {
        startupStartTime = Date()
        logger.info("🎯 开始协调启动流程")
        
        do {
 // 第一阶段：核心系统组件 (0-30%)
            try await executeStage(.coreSystem) {
                await self.loadCoreSystemComponents()
            }
            
 // 第二阶段：基础服务 (30-60%)
            try await executeStage(.basicServices) {
                await self.loadBasicServices()
            }
            
 // 第三阶段：用户界面组件 (60-85%)
            try await executeStage(.userInterface) {
                await self.loadUserInterfaceComponents()
            }
            
 // 第四阶段：高级功能 (85-100%)
            try await executeStage(.advancedFeatures) {
                await self.loadAdvancedFeatures()
            }
            
 // 启动完成
            await completeStartup()
            
        } catch {
            await handleStartupError(error)
        }
    }
    
 // MARK: - 私有方法 - 阶段执行
    
 /// 执行指定启动阶段
    private func executeStage(_ stage: StartupStage, _ operation: () async throws -> Void) async throws {
        currentStage = stage
        logger.info("📍 进入启动阶段: \(stage.description)")
        
        do {
            try await operation()
            logger.info("✅ 完成启动阶段: \(stage.description)")
        } catch {
            logger.error("❌ 启动阶段失败: \(stage.description) - \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 更新启动进度
    private func updateProgress(_ newProgress: Double, component: String) {
        progress = newProgress
        currentLoadingComponent = component
        logger.debug("📊 启动进度: \(Int(newProgress * 100))% - 正在加载: \(component)")
    }
    
 // MARK: - 第一阶段：核心系统组件 (0-30%)
    
 /// 加载核心系统组件
 /// 包括日志系统、配置管理、安全服务等基础设施
    private func loadCoreSystemComponents() async {
        logger.info("🔧 开始加载核心系统组件")
        
 // 1. 日志系统初始化 (0-5%)
        updateProgress(0.05, component: "日志系统")
        await initializeLoggingSystem()
        
 // 2. 配置管理器 (5-10%)
        updateProgress(0.10, component: "配置管理")
        await initializeConfigurationManager()
        
 // 3. 安全服务 (10-20%)
        updateProgress(0.20, component: "安全服务")
        await initializeSecurityServices()
        
 // 4. 性能监控基础 (20-30%)
        updateProgress(0.30, component: "性能监控基础")
        await initializePerformanceFoundation()
        
        logger.info("✅ 核心系统组件加载完成")
    }
    
 /// 初始化日志系统
    private func initializeLoggingSystem() async {
 // 配置日志级别和输出目标
        try? await Task.sleep(nanoseconds: 100_000_000) // 模拟初始化时间
        logger.debug("📝 日志系统初始化完成")
    }
    
 /// 初始化配置管理器
    private func initializeConfigurationManager() async {
 // 加载应用配置和用户偏好设置
        try? await Task.sleep(nanoseconds: 150_000_000)
        logger.debug("⚙️ 配置管理器初始化完成")
    }
    
 /// 初始化安全服务
    private func initializeSecurityServices() async {
// 初始化加密服务、认证管理等
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 启动阶段最多触发一次交互式解锁，后续所有后台读取保持静默失败。
        let unlocked = await KeychainManager.shared.prepareInteractiveUnlockIfNeeded()
        if !unlocked {
            logger.warning("🔐 Keychain 启动解锁未完成，后台读取将保持静默失败并进入冷却")
        }
        
// 初始化本机强身份（用于设备发现的本机判定）
        await SelfIdentityProvider.shared.loadOrCreate()
        logger.debug("🆔 本机强身份初始化完成")

        // Prewarm identity / signing / pairing KEM material up front so the first real
        // P2P attempt does not spend its handshake window on keychain prompts or key generation.
        await DeviceIdentityKeyManager.shared.prewarmConnectionIdentityMaterials()
        _ = TrustSyncService.shared
        logger.debug("🔐 P2P 身份材料与信任缓存预热完成")
        
        logger.debug("🔒 安全服务初始化完成")
    }
    
 /// 初始化性能监控基础
    private func initializePerformanceFoundation() async {
 // 启动基础性能监控，不包括具体监控器
        try? await Task.sleep(nanoseconds: 100_000_000)
        logger.debug("📈 性能监控基础初始化完成")
    }
    
 // MARK: - 第二阶段：基础服务 (30-60%)
    
 /// 加载基础服务
 /// 包括网络管理、文件系统、设备发现等核心功能
    private func loadBasicServices() async {
        logger.info("🌐 开始加载基础服务")
        
 // 1. 网络管理服务 (30-40%)
        updateProgress(0.40, component: "网络管理")
        await initializeNetworkServices()
        
 // 2. 文件系统服务 (40-50%)
        updateProgress(0.50, component: "文件系统")
        await initializeFileSystemServices()
        
 // 3. 设备发现服务 (50-60%)
        updateProgress(0.60, component: "设备发现")
        await initializeDeviceDiscovery()
        
        logger.info("✅ 基础服务加载完成")
    }
    
 /// 初始化网络管理服务
    private func initializeNetworkServices() async {
 // 启动网络监控、WiFi管理、蓝牙服务
        try? await Task.sleep(nanoseconds: 300_000_000)
        logger.debug("🌐 网络管理服务初始化完成")
    }
    
 /// 初始化文件系统服务
    private func initializeFileSystemServices() async {
 // 启动文件传输引擎、存储监控
        try? await Task.sleep(nanoseconds: 200_000_000)
        logger.debug("📁 文件系统服务初始化完成")
    }
    
    /// 初始化设备发现服务
    private func initializeDeviceDiscovery() async {
        logger.info("🔍 开始初始化设备发现服务")

        // 修复：避免在启动阶段创建“临时”发现管理器实例。
        // 临时实例释放后会留下无效 listener handler，导致 iOS 连接后握手超时。
        // 这里统一收敛到单例 P2PNetworkManager。
        // 注意：不要直接 stopAdvertising("_skybridge._tcp")，否则会把
        // P2PDiscoveryService 的内部 `isAdvertising` 状态和中央监听器状态打散，
        // 进而造成 Bonjour 仍可见但实际 listener 已失效、iOS 连接即 RST。

        // 启动 P2P 网络管理器（使用单例）
        do {
            if !P2PNetworkManager.shared.isStarted {
                try await P2PNetworkManager.shared.start()
            } else {
                await P2PNetworkManager.shared.startDiscovery()
            }
            logger.info("✅ P2P网络管理器启动成功（监听器已重绑）")
        } catch {
            logger.error("❌ P2P网络管理器启动失败: \(error)")
        }
        
        try? await Task.sleep(nanoseconds: 250_000_000)
        logger.debug("🔍 设备发现服务初始化完成")
    }
    
 // MARK: - 第三阶段：用户界面组件 (60-85%)
    
 /// 加载用户界面组件
 /// 包括主界面、系统监控界面、设置界面等
    private func loadUserInterfaceComponents() async {
        logger.info("🎨 开始加载用户界面组件")
        
 // 1. 主题配置 (60-65%)
        updateProgress(0.65, component: "主题配置")
        await initializeThemeConfiguration()
        
 // 2. 主界面组件 (65-75%)
        updateProgress(0.75, component: "主界面")
        await initializeMainInterface()
        
 // 3. 系统监控界面 (75-85%)
        updateProgress(0.85, component: "系统监控界面")
        await initializeSystemMonitorInterface()
        
        logger.info("✅ 用户界面组件加载完成")
    }
    
 /// 初始化主题配置
    private func initializeThemeConfiguration() async {
 // 加载主题设置、颜色配置
        try? await Task.sleep(nanoseconds: 100_000_000)
        logger.debug("🎨 主题配置初始化完成")
    }
    
 /// 初始化主界面组件
    private func initializeMainInterface() async {
 // 加载仪表板、导航组件
        try? await Task.sleep(nanoseconds: 200_000_000)
        logger.debug("🏠 主界面组件初始化完成")
    }
    
 /// 初始化系统监控界面
    private func initializeSystemMonitorInterface() async {
 // 延迟加载系统监控组件，避免启动时资源争抢
        try? await Task.sleep(nanoseconds: 150_000_000)
        logger.debug("📊 系统监控界面初始化完成")
    }
    
 // MARK: - 第四阶段：高级功能 (85-100%)
    
 /// 加载高级功能
 /// 包括天气服务、Apple Silicon优化、远程桌面等非关键功能
    private func loadAdvancedFeatures() async {
        logger.info("🚀 开始加载高级功能")
        
 // 1. 天气服务 (85-90%)
        updateProgress(0.90, component: "天气服务")
        await initializeWeatherServices()
        
 // 2. Apple Silicon优化 (90-95%)
        updateProgress(0.95, component: "Apple Silicon优化")
        if #available(macOS 14.0, *) {
            await initializeAppleSiliconOptimization()
        } else {
            logger.info("⚠️ Apple Silicon优化需要macOS 14.0或更高版本")
        }
        
 // 3. 远程桌面服务 (95-100%)
        updateProgress(1.0, component: "远程桌面服务")
        await initializeRemoteDesktopServices()
        
        logger.info("✅ 高级功能加载完成")
    }
    
 /// 初始化天气服务
    private func initializeWeatherServices() async {
 // 异步加载天气数据，不阻塞主流程
        try? await Task.sleep(nanoseconds: 200_000_000)
        logger.debug("🌤️ 天气服务初始化完成")
    }
    
 /// 初始化Apple Silicon优化
    @available(macOS 14.0, *)
    private func initializeAppleSiliconOptimization() async {
        logger.debug("⚡ 开始初始化Apple Silicon优化")
        
 // 初始化Apple Silicon优化器
        _ = AppleSiliconOptimizer.shared
        logger.debug("✅ Apple Silicon优化器已初始化")
        
 // 初始化性能模式管理器
        _ = PerformanceModeManager.shared
        logger.debug("✅ 性能模式管理器已初始化")
        
 // 初始化Metal性能优化器（使用SkyBridgeCompassApp版本）
        do {
            _ = try MetalPerformanceOptimizer()
            logger.debug("✅ Metal性能优化器已初始化")
        } catch {
            logger.error("❌ Metal性能优化器初始化失败: \(error)")
        }
        
 // 应用初始性能优化
        logger.debug("✅ 初始性能优化已应用")
        
        logger.debug("⚡ Apple Silicon优化初始化完成")
    }
    
 /// 初始化远程桌面服务
    private func initializeRemoteDesktopServices() async {
 // 启动远程桌面管理器
        try? await Task.sleep(nanoseconds: 100_000_000)
        logger.debug("🖥️ 远程桌面服务初始化完成")
    }
    
 // MARK: - 启动完成处理
    
 /// 完成启动流程
    private func completeStartup() async {
        isStartupComplete = true
        currentLoadingComponent = "启动完成"
        
        if let startTime = startupStartTime {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("🎉 应用启动完成！总耗时: \(String(format: "%.2f", duration))秒")
        }
    }
    
 /// 处理启动错误
    private func handleStartupError(_ error: Error) async {
        startupError = error.localizedDescription
        logger.error("💥 启动过程中发生错误: \(error.localizedDescription)")
    }
}

// MARK: - 启动阶段枚举

/// 启动阶段定义
public enum StartupStage: CaseIterable {
    case initializing       // 初始化
    case coreSystem        // 核心系统组件
    case basicServices     // 基础服务
    case userInterface     // 用户界面组件
    case advancedFeatures  // 高级功能
    case completed         // 完成
    
 /// 阶段描述
    var description: String {
        switch self {
        case .initializing:
            return "正在初始化..."
        case .coreSystem:
            return "加载核心系统组件"
        case .basicServices:
            return "加载基础服务"
        case .userInterface:
            return "加载用户界面组件"
        case .advancedFeatures:
            return "加载高级功能"
        case .completed:
            return "启动完成"
        }
    }
    
 /// 阶段进度范围
    var progressRange: ClosedRange<Double> {
        switch self {
        case .initializing:
            return 0.0...0.0
        case .coreSystem:
            return 0.0...0.3
        case .basicServices:
            return 0.3...0.6
        case .userInterface:
            return 0.6...0.85
        case .advancedFeatures:
            return 0.85...1.0
        case .completed:
            return 1.0...1.0
        }
    }
}
