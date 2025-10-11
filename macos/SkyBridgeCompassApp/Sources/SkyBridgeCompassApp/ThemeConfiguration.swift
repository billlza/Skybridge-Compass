import SwiftUI
import Foundation

// MARK: - 主题配置类
// 遵循macOS最佳实践，使用@MainActor确保线程安全
@MainActor
class ThemeConfiguration: ObservableObject {
    // MARK: - 单例实例
    static let shared = ThemeConfiguration()
    
    // MARK: - 发布属性
    @Published var currentTheme: AppTheme = .starryNight
    @Published var enableAnimations: Bool = true
    @Published var enableGlassEffect: Bool = true
    @Published var backgroundIntensity: Double = 0.6
    @Published var glassOpacity: Double = 0.8
    
    private init() {
        loadThemeSettings()
    }
    
    // MARK: - 主题枚举
    enum AppTheme: String, CaseIterable, Identifiable {
        case starryNight = "星空夜晚"
        case deepSpace = "深空探索"
        case aurora = "极光幻境"
        case classic = "经典模式"
        
        var id: String { rawValue }
        
        // 主要颜色
        var primaryColor: Color {
            switch self {
            case .starryNight:
                return .blue
            case .deepSpace:
                return .purple
            case .aurora:
                return .green
            case .classic:
                return .accentColor
            }
        }
        
        // 次要颜色
        var secondaryColor: Color {
            switch self {
            case .starryNight:
                return .cyan
            case .deepSpace:
                return .indigo
            case .aurora:
                return .mint
            case .classic:
                return .secondary
            }
        }
        
        // 背景渐变色
        var backgroundGradient: [Color] {
            switch self {
            case .starryNight:
                return [
                    Color(red: 0.05, green: 0.05, blue: 0.15),
                    Color(red: 0.1, green: 0.05, blue: 0.2),
                    Color(red: 0.15, green: 0.1, blue: 0.25),
                    Color(red: 0.08, green: 0.08, blue: 0.18)
                ]
            case .deepSpace:
                return [
                    Color(red: 0.02, green: 0.02, blue: 0.1),
                    Color(red: 0.05, green: 0.02, blue: 0.15),
                    Color(red: 0.08, green: 0.05, blue: 0.2),
                    Color(red: 0.03, green: 0.03, blue: 0.12)
                ]
            case .aurora:
                return [
                    Color(red: 0.02, green: 0.1, blue: 0.08),
                    Color(red: 0.05, green: 0.15, blue: 0.12),
                    Color(red: 0.08, green: 0.2, blue: 0.15),
                    Color(red: 0.03, green: 0.12, blue: 0.1)
                ]
            case .classic:
                return [
                    Color(red: 0.11, green: 0.15, blue: 0.32),
                    Color(red: 0.15, green: 0.2, blue: 0.4),
                    Color(red: 0.2, green: 0.25, blue: 0.45),
                    Color(red: 0.12, green: 0.18, blue: 0.35)
                ]
            }
        }
    }
    
    // MARK: - 计算属性
    /// 获取当前主题的卡片背景材质
    var cardBackgroundMaterial: Material {
        if enableGlassEffect {
            return .ultraThinMaterial
        } else {
            return .regularMaterial
        }
    }
    
    /// 获取当前主题的侧边栏背景材质
    var sidebarBackgroundMaterial: Material {
        if enableGlassEffect {
            return .thinMaterial
        } else {
            return .regularMaterial
        }
    }
    
    /// 获取当前主题的卡片背景色
    var cardBackgroundColor: Color {
        return Color.white.opacity(enableGlassEffect ? 0.04 : 0.08)
    }
    
    /// 获取当前主题的边框颜色
    var borderColor: Color {
        return Color.white.opacity(enableGlassEffect ? 0.08 : 0.15)
    }
    
    /// 主文本颜色
    var primaryTextColor: Color {
        return .white
    }
    
