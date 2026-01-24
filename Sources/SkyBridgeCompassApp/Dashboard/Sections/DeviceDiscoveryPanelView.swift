import SwiftUI
import SkyBridgeCore
import os.log

/// 设备发现面板 - 仪表盘内嵌版本
@available(macOS 14.0, *)
public struct DeviceDiscoveryPanelView: View {
    @EnvironmentObject var appModel: DashboardViewModel
    @EnvironmentObject var themeConfiguration: ThemeConfiguration

    @Binding var deviceSearchText: String
    @Binding var filteredDevices: [DiscoveredDevice]
    @Binding var isSearching: Bool
    @Binding var showManualConnectSheet: Bool
    @Binding var extendedSearchCountdown: Int

    @State private var searchTask: Task<Void, Never>?
    @State private var showDiagnosticsPanel = false

    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "DeviceDiscoveryPanel")

    public init(
        deviceSearchText: Binding<String>,
        filteredDevices: Binding<[DiscoveredDevice]>,
        isSearching: Binding<Bool>,
        showManualConnectSheet: Binding<Bool>,
        extendedSearchCountdown: Binding<Int>
    ) {
        self._deviceSearchText = deviceSearchText
        self._filteredDevices = filteredDevices
        self._isSearching = isSearching
        self._showManualConnectSheet = showManualConnectSheet
        self._extendedSearchCountdown = extendedSearchCountdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(LocalizationManager.shared.localizedString("dashboard.deviceDiscovery"), systemImage: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(themeConfiguration.primaryTextColor)
                Spacer()

 // 添加扫描状态指示器
                if appModel.isScanning || UnifiedOnlineDeviceManager.shared.isScanning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(LocalizationManager.shared.localizedString("status.scanning"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 诊断按钮
                Button(action: { showDiagnosticsPanel.toggle() }) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help(LocalizationManager.shared.localizedString("discovery.diagnostics.title"))
                .popover(isPresented: $showDiagnosticsPanel, arrowEdge: .bottom) {
                    DiscoveryDiagnosticsView()
                        .frame(width: 450, height: 500)
                }
            }

            VStack(spacing: 16) {
 // 搜索栏和刷新按钮 - 优化版本
                HStack {
 // 将兼容更多设备、扩展搜索、手动连接移动到搜索框左侧
                    Toggle(LocalizationManager.shared.localizedString("discovery.compatibilityMode"), isOn: Binding(
                        get: { SettingsManager.shared.enableCompatibilityMode },
                        set: { SettingsManager.shared.enableCompatibilityMode = $0; appModel.triggerDiscoveryRefresh() }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption)

                    Button(action: {
                        appModel.triggerExtendedDiscovery(seconds: 15)
                        extendedSearchCountdown = 15
                        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
                        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
                        t.setEventHandler { [weak t] in
                            extendedSearchCountdown -= 1
                            if extendedSearchCountdown <= 0 { t?.cancel() }
                        }
                        t.resume()
                    }) {
                        Text(extendedSearchCountdown > 0 ? String(format: LocalizationManager.shared.localizedString("discovery.extendedSearch.active"), extendedSearchCountdown) : LocalizationManager.shared.localizedString("discovery.extendedSearch.default"))
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    Button(LocalizationManager.shared.localizedString("discovery.manualConnect")) { showManualConnectSheet = true }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField(LocalizationManager.shared.localizedString("discovery.searchPlaceholder"), text: $deviceSearchText)
                            .textFieldStyle(.plain)
                            .onChange(of: deviceSearchText) { _, newValue in
 // 防抖动搜索
                                searchTask?.cancel()
                                searchTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms 防抖
                                    if !Task.isCancelled {
                                        await filterDevices(with: newValue)
                                    }
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button(action: {
 // 异步刷新，避免阻塞UI
                        Task { @MainActor in
                            appModel.triggerDiscoveryRefresh()
                        }
                    }) {
                        Image(systemName: (appModel.isScanning || UnifiedOnlineDeviceManager.shared.isScanning) ? "stop.circle" : "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .rotationEffect(.degrees((appModel.isScanning || UnifiedOnlineDeviceManager.shared.isScanning) ? 0 : 360))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false),
                                     value: (appModel.isScanning || UnifiedOnlineDeviceManager.shared.isScanning))
                    }
                    .buttonStyle(.bordered)
                    .disabled(appModel.isScanning || UnifiedOnlineDeviceManager.shared.isScanning)
                }

 // 设备列表 - 虚拟化优化
                if filteredDevices.isEmpty {
                    EmptyStateView(
                        title: deviceSearchText.isEmpty ? LocalizationManager.shared.localizedString("dashboard.noDevicesFound") : LocalizationManager.shared.localizedString("discovery.noMatch"),
                        subtitle: deviceSearchText.isEmpty ?
                            LocalizationManager.shared.localizedString("dashboard.checkNetwork") :
                            LocalizationManager.shared.localizedString("discovery.adjustSearch")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredDevices, id: \.id) { device in
                                EnhancedDeviceRow(device: device) {
                                    Task { @MainActor in
                                        await connectToDevice(device)
                                    }
                                }
                                .transition(.asymmetric(
                                    insertion: .scale.combined(with: .opacity),
                                    removal: .opacity
                                ))
                            }
                        }
                        .animation(.easeInOut(duration: 0.3), value: filteredDevices.count)
                    }
                    .frame(maxHeight: 400) // 限制最大高度，启用滚动
                }
            }
        }
        .padding(20)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

 /// 异步过滤设备列表，支持名称、IP和服务搜索
    @MainActor
    private func filterDevices(with searchText: String) async {
        isSearching = true

        let filtered = await withTaskGroup(of: [DiscoveredDevice].self) { group in
            group.addTask { @MainActor in
                self.mapOnlineToDiscovered(self.appModel.onlineDevices)
            }

            var result: [DiscoveredDevice] = []
            for await devices in group {
                if searchText.isEmpty {
                    result = devices
                } else {
                    let lowercasedSearch = searchText.lowercased()
                    result = devices.filter { device in
                        device.name.lowercased().contains(lowercasedSearch) ||
                        (device.ipv4?.contains(lowercasedSearch) == true) ||
                        (device.ipv6?.contains(lowercasedSearch) == true) ||
                        device.services.contains { service in
                            service.lowercased().contains(lowercasedSearch)
                        }
                    }
                }
            }
            return result
        }

        filteredDevices = sortDevicesBySignalStrength(filtered)
        isSearching = false
    }

    @MainActor
    private func mapOnlineToDiscovered(_ online: [OnlineDevice]) -> [DiscoveredDevice] {
        online.map { od in
            DiscoveredDevice(
                id: od.id,
                name: od.name,
                ipv4: od.ipv4,
                ipv6: od.ipv6,
                services: od.services,
                portMap: od.portMap,
                connectionTypes: od.connectionTypes,
                uniqueIdentifier: od.uniqueIdentifier,
                signalStrength: nil,
                source: od.sources.first ?? .unknown,
                isLocalDevice: od.isLocalDevice,
                deviceId: nil,
                pubKeyFP: nil,
                macSet: od.macAddress.map { Set([$0]) } ?? []
            )
        }
    }

    private func sortDevicesBySignalStrength(_ devices: [DiscoveredDevice]) -> [DiscoveredDevice] {
        let settings = SettingsManager.shared
        guard settings.sortBySignalStrength else { return devices }
        func score(for d: DiscoveredDevice) -> Int {
            return Int(d.signalStrength ?? 0)
        }
        return devices.sorted { a, b in
            let sa = score(for: a)
            let sb = score(for: b)
            if sa != sb { return sa > sb }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    @MainActor
    private func connectToDevice(_ device: DiscoveredDevice) async {
        logger.info("正在连接到设备: \(device.name)")
        await appModel.connect(to: device)
        logger.info("连接设备操作完成: \(device.name)")
    }
}

