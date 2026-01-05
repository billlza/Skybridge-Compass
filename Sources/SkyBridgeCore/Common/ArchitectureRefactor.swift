import Foundation
import OSLog

/// 架构重构工具类 - 支持从单例模式迁移到工厂模式
/// 遵循Apple Silicon最佳实践和Swift 6.2特性
@MainActor
public final class ArchitectureRefactor {
    
 // MARK: - 单例
 // Swift 6.2.1：此工具类使用单例模式是合适的，因为它是一个无状态的工厂访问器
 // 后续版本可按需迁移到依赖注入模式
    
    public static let shared = ArchitectureRefactor()
    
 // MARK: - 私有属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "ArchitectureRefactor")
    private let managerFactory = ManagerFactory.shared
    
 // MARK: - 初始化
    
    private init() {
        logger.info("🔧 架构重构工具初始化")
    }
    
 // MARK: - 管理器迁移方法
    
 /// 获取RemoteDesktopManager实例（从单例迁移到工厂模式）
 /// - Returns: RemoteDesktopManager实例
 /// - Note: 当前返回单例，后续可通过 ManagerFactory 提供依赖注入版本
    public func getRemoteDesktopManager() -> RemoteDesktopManager {
        return RemoteDesktopManager.shared
    }
    
 /// 获取P2PNetworkManager实例（从单例迁移到工厂模式）
 /// - Returns: P2PNetworkManager实例
    public func getP2PNetworkManager() -> P2PNetworkManager {
        return P2PNetworkManager.shared
    }
    
 /// 获取AuthenticationService实例（从单例迁移到工厂模式）
 /// - Returns: AuthenticationService实例
    public func getAuthenticationService() -> AuthenticationService {
        return AuthenticationService.shared
    }
    
 /// 获取PerformanceModeManager实例（从单例迁移到工厂模式）
 /// - Returns: PerformanceModeManager实例
    public func getPerformanceModeManager() -> PerformanceModeManager {
        return PerformanceModeManager.shared
    }
    
 /// 获取SettingsManager实例（从单例迁移到工厂模式）
 /// - Returns: SettingsManager实例
    public func getSettingsManager() -> SettingsManager {
        return SettingsManager.shared
    }
    
 /// 获取AppleSiliconOptimizer实例（从单例迁移到工厂模式）
 /// - Returns: AppleSiliconOptimizer实例
    public func getAppleSiliconOptimizer() -> AppleSiliconOptimizer {
        return AppleSiliconOptimizer.shared
    }
    
 /// 获取KeychainManager实例（从单例迁移到工厂模式）
 /// - Returns: KeychainManager实例
    public func getKeychainManager() -> KeychainManager {
        return KeychainManager.shared
    }
    
 /// 获取NebulaService实例（从单例迁移到工厂模式）
 /// - Returns: NebulaService实例
    public func getNebulaService() -> NebulaService {
        return NebulaService.shared
    }
    
 // MARK: - 架构分析方法
    
 /// 分析当前架构中的单例使用情况
 /// - Returns: 单例使用报告
    public func analyzeSingletonUsage() -> SingletonAnalysisReport {
        logger.info("📊 开始分析单例使用情况")
        
        let singletonManagers = [
            "RemoteDesktopManager",
            "P2PNetworkManager", 
            "AuthenticationService",
            "PerformanceModeManager",
            "SettingsManager",
            "AppleSiliconOptimizer",
            "KeychainManager",
            "NebulaService",
            "ManagerFactory",
            "ServiceFactory"
        ]
        
        let report = SingletonAnalysisReport(
            totalSingletons: singletonManagers.count,
            criticalSingletons: singletonManagers.filter { isCriticalSingleton($0) },
            migratableSingletons: singletonManagers.filter { isMigratable($0) },
            recommendations: generateMigrationRecommendations(for: singletonManagers)
        )
        
        logger.info("✅ 单例分析完成: \(report.totalSingletons)个单例，\(report.migratableSingletons.count)个可迁移")
        return report
    }
    
