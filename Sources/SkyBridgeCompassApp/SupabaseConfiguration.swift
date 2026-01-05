import Foundation
import SkyBridgeCore

/// Supabase配置管理器 - 负责初始化和管理Supabase连接
/// 遵循Apple 2025最佳实践，支持环境变量和手动配置
@MainActor
public final class SupabaseConfiguration: ObservableObject {
    
 // MARK: - 单例
    
    public static let shared = SupabaseConfiguration()
    
 // MARK: - 配置状态
    
    @Published public var isConfigured = false
    @Published public var configurationError: String?
    
 // MARK: - 私有属性
    
    private var currentConfiguration: SupabaseService.Configuration?
    
 // MARK: - 初始化
    
    private init() {
 // 尝试从环境变量自动配置
        attemptAutoConfiguration()
    }
    
 // MARK: - 公共方法
    
 /// 尝试从环境变量自动配置Supabase
    public func attemptAutoConfiguration() {
 // 首先尝试从 Keychain 加载
        SkyBridgeLogger.ui.debugOnly("🔍 [SupabaseConfiguration] 尝试从 Keychain 加载...")
        if let config = loadFromKeychain() {
            SkyBridgeLogger.ui.debugOnly("✅ [SupabaseConfiguration] 从 Keychain 加载配置成功")
            configureSupabase(with: config)
            return
        }
        
 // 其次检查环境变量
        let urlEnv = ProcessInfo.processInfo.environment["SUPABASE_URL"]
        let keyEnv = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        
        SkyBridgeLogger.ui.debugOnly("🔍 [SupabaseConfiguration] 检查环境变量:")
        SkyBridgeLogger.ui.debugOnly("   SUPABASE_URL: \(urlEnv ?? "未设置")")
        SkyBridgeLogger.ui.debugOnly("   SUPABASE_ANON_KEY: \(keyEnv != nil ? "已设置" : "未设置")")
        
 // 使用 if-let 绑定，config 在闭包中使用
        if let config = SupabaseService.Configuration.fromEnvironment() {
            SkyBridgeLogger.ui.debugOnly("✅ [SupabaseConfiguration] 从环境变量加载配置成功")
            configureSupabase(with: config)  // config 被使用
        } else {
            SkyBridgeLogger.ui.debugOnly("⚠️ [SupabaseConfiguration] Keychain 和环境变量都未配置")
            SkyBridgeLogger.ui.debugOnly("   请在应用中配置 Supabase 或设置环境变量")
 // 不再自动使用演示模式，让用户手动配置
            configurationError = "未找到 Supabase 配置，请在设置中配置"
            isConfigured = false
        }
    }
    
 /// 从 Keychain 加载 Supabase 配置
    private func loadFromKeychain() -> SupabaseService.Configuration? {
        do {
            let keychain = KeychainManager.shared
            let config = try keychain.retrieveSupabaseConfig()
            
 // 验证配置不为空
            guard !config.url.isEmpty, !config.anonKey.isEmpty else {
                SkyBridgeLogger.ui.debugOnly("⚠️ Keychain 中的配置不完整")
                return nil
            }
            
 // 创建 URL
            guard let url = URL(string: config.url) else {
                SkyBridgeLogger.ui.debugOnly("⚠️ 无效的 Supabase URL: \(config.url)")
                return nil
            }
            
            return SupabaseService.Configuration(
                url: url,
                anonKey: config.anonKey,
                serviceRoleKey: config.serviceRoleKey
            )
        } catch {
            SkyBridgeLogger.ui.debugOnly("⚠️ 从 Keychain 加载失败: \(error.localizedDescription)")
            return nil
        }
    }
    
 /// 手动配置Supabase
    public func configureSupabase(with configuration: SupabaseService.Configuration) {
        currentConfiguration = configuration
        
 // 启用AuthenticationService的Supabase模式
        AuthenticationService.shared.enableSupabaseMode(supabaseConfig: configuration)
        
        isConfigured = true
        configurationError = nil
        
        SkyBridgeLogger.ui.debugOnly("✅ Supabase已配置成功")
        SkyBridgeLogger.ui.debugOnly("   URL: \(configuration.url)")
        SkyBridgeLogger.ui.debugOnly("   匿名密钥: \(String(configuration.anonKey.prefix(10)))...")
    }
    
