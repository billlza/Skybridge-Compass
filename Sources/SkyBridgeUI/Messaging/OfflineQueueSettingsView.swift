//
// OfflineQueueSettingsView.swift
// SkyBridgeUI
//
// 离线消息队列设置界面
// 支持 macOS 14.0+
//

import SwiftUI
import SkyBridgeCore

/// 离线消息队列设置视图
public struct OfflineQueueSettingsView: View {

    @ObservedObject private var queue: OfflineMessageQueue
    @State private var showClearConfirmation = false

    public init(queue: OfflineMessageQueue = .shared) {
        self.queue = queue
    }

    public var body: some View {
        Form {
            // 状态概览
            Section {
                statisticsOverview
            } header: {
                Label("队列状态", systemImage: "tray.full")
            }

            // 队列配置
            Section {
                maxQueueSizeRow
                maxMessagesPerDeviceRow
                maxRetryCountRow
                retryIntervalRow
            } header: {
                Label("队列配置", systemImage: "slider.horizontal.3")
            }

            // TTL 配置
            Section {
                defaultTTLRow
                urgentTTLRow
            } header: {
                Label("消息有效期", systemImage: "clock")
            }

            // 高级选项
            Section {
                Toggle("启用持久化", isOn: $queue.configuration.enablePersistence)
                Toggle("按优先级排序", isOn: $queue.configuration.priorityOrdering)
            } header: {
                Label("高级选项", systemImage: "gearshape.2")
            }

            // 设备队列分布
            if !queue.statistics.deviceBreakdown.isEmpty {
                Section {
                    ForEach(Array(queue.statistics.deviceBreakdown.keys.sorted()), id: \.self) { deviceID in
                        HStack {
                            Text(deviceID)
                                .lineLimit(1)
                            Spacer()
                            Text("\(queue.statistics.deviceBreakdown[deviceID] ?? 0) 条")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Label("设备队列分布", systemImage: "laptopcomputer.and.iphone")
                }
            }

            // 操作
            Section {
                Button {
                    Task {
                        await queue.retryFailed()
                    }
                } label: {
                    Label("重试失败消息", systemImage: "arrow.clockwise")
                }
                .disabled(queue.statistics.failedMessages == 0)

                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("清空队列", systemImage: "trash")
                }
                .disabled(queue.statistics.totalMessages == 0)
            } header: {
                Label("操作", systemImage: "hand.tap")
            }
        }
        .formStyle(.grouped)
        .alert("确认清空队列", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task {
                    await queue.clearAll()
                }
            }
        } message: {
            Text("确定要清空所有待发消息吗？此操作无法撤销。")
        }
    }

    // MARK: - Subviews

