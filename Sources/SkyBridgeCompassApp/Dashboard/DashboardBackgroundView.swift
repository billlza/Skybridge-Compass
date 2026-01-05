import SwiftUI
import SkyBridgeCore

/// 仪表盘背景视图 - 包含主题壁纸和天气效果
@available(macOS 14.0, *)
public struct DashboardBackgroundView: View {
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @EnvironmentObject var weatherManager: WeatherIntegrationManager
    @EnvironmentObject var weatherSettings: WeatherEffectsSettings
    
    @ObservedObject var hazeClearManager: InteractiveClearManager
    
    public init(hazeClearManager: InteractiveClearManager) {
        self._hazeClearManager = ObservedObject(wrappedValue: hazeClearManager)
    }
    
    public var body: some View {
        ZStack {
 // 主题壁纸背景 - 按当前主题切换，并联动实时天气参数
            themeBackgroundView()
                .opacity(themeConfiguration.backgroundIntensity)
                .ignoresSafeArea(.all)
            
 // 全页面雾霾背景 - 鼠标悬停驱散效果（联动交互式驱散全局透明度）
            GlobalHazeBackground(clearManager: hazeClearManager)
                .ignoresSafeArea(.all)
            
 // 🌦️ 天气效果覆盖层（根据实时天气动态切换）
            ZStack {
                if weatherSettings.isEnabled {
                    dynamicWeatherEffectView(for: weatherManager.currentTheme.condition)
                        .ignoresSafeArea(.all)
                        .id(weatherManager.currentTheme.condition) // 🔥 强制视图重建以切换效果
                }
            }
        }
    }
    
 /// 根据当前主题选择壁纸背景视图，并向壁纸注入实时天气数据（如风速、湿度、AQI）。
    @ViewBuilder
    private func themeBackgroundView() -> some View {
        switch themeConfiguration.currentTheme {
        case .starryNight:
            StarryBackground()
        case .deepSpace:
            DeepSpaceBackground(weather: weatherManager.currentWeather)
                .environmentObject(themeConfiguration)
        case .aurora:
            AuroraBackgroundV2(weather: weatherManager.currentWeather)
                .environmentObject(themeConfiguration)
        case .classic:
            ClassicBackgroundV2(weather: weatherManager.currentWeather)
                .environmentObject(themeConfiguration)
        case .custom:
            CustomBackgroundView()
                .environmentObject(themeConfiguration)
        }
    }
    
 /// 根据天气条件返回对应的动态天气效果视图
    @ViewBuilder
    private func dynamicWeatherEffectView(for condition: WeatherCondition) -> some View {
        switch condition {
        case .clear:
 // ☀️ 晴天 - 太阳系统 + God Rays + 白云 + 浮尘
            CinematicClearSkyEffectView()
            
        case .cloudy:
 // ☁️ 多云 - 体积云 + 光线漫射
            CinematicCloudySkyView()
            
        case .rainy, .stormy:
 // 🌧️ 雨天/暴风雨 - 物理雨滴 + 闪电 + 玻璃水珠
            CinematicRainEffectView()
            
        case .snowy:
 // ❄️ 雪天 - 物理雪花 + 360°旋转 + 积雪
            CinematicSnowEffectView()
            
        case .foggy:
 // 🌫️ 雾天 - 体积雾 + 光线步进
            CinematicFogView()
            
        case .haze:
 // 😶‍🌫️ 霾天 - 轻度体积雾 + 沙尘
            SkyBridgeCore.CinematicHazeView(
                weatherManager: WeatherIntegrationManager.shared,
                clearManager: hazeClearManager
            )
            
        default:
 // 未知天气 - 默认晴天
            CinematicClearSkyEffectView()
        }
    }
}

