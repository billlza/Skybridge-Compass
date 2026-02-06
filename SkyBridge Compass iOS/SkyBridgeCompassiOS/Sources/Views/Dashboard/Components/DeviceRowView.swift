//
// DeviceRowView.swift
// SkyBridgeCompassiOS
//
// 设备行视图组件 - 显示单个发现的设备
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 设备行视图
@available(iOS 17.0, *)
public struct DeviceRowView: View {
    let device: DiscoveredDevice
    let connectionStatus: ConnectionStatus?
    let onTap: () -> Void
    
    public init(device: DiscoveredDevice, connectionStatus: ConnectionStatus? = nil, onTap: @escaping () -> Void) {
        self.device = device
        self.connectionStatus = connectionStatus
        self.onTap = onTap
    }
    
    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // 设备图标
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [platformColor.opacity(0.3), platformColor.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: platformIcon)
                        .font(.system(size: 18))
                        .foregroundColor(platformColor)
                }
                
                // 设备信息
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)

                        if let status = connectionStatus {
                            Text(status.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(connectionStatusColor(status))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(connectionStatusColor(status).opacity(0.18))
                                .clipShape(Capsule())
                        }
                        
                        // PQC 徽章
                        if device.capabilities.contains("pqc") {
                            PQCBadge()
                        }
                    }
                    
                    HStack(spacing: 8) {
                        // 平台
                        Text(device.platform.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // IP 地址
                        if let ip = device.ipAddress {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(ip)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 能力徽章（端口来自 TXT/合并结果；如果未知就不显示端口）
                    HStack(spacing: 6) {
                        if device.supportsFileTransfer {
                            CapabilityBadge(
                                icon: "folder",
                                title: "文件",
                                port: device.fileTransferPort
                            )
                        }
                        if device.supportsRemoteControl {
                            CapabilityBadge(
                                icon: "display",
                                title: "远控",
                                port: device.remoteControlPort
                            )
                        }
                    }
                }
                
                Spacer()
                
                // 信号强度
                SignalStrengthView(strength: device.signalStrength)
                
                // 箭头
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Computed Properties
    
    private var platformIcon: String {
        switch device.platform {
        case .macOS: return "desktopcomputer"
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        case .android: return "smartphone"
        case .windows: return "pc"
        case .linux: return "server.rack"
        case .unknown: return "questionmark.circle"
        }
    }
    
    private var platformColor: Color {
        switch device.platform {
        case .macOS: return .blue
        case .iOS: return .cyan
        case .iPadOS: return .purple
        case .android: return .green
        case .windows: return .blue
        case .linux: return .orange
        case .unknown: return .gray
        }
    }

    private func connectionStatusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected:
            return .green
        case .connecting, .disconnecting:
            return .orange
        case .failed, .error:
            return .red
        case .disconnected:
            return .gray
        }
    }
}

// MARK: - Signal Strength View

/// 信号强度视图
@available(iOS 17.0, *)
struct SignalStrengthView: View {
    let strength: Int
    
    var body: some View {
        Group {
            if normalized <= 0.02 {
                Image(systemName: "wifi.slash")
            } else {
                Image(systemName: "wifi", variableValue: normalized)
            }
        }
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
        .font(.system(size: 14, weight: .medium))
        .frame(width: 20, alignment: .trailing)
    }

    /// 将 RSSI（dBm，通常为负数）映射到 [0,1]，用于可变 SF Symbol
    private var normalized: Double {
        // 经验阈值：-90 较弱，-30 很强
        let minRSSI = -90.0
        let maxRSSI = -30.0
        let value = Double(strength)
        let clamped = min(max(value, minRSSI), maxRSSI)
        return (clamped - minRSSI) / (maxRSSI - minRSSI)
    }
}

// MARK: - PQC Badge

/// PQC 徽章
@available(iOS 17.0, *)
struct PQCBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 8))
            Text("PQC")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundColor(.green)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.2))
        .clipShape(Capsule())
    }
}

// MARK: - Capability Badge

@available(iOS 17.0, *)
private struct CapabilityBadge: View {
    let icon: String
    let title: String
    let port: UInt16?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            if let port {
                Text("\(title):\(port)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            } else {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundColor(.cyan)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.cyan.opacity(0.15))
        .clipShape(Capsule())
    }
}

// MARK: - Empty Devices View

/// 空设备列表视图
@available(iOS 17.0, *)
struct EmptyDevicesView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            Text("未发现设备")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("确保设备在同一网络下")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

// MARK: - Connection Row View

/// 连接行视图
@available(iOS 17.0, *)
struct ConnectionRowView: View {
    let connection: Connection
    let onDisconnect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // 设备图标
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Image(systemName: deviceIcon)
                    .font(.system(size: 16))
                    .foregroundColor(.green)
            }
            
            // 连接信息
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.device.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(connection.status.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // 断开按钮
            Button(action: onDisconnect) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red.opacity(0.8))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.green.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
    }
    
    private var deviceIcon: String {
        switch connection.device.platform {
        case .macOS: return "desktopcomputer"
        case .iOS: return "iphone"
        case .iPadOS: return "ipad"
        default: return "laptop"
        }
    }
    
    private var statusColor: Color {
        switch connection.status {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        case .error: return .red
        }
    }
}

// MARK: - Device Detail Sheet

/// 设备详情弹窗
@available(iOS 17.0, *)
struct DeviceDetailSheet: View {
    let device: DiscoveredDevice
    
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connectionManager: P2PConnectionManager
    @ObservedObject private var trustedStore: TrustedDeviceStore = .shared
    @State private var isConnecting = false
    @State private var connectError: String?
    @State private var showPQCVerification: Bool = false
    
