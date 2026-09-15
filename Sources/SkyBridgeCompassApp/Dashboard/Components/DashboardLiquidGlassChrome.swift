import SwiftUI
import SkyBridgeUI
import SkyBridgeWeatherRendering

private struct DashboardGlassAncestorKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var hasDashboardGlassAncestor: Bool {
        get { self[DashboardGlassAncestorKey.self] }
        set { self[DashboardGlassAncestorKey.self] = newValue }
    }
}

@available(macOS 14.0, *)
private struct DashboardGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.hasDashboardGlassAncestor) private var hasGlassAncestor

    func body(content: Content) -> some View {
        Group {
            if hasGlassAncestor {
                // Child rows share the panel's optical surface; a second glass
                // pass would sample the parent glass instead of the weather.
                content.background(
                    Color.white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                content.skyBridgeLiquidGlassBackground(
                    cornerRadius: cornerRadius,
                    fallbackMaterial: .ultraThinMaterial,
                    borderColor: Color.white.opacity(0.12),
                    nativeStrokeColor: .clear
                )
                .weatherGlassSurface(cornerRadius: cornerRadius)
            }
        }
        .environment(\.hasDashboardGlassAncestor, true)
    }
}

/// 主控台全宽卡片的液态玻璃外观，使用系统光学材质采样真实背景。
///
/// 从天气卡片抽出，账号设备面板与天气卡片共用同一套视觉，避免在同一页面出现第二种"玻璃"。
@available(macOS 14.0, *)
struct DashboardLiquidGlassChrome: ViewModifier {
    let accent: Color
    let isHovering: Bool
    let isFlashing: Bool

    func body(content: Content) -> some View {
        content
            .dashboardGlassSurface(cornerRadius: 20)
            .shadow(
                color: accent.opacity(isFlashing ? 0.3 : 0.1),
                radius: isFlashing ? 20 : 8,
                x: 0,
                y: isFlashing ? 8 : 4
            )
            .scaleEffect(isHovering ? 1.005 : 1.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isHovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isFlashing)
    }
}

@available(macOS 14.0, *)
extension View {
    /// One optical background per content panel; the weather overlay receives
    /// the same bounds and corner radius for its wet edges.
    func dashboardGlassSurface(cornerRadius: CGFloat) -> some View {
        modifier(DashboardGlassSurfaceModifier(cornerRadius: cornerRadius))
    }

    func dashboardLiquidGlassChrome(accent: Color, isHovering: Bool, isFlashing: Bool = false) -> some View {
        modifier(DashboardLiquidGlassChrome(accent: accent, isHovering: isHovering, isFlashing: isFlashing))
    }
}
