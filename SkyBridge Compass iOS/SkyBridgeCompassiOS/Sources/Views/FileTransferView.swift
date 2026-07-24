import SwiftUI
import UniformTypeIdentifiers
import QuickLook
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 17.0, *)
struct FileTransferView: View {
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var fileTransferManager = FileTransferManager.instance
    @StateObject private var crossNetwork = CrossNetworkWebRTCManager.instance
    
    @State private var showFilePicker = false
    @State private var targetDevice: DiscoveredDevice?
    @State private var previewItem: FilePreviewItem?
    @State private var shareItem: FilePreviewItem?
    @State private var fileOpenErrorMessage: String?

#if DEBUG || SKYBRIDGE_TESTING
    private var isUITestFilesScenario: Bool {
        ProcessInfo.processInfo.arguments.contains("UITEST_SCENARIO_FILES")
    }
#endif
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    quickSendSection
                    
                    if !fileTransferManager.activeTransfers.isEmpty {
                        activeTransfersSection
                    }
                    
                    transferHistorySection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(DashboardView.QuantumGlassBackground())
            .accessibilityIdentifier("files.root")
            .scrollContentBackground(.hidden)
            .navigationTitle(RuntimeLocalization.string("文件传输"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
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
            .sheet(item: $previewItem) { item in
                FileQuickLookPreview(url: item.url)
            }
            .sheet(item: $shareItem) { item in
                FileShareSheet(items: [item.url])
            }
            .alert(RuntimeLocalization.string("无法打开文件"), isPresented: Binding(
                get: { fileOpenErrorMessage != nil },
                set: { if !$0 { fileOpenErrorMessage = nil } }
            )) {
                Button(RuntimeLocalization.string("好的"), role: .cancel) { fileOpenErrorMessage = nil }
            } message: {
                Text(fileOpenErrorMessage ?? RuntimeLocalization.string("未知错误"))
            }
        }
    }
    
    // MARK: - Quick Send Section
    
    private var quickSendSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.cyan)
                Text(RuntimeLocalization.string("快速发送"))
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text(
                String(
                    format: RuntimeLocalization.string("接收目录：%@"),
                    fileTransferManager.getDownloadsDirectory().path
                )
            )
            .font(.caption)
            .foregroundColor(.white.opacity(0.4))
            .lineLimit(1)
            
            let hasCrossNetwork: Bool = {
                if case .connected = crossNetwork.state { return true }
                return false
            }()
            
            if lanQuickSendDevices.isEmpty && !hasCrossNetwork {
                emptyDeviceState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if hasCrossNetwork {
                            let id = crossNetwork.remoteDeviceId ?? "webrtc-remote"
                            let name = crossNetwork.remoteDeviceName ?? RuntimeLocalization.string("跨网设备")
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
                                    handleQuickSendTargetSelection(pseudo)
                                }
                            )
                        }
                        ForEach(lanQuickSendDevices, id: \.id) { device in
                            DeviceQuickSendCard(
                                device: device,
                                onTap: {
                                    handleQuickSendTargetSelection(device)
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .accessibilityIdentifier("files.quickSend.section")
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
    }

    private var lanQuickSendDevices: [DiscoveredDevice] {
        var seen: Set<String> = []
        var devices: [DiscoveredDevice] = []

        for connection in connectionManager.activeConnections {
            let resolved = fileTransferManager.preferredQuickSendDevice(
                for: connectionManager.resolvedPeerDevice(for: connection.device)
            )
            let key = resolved.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if seen.insert(key).inserted {
                devices.append(resolved)
            }
        }

        return devices
    }
    
    private var emptyDeviceState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.title2)
                .foregroundColor(.white.opacity(0.3))
            
            Text(RuntimeLocalization.string("没有连接的设备"))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
            
            Text(RuntimeLocalization.string("请先在发现页面连接设备"))
                .font(.caption)
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
    
    // MARK: - Active Transfers Section
    
    private var activeTransfersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("files.active.ready")
                .accessibilityIdentifier("files.active.ready")

            HStack {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(.green)
                Text(RuntimeLocalization.string("正在传输"))
                    .font(.headline)
                    .foregroundColor(.white)
            }
            
            ForEach(fileTransferManager.activeTransfers) { transfer in
                FileTransferCard(transfer: transfer)
            }
        }
        .padding(16)
        .accessibilityIdentifier("files.active.section")
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LinearGradient(colors: [.green.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
    }
    
    // MARK: - Transfer History Section
    
    private var transferHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.white.opacity(0.5))
                Text(RuntimeLocalization.string("传输历史"))
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: clearHistory) {
                    Text(RuntimeLocalization.string("清空"))
                        .font(.caption)
                        .foregroundColor(.cyan)
                }
            }
            
            if fileTransferManager.transferHistory.isEmpty {
                Text(RuntimeLocalization.string("暂无传输记录"))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("files.history.ready")
                    .accessibilityIdentifier("files.history.ready")

                ForEach(fileTransferManager.transferHistory) { transfer in
                    FileTransferHistoryCard(
                        transfer: transfer,
                        onOpenFile: openLocalFile,
                        onShareFile: shareLocalFile
                    )
                }
            }
        }
        .padding(16)
        .accessibilityIdentifier("files.history.section")
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.15), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
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

    private func handleQuickSendTargetSelection(_ device: DiscoveredDevice) {
        targetDevice = device
#if DEBUG || SKYBRIDGE_TESTING
        if isUITestFilesScenario {
            fileTransferManager.performUITestQuickSend(to: device)
            return
        }
#endif
        showFilePicker = true
    }

    private func openLocalFile(_ transfer: FileTransfer) {
        Task { @MainActor in
            do {
                guard let resolvedURL = try await fileTransferManager.resolveExistingLocalFileURL(for: transfer) else {
                    fileOpenErrorMessage = String(
                        format: RuntimeLocalization.string("文件不存在，可能已被删除。\n路径：%@"),
                        transfer.localPath ?? "Downloads/\(transfer.fileName)"
                    )
                    return
                }
                previewItem = FilePreviewItem(url: resolvedURL)
            } catch {
                fileOpenErrorMessage = RuntimeLocalization.string("文件路径检查失败，请稍后重试。")
            }
        }
    }

    private func shareLocalFile(_ transfer: FileTransfer) {
        Task { @MainActor in
            do {
                guard let resolvedURL = try await fileTransferManager.resolveExistingLocalFileURL(for: transfer) else {
                    fileOpenErrorMessage = String(
                        format: RuntimeLocalization.string("文件不存在，可能已被删除。\n路径：%@"),
                        transfer.localPath ?? "Downloads/\(transfer.fileName)"
                    )
                    return
                }
                shareItem = FilePreviewItem(url: resolvedURL)
            } catch {
                fileOpenErrorMessage = RuntimeLocalization.string("文件路径检查失败，请稍后重试。")
            }
        }
    }
}

