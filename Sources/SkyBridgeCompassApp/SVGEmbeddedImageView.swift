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
        let shouldTrimTransparentBounds = preferredResourceName == "SidebarBrandIcon"
        if let image = loadImageResource(named: preferredResourceName, withExtension: "png", bundle: .main) {
            return normalizedBrandImage(image, trimTransparentBounds: shouldTrimTransparentBounds)
        }

        if let image = loadImageResource(named: preferredResourceName, withExtension: "png", bundle: .module) {
            return normalizedBrandImage(image, trimTransparentBounds: shouldTrimTransparentBounds)
        }

        if let image = loadImageResource(named: "BrandIcon", withExtension: "png", bundle: .main) {
            return normalizedBrandImage(image, trimTransparentBounds: false)
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

    private static func normalizedBrandImage(_ image: NSImage, trimTransparentBounds: Bool) -> NSImage {
        trimTransparentBounds ? Self.trimTransparentBounds(image) : image
    }

    private static func trimTransparentBounds(_ image: NSImage) -> NSImage {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return image
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 1, height > 1 else { return image }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let alpha = rgba[(y * width + x) * 4 + 3]
                guard alpha > 8 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        guard cropRect.width < CGFloat(width) * 0.98 || cropRect.height < CGFloat(height) * 0.98,
              let cropped = cgImage.cropping(to: cropRect) else {
            return image
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropRect.width, height: cropRect.height))
    }
}

private extension View {
    func applyCornerClip(_ radius: CGFloat?) -> some View {
        guard let r = radius else { return AnyView(self) }
        return AnyView(self.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous)))
    }
}
