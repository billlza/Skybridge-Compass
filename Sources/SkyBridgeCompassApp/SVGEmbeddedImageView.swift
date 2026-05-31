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
        BrandAppIconView(
            contentMode: .fill,
            safeInset: 0,
            clipCornerRadius: cornerRadius
        )
    }
}

struct BrandAppIconView: View {
    let contentMode: ContentMode
    let safeInset: CGFloat
    let clipCornerRadius: CGFloat?
    let preferredResourceName: String

    @State private var nsImage: NSImage?

    init(
        contentMode: ContentMode = .fit,
        safeInset: CGFloat = 0,
        clipCornerRadius: CGFloat? = nil,
        preferredResourceName: String = "BrandIcon"
    ) {
        self.contentMode = contentMode
        self.safeInset = safeInset
        self.clipCornerRadius = clipCornerRadius
        self.preferredResourceName = preferredResourceName
    }

    var body: some View {
        ZStack {
            if let image = nsImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: contentMode)
                    .padding(safeInset)
                    .applyCornerClip(clipCornerRadius)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard nsImage == nil else { return }
        let preferredResourceName = preferredResourceName
        Task.detached(priority: .utility) {
            let image = BrandIconAssetLoader.load(preferredResourceName: preferredResourceName)
            guard let image else { return }
            await MainActor.run { self.nsImage = image }
        }
    }
}

private enum BrandIconAssetLoader {
    static func load(preferredResourceName: String) -> NSImage? {
        if let image = loadImageResource(named: preferredResourceName, withExtension: "png", bundle: .main) {
            return image
        }

        if let image = loadImageResource(named: preferredResourceName, withExtension: "png", bundle: .module) {
            return image
        }

        if let image = loadImageResource(named: "BrandIcon", withExtension: "png", bundle: .main) {
            return image
        }

        return loadImageResource(named: "AppIcon", withExtension: "png", bundle: .module)
    }

    private static func loadImageResource(named name: String, withExtension extensionName: String, bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: name, withExtension: extensionName),
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        return image
    }

}

private extension View {
    func applyCornerClip(_ radius: CGFloat?) -> some View {
        guard let r = radius else { return AnyView(self) }
        return AnyView(self.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous)))
    }
}
