import SwiftUI
import AppIntents
import Observation

struct SettingsView: View {
    @Environment(DashboardViewModel.self) private var viewModel
    @State private var refreshInterval: Double = 3
    @State private var systemSettingsModel = SystemSettingsViewModel()

    var body: some View {
        Form {
            if systemSettingsModel.isLoading {
                Section {
                    ProgressView("正在同步系统策略…")
                }
            }

            if let profile = systemSettingsModel.profile {
                Section("当前策略") {
                    LabeledContent("名称", value: profile.name)
                    LabeledContent("维护者", value: profile.author)
                    LabeledContent("更新时间", value: profile.appliedAt.formatted(date: .numeric, time: .shortened))
                    Button {
                        Task { await systemSettingsModel.refresh() }
                    } label: {
                        Label("重新拉取策略", systemImage: "arrow.clockwise")
                    }
                }
            }

            ForEach(systemSettingsModel.categories) { category in
                Section(category.name) {
                    ForEach(category.settings) { setting in
                        SystemSettingControl(
                            setting: setting,
                            valueProvider: systemSettingsModel.binding(for: setting)
                        )
                    }
                }
            }

            if let error = systemSettingsModel.errorMessage {
                Section("系统策略状态") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.pink)
                }
            }

            Section("刷新频率") {
                Slider(value: $refreshInterval, in: 2...10, step: 1) {
                    Text("刷新频率")
                } minimumValueLabel: {
                    Text("2s")
                } maximumValueLabel: {
                    Text("10s")
                }
                Text("当前: \(Int(refreshInterval)) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Siri 快捷指令") {
                Text("对 Siri 说“打开云桥司南控制台”即可快速唤醒应用，跳转到主控制台。")
                    .font(.body)
                AppShortcutLink(intent: OpenDashboardIntent()) {
                    Label("添加到 Siri", systemImage: "mic")
                }
            }

            Section("小组件") {
                Text("将 Skybridge Compass 小组件添加到主屏幕或锁屏以随时查看实时指标。")
                Link("查看小组件管理", destination: URL(string: "x-apple.systempreferences:com.apple.WidgetKitSettingsExtension")!)
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0")
                LabeledContent("构建时间", value: Date.now.formatted(date: .numeric, time: .shortened))
            }
        }
        .navigationTitle("系统设置")
        .onAppear {
            refreshInterval = max(2, min(10, viewModel.monitoringInterval.secondsDouble))
        }
        .onChange(of: refreshInterval) { _, newValue in
            viewModel.updateMonitoringInterval(seconds: newValue)
        }
        .task {
            await systemSettingsModel.refresh()
        }
    }
}

private struct SystemSettingControl: View {
    let setting: SystemSetting
    let valueProvider: SystemSettingBinding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch setting.kind {
            case .toggle:
                Toggle(isOn: valueProvider.toggleBinding) {
                    Text(setting.name)
                        .font(.headline)
                }
            case .selection:
                Menu {
                    ForEach(setting.options, id: \.self) { option in
                        Button(option) {
                            valueProvider.selectionAction(option)
                        }
                    }
                } label: {
                    LabeledContent(setting.name, value: valueProvider.displayValue)
                }
            case .slider:
                let range = (setting.minimumValue ?? 0)...(setting.maximumValue ?? 100)
                Slider(value: valueProvider.sliderBinding(range: range), in: range, step: setting.step ?? 1)
                LabeledContent(setting.name, value: valueProvider.displayValue)
            }
            Text(setting.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SystemSettingBinding {
    let settingID: UUID
    let getValue: () -> SystemSetting?
    let toggleAction: (Bool) -> Void
    let selectionAction: (String) -> Void
    let sliderAction: (Double) -> Void

    var displayValue: String {
        getValue()?.displayValue ?? "--"
    }

    var toggleBinding: Binding<Bool> {
        Binding<Bool>(
            get: { getValue()?.boolValue ?? false },
            set: { newValue in toggleAction(newValue) }
        )
    }

    func sliderBinding(range: ClosedRange<Double>) -> Binding<Double> {
        Binding<Double>(
            get: {
                let value = getValue()?.doubleValue ?? range.lowerBound
                return min(max(value, range.lowerBound), range.upperBound)
            },
            set: { newValue in sliderAction(newValue) }
        )
    }
}

@MainActor
@Observable
final class SystemSettingsViewModel {
    var categories: [SystemSettingsCategory] = []
    var profile: SystemSettingsProfile?
    var isLoading: Bool = false
    var errorMessage: String?

    private let service: SystemSettingsService
    private var settings: [UUID: SystemSetting] = [:]

    init(service: SystemSettingsService = .shared) {
        self.service = service
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await service.fetchSettings()
            settings = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            categories = Self.group(settings: fetched)
            profile = try await service.fetchProfile()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func binding(for setting: SystemSetting) -> SystemSettingBinding {
        SystemSettingBinding(
            settingID: setting.id,
            getValue: { [weak self] in
                guard let self else { return nil }
                return self.settings[setting.id]
            },
            toggleAction: { [weak self] newValue in
                Task { await self?.updateToggle(for: setting, value: newValue) }
            },
            selectionAction: { [weak self] option in
                Task { await self?.updateSelection(for: setting, option: option) }
            },
            sliderAction: { [weak self] value in
                Task { await self?.updateSlider(for: setting, value: value) }
            }
        )
    }

    func updateSelection(for setting: SystemSetting, option: String) async {
        await update(setting: setting) { updated in
            updated.selectedOption = option
        }
    }

    func updateSlider(for setting: SystemSetting, value: Double) async {
        await update(setting: setting) { updated in
            updated.doubleValue = value
        }
    }

    private func updateToggle(for setting: SystemSetting, value: Bool) async {
        await update(setting: setting) { updated in
            updated.boolValue = value
        }
    }

    private func update(setting: SystemSetting, transform: (inout SystemSetting) -> Void) async {
        guard var current = settings[setting.id] else { return }
        let original = current
        transform(&current)
        settings[setting.id] = current
        categories = Self.group(settings: Array(settings.values))
        do {
            let saved = try await service.update(setting: current)
            settings[setting.id] = saved
            categories = Self.group(settings: Array(settings.values))
            errorMessage = nil
        } catch {
            settings[setting.id] = original
            categories = Self.group(settings: Array(settings.values))
            errorMessage = error.localizedDescription
        }
    }

    private static func group(settings: [SystemSetting]) -> [SystemSettingsCategory] {
        let grouped = Dictionary(grouping: settings) { $0.category }
        return grouped.keys.sorted().map { key in
            let settings = grouped[key]?.sorted(by: { $0.name < $1.name }) ?? []
            return SystemSettingsCategory(name: key, settings: settings)
        }
    }
}
