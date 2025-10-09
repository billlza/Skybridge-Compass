import SwiftUI

extension View {
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 28) -> some View {
        if #available(iOS 18.0, *) {
            self
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