 /// 配置演示模式（用于开发和测试）
 ///
 /// ⚠️ 警告：演示模式不会连接到真实的 Supabase 后端。
 /// 生产环境请使用以下方式配置：
 /// 1. 设置环境变量 SUPABASE_URL 和 SUPABASE_ANON_KEY
 /// 2. 在应用设置中手动配置
 /// 3. 将配置保存到 Keychain
    public func configureDemoMode() {
 // ⚠️ 演示模式：使用本地模拟配置，不连接真实后端
 // 演示模式仅用于 UI 预览和开发测试，不提供任何后端功能
        
        SkyBridgeLogger.ui.warning("⚠️ 演示模式已启用 - 不连接真实 Supabase 后端")
        SkyBridgeLogger.ui.warning("   在线功能（如账号同步、云备份）将不可用")
        SkyBridgeLogger.ui.warning("   请配置真实的 Supabase 项目以启用完整功能")
        
 // 设置为离线/演示状态，而不是使用无效的占位符密钥
        isConfigured = false
        configurationError = "演示模式：在线功能已禁用。请在设置中配置 Supabase 以启用云功能。"
        currentConfiguration = nil
        
 // 打印配置指南
        Self.printSetupInstructions()
    }
    
 /// 检查是否处于演示/离线模式
    public var isDemoMode: Bool {
        return !isConfigured || currentConfiguration == nil
    }
    
 /// 获取配置指南文本（用于 UI 显示）
    public static var configurationGuide: String {
        """
        配置 Supabase 的方法：
        
        方法一：环境变量（推荐用于开发）
        1. 打开终端
        2. 设置环境变量：
           export SUPABASE_URL="https://your-project.supabase.co"
           export SUPABASE_ANON_KEY="your-anon-key"
        3. 重启 SkyBridge Compass Pro
        
        方法二：应用内配置
        1. 打开 设置 > 账号与云服务
        2. 输入 Supabase 项目 URL 和匿名密钥
        3. 点击保存
        
        获取 Supabase 配置：
        1. 访问 https://supabase.com 创建项目
        2. 在项目设置 > API 中获取 URL 和密钥
        """
    }
    
 /// 验证当前配置是否有效
    public func validateConfiguration() async -> Bool {
        guard let config = currentConfiguration else {
            configurationError = "未找到Supabase配置"
            return false
        }
 // 使用统一 SupabaseClient 进行健康检查（auth/v1/settings）
        let client = SupabaseClient(baseURL: config.url, anonKey: config.anonKey)
        do {
            let (_, http) = try await client.get(path: "auth/v1/settings")
            let ok = (200...399).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 404
            configurationError = ok ? nil : "Supabase健康检查失败: HTTP \(http.statusCode)"
            return ok
        } catch let err as SupabaseClient.SupabaseError {
            configurationError = err.localizedDescription
            return false
        } catch {
            configurationError = "网络请求失败：\(error.localizedDescription)"
            return false
        }
    }
    
 /// 获取配置状态描述
    public var configurationStatus: String {
        if isConfigured {
            if let config = currentConfiguration {
                return "已连接到: \(config.url.host ?? "未知主机")"
            } else {
                return "配置状态异常"
            }
        } else {
            return configurationError ?? "未配置"
        }
    }
    
 // MARK: - 环境变量检查
    
 /// 检查必需的环境变量是否已设置
    public static func checkEnvironmentVariables() -> (isComplete: Bool, missing: [String]) {
        let requiredVars = ["SUPABASE_URL", "SUPABASE_ANON_KEY"]
        let missing = requiredVars.filter { ProcessInfo.processInfo.environment[$0] == nil }
        
        return (isComplete: missing.isEmpty, missing: missing)
    }
    
 /// 打印环境变量设置指南
    public static func printSetupInstructions() {
        let envCheck = checkEnvironmentVariables()
        
        if !envCheck.isComplete {
            SkyBridgeLogger.ui.debugOnly("🔧 Supabase环境变量设置指南:")
            SkyBridgeLogger.ui.debugOnly("   请在终端中设置以下环境变量:")
            SkyBridgeLogger.ui.debugOnly("")
            
            for variable in envCheck.missing {
                switch variable {
                case "SUPABASE_URL":
                    SkyBridgeLogger.ui.debugOnly("   export SUPABASE_URL=\"https://your-project.supabase.co\"")
                case "SUPABASE_ANON_KEY":
                    SkyBridgeLogger.ui.debugOnly("   export SUPABASE_ANON_KEY=\"your-anon-key\"")
                default:
                    SkyBridgeLogger.ui.debugOnly("   export \(variable)=\"your-value\"")
                }
            }
            
            SkyBridgeLogger.ui.debugOnly("")
            SkyBridgeLogger.ui.debugOnly("   然后重新启动应用程序")
            SkyBridgeLogger.ui.debugOnly("   或者在应用中手动配置Supabase连接")
        } else {
            SkyBridgeLogger.ui.debugOnly("✅ 所有必需的Supabase环境变量已设置")
        }
    }
}
