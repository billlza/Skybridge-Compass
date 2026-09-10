import SwiftUI
import SkyBridgeWeatherRendering

/// 主控台全宽卡片的液态玻璃外观（磨砂底层 + 渐变光泽 + 描边 + 动态阴影 + 悬停缩放）。
///
/// 从天气卡片抽出，账号设备面板与天气卡片共用同一套视觉，避免在同一页面出现第二种"玻璃"。
@available(macOS 14.0, *)
struct DashboardLiquidGlassChrome: ViewModifier {
    let accent: Color
    let isHovering: Bool
    let isFlashing: Bool

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Color.white.opacity(0.04)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovering ? 0.08 : 0.03),
                            Color.white.opacity(0.01)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovering ? 0.15 : 0.08),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(
                color: accent.opacity(isFlashing ? 0.3 : 0.1),
                radius: isFlashing ? 20 : 8,
                x: 0,
                y: isFlashing ? 8 : 4
            )
            .weatherGlassSurface(cornerRadius: 20)
            .scaleEffect(isHovering ? 1.005 : 1.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isHovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isFlashing)
    }
}

@available(macOS 14.0, *)
extension View {
    func dashboardLiquidGlassChrome(accent: Color, isHovering: Bool, isFlashing: Bool = false) -> some View {
        modifier(DashboardLiquidGlassChrome(accent: accent, isHovering: isHovering, isFlashing: isFlashing))
    }
}