// MARK: - Device Quick Send Card

struct DeviceQuickSendCard: View {
    let device: DiscoveredDevice
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 56, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        )
                    
                    Image(systemName: device.platform.iconName)
                        .font(.system(size: 22))
                        .foregroundStyle(
                            LinearGradient(colors: device.platform.gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }
                
                Text(device.name)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("files.quickSend.\(device.id)")
    }
}

// MARK: - File Transfer Card

struct FileTransferCard: View {
    let transfer: FileTransfer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    
                    Image(systemName: fileIcon)
                        .font(.system(size: 16))
                        .foregroundColor(iconColor)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.fileName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Text(formatFileSize(transfer.fileSize))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Spacer()
                
                statusBadge
            }
            
            if transfer.status == .transferring {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 5)
                            
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [transfer.isIncoming ? .green : .blue, .cyan],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * CGFloat(transfer.progress)), height: 5)
                                .shadow(color: .cyan.opacity(0.4), radius: 2, x: 0, y: 0)
                        }
                    }
                    .frame(height: 5)
                    
                    HStack {
                        Text("\(Int(transfer.progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white.opacity(0.5))
                        
                        Spacer()
                        
                        Text(formatSpeed(transfer.speed))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }

            if transfer.isIncoming, let locationText {
                Text(String(format: RuntimeLocalization.string("保存位置：%@"), locationText))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }

            if transfer.receiptDeliveryStatus == .unknown {
                Text(RuntimeLocalization.string("fileTransfer.receiptDeliveryUnknown"))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            if transfer.operationalWarning == .committedFileReleaseFailed {
                Text(RuntimeLocalization.string("fileTransfer.committedFileReleaseFailed"))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files.active.\(transfer.id)")
    }
    
    private var iconColor: Color {
        switch transfer.status {
        case .transferring: return .cyan
        case .completed: return .green
        case .failed: return .red
        default: return .orange
        }
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
                    .tint(.cyan)
                    .scaleEffect(0.8)
            case .completed:
                Image(systemName: transfer.receiptDeliveryStatus == .unknown
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill")
                    .foregroundColor(transfer.receiptDeliveryStatus == .unknown ? .orange : .green)
            case .failed:
                Image(systemName: transfer.receiptDeliveryStatus == .unknown
                    ? "exclamationmark.triangle.fill"
                    : "xmark.circle.fill")
                    .foregroundColor(transfer.receiptDeliveryStatus == .unknown ? .orange : .red)
            }
        }
        .font(.body)
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
    let onOpenFile: (FileTransfer) -> Void
    let onShareFile: (FileTransfer) -> Void

    private var relativeTimestampText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: transfer.timestamp, relativeTo: Date())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: transfer.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundColor(transfer.isIncoming ? .green : .blue)
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.fileName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        Text(
                            transfer.isIncoming
                                ? RuntimeLocalization.string("来自")
                                : RuntimeLocalization.string("发送至")
                        )
                        Text(transfer.remotePeer)
                        Text("·")
                        Text(relativeTimestampText)
                    }
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
                }
                
                Spacer()
                
                Text(ByteCountFormatter.string(fromByteCount: transfer.fileSize, countStyle: .file))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.4))
            }

            if transfer.isIncoming, let localPath = transfer.localPath {
                HStack(spacing: 8) {
                    Text(
                        String(
                            format: RuntimeLocalization.string("保存位置：%@"),
                            displayLocation(path: localPath)
                        )
                    )
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    
                    Spacer()
                    
                    Button(RuntimeLocalization.string("打开")) {
                        onOpenFile(transfer)
                    }
                    .font(.caption2)
                    .foregroundColor(.cyan)
                    .buttonStyle(.borderless)

                    Button(RuntimeLocalization.string("导出")) {
                        onShareFile(transfer)
                    }
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.75))
                    .buttonStyle(.borderless)
                }
            }

            if transfer.receiptDeliveryStatus == .unknown {
                Text(RuntimeLocalization.string("fileTransfer.receiptDeliveryUnknown"))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            if transfer.operationalWarning == .committedFileReleaseFailed {
                Text(RuntimeLocalization.string("fileTransfer.committedFileReleaseFailed"))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files.history.\(transfer.id)")
    }

    private func displayLocation(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return "Downloads/\(url.lastPathComponent)"
    }
}

private struct FilePreviewItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct FileQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct FileShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.excludedActivityTypes = nil
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
