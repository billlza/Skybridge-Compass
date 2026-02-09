import SwiftUI

/// 网络监控卡片 - 显示网络使用情况和统计信息
/// 符合macOS设计规范，提供详细的网络监控信息
@available(macOS 14.0, *)
public struct NetworkMonitorCard: View {
    
 // MARK: - 属性
    
    let uploadSpeed: Double
    let downloadSpeed: Double
    let totalUploaded: Int64
    let totalDownloaded: Int64
    let connectionCount: Int
    let isConnected: Bool
    
 // MARK: - 状态属性
    
    @State private var animateUpload = false
    @State private var animateDownload = false
    @State private var isUploadPulseInFlight = false
    @State private var isDownloadPulseInFlight = false
    
 // MARK: - 初始化
    
    public init(
        uploadSpeed: Double,
        downloadSpeed: Double,
        totalUploaded: Int64,
        totalDownloaded: Int64,
        connectionCount: Int,
        isConnected: Bool
    ) {
        self.uploadSpeed = uploadSpeed
        self.downloadSpeed = downloadSpeed
        self.totalUploaded = totalUploaded
        self.totalDownloaded = totalDownloaded
        self.connectionCount = connectionCount
        self.isConnected = isConnected
    }
    
 // MARK: - 视图主体
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
 // 标题和连接状态
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                    .font(.title2)
                
                Text(LocalizationManager.shared.localizedString("monitor.network.title"))
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
 // 连接状态指示器
                HStack(spacing: 6) {
                    Circle()
                        .fill(isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(animateUpload ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: animateUpload)
                    
                    Text(LocalizationManager.shared.localizedString(isConnected ? "status.connected" : "status.disconnected"))
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .red)
                }
            }
            
 // 速度显示
            HStack(spacing: 24) {
 // 上传速度
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(.orange)
                            .font(.title3)
                            .scaleEffect(animateUpload ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 0.5), value: animateUpload)
                        
                        Text(LocalizationManager.shared.localizedString("monitor.network.upload"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Text(formatSpeed(uploadSpeed))
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .contentTransition(.numericText())
                }
                
                Divider()
                    .frame(height: 40)
                
 // 下载速度
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                            .scaleEffect(animateDownload ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 0.5), value: animateDownload)
                        
                        Text(LocalizationManager.shared.localizedString("monitor.network.download"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Text(formatSpeed(downloadSpeed))
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .contentTransition(.numericText())
                }
                
                Spacer()
            }
            
 // 分隔线
            Divider()
            
 // 统计信息
            VStack(spacing: 12) {
 // 总流量
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizationManager.shared.localizedString("monitor.network.totalUpload"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(formatBytes(totalUploaded))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(LocalizationManager.shared.localizedString("monitor.network.totalDownload"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(formatBytes(totalDownloaded))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                    }
                }
                
 // 连接数
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizationManager.shared.localizedString("monitor.network.activeConnections"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("\(connectionCount)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                    
                    Spacer()
                    
 // 网络质量指示器
                    networkQualityIndicator
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 0.5)
        }
        .onAppear {
            startAnimations()
        }
        .onChange(of: uploadSpeed) { _, _ in
            triggerUploadAnimation()
        }
        .onChange(of: downloadSpeed) { _, _ in
            triggerDownloadAnimation()
        }
    }
    
 // MARK: - 网络质量指示器
    
    private var networkQualityIndicator: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(LocalizationManager.shared.localizedString("monitor.network.quality"))
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 2) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(signalBarColor(for: index))
                        .frame(width: 3, height: CGFloat(4 + index * 2))
                        .animation(.easeInOut(duration: 0.3).delay(Double(index) * 0.1), value: networkQuality)
                }
            }
        }
    }
    
 // MARK: - 计算属性
    
    private var networkQuality: Int {
        let totalSpeed = uploadSpeed + downloadSpeed
        
        if totalSpeed > 10 * 1024 * 1024 { // > 10MB/s
            return 4
        } else if totalSpeed > 5 * 1024 * 1024 { // > 5MB/s
            return 3
        } else if totalSpeed > 1024 * 1024 { // > 1MB/s
            return 2
        } else if totalSpeed > 0 {
            return 1
        } else {
            return 0
        }
    }
    
 // MARK: - 私有方法
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        
        let formattedSize = formatter.string(fromByteCount: Int64(bytesPerSecond))
        return "\(formattedSize)/s"
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        
        return formatter.string(fromByteCount: bytes)
    }
    
    private func signalBarColor(for index: Int) -> Color {
        if index < networkQuality {
            switch networkQuality {
            case 4:
                return .green
            case 3:
                return .yellow
            case 2:
                return .orange
            case 1:
                return .red
            default:
                return .gray.opacity(0.3)
            }
        } else {
            return .gray.opacity(0.3)
        }
    }
    
    private func startAnimations() {
        if isConnected {
            animateUpload = true
            animateDownload = true
        }
        isUploadPulseInFlight = false
        isDownloadPulseInFlight = false
    }
    
    private func triggerUploadAnimation() {
        guard !isUploadPulseInFlight else { return }
        isUploadPulseInFlight = true
        withAnimation(.easeInOut(duration: 0.3)) {
            animateUpload = false
        }
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            withAnimation(.easeInOut(duration: 0.3)) {
                animateUpload = true
            }
            isUploadPulseInFlight = false
        }
    }
    
    private func triggerDownloadAnimation() {
        guard !isDownloadPulseInFlight else { return }
        isDownloadPulseInFlight = true
        withAnimation(.easeInOut(duration: 0.3)) {
            animateDownload = false
        }
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            withAnimation(.easeInOut(duration: 0.3)) {
                animateDownload = true
            }
            isDownloadPulseInFlight = false
        }
    }
}

// MARK: - 预览

@available(macOS 14.0, *)
struct NetworkMonitorCard_Previews: PreviewProvider {
    static var previews: some View {
        NetworkMonitorCard(
            uploadSpeed: 45.2 * 1024,
            downloadSpeed: 125.5 * 1024,
            totalUploaded: 1024 * 1024 * 100,
            totalDownloaded: 1024 * 1024 * 500,
            connectionCount: 12,
            isConnected: true
        )
        .frame(width: 300, height: 200)
        .previewDisplayName("连接状态")
        
        NetworkMonitorCard(
            uploadSpeed: 0,
            downloadSpeed: 0,
            totalUploaded: 0,
            totalDownloaded: 0,
            connectionCount: 0,
            isConnected: false
        )
        .frame(width: 300, height: 200)
        .previewDisplayName("断开状态")
        
        NetworkMonitorCard(
            uploadSpeed: 10 * 1024,
            downloadSpeed: 50 * 1024,
            totalUploaded: 1024 * 1024 * 10,
            totalDownloaded: 1024 * 1024 * 50,
            connectionCount: 3,
            isConnected: true
        )
        .frame(width: 300, height: 200)
        .previewDisplayName("连接中状态")
        
        NetworkMonitorCard(
            uploadSpeed: 0,
            downloadSpeed: 0,
            totalUploaded: 0,
            totalDownloaded: 0,
            connectionCount: 0,
            isConnected: false
        )
        .frame(width: 300, height: 200)
        .previewDisplayName("错误状态")
    }
}
