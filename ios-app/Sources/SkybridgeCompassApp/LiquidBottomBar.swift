import SwiftUI
import SkyBridgeDesignSystem

struct LiquidBottomBar<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 12) {
            LiquidHandle()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16 + safeAreaBottomInset())
        .background(liquidGlassMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.45), radius: 32, x: 0, y: -2)
        .padding(.horizontal, 8)
    }
}