    /// 次要文本颜色
    var secondaryTextColor: Color {
        return .secondary
    }
    
    // MARK: - 动画配置
    /// 标准动画持续时间
    var standardAnimationDuration: Double {
        return enableAnimations ? 0.3 : 0.0
    }
    
    /// 弹簧动画
    var springAnimation: Animation {
        if enableAnimations {
            return .spring(response: 0.6, dampingFraction: 0.8)
        } else {
            return .linear(duration: 0)
        }
    }
    
    /// 缓动动画
    var easeAnimation: Animation {
        if enableAnimations {
            return .easeInOut(duration: standardAnimationDuration)
        } else {
            return .linear(duration: 0)
        }
    }
    
    // MARK: - 主题操作方法
    /// 切换到指定主题
    func switchToTheme(_ theme: AppTheme) {
        withAnimation(springAnimation) {
            currentTheme = theme
        }
        saveThemeSettings()
    }
    
    /// 切换动画开关
    func toggleAnimations() {
        enableAnimations.toggle()
        saveThemeSettings()
    }
    
    /// 切换玻璃效果开关
    func toggleGlassEffects() {
        withAnimation(springAnimation) {
            enableGlassEffect.toggle()
        }
        saveThemeSettings()
    }
    
    // MARK: - 设置调整方法
    /// 调整背景强度
    func adjustBackgroundIntensity(_ intensity: Double) {
        backgroundIntensity = intensity
        saveThemeSettings()
    }
    
    /// 调整玻璃透明度
    func adjustGlassOpacity(_ opacity: Double) {
        glassOpacity = opacity
        saveThemeSettings()
    }
    
    // MARK: - 持久化存储
    /// 保存主题设置到UserDefaults
    private func saveThemeSettings() {
        let defaults = UserDefaults.standard
        defaults.set(currentTheme.rawValue, forKey: "AppTheme")
        defaults.set(enableAnimations, forKey: "EnableAnimations")
        defaults.set(enableGlassEffect, forKey: "EnableGlassEffects")
        defaults.set(backgroundIntensity, forKey: "BackgroundIntensity")
        defaults.set(glassOpacity, forKey: "GlassOpacity")
    }
    
    /// 从UserDefaults加载主题设置
    private func loadThemeSettings() {
        let defaults = UserDefaults.standard
        
        if let themeRawValue = defaults.object(forKey: "AppTheme") as? String,
           let theme = AppTheme(rawValue: themeRawValue) {
            currentTheme = theme
        }
        
        enableAnimations = defaults.object(forKey: "EnableAnimations") as? Bool ?? true
        enableGlassEffect = defaults.object(forKey: "EnableGlassEffects") as? Bool ?? true
        backgroundIntensity = defaults.object(forKey: "BackgroundIntensity") as? Double ?? 1.0
        glassOpacity = defaults.object(forKey: "GlassOpacity") as? Double ?? 0.8
    }
}

// MARK: - SwiftUI视图扩展
extension View {
    /// 应用主题样式
    func themed() -> some View {
        self.preferredColorScheme(.dark)
    }
    
    /// 应用主题卡片样式
    func themedCard() -> some View {
        self
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
    
    /// 应用主题按钮样式
    func themedButton(color: Color? = nil) -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color ?? .blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            .shadow(radius: 2)
    }
}

#Preview {
    VStack(spacing: 20) {
        Text("主题预览")
            .font(.title)
            .foregroundColor(ThemeConfiguration.shared.primaryTextColor)
        
        HStack(spacing: 16) {
            ForEach(ThemeConfiguration.AppTheme.allCases) { theme in
                VStack {
                    Rectangle()
                        .fill(LinearGradient(
                            gradient: Gradient(colors: theme.backgroundGradient),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 60, height: 40)
                        .cornerRadius(8)
                    
                    Text(theme.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    .padding()
    .themedCard()
    .themed()
}