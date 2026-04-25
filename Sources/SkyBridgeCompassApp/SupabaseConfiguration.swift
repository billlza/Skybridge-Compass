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
    private var keychainAutoConfigurationTask: Task<Void, Never>?

    public var resolvedConfiguration: SupabaseService.Configuration? {
        currentConfiguration
    }
    
 // MARK: - 初始化
    
    private init() {
 // 尝试从非阻塞配置源自动配置；启动阶段不能触碰 Keychain，避免系统授权弹窗拖死 App。
        attemptAutoConfiguration()
    }
    
 // MARK: - 公共方法
    
    /// 尝试从可用配置源自动配置 Supabase（Keychain / 环境变量 / Info.plist / 资源文件）
    public func attemptAutoConfiguration() {
        let urlEnv = ProcessInfo.processInfo.environment["SUPABASE_URL"]
        let keyEnv = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        
        SkyBridgeLogger.ui.debugOnly("🔍 [SupabaseConfiguration] 检查环境变量:")
        SkyBridgeLogger.ui.debugOnly("   SUPABASE_URL: \(urlEnv ?? "未设置")")
        SkyBridgeLogger.ui.debugOnly("   SUPABASE_ANON_KEY: \(keyEnv != nil ? "已设置" : "未设置")")
        
 // 先检查环境变量 / 包内配置，这些来源不会阻塞主线程。
        if let config = SupabaseService.Configuration.fromEnvironment() {
            SkyBridgeLogger.ui.debugOnly("✅ [SupabaseConfiguration] 从可用配置源加载配置成功")
            configureSupabase(with: config)
        } else {
            SkyBridgeLogger.ui.debugOnly("⚠️ [SupabaseConfiguration] 环境变量与包内配置未命中，后台尝试 Keychain 配置")
            configurationError = "未找到 Supabase 配置，请在设置中配置"
            isConfigured = false
            scheduleKeychainAutoConfiguration()
        }
    }

    private func scheduleKeychainAutoConfiguration() {
        guard keychainAutoConfigurationTask == nil else { return }

        keychainAutoConfigurationTask = Task { [weak self] in
            let keychainConfiguration = await Task.detached(priority: .utility) {
                SupabaseService.Configuration.fromKeychain()
            }.value

            await MainActor.run {
                guard let self else { return }
                self.keychainAutoConfigurationTask = nil
                guard !self.isConfigured,
                      let keychainConfiguration else {
                    return
                }
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseConfiguration] 从 Keychain 后台加载配置成功")
                self.configureSupabase(with: keychainConfiguration)
            }
        }
    }
    
 /// 手动配置Supabase
    public func configureSupabase(with configuration: SupabaseService.Configuration) {
        guard validatedConfiguration(
            urlString: configuration.url.absoluteString,
            anonKey: configuration.anonKey
        ) != nil else {
            currentConfiguration = nil
            isConfigured = false
            configurationError = "Supabase 配置无效（需 https 且不能为占位值）"
            SkyBridgeLogger.ui.error("❌ Supabase 配置被拒绝：无效或占位配置")
            return
        }

        currentConfiguration = configuration
        
 // 启用AuthenticationService的Supabase模式
        AuthenticationService.shared.enableSupabaseMode(supabaseConfig: configuration)
        
        isConfigured = true
        configurationError = nil
        
        SkyBridgeLogger.ui.debugOnly("✅ Supabase已配置成功")
        SkyBridgeLogger.ui.debugOnly("   URL: \(configuration.url)")
        SkyBridgeLogger.ui.debugOnly("   匿名密钥: 已配置")

        Task { @MainActor [weak self] in
            guard let self else { return }
            let isHealthy = await self.validateConfiguration()
            if isHealthy {
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseConfiguration] Auth 健康检查通过")
            } else {
                SkyBridgeLogger.ui.error("⚠️ [SupabaseConfiguration] Auth 健康检查失败: \(self.configurationError ?? "未知错误", privacy: .private)")
            }
        }
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

    private func validatedConfiguration(
        urlString: String,
        anonKey: String
    ) -> SupabaseService.Configuration? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty, !trimmedAnonKey.isEmpty else {
            return nil
        }

        let normalizedURL = trimmedURL.lowercased()
        let normalizedAnonKey = trimmedAnonKey.lowercased()
        if normalizedURL.contains("your-project.supabase.co") || normalizedAnonKey == "your-anon-key" {
            return nil
        }

        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        if scheme != "https" {
#if DEBUG
            let isLocalHost = host == "localhost" || host == "127.0.0.1"
            guard scheme == "http", isLocalHost else {
                return nil
            }
#else
            return nil
#endif
        }

        return SupabaseService.Configuration(url: url, anonKey: trimmedAnonKey)
    }
}
