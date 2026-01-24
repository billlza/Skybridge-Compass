import SwiftUI

/// iOS Liquid Glass（液态玻璃）统一封装：
/// - iOS 26+：使用系统 `glassEffect`（与 macOS 26 Tahoe 端一致）
/// - iOS 17-18：自动回退到 `.ultraThinMaterial`（保证可用性）
@available(iOS 17.0, macOS 14.0, *)
public enum LiquidGlass {
    /// 默认卡片圆角
    public static let defaultCornerRadius: CGFloat = 24
}

@available(iOS 17.0, macOS 14.0, *)
private struct LiquidGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let contentPadding: CGFloat

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                content
                    .padding(contentPadding)
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .clipShape(shape)
                    .overlay(
                        shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
            } else {
                content
                    .padding(contentPadding)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct LiquidGlassCapsuleModifier: ViewModifier {
    let contentPaddingH: CGFloat
    let contentPaddingV: CGFloat

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                content
                    .padding(.horizontal, contentPaddingH)
                    .padding(.vertical, contentPaddingV)
                    .glassEffect(.regular, in: .capsule)
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
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
    }
}

@available(iOS 17.0, macOS 14.0, *)
public extension View {
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
