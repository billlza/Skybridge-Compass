import SwiftUI
import SkyBridgeCore

/// 经典模式背景组件
/// 采用系统材质与柔性渐变的组合，依据实时天气调整色相与模糊强度，
/// 在保证信息可读性的同时与天气效果层自然融合。
struct ClassicBackground: View {
    let weather: WeatherInfo?
    
    @EnvironmentObject private var themeConfiguration: ThemeConfiguration
    
 /// 根据天气状况选择色相倾向
    private var baseColors: [Color] {
        switch weather?.condition {
        case .clear:
            return [Color.blue.opacity(0.18), Color.cyan.opacity(0.12), Color.clear]
        case .cloudy:
            return [Color.indigo.opacity(0.14), Color.gray.opacity(0.12), Color.clear]
        case .rainy:
            return [Color.blue.opacity(0.12), Color.gray.opacity(0.16), Color.clear]
        case .snowy:
            return [Color.white.opacity(0.14), Color.blue.opacity(0.10), Color.clear]
        case .foggy:
            return [Color.white.opacity(0.18), Color.gray.opacity(0.14), Color.clear]
        case .haze:
            return [Color.orange.opacity(0.12), Color.yellow.opacity(0.08), Color.clear]
        case .stormy:
            return [Color.purple.opacity(0.14), Color.indigo.opacity(0.12), Color.clear]
        default:
            return [Color.blue.opacity(0.12), Color.purple.opacity(0.10), Color.clear]
        }
    }
    
 /// 湿度/雾霾驱动模糊强度（保证阅读性不超过合理范围）
    private var blurRadius: CGFloat {
        let humidity = weather?.humidity ?? 55.0
        let condition = weather?.condition
        let base = (humidity / 100.0) * 16.0
        let condBoost: CGFloat = (condition == .foggy || condition == .haze) ? 8.0 : 2.0
        return min(26.0, CGFloat(base) + condBoost)
    }
    
    var body: some View {
        ZStack {
 // 系统材质层：与macOS视觉一致，确保信息承载能力
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
 // 主题渐变色：轻微色彩氛围
                    LinearGradient(
                        colors: baseColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .blendMode(.overlay)
                }
                .blur(radius: blurRadius)
            
 // 辅助边缘光晕：强化层次但强度可控
            LinearGradient(
                colors: [
                    Color.white.opacity(0.06),
                    Color.clear,
                    Color.white.opacity(0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .blendMode(.softLight)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}