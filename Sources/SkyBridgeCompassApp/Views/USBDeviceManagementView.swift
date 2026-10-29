import SwiftUI
import SkyBridgeCore

/// USB设备管理视图
/// 展示已连接的USB设备，包括MFi认证设备、Android设备、硬盘和U盘
@available(macOS 14.0, *)
struct USBDeviceManagementView: View {
    @StateObject private var usbManager: USBCConnectionManager
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    @State private var connectedDevices: [USBDeviceInfo] = []
    @State private var isScanning = false
    @State private var lastScanTime: Date?
    @State private var hasLoadedInitialDevices = false
    @State private var appleUSBDevices: [USBMultiplexDevice] = []
    @State private var usbInventoryError: String?
    @State private var androidUSBDevices: [USBDeviceInfo] = []
    @State private var androidInventoryError: String?

    init(usbManager: USBCConnectionManager = .shared) {
        _usbManager = StateObject(wrappedValue: usbManager)
    }
    
    var body: some View {
        // The app sidebar owns navigation; a nested NavigationView creates an
        // empty detail column and squeezes the USB controls into its sidebar.
        Group {
            VStack(spacing: 0) {
 // 标题和刷新按钮
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizationManager.shared.localizedString("usb.management.title"))
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        if let lastScan = lastScanTime {
                            Text(String(format: LocalizationManager.shared.localizedString("usb.lastScan"), dateFormatter.string(from: lastScan)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: refreshDevices) {
                        HStack {
                            Image(systemName: isScanning ? "arrow.clockwise" : "arrow.clockwise.circle")
                                .rotationEffect(.degrees(isScanning ? 360 : 0))
                                .animation(isScanning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isScanning)
                            Text(LocalizationManager.shared.localizedString("action.refresh"))
                        }
                    }
                    .disabled(isScanning)
                }
                .padding()
                .background(.ultraThinMaterial)
                
                Divider()
                
 // 主内容区域（大块液态玻璃面板）
                ScrollView {
                    VStack(spacing: 20) {
 // 设备统计卡片
                        deviceStatsCards
                        if let error = usbManager.lastScanError {
                            Text(String(localized: "设备扫描失败，当前显示上次记录：") + error).foregroundStyle(.red)
                        }
                        if let usbInventoryError {
                            Text(usbInventoryError).foregroundStyle(.red)
                        }
                        ForEach(appleUSBDevices, id: \.udid) { device in
                            USBPeerConnectionRow(udid: device.udid)
                        }
                        if let androidInventoryError { Text(androidInventoryError).foregroundStyle(.red) }
                        AndroidUSBConnectionView(devices: androidUSBDevices,
                            inventoryCurrent: !isScanning && androidInventoryError == nil,
                            refreshDevices: refreshDevices)
                        
 // 设备列表
                        if connectedDevices.isEmpty {
                            emptyStateView
                        } else {
                            deviceListView
                        }
                    }
                    .padding(20)
                }
                .background(
                    themeConfiguration.cardBackgroundMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(themeConfiguration.borderColor, lineWidth: 1)
                )
                .padding(16)
            }
        }
        .onAppear(perform: loadCachedDevicesAndScanIfNeeded)
        .onReceive(usbManager.$discoveredUSBDevices) { devices in
            connectedDevices = devices.sorted { $0.name < $1.name }
            lastScanTime = usbManager.lastScanCompletedAt
        }
    }
    
 // MARK: - 设备统计卡片
    
    private var deviceStatsCards: some View {
        HStack(spacing: 16) {
 // MFi认证设备数量
            USBStatCard(
                title: LocalizationManager.shared.localizedString("usb.mfi.title"),
                value: "\(mfiDeviceCount)",
                icon: "checkmark.seal.fill",
                color: .green
            )
            
 // Android设备数量
            USBStatCard(
                title: LocalizationManager.shared.localizedString("usb.android.title"),
                value: "\(androidDeviceCount)",
                icon: "smartphone",
                color: .blue
            )
            
 // 存储设备数量
            USBStatCard(
                title: LocalizationManager.shared.localizedString("usb.storage.title"),
                value: "\(storageDeviceCount)",
                icon: "externaldrive.fill",
                color: .orange
            )
            
 // 总设备数量
            USBStatCard(
                title: LocalizationManager.shared.localizedString("usb.total.title"),
                value: "\(connectedDevices.count)",
                icon: "cable.connector",
                color: .purple
            )
        }
    }
    
 // MARK: - 空状态视图
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cable.connector")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text(LocalizationManager.shared.localizedString("usb.empty.title"))
                .font(.title2)
                .fontWeight(.medium)
            
