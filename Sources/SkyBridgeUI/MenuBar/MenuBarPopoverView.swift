//
// MenuBarPopoverView.swift
// SkyBridgeUI
//
// Menu Bar App - Popover View
// Requirements: 1.2, 2.1, 2.3, 2.4, 3.1, 4.2, 6.1, 6.2
//

import SwiftUI
import SkyBridgeCore

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

// MARK: - CompassIcon (司南图标)

/// 司南/指南针风格图标
@available(macOS 14.0, *)
struct CompassIcon: View {
    let size: CGFloat
    
    var body: some View {
        ZStack {
 // 外圈
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.blue.opacity(0.8), .cyan.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
            
 // 内圈刻度
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                .padding(4)
            
 // 指针 - 北（红色）
            CompassNeedle(isNorth: true)
                .fill(
                    LinearGradient(
                        colors: [.red, .red.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            
 // 指针 - 南（白色/浅色）
            CompassNeedle(isNorth: false)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.9), .gray.opacity(0.5)],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                )
            
 // 中心点
            Circle()
                .fill(Color.blue)
                .frame(width: size * 0.15, height: size * 0.15)
        }
        .frame(width: size, height: size)
    }
}

/// 指南针指针形状
@available(macOS 14.0, *)
struct CompassNeedle: Shape {
    let isNorth: Bool
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let needleLength = rect.height * 0.35
        let needleWidth = rect.width * 0.12
        
        if isNorth {
 // 北指针（向上）
            path.move(to: CGPoint(x: center.x, y: center.y - needleLength))
            path.addLine(to: CGPoint(x: center.x - needleWidth, y: center.y))
            path.addLine(to: CGPoint(x: center.x + needleWidth, y: center.y))
            path.closeSubpath()
        } else {
 // 南指针（向下）
            path.move(to: CGPoint(x: center.x, y: center.y + needleLength))
            path.addLine(to: CGPoint(x: center.x - needleWidth, y: center.y))
            path.addLine(to: CGPoint(x: center.x + needleWidth, y: center.y))
            path.closeSubpath()
        }
        
        return path
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
                    ForEach(Array(device.connectionTypes.prefix(2)), id: \.self) { (type: DeviceConnectionType) in
                        Text(type.displayName)
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
            
 // 信号强度 - 始终显示，使用实际值或基于连接类型估算
            SignalStrengthIndicator(strength: estimatedSignalStrength)
            
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
        if device.connectionTypes.contains(.usb) {
            return "cable.connector"
        } else if device.connectionTypes.contains(.bluetooth) {
            return "wave.3.right"
        } else {
            return "wifi"
        }
    }
    
    private var connectionColor: Color {
        let strength = estimatedSignalStrength
        if strength > 0.7 {
            return .green
        } else if strength > 0.3 {
            return .orange
        } else {
            return .secondary
        }
    }
    
 /// 估算信号强度：优先使用实际值，否则基于连接类型估算
    private var estimatedSignalStrength: Double {
 // 如果有实际测量值，直接使用
        if let strength = device.signalStrength {
            return strength
        }
        
 // 基于连接类型估算信号强度
        if device.connectionTypes.contains(.thunderbolt) {
            return 1.0  // 雷电连接最强
        } else if device.connectionTypes.contains(.usb) {
            return 0.95 // USB 连接很强
        } else if device.connectionTypes.contains(.ethernet) {
            return 0.9  // 有线网络很强
        } else if device.connectionTypes.contains(.wifi) {
            return 0.7  // Wi-Fi 默认中等偏强
        } else if device.connectionTypes.contains(.bluetooth) {
            return 0.5  // 蓝牙默认中等
        } else {
            return 0.3  // 未知连接类型默认较弱
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
    
 /// 快捷操作按钮标识符（用于测试）
    static let buttonIdentifiers = [
        "deviceDiscovery",
        "fileTransfer",
        "screenMirror",
        "settings"
    ]
    
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
        case .bluetooth: return "蓝牙"
        case .usb: return "USB"
        case .ethernet: return "以太网"
        case .thunderbolt: return "雷电"
        case .unknown: return "未知"
        }
    }
}