 /// 生成架构重构计划
 /// - Returns: 重构计划
    public func generateRefactoringPlan() -> ArchitectureRefactoringPlan {
        logger.info("📋 生成架构重构计划")
        
        let phases = [
            RefactoringPhase(
                name: "第一阶段：核心管理器重构",
                description: "重构核心业务管理器，减少单例依赖",
                tasks: [
                    "将RemoteDesktopManager迁移到工厂模式",
                    "优化ManagerFactory的依赖注入机制",
                    "重构P2PNetworkManager的生命周期管理"
                ],
                estimatedDuration: "2-3天",
                priority: .high
            ),
            RefactoringPhase(
                name: "第二阶段：服务层重构",
                description: "重构服务层架构，提升模块化程度",
                tasks: [
                    "重构AuthenticationService为可注入服务",
                    "优化SettingsManager的配置管理",
                    "改进KeychainManager的安全性"
                ],
                estimatedDuration: "1-2天",
                priority: .medium
            ),
            RefactoringPhase(
                name: "第三阶段：性能优化重构",
                description: "优化性能相关组件的架构设计",
                tasks: [
                    "重构AppleSiliconOptimizer为模块化组件",
                    "优化PerformanceModeManager的资源管理",
                    "改进NebulaService的并发处理"
                ],
                estimatedDuration: "1-2天",
                priority: .medium
            )
        ]
        
        let plan = ArchitectureRefactoringPlan(
            phases: phases,
            totalEstimatedDuration: "4-7天",
            expectedBenefits: [
                "提升代码可测试性",
                "降低组件间耦合度",
                "改善内存管理效率",
                "增强架构可扩展性"
            ]
        )
        
        logger.info("✅ 重构计划生成完成: \(phases.count)个阶段")
        return plan
    }
    
 // MARK: - 私有方法
    
 /// 判断是否为关键单例
 /// - Parameter singletonName: 单例名称
 /// - Returns: 是否为关键单例
    private func isCriticalSingleton(_ singletonName: String) -> Bool {
        let criticalSingletons = ["ManagerFactory", "ServiceFactory", "KeychainManager"]
        return criticalSingletons.contains(singletonName)
    }
    
 /// 判断是否可迁移
 /// - Parameter singletonName: 单例名称
 /// - Returns: 是否可迁移
    private func isMigratable(_ singletonName: String) -> Bool {
        let migratableSingletons = [
            "RemoteDesktopManager",
            "P2PNetworkManager",
            "AuthenticationService",
            "PerformanceModeManager",
            "SettingsManager",
            "AppleSiliconOptimizer",
            "NebulaService"
        ]
        return migratableSingletons.contains(singletonName)
    }
    
 /// 生成迁移建议
 /// - Parameter singletons: 单例列表
 /// - Returns: 迁移建议列表
    private func generateMigrationRecommendations(for singletons: [String]) -> [String] {
        return [
            "优先迁移业务逻辑管理器（如RemoteDesktopManager）",
            "保留系统级单例（如KeychainManager）",
            "使用工厂模式管理对象生命周期",
            "引入依赖注入减少硬编码依赖",
            "分阶段进行迁移，确保系统稳定性"
        ]
    }
}

// MARK: - 数据结构

/// 单例分析报告
public struct SingletonAnalysisReport {
 /// 单例总数
    public let totalSingletons: Int
    
 /// 关键单例列表
    public let criticalSingletons: [String]
    
 /// 可迁移单例列表
    public let migratableSingletons: [String]
    
 /// 迁移建议
    public let recommendations: [String]
    
 /// 健康评分（0-100）
    public var healthScore: Int {
        let migratableRatio = Double(migratableSingletons.count) / Double(totalSingletons)
        return Int((1.0 - migratableRatio) * 100)
    }
}

/// 架构重构计划
public struct ArchitectureRefactoringPlan {
 /// 重构阶段
    public let phases: [RefactoringPhase]
    
 /// 总预估时间
    public let totalEstimatedDuration: String
    
 /// 预期收益
    public let expectedBenefits: [String]
}

/// 重构阶段
public struct RefactoringPhase {
 /// 阶段名称
    public let name: String
    
 /// 阶段描述
    public let description: String
    
 /// 任务列表
    public let tasks: [String]
    
 /// 预估时间
    public let estimatedDuration: String
    
 /// 优先级
    public let priority: RefactoringPriority
}

/// 重构优先级
public enum RefactoringPriority {
    case high    // 高优先级
    case medium  // 中优先级
    case low     // 低优先级
    
    public var description: String {
        switch self {
        case .high: return "高优先级"
        case .medium: return "中优先级"
        case .low: return "低优先级"
        }
    }
}