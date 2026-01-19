//
// ClipboardSyncSettingsView.swift
// SkyBridgeUI
//
// 跨设备剪贴板同步设置界面
// 支持 macOS 14.0+
//

import SwiftUI
import SkyBridgeCore

/// 剪贴板同步设置视图
public struct ClipboardSyncSettingsView: View {

    @ObservedObject private var syncService: ClipboardSyncService
    @State private var showClearHistoryAlert = false

    public init(syncService: ClipboardSyncService = .shared) {
        self.syncService = syncService
    }

    public var body: some View {
        Form {
            // 启用/禁用
            Section {
                Toggle("启用剪贴板同步", isOn: Binding(
                    get: { syncService.isEnabled },
                    set: { newValue in
                        Task {
                            if newValue {
                                try? await syncService.enable()
                            } else {
                                syncService.disable()
                            }
                        }
                    }
                ))

                statusRow
            } header: {
                Label("同步状态", systemImage: "doc.on.clipboard")
            }

            // 同步选项
            Section {
                Toggle("同步图片", isOn: $syncService.configuration.syncImages)
                    .disabled(!syncService.isEnabled)

                Toggle("同步文件路径", isOn: $syncService.configuration.syncFileURLs)
                    .disabled(!syncService.isEnabled)

                maxSizeRow
            } header: {
                Label("同步内容", systemImage: "square.and.arrow.up.on.square")
            }

            // 已连接设备
            Section {
                if syncService.connectedDevices.isEmpty {
                    Text("无已连接设备")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(syncService.connectedDevices, id: \.deviceID) { device in
                        deviceRow(device)
                    }
                }
            } header: {
                Label("已连接设备 (\(syncService.connectedDevices.count))", systemImage: "laptopcomputer.and.iphone")
            }

            // 历史记录
            Section {
                historyLimitRow

                if !syncService.history.isEmpty {
                    Button(role: .destructive) {
                        showClearHistoryAlert = true
                    } label: {
                        Label("清除历史记录", systemImage: "trash")
                    }
                }
            } header: {
                Label("历史记录 (\(syncService.history.count))", systemImage: "clock.arrow.circlepath")
            }

            // 最近同步
            if !syncService.history.isEmpty {
                Section {
                    ForEach(syncService.history.prefix(5)) { entry in
                        historyEntryRow(entry)
                    }
                } header: {
                    Label("最近同步", systemImage: "list.bullet")
                }
            }
        }
        .formStyle(.grouped)
        .alert("清除历史记录", isPresented: $showClearHistoryAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                syncService.clearHistory()
            }
        } message: {
            Text("确定要清除所有剪贴板同步历史记录吗？此操作无法撤销。")
        }
    }

    // MARK: - Subviews

    private var statusRow: some View {
        HStack {
            Text("状态")
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(syncService.syncState.displayName)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch syncService.syncState {
        case .disabled:
            return .gray
        case .idle:
            return .green
        case .syncing:
            return .blue
        case .error:
            return .red
        }
    }

    private var maxSizeRow: some View {
        HStack {
            Text("最大内容大小")
            Spacer()
            Picker("", selection: Binding(
                get: { syncService.configuration.maxContentSize },
                set: { syncService.configuration.maxContentSize = $0 }
            )) {
                Text("1 MB").tag(1 * 1024 * 1024)
                Text("5 MB").tag(5 * 1024 * 1024)
                Text("10 MB").tag(10 * 1024 * 1024)
                Text("25 MB").tag(25 * 1024 * 1024)
            }
            .pickerStyle(.menu)
            .frame(width: 100)
            .disabled(!syncService.isEnabled)
        }
    }

    private var historyLimitRow: some View {
        HStack {
            Text("保留记录数")
            Spacer()
            Picker("", selection: Binding(
                get: { syncService.configuration.historyLimit },
                set: { syncService.configuration.historyLimit = $0 }
            )) {
                Text("10 条").tag(10)
                Text("25 条").tag(25)
                Text("50 条").tag(50)
                Text("100 条").tag(100)
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private func deviceRow(_ device: DeviceClipboardStatus) -> some View {
        HStack {
            Image(systemName: device.isOnline ? "checkmark.circle.fill" : "circle")
                .foregroundColor(device.isOnline ? .green : .gray)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                    .font(.body)

                if let lastSync = device.lastSyncTime {
                    Text("上次同步: \(lastSync, style: .relative)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if device.syncEnabled {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 2)
    }

    private func historyEntryRow(_ entry: ClipboardHistoryEntry) -> some View {
        HStack {
            // 方向图标
            Image(systemName: entry.direction == .outgoing ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundColor(entry.direction == .outgoing ? .blue : .green)

            // 内容类型图标
            Image(systemName: contentTypeIcon(entry.content.type))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                // 预览
                if let preview = entry.content.textPreview {
                    Text(preview)
                        .font(.body)
                        .lineLimit(1)
                } else {
                    Text(entry.content.type.rawValue.capitalized)
                        .font(.body)
                }

                // 时间和大小
                HStack {
                    Text(entry.syncedAt, style: .relative)
                    Text("·")
                    Text(formatBytes(entry.content.size))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func contentTypeIcon(_ type: ClipboardContentType) -> String {
        switch type {
        case .text: return "doc.text"
        case .image: return "photo"
        case .fileURL: return "folder"
        case .richText: return "doc.richtext"
        case .html: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - 剪贴板同步状态栏项目

/// 菜单栏状态项视图
public struct ClipboardSyncMenuBarView: View {

    @ObservedObject private var syncService: ClipboardSyncService

    public init(syncService: ClipboardSyncService = .shared) {
        self.syncService = syncService
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 状态
            HStack {
                Image(systemName: "doc.on.clipboard")
                Text("剪贴板同步")
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            .font(.headline)

            Divider()

            // 开关
            Toggle("启用", isOn: Binding(
                get: { syncService.isEnabled },
                set: { newValue in
                    Task {
                        if newValue {
                            try? await syncService.enable()
                        } else {
                            syncService.disable()
                        }
                    }
                }
            ))

            // 设备数
            HStack {
                Text("已连接设备")
                Spacer()
                Text("\(syncService.connectedDevices.count)")
                    .foregroundColor(.secondary)
            }

            // 最后同步
            if let lastSync = syncService.lastSyncTime {
                HStack {
                    Text("上次同步")
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // 手动同步
            Button {
                Task {
                    try? await syncService.syncNow()
                }
            } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!syncService.isEnabled)
        }
        .padding()
        .frame(width: 250)
    }

    private var statusColor: Color {
        switch syncService.syncState {
        case .disabled: return .gray
        case .idle: return .green
        case .syncing: return .blue
        case .error: return .red
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ClipboardSyncSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ClipboardSyncSettingsView()
            .frame(width: 500, height: 600)
    }
}
#endif
