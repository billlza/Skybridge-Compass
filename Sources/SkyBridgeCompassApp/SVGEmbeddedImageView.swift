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

    @State private var nsImage: NSImage?

    init(
        contentMode: ContentMode = .fit,
        safeInset: CGFloat = 0,
        clipCornerRadius: CGFloat? = nil
    ) {
        self.contentMode = contentMode
        self.safeInset = safeInset
        self.clipCornerRadius = clipCornerRadius
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
        .task {
            if nsImage == nil {
                nsImage = BrandIconAssetLoader.load()
            }
        }
    }
}

@MainActor
private enum BrandIconAssetLoader {
    static func load() -> NSImage? {
        if isRunningFromPackagedApp,
           let appIcon = NSApplication.shared.applicationIconImage.copy() as? NSImage,
           appIcon.size.width > 0,
           appIcon.size.height > 0 {
            return appIcon
        }

        for bundle in [Bundle.module] {
            for candidate in iconCandidates {
                if let url = bundle.url(forResource: candidate.name, withExtension: candidate.extensionName),
                   let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        return nil
    }

    private static let iconCandidates: [(name: String, extensionName: String)] = [
        ("AppIcon", "png"),
        ("BrandIcon", "png"),
        ("AppIconDock", "png"),
        ("app_icon", "png")
    ]

    private static var isRunningFromPackagedApp: Bool {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        return packagedContentsURL(containing: executableURL) != nil
    }

    private static func packagedContentsURL(containing executableURL: URL) -> URL? {
        var url = executableURL
        while url.path != "/" {
            if url.lastPathComponent == "Contents" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

private extension View {
    func applyCornerClip(_ radius: CGFloat?) -> some View {
        guard let r = radius else { return AnyView(self) }
        return AnyView(self.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous)))
    }
}
