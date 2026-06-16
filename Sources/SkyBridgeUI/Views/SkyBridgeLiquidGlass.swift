import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
public enum SkyBridgeLiquidGlass {
    public static let defaultCardCornerRadius: CGFloat = 24
    public static let defaultNativeStrokeColor = Color.white.opacity(0.18)
}

@available(iOS 17.0, macOS 14.0, *)
private struct SkyBridgeLiquidGlassMaterialBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fallbackCornerRadius: CGFloat
    let fallbackMaterial: Material
    let borderColor: Color
    let nativeStrokeColor: Color

    func body(content: Content) -> some View {
        content.background {
            if #available(iOS 26.0, macOS 26.0, *) {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .overlay(shape.strokeBorder(nativeStrokeColor, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: fallbackCornerRadius, style: .continuous)
                    .fill(fallbackMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: fallbackCornerRadius, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    )
            }
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct SkyBridgeLiquidGlassColorBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fallbackCornerRadius: CGFloat
    let fallbackColor: Color
    let borderColor: Color
    let nativeStrokeColor: Color

    func body(content: Content) -> some View {
        content.background {
            if #available(iOS 26.0, macOS 26.0, *) {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .overlay(shape.strokeBorder(nativeStrokeColor, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: fallbackCornerRadius, style: .continuous)
                    .fill(fallbackColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: fallbackCornerRadius, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 1)
                    )
            }
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct SkyBridgeLiquidGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let contentPadding: CGFloat
    let fallbackMaterial: Material
    let borderColor: Color
    let nativeStrokeColor: Color

    func body(content: Content) -> some View {
        content
            .padding(contentPadding)
            .skyBridgeLiquidGlassBackground(
                cornerRadius: cornerRadius,
                fallbackMaterial: fallbackMaterial,
                borderColor: borderColor,
                nativeStrokeColor: nativeStrokeColor
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

@available(iOS 17.0, macOS 14.0, *)
private struct SkyBridgeLiquidGlassCapsuleModifier: ViewModifier {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let fallbackColor: Color
    let borderColor: Color
    let nativeStrokeColor: Color

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                if #available(iOS 26.0, macOS 26.0, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: .capsule)
                        .overlay(Capsule().strokeBorder(nativeStrokeColor, lineWidth: 1))
                } else {
                    Capsule()
                        .fill(fallbackColor)
                        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
                }
            }
    }
}

@available(iOS 17.0, macOS 14.0, *)
public extension View {
    func skyBridgeLiquidGlassBackground(
        cornerRadius: CGFloat,
        fallbackCornerRadius: CGFloat? = nil,
        fallbackMaterial: Material,
        borderColor: Color,
        nativeStrokeColor: Color = SkyBridgeLiquidGlass.defaultNativeStrokeColor
    ) -> some View {
        modifier(
            SkyBridgeLiquidGlassMaterialBackgroundModifier(
                cornerRadius: cornerRadius,
                fallbackCornerRadius: fallbackCornerRadius ?? cornerRadius,
                fallbackMaterial: fallbackMaterial,
                borderColor: borderColor,
                nativeStrokeColor: nativeStrokeColor
            )
        )
    }

    func skyBridgeLiquidGlassBackground(
        cornerRadius: CGFloat,
        fallbackCornerRadius: CGFloat? = nil,
        fallbackColor: Color,
        borderColor: Color,
        nativeStrokeColor: Color = SkyBridgeLiquidGlass.defaultNativeStrokeColor
    ) -> some View {
        modifier(
            SkyBridgeLiquidGlassColorBackgroundModifier(
                cornerRadius: cornerRadius,
                fallbackCornerRadius: fallbackCornerRadius ?? cornerRadius,
                fallbackColor: fallbackColor,
                borderColor: borderColor,
                nativeStrokeColor: nativeStrokeColor
            )
        )
    }

    func skyBridgeLiquidGlassCard(
        cornerRadius: CGFloat = SkyBridgeLiquidGlass.defaultCardCornerRadius,
        padding: CGFloat = 20,
        fallbackMaterial: Material = .ultraThinMaterial,
        borderColor: Color = Color.white.opacity(0.15),
        nativeStrokeColor: Color = SkyBridgeLiquidGlass.defaultNativeStrokeColor
    ) -> some View {
        modifier(
            SkyBridgeLiquidGlassCardModifier(
                cornerRadius: cornerRadius,
                contentPadding: padding,
                fallbackMaterial: fallbackMaterial,
                borderColor: borderColor,
                nativeStrokeColor: nativeStrokeColor
            )
        )
    }

    func skyBridgeLiquidGlassCapsule(
        horizontalPadding: CGFloat = 16,
        verticalPadding: CGFloat = 10,
        fallbackColor: Color,
        borderColor: Color,
        nativeStrokeColor: Color = SkyBridgeLiquidGlass.defaultNativeStrokeColor
    ) -> some View {
        modifier(
            SkyBridgeLiquidGlassCapsuleModifier(
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding,
                fallbackColor: fallbackColor,
                borderColor: borderColor,
                nativeStrokeColor: nativeStrokeColor
            )
        )
    }
}
