import SwiftUI
import UniformTypeIdentifiers
import SkyBridgeCore
import CoreImage.CIFilterBuiltins
import AVKit

/// 文件传输界面 - 符合Apple官方设计的现代化文件传输体验
public struct FileTransferView: View {

 // MARK: - 状态管理
    @StateObject private var fileTransferManager = FileTransferManager.shared
    @StateObject private var crossNetworkManager = CrossNetworkConnectionManager.shared
    @State private var selectedTab = 0
    @State private var selectedFiles: [URL] = []
    @State private var allowMultipleFiles = true
    @State private var showingQRCode = false
    @State private var dragOver = false
    @State private var qrCodeString = ""
    @State private var showingMediaPreview = false
    @State private var previewingFile: URL?
 // 调试面板：记录最近一次整文件HMAC与签名校验结果
    @State private var lastHmacTagHex: String = ""
    @State private var lastSignatureOk: Bool = false
    @State private var lastSigTransferId: String = ""

 // 威胁警报状态 - Requirements: 4.3
    @State private var showingThreatAlert = false
    @State private var threatAlertResult: FileScanResult?


    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
 // 侧边栏 - 设备和连接
            sidebarContent

 // 主内容区域
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("fileHmacTagReported"))) { note in
            if let info = note.userInfo, let hex = info["hmacTagHex"] as? String, let tid = info["transferId"] as? String {
                lastHmacTagHex = hex
                lastSigTransferId = tid
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("fileSignatureVerified"))) { note in
            if let info = note.userInfo, let ok = info["ok"] as? Bool, let tid = info["transferId"] as? String {
                lastSignatureOk = ok
                lastSigTransferId = tid
            }
        }
 // 顶部不再显示“二维码/齿轮”按钮，设置入口保留在“设置”标签
        .sheet(isPresented: $showingMediaPreview) {
            if let previewFile = previewingFile {
                MediaPreviewView(fileURL: previewFile)
            }
        }
 // 威胁警报对话框 - Requirements: 4.3
        .sheet(isPresented: $showingThreatAlert) {
            if let result = threatAlertResult {
                ThreatAlertDialog(
                    result: result,
                    onDelete: {
                        handleThreatAction(.delete, for: result)
                    },
                    onQuarantine: {
                        handleThreatAction(.quarantine, for: result)
                    },
                    onIgnore: {
                        handleThreatAction(.ignore, for: result)
                    }
                )
            }
        }
 // 监听威胁检测通知
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FileScanThreatDetected"))) { note in
            if let info = note.userInfo,
               let result = info["scanResult"] as? FileScanResult,
               result.verdict == .unsafe {
                threatAlertResult = result
                showingThreatAlert = true
            }
        }
    }

 // MARK: - 侧边栏内容
    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionStatusCard
            Divider().opacity(0.6).blendMode(.overlay)
            quickActionsCard
            Divider().opacity(0.6).blendMode(.overlay)
            recentTransfersCard
            Spacer()
        }
        .tahoeLiquidGlassCard()
        .frame(width: 240)
    }

 // MARK: - 主内容区域
    private var mainContent: some View {
        VStack(spacing: 0) {
 // 现代化标签栏
            modernTabBar

 // 主要内容
            TabView(selection: $selectedTab) {
                modernFileTransferTab
                    .tag(0)

                enhancedTransferHistoryTab
                    .tag(1)
            }
            .tabViewStyle(.automatic)
        }
    }

 // MARK: - 连接状态卡片
    private var connectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wifi.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
                Text(LocalizationManager.shared.localizedString("fileTransfer.connectionStatus"))
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            HStack {
                Circle()
                    .fill(fileTransferManager.isTransferring ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                    .scaleEffect(fileTransferManager.isTransferring ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: fileTransferManager.isTransferring)

                Text(LocalizationManager.shared.localizedString(fileTransferManager.isTransferring ? "status.transferring" : "status.idle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.3), value: fileTransferManager.isTransferring)
            }

            if fileTransferManager.isTransferring {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizationManager.shared.localizedString("fileTransfer.totalProgress"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(fileTransferManager.totalProgress * 100))%")
                            .font(.caption)
                            .fontWeight(.medium)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: fileTransferManager.totalProgress)
                    }

                    ProgressView(value: fileTransferManager.totalProgress)
                        .tint(.blue)
                        .animation(.easeInOut(duration: 0.5), value: fileTransferManager.totalProgress)
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: fileTransferManager.isTransferring)
    }

 // MARK: - 快速操作卡片
    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizationManager.shared.localizedString("fileTransfer.quickActions"))
                .font(.headline)
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                Button(action: selectFiles) {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.blue)
                        Text(LocalizationManager.shared.localizedString("action.selectFiles"))
                            .fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Divider()

                Button(action: selectFolder) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                            .foregroundColor(.orange)
                        Text(LocalizationManager.shared.localizedString("action.selectFolder"))
                            .fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Divider()

                Button(action: {
                    generateQRCode()
                    showingQRCode = true
                }) {
                    HStack {
                        Image(systemName: "qrcode")
                            .foregroundColor(.green)
                        Text(LocalizationManager.shared.localizedString("connection.generateQR"))
                            .fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

 // MARK: - 最近传输卡片
    private var recentTransfersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizationManager.shared.localizedString("fileTransfer.recentTransfers"))
                .font(.headline)
                .fontWeight(.semibold)

            let recentTransfers = Array(fileTransferManager.transferHistory.prefix(3))
            if recentTransfers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundColor(.gray)
                    Text(LocalizationManager.shared.localizedString("fileTransfer.recent.empty"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(recentTransfers) { transfer in
                        CompactTransferRowView(transfer: transfer)
                    }
                }
            }
        }
    }

 // MARK: - 现代化标签栏
    private var modernTabBar: some View {
        HStack(spacing: 0) {
            ModernTabButton(
                title: LocalizationManager.shared.localizedString("fileTransfer.tab.transfer"),
                icon: "arrow.up.arrow.down.circle",
                isSelected: selectedTab == 0
            ) {
                selectedTab = 0
            }

            ModernTabButton(
                title: LocalizationManager.shared.localizedString("fileTransfer.tab.history"),
                icon: "clock.arrow.circlepath",
                isSelected: selectedTab == 1
            ) {
                selectedTab = 1
            }
        }
        .padding(.horizontal)
        .background(.thinMaterial)
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

 // MARK: - 现代化文件传输标签页
    private var modernFileTransferTab: some View {
        ScrollView {
            VStack(spacing: 24) {
 // 拖拽区域
                modernDropZone

 // 选中的文件
                if !selectedFiles.isEmpty {
                    selectedFilesSection
                        .tahoeLiquidGlassCard()
                }

 // 活跃传输
                activeTransfersSection
            }
            .padding()
        }
    }

 // MARK: - 现代化拖拽区域
    private var modernDropZone: some View {
        VStack(spacing: 20) {
            Image(systemName: dragOver ? "plus.circle.fill" : "plus.circle.dashed")
                .font(.system(size: 64))
                .foregroundColor(dragOver ? .blue : .gray)
                .animation(.easeInOut(duration: 0.2), value: dragOver)

            VStack(spacing: 8) {
                Text(LocalizationManager.shared.localizedString("fileTransfer.drop.title"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(LocalizationManager.shared.localizedString("fileTransfer.drop.subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Button(LocalizationManager.shared.localizedString("action.selectFiles")) {
                    selectFiles()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(LocalizationManager.shared.localizedString("action.selectFolder")) {
                    selectFolder()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 200)
        .padding(40)
        .tahoeLiquidGlassCard()
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            handleFileDrop(providers: providers)
        }
    }

 // MARK: - 选中文件区域
    private var selectedFilesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(LocalizationManager.shared.localizedString("fileTransfer.selectedFiles"))
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("(\(selectedFiles.count))")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Spacer()

                Button(LocalizationManager.shared.localizedString("action.sendAll")) {
                    sendSelectedFiles()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty)

                Button(LocalizationManager.shared.localizedString("action.clear")) {
                    selectedFiles.removeAll()
                }
                .buttonStyle(.bordered)
            }

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 300), spacing: 16)
            ], spacing: 16) {
                ForEach(selectedFiles, id: \.self) { fileURL in
                    ModernFileCard(fileURL: fileURL) {
                        selectedFiles.removeAll { $0 == fileURL }
                    } onPreview: {
                        previewingFile = fileURL
                        showingMediaPreview = true
                    }
                }
            }
        }
        .padding()
    }

 // MARK: - 活跃传输区域
    private var activeTransfersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizationManager.shared.localizedString("fileTransfer.activeTransfers"))
                .font(.title3)
                .fontWeight(.semibold)

            if fileTransferManager.activeTransfers.isEmpty {
                EmptyStateView(
                    title: LocalizationManager.shared.localizedString("fileTransfer.active.emptyTitle"),
                    subtitle: LocalizationManager.shared.localizedString("fileTransfer.active.emptySubtitle"),
                    systemImage: "arrow.up.arrow.down.circle"
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(Array(fileTransferManager.activeTransfers.values), id: \.id) { transfer in
                        ModernTransferRowView(transfer: transfer) {
 // cancelTransfer 是同步方法，不需要 await
                            fileTransferManager.cancelTransfer(transfer.id)
                        }
                    }
                }
            }
        }
        .tahoeLiquidGlassCard()
    }

 // MARK: - 增强的传输历史标签页
    private var enhancedTransferHistoryTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(LocalizationManager.shared.localizedString("fileTransfer.history.title"))
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(LocalizationManager.shared.localizedString("fileTransfer.history.clear")) {
                    fileTransferManager.clearHistory()
                }
                .buttonStyle(.bordered)
                .disabled(fileTransferManager.transferHistory.isEmpty)
            }
            .padding(.horizontal)

            if fileTransferManager.transferHistory.isEmpty {
                EmptyStateView(
                    title: LocalizationManager.shared.localizedString("fileTransfer.history.emptyTitle"),
                    subtitle: LocalizationManager.shared.localizedString("fileTransfer.history.emptySubtitle"),
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(fileTransferManager.transferHistory) { transfer in
                            EnhancedHistoryRowView(transfer: transfer)
                        }
 // 调试面板：整文件 HMAC 与签名校验并排显示
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LocalizationManager.shared.localizedString("fileTransfer.debug.title"))
                                .font(.headline)
                                .fontWeight(.semibold)
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizationManager.shared.localizedString("fileTransfer.debug.hmacTagHex"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(lastHmacTagHex.isEmpty ? LocalizationManager.shared.localizedString("common.none") : lastHmacTagHex)
                                        .font(.system(.footnote, design: .monospaced))
                                        .lineLimit(3)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizationManager.shared.localizedString("fileTransfer.debug.signatureResult"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 6) {
                                        Image(systemName: lastSignatureOk ? "checkmark.seal.fill" : "xmark.seal")
                                            .foregroundColor(lastSignatureOk ? .green : .red)
                                        Text(lastSigTransferId.isEmpty ? LocalizationManager.shared.localizedString("common.none") : lastSigTransferId)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .padding(.horizontal)
                    }
                    .padding(.horizontal)
                }
            }

            Spacer()
        }
    }

 // MARK: - 威胁处理

 /// 威胁处理操作类型
    private enum ThreatAction {
        case delete
        case quarantine
        case ignore
    }

 /// 处理威胁操作 - Requirements: 4.3
    private func handleThreatAction(_ action: ThreatAction, for result: FileScanResult) {
        let fileURL = result.fileURL

        switch action {
        case .delete:
 // 删除文件
            do {
                try FileManager.default.removeItem(at: fileURL)
                SkyBridgeLogger.ui.info("🗑️ 已删除威胁文件: \(fileURL.lastPathComponent)")
            } catch {
                SkyBridgeLogger.ui.error("❌ 删除文件失败: \(error.localizedDescription)")
            }

        case .quarantine:
 // 移动到隔离区
            let fm = FileManager.default
            let quarantineBase = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
            let quarantineDir = quarantineBase.appendingPathComponent("SkyBridge/Quarantine")

            do {
                try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
                let quarantinePath = quarantineDir.appendingPathComponent(fileURL.lastPathComponent)
                try fm.moveItem(at: fileURL, to: quarantinePath)
                SkyBridgeLogger.ui.info("🔒 已隔离威胁文件: \(fileURL.lastPathComponent)")
            } catch {
                SkyBridgeLogger.ui.error("❌ 隔离文件失败: \(error.localizedDescription)")
            }

        case .ignore:
 // 忽略风险，仅记录日志
            SkyBridgeLogger.ui.warning("⚠️ 用户选择忽略威胁: \(fileURL.lastPathComponent)")
        }

 // 关闭警报
        showingThreatAlert = false
        threatAlertResult = nil
    }

 // MARK: - 辅助方法
    private func generateQRCode() {
 // 生成包含传输信息的二维码
        let transferInfo: [String: Any] = [
            "type": "file_transfer",
            "device_id": UUID().uuidString,
            "timestamp": Date().timeIntervalSince1970
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: transferInfo),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            qrCodeString = jsonString
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url {
                        DispatchQueue.main.async {
                            if allowMultipleFiles {
                                selectedFiles.append(url)
                            } else {
                                selectedFiles = [url]
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowMultipleFiles
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            selectedFiles.append(contentsOf: panel.urls)
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            selectedFiles.append(url)
        }
    }

    private func sendSelectedFiles() {
        Task { @MainActor in
            for fileURL in selectedFiles {
                do {
                    // 1. Prefer Cross-Network (WebRTC DataChannel) when available.
                    if case .connected = crossNetworkManager.connectionStatus,
                       let conn = crossNetworkManager.currentConnection,
                       case .webrtc = conn.transport {
                        try await crossNetworkManager.sendFileToConnectedPeer(fileURL)
                        continue
                    }
                    
                    // 2. Try Local P2P (Bonjour/IP) via FileTransferManager internal resolution
                    // This handles active peer lookup and throws if no connection exists.
                    try await fileTransferManager.sendFileToFirstActivePeer(at: fileURL)
                    continue
                } catch {
                    SkyBridgeLogger.ui.error("传输失败: \(error.localizedDescription, privacy: .private)")
                }
            }
            selectedFiles.removeAll()
        }
    }

    private func fileIcon(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()

        switch pathExtension {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "wmv":
            return "video"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx":
            return "doc.text"
        case "xls", "xlsx":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.on.rectangle"
        case "zip", "rar", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 支持组件

private struct ModernTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundColor(isSelected ? .blue : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .background(
            Rectangle()
                .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        )
        .overlay(
            Rectangle()
                .frame(height: 3)
                .foregroundColor(isSelected ? .blue : .clear),
            alignment: .bottom
        )
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

private struct ModernFileCard: View {
    let fileURL: URL
    let onRemove: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
 // 文件图标
            Image(systemName: fileIcon(for: fileURL))
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

 // 文件信息
            VStack(alignment: .leading, spacing: 4) {
                Text(fileURL.lastPathComponent)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    Text(formatFileSize(Int64(fileSize)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

 // 操作按钮
            HStack(spacing: 8) {
                if isMediaFile(fileURL) {
                    Button(action: onPreview) {
                        HStack {
                            Image(systemName: "play.circle")
                            Text(LocalizationManager.shared.localizedString("action.preview"))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
    }

    private func fileIcon(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()

        switch pathExtension {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "wmv":
            return "video"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }

    private func isMediaFile(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        let mediaExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "heic", "mp4", "mov", "avi", "mkv", "wmv", "mp3", "wav", "aac", "flac", "m4a"]
        return mediaExtensions.contains(pathExtension)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct ModernTransferRowView: View {
    let transfer: FileTransfer
    let onCancel: () -> Void
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
 // 传输方向图标
                Image(systemName: transfer.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(transfer.direction == .outgoing ? .blue : .green)
                    .font(.title2)
                    .scaleEffect(isAnimating && transfer.status == .transferring ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isAnimating)

 // 文件信息
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.fileName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(formatFileSize(transfer.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

 // 状态和进度
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(transfer.progress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .contentTransition(.numericText())

                    Text(transfer.status.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

 // 取消按钮
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }

 // 进度条 - 优化动画和响应性
            ProgressView(value: transfer.progress)
                .tint(.blue)
                .animation(.easeInOut(duration: 0.3), value: transfer.progress)
        }
        .padding()
        .onAppear {
            if transfer.status == .transferring {
                isAnimating = true
            }
        }
        .onChange(of: transfer.status) { _, newStatus in
            withAnimation {
                isAnimating = newStatus == .transferring
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct CompactTransferRowView: View {
    let transfer: FileTransfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(transfer.status == .completed ? .green : .red)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.fileName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let completedAt = transfer.completedAt {
                    Text(formatDate(completedAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct EnhancedHistoryRowView: View {
    let transfer: FileTransfer
    @State private var showingScanDetails = false

    var body: some View {
        HStack(spacing: 12) {
 // 状态图标
            Image(systemName: transfer.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(transfer.status == .completed ? .green : .red)
                .font(.title2)

 // 文件信息
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.fileName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack {
                    Text(formatFileSize(transfer.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let completedAt = transfer.completedAt {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(formatDate(completedAt))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Show saved path for inbound completed transfers so the user can locate the file easily.
                if transfer.direction == .incoming,
                   transfer.status == .completed,
                   let url = transfer.localPath {
                    Text(url.path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

 // 扫描结果摘要 - Requirements: 4.2, 7.2
            if let scanResult = transfer.scanResult {
                Button {
                    showingScanDetails = true
                } label: {
                    HStack(spacing: 4) {
                        scanVerdictIcon(scanResult.verdict)
                            .font(.caption)

                        if !scanResult.warnings.isEmpty {
                            Text("(\(scanResult.warnings.count))")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }

 // 扫描时长
                        Text(formatScanDuration(scanResult.scanDuration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(scanVerdictBackground(scanResult.verdict), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Reveal received file in Finder (macOS only).
            #if os(macOS)
            if transfer.direction == .incoming,
               transfer.status == .completed,
               let url = transfer.localPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示")
            }
            #endif

 // 传输方向
            Image(systemName: transfer.direction == .outgoing ? "arrow.up" : "arrow.down")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .sheet(isPresented: $showingScanDetails) {
            if let scanResult = transfer.scanResult {
                ScanDetailSheet(result: scanResult)
            }
        }
    }

    private func scanVerdictIcon(_ verdict: ScanVerdict) -> some View {
        Group {
            switch verdict {
            case .safe:
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
            case .warning:
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
            case .unsafe:
                Image(systemName: "xmark.shield.fill")
                    .foregroundColor(.red)
            case .unknown:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.gray)
            }
        }
    }

    private func scanVerdictBackground(_ verdict: ScanVerdict) -> Color {
        switch verdict {
        case .safe:
            return .green.opacity(0.15)
        case .warning:
            return .orange.opacity(0.15)
        case .unsafe:
            return .red.opacity(0.15)
        case .unknown:
            return .gray.opacity(0.15)
        }
    }

    private func formatScanDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.1fs", duration)
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct ModernSettingCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .font(.title3)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            content
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct ModernToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundColor(.gray)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}



// MARK: - 枚举和扩展

@MainActor
enum TransferSpeed: CaseIterable {
    case slow, normal, fast

    var displayName: String {
        switch self {
        case .slow: return LocalizationManager.shared.localizedString("transferSpeed.slow")
        case .normal: return LocalizationManager.shared.localizedString("transferSpeed.normal")
        case .fast: return LocalizationManager.shared.localizedString("transferSpeed.fast")
        }
    }
}

@MainActor
extension TransferStatus {
    var displayName: String {
        switch self {
        case .preparing:
            return LocalizationManager.shared.localizedString("transferStatus.preparing")
        case .transferring:
            return LocalizationManager.shared.localizedString("transferStatus.transferring")
        case .paused:
            return LocalizationManager.shared.localizedString("transferStatus.paused")
        case .completed:
            return LocalizationManager.shared.localizedString("transferStatus.completed")
        case .failed:
            return LocalizationManager.shared.localizedString("transferStatus.failed")
        case .cancelled:
            return LocalizationManager.shared.localizedString("transferStatus.cancelled")
        }
    }
}

private struct TahoeLiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                content
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .clipShape(shape)
                    .overlay(
                        shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
            } else {
                content
                    .padding(20)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
        }
    }
}

private extension View {
    func tahoeLiquidGlassCard(cornerRadius: CGFloat = 24) -> some View {
        modifier(TahoeLiquidGlassCardModifier(cornerRadius: cornerRadius))
    }
}

#if DEBUG
struct FileTransferView_Previews: PreviewProvider {
    static var previews: some View {
        FileTransferView()
    }
}
#endif