    var body: some View {
        NavigationStack {
            List {
                // 设备信息
                Section("设备信息") {
                    LabeledContent("名称", value: device.name)
                    LabeledContent("平台", value: device.platform.displayName)
                    LabeledContent("系统版本", value: device.osVersion)
                    LabeledContent("连接状态", value: connectionStatus?.displayName ?? "未连接")
                    if let ip = device.ipAddress {
                        LabeledContent("IP 地址", value: ip)
                    }
                    if let err = connectionManager.connectionErrorByDeviceId[device.id], !err.isEmpty {
                        LabeledContent("断开原因", value: err)
                    }
                }
                
                // 功能
                Section("支持功能") {
                    ForEach(device.capabilities, id: \.self) { capability in
                        HStack {
                            Image(systemName: capabilityIcon(capability))
                                .foregroundColor(.cyan)
                            Text(capabilityName(capability))
                        }
                    }
                }
                
                // 操作
                Section {
                    if trustedStore.isTrusted(deviceId: device.id) {
                        HStack(spacing: 10) {
                            Image(systemName: trustSymbolName)
                                .foregroundStyle(.green)
                            Text("已受信任（PQC 引导）")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            showPQCVerification = true
                        } label: {
                            HStack {
                                Image(systemName: "lock.shield")
                                Text("PQC 身份验证（输入验证码）")
                            }
                        }
                    }
                    if connectionStatus == .connected {
                        Button(role: .destructive) {
                            disconnect()
                        } label: {
                            HStack {
                                Image(systemName: disconnectSymbolName)
                                Text("断开连接")
                            }
                        }
                    } else {
                        Button {
                            connect()
                        } label: {
                            HStack {
                                if isConnecting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                } else {
                                    Image(systemName: "link")
                                }
                                Text(isConnecting ? "连接中..." : "连接设备")
                            }
                        }
                        .disabled(isConnecting || connectionStatus == .connecting)
                    }
                }
            }
            .navigationTitle(device.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .alert(
                "连接失败",
                isPresented: Binding(
                    get: { connectError != nil },
                    set: { presenting in
                        if !presenting { connectError = nil }
                    }
                )
            ) {
                Button("好的") { connectError = nil }
            } message: {
                Text(connectError ?? "")
            }
            .sheet(isPresented: $showPQCVerification) {
                PQCVerificationView(device: device)
            }
        }
    }
    
    private var disconnectSymbolName: String {
        #if canImport(UIKit)
        // Some SF Symbols are OS-version dependent; avoid runtime spam on older system symbol sets.
        for name in ["link.badge.minus", "link.slash", "xmark.circle", "xmark"] {
            if UIImage(systemName: name) != nil { return name }
        }
        #endif
        return "xmark"
    }
    
    private var trustSymbolName: String {
        #if canImport(UIKit)
        for name in ["checkmark.shield", "checkmark.seal", "checkmark.circle", "checkmark"] {
            if UIImage(systemName: name) != nil { return name }
        }
        #endif
        return "checkmark"
    }

    private var connectionStatus: ConnectionStatus? {
        connectionManager.connectionStatusByDeviceId[device.id]
            ?? (connectionManager.activeConnections.contains(where: { $0.device.id == device.id }) ? .connected : nil)
    }

    private func connect() {
        isConnecting = true
        Task {
            do {
                try await P2PConnectionManager.instance.connect(to: device)
            isConnecting = false
            dismiss()
            } catch {
                isConnecting = false
                connectError = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        Task { @MainActor in
            await P2PConnectionManager.instance.disconnect(from: device)
            dismiss()
        }
    }
    
    private func capabilityIcon(_ capability: String) -> String {
        switch capability {
        case "remote_desktop", "remote_desktop_viewer": return "display"
        case "file_transfer": return "folder"
        case "clipboard_sync": return "doc.on.clipboard"
        case "screen_sharing", "screen_sharing_viewer": return "rectangle.on.rectangle"
        case "touch_input": return "hand.tap"
        case "pqc": return "lock.shield"
        default: return "questionmark.circle"
        }
    }
    
    private func capabilityName(_ capability: String) -> String {
        switch capability {
        case "remote_desktop", "remote_desktop_viewer": return "远程桌面"
        case "file_transfer": return "文件传输"
        case "clipboard_sync": return "剪贴板同步"
        case "screen_sharing", "screen_sharing_viewer": return "屏幕共享"
        case "touch_input": return "触控输入"
        case "pqc": return "量子安全"
        default: return capability
        }
    }
}

// MARK: - Preview
#if DEBUG
@available(iOS 17.0, *)
struct DeviceRowView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            DeviceRowView(
                device: DiscoveredDevice(
                    id: "test",
                    name: "MacBook Pro",
                    modelName: "MacBookPro18,3",
                    platform: .macOS,
                    osVersion: "15.0",
                    ipAddress: "192.168.1.100",
                    signalStrength: -45,
                    lastSeen: Date()
                )
            ) {}
            
            DeviceRowView(
                device: DiscoveredDevice(
                    id: "test2",
                    name: "iPhone 15 Pro",
                    modelName: "iPhone15,3",
                    platform: .iOS,
                    osVersion: "18.0",
                    ipAddress: "192.168.1.101",
                    signalStrength: -65,
                    lastSeen: Date()
                )
            ) {}
        }
        .padding()
        .background(Color.black)
    }
}
#endif
