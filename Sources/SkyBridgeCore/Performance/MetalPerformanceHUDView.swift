import SwiftUI
import Metal
import Foundation

/// Metal Performance HUD 的 SwiftUI 视图组件
@available(macOS 14.0, *)
public struct MetalPerformanceHUDView: View {
    
    @ObservedObject private var hud: MetalPerformanceHUD
    @State private var showConfiguration = false
    
    public init(hud: MetalPerformanceHUD) {
        self.hud = hud
    }
    
    public var body: some View {
        ZStack {
            if hud.isEnabled && hud.isVisible {
                hudOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: hud.isVisible)
            }
        }
    }
    
 // MARK: - HUD 覆盖层
    
    private var hudOverlay: some View {
        VStack {
            switch hud.hudConfiguration.position {
            case HUDPosition.topLeft, HUDPosition.topRight:
                hudContent
                Spacer()
            case HUDPosition.bottomLeft, HUDPosition.bottomRight:
                Spacer()
                hudContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false) // 允许点击穿透
    }
    
 // MARK: - HUD 内容
    
    private var hudContent: some View {
        HStack {
            if hud.hudConfiguration.position == HUDPosition.topRight || hud.hudConfiguration.position == HUDPosition.bottomRight {
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
 // 标题栏
                HStack {
                    Image(systemName: "speedometer")
                        .foregroundColor(.white)
                    Text("Metal Performance")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        showConfiguration.toggle()
                    }) {
                        Image(systemName: "gear")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: {
                        hud.toggleVisibility()
                    }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                Divider()
                    .background(Color.white.opacity(0.3))
                
 // 性能指标
                performanceMetrics
                
 // 设备信息
                if hud.hudConfiguration.showDeviceInfo {
                    deviceInfo
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(Double(hud.hudConfiguration.opacity)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .frame(minWidth: 280)
            
            if hud.hudConfiguration.position == HUDPosition.topLeft || hud.hudConfiguration.position == HUDPosition.bottomLeft {
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showConfiguration) {
            HUDConfigurationView(hud: hud)
        }
    }
    
 // MARK: - 性能指标视图
    
    private var performanceMetrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hud.hudConfiguration.showFrameRate {
                MetricRow(
                    icon: "timer",
                    label: "帧率",
                    value: String(format: "%.1f FPS", hud.currentMetrics.frameRate),
                    color: frameRateColor
                )
            }
            
            if hud.hudConfiguration.showGPUTime {
                MetricRow(
                    icon: "cpu",
                    label: "GPU时间",
                    value: String(format: "%.2f ms", hud.currentMetrics.gpuTime * 1000),
                    color: gpuTimeColor
                )
            }
            
            if hud.hudConfiguration.showMemoryUsage {
                MetricRow(
                    icon: "memorychip",
                    label: "内存使用",
                    value: formatMemoryUsage(hud.currentMetrics.memoryUsage),
                    color: memoryUsageColor
                )
            }
        }
    }
    
 // MARK: - 设备信息视图
    
    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .background(Color.white.opacity(0.3))
            
            HStack {
                Image(systemName: hud.currentMetrics.isAppleSilicon ? "cpu.fill" : "cpu")
                    .foregroundColor(.white.opacity(0.8))
                Text(hud.currentMetrics.deviceName)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            if hud.currentMetrics.isAppleSilicon {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.blue.opacity(0.8))
                    Text("Apple Silicon 优化")
                        .font(.caption2)
                        .foregroundColor(.blue.opacity(0.8))
                }
            }
        }
    }
    
 // MARK: - 辅助视图
    
    private func MetricRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
            
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
            
            Spacer()
            
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundColor(color)
        }
    }
    
 // MARK: - 计算属性
    
    private var frameRateColor: Color {
        let fps = hud.currentMetrics.frameRate
        if fps >= 55 {
            return .green
        } else if fps >= 30 {
            return .yellow
        } else {
            return .red
        }
    }
    
    private var gpuTimeColor: Color {
        let gpuTime = hud.currentMetrics.gpuTime * 1000 // 转换为毫秒
        if gpuTime <= 16.67 { // 60 FPS
            return .green
        } else if gpuTime <= 33.33 { // 30 FPS
            return .yellow
        } else {
            return .red
        }
    }
    
    private var memoryUsageColor: Color {
        let memoryGB = Double(hud.currentMetrics.memoryUsage) / (1024 * 1024 * 1024)
        if memoryGB <= 4 {
            return .green
        } else if memoryGB <= 8 {
            return .yellow
        } else {
            return .red
        }
    }
    
 // MARK: - 辅助方法
    
    private func formatMemoryUsage(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - HUD 配置视图

@available(macOS 14.0, *)
private struct HUDConfigurationView: View {
    @ObservedObject private var hud: MetalPerformanceHUD
    @State private var configuration: HUDConfiguration
    @Environment(\.dismiss) private var dismiss
    
    init(hud: MetalPerformanceHUD) {
        self.hud = hud
        self._configuration = State(initialValue: hud.hudConfiguration)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("显示设置") {
                    Toggle("自动显示", isOn: $configuration.autoShow)
                    
                    Picker("位置", selection: $configuration.position) {
                        Text("左上角").tag(HUDPosition.topLeft)
                        Text("右上角").tag(HUDPosition.topRight)
                        Text("左下角").tag(HUDPosition.bottomLeft)
                        Text("右下角").tag(HUDPosition.bottomRight)
                    }
                    
                    HStack {
                        Text("透明度")
                        Slider(value: Binding(
                            get: { Double(configuration.opacity) },
                            set: { configuration.opacity = Float($0) }
                        ), in: 0.3...1.0)
                        Text(String(format: "%.0f%%", configuration.opacity * 100))
                            .frame(width: 40)
                    }
                }
                
                Section("性能指标") {
                    Toggle("显示帧率", isOn: $configuration.showFrameRate)
                    Toggle("显示GPU时间", isOn: $configuration.showGPUTime)
                    Toggle("显示内存使用", isOn: $configuration.showMemoryUsage)
                    Toggle("显示设备信息", isOn: $configuration.showDeviceInfo)
                }
                
                Section("更新频率") {
                    Picker("更新间隔", selection: $configuration.updateInterval) {
                        Text("60 FPS").tag(1.0/60.0)
                        Text("30 FPS").tag(1.0/30.0)
                        Text("15 FPS").tag(1.0/15.0)
                    }
                }
            }
            .navigationTitle("HUD 配置")
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("保存") {
                        hud.updateConfiguration(configuration)
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}

// MARK: - 预览

@available(macOS 14.0, *)
struct MetalPerformanceHUDView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            if let device = MTLCreateSystemDefaultDevice(),
               let hud = try? MetalPerformanceHUD(device: device) {
                
 // 模拟数据
                let _ = hud.enable()
                
                MetalPerformanceHUDView(hud: hud)
                    .frame(width: 800, height: 600)
                    .background(Color.gray.opacity(0.3))
            } else {
                Text("Metal 设备不可用")
            }
        }
    }
}