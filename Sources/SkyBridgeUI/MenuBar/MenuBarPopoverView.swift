//
// MenuBarPopoverView.swift
// SkyBridgeUI
//
// Menu Bar App - Popover View
// Requirements: 1.2, 2.1, 2.3, 2.4, 3.1, 4.2, 6.1, 6.2
//

import SwiftUI
import SkyBridgeCore
import AppKit

/// 菜单栏弹出面板视图
/// Requirements: 1.2
@available(macOS 14.0, *)
public struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    
    public init(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
 // 头部：应用标题
            HeaderSection()
            
            Divider()
            
 // 设备列表
            DeviceListSection(
                devices: viewModel.discoveredDevices,
                isScanning: viewModel.isScanning,
                onDeviceSelected: { device in
                    viewModel.selectDevice(device)
                }
            )
            
 // 传输进度（如有）
            if viewModel.configuration.showTransferProgress && !viewModel.activeTransfers.isEmpty {
                Divider()
                TransferProgressSection(transfers: viewModel.activeTransfers)
            }
            
            Divider()
            
 // 快捷操作按钮
            QuickActionsSection(viewModel: viewModel)
        }
        .frame(
            width: viewModel.configuration.popoverWidth,
            height: viewModel.configuration.popoverHeight
        )
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - HeaderSection

/// 头部区域
/// Requirements: 1.2
@available(macOS 14.0, *)
struct HeaderSection: View {
    var body: some View {
        HStack(spacing: 12) {
 // 应用图标 - 司南风格
            CompassIcon(size: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("SkyBridge Compass")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("跨设备连接助手")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
 // 打开主窗口按钮
            Button(action: {
                NotificationCenter.default.post(name: .menuBarOpenMainWindow, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            }) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("打开主窗口")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - CompassIcon

@available(macOS 14.0, *)
struct CompassIcon: View {
    let size: CGFloat
    @State private var image: NSImage?
    
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        Task.detached(priority: .utility) {
            let loadedImage = MenuBarBrandIconLoader.load()
            guard let loadedImage else { return }
            await MainActor.run { self.image = loadedImage }
        }
    }
}

private enum MenuBarBrandIconLoader {
    static func load() -> NSImage? {
        guard isRunningFromPackagedApp else { return nil }
        return loadImageResource(named: "AppIcon", withExtension: "icns", bundle: .main)
    }

    private static func loadImageResource(named name: String, withExtension extensionName: String, bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: name, withExtension: extensionName),
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        return image
    }

    private static var isRunningFromPackagedApp: Bool {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            return false
        }

        var url = URL(fileURLWithPath: executablePath).standardizedFileURL
        while url.path != "/" {
            if url.lastPathComponent == "Contents" {
                return true
            }
            url.deleteLastPathComponent()
        }

        return false
    }
}

// MARK: - DeviceListSection

/// 设备列表区域
/// Requirements: 2.1, 2.3, 2.4
@available(macOS 14.0, *)
struct DeviceListSection: View {
    let devices: [DiscoveredDevice]
    let isScanning: Bool
    let onDeviceSelected: (DiscoveredDevice) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
 // 标题栏
            HStack {
                Text("附近设备")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.6)
                }
                
                Text("\(devices.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            
 // 设备列表或占位符
            if devices.isEmpty {
 // Requirements: 2.3
                EmptyDeviceListPlaceholder()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(devices, id: \.id) { device in
                            DeviceRow(device: device)
                                .onTapGesture {
                                    onDeviceSelected(device)
                                }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }
}

/// 空设备列表占位符
/// Requirements: 2.3
@available(macOS 14.0, *)
struct EmptyDeviceListPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            
            Text("未发现设备")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("点击下方按钮扫描附近设备")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

/// 设备行
@available(macOS 14.0, *)
struct DeviceRow: View {
    let device: DiscoveredDevice
    
    var body: some View {
        HStack(spacing: 12) {
 // 设备图标
            Image(systemName: deviceIcon)
                .font(.system(size: 20))
                .foregroundColor(connectionColor)
                .frame(width: 28, height: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
 // 连接类型标签
                    ForEach(connectionBadges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            }
            
            Spacer()
            
            if let signalStrength {
                SignalStrengthIndicator(strength: signalStrength)
            } else {
                SignalUnavailableIndicator()
            }
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(Color.clear)
        .onHover { hovering in
 // 悬停效果由 SwiftUI 自动处理
        }
    }
    
    private var deviceIcon: String {
        if let networkLinkStatus = device.networkLinkStatus {
            return networkLinkStatus.iconName
        }
        if device.connectionTypes.contains(.usb) {
            return "cable.connector"
        } else if device.connectionTypes.contains(.bluetooth) {
            return "wave.3.right"
        } else {
            return "wifi"
        }
    }
    
    private var connectionColor: Color {
        guard let strength = signalStrength else {
            return .secondary
        }
        if strength > 0.7 {
            return .green
        } else if strength > 0.3 {
            return .orange
        } else {
            return .secondary
        }
    }

    private var signalStrength: Double? {
        device.networkLinkStatus?.normalizedSignalStrength
    }

    private var connectionBadges: [String] {
        var badges: [String] = []
        var seen = Set<String>()

        func append(_ label: String) {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard seen.insert(trimmed.lowercased()).inserted else { return }
            badges.append(trimmed)
        }

        if let status = device.networkLinkStatus {
            if status.kind == .unknown {
                append(device.primaryConnectionType.displayName)
            } else {
                append(status.displayLabel)
            }
        }

        for type in sortedConnectionTypes where badges.count < 2 {
            append(type.displayName)
        }

        return Array(badges.prefix(2))
    }

    private var sortedConnectionTypes: [DeviceConnectionType] {
        let priority: [DeviceConnectionType] = [
            .cellular,
            .wifi,
            .thunderbolt,
            .ethernet,
            .usb,
            .bluetooth,
            .unknown
        ]
        return device.connectionTypes.sorted { lhs, rhs in
            let lhsIndex = priority.firstIndex(of: lhs) ?? priority.count
            let rhsIndex = priority.firstIndex(of: rhs) ?? priority.count
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.rawValue < rhs.rawValue
        }
    }
}

/// 信号强度指示器 - iPhone 风格扇形信号格
@available(macOS 14.0, *)
struct SignalStrengthIndicator: View {
    let strength: Double
    
    var body: some View {
 // iPhone 风格：4 个递增高度的圆角矩形条
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < barsCount ? signalColor : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: barHeight(for: index))
            }
        }
        .frame(height: 14)
    }
    
    private var barsCount: Int {
        if strength >= 0.9 { return 4 }
        if strength >= 0.65 { return 3 }
        if strength >= 0.4 { return 2 }
        if strength >= 0.15 { return 1 }
        return 0
    }
    
    private var signalColor: Color {
        if strength >= 0.65 { return .primary }
        if strength >= 0.4 { return .orange }
        return .red
    }
    
    private func barHeight(for index: Int) -> CGFloat {
 // iPhone 风格递增高度：4, 7, 10, 14
        CGFloat(4 + index * 3 + (index > 0 ? 1 : 0))
    }
}

@available(macOS 14.0, *)
struct SignalUnavailableIndicator: View {
    var body: some View {
        Text("—")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 22, height: 14)
    }
}

// MARK: - TransferProgressSection

/// 传输进度区域
/// Requirements: 4.2
@available(macOS 14.0, *)
struct TransferProgressSection: View {
    let transfers: [MenuBarTransferItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("传输中")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            
            ForEach(transfers) { transfer in
                TransferRow(transfer: transfer)
            }
            .padding(.bottom, 8)
        }
    }
}

