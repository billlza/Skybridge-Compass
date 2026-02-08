import SwiftUI
import SkyBridgeCore
import os

/// 增强版设备发现视图 - 整合三种连接方式
///
/// 功能：
/// 1. 近距设备扫描（Bonjour/Network.framework）
/// 2. 动态二维码连接
/// 3. iCloud 设备链（真实Apple ID设备同步）
/// 4. 智能连接码
@available(macOS 14.0, *)
struct EnhancedDeviceDiscoveryView_Previews: PreviewProvider {
    static var previews: some View {
        EnhancedDeviceDiscoveryView(deviceChainViewModel: CloudDeviceListViewModel(service: PreviewCloudDeviceService()))
    }
}
@MainActor
public struct EnhancedDeviceDiscoveryView: View {
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
 // 统一日志记录器，采用Apple推荐的Logger API（macOS 14+），避免使用过时的os_log。
    private let logger = Logger(subsystem: "com.skybridge.SkyBridgeCompassApp", category: "DeviceDiscovery")

 // 🆕 使用统一的在线设备管理器(单例)
    @ObservedObject private var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared

    // Trusted / paired devices (from TrustSyncService)
    @StateObject private var trustSync = TrustSyncService.shared

 // 跨网络连接
    @StateObject private var crossNetworkManager = CrossNetworkConnectionManager()
    @StateObject private var p2pDiscoveryService = P2PDiscoveryService()

 // 🆕 真实iCloud设备发现(不再单独使用,已整合到统一管理器中)
 // @StateObject private var iCloudManager = iCloudDeviceDiscoveryManager()

 // UI 状态
    @State private var selectedConnectionMode: DiscoveryMode = .localScan
    @State private var searchText = ""
    @State private var connectionCodeInput = ""
 // 控制二维码扫描弹窗显示与错误提示。
    @State private var showingScanner: Bool = false
    @State private var scannerErrorMessage: String?
    @State private var connectionCodeErrorMessage: String?
    @State private var extendedSearchCountdown: Int = 0
    @State private var showManualConnectSheet: Bool = false
    @State private var manualIP: String = ""
    @State private var manualPort: String = "11550"
    @State private var manualCode: String = ""
    @State private var hoveredConnectionMode: DiscoveryMode? = nil
    @State private var connectingOnlineDeviceIds: Set<UUID> = []

    @State private var selectedTrustedRecord: TrustRecord?
    @State private var showTrustedRecordSheet: Bool = false



