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
    
 /// 当前正在执行的启动步骤
    @Published public private(set) var currentStep: StartupStep?
    
 /// 已完成的启动步骤数
    @Published public private(set) var completedStepCount: Int = 0
    
 /// 是否启动完成
    @Published public var isStartupComplete: Bool = false
    
 /// 启动错误信息
    @Published public var startupError: String?

    public var totalStepCount: Int {
        StartupStep.allCases.count
    }
    
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
        resetStartupState()
        startupStartTime = Date()
        logger.info("🎯 开始协调启动流程")
        
        do {
 // 第一阶段：核心系统组件
            try await executeStage(.coreSystem) {
                try await self.loadCoreSystemComponents()
            }
            
 // 第二阶段：基础服务
            try await executeStage(.basicServices) {
                try await self.loadBasicServices()
            }
            
 // 第三阶段：用户界面组件
            try await executeStage(.userInterface) {
                try await self.loadUserInterfaceComponents()
            }
            
 // 第四阶段：高级功能
            try await executeStage(.advancedFeatures) {
                try await self.loadAdvancedFeatures()
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
        logger.info("📍 进入启动阶段: \(stage.logLabel)")
        
        do {
            try await operation()
            logger.info("✅ 完成启动阶段: \(stage.logLabel)")
        } catch {
            logger.error("❌ 启动阶段失败: \(stage.logLabel) - \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 执行真实的启动步骤，并在步骤完成时更新进度
    private func executeStep(_ step: StartupStep, _ operation: () async throws -> Void) async throws {
        currentStage = step.stage
        currentStep = step
        logger.info("🔄 启动步骤开始: \(step.logLabel)")
        await Task.yield()

        let stepStartTime = Date()

        do {
            try await operation()
            completedStepCount += 1
            progress = Double(completedStepCount) / Double(totalStepCount)

            let duration = Date().timeIntervalSince(stepStartTime)
            logger.info(
                "✅ 启动步骤完成: \(step.logLabel), progress=\(Int(self.progress * 100))%, duration=\(String(format: "%.2f", duration))s"
            )
            await Task.yield()
        } catch {
            logger.error("❌ 启动步骤失败: \(step.logLabel) - \(error.localizedDescription)")
            throw error
        }
    }

    private func resetStartupState() {
        currentStage = .initializing
        progress = 0.0
        currentStep = nil
        completedStepCount = 0
        isStartupComplete = false
        startupError = nil
    }
    
 // MARK: - 第一阶段：核心系统组件
    
 /// 加载核心系统组件
 /// 包括日志系统、配置管理、安全服务等基础设施
    private func loadCoreSystemComponents() async throws {
        logger.info("🔧 开始加载核心系统组件")
        
 // 1. 日志系统初始化
        try await executeStep(.loggingSystem) {
            await initializeLoggingSystem()
        }
        
 // 2. 配置管理器
        try await executeStep(.configurationManager) {
            await initializeConfigurationManager()
        }
        
 // 3. 安全服务
        try await executeStep(.securityServices) {
            await initializeSecurityServices()
        }
        
 // 4. 性能监控基础
        try await executeStep(.performanceFoundation) {
            await initializePerformanceFoundation()
        }
        
        logger.info("✅ 核心系统组件加载完成")
    }
    
 /// 初始化日志系统
    private func initializeLoggingSystem() async {
 // 日志设施已在 App 进程内可用，这里只做一次显式预热
        logger.debug("📝 日志系统初始化完成")
    }
    
 /// 初始化配置管理器
    private func initializeConfigurationManager() async {
 // 触发设置单例加载，确保用户偏好已可用
        _ = SettingsManager.shared
        logger.debug("⚙️ 配置管理器初始化完成")
    }
    
 /// 初始化安全服务
    private func initializeSecurityServices() async {
        // loadAuthSession uses non-interactive Keychain access; identity material is
        // still provisioned later from authenticated flows that actually need it.
        AuthenticationService.shared.reloadPersistedSessionIfNeeded()

        logger.debug("🔒 安全服务初始化完成（登录态非交互恢复，Keychain 身份材料延迟加载）")
    }
    
 /// 初始化性能监控基础
    private func initializePerformanceFoundation() async {
 // 预热性能模式与硬件监控基础设施
        _ = PerformanceModeManager.shared
        _ = HardwareMonitorService.shared
        logger.debug("📈 性能监控基础初始化完成")
    }
    
 // MARK: - 第二阶段：基础服务
    
 /// 加载基础服务
 /// 包括网络管理、文件系统、设备发现等核心功能
    private func loadBasicServices() async throws {
        logger.info("🌐 开始加载基础服务")
        
 // 1. 网络管理服务
        try await executeStep(.networkServices) {
            await initializeNetworkServices()
        }
        
 // 2. 文件系统服务
        try await executeStep(.fileSystemServices) {
            await initializeFileSystemServices()
        }
        
 // 3. 设备发现服务
        try await executeStep(.deviceDiscovery) {
            await initializeDeviceDiscovery()
        }
        
        logger.info("✅ 基础服务加载完成")
    }
    
 /// 初始化网络管理服务
    private func initializeNetworkServices() async {
 // 预热网络偏好与 QoS 基础服务
        _ = NetworkPreferenceService.shared
        _ = QoSManager.shared
        logger.debug("🌐 网络管理服务初始化完成")
    }
    
 /// 初始化文件系统服务
    private func initializeFileSystemServices() async {
 // 预热文件传输相关的桥接和任务管理器
        _ = FileTransferSettingsBridge.shared
        _ = FileTransferManager.shared
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
        
        logger.debug("🔍 设备发现服务初始化完成")
    }
    
 // MARK: - 第三阶段：用户界面组件
    
 /// 加载用户界面组件
 /// 包括主界面、系统监控界面、设置界面等
    private func loadUserInterfaceComponents() async throws {
        logger.info("🎨 开始加载用户界面组件")
        
 // 1. 主题配置
        try await executeStep(.themeConfiguration) {
            await initializeThemeConfiguration()
        }
        
 // 2. 主界面组件
        try await executeStep(.mainInterface) {
            await initializeMainInterface()
        }
        
 // 3. 系统监控界面
        try await executeStep(.systemMonitorInterface) {
            await initializeSystemMonitorInterface()
        }
        
        logger.info("✅ 用户界面组件加载完成")
    }
    
 /// 初始化主题配置
    private func initializeThemeConfiguration() async {
 // 预热主题配置单例
        _ = ThemeConfiguration.shared
        logger.debug("🎨 主题配置初始化完成")
    }
    
 /// 初始化主界面组件
    private func initializeMainInterface() async {
 // 主界面主体由 SwiftUI 在进入 RootContainerView 时创建，这里仅保留显式步骤
        await Task.yield()
        logger.debug("🏠 主界面组件初始化完成")
    }
    
 /// 初始化系统监控界面
    private func initializeSystemMonitorInterface() async {
 // 预热系统监控协调器，避免首次打开时冷启动
        _ = ConcurrentSystemMonitor.shared
        logger.debug("📊 系统监控界面初始化完成")
    }
    
 // MARK: - 第四阶段：高级功能
    
 /// 加载高级功能
 /// 包括天气服务、Apple Silicon优化、远程桌面等非关键功能
    private func loadAdvancedFeatures() async throws {
        logger.info("🚀 开始加载高级功能")
        
 // 1. 天气服务
        try await executeStep(.weatherServices) {
            await initializeWeatherServices()
        }
        
 // 2. Apple Silicon优化
        try await executeStep(.appleSiliconOptimization) {
            if #available(macOS 14.0, *) {
                await initializeAppleSiliconOptimization()
            } else {
                logger.info("⚠️ Apple Silicon优化需要macOS 14.0或更高版本")
            }
        }
        
 // 3. 远程桌面服务
        try await executeStep(.remoteDesktopServices) {
            await initializeRemoteDesktopServices()
        }
        
        logger.info("✅ 高级功能加载完成")
    }
    
 /// 初始化天气服务
    private func initializeWeatherServices() async {
 // 预热天气集成单例，避免首次进入相关界面时冷启动
        _ = WeatherIntegrationManager.shared
        _ = WeatherEffectsSettings.shared
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
 // 预热远程桌面相关单例，但不主动启动会话
        _ = RemoteDesktopManager.shared
        _ = CrossNetworkConnectionManager.shared
        logger.debug("🖥️ 远程桌面服务初始化完成")
    }
    
 // MARK: - 启动完成处理
    
 /// 完成启动流程
    private func completeStartup() async {
        currentStage = .completed
        currentStep = nil
        completedStepCount = totalStepCount
        progress = 1.0
        isStartupComplete = true
        
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
    
    var localizationKey: String {
        switch self {
        case .initializing:
            return "startup.stage.initializing"
        case .coreSystem:
            return "startup.stage.coreSystem"
        case .basicServices:
            return "startup.stage.basicServices"
        case .userInterface:
            return "startup.stage.userInterface"
        case .advancedFeatures:
            return "startup.stage.advancedFeatures"
        case .completed:
            return "startup.stage.completed"
        }
    }

    var logLabel: String {
        switch self {
        case .initializing:
            return "initializing"
        case .coreSystem:
            return "coreSystem"
        case .basicServices:
            return "basicServices"
        case .userInterface:
            return "userInterface"
        case .advancedFeatures:
            return "advancedFeatures"
        case .completed:
            return "completed"
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

public enum StartupStep: CaseIterable {
    case loggingSystem
    case configurationManager
    case securityServices
    case performanceFoundation
    case networkServices
    case fileSystemServices
    case deviceDiscovery
    case themeConfiguration
    case mainInterface
    case systemMonitorInterface
    case weatherServices
    case appleSiliconOptimization
    case remoteDesktopServices

    var stage: StartupStage {
        switch self {
        case .loggingSystem, .configurationManager, .securityServices, .performanceFoundation:
            return .coreSystem
        case .networkServices, .fileSystemServices, .deviceDiscovery:
            return .basicServices
        case .themeConfiguration, .mainInterface, .systemMonitorInterface:
            return .userInterface
        case .weatherServices, .appleSiliconOptimization, .remoteDesktopServices:
            return .advancedFeatures
        }
    }

    var localizationKey: String {
        switch self {
        case .loggingSystem:
            return "startup.step.loggingSystem"
        case .configurationManager:
            return "startup.step.configurationManager"
        case .securityServices:
            return "startup.step.securityServices"
        case .performanceFoundation:
            return "startup.step.performanceFoundation"
        case .networkServices:
            return "startup.step.networkServices"
        case .fileSystemServices:
            return "startup.step.fileSystemServices"
        case .deviceDiscovery:
            return "startup.step.deviceDiscovery"
        case .themeConfiguration:
            return "startup.step.themeConfiguration"
        case .mainInterface:
            return "startup.step.mainInterface"
        case .systemMonitorInterface:
            return "startup.step.systemMonitorInterface"
        case .weatherServices:
            return "startup.step.weatherServices"
        case .appleSiliconOptimization:
            return "startup.step.appleSiliconOptimization"
        case .remoteDesktopServices:
            return "startup.step.remoteDesktopServices"
        }
    }

    var logLabel: String {
        switch self {
        case .loggingSystem:
            return "loggingSystem"
        case .configurationManager:
            return "configurationManager"
        case .securityServices:
            return "securityServices"
        case .performanceFoundation:
            return "performanceFoundation"
        case .networkServices:
            return "networkServices"
        case .fileSystemServices:
            return "fileSystemServices"
        case .deviceDiscovery:
            return "deviceDiscovery"
        case .themeConfiguration:
            return "themeConfiguration"
        case .mainInterface:
            return "mainInterface"
        case .systemMonitorInterface:
            return "systemMonitorInterface"
        case .weatherServices:
            return "weatherServices"
        case .appleSiliconOptimization:
            return "appleSiliconOptimization"
        case .remoteDesktopServices:
            return "remoteDesktopServices"
        }
    }
}