/// 传输行
@available(macOS 14.0, *)
struct TransferRow: View {
    let transfer: MenuBarTransferItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: stateIcon)
                    .font(.caption)
                    .foregroundColor(stateColor)
                
                Text(transfer.fileName)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                Text(transfer.formattedProgress)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ProgressView(value: transfer.progress)
                .progressViewStyle(.linear)
                .tint(stateColor)
            
            HStack {
                Text(transfer.formattedSpeed)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }
    
    private var stateIcon: String {
        switch transfer.state {
        case .transferring: return "arrow.up.arrow.down"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }
    
    private var stateColor: Color {
        switch transfer.state {
        case .transferring: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        }
    }
}

// MARK: - QuickActionsSection

/// 快捷操作区域
/// Requirements: 3.1, 3.2, 3.3, 3.4, 3.5
@available(macOS 14.0, *)
struct QuickActionsSection: View {
    @ObservedObject var viewModel: MenuBarViewModel
    
#if DEBUG || SKYBRIDGE_TESTING
 /// 快捷操作按钮标识符（用于测试）
    static let buttonIdentifiers = [
        "deviceDiscovery",
        "fileTransfer",
        "screenMirror",
        "settings"
    ]
#endif
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 8) {
 // 设备发现
            QuickActionButton(
                icon: "magnifyingglass",
                title: "发现设备",
                isLoading: viewModel.isScanning
            ) {
                Task {
                    await viewModel.startDeviceScan()
                }
            }
            .accessibilityIdentifier("deviceDiscovery")
            
 // 文件传输
            QuickActionButton(
                icon: "doc.fill",
                title: "文件传输"
            ) {
                viewModel.openFileTransfer()
            }
            .accessibilityIdentifier("fileTransfer")
            
 // 屏幕镜像
            QuickActionButton(
                icon: "rectangle.on.rectangle",
                title: "屏幕镜像"
            ) {
                viewModel.openScreenMirror()
            }
            .accessibilityIdentifier("screenMirror")
            
 // 设置
            QuickActionButton(
                icon: "gearshape.fill",
                title: "设置"
            ) {
                viewModel.openSettings()
            }
            .accessibilityIdentifier("settings")
        }
        .padding(12)
    }
}

/// 快捷操作按钮
@available(macOS 14.0, *)
struct QuickActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 20))
                    }
                }
                .frame(width: 24, height: 24)
                
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - DeviceConnectionType Extension

extension DeviceConnectionType {
    var displayName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "蜂窝"
        case .bluetooth: return "蓝牙"
        case .usb: return "USB"
        case .ethernet: return "以太网"
        case .thunderbolt: return "雷电"
        case .unknown: return "未知"
        }
    }
}