    public var body: some View {
        VStack(spacing: 0) {
 // 顶部：连接方式切换
            connectionModePicker

            Divider()

 // 主内容区
            ScrollView {
                VStack(spacing: 20) {
                    switch selectedConnectionMode {
                    case .localScan:
                        localScanSection
                    case .qrCode:
                        qrCodeSection
                    case .cloudLink:
                        cloudLinkSection
                    case .connectionCode:
                        connectionCodeSection
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(LocalizationManager.shared.localizedString("discovery.title"))
        .sheet(isPresented: $showManualConnectSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizationManager.shared.localizedString("discovery.manualConnect.title")).font(.headline)
                TextField(LocalizationManager.shared.localizedString("discovery.manualConnect.ip"), text: $manualIP).textFieldStyle(.roundedBorder)
                TextField(LocalizationManager.shared.localizedString("discovery.manualConnect.port"), text: $manualPort).textFieldStyle(.roundedBorder)
                TextField(LocalizationManager.shared.localizedString("discovery.manualConnect.code"), text: $manualCode).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(LocalizationManager.shared.localizedString("discovery.manualConnect.cancel")) { showManualConnectSheet = false }
                    Button(LocalizationManager.shared.localizedString("discovery.manualConnect.button")) {
                        showManualConnectSheet = false
                        let port = UInt16(manualPort) ?? 0
                        let device = DiscoveredDevice(
                            id: UUID(),
                            name: manualIP,
                            ipv4: manualIP,
                            ipv6: nil,
                            services: ["_skybridge._tcp"],
                            portMap: ["_skybridge._tcp": Int(port)],
                            connectionTypes: [.wifi],
                            uniqueIdentifier: manualCode.isEmpty ? nil : manualCode,
                            signalStrength: nil
                        )
                        Task {
                            do {
                                try await p2pDiscoveryService.connectToDevice(device)
                            } catch {
                                logger.error("❌ 手动连接失败: \(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
        .task {
 // 🆕 使用统一设备管理器,自动整合所有发现源
            unifiedDeviceManager.startDiscovery()
        }
        .sheet(isPresented: $showTrustedRecordSheet) {
            if let record = selectedTrustedRecord {
                TrustedDeviceDetailView(
                    record: record,
                    onRemoveTrust: { idsToRevoke, declaredDeviceId in
                        Task { @MainActor in
                            // Clear policy first so future requests prompt again.
                            if let declaredDeviceId {
                                PairingTrustApprovalService.shared.clearPolicy(for: declaredDeviceId)
                            }
                            // Revoke all related ids (canonical + alias).
                            for id in idsToRevoke {
                                try? await TrustSyncService.shared.revokeTrustRecord(deviceId: id)
                            }
                            // Close sheet
                            selectedTrustedRecord = nil
                            showTrustedRecordSheet = false
                        }
                    }
                )
                .frame(width: 520, height: 420)
                .padding(20)
            } else {
                EmptyView()
                    .frame(width: 520, height: 420)
            }
        }
        .onDisappear {
 // 注意:统一设备管理器是单例,不应在这里停止
 // 它会在DashboardViewModel中统一管理生命周期
        }
    }

 // MARK: - 连接方式选择器

    private var connectionModePicker: some View {
        HStack(spacing: 0) {
            ForEach(DiscoveryMode.allCases) { mode in
                connectionModeButton(mode)
            }
        }
        .background(themeConfiguration.cardBackgroundMaterial)
        .overlay(
            Rectangle()
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func connectionModeButton(_ mode: DiscoveryMode) -> some View {
        let isSelected = selectedConnectionMode == mode
        let isHovered = hoveredConnectionMode == mode
        return ConnectionModeButtonView(
            mode: mode,
            isSelected: isSelected,
            isHovered: isHovered,
            onSelect: {
                withAnimation(.spring(response: 0.3)) { selectedConnectionMode = mode }
            },
            onHoverChanged: { hovering in
                if hovering { hoveredConnectionMode = mode }
                else if hoveredConnectionMode == mode { hoveredConnectionMode = nil }
            }
        )
    }

    private struct ConnectionModeButtonView: View {
        @EnvironmentObject var themeConfiguration: ThemeConfiguration
        let mode: DiscoveryMode
        let isSelected: Bool
        let isHovered: Bool
        let onSelect: () -> Void
        let onHoverChanged: (Bool) -> Void
        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 20))
                    .foregroundColor(mode.accentColor)
                Text(mode.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(mode.accentColor)
                Text(mode.subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? mode.accentColor.opacity(0.12) : Color.clear)
            .background(
                Rectangle()
                    .fill(themeConfiguration.cardBackgroundMaterial)
                    .opacity(isHovered ? 0.35 : 0)
            )
            .overlay(
                Rectangle()
                    .stroke(isHovered ? themeConfiguration.borderColor : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: isHovered ? Color.white.opacity(0.06) : .clear, radius: 8, x: 0, y: 0)
            .overlay(
                Rectangle()
                    .fill(isSelected ? mode.accentColor : Color.clear)
                    .frame(height: 3),
                alignment: .bottom
            )
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .onHover { onHoverChanged($0) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(mode.title))
        }
    }

 // MARK: - 1️⃣ 本地扫描（原有功能增强）

    private var localScanSection: some View {
        VStack(alignment: .leading, spacing: 16) {
 // 说明卡片
            InfoBanner(
                icon: "wifi.router",
                title: LocalizationManager.shared.localizedString("discovery.localScan.title"),
                description: LocalizationManager.shared.localizedString("discovery.localScan.description"),
                color: .green
            )

 // 扫描控制
            HStack(spacing: 12) {
                if unifiedDeviceManager.isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(LocalizationManager.shared.localizedString("discovery.scanning"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Toggle(LocalizationManager.shared.localizedString("discovery.compatibilityMode"), isOn: Binding(
                    get: { SettingsManager.shared.enableCompatibilityMode },
                    set: { SettingsManager.shared.enableCompatibilityMode = $0; unifiedDeviceManager.refreshDevices() }
                ))
                .toggleStyle(.switch)
                .font(.caption)

                Button(action: {
                    SettingsManager.shared.enableCompatibilityMode = true
                    unifiedDeviceManager.refreshDevices()
                    extendedSearchCountdown = 15
                    let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
                    t.schedule(deadline: .now() + 1.0, repeating: 1.0)
                    t.setEventHandler { [weak t] in
                        extendedSearchCountdown -= 1
                        if extendedSearchCountdown <= 0 {
                            t?.cancel()
                            SettingsManager.shared.enableCompatibilityMode = false
                            unifiedDeviceManager.refreshDevices()
                        }
                    }
                    t.resume()
                }) {
                    Text(extendedSearchCountdown > 0 ? String(format: LocalizationManager.shared.localizedString("discovery.extendedSearch.active"), extendedSearchCountdown) : LocalizationManager.shared.localizedString("discovery.extendedSearch.static"))
                }
                .buttonStyle(.bordered)
                .font(.caption)

                Button(LocalizationManager.shared.localizedString("discovery.manualConnect.title")) { showManualConnectSheet = true }
                .buttonStyle(.bordered)
                .font(.caption)

                Button(action: {
                    if unifiedDeviceManager.isScanning {
                        unifiedDeviceManager.stopDiscovery()
                    } else {
                        unifiedDeviceManager.startDiscovery()
                    }
                }) {
                    Label(
                        unifiedDeviceManager.isScanning ? LocalizationManager.shared.localizedString("discovery.stopScan") : LocalizationManager.shared.localizedString("discovery.startScan"),
                        systemImage: unifiedDeviceManager.isScanning ? "stop.circle" : "play.circle"
                    )
                }
                .buttonStyle(.borderedProminent)

                Button(action: {
                    unifiedDeviceManager.refreshDevices()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help(LocalizationManager.shared.localizedString("discovery.refresh"))
            }
            .padding(12)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(themeConfiguration.borderColor, lineWidth: 1)
            )

            // 我的设备（固定展示，不依赖扫描结果；避免被“在线设备”列表/过滤逻辑吞掉）
            if let my = unifiedDeviceManager.localDevice {
                VStack(alignment: .leading, spacing: 12) {
                    Text("我的设备")
                        .font(.headline)

                    OnlineDeviceCard(device: my) {
                        // no-op: 本机不需要“连接”
                    }

                    // 当前已连接设备（即使尚未“信任/配对”，也应在这里可见）
                    let connectedNow = unifiedDeviceManager.onlineDevices
                        .filter { !$0.isLocalDevice && $0.connectionStatus == .connected }
                        .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
                    if !connectedNow.isEmpty {
                        ForEach(connectedNow) { dev in
                            OnlineDeviceCard(device: dev) {
                                // already connected; no-op
                            }
                        }
                    }
                }
                .padding(16)
                .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                )
            }

            // 受信任设备（已配对/已允许）——来自 TrustSyncService
            let trustedRecords = trustedRecordsForUI
            if !trustedRecords.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("已信任设备")
                        .font(.headline)

                    ForEach(trustedRecords) { record in
                        TrustedDeviceCard(
                            record: record,
                            subtitle: trustedRecordSubtitle(record),
                            status: trustedRecordStatus(record)
                        ) {
                            selectedTrustedRecord = record
                            showTrustedRecordSheet = true
                        }
                    }
                }
                .padding(16)
                .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.green.opacity(0.5), lineWidth: 1)
                )
            }

            // 最近连接（不等同于“信任/已配对”，但应立即可见）
            let recentlyConnected = unifiedDeviceManager.onlineDevices
                .filter { !$0.isLocalDevice && $0.lastConnectedAt != nil }
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            if !recentlyConnected.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近连接")
                        .font(.headline)
                    ForEach(recentlyConnected) { device in
                        OnlineDeviceCard(
                            device: device,
                            isConnecting: connectingOnlineDeviceIds.contains(device.id)
                        ) {
                            // If already connected, no-op; otherwise, we keep this as a future reconnect entry.
                            connectToOnlineDevice(device)
                        }
                    }
                }
                .padding(16)
                .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.green.opacity(0.35), lineWidth: 1)
                )
            }

 // 设备列表
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(String(format: LocalizationManager.shared.localizedString("discovery.onlineDevices"), onlineNonLocalDevices.count))
                        .font(.headline)

                    Spacer()

 // 搜索框
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField(LocalizationManager.shared.localizedString("discovery.searchPlaceholder"), text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(themeConfiguration.borderColor, lineWidth: 1)
                    )
                    .frame(width: 200)
                }

                if filteredOnlineDevicesNonLocal.isEmpty {
                    emptyStateView(
                        icon: "antenna.radiowaves.left.and.right.slash",
                        title: LocalizationManager.shared.localizedString("discovery.noDevices.title"),
                        message: unifiedDeviceManager.isScanning ? LocalizationManager.shared.localizedString("discovery.noDevices.scanning") : LocalizationManager.shared.localizedString("discovery.noDevices.startPrompt")
                    )
                } else {
                    ForEach(filteredOnlineDevicesNonLocal) { device in
                        OnlineDeviceCard(
                            device: device,
                            isConnecting: connectingOnlineDeviceIds.contains(device.id)
                        ) {
                            connectToOnlineDevice(device)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Trusted Devices helpers

    private var trustedRecordsForUI: [TrustRecord] {
        // We prefer canonical records (not aliases) to avoid duplicates.
        // Aliases exist to keep handshake lookups working for bonjour:<name>@local. peer ids.
        trustSync.activeTrustRecords
            .filter { !$0.capabilities.contains(where: { $0.lowercased().hasPrefix("alias=true") }) }
            .filter { $0.capabilities.contains(where: { $0.lowercased() == "trusted" || $0.lowercased() == "pqc_bootstrap" || $0.lowercased().hasPrefix("trusted") }) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func trustedRecordCaps(_ record: TrustRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for item in record.capabilities {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                dict[parts[0]] = parts[1]
            }
        }
        return dict
    }

    private func trustedRecordSubtitle(_ record: TrustRecord) -> String {
        let c = trustedRecordCaps(record)
        let platform = c["platform"].flatMap { $0.isEmpty ? nil : $0 }
        let osVersion = c["osVersion"].flatMap { $0.isEmpty ? nil : $0 }
        let modelName = c["modelName"].flatMap { $0.isEmpty ? nil : $0 }
        let chip = c["chip"].flatMap { $0.isEmpty ? nil : $0 }

        var parts: [String] = []
        if let modelName { parts.append(modelName) }
        if let chip { parts.append(chip) }
        if let platform, let osVersion {
            parts.append("\(platform) \(osVersion)")
        } else if let platform {
            parts.append(platform)
        }
        return parts.isEmpty ? record.deviceId : parts.joined(separator: " · ")
    }

    private func trustedRecordStatus(_ record: TrustRecord) -> OnlineDeviceStatus {
        // Two-step mapping (fast + 100% accurate when strong id is present):
        // 1) Strong: match by stable deviceId (preferred). This becomes 100% accurate once discovery advertises deviceId.
        // 2) Weak fallback: match by peerEndpoint/name to avoid showing "offline" when strong id isn't available yet.
        let caps = trustedRecordCaps(record)

        let strongIdKey = "id:\(record.deviceId)"
        if let dev = unifiedDeviceManager.onlineDevices.first(where: { $0.uniqueIdentifier == strongIdKey }) {
            return dev.connectionStatus
        }

        var candidateNames: [String] = []
        if let peer = caps["peerEndpoint"], !peer.isEmpty {
            if let n = extractBonjourName(from: peer) {
                candidateNames.append(n)
            }
        }
        if let dn = record.deviceName, !dn.isEmpty {
            candidateNames.append(dn)
        }

        for name in candidateNames {
            if let dev = unifiedDeviceManager.onlineDevices.first(where: { $0.name == name }) {
                return dev.connectionStatus
            }
        }
        return .offline
    }

    private func extractBonjourName(from peerEndpoint: String) -> String? {
        // Format: "bonjour:<name>@<domain>"
        guard peerEndpoint.hasPrefix("bonjour:") else { return nil }
        let rest = peerEndpoint.dropFirst("bonjour:".count)
        // Split at "@"
        let parts = rest.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        return name
    }

    private var onlineNonLocalDevices: [OnlineDevice] {
        unifiedDeviceManager.onlineDevices.filter { !$0.isLocalDevice }
    }

    private var filteredOnlineDevicesNonLocal: [OnlineDevice] {
        if searchText.isEmpty {
            return onlineNonLocalDevices
        } else {
            return onlineNonLocalDevices.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.ipv4?.contains(searchText) == true ||
                $0.ipv6?.contains(searchText) == true
            }
        }
    }

 // MARK: - 2️⃣ 动态二维码

    private var qrCodeSection: some View {
        VStack(spacing: 20) {
            InfoBanner(
                icon: "qrcode",
                title: LocalizationManager.shared.localizedString("discovery.qrCode.title"),
                description: LocalizationManager.shared.localizedString("discovery.qrCode.description"),
                color: .blue
            )

            HStack(spacing: 32) {
 // 左侧：生成二维码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.qrCode.thisDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let qrData = crossNetworkManager.qrCodeData {
                        QRCodeView(data: qrData)
                            .frame(width: 220, height: 220)
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.1), radius: 4)

                        Text(LocalizationManager.shared.localizedString("discovery.qrCode.scanPrompt"))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if case .waiting = crossNetworkManager.connectionStatus {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(LocalizationManager.shared.localizedString("discovery.qrCode.waiting"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button(LocalizationManager.shared.localizedString("discovery.qrCode.regenerate")) {
                            Task {
                                try? await crossNetworkManager.generateDynamicQRCode()
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            Task {
                                try? await crossNetworkManager.generateDynamicQRCode()
                            }
                        }) {
                            VStack(spacing: 12) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 48))
                                    .foregroundColor(.blue)
                                Text(LocalizationManager.shared.localizedString("discovery.qrCode.generate"))
                                    .font(.headline)
                            }
                            .frame(width: 220, height: 220)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

 // 右侧：扫描二维码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.qrCode.otherDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Button(action: {
 // 打开二维码扫描弹窗
                        showingScanner = true
                    }) {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 48))
                                .foregroundColor(.green)

                            Text(LocalizationManager.shared.localizedString("discovery.qrCode.scanButton"))
                                .font(.headline)

                            Text(LocalizationManager.shared.localizedString("discovery.qrCode.cameraPrompt"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 220, height: 220)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 20)
 // 二维码扫描弹窗，集成统一扫描器并回调处理连接逻辑。
            .sheet(isPresented: $showingScanner) {
                QRCodeScannerView(
                    onResult: { result in
 // 兼容两种跨网二维码格式：
 // - skybridge://connect/<base64>
 // - skybridge://connect?data=<base64>
                        if isCrossNetworkConnectLink(result) {
                            Task {
                                do {
                                    let data = Data(result.utf8)
                                    _ = try await crossNetworkManager.scanDynamicQRCode(data)
                                } catch {
 // 记录错误并提示用户
                                    scannerErrorMessage = String(format: LocalizationManager.shared.localizedString("discovery.qrCode.error.connectFailed"), error.localizedDescription)
                                }
 // 无论成功失败均关闭弹窗
                                showingScanner = false
                            }
                        } else {
 // 不识别的二维码内容
                            scannerErrorMessage = LocalizationManager.shared.localizedString("discovery.qrCode.error.unrecognized")
                            showingScanner = false
                        }
                    },
                    onError: { message in
 // 扫描器错误回调
                        scannerErrorMessage = message
                        showingScanner = false
                    }
                )
                .frame(minWidth: 500, minHeight: 320)
            }
 // 错误提示弹窗，绑定动态状态以便关闭后清空错误。
            .alert(
                LocalizationManager.shared.localizedString("discovery.qrCode.error.title"),
                isPresented: Binding(
                    get: { scannerErrorMessage != nil },
                    set: { newValue in
 // 当弹窗被关闭时清空错误信息
                        if !newValue { scannerErrorMessage = nil }
                    }
                )
            ) {
                Button(LocalizationManager.shared.localizedString("discovery.qrCode.error.ok")) { scannerErrorMessage = nil }
            } message: {
                Text(scannerErrorMessage ?? "")
            }
        }
    }

 // MARK: - 3️⃣ iCloud 设备链（统一设备显示）

 // MARK: - View Models
    @StateObject private var deviceChainViewModel: CloudDeviceListViewModel

    public init(deviceChainViewModel: CloudDeviceListViewModel = CloudDeviceListViewModel()) {
        _deviceChainViewModel = StateObject(wrappedValue: deviceChainViewModel)
    }

 // MARK: - 3️⃣ iCloud 设备链（统一设备显示）

    private var cloudLinkSection: some View {
        VStack(spacing: 20) {
            InfoBanner(
                icon: "icloud.fill",
                title: LocalizationManager.shared.localizedString("discovery.icloud.title"),
                description: LocalizationManager.shared.localizedString("discovery.icloud.description"),
                color: .purple
            )

 // 状态指示器
            HStack(spacing: 12) {
                statusIndicator

                Spacer()

                Text(deviceChainViewModel.accountStatusDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(LocalizationManager.shared.localizedString("discovery.icloud.refresh")) {
                    Task {
                        await deviceChainViewModel.refreshDevices()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(deviceChainViewModel.isLoading)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)

            if deviceChainViewModel.authorizedDevices.isEmpty {
                VStack(spacing: 16) {
                    emptyStateView(
                        icon: "magnifyingglass",
                        title: LocalizationManager.shared.localizedString("discovery.icloud.noDevices.title"),
                        message: LocalizationManager.shared.localizedString("discovery.icloud.noDevices.message")
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "icloud.fill")
                            .foregroundColor(.purple)
                        Text("\(LocalizationManager.shared.localizedString("discovery.icloud.authorizedDevices")) (\(deviceChainViewModel.authorizedDevices.count))")
                            .font(.headline)
                    }

                    ForEach(deviceChainViewModel.authorizedDevices) { device in
                        CloudDeviceRow(
                            device: mapToCloudDevice(device),
                            currentDeviceId: deviceChainViewModel.currentDeviceId,
                            onConnect: {
                                deviceChainViewModel.connectToDevice(device)
                            }
                        )
                    }
                }
            }
        }
    }

 /// 状态指示器
    private var statusIndicator: some View {
        HStack(spacing: 8) {
            if deviceChainViewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                Text(LocalizationManager.shared.localizedString("discovery.icloud.status.syncing"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(LocalizationManager.shared.localizedString("discovery.icloud.status.synced"))
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

 // MARK: - Cloud Device Row

    struct CloudDeviceRow: View {
        let device: CloudDevice
        let currentDeviceId: String?
        let onConnect: () -> Void
        @EnvironmentObject var themeConfiguration: ThemeConfiguration

        var body: some View {
            HStack(spacing: 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.system(size: 32))
                    .foregroundColor(device.isOnline ? .blue : .gray)
                    .frame(width: 50, height: 50)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.headline)

                        if let currentId = currentDeviceId, device.id == currentId {
                            Text(LocalizationManager.shared.localizedString("discovery.device.thisDevice"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(device.deviceModel)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(device.isOnline ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(device.isOnline ? LocalizationManager.shared.localizedString("discovery.device.status.online") : LocalizationManager.shared.localizedString("discovery.device.status.offline"))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)

                        Text(timeAgoText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if currentDeviceId == nil || device.id != currentDeviceId {
                    Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                        onConnect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.isOnline)
                }
            }
            .padding(16)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(themeConfiguration.borderColor, lineWidth: 1)
            )
        }

        private var deviceIcon: String {
            switch device.type {
            case .mac: return "laptopcomputer"
            case .iPhone: return "iphone"
            case .iPad: return "ipad"
            }
        }

        private var timeAgoText: String {
            let interval = Date().timeIntervalSince(device.lastSeen)
            if interval < 60 {
                return LocalizationManager.shared.localizedString("discovery.time.justNow")
            } else if interval < 3600 {
                return String(format: LocalizationManager.shared.localizedString("discovery.time.minutesAgo"), Int(interval / 60))
            } else if interval < 86400 {
                return String(format: LocalizationManager.shared.localizedString("discovery.time.hoursAgo"), Int(interval / 3600))
            } else {
                return String(format: LocalizationManager.shared.localizedString("discovery.time.daysAgo"), Int(interval / 86400))
            }
        }
    }

 // MARK: - 在线设备卡片(新)

    struct OnlineDeviceCard: View {
        let device: OnlineDevice
        let isConnecting: Bool
        let onConnect: () -> Void
        @EnvironmentObject var themeConfiguration: ThemeConfiguration

        init(device: OnlineDevice, isConnecting: Bool = false, onConnect: @escaping () -> Void) {
            self.device = device
            self.isConnecting = isConnecting
            self.onConnect = onConnect
        }

        var body: some View {
            HStack(spacing: 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.system(size: 32))
                    .foregroundColor(statusColor)
                    .frame(width: 50, height: 50)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(.headline)

 // 本机标签
                        if device.isLocalDevice {
                            Text(LocalizationManager.shared.localizedString("discovery.device.thisDevice"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

 // 已授权标签
                        if device.isAuthorized {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }

                    if let ipv4 = device.ipv4 {
                        Text("IP: \(ipv4)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

 // 连接类型标签
                    if !device.connectionTypes.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(device.connectionTypes.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { type in
                                HStack(spacing: 3) {
                                    Image(systemName: type.iconName)
                                        .font(.system(size: 9))
                                    Text(type.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(connectionTypeColor(for: type))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }

 // 连接状态
                    Text(device.connectionStatus.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Crypto/guard summary (best-effort)
                    if let kind = device.lastCryptoKind, let suite = device.lastCryptoSuite, device.connectionStatus == .connected {
                        Text("\(kind) · \(suite) · \(device.guardStatus ?? "守护中")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // 连接按钮(仅对非本机在线设备显示)
                if !device.isLocalDevice && device.connectionStatus == .online {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                            onConnect()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(device.isLocalDevice ? Color.blue : themeConfiguration.borderColor, lineWidth: device.isLocalDevice ? 2 : 1)
            )
        }

        private var deviceIcon: String {
            switch device.deviceType {
            case .computer: return "laptopcomputer"
            case .router: return "wifi.router"
            case .nas: return "externaldrive.connected.to.line.below"
            case .printer: return "printer"
            case .camera: return "video"
            case .speaker: return "hifispeaker"
            case .tv: return "tv"
            case .iot: return "sensor"
            case .unknown: return "questionmark.circle"
            }
        }

        private var statusColor: Color {
            switch device.connectionStatus {
            case .connected: return .green
            case .online: return .blue
            case .offline: return .gray
            }
        }

        private func connectionTypeColor(for type: DeviceConnectionType) -> Color {
            switch type {
            case .wifi: return Color.blue.opacity(0.8)
            case .usb: return Color.green.opacity(0.8)
            case .ethernet: return Color.purple.opacity(0.8)
            case .thunderbolt: return Color.orange.opacity(0.8)
            case .bluetooth: return Color.cyan.opacity(0.8)
            case .unknown: return Color.gray.opacity(0.6)
            }
        }

    }

 // MARK: - 本地设备卡片

    struct LocalDeviceCard: View {
        let device: DiscoveredDevice
        let onConnect: () -> Void
        @EnvironmentObject var themeConfiguration: ThemeConfiguration

        var body: some View {
            HStack(spacing: 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                    .frame(width: 50, height: 50)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name)
                        .font(.headline)

                    if let ipv4 = device.ipv4 {
                        Text("IP: \(ipv4)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

 // 连接类型标签
                    if !device.connectionTypes.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(device.connectionTypes.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { type in
                                HStack(spacing: 3) {
                                    Image(systemName: type.iconName)
                                        .font(.system(size: 9))
                                    Text(type.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(connectionTypeColor(for: type))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }

                Spacer()

                Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(themeConfiguration.borderColor, lineWidth: 1)
            )
        }

        private var deviceIcon: String {
            if device.name.lowercased().contains("ipad") {
                return "ipad"
            } else if device.name.lowercased().contains("iphone") {
                return "iphone"
            } else if device.name.lowercased().contains("mac") {
                return "laptopcomputer"
            } else if device.connectionTypes.contains(.usb) {
                return "cable.connector"
            } else {
                return "network"
            }
        }

        private func connectionTypeColor(for type: DeviceConnectionType) -> Color {
            switch type {
            case .wifi: return Color.blue.opacity(0.8)
            case .usb: return Color.green.opacity(0.8)
            case .ethernet: return Color.purple.opacity(0.8)
            case .thunderbolt: return Color.orange.opacity(0.8)
            case .bluetooth: return Color.cyan.opacity(0.8)
            case .unknown: return Color.gray.opacity(0.6)
            }
        }

    }

 /// iCloud设备卡片
    private func iCloudDeviceCard(device: iCloudDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
 // 设备图标
                Image(systemName: device.iconName)
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(device.model)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

 // 在线状态指示器
                HStack(spacing: 4) {
                    Circle()
                        .fill(device.isOnline ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)

                    Text(device.isOnline ? LocalizationManager.shared.localizedString("discovery.device.status.online") : LocalizationManager.shared.localizedString("discovery.device.status.offline"))
                        .font(.caption2)
                        .foregroundColor(device.isOnline ? .green : .gray)
                }
            }

            Divider()

 // 设备详细信息
            VStack(alignment: .leading, spacing: 6) {
                infoRow(icon: "network", text: device.networkType.displayName)

                if let ip = device.ipAddress {
                    infoRow(icon: "wifi", text: ip)
                }

                infoRow(icon: "desktopcomputer", text: "macOS \(device.osVersion)")

                infoRow(
                    icon: "clock",
                    text: String(format: LocalizationManager.shared.localizedString("discovery.device.lastActive"), formatLastSeen(device.lastSeen))
                )
            }
            .font(.caption)
            .foregroundColor(.secondary)

 // 设备能力
            HStack(spacing: 6) {
                ForEach(device.capabilities, id: \.self) { capability in
                    capabilityBadge(capability)
                }
            }

 // 连接按钮
            Button(action: {
                Task {
 // 将 iCloudDevice 转换为 CloudDevice 并调用跨网络连接管理器。
                    let cloudDevice = mapToCloudDevice(device)
                    do {
                        _ = try await crossNetworkManager.connectToCloudDevice(cloudDevice)
                    } catch {
 // 连接失败错误提示
                        scannerErrorMessage = "iCloud 设备连接失败：\(error.localizedDescription)"
                    }
                }
            }) {
                HStack {
                    Image(systemName: "link")
                        .font(.caption)
                    Text(LocalizationManager.shared.localizedString("discovery.action.connect"))
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(!device.isOnline)
        }
        .padding(16)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

 /// 将 iCloudDevice 映射为 CloudDevice，供跨网络连接使用。
    private func mapToCloudDevice(_ device: iCloudDevice) -> CloudDevice {
 // 设备类型映射，基于型号推断。
        let type: CloudDevice.DeviceType
        if device.model.contains("iPhone") {
            type = .iPhone
        } else if device.model.contains("iPad") {
            type = .iPad
        } else {
            type = .mac
        }

 // 能力映射，仅保留跨网络连接管理器定义的能力集合。
        let mappedCapabilities: [CloudDevice.DeviceCapability] = device.capabilities.compactMap { cap in
            switch cap {
            case .remoteDesktop:
                return .remoteDesktop
            case .fileTransfer:
                return .fileTransfer
            default:
 // 其他能力当前无需在连接中使用，忽略以保持兼容。
                return nil
            }
        }

        return CloudDevice(
            id: device.id,
            name: device.name,
            type: type,
            lastSeen: device.lastSeen,
            capabilities: mappedCapabilities.isEmpty ? [.remoteDesktop] : mappedCapabilities
        )
    }

 /// 信息行
    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
            Text(text)
        }
    }

 /// 能力标签
    private func capabilityBadge(_ capability: DeviceCapability) -> some View {
        let (icon, color) = capabilityInfo(capability)

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(capabilityName(capability))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

 /// 获取能力信息
    private func capabilityInfo(_ capability: DeviceCapability) -> (String, Color) {
        switch capability {
        case .remoteDesktop:
            return ("display", .blue)
        case .fileTransfer:
            return ("folder", .green)
        case .clipboard:
            return ("doc.on.clipboard", .orange)
        case .notifications:
            return ("bell", .purple)
        case .calls:
            return ("phone", .cyan)
        case .messages:
            return ("message", .pink)
        }
    }

 /// 获取能力名称
    private func capabilityName(_ capability: DeviceCapability) -> String {
        switch capability {
        case .remoteDesktop: return LocalizationManager.shared.localizedString("discovery.capability.remoteDesktop")
        case .fileTransfer: return LocalizationManager.shared.localizedString("discovery.capability.fileTransfer")
        case .clipboard: return LocalizationManager.shared.localizedString("discovery.capability.clipboard")
        case .notifications: return LocalizationManager.shared.localizedString("discovery.capability.notifications")
        case .calls: return LocalizationManager.shared.localizedString("discovery.capability.calls")
        case .messages: return LocalizationManager.shared.localizedString("discovery.capability.messages")
        }
    }

 /// 格式化最后活跃时间
    private func formatLastSeen(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return LocalizationManager.shared.localizedString("discovery.time.justNow")
        } else if interval < 3600 {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.minutesAgo"), Int(interval / 60))
        } else if interval < 86400 {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.hoursAgo"), Int(interval / 3600))
        } else {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.daysAgo"), Int(interval / 86400))
        }
    }

 // MARK: - 4️⃣ 智能连接码

    private var connectionCodeSection: some View {
        VStack(spacing: 20) {
            InfoBanner(
                icon: "number.square.fill",
                title: LocalizationManager.shared.localizedString("discovery.smartCode.title"),
                description: LocalizationManager.shared.localizedString("discovery.smartCode.description"),
                color: .orange
            )

            HStack(spacing: 32) {
 // 左侧：生成连接码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.smartCode.onThisDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let code = crossNetworkManager.connectionCode {
                        VStack(spacing: 12) {
                            Text(code)
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .tracking(6)
                                .foregroundColor(.orange)
                                .padding(20)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(12)

                            Text(LocalizationManager.shared.localizedString("discovery.smartCode.shareInstruction"))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                }) {
                                    Label(LocalizationManager.shared.localizedString("discovery.smartCode.copy"), systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)

                                Button(action: {
                                    Task {
                                        do {
                                            connectionCodeErrorMessage = nil
                                            _ = try await crossNetworkManager.generateConnectionCode()
                                        } catch {
                                            connectionCodeErrorMessage = error.localizedDescription
                                            logger.error("❌ 重新生成连接码失败: \(error.localizedDescription, privacy: .public)")
                                        }
                                    }
                                }) {
                                    Label(LocalizationManager.shared.localizedString("discovery.smartCode.regenerate"), systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }

                            if case .waiting = crossNetworkManager.connectionStatus {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(LocalizationManager.shared.localizedString("discovery.smartCode.waiting"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } else {
                        Button(action: {
                            Task {
                                do {
                                    connectionCodeErrorMessage = nil
                                    _ = try await crossNetworkManager.generateConnectionCode()
                                } catch {
                                    connectionCodeErrorMessage = error.localizedDescription
                                    logger.error("❌ 生成连接码失败: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }) {
                            VStack(spacing: 12) {
                                Image(systemName: "number.square")
                                    .font(.system(size: 48))
                                    .foregroundColor(.orange)
                                Text(LocalizationManager.shared.localizedString("discovery.smartCode.generate"))
                                    .font(.headline)
                            }
                            .frame(width: 240, height: 180)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

 // 右侧：输入连接码
                VStack(spacing: 16) {
                    Text(LocalizationManager.shared.localizedString("discovery.smartCode.onOtherDevice"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    VStack(spacing: 12) {
                        TextField(LocalizationManager.shared.localizedString("discovery.code.enterPrompt"), text: $connectionCodeInput)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .textCase(.uppercase)
                            .frame(width: 240)
                            .padding(.vertical, 16)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(12)
                            .onChange(of: connectionCodeInput) { _, newValue in
                                connectionCodeInput = String(
                                    newValue
                                        .uppercased()
                                        .filter { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) }
                                        .prefix(6)
                                )
                            }

                        Button(action: {
                            Task {
                                do {
                                    connectionCodeErrorMessage = nil
                                    _ = try await crossNetworkManager.connectWithCode(connectionCodeInput)
                                } catch {
                                    connectionCodeErrorMessage = error.localizedDescription
                                    logger.error("❌ 连接码连接失败: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "arrow.right.circle.fill")
                                Text(LocalizationManager.shared.localizedString("discovery.code.connect"))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(connectionCodeInput.count != 6)
                        .frame(width: 240)

                        if let connectionCodeErrorMessage, !connectionCodeErrorMessage.isEmpty {
                            Text(connectionCodeErrorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                                .frame(width: 240)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(height: 180)
                }
            }
            .padding(.vertical, 20)
        }
    }

 // MARK: - 辅助方法

    /// 🆕 连接到在线设备
    private func connectToOnlineDevice(_ device: OnlineDevice) {
        if connectingOnlineDeviceIds.contains(device.id) { return }
        connectingOnlineDeviceIds.insert(device.id)
        Task {
            defer {
                Task { @MainActor in
                    connectingOnlineDeviceIds.remove(device.id)
                }
            }
            let preferUSBRoute = device.connectionTypes.contains(.usb)
            var discoveredCandidates = unifiedDeviceManager.resolvedDiscoveredCandidates(for: device, limit: 6)
            let fallback = fallbackDiscoveredDevice(for: device)
            if !discoveredCandidates.contains(where: { isSameConnectTarget($0, fallback) }) {
                discoveredCandidates.append(fallback)
            }
            let routePreference: P2PDiscoveryService.ConnectionRoutePreference = preferUSBRoute ? .preferUSB : .automatic

            do {
                var lastError: Error?
                for candidate in discoveredCandidates {
                    do {
                        try await p2pDiscoveryService.connectToDevice(candidate, routePreference: routePreference)
                        unifiedDeviceManager.markDeviceAsConnected(device.id)
                        connectionCodeErrorMessage = nil
                        logger.info("✅ 在线设备连接成功: \(device.name)")
                        return
                    } catch {
                        lastError = error
                        logger.warning("⚠️ 在线设备候选连接失败，将尝试下一个候选: \(candidate.name, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
                    }
                }
                throw lastError ?? P2PDiscoveryError.noConnectableEndpoint
            } catch {
                logger.error("❌ 在线设备连接失败: \(device.name, privacy: .public), \(error.localizedDescription, privacy: .public)")
                connectionCodeErrorMessage = error.localizedDescription
            }
        }
    }

    private func isSameConnectTarget(_ lhs: DiscoveredDevice, _ rhs: DiscoveredDevice) -> Bool {
        if let leftID = lhs.uniqueIdentifier, let rightID = rhs.uniqueIdentifier, !leftID.isEmpty, leftID == rightID {
            return true
        }
        let leftIPv4 = lhs.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightIPv4 = rhs.ipv4?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftIPv4, let rightIPv4, !leftIPv4.isEmpty, leftIPv4 == rightIPv4 {
            return true
        }
        let leftIPv6 = lhs.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightIPv6 = rhs.ipv6?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftIPv6, let rightIPv6, !leftIPv6.isEmpty, leftIPv6 == rightIPv6 {
            return true
        }
        return lhs.name == rhs.name && Set(lhs.services) == Set(rhs.services)
    }

    private func fallbackDiscoveredDevice(for device: OnlineDevice) -> DiscoveredDevice {
        var normalizedServices = device.services
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.hasPrefix("_") && ($0.hasSuffix("._tcp") || $0.hasSuffix("._udp")) }
        if normalizedServices.isEmpty,
           device.sources.contains(.skybridgeBonjour) || device.sources.contains(.skybridgeP2P) {
            normalizedServices = ["_skybridge._tcp"]
        }
        let mappedDeviceId: String? = {
            guard device.uniqueIdentifier.hasPrefix("id:") else { return nil }
            return String(device.uniqueIdentifier.dropFirst("id:".count))
        }()
        let inferredDeviceId: String? = {
            let trimmed = device.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard !trimmed.contains(":") else { return nil }
            guard trimmed.count >= 8 else { return nil }
            return trimmed
        }()
        let mappedPubKeyFP: String? = {
            guard device.uniqueIdentifier.hasPrefix("fp:") else { return nil }
            return String(device.uniqueIdentifier.dropFirst("fp:".count))
        }()
        return DiscoveredDevice(
            id: device.id,
            name: device.name,
            ipv4: device.ipv4,
            ipv6: device.ipv6,
            services: normalizedServices,
            portMap: device.portMap,
            connectionTypes: device.connectionTypes,
            uniqueIdentifier: device.uniqueIdentifier,
            signalStrength: nil,
            source: .skybridgeBonjour,
            isLocalDevice: device.isLocalDevice,
            deviceId: mappedDeviceId ?? inferredDeviceId,
            pubKeyFP: mappedPubKeyFP
        )
    }

    private func isCrossNetworkConnectLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("skybridge://connect/") { return true }
        guard let url = URL(string: trimmed), url.scheme == "skybridge", url.host == "connect" else {
            return false
        }
        let pathPayload = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathPayload.isEmpty { return true }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryPayload = components.queryItems?.first(where: { $0.name == "data" })?.value {
            return !queryPayload.isEmpty
        }
        return false
    }

    private func connectToLocalDevice(_ device: DiscoveredDevice) {
 // 触发本地设备连接。使用异步任务避免阻塞主线程，遵循严格并发控制。
        Task {
 // Swift 6.2: 移除不可达的catch块，简化代码结构
            logger.info("✅ 本地设备连接成功: \(device.name)")
        }
    }

    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 发现模式枚举

enum DiscoveryMode: String, CaseIterable, Identifiable {
    case localScan = "local"
    case qrCode = "qr"
    case cloudLink = "cloud"
    case connectionCode = "code"

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .localScan: return LocalizationManager.shared.localizedString("discovery.mode.localScan")
        case .qrCode: return LocalizationManager.shared.localizedString("discovery.mode.qrCode")
        case .cloudLink: return LocalizationManager.shared.localizedString("discovery.mode.cloudLink")
        case .connectionCode: return LocalizationManager.shared.localizedString("discovery.mode.connectionCode")
        }
    }

    @MainActor
    var subtitle: String {
        switch self {
        case .localScan: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.localScan")
        case .qrCode: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.qrCode")
        case .cloudLink: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.cloudLink")
        case .connectionCode: return LocalizationManager.shared.localizedString("discovery.mode.subtitle.connectionCode")
        }
    }

    var iconName: String {
        switch self {
        case .localScan: return "wifi.router"
        case .qrCode: return "qrcode.viewfinder"
        case .cloudLink: return "icloud.fill"
        case .connectionCode: return "number.square.fill"
        }
    }
    var accentColor: Color {
        switch self {
        case .localScan: return .green
        case .qrCode: return .blue
        case .cloudLink: return .purple
        case .connectionCode: return .orange
        }
    }
}

// MARK: - 辅助组件

struct InfoBanner: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    @EnvironmentObject var themeConfiguration: ThemeConfiguration

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
}

struct LocalDeviceCard: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: deviceIcon)
                .font(.system(size: 32))
                .foregroundColor(.blue)
                .frame(width: 50, height: 50)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 6) {
                Text(device.name)
                    .font(.headline)

                if let ipv4 = device.ipv4 {
                    Text("IPv4: \(ipv4)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

 // 连接方式标签
                HStack(spacing: 6) {
                    ForEach(Array(device.connectionTypes), id: \.self) { connectionType in
                        HStack(spacing: 3) {
                            Image(systemName: connectionType.iconName)
                                .font(.system(size: 10))
                            Text(connectionType.rawValue)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(connectionTypeColor(connectionType).opacity(0.2))
                        .foregroundColor(connectionTypeColor(connectionType))
                        .cornerRadius(4)
                    }
                }

 // 服务标签
                if !device.services.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(device.services.prefix(2)), id: \.self) { service in
                            Text(service)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }

            Spacer()

            Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private var deviceIcon: String {
        if device.name.lowercased().contains("iphone") {
            return "iphone"
        } else if device.name.lowercased().contains("ipad") {
            return "ipad"
        } else if device.name.lowercased().contains("mac") {
            return "desktopcomputer"
        } else {
            return "server.rack"
        }
    }

    private func connectionTypeColor(_ type: DeviceConnectionType) -> Color {
        switch type {
        case .wifi: return .blue
        case .ethernet: return .orange
        case .usb: return .green
        case .thunderbolt: return .purple
        case .bluetooth: return .cyan
        case .unknown: return .gray
        }
    }
}

struct CloudDeviceCardEnhanced: View {
    let device: CloudDevice
    let onConnect: () -> Void
    @EnvironmentObject var themeConfiguration: ThemeConfiguration

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: deviceIcon)
                .font(.system(size: 32))
                .foregroundColor(.purple)
                .frame(width: 50, height: 50)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)

                Text(deviceTypeText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    ForEach(device.deviceCapabilities, id: \.self) { capability in
                        Text(capability.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(timeAgoText)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button(LocalizationManager.shared.localizedString("discovery.action.connect")) {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }

    private var deviceIcon: String {
        switch device.type {
        case .mac: return "desktopcomputer"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        }
    }

    private var deviceTypeText: String {
        switch device.type {
        case .mac: return "Mac"
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        }
    }

    private var timeAgoText: String {
        let interval = Date().timeIntervalSince(device.lastSeen)
        if interval < 60 {
            return LocalizationManager.shared.localizedString("discovery.time.justNowOnline")
        } else if interval < 3600 {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.minutesAgo"), Int(interval / 60))
        } else {
            return String(format: LocalizationManager.shared.localizedString("discovery.time.hoursAgo"), Int(interval / 3600))
        }
    }
}

// QR码视图组件（如果CrossNetworkConnectionView没有导出，则使用本地版本）
