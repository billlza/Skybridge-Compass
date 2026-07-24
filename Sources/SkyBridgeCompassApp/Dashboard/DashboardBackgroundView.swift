import SwiftUI
import SkyBridgeCore

/// Lightweight first-frame background shared by the launch screen and Dashboard shell.
struct LaunchTransitionBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.01, green: 0.01, blue: 0.08),
                Color(red: 0.03, green: 0.04, blue: 0.15),
                Color(red: 0.07, green: 0.08, blue: 0.22)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// 仪表盘背景视图 - 包含主题壁纸和天气效果
@available(macOS 14.0, *)
public struct DashboardBackgroundView: View {
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @EnvironmentObject var weatherManager: WeatherIntegrationManager
    @EnvironmentObject var weatherSettings: WeatherEffectsSettings

    @ObservedObject var hazeClearManager: InteractiveClearManager
    private let enableWeatherEffects: Bool

    public init(
        hazeClearManager: InteractiveClearManager,
        enableWeatherEffects: Bool = true
    ) {
        self._hazeClearManager = ObservedObject(wrappedValue: hazeClearManager)
        self.enableWeatherEffects = enableWeatherEffects
    }

    public var body: some View {
        ZStack {
 // 主题壁纸背景 - 按当前主题切换，并联动实时天气参数
            themeBackgroundView()
                .opacity(themeConfiguration.backgroundIntensity)
                .ignoresSafeArea(.all)

            // 全页面雾霾背景（仅在雾/霾天气启用）
            // 说明：该层是 Metal 全屏雾霾，会整体“染灰”UI；对多云/晴天等不应常驻叠加，
            // 否则会把主题底色与云层效果一起压暗成“灰败”。
            if weatherManager.currentTheme.condition.needsFogEffect {
                GlobalHazeBackground(clearManager: hazeClearManager)
                    .ignoresSafeArea(.all)
            }

 // 🌦️ 天气效果覆盖层（根据实时天气动态切换）
            ZStack {
                if enableWeatherEffects,
                   weatherSettings.isEnabled,
                   weatherManager.currentWeather != nil {
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
        // ✅ 统一入口：所有天气覆盖层都通过 SkyBridgeCore.WeatherEffectView 渲染
        WeatherEffectView(theme: weatherManager.currentTheme)
    }
}
