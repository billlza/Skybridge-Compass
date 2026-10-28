import SwiftUI
import SkyBridgeWeatherRendering

/// iOS Liquid Glass（液态玻璃）统一封装：
/// - 内容卡片使用标准 Material，并遵循增强对比度与降低透明度设置。
/// - 浮动控件在 iOS 26+ 使用 regular Liquid Glass；旧版使用系统 Material。
@available(iOS 17.0, macOS 14.0, *)
public enum LiquidGlass {
    /// 默认卡片圆角
    public static let defaultCornerRadius: CGFloat = 24
    /// Supporting content remains adaptive, with enough ink for small text on translucent cards.
    public static let supportingText = Color.primary.opacity(0.78)
}

@available(iOS 17.0, macOS 14.0, *)
private struct LiquidGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let contentPadding: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Text-bearing content uses a standard material. Clear Liquid Glass belongs to
        // floating controls; it cannot provide a stable reading surface over arbitrary content.
        content
            .padding(contentPadding)
            .background(contentMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.3 : 0.08)))
            .weatherGlassSurface(cornerRadius: cornerRadius)
    }

    private var contentMaterial: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(colorScheme == .dark ? Color.black : Color.white)
        }
        return AnyShapeStyle(contrast == .increased ? Material.thick : Material.regular)
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct LiquidGlassCapsuleModifier: ViewModifier {
    let contentPaddingH: CGFloat
    let contentPaddingV: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                content
                    .padding(.horizontal, contentPaddingH)
                    .padding(.vertical, contentPaddingV)
                    .glassEffect(
                        Glass.regular.interactive(),
                        in: .capsule
                    )
                    .background(
                        (colorScheme == .dark ? Color.black : Color.white)
                            .opacity(reduceTransparency ? 1 : (colorScheme == .dark ? 0.24 : 0.18)),
                        in: Capsule()
                    )
            } else {
                content
                    .padding(.horizontal, contentPaddingH)
                    .padding(.vertical, contentPaddingV)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }
        }
        .weatherGlassSurface(cornerRadius: 100)
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct LiquidGlassGroupModifier: ViewModifier {
    let spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
public extension View {
    /// Share the system's glass rendering pass without layering glass on glass.
    func liquidGlassGroup(spacing: CGFloat = 8) -> some View {
        modifier(LiquidGlassGroupModifier(spacing: spacing))
    }
    /// 液态玻璃卡片（适用于你的主界面卡片/面板）
    func liquidGlassCard(
        cornerRadius: CGFloat = LiquidGlass.defaultCornerRadius,
        padding: CGFloat = 20
    ) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, contentPadding: padding))
    }

    /// 液态玻璃胶囊（适用于截图里的“底部胶囊栏/悬浮工具条”）
    func liquidGlassCapsule(
        paddingH: CGFloat = 16,
        paddingV: CGFloat = 10
    ) -> some View {
        modifier(LiquidGlassCapsuleModifier(contentPaddingH: paddingH, contentPaddingV: paddingV))
    }
}
