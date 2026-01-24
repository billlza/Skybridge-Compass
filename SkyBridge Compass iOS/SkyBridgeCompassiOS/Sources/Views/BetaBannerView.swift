import SwiftUI

/// 发行版打磨：用于标注“实验功能 / Beta”，避免用户误解功能成熟度
@available(iOS 17.0, *)
struct BetaBannerView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.25))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())

                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.primary)

                Spacer(minLength: 0)
            }

            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}


