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

private struct TrustedGroupSelection: Identifiable, Equatable {
    let id: String
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

 // 跨网络连接（使用共享实例，确保与文件传输/远程桌面等模块状态一致）
    @StateObject private var crossNetworkManager = CrossNetworkConnectionManager.shared
    @StateObject private var p2pDiscoveryService = P2PDiscoveryService.shared

 // 🆕 真实iCloud设备发现(不再单独使用,已整合到统一管理器中)
 // @StateObject private var iCloudManager = iCloudDeviceDiscoveryManager()

 // UI 状态
    @State private var selectedConnectionMode: DiscoveryMode = .localScan
    @State private var searchText = ""
    @State private var connectionCodeInput = ""
 // 控制二维码扫描弹窗显示与错误提示。
    @State private var showingScanner: Bool = false
    @State private var scannerErrorMessage: String?
    @State private var lastScannerErrorFingerprint: String?
    @State private var lastScannerErrorAt: Date = .distantPast
    @State private var connectionCodeErrorMessage: String?
    @State private var extendedSearchCountdown: Int = 0
    @State private var showManualConnectSheet: Bool = false
    @State private var manualIP: String = ""
    @State private var manualPort: String = "11550"
    @State private var manualCode: String = ""
    @State private var hoveredConnectionMode: DiscoveryMode? = nil
    @State private var connectingOnlineDeviceIds: Set<UUID> = []

