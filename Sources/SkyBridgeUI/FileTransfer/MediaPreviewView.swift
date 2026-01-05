import SwiftUI
import AVKit
import AVFoundation
import SkyBridgeCore

/// 媒体预览视图 - 支持音频和视频文件预览
struct MediaPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Float = 1.0
    @State private var showingControls = true
    @State private var fileInfo: FileInfo?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
 // 媒体播放区域
                mediaPlayerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showingControls.toggle()
                        }
                    }
                
 // 控制面板
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
 // 关闭预览
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(LocalizationManager.shared.localizedString("action.share")) {
 // 分享文件
                }
            }
        }
        }
        .onAppear {
            setupPlayer()
            loadFileInfo()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
 // MARK: - 媒体播放器视图
    
    @ViewBuilder
    private var mediaPlayerView: some View {
        if isVideoFile {
 // 视频播放器
            if let player = player {
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: .fit)
            } else {
                loadingView
            }
        } else {
 // 音频可视化界面
            audioVisualizationView
        }
    }
    
 // MARK: - 音频可视化视图
    
    private var audioVisualizationView: some View {
        VStack(spacing: 32) {
 // 专辑封面或音频图标
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
                    
                    if let info = fileInfo {
                        Text(info.formattedDuration)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            
 // 音频波形可视化（简化版）
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
    
 // MARK: - 音频波形视图
    
    private var audioWaveformView: some View {
        HStack(spacing: 2) {
            ForEach(0..<50, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 3)
                    .frame(height: CGFloat.random(in: 10...50))
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                        value: isPlaying
                    )
            }
        }
    }
    
 // MARK: - 控制面板
    
    private var controlPanel: some View {
        VStack(spacing: 16) {
 // 进度条
            progressSlider
            
 // 播放控制按钮
            playbackControls
            
 // 音量控制
            volumeControl
            
 // 文件信息
            if let info = fileInfo {
                fileInfoView(info)
            }
        }
    }
    
 // MARK: - 进度条
    
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
    
 // MARK: - 播放控制
    
    private var playbackControls: some View {
        HStack(spacing: 24) {
 // 后退15秒
            Button {
                seekBy(-15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
            }
            
 // 播放/暂停
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
            }
            .buttonStyle(.plain)
            
 // 前进15秒
            Button {
                seekBy(15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.title2)
            }
        }
    }
    
 // MARK: - 音量控制
    
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
    
 // MARK: - 文件信息视图
    
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
                
                GridRow {
                    Text("时长:")
                        .foregroundColor(.secondary)
                    Text(info.formattedDuration)
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
    
 // MARK: - 加载视图
    
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
    
 // MARK: - 计算属性
    
    private var isVideoFile: Bool {
        let videoExtensions = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "m4v"]
        return videoExtensions.contains(fileURL.pathExtension.lowercased())
    }
    
 // MARK: - 私有方法
    
 /// 设置播放器
    private func setupPlayer() {
        player = AVPlayer(url: fileURL)
        
 // 监听播放状态
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000), queue: .main) { time in
            Task { @MainActor in
                self.currentTime = time.seconds
            }
        }
        
 // 监听播放完成
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = false
                currentTime = 0
                player?.seek(to: .zero)
            }
        }
        
 // 获取时长（避免使用已废弃API）
        if let item = player?.currentItem {
            Task { @MainActor in
                if let dur = try? await item.asset.load(.duration), dur.isValid && !dur.isIndefinite {
                    self.duration = dur.seconds
                }
            }
        }
    }
    
 /// 加载文件信息
    private func loadFileInfo() {
        Task {
            do {
                let resources = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                let fileSize = resources.fileSize ?? 0
                
                let asset = AVAsset(url: fileURL)
                let duration = try await asset.load(.duration)
                
                await MainActor.run {
                    self.fileInfo = FileInfo(
                        fileName: fileURL.lastPathComponent,
                        fileSize: ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file),
                        duration: duration.seconds,
                        format: fileURL.pathExtension.uppercased()
                    )
                    self.duration = duration.seconds
                }
            } catch {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "SkyBridgeCompassApp", category: "ui").error("加载文件信息失败: \(error.localizedDescription)")
            }
        }
    }
    
 /// 切换播放状态
    private func togglePlayback() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
 /// 跳转播放位置
    private func seekBy(_ seconds: Double) {
        let newTime = max(0, min(currentTime + seconds, duration))
        player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 1000))
        currentTime = newTime
    }
    
 /// 格式化时间
    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 文件信息模型

private struct FileInfo {
    let fileName: String
    let fileSize: String
    let duration: Double
    let format: String?
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct MediaPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        MediaPreviewView(fileURL: URL(fileURLWithPath: "/Users/test/Movies/sample.mp4"))
    }
}
import OSLog
