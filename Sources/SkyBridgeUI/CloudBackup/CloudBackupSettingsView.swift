//
// CloudBackupSettingsView.swift
// SkyBridgeUI
//
// 云端备份设置界面
// 支持 macOS 14.0+
//

import SwiftUI
import SkyBridgeCore

/// 云端备份设置视图
public struct CloudBackupSettingsView: View {

    @ObservedObject private var backupService: CloudBackupService
    @State private var showPasswordSheet = false
    @State private var showRestoreSheet = false
    @State private var selectedBackup: CloudBackupRecord?
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showDeleteConfirmation = false
    @State private var backupToDelete: CloudBackupRecord?

    public init(backupService: CloudBackupService = .shared) {
        self.backupService = backupService
    }

    public var body: some View {
        Form {
            // iCloud 状态
            Section {
                iCloudStatusRow

                if backupService.isICloudAvailable {
                    Button {
                        showPasswordSheet = true
                    } label: {
                        Label("设置加密密码", systemImage: "key")
                    }
                }
            } header: {
                Label("iCloud 状态", systemImage: "icloud")
            }

            // 自动备份
            Section {
                Toggle("启用自动备份", isOn: $backupService.configuration.autoBackupEnabled)
                    .disabled(!backupService.isICloudAvailable)

                if backupService.configuration.autoBackupEnabled {
                    Picker("备份间隔", selection: $backupService.configuration.autoBackupInterval) {
                        Text("每天").tag(TimeInterval(86400))
                        Text("每周").tag(TimeInterval(604800))
                        Text("每月").tag(TimeInterval(2592000))
                    }

                    Toggle("仅在 WiFi 下备份", isOn: $backupService.configuration.wifiOnlyBackup)
                }
            } header: {
                Label("自动备份", systemImage: "arrow.clockwise")
            }

            // 备份内容
            Section {
                ForEach(BackupItemType.allCases, id: \.self) { type in
                    Toggle(isOn: Binding(
                        get: { backupService.configuration.enabledBackupTypes.contains(type) },
                        set: { isEnabled in
                            if isEnabled {
                                backupService.configuration.enabledBackupTypes.insert(type)
                            } else {
                                backupService.configuration.enabledBackupTypes.remove(type)
                            }
                        }
                    )) {
                        Label(type.displayName, systemImage: type.icon)
                    }
                }
            } header: {
                Label("备份内容", systemImage: "doc.on.doc")
            }

            // 手动备份
            Section {
                if let lastTime = backupService.lastBackupTime {
                    HStack {
                        Text("上次备份")
                        Spacer()
                        Text(lastTime, style: .relative)
                            .foregroundColor(.secondary)
                    }
                }

                Button {
                    Task {
                        try? await backupService.createBackup()
                    }
                } label: {
                    HStack {
                        Label("立即备份", systemImage: "arrow.up.to.line")
                        Spacer()
                        if backupService.status.isActive {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
                .disabled(!backupService.isICloudAvailable || backupService.status.isActive)

                statusRow
            } header: {
                Label("备份操作", systemImage: "externaldrive.badge.icloud")
            }

            // 可用备份
            Section {
                if backupService.availableBackups.isEmpty {
                    Text("暂无可用备份")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(backupService.availableBackups) { record in
                        backupRow(record)
                    }
                }

                Button {
                    Task {
                        await backupService.refreshAvailableBackups()
                    }
                } label: {
                    Label("刷新列表", systemImage: "arrow.clockwise")
                }
            } header: {
                Label("可用备份 (\(backupService.availableBackups.count))", systemImage: "clock.arrow.circlepath")
            }

            // 高级设置
            Section {
                Picker("保留备份数量", selection: $backupService.configuration.maxBackupCount) {
                    Text("5 个").tag(5)
                    Text("10 个").tag(10)
                    Text("20 个").tag(20)
                    Text("50 个").tag(50)
                }
            } header: {
                Label("高级设置", systemImage: "gearshape.2")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPasswordSheet) {
            passwordSheet
        }
        .sheet(item: $selectedBackup) { record in
            restoreSheet(record)
        }
        .alert("删除备份", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let backup = backupToDelete {
                    Task {
                        try? await backupService.deleteBackup(backup)
                    }
                }
            }
        } message: {
            Text("确定要删除此备份吗？此操作无法撤销。")
        }
        .task {
            await backupService.refreshAvailableBackups()
        }
    }

    // MARK: - Subviews

    private var iCloudStatusRow: some View {
        HStack {
            Text("iCloud 状态")
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(backupService.isICloudAvailable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(backupService.isICloudAvailable ? "已连接" : "未连接")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusRow: some View {
        HStack {
            Text("状态")
            Spacer()

            if let progress = backupService.status.progress {
                ProgressView(value: progress)
                    .frame(width: 80)
            }

            Text(backupService.status.displayName)
                .foregroundColor(.secondary)
        }
    }

    private func backupRow(_ record: CloudBackupRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.deviceName)
                        .font(.body)

                    Text("v\(record.appVersion)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                HStack {
                    Text(record.createdAt, style: .date)
                    Text("·")
                    Text(formatBytes(record.totalSize))
                    Text("·")
                    Text("\(record.itemCount) 项")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 12) {
                Button {
                    selectedBackup = record
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .buttonStyle(.borderless)
                .help("恢复此备份")

                Button {
                    backupToDelete = record
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("删除此备份")
            }
        }
        .padding(.vertical, 4)
    }

    private var passwordSheet: some View {
        VStack(spacing: 20) {
            Text("设置加密密码")
                .font(.headline)

            Text("此密码用于加密您的备份数据。请妥善保管，密码丢失将无法恢复备份。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)

            SecureField("确认密码", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("取消") {
                    showPasswordSheet = false
                    password = ""
                    confirmPassword = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("确定") {
                    if password == confirmPassword && !password.isEmpty {
                        try? backupService.setEncryptionPassword(password)
                        showPasswordSheet = false
                        password = ""
                        confirmPassword = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || password != confirmPassword)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func restoreSheet(_ record: CloudBackupRecord) -> some View {
        VStack(spacing: 20) {
            Text("恢复备份")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("设备:")
                    Spacer()
                    Text(record.deviceName)
                }
                HStack {
                    Text("日期:")
                    Spacer()
                    Text(record.createdAt, style: .date)
                }
                HStack {
                    Text("大小:")
                    Spacer()
                    Text(formatBytes(record.totalSize))
                }
                HStack {
                    Text("项目数:")
                    Spacer()
                    Text("\(record.itemCount) 项")
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Text("恢复将覆盖当前设备上的相应数据。确定要继续吗？")
                .font(.caption)
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)

            HStack {
                Button("取消") {
                    selectedBackup = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("恢复") {
                    Task {
                        try? await backupService.restoreBackup(record)
                        selectedBackup = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400)
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Preview

#if DEBUG
struct CloudBackupSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        CloudBackupSettingsView()
            .frame(width: 500, height: 700)
    }
}
#endif
