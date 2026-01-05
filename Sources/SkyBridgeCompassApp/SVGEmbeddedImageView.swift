import SwiftUI
import AppKit

struct SVGEmbeddedImageView: View {
    let filePath: String
    let contentMode: ContentMode
    let safeInset: CGFloat
    let clipCornerRadius: CGFloat?
    @State private var nsImage: NSImage?
    var body: some View {
        ZStack {
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .clipped()
                    .padding(safeInset)
                    .applyCornerClip(clipCornerRadius)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: load)
    }
    private func load() {
        Task.detached(priority: .utility) {
            guard let data = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
            let marker = "base64,"
            guard let mRange = data.range(of: marker) else { return }
            let start = mRange.upperBound
            guard let end = data[start...].firstIndex(of: "\"") else { return }
            let b64 = String(data[start..<end])
            guard let raw = Data(base64Encoded: b64) else { return }
            let img = NSImage(data: raw)
            await MainActor.run { self.nsImage = img }
        }
    }
}

struct CustomGlobeIconView: View {
    var cornerRadius: CGFloat = 12
    var body: some View {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "custom-globe", withExtension: "svg")
            ?? bundle.url(forResource: "custom-globe", withExtension: "svg", subdirectory: "Icons")
            ?? bundle.url(forResource: "app-icon", withExtension: "svg")
        let env = ProcessInfo.processInfo.environment
        let explicitPath = env["SKYBRIDGE_ICON_SVG_PATH"]
        let defaultPath = "/Users/bill/Desktop/SkyBridge Compass Pro release/1764932992803.svg"
        let path = url?.path ?? explicitPath ?? defaultPath
        SVGEmbeddedImageView(filePath: path, contentMode: .fill, safeInset: 0, clipCornerRadius: cornerRadius)
    }
}

private extension View {
    func applyCornerClip(_ radius: CGFloat?) -> some View {
        guard let r = radius else { return AnyView(self) }
        return AnyView(self.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous)))
    }
}
