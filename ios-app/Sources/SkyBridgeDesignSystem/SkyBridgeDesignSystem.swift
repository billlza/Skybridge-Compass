import SwiftUI
import UIKit

public enum SkyBridgeColors {
    public static let nebulaTop = Color(red: 18/255, green: 27/255, blue: 51/255)
    public static let nebulaBottom = Color(red: 35/255, green: 8/255, blue: 50/255)
    public static let accentBlue = Color(red: 78/255, green: 150/255, blue: 241/255)
    public static let accentPurple = Color(red: 172/255, green: 108/255, blue: 248/255)
    public static let warningYellow = Color(red: 255/255, green: 203/255, blue: 108/255)
    public static let successGreen = Color(red: 83/255, green: 201/255, blue: 166/255)
}

public enum SkyBridgeGradients {
    public static let aurora = LinearGradient(
        gradient: Gradient(colors: [SkyBridgeColors.nebulaTop, SkyBridgeColors.nebulaBottom]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    public static let accent = LinearGradient(
        colors: [SkyBridgeColors.accentBlue, SkyBridgeColors.accentPurple],
        startPoint: .leading,
        endPoint: .trailing
    )
}

public struct SkyBridgeBackground: View {
    public init() {}
    public var body: some View {
        ZStack {
            SkyBridgeGradients.aurora
                .ignoresSafeArea()
            RadialGradient(
                colors: [SkyBridgeColors.accentPurple.opacity(0.35), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 450
            )
            .blendMode(.screen)
            .blur(radius: 64)
            Starfield()
        }
    }
}

struct Starfield: View {
    let stars: [CGPoint] = (0..<120).map { index in
        let x = CGFloat(index).truncatingRemainder(dividingBy: 12) / 12
        let y = CGFloat(index) / 120
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(stars.enumerated()), id: \.offset) { pair in
                let point = pair.element
                Circle()
                    .fill(Color.white.opacity(Double.random(in: 0.15...0.4)))
                    .frame(width: 2, height: 2)
                    .position(x: proxy.size.width * point.x, y: proxy.size.height * point.y)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

public struct GlassCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding()
            .background(liquidGlassMaterial())
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
    }
}

@ViewBuilder
public func liquidGlassMaterial() -> some ShapeStyle {
    if #available(iOS 26, *) {
        AnyShapeStyle(.thickMaterial)
    } else {
        AnyShapeStyle(.ultraThinMaterial)
    }
}

@MainActor
public func safeAreaBottomInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
}

public struct LiquidHandle: View {
    public init() {}
    public var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.4))
            .frame(width: 36, height: 4)
            .padding(.top, 8)
    }
}
