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
        let sourcePath = filePath
        Task.detached(priority: .utility) {
            let image = SVGEmbeddedImageView.decodeEmbeddedBase64Image(at: sourcePath)
                ?? NSImage(contentsOfFile: sourcePath)
            guard let image else { return }
            await MainActor.run { self.nsImage = image }
        }
    }

    nonisolated private static func decodeEmbeddedBase64Image(at path: String) -> NSImage? {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let marker = "base64,"
        guard let markerRange = data.range(of: marker) else { return nil }
        let start = markerRange.upperBound
        guard let end = data[start...].firstIndex(of: "\"") else { return nil }
        let payload = String(data[start..<end])
        guard let raw = Data(base64Encoded: payload) else { return nil }
        return NSImage(data: raw)
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
