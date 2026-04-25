import SwiftUI
import AVKit
import AVFoundation
import ImageIO
#if canImport(AppKit)
import AppKit
private typealias PreviewPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
private typealias PreviewPlatformImage = UIImage
#endif
import OSLog
import SkyBridgeCore

enum FilePreviewKind: Equatable {
    case image
    case video
    case audio
    case unsupported

    static func kind(for url: URL) -> FilePreviewKind {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp":
            return .image
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "m4v":
            return .video
        case "mp3", "wav", "aac", "flac", "m4a", "aiff", "aif":
            return .audio
        default:
            return .unsupported
        }
    }

    static func isPreviewable(_ url: URL) -> Bool {
        kind(for: url) != .unsupported
    }
}

/// 文件预览视图 - 支持图片、音频和视频文件预览。
struct MediaPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL

    @State private var player: AVPlayer?
    @State private var image: PreviewPlatformImage?
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Float = 1.0
    @State private var showingControls = true
    @State private var fileInfo: FileInfo?
    @State private var playerTimeObserverToken: Any?
    @State private var playbackEndObserverToken: NSObjectProtocol?
    @State private var waveformHeights = MediaPreviewView.makeWaveformHeights()

    private var previewKind: FilePreviewKind {
        FilePreviewKind.kind(for: fileURL)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                mediaPlayerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onTapGesture {
                        guard previewKind != .image else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showingControls.toggle()
                        }
                    }

                if showingControls {
                    controlPanel
                        .padding()
                        .background(.ultraThinMaterial)
                        .overlay(
                            Rectangle()
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationManager.shared.localizedString("action.close")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(LocalizationManager.shared.localizedString("action.share")) {
                        openInSystemViewer()
                    }
                }
            }
        }
        .onAppear {
            loadPreview()
        }
        .onDisappear {
            cleanupPlayer()
            imageLoadTask?.cancel()
            imageLoadTask = nil
        }
    }

    @ViewBuilder
    private var mediaPlayerView: some View {
        switch previewKind {
        case .image:
            imagePreviewView
        case .video:
            if let player {
                MediaPreviewVideoPlayerView(player: player)
            } else if let loadError {
                errorView(loadError)
            } else {
                loadingView
            }
        case .audio:
            audioVisualizationView
        case .unsupported:
            errorView("此文件类型不支持预览")
        }
    }

    private var imagePreviewView: some View {
        Group {
            if let image {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        platformImageView(image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                maxWidth: max(geometry.size.width, 1),
                                maxHeight: max(geometry.size.height, 1)
                            )
                            .padding(24)
                    }
                    .background(Color.black)
                }
            } else if let loadError {
                errorView(loadError)
            } else {
                loadingView
            }
        }
    }

    private var audioVisualizationView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Image(systemName: "music.note")
                    .font(.system(size: 80))
                    .foregroundColor(.white.opacity(0.8))

                VStack(spacing: 8) {
                    Text(fileURL.deletingPathExtension().lastPathComponent)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    if let formattedDuration = fileInfo?.formattedDuration {
                        Text(formattedDuration)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }

            audioWaveformView
                .frame(height: 60)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [.purple.opacity(0.8), .blue.opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var audioWaveformView: some View {
        HStack(spacing: 2) {
            ForEach(Array(waveformHeights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 3)
                    .frame(height: height)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: isPlaying
                    )
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 16) {
            if previewKind == .video || previewKind == .audio {
                progressSlider
                playbackControls
                volumeControl
            }

            if let info = fileInfo {
                fileInfoView(info)
            }
        }
    }

    private var progressSlider: some View {
        VStack(spacing: 8) {
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                if !editing {
                    player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 1000))
                }
            }
            .accentColor(.blue)

            HStack {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 24) {
            Button {
                seekBy(-15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
            }

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
            }
            .buttonStyle(.plain)

            Button {
                seekBy(15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.title2)
            }
        }
    }

    private var volumeControl: some View {
        HStack {
            Image(systemName: "speaker.fill")
                .foregroundColor(.secondary)

            Slider(value: $volume, in: 0...1) { _ in
                player?.volume = volume
            }
            .frame(width: 100)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundColor(.secondary)
        }
    }

    private func fileInfoView(_ info: FileInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件信息")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("文件名:")
                        .foregroundColor(.secondary)
                    Text(info.fileName)
                }

                GridRow {
                    Text("大小:")
                        .foregroundColor(.secondary)
                    Text(info.fileSize)
                }

                if let formattedDuration = info.formattedDuration {
                    GridRow {
                        Text("时长:")
                            .foregroundColor(.secondary)
                        Text(formattedDuration)
                    }
                }

                if let dimensions = info.dimensions {
                    GridRow {
                        Text("尺寸:")
                            .foregroundColor(.secondary)
                        Text(dimensions)
                    }
                }

                if let format = info.format {
                    GridRow {
                        Text("格式:")
                            .foregroundColor(.secondary)
                        Text(format)
                    }
                }
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("正在加载...")
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.yellow)

            Text(message)
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(fileURL.lastPathComponent)
                .font(.caption)
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func loadPreview() {
        imageLoadTask?.cancel()
        imageLoadTask = nil
        cleanupPlayer()
        image = nil
        loadError = nil
        fileInfo = nil
        isPlaying = false
        currentTime = 0
        duration = 0

        switch previewKind {
        case .image:
            loadImagePreview()
        case .video, .audio:
            setupPlayer()
            loadFileInfo(loadMediaDuration: true, imageSize: nil)
        case .unsupported:
            loadFileInfo(loadMediaDuration: false, imageSize: nil)
        }
    }

    private func setupPlayer() {
        cleanupPlayer()

        let player = AVPlayer(url: fileURL)
        self.player = player

        playerTimeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000),
            queue: .main
        ) { time in
            Task { @MainActor in
                self.currentTime = time.seconds
            }
        }

        playbackEndObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = false
                currentTime = 0
                player.seek(to: .zero)
            }
        }
    }

    private func cleanupPlayer() {
        if let player, let token = playerTimeObserverToken {
            player.removeTimeObserver(token)
        }
        playerTimeObserverToken = nil

        if let playbackEndObserverToken {
            NotificationCenter.default.removeObserver(playbackEndObserverToken)
        }
        playbackEndObserverToken = nil

        player?.pause()
        player = nil
    }

    private func loadImagePreview() {
        let previewURL = fileURL
        imageLoadTask = Task {
            do {
                let loadedPreview = try await Task.detached(priority: .userInitiated) {
                    try Self.makeImagePreview(for: previewURL)
                }.value
                guard !Task.isCancelled else { return }
                image = loadedPreview.image
                loadFileInfo(loadMediaDuration: false, imageSize: loadedPreview.dimensions)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                loadError = "无法加载图片预览"
                loadFileInfo(loadMediaDuration: false, imageSize: nil)
            }
        }
    }

    private func loadFileInfo(loadMediaDuration: Bool, imageSize: CGSize?) {
        Task {
            do {
                let fileSize = try await Task.detached(priority: .utility) {
                    let resources = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                    return resources.fileSize ?? 0
                }.value

                var mediaDuration: Double?
                if loadMediaDuration {
                    let asset = AVAsset(url: fileURL)
                    let loadedDuration = try await asset.load(.duration)
                    if loadedDuration.isValid,
                       !loadedDuration.isIndefinite,
                       loadedDuration.seconds.isFinite {
                        mediaDuration = loadedDuration.seconds
                    }
                }

                self.fileInfo = FileInfo(
                    fileName: fileURL.lastPathComponent,
                    fileSize: ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file),
                    duration: mediaDuration,
                    dimensions: Self.formattedDimensions(imageSize),
                    format: fileURL.pathExtension.uppercased()
                )
                if let mediaDuration {
                    self.duration = mediaDuration
                }
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "SkyBridgeCompassApp", category: "ui").error("加载文件信息失败: \(error.localizedDescription)")
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }

    private func seekBy(_ seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 1000))
        currentTime = newTime
    }

    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func openInSystemViewer() {
#if canImport(AppKit)
        NSWorkspace.shared.open(fileURL)
#elseif canImport(UIKit)
        // iOS builds use the system document flow elsewhere.
#endif
    }

    @ViewBuilder
    private func platformImageView(_ image: PreviewPlatformImage) -> Image {
#if canImport(AppKit)
        Image(nsImage: image)
#elseif canImport(UIKit)
        Image(uiImage: image)
#endif
    }

    private static func makeWaveformHeights() -> [CGFloat] {
        (0..<50).map { index in
            let phase = Double(index) * 0.41
            return CGFloat(18 + (sin(phase) + 1) * 16)
        }
    }

    private static func formattedDimensions(_ size: CGSize?) -> String? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    private nonisolated static func makeImagePreview(for url: URL) throws -> LoadedPreviewImage {
        let sourceOptions: CFDictionary = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat
        let originalHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat

        let thumbnailOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let dimensions = CGSize(
            width: originalWidth ?? CGFloat(thumbnail.width),
            height: originalHeight ?? CGFloat(thumbnail.height)
        )
#if canImport(AppKit)
        let image = NSImage(
            cgImage: thumbnail,
            size: CGSize(width: thumbnail.width, height: thumbnail.height)
        )
#elseif canImport(UIKit)
        let image = UIImage(cgImage: thumbnail)
#endif
        return LoadedPreviewImage(image: image, dimensions: dimensions)
    }
}

private struct FileInfo {
    let fileName: String
    let fileSize: String
    let duration: Double?
    let dimensions: String?
    let format: String?

    var formattedDuration: String? {
        guard let duration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct LoadedPreviewImage: @unchecked Sendable {
    let image: PreviewPlatformImage
    let dimensions: CGSize
}

private extension PreviewPlatformImage {
    var previewSize: CGSize {
#if canImport(AppKit)
        size
#elseif canImport(UIKit)
        size
#endif
    }
}

struct MediaPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        MediaPreviewView(fileURL: URL(fileURLWithPath: "/Users/test/Pictures/sample.png"))
    }
}

#if canImport(AppKit)
private struct MediaPreviewVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsSharingServiceButton = false
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
#endif