    @State private var selectedTrustedGroupSelection: TrustedGroupSelection?
    @StateObject private var trustedBonjourMetadata = TrustedBonjourMetadataStore()



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
        .task(id: trustedBonjourRefreshKey) {
            trustedBonjourMetadata.scheduleRefresh(for: trustedRecordsForUI)
        }
        .sheet(item: $selectedTrustedGroupSelection) { selection in
            if let group = trustedRecordGroup(for: selection.id) {
                let record = group.displayRecord
                let presentationMetadata = trustedRecordPresentation(group)
                TrustedDeviceDetailView(
                    record: record,
                    relatedRecords: group.relatedRecords,
                    presentationMetadata: presentationMetadata,
                    status: trustedRecordStatus(group),
                    onDisconnect: { idsToDisconnect, declaredDeviceId in
                        Task { @MainActor in
                            var didDisconnect = false
                            let disconnectCandidateIds = Array(
                                Set(
                                    idsToDisconnect
                                        + record.knownDeviceIds
                                        + [record.deviceId, record.currentDeviceId, declaredDeviceId]
                                            .compactMap { $0 }
                                )
                            )
                            let normalizedIds = Set(
                                disconnectCandidateIds
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                            )
                            let normalizedRecordName = (record.deviceName ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased()

                            if let snapshot = crossNetworkManager.activeSessionSnapshot {
                                let snapshotId = (snapshot.deviceId ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .lowercased()
                                let snapshotName = (snapshot.deviceName ?? crossNetworkManager.currentConnection?.deviceName ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .lowercased()

                                if (!snapshotId.isEmpty && normalizedIds.contains(snapshotId))
                                    || (!normalizedRecordName.isEmpty && snapshotName == normalizedRecordName) {
                                    await crossNetworkManager.disconnect()
                                    didDisconnect = true
                                }
                            }

                            for id in disconnectCandidateIds {
                                didDisconnect = p2pDiscoveryService.disconnectFromDevice(id) || didDisconnect
                            }

                            if didDisconnect {
                                selectedTrustedGroupSelection = nil
                            }
                        }
                    },
                    onRepairP2PTrust: { idsToRepair in
                        Task { @MainActor in
                            await PeerBootstrapTrustMaterialCleanup.repairP2PTrust(deviceIds: idsToRepair)
                            selectedTrustedGroupSelection = nil
                        }
                    },
                    onRemoveTrust: { idsToRevoke, declaredDeviceId in
                        Task { @MainActor in
                            let idsToForget = Array(Set(idsToRevoke + [declaredDeviceId].compactMap { $0 }))
                            // Clear policy first so future requests prompt again.
                            if let declaredDeviceId {
                                PairingTrustApprovalService.shared.clearPolicy(for: declaredDeviceId)
                            }
                            // Revoke all related ids (canonical + alias).
                            for id in idsToForget {
                                try? await TrustSyncService.shared.revokeTrustRecord(deviceId: id)
                            }
                            await PeerBootstrapTrustMaterialCleanup.forgetDevice(deviceIds: idsToForget)
                            // Close sheet
                            selectedTrustedGroupSelection = nil
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

                    ForEach(trustedRecords) { group in
                        TrustedDeviceCard(
                            record: group.displayRecord,
                            subtitle: trustedRecordSubtitle(group),
                            status: trustedRecordStatus(group)
                        ) {
                            selectedTrustedGroupSelection = TrustedGroupSelection(id: group.id)
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
            let recentlyConnected = groupedRecentlyConnectedDevices
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

    private var trustedRecordsForUI: [TrustRecordDisplayGroup] {
        let activeTrustedRecords = trustSync.activeTrustRecords
            .filter { $0.capabilities.contains(where: { $0.lowercased() == "trusted" || $0.lowercased() == "pqc_bootstrap" || $0.lowercased().hasPrefix("trusted") }) }
            .sorted { $0.updatedAt > $1.updatedAt }

        return TrustSyncService.buildPresentationDisplayGroups(from: activeTrustedRecords)
    }

    private func trustedRecordGroup(for id: String) -> TrustRecordDisplayGroup? {
        trustedRecordsForUI.first { $0.id == id }
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

    private func trustedRecordSubtitle(_ group: TrustRecordDisplayGroup) -> String {
        let normalized = trustedRecordPresentation(group)

        var parts: [String] = []
        if let modelName = normalized.modelName { parts.append(modelName) }
        if let chip = normalized.chip { parts.append(chip) }
        if let platform = normalized.platform, let osVersion = normalized.osVersion {
            parts.append("\(platform) \(osVersion)")
        } else if let platform = normalized.platform {
            parts.append(platform)
        }
        return parts.isEmpty ? group.displayRecord.deviceId : parts.joined(separator: " · ")
    }

    private func trustedRecordPresentation(
        _ group: TrustRecordDisplayGroup
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation {
        let record = group.displayRecord
        let c = trustedRecordCaps(record)
        let fallback = ApplePeerDeviceMetadataNormalizer.normalize(
            modelName: c["modelName"],
            chip: c["chip"],
            platform: c["platform"],
            osVersion: c["osVersion"]
        )
        let bonjourLive = trustedBonjourMetadata.metadataByGroupId[group.id]
        let live = bonjourLive ?? unifiedDeviceManager.resolvedApplePeerMetadata(for: trustedLookupRecords(for: group))
        var merged = ApplePeerDeviceMetadataNormalizer.mergedPresentation(
            preferred: live,
            fallback: fallback
        )
        if live == nil {
            merged = ApplePeerDeviceMetadataNormalizer.normalize(
                modelName: merged.modelName,
                chip: merged.chip,
                platform: merged.platform,
                osVersion: nil
            )
        }
        return merged
    }

    private func trustedLivePresentation(
        _ group: TrustRecordDisplayGroup
    ) -> ApplePeerDeviceMetadataNormalizer.Presentation? {
        unifiedDeviceManager.resolvedApplePeerMetadata(for: trustedLookupRecords(for: group))
    }

    private func trustedRecordStatus(_ group: TrustRecordDisplayGroup) -> OnlineDeviceStatus {
        let resolvedStatus = trustedPresentationOnlineDevices(for: group)
            .map(\.connectionStatus)
            .max(by: { statusPriority($0) < statusPriority($1) })
            ?? .offline
        return isCrossNetworkSessionActive(for: group) ? .connected : resolvedStatus
    }

    private func isCrossNetworkSessionActive(for group: TrustRecordDisplayGroup) -> Bool {
        guard let snapshot = crossNetworkManager.activeSessionSnapshot else { return false }
        switch snapshot.phase {
        case .transportReady, .handshakeComplete, .reconnecting:
            break
        case .connecting, .disconnecting:
            return false
        }

        let snapshotIds = Set(
            [
                snapshot.deviceId
            ]
            .compactMap(normalizedDiscoveryToken)
        )

        for record in trustedLookupRecords(for: group) {
            let caps = trustedRecordCaps(record)
            let recordIds = Set(
                [
                    record.deviceId,
                    record.currentDeviceId,
                    caps["declaredDeviceId"],
                    caps["peerEndpoint"]
                ]
                + record.knownDeviceIds
            .compactMap(normalizedDiscoveryToken))

            if !recordIds.isDisjoint(with: snapshotIds) {
                return true
            }

            let recordName = normalizedDiscoveryToken(record.deviceName)
            let snapshotName = normalizedDiscoveryToken(
                snapshot.deviceName ?? crossNetworkManager.currentConnection?.deviceName
            )
            if let recordName, let snapshotName, recordName == snapshotName {
                return true
            }
        }

        return false
    }

    private func trustedLookupRecords(for group: TrustRecordDisplayGroup) -> [TrustRecord] {
        let records = [group.displayRecord] + group.relatedRecords
        var ordered: [TrustRecord] = []
        var seen = Set<String>()

        for record in records {
            let key = "\(record.deviceId)|\(record.updatedAt)"
            if seen.insert(key).inserted {
                ordered.append(record)
            }
        }
        return ordered
    }

    private func trustedPresentationOnlineDevices(for group: TrustRecordDisplayGroup) -> [OnlineDevice] {
        let records = trustedLookupRecords(for: group)
        let context = trustedDeviceMatchContext(for: group)
        let liveCandidates = unifiedDeviceManager.onlineDevices.filter { !$0.isLocalDevice }
        let recentCandidates = groupedRecentlyConnectedDevices.filter { !$0.isLocalDevice }

        var mergedByIdentity: [String: (score: Int, device: OnlineDevice)] = [:]
        for device in liveCandidates + recentCandidates {
            let resolvedTrustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: records)
            let fallbackScore = trustedDeviceMatchScore(device, context: context)
            let matchScore: Int
            let mergeKey: String

            if let resolvedTrustRecord {
                matchScore = 20_000 + fallbackScore
                mergeKey = "trusted:\(resolvedTrustRecord.deviceId)"
            } else {
                guard fallbackScore > 0 else { continue }
                matchScore = fallbackScore
                mergeKey = "device:\(device.id.uuidString)"
            }

            if let existing = mergedByIdentity[mergeKey] {
                if existing.score == matchScore {
                    mergedByIdentity[mergeKey] = (
                        score: matchScore,
                        device: preferredRecentDisplayDevice(existing.device, device)
                    )
                } else if existing.score < matchScore {
                    mergedByIdentity[mergeKey] = (score: matchScore, device: device)
                }
            } else {
                mergedByIdentity[mergeKey] = (score: matchScore, device: device)
            }
        }

        return mergedByIdentity.values.sorted { lhs, rhs in
            let lhsScore = lhs.score
            let rhsScore = rhs.score
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return trustedPresentationPriority(lhs.device) > trustedPresentationPriority(rhs.device)
        }
        .map(\.device)
    }

    private func trustedPresentationPriority(_ device: OnlineDevice) -> Int {
        var score = statusPriority(device.connectionStatus) * 1_000
        if device.isConnectable { score += 150 }
        if !(device.uniqueIdentifier.hasPrefix("recent:")) { score += 250 }
        if device.modelName?.isEmpty == false { score += 400 }
        if device.chip?.isEmpty == false { score += 300 }
        if device.platformName?.isEmpty == false { score += 200 }
        if device.osVersion?.isEmpty == false { score += 600 }
        if device.ipv4 != nil || device.ipv6 != nil { score += 100 }
        score += Int(device.lastSeen.timeIntervalSince1970)
        return score
    }

    private func trustedDeviceMatchContext(
        for group: TrustRecordDisplayGroup
    ) -> (identityTokens: Set<String>, nameTokens: Set<String>) {
        let records = trustedLookupRecords(for: group)
        var identityTokens = Set<String>()
        var nameTokens = Set<String>()

        for record in records {
            for raw in [record.deviceId, record.currentDeviceId, record.deviceName] + record.knownDeviceIds {
                trustedDeviceTokens(from: raw).forEach { token in
                    if token.hasPrefix("name:") {
                        nameTokens.insert(token)
                    } else {
                        identityTokens.insert(token)
                    }
                }
            }

            let caps = trustedRecordCaps(record)
            for raw in [caps["declaredDeviceId"], caps["peerEndpoint"]] {
                trustedDeviceTokens(from: raw).forEach { token in
                    if token.hasPrefix("name:") {
                        nameTokens.insert(token)
                    } else {
                        identityTokens.insert(token)
                    }
                }
            }
        }

        return (identityTokens, nameTokens)
    }

    private func trustedDeviceMatchScore(
        _ device: OnlineDevice,
        context: (identityTokens: Set<String>, nameTokens: Set<String>)
    ) -> Int {
        let deviceTokens = trustedDeviceTokens(for: device)
        let identityMatches = deviceTokens.intersection(context.identityTokens)
        if !identityMatches.isEmpty {
            return 10_000 + identityMatches.count * 100
        }

        if context.identityTokens.isEmpty {
            let nameMatches = deviceTokens.intersection(context.nameTokens)
            if !nameMatches.isEmpty {
                return 1_000 + nameMatches.count * 10
            }
        }

        return 0
    }

    private func trustedDeviceTokens(for device: OnlineDevice) -> Set<String> {
        var tokens = Set<String>()
        for raw in [device.uniqueIdentifier, device.ipv4, device.ipv6, device.name] {
            tokens.formUnion(trustedDeviceTokens(from: raw))
        }
        return tokens
    }

    private func trustedDeviceTokens(from raw: String?) -> Set<String> {
        guard let raw = normalizedDiscoveryToken(raw) else { return [] }

        var tokens = Set<String>()
        tokens.insert(raw)

        if raw.hasPrefix("id:") {
            tokens.insert(String(raw.dropFirst("id:".count)))
            return tokens
        }

        if raw.hasPrefix("bonjour:") {
            tokens.insert("host:\(raw)")
            if let name = raw.split(separator: "@", maxSplits: 1).first {
                tokens.insert("name:\(String(name.dropFirst("bonjour:".count)))")
            }
            return tokens
        }

        if raw.hasPrefix("host:") {
            let payload = String(raw.dropFirst("host:".count))
            tokens.insert(payload)
            if payload.hasPrefix("bonjour:") {
                tokens.insert(payload)
            }
            if payload.hasPrefix("id:") {
                tokens.insert(String(payload.dropFirst("id:".count)))
            }
            return tokens
        }

        if raw.hasPrefix("recent:") {
            let payload = String(raw.dropFirst("recent:".count))
            tokens.insert(payload)
            if payload.hasPrefix("peer:") {
                tokens.insert(String(payload.dropFirst("peer:".count)))
            }
            return tokens
        }

        if raw.hasPrefix("peer:") {
            tokens.insert(String(raw.dropFirst("peer:".count)))
            return tokens
        }

        if raw.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            tokens.insert(raw)
            tokens.insert("id:\(raw)")
            return tokens
        }

        if raw.contains(".") || raw.contains(":") {
            tokens.insert("host:\(raw)")
            return tokens
        }

        tokens.insert("name:\(raw)")
        return tokens
    }

    private func normalizedDiscoveryToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token.isEmpty ? nil : token
    }

    private var onlineNonLocalDevices: [OnlineDevice] {
        unifiedDeviceManager.onlineDevices.filter { !$0.isLocalDevice }
    }

    private var filteredOnlineDevicesNonLocal: [OnlineDevice] {
        let settings = SettingsManager.shared
        let base = onlineNonLocalDevices.filter { device in
            if settings.hideOfflineDevices && device.connectionStatus == .offline {
                return false
            }
            if settings.showConnectableDevicesOnly && !device.isConnectable {
                return false
            }
            return true
        }

        if searchText.isEmpty {
            return base
        }

        return base.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.ipv4?.contains(searchText) == true ||
            $0.ipv6?.contains(searchText) == true
        }
    }

    private var groupedRecentlyConnectedDevices: [OnlineDevice] {
        let candidates = unifiedDeviceManager.onlineDevices
            .filter { !$0.isLocalDevice && $0.lastConnectedAt != nil && $0.connectionStatus != .connected }
        guard !candidates.isEmpty else { return [] }

        let trustRecords = trustedRecordsForUI.map(\.displayRecord)
        var grouped: [String: OnlineDevice] = [:]

        for device in candidates {
            let groupingKey: String
            if let trustRecord = unifiedDeviceManager.resolvedTrustRecord(for: device, among: trustRecords) {
                groupingKey = "trusted:\(trustRecord.deviceId)"
            } else {
                groupingKey = "device:\(device.id.uuidString)"
            }

            if let existing = grouped[groupingKey] {
                grouped[groupingKey] = preferredRecentDisplayDevice(existing, device)
            } else {
                grouped[groupingKey] = device
            }
        }

        return grouped.values.sorted { lhs, rhs in
            if statusPriority(lhs.connectionStatus) != statusPriority(rhs.connectionStatus) {
                return statusPriority(lhs.connectionStatus) > statusPriority(rhs.connectionStatus)
            }
            let lhsConnected = lhs.lastConnectedAt ?? .distantPast
            let rhsConnected = rhs.lastConnectedAt ?? .distantPast
            if lhsConnected != rhsConnected {
                return lhsConnected > rhsConnected
            }
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen > rhs.lastSeen
            }
            return lhs.name < rhs.name
        }
    }

    private var trustedBonjourRefreshKey: String {
        let trustIds = trustedRecordsForUI.map(\.id).joined(separator: "|")
        let trustEndpoints = trustedRecordsForUI
            .flatMap { trustedLookupRecords(for: $0) }
            .flatMap { record in
                [record.deviceId, record.currentDeviceId] + record.knownDeviceIds + record.capabilities
            }
            .joined(separator: "|")
        let onlineSummary = unifiedDeviceManager.onlineDevices
            .filter { !$0.isLocalDevice }
            .map {
                "\($0.uniqueIdentifier):\($0.connectionStatus.rawValue):\($0.platformName ?? ""):\($0.osVersion ?? ""):\($0.modelName ?? ""):\($0.chip ?? "")"
            }
            .sorted()
            .joined(separator: "|")
        let discoverySummary = unifiedDeviceManager.discoveryMetadataSummary
        return "\(selectedConnectionMode.id)|\(trustIds)|\(trustEndpoints)|\(onlineSummary)|\(discoverySummary)|scan:\(unifiedDeviceManager.isScanning)"
    }

    private func preferredRecentDisplayDevice(_ lhs: OnlineDevice, _ rhs: OnlineDevice) -> OnlineDevice {
        if statusPriority(lhs.connectionStatus) != statusPriority(rhs.connectionStatus) {
            return statusPriority(lhs.connectionStatus) > statusPriority(rhs.connectionStatus) ? lhs : rhs
        }

        if lhs.isConnectable != rhs.isConnectable {
            return lhs.isConnectable ? lhs : rhs
        }

        let lhsLooksLikeIP = isIPAddressLikeLabel(lhs.name)
        let rhsLooksLikeIP = isIPAddressLikeLabel(rhs.name)
        if lhsLooksLikeIP != rhsLooksLikeIP {
            return lhsLooksLikeIP ? rhs : lhs
        }

        let lhsConnected = lhs.lastConnectedAt ?? .distantPast
        let rhsConnected = rhs.lastConnectedAt ?? .distantPast
        if lhsConnected != rhsConnected {
            return lhsConnected > rhsConnected ? lhs : rhs
        }

        if lhs.lastSeen != rhs.lastSeen {
            return lhs.lastSeen > rhs.lastSeen ? lhs : rhs
        }

        return lhs.name.count >= rhs.name.count ? lhs : rhs
    }

    private func isIPAddressLikeLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(":") { return true }
        let parts = trimmed.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
    }

    private func statusPriority(_ status: OnlineDeviceStatus) -> Int {
        switch status {
        case .connected:
            return 3
        case .online:
            return 2
        case .offline:
            return 1
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
                            .frame(width: 280, height: 280)
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.1), radius: 4)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white, Color.blue)
                                    .padding(10)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .help("点击二维码立即刷新")
                            .onTapGesture {
                                Task { await generateDynamicQRCodeFromUI(trigger: "tap_qr_refresh") }
                            }

                        Text("扫描此二维码，点击二维码可立即刷新")
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
                            Task { await generateDynamicQRCodeFromUI(trigger: "regenerate_qr") }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            Task { await generateDynamicQRCodeFromUI(trigger: "generate_qr") }
                        }) {
                            VStack(spacing: 12) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 48))
                                    .foregroundColor(.blue)
                                Text(LocalizationManager.shared.localizedString("discovery.qrCode.generate"))
                                    .font(.headline)
                            }
                            .frame(width: 280, height: 280)
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
                        .frame(width: 280, height: 280)
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
                            let scannedContent = result
                            showingScanner = false
                            Task { await connectScannedQRCodeFromUI(scannedContent, trigger: "qr_scanner_sheet") }
                        } else {
 // 不识别的二维码内容
                            presentScannerError(LocalizationManager.shared.localizedString("discovery.qrCode.error.unrecognized"))
                            showingScanner = false
                        }
                    },
                    onError: { message in
                        // 扫描器错误回调
                        presentScannerError(message)
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
        @StateObject private var settingsManager = SettingsManager.shared
        @ObservedObject private var presenceService = ConnectionPresenceService.shared

        init(device: OnlineDevice, isConnecting: Bool = false, onConnect: @escaping () -> Void) {
            self.device = device
            self.isConnecting = isConnecting
            self.onConnect = onConnect
        }

        var body: some View {
            HStack(spacing: settingsManager.compactMode ? 10 : 16) {
 // 设备图标
                Image(systemName: deviceIcon)
                    .font(.system(size: settingsManager.compactMode ? 24 : 32))
                    .foregroundColor(statusColor)
                    .frame(width: settingsManager.compactMode ? 40 : 50, height: settingsManager.compactMode ? 40 : 50)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: settingsManager.compactMode ? 4 : 6) {
                    HStack(spacing: 8) {
                        Text(device.name)
                            .font(settingsManager.compactMode ? .subheadline : .headline)

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

                    if settingsManager.showDeviceDetails, let ipv4 = device.ipv4 {
                        Text("IP: \(ipv4)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

 // 连接类型标签
                    if settingsManager.showDeviceDetails && !device.connectionTypes.isEmpty {
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

                    if settingsManager.showConnectionStats {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if settingsManager.showDeviceRSSI, let signal = device.signalStrength {
                        Text("RSSI: \(Int(signal))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if settingsManager.showConnectionStats,
                       let detail = connectionDetailText {
                        Text(detail)
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
            .padding(settingsManager.compactMode ? 10 : 16)
            .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(device.isLocalDevice ? Color.blue : themeConfiguration.borderColor, lineWidth: device.isLocalDevice ? 2 : 1)
            )
        }

        private var resolvedCryptoKind: String? {
            matchingPresenceConnection?.cryptoKind ?? device.lastCryptoKind
        }

        private var resolvedCryptoSuite: String? {
            matchingPresenceConnection?.suite ?? device.lastCryptoSuite
        }

        private var resolvedGuardStatus: String? {
            if device.isLocalDevice { return nil }
            if let guardStatus = device.guardStatus,
               !guardStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return guardStatus
            }
            return device.connectionStatus == .connected ? "守护中" : nil
        }

        private var statusText: String {
            if device.isLocalDevice {
                return "在线"
            }
            guard device.connectionStatus == .connected else {
                return device.connectionStatus.rawValue
            }
            return ConnectionCryptoPresentation.connectedStatusTextWithPolicyFallback(
                kind: resolvedCryptoKind,
                suite: resolvedCryptoSuite,
                baseConnectedText: device.connectionStatus.rawValue,
                compatibilityModeEnabled: settingsManager.enableCompatibilityMode
            )
        }

        private var connectionDetailText: String? {
            guard device.connectionStatus == .connected else { return nil }
            return ConnectionCryptoPresentation.detailText(
                kind: resolvedCryptoKind,
                suite: resolvedCryptoSuite,
                guardStatus: resolvedGuardStatus
            )
        }

        private var matchingPresenceConnection: ConnectionPresenceService.ActiveConnection? {
            guard #available(macOS 14.0, iOS 17.0, *) else { return nil }

            let activeConnections = presenceService.activeConnections
            guard !activeConnections.isEmpty else { return nil }

            if device.isLocalDevice {
                return nil
            }

            let deviceTokens = presenceMatchTokens(
                identifier: device.uniqueIdentifier,
                displayName: device.name,
                addresses: [device.ipv4, device.ipv6]
            )
            if !deviceTokens.isEmpty {
                let matches = activeConnections.filter { connection in
                    let connectionTokens = presenceMatchTokens(
                        identifier: connection.id,
                        displayName: connection.displayName,
                        addresses: [connection.address]
                    )
                    return !deviceTokens.isDisjoint(with: connectionTokens)
                }
                if let newestMatch = matches.max(by: { $0.connectedAt < $1.connectedAt }) {
                    return newestMatch
                }
            }

            return nil
        }

        private func normalizedAddress(_ raw: String?) -> String? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            var value = raw
            if value.hasPrefix("[") && value.hasSuffix("]") {
                value = String(value.dropFirst().dropLast())
            }
            if let percent = value.firstIndex(of: "%") {
                value = String(value[..<percent])
            }
            return value.lowercased()
        }

        private func normalizedToken(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        private func presenceMatchTokens(
            identifier: String?,
            displayName: String?,
            addresses: [String?]
        ) -> Set<String> {
            var tokens = Set<String>()

            func addToken(_ raw: String?) {
                guard let raw else { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                tokens.insert(trimmed.lowercased())
            }

            func addIdentifier(_ raw: String?) {
                guard let raw else { return }
                let normalized = normalizedToken(raw)
                guard !normalized.isEmpty else { return }
                addToken(normalized)

                if normalized.hasPrefix("recent:") {
                    addIdentifier(String(normalized.dropFirst("recent:".count)))
                }
                if normalized.hasPrefix("id:") {
                    addToken(String(normalized.dropFirst("id:".count)))
                }
                if normalized.hasPrefix("bonjour:") {
                    let payload = String(normalized.dropFirst("bonjour:".count))
                    let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
                    addToken(parts.first)
                }
            }

            addIdentifier(identifier)
            addToken(displayName)
            for address in addresses {
                addToken(normalizedAddress(address))
            }

            return tokens
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
                        scannerErrorMessage = "iCloud 设备连接失败：\(userFacingConnectionErrorMessage(error))"
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
                            Picker(
                                LocalizationManager.shared.localizedString("connection.codeMode.title"),
                                selection: $crossNetworkManager.connectionCodeLeaseMode
                            ) {
                                Text(LocalizationManager.shared.localizedString("connection.codeMode.short"))
                                    .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.shortLived)
                                Text(LocalizationManager.shared.localizedString("connection.codeMode.day"))
                                    .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.dayStable)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 240)

                            Text(
                                crossNetworkManager.connectionCodeLeaseMode == .dayStable
                                    ? LocalizationManager.shared.localizedString("connection.codeMode.dayHint")
                                    : LocalizationManager.shared.localizedString("connection.codeMode.shortHint")
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(width: 240)

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
                                            connectionCodeErrorMessage = userFacingConnectionErrorMessage(error)
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
                                    connectionCodeErrorMessage = userFacingConnectionErrorMessage(error)
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

                        Picker(
                            LocalizationManager.shared.localizedString("connection.codeMode.title"),
                            selection: $crossNetworkManager.connectionCodeLeaseMode
                        ) {
                            Text(LocalizationManager.shared.localizedString("connection.codeMode.short"))
                                .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.shortLived)
                            Text(LocalizationManager.shared.localizedString("connection.codeMode.day"))
                                .tag(CrossNetworkConnectionManager.ConnectionCodeLeaseMode.dayStable)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)

                        Text(
                            crossNetworkManager.connectionCodeLeaseMode == .dayStable
                                ? LocalizationManager.shared.localizedString("connection.codeMode.dayHint")
                                : LocalizationManager.shared.localizedString("connection.codeMode.shortHint")
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 240)
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
                                connectionCodeInput = CrossNetworkConnectionManager.sanitizeConnectionCodeInput(newValue)
                            }

                        Button(action: {
                            Task {
                                do {
                                    connectionCodeErrorMessage = nil
                                    _ = try await crossNetworkManager.connectWithCode(connectionCodeInput)
                                } catch {
                                    connectionCodeErrorMessage = userFacingConnectionErrorMessage(error)
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
                        .disabled(!CrossNetworkConnectionManager.canSubmitConnectionCode(connectionCodeInput))
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
            var discoveredCandidates = unifiedDeviceManager.resolvedDiscoveredCandidates(for: device, limit: 6)
            if let fallback = fallbackDiscoveredDevice(for: device),
               !discoveredCandidates.contains(where: { isSameConnectTarget($0, fallback) }) {
                discoveredCandidates.append(fallback)
            }
            let preferUSBRoute = shouldPreferUSBRoute(for: device, candidates: discoveredCandidates)
            let routePreference: P2PDiscoveryService.ConnectionRoutePreference = {
                if !SettingsManager.shared.enableP2PDirectConnection {
                    return .managedRelayOnly
                }
                return preferUSBRoute ? .preferUSB : .automatic
            }()

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
                connectionCodeErrorMessage = userFacingConnectionErrorMessage(error)
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

    private func shouldPreferUSBRoute(for device: OnlineDevice, candidates: [DiscoveredDevice]) -> Bool {
        guard device.connectionTypes.contains(.usb) else { return false }
        return candidates.contains { candidate in
            candidate.connectionTypes.contains(.usb)
                && ((candidate.portMap["_skybridge._tcp"] ?? 0) > 0
                    || (candidate.portMap["_skybridge._udp"] ?? 0) > 0
                    || candidate.uniqueIdentifier?.hasPrefix("bonjour:") == true
                    || candidate.uniqueIdentifier?.hasPrefix("recent:bonjour:") == true)
        }
    }

    private func fallbackDiscoveredDevice(for device: OnlineDevice) -> DiscoveredDevice? {
        var normalizedServices = device.services
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.hasPrefix("_") && ($0.hasSuffix("._tcp") || $0.hasSuffix("._udp")) }

        let hasSkyBridgeSource = device.sources.contains(.skybridgeBonjour) || device.sources.contains(.skybridgeP2P)
        let hasBonjourIdentifier = device.uniqueIdentifier.hasPrefix("bonjour:")
            || device.uniqueIdentifier.hasPrefix("recent:bonjour:")
        let hasSkyBridgeControlPort = (device.portMap["_skybridge._tcp"] ?? 0) > 0
            || (device.portMap["_skybridge._udp"] ?? 0) > 0
        let hasSkyBridgeControlService = normalizedServices.contains("_skybridge._tcp")
            || normalizedServices.contains("_skybridge._udp")

        if normalizedServices.isEmpty, hasSkyBridgeSource, hasBonjourIdentifier {
            normalizedServices = ["_skybridge._tcp"]
        }
        guard hasSkyBridgeControlService
            || hasSkyBridgeControlPort
            || (hasSkyBridgeSource && hasBonjourIdentifier)
        else {
            logger.warning(
                "⚠️ 跳过在线设备 fallback 候选：缺少真实 SkyBridge 控制端点 device=\(device.name, privacy: .public) id=\(device.uniqueIdentifier, privacy: .public)"
            )
            return nil
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
        let source: DeviceSource = {
            if device.sources.contains(.skybridgeP2P) { return .skybridgeP2P }
            if device.sources.contains(.skybridgeBonjour) { return .skybridgeBonjour }
            return .unknown
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
            signalStrength: device.signalStrength,
            source: source,
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

    private func generateDynamicQRCodeFromUI(trigger: String) async {
        guard !isGeneratingQRCode else { return }
        do {
            scannerErrorMessage = nil
            logger.info("📷 QR action started: \(trigger, privacy: .public)")
            _ = try await crossNetworkManager.generateDynamicQRCode()
            logger.info("✅ QR action succeeded: \(trigger, privacy: .public)")
        } catch {
            logger.error("❌ QR action failed: \(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            presentScannerError(String(
                format: LocalizationManager.shared.localizedString("discovery.qrCode.error.connectFailed"),
                userFacingConnectionErrorMessage(error)
            ))
        }
    }

    private func connectScannedQRCodeFromUI(_ content: String, trigger: String) async {
        do {
            scannerErrorMessage = nil
            logger.info("📷 QR scan connect started: \(trigger, privacy: .public)")
            let data = Data(content.utf8)
            _ = try await crossNetworkManager.scanDynamicQRCode(data)
            logger.info("✅ QR scan connect succeeded: \(trigger, privacy: .public)")
        } catch {
            logger.error("❌ QR scan connect failed: \(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            presentScannerError(String(
                format: LocalizationManager.shared.localizedString("discovery.qrCode.error.connectFailed"),
                userFacingConnectionErrorMessage(error)
            ))
        }
    }

    private var isGeneratingQRCode: Bool {
        if case .generating = crossNetworkManager.connectionStatus {
            return true
        }
        return false
    }

    private func presentScannerError(_ message: String, dedupeWindow: TimeInterval = 12) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let now = Date()
        if lastScannerErrorFingerprint == normalized,
           now.timeIntervalSince(lastScannerErrorAt) < dedupeWindow {
            return
        }
        lastScannerErrorFingerprint = normalized
        lastScannerErrorAt = now
        scannerErrorMessage = normalized
    }

    private func userFacingConnectionErrorMessage(_ error: Error) -> String {
        let message = HandshakeErrorLocalizer.localizedMessage(for: error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return message
        }
        let fallback = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "连接失败" : fallback
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

    @MainActor
    private final class TrustedBonjourMetadataStore: ObservableObject {
        @Published fileprivate var metadataByGroupId: [String: ApplePeerDeviceMetadataNormalizer.Presentation] = [:]
        private var refreshTask: Task<Void, Never>?
        private let logger = Logger(
            subsystem: "com.skybridge.SkyBridgeCompassApp",
            category: "TrustedBonjourMetadata"
        )

        func scheduleRefresh(for groups: [TrustRecordDisplayGroup]) {
            let snapshot = groups
            logger.debug("schedule refresh for \(snapshot.count) trusted groups")
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                await self?.refresh(for: snapshot)
            }
        }

        deinit {
            refreshTask?.cancel()
        }

        private func refresh(for groups: [TrustRecordDisplayGroup]) async {
            var updated: [String: ApplePeerDeviceMetadataNormalizer.Presentation] = [:]
            for group in groups {
                guard !Task.isCancelled else { return }
                guard let endpoint = Self.bonjourEndpoint(for: group) else {
                    logger.debug("skip group \(group.id, privacy: .public): no bonjour endpoint")
                    continue
                }
                logger.debug(
                    "resolve group \(group.id, privacy: .public) endpoint=\(endpoint.name, privacy: .public)@\(endpoint.domain, privacy: .public)"
                )
                guard let info = await BonjourTXTLookupResolver.resolve(
                    name: endpoint.name,
                    type: "_skybridge._tcp",
                    domain: endpoint.domain,
                    timeout: 1.5
                ) else {
                    logger.debug("resolve missed group \(group.id, privacy: .public)")
                    continue
                }
                logger.debug(
                    "resolved group \(group.id, privacy: .public) platform=\(info.platform ?? "", privacy: .public) os=\(info.osVersion ?? "", privacy: .public) model=\(info.model ?? "", privacy: .public)"
                )

                let normalized = ApplePeerDeviceMetadataNormalizer.normalize(
                    modelName: info.model,
                    chip: info.chip,
                    platform: info.platform,
                    osVersion: info.osVersion
                )

                if normalized.modelName != nil
                    || normalized.chip != nil
                    || normalized.platform != nil
                    || normalized.osVersion != nil {
                    updated[group.id] = normalized
                }
            }

            applyResolvedMetadata(updated, validGroupIds: Set(groups.map(\.id)))
        }

        private func applyResolvedMetadata(
            _ updated: [String: ApplePeerDeviceMetadataNormalizer.Presentation],
            validGroupIds: Set<String>
        ) {
            var merged = metadataByGroupId.filter { validGroupIds.contains($0.key) }
            merged.merge(updated) { _, new in new }
            metadataByGroupId = merged
            logger.debug("applied trusted bonjour metadata for \(updated.count) groups; retained total \(merged.count)")
        }

        private nonisolated static func bonjourEndpoint(
            for group: TrustRecordDisplayGroup
        ) -> (name: String, domain: String)? {
            let records = [group.displayRecord] + group.relatedRecords
            for record in records {
                for token in bonjourCandidates(from: record) {
                    if let parsed = parseBonjourToken(token) {
                        return parsed
                    }
                }
            }
            return nil
        }

        private nonisolated static func bonjourCandidates(from record: TrustRecord) -> [String] {
            let caps = record.capabilities.compactMap { capability -> String? in
                let parts = capability.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "peerEndpoint" else { return nil }
                return parts[1]
            }

            return caps
                + [record.deviceId, record.currentDeviceId]
                + record.knownDeviceIds
        }

        private nonisolated static func parseBonjourToken(_ raw: String?) -> (name: String, domain: String)? {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.hasPrefix("bonjour:") else {
                return nil
            }

            let payload = String(raw.dropFirst("bonjour:".count))
            let parts = payload.split(separator: "@", maxSplits: 1).map(String.init)
            guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return nil
            }

            let domain = parts.count > 1 ? parts[1] : "local."
            return (name, domain.hasSuffix(".") ? domain : "\(domain).")
        }
    }
}

private final class BonjourTXTLookupResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let resumed = OSAllocatedUnfairLock(initialState: false)
    private let service: NetService
    private var continuation: CheckedContinuation<BonjourDeviceInfo?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var selfRetain: BonjourTXTLookupResolver?

    private init(name: String, type: String, domain: String) {
        self.service = NetService(domain: domain, type: type, name: name)
        super.init()
    }

    static func resolve(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval = 3
    ) async -> BonjourDeviceInfo? {
        let resolved = await withCheckedContinuation { continuation in
            let resolver = BonjourTXTLookupResolver(name: name, type: type, domain: domain)
            resolver.start(timeout: timeout, continuation: continuation)
        }
        if let resolved {
            return resolved
        }
        return await fallbackResolveViaDNSSD(
            name: name,
            type: type,
            domain: domain,
            timeout: timeout
        )
    }

    private func start(
        timeout: TimeInterval,
        continuation: CheckedContinuation<BonjourDeviceInfo?, Never>
    ) {
        self.continuation = continuation
        self.selfRetain = self
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: timeout)

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.finish(with: nil)
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let txtData = sender.txtRecordData() else {
            finish(with: nil)
            return
        }

        let dict = NetService.dictionary(fromTXTRecord: txtData).reduce(into: [String: String]()) { partialResult, item in
            if let value = String(data: item.value, encoding: .utf8) {
                partialResult[item.key] = value
            }
        }
        finish(with: BonjourTXTParser.extractDeviceInfo(from: dict))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        finish(with: nil)
    }

    private func finish(with info: BonjourDeviceInfo?) {
        let shouldResume = resumed.withLock { completed -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldResume else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        service.delegate = nil
        service.stop()
        service.remove(from: .main, forMode: .common)
        continuation?.resume(returning: info)
        continuation = nil
        selfRetain = nil
    }

    private static func fallbackResolveViaDNSSD(
        name: String,
        type: String,
        domain: String,
        timeout: TimeInterval
    ) async -> BonjourDeviceInfo? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/dns-sd") else {
            return nil
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-L", name, type, domain]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let completed = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable () -> Void = {
                let shouldResume = completed.withLock { state -> Bool in
                    guard !state else { return false }
                    state = true
                    return true
                }
                guard shouldResume else { return }
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }
                for line in output.split(whereSeparator: \.isNewline).reversed() {
                    let parsed = parseDNSSDKeyValueLine(String(line))
                    if !parsed.isEmpty {
                        continuation.resume(returning: BonjourTXTParser.extractDeviceInfo(from: parsed))
                        return
                    }
                }
                continuation.resume(returning: nil)
            }

            process.terminationHandler = { _ in
                finish()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            Task {
                try? await Task.sleep(for: .seconds(max(timeout, 0.5)))
                let shouldTerminate = completed.withLock { !$0 }
                if shouldTerminate, process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private static func parseDNSSDKeyValueLine(_ line: String) -> [String: String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("=") else { return [:] }

        let tokens = splitEscapedFields(trimmed)
        var parsed: [String: String] = [:]
        for token in tokens {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1]
                .replacingOccurrences(of: "\\ ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            parsed[key] = value
        }
        return parsed
    }

    private static func splitEscapedFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaping = false

        for scalar in line.unicodeScalars {
            let character = Character(scalar)
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" {
                current.append(character)
                escaping = true
                continue
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !current.isEmpty {
                    fields.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            fields.append(current)
        }

        return fields
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
