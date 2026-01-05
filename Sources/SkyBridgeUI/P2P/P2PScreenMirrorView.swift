//
// P2PScreenMirrorView.swift
// SkyBridgeUI
//
// iOS/iPadOS P2P Integration - Screen Mirror UI
// Requirements: 7.8, 7.9
//

import SwiftUI
import SkyBridgeCore

// MARK: - P2P Screen Mirror View

/// P2P 屏幕镜像视图
/// 显示 iOS 设备的屏幕镜像和控制按钮
@available(macOS 14.0, iOS 17.0, *)
public struct P2PScreenMirrorView: View {
    
 // MARK: - State
    
    @StateObject private var viewModel = P2PScreenMirrorViewModel()
    @State private var isFullscreen: Bool = false
    @State private var showControls: Bool = true
    @State private var controlsHideTimer: Timer?
    
 // MARK: - Environment
    
    @Environment(\.dismiss) private var dismiss
    
 // MARK: - Body
    
    public init() {}
    
    public var body: some View {
        ZStack {
 // 背景
            Color.black
                .ignoresSafeArea()
            
 // 视频显示区域
            videoDisplayView
            
 // 控制覆盖层
            if showControls {
                controlsOverlay
            }
            
 // 录制指示器
            if viewModel.isRecording {
                recordingIndicator
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onHover { hovering in
            if hovering {
                showControls = true
                resetControlsTimer()
            }
        }
        .onTapGesture {
            showControls.toggle()
            if showControls {
                resetControlsTimer()
            }
        }
    }
    
 // MARK: - Video Display
    
    private var videoDisplayView: some View {
        GeometryReader { geometry in
            ZStack {
                if let frame = viewModel.currentFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
 // 占位符
                    VStack(spacing: 16) {
                        Image(systemName: "iphone")
                            .font(.system(size: 64))
                            .foregroundColor(.gray)
                        
                        Text(viewModel.statusText)
                            .font(.headline)
                            .foregroundColor(.gray)
                        
                        if viewModel.isConnecting {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
    
 // MARK: - Controls Overlay
    
    private var controlsOverlay: some View {
        VStack {
 // 顶部工具栏
            topToolbar
            
            Spacer()
            
 // 底部控制栏
            bottomControls
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }
    
 // MARK: - Top Toolbar
    
    private var topToolbar: some View {
        HStack {
 // 设备信息
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.deviceName)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(viewModel.connectionStatus)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            Spacer()
            
 // 连接质量指示器
            connectionQualityIndicator
            
 // 关闭按钮
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
 // MARK: - Connection Quality Indicator
    
    private var connectionQualityIndicator: some View {
        HStack(spacing: 4) {
 // 信号强度条
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < viewModel.signalStrength ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 4, height: CGFloat(6 + index * 3))
            }
            
 // 延迟显示
            Text("\(viewModel.latencyMs)ms")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
    }
    
 // MARK: - Bottom Controls
    
    private var bottomControls: some View {
        HStack(spacing: 24) {
 // 录制按钮
            controlButton(
                icon: viewModel.isRecording ? "stop.circle.fill" : "record.circle",
                label: viewModel.isRecording ? "停止" : "录制",
                color: viewModel.isRecording ? .red : .white,
                action: { viewModel.toggleRecording() }
            )
            
 // 截图按钮
            controlButton(
                icon: "camera.fill",
                label: "截图",
                color: .white,
                action: { viewModel.takeScreenshot() }
            )
            
 // 全屏按钮
            controlButton(
                icon: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: isFullscreen ? "退出全屏" : "全屏",
                color: .white,
                action: { toggleFullscreen() }
            )
            
 // 设置按钮
            controlButton(
                icon: "gearshape.fill",
                label: "设置",
                color: .white,
                action: { viewModel.showSettings = true }
            )
            
            Spacer()
            
 // 断开连接按钮
            controlButton(
                icon: "xmark.circle.fill",
                label: "断开",
                color: .orange,
                action: { viewModel.disconnect() }
            )
        }
        .padding()
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    private func controlButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }
    
 // MARK: - Recording Indicator
    
    private var recordingIndicator: some View {
        VStack {
            HStack {
                Spacer()
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .opacity(viewModel.recordingIndicatorOpacity)
                    
                    Text("录制中")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    
                    Text(viewModel.recordingDuration)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.8))
                .cornerRadius(16)
                .padding()
            }
            
            Spacer()
        }
    }
    
 // MARK: - Helpers
    
    private func resetControlsTimer() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            Task { @MainActor in
                withAnimation {
                    showControls = false
                }
            }
        }
    }
    
    private func toggleFullscreen() {
        isFullscreen.toggle()
 // 实际全屏切换逻辑
        if let window = NSApplication.shared.keyWindow {
            window.toggleFullScreen(nil)
        }
    }
}

// MARK: - View Model

@available(macOS 14.0, iOS 17.0, *)
@MainActor
class P2PScreenMirrorViewModel: ObservableObject {
    
    @Published var currentFrame: NSImage?
    @Published var deviceName: String = "iPhone"
    @Published var connectionStatus: String = "已连接"
    @Published var isConnecting: Bool = false
    @Published var isRecording: Bool = false
    @Published var showSettings: Bool = false
    @Published var statusText: String = "等待连接..."
    @Published var signalStrength: Int = 3
    @Published var latencyMs: Int = 25
    @Published var recordingDuration: String = "00:00"
    @Published var recordingIndicatorOpacity: Double = 1.0
    
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var blinkTimer: Timer?
    
    func toggleRecording() {
        isRecording.toggle()
        
        if isRecording {
            startRecording()
        } else {
            stopRecording()
        }
    }
    
    func takeScreenshot() {
        guard let frame = currentFrame else { return }
        
 // 保存截图
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot_\(Date().ISO8601Format()).png"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let tiffData = frame.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: url)
                }
            }
        }
    }
    
    func disconnect() {
 // 断开连接
        currentFrame = nil
        connectionStatus = "已断开"
        statusText = "连接已断开"
    }
    
    private func startRecording() {
        recordingStartTime = Date()
        
 // 更新录制时长
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRecordingDuration()
            }
        }
        
 // 闪烁指示器
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingIndicatorOpacity = self?.recordingIndicatorOpacity == 1.0 ? 0.3 : 1.0
            }
        }
    }
    
    private func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
        recordingIndicatorOpacity = 1.0
        recordingDuration = "00:00"
    }
    
    private func updateRecordingDuration() {
        guard let startTime = recordingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(startTime))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        recordingDuration = String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, iOS 17.0, *)
#Preview {
    P2PScreenMirrorView()
        .frame(width: 800, height: 600)
}
#endif
