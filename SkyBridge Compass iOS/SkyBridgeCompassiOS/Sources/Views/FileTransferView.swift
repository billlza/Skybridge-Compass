import SwiftUI
import UniformTypeIdentifiers
import QuickLook
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 17.0, *)
private struct FileTransferTargetSelection {
    let device: DiscoveredDevice
    let routeIntent: PeerTransportRouteIntent
}

@available(iOS 17.0, *)
struct FileTransferView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @StateObject private var fileTransferManager = FileTransferManager.instance
    @StateObject private var crossNetwork = CrossNetworkWebRTCManager.instance
    
    @State private var showFilePicker = false
    @State private var targetSelection: FileTransferTargetSelection?
    @State private var previewItem: FilePreviewItem?
    @State private var shareItem: FilePreviewItem?
    @State private var fileActionErrorMessage: String?

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
                    Menu {
                        if let selection = crossNetworkQuickSendSelection {
                            Button(selection.device.name) {
                                handleQuickSendTargetSelection(selection)
                            }
                        }
                        ForEach(lanQuickSendDevices, id: \.id) { device in
                            Button(device.name) {
                                handleQuickSendTargetSelection(
                                    FileTransferTargetSelection(device: device, routeIntent: .directLAN)
                                )
                            }
                        }
                        if lanQuickSendDevices.isEmpty && crossNetworkQuickSendSelection == nil {
                            Text(RuntimeLocalization.string("请先在发现页面连接设备"))
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    .accessibilityLabel(RuntimeLocalization.string("选择接收设备"))
                    .accessibilityIdentifier("files.chooseRecipient")
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
            .alert(RuntimeLocalization.string("文件操作失败"), isPresented: Binding(
                get: { fileActionErrorMessage != nil },
                set: { if !$0 { fileActionErrorMessage = nil } }
            )) {
                Button(RuntimeLocalization.string("好的"), role: .cancel) { fileActionErrorMessage = nil }
            } message: {
                Text(fileActionErrorMessage ?? RuntimeLocalization.string("未知错误"))
            }
        }
    }
    
    // MARK: - Quick Send Section
    
    private var quickSendSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.tint)
                Text(RuntimeLocalization.string("快速发送"))
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Text(
                String(
                    format: RuntimeLocalization.string("接收目录：%@"),
                    fileTransferManager.getDownloadsDirectory().lastPathComponent
                )
            )
            .font(.caption)
            .foregroundStyle(LiquidGlass.supportingText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            
            if lanQuickSendDevices.isEmpty && crossNetworkQuickSendSelection == nil {
                emptyDeviceState
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    quickSendTargets
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        quickSendTargets
                    }
                }
            }
        }
        .padding(16)
        .accessibilityIdentifier("files.quickSend.section")
        .liquidGlassCard(cornerRadius: 20, padding: 0)
    }

    @ViewBuilder
    private var quickSendTargets: some View {
        if let selection = crossNetworkQuickSendSelection {
            DeviceQuickSendCard(device: selection.device) {
                handleQuickSendTargetSelection(selection)
            }
        }
        ForEach(lanQuickSendDevices, id: \.id) { device in
            DeviceQuickSendCard(device: device) {
                handleQuickSendTargetSelection(
                    FileTransferTargetSelection(device: device, routeIntent: .directLAN)
                )
            }
        }
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

    private var crossNetworkQuickSendSelection: FileTransferTargetSelection? {
        guard case .connected(let sessionID) = crossNetwork.state else { return nil }
        let snapshot = crossNetwork.activeSessionSnapshot.flatMap { candidate in
            candidate.sessionId == sessionID ? candidate : nil
        }
        let deviceID = snapshot?.deviceId
            ?? crossNetwork.remoteDeviceId
            ?? "webrtc-\(sessionID)"
        let deviceName = snapshot?.deviceName
            ?? crossNetwork.remoteDeviceName
            ?? RuntimeLocalization.string("跨网设备")
        let device = DiscoveredDevice(
            id: deviceID,
            name: deviceName,
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
        return FileTransferTargetSelection(
            device: device,
            routeIntent: .crossNetwork(sessionID: sessionID)
        )
    }
    
    private var emptyDeviceState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.title2)
                .foregroundStyle(LiquidGlass.supportingText)
            
            Text(RuntimeLocalization.string("没有连接的设备"))
                .font(.subheadline)
                .foregroundStyle(LiquidGlass.supportingText)
            
            Text(RuntimeLocalization.string("请先在发现页面连接设备"))
                .font(.caption)
                .foregroundStyle(LiquidGlass.supportingText)
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
                    .foregroundStyle(.primary)
            }
            
            ForEach(fileTransferManager.activeTransfers) { transfer in
                FileTransferCard(transfer: transfer)
                    .onAppear {
                        fileTransferManager.recordProductFileTransferCompletionVisible(for: transfer)
                    }
                    .onChange(of: transfer.status) { _, _ in
                        fileTransferManager.recordProductFileTransferCompletionVisible(for: transfer)
                    }
            }
        }
        .padding(16)
        .accessibilityIdentifier("files.active.section")
        .liquidGlassCard(cornerRadius: 20, padding: 0)
    }
    
    // MARK: - Transfer History Section
    
    private var transferHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileTransferAdaptiveRow {
                Label {
                    Text(RuntimeLocalization.string("传输历史"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(LiquidGlass.supportingText)
                }
                .fixedSize(horizontal: false, vertical: true)

                if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                Button(action: clearHistory) {
                    Text(RuntimeLocalization.string("清空"))
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            
            if fileTransferManager.transferHistory.isEmpty {
                Text(RuntimeLocalization.string("暂无传输记录"))
                    .font(.subheadline)
                    .foregroundStyle(LiquidGlass.supportingText)
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
                    .onAppear {
                        fileTransferManager.recordProductFileTransferCompletionVisible(for: transfer)
                    }
                    .onChange(of: transfer.status) { _, _ in
                        fileTransferManager.recordProductFileTransferCompletionVisible(for: transfer)
                    }
                }
            }
        }
        .padding(16)
        .accessibilityIdentifier("files.history.section")
        .liquidGlassCard(cornerRadius: 20, padding: 0)
    }
    
    // MARK: - Actions
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            sendFiles(urls)
            
        case .failure(let error):
            SkyBridgeLogger.shared.error("❌ 文件选择失败: \(error.localizedDescription)")
            fileActionErrorMessage = FileTransferErrorFormatter.localizedMessage(for: error)
        }
    }
    
    private func sendFiles(_ urls: [URL]) {
        guard let selection = targetSelection else {
            SkyBridgeLogger.shared.warning("⚠️ 未选择目标设备")
            fileActionErrorMessage = RuntimeLocalization.string("请先选择接收设备，再选择文件。")
            return
        }
        
        Task {
            var failures: [String] = []
            for url in urls {
                do {
                    try await fileTransferManager.sendFile(
                        at: url,
                        to: selection.device,
                        routeIntent: selection.routeIntent
                    )
                    SkyBridgeLogger.shared.info("📤 文件发送完成: \(url.lastPathComponent)")
                } catch {
                    SkyBridgeLogger.shared.error("❌ 发送失败: \(error.localizedDescription)")
                    failures.append("\(url.lastPathComponent): \(FileTransferErrorFormatter.localizedMessage(for: error))")
                }
            }
            if !failures.isEmpty {
                fileActionErrorMessage = failures.joined(separator: "\n")
            }
        }
    }
    
    private func clearHistory() {
        fileTransferManager.clearHistory()
    }

    private func handleQuickSendTargetSelection(_ selection: FileTransferTargetSelection) {
        targetSelection = selection
#if DEBUG || SKYBRIDGE_TESTING
        if isUITestFilesScenario {
            fileTransferManager.performUITestQuickSend(to: selection.device)
            return
        }
#endif
        showFilePicker = true
    }

    private func openLocalFile(_ transfer: FileTransfer) {
        Task { @MainActor in
            do {
                guard let resolvedURL = try await fileTransferManager.resolveExistingLocalFileURL(for: transfer) else {
                    fileActionErrorMessage = String(
                        format: RuntimeLocalization.string("文件不存在，可能已被删除。\n路径：%@"),
                        transfer.localPath ?? "Downloads/\(transfer.fileName)"
                    )
                    return
                }
                previewItem = FilePreviewItem(url: resolvedURL)
            } catch {
                fileActionErrorMessage = RuntimeLocalization.string("文件路径检查失败，请稍后重试。")
            }
        }
    }

    private func shareLocalFile(_ transfer: FileTransfer) {
        Task { @MainActor in
            do {
                guard let resolvedURL = try await fileTransferManager.resolveExistingLocalFileURL(for: transfer) else {
                    fileActionErrorMessage = String(
                        format: RuntimeLocalization.string("文件不存在，可能已被删除。\n路径：%@"),
                        transfer.localPath ?? "Downloads/\(transfer.fileName)"
                    )
                    return
                }
                shareItem = FilePreviewItem(url: resolvedURL)
            } catch {
                fileActionErrorMessage = RuntimeLocalization.string("文件路径检查失败，请稍后重试。")
            }
        }
    }
}

