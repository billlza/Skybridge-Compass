import SwiftUI
import AppKit
import SkyBridgeCore
import SkyBridgeProtocolCore

/// Presentation choices only. The connection owner reloads trust before any
/// USB mode change and authenticates the selected protocol identity on the wire.
struct USBPairedPeerChoice: Identifiable {
    let peerID: String
    let fingerprint: String
    let algorithm: ProtocolSigningAlgorithm
    let name: String
    var id: String { peerID + ":" + fingerprint + ":" + algorithm.rawValue }

    static func choices(records: [TrustRecord]) -> [Self] {
        var seen = Set<String>()
        return records.flatMap { record -> [Self] in
            guard record.isAuthenticationEligible else { return [] }
            let raw = record.currentDeviceIdMetadata ?? record.deviceId
            let normalized = raw.lowercased().hasPrefix("id:") ? String(raw.dropFirst(3)) : raw
            guard let id = UUID(uuidString: normalized) else { return [] }
            return record.currentPathAuthorityPins.compactMap { pin -> Self? in
                guard pin.algorithm == .mlDSA65 || pin.algorithm == .mlDSA87 else { return nil }
                let peer = Self(peerID: id.uuidString, fingerprint: pin.fingerprint,
                    algorithm: pin.algorithm, name: record.deviceName ?? id.uuidString)
                return seen.insert(peer.id).inserted ? peer : nil
            }
        }.sorted { $0.id < $1.id }
    }
}

@available(macOS 14.0, *)
struct AndroidUSBConnectionView: View {
    let devices: [USBDeviceInfo]
    let inventoryCurrent: Bool
    let refreshDevices: () -> Void
    @ObservedObject private var owner = P2PDiscoveryService.shared.androidUSBConnection
    @ObservedObject private var trust = TrustSyncService.shared
    @State private var selectedRegistry: UInt64?
    @State private var selectedPeer = ""
    @State private var inputFailure: String?