            Text(LocalizationManager.shared.localizedString("usb.empty.subtitle"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
 // MARK: - 设备列表视图
    
    private var deviceListView: some View {
        VStack(spacing: 12) {
            ForEach(connectedDevices, id: \.deviceID) { device in
                DeviceCard(device: device)
            }
        }
    }
    
 // MARK: - 计算属性
    
    private var mfiDeviceCount: Int {
        connectedDevices.filter { $0.deviceType == .appleMFi }.count
    }
    
    private var androidDeviceCount: Int {
        connectedDevices.filter { $0.deviceType == .androidDevice }.count
    }
    
    private var storageDeviceCount: Int {
        connectedDevices.filter { $0.deviceType == .externalDrive || $0.deviceType == .usbFlashDrive }.count
    }
    
 // MARK: - 方法

    private func loadCachedDevicesAndScanIfNeeded() {
        connectedDevices = usbManager.getConnectedUSBDevices().sorted { $0.name < $1.name }
        lastScanTime = usbManager.lastScanCompletedAt

        guard !hasLoadedInitialDevices else { return }
        hasLoadedInitialDevices = true

        if usbManager.lastScanCompletedAt == nil {
            refreshDevices()
        } else {
            Task { await refreshUSBPeers() }
        }
    }
    
    private func refreshDevices() {
        guard !isScanning else { return }
        isScanning = true
        
        Task {
 // 扫描USB设备。MFi/ExternalAccessory 扫描必须走显式授权路径，避免刷新页面时隐式触发系统隐私框架。
            await usbManager.scanForUSBDevices()
            await refreshUSBPeers()
            
 // 获取设备列表
            let devices = usbManager.getConnectedUSBDevices()
            
            await MainActor.run {
                self.connectedDevices = devices.sorted { $0.name < $1.name }
                self.lastScanTime = usbManager.lastScanCompletedAt
                self.isScanning = false
            }
        }
    }

    @MainActor
    private func refreshUSBPeers() async {
        do {
            appleUSBDevices = try await USBMultiplexTransport.devices()
            usbInventoryError = nil
        } catch {
            appleUSBDevices = []
            usbInventoryError = String(localized: "无法读取 USB 连接：") + error.localizedDescription
        }
        do {
            androidUSBDevices = try await usbManager.readNativeAndroidUSBDevices()
            androidInventoryError = nil
        } catch {
            androidInventoryError = String(localized: "无法更新 Android USB 设备：") + error.localizedDescription
        }
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }
}

/// A cable selects the route. The chosen, already paired protocol identity is
/// still checked by the same signed bootstrap and strict PQC handshake as CLI.
@available(macOS 14.0, *)
private struct USBPeerConnectionRow: View {
    let udid: String
    @ObservedObject private var trust = TrustSyncService.shared
    @ObservedObject private var service = P2PDiscoveryService.shared
    @ObservedObject private var presence = ConnectionPresenceService.shared
    @State private var selectedPeer = ""
    @State private var connecting = false
    @State private var inspecting = false
    @State private var outcome: String?
    @State private var failed = false

    private var peers: [USBPairedPeerChoice] {
        USBPairedPeerChoice.choices(records: trust.activeTrustRecords)
    }

    private var activeUSBPeer: (device: DiscoveredDevice, connection: P2PConnection)? {
        for device in service.connectedUSBControlDevices {
            guard let peerID = device.deviceId,
                  presence.activeConnection(forPeerId: peerID)?.controlTransport == .usb,
                  let connection = service.authenticatedUSBConnection(to: device, udid: udid) else { continue }
            return (device, connection)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "通过 USB 连接 SkyBridge"), systemImage: "cable.connector")
                .font(.headline)
            if let active = activeUSBPeer {
                Text(active.device.name).font(.headline)
                Label(LocalizationManager.shared.localizedString("connection.current.usb"), systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("usb.connected.\(udid)")
                if let suite = active.connection.negotiatedSuiteName {
                    Text(suite).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Picker(String(localized: "已配对设备"), selection: $selectedPeer) {
                        Text(String(localized: "选择线缆连接的设备")).tag("")
                        ForEach(peers) { peer in
                            Text("\(peer.name) · \(peer.fingerprint.prefix(12))").tag(peer.id)
                        }
                    }
                    .disabled(connecting || inspecting)
                    Button(connecting ? String(localized: "正在验证…") : String(localized: "连接")) {
                        connect()
                    }
                    .disabled(connecting || inspecting || !peers.contains { $0.id == selectedPeer })
                    .accessibilityIdentifier("usb.connect.\(udid)")
                }
                if inspecting {
                    ProgressView(LocalizationManager.shared.localizedString("usb.peer.identifying"))
                        .controlSize(.small)
                }
            }
            if peers.isEmpty && activeUSBPeer == nil {
                Text(String(localized: "先在设备管理中完成配对，再选择此 USB 连接。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let outcome, activeUSBPeer == nil {
                Text(outcome).font(.callout).foregroundStyle(failed ? .red : .secondary)
            }
            DisclosureGroup(LocalizationManager.shared.localizedString("usb.connection.details")) {
                Text("USB · \(udid)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task(id: udid) { await identifyKnownCablePeer() }
    }

    /// A signed probe may select an already paired identity for this cable. It
    /// does not grant trust or connect, and never chooses a different saved peer.
    @MainActor
    private func identifyKnownCablePeer() async {
        guard activeUSBPeer == nil, selectedPeer.isEmpty, !connecting else { return }
        inspecting = true
        defer { inspecting = false }
        do {
            let inspection = try await service.inspectUSBPeer(udid: udid)
            try Task.checkCancellation()
            guard activeUSBPeer == nil, selectedPeer.isEmpty, !connecting else { return }
            guard inspection.signature_verified, inspection.paired,
                  let fingerprint = inspection.peer.expected_fingerprint else {
                outcome = LocalizationManager.shared.localizedString("usb.peer.pairFirst")
                return
            }
            let matches = peers.filter {
                $0.peerID.caseInsensitiveCompare(inspection.peer.peer_id) == .orderedSame && $0.fingerprint == fingerprint
            }
            guard matches.count == 1 else {
                outcome = LocalizationManager.shared.localizedString("usb.peer.pairFirst")
                return
            }
            selectedPeer = matches[0].id
        } catch is CancellationError {
            return
        } catch {
            guard activeUSBPeer == nil, selectedPeer.isEmpty, !connecting else { return }
            failed = true
            outcome = LocalizationManager.shared.localizedString("usb.peer.identificationFailed") + error.localizedDescription
        }
    }

    @MainActor
    private func connect() {
        guard let peer = peers.first(where: { $0.id == selectedPeer }) else { return }
        connecting = true; outcome = nil; failed = false
        Task { @MainActor in
            defer { connecting = false }
            do {
                let request = try OperatorUSBConnectRequest(params: .init([
                    "udid": .string(udid), "peer_id": .string(peer.peerID),
                    "expected_fingerprint": .string(peer.fingerprint)
                ]))
                let result = try await OperatorNearbyFileRuntime.connectUSB(request)
                guard result.transport == "usb", result.pqc == true, let suite = result.negotiated_suite else {
                    throw CrossnetControlFailure.sessionRuntimeApplyFailed
                }
                outcome = String(localized: "USB 身份验证成功，已建立加密连接：") + suite
            } catch {
                failed = true
                outcome = String(localized: "USB 连接失败：") + error.localizedDescription
            }
        }
    }
}

// MARK: - 统计卡片组件

@available(macOS 14.0, *)
struct USBStatCard: View {
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title2)
                
                Spacer()
                
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
            }
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
}

// MARK: - 设备卡片组件

@available(macOS 14.0, *)
struct DeviceCard: View {
    @EnvironmentObject var themeConfiguration: ThemeConfiguration
    let device: USBDeviceInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
 // 设备头部信息
            HStack {
                deviceIcon
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Text(device.deviceType.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
 // MFi认证标识
                if device.isMFiCertified {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text(LocalizationManager.shared.localizedString("usb.mfi.certified"))
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            
 // 设备详细信息
            VStack(alignment: .leading, spacing: 8) {
                deviceInfoRow(label: LocalizationManager.shared.localizedString("usb.device.id"), value: device.deviceID)
                deviceInfoRow(label: LocalizationManager.shared.localizedString("usb.vendor.id"), value: String(format: "0x%04X", device.vendorID))
                deviceInfoRow(label: LocalizationManager.shared.localizedString("usb.product.id"), value: String(format: "0x%04X", device.productID))
                
                if let serialNumber = device.serialNumber {
                    deviceInfoRow(label: LocalizationManager.shared.localizedString("usb.serial.number"), value: serialNumber)
                }
                
                deviceInfoRow(label: LocalizationManager.shared.localizedString("usb.connection.interface"), value: device.connectionInterface)
                
 // 设备能力
                if !device.capabilities.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizationManager.shared.localizedString("usb.device.capabilities"))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 80))
                        ], spacing: 4) {
                            ForEach(device.capabilities, id: \.self) { capability in
                                Text(capability)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(themeConfiguration.cardBackgroundMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(themeConfiguration.borderColor, lineWidth: 1)
        )
    }
    
    private var deviceIcon: some View {
        Group {
            switch device.deviceType {
            case .appleMFi:
                Image(systemName: "iphone")
                    .foregroundColor(.blue)
            case .androidDevice:
                Image(systemName: "smartphone")
                    .foregroundColor(.green)
            case .externalDrive:
                Image(systemName: "externaldrive.fill")
                    .foregroundColor(.orange)
            case .usbFlashDrive:
                Image(systemName: "externaldrive.fill.badge.plus")
                    .foregroundColor(.purple)
            case .audioDevice:
 // USB 音频设备（耳机/音箱）
                Image(systemName: "headphones")
                    .foregroundColor(.pink)
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.gray)
            }
        }
        .font(.title2)
        .frame(width: 40, height: 40)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func deviceInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            
            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
        }
    }
}

// MARK: - 预览

@available(macOS 14.0, *)
struct USBDeviceManagementView_Previews: PreviewProvider {
    static var previews: some View {
        USBDeviceManagementView()
            .frame(width: 800, height: 600)
    }
}