    private var statisticsOverview: some View {
        VStack(spacing: 12) {
            // 主要统计
            HStack(spacing: 20) {
                statisticCell(
                    title: "待发送",
                    value: queue.statistics.pendingMessages,
                    color: .blue
                )

                statisticCell(
                    title: "发送中",
                    value: queue.statistics.sendingMessages,
                    color: .orange
                )

                statisticCell(
                    title: "已送达",
                    value: queue.statistics.deliveredMessages,
                    color: .green
                )

                statisticCell(
                    title: "失败",
                    value: queue.statistics.failedMessages,
                    color: .red
                )
            }

            Divider()

            // 附加信息
            HStack {
                if let oldestAge = queue.statistics.oldestMessageAge {
                    Label("最老消息: \(formatDuration(oldestAge))", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if queue.statistics.averageWaitTime > 0 {
                    Label("平均等待: \(formatDuration(queue.statistics.averageWaitTime))", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // 处理状态指示器
            if queue.isProcessing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("正在处理队列...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func statisticCell(title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(color)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var maxQueueSizeRow: some View {
        HStack {
            Text("最大队列大小")
            Spacer()
            Picker("", selection: $queue.configuration.maxQueueSize) {
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1000").tag(1000)
                Text("5000").tag(5000)
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private var maxMessagesPerDeviceRow: some View {
        HStack {
            Text("每设备最大消息数")
            Spacer()
            Picker("", selection: $queue.configuration.maxMessagesPerDevice) {
                Text("50").tag(50)
                Text("100").tag(100)
                Text("200").tag(200)
                Text("500").tag(500)
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private var maxRetryCountRow: some View {
        HStack {
            Text("最大重试次数")
            Spacer()
            Picker("", selection: $queue.configuration.maxRetryCount) {
                Text("3 次").tag(3)
                Text("5 次").tag(5)
                Text("10 次").tag(10)
                Text("20 次").tag(20)
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private var retryIntervalRow: some View {
        HStack {
            Text("重试间隔")
            Spacer()
            Picker("", selection: $queue.configuration.retryInterval) {
                Text("10 秒").tag(TimeInterval(10))
                Text("30 秒").tag(TimeInterval(30))
                Text("60 秒").tag(TimeInterval(60))
                Text("5 分钟").tag(TimeInterval(300))
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private var defaultTTLRow: some View {
        HStack {
            Text("普通消息有效期")
            Spacer()
            Picker("", selection: $queue.configuration.defaultTTL) {
                Text("1 小时").tag(TimeInterval(3600))
                Text("6 小时").tag(TimeInterval(21600))
                Text("24 小时").tag(TimeInterval(86400))
                Text("7 天").tag(TimeInterval(604800))
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    private var urgentTTLRow: some View {
        HStack {
            Text("紧急消息有效期")
            Spacer()
            Picker("", selection: $queue.configuration.urgentTTL) {
                Text("24 小时").tag(TimeInterval(86400))
                Text("7 天").tag(TimeInterval(604800))
                Text("30 天").tag(TimeInterval(2592000))
                Text("永不过期").tag(TimeInterval.infinity)
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }
}

// MARK: - 消息列表视图

/// 待发消息列表视图
public struct PendingMessagesListView: View {

    @ObservedObject private var queue: OfflineMessageQueue
    @State private var messages: [QueuedMessage] = []
    @State private var selectedDeviceID: String?

    public init(queue: OfflineMessageQueue = .shared) {
        self.queue = queue
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 设备过滤器
            if !queue.statistics.deviceBreakdown.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(
                            title: "全部",
                            isSelected: selectedDeviceID == nil,
                            count: queue.statistics.pendingMessages
                        ) {
                            selectedDeviceID = nil
                            Task { await refreshMessages() }
                        }

                        ForEach(Array(queue.statistics.deviceBreakdown.keys.sorted()), id: \.self) { deviceID in
                            FilterChip(
                                title: String(deviceID.prefix(8)),
                                isSelected: selectedDeviceID == deviceID,
                                count: queue.statistics.deviceBreakdown[deviceID] ?? 0
                            ) {
                                selectedDeviceID = deviceID
                                Task { await refreshMessages() }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)

                Divider()
            }

            // 消息列表
            if messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("暂无待发消息")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(messages) { message in
                        MessageRow(message: message) {
                            Task {
                                try? await queue.cancel(messageID: message.id)
                                await refreshMessages()
                            }
                        }
                    }
                }
            }
        }
        .task {
            await refreshMessages()
        }
    }

    private func refreshMessages() async {
        if let deviceID = selectedDeviceID {
            messages = await queue.getPendingMessages(for: deviceID)
        } else {
            messages = await queue.getAllPendingMessages()
                .filter { !$0.status.isTerminal }
                .sorted { $0.priority > $1.priority }
        }
    }
}

// MARK: - 辅助视图

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("(\(count))")
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

private struct MessageRow: View {
    let message: QueuedMessage
    let onCancel: () -> Void

    var body: some View {
        HStack {
            // 优先级指示器
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.messageType.displayName)
                        .font(.body)

                    Text(message.priority.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(priorityColor.opacity(0.2))
                        .cornerRadius(4)
                }

                HStack {
                    Text("目标: \(String(message.targetDeviceID.prefix(8)))...")
                    Text("·")
                    Text(message.status.displayName)
                    if message.retryCount > 0 {
                        Text("·")
                        Text("重试 \(message.retryCount) 次")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                HStack {
                    Text("创建于 \(message.createdAt, style: .relative)")
                    if message.remainingTTL < 3600 {
                        Text("·")
                        Text("即将过期")
                            .foregroundColor(.orange)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var priorityColor: Color {
        switch message.priority {
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }
}

// MARK: - Preview

#if DEBUG
struct OfflineQueueSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        OfflineQueueSettingsView()
            .frame(width: 500, height: 600)
    }
}
#endif
