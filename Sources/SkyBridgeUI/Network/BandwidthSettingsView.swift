//
// BandwidthSettingsView.swift
// SkyBridgeUI
//
// 带宽限速设置界面
// 支持 macOS 14.0+
//

import SwiftUI
import SkyBridgeCore

/// 带宽限速设置视图
public struct BandwidthSettingsView: View {

    @ObservedObject private var engine: BandwidthThrottleEngine
    @State private var showScheduleEditor = false
    @State private var editingSchedule: BandwidthSchedule?

    public init(engine: BandwidthThrottleEngine = .shared) {
        self.engine = engine
    }

    public var body: some View {
        Form {
            // 启用开关
            Section {
                Toggle("启用带宽限速", isOn: $engine.isEnabled)

                if engine.isEnabled {
                    globalLimitRow
                }
            } header: {
                Label("带宽控制", systemImage: "speedometer")
            }

            // 设备限速
            if engine.isEnabled {
                Section {
                    if engine.config.perDeviceLimits.isEmpty {
                        Text("暂无设备限速规则")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(engine.config.perDeviceLimits.keys), id: \.self) { deviceID in
                            deviceLimitRow(deviceID: deviceID)
                        }
                        .onDelete { indexSet in
                            let keys = Array(engine.config.perDeviceLimits.keys)
                            for index in indexSet {
                                engine.setDeviceLimit(nil, for: keys[index])
                            }
                        }
                    }
                } header: {
                    Label("设备限速", systemImage: "laptopcomputer")
                }

                // 时段限速
                Section {
                    ForEach(engine.config.schedules) { schedule in
                        scheduleRow(schedule)
                    }
                    .onDelete { indexSet in
                        let schedules = engine.config.schedules
                        for index in indexSet {
                            engine.removeSchedule(id: schedules[index].id)
                        }
                    }

                    Button {
                        editingSchedule = nil
                        showScheduleEditor = true
                    } label: {
                        Label("添加时段规则", systemImage: "plus.circle")
                    }
                } header: {
                    Label("时段限速", systemImage: "clock")
                }

                // 使用统计
                Section {
                    if engine.currentUsage.isEmpty {
                        Text("暂无使用数据")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(engine.currentUsage.keys), id: \.self) { deviceID in
                            usageRow(deviceID: deviceID)
                        }
                    }

                    if !engine.currentUsage.isEmpty {
                        Button(role: .destructive) {
                            engine.resetStatistics()
                        } label: {
                            Label("重置统计", systemImage: "trash")
                        }
                    }
                } header: {
                    Label("使用统计", systemImage: "chart.bar")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showScheduleEditor) {
            ScheduleEditorView(
                schedule: editingSchedule,
                onSave: { schedule in
                    if editingSchedule != nil {
                        // 更新现有规则
                        if let index = engine.config.schedules.firstIndex(where: { $0.id == schedule.id }) {
                            engine.config.schedules[index] = schedule
                        }
                    } else {
                        // 添加新规则
                        engine.addSchedule(schedule)
                    }
                    showScheduleEditor = false
                },
                onCancel: {
                    showScheduleEditor = false
                }
            )
        }
    }

    // MARK: - Subviews

    private var globalLimitRow: some View {
        HStack {
            Text("全局限速")
            Spacer()
            Picker("", selection: Binding(
                get: { engine.config.globalLimit ?? 0 },
                set: { engine.config.globalLimit = $0 == 0 ? nil : $0 }
            )) {
                Text("无限制").tag(Int64(0))
                Text("10 MB/s").tag(Int64(10 * 1024 * 1024))
                Text("50 MB/s").tag(Int64(50 * 1024 * 1024))
                Text("100 MB/s").tag(Int64(100 * 1024 * 1024))
                Text("500 MB/s").tag(Int64(500 * 1024 * 1024))
                Text("1 GB/s").tag(Int64(1024 * 1024 * 1024))
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }
    }

    private func deviceLimitRow(deviceID: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(deviceID)
                    .lineLimit(1)
                if let limit = engine.config.perDeviceLimits[deviceID] {
                    Text(limit.bandwidthFormatted)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private func scheduleRow(_ schedule: BandwidthSchedule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: schedule.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(schedule.isEnabled ? .green : .gray)
                    Text(schedule.name)
                }

                Text("\(schedule.startHour):00 - \(schedule.endHour):00 | \(schedule.limit.bandwidthFormatted)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                editingSchedule = schedule
                showScheduleEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func usageRow(deviceID: String) -> some View {
        let stats = engine.getUsageStats(for: deviceID)

        return HStack {
            Text(deviceID)
                .lineLimit(1)

            Spacer()

            VStack(alignment: .trailing) {
                Text(formatBytes(stats.bytesUsed))
                    .font(.body)

                ProgressView(value: min(stats.usageRatio, 1.0))
                    .frame(width: 80)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 时段规则编辑器

struct ScheduleEditorView: View {
    @State private var name: String
    @State private var startHour: Int
    @State private var endHour: Int
    @State private var limitMBps: Double
    @State private var isEnabled: Bool
    @State private var selectedDays: Set<Int>

    private let scheduleID: UUID
    private let onSave: (BandwidthSchedule) -> Void
    private let onCancel: () -> Void

    private let dayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    init(
        schedule: BandwidthSchedule?,
        onSave: @escaping (BandwidthSchedule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.scheduleID = schedule?.id ?? UUID()
        self._name = State(initialValue: schedule?.name ?? "新规则")
        self._startHour = State(initialValue: schedule?.startHour ?? 9)
        self._endHour = State(initialValue: schedule?.endHour ?? 18)
        self._limitMBps = State(initialValue: Double(schedule?.limit ?? 50 * 1024 * 1024) / (1024 * 1024))
        self._isEnabled = State(initialValue: schedule?.isEnabled ?? true)
        self._selectedDays = State(initialValue: schedule?.daysOfWeek ?? Set(1...7))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Text("时段限速规则")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // 表单
            Form {
                TextField("规则名称", text: $name)

                Toggle("启用", isOn: $isEnabled)

                // 时间范围
                HStack {
                    Picker("开始时间", selection: $startHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                    .frame(width: 100)

                    Text("至")

                    Picker("结束时间", selection: $endHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                    .frame(width: 100)
                }

                // 限速值
                HStack {
                    Text("限速:")
                    TextField("", value: $limitMBps, format: .number)
                        .frame(width: 80)
                    Text("MB/s")
                }

                // 星期选择
                VStack(alignment: .leading) {
                    Text("适用日期:")
                    HStack {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(dayNames[day - 1], isOn: Binding(
                                get: { selectedDays.contains(day) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedDays.insert(day)
                                    } else {
                                        selectedDays.remove(day)
                                    }
                                }
                            ))
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 300)

            Divider()

            // 按钮
            HStack {
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存") {
                    let schedule = BandwidthSchedule(
                        id: scheduleID,
                        name: name,
                        startHour: startHour,
                        endHour: endHour,
                        limit: Int64(limitMBps * 1024 * 1024),
                        daysOfWeek: selectedDays,
                        isEnabled: isEnabled
                    )
                    onSave(schedule)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450, height: 450)
    }
}

// MARK: - Preview

#if DEBUG
struct BandwidthSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        BandwidthSettingsView()
            .frame(width: 500, height: 600)
    }
}
#endif
