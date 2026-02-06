import SwiftUI
import UniformTypeIdentifiers

/// 文件传输视图 - 与 Files app 集成，支持拖放和分享
@available(iOS 17.0, *)
struct FileTransferView: View {
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var fileTransferManager = FileTransferManager.instance
    @StateObject private var settings = SettingsManager.instance
    @StateObject private var crossNetwork = CrossNetworkWebRTCManager.instance
    
    @State private var showFilePicker = false
    @State private var targetDevice: DiscoveredDevice?
    
    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient

                if !settings.enableExperimentalFeatures {
                    VStack {
                        BetaBannerView(
                            title: "文件传输（实验功能）",
                            message: "当前实现支持分块/校验/可选压缩。发布前建议与 macOS 端做一次双向互通冒烟测试（同网段发现→连接→发送/接收）。"
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        Spacer()
                    }
                }
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 快速发送区域
                        quickSendSection
                        
                        // 正在传输的文件
                        if !fileTransferManager.activeTransfers.isEmpty {
                            activeTransfersSection
                        }
                        
                        // 传输历史
                        transferHistorySection
                    }
                    .padding()
                }
            }
            .navigationTitle("文件传输")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result)
            }
        }
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.05, blue: 0.15),
                Color(red: 0.1, green: 0.1, blue: 0.2)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    // MARK: - Quick Send Section
    
    private var quickSendSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("快速发送")
                .font(.headline)
                .foregroundColor(.white)

            Text("接收目录：\(fileTransferManager.getDownloadsDirectory().path)")
                .font(.caption)
                .foregroundColor(.gray)
                .lineLimit(1)
            
            // 在线设备列表
            let hasCrossNetwork: Bool = {
                if case .connected = crossNetwork.state { return true }
                return false
            }()
            
            if connectionManager.activeConnections.isEmpty && !hasCrossNetwork {
                emptyDeviceState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if hasCrossNetwork {
                            let id = crossNetwork.remoteDeviceId ?? "webrtc-remote"
                            let name = crossNetwork.remoteDeviceName ?? "跨网设备"
                            let pseudo = DiscoveredDevice(
                                id: id,
                                name: name,
                                modelName: "Remote",
                                platform: .macOS,
                                osVersion: "",
                                ipAddress: nil,
                                services: [],
                                portMap: [:],
                                signalStrength: -50,
                                lastSeen: Date(),
                                isConnected: true,
                                isTrusted: true,
                                publicKey: nil,
                                advertisedCapabilities: ["file_transfer"],
                                capabilities: ["file_transfer"]
                            )
                            DeviceQuickSendCard(
                                device: pseudo,
                                onTap: {
                                    targetDevice = pseudo
                                    showFilePicker = true
                                }
                            )
                        }
                        ForEach(connectionManager.activeConnections) { connection in
                            DeviceQuickSendCard(
                                device: connection.device,
                                onTap: {
                                    targetDevice = connection.device
                                    showFilePicker = true
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(white: 0.15))
        .cornerRadius(16)
    }
    
    private var emptyDeviceState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.title)
                .foregroundColor(.gray)
            
            Text("没有连接的设备")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            Text("请先在\"发现\"页面连接设备")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - Active Transfers Section
    
    private var activeTransfersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("正在传输")
                .font(.headline)
                .foregroundColor(.white)
            
            ForEach(fileTransferManager.activeTransfers) { transfer in
                FileTransferCard(transfer: transfer)
            }
        }
        .padding()
        .background(Color(white: 0.15))
        .cornerRadius(16)
    }
    
    // MARK: - Transfer History Section
    
    private var transferHistorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("传输历史")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: clearHistory) {
                    Text("清空")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            if fileTransferManager.transferHistory.isEmpty {
                Text("暂无传输记录")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ForEach(fileTransferManager.transferHistory) { transfer in
                    FileTransferHistoryCard(transfer: transfer)
                }
            }
        }
        .padding()
        .background(Color(white: 0.15))
        .cornerRadius(16)
    }
    
    // MARK: - Actions
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            sendFiles(urls)
            
        case .failure(let error):
            SkyBridgeLogger.shared.error("❌ 文件选择失败: \(error.localizedDescription)")
        }
    }
    
    private func sendFiles(_ urls: [URL]) {
        guard let device = targetDevice else {
            SkyBridgeLogger.shared.warning("⚠️ 未选择目标设备")
            return
        }
        
        Task {
            for url in urls {
                do {
                    try await fileTransferManager.sendFile(
                        at: url,
                        to: device
                    )
                    SkyBridgeLogger.shared.info("📤 开始发送: \(url.lastPathComponent)")
                } catch {
                    SkyBridgeLogger.shared.error("❌ 发送失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func clearHistory() {
        fileTransferManager.clearHistory()
    }
}

// MARK: - Device Quick Send Card

struct DeviceQuickSendCard: View {
    let device: DiscoveredDevice
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: device.platform.iconName)
                    .font(.title)
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        LinearGradient(
                            colors: device.platform.gradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(12)
                
                Text(device.name)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(width: 80)
        }
    }
}

// MARK: - File Transfer Card

struct FileTransferCard: View {
    let transfer: FileTransfer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // 文件图标
                Image(systemName: fileIcon)
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(8)
                
                // 文件信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.fileName)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Text(formatFileSize(transfer.fileSize))
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // 状态
                statusBadge
            }
            
            // 进度条
            if transfer.status == .transferring {
                VStack(spacing: 4) {
                    ProgressView(value: transfer.progress)
                        .tint(.blue)
                    
                    HStack {
                        Text("\(Int(transfer.progress * 100))%")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Spacer()
                        
                        Text(formatSpeed(transfer.speed))
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }

            if transfer.isIncoming, let locationText {
                Text("保存位置：\(locationText)")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .padding()
        .background(Color(white: 0.1))
        .cornerRadius(12)
    }
    
    private var fileIcon: String {
        switch transfer.fileType {
        case .image: return "photo.fill"
        case .video: return "video.fill"
        case .audio: return "music.note"
        case .document: return "doc.fill"
        case .archive: return "archivebox.fill"
        default: return "doc.fill"
        }
    }
    
    private var statusBadge: some View {
        Group {
            switch transfer.status {
            case .pending:
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
                
            case .transferring:
                ProgressView()
                    .tint(.blue)
                
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
        .font(.title3)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    private var locationText: String? {
        guard let localPath = transfer.localPath else { return nil }
        let url = URL(fileURLWithPath: localPath)
        return "Downloads/\(url.lastPathComponent)"
    }
}

// MARK: - File Transfer History Card

struct FileTransferHistoryCard: View {
    let transfer: FileTransfer
    @Environment(\.openURL) private var openURL

    private var relativeTimestampText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: transfer.timestamp, relativeTo: Date())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: transfer.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(transfer.isIncoming ? .green : .blue)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.fileName)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        Text(transfer.isIncoming ? "来自" : "发送至")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Text(transfer.remotePeer)
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Text("•")
                            .foregroundColor(.gray)
                        
                        Text(relativeTimestampText)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                Spacer()
                
                Text(ByteCountFormatter.string(fromByteCount: transfer.fileSize, countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if transfer.isIncoming, let localPath = transfer.localPath {
                HStack(spacing: 8) {
                    Text("保存位置：\(displayLocation(path: localPath))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    Spacer()
                    Button("打开") {
                        openURL(URL(fileURLWithPath: localPath))
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding()
        .background(Color(white: 0.1))
        .cornerRadius(12)
    }

    private func displayLocation(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return "Downloads/\(url.lastPathComponent)"
    }
}

// MARK: - Preview
#if DEBUG
struct FileTransferView_Previews: PreviewProvider {
    static var previews: some View {
        FileTransferView()
            .environmentObject(P2PConnectionManager.instance)
    }
}
#endif
