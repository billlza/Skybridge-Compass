import SwiftUI

// MARK: - 传输队列视图
/// 展示传输队列状态，支持暂停、恢复、取消等操作
@available(macOS 14.0, iOS 17.0, *)
public struct TransferQueueView: View {
    
    @StateObject private var transferManager = ResumableTransferManager.shared
    @State private var selectedTransfer: ResumableTransfer?
    @State private var showingClearConfirmation = false
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // 顶部统计栏
            statisticsBar
            
            Divider()
            
            // 传输列表
            if transferManager.transfers.isEmpty {
                emptyStateView
            } else {
                transferList
            }
        }
        .confirmationDialog(
            "清除已完成的传输？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                transferManager.clearCompleted()
            }
            Button("取消", role: .cancel) {}
        }
    }
    
    // MARK: - 子视图
    
    private var statisticsBar: some View {
        HStack(spacing: 16) {
            // 队列状态
            let summary = transferManager.getStatusSummary()
            
            HStack(spacing: 8) {
                statusBadge(count: summary.transferring, label: "传输中", color: .blue, icon: "arrow.up.arrow.down")
                statusBadge(count: summary.queued, label: "等待中", color: .orange, icon: "clock")
                statusBadge(count: summary.paused, label: "已暂停", color: .gray, icon: "pause.circle")
                statusBadge(count: summary.failed, label: "失败", color: .red, icon: "exclamationmark.triangle")
            }
            
            Spacer()
            
            // 总体进度
            if summary.totalBytes > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(formatBytes(summary.transferredBytes)) / \(formatBytes(summary.totalBytes))")
                        .font(.caption.monospacedDigit())
                    
                    if transferManager.statistics.currentSpeed > 0 {
                        Text("\(formatSpeed(transferManager.statistics.currentSpeed))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // 操作按钮
            HStack(spacing: 8) {
                Button(action: {
                    if transferManager.isQueuePaused {
                        transferManager.resumeAll()
                    } else {
                        transferManager.pauseAll()
                    }
                }) {
                    Image(systemName: transferManager.isQueuePaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(transferManager.isQueuePaused ? "恢复全部" : "暂停全部")
                
                Button(action: { showingClearConfirmation = true }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(transferManager.transfers.filter { $0.state == .completed || $0.state == .cancelled }.isEmpty)
                .help("清除已完成")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PlatformColor.controlBackground)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("传输队列为空")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("拖放文件到设备或使用文件传输功能开始传输")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var transferList: some View {
        List {
            // 活跃传输
            let active = transferManager.transfers.filter { $0.state == .transferring }
            if !active.isEmpty {
                Section("传输中") {
                    ForEach(active) { transfer in
                        TransferRowView(transfer: transfer)
                    }
                }
            }
            
            // 等待中
            let queued = transferManager.transfers.filter { $0.state == .queued }
            if !queued.isEmpty {
                Section("等待中 (\(queued.count))") {
                    ForEach(queued) { transfer in
                        TransferRowView(transfer: transfer)
                    }
                }
            }
            
            // 已暂停
            let paused = transferManager.transfers.filter { $0.state == .paused }
            if !paused.isEmpty {
                Section("已暂停") {
                    ForEach(paused) { transfer in
                        TransferRowView(transfer: transfer)
                    }
                }
            }
            
            // 失败
            let failed = transferManager.transfers.filter { $0.state == .failed }
            if !failed.isEmpty {
                Section("失败") {
                    ForEach(failed) { transfer in
                        TransferRowView(transfer: transfer)
                    }
                }
            }
            
            // 已完成
            let completed = transferManager.transfers.filter { $0.state == .completed }
            if !completed.isEmpty {
                Section("已完成 (\(completed.count))") {
                    ForEach(completed.prefix(10)) { transfer in
                        TransferRowView(transfer: transfer)
                    }
                    
                    if completed.count > 10 {
                        Text("还有 \(completed.count - 10) 个已完成的传输")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
    
    // MARK: - 辅助视图
    
    private func statusBadge(count: Int, label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text("\(count)")
                .font(.caption.monospacedDigit().bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .cornerRadius(6)
        .opacity(count > 0 ? 1 : 0.5)
    }
    
    // MARK: - 格式化方法
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }
}

// MARK: - 传输行视图

@available(macOS 14.0, iOS 17.0, *)
struct TransferRowView: View {
    let transfer: ResumableTransfer
    @StateObject private var transferManager = ResumableTransferManager.shared
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 文件图标
            fileIcon
            
            // 文件信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(transfer.fileName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // 方向指示器
                    Image(systemName: transfer.direction == .outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(transfer.direction == .outgoing ? .blue : .green)
                        .font(.caption)
                }
                
                HStack {
                    // 目标设备
                    Text(transfer.targetDevice.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .foregroundStyle(.tertiary)
                    
                    // 大小
                    Text(formatBytes(transfer.fileSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    // 状态/进度
                    statusView
                }
                
                // 进度条
                if transfer.state == .transferring || transfer.state == .paused {
                    ProgressView(value: transfer.progress, total: 100)
                        .progressViewStyle(.linear)
                        .tint(transfer.state == .paused ? .gray : .blue)
                }
                
                // 错误信息
                if let error = transfer.lastError, transfer.state == .failed {
            Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            
            // 操作按钮
            if isHovering {
                actionButtons
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            contextMenuItems
        }
    }
    
    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(iconBackgroundColor)
                .frame(width: 40, height: 40)
            
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundStyle(iconForegroundColor)
        }
    }
    
    private var statusView: some View {
        Group {
            switch transfer.state {
            case .queued:
                Label("等待中", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                
            case .transferring:
                HStack(spacing: 4) {
                    Text("\(Int(transfer.progress))%")
                        .font(.caption.monospacedDigit())
                    
                    if let eta = transfer.estimatedTimeRemaining {
                        Text("• 剩余 \(formatDuration(eta))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.blue)
                
            case .paused:
                Label("已暂停", systemImage: "pause.circle")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                
            case .completed:
                Label("已完成", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.green)
                
            case .failed:
                Label("失败", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                
            case .cancelled:
                Label("已取消", systemImage: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 4) {
            switch transfer.state {
            case .queued, .transferring:
                Button(action: { transferManager.pause(transfer.id) }) {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.borderless)
                
            case .paused, .failed:
                Button(action: { transferManager.resume(transfer.id) }) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                
            default:
                EmptyView()
            }
            
            if transfer.state != .completed && transfer.state != .cancelled {
                Button(action: { transferManager.cancel(transfer.id) }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
        }
    }
    
    @ViewBuilder
    private var contextMenuItems: some View {
        switch transfer.state {
        case .queued, .transferring:
            Button("暂停") { transferManager.pause(transfer.id) }
            Button("取消", role: .destructive) { transferManager.cancel(transfer.id) }
            
        case .paused:
            Button("恢复") { transferManager.resume(transfer.id) }
            Button("取消", role: .destructive) { transferManager.cancel(transfer.id) }
            
        case .failed:
            Button("重试") { transferManager.retry(transfer.id) }
            Button("取消", role: .destructive) { transferManager.cancel(transfer.id) }
            
        case .completed:
#if os(macOS)
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([transfer.fileURL])
            }
#endif
            
        case .cancelled:
            EmptyView()
        }
        
        Divider()
        
        Menu("优先级") {
            Button("紧急") { transferManager.setPriority(transfer.id, priority: .urgent) }
            Button("高") { transferManager.setPriority(transfer.id, priority: .high) }
            Button("普通") { transferManager.setPriority(transfer.id, priority: .normal) }
            Button("低") { transferManager.setPriority(transfer.id, priority: .low) }
        }
    }
    
    // MARK: - 辅助属性
    
    private var iconBackgroundColor: Color {
        switch transfer.state {
        case .transferring: return .blue.opacity(0.15)
        case .completed: return .green.opacity(0.15)
        case .failed: return .red.opacity(0.15)
        case .paused: return .gray.opacity(0.15)
        default: return .orange.opacity(0.15)
        }
    }
    
    private var iconForegroundColor: Color {
        switch transfer.state {
        case .transferring: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused: return .gray
        default: return .orange
        }
    }
    
    private var iconName: String {
        let ext = (transfer.fileName as NSString).pathExtension.lowercased()
        
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        case "mp3", "wav", "aac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "rar":
            return "archivebox"
        case "app", "dmg", "pkg":
            return "app.badge"
        default:
            return "doc"
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))秒"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))分钟"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)小时\(minutes)分钟"
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, iOS 17.0, *)
#Preview {
    TransferQueueView()
        .frame(width: 500, height: 600)
}
#endif