    private var peers: [USBPairedPeerChoice] { USBPairedPeerChoice.choices(records: trust.activeTrustRecords) }
    private var selectedDevice: USBDeviceInfo? {
        devices.first { $0.registryEntryID == selectedRegistry && $0.registryEntryID != nil }
    }
    private var canConnect: Bool {
        inventoryCurrent && !owner.isOccupied && selectedDevice != nil && peers.contains { $0.id == selectedPeer }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "通过 USB 连接 Android"), systemImage: "cable.connector")
                .font(.headline)
            if owner.isOccupied {
                Text(owner.selectedPeer?.name ?? String(localized: "Android 手机"))
                    .font(.headline)
                if owner.authenticatedConnection != nil {
                    Label(String(localized: "USB 已安全连接"), systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("usb.android.connected")
                    Text(String(localized: "可用的音频选项会显示在手机的设备页面。播放前会检查账户授权和输出格式，并请求本机确认。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(phaseDescription).accessibilityIdentifier("usb.android.phase")
                }
                if owner.phase == .cleanupRequired {
                    Button(String(localized: "完成断开")) { owner.finishCleanup() }
                        .accessibilityIdentifier("usb.android.cleanup")
                } else {
                    Button(owner.phase == .connected ? String(localized: "断开") : String(localized: "取消连接")) { owner.stop() }
                        .disabled(owner.phase == .stopping)
                        .accessibilityIdentifier("usb.android.stop")
                }
            } else {
                Picker(String(localized: "已插入的手机"), selection: $selectedRegistry) {
                    Text(String(localized: "选择 USB 设备")).tag(Optional<UInt64>.none)
                    ForEach(devices, id: \.registryEntryID) { device in
                        Text(device.name).tag(device.registryEntryID)
                    }
                }
                Picker(String(localized: "已配对设备"), selection: $selectedPeer) {
                    Text(String(localized: "选择这台手机的配对记录")).tag("")
                    ForEach(peers) { peer in Text(peer.name + " · " + peer.fingerprint.prefix(12)).tag(peer.id) }
                }
                Button(String(localized: "连接")) { connect() }
                    .disabled(!canConnect)
                    .accessibilityIdentifier("usb.android.connect")
                if peers.isEmpty {
                    Text(String(localized: "请先在设备管理中完成配对。插入线缆后仍会验证设备身份。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if devices.isEmpty {
                    Text(String(localized: "请通过 USB 连接手机，并在手机上打开 SkyBridge。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure = inputFailure ?? owner.failureMessage {
                Text(failure).foregroundStyle(.red).accessibilityIdentifier("usb.android.failure")
            }
            if inputFailure == nil, owner.failurePresentation?.recovery == .reviewDriverExtensions {
                USBDriverRecoveryHelp(resourcesReleased: !owner.isOccupied)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: devices.compactMap(\.registryEntryID), initial: true) { _, ids in
            if !ids.contains(where: { $0 == selectedRegistry }) {
                // Selecting a physical port is not selecting or trusting a peer.
                selectedRegistry = ids.count == 1 ? ids.first : nil
            }
        }
        .onChange(of: owner.phase) { _, phase in
            // AOA changes the registry generation. Refresh once after the
            // attempt retires; never automatically replay its connect request.
            if phase == .idle || phase == .failed { refreshDevices() }
        }
        .onChange(of: peers.map(\.id), initial: true) { _, ids in
            // A sole verified record is an unambiguous presentation choice.
            // Selecting it never starts a connection or grants new trust.
            if !ids.contains(selectedPeer) { selectedPeer = ids.count == 1 ? ids[0] : "" }
        }
    }

    private var phaseDescription: String {
        switch owner.phase {
        case .preparing: return String(localized: "正在准备手机，请留意手机上的 USB 提示…")
        case .opening: return String(localized: "正在建立 USB 通道…")
        case .authenticating: return String(localized: "正在验证设备身份…")
        case .connected, .stopping: return String(localized: "正在断开并释放设备…")
        case .cleanupRequired: return String(localized: "设备释放尚未确认，完成断开前不能重新连接。")
        case .idle: return String(localized: "USB 已断开")
        case .failed: return String(localized: "USB 连接未完成")
        }
    }

    private func connect() {
        guard canConnect, let device = selectedDevice, let peer = peers.first(where: { $0.id == selectedPeer }) else { return }
        inputFailure = nil
        do {
            try owner.connect(source: device, peer: AndroidUSBSelectedPeer(deviceID: peer.peerID,
                fingerprint: peer.fingerprint, algorithm: peer.algorithm, name: peer.name))
        } catch {
            inputFailure = error.localizedDescription
        }
    }
}


/// Opening Settings is an explicit user action; this view never changes drivers
/// or retries a connection. It remains unavailable until native cleanup completes.
@available(macOS 14.0, *)
private struct USBDriverRecoveryHelp: View {
    let resourcesReleased: Bool
    @State private var settingsOpenFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "退出换机或手机连接应用后，其 USB 驱动仍可能继续运行。请在系统设置中搜索“扩展”，按相关软件的说明检查 USB 驱动扩展；处理后返回并刷新设备。"))
                .font(.caption).foregroundStyle(.secondary)
            if !resourcesReleased {
                Text(String(localized: "请先完成上方的断开操作，再检查驱动。"))
                    .font(.caption)
            }
            Button(String(localized: "打开系统设置")) {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
                    settingsOpenFailed = true
                    return
                }
                // A true result acknowledges the launch request, not recovery
                // of the USB interface; no connection or success state changes.
                settingsOpenFailed = !NSWorkspace.shared.open(url)
            }
            .disabled(!resourcesReleased)
            .accessibilityIdentifier("usb.android.reviewDrivers")
            if settingsOpenFailed {
                Text(String(localized: "无法打开系统设置。请从 Apple 菜单手动打开后检查扩展。"))
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("usb.android.settingsOpenFailed")
            }
        }
        .accessibilityIdentifier("usb.android.driverRecovery")
    }
}