/// Accessibility text gets the full row width without changing its content or actions.
private struct FileTransferAdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Device Quick Send Card

struct DeviceQuickSendCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let device: DiscoveredDevice
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 8) {
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
                    .foregroundStyle(LiquidGlass.supportingText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 72)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("files.quickSend.\(device.id)")
    }
}

// MARK: - File Transfer Card

struct FileTransferCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transfer: FileTransfer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FileTransferAdaptiveRow(spacing: 12) {
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
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(formatFileSize(transfer.fileSize))
                        .font(.caption2)
                        .foregroundStyle(LiquidGlass.supportingText)
                }
                
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                
                FileTransferStatusBadge(transfer: transfer)
            }
            
            if transfer.status == .transferring {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
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
                    
                    FileTransferAdaptiveRow(spacing: 4) {
                        Text("\(Int(transfer.progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LiquidGlass.supportingText)
                        
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        
                        Text(formatSpeed(transfer.speed))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LiquidGlass.supportingText)
                    }
                }
            }

            if transfer.isIncoming, let locationText {
                Text(String(format: RuntimeLocalization.string("保存位置：%@"), locationText))
                    .font(.caption2)
                    .foregroundStyle(LiquidGlass.supportingText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if transfer.receiptDeliveryStatus == .unknown {
                Text(RuntimeLocalization.string("fileTransfer.receiptDeliveryUnknown"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if transfer.operationalWarning == .committedFileReleaseFailed {
                Text(RuntimeLocalization.string("fileTransfer.committedFileReleaseFailed"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
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

private struct FileTransferStatusBadge: View {
    let transfer: FileTransfer

    var body: some View {
        Group {
            switch transfer.status {
            case .pending:
                Label(RuntimeLocalization.string("等待中"), systemImage: "clock.fill")
                    .foregroundStyle(.primary)
            case .transferring:
                HStack(spacing: 4) {
                    ProgressView().tint(.cyan).scaleEffect(0.8)
                    Text(RuntimeLocalization.string("正在传输"))
                }
                .foregroundStyle(.primary)
            case .completed:
                Label(RuntimeLocalization.string("已完成"), systemImage: transfer.receiptDeliveryStatus == .unknown
                    ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(.primary)
            case .failed:
                Label(RuntimeLocalization.string("失败"), systemImage: transfer.receiptDeliveryStatus == .unknown
                    ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption)
    }
}

// MARK: - File Transfer History Card

struct FileTransferHistoryCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            FileTransferAdaptiveRow(spacing: 12) {
                Image(systemName: transfer.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundColor(transfer.isIncoming ? .green : .blue)
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.fileName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    FileTransferAdaptiveRow(spacing: 6) {
                        Text([
                            transfer.isIncoming
                                ? RuntimeLocalization.string("来自")
                                : RuntimeLocalization.string("发送至"),
                            transfer.remotePeer
                        ].joined(separator: " "))
                        if !dynamicTypeSize.isAccessibilitySize { Text("·") }
                        Text(relativeTimestampText)
                    }
                    .font(.caption2)
                    .foregroundStyle(LiquidGlass.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    FileTransferStatusBadge(transfer: transfer)
                    Text(ByteCountFormatter.string(fromByteCount: transfer.fileSize, countStyle: .file))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(LiquidGlass.supportingText)
                }
            }

            if transfer.isIncoming, let localPath = transfer.localPath {
                FileTransferAdaptiveRow(spacing: 8) {
                    Text(
                        String(
                            format: RuntimeLocalization.string("保存位置：%@"),
                            displayLocation(path: localPath)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(LiquidGlass.supportingText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    
                    Button(RuntimeLocalization.string("打开")) {
                        onOpenFile(transfer)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .buttonStyle(.borderless)

                    Button(RuntimeLocalization.string("导出")) {
                        onShareFile(transfer)
                    }
                    .font(.caption2)
                    .foregroundStyle(LiquidGlass.supportingText)
                    .buttonStyle(.borderless)
                }
            }

            if transfer.receiptDeliveryStatus == .unknown {
                Text(RuntimeLocalization.string("fileTransfer.receiptDeliveryUnknown"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if transfer.operationalWarning == .committedFileReleaseFailed {
                Text(RuntimeLocalization.string("fileTransfer.committedFileReleaseFailed"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
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
