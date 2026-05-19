import SwiftUI

#if os(iOS)
struct UnsupportedIOSDeviceView: View {
    let device: UnsupportedIOSDevice

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    Color(red: 0.90, green: 0.94, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "iphone.gen3.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("This device is no longer supported.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.primary)

                Text("SkyBridge Compass now requires 2020 or newer iPhone and iPad hardware.")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("当前版本不再支持这台设备。SkyBridge Compass 现要求使用 2020 年及之后发布的 iPhone / iPad 硬件。")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Blocked model")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(device.displayName) (\(device.modelIdentifier))")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(24)
        }
    }
}
#endif
